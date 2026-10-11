package qingzhou

import std.collection.*

/*
 * SPDX-License-Identifier: MIT
 *
 * 流式查询构建器（参数化优先）。
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * 与生态里其他 SQL 构造库的区别：**产出的是可直接执行的 (sql, params)**，
 * 参数已转成 DbValue 序列，直接喂给 DbBackend.query/exec 的绑定入口——
 * 既是 SQL 构造器，也闭环到执行层；且默认拒绝一切 CangDB 解析不了的构造，
 * 不做「在 MySQL 上能跑、换 CangDB 就炸」的静默降级。
 *
 * 用法：
 *   let (sql, ps) = SelectQuery().from("users").select(["id", "name"])
 *       .filter(dbEq("role_id", DbInt(1))).orderBy("id", desc: true).toSql()
 *   let rs = be.query(sql, ps)
 *   // 或直接 .query(be)：方言取自后端自身
 */

/* 方言：决定构建器允许产出哪些构造。 */

/*
 * 两个后端的 SQL 能力并不相同——CangDB 是自实现的 SQL 子集解析器，
 * 只认 `= > < >= <= LIKE BETWEEN` + 扁平 AND，没有 OR / 括号 / != /
 * IS NULL / 值列表 IN / LIMIT / OFFSET；MySQL 则全都有。
 *
 * 因此构建器必须知道目标方言：Common 只产出两边都认的子集，
 * 越界构造在**构建期**就抛异常，而不是等后端解析报错。
 */
public enum DbDialect {
    | Common
    | MySql
}

/* 比较运算符。Ne（<>）CangDB 不支持，仅在 MySql 方言下放行。 */
public enum DbOp {
    | Eq
    | Ne
    | Gt
    | Ge
    | Lt
    | Le
}

/*
 * 条件树。叶子为列与值的比较，And/Or/Not 组合。
 * 各构造的方言可用性见 DbDialect 注释。
 */
public enum DbCond {
    | Cmp(String, DbOp, DbValue)
    | Between(String, DbValue, DbValue)
    | Like(String, DbValue)
    | InList(String, Array<DbValue>)
    | NullTest(String, Bool)
    | And(Array<DbCond>)
    | Or(Array<DbCond>)
    | Not(DbCond)
    | Raw(String, Array<DbValue>)
}

/* 条件构造便捷入口（前缀 db 避免与包内既有顶层函数撞名）。 */

public func dbEq(col: String, v: DbValue): DbCond { DbCond.Cmp(col, DbOp.Eq, v) }
public func dbNe(col: String, v: DbValue): DbCond { DbCond.Cmp(col, DbOp.Ne, v) }
public func dbGt(col: String, v: DbValue): DbCond { DbCond.Cmp(col, DbOp.Gt, v) }
public func dbGe(col: String, v: DbValue): DbCond { DbCond.Cmp(col, DbOp.Ge, v) }
public func dbLt(col: String, v: DbValue): DbCond { DbCond.Cmp(col, DbOp.Lt, v) }
public func dbLe(col: String, v: DbValue): DbCond { DbCond.Cmp(col, DbOp.Le, v) }
public func dbLike(col: String, v: DbValue): DbCond { DbCond.Like(col, v) }
public func dbBetween(col: String, lo: DbValue, hi: DbValue): DbCond {
    DbCond.Between(col, lo, hi)
}
public func dbIn(col: String, vs: Array<DbValue>): DbCond { DbCond.InList(col, vs) }
public func dbIsNull(col: String): DbCond { DbCond.NullTest(col, true) }
public func dbNotNull(col: String): DbCond { DbCond.NullTest(col, false) }
public func dbAnd(cs: Array<DbCond>): DbCond { DbCond.And(cs) }
public func dbOr(cs: Array<DbCond>): DbCond { DbCond.Or(cs) }
public func dbNot(c: DbCond): DbCond { DbCond.Not(c) }

