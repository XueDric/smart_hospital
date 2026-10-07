package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * MySQL 持久化层（2026-09-20，路线 B：**只换持久化层**）
 *
 * ===== 这个文件做什么、不做什么 =========================================
 *
 * 做：把 store.cj 里那套"启动时读 data/db.json / 每次变更整库重写 db.json"
 *     换成"启动时从 MySQL 全量载入内存 / 每次变更在**一个事务**里把各表整体替换"。
 *
 * 不做：**内存模型、业务 handler、权限、视图、派生量一行不改**。
 *   Store 结构、7 张 HashMap、所有 h_*.cj / perms.cj / views.cj /
 *   逾期与课题树递归 / 时间桶分组 / 部门范围判定全部保持原样 ——
 *   这是本项目"507 条单测 + 434 条冒烟"语义不被破坏的前提。
 *
 * ===== 为什么复用 *FromJson 而不是另写一套字段映射 ======================
 *
 * 载入时把数据库行摆成一个 JsonObject，再直接喂给现成的
 * deptFromJson / memberFromJson / planFromJson / taskFromJson / linkFromJson /
 * tokenFromJson（store.cj 里那 7 个 *FromJson 的权威定义）。
 * 这样"字段清单"只有一个出处：以后 Task 再加一个字段，只会改 store.cj 一处，
 * 不会出现"JSON 路径有、SQL 路径漏"这种两套定义漂移的经典事故。
 *
 * 因此本文件的 SELECT **显式列出列名**（不用 `SELECT *`：物理列序不是契约，
 * 一次 alter 就会错位）。
 *
 * ===== 落盘用"多行 INSERT"，不是逐行 ====================================
 *
 * 一次提交要整体替换 7 张表。若逐行 INSERT，1000 人 + 1000 任务 = 2000+ 次往返，
 * 每次写盘都会很明显（而 club-server 原本是"一次文件写"，写盘在请求链上、
 * 响应之前 —— 见 writeDbToMysql 的语义说明）。
 * 所以按**每批最多 BATCH_ROWS 行**拼成单条 `INSERT ... VALUES (...),(...),...`：
 * 往返次数从 O(行数) 降到 O(行数/批大小)，仍是**参数化**（每行一组 `?`，
 * 值全部走 DbValue 绑定），没有字符串拼值。
 *
 * ===== SQL 安全：一律参数化，禁止字符串拼 SQL ==========================
 *
 * 全部走框架 v0.8 的参数化接口：
 *     db.exec(sql, [DbStr(x), DbInt(n), ...])   /   db.query(sql, params)
 * 框架把 `?` 占位符按类型绑成安全字面量（字符串走 sqlQuote 转义、数字原样）。
 *
 * ⚠ 上游曾经在 MySQL 路径上是**字符串拼 SQL**（`... WHERE username = '${x}'`），
 *   而 club-server 的入参里大量是用户可控字符串（姓名 / 任务标题 / 阻塞原因 /
 *   名录搜索词 q= / 部门名 / 课题名 / 招募 token），照那个模式写会立刻引入 SQL 注入。
 *   所以本文件里拼进 SQL 的**只能是常量**：列名清单、`?` 占位符、表名、DDL。
 *   任何 `${...}` 把**值**插进 SQL 的写法都视为缺陷。
 *   （唯一一处外部输入进 SQL 的是库名，它先过 dbNameChecked() 的标识符白名单。）
 */

import std.collection.*
/* std.convert 给 Int64.parse 用（parseIntOr）。注意仓颉的 parse 是扩展方法，
 * 光有 std.convert 还不够 —— 它声明在 Parsable 接口的扩展上，必须 import 该包才能解析。 */
import std.convert.*
import std.database.sql.*
import stdx.encoding.json.*

/*
 * ⚠ 这一条 import **看着没人用，但绝对不能删**（与 ops\admin_main.cj:76 同一个理由）：
 *   内置的 MariaDB 驱动靠"包顶层的一条 `let _ = DriverManager.register(...)`"
 *   完成注册（third_party\mariadb-driver\src\cdbc\driver.cj:23），而**只有该包被引用时
 *   那行顶层初始化才会被执行**。只在链接命令里加 `-l:mariadb.cdbc` 是不够的 ——
 *   实测就是这样：编译链接全过，一启动就抛
 *     "未注册 mysql/mariadb 驱动：请引入 mysqlclient4cj 或 Cangjie-SIG mysql-driver…"
 *   而框架的 db_mysql.cj 是**运行时按注册名查找**驱动的（编译期零依赖），
 *   所以它自己不会 import 任何驱动包；"注册"只能由用它的那一方来做。
 *   club-server 现在用它，所以这条 import 也必须在这里出现。
 */
import mariadb.cdbc.*

/* ===================== 连接参数 ===================== */

/*
 * MySQL 连接参数。由命令行（DSN 或 --mysql-* 命名参数）解析出来，
 * 与 store.cj 的 Store 解耦：Store 只持有构造好的 MysqlStore。
 */
public class MySqlConfig {
    public var host: String = "127.0.0.1"
    public var port: Int64 = 3306
    public var user: String = "root"
    public var pass: String = ""
    public var db: String = "club_server"

    /*
     * 这一份配置**完全来自默认值**（命令行既没给 DSN，也没给任何 --mysql-*）。
     *
     * 为什么要记这个事实：默认端口是 MySQL 出厂默认 **3306**，而本机联调的便携版
     * MariaDB 在 **3307** —— 于是"忘了给连接参数"的表现是 `Failed to connect 10061`，
     * 看起来像"服务器坏了/端口配错了"，其实只是参数没传进来。实测踩到过一次：
     * PowerShell 里引用了未定义的 `$dsn`（空串，**不报错**），命令就悄悄按
     * 3306 + 空口令去连。有了这个标记，loadOrExitDb 就能在**连之前**把
     * "你正在使用默认参数"说出来，而不是让人对着一句连接失败猜半天。
     * 单测（`test` 不带 DSN）不会打印它 —— 那条路本来就不连库。
     */
    public var fromDefaults: Bool = false

    public init() {}

    /*
     * 给日志/启动横幅用的一行摘要。**绝不包含口令**
     * （这是硬约束：口令不写日志、不进响应；这里只体现"有没有填"）。
     */
    public func describe(): String {
        let pw = if (pass.size > 0) { "***" } else { "(empty)" }
        return "mysql://${user}@${host}:${port}/${db} pass=${pw}"
    }
}

/*
 * 库名只允许 [A-Za-z0-9_$]，且不能以数字开头。
 *
 * 为什么必须校验：库名要拼进 `CREATE DATABASE`（这条 DDL 不能用占位符绑定标识符），
 * 是**唯一**一处名字会进 SQL 的地方。它来自命令行，属于外部输入，
 * 不校验就等于开了一个注入口子。校验后这个口子就关死了。
 */
func dbNameChecked(name: String): String {
    if (name.size == 0 || name.size > 64) {
        throw Exception("数据库名不合法（长度须在 1..64）：${name}")
    }
    let bytes = name.toArray()
    var i: Int64 = 0
    while (i < bytes.size) {
        let c = bytes[i]
        let ok = (c >= UInt8(0x41) && c <= UInt8(0x5A)) ||
            (c >= UInt8(0x61) && c <= UInt8(0x7A)) ||
            (c >= UInt8(0x30) && c <= UInt8(0x39)) ||
            c == UInt8(0x5F) || c == UInt8(0x24)
        if (!ok) {
            throw Exception("数据库名只能含字母/数字/下划线/美元符：${name}")
        }
        i += 1
    }
    let first = bytes[0]
    if (first >= UInt8(0x30) && first <= UInt8(0x39)) {
        throw Exception("数据库名不能以数字开头：${name}")
    }
    return name
}

/* ===================== MySqlStore：DbBackend 的一层薄封装 ===================== */

/*
 * 为什么再包一层而不直接用 MySqlBackend：
 *   1) Store 需要一个"可空的后端引用"来表达"这个 Store 走 MySQL 还是走文件"，
 *      包一层类型名更自明（Store.mysql: ?MysqlStore）；
 *   2) 参数化入口收在这里，业务侧不再直接拼 Array<DbValue>；
 *   3) 启动期的错误信息统一在这里加中文处置提示（连不上、驱动没注册…）。
 */
public class MysqlStore {
    public let db: MySqlBackend
    public let cfg: MySqlConfig

