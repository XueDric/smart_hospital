/*
 * ===== 分工标注（用于课程/项目分工归属，非功能代码） =====================
 * 主要修改者：Haocheng Sun <2396556545@qq.com>
 *   提交 f7b34aa  后端修复：P1 权限/并发缺陷 + 非数据层输入加固（含运维台 9 条）
 *   提交 8a9e11c  复核修正：8 处「自述与代码不符 / 与既有契约冲突」
 * 本人改动量：+451 / -90（git log --author 统计；标注日期 2026-09-18）
 * =====================================================================
 */
package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 运维台（admin 构建）入口
 *
 * 这一份是**我们自己的入口**，基线是上游 examples/admin.cj（轻舟快照里的后台示例），
 * 做三件事：
 *   1) 原样保留上游那套（登录 / me / dashboard / users / roles / perms / health /
 *      /admin/shutdown + 静态托管 SPA），因为上游预构建的 admin-web 前端就按这套接口写。
 *   2) 加一组「/api/club/…」运维接口：直接读社团库文件（只读），
 *      一切**写**操作由前端带**运维账号**的令牌直接打 club-server 的真实 API（见下）。
 *   3) 修掉上游那处 HTTP 状态码问题：上游 `respondOk/respondErr` 只写 body 的 code，
 *      而 `passOnNotFound` 的路由 miss 时会先把 ctx.status 置成 404，于是"成功响应带 404"。
 *      现在入口是我们的代码，加一个链尾的 statusNormalizer() 按 body.code 回写状态码。
 *      （归属证据见 docs/API-NOTES.md 坑 34；上游 examples/admin.cj 仍留在快照里作对照。）
 *
 * 为什么写操作不直连社团库
 *   club-server 与运维台是两个进程。若都直接写同一份数据，就是 last-writer-wins，
 *   会静默丢数据，还会绕过 club-server 里的权限判定（N-7）、两阶段赋值（N-15）、
 *   部门一致性（N-18）等约束。所以：
 *     读 = 运维台直接连 **MySQL** 读社团库（2026-09-20 起；此前是读 db.json 文件）
 *     写 = 前端 fetch club-server 的「/api/v1/…」（CORS 已开、方法与 Authorization 头都在白名单里），
 *          用**运维账号**换到的令牌（后台代持，见 /api/club/session），令牌只存在浏览器 localStorage
 *  运维台自己的 RBAC 只负责"谁能打开这个页面"：后台的 admin 角色，或者**直接用 club-server
 *  的运维账号登录**（2026-09-17 起，见下方"运维身份"整段）。
 *
 * 社团库读取（2026-09-20）
 *   club-server 的持久化整体迁到 MySQL（路线 B：只换持久化层，
 *   见 server\src\mysql_store.cj 与 docs\club-server-mysql-assessment.md），
 *   `data/db.json` 不再是真相来源 —— 所以 withClub() 改成**从 MySQL 全量载入**
 *   （复用 club-server 那份 storeLoadDb，两个进程共用同一套字段映射）。
 *   admin.env 里：mysql_host / mysql_port / mysql_user / mysql_pass 与后台 RBAC 共用，
 *   社团库名另给一个键 **club_mysql_db**（默认 club）；club_data 保留，
 *   但它现在只表示**审计日志目录**（audit.log 仍在文件里，不入库）。
 *   「一键备份」相应地改成"从 MySQL 导出 JSON 快照"（用 renderDb，同原 db.json 格式）。
 *
 * 编译：build.ps1 -Target admin（框架文件（含 store.cj + db_mysql.cj，**不含** db_cangdb/db_factory）
 *       + 我们这 10 个：store / store_persistence / store_queries / mysql_store / audit /
 *         timex / strx / ops/club_json / ops/club_view / ops/admin_main
 *       + 链接内置 MariaDB 驱动 build\mysql-driver）
 * 运行：cd build\admin ; .\admin.exe   ->  http://127.0.0.1:3000/（运维页 /club）
 *
 * RBAC 数据层 = **MySQL**（2026-09-19 起）
 *   原先走 server\src\fw_rbac_store.cj 的 JSON 文件后端（build\admin\admin-data\rbac.json）——
 *   那是为"沧海 CangDB 1.0.5 与 cjc 1.1.3 不兼容（编译通过、运行超时）"的年代写的。轻舟 v0.7 加了数据库抽象层
 *   （src\db.cj 接口 + src\db_mysql.cj 的 MySqlBackend），所以本入口改成：
 *       RbacStore(MySqlBackend(host, port, user, pass, db))
 *   连接参数来自 admin.env 的 mysql_host / mysql_port / mysql_user / mysql_pass / mysql_db
 *   （见 docs\mysql-backend.md；建表与灌种子由框架 RbacStore 的构造完成）。
 *
 *   ⚠ 框架的种子口令是**写死的 admin123 / user123**（third_party\qingzhou\src\store.cj:104-111），
 *     直接用就是 N-29 回归。所以本文件在**新库**上多走一步"换口令"（见 main() 里 N-29 那段）：
 *     删掉两个种子账号、用随机口令重建，并写回 admin.env。目标：**新库首次启动后用
 *     admin123 / user123 登录必须失败**。
 */

import std.collection.*
import std.convert.*
import std.fs.*
import std.sync.*
import std.time.*
import stdx.encoding.json.*

/*
 * ⚠ 这一条 import **看着没人用，但绝对不能删**（2026-09-19）：
 *   内置的 MariaDB 驱动靠"包顶层的一条 `let _ = DriverManager.register(...)`"
 *   完成注册（third_party\mariadb-driver\src\cdbc\driver.cj:23），而**只有该包被引用时
 *   那行顶层初始化才会被执行**。只在链接命令里加 `-l:mariadb.cdbc` 是不够的 ——
 *   实测就是这样：编译链接全过，一启动就抛
 *     "未注册 mysql/mariadb 驱动：请引入 mysqlclient4cj 或 Cangjie-SIG mysql-driver…"
 *   而框架的 db_mysql.cj 是**运行时按注册名查找**驱动的（编译期零依赖），所以它自己
 *   不会 import 任何驱动包。于是"注册"这件事只能由**用它的那一方**（也就是这里）来做。
 *   import 只在 admin 这条构建链得上驱动（build.ps1 -Target admin 才带
 *   --import-path build\mysql-driver），club-server 那条既不编这个文件也不链驱动，
 *   所以不会因此多出一个依赖。
 */
import mariadb.cdbc.*

/* 优雅关闭触发器：闭包捕获 this，POST /admin/shutdown 置 true。 */
class OpsShutdownFlag {
    public var requested: Bool = false
    init() {}
}

/* 运维台配置（来自 admin.env，缺省值见 main 里）。 */
class OpsConfig {
    /*
     * 社团库的**审计日志目录**（2026-09-20 起只剩这一个用途）。
     *
     * 原先它是"社团库目录（含 db.json / audit.log）"，运维页直接读那个 db.json。
     * 现在 club-server 的业务数据全在 **MySQL** 里（路线 B：只换持久化层），
     * 社团库的读取改成连 MySQL（见 clubMysqlDb 与 withClub），
     * 所以这个目录下**只剩 audit.log** 还有意义 —— 审计是追加写的行日志，
     * 不属于那 7 张业务表，本次迁移没动它。
     * admin.env 的键名仍叫 `club_data`（历史配置，不改成谎报的键）。
     */
    public var dataDir: String = "../data"
    public var apiBase: String = "http://127.0.0.1:8080"  /* 服务端自己探测用 */
    public var clubPort: Int64 = 8080             /* 前端拼 club-server 地址用 */
    /*
     * 后台数据目录（2026-09-19 起只剩一个用途：**社团库备份**落到它下面的 club-backups\）。
     * 原先它还兼着"RBAC 数据文件所在目录"（rbacDb 派生自它），现在 RBAC 在 MySQL 里，没有文件了。
     */
    public var adminDataDir: String = "admin-data"
    /*
     * 后台自己的 RBAC 库（2026-09-19 改）：**MySQL**，不再是 admin-data\rbac.json。
     * 下面 5 个字段只是"回显给运维页看"的值（/api/club/config 会告诉运维人员后台连的是哪个库），
     * 真正建连用的是 main() 里从同一份配置读出的参数 —— 别在这里再读一次 env，会出现两份口径。
     */
    public var mysqlHost: String = "127.0.0.1"
    public var mysqlPort: Int64 = 3306
    public var mysqlUser: String = "root"
    /*
     * 口令**故意只留在 main() 的局部变量里、不放进本对象**：OpsConfig 的字段会被
     * /api/club/config 之类的响应读出去，口令放进来就迟早会被某次"顺手回显"带出去。
     * （本对象里唯一与凭据有关的是 clubUser/clubPass，那是 club-server 的运维账号，
     * 有专门的加锁与一致性访问器，见下面。）
     */
    public var mysqlDb: String = "club_rbac"
    /*
     * **社团库**所在的数据库名（2026-09-20 新增，admin.env 的 `club_mysql_db`）。
     *
     * 为什么单独一个键：运维台自己的 RBAC 库（mysql_db = club_rbac）与 club-server 的
     * 业务库是**同一个 MySQL 实例上的两个库**。host/port/user/pass 复用 mysql_*，
     * 只有库名不同 —— 于是运维页读社团库与它自己登录用不着两套连接配置。
     *
     * ⚠ 默认值**必须是 club_server**（= club-server 的 MySqlConfig.db 默认值）。
     *   2026-09-20 之前这里写的是 `club`，而 build.ps1 生成的 admin.env 也写 `club`，
     *   注释还声称"与 club-server 的默认库名一致" —— 那是错的：club-server 默认就是
     *   `club_server`，于是**开箱即错**：运维页一打开就是
     *   `Unknown database 'club'`（实测踩到）。用户的 DSN 写的是 club_server 时尤其明显。
     *   README / local-deploy 的示例也一律用 club_server，两处现在对齐了。
     */
    public var clubMysqlDb: String = "club_server"
    /*
     * 专用运维账号（club-server 侧的 `role = ops`，由 club-server init-ops 创建）。
     * 为什么由后台代持：运维不该由会长执行 —— 运维人员只用后台账号登录（口令见 N-29 的说明），
     * 写操作以这个运维账号的身份发出去，club-server 的审计里 actor 就是"运维"。
     *
     * ⚠ 为什么这两条要私有化 + 加锁（2026-09-17）：
     *   上面那 5 个字段只在 main() 里写一次、`serve()` 之后只读，所以裸着没有竞争；
     *   而这两条不同 —— 用**运维账号登录运维台**时（见文件上方的"运维身份"整段）
     *   opsLoginViaClub() 会在**请求线程里就地改写它们**，同时 /api/club/config、
     *   /api/club/session、clubSessionEnsure() 都在读。框架是**并发处理请求**的（每个请求一个
     *   轻量线程），而这是一对**必须一致**的值：读方若恰好插在两次赋值之间，
     *   就会拿到"新手机号 + 旧口令"这种**不可能存在**的组合，然后拿它去 club-server 登录 ——
     *   白烧一次 10 万次 PBKDF2，还会在 sess.err 里留下"凭据被拒绝"这种把人带偏的诊断
     *   （会让人以为是 club-server 或密码的问题）。
     *   所以：两个字段一起私有化，由一把 Mutex 保护，对外只暴露
     *   clubCreds()（一次取一对一致快照）与 setClubCreds()（一次写一对）。
     */
    private let credMu = Mutex()
    private var clubUser: String = ""
    private var clubPass: String = ""

    public init() {}

    /* 一致快照：返回的 user / pass 必定来自**同一次**写入（见上方注释）。 */
    public func clubCreds(): (String, String) {
        var u = ""
        var p = ""
        credMu.lock()
        try {
            u = clubUser
            p = clubPass
        } finally {
            credMu.unlock()
        }
        return (u, p)
    }

    /* 整体替换：两条一次写完。读方要么看到旧的一对、要么看到新的一对，没有中间态。 */
    public func setClubCreds(user: String, pass: String): Unit {
        credMu.lock()
        try {
            clubUser = user
            clubPass = pass
        } finally {
            credMu.unlock()
        }
    }
}

/*
 * 运维会话（内存缓存）：后台用 club_user/club_pass 登录 club-server 换到的令牌。
 * 只在后台进程内存里，不落盘；TTL 内复用，避免每次开页面都烧一次 PBKDF2（~400 ms）。
 *
 * ⚠ 为什么不直接公开 6 个 var（2026-09-17 修）：
 *   它由 main() 创建、被多个请求闭包**共享**，而框架并发处理请求。原先 6 个字段各自裸读写，
 *   于是读方可能看到"新 token 配旧 err"、"新身份配旧 token"这类**半成品组合** ——
 *   /api/club/session 是把这些字段逐个塞进 JSON 再交给前端的，前端拿到一次撕裂的组合
 *   就可能显示"身份是运维账号，但 token 是上一个账号的"。
 *   方案：字段全部私有，只留两个入口 ——
 *     · commit(...)    一次**整体替换**全部 6 个字段（登录成功时）；
 *     · markFailed(msg) 只清 token + 记 err，**身份字段保持上一次的值**（登录失败时，
 *                       与改动前的行为逐字段一致）；
 *     · view()         返回**不可变快照** ClubSessionView，读方在快照上取字段，
 *                       拿到的永远是一次完整写入的结果。
 *   没有采用"整对象引用替换"（每次 new 一个 ClubSession 换引用）的原因：那需要把
 *   ops / clubSess 再包一层可变引用并给它加锁，等于多一层间接；而这里字段少、写点只有两处，
 *   在类内加锁更直白。也没有把网络调用放进锁内（见 clubSessionEnsure 的注释）。
 */
