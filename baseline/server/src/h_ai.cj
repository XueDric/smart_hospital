package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * Part 7 · AI 能力的 HTTP handler（api-design.md Part 7）
 *
 * ⚠ 三段式，顺序不能变（llm-client-spec §6.4）：
 *     ① 认证（requireActive **内部会加 s.lock**，所以必须在锁外调用）
 *     ② 锁内：**只取数**，立刻出锁
 *     ③ 锁外：调模型（LlmClient 全程不碰锁）
 *     ④ 审计 + 响应
 *
 *   ⚠ 绝对不要在 `s.lock` 持有期间调用 `ai.call(...)`：
 *      实测锁内做 I/O 会把并发彻底串行化（4×2s：8088ms vs 锁外 2034ms）。
 *
 * 口径：**永不返回 5xx**。模型不可用一律 200 + data.source != "model"。
 */

import std.collection.*
import std.sync.*
import std.time.*
import stdx.encoding.json.*

/* ===================== 共用 ===================== */

/* ===================== AI-6：成员级节流 ===================== */

/*
 * 为什么必须有：
 *   `api-design.md` 三处（§1.3 错误码表、§7.6、前端指南）都宣称有「成员级智能调用节流
 *   （防刷、防费用失控）」，但代码里原先**只有** `Semaphore(maxConcurrent)` —— 那是
 *   **限并发、不限速率**；`budgetMs` 也只是单次调用的时间预算。于是任意 active 账号
 *   循环 POST /api/v1/ai/ask（该接口除登录外不要求任何权限）就能无限调用，
 *   每次 1~2 次出站请求，全是真金白银。
 *
 * 口径：按**成员 id** 分桶（与文档一致，不是按 IP）。固定窗口即可 —— 这里要的是
 * 「不能让一个人把额度刷爆」，不是精确的令牌桶。
 *
 * 为什么放模块级而不是 Store：这是**短命的运行态计数**，不需要持久化；
 * 重启重置窗口是可接受的语义（而且不必碰 MySQL 落盘路径）。
 */
/*
 * F-5（2026-10-05 深夜）：窗口必须用**单调时钟**（毫秒），不能用墙钟 `nowEpoch()`。
 * 时钟回拨 Δ 会让所有时间戳的"年龄"变成负数 -> 该成员被 429 长达 Δ，
 * 且 `aiRateStale` 永不返回 true -> 清理永不发生、表只涨；前跳则额度被提前清空。
 * 工具链里本来就有单调时钟（框架 timeout.cj 用的就是 MonoTime）。
 */
let AI_RATE_WINDOW_MS: Int64 = 60 * 1000
let AI_RATE_LIMIT: Int64 = 20
/* 超过这个成员数就顺手清掉过期条目，避免 map 无限增长 */
let AI_RATE_PRUNE_AT: Int64 = 512

/*
 * R-9 根因修复（2026-10-05 深夜）：**固定窗口 -> 滑动窗口**。
 *
 * 固定窗口（20 次 / 60 秒）的致命处：窗口一到就清零重来，于是**单次调用越慢，
 * 一个窗口内能累积到的次数越少**。设单次耗时 T，一个窗口最多数到约 60/T，
 * 要够到 20 必须 T 小于约 3 秒 —— T = 4 秒时最多数到约 15 次就滚窗清零，
 * **打一万次也不会 429**。评审 A/B 实测（同一二进制、同一代码路径，唯一变量是桩延迟）：
 *   桩 0 ms    -> 200 x 20 + 429 x 5
 *   桩 4000 ms -> 200 x 25 + 429 x 0（101 秒 约 14.9 次/分，本来就在额度内）
 * 而这条限流的设计目标恰恰是**防费用失控** —— 在最该拦住的那种场景下是漏的。
 *
 * 滑动窗口只保留最近 60 秒内的时间戳，于是「20 次 / 60 秒」**在任意延迟下都成立**。
 */
class AiRateEntry {
    /* 窗口内的调用时间戳（秒），只保留 now - 60s 之内的 */
    public var stamps: ArrayList<Int64> = ArrayList<Int64>()
}

/*
 * F-5：单调毫秒。`MonoTime` 本身只能相减得到 `Duration`（`toMilliseconds()` 在
 * Duration 上，不在 MonoTime 上），所以以一个**模块级基准点**为原点 ——
 * 这里只需要"相对时间差"，不需要绝对时刻。
 */
let g_aiMonoBase: MonoTime = MonoTime.now()

func aiMonoMs(): Int64 {
    return (MonoTime.now() - g_aiMonoBase).toMilliseconds()
}

/* 该成员的记录是否已完全过期（可被清理） */
func aiRateStale(e: AiRateEntry, now: Int64): Bool {
    for (t in e.stamps) {
        if (now - t < AI_RATE_WINDOW_MS) {
            return false
        }
    }
    return true
}

var g_aiRate: HashMap<Int64, AiRateEntry> = HashMap<Int64, AiRateEntry>()
let g_aiRateLock: Mutex = Mutex()

/*
 * R-9（2026-10-05 晚修）：节流**只在真的要调模型时**计数，且移到授权/校验之后。
 *
 * 原先 `aiRateCheck(actor.id)` 是四个 handler 里 `requireActive` 之后的**第一句**，
 * 而 `requireAccess` / `v.done()` / `reqObj` 都在其后。三个后果：
 *   · 本该 403 / 400 的请求可能先拿到 **429** —— 把 AI-10 刚恢复的
 *     「认证 → 授权 → 校验」顺序从另一侧又破坏了；
 *   · 畸形 / 无权请求也消耗配额；
 *   · `ai == None`（纯本地兜底、**零成本**）同样被限流，纯属误伤。
 */
func aiRateCheckIfEnabled(ai: ?AiClient, memberId: Int64): Unit {
    match (ai) {
        case Some(_) => aiRateCheck(memberId)
        case None => ()
    }
}

/*
 * F-2（2026-10-05 深夜）：**只读的削峰闸门**（peek，不消耗额度）。
 *
 * 消耗额度的检查点在锁区间之**后**，而被限流的请求在拿到 429 之前，
 * 仍要在 `s.lock` 里跑约 2 x 成员 x 任务 次迭代
 * （`aiCandidateLines` + `aiFallbackOwner` + `aiPlanHistoryLines`；200 成员 x 4000 任务
 * 约 160 万次/请求）—— 单个已认证成员就能让**全服务**在全局锁上排队。
 *
 * 所以在 `requireActive` 之后先"看一眼"：已满就直接 429，**不消耗、不进锁**。
 *
 * 代价（已知并接受）：已被限流的成员会**先看到 429 再看到 403** ——
 * 与 R-9「比 403 晚」的初衷部分相反，但比丢掉削峰划算。
 */
func aiRatePeekIfEnabled(ai: ?AiClient, memberId: Int64): Unit {
    match (ai) {
        case Some(_) =>
            let now = aiMonoMs()
            g_aiRateLock.lock()
            try {
                match (g_aiRate.get(memberId)) {
                    case Some(e) =>
                        var live: Int64 = 0
                        for (t in e.stamps) {
                            if (now - t < AI_RATE_WINDOW_MS) {
                                live += 1
                            }
                        }
                        if (live >= AI_RATE_LIMIT) {
                            throw apiErrMsg("AI_RATE_LIMITED", "智能请求过于频繁，请稍后再试")
                        }
                    case None => ()
                }
            } finally {
                g_aiRateLock.unlock()
            }
        case None => ()
    }
}

/*
 * F-1（2026-10-05 深夜）：**退还**刚消耗的那个时间戳。
 *
 * `overloaded`（并发闸门满）与 `too_large`（prompt 超 maxRequestBytes 自拒）
 * 这两条路径**一个出站请求都不发** —— 与 `ai == None` 同为"零成本"，
 * 但模块只排除了后者。实测：25 并发里 20 个 200 中只有 4 个真花钱，
 * 却吃掉了全部 20 个额度（"20 个额度换 4 次真实调用"）。
 */
func aiRateRefundIfFree(memberId: Int64, r: AiResult): Unit {
    if (r.outcome == "overloaded" || r.status == -413) {
        g_aiRateLock.lock()
        try {
            match (g_aiRate.get(memberId)) {
                case Some(e) =>
                    /* 去掉最后一个时间戳（刚加的那个）。不用 remove(at:) —— 重建更稳。 */
                    if (e.stamps.size > 0) {
                        let keep = ArrayList<Int64>()
                        var i: Int64 = 0
                        while (i < e.stamps.size - 1) {
                            keep.add(e.stamps[i])
                            i += 1
                        }
                        e.stamps = keep
                    }
                case None => ()
            }
        } catch (ex: Exception) {
            /* 退还失败不是错误：宁可少退一个额度，也不能让请求 500 */
        } finally {
            g_aiRateLock.unlock()
        }
    }
}

