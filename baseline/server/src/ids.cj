package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * ID、令牌与随机口令。
 *
 * 说明：std.random 只确认了 Random().nextBytes(n)。这里一律以字节为随机源，
 * 再自行折算，避免依赖未验证的 nextUInt64 之类入口。
 */

import std.collection.*
import std.random.*
import stdx.encoding.hex.*

/*
 * 取 n 字节随机数。
 * 注意 std.random 的 nextBytes 是**填充已有缓冲区**的形态
 * （轻舟 requestid.cj 也是这么用的），不要写成 nextBytes(n) 取返回值。
 */
public func randBytes(n: Int64): Array<UInt8> {
    let r = Random()
    let buf = Array<UInt8>(n, repeat: 0)
    r.nextBytes(buf)
    return buf
}

/* 随机十六进制串。令牌与盐都用它。 */
public func randHex(nbytes: Int64): String {
    return toHexString(randBytes(nbytes))
}

/*
 * [0, bound) 的均匀随机数。
 * 用 7 字节（56 位）拼正整数，保证乘法不溢出（Cangjie 溢出会抛异常）。
 */
public func randBelow(bound: Int64): Int64 {
    if (bound <= 1) {
        return 0
    }
    let b = Random().nextBytes(7)
    var v: Int64 = 0
    var i: Int64 = 0
    while (i < 7) {
        v = v * 256 + Int64(b[i])
        i += 1
    }
    return v % bound
}

/* 会话令牌：32 字节 = 64 个十六进制字符。 */
public func newToken(): String {
    return randHex(32)
}

/*
 * 易读口令字母表：去掉了 0/O、1/I/L、2/Z、5/S、8/B 这类易混字符。
 * 注册口令与临时密码要能被人**在微信里口头传达**，可读性是功能要求，不是美化。
 */
public let CODE_ALPHABET: String = "ACDEFGHJKLMNPQRTUVWXY34679"

public func randCode(length: Int64): String {
    let alpha = CODE_ALPHABET.toArray()
    let out = ArrayList<UInt8>()
    var i: Int64 = 0
    while (i < length) {
        out.add(alpha[randBelow(alpha.size)])
        i += 1
    }
    return String.fromUtf8(out.toArray())
}

/* 社团注册口令：6 位。 */
public func newRegisterCode(): String {
    return randCode(6)
}

/* 重置密码用的临时密码：8 位，只在重置那一次返回。 */
public func newTempPassword(): String {
    return randCode(8)
}
