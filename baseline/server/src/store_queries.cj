package qingzhou

/*
 * 社团管理工具 · Store 的查询、排序、幂等与课题树辅助。
 * 数据模型与 JSON 字段映射见 store.cj；加载与落盘见 store_persistence.cj。
 */

import std.collection.*
import stdx.encoding.json.*

/* ===================== 查询辅助 ===================== */


public func memberByPhone(s: Store, phone: String): ?Member {
    for ((_k, m) in s.members) {
        if (m.phone == phone) {
            return Some(m)
        }
    }
    return None
}



/* 未删除的任务。全项目一致地用它过滤【v1-scope 规则 17】。 */
public func activeTaskById(s: Store, id: Int64): ?Task {
    match (s.tasks.get(id)) {
        case Some(t) =>
            if (t.deleted_at > 0) {
                return None
            }
            return Some(t)
        case None => return None
    }
}

/*
 * 会长人数：规则 10「系统必须始终至少有一个 president」。
 * 口径 = `role == "president"` 且 `status != "disabled"`（**pending 也算**：
 * 但 `pending` 且 `role = "president"` 在各写入路径上都不可达 —— 注册给空角色、
 * `assign`/PATCH 同时改 role 与 status、移交要求目标 active —— 所以这一条不影响判定）。
 */
public func presidentCount(s: Store): Int64 {
    var n: Int64 = 0
    for ((_k, m) in s.members) {
        if (m.role == "president" && m.status != "disabled") {
            n += 1
        }
    }
    return n
}

/* 待分配列表（先来先处理，即按 id 升序 = 注册顺序）。 */
public func pendingMembers(s: Store): Array<Member> {
    let out = ArrayList<Member>()
    for ((_k, m) in s.members) {
        if (m.status == "pending") {
            out.add(m)
        }
    }
    let arr = out.toArray()
    sortByKey<Member>(arr, { m: Member => m.id })
    return arr
}

/*
 * 按 Int64 键排序：**原地堆排序 O(n log n)**。
 *
 * 2026-09-15 替换原先的插入排序。为什么必须换（见 docs/capacity-baseline.md 的实测）：
 * 这里排的不是"几十条"，而是**某个用户能看见的全部任务 / 成员**——会长看得见全社团。
 * 插入排序是 O(n²)，实测：
 *     可见任务  8000 个 → GET /tasks 168 ms
 *     可见任务 24000 个 → GET /tasks **1017 ms**（数据涨 3 倍，延迟涨 6 倍 = 平方项）
 * 换堆排序后回到同一量级下几十毫秒。
 *
 * 为什么自己写而不用 std.sort：本项目只用**已实测过**的标准库入口（docs/API-NOTES.md 开头的纪律）。
 * 堆排序原地、零额外分配、不引入新 API。
 *
 * 稳定性：堆排序不稳定。需要复合排序语义的调用点要在比较器中明确写出
 * 次关键字（任务截止时间排序由 `sortTasksByDue` 负责）。
 */
func sortByKey<T>(arr: Array<T>, key: (T) -> Int64): Unit {
    let n = arr.size
    if (n < 2) {
        return
    }
    /* 1) 建大顶堆：从最后一个非叶节点起逐个下沉 */
    var i = n / 2 - 1
    while (i >= 0) {
        siftDown<T>(arr, i, n, key)
        i -= 1
    }
    /* 2) 反复把堆顶（当前最大）换到末尾，再对缩小后的堆下沉 */
    var end = n - 1
    while (end > 0) {
        let tmp = arr[0]
        arr[0] = arr[end]
        arr[end] = tmp
        siftDown<T>(arr, 0, end, key)
        end -= 1
    }
}

/* 把 root0 处的元素在 [0, end) 范围内下沉到正确位置。 */
func siftDown<T>(arr: Array<T>, root0: Int64, end: Int64, key: (T) -> Int64): Unit {
    var root = root0
    var go = true
    while (go) {
        let left = root * 2 + 1
        if (left >= end) {
            go = false
        } else {
            var pick = left
            let right = left + 1
            if (right < end && key(arr[left]) < key(arr[right])) {
                pick = right
            }
            if (key(arr[root]) < key(arr[pick])) {
                let tmp = arr[root]
                arr[root] = arr[pick]
                arr[pick] = tmp
                root = pick
            } else {
                go = false
            }
        }
    }
}

