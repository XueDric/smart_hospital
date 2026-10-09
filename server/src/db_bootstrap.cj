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
    /*
     * ⚠ 默认端口 = **3306**（MySQL 出厂默认），不是本项目的 3317 —— 这是刻意的。
     *
     * 原值是 **3307**，那是**社团那台**便携 MariaDB 的端口；本项目自管 devdb
     * 后来迁到 **3317**，而这个默认值一直没跟着改。它造成的实际危害是：
     *   ① 它是个**假默认** —— 本项目**没有任何实例**跑在 3307 上，
     *      所以"什么都不传就用了默认值"这条路径必然失败；
     *   ② 更坏的是它**看起来像对的**（一个具体的、像是配置过的数字），
     *      于是"DSN 没传进来"和"端口写错了"这两种故障会长得一模一样。
     * 📌 所以默认值取**协议标准口**：它不假装知道本项目的部署，
     *   而任何"没拿到 DSN"的情况都会以一个**明显不对**的端口暴露出来。
     *   （DSN 缺端口时的行为：`parseDsn` 会保留这个默认值 ⇒ 连不上 ⇒ 报错里
     *     回显实际用的 host:port，使用者一眼能看到是 3306 而不是自己的端口。）
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
    return parseDsnEx(dsn, allowEmptyDb: false)
}

/*
 * 同 `parseDsn`，但可选择**允许空库名**。
 *
 * ⚠ 这是为 `create-db --admin-dsn` 加的（实测踩到）：
 *   管理员 DSN 的用途是 `GRANT ... ON <目标库>.*`，**它自己不需要库名** ——
 *   而 `GRANT` 可以在目标库还不存在时就执行（MySQL 允许对不存在的库授权）。
 *   所以使用者自然会写 `mysql://root:pw@127.0.0.1:3317/`，
 *   原来的严格校验会直接把它拒掉（"DSN 库名为空"），
 *   ⇒ 逼使用者去填一个**语义上无意义**的库名。
 *
 * ⚠ 为什么做成参数而不是复制一份解析器：解析逻辑（含多字节主机名/口令的
 *   字节级处理）**只该有一份** —— 复制出来的那份迟早与这份不一致。
 *   （这是本项目"同一语义只留一处实现"的又一次应用。）
 */
