/*
 * SPDX-License-Identifier: MIT
 *
 * auth_repo.cj —— 鉴权仓储（MySQL 令牌体系）
 * 只负责"令牌 → 身份"，权限判定在 http_app.cj 的 can()；业务逻辑不感知身份来源。
 */

package qingzhou

/*
 * 依赖：stdx.crypto.digest（HMAC/SHA256 间接用）、stdx.encoding.hex（toHexString）。
 * 禁止 import `std.convert.*`：它会遮蔽 trimAscii / toAsciiLower（真正提供方是 std.collection.*）。
 */
import std.collection.*
import stdx.crypto.digest.*
import stdx.encoding.hex.*

/* ===================== 账号 ===================== */

/* 鉴权账号（读模型）。 */
public class AuthUser {
    public var id: Int64 = 0
    public var loginName: String = ""
    public var role: Role = Role.Patient
    public var refId: Int64 = 0
    public var displayName: String = ""
    public var pwSalt: String = ""
    public var pwHash: String = ""
    public var pwIter: Int64 = 0
    public var status: String = "active"
}

/* 登录限流 / 锁定 */

/* 登录失败限流：5 次失败 / 15 分钟窗口 / 锁 15 分钟。
 * 不能取消：无限次在线爆破既是口令风险，也把 PBKDF2 当 CPU 放大器。
 * 代价如实记录：账号级锁定可被用于对特定账号做 15 分钟量级拒绝服务，换来的是有限窗口可自愈。 */
public let LOGIN_FAIL_LIMIT: Int64 = 5
public let LOGIN_FAIL_WINDOW: Int64 = 900
public let LOGIN_LOCK_SECONDS: Int64 = 900

/* 登录名归一（trimAscii + toAsciiLower），与 DB 的 utf8mb4_general_ci / PAD SPACE 同口径。
 * 必须去首尾空白并统一小写，否则大小写与尾空格变体各消耗一份失败预算，限流形同虚设。
 * 用 ASCII 小写而非 locale 感知 toLower：归一口径必须跨机器一致，否则换机即绕过。 */
public func normalizeLoginName(raw: String): String {
    return raw.trimAscii().toAsciiLower()
}

/* 归属哈希用的固定密钥：公开常量，不是机密；禁止轮换（会让历史计数行全部失配 = 清空限流）。 */
private let LOGIN_HASH_KEY: String = "smart-hospital/login-attempt/v1"

/* 登录名哈希（十六进制）；入参必须是已归一化的值。
 * 用 HMAC-SHA256 + 固定密钥当带密钥摘要（crypto 层只暴露 hmacSha256），只为定长映射，不抗爆破。 */
public func loginNameHash(loginName: String): String {
    return toHexString(hmacSha256(LOGIN_HASH_KEY.toArray(), normalizeLoginName(loginName).toArray()))
}

/* 登录锁定状态。 */
public class LockState {
    public var locked: Bool = false
    public var failCount: Int64 = 0
    public var retryAfterSeconds: Int64 = 0
}

/* 登录结果：成功 / 凭据不对（账号不存在、口令错、停用刻意不区分，防枚举）/ 被锁定。
 * 锁定必须独立表达，否则客户端拿不到 retryAfterSeconds。 */
public class LoginOutcome {
    public var userId: Int64 = 0
    public var token: String = ""
    public var expiresAt: Int64 = 0
    public var locked: Bool = false
    public var retryAfterSeconds: Int64 = 0

    /* 成功 = 拿到令牌。 */
    public func succeeded(): Bool {
        return token.size > 0
    }
}

/* 口令强度 */

/* 口令最短 8 位：与 PBKDF2 10 万次迭代 + 失败限流是组合，不是单点约束。 */
public let PW_MIN_LEN: Int64 = 8

