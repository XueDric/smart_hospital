/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 *
 * ===== db_bootstrap.cj —— MySQL 建连与初始化 =====
 *
 * 负责建连、建库、授权探测与会话初始化。三条硬约束：
 *  · 连接后必须 SET NAMES utf8mb4，失败直接抛：字符集是 utf8mb3 时一个 emoji
 *    会让之后所有写入持续失败，且轻舟框架没有字符集参数；
 *  · 驱动必须在某个被编译的文件里 import 过才会在运行时注册，仅链接 mariadb.cdbc 不够；
 *  · 反斜杠转义只选一种：沿用 noBackslashEscapes=false，参数一律走 DbValue 绑定。
 */

package qingzhou

// Int64.parse 需要 std.convert，仓颉不自动导入
import std.convert.*

// 驱动必须被 import 过才会注册（db_mysql.cj 运行时按注册名查找）
import mariadb.cdbc.*

/* MySQL 连接配置。口令只进连接，绝不进 describe() 输出。 */
public class MySqlConfig {
    public var host: String = "127.0.0.1"
    /*
     * 默认端口取 3306（MySQL 标准口），不是本项目 devdb 的 3317。
     * 缺 DSN 时端口会明显不对，避免"假默认"把"没传 DSN"伪装成"端口写错"。
     */
    public var port: Int64 = 3306
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

    /* 日志/报错用描述；绝不回显口令。 */
    public func describe(): String {
        return "${user}@${host}:${port}/${db}"
    }
}

/* 解析 DSN：mysql://user:pass@host:port/db。
 * 切分与框架 db_factory.cj:85-92 一致：userinfo 按最后一个 @、user/pass 按第一个 :。
 * 失败抛异常并给出期望格式，便于排障。 */
public func parseDsn(dsn: String): MySqlConfig {
    return parseDsnEx(dsn, allowEmptyDb: false)
}

/* 同 parseDsn，但 allowEmptyDb=true 时允许库名为空（--admin-dsn 用）。
 * GRANT 可在目标库不存在时执行，管理员 DSN 不需要库名。
 * 解析逻辑只保留这一份，避免两套口径漂移。 */
