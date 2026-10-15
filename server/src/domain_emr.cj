/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 *
 * ===== domain_emr.cj —— P4 电子病历域（直接 SQL）============================
 *
 * ── 为什么病历**不**走内存 Store（ADR-0001 rev.6）──────────────────────────
 *
 *   ADR-0001 原版把 `department`/`doctor`/`patient`/`medical_record` 一起划进
 *   "内存 Store（配套域）"。P4 落地时发现**病历放错了**，理由有两条、都很硬：
 *
 *   ① ★ **本仓自己已经为同类数据判过一次**（P2）——
 *      `previsit_session` 当初就**特意排除**在内存 Store 之外，原话是：
 *        「★ 预问诊表**不属内存 Store 负责的表**（**它是医疗数据，必须立刻持久化**，
 *          不能进"整表替换"范式）」
 *      而 `medical_record` 是**最典型的医疗数据**（诊断/处理意见）。
 *      同一类数据两套处置，正是本项目反复点名的病（"同一语义两处口径"）。
 *
 *   ② ★ **内存 Store 在生产路径上从未刷盘**（我核实过）——
 *      全仓 `flushToMysql()` 的调用点**只有 `acceptance.cj`（测试）**；
 *      `main.cj` / `http_app.cj` **完全没有引用 MemStore**。
 *      ⇒ 若病历走内存 Store，写病历 = 只写内存 + **永不落库**。
 *        "病历丢了"与"排班丢了"不是一个量级的后果。
 *
 *   ⇒ 所以 rev.6 把 `medical_record` **移出 `MEM_TABLES`**，改直接 SQL，
 *     由本文件的 `MedicalRecordRepo` 独占写入（照 `BookingRepo` / `PrevisitRepo` 的范式）。
 *
 *   ⚠ **明确没做的事**（诚实标注，免得被读成"配套域也搬走了"）：
 *     `department` / `doctor` / `patient` **仍在内存 Store 里**。
 *     它们同样"生产不刷盘"，但 P4 的范围只到病历 —— 那三张表的处置
 *     （是接上刷盘、还是也改直接 SQL）属**另一项决策**，写进 P4-HANDOFF 的未做清单。
 *
 * ── 与预约（appointment）的关系 ───────────────────────────────────────────
 *   病历**挂在挂号单上**（`appointment_id` 唯一）：
 *     · 一次就诊一份病历 ⇒ `UNIQUE KEY uk_record_appointment` 由**数据库**保证；
 *     · 患者/医生身份**从 appointment 派生**，**不接受客户端传入** ——
 *       这是防越权的关键（照"我的挂号"那条的做法：参数不被信任）。
 */

package qingzhou

import std.collection.*
/*
 * ★ 2026-10-14（改进 1）：本文件第一次自己**构造** JSON —— `previsit_ref`
 *   的序列化/解析放在这里（与 `MedicalRecord` 同一个文件，读写同一处）。
 *   ⚠ 同包的其它文件各自 import 各自用（仓颉的 import 是**按文件**生效的，
 *     不存在"另一个文件 import 过就够了" —— 漏了就是
 *     `error: undeclared type name 'JsonValue'`，本轮真踩过）。
 */
import stdx.encoding.json.*

/* ===================== 病历表与七段式 ===================== */

/* 病历状态（表名常量 TABLE_MEDICAL_RECORD 在 schema.cj 已定义，不重复定义）。 */
public let EMR_DRAFT: String = "draft"
public let EMR_LOCKED: String = "locked"

/*
 * 病历**七段式**（照 brief §2.1 医生端的原文顺序）。
 *
 * ⚠ 顺序**有意义**：它是医生书写时的自然顺序（主诉 → 现病史 → … → 处理意见），
 *   也是接口回显的顺序。所以用**数组**而不是 Map（Map 无序）。
 */
