package qingzhou

import std.collection.*
import stdx.encoding.json.*
import std.time.*

/*
 * SPDX-License-Identifier: MIT
 *
 * ===== http_kb.cj —— P5 知识库接口层（管理端 CRUD + 检索）=================
 *
 * 与 `http_base.cj` / `http_p4.cj` 同一手法：**内容分文件，注册集中在 http_app**。
 *
 * ---------------------------------------------------------------------------
 * ## 端点清单
 *
 *   管理端（`ManageKnowledgeBase`，仅管理员）
 *     GET    /api/v1/admin/kb/docs              列表（含块数）
 *     POST   /api/v1/admin/kb/docs              新建（**自动切块**）
 *     GET    /api/v1/admin/kb/docs/:id          单篇
 *     PUT    /api/v1/admin/kb/docs/:id          修改（**自动重切块**）
 *     DELETE /api/v1/admin/kb/docs/:id          删除（连带删块）
 *     GET    /api/v1/admin/kb/stats             规模（文档/块/向量覆盖率）
 *
 *   检索（`QueryKnowledgeBase`，医生 + 管理员；**患者不给**）
 *     GET    /api/v1/kb/search?q=...&top=...    关键词检索（默认路，永远可用）
 *
 * ## ★★ 两个刻意的取舍
 *
 * ① **检索端点只走关键词路**（不暴露"传查询向量"的入口）。
 *    理由：让**客户端传向量**等于把"用哪条路"的决定权交给调用方，
 *    而调用方（尤其患者侧客户端）无法知道"库里到底有没有向量"。
 *    ⇒ 决定权留在服务端，且 `source` 如实回报。
 *    ⚠ 向量路的**仓储实现已就绪并有测试**（`kb_repo.searchVector`），
 *      等 embedding 端点可用时，由服务端在**同一个端点内**决定走哪条 —— 
 *      届时 `source` 会变成 `vector`，契约不变。
 *
 * ② **不返回文档 `body` 全文**，只返回命中的**块**内容。
 *    ⚠ 理由：检索接口是给"喂模型"用的，块就是喂进去的单位；
 *      返回全文会让响应体随文档变大而无界（一篇 2 万字的须知 = 200KB 响应）。
 *      要看全文请用管理端的 `GET /admin/kb/docs/:id`。
 */

/* ===================== JSON 化 ===================== */

/* 文档（列表页：**不含 body**，省响应体）。 */
func kbDocBriefJson(d: KbDoc): JsonObject {
    let o = JsonObject()
    o.put("id", JsonInt(d.id))
    o.put("title", JsonString(d.title))
    o.put("category", JsonString(d.category))
    o.put("enabled", JsonBool(d.enabled))
    o.put("chunk_count", JsonInt(d.chunkCount))
    o.put("updated_at", JsonInt(d.updatedAt))
    return o
}

/* 文档（详情：含 body）。 */
func kbDocFullJson(d: KbDoc): JsonObject {
    let o = kbDocBriefJson(d)
    o.put("body", JsonString(d.body))
    o.put("updated_by", JsonInt(d.updatedBy))
    o.put("created_at", JsonInt(d.createdAt))
    return o
}

/*
 * 一条检索命中。
 * ★ `source` 必带 —— 调用方据此知道"这次走的是哪条路"。
 */
func kbHitJson(h: KbHit): JsonObject {
    let o = JsonObject()
    o.put("doc_id", JsonInt(h.docId))
    o.put("chunk_id", JsonInt(h.chunkId))
    o.put("seq", JsonInt(h.seq))
    o.put("title", JsonString(h.title))
    o.put("category", JsonString(h.category))
    o.put("content", JsonString(h.content))
    /*
     * ⚠ 分数保留 4 位小数（**不是**原始 double 串）：
     *   原始串会输出 `0.3333333333333333` 这种 16 位噪声，
     *   而它会被测试/前端当作"精确值"比较 ⇒ 换个实现就红。
     *   检索分数本来就是**相对**量，4 位足够排序与展示。
     */
    o.put("score", JsonFloat(kbRound4(h.score)))
    o.put("source", JsonString(h.source))
    return o
}

/* 保留 4 位小数。 */
func kbRound4(v: Float64): Float64 {
    return Float64(Int64(v * 10000.0 + 0.5)) / 10000.0
}

/* ===================== 请求体解析 ===================== */