    public init(cfg: MySqlConfig) {
        this.cfg = cfg
        try {
            db = MySqlBackend(cfg.host, cfg.port, cfg.user, cfg.pass, cfg.db,
                              noBackslashEscapes: false)
        } catch (e: Exception) {
            /*
             * 这里最容易踩的是"驱动没注册"（少写 import mariadb.cdbc.*），
             * 它的报错原文是英文的，且看起来像"服务器连不上"。这里补一句人话，
             * 但**不回显口令**（describe 里就是 ***）。
             */
            throw Exception("连接 MySQL 失败（${cfg.describe()}）：${e.message}\n" +
                "  处置：① 确认服务器在跑（本机联调的便携版 MariaDB 用 3307）；" +
                "② 确认连通与账号口令；③ 若报「未注册 mysql/mariadb 驱动」，" +
                "说明驱动没被注册进链接产物 —— 重跑 build-mysql-driver.ps1 再 build.ps1" +
                "（详见 docs/mysql-backend.md）。")
        }
        /*
         * ===== P0（2026-10-04）：会话字符集必须显式设成 utf8mb4 ==================
         *
         * **现象**：一个 4 字节 UTF-8 字符（emoji）就让之后所有写入持续 500，
         * 而读请求仍返回 200。实测那一刻：emoji 任务 → 500，紧接着普通 ASCII 任务
         * → 500，纯中文任务 → 500；`GET /tasks` → 200（读的是未落盘的内存）。
         *
         * **根因**：连接侧与库不一致 ——
         *   · 驱动握手把连接字符集**写死成 33 = utf8mb3**
         *     （third_party/mariadb-driver/src/protocol/client_handshake_response.cj:156-161
         *      的 getDefault() → .setCharset(33)）；
         *   · 框架 third_party/qingzhou/src/db_mysql.cj **没有字符集参数**
         *     （只在 noBackslashEscapes 为真时发一句 SET SESSION sql_mode）；
         *   · 本文件此前也没发过 `SET NAMES`。
         * 于是库与 9 张表都是 utf8mb4，而连接是 utf8mb3：含 4 字节字符的行
         * INSERT 报 `1366 Incorrect string value`。
         *
         * **为什么后果是"持续 500"**：落盘是**一个事务**，失败即整体回滚；而
         * "已落盘基准" `s.persisted` 只在提交成功后推进（见 writeDbToMysql 末尾），
         * 所以那条坏数据永远留在内存里 —— 之后每一次写都失败，直到重启，
         * 而重启会丢掉全部未落盘的写入。触发面**不需要认证**：注册时的姓名
         * 就是自由文本。
         *
         * **处置**：驱动与框架快照都被 MANIFEST.sha256 锁死、不该改，所以修在
         * 我们自己的文件里 —— 建连后立刻 `SET NAMES utf8mb4`；失败**直接抛**，
         * 不静默继续（继续跑等于把上面那条路径留着）。
         * 回归闸门：tests.cj 的 testMysqlRoundTrip 里的 4 字节断言
         * （把这一句撤掉，那条断言当场变红）。
         */
        try {
            db.exec("SET NAMES utf8mb4", Array<DbValue>())
        } catch (e: Exception) {
            throw Exception("设置会话字符集失败（SET NAMES utf8mb4）：${e.message}\n" +
                "  处置：确认账号权限、库名与主机；详见 docs/mysql-backend.md §12.10。" +
                "**不静默继续** —— 连接字符集是 utf8mb3 时，一个 4 字节字符（emoji）" +
                "就会让之后每一次写入持续 500。")
        }
    }

    /* 查询（参数化）。 */
    public func q(sql: String, params: Array<DbValue>): DbResultSet {
        return db.query(sql, params)
    }

    /* 写（参数化）。 */
    public func x(sql: String, params: Array<DbValue>): Int64 {
        return db.exec(sql, params)
    }

    /*
     * 事务：begin → body() → commit；body 抛异常则 rollback 并重新抛出。
     * 直接用框架 DbBackend.withTransaction（v0.8 C-2），不自己手写配对，
     * 少一类"漏 rollback"的缺陷。
     */
    public func tx(body: () -> Unit): Unit {
        db.withTransaction(body)
    }

    public func close(): Unit {
        db.close()
    }
}

/*
 * 建库（幂等）：`CREATE DATABASE IF NOT EXISTS <db> CHARACTER SET utf8mb4`。
 *
 * 为什么单独做一次：MySqlBackend 的 URL 里带 database，库不存在时**建连就会失败**；
 * 而"库要先手工建好"对 club-server 的部署面是个不必要的门槛（原来只要一个目录）。
 * 做法：先用空库名连一次（驱动的 database 参数允许为空），建库、断开，
 * 调用方再用真库名连。
 *
 * ⚠ 用空库名建连在部分服务器/驱动上会失败（例如账号没有全局权限）。这时**不吞异常**，
 *   而是原样抛出并带上"请先手工建库"的处置 —— 比一句莫名奇妙的连接失败有用。
 *
 * 库名是唯一进 SQL 的外部输入，先过 dbNameChecked() 的标识符白名单。
 */
public func ensureDatabase(cfg: MySqlConfig): Unit {
    let name = dbNameChecked(cfg.db)
    let boot = MySqlConfig()
    boot.host = cfg.host
    boot.port = cfg.port
    boot.user = cfg.user
    boot.pass = cfg.pass
    boot.db = ""
    var probe: ?MysqlStore = None
    try {
        probe = Some(MysqlStore(boot))
    } catch (e: Exception) {
        /*
         * ⚠ 这里的报错**必须说清是"连不上"而不是"库名没给"**（2026-09-20 改）。
         *
         * 原文是「无法在不指定库名的情况下连上 MySQL…处置：先手工建库」—— 这句话把
         * **端口/服务没起** 误报成"没给库名"，于是真实原因（本机联调那台 MariaDB 在
         * **3307**，而没给 DSN 时会静默退回出厂默认 **3306**）被完全掩盖。实测踩到：
         * 用户在 PowerShell 里用了未定义的 `$dsn`（未定义变量 = 空串），
         * 命令就悄悄按 3306 + 空口令 去连，报 `Failed to connect 10061`，
         * 而当前这句提示让人以为是库名或权限问题。
         *
         * 现在把"目标地址 + 四种可能原因（按可能性排序）"列出来。
         * 仍保留"无全局权限也能连不上"这一条 —— 那才是真的需要手工建库的情形。
         */
        throw Exception("连不上 MySQL（${cfg.describe()}）：${e.message}\n" +
            "  处置（按可能性排序）：\n" +
            "   ① **端口/主机不对**：本机联调的便携版 MariaDB 是 127.0.0.1:**3307**（MySQL 出厂默认 3306）。\n" +
            "      确认它在听：Test-NetConnection ${cfg.host} -Port ${cfg.port}\n" +
            "   ② **这条命令压根没拿到连接参数**：没给 DSN 也没给 --mysql-* 时会**静默退回默认值**\n" +
            "      （127.0.0.1:3306 / root / 空口令 / club_server）。照文档复制命令时最常见的原因就是\n" +
            "      DSN 变量是空的 —— 在 PowerShell 里引用一个未定义的 `$dsn` **不会报错**，就是空串。\n" +
            "      正确写法：<子命令> ... \"mysql://用户:口令@主机:3307/库名\"\n" +
            "   ③ 账号/口令不对；\n" +
            "   ④ 账号**不允许不带库名连接**（没有全局权限）—— 这一种才需要先手工建库再连：\n" +
            "      CREATE DATABASE " + name + " CHARACTER SET utf8mb4;")
    }
    let p = match (probe) {
        case Some(x) => x
        case None => throw Exception("无法连接 MySQL")
    }
    try {
        p.x("CREATE DATABASE IF NOT EXISTS " + name + " CHARACTER SET utf8mb4", Array<DbValue>())
    } finally {
        p.close()
    }
}

/* ===================== 建表 ===================== */

/*
 * 7 张业务表的 DDL。列名与类型**从 store.cj 的 *ToJson 键推导**（那是权威字段清单）：
 *   · 整型（id / epoch 秒 / *_iter）→ BIGINT NOT NULL DEFAULT 0
 *   · 字符串 → TEXT NOT NULL（**不用 NULL**：DbResultSet 是按 String 取值的，
 *     列可空会让驱动走到 null 分支；业务语义本来就是"空串 = 无"，不是 NULL）
 *   · 布尔（enabled）→ TINYINT NOT NULL DEFAULT 1（1/0）
 *
 * 主键：departments / members / plans / tasks 用 id；
 *       invite_links / tokens / idem 用各自的字符串键。
 * 全部 `IF NOT EXISTS`，重复启动不报错（幂等）。
 *
 * ⚠ 表名与 store.cj 的逻辑表名**一一同名**（departments / members / plans / tasks /
 *   invite_links / tokens / idem）：这个库是 club-server 专用的，不与其他业务共库。
 *   （所以**没有**加 `club_` 前缀 —— 加了反而会让"表 ↔ 内存表"的对应变模糊。）
 */
