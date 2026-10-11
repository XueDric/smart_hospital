package qingzhou

import std.collection.*
import std.io.InputStream
import std.fs.*
import std.time.*
import std.sync.*
import stdx.encoding.json.*
import stdx.crypto.x509.*
import stdx.crypto.keys.*

// 已运行的场景总数（动态计数，避免与 @Test 版场景数硬编码不同步）
var g_total: Int64 = 0

/*
 * SPDX-License-Identifier: MIT
 *
 * Manual runner used by `qingzhou.exe test`.
 * Re-executes each unit-test scenario without @Test / @Expect macros so that
 * the same scenarios stay runnable under cjc-direct builds (where cjpm test
 * may be unstable on Windows).
 *
 * Each scenario must throw to fail; the runner converts that to a FAIL line.
 */
public func runAllUnitTests(): Int64 {
    var failed: Int64 = 0

    failed += runCase("compose_single_mw_runs", { =>
        let stack = ArrayList<Middleware>()
        stack.add({ ctx: Context, _: () -> Unit =>
            ctx.trace("only")
        })
        let ctx = Context()
        compose(stack)(ctx)
        checkEq(ctx.dump(), "only")
    })

    failed += runCase("compose_order_is_onion", { =>
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
        checkEq(ctx.dump(), "a-in -> b-in -> h -> b-out -> a-out")
    })

    failed += runCase("compose_skipped_next_still_safe", { =>
        // koa-compose semantics: dispatch advances unconditionally;
        // a middleware that ignores `next` is still invoked once,
        // then returns to the caller. No crash, no infinite loop.
        let stack = ArrayList<Middleware>()
        stack.add({ ctx: Context, next: () -> Unit =>
            ctx.trace("before"); next(); ctx.trace("after")
        })
        stack.add({ ctx: Context, _: () -> Unit =>
            ctx.trace("skipped")
        })
        let ctx = Context()
        compose(stack)(ctx)
        checkEq(ctx.dump(), "before -> skipped -> after")
    })

    failed += runCase("context_default_response_is_200_empty", { =>
        let ctx = Context()
        checkEq(ctx._peekStatus(), 200)
        checkEq(ctx._peekBody(), "")
    })

    failed += runCase("context_chainable_status_body_header", { =>
        let ctx = Context()
        ctx.status(201).body("hi").header("x", "y")
        checkEq(ctx._peekStatus(), 201)
        checkEq(ctx._peekBody(), "hi")
        checkEq(ctx._peekHeaders()["x"], "y")
    })

    failed += runCase("context_json_sets_content_type", { =>
        let ctx = Context()
        ctx.json("{\"ok\":true}")
        checkEq(ctx._peekHeaders()["content-type"], "application/json; charset=utf-8")
        checkEq(ctx._peekBody(), "{\"ok\":true}")
    })

    failed += runCase("apphandler_default_500_when_no_error_mw", { =>
        let stack = ArrayList<Middleware>()
        stack.add({ ctx: Context, _: () -> Unit =>
            throw Boom2()
        })
        let h = AppHandler(stack, ArrayList<Middleware>())
        let ctx = Context()
        h.handle(ctx)
        checkEq(ctx._peekStatus(), 500)
        checkEq(ctx._peekBody(), "Internal Error: boom!")
    })

    failed += runCase("apphandler_invokes_error_chain_and_preserves_status", { =>
        let stack = ArrayList<Middleware>()
        stack.add({ ctx: Context, _: () -> Unit =>
            throw Boom2()
        })
        let errStack = ArrayList<Middleware>()
        errStack.add({ ctx: Context, _: () -> Unit =>
            ctx.status(418).body("teapot")
        })
        let h = AppHandler(stack, errStack)
        let ctx = Context()
        h.handle(ctx)
        checkEq(ctx._peekStatus(), 418)
        checkEq(ctx._peekBody(), "teapot")
        checkTrue(ctx.err().isSome())
    })

    failed += runCase("apphandler_commit_idempotent_default_200", { =>
        let stack = ArrayList<Middleware>()
        stack.add({ ctx: Context, _: () -> Unit => () })
        let h = AppHandler(stack, ArrayList<Middleware>())
        let ctx = Context()
        h.handle(ctx)
        checkEq(ctx._peekStatus(), 200)
    })

    // ============  Router scenarios ============

    failed += runCase("router_static_match", { =>
        let r = Router().get("/users", { ctx, _ => () })
        let ctx = Context()
        let res = r.lookup("GET", "/users", ctx)
        checkTrue(match (res) { case DispatchResult.Matched(_) => true; case _ => false })
    })

    failed += runCase("router_param_match_injects_param", { =>
        let r = Router().get("/users/:id", { ctx, _ => () })
        let ctx = Context()
        let _ = r.lookup("GET", "/users/42", ctx)
        checkEq(ctx.paramOr("id", ""), "42")
    })

    failed += runCase("router_multi_param", { =>
        let r = Router().get("/users/:uid/posts/:pid", { ctx, _ => () })
        let ctx = Context()
        let _ = r.lookup("GET", "/users/7/posts/99", ctx)
        checkEq(ctx.paramOr("uid", ""), "7")
        checkEq(ctx.paramOr("pid", ""), "99")
    })

    failed += runCase("router_wildcard_captures_tail", { =>
        let r = Router().get("/files/*", { ctx, _ => () })
        let ctx = Context()
        let _ = r.lookup("GET", "/files/a/b/c.txt", ctx)
        checkEq(ctx.paramOr("tail", ""), "a/b/c.txt")
    })

    failed += runCase("router_not_found", { =>
        let r = Router().get("/users", { ctx, _ => () })
        let ctx = Context()
        let _ = r.lookup("GET", "/nope", ctx)
        checkEq(ctx._peekStatus(), 404)
    })

    failed += runCase("router_method_not_allowed_405_allow", { =>
        let r = Router().get("/hello", { ctx, _ => () })
        let ctx = Context()
        let _ = r.lookup("DELETE", "/hello", ctx)
        checkEq(ctx._peekStatus(), 405)
        checkEq(ctx._peekHeaders()["allow"], "GET")
    })

    failed += runCase("router_method_dispatch_same_path", { =>
        let r = Router()
            .get("/users", { ctx, _ => ctx.body("list") })
            .post("/users", { ctx, _ => ctx.body("create") })
        let gctx = Context()
        let gres = r.lookup("GET", "/users", gctx)
        checkTrue(match (gres) { case DispatchResult.Matched(_) => true; case _ => false })
        match (gres) {
            case DispatchResult.Matched(h) => h(gctx, { => () })
            case _ => ()
        }
        checkEq(gctx._peekBody(), "list")
        let pctx = Context()
        let pres = r.lookup("POST", "/users", pctx)
        match (pres) {
            case DispatchResult.Matched(h) => h(pctx, { => () })
            case _ => ()
        }
        checkEq(pctx._peekBody(), "create")
    })

    failed += runCase("router_static_priority_over_param", { =>
        let r = Router()
            .get("/users/me", { ctx, _ => ctx.body("me-static") })
            .get("/users/:id", { ctx, _ => ctx.body("me-param") })
        let ctx = Context()
        let res = r.lookup("GET", "/users/me", ctx)
        match (res) {
            case DispatchResult.Matched(h) => h(ctx, { => () })
            case _ => ()
        }
        checkEq(ctx._peekBody(), "me-static")
        checkTrue(ctx.param("id").isNone())
    })

    failed += runCase("router_backtrack_static_then_param", { =>
        let r = Router()
            .get("/api/users/me", { ctx, _ => ctx.body("user-me") })
            .get("/api/:module/list", { ctx, _ => ctx.body("module-list") })
        let ctx = Context()
        let res = r.lookup("GET", "/api/users/list", ctx)
        match (res) {
            case DispatchResult.Matched(h) => h(ctx, { => () })
            case _ => ()
        }
        checkEq(ctx._peekBody(), "module-list")
        checkEq(ctx.paramOr("module", "-"), "users")
    })

    failed += runCase("router_backtrack_static_then_wildcard", { =>
        let r = Router()
            .get("/files/local/config", { ctx, _ => ctx.body("local-config") })
            .get("/files/*path", { ctx, _ => ctx.body("wild") })
        let ctx = Context()
        let res = r.lookup("GET", "/files/local/data", ctx)
        match (res) {
            case DispatchResult.Matched(h) => h(ctx, { => () })
            case _ => ()
        }
        checkEq(ctx._peekBody(), "wild")
        checkEq(ctx.paramOr("path", "-"), "local/data")
    })

    failed += runCase("router_backtrack_restores_param_on_failure", { =>
        let r = Router()
            .get("/x/:a/fixed", { ctx, _ => ctx.body("first") })
            .get("/x/:b/other", { ctx, _ => ctx.body("second") })
        let ctx = Context()
        let res = r.lookup("GET", "/x/val/other", ctx)
        match (res) {
            case DispatchResult.Matched(h) => h(ctx, { => () })
            case _ => ()
        }
        checkEq(ctx._peekBody(), "second")
        checkEq(ctx.paramOr("b", "-"), "val")
        checkTrue(ctx.param("a").isNone())
    })

    failed += runCase("router_backtrack_param_then_wildcard", { =>
        let r = Router()
            .get("/d/:id/detail", { ctx, _ => ctx.body("detail") })
            .get("/d/:name/*rest", { ctx, _ => ctx.body("rest") })
        let ctx = Context()
        let res = r.lookup("GET", "/d/42/x/y", ctx)
        match (res) {
            case DispatchResult.Matched(h) => h(ctx, { => () })
            case _ => ()
        }
        checkEq(ctx._peekBody(), "rest")
        checkEq(ctx.paramOr("name", "-"), "42")
        checkEq(ctx.paramOr("rest", "-"), "x/y")
        checkTrue(ctx.param("id").isNone())
    })

    failed += runCase("router_param_prefix_plus_tail_wildcard", { =>
        let r = Router().get("/:version/*path", { ctx, _ => ctx.body("api") })
        let ctx = Context()
        let res = r.lookup("GET", "/v1/users/42", ctx)
        match (res) {
            case DispatchResult.Matched(h) => h(ctx, { => () })
            case _ => ()
        }
        checkEq(ctx._peekBody(), "api")
        checkEq(ctx.paramOr("version", "-"), "v1")
        checkEq(ctx.paramOr("path", "-"), "users/42")
    })

    // ============  Router enhancements: optional params / named wildcards / groups / naming ============

    failed += runCase("router_optional_param_matched", { =>
        let r = Router().get("/users/:id?", { ctx, _ => () })
        let ctx = Context()
        let res = r.lookup("GET", "/users/42", ctx)
        checkTrue(match (res) { case DispatchResult.Matched(_) => true; case _ => false })
        checkEq(ctx.paramOr("id", ""), "42")
    })

    failed += runCase("router_optional_param_absent", { =>
        let r = Router().get("/users/:id?", { ctx, _ => () })
        let ctx = Context()
        let res = r.lookup("GET", "/users", ctx)
        checkTrue(match (res) { case DispatchResult.Matched(_) => true; case _ => false })
        checkTrue(ctx.param("id").isNone())
    })

    failed += runCase("router_optional_param_multi_combination", { =>
        let r = Router().get("/a/:x?/b/:y?", { ctx, _ => () })
        // 4 种组合全部命中
        for (p in ["/a/1/b/2", "/a/1/b", "/a/b/2", "/a/b"]) {
            let ctx = Context()
            let res = r.lookup("GET", p, ctx)
            checkTrue(match (res) { case DispatchResult.Matched(_) => true; case _ => false })
        }
        // 参数注入正确性
        let ctx = Context()
        let _ = r.lookup("GET", "/a/1/b/2", ctx)
        checkEq(ctx.paramOr("x", ""), "1")
        checkEq(ctx.paramOr("y", ""), "2")
    })

    failed += runCase("router_optional_param_too_many_throws", { =>
        var threw = false
        try {
            let r = Router().get("/a/:p1?/b/:p2?/c/:p3?/d/:p4?", { ctx, _ => () })
            let _ = r
        } catch (e: IllegalArgumentException) {
            threw = true
        }
        checkTrue(threw)
    })

    failed += runCase("router_named_trailing_wildcard", { =>
        let r = Router().get("/files/*path", { ctx, _ => () })
        let ctx = Context()
        let res = r.lookup("GET", "/files/a/b/c.txt", ctx)
        checkTrue(match (res) { case DispatchResult.Matched(_) => true; case _ => false })
        checkEq(ctx.paramOr("path", ""), "a/b/c.txt")
    })

    failed += runCase("router_mid_wildcard_single_segment", { =>
        // 中途 "*" 匹配单段，尾部 "*" 吞尾
        let r = Router().get("/v1/*/shop/*", { ctx, _ => () })
        let ctx = Context()
        let res = r.lookup("GET", "/v1/brand4/shop/blue/xs", ctx)
        checkTrue(match (res) { case DispatchResult.Matched(_) => true; case _ => false })
        checkEq(ctx.paramOr("tail", ""), "blue/xs")
        // 中途 "*" 不吞多段：/v1/a/b/shop/x 不应命中
        let ctx2 = Context()
        let res2 = r.lookup("GET", "/v1/a/b/shop/x", ctx2)
        checkTrue(match (res2) { case DispatchResult.NotFound => true; case _ => false })
    })

    failed += runCase("router_mid_named_wildcard_captures_segment", { =>
        let r = Router().get("/v1/*ver/shop/*", { ctx, _ => () })
        let ctx = Context()
        let res = r.lookup("GET", "/v1/v2/shop/blue/xs", ctx)
        checkTrue(match (res) { case DispatchResult.Matched(_) => true; case _ => false })
        checkEq(ctx.paramOr("ver", ""), "v2")
        checkEq(ctx.paramOr("tail", ""), "blue/xs")
    })

    failed += runCase("router_group_prefix_mount", { =>
        let r = Router()
        r.group("/api").get("/users", { ctx, _ => ctx.body("api-users") })
        let ctx = Context()
        let res = r.lookup("GET", "/api/users", ctx)
        checkTrue(match (res) { case DispatchResult.Matched(_) => true; case _ => false })
        match (res) {
            case DispatchResult.Matched(h) => h(ctx, { => () })
            case _ => ()
        }
        checkEq(ctx._peekBody(), "api-users")
        // 未挂前缀的原路径不应命中
        let ctx2 = Context()
        let res2 = r.lookup("GET", "/users", ctx2)
        checkTrue(match (res2) { case DispatchResult.NotFound => true; case _ => false })
    })

    failed += runCase("router_group_nested_with_middleware", { =>
        let r = Router()
        let trace = ArrayList<String>()
        let log1: Middleware = { ctx: Context, next: () -> Unit =>
            trace.add("m1-pre")
            next()
            trace.add("m1-post")
        }
        let log2: Middleware = { ctx: Context, next: () -> Unit =>
            trace.add("m2-pre")
            next()
            trace.add("m2-post")
        }
        r.group("/api", mw: [log1])
            .group("/v1", mw: [log2])
            .get("/list", { ctx, _ => trace.add("handler") })
        let ctx = Context()
        let res = r.lookup("GET", "/api/v1/list", ctx)
        checkTrue(match (res) { case DispatchResult.Matched(_) => true; case _ => false })
        match (res) {
            case DispatchResult.Matched(h) => h(ctx, { => () })
            case _ => ()
        }
        // 洋葱序：父组中间件在最外层
        checkEq(String.join(trace.toArray(), delimiter: ","), "m1-pre,m2-pre,handler,m2-post,m1-post")
    })

    failed += runCase("router_named_route_urlFor", { =>
        let r = Router()
            .get("/users/:id", { ctx, _ => () }, name: "user_detail")
            .get("/files/*path", { ctx, _ => () }, name: "file_tail")
            .get("/docs/:lang?/page", { ctx, _ => () }, name: "doc_page")
        // 普通参数替换
        let params1 = HashMap<String, String>()
        params1["id"] = "42"
        checkEq(r.urlFor("user_detail", params: params1).getOrThrow(), "/users/42")
        // 命名通配符替换
        let params2 = HashMap<String, String>()
        params2["path"] = "a/b.txt"
        checkEq(r.urlFor("file_tail", params: params2).getOrThrow(), "/files/a/b.txt")
        // 可选参数：提供则保留，缺省则跳过
        let params3 = HashMap<String, String>()
        params3["lang"] = "zh"
        checkEq(r.urlFor("doc_page", params: params3).getOrThrow(), "/docs/zh/page")
        checkEq(r.urlFor("doc_page").getOrThrow(), "/docs/page")
        // 必填参数缺失 -> None；未知名 -> None
        checkTrue(r.urlFor("user_detail").isNone())
        checkTrue(r.urlFor("no_such_name").isNone())
    })

    // ============  urldecode / cookies ============

    failed += runCase("urldecode_basic", { =>
        checkEq(urlDecode("hello"), "hello")
        checkEq(urlDecode("hello+world"), "hello world")
        checkEq(urlDecode("a%20b"), "a b")
    })

    failed += runCase("urldecode_percent_encoded_unicode", { =>
        checkEq(urlDecode("%E4%B8%AD%E6%96%87"), "中文")
    })

    failed += runCase("urldecode_invalid_percent_passes_through", { =>
        checkEq(urlDecode("abc%"), "abc%")
        checkEq(urlDecode("abc%ZZ"), "abc%ZZ")
    })

    failed += runCase("urldecode_empty", { =>
        checkEq(urlDecode(""), "")
    })

    failed += runCase("cookies_get_returns_none_without_http", { =>
        let ctx = Context()
        checkTrue(ctx.cookies.get("sid").isNone())
    })

    failed += runCase("cookies_set_writes_header", { =>
        let ctx = Context()
        ctx.cookies.set("sid", "abc123")
        // : legacy set() defaults to CookieOptions() -> adds Path=/
        checkEq(ctx._peekHeaders()["Set-Cookie"], "sid=abc123; Path=/")
    })

    failed += runCase("cookies_set_multiple_accumulates", { =>
        let ctx = Context()
        ctx.cookies.set("a", "1")
        ctx.cookies.set("b", "2")
        // stdx overwrites same-named headers; we accumulate into a
        // comma-separated single Set-Cookie line.  adds Path=/ to each.
        checkEq(ctx._peekHeaders()["Set-Cookie"], "a=1; Path=/, b=2; Path=/")
    })

    failed += runCase("context_body_bytes_empty_when_no_http", { =>
        let ctx = Context()
        checkEq(ctx.bodyBytes().size, 0)
        checkEq(ctx._peekRawBody().size, 0)
    })

    // ============  mimeOf ============

    failed += runCase("mime_known_image", { =>
        checkEq(mimeOf("a.png"), "image/png")
        checkEq(mimeOf("a.jpg"), "image/jpeg")
        checkEq(mimeOf("a.jpeg"), "image/jpeg")
        checkEq(mimeOf("a.gif"), "image/gif")
        checkEq(mimeOf("a.webp"), "image/webp")
        checkEq(mimeOf("a.svg"), "image/svg+xml")
    })

    failed += runCase("mime_known_video_audio_text", { =>
        checkEq(mimeOf("clip.mp4"), "video/mp4")
        checkEq(mimeOf("clip.webm"), "video/webm")
        checkEq(mimeOf("song.mp3"), "audio/mpeg")
        checkEq(mimeOf("page.html"), "text/html; charset=utf-8")
        checkEq(mimeOf("page.css"), "text/css; charset=utf-8")
        checkEq(mimeOf("page.js"), "application/javascript; charset=utf-8")
    })

    failed += runCase("mime_case_insensitive_and_fallback", { =>
        checkEq(mimeOf("PIC.PNG"), "image/png")
        checkEq(mimeOf("PIC.Jpeg"), "image/jpeg")
        checkEq(mimeOf("data.xyz123"), "application/octet-stream")
        checkEq(mimeOf("README"), "application/octet-stream")
        checkEq(mimeOf("foo."), "application/octet-stream")
        checkEq(mimeOf(".gitignore"), "application/octet-stream")
    })

    failed += runCase("mime_strips_dirs", { =>
        checkEq(mimeOf("path/to/pic.png"), "image/png")
        checkEq(mimeOf("v1.2/file"), "application/octet-stream")
    })

    // ============  Context binary body ============

    failed += runCase("context_body_bytes_kind_dispatch", { =>
        let ctx = Context()
        checkEq(ctx._peekBodyKind(), 0)
        ctx.body("hello")
        checkEq(ctx._peekBodyKind(), 0)
        let payload = Array<UInt8>(3, { i => UInt8(i + 1) })
        ctx.body(payload)
        checkEq(ctx._peekBodyKind(), 1)
        checkEq(ctx._peekBodyBytes().size, 3)
        ctx.body("goodbye")
        checkEq(ctx._peekBodyKind(), 0)
    })

    failed += runCase("context_body_bytes_overrides_text", { =>
        let ctx = Context()
        ctx.body("never sent")
        let payload = Array<UInt8>(5, { _ => UInt8(0xFF) })
        ctx.body(payload)
        checkEq(ctx._peekBodyKind(), 1)
    })

    // ============  hasTraversal ============

    failed += runCase("traversal_blocks_dotdot_segments", { =>
        checkTrue(hasTraversal("../etc/passwd"))
        checkTrue(hasTraversal("a/../../b"))
        checkTrue(hasTraversal("a/.."))
        checkTrue(hasTraversal(".."))
    })

    failed += runCase("traversal_blocks_backslashes", { =>
        checkTrue(hasTraversal("a\\b"))
        checkTrue(hasTraversal("\\foo"))
    })

    failed += runCase("traversal_allows_normal_paths", { =>
        checkTrue(!hasTraversal("a/b/c.png"))
        checkTrue(!hasTraversal("logo.svg"))
        checkTrue(!hasTraversal("path.with.dots/file"))
        checkTrue(!hasTraversal(""))
    })

    failed += runCase("mime_video_types_present", { =>
        checkEq(mimeOf("movie.mp4"), "video/mp4")
        checkEq(mimeOf("movie.mov"), "video/quicktime")
    })

    // ============  Range parser ============

    failed += runCase("range_closed_form", { =>
        let r = parseRange("bytes=0-499", 1000)
        checkTrue(match (r) { case RangeResult.Satisfiable(s) => s.start == 0 && s.end == 499; case _ => false })
    })

    failed += runCase("range_open_end", { =>
        let r = parseRange("bytes=500-", 1000)
        checkTrue(match (r) { case RangeResult.Satisfiable(s) => s.start == 500 && s.end == 999; case _ => false })
    })

    failed += runCase("range_suffix_form", { =>
        let r = parseRange("bytes=-500", 1000)
        checkTrue(match (r) { case RangeResult.Satisfiable(s) => s.start == 500 && s.end == 999; case _ => false })
        let r2 = parseRange("bytes=-1500", 1000)
        checkTrue(match (r2) { case RangeResult.Satisfiable(s) => s.start == 0 && s.end == 999; case _ => false })
    })

    failed += runCase("range_end_clipped_to_size", { =>
        let r = parseRange("bytes=0-9999", 1000)
        checkTrue(match (r) { case RangeResult.Satisfiable(s) => s.start == 0 && s.end == 999; case _ => false })
    })

    failed += runCase("range_unsatisfiable_start_past_end", { =>
        let r = parseRange("bytes=1000-", 1000)
        checkTrue(match (r) { case RangeResult.Unsatisfiable => true; case _ => false })
    })

    failed += runCase("range_malformed_reversed_bounds", { =>
        let r = parseRange("bytes=200-100", 1000)
        checkTrue(match (r) { case RangeResult.Malformed => true; case _ => false })
    })

    failed += runCase("range_malformed_multi_range", { =>
        let r = parseRange("bytes=0-100,200-300", 1000)
        checkTrue(match (r) { case RangeResult.Malformed => true; case _ => false })
    })

    failed += runCase("range_malformed_no_unit", { =>
        let r = parseRange("0-499", 1000)
        checkTrue(match (r) { case RangeResult.Malformed => true; case _ => false })
    })

    failed += runCase("range_zero_byte_resource", { =>
        let r = parseRange("bytes=0-0", 0)
        checkTrue(match (r) { case RangeResult.Unsatisfiable => true; case _ => false })
    })

    failed += runCase("range_length_helper", { =>
        let s = RangeSpec(10, 19)
        checkEq(s.length(), 10)
    })

    failed += runCase("format_content_range_normal", { =>
        let s = RangeSpec(0, 499)
        checkEq(formatContentRange(s, 1000), "bytes 0-499/1000")
    })

    failed += runCase("format_content_range_unsatisfiable", { =>
        checkEq(formatUnsatisfiableContentRange(1000), "bytes */1000")
    })

    // ============  ETag ============

    failed += runCase("etag_make_quoted_size", { =>
        checkEq(makeETag(0), "\"0\"")
        checkEq(makeETag(1024), "\"1024\"")
        checkEq(makeETag(123456789), "\"123456789\"")
    })

    failed += runCase("etag_matches_exact", { =>
        let et = makeETag(1024)
        checkTrue(etagMatches("\"1024\"", et))
    })

    failed += runCase("etag_matches_wildcard", { =>
        checkTrue(etagMatches("*", makeETag(1024)))
        checkTrue(etagMatches("  *  ", makeETag(7)))
    })

    failed += runCase("etag_matches_in_list", { =>
        let et = makeETag(1024)
        checkTrue(etagMatches("\"old1\", \"1024\", \"old2\"", et))
        checkTrue(etagMatches("\"999\", W/\"1024\"", et))
    })

    failed += runCase("etag_does_not_match_other_size", { =>
        let et = makeETag(1024)
        checkTrue(!etagMatches("\"2048\"", et))
        checkTrue(!etagMatches("", et))
    })

    failed += runCase("etag_parse_tags_strips_weak_prefix", { =>
        let tags = parseIfNoneMatchTags("W/\"42\", \"43\"")
        checkEq(tags.size, 2)
        checkEq(tags[0], "\"42\"")
        checkEq(tags[1], "\"43\"")
    })

    // ---------- : Cookies full options ----------
    failed += runCase("cookies_set_with_full_options", { =>
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
        checkTrue(hdr.contains("sid=x"))
        checkTrue(hdr.contains("Max-Age=3600"))
        checkTrue(hdr.contains("Path=/admin"))
        checkTrue(hdr.contains("Domain=example.com"))
        checkTrue(hdr.contains("HttpOnly"))
        checkTrue(hdr.contains("Secure"))
        checkTrue(hdr.contains("SameSite=Strict"))
    })

    failed += runCase("cookies_set_default_options_omit_attrs", { =>
        let ctx = Context()
        let opts = CookieOptions()
        ctx.cookies.set("k", "v", opts)
        checkEq(ctx._peekHeaders()["Set-Cookie"], "k=v; Path=/")
    })

    // ---------- : bodyParser smoke ----------
    failed += runCase("bodyparser_runs_next_with_no_http", { =>
        // Without an http context, the parser cannot read the request
        // stream but should still call next() so the chain continues.
        let ctx = Context()
        let mw = bodyParser()
        let called = Array<Bool>(1, { _ => false })
        mw(ctx, { => called[0] = true })
        checkEq(called[0], true)
    })

    // ---------- : logger formatter ----------
    failed += runCase("logger_formatter_with_id", { =>
        let ctx = Context()
        ctx._id = "abc123"
        ctx.status(404)
        let line = defaultLoggerFormatter(ctx, 12)
        checkTrue(line.contains("abc123"))
        checkTrue(line.contains("404"))
        checkTrue(line.contains("12ms"))
    })

    failed += runCase("logger_formatter_dash_when_no_id", { =>
        let ctx = Context()
        let line = defaultLoggerFormatter(ctx, 1)
        checkTrue(line.startsWith("- "))
    })

    // 结构化 JSON 日志
    failed += runCase("json_log_formatter_emits_structured_fields", { =>
        let ctx = Context()
        ctx._id = "req-1"
        ctx.status(201)
        let line = jsonLogFormatter(ctx, 37)
        checkTrue(line.contains("\"id\":\"req-1\""))
        checkTrue(line.contains("\"status\":201"))
        checkTrue(line.contains("\"elapsed_ms\":37"))
        checkTrue(line.contains("\"method\":"))
        checkTrue(line.contains("\"path\":"))
    })

    failed += runCase("json_log_formatter_escapes_quotes", { =>
        let ctx = Context()
        // 无 http 时 path 为 ""，此处验证 jsonLogFormatter 走 JsonBuilder
        // 自动转义：直接构造含引号的场景不适用（path 来自 request），
        // 改为验证输出是合法 JSON（可被 JsonValue.fromStr 解析）。
        let line = jsonLogFormatter(ctx, 5)
        let parsed = JsonValue.fromStr(line)   // 解析失败会抛异常
        let obj = parsed.asObject()
        checkTrue(obj.containsKey("status"))
        checkTrue(obj.containsKey("elapsed_ms"))
    })

    failed += runCase("file_log_writer_appends_to_file", { =>
        let p = "build/test_access.log"
        // 清理旧文件（remove 是 std.fs 顶层函数）
        try { remove(p) } catch (e: Exception) { }
        let w = fileLogWriter(p)
        w("first line")
        w("second line")
        let bytes = File.readFrom(p)
        let content = String.fromUtf8(bytes)
        checkTrue(content.contains("first line"))
        checkTrue(content.contains("second line"))
        try { remove(p) } catch (e: Exception) { }
    })

    // ---------- : requestId helper ----------
    failed += runCase("random_id_is_hex_of_requested_length", { =>
        let id = randomId(8)
        checkEq(id.size, 16)
        for (c in id) {
            let ok = (c >= UInt8(0x30) && c <= UInt8(0x39)) || (c >= UInt8(0x61) && c <= UInt8(0x66))
            if (!ok) { checkTrue(false) }
        }
    })

    // ---------- : CORS resolveOrigin ----------
    failed += runCase("cors_resolve_origin_wildcard", { =>
        let ctx = Context()
        checkEq(resolveOrigin(ctx, "*"), "*")
    })

    failed += runCase("cors_resolve_origin_fixed", { =>
        let ctx = Context()
        checkEq(resolveOrigin(ctx, "https://app.example.com"), "https://app.example.com")
    })

    // jsonx 安全访问器 + JsonBuilder
    failed += runCase("jsonx_getStr_hit", { =>
        let o = JsonObject()
        o.put("name", JsonString("alice"))
        match (jsonGetStr(o, "name")) {
            case Some(s) => checkEq(s, "alice")
            case None => checkTrue(false)
        }
    })

    failed += runCase("jsonx_getStr_missing", { =>
        let o = JsonObject()
        match (jsonGetStr(o, "nope")) {
            case Some(_) => checkTrue(false)
            case None => checkTrue(true)
        }
    })

    failed += runCase("jsonx_getStr_wrong_type", { =>
        let o = JsonObject()
        o.put("age", JsonInt(30))
        match (jsonGetStr(o, "age")) {
            case Some(_) => checkTrue(false)
            case None => checkTrue(true)
        }
    })

    failed += runCase("jsonx_getInt64_hit", { =>
        let o = JsonObject()
        o.put("age", JsonInt(30))
        match (jsonGetInt64(o, "age")) {
            case Some(n) => checkEq(n, 30)
            case None => checkTrue(false)
        }
    })

    failed += runCase("jsonx_getInt64_wrong_type", { =>
        let o = JsonObject()
        o.put("name", JsonString("x"))
        match (jsonGetInt64(o, "name")) {
            case Some(_) => checkTrue(false)
            case None => checkTrue(true)
        }
    })

    failed += runCase("jsonx_getBool_hit", { =>
        let o = JsonObject()
        o.put("ok", JsonBool(true))
        match (jsonGetBool(o, "ok")) {
            case Some(b) => checkEq(b, true)
            case None => checkTrue(false)
        }
    })

    failed += runCase("jsonx_getArray_hit", { =>
        let o = JsonObject()
        o.put("tags", JsonArray())
        match (jsonGetArray(o, "tags")) {
            case Some(a) => checkEq(a.size(), 0)
            case None => checkTrue(false)
        }
    })

    failed += runCase("jsonx_jsonMissing_reports_first", { =>
        let o = JsonObject()
        o.put("a", JsonString("1"))
        match (jsonMissing(o, ["a", "b", "c"])) {
            case Some(m) => checkEq(m, "b")
            case None => checkTrue(false)
        }
    })

    failed += runCase("jsonx_jsonMissing_none_when_all_present", { =>
        let o = JsonObject()
        o.put("a", JsonString("1"))
        o.put("b", JsonString("2"))
        match (jsonMissing(o, ["a", "b"])) {
            case Some(_) => checkTrue(false)
            case None => checkTrue(true)
        }
    })

    failed += runCase("jsonx_builder_escapes_and_serializes", { =>
        let j = JsonBuilder()
            .put("title", "he said \"hi\"")
            .putInt("count", 3)
            .putBool("ok", true)
            .build()
        checkTrue(j.contains("\\\""))
        checkTrue(j.contains("\"count\":3"))
        checkTrue(j.contains("\"ok\":true"))
    })

    failed += runCase("jsonx_builder_nested_object", { =>
        let inner = JsonObject()
        inner.put("x", JsonInt(1))
        let j = JsonBuilder().putObject("meta", inner).build()
        checkTrue(j.contains("\"meta\":{\"x\":1}"))
    })

    // security 密码哈希 + 签名
    failed += runCase("security_hash_verify_success", { =>
        let stored = hashPassword("secret123", "abc", 10)
        checkEq(verifyPassword("secret123", stored), true)
    })

    failed += runCase("security_hash_verify_wrong_password", { =>
        let stored = hashPassword("secret123", "abc", 10)
        checkEq(verifyPassword("wrong", stored), false)
    })

    failed += runCase("security_hash_self_describing_format", { =>
        let stored = hashPassword("pw", "salt", 5)
        let parts = stored.split("$", 3, removeEmpty: false)
        checkEq(parts.size, 3)
        checkEq(parts[0], "salt")
        checkEq(parts[1], "5")
    })

    failed += runCase("security_sign_roundtrip", { =>
        let signed = signValue("session-123", "secret")
        match (verifySigned(signed, "secret")) {
            case Some(v) => checkEq(v, "session-123")
            case None => checkTrue(false)
        }
    })

    failed += runCase("security_sign_tampered_rejected", { =>
        let signed = signValue("session-123", "secret")
        match (signed.lastIndexOf(".")) {
            case Some(dot) =>
                let tampered = "session-999" + signed[dot..]
                match (verifySigned(tampered, "secret")) {
                    case Some(_) => checkTrue(false)
                    case None => checkTrue(true)
                }
            case None => checkTrue(false)
        }
    })

    failed += runCase("security_sign_wrong_secret_rejected", { =>
        let signed = signValue("v", "secret-a")
        match (verifySigned(signed, "secret-b")) {
            case Some(_) => checkTrue(false)
            case None => checkTrue(true)
        }
    })

    failed += runCase("security_randomHex_length", { =>
        checkEq(randomHex(16).size, 32)
    })

    // session
    failed += runCase("session_create_exists", { =>
        let store = SessionStore()
        let id = store.create()
        checkEq(store.exists(id), true)
    })

    failed += runCase("session_set_get_roundtrip", { =>
        let store = SessionStore()
        let id = store.create()
        store.set(id, "user", "alice")
        match (store.get(id, "user")) {
            case Some(v) => checkEq(v, "alice")
            case None => checkTrue(false)
        }
    })

    failed += runCase("session_destroy", { =>
        let store = SessionStore()
        let id = store.create()
        store.destroy(id)
        checkEq(store.exists(id), false)
    })

    // util 内置解析器
    failed += runCase("util_parseInt64OrNone_valid", { =>
        match (parseInt64OrNone("42")) {
            case Some(n) => checkEq(n, 42)
            case None => checkTrue(false)
        }
    })

    failed += runCase("util_parseInt64OrNone_invalid", { =>
        match (parseInt64OrNone("abc")) {
            case Some(_) => checkTrue(false)
            case None => checkTrue(true)
        }
    })

    failed += runCase("util_parseInt64Or_default", { =>
        checkEq(parseInt64Or("abc", 7), 7)
        checkEq(parseInt64Or("12", 7), 12)
    })

    failed += runCase("util_parseUInt16OrNone_valid", { =>
        match (parseUInt16OrNone("8080")) {
            case Some(n) => checkEq(n, 8080)
            case None => checkTrue(false)
        }
    })

    failed += runCase("util_parseBoolOrNone", { =>
        checkEq(parseBoolOrNone("true"), Some(true))
        checkEq(parseBoolOrNone("FALSE"), Some(false))
        match (parseBoolOrNone("yes")) {
            case Some(_) => checkTrue(false)
            case None => checkTrue(true)
        }
    })

    // 多 Range
    failed += runCase("range_multi_satisfiable", { =>
        match (parseRanges("bytes=0-1,4-5", 100)) {
            case RangesResult.Satisfiable(specs) => checkEq(specs.size, 2)
            case _ => checkTrue(false)
        }
    })

    failed += runCase("range_multi_single_still_works", { =>
        match (parseRanges("bytes=0-1", 100)) {
            case RangesResult.Satisfiable(specs) => checkEq(specs.size, 1)
            case _ => checkTrue(false)
        }
    })

    failed += runCase("range_multi_unsatisfiable", { =>
        match (parseRanges("bytes=999-1000", 100)) {
            case RangesResult.Unsatisfiable => checkTrue(true)
            case _ => checkTrue(false)
        }
    })

    failed += runCase("range_multi_malformed", { =>
        match (parseRanges("bytes=abc", 100)) {
            case RangesResult.Malformed => checkTrue(true)
            case _ => checkTrue(false)
        }
    })

    failed += runCase("range_multipart_body_contains_boundary_and_range", { =>
        let bytes = Array<UInt8>(10, { i => UInt8(i) })
        let specs = Array<RangeSpec>(2, { _ => RangeSpec(0, 1) })
        specs[0] = RangeSpec(0, 1)
        specs[1] = RangeSpec(4, 5)
        let body = formatMultipartBody(specs, bytes, "text/plain", "BND", 10)
        let s = String.fromUtf8(body)
        checkTrue(s.contains("--BND"))
        checkTrue(s.contains("Content-Range: bytes 0-1/10"))
        checkTrue(s.contains("Content-Range: bytes 4-5/10"))
        checkTrue(s.contains("--BND--"))
    })

    // compress (gzip)
    failed += runCase("compress_gzip_compresses_repetitive_data", { =>
        let big = Array<UInt8>(1000, { _ => UInt8(0x61) })
        let gz = gzipCompress(big)
        checkTrue(gz.size > 0)
        checkTrue(gz.size < big.size)
    })

    failed += runCase("compress_gzip_empty_input", { =>
        checkEq(gzipCompress(Array<UInt8>()).size, 0)
    })

    failed += runCase("compress_isCompressibleType", { =>
        checkEq(isCompressibleType("text/html; charset=utf-8"), true)
        checkEq(isCompressibleType("application/json"), true)
        checkEq(isCompressibleType("image/png"), false)
    })

    // multipart
    failed += runCase("multipart_extract_boundary", { =>
        checkEq(extractBoundary("multipart/form-data; boundary=abc123"), "abc123")
        checkEq(extractBoundary("multipart/form-data; boundary=\"xyz\""), "xyz")
    })

    failed += runCase("multipart_parse_text_field", { =>
        let body = "--BND\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nhello world\r\n--BND--\r\n"
        let parts = parseMultipart(body.toArray(), "BND")
        checkEq(parts.size, 1)
        checkEq(parts[0].name, "title")
        checkEq(parts[0].text(), "hello world")
    })

    failed += runCase("multipart_parse_file_field", { =>
        let body = "--BND\r\nContent-Disposition: form-data; name=\"upload\"; filename=\"a.txt\"\r\nContent-Type: text/plain\r\n\r\nfile bytes here\r\n--BND--\r\n"
        let parts = parseMultipart(body.toArray(), "BND")
        checkEq(parts.size, 1)
        checkEq(parts[0].name, "upload")
        checkEq(parts[0].filename, "a.txt")
        checkEq(parts[0].text(), "file bytes here")
    })

    failed += runCase("multipart_parse_multiple_parts", { =>
        let body = "--BND\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n--BND\r\nContent-Disposition: form-data; name=\"b\"\r\n\r\n2\r\n--BND--\r\n"
        let parts = parseMultipart(body.toArray(), "BND")
        checkEq(parts.size, 2)
        checkEq(parts[0].name, "a")
        checkEq(parts[1].name, "b")
    })

    // 二进制载荷字节级解析 —— 全字节范围（含非法
    // UTF-8 序列）不损坏。旧实现 String.fromUtf8(body) 会抛
    // "Invalid utf8 byte sequence"（整个请求 500）。
    failed += runCase("multipart_parse_binary_payload_safe", { =>
        let head = "--BND\r\nContent-Disposition: form-data; name=\"file\"; filename=\"bin.dat\"\r\nContent-Type: application/octet-stream\r\n\r\n"
        let buf = ArrayList<UInt8>()
        for (b in head.toArray()) {
            buf.add(b)
        }
        // 0x00..0xFF 循环两轮（512 字节，含非法 UTF-8 序列）
        var round: Int64 = 0
        while (round < 2) {
            var v: Int64 = 0
            while (v < 256) {
                buf.add(UInt8(v))
                v += 1
            }
            round += 1
        }
        let tail = "\r\n--BND--\r\n"
        for (b in tail.toArray()) {
            buf.add(b)
        }
        let parts = parseMultipart(buf.toArray(), "BND")
        checkEq(parts.size, 1)
        checkEq(parts[0].name, "file")
        checkEq(parts[0].filename, "bin.dat")
        checkEq(parts[0].data.size, 512)
        checkEq(parts[0].data[0], UInt8(0))
        checkEq(parts[0].data[255], UInt8(255))
        checkEq(parts[0].data[256], UInt8(0))
        checkEq(parts[0].data[511], UInt8(255))
    })

    // Last-Modified
    failed += runCase("lastmod_fileLastModified_returns_some", { =>
        match (fileLastModified("./public_blog/index.html")) {
            case Some(_) => checkTrue(true)
            case None => checkTrue(false)
        }
    })

    failed += runCase("lastmod_fileLastModified_missing_returns_none", { =>
        match (fileLastModified("./public_blog/does_not_exist.xyz")) {
            case Some(_) => checkTrue(false)
            case None => checkTrue(true)
        }
    })

    failed += runCase("lastmod_formatHttpDate_contains_gmt", { =>
        match (fileLastModified("./public_blog/index.html")) {
            case Some(mt) =>
                let s = formatHttpDate(mt)
                checkTrue(s.contains(" GMT"))
                checkTrue(s.contains(", "))
            case None => checkTrue(false)
        }
    })

    failed += runCase("lastmod_lastModifiedMatches_exact", { =>
        checkEq(lastModifiedMatches("Wed, 09 Sep 2026 19:33:49 GMT", "Wed, 09 Sep 2026 19:33:49 GMT"), true)
        checkEq(lastModifiedMatches("Thu, 10 Sep 2026 00:00:00 GMT", "Wed, 09 Sep 2026 19:33:49 GMT"), false)
    })

    failed += runCase("config_parse_key_value", { =>
        let c = parseConfigText("port=3000\nhost=localhost")
        checkEq(c.getOr("port", ""), "3000")
        checkEq(c.getOr("host", ""), "localhost")
    })

    failed += runCase("config_parse_ignores_comment_and_blank", { =>
        let c = parseConfigText("# comment\n\nport=8080\n   \n# another\nname=app")
        checkEq(c.has("comment"), false)
        checkEq(c.size(), 2)
        checkEq(c.getOr("port", ""), "8080")
        checkEq(c.getOr("name", ""), "app")
    })

    failed += runCase("config_value_with_equals", { =>
        let c = parseConfigText("url=http://x.com?a=1&b=2")
        checkEq(c.getOr("url", ""), "http://x.com?a=1&b=2")
    })

    failed += runCase("config_typed_accessors", { =>
        let c = Config()
        c.set("port", "3000")
        c.set("debug", "true")
        c.set("ratio", "1.5")
        checkEq(c.getIntOr("port", 0), 3000)
        checkEq(c.getBoolOr("debug", false), true)
        match (c.getFloat("ratio")) {
            case Some(f) => checkTrue(f > 1.4)
            case None => throw Exception("expected ratio")
        }
    })

    failed += runCase("config_get_or_default", { =>
        let c = Config()
        checkEq(c.getOr("missing", "fallback"), "fallback")
        checkEq(c.getIntOr("missing", 42), 42)
        checkEq(c.getBoolOr("missing", true), true)
    })

    failed += runCase("static_cache_put_get", { =>
        let cache = StaticCache()
        let bytes = Array<UInt8>(3, { i => UInt8(i + 1) })
        cache.put("/a/b.txt", bytes)
        match (cache.get("/a/b.txt")) {
            case Some(cached) => checkEq(cached.size, 3)
            case None => throw Exception("expected cached")
        }
        match (cache.get("/missing")) {
            case Some(_) => throw Exception("expected miss")
            case None => checkTrue(true)
        }
    })

    // ============  TLS scenarios ============
    failed += runCase("serveTls_rejects_garbage_pem_no_silent_fallback", { =>
        // 核心要求：PEM 无法解析时必须抛异常，绝不静默降级为明文 HTTP
        let app = QingZhouApp()
        var threw = false
        try {
            app.serveTls(65530, "not-a-cert", "not-a-key")
        } catch (e: Exception) {
            threw = true
        }
        checkTrue(threw)
    })

    failed += runCase("x509_cert_decode_rejects_garbage", { =>
        var threw = false
        try {
            X509Certificate.decodeFromPem("not-a-pem")
        } catch (e: Exception) {
            threw = true
        }
        checkTrue(threw)
    })

    failed += runCase("rsa_privatekey_decode_rejects_garbage", { =>
        var threw = false
        try {
            RSAPrivateKey.decodeFromPem("not-a-pem")
        } catch (e: Exception) {
            threw = true
        }
        checkTrue(threw)
    })

    // ============  JWT scenarios ============
    failed += runCase("jwt_issue_is_three_part_standard", { =>
        let t = jwtIssue("42", "secret", 3600)
        checkTrue(t.split(".", 3, removeEmpty: false).size == 3)
    })

    failed += runCase("jwt_verify_roundtrip_returns_sub", { =>
        let t = jwtIssue("42", "secret", 3600)
        match (jwtVerify(t, "secret")) {
            case Some(sub) => checkTrue(sub == "42")
            case None => checkTrue(false)
        }
    })

    failed += runCase("jwt_verify_rejects_tampered_payload", { =>
        let t = jwtIssue("42", "secret", 3600)
        let parts = t.split(".", 3, removeEmpty: false)
        let tampered = parts[0] + "." + parts[1] + "X" + "." + parts[2]
        checkTrue(jwtVerify(tampered, "secret").isNone())
    })

    failed += runCase("jwt_verify_rejects_wrong_secret", { =>
        let t = jwtIssue("42", "secret", 3600)
        checkTrue(jwtVerify(t, "other-secret").isNone())
    })

    failed += runCase("jwt_verify_rejects_expired", { =>
        let t = jwtIssue("42", "secret", -60)   // 60 秒前已过期
        checkTrue(jwtVerify(t, "secret").isNone())
    })

    failed += runCase("jwt_verify_rejects_malformed", { =>
        checkTrue(jwtVerify("not-a-jwt", "secret").isNone())
        checkTrue(jwtVerify("a.b", "secret").isNone())
    })

    // ============  RateLimit / SecurityHeaders scenarios ============
    failed += runCase("ratelimit_allows_under_limit", { =>
        let mw = rateLimit(5, 60)
        let callCount = ArrayList<String>()
        mw(Context(), { => callCount.add("x") })
        mw(Context(), { => callCount.add("x") })
        mw(Context(), { => callCount.add("x") })
        checkEq(Int64(callCount.size), Int64(3))
    })

    failed += runCase("ratelimit_blocks_over_limit", { =>
        let mw = rateLimit(2, 60)
        let callCount = ArrayList<String>()
        mw(Context(), { => callCount.add("x") })
        mw(Context(), { => callCount.add("x") })
        mw(Context(), { => callCount.add("x") })   // 第 3 次应被限流短路
        checkEq(Int64(callCount.size), Int64(2))
    })

    failed += runCase("securityheaders_sets_default_headers", { =>
        let ctx = Context()
        securityHeaders()(ctx, { => () })
        let headers = ctx._peekHeaders()
        match (headers.get("X-Content-Type-Options")) {
            case Some(v) => checkEq(v, "nosniff")
            case None => checkTrue(false)
        }
        match (headers.get("X-Frame-Options")) {
            case Some(v) => checkEq(v, "DENY")
            case None => checkTrue(false)
        }
    })

    failed += runCase("securityheaders_optional_csp", { =>
        let opts = SecurityHeadersOptions()
        opts.contentSecurityPolicy = "default-src 'self'"
        let ctx = Context()
        securityHeadersOpts(opts)(ctx, { => () })
        match (ctx._peekHeaders().get("Content-Security-Policy")) {
            case Some(v) => checkEq(v, "default-src 'self'")
            case None => checkTrue(false)
        }
    })

    failed += runCase("context_remote_addr_empty_without_http", { =>
        let ctx = Context()
        checkEq(ctx.remoteAddr(), "")
        checkEq(ctx.remoteIp(), "")
    })

    // ============  CircuitBreaker scenarios ============
    failed += runCase("circuit_opens_after_max_failures", { =>
        let cb = CircuitBreaker(3, 60)
        cb.onFailure()
        cb.onFailure()
        checkEq(cb.stateName(), "closed")
        cb.onFailure()
        checkEq(cb.stateName(), "open")
        checkTrue(!cb.isAllowed())
    })

    failed += runCase("circuit_success_resets", { =>
        let cb = CircuitBreaker(3, 60)
        cb.onFailure()
        cb.onFailure()
        cb.onSuccess()
        checkEq(cb.stateName(), "closed")
    })

    failed += runCase("circuit_half_open_after_cooldown", { =>
        let cb = CircuitBreaker(2, 0)   // 冷却 0 秒，立即可试探
        cb.onFailure()
        cb.onFailure()
        checkEq(cb.stateName(), "open")
        checkTrue(cb.isAllowed())
        checkEq(cb.stateName(), "half-open")
    })

    failed += runCase("circuit_half_open_failure_reopens", { =>
        let cb = CircuitBreaker(2, 0)
        cb.onFailure()
        cb.onFailure()
        checkTrue(cb.isAllowed())
        cb.onFailure()
        checkEq(cb.stateName(), "open")
    })

    failed += runCase("circuit_half_open_success_closes", { =>
        let cb = CircuitBreaker(2, 0)
        cb.onFailure()
        cb.onFailure()
        checkTrue(cb.isAllowed())
        cb.onSuccess()
        checkEq(cb.stateName(), "closed")
    })

    // ============  WebSocket scenarios ============
    failed += runCase("websocket_upgrade_none_without_http", { =>
        checkTrue(upgradeWebSocket(Context()).isNone())
    })

    // ============  Hybrid auth scenarios ============
    failed += runCase("resolve_identity_from_session", { =>
        let store = SessionStore()
        let sid = store.create()
        store.set(sid, "userId", "42")
        let ctx = Context()
        ctx.setState("sid", sid)
        match (resolveIdentity(ctx, "secret", store)) {
            case Some(u) => checkEq(u, "42")
            case None => checkTrue(false)
        }
    })

    failed += runCase("resolve_identity_none", { =>
        let store = SessionStore()
        checkTrue(resolveIdentity(Context(), "secret", store).isNone())
    })

    failed += runCase("require_session_blocks_without_sid", { =>
        let store = SessionStore()
        let calls = ArrayList<String>()
        requireSession("secret", store)(Context(), { => calls.add("x") })
        checkEq(Int64(calls.size), Int64(0))
    })

    // ============  HttpClient helper scenarios ============
    failed += runCase("http_isSuccess_boundaries", { =>
        checkTrue(isSuccess(UInt16(200)))
        checkTrue(isSuccess(UInt16(299)))
        checkTrue(!isSuccess(UInt16(199)))
        checkTrue(!isSuccess(UInt16(300)))
        checkTrue(!isSuccess(UInt16(404)))
    })

    // ============  回归（外部使用方 22 项反馈） ============

    // A-1：短读不是 EOF —— 每次只回 3 字节的流也要读全 10000 字节
    failed += runCase("readbodyupto_short_reads_not_truncated", { =>
        let payload = Array<UInt8>(10000, { i => UInt8(i % 251) })
        let out = ArrayList<UInt8>()
        let exceeded = readBodyUpTo(ShortReadStream(payload, 3), Int64.Max, out)
        checkTrue(!exceeded)
        checkEq(out.size, 10000)
        checkEq(out[0], payload[0])
        checkEq(out[9999], payload[9999])
    })

    failed += runCase("readbodyupto_reports_cap_exceeded", { =>
        let payload = Array<UInt8>(5000, { _ => UInt8(0x41) })
        let out = ArrayList<UInt8>()
        let exceeded = readBodyUpTo(ShortReadStream(payload, 100), 1000, out)
        checkTrue(exceeded)
        // 超限时 out 可能略超 cap（最后一个块整体进入），调用方整体丢弃
        checkTrue(out.size >= 1000)
    })

    failed += runCase("readbodyupto_empty_stream_is_eof", { =>
        let out = ArrayList<UInt8>()
        let exceeded = readBodyUpTo(ShortReadStream(Array<UInt8>(), 3), Int64.Max, out)
        checkTrue(!exceeded)
        checkEq(out.size, 0)
    })

    failed += runCase("context_body_bytes_capped_no_http", { =>
        let ctx = Context()
        match (ctx.bodyBytesCapped(10)) {
            case Some(b) => checkEq(b.size, 0)
            case None => checkTrue(false)
        }
    })

    // A-2：Content-Length 预检中间件（不消费流）
    failed += runCase("contentlengthlimit_passes_without_header", { =>
        let mw = contentLengthLimit(1024)
        let called = Array<Bool>(1, { _ => false })
        mw(Context(), { => called[0] = true })
        checkEq(called[0], true)
    })

    failed += runCase("contentlengthlimit_reject_indeterminate_411", { =>
        let opts = ContentLengthLimitOptions()
        opts.onIndeterminate = IndeterminatePolicy.Reject
        let mw = contentLengthLimit(opts)
        let called = Array<Bool>(1, { _ => false })
        let ctx = Context()
        mw(ctx, { => called[0] = true })
        checkEq(called[0], false)
        checkEq(ctx._peekStatus(), 411)
    })

    // A-3：bodyParser 错误响应统一壳（与 api.cj 一致）
    failed += runCase("bodyparser_error_uses_unified_shell", { =>
        let ctx = Context()
        defaultBodyParserError(ctx, 413, "Request body too large")
        checkEq(ctx._peekStatus(), 413)
        checkEq(ctx._peekBody(), "{\"code\":413,\"message\":\"Request body too large\",\"data\":null}")
    })

    // A-4：passOnNotFound 透传前复位预写的 404（状态/body/content-type）
    failed += runCase("router_pass_on_not_found_resets_prewritten_404", { =>
        let r = Router()
        r.passOnNotFound = true
        r.get("/known", { ctx, _ => ctx.body("known") })
        let ctx = Context()
        let reached = Array<Bool>(1, { _ => false })
        let mw = r.middleware()
        mw(ctx, { =>
            reached[0] = true
            ctx.status(200).body("from-fallback")
        })
        checkEq(reached[0], true)
        checkEq(ctx._peekStatus(), 200)
        checkEq(ctx._peekBody(), "from-fallback")
        checkTrue(ctx._peekHeaders().get("content-type").isNone())
    })

    // A-7：ETag 复合 mtime 指纹 "<size>-<YYYYMMDDHHmmss>"
    failed += runCase("etag_make_with_mtime_fingerprint", { =>
        match (fileLastModified("./public_blog/index.html")) {
            case Some(mt) =>
                let e = makeETagWithMtime(100, mt)
                checkTrue(e.startsWith("\"100-"))
                checkTrue(e.endsWith("\""))
                let inner = e[1..(e.size - 1)]
                let parts = inner.split("-", 2, removeEmpty: false)
                checkEq(parts.size, 2)
                checkEq(parts[0], "100")
                checkEq(parts[1].size, 14)
            case None => checkTrue(false)
        }
    })

    // B-1：SQL 转义纯函数
    failed += runCase("sqlquote_escapes_single_quotes", { =>
        checkEq(sqlEscape(""), "")
        checkEq(sqlEscape("plain"), "plain")
        checkEq(sqlEscape("it's"), "it''s")
        checkEq(sqlQuote("it's"), "'it''s'")
    })

    failed += runCase("sqlquote_handles_edges", { =>
        checkEq(sqlEscape("'admin'"), "''admin''")
        checkEq(sqlQuote("a''b"), "'a''''b'")
        checkEq(sqlQuote("tail'"), "'tail'''")
    })

    failed += runCase("sqlquote_neutralizes_injection", { =>
        let quoted = sqlQuote("' OR '1'='1")
        checkTrue(quoted.startsWith("'"))
        checkTrue(quoted.endsWith("'"))
        // 转义后不再含有可提前闭合字面量的裸引号结构
        checkTrue(!quoted.contains("' OR '1'='1'"))
    })

    // B-1：RbacStore 拼接层 —— 登录/建户的 username 均已转义
    failed += runCase("rbacstore_find_escapes_username", { =>
        let be = RecordingBackend()
        let store = RbacStore(be)
        let _ = store.findUserByUsername("x' OR '1'='1")
        checkTrue(be.lastSql.startsWith("SELECT * FROM users WHERE username = '"))
        checkTrue(be.lastSql.contains("''1''"))
        checkTrue(!be.lastSql.contains("'1'='1'"))
    })

    failed += runCase("rbacstore_create_user_escapes_input", { =>
        let be = RecordingBackend()
        let store = RbacStore(be)
        let _ = store.createUser("bob'--", hashPassword("pw", "s", 5), 2)
        checkTrue(be.lastSql.startsWith("INSERT INTO users VALUES"))
        checkTrue(be.lastSql.contains("bob''--"))
        checkTrue(!be.lastSql.contains("bob'--"))
    })

    // B-2：changePassword —— UPDATE 形态 + 新哈希经 sqlQuote 包裹
    failed += runCase("rbacstore_change_password_builds_safe_update", { =>
        let be = RecordingBackend()
        let store = RbacStore(be)
        checkTrue(store.changePassword(1, "newPw"))
        checkTrue(be.lastSql.startsWith("UPDATE users SET password_hash = '"))
        checkTrue(be.lastSql.endsWith("' WHERE id = 1"))
    })

    failed += runCase("rbacstore_change_password_missing_user_false", { =>
        let be = RecordingBackend()
        be.execResult = 0
        let store = RbacStore(be)
        checkTrue(!store.changePassword(999, "pw"))
    })

    // C-1：参数化绑定纯函数 —— 占位符按序替换为类型感知字面量
    failed += runCase("bindSql_replaces_placeholders", { =>
        checkEq(bindSql("a = ? AND b = ?", [DbInt(1), DbStr("x")]), "a = 1 AND b = 'x'")
    })

    failed += runCase("bindSql_type_aware_literals", { =>
        // 仓颉 Float64.toString() 固定输出 6 位小数（1.5 -> 1.500000）
        checkEq(bindSql("f = ?", [DbFloat(1.5)]), "f = 1.500000")
        checkEq(bindSql("b = ?", [DbBool(true)]), "b = 1")
        checkEq(bindSql("b = ?", [DbBool(false)]), "b = 0")
        checkEq(bindSql("n = ?", [DbNull]), "n = NULL")
    })

    failed += runCase("bindSql_escapes_string_values", { =>
        checkEq(bindSql("u = ?", [DbStr("it's")]), "u = 'it''s'")
        checkEq(bindSql("u = ?", [DbStr("' OR '1'='1")]), "u = ''' OR ''1''=''1'")
    })

    failed += runCase("bindSql_param_count_mismatch_throws", { =>
        var threw = false
        try {
            let _ = bindSql("a = ? AND b = ?", [DbInt(1)])
        } catch (e: Exception) {
            threw = true
        }
        checkTrue(threw)
    })

    // C-1：RbacStore 参数化路径 —— 最终 SQL 安全（走 ? 绑定而非手写 sqlQuote）
    failed += runCase("rbacstore_parameterized_query_safe", { =>
        let be = RecordingBackend()
        let store = RbacStore(be)
        let _ = store.findUserByUsername("x' OR '1'='1")
        checkTrue(be.lastSql.startsWith("SELECT * FROM users WHERE username = '"))
        checkTrue(!be.lastSql.contains("'1'='1'"))
    })

    // C-2：事务 —— withTransaction 自动 begin/commit/rollback 语义
    failed += runCase("withTransaction_commits_on_success", { =>
        let be = RecordingBackend()
        be.withTransaction({ =>
            be.exec("INSERT INTO users VALUES (9, 'a', 'h', 1)")
        })
        checkEq(be.lastTxAction, "commit")
    })

    failed += runCase("withTransaction_rolls_back_on_error", { =>
        let be = RecordingBackend()
        var threw = false
        try {
            be.withTransaction({ =>
                be.exec("INSERT INTO users VALUES (9, 'a', 'h', 1)")
                throw Exception("boom")
            })
        } catch (e: Exception) {
            threw = true
        }
        checkTrue(threw)
        checkEq(be.lastTxAction, "rollback")
    })

    // C-3：DbResultSet 类型化取值（getInt/getFloat/getString/getNullable）
    failed += runCase("dbresultset_typed_accessors", { =>
        let rows = ArrayList<ArrayList<String>>()
        let r0 = ArrayList<String>()
        r0.add("42")
        r0.add("3.14")
        r0.add("hello")
        r0.add("NULL")
        rows.add(r0)
        let rs = DbResultSet(rows)
        checkEq(rs.getInt(0, 0), 42)
        checkEq(rs.getFloat(0, 1), 3.14)
        checkEq(rs.getString(0, 2), "hello")
        // NULL 约定：字符串 "NULL" 与空串均视为 None
        checkEq(rs.getNullable(0, 3), None)
        checkEq(rs.getNullable(0, 2), Some("hello"))
    })

    failed += runCase("dbresultset_getNullable_empty_string", { =>
        let rows = ArrayList<ArrayList<String>>()
        let r0 = ArrayList<String>()
        r0.add("")
        rows.add(r0)
        let rs = DbResultSet(rows)
        checkEq(rs.getNullable(0, 0), None)
    })

    // B-3：createUser 事务内查重 —— 重名抛异常并回滚
    failed += runCase("createUser_duplicate_username_throws", { =>
        let be = RecordingBackend()
        // 预置一行，模拟 username 已存在（查重命中）
        let row = ArrayList<String>()
        row.add("1")
        row.add("alice")
        row.add("hash")
        row.add("2")
        be.queryRows.add(row)
        let store = RbacStore(be)
        var threw = false
        try {
            store.createUser("alice", "hash", 2)
        } catch (e: IllegalArgumentException) {
            threw = true
        }
        checkTrue(threw)
        checkEq(be.lastTxAction, "rollback")
    })

    // B-3：createUser 成功插入（事务提交 + INSERT 落库）
    failed += runCase("createUser_success_inserts_in_tx", { =>
        let be = RecordingBackend()
        let store = RbacStore(be)
        let id = store.createUser("bob", "hash", 2)
        checkTrue(id > 0)
        checkEq(be.lastTxAction, "commit")
        checkTrue(be.lastSql.startsWith("INSERT INTO users VALUES"))
    })

    // ============  连接池（DbPool / SimpleDbPool）  ============

    // 池为空时 acquire 触发工厂新建，close 关闭空闲连接
    failed += runCase("pool_acquire_empty_creates_new", { =>
        let factory = CountingBackendFactory()
        let pool = SimpleDbPool({ => factory.create() }, 2)
        let b1 = pool.acquire()
        checkEq(factory.created, 1)
        checkEq(pool.idleCount(), 0)
        pool.release(b1)
        checkEq(pool.idleCount(), 1)
        pool.close()
        checkEq(factory.closed, 1)
    })

    // 归还后再次 acquire 复用同一条连接（LIFO，不重复新建）
    failed += runCase("pool_acquire_reuses_idle", { =>
        let factory = CountingBackendFactory()
        let pool = SimpleDbPool({ => factory.create() }, 2)
        let b1 = pool.acquire()
        pool.release(b1)
        let b2 = pool.acquire()
        checkEq(factory.created, 1)   // 复用，未新建
        checkEq(pool.idleCount(), 0)
        pool.release(b2)
        pool.close()
    })

    // 同时借出多条，超过空闲保有上限归还时直接关闭（避免无限堆积）
    failed += runCase("pool_release_over_capacity_closes", { =>
        let factory = CountingBackendFactory()
        let pool = SimpleDbPool({ => factory.create() }, 1)
        let b1 = pool.acquire()
        let b2 = pool.acquire()
        checkEq(factory.created, 2)
        pool.release(b1)   // 栈满（capacity=1），b1 占住唯一空位
        checkEq(pool.idleCount(), 1)
        pool.release(b2)   // 栈已满，b2 被直接关闭
        checkEq(pool.idleCount(), 1)
        checkEq(factory.closed, 1)   // b2 被关闭
        pool.close()                 // 再关 b1
        checkEq(factory.closed, 2)
    })

    // close 只关闭空闲连接，已借出（in-flight）的连接不在此处关闭
    failed += runCase("pool_close_keeps_borrowed", { =>
        let factory = CountingBackendFactory()
        let pool = SimpleDbPool({ => factory.create() }, 2)
        let b1 = pool.acquire()
        let b2 = pool.acquire()
        pool.release(b2)     // b2 回池
        pool.close()         // 只关 b2，b1 仍在借用中
        checkEq(factory.closed, 1)
        b1.close()           // 调用方自行关闭借出的连接
        checkEq(factory.closed, 2)
    })

    // onListen 在 serve() 返回前触发；onShutdown 在
    // shutdown() 排空后按注册序触发（真实起停 127.0.0.1 服务验证）
    failed += runCase("lifecycle_listen_and_shutdown_hooks", { =>
        let app = QingZhouApp()
        let st = HookState()
        app.onListen({ => st.listened += 1 })
           .onShutdown({ => st.order += "a" })
           .onShutdown({ => st.order += "b" })
        checkEq(st.listened, 0)   // 启动前未触发
        let handle = app.serve(18971, bindAddr: "127.0.0.1")
        checkEq(st.listened, 1)   // serve() 返回即已触发
        checkEq(st.order, "")     // 关闭前未触发
        busyWaitMs(300)           // 等 serve 线程完成 bind，走正常关闭路径
        handle.shutdown()
        checkEq(st.order, "ab")   // 注册序执行
    })

    // onShutdown 单钩子异常不阻断其余钩子（收尾阶段异常隔离）
    failed += runCase("lifecycle_shutdown_hook_error_isolated", { =>
        let app = QingZhouApp()
        let st = HookState()
        app.onShutdown({ => st.order += "a" })
           .onShutdown({ => throw Exception("boom") })
           .onShutdown({ => st.order += "c" })
        let handle = app.serve(18972, bindAddr: "127.0.0.1")
        busyWaitMs(300)
        handle.shutdown()
        checkEq(st.order, "ac")   // 抛异常的钩子被跳过，其余照常执行
    })

    // 典型用法：连接池挂 onShutdown，进程优雅关闭时自动回收空闲连接
    failed += runCase("lifecycle_pool_close_via_shutdown_hook", { =>
        let factory = CountingBackendFactory()
        let pool = SimpleDbPool({ => factory.create() }, 2)
        let b = pool.acquire()
        pool.release(b)   // b 回池成为空闲连接
        checkEq(factory.closed, 0)
        let app = QingZhouApp()
        app.onShutdown({ => pool.close() })
        let handle = app.serve(18973, bindAddr: "127.0.0.1")
        busyWaitMs(300)
        handle.shutdown()
        checkEq(factory.closed, 1)   // 池随优雅关闭自动回收
    })

    // 探针执行（含异常捕获）与报告 JSON
    failed += runCase("health_probe_pass_and_throw_captured", { =>
        let up = runHealthProbe(HealthCheck("ok", { => true }))
        checkTrue(up.ok)
        checkEq(up.name, "ok")
        match (up.error) {
            case Some(_) => checkTrue(false)
            case None => ()
        }
        let down = runHealthProbe(HealthCheck("db", { =>
            throw Exception("connect refused")
        }))
        checkTrue(!down.ok)
        checkEq(down.name, "db")
        match (down.error) {
            case Some(e) => checkEq(e, "connect refused")
            case None => checkTrue(false)
        }
    })

    failed += runCase("health_report_json_and_status_code", { =>
        let results = ArrayList<HealthProbeResult>()
        results.add(HealthProbeResult("cache", true))
        results.add(HealthProbeResult("db", false, error: Some("timeout")))
        checkEq(healthStatusCode(results), 503)
        let json = healthReportJson(results, 1234)
        checkTrue(json.contains("\"status\":\"DOWN\""))
        checkTrue(json.contains("\"name\":\"db\""))
        checkTrue(json.contains("\"error\":\"timeout\""))
        checkTrue(json.contains("\"uptimeMs\":1234"))
        // 全部通过 -> 200 + UP
        let all = ArrayList<HealthProbeResult>()
        all.add(HealthProbeResult("cache", true))
        checkEq(healthStatusCode(all), 200)
        checkTrue(healthReportJson(all, 0).contains("\"status\":\"UP\""))
    })

    // 非健康路径透传：路径不匹配时 next() 必须被调用（无 http ctx
    // 时 path() 为空串，天然不匹配 /health）
    failed += runCase("health_passthrough_invokes_next", { =>
        let mw = healthCheck()
        let ctx = Context()
        mw(ctx, { => ctx.trace("next-ran") })
        checkEq(ctx.dump(), "next-ran")
        checkEq(ctx._peekStatus(), 200)
    })

    // e2e（真实起停服务器 + 框架 HttpClient）：
    //   /healthz 存活检查恒 200（探针全挂也不重启风暴）
    //   /health  就绪检查跑探针，挂一个 -> 503 + DOWN 报告
    //   /ping    非健康路径正常走路由
    failed += runCase("health_e2e_liveness_readiness_routing", { =>
        let opts = HealthCheckOptions()
            .addCheck("ok", { => true })
            .addCheck("db", { => false })
        let app = QingZhouApp()
        let router = Router()
        router.get("/ping", { ctx: Context, _: () -> Unit =>
            ctx.body("pong")
        })
        app.use(healthCheckWith(opts)).use(router.middleware())
        let handle = app.serve(18974, bindAddr: "127.0.0.1")
        busyWaitMs(300)
        let c = HttpClient(5, 5)
        let live = c.get("http://127.0.0.1:18974/healthz")
        checkEq(live.status, UInt16(200))
        checkTrue(live.body.contains("\"status\":\"UP\""))
        let ready = c.get("http://127.0.0.1:18974/health")
        checkEq(ready.status, UInt16(503))
        checkTrue(ready.body.contains("\"status\":\"DOWN\""))
        checkTrue(ready.body.contains("\"name\":\"ok\""))
        checkTrue(ready.body.contains("\"name\":\"db\""))
        let ping = c.get("http://127.0.0.1:18974/ping")
        checkEq(ping.status, UInt16(200))
        checkEq(ping.body, "pong")
        c.close()
        handle.shutdown()
    })

    // MockTransport 无网络单测 + 退避策略 + 真实 TLS 握手
    failed += runCase("outbound_mock_success_first_try", { =>
        let mock = MockTransport()
        mock.enqueue(OutboundResponse(200, "{\"ok\":true}"))
        let client = OutboundClient(mock)
        let resp = client.get("https://example.test/api")
        checkEq(resp.status, 200)
        checkTrue(resp.isSuccess())
        checkEq(mock.sentRequests().size, 1)   // 一次成功，无重试
        client.close()
    })

    failed += runCase("outbound_retry_on_5xx_then_success", { =>
        let mock = MockTransport()
        mock.enqueue(OutboundResponse(500, "boom"))
        mock.enqueue(OutboundResponse(503, "boom"))
        mock.enqueue(OutboundResponse(200, "ok"))
        let policy = RetryPolicy(3, 1, 4)   // 退避压到 1ms 级，测试才快
        policy.jitter = false
        let client = OutboundClient(mock, retry: policy)
        let resp = client.get("https://example.test/api")
        checkEq(resp.status, 200)
        checkEq(mock.sentRequests().size, 3)   // 500 → 503 → 200，重试 2 次
        client.close()
    })

    failed += runCase("outbound_no_retry_on_4xx", { =>
        let mock = MockTransport()
        mock.enqueue(OutboundResponse(400, "bad request"))
        let policy = RetryPolicy(3, 1, 4)
        policy.jitter = false
        let client = OutboundClient(mock, retry: policy)
        let resp = client.get("https://example.test/api")
        checkEq(resp.status, 400)
        checkEq(mock.sentRequests().size, 1)   // 4xx 不重试（客户端问题）
        client.close()
    })

    failed += runCase("outbound_retry_exhausted_on_network_error", { =>
        let mock = MockTransport()
        mock.enqueue(OutboundResponse(0, "", networkError: Some("connect refused")))
        mock.enqueue(OutboundResponse(0, "", networkError: Some("connect refused")))
        mock.enqueue(OutboundResponse(0, "", networkError: Some("connect refused")))
        let policy = RetryPolicy(3, 1, 4)
        policy.jitter = false
        let client = OutboundClient(mock, retry: policy)
        let resp = client.get("https://example.test/api")
        checkTrue(resp.isNetworkFailure())
        checkEq(mock.sentRequests().size, 3)   // 网络错误用满 3 次尝试
        client.close()
    })

    failed += runCase("outbound_backoff_exponential_and_capped", { =>
        let p = RetryPolicy(5, 100, 400)
        p.jitter = false
        checkEq(p.delayMsFor(1), 100)
        checkEq(p.delayMsFor(2), 200)
        checkEq(p.delayMsFor(3), 400)
        checkEq(p.delayMsFor(4), 400)          // maxDelayMs 封顶
        checkTrue(p.shouldRetry(OutboundResponse(429, ""), 1))    // 限流可重试
        checkTrue(p.shouldRetry(OutboundResponse(500, ""), 1))    // 5xx 可重试
        checkTrue(!p.shouldRetry(OutboundResponse(404, ""), 1))   // 4xx 不重试
        checkTrue(!p.shouldRetry(OutboundResponse(500, ""), 5))   // 用满次数后不再重试
    })

    // 真实 TLS：起 HTTPS 服务（自签证书），用 CustomCA 握手并取回响应
    failed += runCase("outbound_tls_custom_ca_real_handshake", { =>
        let certPem = String.fromUtf8(File.readFrom("examples/cert.pem"))
        let keyPem = String.fromUtf8(File.readFrom("examples/key.pem"))
        let router = Router()
        router.get("/tls-ping", { ctx: Context, _: () -> Unit =>
            ctx.body("tls-pong")
        })
        let app = QingZhouApp().use(router.middleware())
        let handle = app.serveTls(19002, certPem, keyPem, bindAddr: "127.0.0.1")
        busyWaitMs(500)
        let tls = OutboundTlsOptions()
        tls.caBundlePath = "examples/cert.pem"   // 自签证书自身作信任锚
        let client = OutboundClient(StdxTransport(5, tls))
        let resp = client.get("https://127.0.0.1:19002/tls-ping")
        checkEq(resp.status, 200)
        checkEq(resp.body, "tls-pong")
        client.close()
        handle.shutdown()
    })

    // 容错 JSON 提取（剥围栏 / 跳过话术 / 字符串内括号不误判）
    failed += runCase("extractJson_from_markdown_fence", { =>
        let text = "好的，结果如下：\n```json\n{\"a\":1,\"b\":[2,3]}\n```\n希望有帮助"
        match (extractJson(text)) {
            case Some(fragment) => checkEq(fragment, "{\"a\":1,\"b\":[2,3]}")
            case None => checkTrue(false)
        }
    })

    failed += runCase("extractJson_skips_braces_inside_strings", { =>
        let text = "prefix {\"note\":\"a } b\",\"n\":1} suffix"
        match (extractJson(text)) {
            case Some(f) => checkEq(f, "{\"note\":\"a } b\",\"n\":1}")
            case None => checkTrue(false)
        }
    })

    failed += runCase("extractJson_none_when_absent", { =>
        match (extractJson("这段文本里没有 JSON")) {
            case Some(_) => checkTrue(false)
            case None => ()
        }
    })

    failed += runCase("parseJsonLoose_reads_fenced_object", { =>
        let text = "```json\n{\"title\":\"x\",\"priority\":3}\n```"
        match (parseJsonLoose(text)) {
            case Some(v) =>
                match (jsonGetStr(v.asObject(), "title")) {
                    case Some(s) => checkEq(s, "x")
                    case None => checkTrue(false)
                }
            case None => checkTrue(false)
        }
    })

    // schema 级校验（一次收集全部错误）
    failed += runCase("jsonschema_reports_all_errors_at_once", { =>
        let obj = JsonObject()
        obj.put("title", JsonString(""))
        obj.put("priority", JsonInt(9))
        let schema = JsonSchema()
            .requireStr("title", minLen: 1)
            .requireIntIn("priority", 1, 5)
            .require("missing", FStr)
        let errs = schema.validate(obj)
        checkEq(errs.size, 3)              // 长度不足 + 超范围 + 缺必填，一次报全
        checkTrue(!schema.isValid(obj))
    })

    failed += runCase("jsonschema_valid_object_passes", { =>
        let obj = JsonObject()
        obj.put("title", JsonString("写周报"))
        obj.put("priority", JsonInt(3))
        let schema = JsonSchema().requireStr("title", minLen: 1).requireIntIn("priority", 1, 5)
        checkTrue(schema.isValid(obj))
        checkEq(schema.fieldCount(), 2)
    })

    failed += runCase("jsonschema_type_mismatch_detected", { =>
        let obj = JsonObject()
        obj.put("count", JsonString("not-a-number"))
        let schema = JsonSchema().require("count", FInt)
        let errs = schema.validate(obj)
        checkEq(errs.size, 1)
        checkTrue(errs[0].contains("类型不符"))
    })

    // 日志脱敏（密钥永不入日志）
    failed += runCase("redact_authorization_and_query", { =>
        let raw = "Authorization: Bearer sk-abc123\napi_key=deadbeef&page=1"
        let out = redact(raw)
        checkTrue(!out.contains("sk-abc123"))
        checkTrue(!out.contains("deadbeef"))
        checkTrue(out.contains("page=1"))   // 非敏感字段保留
        checkTrue(out.contains("***"))
    })

    failed += runCase("redact_json_fields_keeps_others", { =>
        let raw = "{\"token\":\"abc\",\"password\":\"p@ss\",\"user\":\"bob\"}"
        let out = redact(raw)
        checkTrue(!out.contains("abc"))
        checkTrue(!out.contains("p@ss"))
        checkTrue(out.contains("bob"))
    })

    failed += runCase("redact_keeps_normal_text_intact", { =>
        let raw = "GET /api/users?page=2 status=200"
        checkEq(redact(raw), raw)
    })

    // 出站并发上限（信号量真实验证：6 并发请求，峰值不超 2）
    failed += runCase("outbound_concurrency_cap_enforced", { =>
        let probe = ConcurrencyProbe()
        let client = OutboundClient(probe, maxConcurrency: 2)
        let futures = ArrayList<Future<Unit>>()
        var i: Int64 = 0
        while (i < 6) {
            futures.add(spawn { client.get("https://example.test/x") })
            i += 1
        }
        for (f in futures) {
            f.get()
        }
        checkTrue(probe.peakCount() <= 2)   // 峰值并发不超过上限
        checkTrue(probe.peakCount() >= 2)   // 且确实并行过（限制未误设成串行）
        checkEq(probe.totalCalls(), 6)
        client.close()
    })

    // ---------- 查询构建器（dbquery.cj） ----------

    failed += runCase("dbquery_select_render", { =>
        let (sql, ps) = SelectQuery().from("users").select(["id", "name"])
            .filter(dbEq("role_id", DbInt(1)))
            .orderBy("id", desc: true).toSql()
        checkEq(sql, "SELECT id, name FROM users WHERE role_id = ? ORDER BY id DESC")
        checkEq(ps.size, 1)
        checkEq(dbValueLiteral(ps[0]), "1")
    })

    failed += runCase("dbquery_params_never_inlined", { =>
        // 值一律走参数占位符，不拼进 SQL —— 注入面由此关闭
        let evil = "x' OR '1'='1"
        let (sql, ps) = SelectQuery().from("users").filter(dbEq("name", DbStr(evil))).toSql()
        checkEq(sql, "SELECT * FROM users WHERE name = ?")
        checkTrue(!sql.contains("OR"))
        checkEq(dbValueLiteral(ps[0]), "'x'' OR ''1''=''1'")
    })

    failed += runCase("dbquery_backend_plumbing", { =>
        // 构建器 -> 参数 -> bindSql -> 后端（用 RecordingBackend，无需真库）
        let be = RecordingBackend()
        SelectQuery().from("users").filter(dbEq("name", DbStr("x' OR '1'='1"))).query(be)
        checkEq(be.lastSql, "SELECT * FROM users WHERE name = 'x'' OR ''1''=''1'")
        InsertQuery().into("users").values([DbInt(1), DbStr("a")]).exec(be)
        checkEq(be.lastSql, "INSERT INTO users VALUES (1, 'a')")
    })

    failed += runCase("dbquery_ident_rejects_injection", { =>
        checkThrows({ => sqlIdent("users; DROP TABLE users") })
        checkThrows({ => sqlIdent("1abc") })
        checkThrows({ => sqlIdent("a.b.c") })
        checkThrows({ => sqlIdent("a.") })
        checkThrows({ => sqlIdent("") })
        checkEq(sqlIdent("users"), "users")
        checkEq(sqlIdent("t.col_1"), "t.col_1")
    })

    failed += runCase("dbquery_and_or_grouping", { =>
        let c = dbAnd([dbEq("a", DbInt(1)), dbEq("b", DbInt(2))])
        let (sqlC, _) = SelectQuery().from("t").filter(c).toSql()      // Common：扁平
        checkEq(sqlC, "SELECT * FROM t WHERE a = ? AND b = ?")
        let (sqlM, _) = SelectQuery().from("t").filter(c).toSql(dialect: DbDialect.MySql)
        checkEq(sqlM, "SELECT * FROM t WHERE (a = ? AND b = ?)")
        let (sqlO, _) = SelectQuery().from("t")
            .filter(dbOr([dbEq("a", DbInt(1)), dbEq("b", DbInt(2))]))
            .toSql(dialect: DbDialect.MySql)
        checkEq(sqlO, "SELECT * FROM t WHERE (a = ? OR b = ?)")
    })

    failed += runCase("dbquery_dialect_gate_rejects_mysql_only", { =>
        // CangDB 解析不了的构造必须在构建期就拒绝
        checkThrows({ => SelectQuery().from("t").filter(dbNe("a", DbInt(1))).toSql() })
        checkThrows({ => SelectQuery().from("t").filter(dbIsNull("a")).toSql() })
        checkThrows({ => SelectQuery().from("t").filter(dbIn("a", [DbInt(1)])).toSql() })
        checkThrows({ => SelectQuery().from("t")
            .filter(dbOr([dbEq("a", DbInt(1)), dbEq("b", DbInt(2))])).toSql() })
        checkThrows({ => SelectQuery().from("t").limit(10).toSql() })
        checkThrows({ => SelectQuery().from("t").offset(5).toSql() })
        checkThrows({ => InsertQuery().into("t").set("a", DbInt(1)).toSql() })
        // 同一构造在 MySql 方言下放行
        let (s1, _) = SelectQuery().from("t").filter(dbNe("a", DbInt(1)))
            .toSql(dialect: DbDialect.MySql)
        checkEq(s1, "SELECT * FROM t WHERE a <> ?")
        let (s2, _) = SelectQuery().from("t").limit(10).offset(5).toSql(dialect: DbDialect.MySql)
        checkEq(s2, "SELECT * FROM t LIMIT 10 OFFSET 5")
    })

    failed += runCase("dbquery_insert_forms", { =>
        let (s1, p1) = InsertQuery().into("t").values([DbInt(1), DbStr("a")]).toSql()
        checkEq(s1, "INSERT INTO t VALUES (?, ?)")
        checkEq(p1.size, 2)
        checkThrows({ => InsertQuery().into("t").set("id", DbInt(1)).toSql() })
        let (s2, _) = InsertQuery().into("t").set("id", DbInt(1)).toSql(dialect: DbDialect.MySql)
        checkEq(s2, "INSERT INTO t (id) VALUES (?)")
        checkThrows({ => InsertQuery().into("t").values([]).toSql() })
    })

    failed += runCase("dbquery_update_delete_guard", { =>
        // 无 WHERE 的全表写操作默认拒绝
        checkThrows({ => UpdateQuery().update("t").set("a", DbInt(1)).toSql() })
        checkThrows({ => DeleteQuery().from("t").toSql() })
        let (s1, p1) = UpdateQuery().update("t").set("a", DbInt(1))
            .filter(dbEq("id", DbInt(7))).toSql()
        checkEq(s1, "UPDATE t SET a = ? WHERE id = ?")
        checkEq(p1.size, 2)
        let (s2, _) = DeleteQuery().from("t").allowFullTable().toSql()
        checkEq(s2, "DELETE FROM t")
    })

    failed += runCase("dbquery_raw_escape_hatch", { =>
        let (s1, p1) = SelectQuery().from("t")
            .filter(dbRaw("(a = ? OR b LIKE ?)", ps: [DbInt(1), DbStr("%x%")]))
            .toSql(dialect: DbDialect.MySql)
        checkEq(s1, "SELECT * FROM t WHERE (a = ? OR b LIKE ?)")
        checkEq(p1.size, 2)
    })

    println("---")
    if (failed == 0) {
        println("All ${g_total} unit-test scenarios PASSED")
        return 0
    }
    println("${failed} unit-test scenario(s) FAILED")
    return 1
}

