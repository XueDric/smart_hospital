package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * token-based authentication middleware.
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * 无状态 token 鉴权（前后端分离友好），基于标准 JWT（HS256，带 exp 过期）：
 *   - issueToken(userId, secret)      签发 JWT（默认 2 小时有效）
 *   - issueTokenTtl(userId, secret, ttlSeconds) 签发指定时长的 JWT
 *   - verifyToken(token, secret)      校验签名 + 过期，取回 userId
 *   - authRequired(secret)            中间件：校验 Authorization: Bearer <token>
 *
 * 校验通过后把 userId 写入 ctx.state["userId"]，业务代码用
 * ctx.getStateOr("userId", "") 读取。
 */

/* 默认 token 有效期（秒）：2 小时。 */
public let DEFAULT_TOKEN_TTL: Int64 = 7200

/* 签发 token（默认 2 小时有效）。 */
public func issueToken(userId: String, secret: String): String {
    return jwtIssue(userId, secret, DEFAULT_TOKEN_TTL)
}

/* 签发指定时长的 token。 */
public func issueTokenTtl(userId: String, secret: String, ttlSeconds: Int64): String {
    return jwtIssue(userId, secret, ttlSeconds)
}

/* 校验 token（签名 + 过期），通过返回 userId，否则 None。 */
public func verifyToken(token: String, secret: String): ?String {
    return jwtVerify(token, secret)
}

/*
 * 鉴权中间件：要求 Authorization: Bearer <token>。
 * 只保护 /api 与 /admin 开头的路径（静态资源、SPA 页面直接放行），
 * 校验通过 -> ctx.state["userId"] 写入并放行；否则 401 并短路（不调 next）。
 */
public func authRequired(secret: String): Middleware {
    return { ctx: Context, next: () -> Unit =>
        // 仅对 /api、/admin 路径做鉴权，其余（静态/页面）放行。
        let p = ctx.path()
        let isApi = p.size >= 4 && p[0..4] == "/api"
        let isAdmin = p.size >= 6 && p[0..6] == "/admin"
        if (!isApi && !isAdmin) {
            next()
            return
        }
        match (ctx.requestHeader("Authorization")) {
            case Some(h) =>
                match (extractBearer(h)) {
                    case Some(t) =>
                        match (verifyToken(t, secret)) {
                            case Some(userId) =>
                                ctx.setState("userId", userId)
                                next()
                            case None =>
                                respondErr(ctx, 401, "invalid token")
                        }
                    case None =>
                        respondErr(ctx, 401, "invalid authorization header")
                }
            case None =>
                respondErr(ctx, 401, "missing authorization")
        }
    }
}

/* 从 "Bearer <token>" 中提取 token；格式不符返回 None。 */
func extractBearer(header: String): ?String {
    if (header.size > 7 && header[0..7] == "Bearer ") {
        return Some(header[7..])
    }
    return None
}
