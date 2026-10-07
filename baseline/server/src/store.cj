/*
 * ===== 算法归属说明（2026-09-18）=========================================
 * 本文件接收了 Haocheng Sun <2396556545@qq.com> **移入**的两个部门一致性判定：
 *   · planOwnerDeptOk()  课题负责人的部门一致性（原 h_plan.cj）
 *   · taskPlanDeptOk()   任务与课题的部门一致性（原 h_task.cj 的两处内联判定）
 * 归入本文件的理由：本文件的职责本就是"查询 / 排序 / 课题树辅助"。
 * 除此之外，本文件的其余内容非其产出。
 * =====================================================================
 */
package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * 数据模型与 JSON 字段映射。
 *
 * 为了让职责和变更范围清晰，Store 代码拆成三个同包编译单元：
 *   · store.cj：数据模型、Store 容器与 ToJson/FromJson 字段映射；
 *   · store_persistence.cj：文件后端加载、快照、落盘与 renderDb；
 *   · store_queries.cj：查询、排序、幂等与课题树辅助。
 *
 * ===== 持久化后端有两个（2026-09-20 起）=================================
 *
 * **MySQL（club-server 的默认，也是唯一在用的那条）**：见 mysql_store.cj。
 *   启动时从 7 张表全量载入内存；每次变更在**一个事务**里把各表整体替换
 *   （DELETE + 多行参数化 INSERT）。`data/db.json` 从此**不是真相来源**。
 *
 * **文件（仅在 Store.mysql == None 时生效）**：本文件下半部分那套
 *   "内存 Store + 写时原子落盘 JSON" ——
 *     · `club-server test` 的单测直接构造内存 Store 断言它（507 条，语义不变）；
 *     · `build.ps1 -Target admin` 的运维台只读社团库，也编译本文件。
 *   保留它**不是为了回退**，而是因为单测的绝大部分（落盘 / 加载 / 序号守卫 /
 *   坏库拒绝启动）就是对着这套语义写的；路线 B 的要求正是"它们一条都不用改"。
 *
 * 文件后端的设计（原 v1-scope §8）：
 *   · 单一快照文件 data/db.json，保证跨表一致（不会出现"任务存了、索引没存"）
 *   · 原子写：先写 db.json.tmp，再把旧文件备份成 db.json.bak，最后 rename 覆盖
 *   · 解析失败**绝不静默降级为空库**——那会在下一次保存时把真实数据覆盖掉。
 *     启动时宁可报错退出，让人去修文件。
 * MySQL 后端把上面三条**逐条对等**搬过去：一个事务 = 跨表一致；异常 = 拒绝启动
 * （见 mysql_store.cj 的 storeLoadDb / writeDbToMysql）。
 *
 * 并发：stdx 服务器可能并发处理请求，所有对 Store 的读写都在 store.lock 下进行。
 * Mutex 不可重入，因此 handler 只在最外层加一次锁。
 *
 * 空值约定：Int64 用 0 表示"无"。parent_id=0 顶层课题、plan_id=0 独立任务、
 * dept_id=0 未分配、时间字段 0 表示 null。1970 年不会成为真实业务值。
 */

import std.collection.*
import std.sync.*
import stdx.encoding.json.*

/* ===================== 数据模型（v1-scope §5） ===================== */

public class Department {
    public var id: Int64 = 0
    public var name: String = ""
    public var sort: Int64 = 0
}

public class Member {
    public var id: Int64 = 0
    public var name: String = ""
    public var phone: String = ""
    /* 口令：算法/迭代次数/盐/摘要分开存，避免解析复合字符串 */
    public var pw_algo: String = "pbkdf2-sha256"
    public var pw_iter: Int64 = 0
    public var pw_salt: String = ""
    public var pw_hash: String = ""
    public var role: String = ""          /* pending 时为空 */
    public var dept_id: Int64 = 0         /* pending 时为 0 */
    public var dept_hint: Int64 = 0       /* 招募链接带来的部门预填，仅提示用 */
    public var status: String = "pending" /* pending / active / disabled */
    public var joined_at: Int64 = 0
}

