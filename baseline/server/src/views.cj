package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * 对外 JSON 视图（模型的投影）。
 *
 * 一条硬规则：**MemberBrief 不含手机号**（api-design §2.7）。
 * 名录只需要姓名、部门、角色。手机号只在 /auth/me、本人资料，
 * 以及会长/副会长可见的管理视图里出现——成本为零的隐私最小化。
 */

import std.collection.*
import stdx.encoding.json.*

/* 人：名录、任务负责人、课题负责人等所有出现"人"的地方统一用它。 */
public func memberBrief(s: Store, m: Member): JsonObject {
    let o = JsonObject()
    jPutInt(o, "id", m.id)
    jPutStr(o, "name", m.name)
    if (m.status == "active" && m.role.size > 0) {
        jPutStr(o, "role", m.role)
    } else {
        jPutNull(o, "role")
    }
    if (m.dept_id > 0) {
        jPutObj(o, "dept", deptBriefObj(s, m.dept_id))
    } else {
        jPutNull(o, "dept")
    }
    jPutStr(o, "status", m.status)
    jPutTime(o, "joined_at", m.joined_at)
    return o
}

/* 本人视图：比 MemberBrief 多手机号（仅本人可见）。 */
public func memberSelf(s: Store, m: Member): JsonObject {
    let o = memberBrief(s, m)
    jPutStr(o, "phone", m.phone)
    return o
}

public func deptBriefObj(s: Store, deptId: Int64): JsonObject {
    let o = JsonObject()
    jPutInt(o, "id", deptId)
    match (s.departments.get(deptId)) {
        case Some(d) => jPutStr(o, "name", d.name)
        case None => jPutStr(o, "name", "")
    }
    return o
}

/*
 * 权限摘要。客户端读它**只为画界面**，绝不能用它替代服务端校验
 * （真正的拦截在 perms.cj 的 checkAccess / requireAccess）。
 */
public func permissionsOf(m: Member): JsonObject {
    let p = JsonObject()
    let active = m.status == "active"
    let global = active && (m.role == "president" || m.role == "vice_president" || m.role == "ops")
    let deptAdmin = active && (m.role == "lead" || m.role == "vice_lead")
    /*
     * view_scope：**active 成员一律 all**（2026-09-16，D-3）。
     *
     * 原文在 global / deptAdmin 上分档（all / dept），那是"任务与课题按部门可见"时代的产物。
     * 现在读范围已全社团开放（perms.cj 的 scopeAllows），再下发 dept 会让客户端在 P02
     * 渲染成「本部门范围可见」，与设计稿的「全社团范围可见」不符。
     * 角色之间的差别体现在**动作布尔**上，不再体现在可见范围上。
     */
    var scope = "none"
    if (active) {
        scope = "all"
    }
    jPutStr(p, "view_scope", scope)
    jPutBool(p, "manage_members", global)
    /*
     * set_role 必须**从 can() 推出来**，不能手写角色判断（L-1）。
     * 原先写的是 `m.role == "president"`，但真实权限是「会长与副会长都能改角色
     * （副会长除外会长本人）」——客户端据此把副会长的角色下拉框整个藏掉了，
     * 而后端其实允许。探针目标取本部门的一个普通成员，这正是"能不能改别人角色"。
     */
    let probe = Target()
    probe.dept_id = m.dept_id
    probe.target_role = "member"
    jPutBool(p, "set_role", active && can(m, Action.SetRole, probe))
    jPutBool(p, "create_plan", global || deptAdmin)
    jPutBool(p, "create_task", global || deptAdmin)
    jPutBool(p, "update_any_task", global || deptAdmin)
    /*
     * 「管理」页四张分区卡按权限显示（D-1，2026-09-16）。
     *
     * 设计规格 P10 要求「按权限显示的管理入口」，P09 的管理页是四张分区卡：
     *   部门与组织 / 注册口令 / 招募链接 / 会长移交。
     * 只下发 manage_members 是不够的 —— 副会长 manage_members 为真，会看到
     * 「部门与组织」入口，点下去却被 403（部门增删改是会长独占）。这正是设计稿
     * 要避免的"看得到点不动"。
     *
     * 五个布尔**全部由 can() 推导**，不在这里手写角色判断（权限判定只有一处）。
     */
    let none = Target()
    jPutBool(p, "manage_depts", active && can(m, Action.ManageDept, none))
    jPutBool(p, "view_register_code", active && can(m, Action.ViewRegisterCode, none))
    jPutBool(p, "change_register_code", active && can(m, Action.ChangeRegisterCode, none))
    jPutBool(p, "manage_invite_links", active && can(m, Action.ManageInviteLink, none))
    jPutBool(p, "transfer_presidency", active && can(m, Action.TransferPresidency, none))
    return p
}

