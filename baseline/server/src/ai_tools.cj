package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * AI 智能体 · 工具白名单与受限执行（api-design Part 7 · POST /api/v1/ai/agent）
 *
 * 对应 docs/llm-client-spec.md §5.6 的 T1–T6：
 *   T1  这里是**唯一**允许执行「由模型产生的动作」的入口。
 *   T2  白名单是**静态表**（aiToolSpecs）—— 模型既不能新增工具，也不能改参数语义。
 *   T3  参数一律当**不可信输入**：取值走既有校验，范围自己再夹一次。
 *   T4  循环上限与总预算由调用方（h_ai.cj 的 aiAgentLoop）控制。
 *   T5  每次调用都写审计（含 denied）—— 由 handler 侧统一写，见 aiAuditTool。
 *   T6  权限判定**只用 can()**，不在 LLM 链路上另写一套 if（会与 perms.cj 漂移）。
 *
 * ★ 本期**只读**（Phase 1）。要升级为读写，只需：往 aiToolSpecs 里加条目、
 *   在 aiToolRun 里加分支 —— 权限门、未知工具拒绝、审计、截断都是共用的，**结构不用改**。
 *
 * ⚠ 锁纪律：`dispatchAiTool` 要求调用方**持 s.lock**（与 aiCandidateLines 同一约定），
 *   而模型调用必须在锁外。所以每一轮固定是：
 *       锁外 调模型 → 锁内 跑 1 个工具（短）→ 锁外 回灌 → 下一轮
 */

import std.collection.*
import stdx.encoding.json.*

/* ---- 工具定义 ---- */

public class AiToolSpec {
    public let name: String
    public let action: Action
    public let label: String
    /* true = 写操作 —— **必须走「提议 → 用户确认 → 执行」**，不能在 agent 循环里直接执行 */
    public let write: Bool

    public init(name: String, action: Action, label: String, write!: Bool = false) {
        this.name = name
        this.action = action
        this.label = label
        this.write = write
    }
}

/*
 * 静态白名单。**模型不能新增工具**（T2）。
 *
 * 本期 5 个**全部只读**。其中只有 `list_pending_members` 在今天就会真的拦人
 * （`AssignPending` 需部长及以上）；其余 4 个按当前「读范围对全社团开放」的口径
 * 对所有 active 成员都放行 —— 但**门仍然要设**：
 *   ① 这是「权限判定只有一处」这条铁律的延续；
 *   ② 读范围一旦收紧（AI-17 / R-7 就是这么埋的坑），它们会自动跟着收紧。
 */
public func aiToolSpecs(): Array<AiToolSpec> {
    return [
        AiToolSpec("list_my_tasks", Action.ViewTasks,
                   "列出**我自己**负责的未完成任务；可选参数 overdue=1 只看已逾期的"),
        AiToolSpec("task_detail", Action.ViewTasks,
                   "按 task_id 查单个任务的详情（标题/状态/负责人/截止时间/所属课题）"),
        AiToolSpec("dept_stats", Action.ViewMembers,
                   "查**我所在部门**的人数与任务统计（在册人数 / 未完成 / 已逾期）"),
        AiToolSpec("list_dept_open_tasks", Action.ViewTasks,
                   "列出**我所在部门**的未完成任务（最多 20 条）"),
        AiToolSpec("list_pending_members", Action.AssignPending,
                   "列出待审批（pending）成员。**需要审批权限**，没有权限的成员会被拒绝"),
        /*
         * ---- 写工具（P2）。**只开 L1**：改自己负责的任务状态。
         * L2（create_task / set_task_due / update_task_status）与 L3（删任务、停用成员、
         * 移交会长等）暂不开；**L3 是永久排除**。
         */
        AiToolSpec("set_my_task_status", Action.UpdateTaskStatus,
                   "把**我自己**负责的任务状态改成 todo / doing / blocked / done；进入 blocked 需要同时给出 blocker。**这是写操作**，需用户确认后才会真正执行",
                   write: true)
    ]
}

/* 给模型看的工具清单（只含名字与说明，**不含权限实现**） */
public func aiToolLines(): String {
    var out = ""
    for (spec in aiToolSpecs()) {
        out += "- ${spec.name}：${spec.label}\n"
    }
    return out
}

