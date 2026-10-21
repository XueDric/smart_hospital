package qingzhou

import std.collection.*
import std.fs.*
import std.io.*
import stdx.encoding.json.*
import stdx.net.http.*
import stdx.net.tls.*
import std.env.*
import std.sync.*
import std.time.*

/*
 * SPDX-License-Identifier: MIT
 *
 * ===== ai_call.cj —— 真模型出站调用 =====
 * 密钥只在出站那一刻从引用解析出来：不落库、不缓存、不进日志。
 * 失败必须降级回规则并如实标注 source（rules / model / model:invalid）。
 * 模型不能改变"给不给号"：科室与号源由规则和数据库决定，模型只产解释文字。
 */

/* 常量必须定义在首次使用之前：仓颉没有 hoisting，故集中在最前。 */
/* 响应体读取上限：模型返回不该超过 1 MiB。没有上限时一个畸形/恶意响应能吃掉内存。 */
public let AI_MAX_RESP_BYTES: Int64 = 1024 * 1024

/* 出站并发闸：容量取进程启动后首次出站时读到的 ai.max_concurrent。
 * 运行中改配置不重建信号量，重建会让等待中的调用永久阻塞。
 * 限的是本进程内同时在途的调用数；超额在 acquire 处等待，不排队超时。 */
private var aiSemCapacity: Int64 = 0
private let aiSemLock = Mutex()
private var aiSem: ?Semaphore = None

private func aiGate(limit: Int64): Semaphore {
    aiSemLock.lock()
    try {
        if (aiSemCapacity != limit) {
            if (aiSem.isNone()) {
                aiSem = Some(Semaphore(limit))
                aiSemCapacity = limit
            }
        }
    } finally {
        aiSemLock.unlock()
    }
    return aiSem.getOrThrow()
}

private func aiReleaseGate(): Unit {
    match (aiSem) {
        case Some(s) => s.release()
        case None => ()
    }
}

/* 单调时钟（毫秒）。测耗时必须读真时钟：拿参数当"当前时间"会让 elapsedMs 恒为 0。 */
private func aiNowMs(): Int64 {
    return DateTime.now().toUnixTimeStamp().toMilliseconds()
}

/* ===================== 结果与状态 ===================== */

/* 出站调用的结果。source 是本类型的主要理由：调用方要如实把来源透传给患者。 */
public class AiCallResult {
    public var ok: Bool = false
    public var text: String = ""
    /* 来源标注，可直接给患者看：model / rules（未配或降级）/ model:invalid（输出不合格）。
     * 三者处置不同：model:invalid 要改 Prompt，rules 要查配置或网络。 */
    public var source: String = "rules"
    /* 失败原因（**给运维看**，不含密钥）。空串表示成功。 */
    public var reason: String = ""
    /* 耗时（毫秒）。用于看板的"调用耗时"与超时排查。 */
    public var elapsedMs: Int64 = 0
    public var invalidOutput: Bool = false
    /* HTTP 状态码（0 = 没走到收响应）。401 与 404 处置不同，数字比措辞更不易误读。 */
    public var httpStatus: Int64 = 0
    /* 请求是否真的发出去过：重试只针对发出后的失败，配置/密钥错重试是白等。 */
    public var attempted: Bool = false
}


/* AI 是否真的可调用：开关开、endpoint/model/key_ref 齐、密钥引用能解析。
 * 返回（可否, 原因），只给 Bool 会逼人猜"为什么没调模型"。
 * 必须不缓存：ai_setting 的纪律是改配置零重启。 */
public func aiCanCall(o: AiRuntimeOptions): (Bool, String) {
    if (!o.enabled) {
        return (false, o.disabledReason)
    }
    if (o.endpoint.size == 0) {
        return (false, "未配置 ai.endpoint")
    }
    if (o.model.size == 0) {
        return (false, "未配置 ai.model")
    }
    if (o.keyRef.size == 0) {
        return (false, "未配置 ai.key_ref（密钥引用）")
    }
    match (aiResolveKey(o.keyRef)) {
        case Some(_) => return (true, "")
        case None => return (false, aiKeyRefProblem(o.keyRef))
    }
}

/* 把 env:名 / file:路径 / builtin:名 解析成真密钥。
 * 返回值只在调用侧短暂存在，不得存进字段或日志。
 * file: 路径必须 trimAscii，尾随换行会让 Authorization 头带 \n ⇒ 401。 */