/* 角色中文名，用于日志与导出。 */
public func roleLabel(role: String): String {
    if (role == "president") {
        return "会长"
    }
    if (role == "ops") {
        return "运维"
    }
    if (role == "vice_president") {
        return "副会长"
    }
    if (role == "lead") {
        return "部长"
    }
    if (role == "vice_lead") {
        return "副部长"
    }
    if (role == "member") {
        return "成员"
    }
    return "待分配"
}

/* 角色必须是固定 5 档之一（v1-scope 规则 5：只能分配，不能自定义）。 */
public func isKnownRole(role: String): Bool {
    if (role == "president") {
        return true
    }
    if (role == "vice_president") {
        return true
    }
    if (role == "lead") {
        return true
    }
    if (role == "vice_lead") {
        return true
    }
    if (role == "member") {
        return true
    }
    return false
}

/* ===================== Part 3 的视图 ===================== */

/*
 * 部门（含部长与人数）。
 * `lead` 现查现算：v0.6 起**部长身份只由 `Member.role = lead` 表达**，
 * Department 表里没有、也不该有 lead_id（同一事实存两份必然不一致）。
 */
public func deptView(s: Store, d: Department): JsonObject {
    let o = JsonObject()
    jPutInt(o, "id", d.id)
    jPutStr(o, "name", d.name)
    jPutInt(o, "sort", d.sort)
    var lead: ?Member = None
    var count: Int64 = 0
    for ((_k, m) in s.members) {
        if (m.dept_id != d.id || m.status != "active") {
            continue
        }
        count += 1
        if (m.role == "lead") {
            lead = Some(m)
        }
    }
    match (lead) {
        case Some(lm) => jPutObj(o, "lead", memberBrief(s, lm))
        case None => jPutNull(o, "lead")
    }
    jPutInt(o, "member_count", count)
    return o
}

/* 部门列表响应体（不分页：只有 4 个组织为一个量级）。 */
public func deptListView(s: Store): JsonObject {
    let list = sortedDepartments(s)
    let arr = JsonArray()
    for (d in list) {
        arr.add(deptView(s, d))
    }
    let data = JsonObject()
    data.put("items", arr)
    return data
}

/*
 * 成员详情：MemberBrief + 计数摘要（只给计数，明细属于 Part 4 的列表接口）。
 *
 * D-7（2026-09-16）：设计规格 P07 的身份卡是
 * 「2025-09 加入 · 未完成 5 · 逾期 1 · 已完成 12」——**四个数**。
 * 原先只给 owned_tasks（含已完成的总数）与 open_tasks，于是
 *   ① 「已完成」客户端能用 owned-open 凑出来，但 ② 「逾期」凑不出来，
 *      只能再打一次 GET /tasks?owner_id=X&overdue=true 去读 total。
 * 现在两个数都在这里一次算完（同一次遍历，成本为零）。
 */
