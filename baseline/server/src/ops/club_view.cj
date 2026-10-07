/*
 * ===== 分工标注（用于课程/项目分工归属，非功能代码） =====================
 * 主要修改者：Haocheng Sun <2396556545@qq.com>
 *   提交 f7b34aa  后端修复：P1 权限/并发缺陷 + 非数据层输入加固（含运维台 9 条）
 *   提交 8a9e11c  复核修正：8 处「自述与代码不符 / 与既有契约冲突」
 * 本人改动量：+153 / -18（git log --author 统计；标注日期 2026-09-18）
 * =====================================================================
 */
package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 运维台（admin 构建）专用
 * —— 社团库的**只读**视图层：概览 / 名录 / 部门 / 任务 / 课题 / 招募链接 / 审计日志。
 *
 * 定位（很重要）
 *   运维台**只读**社团库文件，一切**写**操作都转发给 club-server 的真实 API
 *   （由前端带会长令牌直接调用，见 ops/admin_main.cj 的文件头与 docs/HANDOFF.md）。
 *   理由：club-server 与运维台是两个进程，若都直接写同一个 db.json，就是 last-writer-wins，
 *   会静默丢数据，而且绕过 N-7 / N-15 那些已修的权限与原子性约束。
 *
 * 安全
 *   本文件**绝不**序列化 Member 的口令材料（pw_salt / pw_hash / pw_iter / pw_algo）。
 *   store.cj 里的 memberToJson 是"整库落盘"用的，会把那 4 个字段一起写出去，
 *   所以这里另写白名单视图 clubMemberRow()，不复用它。改这个文件时请守住这条。
 *
 * 时间
 *   库里的时间戳是 epoch 秒；对外一律用 timex.cj 的 isoLocal()（+08:00）格式化，
 *   与 club-server 的接口口径一致。
 */

import std.collection.*
import std.convert.*
import std.fs.*
import stdx.encoding.json.*

/* ===================== 小工具 ===================== */

/* epoch 秒 → ISO8601（本地时区）；0 / 负数 → null（与 api-design §1.8 一致）。 */
func clubPutTime(o: JsonObject, k: String, epoch: Int64): Unit {
    if (epoch > 0) {
        o.put(k, JsonString(isoLocal(epoch)))
    } else {
        o.put(k, JsonNull())
    }
}

/* 宽松取整：空串 / 非法 / 越界 → 默认值。运维台的 query 参数坏掉不该让页面白屏。 */
func clubIntOr(s: String, d: Int64): Int64 {
    let t = s.trimAscii()
    if (t.size == 0) {
        return d
    }
    try {
        return Int64.parse(t)
    } catch (e: Exception) {
        return d
    }
}

func clubDeptName(s: Store, id: Int64): String {
    if (id <= 0) {
        return ""
    }
    match (s.departments.get(id)) {
        case Some(d) => return d.name
        case None => return ""
    }
}

func clubMemberName(s: Store, id: Int64): String {
    if (id <= 0) {
        return ""
    }
    match (s.members.get(id)) {
        case Some(m) => return m.name
        case None => return ""
    }
}

func clubPlanTitle(s: Store, id: Int64): String {
    if (id <= 0) {
        return ""
    }
    match (s.plans.get(id)) {
        case Some(p) => return p.title
        case None => return ""
    }
}

/*
 * 角色代号 → 中文。代号必须与 club-server 一致：
 *   president / ops / vice_president / lead / vice_lead / member
 * ⚠ 中间两档是 **lead / vice_lead**（不是 minister）—— 2026-09-16 这里写错过一次，
 *   结果是运维页把"部长"显示成空白、下拉框发出去的代号还会被服务端拒。
 *   闸门：tests/ops-check.ps1 会分配 lead / vice_lead 并回读中文标签。
 */
func clubRoleLabel(role: String): String {
    if (role == "president") { return "会长" }
    if (role == "ops") { return "运维" }
    if (role == "vice_president") { return "副会长" }
    if (role == "lead") { return "部长" }
    if (role == "vice_lead") { return "副部长" }
    if (role == "member") { return "成员" }
    return ""
}

func clubMemberStatusLabel(st: String): String {
    if (st == "active") { return "在册" }
    if (st == "pending") { return "待分配" }
    if (st == "disabled") { return "已停用" }
    return st
}

func clubTaskStatusLabel(st: String): String {
    if (st == "todo") { return "待办" }
    if (st == "doing") { return "进行中" }
    if (st == "blocked") { return "受阻" }
    if (st == "done") { return "已完成" }
    return st
}

/* 文件字节数；读不到返回 0（不存在也算 0）。 */
func clubFileSize(path: String): Int64 {
    if (!exists(path)) {
        return 0
    }
    try {
        return File.readFrom(path).size
    } catch (e: Exception) {
        return 0
    }
}