public func parseDsnEx(dsn: String, allowEmptyDb!: Bool): MySqlConfig {
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

/*
 * 库名白名单校验（标识符）。
 *
 * 库名是**唯一**会进 SQL 文本（DDL/DML 都拼不了参数的地方）的外部输入，
 * 所以必须先过白名单再拼。照基线 mysql_store.cj 的 dbNameChecked 口径：
 *   只允许 [A-Za-z0-9_]，且首字符不能是数字，长度 1~64。
 */
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

/*
 * 幂等建库：`CREATE DATABASE IF NOT EXISTS <db> CHARACTER SET utf8mb4`。
 *
 * ── 为什么需要它（照基线 mysql_store.cj:248 的同一考量）──────────────────
 * `MySqlBackend` 的 URL 里带 database，**库不存在时建连就会失败**。
 * 于是"先手工建库"成了部署门槛。但很多账号（例如本项目的 `hospital`）
 * **没有全局权限**，即使先建库也未必能建 —— 所以这个入口只在有权限时有用，
 * 没权限时必须在报错里说清"要去手工建库"，而不是让人以为代码坏了。
 *
 * 做法：先用**空库名**连一次（驱动允许 database 为空），建库、断开。
 */
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
        /*
         * ⚠ 这里**不能**只说"建库失败"。最常见的原因恰恰不是"没权限"，
         *   而是**端口/主机不对**或**DSN 是空的**（PowerShell 引用未定义变量 = 空串，
         *   会静默退回默认值）。基线专门为此写过一版把原因按可能性排序的报错，
         *   这里沿用同一口径 —— 错误信息本身就是排障文档。
         *
         * ⚠⚠ **这条提示里绝不再写死端口号**（2026-10-07 修，第九份复查发现）。
         *   原文是「本机联调的便携版 MariaDB 是 127.0.0.1:**3307**」——
         *   而本项目自管 devdb 早已迁到 **3317**（3307 是**社团那台**，
         *   本项目不再依赖它，见 `docs/DEV-DB.md`）。
         *   后果很实在：**复查的人、以及我自己在本项目里，都被它误导过** ——
         *   devdb 没起来时，提示让人去查 3307，而正确处置是启动 3317 的 devdb。
         *   📌 根因是"**同一件事两处口径**"：端口的事实来源是 `cfg`（DSN 里那个），
         *     提示里却又手写了一份 ⇒ 迟早漂移。而且**偏偏这是最需要准确的地方**
         *     （出错时的提示）。⇒ 改成**从 `cfg` 派生**：先回显实际用的 host:port，
         *     再让使用者拿它去 `docs/DEV-DB.md` 核对 —— **本提示不复制那个数字**，
         *     从机制上消灭漂移。
         */
        throw Exception("连不上 MySQL（${cfg.describe()}）：${e.message}\n" +
            "  处置（按可能性排序）：\n" +
            "   ① **端口/主机不对**：把你启动实例的端口与上面回显的 ${cfg.host}:${cfg.port} 核对\n" +
            "      ⚠ 本项目自管 devdb 的端口**以 docs/DEV-DB.md 为准**（本提示刻意不写死它，" +
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

/*
 * 让"刚建好的库"对**当前账号**真的可用（返回 0 = 可用，非 0 = 不可用且已给出处置）。
 *
 * ════ 为什么必须有这一步（第八份复查的真问题，我已复现）════════════════════
 *
 *   `hospital` 账号的实际授权（我实查确认）：
 *       GRANT CREATE ON *.*                              ← 只要"能建库"
 *       GRANT ALL PRIVILEGES ON `hospital`.*             ← 权限**按库逐个授**
 *       GRANT ALL PRIVILEGES ON `hospital_test`.*
 *   ⇒ 它能 `CREATE DATABASE iso_test2` 成功，但**对新库没有权限**。
 *
 *   于是 `create-db` 打印「✅ 库已就绪」，紧接着 `check-db` 在 `migrateSchema`
 *   的 ALTER 上被拒：
 *       ALTER command denied to user 'hospital'@'localhost' for table `iso_test2`.`appointment`
 *
 *   ⚠ 危害是**语义上的**：`create-db` 说"就绪"，而它建出来的库**不可用**；
 *     失败被推迟到下一个命令，且（修 check-db 之前）以**未捕获异常 + 堆栈**出现。
 *     报错的地方不是出错的地方 —— 比"建库失败"更难查。
 *
 * ════ 授权时**绝不硬编码 host**（这是我修的过程里又踩到的一处）══════════════
 *   我第一版写的是 `TO 'user'@'localhost'` —— 而 host 部分**不是**由 DSN 决定的：
 *   同一个 DSN 连上去，MySQL 可能把你认成 `user@localhost`（socket/named pipe）
 *   或 `user@127.0.0.1`（TCP）。写死 `localhost` 时，对后一种就是
 *   **授给了一个不存在的账户**（GRANT 甚至会报成功，因为 MySQL 默认会创建账户）。
 *   ⇒ 所以这里一律用**数据库自己报告的 `CURRENT_USER()`**（形如 `user@host`）
 *     来拼授权语句。这样"授给谁"与"我是谁"**必然一致**。
 *
 * ════ 为什么只能"尽力而为"，不能保证成功 ══════════════════════════════════
 *   为自己授权需要 `GRANT OPTION`（或 root）。本项目的业务账号**没有**它 ——
 *   这是**正确**的（服务进程不该长期持有授权能力）。
 *   ⇒ 所以分两种情况，**都不会静默**：
 *     · 能授 ⇒ 授完**复探一次**（不靠"GRANT 没抛就一定成了"）；
 *     · 不能授 ⇒ **明确说"库已建好但这个账号用不了"** + 给可复制的管理员命令 + 返回失败。
 *   关键是**不许把"不可用"报成"就绪"**，也不许把"可用"误报成"不可用"。
 */
public func ensureDatabaseUsable(cfg: MySqlConfig): Int64 {
    let name = dbNameChecked(cfg.db)
    var db: DbBackend
    try {
        db = openDatabase(cfg)
    } catch (e: Exception) {
        println("❌ 建库后连不上 ${cfg.describe()}：${e.message}")
        return 1
    }
    /* ★ 用库自己报告的账户（user@host），不要用 DSN 里的用户名去猜 host */
    let account = currentAccountOf(db, cfg)
    var usable = canAlterExistingTable(db)
    if (usable) {
        db.close()
        return 0
    }
    /*
     * 走到这里 = 库存在但当前账号做不了 `migrateSchema` 需要的那类 DDL。
     * 尝试**自我授权**（需要 GRANT OPTION；业务账号通常没有，失败是意料之中）。
     */
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
        /* 授完**再探一次** —— 权限可能要重连才完全生效，不能只看 GRANT 没抛 */
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

/*
 * 取当前连接的**实际账户**，形如 `'user'@'host'`（已加好引号，可直接拼进 GRANT）。
 *
 * 用 `CURRENT_USER()` 而不是 DSN：DSN 给的是**登录名**，而 MySQL 匹配到的是
 * **账户**（含 host）。两者可能不同 —— 例如 `-h 127.0.0.1` 连上去可能被认成
 * `user@localhost`。硬编码 host 就会授错账户。
 */
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
        /* 读不到就退回 DSN 的登录名 + 本机常见 host —— 但**说明这是退路** */
    }
    return "'" + cfg.user + "'@'localhost'"
}

/*
 * 账户串（`'user'@'host'`）是否"安全到可以拼进 SQL"。
 *
 * ⚠ 与库名不同，账户名可以含 `.` `_` `-` `%`（`%` 是 host 通配符，很常见），
 *   所以不能用 `dbNameChecked` 那种严格白名单。但它是拼进 GRANT 文本的外部输入，
 *   仍要挡掉引号/空格/分号/反斜杠这类**能改变语句结构**的字符。
 *   挡不住时**不拼**（走"给出手工命令"那条路），而不是硬拼。
 *
 * 允许的完整形态：`'name'@'host'` —— 恰好两个单引号段。
 */
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
    /* 必须恰好 4 个单引号（'u'@'h'），否则形态不对 */
    var quotes = 0
    for (ch in account.toArray()) {
        if (Int64(ch) == 0x27) {
            quotes = quotes + 1
        }
    }
    return quotes == 4
}

