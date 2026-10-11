package qingzhou

import std.collection.*
import std.time.*
import std.sync.*
import std.fs.*
import std.random.*
import stdx.net.http.*
import stdx.net.tls.*
import stdx.net.tls.common.*
import stdx.crypto.common.Certificate
import stdx.crypto.x509.*

/*
 * SPDX-License-Identifier: MIT
 *
 * 出站调用增强：TLS / 重试退避 / 可注入传输层。
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * 补齐 httpclient.cj 所缺的三项通用出站能力（与具体业务无关，
 * 调用任何第三方 HTTPS API 都受益）：
 *   1. HTTPS(TLS) 客户端 -- TlsClientConfig + CertificateVerifyMode
 *   2. 重试 + 指数退避   -- 网络错误 / 429 / 5xx 可重试判定 + 抖动
 *   3. HttpTransport 抽象 -- StdxTransport（真实）+ MockTransport（无网络可测）
 *
 * 与 httpclient.cj 的关系：后者保持「最简 helper」定位不动；需要 TLS /
 * 重试 / 可测性时改用本模块的 OutboundClient。
 *
 * 关键坑：
 *   - CertificateVerifyMode 自 stdx 1.1.3.1 起位于 stdx.net.tls.common 子包
 *   - 必须 import stdx.net.tls.*，否则运行时报 Global TLS kit is not set
 *   - CustomCA 是带参数的枚举变体，CA 列表作为载荷传入，不是字段
 *   - Array<Certificate> 与 Array<X509Certificate> 不协变，且 as 返回 Option
 *   - TlsClientConfig 是 struct，必须 var 声明后才能赋字段
 *   - Windows 上 Default 模式不读系统证书库，故生产用 CustomCA、本机开发用 TrustAll
 */

/* ===================== TLS 选项 ===================== */

/*
 * 出站 TLS 配置。三种模式按优先级：
 *   trustAll = true        -> 信任所有证书（仅本机开发，见评审 S3）
 *   caBundlePath 非空      -> CustomCA，用指定 PEM bundle 验证（生产推荐）
 *   两者都未设             -> Default，用系统证书库（Windows 上通常不可用）
 */
public class OutboundTlsOptions {
    /* CA bundle 的 PEM 文件路径（可含多张证书）。生产部署随包分发。 */
    public var caBundlePath: String = ""
    /* 信任所有证书。仅限本机开发，禁止进入生产配置。 */
    public var trustAll: Bool = false
    /* SNI 主机名；空串表示用 URL 里的 host。 */
    public var serverName: String = ""

    public init() {}

    /* 是否需要向 ClientBuilder 注入 TLS 配置（Default 模式无需注入）。 */
    public func needsConfig(): Bool {
        return trustAll || caBundlePath.size > 0 || serverName.size > 0
    }
}

/*
 * 读取 PEM 文件并转为 Array<Certificate>（CustomCA 需要的载荷类型）。
 * 注意：Array<X509Certificate> 不能直接当 Array<Certificate> 用（数组不协变），
 * 且 `as` 转换返回 Option，必须逐个拷贝并解包。
 */
public func loadCaCertificates(pemPath: String): Array<Certificate> {
    let pem = String.fromUtf8(File.readFrom(pemPath))
    let x509s = X509Certificate.decodeFromPem(pem)
    return Array<Certificate>(x509s.size, {i =>
        match (x509s[i] as Certificate) {
            case Some(c) => c
            case None => throw Exception("PEM 中第 ${i} 张证书不是 Certificate 类型")
        }
    })
}

/* 由选项构造 TlsClientConfig（顶层函数，避免在 init 中触碰 this）。 */
func buildTlsClientConfig(tls: OutboundTlsOptions): TlsClientConfig {
    var cfg = TlsClientConfig()
    if (tls.trustAll) {
        cfg.verifyMode = CertificateVerifyMode.TrustAll
    } else if (tls.caBundlePath.size > 0) {
        cfg.verifyMode = CertificateVerifyMode.CustomCA(loadCaCertificates(tls.caBundlePath))
    }
    if (tls.serverName.size > 0) {
        cfg.serverName = Some(tls.serverName)
    }
    return cfg
}

/* ===================== 传输层抽象 ===================== */

/* 出站请求描述（传输层的输入）。headers 由调用方合并好。 */
public class OutboundRequest {
    public let method: String
    public let url: String
    public let body: ?String
    public let headers: HashMap<String, String>

    public init(method: String, url: String, body: ?String, headers: HashMap<String, String>) {
        this.method = method
        this.url = url
        this.body = body
        this.headers = headers
    }
}

/*
 * 出站应答（传输层的输出）。两种失败要区分开：
 *   networkError = Some(msg) -> 网络层失败（连不上 / 超时 / TLS 握手失败），status = 0
 *   networkError = None      -> 已收到 HTTP 响应，看 status
 */
