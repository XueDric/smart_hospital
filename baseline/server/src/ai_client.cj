package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * AI 能力 · 出站调用、输出归一化、降级与审计素材
 *
 * 对应：api-design.md Part 7 · llm-client-spec.md §5.2 / §5.4 / §5.5 / §6
 *
 * 分工：本文件**不依赖 Store**（因此不碰任何锁），只做「把模型调通并翻译成业务语义」。
 * 审计由 handler 用 `AiResult` 里的字段去写（那里才有 Store）。
 *
 * 三条设计口径：
 *   1. **永不把异常抛给上层**：一切失败都变成 `source != "model"` 的降级结果。
 *   2. **模型输出是不可信输入**：必须过 extractJson（剥围栏/括号配平）→ 严格解析
 *      → aiNormalize 剔 null → JsonSchema 校验；不合法就重试一次，再不行才降级。
 *      **绝不把没校验过的内容当业务值返回。**
 *   3. **限流用 tryAcquire 而非阻塞 acquire**（spec §14.5① 的决策）：
 *      拿不到许可立刻降级，不排队堆积——排队的请求仍然占着入站线程。
 */

import std.collection.*
import std.sync.*
import std.time.*
import stdx.encoding.json.*
import stdx.net.http.*
import stdx.net.tls.*
import stdx.net.tls.common.*

/* ---- 来源标记（与 api-design Part 7 的 data.source 一一对应）---- */

public let AI_SOURCE_MODEL: String = "model"
public let AI_SOURCE_FALLBACK: String = "fallback"

/*
 * ⚠ **当前没有任何代码会产出这个值**（2026-10-06 核实）。
 *
 * R-8 之后，AI 未配置时各 handler 一律给 `fallback` + **有内容的规则兜底**
 * （spec §5.5 D2：兜底不得为空），而**不是** `"none"`。
 *
 * 保留常量的理由：① `llm-client-spec` 里"三态"的历史口径仍引用它；
 * ② 将来若要区分"连兜底都没有"，它仍是那个取值。
 * **但此前有三处注释声称"handler 会返回 none" —— 那是错的，已一并更正。**
 */
public let AI_SOURCE_NONE: String = "none"

/* ---- 调用结果 ---- */

public class AiResult {
    /* model / fallback（目前不会是 none，见 AI_SOURCE_NONE 的说明） */
    public let source: String
    /* 校验通过的模型输出；source=model 时有意义，其余为空对象 */
    public let obj: JsonObject
    /* 给用户看的一句话（fallback / none 时非空） */
    public let note: String
    /* 机器可读的结局：ok / not_configured / overloaded / timeout / network /
       rate_limited / server_error / http_error / bad_output */
    public let outcome: String
    public let elapsedMs: Int64
    public let attempts: Int64
    /* R-11（2026-10-05 晚修）：审计要求记上游 status；原先 AiResult 根本不携带它，
       光改 handler 补不上。0 = 网络层失败（无 HTTP 状态）。 */
    public let status: Int64

    public init(source: String, obj: JsonObject, note: String, outcome: String,
                elapsedMs: Int64, attempts: Int64, status: Int64) {
        this.source = source
        this.obj = obj
        this.note = note
        this.outcome = outcome
        this.elapsedMs = elapsedMs
        this.attempts = attempts
        this.status = status
    }

    public func isModel(): Bool {
        return source == AI_SOURCE_MODEL
    }
}

/* ---- 客户端 ---- */

/*
 * 只有 `opts.enabled == true` 时才构造（未启用时用 `newAiClient` 得到 None）。
 * 这样内部字段都可以是非 Option 的，避免到处 match。
 */
public class AiClient {
    private let opts: AiOptions
    private let apiKey: String
    private let client: OutboundClient
    /* 自管信号量：拿不到许可立刻降级，不用框架那套阻塞 acquire */
    private let sem: Semaphore