public func memberDetailView(s: Store, m: Member, now: Int64): JsonObject {
    let o = JsonObject()
    jPutObj(o, "member", memberBrief(s, m))
    var owned: Int64 = 0
    var open: Int64 = 0
    var done: Int64 = 0
    var overdue: Int64 = 0
    for ((_k, t) in s.tasks) {
        if (t.deleted_at > 0 || t.owner_id != m.id) {
            continue
        }
        owned += 1
        if (t.status == "done") {
            done += 1
            continue
        }
        open += 1
        if (isTaskOverdue(t, now)) {
            overdue += 1
        }
    }
    var plans: Int64 = 0
    for ((_k, p) in s.plans) {
        if (p.owner_id == m.id) {
            plans += 1
        }
    }
    let st = JsonObject()
    jPutInt(st, "owned_tasks", owned)
    jPutInt(st, "open_tasks", open)
    jPutInt(st, "done_tasks", done)
    jPutInt(st, "overdue_tasks", overdue)
    jPutInt(st, "owned_plans", plans)
    jPutObj(o, "stats", st)
    return o
}

/* 待分配成员：MemberBrief + 来源部门提示 + 注册时间。 */
public func pendingView(s: Store, m: Member): JsonObject {
    let o = memberBrief(s, m)
    if (m.dept_hint > 0) {
        jPutObj(o, "dept_hint", deptBriefObj(s, m.dept_hint))
    } else {
        jPutNull(o, "dept_hint")
    }
    jPutTime(o, "registered_at", m.joined_at)
    return o
}

/* 招募链接。url 由请求的 Host 头拼出来，避免把域名写死在配置里。 */
public func inviteLinkView(s: Store, l: DeptInviteLink, url: String): JsonObject {
    let o = JsonObject()
    jPutStr(o, "token", l.token)
    if (url.size > 0) {
        jPutStr(o, "url", url)
    }
    jPutObj(o, "dept", deptBriefObj(s, l.dept_id))
    jPutBool(o, "enabled", l.enabled)
    jPutTime(o, "created_at", l.created_at)
    return o
}

/* 注册配置（仅会长 / 副会长可读）。 */
public func registerConfigView(s: Store): JsonObject {
    let o = JsonObject()
    jPutStr(o, "code", s.register_code)
    jPutTime(o, "updated_at", s.register_code_at)
    match (s.members.get(s.register_code_by)) {
        case Some(m) => jPutObj(o, "updated_by", memberBrief(s, m))
        case None => jPutNull(o, "updated_by")
    }
    return o
}

/* ===================== Part 4 的视图 ===================== */

/* 课题目录里引用一个课题时的最小形态。 */
public func planRefObj(p: Plan): JsonObject {
    let o = JsonObject()
    jPutInt(o, "id", p.id)
    jPutStr(o, "title", p.title)
    return o
}

/*
 * 任务所属课题的面包屑：从顶层到本级。
 * 带 guard，避免数据异常（环形）时死循环——环形校验在 M4 的移动接口上，
 * 但**读取路径不能假设数据一定干净**。
 *
 * L-10：这里的上限原先写死 32，而"合法深度上限"在 store.cj 里另有定义
 * （PLAN_MAX_DEPTH = 6，遍历保护的宽松上限是 PLAN_WALK_GUARD = 64）。
 * 两处不一致，将来调深度的上限时很容易只改一处。统一引用同一个常量。
 */
public func planPath(s: Store, planId: Int64): JsonArray {
    let chain = ArrayList<Plan>()
    var cur = planId
    var guard: Int64 = 0
    while (cur > 0 && guard < PLAN_WALK_GUARD) {
        match (s.plans.get(cur)) {
            case Some(p) =>
                chain.add(p)
                cur = p.parent_id
            case None => cur = 0
        }
        guard += 1
    }
    let arr = JsonArray()
    var i = chain.size - 1
    while (i >= 0) {
        arr.add(planRefObj(chain[i]))
        i -= 1
    }
    return arr
}

