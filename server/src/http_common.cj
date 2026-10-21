/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 *
 * ===== http_common.cj —— HTTP 响应/错误公共层 =====
 * 成功 {"ok":true,"data":{...}}；失败 {"ok":false,"error":{code,message,fields}}。
 * HTTP 状态给网络层（401 踢回登录页），error.code 给业务层；绝不外泄堆栈。
 */

package qingzhou

import std.collection.*
import stdx.encoding.json.*

/* ===================== 业务错误 ===================== */

/* 业务错误：HTTP 状态码 + 机器可读 code + 可选逐字段原因。
 * 只有"请求不合法/无权"才抛；"号被抢走"这类正常业务结果用返回值表达。 */
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

/* 错误码 → (HTTP 状态码, 默认中文文案)，唯一权威。未登记的码一律 500。
 * 新增错误码必须在此登记并配一条走 HTTP 的用例，否则正常业务拒绝会被报成 500。 */
public func apiErrorSpec(code: String): (Int64, String) {
    // 认证 / 鉴权
    if (code == "AUTH_REQUIRED") {
        return (401, "未登录或缺少令牌")
    }
    if (code == "AUTH_BAD_CREDENTIALS") {
        return (401, "账号或密码错误")
    }
    /* 429：被限流而非凭据错；按登录名计数，不构成账号枚举 oracle。 */
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
    /* 409：排班已存在，压成 404 会让调用方误以为可重试。 */
    if (code == "SCHEDULE_EXISTS") {
        return (409, "该医生在该时段的排班已存在，请直接修改已有排班")
    }
    if (code == "APPOINTMENT_NOT_FOUND") {
        return (404, "挂号单不存在")
    }
    if (code == "USER_NOT_FOUND") {
        return (404, "账号不存在")
    }
    /* 404 不是 403："不存在"与"不属于你"同答，避免枚举 oracle。 */
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
    /* 409：单存在但状态不允许退号，不能报成 404。 */
    if (code == "APPOINTMENT_NOT_CANCELLABLE") {
        return (409, "该挂号单当前状态不允许退号（只有「已挂号」可以退）")
    }
    /* 409：病历已定稿，需先处理锁定状态；不能与不可退号合并。 */
    if (code == "APPOINTMENT_RECORD_LOCKED") {
        return (409, "该挂号单的病历已定稿，不能退号")
    }
    if (code == "ROUTE_NOT_FOUND") {
        return (404, "接口不存在")
    }
    /* 405/416 也纳入本表：客户端可见 code 集合必须在此有界。 */
    if (code == "METHOD_NOT_ALLOWED") {
        return (405, "该接口不支持此请求方法")
    }
    if (code == "RANGE_NOT_SATISFIABLE") {
        return (416, "请求的字节范围超出文件大小")
    }
    /* 404：草稿也走此码，与"没有病历"不可区分，否则泄露存在性。 */
    if (code == "EMR_NOT_FOUND") {
        return (404, "病历不存在或尚未提交")
    }
    /* 409：状态冲突而非请求格式错，同样的请求在锁定前合法。 */
    if (code == "EMR_LOCKED") {
        return (409, "病历已提交锁定，不可修改（需管理员解锁）")
    }
    if (code == "EMR_CHANGED") {
        return (409, "病历已被其他操作修改，请重新读取后确认")
    }
    /* 404：version 是资源标识，合法但不存在同属"资源没有"。 */
    if (code == "REVISION_NOT_FOUND") {
        return (404, "该病历没有这一版修订")
    }
    /* 完成就诊前必须先提交锁定病历（409：当前状态不允许该操作）。 */
    if (code == "EMR_NOT_LOCKED") {
        return (409, "完成就诊前必须先提交锁定病历")
    }
    /* 409：状态不允许该流转，不是参数错。 */
    if (code == "VISIT_BAD_STATE") {
        return (409, "当前就诊状态不允许该操作")
    }
    /* 409：日子没到，与"状态不允许"分开给文案。 */
    if (code == "VISIT_DATE_FUTURE") {
        return (409, "该号的就诊日还没到，不能到院登记或接诊")
    }

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
    if (code == "NOTICE_NOT_FOUND") {
        return (404, "公告不存在")
    }
    /* 同名公告 ⇒ 409（请求本身合法，是与既有数据冲突）。 */
    if (code == "NOTICE_TITLE_TAKEN") {
        return (409, "已存在同名公告")
    }
    if (code == "AI_MODEL_NOT_FOUND") {
        return (404, "模型配置不存在")
    }
    /* 同名配置 ⇒ 409（请求本身合法，是与既有数据冲突）。 */
    if (code == "AI_MODEL_NAME_TAKEN") {
        return (409, "同名模型配置已存在")
    }
    /* 409：排班被并发修改，客户端需刷新后重试。 */
    if (code == "SCHEDULE_CONFLICT") {
        return (409, "该排班已被他人修改，请刷新后重试")
    }
    /* 未登记会落到兜底 500，客户端看到表外 code；新增码必须同步登记。 */
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

/* 同上，但换成自定义 message（必须是自己写的文案）。 */
public func apiErrorMsg(code: String, msg: String): ApiError {
    let spec = apiErrorSpec(code)
    return ApiError(code, spec[0], msg, None)
}

/* 同上，附逐字段原因：fields 原样进信封，供前端定位表单。 */
public func apiErrorFields(code: String, msg: String, fields: JsonObject): ApiError {
    let spec = apiErrorSpec(code)
    return ApiError(code, spec[0], msg, fields)
}

/* ===================== 响应写出 ===================== */

/* 统一成功响应；必须用 ctx.status(...).json(...)：先 body(bytes) 再 json() 会静默丢弃 json。 */
public func sendOk(ctx: Context, data: JsonObject): Unit {
    sendEnvelope(ctx, 200, data)
}

/* 201 创建成功。 */
public func sendCreated(ctx: Context, data: JsonObject): Unit {
    sendEnvelope(ctx, 201, data)
}

func sendEnvelope(ctx: Context, status: Int64, data: JsonObject): Unit {
    let root = JsonObject()
    root.put("ok", JsonBool(true))
    root.put("data", data)
    ctx.status(status).json(root.toString())
}

/* 失败信封的唯一构造处：router 的 404/405 与静态层只接受字符串形式。 */
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

/* body parser 的错误出口：框架默认体 {"code":400,...} 会破坏统一信封，必须在挂中间件这层换掉
 * （parser 在 handler 前短路）。413 文案不写具体数字：外层 64 KiB 与内层 1 MiB 上限不同。 */
public func hospitalBodyParserError(ctx: Context, status: Int64, message: String): Unit {
    let msg = if (status == 413) {
        "请求体过大，超出服务端允许的上限"
    } else {
        "请求体不是合法 JSON"
    }
    /* 原始英文短语只进服务端日志，不进响应体。 */
    println("[BODY] 请求体被中间件拒绝：status=" + status.toString() + " framework=" + message)
    sendError(ctx, ApiError("VALIDATION_FAILED", status, msg, None))
}

/* body parser 选项：错误出口换成统一信封；onError 是可变字段，需一个有名字的落点。 */
public func hospitalBodyParserOptions(): BodyParserOptions {
    let opts = BodyParserOptions()
    opts.onError = hospitalBodyParserError
    return opts
}

/* 外层 contentLengthLimit 选项：contentLengthLimit() 不接受 onError，必须自己组 opts。 */
public func hospitalContentLengthLimitOptions(maxBytes: Int64): ContentLengthLimitOptions {
    let opts = ContentLengthLimitOptions()
    opts.maxBytes = maxBytes
    opts.onError = hospitalBodyParserError
    return opts
}

/* 可直接回给客户端的校验失败异常（message 必须是自己的文案，绝不用外部输入构造）。 */
public class UserFacingError <: Exception {
    public UserFacingError(message: String) {
        super(message)
    }
}

/* 统一异常出口（app.onError）：ApiError 原样回，其余 500 且细节只进日志。 */
public func hospitalErrorHandler(ctx: Context): Unit {
    match (ctx.err()) {
        case Some(e: ApiError) => sendError(ctx, e)
        case Some(e: UserFacingError) =>
            /* 400 且保留原因：文案是自己写的，可回给客户端。 */
            let spec = apiErrorSpec("VALIDATION_FAILED")
            sendError(ctx, ApiError("VALIDATION_FAILED", spec[0], e.message, None))
        case Some(e) =>
            // 其它异常：细节只进服务端日志，不回给客户端
            println("[ERROR] ${ctx.method()} ${ctx.path()} -> ${e.message}")
            let spec = apiErrorSpec("INTERNAL")
            sendError(ctx, ApiError("INTERNAL", spec[0], spec[1], None))
        case None =>
            /* 只在确实没写过响应时补 500；判据含 body 非空，不能只看 _committed，
             * 否则会把"已写 body 未 commit"的响应再写一遍。 */
            let alreadyWritten = ctx._committed || ctx._peekBody().size > 0
            if (!alreadyWritten) {
                println("[ERROR] ${ctx.method()} ${ctx.path()} -> 异常被消费但未写响应，兜底回 500")
                let spec = apiErrorSpec("INTERNAL")
                sendError(ctx, ApiError("INTERNAL", spec[0], spec[1], None))
            }
    }
}


/* 取必填字符串字段，缺失/空串抛 VALIDATION_FAILED 并指明字段名。 */
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

/* 读可选布尔字段，只认 JSON true/false；缺字段返回 None（与显式 false 区分）。
 * 不是布尔也返回 None，由调用方给 400，不能直接 asBool() 抛成 500。 */
public func bodyBool(ctx: Context, key: String): ?Bool {
    let o = bodyObj(ctx)
    match (o.get(key)) {
        case Some(v) =>
            /* 必须先判类型再取值：asBool() 类型不符会抛异常，一路变成 500。 */
            if (v is JsonBool) {
                return Some(v.asBool().getValue())
            }
            return None
        case None => return None
    }
}

/* 必填整数：缺失或非整数 ⇒ 400 VALIDATION_FAILED（带字段名）。 */
public func requireInt(ctx: Context, key: String): Int64 {
    match (bodyInt64(ctx, key)) {
        case Some(v) => return v
        case None => throw apiErrorMsg("VALIDATION_FAILED", "缺少必填数值字段 ${key}")
    }
}

/* 读可选浮点字段：整数也接受（JSON 里 1 与 1.0 都是数字）。
 * 同 bodyBool：先判类型再 asFloat()，否则类型不符会变成 500。 */
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
