package spike

/*
 * AI-2 复现探针：框架 `httpclient.cj` 的 readBodyText 把「短读」当 EOF。
 *
 * 两种读法各请求一次同一个桩，打印收到的字节数：
 *   readFramework —— **逐字照抄**框架 third_party/qingzhou/src/httpclient.cj:25-43
 *                    （含 `if (n < buf.size) { break }` 这一行）
 *   readFixed     —— 同一段代码，但**只以 n <= 0 判流结束**（入站侧 context.cj 早已这么改）
 *
 * 判据：body 越大越明显 —— 框架读法收到的字节数会**远小于**桩实际发出的字节数，
 *       而 readFixed 收到的与桩发出的一致。
 *
 * 用法：probe.exe [baseUrl]
 */

import std.collection.*
import std.io.*
import stdx.net.http.*

/* 逐字照抄框架 httpclient.cj 的 readBodyText（含缺陷）。 */
func readFramework(body: InputStream): String {
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

/* 同一段代码，按入站侧的铁律修：**只有 n <= 0 才是流结束**。 */
func readFixed(body: InputStream): String {
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
    }
    return String.fromUtf8(out.toArray())
}

func fetchLen(base: String, size: Int64, fixed: Bool): Int64 {
    let client = ClientBuilder().noProxy().build()
    try {
        let req = HttpRequestBuilder()
            .method("POST")
            .url("${base}/v1/chat/completions?size=${size}")
            .header("content-type", "application/json")
            .body("{}")
            .build()
        let resp = client.send(req)
        let text = if (fixed) { readFixed(resp.body) } else { readFramework(resp.body) }
        client.close()
        return text.size
    } catch (e: Exception) {
        client.close()
        println("      请求异常：${e.message}")
        return -1
    }
}

main(args: Array<String>): Int64 {
    var base = "http://127.0.0.1:19001"
    if (args.size > 0) {
        base = args[0]
    }
    println("=== AI-2 复现：框架 readBodyText 的短读截断 ===")
    println("桩按 1000 字节/20ms 分块慢发；下表是**客户端实际收到**的字节数")
    println("")
    println("  请求 size | 框架读法收到 | 正确读法收到 | 判定")
    let sizes = [300, 3000, 4000, 4200, 5000, 9000, 20000]
    var fixedBad: Int64 = 0
    for (s in sizes) {
        let a = fetchLen(base, s, false)
        let b = fetchLen(base, s, true)
        /* 正确读法至少要收到「请求的 content 字节数」——说明没被截断 */
        if (b < s) {
            fixedBad += 1
        }
        var verdict = "一致"
        if (a < b) {
            verdict = "框架截断（丢 ${b - a} 字节）"
        }
        println("  ${s} | ${a} | ${b} | ${verdict}")
    }
    println("")
    println("判据：框架读法明显小于正确读法 => AI-2 坐实；正确读法不小于请求量 => 修法有效。")
    /* 给回归闸门用的**纯 ASCII** 判定行（PowerShell 5.1 按 ANSI 读子进程输出，
       中文会变乱码，所以这里不能靠中文匹配）。 */
    if (fixedBad == 0) {
        println("FIXED_READER_OK=1")
    } else {
        println("FIXED_READER_OK=0")
    }
    return 0
}
