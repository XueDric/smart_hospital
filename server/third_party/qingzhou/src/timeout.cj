package qingzhou

import std.time.*

/*
 * SPDX-License-Identifier: MIT
 *
 * timeout middleware.
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * Soft, post-hoc timeout for the synchronous middleware model. We don't
 * have a thread scheduler to interrupt a long-running handler, so the
 * middleware does the next best thing:
 *
 *   - Record start time on entry (MonoTime for monotonicity).
 *   - Run the chain.
 *   - On exit, if elapsed > opts.ms:
 *       * If the handler did nothing (still default 200 + empty body),
 *         we override with 408 Request Timeout.
 *       * If the handler already responded (status / body set), we
 *         respect the handler's response and only stamp
 *         X-Timeout-Ms: <elapsed> on the response so observability
 *         tooling can spot slow handlers.
 *
 * This matches the spirit of koa-timeout without the ability to
 * interrupt the in-flight handler. The interrupt-style guarantee
 * requires a Future/Promise model that Cangjie's std doesn't ship
 * in 1.0.5.
 */

public class TimeoutOptions {
    /* Maximum wall time in milliseconds. 0 disables the middleware
     * (timeout() defaults to 5000). */
    public var ms: Int64 = 5000

    /* Custom responder invoked when the handler did not respond in
     * time. Default emits a plain-text 408. */
    public var onTimeout: (Context) -> Unit = defaultTimeoutResponder

    public init() {}
}

public func defaultTimeoutResponder(ctx: Context): Unit {
    ctx.status(408)
        .header("content-type", "text/plain; charset=utf-8")
        .body("Request Timeout")
}

/* Default-config: 5s timeout. */
public func timeout(): Middleware {
    return timeoutWith(TimeoutOptions())
}

/* Shorthand: timeout(ms). */
public func timeout(ms: Int64): Middleware {
    let opts = TimeoutOptions()
    opts.ms = ms
    return timeoutWith(opts)
}

public func timeoutWith(opts: TimeoutOptions): Middleware {
    return { ctx: Context, next: () -> Unit =>
        let start = MonoTime.now()
        ctx._startMonotonic = Some(start)
        ctx._timeoutMs = opts.ms
        next()
        // After the chain finishes: did we exceed?
        let now = MonoTime.now()
        let elapsed = (now - start).toMilliseconds()
        if (elapsed <= opts.ms) {
            return
        }
        // Exceeded. Decide: override (handler did nothing) or annotate.
        let statusUntouched = (ctx._peekStatus() == 200)
        let bodyUntouched = (ctx._peekBody().size == 0)
        if (statusUntouched && bodyUntouched) {
            opts.onTimeout(ctx)
        } else {
            ctx.header("x-timeout-ms", elapsed.toString())
        }
    }
}