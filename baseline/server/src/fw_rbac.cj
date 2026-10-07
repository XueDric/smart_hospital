package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * 【本地适配 · 暂时性】轻舟 RBAC 授权中间件 —— 2026-09-14
 *
 * 背景与撤销方式：见 fw_rbac_store.cj 的文件头（同一个适配的两半）。
 *
 * 与轻舟原版 src/rbac.cj 的差异（只有响应出口这一处）
 *   原版用 respondErr(ctx, 401/403, ...) —— 那是轻舟 src/api.cj 的
 *   `{ "code": 0, "message": "ok", "data": ... }` 壳；
 *   我们项目的唯一权威是 api-design.md 冻结的
 *   `{ ok: false, error: { code, message, fields } }`（见 Errors / sendError）。
 *   同一份二进制里出现两套响应格式会让客户端分裂，所以这里**对齐我们的接口**：
 *   改为抛 ApiError，交给统一的 errHandler 出口（main.cj 的 onError），
 *   错误码沿用我们错误码表里已有的两个：
 *     · 未登录   -> AUTH_REQUIRED  (HTTP 401)
 *     · 无权限   -> FORBIDDEN_ROLE (HTTP 403)
 *   判定逻辑（方法 + 路径前缀匹配、其余透传）与原版逐行一致。
 *
 * 依赖 authRequired() 先把用户 id 写进 ctx.state["userId"]（与原版同约定）。
 *
 * ⚠ **本文件当前没有被使用，别照字面以为它生效**（2026-09-16 核实并记下）
 *   · 全仓只有 2 处 `requirePermission` 定义：这里，以及 vendored 轻舟的 `src/rbac.cj`。
 *     `main.cj` 的中间件链里**没有它**；`RbacStore` 只在 `tests.cj` 的
 *     `testRbacAdaptation` 里被构造过。
 *   · 本项目的授权走的是自己那一套：`perms.cj` 的 `can(member, action, target)`
 *     （README 的设计原则"权限判定收敛到一个函数"）。
 *   · 真要把它挂上，**必须先有东西往 `ctx.state["userId"]` 写值** ——
 *     `server/src` 里没有任何 `setState`，而 vendored 轻舟的 `authRequired(secret)`
 *     （third_party/qingzhou/src/auth.cj）是无状态 HMAC 签名令牌，与我们的
 *     服务端令牌表（`auth.cj` 的 `issueToken`）不是一套。
 *     直接挂上去的结果是**所有受保护请求 100% 401**。
 *   · 所以它的定位是：编译接缝（保证与上游同名同签名、升级时能对齐）+ 反面教材。
 *     等 CangDB 有与 cjc 1.1.3 兼容的版本、决定改用轻舟 RBAC 时，才按 fw_rbac_store.cj 文件头的三步回退。
 */

import std.convert.*

public func requirePermission(store: RbacStore, method: String, pathPrefix: String, code: String): Middleware {
    return { ctx: Context, next: () -> Unit =>
        let m = ctx.method()
        let p = ctx.path()
        let methodMatch = (method == "*" || m == method)
        let pathMatch = (p.size >= pathPrefix.size && p[0..pathPrefix.size] == pathPrefix)
        /* 不匹配「方法 + 路径前缀」的请求一律透传（与原版一致） */
        if (!(methodMatch && pathMatch)) {
            next()
            return
        }
        let userIdStr = ctx.getStateOr("userId", "")
        if (userIdStr.size == 0) {
            throw apiErr("AUTH_REQUIRED")
        }
        let userId = try {
            Int64.parse(userIdStr)
        } catch (e: Exception) {
            Int64(-1)
        }
        if (userId < 0) {
            throw apiErr("AUTH_REQUIRED")
        }
        if (store.hasPermission(userId, code)) {
            next()
        } else {
            throw apiErrMsg("FORBIDDEN_ROLE", "缺少权限：${code}")
        }
    }
}
