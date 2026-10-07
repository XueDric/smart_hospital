/*
 * ===== 分工标注（用于课程/项目分工归属，非功能代码） =====================
 * 主要修改者：Haocheng Sun <2396556545@qq.com>
 *   提交 f7b34aa  后端修复：P1 权限/并发缺陷 + 非数据层输入加固（含运维台 9 条）
 *   提交 8a9e11c  复核修正：8 处「自述与代码不符 / 与既有契约冲突」
 * 本人改动量：+135 / -27（git log --author 统计；标注日期 2026-09-18）
 * 算法相关：任务↔课题的部门一致性判定（N-18）已抽成 taskPlanDeptOk() 并**移入 store.cj**
 * =====================================================================
 */
package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * Part 4 · 任务 —— 8 个接口
 *
 * 本部分是工具的核心：第 1 节的第二个问题「每件事由谁负责、做到什么程度」全落在这里。
 *
 * 三条不能打折的规则：
 *   · **一个任务只能有一个负责人**（必填且不可置空）——多个负责人等于没人负责
 *   · **状态只有 4 档**，不做进度百分比；「逾期」是派生量，永不落盘（规则 2/15）
 *   · **进入 blocked 必须填 blocker**，离开时自动清空——这是信息量最大的字段
 *
 * ⚠ 锁规则：requireActive 内部加锁；handler 先认证、再单独加锁。
 */

import std.collection.*
import stdx.encoding.json.*

/* 权限判定目标：把任务的三个关键事实交给 can()。 */
func targetOfTask(actor: Member, t: Task): Target {
    let tgt = Target()
    tgt.dept_id = t.dept_id
    tgt.owner_id = t.owner_id
    tgt.creator_id = t.created_by
    tgt.is_self = (t.owner_id == actor.id)
    return tgt
}

/*
 * 「我的任务」首页的分组（纯函数，便于单测）
 *
 * D-4（2026-09-16）：`deptScopeId > 0` 时，除自己负责的任务外，**额外**把
 * 本部门成员处于 `blocked` 的任务也纳入（设计规格 P03 的
 * 「部长在首页即可看到这条」）。调用方只在操作者是部长 / 副部长时传自己的部门 id，
 * 其余角色传 0（会长 / 副会长要看全貌走任务列表，不该让首页被别人的阻塞项淹没）。
 */
public class MineGroups {
    public var overdue: Array<Task> = Array<Task>()
    public var blocked: Array<Task> = Array<Task>()
    public var due_today: Array<Task> = Array<Task>()
    public var due_week: Array<Task> = Array<Task>()
    public var later: Array<Task> = Array<Task>()
    public var no_due: Array<Task> = Array<Task>()
    public var open_total: Int64 = 0
    public var borrowed: Int64 = 0   /* 其中"不是自己负责、但本部门被阻塞"的条数 */

    public init() {}
}

/*
 * 分组口径（服务端算，客户端不重复实现——否则跨设备口径会不一致）：
 *   overdue    due_at < 现在
 *   due_today  今天之内到期
 *   due_week   未来 7 天内（滚动窗口，不按自然周；否则周日会让该组变空）
 *   later      再往后
 *   no_due     没有截止时间
 *   blocked    **额外**一组：阻塞是状态，逾期是时间事实，两者不互斥（api-design §4.1）
 *
 * 只列**未完成**任务：首页是"我负责什么"，已完成的不该再出现在逾期里。
 * 本部门被阻塞的任务（borrowed）同样进 blocked 组，并按同一套时间桶进入时间分组
 * —— 与设计稿「阻塞项同时也会出现在下面的时间分组里」一致。
 */
