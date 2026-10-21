/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 *
 * domain_emr.cj —— 电子病历域 + 接诊队列（直接 SQL，不经内存 Store）。
 *
 * 对外：MedicalRecordRepo（findByAppointment、listForPatient、saveDraft、lock、reopen、revisions、
 *   intakePrefill、backfillRevisions）、emrSections / emrRequiredKeys、visitTransitionAllowed、
 *   VisitRepo（queueForDoctor、transition、arrive、waiting、start、finish）、emrHasLockedRecord。
 * 约束：病历挂挂号单（uk_record_appointment 一份）；patient_id/doctor_id 从 appointment 派生，禁止客户端传入。
 */

package qingzhou

import std.collection.*
import stdx.encoding.json.*

/* ===================== 病历表与七段式 ===================== */

/* 病历状态（表名常量 TABLE_MEDICAL_RECORD 在 schema.cj）。 */
public let EMR_DRAFT: String = "draft"
public let EMR_LOCKED: String = "locked"

/* 修订操作取值（lock/reopen）：用常量，字面量拼错不会编译失败、只会让审计查询查不到。 */
public let EMR_OP_LOCK: String = "lock"
public let EMR_OP_REOPEN: String = "reopen"

/* 解锁理由长度（按字符，4–255）。必须填：解锁是推翻一份定稿医疗文书，理由要留给后来人；下限只拒不敷衍的取值，不判语义。 */
public let EMR_REASON_MIN: Int64 = 4
public let EMR_REASON_MAX: Int64 = 255

/* 解锁理由是否合法（trim 后 4–255 **字符**）。 */
public func emrReasonValid(reason: String): Bool {
    let t = reason.trimAscii()
    /* 必须用 previsitCharLen（字符数）而非 String.size（字节数）：中文理由的"太短"永远拦不住。 */
    let n = previsitCharLen(t)
    return n >= EMR_REASON_MIN && n <= EMR_REASON_MAX
}

/* 病历七段式：顺序即医生书写顺序，也是接口回显顺序（故用数组不用 Map）。 */
public class EmrSection {
    public let key: String
    public let label: String
    /* 该段的字符上限（**按字符**算，不按字节 —— 见 P2 的字节/字符教训）。 */
    public let maxLen: Int64
    /* 仅锁定的时候必填，刻意只设 diagnosis/treatment：七段全必填会逼医生乱填。单一来源 emrRequiredKeys()。 */
    public let requiredToLock: Bool

    public init(key: String, label: String, maxLen: Int64, requiredToLock!: Bool = false) {
        this.key = key
        this.label = label
        this.maxLen = maxLen
        this.requiredToLock = requiredToLock
    }
}

/* 七段式定义（**唯一来源**：DDL 的列名、接口字段名、校验都从这里派生）。 */
public func emrSections(): Array<EmrSection> {
    return [
        EmrSection("chief_complaint", "主诉", 2000),
        EmrSection("present_illness", "现病史", 4000),
        EmrSection("past_history", "既往史", 2000),
        EmrSection("allergy_history", "过敏史", 2000),
        EmrSection("physical_exam", "体格检查", 2000),
        EmrSection("diagnosis", "诊断", 2000, requiredToLock: true),
        EmrSection("treatment", "处理意见", 4000, requiredToLock: true)
    ]
}

/* 某段的契约；未知返回 None。 */
public func emrSectionOf(key: String): ?EmrSection {
    for (s in emrSections()) {
        if (s.key == key) {
            return Some(s)
        }
    }
    return None
}

/* 提交锁定时的必填段（给测试与错误信息用）。 */
public func emrRequiredKeys(): Array<String> {
    let out = ArrayList<String>()
    for (s in emrSections()) {
        if (s.requiredToLock) {
            out.add(s.key)
        }
    }
    return out.toArray()
}

/* 段长度 SQL 表达式（生成）：用 CHAR_LENGTH（字符）而非 LENGTH（字节），与本仓长度口径一致；
 * 列名全部来自 emrSections() 常量，不含外部输入。 */
func emrContentLenSql(): String {
    var s = "("
    var first = true
    for (sec in emrSections()) {
        if (!first) {
            s = s + " + "
        }
        s = s + "IFNULL(CHAR_LENGTH(" + sec.key + "), 0)"
        first = false
    }
    return s + ")"
}

/* "病历正文全为空"（= 医生还没动笔）。 */
func emrEmptySql(): String {
    return emrContentLenSql() + " = 0"
}

/* "病历正文非空"。 */
func emrNonEmptySql(): String {
    return emrContentLenSql() + " > 0"
}

/* 取某段正文（未知 key 返回空串）。 */
public func emrAnswerOf(form: PrevisitForm, key: String): String {
    match (form.answers.get(key)) {
        case Some(v) => return v
        case None => return ""
    }
}

/* 取 intakeSlots() 第 i 个槽位的 key：不在本文件写 "chief"/"duration" 字面量（那是第二份定义），
 * emrAssertIntakeSlotCount() 在测试里把"必须是 6 个"钉住。 */
public func intakeSlotKeyAt(i: Int64): String {
    let slots = intakeSlots()
    if (i >= 0 && i < slots.size) {
        return slots[i].key
    }
    return ""
}

/* 拼「标签：值」片段，空值跳过；分隔符口径只此一处。 */
public func emrJoinParts(parts: Array<(String, String)>): String {
    var s = ""
    for ((label, v) in parts) {
        if (v.size == 0) {
            continue
        }
        if (s.size > 0) {
            s = s + "；"
        }
        s = s + label + "：" + v
    }
    return s
}

/* previsit_ref JSON：{"session_id","sections","at"(epoch 秒)}，空串 = 无预填来源。用 JsonObject 拼，禁止手拼。
 * sections 只记建单那一刻的初值来源，之后永不更新；展示必须照此措辞（如"预填于 14:03"），
 * 说成"本段为患者自述"即失实 —— 病历是法律文书。 */
public func emrPrevisitRefJson(sessionId: String, sections: Array<String>, at: Int64): String {
    let o = JsonObject()
    o.put("session_id", JsonString(sessionId))
    let arr = ArrayList<JsonValue>()
    for (k in sections) {
        arr.add(JsonString(k))
    }
    o.put("sections", JsonArray(arr.toArray()))
    o.put("at", JsonInt(at))
    return o.toString()
}

/* 解析 previsit_ref → 来自患者自述的段；坏 JSON 不抛，回落空数组（只读操作不该 500）。 */
public func emrPrevisitRefSections(ref: String): Array<String> {
    let out = ArrayList<String>()
    if (ref.size == 0) {
        return out.toArray()
    }
    try {
        let o = JsonValue.fromStr(ref).asObject()
        match (o.get("sections")) {
            case Some(v) =>
                if (v is JsonArray) {
                    /* JsonArray 未实现 Iterator，必须按下标遍历（for-in 会编译报错）。 */
                    let arr = v.asArray()
                    var i: Int64 = 0
                    while (i < arr.size()) {
                        let x = arr[i]
                        /* 只接受字符串（别的类型是脏数据，不猜、不强制转换） */
                        if (x is JsonString) {
                            out.add(x.asString().getValue())
                        }
                        i = i + 1
                    }
                }
            case None => ()
        }
    } catch (e: Exception) {
        return ArrayList<String>().toArray()
    }
    return out.toArray()
}