/* 计数 +1；超限抛 AI_RATE_LIMITED（429）。 */
func aiRateCheck(memberId: Int64): Unit {
    let now = aiMonoMs()
    g_aiRateLock.lock()
    try {
        /*
         * R-1（2026-10-05 晚修）：**不能边遍历边删**。
         * 原先这里直接在 `for ((k, e) in g_aiRate)` 里 `g_aiRate.remove(k)` ——
         * 用项目自己的 cjc 1.2.0 写探针实测：`THROWS after removed=1`
         * （仓颉 HashMap 迭代中删除会抛，且 `e.message` 为空）。
         * 而本函数是 4 个 handler 里 `requireActive` 之后的**第一句、且不在任何 try 内**
         * → 异常穿到框架 → 按非 ApiError 处理 → **500 INTERNAL**，直接打破
         * 「永不返回 5xx」的契约（api-design.md §7）。
         * 触发条件是进程内有 >512 个不同成员调用过 AI、且有一条记录已过窗口 ——
         * 在目标规模下是**持续的间歇 500**，不是一次性。
         *
         * 照仓库既有正确写法（h_auth.cj 的 pruneLoginFail / pruneIpFail）：
         * 先收进 doomed，**循环外**再删。
         *
         * 另外单独包一层 try：清理是"顺手的卫生工作"，它出任何问题都不影响限流主逻辑，
         * 更不允许逃出去变成 500。注意**不能**把整个函数包进 catch ——
         * 那会把下面那句故意的 `AI_RATE_LIMITED` 一起吞掉。
         */
        try {
            if (g_aiRate.size > AI_RATE_PRUNE_AT) {
                let doomed = ArrayList<Int64>()
                for ((k, e) in g_aiRate) {
                    if (aiRateStale(e, now)) {
                        doomed.add(k)
                    }
                }
                for (k in doomed) {
                    g_aiRate.remove(k)
                }
            }
        } catch (e: Exception) {
            /* F-10：清理失败不是错误（宁可多留几条过期记录，也不能让请求 500），
               但**不能完全无声** —— 否则将来清理真出问题会表现为"表悄悄涨"，
               运维拿不到任何信号。 */
            println("[WARN] ai rate prune 失败：${e.message}")
        }
        match (g_aiRate.get(memberId)) {
            case Some(e) =>
                /* 先滑出窗口，再判额度 —— 判据与调用快慢**无关** */
                let keep = ArrayList<Int64>()
                for (t in e.stamps) {
                    if (now - t < AI_RATE_WINDOW_MS) {
                        keep.add(t)
                    }
                }
                e.stamps = keep
                if (e.stamps.size >= AI_RATE_LIMIT) {
                    throw apiErrMsg("AI_RATE_LIMITED", "智能请求过于频繁，请稍后再试")
                }
                e.stamps.add(now)
            case None =>
                let e = AiRateEntry()
                e.stamps.add(now)
                g_aiRate[memberId] = e
        }
    } finally {
        g_aiRateLock.unlock()
    }
}

/* 把 AiResult 的元信息装进响应 data（各 handler 再平铺自己的业务字段）。 */
func aiPutMeta(d: JsonObject, r: AiResult): Unit {
    jPutStr(d, "source", r.source)
    if (r.note.size > 0) {
        jPutStr(d, "note", r.note)
    }
}

/* 把字符串数组字段从模型输出里搬到响应（模型输出只允许出现 schema 声明过的键）。 */
func aiPutStrArr(d: JsonObject, obj: JsonObject, key: String): Unit {
    let arr = JsonArray()
    match (jsonGetArray(obj, key)) {
        case Some(src) =>
            var i: Int64 = 0
            while (i < src.size()) {
                match (src[i]) {
                    case s: JsonString => arr.add(s)
                    case _ => ()
                }
                i += 1
            }
        case None => ()
    }
    d.put(key, arr)
}

/*
 * F-6（2026-10-05 深夜）：模型给的 `due_at` / `suggest_send_at` 必须是
 * **ISO 8601 带时区**（api-design §7.1 / §7.2），而原先用 aiPutStrOrNull **原样透传**
 * —— 模型回"明天下午"就直接送到客户端。不合规就**丢弃该键**（比透传脏值好）。
 */
func aiIsIso8601(s: String): Bool {
    /* 形如 2026-10-20T18:00:00+08:00 或 ...Z；只做**形状**校验，不解析日历合法性 */
    if (s.size < 20) {
        return false
    }
    let b = s.toArray()
    if (b[4] != UInt8(45) || b[7] != UInt8(45)) { return false }
    if (b[10] != UInt8(84)) { return false }
    if (b[13] != UInt8(58) || b[16] != UInt8(58)) { return false }
    var j: Int64 = 0
    while (j < 4) {
        if (b[j] < UInt8(48) || b[j] > UInt8(57)) { return false }
        j += 1
    }
    var i: Int64 = 11
    while (i < 17) {
        if (i != 13 && i != 16) {
            if (b[i] < UInt8(48) || b[i] > UInt8(57)) { return false }
        }
        i += 1
    }
    /* 末尾必须是 Z（UTC）或 +hh:mm / -hh:mm */
    if (b[b.size - 1] == UInt8(90)) { return true }
    if (s.size >= 25 && (b[19] == UInt8(43) || b[19] == UInt8(45)) && b[22] == UInt8(58)) {
        return true
    }
    return false
}

func aiPutIsoOrNull(d: JsonObject, obj: JsonObject, key: String): Unit {
    match (jsonGetStr(obj, key)) {
        case Some(s) =>
            if (aiIsIso8601(s)) {
                jPutStr(d, key, s)
            } else {
                jPutNull(d, key)
            }
        case None => jPutNull(d, key)
    }
}

func aiPutStrOrNull(d: JsonObject, obj: JsonObject, key: String): Unit {
    match (jsonGetStr(obj, key)) {
        case Some(s) => jPutStr(d, key, s)
        case None => jPutNull(d, key)
    }
}

/* AI 未启用时的统一响应：这一条路**不能报错**，只是没有建议。 */

/*
 * 审计：只记元信息，**绝不记密钥与完整 prompt**（spec §7 S1/S7）。
 *
 * ⚠ AI-3（2026-10-05 修）：`audit()` 的契约是「**在锁内调用**」—— 它直接
 * `s.audit_pending.add(line)`，自己不加锁；而刷盘侧是在锁内**换数组引用**
 * （`store_persistence.cj`：`auditLines = s.audit_pending` → 换新的 ArrayList）。
 * 锁外 add 可能落进已被换下的旧数组 → **那行审计永远写不进 audit.log**。
 * 所以这里自己取一次短锁。慢的出站调用仍在锁外，不冲突。
 */
func aiAudit(s: Store, actorId: Int64, feature: String, r: AiResult): Unit {
    /* R-11：llm-client-spec 要求每次调用记 elapsedMs / outcome / **status** /
       attempts / **endpoint 主机名**；原先只有前两个半。 */
    let note = "outcome=${r.outcome} source=${r.source} status=${r.status} " +
        "attempts=${r.attempts} ms=${r.elapsedMs} host=${aiHostOnly(aiOptionsCurrent().endpoint)}"
    s.lock.lock()
    try {
        audit(s, actorId, "ai_" + feature, 0, note)
    } finally {
        s.lock.unlock()
    }
}

/* 候选负责人名单（供模型挑人）。**模型只能从这份名单里选**，返回后还要再校验。 */
func aiCandidateIds(s: Store, deptId: Int64): HashSet<Int64> {
    let ids = HashSet<Int64>()
    for ((_, m) in s.members) {
        if (m.status == "active" && m.dept_id == deptId) {
            ids.add(m.id)
        }
    }
    return ids
}

func aiCandidateLines(s: Store, deptId: Int64): String {
    var out = ""
    for ((_, m) in s.members) {
        if (m.status != "active" || m.dept_id != deptId) {
            continue
        }
        var inflight: Int64 = 0
        for ((_, t) in s.tasks) {
            if (t.owner_id == m.id && t.deleted_at == 0 && t.status != "done") {
                inflight += 1
            }
        }
        out += "- id=${m.id} 姓名=${m.name} 角色=${m.role} 在途任务=${inflight}\n"
    }
    if (out.size == 0) {
        out = "（本部门暂无可选成员）"
    }
    return out
}

/*
 * AI-5：该课题下的历史任务，作为「以前的活动信息」喂给模型。
 * **调用方必须持锁**。只取最近若干条，避免把 prompt 撑爆。
 */
