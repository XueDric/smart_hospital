package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * Part 3.2–3.4 · 成员名录、待分配与授权、会长移交 —— 8 个接口
 *
 * 两处设计要点：
 *   1. **注册与授权分离**：assign 只做"授予部门+角色"这一件事，
 *      注册接口不产生任何权限（v1-scope 规则 12）。
 *   2. **权限与字段一一对应**：改姓名走 EditMemberName，改部门/角色走 SetRole，
 *      两者权限不同，不能因为它们在同一个请求体里就合并判定。
 *
 * ⚠ 锁规则：requireActive 内部加锁；handler 先认证、再单独加锁。
 */

import std.collection.*
import stdx.encoding.json.*

/* 组装一条批量失败记录。 */
func addFail(arr: JsonArray, id: Int64, code: String): Unit {
    let o = JsonObject()
    jPutInt(o, "id", id)
    jPutStr(o, "code", code)
    arr.add(o)
}

/* 名下有未完成任务：把任务清单放进 error.fields.tasks（见 api-design §3.2 注）。 */
func openTasksError(s: Store, m: Member, open: Array<Task>): ApiError {
    let arr = JsonArray()
    for (t in open) {
        let o = JsonObject()
        jPutInt(o, "id", t.id)
        jPutStr(o, "title", t.title)
        jPutStr(o, "status", t.status)
        arr.add(o)
    }
    let fields = JsonObject()
    fields.put("tasks", arr)
    return apiErrFields("MEMBER_HAS_OPEN_TASKS", "${m.name} 名下还有 ${open.size} 个未完成任务，需先转交", fields)
}

/* 为某个成员构造权限判定目标。 */
func targetOf(actor: Member, tgt: Member): Target {
    let t = Target()
    t.member_id = tgt.id
    t.dept_id = tgt.dept_id
    t.target_role = tgt.role
    /*
     * 2026-09-17（P1 加固）：把"目标确实没有角色"这件事**显式声明**出来。
     *
     * 待分配成员（status=pending）的 role 就是空串 —— 这是正常状态，不是漏填。
     * perms 的同权闸据此区分"待分配（按 0 档处理）"与"调用方忘了填（一律拒）"，
     * 见 Target.role_absent 的注释。
     */
    t.role_absent = (tgt.role.size == 0)
    t.owner_id = tgt.id
    t.is_self = (tgt.id == actor.id)
    return t
}

/*
 * D-2（2026-09-16）：名录搜索 —— 匹配**姓名 OR 部门名**，大小写不敏感。
 * 设计规格 P06 的搜索框占位符原文就是「搜索姓名或部门」。
 *
 * 只搜这两个维度：手机号**不参与匹配**——P06 底部明确写「名录不含手机号——
 * 这是隐私最小化」，接口里既然不返回，就不该能被检索出来（否则等于换了个方式泄露）。
 * 待分配成员 dept_id 为 0，但它的部门预填（dept_hint）也该能被搜到，
 * 否则名录里「待分配」那组搜"运营部"会漏掉它们。
 */
func memberMatchesQuery(s: Store, m: Member, qLower: String): Bool {
    if (containsAscii(m.name.toAsciiLower(), qLower)) {
        return true
    }
    if (m.dept_id > 0) {
        match (s.departments.get(m.dept_id)) {
            case Some(d) => return containsAscii(d.name.toAsciiLower(), qLower)
            case None => ()
        }
    }
    if (m.dept_hint > 0) {
        match (s.departments.get(m.dept_hint)) {
            case Some(d) => return containsAscii(d.name.toAsciiLower(), qLower)
            case None => ()
        }
    }
    return false
}

/*
 * GET /api/v1/members —— 成员名录
 * 全社团可见（api-design §3.2）：这是第 1 节第一个问题「社团里有哪些人」的答案。
 * 默认只返回 active；用 ?status= 查其它状态。
 * ?q= 按**姓名或部门名**模糊匹配（D-2，对应设计规格 P06 的搜索框）。
 */
