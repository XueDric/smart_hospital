package qingzhou

import std.collection.*
import std.convert.*
import std.time.*

/*
 * SPDX-License-Identifier: MIT
 *
 * Example 8: admin — 前后端分离后台管理系统（CangDB 持久化 + RBAC + 生产化）。
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * 路由与权限：
 *   POST   /api/login        登录（公开）
 *   POST   /api/password     修改本人密码（登录即可，B-2）
 *   GET    /api/me           当前用户（登录即可）
 *   GET    /api/dashboard    仪表盘（登录即可）
 *   GET    /api/users        用户列表（user:list）
 *   POST   /api/users        创建用户（user:create）
 *   DELETE /api/users/:id    删除用户（user:delete）
 *   GET    /api/roles        角色列表（role:list）
 *   GET    /api/perms        权限列表（perm:list）
 *   GET    /health           健康检查（公开，供部署脚本探测）
 *   POST   /admin/shutdown   优雅关闭（需 admin 角色 + token）
 *   其它                     静态托管 + SPA fallback
 *
 * 内置账号（种子数据，密码哈希存储）：
 *   admin / admin123   角色 admin（拥有全部权限）
 *   user  / user123    角色 user（仅 dashboard:view）
 *
 * 配置（admin.env，缺省见下方 loadConfig 注释）：
 *   port    监听端口（默认 3000）
 *   db      数据库 DSN（默认 cangdb:admin.cjdb；切换 MySQL 等，见 docs/DATABASE.md）
 *   secret  JWT 签名密钥（未配置则每次启动随机，重启后 token 全部失效）
 *   ttl     token 有效期秒（默认 7200）
 *
 * 运行：.\build\admin.exe  ->  http://127.0.0.1:3000/
 * 部署：./deploy-admin.sh {start|stop|status|restart}
 */

/* 优雅关闭触发器：闭包捕获 this，POST /admin/shutdown 置 true。 */
class ShutdownFlag {
    public var requested: Bool = false
    init() {}
}

