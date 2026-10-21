package qingzhou

/* ArrayList 来自 std.collection，须显式 import（仓颉没有隐式导入）。 */
import std.collection.*
import std.database.sql.*

/*
 * SPDX-License-Identifier: MIT
 *
 *
 * ===== domain_base.cj —— 基础数据域（科室 / 医生）=================
 *
 * 职责：department / doctor 两张表的管理端 CRUD（分页、软删、引用检查）
 * 对外：DepartmentRepo / DoctorRepo / BaseWriteOutcome；写入不抛异常，业务拒绝靠返回值表达
 * 不含 patient：患者档案是敏感个人信息，开 CRUD 属合规决策而非工程便利
 * 错误码：BASE_NOT_FOUND 404、BASE_NAME_TAKEN / BASE_CODE_TAKEN / BASE_IN_USE 409、
 *        VALIDATION_FAILED 400（映射在 http_base.cj）
 * 不变量：name / code 由数据库唯一键兜底（uk_department_name / uk_department_code），不做先查后插
 * 不变量：删除语义由 ?force= 显式选择 —— 默认只删未被引用者（409 说清谁在用），force=true 软删（enabled=0）
 * 不变量：不存在硬删 —— appointment / schedule / medical_record 都可能引用，硬删会破坏历史
 */

/* ===================== 科室 ===================== */

/* 科室（`department` 表的一行）。 */
/* 常量与校验函数必须在首次使用之前定义：仓颉没有 hoisting（declare before use）。 */
public let BASE_NAME_MAX: Int64 = 64
public let BASE_CODE_MAX: Int64 = 32
public let BASE_LOCATION_MAX: Int64 = 128
public let BASE_TITLE_MAX: Int64 = 32
public let BASE_SPECIALTY_MAX: Int64 = 255

/* 长度按字符数算，不按字节：列是 VARCHAR(64)（64 字符），按字节判中文姓名只剩 21 字可用。
 * 超长或为空 ⇒ invalid ⇒ 400。 */
public func baseValidateName(v: String, what: String): String {
    let t = v.trimAscii()
    if (t.size == 0) {
        return "${what}不能为空"
    }
    if (previsitCharLen(t) > BASE_NAME_MAX) {
        return "${what}最长 ${BASE_NAME_MAX} 字"
    }
    /* 拒绝控制字符（含换行/制表）：会破坏 JSON 与日志的单行假设，且没有合法用途。
     * 明确拒绝比"存进去再想办法显示"可靠。 */
    if (baseHasControlChar(t)) {
        return "${what}不能含控制字符（换行/制表等）"
    }
    return ""
}

public func baseValidateCode(v: String, what: String): String {
    let t = v.trimAscii()
    if (t.size == 0) {
        return "${what}不能为空"
    }
    if (previsitCharLen(t) > BASE_CODE_MAX) {
        return "${what}最长 ${BASE_CODE_MAX} 字"
    }
    /* 编码是给程序看的稳定标识（分诊/统计按它对齐）：限定 [A-Za-z0-9_-]，不允许空格与中文。
     * 避免出现"看起来像名字"的编码。 */
    for (r in t.runes()) {
        let ok = (r >= r'a' && r <= r'z') || (r >= r'A' && r <= r'Z') ||
                 (r >= r'0' && r <= r'9') || r == r'_' || r == r'-'
        if (!ok) {
            return "${what}只能含字母/数字/下划线/连字符（实得含「${r}」）"
        }
    }
    return ""
}

/* 是否含 ASCII 控制字符（0x00-0x1F、0x7F）。 */
public func baseHasControlChar(s: String): Bool {
    for (b in s.toArray()) {
        if (b < 0x20 || b == 0x7F) {
            return true
        }
    }
    return false
}


public class Department {
    public var id: Int64 = 0
    public var name: String = ""
    public var code: String = ""
    public var location: String = ""
    public var sort: Int64 = 0
    public var enabled: Bool = true
    public var createdAt: Int64 = 0
}