    public init(opts: AiOptions) {
        this.opts = opts
        this.apiKey = aiReadApiKey(opts)

        var tls = OutboundTlsOptions()
        if (opts.insecureTrustAll) {
            tls.trustAll = true
        } else {
            tls.caBundlePath = opts.caBundlePath
        }
        /*
         * AI-2（2026-10-05 修）：用我们自己的 `AiTransport`，**不用**框架的 StdxTransport。
         * 后者的读体走 httpclient.cj 的 readBodyText，把「短读」当 EOF —— 长回答会被
         * 截断，然后静默降级为 fallback（不报错，只是用户看到兜底文案）。
         * 已用 spike/llm-truncation 的分块慢发桩确定性复现：框架读法固定只收到
         * 第一块 1000 字节，正确读法收到完整 20,263 字节。
         */
        let transport = AiTransport(opts.timeoutSecs, tls, AI_MAX_RESPONSE_BYTES)
        /* maxConcurrency 传 0：把并发闸门交给下面这个 sem，以便用 tryAcquire 降级 */
        /*
         * AI-15（2026-10-05 修）：框架重试次数必须归零。
         * 原先 `RetryPolicy(2, ...)` —— 框架自己最多重试 2 次，外层 while 又跑 2 轮，
         * 于是单次请求最坏会发 **4 次 POST**（spec §5.1 要求 retryMax=1，即最多 2 次尝试），
         * 费用与限流都会被这个放大打穿。改成 1（不额外重试），
         * 重试统一由外层 `callInner` 按 `aiRetryable` 决定 —— 这样 `attempts`
         * 也等于**真实的 POST 次数**，不再少报。
         */
        let policy = RetryPolicy(1, 300, 2000)
        this.client = OutboundClient(transport, retry: policy, maxConcurrency: 0)
        this.sem = Semaphore(opts.maxConcurrent)
    }

    /* 未启用时返回 None；handler 据此给 source="fallback"（**不是 "none"**），不报错 */
    public func close(): Unit {
        client.close()
    }

    /*
     * 一次智能调用。**任何失败都不抛异常**。
     *
     * userPrompt : 由 ai_schema.cj 的 aiPromptXxx 生成
     * schema     : ai_schema.cj 的 aiSchemaXxx
     * keys       : 该功能允许出现的键（供 aiNormalize 剔 null）
     * fallback   : 兜底构造函数。**必须由调用方提供**（spec §5.5 D2：
     *              每个智能功能都要有一个不依赖模型的兜底）
     */
    public func call(userPrompt: String, schema: JsonSchema, keys: Array<String>,
                     fallback: JsonObject): AiResult {
        let t0 = aiNowMs()
        if (!sem.tryAcquire()) {
            return AiResult(AI_SOURCE_FALLBACK, fallback,
                            "当前智能请求较多，请稍后再试", "overloaded", aiNowMs() - t0, 0, 0)
        }
        try {
            return callInner(userPrompt, schema, keys, fallback, t0)
        } finally {
            sem.release()
        }
    }

    private func callInner(userPrompt: String, schema: JsonSchema, keys: Array<String>,
                           fallback: JsonObject, t0: Int64): AiResult {
        var attempt: Int64 = 0
        var last = "bad_output"
        var lastStatus: Int64 = 0
        /*
         * AI-15：只有**因为上一条输出不合法**而重试时，才追加纠错语。
         * 原先 `attempt > 1` 就无条件追加 —— 于是超时/5xx 重试时也会对模型说
         * 「你上次的 JSON 不合法」，把错误归因甩给了模型（且可能反而干扰它）。
         */
        var badOutputRetry = false
        while (attempt < 2 && aiNowMs() - t0 < opts.budgetMs) {
            attempt += 1
            /*
             * R-6（2026-10-05 晚修）：退避必须在这里补回来。
             * AI-15 把框架重试归零（RetryPolicy(1,…)）后，`outbound.cj` 里那句
             * `sleep(retry.delayMsFor(attempt))` 就成了死代码，而外层循环原先**没有任何 sleep**
             * —— 于是**恰好在被限流（429）或 5xx 时**，第二次 POST 立刻打出，
             * 正是框架"指数退避 + 抖动"要防的捶打，费用也随之翻倍。
             */
            if (attempt > 1) {
                sleep(Duration.millisecond * 300)
            }
            let resp = postOnce(userPrompt, badOutputRetry)
            last = aiClassify(resp)
            lastStatus = resp.status
            if (last == "ok") {
                match (aiParseOutput(resp.body, schema, keys)) {
                    case Some(o) =>
                        return AiResult(AI_SOURCE_MODEL, o, "", "ok", aiNowMs() - t0, attempt, lastStatus)
                    case None =>
                        /* F-7：被长度截断时不重试 —— 重试无用，且纠错语是错误归因 */
                        if (aiFinishReason(resp.body) == "length") {
                            last = "truncated"
                            break
                        }
                        last = "bad_output"
                        badOutputRetry = true
                }
            } else if (!aiRetryable(last)) {
                /* F-8：too_large 是我们**自己拒发**（一个 POST 都没出去），
                   attempts 必须记真实 POST 数 = 0（AI-15 的口径）。 */
                if (last == "too_large") {
                    attempt -= 1
                }
                break
            } else {
                badOutputRetry = false
            }
        }
        return AiResult(AI_SOURCE_FALLBACK, fallback, aiFallbackNote(last),
                        last, aiNowMs() - t0, attempt, lastStatus)
    }

