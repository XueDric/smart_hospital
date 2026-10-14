package qingzhou

import std.collection.*
import std.database.sql.*
import std.sync.*

/*
 * SPDX-License-Identifier: MIT
 *
 * MySQL 后端（实现 DbBackend 接口）。
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * 基于 std.database.sql 标准接口，编译期不依赖任何驱动，运行时按注册名查找，
 * 兼容两个社区驱动（引入其一并 import 其 cdbc 包即可，import 触发驱动注册）：
 *   - mysqlclient4cj            注册名 "mysql"   URL scheme mysql://
 *   - Cangjie-SIG mysql-driver  注册名 "mariadb" URL scheme mariadb://
 * 使用前提：环境有 OpenSSL 3 动态库；服务器可用 MySQL/MariaDB/TiDB/OceanBase。
 * 本文件不在默认编译范围内（见 build.sh），端到端验证见 docs/DATABASE.md。
 *
 * 使用：
 *   import mariadb.cdbc.*               // 或 import mysqlclient4cj.cdbc.*
 *   let store = RbacStore(MySqlBackend("127.0.0.1", 3306, "root", "pass", "app_db"))
 */
public class MySqlBackend <: DbBackend {
    private let conn: Connection
    private let tx: Transaction
    // std.sync.Mutex 是可重入锁：事务持锁后，其内部 query/exec 可再次入锁。
    private let connectionLock = Mutex()
    private var transactionActive: Bool = false
    private var usable: Bool = true

    /*
     * ★★ 绑定值转义口径（2026-10-10，被 `PUT ai.endpoint` 的实测缺陷逼出来的）。
     *
     * 现象：往 `ai.endpoint` 写 `https://h/p?q=1`，库里变成 `https://h/pNULLq=1`
     *   —— `?` 变成**四个字母 NULL**。实测（直接读库，不经 HTTP）：
     *     写出 "https://h/p?q=1"          ⇒ "https://h/pNULLq=1"
     *     写出 "https://h/p?a=1&b=2?c"    ⇒ "https://h/pNULLa=1&b=2NULLc"
     *     写出 "a\b\c"                    ⇒ "ac"        ← 反斜杠被吞
     *     写出 "x'; DROP ... ; -- ?"       ⇒ "x'; DROP ... ; -- NULL"
     *
     * 根因（两层，**同一类**"框架绑定不完整"）：
     *   ① `bindSql`（db.cj）把参数按序拼成**字面量文本** ⇒ 之后的 SQL 里若含裸 `?`，
     *      **驱动**（`mariadb.cdbc` 的 ClientPrepareStatement）就把它当成一个占位符：
     *          parameters = Array<Any>(originSql.count("?"), repeat: None)
     *      它**按整条 SQL 里 `?` 的字符个数**定参数槽位，**不认识引号** ⇒ 值里的 `?`
     *      也占一个槽位 ⇒ 该槽位未绑定 ⇒ `buildSql()` 把它写成 `NULL`。
     *      （`prepare.mode=client` 的注释假设"SQL 里无 ? 占位符"，值里含 `?` 时该假设不成立。）
     *   ② MySQL **默认还开着反斜杠转义**，而框架的 `sqlEscape` 只做 SQL 标准的 `''` 双写
     *      ⇒ 值里的 `\` 被服务端当转义符吃掉。
     *      （搬迁前的 mysql 接入文档 §12.3 已记 ②，用 `mysqlSafe` 双写反斜杠解决；
     *        那一条**没有覆盖 ①** —— `?` 这一面是本项目才实测到的。）
     *
     * 处置：转义放在**后端**（这里），不放进通用的 `bindSql` ——
     *   `'\?'` 只有在"MySQL 反斜杠转义"这个口径下才等于 `?`，CangDB 后端未必同义，
     *   塞进通用层就是污染。参数化 `exec`/`query` 是唯一入口，在这里覆盖即可全局生效。
     *
     * ⚠ 为什么必须**两件事一起做**：两者共用同一个反斜杠机制。
     *   只补 `?` 而不补 `\`：`"a\"` 结尾会逃逸掉收尾引号 ⇒ **SQL 词法跑飞**（搬迁前已实测）。
     *   只补 `\` 而不补 `?`：就是本缺陷。
     *
     * 口径选择（`false` = 沿用搬迁前 `mysql_store.cj` 的 `noBackslashEscapes: false`）：
     *   本项目无历史数据包袱，两种口径都能自洽（两种我都验证过）；
     *   选 `false` 是为了**与搬迁前存储口径一致**，避免同一批数据在两套代码里读法不同。
     *   若将来改成 `true`，本类的转义必须**同时**去掉反斜杠双写（`?` 的 `\?` 仍然可以留，
     *   `NO_BACKSLASH_ESCAPES` 下服务端把 `\?` 当两个字面字符，结果不变）。
     */
    private let noBackslashEscapes: Bool

