package qingzhou

/*
 * ⚠ `ArrayList` 来自 std.collection —— 本仓踩过"漏 import 报 undeclared identifier"
 *   （见 domain_booking.cj 的同类注释），所以这里显式写上。
 */
import std.collection.*
import std.database.sql.*

/*
 * SPDX-License-Identifier: MIT
 *
 * ===== domain_base.cj —— 基础数据域（科室 / 医生）=================
 *
 * ## 为什么会有这个文件（ADR-0001 rev.7 的直接后果）
 *
 * rev.7 拆掉内存 Store 时，我给 `department`/`doctor`/`patient` 定了新归属
 * **「基础数据域」**，并如实记下一条边界：
 *
 *   ⚠ **它们没有写入端点** —— 靠人工 SQL 维护。
 *
 * 本文件就是来还这笔账的：给科室与医生补上**管理端 CRUD**。
 * 不补的话，"分诊推荐科室"这件事在生产上根本跑不起来 ——
 * 因为 `triage.cj` 查的就是 `department` 表，而没人能往里加数据。
 *
 * ## 本文件**只做科室与医生**，刻意不含患者
 *
 * `patient` 表存的是**敏感个人信息**（`docs/`brief §9 R-4：真实落地需个保法合规、
 * 实名、留存策略）。给患者开管理端 CRUD 是**合规决策**，不是工程便利 ——
 * 所以它**不在本次范围**，也**没有**顺手加进来。已写进 P4-HANDOFF 未做清单。
 *
 * ## 两条刻意的设计
 *
 * ① **`department.name` 必须唯一**（补 `uk_department_name`）。
 *    ⚠ 理由不是"看起来该唯一"，而是**有一个真调用方按名字查**：
 *      `triage.cj` 用 `SELECT ... FROM department WHERE name = ?` 判断"该科室是否可挂号"。
 *      同名会让这条判断**分裂**（命中哪一行取决于存储顺序）——
 *      而它恰好是"分诊推荐"与"排班列表"两处口径的连接点。
 *    ⇒ 纪律要能被**数据库**兜底，而不是只靠应用层先查后写。
 *
 * ② **删除有两种语义，且必须由调用方明确选**（`?force=`）：
 *      · 默认（force=false）：**只允许删未被引用的**科室/医生。有引用 ⇒ `inUse`，
 *        回 409 并**说清是谁在用**。理由：真实系统里"删掉一个还有排班的医生"
 *        会让历史数据失去归属，而这类错误**事后无法用代码修**。
 *      · `force=true`：**软删**（`enabled = 0`），行保留。
 *    ⚠ **不存在硬删**。这是刻意的：`appointment`/`schedule`/`medical_record`
 *      都可能引用它，硬删要么失败要么破坏历史。所以"删"在数据层就是软删。
 */

/* ===================== 科室 ===================== */

/* 科室（`department` 表的一行）。 */
/*
 * ⚠⚠ 常量与校验**必须定义在使用之前** —— 仓颉**没有 hoisting**。
 *   我第一版把它们放在文件末尾，实测报
 *     variable 'BASE_LOCATION_MAX' is used before being defined
 *   项目笔记里早就记过这条（"declare before use"），仍踩了一次，
 *   所以这里放在最前面并把原因写死。
 */
public let BASE_NAME_MAX: Int64 = 64
public let BASE_CODE_MAX: Int64 = 32
public let BASE_LOCATION_MAX: Int64 = 128
public let BASE_TITLE_MAX: Int64 = 32
public let BASE_SPECIALTY_MAX: Int64 = 255

/*
 * ⚠ 长度一律按**字符**数算，不按字节 —— 本仓踩过三次"字节/字符混用"的坑
 *   （见 server/README.md 踩坑表）。中文姓名 3 字 = 9 字节，
 *   若按字节判 64 就只剩 21 个汉字可用，而列是 VARCHAR(64)（64 字符）。
 */
