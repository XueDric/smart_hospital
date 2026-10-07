package qingzhou

import std.time.*
import std.fs.*

/*
 * SPDX-License-Identifier: MIT
 *
 * logger middleware.
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * Replaces the  trace-only logger with a stdout-oriented access log.
 * Format:
 *
 *   <id-or-dash> <ip-or-dash> METHOD path -> status (Xms)
 *
 * Where the id is ctx._id (set by requestId()) if present, or "-" if
 * the logger runs without a prior requestId() middleware; the ip is the
 * client IP (Context.remoteIp()), or "-" when unavailable.
 *
 * Plug a custom formatter/writer via LoggerOptions to ship structured
 * logs (e.g. JSON line per request, or a File output sink).
 */

public class LoggerOptions {
    public var formatter: (Context, Int64) -> String = defaultLoggerFormatter
    public var writer: (String) -> Unit = defaultLoggerWriter

    public init() {}
}

public func defaultLoggerFormatter(ctx: Context, elapsedMs: Int64): String {
    let id = if (ctx._id.size > 0) { ctx._id } else { "-" }
    let ip = if (ctx.remoteIp().size > 0) { ctx.remoteIp() } else { "-" }
    return "${id} ${ip} ${ctx.method()} ${ctx.path()} -> ${ctx._peekStatus()} (${elapsedMs}ms)"
}

public func defaultLoggerWriter(line: String): Unit {
    println(line)
}

public func logger(): Middleware {
    return loggerWith(LoggerOptions())
}

public func loggerWith(opts: LoggerOptions): Middleware {
    return { ctx: Context, next: () -> Unit =>
        let start = MonoTime.now()
        next()
        let now = MonoTime.now()
        let elapsed = (now - start).toMilliseconds()
        let line = opts.formatter(ctx, elapsed)
        opts.writer(line)
    }
}

/* 结构化日志 */

/*
 * 结构化 JSON 行格式化器（每请求一行 JSON，供日志采集/ELK 解析）。
 * 字段：id / ip / method / path / status / elapsed_ms。基于 JsonBuilder
 * 自动转义，杜绝手写 JSON 拼接的转义遗漏。
 *
 *   loggerWith(LoggerOptions(formatter: jsonLogFormatter))
 */
public func jsonLogFormatter(ctx: Context, elapsedMs: Int64): String {
    return JsonBuilder()
        .put("id", if (ctx._id.size > 0) { ctx._id } else { "-" })
        .put("ip", if (ctx.remoteIp().size > 0) { ctx.remoteIp() } else { "-" })
        .put("method", ctx.method())
        .put("path", ctx.path())
        .putInt("status", ctx._peekStatus())
        .putInt("elapsed_ms", elapsedMs)
        .build()
}

/*
 * 文件日志 sink：把日志行追加写入文件（文件不存在则创建，UTF-8）。
 * 基于 std.fs.File.appendTo，每次调用即开即写即关，无需持有句柄——
 * 进程退出安全、多实例可共写（追加语义由 OS 保证原子性到字节流层面）。
 *
 * 注意：File.appendTo 每次打开文件有开销，高吞吐场景可自行持 File 句柄
 * 复用（见 LoggerOptions.writer 注入点）。
 *
 *   loggerWith(LoggerOptions(
 *       formatter: jsonLogFormatter,
 *       writer: fileLogWriter("./logs/access.log")
 *   ))
 */
public func fileLogWriter(path: String): (String) -> Unit {
    return { line: String =>
        File.appendTo(path, (line + "\n").toArray())
    }
}