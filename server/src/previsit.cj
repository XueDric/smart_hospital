/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 *
 * ===== previsit.cj —— P2 智能预问诊（多轮采集 + SSE 流式）==================
 *
 * ── 本文件的核心纪律（brief §5.2 那张表，必须分清两件事）──────────────────
 *
 *   | 场景 | 是否流式 | 理由 |
 *   | 预问诊**对话文本** | ✅ 可以流式 | 它就是自然语言，**不是业务值** |
 *   | 抽取出的**业务值**（问诊单） | ❌ **必须非流式 + 校验后返回** | 同分诊结论 |
 *
 *   这条区分是 brief 明确点名"最容易做错的地方"。所以本文件在结构上就把它分开：
 *     · `previsitAssistantLines()` 产出的是**要流出去的对话文本**（自然语言）
 *     · `PrevisitForm` 是**结构化业务值**（有类型、有校验、只走 JSON 一次性返回）
 *   两者**不共用**任何"拼字符串返回给客户端"的路径。
 *
 * ⚠⚠ 本轮**不接真模型**（与分诊同一个阻塞：brief §10 Q6 合规待决）。
 *   所以"追问文本"是**规则生成**的（固定的问诊顺序 + 按主诉微调措辞），
 *   而**不是**模型生成的。这一点在读代码时不会有歧义：
 *   文件里没有任何出站 HTTP 调用，也没有"模型"字样出现在产物上。
 *   接上模型时只需替换 `previsitAssistantLines()` ——
 *   会话状态机、业务值校验、流式帧格式**一行都不用改**。
 *
 * ── 为什么"对话文本"可以流式而"业务值"不行（把理由写下来，免得将来被"优化"掉）──
 *   对话文本流错了，患者看到半句话 —— 他只会再问一次，**无害**。
 *   业务值流错了（比如"过敏史：青霉素"先流出去、再改成"无过敏史"），
 *   客户端可能已经把它写进病历草稿 —— **那是医疗记录污染**。
 *   所以业务值**只有在完整、校验通过之后**才允许出现在响应里。
 */

package qingzhou

import std.collection.*
import stdx.encoding.json.*

/*
 * "问诊单**未采完**"的 SQL 片段 —— 由 `intakeSlots()` **生成**，不手写。
 *
 * ⚠⚠ 为什么必须生成、且判据不是"表单空不空"（我第一版写 `form_json = ''`，实测无效）：
 *
 *   我原以为"被放弃的会话"就是 `form_json = ''`。**错** ——
 *   `GET /previsit/stream?chief_complaint=...` 会**立刻把主诉写进表单**，
 *   于是刚开的会话 `form_json` 就已经是 `{"chief":"咳嗽"}`（非空）。
 *   实测连开 42 次 ⇒ 42 行全都 `form_json <> ''`，那条 DELETE 一行都匹配不到。
 *
 *   ⇒ 真正的判据是"**六个槽位齐不齐**"，不是"表单空不空"。
 *
 * ── 为什么用字符串包含来数槽位（而不是 JSON 函数）──────────────────────
 *   ① 本项目起步就定"不依赖 DB 高级特性"的路线（brief §5.1）；
 *      用 `JSON_CONTAINS_PATH` 会把"能不能跑"绑在 MySQL 的 JSON 支持上。
 *   ② 六个 key 都是英文字段名，且**两两不是彼此的子串**
 *      （chief / duration / severity / associated / history / allergy）
 *      ⇒ 用 `LIKE '%key%'` 数出现次数是安全的。
 *      ⚠ 这个前提必须成立：加新槽位时若取了别人的子串（如加 `chief2`），
 *      计数会偏大 ⇒ **`rpIncompleteRule` 用例会变红**（按类别扫，不靠人记）。
 *   ③ 片段由 `intakeSlots()` 生成 ⇒ 加槽位只改一处（"口径只留一处"）。
 */
func previsitSlotCountSql(): String {
    var s = "("
    var first = true
    for (sl in intakeSlots()) {
        if (!first) {
            s = s + " + "
        }
        // LIKE 的 % 是通配符；key 由我们自己的表定义，不含 % 或 _
        s = s + "(form_json LIKE '%${sl.key}%')"
        first = false
    }
    return s + ")"
}

/* "问诊单**未采完**"（槽位没齐）。 */
func previsitIncompleteSql(): String {
    return previsitSlotCountSql() + " < ${intakeSlots().size}"
}

