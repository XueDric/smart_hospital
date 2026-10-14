package qingzhou

import std.collection.*
import stdx.encoding.json.*

/*
 * SPDX-License-Identifier: MIT
 *
 * ===== kb_repo.cj —— P5 知识库仓储（文档 CRUD + 切块 + 两条检索路）=====
 *
 * 核心算法在 `domain_kb.cj`（切块/余弦/关键词打分，**纯逻辑、无 DB 无网络**）；
 * 本文件只管**持久化与检索编排**。
 *
 * ---------------------------------------------------------------------------
 * ## ★★ 本文件最要紧的一件事：**重新切块的 upsert 语义**
 *
 * 改一篇文档的正文时，块会**重新切**。这里必须保证：
 *   **旧的块全部消失**（否则检索会召回**已被改掉的旧内容** ——
 *   而那种错误的表现是"模型引用了文档里已经删掉的句子"，极难发现）。
 *
 * 做法（两步，**都在同一个语义里**）：
 *   ① 按 `(doc_id, seq)` **upsert** 新块（利用 `uk_kb_chunk_doc_seq`）；
 *   ② **删掉 `seq >= 新块数` 的旧块** —— 文档变短时，尾部旧块不会被 ① 覆盖。
 * ⚠ 只做 ① 会让"文档变短"留下尾部幽灵块；只做 ②（先删后插）会在中途失败时
 *   **丢掉整篇文档的块**。⇒ ①+② 的顺序是刻意的：**新块先落，再清多余**。
 *
 * ## ★★ 第二条要紧的事：**两条检索路不混排**
 *
 *   · `searchKeyword` —— 不需要 embedding，**永远可用**（默认路径）
 *   · `searchVector`  —— 需要传入查询向量；库里没有向量的块**跳过**
 * ⚠ 分数**量纲不同**（覆盖比例 vs 余弦）⇒ **绝不混排**
 *   （详见 `domain_kb.cj` 踩坑表 AJ）。选哪条路由调用方按"有没有 embedding"决定。
 */

/* ===================== 常量 ===================== */

/*
 * 一次检索最多扫描多少个块。
 *
 * ⚠⚠ **这是一条硬性上限，必须写进文档**（2026-10-09 复查要求）：
 *   超过 5000 块时，检索**只扫前 5000 个**（按 `c.id` 升序），
 *   **后面的块静默地永远不会被检索到** —— 这是本仓最忌的"静默失效"形态，
 *   所以：
 *     ① 响应里带 `scanned`（调用方可以自己发现 `scanned == 5000`）；
 *     ② 上限值在这里**只有一处定义**，且 `stats()` 会回报总块数
 *        ⇒ "块数 > 5000" 这件事**是可观测的**，不是暗坑。
 *
 * ⚠ 5000 怎么来的：brief §5.5 说"单院区知识库几千 chunk 完全够用；
 *   上万 chunk 才需要降维/分片"。**5000 正好落在这个区间的上沿** ——
 *   也就是说：到了该做分片的时候，`scanned` 会顶到 5000 提醒你。
 *   📌 一个"刚好等于设计容量"的上限，比一个"很大所以看起来不会碰到"的上限有用。
 */
public let KB_SCAN_LIMIT: Int64 = 5000

/* ===================== 结果类型 ===================== */

/* 知识库文档（`kb_doc` 的一行）。 */
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

/* 文档写入结果（**不抛异常**：可预期的业务拒绝靠返回值表达）。 */
public class KbWriteOutcome {
    public var ok: Bool = false
    public var id: Int64 = 0
    public var notFound: Bool = false
    /* `title` 唯一键冲突 ⇒ 409。 */
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

/* 检索结果（含**来源标注**，调用方必须如实透传）。 */
public class KbSearchResult {
    public var hits: Array<KbHit> = Array<KbHit>()
    /* "keyword" | "vector" —— **不可省**（见 domain_kb.cj 的说明）。 */
    public var source: String = KB_SOURCE_KEYWORD
    /* 扫过多少个块（看板/排障用：能看出"知识库多大、检索多贵"）。 */
    public var scanned: Int64 = 0
    /* 库里有多少块**没有**向量（向量路的覆盖度；关键词路恒为 0）。 */
    public var missingVectors: Int64 = 0
}

/* ===================== 仓储 ===================== */

public class KbRepo {
    private let db: DbBackend

    public init(db: DbBackend) {
        this.db = db
    }