public class Plan {
    public var id: Int64 = 0
    public var title: String = ""
    public var desc: String = ""
    public var parent_id: Int64 = 0       /* 0 = 顶层课题 */
    public var owner_id: Int64 = 0        /* 必填，任意层级都要有 */
    public var dept_id: Int64 = 0         /* 仅顶层有值（v1-scope 规则 19） */
    public var due_at: Int64 = 0
    public var created_by: Int64 = 0
    public var created_at: Int64 = 0
    public var updated_at: Int64 = 0
}

public class Task {
    public var id: Int64 = 0
    public var title: String = ""
    public var desc: String = ""
    public var owner_id: Int64 = 0        /* 必填且唯一（规则 1） */
    public var plan_id: Int64 = 0
    public var dept_id: Int64 = 0
    public var status: String = "todo"    /* todo / doing / blocked / done */
    public var blocker: String = ""
    /*
     * 「需要帮助」的求助对象（D-4，2026-09-16）。
     *
     * 设计规格 P03 的阻塞块里有一行「需要帮助 · 宣传部 陈屿」——求助指向
     * **某个部门**（必填其一），可以具体到**某个人**。只在 status = blocked 时有意义：
     * 离开 blocked 时与 blocker 一起清空（同一个信息块，不该留下半截状态）。
     *
     * help_dept_id 允许由 help_member_id 推导（只填人时按该成员所在部门补齐），
     * 这样「部长首页看本部门被求助项」永远只需要比一个字段。
     */
    public var help_dept_id: Int64 = 0   /* 0 = 未指定求助部门 */
    public var help_member_id: Int64 = 0 /* 0 = 只到部门，不指定到人 */
    public var due_at: Int64 = 0
    public var updated_at: Int64 = 0
    public var completed_at: Int64 = 0
    public var deleted_at: Int64 = 0      /* 软删除（规则 17） */
    public var source: String = ""
    public var created_by: Int64 = 0
    public var created_at: Int64 = 0
}

public class DeptInviteLink {
    public var token: String = ""
    public var dept_id: Int64 = 0
    public var enabled: Bool = true
    public var created_by: Int64 = 0
    public var created_at: Int64 = 0
}

public class TokenRecord {
    public var member_id: Int64 = 0
    public var created_at: Int64 = 0
    public var expires_at: Int64 = 0
}

public class IdemRecord {
    public var resource_id: Int64 = 0
    public var created_at: Int64 = 0
    /*
     * P2（2026-10-06）：给 `idem` 加两列，用来存 **AI 写操作提议**。
     *
     * 为什么复用这张表：提议需要的正是「一次性 + 按 (kind, actor, token) 定位 + 带时间戳」，
     * 与幂等记录同构。两种记录靠 `kind` 区分：`ai_prop` = 提议，其余 = 既有幂等。
     *
     * ⚠ 幂等记录这两个字段恒为空/0 —— 既有的幂等行为**完全不变**。
     */
    public var payload: String = ""   /* 提议 JSON：{tool, args, action}；幂等记录为空 */
    public var used_at: Int64 = 0     /* 0 = 未消费；>0 = 已消费（幂等回放） */
}

public class LoginFail {
    public var count: Int64 = 0
    public var first_at: Int64 = 0
    public var locked_until: Int64 = 0
}

/*
 * 注册口令的失败状态（N-6）。**按客户端 IP 各存一份**，不再是一个全局计数。
 * lock_level 记录"这个 IP 已经被锁过几次"，锁定时长按它翻倍（递增退避）。
 */
public class RegFail {
    public var count: Int64 = 0
    public var first_at: Int64 = 0
    public var locked_until: Int64 = 0
    public var lock_level: Int64 = 0
}

/* ===================== Store ===================== */

public class Store {
    public let dir: String
    public let lock: Mutex = Mutex()

    /*
     * ===== 持久化后端（2026-09-20，路线 B）=================================
     *
     * `None`  = **文件后端**：内存 Store + 写时原子落盘 JSON（本文件下半部分那套）。
     *           `club-server test` 的单测、以及 `build.ps1 -Target admin`（运维台
     *           只读社团库，它可以连着 club-server 的库读）走的就是这条。
     * `Some` = **MySQL 后端**：启动时由 mysql_store.cj 的 storeLoadDb 从库里全量载入，
     *           落盘时把内存快照在**一个事务**里写回库（见 writeDbToMysql）。
     *
     * 为什么做成 Store 上的一个字段（而不是换掉 Store 或另造一个类型）：
     *   路线 B 的全部承诺就是"内存模型与业务逻辑一行不动"。把后端挂在 Store 上，
     *   所有 218 处 `s.<表>` 访问、64 个派生辅助函数、51 处 `s.lock.lock()`
     *   全都不需要知道自己脚下是文件还是数据库 —— 它们本来就只跟内存打交道。
     *   唯一需要知道后端的是**落盘那几个函数**（storeSnapshot / writeSnapshot）。
     */
    public var mysql: ?MysqlStore = None