/* 常见弱口令（小写比对）：示例级清单，只拦随手可敲的，不能替代外部字典；必须含"常见词+数字"。 */
private let WEAK_PASSWORDS: Array<String> = [
    // 纯常见词
    "password", "passw0rd", "qwertyui", "iloveyou", "administrator",
    "letmein1", "welcome1", "changeme", "hospital", "monkey12",
    // 常见词 + 数字：强制字母+数字后最可能的形态
    "password1", "password12", "password123", "password1234", "password2024",
    "password2025", "password2026", "qwerty123", "qwerty1234", "qwerty12345",
    "abc12345", "abcd1234", "iloveyou1", "welcome123",
    // admin123 等短词+短数字必须保留：重写清单最容易漏掉"原本有的项"。
    "admin123", "admin12345", "root1234", "test123", "test123456",
    "hospital2026", "qwerty12", "abcdef12", "aa123456", "abc123456",
    "administrator1", "hospital1", "hospital123", "test1234", "test12345",
    "letmein123", "changeme1", "changeme123", "monkey123",
    // 纯数字 / 顺序键
    "12345678", "123456789", "1234567890", "11111111", "00000000",
    "12341234", "87654321", "11223344", "123123123"
]

/* 口令校验结果。 */
public class PwCheck {
    public var ok: Bool = true
    /* 面向用户的理由（ok = false 时非空）。 */
    public var reason: String = ""
}

/* 会话（令牌按设备管理） */

/* 一条活跃会话（读模型）；刻意不含 token —— 少复制一份凭据。
 * deviceId / deviceName 是客户端自报，不可信，绝不参与授权判定。 */
public class SessionInfo {
    public var deviceId: String = ""
    public var deviceName: String = ""
    public var createdAt: Int64 = 0
    public var lastSeenAt: Int64 = 0
    public var expiresAt: Int64 = 0
}

/* 口令强度校验，在仓储层强制：createUser / setPassword / create-admin 共用同一必经点，HTTP 层无法绕过。
 * 规则：≥8 位、含字母与数字、不在弱口令表、不等于登录名及"登录名+前后缀"。
 * 刻意不要求特殊字符（会推向 Password1! 这类可预测写法）。 */
public func checkPasswordStrength(password: String, loginName: String): PwCheck {
    let r = PwCheck()

    if (password.size < PW_MIN_LEN) {
        r.ok = false
        r.reason = "口令至少 ${PW_MIN_LEN} 位（当前 ${password.size} 位）"
        return r
    }

    // ② 字母 + 数字
    var hasLetter = false
    var hasDigit = false
    for (ch in password.toArray()) {
        let c = Int64(ch)
        if ((c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)) {
            hasLetter = true
        }
        if (c >= 0x30 && c <= 0x39) {
            hasDigit = true
        }
    }
    if (!hasLetter || !hasDigit) {
        r.ok = false
        r.reason = "口令必须同时包含字母与数字"
        return r
    }

    // ③ 弱口令表（小写比对）
    let low = password.toAsciiLower()
    for (w in WEAK_PASSWORDS) {
        if (low == w) {
            r.ok = false
            r.reason = "口令太常见，请换一个"
            return r
        }
    }

    // ④ 不得等于登录名或"登录名 + 数字"
    let nlogin = normalizeLoginName(loginName)
    if (nlogin.size > 0) {
        if (low == nlogin) {
            r.ok = false
            r.reason = "口令不能与登录名相同"
            return r
        }
        if (low.startsWith(nlogin) || low.endsWith(nlogin)) {
            r.ok = false
            r.reason = "口令不能是登录名加前后缀（如 ${loginName}123）"
            return r
        }
    }
    return r
}

public class AuthRepo {
    private let db: DbBackend

    public init(db: DbBackend) {
        this.db = db
    }

    /* 登录限流：读 / 记 / 清 */