    private func postOnce(userPrompt: String, correctOutput: Bool): OutboundResponse {
        let body = aiBuildRequestBody(opts.model, userPrompt, correctOutput, opts.maxTokens)
        /*
         * AI-8（2026-10-05 修）：`maxRequestBytes` 原先**声明了却从不被读**（死配置）。
         * 真正会撑大 prompt 的不是用户输入，而是**服务端自己拼的**候选名单与历史，
         * 所以在这里按字节卡住：超限**不发**出站请求。
         * 用 413 返回是刻意的 —— `aiClassify` 会归为 `http_error`，而 4xx（除 429）
         * 是**不可重试**的，于是立刻降级，不会白烧一次重试。
         */
        if (opts.maxRequestBytes > 0 && body.size > opts.maxRequestBytes) {
            /*
             * R-10（2026-10-05 晚修）：用**负数哨兵**，不要复用 413。
             * 原先自造 `OutboundResponse(413, "")` —— 与上游真实的 413 无法区分，
             * 于是 `aiClassify` 归成 `http_error`，用户看到「智能服务返回异常」，
             * 审计也记 `outcome=http_error`（把服务商的正常响应说成出错）。
             * 而 `llm-client-spec.md` 本来就有独立的 `TooLarge` 分类。
             */
            return OutboundResponse(-413, "")
        }
        let headers = HashMap<String, String>()
        headers["authorization"] = "Bearer " + apiKey
        return client.postJson(opts.endpoint, body, headers: Some(headers))
    }
}

/* 未启用时返回 None。handler 用 `match` 处理，避免到处判空。 */
public func newAiClient(opts: AiOptions): ?AiClient {
    if (!opts.enabled) {
        return None
    }
    return Some(AiClient(opts))
}

/* ===================== 出站结果的业务语义 ===================== */

func aiClassify(resp: OutboundResponse): String {
    /* R-10：我们**自己**拒发的请求（提示词超上限），不是上游的错 */
    if (resp.status == -413) {
        return "too_large"
    }
    if (resp.isNetworkFailure()) {
        let msg = match (resp.networkError) {
            case Some(m) => m
            case None => ""
        }
        if (containsAscii(msg, "timeout")) {
            return "timeout"
        }
        return "network"
    }
    if (resp.isSuccess()) {
        return "ok"
    }
    if (resp.status == 429) {
        return "rate_limited"
    }
    if (resp.status >= 500) {
        return "server_error"
    }
    return "http_error"
}

/* 可重试的结局。**4xx（除 429）不重试**——那是我们自己的请求有问题，重试无意义。 */
func aiRetryable(outcome: String): Bool {
    return outcome == "timeout" || outcome == "network" ||
           outcome == "rate_limited" || outcome == "server_error"
}

func aiFallbackNote(outcome: String): String {
    if (outcome == "timeout") {
        return "智能建议超时，以下依据历史数据给出"
    }
    if (outcome == "overloaded") {
        return "当前智能请求较多，以下依据历史数据给出"
    }
    if (outcome == "rate_limited" || outcome == "server_error" || outcome == "network") {
        return "智能服务暂时不可用，以下依据历史数据给出"
    }
    if (outcome == "http_error") {
        return "智能服务返回异常，以下依据历史数据给出"
    }
    if (outcome == "truncated") {
        return "回答被长度上限截断，建议缩小问题范围或调大 --ai-max-tokens"
    }
    if (outcome == "too_large") {
        /* R-10：中立文案 —— 这是我们自己没发出去，与服务商无关 */
        return "本次请求内容过长，已改用规则建议"
    }
    return "智能建议暂时不可用，以下依据历史数据给出"
}