/* 文件最后修改时间（epoch 秒）；读不到返回 0。用框架 etag.cj 的 fileLastModified（UTC DateTime）。 */
func clubFileMtime(path: String): Int64 {
    match (fileLastModified(path)) {
        case Some(dt) =>
            return dt.toUnixTimeStamp().toSeconds()
        case None => return 0
    }
}

/* ===================== 单行视图（白名单字段） ===================== */

/*
 * 成员一行。**不含任何口令材料**（见文件头"安全"一节）。
 * has_password 只说明"有没有设过口令"，运维排查"登不上"时够用且不泄露材料。
 *
 * open_tasks 由调用方传入的**聚合表**取（见 clubOpenTaskCounts 的长注释）：
 * 原先这一行自己调 openTasksOf(s, m.id)，而那个函数会遍历**全部任务** ——
 * 一页 500 个成员 × 上万条任务就是千万级迭代，全发生在"打开名录页"这一条请求里。
 */
func clubMemberRow(s: Store, m: Member, now: Int64, openCounts: HashMap<Int64, Int64>): JsonObject {
    let o = JsonObject()
    jPutInt(o, "id", m.id)
    jPutStr(o, "name", m.name)
    jPutStr(o, "phone", m.phone)
    jPutStr(o, "role", m.role)
    jPutStr(o, "role_label", clubRoleLabel(m.role))
    jPutInt(o, "dept_id", m.dept_id)
    jPutStr(o, "dept_name", clubDeptName(s, m.dept_id))
    jPutInt(o, "dept_hint", m.dept_hint)
    jPutStr(o, "dept_hint_name", clubDeptName(s, m.dept_hint))
    jPutStr(o, "status", m.status)
    jPutStr(o, "status_label", clubMemberStatusLabel(m.status))
    jPutBool(o, "is_president", m.role == "president")
    jPutBool(o, "has_password", m.pw_hash.size > 0)
    jPutInt(o, "open_tasks", openCounts.get(m.id) ?? 0)
    clubPutTime(o, "joined_at", m.joined_at)
    /* now 目前只用于"账号是否在册"这类派生展示，保留参数以便后续加派生字段 */
    if (m.status == "active" && m.role != "president" && now > 0) {
        jPutBool(o, "can_disable", true)
    } else {
        jPutBool(o, "can_disable", false)
    }
    return o
}

/*
 * 每个 owner 名下**未完成任务数**的聚合表（一次遍历 tasks）。
 *
 * 为什么需要（2026-09-17 修 N+1）：名录页的每行原先各自调 store.cj 的 openTasksOf()，
 * 而那个函数**遍历全部任务**（它是给"移出社团前必须转交"那种单成员检查用的）。
 * 于是开销是"本页行数 × 全库任务数"：size=500、库里有 1 万条任务就是 500 万次比较，
 * 而且排序开销（openTasksOf 内部还 sortByKey）也白花在只取 .size 的调用上。
 * 现在改成入口处**一次遍历**算出全表，行构造只做一次 HashMap 查表 —— O(任务数 + 本页行数)。
 *
 * 口径必须与 openTasksOf 逐条一致，否则 open_tasks 会悄悄变化：
 *   openTasksOf 的过滤是 `deleted_at > 0 || owner_id != memberId || status == "done"` → 跳过，
 *   即"未删除、且不是 done"才算未完成。这里按 owner_id 分桶累加同一条件。
 *   （owner_id = 0 的"无主任务"也会进表，但成员 id 恒 > 0，不会被查到，与旧行为一致。）
 */
func clubOpenTaskCounts(s: Store): HashMap<Int64, Int64> {
    let counts = HashMap<Int64, Int64>()
    for ((_k, t) in s.tasks) {
        if (t.deleted_at > 0 || t.status == "done") {
            continue
        }
        counts[t.owner_id] = (counts.get(t.owner_id) ?? 0) + 1
    }
    return counts
}

/* 部门一行：带在用人数与顶层课题数（运维最常问的两个数）。 */
func clubDeptRow(s: Store, d: Department): JsonObject {
    let o = JsonObject()
    jPutInt(o, "id", d.id)
    jPutStr(o, "name", d.name)
    jPutInt(o, "sort", d.sort)
    jPutInt(o, "active_members", activeMemberCountOfDept(s, d.id))
    jPutInt(o, "top_plans", topPlanCountOfDept(s, d.id))
    return o
}