public class EmrSection {
    public let key: String
    public let label: String
    /* 该段的字符上限（**按字符**算，不按字节 —— 见 P2 的字节/字符教训）。 */
    public let maxLen: Int64
    /*
     * 提交锁定时是否**必填**。
     *
     * ⚠ 这是**刻意的临床取舍**，不是"越全越好"：
     *   真实门诊里"既往史/过敏史"允许写"无"或留空（患者说不清），
     *   但**没有「诊断」的病历不是病历**。
     *   ⇒ 只把 `diagnosis` 与 `treatment` 设为必填 ——
     *     把"七段全必填"当成规则会把医生卡在没法提交，从而催生乱填。
     *   📌 该策略由 `emrRequiredWords()` 单一来源给出，测试直接钉它（见 AC-P4-*）。
     */
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

/*
 * ★★ 段的 SQL 长度表达式（**生成**，不手写）。
 *
 * ⚠ 为什么用 `CHAR_LENGTH` 而不是 `LENGTH`：
 *   `LENGTH` 是**字节**数，中文一字 3 字节 ⇒ 1200 字的诊断会被算成 3600
 *   ⇒ 一旦拿它做"是否为空"的判断，中文会被误判（这里是 `> 0` 判断，
 *     中文不会误判；但取最大值时口径就错了）。统一用字符口径，
 *     与本项目的"长度一律按字符算"保持一致。
 *
 * ⚠ 拼进 SQL 的列名全部来自 `emrSections()` 的**编译期常量**，不含外部输入。
 */
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

/*
 * 取 `intakeSlots()` 里第 i 个槽位的 key（越界返回空串）。
 *
 * ⚠ 为什么用**下标**而不是在本文件里写 "chief"/"duration" 字面量：
 *   那些字符串的**定义**在 `intakeSlots()` 里。这里再写一遍就等于有了第二份定义，
 *   加/改槽位时必然漏改一处。用下标 + `emrAssertIntakeSlotCount()` 测试钉住数量，
 *   就把"映射"变成了对**同一个来源**的位置引用。
 *   📌 待办：接真模型/做 RAG 时若槽位会变多，这里应改成"按 slot 的语义标签查"，
 *     而不是靠下标。当前 6 个槽位是**稳定**的（P2 起未变），下标是可接受的。
 */
public func intakeSlotKeyAt(i: Int64): String {
    let slots = intakeSlots()
    if (i >= 0 && i < slots.size) {
        return slots[i].key
    }
    return ""
}

/*
 * 把若干「标签 + 值」片段拼成一段文本（空值跳过；空串片段不产生分隔符）。
 *
 * ⚠ 抽出来是因为"分隔符口径"必须只有一处：先前我三处各写一次
 *   `cur + (if (cur.size > 0) { "；" } else { "" })`，改格式时就得改三处。
 */
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

/* ===================== 病历数据模型 ===================== */

/*
 * ★ 预问诊来源痕迹的 JSON（2026-10-14 增，改进 1）。
 *
 * `{"session_id":"…","sections":["chief_complaint",…],"at":<epoch 秒>}`
 *
 * ⚠ 它是**从"实际写进病历的那几段"直接构造**的（见 `saveDraft` 的 prefill 循环），
 *   而不是"把 intakePrefill 的 key 再算一遍" —— 后者会造出第二处定义，
 *   两个定义迟早会对不上（本项目反复踩的"同一语义两处实现"）。
 * ⚠ 手工拼 JSON 是这个项目明令避免的事（忘转义引号会把整张单写坏）：
 *   这里用框架的 `JsonObject`（与 `previsitFormJson` 同一手法）。
 *
 * ⚠ **语义边界（别把它读成"当前作者"）**：`sections` 记的是**建单那一刻的初值来源**，
 *   它只在**首次建单**时写入、之后**永不更新**。所以医生后来改写某一段时，
 *   这里仍标着"该段初值来自患者自述" —— 这是**有意的**（它答的是"这段话最初从哪来"），
 *   而不是"这一段现在还是患者写的吗"（那是另一个问题，需要逐段作者字段才能答，
 *   本项目暂不做）。**展示层必须照此措辞**（如"预填于 14:03"），
 *   把它写成"本段为患者自述"就是对病历来源的失实陈述，而病历是法律文书。
 *   `at` 字段就是为这个措辞准备的（配"预填于 <时间>"）。
 */
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

/*
 * 解析 `previsit_ref`，返回"哪几段来自患者自述"（坏数据/空串 ⇒ 空数组）。
 *
 * ⚠ 解析失败**不抛异常**：与 `previsitParseForm` 同一条纪律 ——
 *   库里一条坏 JSON 不该让"读病历"这个只读操作 500。
 */
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
                    /*
                     * ⚠ 按下标遍历（`arr[i]`），**不要**写 `for (x in arr)`：
                     *   stdx 的 `JsonArray` 没实现 `Iterator`，那样写编译期就报
                     *   `the type Class-JsonArray of expression in for-in expression
                     *    does not implement Iterator`（本轮真踩过）。
                     *   同仓的 `domain_kb.cj` 解析向量时也是这个写法。
                     */
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
    /*
     * ★ 预问诊来源痕迹（2026-10-14 增，改进 1）：JSON
     *   `{"session_id":"…","sections":[…],"at":<epoch 秒>}`，空串 = 没有预填来源。
     *   ⚠ 只在**建单时**由预填写入（那一次才是"这段来自患者自述"）。
     *     已有病历不吃预填（见 saveDraft），所以也不会改这个字段 ——
     *     否则"sections"会声称某些段是患者写的，而实际是医生后来改的。
     */
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

/* ===================== 写结果 ===================== */

/*
 * 写病历的结果。
 *
 * ⚠ 用**显式字段**而不是一个 String 错误码：调用方要能区分
 *   "没权限改"（403）/"已锁定"（409）/"未知段"（400）/"超长"（400）——
 *   它们该给客户端**不同的**状态码，混成一个字符串就会退化成 500 或一律 400。
 *   （与 `PrevisitAnswerOutcome` 同一手法。）
 */
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
    /* 供报错用的细节（段名/上限/缺哪几段）。 */
    public var detail: String = ""
    public var recordId: Int64 = 0
}

