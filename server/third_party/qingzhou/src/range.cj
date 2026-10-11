package qingzhou

import std.collection.*

/*
 * SPDX-License-Identifier: MIT
 *
 * HTTP Range request parser (RFC 7233 subset).
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * Supported:
 *   bytes=0-499      -> start=0, end=499
 *   bytes=500-       -> start=500, end=fileSize-1   (open upper bound)
 *   bytes=-500       -> start=fileSize-500, end=fileSize-1   (suffix)
 *   bytes=0-         -> start=0, end=fileSize-1     (full file from 0)
 *
 * Not supported in  (would normally yield 200 + multipart):
 *   bytes=0-100,200-300   (multi-range)
 *
 * Outcomes:
 *   - Parsed + satisfiable    -> Satisfiable(RangeSpec)
 *   - Parsed + out of bounds  -> Unsatisfiable (respond 416)
 *   - Unparseable / multi     -> Malformed        (respond 200, ignore Range)
 *
 * The `Malformed` bucket exists so the caller can decide between "treat
 * the request as if Range wasn't sent" (200 full body) and "send 416".
 * RFC 7233 section 3.1: an unparseable Range header MUST be ignored (treated
 * as if absent), not rejected. So Malformed becomes "fall back to full
 * body", while Unsatisfiable becomes "respond 416".
 */

/*
 * Parsed byte range. Both bounds inclusive, 0-indexed.
 *   start in [0, fileSize)
 *   end   in [start, fileSize - 1]
 */
public class RangeSpec {
    public let start: Int64
    public let end: Int64
    public init(start: Int64, end: Int64) {
        this.start = start
        this.end = end
    }

    /*
     * Byte count to return. Always at least 1 for a satisfiable range
     * (the caller never hands us start > end).
     */
    public func length(): Int64 {
        return end - start + 1
    }
}

public enum RangeResult {
    | Satisfiable(RangeSpec)
    | Unsatisfiable
    | Malformed
}

extend RangeResult <: Equatable<RangeResult> {
    public operator func ==(right: RangeResult): Bool {
        match (this) {
            case Satisfiable(a) =>
                match (right) {
                    case Satisfiable(b) => a.start == b.start && a.end == b.end
                    case _ => false
                }
            case Unsatisfiable =>
                match (right) {
                    case Unsatisfiable => true
                    case _ => false
                }
            case Malformed =>
                match (right) {
                    case Malformed => true
                    case _ => false
                }
        }
    }
    public operator func !=(right: RangeResult): Bool {
        return !(this == right)
    }
}

/*
 * Parse a Range header value into one of the three outcomes.
 *
 * `header` is the value of the Range header WITH the "bytes=" unit
 * prefix already stripped (the caller removes it once; if there is no
 * such prefix we treat the value as malformed).
 *
 * `fileSize` is the total size in bytes of the resource; ranges are
 * clipped/satisfied against it.
 *
 * Spec: RFC 7233 section 2.1. Only single ranges are supported.
 */
public func parseRange(header: String, fileSize: Int64): RangeResult {
    if (fileSize <= 0) {
        // Per RFC 7233 section 4.4 a 0-byte resource cannot satisfy
        // any range; 416 is the canonical answer.
        return RangeResult.Unsatisfiable
    }

    // Split off the unit ("bytes="). We only honour "bytes".
    let unitSep = header.indexOf("=")
    match (unitSep) {
        case None => return RangeResult.Malformed
        case Some(eq) =>
            // The substring before '=' is the range-unit specifier.
            let unit = header[0..eq].trimAscii().toAsciiLower()
            if (unit != "bytes") {
                return RangeResult.Malformed
            }
            let spec = header[(eq + 1)..].trimAscii()
            // Reject empty or multi-range (any comma => multi-range).
            if (spec.size == 0) {
                return RangeResult.Malformed
            }
            if (spec.indexOf(",").isSome()) {
                return RangeResult.Malformed
            }
            // The spec is start "-" end   (end may be empty)
            let dash = spec.indexOf("-")
            match (dash) {
                case None => return RangeResult.Malformed
                case Some(d) =>
                    let sPart = spec[0..d]
                    let ePart = spec[(d + 1)..]
                    // Suffix form: "-N" means last N bytes.
                    if (sPart.size == 0) {
                        if (ePart.size == 0) {
                            return RangeResult.Malformed
                        }
                        let n = match (parseInt64(ePart)) {
                            case Some(v) => v
                            case None => return RangeResult.Malformed
                        }
                        if (n <= 0) {
                            return RangeResult.Malformed
                        }
                        let realN = if (n > fileSize) { fileSize } else { n }
                        let startPos = fileSize - realN
                        return RangeResult.Satisfiable(RangeSpec(startPos, fileSize - 1))
                    }
                    // Open-ended: "N-" means N to EOF.
                    if (ePart.size == 0) {
                        let startPos = match (parseInt64(sPart)) {
                            case Some(v) => v
                            case None => return RangeResult.Malformed
                        }
                        if (startPos < 0 || startPos >= fileSize) {
                            return RangeResult.Unsatisfiable
                        }
                        return RangeResult.Satisfiable(RangeSpec(startPos, fileSize - 1))
                    }
                    // Closed form: "N-M".
                    let startPos = match (parseInt64(sPart)) {
                        case Some(v) => v
                        case None => return RangeResult.Malformed
                    }
                    let endPos = match (parseInt64(ePart)) {
                        case Some(v) => v
                        case None => return RangeResult.Malformed
                    }
                    if (startPos < 0 || endPos < startPos) {
                        return RangeResult.Malformed
                    }
                    if (startPos >= fileSize) {
                        return RangeResult.Unsatisfiable
                    }
                    // Cap end at fileSize - 1 (RFC 7233 section 2.1: server MAY).
                    let cappedEnd = if (endPos >= fileSize) { fileSize - 1 } else { endPos }
                    return RangeResult.Satisfiable(RangeSpec(startPos, cappedEnd))
            }
    }
}

