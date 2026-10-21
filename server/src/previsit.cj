/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 * previsit.cj —— 预问诊：六槽位多轮采集 + SSE 流式（不接模型，追问文本由规则生成）。
 *
 * 铁律：对话文本可流式；业务值（PrevisitForm）必须完整校验后一次性 JSON 返回，禁止流式。
 */

package qingzhou

import std.collection.*
import stdx.encoding.json.*

/*
 * 未采完判据：IFNULL(JSON_LENGTH(JSON_KEYS(form_json)), 0) < 槽位数 —— 数真实 JSON 键，与值内容无关。
 * 不能用 form_json = ''（开流即写入主诉），也不能 LIKE '%key%'（答案文本可含槽位名，误判成已完成）。
 * 不能省 IFNULL：坏 JSON 时 JSON_KEYS 返回 NULL，驱动 getInt 抛异常，会中断 create() 连带新会话建不出。
 */
func previsitSlotCountSql(): String {
    return "IFNULL(JSON_LENGTH(JSON_KEYS(form_json)), 0)"
}

/* 未采完：已填槽位数 < 总槽位数。 */
func previsitIncompleteSql(): String {
    return previsitSlotCountSql() + " < ${intakeSlots().size}"
}

func previsitCompleteSql(): String {
    return previsitSlotCountSql() + " >= ${intakeSlots().size}"
}

/* 会话清理阈值 */

/* 未采完会话 TTL 30 分钟：患者不会回来续答，与一次门诊候诊同量级。 */
public let PREVISIT_ABANDONED_TTL: Int64 = 1800

/* 同患者未完成会话上限 5：防反复开流不作答的滥用。 */
public let PREVISIT_MAX_OPEN: Int64 = 5

/* 同患者已完成问诊单上限 50：安全阀，只防无界增长；真实归档属病历域。 */
public let PREVISIT_MAX_DONE: Int64 = 50

/* 问诊槽位 */

/* 一个采集槽位（静态表）。顺序即采集顺序：病程 → 程度 → 伴随症状 → 既往史 → 过敏史。 */
public class IntakeSlot {
    public let key: String          // 落库用的字段名（英文，稳定）
    public let question: String     // 给患者看的问题
    public let hint: String         // 可选的作答提示（示例）
    public let maxLen: Int64        // 该字段允许的最大**字符**数
    /* 给医生看的短名：与 question 两套文案；取值必须与 intakePrefill() 的段名逐字一致。 */
    public let label: String

    public init(key: String, question: String, hint: String, maxLen: Int64, label: String) {
        this.key = key
        this.question = question
        this.hint = hint
        this.maxLen = maxLen
        this.label = label
    }
}

/*
 * 六个槽位：主诉/病程/程度/伴随/既往史/过敏史 —— 门诊最小可用集；不问身份证、住址（最小必要）。
 * 过敏史的「无」是有效答案（存值），与留空不同。
 */
public func intakeSlots(): Array<IntakeSlot> {
    return [
        IntakeSlot("chief", "您这次主要哪里不舒服？", "例如：咳嗽、胃痛、头晕", 200, "主诉"),
        IntakeSlot("duration", "这个情况持续多久了？", "例如：3 天、2 周、半年", 60, "病程"),
        IntakeSlot("severity", "对日常生活影响大吗？", "例如：轻微 / 影响睡眠 / 无法工作", 60, "程度"),
        /* 文案用「」而非 ASCII 双引号：后者是字符串定界符，写在字符串中间会提前结束字面量。 */
        IntakeSlot("associated", "还有其它不舒服吗？（没有就写「无」）", "例如：发热、恶心、乏力", 200, "伴随"),
        IntakeSlot("history", "以前有没有得过什么病、或长期吃药？", "例如：高血压 5 年，服降压药；或写「无」", 300, "既往史"),
        IntakeSlot("allergy", "有没有药物或食物过敏？", "例如：青霉素过敏；或写「无」", 200, "过敏史")
    ]
}

/*
 * 结构化问诊单（业务值）：只在校验通过后返回；answers 的键即 IntakeSlot.key。
 */
public class PrevisitForm {
    public var answers: Map<String, String> = HashMap<String, String>()
    public var updatedAt: Int64 = 0

    public func filled(): Int64 {
        var n: Int64 = 0
        for (s in intakeSlots()) {
            if (answers.contains(s.key)) {
                n = n + 1
            }
        }
        return n
    }

    public func complete(): Bool {
        for (s in intakeSlots()) {
            if (!answers.contains(s.key)) {
                return false
            }
        }
        return true
    }
}