public func aiResolveKey(ref: String): ?String {
    return aiResolveKeyAt(ref, hDateStringOf(hNowEpoch()))
}

/* 可注入"今天"的版本，便于断言 builtin: 到期后取不到；env:/file: 无有效期。 */
public func aiResolveKeyAt(ref: String, today: String): ?String {
    match (keyRefEnvName(ref)) {
        case Some(name) =>
            let v = getVariable(name)
            match (v) {
                case Some(raw) =>
                    let t = raw.trimAscii()
                    if (t.size == 0) {
                        return None
                    }
                    return Some(t)
                case None => return None
            }
        case None => ()
    }
    match (keyRefFilePath(ref)) {
        case Some(path) =>
            try {
                let t = String.fromUtf8(File.readFrom(path.trimAscii())).trimAscii()
                if (t.size == 0) {
                    return None
                }
                return Some(t)
            } catch (e: Exception) {
                return None
            }
        case None => ()
    }
    /* builtin: 从代码常量取；三种前缀互不重叠，顺序只为可读。 */
    match (keyRefBuiltinName(ref)) {
        case Some(name) =>
            match (aiBuiltinKeyOfAt(name, today)) {
                case Some(k) => return Some(k)
                case None => return None
            }
        case None => ()
    }
    /* 三种前缀都不匹配：put 会拒，这里只是兜底。 */
    return None
}

/* 密钥引用解析失败的可执行原因，不含密钥本体。
 * env: 与 file: 的失败必须分开说，混成一句会让人查错方向。 */
public func aiKeyRefProblem(ref: String): String {
    match (keyRefEnvName(ref)) {
        case Some(name) =>
            return "环境变量 ${name} 未设置或为空（注意：要设在**服务进程**的环境里，" +
                   "不是设在你敲命令的那个窗口）"
        case None => ()
    }
    match (keyRefFilePath(ref)) {
        case Some(path) => return "密钥文件读不到或为空：${path}"
        case None => ()
    }
    match (keyRefBuiltinName(ref)) {
        case Some(name) =>
            /* 先区分"到期"与"常量缺失"：到期是预期行为，要说清到期日与替代做法。 */
            if (aiBuiltinExpired(name, hDateStringOf(hNowEpoch()))) {
                return aiBuiltinExpiredMessage(name)
            }
            return "内置引用 `builtin:${name}` 没有对应的内置常量（应当是编译期就有的常量，缺失说明版本不对）"
        case None => ()
    }
    return "ai.key_ref 既不是 env: / file: / builtin:（只接受这三种形式）"
}

/* ===================== 出站调用 ===================== */

/* 系统提示：P3 的 Prompt 模板库里有可覆盖的版本；这里是**内置兜底**。 */
public let AI_SYS_FALLBACK: String =
    "你是医院导诊助手。只输出给患者看的一到两句中文说明，不要诊断，不要开药，不要给剂量。"

/* 调一次 chat/completions（OpenAI 兼容）。
 * 不抛异常：失败都变成 ok=false + source="rules" + reason，不能让网络抖动变成 500。
 * 每次新建 Client 并 close：连接泄漏比复用收益更值得防。 */
public func aiCallChat(o: AiRuntimeOptions, prompt: String, now: Int64): AiCallResult {
    let (can, why) = aiCanCall(o)
    if (!can) { let r = AiCallResult(); r.reason = why; return r }
    aiGate(o.maxConcurrent).acquire()
    /* 墙钟硬上限（含 DNS/connect/读写）：框架没有 connectTimeout，用 Future 到点如实降级。
     * Future 超时不取消底层 TCP，worker 跑完才退；残留受 ai.max_concurrent 约束。 */
    let deadline = if (o.timeoutSecs > 0) { o.timeoutSecs } else { 30 }
    var task: ?Future<AiCallResult> = None
    try {
        task = Some(spawn { =>
            try {
                return aiCallChatRaw(o, prompt, now, retryBudgetMs: deadline * 1000)
            } finally {
                aiReleaseGate()
            }
        })
    } catch (e: Exception) {
        aiReleaseGate()
        let r = AiCallResult()
        r.reason = "无法启动模型任务，已降级为规则"
        return r
    }
    try {
        return task.getOrThrow().get(Duration.second * deadline)
    } catch (e: TimeoutException) {
        let r = AiCallResult()
        r.reason = "模型调用超过 ${deadline}s 全链路上限（含 DNS/connect/读写），已降级为规则"
        return r
    } catch (e: Exception) {
        /* 超时与非超时分开：解析失败/worker 内异常不能被报成超时。 */
        let r = AiCallResult()
        r.reason = "模型调用执行失败（不是超时）：${e.message}，已降级为规则"
        return r
    }
}

