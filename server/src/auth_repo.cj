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

/*
 * ⚠ 本文件原先**没有 import**（它只用 String/Int64 与 db.exec/query）。
 *   2026-10-07 引入"登录名归一 + 哈希"后需要两个 stdx 模块，必须显式 import ——
 *   否则报 `undeclared identifier 'toHexString'`（实测踩到）。
 *   · stdx.crypto.digest  → HMAC / SHA256（经 auth_crypto.hmacSha256 间接用）
 *   · stdx.encoding.hex   → toHexString
 *
 * ⚠⚠ **不要** import `std.convert.*`：实测加上之后 `trimAscii` 反而变成
 *   `undeclared identifier 'trimAscii'`（那个模块有同名符号，把可用的那个遮蔽掉了）。
 *   真正让 `trimAscii` / `toAsciiLower` 可用的是 **`std.collection.*`** ——
 *   证据：两个用它们的文件（`main.cj` / `http_app.cj`）都 import 了它。
 *   这个"到底谁提供 trimAscii"的排查花了好几轮，记下来免得下次再找。
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

/* ===================== 登录限流 / 锁定（P1 安全加固）===================== */

/*
 * 登录失败限流参数。
 *
 * ★ 为什么必须有它：没有限流时，攻击者可以**无限次**尝试口令。
 *   本项目的口令用 PBKDF2（10 万次迭代）确实让单次尝试很贵（约百毫秒），
 *   但那只把"离线爆破"变贵，**在线爆破只需要一个循环** ——
 *   而且能把服务端的 PBKDF2 当 **CPU 放大器**打（每次尝试都烧 100ms CPU）。
 *
 * 取值口径（三个数字都要能解释，不能拍脑袋）：
 *   · FAIL_LIMIT = 5        —— 正常人手误 1~2 次；5 次足够容错，又不给爆破留空间。
 *   · FAIL_WINDOW = 900s    —— 15 分钟窗口内的失败才累计；零散的手误不会累积成锁定。
 *   · LOCK_SECONDS = 900s   —— 锁 15 分钟。
 *
 * ── ★ 关于"锁定"的代价：必须**如实**说，不能美化（2026-10-07 订正）────────
 * 本文件原先写着"攻击者最多拖慢自己，用户等一会儿即可自愈"。
 * **这句话是错的** —— 复查指出，实测也证实：锁定记在**账号**上，
 * 所以知道某人登录名的攻击者**可以故意输错 5 次来锁死那个真实用户**
 * （锁定期内他连**正确口令**也进不来，实测同样返回 429）。
 *
 * 这是**账号级锁定固有的代价**，不是实现 bug。如实写成：
 *     「可被用于对**特定账号**做 15 分钟量级的拒绝服务」。
 *
 * 为什么仍然选账号级锁定（而不是因此取消）：
 *   · 不锁 ⇒ 在线爆破不受限，那是更严重的问题（口令被撞开，泄露的是病历）；
 *   · 折中是**有限窗口**：受害者最多等 15 分钟即可自愈，**无需人工解锁**。
 *     永久锁定才是真正的 DoS —— 攻击者一次故意输错就能永久挡住用户，还要运维介入；
 *   · 要**彻底**消除这个代价，需要按 IP 限流或加验证码 —— 属于 P2+ 范围。
 *     这里如实记录为**已知边界**，不假装没有。
 */
public let LOGIN_FAIL_LIMIT: Int64 = 5
public let LOGIN_FAIL_WINDOW: Int64 = 900
public let LOGIN_LOCK_SECONDS: Int64 = 900

