package qingzhou

import std.collection.*
import std.random.*
import std.convert.*
import stdx.crypto.digest.*

/*
 * SPDX-License-Identifier: MIT
 *
 * 安全原语（密码哈希 + 签名 cookie）。
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * 薄弱点：
 *   1) 无密码哈希 helper（此前只能裸 sha256，无盐）
 *   2) 无签名 cookie / session（此前只有明文 cookie get/set）
 *
 * 底层能力（stdx 1.0.5.1 crypto.digest）：
 *   - SHA256:  write(bytes) + finish() -> Array<UInt8>
 *   - HMAC:    HMAC(keyBytes, { => SHA256() }) + write + finish
 */

/* ===================== 通用 hex ===================== */

func toHex(bytes: Array<UInt8>): String {
    let hex = "0123456789abcdef"
    let sb = StringBuilder()
    for (b in bytes) {
        let hi = Int64(b) >> 4
        let lo = Int64(b) & 0x0f
        sb.append(hex[hi .. hi + 1])
        sb.append(hex[lo .. lo + 1])
    }
    return sb.toString()
}

func sha256Hex(s: String): String {
    let sha = SHA256()
    sha.write(s.toArray())
    return toHex(sha.finish())
}

/* ===================== 密码哈希（PBKDF2 风格） ===================== */

/*
 * 迭代哈希：h = sha256(salt + password)，重复 rounds 次
 * h = sha256(h + salt + password)。
 * 这是 PBKDF2 的简化（无 HMAC、无 block 拼接），对 demo/轻量场景够用；
 * 生产建议 rounds >= 100000 或换 stdx 后续提供的 scrypt/bcrypt。
 */
func computePasswordHash(password: String, salt: String, rounds: Int64): String {
    var h = sha256Hex(salt + password)
    var i: Int64 = 1
    while (i < rounds) {
        h = sha256Hex(h + salt + password)
        i += 1
    }
    return h
}

/*
 * 生成自描述哈希：返回 "salt$rounds$hashHex"。
 * salt 建议用随机字节 hex（可用 randomHex 生成）。
 */
public func hashPassword(password: String, salt: String, rounds: Int64): String {
    return salt + "$" + rounds.toString() + "$" + computePasswordHash(password, salt, rounds)
}

/*
 * 校验密码。stored 为 hashPassword 的返回值；格式不符返回 false。
 */
public func verifyPassword(password: String, stored: String): Bool {
    let parts = stored.split("$", 3, removeEmpty: false)
    if (parts.size != 3) {
        return false
    }
    let salt = parts[0]
    let rounds = try { Int64.parse(parts[1]) } catch (e: Exception) { Int64(0) }
    if (rounds <= 0) {
        return false
    }
    let expected = parts[2]
    let actual = computePasswordHash(password, salt, rounds)
    return actual == expected
}

/* ===================== 签名 cookie（HMAC-SHA256） ===================== */

/*
 * 签名一个值：返回 "value.sig"，其中 sig = HMAC-SHA256(secret, value) 的
 * hex。value 需不含 "."（或调用方保证），verifySigned 用最后一个 "." 分割。
 */
public func signValue(value: String, secret: String): String {
    let mac = HMAC(secret.toArray(), { => SHA256() })
    mac.write(value.toArray())
    let sig = toHex(mac.finish())
    return value + "." + sig
}

/*
 * 校验签名值：签名匹配返回原始 value，否则返回 None。
 */
public func verifySigned(signed: String, secret: String): ?String {
    let idx = signed.lastIndexOf(".")
    match (idx) {
        case Some(i) =>
            if (i <= 0 || i >= signed.size - 1) {
                return None
            }
            let value = signed[0..i]
            let recomputed = signValue(value, secret)
            if (recomputed == signed) {
                return Some(value)
            }
            return None
        case None => return None
    }
}

/* ===================== 随机字节 ===================== */

/*
 * 生成 n 字节随机数据的 hex 字符串（用作 salt / session token）。
 */
public func randomHex(nBytes: Int64): String {
    let r = Random()
    let buf = Array<UInt8>(nBytes, { _ => UInt8(0) })
    r.nextBytes(buf)
    return toHex(buf)
}

/* ===================== 敏感信息脱敏 ===================== */

/*
 * 默认敏感字段名（不区分大小写匹配）。命中后其值被替换为 *。
 * 覆盖 HTTP 头与常见的 query / JSON 字段两种形态。
 */
let REDACT_KEYS: Array<String> = [
    "authorization", "api_key", "apikey", "api-key", "x-api-key",
    "access_token", "refresh_token", "id_token", "token",
    "password", "passwd", "secret", "client_secret", "private_key"
]

