/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 *
 * ===== http_app.cj —— HTTP 应用装配 + 挂号闭环接口（P1）=====================
 *
 * 落地 P1：排班查询 / 挂号 / 取消 三个 REST，复用 P0 的 `BookingRepo`
 * （原子扣减 + 幂等 + 三态取消），因此并发安全由数据库保证，本文件不引入新锁。
 *
 * ── 中间件顺序（照基线口径，baseline/server/src/main.cj:940-953）──────────
 *   requestId → logger → bodyLimit → bodyParser → cors → timeout → router.middleware
 * 三条硬性理由：
 *   1. `bodyLimit` 必须在 `bodyParser` **之前**：框架的 bodyParser 是"先整个读进内存
 *      再比 maxBytes"，只有抢在它前面按 Content-Length 拦，大 body 才进不了内存。
 *   2. `timeout` 必须在 `router.middleware()` **之前**：router 命中后直接调 handler，
 *      我们的 handler 从不调 next()，排在 router 后面的中间件**一次都不会执行**。
 *   3. `router.middleware()` 必须**最后** use：在它之后注册的都不会跑。
 *
 * ── 三端角色（P1 简化版，如实标注）──────────────────────────────────────
 *   患者 / 医生 / 管理员三种角色，权限判定收敛到**单一函数** `can(role, action)`
 *   （基线铁律：禁止 handler 手写 if 判权限，见 baseline/server/src/perms.cj）。
 *
 *   ⚠ 与基线的差异：基线是"不透明令牌 + PBKDF2 三阶段加锁"，本阶段**尚未搬令牌体系**，
 *     用的是 `--dev-auth` 显式开启的**开发态身份头**（`X-Role` / `X-Patient-Id`）。
 *     这是**刻意的临时形态**：先把接口与权限骨架立起来并测通，
 *     令牌换取/持久化/过期回收放 P1 收尾。**生产启用会直接拒绝启动**（见 requireDevAuth）。
 */

package qingzhou

import std.collection.*
import stdx.encoding.json.*

/* ===================== 角色与权限（单一判定函数） ===================== */

/*
 * 三端角色。
 * ⚠ 仓颉的枚举**不能用 `==` 比较**（API-NOTES 坑 4：invalid binary operator '==' on Enum），
 *   所以角色比较一律走 `roleName()` 转字符串，或用 match。
 */
public enum Role {
    | Patient
    | Doctor
    | Admin
}

public func roleName(r: Role): String {
    match (r) {
        case Patient => return "patient"
        case Doctor => return "doctor"
        case Admin => return "admin"
    }
}

public func roleOf(name: String): ?Role {
    if (name == "patient") {
        return Some(Role.Patient)
    }
    if (name == "doctor") {
        return Some(Role.Doctor)
    }
    if (name == "admin") {
        return Some(Role.Admin)
    }
    return None
}

/*
 * 权限动作。
 */
public enum Action {
    | ViewSchedule        // 查排班（三端都能看）
    | Book                // 挂号（仅患者）
    | CancelOwn           // 取消自己的挂号（患者）
    | CancelAny           // 取消任意挂号（管理员）
    | ManageSchedule      // 维护排班与号源（管理员）
}

public func actionName(a: Action): String {
    match (a) {
        case ViewSchedule => return "view_schedule"
        case Book => return "book"
        case CancelOwn => return "cancel_own"
        case CancelAny => return "cancel_any"
        case ManageSchedule => return "manage_schedule"
    }
}

/*
 * ★ 权限判定的**唯一入口**（基线铁律：收敛到单一函数，禁止 handler 手写 if）。
 *
 * 权限矩阵（P1）：

 *   动作              患者   医生   管理员
 *   view_schedule      ✅     ✅     ✅
 *   book               ✅     ❌     ❌
 *   cancel_own         ✅     ❌     ❌
 *   cancel_any         ❌     ❌     ✅
 *   manage_schedule    ❌     ❌     ✅
 *
 * 医生当前**没有**写权限（接诊/写病历属 P4）。这里如实留空，
 * 不预先发权 —— 未实现的动作给权限等于埋一个未测的入口。
 */