public func groupMine(s: Store, ownerId: Int64, now: Int64, deptScopeId: Int64): MineGroups {
    let g = MineGroups()
    let todayStart = startOfLocalDay(now)
    let tomorrow = todayStart + DAY_SECONDS
    let weekEnd = todayStart + 7 * DAY_SECONDS

    let overdue = ArrayList<Task>()
    let blocked = ArrayList<Task>()
    let today = ArrayList<Task>()
    let week = ArrayList<Task>()
    let later = ArrayList<Task>()
    let none = ArrayList<Task>()

    for ((_k, t) in s.tasks) {
        if (t.deleted_at > 0) {
            continue
        }
        let mine = (t.owner_id == ownerId)
        /*
         * 「本部门被阻塞」= 别人负责 + 本部门 + blocked。
         * 不额外要求 needs_help（help_dept_id）非空：设计规格 P01 的首页里，
         * 部长看到的是一条**没标求助对象**的阻塞任务；标了求助对象的走同一组，
         * 客户端用 needs_help 决定是否渲染「需要帮助 · …」那一行。
         */
        let borrowed = !mine && deptScopeId > 0 && t.status == "blocked" && t.dept_id == deptScopeId
        if (!mine && !borrowed) {
            continue
        }
        if (t.status == "done") {
            continue
        }
        if (borrowed) {
            g.borrowed += 1
        }
        g.open_total += 1
        if (t.status == "blocked") {
            blocked.add(t)
        }
        if (t.due_at <= 0) {
            none.add(t)
            continue
        }
        if (t.due_at < now) {
            overdue.add(t)
            continue
        }
        if (t.due_at < tomorrow) {
            today.add(t)
            continue
        }
        if (t.due_at < weekEnd) {
            week.add(t)
            continue
        }
        later.add(t)
    }

    g.overdue = sortedTasksByDue(overdue)
    g.blocked = sortedTasksByDue(blocked)
    g.due_today = sortedTasksByDue(today)
    g.due_week = sortedTasksByDue(week)
    g.later = sortedTasksByDue(later)
    g.no_due = sortedTasksByDue(none)
    return g
}

/*
 * GET /api/v1/tasks/mine —— **v1 最重要的接口**
 *
 * 真正让人每天打开 App 的是「我负责什么」，不是组织架构图。
 * 主体永远是自己负责的任务，因此不需要 can() 判定。
 *
 * D-4（2026-09-16）唯一的例外：**部长 / 副部长**的首页还会带上「本部门成员的阻塞项」
 * —— 设计规格 P03 原文「需要帮助 · 宣传部 陈屿（部长在首页即可看到这条）」，
 * 对应 P01 里部长看到的「运营部 · 负责人 王砚」那条别人的阻塞任务。
 * 这不是可见性放宽（读范围本身已全社团开放），而是"该谁管就该在谁的首页出现"。
 * 会长 / 副会长不参与这一条：他们要全貌走任务列表，首页不该被全社团的阻塞项淹没。
 */
public func handleTasksMine(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    /* 只有部长 / 副部长带部门范围；其余角色为 0（只看自己的） */
    let deptScopeId = if (actor.role == "lead" || actor.role == "vice_lead") {
        actor.dept_id
    } else {
        0
    }
    s.lock.lock()
    try {
        let now = nowEpoch()
        let g = groupMine(s, actor.id, now, deptScopeId)
        let data = JsonObject()
        data.put("overdue", taskArr(s, g.overdue, now))
        data.put("blocked", taskArr(s, g.blocked, now))
        data.put("due_today", taskArr(s, g.due_today, now))
        data.put("due_week", taskArr(s, g.due_week, now))
        data.put("later", taskArr(s, g.later, now))
        data.put("no_due", taskArr(s, g.no_due, now))
        let counts = JsonObject()
        jPutInt(counts, "overdue", g.overdue.size)
        jPutInt(counts, "blocked", g.blocked.size)
        jPutInt(counts, "open_total", g.open_total)
        /* 其中有多少条是"本部门别人的阻塞项"（部长 / 副部长才会有非零值） */
        jPutInt(counts, "borrowed_blocked", g.borrowed)
        jPutObj(data, "counts", counts)
        sendOk(ctx, data)
    } finally {
        s.lock.unlock()
    }
}

/* GET /api/v1/tasks —— 列表（按 view_scope 过滤 + 筛选 + 分页） */
public func handleTaskList(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    let fDept = queryIntOr(ctx, "dept_id", 0)
    let fOwner = queryIntOr(ctx, "owner_id", 0)
    let fStatus = ctx.queryParamOr("status", "")
    let fPlan = queryIntOr(ctx, "plan_id", 0)
    let fOverdue = ctx.queryParamOr("overdue", "") == "true"
    let includeSub = ctx.queryParamOr("include_subplans", "true") != "false"

    s.lock.lock()
    try {
        let now = nowEpoch()
        var planScope: ?HashSet<Int64> = None
        if (fPlan > 0) {
            match (s.plans.get(fPlan)) {
                case Some(_) => ()
                case None => throw apiErr("PLAN_NOT_FOUND")
            }
            if (includeSub) {
                planScope = Some(planSubtreeIds(s, fPlan))
            } else {
                let only = HashSet<Int64>()
                only.add(fPlan)
                planScope = Some(only)
            }
        }

        let picked = ArrayList<Task>()
        for ((_k, t) in s.tasks) {
            if (t.deleted_at > 0) {
                continue
            }
            if (fDept > 0 && t.dept_id != fDept) {
                continue
            }
            if (fOwner > 0 && t.owner_id != fOwner) {
                continue
            }
            if (fStatus.size > 0 && t.status != fStatus) {
                continue
            }
            match (planScope) {
                case Some(ids) =>
                    if (!ids.contains(t.plan_id)) {
                        continue
                    }
                case None => ()
            }
            if (fOverdue && !isTaskOverdue(t, now)) {
                continue
            }
            if (!can(actor, Action.ViewTasks, targetOfTask(actor, t))) {
                continue
            }
            picked.add(t)
        }
        let sorted = sortedTasksByDue(picked)
        let out = ArrayList<JsonObject>()
        for (t in sorted) {
            out.add(taskBrief(s, t, now))
        }
        sendOk(ctx, pagedJson(ctx, out))
    } finally {
        s.lock.unlock()
    }
}

