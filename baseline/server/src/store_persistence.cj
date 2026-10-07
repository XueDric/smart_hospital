package qingzhou

/*
 * 社团管理工具 · Store 文件后端的加载、快照与落盘实现。
 * 数据模型与 JSON 字段映射见 store.cj；查询与课题树算法见 store_queries.cj。
 */

import std.collection.*
import std.fs.*
import stdx.encoding.json.*

/* ===================== 加载 / 保存 ===================== */

public func storeLoad(dir: String): Store {
    let s = Store(dir)
    let file = s.dbFile()
    if (!exists(file)) {
        return s
    }
    let text = String.fromUtf8(File.readFrom(file))
    var root: ?JsonObject = None
    try {
        root = Some(JsonValue.fromStr(text).asObject())
    } catch (e: Exception) {
        root = None
    }
    match (root) {
        case Some(r) =>
            s.next_dept = reqIntOr(r, "next_dept", 1)
            s.next_member = reqIntOr(r, "next_member", 1)
            s.next_plan = reqIntOr(r, "next_plan", 1)
            s.next_task = reqIntOr(r, "next_task", 1)
            s.register_code = reqStrOr(r, "register_code", "")
            s.register_code_by = reqIntOr(r, "register_code_by", 0)
            s.register_code_at = reqIntOr(r, "register_code_at", 0)
            /* 每条记录解析完都对一次总数（P1 M-7），见 checkLoaded */
            let deptArr = arrOf(r, "departments")
            s.departments = deptArrFromJson(r, "departments")
            checkLoaded("departments", deptArr, s.departments.size, file)
            let memberArr = arrOf(r, "members")
            s.members = memberArrFromJson(r, "members")
            checkLoaded("members", memberArr, s.members.size, file)
            let planArr = arrOf(r, "plans")
            s.plans = planArrFromJson(r, "plans")
            checkLoaded("plans", planArr, s.plans.size, file)
            let taskArr = arrOf(r, "tasks")
            s.tasks = taskArrFromJson(r, "tasks")
            checkLoaded("tasks", taskArr, s.tasks.size, file)
            let linkArr = arrOf(r, "invite_links")
            s.invite_links = linkArrFromJson(r, "invite_links")
            checkLoaded("invite_links", linkArr, s.invite_links.size, file)
            let tokenArr = arrOf(r, "tokens")
            s.tokens = tokenArrFromJson(r, "tokens")
            checkLoaded("tokens", tokenArr, s.tokens.size, file)
            /* N-5：idem 原先漏了 checkLoaded，是 8 张表里唯一的例外。
             * 它的影响确实最小（24 小时 TTL 的幂等映射，丢一条最坏是客户端重试时
             * 多建一个资源），但"例外只存在于代码里"正是后人最容易踩的坑——
             * 口径统一成一种，读代码的人就不必再猜哪张表特殊。 */
            let idemArr = arrOf(r, "idem")
            s.idem = idemArrFromJson(r, "idem")
            checkLoaded("idem", idemArr, s.idem.size, file)
            /* login_fail 不再从文件读（P1 M-3：短时效限流状态只留内存）。
             * 旧文件里的 login_fail 字段被忽略，不影响启动。 */
            return s
        case None =>
            /* 绝不静默降级为空库：下一次保存会把真实数据覆盖掉。 */
            throw Exception("数据文件无法解析，已停止启动以免覆盖数据：${file}")
    }
}

/*
 * 逐条校验：JSON 数组里有几条，就必须解析出几条（P1 M-7）。
 *
 * 原先每个元素的解析失败都被 `catch { () }` 静默吞掉：文件里 100 个任务，
 * 坏了 3 个，服务照常启动，用户看到 97 个任务——接着下一次保存就把那 3 条永久覆盖。
 * 静默丢数据比直接起不来严重得多，所以这里与"文件级解析失败"同一口径：
 * 宁可起不来，也不要带着残缺数据继续写。
 *
 * 条数不等也可能是两条记录主键相同（后者覆盖前者），这同样是文件不一致，
 * 拒绝启动也是正确的处理。
 */
