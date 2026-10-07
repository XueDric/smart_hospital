package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * Part 3.1 · 部门（组织）—— 4 个接口
 *
 * 权限（2026-09-13 决策，api-design §3.1 / §3.8 / §6.1 已统一）：
 *   GET             全体 active 成员（只有 4 个组织，是所有人画界面要用的事实）
 *   POST/PATCH/DELETE   **仅会长**。组织架构是社团层面的事，增删改都会影响所有人的归属；
 *                       副会长可以管人（调部门、改角色），但不直接改动组织本身。
 *
 * ⚠ 锁规则：requireActive 内部会加锁，所以必须先认证、**再**加锁做修改。
 */

import std.collection.*
import stdx.encoding.json.*

/* GET /api/v1/depts */
public func handleDeptList(ctx: Context, s: Store): Unit {
    let m = requireActive(ctx, s)
    requireAccess(m, Action.ViewMembers, Target())
    s.lock.lock()
    try {
        sendOk(ctx, deptListView(s))
    } finally {
        s.lock.unlock()
    }
}

/* POST /api/v1/depts */
public func handleDeptCreate(ctx: Context, s: Store): Unit {
    let m = requireActive(ctx, s)
    requireAccess(m, Action.ManageDept, Target())
    let body = reqObj(ctx)
    let v = V()
    let name = v.need("name", reqStrOr(body, "name", ""), "请输入部门名称")
    /* 2026-09-17：部门名会出现在每个成员/任务的视图里（整份进 db.json），设个上限（见 limits.cj） */
    lenCheck(v, "name", "部门名", name, MAX_NAME_BYTES)
    v.done()

    let data = JsonObject()
    storeMutation(s, { =>
        if (deptNameTaken(s, name, 0)) {
            throw apiErrFields("ALREADY_EXISTS", "部门名已存在", oneField("name", "部门名已存在"))
        }
        /* sort 缺省 = 当前部门数（追加到末尾）。
         * M-8：必须校验范围。sort 直接参与 `sort * 1000000 + id` 的排序键，
         * 越界值会溢出并**落盘**，之后每次 GET /depts 都会 500 且只能手改文件恢复。 */
        let sort = reqIntOr(body, "sort", s.departments.size)
        if (sort < SORT_MIN || sort > SORT_MAX) {
            throw apiErrFields("VALIDATION_FAILED", "参数校验失败",
                oneField("sort", "排序值需在 ${SORT_MIN} 到 ${SORT_MAX} 之间"))
        }
        let d = Department()
        d.id = s.next_dept
        s.next_dept += 1
        d.name = name
        d.sort = sort
        s.departments[d.id] = d
        /* 部门增删改是**会长与运维**独占的敏感动作，三条都要留痕（原先只有删除记了审计）。
         * 2026-09-16 补：运维页开放「新增部门」之后这条尤其不能缺 ——
         * 否则"谁建的部门"在审计里查不到，运维与会长之间的职责分离就断了一半。 */
        audit(s, m.id, "create-dept", d.id, "部门=${name} sort=${sort}")
        jPutObj(data, "dept", deptView(s, d))
    })
    sendCreated(ctx, data)
}

/* PATCH /api/v1/depts/{id} —— 字段全部可选：name / sort */
public func handleDeptUpdate(ctx: Context, s: Store): Unit {
    let m = requireActive(ctx, s)
    requireAccess(m, Action.ManageDept, Target())
    let id = pathIdOr(ctx, "DEPT_NOT_FOUND")
    let body = reqObj(ctx)

    /* Department 没有、也不该有 lead_id：部长身份只由 Member.role = lead 表达。
     * 客户端若传了，明确报错而不是静默忽略——静默忽略会让调用方以为改成功了。 */
    if (body.get("lead_id").isSome()) {
        throw apiErrFields("VALIDATION_FAILED", "参数校验失败",
            oneField("lead_id", "不接受 lead_id：部长身份由成员的 role 表达，请改用 PATCH /members/{id}"))
    }

    s.lock.lock()
    try {
        let d = match (s.departments.get(id)) {
            case Some(x) => x
            case None => throw apiErr("DEPT_NOT_FOUND")
        }
        var touched = false
        /* ---------- 阶段一：只校验，不碰 d（N-15：d 是 s.departments 里的活引用） ---------- */
        var nextName: ?String = None
        match (reqOptionalStr(body, "name")) {
            case Some(nm) =>
                if (isBlank(nm)) {
                    throw apiErrFields("VALIDATION_FAILED", "参数校验失败", oneField("name", "部门名称不能为空"))
                }
                requireLen("name", "部门名", nm, MAX_NAME_BYTES)
                if (deptNameTaken(s, nm, d.id)) {
                    throw apiErrFields("ALREADY_EXISTS", "部门名已存在", oneField("name", "部门名已存在"))
                }
                nextName = Some(nm)
            case None => ()
        }
        var nextSort: ?Int64 = None
        match (reqOptionalInt(body, "sort")) {
            case Some(sv) =>
                /* M-8：同 handleDeptCreate，越界值会让排序键溢出并永久写进数据文件 */
                if (sv < SORT_MIN || sv > SORT_MAX) {
                    throw apiErrFields("VALIDATION_FAILED", "参数校验失败",
                        oneField("sort", "排序值需在 ${SORT_MIN} 到 ${SORT_MAX} 之间"))
                }
                nextSort = Some(sv)
            case None => ()
        }

        /* ---------- 阶段二：全部通过之后才落值（N-15） ---------- */
        match (nextName) {
            case Some(nm) =>
                d.name = nm
                touched = true
            case None => ()
        }
        match (nextSort) {
            case Some(sv) =>
                d.sort = sv
                touched = true
            case None => ()
        }
        if (touched) {
            /* 同 handleDeptCreate：改名 / 改排序也要留痕（与删除部门同口径） */
            audit(s, m.id, "update-dept", d.id, "部门=${d.name} sort=${d.sort}")
            storeSave(s)
        }
        let data = JsonObject()
        jPutObj(data, "dept", deptView(s, d))
        sendOk(ctx, data)
    } finally {
        s.lock.unlock()
    }
}