/*
 * Format a "Content-Range: bytes start-end/size" header value.
 * Used by 206 partial responses.
 */
public func formatContentRange(spec: RangeSpec, size: Int64): String {
    return "bytes " + spec.start.toString() + "-" + spec.end.toString() + "/" + size.toString()
}

/*
 * Format "Content-Range" header for 416 responses. Per RFC 7233
 * part 4.4 the form is `bytes STAR/size` (literal asterisk).
 */
public func formatUnsatisfiableContentRange(size: Int64): String {
    return "bytes */" + size.toString()
}

/*
 * Hand-rolled Int64 parser. Accepts an optional leading '-' for
 * negative numbers; rejects anything with non-digit characters in the
 * body (so "12abc" fails). stdx doesn't expose a free int64 parser on
 * cangjie 1.0 (patch 5), and std.convert is fine but we want to
 * fail-soft (so "12abc" returns None instead of throwing).
 */
func parseInt64(s: String): ?Int64 {
    if (s.size == 0) {
        return None
    }
    var i: Int64 = 0
    var neg: Bool = false
    if (s[0] == UInt8(0x2D)) {
        neg = true
        i = 1
        if (s.size == 1) {
            return None
        }
    }
    var v: Int64 = 0
    while (i < s.size) {
        let c = s[i]
        if (c < UInt8(0x30) || c > UInt8(0x39)) {
            return None
        }
        v = v * 10 + (Int64(c) - 0x30)
        i += 1
    }
    return if (neg) { -v } else { v }
}

/* ===================== 多 Range ===================== */

/*
 * 多 Range 解析结果。Satisfiable 携带至少一个（可能是多个）RangeSpec。
 */
public enum RangesResult {
    | Satisfiable(Array<RangeSpec>)
    | Unsatisfiable
    | Malformed
}

extend RangesResult <: Equatable<RangesResult> {
    public operator func ==(right: RangesResult): Bool {
        match (this) {
            case Satisfiable(a) =>
                match (right) {
                    case Satisfiable(b) =>
                        if (a.size != b.size) {
                            return false
                        }
                        var i: Int64 = 0
                        while (i < a.size) {
                            if (a[i].start != b[i].start || a[i].end != b[i].end) {
                                return false
                            }
                            i += 1
                        }
                        return true
                    case _ => false
                }
            case Unsatisfiable =>
                match (right) {
                    case Unsatisfiable => true
                    case _ => false
                }
            case Malformed =>
                match (right) {
                    case Malformed => true
                    case _ => false
                }
        }
    }
    public operator func !=(right: RangesResult): Bool {
        return !(this == right)
    }
}

/*
 * 解析可能包含多个 range 的 Range 头（逗号分隔）。
 *
 * 语义（RFC 7233 简化）：
 *   - 任一片段无法解析  -> Malformed（调用方忽略 Range，回 200）
 *   - 任一片段越界      -> Unsatisfiable（调用方回 416）
 *   - 否则              -> Satisfiable(列表)，1 个走单 range，多个走 multipart
 */
public func parseRanges(header: String, fileSize: Int64): RangesResult {
    if (fileSize <= 0) {
        return RangesResult.Unsatisfiable
    }
    let unitSep = header.indexOf("=")
    match (unitSep) {
        case None => return RangesResult.Malformed
        case Some(eq) =>
            let unit = header[0..eq].trimAscii().toAsciiLower()
            if (unit != "bytes") {
                return RangesResult.Malformed
            }
            let spec = header[(eq + 1)..].trimAscii()
            if (spec.size == 0) {
                return RangesResult.Malformed
            }
            let parts = spec.split(",", -1, removeEmpty: true)
            let out = ArrayList<RangeSpec>()
            for (p in parts) {
                // 复用 parseRange（单 range 逻辑），补回 "bytes=" 前缀。
                match (parseRange("bytes=" + p.trimAscii(), fileSize)) {
                    case RangeResult.Satisfiable(r) => out.add(r)
                    case RangeResult.Unsatisfiable => return RangesResult.Unsatisfiable
                    case RangeResult.Malformed => return RangesResult.Malformed
                }
            }
            if (out.size == 0) {
                return RangesResult.Unsatisfiable
            }
            return RangesResult.Satisfiable(out.toArray())
    }
}

/*
 * 构造 multipart/byteranges 响应体（RFC 7233 4.1）。
 * 每个 part 包含 Content-Type + Content-Range 头 + 对应字节切片，
 * 最终以 `--boundary--` 结束。
 */
public func formatMultipartBody(specs: Array<RangeSpec>, bytes: Array<UInt8>, mime: String, boundary: String, fileSize: Int64): Array<UInt8> {
    let out = ArrayList<UInt8>()
    for (spec in specs) {
        let header = "--" + boundary + "\r\n" +
            "Content-Type: " + mime + "\r\n" +
            "Content-Range: " + formatContentRange(spec, fileSize) + "\r\n\r\n"
        for (b in header.toArray()) {
            out.add(b)
        }
        let slice = sliceBytes(bytes, spec.start, spec.end)
        for (b in slice) {
            out.add(b)
        }
        out.add(UInt8(0x0D))  // \r
        out.add(UInt8(0x0A))  // \n
    }
    let tail = "--" + boundary + "--\r\n"
    for (b in tail.toArray()) {
        out.add(b)
    }
    return out.toArray()
}