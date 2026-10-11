package qingzhou

import std.collection.*

/*
 * SPDX-License-Identifier: MIT
 *
 * onion dispatcher with error handling.
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * Design:
 *  - Middleware: (Context, () -> Unit) -> Unit
 *  - Dispatcher: class holding var index, captures let ref (this) for recursive next
 *  - Error path: AppHandler wraps business chain in try/catch.
 *      Exception -> ctx.throw_err(e) -> run error chain (if any) -> otherwise default 500.
 *    Error chain does not recurse next (Koa behavior) to avoid infinite loops.
 */
public type Middleware = (Context, () -> Unit) -> Unit

public class Dispatcher {
    private let ctx: Context
    private let stack: ArrayList<Middleware>
    private var index: Int64 = -1

    public init(ctx: Context, stack: ArrayList<Middleware>) {
        this.ctx = ctx
        this.stack = stack
    }

    public func dispatch(): Unit {
        next()
    }

    func next(): Unit {
        index += 1
        if (index < stack.size) {
            let mw = stack[index]
            mw(ctx, { => this.next() })
        }
    }
}

/*
 * Error chain dispatcher. Does NOT recurse into business chain.
 */
class ErrorDispatcher {
    private let ctx: Context
    private let stack: ArrayList<Middleware>
    private var index: Int64 = -1

    init(ctx: Context, stack: ArrayList<Middleware>) {
        this.ctx = ctx
        this.stack = stack
    }

    func dispatch(): Unit {
        next()
    }

    func next(): Unit {
        index += 1
        if (index < stack.size) {
            let mw = stack[index]
            mw(ctx, { => this.next() })
        }
    }
}

/*
 * Full request handler: encapsulates business + error chain.
 */
public class AppHandler {
    private let normalStack: ArrayList<Middleware>
    private let errorStack: ArrayList<Middleware>

    public init(normalStack: ArrayList<Middleware>, errorStack: ArrayList<Middleware>) {
        this.normalStack = normalStack
        this.errorStack = errorStack
    }

    public func handle(ctx: Context): Unit {
        try {
            let d = Dispatcher(ctx, normalStack)
            d.dispatch()
        } catch (e: Exception) {
            ctx.throw_err(e)
            if (errorStack.size > 0) {
                let ed = ErrorDispatcher(ctx, errorStack)
                try {
                    ed.dispatch()
                } catch (e2: Exception) {
                    ctx.status(500).body("Internal Error: ${e2.message}")
                }
            } else {
                ctx.status(500).body("Internal Error: ${e.message}")
            }
        }
        ctx.commit()
    }
}

/*
 * compatible compose: returns (Context) -> Unit for unit tests and light use.
 * Error handling is delegated to AppHandler.
 */
public func compose(stack: ArrayList<Middleware>): (Context) -> Unit {
    return { ctx: Context =>
        let d = Dispatcher(ctx, stack)
        d.dispatch()
    }
}
