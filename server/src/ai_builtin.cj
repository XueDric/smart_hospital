package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * ===== ai_builtin.cj —— 内置演示凭据（`builtin:` 引用）=================
 *
 * 2026-10-17 评审整改：评审指出「默认配置下模型一次都不调」——开箱即用这一项
 * 是零分。用户（项目负责人）决定**把默认模型直接写死在代码里接入**，因此本文件
 * 提供第 4 种密钥引用形式 `builtin:demo`：库里仍然只存**引用**（`builtin:demo`），
 * 密钥本体留在代码里，由 `aiResolveKey()` 在出站那一刻取用。
 *
 * ---------------------------------------------------------------------------
 * ## 为什么是"引用"而不是把密钥写进 `ai_setting` 表
 *
 * `ai_settings.cj` 的设计约束是「库里只存引用、机制性拒绝裸密钥」（见该文件头
 * 注释与 `validateKeyRef()`）。直接往 KV 里塞一把 `sk-...` 会：
 *   · 破坏这条不变量 —— 管理台读取、备份、导出都会把密钥带出去；
 *   · 让"密钥是否已设置"的回显逻辑失去意义（`set=true` 变成"库里有明文"）。
 * ⇒ 新增 `builtin:<名字>` 形式：**名字**进库、**本体**在代码。白名单只有
 *   `builtin:demo` 一个，`validateKeyRef()` 会拒掉其它任何名字。
 *
 * ---------------------------------------------------------------------------
 * ## ⚠⚠ 这把密钥是**真的**，且随源码与二进制一起分发
 *
 * 写死即意味着：
 *   · 任何拿到本仓库或 `hospital-server.exe` 的人都能 `strings` 出它；
 *   · 它一旦被公开（push 到公开远端、随分发包发出、贴进答辩截图）就应视为**已泄露**。
 * ⇒ **对外发布前必须轮换**：在 DeepSeek 控制台吊销这把 key、生成新的，
 *   然后把 `AI_BUILTIN_DEMO_KEY` 换成新值（或干脆把 `builtin:demo` 从白名单去掉，
 *   改回 `env:` / `file:` 的正式做法）。
 * ⚠ 刻意**不做**的程度：不写进日志、不回显在 `/api/ai/settings`（那里只回
 *   `ref_kind=builtin`）、不进错误消息 —— 与 env:/file: 两条路径的纪律一致。
 *
 * ## ★ 2026-10-18：加了**有效期**（`AI_BUILTIN_DEMO_VALID_UNTIL`）
 *
 * 负责人选择"保留这把 key 作为实验室/评审窗口用的演示密钥"。既然保留，就把风险
 * 装进机制里：到期后 `aiResolveKey()` 拒绝使用，理由里写明到期日与替代做法。
 * 演示窗口结束仍应去 DeepSeek 控制台**吊销**（日期只防"代码继续用它"，不防
 * "已经流出去的副本"）。详见本文件下方"限时"一节。
 *
 * ## 公开信息（不是秘密）
 *   · endpoint `https://api.deepseek.com/chat/completions`（OpenAI 兼容）
 *   · model    `deepseek-chat`
 *   · 实测 2026-10-17：curl 该 endpoint 返回 200，`usage.total_tokens` 正常计数。
 */

/* 引用前缀。留成常量，避免各处手写字符串漂移。 */
public let AI_BUILTIN_SCHEME: String = "builtin:"

/* 唯一被接受的内置名字。新增内置凭据必须同时加进 `aiBuiltinNames()`。 */
public let AI_BUILTIN_DEMO: String = "demo"

/*
 * ★ 内置演示密钥本体。
 *
 * ⚠ 只有 `aiResolveKey()` 该读它；其它任何地方需要密钥都应先拿到"引用"再解析。
 * ⚠ 不要在这行前后加"打印/校验"性质的调试代码 —— 一行 `println` 就会把密钥
 *   写进日志与答辩录屏。
 */
