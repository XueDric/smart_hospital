/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 *
 * ===== http_common.cj —— HTTP 响应/错误公共层 ==============================
 *
 * 统一响应口径（与搬迁前一致，便于客户端复用同一套解析代码）：
 *   成功：200/201 `{"ok":true,"data":{...}}`
 *   失败：`{"ok":false,"error":{"code":"...","message":"...","fields":{...}}}`
 *   —— HTTP 状态码给网络层用（401 直接踢回登录页，不必解析 body），
 *      error.code 给业务层用（客户端 switch 出文案）。这是搬迁前的 api-design §1.2 的分工。
 *
 * ⚠ 一处关键纪律：**绝不向客户端暴露内部堆栈**。未列出的异常一律 500 + "服务器内部错误"，
 *   细节只进服务端日志（照搬迁前的 main.cj:909-917 的 errHandler）。
 */

package qingzhou

import std.collection.*
import stdx.encoding.json.*

/* ===================== 业务错误 ===================== */

/*
 * 业务错误：带 HTTP 状态码 + 机器可读 code + 可选逐字段原因。
 *
 * 为什么用异常而不是返回值：轻舟的洋葱模型里，handler 抛异常会被 `onError` 中间件接住
 * （compose.cj:83-101 的 AppHandler.handle → ctx.throw_err(e)），所以抛出来是最省路径的
 * —— **但业务"失败"不该都用异常**：像"号已被抢走"这种**正常业务结果**用返回值表达
 * （见 BookingRepo 的 BookingOutcome），只有"请求本身不合法/无权"才抛 ApiError。
 */
public class ApiError <: Exception {
    public let code: String
    public let status_: Int64
    public let fields: ?JsonObject

    public init(code: String, status_: Int64, msg: String, fields: ?JsonObject) {
        super(msg)
        this.code = code
        this.status_ = status_
        this.fields = fields
    }
}

/*
 * 错误码表 —— **唯一权威在本文件**。
 *
 * 每个码给出 (HTTP 状态码, 默认中文文案)。未列出的码一律 500，
 * 且文案固定为"服务器内部错误"（不把 code 之外的内部信息带出去）。
 *
 * 三端角色相关（P1）：AUTH_REQUIRED / AUTH_BAD_CREDENTIALS / AUTH_TOKEN_EXPIRED /
 * FORBIDDEN_ROLE —— 客户端只要看到 401 就跳登录页，不必解析 body。
 */