/* 任务一行。 */
func clubTaskRow(s: Store, t: Task, now: Int64): JsonObject {
    let o = JsonObject()
    jPutInt(o, "id", t.id)
    jPutStr(o, "title", t.title)
    jPutInt(o, "owner_id", t.owner_id)
    jPutStr(o, "owner_name", clubMemberName(s, t.owner_id))
    jPutInt(o, "dept_id", t.dept_id)
    jPutStr(o, "dept_name", clubDeptName(s, t.dept_id))
    jPutInt(o, "plan_id", t.plan_id)
    jPutStr(o, "plan_title", clubPlanTitle(s, t.plan_id))
    jPutStr(o, "status", t.status)
    jPutStr(o, "status_label", clubTaskStatusLabel(t.status))
    jPutBool(o, "overdue", isTaskOverdue(t, now))
    jPutBool(o, "deleted", t.deleted_at > 0)
    clubPutTime(o, "due_at", t.due_at)
    clubPutTime(o, "updated_at", t.updated_at)
    clubPutTime(o, "completed_at", t.completed_at)
    /* 阻塞信息只在 blocked 时有意义（与 club-server 的口径一致） */
    if (t.status == "blocked") {
        jPutStr(o, "blocker", t.blocker)
        jPutInt(o, "help_dept_id", t.help_dept_id)
        jPutStr(o, "help_dept_name", clubDeptName(s, t.help_dept_id))
        jPutInt(o, "help_member_id", t.help_member_id)
        jPutStr(o, "help_member_name", clubMemberName(s, t.help_member_id))
    }
    return o
}

/* 课题一行（进度来自 planStatsAll 的一次性聚合，避免 O(n²)）。 */
func clubPlanRow(s: Store, p: Plan, stats: ?PlanStats): JsonObject {
    let o = JsonObject()
    jPutInt(o, "id", p.id)
    jPutStr(o, "title", p.title)
    jPutInt(o, "parent_id", p.parent_id)
    jPutInt(o, "dept_id", p.dept_id)
    jPutStr(o, "dept_name", clubDeptName(s, p.dept_id))
    jPutInt(o, "owner_id", p.owner_id)
    jPutStr(o, "owner_name", clubMemberName(s, p.owner_id))
    jPutInt(o, "depth", planDepthOf(s, p.id))
    clubPutTime(o, "due_at", p.due_at)
    clubPutTime(o, "updated_at", p.updated_at)
    match (stats) {
        case Some(x) =>
            jPutInt(o, "child_count", x.child_count)
            jPutInt(o, "tasks_total", x.total)
            jPutInt(o, "tasks_done", x.done)
            jPutInt(o, "own_tasks", x.task_count)
        case None =>
            jPutInt(o, "child_count", 0)
            jPutInt(o, "tasks_total", 0)
            jPutInt(o, "tasks_done", 0)
            jPutInt(o, "own_tasks", 0)
    }
    return o
}

/* 招募链接一行。token 对运维要可见（要发给新同学），所以不截断。 */
func clubLinkRow(s: Store, l: DeptInviteLink): JsonObject {
    let o = JsonObject()
    jPutStr(o, "token", l.token)
    jPutInt(o, "dept_id", l.dept_id)
    jPutStr(o, "dept_name", clubDeptName(s, l.dept_id))
    jPutBool(o, "enabled", l.enabled)
    jPutInt(o, "created_by", l.created_by)
    jPutStr(o, "created_by_name", clubMemberName(s, l.created_by))
    clubPutTime(o, "created_at", l.created_at)
    jPutStr(o, "path", "/join/${l.token}")
    return o
}

/* ===================== 概览 ===================== */