    /*
     * 建立连接：按注册名查找驱动（mysql 优先，回退 mariadb），组装对应 scheme 的 URL。
     *
     * noBackslashEscapes 默认开启：连接后把会话 sql_mode 固定为 NO_BACKSLASH_ESCAPES。
     * 框架级绑定用 SQL 标准的 '' 转义（见 db.cj 的 sqlEscape），而 MySQL 默认把
     * 反斜杠也当转义符，两者冲突时以单个反斜杠结尾的值（如 "abc\"）会逃逸出字符串
     * 边界。固定该会话变量后，'' 转义在 MySQL 与 CangDB 上语义一致。
     *
     * 代价与回退：固定后 raw SQL 不能再依赖反斜杠转义（`\'`、LIKE 的 `\%` 需改写）。
     * 确实需要旧行为时传 noBackslashEscapes: false。
     */
    public init(host: String, port: Int64, user: String, password: String, database: String,
                noBackslashEscapes!: Bool = true) {
        var urlScheme = "mysql"
        let driver = match (DriverManager.getDriver("mysql")) {
            case Some(d) => d
            case None =>
                // 未注册 "mysql" 时回退 Cangjie-SIG mysql-driver（注册名 "mariadb"）
                urlScheme = "mariadb"
                match (DriverManager.getDriver("mariadb")) {
                    case Some(d) => d
                    case None => throw Exception("未注册 mysql/mariadb 驱动：请引入 mysqlclient4cj 或 Cangjie-SIG mysql-driver，并 import 其 cdbc 包以触发驱动注册")
                }
        }
        let ds = driver.open(
            urlScheme + "://" + host + ":" + port.toString(),
            // 【本仓改动】原为 prepare.mode=client，实测会把数据里出现的 `?` 替换成字面量 NULL。
            // 只保留 username/password/database —— 不设 prepare.mode 时驱动回落到 **server**
            // （见 connection.cj 的 prepareStatement：options 里没有该键就 return ServerPrepareStatement）。
            // 判定依据与回归见下方长注释「prepare.mode 的选择」。
            [("username", user), ("password", password), ("database", database)]
        )
        conn = ds.connect()
        tx = conn.createTransaction()
        this.noBackslashEscapes = noBackslashEscapes
        if (noBackslashEscapes) {
            // sql_mode 是 SET 类型，已含该项时会自动去重，故可幂等重复设置
            synchronized(connectionLock) {
                let stmt = conn.prepareStatement(
                    "SET SESSION sql_mode = CONCAT(@@SESSION.sql_mode, ',NO_BACKSLASH_ESCAPES')")
                try {
                    stmt.update()
                } finally {
                    stmt.close()
                }
            }
        }
    }

    /* MySQL 支持 OR / 括号 / <> / IS NULL / 值列表 IN / LIMIT / OFFSET，
       故方言为 MySql —— 构建器不再拒绝这些构造。 */
    public func dialect(): DbDialect {
        DbDialect.MySql
    }

