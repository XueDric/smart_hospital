/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 *
 * ===== db_bootstrap.cj —— MySQL 建连与初始化 ==============================
 *
 * 职责：把「连库」这件事做对，并把基线踩过的三个坑一次挡掉：
 *
 *   坑 1（致命）**连接字符集**：驱动握手把会话字符集写死成 utf8mb3（id 33），
 *        而库与表都是 utf8mb4 —— 于是**一个 4 字节 UTF-8 字符（emoji）就让之后
 *        所有写入持续报 1366 直到重启**。轻舟框架 db_mysql.cj **没有字符集参数**。
 *        处置：建连后立刻 `SET NAMES utf8mb4`，**失败直接抛，不静默继续**。
 *        依据：baseline/server/src/mysql_store.cj:201-208、baseline/docs/API-NOTES.md 坑 44
 *
 *   坑 2 **驱动注册**：db_mysql.cj 是"编译期零驱动依赖、运行时按注册名查找"，
 *        所以驱动必须在**某个被编译的文件里 import 过**才会注册 ——
 *        仅靠 `-l:mariadb.cdbc` 链接是不够的。
 *        处置：本文件顶层 `import mariadb.cdbc.*`。
 *
 *   坑 3 **反斜杠转义约定**必须二选一、不能都做：
 *        框架默认 `noBackslashEscapes: true`（会话固定 NO_BACKSLASH_ESCAPES，
 *        与框架的 `''` 转义一致）。基线实际传的是 `false` 并自己负责反斜杠加倍。
 *        本项目选择**沿用基线口径 `false`**（与 baseline mysql_store.cj:158 一致），
 *        并且**不在业务层做任何反斜杠加倍** —— 参数一律走 DbValue 绑定，
 *        由框架的 bindSql 负责安全字面量化（db.cj:113-131）。
 */

package qingzhou

// Int64.parse 需要它（仓颉不自动导入 std.convert）
import std.convert.*

// 坑 2：必须 import 才会注册驱动（db_mysql.cj 运行时按注册名 "mysql"→"mariadb" 查找）
import mariadb.cdbc.*

/* MySQL 连接配置。 */
public class MySqlConfig {
    public var host: String = "127.0.0.1"
    public var port: Int64 = 3307
    public var user: String = "hospital"
    public var pass: String = ""
    public var db: String = "hospital"

    public init() {}

    public init(host: String, port: Int64, user: String, pass: String, db: String) {
        this.host = host
        this.port = port
        this.user = user
        this.pass = pass
        this.db = db
    }

    /* 日志/报错用的描述，**绝不回显口令**。 */
    public func describe(): String {
        return "${user}@${host}:${port}/${db}"
    }
}

/*
 * 解析 DSN：`mysql://user:pass@host:port/db`
 *
 * 拆分规则与框架 db_factory.cj:85-92 保持一致（避免出现两套口径）：
 *   · userinfo 与 host 在**最后一个 `@`** 处切分（口令里可能含 `@`）
 *   · user 与 password 在**第一个 `:`** 处切分
 *   · host 与 port 在**最后一个 `:`** 处切分
 *
 * 解析失败抛异常并给出期望格式 —— 比"连不上"有用。
 */
public func parseDsn(dsn: String): MySqlConfig {
    var s = dsn
    if (s.startsWith("mysql://")) {
        s = s[8..]
    }
    // ⚠ 仓颉的 indexOf/lastIndexOf 返回 ?Int64（不是 -1 哨兵）——
    //   所以用 isNone()/getOrThrow() 处理，不能与 Int64 比较。
    let slashOpt = s.lastIndexOf("/")
    if (slashOpt.isNone()) {
        throw Exception("DSN 缺少库名：期望 mysql://user:pass@host:port/db，实际 '${dsn}'")
    }
    let slash = slashOpt.getOrThrow()
    let authority = s[0..slash]
    let dbName = s[(slash + 1)..]
    if (dbName.size == 0) {
        throw Exception("DSN 库名为空：'${dsn}'")
    }
    let atOpt = authority.lastIndexOf("@")
    if (atOpt.isNone()) {
        throw Exception("DSN 缺少 '@'：期望 mysql://user:pass@host:port/db，实际 '${dsn}'")
    }
    let at = atOpt.getOrThrow()
    let userinfo = authority[0..at]
    let hostport = authority[(at + 1)..]

    var user = userinfo
    var pass = ""
    let colonOpt = userinfo.indexOf(":")
    if (colonOpt.isSome()) {
        let colon = colonOpt.getOrThrow()
        user = userinfo[0..colon]
        pass = userinfo[(colon + 1)..]
    }

    var host = hostport
    var port: Int64 = 3306
    let hcOpt = hostport.lastIndexOf(":")
    if (hcOpt.isSome()) {
        let hc = hcOpt.getOrThrow()
        host = hostport[0..hc]
        let ps = hostport[(hc + 1)..]
        if (ps.size > 0) {
            port = Int64.parse(ps)
        }
    }
    if (host.size == 0) {
        host = "127.0.0.1"
    }
    return MySqlConfig(host, port, user, pass, dbName)
}

/*
 * 建连 + 初始化会话。
 *
 * 返回可用的 DbBackend。调用方通常紧接着 ensureSchema(db) 建表。
 *
 * ⚠ 建库（CREATE DATABASE）不在这里做：MySqlBackend 的 URL 里带 database，
 *   库不存在时**建连就会失败**。基线专门写了 ensureDatabase() 绕开（mysql_store.cj:248）。
 *   本项目 P0 阶段要求库**预先建好**（并把它写进 README），
 *   因为建库需要比业务账号更高的权限，不该由服务进程持有。
 */
public func openDatabase(cfg: MySqlConfig): DbBackend {
    var backend: DbBackend
    try {
        // noBackslashEscapes: false —— 沿用基线口径（mysql_store.cj:158）
        backend = MySqlBackend(cfg.host, cfg.port, cfg.user, cfg.pass, cfg.db,
                               noBackslashEscapes: false)
    } catch (e: Exception) {
        throw Exception("连接 MySQL 失败（${cfg.describe()}）：${e.message}\n" +
            "  处置：① 确认服务器在跑（本项目本机联调用便携版 MariaDB 的 3307）；" +
            "② 确认账号口令与库已建好；" +
            "③ 若报「未注册 mysql/mariadb 驱动」，说明驱动没被注册进链接产物 —— " +
            "先跑 build-mysql-driver.ps1 再 build.ps1，并确认 db_bootstrap.cj 里 import 了 mariadb.cdbc.*")
    }
    // 坑 1：必须显式设字符集，否则一个 emoji 会让之后所有写入持续失败
    try {
        backend.exec("SET NAMES utf8mb4", Array<DbValue>())
    } catch (e: Exception) {
        throw Exception("设置会话字符集失败（SET NAMES utf8mb4）：${e.message}\n" +
            "  **不静默继续** —— 连接字符集是 utf8mb3 时，一个 4 字节字符（emoji）" +
            "就会让之后每一次写入持续 500。详见 baseline/docs/API-NOTES.md 坑 44。")
    }
    return backend
}