func clubOverview(s: Store): JsonObject {
    let now = nowEpoch()
    let o = JsonObject()
    /*
     * 数据来源（2026-09-20 改口径，与 /api/club/config 的改动配套 —— 见 admin_main.cj 那里
     * "删掉会撒谎的键"那一段）。
     *
     * 原先这里报 `data\db.json` 的路径 / 是否存在 / 大小 / mtime。club-server 的持久化
     * 整体迁到 **MySQL**（路线 B，见 src\mysql_store.cj）之后那个文件**不再产生**，
     * 继续报它就是撒谎：运维页会永远显示
     *     「库文件 <…>\db.json · 0.0 KB · 最后写入 —」
     * 而真实数据一条不少地躺在库里 —— 运维看到这个只会以为"库空了/落盘坏了"。
     * 所以四个键（db_file / db_exists / db_bytes / db_mtime）**全部删掉**，
     * 只如实回报后端类型；文件侧留着的东西只有 **audit.log**，
     * 它由下面的 `audit` 对象报（file / bytes / lines）。
     *   ⚠ 这里给不出主机与库名：Store 没有那层上下文（在 ops 配置里），
     *     库名与 host:port 由 /api/club/config 的 club_database / club_mysql 给。
     */
    jPutStr(o, "data_dir", s.dir)
    jPutStr(o, "db_backend", if (s.mysql.isSome()) { "mysql" } else { "file" })

    var active: Int64 = 0
    var pending: Int64 = 0
    var disabled: Int64 = 0
    var president: Int64 = 0
    var vicePresident: Int64 = 0
    var lead: Int64 = 0
    var viceLead: Int64 = 0
    var plainMember: Int64 = 0
    for ((_k, m) in s.members) {
        if (m.status == "active") { active += 1 }
        if (m.status == "pending") { pending += 1 }
        if (m.status == "disabled") { disabled += 1 }
        if (m.role == "president") { president += 1 }
        if (m.role == "vice_president") { vicePresident += 1 }
        /* ⚠ 中间两档的**权威角色码是 lead / vice_lead**（见 perms.cj 的 roleRank、
         *   views.cj 的 roleLabel，以及本文件 clubRoleLabel() 上方那段注释）。
         *   2026-09-17 之前这里判的是 `"minister"` / `"vice_minister"` —— 那是从来没存在过的
         *   代号，于是**部长/副部长两个数恒为 0**：库里有几个部长，概览都显示 0，
         *   而同一页的名录又照常显示「部长」（它走 role_label），自相矛盾且极易被当成"数据没录进去"。
         *   注意 `member` 这一档：部长**不同时**计入 member（role 是单值，不是位掩码），
         *   所以 total ≠ active + 各档之和时不必惊讶 —— ops 账号也不计入任何一档。 */
        if (m.role == "lead") { lead += 1 }
        if (m.role == "vice_lead") { viceLead += 1 }
        if (m.role == "member") { plainMember += 1 }
    }
    let mj = JsonObject()
    jPutInt(mj, "total", s.members.size)
    jPutInt(mj, "active", active)
    jPutInt(mj, "pending", pending)
    jPutInt(mj, "disabled", disabled)
    jPutInt(mj, "president", president)
    jPutInt(mj, "vice_president", vicePresident)
    /*
     * ⚠ 这两个**键名**（minister / vice_minister）是历史遗留的错名，本次**故意不改**：
     *   它们承载的是"部长 / 副部长"两个数（即上面的 lead / viceLead），改键名属于契约漂移。
     *   之所以能确认改键名安全、但选择不改：`grep -ri minister server/admin-web/src` 与
     *   `grep -ri minister server/tests` 都是 0 命中 —— 前端目前根本没消费这两个键，
     *   所以本次只修"数错了"这件事本身；键名若要纠正，应该连同前端一起作为一次独立的契约变更做。
     */
    jPutInt(mj, "minister", lead)
    jPutInt(mj, "vice_minister", viceLead)
    jPutInt(mj, "member", plainMember)
    o.put("members", mj)

    var tOpen: Int64 = 0
    var tDone: Int64 = 0
    var tBlocked: Int64 = 0
    var tOverdue: Int64 = 0
    var tDeleted: Int64 = 0
    for ((_k, t) in s.tasks) {
        if (t.deleted_at > 0) {
            tDeleted += 1
            continue
        }
        if (t.status == "done") {
            tDone += 1
        } else {
            tOpen += 1
        }
        if (t.status == "blocked") { tBlocked += 1 }
        if (isTaskOverdue(t, now)) { tOverdue += 1 }
    }
    let tj = JsonObject()
    jPutInt(tj, "total", s.tasks.size)
    jPutInt(tj, "open", tOpen)
    jPutInt(tj, "done", tDone)
    jPutInt(tj, "blocked", tBlocked)
    jPutInt(tj, "overdue", tOverdue)
    jPutInt(tj, "deleted", tDeleted)
    o.put("tasks", tj)

    var linksOn: Int64 = 0
    for ((_k, l) in s.invite_links) {
        if (l.enabled) { linksOn += 1 }
    }
    let lj = JsonObject()
    jPutInt(lj, "total", s.invite_links.size)
    jPutInt(lj, "enabled", linksOn)
    o.put("links", lj)

    var tokActive: Int64 = 0
    for ((_k, t) in s.tokens) {
        if (t.expires_at > now) { tokActive += 1 }
    }
    let kj = JsonObject()
    jPutInt(kj, "total", s.tokens.size)
    jPutInt(kj, "active", tokActive)
    o.put("tokens", kj)

    jPutInt(o, "depts", s.departments.size)
    jPutInt(o, "plans", s.plans.size)
    jPutInt(o, "idem", s.idem.size)

    /* 注册口令：只有会长/副会长能看（api-design §3.6），运维台本身又只放给 admin 角色，
     * 所以这里直接给出，省得运维再去客户端翻。 */
    let rj = JsonObject()
    jPutBool(rj, "has_code", s.register_code.size > 0)
    jPutStr(rj, "code", s.register_code)
    jPutInt(rj, "by_member_id", s.register_code_by)
    jPutStr(rj, "by_name", clubMemberName(s, s.register_code_by))
    clubPutTime(rj, "at", s.register_code_at)
    o.put("register", rj)

    let auditFile = "${s.dir}/audit.log"
    let aj = JsonObject()
    jPutStr(aj, "file", auditFile)
    /* 字节数与行数**一次读盘**同时取（见 clubAuditStat 的长注释）：
     * 原先这里是 clubFileSize() + clubAuditLines(s, 0) —— 读两遍，而且后一遍把每一行都建成
     * JsonObject 再丢掉，只为得到一个行数。 */
    let (auditBytes, auditLines) = clubAuditStat(s)
    jPutInt(aj, "bytes", auditBytes)
    jPutInt(aj, "lines", auditLines)
    o.put("audit", aj)

    return o
}