    /* ---------- 文档 CRUD ---------- */

    /*
     * 列表。
     *
     * ⚠ 块数用**一次 GROUP BY** 取回，不是逐行查（N+1 —— 本仓在 `baseDepartmentNameMap`
     *   那里已经踩过一次并写在注释里）。
     */
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

    /*
     * 建文档：**落库 + 立刻切块**。
     *
     * ⚠ 校验放在仓储里（不只放 HTTP 层）：这样测试、将来的 CLI 也走同一套 ——
     *   "同一语义只留一处实现"（本仓铁律）。
     */
    public func create(title: String, category: String, body: String,
                       actorId: Int64, now: Int64): KbWriteOutcome {
        let out = KbWriteOutcome()
        let why = kbValidate(title, category, body)
        if (why.size > 0) {
            return out.markInvalid(why)
        }
        /*
         * ⚠ 直接 INSERT，**不先查**（先查后插是 TOCTOU）：靠 `uk_kb_doc_title` 兜底，
         *   冲突由 `kbClassifyDuplicate` 分类 —— 与 `domain_base.cj` 同一手法。
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
     * 改文档：**标题/分类/正文都可改**；改正文 ⇒ **重新切块**。
     *
     * ⚠ 显式返回 `changedBody`（由调用方/测试判定是否需要重新向量化）——
     *   其实 `kbRechunk` 内部已经处理，这里只是把"正文变没变"这个事实**暴露出来**，
     *   免得将来有人想"没变就不重新切"时无处判断。
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
         * ★★ 重新切块 —— **这是本文件最容易出错的地方**（见文件头）。
         * ⚠ 无条件重切（不做"正文没变就跳过"的优化）：那个优化需要**比较正文**，
         *   而正文可能上万字 ⇒ 比较成本与重切相当，却多一条"比较逻辑写错就漏切"的风险。
         *   宁可多切一次。📌 "不做无收益的优化，尤其当它引入新的出错面"。
         */
        kbRechunk(id, body, now)
        return out.markOk(id)
    }

    /*
     * 删文档。
     *
     * ⚠ 连带删块（**真删**，不是软删）—— 与 `department`/`doctor` 的软删策略**不同**，
     *   理由必须写清：科室/医生被**历史业务数据**引用（挂号/病历要能解析出名字），
     *   而知识库块**不被任何业务数据引用**（它只是检索的原料）⇒
     *   留着停用文档的块**只会污染检索**。要停用请用 `enabled = 0`。
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

    /* ---------- 切块（upsert + 清尾部）---------- */

    /*
     * 重新切块并落库。**旧块必须消失**（见文件头）。
     *
     * 返回落库后的块数。
     */
    public func kbRechunkPublic(docId: Int64, body: String, now: Int64): Int64 {
        return kbRechunk(docId, body, now)
    }

    private func kbRechunk(docId: Int64, body: String, now: Int64): Int64 {
        let pieces = kbChunk(body)
        /*
         * ① 先 upsert 新块。
         * ⚠ `chars` 存**字符数**（`previsitCharLen`）而不是 `size`（字节数）——
         *   本仓为"字节/字符混用"栽过三次，而这个字段会被用来判断块长度是否合理。
         */
        var i: Int64 = 0
        for (p in pieces) {
            db.exec(
                "INSERT INTO kb_chunk (doc_id, seq, content, chars, embedding, embedded_at, created_at) " +
                "VALUES (?, ?, ?, ?, NULL, 0, ?) " +
                "ON DUPLICATE KEY UPDATE content = VALUES(content), chars = VALUES(chars), " +
                /* ⚠ 正文变了 ⇒ **旧向量必须作废**（它对应的是旧文本！）。 */
                "embedding = NULL, embedded_at = 0",
                [DbInt(docId), DbInt(i), DbStr(p), DbInt(previsitCharLen(p)), DbInt(now)])
            i = i + 1
        }
        /* ② 再清掉"文档变短"留下的尾部旧块（`seq >= 新块数`）。 */
        db.exec("DELETE FROM kb_chunk WHERE doc_id = ? AND seq >= ?", [DbInt(docId), DbInt(i)])
        return i
    }

    /* ---------- 检索 ---------- */

