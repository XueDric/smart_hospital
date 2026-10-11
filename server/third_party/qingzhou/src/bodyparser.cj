package qingzhou

import std.collection.*

/*
 * SPDX-License-Identifier: MIT
 *
 * bodyParser middleware.
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * Wraps 's lazy body access (bodyJson / bodyForm / body) so that
 *   - The request body is read exactly once and cached (already true
 *     by construction in Context, but bodyParser additionally enforces
 *     a size limit up-front).
 *   - An unparseable JSON body yields 400 with a clear error rather than
 *     a silent None at bodyJson().
 *   - Unsupported Content-Types are passed through untouched, so the
 *     user can mount a separate multipart handler later.
 *
 * Recognised Content-Types (after parameter stripping):
 *   application/json                       -> ctx.bodyJson() is materialised
 *   application/x-www-form-urlencoded      -> ctx.bodyForm() is materialised
 *   text/<subtype>                         -> ctx.body() is materialised
 *   anything else                          -> no-op, downstream sees raw ctx
 *
 * Note: we deliberately do not consume the body for unrecognised types
 * so that streamable parsers (multipart, graphql-over-http-ws upgrades,
 * etc.) can still operate on ctx.request.body in the future.
 */

public class BodyParserOptions {
    /* Hard cap on the raw body in bytes. 1 MiB matches koa-bodyparser's
     * default jsonLimit when given as a string. */
    public var maxBytes: Int64 = 1024 * 1024

    /* Custom error reporter. Reassignable to plug a JSON-error format
     * or to send HTML error pages. */
    public var onError: (Context, Int64, String) -> Unit = defaultBodyParserError

    public init() {}
}

/*
 * Default error reporter: emits the framework-unified JSON shell
 * {"code":N,"message":"...","data":null}. v0.7.1（外部反馈 A-3）：旧版
 * 发 {"error":"..."}，与 api.cj 的统一响应壳不一致，客户端要写两套解析。
 */
public func defaultBodyParserError(ctx: Context, status: Int64, msg: String): Unit {
    ctx.status(status)
        .header("content-type", "application/json; charset=utf-8")
        .body("{\"code\":" + status.toString() + ",\"message\":\"" + escapeJsonString(msg) + "\",\"data\":null}")
}

/* Convenience: bodyParser() with defaults. */
public func bodyParser(): Middleware {
    return bodyParser(BodyParserOptions())
}

public func bodyParser(opts: BodyParserOptions): Middleware {
    return { ctx: Context, next: () -> Unit =>
        // 归一到小写再比较。contentType() 只去参数
        // 不改大小写，"Application/JSON" 等合法变体旧版会被当未知类型透传。
        let ct = ctx.contentType().toAsciiLower()
        // Branch on Content-Type. Unsupported types fall through so a
        // user-mounted multipart/raw handler can deal with them.
        // On an error the parser short-circuits (responds itself) and
        // does NOT call next(), so the error response is final.
        if (ct == "application/json") {
            if (!handleJson(ctx, opts)) {
                return
            }
        } else if (ct == "application/x-www-form-urlencoded") {
            if (!handleForm(ctx, opts)) {
                return
            }
        } else if (ct.startsWith("text/")) {
            if (!handleText(ctx, opts)) {
                return
            }
        }
        // Anything else: pass through. Don't pre-consume the stream.
        next()
    }
}

/* Internal: enforce size + parse JSON. Returns false when the error
 * reporter has taken over the response (caller must not call next).
 * 限额下沉到流式读取（bodyBytesCapped）——
 * 超过 maxBytes 立即停止读流并回 413，不再「全量读入内存后才判定」；
 * 也补上了非 JSON 类型（form/text）此前完全没有的流上限。 */
func handleJson(ctx: Context, opts: BodyParserOptions): Bool {
    match (ctx.bodyBytesCapped(opts.maxBytes)) {
        case None =>
            opts.onError(ctx, 413, "Request body too large")
            return false
        case Some(_) => ()
    }
    // 缓存已由 bodyBytesCapped 填充，bodyJsonError() 内部复用缓存，
    // InputStream 不会被二次消费。
    let raw = ctx._peekRawBody()
    match (ctx.bodyJsonError()) {
        case Some(_) =>
            // bodyJsonError returned Some when raw was non-empty and parsing failed.
            if (raw.size > 0) {
                opts.onError(ctx, 400, "Invalid JSON body")
                return false
            }
            // raw.size == 0 -> empty JSON body is acceptable; treat as null.
        case None => ()
    }
    return true
}