/*
 * 逃生口：原样 SQL 片段 + 其参数（片段内用 ? 占位）。
 * 用它即放弃方言检查，调用方自负两端兼容性。
 */
public func dbRaw(sql: String, ps!: Array<DbValue> = Array<DbValue>()): DbCond {
    DbCond.Raw(sql, ps)
}

/* SQL 累积缓冲：避免「捕获 var 的 lambda 不能作函数值传递」这一语言限制。 */
class SqlBuf {
    public var sql: String = ""
    public let params: ArrayList<DbValue> = ArrayList<DbValue>()

    public func add(s: String): Unit {
        sql += s
    }

    /* 写一个占位符并登记参数——二者必须成对，否则 bindSql 的数量校验会失败。 */
    public func bind(v: DbValue): Unit {
        sql += "?"
        params.add(v)
    }
}

/*
 * 标识符校验。表名/列名是 SQL 结构的一部分，无法用参数占位符替代，
 * 因此只能「校验放行」而不能「转义」——各后端标识符引号语法不同
 * （MySQL 反引号 / SQLite 双引号），靠引号转义反而制造方言分叉。
 *
 * 放行 [A-Za-z_][A-Za-z0-9_]*，允许一个 表.列 限定前缀；其余一律抛异常。
 */
public func sqlIdent(name: String): String {
    let bytes = name.toArray()
    if (bytes.size == 0) {
        throw Exception("标识符不能为空")
    }
    var dots: Int64 = 0
    var atSegmentStart = true
    var i: Int64 = 0
    while (i < bytes.size) {
        let b = bytes[i]
        if (b == 46) {                       // '.'
            if (atSegmentStart) {
                throw Exception("非法标识符: " + name + "（点号位置不当）")
            }
            dots += 1
            if (dots > 1) {
                throw Exception("非法标识符: " + name + "（只允许一个 表.列 前缀）")
            }
            atSegmentStart = true
        } else if (!identByteOk(b, atSegmentStart)) {
            throw Exception("非法标识符: " + name +
                "（只允许字母/数字/下划线，可带一个 表.列 前缀）")
        } else {
            atSegmentStart = false
        }
        i += 1
    }
    if (atSegmentStart) {
        throw Exception("非法标识符: " + name + "（不能以点号结尾）")
    }
    return name
}

func identByteOk(b: UInt8, atSegmentStart: Bool): Bool {
    let isUpper = b >= 65 && b <= 90
    let isLower = b >= 97 && b <= 122
    let isUnderscore = b == 95
    if (atSegmentStart) {
        return isUpper || isLower || isUnderscore
    }
    let isDigit = b >= 48 && b <= 57
    return isUpper || isLower || isUnderscore || isDigit
}

/* 该构造只有 MySQL 支持时，在 Common 方言下明确拒绝。 */
func requireMySql(d: DbDialect, what: String): Unit {
    match (d) {
        case MySql => ()
        case Common =>
            throw Exception(what + " 在 Common 方言下不可用：CangDB 的 SQL 子集不支持它。" +
                "确认目标只有 MySQL 时用 toSql(dialect: DbDialect.MySql)")
    }
}

func opText(op: DbOp): String {
    match (op) {
        case Eq => "="
        case Ne => "<>"
        case Gt => ">"
        case Ge => ">="
        case Lt => "<"
        case Le => "<="
    }
}