/*
 * Concrete exception subclass used by manual runner scenarios.
 * Lives here so that unit_tests.cj (which declares `Boom <: Exception` for the
 * @Test macros) does not collide.
 */
class Boom2 <: Exception {
    init() { super("boom!") }
}

/*
 * 短读流 stub。read() 每次最多返回
 * chunkCap 字节（可少于调用方缓冲区大小），模拟 TCP 分段 —— 用于
 * 证明 readBodyUpTo 不再把短读误判为 EOF。
 */
class ShortReadStream <: InputStream {
    let payload: Array<UInt8>
    var pos: Int64 = 0
    let chunkCap: Int64
    init(payload: Array<UInt8>, chunkCap: Int64) {
        this.payload = payload
        this.chunkCap = chunkCap
    }
    public func read(buf: Array<UInt8>): Int64 {
        if (pos >= payload.size) {
            return 0
        }
        var n = payload.size - pos
        if (n > chunkCap) {
            n = chunkCap
        }
        if (n > buf.size) {
            n = buf.size
        }
        var i: Int64 = 0
        while (i < n) {
            buf[i] = payload[pos + i]
            i += 1
        }
        pos += n
        return n
    }
    public func isClosed(): Bool {
        return pos >= payload.size
    }
}

/*
 * 记录型内存后端。不真正执行 SQL，
 * 只记录最后一条语句并返回可控行数，让 RbacStore 进入默认测试编译集
 * 后（store.cj 已无外部依赖）可以验证拼接 SQL 的转义形态。
 */