public func apiErrorSpec(code: String): (Int64, String) {
    // 认证 / 鉴权
    if (code == "AUTH_REQUIRED") {
        return (401, "未登录或缺少令牌")
    }
    if (code == "AUTH_BAD_CREDENTIALS") {
        return (401, "账号或密码错误")
    }
    /*
     * 登录被限流（P1 安全加固，2026-10-07 增）。
     *
     * ⚠ 用 **429 Too Many Requests** 而不是 401：语义上是"你被限流了"，
     *   而不是"凭据不对"；客户端据此提示"请 N 分钟后再试"并读 `Retry-After` 头。
     *
     * ⚠⚠ 关于"会不会成为账号枚举的 oracle"——**不会**，但理由必须写清：
     *   限流是**按登录名**记的，而**不存在的登录名同样会被限流**
     *   （计数表 auth_login_attempt 与 auth_user 无外键，见 schema.cj 的说明）。
     *   所以"连续输错 5 次"这个动作对存在/不存在的名字**结果完全一样**：
     *   都是第 6 次拿到 429。攻击者无法据此判断账号是否存在。
     */
    if (code == "AUTH_RATE_LIMITED") {
        return (429, "登录失败次数过多，请稍后再试")
    }
    if (code == "AUTH_TOKEN_EXPIRED") {
        return (401, "登录已过期，请重新登录")
    }
    if (code == "FORBIDDEN_ROLE") {
        return (403, "当前角色无权执行此操作")
    }
    // 参数
    if (code == "VALIDATION_FAILED") {
        return (400, "参数校验失败")
    }
    // 号源 / 挂号（业务语义）
    if (code == "SCHEDULE_NOT_FOUND") {
        return (404, "排班不存在或已停诊")
    }
    /*
     * ★ 2026-10-17 增：同一医生同一天同一时段不能建两条排班。
     * ⚠ 与 `SCHEDULE_NOT_FOUND` 分开：这条**不是**找不到，而是"已经有了、去改它"。
     *   压成 404「排班不存在」会让调用方以为要重试 —— 而重试**永远建不出来**。
     */
    if (code == "SCHEDULE_EXISTS") {
        return (409, "该医生在该时段的排班已存在，请直接修改已有排班")
    }
    if (code == "APPOINTMENT_NOT_FOUND") {
        return (404, "挂号单不存在")
    }
    if (code == "USER_NOT_FOUND") {
        return (404, "账号不存在")
    }
    /*
     * 预问诊会话不存在（P2，2026-10-07 增）。
     *
     * ⚠ 刻意用 **404** 而不是 403：403 等于告诉调用方
     *   「这个 session_id **存在**、只是不属于你」—— 那是个枚举 oracle，
     *   攻击者可据此试探哪些会话 id 有效。404 对"不存在"与"不属于你"给同一答案。
     */
    if (code == "PREVISIT_NOT_FOUND") {
        return (404, "预问诊会话不存在或已失效")
    }
    if (code == "USER_EXISTS") {
        return (409, "登录名已存在")
    }
    if (code == "SLOT_GONE") {
        return (409, "号源已被抢完，请选择其它排班")
    }
    if (code == "SLOT_NOT_RESTORED") {
        return (409, "已退号，但号源归还异常，请联系人工处理")
    }
    /*
     * ★ 2026-10-12（代码检查报告第 1 条）：退号必须走状态机，只有 `booked` 能退。
     *
     * 为什么是 **409** 而不是 404：这张单**确实存在**，只是当前状态不允许这个操作 ——
     *   用 404 会把"已就诊完成，不能退号"说成"挂号单不存在"，
     *   患者拿着这句提示去问谁都查不出原因（报告里点名的误报就在这里）。
     * 文案刻意**不含状态名**：具体状态由 handler 用 `visitStatusLabel` 拼进消息
     *   （这一层只给"说不出状态时"的兜底文案）。
     */
    if (code == "APPOINTMENT_NOT_CANCELLABLE") {
        return (409, "该挂号单当前状态不允许退号（只有「已挂号」可以退）")
    }
    /*
     * ★ 2026-10-17 增：状态没问题（仍是 `booked`），但**病历已定稿**。
     *
     * ⚠ 与 `APPOINTMENT_NOT_CANCELLABLE` **必须分开**：处置完全不同 ——
     *   那条是"刷新看看"，这条是"刷新永远没用，要先把病历定稿状态处理掉"。
     * ⚠ 必须登记在这里，否则落到兜底 `(500, "服务器内部错误")` ——
     *   那就是上面 135-142 行记过的那个坑（正常业务拒绝被报成服务端故障）。
     */
    if (code == "APPOINTMENT_RECORD_LOCKED") {
        return (409, "该挂号单的病历已定稿，不能退号")
    }
    if (code == "ROUTE_NOT_FOUND") {
        return (404, "接口不存在")
    }
    /*
     * ★ 2026-10-17（S14 修）增：框架层两条错误也纳入同一张码表。
     *
     * 为什么"用不到"也要登记：这张表是**客户端可见 code 集合**的唯一来源
     *   （文件顶部与下面 P4 那段都强调过"新错误码必须在这里登记"）。
     *   路由器 405 与静态层 416 从今天起会以本项目的信封发出去，客户端因此会
     *   真的看到这两个 code —— 不登记就等于让 `code` 集合出现表外成员，
     *   而这正是先前"落到兜底 500"那个坑的同源问题。
     * ⚠ 实际响应文案由调用处决定（router 的 errorBody 钩子会把"允许的方法/路径"
     *   拼进 message、静态层用可配 body 字符串），这里的文案只是
     *   `apiError("METHOD_NOT_ALLOWED")` 这种直接调用时的兜底。
     */
    if (code == "METHOD_NOT_ALLOWED") {
        return (405, "该接口不支持此请求方法")
    }
    if (code == "RANGE_NOT_SATISFIABLE") {
        return (416, "请求的字节范围超出文件大小")
    }
    /*
     * ★ P4（2026-10-07）：病历与接诊的四个错误码。
     *
     * ⚠⚠ **我漏了这一步，实测代价是四个端点全返回 500**：
     *   `apiErrorSpec` 是"错误码 → (HTTP 状态, 文案)"的**唯一映射表**，
     *   没登记就落到最后的兜底 `(500, "服务器内部错误")`。
     *   于是"病历已锁定，不能改"这种**正常的业务拒绝**被报成了服务端故障，
     *   客户端完全无法据此做正确提示。
     *   📌 而纯逻辑层的 accept 测试**抓不到这个**：它直接调仓储、
     *     不经过 HTTP 映射 —— 所以这一条是**端到端脚本**抓出来的。
     *     ⇒ 新增错误码必须同时补这里，且必须有**走 HTTP 的**用例（不能只测仓储）。
     */
    /*
     * 病历不存在 / 尚未提交。
     * ⚠ 404：草稿对患者也走这个码，与"没有病历"**不可区分** ——
     *   否则 403 会告诉患者"这里确实有一份还没写好的病历"。
     */
    if (code == "EMR_NOT_FOUND") {
        return (404, "病历不存在或尚未提交")
    }
    /*
     * 病历已提交锁定，不可再改（**409 而不是 400**）。
     * ⚠ 这是**状态冲突**，不是请求格式错：同样的请求在"锁定前"是合法的。
     *   客户端据此应提示"需管理员解锁"，而不是"参数有误"。
     */
    if (code == "EMR_LOCKED") {
        return (409, "病历已提交锁定，不可修改（需管理员解锁）")
    }
    if (code == "EMR_CHANGED") {
        return (409, "病历已被其他操作修改，请重新读取后确认")
    }
    /*
     * ★ 2026-10-15（改进 3）：请求的那一版修订不存在。
     * ⚠ 404（不是 400）：`version` 是个**资源标识**（`/revisions/:version`），
     *   版本号合法但不存在，与路径写错同类 —— 都是"这个资源没有"。
     *   给 400 会把"版本被清理了/你记错了"说成"参数格式错"。
     */
    if (code == "REVISION_NOT_FOUND") {
        return (404, "该病历没有这一版修订")
    }
    /* 完成就诊前必须先提交锁定病历（409：当前状态不允许该操作）。 */
    if (code == "EMR_NOT_LOCKED") {
        return (409, "完成就诊前必须先提交锁定病历")
    }
    /*
     * 接诊状态不允许该流转（409）。
     * ⚠ 例如对已 `done` 的单再"开始接诊" —— 状态冲突，不是参数错。
     */
    if (code == "VISIT_BAD_STATE") {
        return (409, "当前就诊状态不允许该操作")
    }
    /*
     * ★ 2026-10-18：就诊日期门槛 —— 未来日期的号不能进到院/候诊/接诊（409）。
     * ⚠ 与 `VISIT_BAD_STATE` 分开：那条是"状态不允许"，这条是"日子还没到"，
     *   客户端提示语完全不同（一个是"这张单已结束"，一个是"这个号不是今天的"）。
     */
    if (code == "VISIT_DATE_FUTURE") {
        return (409, "该号的就诊日还没到，不能到院登记或接诊")
    }

    /*
     * ★ 2026-10-09：基础数据域（科室/医生）的三个错误码。
     *
     * ⚠ 又一次提醒（P4 真踩过）：**新错误码必须在这里登记**，
     *   否则落到兜底 `(500, "服务器内部错误")`，把正常的业务拒绝
     *   （"同名已存在"、"不能删因为有排班"）报成服务端故障。
     *   而且**纯逻辑层测试抓不到** —— 必须有走 HTTP 的用例。
     */
    if (code == "BASE_NOT_FOUND") {
        return (404, "科室或医生不存在")
    }
    /* 同名/同编码 ⇒ 409（**不是** 400：请求本身合法，是与既有数据冲突）。 */
    if (code == "BASE_NAME_TAKEN") {
        return (409, "同名已存在")
    }
    if (code == "BASE_CODE_TAKEN") {
        return (409, "该编码已被占用")
    }
    /*
     * ★ P5 知识库两个码。
     *
     * ⚠ **又一次**提醒（P4 真踩过、P5 差点再踩）：**新错误码必须在这里登记**，
     *   否则落到兜底 `(500, "服务器内部错误")`，把正常的业务拒绝
     *   （"文档不存在"、"同名文档已存在"）报成服务端故障。
     *   而且**纯逻辑层测试抓不到** —— 必须有走 HTTP 的用例（`kb-check.ps1` 覆盖）。
     */
    if (code == "KB_DOC_NOT_FOUND") {
        return (404, "知识库文档不存在")
    }
    /* 同名文档 ⇒ 409（请求本身合法，是与既有数据冲突）。 */
    if (code == "KB_TITLE_TAKEN") {
        return (409, "已存在同名知识库文档")
    }
    /* 被引用不能删 ⇒ 409。消息由 handler 给出（含"被谁引用"的具体数字）。 */
    if (code == "BASE_IN_USE") {
        return (409, "该记录正被引用，不能删除")
    }
    /*
     * ★ 2026-10-12：公告域两个码。
     *
     * ⚠ **第四次**提醒（P4 真踩过、P5 差点再踩）：新错误码必须在这里登记，
     *   否则落到兜底 `(500, "服务器内部错误")`，把"公告不存在"这种正常业务拒绝
     *   报成服务端故障；而**纯逻辑层测试抓不到**（它直接调仓储、不经过 HTTP 映射）
     *   ⇒ 必须有走 HTTP 的用例（本轮由 `curl` 逐端点验证 + 回归脚本覆盖）。
     */
    if (code == "NOTICE_NOT_FOUND") {
        return (404, "公告不存在")
    }
    /* 同名公告 ⇒ 409（请求本身合法，是与既有数据冲突）。 */
    if (code == "NOTICE_TITLE_TAKEN") {
        return (409, "已存在同名公告")
    }
    /*
     * ★ 2026-10-14：AI 模型配置三个码（管理台「AI 模型配置」页）。
     *
     * ⚠ **第五次**提醒（P4/P5/公告都踩过或差点踩）：新错误码必须在这里登记，
     *   否则落到兜底 `(500, "服务器内部错误")`，把"配置不存在"/"同名配置"
     *   这种正常业务拒绝报成服务端故障；而**纯逻辑层测试抓不到**
     *   ⇒ 本轮由 `server/tests/ai-model-check.ps1` 逐条钉住这四个码的 HTTP 状态。
     */
    if (code == "AI_MODEL_NOT_FOUND") {
        return (404, "模型配置不存在")
    }
    /* 同名配置 ⇒ 409（请求本身合法，是与既有数据冲突）。 */
    if (code == "AI_MODEL_NAME_TAKEN") {
        return (409, "同名模型配置已存在")
    }
    /*
     * ★ 排班被并发修改 ⇒ 409。
     *
     * ⚠ 用 409（不是 404/400）：排班**存在**、请求**合法**，只是"我基于的版本"
     *   已经被别人改过了 —— 这正是 409 的语义，也是唯一能让管理台提示
     *   "请刷新后重试"的码（用 400 会被当成"你填错了参数"）。
     */
    if (code == "SCHEDULE_CONFLICT") {
        return (409, "该排班已被他人修改，请刷新后重试")
    }
    /*
     * ★ 2026-10-14（第三方复查 A4 修）：把"抛了但没登记"的三个码补齐。
     *
     * 它们**已经在抛**，只是没在这张表里 —— 于是走到 :251 的兜底 (500, "服务器内部错误")，
     * 客户端拿到一个**未文档化的 code**（`INTERNAL_ERROR`），而响应文案却与
     * 登记表里那个"服务器内部错误"一模一样 ⇒ 看起来像服务端故障，实为契约缺口。
     *
     * 三个码的语义都是 500（它们确实是服务端侧的写失败/意外），所以这里补登记
     * **不改变任何行为**，只是让"响应里的 code"重新等于"文档里的 code"：
     *   · `INTERNAL_ERROR` —— `http_base.cj` 的 `baseThrowOnFailure`（科室/医生全部写操作）
     *     与 `http_notice.cj` 的写失败；
     *   · `KB_WRITE_FAILED` —— `http_kb.cj` 的文档写失败；
     *   · `INTERNAL` —— `http_common.cj` 自身兜底 handler、`http_app.cj`、`http_p4.cj`
     *     （与兜底同值，登记它只是为了"客户端看到的 code 集合"有界且可枚举）。
     */
    if (code == "INTERNAL_ERROR") {
        return (500, "服务器内部错误")
    }
    if (code == "KB_WRITE_FAILED") {
        return (500, "知识库写入失败")
    }
    if (code == "INTERNAL") {
        return (500, "服务器内部错误")
    }
    return (500, "服务器内部错误")
}