func aiPlanHistoryLines(s: Store, planId: Int64): String {
    var out = ""
    var count: Int64 = 0
    for ((_, t) in s.tasks) {
        if (t.deleted_at != 0 || t.plan_id != planId) {
            continue
        }
        if (count >= 8) {
            break
        }
        out += "- ${t.title}（状态 ${t.status}）\n"
        count += 1
    }
    return out
}

/* 规则兜底：本部门在途任务最少的那个人（并列时 id 小的优先，保证可复现）。 */
func aiFallbackOwner(s: Store, deptId: Int64): (Int64, String, Int64) {
    var bestId: Int64 = 0
    var bestName = ""
    var bestLoad: Int64 = -1
    for ((_, m) in s.members) {
        if (m.status != "active" || m.dept_id != deptId) {
            continue
        }
        var load: Int64 = 0
        for ((_, t) in s.tasks) {
            if (t.owner_id == m.id && t.deleted_at == 0 && t.status != "done") {
                load += 1
            }
        }
        if (bestLoad < 0 || load < bestLoad || (load == bestLoad && m.id < bestId)) {
            bestLoad = load
            bestId = m.id
            bestName = m.name
        }
    }
    return (bestId, bestName, bestLoad)
}

/* 把任务的目标事实交给 can()。 */
func aiTargetOfTask(t: Task): Target {
    let tgt = Target()
    tgt.dept_id = t.dept_id
    tgt.owner_id = t.owner_id
    tgt.creator_id = t.created_by
    return tgt
}

/* ===================== 7.1 任务建议 ===================== */

public func handleAiTaskSuggest(ctx: Context, s: Store, ai: ?AiClient): Unit {
    let actor = requireActive(ctx, s)
    /* F-2：只读削峰 —— 已满就直接 429，不消耗额度、也不进 s.lock 做那 160 万次迭代 */
    aiRatePeekIfEnabled(ai, actor.id)
    let body = reqObj(ctx)
    let title = reqStrOr(body, "title", "")
    let desc = reqStrOr(body, "desc", "")
    let planId = reqIntOr(body, "plan_id", 0)
    let reqDept = reqIntOr(body, "dept_id", 0)
    let v = V()
    v.need("title", title, "标题不能为空")
    /* AI-8：AI 接口原先没有任何长度闸门（limits.cj 的其它接口都有）。 */
    lenCheck(v, "title", "标题", title, MAX_TITLE_BYTES)
    lenCheck(v, "desc", "描述", desc, MAX_DESC_BYTES)
    /* R-7：负数原先被 `if (planId > 0)` 静默忽略 —— 客户端笔误会被当成"没传课题"，
       而实际请求的是另一个课题的历史。显式判非法。 */
    v.check("plan_id", planId >= 0, "plan_id 不能为负")

    /* ② 锁内：只取数 + 顺手构造**规则的兜底对象**（兜底很便宜，不必用闭包延迟；
       而且仓颉不允许「捕获可变变量的 lambda」当值传递，闭包式兜底本来就写不了） */
    var deptId = reqDept
    var deptName = ""
    var candidates = ""
    var candIds = HashSet<Int64>()
    var history = ""
    var fallback = JsonObject()
    s.lock.lock()
    try {
        if (deptId == 0) {
            deptId = actor.dept_id
        }
        /* 权限：与创建任务同权 */
        let tgt = Target()
        tgt.dept_id = deptId
        requireAccess(actor, Action.CreateTask, tgt)
        /*
         * AI-10（2026-10-05 修）：**先授权、再校验入参**。
         * 原先 `v.done()` 在授权之前，普通成员发 `{"title":""}` 会拿到
         * 400 VALIDATION_FAILED，而真实原因是**无权**建任务 —— 既不准确也泄露了
         * "这个接口认这个字段"。本仓已为这个顺序立过规矩
         * （h_task.cj：「先认证 → 再授权 → 最后校验入参」）。
         */
        v.done()
        match (s.departments.get(deptId)) {
            case Some(dp) => deptName = dp.name
            case None => deptName = "（未知部门）"
        }
        candidates = aiCandidateLines(s, deptId)
        candIds = aiCandidateIds(s, deptId)
        /*
         * AI-5（2026-10-05 修）：`plan_id` 原先**读了不用** —— prompt 模板里
         * 「部门过往同类任务（供参考，可能为空）」那一段永远是「（无）」，
         * 而不带 plan_id 的请求与带了它的输出**逐字节相同**。
         * 现在真的把它接上（顺便校验课题存在，原先连存在性都不查）。
         */
        if (planId > 0) {
            match (s.plans.get(planId)) {
                case Some(p) =>
                    /*
                     * R-7（2026-10-05 晚修）：历史任务会被聚合进**发给外部模型**的 prompt，
                     * 必须与 AI-17（retrospective 的课题分支）**对称地**先做一次授权判定。
                     * 原先这里只查了存在性。按今天的读范围这些数据本就在职成员可读，
                     * 所以不是现行越权；但缺一道明确判定，一旦收紧读范围就会静默变成绕过点。
                     * 另外存在性检查单独存在时，`PLAN_NOT_FOUND` 顺带成了 plan_id 探针。
                     */
                    let ptgt = Target()
                    ptgt.dept_id = p.dept_id
                    ptgt.owner_id = p.owner_id
                    ptgt.creator_id = p.created_by
                    requireAccess(actor, Action.ViewTasks, ptgt)
                    history = aiPlanHistoryLines(s, planId)
                case None => throw apiErrMsg("PLAN_NOT_FOUND", "课题不存在")
            }
        }
        let fb = aiFallbackOwner(s, deptId)
        let fbOwnerId = fb[0]
        let fbOwnerName = fb[1]
        let fbLoad = fb[2]
        if (fbOwnerId > 0) {
            jPutInt(fallback, "owner_id", fbOwnerId)
            jPutStr(fallback, "owner_name", fbOwnerName)
        } else {
            jPutNull(fallback, "owner_id")
            jPutNull(fallback, "owner_name")
        }
        jPutNull(fallback, "due_at")
        jPutNull(fallback, "granularity")
        let reasons = JsonArray()
        reasons.add(JsonString("按本部门在途任务数最少挑出（${fbOwnerName} 在途 ${fbLoad} 件）"))
        fallback.put("reasons", reasons)
    } finally {
        s.lock.unlock()
    }

    /* ③ 锁外：调模型 */
    let prompt = aiPromptTaskSuggest(title, desc, deptName, candidates, history)
    /* R-9（根因已定位：固定窗口 + 慢调用，与位置无关）：
       放在**授权与校验之后、出站调用之前** —— 比 403 晚（无权请求不吃配额、
       也不该看到 429），比花钱早（真正拦住）。仓库惯例见 h_auth.cj 的 handleLogin：
       reqObj -> v.done -> 锁定检查 -> PBKDF2。
       模型未启用时不计数（ai == None 是纯本地兜底、零成本）。 */
    aiRateCheckIfEnabled(ai, actor.id)
    match (ai) {
        case Some(c) =>
            let r = c.call(prompt, aiSchemaTaskSuggest(), AI_KEYS_TASK_SUGGEST, fallback)
            aiRateRefundIfFree(actor.id, r)
            /* 模型挑的人必须真在候选名单里，否则丢弃（模型不得凭空造人） */
            var ownerId: Int64 = 0
            match (jsonGetInt64(r.obj, "owner_id")) {
                case Some(id) =>
                    if (r.isModel()) {
                        if (candIds.contains(id)) {
                            ownerId = id
                        }
                    } else {
                        ownerId = id
                    }
                case None => ()
            }
            /* R-15（2026-10-05 晚修）：这里原有一段 `var ownerName` + 两次赋值 + 一个
               只为喂它而存在的 aiOwnerNameOf —— 变量**从未被读过**（响应早已改用
               aiOwnerBriefOf 出 MemberBrief 对象）。上一个提交自称"清死代码"却漏了它。 */
            let d = JsonObject()
            /* AI-9：owner 是 MemberBrief 对象，不是扁平 owner_id/owner_name */
            if (ownerId > 0) {
                match (aiOwnerBriefOf(s, ownerId)) {
                    case Some(b) => jPutObj(d, "owner", b)
                    case None => jPutNull(d, "owner")
                }
            } else {
                jPutNull(d, "owner")
            }
            aiPutIsoOrNull(d, r.obj, "due_at")
            aiPutStrOrNull(d, r.obj, "granularity")
            aiPutStrArr(d, r.obj, "reasons")
            aiPutMeta(d, r)
            aiAudit(s, actor.id, "task_suggest", r)
            sendOk(ctx, d)
        case None =>
            let r = AiResult(AI_SOURCE_FALLBACK, fallback, "智能建议暂不可用（AI 未配置）",
                             "not_configured", 0, 0, 0)
            let d = JsonObject()
            /* AI-9：同样输出 MemberBrief 对象 */
            var fbOwner: ?JsonObject = None
            match (jsonGetInt64(fallback, "owner_id")) {
                case Some(id) => fbOwner = aiOwnerBriefOf(s, id)
                case None => ()
            }
            match (fbOwner) {
                case Some(b) => jPutObj(d, "owner", b)
                case None => jPutNull(d, "owner")
            }
            aiPutStrOrNull(d, fallback, "due_at")
            aiPutStrOrNull(d, fallback, "granularity")
            aiPutStrArr(d, fallback, "reasons")
            aiPutMeta(d, r)
            sendOk(ctx, d)
    }
}