public class MedicalRecord {
    public var id: Int64 = 0
    public var appointmentId: Int64 = 0
    public var patientId: Int64 = 0
    public var doctorId: Int64 = 0
    /* 七段正文（与 emrSections() 的 key 一一对应）。 */
    public var chiefComplaint: String = ""
    public var presentIllness: String = ""
    public var pastHistory: String = ""
    public var allergyHistory: String = ""
    public var physicalExam: String = ""
    public var diagnosis: String = ""
    public var treatment: String = ""
    /* draft / locked */
    public var status: String = EMR_DRAFT
    /* 最后修改人（账号 id）。⚠ 用于审计：锁定后只有管理员 reopen 能改，那时也记新的人。 */
    public var updatedBy: Int64 = 0
    /* 预问诊来源痕迹，空串 = 没有；只在建单时写入、之后不改，否则 sections 会声称医生改过的段仍是患者写的。 */
    public var previsitRef: String = ""
    public var createdAt: Int64 = 0
    public var updatedAt: Int64 = 0

    public init() {}

    public func isLocked(): Bool {
        return status == EMR_LOCKED
    }

    /* 取某段正文（未知 key 返回空串）。 */
    public func get(key: String): String {
        if (key == "chief_complaint") { return chiefComplaint }
        if (key == "present_illness") { return presentIllness }
        if (key == "past_history") { return pastHistory }
        if (key == "allergy_history") { return allergyHistory }
        if (key == "physical_exam") { return physicalExam }
        if (key == "diagnosis") { return diagnosis }
        if (key == "treatment") { return treatment }
        return ""
    }

    /* 设置某段正文（未知 key 返回 false，调用方据此报 400）。 */
    public func set(key: String, value: String): Bool {
        if (key == "chief_complaint") { chiefComplaint = value; return true }
        if (key == "present_illness") { presentIllness = value; return true }
        if (key == "past_history") { pastHistory = value; return true }
        if (key == "allergy_history") { allergyHistory = value; return true }
        if (key == "physical_exam") { physicalExam = value; return true }
        if (key == "diagnosis") { diagnosis = value; return true }
        if (key == "treatment") { treatment = value; return true }
        return false
    }

    /* 已填段数（非空算填了）。 */
    public func filledCount(): Int64 {
        var n: Int64 = 0
        for (s in emrSections()) {
            if (get(s.key).trimAscii().size > 0) {
                n = n + 1
            }
        }
        return n
    }

    /* 是否七段全填。 */
    public func complete(): Bool {
        return filledCount() == emrSections().size
    }

    /* 提交锁定所缺的必填段（空 = 可以锁定）。 */
    public func missingRequired(): Array<String> {
        let out = ArrayList<String>()
        for (s in emrSections()) {
            if (s.requiredToLock && get(s.key).trimAscii().size == 0) {
                out.add(s.label)
            }
        }
        return out.toArray()
    }
}

/* 七段正文 → JSON 快照，含空段：diff 要能区分"这一段被删空了"与"这一版没有这一段"。
 * 段正文是医生输入的任意文本，用 JsonObject 拼，禁止手工拼串（必踩转义）。 */
public func emrSectionsJson(rec: MedicalRecord): String {
    let o = JsonObject()
    for (s in emrSections()) {
        o.put(s.key, JsonString(rec.get(s.key)))
    }
    return o.toString()
}

/* JSON → 段值表；坏数据不抛（同 emrPrevisitRefSections），只取 emrSections() 已知的段，未知键忽略。 */
public func emrSectionValues(json: String): HashMap<String, String> {
    let out = HashMap<String, String>()
    if (json.size == 0) {
        return out
    }
    try {
        let o = JsonValue.fromStr(json).asObject()
        for (s in emrSections()) {
            match (o.get(s.key)) {
                case Some(v) =>
                    if (v is JsonString) {
                        out[s.key] = v.asString().getValue()
                    }
                case None => ()
            }
        }
    } catch (e: Exception) {
        return HashMap<String, String>()
    }
    return out
}

/* 取段值（缺键 ⇒ 空串）。 */
func emrValueOfForm(m: HashMap<String, String>, k: String): String {
    match (m.get(k)) {
        case Some(v) => return v
        case None => return ""
    }
}

/* 修订记录：不可变历史行，只有读方法；要改历史只能再落一行新版本。 */
public class MedicalRecordRevision {
    public var id: Int64 = 0
    public var recordId: Int64 = 0
    public var appointmentId: Int64 = 0
    public var version: Int64 = 0
    public var status: String = ""
    public var sectionsJson: String = ""
    public var operation: String = ""
    public var reason: String = ""
    public var operatorUserId: Int64 = 0
    public var operatorRole: String = ""
    public var createdAt: Int64 = 0

    public init() {}

    /* 该版本的段值表（解析 sections_json，坏数据 ⇒ 空表）。 */
    public func values(): HashMap<String, String> {
        return emrSectionValues(sectionsJson)
    }

    /* 该版本已填段数（列表里给"v2 · 5/7 段"用）。 */
    public func filledCount(): Int64 {
        let m = values()
        var n: Int64 = 0
        for (s in emrSections()) {
            if (emrValueOfForm(m, s.key).trimAscii().size > 0) {
                n = n + 1
            }
        }
        return n
    }
}

/* 逐段差异行：七段全给（未变 changed=false），不只回变化段 —— 否则客户端要自排段序、自补未变段。 */
public class EmrDiffRow {
    public let key: String
    public let label: String
    public let before: String
    public let after: String
    public let changed: Bool

    public init(key: String, label: String, before: String, after: String) {
        this.key = key
        this.label = label
        this.before = before
        this.after = after
        this.changed = before != after
    }
}

/* 逐段对比两个版本的段值表（顺序 = `emrSections()` 的临床顺序）。 */
public func emrDiffRows(before: HashMap<String, String>,
                        after: HashMap<String, String>): Array<EmrDiffRow> {
    let out = ArrayList<EmrDiffRow>()
    for (s in emrSections()) {
        out.add(EmrDiffRow(s.key, s.label,
                           emrValueOfForm(before, s.key), emrValueOfForm(after, s.key)))
    }
    return out.toArray()
}

/* 写结果用显式字段而非一个错误码：403/409/400 要给不同状态码，混成字符串会退化成 500 或一律 400。 */
public class EmrWriteOutcome {
    public var ok: Bool = false
    /* 该预约不存在（或不属于该医生）。 */
    public var noSuchAppointment: Bool = false
    /* 病历已锁定，草稿写入被拒。 */
    public var locked: Bool = false
    /* 读到的草稿内容已被另一请求修改；调用方保留输入并重新读取。 */
    public var conflict: Bool = false
    /* 未知的段名。 */
    public var unknownSection: Bool = false
    /* 某段超长（超出字符上限）。 */
    public var tooLong: Bool = false
    /* 缺必填段（提交时）。 */
    public var missingRequired: Bool = false
    /* 解锁理由不合法（缺理由 / 太短 / 太长）。 */
    public var badReason: Bool = false
    /* 供报错用的细节（段名/上限/缺哪几段）。 */
    public var detail: String = ""
    public var recordId: Int64 = 0
    /* 本次落下的修订版本号：0 = 没记上，让"审计写失败"不静默（响应里能看到）。
     * 业务效果（status=locked）不因审计写失败而回滚：库写不进去不该等于医生锁不了病历。 */
    public var revisionVersion: Int64 = 0
    /* conflict 时回带服务端当前 updated_at/updated_by（0 = 没读到，不是 1970）：
     * 不回带的话客户端只能整份丢弃本地输入重新拉取。 */
    public var currentUpdatedAt: Int64 = 0
    public var currentUpdatedBy: Int64 = 0
}