/* "问诊单**已采完**"（槽位齐了）—— 与上面互补。 */
func previsitCompleteSql(): String {
    return previsitSlotCountSql() + " >= ${intakeSlots().size}"
}

/* ===================== 卫生阈值（会话清理）===================== */

/*
 * 被放弃会话的 TTL（秒）：30 分钟。
 *
 * 取值理由：患者中途离开后**不会再回来接着答**（他没有可恢复的入口，
 * 会话 id 只在当次前端的流里），所以未完成会话的"追问价值"很快归零。
 * 30 分钟与"一次门诊候诊"同量级，足够覆盖"答到一半去缴费再回来"。
 */
public let PREVISIT_ABANDONED_TTL: Int64 = 1800

/*
 * 同一患者**未完成**会话的保留上限。
 *
 * ⚠ 这个上限防的是**滥用**：反复 `GET /previsit/stream` 但不作答
 *   （复查实测连续 12 次就新增 12 行）。取 5 —— 正常患者不会有 5 个
 *   同时进行中的问诊；而连开 5 次以上的基本是脚本。
 */
public let PREVISIT_MAX_OPEN: Int64 = 5

/*
 * 同一患者**已完成**问诊单的保留上限。
 *
 * ⚠ 这是**安全阀**，不是保留策略：真实归档属 P4 病历域（要有明确的
 *   数据保留期与审计要求）。这里只保证"不会无界增长"。
 *   取 50：覆盖一个患者相当长一段时间的就诊记录。
 */
public let PREVISIT_MAX_DONE: Int64 = 50

/* ===================== 问诊槽位（静态表）===================== */

/*
 * 一个问诊槽位（要采集的一项信息）。
 *
 * ⚠ 这是**静态表**（照 `deptRules()` / `aiToolSpecs()` 的纪律）：
 *   顺序有意义 —— 采集顺序就是表里的顺序，先问"多久了"再问"多严重"，
 *   符合临床问诊习惯（现病史：起病时间 → 严重程度 → 伴随症状 → 诊疗经过）。
 */
public class IntakeSlot {
    public let key: String          // 落库用的字段名（英文，稳定）
    public let question: String     // 给患者看的问题
    public let hint: String         // 可选的作答提示（示例）
    public let maxLen: Int64        // 该字段允许的最大**字符**数

    public init(key: String, question: String, hint: String, maxLen: Int64) {
        this.key = key
        this.question = question
        this.hint = hint
        this.maxLen = maxLen
    }
}

/*
 * 问诊单的六个槽位。
 *
 * ⚠ 为什么是这六项（可解释，不是随手列的）：
 *   主诉 / 病程 / 程度 / 伴随症状 / 既往史 / 过敏史 ——
 *   这是门诊问诊的**最小可用集**：缺"过敏史"会开错药，缺"病程"无法判断急慢，
 *   缺"伴随症状"无法鉴别诊断。再少就不足以支撑医生接诊。
 *   刻意**不问**身份证号/住址等与本次就诊无关的信息 —— 最小必要原则。
 *
 * ⚠ 过敏史有 `none` 语义（"无过敏史"是**有效答案**，不是"没答"）：
 *   所以下面 `previsitFormComplete` 只判断"槽位是否有值"，
 *   而"无"会被当作一个合法的值存下来 —— 这与"留空"必须区分开。
 */
public func intakeSlots(): Array<IntakeSlot> {
    return [
        IntakeSlot("chief", "您这次主要哪里不舒服？", "例如：咳嗽、胃痛、头晕", 200),
        IntakeSlot("duration", "这个情况持续多久了？", "例如：3 天、2 周、半年", 60),
        IntakeSlot("severity", "对日常生活影响大吗？", "例如：轻微 / 影响睡眠 / 无法工作", 60),
        /*
         * ⚠ 提示语里的"无"用 **CJK 直角引号**（「」）而不是 ASCII 双引号：
         *   ASCII `"` 在仓颉里是**字符串定界符** ⇒ 写在字符串中间会把字面量提前结束
         *   （实测报 `unclosed delimiter: '('`）。中文文案里嵌引用一律用「」，
         *   既避开这个问题，排版上也更规范。
         */
        IntakeSlot("associated", "还有其它不舒服吗？（没有就写「无」）", "例如：发热、恶心、乏力", 200),
        IntakeSlot("history", "以前有没有得过什么病、或长期吃药？", "例如：高血压 5 年，服降压药；或写「无」", 300),
        IntakeSlot("allergy", "有没有药物或食物过敏？", "例如：青霉素过敏；或写「无」", 200)
    ]
}