/* R-15：`aiOwnerNameOf` 已删 —— 它只为 task-suggest 里那个从不被读的 ownerName 服务。
   notice-draft 用的是它自己锁内取的 ownerName，与本函数无关。 */

/*
 * 取成员的对外简报。**AI-9（2026-10-05 修）**：api-design §7.1 规定
 * `task-suggest` 的 `owner` 是 `MemberBrief` 对象（`{"id":..,"name":..,"dept":{..}}`），
 * 而原先返回的是扁平 `owner_id` + `owner_name` —— 照文档写的 ArkTS 会取不到值。
 * 自己加一次短锁；调用方必须在锁外。
 */
func aiOwnerBriefOf(s: Store, id: Int64): ?JsonObject {
    s.lock.lock()
    try {
        match (s.members.get(id)) {
            case Some(m) => return Some(memberBrief(s, m))
            case None => return None
        }
    } finally {
        s.lock.unlock()
    }
}

/* AI-9：`basis` 是对象数组 `[{kind, ref}]`（api-design §7.4），不是字符串数组。 */
func aiBasisKind(text: String): String {
    if (startsWithAscii(text, "permission")) { return "permission" }
    if (startsWithAscii(text, "data")) { return "data" }
    if (startsWithAscii(text, "doc")) { return "doc" }
    return "doc"
}

func aiPutBasis(d: JsonObject, src: JsonObject): Unit {
    let arr = JsonArray()
    match (jsonGetArray(src, "basis")) {
        case Some(list) =>
            var i: Int64 = 0
            while (i < list.size()) {
                match (list[i]) {
                    case s: JsonString =>
                        let text = aiStripQuotes(s.toString())
                        let o = JsonObject()
                        jPutStr(o, "kind", aiBasisKind(text))
                        jPutStr(o, "ref", text)
                        arr.add(o)
                    case _ => ()
                }
                i += 1
            }
        case None => ()
    }
    d.put("basis", arr)
}

/* 兜底（非模型）回答的 basis —— 形状必须与 aiPutBasis 产出的一致（AI-9）。 */
func aiBasisFixture(role: String): JsonArray {
    let arr = JsonArray()
    let b1 = JsonObject()
    jPutStr(b1, "kind", "permission")
    jPutStr(b1, "ref", "can() 的系统判定结果")
    arr.add(b1)
    let b2 = JsonObject()
    jPutStr(b2, "kind", "data")
    jPutStr(b2, "ref", "当前角色 ${role}")
    arr.add(b2)
    return arr
}

/*
 * 智能体（`/ai/agent`）的 basis。**形状必须与 aiPutBasis / aiBasisFixture 一致**（AI-9）。
 *
 * 2026-10-06 修（前端报的契约不一致）：原先这条路径**手搓了字符串数组**
 * `["permission: …", "data: …"]`，而同一接口的降级路径返回对象数组 ⇒
 * **同一个 `basis` 字段、同一份 `source=fallback`，形状却取决于"AI 配没配"**，
 * 客户端无法可靠消费（按对象解析遇字符串会崩、按字符串解析遇对象会乱），只能不消费。
 *
 * 为什么单独一个函数而不是复用 aiBasisFixture：
 *   两者的 `data` 依据**本来就不是一回事** —— agent 的数据来自**工具查询**（见 steps），
 *   而 aiBasisFixture 描述的是"当前角色"。改形状，但**不篡改语义**。
 *
 * ⚠ `AI_KEYS_AGENT` 里**没有 `basis`**（模型不产出这个字段），所以这里是**静态基准**，
 *   不是从模型输出里取的。若将来要让模型自己给依据，需同时扩 schema 与提示词，
 *   那时再改调 `aiPutBasis(d, r.obj)`。
 */
func aiBasisAgent(): JsonArray {
    let arr = JsonArray()
    let b1 = JsonObject()
    jPutStr(b1, "kind", "permission")
    jPutStr(b1, "ref", "can() 的系统判定结果")
    arr.add(b1)
    let b2 = JsonObject()
    jPutStr(b2, "kind", "data")
    jPutStr(b2, "ref", "工具查询结果（见 steps）")
    arr.add(b2)
    return arr
}

/* 课题面包屑（**调用方必须持锁**）。深度封顶，避免脏数据成环时死循环。 */
func aiPlanPath(s: Store, planId: Int64): String {
    var path = ""
    var cur = planId
    var depth: Int64 = 0
    while (cur > 0 && depth < 8) {
        match (s.plans.get(cur)) {
            case Some(p) =>
                path = if (path.size == 0) { p.title } else { p.title + " / " + path }
                cur = p.parent_id
            case None => cur = 0
        }
        depth += 1
    }
    return path
}

/* ===================== 7.2 通知起草 ===================== */

public func handleAiNoticeDraft(ctx: Context, s: Store, ai: ?AiClient): Unit {
    let actor = requireActive(ctx, s)
    /* F-2：只读削峰 —— 已满就直接 429，不消耗额度、也不进 s.lock 做那 160 万次迭代 */
    aiRatePeekIfEnabled(ai, actor.id)
    let body = reqObj(ctx)
    let taskId = reqIntOr(body, "task_id", 0)
    var audience = reqStrOr(body, "audience", "members")
    /*
     * AI-11（2026-10-05 修）：audience 必须过**白名单**。
     * 原先收任意字符串：既原样塞进 prompt，又把**模型返回的** audience 回给客户端
     * （而 `aiSchemaNotice()` 只声明了 title/body，压根没约束它）。
     * 口径见 api-design §7.2：members（默认）/ leads / all。
     */
    if (audience != "members" && audience != "leads" && audience != "all") {
        audience = "members"
    }
    let v = V()
    v.check("task_id", taskId > 0, "任务 id 不能为空")
    /*
     * 形状校验（id 必须为正）放在**查资源之前**：它只说明"参数是否成形"，
     * 不泄露资源是否存在，因此不受 AI-10 约束 —— AI-10 管的是**内容**校验
     * （如 task-suggest 的 title 为空）不能先于授权。
     * 放在后面会让 `task_id=0` 报 404「任务不存在」而不是 400「参数校验失败」，
     * 语义不对（id=0 不是一个"不存在的任务"，而是非法入参）。
     */
    v.done()

    var taskTitle = ""
    var ownerName = ""
    var dueAt = ""
    var planPath = ""
    var fallback = JsonObject()

    /* ② 锁内：取数 + 构造模板兜底 */
    s.lock.lock()
    try {
        var t: Task = Task()
        var found = false
        match (s.tasks.get(taskId)) {
            case Some(x) => t = x
                found = true
            case None => ()
        }
        if (!found || t.deleted_at != 0) {
            throw apiErrMsg("TASK_NOT_FOUND", "任务不存在")
        }
        requireAccess(actor, Action.ViewTasks, aiTargetOfTask(t))
        taskTitle = t.title
        match (s.members.get(t.owner_id)) {
            case Some(m) => ownerName = m.name
            case None => ()
        }
        if (t.due_at > 0) {
            dueAt = isoLocal(t.due_at)
        }
        planPath = aiPlanPath(s, t.plan_id)

        jPutStr(fallback, "title", "关于「${t.title}」的通知")
        var text = "各位成员：\n\n关于「${t.title}」"
        if (ownerName.size > 0) {
            text += "，由 ${ownerName} 负责"
        }
        if (dueAt.size > 0) {
            text += "，请于 ${dueAt} 前完成"
        }
        text += "。\n\n请知悉并按时推进。"
        jPutStr(fallback, "body", text)
        jPutStr(fallback, "audience", audience)
        jPutNull(fallback, "suggest_send_at")
    } finally {
        s.lock.unlock()
    }

    /* ③ 锁外：调模型 */
    let prompt = aiPromptNotice(taskTitle, ownerName, dueAt, planPath, audience)
    /* R-9（根因已定位：固定窗口 + 慢调用，与位置无关）：
       放在**授权与校验之后、出站调用之前** —— 比 403 晚（无权请求不吃配额、
       也不该看到 429），比花钱早（真正拦住）。仓库惯例见 h_auth.cj 的 handleLogin：
       reqObj -> v.done -> 锁定检查 -> PBKDF2。
       模型未启用时不计数（ai == None 是纯本地兜底、零成本）。 */
    aiRateCheckIfEnabled(ai, actor.id)
    match (ai) {
        case Some(c) =>
            let r = c.call(prompt, aiSchemaNotice(), AI_KEYS_NOTICE, fallback)
            aiRateRefundIfFree(actor.id, r)
            let d = JsonObject()
            aiPutStrOrNull(d, r.obj, "title")
            aiPutStrOrNull(d, r.obj, "body")
            /* AI-11：audience 一律回填**请求里的**值，不用模型返回的 */
            jPutStr(d, "audience", audience)
            aiPutIsoOrNull(d, r.obj, "suggest_send_at")
            aiPutMeta(d, r)
            aiAudit(s, actor.id, "notice_draft", r)
            sendOk(ctx, d)
        case None =>
            let r = AiResult(AI_SOURCE_FALLBACK, fallback, "智能起草暂不可用（AI 未配置）",
                             "not_configured", 0, 0, 0)
            let d = JsonObject()
            aiPutStrOrNull(d, fallback, "title")
            aiPutStrOrNull(d, fallback, "body")
            aiPutStrOrNull(d, fallback, "audience")
            aiPutStrOrNull(d, fallback, "suggest_send_at")
            aiPutMeta(d, r)
            sendOk(ctx, d)
    }
}

