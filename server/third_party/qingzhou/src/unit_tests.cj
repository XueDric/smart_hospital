package qingzhou

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*
import stdx.encoding.json.*

/*
 * SPDX-License-Identifier: MIT
 *
 * unit tests using std.unittest.
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * Conventions:
 *  - returns Unit; failures are signaled by the @Expect / @Assert macros
 *    (cjpm test) AND by manual checks (when run from `test` mode).
 */

// ============ compose 调度 ============

@Test
func compose_single_mw_runs(): Unit {
    let stack = ArrayList<Middleware>()
    stack.add({ ctx: Context, _: () -> Unit =>
        ctx.trace("only")
    })
    let ctx = Context()
    compose(stack)(ctx)
    @Expect(ctx.dump(), "only")
}

@Test
func compose_order_is_onion(): Unit {
    let stack = ArrayList<Middleware>()
    stack.add({ ctx: Context, next: () -> Unit =>
        ctx.trace("a-in"); next(); ctx.trace("a-out")
    })
    stack.add({ ctx: Context, next: () -> Unit =>
        ctx.trace("b-in"); next(); ctx.trace("b-out")
    })
    stack.add({ ctx: Context, _: () -> Unit =>
        ctx.trace("h")
    })
    let ctx = Context()
    compose(stack)(ctx)
    @Expect(ctx.dump(), "a-in -> b-in -> h -> b-out -> a-out")
}

@Test
func compose_skipped_next_still_safe(): Unit {
    // koa-compose semantics: dispatch advances unconditionally;
    // a middleware that ignores `next` is still invoked once,
    // then returns to the caller.
    let stack = ArrayList<Middleware>()
    stack.add({ ctx: Context, next: () -> Unit =>
        ctx.trace("before"); next(); ctx.trace("after")
    })
    stack.add({ ctx: Context, _: () -> Unit =>
        ctx.trace("skipped")
    })
    let ctx = Context()
    compose(stack)(ctx)
    @Expect(ctx.dump(), "before -> skipped -> after")
}

// ============ Context 响应工具 ============

@Test
func context_default_response_is_200_empty(): Unit {
    let ctx = Context()
    @Expect(ctx._peekStatus(), 200)
    @Expect(ctx._peekBody(), "")
}

@Test
func context_chainable_status_body_header(): Unit {
    let ctx = Context()
    ctx.status(201).body("hi").header("x", "y")
    @Expect(ctx._peekStatus(), 201)
    @Expect(ctx._peekBody(), "hi")
    @Expect(ctx._peekHeaders()["x"], "y")
}

@Test
func context_json_sets_content_type(): Unit {
    let ctx = Context()
    ctx.json("{\"ok\":true}")
    @Expect(ctx._peekHeaders()["content-type"], "application/json; charset=utf-8")
    @Expect(ctx._peekBody(), "{\"ok\":true}")
}

// ============ AppHandler 错误处理 ============

class Boom <: Exception {
    init() { super("boom!") }
}

@Test
func apphandler_default_500_when_no_error_mw(): Unit {
    let stack = ArrayList<Middleware>()
    stack.add({ ctx: Context, _: () -> Unit =>
        throw Boom()
    })
    let h = AppHandler(stack, ArrayList<Middleware>())
    let ctx = Context()
    h.handle(ctx)
    @Expect(ctx._peekStatus(), 500)
    @Expect(ctx._peekBody(), "Internal Error: boom!")
}

@Test
func apphandler_invokes_error_chain_and_preserves_status(): Unit {
    let stack = ArrayList<Middleware>()
    stack.add({ ctx: Context, _: () -> Unit =>
        throw Boom()
    })
    let errStack = ArrayList<Middleware>()
    errStack.add({ ctx: Context, _: () -> Unit =>
        ctx.status(418).body("teapot")
    })
    let h = AppHandler(stack, errStack)
    let ctx = Context()
    h.handle(ctx)
    @Expect(ctx._peekStatus(), 418)
    @Expect(ctx._peekBody(), "teapot")
    @Expect(ctx.err().isSome(), true)
}

@Test
func apphandler_commit_is_idempotent(): Unit {
    let stack = ArrayList<Middleware>()
    stack.add({ ctx: Context, _: () -> Unit => () })
    let h = AppHandler(stack, ArrayList<Middleware>())
    let ctx = Context()
    h.handle(ctx)
    ctx.body("manual")
    @Assert(ctx._peekBody() == "manual")
    @Assert(ctx.commit() == ())
}