/* 科室/医生写入的结果（**不抛异常**：可预期的业务拒绝靠返回值表达）。 */
public class BaseWriteOutcome {
    /* 写入成功。`id` 是新建/更新后的主键。 */
    public var ok: Bool = false
    public var id: Int64 = 0
    /* 目标不存在（404）。⚠ 与"别人的"不可区分 —— 不制造枚举 oracle。 */
    public var notFound: Bool = false
    /* 违反唯一键（`code` 或 `name` 重复）⇒ 409。`conflictField` 指出是哪个。 */
    public var duplicate: Bool = false
    public var conflictField: String = ""
    /* 被引用，不能删（默认 force=false 时的删除）⇒ 409。`inUseBy` 说清是谁。 */
    public var inUse: Bool = false
    public var inUseBy: String = ""
    /* 参数不合法 ⇒ 400。`detail` 是给使用者看的原因。 */
    public var invalid: Bool = false
    public var detail: String = ""

    public func markOk(newId: Int64): BaseWriteOutcome {
        this.ok = true
        this.id = newId
        return this
    }

    public func markDuplicate(field: String): BaseWriteOutcome {
        this.duplicate = true
        this.conflictField = field
        return this
    }

    public func markInUse(by: String): BaseWriteOutcome {
        this.inUse = true
        this.inUseBy = by
        return this
    }

    public func markInvalid(why: String): BaseWriteOutcome {
        this.invalid = true
        this.detail = why
        return this
    }
}

/*
 * 科室仓储。科室没有并发热点（不是每秒被抢的资源），所以不用条件 UPDATE 那套。
 * 唯一键由数据库兜底，应用层不做先查后插（那是 TOCTOU）：直接 INSERT，捕获唯一键冲突判重复。
 * 冲突分类见文件末尾 baseClassifyDuplicate。
 */
public class DepartmentRepo {
    private let db: DbBackend

    public init(db: DbBackend) {
        this.db = db
    }

    public func listAll(includeDisabled!: Bool = true, limit!: Int64 = 0, offset!: Int64 = 0): Array<Department> {
        var sql = "SELECT id, name, code, location, sort, enabled, created_at FROM department"
        if (!includeDisabled) {
            sql = sql + " WHERE enabled = 1"
        }
        sql = sql + " ORDER BY sort ASC, id ASC"
        /* 分页：limit <= 0 = 不分页（读全表建名字索引的调用点不会被误截断，截断 = 页面显示空科室名）。
         * offset 只在分页时拼 —— 单独 OFFSET 在 MySQL 是语法错误；负数一律夹到 0，不透传进 SQL。
         * LIMIT ? OFFSET ? 参数化：这是本函数唯一的注入面。total 由 countAll 给，两处 where 必须逐字一致。 */
        let args = ArrayList<DbValue>()
        if (limit > 0) {
            var off = offset
            if (off < 0) {
                off = 0
            }
            sql = sql + " LIMIT ? OFFSET ?"
            args.add(DbInt(limit))
            args.add(DbInt(off))
        }
        let rs = db.query(sql, args.toArray())
        let out = ArrayList<Department>()
        var i: Int64 = 0
        while (i < rs.rowCount()) {
            let d = Department()
            d.id = rs.getInt(i, 0)
            d.name = rs.getString(i, 1)
            d.code = rs.getString(i, 2)
            d.location = rs.getString(i, 3)
            d.sort = rs.getInt(i, 4)
            d.enabled = rs.getInt(i, 5) != 0
            d.createdAt = rs.getInt(i, 6)
            out.add(d)
            i = i + 1
        }
        return out.toArray()
    }

    /* 与 listAll 同一套过滤条件下的总数。要单独 COUNT 是因为客户端要显示"共 N 条 / 第 M 页"，
     * 靠多查一页只能得到"还有更多"，翻到最后一页还得再试一次。过滤条件必须与 listAll 逐字对应，
     * 否则会出现"total=3 但翻不到 3 条"这类分页 bug（base-check 的断言会比较两者）。 */
    public func countAll(includeDisabled!: Bool = true): Int64 {
        var sql = "SELECT COUNT(*) FROM department"
        if (!includeDisabled) {
            sql = sql + " WHERE enabled = 1"
        }
        let rs = db.query(sql, Array<DbValue>())
        if (rs.rowCount() == 0) {
            return 0
        }
        return rs.getInt(0, 0)
    }

