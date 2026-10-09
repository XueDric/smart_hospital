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
 * ===== ai_call.cj —— 真模型出站调用（P5 第一步）==================
 *
 * P2 立分诊/预问诊时**刻意只做规则**，把"接真模型"挂起（阻塞于 brief §10 的
 * **Q6 合规评估**）。P3 把配置底座建齐了（`ai_setting` KV + 密钥只存引用 +
 * 改配置零重启 + Prompt 模板 + 工具开关）。**本文件补的是最后一环：出站调用。**
 *
 * ---------------------------------------------------------------------------
 * ## 三条不可让步的纪律
 *
 * ### ① 密钥**只在出站那一刻**从引用解析出来 —— 不落库、不缓存、不进日志
 *
 * 库里存的是 `env:DEEPSEEK_API_KEY`（一个**引用**）；本文件在**发起请求前**
 * 才把它解析成真密钥，用完即弃（局部变量，不出这个函数）。
 * ⚠ 并且**绝不把密钥写进任何错误消息 / 日志**：连"前 4 位 + 后 4 位"都不给
 *   （那在只有 32 字符的 key 上已经泄露了 25%）。
 *
 * ### ② 失败**必须降级回规则**，且**如实标注**
 *
 * 模型不可用有十几种原因（DNS、超时、401、限流、返回体不是 JSON…）。
 * 无论哪种，**患者的就医路径不能因此断掉** —— `triage.cj` 的规则引擎是
 * 权威兜底（P2 实测过它对危急征象的判定）。所以：
 *   · 调用失败 ⇒ 回退到规则结论，`source` 标成 `rules`（而不是假装模型成功了）；
 *   · 调用成功 ⇒ `source` 标成 `model`；
 *   · 调用成功但模型输出不合法 ⇒ `source` 标成 `model:invalid`（**与规则失败区分**，
 *     因为处置不同：前者要改 Prompt，后者要查网络）。
 *
 * ### ③ ★★ 模型**不能**改变"给不给号"这件事
 *
 * 这是最重要的一条。P2 建了一个硬性验证层："**绝不给没有号的推荐**"。
 * 若让模型自由推荐科室，它完全可能推荐一个**没有排班**的科室 —— 那会把
 * 患者引到一个挂不上号的死路，而且是**模型看起来很有道理地**引过去的
 * （比规则出错更难发现）。
 * ⇒ 本文件的定位是**增强，不是替代**：
 *     · `triage` 的 `options`（科室 + 排班 + 号源）**仍由规则与数据库决定**；
 *     · 模型**只**产出给患者看的**解释文字**与对主诉的**理解归纳**。
 *     模型说什么都不会让一个没号的科室出现在推荐里。
 *
 * ---------------------------------------------------------------------------
 * ## ⚠ 一处必须记下的**注释更正**（本仓反复出现的病：注释比实现旧）
 *
 * `http_app.cj` 与 `main.cj` 都有注释说：
 *   「本工具链的仓颉 std **没有 `getEnv`/`envVars`**（照抄框架 config.cj）」
 * 我照着那句一度以为 `env:` 引用**根本无法解析**。
 * **实测（2026-10-09）**：`std.env.getVariable` **存在且可用** ——
 *   import std.env.*     ⇒  `getVariable("X")` 返回 `?String`
 *   实测 `getVariable("PROBE_TEST_VAR")` 拿到 `hello-from-env` ✅
 * ⇒ 那句注释是**过时的**（很可能照抄自更早的 SDK）。我没有去改那两处注释
 *   （它们是别人的上下文，且改动面比本任务大），但**这里必须写明**，
 *   否则下一个人会像我一样绕一大圈。
 *   📌 这正是本项目的教训：**注释会过期，实测不会** —— 拿不准就写最小探针。
 */

/*
 * ⚠⚠ 常量**必须定义在使用之前** —— 仓颉**没有 hoisting**。
 *   本任务里我已经**第二次**踩这个（第一次在 domain_base.cj）。
 *   所以这里把常量集中在最前面，并把原因写死。
 */
/* 响应体读取上限：模型返回不该超过 1 MiB。没有上限时一个畸形/恶意响应能吃掉内存。 */
public let AI_MAX_RESP_BYTES: Int64 = 1024 * 1024