public func handleMemberList(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    requireAccess(actor, Action.ViewMembers, Target())
    let fDept = queryIntOr(ctx, "dept_id", 0)
    let fRole = ctx.queryParamOr("role", "")
    let fStatus = ctx.queryParamOr("status", "active")
    let q = ctx.queryParamOr("q", "").trimAscii().toAsciiLower()

    s.lock.lock()
    try {
        let picked = ArrayList<Member>()
        for ((_k, x) in s.members) {
            /*
             * 系统账号（运维，`role = ops`）**不进名录**（2026-09-16，甲方选择"隐藏系统账号"）：
             *   · 它不是社团成员，出现在名录里只会让人困惑；
             *   · 客户端的名录角色标签只映射 5 档，认不出它（会显示成"待分配"）；
             *   · 要看/管这个账号，用运维台 —— 它直读库文件（`/api/club/members`），不受这里影响。
             * 只隐藏**列表**：按 id 查详情仍然可达（会长/运维需要时用得上），
             * 而 id 不会从任何成员可见的列表里露出。
             */
            if (x.role == "ops") {
                continue
            }
            if (fStatus.size > 0 && x.status != fStatus) {
                continue
            }
            if (fDept > 0 && x.dept_id != fDept) {
                continue
            }
            if (fRole.size > 0 && x.role != fRole) {
                continue
            }
            if (q.size > 0 && !memberMatchesQuery(s, x, q)) {
                continue
            }
            picked.add(x)
        }
        let sorted = sortedMembers(s, picked)
        let arr = ArrayList<JsonObject>()
        for (x in sorted) {
            arr.add(memberBrief(s, x))
        }
        sendOk(ctx, pagedJson(ctx, arr))
    } finally {
        s.lock.unlock()
    }
}

/* GET /api/v1/members/{id} —— 详情（MemberBrief + 计数摘要） */
public func handleMemberDetail(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    requireAccess(actor, Action.ViewMembers, Target())
    let id = pathIdOr(ctx, "MEMBER_NOT_FOUND")
    s.lock.lock()
    try {
        let tgt = match (s.members.get(id)) {
            case Some(x) => x
            case None => throw apiErr("MEMBER_NOT_FOUND")
        }
        sendOk(ctx, memberDetailView(s, tgt, nowEpoch()))
    } finally {
        s.lock.unlock()
    }
}

/*
 * GET /api/v1/members/pending —— 待分配列表（先来先处理）
 *
 * 2026-10-06：按 api-design §7.5 给每条记录加 `risk` 分档。三段式（**锁纪律**）：
 *   ① 锁内取列表 + 每个申请人的事实（只读，短）
 *   ② **锁外**算分（可能调模型 —— 绝不能持锁做 I/O）
 *   ③ 锁内组装响应（pendingView 需要 s）
 *
 * ★ 分档**只影响排序与呈现，不影响审批动作** —— 不做"低风险自动通过"。
 */
public func handleMemberPending(ctx: Context, s: Store, ai: ?AiClient): Unit {
    let actor = requireActive(ctx, s)
    requireAccess(actor, Action.AssignPending, Target())
    let now = nowEpoch()

    /* ① 锁内：取数 + 采事实 */
    var items: Array<Member> = Array<Member>()
    let facts = HashMap<Int64, RiskFacts>()
    s.lock.lock()
    try {
        items = pendingMembers(s)
        for (x in items) {
            facts[x.id] = aiRiskFacts(s, x, now)
        }
    } finally {
        s.lock.unlock()
    }

    /* ② 锁外：算分（命中缓存的不重复调模型；本次刷新的名额也封顶） */
    let risks = HashMap<Int64, JsonObject>()
    var used: Int64 = 0
    for (x in items) {
        let f = match (facts.get(x.id)) {
            case Some(v) => v
            case None => RiskFacts()
        }
        let cached = aiRiskCached(x.id)
        risks[x.id] = pendingRiskOf(x, f, ai, used >= AI_RISK_MAX_CALLS)
        if (!cached) {
            used += 1
        }
    }

    /*
     * ②b 淘汰风险缓存里**已不在待审批列表**的条目。
     *
     * 2026-10-06 修：此前该缓存只写不淘汰 —— 每个被评过一次的申请人都会永久留一条，
     * 即便他早已通过审批、不再出现在列表里。单条很小，但**无界增长**。
     * 这个缓存只为本列表服务，所以每次刷新后按当前列表清一遍即可。
     * （锁序安全：这里只取 g_riskLock；没有任何路径是 g_riskLock -> s.lock。）
     */
    let keepIds = HashSet<Int64>()
    for (x in items) {
        keepIds.add(x.id)
    }
    aiRiskCacheRetain(keepIds)

    /* ③ 锁内：组装（高风险排前面） */
    s.lock.lock()
    try {
        /* 先按风险档排序，再按原顺序（先来先处理）稳定排列 */
        let ordered = ArrayList<Member>()
        var rank: Int64 = 0
        while (rank <= 2) {
            for (x in items) {
                let r = match (risks.get(x.id)) {
                    case Some(v) => v
                    case None => JsonObject()
                }
                if (aiRiskRank(r) == rank) {
                    ordered.add(x)
                }
            }
            rank += 1
        }
        let arr = JsonArray()
        for (x in ordered) {
            let v = pendingView(s, x)
            match (risks.get(x.id)) {
                case Some(r) => v.put("risk", r)
                case None => v.put("risk", aiRiskFallback(RiskFacts()))
            }
            arr.add(v)
        }
        let data = JsonObject()
        data.put("items", arr)
        sendOk(ctx, data)
    } finally {
        s.lock.unlock()
    }
}