class ClubSession {
    private let mu = Mutex()
    private var token: String = ""
    private var at: Int64 = 0
    private var name: String = ""
    private var role: String = ""
    private var phone: String = ""
    private var err: String = ""

    public init() {}

    /* 一次写完 6 个字段（读方要么看到上一次的完整会话，要么看到这一次的完整会话）。 */
    public func commit(token: String, at: Int64, name: String, role: String, phone: String,
                       err: String): Unit {
        mu.lock()
        try {
            this.token = token
            this.at = at
            this.name = name
            this.role = role
            this.phone = phone
            this.err = err
        } finally {
            mu.unlock()
        }
    }

    /*
     * 登录/续期失败：清掉 token、记下原因，**不动 at / name / role / phone**。
     * 保持"失败时身份字段还在"这一点是有意的 —— 它与改动前的逐字段行为一致，
     * 而令牌已清空，前端拿到的 error 会盖住身份展示。
     */
    public func markFailed(err: String): Unit {
        mu.lock()
        try {
            this.token = ""
            this.err = err
        } finally {
            mu.unlock()
        }
    }

    /*
     * 一致快照。与 clubCreds() / commit() / markFailed() 保持**同一种写法**（try/finally）：
     * 今天 ClubSessionView 的构造函数只做赋值、不会抛，裸 lock/unlock 也正确；
     * 但这里是全类唯一一处"往构造函数里加一行校验就会永久死锁"的写法，
     * 而重复锁定在仓颉里是直接挂住（不是抛异常），排查成本极高 —— 统一成 try/finally。
     */
    public func view(): ClubSessionView {
        mu.lock()
        var v = ClubSessionView("", 0, "", "", "", "")
        try {
            v = ClubSessionView(token, at, name, role, phone, err)
        } finally {
            mu.unlock()
        }
        return v
    }
}

/* 会话快照：view() 的返回值。字段全是 let，拿到之后怎么传都不会再变。 */
class ClubSessionView {
    public let token: String
    public let at: Int64
    public let name: String
    public let role: String
    public let phone: String
    public let err: String
    public init(token: String, at: Int64, name: String, role: String, phone: String, err: String) {
        this.token = token
        this.at = at
        this.name = name
        this.role = role
        this.phone = phone
        this.err = err
    }
}

/* 缓存有效期（秒）：club-server 的令牌本身是 30 天，这里只是别把登录做得太频繁。 */
let OPS_SESSION_TTL: Int64 = 6 * 3600

/* ===================== 运维身份：运维账号直接登录运维台（2026-09-17） =====================
 *
 * 登录框现在接受**两种**凭据：
 *   ① 后台自己的账号（轻舟 RBAC：admin / user）—— 管后台自身，与上游一致；
 *   ② club-server 的**运维账号**（`role = ops`，由 `club-server init-ops` 创建）——
 *      也就是把手机号与运维口令直接填进登录框。
 *
 * 为什么加这条（原先的设计是"运维人员必须先拿到另一个后台口令，再把运维账号手填进
 * admin.env 的 club_user/club_pass"）：两套凭据、两道手工配置，而运维人员真正拥有的
 * 只有 init-ops 建的那一个。实测里这一步正是最容易被跳过、跳过之后现象最迷惑人的地方
 * （登录恒 401，而运维页名录读文件、照样看得见那个账号），见 local-deploy §2.2 / §2.7。
 *
 * 身份怎么表达：JWT 主体写成 **`ops:<手机号>`**，与后台自己的数字 userId 天然区分开。
 *   · 不必新增角色、也不必迁移 rbac.json；
 *   · framework 的 requirePermission 把非数字主体判成 userId = -1 → 后台管理接口
 *     （用户 / 角色 / 权限）对运维身份**自然关闭**，无需额外写闸门；
 *   · 运维接口的闸门在 requireClubOps() 里显式放行这一形态。
 *
 * 口令**由 club-server 校验**（不在这里离线核对 db.json）。理由：写路径本来就走
 * club-server，两边用同一个权威才不会出现"登录成功了但写操作说凭据被拒"这种分裂状态；
 * 而且 club-server 只在启动时读一次库，"刚 init-ops 但没重启"这类问题能在登录这一步
 * 就被诊断出来（见 opsLoginDiagnosis）。
 */
let OPS_SUBJECT_PREFIX: String = "ops:"

func opsSubjectOf(phone: String): String {
    return OPS_SUBJECT_PREFIX + phone
}

/* 是运维身份则返回其中的手机号；后台自己的数字主体返回 None。 */
func opsPhoneOfSubject(subject: String): ?String {
    if (subject.size > OPS_SUBJECT_PREFIX.size &&
        subject[0..OPS_SUBJECT_PREFIX.size] == OPS_SUBJECT_PREFIX) {
        return Some(subject[OPS_SUBJECT_PREFIX.size..])
    }
    return None
}

/*
 * 运维账号登录的按 IP 节流表。
 *
 * 为什么必须有：登录框会把"非后台账号"的输入**转发**给 club-server 校验，而那边每次
 * 校验都是 10 万次 PBKDF2 —— 于是运维台多了一条"未认证就能让 club-server 烧 CPU"的路径
 * （与 N-21 同一类问题）。更要紧的是 **club-server 的登录节流是按 IP 记的，而所有转发
 * 都来自运维台这一个 IP**：局域网里有人刷运维台登录，就可能把社团服务端的登录桶刷满，
 * 把真正的运维人员一起锁在门外。
 *
 * 所以这里在**转发之前**按客户端 IP 先拦一道，阈值取 club-server 的一半
 * （那边是 15 分钟 10 次，见 h_auth.cj 的 LOGIN_FAIL_LIMIT=5/两个桶），
 * 保证**单个来源**打不满 club-server 的桶。递增退避与清理策略与 h_auth.cj 同构。
 *
 * 线程安全（2026-09-17 复核，因为框架并发处理请求）
 *   本类**是**线程安全的，但这份保证完全依赖那把 Mutex —— 它是个 `private let`，构造期初始化，
 *   locked() / note() 两步都整体包在 lock/unlock 里（含 `tbl.get(ip) ?? OpsLoginFail()` 这条
 *   读改写），所以 HashMap 永远不会被并发改坏，也不会出现"两次失败只记了一次"的丢更新。
 *   ⚠ 因此**新增任何触碰 tbl 的方法都必须自己加锁**，或者干脆在锁内委托给已有方法；
 *   尤其是别在锁外直接读 tbl（HashMap 不是线程安全的，project 纪律见 capacity-baseline §4.4）。
 *
 * 谁在用这张表（2026-09-17 起）
 *   **两条登录分支共用一个桶**（这是本次修的缺陷之一，见 /api/login 的注释）：
 *   原先只有"转发给 club-server"的运维账号分支走节流，而"命中本地 RBAC 账号"的分支失败时
 *   直接返回 401 —— 于是一个来源可以**无限次**猜后台账号的口令（admin / user 那两个），
 *   而节流表完全没记过一笔。
 */
let OPS_LOGIN_WINDOW: Int64 = 900         /* 统计窗口（秒） */
let OPS_LOGIN_FAIL_LIMIT: Int64 = 5       /* 窗口内失败次数达到它就锁 */
let OPS_LOGIN_LOCK: Int64 = 900           /* 锁定时长（秒） */
/* 登录字段上限（2026-09-18 补）：见 /api/login 入口的第一道校验。256 字节足够任何手机号/账号名。 */
let OPS_LOGIN_FIELD_MAX: Int64 = 256

class OpsLoginFail {
    public var count: Int64 = 0
    public var first_at: Int64 = 0
    public var locked_until: Int64 = 0
    public init() {}
}

/*
 * 按来源 IP 记登录失败的节流表（见上方整段说明）。
 * 线程安全：全部状态都在 mu 保护之下 —— 新增方法请照抄下面两个方法的形状（lock / try / finally unlock）。
 */
class OpsLoginGuard {
    private let mu = Mutex()
    private var tbl: HashMap<String, OpsLoginFail> = HashMap<String, OpsLoginFail>()

    public init() {}

    public func locked(ip: String): Bool {
        mu.lock()
        var out = false
        try {
            let now = nowEpoch()
            match (tbl.get(ip)) {
                case Some(st) => out = st.locked_until > now
                case None => out = false
            }
        } finally {
            mu.unlock()
        }
        return out
    }

    /* ok = true 表示这次尝试"凭据确实有效"，成功即清空该 IP 的记录。 */
    public func note(ip: String, ok: Bool): Unit {
        /* 空键 = 回环等不参与节流的来源（见 opsLoginViaClub 里的说明） */
        if (ip.size == 0) {
            return
        }
        mu.lock()
        try {
            let now = nowEpoch()
            if (ok) {
                tbl.remove(ip)
            } else {
                let st = tbl.get(ip) ?? OpsLoginFail()
                if (st.first_at == 0 || now - st.first_at > OPS_LOGIN_WINDOW) {
                    st.first_at = now
                    st.count = 0
                }
                st.count += 1
                if (st.count >= OPS_LOGIN_FAIL_LIMIT) {
                    st.locked_until = now + OPS_LOGIN_LOCK
                    st.count = 0
                    st.first_at = now
                }
                tbl[ip] = st
                if (tbl.size > 500) {
                    let doomed = ArrayList<String>()
                    for ((k, v) in tbl) {
                        if (v.locked_until <= now && now - v.first_at > OPS_LOGIN_WINDOW) {
                            doomed.add(k)
                        }
                    }
                    for (k in doomed) {
                        tbl.remove(k)
                    }
                }
            }
        } finally {
            mu.unlock()
        }
    }
}

/* 进程内单例：登录路由是闭包，用全局量比多穿一层参数清楚。 */
let opsLoginGuard = OpsLoginGuard()

/*
 * 从 ctx.remoteAddr()（"ip:port" / "[v6]:port" / 裸 IPv6）里剥出地址，只当作**节流键**用。
 * 因此这里不需要 N-14 那种严格判定：即使切错也只是几个来源共用同一个桶（偏保守，不是绕过）。
 */
func opsClientIp(ctx: Context): String {
    let raw = ctx.remoteAddr()
    let a = raw.toArray()
    let n = a.size
    if (n == 0) {
        return ""
    }
    if (a[0] == 91) {   /* '[' → [v6]:port */
        var i: Int64 = 1
        while (i < n) {
            if (a[i] == 93) {   /* ']' */
                return String.fromUtf8(a[1..i])
            }
            i += 1
        }
        return raw
    }
    var colons: Int64 = 0
    var last: Int64 = -1
    var j: Int64 = 0
    while (j < n) {
        if (a[j] == 58) {   /* ':' */
            colons += 1
            last = j
        }
        j += 1
    }
    if (colons == 1) {
        return String.fromUtf8(a[0..last])
    }
    return raw
}

/*
 * 节流键：把回环来源折成空串（= **不参与节流**）。
 *
 * 与 club-server 的**注册口令**节流同口径（回环豁免）：本机调用者本来就有更高权限，
 * 而且本项目的测试脚本都从本机打 —— 否则跑几轮测试就把自己锁 15 分钟。
 * ⚠ 2026-09-18：club-server 的**登录**按 IP 节流已按"应用层不做抗 DDoS"的口径移除；
 *   运维台这一道**保留** —— 它守的是后台口令（未认证端点上的口令穷举），不是流量型攻击。
 * 回环折成空串后由 OpsLoginGuard 处理：note() 忽略空键，locked() 对空键恒 false。
 *
 * 为什么要抽成函数（2026-09-17）：/api/login 的**两条分支现在共用同一张节流表**，
 * 两条分支必须用同一个键算法 —— 各算各的就会出现"同一台机器在两个分支上各有一个桶"，
 * 那"统一节流"就名不副实（换一个用户名格式就能换一个桶接着猜）。
 */
func opsThrottleKey(ctx: Context): String {
    let ip0 = opsClientIp(ctx)
    let isLoopback = (ip0 == "127.0.0.1" || ip0 == "::1" ||
        ip0 == "0:0:0:0:0:0:0:1" || ip0 == "::ffff:127.0.0.1")
    if (isLoopback) {
        return ""
    }
    return ip0
}

/* 被节流时的统一回执：两条分支共用同一句话，避免"同一件事两种说法"漂移。 */
func opsThrottleRejected(ctx: Context): Unit {
    opsErr(ctx, 429, 429, "尝试过于频繁：该来源已被临时锁定" +
        "（约 15 分钟；重启运维台立即清零）")
}