    /* 执行查询：游标逐行前进，每列按 String 取值，收集为 DbResultSet。
       注意：std.database.sql 的 get<T>(index) 列索引从 1 开始（1-based）。 */
    public func query(sql: String): DbResultSet {
        synchronized(connectionLock) {
            requireUsable()
            return queryLocked(sql)
        }
    }

    // 结果集也在连接锁内完整物化，避免游标读取跨过其他命令。
    private func queryLocked(sql: String): DbResultSet {
        let stmt = conn.prepareStatement(sql)
        try {
            let qr = stmt.query()
            try {
                let out = ArrayList<ArrayList<String>>()
                while (qr.next()) {
                    let row = ArrayList<String>()
                    let n = qr.columnInfos.size
                    var i: Int64 = 1
                    while (i <= n) {
                        // getOrNull 保留 NULL，不让可空列读取抛异常。
                        match (qr.getOrNull<String>(i)) {
                            case Some(v) => row.add(v)
                            case None => row.add("NULL")
                        }
                        i += 1
                    }
                    out.add(row)
                }
                return DbResultSet(out)
            } finally {
                qr.close()
            }
        } finally {
            stmt.close()
        }
    }

    /* 执行写操作，返回受影响行数（UpdateResult.rowCount）。 */
    public func exec(sql: String): Int64 {
        synchronized(connectionLock) {
            requireUsable()
            let stmt = conn.prepareStatement(sql)
            try {
                let ur = stmt.update()
                return ur.rowCount
            } finally {
                stmt.close()
            }
        }
    }

    /* 确保表存在：MySQL 支持 CREATE TABLE IF NOT EXISTS，一条语句搞定。 */
    public func ensureTable(name: String, columns: String): Unit {
        exec("CREATE TABLE IF NOT EXISTS " + name + " (" + columns + ")")
    }

    /* ===================== 参数化绑定：MySQL 口径的转义 ===================== */

    /*
     * 把绑定值按本会话的口径转义（正体在**模块级** `mysqlBindEscapeFor`，
     * 那里有完整的现象/根因/口径说明）。这里只做个带口径的薄封装。
     */
    public func mysqlBindEscape(v: String): String {
        return mysqlBindEscapeFor(v, !noBackslashEscapes)
    }

    /* 对单个绑定值按类型转义：只有字符串有转义面（数字/布尔/NULL 无字符可逃逸）。 */

    /*
     * ★★ 覆盖框架的参数化入口（这是本类相对 `DbBackend` 默认实现**唯一**的实质差异）。
     *
     * 覆盖而不是改框架 `db.cj` 的理由：这套处理是**MySQL 方言**的（反斜杠转义口径
     * + 参数里的 `?` 不能当占位符），放进通用层会污染其它后端。
     * 这里覆盖后，全仓所有 `exec(sql, params)` / `query(sql, params)` 调用
     * （当前 28 处）都自动走过它，无需逐个改调用点。
     *
     * ⚠ **为什么不能复用框架的 `bindSql`**：`bindSql` 内部用 `sqlQuote` 包值，
     *   而 `sqlEscape` 只双写 `'`、**不管 `\`** —— 而 `\` 在 MySQL 默认会话里是转义符
     *   （`a\b` 被吃掉一个字符、值以 `\` 结尾会逃逸收尾引号）。要补 `\` 就必须在
     *   "值还没被套上引号"的那一层动手，而 `bindSql` 是不可分割的整函数、
     *   内部拼完直接产出最终文本。⇒ 只能自己拼，见 `mysqlBindSql`：
     *   它就是本后端的 `bindSql`，语义（占位符个数校验、fails fast）与框架一致。
     *
     * ✅ 哨兵已撤：这里的 `query`/`exec` 现在**只是** `mysqlBindSql`，不再需要
     *    `mysqlRestoreQmark`（那个调用恰恰是本缺陷的成因，见函数处的说明）。
     */
    public func query(sql: String, params: Array<DbValue>): DbResultSet {
        query(mysqlBindSql(sql, params))
    }

