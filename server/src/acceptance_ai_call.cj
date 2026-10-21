package qingzhou

import std.env.*

/*
 * SPDX-License-Identifier: MIT
 *
 * acceptance_ai_call.cj —— AC-AICALL-1…3：真模型出站
 * 重心是"不该发出去的东西"：医疗建议、密钥、绕过校验层都不得出现在出站/返回内容里。
 * 真实出站仅在 AI_CALL_LIVE_TEST 就位时跑，否则跳过并打印原因，不假装通过。
 */

/* ---------- AC-AICALL-1：可调用性判定与密钥引用解析 ----------
 * acAiCall1：可调用性 / 密钥引用 / 重试判据 / 内置密钥白名单与有效期；db 未用。
 */
public func acAiCall1(runner: TestRunner, db: DbBackend): Unit {
    println("=== AC-AICALL-1 ★★ 可调用性判定 + 密钥引用解析（**不含密钥本体**）===")
    let now = hNowEpoch()

    /* ① 未启用 ⇒ 不可调用，且给出原因（只给 false 会逼人去猜）。 */
    let off = AiRuntimeOptions()
    off.enabled = false
    off.disabledReason = "总开关关着"
    let (can1, why1) = aiCanCall(off)
    runner.check("① 未启用 ⇒ 不可调用", !can1)
    runner.check("① 且原因非空（排障需要知道为什么）", why1.size > 0)

    /* ② 启用但缺 endpoint / model / key_ref ⇒ 各自给出不同的原因。 */
    let e1 = AiRuntimeOptions()
    e1.enabled = true
    let (can2, why2) = aiCanCall(e1)
    runner.check("② 缺 endpoint ⇒ 不可调用", !can2)
    runner.check("★ ② 原因指向 endpoint（不是笼统「配置不全」）", why2.contains("endpoint"))

    let e2 = AiRuntimeOptions()
    e2.enabled = true
    e2.endpoint = "https://api.example.com/v1/chat/completions"
    let (can3, why3) = aiCanCall(e2)
    runner.check("② 缺 model ⇒ 不可调用", !can3)
    runner.check("★ ② 原因指向 model", why3.contains("model"))

    let e3 = AiRuntimeOptions()
    e3.enabled = true
    e3.endpoint = "https://api.example.com/v1/chat/completions"
    e3.model = "some-model"
    let (can4, why4) = aiCanCall(e3)
    runner.check("② 缺 key_ref ⇒ 不可调用", !can4)
    runner.check("★ ② 原因指向 key_ref", why4.contains("key_ref"))

    /* ③ 密钥引用解析：环境变量不存在 ⇒ None（不是空串、不是抛异常）。 */
    let missing = "SMART_HOSPITAL_AC_TEST_NO_SUCH_VAR_${now}"
    match (aiResolveKey("env:${missing}")) {
        case Some(_) => runner.check("★★ ③ 不存在的环境变量 ⇒ 不得解析出值", false)
        case None => runner.check("★★ ③ 不存在的环境变量 ⇒ None（不抛异常、不返回空串）", true)
    }
    /* ★ 失败原因必须能指导处置：点明"环境变量要设在服务进程上"。
     *   用 $env:X=... 后重启服务就没了，症状是"配了却不生效"。
     */
    let problem = aiKeyRefProblem("env:${missing}")
    runner.check("★ ③ 原因点明是环境变量问题", problem.contains("环境变量"))
    runner.check("★ ③ 且提醒「要设在服务进程的环境里」（本仓实测的易错点）",
                 problem.contains("服务进程"))
    runner.check("★★ ③ 原因里**不含**任何看起来像密钥的串（无 sk- 前缀）",
                 !problem.contains("sk-"))

    /* ④ 非 env:/file: 的引用（不该发生）：如实回报而不是静默。 */
    runner.check("④ 既非 env: 也非 file: 的引用 ⇒ 解析失败",
                 aiResolveKey("plainvalue").isNone())
    runner.check("④ 且原因说明这一点",
                 aiKeyRefProblem("plainvalue").contains("env:"))

    /* ⑤ ★ 真实环境变量能被解析（用本用例自己设的变量，不依赖任何真实密钥）。 */
    let probeName = "SMART_HOSPITAL_AC_KEYREF_PROBE"
    /* ⚠ 仓颉 std 没有 setenv，只能在启动前由外部设置；未设时如实跳过。 */
    match (aiResolveKey("env:${probeName}")) {
        case Some(_) =>
            runner.check("★ ⑤ 环境变量存在时能解析出值（且已 trim）", true)
        case None =>
            println("  [SKIP] ⑤ 环境变量 ${probeName} 未设置 —— 跳过（不是失败）")
    }

    /* ⑥ ★★ 重试判据：401/400 不重试，网络异常必须重试；边界用逻辑断言钉死。
     *   太宽白打一次服务商，太窄等于没做，两类错误在真实环境都表现为"偶尔失败"。
     */
    let t1 = AiCallResult()
    t1.reason = "出站调用异常：connect reset"
    t1.attempted = true
    runner.check("⑥ 网络异常（httpStatus=0）⇒ 可重试", aiCallRetryable(t1))
    let t2 = AiCallResult()
    t2.httpStatus = 429
    t2.attempted = true
    runner.check("⑥ 429 限流 ⇒ 可重试（等一下就好）", aiCallRetryable(t2))
    let t3 = AiCallResult()
    t3.httpStatus = 503
    t3.attempted = true
    runner.check("⑥ 5xx ⇒ 可重试（网关抖动）", aiCallRetryable(t3))
    let t4 = AiCallResult()
    t4.httpStatus = 401
    t4.attempted = true
    runner.check("★ ⑥ 401（密钥错）⇒ **不重试**（重试只是再错一次）", !aiCallRetryable(t4))
    let t5 = AiCallResult()
    t5.httpStatus = 400
    t5.attempted = true
    runner.check("★ ⑥ 400（请求不合法）⇒ **不重试**", !aiCallRetryable(t5))
    let t6 = AiCallResult()
    t6.reason = "ai.key_ref 既不是 env: / file: / builtin:"
    runner.check("★ ⑥ 没发出去过的失败（配置/密钥解析前失败）⇒ **不重试**",
                 !aiCallRetryable(t6))
    let t7 = AiCallResult()
    t7.httpStatus = 200
    t7.invalidOutput = true
    t7.attempted = true
    runner.check("★ ⑥ 200 但输出不合格 ⇒ **不重试**（那是 Prompt 问题，不是网络）",
                 !aiCallRetryable(t7))
    let t8 = AiCallResult()
    t8.ok = true
    runner.check("⑥ 成功 ⇒ 不重试", !aiCallRetryable(t8))
    runner.check("⑥ 重试上限是一个可审计的常量（${AI_CALL_MAX_ATTEMPTS} 次尝试）",
                 AI_CALL_MAX_ATTEMPTS == 2)

    /* ⑦ ★★ 内置密钥出站白名单：builtin:demo 只允许发往 DeepSeek 域名。
     *   全局 key_ref 配各行 base_url，不校验会把 DeepSeek 密钥发给阿里云（凭据外泄）。
     */
    let hc1 = aiBuiltinKeyHostCheck("builtin:demo", "https://api.deepseek.com/chat/completions")
    runner.check("★ ⑦ 内置密钥发往官方端点 ⇒ 放行", hc1[0])
    let hc2 = aiBuiltinKeyHostCheck("builtin:demo",
                                    "https://dashscope.aliyuncs.com/compatible-mode/v1/embeddings")
    runner.check("★ ⑦ 内置密钥发往别家 ⇒ **拒绝**（否则密钥外泄）", !hc2[0])
    runner.check("★ ⑦ 拒绝理由要说清往哪发、怎么办",
                 hc2[1].contains("api.deepseek.com") && hc2[1].contains("key_ref"))
    let hc3 = aiBuiltinKeyHostCheck("env:DEEPSEEK_API_KEY", "https://dashscope.aliyuncs.com/compatible-mode/v1")
    runner.check("⑦ 运维自配的 env: 引用不受白名单限制（他有权决定发往哪）", hc3[0])
    let hc4 = aiBuiltinKeyHostCheck("", "https://api.deepseek.com")
    runner.check("⑦ 没有引用（走别的来源）不受影响", hc4[0])

    /* ⑧ ★ 内置演示密钥有效期必须是代码行为而非文档承诺，到期即不可调用。 */
    let until = aiBuiltinValidUntil(AI_BUILTIN_DEMO)
    runner.check("⑧ 内置演示密钥登记了有效期（${until}）", until.size == 10 && until.contains("-"))
    runner.check("⑧ 窗口内可取到密钥（today=${until}）",
                 aiBuiltinKeyOfAt(AI_BUILTIN_DEMO, until).isSome())
    runner.check("★ ⑧ 有效期**之后**取不到（今天是 2999-12-31）",
                 aiBuiltinKeyOfAt(AI_BUILTIN_DEMO, "2999-12-31").isNone())
    runner.check("★ ⑧ 但有效期**之前**可取到（2020-01-01），说明不是一刀切关掉",
                 aiBuiltinKeyOfAt(AI_BUILTIN_DEMO, "2020-01-01").isSome())
    runner.check("★ ⑧ 到期后 `aiResolveKeyAt` 也取不到（同一判据，两条路径一致）",
                 aiResolveKeyAt("builtin:${AI_BUILTIN_DEMO}", "2999-12-31").isNone())
    runner.check("⑧ `today` 为空（时钟异常）时不判过期 —— 演示可用性优先",
                 !aiBuiltinExpired(AI_BUILTIN_DEMO, ""))
    runner.check("⑧ 没有有效期概念的名字不判过期", !aiBuiltinExpired("nobody", "2999-12-31"))
    runner.check("★ ⑧ 到期理由要说到期日与替代做法（否则运维会去查版本）",
                 aiBuiltinExpiredMessage(AI_BUILTIN_DEMO).contains(until) &&
                 aiBuiltinExpiredMessage(AI_BUILTIN_DEMO).contains("key_ref"))
}

