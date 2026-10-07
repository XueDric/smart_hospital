package qingzhou

import std.collection.*
import std.time.*

/*
 * SPDX-License-Identifier: MIT
 *
 * 请求限流中间件（固定窗口）。
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * 按客户端 IP 做固定窗口限流：windowSeconds 秒内最多 limit 次请求，
 * 超限返回 429 + Retry-After 头，不调用后续中间件（短路）。
 *
 * 实现：内存 HashMap 记录每个 key 的窗口起点 + 计数，窗口过期惰性重置。
 * 适用于单实例；多实例需共享存储（Redis 等），超出本中间件范围。
 */

/*
 * 限流中间件。key 默认取客户端 IP（Context.remoteIp()）。
 *   limit        窗口内最大请求数
 *   windowSeconds 窗口长度（秒）
 */
public func rateLimit(limit: Int64, windowSeconds: Int64): Middleware {
    let windowStart = HashMap<String, Int64>()
    let counts = HashMap<String, Int64>()
    return { ctx: Context, next: () -> Unit =>
        let key = ctx.remoteIp()
        let now = DateTime.nowUTC().toUnixTimeStamp().toSeconds()
        match (windowStart.get(key)) {
            case Some(start) =>
                if (now - start >= windowSeconds) {
                    // 窗口过期，重置计数
                    windowStart[key] = now
                    counts[key] = Int64(1)
                } else {
                    let c = match (counts.get(key)) {
                        case Some(n) => n
                        case None => Int64(0)
                    }
                    if (c >= limit) {
                        // 超限：429 + Retry-After，短路
                        ctx.status(429)
                        ctx.header("retry-after", windowSeconds.toString())
                        ctx.header("content-type", "application/json")
                        ctx.body("{\"code\":429,\"message\":\"too many requests\",\"data\":null}")
                        return
                    }
                    counts[key] = c + 1
                }
            case None =>
                windowStart[key] = now
                counts[key] = Int64(1)
        }
        next()
    }
}
