package qingzhou

import std.collection.*
import std.env.*
import stdx.net.http.*
import stdx.net.tls.*
import stdx.crypto.x509.*
import stdx.crypto.keys.*
import stdx.log.*
import stdx.logger.*

/*
 * SPDX-License-Identifier: MIT
 *
 * Application.
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 *  - use(mw): register business middleware (chainable)
 *  - onError(mw): register error handler (called only when business chain throws)
 *  - onListen(cb) / onShutdown(cb): lifecycle hooks (chainable). onListen
 *    fires after the server starts listening (each serve/listen boot);
 *    onShutdown fires after graceful shutdown() drains in-flight requests,
 *    in registration order, with per-hook error isolation (one failing hook
 *    does not block the rest). Typical use: preheat caches / register
 *    service discovery on listen; flush logs / close the DbPool on
 *    shutdown (app.onShutdown({ => pool.close() })).
 *  - listen(port): boot stdx server with a custom catch-all distributor
 *    that forwards every request to the QingZhouApp handler. The stdx
 *    built-in `DirectDistributor` is exact-match only (one entry per
 *    literal path) and would otherwise fall back to its own NotFoundHandler
 *    for /hello, /users/42, etc. Our router middleware then decides
 *    200/404/405 internally.
 */
public class QingZhouApp {
    private let stack: ArrayList<Middleware> = ArrayList<Middleware>()
    private let errorStack: ArrayList<Middleware> = ArrayList<Middleware>()
    // 注册序执行；onShutdown 钩子随 ServerHandle 走。
    private let listenHooks: ArrayList<() -> Unit> = ArrayList<() -> Unit>()
    private let shutdownHooks: ArrayList<() -> Unit> = ArrayList<() -> Unit>()

    public init() {}

    public func use(mw: Middleware): QingZhouApp {
        stack.add(mw)
        return this
    }

    public func onError(mw: Middleware): QingZhouApp {
        errorStack.add(mw)
        return this
    }

    /* 生命周期钩子：监听启动后回调（每次 serve/listen 启动都会触发，
     * 异常直接抛出——启动期初始化失败应当 fail-fast，不带病上线）。 */
    public func onListen(cb: () -> Unit): QingZhouApp {
        listenHooks.add(cb)
        return this
    }

    /* 生命周期钩子：优雅关闭（shutdown() 排空在途请求后）回调。
     * 按注册序执行；单个钩子抛异常只打印告警、不阻断其余钩子。 */
    public func onShutdown(cb: () -> Unit): QingZhouApp {
        shutdownHooks.add(cb)
        return this
    }

    public func handler(): AppHandler {
        return AppHandler(stack, errorStack)
    }

    /* Blocking: boot the server and block until it is shut down.
     * Equivalent to serve(port).wait(). Kept for the common demo use.
     * bindAddr 可指定监听地址，默认 0.0.0.0。
     * maxRequestBodySize 可调请求体上限（None 走 stdx
     * 默认，约几 MB；大文件上传场景需显式调大，见 docs/CAVEATS.md）。 */
    public func listen(port: UInt16, bindAddr!: String = "0.0.0.0", maxRequestBodySize!: ?Int64 = None): Unit {
        let handle = serve(port, bindAddr: bindAddr, maxRequestBodySize: maxRequestBodySize)
        handle.wait()
    }

    /* non-blocking boot. Spawns the blocking server.serve() onto a
     * background CJThread and returns a handle. Call shutdown() to stop
     * accepting new connections and drain in-flight requests (graceful
     * shutdown); call wait() to simply block until the server exits.
     * bindAddr! 命名参数 —— 旧版写死 0.0.0.0，内网/容器
     * 场景无法只绑 127.0.0.1。示例：app.serve(3000, bindAddr: "127.0.0.1")
     * maxRequestBodySize —— stdx 默认上限较低（约几 MB），8MB 级
     * 大文件上传会收到 "The content too large."；传 Some(n) 调大。 */
    public func serve(port: UInt16, bindAddr!: String = "0.0.0.0", maxRequestBodySize!: ?Int64 = None): ServerHandle {
        bootServer(port, None, bindAddr, maxRequestBodySize)
    }

    /* HTTPS: boot a TLS server. certPem / keyPem are PEM-encoded strings —
     * the X.509 certificate chain and its matching private key. */
    public func serveTls(port: UInt16, certPem: String, keyPem: String, bindAddr!: String = "0.0.0.0", maxRequestBodySize!: ?Int64 = None): ServerHandle {
        let certs = X509Certificate.decodeFromPem(certPem)
        // RSAPrivateKey.decodeFromPem 在 stdx 1.0.5.1 与 1.1.3.1 均实现；
        // PrivateKey 接口上的 decodeFromPem 在 1.1.x 已移除，故走具体类型。
        let key = RSAPrivateKey.decodeFromPem(keyPem)
        bootServer(port, Some(TlsServerConfig(certs, key)), bindAddr, maxRequestBodySize)
    }

    /* Blocking HTTPS boot, equivalent to serveTls(port, cert, key).wait(). */
    public func listenTls(port: UInt16, certPem: String, keyPem: String, bindAddr!: String = "0.0.0.0", maxRequestBodySize!: ?Int64 = None): Unit {
        let handle = serveTls(port, certPem, keyPem, bindAddr: bindAddr, maxRequestBodySize: maxRequestBodySize)
        handle.wait()
    }