public func can(role: Role, action: Action): Bool {
    match (action) {
        case ViewSchedule => return true
        case Book =>
            match (role) {
                case Patient => return true
                case _ => return false
            }
        case CancelOwn =>
            match (role) {
                case Patient => return true
                case _ => return false
            }
        case CancelAny =>
            match (role) {
                case Admin => return true
                case _ => return false
            }
        case ManageSchedule =>
            match (role) {
                case Admin => return true
                case _ => return false
            }
    }
}

/* 权限不满足时抛 FORBIDDEN_ROLE（403）。 */
public func requireCan(role: Role, action: Action): Unit {
    if (!can(role, action)) {
        throw apiErrorMsg("FORBIDDEN_ROLE",
                          "角色 ${roleName(role)} 无权执行 ${actionName(action)}")
    }
}

/* ===================== 身份识别（开发态，明确标注） ===================== */

/*
 * 当前请求的身份。
 *
 * ⚠ 这是 `principalOf()` 与 `can()` 之间的**唯一契约**：
 *   身份来源怎么变（开发态头 / 令牌），这个结构不变，
 *   所以权限矩阵与业务逻辑都不用动。
 */
public class Principal {
    public var userId: Int64 = 0
    public var role: Role = Role.Patient
    public var patientId: Int64 = 0
    public var doctorId: Int64 = 0
    public var loginName: String = ""
}

/*
 * 开发态身份开关。
 *
 * ⚠⚠ 这是**临时形态**，不是最终鉴权：
 *   基线用的是"不透明令牌 + PBKDF2 三阶段加锁"（baseline/server/src/auth.cj），
 *   本阶段为把接口与权限骨架先立起来、先测通，改用显式请求头。
 *
 * 三重保险，避免它悄悄上生产：
 *   1. 必须显式传 `--dev-auth` 才启用（默认关闭）；
 *   2. 启用时**每个请求**都打一行 [DEV-AUTH] 警告日志；
 *   3. 传了 `--prod` 时**直接拒绝启动**。
 *
 * ⚠ 为什么用 `--prod` 命令行开关而不是环境变量 `HOSPITAL_ENV`：
 *   本工具链的仓颉 std **没有 `getEnv`/`envVars`**
 *   （框架 config.cj:17-21 逐字核对过："neither std.env nor std.process has them"；
 *    基线 main.cj:24-25 因此也明说"不支持环境变量配置，只能走命令行"）。
 *   所以这里照基线的做法走命令行开关 —— 用环境变量会静默永远不生效，
 *   那比没有更糟（以为生产被保护了，其实没有）。
 */
public class DevAuthGate {
    public let enabled: Bool

    public init(enabled: Bool, prod: Bool) {
        if (enabled && prod) {
            throw Exception("拒绝启动：--prod 时不允许开启 --dev-auth。" +
                            "开发态身份头会绕过全部认证，生产环境必须走令牌。")
        }
        this.enabled = enabled
    }
}

/*
 * 从请求解析身份。
 *
 * ★ 优先级（P1 令牌体系上线后）：
 *   1. **`Authorization: Bearer <token>`** —— 正式路径。
 *      令牌是 32 字节随机 → 64 位 hex，服务端存 token → user 映射（不是无状态 JWT），
 *      所以"停用账号/改密码"能立即踢下线。
 *   2. 开发态身份头（`X-Role` / `X-Patient-Id`）—— **仅在 `--dev-auth` 下才看**，
 *      每请求打 `[DEV-AUTH]` 警告。用于本机快速联调。
 *   3. 两者都没有 → **401，明确失败**。
 *
 * ⚠ 顺序很重要：先看令牌。这样即使有人误开了 `--dev-auth`，
 *   带合法令牌的正式请求也不会走开发态分支（少一条"以为在用令牌其实在用头"的歧路）。
 *
 * ⚠ 非开发态下**绝不静默放行** —— 静默放行是最危险的失败方式。
 */