/*
 * 复合排序键的安全折算（P1 M-8）。
 *
 * `sort * 1000000 + id` 这个写法隐含前提：sort 必须是有界的小整数。原先没有校验，
 * 一个 sort = 9223372036854775807 会让乘法溢出，排序键变成一个大负数，
 * 而且这个坏值会**落盘**——之后每一次 GET /depts 都在排序时溢出，
 * 接口从此永久 500，只能手工改文件才能恢复。
 *
 * 两道防线：handler 侧校验 sort 取值范围（h_dept.cj 的 SORT_MIN/SORT_MAX），
 * 这里再夹一次——因为磁盘上可能已经有旧版本写下的越界值。夹紧只影响排序先后，
 * 不会丢数据，也不会让接口起不来。
 */
public let SORT_MIN: Int64 = 0
public let SORT_MAX: Int64 = 10000

/*
 * 「未分配部门」（`dept_id = 0`，或部门已被删除）在成员排序里的哨兵值。
 *
 * ⚠ 必须**严格大于 `SORT_MAX`**（2026-09-16 修）。原先 `sortedMembers` 里写死 999，
 * 而 sort 的合法上界是 10000 —— 只要有一个部门的 `sort ≥ 999`，
 * 未分配成员就会排到那个部门**前面**，与"未分配部门排最后"的注释相反。
 * （默认建的部门 sort 是 0、1、2…，所以这个裂缝平时看不见；但 `POST /depts` 允许
 *   客户端显式传 sort，最大 10000，一传就暴露。）
 *
 * 取 `SORT_MAX + 1` 而不是更大的数：排序键是 `ds * 1000000 + id`，
 * 这个量级离 Int64 上界还很远，不会溢出。
 */
public let SORT_UNASSIGNED: Int64 = SORT_MAX + 1

func sortKeyClamp(v: Int64): Int64 {
    if (v < SORT_MIN) {
        return SORT_MIN
    }
    if (v > SORT_MAX) {
        return SORT_MAX
    }
    return v
}

/* 部门展示顺序：sort → id。 */
public func sortedDepartments(s: Store): Array<Department> {
    let out = ArrayList<Department>()
    for ((_k, d) in s.departments) {
        out.add(d)
    }
    let arr = out.toArray()
    sortByKey<Department>(arr, { d: Department => sortKeyClamp(d.sort) * 1000000 + d.id })
    return arr
}

/* 成员展示顺序：部门 sort → id（未分配部门排最后）。 */
public func sortedMembers(s: Store, list: ArrayList<Member>): Array<Member> {
    let arr = list.toArray()
    sortByKey<Member>(arr, { m: Member =>
        var ds: Int64 = SORT_UNASSIGNED
        match (s.departments.get(m.dept_id)) {
            case Some(d) => ds = sortKeyClamp(d.sort)
            case None => ds = SORT_UNASSIGNED
        }
        ds * 1000000 + m.id
    })
    return arr
}

/* 某成员名下**未完成**的任务——移出社团前必须先转交（api-design §3.2）。 */
public func openTasksOf(s: Store, memberId: Int64): Array<Task> {
    let out = ArrayList<Task>()
    for ((_k, t) in s.tasks) {
        if (t.deleted_at > 0 || t.owner_id != memberId || t.status == "done") {
            continue
        }
        out.add(t)
    }
    let arr = out.toArray()
    sortByKey<Task>(arr, { t: Task => t.id })
    return arr
}

/* 部门下还有多少"没退出"的成员（删除部门的前置检查）。 */
public func activeMemberCountOfDept(s: Store, deptId: Int64): Int64 {
    var n: Int64 = 0
    for ((_k, m) in s.members) {
        if (m.dept_id == deptId && m.status != "disabled") {
            n += 1
        }
    }
    return n
}

/* 部门下还有多少顶层课题（Plan.dept_id 只存在顶层，见 v1-scope 规则 19）。 */
public func topPlanCountOfDept(s: Store, deptId: Int64): Int64 {
    var n: Int64 = 0
    for ((_k, p) in s.plans) {
        if (p.parent_id == 0 && p.dept_id == deptId) {
            n += 1
        }
    }
    return n
}

/* 部门重名检查（改名与新建共用）。 */
public func deptNameTaken(s: Store, name: String, exceptId: Int64): Bool {
    for ((_k, d) in s.departments) {
        if (d.id != exceptId && d.name == name) {
            return true
        }
    }
    return false
}

/* ===================== 任务辅助（Part 4） ===================== */

/* 状态只有 4 档（v1-scope 规则 2：不做进度百分比）。 */
public func isTaskStatus(st: String): Bool {
    if (st == "todo") {
        return true
    }
    if (st == "doing") {
        return true
    }
    if (st == "blocked") {
        return true
    }
    if (st == "done") {
        return true
    }
    return false
}