/* ===================== 7.3 成效与延期归因 ===================== */

/*
 * 把模型给的一条归因串翻成 {kind, detail}。
 * `kind` 取前缀识别（**不切分字符串**，免得为了一次 split 引入脆弱的字节处理）；
 * `detail` 原样保留模型的说法，信息不丢。
 */
func aiCauseKind(text: String): String {
    if (startsWithAscii(text, "dependency")) { return "dependency" }
    if (startsWithAscii(text, "overload")) { return "overload" }
    if (startsWithAscii(text, "granularity")) { return "granularity" }
    if (startsWithAscii(text, "scope_drift")) { return "scope_drift" }
    if (startsWithAscii(text, "external")) { return "external" }
    return "unknown"
}

func aiPutCauses(d: JsonObject, src: JsonObject): Unit {
    let arr = JsonArray()
    match (jsonGetArray(src, "causes")) {
        case Some(list) =>
            var i: Int64 = 0
            while (i < list.size()) {
                match (list[i]) {
                    case s: JsonString =>
                        let c = JsonObject()
                        jPutStr(c, "kind", aiCauseKind(s.toString()))
                        jPutStr(c, "detail", aiStripQuotes(s.toString()))
                        arr.add(c)
                    case _ => ()
                }
                i += 1
            }
        case None => ()
    }
    d.put("causes", arr)
}

/*
 * JsonString.toString() 会带上引号与转义，这里只取原始内容。
 *
 * ⚠ AI-12（2026-10-05 修）：**必须包 try/catch**。它跑在 `aiPutCauses` 里，
 * 输入是**原始模型输出**；同一模块其它 `JsonValue.fromStr` 调用点都包了 try，
 * 说明它确实会抛。一旦抛出且无人接住，就破坏了「永不返回 5xx」的契约。
 * 解析失败就回落成原串（宁可多几个引号，也不能 500）。
 */
func aiStripQuotes(raw: String): String {
    try {
        match (JsonValue.fromStr(raw)) {
            case v: JsonString => return v.getValue()
            case _ => return raw
        }
    } catch (e: Exception) {
        return raw
    }
}

public func handleAiRetrospective(ctx: Context, s: Store, ai: ?AiClient): Unit {
    let actor = requireActive(ctx, s)
    /* F-2：只读削峰 —— 已满就直接 429，不消耗额度、也不进 s.lock 做那 160 万次迭代 */
    aiRatePeekIfEnabled(ai, actor.id)
    let body = reqObj(ctx)
    let taskId = reqIntOr(body, "task_id", 0)
    let planId = reqIntOr(body, "plan_id", 0)
    let v = V()
    v.check("target", taskId > 0 || planId > 0, "task_id 与 plan_id 必须给其中一个")

    /* is_overdue / days **由服务端算**，绝不由模型生成（否则与列表页数字打架） */
    var isOd = false
    var odDays: Int64 = 0
    var facts = ""
    var fallback = JsonObject()

    s.lock.lock()
    try {
        let now = nowEpoch()
        if (taskId > 0) {
            var t: Task = Task()
            var found = false
            match (s.tasks.get(taskId)) {
                case Some(x) => t = x
                    found = true
                case None => ()
            }
            if (!found || t.deleted_at != 0) {
                throw apiErrMsg("TASK_NOT_FOUND", "任务不存在")
            }
            requireAccess(actor, Action.ViewTasks, aiTargetOfTask(t))
            /* AI-10 同款：先授权、再校验入参 */
            v.done()
            var ow = ""
            match (s.members.get(t.owner_id)) {
                case Some(m) => ow = m.name
                case None => ()
            }
            var dueStr = "未设截止时间"
            if (t.due_at > 0) {
                dueStr = isoLocal(t.due_at)
                if (t.status != "done" && isTaskOverdue(t, now)) {
                    isOd = true
                    /* AI-4（2026-10-05 修）：口径必须与列表页一致 —— 用 views.cj 的
                       `overdueDaysOf`（本地日界差），**不能**用 (now - due_at)/86400：
                       24 小时取整会比列表页少一天（09-12 18:00 截止、09-14 09:00 现在，
                       列表页 2 天、这里算出 1 天）。 */
                    odDays = overdueDaysOf(t, now)
                }
            }
            facts = "任务「${t.title}」当前状态 ${t.status}，负责人 ${ow}，截止时间 ${dueStr}。"
        } else {
            var p: Plan = Plan()
            var found = false
            match (s.plans.get(planId)) {
                case Some(x) => p = x
                    found = true
                case None => ()
            }
            if (!found) {
                throw apiErrMsg("PLAN_NOT_FOUND", "课题不存在")
            }
            /* AI-17（2026-10-05 修）：课题分支原先**一次授权都没有**（任务分支有）。
               今天因为 ViewTasks 对全社团放开而等效，但一旦收紧读范围，
               这里会**静默**变成绕过点。补上与任务分支对齐的判定。 */
            let ptgt = Target()
            ptgt.dept_id = p.dept_id
            ptgt.owner_id = p.owner_id
            ptgt.creator_id = p.created_by
            requireAccess(actor, Action.ViewTasks, ptgt)
            /* AI-10 同款：先授权、再校验入参 */
            v.done()
            var total: Int64 = 0
            var done: Int64 = 0
            var late: Int64 = 0
            for ((_, t) in s.tasks) {
                if (t.deleted_at != 0 || t.plan_id != planId) {
                    continue
                }
                total += 1
                if (t.status == "done") {
                    done += 1
                } else if (t.due_at > 0 && isTaskOverdue(t, now)) {
                    late += 1
                    let d = overdueDaysOf(t, now)
                    if (d > odDays) {
                        odDays = d
                    }
                }
            }
            isOd = late > 0
            let rate = if (total > 0) { done * 100 / total } else { 100 }
            facts = "课题「${p.title}」下共 ${total} 个任务，已完成 ${done} 个，按期率约 ${rate}%，" +
                    "当前未完成且已逾期 ${late} 个。"
        }

        var odText = "未延期"
        if (isOd) {
            odText = "已延期 ${odDays} 天"
        }
        jPutStr(fallback, "summary", facts)
        let od = JsonObject()
        jPutBool(od, "is_overdue", isOd)
        jPutInt(od, "days", odDays)
        od.put("causes", JsonArray())
        fallback.put("overdue", od)
        fallback.put("suggestions", JsonArray())
    } finally {
        s.lock.unlock()
    }

    var odText2 = "未延期"
    if (isOd) {
        odText2 = "已延期 ${odDays} 天"
    }
    let prompt = aiPromptRetro(facts, odText2)
    /* R-9（根因已定位：固定窗口 + 慢调用，与位置无关）：
       放在**授权与校验之后、出站调用之前** —— 比 403 晚（无权请求不吃配额、
       也不该看到 429），比花钱早（真正拦住）。仓库惯例见 h_auth.cj 的 handleLogin：
       reqObj -> v.done -> 锁定检查 -> PBKDF2。
       模型未启用时不计数（ai == None 是纯本地兜底、零成本）。 */
    aiRateCheckIfEnabled(ai, actor.id)

    match (ai) {
        case Some(c) =>
            let r = c.call(prompt, aiSchemaRetro(), AI_KEYS_RETRO, fallback)
            aiRateRefundIfFree(actor.id, r)
            let d = JsonObject()
            /* summary 用模型的；overdue 的数字**一律用我们自己算的** */
            match (jsonGetStr(r.obj, "summary")) {
                case Some(sm) => jPutStr(d, "summary", sm)
                case None => jPutStr(d, "summary", facts)
            }
            let od = JsonObject()
            jPutBool(od, "is_overdue", isOd)
            jPutInt(od, "days", odDays)
            aiPutCauses(od, r.obj)
            d.put("overdue", od)
            aiPutStrArr(d, r.obj, "suggestions")
            aiPutMeta(d, r)
            aiAudit(s, actor.id, "retrospective", r)
            sendOk(ctx, d)
        case None =>
            let r = AiResult(AI_SOURCE_FALLBACK, fallback, "智能归因暂不可用（AI 未配置）",
                             "not_configured", 0, 0, 0)
            let d = JsonObject()
            jPutStr(d, "summary", facts)
            let od = JsonObject()
            jPutBool(od, "is_overdue", isOd)
            jPutInt(od, "days", odDays)
            od.put("causes", JsonArray())
            d.put("overdue", od)
            d.put("suggestions", JsonArray())
            aiPutMeta(d, r)
            sendOk(ctx, d)
    }
}