/*
 * ★★ 登录名归一口径（2026-10-07 修，第三份复查发现的**严重**缺陷）。
 *
 * ── 缺陷长什么样（实测复现）──────────────────────────────────────────────
 * 限流计数按**登录名字符串**记，而账号查找是 **TC 不敏感**
 * （`utf8mb4_general_ci` + `PAD SPACE`：`'Admin' = login_name` → 1，
 *   `'admin ' = login_name` → 1）。两套口径不一致 ⇒ 换个写法就换一份新预算：
 *     先把 `admin` 锁死（5 次）→ 再用**正确口令**试：
 *        'Admin'     -> 200 拿到令牌
 *        'aDmIn'     -> 200 拿到令牌
 *        'admin  '   -> 200 拿到令牌        ← 尾空格
 *        '  admin'   -> 401（MySQL 不忽略**首**空格）
 *   库里当时躺着**两份**计数（`fail_count=5` 与 `fail_count=1`）。
 *
 * 危害程度按登录名形态不同（如实算清楚，不含糊）：
 *   · 字母/拼音登录名（`admin`）：大小写变体上限 2^n − 1 份预算
 *     （`admin` 就是 2^5 − 1 = **31 份**，31×5 = 155 次/15 分钟）；
 *   · **尾空格变体**：`admin` / `admin ` / `admin  ` … 任意长 ⇒ **无限份预算**；
 *   · ★ **纯数字登录名（手机号）没有字母**，大小写变体为 0，
 *     但**尾空格变体**照样给任意份预算（`13800000001` / `13800000001 ` …）。
 *   所以"当前最容易被攻击的那一面"的修复，本来可以用**一个字符**绕过。
 *
 * ── 修法：**库与哈希共用同一个归一值** ──────────────────────────────────
 *   ① `trimAscii` —— 去掉首尾空白（**首空格也要去**：MySQL 只忽略尾空格，
 *      只做 trim 尾侧会让 `  admin` 变成第六份预算）；
 *   ② `toAsciiLower` —— 统一小写（与 `_ci` 一致）。
 *   然后 `findUser` / `createUser` / `login` / `loginNameHash` **全都**先归一。
 *
 * ⚠ 为什么用 `toAsciiLower` 而不是 locale 感知的 `toLower`：
 *   登录名是 ASCII（手机号 / 工号 / 字母用户名）。用 locale 感知的转换会引入
 *   "同一字符串在不同机器上归一成不同结果"的风险（土耳其语 I 问题那一类），
 *   而**归一口径必须跨机器一致**，否则限流又能被绕过（换台机器就是新预算的翻版）。
 *   ASCII-only 宁可少归一，也不要**不一致地**归一。
 *
 * 📌 归一只在**边界**做一次（仓储层），调用方不必各自记得 ——
 *   这正是"两处口径容易漂移"的防范：现在只有 `normalizeLoginName` 一处定义。
 */
public func normalizeLoginName(raw: String): String {
    /*
     * ⚠ `trimAscii` 是 **String 的方法**，不是自由函数 ——
     *   实测写成 `trimAscii(raw)` 报 `undeclared identifier 'trimAscii'`
     *   （而单独写 `raw.trimAscii()` 完全正常）。这一点排查了好几轮，
     *   因为错误信息只说"未声明标识符"，不提示"你可能漏了接收者"。
     */
    return raw.trimAscii().toAsciiLower()
}

/*
 * 归属哈希用的固定密钥。
 * ⚠ 见 `loginNameHash` 的说明：这是**公开常量**，不是机密；**不要轮换**它
 *   （轮换会让所有历史计数行失配 = 等价于清空限流状态）。
 */
private let LOGIN_HASH_KEY: String = "smart-hospital/login-attempt/v1"

/*
 * 登录名的哈希（十六进制）。**入参是已归一化的值**。
 *
 * 为什么键用哈希而不是原文：
 *   ① 库被读走后不会直接得到一份"谁被撞过库"的名单；
 *   ② 让"不存在的登录名"与"存在的登录名"在**存储层**也长得一样 ——
 *      这是本项目"防枚举"口径的一部分（与 auth_crypto 的假材料同一思路）。
 *
 * ⚠ 实现说明：本项目的 crypto 层**只暴露了 HMAC-SHA256**
 *   （`hmacSha256`，见 auth_crypto.cj:162），没有裸的 `sha256(bytes)`。
 *   所以这里用 **HMAC-SHA256 + 固定密钥** 当带密钥的摘要。
 *
 * ⚠ 这个 key 是**公开常量**，不是机密：它的作用只是"把登录名映射成定长键"，
 *   不是抗离线爆破（登录名不是口令）。**不要**把它当安全参数去轮换 ——
 *   轮换会让所有历史计数行失配（等价于清空限流状态）。
 */