/* 业务错误构造（状态码由错误码表决定，调用方不必记 401/403 的数字）。 */
public func apiError(code: String): ApiError {
    let spec = apiErrorSpec(code)
    return ApiError(code, spec[0], spec[1], None)
}

public func apiErrorMsg(code: String, msg: String): ApiError {
    let spec = apiErrorSpec(code)
    return ApiError(code, spec[0], msg, None)
}

public func apiErrorFields(code: String, msg: String, fields: JsonObject): ApiError {
    let spec = apiErrorSpec(code)
    return ApiError(code, spec[0], msg, fields)
}

/* ===================== 响应写出 ===================== */

/*
 * 统一成功响应：`{"ok":true,"data":{...}}`。
 *
 * ⚠ 必须用 `ctx.status(...).json(...)`：轻舟的 `json()` 会设
 * `content-type: application/json; charset=utf-8`（context.cj:285）。
 * 绝不能先 `body(bytes)` 再 `json()` —— 那样字节体优先，json 被静默丢弃
 * （context.cj:564-568 的选择器规则，是记录过的语言坑）。
 */
public func sendOk(ctx: Context, data: JsonObject): Unit {
    sendEnvelope(ctx, 200, data)
}

public func sendCreated(ctx: Context, data: JsonObject): Unit {
    sendEnvelope(ctx, 201, data)
}