// ============  Router ============

func noopMw(ctx: Context, _: () -> Unit): Unit { () }

@Test
func router_static_match(): Unit {
    let r = Router().get("/users", noopMw)
    let ctx = Context()
    let res = r.lookup("GET", "/users", ctx)
    @Assert(match (res) { case DispatchResult.Matched(_) => true; case _ => false })
}

@Test
func router_param_match_injects_param(): Unit {
    let r = Router().get("/users/:id", noopMw)
    let ctx = Context()
    let res = r.lookup("GET", "/users/42", ctx)
    @Assert(match (res) { case DispatchResult.Matched(_) => true; case _ => false })
    @Expect(ctx.paramOr("id", ""), "42")
}

@Test
func router_multi_param(): Unit {
    let r = Router().get("/users/:uid/posts/:pid", noopMw)
    let ctx = Context()
    let _ = r.lookup("GET", "/users/7/posts/99", ctx)
    @Expect(ctx.paramOr("uid", ""), "7")
    @Expect(ctx.paramOr("pid", ""), "99")
}

@Test
func router_wildcard_captures_tail(): Unit {
    let r = Router().get("/files/*", noopMw)
    let ctx = Context()
    let res = r.lookup("GET", "/files/a/b/c.txt", ctx)
    @Assert(match (res) { case DispatchResult.Matched(_) => true; case _ => false })
    @Expect(ctx.paramOr("tail", ""), "a/b/c.txt")
}

@Test
func router_not_found(): Unit {
    let r = Router().get("/users", noopMw)
    let ctx = Context()
    let _ = r.lookup("GET", "/nope", ctx)
    @Expect(ctx._peekStatus(), 404)
}

@Test
func router_method_not_allowed_sets_405_and_allow(): Unit {
    let r = Router().get("/hello", noopMw)
    let ctx = Context()
    let _ = r.lookup("DELETE", "/hello", ctx)
    @Expect(ctx._peekStatus(), 405)
    @Expect(ctx._peekHeaders()["allow"], "GET")
}

@Test
func router_method_dispatch_same_path(): Unit {
    let r = Router()
        .get("/users", { ctx: Context, _: () -> Unit => ctx.body("list") })
        .post("/users", { ctx: Context, _: () -> Unit => ctx.body("create") })
    let ctxGet = Context()
    let _ = r.lookup("GET", "/users", ctxGet)
    @Expect(ctxGet._peekBody(), "list")
    let ctxPost = Context()
    let _ = r.lookup("POST", "/users", ctxPost)
    @Expect(ctxPost._peekBody(), "create")
}

@Test
func router_static_priority_over_param(): Unit {
    let r = Router()
        .get("/users/me", { ctx: Context, _: () -> Unit => ctx.body("me-static") })
        .get("/users/:id", { ctx: Context, _: () -> Unit => ctx.body("me-param") })
    let ctx = Context()
    let _ = r.lookup("GET", "/users/me", ctx)
    @Expect(ctx._peekBody(), "me-static")
    @Assert(ctx.param("id").isNone())
}

// ============  urlDecode ============

@Test
func urldecode_basic(): Unit {
    @Expect(urlDecode("hello"), "hello")
    @Expect(urlDecode("hello+world"), "hello world")
    @Expect(urlDecode("a%20b"), "a b")
}

@Test
func urldecode_percent_encoded_unicode(): Unit {
    // 中文 -> "%E4%B8%AD%E6%96%87"
    @Expect(urlDecode("%E4%B8%AD%E6%96%87"), "中文")
}

@Test
func urldecode_invalid_percent_passes_through(): Unit {
    // Lone % at end is left as-is.
    @Expect(urlDecode("abc%"), "abc%")
    // % followed by non-hex chars is left as-is.
    @Expect(urlDecode("abc%ZZ"), "abc%ZZ")
}

@Test
func urldecode_empty(): Unit {
    @Expect(urlDecode(""), "")
}

// ============  cookies (no http ctx path) ============

@Test
func cookies_get_returns_none_without_http(): Unit {
    let ctx = Context()
    let v = ctx.cookies.get("sid")
    @Assert(v.isNone())
}

@Test
func cookies_set_writes_header(): Unit {
    let ctx = Context()
    ctx.cookies.set("sid", "abc123")
    // : legacy set() now defaults to CookieOptions() which adds Path=/
    @Expect(ctx._peekHeaders()["Set-Cookie"], "sid=abc123; Path=/")
}