class RecordingBackend <: DbBackend {
    public var lastSql: String = ""
    public var lastTxAction: String = ""
    public var execResult: Int64 = 1
    // 可配置的查询返回行，测试可预置「查重命中」场景。
    public var queryRows: ArrayList<ArrayList<String>> = ArrayList<ArrayList<String>>()
    public func query(sql: String): DbResultSet {
        lastSql = sql
        return DbResultSet(queryRows)
    }
    public func exec(sql: String): Int64 {
        lastSql = sql
        return execResult
    }
    public func ensureTable(name: String, columns: String): Unit {}
    public func close(): Unit {}
    public func beginTransaction(): Unit { lastTxAction = "begin" }
    public func commitTransaction(): Unit { lastTxAction = "commit" }
    public func rollbackTransaction(): Unit { lastTxAction = "rollback" }
}

/*
 * 计数后端 —— 不真正执行 SQL，只记录「创建/关闭」次数，
 * 用于验证 SimpleDbPool 的复用、超容量关闭、close 语义（不依赖真实数据库）。
 */
class CountingBackend <: DbBackend {
    public let factory: CountingBackendFactory
    public init(factory: CountingBackendFactory) {
        this.factory = factory
    }
    public func query(sql: String): DbResultSet { return DbResultSet() }
    public func exec(sql: String): Int64 { return 0 }
    public func ensureTable(name: String, columns: String): Unit {}
    public func close(): Unit { factory.closed += 1 }
    public func beginTransaction(): Unit {}
    public func commitTransaction(): Unit {}
    public func rollbackTransaction(): Unit {}
}