public class MedicalRecordRepo {
    private let db: DbBackend

    public init(db: DbBackend) {
        this.db = db
    }

    private func rowToRecord(rs: DbResultSet, row: Int64): MedicalRecord {
        let m = MedicalRecord()
        m.id = rs.getInt(row, 0)
        m.appointmentId = rs.getInt(row, 1)
        m.patientId = rs.getInt(row, 2)
        m.doctorId = rs.getInt(row, 3)
        m.chiefComplaint = rs.getString(row, 4)
        m.presentIllness = rs.getString(row, 5)
        m.pastHistory = rs.getString(row, 6)
        m.allergyHistory = rs.getString(row, 7)
        m.physicalExam = rs.getString(row, 8)
        m.diagnosis = rs.getString(row, 9)
        m.treatment = rs.getString(row, 10)
        m.status = rs.getString(row, 11)
        m.updatedBy = rs.getInt(row, 12)
        m.createdAt = rs.getInt(row, 13)
        m.updatedAt = rs.getInt(row, 14)
        /* 新列一律追加在 selectCols 末尾：列顺序只在此二处定义，插中间会静默读错段（如 diagnosis 读成 treatment）。 */
        m.previsitRef = rs.getString(row, 15)
        return m
    }

    private let selectCols: String =
        "id, appointment_id, patient_id, doctor_id, chief_complaint, present_illness, " +
        "past_history, allergy_history, physical_exam, diagnosis, treatment, status, " +
        "updated_by, created_at, updated_at, previsit_ref"

    /* 完整内容快照作为乐观版本：MySQL 排序规则不分大小写，必须 BINARY 比较；updated_at 秒级不能单独当版本。 */
    private let draftSnapshotSql: String =
        "status = ? AND BINARY chief_complaint = BINARY ? AND BINARY present_illness = BINARY ? " +
        "AND BINARY past_history = BINARY ? AND BINARY allergy_history = BINARY ? " +
        "AND BINARY physical_exam = BINARY ? AND BINARY diagnosis = BINARY ? " +
        "AND BINARY treatment = BINARY ? AND updated_by = ? AND updated_at = ?"

    private func snapshotParams(r: MedicalRecord): Array<DbValue> {
        return [DbStr(EMR_DRAFT), DbStr(r.chiefComplaint), DbStr(r.presentIllness),
                DbStr(r.pastHistory), DbStr(r.allergyHistory), DbStr(r.physicalExam),
                DbStr(r.diagnosis), DbStr(r.treatment), DbInt(r.updatedBy), DbInt(r.updatedAt)]
    }

    /* 按挂号单取病历。 */
    public func findByAppointment(appointmentId: Int64): ?MedicalRecord {
        let rs = db.query("SELECT " + selectCols + " FROM medical_record WHERE appointment_id = ?",
                          [DbInt(appointmentId)])
        if (rs.rowCount() > 0) {
            return Some(rowToRecord(rs, 0))
        }
        return None
    }

    /* 患者侧必须走这个：否则拿到别人的 appointment_id 就能读别人病历（数据泄露 + 存在性枚举 oracle）；不匹配一律当不存在。 */
    public func findByAppointmentForPatient(appointmentId: Int64, patientId: Int64): ?MedicalRecord {
        let rs = db.query("SELECT " + selectCols +
                          " FROM medical_record WHERE appointment_id = ? AND patient_id = ?",
                          [DbInt(appointmentId), DbInt(patientId)])
        if (rs.rowCount() > 0) {
            return Some(rowToRecord(rs, 0))
        }
        return None
    }

    /* 患者自己的医疗档案：patient_id 由服务端从令牌派生，不接受客户端传入。 */
    public func listForPatient(patientId: Int64, limit: Int64): Array<MedicalRecord> {
        let out = ArrayList<MedicalRecord>()
        let rs = db.query("SELECT " + selectCols +
                          " FROM medical_record WHERE patient_id = ? " +
                          "ORDER BY updated_at DESC, id DESC LIMIT ?",
                          [DbInt(patientId), DbInt(limit)])
        var i: Int64 = 0
        while (i < rs.rowCount()) {
            out.add(rowToRecord(rs, i))
            i = i + 1
        }
        return out.toArray()
    }

    /* 隐私闸门：该患者是否被这位医生看过。没有它，任何医生猜到 patient_id（自增整数）就能翻全院病历。
     * 判据放进 SQL（WHERE doctor_id = ? AND patient_id = ? LIMIT 1），返回值一律翻成 404，不给枚举信号。 */
    public func patientTreatedByDoctor(doctorId: Int64, patientId: Int64): Bool {
        if (doctorId <= 0 || patientId <= 0) {
            return false
        }
        let rs = db.query("SELECT 1 FROM appointment WHERE doctor_id = ? AND patient_id = ? LIMIT 1",
                          [DbInt(doctorId), DbInt(patientId)])
        return rs.rowCount() > 0
    }

    /* 该患者在该医生名下的已定稿病历（医生工作台"既往记录"）。
     * ① doctor_id 参与 WHERE（纵深防御；闸门另由 patientTreatedByDoctor 把）② status = 'locked'（草稿是个人工作稿，不外泄）
     * ③ excludeAppointmentId 排除本次就诊。排序用就诊时间（子查询取 appointment.visit_date/period）而非 updated_at：
     * 后者是"这一行最后被写"的时刻，改一句老病历就会把它顶到最前。不用 JOIN 因两表有同名列 id/patient_id/doctor_id。 */
    public func listLockedForDoctorPatient(doctorId: Int64, patientId: Int64,
                                           limit: Int64,
                                           excludeAppointmentId!: Int64 = 0): Array<MedicalRecord> {
        let out = ArrayList<MedicalRecord>()
        var sql = "SELECT " + selectCols +
                  " FROM medical_record WHERE doctor_id = ? AND patient_id = ? AND status = ?"
        let params = ArrayList<DbValue>()
        params.add(DbInt(doctorId))
        params.add(DbInt(patientId))
        params.add(DbStr(EMR_LOCKED))
        if (excludeAppointmentId > 0) {
            sql = sql + " AND appointment_id <> ?"
            params.add(DbInt(excludeAppointmentId))
        }
        sql = sql + " ORDER BY " +
                    "(SELECT a.visit_date FROM appointment a WHERE a.id = medical_record.appointment_id) DESC, " +
                    "(SELECT a.period FROM appointment a WHERE a.id = medical_record.appointment_id) DESC, " +
                    "id DESC LIMIT ?"
        params.add(DbInt(limit))
        let rs = db.query(sql, params.toArray())
        var i: Int64 = 0
        while (i < rs.rowCount()) {
            out.add(rowToRecord(rs, i))
            i = i + 1
        }
        return out.toArray()
    }