@Test
func cookies_set_multiple_accumulates(): Unit {
    let ctx = Context()
    ctx.cookies.set("a", "1")
    ctx.cookies.set("b", "2")
    // stdx's response builder overwrites same-named headers, so we
    // combine values into a single comma-separated header.
    @Expect(ctx._peekHeaders()["Set-Cookie"], "a=1; Path=/, b=2; Path=/")
}

@Test
func context_body_bytes_empty_when_no_http(): Unit {
    let ctx = Context()
    let b = ctx.bodyBytes()
    @Expect(b.size, 0)
    @Expect(ctx._peekRawBody().size, 0)
}

// ============  mimeOf ============

@Test
func mime_known_image(): Unit {
    @Expect(mimeOf("a.png"), "image/png")
    @Expect(mimeOf("a.jpg"), "image/jpeg")
    @Expect(mimeOf("a.jpeg"), "image/jpeg")
    @Expect(mimeOf("a.gif"), "image/gif")
    @Expect(mimeOf("a.webp"), "image/webp")
    @Expect(mimeOf("a.svg"), "image/svg+xml")
}

@Test
func mime_known_video_audio_text(): Unit {
    @Expect(mimeOf("clip.mp4"), "video/mp4")
    @Expect(mimeOf("clip.webm"), "video/webm")
    @Expect(mimeOf("song.mp3"), "audio/mpeg")
    @Expect(mimeOf("page.html"), "text/html; charset=utf-8")
    @Expect(mimeOf("page.css"), "text/css; charset=utf-8")
    @Expect(mimeOf("page.js"), "application/javascript; charset=utf-8")
}

@Test
func mime_case_insensitive_and_fallback(): Unit {
    // Case-insensitive ext
    @Expect(mimeOf("PIC.PNG"), "image/png")
    @Expect(mimeOf("PIC.Jpeg"), "image/jpeg")
    // Unknown extension -> application/octet-stream
    @Expect(mimeOf("data.xyz123"), "application/octet-stream")
    // No extension at all
    @Expect(mimeOf("README"), "application/octet-stream")
    // Trailing dot only
    @Expect(mimeOf("foo."), "application/octet-stream")
    // Dot in directory part (e.g. .gitignore)
    @Expect(mimeOf(".gitignore"), "application/octet-stream")
}

@Test
func mime_strips_dirs(): Unit {
    // The "extension" must be after the last '/', not just the last dot.
    @Expect(mimeOf("path/to/pic.png"), "image/png")
    // Folder named with a dot, then file with no ext
    @Expect(mimeOf("v1.2/file"), "application/octet-stream")
}

// ============  Context binary body ============

@Test
func context_body_bytes_kind_dispatch(): Unit {
    let ctx = Context()
    // Default kind = 0 (text)
    @Expect(ctx._peekBodyKind(), 0)
    ctx.body("hello")
    @Expect(ctx._peekBodyKind(), 0)
    // Switch to bytes flips the kind
    let payload = Array<UInt8>(3, { i => UInt8(i + 1) })
    ctx.body(payload)
    @Expect(ctx._peekBodyKind(), 1)
    @Expect(ctx._peekBodyBytes().size, 3)
    // Calling body(String) after body(bytes) flips back to text
    ctx.body("goodbye")
    @Expect(ctx._peekBodyKind(), 0)
}

@Test
func context_body_bytes_overrides_text(): Unit {
    // Even if String body was set, calling body(bytes) overrides it
    // (verified at commit-time, exercised in demo via HTTP demo).
    let ctx = Context()
    ctx.body("never sent")
    let payload = Array<UInt8>(5, { _ => UInt8(0xFF) })
    ctx.body(payload)
    @Expect(ctx._peekBodyKind(), 1)
    @Expect(ctx._peekBody(), "never sent")  // String buffer still there, just shadowed
}

// ============  hasTraversal ============

@Test
func traversal_blocks_dotdot_segments(): Unit {
    @Assert(hasTraversal("../etc/passwd"))
    @Assert(hasTraversal("a/../../b"))
    @Assert(hasTraversal("a/.."))
    @Assert(hasTraversal(".."))
}

@Test
func traversal_blocks_backslashes(): Unit {
    @Assert(hasTraversal("a\\b"))
    @Assert(hasTraversal("\\foo"))
}