/*
 * 逾期**天数**（D-5，2026-09-16）。
 *
 * 设计规格 P01 卡片「逾期 2 天」、P03 提示条「已逾期 2 天 · 该判断由服务端算出，
 * 客户端不重算」——所以天数也必须由服务端下发，不能让客户端拿 due_at 和本地时钟比。
 *
 * 口径 = **本地日界的整数差**（不是 24 小时取整）：
 *   09-12 18:00 截止、09-14 09:00 现在 → 2 天（设计稿的示例正是这个数）
 *   今天 09:00 截止、今天 18:00 现在 → 0 天（is_overdue=true 且 days=0 表示"今天逾期"，
 *   客户端据此显示「已逾期」而不是「逾期 0 天」）
 * 未逾期一律 0。
 */
public func overdueDaysOf(t: Task, now: Int64): Int64 {
    if (!isTaskOverdue(t, now)) {
        return 0
    }
    let d = (startOfLocalDay(now) - startOfLocalDay(t.due_at)) / DAY_SECONDS
    if (d < 0) {
        return 0
    }
    return d
}

/*
 * 「需要帮助」视图（D-4，2026-09-16）。
 *
 * 设计规格 P03 的阻塞原因块里有一行「需要帮助 · 宣传部 陈屿」——求助对象是
 * **部门 + 人**（人到可选）。没有求助对象时给 null，客户端据此决定渲不渲染这一行。
 */
public func needsHelpObj(s: Store, t: Task): JsonObject {
    let h = JsonObject()
    if (t.help_dept_id > 0) {
        jPutObj(h, "dept", deptBriefObj(s, t.help_dept_id))
    } else {
        jPutNull(h, "dept")
    }
    if (t.help_member_id > 0) {
        match (s.members.get(t.help_member_id)) {
            case Some(hm) => jPutObj(h, "member", memberBrief(s, hm))
            case None => jPutNull(h, "member")
        }
    } else {
        jPutNull(h, "member")
    }
    return h
}

/* TaskBrief（api-design §4.9）。`is_overdue` / `overdue_days` / `blocked` 都是服务端算好的派生量。 */
public func taskBrief(s: Store, t: Task, now: Int64): JsonObject {
    let o = JsonObject()
    jPutInt(o, "id", t.id)
    jPutStr(o, "title", t.title)
    jPutStr(o, "status", t.status)
    match (s.members.get(t.owner_id)) {
        case Some(m) => jPutObj(o, "owner", memberBrief(s, m))
        case None => jPutNull(o, "owner")
    }
    if (t.dept_id > 0) {
        jPutObj(o, "dept", deptBriefObj(s, t.dept_id))
    } else {
        jPutNull(o, "dept")
    }
    if (t.plan_id > 0) {
        match (s.plans.get(t.plan_id)) {
            case Some(p) => jPutObj(o, "plan", planRefObj(p))
            case None => jPutNull(o, "plan")
        }
    } else {
        jPutNull(o, "plan")
    }
    jPutTime(o, "due_at", t.due_at)
    jPutBool(o, "is_overdue", isTaskOverdue(t, now))
    jPutInt(o, "overdue_days", overdueDaysOf(t, now))
    jPutBool(o, "blocked", t.status == "blocked")
    /*
     * blocker 必须进 TaskBrief（2026-09-16，队友复验 P0）。
     *
     * 设计规格 P01 的「阻塞中」分组卡片里**直接渲染阻塞原因高亮块**
     * （「阻塞原因（进入 blocked 必填）」+ 原因原文）。原先 blocker 只在 TaskDetail 里，
     * 首页想让这张卡显示原因，就得为每张卡再打一次 GET /tasks/{id} ——
     * 而 P01 的原话正是「服务端已排好序，客户端只渲染、不重算」，
     * 首页本来就该一次拿全。非阻塞任务给 null（不是空串）。
     */
    if (t.blocker.size > 0) {
        jPutStr(o, "blocker", t.blocker)
    } else {
        jPutNull(o, "blocker")
    }
    if (t.help_dept_id > 0 || t.help_member_id > 0) {
        jPutObj(o, "needs_help", needsHelpObj(s, t))
    } else {
        jPutNull(o, "needs_help")
    }
    jPutTime(o, "updated_at", t.updated_at)
    return o
}

