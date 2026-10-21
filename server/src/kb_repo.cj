package qingzhou

import std.collection.*
import stdx.encoding.json.*

/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 * kb_repo.cj —— 知识库仓储：文档 CRUD、切块落库、两条检索路；算法在 domain_kb.cj。
 * 改正文必须让旧块全部消失：先按 (doc_id, seq) upsert 新块，再删 seq >= 新块数的尾部旧块。
 * 只做前者会留幽灵块（召回已删内容），只做后者中途失败会丢整篇块；两条路的分数不可混排。
 */

/* 常量 */

/*
 * 一次检索最多扫描的块数；超出部分不会被检索到，且不报错。
 * 响应带 scanned、stats() 回报 scan_limit_reached —— 触顶必须可观测。
 */
public let KB_SCAN_LIMIT: Int64 = 5000

/* 知识库文档（kb_doc 的一行）。 */
public class KbDoc {
    public var id: Int64 = 0
    public var title: String = ""
    public var category: String = ""
    public var body: String = ""
    public var enabled: Bool = true
    public var updatedBy: Int64 = 0
    public var createdAt: Int64 = 0
    public var updatedAt: Int64 = 0
    /* 派生：块数（列表页要显示，避免 N+1）。 */
    public var chunkCount: Int64 = 0
}

/* 写入结果；不抛异常，可预期的业务拒绝靠返回值表达。 */
public class KbWriteOutcome {
    public var ok: Bool = false
    public var id: Int64 = 0
    public var notFound: Bool = false
    /* title 唯一键冲突 ⇒ 409。 */
    public var duplicate: Bool = false
    public var invalid: Bool = false
    public var detail: String = ""

    public func markOk(newId: Int64): KbWriteOutcome {
        this.ok = true
        this.id = newId
        return this
    }

    public func markInvalid(why: String): KbWriteOutcome {
        this.invalid = true
        this.detail = why
        return this
    }
}

/* 检索结果；来源标注调用方必须如实透传。 */
public class KbSearchResult {
    public var hits: Array<KbHit> = Array<KbHit>()
    /* "keyword" | "vector"，不可省。 */
    public var source: String = KB_SOURCE_KEYWORD
    /* 扫过多少个块（排障用）。 */
    public var scanned: Int64 = 0
    /* 没有向量的块数（向量路覆盖度；关键词路恒为 0）。 */
    public var missingVectors: Int64 = 0
}

/* 仓储 */

public class KbRepo {
    private let db: DbBackend

    public init(db: DbBackend) {
        this.db = db
    }

    /* 列表；块数用一次 GROUP BY 取回，不能逐行查（N+1）。 */
    public func listDocs(includeDisabled!: Bool = true): Array<KbDoc> {
        var sql = "SELECT d.id, d.title, d.category, d.body, d.enabled, d.updated_by, " +
                  "d.created_at, d.updated_at, IFNULL(c.n, 0) AS chunk_count " +
                  "FROM kb_doc d LEFT JOIN " +
                  "(SELECT doc_id, COUNT(*) AS n FROM kb_chunk GROUP BY doc_id) c " +
                  "ON c.doc_id = d.id"
        if (!includeDisabled) {
            sql = sql + " WHERE d.enabled = 1"
        }
        sql = sql + " ORDER BY d.id DESC"
        let rs = db.query(sql, Array<DbValue>())
        let out = ArrayList<KbDoc>()
        var i: Int64 = 0
        while (i < rs.rowCount()) {
            out.add(kbFillDoc(rs, i))
            i = i + 1
        }
        return out.toArray()
    }

    public func findById(id: Int64): ?KbDoc {
        let rs = db.query(
            "SELECT d.id, d.title, d.category, d.body, d.enabled, d.updated_by, " +
            "d.created_at, d.updated_at, IFNULL(c.n, 0) AS chunk_count " +
            "FROM kb_doc d LEFT JOIN " +
            "(SELECT doc_id, COUNT(*) AS n FROM kb_chunk GROUP BY doc_id) c " +
            "ON c.doc_id = d.id WHERE d.id = ?", [DbInt(id)])
        if (rs.rowCount() == 0) {
            return None
        }
        return Some(kbFillDoc(rs, 0))
    }

