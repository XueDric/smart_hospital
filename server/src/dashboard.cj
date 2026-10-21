/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 *
 * ===== dashboard.cj —— P4 运营看板（**只出聚合，绝不出明细**）==============
 *
 * 职责：规模、挂号趋势与取消率、号源使用率、分诊命中率、预问诊/病历进度、AI 与知识库概览
 * 对外：DashboardRepo.build(now, aiSettings) → JsonObject、dashCutoffDate()
 * 硬约束：所有 SELECT 只允许 COUNT/SUM/分组键（department.name、visit_date），不得出现任何 id 或联系方式
 * 不变量：每项指标独立容错（取不到给 0，不整页 500）；不提供按年龄/性别分布 —— 小样本聚合等价于个人识别
 */

package qingzhou

import std.collection.*
import stdx.encoding.json.*

/* 一行"标签 + 计数"。标签只允许放非个人的分组键（科室名 / 日期 / 状态码）。 */
class CountRow {
    var label: String = ""
    var n: Int64 = 0
}

public class DashboardRepo {
    private let db: DbBackend

    public init(db: DbBackend) {
        this.db = db
    }

    /* 单值计数（失败当 0 —— 看板不该因为一个指标查不到就整页 500）。 */
    private func count1(sql: String, params: Array<DbValue>): Int64 {
        try {
            let rs = db.query(sql, params)
            if (rs.rowCount() > 0) {
                return rs.getInt(0, 0)
            }
        } catch (e: Exception) {
            return 0
        }
        return 0
    }

    /* 分组计数（标签 + 计数）。 */
    private func group2(sql: String, params: Array<DbValue>): Array<CountRow> {
        let out = ArrayList<CountRow>()
        try {
            let rs = db.query(sql, params)
            var i: Int64 = 0
            while (i < rs.rowCount()) {
                let c = CountRow()
                c.label = rs.getString(i, 0)
                c.n = rs.getInt(i, 1)
                out.add(c)
                i = i + 1
            }
        } catch (e: Exception) {
            /* 同上：看板是只读视图，单个指标失败不该整页失败 */
        }
        return out.toArray()
    }

    private func rowsToJson(rows: Array<CountRow>): JsonArray {
        let arr = ArrayList<JsonValue>()
        for (c in rows) {
            let e = JsonObject()
            e.put("label", JsonString(c.label))
            e.put("count", JsonInt(c.n))
            arr.add(e)
        }
        return JsonArray(arr.toArray())
    }