/* ===================== 7.4 权限感知问答 ===================== */

/* 要探测的动作清单（标签 → Action）。顺序固定，输出才可复现。 */
func aiActionList(): Array<(String, Action)> {
    return [
        ("查看成员名录", Action.ViewMembers),
        ("查看任务", Action.ViewTasks),
        ("修改成员姓名", Action.EditMemberName),
        ("调整成员角色", Action.SetRole),
        ("停用成员", Action.DisableMember),
        ("审批待分配成员", Action.AssignPending),
        ("重置成员口令", Action.ResetPassword),
        ("管理部门", Action.ManageDept),
        ("删除部门", Action.DeleteDept),
        ("查看注册口令", Action.ViewRegisterCode),
        ("更换注册口令", Action.ChangeRegisterCode),
        ("管理招募链接", Action.ManageInviteLink),
        ("移交会长", Action.TransferPresidency),
        ("创建课题", Action.CreatePlan),
        ("编辑课题", Action.EditPlan),
        ("移动课题", Action.MovePlan),
        ("删除课题", Action.DeletePlan),
        ("创建任务", Action.CreateTask),
        ("编辑任务", Action.EditTask),
        ("删除任务", Action.DeleteTask),
        ("更新任务状态", Action.UpdateTaskStatus)
    ]
}

/*
 * 权限事实：**全部由 can() 算出来**，再作为事实交给模型润色。
 * 模型不生成权限结论 —— 这样"AI 说错权限"在结构上不可能发生。
 *
 * ⚠ 2026-10-06 修（用户报的 bug）：这里原来只填 `dept_id` 与 `is_self`，
 * **`target_role` 留空**。而 perms.cj 的 `outranks()` 对空档位是**故意 fail-closed** 的
 * （注释原文："目标档位未知（空串）：宁拒不放过"），于是：
 *     部长 + Action.ResetPassword -> outranks("lead", "") -> false
 * 结果**部长的权限清单里少了「重置成员口令」** —— 而服务端实际上允许他重置
 * **本部门普通成员**的口令（tests.cj 里就有这条断言，界面上真做也会成功 200）。
 * 这比"AI 说错权限"更糟：**模型没说错，是我们喂给它的"权威事实"错了。**
 *
 * 修法：这个合成目标代表的是「本部门**普通成员**」这个**代表性目标**，
 * 所以 `target_role` 必须**显式填** "member" —— 空串在这里不等于"任意目标"，
 * 而是"目标未知"，会把**所有**依赖档位的规则一律判否
 * （将来往 Action 里加新动作还会踩同一个坑）。
 * 另外把代表性目标写进对外文案（aiPermAnswer），免得被读成"无条件可做"。
 */
/*
 * 权限清单的对外文案。**必须点明代表性目标** —— 清单是按「本部门普通成员」判定的，
 * 不写清楚会被读成"无条件可做"（例如部长能重置口令，但只限档位低于他的成员）。
 */
func aiPermAnswer(perms: String): String {
    return "根据系统判定，你当前的权限是（判定基于「你本人」与「本部门普通成员」两种代表性目标）：\n${perms}"
}

/*
 * 兜底 / 降级时的答案：**必须自述"这不是对你所提问题的回答"**（2026-10-06 加）。
 *
 * 起因是一次真实误判：有人起服务时没配 `--ai-endpoint`，然后拿两个完全不同的问题
 * 打 `/ai/ask`，得到**逐字节相同**的权限摘要，于是判断"这条路径有 bug / 没走模型"。
 * 他判断对了一半 —— 确实没走模型；但**答案文本本身没告诉任何人"我答不了这个"**，
 * 所以只看返回内容的人是发现不了"这是兜底"的。
 *
 * `source=fallback` 与 `note` 在响应信封里标了，但**只读文本的人不会去看信封**。
 * 让文本自己说清楚的成本是零，省掉的是一次误判。
 *
 * ⚠ 只在**确实降级**的路径用它（AI 未配置 / 出站失败）。
 *   模型正常返回但缺 `answer` 字段时仍用 aiPermAnswer —— 那时"模型暂不可用"是假话。
 */
func aiPermFallbackAnswer(perms: String): String {
    return "模型暂不可用。以下是系统判定的当前权限事实 —— 这不是对你所提问题的回答：\n${perms}"
}

func aiPermFacts(actor: Member): String {
    /*
     * 需要**两个**代表性目标，单用其中任一个都会漏（2026-10-06 实测确认）：
     *
     * ① 目标档位不能留空 —— perms.cj 的 outranks() 对空串是故意 fail-closed
     *    （"目标档位未知（空串）：宁拒不放过"），于是
     *        部长 + ResetPassword -> roleAllows -> outranks("lead", "") -> false
     *    部长的清单里少了「重置成员口令」。
     * ② 目标也不能是"本人" —— checkAccess 里有一条 N-7：
     *        case ResetPassword => if (isSelf) { return FORBIDDEN_ROLE }
     *    「重置口令**连自己也不许**」（它是管理员救济动作，会给目标作废全部令牌）。
     *    所以只填 target_role 而保留 is_self=true，这一条**仍然被判否**（实测）。
     *    反过来，普通成员的「更新任务状态」只看 is_self —— 全换成"他人"又会漏掉它。
     *
     * 结论：按「**本人**」与「**本部门普通成员**」两个目标各判一次，取**并集**。
     * 这两条口径也写进了对外文案（aiPermAnswer），不假装是"无条件可做"。
     */
    let selfTgt = Target()
    selfTgt.dept_id = actor.dept_id
    selfTgt.is_self = true
    selfTgt.target_role = "member"

    let peerTgt = Target()
    peerTgt.dept_id = actor.dept_id
    peerTgt.is_self = false
    peerTgt.target_role = "member"

    var out = ""
    for (item in aiActionList()) {
        if (can(actor, item[1], selfTgt) || can(actor, item[1], peerTgt)) {
            out += "- ${item[0]}\n"
        }
    }
    if (out.size == 0) {
        out = "- （没有管理类权限，只能查看本人相关的内容）\n"
    }
    return out
}