/* 分诊模型的剩余等待预算：先 tryAcquire 拿许可，再启动纯网络 worker。
 * 许可由 worker 退出时归还；满载或预算耗尽即降级。 */
public func aiCallChatBudget(o: AiRuntimeOptions, prompt: String, now: Int64,
                             budgetMs: Int64): AiCallResult {
    let fallback = AiCallResult()
    let (can, why) = aiCanCall(o)
    if (!can) { fallback.reason = why; return fallback }
    if (budgetMs <= 0) { fallback.reason = "分诊增强预算已耗尽，已降级为规则"; return fallback }
    if (!aiGate(o.maxConcurrent).tryAcquire()) {
        fallback.reason = "模型并发额度已满，已降级为规则"
        return fallback
    }
    // spawn失败也必须归还许可；正常启动后许可只由worker归还。
    var task: ?Future<AiCallResult> = None
    try {
        task = Some(spawn { =>
            try {
                return aiCallChatRaw(o, prompt, now, ioTimeoutSecs: (budgetMs + 999) / 1000, retryBudgetMs: budgetMs)
            } finally {
                aiReleaseGate()
            }
        })
    } catch (e: Exception) {
        aiReleaseGate()
        fallback.reason = "无法启动模型任务，已降级为规则"
        return fallback
    }
    try {
        return task.getOrThrow().get(Duration.millisecond * budgetMs)
    } catch (e: Exception) {
        fallback.reason = "分诊模型未在等待预算内完成，已降级为规则"
        return fallback
    }
}

/* 有界重试：云侧 429/5xx 抖动不该让分诊消失，只重试真的发出去过的请求。
 * 400/401/403/404 与 invalidOutput 不重试：重试只会再取一次坏结果。
 * 最多 2 次尝试（最多重试 1 次），退避 200 ms。 */
public let AI_CALL_MAX_ATTEMPTS: Int64 = 2
public let AI_CALL_RETRY_BACKOFF_MS: Int64 = 200

/* 判断这次失败值不值得再试一次。 */
func aiCallRetryable(r: AiCallResult): Bool {
    if (r.ok) {
        return false
    }
    if (!r.attempted) {
        return false
    }
    if (r.invalidOutput) {
        return false
    }
    if (r.httpStatus == 0) {
        return true
    }
    if (r.httpStatus == 429) {
        return true
    }
    return r.httpStatus >= 500
}