func handleForm(ctx: Context, opts: BodyParserOptions): Bool {
    match (ctx.bodyBytesCapped(opts.maxBytes)) {
        case None =>
            opts.onError(ctx, 413, "Request body too large")
            return false
        case Some(_) => ()
    }
    let m = ctx.bodyForm()
    // Discard the unused map; the side effect of populating the cache
    // is what we wanted. (m is referenced so the optimiser keeps it.)
    let _ = m.size
    return true
}

func handleText(ctx: Context, opts: BodyParserOptions): Bool {
    match (ctx.bodyBytesCapped(opts.maxBytes)) {
        case None =>
            opts.onError(ctx, 413, "Request body too large")
            return false
        case Some(_) => ()
    }
    let s = ctx.body()
    let _ = s.size
    return true
}

/* Content-Length 预检中间件 */

/*
 * 未知长度（无 Content-Length 头，如 chunked 传输）时的策略。
 *   Pass    放行（默认）：交给 bodyParser 的流式限额兜底。
 *   Reject  411 Length Required：适合强网关语义（拒绝一切不确定长度的请求）。
 */
public enum IndeterminatePolicy {
    | Pass
    | Reject
}

public class ContentLengthLimitOptions {
    /* 与 BodyParserOptions.maxBytes 同义：请求体字节上限。 */
    public var maxBytes: Int64 = 1024 * 1024

    /* 无 Content-Length 时的策略，默认放行。 */
    public var onIndeterminate: IndeterminatePolicy = IndeterminatePolicy.Pass

    /* 错误响应格式，默认统一壳 {"code":N,...}（与 bodyParser 一致）。 */
    public var onError: (Context, Int64, String) -> Unit = defaultBodyParserError

    public init() {}
}

/* Convenience: contentLengthLimit() with defaults. */
public func contentLengthLimit(maxBytes: Int64): Middleware {
    let opts = ContentLengthLimitOptions()
    opts.maxBytes = maxBytes
    return contentLengthLimit(opts)
}

/*
 * 仅按 Content-Length 头预检的限额中间件，
 * 不消费请求流。与 bodyParser 的流式限额互补：
 *   - bodyParser 对 json/form/text 已知类型做真实流式限额（A-2 主修复）；
 *   - 本中间件对任何 Content-Type 生效（含 multipart、二进制透传），
 *     放在链最前面即可为上传/下载类端点兜底，替代使用方自制的 413 闸门。
 *
 * 行为：
 *   - Content-Length > maxBytes        -> 413（onError 决定响应格式）
 *   - Content-Length 缺失或非数字      -> onIndeterminate 策略
 *     （Pass 放行 / Reject 回 411 Length Required）
 */
public func contentLengthLimit(opts: ContentLengthLimitOptions): Middleware {
    return { ctx: Context, next: () -> Unit =>
        match (ctx.requestHeader("content-length")) {
            case Some(v) =>
                match (parseInt64OrNone(v.trimAscii())) {
                    case Some(n) =>
                        if (n > opts.maxBytes) {
                            opts.onError(ctx, 413, "Request body too large")
                            return
                        }
                    case None =>
                        // 值非法视同未声明长度，走 onIndeterminate 策略
                        match (opts.onIndeterminate) {
                            case IndeterminatePolicy.Reject =>
                                opts.onError(ctx, 411, "Length Required")
                                return
                            case IndeterminatePolicy.Pass => ()
                        }
                }
            case None =>
                match (opts.onIndeterminate) {
                    case IndeterminatePolicy.Reject =>
                        opts.onError(ctx, 411, "Length Required")
                        return
                    case IndeterminatePolicy.Pass => ()
                }
        }
        next()
    }
}

/*
 * Minimal JSON string escape: backslash, double-quote, control chars
 * (< 0x20). Used by the default error reporter so messages stay valid
 * JSON. Not a general-purpose JSON encoder -- just safe enough for the
 * error path where the input is a fixed set of canned messages plus
 * whatever exception.message the user throws.
 */
func escapeJsonString(s: String): String {
    let out = ArrayList<UInt8>()
    var i: Int64 = 0
    let n = s.size
    while (i < n) {
        let c = s[i]
        if (c == UInt8(0x5C)) {              // backslash
            out.add(UInt8(0x5C))
            out.add(UInt8(0x5C))
        } else if (c == UInt8(0x22)) {       // double quote
            out.add(UInt8(0x5C))
            out.add(UInt8(0x22))
        } else if (c < UInt8(0x20)) {        // control chars
            out.add(UInt8(0x5C))
            out.add(UInt8(0x75))             // 'u'
            out.add(UInt8(0x30))
            out.add(UInt8(0x30))
            out.add(UInt8(0x30) + UInt8((Int64(c) >> 4) & 0x0F))
            out.add(UInt8(0x30) + UInt8(Int64(c) & 0x0F))
        } else {
            out.add(c)
        }
        i += 1
    }
    return String.fromUtf8(out.toArray())
}