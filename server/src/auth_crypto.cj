/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 *
 * ===== auth_crypto.cj —— 口令哈希与令牌原语 ================================
 *
 * 口令：**PBKDF2-HMAC-SHA256，100000 次迭代，16 字节随机盐**。
 *   为什么不直接用现成的：stdx.crypto.digest 只确认了 SHA256 与 HMAC，
 *   没有确认 PBKDF2 入口。本实现按 RFC 2898 写，并用**三个公开测试向量**钉住
 *   （RFC 7914 §11 两条 + 100k 与 .NET Rfc2898DeriveBytes 对拍一条）——
 *   见 `authSelfTest()`，⚠ 这段必须在连库之前跑，它是"这套密码学没写错"的唯一凭据。
 *
 * 令牌：32 字节随机 → 64 位十六进制，服务端存 token → 用户映射。
 *   **不是无状态 JWT**：这样"停用账号"能立即踢下线（搬迁前的 api-design §1.4 的决策）。
 *
 * 口径来源：搬迁前的 auth.cj，本文件是它的**自包含子集** ——
 * 只搬口令与令牌原语，**不搬**绑定内存 Store 的那部分（pruneTokens/issueToken/
 * requireMember），那些在本项目要改成 MySQL 版（见 auth_repo.cj）。
 *
 * ⚠ 命名：本项目与轻舟框架**同包编译**，顶层名字共享命名空间。
 *   框架已有 `issueToken`（third_party/qingzhou/src/auth.cj:25），
 *   所以本项目的令牌签发叫 **`issueAuthToken`**（已 grep 框架确认无冲突）。
 */

package qingzhou

import std.collection.*
import std.random.*
import stdx.crypto.digest.*
import stdx.encoding.hex.*

/* ===================== 常量 ===================== */

/* 口令哈希迭代数。与搬迁前同口径。 */
public let PBKDF2_ITER: Int64 = 100000

/* 令牌有效期：30 天。 */
public let TOKEN_TTL: Int64 = 30 * 86400

/* 滑动续期节流：每令牌最多每天落盘一次（否则每个请求都写库）。 */
public let RENEW_AFTER: Int64 = 86400

/* ===================== 随机源 ===================== */

/*
 * 取 n 字节随机数。
 * ⚠ std.random 的 `nextBytes` 是**填充已有缓冲区**的形态（框架 requestid.cj 也这么用），
 *   不要写成 `nextBytes(n)` 取返回值 —— 那是另一套语义。
 *
 * ⚠⚠ **已知限制，必须写明（复查项）**：这里用的是 `std.random.Random()`，
 *   本工具链**没有任何文档或 API 能证明它由 OS CSPRNG（CryptGenRandom / RtlGenRandom）**
 *   播种或驱动。也就是说：**会话令牌的随机性强度目前无法证实**。
 *
 *   当前处置（明确决策，不是"忘了"）：
 *     · 令牌是 32 字节（256 bit），即使 RNG 只是"高质量 PRNG"，
 *       在没有同进程观测能力的前提下爆破仍不现实；
 *     · 但**不宣称**它是密码学安全的 —— 不把没验证的东西写成保证。
 *
 *   要真正确认/加固的两条路（留给后续）：
 *     ① 查明 cjc 1.2.0 的 `std.random` 底层实现（是否走 BCryptGenRandom）；
 *     ② 若不确定，则改用 OpenSSL 的 `RAND_bytes` —— 运行时已经依赖
 *        OpenSSL 3 的 DLL（`libcrypto-3-x64.dll`），加一层 CFFI 即可。
 */
public func randBytes(n: Int64): Array<UInt8> {
    let r = Random()
    let buf = Array<UInt8>(n, repeat: 0)
    r.nextBytes(buf)
    return buf
}

/* 随机十六进制串。盐与令牌都用它。 */
public func randHex(nbytes: Int64): String {
    return toHexString(randBytes(nbytes))
}

/* 会话令牌：32 字节 = 64 个十六进制字符。 */
public func newToken(): String {
    return randHex(32)
}

/*
 * [0, bound) 的均匀随机数。
 * 用 7 字节（56 位）拼正整数，保证乘法不溢出（仓颉溢出会抛异常）。
 */
public func randBelow(bound: Int64): Int64 {
    if (bound <= 1) {
        return 0
    }
    let r = Random()
    let buf = Array<UInt8>(7, repeat: 0)
    r.nextBytes(buf)
    var v: Int64 = 0
    var i: Int64 = 0
    while (i < 7) {
        v = v * 256 + Int64(buf[i])
        i += 1
    }
    return v % bound
}

