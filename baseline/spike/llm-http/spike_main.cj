package spike

/*
 * 仓颉出站 HTTP/HTTPS 能力 spike —— 为「任务全生命周期智能体」接入大模型做前置验证。
 *
 * 验证五项（对应评估报告里的四项风险 + 一项补充）：
 *   R1  明文 HTTP：ClientBuilder + HttpRequestBuilder 能否稳定发 POST / 带头 / 读响应体
 *   R2  超时：readTimeout 到点是否真的中断（而不是挂死）
 *   R3  JSON：stdx.encoding.json 对「合法 / 截断 / 代码块包裹 / 前后带自然语言」的边界行为
 *   R4  并发：外部慢调用若在锁内，会不会把整个服务串行化（复现 PBKDF2 那次的老问题）
 *   R5  HTTPS：ClientBuilder().tlsConfig(TlsClientConfig) 能否调通公网 HTTPS（大模型 API 必须是 HTTPS）
 *
 * 用法：spike.exe <baseUrl> [httpsUrl]
 *   默认 baseUrl = http://127.0.0.1:18080
 */

import std.collection.*
import std.fs.*
import std.io.*
import std.sync.*
import std.time.*
import stdx.encoding.json.*
import stdx.crypto.common.*
import stdx.crypto.x509.*
import stdx.net.http.*
import stdx.net.tls.*
import stdx.net.tls.common.*

/* ---------------- 小工具 ---------------- */

