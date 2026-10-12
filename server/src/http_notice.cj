package qingzhou

import std.collection.*
import stdx.encoding.json.*

/*
 * SPDX-License-Identifier: MIT
 *
 * ===== http_notice.cj —— 公告域接口（患者可读 + 管理员维护）==============
 *
 * ## 为什么会有这个文件（患者端联调实测出来的窟窿）
 *
 * 患者端首页有一块「医疗公告」。联调时它显示的是三条**写死的假数据**
 * （2026-10-08 / 2026-10-03），而查库发现：**服务端根本没有公告表、也没有这个端点**
 * （`hospital_test` 的 14 张表里没有 notice）。
 * ⇒ 客户端的 `PatientRepository.notices()` 只能无条件 `MockPatientRepository.notices()`
 *   ——**不是它偷懒**，是服务端没给。这是本次补的那一环。
 *
 * ## 与知识库（kb）的边界 —— 刻意不合并
 *
 * 两者都是"文本 + 标题"，但**用途与威胁模型不同**：
 *   · `kb_doc`：会被检索、命中后**随 Prompt 出站**给模型 ⇒ 属 AI 域，读写都要 `ManageKnowledgeBase`；
 *   · `notice`：只在**界面展示**给人看，永不进 Prompt。
 * 把它们合成一张表的后果是：**发布一条公告就改了 RAG 语料**（患者可能因此拿到
 * 一条"公告式"的模型答案）。所以宁可多一张表。
 *
 * ## 端点一览
 *
 *   GET    /api/v1/notices                  患者可读的公告列表（仅 enabled 且已到发布时刻）
 *   GET    /api/v1/admin/notices[?include_disabled=]  管理列表（默认含停用/预排期）
 *   POST   /api/v1/admin/notices            新建
 *   GET    /api/v1/admin/notices/:id        单个
 *   PUT    /api/v1/admin/notices/:id        修改
 *   DELETE /api/v1/admin/notices/:id        删除（硬删；要留痕就 PUT enabled=false）
 *
 * ⚠ 权限：读侧 `ViewNotice`（**三端都给**：公告本就是面向所有人的院内通知，
 *   患者端首页在用），写侧 `ManageNotice`（仅管理员）。读写分开与 P4/P5 同构。
 * ⚠ 与 `registerBaseRoutes` 一样，注册函数**在 http_app.cj 里被显式调用** ——
 *   让"路由注册"这件事仍然集中可见。
 */

/* 公告 → JSON。
 *
 * ⚠ `date` / `published_at` **两个都给**，不是冗余：
 *   客户端 `PatientNotice.date` 是要直接显示的 `YYYY-MM-DD`
 *   （`feature-patient/.../MockPatientRepository.ets` 里的形状），
 *   而 `published_at`（epoch 秒）给需要精确时刻/自己排序的调用方。
 *   ⚠ 日期用 `hDateStringOf`（Asia/Shanghai）—— 与 `hTodayDate()` 同一口径。
 *     若这里另写一份换算，公告显示的日期与"今天"的判定会**再次分家**
 *     （那正是本次修的病灶）。
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
    /*
     * 管理侧才回 enabled/updated_by/时间戳：
     * 患者侧**只需展示**（多给字段等于多给客户端"依赖内部状态"的机会，
     * 而 enabled 对患者是恒真的 —— 停用的根本不在列表里）。
     */
    if (forAdmin) {
        o.put("enabled", JsonBool(n.enabled))
        o.put("updated_by", JsonInt(n.updatedBy))
        o.put("created_at", JsonInt(n.createdAt))
        o.put("updated_at", JsonInt(n.updatedAt))
    }
    return o
}

/*
 * 写入结果的异常映射（与 `baseThrowOnFailure` 同构，但只有公告域自己的码）。
 *
 * ⚠ 公告只有**一个**唯一键（`uk_notice_title`）⇒ `duplicate` 不必再看
 *   `conflictField` 就能确定是标题重复。`baseClassifyDuplicate` 只认
 *   `uk_department_*` 的索引名，对 `uk_notice_title` 会退化成 `markDuplicate("")`
 *   ⇒ 这里**按域判定**，不去改基础数据域的分类函数（它不该知道公告）。
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

/*
 * 从请求体读公告。
 *
 * 缺省值都是**显式决定**的（不是随手给的）：
 *   · `category` 缺省 `"通知"` —— 界面要有分组标签，空标签会显示成空白块；
 *   · `sort` 缺省 0 —— 与 `department.sort` 同义（小的在前），人工权重；
 *   · `enabled` 缺省 **true** —— 新建即为启用（与科室新增同口径）；
 *   · `published_at` 缺省 = **`defaultPublishedAt`**（而不是 0）。
 *     ⚠ 给 0 的后果是"1970 年发布的公告"，虽然照样可见（`published_at <= now`），
 *       但客户端拿到的 `date` 会显示 `1970-01-01`。这是**会真的误导人**的默认值。
 *     ⚠⚠ 缺省值**由调用方给**（不是这里写死 `hNowEpoch()`）：新建时缺省=现在是对的，
 *       但**修改**时缺省必须是**该行原有的 `published_at`** —— 否则"改个错别字"
 *       会把一条预排期的公告**提前发布**（日期也一起被改掉）。这两件事必须分开。
 */
public func noticeFromBody(ctx: Context, defaultPublishedAt: Int64): Notice {
    let n = Notice()
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
    return n
}

/* 注册公告域的路由。 */
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
        /*
         * ⚠ 管理列表默认**含**停用与预排期（`true`）：管理员要能看到全量才能维护
         *   —— 与科室/医生列表的 `include_disabled` 同为**默认宽松**。
         *   患者侧那条接口恒为严格，两者不会互相影响。
         */
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
        /* 新建：`published_at` 缺省 = 现在（要预排期就显式传未来时间戳）。 */
        let n = noticeFromBody(ctx, hNowEpoch())
        /* `updated_by` 记**是谁改的**（来自令牌，不接受请求体传入）。 */
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
        /* `id <= 0` 一律当"不存在"，不查库（理由同基础数据域：0 不是合法主键）。 */
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
        /*
         * ⚠ 先读旧行：`published_at` 的缺省值必须是**原有的发布时间**。
         *   若像新建那样缺省成"现在"，改个错别字就会把预排期的公告
         *   **提前发布**，并把 `date`（界面上的发布日期）一起改掉。
         */
        let existing = match (notices.findById(id)) {
            case Some(old) => old
            case None => throw apiErrorMsg("NOTICE_NOT_FOUND", "公告不存在")
        }
        let n = noticeFromBody(ctx, existing.publishedAt)
        n.updatedBy = p.userId
        /* `updated_at` 由调用方刷新（仓储不自己取时间，测试才能喂固定值）。 */
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
        /* 硬删。要"下架留痕"改用 PUT enabled=false —— 两个语义都给，不让人猜。 */
        data.put("soft_deleted", JsonBool(false))
        sendOk(ctx, data)
    })
}