    /* 保存草稿（upsert，可重复）。不校验必填（草稿本就允许半成品）；已锁定一律拒绝写入（locked = true）。 */
    public func saveDraft(appointmentId: Int64, doctorId: Int64,
                          patch: HashMap<String, String>, now: Int64,
                          actorId: Int64,
                          prefill!: HashMap<String, String> = HashMap<String, String>(),
                          previsitSessionId!: String = "",
                          expectedUpdatedAt!: Int64 = 0): EmrWriteOutcome {
        let out = EmrWriteOutcome()
        // ① 校验段名与长度（**写入前**校验，不留半成品）
        for ((k, v) in patch) {
            match (emrSectionOf(k)) {
                case None =>
                    out.unknownSection = true
                    out.detail = k
                    return out
                case Some(sec) =>
                    let n = previsitCharLen(v)
                    if (n > sec.maxLen) {
                        out.tooLong = true
                        out.detail = "${sec.label}（${n} 字，上限 ${sec.maxLen}）"
                        return out
                    }
            }
        }
        // ② 取现有病历
        var rec = MedicalRecord()
        var exists = false
        match (findByAppointment(appointmentId)) {
            case Some(r) =>
                rec = r
                exists = true
            case None => ()
        }
        if (exists && rec.isLocked()) {
            out.locked = true
            return out
        }
        /* 乐观锁：客户端带 expected_updated_at 时，服务端当前版本必须是它以为的那一版，否则 409 EMR_CHANGED。
         * 不能只在 HTTP 层先读再比（TOCTOU，两人同时提交会都过）⇒ 改稿 UPDATE 里还额外带 updated_at = ?。 */
        if (exists && expectedUpdatedAt > 0 && rec.updatedAt != expectedUpdatedAt) {
            out.conflict = true
            out.currentUpdatedAt = rec.updatedAt
            out.currentUpdatedBy = rec.updatedBy
            out.recordId = rec.id
            return out
        }
        // 保存合并前的完整快照；rec 会在下方被修改。
        let before = snapshotParams(rec)
        // ③ 合并
        /* 预填只补"该段仍为空"的段（patch 为空且库里也为空），医生写过的段一字不动。
         * 判据必须看段内容：客户端保存时七段全发（未写发空串），按 patch.contains 判会一段都预填不进、反而建出空病历。
         * 且必须先套 patch 再预填，否则那串空值会把刚补的自述当场擦掉（联调时"提示已预填、输入框全空"）。 */
        let prefilled = ArrayList<String>()
        if (!exists) {
            rec.appointmentId = appointmentId
            rec.doctorId = doctorId
            rec.patientId = 0      // 由 ④ 从 appointment 补齐（**不从客户端取**）
            rec.createdAt = now
        }
        /* 先套 patch 再预填：顺序反了，空串会擦掉刚补上的自述。 */
        for ((k, v) in patch) {
            let _ = rec.set(k, v)
        }
        for ((k, v) in prefill) {
            if (rec.get(k).trimAscii().size > 0) {
                continue
            }
            match (emrSectionOf(k)) {
                case None =>
                    out.unknownSection = true
                    out.detail = k
                    return out
                case Some(sec) =>
                    let n = previsitCharLen(v)
                    if (n > sec.maxLen) {
                        out.tooLong = true
                        out.detail = "${sec.label}（${n} 字，上限 ${sec.maxLen}）"
                        return out
                    }
            }
            if (rec.set(k, v)) {
                prefilled.add(k)
            }
        }
        /* 来源痕迹只在还没有痕迹时写：它是"初值来源"快照，后补空段不该重写它。 */
        if (prefilled.size > 0 && previsitSessionId.size > 0 && rec.previsitRef.size == 0) {
            rec.previsitRef = emrPrevisitRefJson(previsitSessionId, prefilled.toArray(), now)
        }
        rec.updatedBy = actorId
        /* ★ 严格递增（见 emrNextStamp）：同一秒内两次保存也要让版本号前进。 */
        rec.updatedAt = emrNextStamp(rec.updatedAt, now)
        // ④ 落库
        if (exists) {
            let values = ArrayList<DbValue>()
            let updates: Array<DbValue> = [DbStr(rec.chiefComplaint), DbStr(rec.presentIllness), DbStr(rec.pastHistory),
                       DbStr(rec.allergyHistory), DbStr(rec.physicalExam), DbStr(rec.diagnosis),
                       DbStr(rec.treatment), DbInt(rec.updatedBy), DbInt(rec.updatedAt),
                       DbStr(rec.previsitRef), DbInt(rec.id)]
            for (x in updates) {
                values.add(x)
            }
            for (x in before) { values.add(x) }
            /* 乐观锁第二道闸：expectedUpdatedAt 也进 WHERE，与 before 里的 updated_at 不是同一个值（后者是本次读到的）。 */
            var guard = ""
            if (expectedUpdatedAt > 0) {
                guard = " AND updated_at = ?"
                values.add(DbInt(expectedUpdatedAt))
            }
            let n = db.exec("UPDATE medical_record SET chief_complaint = ?, present_illness = ?, " +
                    "past_history = ?, allergy_history = ?, physical_exam = ?, diagnosis = ?, " +
                    "treatment = ?, updated_by = ?, updated_at = ?, previsit_ref = ? " +
                    "WHERE id = ? AND " + draftSnapshotSql +
                    guard,
                    values.toArray())
            out.recordId = rec.id
            out.ok = n == 1
            out.conflict = n == 0
            if (n == 0) {
                // 无变化写入也可能返回0；只有回读精确等于拟保存版本且仍draft才成功。
                match (findByAppointment(appointmentId)) {
                    case Some(latest) =>
                        var same = latest.status == EMR_DRAFT && latest.updatedBy == rec.updatedBy &&
                                   latest.updatedAt == rec.updatedAt
                        for (sec in emrSections()) {
                            if (latest.get(sec.key) != rec.get(sec.key)) { same = false }
                        }
                        out.ok = same
                        out.conflict = !same
                        out.locked = latest.isLocked()
                        /* 冲突时把"服务端现在是哪一版"带回给调用方。 */
                        out.currentUpdatedAt = latest.updatedAt
                        out.currentUpdatedBy = latest.updatedBy
                    case None => ()
                }
            }
            return out
        }
        /* patient_id 从 appointment 读出，绝不接受调用方传入。
         * 不用 INSERT ... SELECT：本仓从未跑通该形态（带占位符时驱动只给空消息的 SqlException），
         * 改成"先读 appointment 再纯 INSERT"，不变量不变 —— patient_id 仍来自挂号单。 */
        let ars = db.query("SELECT patient_id FROM appointment WHERE id = ?",
                           [DbInt(appointmentId)])
        if (ars.rowCount() == 0) {
            /* 挂号单不存在 ⇒ 不建病历（这是"没有该预约"的正解） */
            out.noSuchAppointment = true
            return out
        }
        let derivedPatientId = ars.getInt(0, 0)
        try {
            db.exec("INSERT INTO medical_record (appointment_id, patient_id, doctor_id, " +
                "chief_complaint, present_illness, past_history, allergy_history, " +
                "physical_exam, diagnosis, treatment, status, updated_by, created_at, updated_at, " +
                "previsit_ref) " +
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                [DbInt(appointmentId), DbInt(derivedPatientId), DbInt(doctorId),
                 DbStr(rec.chiefComplaint), DbStr(rec.presentIllness), DbStr(rec.pastHistory),
                 DbStr(rec.allergyHistory), DbStr(rec.physicalExam), DbStr(rec.diagnosis),
                 DbStr(rec.treatment), DbStr(EMR_DRAFT), DbInt(rec.updatedBy),
                 DbInt(rec.createdAt), DbInt(rec.updatedAt), DbStr(rec.previsitRef)])
        } catch (e: Exception) {
            /* 同预约并发首存撞 uk_record_appointment 时明确冲突，不重放过时的预填内容。
             * 只把唯一键冲突当冲突（baseDuplicateMessage：Duplicate entry 前缀或 errorCode 1062），其余异常原样上抛 ——
             * 否则连接断/超时/写错都会被翻成 EMR_CHANGED，把人引向完全错的方向。
             * 冲突必须回带 currentUpdatedAt/currentUpdatedBy：http_p4.cj 靠它走带 fields 的出口。 */
            match (baseDuplicateMessage(e)) {
                case None => throw e
                case Some(_) =>
                    match (findByAppointment(appointmentId)) {
                        case Some(latest) =>
                            out.recordId = latest.id
                            out.locked = latest.isLocked()
                            out.conflict = !out.locked
                            out.currentUpdatedAt = latest.updatedAt
                            out.currentUpdatedBy = latest.updatedBy
                            return out
                        case None => throw e
                    }
            }
        }
        rec.patientId = derivedPatientId
        match (findByAppointment(appointmentId)) {
            case Some(r2) =>
                out.recordId = r2.id
                out.ok = true
            case None =>
                /* 刚 INSERT 完却读不到：如实当"没有该预约"（404），不静默当成功。 */
                out.noSuchAppointment = true
        }
        return out
    }