    /*
     * 关键词检索（**默认路径，永远可用**）。
     *
     * ⚠ **一次把候选块读回来**再在内存里打分（不是逐块查）。
     *   理由：本用途下块数有限（几千），一次读回 + 内存打分**比 N 次查询快得多**，
     *   而且**结果一致**（N 次查询之间文档可能被改 ⇒ 同一个响应里出现两个版本）。
     */
    public func searchKeyword(query: String, topN!: Int64 = KB_SEARCH_TOP_N): KbSearchResult {
        let res = KbSearchResult()
        res.source = KB_SOURCE_KEYWORD
        let qTokens = kbTokens(query)
        if (qTokens.size == 0) {
            /* 查询里没有任何可检索成分（如纯标点）⇒ 空结果，**不是**返回随机块。 */
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
     * 向量检索（需要传入查询向量）。
     *
     * ⚠ 库里**没有向量**的块**跳过**（它们是"还没向量化"的正常状态）；
     *   同时回报 `missingVectors` —— 让调用方能判断"是不是大部分都没向量"
     *   （那说明该走关键词路，而不是拿少数几块算余弦）。
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
             * ⚠ 阈值 0（而不是 > 0）：余弦可能是负的（不相关）。
             *   保留 `> 0` 只是"至少方向一致"的粗筛 —— 真正的排序由分数决定，
             *   而 TopN 会取最高的几个。**不设更高阈值**是刻意的：
             *   阈值定高了会"什么都检索不到"，而定多少合适取决于具体 embedding 模型。
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
     * 写入某块的向量（向量化流程用）。
     * ⚠ 只更新 `embedding`/`embedded_at`，**不动 content** ——
     *   若这里顺手写 content，就会让"向量对应哪个文本"变得不可信。
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
         * ⚠ 向量覆盖率如实给出：它直接决定"向量路能不能用"。
         *   0% 时调用方应当走关键词路（并如实标注 source）。
         */
        var pct: Int64 = 0
        if (all > 0) {
            pct = embedded * 100 / all
        }
        o.put("embedding_coverage_pct", JsonInt(pct))
        /*
         * ★ 把**检索上限**一并回报，并明确"是否已触顶"（2026-10-09 复查要求）。
         *   ⚠ 理由：`KB_SCAN_LIMIT` 一旦触顶，超出的块**静默检索不到**。
         *     只回报总块数是不够的 —— 运维看到 "chunks: 6000" 未必联想到
         *     "检索只扫前 5000"。⇒ 这里直接给出**布尔结论**，不让人自己去比。
         *   📌 判据：**能被静默触发的上限，就必须有一个显式的"已触顶"信号。**
         */
        o.put("scan_limit", JsonInt(KB_SCAN_LIMIT))
        o.put("scan_limit_reached", JsonBool(all > KB_SCAN_LIMIT))
        o.put("scan_limit_note", JsonString(
            "检索最多扫描 scan_limit 个块（按 id 升序）；chunks 超过它时，后面的块**不会被检索到**。" +
            "scan_limit_reached=true 表示已触顶，需要分片或缩库。"))
        /*
         * ★★ `embedding_note` **放在这里**，而不是放在 HTTP 端点的 handler 里
         *   （2026-10-09 由 AC-KB-5 ⑨ 抓到：端点里有一份、`stats()` 里没有，
         *    于是"同一口径说明"有了**两处**——而其中一处会被看板/别的调用方漏掉）。
         *
         * ⚠ 为什么口径说明必须跟着数据走：`embedding_coverage_pct` 为 0 是**当前常态**
         *   （DeepSeek 无 embeddings 端点），不解释的话看到 0% 的人会以为**功能坏了**。
         *   把说明与数字**放在同一个对象里**，任何拿到这份数据的调用方
         *   都自动带上解释 —— 而"记得在每个使用点补一句"迟早会漏。
         *   📌 判据：**口径说明应当与被解释的数据同源**，不能靠调用方自觉。
         */
        o.put("embedding_note", JsonString(
            "embedding_coverage_pct 为 0 表示尚无向量（当前检索走关键词路，source=keyword）。" +
            "本版本 DeepSeek 未提供 embeddings 端点，故向量路需另配支持 embedding 的服务。"))
        return o
    }

    /* ---------- 内部：读块 / 取前 N ---------- */

    /*
     * 一次读回**启用文档**的所有块（含向量）。
     *
     * ⚠ 只读 `d.enabled = 1`：停用文档不该被检索到（那是"停用"的定义）。
     *   ⇒ `kb_doc.enabled` 因此是**检索语义的一部分**，不是装饰字段。
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
            /*
             * ⚠ `embedding` 列可为 NULL ⇒ 用 `getNullable`（本仓 DbResultSet 有它）。
             *   直接用 `getString` 拿 NULL 会得到什么取决于驱动实现 —— 不赌。
             */
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

/* ===================== 共用工具 ===================== */

/*
 * 文档字段校验。返回空串表示通过。
 *
 * ⚠⚠ 这里也**机制性拒绝明显的个人信息形态**：
 *   知识库文档由本院人员维护（文档本身不出站），但**检索命中片段会随 Prompt
 *   出站给第三方模型**（见 docs/Q6-合规决策记录.md）⇒ 知识库里**不得放患者信息**。
 *   ⚠ 这条**无法用代码保证**（文档是自由文本）—— 这里只挡**最明显的形态**
 *     （身份证号 / 手机号），并在 Q6 里如实列为"仍需人工把关"。
 *   📌 不假装"代码保证了合规"：能挡的挡住，挡不住的说清。
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
 * 是否含**明显**的个人信息形态。
 *
 * ⚠ 只做两件很窄的事（刻意窄：**误报会让人无法写正常文档**）：
 *   · 11 位连续数字且以 1 开头（手机号形态）
 *   · 18 位（末位可为 X）连续数字/字母（身份证形态）
 * ⚠ **不做**姓名识别（中文姓名无法可靠区分于普通词），
 *   那部分如实列为"人工把关"（见 Q6 记录）。
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
     * ★★ 「17 位数字 + X」也是身份证（**末位校验码为 X 是最常见的一种**）。
     *
     * ⚠⚠ 这一条是 2026-10-09 复查抓到的**真漏判**：上面的循环只累加 `0-9`，
     *   所以 `11010119900307123X` 里的数字段只有 **17 位** ⇒ 不触发 `maxRun >= 18`
     *   ⇒ **放行**。实测：纯 18 位数字被拒（400），而「17 位 + X」返回 **201**。
     *
     * ⚠ 为什么这条尤其要紧（不是"顺手补个边界"）：
     *   本仓 `docs/Q6-合规决策记录.md` 把"管理端拒绝明显的个人信息形态"
     *   **列为一条合规缓解手段**。而合规手段**漏掉最常见的一种写法**，
     *   比没有这条检查更糟 —— 它会让人以为"已经挡住了"。
     *   📌 判据：**声称"已挡住"的东西，必须挡住常见写法**；否则它只是心理安慰。
     *
     * ⚠ 实现上**不把 X 计入 `maxRun`**（那是数字串的长度，语义不同），
     *   而是单独判"恰好 17 位数字 + 紧随 X/x"这个形状。
     *   顺带覆盖小写 `x`（录入时都常见）。
     */
    if (maxRun == 17 && kbHasIdTailX(text)) {
        return "17 位数字 + X（身份证形态）"
    }
    if (maxRun == 11 && startIs1) {
        return "11 位数字串（手机号形态）"
    }
    return ""
}

/*
 * 文里是否存在「恰好 17 位连续数字，且紧随其后是 X / x」。
 *
 * ⚠ 用逐字符扫描而不是正则：仓颉的 `Regex` 在本仓另有用途（redflag），
 *   这里保持与上面同一手法（一次 `runes()` 扫描），免得引入第二套匹配语义。
 */
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
 * 把唯一键冲突分类。
 * 与基础域使用同一唯一键证据；空消息或未知故障不按重复/参数错误处理。
 *
 * ⚠⚠ `title` 参数是**必须的**，不是装饰（2026-10-09 实测发现）：
 *   原来这里只置 `duplicate = true`、不填 `detail`，于是 HTTP 层拼出的 409 消息是
 *   **「已存在同名文档：」后面空着** —— 用户看不到**是哪个名字**冲突了。
 *   一个"说了等于没说"的错误消息会让调用方只能靠猜（尤其批量导入时）。
 *   📌 一般化：**报错要带上"足以定位"的信息** —— 只说"冲突了"而不说"和谁冲突"，
 *     是把定位成本推给调用方。
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

/* 单个计数（看板用）。⚠ 收 db 参数（不是全局）—— 本仓没有全局连接。 */
public func kbCount1(db: DbBackend, sql: String): Int64 {
    let rs = db.query(sql, Array<DbValue>())
    if (rs.rowCount() == 0) {
        return 0
    }
    return rs.getInt(0, 0)
}