/* CountingBackend 的工厂：统计新建/关闭的后端数量。 */
class CountingBackendFactory {
    public var created: Int64 = 0
    public var closed: Int64 = 0
    public func create(): CountingBackend {
        created += 1
        return CountingBackend(this)
    }
}

/*
 * 钩子回调的可变状态容器。
 * 仓颉限制：捕获 var 的 lambda 不能作为函数值传递
 * （"lambda capturing mutable variables needs to be called directly"），
 * 故用引用类型字段承载可变状态，闭包捕获实例后改字段。
 */
class HookState {
    public var listened: Int64 = 0
    public var order: String = ""
}

/* 并发探针：记录 send 的并发峰值与总次数，用于验证 OutboundClient 的信号量上限。
 * 状态用类承载（仓颉 lambda 不能捕获可变 var 作为函数值传递）。 */
class ConcurrencyProbe <: HttpTransport {
    private let lock = Mutex()
    private var active: Int64 = 0
    private var peak: Int64 = 0
    private var calls: Int64 = 0

    public func send(req: OutboundRequest): OutboundResponse {
        synchronized(lock) {
            active += 1
            calls += 1
            if (active > peak) {
                peak = active
            }
        }
        sleep(Duration.millisecond * 60)   // 拉长单次占用，让并发重叠可见
        synchronized(lock) {
            active -= 1
        }
        return OutboundResponse(200, "ok")
    }