/* ===================== 请求体与输出解析 ===================== */

/* OpenAI 兼容的 chat completions 请求体。correctOutput=true 时追加一句纠偏。 */
func aiBuildRequestBody(model: String, userPrompt: String, correctOutput: Bool, maxTokens: Int64): String {
    let user = if (correctOutput) {
        userPrompt + "\n\n【注意】上一次的输出不是合法 JSON。请严格只输出一个 JSON 对象，" +
                     "不要任何解释、不要 markdown 代码块。"
    } else {
        userPrompt
    }
    let msg1 = JsonObject()
    msg1.put("role", JsonString("system"))
    msg1.put("content", JsonString(AI_SYSTEM_RULE))
    let msg2 = JsonObject()
    msg2.put("role", JsonString("user"))
    msg2.put("content", JsonString(user))
    let msgs = JsonArray()
    msgs.add(msg1)
    msgs.add(msg2)

    let root = JsonObject()
    root.put("model", JsonString(model))
    root.put("messages", msgs)
    root.put("temperature", JsonFloat(0.2))
    /* AI-8：补 max_tokens。原先不限 —— 模型吐多长就付多少钱，是费用失控的另一半。 */
    /* R-14：改为可配（原先硬编码 1024，中文长正文会被截断 -> 非法 JSON -> 静默降级） */
    root.put("max_tokens", JsonInt(maxTokens))
    return root.toString()
}

/*
 * 从响应体里取出模型输出并校验。
 * 链路：choices[0].message.content → extractJson（剥围栏 + 括号配平）
 *       → JsonValue.fromStr（严格解析）→ aiNormalize（剔 null）→ schema 校验。
 * 任何一步失败都返回 None（由上层决定重试或降级）。
 */
func aiParseOutput(body: String, schema: JsonSchema, keys: Array<String>): ?JsonObject {
    match (aiExtractContent(body)) {
        case Some(text) =>
            match (extractJson(text)) {
                case Some(jsonText) =>
                    try {
                        match (JsonValue.fromStr(jsonText)) {
                            case o: JsonObject =>
                                let clean = aiNormalize(o, keys)
                                if (schema.isValid(clean)) {
                                    return Some(clean)
                                }
                                return None
                            case _ => return None
                        }
                    } catch (e: Exception) {
                        return None
                    }
                case None => return None
            }
        case None => return None
    }
}

/*
 * F-7（2026-10-05 深夜）：读 `finish_reason`。
 * 原先全文没有任何地方读它，于是**被 token 上限截断**的输出会被归成 bad_output，
 * 后果三层：① 重试时追加「上一次的输出不是合法 JSON」——对长度截断是**错误归因**，
 * 还可能促使模型写得更短；② 白花一次注定无效的付费调用；
 * ③ 用户只看到笼统的"暂不可用"，运维也拿不到"是 token 预算不够"这个信号。
 */
func aiFinishReason(body: String): String {
    try {
        match (JsonValue.fromStr(body)) {
            case root: JsonObject =>
                match (jsonGetArray(root, "choices")) {
                    case Some(arr) =>
                        if (arr.size() == 0) {
                            return ""
                        }
                        match (arr[0]) {
                            case c: JsonObject =>
                                match (jsonGetStr(c, "finish_reason")) {
                                    case Some(s) => return s
                                    case None => return ""
                                }
                            case _ => return ""
                        }
                    case None => return ""
                }
            case _ => return ""
        }
    } catch (e: Exception) {
        return ""
    }
}

/* 取 choices[0].message.content。 */
func aiExtractContent(body: String): ?String {
    try {
        match (JsonValue.fromStr(body)) {
            case root: JsonObject =>
                match (jsonGetArray(root, "choices")) {
                    case Some(arr) =>
                        if (arr.size() == 0) {
                            return None
                        }
                        match (arr[0]) {
                            case c: JsonObject =>
                                match (jsonGetObject(c, "message")) {
                                    case Some(m) => return jsonGetStr(m, "content")
                                    case None => return None
                                }
                            case _ => return None
                        }
                    case None => return None
                }
            case _ => return None
        }
    } catch (e: Exception) {
        return None
    }
}

/* 毫秒级单调性够用的当前时间（用于 elapsedMs）。 */
func aiNowMs(): Int64 {
    return DateTime.now().toUnixTimeStamp().toMilliseconds()
}
