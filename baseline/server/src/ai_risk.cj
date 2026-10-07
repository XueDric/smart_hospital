package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * 邀请风控分档（api-design §7.5）
 *
 * 契约：`GET /api/v1/members/pending` 的**每条记录**多一个 `risk` 字段：
 *     { "level": "low|medium|high", "reasons": ["…"], "source": "model|fallback" }
 *
 * ★ 三条设计决定（2026-10-06，经确认）：
 *
 *   ① **分档只影响呈现与排序，不影响审批动作。**
 *      **不做「低风险自动通过」** —— 按模型的判断自动批准一个人入社是**安全决策**，
 *      而且直接违反本模块的铁律「模型输出不得直接成为写库值」（spec D4）。
 *      高风险排前面 + 角标提醒，但**每一笔都要人点**。
 *
 *   ② **懒算 + 内存缓存**：在打开待审批列表时算，结果按 member id 缓存（进程级）。
 *      于是**每个申请人只花一次模型调用**，不是每次刷新都花。
 *      **不在注册流程里算** —— 注册必须快，不能让新用户等模型。
 *
 *   ③ **IP 不落库**：文档举例的「同一 IP 短时间内 5 次申请」需要把 IP 存进 Member，
 *      而 `Member` 上没有该字段（IP 只在注册时用于内存限流 `reg_fail`）。
 *      改用**现在就有**的三个信号：申请时间的聚集度 / 有无招募链接 / 待审批队列长度。
 *
 * ⚠ 锁纪律：`aiRiskFacts` 要求调用方**持 `s.lock`**（与 aiCandidateLines 同约定）；
 *   而**模型调用必须在锁外** —— handler 因此是「锁内取事实 → 锁外算分 → 锁内组装」三段。
 */

import std.collection.*
import std.sync.*
import stdx.encoding.json.*

/* 同窗口判定的宽度：10 分钟内的申请算"扎堆" */
let AI_RISK_WINDOW_SECS: Int64 = 600
/* 单次列表最多为多少个申请人调模型（防一次刷新打出一串付费调用） */
let AI_RISK_MAX_CALLS: Int64 = 5

/* 规则分档用到的全部事实（**全部来自现有字段**，无需改表） */
public class RiskFacts {
    /* 当前待审批总人数 */
    public var pendingTotal: Int64 = 0
    /* 与本人落在同一个 10 分钟窗口里的申请数（含本人） */
    public var sameWindow: Int64 = 0
    /* 是否来自招募链接（dept_hint > 0 ⇒ 是被人邀请来的） */
    public var fromInvite: Bool = false
    /* 已等待分钟数 */
    public var waitMinutes: Int64 = 0
}


/*
 * 进程级缓存：重启即失效，代价只是重算一次。
 *
 * ⚠ **它不是一个"设上限 + 自动淘汰"的结构** —— 此处曾误写成「与限流器同款」，
 *   而限流器有 `AI_RATE_PRUNE_AT` 会清理、这个缓存**没有**（2026-10-06 更正）。
 *   它的回收靠下面的 `aiRiskCacheRetain()`：每次刷新待审批列表时，清掉不在列表里的条目。
 */
var g_riskCache: HashMap<Int64, JsonObject> = HashMap<Int64, JsonObject>()
let g_riskLock: Mutex = Mutex()

/* 该成员是否已缓存过风控结果 */
public func aiRiskCached(memberId: Int64): Bool {
    g_riskLock.lock()
    try {
        return g_riskCache.contains(memberId)
    } finally {
        g_riskLock.unlock()
    }
}

public func aiRiskCacheGet(memberId: Int64): ?JsonObject {
    g_riskLock.lock()
    try {
        return g_riskCache.get(memberId)
    } finally {
        g_riskLock.unlock()
    }
}

func aiRiskCachePut(memberId: Int64, v: JsonObject): Unit {
    g_riskLock.lock()
    try {
        g_riskCache[memberId] = v
    } finally {
        g_riskLock.unlock()
    }
}

