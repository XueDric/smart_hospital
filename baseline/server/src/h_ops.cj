package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * 运维接口：健康检查 + 优雅关闭。
 *
 * Windows 没有 std.runtime.Signal（..\docs\..\docs\HANDOFF.md §6），优雅关闭只能靠端点触发。
 * 因此 /admin/shutdown **必须限制为本机可访问**，否则任何人都能远程关停服务。
 */

import stdx.encoding.json.*

public let APP_VERSION: String = "0.1.0"

/* GET /health —— 不带 /api 前缀、不需要认证（api-design §1.1）。 */
public func handleHealth(ctx: Context): Unit {
    let data = JsonObject()
    jPutStr(data, "status", "ok")
    jPutStr(data, "version", APP_VERSION)
    jPutStr(data, "time", isoLocal(nowEpoch()))
    sendOk(ctx, data)
}

/*
 * 取客户端地址的文本形式。
 * stdx 的 remoteAddr 具体类型未固定，这里统一用字符串插值取它的文本表示，
 * 避免把类型写死（探针实测该属性存在，但打印格式需运行时确认）。
 */
public func peerOf(ctx: Context): String {
    match (ctx.http) {
        case Some(h) => return "${h.request.remoteAddr}"
        case None => return ""
    }
}

/*
 * 从对端文本里剥出 IP（**不含端口**）—— N-6 的注册节流按它分桶，N-14 的回环判定也用它。
 *
 * 实测 remoteAddr 的文本是 "IP:端口"（例：127.0.0.1:14764），所以必须剥端口；
 * 否则同一台机器每个连接都是新 key，限流形同虚设。三种形态：
 *   `[::1]:14764`   带方括号的 IPv6 —— 实测的真实形态，取方括号内
 *   `127.0.0.1:9`   带端口的 IPv4 —— 取最后一个冒号之前
 *   `::1`           既无方括号也无端口的**裸 IPv6** —— 整串就是地址
 * 拿不到地址时返回空串，调用方自行兜底（当前会退化为全局锁）。
 *
 * 纯函数（不碰 Context），因此可以在单测里直接覆盖各种对端文本 —— N-14 的回归闸门靠它。
 * （N-12 原先记录"裸 IPv6 会切出垃圾 key、退化为全局桶"；这里按冒号个数判断，
 *   整串即地址，该退化已消失。）
 */
public func ipOfPeerText(p: String): String {
    let n = p.size
    if (n == 0) {
        return ""
    }
    let a = p.toArray()
    /* 1) 带方括号：IPv6 的 [::1]:port / [::1] 形态 */
    if (a[0] == 91) { /* '[' */
        var rb: Int64 = -1
        var i: Int64 = 0
        while (i < n) {
            if (a[i] == 93) { /* ']' */
                rb = i
            }
            i += 1
        }
        if (rb > 0) {
            return String.fromUtf8(a[1..rb])
        }
    }
    /* 2) 数冒号：0 个 = 裸 IPv4 / 主机名；1 个 = IPv4:端口；≥2 个 = 裸 IPv6 */
    var colons: Int64 = 0
    var lastColon: Int64 = -1
    var i2: Int64 = 0
    while (i2 < n) {
        if (a[i2] == 58) { /* ':' */
            colons += 1
            lastColon = i2
        }
        i2 += 1
    }
    if (colons == 1) {
        return String.fromUtf8(a[0..lastColon])
    }
    return p
}

public func clientIpOf(ctx: Context): String {
    return ipOfPeerText(peerOf(ctx))
}

/*
 * 判定"这个对端文本是不是本机回环"（**N-14**）。
 *
 * 原实现是对整串做子串搜索（`containsAscii(p, "::1")`）。而 IPv6 对端文本形如
 * `[2001:db8::1]:5000`，于是**只要地址里出现 `::1` 这三个字符**就被判成本机 ——
 * 而 IPv6 的接口标识符由发起方自己决定，攻击者挑一个 `xxxx::1xxx` 形态的源地址，
 * 就能**远程调用 `POST /admin/shutdown`**（该端点没有任何认证）。
 *
 * 现在先把地址剥出来（`ipOfPeerText`），再**按地址相等**判断：
 * 接受集合是白名单，不做任何模式/子串匹配。
 *
 * 之所以抽成纯函数：冒烟测试只能从本机发包，造不出"远程 IPv6 对端"，
 * 反例闸门只能落在单测里（`tests.cj` 的 `testLoopbackPeer`）。
 */
public func isLoopbackPeer(peerText: String): Bool {
    let ip = ipOfPeerText(peerText)
    if (ip.size == 0) {
        return false
    }
    if (ip == "127.0.0.1") {
        return true
    }
    /* IPv6 回环的三种写法：简写、全展开、IPv4 映射 */
    if (ip == "::1") {
        return true
    }
    if (ip == "0:0:0:0:0:0:0:1") {
        return true
    }
    if (ip == "::ffff:127.0.0.1") {
        return true
    }
    return false
}

/*
 * `/admin/shutdown` 的本机判定 —— 见 isLoopbackPeer。
 *
 * 顺带收紧了两处旧行为：不再接受 `localhost`（socket 对端是地址、不会是主机名，
 * 宽松地接受一个字符串只会再开一个口子），也不再接受 `127.x` 里的其它地址
 * （只有 127.0.0.1 与 IPv6 回环被认可）。
 */
public func isLocalPeer(ctx: Context): Bool {
    return isLoopbackPeer(peerOf(ctx))
}