main(): Int64 {
    /* ---------- 配置外置（复用 config.cj 的 .env 加载） ---------- */
    let cfg = loadConfigFile("./admin.env")
    let port = parseUInt16Or(cfg.getOr("port", "3000"), 3000)
    // 数据库 DSN：cangdb:admin.cjdb（嵌入式）或 mysql://user:pass@host:3306/db
    let dbDsn = cfg.getOr("db", "cangdb:admin.cjdb")
    let ttl = cfg.getIntOr("ttl", 7200)
    let secret = match (cfg.get("secret")) {
        case Some(s) => s
        case None =>
            let r = randomHex(32)
            println("[admin] 警告：admin.env 未配置 secret，使用随机值（重启后所有 token 失效）")
            r
    }

    /* 打开 RBAC 存储（工厂按 DSN 选择后端，首次启动自动建表 + 灌种子数据） */
    let store = openStore(dbDsn)
    let shutdownFlag = ShutdownFlag()

    /* ---------- 公开路由：登录，签发标准 JWT（带 exp） ---------- */
    let publicRouter = Router()
    publicRouter.passOnNotFound = true
    publicRouter.post("/api/login", { ctx: Context, _: () -> Unit =>
        let username = bodyStrOr(ctx, "username", "")
        let password = bodyStrOr(ctx, "password", "")
        match (store.findUserByUsername(username)) {
            case Some(u) =>
                if (verifyPassword(password, u.passwordHash)) {
                    let token = issueTokenTtl(u.id.toString(), secret, ttl)
                    respondOk(ctx, "{\"token\":\"${token}\"}")
                } else {
                    respondErr(ctx, 401, "invalid credentials")
                }
            case None =>
                respondErr(ctx, 401, "invalid credentials")
        }
    })

    /* ---------- 登录即可访问 ---------- */
    let authRouter = Router()
    authRouter.passOnNotFound = true
    authRouter.get("/api/me", { ctx: Context, _: () -> Unit =>
        let userId = Int64.parse(ctx.getStateOr("userId", "0"))
        match (store.findUserById(userId)) {
            case Some(u) =>
                let roleName = store.roleNameOf(u.roleId)
                respondOk(ctx, "{\"id\":${u.id},\"username\":\"${u.username}\",\"role\":\"${roleName}\"}")
            case None =>
                respondErr(ctx, 401, "unauthorized")
        }
    })
    authRouter.get("/api/dashboard", { ctx: Context, _: () -> Unit =>
        respondOk(ctx, "{\"stats\":{\"users\":${store.listUsers().size},\"roles\":${store.listRoles().size}}}")
    })
    /* v0.7.1（外部反馈 B-2）：修改本人密码 —— 登录即可，无需管理权限。
     * 种子口令不再只能永久裸奔；新盐随机生成，落库经 sqlQuote 转义。 */
    authRouter.post("/api/password", { ctx: Context, _: () -> Unit =>
        let newPassword = bodyStrOr(ctx, "newPassword", "")
        if (newPassword.size < 6) {
            respondErr(ctx, 400, "newPassword must be at least 6 chars")
            return
        }
        let userId = Int64.parse(ctx.getStateOr("userId", "0"))
        if (store.changePassword(userId, newPassword)) {
            respondOkNull(ctx)
        } else {
            respondErr(ctx, 404, "user not found")
        }
    })

    /* ---------- 管理路由：用户 / 角色 / 权限（requirePermission 保护） ---------- */
    let mgmtRouter = Router()
    mgmtRouter.passOnNotFound = true
    mgmtRouter.get("/api/users", { ctx: Context, _: () -> Unit =>
        let users = store.listUsers()
        let parts = ArrayList<String>()
        for (u in users) {
            parts.add("{\"id\":${u.id},\"username\":\"${u.username}\",\"role\":\"${store.roleNameOf(u.roleId)}\"}")
        }
        respondOk(ctx, "[${String.join(parts.toArray(), delimiter: ",")}]")
    })
    mgmtRouter.post("/api/users", { ctx: Context, _: () -> Unit =>
        let username = bodyStrOr(ctx, "username", "")
        let password = bodyStrOr(ctx, "password", "")
        let roleId = match (bodyInt64(ctx, "roleId")) {
            case Some(r) => r
            case None => Int64(2)
        }
        if (username.size == 0 || password.size == 0) {
            respondErr(ctx, 400, "username and password required")
            return
        }
        let hash = hashPassword(password, "qz2026", 1000)
        // B-3：createUser 在事务内查重，重名抛异常，转 409 而非静默重复
        var id: Int64 = 0
        try {
            id = store.createUser(username, hash, roleId)
        } catch (e: IllegalArgumentException) {
            respondErr(ctx, 409, "username already exists")
            return
        }
        respondOk(ctx, "{\"id\":${id},\"username\":\"${username}\"}")
    })
    mgmtRouter.delete("/api/users/:id", { ctx: Context, _: () -> Unit =>
        let id = Int64.parse(ctx.paramOr("id", "0"))
        if (store.deleteUser(id)) {
            respondOkNull(ctx)
        } else {
            respondErr(ctx, 404, "user not found")
        }
    })
    mgmtRouter.get("/api/roles", { ctx: Context, _: () -> Unit =>
        let roles = store.listRoles()
        let parts = ArrayList<String>()
        for (r in roles) {
            parts.add("{\"id\":${r.id},\"name\":\"${r.name}\"}")
        }
        respondOk(ctx, "[${String.join(parts.toArray(), delimiter: ",")}]")
    })
    mgmtRouter.get("/api/perms", { ctx: Context, _: () -> Unit =>
        let perms = store.listPermissions()
        let parts = ArrayList<String>()
        for (pm in perms) {
            parts.add("{\"id\":${pm.id},\"code\":\"${pm.code}\",\"name\":\"${pm.name}\"}")
        }
        respondOk(ctx, "[${String.join(parts.toArray(), delimiter: ",")}]")
    })

    /* ---------- 运维路由：健康检查 + 优雅关闭（admin 角色保护） ---------- */
    let opsRouter = Router()
    opsRouter.passOnNotFound = true
    opsRouter.get("/health", { ctx: Context, _: () -> Unit =>
        ctx.status(200).header("content-type", "application/json")
            .body("{\"status\":\"ok\"}")
    })
    opsRouter.post("/admin/shutdown", { ctx: Context, _: () -> Unit =>
        // 此时 authRequired 已校验 token 并把 userId 写入 state；这里再校验角色。
        let userId = try {
            Int64.parse(ctx.getStateOr("userId", "0"))
        } catch (e: Exception) {
            Int64(0)
        }
        match (store.findUserById(userId)) {
            case Some(u) =>
                if (u.roleId == 1) {
                    shutdownFlag.requested = true
                    respondOkNull(ctx)
                } else {
                    respondErr(ctx, 403, "forbidden: admin only")
                }
            case None =>
                respondErr(ctx, 401, "unauthorized")
        }
    })

    /* ---------- 静态托管 + SPA fallback ---------- */
    let staticOpts = StaticOptions()
    staticOpts.spaFallback = true
    staticOpts.enableCache = false   // demo 关缓存，改前端即时生效

    let app = QingZhouApp()
        .use(securityHeaders())
        .use(rateLimit(100, 60))
        .use(cors())
        .use(bodyParser())
        .use(publicRouter.middleware())
        .use(authRequired(secret))
        .use(authRouter.middleware())
        .use(requirePermission(store, "GET", "/api/users", "user:list"))
        .use(requirePermission(store, "POST", "/api/users", "user:create"))
        .use(requirePermission(store, "DELETE", "/api/users", "user:delete"))
        .use(requirePermission(store, "GET", "/api/roles", "role:list"))
        .use(requirePermission(store, "GET", "/api/perms", "perm:list"))
        .use(mgmtRouter.middleware())
        .use(opsRouter.middleware())
        .use(serveWithOpts("./admin-web/dist", staticOpts))
        .onError(jsonErrorHandler())

    println("QingZhou RBAC admin · listening on :${port}")
    println("  GET  /health          健康检查")
    println("  POST /admin/shutdown  优雅关闭（需 admin 角色）")
    println("  账号 admin/admin123（管理员） user/user123（普通用户）")

    /* ---------- 优雅关闭：主线程轮询关闭标志 ---------- */
    let handle = app.serve(port)
    while (!shutdownFlag.requested) {
        sleep(Duration.second * 1)
    }
    println("shutdown requested, draining in-flight requests...")
    handle.shutdown()
    println("graceful shutdown complete")
    store.close()
    return 0
}