public func handleAiAsk(ctx: Context, s: Store, ai: ?AiClient): Unit {
    let actor = requireActive(ctx, s)
    /* F-2：只读削峰 —— 已满就直接 429，不消耗额度、也不进 s.lock 做那 160 万次迭代 */
    aiRatePeekIfEnabled(ai, actor.id)
    let body = reqObj(ctx)
    let question = reqStrOr(body, "question", "")
    let v = V()
    v.need("question", question, "问题不能为空")
    /* AI-8：提问会**原样进 prompt 发给外部模型**，长度必须有闸门。 */
    lenCheck(v, "question", "问题", question, MAX_QUESTION_BYTES)
    v.done()

    var who = ""
    var perms = ""
    var fallback = JsonObject()

    s.lock.lock()
    try {
        var deptName = "（未分配）"
        match (s.departments.get(actor.dept_id)) {
            case Some(dp) => deptName = dp.name
            case None => ()
        }
        who = "姓名 ${actor.name}，角色 ${actor.role}，部门 ${deptName}"
        perms = aiPermFacts(actor)
        jPutStr(fallback, "answer", aiPermFallbackAnswer(perms))
        /* AI-9：basis 是对象数组 [{kind, ref}]，与 model 分支保持同一形状 */
        fallback.put("basis", aiBasisFixture(actor.role))
    } finally {
        s.lock.unlock()
    }

    let prompt = aiPromptAsk(question, who, perms, "")
    /* R-9（根因已定位：固定窗口 + 慢调用，与位置无关）：
       放在**授权与校验之后、出站调用之前** —— 比 403 晚（无权请求不吃配额、
       也不该看到 429），比花钱早（真正拦住）。仓库惯例见 h_auth.cj 的 handleLogin：
       reqObj -> v.done -> 锁定检查 -> PBKDF2。
       模型未启用时不计数（ai == None 是纯本地兜底、零成本）。 */
    aiRateCheckIfEnabled(ai, actor.id)
    match (ai) {
        case Some(c) =>
            let r = c.call(prompt, aiSchemaAsk(), AI_KEYS_ASK, fallback)
            aiRateRefundIfFree(actor.id, r)
            let d = JsonObject()
            match (jsonGetStr(r.obj, "answer")) {
                case Some(a) => jPutStr(d, "answer", a)
                case None => jPutStr(d, "answer", aiPermAnswer(perms))
            }
            aiPutBasis(d, r.obj)
            aiPutMeta(d, r)
            aiAudit(s, actor.id, "ask", r)
            sendOk(ctx, d)
        case None =>
            let r = AiResult(AI_SOURCE_FALLBACK, fallback, "智能问答暂不可用（AI 未配置）",
                             "not_configured", 0, 0, 0)
            let d = JsonObject()
            jPutStr(d, "answer", aiPermFallbackAnswer(perms))
            d.put("basis", aiBasisFixture(actor.role))
            aiPutMeta(d, r)
            sendOk(ctx, d)
    }
}

/* ===================== 7.6 智能体：工具循环（只读，Phase 1）===================== */

/* Agent 的轮数上限与总预算（T4）。**整个请求共享预算**，不是每轮各给一份。 */
let AI_AGENT_MAX_ROUNDS: Int64 = 4
let AI_AGENT_BUDGET_MS: Int64 = 20000

/*
 * 工具调用的审计（T5）：**denied 也必须记**。
 * 只记元信息（工具名 / 是否放行 / 第几轮），**不记**参数与结果全文 ——
 * 参数可能含用户隐私，结果可能含业务数据，日志里不该有。
 */
func aiAuditTool(s: Store, actorId: Int64, tool: String, allowed: Bool, round: Int64): Unit {
    let note = "tool=${tool} allowed=${allowed} round=${round}"
    s.lock.lock()
    try {
        audit(s, actorId, "ai_tool", 0, note)
    } finally {
        s.lock.unlock()
    }
}

/*
 * 降级答案（D2：兜底不得为空）。
 * 模型中途不可用时，把**已经查到的数据**直接拼成回答给用户 ——
 * 这比"暂不可用"有用得多，而且完全不依赖模型。
 */
func aiAgentDegradedAnswer(perms: String, steps: JsonArray): String {
    if (steps.size() == 0) {
        return "智能助手暂时不可用。\n根据系统判定，你当前的权限是：\n${perms}"
    }
    var out = "智能助手暂时不可用，以下是已经查到的数据：\n"
    var i: Int64 = 0
    while (i < steps.size()) {
        match (steps[i]) {
            case st: JsonObject =>
                let tool = match (jsonGetStr(st, "tool")) {
                    case Some(v) => v
                    case None => "?"
                }
                let allowed = match (jsonGetBool(st, "allowed")) {
                    case Some(v) => v
                    case None => false
                }
                if (allowed) {
                    match (jsonGetStr(st, "payload")) {
                        case Some(p) => out += "· ${p}\n"
                        case None => ()
                    }
                } else {
                    out += "· ${tool}：无权限访问\n"
                }
            case _ => ()
        }
        i += 1
    }
    return out
}

/*
 * POST /api/v1/ai/agent —— 工具循环（api-design Part 7.6）
 *
 * 每一轮固定是：**锁外**调模型 → 解析 → **锁内**跑 1 个工具（短）→ **锁外**回灌。
 * 绝不能把 `s.lock` 跨轮持有，也不能在锁内调模型 —— 那正是模块注释里反复强调的坑。
 */
public func handleAiAgent(ctx: Context, s: Store, ai: ?AiClient): Unit {
    let actor = requireActive(ctx, s)
    aiRatePeekIfEnabled(ai, actor.id)
    let body = reqObj(ctx)
    let question = reqStrOr(body, "question", "")
    let v = V()
    v.need("question", question, "问题不能为空")
    lenCheck(v, "question", "问题", question, MAX_QUESTION_BYTES)
    v.done()

    var who = ""
    var perms = ""
    var fallback = JsonObject()
    s.lock.lock()
    try {
        var deptName = "（未分配）"
        match (s.departments.get(actor.dept_id)) {
            case Some(dp) => deptName = dp.name
            case None => ()
        }
        who = "姓名 ${actor.name}，角色 ${actor.role}，部门 ${deptName}"
        perms = aiPermFacts(actor)
        jPutStr(fallback, "answer", aiPermFallbackAnswer(perms))
        fallback.put("basis", aiBasisFixture(actor.role))
        fallback.put("steps", JsonArray())
        jPutInt(fallback, "rounds", 0)
        jPutInt(fallback, "calls", 0)
    } finally {
        s.lock.unlock()
    }

    aiRateCheckIfEnabled(ai, actor.id)
    match (ai) {
        case Some(c) =>
            let t0 = aiNowMs()
            let steps = JsonArray()
            var history = ""
            var rounds: Int64 = 0
            var calls: Int64 = 0
            var answer = ""
            var src = AI_SOURCE_FALLBACK
            var outcome = "budget_exhausted"
            var note = ""
            var done = false
            /* P2：写工具产出的提议（有值即表示"等用户确认"，此时 answer 不是最终答案） */
            var proposalOut: ?JsonObject = None

            while (rounds < AI_AGENT_MAX_ROUNDS && (aiNowMs() - t0) < AI_AGENT_BUDGET_MS) {
                rounds += 1
                let prompt = aiPromptAgent(question, who, perms, aiToolLines(), history)
                let r = c.call(prompt, aiSchemaAgent(), AI_KEYS_AGENT, fallback)
                calls += r.attempts
                /* F-1：零出站的结局（overloaded / too_large）退还额度 */
                aiRateRefundIfFree(actor.id, r)
                if (!r.isModel()) {
                    outcome = r.outcome
                    note = r.note
                    answer = aiAgentDegradedAnswer(perms, steps)
                    done = true
                    break
                }
                /* 模型说"可以回答了" -> 收工 */
                var finalText = ""
                match (jsonGetStr(r.obj, "final")) {
                    case Some(f) => finalText = f
                    case None => ()
                }
                if (finalText.size > 0) {
                    answer = finalText
                    src = AI_SOURCE_MODEL
                    outcome = "ok"
                    done = true
                    break
                }
                /* 否则应当是要调工具 */
                let tool = match (jsonGetStr(r.obj, "tool")) {
                    case Some(t) => t
                    case None => ""
                }
                if (tool.size == 0) {
                    /* 既没 final 也没 tool：模型没按协议来，别硬转 —— 当降级处理 */
                    outcome = "bad_output"
                    answer = aiAgentDegradedAnswer(perms, steps)
                    done = true
                    break
                }
                var args = JsonObject()
                match (jsonGetObject(r.obj, "args")) {
                    case Some(a) => args = a
                    case None => ()
                }
                /*
                 * ★ P2：**写工具不在这里执行**。
                 * 改为产出一个「提议」并存进 idem，等用户在界面上确认后才落库 ——
                 * 这就是"模型永远不能单次往返就产生副作用"的落点。
                 */
                var isWrite = false
                for (sp in aiToolSpecs()) {
                    if (sp.name == tool) {
                        isWrite = sp.write
                    }
                }
                if (isWrite) {
                    var propObj: ?JsonObject = None
                    s.lock.lock()
                    try {
                        propObj = aiToolPropose(s, actor, tool, args, nowEpoch())
                        match (propObj) {
                            case Some(pj) =>
                                /* 存**不含令牌**的提议正文；令牌在这一步才生成 */
                                let tk = aiProposalNew(s, actor.id, pj.toString(), nowEpoch())
                                pj.put("token", JsonString(tk))
                                jPutInt(pj, "expires_at", nowEpoch() + AI_PROP_TTL)
                            case None => ()
                        }
                        /*
                         * T5：**产出提议也要落审计**（预筛不过同样记）。
                         *
                         * 为什么必须有这条：没有它，日志里只能看到"用户确认了但被业务规则拒"，
                         * 无法区分"模型压根没提过"。有了它，
                         * 「提议过没有 → 用户确认没有 → 执行结果」三行才连得起来。
                         *
                         * ⚠ 直接调 `audit`，**不调 `aiAuditTool`** —— 后者会自己再取一次 s.lock，
                         *   而 Mutex **非重入**会死锁（与 handleAiAgentConfirm 处同一个坑）。
                         * 只记元信息（工具名/是否产出/第几轮），**不记参数全文** ——
                         * 参数可能含用户隐私，日志里不该有。
                         */
                        var proposed = false
                        match (propObj) {
                            case Some(_) => proposed = true
                            case None => ()
                        }
                        audit(s, actor.id, "ai_tool_propose", 0,
                              "tool=${tool} proposed=${proposed} round=${rounds}")
                    } finally {
                        s.lock.unlock()
                    }
                    match (propObj) {
                        case Some(pj) =>
                            proposalOut = propObj
                            answer = "我准备做一个改动，需要你确认后才会生效。"
                            src = AI_SOURCE_MODEL
                            outcome = "proposal"
                            done = true
                            break
                        case None =>
                            /* 预筛不过：参数不成形，把它当一轮无效结果告诉模型，让它自己收尾 */
                            history += "第 ${rounds} 轮：$tool -> 参数不成形，未产出提议。\n"
                            continue
                    }
                }
                /* 锁内跑**只读**工具（极短）；模型调用永远在锁外 */
                var step = JsonObject()
                s.lock.lock()
                try {
                    step = dispatchAiTool(s, actor, tool, args, aiNowMs())
                } finally {
                    s.lock.unlock()
                }
                steps.add(step)
                let allowed = match (jsonGetBool(step, "allowed")) {
                    case Some(b) => b
                    case None => false
                }
                aiAuditTool(s, actor.id, tool, allowed, rounds)
                /* 回灌给模型：只用 payload，不带任何内部字段 */
                let payload = match (jsonGetStr(step, "payload")) {
                    case Some(p) => p
                    case None => "（无结果）"
                }
                history += "第 ${rounds} 轮：$tool -> ${payload}\n"
            }

            if (!done) {
                /* 轮数或预算耗尽：把已查到的数据给出去，别让用户空手而归 */
                answer = aiAgentDegradedAnswer(perms, steps)
            }

            let d = JsonObject()
            jPutStr(d, "answer", answer)
            d.put("steps", steps)
            jPutInt(d, "rounds", rounds)
            jPutInt(d, "calls", calls)
            /* P2：有提议就带上（前端据此渲染 diff + 确认按钮） */
            match (proposalOut) {
                case Some(pj) => d.put("proposal", pj)
                case None => ()
            }
            /*
             * AI-9 修（2026-10-06）：basis **必须与降级路径同形状**（对象数组 [{kind,ref}]）。
             * 此前这里手搓字符串数组，导致同一接口两条路径形状不一致 —— 见 aiBasisAgent 的说明。
             */
            d.put("basis", aiBasisAgent())
            let res = AiResult(src, JsonObject(), note, outcome, aiNowMs() - t0, calls, 0)
            aiPutMeta(d, res)
            sendOk(ctx, d)

        case None =>
            let r = AiResult(AI_SOURCE_FALLBACK, fallback, "智能助手暂不可用（AI 未配置）",
                             "not_configured", 0, 0, 0)
            let d = JsonObject()
            jPutStr(d, "answer", aiPermFallbackAnswer(perms))
            d.put("steps", JsonArray())
            jPutInt(d, "rounds", 0)
            jPutInt(d, "calls", 0)
            d.put("basis", aiBasisFixture(actor.role))
            aiPutMeta(d, r)
            sendOk(ctx, d)
    }
}