public func loginNameHash(loginName: String): String {
    return toHexString(hmacSha256(LOGIN_HASH_KEY.toArray(), normalizeLoginName(loginName).toArray()))
}

/* 登录锁定状态。 */
public class LockState {
    public var locked: Bool = false
    public var failCount: Int64 = 0
    public var retryAfterSeconds: Int64 = 0
}

/*
 * 登录结果。
 *
 * ── 为什么从 `?(Int64, String, Int64)` 换成这个类（2026-10-07）
 * 引入限流后，登录有**三种**结局，而元组 + Option 只能表达两种：
 *     ① 成功（有 token）
 *     ② 凭据不对（口令错 / 账号不存在 / 停用 —— 三者刻意不区分，防枚举）
 *     ③ **被限流锁定**（与凭据对不对无关，所以不能混进 ②）
 * 用 Option 硬塞会把③伪装成②，于是客户端拿不到"等多久再来"，
 * 而且 ② 的"不区分"口径也会被破坏。
 */
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

public class AuthRepo {
    private let db: DbBackend

    public init(db: DbBackend) {
        this.db = db
    }

    /* ---------- 登录限流：读 / 记 / 清 ---------- */

    /*
     * 查某登录名当前的锁定状态（**只读，不改状态**）。
     *
     * 锁定判据（两条都要满足）：
     *   · `fail_count >= LOGIN_FAIL_LIMIT`     —— 失败次数够多
     *   · `now - last_fail_at < LOGIN_LOCK_SECONDS` —— 且最近一次失败还在锁定期内
     * 第二条让锁定**自动过期**（无需后台任务），也避免"永久锁定"被用来对真实用户做拒绝服务。
     *
     * ⚠ 观察窗口（LOGIN_FAIL_WINDOW）在这里**不**参与判定，而是由 recordFailure
     *   在写入时用它决定"是继续累计还是重新起一轮"。这样判定逻辑只有一处，
     *   不会出现"读的时候按窗口、写的时候按次数"这种两套口径。
     */
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