/* 单次回灌给模型的结果上限（防 prompt 膨胀，撑破 maxRequestBytes / max-tokens） */
let AI_TOOL_PAYLOAD_MAX: Int64 = 2000
/* 每个工具最多列多少条 */
let AI_TOOL_ROW_MAX: Int64 = 20

/*
 * 按 **UTF-8 字符边界**截断 —— 不能直接按字节切，否则会把中文劈成半个，
 * 回灌给模型的就成乱码了。
 */
func aiToolCut(s: String): String {
    if (s.size <= AI_TOOL_PAYLOAD_MAX) {
        return s
    }
    let b = s.toArray()
    var n = AI_TOOL_PAYLOAD_MAX
    while (n > 0 && (b[n] & UInt8(192)) == UInt8(128)) {
        n -= 1
    }
    return String.fromUtf8(b[0..n]) + "…（已截断）"
}

/*
 * 合成目标：与 aiPermFacts 同一口径 —— **必须显式填 `target_role`**。
 * 留空会撞上 `outranks()` 的 fail-closed（"目标档位未知，宁拒不放过"），
 * 把依赖档位的规则一律判否 —— 那个坑在权限清单上已经踩过一次。
 */
func aiToolTarget(actor: Member): Target {
    let tgt = Target()
    tgt.dept_id = actor.dept_id
    tgt.is_self = false
    tgt.target_role = "member"
    return tgt
}

/* ---- 唯一入口 ---- */

/*
 * 执行一个工具。**调用方必须持 `s.lock`**。
 *
 * 返回 `{ tool, allowed, summary, payload }`：
 *   · `allowed=false` 时 `payload` 是**中性文案** —— 不告诉模型具体缺哪个权限，
 *     避免这个接口被当成权限探测面（T6 的推论）。
 *   · `summary` 只用于审计，不含隐私。
 */
public func dispatchAiTool(s: Store, actor: Member, tool: String, args: JsonObject,
                           now: Int64): JsonObject {
    let out = JsonObject()
    jPutStr(out, "tool", tool)

    /* ① 白名单：不在表里一律拒 —— 模型不能凭空发明工具 */
    var found: ?AiToolSpec = None
    for (x in aiToolSpecs()) {
        if (x.name == tool) {
            found = Some(x)
        }
    }
    let spec = match (found) {
        case Some(x) => x
        case None =>
            jPutBool(out, "allowed", false)
            jPutStr(out, "summary", "未知工具")
            jPutStr(out, "payload", "该工具不存在。只能用系统提示里列出的工具。")
            return out
    }

    /* ② 权限：唯一入口是 can()（T6） */
    if (!can(actor, spec.action, aiToolTarget(actor))) {
        jPutBool(out, "allowed", false)
        jPutStr(out, "summary", "权限不足")
        jPutStr(out, "payload", "你没有执行该操作所需的权限。请不要重试这个工具。")
        return out
    }

    /* ③ 执行（本期全部只读） */
    let r = aiToolRun(s, actor, tool, args, now)
    jPutBool(out, "allowed", true)
    jPutStr(out, "summary", r[0])
    jPutStr(out, "payload", aiToolCut(r[1]))
    return out
}

/* ---- 各工具的实现（只读，调用方持锁） ---- */