func renderCond(c: DbCond, d: DbDialect, b: SqlBuf): Unit {
    match (c) {
        case Cmp(col, op, v) =>
            match (op) {
                case Ne => requireMySql(d, "运算符 <>")
                case _ => ()
            }
            b.add(sqlIdent(col))
            b.add(" ")
            b.add(opText(op))
            b.add(" ")
            b.bind(v)
        case Between(col, lo, hi) =>
            b.add(sqlIdent(col))
            b.add(" BETWEEN ")
            b.bind(lo)
            b.add(" AND ")
            b.bind(hi)
        case Like(col, v) =>
            b.add(sqlIdent(col))
            b.add(" LIKE ")
            b.bind(v)
        case InList(col, vs) =>
            requireMySql(d, "IN (值列表)")
            if (vs.size == 0) {
                throw Exception("IN 值列表不能为空")
            }
            b.add(sqlIdent(col))
            b.add(" IN (")
            var i: Int64 = 0
            while (i < vs.size) {
                if (i > 0) {
                    b.add(", ")
                }
                b.bind(vs[i])
                i += 1
            }
            b.add(")")
        case NullTest(col, isNull) =>
            requireMySql(d, "IS NULL / IS NOT NULL")
            b.add(sqlIdent(col))
            b.add(if (isNull) { " IS NULL" } else { " IS NOT NULL" })
        case And(cs) => renderGroup(cs, " AND ", d, b)
        case Or(cs) =>
            requireMySql(d, "OR")
            renderGroup(cs, " OR ", d, b)
        case Not(inner) =>
            requireMySql(d, "NOT")
            b.add("NOT (")
            renderCond(inner, d, b)
            b.add(")")
        case Raw(sql, ps) =>
            b.add(sql)
            var i: Int64 = 0
            while (i < ps.size) {
                b.params.add(ps[i])          // 片段自带 ?，故只登记参数不写占位符
                i += 1
            }
    }
}

/*
 * 条件组：MySQL 下加括号保证优先级；Common 下扁平输出（CangDB 不认括号，
 * 而它只支持 AND，扁平化语义等价）。
 */
func renderGroup(cs: Array<DbCond>, sep: String, d: DbDialect, b: SqlBuf): Unit {
    if (cs.size == 0) {
        throw Exception("条件组不能为空")
    }
    var wrapped = false
    if (cs.size > 1) {
        match (d) {
            case MySql =>
                b.add("(")
                wrapped = true
            case Common => ()
        }
    }
    var i: Int64 = 0
    while (i < cs.size) {
        if (i > 0) {
            b.add(sep)
        }
        renderCond(cs[i], d, b)
        i += 1
    }
    if (wrapped) {
        b.add(")")
    }
}

/* 渲染 WHERE 子句（无条件时什么都不写）。 */
func renderWhere(cond: ?DbCond, d: DbDialect, b: SqlBuf): Unit {
    match (cond) {
        case Some(c) =>
            b.add(" WHERE ")
            renderCond(c, d, b)
        case None => ()
    }
}

/* SELECT */

public class SelectQuery {
    private var table: String = ""
    private let cols: ArrayList<String> = ArrayList<String>()
    private var cond: ?DbCond = None
    private let orderCols: ArrayList<String> = ArrayList<String>()
    private let orderDesc: ArrayList<Bool> = ArrayList<Bool>()
    private var limitN: ?Int64 = None
    private var offsetN: ?Int64 = None

    public init() {}

    /* 选中列；不调用则为 *。 */
    public func select(columns: Array<String>): SelectQuery {
        for (c in columns) {
            cols.add(c)
        }
        return this
    }

    public func from(t: String): SelectQuery {
        table = t
        return this
    }

    public func filter(c: DbCond): SelectQuery {
        cond = Some(c)
        return this
    }

    /* 追加一个 AND 条件（多次调用等价于 dbAnd 包裹）。 */
    public func andFilter(c: DbCond): SelectQuery {
        cond = match (cond) {
            case Some(existing) => Some(DbCond.And([existing, c]))
            case None => Some(c)
        }
        return this
    }

    public func orderBy(col: String, desc!: Bool = false): SelectQuery {
        orderCols.add(col)
        orderDesc.add(desc)
        return this
    }

    /* MySQL 专用（CangDB 无 LIMIT/OFFSET）。 */
    public func limit(n: Int64): SelectQuery {
        limitN = Some(n)
        return this
    }