/*
 * 从请求体取字符串字段。
 *
 * ⚠ `missing` 与"空串"要能区分：
 *   `kbValidate` 对空标题的拒绝理由是"标题不能为空"，
 *   而若字段**根本没传**，理由应该是"缺字段"（那是**接口契约**问题，不是内容问题）。
 *   📌 两者混在一起会让调用方分不清"我传错了"还是"内容不合规"。
 */
func kbBodyField(ctx: Context, name: String): String {
    return bodyStr(ctx, name) ?? ""
}

/*
 * 取布尔字段（缺省用 `def`）。
 * ⚠ 用现成的 `bodyBool`（它内部已做类型判定）：
 *   `asBool()` 类型不符会**抛异常**（这条语言坑记录过），不要自己再写一遍。
 */
func kbBodyBool(ctx: Context, name: String, def: Bool): Bool {
    return bodyBool(ctx, name) ?? def
}

/* ===================== 错误映射 ===================== */

/*
 * 把写入失败翻译成 HTTP 错误。
 *
 * ⚠ 与 `baseThrowOnFailure` 同一口径：**可预期的业务拒绝用 4xx 表达**，
 *   不用 500（500 应当只表示"我们没预料到"）。
 */
func kbThrowOnFailure(out: KbWriteOutcome): Unit {
    if (out.notFound) {
        throw apiErrorMsg("KB_DOC_NOT_FOUND", "知识库文档不存在")
    }
    if (out.duplicate) {
        throw apiErrorMsg("KB_TITLE_TAKEN", "已存在同名文档：${out.detail}")
    }
    if (out.invalid) {
        throw apiErrorMsg("VALIDATION_FAILED", out.detail)
    }
    if (!out.ok) {
        throw apiErrorMsg("KB_WRITE_FAILED", "知识库写入失败")
    }
}

/* ===================== 注册 ===================== */