    /* 建文档：落库后立刻切块；校验放在仓储里，测试与 CLI 才走同一套语义。 */
    public func create(title: String, category: String, body: String,
                       actorId: Int64, now: Int64): KbWriteOutcome {
        let out = KbWriteOutcome()
        let why = kbValidate(title, category, body)
        if (why.size > 0) {
            return out.markInvalid(why)
        }
        /*
         * 直接 INSERT、不先查（先查后插是 TOCTOU）：靠 uk_kb_doc_title 兜底，冲突交给 kbClassifyDuplicate 分类。
         */
        let ins = kbExecTolerant(db,
            "INSERT INTO kb_doc (title, category, body, enabled, updated_by, created_at, updated_at) " +
            "VALUES (?, ?, ?, 1, ?, ?, ?)",
            [DbStr(title.trimAscii()), DbStr(category.trimAscii()), DbStr(body), DbInt(actorId),
             DbInt(now), DbInt(now)], returnInsertId: true)
        if (!ins.ok) {
            return kbClassifyDuplicate(ins.message, title.trimAscii(), out)
        }
        let id = ins.generatedId
        kbRechunk(id, body, now)
        return out.markOk(id)
    }

    /*
     * 改文档；改正文即重新切块。changedBody 由本函数内部处理，这里只把「正文变没变」暴露给调用方。
     */
    public func update(id: Int64, title: String, category: String, body: String,
                       enabled: Bool, actorId: Int64, now: Int64): KbWriteOutcome {
        let out = KbWriteOutcome()
        match (findById(id)) {
            case None =>
                out.notFound = true
                return out
            case Some(_) => ()
        }
        let why = kbValidate(title, category, body)
        if (why.size > 0) {
            return out.markInvalid(why)
        }
        let up = kbExecTolerant(db,
            "UPDATE kb_doc SET title = ?, category = ?, body = ?, enabled = ?, " +
            "updated_by = ?, updated_at = ? WHERE id = ?",
            [DbStr(title.trimAscii()), DbStr(category.trimAscii()), DbStr(body),
             DbInt(if (enabled) { 1 } else { 0 }), DbInt(actorId), DbInt(now), DbInt(id)])
        if (!up.ok) {
            return kbClassifyDuplicate(up.message, title.trimAscii(), out)
        }
        /*
         * 无条件重切：不做「正文没变就跳过」的优化 —— 比较上万字的正文成本与重切相当，却多一条漏切风险。
         */
        kbRechunk(id, body, now)
        return out.markOk(id)
    }

    /*
     * 删文档连带真删块：块不被任何业务数据引用，留着只会污染检索。要停用请用 enabled = 0。
     */
    public func remove(id: Int64): KbWriteOutcome {
        let out = KbWriteOutcome()
        match (findById(id)) {
            case None =>
                out.notFound = true
                return out
            case Some(_) => ()
        }
        db.exec("DELETE FROM kb_chunk WHERE doc_id = ?", [DbInt(id)])
        db.exec("DELETE FROM kb_doc WHERE id = ?", [DbInt(id)])
        return out.markOk(id)
    }

    /*
     * 重新切块并落库，返回落库后的块数；旧块必须消失（见文件头）。
     */
    public func kbRechunkPublic(docId: Int64, body: String, now: Int64): Int64 {
        return kbRechunk(docId, body, now)
    }

    private func kbRechunk(docId: Int64, body: String, now: Int64): Int64 {
        let pieces = kbChunk(body)
        /*
         * 先 upsert 新块；chars 存字符数而不是字节数 —— 该字段用来判断块长是否合理。
         */
        var i: Int64 = 0
        for (p in pieces) {
            db.exec(
                "INSERT INTO kb_chunk (doc_id, seq, content, chars, embedding, embedded_at, created_at) " +
                "VALUES (?, ?, ?, ?, NULL, 0, ?) " +
                "ON DUPLICATE KEY UPDATE content = VALUES(content), chars = VALUES(chars), " +
                /* 正文变了 ⇒ 旧向量必须作废（它对应的是旧文本）。 */
                "embedding = NULL, embedded_at = 0",
                [DbInt(docId), DbInt(i), DbStr(p), DbInt(previsitCharLen(p)), DbInt(now)])
            i = i + 1
        }
        /* 再清掉文档变短留下的尾部旧块（seq >= 新块数）。 */
        db.exec("DELETE FROM kb_chunk WHERE doc_id = ? AND seq >= ?", [DbInt(docId), DbInt(i)])
        return i
    }