    /* 提交锁定：病历必须存在且正文非空，diagnosis/treatment 不能空；置 status=locked 后 saveDraft 一律拒绝。
     * 条件 UPDATE 同时约束 draft 与刚校验的完整内容快照：只约束 draft 挡不住"校验后被他处清空再锁定空病历"，失配回 409。
     * updated_at 同时是乐观锁令牌与客户端眼里的版本号 ⇒ 必须严格递增（emrNextStamp：同秒则 prev + 1）。 */
    private func emrNextStamp(prev: Int64, now: Int64): Int64 {
        if (now > prev) {
            return now
        }
        return prev + 1
    }

    public func lock(appointmentId: Int64, now: Int64, actorId: Int64,
                     actorRole: String): EmrWriteOutcome {
        let out = EmrWriteOutcome()
        var rec = MedicalRecord()
        var exists = false
        match (findByAppointment(appointmentId)) {
            case Some(r) =>
                rec = r
                exists = true
            case None => ()
        }
        if (!exists) {
            out.noSuchAppointment = true
            return out
        }
        if (rec.isLocked()) {
            /* 幂等：已锁定再提交 ⇒ 明确告知"已锁定"，不当成成功（否则用户以为刚锁的） */
            out.locked = true
            out.recordId = rec.id
            /* 幂等路径上自愈一次快照：补上"锁定成功但审计行没写上"的洞。 */
            out.revisionVersion = ensureLockRevision(rec, actorId, actorRole, now)
            return out
        }
        let missing = rec.missingRequired()
        if (rec.filledCount() == 0 || missing.size > 0) {
            out.missingRequired = true
            out.detail = joinStrings(missing, "、")
            out.recordId = rec.id
            return out
        }
        let values = ArrayList<DbValue>()
        /* ★ 严格递增的版本戳（见 emrNextStamp）：SQL 与内存里的 rec 必须用同一个值。 */
        let stamped = emrNextStamp(rec.updatedAt, now)
        let updates: Array<DbValue> = [DbStr(EMR_LOCKED), DbInt(actorId), DbInt(stamped), DbInt(appointmentId)]
        for (x in updates) {
            values.add(x)
        }
        for (x in snapshotParams(rec)) { values.add(x) }
        let n = db.exec("UPDATE medical_record SET status = ?, updated_by = ?, updated_at = ? " +
                        "WHERE appointment_id = ? AND " + draftSnapshotSql, values.toArray())
        if (n == 0) {
            /* 校验的内容已改变或被锁定，不能锁定未校验的新内容。 */
            out.conflict = true
            out.recordId = rec.id
            return out
        }
        out.ok = true
        out.recordId = rec.id
        /* 定稿即落一版不可变快照，且必须在 UPDATE 之后写：先写会在 UPDATE 返回 0 时留下"没锁成"的审计行。
         * rec 是锁定前读到的，先把 status/updatedBy/updatedAt 就地改成落库后的样子再写，
         * 否则会写出"状态是 draft 的定稿快照"（验收里"这一版的状态是 locked"正是因此变红）。写失败 revisionVersion 保持 0。 */
        rec.status = EMR_LOCKED
        rec.updatedBy = actorId
        rec.updatedAt = stamped
        out.revisionVersion = writeRevision(rec, EMR_OP_LOCK, "", actorId, actorRole, now)
        return out
    }

    /* 管理员解锁（修订通道）：仅管理员、显式动作、必须写理由，理由与操作者一起落审计行（operation=reopen）。
     * 校验放域层：只写在 HTTP 层的话，任何新调用方（脚本/AC）都能绕过。
     * 挂号单根本没有病历时如实回 404，不再说成"已锁定"。 */
    public func reopen(appointmentId: Int64, now: Int64, actorId: Int64, actorRole: String,
                       reason: String): EmrWriteOutcome {
        let out = EmrWriteOutcome()
        if (!emrReasonValid(reason)) {
            out.badReason = true
            return out
        }
        /* 快照必须取解锁前（status=locked）的内容：先 UPDATE 再读会把那一版记成草稿，而它正是要留档的。 */
        var before = MedicalRecord()
        var exists = false
        match (findByAppointment(appointmentId)) {
            case Some(r) =>
                before = r
                exists = true
            case None => ()
        }
        if (!exists) {
            out.noSuchAppointment = true
            return out
        }
        let reopenStamp = emrNextStamp(before.updatedAt, now)
        let n = db.exec("UPDATE medical_record SET status = ?, updated_by = ?, updated_at = ? " +
                        "WHERE appointment_id = ? AND status = ?",
                        [DbStr(EMR_DRAFT), DbInt(actorId), DbInt(reopenStamp),
                         DbInt(appointmentId), DbStr(EMR_LOCKED)])
        if (n == 0) {
            out.locked = true      // 语义：没有"已锁定的病历"可解锁（当前是草稿）
            return out
        }
        out.ok = true
        out.recordId = before.id
        /* ★ 解锁也是一次状态变更 ⇒ 落一行带理由的审计快照（内容 = 解锁前那一版）。 */
        out.revisionVersion = writeRevision(before, EMR_OP_REOPEN, reason.trimAscii(),
                                            actorId, actorRole, now)
        return out
    }