/* ---------------------------------------------------------------------------
 * 直连 HTTP（**绕过系统 http_proxy**）—— 与 club_api 通信一律走这两个函数
 *
 * 为什么不用框架的 httpGetText / httpPostJson：
 *   它们内部是 `ClientBuilder().build()`，而 **stdx 的 HTTP 客户端默认会走系统
 *   http_proxy**（连回环地址也照走）。本文件访问的 club_api 按设计就是回环地址
 *   （admin.env 的 club_api，默认 http://127.0.0.1:8080），于是只要环境里存在
 *   http_proxy，发往回环的请求就会被劫给代理 → 代理连不到 → 运维台报
 *   「连不上 club-server」，而同一时刻手工 curl 却是通的。
 *
 *   真实现场（2026-10-02）：WSL 镜像模式的 autoProxy 会把 Windows 的代理配置带进
 *   WSL（http_proxy=http://127.0.0.1:7897），运维账号登录即 100% 失败；
 *   清掉这几个环境变量就恢复正常 —— 已用隔离实验确认。
 *
 *   框架自己的 HttpClient 类是调了 `ClientBuilder().noProxy()` 的，注释里也写明
 *   "回环地址也会被代理拦截成 502 upstream connect failed" —— 所以这里改用它。
 *
 * 为什么修在 server/src 而不是修框架：
 *   third_party/qingzhou/PROVENANCE.md 的「升级纪律」要求**框架文件保持上游原样**，
 *   项目行为修复只能落在 server/src 或构建脚本里；何况 MANIFEST.sha256 会逐字节校验，
 *   改快照会让构建当场失败。
 *
 * 语义与原薄封装保持一致：非 2xx / 网络错误一律返回 None。
 * 超时：与 club-server 同机，8 秒足够区分"连不上"和"慢"。
 * ------------------------------------------------------------------------- */
let OPS_CLUB_HTTP_TIMEOUT: Int64 = 8

func clubHttpGet(url: String): ?String {
    let c = HttpClient(OPS_CLUB_HTTP_TIMEOUT, OPS_CLUB_HTTP_TIMEOUT)
    var result: ?String = None
    try {
        let r = c.get(url)
        if (r.ok) {
            result = Some(r.body)
        }
    } catch (e: Exception) {
        result = None
    } finally {
        c.close()
    }
    return result
}

func clubHttpPostJson(url: String, jsonBody: String): ?String {
    let c = HttpClient(OPS_CLUB_HTTP_TIMEOUT, OPS_CLUB_HTTP_TIMEOUT)
    var result: ?String = None
    try {
        let r = c.post(url, jsonBody)
        if (r.ok) {
            result = Some(r.body)
        }
    } catch (e: Exception) {
        result = None
    } finally {
        c.close()
    }
    return result
}

/*
 * 运维账号登录失败时的**分类诊断**（与 clubSessionEnsure 同一套口径）：
 * "连不上 club-server" 与 "凭据不对" 处置完全不同，答错方向比不答更费时间。
 */
func opsLoginDiagnosis(ops: OpsConfig, phone: String): String {
    match (clubHttpGet(opsJoin(ops.apiBase, "health"))) {
        case Some(_) =>
            return "登录失败：手机号 ${phone} 或口令不对。" +
                "若这是刚用 init-ops 建的账号，注意 club-server **只在启动时读一次库** —— " +
                "必须在建完账号**之后**再启动它（边跑边改不生效，见 local-deploy §2.2 ②）"
        case None =>
            if (startsWithAscii(ops.apiBase.toAsciiLower(), "https://")) {
                return "登录失败：连不上 HTTPS 的 club-server（${ops.apiBase}）。" +
                    "运维台的出站客户端没有 TLS 配置，自签证书也过不了校验 —— " +
                    "请让 club-server 另以**明文 HTTP** 起一个本机端口，并把 club_api 指向它。"
            }
            return "登录失败：连不上 club-server（${ops.apiBase}）。" +
                "运维账号的口令由 club-server 校验，所以它必须在跑 —— " +
                "先在 server\\build 下跑 `club-server serve 8080 data`，再回来登录。" +
                "（club-server 没起时，仍可用后台自己的账号 admin/user 登录，运维页只能看不能改。）"
    }
}

/* ===================== 响应壳（与上游 admin 前端约定一致：{code,message,data}） ===================== */

func opsOk(ctx: Context, data: JsonValue): Unit {
    let o = JsonObject()
    jPutInt(o, "code", 0)
    jPutStr(o, "message", "ok")
    o.put("data", data)
    ctx.status(200).json(o.toString())
}

func opsErr(ctx: Context, status: Int64, code: Int64, message: String): Unit {
    let o = JsonObject()
    jPutInt(o, "code", code)
    /* 用 JsonObject 序列化，转义交给 toString()（手拼字符串会在中文/引号/路径上翻车） */
    jPutStr(o, "message", message)
    o.put("data", JsonNull())
    ctx.status(status).json(o.toString())
}

/*
 * 链尾修状态码：跑完后面的中间件后，若 body 是统一响应壳（以 {"code": 开头），
 * 就按 code 回写 HTTP 状态（0 → 200，其余取 code 本身）。
 *
 * 为什么需要：上游 authRequired / requirePermission / respondErr 只写 body.code 不设 status，
 * 而 passOnNotFound 的路由在 miss 时会先把 status 置成 404 —— 于是 /api/me 拿到的是
 * "HTTP 404 + body code=0"。静态文件的 body 不以 {"code": 开头，因此不受影响。
 */
func statusNormalizer(): Middleware {
    return { ctx: Context, next: () -> Unit =>
        next()
        let body = ctx._peekBody()
        if (body.size < 9) { return }
        if (body[0..8] != "{\"code\":") { return }
        var code: ?Int64 = None
        try {
            code = jsonGetInt64(JsonValue.fromStr(body).asObject(), "code")
        } catch (e: Exception) {
            code = None
        }
        match (code) {
            case Some(n) => ctx.status(statusForCode(n))
            case None => ()
        }
    }
}

func statusForCode(n: Int64): Int64 {
    if (n == 0) { return 200 }
    if (n >= 100 && n <= 599) { return n }
    return 500
}

/* 错误兜底：上游用 jsonErrorHandler（body 是 {"error":...}），这里换成响应壳，前端才认。 */
func opsErrorHandler(): Middleware {
    return { ctx: Context, _: () -> Unit =>
        match (ctx.err()) {
            case Some(e) =>
                if (ctx._peekStatus() == 200 && ctx._peekBody().size == 0) {
                    opsErr(ctx, 500, 500, "运维台内部错误：${e.message}")
                }
                ctx.trace("[err] ${e.message}")
            case None => ()
        }
    }
}

/* ===================== 请求体前置闸门（2026-09-18 补） ===================== */

/*
 * 请求体上限：与 club-server 的 MAX_BODY_BYTES（limits.cj）同口径。
 * 本项目最大的合法请求体是批量分配（200 个 id ≈ 3 KB），64 KiB 留足余量。
 */
let MAX_OPS_BODY_BYTES: Int64 = 64 * 1024

/*
 * 请求体前置闸门。**必须挂在 bodyParser() 之前**（见 main() 的装配链）。
 *
 * 为什么运维台也要一道（与 club-server 的 limits.cj 同一类防护）：
 *   框架的 bodyParser 是"**先把整个 body 读进内存、再比 maxBytes**"，而且对
 *   非 json / 表单 / text 的 Content-Type 直接透传、不读也不判 —— 而 handler 里的
 *   bodyStrOr() 照样会把整份 body 读进来（context.cj 的 bodyBytes 没有任何上限）。
 *   运维台的 POST /api/login 是**未认证**端点，所以"先读后判"在这里等于把内存交给任何人。
 *   ⚠ admin 那条子集构建（build.ps1 -Target admin）**不含 limits.cj / jsonw.cj**，
 *     所以这里是一份**自包含**的等价实现：只用框架的 Middleware/Context，加上
 *     strx.cj 的三个纯函数（isBlank / isDigits / startsWithAscii，它们在子集里）。
 *     两份实现要一起看：club-server 改了 limits.cj 的判定，这里也要跟着对齐。
 *
 * 三条判定：
 *   ① 带 Transfer-Encoding（chunked）或 Content-Length 不是十进制数字 → 411
 *      （长度判不了就**明确拒绝**，不给"绕到框架那边先读进内存"留口子）；
 *   ② Content-Length > MAX_OPS_BODY_BYTES → 413；
 *   ③ Content-Type（剥参数、转小写后）不在 JSON / 表单 / text/ 三类里 → 415。
 *
 * ⚠ 空 Content-Type **放行**（与 limits.cj 一致，这里是有意的）：它是"没有 body 的写请求"
 *   的标准形态 —— 例如 DELETE /api/users/:id（前端与 tests/admin-check.ps1 都不带 body），
 *   还有 POST /admin/shutdown 之外的各类无 body 调用。安全性由 ①② 保证：不管 Content-Type
 *   是什么，长度都必须先过闸，所以"放过空 CT"并不会让大 body 进内存。
 *   代价写清楚：既没有 Content-Length、也没有 Transfer-Encoding 的原始请求只能依赖
 *   服务器本身不去读 body（HTTP/1.1 下无从得知 body 长度，stdx 也不会读它）。
 *
 * 为什么自己回响应、而不是 next() 交给链尾的 statusNormalizer：
 *   本闸门在 bodyParser **之前**，被它拒掉的请求根本走不到 statusNormalizer
 *   （那个规范化是在 bodyParser 之内、靠 next() 走完整条链才生效的），
 *   所以状态码必须在这里显式写死 —— opsErr 就是干这个的（也顺带保证了响应仍是
 *   {code,message,data} 壳，前端 api.js 按 json.code 分支不会踩空）。
 */
func opsBodyLimit(): Middleware {
    return { ctx: Context, next: () -> Unit =>
        let m = ctx.method()
        let writes = (m == "POST" || m == "PUT" || m == "PATCH" || m == "DELETE")
        if (writes) {
            match (ctx.requestHeader("transfer-encoding")) {
                case Some(te) =>
                    if (!isBlank(te)) {
                        opsErr(ctx, 411, 411, "请用 Content-Length 声明请求体长度（运维台不接受 chunked）")
                        return
                    }
                case None => ()
            }
            match (ctx.requestHeader("content-length")) {
                case Some(raw) =>
                    if (!isDigits(raw)) {
                        opsErr(ctx, 411, 411, "Content-Length 必须是十进制数字")
                        return
                    }
                    /* 先判位数再 parse：20 位以上的十进制数会让 Int64.parse **抛溢出异常**，
                     * 而这里是中间件最外层，异常会变成 500 —— 一个"报 413"的闸门反被
                     * 超长 Content-Length 打成 500。15 位十进制（10^15）早就远超 64 KiB，
                     * 直接按"过大"处理，不必解析。 */
                    var over = (raw.size > 15)
                    if (!over && Int64.parse(raw) > MAX_OPS_BODY_BYTES) {
                        over = true
                    }
                    if (over) {
                        opsErr(ctx, 413, 413, "请求体过大（上限 ${MAX_OPS_BODY_BYTES} 字节）")
                        return
                    }
                case None => ()
            }
            /* 大小写不敏感（RFC 7231 §3.1.1.1）：ctx.contentType() 只剥参数、不转小写，
             * 所以统一 toAsciiLower() 后再比（否则 Application/JSON 会被误判 415）。 */
            let ct = ctx.contentType().toAsciiLower()
            if (ct.size > 0 && ct != "application/json" &&
                ct != "application/x-www-form-urlencoded" && !startsWithAscii(ct, "text/")) {
                opsErr(ctx, 415, 415, "请求体格式不受支持，请使用 application/json")
                return
            }
        }
        next()
    }
}

/* ===================== 路径工具 ===================== */

/*
 * 注（2026-09-19）：原先这里还有一个 opsDirOf(p) —— 把 RBAC 数据文件（admin-data/rbac.json）
 * 的路径切成目录，用来派生"备份落到哪"。RBAC 迁到 MySQL 之后没有这个文件了，
 * adminDataDir 改成直接读 admin.env 的 admin_data（见 main()），本函数遂无调用方，删掉。
 */

func opsJoin(a: String, b: String): String {
    if (a.size == 0) { return b }
    let last = a[a.size - 1]
    if (last == UInt8(0x2F) || last == UInt8(0x5C)) {
        return a + b
    }
    return a + "/" + b
}

/*
 * 把首次生成的种子口令写回 admin.env（N-29，2026-09-17；2026-09-19 改成"就地替换"）。
 *
 * 只在**刚建库/刚建表**、且口令是本次随机生成（或用户已在 env 里指定）时调用。
 *
 * ⚠ 为什么不是 File.appendTo（2026-09-19 改）：
 *   原先无条件追加一个块，而 `Config` 的解析是"**后出现的键覆盖先出现的**"。这条组合在
 *   真机上会产生一个**把自己锁在门外**的文件（实测踩到）：admin.env 里已经有模板留的
 *   `# admin_pass=`（注释，不算）或上一次追加留下的 `admin_pass=<旧值>` 时，新口令被追加在
 *   它**后面**，于是"文件里第一条 admin_pass"是空的（或旧口令），而操作员按文件从上往下
 *   读、或按第一条去登录，就会一直失败；而且每切一次库/重灌一次种子就多一段，越积越乱。
 *   （把 tables 清掉重跑测试就会看到重复段 —— 这份文件是要被人打开看的，别留这种雷。）
 *
 * 现在的写法：**逐行重写整份文件**，遇到 `admin_pass` / `user_pass` 就替换成新值，
 * 没有这两行才在末尾补一段。于是文件里永远只有一条、且它就是真正生效的那一条。
 * 仍然保留"只打印一次、不回显旧口令"的语义（打印在调用方）。
 *
 * 写不进去不致命（口令已经打印在控制台），但必须**显式告警**，绝不静默。
 */
