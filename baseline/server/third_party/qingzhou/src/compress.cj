package qingzhou

import std.io.*
import std.collection.*
import stdx.compress.zlib.*

/*
 * SPDX-License-Identifier: MIT
 *
 * gzip 压缩中间件。
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * gzip 压缩。
 *
 * 底层：stdx.compress.zlib 是流式 API（CompressOutputStream），无一次性
 * 函数。这里自实现一个内存 OutputStream（MemOut）收集压缩字节。
 *
 * 用法：
 *   app.use(compress(CompressOptions()))   // 对所有文本类响应压缩
 */

/* 内存输出流：收集写入字节到 ArrayList。 */
class MemOut <: OutputStream {
    private let buf: ArrayList<UInt8> = ArrayList<UInt8>()

    init() {}

    public func write(buffer: Array<UInt8>): Unit {
        for (b in buffer) {
            buf.add(b)
        }
    }

    public func toArray(): Array<UInt8> {
        return buf.toArray()
    }
}

/* gzip 压缩字节数组（空输入返回空数组）。 */
public func gzipCompress(bytes: Array<UInt8>): Array<UInt8> {
    if (bytes.size == 0) {
        return Array<UInt8>()
    }
    let mem = MemOut()
    let gz = CompressOutputStream(mem, wrap: GzipFormat)
    gz.write(bytes)
    gz.flush()
    gz.close()
    return mem.toArray()
}

/* compress 中间件选项。 */
public class CompressOptions {
    /* 小于此字节数的响应不压缩（避免小响应膨胀）。 */
    public var threshold: Int64 = 1024

    public init() {}
}

/*
 * compress 中间件：对「客户端接受 gzip + 文本类 Content-Type + 超过阈值」
 * 的响应做 gzip 压缩。只有当压缩结果确实更小才替换 body（避免膨胀）。
 */
public func compress(opts: CompressOptions): Middleware {
    return { ctx: Context, next: () -> Unit =>
        next()

        // 1. 客户端接受 gzip？
        var accepts = false
        match (ctx.requestHeader("Accept-Encoding")) {
            case Some(ae) => accepts = ae.toAsciiLower().contains("gzip")
            case None => ()
        }
        if (!accepts) {
            return
        }

        // 2. 已经是压缩过的（避免二次压缩）？
        match (ctx._peekHeaders().get("content-encoding")) {
            case Some(_) => return
            case None => ()
        }

        // 3. 文本类 Content-Type？
        var ct = ""
        match (ctx._peekHeaders().get("content-type")) {
            case Some(v) => ct = v
            case None => ()
        }
        if (!isCompressibleType(ct)) {
            return
        }

        // 4. body 大小超过阈值？
        let original = ctx._bodyAsBytes()
        if (original.size < opts.threshold) {
            return
        }

        // 压缩，只有更小才替换。
        let gz = gzipCompress(original)
        if (gz.size > 0 && gz.size < original.size) {
            ctx.body(gz)
            ctx.header("content-encoding", "gzip")
            ctx.header("vary", "Accept-Encoding")
        }
    }
}

/* 判断 Content-Type 是否值得压缩（文本类）。 */
func isCompressibleType(ct: String): Bool {
    let t = ct.toAsciiLower()
    if (t.startsWith("text/")) {
        return true
    }
    if (t.startsWith("application/json")) {
        return true
    }
    if (t.startsWith("application/javascript")) {
        return true
    }
    if (t.startsWith("application/xml")) {
        return true
    }
    if (t.startsWith("image/svg")) {
        return true
    }
    return false
}