    /*
     * 关键词检索（默认路径，永远可用）；一次读回候选块再内存打分：比 N 次查询快，且同一响应内结果一致。
     */
    public func searchKeyword(query: String, topN!: Int64 = KB_SEARCH_TOP_N): KbSearchResult {
        let res = KbSearchResult()
        res.source = KB_SOURCE_KEYWORD
        let qTokens = kbTokens(query)
        if (qTokens.size == 0) {
            /* 查询里没有可检索成分（如纯标点）⇒ 空结果，不返回随机块。 */
            return res
        }
        let rows = kbLoadChunks()
        res.scanned = rows.size
        let scored = ArrayList<KbHit>()
        for (r in rows) {
            let s = kbKeywordScore(qTokens, r.content)
            if (s > 0.0) {
                r.score = s
                r.source = KB_SOURCE_KEYWORD
                scored.add(r)
            }
        }
        res.hits = kbTakeTop(kbSortHits(scored.toArray()), topN)
        return res
    }

    /*
     * 向量检索；没有向量的块跳过并计入 missingVectors，让调用方能判断是否该改走关键词路。
     */
    public func searchVector(queryVec: Array<Float64>, topN!: Int64 = KB_SEARCH_TOP_N): KbSearchResult {
        let res = KbSearchResult()
        res.source = KB_SOURCE_VECTOR
        if (queryVec.size == 0) {
            return res
        }
        let rows = kbLoadChunks()
        res.scanned = rows.size
        let scored = ArrayList<KbHit>()
        var missing: Int64 = 0
        for (r in rows) {
            if (r.embedding.size == 0) {
                missing = missing + 1
                continue
            }
            let s = kbCosine(queryVec, r.embedding)
            /*
             * 粗筛阈值 > 0（余弦可为负）；不设更高阈值：定高了会什么都检索不到，合适值取决于 embedding 模型。
             */
            if (s > 0.0) {
                r.score = s
                r.source = KB_SOURCE_VECTOR
                scored.add(r)
            }
        }
        res.missingVectors = missing
        res.hits = kbTakeTop(kbSortHits(scored.toArray()), topN)
        return res
    }

    /*
     * 写入某块向量；只改 embedding/embedded_at，不动 content，否则「向量对应哪个文本」不可信。
     */
    public func setEmbedding(chunkId: Int64, vec: Array<Float64>, now: Int64): Bool {
        if (vec.size == 0) {
            return false
        }
        db.exec("UPDATE kb_chunk SET embedding = ?, embedded_at = ? WHERE id = ?",
                [DbStr(kbVectorToJson(vec)), DbInt(now), DbInt(chunkId)])
        return true
    }

    /* 还没有向量的块（向量化流程的输入）。 */
    public func pendingChunks(limit: Int64): Array<KbHit> {
        let rs = db.query(
            "SELECT c.id, c.doc_id, c.seq, c.content, d.title, d.category " +
            "FROM kb_chunk c JOIN kb_doc d ON d.id = c.doc_id " +
            "WHERE c.embedding IS NULL AND d.enabled = 1 ORDER BY c.id ASC LIMIT ?",
            [DbInt(limit)])
        let out = ArrayList<KbHit>()
        var i: Int64 = 0
        while (i < rs.rowCount()) {
            let h = KbHit()
            h.chunkId = rs.getInt(i, 0)
            h.docId = rs.getInt(i, 1)
            h.seq = rs.getInt(i, 2)
            h.content = rs.getString(i, 3)
            h.title = rs.getString(i, 4)
            h.category = rs.getString(i, 5)
            out.add(h)
            i = i + 1
        }
        return out.toArray()
    }