/* GET /api/v1/tasks/{id} */
public func handleTaskDetail(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    let id = pathIdOr(ctx, "TASK_NOT_FOUND")
    s.lock.lock()
    try {
        let t = match (activeTaskById(s, id)) {
            case Some(x) => x
            case None => throw apiErr("TASK_NOT_FOUND")
        }
        requireAccess(actor, Action.ViewTasks, targetOfTask(actor, t))
        sendOk(ctx, taskDetail(s, t, nowEpoch()))
    } finally {
        s.lock.unlock()
    }
}

/*
 * POST /api/v1/tasks
 *
 * 幂等：带 `client_token` 时 24 小时内重复提交返回首次结果（HTTP 200 + duplicated: true）。
 * 移动网络不稳定，用户点一下没反应就会再点一次——这个成本很低，能挡掉
 * "一个任务被创建三遍"这类最常见的脏数据。
 */
public func handleTaskCreate(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    let body = reqObj(ctx)
    let v = V()
    let title = v.need("title", reqStrOr(body, "title", ""), "请输入任务标题")
    /*
     * 2026-09-17：文本字段长度上限。三个都放进同一个 V 里收齐再抛（与"一次把所有字段问题
     * 收齐、让表单逐字段提示"的既有口径一致）。为什么必须有：这些字段整份进 db.json，
     * 而**每次写都要重写整个库**（约 3 倍文件大小的 IO）—— 一条 1 MiB 的 desc 会被反复重写，
     * 且一条就顶上千条正常任务。上限见 limits.cj。
     */
    let desc = reqStrOr(body, "desc", "")
    let clientToken = reqStrOr(body, "client_token", "")
    lenCheck(v, "title", "标题", title, MAX_TITLE_BYTES)
    lenCheck(v, "desc", "描述", desc, MAX_DESC_BYTES)
    lenCheck(v, "client_token", "幂等键", clientToken, MAX_CLIENT_TOKEN_BYTES)
    v.done()
    let ownerId = reqIntOr(body, "owner_id", 0)
    if (ownerId <= 0) {
        throw apiErrFields("VALIDATION_FAILED", "参数校验失败",
            oneField("owner_id", "必须指定唯一的负责人"))
    }
    let planId = reqIntOr(body, "plan_id", 0)
    /*
     * 2026-09-17：负数 plan_id 原先会被**原样落库**，并且让下面那条"负责人必须与课题同部门"
     * 的校验（N-18）整段跳过 —— 它判的是 `planId > 0`。api-design 的口径是
     * "0 = 独立任务、> 0 = 挂课题"，负数不是合法输入：明确报错，不静默收下。
     */
    if (planId < 0) {
        throw apiErrFields("VALIDATION_FAILED", "参数校验失败",
            oneField("plan_id", "plan_id 必须是 0（独立任务）或正整数（课题 id）"))
    }
    let dueAt = reqTime(body, "due_at")

    s.lock.lock()
    try {
        let now = nowEpoch()
        if (clientToken.size > 0) {
            match (idemHit(s, "task", actor.id, clientToken, now)) {
                case Some(rid) =>
                    match (activeTaskById(s, rid)) {
                        case Some(existing) =>
                            /* 命中也不能免检：拿首次结果回放之前，按本次操作者重新判一次
                             * 查看权限（P0 H-2）。键里已经带了 actorId，这一层是防御纵深——
                             * 万一将来有人改动键的构成，越权读也不会被顺手放回来。 */
                            requireAccess(actor, Action.ViewTasks, targetOfTask(actor, existing))
                            let data = JsonObject()
                            jPutObj(data, "task", taskDetail(s, existing, now))
                            jPutBool(data, "duplicated", true)
                            sendOk(ctx, data)
                            return
                        case None => ()
                    }
                case None => ()
            }
        }

        let owner = match (s.members.get(ownerId)) {
            case Some(m) => m
            case None => throw apiErr("MEMBER_NOT_FOUND")
        }
        if (owner.status == "pending") {
            throw apiErr("MEMBER_PENDING")
        }
        if (owner.status == "disabled") {
            throw apiErr("MEMBER_DISABLED")
        }
        /* 分配范围：部长/副部长只能分给本部门成员；会长/副会长可跨部门。
         * 用 owner 的部门构造目标，can() 里就是这一条。 */
        let tgt = Target()
        tgt.dept_id = owner.dept_id
        tgt.owner_id = owner.id
        requireAccess(actor, Action.CreateTask, tgt)

        if (planId > 0) {
            match (s.plans.get(planId)) {
                case Some(_) => ()
                case None => throw apiErr("PLAN_NOT_FOUND")
            }
            /*
             * N-18（部门边界）：任务的**负责人**必须与课题同部门。
             * 原实现只校验"课题存在"，于是 A 部门的部长能把自己部门的任务挂进 B 部门的课题，
             * 而 handlePlanDetail 列本级任务时不再逐条 can()（前提是"能看课题就能看它的任务"），
             * B 部门的人因此在课题详情里读到了这个任务 —— 跨部门的信息可见性。
             * 口径已先落回 api-design.md §4.1（「任务创建」的 plan_id 字段说明）。
             * 2026-09-18：判定抽到 store.taskPlanDeptOk()，与编辑/转交路径共用一份
             * （原先两处各内联写一遍）。
             */
            if (!taskPlanDeptOk(s, planId, owner.dept_id)) {
                throw apiErrMsg("FORBIDDEN_NOT_IN_DEPT", "课题属于其它部门，不能把任务挂到跨部门的课题下")
            }
        }

        let t = Task()
        t.id = s.next_task
        s.next_task += 1
        t.title = title
        t.desc = desc
        t.owner_id = ownerId
        t.plan_id = planId
        t.dept_id = owner.dept_id
        t.status = "todo"
        t.due_at = dueAt
        t.created_by = actor.id
        t.created_at = now
        t.updated_at = now
        s.tasks[t.id] = t
        if (clientToken.size > 0) {
            idemPut(s, "task", actor.id, clientToken, t.id, now)
        }
        storeSave(s)

        let data = JsonObject()
        jPutObj(data, "task", taskDetail(s, t, now))
        sendCreated(ctx, data)
    } finally {
        s.lock.unlock()
    }
}