    /*
     * 上一次**成功落盘**的状态（MySQL 后端专用的增量基准）。
     *
     * 为什么要它：club-server 的写入是"请求链末端把整库刷出去"。若每次都重写全部行，
     * 代价就随库的大小走（实测 1000 成员 + 1000 任务时建一个任务要 1.5 秒）。
     * 有了这份基准，落盘只写"这一轮真正变了的东西"（见 writeDbToMysql），
     * 单次写入代价回到 O(本次改动量)，**语义仍是"一个事务、提交后才响应"**。
     *
     * None = 还没落过盘（首次写会按"全库都是新的"处理）。
     * 它只在 save_lock 内被读写（writeDbToMysql 的收尾），不需要额外加锁。
     */
    public var persisted: ?PersistedState = None

    /*
     * 动作 4（2026-09-15）：写盘专用锁。与 lock 分开，否则**整库磁盘 IO** 会占住全局锁。
     * 加锁顺序恒为 `lock → save_lock`（先取全局锁改内存/取快照，解锁后再取 save_lock 写盘），
     * 不存在反向获取，因此不会死锁。
     */
    public let save_lock: Mutex = Mutex()
    /* 提交序号（在 lock 内自增）与已落盘序号（在 save_lock 内更新）：并发写盘收敛到最新快照 */
    public var seq: Int64 = 0
    public var saved_seq: Int64 = 0
    /* 待落盘快照：storeSave 在锁内挂上，snapshotFlush 中间件在解锁后写出去（见 flushPending） */
    public var pending: ?Snapshot = None

    public var departments: HashMap<Int64, Department> = HashMap<Int64, Department>()
    public var members: HashMap<Int64, Member> = HashMap<Int64, Member>()
    public var plans: HashMap<Int64, Plan> = HashMap<Int64, Plan>()
    public var tasks: HashMap<Int64, Task> = HashMap<Int64, Task>()
    public var invite_links: HashMap<String, DeptInviteLink> = HashMap<String, DeptInviteLink>()
    public var tokens: HashMap<String, TokenRecord> = HashMap<String, TokenRecord>()
    public var idem: HashMap<String, IdemRecord> = HashMap<String, IdemRecord>()

    /*
     * login_fail / reg_fail_* 是**短时效限流状态，只存在内存里，不落盘**
     * （P1 M-3）。理由：失败是高频路径，每失败一次就整库原子写一次，
     * 等于给攻击者一个"发一个 401 换 18 MB 磁盘写"的放大杠杆。
     * 重启后计数清零可以接受 —— 攻击者没有让服务重启的手段。
     */
    public var login_fail: HashMap<String, LoginFail> = HashMap<String, LoginFail>()
    /* N-6：注册口令节流从"一个全局计数"改成**按客户端 IP**（key = IP，不含端口）。
     * 拿不到对端地址时 key 为空串，退化为全局锁——总比完全不锁好。 */
    public var reg_fail: HashMap<String, RegFail> = HashMap<String, RegFail>()

    /*
     * PBKDF2 的**并发闸门**（N-21，2026-09-18 起它是应用层唯一的减载手段）。
     * N-16 之后未认证请求也要跑一次等价 PBKDF2（实测 ~525 ms CPU），
     * 24 核下 ~46 并发即可打满整机 —— 而登录是不需要认证的。
     *
     * 为什么只有这一道：**应用层不做按来源的限流**（2026-09-18 决定）。
     * 按 IP 的登录节流对分布式无效、在 NAT/校园网出口下还会误伤整个社团，
     * 而"谁在打、打多大"属于网络/流量层的事（云清洗、WAF、网关限速）。
     * 应用层只保留一道**与来源无关**的上限：同时计算的 PBKDF2 有上限，
     * 超出直接拒绝（429），**不排队**（排队只会把"整机无响应"换成
     * "请求堆积 + 更长的无响应"）。这一道不是抗 DDoS，是**降级**：
     * 宁可让部分登录立刻失败，也不让整机被 8 个以上的 PBKDF2 拖垮。
     */
    public var pbkdf2_lock: Mutex = Mutex()
    public var pbkdf2_inflight: Int64 = 0