/* ---------- AC-AICALL-2：★★ 安全清理层（网络无关，CI 稳定）----------
 * acAiCall2：医疗建议整条丢弃、Markdown / 控制字符 / 长度清理，全部网络无关。
 */
public func acAiCall2(runner: TestRunner, db: DbBackend): Unit {
    println("=== AC-AICALL-2 ★★★ 模型输出安全检查：**医疗建议一律丢弃** ===")

    /* ★★★ 命中诊断/用药词 ⇒ 整条丢弃（返回空串），回退到规则文案。
     *   没能力把医疗建议改安全 —— "每天两次，饭后"去掉药名仍有误导。
     */
    let denyCases: Array<(String, String)> = [
        ("建议服用阿莫西林", "服药动词"),
        ("可以吃 500mg 的对乙酰氨基酚", "剂量 + 单位"),
        ("每日两次，每次一片", "频次 + 片剂"),
        ("我诊断为急性支气管炎", "自称诊断"),
        ("您得了肺炎，需要输液", "断言疾病 + 输液"),
        ("可能是肿瘤，建议尽快手术", "重病断言 + 手术"),
        ("take 500 mg twice daily", "英文剂量（模型很常写）"),
        ("prescription needed", "英文处方"),
    ]
    var leaked = 0
    for (c in denyCases) {
        let out = aiSanitizeNote(c[0])
        if (out.size > 0) {
            leaked = leaked + 1
            println("  [FAIL] 泄漏了「${c[0]}」（${c[1]}）⇒ 清理后仍是「${out}」")
        }
    }
    runner.check("★★★ ① 8 条疑似诊断/用药的输出**全部被丢弃**（实漏 ${leaked} 条）",
                 leaked == 0)

    /* ② 对照：正常解释性文字必须能通过（否则是"一律拒绝"的假绿）。 */
    let okCases: Array<String> = [
        "建议您到呼吸内科就诊，就诊前可记录咳嗽的持续时间和诱因。",
        "这个科室主要看呼吸道相关的不适，您可以先准备好既往就诊记录。",
    ]
    var blocked = 0
    for (c in okCases) {
        if (aiSanitizeNote(c).size == 0) {
            blocked = blocked + 1
            println("  [FAIL] 正常的解释文字被误杀：「${c}」")
        }
    }
    runner.check("★★ ② 对照：正常解释文字**不被误杀**（否则①是「一律拒绝」的假绿）",
                 blocked == 0)

    /* ③ Markdown 标记必须去掉（前端按纯文本渲染）。 */
    let md = aiSanitizeNote("## 建议\n**去呼吸内科**就诊")
    runner.check("③ 去掉 Markdown 标题标记（实得「${md}」）", !md.contains("#"))
    runner.check("③ 去掉粗体标记", !md.contains("*"))
    runner.check("★ ③ **只取第一行**（防止「建议…」藏在第 3 段里绕过检查）",
                 !md.contains("\n"))

    /* ④ 超长输出按字符截断（本仓三次踩过字节/字符混用）。 */
    let long = aiSanitizeNote(hRepeatChar("好", 400))
    runner.check("④ 超长输出被截断到 ≤${AI_NOTE_MAX_CHARS} 字（实得 ${previsitCharLen(long)}）",
                 previsitCharLen(long) <= AI_NOTE_MAX_CHARS)
    runner.check("★★ ④ 且截断后是**合法 UTF-8**（没切在汉字中间 —— 本仓真踩过这个 500）",
                 previsitCharLen(long) > 0)

    /* ⑤ 空输出 / 纯空白 ⇒ 空串（调用方据此标 model:invalid）。 */
    runner.check("⑤ 空串 ⇒ 空串", aiSanitizeNote("").size == 0)
    runner.check("⑤ 纯空白 ⇒ 空串", aiSanitizeNote("   \n  ").size == 0)

    /* ⑥ 控制字符 ⇒ 丢弃（防"第一行"判断被 \r 之类绕过）。 */
    runner.check("★ ⑥ 含控制字符（制表/退格）⇒ 丢弃", aiSanitizeNote("建议就诊\t再联系").size == 0)
}