func sendEnvelope(ctx: Context, status: Int64, data: JsonObject): Unit {
    let root = JsonObject()
    root.put("ok", JsonBool(true))
    root.put("data", data)
    ctx.status(status).json(root.toString())
}

/*
 * 统一失败信封的**字符串**形式（2026-10-17 抽出）。
 *
 * 为什么必须抽出来：失败信封此前只在 `sendError(ctx, e)` 里拼一次 —— 而那是一条
 *   **往 ctx 写出**的路径。但有两处错误响应**不经过 ctx 写出**、只接受一个字符串：
 *     · 路由器直接写出的 404/405（`router.cj` 的 `errorBody` 钩子，见 http_app.cj 的装配处）；
 *     · 静态层的 404/403/416（`static.cj` 的 `notFoundBody` / `forbiddenBody` /
 *       `rangeNotSatisfiableBody`）。
 *   若各处各拼各的，信封形状就会有第二、第三处定义，迟早漂移 —— 而这类漂移正是
 *   本次 S14 的来源（框架三处错误体各写各的形状，客户端要写三套解析）。
 *   ⇒ 定义收敛到这里，`sendError` 与两个钩子共用同一份。
 */
public func errorEnvelopeString(code: String, message: String, fields: ?JsonObject): String {
    let err = JsonObject()
    err.put("code", JsonString(code))
    err.put("message", JsonString(message))
    match (fields) {
        case Some(f) => err.put("fields", f)
        case None => ()
    }
    let root = JsonObject()
    root.put("ok", JsonBool(false))
    root.put("error", err)
    return root.toString()
}