public class PrevisitSession {
    public var id: String = ""
    public var patientId: Int64 = 0
    /* 绑定的挂号单 id，0 = 未绑定（服务端事实，不再依赖客户端本机存储）。 */
    public var appointmentId: Int64 = 0
    public var turn: Int64 = 0
    public var createdAt: Int64 = 0
    public var updatedAt: Int64 = 0
    public var form: PrevisitForm = PrevisitForm()

    /* 下一个待采集槽位。按"槽位是否有值"判定而非 turn：重试同一槽位天然幂等。 */
    public func nextSlot(): ?IntakeSlot {
        for (s in intakeSlots()) {
            if (!form.answers.contains(s.key)) {
                return Some(s)
            }
        }
        return None
    }
}

/* 答案写入结果：三种失败各自成字段（复用字段表达不同语义会漏判）。 */
public class PrevisitAnswerOutcome {
    public var ok: Bool = false
    public var noSuchSession: Bool = false
    /* 非空 = 该字段名不是已知槽位（客户端塞了自造键）。 */
    public var unknownSlot: String = ""
    public var tooLong: String = ""
    public var emptyValue: String = ""

    public func succeeded(): Bool {
        return ok
    }
}

/*
 * 会话落库 previsit_session（见 schema.cj）：多进程/重启不丢，且问诊单本身是要长期保留的医疗数据。
 */
public class PrevisitRepo {
    private let db: DbBackend

    public init(db: DbBackend) {
        this.db = db
    }

    /*
     * 建会话，返回 32 字节随机 id（64 hex，猜不到别人的会话）。顺手 pruneStale() + capSessions()：
     * 反复开流不作答会让这张表永久堆积。
     */
    public func create(patientId: Int64, now: Int64): String {
        let _p = pruneStale(now)
        let _c = capSessions(patientId, now)
        let sid = newToken()
        db.exec("INSERT INTO previsit_session (id, patient_id, turn, form_json, created_at, updated_at) " +
                "VALUES (?, ?, 0, '', ?, ?)",
                [DbStr(sid), DbInt(patientId), DbInt(now), DbInt(now)])
        return sid
    }

    /* 清理陈旧未采完会话；已完成的不在此删（属数据保留策略，由 capSessions 上限约束）。 */
    public func pruneStale(now: Int64): Int64 {
        return db.exec(
            "DELETE FROM previsit_session WHERE " + previsitIncompleteSql() + " AND updated_at < ?",
            [DbInt(now - PREVISIT_ABANDONED_TTL)])
    }

    /*
     * 把患者的会话按类型压到上限：未采完 PREVISIT_MAX_OPEN，已完成 PREVISIT_MAX_DONE。
     */
    public func capSessions(patientId: Int64, now: Int64): Int64 {
        var removed: Int64 = 0
        // ① 未采完会话：超出上限时丢最旧的
        let openRows = db.query(
            "SELECT COUNT(*) FROM previsit_session WHERE patient_id = ? AND " + previsitIncompleteSql(),
            [DbInt(patientId)])
        if (openRows.rowCount() > 0 && openRows.getInt(0, 0) >= PREVISIT_MAX_OPEN) {
            /* LIMIT 不能直接用在带子查询的 DELETE：改 id NOT IN (最新 N-1 条)；ORDER BY updated_at DESC, id DESC 保证同秒也确定。 */
            removed = removed + db.exec(
                "DELETE FROM previsit_session WHERE patient_id = ? AND " + previsitIncompleteSql() + " " +
                "AND id NOT IN (SELECT id FROM (SELECT id FROM previsit_session " +
                "WHERE patient_id = ? AND " + previsitIncompleteSql() + " " +
                "ORDER BY updated_at DESC, id DESC LIMIT ?) t)",
                [DbInt(patientId), DbInt(patientId), DbInt(PREVISIT_MAX_OPEN - 1)])
        }
        let doneRows = db.query(
            "SELECT COUNT(*) FROM previsit_session WHERE patient_id = ? AND " + previsitCompleteSql(),
            [DbInt(patientId)])
        if (doneRows.rowCount() > 0 && doneRows.getInt(0, 0) >= PREVISIT_MAX_DONE) {
            removed = removed + db.exec(
                "DELETE FROM previsit_session WHERE patient_id = ? AND " + previsitCompleteSql() + " " +
                "AND id NOT IN (SELECT id FROM (SELECT id FROM previsit_session " +
                "WHERE patient_id = ? AND " + previsitCompleteSql() + " " +
                "ORDER BY updated_at DESC, id DESC LIMIT ?) t)",
                [DbInt(patientId), DbInt(patientId), DbInt(PREVISIT_MAX_DONE - 1)])
        }
        return removed
    }

