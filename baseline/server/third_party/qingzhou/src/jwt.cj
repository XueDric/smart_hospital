package qingzhou

import std.collection.*
import std.time.*
import stdx.encoding.base64.*
import stdx.encoding.json.*
import stdx.crypto.digest.*

/*
 * SPDX-License-Identifier: MIT
 *
 * 标准 JWT（RFC 7519，HS256）。
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * 产出与外部 JWT 生态兼容的标准三段式 token：
 *   base64url(header) . base64url(payload) . base64url(signature)
 *
 *   header  = {"alg":"HS256","typ":"JWT"}
 *   payload = {"sub":"<userId>","iat":<now秒>,"exp":<now+ttl秒>}
 *   sig     = HMAC-SHA256(secret, header + "." + payload) 的二进制，再 base64url
 *
 * 相比旧版 "userId.sig"（hex 签名、无过期）：
 *   - 标准 base64url 编码，可被网关 / 其他语言服务直接校验
 *   - 带 iat / exp claim，token 有过期时间，避免永久有效
 *   - 校验时拒绝过期 token（默认 30 秒时钟偏移 leeway）
 *
 * 依赖：
 *   - stdx.encoding.base64.toBase64String / fromBase64String（标准 base64）
 *   - std.time.DateTime.nowUTC().toUnixTimeStamp().toSeconds()（当前 UTC 秒）
 *   - stdx.crypto.digest.HMAC + SHA256（复用 security.cj 同一底层）
 */

/* JWT 载荷里提取出的关键 claim。 */
class JwtClaims {
    public let sub: String
    public let exp: Int64
    public init(sub: String, exp: Int64) {
        this.sub = sub
        this.exp = exp
    }
}

/*
 * base64url 编码：标准 base64 -> 替换 '+' 为 '-'、'/' 为 '_'，去掉末尾 '='。
 */
func base64UrlEncode(data: Array<UInt8>): String {
    let b64 = toBase64String(data)
    let out = ArrayList<UInt8>()
    var i: Int64 = 0
    while (i < b64.size) {
        let c = b64[i]
        if (c == UInt8(0x2B)) {          // '+'
            out.add(UInt8(0x2D))         // '-'
        } else if (c == UInt8(0x2F)) {   // '/'
            out.add(UInt8(0x5F))         // '_'
        } else if (c != UInt8(0x3D)) {   // 去掉 '='
            out.add(c)
        }
        i += 1
    }
    return String.fromUtf8(out.toArray())
}

/*
 * base64url 解码：替换 '-'->'+'、'_'->'/'，补 '=' padding 到 4 的倍数，
 * 再用标准 base64 解码。非法输入返回 None。
 */
func base64UrlDecode(s: String): ?String {
    let out = ArrayList<UInt8>()
    var i: Int64 = 0
    while (i < s.size) {
        let c = s[i]
        if (c == UInt8(0x2D)) {          // '-'
            out.add(UInt8(0x2B))         // '+'
        } else if (c == UInt8(0x5F)) {   // '_'
            out.add(UInt8(0x2F))         // '/'
        } else {
            out.add(c)
        }
        i += 1
    }
    // 补 '=' 到 4 的倍数
    let rem = out.size % 4
    if (rem != 0) {
        var j: Int64 = 0
        while (j < 4 - rem) {
            out.add(UInt8(0x3D))
            j += 1
        }
    }
    let stdB64 = String.fromUtf8(out.toArray())
    match (fromBase64String(stdB64)) {
        case Some(bytes) => return Some(String.fromUtf8(bytes))
        case None => return None
    }
}

/* 解析 payload JSON，取出 sub 与 exp；解析失败/缺字段返回 None。 */
func parseJwtClaims(payloadJson: String): ?JwtClaims {
    try {
        let obj = JsonValue.fromStr(payloadJson).asObject()
        match (jsonGetStr(obj, "sub")) {
            case Some(u) =>
                match (jsonGetInt64(obj, "exp")) {
                    case Some(e) => return Some(JwtClaims(u, e))
                    case None => return None
                }
            case None => return None
        }
    } catch (e: Exception) {
        return None
    }
    return None
}

/* 当前 UTC 秒（用于 iat / exp）。 */
func nowUtcSeconds(): Int64 {
    return DateTime.nowUTC().toUnixTimeStamp().toSeconds()
}

/* 过期校验的时钟偏移容忍（秒）：容忍客户端/服务端轻微时钟偏差。 */
func jwtLeewaySeconds(): Int64 {
    return 30
}

/*
 * 签发标准 JWT。userId 为业务主体标识（如用户数字 id），
 * ttlSeconds 为有效时长（秒）。返回三段式 base64url token。
 */
public func jwtIssue(userId: String, secret: String, ttlSeconds: Int64): String {
    let now = nowUtcSeconds()
    let header = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}"
    let payload = "{\"sub\":\"${userId}\",\"iat\":${now},\"exp\":${now + ttlSeconds}}"
    let h = base64UrlEncode(header.toArray())
    let p = base64UrlEncode(payload.toArray())
    let signingInput = h + "." + p
    let mac = HMAC(secret.toArray(), { => SHA256() })
    mac.write(signingInput.toArray())
    let sig = base64UrlEncode(mac.finish())
    return signingInput + "." + sig
}

/*
 * 校验标准 JWT。三步：
 *   1) 拆三段，重算 HMAC-SHA256 签名比对（防篡改）
 *   2) 解码 payload 提取 sub / exp
 *   3) 检查 exp 是否已过期（允许 30 秒时钟偏移 leeway）
 * 全部通过返回 sub（userId），否则 None。
 */
public func jwtVerify(token: String, secret: String): ?String {
    let parts = token.split(".", 3, removeEmpty: false)
    if (parts.size != 3) {
        return None
    }
    let h = parts[0]
    let p = parts[1]
    let s = parts[2]
    // 重算签名
    let mac = HMAC(secret.toArray(), { => SHA256() })
    mac.write((h + "." + p).toArray())
    let expected = base64UrlEncode(mac.finish())
    if (expected != s) {
        return None
    }
    // 解码 payload 检查 exp
    match (base64UrlDecode(p)) {
        case Some(payloadJson) =>
            match (parseJwtClaims(payloadJson)) {
                case Some(claims) =>
                    let now = nowUtcSeconds()
                    if (now >= claims.exp - jwtLeewaySeconds()) {
                        return None   // 已过期
                    }
                    return Some(claims.sub)
                case None => return None
            }
        case None => return None
    }
}
