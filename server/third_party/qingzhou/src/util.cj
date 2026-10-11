package qingzhou

import std.convert.*

/*
 * SPDX-License-Identifier: MIT
 *
 * 内置解析器。
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * `try { Some(Int64.parse(s)) } catch { None }` 里裸写
 * `None` 会报 "generic type should be used with type argument"，迫使每个
 * 使用者都抽一个返回类型明确的 helper。这里收编为框架内置解析器。
 */

/* 安全解析 Int64，失败返回 None。 */
public func parseInt64OrNone(s: String): ?Int64 {
    try {
        return Some(Int64.parse(s))
    } catch (e: Exception) {
        return None
    }
}

/* 解析 Int64，失败返回默认值。 */
public func parseInt64Or(s: String, default_: Int64): Int64 {
    return match (parseInt64OrNone(s)) {
        case Some(n) => n
        case None => default_
    }
}

/* 安全解析 UInt16（端口号等），失败返回 None。 */
public func parseUInt16OrNone(s: String): ?UInt16 {
    try {
        return Some(UInt16.parse(s))
    } catch (e: Exception) {
        return None
    }
}

/* 解析 UInt16，失败返回默认值。 */
public func parseUInt16Or(s: String, default_: UInt16): UInt16 {
    return match (parseUInt16OrNone(s)) {
        case Some(n) => n
        case None => default_
    }
}

/* 安全解析 Float64，失败返回 None。 */
public func parseFloat64OrNone(s: String): ?Float64 {
    try {
        return Some(Float64.parse(s))
    } catch (e: Exception) {
        return None
    }
}

/* 解析 Float64，失败返回默认值。 */
public func parseFloat64Or(s: String, default_: Float64): Float64 {
    return match (parseFloat64OrNone(s)) {
        case Some(n) => n
        case None => default_
    }
}

/* 安全解析 Bool（接受 "true"/"false"，大小写不敏感），失败返回 None。 */
public func parseBoolOrNone(s: String): ?Bool {
    let t = s.trimAscii().toAsciiLower()
    if (t == "true") {
        return Some(true)
    }
    if (t == "false") {
        return Some(false)
    }
    return None
}