public func principalOf(ctx: Context, gate: DevAuthGate, auth: AuthRepo): Principal {
    let now = hNowEpoch()

    /* 1) 正式路径：Bearer 令牌 */
    match (bearerToken(ctx)) {
        case Some(tok) =>
            match (auth.principalByToken(tok, now)) {
                case Some(p) => return p
                case None =>
                    // 令牌无效/过期 —— 明确区分"过期"与"无效"，便于客户端决定是否跳登录页
                    throw apiErrorMsg("AUTH_TOKEN_EXPIRED",
                                      "令牌无效或已过期，请重新登录")
            }
        case None => ()
    }

    /* 2) 开发态身份头（仅 --dev-auth 下） */
    if (gate.enabled) {
        match (ctx.requestHeader("X-Role")) {
            case Some(roleStr) =>
                let role = match (roleOf(roleStr)) {
                    case Some(r) => r
                    case None => throw apiErrorMsg("VALIDATION_FAILED", "未知角色：${roleStr}")
                }
                let p = Principal()
                p.role = role
                println("[DEV-AUTH] ${ctx.method()} ${ctx.path()} 以 ${roleName(role)} 身份放行" +
                        "（开发态；生产必须走令牌）")
                match (ctx.requestHeader("X-Patient-Id")) {
                    case Some(v) => p.patientId = parseInt64Or(v, 0)
                    case None => ()
                }
                match (ctx.requestHeader("X-Doctor-Id")) {
                    case Some(v) => p.doctorId = parseInt64Or(v, 0)
                    case None => ()
                }
                return p
            case None => ()
        }
    }

    /* 3) 都没有 → 401 */
    throw apiErrorMsg("AUTH_REQUIRED", "缺少 Authorization: Bearer <token>")
}

/* 取出 Authorization: Bearer <token>（照基线 auth.cj:136 口径）。 */
public func bearerToken(ctx: Context): ?String {
    match (ctx.requestHeader("authorization")) {
        case Some(v) =>
            if (!startsWithAscii(v.toAsciiLower(), "bearer ")) {
                return None
            }
            let t = subFrom(v, 7).trimAscii()
            if (t.size == 0) {
                return None
            }
            return Some(t)
        case None => return None
    }
}

/*
 * ★ 取消退号是否被允许 —— 把"归属"纳入权限口径（2026-10-07 修）。
 *
 * 为什么单独抽出来：原先 handler 里是
 *     `if (can(role, CancelAny)) {放行} else { requireCan(role, CancelOwn); if (归属不符) throw }`
 * —— 权限判定**被拆成了两处**，这就违反了本项目"权限收敛到单一函数"的纪律
 * （第三方复查指出：这是"禁止 handler 手写 if"被绕过的例子）。
 * 更实际的问题是：**同一条规则会被复制到下一个需要归属判定的接口上**
 * （比如"查看自己的病历"），迟早出现两处实现不一致。
 *
 * 现在的口径是**一个函数、两段都覆盖**：角色能不能退 且 这张单归不归他。
 */
public func canCancel(role: Role, actorPatientId: Int64, appointmentPatientId: Int64,
                      actorUserId: Int64, appointmentOwnerUserId: Int64): Bool {
    // 管理员：可退任意单
    if (can(role, Action.CancelAny)) {
        return true
    }
    // 患者：只能退自己的单。**按 patient 归属判定**（业务身份），
    // 不按 user 归属 —— 一个患者理论上可以有多个登录账号，但病历/挂号只认 patient。
    if (can(role, Action.CancelOwn)) {
        return actorPatientId > 0 && actorPatientId == appointmentPatientId
    }
    return false
}

/* ===================== 入参读取 ===================== */