/*
 * ★★ 出站并发闸（2026-10-09 补 —— 复查发现 `ai.max_concurrent` **被校验、被存库、
 *    被回显，却没有任何地方消费**，正是本项目反复复抓的那一类"配置看起来生效"）。
 *
 * ⚠⚠ 这里有一个**必须讲清的口径边界**：
 *   `ai.max_concurrent` 是**库配置**（管理员可改），而信号量的容量在**进程启动时**
 *   就定了 —— 仓颉没有"运行时改信号量容量"这种操作。
 *   ⇒ 所以本闸取**启动后第一次出站时读到的值**，之后不再变。
 *     文档与回显必须写明这一点，否则又是一次"看起来生效"。
 *   📌 为什么不每次调用都新建信号量：那等于**没有限流**（每个请求各自持有一个信号量）。
 *
 * ⚠ 另一个诚实边界（复查实测指出）：本闸限的是**本进程内同时进行的出站调用数**。
 *   它不限制连接数上限、也不排队超时 —— 若并发远超上限，
 *   请求会**在 acquire 处等待**（这是限流的本意：宁可等，不要打爆下游）。
 */
private var aiSemCapacity: Int64 = 0
private let aiSemLock = Mutex()
private var aiSem: ?Semaphore = None

/* 取（必要时创建）出站并发闸。容量取**首次**调用时配置的值。 */
private func aiAcquireGate(limit: Int64): Unit {
    aiSemLock.lock()
    try {
        if (aiSemCapacity != limit) {
            if (aiSem.isNone()) {
                aiSem = Some(Semaphore(limit))
                aiSemCapacity = limit
            }
            /*
             * ⚠ 配置在运行中被改成**不同**的值时，**不重建**信号量
             *   （重建会让正在等待的调用永久阻塞）。只记一行提示。
             */
        }
    } finally {
        aiSemLock.unlock()
    }
    match (aiSem) {
        case Some(s) => s.acquire()
        case None => ()
    }
}

private func aiReleaseGate(): Unit {
    match (aiSem) {
        case Some(s) => s.release()
        case None => ()
    }
}

/*
 * 单调时钟（毫秒）。
 *
 * ⚠⚠ 复查发现 `elapsedMs` **恒为 0** —— 根因是我把**同一个** `now` 参数既当起点又当终点：
 *     `let t0 = now ... r.elapsedMs = now - t0` ⇒ 恒等于 0。
 *   那个字段的注释写着"用于看板的调用耗时与超时排查"，
 *   而它恰是能暴露"超时没接线"的信号 —— 却永远是 0。
 *   ⇒ 改成**真的读时钟**（`DateTime.now()`）。
 *   📌 教训：**用参数当"当前时间"就等于假设调用是瞬时的**；测耗时必须读真时钟。
 */
private func aiNowMs(): Int64 {
    return DateTime.now().toUnixTimeStamp().toMilliseconds()
}

/* ===================== 结果与状态 ===================== */

/*
 * 出站调用的结果。
 *
 * ⚠ `source` 是本类型存在的主要理由：调用方（分诊/预问诊）要能**如实**把它
 *   透传给患者，而不是笼统地把"有文字返回"当成成功。
 */
public class AiCallResult {
    public var ok: Bool = false
    /* 模型产出的文本（成功时非空）。 */
    public var text: String = ""
    /*
     * 来源标注，直接可给患者看：
     *   "model"         —— 模型真的回答了
     *   "rules"         —— 没配模型 / 未启用 / 调用失败（降级）
     *   "model:invalid" —— 模型答了，但输出不符合要求（要改 Prompt，不是查网络）
     */
    public var source: String = "rules"
    /* 失败原因（**给运维看**，不含密钥）。空串表示成功。 */
    public var reason: String = ""
    /* 耗时（毫秒）。用于看板的"调用耗时"与超时排查。 */
    public var elapsedMs: Int64 = 0
    /* 是否发生了解析或校验层面的失败（与网络失败区分）。 */
    public var invalidOutput: Bool = false
}

/* ===================== 可调用性判定 ===================== */

/*
 * AI 是否**真的可以调用**（配置齐、开关开、密钥引用能解析出真密钥）。
 *
 * ⚠ 刻意**不返回 Bool**，而是返回 `（可否, 原因）`：看板与排障都需要知道
 *   "为什么没调模型"，只给一个 false 会逼人去猜。
 * ⚠ 也刻意**不缓存**结果：`ai_setting` 是"改配置零重启"的（P3 立的纪律），
 *   任何跨请求缓存都会破坏它。
 */
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

/*
 * 把 `env:名` / `file:路径` 解析成**真密钥**。
 *
 * ⚠ 返回值只在调用侧短暂存在，**不得**被存进任何字段或日志。
 * ⚠ `file:` 路径要**去掉首尾空白**（PEM/密钥文件常见尾随换行；带着它发出的
 *   请求头会变成 `Authorization: Bearer sk-xxx\n` ⇒ 服务端 401，
 *   而症状看起来像"密钥错了"，极难查）。
 */