/*
 * 敏感信息脱敏：把 key 对应的值替换为 *，其余原样保留。
 *
 * 覆盖形态：
 *   Authorization: Bearer abc123        -> Authorization: *
 *   "api_key": "sk-xxxx"                -> "api_key": "*"
 *   ?token=abc&page=1                   -> ?token=*&page=1
 *   password=hunter2                    -> password=*
 *
 * 用途：日志、审计、错误信息输出前统一过一遍，保证「密钥永不入日志」。
 * 注意它不是加密——只是遮蔽，切勿把脱敏后的文本当成安全存储手段。
 */
public func redact(text: String): String {
    var bytes = text.toArray()
    for (key in REDACT_KEYS) {
        bytes = redactKeyBytes(bytes, key)
    }
    return String.fromUtf8(bytes)
}

/* 遮蔽单个 key 的所有出现（字节级，避免多字节 UTF-8 被切断）。 */
func redactKeyBytes(bytes: Array<UInt8>, key: String): Array<UInt8> {
    let kb = key.toArray()
    let klen = kb.size
    let out = ArrayList<UInt8>()
    var i: Int64 = 0
    while (i < bytes.size) {
        var matched = false
        if (i + klen <= bytes.size) {
            let boundaryOk = (i == 0) || !isWordByte(bytes[i - 1])
            if (boundaryOk) {
                matched = true
                var j: Int64 = 0
                while (j < klen) {
                    if (asciiLowerByte(bytes[i + j]) != asciiLowerByte(kb[j])) {
                        matched = false
                        break
                    }
                    j += 1
                }
            }
        }
        if (matched) {
            match (findSepBytes(bytes, i + klen)) {
                case Some(sepIdx) =>
                    match (valueSpanBytes(bytes, sepIdx + 1)) {
                        case Some(span) =>
                            var k = i
                            while (k < span[0]) {
                                out.add(bytes[k])
                                k += 1
                            }
                            out.add(42)   // '*'
                            out.add(42)
                            out.add(42)
                            i = span[1]
                            continue
                        case None => ()
                    }
                case None => ()
            }
        }
        out.add(bytes[i])
        i += 1
    }
    return out.toArray()
}

/* ASCII 小写化（仅处理 A-Z）。 */
func asciiLowerByte(b: UInt8): UInt8 {
    if (b >= 65 && b <= 90) {
        return UInt8(Int64(b) + 32)
    }
    return b
}

/* 是否是「词字符」字节（用于 key 的左边界判定，避免匹配 myapi_key 的片段）。 */
func isWordByte(b: UInt8): Bool {
    let isDigit = b >= 48 && b <= 57
    let isUpper = b >= 65 && b <= 90
    let isLower = b >= 97 && b <= 122
    let isUnderscore = b == 95
    return isDigit || isUpper || isLower || isUnderscore
}

/* 从 from 起找 key 与值之间的分隔符 : (58) 或 = (61)，中间允许引号与空格。 */
func findSepBytes(bytes: Array<UInt8>, from: Int64): ?Int64 {
    var i = from
    while (i < bytes.size) {
        let b = bytes[i]
        if (b == 58 || b == 61) {
            return Some(i)
        }
        if (b == 32 || b == 34 || b == 39) {   // 空格 / " / '
            i += 1
            continue
        }
        return None
    }
    return None
}

/*
 * 定位值范围 [start, end)。值可被引号包围（含引号一起遮蔽）或为裸串。
 * 裸串终止于 , ; & 换行 制表 } —— 空格不终止：Authorization 头的常见
 * 形态是 "Bearer <token>"，若被空格截断则 token 会漏出日志。安全侧宁可
 * 多遮蔽，故此处偏保守。
 */
func valueSpanBytes(bytes: Array<UInt8>, from: Int64): ?(Int64, Int64) {
    var i = from
    while (i < bytes.size && bytes[i] == 32) {
        i += 1
    }
    if (i >= bytes.size) {
        return None
    }
    let first = bytes[i]
    if (first == 34 || first == 39) {      // " 或 '
        var j = i + 1
        while (j < bytes.size) {
            let b = bytes[j]
            if (b == 92) {                 // 反斜杠转义
                j += 2
                continue
            }
            if (b == first) {
                return Some((i, j + 1))
            }
            j += 1
        }
        return Some((i, bytes.size))
    }
    var j = i
    while (j < bytes.size) {
        let b = bytes[j]
        if (b == 44 || b == 59 || b == 38 || b == 10 || b == 13 || b == 9 || b == 125) {
            break
        }
        j += 1
    }
    if (j == i) {
        return None
    }
    return Some((i, j))
}
