# QingZhou (轻舟) API Fact Sheet — for writing a NEW server

> **Provenance / method.** Every signature below is copied verbatim from the vendored framework source
> `baseline/server/third_party/qingzhou/src/` (snapshot `3d6c1a36`, v0.12.0+, integrity-locked by
> `third_party/qingzhou/MANIFEST.sha256`), from the working server `baseline/server/src/`, or from
> `baseline/docs/API-NOTES.md` / `baseline/docs/mysql-backend.md`. Line numbers are `file:line` for the
> exact file named. Nothing here is invented; anything not provable from those files is marked
> **UNVERIFIED**.
>
> **Toolchain (must match, or the build fails): cjc 1.2.0 + stdx 1.1.3.1 (static).**
> `build.ps1:4`; the version gate is literal: `if ("$v" -match '1\.2\.0')` (`build.ps1:96`) and
> `if ($ver -notmatch '1\.2\.0') { throw ... }` (`build.ps1:179`). The `cjc` on PATH (1.1.3) is the
> wrong one; correct SDKs:
> `C:\Users\ASUS\.cjenv\sdks\1.2.0\cangjie\bin\cjc.exe` and
> `E:\cangjie\stdx\windows_x86_64_cjnative\static\stdx`.
>
> **Package model (critical):** the framework is ONE package, `package qingzhou` (`app.cj:1`, `router.cj:1`,
> `context.cj:1`, `compose.cj:1`, ...). The application is compiled **into the same package in the same cjc
> invocation** — `server/src/main.cj:1` is also `package qingzhou`, and `build.ps1:4` states it:
> *"cjc 1.2.0 + stdx 1.1.3.1（静态）+ 仓库内置的轻舟源码，同一次调用、同一个包"*.
> There is no `import qingzhou.*` in this project's build; `import qingzhou.*` only applies to the
> `qz`/library mode (`README.md:77-78`). Consequence: **your top-level function names share a namespace
> with the framework's** — see pitfall #1.

---

## 1. App / Server construction

### 1.1 Types and exact signatures (`src/app.cj`)

```cangjie
public class QingZhouApp {                                       // app.cj:36
    public init() {}                                             // app.cj:43

    public func use(mw: Middleware): QingZhouApp                 // app.cj:45
    public func onError(mw: Middleware): QingZhouApp             // app.cj:50
    public func onListen(cb: () -> Unit): QingZhouApp            // app.cj:57
    public func onShutdown(cb: () -> Unit): QingZhouApp          // app.cj:64
    public func handler(): AppHandler                            // app.cj:69

    public func listen(port: UInt16, bindAddr!: String = "0.0.0.0",
                       maxRequestBodySize!: ?Int64 = None): Unit // app.cj:78   (blocking)
    public func serve(port: UInt16, bindAddr!: String = "0.0.0.0",
                      maxRequestBodySize!: ?Int64 = None): ServerHandle // app.cj:91 (non-blocking)
    public func serveTls(port: UInt16, certPem: String, keyPem: String,
                         bindAddr!: String = "0.0.0.0",
                         maxRequestBodySize!: ?Int64 = None): ServerHandle // app.cj:97
    public func listenTls(port: UInt16, certPem: String, keyPem: String,
                          bindAddr!: String = "0.0.0.0",
                          maxRequestBodySize!: ?Int64 = None): Unit // app.cj:106
}

public class ServerHandle {                                      // app.cj:168
    public func shutdown(): Unit                                 // app.cj:185 (graceful)
    public func wait(): Unit                                     // app.cj:202 (block)
}
```

* `listen(port)` is literally `serve(port, ...).wait()` (`app.cj:79-80`).
* `serveTls` takes **PEM strings, not file paths**: `X509Certificate.decodeFromPem(certPem)` +
  `RSAPrivateKey.decodeFromPem(keyPem)` (`app.cj:98-101`). Reading the files and error handling are the
  caller's job — the working server does exactly that (`main.cj:1005-1021`) and **never falls back to
  plaintext** on failure (`main.cj:993-994`).
* Usage (`main.cj:980-982`):
  ```cangjie
  let handle = app.serve(port)   // default bindAddr = "0.0.0.0"
  box.handle = Some(handle)      // keep the handle somewhere (see 1.3)
  handle.wait()                  // blocks until shutdown()
  ```
  `serveTls` usage: `handle = Some(app.serveTls(port, certPem, keyPem))` (`main.cj:1033`).

### 1.2 Boot internals worth knowing (`app.cj:114-151`)

* A **custom catch-all distributor** is installed before `.build()` (`app.cj:117-120`) because stdx's
  built-in `DirectDistributor` is exact-match only and would swallow `/users/42` (comment `app.cj:31-34`).
  Every request goes to `app.handle(Context(httpCtx))`.
* The stdx server logger is forced to `LogLevel.ERROR` (`app.cj:123-124`).
* `println("QingZhou listening on ${bindAddr}:${port}")` is emitted at boot (`app.cj:140`).
* `serve()` is spawned onto a background CJThread (`spawn { server.serve() }`, `app.cj:141-143`);
  **bind happens asynchronously** — `onListen` hooks run right after the spawn and must not assume the
  port is connectable yet (`app.cj:144-149`).

### 1.3 Lifecycle hooks and graceful shutdown

| Hook | Semantics (verbatim from source) |
| --- | --- |
| `onListen(cb)` | fires after the server starts listening, **each serve/listen boot**; exceptions propagate — *"启动期初始化失败应当 fail-fast"* (`app.cj:55-60`) |
| `onShutdown(cb)` | fires **after** `shutdown()` drains in-flight requests, in registration order, with per-hook error isolation (one failing hook does not block the rest) (`app.cj:62-67`, `app.cj:192-199`) |
| `shutdown()` | *"停 accept → 排空在途请求 → 执行 onShutdown 钩子"*; `server.close()` + `fut.get()`; stop errors are printed, not rethrown (`app.cj:179-191`) |
| `wait()` | just `fut.get()`; **does not run hooks** (`app.cj:161`, `app.cj:202-204`) |

* **Windows has no signal hook:** *"Cangjie's std.runtime.Signal is not supported on Windows, so there is no
  portable Ctrl+C -> shutdown() hook here... trigger shutdown() from an admin endpoint or a second thread"*
  (`app.cj:163-166`; also API-NOTES.md:142).
