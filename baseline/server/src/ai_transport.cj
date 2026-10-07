package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * AI 模块专用的出站传输层（实现框架预留的 HttpTransport 注入点）
 *
 * 为什么不用框架的 `StdxTransport`：
 *   `outbound.cj` 的读体走 `httpclient.cj` 的 `readBodyText`，而**那一份还是旧写法**：
 *
 *       if (n < buf.size) { break }        // ← 把「没读满」当成流结束
 *
 *   入站侧早已因此踩坑并修好 —— `context.cj` 把教训写成了铁律：
 *   「**短读不是 EOF** …… 只有 `n <= 0` 才是流结束」。出站这份没跟上。
 *
 * 后果：模型回答只要发生一次短读就被截断 → `JsonValue.fromStr` 失败 →
 * `aiParseOutput` 返回 None → 重试一次仍失败 → **静默降级为 fallback**。
 * 症状是「短问题好用、长回答偶发失灵」，且**不报错**。
 *
 * 已用本地「分块慢发」的桩**确定性复现**（见 `spike/llm-truncation/`）：
 *   桩每 1000 字节 / 20ms 发一块，客户端实际收到 ——
 *     框架读法：**固定 1000 字节**（只拿到第一块就 break）
 *     正确读法：与桩发出的字节数一致（20000 档收到 20,263 字节）
 *   为什么评审没能复现：localhost 上整包往往几次就读满 4096，短读不触发。
 *
 * 本文件**只在这一点上**与框架不同，其余（TLS 注入 / noProxy / 超时 / 错误归类）
 * 与 `StdxTransport` 保持一致，便于对照。
 */

import std.collection.*
import std.io.*
import stdx.net.http.*
import stdx.net.tls.*
import stdx.net.tls.common.*

/* 单次响应的字节上限：模型补全不会很大，这是防上游无限吐字节的兜底。 */
public let AI_MAX_RESPONSE_BYTES: Int64 = 256 * 1024

/*
 * 正确的读体：**只有 n <= 0 才是流结束**。
 * 另加一个字节上限兜底（AI-8）：上游若持续吐字节，不至于把内存吃光。
 */
func aiReadBodyText(body: InputStream, maxBytes: Int64): String {
    let buf = Array<UInt8>(4096, { _ => UInt8(0) })
    let out = ArrayList<UInt8>()
    while (true) {
        let n = body.read(buf)
        if (n <= 0) {
            break
        }
        var i: Int64 = 0
        while (i < n) {
            out.add(buf[i])
            i += 1
        }
        if (maxBytes > 0 && out.size >= maxBytes) {
            break
        }
    }
    return String.fromUtf8(out.toArray())
}

public class AiTransport <: HttpTransport {
    private let client: Client
    private let readTimeout: Duration
    private let writeTimeout: Duration
    /* 单次响应的字节上限（<= 0 表示不限） */
    private let maxResponseBytes: Int64

    public init(timeoutSecs: Int64, tls: OutboundTlsOptions, maxResponseBytes: Int64) {
        this.readTimeout = Duration.second * timeoutSecs
        this.writeTimeout = Duration.second * timeoutSecs
        this.maxResponseBytes = maxResponseBytes
        var builder = ClientBuilder().noProxy()
        /*
         * F-4：**关掉自动重定向**（fail-closed，不跟随 3xx）。
         *
         * stdx 的客户端**默认跟随 3xx**，而我们的出站是"把一个固定端点当模型来用" ——
         * 跟随一个由**对端**给的 Location 没有道理：
         *   · 被劫持 / 配错的端点能让本服务去请求**任意主机**（很窄的 SSRF / 内网探测面）；
         *   · 跟随会把 POST 降级成 GET 并**丢掉请求体**，prompt 根本没送到 → 恒 fallback，
         *     而日志里看不出这是重定向造成的（静默，最糟的那种）。
         * 评审 302 探针实测结清：**密钥不会被转发**（Authorization 不跟过去），
         * 所以这不是泄密问题，而是上面那两点。
         *
         * 实测 A/B（同一请求打到一个返回 302 的端点）：
         *   `autoRedirect(false)` → 拿到原始 **302**；默认 → 跟随之后 **200**。
         *
         * 关掉之后：3xx 被 `aiClassify` 归为 `http_error`（非 2xx / 非 429 / 非 5xx 的兜底），
         * 而 `aiRetryable` 不放行 `http_error` → **立刻降级、不白烧一次重试**；
         * 审计行本来就带 `status=`（R-11 修），运维能直接看到 `status=302`。
         *
         * ⚠ API 名是 `ClientBuilder.autoRedirect(Bool)` —— **不是** `noRedirect` /
         * `followRedirect` / `maxRedirect`（那些在 stdx 里都不存在）。
         * 名字是从 `stdx.net.http.cjo` 的**符号元数据**里读出来的，
         * 并已用「编译通过 + 运行时 A/B（302 vs 200）」两重验证，没有靠猜。
         */
        builder = builder.autoRedirect(false)
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
            return OutboundResponse(Int64(resp.status), aiReadBodyText(resp.body, maxResponseBytes))
        } catch (e: Exception) {
            /* 与框架同一口径：网络层失败记 status=0 + reason */
            return OutboundResponse(0, "", networkError: Some(e.message))
        }
    }

    public func close(): Unit {
        client.close()
    }
}