public let SCHEMA_DDL: Array<String> = [
    "CREATE TABLE IF NOT EXISTS departments (" +
        "id BIGINT NOT NULL, name TEXT NOT NULL, sort BIGINT NOT NULL DEFAULT 0, " +
        "PRIMARY KEY (id)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",

    "CREATE TABLE IF NOT EXISTS members (" +
        "id BIGINT NOT NULL, name TEXT NOT NULL, phone TEXT NOT NULL, " +
        "pw_algo TEXT NOT NULL, pw_iter BIGINT NOT NULL DEFAULT 0, " +
        "pw_salt TEXT NOT NULL, pw_hash TEXT NOT NULL, role TEXT NOT NULL, " +
        "dept_id BIGINT NOT NULL DEFAULT 0, dept_hint BIGINT NOT NULL DEFAULT 0, " +
        "status TEXT NOT NULL, joined_at BIGINT NOT NULL DEFAULT 0, " +
        "PRIMARY KEY (id), KEY idx_members_phone (phone(64))) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",

    "CREATE TABLE IF NOT EXISTS plans (" +
        "id BIGINT NOT NULL, title TEXT NOT NULL, `desc` TEXT NOT NULL, " +
        "parent_id BIGINT NOT NULL DEFAULT 0, owner_id BIGINT NOT NULL DEFAULT 0, " +
        "dept_id BIGINT NOT NULL DEFAULT 0, due_at BIGINT NOT NULL DEFAULT 0, " +
        "created_by BIGINT NOT NULL DEFAULT 0, created_at BIGINT NOT NULL DEFAULT 0, " +
        "updated_at BIGINT NOT NULL DEFAULT 0, " +
        "PRIMARY KEY (id)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",

    "CREATE TABLE IF NOT EXISTS tasks (" +
        "id BIGINT NOT NULL, title TEXT NOT NULL, `desc` TEXT NOT NULL, " +
        "owner_id BIGINT NOT NULL DEFAULT 0, plan_id BIGINT NOT NULL DEFAULT 0, " +
        "dept_id BIGINT NOT NULL DEFAULT 0, status TEXT NOT NULL, blocker TEXT NOT NULL, " +
        "help_dept_id BIGINT NOT NULL DEFAULT 0, help_member_id BIGINT NOT NULL DEFAULT 0, " +
        "due_at BIGINT NOT NULL DEFAULT 0, updated_at BIGINT NOT NULL DEFAULT 0, " +
        "completed_at BIGINT NOT NULL DEFAULT 0, deleted_at BIGINT NOT NULL DEFAULT 0, " +
        "source TEXT NOT NULL, created_by BIGINT NOT NULL DEFAULT 0, " +
        "created_at BIGINT NOT NULL DEFAULT 0, " +
        "PRIMARY KEY (id)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",

    "CREATE TABLE IF NOT EXISTS invite_links (" +
        "`token` VARCHAR(128) NOT NULL, dept_id BIGINT NOT NULL DEFAULT 0, " +
        "enabled TINYINT NOT NULL DEFAULT 1, created_by BIGINT NOT NULL DEFAULT 0, " +
        "created_at BIGINT NOT NULL DEFAULT 0, " +
        "PRIMARY KEY (`token`)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",

    "CREATE TABLE IF NOT EXISTS tokens (" +
        "`token` VARCHAR(128) NOT NULL, member_id BIGINT NOT NULL DEFAULT 0, " +
        "created_at BIGINT NOT NULL DEFAULT 0, expires_at BIGINT NOT NULL DEFAULT 0, " +
        "PRIMARY KEY (`token`)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",

    "CREATE TABLE IF NOT EXISTS idem (" +
        "`key` VARCHAR(255) NOT NULL, resource_id BIGINT NOT NULL DEFAULT 0, " +
        "created_at BIGINT NOT NULL DEFAULT 0, payload TEXT NOT NULL, " +
        "used_at BIGINT NOT NULL DEFAULT 0, " +
        "PRIMARY KEY (`key`)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",

    /*
     * meta：装"不在 7 张业务表里、但必须持久化"的全局计数器与注册配置。
     * 为什么单独一张表：store.cj 的 renderDb 里这几个字段本来就是**库级元数据**
     * （next_dept / next_member / next_plan / next_task / register_code_by /
     * register_code_at），不是哪张表的列。若塞进 members 之类的表，就需要
     * "哪一行的副本才是权威"这种约定，迟早出错。
     * register_code 是字符串，所以再单独一张 meta_str（与文件版 meta.int /
     * meta.string 的分法一致）。
     */
    "CREATE TABLE IF NOT EXISTS meta (" +
        "`k` VARCHAR(64) NOT NULL, v BIGINT NOT NULL DEFAULT 0, " +
        "PRIMARY KEY (`k`)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",

    "CREATE TABLE IF NOT EXISTS meta_str (" +
        "`k` VARCHAR(64) NOT NULL, v TEXT NOT NULL, " +
        "PRIMARY KEY (`k`)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4"
]

/*
 * 建表（幂等）。每次启动都跑一遍：`CREATE TABLE IF NOT EXISTS` 对已存在的表是空操作。
 */
public func ensureSchema(ms: MysqlStore): Unit {
    for (sql in SCHEMA_DDL) {
        ms.x(sql, Array<DbValue>())
    }
    /*
     * schema 迁移（P2-2）：**必须排在"任何读写之前"**。
     *
     * 为什么放在这里而不是 storeLoadDb —— `CREATE TABLE IF NOT EXISTS` 对**已存在**的表
     * 不补列，老库拉起后若**先写**（单测夹具就是先 save 再 load），INSERT 会带着新列名
     * 撞上旧表，直接 `Unknown column 'payload'`（2026-10-06 在统一库上实测复现）。
     * `ensureSchema` 是两条路径（`serve` 与单测）共同的"准备这个库"入口，放这里最稳。
     */
    ensureMigrations(ms)
}

/* ===================== 载入：MySQL → 内存 Store ===================== */

/*
 * 从 MySQL 全量载入。**绝不静默降级为空库**（与 storeLoad 同一口径）：
 * 表不可读、条数对不上、整数列非法 —— 一律抛异常，让服务起不来，
 * 而不是带着残缺数据继续跑（下一次落盘就会把真实数据覆盖掉）。
 *
 * 调用方（main.cj 的 loadOrExitDb）负责把异常转成 [FATAL] + 退出码 1。
 *
 * `dir` 是**审计日志目录**（audit.log 仍在文件里，见 audit.cj）：
 * 业务数据已经全在 MySQL，但审计日志是追加写的行日志，不属于 7 张表，
 * 本次迁移**不动它**（避免把"谁做了什么"的可追溯性一起改掉）。
 */
public func storeLoadDb(ms: MysqlStore, dir: String): Store {
    let s = Store(dir)
    s.mysql = Some(ms)

    s.departments = loadDepartments(ms)
    s.members = loadMembers(ms)
    s.plans = loadPlans(ms)
    s.tasks = loadTasks(ms)
    s.invite_links = loadLinks(ms)
    s.tokens = loadTokens(ms)
    /* 兜底：正常情况下 ensureSchema 已经跑过迁移；这里再跑一次是为了"只 load 不 ensure"的
       调用方也不至于撞上旧列。两步都是幂等的（1 次 information_schema + 1 次版本查询）。 */
    ensureMigrations(ms)
    s.idem = loadIdem(ms)

    /* 元数据（计数器 + 注册配置）。表是空的就是空库，用默认值。 */
    let meta = ms.q("SELECT `k`, v FROM meta", Array<DbValue>())
    var mi: Int64 = 0
    while (mi < meta.rowCount()) {
        let k = meta.cell(mi, 0)
        let v = parseIntOr(meta.cell(mi, 1), 0)
        if (k == "next_dept") { s.next_dept = v }
        if (k == "next_member") { s.next_member = v }
        if (k == "next_plan") { s.next_plan = v }
        if (k == "next_task") { s.next_task = v }
        if (k == "register_code_by") { s.register_code_by = v }
        if (k == "register_code_at") { s.register_code_at = v }
        mi += 1
    }
    let metaStr = ms.q("SELECT `k`, v FROM meta_str", Array<DbValue>())
    var si: Int64 = 0
    while (si < metaStr.rowCount()) {
        if (metaStr.cell(si, 0) == "register_code") {
            s.register_code = metaStr.cell(si, 1)
        }
        si += 1
    }

    /*
     * next_* 兜底（**只抬不降**）：取 max(meta 里的值, 已有最大 id + 1)。
     *
     * 空库时 meta 里没有这几行 → 抬到 1（与文件后端的"文件不存在 → 默认 Store"一致）。
     *
     * ⚠ 为什么不是"只在缺失（< 1）时才兜底"（2026-09-20 修）：
     *   `next_*` 是**下一个要分配的 id**。若它比库里已有的最大 id 还小，新建记录算出来的 id
     *   就会**命中一条已有行**，而落盘走的是 `REPLACE INTO` —— 那条无关的成员/任务会被
     *   **静默覆盖**（本项目最不能接受的一类失败，见 store.cj 顶部"绝不静默降级"那一段）。
     *   这个局面并不需要"有人手工改库"才会出现：任何"绕过 club-server 往库里批量插行"
     *   都会留下它 —— 我们自己的 `tests/bench.ps1` 造数就是 `INSERT ... SELECT` 之后
     *   必须再补一句 `UPDATE meta ... next_member`，它的注释里写着"否则新注册会和
     *   克隆出来的 id 撞车"。抬高是**安全方向**（id 只前进，大不了跳几个号），
     *   所以这里不做条件判断，四个计数器一律过一遍 idFloor。
     */
    s.next_dept = idFloor(s.next_dept, s.departments.keys())
    s.next_member = idFloor(s.next_member, s.members.keys())
    s.next_plan = idFloor(s.next_plan, s.plans.keys())
    s.next_task = idFloor(s.next_task, s.tasks.keys())

    /*
     * ⚠ **加载完立刻把"已落盘基准"设成这份状态**（增量落盘的前提，2026-09-20 修）。
     *
     * 为什么必须在这里设、不能等第一次写：
     *   增量写只做两件事 —— REPLACE 变化的行、DELETE「基准里有而内存里没有」的行。
     *   若基准一开始是空的（None），而库里**本来就有行**（重启后的正常情况就是如此），
     *   那么"从内存里删掉一行"就没人负责把它从库里删掉 —— 删除动作会被**静默丢掉**，
     *   下次重启它又回来了（最坏的一类不一致）。
     *   加载刚结束时"内存 == 库"是已知事实，所以这一刻正是设基准的最好时机。
     */
    let base = snapshotOf(s)
    s.persisted = Some(base)
    return s
}