/* ===================== 病历仓储（直接 SQL）===================== */

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
        /*
         * ⚠ 新列一律**追加在 selectCols 末尾**（这里是 15），不插在中间：
         *   列顺序只在这两处（SELECT 与 rowToRecord）定义，插中间就得改所有下标，
         *   而改错一个下标不会编译失败 —— 会把 diagnosis 读成 treatment 这种事故。
         */
        m.previsitRef = rs.getString(row, 15)
        return m
    }

    private let selectCols: String =
        "id, appointment_id, patient_id, doctor_id, chief_complaint, present_illness, " +
        "past_history, allergy_history, physical_exam, diagnosis, treatment, status, " +
        "updated_by, created_at, updated_at, previsit_ref"

    /*
     * 完整内容快照作为乐观版本。MySQL 默认排序规则不区分大小写，必须二进制
     * 比较；updated_at 秒级时间戳不能单独作为版本。避免在共享连接上新开事务。
     */
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

    /*
     * 按挂号单 + **患者**取病历。
     *
     * ⚠ 患者侧**必须**走这个（而不是 findByAppointment）：否则患者 A 拿到
     *   患者 B 的 appointment_id 就能读到别人的病历 —— 那是**数据泄露**，
     *   而且 404 与 403 的区分还会变成"病历是否存在"的枚举 oracle。
     *   ⇒ 不匹配一律当"不存在"返回（照 previsit 的会话隔离口径）。
     */
    public func findByAppointmentForPatient(appointmentId: Int64, patientId: Int64): ?MedicalRecord {
        let rs = db.query("SELECT " + selectCols +
                          " FROM medical_record WHERE appointment_id = ? AND patient_id = ?",
                          [DbInt(appointmentId), DbInt(patientId)])
        if (rs.rowCount() > 0) {
            return Some(rowToRecord(rs, 0))
        }
        return None
    }

    /*
     * 患者自己的病历列表（"我的医疗档案"）。
     *
     * ⚠ 只回**患者本人**的：`patient_id` 由服务端从令牌派生，**不接受客户端传入**
     *   （照"我的挂号"那条纪律）。
     */
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

    /*
     * ★ 保存草稿（幂等 upsert）。
     *
     * 语义：把 `patch` 里的段合并进现有病历；没有病历则新建一份。
     * ⚠ **不校验必填** —— 草稿就是允许半成品（那正是"草稿"的意思）。
     *   必填只在**提交锁定**时校验（见 `lock`）。
     *
     * ⚠ 已锁定的病历**拒绝写入**（`locked = true`）——
     *   "提交锁定"的全部意义就在这里；允许改就等于没锁。
     */
    public func saveDraft(appointmentId: Int64, doctorId: Int64,
                          patch: HashMap<String, String>, now: Int64,
                          actorId: Int64,
                          prefill!: HashMap<String, String> = HashMap<String, String>(),
                          previsitSessionId!: String = ""): EmrWriteOutcome {
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
        // 保存合并前的完整快照；rec 会在下方被修改。
        let before = snapshotParams(rec)
        // ③ 合并
        /*
         * ★ 这次**真的**由患者自述写进病历的段（2026-10-14，改进 1）。
         *   用它构造 `previsit_ref`：只有"预填时既不在 patch 里、又通过校验被写入"
         *   的段才算患者自述 —— 医生在同一次请求的 patch 里写过的段不算。
         */
        let prefilled = ArrayList<String>()
        if (!exists) {
            rec.appointmentId = appointmentId
            rec.doctorId = doctorId
            rec.patientId = 0      // 由 ④ 从 appointment 补齐（**不从客户端取**）
            rec.createdAt = now
            // 仅在本次实际建单时预填，不能用建单前的外部查询结果覆盖已有病历。
            for ((k, v) in prefill) {
                if (!patch.contains(k)) {
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
            }
            if (prefilled.size > 0 && previsitSessionId.size > 0) {
                rec.previsitRef = emrPrevisitRefJson(previsitSessionId, prefilled.toArray(), now)
            }
        }
        for ((k, v) in patch) {
            let _ = rec.set(k, v)
        }
        rec.updatedBy = actorId
        rec.updatedAt = now
        // ④ 落库
        if (exists) {
            let values = ArrayList<DbValue>()
            let updates: Array<DbValue> = [DbStr(rec.chiefComplaint), DbStr(rec.presentIllness), DbStr(rec.pastHistory),
                       DbStr(rec.allergyHistory), DbStr(rec.physicalExam), DbStr(rec.diagnosis),
                       DbStr(rec.treatment), DbInt(rec.updatedBy), DbInt(rec.updatedAt), DbInt(rec.id)]
            for (x in updates) {
                values.add(x)
            }
            for (x in before) { values.add(x) }
            let n = db.exec("UPDATE medical_record SET chief_complaint = ?, present_illness = ?, " +
                    "past_history = ?, allergy_history = ?, physical_exam = ?, diagnosis = ?, " +
                    "treatment = ?, updated_by = ?, updated_at = ? WHERE id = ? AND " + draftSnapshotSql,
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
                    case None => ()
                }
            }
            return out
        }
        /*
         * ★★ patient_id **从 appointment 读出**，绝不接受调用方传入。
         *
         * ⚠ 这里我原先是写成 `INSERT ... SELECT ... FROM appointment` 的
         *   （让**数据库**把 patient_id 带过来，看起来更"原子"）。
         *   它**在仓颉侧必失败**，而原因我起初完全看不到：
         *     · 异常是 `SqlException: errorCode: 0` —— **消息是空的**
         *       （驱动把 MySQL 的报错文本吞了）；
         *     · 同一条 SQL 用 mariadb 客户端手工重放**完全成功**。
         *   ⇒ 定位后才明白：**本仓（含搬迁前带进来的代码）从来没用过 `INSERT ... SELECT`**，
         *     驱动的 `prepare_statement_client.getOrBuildSql()` 那条路径
         *     对"带占位符的 INSERT + SELECT 子句"没有被验证过。
         *   📌 教训：**不要在一个项目里第一次使用某条 SQL 形态**（尤其当失败
         *     只给空消息时）。用项目已经跑熟的形态，同样能达到目的 ——
         *     这里改成"先读 appointment、再纯 INSERT"，那个不变量**没有变**：
         *     patient_id 仍然来自挂号单，仍然不信任调用方。
         */
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
            // 同预约首次保存并发撞唯一键时明确冲突，不自动重放过时的预填内容。
            match (findByAppointment(appointmentId)) {
                case Some(latest) =>
                    out.recordId = latest.id
                    out.locked = latest.isLocked()
                    out.conflict = !out.locked
                    return out
                case None => throw e
            }
        }
        rec.patientId = derivedPatientId
        match (findByAppointment(appointmentId)) {
            case Some(r2) =>
                out.recordId = r2.id
                out.ok = true
            case None =>
                /*
                 * 刚 INSERT 完却读不到 ⇒ 不该发生。
                 * ⚠ **不静默当成功**：此时"写了却读不到"是自相矛盾的，
                 *   如实标成"没有该预约"（调用方会 404）比假装成功好。
                 */
                out.noSuchAppointment = true
        }
        return out
    }

    /*
     * ★★ 提交锁定。
     *
     * 校验：① 病历必须存在且非空正文；② 必填段（诊断/处理意见）不能为空。
     * 效果：`status = 'locked'` ⇒ 此后 `saveDraft` 一律拒绝。
     *
     * 条件UPDATE同时约束draft和刚校验的完整内容快照。只约束draft不能阻止
     * “校验完成→另一个保存清空必填→锁定空病历”的交错；失配明确返回409。
     */
    public func lock(appointmentId: Int64, now: Int64, actorId: Int64): EmrWriteOutcome {
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
        let updates: Array<DbValue> = [DbStr(EMR_LOCKED), DbInt(actorId), DbInt(now), DbInt(appointmentId)]
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
        return out
    }

    /*
     * ★ 管理员解锁（修订通道）。
     *
     * ⚠ 为什么需要它：病历写错是**必然会发生**的（真实医疗场景也一样），
     *   而"锁定即永久不可改"会把一次笔误变成无法纠正的档案。
     *   正确做法不是允许随便改，而是**留一条有迹可循的通道**：
     *   仅管理员、显式动作、`updated_by` 记录操作者。
     *   ⚠ 本轮的**边界**：只做到"解锁 + 记操作者"，**没有**做完整的修订历史表
     *     （谁在第几版改了什么）—— 那属后续，已写进 P4-HANDOFF 未做清单。
     */
    public func reopen(appointmentId: Int64, now: Int64, actorId: Int64): EmrWriteOutcome {
        let out = EmrWriteOutcome()
        let n = db.exec("UPDATE medical_record SET status = ?, updated_by = ?, updated_at = ? " +
                        "WHERE appointment_id = ? AND status = ?",
                        [DbStr(EMR_DRAFT), DbInt(actorId), DbInt(now),
                         DbInt(appointmentId), DbStr(EMR_LOCKED)])
        if (n == 0) {
            out.locked = true      // 语义：没有"已锁定的病历"可解锁
            return out
        }
        out.ok = true
        return out
    }

    /*
     * ★★ 从**预问诊问诊单**预填病历（P2 → P4 的衔接点）。
     *
     * 这是 P4 里"接上 P2"的那一步：患者开流时答的六项
     * （主诉/病程/程度/伴随/既往史/过敏史）正好覆盖病历七段里的四段。
     *
     * ⚠ 三条纪律：
     *   ① **只做预填，不做覆盖** —— 已经写过的段不动（医生的判断优先于患者自述）。
     *   ② 预填来源是**同一患者同一挂号单的会话**（按 patient_id 过滤）——
     *      不能把别人的问诊单填进这份病历。
     *   ③ 已锁定的病历**不预填**（锁定的意义就是定稿）。
     *   ⚠ 本轮**不做**"问诊单 → 病历"的自动建单（那会让"病历"在没有医生参与时出现）。
     *     预填只在医生**首次保存草稿**时发生（见 `saveDraftWithIntake`）。
     */
    public func intakePrefill(sessionId: String, patientId: Int64): HashMap<String, String> {
        let out = HashMap<String, String>()
        let rs = db.query("SELECT form_json FROM previsit_session WHERE id = ? AND patient_id = ?",
                          [DbStr(sessionId), DbInt(patientId)])
        if (rs.rowCount() == 0) {
            return out
        }
        let form = previsitParseForm(rs.getString(0, 0))
        /*
         * ⚠ 槽位 key 一律**从 `intakeSlots()` 派生**，不在这里写 "chief"/"duration" 字面量 ——
         *   否则"问诊单有哪些槽位"就有了第二个定义，加槽位时会漏改一处
         *   （本项目的"同一语义只留一处实现"）。
         *   下面这六行与 `intakeSlots()` 的**顺序**一一对应；
         *   `emrAssertIntakeSlotCount()` 在测试里把"必须是 6 个"钉住。
         */
        let chief = emrAnswerOf(form, intakeSlotKeyAt(0))
        let duration = emrAnswerOf(form, intakeSlotKeyAt(1))
        let severity = emrAnswerOf(form, intakeSlotKeyAt(2))
        let associated = emrAnswerOf(form, intakeSlotKeyAt(3))
        let history = emrAnswerOf(form, intakeSlotKeyAt(4))
        let allergy = emrAnswerOf(form, intakeSlotKeyAt(5))
        if (chief.size > 0) {
            out["chief_complaint"] = chief
        }
        /*
         * 现病史由"病程 + 程度 + 伴随"拼成 —— 它们是**同一段的素材**，
         * 合起来才构成"现病史"。用 `emrJoinParts` 保证分隔符口径只有一处。
         */
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

    /*
     * 医生**首次**保存草稿时顺带用问诊单预填（可选）。
     *
     * ⚠ 语义边界：只在"还没有病历"时预填；已有病历一律**不动**
     *   （医生的判断优先，不能被患者自述覆盖）。
     */
    public func saveDraftWithIntake(appointmentId: Int64, doctorId: Int64,
                                    sessionId: String, patientId: Int64,
                                    patch: HashMap<String, String>, now: Int64,
                                    actorId: Int64): EmrWriteOutcome {
        return saveDraft(appointmentId, doctorId, patch, now, actorId,
                         prefill: intakePrefill(sessionId, patientId),
                         previsitSessionId: sessionId)
    }
}

