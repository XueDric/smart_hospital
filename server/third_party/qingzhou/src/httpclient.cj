package qingzhou

import std.collection.*
import std.io.*
import stdx.net.http.*
import stdx.encoding.json.*

/*
 * SPDX-License-Identifier: MIT
 *
 * 出站 HTTP 客户端薄封装（helper）。
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * 只封装出站调用最常用的「GET/POST + 文本/JSON + 错误处理」样板，
 * 减少业务代码重复。需要完整能力（自定义 header、TLS、代理、重定向、
 * 连接复用等）请直接用 stdx.net.http.Client，本模块不重复实现。
 *
 * 语义约定：非 2xx 状态码、网络错误、JSON 解析失败一律返回 None（不抛异常），
 * 由调用方决定如何处理。
 */

/* 读 InputStream 全部内容并转为字符串（UTF-8）。 */
func readBodyText(body: InputStream): String {
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
        if (n < buf.size) {
            break
        }
    }
    return String.fromUtf8(out.toArray())
}

/* 判断状态码是否为成功（2xx）。 */
func isSuccess(status: UInt16): Bool {
    return Int64(status) >= 200 && Int64(status) < 300
}

/* GET，返回响应文本 body；非 2xx 或网络错误返回 None。 */
public func httpGetText(url: String): ?String {
    let client = ClientBuilder().build()
    var result: ?String = None
    try {
        let resp = client.get(url)
        if (isSuccess(resp.status)) {
            result = Some(readBodyText(resp.body))
        }
    } catch (e: Exception) {
        result = None
    }
    client.close()
    return result
}

/* GET，返回解析后的 JSON；非 2xx / 非 JSON / 网络错误返回 None。 */
public func httpGetJson(url: String): ?JsonValue {
    match (httpGetText(url)) {
        case Some(text) =>
            return try { Some(JsonValue.fromStr(text)) } catch (e: Exception) { None }
        case None => return None
    }
}

/* POST JSON 字符串，返回响应文本 body；非 2xx 或网络错误返回 None。 */
public func httpPostJson(url: String, jsonBody: String): ?String {
    let client = ClientBuilder().build()
    var result: ?String = None
    try {
        let resp = client.post(url, jsonBody)
        if (isSuccess(resp.status)) {
            result = Some(readBodyText(resp.body))
        }
    } catch (e: Exception) {
        result = None
    }
    client.close()
    return result
}

/* -------------------------------------------------------------------------
 * 以下为「完整能力」层：可复用连接 + 超时 + 自定义头的出站 HTTP 客户端。
 * 上面的 httpGetText / httpGetJson / httpPostJson 保持薄封装语义不变，
 * 面向一次性调用；高频转发（微服务网关、服务间调用）请改用 HttpClient。
 * ------------------------------------------------------------------------- */

/*
 * 出站 HTTP 调用结果，区分三种情况，便于上层做熔断 / 降级 / 重试决策：
 *   ok=true              -> 2xx 成功，body 为响应体文本
 *   ok=false, reason=None -> 服务器返回了非 2xx 状态码（status 有效）
 *   ok=false, reason=Some -> 网络 / 超时 / 读体失败（status 恒为 0）
 */
public class HttpResult {
    public let status: UInt16
    public let body: String
    public let ok: Bool
    public let reason: ?String

    public init(status: UInt16, body: String, ok: Bool, reason: ?String) {
        this.status = status
        this.body = body
        this.ok = ok
        this.reason = reason
    }

    /* 是否网络层失败（未到达服务器或读体异常）。 */
    public func isNetworkError(): Bool {
        return reason.isSome()
    }
}

/*
 * 流式响应结果：持有底层 HttpResponse 的 body 流（InputStream），
 * 供 SSE / chunked 透传「边读边转发」。用完必须 close() 释放连接。
 *
 * 与 HttpResult（一次性读完）互补：HttpResult 用于普通请求，
 * HttpStream 用于需要流式消费响应体的场景。
 */
public class HttpStream {
    public let status: UInt16
    public let ok: Bool
    private let resp: HttpResponse
    private let client: Client

    init(resp: HttpResponse, client: Client) {
        this.status = resp.status
        this.ok = isSuccess(resp.status)
        this.resp = resp
        this.client = client
    }

    /* 读一块响应体，返回读到的字节数（<=0 表示流结束/出错）。 */
    public func read(buf: Array<UInt8>): Int64 {
        return resp.body.read(buf)
    }

    /* 关闭响应体与底层连接。 */
    public func close(): Unit {
        resp.close()
        client.close()
    }
}