/* 同一请求的**单次**执行（不含重试）。 */
private func aiCallChatOnce(o: AiRuntimeOptions, prompt: String, now: Int64,
                            ioTimeoutSecs!: Int64 = 0): AiCallResult {
    let r = AiCallResult()
    let t0 = aiNowMs()
    let (can, why) = aiCanCall(o)
    if (!can) {
        r.reason = why
        return r
    }
    var key = ""
    match (aiResolveKey(o.keyRef)) {
        case Some(k) => key = k
        case None =>
            r.reason = aiKeyRefProblem(o.keyRef)
            return r
    }
    /* 内置密钥不得跟着别人的 base_url 发出去。 */
    let (hostOk, hostWhy) = aiBuiltinKeyHostCheck(o.keyRef, o.endpoint)
    if (!hostOk) {
        r.reason = hostWhy
        return r
    }
    /* 请求体只发必要字段；stream:false 是刻意：服务端不消费流。 */
    /* temperature 取自生效的模型配置（旧 KV 路线取 ai.temperature，默认 0.30）。 */
    let reqBody = JsonObject()
    reqBody.put("model", JsonString(o.model))
    reqBody.put("max_tokens", JsonInt(o.maxTokens))
    reqBody.put("temperature", JsonFloat(o.temperature))
    let msgs = JsonArray()
    let sysMsg = JsonObject()
    sysMsg.put("role", JsonString("system"))
    sysMsg.put("content", JsonString(AI_SYS_FALLBACK))
    msgs.add(sysMsg)
    let userMsg = JsonObject()
    userMsg.put("role", JsonString("user"))
    userMsg.put("content", JsonString(prompt))
    msgs.add(userMsg)
    reqBody.put("messages", msgs)

    try {
        // 并发许可由外层持有，本函数不能再次获取。
        let b = ClientBuilder()
        /* TLS 必须显式配置，否则 https 直接抛 TlsException（类名 TlsClientConfig，TlsConfig 是接口不能实例化）。
         * 信任锚走 OpenSSL：必须设 SSL_CERT_FILE 指向 PEM 包，它不读 Windows 证书库。
         * 本版本 TlsClientConfig 没有 CA bundle 入口（certificate 是 mTLS 客户端证书），
         * 故 ai.ca_bundle_path 在配置层标 unsupported、写入即拒，不能假装接上了。 */
        b.tlsConfig(TlsClientConfig())
        /* 刻意直连：不设 noProxy 会走系统 http_proxy，内网/回环会被拦成 502。 */
        b.noProxy()
        /* 超时：ai.timeout_secs 只是请求级 read/write 超时，框架没有 connectTimeout，
         * 连不可达地址由系统 TCP 超时决定（约 21 s），应用层改不了，文档必须写明。
         * 请求级与 client 级都设：请求级才是逐次生效的那一层。 */
        let seconds = if (ioTimeoutSecs > 0 && ioTimeoutSecs < o.timeoutSecs) {
            ioTimeoutSecs
        } else { o.timeoutSecs }
        let d = Duration.second * seconds
        b.readTimeout(d)
        b.writeTimeout(d)
        let c = b.build()
        try {
        let req = HttpRequestBuilder().method("POST").url(o.endpoint)
            .header("Content-Type", "application/json")
            .header("Authorization", "Bearer " + key)
            .readTimeout(d)
            .writeTimeout(d)
            .body(reqBody.toString()).build()
        /* 从这一行起才算真的发出去过，重试只看这个标记。 */
        r.attempted = true
        let resp = c.send(req)
        let status = Int64(resp.status)
        let body = aiReadAll(resp.body)
        r.elapsedMs = aiNowMs() - t0
        r.httpStatus = status
        if (status < 200 || status >= 300) {
            /* 错误体不回显给患者，先脱敏再进 reason。 */
            r.reason = "模型返回 HTTP ${status}：${aiRedact(body, key)}"
            return r
        }
        match (aiExtractContent(body)) {
            case Some(text) =>
                if (text.trimAscii().size == 0) {
                    /* 200 但内容为空 —— 算"答了但不合格"，不是网络问题。 */
                    r.invalidOutput = true
                    r.source = "model:invalid"
                    r.reason = "模型返回 200 但内容为空"
                    return r
                }
                r.ok = true
                r.text = text.trimAscii()
                r.source = "model"
                return r
            case None =>
                r.invalidOutput = true
                r.source = "model:invalid"
                r.reason = "响应不是预期的 JSON 形状（choices[0].message.content）"
                return r
        }
        } finally {
            c.close()
        }
    } catch (e: Exception) {
        r.elapsedMs = aiNowMs() - t0
        /* 异常消息也可能含密钥（库会把 URL/头拼进消息），一律过 aiRedact。
         * 这一层不能省：成本是一次字符串查找，漏一次就是密钥进日志。 */
        r.reason = "出站调用异常：${aiRedact(e.message, key)}"
        return r
    }
}

/* 执行一次调用，遇瞬时失败按 AI_CALL_MAX_ATTEMPTS 重试。
 * 间隔 sleep 200 ms；本函数不持任何锁，绝不能在持锁区里睡。
 * 最后一次结果原样返回，只在 reason 前加可数的重试次数。 */
private func aiCallChatRaw(o: AiRuntimeOptions, prompt: String, now: Int64,
                           ioTimeoutSecs!: Int64 = 0, retryBudgetMs!: Int64 = 0): AiCallResult {
    let startMs = aiNowMs()
    var attempt: Int64 = 1
    var r = aiCallChatOnce(o, prompt, now, ioTimeoutSecs: ioTimeoutSecs)
    while (attempt < AI_CALL_MAX_ATTEMPTS && aiCallRetryable(r)) {
        /* 重试不能越过调用方期限：预计会用掉一半以上预算就不重试。 */
        if (retryBudgetMs > 0) {
            let used = aiNowMs() - startMs
            if (used + AI_CALL_RETRY_BACKOFF_MS > retryBudgetMs / 2) {
                r.reason = "${r.reason}（剩余预算不足，未重试）"
                break
            }
        }
        attempt = attempt + 1
        sleep(Duration.millisecond * AI_CALL_RETRY_BACKOFF_MS)
        r = aiCallChatOnce(o, prompt, now, ioTimeoutSecs: ioTimeoutSecs)
    }
    if (attempt > 1 && !r.ok && r.reason.size > 0) {
        r.reason = "（已重试 ${attempt - 1} 次）${r.reason}"
    }
    return r
}