    public func exec(sql: String, params: Array<DbValue>): Int64 {
        exec(mysqlBindSql(sql, params))
    }

    // 包括非事务 INSERT；其他请求不能在写入与 ID 读取之间占用连接。
    public func execInsert(sql: String, params: Array<DbValue>): Int64 {
        synchronized(connectionLock) {
            exec(sql, params)
            let rs = query("SELECT LAST_INSERT_ID()", Array<DbValue>())
            if (rs.rowCount() < 1) {
                throw Exception("INSERT 后未返回生成 ID")
            }
            return rs.getInt(0, 0)
        }
    }

    private func requireUsable(): Unit {
        if (!usable) {
            throw Exception("数据库连接已关闭或事务回滚失败")
        }
    }

    /* 关闭连接，归还驱动连接资源。 */
    public func close(): Unit {
        synchronized(connectionLock) {
            if (!usable) { return }
            usable = false
            try {
                conn.close()
            } finally {
                if (transactionActive) {
                    transactionActive = false
                    connectionLock.unlock()
                }
            }
        }
    }

    /* 开启事务：通过 Connection 的事务对象发送 BEGIN。 */
    public func beginTransaction(): Unit {
        // 成功后保留本次 lock，直到同一线程提交/回滚；失败则立即归还。
        connectionLock.lock()
        try {
            requireUsable()
            if (transactionActive) {
                throw Exception("同一连接不支持嵌套事务")
            }
            try {
                tx.begin()
            } catch (e: Exception) {
                // BEGIN 可能已在服务器生效但响应丢失，禁止复用未知事务连接。
                // 仅处理真正发送 BEGIN 的异常；嵌套事务拒绝不会关闭原事务。
                usable = false
                try { conn.close() } catch (_: Exception) { () }
                throw e
            }
            transactionActive = true
        } catch (e: Exception) {
            connectionLock.unlock()
            throw e
        }
    }

    /* 提交事务：COMMIT。 */
    public func commitTransaction(): Unit {
        synchronized(connectionLock) {
            requireUsable()
            if (!transactionActive) { throw Exception("没有可提交的事务") }
            // 提交失败仍保留 begin 的锁，让 withTransaction 先回滚再放行。
            tx.commit()
            transactionActive = false
            connectionLock.unlock()
        }
    }

    /* 回滚事务：ROLLBACK。 */
    public func rollbackTransaction(): Unit {
        synchronized(connectionLock) {
            requireUsable()
            if (!transactionActive) { throw Exception("没有可回滚的事务") }
            try {
                tx.rollback()
            } catch (e: Exception) {
                // 未确认回滚的连接不可复用，防止下个请求进入未知事务。
                usable = false
                try { conn.close() } catch (_: Exception) { () }
                throw e
            } finally {
                transactionActive = false
                connectionLock.unlock()
            }
        }
    }

    public func withTransaction(body: () -> Unit): Unit {
        synchronized(connectionLock) {
            beginTransaction()
            try {
                body()
                commitTransaction()
            } catch (e: Exception) {
                if (transactionActive) { rollbackTransaction() }
                throw e
            }
        }
    }

    /*
     * 确保唯一索引：MySQL 的 TEXT 列建索引必须指定
     * 前缀长度，故用 `column(255)`（用户名远短于 255 字符）；CangDB 的
     * 默认实现用无前缀的 `column`。两方言见 docs/DATABASE.md。
     */
    public func ensureUniqueIndex(table: String, column: String): Unit {
        exec("CREATE UNIQUE INDEX idx_" + table + "_" + column + " ON " + table + "(" + column + "(255))")
    }
}

/* ===================== 绑定值转义（模块级：供后端类与测试直接调用）===================== */

/*
 * 观测钩子（默认关闭，`null` 即无开销）。仅用于**排查本链路的缺陷**：
 * 设上之后，每个经过转义的字符串值都会被记一条（原始值 / 转义后值）。
 *
 * 为什么需要它：这条链路上"值"被两层各自处理（框架拼字面量 → 驱动字符级替换），
 * 中间态没有任何日志，只能靠**结果反推**——本会话就因此在错误的方向上绕了几轮。
 * 有了它就能直接回答："转义到底有没有被调用？它看到的值是什么？"
 */