/*
 * PATCH /api/v1/members/{id} —— 编辑成员（name / dept_id / role 全部可选）
 *
 * 字段级权限：name → EditMemberName；dept_id / role → SetRole。
 * 待分配成员不接受 dept_id / role——那属于 assign 的职责，避免两条路径各写一半。
 */
public func handleMemberUpdate(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    let id = pathIdOr(ctx, "MEMBER_NOT_FOUND")
    let body = reqObj(ctx)

    s.lock.lock()
    try {
        let tgt = match (s.members.get(id)) {
            case Some(x) => x
            case None => throw apiErr("MEMBER_NOT_FOUND")
        }
        let t = targetOf(actor, tgt)
        var touched = false

        /* ---------- 阶段一：只收集 + 校验，**绝不碰 tgt**（N-15） ----------
         * 原先是"边校验边赋值"。后面某个字段校验失败抛异常时，前面写进去的字段不会回滚，
         * 而 tgt 是 s.members 里的**活引用** —— 客户端拿到 4xx，内存却已经被改了，
         * 下一个写请求会把这次"被拒绝"的改动一起序列化落盘。 */
        var nextName: ?String = None
        match (reqOptionalStr(body, "name")) {
            case Some(nm) =>
                requireAccess(actor, Action.EditMemberName, t)
                if (isBlank(nm)) {
                    throw apiErrFields("VALIDATION_FAILED", "参数校验失败", oneField("name", "姓名不能为空"))
                }
                /* 2026-09-17：姓名长度上限（见 limits.cj —— 姓名出现在每个任务/课题视图里） */
                requireLen("name", "姓名", nm, MAX_NAME_BYTES)
                nextName = Some(nm)
            case None => ()
        }

        var newDept: ?Int64 = None
        match (reqOptionalInt(body, "dept_id")) {
            case Some(x) => newDept = Some(x)
            case None => ()
        }
        var newRole: ?String = None
        match (reqOptionalStr(body, "role")) {
            case Some(x) => newRole = Some(x)
            case None => ()
        }

        if (newDept.isSome() || newRole.isSome()) {
            requireAccess(actor, Action.SetRole, t)
            if (tgt.status == "pending") {
                throw apiErrMsg("VALIDATION_FAILED", "待分配成员请用 POST /members/{id}/assign 授予部门与角色")
            }
            match (newRole) {
                case Some(r) =>
                    if (!isKnownRole(r)) {
                        throw apiErrFields("VALIDATION_FAILED", "参数校验失败",
                            oneField("role", "角色必须是 5 档预设之一"))
                    }
                    if (r == "president") {
                        throw apiErrFields("VALIDATION_FAILED", "参数校验失败",
                            oneField("role", "会长只能通过「移交会长」产生"))
                    }
                    /* 规则 10：系统必须始终至少有一个 president */
                    if (tgt.role == "president" && presidentCount(s) <= 1) {
                        throw apiErr("FORBIDDEN_LAST_PRESIDENT")
                    }
                case None => ()
            }
            match (newDept) {
                case Some(did) =>
                    /*
                     * 2026-09-17：`dept_id <= 0` 明确报错，不再静默落库。
                     * 原先只在 `did > 0` 时才校验，于是 `{"dept_id":0}` 能把一个在职成员改成
                     * "没有部门"，`-5` 这类垃圾值也会永久写进 db.json —— 而"未分配"本应只属于
                     * pending 账号（那一路走 POST /members/{id}/assign 审批，本接口对 pending
                     * 只接受 name）。口径与 assign 对齐（那边要求 dept_id > 0）。
                     */
                    if (did <= 0) {
                        throw apiErrFields("VALIDATION_FAILED", "参数校验失败",
                            oneField("dept_id", "部门 id 必须是正整数（待分配账号请用 POST /members/{id}/assign）"))
                    }
                    match (s.departments.get(did)) {
                        case Some(_) => ()
                        case None => throw apiErr("DEPT_NOT_FOUND")
                    }
                case None => ()
            }
        }

        /* ---------- 阶段二：全部通过之后才落值（N-15） ---------- */
        /* 审计要记"旧值 → 新值"，先把旧值拷下来（下面就要覆盖它们） */
        let oldName = tgt.name
        let oldRole = tgt.role
        let oldDept = tgt.dept_id
        match (nextName) {
            case Some(nm) =>
                tgt.name = nm
                touched = true
            case None => ()
        }
        match (newRole) {
            case Some(r) =>
                tgt.role = r
                touched = true
            case None => ()
        }
        match (newDept) {
            case Some(did) =>
                tgt.dept_id = did
                touched = true
            case None => ()
        }

        if (touched) {
            /*
             * 2026-09-17：本 handler 原先**不写审计** —— 而它能改 role 与 dept_id，
             * 也就是说它能提权（`{"role":"vice_president"}`）。同一份文件里
             * disable / assign / assign-batch / transfer-presidency 四条都记账，
             * M-4 的立论正是"成员处置必须可追溯"，唯独这条主路径漏了。
             * 这里按**字段级**记旧值 → 新值，事后能查出"谁把谁改成了什么"。
             */
            audit(s, actor.id, "update-member", tgt.id,
                "姓名=${oldName}->${tgt.name} 角色=${oldRole}->${tgt.role} 部门=${oldDept}->${tgt.dept_id}")
            storeSave(s)
        }
        sendOk(ctx, memberBrief(s, tgt))
    } finally {
        s.lock.unlock()
    }
}