/*
 * 用管理员 DSN 一步到位：建库 + 授权 + 探通。
 *
 * ⚠ 这是**推荐路径** —— "业务账号无法自我授权"是**正确**的安全设计，
 *   不是要被绕过的障碍。与其让使用者手工跑 GRANT，不如让他显式提供一个
 *   有权限的 DSN（一次性的，不会被服务进程长期持有）。
 *
 * ⚠ 授权对象用**目标账号自己报告的 `CURRENT_USER()`**（先用目标 DSN 连一次读出来），
 *   而不是拿 DSN 的用户名去猜 host —— 见 `currentAccountOf` 的注释。
 */
public func ensureDatabaseUsableWithAdmin(target: MySqlConfig, adminDsn: String): Int64 {
    let name = dbNameChecked(target.db)
    var admin: MySqlConfig
    try {
        /* 管理员 DSN 允许不带库名（它只需能执行 GRANT；目标库可以还不存在） */
        admin = parseDsnEx(adminDsn, allowEmptyDb: true)
    } catch (e: Exception) {
        println("❌ --admin-dsn 解析失败：${e.message}")
        return 1
    }
    /* ① 先问目标账号"你是谁"（要和 DSN 连的是同一个库） */
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
    /* ② 用管理员连接授权 */
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
    /* ③ 授完必须**用目标账号真探一次**，不能只看 GRANT 没报错 */
    return ensureDatabaseUsable(target)
}