/*
 * 2026-09-17：PATCH /tasks/{id} 的字段白名单闸门（调用点见 handleTaskUpdate）。
 *
 * **两层**，缺一不可：
 *   ① 具名名单：server 权威字段（状态 / 阻塞 / 部门 / 时间 / 来源）单独列出来，
 *      命中时给出"该走哪个接口"的处置提示，与 v1-scope 规则 20（服务端权威）一一对应。
 *   ② 兜底白名单：本接口**只接受** title / desc / owner_id / plan_id / due_at ——
 *      除这 5 个之外的任何键（含拼错的 `titel`、`foo`）一律拒。
 *
 * ⚠ 为什么 ② 不能省（2026-09-17 修）：只有 ① 的时候，"未知字段"仍然会被静默忽略并
 *   返回 200 —— 那正是本闸门要消灭的形态（调用方以为改成功了，实际什么都没变）。
 *   而 stdx 的 `JsonObject` **不能枚举键**（不实现 Iterator，也没有 `keys()`，
 *   见 docs/API-NOTES.md；已用编译探针确认 `keys` 不是成员），所以用
 *   "**键数 > 白名单命中数**"来判定是否存在不认识的字段：
 *   JSON 解析进 HashMap，同键只留一个，因此键数比命中数多 ⇒ 一定有多余的键。
 *   代价是报错无法点出那个键的名字，只能说明本接口接受哪些字段 —— 这比静默忽略好。
 *   （`JsonObject.size()` 与 `containsKey()` 都可用，同样是编译探针确认的。）
 */
func rejectUnknownTaskFields(body: JsonObject): Unit {
    let immutable: Array<String> = [
        "status", "blocker", "help_dept_id", "help_member_id", "dept_id",
        "id", "created_at", "updated_at", "completed_at", "deleted_at", "created_by", "source"
    ]
    for (k in immutable) {
        if (body.containsKey(k)) {
            throw apiErrFields("VALIDATION_FAILED", "参数校验失败",
                oneField(k, "${k} 不能通过本接口修改：状态与阻塞信息走 PUT /tasks/{id}/status，部门随负责人、时间字段由服务端生成"))
        }
    }
    let allowed: Array<String> = ["title", "desc", "owner_id", "plan_id", "due_at"]
    var hit: Int64 = 0
    for (k in allowed) {
        if (body.containsKey(k)) {
            hit += 1
        }
    }
    if (body.size() > hit) {
        throw apiErrFields("VALIDATION_FAILED", "参数校验失败",
            oneField("body", "请求体含有本接口不接受的字段；本接口只接受 title / desc / owner_id / plan_id / due_at（状态走 PUT /tasks/{id}/status）"))
    }
}

