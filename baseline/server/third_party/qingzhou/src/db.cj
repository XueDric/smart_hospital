package qingzhou

import std.collection.*
import std.convert.*

/*
 * SPDX-License-Identifier: MIT
 *
 * 数据库抽象层（DbBackend 接口 + DbResultSet）。
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * 让框架的数据访问层（RbacStore）依赖抽象接口而非具体数据库，
 * 从而「很容易切换数据库」：CangDB 嵌入式 / MySQL / 未来新增后端
 * 都实现 DbBackend，通过工厂按 DSN 选择即可，业务代码零改动。
 *
 * 设计要点：
 *   - 结果集所有列值统一转成字符串（屏蔽各数据库类型差异）
 *   - 只暴露最小能力集：query（查）/ exec（写）/ ensureTable（建表）/ close
 *   - SQL 方言差异（建表检查等）下沉到各后端实现
 */

/*
 * 结果集：行 x 列，所有值已字符串化（屏蔽各数据库原生类型差异）。
 * DbBackend.query 的返回类型，业务层用它做行级/单元格级读取。
 */
public class DbResultSet {
    /* 行集合，每行是按 SELECT 列序排列的字符串列表。 */
    public let rows: ArrayList<ArrayList<String>>

    public init() {
        rows = ArrayList<ArrayList<String>>()
    }

    public init(rows: ArrayList<ArrayList<String>>) {
        this.rows = rows
    }

    /* 返回行数（不含表头，仅数据行）。 */
    public func rowCount(): Int64 {
        return rows.size
    }

    /* 取第 i 行第 j 列，越界返回空串（宽容访问，避免异常）。 */
    public func cell(i: Int64, j: Int64): String {
        match (rows.get(i)) {
            case Some(row) =>
                match (row.get(j)) {
                    case Some(v) => return v
                    case None => return ""
                }
            case None => return ""
        }
    }

    /* 取第 i 行，越界返回 None。 */
    public func row(i: Int64): ?ArrayList<String> {
        return rows.get(i)
    }

    /*
     * 类型化取值：业务代码不必再手写
     * Int64.parse(cell(...))。底层仍是字符串化值，这里按目标类型解析。
     */

    /* 取字符串（等价 cell，命名与 getInt/getFloat 对齐）。 */
    public func getString(i: Int64, j: Int64): String {
        return cell(i, j)
    }

    /* 取整数：列值须为合法 Int64 字面量，否则抛异常。 */
    public func getInt(i: Int64, j: Int64): Int64 {
        return Int64.parse(cell(i, j))
    }

    /* 取浮点：列值须为合法 Float64 字面量，否则抛异常。 */
    public func getFloat(i: Int64, j: Int64): Float64 {
        return Float64.parse(cell(i, j))
    }

    /*
     * NULL 感知取值：列值为空串或 "NULL"（CangDB valueStr 对 Null 的
     * 字符串化表示）时返回 None，否则返回 Some(值)。用于可空列。
     */
    public func getNullable(i: Int64, j: Int64): ?String {
        let v = cell(i, j)
        if (v == "" || v == "NULL") {
            return None
        }
        return Some(v)
    }
}

/*
 * 数据库后端抽象接口：框架数据访问层（RbacStore 等）只依赖此接口，
 * 不感知具体数据库。新增后端（PostgreSQL、SQLite 等）实现本接口即可接入。
 * 传入的 SQL 须为各数据库兼容的最小公共子集（约定见 src/store.cj 顶部）。
 */
public interface DbBackend {
    /* 执行查询（SELECT），返回字符串化结果集。 */
    func query(sql: String): DbResultSet

    /* 执行写操作（INSERT/UPDATE/DELETE/DDL），返回受影响行数。 */
    func exec(sql: String): Int64

    /* 确保表存在：存在性检查与建表方言由各后端自行处理。 */
    func ensureTable(name: String, columns: String): Unit

    /* 关闭连接，释放后端持有的资源（进程退出前调用）。 */
    func close(): Unit

    /*
     * 参数化查询：SQL 用 ? 占位符，参数按序绑定，
     * 从根本上消除「业务代码手写 sqlQuote 拼接」这一注入源。
     *
     * 默认实现走框架级类型化字面量化（bindSql）：把每个 ? 按序替换为
     * 类型感知的安全字面量（字符串必转义、数字原样、Bool→1/0、Null→NULL），
     * 两个后端（CangDB 字符串解析器 / MySQL）行为一致。
     *
     * 后端可覆盖为真正的服务器端预处理（如 std.database.sql 驱动的
     * PreparedStatement.set<T>），接口与业务代码零改动。
     */
    func query(sql: String, params: Array<DbValue>): DbResultSet {
        query(bindSql(sql, params))
    }

    /* 参数化写操作（INSERT/UPDATE/DELETE/DDL），返回受影响行数。 */
    func exec(sql: String, params: Array<DbValue>): Int64 {
        exec(bindSql(sql, params))
    }

    /*
     * 事务：begin → 若干写操作 → commit/rollback。
     * 各后端按自身 API 实现（CangDB 用 Db.begin/commit/rollback，
     * MySQL 用 Connection.createTransaction 返回的 Transaction）；
     * 不支持事务的后端实现为抛异常即可。
     */
    func beginTransaction(): Unit

