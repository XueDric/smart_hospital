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
 * 修订历史里的**操作**取值（改进 3）。
 * ⚠ 用常量而不是散落的字面量：AC 与文档都要引用它们，"lock" 写错一个字母
 *   不会编译失败，只会让审计查询查不到东西。
 *   `archive` 是**预留**（归档策略当前不需要，见 DDL 的容量估算）。
 */
public let EMR_OP_LOCK: String = "lock"
public let EMR_OP_REOPEN: String = "reopen"

/*
 * 解锁理由的长度约束（**按字符**，与本项目"长度一律按字符算"一致）。
 * ⚠ 为什么必须填：解锁是"推翻一份已定稿的医疗文书"，
 *   而"为什么推翻"是这个动作里唯一能留给后来人的信息。
 *   4 字下限只是拒绝"x"/"aaa"这种敷衍，不做语义判断。
 */
public let EMR_REASON_MIN: Int64 = 4
public let EMR_REASON_MAX: Int64 = 255

/* 解锁理由是否合法（trim 后 4–255 **字符**）。 */
public func emrReasonValid(reason: String): Bool {
    let t = reason.trimAscii()
    /*
     * ⚠ 必须用 `previsitCharLen`（字符数），不能用 `t.size`：
     *   `String.size` 是**字节**数 ⇒ 中文理由的"太短"永远拦不住
     *   （「太短」= 6 字节，会通过 4 字下限）。这一条是**实测**出来的：
     *   验收里"理由过短 ⇒ 被拒"的用例正是因此变红。
     *   仓库里 `domain_base.cj:94` 对 BASE_CODE_MAX 用的是同一个辅助函数 —— 口径一致。
     */
    let n = previsitCharLen(t)
    return n >= EMR_REASON_MIN && n <= EMR_REASON_MAX
}

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

/* ===================== 病历修订历史（改进 3，2026-10-15）===================== */

/*
 * 七段正文 → JSON 快照（**含空段**）。
 *
 * ⚠ 为什么连空段也写进去：diff 要能区分"这一段被删空了"与"这一版根本没有这一段"。
 *   只存非空段的话，两种情况在 JSON 里长得一模一样，而它们临床含义相反。
 * ⚠ 用 `JsonObject` 而不是手工拼串：段正文是**医生输入的任意文本**，
 *   里面完全可能有引号/反斜杠/换行 —— 手工拼 JSON 必然踩转义
 *   （本项目的纪律：不手工拼 JSON，见 `emrPrevisitRefJson` 的同款注释）。
 *   `rec.get(s.key)` 与 `emrSections()` 是**同一处定义**，所以键名不会漂移。
 */
public func emrSectionsJson(rec: MedicalRecord): String {
    let o = JsonObject()
    for (s in emrSections()) {
        o.put(s.key, JsonString(rec.get(s.key)))
    }
    return o.toString()
}

/*
 * JSON 快照 → 段值表（坏数据/空串 ⇒ 空表，**不抛**）。
 *
 * ⚠ 宽容解析的理由与 `emrPrevisitRefSections` 同：库里一条坏 JSON
 *   不该让"读修订历史"这个只读操作 500。
 * ⚠ 只取 `emrSections()` 里已知的段（未知键忽略）：快照是历史数据，
 *   将来若删掉某一段，旧快照里的那个键不该凭空出现在接口上。
 */
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

/*
 * 一条修订记录（`medical_record_revision` 的一行）。
 *
 * ⚠ 它是**不可变**的历史行：没有任何写方法（只有读）。
 *   要改历史，只能再落一行新版本 —— 这正是"审计流"的意思。
 */
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