/* 请求体必须是 JSON 对象；否则 400（而不是让框架抛 500）。 */
public func bodyObj(ctx: Context): JsonObject {
    if (ctx.bodyJsonError().isSome()) {
        throw apiErrorMsg("VALIDATION_FAILED", "请求体不是合法 JSON")
    }
    match (ctx.bodyJson()) {
        case Some(v) =>
            match (v) {
                case o: JsonObject => return o
                case _ => throw apiErrorMsg("VALIDATION_FAILED", "请求体必须是 JSON 对象")
            }
        case None =>
            // 空体视作空对象：让"缺字段"走统一的字段校验错误
            return JsonObject()
    }
}

/* 出参：把 BookingResult 转成 JsonObject（客户端契约）。 */
func bookingJson(r: BookingResult): JsonObject {
    let o = JsonObject()
    o.put("appointment_id", JsonInt(r.appointmentId))
    o.put("schedule_id", JsonInt(r.scheduleId))
    o.put("patient_id", JsonInt(r.patientId))
    o.put("doctor_id", JsonInt(r.doctorId))
    o.put("department_id", JsonInt(r.departmentId))
    o.put("visit_date", JsonString(r.visitDate))     // ★ 就诊日快照
    o.put("period", JsonString(r.period))
    o.put("seq_no", JsonInt(r.seqNo))
    o.put("status", JsonString(r.status))
    // ★ 退号时"号源是否已归还"必须回给客户端：否则客户端无从知道
    //   上一次那个 SlotNotRestored 告警还在不在（见 domain_booking.cj cancel 注释）。
    o.put("slot_restored", JsonBool(r.slotRestored))
    return o
}

/* ===================== 路由 ===================== */

/*
 * 装配路由。
 *
 * 路径带 `/api/v1` 前缀（与基线 api-design 口径一致，便于客户端复用同一套 base-url 处理）。
 *
 * ⚠ 三端业务接口的**身份来源**是 `principalOf(ctx, gate, auth)` ——
 *   从开发态头切到令牌，这里只改了这一个调用点的实参，业务逻辑一行未动。
 */