/*
 * POST /api/v1/members/{id}/disable —— 移出社团
 *
 * 账号与历史记录全部保留（不删除），日后可恢复。
 * 名下有未完成任务会被拒绝：不允许"人走了任务跟着烂尾"（api-design §3.2）。
 */
public func handleMemberDisable(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    let id = pathIdOr(ctx, "MEMBER_NOT_FOUND")

    s.lock.lock()
    try {
        let tgt = match (s.members.get(id)) {
            case Some(x) => x
            case None => throw apiErr("MEMBER_NOT_FOUND")
        }
        requireAccess(actor, Action.DisableMember, targetOf(actor, tgt))
        if (tgt.status == "disabled") {
            /* 幂等：已经是退出状态 */
            sendOk(ctx, memberBrief(s, tgt))
            return
        }
        if (tgt.role == "president" && presidentCount(s) <= 1) {
            throw apiErr("FORBIDDEN_LAST_PRESIDENT")
        }
        let open = openTasksOf(s, tgt.id)
        if (open.size > 0) {
            throw openTasksError(s, tgt, open)
        }
        tgt.status = "disabled"
        storeSave(s)
        audit(s, actor.id, "disable-member", tgt.id, "移出社团（账号保留）")
        sendOk(ctx, memberBrief(s, tgt))
    } finally {
        s.lock.unlock()
    }
}

/*
 * POST /api/v1/members/{id}/assign —— 单个分配（部门 + 角色）
 * **幂等**：对已是 active 的成员重复调用同样的分配，返回 200 而不报错。
 */
