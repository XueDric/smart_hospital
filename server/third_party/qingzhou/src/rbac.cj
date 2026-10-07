package qingzhou

import std.convert.*

/*
 * SPDX-License-Identifier: MIT
 *
 * RBAC authorization middleware.
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * requirePermission(store, method, pathPrefix, code) 对「匹配 method + pathPrefix
 * 前缀」的请求做权限校验，其余请求直接放行（透传）。method 用 "*" 表示任意方法。
 *
 * 依赖 authRequired() 先通过 token 鉴权并把用户 id 写入 ctx.state["userId"]。
 *   有权限 -> next()；无权限 -> 403；未登录 -> 401。
 */

public func requirePermission(store: RbacStore, method: String, pathPrefix: String, code: String): Middleware {
    return { ctx: Context, next: () -> Unit =>
        let m = ctx.method()
        let p = ctx.path()
        let methodMatch = (method == "*" || m == method)
        let pathMatch = (p.size >= pathPrefix.size && p[0..pathPrefix.size] == pathPrefix)
        if (!(methodMatch && pathMatch)) {
            next()
            return
        }
        let userIdStr = ctx.getStateOr("userId", "")
        if (userIdStr.size == 0) {
            respondErr(ctx, 401, "unauthorized")
            return
        }
        let userId = try { Int64.parse(userIdStr) } catch (e: Exception) { Int64(-1) }
        if (userId < 0) {
            respondErr(ctx, 401, "unauthorized")
            return
        }
        if (store.hasPermission(userId, code)) {
            next()
        } else {
            respondErr(ctx, 403, "forbidden: require ${code}")
        }
    }
}