/* ===================== 业务值：问诊单 ===================== */

/*
 * ★ 结构化问诊单 —— **业务值**，只在**全部槽位齐备并校验通过后**才返回。
 *
 * ⚠ 它绝不流式（见文件头）。`answers` 的键就是 `IntakeSlot.key`。
 */
public class PrevisitForm {
    public var answers: Map<String, String> = HashMap<String, String>()
    public var updatedAt: Int64 = 0

    /* 已填项数 / 总项数（进度给客户端用）。 */
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

/* 一个会话的状态。 */
public class PrevisitSession {
    public var id: String = ""
    public var patientId: Int64 = 0
    public var turn: Int64 = 0
    public var createdAt: Int64 = 0
    public var updatedAt: Int64 = 0
    public var form: PrevisitForm = PrevisitForm()

    /*
     * 下一个待采集的槽位；全部采完返回 None。
     *
     * ⚠ 判定依据是"**槽位是否有值**"，而不是 `turn`。
     *   用 `turn` 推进序号会让"重复提交同一槽位"（网络重试）跳过一个字段 ——
     *   而按值判定天然幂等：重试同一个答案不会改变状态。
     */
    public func nextSlot(): ?IntakeSlot {
        for (s in intakeSlots()) {
            if (!form.answers.contains(s.key)) {
                return Some(s)
            }
        }
        return None
    }
}

/* ===================== 仓储 ===================== */

/*
 * 答案写入结果。
 *
 * ⚠ 三种失败必须**各自成字段**（我第一版把"未知字段"塞进 `tooLong` 复用，
 *   结果实现里给未知字段返回了 ok=true ⇒ 客户端可以往表单塞任意键）。
 *   教训：**用"复用字段"表达不同语义，迟早会在某个分支上漏判。**
 */
public class PrevisitAnswerOutcome {
    public var ok: Bool = false
    public var noSuchSession: Bool = false
    /* 非空 = 该字段名不是已知槽位（客户端塞了自造键）。 */
    public var unknownSlot: String = ""
    /* 非空 = 该字段超长（字段名）。 */
    public var tooLong: String = ""
    /* 非空 = 该字段值为空（不算失败，只是没写入；留档便于调用方解释）。 */
    public var emptyValue: String = ""

    public func succeeded(): Bool {
        return ok
    }
}

/*
 * 预问诊会话仓储。
 *
 * ⚠ 会话**落库**而不是放内存：
 *   ① 多进程/重启后会话不丢（本项目已定"不做 Redis"的路线，见 brief §5.1）；
 *   ② 问诊单本身就是**要长期保留的医疗数据**（属于患者档案的一部分），
 *      迟早要落库 —— 现在落库，将来不必迁移。
 *
 * ⚠ 它**不属于**号源域，也不属于内存 Store 负责的配套域：
 *   它是**直接 SQL** 路径（与 `schedule`/`appointment` 同一范式），
 *   且**不参与** ADR-0001 §4.3 的范围锁死（那里锁的是"哪张表归谁写"）。
 *   所以它有自己的表 `previsit_session`（见 schema.cj）。
 */
public class PrevisitRepo {
    private let db: DbBackend

    public init(db: DbBackend) {
        this.db = db
    }