/* 统一失败响应。 */
public func sendError(ctx: Context, e: ApiError): Unit {
    ctx.status(e.status_).json(errorEnvelopeString(e.code, e.message, e.fields))
}

/*
 * ★ 2026-10-17：body parser 的错误出口也走**统一信封**。
 *
 * 背景（实测抓到的契约违反）：框架的 `defaultBodyParserError`
 *   （third_party/qingzhou/src/bodyparser.cj:50-54）自己写
 *   `{"code":400,"message":"Invalid JSON body","data":null}` —— 既没有 `ok` 字段，
 *   也没有 `error` 对象。而客户端严格按三段式信封读 `ok` / `error.code`
 *   （契约见 docs/dev/HARMONY-INTERFACE-GUIDE.md；common-core 的 `HttpClient.parseResponse`
 *   也是这么实现的），于是"请求体不是合法 JSON"这种**客户端自己就能修**的错误，
 *   在界面上会退化成一个与真因毫无关系的报错。
 *
 * ⚠ 为什么必须在**挂中间件**这一层换掉，而不能改 handler：
 *   body parser 在进入 handler **之前**就回应了并短路（`handleJson` 返回 false
 *   后不调 next），所以业务层里那套正确写法（`http_app.cj` 的 `bodyObj()`
 *   → `ctx.bodyJsonError()` → `VALIDATION_FAILED`）**根本执行不到**。
 * ⚠ 复用 `sendError`：任何出口的信封形状只允许有**一处**定义。
 */