/*
 * 逾期是**派生量**（规则 15），由 due_at 与当前时间算出，永不落盘。
 * 已完成的任务不再标逾期——"做完了"这个事实优先于"当时晚了"。
 */
public func isTaskOverdue(t: Task, now: Int64): Bool {
    if (t.status == "done") {
        return false
    }
    return isOverdue(t.due_at, now)
}

/* 按截止时间升序；无截止的排最后（api-design §4.1）。 */
public func sortedTasksByDue(list: ArrayList<Task>): Array<Task> {
    let arr = list.toArray()
    sortTasksByDue(arr)
    return arr
}

/*
 * 任务排序不能再把“无截止”编码成一个有限的时间哨兵：合法的 ISO 年份
 * 可以远大于 2255，任何固定的时间常量都可能被真实 due_at 越过。
 * 直接比较分组和字段，既保持 no_due 最后，也避免时间乘法溢出。
 */
func taskDueBefore(a: Task, b: Task): Bool {
    let aHasDue = a.due_at > 0
    let bHasDue = b.due_at > 0
    if (aHasDue != bHasDue) {
        return aHasDue
    }
    if (aHasDue && a.due_at != b.due_at) {
        return a.due_at < b.due_at
    }
    return a.id < b.id
}

func siftDownTasksDue(arr: Array<Task>, root0: Int64, end: Int64): Unit {
    var root = root0
    var go = true
    while (go) {
        let left = root * 2 + 1
        if (left >= end) {
            go = false
        } else {
            var pick = left
            let right = left + 1
            if (right < end && taskDueBefore(arr[left], arr[right])) {
                pick = right
            }
            if (taskDueBefore(arr[root], arr[pick])) {
                let tmp = arr[root]
                arr[root] = arr[pick]
                arr[pick] = tmp
                root = pick
            } else {
                go = false
            }
        }
    }
}

func sortTasksByDue(arr: Array<Task>): Unit {
    let n = arr.size
    if (n < 2) {
        return
    }
    var i = n / 2 - 1
    while (i >= 0) {
        siftDownTasksDue(arr, i, n)
        i -= 1
    }
    var end = n - 1
    while (end > 0) {
        let tmp = arr[0]
        arr[0] = arr[end]
        arr[end] = tmp
        siftDownTasksDue(arr, 0, end)
        end -= 1
    }
}

/*
 * 课题子树的所有 id（含自身）。
 * `GET /tasks?plan_id=` 默认包含整棵子树——多级课题下，
 * 按父课题筛选却只看到本级任务，是不符合直觉的。
 */
public func planSubtreeIds(s: Store, rootId: Int64): HashSet<Int64> {
    let out = HashSet<Int64>()
    let queue = ArrayList<Int64>()
    queue.add(rootId)
    out.add(rootId)
    var i: Int64 = 0
    while (i < queue.size) {
        let cur = queue[i]
        i += 1
        for ((_k, p) in s.plans) {
            if (p.parent_id == cur && !out.contains(p.id)) {
                out.add(p.id)
                queue.add(p.id)
            }
        }
    }
    return out
}

/* ===================== 幂等（api-design §1.9） ===================== */

public let IDEM_TTL: Int64 = 86400

/*
 * 幂等键必须带上提交者本人（P0 H-2）。
 * 原先只按 kind + token 索引：甲用 client_token 建了资源，乙拿同一个 token 重放，
 * 就会被当成「甲的重复提交」，直接把甲的资源读回去——一个绕过权限判定的越权读。
 * 带上 actorId 后，乙的 token 匹配不到任何记录，走正常创建流程，该 403 还是 403。
 */
func idemKey(kind: String, actorId: Int64, token: String): String {
    return "${kind}:${actorId}:${token}"
}

/* 24 小时内命中则返回首次创建的资源 id。 */
public func idemHit(s: Store, kind: String, actorId: Int64, token: String, now: Int64): ?Int64 {
    let k = idemKey(kind, actorId, token)
    match (s.idem.get(k)) {
        case Some(rec) =>
            if (now - rec.created_at <= IDEM_TTL) {
                return Some(rec.resource_id)
            }
            s.idem.remove(k)
            return None
        case None => return None
    }
}