/*
 * 逐表校验：数据库里有几行，就必须载入几条。
 *
 * 与 store.cj 的 checkLoaded 同一口径（P1 M-7）：条数不等意味着"记录损坏或主键重复"，
 * 宁可起不来，也不要带着残缺数据继续写。
 * 主键约束下这里只会因"解析时被跳过"而不等（例如空 token 的招募链接），
 * 正是那种"一条损坏记录被静默接受"的缺口要被挡住。
 */
func checkLoadedDb(label: String, rows: Int64, loaded: Int64): Unit {
    if (rows != loaded) {
        throw Exception("数据库表 ${label} 有 ${rows} 行，只载入 ${loaded} 条" +
            "（记录损坏或主键重复），已停止启动以免覆盖数据")
    }
}

/*
 * HashMap.keys() 返回的是 EquatableCollection<Int64>（接口），不是 ArrayList。
 * 这里就按接口收 —— 顺带把"我只要一个最大值"这件事说清楚。
 */
func maxKeyOf(keys: EquatableCollection<Int64>): Int64 {
    var best: Int64 = 0
    for (k in keys) {
        if (k > best) {
            best = k
        }
    }
    return best
}

/*
 * "下一个 id"的下限：至少是"已有最大 id + 1"（**只抬不降**）。
 *
 * 见 storeLoadDb 里那段注释：计数器落后于实际最大 id 时，新建记录会命中已有行，
 * 而落盘是 `REPLACE INTO` —— 会**静默覆盖**一条无关数据。抬高只会让 id 跳号，
 * 不会有任何副作用，所以这里不做条件判断，无条件取两者的较大值。
 */
func idFloor(cur: Int64, keys: EquatableCollection<Int64>): Int64 {
    let need = maxKeyOf(keys) + 1
    return if (cur > need) { cur } else { need }
}

/*
 * 整数列取值。非法值**不吞**：直接抛，让 storeLoadDb 的调用方看到明确异常
 * （加载期的目标是"要么全对、要么明确报错"）。
 */
func parseIntOr(v: String, d: Int64): Int64 {
    if (v.size == 0) {
        return d
    }
    try {
        return Int64.parse(v)
    } catch (e: Exception) {
        throw Exception("数据库列值不是合法整数：${v}")
    }
}

/*
 * TINYINT 的布尔：我方的 *ToJson 产出 true/false，数据库里是 1/0。
 * 两种都认（"1"/"true" → true，"0"/"false" → false），空串取默认值。
 */
func parseBoolOr(v: String, d: Bool): Bool {
    if (v.size == 0) {
        return d
    }
    if (v == "0" || v == "false" || v == "FALSE") {
        return false
    }
    return true
}

/*
 * 下面 7 个 loadXxx 的 SELECT 列序 = store.cj 里对应 *FromJson 的读取顺序
 * （JSON 键名与 SQL 列名不同的只有 `desc`，SQL 保留字加反引号）。
 * 改字段时两边一起改 —— 这就是"只有一个字段清单"的代价与收益。
 */

func loadDepartments(ms: MysqlStore): HashMap<Int64, Department> {
    let rs = ms.q("SELECT id, name, sort FROM departments", Array<DbValue>())
    let m = HashMap<Int64, Department>()
    var i: Int64 = 0
    while (i < rs.rowCount()) {
        let o = JsonObject()
        jPutInt(o, "id", parseIntOr(rs.cell(i, 0), 0))
        jPutStr(o, "name", rs.cell(i, 1))
        jPutInt(o, "sort", parseIntOr(rs.cell(i, 2), 0))
        let d = deptFromJson(o)
        m[d.id] = d
        i += 1
    }
    checkLoadedDb("departments", rs.rowCount(), m.size)
    return m
}

func loadMembers(ms: MysqlStore): HashMap<Int64, Member> {
    let rs = ms.q("SELECT id, name, phone, pw_algo, pw_iter, pw_salt, pw_hash, role," +
        " dept_id, dept_hint, status, joined_at FROM members", Array<DbValue>())
    let m = HashMap<Int64, Member>()
    var i: Int64 = 0
    while (i < rs.rowCount()) {
        let o = JsonObject()
        jPutInt(o, "id", parseIntOr(rs.cell(i, 0), 0))
        jPutStr(o, "name", rs.cell(i, 1))
        jPutStr(o, "phone", rs.cell(i, 2))
        jPutStr(o, "pw_algo", rs.cell(i, 3))
        jPutInt(o, "pw_iter", parseIntOr(rs.cell(i, 4), 0))
        jPutStr(o, "pw_salt", rs.cell(i, 5))
        jPutStr(o, "pw_hash", rs.cell(i, 6))
        jPutStr(o, "role", rs.cell(i, 7))
        jPutInt(o, "dept_id", parseIntOr(rs.cell(i, 8), 0))
        jPutInt(o, "dept_hint", parseIntOr(rs.cell(i, 9), 0))
        jPutStr(o, "status", rs.cell(i, 10))
        jPutInt(o, "joined_at", parseIntOr(rs.cell(i, 11), 0))
        let x = memberFromJson(o)
        m[x.id] = x
        i += 1
    }
    checkLoadedDb("members", rs.rowCount(), m.size)
    return m
}

func loadPlans(ms: MysqlStore): HashMap<Int64, Plan> {
    let rs = ms.q("SELECT id, title, `desc`, parent_id, owner_id, dept_id, due_at," +
        " created_by, created_at, updated_at FROM plans", Array<DbValue>())
    let m = HashMap<Int64, Plan>()
    var i: Int64 = 0
    while (i < rs.rowCount()) {
        let o = JsonObject()
        jPutInt(o, "id", parseIntOr(rs.cell(i, 0), 0))
        jPutStr(o, "title", rs.cell(i, 1))
        jPutStr(o, "desc", rs.cell(i, 2))
        jPutInt(o, "parent_id", parseIntOr(rs.cell(i, 3), 0))
        jPutInt(o, "owner_id", parseIntOr(rs.cell(i, 4), 0))
        jPutInt(o, "dept_id", parseIntOr(rs.cell(i, 5), 0))
        jPutInt(o, "due_at", parseIntOr(rs.cell(i, 6), 0))
        jPutInt(o, "created_by", parseIntOr(rs.cell(i, 7), 0))
        jPutInt(o, "created_at", parseIntOr(rs.cell(i, 8), 0))
        jPutInt(o, "updated_at", parseIntOr(rs.cell(i, 9), 0))
        let x = planFromJson(o)
        m[x.id] = x
        i += 1
    }
    checkLoadedDb("plans", rs.rowCount(), m.size)
    return m
}