    /* 查登录名当前锁定状态（只读）。判据：fail_count >= LOGIN_FAIL_LIMIT 且
     * now - last_fail_at < LOGIN_LOCK_SECONDS；第二条让锁定自动过期，不会永久锁死真实用户。
     * 观察窗口不参与读取判定，只在 recordFailure 写入时决定累计还是重新起一轮。 */
    public func lockState(loginName: String, now: Int64): LockState {
        let st = LockState()
        let rs = db.query(
            "SELECT fail_count, last_fail_at FROM auth_login_attempt WHERE login_hash = ?",
            [DbStr(loginNameHash(loginName))])
        if (rs.rowCount() < 1) {
            return st                      // 没有记录 = 从未失败过
        }
        let cnt = rs.getInt(0, 0)
        let lastFail = rs.getInt(0, 1)
        st.failCount = cnt
        if (cnt >= LOGIN_FAIL_LIMIT && now - lastFail < LOGIN_LOCK_SECONDS) {
            st.locked = true
            // 还要多久解锁（至少 1 秒，避免返回 0 让客户端立刻重试）
            let left = LOGIN_LOCK_SECONDS - (now - lastFail)
            st.retryAfterSeconds = if (left < 1) { 1 } else { left }
        }
        return st
    }

    /* 记一次登录失败，返回记完后的锁定状态。
     * 累计规则只有一条：距上次失败超过观察窗口就从 1 重新计数，否则递增 —— 手误不攒成锁定，爆破必被挡。
     * 用 INSERT ... ON DUPLICATE KEY UPDATE 一条语句，避免并发下"先查再写"的计数偏少窗口。 */
    public func recordFailure(loginName: String, now: Int64): LockState {
        let h = loginNameHash(loginName)
        /* window_start 与 fail_count 必须用同一条件判断新窗口，否则窗口与计数错位。 */
        db.exec(
            "INSERT INTO auth_login_attempt (login_hash, fail_count, window_start, last_fail_at) " +
            "VALUES (?, 1, ?, ?) " +
            "ON DUPLICATE KEY UPDATE " +
            "  fail_count = IF(window_start = 0 OR ? - window_start > ?, 1, fail_count + 1), " +
            "  window_start = IF(window_start = 0 OR ? - window_start > ?, ?, window_start), " +
            "  last_fail_at = ?",
            [DbStr(h), DbInt(now), DbInt(now),
             DbInt(now), DbInt(LOGIN_FAIL_WINDOW),
             DbInt(now), DbInt(LOGIN_FAIL_WINDOW), DbInt(now),
             DbInt(now)])
        return lockState(loginName, now)
    }

    /* 登录成功后必须清掉失败计数：否则历史失败会累加，正常用户再错一次就被锁。 */
    public func clearFailures(loginName: String): Int64 {
        return db.exec("DELETE FROM auth_login_attempt WHERE login_hash = ?",
                       [DbStr(loginNameHash(loginName))])
    }

    /* 清理长期未失败的计数行，返回删除行数；保留期取 10 倍观察窗口。
     * 否则随机登录名会把表刷爆（只增不减）。 */
    public func pruneAttempts(now: Int64): Int64 {
        return db.exec("DELETE FROM auth_login_attempt WHERE last_fail_at < ?",
                       [DbInt(now - LOGIN_FAIL_WINDOW * 10)])
    }

    /* 账号 */

    /* 按 id 查账号（setPassword 需要拿登录名做"口令不等于登录名"校验）。 */
    public func findUserById(userId: Int64): ?AuthUser {
        let rs = db.query(
            "SELECT id, login_name, role, ref_id, display_name, pw_salt, pw_hash, " +
            "pw_iter, status FROM auth_user WHERE id = ?", [DbInt(userId)])
        if (rs.rowCount() < 1) {
            return None
        }
        let u = AuthUser()
        u.id = rs.getInt(0, 0)
        u.loginName = rs.getString(0, 1)
        u.role = match (roleOf(rs.getString(0, 2))) {
            case Some(r) => r
            case None => return None
        }
        u.refId = rs.getInt(0, 3)
        u.displayName = rs.getString(0, 4)
        u.pwSalt = rs.getString(0, 5)
        u.pwHash = rs.getString(0, 6)
        u.pwIter = rs.getInt(0, 7)
        u.status = rs.getString(0, 8)
        return Some(u)
    }

