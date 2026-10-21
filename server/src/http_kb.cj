package qingzhou

import std.collection.*
import stdx.encoding.json.*
import std.time.*

/*
 * SPDX-License-Identifier: MIT
 *
 * http_kb.cj —— 知识库接口层：管理端文档 CRUD（自动切块）+ 关键词检索。
 * 暴露 registerKbRoutes；错误码 KB_DOC_NOT_FOUND / KB_TITLE_TAKEN / KB_WRITE_FAILED / VALIDATION_FAILED。
 *
 * 端点：/api/v1/admin/kb/docs（GET/POST）、/api/v1/admin/kb/docs/:id（GET/PUT/DELETE）、/api/v1/admin/kb/stats
 *       /api/v1/kb/search?q=&top=
 *
 * 约束：检索只走关键词路，不暴露传查询向量的入口，走哪条路由服务端决定；
 *       检索不回文档 body 全文，只回命中块，否则响应体随文档无界增长。
 */

/* JSON 化：列表页不带 body，详情页带 body。 */

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

/* 一条检索命中；source 必带，调用方据此知道走的是哪条路。 */
func kbHitJson(h: KbHit): JsonObject {
    let o = JsonObject()
    o.put("doc_id", JsonInt(h.docId))
    o.put("chunk_id", JsonInt(h.chunkId))
    o.put("seq", JsonInt(h.seq))
    o.put("title", JsonString(h.title))
    o.put("category", JsonString(h.category))
    o.put("content", JsonString(h.content))
    /* 分数保留 4 位小数：原始 double 串的 16 位噪声会被当成精确值比较。 */
    o.put("score", JsonFloat(kbRound4(h.score)))
    o.put("source", JsonString(h.source))
    return o
}

/* 保留 4 位小数。 */
func kbRound4(v: Float64): Float64 {
    return Float64(Int64(v * 10000.0 + 0.5)) / 10000.0
}

/* 请求体解析：只有 POST 用它，缺字段按空串交给 kbValidate 拒绝。 */

/* 缺字段与空串要能区分：前者是接口契约问题，后者是内容不合规。 */
func kbBodyField(ctx: Context, name: String): String {
    return bodyStr(ctx, name) ?? ""
}

/* 错误映射：可预期业务拒绝用 4xx，500 只表示未预料。 */

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

/* registerKbRoutes：注册管理端 CRUD 与检索端点；权限 ManageKnowledgeBase / QueryKnowledgeBase，患者不可检索。 */

public func registerKbRoutes(r: Router, auth: AuthRepo, gate: DevAuthGate, kb: KbRepo): Unit {
    /* 管理端 CRUD 四端点，均先 requireCan(ManageKnowledgeBase)。 */

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
        /* 回显 chunk_count：切块这步最易出意外，不回显要再查一次才知道结果。 */
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
        /*
         * PUT = PATCH：缺字段保留旧值，enabled 缺省也保留旧值，否则会有意外重新启用。
         * 字段传了但为空或传 null 仍 400，理由由 kbValidate 给（内容类，不与缺字段混淆）。
         * 代价：kb.update 无条件重切块，只改 enabled 也会重切一次。
         */
        let title = bodyStr(ctx, "title")
        let category = bodyStr(ctx, "category")
        let body = bodyStr(ctx, "body")
        let enabled = bodyBool(ctx, "enabled")
        let existing = match (kb.findById(id)) {
            case Some(d) => d
            case None => throw apiErrorMsg("KB_DOC_NOT_FOUND", "知识库文档不存在")
        }
        let out = kb.update(id, title ?? existing.title, category ?? existing.category,
                            body ?? existing.body, enabled ?? existing.enabled,
                            p.userId, kbNowEpoch())
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
        /* 明确回报块一并删除：与 department/doctor 的软删策略不同。 */
        data.put("chunks_deleted", JsonBool(true))
        sendOk(ctx, data)
    })

    r.get("/api/v1/admin/kb/stats", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageKnowledgeBase)
        let data = kb.stats()
        /* 口径说明由 KbRepo.stats() 一并产出：口径必须与被解释的数据同源（AC-KB-5 ⑨）。 */
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
            /* 必须夹住上界 [1,20]：top 由调用方给，透传等于让它决定一次读多少块进内存。 */
            top = parsed
            if (top < 1) {
                top = 1
            }
            if (top > 20) {
                top = 20
            }
        }
        /* 固定走关键词路；source 取自仓储返回值而非常量，将来切向量路会自动跟随。 */
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
        /* missing_vectors 如实给出：区分没配 embedding 与配了没生效。 */
        data.put("missing_vectors", JsonInt(res.missingVectors))
        sendOk(ctx, data)
    })
}

/* 小工具：路径参数解析与当前时间戳。 */

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
