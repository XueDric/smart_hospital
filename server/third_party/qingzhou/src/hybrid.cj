package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * session + JWT 混合认证。
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * 一套认证逻辑同时接受两种凭证：
 *   1. 无状态 JWT —— Authorization: Bearer <token>（常规 API 调用）
 *   2. 有状态 session —— sid 签名 cookie + 服务端 SessionStore（短期敏感操作）
 *
 * 优先尝试 JWT，未命中再回退 session。业务代码据此做「常规走 JWT、
 * 敏感操作走 session」的混合策略：登录时同时签发 JWT + 建立 session，
 * 敏感接口强制要求 session 凭证（见 requireSession）。
 */

/*
 * 解析当前请求身份，优先 JWT 再 session。
 * 返回 userId（业务身份标识）或 None（未认证）。
 * 前置：session 中间件须先运行（恢复 ctx.state["sid"]）。
 * 约定：session 里存身份用 key "userId"。
 */
public func resolveIdentity(ctx: Context, secret: String, store: SessionStore): ?String {
    // 1. JWT（Bearer）
    match (ctx.requestHeader("Authorization")) {
        case Some(h) =>
            match (extractBearer(h)) {
                case Some(t) =>
                    match (jwtVerify(t, secret)) {
                        case Some(userId) => return Some(userId)
                        case None => ()
                    }
                case None => ()
            }
        case None => ()
    }
    // 2. session（sid -> store["userId"]）
    let sid = ctx.getStateOr("sid", "")
    if (sid.size > 0) {
        match (store.get(sid, "userId")) {
            case Some(userId) => return Some(userId)
            case None => ()
        }
    }
    return None
}

/*
 * 混合认证中间件：JWT 或 session 任一有效即放行，并把 userId 写入
 * ctx.state["userId"]；都无效则 401 短路。
 */
public func hybridAuthRequired(secret: String, store: SessionStore): Middleware {
    return { ctx: Context, next: () -> Unit =>
        match (resolveIdentity(ctx, secret, store)) {
            case Some(userId) =>
                ctx.setState("userId", userId)
                next()
            case None =>
                respondErr(ctx, 401, "unauthorized")
        }
    }
}

/*
 * 强制 session 凭证中间件：仅接受有效 session（忽略 JWT）。
 * 用于「敏感操作必须走 session」的场景（session 可服务端撤销，
 * 生命周期更短，适合改密 / 支付等）。
 */
public func requireSession(secret: String, store: SessionStore): Middleware {
    return { ctx: Context, next: () -> Unit =>
        let sid = ctx.getStateOr("sid", "")
        if (sid.size > 0) {
            match (store.get(sid, "userId")) {
                case Some(userId) =>
                    ctx.setState("userId", userId)
                    next()
                    return
                case None => ()
            }
        }
        respondErr(ctx, 401, "session required")
    }
}