    public func findById(id: Int64): ?Department {
        let rs = db.query("SELECT id, name, code, location, sort, enabled, created_at " +
                          "FROM department WHERE id = ?", [DbInt(id)])
        if (rs.rowCount() == 0) {
            return None
        }
        let d = Department()
        d.id = rs.getInt(0, 0)
        d.name = rs.getString(0, 1)
        d.code = rs.getString(0, 2)
        d.location = rs.getString(0, 3)
        d.sort = rs.getInt(0, 4)
        d.enabled = rs.getInt(0, 5) != 0
        d.createdAt = rs.getInt(0, 6)
        return d
    }

    /* 建科室。校验放在仓储里而不是只放 HTTP 层：测试与将来的 CLI 也走同一套语义。
     * 返回 duplicate / invalid 由调用方映射为 409 / 400。 */
    public func create(d: Department, now: Int64): BaseWriteOutcome {
        let out = BaseWriteOutcome()
        let nameErr = baseValidateName(d.name, "科室名")
        if (nameErr.size > 0) {
            return out.markInvalid(nameErr)
        }
        let codeErr = baseValidateCode(d.code, "科室编码")
        if (codeErr.size > 0) {
            return out.markInvalid(codeErr)
        }
        if (d.location.size > BASE_LOCATION_MAX) {
            return out.markInvalid("科室位置最长 ${BASE_LOCATION_MAX} 字")
        }
        /* 直接 INSERT，不先查：先查后插在并发下两个都会通过检查，靠唯一键兜底并转成 duplicate。
         * 先查后插的另一个问题是"报重复时异常已经抛出"。 */
        let ins = baseExecTolerant(db,
            "INSERT INTO department (name, code, location, sort, enabled, created_at) " +
            "VALUES (?, ?, ?, ?, ?, ?)",
            [DbStr(d.name), DbStr(d.code), DbStr(d.location), DbInt(d.sort),
             DbInt(if (d.enabled) { 1 } else { 0 }), DbInt(now)], returnInsertId: true)
        if (!ins.ok) {
            return baseClassifyDuplicate(ins.message, out)
        }
        return out.markOk(ins.generatedId)
    }

    /* 改科室。不动 created_at（改它等于篡改历史）。重名 ⇒ duplicate ⇒ 409。 */
    public func update(id: Int64, d: Department): BaseWriteOutcome {
        let out = BaseWriteOutcome()
        match (findById(id)) {
            case None => out.notFound = true; return out
            case Some(_) => ()
        }
        let nameErr = baseValidateName(d.name, "科室名")
        if (nameErr.size > 0) {
            return out.markInvalid(nameErr)
        }
        let codeErr = baseValidateCode(d.code, "科室编码")
        if (codeErr.size > 0) {
            return out.markInvalid(codeErr)
        }
        if (d.location.size > BASE_LOCATION_MAX) {
            return out.markInvalid("科室位置最长 ${BASE_LOCATION_MAX} 字")
        }
        let up = baseExecTolerant(db,
            "UPDATE department SET name = ?, code = ?, location = ?, sort = ?, enabled = ? " +
            "WHERE id = ?",
            [DbStr(d.name), DbStr(d.code), DbStr(d.location), DbInt(d.sort),
             DbInt(if (d.enabled) { 1 } else { 0 }), DbInt(id)])
        if (!up.ok) {
            return baseClassifyDuplicate(up.message, out)
        }
        return out.markOk(id)
    }