/*
 * PATCH /api/v1/tasks/{id}
 * 字段全部可选：title / desc / owner_id / due_at / plan_id
 * 改 owner_id 就是**转交**，会更新 updated_at，并且**部门标签跟随新负责人**。
 */
public func handleTaskUpdate(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    let id = pathIdOr(ctx, "TASK_NOT_FOUND")
    let body = reqObj(ctx)

    s.lock.lock()
    try {
        let t = match (activeTaskById(s, id)) {
            case Some(x) => x
            case None => throw apiErr("TASK_NOT_FOUND")
        }
        requireAccess(actor, Action.EditTask, targetOfTask(actor, t))
        /*
         * 2026-09-17：白名单之外的字段**明确报错**，不再静默忽略。
         *
         * 本接口只接受 title / desc / owner_id / plan_id / due_at。客户端若顺手带上
         * status / blocker / help_*，原先的行为是"响应 200 但什么都没变"——调用方以为改成功了
         * （首页上那条任务还在 blocked 里），这正是"绝不静默忽略"纪律要避免的形态。
         * dept_id 与服务端权威字段（id / created_at / updated_at / completed_at /
         * deleted_at / created_by / source）更不能收：前者跟着负责人走，后者只由服务端生成
         * （v1-scope 规则 20）。与 h_dept.cj 对 lead_id 的处理同一口径（也是明确报错 +
         * 告诉调用方该走哪条路）。
         */
        /*
         * ⚠ 位置：本调用排在 requireAccess **之后**（与 h_plan.cj:442 的负数校验同一顺序纪律）。
         *   顺序是"先认证 → 再授权 → 最后校验入参"——否则无权用户带个拼错的字段名拿到的是 400，
         *   而真实原因是 403，客户端会把权限问题当成输入问题。
         *   （2026-09-18 复核补记：行为本身一直正确，原先只是没写明理由。）
         */
        rejectUnknownTaskFields(body)
        var touched = false

        /* ---------- 阶段一：只收集 + 校验，**绝不碰 t**（N-15） ----------
         * t 是 s.tasks 里的活引用，"边校验边赋值"会让被 4xx 拒绝的请求留下半改状态。 */
        var nextTitle: ?String = None
        match (reqOptionalStr(body, "title")) {
            case Some(x) =>
                if (isBlank(x)) {
                    throw apiErrFields("VALIDATION_FAILED", "参数校验失败", oneField("title", "标题不能为空"))
                }
                /* 2026-09-17：长度上限见 limits.cj（一条超长记录会被反复整库重写） */
                requireLen("title", "标题", x, MAX_TITLE_BYTES)
                nextTitle = Some(x)
            case None => ()
        }
        var nextDesc: ?String = None
        match (reqOptionalStr(body, "desc")) {
            case Some(x) =>
                requireLen("desc", "描述", x, MAX_DESC_BYTES)
                nextDesc = Some(x)
            case None => ()
        }
        var nextOwner: ?Int64 = None
        var nextOwnerDept: Int64 = 0
        match (reqOptionalInt(body, "owner_id")) {
            case Some(oid) =>
                if (oid <= 0) {
                    throw apiErrFields("VALIDATION_FAILED", "参数校验失败",
                        oneField("owner_id", "负责人不能置空——任务必须始终有人负责"))
                }
                let owner = match (s.members.get(oid)) {
                    case Some(m) => m
                    case None => throw apiErr("MEMBER_NOT_FOUND")
                }
                /* L-8：原先无论 pending 还是 disabled 都报 MEMBER_PENDING，
                 * 客户端会提示「尚未被分配」，而真实原因是「已被移出社团」。
                 * 两种状态给两个码，与创建路径（本文件 handleTaskCreate）保持一致。 */
                if (owner.status == "pending") {
                    throw apiErrMsg("MEMBER_PENDING", "目标成员尚未被分配，不能接任务")
                }
                if (owner.status == "disabled") {
                    throw apiErrMsg("MEMBER_DISABLED", "目标成员已被移出社团，不能接任务")
                }
                /* 转交同样受分配范围约束 */
                let tgt2 = Target()
                tgt2.dept_id = owner.dept_id
                tgt2.owner_id = owner.id
                requireAccess(actor, Action.CreateTask, tgt2)
                nextOwner = Some(oid)
                nextOwnerDept = owner.dept_id
            case None => ()
        }
        var nextPlan: ?Int64 = None
        match (reqOptionalInt(body, "plan_id")) {
            case Some(pid) =>
                /* 2026-09-17：负数不是合法输入（0 = 独立任务）。原先它会原样落库，
                 * 并让下面那条 N-18 部门一致性校验整段跳过（它判 `effPlan > 0`）。 */
                if (pid < 0) {
                    throw apiErrFields("VALIDATION_FAILED", "参数校验失败",
                        oneField("plan_id", "plan_id 必须是 0（独立任务）或正整数（课题 id）"))
                }
                if (pid > 0) {
                    match (s.plans.get(pid)) {
                        case Some(_) => ()
                        case None => throw apiErr("PLAN_NOT_FOUND")
                    }
                }
                nextPlan = Some(pid)
            case None => ()
        }
        /* due_at 要区分"没传"和"传了 null"：显式传 null 表示清空截止时间 */
        var dueGiven = false
        var dueVal: Int64 = 0
        if (body.containsKey("due_at")) {
            dueVal = reqTime(body, "due_at")
            dueGiven = true
        }

        /*
         * N-18（部门边界）：只要本次动到了 owner 或 plan，就要求**结果状态**里
         * "任务的负责人与课题同部门"。只在动到这两个字段时检查，
         * 这样历史数据本来就不一致时也不会连改名都被挡住。
         */
        if (nextOwner.isSome() || nextPlan.isSome()) {
            var effOwner: Int64 = t.owner_id
            match (nextOwner) {
                case Some(x) => effOwner = x
                case None => ()
            }
            var effPlan: Int64 = t.plan_id
            match (nextPlan) {
                case Some(x) => effPlan = x
                case None => ()
            }
            if (effPlan > 0 && effOwner > 0) {
                var ownerDept: Int64 = 0
                match (s.members.get(effOwner)) {
                    case Some(m) => ownerDept = m.dept_id
                    case None => ()
                }
                if (!taskPlanDeptOk(s, effPlan, ownerDept)) {
                    throw apiErrMsg("FORBIDDEN_NOT_IN_DEPT", "任务的负责人与课题不在同一部门")
                }
            }
        }

        /* ---------- 阶段二：全部通过之后才落值（N-15） ---------- */
        match (nextTitle) {
            case Some(x) =>
                t.title = x
                touched = true
            case None => ()
        }
        match (nextDesc) {
            case Some(x) =>
                t.desc = x
                touched = true
            case None => ()
        }
        match (nextOwner) {
            case Some(oid) =>
                t.owner_id = oid
                t.dept_id = nextOwnerDept
                touched = true
            case None => ()
        }
        match (nextPlan) {
            case Some(pid) =>
                t.plan_id = pid
                touched = true
            case None => ()
        }
        if (dueGiven) {
            t.due_at = dueVal
            touched = true
        }
        /*
         * 2026-09-17：落库的 updated_at 与响应里给客户端算派生量用的 now 必须是**同一个**
         * 时间戳。原先各取一次 nowEpoch()，跨秒时会出现"响应里的时间比库里新 1 秒"。
         */
        let now = nowEpoch()
        if (touched) {
            t.updated_at = now
            storeSave(s)
        }
        sendOk(ctx, taskDetail(s, t, now))
    } finally {
        s.lock.unlock()
    }
}