func loadTasks(ms: MysqlStore): HashMap<Int64, Task> {
    let rs = ms.q("SELECT id, title, `desc`, owner_id, plan_id, dept_id, status, blocker," +
        " help_dept_id, help_member_id, due_at, updated_at, completed_at, deleted_at," +
        " source, created_by, created_at FROM tasks", Array<DbValue>())
    let m = HashMap<Int64, Task>()
    var i: Int64 = 0
    while (i < rs.rowCount()) {
        let o = JsonObject()
        jPutInt(o, "id", parseIntOr(rs.cell(i, 0), 0))
        jPutStr(o, "title", rs.cell(i, 1))
        jPutStr(o, "desc", rs.cell(i, 2))
        jPutInt(o, "owner_id", parseIntOr(rs.cell(i, 3), 0))
        jPutInt(o, "plan_id", parseIntOr(rs.cell(i, 4), 0))
        jPutInt(o, "dept_id", parseIntOr(rs.cell(i, 5), 0))
        jPutStr(o, "status", rs.cell(i, 6))
        jPutStr(o, "blocker", rs.cell(i, 7))
        jPutInt(o, "help_dept_id", parseIntOr(rs.cell(i, 8), 0))
        jPutInt(o, "help_member_id", parseIntOr(rs.cell(i, 9), 0))
        jPutInt(o, "due_at", parseIntOr(rs.cell(i, 10), 0))
        jPutInt(o, "updated_at", parseIntOr(rs.cell(i, 11), 0))
        jPutInt(o, "completed_at", parseIntOr(rs.cell(i, 12), 0))
        jPutInt(o, "deleted_at", parseIntOr(rs.cell(i, 13), 0))
        jPutStr(o, "source", rs.cell(i, 14))
        jPutInt(o, "created_by", parseIntOr(rs.cell(i, 15), 0))
        jPutInt(o, "created_at", parseIntOr(rs.cell(i, 16), 0))
        let x = taskFromJson(o)
        m[x.id] = x
        i += 1
    }
    checkLoadedDb("tasks", rs.rowCount(), m.size)
    return m
}

func loadLinks(ms: MysqlStore): HashMap<String, DeptInviteLink> {
    let rs = ms.q("SELECT `token`, dept_id, enabled, created_by, created_at FROM invite_links",
        Array<DbValue>())
    let m = HashMap<String, DeptInviteLink>()
    var i: Int64 = 0
    while (i < rs.rowCount()) {
        let o = JsonObject()
        jPutStr(o, "token", rs.cell(i, 0))
        jPutInt(o, "dept_id", parseIntOr(rs.cell(i, 1), 0))
        jPutBool(o, "enabled", parseBoolOr(rs.cell(i, 2), true))
        jPutInt(o, "created_by", parseIntOr(rs.cell(i, 3), 0))
        jPutInt(o, "created_at", parseIntOr(rs.cell(i, 4), 0))
        let x = linkFromJson(o)
        /* 空 token 记录跳过不放进 map：与文件后端同口径（条数不等 → checkLoadedDb 拒绝启动）。 */
        if (x.token.size > 0) {
            m[x.token] = x
        }
        i += 1
    }
    checkLoadedDb("invite_links", rs.rowCount(), m.size)
    return m
}

func loadTokens(ms: MysqlStore): HashMap<String, TokenRecord> {
    let rs = ms.q("SELECT `token`, member_id, created_at, expires_at FROM tokens", Array<DbValue>())
    let m = HashMap<String, TokenRecord>()
    var i: Int64 = 0
    while (i < rs.rowCount()) {
        let tok = rs.cell(i, 0)
        if (tok.size > 0) {
            let o = JsonObject()
            jPutStr(o, "token", tok)
            jPutInt(o, "member_id", parseIntOr(rs.cell(i, 1), 0))
            jPutInt(o, "created_at", parseIntOr(rs.cell(i, 2), 0))
            jPutInt(o, "expires_at", parseIntOr(rs.cell(i, 3), 0))
            m[tok] = tokenFromJson(o)
        }
        i += 1
    }
    checkLoadedDb("tokens", rs.rowCount(), m.size)
    return m
}

func ensureIdemColumns(ms: MysqlStore): Unit {
    let have = HashSet<String>()
    let rs = ms.q("SELECT column_name FROM information_schema.columns " +
                  "WHERE table_schema = DATABASE() AND table_name = 'idem'", Array<DbValue>())
    var i: Int64 = 0
    while (i < rs.rowCount()) {
        have.add(rs.cell(i, 0))
        i += 1
    }
    if (!have.contains("payload")) {
        ms.x("ALTER TABLE idem ADD COLUMN payload TEXT NOT NULL", Array<DbValue>())
    }
    if (!have.contains("used_at")) {
        ms.x("ALTER TABLE idem ADD COLUMN used_at BIGINT NOT NULL DEFAULT 0", Array<DbValue>())
    }
}

/* ===================== schema 版本管理（P2-2）===================== */

/*
 * 迁移登记表：记录**已经应用过**的迁移。
 *
 * 为什么需要它 —— `CREATE TABLE IF NOT EXISTS` 只处理「表不存在」，
 * **对已存在的表不会补列 / 不会改列**。老库升级时列缺失，症状是**启动直接失败**：
 * 2026-10-06 实测到 `Unknown column 'payload'`（统一库跑单测时踩到，评审 **P2-2**）。
 *
 * 设计口径是**两条腿走路**：
 *   · **能自省的**（查 `information_schema` 就知道缺不缺列）→ **每次启动都自省一遍**。
 *     这比只看版本号稳：版本表被误改、或从混合备份恢复，也照样能起。
 *   · **不能自省的**（数据回填、枚举改名、口径变更）→ 用版本号做闸门，**只跑一次**。
 * 所以下面 v1 的自省检查在版本闸门之外**也**跑一遍 —— 重复执行是无害的。
 */
public let SCHEMA_VERSION_CURRENT: Int64 = 1

func ensureSchemaVersionTable(ms: MysqlStore): Unit {
    ms.x("CREATE TABLE IF NOT EXISTS schema_version (" +
         "version BIGINT NOT NULL, applied_at BIGINT NOT NULL DEFAULT 0, " +
         "note VARCHAR(255) NOT NULL DEFAULT '', " +
         "PRIMARY KEY (version)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4", Array<DbValue>())
}

func schemaVersionApplied(ms: MysqlStore, version: Int64): Bool {
    let rs = ms.q("SELECT version FROM schema_version WHERE version = ?", [DbInt(version)])
    return rs.rowCount() > 0
}

func schemaVersionMark(ms: MysqlStore, version: Int64, note: String): Unit {
    /* INSERT IGNORE：两个进程同时首启时不会因为主键冲突而失败 */
    ms.x("INSERT IGNORE INTO schema_version (version, applied_at, note) VALUES (?, ?, ?)",
         [DbInt(version), DbInt(nowEpoch()), S(note)])
}

/*
 * 按版本号执行迁移。**调用方不需要先建 schema_version**（本函数自己建）。
 *
 * ⚠ 以后新增迁移的写法：
 *     if (!schemaVersionApplied(ms, 2)) {
 *         <迁移体，尽量写成幂等的>
 *         schemaVersionMark(ms, 2, "一句话说明")
 *     }
 *   并同时把 SCHEMA_VERSION_CURRENT 提到 2。
 */
public func ensureMigrations(ms: MysqlStore): Unit {
    ensureSchemaVersionTable(ms)

    /* ---- v1：`idem` 补 payload / used_at（2026-10-06，P2 写操作提议令牌）---- */
    ensureIdemColumns(ms)
    if (!schemaVersionApplied(ms, 1)) {
        schemaVersionMark(ms, 1, "idem + payload/used_at")
    }
}

func loadIdem(ms: MysqlStore): HashMap<String, IdemRecord> {
    let rs = ms.q("SELECT `key`, resource_id, created_at, payload, used_at FROM idem", Array<DbValue>())
    let m = HashMap<String, IdemRecord>()
    var i: Int64 = 0
    while (i < rs.rowCount()) {
        let k = rs.cell(i, 0)
        if (k.size > 0) {
            let r = IdemRecord()
            r.resource_id = parseIntOr(rs.cell(i, 1), 0)
            r.created_at = parseIntOr(rs.cell(i, 2), 0)
            r.payload = rs.cell(i, 3)
            r.used_at = parseIntOr(rs.cell(i, 4), 0)
            m[k] = r
        }
        i += 1
    }
    checkLoadedDb("idem", rs.rowCount(), m.size)
    return m
}

/* ===================== 参数绑定：MySQL 口径的字符串值 ===================== */