/*
 * 淘汰**已不在待审批列表里**的条目。**调用方不得持 `g_riskLock`**（本函数自己取）。
 *
 * ⚠ 2026-10-06 修（审计发现的真 bug）：此前这个缓存**只写入、从不淘汰**，
 *   于是**每个被评过一次的申请人都会永久留一条** —— 哪怕他早已通过审批、
 *   不再出现在待审批列表里。属于**无界增长**：单条很小（一个小对象），
 *   但没有任何机制回收它；而上面那句"与限流器同款"的注释还会让人以为有人管。
 *
 * 口径：**这个缓存只为待审批列表服务**，所以每次刷新列表后，不在列表里的条目即可清掉。
 * 成本是一次遍历（列表通常只有几十条），远低于它防住的那一次模型调用。
 */
public func aiRiskCacheRetain(keep: HashSet<Int64>): Unit {
    g_riskLock.lock()
    try {
        let doomed = ArrayList<Int64>()
        for ((k, _v) in g_riskCache) {
            if (!keep.contains(k)) {
                doomed.add(k)
            }
        }
        for (k in doomed) {
            g_riskCache.remove(k)
        }
    } finally {
        g_riskLock.unlock()
    }
}


/*
 * 采集事实。**调用方必须持 `s.lock`**。
 * 注意这里**不读 IP** —— 它没有落库（见文件头的决定 ③）。
 */
public func aiRiskFacts(s: Store, m: Member, now: Int64): RiskFacts {
    let f = RiskFacts()
    for ((_, x) in s.members) {
        if (x.status != "pending") {
            continue
        }
        f.pendingTotal += 1
        /* 按 joined_at 的窗口聚集度判断"扎堆申请" */
        let diff = if (x.joined_at > m.joined_at) { x.joined_at - m.joined_at } else { m.joined_at - x.joined_at }
        if (diff <= AI_RISK_WINDOW_SECS) {
            f.sameWindow += 1
        }
    }
    f.fromInvite = (m.dept_hint > 0)
    if (m.joined_at > 0 && now > m.joined_at) {
        f.waitMinutes = (now - m.joined_at) / 60
    }
    return f
}

/* 给模型看的事实文本（三段，复用既有的 aiPromptInviteRisk 签名） */
public func aiRiskApplicantFacts(m: Member, f: RiskFacts): String {
    return "姓名：${m.name}\n等待时长：${f.waitMinutes} 分钟\n当前待审批总人数：${f.pendingTotal}"
}

public func aiRiskLinkFacts(f: RiskFacts): String {
    if (f.fromInvite) {
        return "该申请带有招募链接带来的部门预填（说明是被现有成员邀请来的）"
    }
    return "该申请**没有**招募链接来源（可能是自行找到注册口令）"
}

public func aiRiskSourceFacts(f: RiskFacts): String {
    /* ⚠ 这一格原设计叫 ipFacts；因为 IP 不落库，现在装的是**时间聚集度**。
       字段名保留是为了不改 aiPromptInviteRisk 的签名。 */
    return "与本人落在同一个 ${AI_RISK_WINDOW_SECS / 60} 分钟窗口内的申请数：${f.sameWindow}"
}

/*
 * 规则兜底（**不依赖模型**，spec §5.5 的 D2：兜底不得为空）。
 *
 * 分档口径（有意保守 —— 宁可判高一档让人多看一眼，也不要漏掉）：
 *   · 同一窗口 ≥3 人扎堆，且**没有**邀请链接 → high
 *   · 同一窗口 ≥2 人，或没有邀请链接 → medium
 *   · 其余 → low
 */