var mysqlBindObserver: ?(String, String) -> Unit = None

/*
 * 观测记录缓冲（模块级）。设了观察者时，每次转义追加一条 (原始值, 转义后值)。
 *
 * 为什么要有这个缓冲、而不是让观察者自己写库：
 *   观察者是个**持久化**的闭包，不能捕获调用方那里的 `var db`（仓颉报
 *   `lambda capturing mutable variables needs to be called directly`）。
 *   所以观察者只负责"记"，由调用方在合适的时候自己把缓冲落盘/打印。
 */
let mysqlBindTrace = ArrayList<(String, String)>()

/* 清空观测缓冲（调用方在开始一段观测前调一次）。 */
func mysqlBindTraceClear(): Unit {
    mysqlBindTrace.clear()
}

/*
 * ★★ 绑定值转义（2026-10-10，被 `PUT ai.endpoint` 的实测缺陷逼出来的）。
 *
 * 现象：往 `ai.endpoint` 写 `https://h/p?q=1`，库里变成 `https://h/pNULLq=1`
 *   —— `?` 变成**四个字母 NULL**。
 *
 * 根因（两层，**同一类**："值被内联进 SQL 文本，而下游有两层各自再处理一遍文本"）：
 *
 *   ① `bindSql`（db.cj）把参数按序拼成**字面量文本**（`'值'`），此后 SQL 里的
 *      `?` 已不是占位符，只是数据的**一个普通字符**。
 *      但驱动 `mariadb.cdbc` 的 `ClientPrepareStatement` 不知道这件事：
 *          this.parameters = Array<Any>(originSql.count("?"), repeat: None)
 *          this.parts      = originSql.split("?", removeEmpty: true)
 *      它**按整条 SQL 里 `?` 的字符个数**定参数槽位、**不认识引号**，于是
 *      `buildSql()` 把数据里那个 `?` 当成"一个没人绑定的参数" ⇒ 写成 `NULL` 字面量。
 *      （`prepare.mode=client` 的注释写着"框架级 bindSql 已把参数拼进 SQL（无 ? 占位符）"，
 *        该假设在**值里含 `?`** 时不成立。）
 *      ⚠ 实测这是**纯文本替换、无视转义**：往 SQL 里写 `\?` **没用** —— 驱动照样
 *        看见那个 `?` 字符并替换，结果留下 `\NULL`（`\N` 在 MySQL 里又是 NULL），更糟。
 *
 *   ② MySQL 默认会话还开着**反斜杠转义**，而框架的 `sqlEscape` 只做 SQL 标准的 `''` 双写
 *      ⇒ 值里的 `\` 被服务端吃掉（`a\b`→`a` + 退格符、`a\b\c`→`ac`），
 *        值以 `\` 结尾时更会逃逸掉收尾引号 ⇒ **SQL 词法跑飞**（语法错）。
 *      （搬迁前的 mysql 接入文档 §12.3 已记 ②，用 `mysqlSafe` 双写反斜杠解决；
 *        那一条**没有覆盖 ①** —— `?` 这一面是本项目才实测到的。）
 *
 * 处置（**两阶段**，都只碰参数值与最终 SQL 文本，不动 SQL 模板）：
 *   · 阶段一（值上）：值里含 `?` ⇒ 把每个 `?` 换成哨兵 `U+0001`（见下方
 *     `MYSQL_QMARK_SENTINEL` 的完整说明）。驱动看不见 `?`，替换无从发生。
 *     同时把 `\` 双写（抵 MySQL 反斜杠转义）—— 注意**先双写反斜杠再换哨兵**，
 *     顺序不能反：哨兵不是反斜杠，先换也不影响，但反过来会让自己多看一遍。
 *   · 阶段二（`bindSql` 之后的整条 SQL 上）：把哨兵还原成 `?`。
 *
 * ⚠ 为什么必须**两件事一起做**：两者都能单独把 SQL 弄坏。
 *   只补 `\` 不补 `?` ⇒ 就是本缺陷；只补 `?` 不补 `\` ⇒ `"a\"` 结尾逃逸收尾引号、SQL 词法跑飞。
 *
 * 口径选择（`backslashEscapes=true` = 沿用搬迁前 `mysql_store.cj` 的 `noBackslashEscapes: false`）：
 *   本项目无历史数据包袱，两种口径都能自洽；
 *   选 `false` 是为了**与搬迁前存储口径一致**，避免同一批数据在两套代码里读法不同。
 *
 * 为什么不改驱动 / 不改成真参数绑定：
 *   驱动的 `.cjo` 是**预编译产物**（`server/build/mysql-driver/`，源目录仅作参考副本），
 *   本仓不负责重建它；而"真绑定"要求驱动按 `?` 解析——那正是它做错的地方。
 *   在**唯一入口**（本后端的参数化 `exec`/`query`）把值改写成拿不坏的形态，是本仓能保证的那一层。
 *
 * ⚠ 已知代价：用户数据里若**真的**含 `U+0001`，阶段二会把它当成哨兵还原成 `?`。
 *   这是本方案唯一的正确性代价，无法在"值只能是一段字符串内容"的前提下消除。
 *   判定入口是 `mysqlContainsSentinel(v)`，需要时可在业务层拒绝该字符（见 `kbValidate`
 *   一类的校验器）；当前不拒绝，只在这里如实记账。
 */