/*
 * ⚠ 把字符串**交给框架绑定之前**必须过这一层，理由是一个真实的数据损坏缺陷
 *   （2026-09-20 写 MySQL 往返单测时被断言抓住，见 tests.cj 的 testMysqlRoundTrip）。
 *
 * 框架的 SqlValue 绑定（db.cj 的 dbValueLiteral → sqlQuote → sqlEscape）只把单引号
 * 双写（`'` → `''`），这是 **SQL 标准**转义。而 MySQL / MariaDB **默认还开着一层
 * 反斜杠转义**（除非 sql_mode 里有 NO_BACKSLASH_ESCAPES）：
 *     · `\` 会被当成转义引导符吃掉 —— "与 \ 反斜杠" 存进去变成 "与  反斜杠"；
 *     · 更糟的是**值以单个反斜杠结尾**时（如 `C:\temp\`），那个反斜杠会把**收尾的单引号
 *       也转义掉**，SQL 词法直接跑飞（语法错，或表面成功但语义变了）。
 * 这正是 db.cj 的 `sqlEscape` 注释里已经写明的"残余风险"，它建议"服务端设置
 * NO_BACKSLASH_ESCAPES 消除"，但那需要 SUPER 权限、且会影响同实例上的别人 ——
 * 不是我们能在应用侧单方面依赖的前提（本机 MariaDB 实测 sql_mode 里**没有**它）。
 *
 * 处置：在绑定前把 `\` 也双写。默认模式下 MySQL 会把 `\\` 还原成一个 `\`，
 * 于是"存进去什么、读出来就是什么"；而在开了 NO_BACKSLASH_ESCAPES 的服务器上，
 * `\\` 被原样当成两个反斜杠 —— ⚠ **那种配置下本函数会多存一个反斜杠**，
 * 所以 ensureSchema 之外还有一条启动期提示（main.cj 加载时打印 sql_mode 状态）。
 * 两条路都留着记录：这是"框架绑定不完整"的代价，不是我们想选的方案。
 *
 * ⚠ **转义只能做一次**，这就是本文件里两条写值路径的分工（2026-09-20 把这段写清楚：
 *   原文写的是"所有进 SQL 的字符串都要走 `mysqlStr(...)` 再给 DbStr"，那句话与代码相反 ——
 *   照它做会**多转义一层**，反斜杠在库里变成两个。真正约定是：
 *
 *   (a) **走 insertBatched/replaceBatched 的行数组**（落盘的绝大多数值）：
 *       里放**原始值** `DbStr(raw)`。转义由 `insertBatched` 末尾的 `safeBind(v)` 统一做一遍。
 *       ⚠ 这里**不要**再包 `S(...)`：那会变成"转义两次"，`a\b` 最后存成 `a\\b`。
 *   (b) **单独发的语句**（`DELETE ... WHERE pk = ?`、`meta` 的整表替换等）：
 *       自己用 `S(v)` 包（它们不经 insertBatched）。
 *
 *   两条路都**恰好一次**。判断方法很简单：值的数组如果最终交给 `insertBatched`，
 *   就写 `DbStr`；如果是直接 `ms.x(sql, [ ... ])`，就写 `S(v)`。
 *   整数/布尔不受影响（它们不加引号，无需转义）。
 *
 *   回归闸门：`tests.cj` 的 `testMysqlRoundTrip` 用"含单引号 + 反斜杠"的描述值往返比对 ——
 *   两层或零层转义都会被它当场抓住。
 */
func mysqlSafe(v: String): String {
    if (!containsAscii(v, "\\")) {
        return v
    }
    return String.join(v.split("\\", -1, removeEmpty: false), delimiter: "\\\\")
}

/* 值：字符串走 mysqlSafe，其余按类型直接包（数字/布尔没有转义面）。**仅用于不经 insertBatched 的语句**。 */
func S(v: String): DbValue {
    return DbStr(mysqlSafe(v))
}

func I(v: Int64): DbValue {
    return DbInt(v)
}

func B(v: Bool): DbValue {
    return DbBool(v)
}

/* ===================== 落盘：内存 Store → MySQL（一个事务） ===================== */

/*
 * 每批最多多少行合并进一条 INSERT。
 *
 * 500 行的 members 行大约 500 * (几十字节~几百字节) ≈ 200 KB 量级，
 * 离 max_allowed_packet 的默认 16 MB 很远；同时把 1000 行的往返从 1000 次压到 2 次。
 */
let BATCH_ROWS: Int64 = 500

/*
 * 上次落盘时的**快照**（用于算增量）。
 *
 * 为什么需要它：第一版实现是"每次变更都 DELETE 全表 + 重新 INSERT 全部行" ——
 * 语义没错（跨表一致），但**代价随库的大小走**：`tests/bench.ps1` 实测
 * 1000 成员 + 1000 任务时，**建一个任务要 1511 ms**（文件后端同规模是 56 ms），
 * 因为每次提交都要重写几千行。而 club-server 的写入是"请求链末端同步落盘"，
 * 所以这个代价直接变成每个写接口的延迟。
 *
 * 现在改成**算增量**：只把"这一轮真正变了的东西"写进库
 *   · 新增/修改的行 → REPLACE INTO（主键命中即覆盖）
 *   · 删除的行       → DELETE WHERE pk=?（逐个删，绝不 `DELETE FROM t`）
 *   · 没变的表       → 一条 SQL 都不发
 * 于是单次写入的代价回到 O(本次改动量)，而**语义与"整体替换"完全等价**
 * （同一事务内；提交仍在响应之前 —— 见 writeDbToMysql 的注释）。
 *
 * 它是普通类而不是 JsonObject：字段是强类型的，改字段时编译期就会提醒。
 * 必须是 public：Store 有一个 public 字段（`persisted`）用它做类型。
 */
public class PersistedState {
    public var departments: HashMap<Int64, Department> = HashMap<Int64, Department>()
    public var members: HashMap<Int64, Member> = HashMap<Int64, Member>()
    public var plans: HashMap<Int64, Plan> = HashMap<Int64, Plan>()
    public var tasks: HashMap<Int64, Task> = HashMap<Int64, Task>()
    public var invite_links: HashMap<String, DeptInviteLink> = HashMap<String, DeptInviteLink>()
    public var tokens: HashMap<String, TokenRecord> = HashMap<String, TokenRecord>()
    public var idem: HashMap<String, IdemRecord> = HashMap<String, IdemRecord>()
    /* 计数器与注册配置（对应 meta / meta_str 两张表） */
    public var next_dept: Int64 = 0
    public var next_member: Int64 = 0
    public var next_plan: Int64 = 0
    public var next_task: Int64 = 0
    public var register_code: String = ""
    public var register_code_by: Int64 = 0
    public var register_code_at: Int64 = 0

    public init() {}
}

/*
 * 从内存 Store 取一份持久化快照。
 *
 * ⚠ **值语义拷贝**：club-server 的写入是"就地改内存对象"（`m.name = x`），
 * 所以这里必须逐字段**拷一份**，不能只存引用 —— 否则"上一次落盘的状态"
 * 会跟着内存一起变，增量永远算成"没有变化"。
 * 取快照的地方在 `s.lock` 内（storeSnapshot），与读内存表同一把锁，因此是一致的。
 */
func snapshotOf(s: Store): PersistedState {
    let st = PersistedState()
    copyEntitiesInto(s, st)
    st.next_dept = s.next_dept
    st.next_member = s.next_member
    st.next_plan = s.next_plan
    st.next_task = s.next_task
    st.register_code = s.register_code
    st.register_code_by = s.register_code_by
    st.register_code_at = s.register_code_at
    return st
}

/*
 * 把 7 张内存表**逐字段拷**进快照。
 *
 * 单独抽出来是为了让 storeLoadDb 也能用它设"已落盘基准"
 * （见那里关于"为什么加载后要立刻设基准"的注释）。
 */
func copyEntitiesInto(s: Store, st: PersistedState): Unit {
    for ((k, d) in s.departments) {
        let c = Department()
        c.id = d.id
        c.name = d.name
        c.sort = d.sort
        st.departments[k] = c
    }
    for ((k, m) in s.members) {
        let c = Member()
        c.id = m.id
        c.name = m.name
        c.phone = m.phone
        c.pw_algo = m.pw_algo
        c.pw_iter = m.pw_iter
        c.pw_salt = m.pw_salt
        c.pw_hash = m.pw_hash
        c.role = m.role
        c.dept_id = m.dept_id
        c.dept_hint = m.dept_hint
        c.status = m.status
        c.joined_at = m.joined_at
        st.members[k] = c
    }
    for ((k, p) in s.plans) {
        let c = Plan()
        c.id = p.id
        c.title = p.title
        c.desc = p.desc
        c.parent_id = p.parent_id
        c.owner_id = p.owner_id
        c.dept_id = p.dept_id
        c.due_at = p.due_at
        c.created_by = p.created_by
        c.created_at = p.created_at
        c.updated_at = p.updated_at
        st.plans[k] = c
    }
    for ((k, t) in s.tasks) {
        let c = Task()
        c.id = t.id
        c.title = t.title
        c.desc = t.desc
        c.owner_id = t.owner_id
        c.plan_id = t.plan_id
        c.dept_id = t.dept_id
        c.status = t.status
        c.blocker = t.blocker
        c.help_dept_id = t.help_dept_id
        c.help_member_id = t.help_member_id
        c.due_at = t.due_at
        c.updated_at = t.updated_at
        c.completed_at = t.completed_at
        c.deleted_at = t.deleted_at
        c.source = t.source
        c.created_by = t.created_by
        c.created_at = t.created_at
        st.tasks[k] = c
    }
    for ((k, l) in s.invite_links) {
        let c = DeptInviteLink()
        c.token = l.token
        c.dept_id = l.dept_id
        c.enabled = l.enabled
        c.created_by = l.created_by
        c.created_at = l.created_at
        st.invite_links[k] = c
    }
    for ((k, t) in s.tokens) {
        let c = TokenRecord()
        c.member_id = t.member_id
        c.created_at = t.created_at
        c.expires_at = t.expires_at
        st.tokens[k] = c
    }
    for ((k, r) in s.idem) {
        let c = IdemRecord()
        c.resource_id = r.resource_id
        c.created_at = r.created_at
        c.payload = r.payload
        c.used_at = r.used_at
        st.idem[k] = c
    }
}

