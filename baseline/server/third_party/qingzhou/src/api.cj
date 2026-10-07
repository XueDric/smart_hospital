package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * unified JSON API response helpers.
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * 前后端分离场景的统一响应壳：
 *   { "code": 0, "message": "ok", "data": <payload> }
 *
 *   code    0 = 成功，非 0 = 业务错误码（HTTP 状态通常也对齐 2xx/4xx/5xx）
 *   message 人类可读的消息（成功固定 "ok"，失败为错误描述）
 *   data    业务数据（成功时有效，失败时为 null）
 *
 * 前端 axios/fetch 统一拦截器据此约定：code !== 0 时提示 message、按需跳登录。
 */

/* 成功响应。data 为「已序列化的 JSON 字符串」（如 "{\"id\":1}" 或 "[1,2]"）。 */
public func respondOk(ctx: Context, data: String): Unit {
    ctx.json("{\"code\":0,\"message\":\"ok\",\"data\":${data}}")
}

/* 成功响应，无数据（data = null）。 */
public func respondOkNull(ctx: Context): Unit {
    ctx.json("{\"code\":0,\"message\":\"ok\",\"data\":null}")
}

/* 失败响应。code 建议用 HTTP 状态码（400/401/403/404/500），message 为错误描述。 */
public func respondErr(ctx: Context, code: Int64, message: String): Unit {
    ctx.json("{\"code\":${code},\"message\":\"${message}\",\"data\":null}")
}