/*
 * 可复用连接的出站 HTTP 客户端。
 *
 * 与薄封装函数的区别：
 *   - 持有一个长期存活的 stdx.net.http.Client，跨请求复用 TCP 连接；
 *   - 可配置默认请求头（Authorization / X-Request-Id / trace 等）；
 *   - 每次请求统一套用读 / 写超时，避免下游挂死拖垮调用方。
 *
 * 用法：
 *   let c = HttpClient(5, 5)                      // 读 / 写超时各 5 秒
 *   c.setDefaultHeader("authorization", "Bearer ...")
 *   let r = c.post("http://127.0.0.1:9000/infer", "{\"prompt\":\"hi\"}")
 *   if (r.ok) { ... } else { ... }
 *   c.close()
 */
public class HttpClient {
    private let client: Client
    private let defaultHeaders: HashMap<String, String>
    private let readTimeout: Duration
    private let writeTimeout: Duration

    public init(readTimeoutSecs: Int64, writeTimeoutSecs: Int64) {
        // noProxy()：微服务场景访问的是内网 worker（网关 -> 计算节点），
        // 必须直连；否则 stdx 默认走系统 http_proxy，回环地址也会被代理
        // 拦截成 502 upstream connect failed。
        this.client = ClientBuilder().noProxy().build()
        this.defaultHeaders = HashMap<String, String>()
        this.readTimeout = Duration.second * readTimeoutSecs
        this.writeTimeout = Duration.second * writeTimeoutSecs
    }

    /* 设置默认请求头，返回 this 以便链式配置。 */
    public func setDefaultHeader(name: String, value: String): HttpClient {
        defaultHeaders[name] = value
        return this
    }

    public func get(url: String): HttpResult {
        return request("GET", url, None, None)
    }

    public func getWith(url: String, headers: HashMap<String, String>): HttpResult {
        return request("GET", url, None, Some(headers))
    }

    public func post(url: String, body: String): HttpResult {
        return request("POST", url, Some(body), None)
    }

    public func postWith(url: String, body: String, headers: HashMap<String, String>): HttpResult {
        return request("POST", url, Some(body), Some(headers))
    }

    public func put(url: String, body: String): HttpResult {
        return request("PUT", url, Some(body), None)
    }

    public func putWith(url: String, body: String, headers: HashMap<String, String>): HttpResult {
        return request("PUT", url, Some(body), Some(headers))
    }

    public func delete(url: String): HttpResult {
        return request("DELETE", url, None, None)
    }

    public func deleteWith(url: String, headers: HashMap<String, String>): HttpResult {
        return request("DELETE", url, None, Some(headers))
    }

    /*
     * 通用请求。method 取 "GET"/"POST"/"PUT"/"DELETE" 等；body / headers
     * 传 None 表示缺省。
     *
     * 注意：stdx 的 HttpRequestBuilder 是 immutable-chain 风格，每个 builder
     * 方法都返回新对象，必须用 var 重新赋值，否则 header / body 的修改会被
     * 静默丢弃（QingZhou 在服务端 responseBuilder 上踩过同样的坑）。
     */
    public func request(method: String, url: String, body: ?String, headers: ?HashMap<String, String>): HttpResult {
        var builder = HttpRequestBuilder()
            .method(method)
            .url(url)
            .readTimeout(readTimeout)
            .writeTimeout(writeTimeout)
        for ((k, v) in defaultHeaders) {
            builder = builder.header(k, v)
        }
        match (headers) {
            case Some(h) =>
                for ((k, v) in h) {
                    builder = builder.header(k, v)
                }
            case None => ()
        }
        match (body) {
            case Some(text) => builder = builder.body(text)
            case None => ()
        }
        let req = builder.build()
        try {
            let resp = client.send(req)
            let status = resp.status
            let text = readBodyText(resp.body)
            if (isSuccess(status)) {
                return HttpResult(status, text, true, None)
            }
            return HttpResult(status, text, false, None)
        } catch (e: Exception) {
            return HttpResult(UInt16(0), "", false, Some(e.message))
        }
    }

    /*
     * 流式 POST：返回 HttpStream 而非一次性读完的 HttpResult。
     * 用于 SSE / chunked 透传等需要边读边转发的场景。
     *
     * 用独立 Client（不复用长期 client），避免流式响应未读完就
     * 污染连接池；调用方读完必须调用 HttpStream.close() 释放。
     *
     * 注意：client.send 可能抛异常（网络错误），由调用方 try 处理。
     */
    public func postStream(url: String, body: String, headers: ?HashMap<String, String>): HttpStream {
        let client = ClientBuilder().noProxy().build()
        var builder = HttpRequestBuilder()
            .method("POST")
            .url(url)
            .readTimeout(readTimeout)
            .writeTimeout(writeTimeout)
        for ((k, v) in defaultHeaders) {
            builder = builder.header(k, v)
        }
        match (headers) {
            case Some(h) =>
                for ((k, v) in h) {
                    builder = builder.header(k, v)
                }
            case None => ()
        }
        builder = builder.body(body)
        let req = builder.build()
        let resp = client.send(req)
        return HttpStream(resp, client)
    }

    /* 关闭客户端并释放所有连接；调用后不可再发请求。 */
    public func close(): Unit {
        client.close()
    }
}
