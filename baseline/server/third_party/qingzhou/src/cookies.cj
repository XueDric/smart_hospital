package qingzhou

import std.collection.*
import stdx.net.http.*

/*
 * SPDX-License-Identifier: MIT
 *
 * Cookie parsing & setting.
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * Replaces the  minimal Cookies (set/get only) with full koa-cookies
 * semantics:
 *
 *   ctx.cookies.get(name)                 -> read incoming cookie
 *   ctx.cookies.set(name, value)          -> legacy simple set
 *   ctx.cookies.set(name, value, opts)    -> full RFC 6265 Set-Cookie
 *
 * CookieOptions lets the caller pass maxAge / expires / path / domain /
 * secure / httpOnly / sameSite. All fields default to "do not emit"
 * except path = "/" because that's the most useful default for
 * application-level cookies (we are not emitting session cookies that
 * should be scoped to a sub-path).
 */

/* CookieOptions: full RFC 6265 knobs. All defaults are "omit" except
 * path, which defaults to "/" because application cookies almost
 * always want that and Koa itself uses "" which leaves the browser to
 * default the path to the current request -- an annoying footgun when
 * you forget it. */
public class CookieOptions {
    public var maxAge: Int64 = -1
    public var expires: String = ""
    public var path: String = "/"
    public var domain: String = ""
    public var secure: Bool = false
    public var httpOnly: Bool = false
    public var sameSite: String = ""

    public init() {}
}

public class Cookies {
    private var ctx: ?Context = None
    private var _cache: ?HashMap<String, String> = None

    init() {}

    init(ctx: Context) {
        this.ctx = Some(ctx)
    }

    public func rebind(ctx: Context): Unit {
        this.ctx = Some(ctx)
        _cache = None
    }

    /*
     * Read a cookie sent by the client. Returns None if not present.
     * Lazy: the Cookie: header is parsed on first call and cached for
     * the lifetime of this request context.
     */
    public func get(name: String): ?String {
        let m = parseCookieHeader()
        return m.get(name)
    }

    /*
     * Legacy  entry point: emit "Set-Cookie: k=v" with no attributes.
     * Equivalent to set(name, value, CookieOptions()) since the
     * CookieOptions defaults already cover the "minimal" case.
     */
    public func set(name: String, value: String): Unit {
        set(name, value, CookieOptions())
    }

    /*
     * Full RFC 6265 Set-Cookie emitter. The resulting header is
     * accumulated (commas) into the ctx's "Set-Cookie" header value,
     * because stdx's response builder overwrites same-named headers.
     * The combined form is valid per RFC 6265.
     *
     * Note on SameSite=None: the spec requires Secure=true whenever
     * SameSite=None. We deliberately do NOT auto-enforce this -- the
     * caller knows whether their deployment is HTTPS and we shouldn't
     * silently upgrade their security posture. We do, however, document
     * it in the source so reviewers are reminded.
     */
    public func set(name: String, value: String, opts: CookieOptions): Unit {
        // Build "k=v" plus optional attributes.
        let buf = StringBuilder()
        buf.append(name)
        buf.append("=")
        buf.append(value)
        if (opts.maxAge >= 0) {
            buf.append("; Max-Age=")
            buf.append(opts.maxAge.toString())
        }
        if (opts.expires.size > 0) {
            buf.append("; Expires=")
            buf.append(opts.expires)
        }
        if (opts.path.size > 0) {
            buf.append("; Path=")
            buf.append(opts.path)
        }
        if (opts.domain.size > 0) {
            buf.append("; Domain=")
            buf.append(opts.domain)
        }
        if (opts.secure) {
            buf.append("; Secure")
        }
        if (opts.httpOnly) {
            buf.append("; HttpOnly")
        }
        if (opts.sameSite.size > 0) {
            buf.append("; SameSite=")
            buf.append(opts.sameSite)
        }
        let newPair = buf.toString()

        match (ctx) {
            case Some(c) =>
                let existing = c._peekHeaders().get("Set-Cookie")
                match (existing) {
                    case Some(prev) => c.header("Set-Cookie", "${prev}, ${newPair}")
                    case None => c.header("Set-Cookie", newPair)
                }
            case None => ()
        }
    }

    /* ---------- internals ---------- */

    private func parseCookieHeader(): HashMap<String, String> {
        match (_cache) {
            case Some(m) => return m
            case None => ()
        }
        let m = HashMap<String, String>()
        match (ctx) {
            case Some(c) =>
                match (c.http) {
                    case Some(h) =>
                        for (entry in h.request.headers) {
                            if (entry[0].toAsciiLower() == "cookie") {
                                for (raw in entry[1]) {
                                    for (pair in raw.split(";", -1, removeEmpty: true)) {
                                        let trimmed = pair.trimAscii()
                                        if (trimmed.size == 0) { continue }
                                        // maxSplits is the max piece count;
                                        // 2 = one split at the first '='.
                                        let kv = trimmed.split("=", 2, removeEmpty: false)
                                        let k = kv[0]
                                        let v = if (kv.size > 1) { kv[1] } else { "" }
                                        // last write wins on duplicates
                                        m[k] = v
                                    }
                                }
                            }
                        }
                    case None => ()
                }
            case None => ()
        }
        _cache = Some(m)
        return m
    }
}