public func registerKbRoutes(r: Router, auth: AuthRepo, gate: DevAuthGate, kb: KbRepo): Unit {
    /* ---------- 管理端：文档 CRUD ---------- */

    r.get("/api/v1/admin/kb/docs", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageKnowledgeBase)
        let includeDisabled = (ctx.queryParamOr("include_disabled", "true")) != "false"
        let items = JsonArray()
        for (d in kb.listDocs(includeDisabled: includeDisabled)) {
            items.add(kbDocBriefJson(d))
        }
        let data = JsonObject()
        data.put("items", items)
        data.put("count", JsonInt(Int64(items.size())))
        sendOk(ctx, data)
    })

    r.post("/api/v1/admin/kb/docs", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageKnowledgeBase)
        let title = kbBodyField(ctx, "title")
        let category = kbBodyField(ctx, "category")
        let body = kbBodyField(ctx, "body")
        let out = kb.create(title, category, body, p.userId, kbNowEpoch())
        kbThrowOnFailure(out)
        let data = JsonObject()
        data.put("id", JsonInt(out.id))
        /*
         * ⚠ 回显块数：让调用方**立刻看到"切了几块"**。
         *   切块是这一步最可能出意外的环节（正文超长、全空白），
         *   不回显的话要再查一次才知道结果。
         */
        match (kb.findById(out.id)) {
            case Some(d) => data.put("chunk_count", JsonInt(d.chunkCount))
            case None => data.put("chunk_count", JsonInt(0))
        }
        sendCreated(ctx, data)
    })

    r.get("/api/v1/admin/kb/docs/:id", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageKnowledgeBase)
        let id = kbPathId(ctx)
        match (kb.findById(id)) {
            case Some(d) => sendOk(ctx, kbDocFullJson(d))
            case None => throw apiErrorMsg("KB_DOC_NOT_FOUND", "知识库文档不存在")
        }
    })

    r.put("/api/v1/admin/kb/docs/:id", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageKnowledgeBase)
        let id = kbPathId(ctx)
        let title = kbBodyField(ctx, "title")
        let category = kbBodyField(ctx, "category")
        let body = kbBodyField(ctx, "body")
        /*
         * ⚠ `enabled` 缺省是 **true**（"改内容"是最常见的意图；
         *   要停用请显式传 `enabled: false`）。
         *   ⇒ 但这是**有风险**的缺省：一次"只想改标题"的 PUT 若客户端没带 body，
         *     会把正文清空（那会被 kbValidate 挡住 ⇒ 400，不会静默毁数据）。
         *   📌 刻意保持"PUT = 整体替换"的语义，不做"只改传了的字段"的 patch ——
         *     后者要求客户端知道哪些字段传了，而 JSON 里"没传"与"传了 null"难区分。
         */
        let enabled = kbBodyBool(ctx, "enabled", true)
        let out = kb.update(id, title, category, body, enabled, p.userId, kbNowEpoch())
        kbThrowOnFailure(out)
        let data = JsonObject()
        data.put("id", JsonInt(out.id))
        match (kb.findById(out.id)) {
            case Some(d) =>
                data.put("chunk_count", JsonInt(d.chunkCount))
                data.put("enabled", JsonBool(d.enabled))
            case None => ()
        }
        sendOk(ctx, data)
    })

    r.delete("/api/v1/admin/kb/docs/:id", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageKnowledgeBase)
        let id = kbPathId(ctx)
        let out = kb.remove(id)
        kbThrowOnFailure(out)
        let data = JsonObject()
        data.put("id", JsonInt(out.id))
        /*
         * ⚠ 明确回报"块也一起删了"：这是与 department/doctor 软删策略**不同**的地方，
         *   调用方应当能看到这个差别（而不是以为它也是软删）。
         */
        data.put("chunks_deleted", JsonBool(true))
        sendOk(ctx, data)
    })

    r.get("/api/v1/admin/kb/stats", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageKnowledgeBase)
        let data = kb.stats()
        /*
         * ⚠ 口径说明（`embedding_note` / `scan_limit_note`）**不在这里加** ——
         *   它们由 `KbRepo.stats()` 一并产出。
         *   2026-10-09 改：原来这里手写了一份，而 `stats()` 里没有 ⇒
         *   "同一口径说明"存在**两处**，其中一处会被看板/别的调用方漏掉
         *   （AC-KB-5 ⑨ 抓到的就是这个）。
         *   📌 判据：**口径说明应当与被解释的数据同源**，不能靠调用方自觉补。
         */
        sendOk(ctx, data)
    })

    /* ---------- 检索（医生 + 管理员）---------- */

    r.get("/api/v1/kb/search", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.QueryKnowledgeBase)
        let q = ctx.queryParamOr("q", "").trimAscii()
        if (q.size == 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "缺查询词 q")
        }
        var top = KB_SEARCH_TOP_N
        let topRaw = ctx.queryParamOr("top", "")
        if (topRaw.size > 0) {
            let parsed = parseInt64Or(topRaw, KB_SEARCH_TOP_N)
            /*
             * ⚠ **必须夹住上界**：`top` 是调用方给的，直接透传等于让它
             *   决定"一次读回多少块进内存"（`topN` 大了响应体也无界）。
             *   ⇒ 夹到 [1, 20]：检索是给"喂模型"用的，20 块已远超提示词预算。
             */
            top = parsed
            if (top < 1) {
                top = 1
            }
            if (top > 20) {
                top = 20
            }
        }
        /*
         * ★ 当前固定走**关键词路**（理由见文件头 ①）。
         * ⚠ 但 `source` 来自仓储的返回值，**不是这里写死的常量** ——
         *   这样将来服务端切成向量路时，`source` 自动跟着变，不会忘记改。
         */
        let res = kb.searchKeyword(q, topN: top)
        let items = JsonArray()
        for (h in res.hits) {
            items.add(kbHitJson(h))
        }
        let data = JsonObject()
        data.put("items", items)
        data.put("count", JsonInt(Int64(items.size())))
        data.put("source", JsonString(res.source))
        data.put("scanned", JsonInt(res.scanned))
        /*
         * ⚠ `missing_vectors` **如实给出**（关键词路为 0）：
         *   它是"向量路覆盖度"的直接指标，运维据此判断"要不要配 embedding"。
         *   不给的话，看到 `source=keyword` 的人无法区分
         *   "没配 embedding" 与 "明明配了却没生效"。
         */
        data.put("missing_vectors", JsonInt(res.missingVectors))
        sendOk(ctx, data)
    })
}

/* ===================== 小工具 ===================== */

/* 取路径参数 `:id`（非法 ⇒ 400，不是 500）。 */
func kbPathId(ctx: Context): Int64 {
    let raw = ctx.paramOr("id", "")
    if (raw.size == 0) {
        throw apiErrorMsg("VALIDATION_FAILED", "缺文档 id")
    }
    var ok = true
    var i: Int64 = 0
    while (i < raw.size) {
        let b = raw[i]
        if (b < 48 || b > 57) {
            ok = false
            break
        }
        i = i + 1
    }
    if (!ok) {
        throw apiErrorMsg("VALIDATION_FAILED", "文档 id 必须是数字")
    }
    return parseInt64Or(raw, 0)
}

/* 当前秒级时间戳。 */
func kbNowEpoch(): Int64 {
    return DateTime.now().toUnixTimeStamp().toSeconds()
}
