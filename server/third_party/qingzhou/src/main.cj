package qingzhou

import std.collection.*
import std.convert.*
import stdx.net.http.*

/*
 * SPDX-License-Identifier: MIT
 *
 *  entry points:
 *   args[0] == "test"        -> run manual unit-test scenarios and exit
 *   args[0] == "self-test"   ->  onion sanity check
 *   args[0] == "serve"       -> start HTTP server (port from args[1] or 3000)
 */
main(args: Array<String>): Int64 {
    if (args.size > 0) {
        if (args[0] == "test") {
            println("=== QingZhou  unit tests ===")
            return runAllUnitTests()
        }
        if (args[0] == "self-test") {
            return runSelfTest()
        }
    }

    let port: UInt16 = if (args.size > 1 && args[0] == "serve") {
        UInt16.parse(args[1])
    } else {
        3000
    }
    startServer(port)
    return 0
}

/* --------  onion sanity check -------- */
func runSelfTest(): Int64 {
    let stack = ArrayList<Middleware>()
    stack.add({ ctx: Context, next: () -> Unit =>
        ctx.trace("m1-before"); next(); ctx.trace("m1-after")
    })
    stack.add({ ctx: Context, next: () -> Unit =>
        ctx.trace("m2-before"); next(); ctx.trace("m2-after")
    })
    stack.add({ ctx: Context, _: () -> Unit =>
        ctx.trace("handler")
    })
    let ctx = Context()
    compose(stack)(ctx)
    println("onion order: ${ctx.dump()}")
    let expected = "m1-before -> m2-before -> handler -> m2-after -> m1-after"
    if (ctx.dump() == expected) {
        println("PASS: onion model")
        return 0
    }
    println("FAIL: expected ${expected}")
    return 1
}