    private let revCols: String =
        "id, record_id, appointment_id, version, status, sections_json, operation, " +
        "reason, operator_user_id, operator_role, created_at"

    private func rowToRevision(rs: DbResultSet, row: Int64): MedicalRecordRevision {
        let r = MedicalRecordRevision()
        r.id = rs.getInt(row, 0)
        r.recordId = rs.getInt(row, 1)
        r.appointmentId = rs.getInt(row, 2)
        r.version = rs.getInt(row, 3)
        r.status = rs.getString(row, 4)
        r.sectionsJson = rs.getString(row, 5)
        r.operation = rs.getString(row, 6)
        r.reason = rs.getString(row, 7)
        r.operatorUserId = rs.getInt(row, 8)
        r.operatorRole = rs.getString(row, 9)
        r.createdAt = rs.getInt(row, 10)
        return r
    }

    /* 该病历已有的最大版本号（一行都没有 ⇒ 0）。 */
    public func latestRevisionVersion(recordId: Int64): Int64 {
        let rs = db.query("SELECT IFNULL(MAX(version), 0) FROM medical_record_revision " +
                          "WHERE record_id = ?", [DbInt(recordId)])
        if (rs.rowCount() > 0) {
            return rs.getInt(0, 0)
        }
        return 0
    }

    /* 落一版快照，返回版本号（0 = 没写上）。版本号是"先查 MAX 再 +1"，并发会算出同一个号，由 uk_rev(record_id, version) 挡下；
     * 被挡下重算一次再写。两次都失败返回 0 不抛：业务动作已完成，审计写失败不该升级成"病历锁不了"。 */
    private func writeRevision(rec: MedicalRecord, operation: String, reason: String,
                               operatorUserId: Int64, operatorRole: String,
                               now: Int64): Int64 {
        var attempt: Int64 = 0
        while (attempt < 2) {
            let v = latestRevisionVersion(rec.id) + 1
            try {
                db.exec("INSERT INTO medical_record_revision (record_id, appointment_id, version, " +
                        "status, sections_json, operation, reason, operator_user_id, operator_role, " +
                        "created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                        [DbInt(rec.id), DbInt(rec.appointmentId), DbInt(v), DbStr(rec.status),
                         DbStr(emrSectionsJson(rec)), DbStr(operation), DbStr(reason),
                         DbInt(operatorUserId), DbStr(operatorRole), DbInt(now)])
                return v
            } catch (e: Exception) {
                attempt = attempt + 1
            }
        }
        return 0
    }

    /* 幂等路径自愈：已锁定但一条修订行都没有（lock 的 UPDATE 成功、INSERT 失败）⇒ 补一版，
     * 否则那份病历永远显示"0 个版本"，与界面上"已锁定"矛盾。 */
    private func ensureLockRevision(rec: MedicalRecord, actorId: Int64, actorRole: String,
                                    now: Int64): Int64 {
        let v = latestRevisionVersion(rec.id)
        if (v > 0) {
            return v
        }
        return writeRevision(rec, EMR_OP_LOCK, "", actorId, actorRole, now)
    }

    /* 修订列表按 version 升序：服务端给规范序，客户端管展示序（倒序是 .reverse() 一行的事）；
     * 不带正文 sections_json（列表可能几十版），要正文走 revisions/:version。 */
    public func revisions(appointmentId: Int64): Array<MedicalRecordRevision> {
        let rs = db.query("SELECT " + revCols + " FROM medical_record_revision " +
                          "WHERE appointment_id = ? ORDER BY version ASC", [DbInt(appointmentId)])
        let out = ArrayList<MedicalRecordRevision>()
        var i: Int64 = 0
        while (i < rs.rowCount()) {
            out.add(rowToRevision(rs, i))
            i = i + 1
        }
        return out.toArray()
    }

    /* 某次就诊的**某一版**（带正文）；没有这一版 ⇒ None。 */
    public func revisionAt(appointmentId: Int64, version: Int64): ?MedicalRecordRevision {
        let rs = db.query("SELECT " + revCols + " FROM medical_record_revision " +
                          "WHERE appointment_id = ? AND version = ?",
                          [DbInt(appointmentId), DbInt(version)])
        if (rs.rowCount() > 0) {
            return Some(rowToRevision(rs, 0))
        }
        return None
    }

    /* 某次就诊**已锁定**的最新一版（`reopen` 之后就是刚解锁的那一版）。 */
    public func latestLockedRevision(appointmentId: Int64): ?MedicalRecordRevision {
        let rs = db.query("SELECT " + revCols + " FROM medical_record_revision " +
                          "WHERE appointment_id = ? AND status = ? ORDER BY version DESC LIMIT 1",
                          [DbInt(appointmentId), DbStr(EMR_LOCKED)])
        if (rs.rowCount() > 0) {
            return Some(rowToRevision(rs, 0))
        }
        return None
    }

    /* 从预问诊问诊单预填病历（P2 → P4 衔接）：只预填不覆盖、只取同患者同挂号单的会话、已锁定不预填。
     * 不做自动建单 —— 预填只在医生首次保存草稿时发生（见 saveDraftWithIntake）。 */
    public func intakePrefill(sessionId: String, patientId: Int64): HashMap<String, String> {
        let out = HashMap<String, String>()
        let rs = db.query("SELECT form_json FROM previsit_session WHERE id = ? AND patient_id = ?",
                          [DbStr(sessionId), DbInt(patientId)])
        if (rs.rowCount() == 0) {
            return out
        }
        let form = previsitParseForm(rs.getString(0, 0))
        /* 槽位 key 一律从 intakeSlots() 派生（六行与槽位顺序一一对应，emrAssertIntakeSlotCount() 钉住个数）。 */
        let chief = emrAnswerOf(form, intakeSlotKeyAt(0))
        let duration = emrAnswerOf(form, intakeSlotKeyAt(1))
        let severity = emrAnswerOf(form, intakeSlotKeyAt(2))
        let associated = emrAnswerOf(form, intakeSlotKeyAt(3))
        let history = emrAnswerOf(form, intakeSlotKeyAt(4))
        let allergy = emrAnswerOf(form, intakeSlotKeyAt(5))
        if (chief.size > 0) {
            out["chief_complaint"] = chief
        }
        /* 现病史 = 病程 + 程度 + 伴随（同一段的素材），用 emrJoinParts 保证分隔符口径只有一处。 */
        let illness = emrJoinParts([("病程", duration), ("程度", severity), ("伴随", associated)])
        if (illness.size > 0) {
            out["present_illness"] = illness
        }
        if (history.size > 0) {
            out["past_history"] = history
        }
        if (allergy.size > 0) {
            out["allergy_history"] = allergy
        }
        return out
    }

    /* 首次保存草稿时顺带预填（可选）；已有病历一律不动（医生的判断优先）。 */
    public func saveDraftWithIntake(appointmentId: Int64, doctorId: Int64,
                                    sessionId: String, patientId: Int64,
                                    patch: HashMap<String, String>, now: Int64,
                                    actorId: Int64,
                                    expectedUpdatedAt!: Int64 = 0): EmrWriteOutcome {
        return saveDraft(appointmentId, doctorId, patch, now, actorId,
                         prefill: intakePrefill(sessionId, patientId),
                         previsitSessionId: sessionId,
                         expectedUpdatedAt: expectedUpdatedAt)
    }

    /* 迁移用：给存量已锁定病历补 v1 快照（幂等，migrateSchema 第 ⑩ 步调用）。
     * 不用 INSERT ... SELECT（本仓未跑通，且 sections_json 会变成 JSON_OBJECT 那第二处定义）⇒ 一次 SELECT + 逐行 INSERT。
     * operator_user_id/created_at 借用 updated_by/updated_at（唯一可得的历史信息）；operator_role 留空，编一个就是伪造审计。 */
    public func backfillRevisions(): Int64 {
        let rs = db.query("SELECT " + selectCols + " FROM medical_record " +
                          "WHERE status = ? AND NOT EXISTS (" +
                          "SELECT 1 FROM medical_record_revision r WHERE r.record_id = medical_record.id)",
                          [DbStr(EMR_LOCKED)])
        var done: Int64 = 0
        var i: Int64 = 0
        while (i < rs.rowCount()) {
            let m = rowToRecord(rs, i)
            let v = writeRevision(m, EMR_OP_LOCK, "", m.updatedBy, "", m.updatedAt)
            if (v > 0) {
                done = done + 1
            }
            i = i + 1
        }
        return done
    }
}