public func baseValidateName(v: String, what: String): String {
    let t = v.trimAscii()
    if (t.size == 0) {
        return "${what}不能为空"
    }
    if (previsitCharLen(t) > BASE_NAME_MAX) {
        return "${what}最长 ${BASE_NAME_MAX} 字"
    }
    /*
     * ⚠ 拒绝控制字符（含换行/制表）：它们会破坏 JSON 输出与日志的单行假设，
     *   而且没有一个合法用途。**明确拒绝比"存进去再想办法显示"好**。
     */
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
    /*
     * 编码是给程序看的稳定标识（分诊/统计按它对齐），
     * ⇒ 限定 `[A-Za-z0-9_-]`：不允许空格与中文，避免"看起来像名字"的编码。
     */
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
 * 科室仓储。
 *
 * ⚠ 与号源域不同，科室**没有并发热点**（不是每秒被抢的资源），
 *   所以这里**不用**条件 UPDATE 那套。唯一键由数据库兜底，
 *   应用层**不做**"先查再插"（那是 TOCTOU：查完到插入之间别人可能先插进去）。
 *   做法：直接 INSERT，靠**捕获唯一键冲突**来判定重复。
 */
public class DepartmentRepo {
    private let db: DbBackend

    public init(db: DbBackend) {
        this.db = db
    }

    public func listAll(includeDisabled!: Bool = true): Array<Department> {
        var sql = "SELECT id, name, code, location, sort, enabled, created_at FROM department"
        if (!includeDisabled) {
            sql = sql + " WHERE enabled = 1"
        }
        sql = sql + " ORDER BY sort ASC, id ASC"
        let rs = db.query(sql, Array<DbValue>())
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

    /*
     * 建科室。
     *
     * ⚠ 校验放在仓储里而不是只放 HTTP 层：这样**数据层的调用方**（测试、将来的 CLI）
     *   也走同一套校验 —— 同一语义只留一处实现。
     */
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
        /*
         * ⚠ 直接 INSERT，**不先查**：先查后插在并发下会两个都通过检查、
         *   然后一个撞唯一键 —— 那时再报"重复"就晚了（已经抛异常）。
         *   靠数据库的唯一键兜底，并由下面捕获冲突转成 `duplicate`。
         */
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

    /* 改科室。⚠ **不动 `created_at`**（它是"什么时候建的"，改它等于篡改历史）。 */
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

    /*
     * 删科室（见文件头：默认只删未被引用的；`force=true` 时软删）。
     *
     * ⚠ 引用检查的顺序**刻意从"最硬的证据"开始**：排班 > 医生 > 挂号单。
     *   只要有一条就拒，且**如实回报是哪一类**（使用者据此知道下一步做什么）。
     */
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
        /*
         * force：**软删**（`enabled = 0`）。行保留 ⇒ 历史数据仍能解析出科室名。
         * ⚠ 同时把该科室下的医生也软删 —— 否则会出现"科室已停用、医生仍可被排班"
         *   这种自相矛盾的状态（排班接口按 enabled 筛，医生不筛就漏了）。
         */
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
 * 医生仓储。
 *
 * ⚠ 医生与科室的关键差别：医生**必须属于一个存在的科室**。
 *   本仓**没有外键**（`doctor.department_id` 只是普通索引）⇒ 这条约束
 *   必须由应用层守，且要**在插入前**查（否则会产生指向不存在科室的孤儿医生）。
 *   📌 为什么不用外键：本项目的迁移是"幂等加列/加表"式，
 *     加外键需要重建表（在已有数据上风险高）。所以这里**明确**用应用层校验 +
 *     一条验收断言兜住"不会产生孤儿医生"。
 */
public class DoctorRepo {
    private let db: DbBackend

    public init(db: DbBackend) {
        this.db = db
    }

    public func listAll(departmentId: Int64, includeDisabled!: Bool = true): Array<Doctor> {
        var sql = "SELECT id, name, department_id, title, specialty, enabled, created_at FROM doctor"
        /*
         * ⚠ 参数用 `ArrayList<DbValue>` 而不是 `Array<DbValue>()`：
         *   仓颉的 `Array<T>` **没有 `add`**（实测报 `'add' is not a member of
         *   struct 'Array<...>'`），要动态攒参数必须用 ArrayList，最后 `toArray()`。
         *   📌 本仓 domain_booking.cj 里已有一模一样的注释 —— 我又踩了一次，
         *     所以这次把话写死在这里。
         */
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

    /*
     * 删医生。
     *
     * ⚠ 引用检查里的 **`medical_record.doctor_id`** 是最要紧的一条：
     *   病历是**临床留档**，它的"作者"必须一直可解析。若允许删掉有病历的医生，
     *   历史病历就会指向一个不存在的作者 —— 这类损坏**事后无法用代码修**。
     */
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
        /*
         * force：**软删**。行保留 ⇒ 历史挂号单/病历仍能解析出医生名。
         * ⚠ 同时**停掉该医生名下未来的排班**（`enabled = 0`），
         *   否则"医生已停用、排班仍可挂"是自相矛盾的状态。
         *   📌 注意这里只停**排班**，**不动**已有挂号单 ——
         *     已挂患者不该因为医生离职而被取消（那要人工通知，不是数据层的事）。
         */
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

/* MariaDB 1062 是唯一键冲突。现有驱动可能只保留报错文本，
 * 此时只接受明确的 Duplicate entry 前缀，不凭索引名、空消息或未知故障猜测。
 * 不改变驱动接口或预编译产物；没有这些证据时让原异常上抛。
 */
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

/*
 * 把唯一键冲突分类成"哪个字段重复"。
 *
 * 先确认唯一键冲突，再用错误消息里的索引名定位字段。
 */
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
    /*
     * 公告域（2026-10-12 新增）用的是同一个分类器 —— 不认它的索引名会落到下面的
     * 兜底分支（`markDuplicate("")`），表现为"HTTP 层只能给通用文案"，
     * 而这个字段存在的意义正是"**说清是哪个字段冲突**，便于使用者自己修"。
     * ⚠ 教训：**加一张带唯一键的表，就要回来认它的索引名** ——
     *   唯一键是各自定义的，分类器却是共用的一处。
     */
    if (message.contains("uk_notice_title")) {
        return out.markDuplicate("title")
    }
    /* 已确认冲突但索引名不认识，保留通用的重复文案。 */
    return out.markDuplicate("")
}