public func handleMemberAssign(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    let id = pathIdOr(ctx, "MEMBER_NOT_FOUND")
    let body = reqObj(ctx)
    let v = V()
    let role = v.need("role", reqStrOr(body, "role", ""), "请选择角色")
    let deptId = reqIntOr(body, "dept_id", 0)
    v.check("dept_id", deptId > 0, "请选择部门")
    v.check("role", isKnownRole(role), "角色必须是 5 档预设之一")
    if (role == "president") {
        v.check("role", false, "会长只能通过「移交会长」产生")
    }
    v.done()

    s.lock.lock()
    try {
        let tgt = match (s.members.get(id)) {
            case Some(x) => x
            case None => throw apiErr("MEMBER_NOT_FOUND")
        }
        requireAccess(actor, Action.AssignPending, targetOf(actor, tgt))
        match (s.departments.get(deptId)) {
            case Some(_) => ()
            case None => throw apiErr("DEPT_NOT_FOUND")
        }
        if (tgt.role == "president" && presidentCount(s) <= 1) {
            throw apiErr("FORBIDDEN_LAST_PRESIDENT")
        }
        /* M-4：assign 同时承担"审批待分配"和"恢复已退出成员"两件事。
         * 文档（api-design §3.2）写明移出社团是**保留数据、日后可恢复**，
         * 所以这里不拒绝 disabled 目标；但绝不能让它**静默**发生——
         * 审计里必须能一眼看出这次是"复活"而不是普通分配，
         * 否则事后追查"这个人是怎么回来的"会查不出来。 */
        let wasDisabled = (tgt.status == "disabled")
        tgt.dept_id = deptId
        tgt.role = role
        tgt.status = "active"
        tgt.dept_hint = 0
        storeSave(s)
        if (wasDisabled) {
            audit(s, actor.id, "restore-member", tgt.id,
                "恢复已退出成员：部门=${deptId} 角色=${role}（恢复与分配同用 assign，此处按恢复记账）")
        } else {
            audit(s, actor.id, "assign-member", tgt.id, "部门=${deptId} 角色=${role}")
        }
        sendOk(ctx, memberBrief(s, tgt))
    } finally {
        s.lock.unlock()
    }
}

/*
 * POST /api/v1/members/assign-batch —— 批量分配
 *
 * ⚠ **绝不能"一条失败就整体回滚"**。招新期一次处理 20 个人，
 * 因为其中 1 个数据有问题就全部不生效，会长会疯掉。
 * 逐条报告、让成功的生效，才是可用的批量语义。
 */
public func handleMemberAssignBatch(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    let body = reqObj(ctx)
    let v = V()
    let role = v.need("role", reqStrOr(body, "role", ""), "请选择角色")
    let deptId = reqIntOr(body, "dept_id", 0)
    v.check("dept_id", deptId > 0, "请选择部门")
    v.check("role", isKnownRole(role) && role != "president", "角色不合法（会长只能通过「移交」产生）")
    v.done()

    let ids = match (jsonGetArray(body, "member_ids")) {
        case Some(a) => a
        case None => throw apiErrFields("VALIDATION_FAILED", "参数校验失败", oneField("member_ids", "请提供成员列表"))
    }
    if (ids.size() == 0) {
        throw apiErrFields("VALIDATION_FAILED", "参数校验失败", oneField("member_ids", "成员列表不能为空"))
    }
    if (ids.size() > 200) {
        throw apiErrFields("VALIDATION_FAILED", "参数校验失败", oneField("member_ids", "一次最多处理 200 人"))
    }

    s.lock.lock()
    try {
        requireAccess(actor, Action.AssignPending, Target())
        match (s.departments.get(deptId)) {
            case Some(_) => ()
            case None => throw apiErr("DEPT_NOT_FOUND")
        }
        let ok = JsonArray()
        let bad = JsonArray()
        var restored: Int64 = 0
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
                    if (id < 0) {
                        addFail(bad, id, "VALIDATION_FAILED")
                        continue
                    }
                    match (s.members.get(id)) {
                        case Some(tgt) =>
                            /* N-10：外层那次 requireAccess 传的是**裸 Target()**，只能挡角色维度
                             * （部长 / 成员），挡不住同权。所以这里逐条按成员建 Target 再判一次；
                             * 失败写进 bad 数组，保持"绝不整体回滚、逐条报告"的批量语义。 */
                            let deny = checkAccess(actor, Action.AssignPending, targetOf(actor, tgt)) ?? ""
                            if (deny.size > 0) {
                                addFail(bad, id, deny)
                            } else if (tgt.role == "president" && presidentCount(s) <= 1) {
                                addFail(bad, id, "FORBIDDEN_LAST_PRESIDENT")
                            } else {
                                /* M-4：批量路径同样可能复活已退出成员，单独计数并单独记账 */
                                if (tgt.status == "disabled") {
                                    restored += 1
                                }
                                tgt.dept_id = deptId
                                tgt.role = role
                                tgt.status = "active"
                                tgt.dept_hint = 0
                                ok.add(JsonInt(id))
                            }
                        case None => addFail(bad, id, "MEMBER_NOT_FOUND")
                    }
                case None => ()
            }
        }
        storeSave(s)
        audit(s, actor.id, "assign-batch", deptId,
            "成功=${ok.size()} 失败=${bad.size()} 角色=${role} 其中恢复已退出成员=${restored}")
        let data = JsonObject()
        data.put("succeeded", ok)
        data.put("failed", bad)
        sendOk(ctx, data)
    } finally {
        s.lock.unlock()
    }
}