    /* 删科室（默认只删未被引用的；force=true 时软删）。引用检查按排班 > 医生 > 挂号单的顺序，
     * 从最硬的证据开始；只要命中一条就拒，并如实回报是哪一类，使用者才知道下一步做什么。 */
    public func remove(id: Int64, force: Bool): BaseWriteOutcome {
        let out = BaseWriteOutcome()
        match (findById(id)) {
            case None => out.notFound = true; return out
            case Some(_) => ()
        }
        let docs = baseCount(db, "SELECT COUNT(*) FROM doctor WHERE department_id = ?", id)
        let scheds = baseCount(db, "SELECT COUNT(*) FROM schedule WHERE department_id = ?", id)
        if (!force) {
            if (scheds > 0) {
                return out.markInUse("该科室下还有 ${scheds} 条排班")
            }
            if (docs > 0) {
                return out.markInUse("该科室下还有 ${docs} 位医生")
            }
            let appts = baseCount(db, "SELECT COUNT(*) FROM appointment WHERE department_id = ?", id)
            if (appts > 0) {
                return out.markInUse("该科室下还有 ${appts} 张挂号单")
            }
            db.exec("DELETE FROM department WHERE id = ?", [DbInt(id)])
            return out.markOk(id)
        }
        /* 软删：enabled = 0，行保留，历史数据仍能解析出科室名。同时软删本科室下的医生 ——
         * 否则会出现"科室已停用、医生仍可被排班"。 */
        db.exec("UPDATE department SET enabled = 0 WHERE id = ?", [DbInt(id)])
        db.exec("UPDATE doctor SET enabled = 0 WHERE department_id = ?", [DbInt(id)])
        return out.markOk(id)
    }
}

/* ===================== 医生 ===================== */

/* 医生（`doctor` 表的一行）。 */
public class Doctor {
    public var id: Int64 = 0
    public var name: String = ""
    public var departmentId: Int64 = 0
    public var title: String = ""
    public var specialty: String = ""
    public var enabled: Bool = true
    public var createdAt: Int64 = 0
}

/*
 * 医生仓储。医生必须属于一个存在的科室，但本仓没有外键（doctor.department_id 只是普通索引），
 * 所以这条约束只能由应用层在插入前守住，否则会产生指向不存在科室的孤儿医生。
 * 不用外键的原因：迁移是幂等加列/加表式，加外键要重建表。
 */
public class DoctorRepo {
    private let db: DbBackend

    public init(db: DbBackend) {
        this.db = db
    }

    public func listAll(departmentId: Int64, includeDisabled!: Bool = true,
                        limit!: Int64 = 0, offset!: Int64 = 0): Array<Doctor> {
        var sql = "SELECT id, name, department_id, title, specialty, enabled, created_at FROM doctor"
        /* 参数用 ArrayList<DbValue>：Array<T> 没有 add（编译报 'add' is not a member），
         * 动态攒参数必须 ArrayList，最后 toArray()。 */
        let args = ArrayList<DbValue>()
        if (departmentId > 0) {
            sql = sql + " WHERE department_id = ?"
            args.add(DbInt(departmentId))
        }
        if (!includeDisabled) {
            if (departmentId > 0) {
                sql = sql + " AND enabled = 1"
            } else {
                sql = sql + " WHERE enabled = 1"
            }
        }
        sql = sql + " ORDER BY id ASC"
        /* 分页口径同 DepartmentRepo.listAll：limit <= 0 不分页，offset 仅分页时拼，负数夹到 0。 */
        if (limit > 0) {
            var off = offset
            if (off < 0) {
                off = 0
            }
            sql = sql + " LIMIT ? OFFSET ?"
            args.add(DbInt(limit))
            args.add(DbInt(off))
        }
        let rs = db.query(sql, args.toArray())
        let out = ArrayList<Doctor>()
        var i: Int64 = 0
        while (i < rs.rowCount()) {
            let d = Doctor()
            d.id = rs.getInt(i, 0)
            d.name = rs.getString(i, 1)
            d.departmentId = rs.getInt(i, 2)
            d.title = rs.getString(i, 3)
            d.specialty = rs.getString(i, 4)
            d.enabled = rs.getInt(i, 5) != 0
            d.createdAt = rs.getInt(i, 6)
            out.add(d)
            i = i + 1
        }
        return out.toArray()
    }

    /* 与 listAll 同一套过滤（department_id + enabled）下的总数。
     * 两处条件必须逐字对应，否则出现"total 与实际可翻页数不符"。 */
    public func countAll(departmentId: Int64, includeDisabled!: Bool = true): Int64 {
        var sql = "SELECT COUNT(*) FROM doctor"
        let args = ArrayList<DbValue>()
        if (departmentId > 0) {
            sql = sql + " WHERE department_id = ?"
            args.add(DbInt(departmentId))
        }
        if (!includeDisabled) {
            if (departmentId > 0) {
                sql = sql + " AND enabled = 1"
            } else {
                sql = sql + " WHERE enabled = 1"
            }
        }
        let rs = db.query(sql, args.toArray())
        if (rs.rowCount() == 0) {
            return 0
        }
        return rs.getInt(0, 0)
    }