/* ===================== 列表 ===================== */

/*
 * 分页：默认 50，最多 500（运维台不做无限拉取）。
 *
 * ⚠ page 也要有上界（2026-09-18 补）：`(page - 1) * size` 在仓颉里**溢出即抛**
 *   （实测 cjc 1.1.3：Int64 算术默认检查溢出，`9223372036854775807 * 500`
 *   → OverflowException: mul），而异常会穿透 handler、被链上 passOnNotFound 留下的
 *   404 壳吞掉（链尾 opsErrorHandler 只在 "status==200 且 body 为空" 时才补 500 壳）——
 *   于是 `?page=9223372036854775807` 会让客户端看到「HTTP 404 接口不存在」，
 *   与 clubDepts 原先那个越界 sort 的 bug 同型：一个有效端点被说成"不存在"。
 *   1e6 页早已超出任何真实数据规模，夹到上界即可；夹紧后 (page-1)*size ≤ 5e8，不会溢出。
 */
let CLUB_PAGE_MAX: Int64 = 1000000

func clubPaging(ctx: Context): (Int64, Int64) {
    var page = clubIntOr(ctx.queryParamOr("page", "1"), 1)
    var size = clubIntOr(ctx.queryParamOr("size", "50"), 50)
    if (page < 1) { page = 1 }
    if (page > CLUB_PAGE_MAX) { page = CLUB_PAGE_MAX }
    if (size < 1) { size = 50 }
    if (size > 500) { size = 500 }
    return (page, size)
}

/*
 * 审计日志一次最多回多少行。
 *
 * 为什么要有上限（2026-09-17 修）：`/api/club/audit` 收的是**裸的 limit**
 * （`clubIntOr(...)` 对越界/非法值只回退默认值，没有上界），而 clubAuditLines() 会把
 * 整个 audit.log **读进内存再 split**。审计日志是只追加的，跑几个月就是几万行 ——
 * 于是 `?limit=99999999` 一条请求就能让运维台把几十 MB 的字符串切成一堆行、
 * 再为每一行建一个 JsonObject（每行还要两次成员名查表）。这不是"运维台自己慢"，
 * 它和 clubPaging 的 500 上界是**同一类**防护：运维台不做无限拉取。
 *
 * 取 2000 而不是 500：审计页要能"一次看长一点的历史"，而 2000 行 JSON 仍是百 KB 量级；
 * 默认值与"非法/0/负数"的回退值都保持 200（**既有行为不变**，只是加了一道上界）。
 */
let CLUB_AUDIT_LIMIT_MAX: Int64 = 2000

func clubAuditLimit(ctx: Context): Int64 {
    var limit = clubIntOr(ctx.queryParamOr("limit", "200"), 200)
    if (limit <= 0) { limit = 200 }
    if (limit > CLUB_AUDIT_LIMIT_MAX) { limit = CLUB_AUDIT_LIMIT_MAX }
    return limit
}

func clubMembers(s: Store, ctx: Context): JsonObject {
    let now = nowEpoch()
    let q = ctx.queryParamOr("q", "").trimAscii().toAsciiLower()
    let deptId = clubIntOr(ctx.queryParamOr("dept_id", "0"), 0)
    let role = ctx.queryParamOr("role", "").trimAscii()
    let statusFilter = ctx.queryParamOr("status", "").trimAscii()
    let (page, size) = clubPaging(ctx)

    let all = ArrayList<Member>()
    for ((_k, m) in s.members) {
        all.add(m)
    }
    let sorted = all.toArray()
    sortByKey<Member>(sorted, { m: Member => m.id })

    let hit = ArrayList<Member>()
    for (m in sorted) {
        if (q.size > 0) {
            let byName = containsAscii(m.name.toAsciiLower(), q)
            let byPhone = containsAscii(m.phone, q)
            if (!byName && !byPhone) { continue }
        }
        if (deptId > 0 && m.dept_id != deptId) { continue }
        if (role.size > 0 && m.role != role) { continue }
        if (statusFilter.size > 0 && m.status != statusFilter) { continue }
        hit.add(m)
    }

    let items = JsonArray()
    let total = hit.size
    let from = (page - 1) * size
    /* 未完成任务数在**投影前**一次算完（见 clubOpenTaskCounts 的长注释），
     * 行构造里只做查表 —— 不要再把 openTasksOf() 放回 clubMemberRow 里。 */
    let openCounts = clubOpenTaskCounts(s)
    var i: Int64 = 0
    for (m in hit.toArray()) {
        if (i >= from && i < from + size) {
            items.add(clubMemberRow(s, m, now, openCounts))
        }
        i += 1
    }
    let o = JsonObject()
    o.put("items", items)
    jPutInt(o, "total", total)
    jPutInt(o, "page", page)
    jPutInt(o, "size", size)
    return o
}