public func hospitalBodyParserError(ctx: Context, status: Int64, message: String): Unit {
    /*
     * 框架传的是英文短语，这里按状态给中文文案。
     * ⚠ 413 的文案刻意**不写具体数字**：同一个 onError 被两处复用 ——
     *   外层 `contentLengthLimit(64 KiB)`（按 Content-Length 预检）与
     *   内层 `bodyParser`（默认 1 MiB，兜 chunked），两个上限不同，
     *   写死任何一个数字都会在另一个出口上撒谎。
     */
    let msg = if (status == 413) {
        "请求体过大，超出服务端允许的上限"
    } else {
        "请求体不是合法 JSON"
    }
    /* 原始英文短语只进服务端日志，不进响应体 —— 免得客户端里混两种语言。 */
    println("[BODY] 请求体被中间件拒绝：status=" + status.toString() + " framework=" + message)
    sendError(ctx, ApiError("VALIDATION_FAILED", status, msg, None))
}

/*
 * body parser 的选项：把错误出口换成统一信封后交给 `bodyParser(...)`。
 *
 * ⚠ 为什么要有这个工厂函数：`BodyParserOptions.onError` 是**可变字段**，
 *   给字段赋值需要一个"有名字的落点"（`let o = BodyParserOptions(); o.onError = f`）。
 *   集中在这里也便于以后调 `maxBytes`（当前沿用框架默认 1 MiB）。
 * 📌 本项目 38 个业务文件全部声明 `package qingzhou`（与服务端框架**同包同编**），
 *   所以这里不需要 import —— `BodyParserOptions` 直接可见。
 */
public func hospitalBodyParserOptions(): BodyParserOptions {
    let opts = BodyParserOptions()
    opts.onError = hospitalBodyParserError
    return opts
}

/*
 * 外层 `contentLengthLimit` 闸门的选项：同样换成统一信封，并保留原有的 64 KiB 上限。
 *
 * ⚠ 这是 S14 的**第二处**出口，容易漏：`http_app.cj` 原先调的是便利函数
 *   `contentLengthLimit(maxBytes)`（bodyparser.cj:168-172），它在内部 new 了
 *   `ContentLengthLimitOptions()` 走**默认** `onError`，于是 413 仍回
 *   `{"code":413,"message":"Request body too large","data":null}` —— 实测抓到的残留。
 *   便利函数不接受 onError，所以这里必须自己组 opts。
 * 📌 `onIndeterminate` 保持默认 Pass（无 Content-Length 时放行，交给内层兜底）。
 */