func persistSeedCreds(envPath: String, adminPass: String, userPass: String): Unit {
    try {
        let head = "# ── 首次启动自动生成的后台账号口令（N-29：不再使用写死的默认值）──"
        let raw = String.fromUtf8(File.readFrom(envPath))
        let out = ArrayList<String>()
        var seenAdmin = false
        var seenUser = false
        for (line in raw.split("\n")) {
            /* 用 strx.cj 的 startsWithAscii 而不是 String 的同名方法：本项目只确认过
             * String 的 toArray/fromUtf8/trimAscii/toAsciiLower/size（见 strx.cj 文件头），
             * 其余一律自己写，免得再撞上"声明了但没实现"的 API（轻舟 DEF-1 那类）。 */
            let t = line.trimAscii()
            if (startsWithAscii(t, "admin_pass")) {
                out.add("admin_pass=${adminPass}")
                seenAdmin = true
            } else if (startsWithAscii(t, "user_pass")) {
                out.add("user_pass=${userPass}")
                seenUser = true
            } else {
                out.add(t)
            }
        }
        if (!seenAdmin || !seenUser) {
            out.add("")
            out.add(head)
            if (!seenAdmin) { out.add("admin_pass=${adminPass}") }
            if (!seenUser) { out.add("user_pass=${userPass}") }
        }
        File.writeTo(envPath, String.join(out.toArray(), delimiter: "\n").toArray())
    } catch (e: Exception) {
        println("[admin] ⚠ 口令未能写回 ${envPath}（${e.message}）—— 请立即手工记下上面的口令！")
    }
}

/*
 * 备份文件后缀：yyyyMMdd-HHmmss-SSS（本地时间，末尾三位是**毫秒**）。
 * 字段名按 std.time.DateTime 的实际口径：month 是枚举（要 toInteger），日期是 dayOfMonth；
 * 毫秒取 nanosecond / 1000000（DateTime 没有直接的 millisecond 属性，实测 nanosecond 可用）。
 * 为什么原来是 yyyyMMdd-HHmmss 而现在是这个（2026-09-17 修，见 opsBackupPath 的注释）。
 */
func opsStamp(): String {
    let t = DateTime.now()
    return "${t.year}${pad2(t.month.toInteger())}${pad2(t.dayOfMonth)}-${pad2(t.hour)}${pad2(t.minute)}${pad2(t.second)}-${opsPad3(t.nanosecond / 1000000)}"
}

/* 三位补零（7 -> "007"）。框架的 pad2 只补两位，毫秒要三位，所以这里自己写一个。 */
func opsPad3(n: Int64): String {
    if (n < 10) { return "00" + n.toString() }
    if (n < 100) { return "0" + n.toString() }
    return n.toString()
}

/*
 * 备份目标路径：<outDir>/<prefix>-<stamp><ext>；若该名字已被占用（或还留着它的 .tmp），
 * 就补一个递增序号 -1、-2……
 *
 * 为什么需要（2026-09-17 修）：原先文件名只到**秒**，而备份是"人可能连点两次"的操作 ——
 * 同一秒内的第二次备份会**直接覆盖**第一次的产物（同名 File.writeTo），于是"我备份了两份"
 * 悄悄变成"只剩一份"，而响应里两次返回的路径还一模一样，靠对比根本发现不了。
 * 只加毫秒还不够（同一毫秒内两次并发仍可能撞），所以这里让**文件系统判重**：只要目标名已存在
 * 就换下一个序号，名字唯一不靠时间碰运气。
 *
 * ⚠ "判重"本身是"先看后写"，两个并发请求同时看会双双选到同一个名字 —— 所以整段备份
 *   （取时间戳 → 定路径 → 写 .tmp → rename）都在全局 opsBackupMu 里串行执行。
 *   不加这道锁的话，两个并发备份可能连**同一个 .tmp 文件**都共用，把刚做完的"原子写"
 *   重新变回撕裂写（两个写者交错写同一个 tmp，再被 rename 成正式副本）。
 *   备份是低频的人工操作，串行化没有任何代价。
 */
func opsBackupPath(outDir: String, prefix: String, stamp: String, ext: String): String {
    let base = "${prefix}-${stamp}"
    var candidate = base + ext
    var n: Int64 = 1
    while (exists(opsJoin(outDir, candidate)) || exists(opsJoin(outDir, candidate + ".tmp"))) {
        candidate = "${base}-${n}${ext}"
        n += 1
    }
    return opsJoin(outDir, candidate)
}

/*
 * 原子写文件：先写同目录的 <目标>.tmp，再 rename 覆盖到目标 —— 与 store.cj / fw_rbac_store.cj
 * 的落盘口径完全一致。
 *
 * 为什么（2026-09-17 修）：原先备份是 `File.writeTo(目标, File.readFrom(源))` —— **直接往最终
 * 文件名里写**。备份的全部价值在于"出事时手上有一份完好的副本"，而直接写最终名意味着这份副本
 * 自己也可能处在"写了一半"的状态：进程被杀 / 磁盘写满 / 目标盘是移动硬盘被拔掉，
 * 留下的就是一个**残缺的 db-*.json** —— 它体积非零、文件名正常，看起来完全像一次成功的备份，
 * 而真出事的时候打开才发现是坏的（这正是"备份没验过等于没有备份"的经典形态）。
 * .tmp + rename 后：目标文件要么不存在，要么内容是完整的（同一卷上 rename 是原子的）。
 */
func opsWriteFileAtomic(dst: String, bytes: Array<UInt8>): Unit {
    let tmp = dst + ".tmp"
    File.writeTo(tmp, bytes)
    rename(tmp, to: dst, overwrite: true)
}

/*
 * 备份串行闸：见 opsBackupPath 的注释（"名字判重"是"先看后写"，必须整段串行才成立）。
 * 只有备份这一条路径用它，不参与任何其它请求，因此不会拖慢运维页的读接口。
 */
let opsBackupMu = Mutex()

/* ===================== 社团库读取（只读） ===================== */

/*
 * 确保有一个可用的 club-server 运维会话（必要时登录）。
 *
 * 登录用 clubHttpPostJson（见本文件开头那段说明：直连、绕过 http_proxy）——
 * 它语义上"非 2xx / 网络错误一律返回 None"，
 * 所以我们再探一次 /health 来区分"连不上"和"凭据不对"（两类问题处置完全不同）。
 *
 * 锁的边界（2026-09-17）：**HTTP 调用不在锁内**。
 *   本函数只做两件事：进门前拿一次一致快照判断"要不要登录"、出门前**整体提交**结果。
 *   中间那段网络 IO（登录一次 ~400 ms，NT 上还可能等到超时）不持锁 —— 否则一个卡住的
 *   club-server 会把 /api/club/config 这种只读配置的接口一起拖住（而它们只需要 ops.clubCreds()，
 *   根本不是同一把锁）。代价是**并发首次登录可能重复发一次**，这与改动前完全一样（原先连快照都没有），
 *   但不是新引入的问题；真要收口应该做成"单飞"（single-flight），那是独立的一轮改动。
 *   顺带一个行为改善：force 续期期间，读方看到的是**上一次的完整会话**，而不是"token 为空"的中间态。
 */
func clubSessionEnsure(cfg: OpsConfig, sess: ClubSession, force: Bool): Unit {
    let now = nowEpoch()
    if (!force) {
        let cur = sess.view()
        if (cur.token.size > 0 && now - cur.at < OPS_SESSION_TTL) {
            return
        }
    }
    /* 一致快照：手机号与口令必须成对（见 OpsConfig.clubCreds 的注释） */
    let (clubUser, clubPass) = cfg.clubCreds()
    let url = opsJoin(cfg.apiBase, "api/v1/auth/login")
    let body = JsonObject()
    jPutStr(body, "phone", clubUser)
    jPutStr(body, "password", clubPass)
    match (clubHttpPostJson(url, body.toString())) {
        case Some(text) =>
            var token = ""
            var name = ""
            var role = ""
            var phone = ""
            try {
                let root = JsonValue.fromStr(text).asObject()
                match (jsonGetObject(root, "data")) {
                    case Some(d) =>
                        token = jsonGetStr(d, "token") ?? ""
                        match (jsonGetObject(d, "member")) {
                            case Some(m) =>
                                name = jsonGetStr(m, "name") ?? ""
                                role = jsonGetStr(m, "role") ?? ""
                                phone = jsonGetStr(m, "phone") ?? ""
                            case None => ()
                        }
                    case None => ()
                }
            } catch (e: Exception) {
                token = ""
            }
            if (token.size == 0) {
                sess.markFailed("club-server 的登录响应看不懂（版本不匹配？）")
                return
            }
            /* 登录响应里的 member 是"简报"（不含手机号），手机号以配置为准 */
            sess.commit(token, now, name, role, clubUser, "")
        case None =>
            /* 区分"连不上"与"凭据不对" —— 两类问题的处置完全不同 */
            match (clubHttpGet(opsJoin(cfg.apiBase, "health"))) {
                case Some(_) => sess.markFailed("运维账号凭据被拒绝：club_user=${clubUser}（口令错？账号刚 init-ops 但 club-server 没重启？被 retire-ops 停用？）")
                case None =>
                    /*
                     * 2026-09-17：https:// 必须单独说清楚，否则会把人带到完全错误的方向。
                     *
                     * 本文件的 clubHttpPostJson / clubHttpGet 用的是 noProxy 客户端，**没有 TLS 配置**
                     * （httpclient.cj 的文件头就写着"需要 TLS 请直接用 stdx.net.http.Client"），
                     * 而 club-server 用的又是自签证书 —— 两者叠加必然连不上。
                     * 实测：club_api=https://127.0.0.1:8443 时落到这里，但服务其实**好好起着**，
                     * 原先那句"没起？"是错的诊断。
                     */
                    if (startsWithAscii(cfg.apiBase.toAsciiLower(), "https://")) {
                        sess.markFailed("运维台连不上 HTTPS 的 club-server：${cfg.apiBase}。" +
                            "出站客户端没有 TLS 配置，自签证书也过不了校验 —— " +
                            "请让 club-server 另以**明文 HTTP** 起一个本机端口（如 serve 8080），" +
                            "把 club_api 指向它，并用防火墙限制该端口的来源。")
                    } else {
                        sess.markFailed("连不上 club-server：${cfg.apiBase}（没起？地址/端口在 admin.env 里改）")
                    }
            }
    }
}

/*
 * ② 运维账号登录：把手机号 + 口令转发给 club-server 校验（它才是口令的权威）。
 *
 * 通过且 `role = ops` → 签发主体为 **`ops:<手机号>`** 的 JWT，并把**这次输入的凭据留在
 * 内存里**（ops.clubUser / ops.clubPass），于是 /api/club/session 当场就能换到令牌 ——
 * 不必再手工往 admin.env 填 club_user / club_pass。
 * admin.env 里若配了凭据，则作为"没用运维账号登录时"的回退，行为与之前完全一致（向后兼容）。
 *
 * 凭据只在本进程内存里，不落盘、不回显；进程重启后需要重新登录一次
 * （admin.env 里配了的话则不受影响）。
 */
func opsLoginViaClub(ctx: Context, phone: String, password: String,
                     ops: OpsConfig, clubSess: ClubSession, secret: String, ttl: Int64): Unit {
    /*
     * 回环不参与节流（与 club-server 的**注册口令**节流同口径，见 opsThrottleKey 的注释）：
     * 本机调用者本来就有更高权限，而且本项目的测试脚本都从本机打 —— 否则跑几轮测试就把自己锁 15 分钟。
     * 键算法统一在 opsThrottleKey()（两条登录分支共用，见那里的注释）。
     */
    let ip = opsThrottleKey(ctx)
    if (opsLoginGuard.locked(ip)) {
        opsThrottleRejected(ctx)
        return
    }
    let url = opsJoin(ops.apiBase, "api/v1/auth/login")
    let body = JsonObject()
    jPutStr(body, "phone", phone)
    jPutStr(body, "password", password)
    var token = ""
    var name = ""
    var role = ""
    var mphone = ""
    match (clubHttpPostJson(url, body.toString())) {
        case Some(text) =>
            try {
                let root = JsonValue.fromStr(text).asObject()
                match (jsonGetObject(root, "data")) {
                    case Some(d) =>
                        token = jsonGetStr(d, "token") ?? ""
                        match (jsonGetObject(d, "member")) {
                            case Some(m) =>
                                name = jsonGetStr(m, "name") ?? ""
                                role = jsonGetStr(m, "role") ?? ""
                                mphone = jsonGetStr(m, "phone") ?? ""
                            case None => ()
                        }
                    case None => ()
                }
            } catch (e: Exception) {
                token = ""
            }
        case None => ()
    }
    if (token.size == 0) {
        opsLoginGuard.note(ip, false)
        opsErr(ctx, 401, 401, opsLoginDiagnosis(ops, phone))
        return
    }
    if (role != "ops") {
        /*
         * 口令是对的、只是这一档身份不对 —— **不清**该来源的失败记录（2026-09-18 修）。
         *
         * 原先这里 `note(ip, true)` 会 `tbl.remove(ip)`，而**任意在册成员/会长/副会长**的
         * 手机号 + 口令都能走到这里（club-server 登录已返回非空 token）。于是攻击者只要用
         * 自己的社团账号成功登录一次，就能把两条分支共用的失败桶清零，从而对本地 `admin`
         * 口令无限次猜 —— 这恰好是 8a9e11c 想堵的"4 次猜 + 1 次成功"循环，只是把
         * "合法后台账号"换成了"任意社团账号"。
         * 清零只应发生在**真正的运维身份**上（即下面 role == "ops" 之后的 note(ip, true)）。
         */
        opsErr(ctx, 403, 403, "该账号的角色是「${clubRoleLabel(role)}」，不是运维账号。" +
            "运维台只接受 `club-server init-ops` 建的运维账号（运维不该由会长执行）；" +
            "会长 / 成员账号请在 App 里登录。")
        return
    }
    opsLoginGuard.note(ip, true)
    /*
     * 这次输入的运维凭据留给运维会话用（仅内存），于是不必再手改 admin.env。
     * 两处写入都走"整体替换"入口（2026-09-17）：凭据是一对、会话是一组，读方
     * （/api/club/config、/api/club/session、clubSessionEnsure）不能看到半成品组合 ——
     * 理由见 OpsConfig / ClubSession 的注释。
     */
    ops.setClubCreds(phone, password)
    /* 登录响应里的 member 是简报、可能不含手机号，以登录时输入的手机号为准 */
    clubSess.commit(token, nowEpoch(), name, role,
        if (mphone.size > 0) { mphone } else { phone }, "")
    println("[ops] 运维账号 ${phone} 已登录运维台（后续写操作以它的身份发出）")
    let o = JsonObject()
    jPutStr(o, "token", issueTokenTtl(opsSubjectOf(phone), secret, ttl))
    opsOk(ctx, o)
}