    public func findById(id: Int64): ?Doctor {
        let rs = db.query("SELECT id, name, department_id, title, specialty, enabled, created_at " +
                          "FROM doctor WHERE id = ?", [DbInt(id)])
        if (rs.rowCount() == 0) {
            return None
        }
        let d = Doctor()
        d.id = rs.getInt(0, 0)
        d.name = rs.getString(0, 1)
        d.departmentId = rs.getInt(0, 2)
        d.title = rs.getString(0, 3)
        d.specialty = rs.getString(0, 4)
        d.enabled = rs.getInt(0, 5) != 0
        d.createdAt = rs.getInt(0, 6)
        return d
    }

    public func create(d: Doctor, now: Int64): BaseWriteOutcome {
        let out = BaseWriteOutcome()
        let nameErr = baseValidateName(d.name, "医生姓名")
        if (nameErr.size > 0) {
            return out.markInvalid(nameErr)
        }
        let depErr = baseRequireDepartment(db, d.departmentId)
        if (depErr.size > 0) {
            return out.markInvalid(depErr)
        }
        if (d.title.size > BASE_TITLE_MAX) {
            return out.markInvalid("职称最长 ${BASE_TITLE_MAX} 字")
        }
        if (d.specialty.size > BASE_SPECIALTY_MAX) {
            return out.markInvalid("擅长最长 ${BASE_SPECIALTY_MAX} 字")
        }
        let id = db.execInsert("INSERT INTO doctor (name, department_id, title, specialty, enabled, created_at) " +
                "VALUES (?, ?, ?, ?, ?, ?)",
                [DbStr(d.name), DbInt(d.departmentId), DbStr(d.title), DbStr(d.specialty),
                 DbInt(if (d.enabled) { 1 } else { 0 }), DbInt(now)])
        return out.markOk(id)
    }

    public func update(id: Int64, d: Doctor): BaseWriteOutcome {
        let out = BaseWriteOutcome()
        match (findById(id)) {
            case None => out.notFound = true; return out
            case Some(_) => ()
        }
        let nameErr = baseValidateName(d.name, "医生姓名")
        if (nameErr.size > 0) {
            return out.markInvalid(nameErr)
        }
        let depErr = baseRequireDepartment(db, d.departmentId)
        if (depErr.size > 0) {
            return out.markInvalid(depErr)
        }
        if (d.title.size > BASE_TITLE_MAX) {
            return out.markInvalid("职称最长 ${BASE_TITLE_MAX} 字")
        }
        if (d.specialty.size > BASE_SPECIALTY_MAX) {
            return out.markInvalid("擅长最长 ${BASE_SPECIALTY_MAX} 字")
        }
        db.exec("UPDATE doctor SET name = ?, department_id = ?, title = ?, specialty = ?, " +
                "enabled = ? WHERE id = ?",
                [DbStr(d.name), DbInt(d.departmentId), DbStr(d.title), DbStr(d.specialty),
                 DbInt(if (d.enabled) { 1 } else { 0 }), DbInt(id)])
        return out.markOk(id)
    }

    /* 删医生。medical_record.doctor_id 这条引用最要紧：病历是临床留档，作者必须一直可解析，
     * 允许删会让历史病历指向不存在的作者，事后无法用代码修。 */
    public func remove(id: Int64, force: Bool): BaseWriteOutcome {
        let out = BaseWriteOutcome()
        match (findById(id)) {
            case None => out.notFound = true; return out
            case Some(_) => ()
        }
        let appts = baseCount(db, "SELECT COUNT(*) FROM appointment WHERE doctor_id = ?", id)
        let recs = baseCount(db, "SELECT COUNT(*) FROM medical_record WHERE doctor_id = ?", id)
        if (!force) {
            if (recs > 0) {
                return out.markInUse("该医生名下还有 ${recs} 份病历（临床留档，作者必须可解析）")
            }
            if (appts > 0) {
                return out.markInUse("该医生名下还有 ${appts} 张挂号单")
            }
            let scheds = baseCount(db, "SELECT COUNT(*) FROM schedule WHERE doctor_id = ?", id)
            if (scheds > 0) {
                return out.markInUse("该医生名下还有 ${scheds} 条排班")
            }
            db.exec("DELETE FROM doctor WHERE id = ?", [DbInt(id)])
            return out.markOk(id)
        }
        /* 软删，行保留 ⇒ 历史挂号单/病历仍能解析出医生名。同时停掉该医生名下未来的排班（enabled = 0），
         * 但不动已有挂号单 —— 已挂患者不该因医生离职被取消。 */
        db.exec("UPDATE doctor SET enabled = 0 WHERE id = ?", [DbInt(id)])
        db.exec("UPDATE schedule SET enabled = 0 WHERE doctor_id = ?", [DbInt(id)])
        return out.markOk(id)
    }
}