    /*
     * 建会话。返回会话 id（32 字节随机 = 64 hex，与令牌同强度，猜不到别人的会话）。
     *
     * ★ 顺手做两件**卫生**工作（2026-10-07 按第六份复查补）：
     *   ① `pruneStale()` —— 清理陈旧会话；
     *   ② 限制同一患者的**未完成**会话数，超出则丢掉最旧的。
     *
     * ── 原缺陷（复查实测，我也复现了）────────────────────────────────────────
     *   连续 12 次 `GET /previsit/stream` ⇒ `previsit_session` **新增 12 行**，
     *   而全仓**没有任何地方**清理它（唯一的 DELETE 在测试夹具里）。
     *   反复开流但不作答的客户端会让这张表**永久堆积**。
     *
     *   ⚠ 与本仓既有的卫生习惯不一致：`pruneTokens`（签发令牌时顺手清过期）
     *     与 `pruneAttempts`（登录成功时顺手清陈旧计数）都是这么做的。
     *     **同一类问题在别处已有解法，新表就该照做** —— 这正是"按类别扫"该覆盖到的。
     *
     * ── 为什么阈值分两档（可解释，不是拍脑袋）──────────────────────────────
     *   · **未采完**会话（槽位没齐，见 previsitIncompleteSql）：患者中途放弃的，30 分钟后没有任何
     *     追问价值（他不会再回来接着答），且它们数量最大 ⇒ TTL 短。
     *   · **已完成**会话（有表单）：是**患者档案素材**，要留得久 ⇒ TTL 长，
     *     且**由保留上限**约束（不是无限留）。真实归档属 P4 病历域，这里只防无界增长。
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

    /*
     * 清理陈旧会话（返回删除行数）。
     *
     * ⚠ 只删**未采完**的（判据见 `previsitIncompleteSql`）：已完成的问诊单
     *   **不在这里删** —— 它是医疗记录素材，删除属于"数据保留策略"，
     *   不该由一个顺手 prune 决定。已完成会话的增长由 `capSessions` 的上限约束。
     */
    public func pruneStale(now: Int64): Int64 {
        return db.exec(
            "DELETE FROM previsit_session WHERE " + previsitIncompleteSql() + " AND updated_at < ?",
            [DbInt(now - PREVISIT_ABANDONED_TTL)])
    }

    /*
     * 把某患者的会话数压到上限内（返回删除行数）。
     *
     * ⚠ 只压**未采完**会话：已完成的问诊单是医疗记录，不能因为"开了太多新会话"
     *   而被顶掉。所以两个上限是**分开**的：
     *     · 未采完：`PREVISIT_MAX_OPEN`（防滥用：反复开流）
     *     · 已完成：`PREVISIT_MAX_DONE`（防无界增长；安全阀，不是保留策略）
     */
    public func capSessions(patientId: Int64, now: Int64): Int64 {
        var removed: Int64 = 0
        // ① 未采完会话：超出上限时丢最旧的
        let openRows = db.query(
            "SELECT COUNT(*) FROM previsit_session WHERE patient_id = ? AND " + previsitIncompleteSql(),
            [DbInt(patientId)])
        if (openRows.rowCount() > 0 && openRows.getInt(0, 0) >= PREVISIT_MAX_OPEN) {
            /*
             * 删掉"除了最新 N-1 条之外"的未采完会话。
             *
             * ⚠ `LIMIT` 不能直接用在带子查询的 DELETE 里（MySQL 限制），
             *   所以用 `id NOT IN (子查询取最新 N-1 条)` 的写法。
             *   子查询按 `updated_at DESC, id DESC` 排序 —— 加 `id` 是为了
             *   **同秒内也确定**（否则同一时间戳的多条顺序随机，测试会抖）。
             */
            removed = removed + db.exec(
                "DELETE FROM previsit_session WHERE patient_id = ? AND " + previsitIncompleteSql() + " " +
                "AND id NOT IN (SELECT id FROM (SELECT id FROM previsit_session " +
                "WHERE patient_id = ? AND " + previsitIncompleteSql() + " " +
                "ORDER BY updated_at DESC, id DESC LIMIT ?) t)",
                [DbInt(patientId), DbInt(patientId), DbInt(PREVISIT_MAX_OPEN - 1)])
        }
        // ② 已完成会话：安全阀（超出则丢最旧的）
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
            "SELECT id, patient_id, turn, form_json, created_at, updated_at " +
            "FROM previsit_session WHERE id = ? AND patient_id = ?",
            [DbStr(sid), DbInt(patientId)])
        if (rs.rowCount() < 1) {
            return None
        }
        let s = PrevisitSession()
        s.id = rs.getString(0, 0)
        s.patientId = rs.getInt(0, 1)
        s.turn = rs.getInt(0, 2)
        s.createdAt = rs.getInt(0, 4)
        s.updatedAt = rs.getInt(0, 5)
        s.form = previsitParseForm(rs.getString(0, 3))
        return Some(s)
    }