/*
 * 社团库读取（2026-09-20 换了数据源，**视图逻辑一行未动**）。
 *
 * 原先：每个请求 `storeLoad(dataDir)` —— 现读现解析 club-server 写出的 db.json。
 * 现在：club-server 的持久化已整体换成 MySQL（路线 B，见
 *       server\src\mysql_store.cj 与 docs\club-server-mysql-assessment.md），
 *       `data/db.json` 不再是真相来源，所以这里改成**从 MySQL 全量载入**，
 *       复用 club-server 那份载入代码（storeLoadDb）—— 两个进程共用同一套
 *       *FromJson 映射，"运维页看到的字段"与"服务端认的字段"不可能漂移。
 *
 * `dataDir` 仍要传：它现在只用于**审计日志**（clubAuditLines 读 `${s.dir}/audit.log`），
 * 而审计日志本来就是 club-server 写在文件里的（不在这 7 张表里）。
 *
 * 每请求现连现载（社团库是 KB~MB 级、运维台访问频率极低），换取"永远最新"，
 * 与原先"每请求现读文件"的开销特征一致；连接用完即关，不额外持有连接池。
 *
 * ⚠ **因此这个 Store 只能读**：`ms` 在 finally 里就关掉了，而 storeLoadDb 已经把
 *   它挂进了返回值的 `s.mysql` —— 今后谁要是对这里的 `s` 调 `storeSave` / `storeSaveNow`，
 *   会拿一条**已关闭的连接**去写（运行时抛驱动异常）。视图函数（club_view.cj 那一组）
 *   本来就是只读的，这也是"运维台绝不代写"那条设计的落点：写一律走 club-server 的 HTTP 接口。
 *
 * ⚠ 另一处已知的浪费（不是 bug，但别误判成"库被锁"）：`ensureSchema` 每次请求都会发
 *   9 条 `CREATE TABLE IF NOT EXISTS`。DDL 要取元数据锁，理论上会和 club-server 的写入
 *   抢一下；运维页访问频率极低，暂不为它加"进程内只做一次"的状态。
 */
func withClub(ctx: Context, ops: OpsConfig, mysqlPass: String, dataDir: String,
              f: (Store) -> JsonValue): Unit {
    var st: ?Store = None
    try {
        let mcfg = MySqlConfig()
        mcfg.host = ops.mysqlHost
        mcfg.port = ops.mysqlPort
        mcfg.user = ops.mysqlUser
        mcfg.pass = mysqlPass
        /* 库名先过一遍标识符白名单（与 club-server 用的是同一个函数 dbNameChecked）：
         * 这里只用它建连、不会把它拼进 SQL，但校验一次能让"admin.env 里把库名写错/带了引号"
         * 当场报出一句中文，而不是抛一个难懂的驱动异常。
         * ⚠ 原文的注释写着"库名过同一份白名单"，而代码当时并没有真的调用它 —— 属于
         *   "注释说了、代码没做"，2026-09-20 补齐（注释与代码不一致本身就是缺陷）。 */
        mcfg.db = dbNameChecked(ops.clubMysqlDb)
        let ms = MysqlStore(mcfg)
        try {
            ensureSchema(ms)     /* 幂等：库是 club-server 建的，这里只是保证首次访问不炸 */
            st = Some(storeLoadDb(ms, dataDir))
        } finally {
            ms.close()
        }
    } catch (e: Exception) {
        /*
         * 读不到社团库时，**把最常见的那个原因直接点出来**（2026-09-20 补）。
         *
         * 实测踩到：admin.env 的 `club_mysql_db` 与 club-server 实际用的库名不一致
         * （老模板写的是 `club`，而 club-server 的默认是 `club_server`），
         * 运维页一打开就是一句 `Unknown database 'club'` —— 看不出"这是库名对不上"，
         * 更像是数据库没起来。所以这里顺带查一次 information_schema，把**这台实例上
         * 现有的 club_* 库列出来**，让人一眼看到"哦，应该填 club_server"。
         * ⚠ 这一步是纯提示，自己失败也**不能**影响原来的报错（整体 try 包住）。
         */
        let hint = clubDbNameHint(ops, mysqlPass)
        opsErr(ctx, 500, 500, "社团库（MySQL）无法读取：${e.message}" + hint)
        return
    }
    match (st) {
        case Some(s) => opsOk(ctx, f(s))
        case None => opsErr(ctx, 500, 500, "社团库未加载")
    }
}

/*
 * 社团库读不到时的"库名提示"：把这台实例上现有的 `club%` 库列出来，并指出当前配的是哪个。
 *
 * 为什么值得做：`club_mysql_db`（后台）与 club-server 的 DSN 库名是**两处**配置，
 * 写得不一致时唯一的现象就是一句 `Unknown database 'xxx'` —— 那看起来像"数据库没起来"，
 * 而不像"名字写错了"。实测踩到的正是这个：模板写 `club`，而 club-server 用 `club_server`。
 * 这里主动把候选端出来，一次就能对上号。
 * ⚠ 纯 best-effort：连不上/没权限/查询失败一律返回空串，**绝不影响**原本那条错误。
 */
func clubDbNameHint(ops: OpsConfig, pass: String): String {
    let names = ArrayList<String>()
    try {
        let cfg = MySqlConfig()
        cfg.host = ops.mysqlHost
        cfg.port = ops.mysqlPort
        cfg.user = ops.mysqlUser
        cfg.pass = pass
        cfg.db = ""     /* 只查 information_schema，不指定库名（与 ensureDatabase 的探测同一手法） */
        let ms = MysqlStore(cfg)
        try {
            let rs = ms.q("SELECT schema_name FROM information_schema.schemata" +
                " WHERE schema_name LIKE 'club%' ORDER BY schema_name", Array<DbValue>())
            var i: Int64 = 0
            while (i < rs.rowCount()) {
                names.add(rs.cell(i, 0))
                i += 1
            }
        } finally {
            ms.close()
        }
    } catch (e: Exception) {
        return ""
    }
    if (names.size == 0) {
        return "\n  ⚠ 这台实例上**没有任何 club 开头的库** —— 先在 club-server 那边跑一次 " +
            "init-admin（它会自动建库），或确认 admin.env 的 mysql_host/mysql_port 连的是同一台。"
    }
    return "\n  ⚠ 这台实例上现有的 club* 库是：" + String.join(names.toArray(), delimiter: "、") +
        "；而 admin.env 的 club_mysql_db=" + ops.clubMysqlDb +
        " —— 两者必须是**同一个**（club-server 的默认库名是 club_server，用 DSN 时以 DSN 里的为准）。"
}

/* ===================== 运维台自己的权限闸门 ===================== */
/*
 * 「/api/club/…」放给两种身份：
 *   · 后台的 admin 角色（roleId == 1）—— 上游那套；
 *   · **运维账号登录**的身份（JWT 主体 `ops:<手机号>`，2026-09-17 起）—— 它本来就是
 *     这个页面的主人，用 init-ops 建的账号直接登进来时走这一支。
 * 上游的 requirePermission 是按"路径 → 权限码"配的，运维接口不在它的表里，
 * 所以这里按角色 / 主体形态判定；登录态已由 authRequired 保证（主体在 ctx.state）。
 */
func requireClubOps(store: RbacStore): Middleware {
    return { ctx: Context, next: () -> Unit =>
        let p = ctx.path()
        let isClub = p.size >= 10 && p[0..10] == "/api/club/"
        if (!isClub) {
            next()
            return
        }
        match (opsPhoneOfSubject(ctx.getStateOr("userId", ""))) {
            case Some(_) =>
                next()
                return
            case None => ()
        }
        var uid: Int64 = 0
        try {
            uid = Int64.parse(ctx.getStateOr("userId", "0"))
        } catch (e: Exception) {
            uid = 0
        }
        match (store.findUserById(uid)) {
            case Some(u) =>
                if (u.roleId == 1) {
                    next()
                } else {
                    opsErr(ctx, 403, 403, "forbidden: 运维页仅限 admin 角色或运维账号")
                }
            case None =>
                opsErr(ctx, 401, 401, "unauthorized")
        }
    }
}

/* ===================== 入口 ===================== */

