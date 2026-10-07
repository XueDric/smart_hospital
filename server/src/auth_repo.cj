/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 *
 * ===== auth_repo.cj —— 鉴权仓储（MySQL 令牌体系）===========================
 *
 * 口径来源：baseline/server/src/auth.cj 的令牌部分，但**持久化从内存 Store 换成 MySQL**
 * （基线把 token → member 映射放在 `s.tokens` 内存表里、随整库刷盘落盘；
 *  本项目是"直接 SQL"范式，见 ADR-0001 §4.2 的两套范式）。
 *
 * ★ 关键设计：**principalOf() 与 can() 解耦**。
 *   本文件只负责"令牌 → 身份"，权限判定仍在 http_app.cj 的 `can()` 里。
 *   所以从开发态身份头切到令牌，**业务逻辑与权限矩阵一行未改**。
 *
 * ⚠ 基线的容量教训（`capacity-baseline.md`：4 并发登录 1574→867ms）：
 *   基线把 PBKDF2 移出全局锁（三阶段加锁）才有量级收益。本项目**没有全局锁**
 *   —— 令牌与账号都是直接 SQL，PBKDF2 天然不在任何锁内。
 *   但要注意：**PBKDF2 的 10 万次迭代本身是 CPU 密集的**（约百毫秒量级），
 *   所以登录接口在并发下会争 CPU。这里靠两件事缓解：
 *     ① 每条 HTTP 连接各自 PBKDF2，不互相阻塞（无锁）；
 *     ② 用**假材料**统一"账号不存在"路径的成本（防枚举，见 auth_crypto.cj loginCreds）。
 */

package qingzhou

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

/* ===================== 鉴权仓储 ===================== */

public class AuthRepo {
    private let db: DbBackend

    public init(db: DbBackend) {
        this.db = db
    }

    /* ---------- 账号 ---------- */

    /* 按登录名查账号；不存在返回 None。 */
    public func findUser(loginName: String): ?AuthUser {
        let rs = db.query(
            "SELECT id, login_name, role, ref_id, display_name, pw_salt, pw_hash, " +
            "pw_iter, status FROM auth_user WHERE login_name = ?", [DbStr(loginName)])
        if (rs.rowCount() < 1) {
            return None
        }
        let u = AuthUser()
        u.id = rs.getInt(0, 0)
        u.loginName = rs.getString(0, 1)
        u.role = match (roleOf(rs.getString(0, 2))) {
            case Some(r) => r
            case None => Role.Patient
        }
        u.refId = rs.getInt(0, 3)
        u.displayName = rs.getString(0, 4)
        u.pwSalt = rs.getString(0, 5)
        u.pwHash = rs.getString(0, 6)
        u.pwIter = rs.getInt(0, 7)
        u.status = rs.getString(0, 8)
        return Some(u)
    }

    /*
     * 建账号（幂等：登录名已存在则返回既有 id）。
     * 口令用 newPasswordRecord() 生成（16 字节盐 + 10 万次 PBKDF2）。
     */
    public func createUser(loginName: String, role: Role, refId: Int64,
                           displayName: String, password: String, now: Int64): Int64 {
        let existing = findUser(loginName)
        if (existing.isSome()) {
            return existing.getOrThrow().id
        }
        let rec = newPasswordRecord(password)
        db.exec(
            "INSERT INTO auth_user " +
            "(login_name, role, ref_id, display_name, pw_salt, pw_hash, pw_iter, " +
            " status, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, 'active', ?)",
            [DbStr(loginName), DbStr(roleName(role)), DbInt(refId), DbStr(displayName),
             DbStr(rec[0]), DbStr(rec[1]), DbInt(rec[2]), DbInt(now)])
        let rs = db.query("SELECT LAST_INSERT_ID()", Array<DbValue>())
        if (rs.rowCount() < 1) {
            return 0
        }
        return rs.getInt(0, 0)
    }

    /* 账号是否存在（按 id）。用于"重置口令"前确认，避免 UPDATE 影响 0 行却回 200。 */
    public func userExists(userId: Int64): Bool {
        let rs = db.query("SELECT COUNT(*) FROM auth_user WHERE id = ?", [DbInt(userId)])
        if (rs.rowCount() < 1) {
            return false
        }
        return rs.getInt(0, 0) > 0
    }

