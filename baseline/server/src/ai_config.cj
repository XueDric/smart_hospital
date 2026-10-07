package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * AI 能力 · 配置与启动期校验
 *
 * 对应：api-design.md Part 7 · llm-client-spec.md §5.1 / §2
 *
 * 三条硬约束（都来自本机实测，见 spike/llm-http/FINDINGS.md）：
 *   1. **密钥不能走环境变量** —— 本工具链的仓颉 std 没有 getEnv，
 *      所以只能给【文件路径】；也**不接受命令行直接传密钥**（会进进程列表与 shell 历史）。
 *   2. **Windows 上必须自备 CA；Linux 上不需要**（但本服务一律要求显式给，见下）。
 *      `CertificateVerifyMode.Default` 在 **Windows** 上没有可用信任库，必然报 `unknown CA(134)`
 *      （spike R5 实测）。
 *      ⚠ **Linux 上它会读系统信任库，握手是通的** —— 2026-10-06 在 WSL Ubuntu 26.04 + cjc 1.2.0 上
 *      实测，`Default` 打 api.deepseek.com / baidu / github / bing 四个公网站点**全部通过**。
 *      （此处曾误写成「与 OS 无关、两个平台都要」，后被实测推翻 —— 见 API-NOTES 坑 46。）
 *      但 `aiValidate` **一律要求 `--ai-ca`**（为了在 Windows 上早失败、给出明确原因），
 *      所以 Linux 也要给，**内容可以就是系统那份**：`--ai-ca /etc/ssl/certs/ca-certificates.crt`。
 *   3. 缺 OpenSSL 两个 DLL 时**编译期无警告**，运行到 TLS 才报
 *      `Can not load openssl library or function CRYPTO_get_ex_new_index`。
 *
 * 设计口径：**未配置不是错误**。endpoint/密钥/CA 任一缺失时，AI 功能整体标记为不可用
 * （`enabled = false` + `disabledReason`），但**服务照常启动**——不能因为没配大模型就起不来。
 */

import std.collection.*
import std.convert.*
import std.fs.*

/* AI 功能的一次性配置。启动时构造校验一次，之后只读使用。 */
public class AiOptions {
    /* OpenAI 兼容的完整 URL，例如 https://api.deepseek.com/v1/chat/completions */
    public var endpoint: String = ""
    /* 模型名（OpenAI 兼容协议里 model 是必填字段），例如 deepseek-chat */
    public var model: String = ""
    /* 密钥文件路径（内容首尾空白会被裁剪——密钥文件末尾的换行会污染 Authorization 头） */
    public var apiKeyFile: String = ""
    /* CA bundle 路径（PEM，可含多张证书）。生产必填 */
    public var caBundlePath: String = ""
    /* 读 / 写超时（秒）。必须 > 0 */
    public var timeoutSecs: Int64 = 30
    /* 出站并发上限。必须 ≥ 1 */
    public var maxConcurrent: Int64 = 4
    /*
     * R-14（2026-10-05 晚修）：max_tokens 原先在 ai_client.cj 里**硬编码 1024**。
     * 中文约 1500 字的通知正文就可能超 1024 token -> 输出被截断 -> 非法 JSON
     * -> **静默降级为 fallback** —— 与 AI-2 修掉的那个症状同类，只是换了成因。
     */
    public var maxTokens: Int64 = 2048
    /* 单次调用总预算（毫秒，含重试） */
    public var budgetMs: Int64 = 20000
    /* 单次请求体上限（字节），防止把整库塞进 prompt */
    public var maxRequestBytes: Int64 = 65536
    /* ⚠ 仅本机开发：跳过证书校验。为真时启动打醒目警告，且审计记 insecure=true */
    public var insecureTrustAll: Bool = false

    /* ---- 校验结果（aiValidate 填充）---- */
    /* false = AI 功能整体不可用；服务仍正常启动 */
    public var enabled: Bool = false
    /* enabled=false 的原因；可直接打印给运维看 */
    public var disabledReason: String = ""