func checkLoaded(label: String, arr: JsonArray, loaded: Int64, file: String): Unit {
    if (arr.size() != loaded) {
        throw Exception("数据文件 ${label} 有 ${arr.size()} 条，只解析出 ${loaded} 条（记录损坏或主键重复），已停止启动以免覆盖数据：${file}")
    }
}

/* 逐个把数组元素解析成模型；key 在 JSON 里存成数组，读时按下标遍历（JsonArray 不支持 for-in）。 */
func arrOf(o: JsonObject, key: String): JsonArray {
    match (jsonGetArray(o, key)) {
        case Some(a) => return a
        case None =>
            /*
             * 当前格式由 renderDb 写出 version=1 和全部 8 张表。
             * 某张表缺失或类型错误时必须拒绝启动，否则下一次保存会把该表
             * 静默写成空数组，覆盖真实数据。
             *
             * 没有 version 的文件是早期的最小旧库格式，保留其“缺少新表即空表”
             * 的兼容行为；但只要键实际存在且类型错误，仍然拒绝启动。
             */
            if (o.containsKey(key) || o.containsKey("version")) {
                throw Exception("数据文件 ${key} 缺失或不是数组，已停止启动以免覆盖数据")
            }
            return JsonArray()
    }
}

func deptArrFromJson(o: JsonObject, key: String): HashMap<Int64, Department> {
    let m = HashMap<Int64, Department>()
    let a = arrOf(o, key)
    var i: Int64 = 0
    let n = a.size()
    while (i < n) {
        match (a.get(i)) {
            case Some(v) =>
                try {
                    let d = deptFromJson(v.asObject())
                    m[d.id] = d
                } catch (e: Exception) {
                    ()
                }
            case None => ()
        }
        i += 1
    }
    return m
}

func memberArrFromJson(o: JsonObject, key: String): HashMap<Int64, Member> {
    let m = HashMap<Int64, Member>()
    let a = arrOf(o, key)
    var i: Int64 = 0
    let n = a.size()
    while (i < n) {
        match (a.get(i)) {
            case Some(v) =>
                try {
                    let x = memberFromJson(v.asObject())
                    m[x.id] = x
                } catch (e: Exception) {
                    ()
                }
            case None => ()
        }
        i += 1
    }
    return m
}

func planArrFromJson(o: JsonObject, key: String): HashMap<Int64, Plan> {
    let m = HashMap<Int64, Plan>()
    let a = arrOf(o, key)
    var i: Int64 = 0
    let n = a.size()
    while (i < n) {
        match (a.get(i)) {
            case Some(v) =>
                try {
                    let x = planFromJson(v.asObject())
                    m[x.id] = x
                } catch (e: Exception) {
                    ()
                }
            case None => ()
        }
        i += 1
    }
    return m
}

func taskArrFromJson(o: JsonObject, key: String): HashMap<Int64, Task> {
    let m = HashMap<Int64, Task>()
    let a = arrOf(o, key)
    var i: Int64 = 0
    let n = a.size()
    while (i < n) {
        match (a.get(i)) {
            case Some(v) =>
                try {
                    let x = taskFromJson(v.asObject())
                    m[x.id] = x
                } catch (e: Exception) {
                    ()
                }
            case None => ()
        }
        i += 1
    }
    return m
}

func linkArrFromJson(o: JsonObject, key: String): HashMap<String, DeptInviteLink> {
    let m = HashMap<String, DeptInviteLink>()
    let a = arrOf(o, key)
    var i: Int64 = 0
    let n = a.size()
    while (i < n) {
        match (a.get(i)) {
            case Some(v) =>
                try {
                    let x = linkFromJson(v.asObject())
                    /*
                     * 空 token 记录**跳过不放进 map**（2026-09-16 修，与 tokens / idem 两张表对齐）。
                     * 原先无条件 `m[x.token] = x`，于是 token 为空的记录会被塞进 `""` 键下 ——
                     * 数组条数与 map 条数一致，`checkLoaded` 看不出问题，
                     * 结果是一条**损坏记录被静默接受**（还能被 `GET /api/v1/join/` 命中）。
                     * 跳过之后两者数量不等，`checkLoaded` 会按既定口径拒绝启动 ——
                     * 这正是那三张表共同的语义："宁可起不来，也不带残缺数据继续写"。
                     */
                    if (x.token.size > 0) {
                        m[x.token] = x
                    }
                } catch (e: Exception) {
                    ()
                }
            case None => ()
        }
        i += 1
    }
    return m
}