public func hospitalContentLengthLimitOptions(maxBytes: Int64): ContentLengthLimitOptions {
    let opts = ContentLengthLimitOptions()
    opts.maxBytes = maxBytes
    opts.onError = hospitalBodyParserError
    return opts
}

/*
 * 统一异常出口（挂在 `app.onError(...)`）。照搬迁前的 main.cj:909-917。
 *
 * 为什么必须自己写而不是用框架的 `jsonErrorHandler()`：
 *   框架那个输出的是它自己的 `{"error":...}` 形状，与我们 `{ok:false,error:{...}}`
 *   的统一口径不一致；混用会让客户端遇到两套错误格式。
 */
/*
 * ★ 可直接回给客户端的异常（2026-10-07 加）。
 *
 * ── 为什么需要它 ─────────────────────────────────────────────────────────
 * 仓储层（auth_repo / domain_booking）会在**校验失败**时抛异常，
 * 例如口令强度不足、账号不存在。这些异常默认会被 hospitalErrorHandler
 * 归为 `INTERNAL` ⇒ **回 500**，但它们的性质是"你的请求不对"（4xx）。
 *
 * 两条路都不可取：
 *   · 全部当 500 ⇒ 客户端以为服务端坏了，而实际是它自己该改请求；
 *   · 在 handler 里**按消息字符串** contains("口令强度不足") 匹配 ⇒
 *     改一个字就静默失效（这正是本项目反复吃过的"两处口径"坑）。
 *
 * 所以用**类型**表达：仓储层抛 `UserFacingError(message)`，
 * handler 认出这个类型后回 400 `VALIDATION_FAILED` 并把 message 带给客户端。
 *
 * ⚠ 安全边界：只有**我们自己的代码**能构造这个类型，且 message 是我们写的文案，
 *   所以回给客户端是安全的。**绝不要**用外部输入（如 SQL 报错原文）构造它 ——
 *   那会把内部细节泄露出去。真·内部异常仍然只进日志（见 handler 的 else 分支）。
 */
public class UserFacingError <: Exception {
    public UserFacingError(message: String) {
        super(message)
    }
}

public func hospitalErrorHandler(ctx: Context): Unit {
    match (ctx.err()) {
        case Some(e: ApiError) => sendError(ctx, e)
        case Some(e: UserFacingError) =>
            /*
             * 仓储层明确标记"这是给用户看的校验失败" ⇒ 400，且**保留原因**。
             * 原因文案由我们自己的代码写（不含内部细节），所以可以回。
             */
            let spec = apiErrorSpec("VALIDATION_FAILED")
            sendError(ctx, ApiError("VALIDATION_FAILED", spec[0], e.message, None))
        case Some(e) =>
            // 其它异常：细节只进服务端日志，不回给客户端
            println("[ERROR] ${ctx.method()} ${ctx.path()} -> ${e.message}")
            let spec = apiErrorSpec("INTERNAL")
            sendError(ctx, ApiError("INTERNAL", spec[0], spec[1], None))
        case None =>
            /*
             * 走到这里有两种情况（2026-10-14 评审 E2）：
             *   ① 正常路径：请求本来就没抛异常（绝大多数）；
             *   ② 异常被**某个中间件消费掉**了（`ctx.err()` 被清空），
             *      但那个中间件忘了写响应 —— 客户端会拿到空 200 或一直挂起，
             *      比 500 更难排查。
             * 所以只在"确实一个字都没写过响应"时补一个 500 兜底。
             * 判据用 `_committed`（已提交）或 body 非空（已写但未提交）：
             * 只看 `_committed` 会把"已写 body 还没 commit"的响应又写一遍。
             */
            let alreadyWritten = ctx._committed || ctx._peekBody().size > 0
            if (!alreadyWritten) {
                println("[ERROR] ${ctx.method()} ${ctx.path()} -> 异常被消费但未写响应，兜底回 500")
                let spec = apiErrorSpec("INTERNAL")
                sendError(ctx, ApiError("INTERNAL", spec[0], spec[1], None))
            }
    }
}

