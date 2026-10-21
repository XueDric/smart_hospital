/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 *
 * triage_stat.cj —— 分诊结论留痕与排障聚合（只存得出指标所必需的最小集合）。
 * 约束：绝不落库主诉原文，triage_stat 没有主诉列（AC-P4-*）—— 数据最小化是根本不存，不是存了再脱敏。
 * 约束：写入失败必须吞掉，统计是旁路，不能把患者正在等的 POST /triage 弄成 500；代价是可能少记。
 * 约束：不许无界增长（匿名入口最易被脚本刷），每次写入顺手 prune 掉超过 TTL 的行。
 */

package qingzhou

import std.collection.*
/* 分位数要先排序，全局 sort 来自 std.sort。 */
import std.sort.*
/* 排障端点的 JSON 视图（`triageStatJson` / `triageCallJson`）。 */
import stdx.encoding.json.*

/* 分诊统计的保留天数（看板只看最近 14 天趋势 ⇒ 180 天足够）。 */
public let TRIAGE_STAT_TTL_DAYS: Int64 = 180

/* 采样与分组上限：分位数在内存里算（MySQL 没有 percentile 函数），不设样本上限等于让一次请求把整张表拉进内存。 */
public let TRIAGE_STAT_SAMPLE_DEFAULT: Int64 = 5000
public let TRIAGE_STAT_SAMPLE_MAX: Int64 = 20000
/* 分组数上限（`source` 只有 3 种取值；`model_name` 才是可能变多的那个）。 */
public let TRIAGE_STAT_GROUP_DEFAULT: Int64 = 20
public let TRIAGE_STAT_GROUP_MAX: Int64 = 100

/* request_id 上限 = 列宽 VARCHAR(64)：写侧与读侧必须用同一个常量截断，否则超长请求号反查必然 count = 0 而那一行又在库里。 */
public let TRIAGE_REQUEST_ID_MAX: Int64 = 64

/* 排障窗口最大跨度 366 天：再宽就该做预聚合表，这是界不是技术极限。 */
public let TRIAGE_STAT_WINDOW_MAX_SECS: Int64 = 366 * 86400

public class TriageStatRepo {
    private let db: DbBackend

    public init(db: DbBackend) {
        this.db = db
    }