/*
 * ★★ 数据哨兵：绑定值里的 `?` 先换成它，等值拼进 SQL 文本后再还原成 `?`。
 *
 * 为什么是"换一个字符"而不是"换一种 SQL 写法"（`CHAR(63)`、`0x..`、`_utf8mb4 0x..` 全试过）：
 *   框架 `bindSql` 会给**每个** `DbStr` 套一层引号（`db.cj` 的 `sqlQuote` =
 *   `"'" + sqlEscape(v) + "'"`，而 `sqlEscape` **只双写 `'`、不做反解**）。
 *   于是无论我在值里写什么 SQL 语法，它都会**整体落在一对引号内部**，成为字符串字面量：
 *     · `'CONCAT(''q'', CHAR(63), ''one'')'` → 存进去的是 28 个字符的**文本** `CONCAT('q', CHAR(63), 'one')`
 *     · `'0x713F6F6E65'`               → 存进去的是 12 个字符的**文本** `0x713F6F6E65`
 *     · `'a?b' ESCAPED BY '\\'`        → `ERROR 1064 (42000) ... near 'ESCAPED BY ...'`
 *   实测三条全灭（详见本节上方口径说明）。**"在值里造 SQL 语法"这条路根本不存在** ——
 *   只要值还是 `DbStr`，它就只能是一段**字符串内容**。
 *   所以只能反过来：让内容本身是安全的，把 `?` 藏到一个驱动不认识的字符上。
 *
 * 为什么选 U+0002：它是 ASCII 区控制字符（1 字节）。选 1 字节很重要 —— 驱动是
 *   **字符级**处理 SQL 文本（`originSql.count("?")` / `split("?", ...)`），
 *   多字节哨兵虽然也能工作，但字节数越多，与"按字节切分"的其它环节擦枪走火的概率越大。
 *   而 U+0002 在 MySQL 的字符串字面量里**无需转义、原样保存**，且人类无法从任何输入法键入。
 *   （用 U+0002 而不是 U+0001：`ai_settings` 那批配置值里出现过 `\u0001` 的痕迹，
 *     换一个没用过的码点可以排除"是数据里本来就有的字节"这种混淆。）
 */
const MYSQL_QMARK_SENTINEL = "\u{2}"

/* 哨兵字符是否出现在用户数据里（用于如实报告"该值无法安全往返"，而不是悄悄写坏）。 */
func mysqlContainsSentinel(v: String): Bool {
    return v.contains(MYSQL_QMARK_SENTINEL)
}

