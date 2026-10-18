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
private func aiGate(limit: Int64): Semaphore {
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
    return aiSem.getOrThrow()
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
    /*
     * ★ 2026-10-14 增：HTTP 状态码（0 = 没走到收到响应那一步）。
     *
     * ⚠ 为什么值得单独一个字段：管理台的「连通性测试」要显示"到底发生了什么"。
     *   只看 `reason` 的话，401（密钥错）与 404（地址写错）在文案里长得像
     *   "都是模型返回了一个错误" —— 而这两件事的处置完全不同
     *   （一个去改密钥，一个去改地址）。**数字比措辞更不容易被误读。**
     */
    public var httpStatus: Int64 = 0
    /*
     * ★ 2026-10-17（评审 P2-8）增：**请求是否真的发出去过**。
     *
     * ⚠ 为什么必须单独一个字段：重试只能针对"发出去之后失败"（网络抖动、429、5xx）。
     *   而"密钥解析失败 / 配置不自洽 / 总开关关着"这几类失败**根本没走到 send**，
     *   重试它们只会把同一个错误重复三遍、白等几百毫秒，还会让日志更难读。
     *   靠 `reason` 文案去猜"是不是发了请求"太脆（文案随时会改）——
     *   所以用一个显式布尔，在 `c.send(req)` 的前一行置 true。
     */
    public var attempted: Bool = false
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
    return aiResolveKeyAt(ref, hDateStringOf(hNowEpoch()))
}

/*
 * 上面那条的"可注入今天"版本（纯函数，便于断言"到期后取不到"）。
 *
 * `today` 用 `YYYY-MM-DD`；只影响 `builtin:` 分支 —— env:/file: 是运维自己放的
 * 密钥，没有有效期这回事（由他决定何时吊销）。
 */
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
    /*
     * ★ 2026-10-17：`builtin:demo` —— 从**代码里的常量**取（ai_builtin.cj）。
     *   排在这两条之后、`return None` 之前；顺序不影响正确性（三种前缀互不重叠），
     *   但保持"环境变量 → 文件 → 内置"这个从外到内的顺序便于阅读。
     * ★ 2026-10-18：内置密钥有**有效期**（`AI_BUILTIN_DEMO_VALID_UNTIL`）——
     *   到期后这里取不到，调用方因 `aiKeyRefProblem()` 的说明而知道该换成自己的密钥。
     */
    match (keyRefBuiltinName(ref)) {
        case Some(name) =>
            match (aiBuiltinKeyOfAt(name, today)) {
                case Some(k) => return Some(k)
                case None => return None
            }
        case None => ()
    }
    /* 既不是 env: / file: 也不是白名单内的 builtin: —— 不该发生（`put` 会拒），但如实回报。 */
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
    match (keyRefBuiltinName(ref)) {
        case Some(name) =>
            /*
             * ★ 先区分"到期"与"常量缺失"：到期是**预期行为**（评审窗口结束），
             *   必须说清到期日和替代做法，否则运维会去查"版本对不对"，方向就错了。
             */
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
    let (can, why) = aiCanCall(o)
    if (!can) { let r = AiCallResult(); r.reason = why; return r }
    aiGate(o.maxConcurrent).acquire()
    /*
     * ★★ 2026-10-17（评审 P2-8）：**全链路硬上限**，包含 connect 阶段。
     *
     * 评审原话是"ai_call 无重试/无 connectTimeout"。connectTimeout 这一半
     * **本版本框架给不了** —— 我把 `stdx.net.http.cjo` 的符号表扫过一遍核实：
     * `readTimeout`/`writeTimeout` 各 107 次，`connectTimeout`/`connect_timeout`
     * **0 次**（见本文件下方 429 行附近的说明）。所以"连一个不可达地址"
     * 这段时长原本只能由操作系统 TCP 超时决定（本机实测约 21 秒）。
     *
     * ⇒ 既然框架不提供分阶段的 connect 超时，就用**墙钟期限**兜住整条链路：
     *   把调用放进 worker，主线程 `Future.get(o.timeout_secs)` 到点就**如实降级**
     *   （`source = "rules"` + 说明原因），不等那个卡住的连接。
     *   这是"用总期限覆盖 connect"的等价做法，而且比假承诺一个不存在的
     *   `connectTimeout` 更诚实 —— 后者会让运维以为超时是分阶段生效的。
     *
     * ⚠ 代价要说清：`Future` 超时**不会取消**底层 TCP 连接，worker 仍会把
     *   请求跑完再退出（这是预算路径 `aiCallChatBudget` 早就接受的取舍）。
     *   残留任务数受 `ai.max_concurrent` 闸门约束 —— **许可由 worker 退出时归还**，
     *   所以最多"漏"出 maxConcurrent 个僵尸线程，不会无界增长。
     */
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
        /*
         * ★★ 2026-10-17 复查：这里原来**只有**一个 catch，把所有异常都写成
         *   "超过 Ns 全链路上限"。于是一个"响应解析失败/worker 内抛异常"会被
         *   报成超时 —— 运维按超时去查网络，真因却在别处。
         *   现在超时与非超时分开：非超时**带上真实异常信息**。
         */
        let r = AiCallResult()
        r.reason = "模型调用执行失败（不是超时）：${e.message}，已降级为规则"
        return r
    }
}