/* 把响应体一次读完（照搬轻舟 httpclient.cj 的读法，确认在业务侧同样可用）。 */
func readAllText(body: InputStream): String {
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

func nowMs(): Int64 {
    return DateTime.now().toUnixTimeStamp().toMilliseconds()
}

func is2xx(status: UInt16): Bool {
    return Int64(status) >= 200 && Int64(status) < 300
}

/* 建客户端。tls=true 时挂上 TlsClientConfig —— 这是轻舟 httpclient.cj 目前缺的那一环。 */
func makeClient(tls: Bool, readSecs: Int64, writeSecs: Int64): Client {
    var b = ClientBuilder()
        .noProxy()
        .readTimeout(Duration.second * readSecs)
        .writeTimeout(Duration.second * writeSecs)
    if (tls) {
        var cfg = TlsClientConfig()
        cfg.verifyMode = CertificateVerifyMode.Default
        b = b.tlsConfig(cfg)
    }
    return b.build()
}

/* 一次同步 POST，返回 (http状态码, 文本, 错误原因)。网络异常一律不抛，转成 reason。 */
func postJson(base: String, path: String, payload: String, readSecs: Int64, writeSecs: Int64): (UInt16, String, String) {
    let client = makeClient(false, readSecs, writeSecs)
    try {
        let req = HttpRequestBuilder()
            .method("POST")
            .url(base + path)
            .header("content-type", "application/json")
            .header("authorization", "Bearer spike-token")
            .header("x-spike", "cangjie")
            .body(payload)
            .build()
        let resp = client.send(req)
        let text = readAllText(resp.body)
        client.close()
        return (resp.status, text, "")
    } catch (e: Exception) {
        client.close()
        return (UInt16(0), "", e.message)
    }
}

/* 一次同步 GET（用于公网 HTTPS 探测）。 */
func getUrl(url: String, tls: Bool, readSecs: Int64): (UInt16, Int64, String, String) {
    let t0 = nowMs()
    let client = makeClient(tls, readSecs, readSecs)
    try {
        let req = HttpRequestBuilder().method("GET").url(url).build()
        let resp = client.send(req)
        let text = readAllText(resp.body)
        client.close()
        return (resp.status, nowMs() - t0, text, "")
    } catch (e: Exception) {
        client.close()
        return (UInt16(0), nowMs() - t0, "", e.message)
    }
}

/* ---------------- R1 明文 HTTP ---------------- */

func risk1Http(base: String): Unit {
    println("")
    println("=== R1 明文 HTTP：POST + 自定义头 + 读响应体 ===")
    let (status, text, err) = postJson(base, "/echo", "{\"prompt\":\"你好\"}", 5, 5)
    if (err.size > 0) {
        println("  [R1] FAIL 网络异常：${err}")
        return
    }
    println("  [R1] status=${status}")
    println("  [R1] body=${text}")
    if (is2xx(status) && text.contains("Bearer spike-token") && text.contains("cangjie")) {
        println("  [R1] PASS 请求头与请求体都到达了服务端")
    } else if (is2xx(status)) {
        println("  [R1] PARTIAL 通了，但回显里没看到预期的 header")
    } else {
        println("  [R1] FAIL 非 2xx")
    }
}

/* ---------------- R2 超时 ---------------- */

func risk2Timeout(base: String): Unit {
    println("")
    println("=== R2 超时：服务端睡 5s，客户端 readTimeout=2s ===")
    let t0 = nowMs()
    let (status, _, err) = postJson(base, "/slow?ms=5000", "{}", 2, 2)
    let elapsed = nowMs() - t0
    println("  [R2] 耗时=${elapsed}ms status=${status} reason=${err}")
    if (elapsed < 4000 && status == UInt16(0)) {
        println("  [R2] PASS 超时被真正执行（没有挂到 5s）")
    } else if (elapsed >= 5000) {
        println("  [R2] FAIL readTimeout 没生效，一路等到服务端返回")
    } else {
        println("  [R2] 结果异常，需人工判断")
    }
}

/* ---------------- R3 JSON 解析边界 ---------------- */

func probeJson(label: String, text: String): Unit {
    try {
        let v = JsonValue.fromStr(text)
        match (v) {
            case o: JsonObject => println("  [R3] ${label}: 解析成功(JsonObject)")
            case a: JsonArray => println("  [R3] ${label}: 解析成功(JsonArray)")
            case _ => println("  [R3] ${label}: 解析成功(其他类型)")
        }
    } catch (e: Exception) {
        println("  [R3] ${label}: 解析失败 -> ${e.message}")
    }
}

func risk3Json(base: String): Unit {
    println("")
    println("=== R3 JSON 边界：合法 / 截断 / 代码块包裹 / 带自然语言 ===")
    probeJson("合法", "{\"ok\":true,\"data\":{\"title\":\"例会\"}}")
    probeJson("截断", "{\"ok\": true, \"data\": {")
    probeJson("空串", "")
    probeJson("代码块包裹", "```json\n{\"ok\":true}\n```")
    probeJson("前后带自然语言", "好的，建议如下：{\"ok\":true} 以上。")

    let (_, badText, _) = postJson(base, "/badjson", "{}", 5, 5)
    println("  [R3] 服务端返回的截断串长度=${badText.size}")
}

/* ---------------- R4 锁内做 I/O ---------------- */

/* 坏模式：拿着锁去做 2 秒的外部调用。 */
func badPattern(base: String, mtx: Mutex, counter: AtomicInt64): Unit {
    mtx.lock()
    let (_, _, _) = postJson(base, "/slow?ms=2000", "{}", 10, 10)
    counter.store(counter.load() + 1)
    mtx.unlock()
}

/* 好模式：锁只保护内存状态的更新，I/O 在锁外。 */
func goodPattern(base: String, mtx: Mutex, counter: AtomicInt64): Unit {
    let (_, _, _) = postJson(base, "/slow?ms=2000", "{}", 10, 10)
    mtx.lock()
    counter.store(counter.load() + 1)
    mtx.unlock()
}

func risk4Concurrency(base: String): Unit {
    println("")
    println("=== R4 并发：4 个线程各做一次 2s 慢调用 ===")

    let mtxBad = Mutex()
    let cntBad = AtomicInt64(0)
    let t0 = nowMs()
    let f1 = spawn { badPattern(base, mtxBad, cntBad) }
    let f2 = spawn { badPattern(base, mtxBad, cntBad) }
    let f3 = spawn { badPattern(base, mtxBad, cntBad) }
    let f4 = spawn { badPattern(base, mtxBad, cntBad) }
    f1.get()
    f2.get()
    f3.get()
    f4.get()
    let badMs = nowMs() - t0
    println("  [R4] 坏模式（I/O 在锁内）耗时=${badMs}ms 期望≈8000ms")

    let mtxGood = Mutex()
    let cntGood = AtomicInt64(0)
    let t1 = nowMs()
    let g1 = spawn { goodPattern(base, mtxGood, cntGood) }
    let g2 = spawn { goodPattern(base, mtxGood, cntGood) }
    let g3 = spawn { goodPattern(base, mtxGood, cntGood) }
    let g4 = spawn { goodPattern(base, mtxGood, cntGood) }
    g1.get()
    g2.get()
    g3.get()
    g4.get()
    let goodMs = nowMs() - t1
    println("  [R4] 好模式（I/O 在锁外）耗时=${goodMs}ms 期望≈2000ms")

    if (badMs > goodMs * 2) {
        println("  [R4] PASS 已复现：锁内做 I/O 会把并发彻底串行化（差 ${badMs - goodMs}ms）")
    } else {
        println("  [R4] 提示：两种模式差异不明显，需复核（可能 spawn 未并行）")
    }
}

/* ---------------- R5 公网 HTTPS ---------------- */

/* 三种证书校验模式各建一个客户端——用来定位 HTTPS 失败的真正原因。 */
func makeTlsClient(mode: String, caPath: String, readSecs: Int64): Client {
    var cfg = TlsClientConfig()
    if (mode == "trustall") {
        cfg.verifyMode = CertificateVerifyMode.TrustAll
    } else if (mode == "customca") {
        // 用磁盘上的 CA bundle 构造信任库：File.readFrom 的用法同 server/src/main.cj:977
        // （String.fromUtf8(File.readFrom(certPath))）。
        let pem = String.fromUtf8(File.readFrom(caPath))
        let roots = X509Certificate.decodeFromPem(pem)
        let acc = ArrayList<Certificate>()
        for (c in roots) {
            acc.add(c)
        }
        cfg.verifyMode = CertificateVerifyMode.CustomCA(acc.toArray())
    } else {
        cfg.verifyMode = CertificateVerifyMode.Default
    }
    return ClientBuilder()
        .noProxy()
        .readTimeout(Duration.second * readSecs)
        .writeTimeout(Duration.second * readSecs)
        .tlsConfig(cfg)
        .build()
}

func probeHttps(url: String, mode: String, caPath: String): Unit {
    let t0 = nowMs()
    let client = makeTlsClient(mode, caPath, 15)
    try {
        let req = HttpRequestBuilder().method("GET").url(url).build()
        let resp = client.send(req)
        let text = readAllText(resp.body)
        client.close()
        println("  [R5/${mode}] status=${resp.status} 耗时=${nowMs() - t0}ms 长度=${text.size}  => HTTPS 通")
    } catch (e: Exception) {
        client.close()
        println("  [R5/${mode}] 失败 耗时=${nowMs() - t0}ms reason=${e.message}")
    }
}

func risk5Https(url: String, caPath: String): Unit {
    println("")
    println("=== R5 公网 HTTPS：证书校验模式对比（${url}） ===")
    probeHttps(url, "default", caPath)
    probeHttps(url, "trustall", caPath)
    if (caPath.size > 0) {
        probeHttps(url, "customca", caPath)
    } else {
        println("  [R5/customca] 未提供 CA 路径，跳过")
    }
}

/* ---------------- 入口 ---------------- */

main(args: Array<String>): Int64 {
    var base = "http://127.0.0.1:18080"
    var httpsUrl = "https://www.baidu.com"
    var caPath = ""
    if (args.size > 0) {
        base = args[0]
    }
    if (args.size > 1) {
        httpsUrl = args[1]
    }
    if (args.size > 2) {
        caPath = args[2]
    }
    println("spike：base=${base} https=${httpsUrl} ca=${caPath}")

    try {
        risk1Http(base)
    } catch (e: Exception) {
        println("  [R1] 未捕获异常：${e.message}")
    }
    try {
        risk2Timeout(base)
    } catch (e: Exception) {
        println("  [R2] 未捕获异常：${e.message}")
    }
    try {
        risk3Json(base)
    } catch (e: Exception) {
        println("  [R3] 未捕获异常：${e.message}")
    }
    try {
        risk4Concurrency(base)
    } catch (e: Exception) {
        println("  [R4] 未捕获异常：${e.message}")
    }
    try {
        risk5Https(httpsUrl, caPath)
    } catch (e: Exception) {
        println("  [R5] 未捕获异常：${e.message}")
    }

    println("")
    println("spike 结束")
    return 0
}