public func parseDsnEx(dsn: String, allowEmptyDb!: Bool): MySqlConfig {
    var s = dsn
    if (s.startsWith("mysql://")) {
        s = s[8..]
    }
    // 仓颉 indexOf/lastIndexOf 返回 ?Int64，用 isNone()/getOrThrow() 处理
    let slashOpt = s.lastIndexOf("/")
    if (slashOpt.isNone()) {
        throw Exception("DSN 缺少库名：期望 mysql://user:pass@host:port/db，实际 '${dsn}'")
    }
    let slash = slashOpt.getOrThrow()
    let authority = s[0..slash]
    let dbName = s[(slash + 1)..]
    if (dbName.size == 0 && !allowEmptyDb) {
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

/* 库名校验：库名是唯一会拼进 SQL 文本的外部输入，必须先过白名单。
 * 只允许 [A-Za-z0-9_]，首字符不能是数字，长度 1~64。 */
public func dbNameChecked(name: String): String {
    if (name.size == 0 || name.size > 64) {
        throw Exception("库名长度非法（1~64）：'${name}'")
    }
    var i = 0
    for (ch in name.toArray()) {
        let c = Int64(ch)
        let isDigit = (c >= 0x30 && c <= 0x39)
        let isUpper = (c >= 0x41 && c <= 0x5A)
        let isLower = (c >= 0x61 && c <= 0x7A)
        let isUnder = (c == 0x5F)
        if (!(isDigit || isUpper || isLower || isUnder)) {
            throw Exception("库名含非法字符（只允许字母/数字/下划线）：'${name}'")
        }
        if (i == 0 && isDigit) {
            throw Exception("库名不能以数字开头：'${name}'")
        }
        i = i + 1
    }
    return name
}

/* 幂等建库：CREATE DATABASE IF NOT EXISTS <db> CHARACTER SET utf8mb4。
 * 先用空库名连一次再建；失败必须说清"无权限需手工建库"，不静默。 */
public func ensureDatabase(cfg: MySqlConfig): Unit {
    let name = dbNameChecked(cfg.db)
    let boot = MySqlConfig()
    boot.host = cfg.host
    boot.port = cfg.port
    boot.user = cfg.user
    boot.pass = cfg.pass
    boot.db = ""
    var probe: ?DbBackend = None
    try {
        probe = Some(openDatabase(boot))
    } catch (e: Exception) {
        /* 连不上不等于没权限：最常见是端口/主机不对或 DSN 为空。
         * 提示必须回显 cfg 里实际的 host:port，绝不写死项目端口，否则两处口径漂移。 */
        throw Exception("连不上 MySQL（${cfg.describe()}）：${e.message}\n" +
            "  处置（按可能性排序）：\n" +
            "   ① **端口/主机不对**：把你启动实例的端口与上面回显的 ${cfg.host}:${cfg.port} 核对\n" +
            "      ⚠ 本项目自管 devdb 的端口**以 docs/dev/DEV-DB.md 为准**（本提示刻意不写死它，" +
            "免得两处漂移）；MySQL 出厂默认是 3306\n" +
            "   ② **这条命令压根没拿到 DSN**：PowerShell 里引用未定义的变量不报错、只是空串\n" +
            "   ③ 账号/口令不对\n" +
            "   ④ 账号**不允许不带库名连接**（没有全局权限）—— 只有这一种才需要手工建库：\n" +
            "      CREATE DATABASE " + name + " CHARACTER SET utf8mb4;")
    }
    let p = probe.getOrThrow()
    try {
        p.exec("CREATE DATABASE IF NOT EXISTS " + name + " CHARACTER SET utf8mb4",
               Array<DbValue>())
    } finally {
        p.close()
    }
}

/* 让刚建好的库对当前账号真正可用。
 * 返回 0 可用，1 连不上，2 库在但权限不足且已给处置。
 * 授权对象必须取数据库报告的 CURRENT_USER()，不能拿 DSN 用户名猜 host。 */
public func ensureDatabaseUsable(cfg: MySqlConfig): Int64 {
    let name = dbNameChecked(cfg.db)
    var db: DbBackend
    try {
        db = openDatabase(cfg)
    } catch (e: Exception) {
        println("❌ 建库后连不上 ${cfg.describe()}：${e.message}")
        return 1
    }
    let account = currentAccountOf(db, cfg)
    var usable = canAlterExistingTable(db)
    if (usable) {
        db.close()
        return 0
    }
    /* 库存在但账号 DDL 权限不足：尝试自行授权，通常没有 GRANT OPTION。 */
    var granted = false
    var grantErr = ""
    if (sqlAccountOk(account)) {
        try {
            db.exec("GRANT ALL PRIVILEGES ON `" + name + "`.* TO " + account, Array<DbValue>())
            granted = true
        } catch (e: Exception) {
            grantErr = e.message
        }
    } else {
        grantErr = "账户名含预期外字符，为安全起见不拼接授权语句：" + account
    }
    if (granted) {
        /* 授完必须复探一次，不能只看 GRANT 没抛异常。 */
        let nowOk = canAlterExistingTable(db)
        db.close()
        if (nowOk) {
            println("✅ 已授予并把库调通：GRANT ALL PRIVILEGES ON `" + name + "`.* TO " + account)
            return 0
        }
        println("⚠ GRANT 执行成功，但复探仍不可用（可能需要重连或 FLUSH PRIVILEGES）")
        return 2
    }
    db.close()
    println("❌ 库 `" + name + "` **已建好，但账号 " + account + " 用不了它**。")
    println("   原因：该账号对本库没有权限（`migrateSchema` 需要 ALTER），且**无权自我授权**。")
    if (grantErr.size > 0) {
        println("   自助授权尝试被拒：" + grantErr)
    }
    println("")
    println("   处置（**二选一**）：")
    println("    ① 用管理员账号执行下面两条，然后重跑本命令：")
    println("         GRANT ALL PRIVILEGES ON `" + name + "`.* TO " + account + ";")
    println("         FLUSH PRIVILEGES;")
    println("    ② 或者直接给本命令一个管理员 DSN，它会**一步授好**（推荐）：")
    println("         hospital-server create-db " + cfg.describe() + " --admin-dsn <管理员 DSN>")
    println("")
    println("   ⚠ 不要以为「换个命令就好了」—— 这一步不做，`check-db` / `accept` / `serve`")
    println("     都会在 `migrateSchema` 的 ALTER 上被拒。")
    return 2
}

/* 取当前连接的实际账户，形如 'user'@'host'，已加引号可直接拼进 GRANT。
 * 必须用 CURRENT_USER()：DSN 的登录名可能被 MySQL 映射成含 host 的账户。 */
public func currentAccountOf(db: DbBackend, cfg: MySqlConfig): String {
    try {
        let rs = db.query("SELECT CURRENT_USER()", Array<DbValue>())
        if (rs.rowCount() > 0) {
            let cu = rs.getString(0, 0).trimAscii()
            let at = cu.lastIndexOf("@")
            if (at.isSome()) {
                let i = at.getOrThrow()
                let u = cu[0..i]
                let h = cu[(i + 1)..]
                if (u.size > 0 && h.size > 0) {
                    return "'" + u + "'@'" + h + "'"
                }
            }
        }
    } catch (e: Exception) {
        /* 读不到时退回 DSN 登录名 + localhost，这是退路。 */
    }
    return "'" + cfg.user + "'@'localhost'"
}

/* 账户串 'user'@'host' 是否可安全拼进 SQL；恰好 4 个单引号才算形态正确。
 * 只放行字母/数字/._-$%，能改变语句结构的字符一律拒绝，挡不住时不拼。 */
public func sqlAccountOk(account: String): Bool {
    if (account.size == 0 || account.size > 200) {
        return false
    }
    for (ch in account.toArray()) {
        let c = Int64(ch)
        let isDigit = (c >= 0x30 && c <= 0x39)
        let isUpper = (c >= 0x41 && c <= 0x5A)
        let isLower = (c >= 0x61 && c <= 0x7A)
        let isUnder = (c == 0x5F)
        let isDot = (c == 0x2E)
        let isDash = (c == 0x2D)
        let isDollar = (c == 0x24)
        let isPercent = (c == 0x25)
        let isQuote = (c == 0x27)
        let isAt = (c == 0x40)
        if (!(isDigit || isUpper || isLower || isUnder || isDot || isDash || isDollar ||
              isPercent || isQuote || isAt)) {
            return false
        }
    }
    /* 必须恰好 4 个单引号（'u'@'h'），否则形态不对。 */
    var quotes = 0
    for (ch in account.toArray()) {
        if (Int64(ch) == 0x27) {
            quotes = quotes + 1
        }
    }
    return quotes == 4
}

/* 用管理员 DSN 完成授权并探通，是推荐路径。
 * 授权对象取目标账号的 CURRENT_USER()；授完必须用目标账号复探。 */
public func ensureDatabaseUsableWithAdmin(target: MySqlConfig, adminDsn: String): Int64 {
    let name = dbNameChecked(target.db)
    var admin: MySqlConfig
    try {
        /* 管理员 DSN 允许不带库名：GRANT 可在目标库不存在时执行。 */
        admin = parseDsnEx(adminDsn, allowEmptyDb: true)
    } catch (e: Exception) {
        println("❌ --admin-dsn 解析失败：${e.message}")
        return 1
    }
    /* ① 先问目标账号"你是谁"，要和 DSN 连的是同一个库。 */
    var targetAccount = ""
    try {
        let tdb = openDatabase(target)
        targetAccount = currentAccountOf(tdb, target)
        tdb.close()
    } catch (e: Exception) {
        println("❌ 连不上目标库（无法确认要授权给哪个账户）：${e.message}")
        return 1
    }
    if (!sqlAccountOk(targetAccount)) {
        println("❌ 目标账户名含预期外字符，拒绝拼接授权语句：" + targetAccount)
        return 2
    }
    /* ② 用管理员连接授权。 */
    var adb: DbBackend
    try {
        adb = openDatabase(admin)
    } catch (e: Exception) {
        println("❌ 管理员 DSN 连不上：${e.message}")
        println("   处置：确认 --admin-dsn 的账号/口令/端口正确（它需要 GRANT OPTION 或 root）。")
        return 1
    }
    println("授权：GRANT ALL PRIVILEGES ON `" + name + "`.* TO " + targetAccount)
    try {
        adb.exec("GRANT ALL PRIVILEGES ON `" + name + "`.* TO " + targetAccount, Array<DbValue>())
        adb.exec("FLUSH PRIVILEGES", Array<DbValue>())
    } catch (e: Exception) {
        println("❌ 授权失败：${e.message}")
        println("   处置：该管理员账号需要 GRANT OPTION（或 root），且要能连到同一台 MySQL。")
        adb.close()
        return 2
    }
    adb.close()
    /* ③ 授完必须用目标账号真探一次，不能只看 GRANT 没报错。 */
    return ensureDatabaseUsable(target)
}


/* 探测当前账号能否做 migrateSchema 所需的 DDL，零副作用。
 * 先建临时表拿 CREATE，再对已存在的应用表 ALTER ENGINE=InnoDB 拿 ALTER。
 * 两者必须都通过；全新库无表可探时以临时表为准，否则会假阴性。 */
public func canAlterExistingTable(db: DbBackend): Bool {
    /* 一关：建临时表，测 CREATE 权限且不留残留。 */
    var canCreate = false
    try {
        db.exec("CREATE TEMPORARY TABLE zz_ddl_probe (x INT)", Array<DbValue>())
        canCreate = true
    } catch (e: Exception) {
        canCreate = false
    }
    if (!canCreate) {
        /* 建不了临时表 ⇒ 谈不上迁移。 */
        return false
    }
    /* 二关：改真实应用表，migrateSchema 干的就是这件事，这一关才是真判据。
     * 全新库无应用表时无法探，以第一关为准，避免假阴性。 */
    let probeTables: Array<String> = [TABLE_SCHEDULE, TABLE_PREVISIT, TABLE_AI_SETTING]
    for (t in probeTables) {
        var exists = false
        try {
            let rs = db.query("SELECT COUNT(*) FROM information_schema.TABLES " +
                              "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?", [DbStr(t)])
            exists = rs.rowCount() > 0 && rs.getInt(0, 0) > 0
        } catch (e: Exception) {
            exists = false
        }
        if (exists) {
            /* ALTER ... ENGINE=InnoDB 是幂等改写：触发权限检查又不改数据。 */
            try {
                db.exec("ALTER TABLE " + t + " ENGINE=InnoDB", Array<DbValue>())
                return true
            } catch (e: Exception) {
                /* 表在但改不动 ⇒ 正是"没授权"的形态。 */
                return false
            }
        }
    }
    /* 一张应用表都没有 ⇒ 全新库，第一关已是能拿到的最强信号。 */
    return true
}

/* 建连并初始化会话，返回可用 DbBackend；调用方通常紧接着建表。
 * 建库不在这里：库不存在时建连会失败，且建库权限不该由服务进程长期持有。
 * 失败抛异常，并给出端口/口令/驱动注册三类处置。 */
public func openDatabase(cfg: MySqlConfig): DbBackend {
    var backend: DbBackend
    try {
        // noBackslashEscapes=false：反斜杠转义只选一种，参数一律走 DbValue 绑定
        backend = MySqlBackend(cfg.host, cfg.port, cfg.user, cfg.pass, cfg.db,
                               noBackslashEscapes: false)
    } catch (e: Exception) {
        throw Exception("连接 MySQL 失败（${cfg.describe()}）：${e.message}\n" +
            "  处置：① 确认服务器在跑、且端口与上面回显的 ${cfg.host}:${cfg.port} 一致" +
            "（本项目自管 devdb 的端口以 docs/dev/DEV-DB.md 为准 —— 本提示刻意不写死它，" +
            "免得两处漂移）；" +
            "② 确认账号口令与库已建好；" +
            "③ 若报「未注册 mysql/mariadb 驱动」，说明驱动没被注册进链接产物 —— " +
            "先跑 build-mysql-driver.ps1 再 build.ps1，并确认 db_bootstrap.cj 里 import 了 mariadb.cdbc.*")
    }
    // 必须显式设字符集：否则一个 emoji 会让之后所有写入持续失败
    try {
        backend.exec("SET NAMES utf8mb4", Array<DbValue>())
    } catch (e: Exception) {
        throw Exception("设置会话字符集失败（SET NAMES utf8mb4）：${e.message}\n" +
            "  **不静默继续** —— 连接字符集是 utf8mb3 时，一个 4 字节字符（emoji）" +
            "就会让之后每一次写入持续 500。详见 搬迁前的 API 踩坑记录 坑 44。")
    }
    return backend
}