let AI_BUILTIN_DEMO_KEY: String = "sk-ebd35c9ac7394aa5b7d9847f2a69306d"

/* 与内置凭据配套的默认 endpoint / 模型名（`aiSettingSpecs()` 的默认值取自这里）。 */
public let AI_BUILTIN_DEFAULT_ENDPOINT: String = "https://api.deepseek.com/chat/completions"
public let AI_BUILTIN_DEFAULT_MODEL: String = "deepseek-chat"

/* 默认引用：开箱即用 —— 新建库/未改过配置时 `ai.key_ref` 就是它。 */
public let AI_BUILTIN_DEFAULT_KEY_REF: String = AI_BUILTIN_SCHEME + AI_BUILTIN_DEMO

/* 白名单（`validateKeyRef()` 与 `/api/ai/settings` 的提示共用）。 */
public func aiBuiltinNames(): Array<String> {
    return [AI_BUILTIN_DEMO]
}

/*
 * `builtin:demo` → `demo`；不是 `builtin:` 开头或名字不在白名单 → None。
 *
 * ⚠ 必须比对**白名单**而不是"非空即可" —— 否则 `builtin:` 会变成一个能塞任意
 *   字符串的口子（`builtin:sk-xxx` 就又能把密钥存进库了，正是要防的那件事）。
 */
public func keyRefBuiltinName(ref: String): ?String {
    let t = ref.trimAscii().toAsciiLower()
    /* 整串比对白名单（不做前缀切片）：`builtin:` 后面只允许白名单里的名字。 */
    for (n in aiBuiltinNames()) {
        if (t == AI_BUILTIN_SCHEME + n) {
            return Some(n)
        }
    }
    return None
}

/*
 * `demo` → 密钥本体。名字不在白名单 ⇒ None（调用方按"解析不到"处理）。
 *
 * ⚠ 返回的字符串**不得**被存进任何字段、日志、响应体（同 `aiResolveKey` 的纪律）。
 */
public func aiBuiltinKeyOf(name: String): ?String {
    if (name.trimAscii().toAsciiLower() == AI_BUILTIN_DEMO) {
        return Some(AI_BUILTIN_DEMO_KEY)
    }
    return None
}

/* ===================== 限时：演示密钥的**有效期**（2026-10-18 新增）===================== */

/*
 * ★★ 为什么"内置"必须配一个有效期 —— 以及它到底防住了什么。
 *
 * 写死密钥的真实风险不是"评委看到"，而是**永久可用**：仓库一旦以任何形式流出
 * （截图、录屏、误公开、转发的 zip），那把 key 就一直是活的，谁都能拿去跑自己的
 * 业务。承诺"发布前轮换"没用 —— 承诺不看时间，代码看。
 *
 * ⇒ 把"限时"做成**机制**：到期后 `aiResolveKey()` 直接拒绝这把 key，
 *   `aiKeyRefProblem()` 给出可执行原因（换自己的 env:/file:）。伤害窗口从"永久"
 *   压到"评审窗口"。
 *
 * 它**不能**防住的：窗口期内有人拿走 key 去用。所以这把 key 的余额应当保持很小，
 * 窗口结束后去控制台**吊销**（不是只改这里的日期）。
 *
 * 格式 `YYYY-MM-DD`（与 `hDateStringOf()` 输出同格式）：同格式下**字典序即时间序**，
 * 直接用字符串比较，不需要日期库。想延长/缩短就改这一行 + 重编 + 记 CHANGELOG。
 */
public let AI_BUILTIN_DEMO_VALID_UNTIL: String = "2026-12-31"

/* 该内置名字的有效期（`YYYY-MM-DD`）；没有到期概念的内置凭据返回空串。 */
public func aiBuiltinValidUntil(name: String): String {
    if (name.trimAscii().toAsciiLower() == AI_BUILTIN_DEMO) {
        return AI_BUILTIN_DEMO_VALID_UNTIL
    }
    return ""
}

