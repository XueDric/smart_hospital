package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * built-in middleware demo (proof of framework API).
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * Demonstrates that response tools (status/body/header/json) and the error
 * channel (err()) behave correctly across both business and error chains.
 *
 * Real-world middleware (logger body-parser cors ...) lives in separate
 * qingzhou-middlewares modules under src/ (logger.cj, cors.cj, ...).
 */

/*
 * Logger: the  logger() lives in logger.cj with proper access-log
 * formatting. This file's logger() ( era, trace-only) has been
 * removed in favour of the new one. If you want the trace-only
 * behaviour for debugging, call ctx.trace(...) manually.
 */

/*
 * Error handler for the onError chain.
 * Default policy: if not yet responded (status == 200 + body empty), send 500 JSON.
 * If status already non-200 (e.g. 404 set by middleware), keep it.
 */
public func jsonErrorHandler(): Middleware {
    return { ctx: Context, _: () -> Unit =>
        match (ctx.err()) {
            case Some(e) =>
                if (ctx._peekStatus() == 200 && ctx._peekBody().size == 0) {
                    ctx.status(500)
                        .header("content-type", "application/json")
                        .body("{\"error\":\"${e.message}\"}")
                }
                // Always trace the failure for debugging.
                ctx.trace("[err] ${e.message}")
            case None => ()
        }
    }
}

/*
 * Plain-text responder helper, NOT a middleware - shows how to wrap a
 * response-tool call for a tiny endpoint.
 *   app.use((ctx, next) => { respondText(ctx, "hi"); return next() })
 */
public func respondText(ctx: Context, text: String): Unit {
    ctx.header("content-type", "text/plain; charset=utf-8").body(text)
}

public func respondJSON(ctx: Context, payload: String): Unit {
    ctx.json(payload)
}
