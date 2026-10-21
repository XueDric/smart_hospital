/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 * auth_crypto.cj —— 口令哈希（PBKDF2-HMAC-SHA256）与令牌原语。
 * 自检向量见 authSelfTest()，serve 启动时先跑它再连库。
 */

package qingzhou

import std.collection.*
import std.random.*
import stdx.crypto.digest.*
import stdx.encoding.hex.*

/* 常量 */

/* 口令哈希迭代数。 */
public let PBKDF2_ITER: Int64 = 100000

/* 令牌有效期：30 天。 */
public let TOKEN_TTL: Int64 = 30 * 86400

/* 滑动续期节流：每令牌最多每天落盘一次，否则每个请求都写库。 */
public let RENEW_AFTER: Int64 = 86400

/*
 * 取 n 字节随机数；nextBytes 是填充缓冲区的形态，不返回数组。
 * ⚠ 未证实 std.random 由 OS CSPRNG 驱动 —— 不宣称密码学安全；令牌 32 字节
 *   下爆破不现实，加固路径是改用 OpenSSL 的 RAND_bytes。
 */
public func randBytes(n: Int64): Array<UInt8> {
    let r = Random()
    let buf = Array<UInt8>(n, repeat: 0)
    r.nextBytes(buf)
    return buf
}

/* 随机十六进制串；盐与令牌共用。 */
public func randHex(nbytes: Int64): String {
    return toHexString(randBytes(nbytes))
}

/* 会话令牌：32 字节 = 64 个十六进制字符。 */
public func newToken(): String {
    return randHex(32)
}

/* [0, bound) 均匀随机；用 7 字节拼正整数，避免乘法溢出（仓颉溢出抛异常）。 */
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

/* 易读口令字母表：去掉 0/O、1/I/L、2/Z、5/S、8/B 等易混字符，便于口头传达/手抄。 */
public let CODE_ALPHABET: String = "ACDEFGHJKLMNPQRTUVWXY34679"

/* 字母表里的数字字符。 */
private let CODE_DIGITS: String = "34679"

/* 生成 length 位可读口令：必须含字母与数字（否则被自家强度校验拒），再整体洗牌。 */
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
        out.add(letters[randBelow(letters.size)])
        out.add(digits[randBelow(digits.size)])
        while (out.size < length) {
            out.add(alpha[randBelow(alpha.size)])
        }
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

/* 定时安全比较：逐字节累积 XOR；禁止第一个不同字节就返回（耗时差会泄露前缀匹配）。 */
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

/* ASCII 前缀判定；只在两端都已转小写时使用。 */
public func startsWithAscii(s: String, prefix: String): Bool {
    if (s.size < prefix.size) {
        return false
    }
    return s[0..prefix.size] == prefix
}

/* 从第 from 字节起取子串；越界返回空串。 */
public func subFrom(s: String, from: Int64): String {
    if (from >= s.size || from < 0) {
        return ""
    }
    return s[from..]
}

func hmacSha256(key: Array<UInt8>, msg: Array<UInt8>): Array<UInt8> {
    let mac = HMAC(key, { => SHA256() })
    mac.write(msg)
    return mac.finish()
}

/*
 * RFC 2898 PBKDF2（HMAC-SHA256）；参数非法返回空数组，禁止静默降级为 1 轮。
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

/* 生成本项目的口令记录：(盐 hex, 摘要 hex, 迭代数)；盐 16 字节随机。 */
public func newPasswordRecord(pw: String): (String, String, Int64) {
    let salt = randBytes(16)
    let dk = pbkdf2Sha256(pw.toArray(), salt, PBKDF2_ITER, 32)
    return (toHexString(salt), toHexString(dk), PBKDF2_ITER)
}

/* 校验口令：异常一律按不匹配处理；名字避开框架 verifyPassword（同包会冲突）。 */
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

/* 账号不存在时用的假口令材料：进程内固定、长度同真实值，保证 PBKDF2 输入规模一致。 */
public let DUMMY_PW_SALT: String = "00000000000000000000000000000000"
public let DUMMY_PW_HASH: String = "0000000000000000000000000000000000000000000000000000000000000000"

/*
 * 本次登录该用哪组口令材料（纯函数）；账号不存在时返回假材料 + 标准迭代数，
 * 让两条路径 CPU 成本一致 —— 否则耗时差会泄露某手机号是否注册过。
 */
public func loginCreds(found: Bool, salt: String, hash: String,
                       iter: Int64): (String, String, Int64) {
    if (found) {
        return (salt, hash, iter)
    }
    return (DUMMY_PW_SALT, DUMMY_PW_HASH, PBKDF2_ITER)
}

/* 自检（不需要数据库） */

/*
 * 原语自检，返回失败项数（0 = 全通过）；serve 启动时先跑它再连库。
 * 三条公开向量是这套密码学没写错的唯一凭据。
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

    let v1 = toHexString(pbkdf2Sha256("passwd".toArray(), "salt".toArray(), 1, 64))
    check("RFC7914 向量1（iters=1, dkLen=64）",
          v1 == "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc" +
                "49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783")

    let v2 = toHexString(pbkdf2Sha256("Password".toArray(), "NaCl".toArray(), 80000, 64))
    check("RFC7914 向量2（iters=80000, dkLen=64）",
          v2 == "4ddcd8f60b98be21830cee5ef22701f9641a4418d04c0414aeff08876b34ab56" +
                "a1d425a1225833549adb841b51c9b3176a272bdebba1d078478f62b397f33c8d")

    let v3 = toHexString(pbkdf2Sha256("password".toArray(), "saltSALT".toArray(), 100000, 32))
    check("100k 对拍 .NET Rfc2898DeriveBytes",
          v3 == "5c809e359c03e25b885cf90db237fdea07be535f27a2d4064ae719b6f2996aaa")

    check("iters=0 → 空数组（fail closed）",
          pbkdf2Sha256("pw".toArray(), "salt".toArray(), 0, 32).size == 0)
    check("iters<0 → 空数组", pbkdf2Sha256("pw".toArray(), "salt".toArray(), -1, 32).size == 0)
    check("dkLen=0 → 空数组", pbkdf2Sha256("pw".toArray(), "salt".toArray(), 1000, 0).size == 0)

    let rec = newPasswordRecord("abc12345")
    check("正确口令通过", verifyPw("abc12345", rec[0], rec[1], rec[2]))
    check("错误口令拒绝", !verifyPw("abc12346", rec[0], rec[1], rec[2]))
    check("空盐拒绝", !verifyPw("abc12345", "", rec[1], rec[2]))
    check("迭代为0拒绝", !verifyPw("abc12345", rec[0], rec[1], 0))
    check("迭代次数为 100000", rec[2] == PBKDF2_ITER)
    let rec2 = newPasswordRecord("abc12345")
    check("同一口令两次的盐不同", rec[0] != rec2[0])

    check("相同串相等", constantTimeEq("abcdef", "abcdef"))
    check("不同串不等", !constantTimeEq("abcdef", "abcdeg"))
    check("长度不同不等", !constantTimeEq("abc", "abcd"))

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