/*
 * 分诊模型的剩余等待预算。先非阻塞取共享许可，再启动纯网络任务。
 * Future 超时不会取消系统TCP连接：许可由worker在实际退出时归还，因此残留
 * 任务数量仍有上限，满载即降级。worker不持有请求数据库/结论对象，迟到结果丢弃。
 * Future.get(Duration) 的时限涵盖DNS/connect/读写/解析，并非仅readTimeout。
 */
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

/*
 * ★ 2026-10-17（评审 P2-8）：**有界重试**。
 *
 * 为什么需要：评审指出"网络抖动一次就直接降级"，而患者的就医路径上
 *   一次 502 或一次握手中断就足以让"智能分诊"当场消失。云模型侧 429（限流）
 *   与 5xx（网关抖动）都是**等一下就好**的形态。
 *
 * ⚠ 重试的边界（比"多试几次"重要 —— 无界/无条件重试会把一次故障放大成
 *   对服务商的一次小型 DoS，也会把患者请求拖长）：
 *   ① **只重试真的发出去过的请求**（`attempted`）—— 配置错/密钥错重试毫无意义；
 *   ② **只重试瞬时形态**：网络异常（`httpStatus == 0`）、429、5xx。
 *      4xx 里的 400/401/403/404 是**确定的**错误，重试只会浪费一次配额；
 *   ③ **上限 2 次尝试**（= 最多重试 1 次），间隔 200 ms；
 *   ④ 输出的解析/校验失败（`invalidOutput`）**不重试** —— 那不是网络问题，
 *      改 Prompt 才能解决，重试只是把同一个坏输出再取一遍。
 */
public let AI_CALL_MAX_ATTEMPTS: Int64 = 2
public let AI_CALL_RETRY_BACKOFF_MS: Int64 = 200