/* 读尽响应体（`InputStream` 没有 readToEnd，必须自己循环）。 */
public func aiReadAll(body: InputStream): String {
    let buf = Array<UInt8>(8192, repeat: 0)
    let out = ArrayList<UInt8>()
    while (true) {
        let n = body.read(buf)
        if (n <= 0) {
            break
        }
        var i: Int64 = 0
        while (i < n) {
            out.add(buf[i])
            i = i + 1
        }
        /* 上限 1 MiB：未受信响应不能无限吃内存。 */
        if (out.size > AI_MAX_RESP_BYTES) {
            break
        }
    }
    return String.fromUtf8(out.toArray())
}


/* 从 OpenAI 兼容响应里取 choices[0].message.content。
 * 每一层先判类型再取值：asXxx() 类型不符会抛异常而不是返回 None。 */
public func aiExtractContent(body: String): ?String {
    try {
        let v = JsonValue.fromStr(body)
        if (!(v is JsonObject)) {
            return None
        }
        let o = v.asObject()
        match (o.get("choices")) {
            case Some(ch) =>
                if (!(ch is JsonArray)) {
                    return None
                }
                let arr = ch.asArray()
                if (arr.size() < 1) {
                    return None
                }
                let first = arr[0]
                if (!(first is JsonObject)) {
                    return None
                }
                match (first.asObject().get("message")) {
                    case Some(m) =>
                        if (!(m is JsonObject)) {
                            return None
                        }
                        match (m.asObject().get("content")) {
                            case Some(c) =>
                                if (c is JsonString) {
                                    return Some(c.asString().getValue())
                                }
                                return None
                            case None => return None
                        }
                    case None => return None
                }
            case None => return None
        }
    } catch (e: Exception) {
        return None
    }
}

/* 脱敏：把密钥从任意文本里抹掉，这是最后一道防线而非唯一一道。
 * 密钥短于 8 字符时不替换，否则会大量误伤普通单词。 */
public func aiRedact(text: String, key: String): String {
    if (key.size < 8) {
        return text
    }
    var out = text
    /* 循环替换（原文里可能多次出现） */
    var guard_ = 0
    while (out.contains(key) && guard_ < 16) {
        out = out.replace(key, "***")
        guard_ = guard_ + 1
    }
    return out
}


/* 连通性测试的公共出站段：只有一次、短超时、由人触发，与正式调用刻意分开。
 * 分开是因为正式路径上的每个分支都是患者可见风险，不能混入测试分支。
 * 安全口径相同：https 强制、密钥只从引用解析、错误体先脱敏。 */
private func aiProbePost(endpoint: String, keyRef: String, bodyJson: String,
                         timeoutSecs: Int64): AiCallResult {
    let r = AiCallResult()
    let t0 = aiNowMs()
    if (!startsWithAscii(endpoint.toAsciiLower(), "https://")) {
        r.reason = "接口地址必须是 https://（明文调用大模型 = 密钥裸奔）"
        return r
    }
    var key = ""
    match (aiResolveKey(keyRef)) {
        case Some(k) => key = k
        case None =>
            r.reason = aiKeyRefProblem(keyRef)
            return r
    }
    /* 探活也走同一道白名单，否则"测试通过"会骗人。 */
    let (probeHostOk, probeHostWhy) = aiBuiltinKeyHostCheck(keyRef, endpoint)
    if (!probeHostOk) {
        r.reason = probeHostWhy
        return r
    }
    try {
        let b = ClientBuilder()
        b.tlsConfig(TlsClientConfig())
        b.noProxy()
        let d = Duration.second * timeoutSecs
        b.readTimeout(d)
        b.writeTimeout(d)
        let c = b.build()
        try {
            let req = HttpRequestBuilder().method("POST").url(endpoint)
                .header("Content-Type", "application/json")
                .header("Authorization", "Bearer " + key)
                .readTimeout(d)
                .writeTimeout(d)
                .body(bodyJson).build()
            let resp = c.send(req)
            let status = Int64(resp.status)
            let body = aiReadAll(resp.body)
            r.elapsedMs = aiNowMs() - t0
            r.httpStatus = status
            if (status < 200 || status >= 300) {
                r.reason = "模型返回 HTTP ${status}：${aiRedact(body, key)}"
                return r
            }
            r.text = body
            /* 这里的 ok 只表示出站走到 HTTP 2xx；形状校验由调用方接着做并修正 ok。
             * 分两段是为了不覆盖已有失败原因（401 比"形状不对"有用）。 */
            r.ok = true
            return r
        } finally {
            c.close()
        }
    } catch (e: Exception) {
        r.elapsedMs = aiNowMs() - t0
        r.reason = "出站调用异常：${aiRedact(e.message, key)}"
        return r
    }
}