func clubDepts(s: Store): JsonObject {
    /*
     * 部门展示顺序：直接复用 store.cj 的 sortedDepartments()（sort → id）。
     *
     * 原先这里自己拼了 `d.sort * 1000 + d.id`，有两个坑（2026-09-17 修，两个都实测过）：
     *   ① **越界值会让这个接口彻底不可用**。sort 没有上界保证 —— 磁盘上可能已经有旧版本写下的
     *      越界值（store.cj 的 SORT_MAX 注释就是这么写的："因为磁盘上可能已经有旧版本写下的越界值"）。
     *      仓颉的 Int64 算术**默认"溢出即抛"**（实测：把 `Int64.parse("9223372036854775807")`
     *      这个**运行时**值乘 1000 → `OverflowException: mul`；写成编译期常量则直接被编译器拒绝），
     *      所以这里不是"悄悄回绕成负数、排到最前面"，而是**抛出去**。
     *      抛出去之后更难看：本文件上方的 passOnNotFound 路由（publicRouter / authRouter / mgmtRouter
     *      都是）在 miss 时**已经往 ctx 里写了 404 + `{"error":"Not Found","path":...}`**，
     *      而链尾的 opsErrorHandler 只在"status == 200 且 body 为空"时才补 500 壳 ——
     *      于是客户端拿到的是 **HTTP 404「路由不存在」**，整条响应里没有一个字段像"服务器算错了"。
     *      实测（把 db.json 里某个部门的 sort 改成 9223372036854775807 后重启运维台，同一份数据）：
     *        修前 GET /api/club/depts -> HTTP 404 {"error":"Not Found","path":"/api/club/depts"}（连打两次都一样）
     *        修后 GET /api/club/depts -> HTTP 200，那个部门排在最后
     *      因为这个值每次请求都要从 db.json 读出来，所以是**持续 404**，只能手工改文件才能恢复
     *      （store.cj 里描述的正是这个后果："接口从此永久 500，只能手工改文件才能恢复"）。
     *   ② 就算不溢出，低位也只给 id 留了 3 位十进制：id ≥ 1000 时 `sort=1,id=0` 的键（1000）
     *      会小于 `sort=0,id=5000` 的键（5000）—— **顺序整个错**，而 id 是自增的，早晚过 1000。
     * sortedDepartments() 用的正是 sortKeyClamp(sort) * 1000000 + id（clamp 到 [SORT_MIN, SORT_MAX]，
     * 且给 id 留下 6 位），① ② 一起治掉。这里**不再自己写排序键**，避免两份口径漂移 ——
     * 那正是这个文件与 store.cj 之间最容易失守的地方。
     */
    let sorted = sortedDepartments(s)
    let items = JsonArray()
    for (d in sorted) {
        items.add(clubDeptRow(s, d))
    }
    let o = JsonObject()
    o.put("items", items)
    jPutInt(o, "total", sorted.size)
    return o
}