/*
 * 易读口令字母表：去掉 0/O、1/I/L、2/Z、5/S、8/B 这类易混字符。
 * 管理员初始口令要能被人**在聊天里口头传达或手抄**，可读性是功能要求，不是美化。
 * （口径与搬迁前 ids.cj:61 的 CODE_ALPHABET 一致。）
 */
public let CODE_ALPHABET: String = "ACDEFGHJKLMNPQRTUVWXY34679"

/* 字母表里的**数字**字符（用于保证生成物含数字）。 */
private let CODE_DIGITS: String = "34679"

/*
 * 生成 length 位的可读口令。
 *
 * ── ★★ 为什么必须**保证成分**（2026-10-07 修，第四份复查发现的真缺陷）──────
 * 原实现是"从 26 个字符里独立均匀取 length 个"，**不保证**结果里既有字母又有数字。
 * 而 `CODE_ALPHABET` 是 **21 字母 + 5 数字**，于是：
 *
 *     P(12 位全是字母) = (21/26)^12 ≈ **7.71%**
 *
 * 实测 70 次 `create-admin` 失败 **6** 次（**8.6%**），与理论值吻合。
 *
 * 失败原因是**自己定的规则拒了自己的产物**：本项目的口令强度规则②要求
 * "同时含字母与数字"，而 `createAdmin` 拿 `randCode(12)` 当口令 ——
 * 约 1/12 的概率直接抛 `口令强度不足`。
 * 更糟的是它不是"口令不合法"这种可提示的失败，而是**异常直冒到顶层打堆栈**
 * （`createAdmin` 只 catch 了建库那段）。
 *
 * 📌 教训：**"生成器"与"校验器"必须在同一个契约下**。
 *   加了强度校验却没回头看"我们自己的口令生成器满不满足它" ——
 *   这与前几轮"修一处忘同类位置"是同一类病。
 *
 * ── 修法：强制成分，但**不牺牲随机性** ──────────────────────────────────
 *   ① 前两位置放 1 个随机字母 + 1 个随机数字（保证成分成立）；
 *   ② 其余位照旧均匀随机；
 *   ③ ★ **整体洗牌**（Fisher–Yates）—— 否则"必有一个字母在首位、一个数字在次位"
 *      会变成可预测的结构（攻击者知道前两位的成分，等价于少了几位熵）。
 *   洗牌用 `randBelow`（与取字符同一随机源），不引入新的随机性假设。
 *
 * ⚠ length < 2 时无法同时放字母与数字 ⇒ 退化为纯随机（并由调用方保证长度）。
 */
public func randCode(length: Int64): String {
    let alpha = CODE_ALPHABET.toArray()
    let letters = ArrayList<UInt8>()
    let digits = ArrayList<UInt8>()
    for (c in alpha) {
        if (CODE_DIGITS.toArray().indexOf(c).isSome()) {
            digits.add(c)
        } else {
            letters.add(c)
        }
    }
    let out = ArrayList<UInt8>()
    if (length >= 2 && letters.size > 0 && digits.size > 0) {
        // ① 先各放一个，保证成分
        out.add(letters[randBelow(letters.size)])
        out.add(digits[randBelow(digits.size)])
        // ② 其余位均匀随机
        while (out.size < length) {
            out.add(alpha[randBelow(alpha.size)])
        }
        // ③ Fisher–Yates 洗牌（从后往前换），打散"前两位固定成分"的结构
        var i = out.size - 1
        while (i > 0) {
            let j = randBelow(i + 1)
            let tmp = out[i]
            out[i] = out[j]
            out[j] = tmp
            i = i - 1
        }
    } else {
        var i: Int64 = 0
        while (i < length) {
            out.add(alpha[randBelow(alpha.size)])
            i = i + 1
        }
    }
    return String.fromUtf8(out.toArray())
}

/* ===================== 定时安全比较 ===================== */

/*
 * 定时安全比较（字节级，长度不同直接 false）。
 *
 * 为什么需要：口令摘要比对**不能在第一个不同字节就返回** ——
 * 那会把"前几个字节对了"这个信息通过耗时泄露出去。
 */
public func constantTimeEq(a: String, b: String): Bool {
    if (a.size != b.size) {
        return false
    }
    var diff: UInt8 = 0
    var i = 0
    let x = a.toArray()
    let y = b.toArray()
    while (i < x.size) {
        diff = diff | (x[i] ^ y[i])
        i += 1
    }
    return diff == 0
}