    /* 改口令（同时吊销该账号**全部**令牌 —— 改密码必须踢下线）。 */
    public func setPassword(userId: Int64, password: String, now: Int64): Unit {
        let rec = newPasswordRecord(password)
        db.exec("UPDATE auth_user SET pw_salt = ?, pw_hash = ?, pw_iter = ? WHERE id = ?",
                [DbStr(rec[0]), DbStr(rec[1]), DbInt(rec[2]), DbInt(userId)])
        revokeAllTokens(userId)
    }

    /* ---------- 登录 ---------- */

    /*
     * 校验口令并签发令牌。
     *
     * ★ 防枚举（N-16）：账号不存在时**照样跑一次完整 PBKDF2**（用假材料），
     *   让两条路径的耗时一致。否则"登录响应快 = 账号不存在"就成了枚举器，
     *   而"谁在本院看过病"正是最该保护的信息。
     *
     * 返回 (userId, token, expiresAt) 或 None（口令错/账号停用）。
     */
    public func login(loginName: String, password: String,
                      now: Int64): ?(Int64, String, Int64) {
        let found = findUser(loginName)
        let u = match (found) {
            case Some(x) => x
            case None =>
                // 账号不存在：仍跑 PBKDF2（假材料），然后失败
                let creds = loginCreds(false, "", "", 0)
                let _ = verifyPw(password, creds[0], creds[1], creds[2])
                return None
        }
        let creds = loginCreds(true, u.pwSalt, u.pwHash, u.pwIter)
        if (!verifyPw(password, creds[0], creds[1], creds[2])) {
            return None
        }
        if (u.status != "active") {
            return None
        }
        // 签发令牌：顺手回收过期令牌（照基线 issueToken 的"低频 O(n) 一趟"）
        let _ = pruneTokens(now)
        let tok = newToken()
        let expires = now + TOKEN_TTL
        db.exec(
            "INSERT INTO auth_token (token, user_id, created_at, expires_at, last_renew_at) " +
            "VALUES (?, ?, ?, ?, ?)",
            [DbStr(tok), DbInt(u.id), DbInt(now), DbInt(expires), DbInt(now)])
        return Some((u.id, tok, expires))
    }

    /* ---------- 令牌 ---------- */

    /*
     * 回收全部已过期令牌（返回删除行数）。
     *
     * 为什么要有：基线的教训（`auth.cj:151-160`）—— 原先只在"某个已过期令牌被再次使用"
     * 时才删，用户不再登录就永远留着，于是 tokens 表**只增不减**。
     * 在基线上那会让每次写盘多背几百 KB；在本项目上则是让 `auth_token` 无限增长、
     * 且 `idx_auth_token_expires` 索引持续膨胀。所以签发时顺手清一次。
     */
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

    /*
     * 令牌 → 身份。过期 / 不存在 / 账号停用一律返回 None（**调用方负责抛 401**）。
     *
     * ★ 滑动续期：有效期不足 `TOKEN_TTL - RENEW_AFTER` 时续到 now + TOKEN_TTL，
     *   但用 `last_renew_at` **节流到每天最多写一次** —— 否则每个请求都写库
     *   （基线 auth.cj:206 的同一考量：`RENEW_AFTER` 就是为这个存在的）。
     */
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

        // 滑动续期（节流：每天最多一次）
        if (expiresAt - now < TOKEN_TTL - RENEW_AFTER && now - lastRenew >= RENEW_AFTER) {
            db.exec("UPDATE auth_token SET expires_at = ?, last_renew_at = ? WHERE token = ?",
                    [DbInt(now + TOKEN_TTL), DbInt(now), DbStr(token)])
        }

        let p = Principal()
        p.userId = userId
        p.role = match (roleOf(roleStr)) {
            case Some(r) => r
            case None => Role.Patient
        }
        /*
         * 角色 → 业务实体 id 的映射。
         * 患者：refId 即 patient.id（挂号要用它）；
         * 医生：refId 是 doctor.id；
         * 管理员：无业务实体，保持 0。
         */
        match (p.role) {
            case Patient => p.patientId = refId
            case Doctor => p.doctorId = refId
            case Admin => ()
        }
        return Some(p)
    }
}
