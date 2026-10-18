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
 *     但"少了"必须在文档里说出来（见 docs/PHASE-HANDOFFS.md 的遗留表）。
 */

package qingzhou

import std.collection.*
/*
 * ★ 2026-10-15（改进 7）：`Array.sort()` 来自 `std.sort`
 *   （分位数要先排序；见 `triagePercentile` 为什么用"最近秩"而不是插值）。
 */
import std.sort.*
/* 排障端点的 JSON 视图（`triageStatJson` / `triageCallJson`）。 */
import stdx.encoding.json.*

/* 分诊统计的保留天数（看板只看最近 14 天趋势 ⇒ 180 天足够）。 */
public let TRIAGE_STAT_TTL_DAYS: Int64 = 180

/*
 * 排障端点的采样与分组上限（改进 7）。
 *
 * ⚠ `TRIAGE_STAT_SAMPLE_MAX` 存在的理由：这个 Query 是"取最近 N 行到内存里算
 *   分位数"，**没有下推到 SQL**（MySQL 没有现成的 percentile 函数）。
 *   ⇒ 不设上限等于让一次请求把整张表拉进内存。
 *   取 20000：一天 2 万次分诊已经是相当大的量级，而 2 万行的排序在服务端
 *   是毫秒级的；再多就该上"预聚合表"而不是放开门槛。
 */
public let TRIAGE_STAT_SAMPLE_DEFAULT: Int64 = 5000
public let TRIAGE_STAT_SAMPLE_MAX: Int64 = 20000
/* 分组数上限（`source` 只有 3 种取值；`model_name` 才是可能变多的那个）。 */
public let TRIAGE_STAT_GROUP_DEFAULT: Int64 = 20
public let TRIAGE_STAT_GROUP_MAX: Int64 = 100

/*
 * `request_id` 的长度上限（= 列宽 VARCHAR(64)）。
 *
 * ★ 2026-10-16（复核 D2）：这个常量存在的唯一目的，是让**写侧与读侧用同一个数**。
 *   写侧截断、读侧不截断，就会出现"请求号超过 64 字符 ⇒ 按请求号反查 count = 0，
 *   而那一行其实在库里"—— 排障闭环刚好在最需要它的时候断
 *   （`X-Request-Id` 是客户端可控的，超长请求头迟早会遇到）。
 *   ⇒ 截断只写在**仓储内部**（`record()` 与 `callsByRequest()` 各一次），调用点不必记得。
 */
public let TRIAGE_REQUEST_ID_MAX: Int64 = 64

/*
 * 排障统计窗口的**最大跨度**（秒）= 366 天。
 *
 * ★ 2026-10-16（复核提示项）：`to` 允许填未来（无害），但跨度不设上限时
 *   "一次请求扫全表"只是少打几个字的事（采样上限限制了返回行数，
 *   限制不了扫描本身）。366 天是"再宽就该做预聚合表"的界，不是技术极限。
 */