    /*
     * N-17：待写审计行（**只存在内存里，不落盘**）。
     * audit() 是在锁内被调用的，那时不能做文件 IO —— 与动作 4 确立的
     * "锁内只准备数据、IO 放锁外"同一口径。真正的 append 由请求链末端的
     * snapshotFlush 中间件（解锁后）调用 auditWrite 完成。
     */
    public var audit_pending: ArrayList<String> = ArrayList<String>()

    public var next_dept: Int64 = 1
    public var next_member: Int64 = 1
    public var next_plan: Int64 = 1
    public var next_task: Int64 = 1

    /* 注册配置（全局单例）：口令存明文，仅会长/副会长可读（v1-scope §5） */
    public var register_code: String = ""
    public var register_code_by: Int64 = 0
    public var register_code_at: Int64 = 0

    public init(dir: String) {
        this.dir = dir
    }

    public func dbFile(): String {
        return "${dir}/db.json"
    }
}

/* ===================== 序列化 ===================== */

func deptToJson(d: Department): JsonObject {
    let o = JsonObject()
    jPutInt(o, "id", d.id)
    jPutStr(o, "name", d.name)
    jPutInt(o, "sort", d.sort)
    return o
}

func deptFromJson(o: JsonObject): Department {
    let d = Department()
    d.id = reqIntOr(o, "id", 0)
    d.name = reqStrOr(o, "name", "")
    d.sort = reqIntOr(o, "sort", 0)
    return d
}

func memberToJson(m: Member): JsonObject {
    let o = JsonObject()
    jPutInt(o, "id", m.id)
    jPutStr(o, "name", m.name)
    jPutStr(o, "phone", m.phone)
    jPutStr(o, "pw_algo", m.pw_algo)
    jPutInt(o, "pw_iter", m.pw_iter)
    jPutStr(o, "pw_salt", m.pw_salt)
    jPutStr(o, "pw_hash", m.pw_hash)
    jPutStr(o, "role", m.role)
    jPutInt(o, "dept_id", m.dept_id)
    jPutInt(o, "dept_hint", m.dept_hint)
    jPutStr(o, "status", m.status)
    jPutInt(o, "joined_at", m.joined_at)
    return o
}

func memberFromJson(o: JsonObject): Member {
    let m = Member()
    m.id = reqIntOr(o, "id", 0)
    m.name = reqStrOr(o, "name", "")
    m.phone = reqStrOr(o, "phone", "")
    m.pw_algo = reqStrOr(o, "pw_algo", "pbkdf2-sha256")
    m.pw_iter = reqIntOr(o, "pw_iter", 0)
    m.pw_salt = reqStrOr(o, "pw_salt", "")
    m.pw_hash = reqStrOr(o, "pw_hash", "")
    m.role = reqStrOr(o, "role", "")
    m.dept_id = reqIntOr(o, "dept_id", 0)
    m.dept_hint = reqIntOr(o, "dept_hint", 0)
    m.status = reqStrOr(o, "status", "pending")
    m.joined_at = reqIntOr(o, "joined_at", 0)
    return m
}

func planToJson(p: Plan): JsonObject {
    let o = JsonObject()
    jPutInt(o, "id", p.id)
    jPutStr(o, "title", p.title)
    jPutStr(o, "desc", p.desc)
    jPutInt(o, "parent_id", p.parent_id)
    jPutInt(o, "owner_id", p.owner_id)
    jPutInt(o, "dept_id", p.dept_id)
    jPutInt(o, "due_at", p.due_at)
    jPutInt(o, "created_by", p.created_by)
    jPutInt(o, "created_at", p.created_at)
    jPutInt(o, "updated_at", p.updated_at)
    return o
}

func planFromJson(o: JsonObject): Plan {
    let p = Plan()
    p.id = reqIntOr(o, "id", 0)
    p.title = reqStrOr(o, "title", "")
    p.desc = reqStrOr(o, "desc", "")
    p.parent_id = reqIntOr(o, "parent_id", 0)
    p.owner_id = reqIntOr(o, "owner_id", 0)
    p.dept_id = reqIntOr(o, "dept_id", 0)
    p.due_at = reqIntOr(o, "due_at", 0)
    p.created_by = reqIntOr(o, "created_by", 0)
    p.created_at = reqIntOr(o, "created_at", 0)
    p.updated_at = reqIntOr(o, "updated_at", 0)
    return p
}