    public func peakCount(): Int64 {
        return peak
    }

    public func totalCalls(): Int64 {
        return calls
    }

    public func close(): Unit {}
}

/* 自旋等待（std 无 Thread.sleep）：给 stdx serve 线程时间完成 bind，
 * 使 shutdown() 走正常优雅关闭路径（避开 close/bind 启动竞态）。 */
func busyWaitMs(ms: Int64): Unit {
    let start = MonoTime.now()
    while ((MonoTime.now() - start).toMilliseconds() < ms) {}
}

func runCase(name: String, body: () -> Unit): Int64 {
    g_total += 1
    try {
        body()
        println("  PASS  ${name}")
        return 0
    } catch (e: Exception) {
        println("  FAIL  ${name}: ${e.message}")
        return 1
    }
}

func checkEq<T>(actual: T, expected: T): Unit where T <: Equatable<T> & ToString {
    if (actual != expected) {
        throw Exception("expected <${expected}> got <${actual}>")
    }
}

/*
 * 断言 body 抛异常。用于验证参数校验与方言闸门确实生效——
 * 「没有抛」本身就是失败。
 */
func checkThrows<T>(body: () -> T): Unit {
    var threw = false
    try {
        body()
    } catch (e: Exception) {
        threw = true
    }
    if (!threw) {
        throw Exception("checkThrows: 期望抛异常，但没有")
    }
}

func checkTrue(b: Bool): Unit {
    if (!b) {
        throw Exception("expected true")
    }
}
