package qingzhou

import std.collection.*

/*
 * SPDX-License-Identifier: MIT
 *
 * multipart/form-data 解析。
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * multipart/form-data 解析与上传处理。
 * stdx 无 multipart 包，这里手写 boundary 解析（RFC 7578 子集）。
 *
 * 支持文本字段与二进制文件字段。用法：
 *   app.use(multipart())     // 解析 multipart body 到 ctx
 *   // handler 里：
 *   multipartField(ctx, "title")    // -> ?String
 *   multipartFile(ctx, "upload")    // -> ?MultipartPart
 */

/* 单个 multipart part（字段或文件）。 */
public class MultipartPart {
    public var name: String = ""
    public var filename: String = ""
    public var contentType: String = ""
    public var data: Array<UInt8> = Array<UInt8>()

    init() {}

    /* 文本值（data 按 UTF-8 解码）。 */
    public func text(): String {
        return String.fromUtf8(data)
    }
}

/* 从 Content-Type 头提取 boundary（去掉可选引号）。 */
func extractBoundary(contentType: String): String {
    for (p in contentType.split(";", -1, removeEmpty: false)) {
        let t = p.trimAscii()
        if (t.startsWith("boundary=")) {
            let v = t["boundary=".size..].trimAscii()
            if (v.size >= 2 && v[0] == UInt8(0x22) && v[v.size - 1] == UInt8(0x22)) {
                return v[1..(v.size - 1)]
            }
            return v
        }
    }
    return ""
}

/* 从 Content-Disposition 提取 name 或 filename 属性。 */
func extractAttr(disposition: String, attr: String): ?String {
    for (p in disposition.split(";", -1, removeEmpty: false)) {
        let t = p.trimAscii()
        if (t.startsWith(attr + "=")) {
            let v = t[(attr.size + 1)..].trimAscii()
            if (v.size >= 2 && v[0] == UInt8(0x22) && v[v.size - 1] == UInt8(0x22)) {
                return Some(v[1..(v.size - 1)])
            }
            return Some(v)
        }
    }
    return None
}

/* 解析 part 头部块（每行 "Name: value"）。 */
func parsePartHeaders(block: String, part: MultipartPart): Unit {
    for (line in block.split("\r\n", -1, removeEmpty: true)) {
        let kv = line.split(":", 2, removeEmpty: false)
        if (kv.size < 2) {
            continue
        }
        let name = kv[0].trimAscii().toAsciiLower()
        let value = kv[1].trimAscii()
        if (name == "content-disposition") {
            match (extractAttr(value, "name")) {
                case Some(v) => part.name = v
                case None => ()
            }
            match (extractAttr(value, "filename")) {
                case Some(v) => part.filename = v
                case None => ()
            }
        } else if (name == "content-type") {
            part.contentType = value
        }
    }
}

/*
 * 字节序列朴素搜索：在 hay 中从 from 起找 needle 首次出现位置，找不到返回 -1。
 * multipart 字节级解析的底层辅助（body 可能含任意字节，不能走 String）。
 */
func indexOfBytes(hay: Array<UInt8>, needle: Array<UInt8>, from: Int64): Int64 {
    if (needle.size == 0 || hay.size < needle.size) {
        return -1
    }
    let last = hay.size - needle.size
    var i = from
    while (i <= last) {
        var j: Int64 = 0
        var isMatch = true
        while (j < needle.size) {
            if (hay[i + j] != needle[j]) {
                isMatch = false
                break
            }
            j += 1
        }
        if (isMatch) {
            return i
        }
        i += 1
    }
    return -1
}

/*
 * 解析 multipart body。返回 part 列表（字段/文件）。
 * 文本字段可直接 .text()；文件字段用 .data（原始字节）。
 *
 * 字节级解析。旧实现先把整个 body 经
 * String.fromUtf8 转字符串再 split，二进制文件（PNG/ZIP 等非 UTF-8
 * 载荷）会因非法序列抛异常（整个请求 500）或被替换损坏。现改为
 * 直接在字节数组上搜 boundary：头部块（ASCII 安全）才转字符串，
 * 内容保持原始字节 —— 二进制文件上传不再损坏。
 */
public func parseMultipart(body: Array<UInt8>, boundary: String): ArrayList<MultipartPart> {
    let parts = ArrayList<MultipartPart>()
    if (boundary.size == 0 || body.size == 0) {
        return parts
    }
    let delim = ("--" + boundary).toArray()
    var pos = indexOfBytes(body, delim, 0)
    while (pos >= 0) {
        // 下一个 boundary 出现位置；找不到说明后面没有更多 part
        let next = indexOfBytes(body, delim, pos + delim.size)
        if (next < 0) {
            break
        }
        // 本 part 区间：跳过 boundary 后的 "\r\n"，到 next 前的 "\r\n" 为止
        var start = pos + delim.size
        if (start + 1 < body.size && body[start] == UInt8(0x0D) && body[start + 1] == UInt8(0x0A)) {
            start += 2
        }
        var end = next - 2   // 去掉 next boundary 前的 "\r\n"
        if (end < start) {
            // 空块或结尾 "--" 标记，跳过
            pos = next
            continue
        }
        // 头部块与内容以 "\r\n\r\n" 分隔（头部是 ASCII，fromUtf8 安全）
        let sep = indexOfBytes(body, "\r\n\r\n".toArray(), start)
        if (sep >= 0 && sep + 4 <= end) {
            let headerText = String.fromUtf8(body[start..sep])
            let part = MultipartPart()
            parsePartHeaders(headerText, part)
            part.data = body[(sep + 4)..end]
            parts.add(part)
        }
        pos = next
    }
    return parts
}

/* multipart 中间件：解析 multipart/form-data body，存入 ctx。 */
public func multipart(): Middleware {
    return { ctx: Context, next: () -> Unit =>
        let ctFull = match (ctx.requestHeader("content-type")) {
            case Some(v) => v
            case None => ""
        }
        if (ctFull.toAsciiLower().startsWith("multipart/form-data")) {
            let boundary = extractBoundary(ctFull)
            let parts = parseMultipart(ctx.bodyBytes(), boundary)
            ctx.setMultipartParts(parts)
        }
        next()
    }
}

/* 读文本字段值（第一个匹配 name 的 part）。 */
public func multipartField(ctx: Context, name: String): ?String {
    for (p in ctx.multipartParts()) {
        if (p.name == name) {
            return Some(p.text())
        }
    }
    return None
}

/* 读文件字段（第一个匹配 name 且带 filename 的 part）。 */
public func multipartFile(ctx: Context, name: String): ?MultipartPart {
    for (p in ctx.multipartParts()) {
        if (p.name == name && p.filename.size > 0) {
            return Some(p)
        }
    }
    return None
}