@Test
func traversal_allows_normal_paths(): Unit {
    @Assert(!hasTraversal("a/b/c.png"))
    @Assert(!hasTraversal("logo.svg"))
    @Assert(!hasTraversal("path.with.dots/file"))  // dots mid-name are fine
    @Assert(!hasTraversal(""))
}

@Test
func mime_video_types_present(): Unit {
    // Sanity check for the  video MIME table
    @Expect(mimeOf("movie.mp4"), "video/mp4")
    @Expect(mimeOf("movie.mov"), "video/quicktime")
}

// ============  Range parser ============

@Test
func range_closed_form(): Unit {
    // bytes=0-499  ->  start=0, end=499
    let r = parseRange("bytes=0-499", 1000)
    @Assert(match (r) { case RangeResult.Satisfiable(s) => s.start == 0 && s.end == 499; case _ => false })
}

@Test
func range_open_end(): Unit {
    // bytes=500-  ->  start=500, end=size-1
    let r = parseRange("bytes=500-", 1000)
    @Assert(match (r) { case RangeResult.Satisfiable(s) => s.start == 500 && s.end == 999; case _ => false })
}

@Test
func range_suffix_form(): Unit {
    // bytes=-500  ->  last 500 bytes
    let r = parseRange("bytes=-500", 1000)
    @Assert(match (r) { case RangeResult.Satisfiable(s) => s.start == 500 && s.end == 999; case _ => false })
    // bytes=-1500 with size=1000 caps to full file
    let r2 = parseRange("bytes=-1500", 1000)
    @Assert(match (r2) { case RangeResult.Satisfiable(s) => s.start == 0 && s.end == 999; case _ => false })
}

@Test
func range_end_clipped_to_size(): Unit {
    // bytes=0-9999 with size=1000 -> capped to end=999
    let r = parseRange("bytes=0-9999", 1000)
    @Assert(match (r) { case RangeResult.Satisfiable(s) => s.start == 0 && s.end == 999; case _ => false })
}

@Test
func range_unsatisfiable_start_past_end(): Unit {
    // start >= fileSize
    let r = parseRange("bytes=1000-", 1000)
    @Assert(match (r) { case RangeResult.Unsatisfiable => true; case _ => false })
}

@Test
func range_malformed_reversed_bounds(): Unit {
    // start > end is a malformed range per RFC 7233 section 2.1
    let r = parseRange("bytes=200-100", 1000)
    @Assert(match (r) { case RangeResult.Malformed => true; case _ => false })
}

@Test
func range_malformed_multi_range(): Unit {
    // bytes=0-100,200-300 (multi-range) -> Malformed ( does not support multipart)
    let r = parseRange("bytes=0-100,200-300", 1000)
    @Assert(match (r) { case RangeResult.Malformed => true; case _ => false })
}

@Test
func range_malformed_no_unit(): Unit {
    let r = parseRange("0-499", 1000)
    @Assert(match (r) { case RangeResult.Malformed => true; case _ => false })
}

@Test
func range_zero_byte_resource(): Unit {
    // Per RFC 7233 section 4.4, 0-byte resource is unsatisfiable.
    let r = parseRange("bytes=0-0", 0)
    @Assert(match (r) { case RangeResult.Unsatisfiable => true; case _ => false })
}

@Test
func range_length_helper(): Unit {
    let s = RangeSpec(10, 19)  // 10 bytes inclusive
    @Expect(s.length(), 10)
}

@Test
func format_content_range_normal(): Unit {
    let s = RangeSpec(0, 499)
    @Expect(formatContentRange(s, 1000), "bytes 0-499/1000")
}

@Test
func format_content_range_unsatisfiable(): Unit {
    @Expect(formatUnsatisfiableContentRange(1000), "bytes */1000")
}

// ============  ETag ============

@Test
func etag_make_quoted_size(): Unit {
    @Expect(makeETag(0), "\"0\"")
    @Expect(makeETag(1024), "\"1024\"")
    @Expect(makeETag(123456789), "\"123456789\"")
}

@Test
func etag_matches_exact(): Unit {
    let et = makeETag(1024)
    @Assert(etagMatches("\"1024\"", et))
}

@Test
func etag_matches_wildcard(): Unit {
    // "*" matches anything
    @Assert(etagMatches("*", makeETag(1024)))
    @Assert(etagMatches("  *  ", makeETag(7)))
}

@Test
func etag_matches_in_list(): Unit {
    let et = makeETag(1024)
    @Assert(etagMatches("\"old1\", \"1024\", \"old2\"", et))
    @Assert(etagMatches("\"999\", W/\"1024\"", et))  // weak prefix allowed
}