/* ===================== 共用校验与容错 ===================== */

/* 医生所属科室必须存在且**启用**。返回空串表示通过。 */
public func baseRequireDepartment(db: DbBackend, departmentId: Int64): String {
    if (departmentId <= 0) {
        return "必须指定所属科室"
    }
    let rs = db.query("SELECT enabled FROM department WHERE id = ?", [DbInt(departmentId)])
    if (rs.rowCount() == 0) {
        return "科室不存在（department_id = ${departmentId}）"
    }
    if (rs.getInt(0, 0) == 0) {
        return "该科室已停用，不能再挂医生"
    }
    return ""
}

public func baseCount(db: DbBackend, sql: String, arg: Int64): Int64 {
    let rs = db.query(sql, [DbInt(arg)])
    if (rs.rowCount() == 0) {
        return 0
    }
    return rs.getInt(0, 0)
}

/* 只把已确认的唯一键冲突转成返回值；其他数据库故障保留原异常。 */
public class BaseExecResult {
    public var ok: Bool = false
    public var message: String = ""
    public var generatedId: Int64 = 0
}

/* MariaDB 1062 是唯一键冲突。驱动只保留报错文本时，只接受明确的 Duplicate entry 前缀，
 * 不凭索引名、空消息或未知故障猜测；拿不到这些证据就让原异常上抛（不改变驱动接口）。 */
public func baseDuplicateMessage(e: Exception): ?String {
    if (e.message.startsWith("Duplicate entry ")) {
        return Some(e.message)
    }
    match (e) {
        case sql: SqlException =>
            if (sql.errorCode == 1062) {
                return Some("Duplicate entry (errorCode=1062): ${e.message}")
            }
        case _ => ()
    }
    return None
}

/* INSERT、ID 读取及资源清理故障均不得转成参数错误。 */
public func baseExecTolerant(db: DbBackend, sql: String, args: Array<DbValue>,
                            returnInsertId!: Bool = false): BaseExecResult {
    let r = BaseExecResult()
    try {
        if (returnInsertId) {
            r.generatedId = db.execInsert(sql, args)
        } else {
            db.exec(sql, args)
        }
        r.ok = true
    } catch (e: Exception) {
        match (baseDuplicateMessage(e)) {
            case Some(message) => r.message = message
            case None => throw e
        }
    }
    return r
}

/* 把唯一键冲突分类成"哪个字段重复"：先确认冲突，再用错误消息里的索引名定位字段。
 * 认不出的索引名落到通用文案，不猜字段。 */
public func baseClassifyDuplicate(message: String, out: BaseWriteOutcome): BaseWriteOutcome {
    if (!message.startsWith("Duplicate entry ")) {
        throw Exception(message)
    }
    if (message.contains("uk_department_name")) {
        return out.markDuplicate("name")
    }
    if (message.contains("uk_department_code")) {
        return out.markDuplicate("code")
    }
    /* 公告域共用同一分类器。加一张带唯一键的表，就要回来认它的索引名 —— 否则只会落到通用文案，
     * 而这个字段存在的意义正是说清哪个字段冲突。 */
    if (message.contains("uk_notice_title")) {
        return out.markDuplicate("title")
    }
    /* 已确认冲突但索引名不认识，保留通用的重复文案。 */
    return out.markDuplicate("")
}