    /*
     * 记一次登录失败。返回记完之后的锁定状态（调用方据此决定要不要返回"已锁定"）。
     *
     * 累计规则（刻意只有一条）：**距上次失败超过观察窗口就重新起一轮**。
     *   · 连续失败（间隔 < 15 分钟）→ fail_count 递增 ⇒ 够 5 次就锁；
     *   · 零散手误（间隔 > 15 分钟）→ 从 1 重新数 ⇒ **不会攒成锁定**。
     * 这正是"正常人手误不该被锁"与"爆破必须被挡"的平衡点。
     *
     * ⚠ 用 INSERT ... ON DUPLICATE KEY UPDATE 一条语句完成"插入或累计"，
     *   避免"先查再写"的跨语句窗口（并发爆破时那个窗口会让计数偏少）。
     */
    public func recordFailure(loginName: String, now: Int64): LockState {
        let h = loginNameHash(loginName)
        /*
         * ⚠ 这条 SQL 的 `window_start` 更新有讲究：
         *   `IF(window_start = 0 OR ? - window_start > 窗口, ?, window_start)`
         *   —— 新窗口就把 window_start 推到 now，否则保持。
         *   而 fail_count 用同样的条件决定"重置为 1"还是"加 1"。
         *   两个字段的条件必须一致，否则窗口与计数会错位。
         */
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

    /*
     * 登录成功后清掉失败计数。
     * ★ 必须清：否则"之前失败 4 次 + 这次成功"会留下 4 次，
     *   下次再失败 1 次就被锁 —— 而用户其实一直登录正常。
     */
    public func clearFailures(loginName: String): Int64 {
        return db.exec("DELETE FROM auth_login_attempt WHERE login_hash = ?",
                       [DbStr(loginNameHash(loginName))])
    }

    /*
     * 清理长期未失败的计数行（返回删除行数）。
     *
     * 为什么要有：否则任何被尝试过一次的登录名都会**永久留一行**
     *   —— 攻击者可以拿随机登录名刷爆这张表（表只增不减，基线 tokens 表就是这么踩的）。
     * 保留期取 **10 倍观察窗口**（2.5 小时）：远超判定所需，又能让表自动收敛。
     * 在登录成功时顺手清一次（与 pruneTokens 同一"低频一趟"策略）。
     */
    public func pruneAttempts(now: Int64): Int64 {
        return db.exec("DELETE FROM auth_login_attempt WHERE last_fail_at < ?",
                       [DbInt(now - LOGIN_FAIL_WINDOW * 10)])
    }

    /* ---------- 账号 ---------- */

    /* 按登录名查账号；不存在返回 None。 */
    public func findUser(loginName: String): ?AuthUser {
        /*
         * ★ 查询前归一（2026-10-07）：账号查找在 DB 侧本来就是 TC 不敏感
         *   （utf8mb4_general_ci + PAD SPACE），所以归一只是把**既有的实际行为**
         *   在应用侧写明。这样"归一值"就成了限流计数与账号查找的**同一个口径** ——
         *   不会再有"换个大写就是新预算"的绕过。
         */
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
        /*
         * ★ 写入前归一：库里存的**就是**归一值，于是唯一索引
         *   `uk_auth_user_login (login_name)` 才真正拦住"大小写变体重复注册"。
         *   （否则 `Admin` 与 `admin` 会被 _ci 索引判重而报 1062 —— 错误信息
         *     还会说"已存在"，但用归一值就根本不会走到那一步。）
         */
        let existing = findUser(loginName)
        if (existing.isSome()) {
            return existing.getOrThrow().id
        }
        let rec = newPasswordRecord(password)
        db.exec(
            "INSERT INTO auth_user " +
            "(login_name, role, ref_id, display_name, pw_salt, pw_hash, pw_iter, " +
            " status, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, 'active', ?)",
            [DbStr(normalizeLoginName(loginName)), DbStr(roleName(role)), DbInt(refId), DbStr(displayName),
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
     * ★ 限流（2026-10-07 增）：连续失败 LOGIN_FAIL_LIMIT 次后锁定一段时间。
     *   ⚠ **顺序很重要**：锁定检查放在 PBKDF2 **之前**（锁定时不必再烧 100ms CPU
     *   —— 否则限流反而成了攻击者放大 CPU 消耗的工具）。
     *
     * ⚠ 返回值的语义（调用方 http_app.cj 必须照此映射）：
     *      Some(...)            → 登录成功
     *      None                 → 口令错 / 账号不存在 / 账号停用（**统一不区分**，防枚举）
     *      Some 之外的第三种...  → 用 LoginOutcome 表达"已锁定"，见下方类型
     */
    public func login(loginName: String, password: String,
                      now: Int64): LoginOutcome {
        let out = LoginOutcome()

        // 0) 限流闸门：已锁定 → 直接拒绝，**不跑 PBKDF2**
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

        // 2) 签发令牌
        let tok = newToken()
        let expires = now + TOKEN_TTL
        db.exec(
            "INSERT INTO auth_token (token, user_id, created_at, expires_at, last_renew_at) " +
            "VALUES (?, ?, ?, ?, ?)",
            [DbStr(tok), DbInt(out.userId), DbInt(now), DbInt(expires), DbInt(now)])
        out.token = tok
        out.expiresAt = expires
        return out
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