* **Never call `shutdown()` on the request thread** — it waits for the current request to finish → deadlock.
  Do it from a spawned thread, and wait ~1 s first so the reply is actually flushed:
  ```cangjie
  match (box.handle) {
      case Some(h) => spawn {
          sleep(Duration.second * 1)   // main.cj:733
          h.shutdown()                 // main.cj:734
      }
      case None => ()
  }
  ```
  (`main.cj:715-738`; the 1 s delay is a documented fix for "HTTP 200 + empty body" — API-NOTES.md:156,
  pitfall #36. `handleShutdown` also enforces local-only access via `isLocalPeer(ctx)`, `main.cj:716-718`.)
* Hook-keeping trick used by this project because *"闭包捕获 var 的语义不可靠"*: put the handle in a class
  with a `var` field and capture the `let` reference (`main.cj:46-51`, `main.cj:965`).

---

## 2. Routing

### 2.1 Registration (`src/router.cj`)

```cangjie
public class Router {                                                              // router.cj:84
    public var passOnNotFound: Bool = false                                        // router.cj:88
    public init() {}                                                               // router.cj:92
    public func add(method: String, pattern: String, h: Middleware,
                    name!: ?String = None): Router                                 // router.cj:99
    public func get(p: String, h: Middleware, name!: ?String = None): Router       // router.cj:111
    public func post(p: String, h: Middleware, name!: ?String = None): Router      // router.cj:112
    public func put(p: String, h: Middleware, name!: ?String = None): Router       // router.cj:113
    public func delete(p: String, h: Middleware, name!: ?String = None): Router    // router.cj:114
    public func patch(p: String, h: Middleware, name!: ?String = None): Router     // router.cj:115
    public func all(p: String, h: Middleware, name!: ?String = None): Router       // router.cj:116
    public func urlFor(name: String,
                       params!: HashMap<String, String> = HashMap<String, String>()): ?String  // router.cj:123
    public func group(prefix: String,
                      mw!: Array<Middleware> = Array<Middleware>()): RouteGroup    // router.cj:166
    public func lookup(method: String, path: String, ctx: Context): DispatchResult // router.cj:180
    public func middleware(): Middleware                                           // router.cj:221
}
```

`get/post/...` are one-liners over `add` (`router.cj:111-116`), so the **registered handler type is
`Middleware`**, not a bespoke handler type.

### 2.2 Mounting / grouping

* **Mount the router as the last middleware:** `.use(router.middleware())` (`README.md:84`,
  `main.cj:952`). Anything registered *after* it never runs if a handler doesn't call `next()`
  (that is exactly the documented bug in `main.cj:919-929`).
* **Grouping:** `router.group("/api", mw: [auth])` returns a `RouteGroup` sharing the single trie
  (`router.cj:161-172`); group middleware wraps handlers with onion semantics (`router.cj:386-399`);
  nested `group` concatenates prefixes and inherits parent middleware (`router.cj:422-432`).
  `RouteGroup` exposes `get/post/put/delete/patch` + `group` (`router.cj:401-423`) — **no `all`, no `add`**.
* `name!` registers a named route for `urlFor` reverse generation (`router.cj:99-109`, `router.cj:118-159`).

### 2.3 Pattern syntax (verbatim from `router.cj:13-28`)

```
//   /users             static
//   /users/:id         :param  -> ctx.params["id"]
//   /users/:id?        optional param -> matches /users and /users/42
//                      (expanded to concrete paths at add() time, max 3 per pattern)
//   /files/*           trailing wildcard -> ctx.params["tail"] = "remaining/path"
//   /files/*name       named trailing wildcard -> ctx.params["name"]
//   /v1/*/shop/...     mid-path STAR matches exactly one segment (anonymous);
//                      "/v1/*ver/shop/..." names it -> ctx.params["ver"]
```

* `*` = the literal asterisk character. (The comment spells it out as `STAR` because *"an asterisk
  followed by a slash terminates Cangjie block comments"*, `router.cj:22-23` — see pitfall #3.)
* Optional params are expanded at `add()` time; **more than 3 throw**
  `IllegalArgumentException("too many optional params (max 3): ...")` (`router.cj:454-456`).
* Matching priority **with backtracking**: Static → Param → Wildcard, and *"某个分支走不通时继续尝试
  低优先级分支"* (`router.cj:302-313`, implementation `router.cj:314-350`). Parameters written on a failed
  branch are undone (`router.cj:352-361`). Practical effect: `/api/users/me` and `/api/:module/list`
  coexist; both orders of registration work, though `main.cj:810-811` still registers static paths first.
* `splitPath` normalizes `/`, `""`, trailing slash and uses `split("/", removeEmpty: true)`
  (`router.cj:498-516`).

### 2.4 404 / 405 are written by the framework

`lookup` (and `middleware()`) **mutate the ctx** on non-match:

```cangjie
ctx.status(405).header("allow", allow).header("content-type", "application/json")
   .body("{\"error\":\"Method Not Allowed\",\"allow\":\"${allow}\"}")      // router.cj:196-200
ctx.status(404).header("content-type", "application/json")
   .body("{\"error\":\"Not Found\",\"path\":\"${path}\"}")                 // router.cj:202-205
```

With `passOnNotFound = true`, the router calls `ctx.resetResponse()` **before** `next()` — the comment
explains why: without it the pre-written 404 status leaks onto the later successful response
(`router.cj:233-240`). This is the vendored fix for API-NOTES pitfall #34.

---

## 3. Handler signature

```cangjie
public type Middleware = (Context, () -> Unit) -> Unit      // compose.cj:20
```

A route handler is a `Middleware` whose second parameter is the downstream `next` (usually ignored):

```cangjie
router.get("/health", { ctx: Context, _: () -> Unit =>
    handleHealth(ctx)
})                                                          // main.cj:746-748
```

* Response tools are chainable and buffered; the framework commits once at the end:
  `AppHandler.handle` runs the business chain in a `try`, on exception calls `ctx.throw_err(e)` and then
  runs the `onError` chain (which **does not** recurse `next`), then always `ctx.commit()`
  (`compose.cj:83-101`).
* Business middleware that wraps other handlers: `{ ctx: Context, next: () -> Unit => ...; next() }`
  (`compose.cj:36-42`).
* A handler that wants the router's `next` (e.g. fallthrough chains) must be registered with the router
  **before** the terminal router middleware, and the framework passes `next` through
  (`router.cj:226`: `case DispatchResult.Matched(h) => h(ctx, next)`).

---

## 4. Context API (`src/context.cj`)

```cangjie
public class Context {                                                    // context.cj:28
    public var state: HashMap<String, String> = HashMap<String, String>() // context.cj:37
    public let http: ?HttpContext                                         // context.cj:63
    public var cookies: Cookies = Cookies()                               // context.cj:64

    public init()                                                         // context.cj:82
    public init(httpCtx: HttpContext)                                     // context.cj:87
```

### 4.1 Path params

```cangjie
public func setParam(k: String, v: String): Unit        // context.cj:103
public func param(name: String): ?String                // context.cj:107
public func paramOr(name: String, default_: String): String  // context.cj:111
```
The router injects them on `Matched` (`router.cj:189-191`). Example: `ctx.paramOr("id", "")`.

### 4.2 Query params

```cangjie
public func query(): String                              // context.cj:204  raw, no leading '?'
public func queryParam(name: String): ?String            // context.cj:219  URL-decoded, first value
public func queryParamOr(name: String, default_: String): String  // context.cj:234
public func queryParams(): HashMap<String, String>       // context.cj:242  URL-decoded, last write wins
```
Parsing: `q.split("&", -1, removeEmpty: true)` then `pair.split("=", 2, removeEmpty: false)`
(`context.cj:225-229`) — note `maxSplits` counts **pieces**, so `2` = one split at the first `'='`
(`context.cj:471-473`). URL decoding is hand-rolled `urlDecode` (accumulates bytes, one
`String.fromUtf8` at the end so multi-byte UTF-8 works; `context.cj:608-654`).

### 4.3 Request body / JSON

```cangjie
public func bodyBytes(): Array<UInt8>                    // context.cj:366  lazy, cached, read once
public func bodyBytesCapped(maxBytes: Int64): ?Array<UInt8>  // context.cj:393  None = over the cap
public func body(): String                               // context.cj:417  String.fromUtf8(bodyBytes())
public func bodyJson(): ?JsonValue                       // context.cj:429  None on empty/bad JSON, cached
public func bodyJsonError(): ?Exception                  // context.cj:453
public func bodyForm(): HashMap<String, String>           // context.cj:463
public func contentType(): String                        // context.cj:487  parameters stripped; "" if absent
public func requestHeader(name: String): ?String         // context.cj:511  case-insensitive lookup
```

* `bodyJson()` returns `None` for empty body, non-JSON, or parse error; *"Callers who want to distinguish
  'no body' from 'bad JSON' can branch on `body().isEmpty()` first"* (`context.cj:421-428`).
  `bodyJsonError()` is the app-level way to check (`context.cj:449-457`).
* **There is no body-size limit in the framework body path** — the project enforces it in middleware:
  *"bodyStrOr() 照样会把整份 body 读进来（context.cj 的 bodyBytes 没有任何上限）"* (`ops/admin_main.cj:669`).
  The framework ships `bodyParser` with a 1 MiB cap and `contentLengthLimit`; see 4.6.
* Safe JSON accessors (never throw) live in `src/jsonx.cj`:
  ```cangjie
  public func jsonGetStr(obj: JsonObject, key: String): ?String        // jsonx.cj:28
  public func jsonGetInt64(obj: JsonObject, key: String): ?Int64       // jsonx.cj:35
  public func jsonGetFloat64(obj: JsonObject, key: String): ?Float64   // jsonx.cj:42
  public func jsonGetBool(obj: JsonObject, key: String): ?Bool         // jsonx.cj:49
  public func jsonGetObject(obj: JsonObject, key: String): ?JsonObject // jsonx.cj:56
  public func jsonGetArray(obj: JsonObject, key: String): ?JsonArray   // jsonx.cj:63
  public func jsonMissing(obj: JsonObject, keys: Array<String>): ?String // jsonx.cj:74
  public func bodyStr(ctx: Context, key: String): ?String              // jsonx.cj:151
  public func bodyInt64(ctx: Context, key: String): ?Int64             // jsonx.cj:162
  public func bodyStrOr(ctx: Context, key: String, default_: String): String // jsonx.cj:174
  ```
  Why they exist: `asString()/asObject()/asInt()/asBool()` return **subclasses, not `Option`**, and throw on
  type mismatch (`context.cj`/jsonx.cj:18-23; API-NOTES.md:73).

### 4.4 JSON building

```cangjie
public class JsonBuilder {                                  // jsonx.cj:96
    public init()                                           // jsonx.cj:99
    public func put(key: String, value: String): JsonBuilder       // jsonx.cj:103
    public func putInt(key: String, value: Int64): JsonBuilder     // jsonx.cj:108
    public func putFloat(key: String, value: Float64): JsonBuilder // jsonx.cj:113
    public func putBool(key: String, value: Bool): JsonBuilder     // jsonx.cj:118
    public func putObject(key: String, value: JsonObject): JsonBuilder // jsonx.cj:123
    public func putArray(key: String, value: JsonArray): JsonBuilder   // jsonx.cj:128
    public func build(): String                             // jsonx.cj:134  compact, auto-escaped
    public func toObject(): JsonObject                      // jsonx.cj:139
}
```
Documented example (`jsonx.cj:88-92`): `JsonBuilder().put("id", id.toString()).putInt("count", 3)
.putBool("ok", true).build()`. *"比手写 ... 更安全（自动转义、类型正确）"* (`jsonx.cj:94`).

### 4.5 Response writing

```cangjie
public func status(code: Int64): Context                 // context.cj:258
public func body(s: String): Context                     // context.cj:263
public func body(bytes: Array<UInt8>): Context           // context.cj:274
public func header(k: String, v: String): Context        // context.cj:280  (response header setter)
public func json(payload: String): Context               // context.cj:285
public func resetResponse(): Unit                        // context.cj:533
public func commit(): Unit                               // context.cj:545  idempotent
```

* `json(payload)` sets `content-type: application/json; charset=utf-8` **and** `_body = payload`
  (`context.cj:285-289`). It takes an **already-serialized string** — pass `JsonBuilder().build()` or
  `JsonObject.toString()`.
* `commit()` is called by the framework after the chain (`compose.cj:100`) and is guarded by `_committed`
  (`context.cj:546-549`); **you never need to call it**, and calling it early would freeze the response.
* **Header pitfall (derived from source):** `json()` does **not** reset the byte-body selector, whereas
  `body(String)` sets `_bodyKind = 0` (`context.cj:263-267`) and `body(bytes)` sets `_bodyKind = 1`
  (`context.cj:274-278`). At commit the bytes win when `_bodyKind == 1 && _bodyBytes.size > 0`
  (`context.cj:564-568`). So "`ctx.body(someBytes)` then `ctx.json(s)`" still sends the **bytes**.
* There is **no response-header getter**; `requestHeader` reads request headers only
  (`context.cj:503-511`). Same-name response headers are overwrite semantics (single HashMap key,
  `context.cj:30`, `context.cj:555-557`).
* Cookies: `ctx.cookies.get(name): ?String` (`cookies.cj:65`), `ctx.cookies.set(name, value): Unit`
  (`cookies.cj:75`), `ctx.cookies.set(name, value, opts: CookieOptions): Unit` (`cookies.cj:91`);
  `CookieOptions` fields at `cookies.cj:34-40` (`maxAge`, `expires`, `path`, `domain`, `secure`,
  `httpOnly`, `sameSite`).
* Client address: `ctx.remoteAddr(): String` returns **`"ip:port"`** (`context.cj:179-184`,
  API-NOTES.md:118) and `ctx.remoteIp(): String` strips the port (`context.cj:190-196`).

### 4.6 The `{ok,data}` unified-response helper

Two, and they are **not the same envelope**:

**(a) Framework's own shell** (`src/api.cj`) — `{code, message, data}`:
```cangjie
public func respondOk(ctx: Context, data: String): Unit      // api.cj:22
    // ctx.json("{\"code\":0,\"message\":\"ok\",\"data\":${data}}")
public func respondOkNull(ctx: Context): Unit                // api.cj:27
public func respondErr(ctx: Context, code: Int64, message: String): Unit // api.cj:32
```
`data` must be an **already-serialized JSON fragment** string (`api.cj:21-24`). `code == 0` = success;
the doc says HTTP status usually aligns 2xx/4xx/5xx (`api.cj:11-18`).

**(b) This project's `{ok,data}` / `{ok,error}` shell** (`server/src/jsonw.cj`) — use this if you follow
the existing server's conventions:
```cangjie
public func sendRoot(ctx: Context, status_: Int64, data: JsonObject): Unit  // jsonw.cj:73
public func sendOk(ctx: Context, data: JsonObject): Unit      // jsonw.cj:80  -> 200 {"ok":true,"data":{...}}
public func sendCreated(ctx: Context, data: JsonObject): Unit // jsonw.cj:84  -> 201
public func sendError(ctx: Context, e: ApiError): Unit        // jsonw.cj:89  -> {"ok":false,"error":{...}}
```
```cangjie
public func sendRoot(ctx: Context, status_: Int64, data: JsonObject): Unit {
    let root = JsonObject()
    root.put("ok", JsonBool(true))
    root.put("data", data)
    ctx.status(status_).json(root.toString())        // jsonw.cj:74-77
}
```
`sendError` sets the HTTP status from `e.status_` and emits
`{"ok":false,"error":{"code","message","fields"}}` (`jsonw.cj:89-101`). Request-side helpers in the same
file: `reqObj(ctx): JsonObject` (throws `VALIDATION_FAILED` unless the body is a JSON object,
`jsonw.cj:106-117`), `reqOptionalStr` (`jsonw.cj:120`), `reqOptionalInt` (`jsonw.cj:134`),
`reqStrOr` (`jsonw.cj:148`), `reqIntOr` (`jsonw.cj:162`), `oneField` (`jsonw.cj:65`), plus
`jPutStr/jPutInt/jPutBool/jPutObj/jPutArr/jPutNull/jPutTime` (`jsonw.cj:24-55`).

> Note the mixed conventions in the repo: the framework's `jsonErrorHandler()` produces
> `{"error":"<message>"}` (`middleware.cj:30-44`), `bodyParser`'s default error produces
> `{"code":N,"message":"...","data":null}` (`bodyparser.cj:50-54`), `router` produces
> `{"error":"Not Found",...}`, and the project's own handlers use `{ok,data}`. Pick one envelope
> deliberately.

### 4.7 Middleware the server is built from (exact factories)

```cangjie
public func requestId(): Middleware                              // requestid.cj:36
public func requestIdWith(opts: RequestIdOptions): Middleware    // requestid.cj:40   header="X-Request-Id", bytes=16
public func logger(): Middleware                                 // logger.cj:44
public func loggerWith(opts: LoggerOptions): Middleware          // logger.cj:48
public func bodyParser(): Middleware                             // bodyparser.cj:57
public func bodyParser(opts: BodyParserOptions): Middleware      // bodyparser.cj:61
public func contentLengthLimit(maxBytes: Int64): Middleware      // bodyparser.cj:168
public func cors(): Middleware                                   // cors.cj:43
public func corsWith(opts: CORSOptions): Middleware              // cors.cj:47
public func timeout(): Middleware                                // timeout.cj:52   default ms=5000
public func timeout(ms: Int64): Middleware                       // timeout.cj:57
public func timeoutWith(opts: TimeoutOptions): Middleware        // timeout.cj:63
public func compress(opts: CompressOptions): Middleware          // compress.cj:66   threshold=1024
public func serve(rootDir: String): Middleware                   // static.cj:107
public func serveAt(rootDir: String, prefix: String): Middleware // static.cj:111
public func serveWithOpts(rootDir: String, opts: StaticOptions): Middleware // static.cj:115
public func securityHeaders(): Middleware                        // securityheaders.cj:29
public func rateLimit(limit: Int64, windowSeconds: Int64): Middleware // ratelimit.cj:26
public func multipart(): Middleware                              // multipart.cj:169
public func healthCheck(): Middleware                            // health.cj:144
public func authRequired(secret: String): Middleware             // auth.cj:44
public func jsonErrorHandler(): Middleware                       // middleware.cj:30
public func respondText(ctx: Context, text: String): Unit        // middleware.cj:51
public func respondJSON(ctx: Context, payload: String): Unit     // middleware.cj:55
```
Option fields (defaults verbatim): `BodyParserOptions.maxBytes = 1024 * 1024`,
`onError: (Context, Int64, String) -> Unit = defaultBodyParserError` (`bodyparser.cj:36,40,50`);
`CORSOptions.origin="*"`, `methods="GET, POST, PUT, PATCH, DELETE, OPTIONS"`,
`allowedHeaders="Content-Type, Authorization, X-Request-Id"`,
`exposedHeaders="X-Request-Id"`, `credentials=false`, `maxAge=86400` (`cors.cj:33-38`);
`TimeoutOptions.ms=5000`, `onTimeout: (Context) -> Unit` (`timeout.cj:36,40`);
`CompressOptions.threshold=1024` (`compress.cj:57`);
`StaticOptions` (`static.cj:48-69`): `prefix=""`, `indexFile="index.html"`, `notFoundStatus=404`,
`notFoundBody`, `forbiddenStatus=403`, `forbiddenBody`, `enableRange=true`, `enableETag=true`,
`enableCache=true`, `spaFallback=false`, `apiPrefix="/api"`;
`RequestIdOptions.header="X-Request-Id"`, `bytes=16` (`requestid.cj:31-32`).

**Assembly order used by the working server** (`main.cj:940-953`) — order is semantic:
```cangjie
return QingZhouApp()
    .use(requestId())
    .use(logger())
    .use(bodyLimit())                        // project middleware; MUST precede bodyParser (main.cj:943-946)
    .use(bodyParser(bodyParserOptions()))
    .use(cors())
    .use(timeout(15000))
    .use(snapshotFlush(s))                   // project middleware; must precede router (main.cj:931-935)
    .use(router.middleware())                // router last
    .onError(errHandler)                     // main.cj:909-917
```
`timeout` before the router is mandatory if you want it to run at all: *"排在 router 后面的 timeout
中间件一次都没有被执行过"* (`main.cj:919-925`). Also note `timeout` is a *post-hoc* soft timeout — it
cannot interrupt a running synchronous handler (`main.cj:926-929`).

---

## 5. Streaming / SSE

Exact signatures (`src/context.cj:291-332`):

```cangjie
public func streamStart(contentType: String): Context {   // context.cj:301
    _streaming = true
    _statusCode = 200
    _headers["content-type"] = contentType
    _headers["transfer-encoding"] = "chunked"
    _headers["cache-control"] = "no-cache"
    return this
}

public func writeChunk(bytes: Array<UInt8>): Unit {       // context.cj:314
    match (http) {
        case Some(h) =>
            _flushHead(h)
            let w = HttpResponseWriter(h)
            w.write(bytes)
        case None => ()
    }
}

public func writeChunk(s: String): Unit {                 // context.cj:325
    writeChunk(s.toArray())
}

public func isStreaming(): Bool {                         // context.cj:330
    return _streaming
}
```

Rules, as documented in the source:

1. *"进入流式响应模式（SSE / chunked）。设置响应头后，用 `writeChunk()` 多次写数据；handler 返回后
   stdx 自动写 last-chunk 结束流式响应。"* (`context.cj:293-296`)
2. *"底层依赖 stdx 的 `HttpResponseWriter.write`：首次 write 会把 status + headers 刷到客户端，且要求
   已设 `transfer-encoding: chunked`（否则 stdx 抛「必须设 Content-Length 或 chunked」）。"*
   (`context.cj:297-300`) — `streamStart()` is what sets chunked; do not hand-roll the headers.
3. First `writeChunk` flushes status + headers (`context.cj:310-313`).
4. `streamStart` forces status 200 and cache-control `no-cache`; set status/headers **before** the first
   `writeChunk` (after that the head is on the wire).
5. `writeChunk` is a no-op when there is no `HttpContext` (`case None => ()`, `context.cj:320`).

**UNVERIFIED items (state them to your implementer):**
* `commit()` has **no `_streaming` branch** (`context.cj:545-571`) yet `AppHandler.handle` always calls
  `ctx.commit()` after the chain (`compose.cj:100`). Whether that trailing `commit()` disturbs an
  already-flushed chunked response is not provable from this source.
* There is **zero in-repo usage** of `streamStart`/`writeChunk` (grep over `server/src`, `tests/`,
  `third_party/qingzhou/examples`, `manual_runner.cj` finds only the definitions and one CHANGELOG line:
  `CHANGELOG.md:298`). The framework's own unit-test suite does not cover SSE, so this API is
  **not covered by any regression gate in this workspace**.
* A `HttpResponseWriter` (stdx) is constructed per `writeChunk` call; whether concurrent/interleaved
  writes are safe is not documented here.

---

## 6. Database layer

### 6.1 `DbBackend` interface (verbatim, `src/db.cj:100-181`)

```cangjie
public interface DbBackend {
    func query(sql: String): DbResultSet                    // db.cj:102
    func exec(sql: String): Int64                           // db.cj:105  affected rows
    func ensureTable(name: String, columns: String): Unit    // db.cj:108
    func close(): Unit                                      // db.cj:111

    func query(sql: String, params: Array<DbValue>): DbResultSet {   // db.cj:124  default impl
        query(bindSql(sql, params))
    }
    func exec(sql: String, params: Array<DbValue>): Int64 {          // db.cj:129  default impl
        exec(bindSql(sql, params))
    }

    func beginTransaction(): Unit                           // db.cj:139
    func commitTransaction(): Unit                          // db.cj:142
    func rollbackTransaction(): Unit                        // db.cj:145

    func withTransaction(body: () -> Unit): Unit {          // db.cj:152  default impl
        beginTransaction()
        try {
            body()
            commitTransaction()
        } catch (e: Exception) {
            rollbackTransaction()
            throw e
        }
    }

    func dialect(): DbDialect { DbDialect.Common }          // db.cj:167
    func ensureUniqueIndex(table: String, column: String): Unit {    // db.cj:178  default impl
        exec("CREATE UNIQUE INDEX idx_" + table + "_" + column + " ON " + table + "(" + column + ")")
    }
}
```

**There is no `ping()`.** Only these members exist. The default parameterized `query`/`exec` do **not** use
server-side prepared statements — they interpolate type-aware literals via `bindSql` (`db.cj:113-131`).
`bindSql` **fails fast** if the `?` count ≠ param count:
`throw Exception("SQL 占位符数量(${parts.size - 1})与参数数量(${params.size})不匹配：${sql}")` (`db.cj:252-256`).

### 6.2 `DbValue` (verbatim, `src/db.cj:222-228`) — 5 variants

```cangjie
public enum DbValue {
    | DbInt(Int64)
    | DbFloat(Float64)
    | DbStr(String)
    | DbBool(Bool)
    | DbNull
}
```
Literal rendering (`db.cj:235-243`): `DbInt`/`DbFloat` → `toString()`, `DbStr` → `sqlQuote(s)`,
`DbBool` → `1`/`0`, `DbNull` → `NULL`. Escaping: `sqlEscape` doubles single quotes only
(`db.cj:199-206`), `sqlQuote` wraps in `'` (`db.cj:209-211`).
**There is no `DbBytes` / `DbTime` variant** — `Array<UInt8>` and timestamps must be encoded by you.

### 6.3 `DbResultSet` — everything is a String, 0-based column index

```cangjie
public class DbResultSet {                                  // db.cj:28
    public let rows: ArrayList<ArrayList<String>>           // db.cj:30
    public init()                                           // db.cj:32
    public init(rows: ArrayList<ArrayList<String>>)          // db.cj:36
    public func rowCount(): Int64                           // db.cj:41
    public func cell(i: Int64, j: Int64): String             // db.cj:46  out-of-range -> ""
    public func row(i: Int64): ?ArrayList<String>            // db.cj:58
    public func getString(i: Int64, j: Int64): String         // db.cj:68
    public func getInt(i: Int64, j: Int64): Int64            // db.cj:73  Int64.parse -> throws if not numeric
    public func getFloat(i: Int64, j: Int64): Float64         // db.cj:78
    public func getNullable(i: Int64, j: Int64): ?String      // db.cj:86  "" or "NULL" -> None
}
```
All column values are stringified to hide backend type differences (`db.cj:19`, `db.cj:24-27`).
Usage in the working server: `rs.cell(i, 0)`, `rs.rowCount()`, `parseIntOr(rs.cell(i, 1), 0)`
(`mysql_store.cj:707-716`, `mysql_store.cj:778-793`).
**Column indices are 0-based in `DbResultSet`** (the driver's own `get<T>(index)` is 1-based inside
`MySqlBackend.query`, `db_mysql.cj:77,85-96` — do not confuse the two).

### 6.4 Opening a MySQL backend

```cangjie
public class MySqlBackend <: DbBackend {                     // db_mysql.cj:25
    public init(host: String, port: Int64, user: String, password: String, database: String,
                noBackslashEscapes!: Bool = true)            // db_mysql.cj:40-41
    public func dialect(): DbDialect { DbDialect.MySql }      // db_mysql.cj:72
}
```

The exact connection assembly (`db_mysql.cj:42-67`):

```cangjie
var urlScheme = "mysql"
let driver = match (DriverManager.getDriver("mysql")) {
    case Some(d) => d
    case None =>
        urlScheme = "mariadb"                                // fallback: Cangjie-SIG mysql-driver
        match (DriverManager.getDriver("mariadb")) {
            case Some(d) => d
            case None => throw Exception("未注册 mysql/mariadb 驱动：...")   // db_mysql.cj:50
        }
}
let ds = driver.open(
    urlScheme + "://" + host + ":" + port.toString(),
    [("username", user), ("password", password), ("database", database), ("prepare.mode", "client")]
)
conn = ds.connect()
tx = conn.createTransaction()
if (noBackslashEscapes) {
    let stmt = conn.prepareStatement(
        "SET SESSION sql_mode = CONCAT(@@SESSION.sql_mode, ',NO_BACKSLASH_ESCAPES')")
    stmt.update()
}
```

**DSN / config options a new server must know:**
* **Supported URL schemes:** `mysql://` or `mariadb://` (`db_mysql.cj:16-17,42-52`).
  `prepare.mode=client` is fixed and commented: *"框架级 bindSql 已把参数拼进 SQL（无 ? 占位符），无需
  server 模式的真预处理；client 模式直接发普通 query，兼容 DDL（如 CREATE UNIQUE INDEX——server 模式的
  COM_STMT_PREPARE 不支持 DDL）"* (`db_mysql.cj:55-57`).
* **There is no charset parameter and no `SET NAMES`** (`API-NOTES.md:164` root-cause line).
* **Factory by DSN** (`db_factory.cj`):
  ```cangjie
  public func openStore(dsn: String): RbacStore               // db_factory.cj:26
  public func openPool(dsn: String, capacity: Int64): SimpleDbPool  // db_factory.cj:79
  ```
  Accepted DSN forms (verbatim, `db_factory.cj:11-16`):
  `"cangdb:admin.cjdb"`, `"admin.cjdb"` (no prefix → CangDB file), `"mysql://user:pass@host:3306/db"`.
  `parseMySqlDsn` splitting rules (`db_factory.cj:85-92`): userinfo/host split at the **last `@`**
  (password may contain `@`), user/password at the **first `:`**, host/port at the **last `:`**
  (port defaults to 3306), `/db` is **mandatory**. Errors are redacted via `redactDsn`
  (`db_factory.cj:131-135`).
* **`openStore` is unusable in this project's build** because `db_factory.cj` imports `CangDbBackend`
  (`main.cj:110-114`; `build.ps1:279`). The working server therefore constructs
  `MySqlBackend` directly (`mysql_store.cj:158-159`).
* **Pooling** (`dbpool.cj`): `DbPool.acquire/release/close/idleCount` (`dbpool.cj:36-48`);
  `capacity` is an **idle-connection** cap, not a concurrency cap (`dbpool.cj:54-58`, `db_factory.cj:77`).
  The doc explains why you must pool for concurrency: a single shared connection causes (1) non-thread-safe
  drivers racing and (2) *transaction cross-talk* — *"请求 A 的 begin 会被请求 B 的 commit 提前关闭"*
  (`dbpool.cj:14-21`). `SimpleDbPool` is Mutex-protected, LIFO (`dbpool.cj:61-128`).

### 6.5 `withTransaction` semantics

* Default implementation: `beginTransaction()` → `body()` → `commitTransaction()`; on exception
  `rollbackTransaction()` then **rethrow** (`db.cj:147-161`).
* The working server wraps it 1:1 and calls it `tx` (`mysql_store.cj:221-228`).
* **Nesting/reentrancy is not guarded anywhere in the source**: `MySqlBackend` holds exactly one
  `Transaction` field (`db_mysql.cj:27`, created once at `db_mysql.cj:61`), and `withTransaction` has no
  depth check. Treat nested transactions on one connection as **UNVERIFIED / unsafe** — with a pool,
  borrow one connection per transaction.
* One transaction per request is the project's whole persistence model; consequence documented at
  `API-NOTES.md:164`: a failing transaction leaves in-memory state ahead of the DB, so **every later write
  fails** until restart. Design your write path so a failed flush cannot wedge the process.

### 6.6 `noBackslashEscapes` — the flag pitfall

* Field/parameter: `noBackslashEscapes!: Bool = true` (`db_mysql.cj:41`) — **the default is `true`**.
* What it does: *"连接后把会话 sql_mode 固定为 NO_BACKSLASH_ESCAPES"* (`db_mysql.cj:32-33`).
* Why it exists: the framework's `''` escaping would otherwise collide with MySQL's backslash escaping —
  *"以单个反斜杠结尾的值（如 "abc\"）会逃逸出字符串边界"* (`db_mysql.cj:33-38`, `CHANGELOG.md:33-38`).
* **The pitfall:** if you pass `noBackslashEscapes: false` (old behaviour) while your own escaping layer
  doubles backslashes for the *default* mode, the doubled `\\` is stored **literally as two backslashes**.
  Conversely with the default `true`, raw SQL can no longer rely on backslash escaping
  (`LIKE '\%'` must be rewritten, `db_mysql.cj:37`).
* **What the working server does** (documented decision, `docs/mysql-backend.md:479`): it passes
  `noBackslashEscapes: false` explicitly (`mysql_store.cj:158-159`) and does its own backslash doubling
  (`mysqlSafe`, `mysql_store.cj:836`) — with the warning *"不能反过来改 mysqlSafe —— 库里既有数据都是按
  默认口径写进去的"*. Pick one convention and never switch it after you have data.
* **Independent P0 requirement:** after connecting you **must** send `SET NAMES utf8mb4`
  (`mysql_store.cj:201-208`), because the driver hardcodes the handshake charset to 33 = utf8mb3
  (`API-NOTES.md:164`; `mysql_store.cj:179-186`). Without it, one 4-byte UTF-8 character (emoji) makes
  **all subsequent writes fail** with `1366 Incorrect string value` while reads keep returning 200.
  The working server sets it and **throws** if it fails (`mysql_store.cj:202-207`).

---

## 7. Query builders (`src/dbquery.cj`)

### 7.1 Types, dialects and condition helpers

```cangjie
public enum DbDialect { | Common | MySql }                   // dbquery.cj:35
public enum DbOp { | Eq | Ne | Gt | Ge | Lt | Le }           // dbquery.cj:41

public enum DbCond {                                         // dbquery.cj:54
    | Cmp(String, DbOp, DbValue)
    | Between(String, DbValue, DbValue)
    | Like(String, DbValue)
    | InList(String, Array<DbValue>)
    | NullTest(String, Bool)
    | And(Array<DbCond>)
    | Or(Array<DbCond>)
    | Not(DbCond)
    | Raw(String, Array<DbValue>)
}

public func dbEq(col: String, v: DbValue): DbCond            // dbquery.cj:68
public func dbNe(col: String, v: DbValue): DbCond            // dbquery.cj:69
public func dbGt(col: String, v: DbValue): DbCond            // dbquery.cj:70
public func dbGe(col: String, v: DbValue): DbCond            // dbquery.cj:71
public func dbLt(col: String, v: DbValue): DbCond            // dbquery.cj:72
public func dbLe(col: String, v: DbValue): DbCond            // dbquery.cj:73
public func dbLike(col: String, v: DbValue): DbCond          // dbquery.cj:74
public func dbBetween(col: String, lo: DbValue, hi: DbValue): DbCond  // dbquery.cj:75
public func dbIn(col: String, vs: Array<DbValue>): DbCond     // dbquery.cj:78
public func dbIsNull(col: String): DbCond                     // dbquery.cj:79
public func dbNotNull(col: String): DbCond                    // dbquery.cj:80
public func dbAnd(cs: Array<DbCond>): DbCond                  // dbquery.cj:81
public func dbOr(cs: Array<DbCond>): DbCond                   // dbquery.cj:82
public func dbNot(c: DbCond): DbCond                          // dbquery.cj:83

public func dbRaw(sql: String, ps!: Array<DbValue> = Array<DbValue>()): DbCond  // dbquery.cj:89
public func sqlIdent(name: String): String                    // dbquery.cj:116
```

* **`dbRaw` is a CONDITION escape hatch, not a SET expression.** It returns `DbCond` (=
  `DbCond.Raw(sql, ps)`, `dbquery.cj:90`), so it can only be used where a condition is accepted
  (`filter`, `andFilter`, inside `dbAnd/dbOr/dbNot`). Its doc: *"逃生口：原样 SQL 片段 + 其参数（片段内用
  ? 占位）。用它即放弃方言检查，调用方自负两端兼容性。"* (`dbquery.cj:85-88`). Its params are registered
  without emitting placeholders (the fragment supplies them): `b.add(sql); ... b.params.add(ps[i])`
  (`dbquery.cj:232-239`).
* `sqlIdent` is a whitelist that **throws** — `[A-Za-z_][A-Za-z0-9_]*` plus one `table.col` prefix
  (`dbquery.cj:109-147`); rationale: identifiers cannot be parameterized, and quoting syntax differs per
  backend (`dbquery.cj:110-115`).
* Dialect gating: `Ne`, `InList`, `NullTest`, `Or`, `Not`, `LIMIT`, `OFFSET`, and INSERT column lists all
  call `requireMySql(d, what)` and **throw at build time** under `Common`
  (`dbquery.cj:160-168`, `dbquery.cj:185`, `dbquery.cj:204`, `dbquery.cj:220`, `dbquery.cj:225`,
  `dbquery.cj:228`, `dbquery.cj:377`, `dbquery.cj:383`, `dbquery.cj:460`).

### 7.2 The four builders (all method signatures verbatim)

```cangjie
public class SelectQuery {                                               // dbquery.cj:284
    public init()                                                        // dbquery.cj:293
    public func select(columns: Array<String>): SelectQuery               // dbquery.cj:296
    public func from(t: String): SelectQuery                             // dbquery.cj:303
    public func filter(c: DbCond): SelectQuery                            // dbquery.cj:308
    public func andFilter(c: DbCond): SelectQuery                         // dbquery.cj:314
    public func orderBy(col: String, desc!: Bool = false): SelectQuery     // dbquery.cj:322
    public func limit(n: Int64): SelectQuery                              // dbquery.cj:329  MySQL only
    public func offset(n: Int64): SelectQuery                             // dbquery.cj:335  MySQL only
    public func toSql(dialect!: DbDialect = DbDialect.Common): (String, Array<DbValue>)  // dbquery.cj:340
    public func query(be: DbBackend): DbResultSet                         // dbquery.cj:391  dialect from be
}

public class InsertQuery {                                               // dbquery.cj:399
    public init()                                                        // dbquery.cj:405
    public func into(t: String): InsertQuery                              // dbquery.cj:407
    public func set(col: String, v: DbValue): InsertQuery                  // dbquery.cj:416  MySQL-only form
    public func values(vs: Array<DbValue>): InsertQuery                    // dbquery.cj:426
    public func toSql(dialect!: DbDialect = DbDialect.Common): (String, Array<DbValue>)  // dbquery.cj:431
    public func exec(be: DbBackend): Int64                                // dbquery.cj:484
}

public class UpdateQuery {                                               // dbquery.cj:492
    public init()                                                        // dbquery.cj:499
    public func update(t: String): UpdateQuery                            // dbquery.cj:501
    public func set(col: String, v: DbValue): UpdateQuery                  // dbquery.cj:506
    public func filter(c: DbCond): UpdateQuery                            // dbquery.cj:512
    public func allowFullTable(): UpdateQuery                             // dbquery.cj:518
    public func toSql(dialect!: DbDialect = DbDialect.Common): (String, Array<DbValue>)  // dbquery.cj:523
    public func exec(be: DbBackend): Int64                                // dbquery.cj:556
}

public class DeleteQuery {                                               // dbquery.cj:564
    public init()                                                        // dbquery.cj:569
    public func from(t: String): DeleteQuery                              // dbquery.cj:571
    public func filter(c: DbCond): DeleteQuery                            // dbquery.cj:576
    public func allowFullTable(): DeleteQuery                             // dbquery.cj:582
    public func toSql(dialect!: DbDialect = DbDialect.Common): (String, Array<DbValue>)  // dbquery.cj:587
    public func exec(be: DbBackend): Int64                                // dbquery.cj:606
}
```

### 7.3 **`set` accepts VALUES, never expressions** (proved from source)

`set`'s parameter type is `DbValue` — and `DbValue` has no expression variant (`db.cj:222-228`).
Rendering always emits an identifier, `" = "`, then a **bound placeholder**:

```cangjie
b.add(sqlIdent(cols[i]))
b.add(" = ")
b.bind(vals[i])        // binds "?" + registers the DbValue   // dbquery.cj:547-549
```

So none of these work through `set`: `col = col + 1`, `count = count - 1`, `NOW()`,
`CONCAT(a,b)`, `updated_at = ? + 1`. `bind` writes a literal `?` and appends a param — the two must be
paired or `bindSql`'s count check throws (`dbquery.cj:102-106`, `db.cj:252-256`).
Workarounds: compute the value in Cangjie and bind it, or issue a hand-written parameterized
`be.exec(sql, params)` (the `?` placeholder mechanism is available on the raw `DbBackend` too).
There is no doc comment in the vendored snapshot that states this limitation in words — it is enforced by
the type system (`UNVERIFIED` whether upstream documents it elsewhere; the vendored copy has no `docs/`).

Other enforced rules: `toSql` throws when `from`/`into`/`update` was not called
(`dbquery.cj:341-343`, `dbquery.cj:432-434`, `dbquery.cj:524-526`); `values([])` throws
(`dbquery.cj:443-445`); `values(...)` + `set(...)` mixed throws (`dbquery.cj:440-442`);
UPDATE/DELETE without a WHERE throw unless `allowFullTable()` was called
(`dbquery.cj:530-537`, `dbquery.cj:591-598`); an empty `And/Or` group throws (`dbquery.cj:247-249`).
Usage example from the source header (`dbquery.cj:18-22`):
```cangjie
let (sql, ps) = SelectQuery().from("users").select(["id", "name"])
    .filter(dbEq("role_id", DbInt(1))).orderBy("id", desc: true).toSql()
let rs = be.query(sql, ps)
```

---

## 8. Build commands

### 8.1 The literal compile line (`server/build.ps1:344`)

```powershell
& $Cjc @fw @app --import-path $Stdx -L $Stdx @libs @extraImportPath @extraLibPath @extraLibs -lcrypt32 -Woff unused -o $exe
```
where
```powershell
$Cjc  = Join-Path $CangjieHome "bin\cjc.exe"                                   # build.ps1:170
$libs = (Get-ChildItem "$Stdx\libstdx*.a" | ForEach-Object { "-l:$($_.Name)" }) # build.ps1:232 (STATIC .a)
$extraImportPath = @("--import-path", $drvDir)                                  # build.ps1:253
$extraLibPath    = @("-L", $drvDir)                                             # build.ps1:254
$extraLibs       = @("-l:mariadb.cdbc", "-l:mariadb.connection", "-l:mariadb.protocol")  # build.ps1:255
$exe             = Join-Path $out "club-server.exe"                             # build.ps1:323
```

Resolved for the SDKs given in the task (single invocation, **one package**, framework src + app src):

```powershell
$CJC  = "C:\Users\ASUS\.cjenv\sdks\1.2.0\cangjie\bin\cjc.exe"
$STDX = "E:\cangjie\stdx\windows_x86_64_cjnative\static\stdx"
$DRV  = "E:\harmonyOS\智能医院客户端\baseline\server\build\mysql-driver"
$FW   = Get-ChildItem "E:\harmonyOS\智能医院客户端\baseline\server\third_party\qingzhou\src\*.cj" |
        Where-Object { $_.Name -notin @('main.cj','unit_tests.cj','manual_runner.cj','store.cj','rbac.cj',
                                         'db_cangdb.cj','db_factory.cj','jsonx_edge_test.cj') } |
        ForEach-Object { $_.FullName }
$APP  = Get-ChildItem "E:\harmonyOS\智能医院客户端\baseline\server\src\*.cj" | ForEach-Object { $_.FullName }
$libs = (Get-ChildItem "$STDX\libstdx*.a" | ForEach-Object { "-l:$($_.Name)" })
& $CJC @FW @APP --import-path $STDX -L $STDX @libs `
      --import-path $DRV -L $DRV -l:mariadb.cdbc -l:mariadb.connection -l:mariadb.protocol `
      -lcrypt32 -Woff unused -o "E:\harmonyOS\智能医院客户端\baseline\server\build\club-server.exe"
```
(`-lcrypt32` is required on Windows for stdx crypto/x509; stdx is linked **statically** — `libstdx*.a`,
`build.ps1:232`. `-Woff unused` only suppresses the unused warning; it does **not** cover parser warnings
such as `unsecure character` — API-NOTES.md:182.)

### 8.2 Build layout, package and props

* **Source mode, not `cjpm`.** Rationale in `build.ps1:13-14`: *"为什么不用 cjpm：轻舟自己的 examples/*.cj
  都写 `package qingzhou`，框架既定用法就是与框架源码一起编译（build.sh 也是这么做的）"*.
* **One output executable** `build\club-server.exe` produced directly by cjc `-o` (`build.ps1:323,344`).
  The `-Target admin` branch produces `build\admin\admin.exe` + `admin-web\dist\` + `admin.env`
  (`build.ps1:306-311,352-373`).
* **Framework file set / exclusions** — the framework's own entry points and self-tests are excluded
  (`build.ps1:317-319`): `main.cj`, `unit_tests.cj`, `manual_runner.cj`, `store.cj`, `rbac.cj`,
  `db_cangdb.cj`, `db_factory.cj`, `jsonx_edge_test.cj`. The `admin` branch keeps `store.cj`
  (`build.ps1:281-283`). Any new `.cj` you add under `third_party/qingzhou/src/` is picked up by the glob
  **and** must be listed in `MANIFEST.sha256` or the build rejects it (`build.ps1:211-213`).
* **Integrity gate:** every listed file is SHA-256 verified and extra/missing framework sources abort the
  build (`build.ps1:195-220`).
* **Toolchain pinning** (must not be deleted, `build.ps1:222-230`):
  ```powershell
  $env:CANGJIE_HOME = $CangjieHome
  $env:PATH = (Join-Path $CangjieHome "bin") + ";" +
              (Join-Path $CangjieHome "third_party\llvm\bin") + ";" + $env:PATH
  ```
  Symptom if cjc/stdx versions are mixed: `LLVM ERROR: Broken module found … opt.exe 崩溃`
  (`build.ps1:226`, `build.ps1:180`).
* **MySQL driver must be prebuilt once** (`build-mysql-driver.ps1`), else the build throws before
  compiling (`build.ps1:241-248`). That script itself requires 1.2.0
  (`build-mysql-driver.ps1:55-56`) and compiles three sub-packages in order
  `protocol → connection → cdbc` with:
  ```powershell
  $cargs = @($files) + @("--import-path", $Stdx, "--import-path", $OutDir) +
           @("-L", $Stdx, "-L", $OutDir) +
           @("-Woff", "unused", "-Woff", "deprecated", "--output-type=staticlib") +
           @("-o", (Join-Path $OutDir $s.name))
  ```
  (`build-mysql-driver.ps1:101-106`; artifacts `mariadb.cdbc.cjo` + 3 static libs in
  `server\build\mysql-driver`.) Link with `-l:<full file name>`: *"`-lmariadb.cdbc` 会被 cjc 按点号拆开，
  实测报 `invalid file or directory '.cdbc'`"* (`build.ps1:249-250`).
* **Driver registration requires an `import`, not just linking**: `import mariadb.cdbc.*` in a compiled
  file (`mysql_store.cj:61-71`; `docs/mysql-backend.md:480`).
* **Runtime deployment set = exe + 4 DLLs**, copied to the output dir by the build
  (`build.ps1:507-550`): `libcangjie-runtime.dll`, `libboundscheck.dll`, `libcrypto-3-x64.dll`,
  `libssl-3-x64.dll`. The OpenSSL pair is resolved from
  `third_party\qingzhou\deps\openssl` → `-OpenSslDir` → Git's `mingw64\bin`, and hashed against
  `deps\openssl\EXPECTED.sha256` (warn-only) (`build.ps1:469-538`).
* **Build fails if the target exe is running** (`ld.lld: ... Permission denied`); the script detects the
  lock and prints the `Stop-Process` remedy (`build.ps1:329-342`).

### 8.3 Running tests

* The **project's** tests are a CLI subcommand of the built exe: `main.cj:1122-1139` dispatches
  `cmd == "test"` to `runTests(mysqlCfg)` (`tests.cj:2726`), which prints `PASS ${t.pass} / FAIL ${t.fail}`
  (`tests.cj:2760`):
  ```powershell
  cd E:\harmonyOS\智能医院客户端\baseline\server       # cwd MUST be server/ (API-NOTES.md:153)
  .\build\club-server.exe test                        # no DSN -> skips all MySQL assertions
  .\build\club-server.exe test "mysql://root:<pw>@127.0.0.1:3307/club_test"
  ```
  ⚠ *"不给 DSN 就不碰数据库；给了就额外跑一次 MySQL 持久化往返"* (`docs/mysql-backend.md:495-498`) —
  a green run without a DSN does **not** prove the DB path.
* The **framework's** own tests are separate: `public func runAllUnitTests(): Int64` in
  `third_party/qingzhou/src/manual_runner.cj:25` (a hand-written runner), plus `@Test` suites in
  `unit_tests.cj` / `jsonx_edge_test.cj` which are **excluded** from this build. Upstream's documented
  way is `./build.sh test` / `./build.sh test-jsonx` (`README.md:96-98`, `CHANGELOG.md:306,316`); the
  printed "All ... scenarios PASSED" string in `manual_runner.cj` is **hard-coded** and its count is stale
  (skill note). A `cjc --test` invocation is the upstream mechanism for the `@Test` suites
  (`CHANGELOG.md:316`) — **UNVERIFIED** in this workspace (no such invocation exists in `build.ps1`).
* `main.exe test`-style runs of the framework require `cwd` = project root because cases read relative
  paths (API-NOTES.md:141, skill rule #3).

---

## 9. Top 15 pitfalls that would break a NEW server

Ranked for "someone writing a brand-new server against this framework". All line numbers are
`baseline/docs/API-NOTES.md` unless stated.

1. **Your top-level names collide with the framework's — same `package qingzhou`.**
   *Rule:* *"我们与轻舟同一 `package qingzhou`。框架已占用 `pad2`、`verifyPassword`、`hashPassword`、
   `randomHex`、`randomId`、`sha256Hex`、`bodyStr`、`jsonGetStr`、`exists`、`size`、`get` 等。新增顶层函数前
   **先 grep 框架源码**"* — API-NOTES.md:135. Symptom: a redeclaration/ambiguity error at compile time.
   *Action:* before adding any top-level `func`, grep `third_party/qingzhou/src`.
2. **Missing OpenSSL 3 DLLs → silent compile, 500 at runtime.**
   *"crypto 的两个 DLL 必须与 exe 同目录"*; *"缺失时**编译期无警告**，运行时才
   `CryptoException: Can not load openssl library or function SHA256_Init`"* — API-NOTES.md:134.
   Ship `libcrypto-3-x64.dll` + `libssl-3-x64.dll` next to the exe (build copies 4 DLLs, `build.ps1:539-549`).
3. **Block comments nest — a `/*` inside a comment swallows the rest of the file.**
   *"仓颉的块注释会嵌套：注释里出现 `/*` 或 `/**` 会吞掉后面整个文件"*, error
   `error: unterminated block comment` pointing at the comment's **first** line — API-NOTES.md:157
   (also :140). Never write `server/src/*.cj`, `/**`, or `/*.cj` inside a comment; the framework itself
   spells out "STAR" for this reason (`router.cj:22-23`).
4. **Cangjie enums do not support `==`.**
   *"`if (a == TransferPresidency)` … 编译报 `invalid binary operator '==' on type 'Enum-Action' and
   'Enum-Action'`"* → *"改用 `match`"* — API-NOTES.md:158. (Strings are fine.) The framework works around
   it by hand-writing `operator func ==` (`router.cj:48-67`).
5. **`cwd` must be the exe's directory** — data dirs, certs and `admin.env` are read by relative path;
   the wrong cwd gives *"假失败 + 假通过"* — API-NOTES.md:141. For tests specifically, cwd must be
   `server/`, else data lands in `build/build/test-data*` and the second run can crash — API-NOTES.md:153.
6. **Non-ASCII command-line arguments crash before `main`.**
   `club-server.exe init-admin 13800000000 你的密码123 data` → no output, exit 1,
   `IllegalArgumentException: Invalid unicode scalar value.` — thrown while Cangjie assembles argv, *"早于
   `main` 里的任何校验（切代码页 936 / 65001 都不行）"*; **`--name-file <UTF-8 file>` is the workaround** —
   API-NOTES.md:144. HTTP bodies are unaffected (UTF-8 JSON is fine).
7. **`Directory.create(recursive: true)` throws if the directory already exists.**
   *"目录已存在**照样抛异常** … 必须先 `exists()` 判断。这个坑会让'第二次落盘'直接崩"* — API-NOTES.md:136.
8. **`rename`'s `to` / `overwrite` are named arguments.**
   `rename(a, b)` does not compile; it is
   `rename(from: String, to!: String, overwrite!: Bool)` — API-NOTES.md:137 with the std.fs signature
   block at :24.
9. **`ArrayList` / collections need `import std.collection.*`** — otherwise
   `undeclared identifier 'ArrayList'` — API-NOTES.md:138.
10. **`⚠️` (U+26A0 + U+FE0F) triggers `warning: unsecure character:\u{FE0F}`.**
    Write the single code point `⚠` — API-NOTES.md:139, :182. Also note `-Woff unused` does **not**
    suppress it (`build.ps1:344`).
11. **Windows has no `std.runtime.Signal`, and in-request `shutdown()` deadlocks.**
    Graceful shutdown must come from an HTTP endpoint or a second thread — API-NOTES.md:142 — and
    *"在请求线程里直接 `handle.shutdown()` 会等待本请求自己结束 → **死锁**。要 `spawn` 到后台线程"* —
    API-NOTES.md:143 (`main.cj:722-735` is the working pattern). If you expose the endpoint, **restrict it
    to local peers** (`main.cj:716-718`, API-NOTES.md:142).
12. **The shutdown reply is racy: `HTTP 200` + empty body, ~6/8 runs.**
    Root cause: `server.close()` does not wait for this request's response to be written; fix =
    `sleep(Duration.second * 1)` before `h.shutdown()` — API-NOTES.md:156 (`main.cj:725-734`).
13. **A 4-byte UTF-8 character (emoji) permanently breaks all writes unless you `SET NAMES utf8mb4`.**
    The driver hardcodes handshake charset 33 (utf8mb3); the framework has no charset option; the row
    INSERT fails with `1366 Incorrect string value`, the single transaction rolls back, the in-memory
    state stays ahead of the DB, and *"之后每一次写都失败，直到重启"* — API-NOTES.md:164. Fix in your own
    file: `db.exec("SET NAMES utf8mb4", Array<DbValue>())` right after connecting, and **throw** if it
    fails (`mysql_store.cj:201-208`).
14. **A non-UTF-8 request body returns 500, not 400.**
    `ctx.bodyJson()` calls `body()` (which does `String.fromUtf8`) **outside** its `try`, so invalid bytes
    escape to the error chain → `HTTP 500 {"ok":false,"error":{"code":"INTERNAL"}}`; `bodyParser`'s
    `onError` cannot catch it (it only covers 413 and JSON syntax errors) — API-NOTES.md:161.
    Typical trigger: PowerShell 5.1 `Invoke-RestMethod -Body <string>` sends ANSI(936) bytes
    (API-NOTES.md:165). Guard with `ctx.bodyBytesCapped(64 KiB)` **before** `bodyParser` and decode
    yourself (the project's `limits.cj` ④ does this; `main.cj:943-947` why it must run first).
15. **`Option` has no `getOrElse`; `JsonValue.fromStr` throws instead of returning `None`; `asXxx()` throws
    on type mismatch.**
    *"`Option` **没有 `getOrElse`**，用 `??` 运算符"* — API-NOTES.md:104;
    *"`JsonValue.fromStr(s)` 解析失败**抛异常**，不是返回 Option"* and
    *"`v.asObject()/asString()/asInt()/asBool()` 类型不符抛异常"* — API-NOTES.md:72-73. Use the safe
    accessors (`jsonx.cj:28-68`) / wrap in `try`, and note that in a `try` a bare `None` hits
    `generic type should be used with type argument` (skill/`util.cj:19-70` built-ins such as
    `parseInt64OrNone`).

**Runner-up pitfalls worth a line each** (from the same file):
* `JsonObject`/`JsonArray` do **not** implement `Iterator` — index with a `while` loop (API-NOTES.md:78).
* `sort(arr, by!: ...)` — the named argument is `by`, not `comparator` (API-NOTES.md:85).
* `String.size` is **bytes**; `UInt8.toString()` yields a number, not a character — accumulate
  `Array<UInt8>` and call `String.fromUtf8` once (API-NOTES.md:88-92).
* `split(sep, maxSplits)`: `maxSplits` counts **pieces**, so `split("=", 2)` gives one split at the first
  `=` (`context.cj:471-473`, API-NOTES.md:91).
* `SHA256`/`HMAC` are streaming: `write()` then `finish()`; `HMAC(key, { => SHA256() })` takes a **factory
  lambda** (API-NOTES.md:57-60).
* No PBKDF2 in stdx — the project implements RFC 2898 itself; 100 000 iterations ≈ 340 ms
  (API-NOTES.md:63-65).
* `HashMap` is unordered; keep a separate `ArrayList` when you need order (skill note).
* The vendored snapshot's framework `Context.bodyBytes()` short-read bug (API-NOTES.md:159) is **already
  fixed** here: `readBodyUpTo` returns EOF only on `n <= 0` (`context.cj:684-701`).
* API-NOTES pitfall #34 (a successful body carrying HTTP 404 when `passOnNotFound = true`) is **already
  fixed in this snapshot** (`router.cj:233-240`), but the project keeps a `statusNormalizer()` in its entry
  and still recommends *asserting `body.code`* in tests (API-NOTES.md:154).
* **PowerShell-side** (only if you write test scripts): PS 5.1 reads BOM-less UTF-8 `.ps1` as ANSI and
  local edits silently strip the BOM → phantom syntax errors (API-NOTES.md:150, :179, :160); `-Body`
  string is sent as ISO-8859-1/ANSI, pass `[Text.Encoding]::UTF8.GetBytes($json)` (API-NOTES.md:165,
  :169); `Invoke-WebRequest` gives no body on non-2xx — use `[System.Net.WebRequest]::Create`
  (API-NOTES.md:152); `$home`/`$host`/`$args` are automatic variables (API-NOTES.md:162, :168);
  `curl` is an alias for `Invoke-WebRequest` (API-NOTES.md:174).
* Do not point `CANGJIE_HOME` at a different SDK than the `cjc` on PATH
  (`build.ps1:222-230`, API-NOTES.md:172): **use cjc 1.2.0 + stdx 1.1.3.1**; mixing versions fails as
  `LLVM ERROR: Broken module found`.

---

## 10. Minimal skeleton a new server can start from

Compile-with-the-framework skeleton (single `package qingzhou`, HTTP, JSON envelope, DB optional):

```cangjie
package qingzhou

import std.collection.*
import std.convert.*
import stdx.encoding.json.*

/* 顶层名字必须避开框架已占用的符号（API-NOTES.md:135）。 */
func newServerRouter() : Router {
    let r = Router()
    r.get("/health", { ctx: Context, _: () -> Unit =>
        let o = JsonObject()
        o.put("ok", JsonBool(true))
        ctx.status(200).json(o.toString())            // jsonw.cj / JsonObject.toString()
    })
    r.get("/api/v1/items/:id", { ctx: Context, _: () -> Unit =>
        let id = parseInt64Or(ctx.paramOr("id", "0"), 0)   // util.cj:28
        let page = parseInt64Or(ctx.queryParamOr("page", "1"), 1)
        let body = ctx.bodyJson()                           // context.cj:429 (?JsonValue)
        let name = bodyStrOr(ctx, "name", "")               // jsonx.cj:174
        ctx.status(200).json(JsonBuilder().putInt("id", id).put("name", name).build())
    })
    return r
}

func buildServer(): QingZhouApp {
    let router = newServerRouter()
    return QingZhouApp()
        .use(requestId())                                   // requestid.cj:36
        .use(logger())                                      // logger.cj:44
        .use(bodyParser(BodyParserOptions()))               // bodyparser.cj:57/61 (1 MiB default)
        .use(cors())                                        // cors.cj:43
        .use(timeout(15000))                                // timeout.cj:57  (must precede router)
        .use(router.middleware())                           // router.cj:221  (router last)
        .onError(jsonErrorHandler())                        // middleware.cj:30
}

main(args: Array<String>): Int64 {
    let port: UInt16 = if (args.size > 0) { parseUInt16Or(args[0], 8080) } else { 8080 }
    let app = buildServer()
    let handle = app.serve(port)          // non-blocking; app.listen(port) blocks (app.cj:78/91)
    handle.wait()
    return 0
}
```

MySQL wiring (copy the working server's shape — direct `MySqlBackend`, because `openStore` drags in
CangDB which this build excludes, `main.cj:110-114`):

```cangjie
import mariadb.cdbc.*                        // MUST import to register the driver (mysql_store.cj:71)

let db = MySqlBackend(host, port, user, pass, database, noBackslashEscapes: false)  // db_mysql.cj:40
db.exec("SET NAMES utf8mb4", Array<DbValue>())                     // required (mysql_store.cj:202)
db.exec("CREATE TABLE IF NOT EXISTS t (id BIGINT NOT NULL, name TEXT NOT NULL, PRIMARY KEY (id))",
        Array<DbValue>())                                          // idempotent DDL (mysql_store.cj:383-386)
let rs = db.query("SELECT id, name FROM t WHERE id = ?", [DbInt(7)])   // db.cj:124 / bindSql
var i: Int64 = 0
while (i < rs.rowCount()) {
    let name = rs.cell(i, 1)                                       // db.cj:46 (0-based, "" on overflow)
    i += 1
}
db.withTransaction({ =>                                        // db.cj:152
    db.exec("UPDATE t SET name = ? WHERE id = ?", [DbStr("x"), DbInt(7)])
})
```