/* TaskDetail = TaskBrief + desc / plan_path / created_by / created_at / completed_at */
public func taskDetail(s: Store, t: Task, now: Int64): JsonObject {
    let o = taskBrief(s, t, now)
    jPutStr(o, "desc", t.desc)
    o.put("plan_path", planPath(s, t.plan_id))
    match (s.members.get(t.created_by)) {
        case Some(m) => jPutObj(o, "created_by", memberBrief(s, m))
        case None => jPutNull(o, "created_by")
    }
    jPutTime(o, "created_at", t.created_at)
    jPutTime(o, "completed_at", t.completed_at)
    return o
}

public func taskArr(s: Store, list: Array<Task>, now: Int64): JsonArray {
    let arr = JsonArray()
    for (t in list) {
        arr.add(taskBrief(s, t, now))
    }
    return arr
}

/* ===================== Part 5 的视图 ===================== */

/*
 * PlanBrief（api-design §5.9）。
 * progress 是**递归聚合值**（含整棵子树），task_count 是**本级**任务数，两者不要混。
 * include_progress 为 false 时省略 progress 字段（该参数存在的意义就是减少计算量）。
 */
public func planBrief(s: Store, p: Plan, st: ?PlanStats, includeProgress: Bool): JsonObject {
    let o = JsonObject()
    jPutInt(o, "id", p.id)
    jPutStr(o, "title", p.title)
    match (s.members.get(p.owner_id)) {
        case Some(m) => jPutObj(o, "owner", memberBrief(s, m))
        case None => jPutNull(o, "owner")
    }
    /* dept 仅顶层课题有值；子课题的部门看所属根（规则 19） */
    if (p.parent_id <= 0 && p.dept_id > 0) {
        jPutObj(o, "dept", deptBriefObj(s, p.dept_id))
    } else {
        jPutNull(o, "dept")
    }
    jPutTime(o, "due_at", p.due_at)
    match (st) {
        case Some(x) =>
            if (includeProgress) {
                let pr = JsonObject()
                jPutInt(pr, "done", x.done)
                jPutInt(pr, "total", x.total)
                jPutObj(o, "progress", pr)
            }
            jPutInt(o, "task_count", x.task_count)
            jPutInt(o, "child_count", x.child_count)
        case None =>
            if (includeProgress) {
                let pr = JsonObject()
                jPutInt(pr, "done", 0)
                jPutInt(pr, "total", 0)
                jPutObj(o, "progress", pr)
            }
            jPutInt(o, "task_count", 0)
            jPutInt(o, "child_count", 0)
    }
    jPutTime(o, "created_at", p.created_at)
    jPutTime(o, "updated_at", p.updated_at)
    return o
}

/* 课题详情用：PlanBrief 再加 desc 与 parent_id（树里不带，避免响应过大）。 */
public func planDetailView(s: Store, p: Plan, st: ?PlanStats): JsonObject {
    let o = planBrief(s, p, st, true)
    jPutStr(o, "desc", p.desc)
    jPutInt(o, "parent_id", p.parent_id)
    return o
}

/*
 * 树节点：PlanBrief + 内嵌 children。
 * level 与 depthLimit 配合：超过展开层数就不展开子节点，但 child_count 仍然给，
 * 客户端据此知道"下面还有"。
 */
public func planNodeJson(s: Store, p: Plan, stats: HashMap<Int64, PlanStats>, includeProgress: Bool,
                         depthLimit: Int64, level: Int64): JsonObject {
    let o = planBrief(s, p, stats.get(p.id), includeProgress)
    let kids = JsonArray()
    if (level < depthLimit) {
        for (c in planChildrenOf(s, p.id)) {
            kids.add(planNodeJson(s, c, stats, includeProgress, depthLimit, level + 1))
        }
    }
    o.put("children", kids)
    return o
}