func aiToolRun(s: Store, actor: Member, tool: String, args: JsonObject,
               now: Int64): (String, String) {
    if (tool == "list_my_tasks") {
        let onlyOverdue = match (jsonGetInt64(args, "overdue")) {
            case Some(v) => v == 1
            case None => false
        }
        var lines = ""
        var n: Int64 = 0
        for ((_, t) in s.tasks) {
            if (t.deleted_at != 0 || t.owner_id != actor.id || t.status == "done") {
                continue
            }
            if (onlyOverdue && !isTaskOverdue(t, now)) {
                continue
            }
            if (n >= AI_TOOL_ROW_MAX) {
                break
            }
            lines += "- id=${t.id} ${t.title}（状态 ${t.status}，已逾期 ${overdueDaysOf(t, now)} 天）\n"
            n += 1
        }
        if (n == 0) {
            return ("0 条", "没有符合条件的任务。")
        }
        return ("${n} 条", "我负责的未完成任务：\n${lines}")
    }

    if (tool == "task_detail") {
        let id = match (jsonGetInt64(args, "task_id")) {
            case Some(v) => v
            case None => 0
        }
        if (id <= 0) {
            return ("参数非法", "task_id 必须是正整数。")
        }
        var t: Task = Task()
        var ok = false
        match (s.tasks.get(id)) {
            case Some(x) =>
                t = x
                ok = true
            case None => ()
        }
        if (!ok || t.deleted_at != 0) {
            return ("未找到", "没有 id=${id} 这个任务。")
        }
        var owner = "（未指定）"
        match (s.members.get(t.owner_id)) {
            case Some(m) => owner = m.name
            case None => ()
        }
        var dueStr = "未设截止时间"
        if (t.due_at > 0) {
            dueStr = isoLocal(t.due_at)
        }
        return ("1 条",
                "任务 id=${t.id}\n标题：${t.title}\n状态：${t.status}\n负责人：${owner}\n" +
                "截止时间：${dueStr}\n已逾期：${overdueDaysOf(t, now)} 天")
    }

    if (tool == "dept_stats") {
        var people: Int64 = 0
        for ((_, m) in s.members) {
            if (m.status == "active" && m.dept_id == actor.dept_id) {
                people += 1
            }
        }
        var open: Int64 = 0
        var late: Int64 = 0
        for ((_, t) in s.tasks) {
            if (t.deleted_at != 0 || t.dept_id != actor.dept_id || t.status == "done") {
                continue
            }
            open += 1
            if (isTaskOverdue(t, now)) {
                late += 1
            }
        }
        return ("人数 ${people} / 未完成 ${open} / 逾期 ${late}",
                "本部门（dept_id=${actor.dept_id}）：在册 ${people} 人，" +
                "未完成任务 ${open} 条，其中已逾期 ${late} 条。")
    }

    if (tool == "list_dept_open_tasks") {
        var lines = ""
        var n: Int64 = 0
        for ((_, t) in s.tasks) {
            if (t.deleted_at != 0 || t.dept_id != actor.dept_id || t.status == "done") {
                continue
            }
            if (n >= AI_TOOL_ROW_MAX) {
                break
            }
            var owner = ""
            match (s.members.get(t.owner_id)) {
                case Some(m) => owner = m.name
                case None => ()
            }
            lines += "- id=${t.id} ${t.title}（状态 ${t.status}，负责人 ${owner}）\n"
            n += 1
        }
        if (n == 0) {
            return ("0 条", "本部门没有未完成任务。")
        }
        return ("${n} 条", "本部门的未完成任务：\n${lines}")
    }

    if (tool == "list_pending_members") {
        var lines = ""
        var n: Int64 = 0
        for ((_, m) in s.members) {
            if (m.status != "pending") {
                continue
            }
            if (n >= AI_TOOL_ROW_MAX) {
                break
            }
            /* 只回姓名与预填部门 —— **绝不回手机号**（那是 PII，不该进第三方 prompt） */
            var hint = ""
            match (s.departments.get(m.dept_hint)) {
                case Some(d) => hint = d.name
                case None => ()
            }
            if (hint.size == 0) {
                hint = "未指定"
            }
            lines += "- ${m.name}（申请加入：${hint}）\n"
            n += 1
        }
        if (n == 0) {
            return ("0 条", "当前没有待审批成员。")
        }
        return ("${n} 条", "待审批成员（共 ${n} 人）：\n${lines}")
    }

    /* 白名单已挡过，走到这里说明表与实现不同步 —— 明确报出来，不要静默 */
    return ("未实现", "该工具暂未实现。")
}

/* ===================== 写工具：提议 / 执行 两半（P2）===================== */

/*
 * 写操作的**唯一入口**分两半，由 `handleAiAgent` / `handleAiAgentConfirm` 分别调用：
 *
 *   aiToolPropose  —— 只读：校验参数 + 算出**服务端 diff**，产出一个「提议」
 *   aiToolExecute  —— 落库：重新授权 + 调共享的业务核心
 *
 * ★ 为什么必须有这两半：读操作可以在 agent 循环里直接执行，**写操作不行**。
 *   模型提议 → 用户在界面上看到 diff 并确认 → 服务端才执行。
 *   这样"模型永远不能单次往返就产生副作用"。
 *
 * ⚠ 两半的校验职责**不同**，这是有意设计：
 *   · `aiToolPropose` 的校验是**体验层的预筛** —— 目的是"别让用户确认一个注定失败的提议"。
 *     它可以比执行层宽松（例如只查任务存在与状态枚举）。
 *   · `aiToolExecute` 的校验才是**权威** —— 它调共享的 `taskStatusApply`，
 *     与 HTTP handler **同一份规则**，不存在第二份定义。
 *   所以即便预筛将来与业务规则有细微漂移，也只是"提议没被当场拦下"，
 *   **不可能**让不合规的写落库。
 */

