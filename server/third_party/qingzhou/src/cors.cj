package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * CORS middleware.
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * Implements the standard CORS request/response header set:
 *
 *   Access-Control-Allow-Origin:        <origin>
 *   Access-Control-Allow-Credentials:   true   (only when credentials=true)
 *   Access-Control-Expose-Headers:      <list>
 *
 * And on preflight (OPTIONS):
 *
 *   Access-Control-Allow-Methods:       <list>
 *   Access-Control-Allow-Headers:       <list>
 *   Access-Control-Max-Age:             <seconds>
 *
 * Origin handling:
 *   - "*"      : wildcard; per spec, credentials MUST NOT be true.
 *   - "reflect": mirror the request's Origin header back. Useful for
 *                multi-origin APIs that want to allow any client.
 *   - any other string: fixed origin (e.g. "https://app.example.com")
 *
 * Preflight short-circuits with 204 No Content and never calls next().
 */

public class CORSOptions {
    public var origin: String = "*"
    public var methods: String = "GET, POST, PUT, PATCH, DELETE, OPTIONS"
    public var allowedHeaders: String = "Content-Type, Authorization, X-Request-Id"
    public var exposedHeaders: String = "X-Request-Id"
    public var credentials: Bool = false
    public var maxAge: Int64 = 86400

    public init() {}
}

public func cors(): Middleware {
    return corsWith(CORSOptions())
}

public func corsWith(opts: CORSOptions): Middleware {
    return { ctx: Context, next: () -> Unit =>
        // Resolve the actual Origin value to advertise.
        let useOrigin = resolveOrigin(ctx, opts.origin)

        // Always advertise Allow-Origin + Expose-Headers on every
        // response so simple requests are accepted too.
        ctx.header("access-control-allow-origin", useOrigin)
        ctx.header("access-control-expose-headers", opts.exposedHeaders)
        if (opts.credentials && useOrigin != "*") {
            // Per spec: credentials + "*" is invalid; we guard against it.
            ctx.header("access-control-allow-credentials", "true")
        }

        // Preflight: OPTIONS + Access-Control-Request-Method present.
        if (ctx.method() == "OPTIONS" && ctx.requestHeader("access-control-request-method").isSome()) {
            ctx.header("access-control-allow-methods", opts.methods)
            ctx.header("access-control-allow-headers", opts.allowedHeaders)
            ctx.header("access-control-max-age", opts.maxAge.toString())
            ctx.status(204)
            // Note: 204 responses MUST NOT have a body. We explicitly
            // set body to "" (the default) and do NOT call next().
            return
        }

        next()
    }
}

/* Origin resolution. */
func resolveOrigin(ctx: Context, configured: String): String {
    if (configured == "*") {
        return "*"
    }
    if (configured == "reflect") {
        match (ctx.requestHeader("Origin")) {
            case Some(o) => return o
            case None => return "*"
        }
    }
    return configured
}