/* -------- HTTP demo -------- */
func startServer(port: UInt16): Unit {
    let router = Router()
        .get("/", { ctx: Context, _: () -> Unit =>
            ctx.status(200)
                .header("content-type", "text/plain; charset=utf-8")
                .body("QingZhou  @ /")
        })
        .get("/hello", { ctx: Context, _: () -> Unit =>
            ctx.status(200)
                .header("content-type", "text/plain; charset=utf-8")
                .body("hello from QingZhou")
        })
        .get("/users/:id", { ctx: Context, _: () -> Unit =>
            let id = ctx.paramOr("id", "?")
            let q = ctx.paramOr("q", "none")
            ctx.status(200)
                .header("content-type", "application/json")
                .body("{\"id\":\"${id}\",\"q\":\"${q}\"}")
        })
        .get("/users/:id/posts/:pid", { ctx: Context, _: () -> Unit =>
            let uid = ctx.paramOr("id", "?")
            let pid = ctx.paramOr("pid", "?")
            ctx.status(200)
                .header("content-type", "application/json")
                .body("{\"user_id\":\"${uid}\",\"post_id\":\"${pid}\"}")
        })
        .post("/users", { ctx: Context, _: () -> Unit =>
            ctx.status(201)
                .header("content-type", "application/json")
                .body("{\"created\":true,\"method\":\"POST\"}")
        })
        .get("/files/*", { ctx: Context, _: () -> Unit =>
            let tail = ctx.paramOr("tail", "")
            ctx.status(200)
                .header("content-type", "text/plain; charset=utf-8")
                .body("file path: ${tail}")
        })
        .get("/boom", { ctx: Context, _: () -> Unit =>
            throw Exception("intentional boom @ /boom")
        })
        /* ======  endpoints ====== */
        .post("/echo-json", { ctx: Context, _: () -> Unit =>
            let raw = ctx.body()
            if (raw.size == 0) {
                ctx.status(400)
                    .header("content-type", "application/json")
                    .body("{\"error\":\"empty body\"}")
                return
            }
            match (ctx.bodyJson()) {
                case Some(v) =>
                    ctx.status(200)
                        .header("content-type", "application/json; charset=utf-8")
                        .body("{\"content-type\":\"${ctx.contentType()}\",\"parsed\":${v.toString()}}")
                case None =>
                    let errMsg = match (ctx.bodyJsonError()) {
                        case Some(e) => e.message
                        case None => "unknown parse error"
                    }
                    ctx.status(400)
                        .header("content-type", "application/json")
                        .body("{\"error\":\"bad json\",\"reason\":\"${errMsg}\"}")
            }
        })
        .post("/echo-form", { ctx: Context, _: () -> Unit =>
            let form = ctx.bodyForm()
            let pairs = ArrayList<String>()
            for ((k, v) in form) {
                pairs.add("\"${k}\":\"${v}\"")
            }
            let obj = String.join(pairs.toArray(), delimiter: ",")
            ctx.status(200)
                .header("content-type", "application/json; charset=utf-8")
                .body("{\"content-type\":\"${ctx.contentType()}\",\"fields\":{${obj}}}")
        })
        .get("/cookies", { ctx: Context, _: () -> Unit =>
            // Read raw Cookie: header directly and report.
            var raw = ""
            match (ctx.http) {
                case Some(h) =>
                    for (entry in h.request.headers) {
                        if (entry[0].toAsciiLower() == "cookie") {
                            for (v in entry[1]) {
                                raw = v
                            }
                        }
                    }
                case None => ()
            }
            // Also exercise the cookies.get() accessor to ensure parse path runs.
            let sid = match (ctx.cookies.get("sid")) {
                case Some(s) => s
                case None => ""
            }
            ctx.status(200)
                .header("content-type", "application/json; charset=utf-8")
                .body("{\"raw\":\"${raw}\",\"sid\":\"${sid}\"}")
        })
        .get("/cookies/set", { ctx: Context, _: () -> Unit =>
            ctx.cookies.set("sid", "xyz789")
            ctx.cookies.set("theme", "dark")
            ctx.status(200)
                .header("content-type", "application/json; charset=utf-8")
                .body("{\"ok\":true,\"set\":[\"sid\",\"theme\"]}")
        })
        /* ======  endpoints ====== */
        .get("/m4/request-id", { ctx: Context, _: () -> Unit =>
            // requestId middleware will have stamped ctx._id and a
            // response header. We surface it in the body too so
            // a curl without -i can still see it.
            ctx.status(200)
                .header("content-type", "application/json; charset=utf-8")
                .body("{\"id\":\"${ctx._id}\"}")
        })
        .get("/m4/cookies/secure", { ctx: Context, _: () -> Unit =>
            // Full CookieOptions: secure + httpOnly + SameSite=Strict
            // + maxAge + path + domain. The domain/secure flags won't
            // be exercised by a localhost client but the header
            // composition is observable.
            let opts = CookieOptions()
            opts.maxAge = 3600
            opts.path = "/"
            opts.domain = "example.com"
            opts.secure = true
            opts.httpOnly = true
            opts.sameSite = "Strict"
            ctx.cookies.set("session", "abc-def-ghi", opts)
            ctx.status(200)
                .header("content-type", "application/json; charset=utf-8")
                .body("{\"ok\":true}")
        })
        .post("/m4/echo-bp", { ctx: Context, _: () -> Unit =>
            // Requires bodyParser() to have populated the cache
            // before this handler runs. bodyParser runs in app.use,
            // router dispatches to this route after.
            match (ctx.bodyJson()) {
                case Some(v) =>
                    ctx.status(200)
                        .header("content-type", "application/json; charset=utf-8")
                        .body("{\"echo\":${v.toString()}}")
                case None =>
                    let msg = match (ctx.bodyJsonError()) {
                        case Some(e) => e.message
                        case None => "no body"
                    }
                    ctx.status(400)
                        .header("content-type", "application/json")
                        .body("{\"error\":\"${msg}\"}")
            }
        })

    //  middleware stack:
    //   - requestId first so every other middleware + handler can read ctx._id
    //   - logger emits the access log
    //   - bodyParser materialises bodyJson / bodyForm / body so handlers
    //     don't have to know about the InputStream
    //   - cors adds cross-origin headers
    //   - serveAt before router so /static/* short-circuits before the
    //     404 fallback in router catches them
    //   - timeout 5s default
    let app = QingZhouApp()
        .use(requestId())
        .use(logger())
        .use(serveAt("./public", "/static"))
        .use(cors())
        .use(bodyParser())
        .use(router.middleware())
        .use(timeout(5000))
        .onError(jsonErrorHandler())

    println("[demo routes]")
    println("  GET  /                  -> text 'QingZhou  @ /'")
    println("  GET  /static/logo.png   -> image/png   (70 B PNG)")
    println("  GET  /static/mark.svg   -> image/svg+xml")
    println("  GET  /static/style.css  -> text/css")
    println("  GET  /static/app.js     -> application/javascript")
    println("  GET  /static/note.txt   -> text/plain")
    println("  GET  /static/clip.bin   -> 250 KB binary; supports Range + ETag")
    println("  GET  /static/dir/       -> dir/index.html (default)")
    println("  GET  /static/missing    -> 404")
    println("  GET  /static/../main.cj -> 403 (path traversal)")
    println("  GET  /static/movie.mp4  -> 404 (file absent) [MIME table has video/mp4]")
    println("  GET  /hello             -> text 'hello from QingZhou'")
    println("  GET  /users/42          -> JSON {id:42, q:none}  (param :id)")
    println("  GET  /users/7/posts/99  -> JSON {user_id, post_id}  (multi-param)")
    println("  POST /users             -> 201 {created:true}")
    println("  GET  /files/a/b/c.txt   -> tail = a/b/c.txt  (wildcard)")
    println("  GET  /boom              -> 500 {error}  (onError)")
    println("  GET  /nope              -> 404 {error: Not Found}")
    println("  DELETE /hello           -> 405 {allow: GET} + Allow header")
    println("  POST /echo-json         -> : echoes parsed JSON body, 400 on bad JSON")
    println("  POST /echo-form         -> : echoes form-encoded body")
    println("  GET  /cookies          -> : shows incoming Cookie: header")
    println("  GET  /cookies/set       -> : sets sid + theme cookies")
    println("")
    println("[: middleware suite]")
    println("  GET  /m4/request-id                       -> response header X-Request-Id (32 hex chars)")
    println("  GET  /m4/cookies/secure                   -> Set-Cookie with Max-Age+Path+Domain+Secure+HttpOnly+SameSite")
    println("  POST /m4/echo-bp                          -> bodyParser() then ctx.bodyJson() (requires app.use(bodyParser()))")
    println("  OPTIONS /m4/echo-bp + Origin + ACRM       -> CORS preflight 204 + Access-Control-Allow-*")
    println("")
    println("[: Range / ETag short-circuits on /static/*]")
    println("  GET  /static/clip.bin                        -> 200 + ETag: \"<size>\"")
    println("  GET  /static/clip.bin  + Range: bytes=0-99   -> 206 + Content-Range: bytes 0-99/<size>")
    println("  GET  /static/clip.bin  + Range: bytes=249900- -> 206 (last 100 bytes)")
    println("  GET  /static/clip.bin  + Range: bytes=300000- -> 416 + Content-Range: bytes */<size>")
    println("  GET  /static/clip.bin  + If-None-Match: \"<size>\" -> 304 Not Modified")
    println("  GET  /static/clip.bin  + If-None-Match: *      -> 304 Not Modified")
    println("  HEAD /static/clip.bin                        -> 200 + ETag + Content-Length, no body")

    app.listen(port)
}