func clubTasks(s: Store, ctx: Context): JsonObject {
    let now = nowEpoch()
    let q = ctx.queryParamOr("q", "").trimAscii().toAsciiLower()
    let statusFilter = ctx.queryParamOr("status", "").trimAscii()
    let deptId = clubIntOr(ctx.queryParamOr("dept_id", "0"), 0)
    let ownerId = clubIntOr(ctx.queryParamOr("owner_id", "0"), 0)
    let planId = clubIntOr(ctx.queryParamOr("plan_id", "0"), 0)
    let overdueOnly = ctx.queryParamOr("overdue", "") == "1"
    let withDeleted = ctx.queryParamOr("deleted", "") == "1"
    let (page, size) = clubPaging(ctx)

    let all = ArrayList<Task>()
    for ((_k, t) in s.tasks) {
        all.add(t)
    }
    let sorted = all.toArray()
    /* 按截止时间倒序不方便（sortByKey 只有升序），这里按 id 升序，前端自己排。 */
    sortByKey<Task>(sorted, { t: Task => t.id })

    let hit = ArrayList<Task>()
    for (t in sorted) {
        if (!withDeleted && t.deleted_at > 0) { continue }
        if (q.size > 0 && !containsAscii(t.title.toAsciiLower(), q)) { continue }
        if (statusFilter.size > 0 && t.status != statusFilter) { continue }
        if (deptId > 0 && t.dept_id != deptId) { continue }
        if (ownerId > 0 && t.owner_id != ownerId) { continue }
        if (planId > 0 && t.plan_id != planId) { continue }
        if (overdueOnly && !isTaskOverdue(t, now)) { continue }
        hit.add(t)
    }

    let items = JsonArray()
    let total = hit.size
    let from = (page - 1) * size
    var i: Int64 = 0
    for (t in hit.toArray()) {
        if (i >= from && i < from + size) {
            items.add(clubTaskRow(s, t, now))
        }
        i += 1
    }
    let o = JsonObject()
    o.put("items", items)
    jPutInt(o, "total", total)
    jPutInt(o, "page", page)
    jPutInt(o, "size", size)
    return o
}

func clubPlans(s: Store): JsonObject {
    let ids = HashSet<Int64>()
    for ((_k, p) in s.plans) {
        ids.add(p.id)
    }
    /* 一次性自底向上聚合（O(n)），不要在每个节点上再递归（那会变 O(n²)）。 */
    let stats = planStatsAll(s, ids)

    let all = ArrayList<Plan>()
    for ((_k, p) in s.plans) {
        all.add(p)
    }
    let sorted = all.toArray()
    sortByKey<Plan>(sorted, { p: Plan => p.id })

    let items = JsonArray()
    for (p in sorted) {
        items.add(clubPlanRow(s, p, stats.get(p.id)))
    }
    let o = JsonObject()
    o.put("items", items)
    jPutInt(o, "total", sorted.size)
    return o
}

func clubLinks(s: Store): JsonObject {
    let all = ArrayList<DeptInviteLink>()
    for ((_k, l) in s.invite_links) {
        all.add(l)
    }
    let sorted = all.toArray()
    sortByKey<DeptInviteLink>(sorted, { l: DeptInviteLink => l.created_at })
    let items = JsonArray()
    /* 新→旧：反着放，运维最关心最近生成的 */
    var i = sorted.size - 1
    while (i >= 0) {
        items.add(clubLinkRow(s, sorted[i]))
        i -= 1
    }
    let o = JsonObject()
    o.put("items", items)
    jPutInt(o, "total", sorted.size)
    return o
}

/* ===================== 审计日志 ===================== */

/*
 * 审计日志的 (字节数, 行数) —— **一次读盘同时给出这两个数**。
 *
 * 为什么单独写一个函数（2026-09-17）：
 *   · 概览原先要读**两遍** audit.log 才能显示这两个数：`clubFileSize()` 把整个文件读进内存
 *     只为取 `.size`，`clubAuditLines(s, 0)` 再把**每一行都建成 JsonObject**（每行两次
 *     clubMemberName 查表）然后整份丢掉、只取一个行数 —— 概览是运维页每次打开都要打的接口，
 *     而 audit.log 只会越来越长。
 *   · 行数口径必须与 clubAuditLines() 的 `split("\n", -1, removeEmpty: true).size` **逐字节等价**，
 *     否则页面上"审计行数"会莫名变化。等价性：只有 '\n' 是行分隔符，空段（连续换行、结尾换行）
 *     不计入 —— 于是"见到 '\n' 时若本段已有内容就 +1，收尾时本段还有内容再 +1"就是同一个数。
 *     （注意 '\r' 也算"有内容"：CRLF 文件里 `"\r"` 是一个**非空**段，切分口径同样会计它。）
 *   · 读不到（文件不存在 / 无权限）→ (0, 0)，与 clubFileSize() 的既有口径一致（0 而不是报错）。
 */
func clubAuditStat(s: Store): (Int64, Int64) {
    let path = "${s.dir}/audit.log"
    var bytes: Array<UInt8>
    try {
        bytes = File.readFrom(path)
    } catch (e: Exception) {
        return (0, 0)
    }
    var lines: Int64 = 0
    var inLine = false
    let n = bytes.size
    var i: Int64 = 0
    while (i < n) {
        if (bytes[i] == 10) {        /* '\n' */
            if (inLine) { lines += 1 }
            inLine = false
        } else {
            inLine = true
        }
        i += 1
    }
    if (inLine) { lines += 1 }
    return (bytes.size, lines)
}

