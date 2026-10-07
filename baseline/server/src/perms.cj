/*
 * ===== 分工标注（用于课程/项目分工归属，非功能代码） =====================
 * 主要修改者：Haocheng Sun <2396556545@qq.com>
 *   提交 f7b34aa  后端修复：P1 权限/并发缺陷 + 非数据层输入加固（含运维台 9 条）
 *   提交 8a9e11c  复核修正：8 处「自述与代码不符 / 与既有契约冲突」
 * 本人改动量：+53 / -2（git log --author 统计；标注日期 2026-09-18）
 * 算法相关：新增 bypassesDeptScope()：部门范围豁免判定，并接入 checkAccess 的分层判定
 * =====================================================================
 */
package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * 权限判定 —— **全项目唯一一处**（api-design §1.6）。
 *
 * 铁律（..\docs\..\docs\HANDOFF.md §5）：权限判定收敛到一个函数，**禁止在每个 handler 里手写 if**。
 * 十几个接口各写一遍权限，一定会漏掉某个组合，而权限漏洞是社团工具里
 * 最难发现、后果最难受的一类缺陷。
 *
 * 判定四层（依次）：
 *   1. 账号状态      pending → MEMBER_PENDING；disabled → MEMBER_DISABLED
 *   2. 动作语义      这个动作对目标有没有额外约束（如"不能重置同权/更高权的人"）→ FORBIDDEN_ROLE
 *   3. 角色维度      这个角色能不能做这个动作 → FORBIDDEN_ROLE
 *   4. 部门范围      目标资源在不在自己的范围内 → FORBIDDEN_NOT_IN_DEPT
 *
 * 角色口径（v1-scope §3.4.3，v0.6 起）：
 *   会长        全部
 *   副会长      除「移交会长」与「改动会长本人」外，与会长同权
 *   部长/副部长  本部门成员、任务、课题（两者同权，仅名称不同）
 *   成员        只读本部门 + 只能改自己的任务状态
 *
 * 注意：Cangjie 枚举不支持 ==，这里一律用 match（探针已实测）。
 */

/* 受权限保护的动作。新增能力时先在这里加一项，再改 can()，最后才写 handler。 */
public enum Action {
    | ViewMembers
    | ViewTasks
    | EditMemberName
    | SetRole
    | DisableMember
    | AssignPending
    | ResetPassword
    | ManageDept
    | DeleteDept
    | ViewRegisterCode
    | ChangeRegisterCode
    | ManageInviteLink
    | TransferPresidency
    | CreatePlan
    | EditPlan
    | MovePlan
    | DeletePlan
    | CreateTask
    | EditTask
    | DeleteTask
    | UpdateTaskStatus
}

/*
 * 判定所需的"目标事实"。handler 负责把目标资源的部门/负责人/创建人填进来。
 * 缺省 0 表示"不适用"。
 */
public class Target {
    public var dept_id: Int64 = 0      /* 目标资源的部门 */
    public var owner_id: Int64 = 0     /* 任务/课题负责人 */
    public var creator_id: Int64 = 0   /* 任务创建人 */
    public var member_id: Int64 = 0    /* 目标成员 */
    public var target_role: String = "" /* 目标成员角色（用于"不能改动会长本人"） */
    public var is_self: Bool = false   /* 目标是否就是操作者本人 */
    /*
     * 2026-09-17（P1 加固）：`target_role` 为空串有**两种截然不同的含义**——
     *   · 目标**确实没有角色**：待分配成员（status=pending，role 就是空串），这是正常状态；
     *   · 调用方**漏填**：新 handler 传了裸 `Target()`，于是"同权保护"被静默绕过。
     * 光看空串分不清这两者，所以由 handler **显式声明**前一种情况（`targetOf()` 里设置）。
     * 声明之后，peer 闸对"空串且未声明"的目标一律拒绝（fail closed，与 `outranks` 同口径）。
     */
    public var role_absent: Bool = false /* 目标确实没有角色（待分配），见上 */

    public init() {}
}


