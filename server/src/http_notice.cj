package qingzhou

import std.collection.*
import stdx.encoding.json.*

/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 *
 * http_notice.cj —— 公告域接口（患者可读 + 管理员维护）
 * 端点：GET /api/v1/notices；GET/POST /api/v1/admin/notices；GET/PUT/DELETE /api/v1/admin/notices/:id
 * 权限：读侧 ViewNotice（三端都给），写侧 ManageNotice（仅管理员）。
 * notice 只在界面展示、永不进 Prompt，故与 kb_doc 分表。
 */

/* 公告 → JSON。
 * date（Asia/Shanghai，与 hTodayDate 同口径）与 published_at（epoch 秒）都给；管理侧才带 enabled/updated_by/时间戳。
 */
public func noticeJson(n: Notice, forAdmin: Bool): JsonObject {
    let o = JsonObject()
    o.put("id", JsonInt(n.id))
    o.put("title", JsonString(n.title))
    o.put("body", JsonString(n.body))
    o.put("category", JsonString(n.category))
    o.put("date", JsonString(hDateStringOf(n.publishedAt)))
    o.put("published_at", JsonInt(n.publishedAt))
    o.put("sort", JsonInt(n.sort))
    if (forAdmin) {
        o.put("enabled", JsonBool(n.enabled))
        o.put("updated_by", JsonInt(n.updatedBy))
        o.put("created_at", JsonInt(n.createdAt))
        o.put("updated_at", JsonInt(n.updatedAt))
    }
    return o
}

/* 写入失败 → 错误码：NOTICE_NOT_FOUND / NOTICE_TITLE_TAKEN / VALIDATION_FAILED / INTERNAL_ERROR。
 * 公告唯一键只有 uk_notice_title，duplicate 即标题重复。
 */
public func noticeThrowOnFailure(out: BaseWriteOutcome): Unit {
    if (out.ok) {
        return
    }
    if (out.notFound) {
        throw apiErrorMsg("NOTICE_NOT_FOUND", "公告不存在")
    }
    if (out.duplicate) {
        throw apiErrorMsg("NOTICE_TITLE_TAKEN", "已存在同名公告（标题必须唯一，便于患者端识别）")
    }
    if (out.invalid) {
        throw apiErrorMsg("VALIDATION_FAILED", out.detail)
    }
    throw apiErrorMsg("INTERNAL_ERROR", "写入未成功且原因未知")
}

/* 从请求体读公告；existing 决定语义。
 * None（POST）整体替换，title/body 必填；Some(old)（PUT）为 PATCH，缺失字段保留旧值。
 * published_at 缺省由调用方给：修改时必须传旧值，否则预排期公告会被提前发布。
 */
public func noticeFromBody(ctx: Context, defaultPublishedAt: Int64, existing!: ?Notice = None): Notice {
    let n = Notice()
    match (existing) {
        case Some(old) =>
            n.title = (bodyStr(ctx, "title") ?? old.title).trimAscii()
            n.body = bodyStr(ctx, "body") ?? old.body
            n.category = (bodyStr(ctx, "category") ?? old.category).trimAscii()
            n.sort = bodyInt64(ctx, "sort") ?? old.sort
            n.enabled = bodyBool(ctx, "enabled") ?? old.enabled
            let pubOld = bodyInt64(ctx, "published_at") ?? 0
            if (pubOld <= 0) {
                n.publishedAt = old.publishedAt
            } else {
                n.publishedAt = pubOld
            }
        case None =>
            n.title = requireStr(ctx, "title").trimAscii()
            n.body = requireStr(ctx, "body")
            n.category = (bodyStr(ctx, "category") ?? "通知").trimAscii()
            n.sort = bodyInt64(ctx, "sort") ?? 0
            n.enabled = bodyBool(ctx, "enabled") ?? true
            let pub = bodyInt64(ctx, "published_at") ?? 0
            if (pub <= 0) {
                n.publishedAt = defaultPublishedAt
            } else {
                n.publishedAt = pub
            }
    }
    return n
}