/* 迁移入口：migrateSchema 只拿得到 DbBackend，包一层即可复用仓储的行映射，不必把 rowToRecord 改成 public。 */
public func emrBackfillRevisions(db: DbBackend): Int64 {
    return MedicalRecordRepo(db).backfillRevisions()
}

/* 该挂号单的病历是否已定稿。退号那条路原本完全不看病历：定稿病历会挂在一张已退号、号源已转卖的单上，
 * 加上 uk_record_appointment 让它再也建不了第二份 ⇒ 孤儿记录，只能靠管理员改修订。
 * 这是前置判断（给准确的对外结果），真正护栏是 domain_booking.cj 退号 UPDATE 里的 NOT EXISTS。 */
public func emrHasLockedRecord(db: DbBackend, appointmentId: Int64): Bool {
    let rs = db.query("SELECT status FROM medical_record WHERE appointment_id = ?",
                      [DbInt(appointmentId)])
    return rs.rowCount() > 0 && rs.getString(0, 0) == EMR_LOCKED
}

/* ===================== 接诊队列（appointment 状态机）===================== */

/* 就诊状态与"挂号状态"是同一个字段 appointment.status，不是两套：booked → arrived → waiting → visiting → done，
 * 旁路 cancelled（只允许从 booked）、no_show；done/cancelled/no_show 是终态。
 * arrived/waiting 必须落库：到院与叫号是机构事实，前端自推换台设备就没了，也没有时间戳可解释"等了多久"。 */
public let VISIT_BOOKED: String = "booked"
public let VISIT_ARRIVED: String = "arrived"
public let VISIT_WAITING: String = "waiting"
public let VISIT_VISITING: String = "visiting"
public let VISIT_DONE: String = "done"
public let VISIT_CANCELLED: String = "cancelled"
public let VISIT_NO_SHOW: String = "no_show"

/* 显式流转表：加状态只改这里，且可被测试直接钉住。cancelled 只从 booked 允许（到院后号已消耗，须人工处理）。
 * domain_booking.cj 的退号 UPDATE 也是 WHERE status = 'booked'，改这里必须同时改那里。 */
public func visitTransitionAllowed(from: String, to: String): Bool {
    if (from == VISIT_BOOKED) {
        return to == VISIT_ARRIVED || to == VISIT_CANCELLED || to == VISIT_NO_SHOW
    }
    if (from == VISIT_ARRIVED) {
        return to == VISIT_WAITING || to == VISIT_NO_SHOW
    }
    if (from == VISIT_WAITING) {
        return to == VISIT_VISITING || to == VISIT_NO_SHOW
    }
    if (from == VISIT_VISITING) {
        return to == VISIT_DONE || to == VISIT_NO_SHOW
    }
    /* done / cancelled / no_show / 未知状态 —— 都是终态 */
    return false
}

/* 队列排序优先级（数字小的在前）：到院/候诊在前（人在现场等叫号），其次接诊中、未到院，最后今日终态单留档追溯。
 * 必须与 domain_booking.cj listAppointmentsByDoctor 的 ORDER BY (CASE status ...) 一致，AC-P4-8 逐项比对两者。 */
public func visitQueueRank(s: String): Int64 {
    if (s == VISIT_ARRIVED) {
        return 0
    }
    if (s == VISIT_WAITING) {
        return 1
    }
    if (s == VISIT_VISITING) {
        return 2
    }
    if (s == VISIT_BOOKED) {
        return 3
    }
    if (s == VISIT_DONE) {
        return 4
    }
    if (s == VISIT_NO_SHOW) {
        return 5
    }
    return 6
}

/* 该状态是否终态。 */
public func visitIsTerminal(s: String): Bool {
    return s == VISIT_DONE || s == VISIT_CANCELLED || s == VISIT_NO_SHOW
}

/* 状态中文名：拒绝一次操作时必须说清"现在是什么状态"；与状态常量同处，新增状态漏取名会在这里暴露。 */
public func visitStatusLabel(s: String): String {
    if (s == VISIT_BOOKED) {
        return "已挂号"
    }
    if (s == VISIT_ARRIVED) {
        return "已到院"
    }
    if (s == VISIT_WAITING) {
        return "候诊中"
    }
    if (s == VISIT_VISITING) {
        return "接诊中"
    }
    if (s == VISIT_DONE) {
        return "已完成"
    }
    if (s == VISIT_CANCELLED) {
        return "已退号"
    }
    if (s == VISIT_NO_SHOW) {
        return "已爽约"
    }
    return s
}

/* 接诊操作的结果。 */
public class VisitOutcome {
    public var ok: Bool = false
    /* 挂号单不存在（或不属于该医生）。 */
    public var notFound: Bool = false
    /* 当前状态不允许这个流转。 */
    public var badTransition: Bool = false
    /* 病历还没提交锁定 ⇒ 不允许"完成就诊"。 */
    public var recordNotLocked: Bool = false
    public var fromStatus: String = ""
    public var toStatus: String = ""
}

/* 患者基本标识：只给 name/gender；刻意不带 phone/birth_date（核对身份不需要，生日由医生问诊时自己问）。 */
public class PatientBrief {
    public var id: Int64 = 0
    public var name: String = ""
    public var gender: String = ""
}

public class VisitRepo {
    private let db: DbBackend
    /* 读挂号单委托 BookingRepo：列顺序与 fillFromRow 下标只在那一处定义（刻意的域间依赖，比两处列映射便宜）。 */
    private let booking: BookingRepo

    public init(db: DbBackend) {
        this.db = db
        this.booking = BookingRepo(db)
    }