/*
 * 角色档位：数字越大权限越高。
 * 部长与副部长同档（v1-scope §3.4.3：两者同权，仅名称不同）。
 * 待分配/未知角色为 0，低于任何在册角色。
 */
func roleRank(role: String): Int64 {
    if (role == "president") { return 5 }
    /*
     * 运维（ops）—— 2026-09-16 新增的内置身份，**与会长同档**。
     *
     * 为什么需要它：运维不该由会长本人执行（职责分离）。运维人员用后台自己的
     * 账号（admin/admin123）登录运维台，后台再用这个专用账号去调 club-server；
     * 审计里 actor 就是运维账号，一眼能看出"这是运维做的、不是会长做的"。
     *
     * 权限口径（用户 2026-09-16 定）：**除「移交会长」外与会长同权**。
     * 同档的直接后果是 checkAccess 里那道"不可作用于同档或更高档"的闸会拦住
     * 运维处置会长 —— 而"会长忘口令、运维帮他重置"正是要支持的场景，
     * 所以那里对运维单独放行（见 checkAccess 的 isOps 分支）。
     *
     * 这一档**不可由 API 分配**（views.cj 的 isKnownRole 里没有它），
     * 只能由本机命令 `club-server init-ops` 创建 —— 否则会长就能造出
     * 一个权限略高于自己的账号，等于绕过"会长只能通过移交产生"这条约束。
     */
    if (role == "ops") { return 5 }
    if (role == "vice_president") { return 4 }
    if (role == "lead") { return 3 }
    if (role == "vice_lead") { return 3 }
    if (role == "member") { return 1 }
    return 0
}

/*
 * 「不能改动同档或更高档的人」——2026-09-14 修复权限漏洞。
 *
 * 原先这条约束只写在副会长分支里，部长/副部长分支对 EditMemberName / ResetPassword
 * 直接放行，而部门范围判定只要求「同一部门」。于是只要把部长分到会长所在的部门，
 * 部长就能改会长的姓名、重置会长的密码，进而接管会长账号——报告里的 P0 H-1。
 *
 * 修法是把约束从「一个分支的特例」改成「部长档的档位规则」：
 * 目标档位必须**严格低于**操作者本人。这样部长动不了副部长/部长/副会长/会长。
 * （副会长是否改得动同僚副会长，文档口径是「与会长同权」，因此那一档仍只排除会长本人，
 *  不在这个函数里收紧。）
 */
func outranks(actor_role: String, target_role: String): Bool {
    if (actor_role == "president") {
        return true
    }
    /* 运维与会长同档：同样"可处置任何人"（其余约束由 roleAllows 与 checkAccess 管） */
    if (actor_role == "ops") {
        return true
    }
    /* 目标档位未知（空串）：宁拒不放过，避免将来某个新 handler 忘填 target_role
     * 就把这条规则悄悄绕过。 */
    if (target_role == "") {
        return false
    }
    return roleRank(target_role) < roleRank(actor_role)
}