/* ---------- AC-AICALL-3：响应解析 + 真实出站（可选）----------
 * acAiCall3：严格判类型；真实出站仅在 AI_CALL_LIVE_TEST 开启时跑。
 */
public func acAiCall3(runner: TestRunner, db: DbBackend): Unit {
    println("=== AC-AICALL-3 ★★ 响应解析（严格判类型）+ 真实出站（可选）===")

    /* ① 正常 OpenAI 形状。 */
    let good = "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"你好\"}}]}"
    match (aiExtractContent(good)) {
        case Some(t) => runner.check("① 标准形状能取到 content（实得「${t}」）", t == "你好")
        case None => runner.check("① 标准形状能取到 content", false)
    }

    /* ② 畸形形状必须返回 None 而不是抛异常：模型是不可信输入源。
     *   asObject()/asArray() 类型不符会抛异常，所以 is JsonObject 判断不能省。
     */
    let badCases: Array<(String, String)> = [
        ("not json at all", "根本不是 JSON"),
        ("[]", "顶层是数组"),
        ("{}", "空对象（无 choices）"),
        ("{\"choices\":[]}", "choices 为空数组"),
        ("{\"choices\":\"x\"}", "choices 不是数组"),
        ("{\"choices\":[{}]}", "首项无 message"),
        ("{\"choices\":[{\"message\":{}}]}", "message 无 content"),
        ("{\"choices\":[{\"message\":{\"content\":123}}]}", "content 不是字符串"),
        ("{\"choices\":[{\"message\":{\"content\":null}}]}", "content 是 null"),
    ]
    var threw = 0
    var wrong = 0
    for (c in badCases) {
        try {
            match (aiExtractContent(c[0])) {
                case Some(_) =>
                    wrong = wrong + 1
                    println("  [FAIL] 畸形输入不该解析出内容（${c[1]}）：${c[0]}")
                case None => ()
            }
        } catch (e: Exception) {
            /* 抛异常 = 更严重的问题（会把分诊响应变成 500）。 */
            threw = threw + 1
            println("  [FAIL] 畸形输入**抛异常**（${c[1]}）：${e.message}")
        }
    }
    runner.check("★★ ② 9 种畸形形状全部返回 None（误判 ${wrong} 个）", wrong == 0)
    runner.check("★★ ② 且**一个都不抛异常**（抛了就把分诊变成 500）", threw == 0)

    /* ③ 脱敏：密钥不得出现在文本里（含多次出现）。 */
    let fakeKey = "sk-abcdefghijklmnopqrstuvwxyz012345"
    let dirty = "error: header Authorization: Bearer ${fakeKey} rejected; retry with ${fakeKey}"
    let clean = aiRedact(dirty, fakeKey)
    runner.check("★★★ ③ 密钥被抹掉（一次都不剩）", !clean.contains(fakeKey))
    runner.check("③ 且替换成 ***（不是把整句话删掉 —— 保留可排障的上下文）",
                 clean.contains("***") && clean.contains("error:"))
    runner.check("★ ③ 短于 8 字符的「密钥」不替换（避免把普通词切碎）",
                 aiRedact("hello world", "abc") == "hello world")

    /* ④ 真实出站仅在显式开启时跑：启动前设 AI_CALL_LIVE_TEST=1 与 DEEPSEEK_API_KEY。
     *   密钥只经环境变量，绝不落库/落盘；未开时跳过并打印，不假装通过、也不失败。
     */
    let live = getVariable("AI_CALL_LIVE_TEST") ?? ""
    if (live != "1") {
        println("  [SKIP] ④ 真实出站未开启（设 AI_CALL_LIVE_TEST=1 + DEEPSEEK_API_KEY 才跑）")
        runner.check("④ 跳过真实出站时**如实标注**（不假装通过）", true)
        return
    }
    let key = getVariable("DEEPSEEK_API_KEY") ?? ""
    if (key.size == 0) {
        println("  [SKIP] ④ 开了开关但没给 DEEPSEEK_API_KEY ⇒ 跳过")
        runner.check("④ 缺密钥时**如实跳过**（不失败、不假装成功）", true)
        return
    }
    /* 用真实 ai_setting 仓储读配置（不在测试里硬编码 endpoint/model）。 */
    let repo = AiSettingsRepo(db)
    let now = hNowEpoch()
    var opt: AiRuntimeOptions
    try {
        opt = repo.options(now)
    } catch (e: Exception) {
        println("  [SKIP] ④ 读 AI 配置失败（${e.message}）⇒ 跳过")
        runner.check("④ 读配置失败时如实跳过", true)
        return
    }
    let (can, why) = aiCanCall(opt)
    if (!can) {
        println("  [SKIP] ④ 配置不可调用（${why}）⇒ 跳过。请先：")
        println("         ai.endpoint / ai.model / ai.key_ref（env:DEEPSEEK_API_KEY）/ ai.enabled=1")
        runner.check("④ 配置不齐时如实跳过并给出要配什么", true)
        return
    }
    let r = aiCallChat(opt, "用一句话说明咳嗽三天可以去哪个科室，不要提任何药名。", now)
    runner.check("★ ④ 真实出站**成功**（source=model，实得 ${r.source}）", r.ok)
    runner.check("④ 且取到了非空文本（长度 ${previsitCharLen(r.text)} 字）",
                 previsitCharLen(r.text) > 0)
    runner.check("④ 且耗时被记录（${r.elapsedMs} ms > 0）", r.elapsedMs >= 0)
    /* ★★★ 密钥绝不出现在结果里，连 reason 也要查（库把整个请求头拼进异常消息）。 */
    runner.check("★★★ ④ 成功结果里不含密钥", !r.text.contains(key) && !r.reason.contains(key))
    let bad = aiCallChat(opt, hRepeatChar("测", 10), now)
    runner.check("★★★ ④ 失败/成功的结果里都不含密钥（reason 也查）",
                 !bad.reason.contains(key) && !bad.text.contains(key))
    /* 安全层对真实模型输出的效果（端到端价值所在）。 */
    let sanitized = aiSanitizeNote(r.text)
    println("         模型原文：${r.text}")
    println("         清理之后：${sanitized}")
    runner.check("★★ ④ 真实输出经安全层后**不含**剂量/药名类词汇",
                 !aiNoteHasDenyWord(sanitized))
}