/*
 * 两个版本之间**某一段**的差异。
 *
 * ⚠ 逐段给全七段（未变的 `changed = false` 也在内），不只给变化的那几段：
 *   界面要做"差异视图"（未变段也要显示，只是不高亮），
 *   而"只回变化段"会让客户端不得不自己再排一次段序、自己补未变的段 ——
 *   那就是把"七段有哪些、什么顺序、什么标签"复制到三个客户端。
 */
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
    /* ★ 解锁理由不合法（改进 3：缺理由 / 太短 / 太长）。 */
    public var badReason: Bool = false
    /* 供报错用的细节（段名/上限/缺哪几段）。 */
    public var detail: String = ""
    public var recordId: Int64 = 0
    /*
     * ★ 本次操作落下的修订版本号（改进 3）：lock / reopen 成功时 > 0，**0 = 没记上**。
     *
     * ⚠ 为什么把"版本号"放在写结果里、并透出到响应：
     *   ① 客户端要显示"已锁定 · v1"，而这个数字只有服务端知道（客户端算不出来，
     *      也不该算 —— 版本号是审计事实，不是界面推出来的）；
     *   ② **它让"审计写失败"不再静默** —— 锁定成功了但版本没记上时，
     *      响应里 `revision_version` 为 0，医生看到的就不是一句笼统的"已锁定"。
     *   📌 锁定的**业务效果**（status=locked）不因审计写失败而回滚：
     *     那会让"库写不进去"变成"医生锁不了病历"，两者严重程度不同。
     */
    public var revisionVersion: Int64 = 0
    /*
     * ★ 服务端**当前**那一版的时间与作者（改进 2，仅在 `conflict` 时有意义）。
     *
     * ⚠ 为什么必须回带：
     *   客户端拿 `expected_updated_at` 来提交，被 409 挡下时如果只知道"冲突了"，
     *   它只能整份丢掉本地输入重新拉取 —— 医生的输入就这么没了。
     *   回带"服务端现在是 updated_at=X / updated_by=Y"之后，界面才能说
     *   「另一位医生在 14:03 改过这一份」并让医生自己决定怎么合并。
     *   0 = 服务端没读到（病历不存在/已被删），**不是**"时间是 1970"。
     */
    public var currentUpdatedAt: Int64 = 0
    public var currentUpdatedBy: Int64 = 0
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
     * ★ 该患者是否是**这位医生**看过的患者（改进 2 的隐私闸门）。
     *
     * 为什么必须存在：新端点 `GET /doctor/patients/:patientId/records` 让医生读
     *   **既往**病历。若不加这道闸，任何医生只要猜到 patient_id（那是自增整数）
     *   就能把全院患者的病历翻一遍 —— 而病历里含过敏史、既往史这些敏感信息。
     *
     * ⚠ 判断放在 **SQL 里**（`WHERE doctor_id = ? AND patient_id = ? LIMIT 1`），
     *   不是"先读出就诊记录再在仓颉里比" —— 后者只是把同一件事写在两处，
     *   一旦有人改了其中一处就会悄悄放行（照 `http_p4.cj` 的归属校验纪律）。
     * ⚠ 返回 Bool 而不是"是不是 403"：调用方一律把它翻成 **404**，
     *   不给"这个患者存在吗"的枚举信号（照 previsit 会话隔离的口径）。
     */
    public func patientTreatedByDoctor(doctorId: Int64, patientId: Int64): Bool {
        if (doctorId <= 0 || patientId <= 0) {
            return false
        }
        let rs = db.query("SELECT 1 FROM appointment WHERE doctor_id = ? AND patient_id = ? LIMIT 1",
                          [DbInt(doctorId), DbInt(patientId)])
        return rs.rowCount() > 0
    }

    /*
     * ★ 该患者在该医生名下的**已定稿**病历（改进 2：医生工作台的"既往记录"）。
     *
     * ⚠ 三个约束都与"谁能看到什么"有关，改动前务必读完：
     *   ① `doctor_id` 参与 WHERE ⇒ 医生只看到**自己**看过的那些次；
     *      （"这位患者是不是我的患者"已由 `patientTreatedByDoctor` 单独把关，
     *        这里再限一次是**纵深防御**：将来若有人把闸门挪走，这里仍然挡得住）
     *   ② `status = 'locked'` ⇒ 草稿不外泄：草稿是医生个人的工作稿，
     *      给另一个医生看等于把"未定稿当结论"（口径同 http_p4.cj 的 473-474 行）；
     *   ③ `excludeAppointmentId` 用于"本次就诊"：工作台显示既往记录时
     *      不能把正在写的这一份也算进"既往"。
     * 排序：**就诊时间倒序**（`appointment.visit_date DESC, appointment.period DESC`）
     *   + `id DESC` 兜底（并列时顺序稳定，否则同一秒内的行会让列表顺序抖动）。
     *
     * ⚠ 2026-10-16 改（医生端复核 ★★ 第 3 条，原为 `updated_at DESC, id DESC`）：
     *   `updated_at` 是"这一行最后一次被写"的时刻，**不是**就诊时间 ——
     *   医生把一份三个月前的老病历打开、改一个字再锁定，它就会跳到
     *   "既往记录"的最前面，医生读到的顺序与真实就诊顺序**相反**。
     *   而 `medical_record` 表里**没有** visit_date/period（只有 appointment_id），
     *   就诊时间只能从挂号单取 ⇒ 用只取一列的相关子查询带出来。
     *
     * ⚠ 为什么不用 JOIN：`medical_record` 与 `appointment` 有同名列
     *   （`id` / `patient_id` / `doctor_id`），本仓因 JOIN 的列名歧义栽过
     *   （见 `domain_booking.cj` 的注释：那时改成了 EXISTS）。子查询只读一列、
     *   列名全部带表前缀，不引入歧义，也不用改 `selectCols`/`rowToRecord`
     *   的列顺序（那是本仓"只有一处定义"的纪律）。
     *   📌 代价：每行两次子查询。`(doctor_id, patient_id, status)` 上的行数是个位数
     *      到几十条（"某医生某患者的既往"），可以接受；若将来要上量，
     *      正确做法是把它做成 `medical_record` 的冗余列，而不是在 HTTP 层加排序。
     */
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
        /*
         * ★ 乐观锁（改进 2）：客户端带 `expected_updated_at` 时，服务端**当前**那一版
         *   必须还是它以为的那一版，否则 409 EMR_CHANGED。
         *
         * ⚠ 为什么不能只在 HTTP 层"先读再比"：那样两个请求会在
         *   "读 → 比 → 写"之间交错，两人同时提交时**两个都过**（经典的 TOCTOU）。
         *   所以这里除了本次校验，`exists` 分支的 UPDATE **还额外带一个
         *   `updated_at = ?`**（见下方 `expectedGuard`）——把校验并进同一条写语句，
         *   库层面保证"我改的正是我看到的那一版"。
         */
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
            /*
             * ★ 乐观锁的第二道闸（改进 2）：客户端报的 `expected_updated_at` 也进 WHERE。
             *   它与 `before` 里的 `updated_at` 不是同一个值 ——
             *   `before` 是**本次**读到的，`expectedUpdatedAt` 是**客户端**读到的。
             *   只有两者都成立（= 没人在这两次读之间插进来改过）才写入。
             */
            var guard = ""
            if (expectedUpdatedAt > 0) {
                guard = " AND updated_at = ?"
                values.add(DbInt(expectedUpdatedAt))
            }
            let n = db.exec("UPDATE medical_record SET chief_complaint = ?, present_illness = ?, " +
                    "past_history = ?, allergy_history = ?, physical_exam = ?, diagnosis = ?, " +
                    "treatment = ?, updated_by = ?, updated_at = ? WHERE id = ? AND " + draftSnapshotSql +
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
                        /* 冲突时把"服务端现在是哪一版"带回给调用方（改进 2）。 */
                        out.currentUpdatedAt = latest.updatedAt
                        out.currentUpdatedBy = latest.updatedBy
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
            /*
             * 同预约首次保存并发撞唯一键时明确冲突，不自动重放过时的预填内容。
             *
             * ⚠ 2026-10-16（医生端复核 ★★★ 第 1 条）：这里原先 `catch (e: Exception)`
             *   把**所有**异常都当成"并发撞单" —— 连接断、超时、SQL 写错全都会被
             *   翻译成 409 冲突，调用方拿着 `EMR_CHANGED` 去刷新重试，而真相是库故障
             *   （错误码把运维引到完全错的方向）。改成先确认唯一键冲突：
             *   复用 `domain_base.cj` 的 `baseDuplicateMessage`（同 `baseExecTolerant`
             *   的判据：只有 `Duplicate entry` 前缀或 `SqlException.errorCode == 1062`），
             *   其余异常**原样上抛**。
             *
             * ⚠ 冲突时还必须带回"服务端现在是哪一版"（`currentUpdatedAt` /
             *   `currentUpdatedBy`）：`http_p4.cj` 靠 `if (out.currentUpdatedAt > 0)`
             *   决定走**带 `fields`** 的那条出口；不填就退化成 `apiErrorMsg`，
             *   响应里没有 `error.fields`，与
             *   `contract/schema/envelope-error-fields.schema.json` 的必填直接冲突
             *   （医生端按 `error.fields.updated_at` 重新拉取的做法会拿到 undefined）。
             *   上方 `n == 0` 分支（887-899 行）本来就填了这两个字段，
             *   这条出口是**漏掉的另一半**（同一件事只做了一半）。
             */
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
            /*
             * ★ 改进 3：幂等路径上**自愈**一次快照（见 ensureLockRevision 的说明）。
             *   没有它，上一轮"锁定成功但审计行没写上"会**永久**留在库里。
             */
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
        /*
         * ★ 改进 3：定稿即落一版**不可变快照**。
         *
         * ⚠ 为什么在 UPDATE **之后**写（而不是之前）：快照必须"锁定发生了才有"。
         *   写在前面的话，一旦 UPDATE 因并发改稿失败（返回 0），
         *   库里就会留下一版"其实没锁成"的快照 —— 而审计行**不能**说谎。
         *   写失败时 `revisionVersion` 保持 0（见 EmrWriteOutcome 的说明），
         *   下一次 lock 重试会在幂等路径上自愈。
         * ⚠ `rec` 是锁定前读到的内容，且 UPDATE 用 `draftSnapshotSql` 把它当成乐观版本
         *   ⇒ 落盘的正文与 `rec` **逐字节相同**，快照忠实。
         * ⚠⚠ 但正文相同不代表**状态**相同：`rec.status` 此刻还是 `'draft'`（它是锁定**前**
         *   读到的），直接落盘会写出"一版状态是 draft 的定稿快照" —— 实测验收里
         *   "这一版的状态是 locked" 正是因此变红。所以先把 `rec` 就地改成**落库后的样子**，
         *   再写快照：快照要记的是"锁定后库里长什么样"。
         */
        rec.status = EMR_LOCKED
        rec.updatedBy = actorId
        rec.updatedAt = now
        out.revisionVersion = writeRevision(rec, EMR_OP_LOCK, "", actorId, actorRole, now)
        return out
    }

    /*
     * ★ 管理员解锁（修订通道）。
     *
     * ⚠ 为什么需要它：病历写错是**必然会发生**的（真实医疗场景也一样），
     *   而"锁定即永久不可改"会把一次笔误变成无法纠正的档案。
     *   正确做法不是允许随便改，而是**留一条有迹可循的通道**：
     *   仅管理员、显式动作、**必须写理由**、操作者与理由一起落进审计行。
     *   ✅ 2026-10-15（改进 3）：解锁**已**记进 `medical_record_revision`
     *     （`operation='reopen'` + `reason` + `operator_user_id/operator_role`），
     *     并且定稿那一刻也留一版 —— 所以"谁在第几版改了什么"现在查得到。
     *     （此前这里写着"没有做完整的修订历史表，属后续" —— 那句话已经过期。）
     */
    public func reopen(appointmentId: Int64, now: Int64, actorId: Int64, actorRole: String,
                       reason: String): EmrWriteOutcome {
        let out = EmrWriteOutcome()
        /*
         * ★ 改进 3：解锁**必须说明理由**，且理由要能落进审计行。
         *   校验放在域层（不只放 HTTP 层）：域层是"病历不可无理由解锁"这条规则的
         *   唯一归属地；只写在 HTTP 层的话，任何新的调用方（脚本/AC）都能绕过它。
         */
        if (!emrReasonValid(reason)) {
            out.badReason = true
            return out
        }
        /*
         * ⚠ 快照必须取**解锁前**的内容 ⇒ 先读一份（此刻 `status='locked'`）再 UPDATE。
         *   反过来（先 UPDATE 再读）读到的就是 `draft`，
         *   审计行会把"当时锁定的那一版"记成草稿 —— 而它正是要留档的那一版。
         * ⚠ 与此前行为的一处**收紧**：挂号单根本没有病历时，此前也返回
         *   `locked=true`（⇒ 409 EMR_LOCKED，把"没有这张单"说成"已锁定"）。
         *   现在如实区分：没有病历 ⇒ `noSuchAppointment` ⇒ 404。
         */
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
        let n = db.exec("UPDATE medical_record SET status = ?, updated_by = ?, updated_at = ? " +
                        "WHERE appointment_id = ? AND status = ?",
                        [DbStr(EMR_DRAFT), DbInt(actorId), DbInt(now),
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

    /* ===== 修订历史（改进 3）：只增不改 ===== */

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

    /*
     * 落一版快照，返回版本号（0 = 没写上）。
     *
     * ⚠ 版本号是"先查 MAX 再 +1"，两次并发写会算出同一个号 ——
     *   而 `uk_rev (record_id, version)` 会挡下第二条（**数据库兜底**，
     *   这就是那个唯一键存在的理由）。被挡下时**重算一次**再写：
     *   重算而不是"报错让用户重试"，因为这个动作没有用户可感知的失败语义
     *   （用户只是点了"提交锁定"）。
     * ⚠ 两次都失败 ⇒ 返回 0，**不抛**：调用方（lock/reopen）已经完成了业务动作，
     *   把审计写失败升级成"病历锁不了"是本末倒置（见 EmrWriteOutcome.revisionVersion）。
     */
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

    /*
     * 幂等路径上的**自愈**：已锁定、但一条修订行都没有 ⇒ 补一版。
     *
     * ⚠ 这个函数存在的唯一理由是一个真实可能的窗口：
     *   `lock` 的 UPDATE 成功、紧接着的 INSERT 修订行失败（连接/磁盘抖动）。
     *   没有自愈的话，那份病历会**永远**显示"0 个版本" ——
     *   而界面上它是"已锁定"，两个事实互相矛盾，医生会以为系统丢了数据。
     *   客户端重试一次 lock（幂等路径）就把这一版补上。
     */
    private func ensureLockRevision(rec: MedicalRecord, actorId: Int64, actorRole: String,
                                    now: Int64): Int64 {
        let v = latestRevisionVersion(rec.id)
        if (v > 0) {
            return v
        }
        return writeRevision(rec, EMR_OP_LOCK, "", actorId, actorRole, now)
    }

    /*
     * 某次就诊的全部修订（**升序**：v1 在前）。
     *
     * ⚠ 为什么不按时间倒序（"最新的在最上面"是界面常见诉求）：
     *   ① `version` 才是这个列表的主键语义，升序读起来是"病历的历史"；
     *   ② "与上一版对比"要的是 `version - 1`，倒序会让这个映射看起来是反的；
     *      倒序展示是客户端 `.reverse()` 一行的事，而排序口径搞反了
     *      会让"上一版"指向未来。**服务端给规范序，客户端管展示序。**
     * ⚠ **不带正文**（`sections_json` 不出站）：列表可能几十版，
     *   带正文会让"打开版本抽屉"变成一次几 MB 的响应。
     *   要正文请走 `/revisions/:version`。
     */
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
                                    actorId: Int64,
                                    expectedUpdatedAt!: Int64 = 0): EmrWriteOutcome {
        return saveDraft(appointmentId, doctorId, patch, now, actorId,
                         prefill: intakePrefill(sessionId, patientId),
                         previsitSessionId: sessionId,
                         expectedUpdatedAt: expectedUpdatedAt)
    }

    /*
     * ★ 迁移用：给**存量已锁定病历**补 v1 快照（幂等；由 `migrateSchema` 第 ⑩ 步调用）。
     *
     * ⚠ 为什么不写成 `INSERT ... SELECT`（SQL 一句搞定）：
     *   ① 本仓**从未跑通过** `INSERT ... SELECT`（带占位符时驱动会失败，且
     *      只给空错误消息 —— 见 `saveDraft` 里那段教训）；
     *   ② `sections_json` 要由 `emrSectionsJson` 生成（拼接/转义口径只有一处），
     *      在 SQL 里再用 `JSON_OBJECT` 写一遍就是**第二处定义**。
     *   ⇒ 一次 SELECT（只挑"一条修订都没有"的锁定病历）+ 逐行 INSERT。
     *     存量库的量级是"几百行"，一次迁移跑几百条 INSERT 完全可接受。
     * ⚠ `status = 'locked'` 的行才补：草稿本来就不落版本（本项的既定取舍）。
     * ⚠ `operator_user_id` 用 `updated_by`、`created_at` 用 `updated_at`：
     *   那是**唯一可得的**历史信息（最后改这份病历的人 / 那一刻）。
     *   `operator_role` 留空串 —— 历史数据里**没有**这个信息，编一个就是伪造审计。
     */
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

/*
 * 迁移入口（schema.cj 的第 ⑩ 步调用它）。
 *
 * ⚠ 为什么用自由函数包一层：`migrateSchema` 只拿得到 `DbBackend`，
 *   而补快照要用仓储的行映射（列序只在一处）。包一层比把 `rowToRecord`
 *   改成 public 更好 —— 后者会把"仓储私有列序"暴露给所有调用方。
 */
public func emrBackfillRevisions(db: DbBackend): Int64 {
    return MedicalRecordRepo(db).backfillRevisions()
}

/*
 * ★ 2026-10-17 增：该挂号单的病历是否**已定稿（`locked`）**。
 *
 * 为什么需要它（实测确认的缺陷）：`locked` 的语义是"病历已定稿、不可再改"，
 *   但**退号那条路完全不看病历** —— 患者可以把一张已定稿病历挂着的单退掉，
 *   号源回到池子（可能被卖给别人）。后果：
 *     · 那张单再也不可能 `finish`（`finish` 要求 `visiting` + 病历已锁，
 *       而 `cancelled` 是终态）⇒ **一份定稿病历永久挂在一张已退号、号源已转卖的单上**；
 *     · `medical_record` 有 `UNIQUE KEY uk_record_appointment (appointment_id)`，
 *       同一张单不可能再建第二份病历 ⇒ 这条记录成了孤儿，只能靠管理员改修订。
 *
 * ⚠ 为什么放在 domain_emr 而不是就地写在 BookingRepo：`medical_record.status`
 *   的取值与"哪个值代表不可再改"属于 EMR 域的语义，散到别的文件里写 `'locked'`
 *   字面量就等于有了第二份定义（本项目反复踩的"同一语义两处"）。
 * ⚠ 与 `emrBackfillRevisions` 同理用自由函数包一层：BookingRepo 拿不到
 *   `MedicalRecordRepo` 实例，而它只需要一个布尔判断。
 * ⚠ 这是**前置判断**（为了给出准确的对外结果），真正的护栏是 `domain_booking.cj`
 *   退号那条原子 UPDATE 里的 `NOT EXISTS(...)` —— 并发下"先读后判"永远可能过期。
 */
public func emrHasLockedRecord(db: DbBackend, appointmentId: Int64): Bool {
    let rs = db.query("SELECT status FROM medical_record WHERE appointment_id = ?",
                      [DbInt(appointmentId)])
    return rs.rowCount() > 0 && rs.getString(0, 0) == EMR_LOCKED
}

/* ===================== 接诊队列（appointment 状态机）===================== */

/*
 * 挂号单在**就诊流程**里的状态。
 *
 * ⚠ 与"挂号状态"是**同一个字段**（`appointment.status`），不是两套：
 *   `booked`（已挂号）→ `arrived`（已到院）→ `waiting`（候诊中）
 *                     → `visiting`（接诊中）→ `done`（已完成）
 *   旁路：`cancelled`（退号，**只允许从 booked**）、`no_show`（爽约）
 *   📌 用同一个字段是刻意的 —— 两个字段表达"这张单现在什么状态"
 *     必然会出现不一致（本项目反复踩的"同一语义两处"）。
 *
 * `done` / `cancelled` / `no_show` 是**终态**：不可再流转。
 *
 * 2026-10-15（改进 6）插入 `arrived` / `waiting` 两个状态：
 *   · 为什么必须落库而不是前端自己推：到院/候诊是**机构事实** ——
 *     患者到前台报到了、护士叫过号了，医生换一台设备看队列也得看到同一件事；
 *     前端自推的状态换台设备就没了，且没有时间戳可解释"等了多久"。
 *   · 为什么不用"患者自述到院"直接覆盖：避免与 `visiting`/`done` 打架，
 *     每一步都走同一张流转表。
 */
public let VISIT_BOOKED: String = "booked"
public let VISIT_ARRIVED: String = "arrived"
public let VISIT_WAITING: String = "waiting"
public let VISIT_VISITING: String = "visiting"
public let VISIT_DONE: String = "done"
public let VISIT_CANCELLED: String = "cancelled"
public let VISIT_NO_SHOW: String = "no_show"

/*
 * ★★ 状态流转表（**显式**，不是散落的 if）。
 *
 * 照 brief/ADR 的纪律"状态机要有显式流转表"：
 *   把"允许哪些流转"集中在一处 ⇒ 加状态只改这里，且**可被测试直接钉住**。
 *
 * ⚠ `cancelled` **只从 `booked` 允许**（患者自助退号）：
 *   到院后号已被消耗，要取消必须人工处理（否则会出现"人已经看完了、
 *   单子却变成已退号、号源还回池子"）。`domain_booking.cj` 的退号 UPDATE
 *   也是 `WHERE status = 'booked'`，两处口径一致 —— 改这里必须同时改那里。
 */
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

/*
 * 队列排序优先级（数字小的排前面）。
 *
 * ⚠ 与 `domain_booking.cj` 里 `listAppointmentsByDoctor` 的
 *   `ORDER BY (CASE status ...)` **必须一致** —— 那是同一件事的两处表述
 *   （SQL 里排序才能配合 LIMIT）。AC-P4-8 用本函数预测顺序、再与 SQL 的
 *   实际返回逐项比对，两者的分歧会在测试里立刻变红。
 *
 * 排法：到院/候诊的人**排在前面**（他们人在现场等叫号），
 *       其次接诊中，再其次还没到院的，最后是今天的终态单（留在队列里供追溯）。
 */
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

/*
 * ★ 患者基本标识（2026-10-16 增，医生端复核 ★★★ 第 2 条）。
 *
 * 只承载"认出一个人"所需的两列：`name` / `gender`。
 * ⚠ 刻意**不带** phone / birth_date：医生核对身份不需要手机号；
 *   出生日期由医生问诊时自己问（进病历正文），不靠接口悄悄带出来。
 */
public class PatientBrief {
    public var id: Int64 = 0
    public var name: String = ""
    public var gender: String = ""
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
     * ★ 患者基本标识的**批量**读（2026-10-16 增，医生端复核 ★★★ 第 2 条）。
     *
     * ⚠ 为什么放在 VisitRepo（而不是新建 PatientRepo）：`registerP4Routes` 已经拿到
     *   `visit`，医生侧三个端点都在它的作用域里；新增一个 repo 要同时改
     *   `http_p4.cj` / `http_app.cj` / acceptance 三处装配签名，收益只是"名字更好看"。
     *   `patient` 表的**列映射在本仓只此一处**（同 BookingRepo 的纪律：
     *   列顺序与下标不许有第二份，否则迟早错位）。
     *
     * ⚠ 一定是批量读（`WHERE id IN (…)`），不在循环里逐条查：
     *   接诊队列一次最多 100 条，逐条查就是 N+1（同 http_base.cj 的 NameIndex 纪律）。
     * ⚠ 占位符个数按**去重后**的 id 数给，且只拼 `?`（绝不把 id 文本拼进 SQL）。
     */
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
     *
     * `stampCol` / `stampValue`（2026-10-15 改进 6 增）：顺手在同一句 UPDATE 里
     *   写下这一步的时间戳（`arrived_at` / `started_at`）。
     *   ⚠ `stampCol` 会被拼进 SQL —— **只允许传本文件的字面量常量**，
     *     绝不允许来自请求参数（那是注入）。
     *   📌 写在与 status 同一条 UPDATE 里是刻意的：分两句写会出现
     *     "状态改了、时间戳没改"的中间态，而时间线正是排障要看的东西。
     */
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

    /*
     * 到院登记：`booked → arrived`，并记 `arrived_at`。
     * 只允许从 `booked`（重复登记 ⇒ badTransition，前端刷新即可看到真相）。
     */
    public func arriveVisit(appointmentId: Int64, doctorId: Int64, now: Int64): VisitOutcome {
        return transition(appointmentId, doctorId, VISIT_ARRIVED, [VISIT_BOOKED],
                          stampCol: "arrived_at", stampValue: now)
    }

    /*
     * 进入候诊：`arrived → waiting`。
     * 没有时间戳列 —— "等了多久"由 `arrived_at` 与 `started_at` 之差表达，
     * 再加一个 `waiting_at` 只会多一个可能不一致的字段。
     */
    public func waitingVisit(appointmentId: Int64, doctorId: Int64): VisitOutcome {
        return transition(appointmentId, doctorId, VISIT_WAITING, [VISIT_ARRIVED])
    }

    /*
     * 开始接诊：`waiting → visiting`，并记 `started_at`（就诊时长由此算）。
     * ⚠ 只从 `waiting` 允许 —— 见 `visitTransitionAllowed`：到院/候诊是必须走的，
     *   否则"实际等了多久/有没有跳过候诊"就无从查证。
     */
    public func startVisit(appointmentId: Int64, doctorId: Int64, now: Int64): VisitOutcome {
        return transition(appointmentId, doctorId, VISIT_VISITING, [VISIT_WAITING],
                          stampCol: "started_at", stampValue: now)
    }

    /*
     * 完成就诊：**要求病历已锁定**（同一条 UPDATE 里带上这个前置条件），
     * 并顺手记下 `finished_at`（本次就诊的终点，与 `started_at` 一起给出实际时长）。
     * ⚠ 前置条件必须待在同一句 UPDATE 的 WHERE 里 —— 见 `transition` 的注释。
     */
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