    /* 取会话。⚠ **必须带 patientId** —— 只按 id 取会让患者 A 读到 B 的问诊单。 */
    public func find(sid: String, patientId: Int64): ?PrevisitSession {
        let rs = db.query(
            "SELECT id, patient_id, turn, form_json, created_at, updated_at, appointment_id " +
            "FROM previsit_session WHERE id = ? AND patient_id = ?",
            [DbStr(sid), DbInt(patientId)])
        if (rs.rowCount() < 1) {
            return None
        }
        return Some(rowToSession(rs, 0))
    }

    /* 是否属于该患者（不区分"不存在"和"不是你的"）：区分会变成枚举会话 id 的 oracle。 */
    public func ownedBy(sid: String, patientId: Int64): Bool {
        if (sid.size == 0) {
            return false
        }
        return find(sid, patientId).isSome()
    }

    /*
     * 绑定挂号单：只绑属于该患者的会话（patient_id 写进 UPDATE）；允许重复绑同一单，禁止改绑到另一张单。
     * 返回"现在是否绑在这张单上"—— MySQL 在值不变时返回 0 行受影响，故 0 行时回读确认（幂等重放走这里）。
     */
    public func bindAppointment(sid: String, patientId: Int64, appointmentId: Int64): Bool {
        if (sid.size == 0 || appointmentId <= 0) {
            return false
        }
        let n = db.exec(
            "UPDATE previsit_session SET appointment_id = ? " +
            "WHERE id = ? AND patient_id = ? AND (appointment_id = 0 OR appointment_id = ?)",
            [DbInt(appointmentId), DbStr(sid), DbInt(patientId), DbInt(appointmentId)])
        if (n > 0) {
            return true
        }
        match (find(sid, patientId)) {
            case Some(s) => return s.appointmentId == appointmentId
            case None => return false
        }
    }

    /* 按挂号单取会话（医生读摘要）：SQL 带 patient_id，路由层校验失效也不漏别人的问诊单。 */
    public func findByAppointment(appointmentId: Int64, patientId: Int64): ?PrevisitSession {
        let rs = db.query(
            "SELECT id, patient_id, turn, form_json, created_at, updated_at, appointment_id " +
            "FROM previsit_session WHERE appointment_id = ? AND patient_id = ? " +
            "ORDER BY updated_at DESC, id DESC LIMIT 1",
            [DbInt(appointmentId), DbInt(patientId)])
        if (rs.rowCount() < 1) {
            return None
        }
        return Some(rowToSession(rs, 0))
    }

    /* 该患者最近一次已完成会话（存量兼容）：只在本单未绑定时用；HTTP 响应 bound 区分两种来源。 */
    public func latestCompleteForPatient(patientId: Int64): ?PrevisitSession {
        let rs = db.query(
            "SELECT id, patient_id, turn, form_json, created_at, updated_at, appointment_id " +
            "FROM previsit_session WHERE patient_id = ? AND " + previsitCompleteSql() + " " +
            "ORDER BY updated_at DESC, id DESC LIMIT 1",
            [DbInt(patientId)])
        if (rs.rowCount() < 1) {
            return None
        }
        return Some(rowToSession(rs, 0))
    }

    /* 行 → 会话（列顺序只有这一处：上面三个 SELECT 的列必须逐字一致）。 */
    private func rowToSession(rs: DbResultSet, row: Int64): PrevisitSession {
        let s = PrevisitSession()
        s.id = rs.getString(row, 0)
        s.patientId = rs.getInt(row, 1)
        s.turn = rs.getInt(row, 2)
        s.createdAt = rs.getInt(row, 4)
        s.updatedAt = rs.getInt(row, 5)
        s.form = previsitParseForm(rs.getString(row, 3))
        s.appointmentId = rs.getInt(row, 6)
        return s
    }

    /*
     * 记一个答案。校验三条：会话属于该患者（否则 noSuchSession → 404，不用 403：403 泄露 id 存在）、
     * 字段名是已知槽位、长度按字符数计（按字节会撕裂汉字）。
     */
    public func answer(sid: String, patientId: Int64, key: String, value: String,
                       now: Int64): PrevisitAnswerOutcome {
        let out = PrevisitAnswerOutcome()
        let found = find(sid, patientId)
        if (found.isNone()) {
            out.noSuchSession = true
            return out
        }
        let s = found.getOrThrow()
        var slot: ?IntakeSlot = None
        for (x in intakeSlots()) {
            if (x.key == key) {
                slot = Some(x)
            }
        }
        if (slot.isNone()) {
            /* 未知槽位必须明确拒绝：静默成功 = 客户端能往医疗记录里塞任意键。 */
            out.unknownSlot = key
            return out
        }
        let sl = slot.getOrThrow()
        let v = value.trimAscii()
        if (previsitCharLen(v) > sl.maxLen) {
            out.tooLong = key
            return out
        }
        /* 空值不写入：空 = 没答，与「无」（明确阴性）不同；否则医生会以为患者拒答。 */
        if (v.size == 0) {
            out.emptyValue = key
            out.ok = true
            return out
        }
        s.form.answers[key] = v
        s.turn = s.turn + 1
        /*
         * UPDATE 自己带 patient_id：不依赖前一步 find 的隐含前提，否则将来改 find 就是真正的越权写。
         */
        db.exec("UPDATE previsit_session SET form_json = ?, turn = ?, updated_at = ? " +
                "WHERE id = ? AND patient_id = ?",
                [DbStr(previsitFormJson(s.form)), DbInt(s.turn), DbInt(now), DbStr(sid),
                 DbInt(patientId)])
        out.ok = true
        return out
    }
}