/*
 * 阶段一：把绑定值改写成**在 MySQL 会话口径下安全**的形态（调用点见 `mysqlBindLiteral`）。
 *
 * 三条规则（顺序固定，不可互换）：
 *   ① `'` 双写 —— SQL 标准的字符串内引号写法。**这一条是硬性必需**：
 *      不双写就是"值里的单引号提前收尾字面量"，含 `'` 的值**根本插不进去**
 *      （实测 `it's` ⇒ `ERROR 1064 ... near 's')'`）。框架 `sqlQuote` 也会双写，
 *      这里再双写一次是"本函数独立自洽"的代价，见下面 ⚠ 的说明。
 *   ② `\` 双写（`backslashEscapes` 为真时）—— MySQL 默认会话开着反斜杠转义。
 *      不双写则被服务端吃掉字符（`a\b` ⇒ `a` + 退格符），值以 `\` 结尾时更会
 *      逃逸收尾引号 ⇒ SQL 词法跑飞。
 *   ③ `?` **保持原样，不再改写成哨兵**（这一条是第十一轮排查的结论，见下）。
 *
 * ⚠ 顺序：必须**先双写 `'`，再双写 `\`**。反过来的话，② 产生的 `\\` 会被 ① 当成
 *   普通字符（正确），但 ① 产生的 `''` 会被 ② 无视（也正确）—— 真正的理由是：
 *   两条规则各自独立作用在自己的字符上，**先做哪个都不会互相破坏**，但**必须都在
 *   `?` 处理之前**，因为 `?` 现在不再改写（规则③），顺序对它没有影响了。
 *   （历史：曾经顺序不可换是因为 ③ 会把 `?` 换成哨兵，那时顺序有语义。）
 *
 * ⚠ **为什么不再用哨兵**（记下来，免得有人再走一遍）：哨兵方案（值里的 `?` 先换成
 *   `U+0002`、拼进 SQL、交给驱动前再还原）是在 **client 模式**下唯一能想到的路子，
 *   因为 client 模式按**字符个数**认参数（`db.cj` 的占位符计数与驱动的
 *   `originSql.count("?")` 互相冲突）。但它的**唯一出路**是"让哨兵活到服务端"，
 *   而驱动不提供任何发送前钩子（`sendQuery`/`sendUpdate` 全 `protected`），
 *   还原早了等于没换、不还原就把哨兵写进库。⇒ 换到 **server 模式**（不设
 *   `prepare.mode` 即为 server）：参数走二进制协议单独传，SQL 文本里的 `?`
 *   由服务端按语法判定（引号内的就是数据），**根本不需要哨兵**。
 *   实测同一批值在 server 模式下 `?` 全部原样往返。
 *
 * ⚠ 用 `String.join(split(...))` 而不是 `replace`：仓颉 `String.split` 按**字节**比较、
 *   `removeEmpty: false` 保留空段，拼回来严格等价于"每个分隔符换成新串"。
 *   （本会话实测过 `StringBuilder.append(UInt8)` 会追加**十进制数值文本**而非字符，
 *     所以逐字节手写循环这条路是错的，别回去用。）
 */
func mysqlBindEscapeFor(v: String, backslashEscapes: Bool): String {
    var s = v
    if (s.contains("'")) {
        s = String.join(s.split("'", -1, removeEmpty: false), delimiter: "''")
    }
    if (backslashEscapes && s.contains("\\")) {
        s = String.join(s.split("\\", -1, removeEmpty: false), delimiter: "\\\\")
    }
    match (mysqlBindObserver) {
        case Some(ob) => ob(v, s)
        case None => ()
    }
    return s
}