/*
 * DELETE /api/v1/depts/{id}
 *
 * 不允许删除非空部门——社团的组织架构变更应该是有意识的，
 * 不能一键把 8 个人变成无部门状态。
 *
 * 前置检查比文档多两条（文档只写了成员），否则会留下悬空引用：
 *   · 顶层课题还挂在这个部门 → 同样拒绝（Plan.dept_id 只存在顶层）
 *   · 已退出成员 / 历史任务的部门标签 → 不阻塞，但**置 0**，不留悬空 id
 */
public func handleDeptDelete(ctx: Context, s: Store): Unit {
    let m = requireActive(ctx, s)
    requireAccess(m, Action.DeleteDept, Target())
    let id = pathIdOr(ctx, "DEPT_NOT_FOUND")

    storeMutation(s, { =>
        match (s.departments.get(id)) {
            case Some(_) => ()
            case None => throw apiErr("DEPT_NOT_FOUND")
        }
        let n = activeMemberCountOfDept(s, id)
        if (n > 0) {
            throw apiErrMsg("DEPT_NOT_EMPTY", "该部门下还有 ${n} 名成员，必须先全部调离")
        }
        let pn = topPlanCountOfDept(s, id)
        if (pn > 0) {
            throw apiErrMsg("DEPT_NOT_EMPTY", "该部门下还有 ${pn} 个顶层课题，必须先移走或删除")
        }
        /*
         * 已退出成员与历史任务的部门标签置 0，避免留下指向已删部门的 id。
         *
         * 2026-09-17 补齐三处同类引用（原先只清了这两个）：
         *   · `Member.dept_hint`（招募链接带来的部门预填）→ 一直指向不存在的部门；
         *   · `Task.help_dept_id`（阻塞任务的求助部门）→ 首页「需要帮助」显示空部门名；
         *   · `DeptInviteLink`（该部门的招募链接）→ 最明显的一处：同一个 token 在公开 JSON 里
         *     返回 `enabled:true, dept.name:""`，而公开落地页显示"链接已失效"（两个入口结论矛盾）。
         * 邀请链接按 h_link.cj 的既定语义**停用而不删除**（记录保留，便于事后追溯）。
         */
        var hintsCleared: Int64 = 0
        for ((_k, mm) in s.members) {
            if (mm.dept_id == id) {
                mm.dept_id = 0
            }
            if (mm.dept_hint == id) {
                mm.dept_hint = 0
                hintsCleared += 1
            }
        }
        var helpsCleared: Int64 = 0
        for ((_k, t) in s.tasks) {
            if (t.dept_id == id) {
                t.dept_id = 0
            }
            if (t.help_dept_id == id) {
                /* 2026-09-17 复核后修正：只清**指向部门**的这一半。
                 *
                 * help_member_id 指向的是**成员**，而删部门不会删成员，那个引用依然有效 ——
                 * 原先把两者一起清零，等于把"当时求助的是谁"这条历史信息也一并抹掉了，
                 * 那与"部门没了"不是一回事（也与离开 blocked 时的清空不同：那是用户主动
                 * 结束求助）。视图侧（views.cj）的 dept / member 是两个独立字段，
                 * needs_help 只要任一侧 > 0 就照常下发，所以保留 member 不会留下半截状态。 */
                t.help_dept_id = 0
                helpsCleared += 1
            }
        }
        var linksDisabled: Int64 = 0
        for ((_k, l) in s.invite_links) {
            if (l.dept_id == id && l.enabled) {
                l.enabled = false
                linksDisabled += 1
            }
        }
        s.departments.remove(id)
        audit(s, m.id, "delete-dept", id,
            "部门已删除，遗留引用已清空（预填=${hintsCleared} 求助=${helpsCleared} 停用招募链接=${linksDisabled}）")
    })
    sendOk(ctx, JsonObject())
}