    /* 按登录名查账号；不存在返回 None。 */
    public func findUser(loginName: String): ?AuthUser {
        /* 查询前必须归一：让限流计数与账号查找共用同一个口径，否则换个大小写就是新预算。 */
        let rs = db.query(
            "SELECT id, login_name, role, ref_id, display_name, pw_salt, pw_hash, " +
            "pw_iter, status FROM auth_user WHERE login_name = ?",
            [DbStr(normalizeLoginName(loginName))])
        if (rs.rowCount() < 1) {
            return None
        }
        let u = AuthUser()
        u.id = rs.getInt(0, 0)
        u.loginName = rs.getString(0, 1)
        u.role = match (roleOf(rs.getString(0, 2))) {
            case Some(r) => r
            case None => return None
        }
        u.refId = rs.getInt(0, 3)
        u.displayName = rs.getString(0, 4)
        u.pwSalt = rs.getString(0, 5)
        u.pwHash = rs.getString(0, 6)
        u.pwIter = rs.getInt(0, 7)
        u.status = rs.getString(0, 8)
        return Some(u)
    }

    /* 建账号（幂等：登录名已存在则返回既有 id）；口令走 newPasswordRecord()（16 字节盐 + 10 万次 PBKDF2）。 */
    public func createUser(loginName: String, role: Role, refId: Int64,
                           displayName: String, password: String, now: Int64): Int64 {
        /* 写入前必须归一：库里存的就是归一值，唯一索引 uk_auth_user_login 才拦得住大小写变体重复注册。 */
        let existing = findUser(loginName)
        if (existing.isSome()) {
            return existing.getOrThrow().id
        }
        // 业务账号必须绑定真实实体；停用医生仍存在，不在鉴权层否定其历史访问。
        if (!authReferenceExists(role, refId)) {
            throw UserFacingError("账号绑定的业务档案不存在：${refId}")
        }
        /* 建号也强制口令强度：create-admin CLI 走同一道校验，不能绕。 */
        let pwOk = checkPasswordStrength(password, loginName)
        if (!pwOk.ok) {
            // 用 UserFacingError：映射为 400 VALIDATION_FAILED，不是 500
            throw UserFacingError("口令强度不足：${pwOk.reason}")
        }
        let rec = newPasswordRecord(password)
        return db.execInsert(
            "INSERT INTO auth_user " +
            "(login_name, role, ref_id, display_name, pw_salt, pw_hash, pw_iter, " +
            " status, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, 'active', ?)",
            [DbStr(normalizeLoginName(loginName)), DbStr(roleName(role)), DbInt(refId), DbStr(displayName),
             DbStr(rec[0]), DbStr(rec[1]), DbInt(rec[2]), DbInt(now)])
    }

    /* 只校验业务实体存在性，启停状态由业务权限与排班入口处理。 */
    private func authReferenceExists(role: Role, refId: Int64): Bool {
        match (role) {
            case Patient =>
                if (refId <= 0) {
                    return false
                }
                let rs = db.query("SELECT id FROM patient WHERE id = ?", [DbInt(refId)])
                return rs.rowCount() > 0
            case Doctor =>
                if (refId <= 0) {
                    return false
                }
                let rs = db.query("SELECT id FROM doctor WHERE id = ?", [DbInt(refId)])
                return rs.rowCount() > 0
            case Admin => return true
        }
    }

    /* 账号是否存在（按 id）；用于重置口令前确认，避免 UPDATE 影响 0 行却回 200。 */
    public func userExists(userId: Int64): Bool {
        let rs = db.query("SELECT COUNT(*) FROM auth_user WHERE id = ?", [DbInt(userId)])
        if (rs.rowCount() < 1) {
            return false
        }
        return rs.getInt(0, 0) > 0
    }