func taskToJson(t: Task): JsonObject {
    let o = JsonObject()
    jPutInt(o, "id", t.id)
    jPutStr(o, "title", t.title)
    jPutStr(o, "desc", t.desc)
    jPutInt(o, "owner_id", t.owner_id)
    jPutInt(o, "plan_id", t.plan_id)
    jPutInt(o, "dept_id", t.dept_id)
    jPutStr(o, "status", t.status)
    jPutStr(o, "blocker", t.blocker)
    jPutInt(o, "help_dept_id", t.help_dept_id)
    jPutInt(o, "help_member_id", t.help_member_id)
    jPutInt(o, "due_at", t.due_at)
    jPutInt(o, "updated_at", t.updated_at)
    jPutInt(o, "completed_at", t.completed_at)
    jPutInt(o, "deleted_at", t.deleted_at)
    jPutStr(o, "source", t.source)
    jPutInt(o, "created_by", t.created_by)
    jPutInt(o, "created_at", t.created_at)
    return o
}

func taskFromJson(o: JsonObject): Task {
    let t = Task()
    t.id = reqIntOr(o, "id", 0)
    t.title = reqStrOr(o, "title", "")
    t.desc = reqStrOr(o, "desc", "")
    t.owner_id = reqIntOr(o, "owner_id", 0)
    t.plan_id = reqIntOr(o, "plan_id", 0)
    t.dept_id = reqIntOr(o, "dept_id", 0)
    t.status = reqStrOr(o, "status", "todo")
    t.blocker = reqStrOr(o, "blocker", "")
    /* D-4：老库没有这两个字段 → reqIntOr 取默认 0，无需迁移 */
    t.help_dept_id = reqIntOr(o, "help_dept_id", 0)
    t.help_member_id = reqIntOr(o, "help_member_id", 0)
    t.due_at = reqIntOr(o, "due_at", 0)
    t.updated_at = reqIntOr(o, "updated_at", 0)
    t.completed_at = reqIntOr(o, "completed_at", 0)
    t.deleted_at = reqIntOr(o, "deleted_at", 0)
    t.source = reqStrOr(o, "source", "")
    t.created_by = reqIntOr(o, "created_by", 0)
    t.created_at = reqIntOr(o, "created_at", 0)
    return t
}

func linkToJson(l: DeptInviteLink): JsonObject {
    let o = JsonObject()
    jPutStr(o, "token", l.token)
    jPutInt(o, "dept_id", l.dept_id)
    jPutBool(o, "enabled", l.enabled)
    jPutInt(o, "created_by", l.created_by)
    jPutInt(o, "created_at", l.created_at)
    return o
}

func linkFromJson(o: JsonObject): DeptInviteLink {
    let l = DeptInviteLink()
    l.token = reqStrOr(o, "token", "")
    l.dept_id = reqIntOr(o, "dept_id", 0)
    l.enabled = reqBoolOr(o, "enabled", true)
    l.created_by = reqIntOr(o, "created_by", 0)
    l.created_at = reqIntOr(o, "created_at", 0)
    return l
}

func tokenToJson(t: TokenRecord): JsonObject {
    let o = JsonObject()
    jPutInt(o, "member_id", t.member_id)
    jPutInt(o, "created_at", t.created_at)
    jPutInt(o, "expires_at", t.expires_at)
    return o
}

func tokenFromJson(o: JsonObject): TokenRecord {
    let t = TokenRecord()
    t.member_id = reqIntOr(o, "member_id", 0)
    t.created_at = reqIntOr(o, "created_at", 0)
    t.expires_at = reqIntOr(o, "expires_at", 0)
    return t
}

func idemToJson(k: String, r: IdemRecord): JsonObject {
    let o = JsonObject()
    jPutStr(o, "key", k)
    jPutInt(o, "resource_id", r.resource_id)
    jPutInt(o, "created_at", r.created_at)
    jPutStr(o, "payload", r.payload)
    jPutInt(o, "used_at", r.used_at)
    return o
}