/*
 * POST /api/v1/members/{id}/transfer-presidency —— 会长移交（**仅现任会长**）
 *
 * 这是**一个原子操作**，内部同时完成：目标 → president，自己 → self_role。
 * 为什么不能"改两次角色"：分两步做中间会出现零会长状态，
 * 一旦第二步失败（网络、进程重启），社团就永久失去管理能力（规则 10/11）。
 *
 * 本接口是**产生会长的唯一入口**：assign 与 PATCH /members 一律拒绝 role=president。
 */
public func handleTransferPresidency(ctx: Context, s: Store): Unit {
    let actor = requireActive(ctx, s)
    let id = pathIdOr(ctx, "MEMBER_NOT_FOUND")
    let body = reqObj(ctx)
    let selfRole = reqStrOr(body, "self_role", "vice_president")

    let data = storeMutation(s, { =>
        let tgt = match (s.members.get(id)) {
            case Some(x) => x
            case None => throw apiErr("MEMBER_NOT_FOUND")
        }
        requireAccess(actor, Action.TransferPresidency, targetOf(actor, tgt))
        if (tgt.id == actor.id) {
            throw apiErrFields("VALIDATION_FAILED", "参数校验失败", oneField("id", "不能把会长移交给自己"))
        }
        if (tgt.status == "pending") {
            throw apiErr("MEMBER_PENDING")
        }
        if (tgt.status == "disabled") {
            throw apiErr("MEMBER_DISABLED")
        }
        /*
         * 2026-09-17（P1）：**不能把会长移交给运维账号**。
         *
         * 运维（role=ops）与会长同档，但它不是社团干部：它由 `init-ops` 创建、
         * 由 `retire-ops` 停用。一旦会长身份落到运维账号上，两条官方恢复路径会**同时失效**：
         *   · `retire-ops` 因 `m.role != "ops"` 拒绝（main.cj），
         *   · `init-admin` 因 `presidentCount(s) > 0` 拒绝（main.cj），
         * 只能靠手改 db.json 才能恢复治理。
         * 常规部署里运维账号的 id 通常就是 2（先 init-admin、再 init-ops），
         * 所以这是一条命令即可触发的治理死锁，不是理论风险。
         * 移交目标应该是"某位社团成员"，而不是这台机器上的运维身份。
         */
        if (tgt.role == "ops") {
            throw apiErrMsg("FORBIDDEN_ROLE", "不能把会长移交给运维账号（请移交给一位社团成员）")
        }
        if (!isKnownRole(selfRole) || selfRole == "president") {
            throw apiErrFields("VALIDATION_FAILED", "参数校验失败",
                oneField("self_role", "self_role 必须是会长以外的合法角色"))
        }
        /* 两步同时生效，只落盘一次——不会出现零会长的中间态 */
        tgt.role = "president"
        actor.role = selfRole
        audit(s, actor.id, "transfer-presidency", tgt.id, "原会长降为 ${selfRole}")
        let data = JsonObject()
        jPutObj(data, "president", memberBrief(s, tgt))
        jPutObj(data, "previous", memberBrief(s, actor))
        data
    })
    sendOk(ctx, data)
}