    public init() {}
}

/*
 * 从命令行选项表构造配置。
 *
 * ⚠ **所有 AI 选项都必须带值**：本项目 splitFlags 只认 `--x value` 形式，
 * 裸 `--flag` 会抛"选项后面要跟一个值"。所以布尔开关写成 `--ai-insecure-trust-all 1`。
 */
public func aiOptionsFromFlags(flags: HashMap<String, String>): AiOptions {
    let o = AiOptions()
    o.endpoint = aiTrim(flagOf(flags, "--ai-endpoint"))
    o.model = aiTrim(flagOf(flags, "--ai-model"))
    o.apiKeyFile = aiTrim(flagOf(flags, "--ai-key-file"))
    o.caBundlePath = aiTrim(flagOf(flags, "--ai-ca"))
    o.timeoutSecs = aiParseIntOr(flags, "--ai-timeout", 30)
    o.maxConcurrent = aiParseIntOr(flags, "--ai-max-concurrent", 4)
    o.maxTokens = aiParseIntOr(flags, "--ai-max-tokens", 2048)
    o.insecureTrustAll = flagOf(flags, "--ai-insecure-trust-all") == "1"
    aiValidate(o)
    return o
}

/*
 * 启动期校验：fail-fast，别等到第一次调用才报。
 * 注意失败**不抛异常**——只把 AI 标记为不可用，让服务能起来。
 */