/*
 * 到期判定（纯函数）。
 *
 * ⚠ `today` 为空（时钟取不到/格式坏了）时**不**判过期：宁可让演示继续可用，
 *   也不要因为一次时钟异常把整条 AI 路径关上 —— 与"密钥解析失败就降级到规则"
 *   同一个取舍方向：演示可用性优先，安全边界靠 `AI_BUILTIN_ALLOWED_HOST` 守。
 */
public func aiBuiltinExpired(name: String, today: String): Bool {
    let until = aiBuiltinValidUntil(name)
    if (until.size == 0) {
        return false
    }
    if (today.size == 0) {
        return false
    }
    return today.trimAscii() > until
}

/*
 * 带"今天"的内置密钥取值：过期即 None（调用方按"解析不到"处理，
 * 具体原因由 `aiKeyRefProblem()` 给 —— 那里能说出到期日与替代方案）。
 */
public func aiBuiltinKeyOfAt(name: String, today: String): ?String {
    if (aiBuiltinExpired(name, today)) {
        return None
    }
    return aiBuiltinKeyOf(name)
}

/*
 * 到期后给人看的**可执行**原因（由 `aiKeyRefProblem()` 直接用，测试也断言它）。
 *
 * 分开成一个函数的原因：这条文案要能**被断言**。如果它藏在 `aiKeyRefProblem()`
 * 里、而后者偷偷读墙上时钟，测试就只能"等真的到期"才能验 —— 那等于没验。
 */
public func aiBuiltinExpiredMessage(name: String): String {
    return "内置演示密钥已于 ${aiBuiltinValidUntil(name)} 失效（`builtin:${name}` 只用于评审/演示窗口）" +
           "—— 请换用自己的密钥：`ai.key_ref=env:DEEPSEEK_API_KEY`（或 `file:路径`），" +
           "一条命令的写法见 `tools/set-ai-key.ps1`"
}

/* ===================== 内置密钥的**出站白名单**（2026-10-17 复查新增）===================== */

/*
 * ★★ 为什么需要这一层。
 *
 * `ai.key_ref = builtin:demo` 是**全局**配置（KV 里那一行），而 `ai_model` 表里
 * 每行都有自己的 `base_url`。当某个模型行**自己没有配 key_ref** 时，运行期会回落到
 * 全局引用 —— 于是 DeepSeek 的密钥会跟着那条 `base_url` 发出去。库里种子的
 * 向量行就指向 `dashscope.aliyuncs.com`：结果是**把一家服务商的密钥送给另一家**
 * （对方只会回 401），既无功能收益，又是一次凭据外泄。
 *
 * ⇒ 内置密钥只允许发往它自己的官方端点；其余一律**拒绝发送**并给出可执行的原因。
 *   `env:` / `file:` 引用不受此限（那把密钥是运维自己放进去的，他有决定权）。
 */
public let AI_BUILTIN_ALLOWED_HOST: String = "api.deepseek.com"

/* 该 `keyRef` 是否是内置引用（只认白名单整串）。 */
public func aiKeyRefIsBuiltin(keyRef: String): Bool {
    return keyRefBuiltinName(keyRef).isSome()
}

/*
 * 这次出站是否允许携带内置密钥。
 * 返回 `(allowed, reason)`：`allowed = false` 时 `reason` 是给人看的一句话。
 */
public func aiBuiltinKeyHostCheck(keyRef: String, url: String): (Bool, String) {
    if (!aiKeyRefIsBuiltin(keyRef)) {
        return (true, "")
    }
    if (url.toAsciiLower().contains(AI_BUILTIN_ALLOWED_HOST)) {
        return (true, "")
    }
    return (false, "内置密钥（${keyRef}）只允许发往 ${AI_BUILTIN_ALLOWED_HOST}；" +
        "当前 base_url 指向别的服务商，已拒绝发送 —— 请为该模型行单独配置 key_ref，或改用官方端点")
}