    /*
     * 组装整块看板。所有指标独立容错（count1 / group2 内部 catch）：表还不存在时该项为 0。
     * 每块带 source 说明数据来源 —— 容错的代价是真故障也显示成 0。
     */
    public func build(now: Int64, aiSettings: AiSettingsRepo): JsonObject {
        let o = JsonObject()

        /* ---------- ① 规模（科室 / 医生 / 患者）---------- */
        let scale = JsonObject()
        scale.put("departments", JsonInt(count1("SELECT COUNT(*) FROM department", Array<DbValue>())))
        scale.put("doctors", JsonInt(count1("SELECT COUNT(*) FROM doctor", Array<DbValue>())))
        scale.put("patients", JsonInt(count1("SELECT COUNT(*) FROM patient", Array<DbValue>())))
        /* 三张表直接 SQL 读，无滞后；患者档案至今没有写入端点，只能靠人工 SQL / 导入维护。 */
        scale.put("source", JsonString(
            "mysql 直接读（rev.7 起不再经内存 Store，无滞后）；" +
            "科室/医生有管理端 CRUD，患者档案靠人工 SQL ⇒ 数字反映库中现有数据"))
        o.put("scale", scale)

        /* ---------- ② 挂号总览（含取消率）---------- */
        let total = count1("SELECT COUNT(*) FROM appointment", Array<DbValue>())
        let booked = count1("SELECT COUNT(*) FROM appointment WHERE status = ?", [DbStr(VISIT_BOOKED)])
        let visiting = count1("SELECT COUNT(*) FROM appointment WHERE status = ?", [DbStr(VISIT_VISITING)])
        /* arrived / waiting 也入看板：回答"现在有多少人在现场等"，否则这些人全混在 booked 里看不出来。 */
        let arrived = count1("SELECT COUNT(*) FROM appointment WHERE status = ?", [DbStr(VISIT_ARRIVED)])
        let waiting = count1("SELECT COUNT(*) FROM appointment WHERE status = ?", [DbStr(VISIT_WAITING)])
        let done = count1("SELECT COUNT(*) FROM appointment WHERE status = ?", [DbStr(VISIT_DONE)])
        let cancelled = count1("SELECT COUNT(*) FROM appointment WHERE status = ?", [DbStr(VISIT_CANCELLED)])
        let noShow = count1("SELECT COUNT(*) FROM appointment WHERE status = ?", [DbStr(VISIT_NO_SHOW)])
        let appt = JsonObject()
        appt.put("total", JsonInt(total))
        appt.put("booked", JsonInt(booked))
        appt.put("arrived", JsonInt(arrived))
        appt.put("waiting", JsonInt(waiting))
        appt.put("visiting", JsonInt(visiting))
        appt.put("done", JsonInt(done))
        appt.put("cancelled", JsonInt(cancelled))
        appt.put("no_show", JsonInt(noShow))
        /* 取消率用整数千分比（permille）而非浮点：精度够 0.1%，客户端除以 10；分母为 0 时给 0。 */
        appt.put("cancel_permille", JsonInt(if (total > 0) { cancelled * 1000 / total } else { 0 }))
        appt.put("no_show_permille", JsonInt(if (total > 0) { noShow * 1000 / total } else { 0 }))
        appt.put("permille_note", JsonString("取消率/爽约率是**千分比**（除以 10 得百分比）"))
        o.put("appointments", appt)

        /* ---------- ③ 挂号趋势（按就诊日，最近 N 天）---------- */
        /* 分组键是 visit_date（日期字符串，非个人数据）；限定窗口让响应大小可预期。 */
        let days = 14
        o.put("trend_days", JsonInt(days))
        /* 上下界都要有：只有下界时"未来日期的挂号"会被算进近 N 日趋势（未来号由号源/排班表达）。 */
        o.put("trend", rowsToJson(group2(
            "SELECT visit_date, COUNT(*) FROM appointment " +
            "WHERE visit_date >= ? AND visit_date <= ? " +
            "GROUP BY visit_date ORDER BY visit_date ASC LIMIT ?",
            [DbStr(dashCutoffDate(now, days)), DbStr(dashCutoffDate(now, 0)), DbInt(days)])))

        /* ---------- ④ 科室分布（挂号量 / 号源使用率）---------- */
        /* JOIN department 只为拿科室名做分组键：科室名是机构信息，不是个人数据。 */
        o.put("by_department", rowsToJson(group2(
            "SELECT d.name, COUNT(*) FROM appointment a " +
            "JOIN department d ON d.id = a.department_id " +
            "GROUP BY d.name ORDER BY COUNT(*) DESC LIMIT ?",
            [DbInt(50)])))
        /* 号源使用率：总号源 / 已用 / 剩余（全局 + 按科室） */
        let cap = JsonObject()
        cap.put("total_slots", JsonInt(count1("SELECT IFNULL(SUM(total_num), 0) FROM schedule", Array<DbValue>())))
        cap.put("remain_slots", JsonInt(count1("SELECT IFNULL(SUM(remain_num), 0) FROM schedule", Array<DbValue>())))
        cap.put("schedule_count", JsonInt(count1("SELECT COUNT(*) FROM schedule", Array<DbValue>())))
        cap.put("enabled_schedule_count",
                JsonInt(count1("SELECT COUNT(*) FROM schedule WHERE enabled = 1", Array<DbValue>())))
        o.put("slots", cap)

        /* ---------- ⑤ 分诊命中（**source 由数据推导**，不写死）---------- */
        /* source 由 triage_stat.source 的分布推出（单类报该类 / 两类报 mixed / 无记录报 none），
         * 不写死；by_source 逐项计数，三个数加起来等于分诊总次数，可自证。 */
        let triage = JsonObject()
        let srcRows = group2(
            "SELECT source, COUNT(*) FROM triage_stat GROUP BY source ORDER BY COUNT(*) DESC LIMIT ?",
            [DbInt(10)])
        /* 按前缀归类：model / model:invalid / model:* 都算模型家族 —— 精确匹配 "model"
         * 会把 model:invalid 落进 other，与单列的 model_invalid_calls 自相矛盾。 */
        var modelN: Int64 = 0
        var rulesN: Int64 = 0
        var otherN: Int64 = 0
        for (c in srcRows) {
            if (c.label.startsWith("model")) {
                modelN = modelN + c.n
            } else if (c.label.startsWith("rules")) {
                rulesN = rulesN + c.n
            } else {
                otherN = otherN + c.n
            }
        }
        var srcLabel = "none"
        if (modelN > 0 && rulesN == 0) {
            srcLabel = "model"
        } else if (rulesN > 0 && modelN == 0) {
            srcLabel = "rules"
        } else if (modelN > 0 && rulesN > 0) {
            srcLabel = "mixed"
        } else if (otherN > 0) {
            srcLabel = "other"
        }
        triage.put("source", JsonString(srcLabel))
        triage.put("by_source", rowsToJson(srcRows))
        triage.put("source_note", JsonString(
            "`source` 由 `triage_stat.source` 的分布**推导**（不是写死的）：" +
            "按前缀归成 model / rules 两族；只有一族报那一族，两族都有 = mixed，" +
            "只有未知来源 = other，无记录 = none（`model:invalid` 属 model 族）；" +
            "`by_source` 是逐项真实计数。"))
        triage.put("total_calls", JsonInt(count1("SELECT COUNT(*) FROM triage_stat", Array<DbValue>())))
        triage.put("red_flag_calls",
                   JsonInt(count1("SELECT COUNT(*) FROM triage_stat WHERE red_flag = 1", Array<DbValue>())))
        triage.put("by_reason", rowsToJson(group2(
            "SELECT reason_code, COUNT(*) FROM triage_stat GROUP BY reason_code " +
            "ORDER BY COUNT(*) DESC LIMIT ?", [DbInt(20)])))
        triage.put("by_department", rowsToJson(group2(
            "SELECT IFNULL(department, ''), COUNT(*) FROM triage_stat " +
            "WHERE department <> '' GROUP BY department ORDER BY COUNT(*) DESC LIMIT ?",
            [DbInt(50)])))
        o.put("triage", triage)

        /* ---------- ⑥ 预问诊完成率（P2 的成果可见化）---------- */
        let pvTotal = count1("SELECT COUNT(*) FROM previsit_session", Array<DbValue>())
        let pvDone = count1("SELECT COUNT(*) FROM previsit_session WHERE " + previsitCompleteSql(),
                            Array<DbValue>())
        let previsit = JsonObject()
        previsit.put("sessions", JsonInt(pvTotal))
        previsit.put("completed", JsonInt(pvDone))
        previsit.put("completion_permille", JsonInt(if (pvTotal > 0) { pvDone * 1000 / pvTotal } else { 0 }))
        previsit.put("permille_note", JsonString("完成率是**千分比**（除以 10 得百分比）"))
        o.put("previsit", previsit)

        /* ---------- ⑦ 电子病历进度（P4 自己的成果）---------- */
        let emrTotal = count1("SELECT COUNT(*) FROM medical_record", Array<DbValue>())
        let emrLocked = count1("SELECT COUNT(*) FROM medical_record WHERE status = ?",
                              [DbStr(EMR_LOCKED)])
        let emrEmpty = count1("SELECT COUNT(*) FROM medical_record WHERE " + emrEmptySql(),
                             Array<DbValue>())
        let emr = JsonObject()
        emr.put("records", JsonInt(emrTotal))
        emr.put("locked", JsonInt(emrLocked))
        emr.put("draft", JsonInt(emrTotal - emrLocked))
        emr.put("empty", JsonInt(emrEmpty))
        emr.put("locked_permille", JsonInt(if (emrTotal > 0) { emrLocked * 1000 / emrTotal } else { 0 }))
        emr.put("sections_per_record", JsonInt(emrSections().size))
        o.put("medical_records", emr)

        /* ---------- ⑧ AI 能力中心概览（**配置状态**，不是调用量）---------- */
        let opt = aiSettings.options(now)
        let ai = JsonObject()
        ai.put("enabled", JsonBool(opt.enabled))
        ai.put("disabled_reason", JsonString(opt.disabledReason))
        /* ⚠ endpoint 只给 host（查询串可能含凭据 —— 与 aiSettingsJson 同一口径） */
        ai.put("endpoint_host", JsonString(aiSafeHost(opt.endpoint)))
        ai.put("model", JsonString(opt.model))
        ai.put("tools_enabled", JsonInt(aiToolEnabledCount(aiSettings, now)))
        ai.put("tools_total", JsonInt(aiToolToggles().size))
        let promptCount = promptSlots().size
        var customized: Int64 = 0
        let prepo = PromptRepo(aiSettings)
        for (s in promptSlots()) {
            if (prepo.customized(s.name, now)) {
                customized = customized + 1
            }
        }
        ai.put("prompts_total", JsonInt(promptCount))
        ai.put("prompts_customized", JsonInt(customized))
        /* 三个数来自 triage_stat.source 的分布，只覆盖分诊，不含预问诊（预问诊是确定性规则流程，
         * 不调模型）⇒ 不等于"系统全部 AI 调用"。按分布报而不合成总数，因为分布能自证。 */
        let srcRepo = TriageStatRepo(db)
        let modelCalls = srcRepo.countBySource("model")
        let rulesCalls = srcRepo.countBySource("rules")
        let invalidCalls = srcRepo.countBySource("model:invalid")
        ai.put("model_calls", JsonInt(modelCalls))
        ai.put("rules_calls", JsonInt(rulesCalls))
        ai.put("model_invalid_calls", JsonInt(invalidCalls))
        ai.put("model_calls_note", JsonString(
            "口径：上方三个数来自 `triage_stat.source` 的分布，即**分诊**的真实留痕；" +
            "⚠ **不含预问诊**（它的采集槽位是**确定性规则流程**，不调模型）。" +
            "`model:invalid` = 模型答了但输出未通过安全检查（要改 Prompt，不是查网络）"))
        o.put("ai", ai)

        /* ---------- ⑥ P5 知识库规模 ---------- */
        /*
         * 知识库规模放进看板，让"向量覆盖率长期 0%"在例行巡检时就可见。
         * docs / chunks 是真实行数；embedding_coverage_pct 当前常态为 0（DeepSeek 无 embeddings）。
         * scan_limit_reached 是布尔结论：块数超过 KB_SCAN_LIMIT 后，后面的块静默检索不到。
         */
        let kbStats = JsonObject()
        let kbDocs = count1("SELECT COUNT(*) FROM kb_doc", Array<DbValue>())
        let kbDocsOn = count1("SELECT COUNT(*) FROM kb_doc WHERE enabled = 1", Array<DbValue>())
        let kbChunks = count1("SELECT COUNT(*) FROM kb_chunk", Array<DbValue>())
        let kbEmbedded = count1("SELECT COUNT(*) FROM kb_chunk WHERE embedding IS NOT NULL", Array<DbValue>())
        kbStats.put("docs", JsonInt(kbDocs))
        kbStats.put("docs_enabled", JsonInt(kbDocsOn))
        kbStats.put("chunks", JsonInt(kbChunks))
        kbStats.put("chunks_embedded", JsonInt(kbEmbedded))
        var kbPct: Int64 = 0
        if (kbChunks > 0) {
            kbPct = kbEmbedded * 100 / kbChunks
        }
        kbStats.put("embedding_coverage_pct", JsonInt(kbPct))
        kbStats.put("scan_limit", JsonInt(KB_SCAN_LIMIT))
        kbStats.put("scan_limit_reached", JsonBool(kbChunks > KB_SCAN_LIMIT))
        kbStats.put("note", JsonString(
            "docs/chunks 是库中真实计数。`embedding_coverage_pct` 为 0 表示尚无向量" +
            "（当前走**关键词检索**，`source=keyword`）—— 本版本 DeepSeek 未提供 " +
            "embeddings 端点，故向量路需另配服务，**0% 不等于功能损坏**。" +
            "★ `scan_limit_reached=true` 表示块数已超过检索上限，**超出部分不会被检索到**" +
            "（需要分片或缩库），看板在此**显式报警**而不是让它静默发生。"))
        o.put("knowledge_base", kbStats)

        o.put("generated_at", JsonInt(now))
        return o
    }
}

/*
 * 趋势窗口起始日期（now - days 天，YYYY-MM-DD）。日期换算复用 civilFromDays / triagePad2，
 * 天序用 hDaysFromSecondsShanghai，与 hTodayDate 同口径（按 UTC 算窗口边界会差 8 小时）。
 */
func dashCutoffDate(now: Int64, daysBack: Int64): String {
    let days = hDaysFromSecondsShanghai(now) - daysBack
    let (y, mo, d) = civilFromDays(days)
    return "${y}-${triagePad2(mo)}-${triagePad2(d)}"
}