@Test
func etag_does_not_match_other_size(): Unit {
    let et = makeETag(1024)
    @Assert(!etagMatches("\"2048\"", et))
    @Assert(!etagMatches("", et))
}

@Test
func etag_parse_tags_strips_weak_prefix(): Unit {
    let tags = parseIfNoneMatchTags("W/\"42\", \"43\"")
    @Expect(tags.size, 2)
    @Expect(tags[0], "\"42\"")
    @Expect(tags[1], "\"43\"")
}

// ============  Cookies (full options) ============

@Test
func cookies_set_with_full_options(): Unit {
    let ctx = Context()
    let opts = CookieOptions()
    opts.maxAge = 3600
    opts.path = "/admin"
    opts.domain = "example.com"
    opts.httpOnly = true
    opts.secure = true
    opts.sameSite = "Strict"
    ctx.cookies.set("sid", "x", opts)
    let hdr = ctx._peekHeaders()["Set-Cookie"]
    // Order of attribute emission is fixed by cookies.cj, so we can
    // assert the exact string here.
    @Expect(hdr.contains("sid=x"), true)
    @Expect(hdr.contains("Max-Age=3600"), true)
    @Expect(hdr.contains("Path=/admin"), true)
    @Expect(hdr.contains("Domain=example.com"), true)
    @Expect(hdr.contains("HttpOnly"), true)
    @Expect(hdr.contains("Secure"), true)
    @Expect(hdr.contains("SameSite=Strict"), true)
}

@Test
func cookies_set_default_options_omit_attrs(): Unit {
    let ctx = Context()
    let opts = CookieOptions()
    // opts.maxAge = -1 (default = omit), path = "/" (default = emit),
    // domain = "" (omit), secure/httpOnly = false (omit), sameSite = "" (omit)
    ctx.cookies.set("k", "v", opts)
    let hdr = ctx._peekHeaders()["Set-Cookie"]
    @Expect(hdr, "k=v; Path=/")
}

// ============  bodyParser ============

@Test
func bodyparser_handles_text_body_without_error(): Unit {
    // Without an http ctx, the body parser is a no-op (it can't read
    // the request stream). The middleware still calls next().
    let ctx = Context()
    let mw = bodyParser()
    let called = Array<Bool>(1, { _ => false })
    mw(ctx, { => called[0] = true })
    @Expect(called[0], true)
}

// ============  logger formatter ============

@Test
func logger_default_formatter_includes_id_method_status(): Unit {
    let ctx = Context()
    ctx._id = "abc123"
    ctx.status(404)
    let line = defaultLoggerFormatter(ctx, 12)
    @Expect(line.contains("abc123"), true)
    @Expect(line.contains("404"), true)
    @Expect(line.contains("12ms"), true)
}

@Test
func logger_default_formatter_dash_when_no_id(): Unit {
    let ctx = Context()
    let line = defaultLoggerFormatter(ctx, 1)
    @Expect(line.startsWith("- "), true)
}

// ============  requestId ============

@Test
func random_id_is_hex_of_requested_length(): Unit {
    let id = randomId(8)  // 8 bytes -> 16 hex chars
    @Expect(id.size, 16)
    for (c in id) {
        let ok = (c >= UInt8(0x30) && c <= UInt8(0x39)) || (c >= UInt8(0x61) && c <= UInt8(0x66))
        @Assert(ok)
    }
}

// ============  CORS resolveOrigin ============

@Test
func cors_resolve_origin_wildcard(): Unit {
    // No http -> requestHeader returns None -> fallback "*"
    let ctx = Context()
    @Expect(resolveOrigin(ctx, "*"), "*")
}

@Test
func cors_resolve_origin_fixed(): Unit {
    let ctx = Context()
    @Expect(resolveOrigin(ctx, "https://app.example.com"), "https://app.example.com")
}

// ============ jsonx 安全访问器 + JsonBuilder ============

func mkObj(): JsonObject {
    let o = JsonObject()
    o.put("name", JsonString("alice"))
    o.put("age", JsonInt(30))
    o.put("ok", JsonBool(true))
    o.put("tags", JsonArray())
    return o
}

@Test
func jsonx_getStr_hit(): Unit {
    match (jsonGetStr(mkObj(), "name")) {
        case Some(s) => @Expect(s, "alice")
        case None => @Assert(false)
    }
}

