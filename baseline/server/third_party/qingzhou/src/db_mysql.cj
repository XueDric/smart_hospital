package qingzhou

import std.collection.*
import std.database.sql.*

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
            // prepare.mode=client：框架级 bindSql 已把参数拼进 SQL（无 ? 占位符），
            // 无需 server 模式的真预处理；client 模式直接发普通 query，兼容 DDL
            // （如 CREATE UNIQUE INDEX——server 模式的 COM_STMT_PREPARE 不支持 DDL）。
            [("username", user), ("password", password), ("database", database), ("prepare.mode", "client")]
        )
        conn = ds.connect()
        tx = conn.createTransaction()
        if (noBackslashEscapes) {
            // sql_mode 是 SET 类型，已含该项时会自动去重，故可幂等重复设置
            let stmt = conn.prepareStatement(
                "SET SESSION sql_mode = CONCAT(@@SESSION.sql_mode, ',NO_BACKSLASH_ESCAPES')")
            stmt.update()
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
        let stmt = conn.prepareStatement(sql)
        let qr = stmt.query()
        let out = ArrayList<ArrayList<String>>()
        while (qr.next()) {
            let row = ArrayList<String>()
            let n = qr.columnInfos.size
            var i: Int64 = 1
            while (i <= n) {
                // 统一按 String 取值；若驱动对数值列不支持 get<String>，
                // 需按 columnInfos[i-1] 的列类型改用 get<Int64> 等（见 ColumnInfo）。
                // 用 getOrNull 而非 get：get 在 NULL 列上抛 NoneValueException，
                // 会让任何含 NULL 的查询直接崩。NULL 统一字符串化为 "NULL"，
                // 与 CangDB 后端的约定一致（DbResultSet.getNullable 两端行为相同）。
                match (qr.getOrNull<String>(i)) {
                    case Some(v) => row.add(v)
                    case None => row.add("NULL")
                }
                i += 1
            }
            out.add(row)
        }
        return DbResultSet(out)
    }

    /* 执行写操作，返回受影响行数（UpdateResult.rowCount）。 */
    public func exec(sql: String): Int64 {
        let stmt = conn.prepareStatement(sql)
        let ur = stmt.update()
        return ur.rowCount
    }

    /* 确保表存在：MySQL 支持 CREATE TABLE IF NOT EXISTS，一条语句搞定。 */
    public func ensureTable(name: String, columns: String): Unit {
        exec("CREATE TABLE IF NOT EXISTS " + name + " (" + columns + ")")
    }

    /* 关闭连接，归还驱动连接资源。 */
    public func close(): Unit {
        conn.close()
    }

    /* 开启事务：通过 Connection 的事务对象发送 BEGIN。 */
    public func beginTransaction(): Unit {
        tx.begin()
    }

    /* 提交事务：COMMIT。 */
    public func commitTransaction(): Unit {
        tx.commit()
    }

    /* 回滚事务：ROLLBACK。 */
    public func rollbackTransaction(): Unit {
        tx.rollback()
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