/* 逐字段相等判定（用来决定"这一行要不要写"）。 */

func deptSame(a: Department, b: Department): Bool {
    return a.id == b.id && a.name == b.name && a.sort == b.sort
}

func memberSame(a: Member, b: Member): Bool {
    return a.id == b.id && a.name == b.name && a.phone == b.phone && a.pw_algo == b.pw_algo &&
        a.pw_iter == b.pw_iter && a.pw_salt == b.pw_salt && a.pw_hash == b.pw_hash &&
        a.role == b.role && a.dept_id == b.dept_id && a.dept_hint == b.dept_hint &&
        a.status == b.status && a.joined_at == b.joined_at
}

func planSame(a: Plan, b: Plan): Bool {
    return a.id == b.id && a.title == b.title && a.desc == b.desc && a.parent_id == b.parent_id &&
        a.owner_id == b.owner_id && a.dept_id == b.dept_id && a.due_at == b.due_at &&
        a.created_by == b.created_by && a.created_at == b.created_at && a.updated_at == b.updated_at
}

func taskSame(a: Task, b: Task): Bool {
    return a.id == b.id && a.title == b.title && a.desc == b.desc && a.owner_id == b.owner_id &&
        a.plan_id == b.plan_id && a.dept_id == b.dept_id && a.status == b.status &&
        a.blocker == b.blocker && a.help_dept_id == b.help_dept_id &&
        a.help_member_id == b.help_member_id && a.due_at == b.due_at &&
        a.updated_at == b.updated_at && a.completed_at == b.completed_at &&
        a.deleted_at == b.deleted_at && a.source == b.source && a.created_by == b.created_by &&
        a.created_at == b.created_at
}

func linkSame(a: DeptInviteLink, b: DeptInviteLink): Bool {
    return a.token == b.token && a.dept_id == b.dept_id && a.enabled == b.enabled &&
        a.created_by == b.created_by && a.created_at == b.created_at
}

func tokenSame(a: TokenRecord, b: TokenRecord): Bool {
    return a.member_id == b.member_id && a.created_at == b.created_at && a.expires_at == b.expires_at
}

func idemSame(a: IdemRecord, b: IdemRecord): Bool {
    return a.resource_id == b.resource_id && a.created_at == b.created_at &&
        a.payload == b.payload && a.used_at == b.used_at
}

/*
 * meta 的两张表用"整体替换"（各 7 行，代价可忽略）。
 * 但**先比一次**：什么都没变就连这两条 SQL 都不发 —— 只读请求（GET）下
 * storeSave 根本不会被调用，所以这条路径正常不会走到；这里保守一点没坏处。
 */
func metaSame(a: PersistedState, b: PersistedState): Bool {
    return a.next_dept == b.next_dept && a.next_member == b.next_member &&
        a.next_plan == b.next_plan && a.next_task == b.next_task &&
        a.register_code == b.register_code && a.register_code_by == b.register_code_by &&
        a.register_code_at == b.register_code_at
}

/*
 * 把**一份已取好的快照**写进 MySQL（**增量**，一个事务）。
 *
 * `cur` 是待落盘的状态（**值语义拷贝**，由 storeSnapshot 在 `s.lock` 内取好，见 S-2）；
 * `s.persisted` 是上一次成功落盘的状态。**若两者逐字段相同，本函数一条 SQL 都不发** ——
 * 这也是"没改动就不写库"的保证。
 *
 * ⚠ **`cur` 必须是锁内取好的拷贝，本函数绝不再现读内存表**（2026-10-04 修的 S-2 数据竞争）：
 *   原先这里自己调 `snapshotOf(s)`，而那时只持 `save_lock`、没持 `s.lock`，
 *   handler 正持 `s.lock` 改同一批 `HashMap`（`HashMap` 非线程安全）。后果不只是 UB：
 *   **撕裂出来的一行会被 REPLACE 回库，并被记成新的"已落盘基准"**，之后不再有写入
 *   去纠正它，等于把不一致持久化下来。见 docs/mysql-backend.md §12.11。
 *
 * ⚠ 事务提交发生在**响应发出之前**：调用链是
 *     请求链末端 snapshotFlush → flushPending → writeSnapshot → writeDbToMysql（这里）
 *   而 snapshotFlush 挂在 router 之前、ctx.commit() 之前（见 main.cj 的中间件顺序说明）。
 *   所以 **HTTP 200 依旧代表数据已经落进数据库**，这条 L-7 立下的强语义没有降级。
 *
 * ⚠ 调用方必须已持 `s.save_lock`（writeSnapshot 里就是这么做的）：
 *   序号守卫保证"新快照不会被旧快照覆盖"，这里不重复加锁。
 *
 * 参数化：所有**值**都走 DbStr / DbInt / DbBool；SQL 里拼进去的只有常量列名、表名、`?`。
 * ⚠ 行数组里放的是**原始值**，字符串**不要**自己再包一层 `S(...)`：转义由 insertBatched 的
 *   safeBind 统一做**一次**（写两次就会在库里变成两个反斜杠）。分工见 mysqlSafe 的长注释。
 */