public func idemPut(s: Store, kind: String, actorId: Int64, token: String, resourceId: Int64, now: Int64): Unit {
    let rec = IdemRecord()
    rec.resource_id = resourceId
    rec.created_at = now
    s.idem[idemKey(kind, actorId, token)] = rec
    /* 顺带清理过期项，避免这张表无限增长 */
    if (s.idem.size > 200) {
        let doomed = ArrayList<String>()
        for ((k, r) in s.idem) {
            if (now - r.created_at > IDEM_TTL) {
                doomed.add(k)
            }
        }
        for (k in doomed) {
            s.idem.remove(k)
        }
    }
}

/* ===================== 课题辅助（Part 5） ===================== */

/* 深度硬上限 6 层（v1-scope 规则 18）。上限的意义是防呆，不是限制表达。 */
public let PLAN_MAX_DEPTH: Int64 = 6

/* 脏数据保护用的遍历上限，远大于任何合法深度。 */
let PLAN_WALK_GUARD: Int64 = 64

/*
 * 从 planId 向上走到根课题（顶层 parent_id == 0）。
 * 带 guard：万一数据里有环，读取路径也不能死循环。
 */
public func planRootOf(s: Store, planId: Int64): Int64 {
    var cur = planId
    var guard: Int64 = 0
    while (cur > 0 && guard < PLAN_WALK_GUARD) {
        match (s.plans.get(cur)) {
            case Some(p) =>
                if (p.parent_id <= 0) {
                    return cur
                }
                cur = p.parent_id
            case None => return cur
        }
        guard += 1
    }
    return cur
}

/*
 * 课题的**有效部门**：顶层课题存 dept_id，子课题的部门由所属根决定。
 * 这正是「子课题不允许跨部门」自动成立、移动时也不需要级联更新部门的原因（规则 19）。
 */
public func planDeptOf(s: Store, planId: Int64): Int64 {
    let root = planRootOf(s, planId)
    match (s.plans.get(root)) {
        case Some(p) => return p.dept_id
        case None => return 0
    }
}

/*
 * ===== 部门一致性判定（N-18 口径）=====
 * 2026-09-18：这两个判定由 h_plan.cj / h_task.cj **移入本文件**（Haocheng Sun）。
 * 理由：它们与 planDeptOf / planRootOf / planWouldCycle 一样属于"课题树辅助"，
 * store.cj 的职责本来就是"查询 / 排序 / 课题树辅助"；放一起可避免两侧各写一遍而漂移
 * （h_task.cj 原先就把同一条判定在创建与转交两处各内联写了一遍）。
 */

/*
 * 课题负责人的部门一致性（原在 h_plan.cj）。
 *
 * 为什么必须有：perms 给课题负责人留了一条"我是负责人就放行 EditPlan"的例外。
 * 于是"把负责人填成别的部门的人"= **把本部门课题的写权限送给别的部门**
 * （对方随即能改这个课题的标题 / 截止 / 负责人）。任务侧堵住了这个口子，课题侧原先没有。
 *
 * 部门的"有效值"是根课题的部门（规则 19：子课题不存 dept_id），所以两个调用点都传
 * `planDeptOf(...)`。
 *
 * 例外：会长 / 副会长 / 运维本来就不受部门范围限制 —— 判定仍**只写在 perms.cj**
 * （`bypassesDeptScope(role)`），由调用方算好后经 `bypassScope` 传进来。
 * ⚠ 为什么参数要这么设计：本文件被**运维台那条构建**一起编译（`build.ps1 -Target admin`
 *   只取 store/audit/timex/strx 四个文件 + ops 目录下的入口），而 `perms.cj` 不在那条构建里。
 *   若这里直接调 `bypassesDeptScope`，运维台会以
 *   `error: undeclared identifier 'bypassesDeptScope'` 编译失败（2026-09-18 实测踩到）。
 *   顺带这也守住了"权限判定只有一处"的纪律：本文件只做算法，不复制权限规则。
 *   （写注释时注意：本文件里不要出现斜杠加星号的字面串，仓颉的块注释可嵌套，会变成未闭合注释。）
 * 部门为 0（历史脏数据 / 未分配）同样不拦，避免把旧库卡死。
 */
public func planOwnerDeptOk(ownerDept: Int64, deptId: Int64, bypassScope: Bool): Bool {
    if (deptId <= 0 || bypassScope) {
        return true
    }
    return ownerDept == deptId
}

/*
 * 任务与课题的部门一致性（原在 h_task.cj 内联，创建路径与编辑/转交路径各一份）。
 *
 * 独立任务（planId <= 0）不拦；课题部门为 0（脏数据）或负责人未分配部门
 * （ownerDept <= 0）也不拦；其余要求两者同部门，否则 403 FORBIDDEN_NOT_IN_DEPT。
 */