/* 角色维度：这个角色能不能做这个动作（不看范围）。 */
func roleAllows(role: String, a: Action, t: Target): Bool {
    if (role == "president") {
        return true
    }
    if (role == "ops") {
        /*
         * 运维：除「移交会长」外**与会长同权**（2026-09-16）。
         *
         * 移交会长是治理动作 —— 谁当会长由会长自己决定，运维不参与。
         * 这也是这一档相对会长**唯一**的减法：部门增删改、改注册口令、
         * 处置任何成员（含会长与其他运维账号）都放行。
         * （用 match 而不是 `a == TransferPresidency`：这个枚举没有派生 == 运算符。）
         */
        match (a) {
            case TransferPresidency => return false
            case _ => return true
        }
    }
    if (role == "vice_president") {
        /* 与会长同权，只有这几处例外 */
        match (a) {
            case TransferPresidency => return false
            /* 注册口令：副会长**仅可查看**（api-design §3.6） */
            case ChangeRegisterCode => return false
            /* 部门增删改：**仅会长**。
             * 2026-09-13 决策（原先 §3.1/§6.1 与 §3.8 汇总表冲突，已统一为会长独占，
             * 文档三处已同步）。 */
            case ManageDept => return false
            case DeleteDept => return false
            case EditMemberName => return t.target_role != "president"
            case SetRole => return t.target_role != "president"
            case DisableMember => return t.target_role != "president"
            case ResetPassword => return t.target_role != "president"
            case _ => return true
        }
    }
    if (role == "lead" || role == "vice_lead") {
        match (a) {
            case ViewMembers => return true
            case ViewTasks => return true
            /* 只能作用于档位比自己低的成员（P0 H-1）：部长改不了同僚部长，
             * 更改不了副会长与会长，即使目标恰好和自己同部门。
             * 例外是**改自己的姓名**：那不是提权（改名不改变角色），
             * 而 api-design §3.8 的矩阵里「编辑成员姓名」对部长/副部长是「本部门」，
             * 本部门当然包含自己。scopeAllows 里原本就为此留了一条 is_self 分支。 */
            case EditMemberName => return t.is_self || outranks(role, t.target_role)
            /* 重置密码没有 is_self 例外：本接口签发一次性临时密码，是管理员救济动作，
             * 本人改密走 PUT /auth/password（P2 L-4，口径已统一）。 */
            case ResetPassword => return outranks(role, t.target_role)
            case CreatePlan => return true
            case EditPlan => return true
            case MovePlan => return true
            case DeletePlan => return true
            case CreateTask => return true
            case EditTask => return true
            case DeleteTask => return true
            case UpdateTaskStatus => return true
            case _ => return false
        }
    }
    if (role == "member") {
        match (a) {
            case ViewMembers => return true
            case ViewTasks => return true
            case UpdateTaskStatus => return t.is_self
            case _ => return false
        }
    }
    /* pending（无角色）或未知角色：一律拒绝 */
    return false
}

/*
 * 该角色是否**不受部门范围限制**（会长 / 副会长 / 运维）。
 *
 * 2026-09-17（P1）从 `scopeAllows` 里那一行抽出来单独成一个函数：
 * handler 判"某个人能不能管这个部门的东西"这类**数据一致性**问题时
 * （例如"课题负责人必须与课题同部门"），必须复用同一个口径，
 * 而不是在 handler 里手写 `role == "president"` —— 权限判定只有一处。
 */
public func bypassesDeptScope(role: String): Bool {
    return role == "president" || role == "vice_president" || role == "ops"
}

/* 部门范围维度。 */
func scopeAllows(m: Member, a: Action, t: Target): Bool {
    /*
     * **读**范围对全体 active 成员开放（2026-09-16，按 UI 设计规格 D-3）。
     *
     * 名录（ViewMembers）与任务 / 课题（ViewTasks）都是「全社团可见」：
     *   · P06 成员名录副行「共 42 位 · 全社团可见」；
     *   · P02 任务列表副行「共 38 项 · 全社团范围可见」，卡片本身是别的部门的任务；
     *   · P04 课题树用「全部」筛出**非本部门**的课题；
     *   · P03「部长在首页即可看到这条」——跨部门可见。
     * 原先只有名录放开（v1-scope §3.4.3 写「任务/课题：部长及以下本部门」），
     * 本次按设计稿放开，两份文档已同步。
     *
     * ⚠ 放开的只是**读**。写（改状态 / 编辑 / 删除 / 移动 / 分配）仍走下面的
     *   部门、创建人、负责人判定 —— 否则会推翻 P05/P07 的「处置动作按档位」模型。
     */
    match (a) {
        case ViewMembers => return true
        case ViewTasks => return true
        case _ => ()
    }
    if (bypassesDeptScope(m.role)) {
        return true
    }
    /* 自己的任务状态：与部门无关（跨部门被指派时也要能更新） */
    if (t.is_self) {
        match (a) {
            case UpdateTaskStatus => return true
            case _ => ()
        }
    }
    if (t.member_id > 0 && t.member_id == m.id) {
        match (a) {
            case EditMemberName => return true
            case _ => ()
        }
    }
    match (a) {
        case EditTask =>
            if (t.creator_id == m.id) {
                return true
            }
        case DeleteTask =>
            if (t.creator_id == m.id) {
                return true
            }
        case EditPlan =>
            /* 2026-09-17（P1）：负责人例外**必须同部门**。
             * 原先只要求"我是负责人"就在部门比较之前 return true，于是 A 部门的课题只要
             * 把负责人写成 B 部门的人，B 部门那个人就拿到了这个课题的写权限（改标题 / 截止 /
             * 换负责人）—— 跨部门越权写，与任务侧 N-18 的口径不一致。
             * 加上部门条件后，跨部门负责人会落到函数末尾那条 `t.dept_id == m.dept_id`
             * 判定（为假 → 拒）。这不是新增限制：**同部门**负责人本来就会走到那一条。 */
            if (t.owner_id == m.id && t.dept_id == m.dept_id) {
                return true
            }
        case _ => ()
    }
    return t.dept_id == m.dept_id
}

