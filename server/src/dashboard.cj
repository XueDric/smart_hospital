/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 *
 * ===== dashboard.cj —— P4 运营看板（**只出聚合，绝不出明细**）==============
 *
 * 对应 brief §2.1 第 5 块「运营看板：科室医生患者规模、挂号趋势、号源使用率、
 * 分诊命中率、AI 调用概览」。
 *
 * ── ★★ 本文件唯一的硬约束：隐私 ──────────────────────────────────────────
 *
 *   看板是**跨患者**的视图 —— 这正是隐私最容易漏的地方（"就看一下聚合"）。
 *   所以这里立的规矩是**机制性**的，不是"我们记得别写"：
 *
 *     ① 本文件**所有**查询的 SELECT 列表只允许 `COUNT(*)` / `SUM(...)` /
 *        分组键（科室名、日期），**不允许出现任何 id 或联系方式列**；
 *     ② 分组键只允许用 `department.name` 与 `visit_date`（都不是个人数据）；
 *     ③ 响应里**不含任何** `patient_id` / `doctor_id` / `phone` / `name`
 *        （科室名例外 —— 它是机构信息，不是个人数据）；
 *     ④ 上述三条由验收测试**逐字段**钉住（AC-P4-*：把响应当字符串搜这些键）。
 *
 *   ⚠ 一个**刻意的遗漏**，写在这里免得将来有人"补齐"：
 *     看板**没有**"按患者年龄/性别分布"这类指标。它们看起来是聚合，
 *     但在小科室里等价于个人识别（某科室当天只有 1 个患者时，
 *     "60 岁以上 1 人"就等于说出他/她的年龄）。
 *     📌 小样本下的聚合会退化成个体信息 —— 这是"k-匿名"的朴素版本，
 *       在没有明确的 k 阈值之前，不提供这类维度。
 *
 * ── AI 调用概览做到了哪一步（诚实标注）──────────────────────────────────
 *   ★ 2026-10-09：**真模型已接入**（`ai_call.cj` + `ai_triage.cj`），
 *     所以这里报的是**真实的**调用分布，不再是"诚实地说 0"：
 *       `ai.model_calls` / `ai.rules_calls` / `ai.model_invalid_calls`
 *     三者来自 `triage_stat.source` 的分布 —— 可自证（三个数加起来 = 分诊总次数）。
 *   ⚠ **口径边界（必须写清，否则数字会被误读）**：
 *     这三个数只覆盖**分诊**；**不含预问诊** —— 预问诊的采集槽位是
 *     **确定性规则流程**（P2 的设计），**根本不调模型**。
 *   ⚠ 仍然**不编造**：`ai.model_calls` 为 0 时就是"这段时间没有模型调用"，
 *     而不是"我们没统计"。区别在于前者可被 `triage_stat` 的行数核对。
 */

package qingzhou

import std.collection.*
import stdx.encoding.json.*