public func buildHospitalRouter(repo: BookingRepo, auth: AuthRepo, gate: DevAuthGate): Router {
    let r = Router()

    /* ---------- 健康检查（无需认证，供压测与探活）---------- */
    r.get("/health", { ctx: Context, _: () -> Unit =>
        let o = JsonObject()
        o.put("ok", JsonBool(true))
        o.put("service", JsonString("hospital-server"))
        o.put("version", JsonString(SERVER_VERSION))
        o.put("data_backend", JsonString("mysql"))
        o.put("dev_auth", JsonBool(gate.enabled))
        ctx.status(200).json(o.toString())
    })

    /* ===================== 鉴权接口 ===================== */

    /* ---------- POST /api/v1/auth/login —— 登录换令牌 ---------- */
    r.post("/api/v1/auth/login", { ctx: Context, _: () -> Unit =>
        let body = bodyObj(ctx)
        let loginName = requireStr(ctx, "login_name")
        let password = requireStr(ctx, "password")
        let now = hNowEpoch()
        match (auth.login(loginName, password, now)) {
            case Some(x) =>
                let o = JsonObject()
                o.put("token", JsonString(x[1]))
                o.put("expires_at", JsonInt(x[2]))
                // 顺带回身份摘要，省一次 /me 往返
                match (auth.findUser(loginName)) {
                    case Some(u) =>
                        o.put("user_id", JsonInt(u.id))
                        o.put("role", JsonString(roleName(u.role)))
                        o.put("ref_id", JsonInt(u.refId))
                        o.put("display_name", JsonString(u.displayName))
                    case None => ()
                }
                sendOk(ctx, o)
            case None =>
                /*
                 * ⚠ 账号不存在与口令错误**返回同一个错误码**（AUTH_BAD_CREDENTIALS）。
                 *   分开回就是在告诉攻击者"这个手机号注册过" ——
                 *   而"谁在本院看过病"正是最该保护的信息（见 auth_crypto.cj loginCreds）。
                 */
                throw apiError("AUTH_BAD_CREDENTIALS")
        }
    })

    /* ---------- POST /api/v1/auth/logout —— 登出（吊销当前令牌）---------- */
    r.post("/api/v1/auth/logout", { ctx: Context, _: () -> Unit =>
        let tok = match (bearerToken(ctx)) {
            case Some(t) => t
            case None => throw apiError("AUTH_REQUIRED")
        }
        // 先确认令牌有效（无效令牌登出应报 401，而不是假装成功）
        let _ = principalOf(ctx, gate, auth)
        let _ = auth.revokeToken(tok)
        let o = JsonObject()
        o.put("logged_out", JsonBool(true))
        sendOk(ctx, o)
    })

    /* ---------- GET /api/v1/auth/me —— 当前身份 ---------- */
    r.get("/api/v1/auth/me", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        let o = JsonObject()
        o.put("user_id", JsonInt(p.userId))
        o.put("role", JsonString(roleName(p.role)))
        o.put("patient_id", JsonInt(p.patientId))
        o.put("doctor_id", JsonInt(p.doctorId))
        sendOk(ctx, o)
    })

    /* ---------- POST /api/v1/admin/users —— 建账号（仅管理员）---------- */
    /*
     * P1 需要能造出可登录的账号；正式的账号管理界面属 P4。
     * 与建排班同理，受**认证 + 管理员角色**双重保护。
     */
    r.post("/api/v1/admin/users", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageSchedule)
        let body = bodyObj(ctx)
        let loginName = requireStr(ctx, "login_name")
        let password = requireStr(ctx, "password")
        let roleStr = requireStr(ctx, "role")
        let role = match (roleOf(roleStr)) {
            case Some(r) => r
            case None => throw apiErrorMsg("VALIDATION_FAILED", "未知角色：${roleStr}")
        }
        // ref_id：患者/医生必填（指向业务实体），管理员为 0
        var refId: Int64 = 0
        match (bodyInt64(ctx, "ref_id")) {
            case Some(v) => refId = v
            case None => ()
        }
        // ref_id：患者/医生必填（指向业务实体），管理员为 0。
        // ⚠ 仓颉的枚举**不能用 `==`**（API-NOTES 坑 4：invalid binary operator '==' on Enum），
        //   所以角色判定一律走 match（或用 roleName() 转字符串比较）。
        match (role) {
            case Patient =>
                if (refId <= 0) {
                    throw apiErrorMsg("VALIDATION_FAILED", "患者账号必须给 ref_id（patient.id）")
                }
            case Doctor =>
                if (refId <= 0) {
                    throw apiErrorMsg("VALIDATION_FAILED", "医生账号必须给 ref_id（doctor.id）")
                }
            case Admin => ()
        }
        let displayName = match (bodyStr(ctx, "display_name")) {
            case Some(v) => v
            case None => loginName
        }
        /*
         * ★ 登录名已存在 → **409 明确报错**，不静默复用既有账号。
         *
         * 踩过的坑（本端点自己）：`AuthRepo.createUser` 是幂等的 ——
         * 已存在就返回既有 id。若这里直接回 201，就会出现
         * 「建账号成功、但传的 password 被静默忽略」这种**看起来成功其实没生效**的响应，
         * 调用方（人和脚本都会）据此以为账号建好了、口令是新的 —— 然后登录失败找不到原因。
         * 建账号与改口令是两件事，必须让调用方知道是哪一件。
         */
        if (auth.findUser(loginName).isSome()) {
            throw apiErrorMsg("USER_EXISTS",
                              "登录名已存在：${loginName}（要改口令请调 POST /api/v1/admin/users/:id/password）")
        }
        let uid = auth.createUser(loginName, role, refId, displayName, password, hNowEpoch())
        let o = JsonObject()
        o.put("user_id", JsonInt(uid))
        o.put("role", JsonString(roleName(role)))
        sendCreated(ctx, o)
    })

    /* ---------- GET /api/v1/admin/users?login_name= —— 按登录名查账号（仅管理员）---------- */
    /*
     * 用途：前台"这个手机号对应的账号 id 是多少"是常规需求；
     * 测试夹具也需要它来把已存在的账号口径拉回已知状态。
     *
     * ⚠ **只返回非敏感字段** —— 绝不回 pw_salt / pw_hash（哪怕给管理员也不回：
     *   口令材料没有任何前端用途，回它只是给泄露多开一条路）。
     */
    r.get("/api/v1/admin/users", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageSchedule)
        let loginName = ctx.queryParamOr("login_name", "")
        if (loginName.size == 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "缺少查询参数 login_name")
        }
        match (auth.findUser(loginName)) {
            case Some(u) =>
                let o = JsonObject()
                o.put("user_id", JsonInt(u.id))
                o.put("login_name", JsonString(u.loginName))
                o.put("role", JsonString(roleName(u.role)))
                o.put("ref_id", JsonInt(u.refId))
                o.put("display_name", JsonString(u.displayName))
                o.put("status", JsonString(u.status))
                sendOk(ctx, o)
            case None => throw apiErrorMsg("USER_NOT_FOUND", "账号不存在：${loginName}")
        }
    })

    /* ---------- POST /api/v1/admin/users/:id/password —— 重置口令（仅管理员）---------- */
    /*
     * 医院必须能重置忘记的口令（前台帮患者重置是常规操作）。
     *
     * ★ 安全语义：`setPassword` 会**吊销该账号的全部令牌** ——
     *   改口令必须踢下线，否则"口令泄露 → 改口令"这个补救动作是无效的
     *   （旧令牌仍然能用）。这条有测试钉住。
     */
    r.post("/api/v1/admin/users/:id/password", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageSchedule)
        let uid = parseInt64Or(ctx.paramOr("id", "0"), 0)
        if (uid <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "user_id 必须是正整数")
        }
        let body = bodyObj(ctx)
        let password = requireStr(ctx, "password")
        // 先确认账号存在（否则 UPDATE 影响 0 行、却回 200 —— 那是撒谎）
        if (!auth.userExists(uid)) {
            throw apiErrorMsg("USER_NOT_FOUND", "账号不存在：${uid}")
        }
        auth.setPassword(uid, password, hNowEpoch())
        let o = JsonObject()
        o.put("user_id", JsonInt(uid))
        o.put("tokens_revoked", JsonBool(true))
        sendOk(ctx, o)
    })

    /* ===================== 业务接口 ===================== */

    /* ---------- GET /api/v1/schedules/:id —— 查排班（三端可读）---------- */
    r.get("/api/v1/schedules/:id", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ViewSchedule)
        let sid = parseInt64Or(ctx.paramOr("id", "0"), 0)
        if (sid <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "排班 id 必须是正整数")
        }
        let found = repo.findSchedule(sid)
        if (found.isNone()) {
            throw apiError("SCHEDULE_NOT_FOUND")
        }
        let s = found.getOrThrow()
        let o = JsonObject()
        o.put("id", JsonInt(s.id))
        o.put("doctor_id", JsonInt(s.doctorId))
        o.put("department_id", JsonInt(s.departmentId))
        o.put("work_date", JsonString(s.workDate))
        o.put("period", JsonString(s.period))
        o.put("total_num", JsonInt(s.totalNum))
        o.put("remain_num", JsonInt(s.remainNum))
        o.put("version", JsonInt(s.version))
        o.put("enabled", JsonBool(s.enabled))
        sendOk(ctx, o)
    })

    /* ---------- POST /api/v1/appointments —— 挂号（仅患者）---------- */
    r.post("/api/v1/appointments", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.Book)
        let body = bodyObj(ctx)
        let scheduleId = requireInt(ctx, "schedule_id")
        let clientToken = requireStr(ctx, "client_token")
        // 患者只能给自己挂号：不接受 body 里的 patient_id，
        // 一律用**身份里的** patientId。这样"帮别人挂号"这个面根本不存在。
        if (p.patientId <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "缺少 X-Patient-Id（开发态联调头）")
        }
        let now = hNowEpoch()
        // HTTP 层用更大的重试预算抗瞬时并发（见 domain_booking.cj 的
        // HTTP_BOOKING_RETRY 注释：默认 3 在 20 并发抢 8 号时会少卖）。
        let result = repo.book(p.patientId, scheduleId, clientToken, now,
                               maxRetry: HTTP_BOOKING_RETRY)
        // 幂等命中按 200 返回（不是 201）：没有新建资源
        match (result.outcome) {
            case Booked(_) => sendCreated(ctx, bookingJson(result))
            case AlreadyBooked(_) => sendOk(ctx, bookingJson(result))
            case SlotGone => throw apiError("SLOT_GONE")
            case ScheduleNotFound => throw apiError("SCHEDULE_NOT_FOUND")
        }
    })

    /* ---------- POST /api/v1/appointments/:id/cancel —— 退号 ---------- */
    r.post("/api/v1/appointments/:id/cancel", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        let id = parseInt64Or(ctx.paramOr("id", "0"), 0)
        if (id <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "挂号单 id 必须是正整数")
        }
        let found = repo.findAppointment(id)
        if (found.isNone()) {
            throw apiError("APPOINTMENT_NOT_FOUND")
        }
        let appt = found.getOrThrow()
        /*
         * 谁能退这张单：**单一判定函数**（见 canCancel）——
         * 管理员退任意；患者只退自己的。角色权限与归属判定都收敛在那里，
         * handler 不再手写 if（本项目纪律，也是第三方复查要求修的点）。
         */
        if (!canCancel(p.role, p.patientId, appt.patientId, p.userId, 0)) {
            // ⚠ 是否泄露"这张单存在"？这里有取舍：明确 403 便于患者自查"退错单了"；
            //   若要严格防枚举应改回 404。当前选 403，并在此显式记录这个取舍。
            throw apiErrorMsg("FORBIDDEN_ROLE",
                              "无权取消该挂号单（管理员可退任意单；患者只能退自己的）")
        }
        match (repo.cancel(id, hNowEpoch())) {
            case Cancelled =>
                /*
                 * ⚠ 必须**取消后重读**，不能用上面那个 appt 快照。
                 *   踩过的坑：appt 是取消**之前**读的，status 还是 "booked"，
                 *   直接回它会让客户端看到"退号成功但状态仍是已挂号"——
                 *   自相矛盾的响应比不返回还糟。
                 */
                match (repo.findAppointment(id)) {
                    case Some(after) => sendOk(ctx, bookingJson(after))
                    case None => throw apiError("APPOINTMENT_NOT_FOUND")
                }
            case SlotNotRestored =>
                // ★ 单已取消但号源未归还：HTTP 上算成功（单确实退了），
                //   但带一个显式标记让客户端提示"需人工处理"，绝不谎报失败。
                match (repo.findAppointment(id)) {
                    case Some(after) =>
                        let o = bookingJson(after)
                        o.put("status", JsonString("cancelled"))
                        o.put("slot_restored", JsonBool(false))
                        o.put("warning", JsonString("号源归还异常，请联系人工处理"))
                        sendOk(ctx, o)
                    case None => throw apiError("APPOINTMENT_NOT_FOUND")
                }
            case NotFound => throw apiError("APPOINTMENT_NOT_FOUND")
        }
    })

    /* ---------- POST /api/v1/admin/schedules —— 建排班（仅管理员）---------- */
    /*
     * P1 需要有办法造出真实号源才能测"扣号/退号/并发"。
     * 正式的排班维护界面属 P4（运营看板），这里先给一个**受 --dev-auth + 管理员角色
     * 双重保护**的最小写入接口；不开 --dev-auth 时它和业务接口一样直接 401。
     */
    r.post("/api/v1/admin/schedules", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageSchedule)
        let body = bodyObj(ctx)
        let doctorId = requireInt(ctx, "doctor_id")
        let departmentId = requireInt(ctx, "department_id")
        let workDate = requireStr(ctx, "work_date")
        let period = requireStr(ctx, "period")
        let total = requireInt(ctx, "total_num")
        if (total < 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "total_num 不能为负")
        }
        let now = hNowEpoch()
        repo.insertSchedule(doctorId, departmentId, workDate, period, total, now)
        let sid = repo.lastInsertId()
        let o = JsonObject()
        o.put("schedule_id", JsonInt(sid))
        o.put("total_num", JsonInt(total))
        o.put("remain_num", JsonInt(total))
        sendCreated(ctx, o)
    })

    return r
}