public class OutboundResponse {
    public let status: Int64
    public let body: String
    public let networkError: ?String

    public init(status: Int64, body: String, networkError!: ?String = None) {
        this.status = status
        this.body = body
        this.networkError = networkError
    }

    public func isSuccess(): Bool {
        return status >= 200 && status < 300
    }

    public func isNetworkFailure(): Bool {
        return networkError != None
    }
}

/*
 * 传输层抽象：把「怎么发出去」与「发什么」解耦。
 * 真实实现是 StdxTransport（基于 stdx.net.http.Client）；
 * 测试用 MockTransport（可编程应答，全程无网络）。
 */
public interface HttpTransport {
    func send(req: OutboundRequest): OutboundResponse
    func close(): Unit
}

/* 真实实现：基于 stdx.net.http.Client；可选注入 TLS 配置。 */
public class StdxTransport <: HttpTransport {
    private let client: Client
    private let readTimeout: Duration
    private let writeTimeout: Duration

    /* 明文 HTTP。 */
    public init(timeoutSecs: Int64) {
        this.readTimeout = Duration.second * timeoutSecs
        this.writeTimeout = Duration.second * timeoutSecs
        this.client = ClientBuilder().noProxy().build()
    }

    /* HTTPS：按 tls 选项注入 TlsClientConfig。 */
    public init(timeoutSecs: Int64, tls: OutboundTlsOptions) {
        this.readTimeout = Duration.second * timeoutSecs
        this.writeTimeout = Duration.second * timeoutSecs
        var builder = ClientBuilder().noProxy()
        if (tls.needsConfig()) {
            builder = builder.tlsConfig(buildTlsClientConfig(tls))
        }
        this.client = builder.build()
    }

    public func send(req: OutboundRequest): OutboundResponse {
        var builder = HttpRequestBuilder()
            .method(req.method)
            .url(req.url)
            .readTimeout(readTimeout)
            .writeTimeout(writeTimeout)
        for ((k, v) in req.headers) {
            builder = builder.header(k, v)
        }
        match (req.body) {
            case Some(text) => builder = builder.body(text)
            case None => ()
        }
        try {
            let resp = client.send(builder.build())
            return OutboundResponse(Int64(resp.status), readBodyText(resp.body))
        } catch (e: Exception) {
            // 网络层失败：status 记 0，错误信息留给重试判定与上层观测
            return OutboundResponse(0, "", networkError: Some(e.message))
        }
    }

    public func close(): Unit {
        client.close()
    }
}

/*
 * 测试实现：按预设队列应答（FIFO），并记录收到的请求。
 * 队列耗尽后返回 defaultResponse，便于断言「重试到第 N 次才成功」。
 */
public class MockTransport <: HttpTransport {
    private let queue: ArrayList<OutboundResponse> = ArrayList<OutboundResponse>()
    private let sent: ArrayList<OutboundRequest> = ArrayList<OutboundRequest>()
    private var cursor: Int64 = 0
    private let fallback: OutboundResponse

    public init(fallback!: OutboundResponse = OutboundResponse(200, "")) {
        this.fallback = fallback
    }

    /* 入队一个预设应答，返回 this 以便链式追加。 */
    public func enqueue(resp: OutboundResponse): MockTransport {
        queue.add(resp)
        return this
    }

    /* 已发送的请求，按发送顺序（断言重试次数 / 参数用）。 */
    public func sentRequests(): ArrayList<OutboundRequest> {
        return sent
    }

    public func send(req: OutboundRequest): OutboundResponse {
        sent.add(req)
        if (cursor < queue.size) {
            let r = queue[cursor]
            cursor += 1
            return r
        }
        return fallback
    }

    public func close(): Unit {}
}

/* ===================== 重试策略 ===================== */

/*
 * 重试策略：指数退避 + 可选抖动。
 * 可重试的判定依据（对齐幂等语义之外，只看传输层与状态码）：
 *   网络错误（连不上 / 超时） -> 可重试
 *   429 Too Many Requests      -> 可重试（服务端限流，退避后大概率成功）
 *   5xx                        -> 可重试（服务端瞬时故障）
 *   4xx（除 429）              -> 不重试（客户端问题，重试无意义）
 */
public class RetryPolicy {
    /* 总尝试次数（含首次）。1 表示不重试。 */
    public var maxAttempts: Int64 = 3
    /* 首次失败后的基准退避（毫秒）。 */
    public var baseDelayMs: Int64 = 200
    /* 退避上限（毫秒）。 */
    public var maxDelayMs: Int64 = 5000
    /* 是否对退避加抖动（避免重试风暴同步）。 */
    public var jitter: Bool = true
    public var retryOn429: Bool = true
    public var retryOn5xx: Bool = true
    /* 网络层错误是否重试（连接被拒 / 超时等）。 */
    public var retryOnNetworkError: Bool = true

    public init() {}