/* 注册公告域路由（在 http_app.cj 里显式调用）。 */
public func registerNoticeRoutes(r: Router, auth: AuthRepo, gate: DevAuthGate,
                                 notices: NoticeRepo): Unit {
    /* ---------- 患者可读 ---------- */
    r.get("/api/v1/notices", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ViewNotice)
        let limit = parseInt64Or(ctx.queryParamOr("limit", "0"), 0)
        let now = hNowEpoch()
        let items = JsonArray()
        for (n in notices.listVisible(now, limit)) {
            items.add(noticeJson(n, false))
        }
        let data = JsonObject()
        data.put("items", items)
        data.put("count", JsonInt(Int64(items.size())))
        sendOk(ctx, data)
    })

    /* ---------- 管理端 ---------- */
    r.get("/api/v1/admin/notices", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageNotice)
        /* 管理列表默认含停用与预排期（include_disabled=true）；患者侧那条恒为严格。 */
        let includeDisabled = (ctx.queryParamOr("include_disabled", "true")) != "false"
        let limit = parseInt64Or(ctx.queryParamOr("limit", "0"), 0)
        let items = JsonArray()
        for (n in notices.listAll(includeDisabled: includeDisabled, limit: limit)) {
            items.add(noticeJson(n, true))
        }
        let data = JsonObject()
        data.put("items", items)
        data.put("count", JsonInt(Int64(items.size())))
        sendOk(ctx, data)
    })

    r.post("/api/v1/admin/notices", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageNotice)
        let n = noticeFromBody(ctx, hNowEpoch())
        /* updated_by 记是谁改的：来自令牌，不接受请求体传入。 */
        n.updatedBy = p.userId
        let out = notices.create(n, hNowEpoch())
        noticeThrowOnFailure(out)
        let data = JsonObject()
        data.put("id", JsonInt(out.id))
        match (notices.findById(out.id)) {
            case Some(saved) => data.put("notice", noticeJson(saved, true))
            case None => ()
        }
        sendCreated(ctx, data)
    })

    r.get("/api/v1/admin/notices/:id", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageNotice)
        let id = parseInt64Or(ctx.paramOr("id", "0"), 0)
        /* id <= 0 一律当"不存在"，不查库。 */
        if (id <= 0) {
            throw apiErrorMsg("NOTICE_NOT_FOUND", "公告不存在")
        }
        match (notices.findById(id)) {
            case Some(n) =>
                let data = JsonObject()
                data.put("notice", noticeJson(n, true))
                sendOk(ctx, data)
            case None => throw apiErrorMsg("NOTICE_NOT_FOUND", "公告不存在")
        }
    })

    r.put("/api/v1/admin/notices/:id", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageNotice)
        let id = parseInt64Or(ctx.paramOr("id", "0"), 0)
        /* 先读旧行：published_at 缺省取原值；PATCH 语义下改 enabled 不会提前发布。 */
        let existing = match (notices.findById(id)) {
            case Some(old) => old
            case None => throw apiErrorMsg("NOTICE_NOT_FOUND", "公告不存在")
        }
        let n = noticeFromBody(ctx, existing.publishedAt, existing: Some(existing))
        n.updatedBy = p.userId
        /* updated_at 由调用方刷新（仓储不自己取时间，测试才能喂固定值）。 */
        n.updatedAt = hNowEpoch()
        let out = notices.update(id, n)
        noticeThrowOnFailure(out)
        let data = JsonObject()
        data.put("id", JsonInt(id))
        match (notices.findById(id)) {
            case Some(saved) => data.put("notice", noticeJson(saved, true))
            case None => ()
        }
        sendOk(ctx, data)
    })

    r.delete("/api/v1/admin/notices/:id", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageNotice)
        let id = parseInt64Or(ctx.paramOr("id", "0"), 0)
        let out = notices.remove(id)
        noticeThrowOnFailure(out)
        let data = JsonObject()
        data.put("id", JsonInt(id))
        /* 硬删；下架留痕改用 PUT enabled=false。 */
        data.put("soft_deleted", JsonBool(false))
        sendOk(ctx, data)
    })
}