public func aiValidate(o: AiOptions): Unit {
    if (o.endpoint.size == 0) {
        o.enabled = false
        o.disabledReason = "未配置 --ai-endpoint，AI 功能不可用（其余功能不受影响）"
        return
    }
    if (!o.insecureTrustAll && !startsWithAscii(o.endpoint, "https://")) {
        o.enabled = false
        o.disabledReason = "endpoint 必须是 https://（明文调用大模型 = 密钥裸奔）；" +
                           "仅本机开发可用 --ai-insecure-trust-all 1 强制放行"
        return
    }
    if (o.timeoutSecs <= 0 || o.timeoutSecs > 300) {
        o.enabled = false
        /* AI-15（2026-10-05 修）：加上上界。原来看不出 `--ai-timeout 10000000000`
           （秒/毫秒混用的常见笔误）有什么问题 —— 但它会在 `Duration.second * n`
           处整数溢出**抛异常**，而那行跑在 buildApp 里、无人接住 → 服务起不来。 */
        o.disabledReason = "--ai-timeout 必须在 1..300 秒之间（0 = 无限等待；过大在 Duration 乘法处会溢出）"
        return
    }
    if (o.model.size == 0) {
        o.enabled = false
        o.disabledReason = "未配置 --ai-model（OpenAI 兼容协议里 model 是必填字段）"
        return
    }
    if (o.maxConcurrent < 1 || o.maxConcurrent > 64) {
        o.enabled = false
        /* R-12（2026-10-05 晚修）：补**上界**。`--ai-timeout` 刚为同类问题补了 1..300，
           这里原先只判下界；而该值直达 `Semaphore(opts.maxConcurrent)`，
           极端取值的后果（抛异常还是 OOM）没人验过，且一旦抛，
           路径与 AI-14 同类 —— AiClient.init → newAiClient → buildApp，**无 try**。 */
        o.disabledReason = "--ai-max-concurrent 必须在 1..64 之间（它直达 Semaphore 的计数）"
        return
    }
    if (o.maxTokens < 64 || o.maxTokens > 8192) {
        o.enabled = false
        o.disabledReason = "--ai-max-tokens 必须在 64..8192 之间（过小会截断输出、进而静默降级）"
        return
    }
    if (o.apiKeyFile.size == 0) {
        o.enabled = false
        o.disabledReason = "未配置 --ai-key-file，AI 功能不可用"
        return
    }
    if (!fileExists(o.apiKeyFile)) {
        o.enabled = false
        o.disabledReason = "密钥文件不存在：${o.apiKeyFile}"
        return
    }
    /*
     * AI-13（2026-10-05 修）：**文件存在 ≠ 已配置**。空/纯空白的密钥会让每个请求
     * 发 `Bearer `（必然 401），用户看到的是"智能服务返回异常"而不是"未配置"——
     * 完全误导。
     *
     * AI-14（同批修）：顺便在这里把内容**解码一次**。真正的解码原先发生在构造期
     * （`String.fromUtf8`），而那条路径没人 try —— 密钥文件若是 PowerShell 5.1
     * `Out-File` 默认写出的 UTF-16LE，会让整个服务起不来。这里当场判成配置错误。
     */
    var keyReason = ""
    try {
        if (aiTrim(String.fromUtf8(File.readFrom(o.apiKeyFile))).size == 0) {
            keyReason = "密钥文件是空的（或只有空白字符）：${o.apiKeyFile}"
        }
    } catch (e: Exception) {
        keyReason = "密钥文件不是 UTF-8 文本（PowerShell 5.1 的 Out-File 默认写 UTF-16LE，" +
                    "请用 [IO.File]::WriteAllText 配 UTF8Encoding）：${o.apiKeyFile}"
    }
    if (keyReason.size > 0) {
        o.enabled = false
        o.disabledReason = keyReason
        return
    }
    if (!o.insecureTrustAll) {
        /* 生产路径必须能读到 CA：Windows 上 Default 没有信任库、必然失败；Linux 上 Default 本可用系统库，
           但这里**一律要求显式给** —— 宁可早失败并说清原因，也不要让 Windows 部署在运行时才炸。 */
        if (o.caBundlePath.size == 0) {
            o.enabled = false
            o.disabledReason = "未配置 --ai-ca（Windows 上 Default 没有可用信任库、必然握手失败；Linux 上 Default 本可用系统库，但本服务一律要求显式给 —— 填 /etc/ssl/certs/ca-certificates.crt 即可）；" +
                               "本机开发可用 --ai-insecure-trust-all 1 临时放行"
            return
        }
        if (!fileExists(o.caBundlePath)) {
            o.enabled = false
            o.disabledReason = "CA bundle 不存在：${o.caBundlePath}"
            return
        }
        /*
         * AI-14（2026-10-05 修）：**内容**也要在这里验一次。
         * 真正的 PEM 解析发生在构造期（buildTlsClientConfig → loadCaCertificates），
         * 而那条路径原先**没有任何 try** —— 一个 DER 格式或损坏的 .pem 会让服务
         * **直接起不来**，而报错发生在 buildApp 里、与"配置写错了"这个真实原因隔了一层。
         * 这里当场解析一次：失败即判为配置错误（enabled=false + 可照做的原因），
         * 服务照常启动、其余功能不受影响。
         */
        try {
            let certs = loadCaCertificates(o.caBundlePath)
            if (certs.size == 0) {
                o.enabled = false
                o.disabledReason = "CA bundle 里没有解析出任何证书（是不是给了 DER 而不是 PEM？）：${o.caBundlePath}"
                return
            }
        } catch (e: Exception) {
            o.enabled = false
            o.disabledReason = "CA bundle 无法解析为 PEM 证书：${o.caBundlePath}（${e.message}）"
            return
        }
    }
    o.enabled = true
    o.disabledReason = ""
}

/*
 * 读取密钥（首尾空白已裁剪）。仅在 enabled=true 时调用。
 * 文件里的换行如果不裁掉，会直接把 Authorization 头写坏——这是最容易踩的一个坑。
 */
public func aiReadApiKey(o: AiOptions): String {
    return aiTrim(String.fromUtf8(File.readFrom(o.apiKeyFile)))
}