func tokenArrFromJson(o: JsonObject, key: String): HashMap<String, TokenRecord> {
    let m = HashMap<String, TokenRecord>()
    let a = arrOf(o, key)
    var i: Int64 = 0
    let n = a.size()
    while (i < n) {
        match (a.get(i)) {
            case Some(v) =>
                try {
                    let obj = v.asObject()
                    let tok = reqStrOr(obj, "token", "")
                    if (tok.size > 0) {
                        m[tok] = tokenFromJson(obj)
                    }
                } catch (e: Exception) {
                    ()
                }
            case None => ()
        }
        i += 1
    }
    return m
}

func idemArrFromJson(o: JsonObject, key: String): HashMap<String, IdemRecord> {
    let m = HashMap<String, IdemRecord>()
    let a = arrOf(o, key)
    var i: Int64 = 0
    let n = a.size()
    while (i < n) {
        match (a.get(i)) {
            case Some(v) =>
                try {
                    let obj = v.asObject()
                    let k = reqStrOr(obj, "key", "")
                    let r = IdemRecord()
                    r.resource_id = reqIntOr(obj, "resource_id", 0)
                    r.created_at = reqIntOr(obj, "created_at", 0)
                    r.payload = reqStrOr(obj, "payload", "")
                    r.used_at = reqIntOr(obj, "used_at", 0)
                    if (k.size > 0) {
                        m[k] = r
                    }
                } catch (e: Exception) {
                    ()
                }
            case None => ()
        }
        i += 1
    }
    return m
}

/* ===================== 落盘：序列化在锁内、写盘在锁外（动作 4） ===================== */

/*
 * 一次变更的快照。
 *   · `text`     = 完整 db.json 内容（**仅文件后端**；MySQL 后端留空，见 storeSnapshot）
 *   · `entities` = 锁内取好的**值语义拷贝**（**仅 MySQL 后端**；文件后端为 None）
 *   · `seq`      = 提交序号（两种后端都用，序号守卫靠它）
 */
public class Snapshot {
    public var text: String = ""
    public var entities: ?PersistedState = None
    public var seq: Int64 = 0

    public init() {}
}

/*
 * 在**锁内**取一致快照：把当前 Store 渲染成 db.json 内容，并自增提交序号。
 * ⚠ 调用方必须已持 `s.lock`，否则快照可能跨表不一致（"任务存了、别的没存"）。
 *
 * 为什么把 storeSave 拆成两步（2026-09-15，容量基准的动作 4）：
 *   原先 storeSave 在全局锁里做**整库磁盘 IO** —— 写 .tmp、把旧文件复制成 .bak、
 *   rename，合计约 **3 倍文件大小**的 IO。实测：1000 人 2.51 MB → 单次写占锁 56 ms；
 *   3000 人 7.55 MB → 124 ms，而这段时间**所有请求都在排队**。
 *   现在只有"序列化"留在锁内（几毫秒到十几毫秒），IO 挪到锁外由 save_lock 串行。
 *   （MySQL 后端下连"序列化"都不做，见上。这两组数字只描述**文件后端**。）
 *
 * ⚠ **引用性能数字前先看 `docs/capacity-baseline.md`**：上面这组（含本文件里那处
 *   1017 ms）来自更早的**临时脚本**，`capacity-baseline.md` §6.5 已明确宣布 1017 ms 作废、
 *   §1 给出的是 0.51 MB(1000 人) / 1.54 MB(3000 人)，§4.1 还说明排序改造"落在噪声内、
 *   不要当性能成果宣传"。这里的数字只当**当时的设计动机**看，结论一律以那份文档为准。
 *
 * 语义没有变：调用方仍然是"先 writeSnapshot、再响应"，所以
 * **响应 200 依旧代表已落盘** —— 这条强语义正是 L-7 当初把 IO 放进锁里的理由，
 * 本次只是把 IO 挪出锁，而不是放弃它。
 */