public func writeDbToMysql(s: Store, cur: PersistedState): Unit {
    let ms = match (s.mysql) {
        case Some(x) => x
        case None => return
    }
    let empty = PersistedState()
    /* 首次落盘（或还没记录过基准）→ 按"全库都是新的"走：REPLACE 全部行即可，
     * 不需要先 DELETE（REPLACE 按主键覆盖，且此时库里本来就不该有别的行）。 */
    let prev: PersistedState = match (s.persisted) {
        case Some(x) => x
        case None => empty
    }

    ms.tx {
        /* ---- departments ---- */
        let deptCols = ["id", "name", "sort"]
        let deptRows = ArrayList<Array<DbValue>>()
        for ((_k, d) in cur.departments) {
            let same = match (prev.departments.get(d.id)) {
                case Some(o) => deptSame(o, d)
                case None => false
            }
            if (!same) {
                deptRows.add([DbInt(d.id), DbStr(d.name), DbInt(d.sort)])
            }
        }
        replaceBatched(ms, "departments", deptCols, deptRows)
        for ((k, _o) in prev.departments) {
            if (!cur.departments.contains(k)) {
                ms.x("DELETE FROM departments WHERE id = ?", [I(k)])
            }
        }

        /* ---- members ---- */
        let memberCols = ["id", "name", "phone", "pw_algo", "pw_iter", "pw_salt", "pw_hash",
                          "role", "dept_id", "dept_hint", "status", "joined_at"]
        let memberRows = ArrayList<Array<DbValue>>()
        for ((_k, m) in cur.members) {
            let same = match (prev.members.get(m.id)) {
                case Some(o) => memberSame(o, m)
                case None => false
            }
            if (!same) {
                memberRows.add([DbInt(m.id), DbStr(m.name), DbStr(m.phone), DbStr(m.pw_algo),
                                DbInt(m.pw_iter), DbStr(m.pw_salt), DbStr(m.pw_hash), DbStr(m.role),
                                DbInt(m.dept_id), DbInt(m.dept_hint), DbStr(m.status),
                                DbInt(m.joined_at)])
            }
        }
        replaceBatched(ms, "members", memberCols, memberRows)
        for ((k, _o) in prev.members) {
            if (!cur.members.contains(k)) {
                ms.x("DELETE FROM members WHERE id = ?", [I(k)])
            }
        }

        /* ---- plans ---- */
        let planCols = ["id", "title", "`desc`", "parent_id", "owner_id", "dept_id", "due_at",
                        "created_by", "created_at", "updated_at"]
        let planRows = ArrayList<Array<DbValue>>()
        for ((_k, p) in cur.plans) {
            let same = match (prev.plans.get(p.id)) {
                case Some(o) => planSame(o, p)
                case None => false
            }
            if (!same) {
                planRows.add([DbInt(p.id), DbStr(p.title), DbStr(p.desc), DbInt(p.parent_id),
                              DbInt(p.owner_id), DbInt(p.dept_id), DbInt(p.due_at),
                              DbInt(p.created_by), DbInt(p.created_at), DbInt(p.updated_at)])
            }
        }
        replaceBatched(ms, "plans", planCols, planRows)
        for ((k, _o) in prev.plans) {
            if (!cur.plans.contains(k)) {
                ms.x("DELETE FROM plans WHERE id = ?", [I(k)])
            }
        }

        /* ---- tasks ---- */
        let taskCols = ["id", "title", "`desc`", "owner_id", "plan_id", "dept_id", "status",
                        "blocker", "help_dept_id", "help_member_id", "due_at", "updated_at",
                        "completed_at", "deleted_at", "source", "created_by", "created_at"]
        let taskRows = ArrayList<Array<DbValue>>()
        for ((_k, t) in cur.tasks) {
            let same = match (prev.tasks.get(t.id)) {
                case Some(o) => taskSame(o, t)
                case None => false
            }
            if (!same) {
                taskRows.add([DbInt(t.id), DbStr(t.title), DbStr(t.desc), DbInt(t.owner_id),
                              DbInt(t.plan_id), DbInt(t.dept_id), DbStr(t.status), DbStr(t.blocker),
                              DbInt(t.help_dept_id), DbInt(t.help_member_id), DbInt(t.due_at),
                              DbInt(t.updated_at), DbInt(t.completed_at), DbInt(t.deleted_at),
                              DbStr(t.source), DbInt(t.created_by), DbInt(t.created_at)])
            }
        }
        replaceBatched(ms, "tasks", taskCols, taskRows)
        for ((k, _o) in prev.tasks) {
            if (!cur.tasks.contains(k)) {
                ms.x("DELETE FROM tasks WHERE id = ?", [I(k)])
            }
        }

        /* ---- invite_links ---- */
        let linkCols = ["`token`", "dept_id", "enabled", "created_by", "created_at"]
        let linkRows = ArrayList<Array<DbValue>>()
        for ((_k, l) in cur.invite_links) {
            let same = match (prev.invite_links.get(l.token)) {
                case Some(o) => linkSame(o, l)
                case None => false
            }
            if (!same) {
                linkRows.add([DbStr(l.token), DbInt(l.dept_id), DbBool(l.enabled),
                              DbInt(l.created_by), DbInt(l.created_at)])
            }
        }
        replaceBatched(ms, "invite_links", linkCols, linkRows)
        for ((k, _o) in prev.invite_links) {
            if (!cur.invite_links.contains(k)) {
                ms.x("DELETE FROM invite_links WHERE `token` = ?", [S(k)])
            }
        }

        /* ---- tokens ---- */
        let tokenCols = ["`token`", "member_id", "created_at", "expires_at"]
        let tokenRows = ArrayList<Array<DbValue>>()
        for ((k, t) in cur.tokens) {
            let same = match (prev.tokens.get(k)) {
                case Some(o) => tokenSame(o, t)
                case None => false
            }
            if (!same) {
                tokenRows.add([DbStr(k), DbInt(t.member_id), DbInt(t.created_at),
                               DbInt(t.expires_at)])
            }
        }
        replaceBatched(ms, "tokens", tokenCols, tokenRows)
        for ((k, _o) in prev.tokens) {
            if (!cur.tokens.contains(k)) {
                ms.x("DELETE FROM tokens WHERE `token` = ?", [S(k)])
            }
        }

        /* ---- idem ---- */
        let idemCols = ["`key`", "resource_id", "created_at", "payload", "used_at"]
        let idemRows = ArrayList<Array<DbValue>>()
        for ((k, r) in cur.idem) {
            let same = match (prev.idem.get(k)) {
                case Some(o) => idemSame(o, r)
                case None => false
            }
            if (!same) {
                idemRows.add([DbStr(k), DbInt(r.resource_id), DbInt(r.created_at),
                              DbStr(r.payload), DbInt(r.used_at)])
            }
        }
        replaceBatched(ms, "idem", idemCols, idemRows)
        for ((k, _o) in prev.idem) {
            if (!cur.idem.contains(k)) {
                ms.x("DELETE FROM idem WHERE `key` = ?", [S(k)])
            }
        }

        /* ---- meta：7 行，整体替换；没变则一条都不发 ---- */
        if (!metaSame(prev, cur)) {
            ms.x("DELETE FROM meta", Array<DbValue>())
            let metaCols = ["`k`", "v"]
            let metaRows = ArrayList<Array<DbValue>>()
            metaRows.add([DbStr("next_dept"), DbInt(cur.next_dept)])
            metaRows.add([DbStr("next_member"), DbInt(cur.next_member)])
            metaRows.add([DbStr("next_plan"), DbInt(cur.next_plan)])
            metaRows.add([DbStr("next_task"), DbInt(cur.next_task)])
            metaRows.add([DbStr("register_code_by"), DbInt(cur.register_code_by)])
            metaRows.add([DbStr("register_code_at"), DbInt(cur.register_code_at)])
            insertBatched(ms, "meta", metaCols, metaRows)

            ms.x("DELETE FROM meta_str", Array<DbValue>())
            let metaStrCols = ["`k`", "v"]
            let metaStrRows = ArrayList<Array<DbValue>>()
            metaStrRows.add([DbStr("register_code"), DbStr(cur.register_code)])
            insertBatched(ms, "meta_str", metaStrCols, metaStrRows)
        }
    }

    /* 提交成功后，把"已落盘基准"换成这一份 —— 下一次就能只写变化的部分。
     * 放在事务之后：万一事务抛了，基准不动，下次还会把同样的差异重写一遍（幂等）。 */
    s.persisted = Some(cur)
}

/*
 * 多行 REPLACE（每批最多 BATCH_ROWS 行），**参数化**：
 *   REPLACE INTO t (c1, c2) VALUES (?, ?), (?, ?), ...
 *
 * 为什么用 REPLACE 而不是 INSERT：增量写入时同一主键的行可能已经在库里
 * （改一个字段就是这种情形），REPLACE = "有则覆盖、无则插入"，一条语句搞定，
 * 不需要先 SELECT 判断存在性，也不会像 `INSERT ... ON DUPLICATE KEY UPDATE`
 * 那样要重复列出每个列名。
 * ⚠ REPLACE 的语义是"先 DELETE 再 INSERT"，所以**没有列默认值会被触发** ——
 * 我们每条都写全所有列，不受影响。
 *
 * 列名与表名都是本文件里的常量，值全部走 DbValue 绑定。
 *
 * ⚠ 字符串值在这里统一过 `mysqlSafe()`（见那里的长注释）：框架的 SQL 绑定只做
 *   SQL 标准的 `''` 转义，挡不住 MySQL 默认的反斜杠转义 —— 不经这一层，
 *   含 `\` 的姓名/任务描述（如 `C:\temp\`）会被吃掉字符，甚至把收尾引号转义掉。
 */
func replaceBatched(ms: MysqlStore, table: String, cols: Array<String>,
                    rows: ArrayList<Array<DbValue>>): Unit {
    insertBatched(ms, table, cols, rows, "REPLACE INTO ")
}

func insertBatched(ms: MysqlStore, table: String, cols: Array<String>,
                   rows: ArrayList<Array<DbValue>>): Unit {
    insertBatched(ms, table, cols, rows, "INSERT INTO ")
}

func insertBatched(ms: MysqlStore, table: String, cols: Array<String>,
                   rows: ArrayList<Array<DbValue>>, verb: String): Unit {
    if (rows.size == 0) {
        return
    }
    /* "(?, ?, …)" —— 列数决定占位符个数，只与 SQL 结构有关，与值无关。 */
    var group = "("
    var c: Int64 = 0
    while (c < cols.size) {
        if (c > 0) {
            group += ", "
        }
        group += "?"
        c += 1
    }
    group += ")"

    /* 列名清单是常量，拼进 SQL 是安全的；VALUES 里的值一律走 params 绑定。 */
    let head = verb + table + " (" + String.join(cols, delimiter: ", ") + ") VALUES "
    var start: Int64 = 0
    while (start < rows.size) {
        var end = start + BATCH_ROWS
        if (end > rows.size) {
            end = rows.size
        }
        var sql = head
        let params = ArrayList<DbValue>()
        var i = start
        while (i < end) {
            if (i > start) {
                sql += ", "
            }
            sql += group
            for (v in rows[i]) {
                params.add(safeBind(v))
            }
            i += 1
        }
        ms.x(sql, params.toArray())
        start = end
    }
}

/* 一个绑定值过一趟"MySQL 口径"：字符串加反斜杠转义，其余原样。 */
func safeBind(v: DbValue): DbValue {
    match (v) {
        case DbStr(s) => return DbStr(mysqlSafe(s))
        case _ => return v
    }
}