/*
 * 探测"当前账号能否做 `migrateSchema` 需要的那类 DDL" —— **零副作用**。
 *
 * ════ 我在这里错了两次，两次都记下来（都是"探错了能力"）══════════════════
 *
 *   ❌ 第一版：探 `CREATE TABLE`。
 *      错因：`CREATE ON *.*` 是**全局**的 ⇒ 在新库上 `CREATE TABLE` **永远允许**
 *      （实测：新库上 CREATE 允许，而 ALTER / DROP / SELECT 全被拒）
 *      ⇒ **必然误报"可用"**，而且还会**留下垃圾表**。
 *
 *   ❌ 第二版：探"对**已存在**的应用表做 `ALTER TABLE ... ENGINE=InnoDB`"。
 *      错因：**真·全新库**里一张应用表都没有 ⇒ 走"保守判不可用"的兜底
 *      ⇒ 即使管理员**已经授好权**了，也报"用不了它"（我实测到：
 *      `GRANT` 明明成功，命令却打印"❌ 库已建好但用不了"）。
 *
 *   ✅ 现在：`CREATE TEMPORARY TABLE` —— 它要求 **CREATE** 权限，
 *      而临时表**随连接消失**，所以**没有任何残留**。
 *      ⚠ 但 `CREATE ON *.*` 也会放行它 ⇒ **单独用它不够**（与第一版同一个洞）。
 *      所以**两个一起用，取"都必须通过"**：
 *        · 临时表成功 ⇒ 有 CREATE
 *        · 再对应用表（若存在）ALTER 成功 ⇒ 有 ALTER
 *      只要**任一**不通过就判不可用 ⇒ 不会再出现"授了权仍报不可用"的假阴性，
 *      也不会再出现"CREATE 放行就报可用"的假阳性。
 */
public func canAlterExistingTable(db: DbBackend): Bool {
    /*
     * 第一关：能建临时表吗（CREATE 权限的**无残留**探测）。
     * ⚠ 临时表名必须与真实表区分；且因为它是 TEMPORARY，绝不进磁盘。
     */
    var canCreate = false
    try {
        db.exec("CREATE TEMPORARY TABLE zz_ddl_probe (x INT)", Array<DbValue>())
        canCreate = true
    } catch (e: Exception) {
        canCreate = false
    }
    if (!canCreate) {
        /* 建都建不了 ⇒ 谈不上迁移 */
        return false
    }
    /*
     * 第二关：能改**真实表**吗。
     * `migrateSchema` 干的就是这件事，所以这一关才是真判据。
     * 应用表都还不存在（真·全新库）时**无法探** ⇒ 此时**以第一关为准**
     * （回到"能不能 DDL"的语义，而不是保守报不可用 —— 那会造成假阴性）。
     */
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
            /*
             * ⚠ 用 `ALTER TABLE ... ENGINE=InnoDB`：在 InnoDB 表上是**幂等改写**
             *   （不改列、不动行）—— 既触发权限检查，又不留痕。
             */
            try {
                db.exec("ALTER TABLE " + t + " ENGINE=InnoDB", Array<DbValue>())
                return true
            } catch (e: Exception) {
                /* 表在但改不动 ⇒ 正是"没授权"的形态 */
                return false
            }
        }
    }
    /* 一张应用表都没有 ⇒ 这是个全新库，第一关（能建临时表）已是能拿到的最强信号 */
    return true
}

/*
 * 建连 + 初始化会话。
 *
 * 返回可用的 DbBackend。调用方通常紧接着 ensureSchema(db) 建表。
 *
 * ⚠ 建库（CREATE DATABASE）不在这里做：MySqlBackend 的 URL 里带 database，
 *   库不存在时**建连就会失败**。要建库请用 `ensureDatabase()`（上面）——
 *   它先用空库名连、建库、断开。建库通常需要比业务账号更高的权限，
 *   所以**不该由服务进程在每次启动时持有**，故与建连分开。
 */
public func openDatabase(cfg: MySqlConfig): DbBackend {
    var backend: DbBackend
    try {
        // noBackslashEscapes: false —— 沿用基线口径（mysql_store.cj:158）
        backend = MySqlBackend(cfg.host, cfg.port, cfg.user, cfg.pass, cfg.db,
                               noBackslashEscapes: false)
    } catch (e: Exception) {
        throw Exception("连接 MySQL 失败（${cfg.describe()}）：${e.message}\n" +
            "  处置：① 确认服务器在跑、且端口与上面回显的 ${cfg.host}:${cfg.port} 一致" +
            "（本项目自管 devdb 的端口以 docs/DEV-DB.md 为准 —— 本提示刻意不写死它，" +
            "免得两处漂移）；" +
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
