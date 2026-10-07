package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 安全响应头中间件（helmet 风格）。
 *
 * Copyright (c) 2026 guowei
 * BIT Foundational Software And Systems Lab
 *
 * 一键为响应追加常见安全头，缓解点击劫持 / MIME 嗅探 / 信息泄露等风险：
 *   X-Content-Type-Options: nosniff
 *   X-Frame-Options: <frameOptions>（默认 DENY）
 *   Referrer-Policy: no-referrer
 *   Content-Security-Policy: <csp>（可选，未设置则不追加）
 *
 * 应在洋葱链最外层（靠近入口）使用，确保所有响应都带上安全头。
 */

public class SecurityHeadersOptions {
    /* 防点击劫持。DENY / SAMEORIGIN。 */
    public var frameOptions: String = "DENY"
    /* Content-Security-Policy 值；空串则不追加 CSP 头。 */
    public var contentSecurityPolicy: String = ""
    public init() {}
}

/* 默认安全头（DENY + nosniff + no-referrer，无 CSP）。 */
public func securityHeaders(): Middleware {
    return securityHeadersOpts(SecurityHeadersOptions())
}

/* 自定义安全头。 */
public func securityHeadersOpts(opts: SecurityHeadersOptions): Middleware {
    return { ctx: Context, next: () -> Unit =>
        ctx.header("X-Content-Type-Options", "nosniff")
        ctx.header("X-Frame-Options", opts.frameOptions)
        ctx.header("Referrer-Policy", "no-referrer")
        if (opts.contentSecurityPolicy.size > 0) {
            ctx.header("Content-Security-Policy", opts.contentSecurityPolicy)
        }
        next()
    }
}