    /* 知识库规模（看板用；真实计数，不编造）。 */
    public func stats(): JsonObject {
        let o = JsonObject()
        o.put("docs", JsonInt(kbCount1(db, "SELECT COUNT(*) FROM kb_doc")))
        o.put("docs_enabled", JsonInt(kbCount1(db, "SELECT COUNT(*) FROM kb_doc WHERE enabled = 1")))
        let all = kbCount1(db, "SELECT COUNT(*) FROM kb_chunk")
        let embedded = kbCount1(db, "SELECT COUNT(*) FROM kb_chunk WHERE embedding IS NOT NULL")
        o.put("chunks", JsonInt(all))
        o.put("chunks_embedded", JsonInt(embedded))
        /*
         * 向量覆盖率如实给出：它直接决定向量路能不能用；0% 时调用方应走关键词路。
         */
        var pct: Int64 = 0
        if (all > 0) {
            pct = embedded * 100 / all
        }
        o.put("embedding_coverage_pct", JsonInt(pct))
        /*
         * 检索上限一并回报，并直接给出「是否触顶」的布尔结论：能被静默触发的上限必须有显式信号。
         */
        o.put("scan_limit", JsonInt(KB_SCAN_LIMIT))
        o.put("scan_limit_reached", JsonBool(all > KB_SCAN_LIMIT))
        o.put("scan_limit_note", JsonString(
            "检索最多扫描 scan_limit 个块（按 id 升序）；chunks 超过它时，后面的块**不会被检索到**。" +
            "scan_limit_reached=true 表示已触顶，需要分片或缩库。"))
        /*
         * 口径说明必须与数据同源：embedding_coverage_pct 为 0 是当前常态（DeepSeek 无 embeddings 端点），
         * 不解释会被当成功能故障；放在同一对象里，任何调用方都自动带上解释。
         */
        o.put("embedding_note", JsonString(
            "embedding_coverage_pct 为 0 表示尚无向量（当前检索走关键词路，source=keyword）。" +
            "本版本 DeepSeek 未提供 embeddings 端点，故向量路需另配支持 embedding 的服务。"))
        return o
    }

    /*
     * 一次读回启用文档的所有块；只读 enabled = 1 —— 停用文档不该被检索到，这是检索语义的一部分。
     */
    private func kbLoadChunks(): Array<KbHit> {
        let rs = db.query(
            "SELECT c.id, c.doc_id, c.seq, c.content, d.title, d.category, c.embedding " +
            "FROM kb_chunk c JOIN kb_doc d ON d.id = c.doc_id " +
            "WHERE d.enabled = 1 ORDER BY c.id ASC LIMIT ?", [DbInt(KB_SCAN_LIMIT)])
        let out = ArrayList<KbHit>()
        var i: Int64 = 0
        while (i < rs.rowCount()) {
            let h = KbHit()
            h.chunkId = rs.getInt(i, 0)
            h.docId = rs.getInt(i, 1)
            h.seq = rs.getInt(i, 2)
            h.content = rs.getString(i, 3)
            h.title = rs.getString(i, 4)
            h.category = rs.getString(i, 5)
            /* embedding 列可为 NULL ⇒ 用 getNullable；不赌驱动对 NULL 的 getString 行为。 */
            match (rs.getNullable(i, 6)) {
                case Some(s) => h.embedding = kbVectorFromJson(s)
                case None => ()
            }
            out.add(h)
            i = i + 1
        }
        return out.toArray()
    }

    private func kbTakeTop(sorted: Array<KbHit>, n: Int64): Array<KbHit> {
        let out = ArrayList<KbHit>()
        var i: Int64 = 0
        while (i < sorted.size && i < n) {
            out.add(sorted[i])
            i = i + 1
        }
        return out.toArray()
    }
}

/*
 * 文档字段校验，空串表示通过；同时挡最明显的个人信息形态（身份证/手机号）。
 * 检索命中片段会随提示词出站给第三方模型 ⇒ 知识库不得放患者信息；自由文本无法用代码保证，姓名等仍靠人工把关。
 */