/* ===================== 请求读取小工具 ===================== */

/*
 * 取必填字符串字段。缺失或空串 → 抛 VALIDATION_FAILED 并**指明是哪个字段**。
 *
 * 为什么返回错误信息里带字段名：三端客户端并存时，"参数校验失败"这种话
 * 排查成本很高；带上字段名能让前端直接定位。
 */
public func requireStr(ctx: Context, key: String): String {
    match (bodyStr(ctx, key)) {
        case Some(v) =>
            if (v.size == 0) {
                throw apiErrorMsg("VALIDATION_FAILED", "字段 ${key} 不能为空")
            }
            return v
        case None =>
            throw apiErrorMsg("VALIDATION_FAILED", "缺少必填字段 ${key}")
    }
}

/*
 * 读可选的**布尔**字段（P3 第二块新增：工具开关用）。
 *
 * ⚠ 只认 JSON 的 `true` / `false` —— 不接受 `"1"` / `"yes"` / `"on"` 这类写法。
 *   理由与"工具开关只接受 0/1"同源：**多一种写法就多一处口径**，
 *   而布尔字段没必要给表达空间。缺字段返回 None（与"显式 false"区分开），
 *   让调用方能给出"缺少必填字段 enabled"这种准确报错。
 */
public func bodyBool(ctx: Context, key: String): ?Bool {
    let o = bodyObj(ctx)
    match (o.get(key)) {
        case Some(v) =>
            /*
             * ⚠⚠ **必须先判类型再取值**（实测踩出来的）：
             *   原实现直接 `v.asBool().getValue()`，于是 `{"enabled":"yes"}`
             *   （字符串）会让 `asBool()` **抛异常** ⇒ 走到全局兜底 ⇒ **500**。
             *   而"字段类型不对"是**客户端错误**（400），不是服务端故障。
             *   实测：`PUT /admin/ai/tools/x {"enabled":"yes"}` -> 500。
             *
             *   ⇒ 现在：不是布尔就返回 `None`，由调用方给出准确的 400
             *     （"缺少必填字段 enabled（true/false）"）。
             *   📌 一般规律：**读用户输入时，先用 `is` 判类型，再取值**。
             *     直接 `asXxx()` 在类型不符时是抛异常而不是返回 None。
             */
            if (v is JsonBool) {
                return Some(v.asBool().getValue())
            }
            return None
        case None => return None
    }
}

public func requireInt(ctx: Context, key: String): Int64 {
    match (bodyInt64(ctx, key)) {
        case Some(v) => return v
        case None => throw apiErrorMsg("VALIDATION_FAILED", "缺少必填数值字段 ${key}")
    }
}

/*
 * 读可选的**浮点**字段（2026-10-14 新增：AI 模型配置的 `temperature`）。
 *
 * ⚠ 与 `bodyBool` 同一条纪律：**先判类型再取值** —— `asFloat()` 在类型不符时
 *   **抛异常**（不是返回 None），会一路走到全局兜底变成 500，
 *   而"字段类型不对"是**客户端错误**（400）。
 * ⚠ **整数也接受**：JSON 里 `1` 与 `1.0` 都是数字，没有理由因为少打一个 `.0` 就拒。
 *   （范围校验另有其人：`aiModelValidate` 管 0..2，这里只管"读出来是个数"。）
 */
public func bodyFloatOpt(ctx: Context, key: String): ?Float64 {
    let o = bodyObj(ctx)
    match (o.get(key)) {
        case Some(v) =>
            if (v is JsonFloat) {
                return Some(v.asFloat().getValue())
            }
            if (v is JsonInt) {
                return Some(Float64(v.asInt().getValue()))
            }
            return None
        case None => return None
    }
}