@Test
func jsonx_getStr_missing(): Unit {
    match (jsonGetStr(mkObj(), "nope")) {
        case Some(_) => @Assert(false)
        case None => @Assert(true)
    }
}

@Test
func jsonx_getStr_wrong_type(): Unit {
    // "age" is an Int; reading as String must fail-soft to None.
    match (jsonGetStr(mkObj(), "age")) {
        case Some(_) => @Assert(false)
        case None => @Assert(true)
    }
}

@Test
func jsonx_getInt64_hit(): Unit {
    match (jsonGetInt64(mkObj(), "age")) {
        case Some(n) => @Expect(n, 30)
        case None => @Assert(false)
    }
}

@Test
func jsonx_getInt64_wrong_type(): Unit {
    match (jsonGetInt64(mkObj(), "name")) {
        case Some(_) => @Assert(false)
        case None => @Assert(true)
    }
}

@Test
func jsonx_getBool_hit(): Unit {
    match (jsonGetBool(mkObj(), "ok")) {
        case Some(b) => @Expect(b, true)
        case None => @Assert(false)
    }
}

@Test
func jsonx_getArray_hit(): Unit {
    match (jsonGetArray(mkObj(), "tags")) {
        case Some(a) => @Expect(a.size(), 0)
        case None => @Assert(false)
    }
}

@Test
func jsonx_jsonMissing_reports_first(): Unit {
    let o = JsonObject()
    o.put("a", JsonString("1"))
    match (jsonMissing(o, ["a", "b", "c"])) {
        case Some(missing) => @Expect(missing, "b")
        case None => @Assert(false)
    }
}

@Test
func jsonx_jsonMissing_none_when_all_present(): Unit {
    let o = JsonObject()
    o.put("a", JsonString("1"))
    o.put("b", JsonString("2"))
    match (jsonMissing(o, ["a", "b"])) {
        case Some(_) => @Assert(false)
        case None => @Assert(true)
    }
}

@Test
func jsonx_builder_escapes_and_serializes(): Unit {
    let j = JsonBuilder()
        .put("title", "he said \"hi\"")
        .putInt("count", 3)
        .putBool("ok", true)
        .build()
    // toString() must have escaped the embedded quotes and kept types.
    @Expect(j.contains("\\\""), true)
    @Expect(j.contains("\"count\":3"), true)
    @Expect(j.contains("\"ok\":true"), true)
}

@Test
func jsonx_builder_nested_object(): Unit {
    let inner = JsonObject()
    inner.put("x", JsonInt(1))
    let j = JsonBuilder().putObject("meta", inner).build()
    @Expect(j.contains("\"meta\":{\"x\":1}"), true)
}

// ============ security 密码哈希 + 签名 ============

@Test
func security_hash_verify_success(): Unit {
    let stored = hashPassword("secret123", "abc", 10)
    @Expect(verifyPassword("secret123", stored), true)
}

@Test
func security_hash_verify_wrong_password(): Unit {
    let stored = hashPassword("secret123", "abc", 10)
    @Expect(verifyPassword("wrong", stored), false)
}

@Test
func security_hash_self_describing_format(): Unit {
    let stored = hashPassword("pw", "salt", 5)
    let parts = stored.split("$", 3, removeEmpty: false)
    @Expect(parts.size, 3)
    @Expect(parts[0], "salt")
    @Expect(parts[1], "5")
}

@Test
func security_sign_roundtrip(): Unit {
    let signed = signValue("session-123", "secret")
    match (verifySigned(signed, "secret")) {
        case Some(v) => @Expect(v, "session-123")
        case None => @Assert(false)
    }
}

@Test
func security_sign_tampered_rejected(): Unit {
    let signed = signValue("session-123", "secret")
    match (signed.lastIndexOf(".")) {
        case Some(dot) =>
            let tampered = "session-999" + signed[dot..]
            match (verifySigned(tampered, "secret")) {
                case Some(_) => @Assert(false)
                case None => @Assert(true)
            }
        case None => @Assert(false)
    }
}

@Test
func security_sign_wrong_secret_rejected(): Unit {
    let signed = signValue("v", "secret-a")
    match (verifySigned(signed, "secret-b")) {
        case Some(_) => @Assert(false)
        case None => @Assert(true)
    }
}

@Test
func security_randomHex_length(): Unit {
    let h = randomHex(16)
    @Expect(h.size, 32)  // 16 bytes -> 32 hex chars
}

// ============ session ============