    /* 批量读患者标识：一定是 WHERE id IN (…)，禁止循环逐条查（队列一次最多 100 条 ⇒ N+1）。
     * 占位符按去重后的 id 数给，只拼 ?（绝不把 id 文本拼进 SQL）。patient 表的列映射在本仓只此一处。 */
    public func patientBriefs(ids: Array<Int64>): HashMap<Int64, PatientBrief> {
        let out = HashMap<Int64, PatientBrief>()
        let uniq = ArrayList<Int64>()
        for (id in ids) {
            if (id <= 0) { continue }
            var dup = false
            for (u in uniq) {
                if (u == id) { dup = true }
            }
            if (!dup) { uniq.add(id) }
        }
        if (uniq.size == 0) { return out }
        var marks = ""
        let params = ArrayList<DbValue>()
        var i: Int64 = 0
        for (id in uniq) {
            if (i > 0) { marks = marks + ", " }
            marks = marks + "?"
            params.add(DbInt(id))
            i = i + 1
        }
        let rs = db.query("SELECT id, name, gender FROM patient WHERE id IN (" + marks + ")",
                          params.toArray())
        var r: Int64 = 0
        while (r < rs.rowCount()) {
            let b = PatientBrief()
            b.id = rs.getInt(r, 0)
            b.name = rs.getString(r, 1)
            b.gender = rs.getString(r, 2)
            out[b.id] = b
            r = r + 1
        }
        return out
    }

    /* 医生接诊队列（只含该医生、不含已退号）：列顺序照 BookingRepo，直接复用 fillFromRow。 */
    public func queueForDoctor(doctorId: Int64, limit: Int64): Array<BookingResult> {
        return booking.listAppointmentsByDoctor(doctorId, limit)
    }

    /* 取一张单并确认属于该医生；不匹配一律当不存在（不是"无权限"），避免存在性枚举 oracle。 */
    public func findForDoctor(appointmentId: Int64, doctorId: Int64): ?BookingResult {
        return booking.findAppointmentForDoctor(appointmentId, doctorId)
    }

    /* 流转状态：条件 UPDATE，影响行数即判据。extraWhere 放跨表前置条件（如完成前须已锁病历），
     * 让判据与写入是同一个原子动作。stampCol/stampValue 顺手写 arrived_at/started_at，与 status 同一句（分两句会留下中间态）。
     * stampCol 会拼进 SQL：只允许本文件的字面量常量，禁止来自请求参数。 */
    public func transition(appointmentId: Int64, doctorId: Int64,
                           to: String, allowFrom: Array<String>,
                           stampCol!: String = "", stampValue!: Int64 = 0): VisitOutcome {
        let out = VisitOutcome()
        var appt: BookingResult
        match (findForDoctor(appointmentId, doctorId)) {
            case Some(a) => appt = a
            case None =>
                out.notFound = true
                return out
        }
        out.fromStatus = appt.status
        out.toStatus = to
        if (!visitTransitionAllowed(appt.status, to)) {
            out.badTransition = true
            return out
        }
        var sql = "UPDATE appointment SET status = ?"
        var params = ArrayList<DbValue>()
        params.add(DbStr(to))
        if (stampCol.size > 0) {
            sql = sql + ", " + stampCol + " = ?"
            params.add(DbInt(stampValue))
        }
        sql = sql + " WHERE id = ? AND doctor_id = ? AND status IN ("
        params.add(DbInt(appointmentId))
        params.add(DbInt(doctorId))
        var first = true
        for (s in allowFrom) {
            if (!first) {
                sql = sql + ", "
            }
            sql = sql + "?"
            params.add(DbStr(s))
            first = false
        }
        sql = sql + ")"
        let n = db.exec(sql, params.toArray())
        if (n == 0) {
            /* 期间被别人改了 —— 如实说"状态不允许"，不假装成功 */
            out.badTransition = true
            return out
        }
        out.ok = true
        return out
    }

    /* 就诊日期门槛：未来日期的号不能进 arrived/waiting/visiting/done（客户端守卫可绕过，服务端不行）。
     * 允许过去的号：跨零点接诊与次日补录都是真实业务 ⇒ 判据是"就诊日 > 今天"，不是"必须等于今天"。
     * 只做纯判断，门禁在 http_p4.cj：领域夹具日期写死，把墙上时钟塞进领域层会让 700+ 条断言变脆。 */
    public func visitIsFuture(visitDate: String, now: Int64): Bool {
        if (visitDate.size == 0) {
            return false
        }
        return visitDate > hDateStringOf(now)
    }
    /* 到院登记 booked → arrived，记 arrived_at；重复登记 ⇒ badTransition。 */
    public func arriveVisit(appointmentId: Int64, doctorId: Int64, now: Int64): VisitOutcome {
        return transition(appointmentId, doctorId, VISIT_ARRIVED, [VISIT_BOOKED],
                          stampCol: "arrived_at", stampValue: now)
    }

    /* 进入候诊 arrived → waiting；不设 waiting_at，等待时长用 arrived_at 与 started_at 之差表达。 */
    public func waitingVisit(appointmentId: Int64, doctorId: Int64): VisitOutcome {
        return transition(appointmentId, doctorId, VISIT_WAITING, [VISIT_ARRIVED])
    }

    /* 开始接诊 waiting → visiting，记 started_at（就诊时长由此算）；只从 waiting 允许。 */
    public func startVisit(appointmentId: Int64, doctorId: Int64, now: Int64): VisitOutcome {
        return transition(appointmentId, doctorId, VISIT_VISITING, [VISIT_WAITING],
                          stampCol: "started_at", stampValue: now)
    }

    /* 完成就诊：要求病历已锁定（前置条件在同一句 UPDATE 里），记 finished_at。 */
    public func finishVisit(appointmentId: Int64, doctorId: Int64, now: Int64): VisitOutcome {
        let out = VisitOutcome()
        match (findForDoctor(appointmentId, doctorId)) {
            case Some(a) =>
                out.fromStatus = a.status
            case None =>
                out.notFound = true
                return out
        }
        out.toStatus = VISIT_DONE
        if (!visitTransitionAllowed(out.fromStatus, VISIT_DONE)) {
            out.badTransition = true
            return out
        }
        let n = db.exec(
            "UPDATE appointment SET status = ?, finished_at = ? WHERE id = ? AND doctor_id = ? AND status = ? " +
            "AND EXISTS (SELECT 1 FROM medical_record mr WHERE mr.appointment_id = appointment.id " +
            "AND mr.status = ?)",
            [DbStr(VISIT_DONE), DbInt(now), DbInt(appointmentId), DbInt(doctorId),
             DbStr(VISIT_VISITING), DbStr(EMR_LOCKED)])
        if (n == 0) {
            /* 两种可能：状态不是 visiting，或病历未锁定 —— 查一次给出**准确**原因 */
            let rs = db.query("SELECT status FROM medical_record WHERE appointment_id = ?",
                              [DbInt(appointmentId)])
            let hasLocked = rs.rowCount() > 0 && rs.getString(0, 0) == EMR_LOCKED
            if (!hasLocked) {
                out.recordNotLocked = true
            } else {
                out.badTransition = true
            }
            return out
        }
        out.ok = true
        return out
    }
}