/* 返回拒绝原因的错误码；允许则返回 None。 */
public func checkAccess(m: Member, a: Action, t: Target): ?String {
    if (m.status == "pending") {
        return Some("MEMBER_PENDING")
    }
    if (m.status == "disabled") {
        return Some("MEMBER_DISABLED")
    }
    /* 2. 动作语义层（不看部门范围，但要读角色档位）
     *
     * 「不可作用于与自己**同权或更高权**的人」（2026-09-14 定，当天从"仅重置密码"
     * **推广到改名 / 改角色 / 禁用 / 审批分配 `assign`**）。
     *
     * 只保护"重置密码"是不够的：副会长档在 roleAllows 里对
     * EditMemberName / SetRole / DisableMember 只排除了 president，
     * 于是**副会长可以把另一位副会长降级为 member，或直接禁用**——
     * 同权之间本就不该能互相处置。现在这几类动作一起受这条约束。
     *
     * N-10 的教训：第一次推广时漏了 `assign` / `assign-batch`（它们同样写 role 与 status），
     * 结果副会长仍能降级同权者，甚至把会长刚移出的同权副会长"复活"（推翻会长的决定）。
     * 所以这里把**所有能写 role / status 的路径**列出来对账，新增接口时回到这张表：
     *   PATCH /members/{id}                     → SetRole / EditMemberName  ✅
     *   POST  /members/{id}/disable             → DisableMember            ✅
     *   POST  /members/{id}/assign              → AssignPending            ✅
     *   POST  /members/assign-batch             → AssignPending（逐条判）   ✅
     *   POST  /members/{id}/transfer-presidency → 会长独占                 —
     *   DELETE /depts/{id}（清 dept_id）        → 会长独占                 —
     *   POST  /auth/register（建 pending 账号） → 不属"处置既有成员"        —
     *
     * 规则本身一次覆盖三种情况：
     *   · 自己与自己同权 → "重置密码"连自己也禁（见下）；其余动作对自己网开一面；
     *   · 副会长与副会长同权 → 不能互相重置 / 降级 / 禁用 / 改名；
     *   · 会长档位最高，除自己外无人与之同权 → 会长仍能作用于任何更低档的人。
     *
     * 为什么不用 outranks()：它对 president 直接短路返回 true，
     * 于是"会长作用于会长自己"会被放行 —— 那正是 N-7 要拦的那一条。
     *
     * 为什么放在这里而不是 handler 里：会长与副会长的角色分支都是"直接放行"
     * （roleAllows 里 president 一档 `return true`、副会长档只排除 president），
     * 只有这一层拦得住他们；而"权限判定只有一处"是本项目的铁律。
     *
     * 判定用「目标 id 就是操作者 id」而不是只看 t.is_self：is_self 是派生的便利
     * 标志，新调用点忘填就静默失效；member_id 是必填事实。 */
    let peerForbidden = match (a) {
        case ResetPassword => true
        case SetRole => true
        case DisableMember => true
        case EditMemberName => true
        /* N-10：assign / assign-batch 也是成员处置类动作（能改 role 与 status）。
         * 漏掉它的后果有两个面：① 副会长可降级同权副会长；
         * ② 副会长能用 assign 把会长刚移出的同权副会长"复活"，推翻会长的决定。
         * 注意 pending 目标（role=""，档位 0）不会被误拦 —— 审批待分配照常可用。 */
        case AssignPending => true
        case _ => false
    }
    let isSelf = t.is_self || (t.member_id > 0 && t.member_id == m.id)
    /*
     * 运维（ops）不受"同档或更高档"这道闸的限制（2026-09-16）：
     * 它的权限口径是"除移交会长外与会长同权"，而会长能处置自己以外的任何人 ——
     * 运维要能重置会长的口令（会长忘口令是典型运维场景）、要能处置其他运维账号。
     * 下面那条"重置密码连自己也不许"对它**照旧生效**（那不是档位问题，
     * 而是"作废自己全部令牌 = 响应 200 后自己当场掉线"）。
     */
    let isOps = (m.role == "ops")
    if (peerForbidden && !isSelf && !isOps) {
        /*
         * 2026-09-17（P1 加固）：**先挡住"档位未知"**。
         *
         * `roleRank("")` 是 0 —— 低于任何在册角色。于是"调用方漏填 target_role"会让这条
         * 同权保护**静默失效**（fail open），与本文件 `outranks()` 里"空串宁拒不放过"
         * 的口径正好相反（那边 fail closed、这里 fail open）。影响面不小：
         * 会长与副会长在 roleAllows 里是"直接放行"，只有这一层拦得住他们，
         * 一旦 target_role 漏填，"副会长处置同权副会长"就通了。
         *
         * 现在只有 handler **显式声明**"这个目标确实没有角色"（`role_absent`，
         * 由 h_member.cj 的 `targetOf()` 按目标的真实 role 设置）才按 0 档处理；
         * 空串且未声明 = 调用方漏填 → 一律拒。
         *
         * ⚠ 为什么把 AssignPending 排除在外：这一档的"空串"本来就是**正常输入**
         *   （审批待分配 = 处置一个还没有角色的人），而且 `handleMemberPending`
         *   与 `assign-batch` 的外层检查传的就是裸 `Target()`（它们只借这次调用挡
         *   "角色维度"，逐条判定在后面自己再做一次）。对它们收紧会直接打掉审批流程。
         *   有单测钉着这两条：tests.cj 的"N-10 未误拦 pending"与"目标档位未知 拒"。
         */
        if (t.target_role.size == 0 && !t.role_absent) {
            match (a) {
                case AssignPending => ()
                case _ => return Some("FORBIDDEN_ROLE")
            }
        }
        if (roleRank(t.target_role) >= roleRank(m.role)) {
            return Some("FORBIDDEN_ROLE")
        }
    }
    /* 「重置密码」额外连**自己**也不许（N-7）：它是管理员救济动作，
     * 而这条路径收尾会 revokeOtherTokens(s, tgt.id, "") 把目标的**全部**令牌作废，
     * 对本人执行就是"响应 200、自己当场掉线"（客户端拿到成功却立刻 401）。
     * 改自己的姓名 / 角色 / 启停则是既有口径（且属自伤，没有提权收益），不受这条影响。 */
    match (a) {
        case ResetPassword =>
            if (isSelf) {
                return Some("FORBIDDEN_ROLE")
            }
        case _ => ()
    }
    if (!roleAllows(m.role, a, t)) {
        return Some("FORBIDDEN_ROLE")
    }
    if (!scopeAllows(m, a, t)) {
        return Some("FORBIDDEN_NOT_IN_DEPT")
    }
    return None
}

/* 对外只需要这一个问题：能不能。 */
public func can(m: Member, a: Action, t: Target): Bool {
    return checkAccess(m, a, t).isNone()
}

/* handler 用法：requireAccess(m, Action.CreateTask, tgt)。不通过直接抛 403。 */
public func requireAccess(m: Member, a: Action, t: Target): Unit {
    match (checkAccess(m, a, t)) {
        case Some(code) => throw apiErr(code)
        case None => ()
    }
}