    /* MySQL 专用。 */
    public func offset(n: Int64): SelectQuery {
        offsetN = Some(n)
        return this
    }

    public func toSql(dialect!: DbDialect = DbDialect.Common): (String, Array<DbValue>) {
        if (table.size == 0) {
            throw Exception("SELECT 缺少 from(表名)")
        }
        let b = SqlBuf()
        b.add("SELECT ")
        if (cols.size == 0) {
            b.add("*")
        } else {
            var i: Int64 = 0
            while (i < cols.size) {
                if (i > 0) {
                    b.add(", ")
                }
                b.add(sqlIdent(cols[i]))
                i += 1
            }
        }
        b.add(" FROM ")
        b.add(sqlIdent(table))
        renderWhere(cond, dialect, b)
        if (orderCols.size > 0) {
            b.add(" ORDER BY ")
            var i: Int64 = 0
            while (i < orderCols.size) {
                if (i > 0) {
                    b.add(", ")
                }
                b.add(sqlIdent(orderCols[i]))
                if (orderDesc[i]) {
                    b.add(" DESC")
                }
                i += 1
            }
        }
        match (limitN) {
            case Some(n) =>
                requireMySql(dialect, "LIMIT")
                b.add(" LIMIT " + n.toString())
            case None => ()
        }
        match (offsetN) {
            case Some(n) =>
                requireMySql(dialect, "OFFSET")
                b.add(" OFFSET " + n.toString())
            case None => ()
        }
        return (b.sql, b.params.toArray())
    }

    /* 直接对后端执行；方言取自后端自身（DbBackend.dialect）。 */
    public func query(be: DbBackend): DbResultSet {
        let (sql, ps) = toSql(dialect: be.dialect())
        return be.query(sql, ps)
    }
}

/* INSERT */

public class InsertQuery {
    private var table: String = ""
    private let cols: ArrayList<String> = ArrayList<String>()
    private let vals: ArrayList<DbValue> = ArrayList<DbValue>()
    private var positional: ?Array<DbValue> = None

    public init() {}

    public func into(t: String): InsertQuery {
        table = t
        return this
    }

    /*
     * 带列名的赋值：产出 INSERT INTO t (a, b) VALUES (?, ?)。
     * CangDB 的 INSERT 不接受列清单，故仅 MySql 方言可用。
     */
    public func set(col: String, v: DbValue): InsertQuery {
        cols.add(col)
        vals.add(v)
        return this
    }

    /*
     * 位置赋值：产出 INSERT INTO t VALUES (?, ?)，值须按表列顺序给出。
     * 这是两个后端都支持的写法（CangDB 唯一支持的写法）。
     */
    public func values(vs: Array<DbValue>): InsertQuery {
        positional = Some(vs)
        return this
    }

    public func toSql(dialect!: DbDialect = DbDialect.Common): (String, Array<DbValue>) {
        if (table.size == 0) {
            throw Exception("INSERT 缺少 into(表名)")
        }
        let b = SqlBuf()
        b.add("INSERT INTO ")
        b.add(sqlIdent(table))
        match (positional) {
            case Some(vs) =>
                if (cols.size > 0) {
                    throw Exception("values(...) 与 set(...) 不能混用")
                }
                if (vs.size == 0) {
                    throw Exception("INSERT 值不能为空")
                }
                b.add(" VALUES (")
                var i: Int64 = 0
                while (i < vs.size) {
                    if (i > 0) {
                        b.add(", ")
                    }
                    b.bind(vs[i])
                    i += 1
                }
                b.add(")")
            case None =>
                if (cols.size == 0) {
                    throw Exception("INSERT 需要 set(列, 值) 或 values(值序列)")
                }
                requireMySql(dialect, "INSERT 的列清单形式")
                b.add(" (")
                var j: Int64 = 0
                while (j < cols.size) {
                    if (j > 0) {
                        b.add(", ")
                    }
                    b.add(sqlIdent(cols[j]))
                    j += 1
                }
                b.add(") VALUES (")
                var k: Int64 = 0
                while (k < vals.size) {
                    if (k > 0) {
                        b.add(", ")
                    }
                    b.bind(vals[k])
                    k += 1
                }
                b.add(")")
        }
        return (b.sql, b.params.toArray())
    }