public let TRIAGE_STAT_WINDOW_MAX_SECS: Int64 = 366 * 86400

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
     *
     * ★ 2026-10-15 增（改进 7）：七个**排障遥测**参数（全部带默认值 ⇒
     *   既有调用点与既有断言不受影响）。
     *
     * ⚠⚠ 这七个仍然**没有一个是患者输入**：
     *   `requestId` 来自 `X-Request-Id` 中间件、`modelId`/`modelName` 来自
     *   `ai_model` 的默认对话模型行、`promptRevision` 来自 `ai_setting.revision`、
     *   `elapsedMs`/`degradeReason` 来自 `AiCallResult`、`usedKb` 来自本次检索
     *   是否命中。主诉原文（`text`）**依然没有入口** ——
     *   "数据最小化"这条硬约束不会因为"要排障"而松动：
     *   排障要看的是**调用事实**（哪个模型、多久、为什么降级），
     *   而不是**患者说了什么**。
     */
    public func record(reasonCode: String, redFlag: Bool, department: String,
                       truncated: Bool, source: String, now: Int64,
                       requestId!: String = "",
                       modelId!: Int64 = 0,
                       modelName!: String = "",
                       promptRevision!: Int64 = 0,
                       elapsedMs!: Int64 = 0,
                       degradeReason!: String = "",
                       usedKb!: Bool = false,
                       kbDocIds!: String = ""): Unit {
        try {
            db.exec("INSERT INTO triage_stat (created_at, source, reason_code, red_flag, " +
                    "department, truncated, request_id, model_id, model_name, " +
                    "prompt_revision, elapsed_ms, degrade_reason, used_kb, kb_doc_ids) " +
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    [DbInt(now), DbStr(source), DbStr(reasonCode),
                     DbInt(if (redFlag) { 1 } else { 0 }), DbStr(department),
                     DbInt(if (truncated) { 1 } else { 0 }),
                     /*
                      * ⚠ `request_id` 是**唯一由客户端决定长度**的入参（`X-Request-Id` 请求头），
                      *   列宽只有 64（`TRIAGE_REQUEST_ID_MAX`）：不截断的话，一个超长请求头
                      *   就能让这行的 INSERT 报 1406、被下面的 catch 吞掉 ——
                      *   而"整条不记"恰好是想隐藏自己痕迹的人要的结果。
                      *   截断后最坏情况是"按请求号反查时对不上号"，但**记录还在**。
                      *   其余各列都由服务端常量或库内数据决定（source/reason_code 是常量、
                      *   department 来自 departments.name 本身 ≤64），不需要再截。
                      *
                      * ⚠⚠ **写侧截断了，读侧就必须用同一个常量截断**（2026-10-16 复核 D2）：
                      *   否则 `X-Request-Id` 超过 64 字符时，读侧拿完整值去等值匹配
                      *   必然 `count = 0`，而那一行其实在库里 —— 排障闭环刚好在最需要它的时候断。
                      *   `callsByRequest()` 内部已经按同一常量截断，调用点不必自己记得。
                     */
                     DbStr(previsitTruncateChars(requestId, TRIAGE_REQUEST_ID_MAX)), DbInt(modelId),
                     /*
                      * ⚠ 列宽是 VARCHAR(64)：模型名/降级原因都可能更长
                      *   （中文降级原因动辄 30+ 字）。**在这里按字符截断**，
                      *   而不是让 MySQL 报 1406（Data too long）——
                      *   后者会被下面的 catch 吞掉，表现是"这条分诊完全没有记录"，
                      *   比"原因被截短"严重得多。
                      */
                     DbStr(previsitTruncateChars(modelName, 64)),
                     DbInt(promptRevision), DbInt(elapsedMs),
                     DbStr(previsitTruncateChars(degradeReason, 64)),
                     DbInt(if (usedKb) { 1 } else { 0 }),
                     /* ⚠ 与 modelName 同理：列宽 255，超长会被 MySQL 1406 吞成"整条不记"。 */
                     DbStr(previsitTruncateChars(kbDocIds, 255))])
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

    /*
     * ===================== 改进 7：排障查询 =====================
     *
     * ⚠⚠ 本段返回的**全部是调用事实**，与写入侧同一条红线：
     *   没有主诉原文、没有 patient_id / doctor_id / 手机号。
     *   `TriageCallRow` 的字段就是 `triage_stat` 的列 ——
     *   而那张表**从来没有**主诉列（见文件头硬约束①）。
     */

    /*
     * 取一个时间窗内的样本（**按时间倒序** ⇒ `limit` 截断时留下的是"最近的"，
     * 而不是"最早的"；排障总是先关心刚刚发生的事）。
     *
     * ⚠ 为什么要 `limit`（而不是"窗口内全取"）：
     *   分诊是**匿名入口**，一天几千行很常见。
     *   分位数（p50/p95）是统计量，**样本足够多时取最近 N 条与取全窗口几乎一样**，
     *   而"把整个窗口读进内存"在排障时会把服务端内存拖垮 ——
     *   排障工具把系统搞挂是最不能接受的失败。
     *   ⇒ 代价如实说：`truncated = true` 时，返回的分位数是"最近 N 条样本的分位数"。
     */
    public func windowRows(from: Int64, to: Int64, limit: Int64): TriageStatWindow {
        let w = TriageStatWindow()
        /*
         * ⚠ `LIMIT ? + 1` 这一手是为了**判断有没有被截断**：
         *   多取一行，若能取到第 limit+1 行，就说明窗口里还有更早的样本。
         *   不这么做就只能"猜"（例如比较 COUNT(*) 与 size，那要多一次查询）。
         */
        let rs = db.query(
            "SELECT id, created_at, source, reason_code, red_flag, department, truncated, " +
            "request_id, model_id, model_name, prompt_revision, elapsed_ms, degrade_reason, " +
            "used_kb, kb_doc_ids FROM triage_stat " +
            "WHERE created_at >= ? AND created_at <= ? " +
            "ORDER BY created_at DESC, id DESC LIMIT ?",
            [DbInt(from), DbInt(to), DbInt(limit + 1)])
        let n = rs.rowCount()
        /*
         * ⚠ 用 `ArrayList` 收，最后 `toArray()`：仓颉的 `Array<T>` **没有 `add`**
         *   （实测报 `'add' is not a member of struct 'Array<...>'`），
         *   可增长的收集一律走 `ArrayList` —— 与 `schema.cj:32` 的既有结论一致。
         */
        let list = ArrayList<TriageCallRow>()
        var i: Int64 = 0
        while (i < n) {
            if (i >= limit) {
                w.truncated = true
                break
            }
            list.add(triageCallRowOf(rs, i))
            i = i + 1
        }
        w.rows = list.toArray()
        return w
    }

    /*
     * 按请求编号反查（`GET /admin/ai/triage-calls/:requestId`）。
     *
     * ⚠ 返回**一个数组**而不是一行：`request_id` 在库上**没有唯一约束**
     *   （中间件信任客户端传来的 `X-Request-Id` ⇒ 同一个值理论上可以被重复使用）。
     *   若这里假设"只有一行"，将来遇到重复编号时就会**悄悄只显示一条**，
     *   而排障最怕的就是"看到的不全"。多取几条（默认 20）反而更诚实。
     */
    public func callsByRequest(requestId: String, limit: Int64): Array<TriageCallRow> {
        let out = ArrayList<TriageCallRow>()
        /*
         * ★ 2026-10-16（复核 D2）：**读侧用与写侧同一个常量截断**。
         *   `record()` 写库前会把 `X-Request-Id` 截到 `TRIAGE_REQUEST_ID_MAX`，
         *   读侧若拿完整值去等值匹配，超过 64 字符的请求号永远查不到 ——
         *   而那一行明明在库里，排障的人只会看到"没有记录"。
         *   放在仓储内部做，调用点（`http_app.cj` 的 triage-calls 路由）不必记得。
         */
        let key = previsitTruncateChars(requestId, TRIAGE_REQUEST_ID_MAX)
        let rs = db.query(
            "SELECT id, created_at, source, reason_code, red_flag, department, truncated, " +
            "request_id, model_id, model_name, prompt_revision, elapsed_ms, degrade_reason, " +
            "used_kb, kb_doc_ids FROM triage_stat WHERE request_id = ? " +
            "ORDER BY id DESC LIMIT ?",
            [DbStr(key), DbInt(limit)])
        var i: Int64 = 0
        while (i < rs.rowCount()) {
            out.add(triageCallRowOf(rs, i))
            i = i + 1
        }
        return out.toArray()
    }
}

/* ===================== 改进 7：查询结果类型与聚合 ===================== */

/* 一行遥测（**只有调用事实**；字段与 `triage_stat` 的列一一对应）。 */
public class TriageCallRow {
    public var id: Int64 = 0
    public var createdAt: Int64 = 0
    public var source: String = ""
    public var reasonCode: String = ""
    public var redFlag: Bool = false
    public var department: String = ""
    public var truncated: Bool = false
    public var requestId: String = ""
    public var modelId: Int64 = 0
    public var modelName: String = ""
    public var promptRevision: Int64 = 0
    public var elapsedMs: Int64 = 0
    public var degradeReason: String = ""
    public var usedKb: Bool = false
    public var kbDocIds: String = ""
}

/* 查询窗口 + 是否被样本上限截断。 */
public class TriageStatWindow {
    public var rows: Array<TriageCallRow> = Array<TriageCallRow>()
    public var truncated: Bool = false
}

/*
 * 一组聚合（`bucket` 是分组键的取值；看板按它排序展示）。
 *
 * ★ 2026-10-16（复核提示项）：`degraded` 与 `redFlag` **分开计**。
 *   前者是"想调模型但没成功"（失败），后者是"规则层的**故意**短路"
 *   （命中危急征象就不该调模型）。混在一起会让看板上的"AI 降级率"虚高 ——
 *   把临床上有意跳过模型的安全旁路算成 AI 故障，指标就指向错误的方向。
 */
public class TriageStatGroup {
    public var bucket: String = ""
    public var total: Int64 = 0
    public var degraded: Int64 = 0
    public var redFlag: Int64 = 0
    public var p50Ms: Int64 = 0
    public var p95Ms: Int64 = 0
}

/*
 * 降级原因 → 是否算一次 **AI 失败**。
 *
 * ⚠ 唯一判据，`triageStatAggregate()`、行级 JSON、看板口径全部走这里 ——
 *   不要在别处再写一遍（"同一个统计量两份实现"是本仓反复踩过的病）。
 *   空串 = 真的用上了模型（成功）；`RED_FLAG` = 规则层有意短路（不是失败）。
 */
public func triageDegradeIsFailure(reason: String): Bool {
    return reason.size > 0 && reason != TR_RED_FLAG
}

/* 是否属于"命中危急征象、故意不调模型"的安全旁路。 */
public func triageDegradeIsRedFlagBypass(reason: String): Bool {
    return reason == TR_RED_FLAG
}

/* 一行结果集 → `TriageCallRow`（列顺序与上面两句 SELECT 严格一致）。 */
private func triageCallRowOf(rs: DbResultSet, i: Int64): TriageCallRow {
    let r = TriageCallRow()
    r.id = rs.getInt(i, 0)
    r.createdAt = rs.getInt(i, 1)
    r.source = rs.getString(i, 2)
    r.reasonCode = rs.getString(i, 3)
    r.redFlag = rs.getInt(i, 4) != 0
    r.department = rs.getString(i, 5)
    r.truncated = rs.getInt(i, 6) != 0
    r.requestId = rs.getString(i, 7)
    r.modelId = rs.getInt(i, 8)
    r.modelName = rs.getString(i, 9)
    r.promptRevision = rs.getInt(i, 10)
    r.elapsedMs = rs.getInt(i, 11)
    r.degradeReason = rs.getString(i, 12)
    r.usedKb = rs.getInt(i, 13) != 0
    r.kbDocIds = rs.getString(i, 14)
    return r
}

/*
 * `group_by` 的白名单。
 *
 * ⚠⚠ 这是**安全边界**，不是"参数校验的礼貌"。
 *
 * ★ 2026-10-16（复核纠错）：这里原先写着"分组列名要拼进 SQL（`GROUP BY` 不能用占位符）"
 *   —— **那是错的**，与实际实现不符：分组其实是在**内存里**做的
 *   （`triageStatBucketOf()` 取每行的键、`triageStatAggregate()` 用 `HashMap` 分桶，
 *   没有任何 `GROUP BY` 被拼进 SQL）。所以非法值在这里**不会**造成注入。
 *
 *   那白名单为什么还留着？两条：
 *   ① 非法值直接 400 而不是"回退默认值继续查" —— 后者会让拼错的看板请求
 *      看起来"成功"，数字却是别的维度的（静默错误比报错更难发现）；
 *   ② 万一将来有人把分桶下推到 SQL（`GROUP BY <列名>` 确实不能用占位符），
 *      这道闸门就是唯一挡在中间的墙 —— **注释不能替代码许下一个它没兑现的安全承诺**，
 *      否则下一个人会照着注释改代码，那时注入面才真的出现。
 */
public func triageStatGroupByOk(name: String): Bool {
    return name == "source" || name == "reason_code" || name == "model_name"
}

/* 一行的分组键取值（调用方必须先过 `triageStatGroupByOk`）。 */
private func triageStatBucketOf(r: TriageCallRow, groupBy: String): String {
    if (groupBy == "source") {
        return r.source
    }
    if (groupBy == "reason_code") {
        return r.reasonCode
    }
    return r.modelName
}

/*
 * 分位数（**最近秩法 / nearest-rank**）：返回升序数组里第 ceil(p% × n) 个值。
 *
 * ⚠ 为什么不用"线性插值"那种分位数：
 *   `elapsed_ms` 是**整数毫秒**，插值会造出一个**从未真实发生过**的耗时
 *   （例如实际是 120ms 与 130ms，插值给出 125ms）。
 *   排障时"这个数在日志里根本找不到"会让整条结论变得可疑。
 *   ⇒ 取一个**真实存在的样本值**，哪怕它稍微保守一点。
 *
 * ⚠ 空样本回 0：0 与"真实耗时 0ms"会混。这是**有意的取舍** ——
 *   调用方同时在 `total` 里给出样本量（`total = 0` 时 p50/p95 无意义），
 *   比在类型上再加一个 Option 更贴近这个接口的用途（看板直接画图）。
 */
public func triagePercentile(sorted: Array<Int64>, p: Int64): Int64 {
    let n = sorted.size
    if (n == 0) {
        return 0
    }
    /* 最近秩：rank = ceil(p × n / 100)，下标从 0 起 ⇒ 减一；上界夹到 n-1。 */
    var rank = (p * n + 99) / 100
    if (rank < 1) {
        rank = 1
    }
    if (rank > n) {
        rank = n
    }
    return sorted[rank - 1]
}

/*
 * 把窗口样本聚合成"总体 + 各分组"。
 *
 * ⚠ 为什么在**仓颉里**聚合而不是 `GROUP BY` 到 SQL：
 *   分位数在 MySQL 里没有内置函数（`PERCENTILE_CONT` 是别的库的），
 *   要么用变量模拟（版本相关、易错），要么把样本取回来自己算。
 *   样本本来就已经取回（见 `windowRows`），再往 SQL 里塞一套分组
 *   等于**同一个统计量有两个实现** —— 而它们迟早在边界上不一致。
 *
 * ⚠ `limit` 只截**分组数**（`ORDER BY total DESC` 取前几名），不截样本。
 *   看板要的是"哪几类最多"，不关心长尾里的每一类。
 */
public func triageStatAggregate(rows: Array<TriageCallRow>, groupBy: String,
                                limit: Int64): (TriageStatGroup, Array<TriageStatGroup>) {
    let allMs = ArrayList<Int64>()
    let all = TriageStatGroup()
    /*
     * 总体行的 bucket 给一个**有名字的**取值 "all"，不用空串：
     *   空串在 JSON 里与"字段缺失/没算出来"长得一样，看板想直接打印这一行时
     *   会印出一片空白；而总体行并不在 `groups` 数组里（它是 `overall` 字段），
     *   所以 "all" 不会与任何真实分组键混淆。
     */
    all.bucket = "all"
    /* 分组桶：用 HashMap 保序不需要，最后按 total 排即可。 */
    let buckets = HashMap<String, ArrayList<TriageCallRow>>()
    for (r in rows) {
        allMs.add(r.elapsedMs)
        /*
         * ⚠ "降级"的判据**只有一条**，且走 `triageDegradeIsFailure()`：
         *   不要写成 `source != "model"` —— 那样同一个统计量就有了两份实现
         *   （单次排障里的 `degraded` 布尔按降级原因算），
         *   将来 source 多一个取值时，看板上的行之和会与分组的小计对不上。
         * ★ 2026-10-16：红线安全旁路（`RED_FLAG`）**不计入** degraded，另计 `redFlag`。
         */
        if (triageDegradeIsFailure(r.degradeReason)) {
            all.degraded = all.degraded + 1
        }
        if (triageDegradeIsRedFlagBypass(r.degradeReason)) {
            all.redFlag = all.redFlag + 1
        }
        let key = triageStatBucketOf(r, groupBy)
        if (buckets.contains(key)) {
            buckets[key].add(r)
        } else {
            let l = ArrayList<TriageCallRow>()
            l.add(r)
            buckets[key] = l
        }
    }
    all.total = rows.size
    /*
     * ⚠ 用 `std.sort` 的**全局 `sort(数组)`**，不用 `数组.sort()`：后者在本版工具链
     *   已标记 `deprecated`（实测警告 "Use global function sort<T>(data: Array<T>...)"），
     *   而构建输出要保持零警告 —— 那正是"改动是否干净"的判据之一。
     */
    let allArr = allMs.toArray()
    sort(allArr)
    all.p50Ms = triagePercentile(allArr, 50)
    all.p95Ms = triagePercentile(allArr, 95)

    let groups = ArrayList<TriageStatGroup>()
    for ((key, list) in buckets) {
        let g = TriageStatGroup()
        g.bucket = key
        g.total = list.size
        let ms = ArrayList<Int64>()
        for (r in list) {
            ms.add(r.elapsedMs)
            /* 与总体行同一判据（见上面 `all.degraded` 处的注释）。 */
            if (triageDegradeIsFailure(r.degradeReason)) {
                g.degraded = g.degraded + 1
            }
            if (triageDegradeIsRedFlagBypass(r.degradeReason)) {
                g.redFlag = g.redFlag + 1
            }
        }
        let msArr = ms.toArray()
        sort(msArr)
        g.p50Ms = triagePercentile(msArr, 50)
        g.p95Ms = triagePercentile(msArr, 95)
        groups.add(g)
    }
    /* 见函数头注释：排序结果必须**确定性**（样本量降序，并列按 bucket 升序）。 */
    let sorted = groups.toArray()
    var i: Int64 = 0
    while (i < sorted.size) {
        var j = i + 1
        while (j < sorted.size) {
            let better = sorted[j].total > sorted[i].total ||
                (sorted[j].total == sorted[i].total && sorted[j].bucket < sorted[i].bucket)
            if (better) {
                let t = sorted[i]
                sorted[i] = sorted[j]
                sorted[j] = t
            }
            j = j + 1
        }
        i = i + 1
    }
    if (limit > 0 && sorted.size > limit) {
        let cut = ArrayList<TriageStatGroup>()
        var k: Int64 = 0
        while (k < limit) {
            cut.add(sorted[k])
            k = k + 1
        }
        return (all, cut.toArray())
    }
    return (all, sorted)
}

/* ===================== 改进 7：排障端点的 JSON 视图 ===================== */
/*
 * ── ★★ 合规红线（写在这里免得"顺手加个字段"）─────────────────────────────
 *   排障端点比看板**更接近敏感数据**（它就是为"这一次分诊到底发生了什么"而
 *   存在的），所以口径必须比看板更严：
 *     ① **主诉原文永不出现** —— `triage_stat` 表里根本没有这一列（机制性保证，
 *        不靠"记得别写"），所以这里的 JSON 连"忘了过滤"的机会都没有；
 *     ② 不出现 `patient_id` / `doctor_id` / 手机号 / 姓名等任何个人标识；
 *     ③ `request_id` 是**客户端请求头**（`X-Request-Id`）的值，不是患者数据 ——
 *        但它是谁给的就要说清楚：它是**排障用的关联键**，不能当作身份凭证；
 *     ④ `department` 是**科室名**（机构信息，与看板同口径）；
 *     ⑤ `kb_doc_ids` 只给**文档 id**，不给命中的正文片段
 *        （正文片段才是"知识库泄给非管理员"的真实风险面）。
 */

/*
 * 一个分组（或总体）→ JSON。`degrade_rate` 四舍五入到 4 位小数。
 *
 * ★ 2026-10-16（复核提示项）：`degraded` 只数 **AI 失败**（想调模型没成功），
 *   红线安全旁路另计 `red_flag` / `red_flag_rate` —— 三者关系是
 *   `total = 用上模型 + degraded + red_flag`（没有降级原因的其它 source 取值
 *   理论上不存在，但即使出现也只是落进"用上模型"那一列，不会算成失败）。
 */
public func triageStatGroupJson(g: TriageStatGroup): JsonObject {
    let o = JsonObject()
    o.put("bucket", JsonString(g.bucket))
    o.put("total", JsonInt(g.total))
    o.put("degraded", JsonInt(g.degraded))
    o.put("red_flag", JsonInt(g.redFlag))
    let rate = if (g.total > 0) {
        Float64(g.degraded) / Float64(g.total)
    } else {
        0.0
    }
    o.put("degrade_rate", JsonFloat(Float64(Int64(rate * 10000.0 + 0.5)) / 10000.0))
    let rfRate = if (g.total > 0) {
        Float64(g.redFlag) / Float64(g.total)
    } else {
        0.0
    }
    o.put("red_flag_rate", JsonFloat(Float64(Int64(rfRate * 10000.0 + 0.5)) / 10000.0))
    o.put("p50_ms", JsonInt(g.p50Ms))
    o.put("p95_ms", JsonInt(g.p95Ms))
    return o
}

/* 一次统计窗口 → JSON（总体 + 分组；`sampled` 与 `truncated` 一起看才有意义）。 */
public func triageStatWindowJson(w: TriageStatWindow, groupBy: String, from: Int64, to: Int64,
                                 sampleLimit: Int64, groupLimit: Int64): JsonObject {
    let agg = triageStatAggregate(w.rows, groupBy, groupLimit)
    let o = JsonObject()
    o.put("from", JsonInt(from))
    o.put("to", JsonInt(to))
    o.put("group_by", JsonString(groupBy))
    o.put("sample_limit", JsonInt(sampleLimit))
    o.put("group_limit", JsonInt(groupLimit))
    o.put("sampled", JsonInt(w.rows.size))
    /*
     * ⚠ `truncated = true` 时必须**在界面上说出来**：分组指标是在样本上算的，
     *   不是全量。悄悄少算会让"命中率下降了"这种结论失去依据。
     */
    o.put("truncated", JsonBool(w.truncated))
    o.put("overall", triageStatGroupJson(agg[0]))
    let arr = JsonArray()
    var i: Int64 = 0
    while (i < agg[1].size) {
        arr.add(triageStatGroupJson(agg[1][i]))
        i = i + 1
    }
    o.put("groups", arr)
    return o
}

/* 一次调用 → JSON（**全链路**：时间 / 结论 / 模型 / 模板版本 / 耗时 / 检索）。 */
public func triageCallJson(r: TriageCallRow): JsonObject {
    let o = JsonObject()
    o.put("id", JsonInt(r.id))
    o.put("created_at", JsonInt(r.createdAt))
    o.put("source", JsonString(r.source))
    o.put("reason_code", JsonString(r.reasonCode))
    o.put("red_flag", JsonBool(r.redFlag))
    o.put("department", JsonString(r.department))
    o.put("truncated", JsonBool(r.truncated))
    o.put("request_id", JsonString(r.requestId))
    o.put("model_id", JsonInt(r.modelId))
    o.put("model_name", JsonString(r.modelName))
    o.put("prompt_revision", JsonInt(r.promptRevision))
    o.put("elapsed_ms", JsonInt(r.elapsedMs))
    o.put("degrade_reason", JsonString(r.degradeReason))
    /* `degraded` 是"这一步**失败了**"的冗余布尔（走同一判据，见 triageDegradeIsFailure）：
       看板按它过滤，免得前端去记"空串 = 真用上了模型"这条口径。
       ★ 2026-10-16：`RED_FLAG`（命中危急征象、故意不调模型）**不再算降级**，
       它有自己的布尔 `red_flag_bypass` —— 否则"AI 失败率"会把安全旁路算进去。 */
    o.put("degraded", JsonBool(triageDegradeIsFailure(r.degradeReason)))
    o.put("red_flag_bypass", JsonBool(triageDegradeIsRedFlagBypass(r.degradeReason)))
    o.put("used_kb", JsonBool(r.usedKb))
    o.put("kb_doc_ids", JsonString(r.kbDocIds))
    return o
}