public func aiResolveKey(ref: String): ?String {
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
    /* 既不是 env: 也不是 file: —— 不该发生（`put` 会拒），但如实回报。 */
    return None
}

/*
 * 密钥引用解析失败时的**可执行**原因 —— 不含密钥本体。
 *
 * ⚠ 刻意把两种失败分开说：`env:` 失败是"环境变量没设/在服务进程里没设"，
 *   `file:` 失败是"文件读不到"。混成一句话会让人查错方向。
 */
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
    return "ai.key_ref 既不是 env: 也不是 file:"
}

/* ===================== 出站调用 ===================== */

/* 系统提示：P3 的 Prompt 模板库里有可覆盖的版本；这里是**内置兜底**。 */
public let AI_SYS_FALLBACK: String =
    "你是医院导诊助手。只输出给患者看的一到两句中文说明，不要诊断，不要开药，不要给剂量。"

/*
 * 调一次 chat/completions（OpenAI 兼容）。
 *
 * ⚠ **不抛异常**：所有失败都变成 `AiCallResult.ok = false` +
 *   `source = "rules"` + `reason`。理由见文件头纪律 ②：
 *   调用方是患者的就医路径，不能让一次网络抖动变成 500。
 *
 * ⚠ 每次都新建 `Client` 并 `close()`：本项目**不是高并发网关**，
 *   连接复用带来的收益远小于"忘记 close 导致连接泄漏"的风险
 *   （而 `stdx` 的 Client 不 close 会一直持有 socket）。
 *   📌 若将来要高频调用，再引入池化 —— 那时**先写压测**，不要凭感觉加。
 */