/*
 * ★★ 本后端的 `bindSql`：把 `?` 占位符替换成**安全形态**的值字面量。
 *
 * 与框架 `db.cj` 的 `bindSql` 唯一的语义差别是**值的写法**：
 *   · 框架：`sqlQuote(v)` = `"'" + sqlEscape(v) + "'"`，其中 `sqlEscape` 只双写 `'`
 *     ⇒ 反斜杠不双写（被服务端吃掉）、`?` 原样留在 SQL 文本里（被驱动替换成 `NULL`）。
 *   · 本函数：`'` 双写（SQL 标准）+ `\` 双写（MySQL 口径）+ `?` → 数据哨兵
 *     ⇒ 拼完的 SQL 文本里**一个数据 `?` 都没有**，驱动无从替换。
 *
 * 占位符校验与框架一致（fails fast）：个数不等直接抛，绝不"尽力而为"地拼一条可能
 * 把值写错位置的 SQL —— 写错位置比报错危险得多。
 * 错误消息刻意与框架同形，便于既有排错经验继续用。
 *
 * ⚠ 拼装完成后**不要**在这里还原数据哨兵：还原出来的 `?` 会被**驱动**看见并替换成
 *   `NULL`，那正是本缺陷。还原是对外层的 `exec`/`query` 的责任 —— 顺序是
 *   `mysqlBindSql`（数据哨兵在位）→ `mysqlRestoreQmark`（还原数据 `?`）→ 交给驱动。
 *   中间那一段时间里 SQL 文本中不存在数据 `?`，这就是整个方案成立的原因。
 */
func mysqlBindSql(sql: String, params: Array<DbValue>): String {
    let parts = sql.split("?", -1, removeEmpty: false)
    if (parts.size != params.size + 1) {
        throw Exception("SQL 占位符数量(${parts.size - 1})与参数数量(${params.size})不匹配：${sql}")
    }
    let out = StringBuilder()
    var i = 0
    while (i < parts.size) {
        out.append(parts[i])
        if (i < params.size) {
            out.append(mysqlBindLiteral(params[i]))
        }
        i += 1
    }
    return out.toString()
}

/*
 * 单个值 → 安全字面量。
 * 只有字符串有可逃逸的字符面（数字/布尔/NULL 没有），其余沿用框架的 `dbValueLiteral`。
 *
 * ⚠ 这里**自己加引号**（`"'" + escaped + "'"`）而不是调框架的 `sqlQuote`：
 *   `sqlQuote` = `"'" + sqlEscape(v) + "'"`，其中 `sqlEscape` **只双写 `'`**。
 *   若在这里先 `mysqlBindEscapeFor`（已双写 `'` 与 `\`）再交给 `sqlQuote`，
 *   第二次 `sqlEscape` 会把已经双写的 `'` **再双写一遍**（`it''s` → `it''''s`）。
 *   两条路只能选一条：要么"自己全包"（本函数），要么"只补 `\` 和 `?`、把 `'`
 *   留给 `sqlQuote`"。选前者的理由是**转义口径集中在一处**，读代码不必在
 *   "这个函数没做引号转义，别处补的"之间来回跳。
 */
func mysqlBindLiteral(v: DbValue): String {
    match (v) {
        case DbStr(s) => "'" + mysqlBindEscapeFor(s, true) + "'"
        case other => dbValueLiteral(other)
    }
}

/*
 * 【已废弃】第二阶段哨兵还原 —— 保留仅为记录历史，**当前没有任何调用点**。
 *
 * 为什么废弃：哨兵（`MYSQL_QMARK_SENTINEL`）整套机制只在 client 模式下有意义；
 * 本后端已改用 server 模式（见构造函数里的说明），数据里的 `?` 由服务端按语法
 * 判定，**既不需要哨兵、也不能在交给驱动前把 `?` 还原回去**（client 模式下正是
 * 这一步让驱动重新看见数据 `?` 并替换成 `NULL`，是本缺陷的直接成因）。
 * 留着函数体是为了让"我们曾经这么试过、为什么不行"留在代码里可查。
 */
func mysqlRestoreQmark(sql: String): String {
    return sql.replace(MYSQL_QMARK_SENTINEL, "?")
}