    /* 分页列账号（GET /admin/users，支持按角色 / 状态筛选）。
     * 筛选值一律参数化，绝不拼 SQL；非法角色 / 状态当没筛（列表是浏览语义），roleOf() 是白名单。
     * 返回不带 pw_salt / pw_hash：列表最容易被整页导出。 */
    public func listUsers(limit: Int64, offset: Int64, roleFilter: String,
                          statusFilter: String): Array<AuthUser> {
        let wantRole = match (roleOf(roleFilter)) {
            case Some(r) => roleName(r)
            case None => ""
        }
        let wantStatus = if (statusFilter == "active" || statusFilter == "disabled") {
            statusFilter
        } else {
            ""
        }
        let rs = db.query(
            "SELECT id, login_name, role, ref_id, display_name, pw_salt, pw_hash, pw_iter, status " +
            "FROM auth_user WHERE role <> '' AND (? = '' OR role = ?) AND (? = '' OR status = ?) " +
            "ORDER BY id ASC LIMIT ? OFFSET ?",
            [DbStr(wantRole), DbStr(wantRole), DbStr(wantStatus), DbStr(wantStatus),
             DbInt(limit), DbInt(offset)])
        let out = ArrayList<AuthUser>()
        var i: Int64 = 0
        while (i < rs.rowCount()) {
            let u = AuthUser()
            u.id = rs.getInt(i, 0)
            u.loginName = rs.getString(i, 1)
            u.role = match (roleOf(rs.getString(i, 2))) {
                case Some(r) => r
                case None => Role.Patient
            }
            u.refId = rs.getInt(i, 3)
            u.displayName = rs.getString(i, 4)
            /* 口令材料故意不读出行：读进来就有被顺手回显的风险。 */
            u.pwIter = rs.getInt(i, 7)
            u.status = rs.getString(i, 8)
            out.add(u)
            i = i + 1
        }
        return out.toArray()
    }

    /* 同上口径的总数（分页要能显示"共 N 条"）。 */
    public func countUsers(roleFilter: String, statusFilter: String): Int64 {
        let wantRole = match (roleOf(roleFilter)) {
            case Some(r) => roleName(r)
            case None => ""
        }
        let wantStatus = if (statusFilter == "active" || statusFilter == "disabled") {
            statusFilter
        } else {
            ""
        }
        let rs = db.query(
            "SELECT COUNT(*) FROM auth_user WHERE role <> '' AND (? = '' OR role = ?) AND (? = '' OR status = ?)",
            [DbStr(wantRole), DbStr(wantRole), DbStr(wantStatus), DbStr(wantStatus)])
        if (rs.rowCount() == 0) {
            return 0
        }
        return rs.getInt(0, 0)
    }

    /* 改口令，并吊销该账号全部令牌（改密必须踢下线）。
     * 顺序必须是先校验强度、再落库 + 吊销：否则一次弱口令请求就能把目标用户踢下线。
     * userId 不存在时抛异常（HTTP 映射 404 USER_NOT_FOUND），不能把"未生效"当"成功"。 */
    public func setPassword(userId: Int64, password: String, now: Int64): Unit {
        let who = findUserById(userId)
        if (who.isNone()) {
            // 同理：这是"请求的账号不存在"，属 4xx，不是服务端故障
            throw UserFacingError("账号不存在：${userId}")
        }
        let pwOk = checkPasswordStrength(password, who.getOrThrow().loginName)
        if (!pwOk.ok) {
            // 用 UserFacingError：映射为 400 VALIDATION_FAILED，不是 500
            throw UserFacingError("口令强度不足：${pwOk.reason}")
        }
        let rec = newPasswordRecord(password)
        db.exec("UPDATE auth_user SET pw_salt = ?, pw_hash = ?, pw_iter = ? WHERE id = ?",
                [DbStr(rec[0]), DbStr(rec[1]), DbInt(rec[2]), DbInt(userId)])
        revokeAllTokens(userId)
    }

    /* 登录 */