/*
 * 一个"计数 + 标签"的行（分组统计的通用形状）。
 * ⚠ 标签只允许放**非个人**的分组键（科室名 / 日期 / 状态码）。
 */
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
     * 组装整块看板。
     *
     * ⚠ 所有指标都**独立容错**（`count1` / `group2` 内部 catch）：
     *   看板某张表还不存在（例如全新库）时应该是"这一项为 0"，
     *   而不是整页 500 —— 看板的用途恰恰是"看清全局"，
     *   它自己挂掉会让人以为整个系统坏了。
     *   📌 代价：一个真故障会被显示成 0。所以每块都带 `source` 字段说明
     *     数据从哪来，并在 selftest 里另有一组"表都在"的断言兜底。
     */
    public func build(now: Int64, aiSettings: AiSettingsRepo): JsonObject {
        let o = JsonObject()

        /* ---------- ① 规模（科室 / 医生 / 患者）---------- */
        /*
         * ⚠ `department` / `doctor` / `patient` 三张表属**内存 Store**，
         *   而内存 Store 在生产路径上**不刷盘**（P4 已确认，见 P4-HANDOFF）
         *   ⇒ 这里读到的可能是**旧数据**（上一次刷盘时的快照）。
         *   如实标注：`scale.source` = "mysql（内存 Store 的表，生产未刷盘 ⇒ 可能滞后）"。
         *   📌 这比"悄悄给个数字"诚实得多 —— 运维看到这句就知道为什么数字不动。
         */
        let scale = JsonObject()
        scale.put("departments", JsonInt(count1("SELECT COUNT(*) FROM department", Array<DbValue>())))
        scale.put("doctors", JsonInt(count1("SELECT COUNT(*) FROM doctor", Array<DbValue>())))
        scale.put("patients", JsonInt(count1("SELECT COUNT(*) FROM patient", Array<DbValue>())))
        /*
         * ★ ADR-0001 rev.7：内存 Store 已整体拆除 ⇒ 这三张表现在是**直接 SQL 读**，
         *   **不再是"上次刷盘的快照"**，所以原先那句"可能滞后"的标注已不成立。
         *   ⚠ 但仍要标注来源：它们目前**没有写入端点**（靠人工 SQL 维护），
         *     所以数字反映的是"库里现有的参考数据"，不是"系统自动积累的规模"。
         *     这两件事对看板读者是**不同的信息**，不能混。
         */
        scale.put("source", JsonString(
            "mysql 直接读（rev.7 起不再经内存 Store，无滞后）；" +
            "⚠ 但这三张表目前**没有写入端点**，靠人工 SQL 维护 ⇒ 数字反映库中现有参考数据"))
        o.put("scale", scale)

        /* ---------- ② 挂号总览（含取消率）---------- */
        let total = count1("SELECT COUNT(*) FROM appointment", Array<DbValue>())
        let booked = count1("SELECT COUNT(*) FROM appointment WHERE status = ?", [DbStr(VISIT_BOOKED)])
        let visiting = count1("SELECT COUNT(*) FROM appointment WHERE status = ?", [DbStr(VISIT_VISITING)])
        /*
         * ★ 2026-10-15（改进 6）：到院/候诊两态也进看板。
         *   为什么必须有这两个数字：它们回答"现在有多少人**在现场等**" ——
         *   这是运营最关心的一个量（等太久要加开诊室），而原口径里
         *   这些人全都挤在 `booked` 里，与"还没出门的患者"混在一起，看不出来。
         */
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
        /*
         * ⚠ 取消率**用整数千分比**（`permille`）而不是浮点：
         *   · 仓颉侧的浮点格式化在本项目没验过（不想为了一个百分比引入未测路径）；
         *   · 千分比精度足够（0.1%），且客户端除以 10 即可。
         *   ⚠ 分母为 0 时给 0，**不给 NULL、不抛** —— "没有挂号"时取消率是 0 很自然。
         */
        appt.put("cancel_permille", JsonInt(if (total > 0) { cancelled * 1000 / total } else { 0 }))
        appt.put("no_show_permille", JsonInt(if (total > 0) { noShow * 1000 / total } else { 0 }))
        appt.put("permille_note", JsonString("取消率/爽约率是**千分比**（除以 10 得百分比）"))
        o.put("appointments", appt)

        /* ---------- ③ 挂号趋势（按就诊日，最近 N 天）---------- */
        /*
         * ⚠ 分组键是 `visit_date`（日期字符串）—— 不是个人数据。
         *   限定窗口是为了"响应大小可预期"（不限窗口时，一个跑了三年的库
         *   会返回上千行，看板反而看不清）。
         */
        let days = 14
        o.put("trend_days", JsonInt(days))
        o.put("trend", rowsToJson(group2(
            "SELECT visit_date, COUNT(*) FROM appointment " +
            "WHERE visit_date >= ? GROUP BY visit_date ORDER BY visit_date ASC LIMIT ?",
            [DbStr(dashCutoffDate(now, days)), DbInt(days)])))

        /* ---------- ④ 科室分布（挂号量 / 号源使用率）---------- */
        /*
         * ⚠ 这里 JOIN 了 department 拿**科室名**做分组键。
         *   科室名是机构信息（管理员本来就在管理它），不是个人数据 ——
         *   这一点与"不给患者姓名"是两回事，刻意区分。
         */
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
        /*
         * ★★ 2026-10-17 评审 P2-7：这里原本写死 `source = "rules"`。
         *   真模型 2026-10-09 就接进来了，写死的值会**一直骗人**：
         *   看板说"全走规则"，而 triage_stat 里明明躺着 source=model 的行。
         *   现在 source 由 `triage_stat.source` 的分布**推出来**
         *   （只有一类报那一类 / 两类都有报 mixed / 无记录报 none），
         *   并额外给出 `by_source` 逐项计数 —— 数字能自证，不靠一句注释。
         */
        let triage = JsonObject()
        let srcRows = group2(
            "SELECT source, COUNT(*) FROM triage_stat GROUP BY source ORDER BY COUNT(*) DESC LIMIT ?",
            [DbInt(10)])
        var modelN: Int64 = 0
        var rulesN: Int64 = 0
        var otherN: Int64 = 0
        for (c in srcRows) {
            if (c.label == "model") {
                modelN = c.n
            } else if (c.label == "rules") {
                rulesN = c.n
            } else {
                otherN = otherN + c.n
            }
        }
        var srcLabel = "none"
        if (modelN > 0 && rulesN == 0 && otherN == 0) {
            srcLabel = "model"
        } else if (rulesN > 0 && modelN == 0 && otherN == 0) {
            srcLabel = "rules"
        } else if (modelN + rulesN + otherN > 0) {
            srcLabel = "mixed"
        }
        triage.put("source", JsonString(srcLabel))
        triage.put("by_source", rowsToJson(srcRows))
        triage.put("source_note", JsonString(
            "`source` 由 `triage_stat.source` 的分布**推导**（不是写死的）：" +
            "只有 model / 只有 rules / 两者都有 = mixed / 无记录 = none；" +
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
        /*
         * ★★ 2026-10-09：**真模型已接入** ⇒ 这里从"诚实地说 0"改成"报真实的数"。
         *
         * ── 口径（必须写清，否则数字会被误读）────────────────────────────
         *   `model_calls` / `rules_calls` / `model_invalid_calls` 来自
         *   `triage_stat.source` 的分布 —— 即**分诊**这件事的真实留痕。
         *   ⚠ **不含预问诊**：预问诊的采集问题是**确定性的规则流程**
         *     （P2 的设计：槽位顺序固定、校验在规则里），**不调模型**。
         *     所以这两个数加起来**不等于**"系统全部 AI 调用"，
         *     而是"分诊的调用分布"。`model_calls_note` 里写明这一点。
         *   📌 为什么坚持按 source 分布报、而不是合成一个"总调用数"：
         *     合成的那个数**无法自证**（谁也说不清它统计了什么），
         *     而分布能自证 —— 三个数加起来就是分诊总次数（可核对）。
         */
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
         * ★★ 这一块为什么必须存在（而不是"知识库自己有 stats 接口就够"）：
         *   `GET /admin/kb/stats` 只有**知道要去看**的人才会调；而看板的用途是
         *   **"看清全局"** —— 知识库是分诊说明文案的来源，它的规模与
         *   **向量覆盖率**直接决定"RAG 增强还能不能更强"。
         *   放在看板上，运维在例行巡检时就会看到"覆盖率长期 0%"，
         *   而不是等到有人抱怨"模型说的和院内须知不一致"才发现。
         *
         * ⚠ 口径（照 `ai` 那一块的做法，每个数都要能自证）：
         *   · `docs` / `chunks` —— 库里现有行数（**真实计数，不编造**）
         *   · `embedding_coverage_pct` —— 有向量的块占比。**0% 是当前常态**
         *     （DeepSeek 无 embeddings 端点），所以**必须带说明**，
         *     否则看到 0% 的人会以为"功能坏了"。
         *   · ★ `scan_limit_reached` —— **布尔结论**：块数是否已超过检索上限
         *     （`KB_SCAN_LIMIT`）。超了之后**后面的块静默检索不到**，
         *     这是本仓最忌的形态 ⇒ 必须在看板上**一眼可见**，不能让人自己去比。
         *
         * ⚠ 独立容错（与整块看板同一纪律）：`kb_doc` / `kb_chunk` 表不存在
         *   （例如全新库、或 P5 建表还没跑）时显示 0，而**不是整页 500**。
         *   ⇒ 用本文件**自带**的 `count1`（内部 catch），
         *     而**不是** `kb_repo.cj` 的 `kbCount1` —— 后者是裸查询，表的缺失会直接抛。
         *   📌 教训（写下来免得下一个人顺手换掉）：**同名/近名的两个取数助手，
         *     容错语义可能完全不同。** 看板这一块的契约是"任何一项取不到都给 0"，
         *     所以要选**明确带 catch 的那个**，不能按名字像就挑。
         *     这不只是洁癖：看板恰恰是"系统出问题时给人看的那一页"，
         *     它自己 500 会让人以为**整个系统**坏了。
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
 * 趋势窗口的起始日期（now - days 天，YYYY-MM-DD）。
 *
 * ⚠ 复用 `civilFromDays` / `triagePad2`（hTodayDate 的实现）而不是另写一份日期换算：
 *   日期换算是最容易写错且"错了也看不出来"的一类代码（闰年、月末边界），
 *   本仓只有一处实现，这里沿用。
 * ⚠ 2026-10-12：天序改用 `hDaysFromSecondsShanghai`（Asia/Shanghai，UTC+8）——
 *   与 `hTodayDate()` 同一口径。此前这里按 UTC 算，
 *   会让看板趋势的窗口边界与"今天"的定义**不一致**（差 8 小时，
 *   而统计是按 `visit_date` 这类**本地日期字符串**分组的）。
 *   📌 两处口径分家正是本次要修的病灶，所以这里必须同一个函数。
 */
func dashCutoffDate(now: Int64, daysBack: Int64): String {
    let days = hDaysFromSecondsShanghai(now) - daysBack
    let (y, mo, d) = civilFromDays(days)
    return "${y}-${triagePad2(mo)}-${triagePad2(d)}"
}