    /* 提交当前事务，落盘全部写操作。 */
    func commitTransaction(): Unit

    /* 回滚当前事务，丢弃全部未提交写操作。 */
    func rollbackTransaction(): Unit

    /*
     * 事务回调：自动 begin → 执行 body → commit，
     * body 抛异常则回滚并重新抛出。业务侧原子化多语句写操作的首选，
     * 免去手写 begin/commit/rollback 的成对管理。
     */
    func withTransaction(body: () -> Unit): Unit {
        beginTransaction()
        try {
            body()
            commitTransaction()
        } catch (e: Exception) {
            rollbackTransaction()
            throw e
        }
    }

    /*
     * 后端方言：查询构建器（dbquery.cj）据此决定允许产出哪些 SQL 构造。
     * 默认 Common —— 只产出两个后端都认的公共子集；能力更强的后端覆盖它。
     */
    func dialect(): DbDialect {
        DbDialect.Common
    }

    /*
     * 确保唯一索引：为表某列建唯一索引。默认实现用
     * `CREATE UNIQUE INDEX idx_<table>_<column> ON <table>(<column>)`，
     * 适合 CangDB；MySQL 的 TEXT 列建索引须指定前缀长度，后端可覆盖
     * （见 db_mysql.cj）。重复建索引时后端抛「已存在」异常，调用方
     * 应捕获并忽略（幂等）。
     */
    func ensureUniqueIndex(table: String, column: String): Unit {
        exec("CREATE UNIQUE INDEX idx_" + table + "_" + column + " ON " + table + "(" + column + ")")
    }
}

/* SQL 字符串转义 */

/*
 * SQL 字符串字面量转义：仅把单引号双写（' -> ''）。
 *
 * 这是 SQL 标准转义，两个后端均正确处理：
 *   - CangDB：cangdb core.cj readString 显式支持 '' 跳出（逐字符词法）；
 *   - MySQL：默认模式与 NO_BACKSLASH_ESCAPES 模式下 '' 都成立。
 *
 * MySQL 侧的尾反斜杠隐患（默认的反斜杠转义会吃掉字面量的收尾引号）
 * 已由 MySqlBackend 建连时固定会话 sql_mode=NO_BACKSLASH_ESCAPES 消除，
 * 故 '' 方案在两个后端上语义一致（见 docs/DATABASE.md）。
 *
 * 拼接约定：所有含外部输入的字符串值一律经 sqlQuote 包裹后再拼进
 * SQL，见 RbacStore（src/store.cj）的调用示例。
 */
public func sqlEscape(s: String): String {
    if (s.size == 0) {
        return s
    }
    // 按 ' 切开再用 '' 连接：等价于把每个 ' 替换为 ''，且自动处理
    // 开头/结尾/连续引号（切分会产生空片段，removeEmpty: false 保留）。
    return String.join(s.split("'", -1, removeEmpty: false), delimiter: "''")
}

/* sqlEscape 后包一层单引号，得到可直接拼进 SQL 的字符串字面量。 */
public func sqlQuote(s: String): String {
    return "'" + sqlEscape(s) + "'"
}

/* 参数化查询 */

/*
 * SQL 绑定值：参数化查询（DbBackend.query/exec 的 params）的元素类型。
 * 用枚举区分值的类型，绑定层据此生成「类型感知」的安全字面量：
 *   - DbStr 走 sqlQuote（单引号转义）
 *   - DbInt / DbFloat 原样输出（数值无注入面，绝不被误加引号）
 *   - DbBool 转 1/0，DbNull 转 NULL
 */
public enum DbValue {
    | DbInt(Int64)
    | DbFloat(Float64)
    | DbStr(String)
    | DbBool(Bool)
    | DbNull
}

/*
 * 把单个绑定值转成可直接拼进 SQL 的字面量。字符串必须转义（sqlQuote），
 * 数字原样、布尔转 1/0、NULL 原样 —— 这是参数化安全的关键：类型明确，
 * 不会把「外部字符串」漏转义，也不会给「数字」误加引号。
 */
public func dbValueLiteral(v: DbValue): String {
    match (v) {
        case DbInt(n) => n.toString()
        case DbFloat(f) => f.toString()
        case DbStr(s) => sqlQuote(s)
        case DbBool(b) => if (b) { "1" } else { "0" }
        case DbNull => "NULL"
    }
}

/*
 * 框架级参数绑定：把 SQL 里的 ? 占位符按序替换为对应绑定值的字面量。
 *
 * 占位符数量必须与参数数量严格一致，否则抛异常（快速失败，防止漏绑）。
 * 约定：SQL 模板里不得出现字面量 ?（框架 SQL 均为简单等值/INSERT/UPDATE，
 * 无此场景）；? 仅作占位符。所有后端共用此实现，保证转义语义一致。
 */
public func bindSql(sql: String, params: Array<DbValue>): String {
    let parts = sql.split("?", -1, removeEmpty: false)
    if (parts.size != params.size + 1) {
        throw Exception("SQL 占位符数量(${parts.size - 1})与参数数量(${params.size})不匹配：${sql}")
    }
    var out = parts.get(0).getOrThrow()
    var i: Int64 = 0
    while (i < params.size) {
        out += dbValueLiteral(params.get(i).getOrThrow())
        out += parts.get(i + 1).getOrThrow()
        i += 1
    }
    return out
}