/* ===================== 接诊队列（appointment 状态机）===================== */

/*
 * 挂号单在**就诊流程**里的状态。
 *
 * ⚠ 与"挂号状态"是**同一个字段**（`appointment.status`），不是两套：
 *   `booked`（已挂号）→ `visiting`（接诊中）→ `done`（已完成）
 *   旁路：`cancelled`（患者/管理员退号）、`no_show`（爽约）
 *   📌 用同一个字段是刻意的 —— 两个字段表达"这张单现在什么状态"
 *     必然会出现不一致（本项目反复踩的"同一语义两处"）。
 *
 * `done` / `cancelled` / `no_show` 是**终态**：不可再流转。
 */
public let VISIT_BOOKED: String = "booked"
public let VISIT_VISITING: String = "visiting"
public let VISIT_DONE: String = "done"
public let VISIT_CANCELLED: String = "cancelled"
public let VISIT_NO_SHOW: String = "no_show"

/*
 * ★★ 状态流转表（**显式**，不是散落的 if）。
 *
 * 照 brief/ADR 的纪律"状态机要有显式流转表"：
 *   把"允许哪些流转"集中在一处 ⇒ 加状态只改这里，且**可被测试直接钉住**。
 */
public func visitTransitionAllowed(from: String, to: String): Bool {
    if (from == VISIT_BOOKED) {
        return to == VISIT_VISITING || to == VISIT_CANCELLED || to == VISIT_NO_SHOW
    }
    if (from == VISIT_VISITING) {
        return to == VISIT_DONE || to == VISIT_NO_SHOW
    }
    /* done / cancelled / no_show / 未知状态 —— 都是终态 */
    return false
}