    /*
     * 记一个答案。
     *
     * 校验（三条，缺一条都会让业务值不可信）：
     *   ① 会话存在且属于该患者（否则 noSuchSession —— HTTP 层映射 404，**不是 403**：
     *      用 403 会泄露"这个 id 存在但不属于你"，那是枚举 oracle）；
     *   ② 字段名必须是**已知槽位**（防止客户端塞任意键进表单）；
     *   ③ 长度上限（按**字符**数，见 `previsitTruncateChars` —— 按字节会撕裂汉字）。
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
        // ② 已知槽位
        var slot: ?IntakeSlot = None
        for (x in intakeSlots()) {
            if (x.key == key) {
                slot = Some(x)
            }
        }
        if (slot.isNone()) {
            /*
             * ★ 未知槽位必须**明确拒绝**（不能静默成功）。
             *   静默成功 = 客户端可以往 `form_json` 里塞任意键，
             *   而问诊单是**要给医生看的医疗记录** —— 里面出现没人认识的字段，
             *   轻则困惑、重则被误读成有效的临床信息。
             */
            out.unknownSlot = key
            return out
        }
        let sl = slot.getOrThrow()
        let v = value.trimAscii()
        // ③ 长度上限（按**字符**数，不按字节 —— 按字节会误判中文并可能切坏）
        if (previsitCharLen(v) > sl.maxLen) {
            out.tooLong = key
            return out
        }
        /*
         * ⚠ 空值**不写入**：空串在语义上是"没答"，与 `无`（明确的"没有"）不同。
         *   若把空串当答案存下，问诊单会出现"既往史 = 空"这种无法解释的值 ——
         *   而医生看到空值会以为"问了但患者拒答"，看到"无"才知道是阴性。
         */
        if (v.size == 0) {
            out.emptyValue = key
            out.ok = true
            return out
        }
        s.form.answers[key] = v
        s.turn = s.turn + 1
        /*
         * ★ 复查第 6 份第 4 条：`WHERE` 原来只带 `id`，靠前一步 `find(sid, patientId)`
         *   把关。会话归属**不可变**（`patient_id` 建表后从不更新），所以那一步之后
         *   `sid` 确实属于该患者 —— **不可利用**。但"安全性依赖两步之间的隐含前提"
         *   是脆的：将来谁把 `find` 换成别的查询、或加了"会话可转移"的功能，
         *   这里就会变成一个**真正的越权写**。
         *   ⇒ 补上 `patient_id` 条件，让这条 UPDATE **自己**就是安全的。
         */
        db.exec("UPDATE previsit_session SET form_json = ?, turn = ?, updated_at = ? " +
                "WHERE id = ? AND patient_id = ?",
                [DbStr(previsitFormJson(s.form)), DbInt(s.turn), DbInt(now), DbStr(sid),
                 DbInt(patientId)])
        out.ok = true
        return out
    }
}

/* ===================== 表单序列化（业务值的持久化形式）===================== */

/*
 * 把问诊单序列化成 JSON 字符串（存库用）。
 *
 * ⚠ 用框架的 `JsonObject` 而不是手工拼字符串 —— 手工拼就必须自己处理转义，
 *   而"忘了转义引号"会让一个含 `"` 的答案把整张表单写坏（且很难查）。
 */
public func previsitFormJson(f: PrevisitForm): String {
    let o = JsonObject()
    for (s in intakeSlots()) {
        if (f.answers.contains(s.key)) {
            o.put(s.key, JsonString(f.answers[s.key]))
        }
    }
    return o.toString()
}

/*
 * 从 JSON 字符串还原问诊单。
 *
 * ⚠ 解析失败**不抛异常**，返回空表单：库里一条坏 JSON 不该让整个会话不可用
 *   （患者可以重新作答；而抛异常会让"查看问诊单"这个只读操作也 500）。
 */
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
                    // 只接受字符串；其它类型视作脏数据丢弃（不猜、不强制转换）
                    if (x is JsonString) {
                        f.answers[s.key] = x.asString().getValue()
                    }
                case None => ()
            }
        }
    } catch (e: Exception) {
        /*
         * ★ 坏数据 → 空表单（见上面说明：这是**有意**的，避免只读操作 500）。
         *
         * ⚠ 复查第 6 份第 5 条指出：**静默**返回空表单会丢审计留痕 ——
         *   患者说"我明明答了，怎么是空的"时，运维查不出原因。
         *   ⇒ 保留"不抛异常"的行为（那是对的），但**留下日志**：
         *     谁（哪条会话）的 form_json 坏了、坏成什么样（截断到 200 字符）。
         *
         * ⚠ 日志里**不放完整原文**：`form_json` 含既往史/过敏史 —— 那是敏感医疗数据，
         *   打全量等于把病历抄进日志文件（日志的访问控制通常比库弱）。
         *   200 字符 + 明显截断标记足够定位问题，且不足以泄露一份完整病史。
         */
        let head = if (json.size > 200) { previsitTruncateChars(json, 200) + "…(已截断)" } else { json }
        println("[WARN] previsit form_json 解析失败，已退化为空表单（患者会看到未作答）。" +
                " 原因=${e.message} 原文前 200 字符=${head}")
    }
    return f
}