public func aiCallChat(o: AiRuntimeOptions, prompt: String, now: Int64): AiCallResult {
    let r = AiCallResult()
    /*
     * ★★ 用**真时钟**量耗时（2026-10-09 修）。
     * ⚠ 原来写的是 `let t0 = now` —— 而 `now` 是**调用方传进来的参数**，
     *   末尾又用 `now - t0` ⇒ **恒等于 0**。复查实测确认了这一点。
     */
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
    /*
     * 请求体：只发必要字段。
     * ⚠ `stream: false` 是**刻意**的：本项目在服务端**自己不消费流**
     *   （患者侧的 SSE 由我们重新产出）。让模型侧也流式只会让"超时/半截响应"
     *   更难处理，收益为零。
     */
    let reqBody = JsonObject()
    reqBody.put("model", JsonString(o.model))
    reqBody.put("max_tokens", JsonInt(o.maxTokens))
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
        /*
         * ★★ 出站并发闸（`ai.max_concurrent`）——2026-10-09 补。
         * ⚠ 复查发现这个旋钮**被校验、被存库、被回显，却没有任何地方消费**。
         *   ⚠ 口径边界：容量取**启动后首次出站**时配置的值（仓颉没有运行时改信号量容量），
         *     已写进 `ai_settings.cj` 的说明与 `ai-live-check`。
         */
        aiAcquireGate(o.maxConcurrent)
        let b = ClientBuilder()
        /*
         * ⚠⚠ TLS **必须显式配置**，否则对 https:// 会直接抛
         *   `TlsException: TLS must be configured when HTTPS requests are sent`。
         *   类名是 **`TlsClientConfig`**（在 `stdx.net.tls`）—— 这一条我试错了好几次，
         *   记下来免得下一个人重走：
         *     · `TlsConfig` —— 是**接口**，不能实例化；
         *     · `ClientTlsConfig` —— **不存在**（编译器说 undeclared identifier）；
         *     · `TlsClientConfig` —— ✅ 就是它。
         */
        /*
         * ⚠⚠ `ai.ca_bundle_path` **不能在这里接线**（2026-10-09 查清并如实处理）：
         *
         *   我原本打算设 `TlsClientConfig().certificate = Some(certs)`，编译器给出的期望类型是
         *     `Option<Tuple<Array<Certificate>, PrivateKey>>`
         *   —— 那是**客户端证书（mTLS）**，**不是信任锚**。
         *   这个版本的 `TlsClientConfig` **没有** CA bundle / 自定义信任库入口。
         *   ⇒ 它在**架构上无法在本版本生效**，不是"懒得接"。
         *
         *   ⇒ 处置：把那个配置项在 `ai_settings.cj` 里标成 **unsupported**，
         *     **写入即被拒**并给出「为什么 + 怎么办」。这样"我配了自建 CA"
         *     会在**配置那一刻**失败，而不是等到连不上时让人去猜网络。
         *     📌 比"接线了但假的"和"静默忽略"都好 —— 那两者都会把排查引向错误方向。
         */
        b.tlsConfig(TlsClientConfig())
        /*
         * ⚠ `noProxy()`：不设的话 stdx 会走系统 `http_proxy`，
         *   内网/回环地址会被代理拦成 502（框架 httpclient.cj 里踩过同一个坑）。
         *   而调云模型时**代理通常是需要的** —— 这里刻意**直连**，
         *   因为本项目部署在内网、由出口网关统一出网；
         *   若将来要在带代理的环境跑，应把代理**做成一项显式配置**，
         *   而不是靠环境变量隐式生效（隐式生效正是"配置漂移"的来源）。
         */
        b.noProxy()
        /*
         * ★★ 超时（`ai.timeout_secs`）——2026-10-09 补。**这是本轮最严重的一个发现**。
         *
         * 复查实测：设 `ai.timeout_secs = 5`、端点指向不可达地址，
         * 患者请求**挂了 21130 ms**，而 `ai_reason` 报的是操作系统级 connect 超时
         * ⇒ 配置的 5 秒**完全没生效**。
         * 静态确认：`timeoutSecs` 只出现在 `options()`、校验与解析断言里，出站**一次都没用**。
         *
         * ⚠⚠ **必须讲清的两个边界，不能假装超时是全能的**：
         *
         *   ① 框架**没有 connect 超时**（我把 `stdx.net.http.cjo` 的 ClientBuilder 成员
         *      全列出来核对过：只有 readTimeout / writeTimeout / poolSize /
         *      maxFrameSize / autoRedirect / proxy / logger，**没有 connectTimeout**）。
         *      ⇒ 「连一个**不可达**地址」这一段的时长由**操作系统的 TCP 连接超时**决定
         *        （本机实测约 21 秒），**我们在应用层改不了**。
         *        所以复查那条 21 秒**不是"接线后又没生效"**，而是**连不上时必然如此**。
         *   ② 但**握手成功之后的读写**是能限的，而且那才是"一直不回的端点"那种
         *      真会**无限挂住并占着服务线程**的形态（复查也点出了这一层）。
         *
         * ⇒ 接的是 ①'s 能接的部分：**请求级** read/write 超时都设上，
         *   并在文档里**如实写明 connect 阶段不受控**。
         *   📌 只设 client 级不够 —— 请求级才是逐次生效的那一层，两层都设。
         */
        let d = Duration.second * o.timeoutSecs
        b.readTimeout(d)
        b.writeTimeout(d)
        let c = b.build()
        let req = HttpRequestBuilder().method("POST").url(o.endpoint)
            .header("Content-Type", "application/json")
            .header("Authorization", "Bearer " + key)
            .readTimeout(d)
            .writeTimeout(d)
            .body(reqBody.toString()).build()
        let resp = c.send(req)
        let status = Int64(resp.status)
        let body = aiReadAll(resp.body)
        c.close()
        aiReleaseGate()
        r.elapsedMs = aiNowMs() - t0
        if (status < 200 || status >= 300) {
            /*
             * ⚠ 错误体**不回显给患者**，只进 `reason`（运维看）。
             *   而且**先脱敏**：模型服务商偶尔会在错误里回显请求头片段。
             */
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
    } catch (e: Exception) {
        aiReleaseGate()
        r.elapsedMs = aiNowMs() - t0
        /*
         * ⚠ 异常消息也可能含密钥（例如把整个请求 URL/头拼进消息的库）。
         *   一律过 `aiRedact`。**这一层不能省** —— 它的成本是一次字符串查找，
         *   而漏一次就是密钥进日志。
         */
        r.reason = "出站调用异常：${aiRedact(e.message, key)}"
        return r
    }
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
        /*
         * ⚠ 设上限：模型返回体不该超过 1 MiB。没有上限的话，
         *   一个畸形/恶意响应能把内存吃满（本项目是**面向不可信网络**的）。
         */
        if (out.size > AI_MAX_RESP_BYTES) {
            break
        }
    }
    return String.fromUtf8(out.toArray())
}


/*
 * 从 OpenAI 兼容响应里取 `choices[0].message.content`。
 *
 * ⚠ 每一层都**先判类型再取值**：`asXxx()` 在类型不符时**抛异常**而不是返回 None
 *   （本仓 API-NOTES 记过这条），所以 `if (v is JsonString)` 这类判断不能省。
 */
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

/*
 * 脱敏：把密钥从任意文本里抹掉。
 *
 * ⚠ 只在密钥**足够长**时才替换。密钥短于 8 字符时替换会产生大量误伤
 *   （把普通单词切碎），而短密钥本身也不该被允许 —— `validateKeyRef` 已拦住
 *   明显的密钥形态。这里是**最后一道**防线，不是唯一一道。
 */
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