    public func exec(be: DbBackend): Int64 {
        let (sql, ps) = toSql(dialect: be.dialect())
        return be.exec(sql, ps)
    }
}

/* UPDATE */

public class UpdateQuery {
    private var table: String = ""
    private let cols: ArrayList<String> = ArrayList<String>()
    private let vals: ArrayList<DbValue> = ArrayList<DbValue>()
    private var cond: ?DbCond = None
    private var fullTableAllowed = false

    public init() {}

    public func update(t: String): UpdateQuery {
        table = t
        return this
    }

    public func set(col: String, v: DbValue): UpdateQuery {
        cols.add(col)
        vals.add(v)
        return this
    }

    public func filter(c: DbCond): UpdateQuery {
        cond = Some(c)
        return this
    }

    /* 显式声明「允许无 WHERE 的全表更新」——默认拒绝，防误操作。 */
    public func allowFullTable(): UpdateQuery {
        fullTableAllowed = true
        return this
    }

    public func toSql(dialect!: DbDialect = DbDialect.Common): (String, Array<DbValue>) {
        if (table.size == 0) {
            throw Exception("UPDATE 缺少 update(表名)")
        }
        if (cols.size == 0) {
            throw Exception("UPDATE 缺少 set(列, 值)")
        }
        match (cond) {
            case Some(_) => ()
            case None =>
                if (!fullTableAllowed) {
                    throw Exception("UPDATE 没有 WHERE：全表更新影响面大，" +
                        "确认无误请显式调用 allowFullTable()")
                }
        }
        let b = SqlBuf()
        b.add("UPDATE ")
        b.add(sqlIdent(table))
        b.add(" SET ")
        var i: Int64 = 0
        while (i < cols.size) {
            if (i > 0) {
                b.add(", ")
            }
            b.add(sqlIdent(cols[i]))
            b.add(" = ")
            b.bind(vals[i])
            i += 1
        }
        renderWhere(cond, dialect, b)
        return (b.sql, b.params.toArray())
    }

    public func exec(be: DbBackend): Int64 {
        let (sql, ps) = toSql(dialect: be.dialect())
        return be.exec(sql, ps)
    }
}

/* DELETE */

public class DeleteQuery {
    private var table: String = ""
    private var cond: ?DbCond = None
    private var fullTableAllowed = false

    public init() {}

    public func from(t: String): DeleteQuery {
        table = t
        return this
    }

    public func filter(c: DbCond): DeleteQuery {
        cond = Some(c)
        return this
    }

    /* 显式声明「允许无 WHERE 的全表删除」——默认拒绝，防误操作。 */
    public func allowFullTable(): DeleteQuery {
        fullTableAllowed = true
        return this
    }

    public func toSql(dialect!: DbDialect = DbDialect.Common): (String, Array<DbValue>) {
        if (table.size == 0) {
            throw Exception("DELETE 缺少 from(表名)")
        }
        match (cond) {
            case Some(_) => ()
            case None =>
                if (!fullTableAllowed) {
                    throw Exception("DELETE 没有 WHERE：全表删除影响面大，" +
                        "确认无误请显式调用 allowFullTable()")
                }
        }
        let b = SqlBuf()
        b.add("DELETE FROM ")
        b.add(sqlIdent(table))
        renderWhere(cond, dialect, b)
        return (b.sql, b.params.toArray())
    }

    public func exec(be: DbBackend): Int64 {
        let (sql, ps) = toSql(dialect: be.dialect())
        return be.exec(sql, ps)
    }
}