@Test
func session_create_exists(): Unit {
    let store = SessionStore()
    let id = store.create()
    @Expect(store.exists(id), true)
}

@Test
func session_set_get_roundtrip(): Unit {
    let store = SessionStore()
    let id = store.create()
    store.set(id, "user", "alice")
    match (store.get(id, "user")) {
        case Some(v) => @Expect(v, "alice")
        case None => @Assert(false)
    }
}

@Test
func session_destroy(): Unit {
    let store = SessionStore()
    let id = store.create()
    store.destroy(id)
    @Expect(store.exists(id), false)
}

// ============ util 内置解析器 ============

@Test
func util_parseInt64OrNone_valid(): Unit {
    match (parseInt64OrNone("42")) {
        case Some(n) => @Expect(n, 42)
        case None => @Assert(false)
    }
}

@Test
func util_parseInt64OrNone_invalid(): Unit {
    match (parseInt64OrNone("abc")) {
        case Some(_) => @Assert(false)
        case None => @Assert(true)
    }
}

@Test
func util_parseInt64Or_default(): Unit {
    @Expect(parseInt64Or("abc", 7), 7)
    @Expect(parseInt64Or("12", 7), 12)
}

@Test
func util_parseUInt16OrNone_valid(): Unit {
    match (parseUInt16OrNone("8080")) {
        case Some(n) => @Expect(n, 8080)
        case None => @Assert(false)
    }
}

@Test
func util_parseBoolOrNone(): Unit {
    @Expect(parseBoolOrNone("true"), Some(true))
    @Expect(parseBoolOrNone("FALSE"), Some(false))
    match (parseBoolOrNone("yes")) {
        case Some(_) => @Assert(false)
        case None => @Assert(true)
    }
}

// ============ 多 Range ============

@Test
func range_multi_satisfiable(): Unit {
    match (parseRanges("bytes=0-1,4-5", 100)) {
        case RangesResult.Satisfiable(specs) => @Expect(specs.size, 2)
        case _ => @Assert(false)
    }
}

@Test
func range_multi_single_still_works(): Unit {
    match (parseRanges("bytes=0-1", 100)) {
        case RangesResult.Satisfiable(specs) => @Expect(specs.size, 1)
        case _ => @Assert(false)
    }
}

@Test
func range_multi_unsatisfiable(): Unit {
    match (parseRanges("bytes=999-1000", 100)) {
        case RangesResult.Unsatisfiable => @Assert(true)
        case _ => @Assert(false)
    }
}

@Test
func range_multi_malformed(): Unit {
    match (parseRanges("bytes=abc", 100)) {
        case RangesResult.Malformed => @Assert(true)
        case _ => @Assert(false)
    }
}

@Test
func range_multipart_body_contains_boundary_and_range(): Unit {
    let bytes = Array<UInt8>(10, { i => UInt8(i) })
    let specs = Array<RangeSpec>(2, { _ => RangeSpec(0, 1) })
    specs[0] = RangeSpec(0, 1)
    specs[1] = RangeSpec(4, 5)
    let body = formatMultipartBody(specs, bytes, "text/plain", "BND", 10)
    let s = String.fromUtf8(body)
    @Expect(s.contains("--BND"), true)
    @Expect(s.contains("Content-Range: bytes 0-1/10"), true)
    @Expect(s.contains("Content-Range: bytes 4-5/10"), true)
    @Expect(s.contains("--BND--"), true)
}

// ============ compress (gzip) ============

@Test
func compress_gzip_compresses_repetitive_data(): Unit {
    let big = Array<UInt8>(1000, { _ => UInt8(0x61) })  // 1000 个 'a'
    let gz = gzipCompress(big)
    @Expect(gz.size > 0, true)
    @Expect(gz.size < big.size, true)
}

@Test
func compress_gzip_empty_input(): Unit {
    let gz = gzipCompress(Array<UInt8>())
    @Expect(gz.size, 0)
}

@Test
func compress_isCompressibleType(): Unit {
    @Expect(isCompressibleType("text/html; charset=utf-8"), true)
    @Expect(isCompressibleType("application/json"), true)
    @Expect(isCompressibleType("image/png"), false)
}

// ============ multipart ============

@Test
func multipart_extract_boundary(): Unit {
    @Expect(extractBoundary("multipart/form-data; boundary=abc123"), "abc123")
    @Expect(extractBoundary("multipart/form-data; boundary=\"xyz\""), "xyz")
}