/*
 * 读 <数据目录>/audit.log 的尾部。`limit <= 0` 表示**不截断（返回全部行）**。
 *
 * ⚠ 2026-09-18 改：**只对尾部那一小段做切分**。
 *   原先的实现是 `String.fromUtf8(File.readFrom(path))` 之后对**整份**文本
 *   `split("\n", -1, removeEmpty: true)`，再取最后 limit 段 —— 也就是说
 *   clubAuditLimit 的 2000 上界只省掉了 JsonObject 的构造，**切分本身**
 *   （几万行时就是几万个 String）每次请求照样发生，与那里的注释宣称的效果并不相符。
 *   现在按字节从末尾反向扫够 limit 个**非空段**，只把那一小段（cut..n）解成字符串再切。
 *   手法与 clubAuditStat 的字节扫描一致，行数口径也一致：只有 '\n' 是分隔符、
 *   空段不计入（见 clubAuditStat 的注释）。
 *   安全性：cut 一定落在换行符**之后**，而 '\n'(0x0A) 不可能是 UTF-8 的续字节，
 *   所以 String.fromUtf8(bytes[cut..n]) 永远是合法 UTF-8。
 *   仍然保留"整份读进内存"这一步（与 clubAuditStat / clubFileSize 同一口径；
 *   要彻底避免得改成流式读，那是独立的一轮）。
 *
 * ⚠ 2026-09-17 更正：这里原先写着"limit = 0 表示只要总行数（概览用）"，但实现从来不是那样 ——
 *   返回的始终是**全部行**（只是概览把结果丢掉、只取 size）。现在概览改用
 *   clubAuditStat()（只数不解析），本函数的调用方一律传正数 limit（上界见 clubAuditLimit）。
 *   保留 `limit <= 0 → 全部` 这条行为，是为了不动既有语义；但**不要**再用它去数行数。
 *
 * 行格式（audit.cj 写入口，制表符分隔，note 里的制表符已被替换成空格，所以恒为 5 段）：
 *   <iso本地时间>\tactor=<id>\t<动作>\ttarget=<id>\t<备注>
 * 解析失败的行走"原始行"分支，绝不丢——运维日志里出现看不懂的行本身就是线索。
 */
func clubAuditLines(s: Store, limit: Int64): JsonArray {
    let path = "${s.dir}/audit.log"
    let out = JsonArray()
    if (!exists(path)) {
        return out
    }
    var bytes: Array<UInt8>
    try {
        bytes = File.readFrom(path)
    } catch (e: Exception) {
        return out
    }
    /*
     * 尾部窗口起点 cut：从末尾反向扫，每扫完一个**非空段**就计数，
     * 数够 limit 个时 cut = 那一段的起始字节（跳过它前面的 '\n'）。
     * 段数不够、或 limit <= 0（不截断）时 cut 保持 0 → 整份。
     */
    let n = bytes.size
    var cut: Int64 = 0
    if (limit > 0) {
        var seen: Int64 = 0
        var hasContent = false
        var bi = n - 1
        while (bi >= 0) {
            if (bytes[bi] == 10) {        /* '\n' */
                if (hasContent) {
                    seen += 1
                    if (seen >= limit) {
                        cut = bi + 1
                        break
                    }
                }
                hasContent = false
            } else {
                hasContent = true
            }
            bi -= 1
        }
    }
    let text = String.fromUtf8(bytes[cut..n])
    let lines = text.split("\n", -1, removeEmpty: true)
    /* 新→旧输出 */
    var i = lines.size - 1
    while (i >= 0) {
        let line = lines[i]
        let o = JsonObject()
        let parts = line.split("\t", -1, removeEmpty: false)
        if (parts.size >= 5) {
            jPutStr(o, "at", parts[0])
            jPutInt(o, "actor_id", clubIntOr(clubStripPrefix(parts[1], "actor="), 0))
            jPutStr(o, "actor_name", clubMemberName(s, clubIntOr(clubStripPrefix(parts[1], "actor="), 0)))
            jPutStr(o, "action", parts[2])
            jPutInt(o, "target_id", clubIntOr(clubStripPrefix(parts[3], "target="), 0))
            jPutStr(o, "target_name", clubMemberName(s, clubIntOr(clubStripPrefix(parts[3], "target="), 0)))
            jPutStr(o, "note", parts[4])
            jPutBool(o, "parsed", true)
        } else {
            jPutStr(o, "at", "")
            jPutInt(o, "actor_id", 0)
            jPutStr(o, "actor_name", "")
            jPutStr(o, "action", "?")
            jPutInt(o, "target_id", 0)
            jPutStr(o, "target_name", "")
            jPutStr(o, "note", line)
            jPutBool(o, "parsed", false)
        }
        out.add(o)
        i -= 1
    }
    return out
}

func clubStripPrefix(v: String, pfx: String): String {
    if (v.size >= pfx.size && v[0..pfx.size] == pfx) {
        return v[pfx.size..]
    }
    return v
}