public func aiRiskFallback(f: RiskFacts): JsonObject {
    let reasons = JsonArray()
    var level = "low"
    if (f.sameWindow >= 3 && !f.fromInvite) {
        level = "high"
        reasons.add(JsonString("${AI_RISK_WINDOW_SECS / 60} 分钟内有 ${f.sameWindow} 人扎堆申请，且这批申请没有招募链接来源"))
    } else if (f.sameWindow >= 2) {
        level = "medium"
        reasons.add(JsonString("${AI_RISK_WINDOW_SECS / 60} 分钟内有 ${f.sameWindow} 人同时申请"))
    } else if (!f.fromInvite) {
        level = "medium"
        reasons.add(JsonString("该申请没有招募链接来源，无法核对邀请人"))
    } else {
        reasons.add(JsonString("来自招募链接、且同一时段没有扎堆申请"))
    }
    if (f.waitMinutes >= 60) {
        reasons.add(JsonString("已等待 ${f.waitMinutes} 分钟，建议尽快处理"))
    }
    let o = JsonObject()
    jPutStr(o, "level", level)
    o.put("reasons", reasons)
    jPutStr(o, "source", AI_SOURCE_FALLBACK)
    return o
}

/* 把模型给的分档翻成对外形状（**只接受 low/medium/high**，其余一律丢弃回落兜底） */
func aiRiskFromModel(obj: JsonObject, f: RiskFacts): ?JsonObject {
    let lv = match (jsonGetStr(obj, "level")) {
        case Some(v) => v
        case None => ""
    }
    if (lv != "low" && lv != "medium" && lv != "high") {
        return None
    }
    let reasons = JsonArray()
    match (jsonGetArray(obj, "reasons")) {
        case Some(a) =>
            var i: Int64 = 0
            while (i < a.size() && i < 5) {
                match (a[i]) {
                    case s: JsonString => reasons.add(s)
                    case _ => ()
                }
                i += 1
            }
        case None => ()
    }
    if (reasons.size() == 0) {
        /* 没给理由就不采信它的分档 —— 让用户看一个没有依据的"高风险"是误导 */
        return None
    }
    let o = JsonObject()
    jPutStr(o, "level", lv)
    o.put("reasons", reasons)
    jPutStr(o, "source", AI_SOURCE_MODEL)
    return o
}

/*
 * 某个申请人的风控分档。**调用方必须处于锁外**（内部会调模型）。
 *
 * 命中缓存直接返回；否则调一次模型，失败/不合法就回落规则兜底。
 * **本函数永不抛异常、永不返回空** —— 列表接口不能因为风控而失败。
 */
public func pendingRiskOf(m: Member, f: RiskFacts, ai: ?AiClient, modelBudgetUsed: Bool): JsonObject {
    match (aiRiskCacheGet(m.id)) {
        case Some(cached) => return cached
        case None => ()
    }
    var result = aiRiskFallback(f)
    match (ai) {
        case Some(c) =>
            if (modelBudgetUsed) {
                /* 本次刷新的模型调用名额已用完 —— 剩下的走兜底（不是错误，是预算） */
                result = aiRiskFallback(f)
            } else {
                let prompt = aiPromptInviteRisk(aiRiskApplicantFacts(m, f), aiRiskLinkFacts(f),
                                                aiRiskSourceFacts(f))
                let r = c.call(prompt, aiSchemaInviteRisk(), AI_KEYS_RISK, aiRiskFallback(f))
                if (r.isModel()) {
                    match (aiRiskFromModel(r.obj, f)) {
                        case Some(v) =>
                            /* 把 note 也带上，前端可据 source 弱化样式 */
                            if (r.note.size > 0) {
                                jPutStr(v, "note", r.note)
                            }
                            result = v
                        case None =>
                            result = aiRiskFallback(f)
                    }
                } else {
                    let fb = aiRiskFallback(f)
                    if (r.note.size > 0) {
                        jPutStr(fb, "note", r.note)
                    }
                    result = fb
                }
            }
        case None => ()
    }
    aiRiskCachePut(m.id, result)
    return result
}

/* 渲染排序用：high=0 / medium=1 / low=2（**只影响排序，不影响审批动作**） */
public func aiRiskRank(r: JsonObject): Int64 {
    let lv = match (jsonGetStr(r, "level")) {
        case Some(v) => v
        case None => "low"
    }
    if (lv == "high") {
        return 0
    }
    if (lv == "medium") {
        return 1
    }
    return 2
}