    /* 校验口令并签发令牌。账号不存在时照样跑一次完整 PBKDF2（假材料），两条路径耗时一致，防枚举。
     * 锁定检查必须在 PBKDF2 之前，否则限流反成攻击者的 CPU 放大器。
     * 返回值：LoginOutcome 区分成功 / 凭据不对（统一不区分）/ 已锁定（带 retryAfterSeconds）。 */
    public func login(loginName: String, password: String,
                      now: Int64,
                      deviceId!: String = "", deviceName!: String = ""): LoginOutcome {
        let out = LoginOutcome()

        // 0) 限流闸门：已锁定 → 直接拒绝，不跑 PBKDF2
        let st = lockState(loginName, now)
        if (st.locked) {
            out.locked = true
            out.retryAfterSeconds = st.retryAfterSeconds
            return out
        }

        let found = findUser(loginName)
        let ok: Bool
        match (found) {
            case Some(u) =>
                let creds = loginCreds(true, u.pwSalt, u.pwHash, u.pwIter)
                ok = verifyPw(password, creds[0], creds[1], creds[2])
                if (ok && u.status != "active") {
                    return out                 // 账号停用：既不计失败也不签发
                }
                if (ok && !authReferenceExists(u.role, u.refId)) {
                    return out                 // 幽灵业务身份：不签发令牌，不泄露缺失原因
                }
                if (ok) {
                    out.userId = u.id
                }
            case None =>
                // 账号不存在：仍跑 PBKDF2（假材料），然后失败 —— 耗时与"口令错"一致
                let creds = loginCreds(false, "", "", 0)
                let _ = verifyPw(password, creds[0], creds[1], creds[2])
                ok = false
        }

        if (!ok) {
            // 记一次失败，并把"记完是否已锁定"回给调用方
            let after = recordFailure(loginName, now)
            out.locked = after.locked
            out.retryAfterSeconds = after.retryAfterSeconds
            return out
        }

        // 1) 成功：清失败计数 + 顺手回收过期令牌与陈旧计数（各一趟）
        let _ = clearFailures(loginName)
        let _ = pruneTokens(now)
        let _ = pruneAttempts(now)

        // 2) 签发令牌（记录设备信息，供"会话列表 / 踢单台设备"使用）
        let tok = newToken()
        let expires = now + TOKEN_TTL
        db.exec(
            "INSERT INTO auth_token (token, user_id, created_at, expires_at, last_renew_at, " +
            " device_id, device_name, last_seen_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            [DbStr(tok), DbInt(out.userId), DbInt(now), DbInt(expires), DbInt(now),
             DbStr(deviceId), DbStr(deviceName), DbInt(now)])
        out.token = tok
        out.expiresAt = expires
        return out
    }

    /* 令牌 */

    /* 列某账号的活跃会话（令牌按设备管理）。
     * 只返回未过期会话；按 last_seen_at DESC、同刻按 device_id 定序，保证列表可复现。
     * 不含 token 本身：列出会话只需区分设备。 */
    public func listSessions(userId: Int64, now: Int64): Array<SessionInfo> {
        let rs = db.query(
            "SELECT device_id, device_name, created_at, last_seen_at, expires_at " +
            "FROM auth_token WHERE user_id = ? AND expires_at > ? " +
            "ORDER BY last_seen_at DESC, device_id ASC",
            [DbInt(userId), DbInt(now)])
        let out = ArrayList<SessionInfo>()
        var i: Int64 = 0
        while (i < rs.rowCount()) {
            let s = SessionInfo()
            s.deviceId = rs.getString(i, 0)
            s.deviceName = rs.getString(i, 1)
            s.createdAt = rs.getInt(i, 2)
            s.lastSeenAt = rs.getInt(i, 3)
            s.expiresAt = rs.getInt(i, 4)
            out.add(s)
            i = i + 1
        }
        return out.toArray()
    }

    /* 踢掉某账号在指定设备上的全部会话，返回删除行数。
     * 必须带 user_id 条件：device_id 是客户端自报的，只按它删会让 A 踢掉 B 的会话。
     * deviceId 为空串时拒绝执行并返回 0，否则会一次踢掉所有未报设备的会话；踢全部请走 revokeAllTokens。 */
    public func revokeSessionsByDevice(userId: Int64, deviceId: String): Int64 {
        if (deviceId.size == 0) {
            return 0
        }
        return db.exec("DELETE FROM auth_token WHERE user_id = ? AND device_id = ?",
                       [DbInt(userId), DbStr(deviceId)])
    }

    /* 刷新 last_seen_at（默认 300s 节流）：不更新的话会话列表永远按登录顺序排，用户分不清。 */
    public func touchSession(token: String, now: Int64, throttleSeconds!: Int64 = 300): Unit {
        let _ = db.exec(
            "UPDATE auth_token SET last_seen_at = ? WHERE token = ? AND last_seen_at < ?",
            [DbInt(now), DbStr(token), DbInt(now - throttleSeconds)])
    }


    /* 回收全部已过期令牌，返回删除行数；签发时顺手清一次，否则 auth_token 只增不减、索引持续膨胀。 */
    public func pruneTokens(now: Int64): Int64 {
        return db.exec("DELETE FROM auth_token WHERE expires_at <= ?", [DbInt(now)])
    }

    /* 吊销某账号的全部令牌。返回删除行数。 */
    public func revokeAllTokens(userId: Int64): Int64 {
        return db.exec("DELETE FROM auth_token WHERE user_id = ?", [DbInt(userId)])
    }

    /* 吊销单个令牌（登出）。返回 true = 确实删掉了一行。 */
    public func revokeToken(token: String): Bool {
        let n = db.exec("DELETE FROM auth_token WHERE token = ?", [DbStr(token)])
        return n == 1
    }

    /* 令牌 → 身份。过期 / 不存在 / 账号停用一律返回 None，调用方负责抛 401 AUTH_TOKEN_EXPIRED。
     * 滑动续期：剩余不足 TOKEN_TTL - RENEW_AFTER 时续到 now + TOKEN_TTL，用 last_renew_at 节流到每天最多写一次。 */
    public func principalByToken(token: String, now: Int64): ?Principal {
        if (token.size == 0) {
            return None
        }
        let rs = db.query(
            "SELECT t.user_id, t.expires_at, t.last_renew_at, u.role, u.ref_id, u.status " +
            "FROM auth_token t JOIN auth_user u ON u.id = t.user_id WHERE t.token = ?",
            [DbStr(token)])
        if (rs.rowCount() < 1) {
            return None
        }
        let userId = rs.getInt(0, 0)
        let expiresAt = rs.getInt(0, 1)
        let lastRenew = rs.getInt(0, 2)
        let roleStr = rs.getString(0, 3)
        let refId = rs.getInt(0, 4)
        let status = rs.getString(0, 5)

        if (expiresAt <= now) {
            // 过期的顺手删掉，别留垃圾
            let _ = revokeToken(token)
            return None
        }
        if (status != "active") {
            return None
        }

        let p = Principal()
        p.userId = userId
        p.role = match (roleOf(roleStr)) {
            case Some(r) => r
            case None => return None
        }
        if (!authReferenceExists(p.role, refId)) {
            return None
        }

        // 仅有效身份才滑动续期（节流：每天最多一次）。
        /* 必须把续期后的有效期回填给调用方（p.expiresAt）：否则各端只能缓存登录时的旧值，两侧到期时刻越差越大。 */
        var effectiveExpires = expiresAt
        if (expiresAt - now < TOKEN_TTL - RENEW_AFTER && now - lastRenew >= RENEW_AFTER) {
            db.exec("UPDATE auth_token SET expires_at = ?, last_renew_at = ? WHERE token = ?",
                    [DbInt(now + TOKEN_TTL), DbInt(now), DbStr(token)])
            effectiveExpires = now + TOKEN_TTL
        }
        p.expiresAt = effectiveExpires
        /* 角色 → 业务实体 id：患者 patient.id / 医生 doctor.id / 管理员 0。 */
        match (p.role) {
            case Patient => p.patientId = refId
            case Doctor => p.doctorId = refId
            case Admin => ()
        }
        return Some(p)
    }
}