    public init(maxAttempts: Int64, baseDelayMs: Int64, maxDelayMs: Int64) {
        this.maxAttempts = maxAttempts
        this.baseDelayMs = baseDelayMs
        this.maxDelayMs = maxDelayMs
    }

    /* 第 attempt 次尝试失败后，是否还应重试（attempt 从 1 开始）。 */
    public func shouldRetry(resp: OutboundResponse, attempt: Int64): Bool {
        if (attempt >= maxAttempts) {
            return false
        }
        if (resp.isNetworkFailure()) {
            return retryOnNetworkError
        }
        if (retryOn429 && resp.status == 429) {
            return true
        }
        if (retryOn5xx && resp.status >= 500 && resp.status < 600) {
            return true
        }
        return false
    }

    /* 第 attempt 次失败后的退避毫秒数（指数增长，受 maxDelayMs 封顶，可抖动）。 */
    public func delayMsFor(attempt: Int64): Int64 {
        var d = baseDelayMs
        var i: Int64 = 1
        while (i < attempt) {
            if (d >= maxDelayMs) {
                break
            }
            d = d * 2
            i += 1
        }
        if (d > maxDelayMs) {
            d = maxDelayMs
        }
        if (jitter && d > 2) {
            let half = d / 2
            let r = Random()
            d = half + Int64(r.nextUInt64() % UInt64(half + 1))
        }
        return d
    }
}

/* ===================== 出站客户端 ===================== */

/*
 * 带重试的出站客户端：transport（怎么发）+ retry（失败怎么办）+ 并发上限。
 * 传输层可注入，因此单测可全程离线（MockTransport）。
 *
 * maxConcurrency > 0 时用 std.sync.Semaphore 限制同时在途的请求数：
 * 入站方向有 ratelimit 中间件保护服务端，但出站方向没有对应机制，
 * 突发调用会把下游打挂或耗尽本进程连接。信号量在 send 入口 acquire、
 * finally 里 release，保证异常路径也能归还。
 */
public class OutboundClient {
    private let transport: HttpTransport
    private let retry: RetryPolicy
    private let semaphore: ?Semaphore
    private let defaultHeaders: HashMap<String, String> = HashMap<String, String>()

    public init(transport: HttpTransport, retry!: RetryPolicy = RetryPolicy(), maxConcurrency!: Int64 = 0) {
        this.transport = transport
        this.retry = retry
        if (maxConcurrency > 0) {
            this.semaphore = Some(Semaphore(maxConcurrency))
        } else {
            this.semaphore = None
        }
    }

    /* 设置默认请求头（每次请求都带），返回 this 以便链式配置。 */
    public func setDefaultHeader(name: String, value: String): OutboundClient {
        defaultHeaders[name] = value
        return this
    }

    /* 合并默认头与本次请求头（本次优先）。 */
    private func mergeHeaders(headers: ?HashMap<String, String>): HashMap<String, String> {
        let merged = HashMap<String, String>()
        for ((k, v) in defaultHeaders) {
            merged[k] = v
        }
        match (headers) {
            case Some(h) =>
                for ((k, v) in h) {
                    merged[k] = v
                }
            case None => ()
        }
        return merged
    }

    /*
     * 发送请求，按 retry 策略自动重试，返回最终结果。
     * 若配置了 maxConcurrency，全程持有信号量（含退避等待），保证在途数受控。
     * 退避等待用 std.sync.sleep（仓颉 1.2.0 起可用；早期版本需自旋）。
     */
    public func send(method: String, url: String, body!: ?String = None, headers!: ?HashMap<String, String> = None): OutboundResponse {
        match (semaphore) {
            case Some(s) => s.acquire()
            case None => ()
        }
        try {
            let req = OutboundRequest(method, url, body, mergeHeaders(headers))
            var attempt: Int64 = 1
            var resp = transport.send(req)
            while (retry.shouldRetry(resp, attempt)) {
                sleep(Duration.millisecond * retry.delayMsFor(attempt))
                attempt += 1
                resp = transport.send(req)
            }
            return resp
        } finally {
            match (semaphore) {
                case Some(s) => s.release()
                case None => ()
            }
        }
    }

    /* 便捷方法。 */
    public func get(url: String, headers!: ?HashMap<String, String> = None): OutboundResponse {
        return send("GET", url, headers: headers)
    }

    public func post(url: String, body: String, headers!: ?HashMap<String, String> = None): OutboundResponse {
        return send("POST", url, body: Some(body), headers: headers)
    }

    public func postJson(url: String, json: String, headers!: ?HashMap<String, String> = None): OutboundResponse {
        let h = match (headers) {
            case Some(x) => x
            case None => HashMap<String, String>()
        }
        h["content-type"] = "application/json"
        return send("POST", url, body: Some(json), headers: Some(h))
    }

    public func close(): Unit {
        transport.close()
    }
}
