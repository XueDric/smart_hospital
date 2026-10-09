/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 *
 * ===== triage_stat.cj —— P4：把分诊结论留痕（**只存得出指标所必需的最小集合**）
 *
 * ── 为什么需要它 ──────────────────────────────────────────────────────────
 *   brief §2.1 要的"分诊命中率"在原设计里**无从计算** —— 因为 `POST /triage`
 *   只回结论、不留任何痕迹。⇒ 要有历史才可能有分布。
 *
 * ── ★★ 本文件的两条硬约束 ────────────────────────────────────────────────
 *
 *   ① **绝不落库主诉原文**。
 *      分诊的输入是患者自己写的一句话（例如「下腹坠痛伴出血两周」）——
 *      那是最敏感的自由文本。本表**只存结论**（结论码 / 是否危急 / 科室名），
 *      因为看板只需要计数。
 *      📌 这是"数据最小化"的朴素版本：**不是"存了再脱敏"，而是根本不存**。
 *      它由验收测试钉住：往 triage_stat 里搜主诉片段必须搜不到（AC-P4-*）。
 *
 *   ② **不许无界增长**。
 *      分诊是**匿名入口**（还没挂号的人在用），意味着它最容易被脚本刷。
 *      所以照 `pruneTokens` / `pruneAttempts` 的"顺手 prune"手法：
 *      每次写入时清理超过 TTL 的行。
 *
 * ── 写入失败**不得影响分诊结果**（刻意的取舍，说清楚）──────────────────
 *   分诊是患者正在等的响应；统计是**旁路**。
 *   ⇒ 统计写失败时**吞掉异常**，只在日志体现，绝不让 `POST /triage` 变 500。
 *   ⚠ 代价：统计可能少记。这是**有意的**——为统计牺牲主流程是本末倒置。
 *     但"少了"必须在文档里说出来（见 P4-HANDOFF 的诚实边界）。
 */

package qingzhou

import std.collection.*

/* 分诊统计的保留天数（看板只看最近 14 天趋势 ⇒ 180 天足够）。 */
public let TRIAGE_STAT_TTL_DAYS: Int64 = 180

public class TriageStatRepo {
    private let db: DbBackend

    public init(db: DbBackend) {
        this.db = db
    }

    /*
     * 记一次分诊。
     *
     * ⚠ `complaint` 参数**刻意不存在** —— 签名里就没有它，
     *   于是"想记主诉"这件事在**类型层面**做不到（比注释约束硬）。
     *   本方法的全部输入都是**结论**：结论码、是否危急、科室名、是否截断。
     */
    public func record(reasonCode: String, redFlag: Bool, department: String,
                       truncated: Bool, source: String, now: Int64): Unit {
        try {
            db.exec("INSERT INTO triage_stat (created_at, source, reason_code, red_flag, " +
                    "department, truncated) VALUES (?, ?, ?, ?, ?, ?)",
                    [DbInt(now), DbStr(source), DbStr(reasonCode),
                     DbInt(if (redFlag) { 1 } else { 0 }), DbStr(department),
                     DbInt(if (truncated) { 1 } else { 0 })])
            prune(now)
        } catch (e: Exception) {
            /*
             * ⚠ **吞掉**（见文件头）：统计是旁路，不能把患者正在等的分诊响应弄成 500。
             *   但要**说出来**（日志），否则"统计悄悄不工作了"没人知道。
             */
            println("[WARN] 分诊统计写入失败（不影响分诊结果）：${e.message}")
        }
    }

    /* 清理陈旧统计（顺手 prune，返回删除行数）。 */
    public func prune(now: Int64): Int64 {
        let cutoff = now - TRIAGE_STAT_TTL_DAYS * 86400
        return db.exec("DELETE FROM triage_stat WHERE created_at < ?", [DbInt(cutoff)])
    }

    /* 当前统计行数（自检/测试用）。 */
    /*
 * ★ 2026-10-09：按 `source` 计数 —— 看板靠它报**真实的**模型调用次数。
 *
 * ⚠ 为什么复用本表而不是新建一张"模型调用表"：
 *   `triage_stat` 本就是"分诊这件事的留痕"，而 `source` 已经区分了
 *   `rules` / `model`。模型调用次数**就是** `source` 的分布 ——
 *   再建一张表会让同一件事有两份记录，而它们迟早不一致。
 *   📌 代价（如实记下）：本表**只覆盖分诊**，不含预问诊的模型调用。
 *     看板报数时必须**写清口径**，否则读者会以为那是全部调用。
 */
public func countBySource(src: String): Int64 {
    let rs = db.query("SELECT COUNT(*) FROM triage_stat WHERE source = ?", [DbStr(src)])
    if (rs.rowCount() == 0) {
        return 0
    }
    return rs.getInt(0, 0)
}

public func count(): Int64 {
        let rs = db.query("SELECT COUNT(*) FROM triage_stat", Array<DbValue>())
        if (rs.rowCount() > 0) {
            return rs.getInt(0, 0)
        }
        return 0
    }
}