/* ASCII 前缀判定（只在两端都按小写比较时使用）。 */
public func startsWithAscii(s: String, prefix: String): Bool {
    if (s.size < prefix.size) {
        return false
    }
    return s[0..prefix.size] == prefix
}

/* 从第 from 个字节起取子串（from 超界返回空串）。 */
public func subFrom(s: String, from: Int64): String {
    if (from >= s.size || from < 0) {
        return ""
    }
    return s[from..]
}

/* ===================== PBKDF2 ===================== */

func hmacSha256(key: Array<UInt8>, msg: Array<UInt8>): Array<UInt8> {
    let mac = HMAC(key, { => SHA256() })
    mac.write(msg)
    return mac.finish()
}

/*
 * RFC 2898 PBKDF2，PRF = HMAC-SHA256。
 *
 * ⚠ **参数防线（照搬迁前加固口径）**：本函数**不做业务校验**，非法参数一律
 *   **返回空数组（fail closed）**，而不是"算出一个看起来合法的弱摘要"：
 *   · `iters <= 0` 时下面的循环一次都不跑，等价于 **1 轮** —— 规范里 c 的最小合法值，
 *     也就是"静默降级成最弱配置"。
 *   · `dkLen <= 0` 时切片 `[0..dkLen]` 本身也不合法。
 *   密码学原语**宁可失败，也不降级**。
 */
public func pbkdf2Sha256(pwd: Array<UInt8>, salt: Array<UInt8>, iters: Int64,
                         dkLen: Int64): Array<UInt8> {
    if (iters <= 0 || dkLen <= 0) {
        return Array<UInt8>()
    }
    let hLen: Int64 = 32
    let blocks: Int64 = (dkLen + hLen - 1) / hLen
    let out = ArrayList<UInt8>()
    var i: Int64 = 1
    while (i <= blocks) {
        let seed = ArrayList<UInt8>(salt)
        seed.add(UInt8((i >> 24) & 0xFF))
        seed.add(UInt8((i >> 16) & 0xFF))
        seed.add(UInt8((i >> 8) & 0xFF))
        seed.add(UInt8(i & 0xFF))
        var u = hmacSha256(pwd, seed.toArray())
        let t = u.clone()
        var c: Int64 = 1
        while (c < iters) {
            u = hmacSha256(pwd, u)
            var j: Int64 = 0
            while (j < hLen) {
                t[j] = t[j] ^ u[j]
                j += 1
            }
            c += 1
        }
        for (b in t) {
            out.add(b)
        }
        i += 1
    }
    return out.toArray()[0..dkLen]
}

/* 生成本项目的口令记录：(盐 hex, 摘要 hex, 迭代数)。 */
public func newPasswordRecord(pw: String): (String, String, Int64) {
    let salt = randBytes(16)
    let dk = pbkdf2Sha256(pw.toArray(), salt, PBKDF2_ITER, 32)
    return (toHexString(salt), toHexString(dk), PBKDF2_ITER)
}

/*
 * 校验口令。任何一步异常都当作"不匹配"，**绝不向上抛**。
 *
 * ⚠ 名字不叫 `verifyPassword`：轻舟框架自己已经有一个同名函数（security.cj），
 *   同包编译会冲突（搬迁前 auth.cj:90 记过同一个坑）。
 */
public func verifyPw(pw: String, saltHex: String, hashHex: String, iters: Int64): Bool {
    var salt: Array<UInt8> = Array<UInt8>()
    match (fromHexString(saltHex)) {
        case Some(x) => salt = x
        case None => return false
    }
    if (iters <= 0) {
        return false
    }
    let dk = pbkdf2Sha256(pw.toArray(), salt, iters, 32)
    return constantTimeEq(toHexString(dk), hashHex)
}

/*
 * N-16 口径：账号不存在时用的**假口令材料**。进程内固定即可 ——
 * 攻击者无法从响应里区分"用了哪个盐"。长度与真实值同规格，保证 PBKDF2 输入规模一致。
 */
public let DUMMY_PW_SALT: String = "00000000000000000000000000000000"
public let DUMMY_PW_HASH: String = "0000000000000000000000000000000000000000000000000000000000000000"

/*
 * 取本次登录该用哪一组口令材料（**纯函数**，N-16 的回归闸门）。
 *
 * 账号不存在时返回假材料 + **标准迭代数**，让两条路径的 CPU 成本一致。
 * 搬迁前实测过：如果写成 `if (found) { ok = verifyPw(...) }`，号码不存在时整段
 * 10 万次迭代被跳过，响应时间差约 **13 倍**（388ms 对 28ms），
 * 于是登录接口本身成了一个"某手机号是否注册过"的枚举器。
 *
 * 对本项目尤其要紧：**"谁在本院看过病"是最该保护的一类信息。**
 */