/* 序列化成 JSON 存库：用 JsonObject 而非手拼，否则忘了转义双引号会写坏整张表单。 */
public func previsitFormJson(f: PrevisitForm): String {
    let o = JsonObject()
    for (s in intakeSlots()) {
        if (f.answers.contains(s.key)) {
            o.put(s.key, JsonString(f.answers[s.key]))
        }
    }
    return o.toString()
}

/* 解析失败不抛异常、退化为空表单（患者可重新作答；抛异常会让只读操作 500），但要留日志。 */
public func previsitParseForm(json: String): PrevisitForm {
    let f = PrevisitForm()
    if (json.size == 0) {
        return f
    }
    try {
        let v = JsonValue.fromStr(json)
        let o = v.asObject()
        for (s in intakeSlots()) {
            match (o.get(s.key)) {
                case Some(x) =>
                    if (x is JsonString) {
                        f.answers[s.key] = x.asString().getValue()
                    }
                case None => ()
            }
        }
    } catch (e: Exception) {
        /*
         * 坏数据 → 空表单是有意的；日志只留前 200 字符：form_json 含既往史/过敏史，全量等于把病历抄进日志。
         */
        let head = if (json.size > 200) { previsitTruncateChars(json, 200) + "…(已截断)" } else { json }
        println("[WARN] previsit form_json 解析失败，已退化为空表单（患者会看到未作答）。" +
                " 原因=${e.message} 原文前 200 字符=${head}")
    }
    return f
}

/*
 * 助手本轮要说的话，按句子切行 —— 可流式的那一半（返回 Array 才有内容可分）。
 * 规则：首次先复述主诉；中途带「第 N/6 项」进度；采完明确声明不替代医生诊断。
 */
public func previsitAssistantLines(s: PrevisitSession, justAnswered: ?String): Array<String> {
    let out = ArrayList<String>()
    let next = s.nextSlot()

    if (next.isNone()) {
        out.add("好的，我已经把您的就诊信息整理好了。")
        out.add("共 ${intakeSlots().size} 项，下面是**给医生看的**问诊单摘要，您可以在挂号时一并提交。")
        out.add("⚠ 这只是就诊前的信息采集，**不能替代医生诊断**；如症状加重请及时就医或前往急诊。")
        return out.toArray()
    }
    let sl = next.getOrThrow()

    if (s.turn == 0 && s.form.answers.contains("chief")) {
        out.add("明白了，您主要是「${s.form.answers["chief"]}」。")
        out.add("为了帮医生更快了解情况，我再问几个问题，一共 ${intakeSlots().size} 项。")
    } else {
        match (justAnswered) {
            case Some(k) =>
                if (k == "associated" || k == "history" || k == "allergy") {
                    out.add("好的，记下了。")
                } else {
                    out.add("好的。")
                }
            case None => ()
        }
    }
    out.add("第 ${s.form.filled() + 1}/${intakeSlots().size} 项：${sl.question}")
    if (sl.hint.size > 0) {
        out.add("（${sl.hint}）")
    }
    return out.toArray()
}

/*
 * data 用 JSON 而非裸文本：SSE 里换行是帧分隔符，裸 \n 会把一帧拆成两帧。
 * 结尾必须恰好 \n\n：少一个客户端会一直等下一行。
 */
public func sseFrame(event: String, payload: JsonObject): String {
    let o = JsonObject()
    o.put("event", JsonString(event))
    o.put("data", payload)
    return "data: ${o.toString()}\n\n"
}

/* 按字符截断：String 切片是字节偏移，[0..n] 会在多字节字符中间切断 ⇒ 非法 UTF-8。 */
public func previsitTruncateChars(s: String, n: Int64): String {
    let buf = ArrayList<Rune>()
    for (r in s.runes()) {
        if (buf.size >= n) {
            break
        }
        buf.add(r)
    }
    return String(buf.toArray())
}

/* 字符串的**字符**数（不是字节数）。 */
public func previsitCharLen(s: String): Int64 {
    var n: Int64 = 0
    for (r in s.runes()) {
        n = n + 1
    }
    return n
}