/* 判断这次失败值不值得再试一次（判据见上方 ①②④）。 */
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
    /* ★ 2026-10-17 复查：内置密钥不得跟着别人的 base_url 发出去（见 ai_builtin.cj）。 */
    let (hostOk, hostWhy) = aiBuiltinKeyHostCheck(o.keyRef, o.endpoint)
    if (!hostOk) {
        r.reason = hostWhy
        return r
    }
    /*
     * 请求体：只发必要字段。
     * ⚠ `stream: false` 是**刻意**的：本项目在服务端**自己不消费流**
     *   （患者侧的 SSE 由我们重新产出）。让模型侧也流式只会让"超时/半截响应"
     *   更难处理，收益为零。
     */
    /*
     * ★ 2026-10-14：补 `temperature`。
     *
     * ⚠ 在这之前，本项目的出站请求体**从不发 temperature** —— 于是"温度"
     *   这件事在服务端根本不存在（`grep -i temperature` 零命中），
     *   而管理台的模型配置页恰恰要按每条配置设它（截图上的 0.30）。
     *   ⇒ 现在它来自**生效的那条模型配置**（见 ai_settings.cj 的 aiRuntimeResolve），
     *     旧 KV 路线下取 `ai.temperature`（默认 0.30）。
     */
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
        /*
         * ★★ 出站并发闸（`ai.max_concurrent`）——2026-10-09 补。
         * ⚠ 复查发现这个旋钮**被校验、被存库、被回显，却没有任何地方消费**。
         *   ⚠ 口径边界：容量取**启动后首次出站**时配置的值（仓颉没有运行时改信号量容量），
         *     已写进 `ai_settings.cj` 的说明与 `ai-live-check`。
         */
        // 并发许可由外层持有，本函数不能再次获取。
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
        /* ★ 2026-10-17（P2-8）：从这一行起才算"真的发出去过"，重试只看这个标记。 */
        r.attempted = true
        let resp = c.send(req)
        let status = Int64(resp.status)
        let body = aiReadAll(resp.body)
        r.elapsedMs = aiNowMs() - t0
        r.httpStatus = status
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
        } finally {
            c.close()
        }
    } catch (e: Exception) {
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

/*
 * 执行一次调用，遇到**瞬时**失败按 `AI_CALL_MAX_ATTEMPTS` 重试。
 *
 * ⚠ 重试间隔用 `sleep`：这里是**网络任务线程**（调用方在 `aiCallChat` 里
 *   已经用 worker 隔离），睡 200 ms 不会阻塞请求线程；但**绝不能在持锁区**里睡
 *   （本函数不持任何锁）。
 * ⚠ 最后一次尝试的结果**原样返回**，只在 `reason` 前加一个可数的重试标记 ——
 *   否则运维看到的是"第 2 次也失败了"这种没法处置的信息，而"重试过几次"
 *   本身是可聚合的运维指标（例如重试率高说明服务商在抖）。
 */
private func aiCallChatRaw(o: AiRuntimeOptions, prompt: String, now: Int64,
                           ioTimeoutSecs!: Int64 = 0, retryBudgetMs!: Int64 = 0): AiCallResult {
    let startMs = aiNowMs()
    var attempt: Int64 = 1
    var r = aiCallChatOnce(o, prompt, now, ioTimeoutSecs: ioTimeoutSecs)
    while (attempt < AI_CALL_MAX_ATTEMPTS && aiCallRetryable(r)) {
        /*
         * ★★ 2026-10-17 复查：**重试不能越过调用方的期限**。
         *   原来首试超时后照样 `sleep 200ms` 再试一次，而主线程的
         *   `Future.get(deadline)` 早就到点了 —— 白烧一次配额，结果还会被丢弃。
         *   现在：预计会用掉一半以上预算就**不重试**，直接如实返回首次失败原因。
         */
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
 *   （项目里记过这条），所以 `if (v is JsonString)` 这类判断不能省。
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

/* ===================== 连通性测试的最小出站调用（2026-10-14 增）===================== */

/*
 * 连通性测试的公共出站段。
 *
 * ⚠ 与 `aiCallChatRaw` **刻意分开**（不是重复代码，是两件事）：
 *   · 正式调用要并发闸、预算控制、降级语义、响应解析；
 *   · 连通性测试**只有一次、短超时、由人触发**，要的是"最快回答能不能连上"。
 *   把两者揉在一起会让正式路径多出一堆"只有测试才用"的分支 ——
 *   而正式路径上的每个分支都是患者可见的风险。
 *
 * ⚠ 相同的是**安全口径**：https 强制、密钥只从引用解析、错误体先脱敏。
 */
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
    /* ★ 2026-10-17 复查：探活也走同一道白名单，否则"测试通过"会骗人。 */
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
            /*
             * ⚠ 这里的 `ok` 只表示**"出站走到 HTTP 2xx"**，不表示"结果可用" ——
             *   形状校验由调用方（aiProbeChat / aiProbeEmbedding）接着做，
             *   它们会把 `ok` 修正回 false 并给出具体原因。
             *   📌 分成两段是为了**不覆盖已有的失败原因**：HTTP 401 的原因
             *     （密钥错）比"响应形状不对"有用得多，不能被后一段冲掉。
             */
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

/*
 * 对话模型的连通性测试：发一条最小的 chat 请求。
 *
 * ⚠ `max_tokens` 取 8（不是 1）：有些兼容实现在 `max_tokens=1` 时会返回
 *   **空内容**，那会让"连通"被判成"异常"（假失败比假成功更费排查时间）。
 * ⚠ 形状仍按**正式路径的同一函数** `aiExtractContent` 判 ——
 *   连通性测试必须验证"我们真正依赖的那个字段拿得到"，
 *   否则会出现"测试通过，正式调用解析失败"。
 */
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

/*
 * 向量模型的连通性测试。
 *
 * ⚠ 响应形状校验**必须在这一层做**：本项目的向量存储是 `kb_chunk.embedding`
 *   里的一串数字，如果连通性测试只看 HTTP 200，就会出现
 *   "测试通过、但回填向量时解析不出数组" —— 那是最难查的一类问题。
 */
public func aiProbeEmbedding(endpoint: String, model: String, keyRef: String,
                             timeoutSecs!: Int64 = 15): AiCallResult {
    let reqBody = JsonObject()
    reqBody.put("model", JsonString(model))
    /*
     * ⚠ `input` 用**数组**（OpenAI 兼容约定；有些实现两种都收，
     *   但数组是两边都认的形状）。内容用最短的非空字符串。
     */
    let inputs = JsonArray()
    inputs.add(JsonString("ping"))
    reqBody.put("input", inputs)
    let r = aiProbePost(endpoint, keyRef, reqBody.toString(), timeoutSecs)
    /*
     * ★★ 2026-10-17 复查：这里原来只判 `httpStatus == 0`（纯传输失败）。
     *   401/403/404 这类**有状态码的真原因**会继续往下走，被"响应不是预期的向量形状"
     *   覆盖掉 —— 排查时看到的是形状问题，实际是密钥/模型名/端点错。
     *   判据改成 `!r.ok`：只要 HTTP 那一层已经失败，就保留它的原因。
     */
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

/*
 * 从 embeddings 响应里取向量维度；形状不符返回 -1。
 *
 * ⚠ 每一层先判类型再取值（`asXxx()` 类型不符会抛异常，本项目记过这条）。
 */
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