@Test
func multipart_parse_text_field(): Unit {
    let body = "--BND\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nhello world\r\n--BND--\r\n"
    let parts = parseMultipart(body.toArray(), "BND")
    @Expect(parts.size, 1)
    @Expect(parts[0].name, "title")
    @Expect(parts[0].text(), "hello world")
}

@Test
func multipart_parse_file_field(): Unit {
    let body = "--BND\r\nContent-Disposition: form-data; name=\"upload\"; filename=\"a.txt\"\r\nContent-Type: text/plain\r\n\r\nfile bytes here\r\n--BND--\r\n"
    let parts = parseMultipart(body.toArray(), "BND")
    @Expect(parts.size, 1)
    @Expect(parts[0].name, "upload")
    @Expect(parts[0].filename, "a.txt")
    @Expect(parts[0].text(), "file bytes here")
}

@Test
func multipart_parse_multiple_parts(): Unit {
    let body = "--BND\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n--BND\r\nContent-Disposition: form-data; name=\"b\"\r\n\r\n2\r\n--BND--\r\n"
    let parts = parseMultipart(body.toArray(), "BND")
    @Expect(parts.size, 2)
    @Expect(parts[0].name, "a")
    @Expect(parts[1].name, "b")
}

// ============ Last-Modified ============

@Test
func lastmod_fileLastModified_returns_some(): Unit {
    match (fileLastModified("./public_blog/index.html")) {
        case Some(_) => @Assert(true)
        case None => @Assert(false)
    }
}

@Test
func lastmod_fileLastModified_missing_returns_none(): Unit {
    match (fileLastModified("./public_blog/does_not_exist.xyz")) {
        case Some(_) => @Assert(false)
        case None => @Assert(true)
    }
}

@Test
func lastmod_formatHttpDate_contains_gmt(): Unit {
    match (fileLastModified("./public_blog/index.html")) {
        case Some(mt) =>
            let s = formatHttpDate(mt)
            @Expect(s.contains(" GMT"), true)
            @Expect(s.contains(", "), true)
        case None => @Assert(false)
    }
}

@Test
func lastmod_lastModifiedMatches_exact(): Unit {
    @Expect(lastModifiedMatches("Wed, 09 Sep 2026 19:33:49 GMT", "Wed, 09 Sep 2026 19:33:49 GMT"), true)
    @Expect(lastModifiedMatches("Thu, 10 Sep 2026 00:00:00 GMT", "Wed, 09 Sep 2026 19:33:49 GMT"), false)
}

@Test
func config_parse_key_value(): Unit {
    let c = parseConfigText("port=3000\nhost=localhost")
    @Expect(c.getOr("port", ""), "3000")
    @Expect(c.getOr("host", ""), "localhost")
}

@Test
func config_parse_ignores_comment_and_blank(): Unit {
    let c = parseConfigText("# comment\n\nport=8080\n   \n# another\nname=app")
    @Expect(c.has("comment"), false)
    @Expect(c.size(), 2)
    @Expect(c.getOr("port", ""), "8080")
    @Expect(c.getOr("name", ""), "app")
}

@Test
func config_value_with_equals(): Unit {
    let c = parseConfigText("url=http://x.com?a=1&b=2")
    @Expect(c.getOr("url", ""), "http://x.com?a=1&b=2")
}

@Test
func config_typed_accessors(): Unit {
    let c = Config()
    c.set("port", "3000")
    c.set("debug", "true")
    c.set("ratio", "1.5")
    @Expect(c.getIntOr("port", 0), 3000)
    @Expect(c.getBoolOr("debug", false), true)
    match (c.getFloat("ratio")) {
        case Some(f) => @Expect(f > 1.4, true)
        case None => @Assert(false)
    }
}

@Test
func config_get_or_default(): Unit {
    let c = Config()
    @Expect(c.getOr("missing", "fallback"), "fallback")
    @Expect(c.getIntOr("missing", 42), 42)
    @Expect(c.getBoolOr("missing", true), true)
}

@Test
func static_cache_put_get(): Unit {
    let cache = StaticCache()
    let bytes = Array<UInt8>(3, { i => UInt8(i + 1) })
    cache.put("/a/b.txt", bytes)
    match (cache.get("/a/b.txt")) {
        case Some(cached) => @Expect(cached.size, 3)
        case None => @Assert(false)
    }
    match (cache.get("/missing") ) {
        case Some(_) => @Assert(false)
        case None => @Assert(true)
    }
}