/* 启动时打印一次配置状态（**不打印密钥**）。 */
public func aiDescribe(o: AiOptions): String {
    if (!o.enabled) {
        return "AI：未启用 —— ${o.disabledReason}"
    }
    let mode = if (o.insecureTrustAll) { "⚠ 跳过证书校验（仅限本机开发）" } else { "CustomCA：${o.caBundlePath}" }
    return "AI：已启用 —— endpoint=${aiHostOnly(o.endpoint)} 超时=${o.timeoutSecs}s " +
           "并发=${o.maxConcurrent} 校验=${mode}"
}

/* 只取 URL 的 scheme://host 部分，避免把路径与查询串打进日志。
   用字节扫描而不是 String.indexOf：后者返回 Option，且这里要的语义很窄。 */
func aiHostOnly(url: String): String {
    let b = url.toArray()
    var start: Int64 = 0
    var k: Int64 = 0
    while (k + 2 < b.size) {
        /* "://" */
        if (b[k] == UInt8(58) && b[k + 1] == UInt8(47) && b[k + 2] == UInt8(47)) {
            start = k + 3
            break
        }
        k += 1
    }
    var end = start
    /* 停在 '/', '?', '#' */
    while (end < b.size && b[end] != UInt8(47) && b[end] != UInt8(63) && b[end] != UInt8(35)) {
        end += 1
    }
    /*
     * AI-16（2026-10-05 修）：还要剥掉 **URL userinfo**（`user:pass@host`）。
     * 原先的扫描只停在 / ? #，于是运维若把凭据写进 URL
     * （`https://sk-xxxx@host/v1/...`），**每次启动都会把 `sk-xxxx@host` 打到 stdout**——
     * 查询串里的密钥反而被剥掉了，等于把最该藏的那段露出来。
     */
    var at: Int64 = -1
    var p = start
    while (p < end) {
        if (b[p] == UInt8(64)) {
            at = p
        }
        p += 1
    }
    if (at >= start) {
        start = at + 1
    }
    if (end <= start) {
        return "(未解析)"
    }
    return String.fromUtf8(b[start..end])
}

/* ---- 小工具 ---- */

func fileExists(path: String): Bool {
    try {
        let _ = File.readFrom(path)
        return true
    } catch (e: Exception) {
        return false
    }
}

/* 数值选项：给了但非法时**不静默取默认值**，而是返回非法值让 aiValidate 拒掉。 */
func aiParseIntOr(flags: HashMap<String, String>, k: String, d: Int64): Int64 {
    let raw = aiTrim(flagOf(flags, k))
    if (raw.size == 0) {
        return d
    }
    try {
        return Int64.parse(raw)
    } catch (e: Exception) {
        return -1
    }
}

/* 裁剪首尾空白（空格 / 制表 / CR / LF）。自己写而不用 String.trim：
   这里的语义要明确到字节，且必须能处理密钥文件末尾的换行。 */
func aiTrim(s: String): String {
    let b = s.toArray()
    var i: Int64 = 0
    var j: Int64 = b.size
    while (i < j && aiIsSpace(b[i])) {
        i += 1
    }
    while (j > i && aiIsSpace(b[j - 1])) {
        j -= 1
    }
    if (i == 0 && j == b.size) {
        return s
    }
    return String.fromUtf8(b[i..j])
}

func aiIsSpace(c: UInt8): Bool {
    return c == UInt8(32) || c == UInt8(9) || c == UInt8(10) || c == UInt8(13)
}

/* ===================== 启动期配置的传递 ===================== */

/*
 * 启动时把解析好的 AI 配置放这里，供 buildApp 构造客户端。
 *
 * 为什么用模块级变量而不是给 buildApp 加参数：buildApp 的签名被多处调用，
 * 加参数要改一圈；而这份配置**只在 main 的 serve 路径写一次、之后只读**，
 * 不存在运行期改写，所以模块级变量在这里是安全的。
 */
var g_aiOptions: AiOptions = AiOptions()

public func setAiOptions(o: AiOptions): Unit {
    g_aiOptions = o
}

public func aiOptionsCurrent(): AiOptions {
    return g_aiOptions
}