public func loginCreds(found: Bool, salt: String, hash: String,
                       iter: Int64): (String, String, Int64) {
    if (found) {
        return (salt, hash, iter)
    }
    return (DUMMY_PW_SALT, DUMMY_PW_HASH, PBKDF2_ITER)
}

/* ===================== 自检（不需要数据库） ===================== */

/*
 * 口令与令牌原语自检。返回失败项数（0 = 全通过）。
 *
 * ★ 这是"密码学没写错"的**唯一凭据**，所以 `serve` 启动时**先跑它再连库**：
 *   如果 PBKDF2 是错的，连上库也只是在用错的哈希发令牌。
 *
 * ⚠ 第 3 条向量（100k）要跑 10 万次 HMAC，是本函数里唯一有感知耗时的一步
 *   （实测数百毫秒量级）—— 值是**固定的公开向量**，不是"跑得通就算过"。
 */
public func authSelfTest(): Int64 {
    var failed: Int64 = 0

    func check(name: String, ok: Bool): Unit {
        if (ok) {
            println("  [PASS] ${name}")
        } else {
            println("  [FAIL] ${name}")
            failed = failed + 1
        }
    }

    println("=== 口令/令牌原语自检 ===")

    /* 1) RFC 7914 §11 向量 1：pbkdf2("passwd","salt",1,64) */
    let v1 = toHexString(pbkdf2Sha256("passwd".toArray(), "salt".toArray(), 1, 64))
    check("RFC7914 向量1（iters=1, dkLen=64）",
          v1 == "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc" +
                "49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783")

    /* 2) RFC 7914 §11 向量 2：pbkdf2("Password","NaCl",80000,64) */
    let v2 = toHexString(pbkdf2Sha256("Password".toArray(), "NaCl".toArray(), 80000, 64))
    check("RFC7914 向量2（iters=80000, dkLen=64）",
          v2 == "4ddcd8f60b98be21830cee5ef22701f9641a4418d04c0414aeff08876b34ab56" +
                "a1d425a1225833549adb841b51c9b3176a272bdebba1d078478f62b397f33c8d")

    /* 3) 正式参数（100k）与 .NET Rfc2898DeriveBytes 对拍 */
    let v3 = toHexString(pbkdf2Sha256("password".toArray(), "saltSALT".toArray(), 100000, 32))
    check("100k 对拍 .NET Rfc2898DeriveBytes",
          v3 == "5c809e359c03e25b885cf90db237fdea07be535f27a2d4064ae719b6f2996aaa")

    /* 4) 参数防线：非法参数必须 fail closed（返回空），不得静默降级成 1 轮 */
    check("iters=0 → 空数组（fail closed）",
          pbkdf2Sha256("pw".toArray(), "salt".toArray(), 0, 32).size == 0)
    check("iters<0 → 空数组", pbkdf2Sha256("pw".toArray(), "salt".toArray(), -1, 32).size == 0)
    check("dkLen=0 → 空数组", pbkdf2Sha256("pw".toArray(), "salt".toArray(), 1000, 0).size == 0)

    /* 5) 口令记录往返 */
    let rec = newPasswordRecord("abc12345")
    check("正确口令通过", verifyPw("abc12345", rec[0], rec[1], rec[2]))
    check("错误口令拒绝", !verifyPw("abc12346", rec[0], rec[1], rec[2]))
    check("空盐拒绝", !verifyPw("abc12345", "", rec[1], rec[2]))
    check("迭代为0拒绝", !verifyPw("abc12345", rec[0], rec[1], 0))
    check("迭代次数为 100000", rec[2] == PBKDF2_ITER)
    let rec2 = newPasswordRecord("abc12345")
    check("同一口令两次的盐不同", rec[0] != rec2[0])

    /* 6) 定时安全比较 */
    check("相同串相等", constantTimeEq("abcdef", "abcdef"))
    check("不同串不等", !constantTimeEq("abcdef", "abcdeg"))
    check("长度不同不等", !constantTimeEq("abc", "abcd"))

    /* 7) 令牌形态：64 个十六进制字符，且两次不同 */
    let t1 = newToken()
    let t2 = newToken()
    check("令牌长度 64", t1.size == 64)
    check("两次令牌不同", t1 != t2)

    println("")
    if (failed == 0) {
        println("✅ 口令/令牌原语自检全部通过")
    } else {
        println("❌ 口令/令牌原语自检失败 ${failed} 项")
    }
    return failed
}