/* 该状态是否终态。 */
public func visitIsTerminal(s: String): Bool {
    return s == VISIT_DONE || s == VISIT_CANCELLED || s == VISIT_NO_SHOW
}

/*
 * 状态 → 面向使用者的中文名（2026-10-12 增）。
 *
 * 为什么需要：拒绝一次状态不允许的操作时，**必须说清"现在是什么状态"** ——
 * 否则使用者只看到"不允许退号"，不知道是该去就诊、还是单子已经结束了。
 * 与状态常量放同一处：新增状态时**不可能忘记**给它取名字（漏了就会在这里被看到）。
 */
public func visitStatusLabel(s: String): String {
    if (s == VISIT_BOOKED) {
        return "已挂号"
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

public class VisitRepo {
    private let db: DbBackend
    /*
     * ★ 读挂号单**委托**给 BookingRepo（而不是本文件再写一份 SELECT）。
     *   理由见 BookingRepo.findAppointmentForDoctor 的注释：
     *   列顺序与 `fillFromRow` 的下标只在那一处定义，复制一份迟早会错位。
     *   📌 这带来一个"域间依赖"（接诊域 → 挂号域），是**刻意**的：
     *     比"两处列映射"的长期代价小得多。
     */
    private let booking: BookingRepo

    public init(db: DbBackend) {
        this.db = db
        this.booking = BookingRepo(db)
    }

    /*
     * 医生接诊队列（只含**该医生**的单，不含已退号）。
     *
     * ⚠ 列顺序照 `BookingRepo.findAppointment` 的 SELECT（**同一处定义**），
     *   这样能直接复用 `fillFromRow` —— 不自己再写一份行映射
     *   （两份映射迟早会不一致，那是本项目反复踩的病）。
     */
    public func queueForDoctor(doctorId: Int64, limit: Int64): Array<BookingResult> {
        return booking.listAppointmentsByDoctor(doctorId, limit)
    }

    /*
     * 取一张单（并确认属于该医生）。
     * ⚠ 不匹配 ⇒ 当**不存在**（不是"无权限"）—— 否则会变成"这张单是否存在"的枚举 oracle。
     */
    public func findForDoctor(appointmentId: Int64, doctorId: Int64): ?BookingResult {
        return booking.findAppointmentForDoctor(appointmentId, doctorId)
    }

    /*
     * 流转状态（条件 UPDATE，影响行数即判据）。
     *
     * ⚠ `extraWhere` 用于"完成就诊前必须已锁定病历"这类**跨表前置条件**：
     *   把它放进同一条 UPDATE 的 WHERE 里，才能做到"判据与写入是同一个原子动作"
     *   （否则"先查病历再改状态"在并发下会漏）。
     */
    public func transition(appointmentId: Int64, doctorId: Int64,
                           to: String, allowFrom: Array<String>): VisitOutcome {
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
        var sql = "UPDATE appointment SET status = ? WHERE id = ? AND doctor_id = ? AND status IN ("
        var params = ArrayList<DbValue>()
        params.add(DbStr(to))
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

    /* 完成就诊：**要求病历已锁定**（同一条 UPDATE 里带上这个前置条件）。 */
    public func finishVisit(appointmentId: Int64, doctorId: Int64): VisitOutcome {
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
            "UPDATE appointment SET status = ? WHERE id = ? AND doctor_id = ? AND status = ? " +
            "AND EXISTS (SELECT 1 FROM medical_record mr WHERE mr.appointment_id = appointment.id " +
            "AND mr.status = ?)",
            [DbStr(VISIT_DONE), DbInt(appointmentId), DbInt(doctorId),
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