    /*
     * 记一次分诊：入参全是结论（结论码/是否危急/科室名/是否截断），complaint 参数刻意不存在 —— 想记主诉在类型层面做不到。
     * 七个遥测参数同样没有一个是患者输入：requestId 来自 X-Request-Id，模型标识来自 ai_model 默认行，耗时与降级来自 AiCallResult。
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
                      * request_id 是唯一由客户端决定长度的入参：不截断的话超长请求头会让 INSERT 报 1406 并被下面的 catch 吞掉，等于整条不记；
                      * 截断后最坏是反查对不上号，但记录还在。写侧截断了，读侧就必须用同一个常量截断。
                      */
                     DbStr(previsitTruncateChars(requestId, TRIAGE_REQUEST_ID_MAX)), DbInt(modelId),
                     /* 列宽 VARCHAR(64)：中文降级原因动辄 30+ 字，在这里按字符截断，别让 MySQL 报 1406 被吞成"整条没记录"。 */
                     DbStr(previsitTruncateChars(modelName, 64)),
                     DbInt(promptRevision), DbInt(elapsedMs),
                     DbStr(previsitTruncateChars(degradeReason, 64)),
                     DbInt(if (usedKb) { 1 } else { 0 }),
                     /* ⚠ 与 modelName 同理：列宽 255，超长会被 MySQL 1406 吞成"整条不记"。 */
                     DbStr(previsitTruncateChars(kbDocIds, 255))])
            prune(now)
        } catch (e: Exception) {
            /* 吞掉异常：统计是旁路，不能把患者正在等的响应弄成 500；但要打日志，否则统计悄悄不工作没人知道。 */
            println("[WARN] 分诊统计写入失败（不影响分诊结果）：${e.message}")
        }
    }

    /* 清理陈旧统计（顺手 prune，返回删除行数）。 */
    public func prune(now: Int64): Int64 {
        let cutoff = now - TRIAGE_STAT_TTL_DAYS * 86400
        return db.exec("DELETE FROM triage_stat WHERE created_at < ?", [DbInt(cutoff)])
    }

    /*
     * 按 source 计数：模型调用次数就是 source 的分布，再建一张调用表会让同一件事有两份记录；代价是本表只覆盖分诊，不含预问诊。
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

/* 排障查询：返回的全部是调用事实，没有主诉原文、没有 patient_id / doctor_id / 手机号。 */

    /*
     * 取时间窗内样本、按时间倒序（limit 截断时留下的是最近的）；truncated = true 表示 p50/p95 只是最近 N 条的分位数，样本上限是为了不把整个窗口读进内存。
     */
    public func windowRows(from: Int64, to: Int64, limit: Int64): TriageStatWindow {
        let w = TriageStatWindow()
        /* LIMIT ? + 1：多取一行用来判断是否被截断，能取到第 limit+1 行就说明窗口里还有更早的样本。 */
        let rs = db.query(
            "SELECT id, created_at, source, reason_code, red_flag, department, truncated, " +
            "request_id, model_id, model_name, prompt_revision, elapsed_ms, degrade_reason, " +
            "used_kb, kb_doc_ids FROM triage_stat " +
            "WHERE created_at >= ? AND created_at <= ? " +
            "ORDER BY created_at DESC, id DESC LIMIT ?",
            [DbInt(from), DbInt(to), DbInt(limit + 1)])
        let n = rs.rowCount()
        /* 用 ArrayList 收集再 toArray()：仓颉 Array<T> 没有 add（与 schema.cj:32 的既有结论一致）。 */
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

    /* 按请求号反查：request_id 在库上没有唯一约束，返回数组而不是一行，否则遇到重复编号会悄悄只显示一条。 */
    public func callsByRequest(requestId: String, limit: Int64): Array<TriageCallRow> {
        let out = ArrayList<TriageCallRow>()
        /* 读侧用与写侧同一常量截断：否则超过 64 字符的请求号永远查不到，而那一行明明在库里。 */
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

/* 查询结果类型与聚合。 */

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

/* 一组聚合：degraded 只数 AI 失败，redFlag 是规则层故意短路，混在一起会让看板上的 AI 降级率虚高。 */
public class TriageStatGroup {
    public var bucket: String = ""
    public var total: Int64 = 0
    public var degraded: Int64 = 0
    public var redFlag: Int64 = 0
    public var p50Ms: Int64 = 0
    public var p95Ms: Int64 = 0
}

/* 降级原因 → 是否算 AI 失败：唯一判据，聚合与 JSON 都走这里；空串 = 真用上模型，RED_FLAG = 有意短路。 */
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
 * group_by 白名单是安全边界，不是参数校验的礼貌：非法值直接 400，不给"回退默认值继续查"（静默错误更难发现）；
 * 分桶目前在内存里做，但若将来把 GROUP BY 下推 SQL，这道闸门就是唯一挡在中间的墙。
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
 * 分位数用最近秩法：返回升序数组里第 ceil(p% × n) 个真实样本值。不做线性插值 —— 整数毫秒插值会造出一个从未发生过的耗时，
 * 排障时"日志里找不到这个数"会让结论可疑；空样本回 0，调用方看 total = 0。
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
 * 在仓颉里聚合而不下推 GROUP BY：分位数没有内置函数，样本已取回，再塞一套分组等于同一统计量有两个实现；limit 只截分组数。
 */
public func triageStatAggregate(rows: Array<TriageCallRow>, groupBy: String,
                                limit: Int64): (TriageStatGroup, Array<TriageStatGroup>) {
    let allMs = ArrayList<Int64>()
    let all = TriageStatGroup()
    /* 总体行的 bucket 用 "all" 而非空串：空串在 JSON 里与字段缺失长得一样。 */
    all.bucket = "all"
    /* 分组桶：用 HashMap 保序不需要，最后按 total 排即可。 */
    let buckets = HashMap<String, ArrayList<TriageCallRow>>()
    for (r in rows) {
        allMs.add(r.elapsedMs)
        /* 降级判据只有一条，走 triageDegradeIsFailure()；红线安全旁路（RED_FLAG）不计入 degraded，另计 redFlag。 */
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
    /* 用全局 sort() 而不是 数组.sort()：后者已 deprecated，构建要零警告。 */
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

/* 排障端点的 JSON 视图。 */
/*
 * 合规红线：排障端点比看板更接近敏感数据 —— 主诉原文永不存在（表里没这一列），不出现 patient_id / doctor_id / 手机号；
 * request_id 只是排障关联键，不是身份凭证；kb_doc_ids 只给文档 id，不给命中正文。
 */

/* 一组（或总体）→ JSON：degrade_rate 四舍五入 4 位；total = 用上模型 + degraded + red_flag。 */
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
    /* truncated = true 必须在界面上说出来：分组指标是样本上的，悄悄少算会让命中率下降这类结论失去依据。 */
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
    /* degraded 是冗余布尔（走同一判据），免得前端去记"空串 = 真用上模型"；RED_FLAG 另有 red_flag_bypass。 */
    o.put("degraded", JsonBool(triageDegradeIsFailure(r.degradeReason)))
    o.put("red_flag_bypass", JsonBool(triageDegradeIsRedFlagBypass(r.degradeReason)))
    o.put("used_kb", JsonBool(r.usedKb))
    o.put("kb_doc_ids", JsonString(r.kbDocIds))
    return o
}