/* ===================== 应用装配 ===================== */

public func buildHospitalApp(repo: BookingRepo, auth: AuthRepo, gate: DevAuthGate): QingZhouApp {
    let router = buildHospitalRouter(repo, auth, gate)
    return QingZhouApp()
        .use(requestId())
        .use(logger())
        // bodyLimit 必须排在 bodyParser **之前**（外层）：框架的 bodyParser 是
        // "先把整个 body 读进内存、再比 maxBytes"，只有抢在它前面按 Content-Length
        // 拦，大 body 才进不了内存。
        // ⚠ 基线的 `bodyLimit()` 是**基线自己写的**（baseline/server/src/limits.cj:83），
        //   不在框架里；这里用框架原生的 `contentLengthLimit(maxBytes)`（bodyparser.cj:168）。
        //   上限 64 KiB —— 与基线 MAX_BODY_BYTES 同口径（limits.cj:47）。
        .use(contentLengthLimit(64 * 1024))
        /*
         * ⚠ bodyParser() 的真实上限是**框架默认的 1 MiB**（bodyparser.cj:36
         *   `maxBytes = 1024 * 1024`），**不是**上面那个 64 KiB。
         *   两者关系是：
         *     · `contentLengthLimit(64 KiB)` —— 外层闸门，按 **Content-Length** 拦，
         *       所以声明了长度的大 body 在进内存**之前**就被挡掉（在 bodyParser 之前 use）；
         *     · `bodyParser()` 的 1 MiB —— 内层兜底，用于**没有 Content-Length** 的
         *       请求（chunked 编码时外层闸门看不出来，只能靠它）。
         *   实测：发 100 KiB 的 body → 413（外层闸门生效）。
         *   （复查指出"文档说 64 KiB、注释说 1 MiB"的口径不一致，根因就是把
         *     两个不同层的限额混着说了。这里把关系写清楚，数字不再打架。）
         */
        .use(bodyParser())
        .use(cors())
        /*
         * ⚠ `timeout(15000)` **不能中断**已经进入的同步 handler —— 这是实测确认的
         *   框架语义，不是配置问题：timeout.cj:64-83 的实现是
         *       `next()`（**同步跑完整个下游**）→ 再比较 elapsed → 超时才补一个 408。
         *   所以它只能"事后补告警"（handler 没写响应时给 408；
         *   已经写了响应就只加一个 `x-timeout-ms` 响应头），
         *   **不会**把慢 handler 掐掉、也不会释放它占的线程。
         *
         *   对本项目意味着什么：挂号/退号路径里**不能有慢操作**
         *   （这也是"事务内禁止出站网络调用"那条纪律的另一面 —— 见 ADR-0001 §6）。
         *   真正的超时保护要靠：① 单条 SQL 的 `innodb_lock_wait_timeout`；
         *   ② 未来若引入 AI/HTTP 出站，必须在**事务外**做并自带超时。
         */
        .use(timeout(15000))
        .use(router.middleware())
        .onError({ ctx: Context, _: () -> Unit => hospitalErrorHandler(ctx) })
}

/*
 * 持有 ServerHandle。
 * 必须放在 class 的字段里而不是闭包捕获的 var —— 仓颉闭包不能捕获可变变量
 * （本项目已踩过两次，见 domain_booking.cj 的 TxResult）。
 */
public class HandleBox {
    public var handle: ?ServerHandle = None

    public init() {}
}