public func taskPlanDeptOk(s: Store, planId: Int64, ownerDept: Int64): Bool {
    if (planId <= 0 || ownerDept <= 0) {
        return true
    }
    let planDept = planDeptOf(s, planId)
    return planDept <= 0 || planDept == ownerDept
}

/* 层级：顶层为 1。 */
public func planDepthOf(s: Store, planId: Int64): Int64 {
    var cur = planId
    var d: Int64 = 1
    var guard: Int64 = 0
    while (cur > 0 && guard < PLAN_WALK_GUARD) {
        match (s.plans.get(cur)) {
            case Some(p) =>
                if (p.parent_id <= 0) {
                    return d
                }
                cur = p.parent_id
                d += 1
            case None => return d
        }
        guard += 1
    }
    return d
}

/* 以 planId 为根的子树高度（含自身）。带层级 guard，防脏数据成环。 */
public func planHeightOf(s: Store, planId: Int64): Int64 {
    return planHeightFrom(s, planId, 0)
}

func planHeightFrom(s: Store, planId: Int64, level: Int64): Int64 {
    if (level > PLAN_WALK_GUARD) {
        return 1
    }
    let kids = planChildrenOf(s, planId)
    if (kids.size == 0) {
        return 1
    }
    var best: Int64 = 0
    for (k in kids) {
        let h = planHeightFrom(s, k.id, level + 1)
        if (h > best) {
            best = h
        }
    }
    return best + 1
}

/* 直接子课题，按 id 升序。 */
public func planChildrenOf(s: Store, planId: Int64): Array<Plan> {
    let out = ArrayList<Plan>()
    for ((_k, p) in s.plans) {
        if (p.parent_id == planId) {
            out.add(p)
        }
    }
    let arr = out.toArray()
    sortByKey<Plan>(arr, { p: Plan => p.id })
    return arr
}

/*
 * 环形校验（api-design §5.6 的实现提示）：**从目标父节点向上遍历到根**，
 * 而不是向下扫子树——向上遍历的深度通常远小于子树规模。
 * 一旦成环，递归进度聚合会无限循环并拖垮服务，这是多级结构下最容易出的事故。
 */
public func planWouldCycle(s: Store, planId: Int64, newParentId: Int64): Bool {
    if (newParentId <= 0) {
        return false
    }
    var cur = newParentId
    var guard: Int64 = 0
    while (cur > 0 && guard < PLAN_WALK_GUARD) {
        if (cur == planId) {
            return true
        }
        match (s.plans.get(cur)) {
            case Some(p) => cur = p.parent_id
            case None => return false
        }
        guard += 1
    }
    return false
}

/* 把 rootId 及其全部后代加入 out（供可见性集合与统计用）。 */
public func planSubtreeInto(s: Store, rootId: Int64, out: HashSet<Int64>): Unit {
    let queue = ArrayList<Int64>()
    queue.add(rootId)
    out.add(rootId)
    var i: Int64 = 0
    while (i < queue.size) {
        let cur = queue[i]
        i += 1
        for ((_k, p) in s.plans) {
            if (p.parent_id == cur && !out.contains(p.id)) {
                out.add(p.id)
                queue.add(p.id)
            }
        }
    }
}

/* 一个课题的聚合统计。 */
public class PlanStats {
    public var own_total: Int64 = 0    /* 本级任务总数 */
    public var own_done: Int64 = 0     /* 本级已完成 */
    public var task_count: Int64 = 0   /* 本级任务数（对外字段） */
    public var total: Int64 = 0        /* 递归聚合：含整棵子树 */
    public var done: Int64 = 0         /* 递归聚合：含整棵子树 */
    public var child_count: Int64 = 0  /* 直接子课题数 */

    public init() {}
}

/*
 * 递归进度聚合，**自底向上一次算完，O(n)**。
 *
 * api-design §5.8 明确警告：不要对每个节点各自递归（那是 O(n^2)，课题一多就明显变慢）。
 * 做法：先按"深度从深到浅"排序，再依次把子节点的聚合值累加到父节点——
 * 处理到某个节点时，它的所有子节点必然已经算完。
 *
 * 只统计**未删除**的任务；已完成按 status == done 判定。
 */