    /* Shared boot path for HTTP (tls=None) and HTTPS (tls=Some(config)).
     * Builds the catch-all distributor, optional TLS layer, logger and
     * spawns the blocking server.serve() onto a background thread. */
    private func bootServer(port: UInt16, tls: ?TlsServerConfig, bindAddr: String, maxRequestBodySize: ?Int64): ServerHandle {
        let app = handler()
        // Build server with our custom distributor before .build().
        let dispatcher = CatchAllDistributor({ httpCtx: HttpContext =>
            let ctx = Context(httpCtx)
            app.handle(ctx)
        })
        // 抑制 stdx 服务器内部日志噪音（如客户端断开连接的 WARN），只保留 ERROR。
        // 框架自己的请求日志由 logger() 中间件负责，不受此设置影响。
        let serverLog = SimpleLogger(getStdOut())
        serverLog.level = LogLevel.ERROR
        var builder = ServerBuilder()
            .addr(bindAddr).port(port)
        match (tls) {
            case Some(cfg) => builder = builder.tlsConfig(cfg)
            case None => ()
        }
        // 请求体上限（stdx 默认较低，大文件上传场景显式调大）
        match (maxRequestBodySize) {
            case Some(n) => builder = builder.maxRequestBodySize(n)
            case None => ()
        }
        let server = builder
            .distributor(dispatcher)
            .logger(serverLog)
            .build()
        println("QingZhou listening on ${bindAddr}:${port}")
        let fut = spawn {
            server.serve()
        }
        // serve 线程启动后触发 onListen（fail-fast，
        // 异常上抛）。bind 由 serve 线程异步完成——钩子内不应假定端口已可
        // 连接（预热缓存/服务发现注册等不依赖端口自身的初始化放这里）。
        for (cb in listenHooks) {
            cb()
        }
        return ServerHandle(server, fut, shutdownHooks)
    }
}

/*
 * handle to a running server, returned by QingZhouApp.serve().
 * shutdown() is the graceful path: close() stops the accept loop and
 * drains in-flight requests before serve() returns; wait() just blocks
 * until the server thread finishes. Both are safe to call once.
 * shutdown() 在排空在途请求后按注册序执行
 * onShutdown 钩子（单钩子异常隔离——收尾阶段不应因个别清理失败
 * 而丢弃其余清理）。wait() 不触发钩子（进程直接退出无收尾语义）。
 *
 * NOTE on signals: Cangjie's std.runtime.Signal is not supported on
 * Windows, so there is no portable Ctrl+C -> shutdown() hook here. On
 * POSIX targets the app can wire Signal.SIGINT to a shutdown flag; on
 * Windows, trigger shutdown() from an admin endpoint or a second thread.
 */
public class ServerHandle {
    private let server: Server
    private let fut: Future<Unit>
    private let shutdownHooks: ArrayList<() -> Unit>

    init(server: Server, fut: Future<Unit>, shutdownHooks: ArrayList<() -> Unit>) {
        this.server = server
        this.fut = fut
        this.shutdownHooks = shutdownHooks
    }

    /* 优雅关闭：停 accept → 排空在途请求 → 执行 onShutdown 钩子。
     * 停服调用（close/get）异常只打印不重抛——关闭阶段的错误不应
     * 阻断收尾钩子；已知竞态：shutdown 紧跟 serve() 调用时，close()
     * 可能先于 serve 线程的 bind() 执行，此时 serve 线程会以
     * "Socket is already closed" 退出，本方法视为服务已停止。
     * 生产场景（运行一段时间后才关停）不受影响。 */
    public func shutdown(): Unit {
        try {
            server.close()
            fut.get()
        } catch (e: Exception) {
            println("[qingzhou] server stop: ${e.message}")
        }
        // 排空完成后执行收尾钩子：注册序 + 异常隔离。
        for (cb in shutdownHooks) {
            try {
                cb()
            } catch (e: Exception) {
                println("[qingzhou] onShutdown hook failed: ${e.message}")
            }
        }
    }

    public func wait(): Unit {
        fut.get()
    }
}

/*
 * Custom distributor: register() is a no-op (the framework does its own
 * routing inside the Koa chain); distribute(path) always returns the
 * same root handler so stdx never falls through to its own NotFoundHandler.
 */
class CatchAllDistributor <: HttpRequestDistributor {
    private let root: HttpRequestHandler

    init(root: (HttpContext) -> Unit) {
        this.root = LambdaHandler(root)
    }

    public func register(path: String, handler: (HttpContext) -> Unit): Unit {
        // intentional no-op: paths are handled by the framework's router
    }

    public func register(path: String, handler: HttpRequestHandler): Unit {
        // intentional no-op
    }

    public func distribute(path: String): HttpRequestHandler {
        return root
    }
}

/*
 * Adapt a (HttpContext) -> Unit lambda into a HttpRequestHandler.
 * HttpRequestHandler is an interface, so we need a concrete class.
 */
class LambdaHandler <: HttpRequestHandler {
    private let f: (HttpContext) -> Unit

    init(f: (HttpContext) -> Unit) {
        this.f = f
    }

    public func handle(ctx: HttpContext): Unit {
        f(ctx)
    }
}