/* 对话模型连通性测试：发一条最小 chat 请求。
 * max_tokens 取 8 不是 1：有些实现 max_tokens=1 返回空内容，会假失败。
 * 形状用正式路径同一函数 aiExtractContent 判，避免"测试通过、正式解析失败"。 */
public func aiProbeChat(endpoint: String, model: String, keyRef: String, temperature: Float64,
                        maxTokens!: Int64 = 8, timeoutSecs!: Int64 = 15): AiCallResult {
    let reqBody = JsonObject()
    reqBody.put("model", JsonString(model))
    reqBody.put("max_tokens", JsonInt(maxTokens))
    reqBody.put("temperature", JsonFloat(temperature))
    let msgs = JsonArray()
    let m = JsonObject()
    m.put("role", JsonString("user"))
    m.put("content", JsonString("连通性测试：请只回复 ok"))
    msgs.add(m)
    reqBody.put("messages", msgs)
    let r = aiProbePost(endpoint, keyRef, reqBody.toString(), timeoutSecs)
    if (!r.ok) {
        return r
    }
    match (aiExtractContent(r.text)) {
        case Some(text) =>
            if (text.trimAscii().size == 0) {
                r.invalidOutput = true
                r.ok = false
                r.reason = "连通（HTTP ${r.httpStatus}）但内容为空（choices[0].message.content 为空）"
                r.text = ""
                return r
            }
            r.text = text.trimAscii()
            return r
        case None =>
            r.invalidOutput = true
            r.ok = false
            r.reason = "响应不是预期的 JSON 形状（choices[0].message.content）"
            r.text = ""
            return r
    }
}

/* 向量模型连通性测试。响应形状必须在这一层校验：只看 200 会出现
 * "测试通过但回填向量时解析不出数组"。 */
public func aiProbeEmbedding(endpoint: String, model: String, keyRef: String,
                             timeoutSecs!: Int64 = 15): AiCallResult {
    let reqBody = JsonObject()
    reqBody.put("model", JsonString(model))
    /* input 用数组：OpenAI 兼容约定，两种都收的实现也认数组。 */
    let inputs = JsonArray()
    inputs.add(JsonString("ping"))
    reqBody.put("input", inputs)
    let r = aiProbePost(endpoint, keyRef, reqBody.toString(), timeoutSecs)
    /* 只要 HTTP 层已失败就保留其原因，不能被"形状不对"覆盖。 */
    if (!r.ok) {
        return r
    }
    let dim = aiExtractEmbeddingDim(r.text)
    if (dim <= 0) {
        r.invalidOutput = true
        r.reason = "响应不是预期的向量形状（data[0].embedding 不是非空数组）"
        r.text = ""
        return r
    }
    r.ok = true
    r.text = "向量维度 ${dim}"
    return r
}

/* 从 embeddings 响应里取向量维度；形状不符返回 -1。
 * 每层先判类型再取值：asXxx() 类型不符会抛异常。 */
public func aiExtractEmbeddingDim(body: String): Int64 {
    try {
        let v = JsonValue.fromStr(body)
        if (!(v is JsonObject)) {
            return -1
        }
        match (v.asObject().get("data")) {
            case Some(d) =>
                if (!(d is JsonArray)) {
                    return -1
                }
                let arr = d.asArray()
                if (arr.size() < 1) {
                    return -1
                }
                let first = arr[0]
                if (!(first is JsonObject)) {
                    return -1
                }
                match (first.asObject().get("embedding")) {
                    case Some(e) =>
                        if (!(e is JsonArray)) {
                            return -1
                        }
                        return e.asArray().size()
                    case None => return -1
                }
            case None => return -1
        }
    } catch (e: Exception) {
        return -1
    }
}