/*
 * PUT /api/v1/tasks/{id}/status —— 状态流转与阻塞原因
 *
 * 1. 进入 blocked 必须带 blocker，否则 BLOCKER_REQUIRED
 * 2. 离开 blocked 自动清空 blocker（历史由 updated_at 体现，v1 不做完整变更历史）
 * 3. 进入 done 记 completed_at；退回其他状态时清空
 * 4. **允许任意状态互跳，不设状态机**——真实情况是"这事其实早做完了，我忘了标"
 * 5. （D-4，2026-09-16）进 blocked 时可选带**求助对象** `help_dept_id` / `help_member_id`，
 *    对应设计规格 P03 阻塞块里的「需要帮助 · 宣传部 陈屿」。离开 blocked 一并清空。
 */
/*
 * 改任务状态的**业务核心**：校验 + 落值。HTTP handler 与 AI 写工具**共用这一个**。
 *
 * 为什么抽出来（2026-10-06）：AI 的写操作必须与界面**规则完全一致**
 * （blocked 必填 blocker、求助对象校验、两阶段纪律、completed_at 语义）。
 * 在 AI 工具里再实现一遍就是制造第二份定义 —— 那正是本项目
 * 「权限判定只有一处」明令禁止的漂移，也是 spec D4「模型输出不得绕过校验」的边界。
 *
 * **前提**：调用方已持 `s.lock`，且**已完成** `requireAccess` 与任务存在性检查。
 * 抛出的异常与原 handler 完全一致（客户端看到的错误码不变）。
 */