func aiArgInt(args: JsonObject, key: String): Int64 {
    return match (jsonGetInt64(args, key)) {
        case Some(v) => v
        case None => 0
    }
}

func aiArgStr(args: JsonObject, key: String): String {
    return match (jsonGetStr(args, key)) {
        case Some(v) => v
        case None => ""
    }
}

/*
 * 产出一个提议。返回 None 表示"参数不成形 / 预筛不过"，调用方应当让模型重试或收尾。
 *
 * 返回的 `diff` **由服务端读当前值算出来**，不是模型的措辞 ——
 * 用户确认的是服务端的 diff（G6）。
 *
 * **幂等性：本函数只读，不碰任何被提议修改的对象。**
 */
public func aiToolPropose(s: Store, actor: Member, tool: String, args: JsonObject,
                          now: Int64): ?JsonObject {
    if (tool != "set_my_task_status") {
        return None
    }
    let id = aiArgInt(args, "task_id")
    let status = aiArgStr(args, "status")
    if (id <= 0 || !isTaskStatus(status)) {
        return None
    }
    var t: Task = Task()
    var found = false
    match (activeTaskById(s, id)) {
        case Some(x) =>
            t = x
            found = true
        case None => ()
    }
    if (!found) {
        return None
    }
    /* 预筛：进入 blocked 必须给 blocker（真正的权威判定在 taskStatusApply 里） */
    if (status == "blocked" && isBlank(aiArgStr(args, "blocker"))) {
        return None
    }

    let diff = JsonArray()
    if (t.status != status) {
        let d = JsonObject()
        jPutStr(d, "field", "status")
        jPutStr(d, "from", t.status)
        jPutStr(d, "to", status)
        diff.add(d)
    }
    let out = JsonObject()
    jPutStr(out, "tool", tool)
    /* title 由**服务端**给，不用模型的措辞（G6） */
    jPutStr(out, "title", "修改任务状态")
    jPutStr(out, "target", "#${t.id} ${t.title}")
    out.put("args", args)
    out.put("diff", diff)
    return Some(out)
}

/*
 * 执行一个写工具。**调用方必须持 `s.lock`**。
 * 返回 `(是否成功, 资源 id, 给用户看的一句话)`。
 *
 * ⚠ 这里**重新**跑 `can()`（TOCTOU）：提议到确认之间，角色可能被降级、
 *   任务可能被转交、读范围可能收紧 —— **不复用提议时的判定**。
 */
public func aiToolExecute(s: Store, actor: Member, tool: String, args: JsonObject,
                          now: Int64): (Bool, Int64, String) {
    if (tool != "set_my_task_status") {
        return (false, 0, "该写工具未实现")
    }
    let id = aiArgInt(args, "task_id")
    var t: Task = Task()
    var found = false
    match (activeTaskById(s, id)) {
        case Some(x) =>
            t = x
            found = true
        case None => ()
    }
    if (!found) {
        return (false, 0, "任务已不存在（可能刚被删除）")
    }
    /* 执行时的**权威**授权判定（TOCTOU）—— 唯一入口仍是 can() */
    if (!can(actor, Action.UpdateTaskStatus, targetOfTask(actor, t))) {
        return (false, 0, "你现在没有修改这个任务的权限")
    }
    let status = aiArgStr(args, "status")
    try {
        /* 与 HTTP handler **同一份规则**：blocked 必填 blocker、求助对象校验、
           两阶段纪律、completed_at 语义 —— 全部走共享的 taskStatusApply。 */
        taskStatusApply(s, t, status, aiArgStr(args, "blocker"),
                        aiArgInt(args, "help_dept_id"), aiArgInt(args, "help_member_id"), now)
    } catch (e: Exception) {
        return (false, 0, "执行被业务规则拒绝：${e.message}")
    }
    return (true, t.id, "已把「${t.title}」的状态改为 ${status}")
}