public func storeSnapshot(s: Store): Snapshot {
    let snap = Snapshot()
    /*
     * MySQL 后端**不在这里渲染整库文本**（2026-09-20）：
     *   · 库里没有"整库文本"这个东西；
     *   · 渲染一个永远不被使用的 MB 级字符串，是把"锁内开销"这条老问题又请回来
     *     （上面那段"为什么把 storeSave 拆成两步"讲的就是它）。
     * 但**要在锁内取一份值语义拷贝**（2026-10-04，S-2）：
     *   落盘路径（writeSnapshot → writeDbToMysql）只持 `save_lock`、**不持** `s.lock`；
     *   若到那时才现读内存表，就会与持 `s.lock` 的 handler 并发遍历同一批 `HashMap`
     *   （`HashMap` 非线程安全）—— 后果不只是 UB：撕裂出来的一行会被 REPLACE 回库、
     *   并被记成新的"已落盘基准"，之后不再有写入去纠正它，等于把不一致持久化下来。
     *   所以拷贝在这里做完（O(表大小) 的**纯内存**拷贝，与文件后端的 renderDb 同构），
     *   落盘侧只消费这份拷贝。见 docs/mysql-backend.md §12.11。
     * ⚠ writeSnapshot 里那个 `text.size == 0 → return` 的短路必须排在 MySQL 分支**之后**，
     *   否则 MySQL 路径会被它整个吃掉、一次都不落盘。
     */
    if (s.mysql.isNone()) {
        snap.text = renderDb(s)
    } else {
        snap.entities = Some(snapshotOf(s))
    }
    s.seq += 1
    snap.seq = s.seq
    return snap
}

/*
 * 在**锁外**写盘。并发写盘由 s.save_lock 串行，序号守卫保证"新快照不会被旧快照覆盖"：
 *   A(seq5) 与 B(seq6) 并发，无论谁先拿到 save_lock 都收敛到 seq6 ——
 *   A 先写(5)、B 后写(6) ✓；B 先写(6)、A 发现 5 <= saved_seq 直接跳过 ✓
 *   （seq6 的快照是在 s.lock 内取的，必然已包含 A 的变更，跳过不会丢数据）
 *   → 而且两者都会在返回前看到"磁盘上已有不低于自己的版本"，与 storeSave 的旧语义等价。
 */
public func writeSnapshot(s: Store, snap: Snapshot): Unit {
    /*
     * MySQL 后端：写 `snap.entities` 那份**锁内取好的拷贝**（writeDbToMysql 内部自己开事务），
     * **不看 snap.text**（它按设计是空的，见 storeSnapshot 的注释），
     * 也**绝不再现读内存表**（S-2，见 writeDbToMysql 的注释）。
     * 序号守卫照旧：旧快照不会覆盖新快照。
     *
     * 事务提交发生在这里、而本函数由请求链末端的 snapshotFlush 在 ctx.commit() 之前调用，
     * 所以「响应 200 ⇒ 数据已在库里」这条强语义保住了（与文件后端逐字同构）。
     */
    if (s.mysql.isSome()) {
        s.save_lock.lock()
        try {
            if (snap.seq <= s.saved_seq) {
                return
            }
            /* 兜底：手工构造的 Snapshot（单测自造）没有 entities，只能现取一份。
             * ⚠ 请求链上的快照**一定**带 entities（storeSnapshot 在 `s.lock` 内填好），
             *   所以这条分支不会出现在请求路径上。 */
            let cur: PersistedState = match (snap.entities) {
                case Some(x) => x
                case None => snapshotOf(s)
            }
            writeDbToMysql(s, cur)
            s.saved_seq = snap.seq
        } finally {
            s.save_lock.unlock()
        }
        return
    }
    if (snap.text.size == 0) {
        return
    }
    s.save_lock.lock()
    try {
        if (snap.seq <= s.saved_seq) {
            return
        }
        writeDbFile(s, snap.text)
        s.saved_seq = snap.seq
    } finally {
        s.save_lock.unlock()
    }
}

