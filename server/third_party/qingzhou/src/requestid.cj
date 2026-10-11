package qingzhou

import std.random.*

/*
 * SPDX-License-Identifier: MIT
 *
 * requestId middleware.
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * Assigns every request a stable id and surfaces it two ways:
 *   1. ctx.id()                -- reads the current id (set or default)
 *   2. response header         -- echoes the id to the client so
 *                                 downstream proxies / browser
 *                                 dev-tools can correlate logs
 *   3. ctx._id                 -- the raw field; logger / other
 *                                 middlewares can read it directly
 *
 * If the client supplies the configured request header (default
 * X-Request-Id) we trust it. Otherwise we mint 16 random bytes
 * (32 hex chars) -- long enough that collisions in a single
 * process lifetime are statistically negligible.
 *
 * The id is set BEFORE next() so downstream middlewares (logger,
 * request-bound tracing) can include it in their output.
 */

public class RequestIdOptions {
    public var header: String = "X-Request-Id"
    public var bytes: Int64 = 16
    public init() {}
}

public func requestId(): Middleware {
    return requestIdWith(RequestIdOptions())
}

public func requestIdWith(opts: RequestIdOptions): Middleware {
    return { ctx: Context, next: () -> Unit =>
        let incoming = ctx.requestHeader(opts.header)
        let id = match (incoming) {
            case Some(v) =>
                // Trim and validate. Some clients send comma lists
                // (X-Forwarded-For style). Take the first token and
                // strip whitespace.
                let t = v.trimAscii()
                if (t.size > 0) { t } else { randomId(opts.bytes) }
            case None => randomId(opts.bytes)
        }
        ctx._id = id
        ctx.header(opts.header, id)
        next()
    }
}

/* Generate a hex id of the requested byte length. */
func randomId(byteLen: Int64): String {
    let r = Random()
    let buf = Array<UInt8>(byteLen, { _ => UInt8(0) })
    r.nextBytes(buf)
    let out = StringBuilder()
    let hex = "0123456789abcdef"
    for (x in buf) {
        let hi = Int64(x) >> 4
        let lo = Int64(x) & 0x0f
        out.append(hex[hi..hi + 1])
        out.append(hex[lo..lo + 1])
    }
    return out.toString()
}