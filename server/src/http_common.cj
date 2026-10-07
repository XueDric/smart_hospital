/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 *
 * ===== http_common.cj —— HTTP 响应/错误公共层 ==============================
 *
 * 统一响应口径（与基线一致，便于客户端复用同一套解析代码）：
 *   成功：200/201 `{"ok":true,"data":{...}}`
 *   失败：`{"ok":false,"error":{"code":"...","message":"...","fields":{...}}}`
 *   —— HTTP 状态码给网络层用（401 直接踢回登录页，不必解析 body），
 *      error.code 给业务层用（客户端 switch 出文案）。这是基线 api-design §1.2 的分工。
 *
 * ⚠ 一处关键纪律：**绝不向客户端暴露内部堆栈**。未列出的异常一律 500 + "服务器内部错误"，
 *   细节只进服务端日志（照 baseline/server/src/main.cj:909-917 的 errHandler）。
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
    if (code == "APPOINTMENT_NOT_FOUND") {
        return (404, "挂号单不存在")
    }
    if (code == "USER_NOT_FOUND") {
        return (404, "账号不存在")
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
    if (code == "ROUTE_NOT_FOUND") {
        return (404, "接口不存在")
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
 * （context.cj:564-568 的选择器规则，是 API-NOTES 记过的坑）。
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

/* 统一失败响应。 */
public func sendError(ctx: Context, e: ApiError): Unit {
    let err = JsonObject()
    err.put("code", JsonString(e.code))
    err.put("message", JsonString(e.message))
    match (e.fields) {
        case Some(f) => err.put("fields", f)
        case None => ()
    }
    let root = JsonObject()
    root.put("ok", JsonBool(false))
    root.put("error", err)
    ctx.status(e.status_).json(root.toString())
}

/*
 * 统一异常出口（挂在 `app.onError(...)`）。照 baseline/server/src/main.cj:909-917。
 *
 * 为什么必须自己写而不是用框架的 `jsonErrorHandler()`：
 *   框架那个输出的是它自己的 `{"error":...}` 形状，与我们 `{ok:false,error:{...}}`
 *   的统一口径不一致；混用会让客户端遇到两套错误格式。
 */
public func hospitalErrorHandler(ctx: Context): Unit {
    match (ctx.err()) {
        case Some(e: ApiError) => sendError(ctx, e)
        case Some(e) =>
            // 细节只进服务端日志，不回给客户端
            println("[ERROR] ${ctx.method()} ${ctx.path()} -> ${e.message}")
            let spec = apiErrorSpec("INTERNAL")
            sendError(ctx, ApiError("INTERNAL", spec[0], spec[1], None))
        case None => ()
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

public func requireInt(ctx: Context, key: String): Int64 {
    match (bodyInt64(ctx, key)) {
        case Some(v) => return v
        case None => throw apiErrorMsg("VALIDATION_FAILED", "缺少必填数值字段 ${key}")
    }
}