/* ===================== 7.7 确认并执行 AI 提议（写操作，P2）===================== */

/*
 * POST /api/v1/ai/agent/confirm —— 执行一个已确认的提议（api-design Part 7.7）
 *
 * ★ 与 Part 7 其余接口**有意分家**：那些是读操作，铁律是「永不 5xx、模型不可用就降级」；
 *   而**写操作失败必须显式报错** —— 用户必须知道"没写成"。静默降级在这里是事故。
 *
 * 六步，每一步失败都中止：
 *   ① 查令牌（key 里含 actorId ⇒ 别人的令牌根本取不到）    -> 404 AI_PROPOSAL_NOT_FOUND
 *   ② 已消费                                              -> 409 AI_PROPOSAL_USED
 *   ③ 过期（**5 分钟窗口必须自己判**；IDEM_TTL 是 24 小时） -> 410 AI_PROPOSAL_EXPIRED
 *   ④ 执行（内部会**重新**跑 can() —— TOCTOU；并走共享的 taskStatusApply）
 *   ⑤ 与执行**同一个锁**内标记 used_at ⇒ 单次消费是原子的
 *
 * ⚠ 这里**不调模型**，所以也不消耗 AI 配额（没有句柄、没有出站请求）。
 */
public func handleAiAgentConfirm(ctx: Context, s: Store, ai: ?AiClient): Unit {
    let actor = requireActive(ctx, s)
    let body = reqObj(ctx)
    let token = reqStrOr(body, "token", "")
    let v = V()
    v.need("token", token, "缺少确认令牌")
    v.done()

    var resourceId: Int64 = 0
    var summary = ""
    var toolName = ""
    s.lock.lock()
    try {
        let now = nowEpoch()
        var rec: IdemRecord = IdemRecord()
        var have = false
        match (aiProposalGet(s, actor.id, token)) {
            case Some(r) =>
                rec = r
                have = true
            case None => ()
        }
        /* ① 不存在 —— 也覆盖"这是别人的令牌"（key 里带了 actorId，取不到） */
        if (!have) {
            throw apiErrMsg("AI_PROPOSAL_NOT_FOUND", "确认令牌不存在或不属于你")
        }
        /* ② 已消费 —— 幂等：告诉用户执行过了，**不二次执行** */
        if (rec.used_at > 0) {
            throw apiErrMsg("AI_PROPOSAL_USED", "这个提议已经执行过了")
        }
        /* ③ 过期 */
        if (now - rec.created_at > AI_PROP_TTL) {
            throw apiErrMsg("AI_PROPOSAL_EXPIRED", "确认已超时（5 分钟），请重新让助手提议")
        }
        /* ④ 解析存下来的提议正文（**不含令牌**，令牌是另加的） */
        var args = JsonObject()
        try {
            match (JsonValue.fromStr(rec.payload)) {
                case pj: JsonObject =>
                    match (jsonGetStr(pj, "tool")) {
                        case Some(x) => toolName = x
                        case None => ()
                    }
                    match (jsonGetObject(pj, "args")) {
                        case Some(a) => args = a
                        case None => ()
                    }
                case _ => ()
            }
        } catch (e: Exception) {
            throw apiErrMsg("AI_PROPOSAL_NOT_FOUND", "确认令牌已损坏")
        }
        if (toolName.size == 0) {
            throw apiErrMsg("AI_PROPOSAL_NOT_FOUND", "确认令牌里没有可执行的操作")
        }
        /* ⑤ 执行 —— 内部重新授权（TOCTOU），并调共享的业务核心 */
        let r = aiToolExecute(s, actor, toolName, args, now)
        resourceId = r[1]
        summary = r[2]
        if (!r[0]) {
            /*
             * 失败**不**标记 used_at：没有副作用发生，让用户可以重试同一个令牌
             * （它仍会在 5 分钟后过期）。这与"已消费"是两回事。
             */
            throw apiErrMsg("AI_PROPOSAL_EXEC_FAILED", summary)
        }
        /* ⑥ 与执行同一个锁内标记 —— 单次消费由此变成原子的 */
        aiProposalConsume(s, actor.id, token, resourceId, now)
        /*
         * 审计：**在这里内联**，不调 aiAuditTool ——
         * 那个函数会自己再取一次 s.lock，而 Mutex 非重入，会**死锁**。
         * （audit() 的契约本来就是"调用方持锁"。）
         * 令牌只记前 8 位，避免日志里的人拿它去确认。
         */
        audit(s, actor.id, "ai_tool_confirm", 0,
              "tool=${toolName} token=${aiPropTag(token)} resource=${resourceId}")
    } finally {
        s.lock.unlock()
    }
    let d = JsonObject()
    jPutStr(d, "tool", toolName)
    jPutInt(d, "resource_id", resourceId)
    jPutStr(d, "summary", summary)
    sendOk(ctx, d)
}