public func planStatsAll(s: Store, ids: HashSet<Int64>): HashMap<Int64, PlanStats> {
    let stats = HashMap<Int64, PlanStats>()

    /* 1) 建表 + 直接子课题数 */
    for ((_k, p) in s.plans) {
        if (!ids.contains(p.id)) {
            continue
        }
        stats[p.id] = PlanStats()
    }
    for ((_k, p) in s.plans) {
        if (!ids.contains(p.id) || p.parent_id <= 0 || !ids.contains(p.parent_id)) {
            continue
        }
        match (stats.get(p.parent_id)) {
            case Some(parent) => parent.child_count += 1
            case None => ()
        }
    }

    /* 2) 本级任务数 */
    for ((_k, t) in s.tasks) {
        if (t.deleted_at > 0 || t.plan_id <= 0 || !ids.contains(t.plan_id)) {
            continue
        }
        match (stats.get(t.plan_id)) {
            case Some(st) =>
                st.task_count += 1
                st.own_total += 1
                if (t.status == "done") {
                    st.own_done += 1
                }
            case None => ()
        }
    }

    /* 3) 先把 total/done 初始化成**本级值** */
    for ((_k, p) in s.plans) {
        if (!ids.contains(p.id)) {
            continue
        }
        match (stats.get(p.id)) {
            case Some(st) =>
                st.total = st.own_total
                st.done = st.own_done
            case None => ()
        }
    }

    /* 4) 深度从深到浅累加到父节点。注意这里**不能**再重置 total/done，
     *    否则会把子节点刚累加进来的值覆盖回本级值（父课题进度会永远偏小）。 */
    let list = ArrayList<Plan>()
    for ((_k, p) in s.plans) {
        if (ids.contains(p.id)) {
            list.add(p)
        }
    }
    let arr = list.toArray()
    sortByKey<Plan>(arr, { p: Plan => 0 - planDepthOf(s, p.id) * 1000000 + p.id })
    for (p in arr) {
        match (stats.get(p.id)) {
            case Some(st) =>
                if (p.parent_id > 0) {
                    match (stats.get(p.parent_id)) {
                        case Some(parent) =>
                            parent.total += st.total
                            parent.done += st.done
                        case None => ()
                    }
                }
            case None => ()
        }
    }
    return stats
}

/*
 * 单个课题的聚合统计（含整棵子树）。
 *
 * 存在的理由（P1 M-1）：POST /plans 与 PATCH /plans/{id} 的响应里也带 progress，
 * 起初那里传的是 None，序列化出来就是 total=0 / done=0——一个假进度。客户端改完
 * 标题，进度条会突然归零。凡是返回 plan 对象的地方都必须用这个函数取真值。
 * 命中幂等回放时同理。
 */
public func planStatsOf(s: Store, id: Int64): ?PlanStats {
    let sub = HashSet<Int64>()
    planSubtreeInto(s, id, sub)
    return planStatsAll(s, sub).get(id)
}

/*
 * 删除课题：**直接子节点上提一级，绝不级联删除**（v1-scope 规则 9）。
 *
 *   子课题   -> parent_id = P.parent_id
 *   任务     -> plan_id   = P.parent_id
 *   P 是顶层 -> 子课题变为顶层并**继承 P 的 dept_id**（dept_id 只存顶层，这一步不能漏）
 *               任务变为独立任务（plan_id = 0）
 *
 * 为什么不做级联删除：任务承载着人的工作量记录，一次误删丢掉整棵子树
 * 是这个设计里最不可接受的失败模式。
 *
 * 返回（上提的课题数，上提的任务数）；任务数只算未删除的。
 * 抽成纯函数是为了可单测；handler 负责权限、审计与落盘。
 */
public func planDeletePromote(s: Store, id: Int64): (Int64, Int64) {
    let target = match (s.plans.get(id)) {
        case Some(x) => x
        case None => return (0, 0)
    }
    let newParent = target.parent_id
    let wasTop = (newParent <= 0)
    let inheritDept = target.dept_id
    let now = nowEpoch()
    var movedPlans: Int64 = 0
    var movedTasks: Int64 = 0

    for ((_k, c) in s.plans) {
        if (c.parent_id == id && c.id != id) {
            c.parent_id = newParent
            if (wasTop) {
                c.dept_id = inheritDept
            }
            c.updated_at = now
            movedPlans += 1
        }
    }
    for ((_k, t) in s.tasks) {
        if (t.plan_id == id) {
            t.plan_id = newParent
            t.updated_at = now
            if (t.deleted_at <= 0) {
                movedTasks += 1
            }
        }
    }
    s.plans.remove(id)
    return (movedPlans, movedTasks)
}