public func taskStatusApply(s: Store, t: Task, status: String, blocker: String,
                            helpDept: Int64, helpMember: Int64, now: Int64): Unit {
    /*
     * 2026-09-17：阻塞原因的长度校验放在**授权之后**（原先在锁外、requireAccess 之前）。
     * 顺序纪律：先认证 → 再授权 → 最后校验入参。否则一个无权用户（甚至目标不存在的
     * 请求）只要带个超长 blocker，拿到的就是 400「表单填错了」而不是 403/404 ——
     * 客户端会把权限问题显示成输入问题，排查方向被带偏。
     * （抽取后这条纪律由**调用方**保证：先 requireAccess，再调本函数。）
     */
    requireLen("blocker", "阻塞原因", blocker, MAX_BLOCKER_BYTES)

    if (status == "blocked" && isBlank(blocker)) {
        throw apiErrFields("BLOCKER_REQUIRED", "进入阻塞状态必须填写阻塞原因",
            oneField("blocker", "请说明卡在哪里，这比任何进度百分比都有用"))
    }
    /*
     * 求助对象只在 blocked 下有意义。非阻塞状态传了非零值就**明确报错**，
     * 不静默忽略——静默忽略会让调用方以为求助已经登记上了（本项目一贯纪律）。
     */
    if (status != "blocked" && (helpDept > 0 || helpMember > 0)) {
        throw apiErrFields("VALIDATION_FAILED", "参数校验失败",
            oneField("help_dept_id", "只有阻塞状态才能指定求助对象（离开阻塞会自动清空）"))
    }
    /* ---------- 阶段一：只校验，不碰 t（N-15 的两阶段纪律） ---------- */
    var nextHelpDept: Int64 = 0
    var nextHelpMember: Int64 = 0
    if (status == "blocked") {
        if (helpMember > 0) {
            let hm = match (s.members.get(helpMember)) {
                case Some(x) => x
                case None => throw apiErr("MEMBER_NOT_FOUND")
            }
            if (hm.status == "pending") {
                throw apiErrMsg("MEMBER_PENDING", "求助对象尚未被分配，不能作为求助人")
            }
            if (hm.status == "disabled") {
                throw apiErrMsg("MEMBER_DISABLED", "求助对象已退出社团，不能作为求助人")
            }
            if (helpDept > 0 && helpDept != hm.dept_id) {
                throw apiErrFields("VALIDATION_FAILED", "参数校验失败",
                    oneField("help_member_id", "求助人不在所选部门里"))
            }
            nextHelpMember = helpMember
            /* 只填人时按该成员的部门补齐——"本部门被求助"永远只要比一个字段 */
            nextHelpDept = hm.dept_id
        } else if (helpDept > 0) {
            match (s.departments.get(helpDept)) {
                case Some(_) => ()
                case None => throw apiErr("DEPT_NOT_FOUND")
            }
            nextHelpDept = helpDept
        }
    }

    /* ---------- 阶段二：全部通过之后才落值 ---------- */
    t.status = status
    if (status == "blocked") {
        t.blocker = blocker
        t.help_dept_id = nextHelpDept
        t.help_member_id = nextHelpMember
    } else {
        t.blocker = ""
        t.help_dept_id = 0
        t.help_member_id = 0
    }
    if (status == "done") {
        if (t.completed_at <= 0) {
            t.completed_at = now
        }
    } else {
        t.completed_at = 0
    }
    t.updated_at = now
}

public func handleTaskStatus(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    let id = pathIdOr(ctx, "TASK_NOT_FOUND")
    let body = reqObj(ctx)
    let v = V()
    let status = v.need("status", reqStrOr(body, "status", ""), "请选择任务状态")
    v.check("status", isTaskStatus(status), "状态只能是 todo / doing / blocked / done")
    v.done()
    let blocker = reqStrOr(body, "blocker", "")
    let helpDept = reqIntOr(body, "help_dept_id", 0)
    let helpMember = reqIntOr(body, "help_member_id", 0)

    let data = storeMutation(s, { =>
        let t = match (activeTaskById(s, id)) {
            case Some(x) => x
            case None => throw apiErr("TASK_NOT_FOUND")
        }
        requireAccess(actor, Action.UpdateTaskStatus, targetOfTask(actor, t))
        /*
         * 校验 + 落值走共享的 taskStatusApply —— 与 AI 写工具**同一份规则**。
         * 顺序不变：先 requireAccess，再由它做入参校验（见该函数的说明）。
         */
        let now = nowEpoch()
        taskStatusApply(s, t, status, blocker, helpDept, helpMember, now)
        taskDetail(s, t, now)
    })
    sendOk(ctx, data)
}