main(args: Array<String>): Int64 {
    /*
     * ⚠ admin.exe **不接受任何命令行参数**：连接参数、端口、密钥全部来自 admin.env。
     *
     * 为什么要显式警告（2026-09-20 实测踩到）：
     *   club-server 是 `club-server <子命令> ... <DSN>` 那种吃位置参数的形态，
     *   于是很自然地会照着写 `admin.exe "mysql://root:pw@127.0.0.1:3307/club_server"` ——
     *   而 `main()` 根本收不到它（仓颉里不声明 args 就拿不到 argv），参数被**静默忽略**，
     *   面板照 admin.env 去连它自己的库（club_rbac），报出来的却是一句
     *   "Unknown database 'club_rbac'"，让人以为是连接串写错了。
     *   这里把"你给的参数没用、请改 admin.env"直接说出来。
     */
    if (args.size > 0) {
        println("[admin] ⚠ 本程序**不接受命令行参数**，下面这些已被忽略：")
        /* 参数可能是误传的 DSN，里面含数据库口令；只报数量，绝不回显原值。 */
        println("[admin]      已忽略 ${args.size} 个参数（参数值不写入日志）")
        println("[admin]    连接参数请写进 ./admin.env 的 mysql_host / mysql_port / mysql_user /")
        println("[admin]    mysql_pass / mysql_db（社团库是 club_mysql_db）。")
        println("[admin]    例：mysql://root:口令@127.0.0.1:3307/club_server 要拆成 mysql_host=127.0.0.1")
        println("[admin]        mysql_port=3307  mysql_user=root  mysql_pass=口令")
        println("[admin]    （club-server 才吃 DSN 位置参数；两者形态不同，别照抄。）")
    }

    /* ---------- 配置外置（复用 config.cj 的 .env 加载） ---------- */
    let envPath = "./admin.env"
    let cfg = loadConfigFile(envPath)
    let port = parseUInt16Or(cfg.getOr("port", "3000"), 3000)
    let ttl = cfg.getIntOr("ttl", 7200)
    let secret = match (cfg.get("secret")) {
        case Some(s) => s
        case None =>
            let r = randomHex(32)
            println("[admin] 警告：admin.env 未配置 secret，使用随机值（重启后所有 token 失效）")
            r
    }

    let ops = OpsConfig()
    ops.dataDir = cfg.getOr("club_data", "../data")
    ops.apiBase = cfg.getOr("club_api", "http://127.0.0.1:8080")
    ops.clubPort = cfg.getIntOr("club_port", 8080)
    /*
     * 「运维页备份」本来就落社团库**备份**的目录，与 RBAC 走文件还是 MySQL 无关；
     * 2026-09-19 之前它是从 RBAC 数据文件的路径推出来的（opsDirOf(dbPath)），
     * 现在 RBAC 没有文件了，就直接给个固定值（可以用 admin.env 的 admin_data 覆盖）。
     */
    ops.adminDataDir = cfg.getOr("admin_data", "admin-data")
    /* 下面 5 个只是回显用（/api/club/config）；真正建连见 rbacs 那段 —— 两处读的是同一份 cfg */
    ops.mysqlHost = cfg.getOr("mysql_host", "127.0.0.1")
    ops.mysqlPort = cfg.getIntOr("mysql_port", 3306)
    ops.mysqlUser = cfg.getOr("mysql_user", "root")
    ops.mysqlDb = cfg.getOr("mysql_db", "club_rbac")
    ops.clubMysqlDb = cfg.getOr("club_mysql_db", "club_server")
    /* 一次写一对（见 OpsConfig.setClubCreds 的注释）：admin.env 里没配就是两个空串，
     * 此时运维页仍可用"运维账号登录"这条路走通（见文件上方"运维身份"整段）。 */
    ops.setClubCreds(cfg.getOr("club_user", ""), cfg.getOr("club_pass", ""))
    /* 运维会话（内存缓存）：后台用它以**运维账号**的身份调 club-server */
    let clubSess = ClubSession()

    /* ---------- 后台自己的 RBAC 库（**MySQL**，2026-09-19 起） ----------
     * 数据层 = 框架 src\store.cj 的 RbacStore(db) + src\db_mysql.cj 的 MySqlBackend。
     * 驱动是内置的 third_party\mariadb-driver（运行时按注册名 "mariadb" 查找，所以
     * db_mysql.cj 编译期零驱动依赖）；构建脚本负责把它链进来，缺了会在 build.ps1 就报错。
     *
     * N-29（2026-09-17 修，2026-09-19 迁移时必须保留）：种子口令**不得**是写死的
     * admin123 / user123。框架 RbacStore 的构造在首次打开时会自动建表 + 灌种子，
     * 而它灌的就是那对公开默认口令（third_party\qingzhou\src\store.cj:104-111）——
     * 当年写 fw_rbac_store.cj 时正是把这一步换成了"随机生成 + 写回 admin.env"，
     * 切到 MySQL 之后那段语义**必须原样搬过来**（框架 RbacStore 没有改口令的方法，
     * 所以是 deleteUser + createUser 重建，见下）。
     *
     * 判定"是不是新库"必须在**构造之前**：框架构造完就把种子灌进去了，
     * 那时再查就只能看到 admin123 的哈希、分不清"原本就空"和"刚被灌了默认值"。
     * 表还不存在时 query 会抛（MySQL 的 SELECT 打到不存在的表 = 1146），按新库处理；
     * ⚠ "连不上"不在这里兜 —— MySqlBackend 的**构造函数**就会抛（建连失败），
     *   走到这一步说明连接已经建立，所以查询失败只剩"表不存在"这一类原因。
     */
    let mysqlHost = cfg.getOr("mysql_host", "127.0.0.1")
    let mysqlPort = cfg.getIntOr("mysql_port", 3306)
    let mysqlUser = cfg.getOr("mysql_user", "root")
    let mysqlPass = cfg.getOr("mysql_pass", "")
    let mysqlDb = cfg.getOr("mysql_db", "club_rbac")
    println("[admin] RBAC 数据层：MySQL ${mysqlUser}@${mysqlHost}:${mysqlPort}/${mysqlDb}（库不存在会自动建，表由启动时自动建）")
    /*
     * 库不存在就**先建**（2026-09-20 补）。
     *
     * 原先这里直接 `MySqlBackend(...)`，而它的连接串里带 database —— 库不存在时**建连就失败**，
     * 报 `Unknown database 'club_rbac'`。于是"清空数据/换一台 MySQL 后第一次起面板"必须先
     * 手工敲一句 CREATE DATABASE，而 club-server 那边早就自动建库了（ensureDatabase），
     * 两者行为不一致、文档也只在 admin.env 的注释里提了一句。实测踩到：
     * 清理仓库把 club_* 全 DROP 之后，`admin.exe` 直接起不来。
     * 现在与 club-server 用**同一个** ensureDatabase（dbNameChecked 白名单也一并复用）。
     * ⚠ 账号没有 CREATE 权限时会失败 —— 那时**不吞**，打印原因并给出手工建库语句，
     *   随后仍会走到下面的 MySqlBackend，由它抛出那句带完整处置的错（信息不丢）。
     */
    let rbacCfg = MySqlConfig()
    rbacCfg.host = mysqlHost
    rbacCfg.port = mysqlPort
    rbacCfg.user = mysqlUser
    rbacCfg.pass = mysqlPass
    rbacCfg.db = mysqlDb
    try {
        ensureDatabase(rbacCfg)
    } catch (e: Exception) {
        println("[admin] ⚠ 自动建库失败：${e.message}")
        println("[admin]    若库已存在可忽略；否则请手工建一次：" +
            "CREATE DATABASE ${mysqlDb} CHARACTER SET utf8mb4;")
    }
    let rbacs = try {
        MySqlBackend(mysqlHost, mysqlPort, mysqlUser, mysqlPass, mysqlDb)
    } catch (e: Exception) {
        throw Exception("连不上 MySQL（${mysqlHost}:${mysqlPort}/${mysqlDb}）：${e.message}。" +
            " 处置：① 服务器起着吗（netstat -ano | findstr :${mysqlPort}）；" +
            "② admin.env 的 mysql_host/mysql_port/mysql_user/mysql_pass/mysql_db 对不对" +
            "（⚠ 口令留空 = 无口令，症状是连不上）；" +
            "③ 库建了吗（正常会自动建，失败时手工来一次：CREATE DATABASE ${mysqlDb} CHARACTER SET utf8mb4;）。" +
            " 详见 docs\\mysql-backend.md。")
    }
    var freshDb = false
    try {
        freshDb = (rbacs.query("SELECT * FROM users").rowCount() == 0)
    } catch (e: Exception) {
        freshDb = true
    }
    let store = RbacStore(rbacs)
    /* 用户可能自己在 admin.env 里指定了口令（那时 freshDb 为 true 也不换） */
    let adminPassCfg = cfg.getOr("admin_pass", "")
    let userPassCfg = cfg.getOr("user_pass", "")
    if (freshDb) {
        /*
         * 新库：框架刚建表并灌了 admin/admin123、user/user123 两条种子 —— 立刻换成随机口令。
         * 生成方式**照抄 fw_rbac_store.cj 的 seed()**：randomHex(8) = 16 个十六进制字符，
         * 哈希同盐同轮数（security.cj 的 hashPassword(pw, "qz2026", 1000)），口径保持一致。
         * 先 delete 再 create 而不是 update：框架 RbacStore 没有改口令的方法，
         * 而删掉之后 nextUserId() = max(id)+1 会把 id 正好补回 1 / 2 —— 登录与
         * requirePermission 依赖的 id↔账号对应关系不变（admin 的 id 必须还是 1）。
         */
        let adminPass = if (adminPassCfg.size > 0) { adminPassCfg } else { randomHex(8) }
        let userPass = if (userPassCfg.size > 0) { userPassCfg } else { randomHex(8) }
        store.deleteUser(1)
        store.deleteUser(2)
        store.createUser("admin", hashPassword(adminPass, "qz2026", 1000), 1)
        store.createUser("user", hashPassword(userPass, "qz2026", 1000), 2)
        /* 落到 admin.env：只打印一次，不回显旧口令（这是 N-29 的核心动作） */
        persistSeedCreds(envPath, adminPass, userPass)
        println("")
        println("========================================================")
        println("  首次启动：已为后台账号生成随机口令（只显示这一次）")
        println("    admin  口令  ${adminPass}")
        println("    user   口令  ${userPass}")
        println("  已写入 ${envPath} 的 admin_pass / user_pass，请妥善保管。")
        println("  （种子默认口令 admin123 / user123 已被覆盖，本库用它们登录会被拒。）")
        println("========================================================")
        println("")
    } else {
        /*
         * 不是新库 —— 但**仍然**要检查一遍种子账号是不是那对公开默认口令。
         * 为什么保留这一条：它是从文件后端时代传下来的"旧库告警"。放到 MySQL 语境下有两个
         * 真实场景会命中它：① 手工往库里灌过框架种子（或直接跑过上游示例）；
         * ② 有人把 admin_pass 显式配成 admin123 之后的库。
         * 命中了就**醒目**说出来，别让它悄悄留在生产里。
         */
        var legacySeed = false
        match (store.findUserByUsername("admin")) {
            case Some(u) =>
                if (verifyPassword("admin123", u.passwordHash)) {
                    legacySeed = true
                }
            case None => ()
        }
        match (store.findUserByUsername("user")) {
            case Some(u) =>
                if (verifyPassword("user123", u.passwordHash)) {
                    legacySeed = true
                }
            case None => ()
        }
        if (legacySeed) {
            println("  ⚠ 后台仍在用**公开的默认口令**（admin123 / user123）。请立刻处置（任选其一）：")
            println("      · 删掉库里那两个账号（DELETE FROM users;）后重启 —— 会重新生成随机口令并写回 admin.env；")
            println("      · 或把 admin.env 的 admin_pass / user_pass 改成自己的值，删库重建。")
        } else {
            println("  后台口令见 admin.env 的 admin_pass / user_pass（首次启动时打印过一次，不再回显）")
        }
    }

    let shutdownFlag = OpsShutdownFlag()
    let bootEpoch = nowEpoch()

    /* ---------- 公开路由：登录，签发标准 JWT（带 exp） ---------- */
    let publicRouter = Router()
    publicRouter.passOnNotFound = true
    /*
     * 登录：两种凭据都接受（见文件上方"运维身份"整段说明）。
     *   ① 后台自己的账号（轻舟 RBAC）—— 与上游一致；
     *   ② 不是后台账号时，当作 club-server 的**运维账号**（手机号）转发过去校验。
     * ① 与 ② 的失败信息分开写，避免把"用户名打错了"和"club-server 没起"混成一句。
     *
     * ⚠ 两条分支**共用同一张节流表**（2026-09-17 修）：
     *   原先只有分支 ② 走 OpsLoginGuard，分支 ① 失败时直接 `opsErr(401)` 走人 ——
     *   于是**本地后台账号（admin / user）可以被无限次猜口令**：登录框里打一个后台用户名，
     *   失败一万次也不会在节流表里留下任何一笔，而这张表存在的全部理由就是拦住猜口令。
     *   （分支 ② 之所以早就加了，是因为它有"未认证就能让 club-server 烧 10 万次 PBKDF2"
     *   这个更显眼的问题；分支 ① 的 verifyPassword 只有 1000 轮，看着"便宜"，但**猜口令本身就是
     *   攻击面**，便宜不等于可以对无限次尝试敞开。）
     *
     *   统一口径（逐条与分支 ② 的既有语义对齐，**只有一处例外**）：
     *     · 校验**之前**先看 locked()：锁定期内连口令都不验（否则锁只挡住了"通过"，
     *       没挡住 CPU 消耗与计时侧信道）；
     *     · 失败 → note(ip, false)（窗口内递增，达阈值锁 15 分钟）；
     *     · 成功 → 分支 ② note(ip, true)（立即清零，因为它要求先拿出**运维口令**）；
     *       分支 ① **不清零**（见 /api/login 里的长注释：只要有任意一个合法后台账号
     *       就能靠"成功一次"把计数器压回阈值以下，从而无限次猜 admin）。
     *     · 键用 opsThrottleKey()：回环来源折成空串、**不参与节流**（与分支 ② 完全一致，
     *       否则本机测试脚本跑几轮就把自己锁 15 分钟）；
     *     · 429 的回执文案也共用 opsThrottleRejected()。
     *   注意"统一"的连带影响是**有意的**：一个来源在两条分支上共用同一个桶，
     *   所以拿本地用户名刷失败次数，也会同时把这个来源的运维账号登录一起锁上 ——
     *   这正是"同一个来源的登录尝试"应有的语义（攻击者不该靠换用户名格式换一个桶）。
     */
    publicRouter.post("/api/login", { ctx: Context, _: () -> Unit =>
        let username = bodyStrOr(ctx, "username", "")
        let password = bodyStrOr(ctx, "password", "")
        /*
         * 字段长度上限（2026-09-18 补）：本闸门在 opsBodyLimit 之后，body 已经进了内存
         * （整份 body 由它兜在 64 KiB 以内），这里只是不让超长字段进
         * findUserByUsername() 的线性扫描、hashPassword() 与转发给 club-server 的请求体。
         * 放在节流之前：它**不消耗**失败次数 —— 长度不合法是请求本身有问题，
         * 与"猜口令"不是一回事（也不该让攻击者靠发超长字段把正常来源刷进 15 分钟锁定）。
         */
        if (username.size > OPS_LOGIN_FIELD_MAX || password.size > OPS_LOGIN_FIELD_MAX) {
            opsErr(ctx, 400, 400, "username/password 过长（各上限 ${OPS_LOGIN_FIELD_MAX} 字节）")
            return
        }
        match (store.findUserByUsername(username)) {
            case Some(u) =>
                let ip = opsThrottleKey(ctx)
                if (verifyPassword(password, u.passwordHash)) {
                    /*
                     * 成功：**直接放行**，不因"该来源已被锁"而拒掉正确口令（2026-09-18 修）。
                     *
                     * 原先 locked() 排在验口令之前，于是第三方只要连打 5 次错口令，就能让
                     * 合法管理员在**同一出口 IP** 上 15 分钟进不去（到期再打 5 次即可续期）。
                     * 这个副作用正是 24b4d02 以"NAT / 校园网出口会把整个社团一起锁在门外"
                     * 为由、把 club-server 的按 IP 登录节流移掉的那种伤害。
                     *
                     * 本分支的账号口令是 admin.env 首次启动时随机生成的 16 位十六进制（2^64），
                     * 爆破不可行 —— 所以这里**不需要**用"连正确口令一起拒"来换强度。
                     * 失败仍照常记账，锁定只作用于失败路径（见 else 分支）。
                     * 分支 ②（运维账号，口令由人设定、强度不可控）保留验口令**之前**的拦截，
                     * 见 opsLoginViaClub 的 locked() 检查。
                     *
                     * 仍然**不清零**失败计数：防"猜 4 次 + 用另一个合法凭据成功 1 次"的循环。
                     */
                    let token = issueTokenTtl(u.id.toString(), secret, ttl)
                    /* 前端 api.js 取的是 data.token（与上游一致） */
                    let o = JsonObject()
                    jPutStr(o, "token", token)
                    opsOk(ctx, o)
                } else {
                    if (opsLoginGuard.locked(ip)) {
                        opsThrottleRejected(ctx)
                        return
                    }
                    opsLoginGuard.note(ip, false)
                    opsErr(ctx, 401, 401, "invalid credentials")
                }
            case None =>
                opsLoginViaClub(ctx, username, password, ops, clubSess, secret, ttl)
        }
    })

    /* ---------- 登录即可访问 ---------- */
    let authRouter = Router()
    authRouter.passOnNotFound = true
    authRouter.get("/api/me", { ctx: Context, _: () -> Unit =>
        let subject = ctx.getStateOr("userId", "")
        /*
         * 运维账号登录：身份不在后台的 rbac.json 里，所以 id 恒为 0。
         * can_ops = true 让前端放行运维页；后台管理接口（用户 / 角色 / 权限）由 framework 的
         * requirePermission 按数字 userId 判定 —— 运维身份拿不到权限，因此仍是 admin 专属。
         */
        match (opsPhoneOfSubject(subject)) {
            case Some(phone) =>
                let oo = JsonObject()
                jPutInt(oo, "id", 0)
                jPutStr(oo, "username", phone)
                jPutStr(oo, "role", "ops")
                jPutBool(oo, "can_ops", true)
                jPutBool(oo, "is_ops_account", true)
                opsOk(ctx, oo)
                return
            case None => ()
        }
        var userId: Int64 = 0
        try {
            userId = Int64.parse(subject)
        } catch (e: Exception) {
            userId = 0
        }
        match (store.findUserById(userId)) {
            case Some(u) =>
                let o = JsonObject()
                jPutInt(o, "id", u.id)
                jPutStr(o, "username", u.username)
                jPutStr(o, "role", store.roleNameOf(u.roleId))
                jPutBool(o, "can_ops", u.roleId == 1)
                opsOk(ctx, o)
            case None =>
                opsErr(ctx, 401, 401, "unauthorized")
        }
    })
    authRouter.get("/api/dashboard", { ctx: Context, _: () -> Unit =>
        let o = JsonObject()
        let stats = JsonObject()
        jPutInt(stats, "users", store.listUsers().size)
        jPutInt(stats, "roles", store.listRoles().size)
        o.put("stats", stats)
        opsOk(ctx, o)
    })

    /* ---------- 管理路由：后台用户 / 角色 / 权限（上游那套，保持不动） ---------- */
    let mgmtRouter = Router()
    mgmtRouter.passOnNotFound = true
    mgmtRouter.get("/api/users", { ctx: Context, _: () -> Unit =>
        let arr = JsonArray()
        for (u in store.listUsers()) {
            let o = JsonObject()
            jPutInt(o, "id", u.id)
            jPutStr(o, "username", u.username)
            jPutStr(o, "role", store.roleNameOf(u.roleId))
            arr.add(o)
        }
        opsOk(ctx, arr)
    })
    mgmtRouter.post("/api/users", { ctx: Context, _: () -> Unit =>
        let username = bodyStrOr(ctx, "username", "")
        let password = bodyStrOr(ctx, "password", "")
        let roleId = match (bodyInt64(ctx, "roleId")) {
            case Some(r) => r
            case None => Int64(2)
        }
        if (username.size == 0 || password.size == 0) {
            opsErr(ctx, 400, 400, "username and password required")
            return
        }
        /*
         * 重名拒绝（2026-09-17 修；2026-09-19 换到框架 RbacStore 后**收成一道**）。
         *
         * 同名两个用户的害处：findUserByUsername() 取**首个匹配** —— 在文件后端是 HashMap 的
         * 遍历顺序（不确定），在 MySQL 后端是返回行的顺序（同样不是"你刚建的那个"）：
         * 后建的那个可能**永远登不进去**（而它明明出现在用户列表里、还能被单独删除）。
         * 这不是"多一条脏数据"，而是"账号看着存在、行为随机"。
         *
         * ⚠ 这一道现在承担**全部**责任，必须有：框架的 RbacStore.createUser() 既不校验重名、
         *   也不抛异常（store.cj 的注释就把"username 唯一性由调用方保证"写明了），
         *   所以下面的 catch 里**不能**再靠"抛没抛"来判重名 —— 那里只剩"SQL 执行失败"一种可能。
         *   （我们的 fw_rbac_store.cj 有 usernameTaken() 且会抛，框架这份没有，这是两实现
         *   已知的一处语义差；club-server 仍走前者，admin 走后者。）
         */
        if (store.findUserByUsername(username).isSome()) {
            opsErr(ctx, 400, 400, "username already exists: ${username}")
            return
        }
        let hash = hashPassword(password, "qz2026", 1000)
        /*
         * 剩下的失败只有**数据库层面**那一类（连不上 / SQL 错 / 表被改坏）——
         * 如实报 500，别再把它说成"重名"（那会让人一遍遍换名字重试）。
         *
         * 运行时异常会穿透 handler、被链上 passOnNotFound 留下的 404 壳吃掉
         * （见下面 /api/users/:id 的实测记录），所以这里必须自己 try 住。
         */
        var id: Int64 = 0
        try {
            id = store.createUser(username, hash, roleId)
        } catch (e: Exception) {
            opsErr(ctx, 500, 500, "创建用户失败（数据库错误）：${e.message}")
            return
        }
        let o = JsonObject()
        jPutInt(o, "id", id)
        jPutStr(o, "username", username)
        opsOk(ctx, o)
    })
    mgmtRouter.delete("/api/users/:id", { ctx: Context, _: () -> Unit =>
        /*
         * 路径参数必须自己 try 住（2026-09-17 修）：
         * `Int64.parse("abc")` 抛的是**运行时异常**，它会穿透 handler、一路穿到链尾的 opsErrorHandler。
         *
         * ⚠ 而 opsErrorHandler 只在"ctx.status == 200 且 body 为空"时才补我们的 `{code,message,data}` 壳 ——
         *   本链里排在 mgmtRouter **之前**的 publicRouter / authRouter 都是 passOnNotFound，它们 miss 时
         *   **已经往 ctx 写了 404 + `{"error":"Not Found","path":"..."}`**，于是那个判断为假、
         *   异常只被 ctx.trace 记一行，**那个 404 body 会原样发给客户端**。
         *   实测（修前，真机跑）：
         *     DELETE /api/users/abc -> HTTP 404  body={"error":"Not Found","path":"/api/users/abc"}
         *   所以症状不是"500 内部错误"，而是**"这条路由不存在"** —— 响应里连 `code` 字段都没有
         *   （前端 api.js 只看 json.code，会退化成一句 "request failed"），
         *   把"前端把 id 拼错了"说成"后台没有这个接口"。修后：**HTTP 400 + `{"code":400,...}`**。
         *
         * 选 **400** 而不是按 404 处理：这个 handler 里 404 的既有含义是
         * 「这个 id 的用户不存在」（deleteUser 返回 false 那一支），而"id 根本不是数字"
         * 是**请求本身**不合法。两者混成一个码之后，前端就分不清"这个人已经被删了"
         * 与"前端把 id 拼错了"—— 前者刷新列表即可自愈，后者必须改代码。
         * （与 /health 之类"宽松取默认值"不同：那些是**读**接口，坏参数不该让页面白屏；
         *   而这里是**写**接口，宁可明确拒绝。）
         */
        let rawId = ctx.paramOr("id", "")
        var id: Int64 = 0
        try {
            id = Int64.parse(rawId)
        } catch (e: Exception) {
            opsErr(ctx, 400, 400, "invalid user id: ${rawId}")
            return
        }
        if (store.deleteUser(id)) {
            opsOk(ctx, JsonNull())
        } else {
            opsErr(ctx, 404, 404, "user not found")
        }
    })
    mgmtRouter.get("/api/roles", { ctx: Context, _: () -> Unit =>
        let arr = JsonArray()
        for (r in store.listRoles()) {
            let o = JsonObject()
            jPutInt(o, "id", r.id)
            jPutStr(o, "name", r.name)
            arr.add(o)
        }
        opsOk(ctx, arr)
    })
    mgmtRouter.get("/api/perms", { ctx: Context, _: () -> Unit =>
        let arr = JsonArray()
        for (pm in store.listPermissions()) {
            let o = JsonObject()
            jPutInt(o, "id", pm.id)
            jPutStr(o, "code", pm.code)
            jPutStr(o, "name", pm.name)
            arr.add(o)
        }
        opsOk(ctx, arr)
    })

    /* ---------- 运维路由：社团管理（只读；写走 club-server，见文件头） ---------- */
    let clubRouter = Router()
    clubRouter.passOnNotFound = true

    /* 前端拿这些去拼 club-server 的地址（浏览器所在的机器可能不是服务端那台）。 */
    clubRouter.get("/api/club/config", { ctx: Context, _: () -> Unit =>
        /* 一次取一对一致的凭据快照：接口不该暴露"半次写入"的中间态（见 OpsConfig 的注释） */
        let (clubUser, clubPass) = ops.clubCreds()
        let o = JsonObject()
        jPutStr(o, "api_base", ops.apiBase)
        jPutInt(o, "club_port", ops.clubPort)
        /*
         * 社团库的位置（2026-09-20 改口径）：**数据在 MySQL 里**，不是一个文件。
         *   · club_database   —— 社团库的 MySQL 库名（与 club-server 连的是同一个）；
         *   · club_mysql      —— host:port（口令绝不回显）；
         *   · club_data_dir   —— 现在只是**审计日志目录**（audit.log 仍在文件里），
         *                        保留它是因为前端会显示这个路径让人去找日志。
         * 同时**删掉** club_db_file / db_exists 里那个"db.json 路径"键：
         * 留着会撒谎（那个文件已经不再产生、也不再是真相来源）。
         *   ⚠ 兼容性：`club_data_dir` 键名与取值都没变，只是含义收窄到审计日志。
         */
        jPutStr(o, "club_database", ops.clubMysqlDb)
        jPutStr(o, "club_mysql", "${ops.mysqlHost}:${ops.mysqlPort}")
        jPutStr(o, "club_data_dir", ops.dataDir)
        jPutStr(o, "club_audit_file", opsJoin(ops.dataDir, "audit.log"))
        jPutStr(o, "admin_data_dir", ops.adminDataDir)
        jPutStr(o, "rbac_db_file", "")
        jPutStr(o, "rbac_backend", "mysql")
        jPutStr(o, "rbac_database", "${ops.mysqlHost}:${ops.mysqlPort}/${ops.mysqlDb}")
        jPutInt(o, "admin_port", Int64(port))
        jPutBool(o, "ops_account_configured", clubUser.size > 0 && clubPass.size > 0)
        jPutStr(o, "ops_account", clubUser)
        clubPutTime(o, "boot_at", bootEpoch)
        opsOk(ctx, o)
    })

    /*
     * 运维会话：后台用 admin.env 里的**专用运维账号**（club-server 的 role = ops）
     * 登录 club-server，把令牌交给前端。
     *
     * 为什么这样做（而不是让运维人员自己输会长口令，也不是后台逐条代理写）：
     *   · 运维人员只登录后台一次（口令见 N-29 的说明），不需要知道任何社团账号的口令；
     *   · 写操作的**身份**是运维账号 —— club-server 的审计里 actor 就是"运维"，
     *     与会长做的操作分得清清楚楚（职责分离）；
     *   · 前端仍然直连 club-server（CORS 已开），因此 PATCH/DELETE 这些方法都能用，
     *     后台不必自己实现一套 HTTP 转发。
     * 令牌只在本进程内存里缓存（TTL 6 小时），前端拿到的也只是这个运维令牌。
     */
    clubRouter.get("/api/club/session", { ctx: Context, _: () -> Unit =>
        let o = JsonObject()
        let (clubUser, clubPass) = ops.clubCreds()
        if (clubUser.size == 0 || clubPass.size == 0) {
            jPutBool(o, "configured", false)
            jPutStr(o, "hint", "未配置运维账号：先在 club-server 跑 " +
                "`club-server init-ops <手机号> <口令> <数据目录>`，" +
                "再把手机号/口令填进 admin.env 的 club_user / club_pass")
            opsOk(ctx, o)
            return
        }
        let force = ctx.queryParamOr("force", "") == "1"
        clubSessionEnsure(ops, clubSess, force)
        /* 一次取一致快照：token 与 identity 必须是**同一次**登录的结果，
         * 否则前端可能拿到"身份是运维账号、token 却是上一个账号的"这种撕裂组合（见 ClubSession 的注释） */
        let sess = clubSess.view()
        jPutBool(o, "configured", true)
        jPutStr(o, "api_base", ops.apiBase)
        jPutInt(o, "club_port", ops.clubPort)
        jPutStr(o, "token", sess.token)
        if (sess.err.size > 0) {
            jPutStr(o, "error", sess.err)
        }
        let id = JsonObject()
        jPutStr(id, "name", sess.name)
        jPutStr(id, "phone", sess.phone)
        jPutStr(id, "role", sess.role)
        jPutStr(id, "role_label", clubRoleLabel(sess.role))
        o.put("identity", id)
        opsOk(ctx, o)
    })

    clubRouter.get("/api/club/overview", { ctx: Context, _: () -> Unit =>
        withClub(ctx, ops, mysqlPass, ops.dataDir, { s: Store => clubOverview(s) })
    })
    clubRouter.get("/api/club/members", { ctx: Context, _: () -> Unit =>
        withClub(ctx, ops, mysqlPass, ops.dataDir, { s: Store => clubMembers(s, ctx) })
    })
    clubRouter.get("/api/club/depts", { ctx: Context, _: () -> Unit =>
        withClub(ctx, ops, mysqlPass, ops.dataDir, { s: Store => clubDepts(s) })
    })
    clubRouter.get("/api/club/tasks", { ctx: Context, _: () -> Unit =>
        withClub(ctx, ops, mysqlPass, ops.dataDir, { s: Store => clubTasks(s, ctx) })
    })
    clubRouter.get("/api/club/plans", { ctx: Context, _: () -> Unit =>
        withClub(ctx, ops, mysqlPass, ops.dataDir, { s: Store => clubPlans(s) })
    })
    clubRouter.get("/api/club/links", { ctx: Context, _: () -> Unit =>
        withClub(ctx, ops, mysqlPass, ops.dataDir, { s: Store => clubLinks(s) })
    })
    clubRouter.get("/api/club/audit", { ctx: Context, _: () -> Unit =>
        /*
         * limit 的默认值（200）、非法/0/负数的回退值（200）与**上界**（CLUB_AUDIT_LIMIT_MAX = 2000）
         * 全在 clubAuditLimit() 里，理由见那里的长注释。
         * 这里原先直接吃裸 limit：`?limit=99999999` 会让整份 audit.log 被切成一堆行、
         * 再为每行建一个 JsonObject（每行还两次成员名查表）—— 与 clubPaging 的 500 上界是同一类防护。
         */
        let cap = clubAuditLimit(ctx)
        withClub(ctx, ops, mysqlPass, ops.dataDir, { s: Store =>
            let o = JsonObject()
            let items = clubAuditLines(s, cap)
            o.put("items", items)
            jPutInt(o, "shown", items.size())
            o
        })
    })

    /*
     * 服务端侧探测 club-server（前端在别的机器上时，localhost 指的不是服务端）。
     * 只用 GET，因此走 clubHttpGet 就够。
     */
    clubRouter.get("/api/club/server-health", { ctx: Context, _: () -> Unit =>
        let url = opsJoin(ops.apiBase, "health")
        let t0 = MonoTime.now()
        let o = JsonObject()
        match (clubHttpGet(url)) {
            case Some(text) =>
                let ms = (MonoTime.now() - t0).toMilliseconds()
                jPutBool(o, "up", true)
                jPutInt(o, "ms", ms)
                jPutStr(o, "body", text)
                jPutStr(o, "url", url)
            case None =>
                jPutBool(o, "up", false)
                jPutInt(o, "ms", 0)
                jPutStr(o, "body", "")
                jPutStr(o, "url", url)
        }
        opsOk(ctx, o)
    })

    /*
     * 备份：把社团库导出成 **JSON 快照**写到 <后台数据目录>/club-backups/，审计日志照旧复制。
     *
     * 2026-09-20 换数据源：社团库在 MySQL 里了，**没有 db.json 可复制**。
     * 但备份的**产物**是文件不违背"不采用文件存储"——存储层是 MySQL，备份件是导出物。
     * 导出格式故意用 renderDb()（就是原 db.json 的那套键与结构）：
     *   · 复用 club-server 同一份 *ToJson 映射 —— 包里不可能少字段、不可能与库里的形状不一致；
     *   · 这份快照仍然能被原来的 JSON 导入路径吃回去（回退/迁移都用得上）。
     * 响应里的 db_bytes 是**这份快照的字节数**（不再有"db.json 有多大"这个概念）。
     *
     * 2026-09-17 三处修正（都是"备份本身可能不可靠"这一类）与本次改动的对应关系：
     *   ① 落盘原子（opsWriteFileAtomic：先 .tmp 再 rename）—— 保留，未动；
     *   ② 文件名带毫秒 + 冲突自动补序号（opsBackupPath）—— 保留，未动；
     *   ③ "只读一次"—— 语义**更强**了：原来读 db.json 两次可能读到两个版本，
     *      现在快照是"一次 SELECT 事务里载入的内存状态渲染出来的"，天然是同一个版本。
     *   另外：整段备份仍在 opsBackupMu 里**串行**（见 opsBackupPath 的注释）。
     */
    clubRouter.post("/api/club/backup", { ctx: Context, _: () -> Unit =>
        withClub(ctx, ops, mysqlPass, ops.dataDir, { s: Store =>
            opsBackupMu.lock()
            try {
                let stamp = opsStamp()
                let outDir = opsJoin(ops.adminDataDir, "club-backups")
                if (!exists(outDir)) {
                    Directory.create(outDir, recursive: true)
                }
                /* 这一份字节既用于写快照，也用于报 db_bytes —— 二者必然一致 */
                let snapBytes = renderDb(s).toArray()
                let files = JsonArray()
                let dbOut = opsBackupPath(outDir, "club", stamp, ".json")
                opsWriteFileAtomic(dbOut, snapBytes)
                files.add(JsonString(dbOut))
                let auditFile = opsJoin(ops.dataDir, "audit.log")
                if (exists(auditFile)) {
                    let auditOut = opsBackupPath(outDir, "audit", stamp, ".log")
                    opsWriteFileAtomic(auditOut, File.readFrom(auditFile))
                    files.add(JsonString(auditOut))
                }
                let o = JsonObject()
                o.put("files", files)
                jPutStr(o, "stamp", stamp)
                jPutInt(o, "db_bytes", snapBytes.size)
                jPutStr(o, "source", "mysql/${ops.mysqlHost}:${ops.mysqlPort}/${ops.clubMysqlDb}")
                o
            } catch (e: Exception) {
                /*
                 * 抛出去交给 withClub 的统一错误出口（它会回 500 并把原因写进 message）。
                 * ⚠ 这里**不要**自己调 opsErr 再返回空对象：那样 withClub 回头还会再
                 *   opsOk 一次，等于一个请求叠两个响应（先写的赢，后写的是死代码）。
                 */
                throw Exception("备份失败：${e.message}")
            } finally {
                opsBackupMu.unlock()
            }
        })
    })

    /* ---------- 运维路由：健康检查 + 优雅关闭（admin 角色保护） ---------- */
    let opsRouter = Router()
    opsRouter.passOnNotFound = true
    opsRouter.get("/health", { ctx: Context, _: () -> Unit =>
        ctx.status(200).header("content-type", "application/json")
            .body("{\"status\":\"ok\"}")
    })
    opsRouter.post("/admin/shutdown", { ctx: Context, _: () -> Unit =>
        let userId = try {
            Int64.parse(ctx.getStateOr("userId", "0"))
        } catch (e: Exception) {
            Int64(0)
        }
        match (store.findUserById(userId)) {
            case Some(u) =>
                if (u.roleId == 1) {
                    shutdownFlag.requested = true
                    opsOk(ctx, JsonNull())
                } else {
                    opsErr(ctx, 403, 403, "forbidden: admin only")
                }
            case None =>
                opsErr(ctx, 401, 401, "unauthorized")
        }
    })

    /* ---------- 静态托管 + SPA fallback ---------- */
    let staticOpts = StaticOptions()
    staticOpts.spaFallback = true
    staticOpts.enableCache = false   /* 运维台改前端要立即生效，不缓存 */
    /*
     * 2026-09-17：**必须关掉 ETag**，否则重建前端后浏览器会卡在旧页面上（实测白屏）。
     *
     * 框架的 ETag 是"**仅按字节大小**"生成的强校验器（static.cj 的 makeETag(size) → `"<size>"`，
     * 文件头第 32 行写明），而 vite 重建时 index.html 里变的只有两个 8 位 hash 文件名 ——
     * **字节数一模一样**（实测重建前后都是 399 字节，`git cat-file -s` 两版相同）。
     * 于是 ETag 完全相同：浏览器带着 If-None-Match 回来直接拿到 **304**，继续用旧的
     * index.html，而它引用的 index-<旧hash>.js 已被 vite 删掉 → **JS 404 → 一片空白**。
     * （Last-Modified 那一路本身是对的，但它排在前面且因 mtime 已变而不匹配，
     *   于是落到 ETag 这一路命中 304，正好把这个坑踩满。）
     * 运维台只在本机/运维网内使用，每次重下发 ~115 KB 的 JS 完全可以接受 —— 正确性优先。
     */
    staticOpts.enableETag = false

    let app = QingZhouApp()
        .use(securityHeaders())
        /* 运维页一次进来会并发拉 6~8 个接口，上游的 100/分钟太紧；这里放宽并写明理由 */
        .use(rateLimit(600, 60))
        .use(cors())
        /*
         * 请求体前置闸门（2026-09-18 补）：**必须在 bodyParser 之前**（外层）。
         * 它靠 Content-Length / Content-Type 就把超大 body 挡在内存之外 ——
         * 框架的 bodyParser 是"先整份读进内存、再比 maxBytes"，装在它之后等于没装。
         * 放在 cors 之后：这样 411/413/415 这些拒绝响应也带上 CORS 头，
         * 浏览器侧才能读到 message（否则只有一个不透明的网络错误）。见 opsBodyLimit()。
         */
        .use(opsBodyLimit())
        .use(bodyParser())
        .use(statusNormalizer())
        .use(publicRouter.middleware())
        .use(authRequired(secret))
        .use(authRouter.middleware())
        .use(requirePermission(store, "GET", "/api/users", "user:list"))
        .use(requirePermission(store, "POST", "/api/users", "user:create"))
        .use(requirePermission(store, "DELETE", "/api/users", "user:delete"))
        .use(requirePermission(store, "GET", "/api/roles", "role:list"))
        .use(requirePermission(store, "GET", "/api/perms", "perm:list"))
        .use(mgmtRouter.middleware())
        .use(requireClubOps(store))
        .use(clubRouter.middleware())
        .use(opsRouter.middleware())
        .use(serveWithOpts("./admin-web/dist", staticOpts))
        .onError(opsErrorHandler())

    println("QingZhou RBAC admin · listening on :${port}")
    println("  GET  /health              健康检查")
    println("  POST /admin/shutdown      优雅关闭（需 admin 角色）")
    println("  GET  /api/club/overview   社团运维台（读社团库；写走 club-server）")
    println("  运维页 http://127.0.0.1:${port}/club")
    /*
     * 社团库的地址（2026-09-20 改）：业务数据在 MySQL 里，不再是 ops.dataDir 下的 db.json。
     * dataDir 现在只是**审计日志目录** —— 照实说，别让人去找一个不再产生的文件。
     */
    println("  社团库 MySQL ${ops.mysqlHost}:${ops.mysqlPort}/${ops.clubMysqlDb}　club-server ${ops.apiBase}")
    println("  审计日志目录 ${ops.dataDir}（audit.log；业务数据已不在文件里）")
    /* 一次取一致快照（这两条打印发生在 serve() 之前，但用法与接口侧保持一致，别再直接读字段） */
    let (bootClubUser, _bootClubPass) = ops.clubCreds()
    if (bootClubUser.size > 0) {
        println("  运维身份 ${bootClubUser}（club-server 的 role = ops：除移交会长外与会长同权）")
        println("    （也可以直接用运维账号登录本后台，那样就不必在这里配 club_user / club_pass）")
    } else {
        println("  运维页的写操作需要一个运维账号（club-server 的 role = ops）。")
        println("    最简单的做法：直接用运维账号登录本后台（手机号 + init-ops 的口令）。")
        println("    也可以把手机号/口令填进 admin.env 的 club_user / club_pass（两种都行）。")
        println("    还没有运维账号就先建一个（**在 club-server 未运行时**执行）：")
        println("      cd server\\build ; .\\club-server.exe init-ops <手机号> <口令> mysql://root:<口令>@127.0.0.1:3307/club")
    }
    /*
     * N-29（2026-09-17）：口令来源与**实际监听地址**必须显式可见。
     *
     * 原先这里打印的是"账号 admin/admin123"：既把公开默认口令再复述一遍，
     * 又完全没提框架把端口绑在 **0.0.0.0**（`app.cj` 里 `.addr(bindAddr)`，默认值 "0.0.0.0"），
     * 而文档只写 127.0.0.1 —— 读者会以为只有本机能连。
     *
     * 2026-09-19 迁移到 MySQL 后，这句"口令见 admin.env"的提示移到了上面那段
     * （新库/旧库两个分支各说各的）—— 这里只留监听地址这条，避免同一个意思出现两处、
     * 然后慢慢漂移成两种说法。
     *
     * 2026-09-20 更正一处**已经过时的事实**：上游 v0.8（`20be0ae`）已按我们的 C-5 反馈加了
     * `serve(port, bindAddr! = "0.0.0.0")` —— 也就是"只绑本机"**现在有开关了**，
     * 只是我们后台的入口用的仍是默认值。原文写的是"框架固定绑全网卡、没有开关"，不再成立。
     * （2026-09-24 快照升到 `fbc823d`/v0.10.0 后这条依然成立，签名没变。）
     */
    println("  ⚠ 监听 0.0.0.0:${port} —— 框架默认绑全网卡（v0.8 起可用 bindAddr 只绑本机，本入口暂未暴露该开关）。")
    println("      运维台能看到整个社团库，请用防火墙只对运维机放行 ${port}，")
    println("      不要把它暴露到公网或整个校园网。")

    /* ---------- 优雅关闭：主线程轮询关闭标志 ---------- */
    let handle = app.serve(port)
    while (!shutdownFlag.requested) {
        sleep(Duration.second * 1)
    }
    println("shutdown requested, draining in-flight requests...")
    handle.shutdown()
    println("graceful shutdown complete")
    store.close()
    return 0
}