/*
 * 提交一次变更（**在锁内调用**）：把当前状态序列化成快照挂到 `s.pending`，**不碰磁盘**。
 * 真正的写盘由请求链末端的 `snapshotFlush` 中间件在**解锁之后**完成（见 flushPending）。
 *
 * 于是全局锁只承担"序列化"（几毫秒到十几毫秒），不再承担整库 IO
 * （实测 1000 人 2.51 MB 时单次写占锁 56 ms、3000 人 7.55 MB 时 124 ms）。
 * ⚠ **MySQL 后端下这段"序列化"开销不存在**：storeSnapshot 直接跳过 renderDb
 *   （库里没有整库文本），锁内只自增一个序号；DB 往返发生在 writeSnapshot 里、
 *   仍然在锁外（save_lock 之内、store.lock 之外）。
 *
 * ⚠ 语义没有降低：`snapshotFlush` 跑在 `ctx.commit()` **之前**，所以
 *   **响应 200 依旧代表数据已经写在磁盘上**（MySQL 后端下 = 事务已提交）——
 *   这正是 L-7 当初把 IO 放进锁里的理由。
 * ⚠ 若 handler 抛异常，`next()` 不会返回、pending 不落盘 —— 与改造前一致
 *   （旧代码抛异常时也执行不到 storeSave 那一行）。
 */
public func storeSave(s: Store): Unit {
    let snap = storeSnapshot(s)
    s.save_lock.lock()
    try {
        s.pending = Some(snap)
    } finally {
        s.save_lock.unlock()
    }
}

/*
 * 修改 Store 的常用写法：拿锁、执行修改、准备快照、解锁。
 *
 * 回调里只写业务修改，不再重复写一套 lock / try / finally / storeSave。
 * 回调抛错时不会准备快照，外层仍会负责解锁。
 */
public func storeMutation<T>(s: Store, body: () -> T): T {
    s.lock.lock()
    try {
        let result = body()
        storeSave(s)
        return result
    } finally {
        s.lock.unlock()
    }
}

/*
 * 同步落盘：给**不在 HTTP 请求里**的调用方用（`init-admin`、单测）。
 * 请求里的 handler 用 storeSave 即可，不要用这个（会重新把 IO 放回锁内）。
 */
public func storeSaveNow(s: Store): Unit {
    writeSnapshot(s, storeSnapshot(s))
}

/*
 * 把待落盘的东西写出去（幂等）：审计行 + 整库快照；没有待写内容时是空操作。
 *
 * 两件事都在**解锁之后**做（调用方是请求链末端的 snapshotFlush 中间件）：
 *   · 审计行（N-17）：原先在锁内 `File.appendTo`，与动作 4 的口径不一致；
 *   · 整库快照（动作 4）：见 storeSave 的注释。
 * 顺序是先审计、后快照：即便快照被序号守卫跳过，审计行也已经落地。
 */
public func flushPending(s: Store): Unit {
    /* 1) 取走待写审计行 —— 只为了搬动数组，短暂持全局锁（加锁顺序与别处一致） */
    var auditLines = ArrayList<String>()
    s.lock.lock()
    try {
        if (s.audit_pending.size > 0) {
            auditLines = s.audit_pending
            s.audit_pending = ArrayList<String>()
        }
    } finally {
        s.lock.unlock()
    }
    auditWrite(s, auditLines)

    /* 2) 取走待写快照（在 save_lock 内），再锁外写盘 */
    var take: ?Snapshot = None
    s.save_lock.lock()
    try {
        take = s.pending
        s.pending = None
    } finally {
        s.save_lock.unlock()
    }
    match (take) {
        case Some(x) =>
            try {
                writeSnapshot(s, x)
            } catch (e: Exception) {
                println("[db] ★ 落盘失败，本次变更未提交：${e.message}")
                throw e
            }
        case None => ()
    }
}