public func kbValidate(title: String, category: String, body: String): String {
    let t = title.trimAscii()
    if (t.size == 0) {
        return "标题不能为空"
    }
    if (previsitCharLen(t) > KB_TITLE_MAX_CHARS) {
        return "标题最长 ${KB_TITLE_MAX_CHARS} 字"
    }
    if (baseHasControlChar(t)) {
        return "标题不能含控制字符"
    }
    if (category.trimAscii().size > 32) {
        return "分类最长 32 字"
    }
    if (baseHasControlChar(category)) {
        return "分类不能含控制字符"
    }
    let b = body.trimAscii()
    if (b.size == 0) {
        return "正文不能为空"
    }
    if (previsitCharLen(b) > KB_BODY_MAX_CHARS) {
        return "正文最长 ${KB_BODY_MAX_CHARS} 字"
    }
    let hit = kbLooksLikePersonalInfo(b)
    if (hit.size > 0) {
        return "正文疑似含个人信息（${hit}）—— 知识库是**公开可检索**的，" +
               "检索片段会随提示词发给第三方模型，请勿写入患者信息"
    }
    return ""
}

/*
 * 是否含明显的个人信息形态：只认手机号与身份证两种，刻意窄 —— 误报会让人写不了正常文档。
 */
public func kbLooksLikePersonalInfo(text: String): String {
    let digits = ArrayList<Rune>()
    var run = 0
    var maxRun = 0
    var startIs1 = false
    var curStartIs1 = false
    for (r in text.runes()) {
        if (r >= r'0' && r <= r'9') {
            if (run == 0) {
                curStartIs1 = (r == r'1')
            }
            run = run + 1
            if (run > maxRun) {
                maxRun = run
                startIs1 = curStartIs1
            }
        } else {
            run = 0
        }
    }
    if (maxRun >= 18) {
        return "18 位数字串（身份证形态）"
    }
    /*
     * 「17 位数字 + X」也是身份证；上面的循环只累加 0-9，会把这种最常见写法放行。
     * 单独判「恰好 17 位数字 + 紧随 X/x」；不把 X 计入数字串长度，语义不同。
     */
    if (maxRun == 17 && kbHasIdTailX(text)) {
        return "17 位数字 + X（身份证形态）"
    }
    if (maxRun == 11 && startIs1) {
        return "11 位数字串（手机号形态）"
    }
    return ""
}

/* 逐字符扫描而非正则，与 kbLooksLikePersonalInfo 保持同一套匹配语义。 */
public func kbHasIdTailX(text: String): Bool {
    var run = 0
    for (r in text.runes()) {
        if (r >= r'0' && r <= r'9') {
            run = run + 1
            continue
        }
        if (run == 17 && (r == r'X' || r == r'x')) {
            return true
        }
        run = 0
    }
    return false
}

/* 仅已确认的唯一键冲突返回失败结果，未知数据库故障原样上抛。 */
public class KbExecResult {
    public var ok: Bool = false
    public var message: String = ""
    public var generatedId: Int64 = 0
}

public func kbExecTolerant(db: DbBackend, sql: String, args: Array<DbValue>,
                          returnInsertId!: Bool = false): KbExecResult {
    let r = KbExecResult()
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
 * 把唯一键冲突分类；title 参数是必须的：detail 要带上冲突的标题，只说「冲突了」会让调用方靠猜。
 * 空消息或未知故障不按重复/参数错误处理。
 */
public func kbClassifyDuplicate(message: String, title: String, out: KbWriteOutcome): KbWriteOutcome {
    if (!message.startsWith("Duplicate entry ")) {
        throw Exception(message)
    }
    out.duplicate = true
    out.detail = "标题「${title}」"
    return out
}

/* 填一行文档。 */
private func kbFillDoc(rs: DbResultSet, i: Int64): KbDoc {
    let d = KbDoc()
    d.id = rs.getInt(i, 0)
    d.title = rs.getString(i, 1)
    d.category = rs.getString(i, 2)
    d.body = rs.getString(i, 3)
    d.enabled = rs.getInt(i, 4) != 0
    d.updatedBy = rs.getInt(i, 5)
    d.createdAt = rs.getInt(i, 6)
    d.updatedAt = rs.getInt(i, 7)
    d.chunkCount = rs.getInt(i, 8)
    return d
}

/* 单个计数；db 以参数传入，本仓没有全局连接。 */
public func kbCount1(db: DbBackend, sql: String): Int64 {
    let rs = db.query(sql, Array<DbValue>())
    if (rs.rowCount() == 0) {
        return 0
    }
    return rs.getInt(0, 0)
}