/*
 * DELETE /api/v1/tasks/{id} —— **软删除**
 * 任务承载着人的工作量记录，硬删除会让"这学期我做了多少事"永远无法回答，
 * 而误删在移动端非常容易发生（v1-scope 规则 17）。
 */
public func handleTaskDelete(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    let id = pathIdOr(ctx, "TASK_NOT_FOUND")
    storeMutation(s, { =>
        let t = match (activeTaskById(s, id)) {
            case Some(x) => x
            case None => throw apiErr("TASK_NOT_FOUND")
        }
        requireAccess(actor, Action.DeleteTask, targetOfTask(actor, t))
        t.deleted_at = nowEpoch()
        t.updated_at = t.deleted_at
    })
    sendOk(ctx, JsonObject())
}

/*
 * POST /api/v1/tasks/lookup —— 日历同步用（api-design §4.8）
 *
 * 服务端**不存任何日历字段**：日历事件在成员自己的手机上，且同一任务可能被多人加入。
 * 客户端本地维护 task_id → {event_id, cached_*}，用这个接口批量确认
 * "我加过日历的任务现在还在不在"。返回 missing 里的 id 即需清理的本地事件。
 *
 * 没有它，客户端就无法可靠回收日历事件，日历里会堆错误提醒——两周后成员就不再相信它。
 */
public func handleTaskLookup(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    let body = reqObj(ctx)
    let ids = match (jsonGetArray(body, "task_ids")) {
        case Some(a) => a
        case None => throw apiErrFields("VALIDATION_FAILED", "参数校验失败", oneField("task_ids", "请提供任务 id 列表"))
    }
    if (ids.size() > 500) {
        throw apiErrFields("VALIDATION_FAILED", "参数校验失败", oneField("task_ids", "一次最多查询 500 个"))
    }
    s.lock.lock()
    try {
        let items = JsonArray()
        let missing = JsonArray()
        /* 2026-09-17：同一批里重复的 id 只处理一次（原先会原样重复进 items / missing，
         * 客户端照着它清理本地日历会做重复功）。 */
        let seen = HashSet<Int64>()
        var i: Int64 = 0
        while (i < ids.size()) {
            let cell = ids.get(i)
            i += 1
            match (cell) {
                case Some(jv) =>
                    var id: Int64 = -1
                    try {
                        id = jv.asInt().getValue()
                    } catch (e: Exception) {
                        id = -1
                    }
                    /*
                     * 2026-09-17：非法元素**明确报错**，不再折算成 -1 混进 missing。
                     * 原先非整数 / 0 / 负数都会变成 `missing: [-1]` —— 客户端拿到一个它
                     * 从来没送过的 id，既清不掉本地事件、也看不出是自己传错了
                     * （与"绝不静默忽略参数"的纪律冲突）。
                     */
                    if (id <= 0) {
                        throw apiErrFields("VALIDATION_FAILED", "参数校验失败",
                            oneField("task_ids", "列表里有非法 id：任务 id 必须是正整数"))
                    }
                    if (seen.contains(id)) {
                        continue
                    }
                    seen.add(id)
                    match (activeTaskById(s, id)) {
                        case Some(t) =>
                            if (can(actor, Action.ViewTasks, targetOfTask(actor, t))) {
                                let o = JsonObject()
                                jPutInt(o, "id", t.id)
                                jPutTime(o, "due_at", t.due_at)
                                jPutStr(o, "status", t.status)
                                jPutTime(o, "updated_at", t.updated_at)
                                items.add(o)
                            } else {
                                /* 看不见的（别人的 / 已移出社团的人负责的）与已删除的一律进
                                 * missing —— 客户端据此清掉本地日历事件，语义与原先一致。 */
                                missing.add(JsonInt(id))
                            }
                        case None => missing.add(JsonInt(id))
                    }
                case None => ()
            }
        }
        let data = JsonObject()
        data.put("items", items)
        data.put("missing", missing)
        sendOk(ctx, data)
    } finally {
        s.lock.unlock()
    }
}