/*
 * 请求链上的刷盘中间件。**必须挂在 router 之前**：
 * 这样 `next()` 返回时 handler 已经跑完并解锁（我们的 handler 不调用 next），
 * 而整条链仍在 `ctx.commit()` 之前 —— 顺序是「改内存 → 解锁 → 写盘 → 发响应」。
 */
public func snapshotFlush(s: Store): Middleware {
    return { ctx: Context, next: () -> Unit =>
        next()
        flushPending(s)
    }
}

/* 真正的文件写入：写 .tmp → 备份旧文件 → rename 覆盖。 */
func writeDbFile(s: Store, text: String): Unit {
    /* 注意：Cangjie 的 Directory.create 在目录已存在时**照样抛异常**
     * （即使 recursive: true），必须先判断存在性，否则第二次落盘就会崩。 */
    if (!exists(s.dir)) {
        Directory.create(s.dir, recursive: true)
    }
    let tmp = s.dbFile() + ".tmp"
    File.writeTo(tmp, text.toArray())
    if (exists(s.dbFile())) {
        File.writeTo(s.dbFile() + ".bak", File.readFrom(s.dbFile()))
    }
    rename(tmp, to: s.dbFile(), overwrite: true)
}

/*
 * 把整个 Store 渲染成 db.json 的文本（不碰磁盘）。
 *
 * 2026-09-20 起它有两个用途，都**不是**持久化路径：
 *   1) 文件后端（Store.mysql == None）的落盘：writeDbFile 直接写这份文本；
 *   2) **运维台的"一键备份"**：club-server 的业务数据已经在 MySQL 里，
 *      备份改成"从内存 Store 渲染一份 JSON 快照落盘"（见 ops\admin_main.cj 的备份端点）。
 *      复用这一个函数的意义是：备份件与原来的 db.json **同格式**，
 *      并且用的是同一份 *ToJson 映射 —— 不会出现"备份里少字段"。
 */
public func renderDb(s: Store): String {
    let root = JsonObject()
    root.put("version", JsonInt(1))
    jPutInt(root, "next_dept", s.next_dept)
    jPutInt(root, "next_member", s.next_member)
    jPutInt(root, "next_plan", s.next_plan)
    jPutInt(root, "next_task", s.next_task)
    jPutStr(root, "register_code", s.register_code)
    jPutInt(root, "register_code_by", s.register_code_by)
    jPutInt(root, "register_code_at", s.register_code_at)

    let depts = JsonArray()
    for ((_k, d) in s.departments) {
        depts.add(deptToJson(d))
    }
    root.put("departments", depts)

    let members = JsonArray()
    for ((_k, m) in s.members) {
        members.add(memberToJson(m))
    }
    root.put("members", members)

    let plans = JsonArray()
    for ((_k, p) in s.plans) {
        plans.add(planToJson(p))
    }
    root.put("plans", plans)

    let tasks = JsonArray()
    for ((_k, x) in s.tasks) {
        tasks.add(taskToJson(x))
    }
    root.put("tasks", tasks)

    let links = JsonArray()
    for ((_k, l) in s.invite_links) {
        links.add(linkToJson(l))
    }
    root.put("invite_links", links)

    let toks = JsonArray()
    for ((k, t) in s.tokens) {
        let o = tokenToJson(t)
        jPutStr(o, "token", k)
        toks.add(o)
    }
    root.put("tokens", toks)

    /* login_fail / reg_fail 不落盘（P1 M-3 / N-6），见 Store 字段上的注释。 */

    let idems = JsonArray()
    for ((k, r) in s.idem) {
        idems.add(idemToJson(k, r))
    }
    root.put("idem", idems)

    return root.toString()
}