/* ===================== 对话文本（可流式的那一半）===================== */

/*
 * 生成"助手这一轮要说的话"，按**句子**切成若干行 —— 这就是要流出去的对话文本。
 *
 * ★ 返回 `Array<String>` 而不是一个 String，是为了让"流式"这件事有内容可分：
 *   一次写完整个文本不算流式（那是伪装成 SSE 的普通响应）。
 *
 * ⚠ 本轮**不接模型**：这些文本是规则生成的（见文件头）。
 *   接模型时只替换本函数，其余（会话状态机 / 流式帧 / 业务值校验）都不动。
 *
 * 三条规则（都可解释）：
 *   ① 首次进入：先回应主诉（**复述**患者的话，让他确认没被误解），再问下一个槽位；
 *   ② 中途：直接问下一个槽位，并带上进度（"第 3/6 项"）让患者知道还要多久；
 *   ③ 全部采完：明确告诉患者"已生成问诊单"，并说明它**不替代医生诊断**。
 *
 * ⚠ 第 ③ 条那句免责不是客套：预问诊的输出是**给医生看的素材**，
 *   不是诊断结论。不写清楚，患者会以为系统已经"看完病了"。
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

    // ① 首次进入：先复述主诉
    if (s.turn == 0 && s.form.answers.contains("chief")) {
        out.add("明白了，您主要是「${s.form.answers["chief"]}」。")
        out.add("为了帮医生更快了解情况，我再问几个问题，一共 ${intakeSlots().size} 项。")
    } else {
        match (justAnswered) {
            case Some(k) =>
                // 对"无"这类否定答案给一句确认，避免患者以为没收到
                if (k == "associated" || k == "history" || k == "allergy") {
                    out.add("好的，记下了。")
                } else {
                    out.add("好的。")
                }
            case None => ()
        }
    }
    // ② 问下一个槽位（带进度）
    out.add("第 ${s.form.filled() + 1}/${intakeSlots().size} 项：${sl.question}")
    if (sl.hint.size > 0) {
        out.add("（${sl.hint}）")
    }
    return out.toArray()
}

/* ===================== SSE 帧 ===================== */

/*
 * 构造一个 SSE 帧（`data: <json>\n\n`）。
 *
 * ⚠ 为什么 data 用 **JSON** 而不是裸文本：
 *   SSE 协议里换行是**帧分隔符**，裸文本里的 `\n` 会把一帧拆成两帧
 *   （患者会看到半句话，而且客户端解析出的 JSON 也断了）。
 *   JSON 把换行转义成 `\n` 两个字符 ⇒ 帧里永远没有裸换行。
 *   已由 `previsit-test` 断言"帧内不含裸换行"。
 *
 * ⚠ 必须**恰好**以 `\n\n` 结尾：`\n` 只是行结束，`\n\n` 才是"事件结束"。
 *   少一个 `\n` 客户端会一直等下一行（表现为"卡住不动"）。
 */
public func sseFrame(event: String, payload: JsonObject): String {
    let o = JsonObject()
    o.put("event", JsonString(event))
    o.put("data", payload)
    return "data: ${o.toString()}\n\n"
}

/*
 * 把一个字符串按**字符**截断到 n 个字符。
 *
 * ⚠ 存在的唯一理由：`String` 的切片是**字节**偏移，直接 `[0..n]` 会在多字节
 *   字符中间切断 ⇒ 非法 UTF-8。这与 `triageTruncateChars` 是同一个坑
 *   （本项目已为此吃过一次 500）——**凡是要按长度截断用户输入，都必须走字符空间**。
 */
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
