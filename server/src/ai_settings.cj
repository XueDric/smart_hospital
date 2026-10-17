/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 *
 * ===== ai_settings.cj —— P3 AI 能力中心：配置从「命令行参数」到「数据库驱动」=====
 *
 * 对应 brief §2.2 创新点①「数据库驱动的 AI 能力中心（改配置零重启）」
 * 与 §5.3「AI 配置要从命令行参数改成数据库驱动」。
 *
 * ── 本文件存在的**唯一**硬约束：密钥绝不落库 ────────────────────────────────
 *
 *   brief §5.3 原文点名的**安全回归风险**：
 *   「参考系统说『API Key 支持 `env:` 回落、密钥不落库』，而本仓库现在是
 *    `--ai-key-file`…… 改成 DB 驱动时，**把密钥写进库是倒退** ——
 *    建议库里只存引用路径 / `env:` 名，密钥本体仍留文件或环境变量。」
 *
 *   ⇒ 所以本设计里，库里存的是**引用**，形如：
 *        `env:SMART_HOSPITAL_AI_KEY`   —— 从环境变量取
 *        `file:C:\ProgramData\...\ai.key` —— 从文件取
 *     而**密钥本体**永远只在环境变量或文件里。
 *
 *   ⚠⚠ 并且这个约束是**机制性**保证的，不是靠"我们记得别写"：
 *     `AiSettingsRepo.put()` 对 `ai.key_ref` 这一项**拒绝**任何不是
 *     `env:` / `file:` 开头的值（见 `validateKeyRef`）。
 *     所以即使将来有人加了个"把任意键值写进配置"的通用接口，
 *     也不可能把一串裸密钥塞进 `ai.key_ref`。
 *     📌 这是"把纪律做成机制"的又一例（与 ADR-0001 的"范围锁死"同一手法）。
 *
 * ── 当前实现**只到配置层**，不含出站调用 ──────────────────────────────────
 *   本轮**不接真模型**（与分诊/预问诊同一阻塞：Q6 合规评估待决）。
 *   所以这里实现的是"配置能被 DB 驱动、能被热更新、密钥不落库"这套**机制**，
 *   而 `AiRuntimeOptions` 目前**只被读取与校验**，没有被任何出站代码消费。
 *   这一点必须说清 —— 否则"AI 能力中心已完成"会被误读成"AI 已接通"。
 */

package qingzhou

import std.collection.*
import std.sync.*
import stdx.encoding.json.*

/* ===================== 配置项定义（静态白名单）===================== */

/*
 * 一个可配置项。
 *
 * ⚠ 静态白名单（照 `deptRules()` / `aiToolSpecs()` 的纪律）：
 *   **只有这里列出的 key 才能写进配置表** —— 否则任意键会被塞进 KV 表，
 *   变成一个"谁也不知道有什么用、但没人敢删"的垃圾场。
 *   `AiSettingsRepo.put()` 会拒绝未登记的 key。
 */
public class AiSettingSpec {
    public let key: String
    public let label: String
    /* 默认值（库里没有该行时用它）。 */
    public let defaultVal: String
    /* 是否敏感：敏感项的**值**永不出现在任何响应里，只回显"是否已设置"。 */
    public let secret: Bool
    /*
     * ★ 数值范围（min 与 max 同时 > 0 才启用校验）。
     *
     * ⚠⚠ 为什么必须有这两列（第七份复查第 1 条，我已复现）：
     *   原来**只校验 `key_ref`，数值项完全不校验** —— 于是
     *       PUT ai.timeout_secs = abc   -> 200，回显 value=abc
     *   而运行期 `parseInt64Or` 把它**静默换成默认值 30**。
     *   结果：**回显的值 ≠ 生效的值**，而且系统报"配置有效"。
     *   更糟的是它能**掩盖真实故障**：复查实测库里原来是越界的 9999
     *   （正确地给出 enabled=false + 明确理由），把它"改成" abc 之后
     *   **enabled 反而翻成了 true** —— 一个写错的编辑把报警变成了绿灯。
     *
     *   同一张表里 `ai.key_ref` 是**写入即校验**、数值项却"读了才回落"——
     *   **口径不一致**。现在两者都在 `put()` 校验（同一道闸门）。
     */
    public let numMin: Int64
    public let numMax: Int64
    /*
     * ★★ 已登记但**本版本不支持**（2026-10-09 增，第十份复查触发）。
     *
     * ⚠ 为什么需要这一列：复查发现 `ai.ca_bundle_path` **被校验、被存库、被回显，
     *   却没有任何地方消费** —— 管理员设了它，系统回 200，然后**完全忽略**。
     *   我原本打算把它接上，但读 `stdx.net.tls` 的符号后确认：
     *     `TlsClientConfig.certificate` 的类型是
     *       `Option<Tuple<Array<Certificate>, PrivateKey>>`
     *     —— 那是**客户端证书（mTLS）**，**不是信任锚**。
     *     这个版本的 `TlsClientConfig` **没有** CA bundle / 自定义信任库的入口。
     *   ⇒ 所以它**在架构上无法在本版本接线**，不是"我懒得接"。
     *
     * ⇒ 处置（比"接线了但假的"和"静默忽略"都好）：**明确标成不支持**，
     *   任何写入尝试都被 `put()` 拒并给出理由 —— 让"我配了自建 CA"这件事
     *   **在配置那一刻就失败**，而不是等到连不上时去猜。
     *   📌 本仓纪律：**配置项要么真生效，要么明确说它不生效**；
     *     "看起来生效"是最坏的一种（它会把排查引向错误方向）。
     */
    public let unsupported: Bool
    /* 不支持时的**可执行**理由（写清"为什么"与"怎么办"）。 */
    public let unsupportedReason: String

    public init(key: String, label: String, defaultVal: String, secret!: Bool = false,
                numMin!: Int64 = 0, numMax!: Int64 = 0,
                unsupported!: Bool = false, unsupportedReason!: String = "") {
        this.key = key
        this.label = label
        this.defaultVal = defaultVal
        this.secret = secret
        this.numMin = numMin
        this.numMax = numMax
        this.unsupported = unsupported
        this.unsupportedReason = unsupportedReason
    }

    /* 是否是数值项（需要范围校验）。 */
    public func numeric(): Bool {
        return numMin > 0 && numMax > 0
    }
}

/* 配置项 key（写成常量，免得字符串散落各处拼错）。 */
public let SET_AI_ENABLED: String = "ai.enabled"
public let SET_AI_ENDPOINT: String = "ai.endpoint"
public let SET_AI_MODEL: String = "ai.model"
public let SET_AI_TIMEOUT: String = "ai.timeout_secs"
public let SET_AI_MAX_CONCURRENT: String = "ai.max_concurrent"
public let SET_AI_MAX_TOKENS: String = "ai.max_tokens"
public let SET_AI_KEY_REF: String = "ai.key_ref"
public let SET_AI_CA_BUNDLE: String = "ai.ca_bundle_path"

/*
 * ★ 2026-10-15 增（改进 7）：**配置版本号所在的那一行**（保留键）。
 *
 * ⚠⚠ 为什么版本号要"占一行"，而不是"每次改配置把现有行全部 +1"：
 *   验收测试（AC-P3-7 ⑪）当场抓到了后者的问题 ——
 *   `MAX(revision)` 是**从现有行算出来的**，于是：
 *     · 表本来是空的（新部署、或刚被"清空配置"）⇒ 读回兜底值 1；
 *       紧接着写第一项配置 ⇒ 唯一那行 revision 变成 1 ⇒ **还是 1**。
 *       两次读到的版本号一样，可配置**明明变了** ——
 *       这正是版本号唯一的用途（比对两次调用是不是同一套配置），等于没有。
 *     · 更糟的是"删掉最后一项配置"：表被删空 ⇒ `MAX` 归 NULL ⇒
 *       版本号从 N **倒退**回兜底值，历史排障结论会被反向对账。
 *   结论：**版本号不能寄生在"会被删掉的行"上**。
 *
 * ⚠ 为什么不干脆另开一张表：`ai_setting` 的"改配置零重启"靠的是
 *   **单点失效**（`invalidate()`）；多一张表就多一处写入、多一处失效要同步。
 *   而这一行放在同一张表里**不破坏任何读路径** ——
 *   所有回显都按"登记清单"（`aiSettingSpecs()` / `promptSlots()` /
 *   `aiToolToggles()`）遍历，**没有**任何接口裸查 `SELECT k, v`：
 *     `aiSettingsJson()` 只走登记表 ⇒ 保留行天然不出现在管理台。
 *   ⚠ 因此**将来若有人加"列出全部 KV"的接口，必须显式过滤这一行**。
 *
 * ⚠ 键名刻意**不落在** `ai.*` / `prompt.*` / `ai.tool.*` 三个命名空间里：
 *   `aiSettingKeyKnown()` 只认登记表里的键 ⇒ 保留行**通过接口写不进、也删不掉**
 *   （AC-P3-7 ⑪ 对此有断言）。
 */
public let SET_AI_REVISION_ROW: String = "__revision__"

/*
 * 可配置项清单。
 *
 * ⚠ 刻意**收哪些、不收哪些**（可解释，不是照抄命令行参数）：
 *   收：开关 / endpoint / model / 超时 / 并发 / max_tokens / 密钥引用 / CA 路径
 *       —— 这些是"运维想调、且改了应该立刻生效"的。
 *   不收：任何"放行明文 / 跳过 TLS 校验"的开关。
 *       理由：它**不该有"在运行时被改开"的路径** ——
 *       那是把生产环境变成**可被远程关掉 TLS 校验**。
 *       ⚠⚠ 而"由启动参数决定"这条**在本版本并不存在**：
 *       `AiRuntimeOptions.allowPlaintextEndpoint` 恒为 false，`serve` 也没有对应参数。
 *       原来的注释在这里承诺了"只能由启动参数决定"，把人引向一个**不存在的开关**
 *       （第十一份复查照着它去试了）⇒ 已改成如实陈述，见该类上方的完整说明。
 *       📌 这是一条**刻意的遗漏**，不是忘了 —— 写在这里免得将来有人"补齐"。
 */
public func aiSettingSpecs(): Array<AiSettingSpec> {
    return [
        AiSettingSpec(SET_AI_ENABLED, "AI 功能总开关（1/0）", "0"),
        AiSettingSpec(SET_AI_ENDPOINT, "OpenAI 兼容的完整 URL（必须 https://）", ""),
        AiSettingSpec(SET_AI_MODEL, "模型名", ""),
        AiSettingSpec(SET_AI_TIMEOUT, "读/写超时（秒，1..300）", "30", numMin: 1, numMax: 300),
        AiSettingSpec(SET_AI_MAX_CONCURRENT, "出站并发上限（1..64）", "4", numMin: 1, numMax: 64),
        AiSettingSpec(SET_AI_MAX_TOKENS, "max_tokens（64..8192）", "2048", numMin: 64, numMax: 8192),
        /*
         * ★★ 密钥**引用**（不是密钥本身）。secret=true 让它在响应里只回显"是否已设置"。
         *   值必须是 `env:` 或 `file:` 开头 —— 由 validateKeyRef 机制性保证。
         */
        AiSettingSpec(SET_AI_KEY_REF, "密钥**引用**（env:名 或 file:路径；⚠ 不存密钥本体）", "", secret: true),
        /*
         * ⚠⚠ **本版本不支持**（第十份复查发现它"被校验、被存库、被回显，却没人消费"）。
         *
         * 我查过为什么接不上：`TlsClientConfig.certificate` 的类型是
         *   `Option<Tuple<Array<Certificate>, PrivateKey>>` —— 那是**客户端证书（mTLS）**，
         * **不是信任锚**。这个版本的 `TlsClientConfig` 没有 CA bundle 入口。
         * ⇒ 与其留一个"看起来生效"的旋钮（会把排查引向错误方向），不如**明确拒绝写入**。
         */
        AiSettingSpec(SET_AI_CA_BUNDLE, "CA bundle 路径（⚠ 本版本不支持：框架未暴露信任锚配置）",
                      "", unsupported: true,
                      unsupportedReason: "本版本无法生效：stdx 1.1.3.1 的 TlsClientConfig 只支持「客户端证书(mTLS)」，没有自定义信任锚(CA bundle)入口。" +
                          "若需要连自建 CA 的服务，请把该 CA 装进操作系统的信任库，或升级到暴露了信任锚配置的 stdx 版本。")
    ]
}

/*
 * ★ 某个 key 是否"已登记" —— **三类 key 的统一入口**（P3 第二块新增）。
 *
 * 三类各有自己的登记表，但**判断"这个 key 合不合法"只此一处**：
 *   · `ai.*`      → `aiSettingSpecs()`
 *   · `prompt.*`  → `promptSlots()`（在 ai_prompt.cj）
 *   · `ai.tool.*` → `aiToolToggles()`（在 ai_prompt.cj）
 *
 * ⚠ 为什么不把 prompt / tool 也塞进 `aiSettingSpecs()`：
 *   那张表是**静态**的（编译期就定），而 prompt/tool 的 key 是**由各自的
 *   登记表派生出来的**（`prompt.` + 名字）。塞进去要么手写重复项（加一个模板
 *   要改两处 ⇒ 迟早漏），要么就得让 `aiSettingSpecs()` 变成动态拼接
 *   （那它就不再是"可一眼看全的静态白名单"了）。
 *   ⇒ 现在这样：**各自的登记表是唯一真相**，而"合法性判断"收口到这一个函数。
 */
/*
 * 按 key 取配置项定义（找不到返回 None）。
 * ⚠ 存在的理由：`put()` 需要判断"这一项是否**已登记但不支持**"，
 *   而原来的 `aiSettingKeyKnown` 只回答"认不认得" —— 不够。
 */
public func aiSettingSpecOf(key: String): ?AiSettingSpec {
    for (s in aiSettingSpecs()) {
        if (s.key == key) {
            return Some(s)
        }
    }
    return None
}

public func aiSettingKeyKnown(key: String): Bool {
    if (aiSettingDefaultOfRaw(key).isSome()) {
        return true
    }
    if (startsWithAscii(key, "prompt.")) {
        return promptSlotOf(key[7..]).isSome()
    }
    if (startsWithAscii(key, AI_TOOL_KEY_PREFIX)) {
        return aiToolKnown(key[AI_TOOL_KEY_PREFIX.size..])
    }
    return false
}

/*
 * 某 key 的**默认值**（三类通用）。未登记返回空串。
 * ⚠ 空串与"未登记"在这里**不需要区分** —— 未登记的值本来就不该被读到
 *   （`put` 已经挡住了写入），所以读路径给空串是正确的降级。
 */
public func aiSettingDefaultOf(key: String): String {
    match (aiSettingDefaultOfRaw(key)) {
        case Some(d) => return d
        case None => ()
    }
    if (startsWithAscii(key, "prompt.")) {
        // Prompt 的"默认值"就是默认模板（非空），但它由 PromptRepo 负责拼装；
        // 这里返回空串表示"库里没有该行 ⇒ 由 PromptRepo 回落到默认模板"。
        return ""
    }
    if (startsWithAscii(key, AI_TOOL_KEY_PREFIX)) {
        let name = key[AI_TOOL_KEY_PREFIX.size..]
        // 工具未设置 ⇒ 用默认开关（空串表示"没设"，由 aiToolEnabled 处理默认值）
        if (aiToolKnown(name)) {
            return ""
        }
    }
    return ""
}

/*
 * 取某 key 在**静态登记表**里的默认值；未登记返回 None。
 *
 * ⚠ 名字带 `Raw` 是为了区分于 `aiSettingDefaultOf()`（三类通用）：
 *   这个只看 `aiSettingSpecs()`（静态那一类），是 `aiSettingDefaultOf` 的第一层。
 */
public func aiSettingDefaultOfRaw(key: String): ?String {
    for (s in aiSettingSpecs()) {
        if (s.key == key) {
            return Some(s.defaultVal)
        }
    }
    return None
}

/* 兼容性别名：旧调用点用 `aiSettingDefault` 表示"静态表的默认值"。 */
public func aiSettingDefault(key: String): ?String {
    return aiSettingDefaultOfRaw(key)
}

/* 某项是否敏感。 */
public func aiSettingIsSecret(key: String): Bool {
    for (s in aiSettingSpecs()) {
        if (s.key == key) {
            return s.secret
        }
    }
    return false
}

/* ===================== 密钥引用的机制性校验 ===================== */

/*
 * ★★ 校验"密钥引用" —— **这是本项目"密钥不落库"的机制保证**。
 *
 * 允许的形状只有两种：
 *   `env:NAME`      从环境变量取（NAME 非空）
 *   `file:/path`    从文件取（路径非空）
 *
 * 其余**一律拒绝**。这一条挡住的是：有人（或某个将来的通用配置接口）
 * 把一串裸密钥直接写进 `ai.key_ref`。
 *
 * ⚠ 为什么还要拒绝"看起来像密钥"的值（而不是只判断前缀）：
 *   如果只判断前缀，攻击者写 `env:sk-abcdef...` 就能把密钥**存进库里**，
 *   而它同时"满足前缀要求" —— 那就等于绕过了整条约束。
 *   ⇒ 所以 `env:` 后面的名字还要过一遍**环境变量名**的形状检查
 *     （只允许 `A-Z 0-9 _`，且不以数字开头）。`file:` 后面的路径同理
 *     不做内容检查，但**必须像路径**（含分隔符或以盘符/斜杠开头）。
 */
public func validateKeyRef(v: String): String {
    let t = v.trimAscii()
    if (t.size == 0) {
        return ""      // 空 = 不配置（允许，AI 会因此 enabled=false）
    }
    if (startsWithAscii(t.toAsciiLower(), "env:")) {
        let name = t[4..]
        if (name.size == 0) {
            return "env: 后面必须跟环境变量名"
        }
        /*
         * 环境变量名形状：`[A-Za-z_][A-Za-z0-9_]*`
         * ⚠ 必须收紧 —— 否则 `env:sk-abcdef...` 这种"前缀合法但本体是密钥"
         *   的值会被当成环境变量名存进库，等于绕过整条约束。
         */
        let chars = name.toArray()
        var i: Int64 = 0
        while (i < chars.size) {
            let c = Int64(chars[i])
            let isUpper = (c >= 0x41 && c <= 0x5A)
            let isLower = (c >= 0x61 && c <= 0x7A)
            let isDigit = (c >= 0x30 && c <= 0x39)
            let isUnderscore = (c == 0x5F)
            if (i == 0) {
                if (!(isUpper || isLower || isUnderscore)) {
                    return "环境变量名必须以字母或下划线开头（收到的不是合法变量名）"
                }
            } else if (!(isUpper || isLower || isDigit || isUnderscore)) {
                return "环境变量名只能含字母、数字、下划线（收到的不是合法变量名）"
            }
            i = i + 1
        }
        if (name.size > 128) {
            return "环境变量名过长"
        }
        return ""
    }
    if (startsWithAscii(t.toAsciiLower(), "file:")) {
        let p = t[5..]
        if (p.size == 0) {
            return "file: 后面必须跟路径"
        }
        /*
         * 路径形状：含 `/` 或 `\`，或以盘符开头。
         * ⚠ 同样是收紧 —— 一个**不含任何分隔符**的 `file:` 值不可能是真路径，
         *   更可能是一串被误当路径的密钥。
         */
        var looksLikePath = false
        for (ch in p.toArray()) {
            let c = Int64(ch)
            if (c == 0x2F || c == 0x5C) {      // / 或 \
                looksLikePath = true
            }
        }
        if (!looksLikePath && !(p.size > 1 && Int64(p.toArray()[1]) == 0x3A)) {
            return "file: 后面必须是一个**路径**（含 / 或 \\，或以盘符开头）"
        }
        if (p.size > 512) {
            return "路径过长"
        }
        return ""
    }
    return "只接受 `env:变量名` 或 `file:路径` 两种形式 —— " +
           "**密钥本体绝不入库**（brief §5.3）"
}

/* 某引用是否指向环境变量（是则返回变量名）。 */
public func keyRefEnvName(ref: String): ?String {
    if (startsWithAscii(ref.toAsciiLower(), "env:")) {
        return Some(ref[4..])
    }
    return None
}

/* 某引用是否指向文件（是则返回路径）。 */
public func keyRefFilePath(ref: String): ?String {
    if (startsWithAscii(ref.toAsciiLower(), "file:")) {
        return Some(ref[5..])
    }
    return None
}

/* ===================== 运行时配置类型 ===================== */

/*
 * 由**数据库配置**装配出的运行时 AI 选项。
 *
 * ⚠ 为什么不复用搬迁前的 `AiOptions`（搬迁前的 ai_config.cj）：
 *   ① 搬迁前**不参与本仓编译**（`build.ps1` 只编 `server/src` 下的 .cj）——
 *      它是"只读参考"，不是依赖（见根 README 的目录结构说明）。
 *   ② 两者的**来源不同**：搬迁前那份来自命令行参数（含 `--ai-key-file` 路径），
 *      这份来自库里的**引用**（`env:` / `file:`）。硬要同名会让人以为
 *      "改了这里 = 改了搬迁前"，而实际没有任何联动。
 *   ③ 字段也**刻意不同**：这里**没有** `apiKeyFile` —— 密钥引用在装配时才解析，
 *      不混进"路径"字段（见 `AiSettingsRepo.options` 的注释）。
 *
 * ⚠⚠ `allowPlaintextEndpoint` —— **本版本恒为 false，没有任何赋值点。**
 *
 *   2026-10-09 第十一份复查指出：这里原来叫 `insecureTrustAll`，注释写着
 *   「**只能由启动参数置位**」，而 `serve` 的参数里**根本没有那一个**
 *   （只有 `--port` / `--bind` / `--tls-cert` / `--tls-key` / `--tls-files` /
 *   `--dev-auth` / `--prod`）⇒ 于是那个注释把人引向一个**不存在的开关**，
 *   复查者本人就照着它去试了。
 *   这正是本仓反复复抓的那一类：**声称存在的机制没接线**。
 *
 *   ⇒ 处置是**改承诺，不是补齐机制**，两个理由：
 *     ① **名字与用途不符**：`insecureTrustAll` 表达的是「**跳过证书校验**」（TLS 信任），
 *        而它在这里的实际用途是「**允许明文 http**」—— 两件不同的事混在一个字段上。
 *        ⇒ 改名 `allowPlaintextEndpoint`，让名字说清它到底放开什么。
 *     ② **补一个"允许明文"的启动参数 = 新增攻面**，而收益只是"本机跑 Ollama"这类场景。
 *        对一个医疗系统，"本机回环"这个约束**很难在代码里钉死**
 *        （配个别的回环别名、或 DNS 变了，约束就悄悄失效）
 *        ⇒ 不值得为便利换一个**看起来被约束、实际可能没约束住**的开关。
 *
 *   ⚠ **失败方向是安全的**（fail-closed）：恒为 false ⇒ 明文 endpoint 一律被拒，
 *     拿不到"以为放开了其实没放开"的半吊子状态。
 *
 *   📌 将来真要支持明文（例如接本机模型），**必须做成独立的一件事**：
 *     单独的参数 + **只允许回环**的显式校验 + 启动时打醒目警告 + 单独的测试，
 *     而不是复用一个名字指向别处的旧字段。
 */
public class AiRuntimeOptions {
    public var endpoint: String = ""
    public var model: String = ""
    /* 密钥**引用**（env:名 / file:路径），不是密钥本体。 */
    public var keyRef: String = ""
    public var caBundlePath: String = ""
    public var timeoutSecs: Int64 = 30
    public var maxConcurrent: Int64 = 4
    public var maxTokens: Int64 = 2048
    /*
     * ★ 采样温度（2026-10-14 新增，跨端审计之外的产品需求：管理台「AI 模型配置」页
     *   每行都可配温度）。
     *
     * ⚠ 旧口径**根本不发 temperature** —— 也就是"用服务商的默认值"
     *   （OpenAI 兼容协议默认 1.0）。这不是"中性选择"，而是**把决定性交给了别人**：
     *   同一个主诉在两次分诊里可能给出不同的科室排序，而排班/挂号要的是稳定。
     *   ⇒ 现在显式发一个偏保守的 0.7，并允许每行覆盖。
     *   ⚠ 与"温度能否为 0"分开说：0 是合法取值（最确定），**不是**"未配置"。
     *     所以这里用 Float64 而不是"0 表示没设"的 Int64。
     */
    public var temperature: Float64 = 0.7
    /* ⚠ 本版本**恒为 false**（没有任何赋值点，见下方说明）。 */
    public var allowPlaintextEndpoint: Bool = false

    /*
     * ★ 2026-10-15 增（改进 7）：**这一次用的是哪个模型**（排障遥测要带走的事实）。
     *
     * ⚠ 为什么不能等落库时再去查配置：`ai_setting`/`ai_model` 都是**改配置零重启**的，
     *   调用与落库之间可能插进一次管理员改配置 ⇒ 再去查就会把"A 模型的结果"
     *   记成"B 模型"。排障日志最不能容忍的就是"事后看到的事实与当时不同"。
     *
     * ⚠ `modelId = 0` 是**有语义的**：表示"本次走的是 KV 配置（没有 `ai_model` 行）"，
     *   而不是"第 0 号模型"。此时 `modelName` 仍是**当时真的发出去的模型名**
     *   （`o.model`），而不是空串 —— 空串会让排障看不出用的是什么。
     */
    public var modelId: Int64 = 0
    public var modelName: String = ""

    /* 校验结果。 */
    public var enabled: Bool = false
    public var disabledReason: String = ""

    public init() {}
}

/*
 * 校验运行时选项是否自洽（**只读配置，不做出站调用**）。
 *
 * 口径照搬迁前 `aiValidate`（那份不在本仓编译输入里，但**边界条件照抄**，
 * 因为每条边界背后都有一个实测踩出来的理由）：
 *   · endpoint 必须 https://（明文调模型 = 密钥裸奔）。
 *     ⚠ 这里**没有**"启动参数显式放行"这条路 —— 见 `AiRuntimeOptions`
 *       上方关于 `allowPlaintextEndpoint` 的说明（本版本恒为 false，
 *       原来的注释承诺了一个不存在的参数，已改）。
 *   · timeout 1..300（0 = 无限等待；过大在 Duration 乘法处溢出）
 *   · maxConcurrent 1..64（它直达 Semaphore 计数）
 *   · maxTokens 64..8192（过小会截断输出 ⇒ 非法 JSON ⇒ 静默降级）
 *   · keyRef 非空（否则无法认证）
 *
 * ⚠ 与搬迁前**唯一**的差别：这里多了"密钥引用形状"这一道（`validateKeyRef`），
 *   因为本设计的密钥来自引用而不是文件路径。
 */
public func aiRuntimeValidate(o: AiRuntimeOptions): Unit {
    if (o.endpoint.size == 0) {
        o.enabled = false
        o.disabledReason = "未配置 ${SET_AI_ENDPOINT}，AI 功能不可用（其余功能不受影响）"
        return
    }
    if (!o.allowPlaintextEndpoint && !startsWithAscii(o.endpoint.toAsciiLower(), "https://")) {
        o.enabled = false
        /*
         * ⚠ 错误消息必须**说清"本版本没有放行开关"** ——
         *   否则运维会去翻启动参数找一个不存在的选项
         *   （第十一份复查就是这么被上一版注释引偏的）。
         */
        o.disabledReason = "endpoint 必须是 https://（明文调用大模型 = 密钥裸奔）；" +
            "本版本**不提供**明文放行开关，改用 https 或本机反向代理终止 TLS"
        return
    }
    if (o.timeoutSecs <= 0 || o.timeoutSecs > 300) {
        o.enabled = false
        o.disabledReason = "${SET_AI_TIMEOUT} 必须在 1..300 秒之间（0 = 无限等待；过大在 Duration 乘法处会溢出）"
        return
    }
    if (o.model.size == 0) {
        o.enabled = false
        o.disabledReason = "未配置 ${SET_AI_MODEL}（OpenAI 兼容协议里 model 是必填字段）"
        return
    }
    if (o.maxConcurrent < 1 || o.maxConcurrent > 64) {
        o.enabled = false
        o.disabledReason = "${SET_AI_MAX_CONCURRENT} 必须在 1..64 之间（它直达 Semaphore 的计数）"
        return
    }
    if (o.maxTokens < 64 || o.maxTokens > 8192) {
        o.enabled = false
        o.disabledReason = "${SET_AI_MAX_TOKENS} 必须在 64..8192 之间（过小会截断输出、进而静默降级）"
        return
    }
    if (o.keyRef.size == 0) {
        o.enabled = false
        o.disabledReason = "未配置 ${SET_AI_KEY_REF}（必须是 env:名 或 file:路径）"
        return
    }
    let why = validateKeyRef(o.keyRef)
    if (why.size > 0) {
        o.enabled = false
        o.disabledReason = why
        return
    }
    o.enabled = true
    o.disabledReason = ""
}

/*
 * 字符串是否是**纯十进制整数**（可带一个前导负号）。
 *
 * ⚠ 为什么不直接用 `parseInt64Or`：它对垃圾输入返回**兜底值**，
 *   于是 `abc` 与 `-1` 无法区分 —— 而"非数字"与"越界"要给**不同的**拒绝理由
 *   （前者是写错了类型，后者是范围不对）。
 *   搬迁前的 `parseInt64Or` 语义是"尽力解析 + 兜底"，那是**读取**路径该有的宽容；
 *   **写入**路径要的是严格 —— 这正是第七份复查第 1 条的根因。
 */
func aiIsAllDigits(s: String): Bool {
    if (s.size == 0) {
        return false
    }
    let chars = s.toArray()
    var i: Int64 = 0
    /* 允许一个前导负号（范围校验会挡住负数，但"是不是数字"与"在不在范围内"要分开判）。 */
    if (Int64(chars[0]) == 0x2D) {
        i = 1
        if (chars.size == 1) {
            return false      /* 只有一个负号，不是数字 */
        }
    }
    while (i < chars.size) {
        let c = Int64(chars[i])
        if (c < 0x30 || c > 0x39) {
            return false
        }
        i = i + 1
    }
    return true
}

public class AiSettingPutResult {
    public var ok: Bool = false
    /* 非空 = 拒绝原因（可直接给运维看）。 */
    public var rejected: String = ""
}

/* ===================== 仓储（含缓存与失效）===================== */

/*
 * ★★ AI 配置仓储 —— **改配置零重启** 的落点。
 *
 * ── 缓存策略（照参考系统"配置外置 + 缓存失效"的本质，brief §2.2 创新点①）──
 *   读走**内存缓存**（避免每个请求都查库），写**主动失效**缓存。
 *   所以"改配置零重启"= 写库 → 清缓存 → 下一次读拿到新值。
 *
 * ⚠ 缓存有效期（TTL）也要有：多实例部署时，别的实例不会收到本实例的失效通知，
 *   只能靠 TTL 过期来收敛。本机单实例下 TTL 不会触发，但**不能因此不写** ——
 *   那会让"将来上多实例"变成一个静默的正确性缺陷（配置不一致且无人知道）。
 *   5 秒是"够快收敛"与"别把库打爆"的折中。
 */
public let AI_SETTINGS_CACHE_TTL_SECS: Int64 = 5

public class AiSettingsRepo {
    private let db: DbBackend
    /* 可重入：get 在仓储锁内调用 reload；锁序为仓储锁 → 数据库连接锁。
     * 写操作释放数据库连接锁后才 invalidate，不持有连接锁反向获取仓储锁。
     */
    private let cacheLock = Mutex()
    /* 缓存：所有项的 key→value。`cacheAt = 0` 表示未加载/已失效。 */
    private var cache: HashMap<String, String> = HashMap<String, String>()
    private var cacheAt: Int64 = 0
    /*
     * ★ 多模型配置（`ai_model` 表，见 `ai_model.cj`）的**可选**装配点。
     *
     *   `None` ⇒ 完全走旧口径（只有 KV 里的 `ai.endpoint` / `ai.model`）。
     *   为什么做成可选而不是构造参数：
     *     · 这个仓储的**单元测试与 `ai_settings` 的老用例**只关心 KV 语义，
     *       不该被迫先造一张 `ai_model` 表；
     *     · 让"没接模型表"成为一个**合法状态**（而不是崩溃），
     *       这样"迁移期只有 KV"与"已经建了模型表"两条路都能跑。
     *   ⚠ 反过来，**不能**在 `options()` 里 `models.getOrThrow()` ——
     *     那会把"没接"变成运行期崩溃，而不是"回落到 KV"。
     */
    private var models: ?AiModelRepo = None

    public init(db: DbBackend) {
        this.db = db
    }

    /* 接上模型表（`main.cj` 里构造完两个仓储后调用一次）。 */
    public func attachModels(m: AiModelRepo): Unit {
        models = Some(m)
    }

    /*
     * 读某项配置：**优先取库里的值**，库里没有该行则用默认值。
     *
     * ⚠ "库里没有该行"与"库里存了空串"是**两回事**：
     *   前者 ⇒ 用默认值；后者 ⇒ 就是空（例如把 endpoint 清空 = 停用 AI）。
     *   混起来会让"想清空某项"做不到（一清空就回落到默认值）。
     *
     * ⚠⚠ **但这个区分只对"字符串项"成立，对"数值项"不成立**（第七份复查补充，
     *   我认同并已加断言）：
     *   · 对 `ai.endpoint`：空串是**有意义的取值**（= 停用 AI）⇒ 区分成立；
     *   · 对 `ai.timeout_secs` 这类：空串经 `parseInt64Or` 又会**变回默认值**
     *     ⇒ "存了空串"与"没这一行"**在效果上无法区分**（都落到默认值）。
     *   所以对数值项，"清空"只能理解为"回到默认值"，不存在"空值"这个第三态。
     *   这不算缺陷（数值项本来就没有"空"这个合法取值），但**口径要说清** ——
     *   否则会有人以为"清空 timeout 就能让它无效"。
     *
     *   另：`put()` 现在把值 **trim 后入库**，所以 `"   "` 与 `""` 等价，
     *   两者都落回默认值，回显也一致（见 `aiSettingsJson` 里回显生效值的说明）。
     */
    public func get(key: String, now: Int64): String {
        synchronized(cacheLock) {
            if (cacheAt == 0 || now - cacheAt > AI_SETTINGS_CACHE_TTL_SECS) {
                reload(now)
            }
            if (cache.contains(key)) {
                return cache[key]
            }
            // ⚠ 默认值也 trim：与"写入时 trim"配套，保证任何路径都不带首尾空白
            return aiSettingDefaultOf(key).trimAscii()
        }
    }

    /* 重新加载全部配置到缓存。 */
    public func reload(now: Int64): Unit {
        synchronized(cacheLock) {
            let fresh = HashMap<String, String>()
            let rs = db.query("SELECT k, v FROM ai_setting", Array<DbValue>())
            var i: Int64 = 0
            while (i < rs.rowCount()) {
                fresh[rs.getString(i, 0)] = rs.getString(i, 1)
                i = i + 1
            }
            cache = fresh
            cacheAt = now
        }
    }

    /*
     * ★ 主动失效缓存。写入后**必须**调用 —— 这就是"改配置零重启"的全部机制。
     *
     * ⚠ 把 `cacheAt` 置 0 而不是"直接把新值塞进缓存"：
     *   后者在多实例/并发写下容易与库不一致（本实例以为写成功了，
     *   实际别的实例又改了库）。置 0 = "下次读重新查库"，**永远以库为准**。
     */
    public func invalidate(): Unit {
        synchronized(cacheLock) {
            cacheAt = 0
        }
    }

    /* 写某项配置（含**未登记 key 拒绝**与**密钥引用校验**两道闸门）。 */
    public func put(key: String, value: String, now: Int64): AiSettingPutResult {        let r = AiSettingPutResult()
        /*
         * 闸门①：必须是"**已登记**"的 key（否则 KV 表会变垃圾场）。
         *
         * ⚠ 这里有三类合法 key（同一张表、同一套缓存，靠**前缀**做命名空间）：
         *   · `ai.*`      —— 静态登记表里的项（`aiSettingSpecs()`）
         *   · `prompt.*`  —— Prompt 模板（登记表在 `promptSlots()`）
         *   · `ai.tool.*` —— AI 工具开关（登记表在 `aiToolToggles()`）
         *   三类各自有登记表 ⇒ 都"有名单可查"，不是任意键。
         *   📌 复用同一张 KV 表 + 同一套缓存失效，是为了**不把"失效逻辑"写第二遍**
         *     （"同一语义只留一处"）。
         */
        if (!aiSettingKeyKnown(key)) {
            r.rejected = "未知的配置项：${key}（只有登记过的 key 才能写）"
            return r
        }
        /*
         * ★★ 闸门①之二：**已登记但本版本不支持**的项 —— 拒绝写入并给出理由。
         *
         * ⚠ 为什么连"写"都要拒（而不是允许写、运行期忽略）：
         *   复查实测这个旋钮的行为是「写入 200 → 回显正常 → **完全没人消费**」。
         *   那是最坏的一类失败：使用者**以为配置生效了**，排查方向于是全错
         *   （去查网络、查证书链，而事实是"这个开关根本没接线"）。
         *   ⇒ 让它在**写入那一刻**失败，并说清「为什么」与「怎么办」。
         */
        match (aiSettingSpecOf(key)) {
            case Some(s) =>
                if (s.unsupported) {
                    r.rejected = "配置项 ${key} 在本版本**不支持**（不会生效，故拒绝写入）：${s.unsupportedReason}"
                    return r
                }
            case None => ()
        }
        // 闸门②：★★ 密钥引用必须过形状校验 —— 这是"密钥不落库"的机制保证
        if (key == SET_AI_KEY_REF) {
            let why = validateKeyRef(value)
            if (why.size > 0) {
                r.rejected = why
                return r
            }
        }
        /*
         * 闸门③：★ 数值项必须**写入即校验**（第七份复查第 1 条）。
         *
         * 与闸门② 同一条纪律：**能在写入时判定的错，就不要留到读取时静默回落**。
         * 回落会让"回显的值"与"生效的值"不一致，而且系统报"配置有效" ——
         * 那种不一致比直接报错难查得多。
         *
         * ⚠ 空值（或全空白）是**例外，且被明确接受**：它表示"回到默认值"
         *   （与 `remove` 等价的效果）。这个例外必须显式写出来 ——
         *   否则"想清空某项"会变成一个 400，用户只能删行才能清空。
         */
        let trimmed = value.trimAscii()
        var spec: ?AiSettingSpec = None
        for (s in aiSettingSpecs()) {
            if (s.key == key) {
                spec = Some(s)
            }
        }
        /*
         * ⚠ 只有**静态登记项**才做数值校验：Prompt 模板与工具开关走各自的闸门
         *   （`PromptRepo.put()` 校验占位符与长度；`aiToolSet` 只接受 0/1）。
         *   把数值校验也套到它们身上会误拒（一个模板当然不是数字）。
         */
        if (spec.isSome() && spec.getOrThrow().numeric() && trimmed.size > 0) {
            let sp = spec.getOrThrow()
            if (!aiIsAllDigits(trimmed)) {
                r.rejected = "${key} 必须是整数（收到的是非数字；" +
                             "允许范围 ${sp.numMin}..${sp.numMax}）"
                return r
            }
            let n = parseInt64Or(trimmed, -1)
            if (n < sp.numMin || n > sp.numMax) {
                r.rejected = "${key} 必须在 ${sp.numMin}..${sp.numMax} 之间（收到 ${n}）"
                return r
            }
        }
        /*
         * ★ 存**trim 后**的值（第七份复查第 1 条的连带修正）。
         *
         * 原实现把原始值（可能是 "   "）原样写库，于是：
         *   回显 "   "（3 个空格），而生效值是默认值 30
         *   ⇒ **又一次"回显 ≠ 生效"** —— 与复查指出的那个缺陷同一个病，
         *     只是入口从"非数字"换成了"全空白"。
         *   我是被自己写的断言（"回显与生效仍一致"）抓出来的。
         *
         * trim 后：`"   "` 与 `""` 等价 ⇒ 老实回到默认值，两边一致。
         */
        let stored = trimmed
        db.exec("INSERT INTO ai_setting (k, v, updated_at) VALUES (?, ?, ?) " +
                "ON DUPLICATE KEY UPDATE v = VALUES(v), updated_at = VALUES(updated_at)",
                [DbStr(key), DbStr(stored), DbInt(now)])
        /*
         * ★ 2026-10-15（改进 7）：**每次写入把版本号推进一格**。
         *   实现全部在 `bumpRevision()` 里（含"为什么不是整表 +1"的说明 ——
         *   那个写法被 AC-P3-7 ⑪ 当场证明会丢格）。
         */
        bumpRevision(now)
        invalidate()
        r.ok = true
        return r
    }

    /*
     * ★ 2026-10-15 增（改进 7）：**把配置版本号推进一格**。
     *
     * ── 语义（一句话）────────────────────────────────────────────────────────
     *   "配置变了一次" ⇒ 版本号 +1。写入、删除**都算**变（删除会让生效值从
     *   "设过的值"跳回默认值，在排障视角就是一次配置变更）。
     *
     * ── 为什么是"一个保留行上的计数器"，而不是别的写法 ──────────────────────
     *   ① **不是"现有行全部 +1"**（最初的写法）：版本号寄生在"会被删掉的行"上，
     *      于是空表读回兜底值、写第一项后还是同一个值（**配置变了而版本没变**），
     *      删掉最后一项还会让版本号**倒退**。AC-P3-7 ⑪ 把这两种情况都钉住了。
     *   ② **不是"先读 MAX 再写"**：并发下两个管理员各读到 N、各写 N+1
     *      ⇒ 配置变了两次而版本只动一格。而 `ON DUPLICATE KEY UPDATE ... + 1`
     *      是**库内自增**，不依赖本进程读到的值 ⇒ 不丢格。
     *   ③ **不是另开一张表**：那样"写配置"就有两处写、两处要失效缓存。
     *
     * ⚠ 保留行的键 `SET_AI_REVISION_ROW` 不在 `ai.*` / `prompt.*` / `ai.tool.*`
     *   三个命名空间里 ⇒ 接口既写不进也删不掉（`aiSettingKeyKnown()` 不认它）。
     * ⚠ 保留行**不出现在任何回显**里：回显都按登记清单遍历，没人裸查 KV（详见
     *   `SET_AI_REVISION_ROW` 的注释 —— 含"将来加裸查接口要过滤它"的提醒）。
     * ⚠ 保留行的 `v` 存空串：它**不是配置项**，不该有值。
     */
    private func bumpRevision(now: Int64): Unit {
        /*
         * 一句 `INSERT ... ON DUPLICATE KEY UPDATE` 同时管两种情况：
         *   · 保留行不存在 ⇒ 插进去，revision = 1（第一版配置）；
         *   · 已存在      ⇒ 库内自增，不读回内存（并发下不丢格）。
         * ⚠ 并发首插：两条语句同时插同一主键 ⇒ 输的那条落到 `UPDATE` 分支、
         *   照样 +1 ⇒ **两次变更记两格**，不会并成一格。
         */
        let _ = db.exec(
            "INSERT INTO ai_setting (k, v, updated_at, revision) VALUES (?, '', ?, 1) " +
            "ON DUPLICATE KEY UPDATE revision = revision + 1, updated_at = VALUES(updated_at)",
            [DbStr(SET_AI_REVISION_ROW), DbInt(now)])
    }

    /* 删某项配置（回到默认值）。 */
    public func remove(key: String, now: Int64): Bool {
        if (!aiSettingKeyKnown(key)) {
            return false
        }
        /*
         * ★ 2026-10-15（改进 7）：删除也是**改配置**，同样推进版本号。
         *   ⚠ 不能"删了就完了"：删掉一项会让生效值从"设过的值"跳回默认值，
         *     在排障视角这就是**一次配置变更**（"那天开始模型变成默认的了"）。
         *   ⚠ 版本号记在**保留行**上（见 `bumpRevision`），所以"删掉最后一项配置"
         *     也不会把版本号一起删掉 —— 这正是最初"整表 +1"写法栽的地方。
         */
        let _ = db.exec("DELETE FROM ai_setting WHERE k = ?", [DbStr(key)])
        bumpRevision(now)
        invalidate()
        return true
    }

    /*
     * ★ 2026-10-15 增（改进 7）：**当前配置版本号**。
     *
     * ⚠ 读用 `MAX(revision)`：版本号实际只由**保留行**持有（`bumpRevision`），
     *   普通配置行的 `revision` 保持 0，所以取最大值就是取保留行的值。
     *   这样读的好处是**表里一行都没有时也不会读错**（回 0 = 还没有任何配置）。
     *
     * ⚠ 「还没有任何配置」用 **0** 表达，不是 1：
     *   0 的含义是"这套部署还没写过配置"（出厂状态），排障时看到 0
     *   应当理解为"当时用的是默认值"。若兜底成 1，就会与"第一次改配置后"
     *   的版本号撞在一起 —— 配置变了而版本号没变，版本号就白记了
     *   （AC-P3-7 ⑪ 钉住了这条）。
     *
     * ⚠ 不要指望它在**并发写入的瞬间**精确：它是"事后比对两次调用是不是同一套
     *   配置"用的，不是事务隔离级别。
     */
    public func revision(now: Int64): Int64 {
        /*
         * ⚠⚠ **必须自己 try/catch**（2026-10-16 复核 D1）：
         *   本函数的调用点之一是 `http_app.cj` 的分诊路由 ——
         *   `triageStat.record(..., promptRevision: aiSettings.revision(hNowEpoch()))`
         *   是**具名实参**，它在**调用点**求值、早于 `record()` 的函数体，
         *   所以 `record()` 里那个"统计失败不影响分诊"的 catch **护不住它**。
         *   库一抖（同一个 `DbBackend`，分诊本身也要读库）就会冒到 `http_common.cj`
         *   的兜底分支，患者拿到 500 而不是分诊结论 —— 恰好违反
         *   `triage_stat.cj` 文件头写的纪律：**统计是旁路**。
         *
         * 回 0 是**语义安全**的兜底：0 在 `prompt_revision` 里的含义本来就是
         * "这套部署还没写过配置 / 读不到"，排障时不会把它误读成某个真实版本。
         */
        try {
            let rs = db.query("SELECT IFNULL(MAX(revision), 0) FROM ai_setting", Array<DbValue>())
            if (rs.rowCount() > 0) {
                return rs.getInt(0, 0)
            }
            return 0
        } catch (e: Exception) {
            println("[WARN] 读配置版本号失败（不影响分诊结论）：${e.message}")
            return 0
        }
    }

    /*
     * ★ 把配置装配成 `AiRuntimeOptions` 并校验（复用搬迁前的 `aiRuntimeValidate` 口径）。
     *
     * ⚠ 这一步**只读配置、不做任何出站调用** —— 它回答"配置是否自洽"，
     *   不回答"模型是否可达"。后者要等接上模型才知道。
     */
    public func options(now: Int64): AiRuntimeOptions {
        let o = AiRuntimeOptions()
        o.endpoint = get(SET_AI_ENDPOINT, now).trimAscii()
        o.model = get(SET_AI_MODEL, now).trimAscii()
        /*
         * ★ 2026-10-15（改进 7）：先记下"KV 口径下的模型名"，再由默认模型行覆盖。
         *   ⚠ 默认值取 `o.model` 而不是空串：即便走的是 KV 配置（没有 `ai_model` 行），
         *     排障也必须看得出**当时真的发出去的模型名**是什么。
         *     `modelId` 保持 0 —— 那是"没有模型行"的**语义**，不是缺省。
         */
        o.modelName = o.model
        o.timeoutSecs = parseInt64Or(get(SET_AI_TIMEOUT, now), 30)
        o.maxConcurrent = parseInt64Or(get(SET_AI_MAX_CONCURRENT, now), 4)
        o.maxTokens = parseInt64Or(get(SET_AI_MAX_TOKENS, now), 2048)
        o.caBundlePath = get(SET_AI_CA_BUNDLE, now).trimAscii()
        o.keyRef = get(SET_AI_KEY_REF, now).trimAscii()
        /*
         * ⚠ 密钥引用**不进 AiRuntimeOptions.apiKeyFile** —— 它是引用不是路径。
         *   保留 `apiKeyFile` 语义单纯（真路径），引用在装配时才解析。
         *   这样"库里存引用、本体在环境/文件"这条边界在类型上就不会被混。
         */
        let masterOn = get(SET_AI_ENABLED, now).trimAscii() == "1"
        /*
         * ★★ 新口径优先：`ai_model` 里"默认对话模型"那一行**整体覆盖** KV 的
         *     endpoint / model / key_ref / temperature / max_tokens。
         *
         *   ⚠ 覆盖（而不是"逐字段择优合并"）是有意为之：
         *     一行模型配置 = 该模型的事实全集。如果按字段分别取"新表有就用新的、
         *     没有就用旧的"，就会出现"新表填了 base_url、旧表填了另一个 model"
         *     这种**两个来源拼出来的模型** —— 排查时没人知道请求到底发给了谁。
         *     语义要能一句话说清：「有默认行就全用它，没有才全用 KV」。
         *
         *   ⚠⚠ 唯一**不**覆盖的是 `key_ref` 为空的情形：空 = "这一行没自带密钥，
         *     用全局那把"（`ai_model` 的写入校验允许留空，见 `aiModelValidate`）。
         *     若在这里无脑覆盖成空串，`aiRuntimeValidate` 会报"未配置 key_ref"，
         *     于是"只想给向量模型单独配一把密钥"就变成了"对话模型也用不了"。
         *
         *   ⚠ `base_url` 是**基地址**（如 https://host/compatible-mode/v1），
         *     而 `aiCallChatRaw` 直接把 `o.endpoint` 当**完整请求 URL** 用（:453）
         *     ⇒ 这里必须过 `aiModelRequestUrl` 拼上 `/chat/completions`。
         *     漏了这一步的表现是"连通性测试能过、真实分诊 404"——
         *     因为探针自己拼 URL，两条路走的不是同一个函数。
         */
        match (models) {
            case Some(mr) =>
                match (mr.defaultOf(AI_MODEL_KIND_CHAT, now)) {
                    case Some(m) =>
                        o.endpoint = aiModelRequestUrl(m.baseUrl, AI_MODEL_KIND_CHAT)
                        o.model = m.model
                        /*
                         * ★ 2026-10-15（改进 7）：把"这一行是谁"带走（排障遥测）。
                         *   ⚠ 名字优先用**行名**（`m.name`，管理员起的"通义千问-正式"），
                         *     因为它才是人话；但行名为空时退回 `m.model`
                         *     （否则排障看到空名字，等于没记）。
                         */
                        o.modelId = m.id
                        o.modelName = if (m.name.size > 0) { m.name } else { m.model }
                        if (m.keyRef.size > 0) {
                            o.keyRef = m.keyRef
                        }
                        o.temperature = m.temperature
                        o.maxTokens = m.maxTokens
                    case None => ()
                }
            case None => ()
        }
        aiRuntimeValidate(o)
        if (!masterOn && o.enabled) {
            // 总开关关掉 ⇒ 即使配置自洽也不可用（且理由要说清是**开关**，不是配置错）
            o.enabled = false
            o.disabledReason = "AI 总开关 `${SET_AI_ENABLED}` 为 0（配置本身自洽，但被开关停用）"
        }
        return o
    }
}

/* ===================== 给运维/接口看的视图 ===================== */

/*
 * 配置的**可回显视图**（JSON）。
 *
 * ★★ 安全要点：`secret` 项**只回显"是否已设置"**，绝不回显值本身。
 *   即使是管理员也不回 —— 与"账号接口绝不回 pw_hash"同一条纪律
 *   （见 http_app.cj 里 `/admin/users` 的注释）。
 */
public func aiSettingsJson(repo: AiSettingsRepo, now: Int64): JsonObject {
    let o = JsonObject()
    let items = ArrayList<JsonValue>()
    for (s in aiSettingSpecs()) {
        let e = JsonObject()
        e.put("key", JsonString(s.key))
        e.put("label", JsonString(s.label))
        e.put("secret", JsonBool(s.secret))
        if (s.secret) {
            /*
             * 敏感项：只回"设置了没有" + **引用类型**（env / file / 空）。
             * ⚠ 连变量名/路径都**不回**：路径本身会泄露部署结构
             *   （例如 `C:\ProgramData\smart-hospital\ai.key` 暴露了目录约定）。
             */
            let v = repo.get(s.key, now)
            e.put("set", JsonBool(v.size > 0))
            var kind = ""
            if (keyRefEnvName(v).isSome()) {
                kind = "env"
            } else if (keyRefFilePath(v).isSome()) {
                kind = "file"
            }
            e.put("ref_kind", JsonString(kind))
        } else if (s.key == SET_AI_ENDPOINT) {
            /*
             * ★★ endpoint 是**非秘密项**，但它的**值不能原样回显** ——
             *   有些网关把凭据放在查询串里（`...?api-key=xxx`），
             *   原样回显 = 把凭据写进了响应体与访问日志。
             *
             *   ⚠ 这个漏洞是**测试抓出来的**（AC-P3-4 ②）：我最初把 endpoint
             *     当普通非秘密项、直接回显全值，于是 `?token=SECRET_TOKEN_XYZ`
             *     原封不动出现在回显里。而同一份数据我**在 `aiSafeHost()`
             *     里已经脱敏过一次**（那是给日志用的）—— 两处口径不一致。
             *
             *   📌 又一次"同一件事两处口径"：脱敏必须**只在一处**做，
             *     否则早晚有一处忘了。现在 endpoint 的回显统一走 `aiSafeHost()`。
             */
            let full = repo.get(s.key, now)
            e.put("value", JsonString(aiSafeHost(full)))
            e.put("default", JsonString(s.defaultVal))
            /* 告知"是否被脱敏过"，避免管理员以为配置里真的只存了 host */
            e.put("redacted", JsonBool(full.size > 0 && aiSafeHost(full) != full))
        } else {
            /*
             * ★★ 回显的 value 必须是"**生效值**"，不是"原始存储值"（第七份复查第 1 条）。
             *
             * 原来回显的是 `repo.get()` 的原始值。对**数值项**它与生效值不一致：
             *   · 库里没该行 ⇒ get 返回空串，而生效值是默认值（30）
             *   · 库里是垃圾值 ⇒ 曾出现"回显 abc、生效 30"（现已写入即拒，但空值这条路仍在）
             * ⇒ 回显空串会让管理员以为"这一项没配"，而实际生效的是 30。
             *
             * 现在：**原始值非空就回原始值，为空就回默认值** ——
             * 于是"回显 == 生效"对两种情况都成立。
             * `default` 字段仍然单独给出，方便管理员区分"我设的"与"默认的"。
             */
            let raw = repo.get(s.key, now)
            let shown = if (raw.size > 0) { raw } else { s.defaultVal }
            e.put("value", JsonString(shown))
            e.put("default", JsonString(s.defaultVal))
            /* 告知"这个值是默认来的"（而不是管理员设的） */
            e.put("is_default", JsonBool(raw.size == 0))
        }
        items.add(e)
    }
    o.put("items", JsonArray(items.toArray()))
    /*
     * 生效状态（装配 + 校验后的结论）。
     * ⚠ 只给"能不能用 + 为什么"，不给 endpoint 之外的任何细节；endpoint 也脱敏。
     */
    let opt = repo.options(now)
    o.put("enabled", JsonBool(opt.enabled))
    o.put("disabled_reason", JsonString(opt.disabledReason))
    o.put("endpoint_host", JsonString(aiSafeHost(opt.endpoint)))
    /*
     * ★★ 2026-10-17（S13 修）：把"**真的能调用吗**"拆成可判定的字段。
     *
     * 现场症状：管理台「AI 配置」页显示"已设置"，分诊却每次都静默走规则兜底 ——
     *   因为 `enabled` 只回答"**配置是否自洽**"，不回答"**密钥此刻取不取得到**"。
     *   两者混为一谈时，排查方向会指向"模型不回答"，而真因是"进程里没有那个环境变量"
     *   ——这才是本仓最忌的那类失败（症状与真因对不上）。
     *
     * ⇒ 这里补三个字段：
     *   · `key_ref_kind`   —— `env` / `file` / 空（**不回变量名与路径**，见上方 secret 项的口径）
     *   · `key_resolvable` —— 此刻真去解析一次（读环境变量/读文件）能不能取到
     *   · `model` / `model_id` —— 生效的模型名与模型行 id（排障要知道"到底发给了谁"）
     *
     * ⚠ `key_resolvable` 只在 `enabled` 为真时才有意义（总开关关掉时本就不该调用），
     *   但这里仍然如实给出：运维改完环境变量后**不必重启**就能在页面上看到它变 true，
     *   而 `enabled` 的重算与 `--prod` 校验走的是同一套 `options()`。
     */
    var refKind = ""
    if (keyRefEnvName(opt.keyRef).isSome()) {
        refKind = "env"
    } else if (keyRefFilePath(opt.keyRef).isSome()) {
        refKind = "file"
    }
    o.put("key_ref_kind", JsonString(refKind))
    o.put("key_resolvable", JsonBool(refKind.size > 0 && aiResolveKey(opt.keyRef).isSome()))
    o.put("model", JsonString(opt.modelName))
    o.put("model_id", JsonInt(opt.modelId))
    return o
}

/*
 * 把 endpoint 的**凭据部分**抹掉，保留到路径为止（`scheme://host[:port]/path`）。
 *
 * ⚠ 与搬迁前 `aiHostOnly` 同一个理由：完整 URL 可能含查询串里的凭据
 *   （有些网关把 key 放在 `?api-key=`），打进响应/日志就是泄露。
 *   这里自己实现一份而不是复用搬迁前的：搬迁前那份不在本仓编译输入里，**不参与本仓编译**
 *   （所以这里允许出现这份小重复。）
 *
 * ★★ 2026-10-09 第十一份复查后**改过一次**：原来只返回 `scheme://host`，
 *   **连路径也抹掉** ⇒ 管理员看不到自己配的是哪条路径。
 *   给出的理由是"整条 URL 可能含查询串凭据" —— 那个理由**只支持抹掉查询串**，
 *   不支持抹掉路径（复查也确认：生效值没有被截断，`o.endpoint` 是原样交给 `url(...)`）。
 *
 *   ⚠ 为什么"能看到路径"是**必须**的，而不是讲究：
 *     brief §2.1 第 4 条明确要求**对话模型与向量模型分开配** ——
 *     两者的 endpoint 很可能是**同一个 host 的不同路径**
 *     （`/v1/chat/completions` vs `/v1/embeddings`）。
 *     只回显 host 的话，管理员盯着两个一模一样的 `https://gw.corp` **无法确认**
 *     自己有没有把两条配反 —— 而配反的后果是"检索永远走关键词/模型永远不回答"，
 *     排查方向与真实原因**完全对不上**（这是本仓最忌的那类失败）。
 *     📌 判据：**回显要足以让配置者核对"我配对了没有"**；
 *       抹掉的信息里，只有**凭据**是必须抹的。
 *
 * ⚠ 仍然抹掉的两处（都是**真的**凭据位置）：
 *   · `?query` / `#fragment` —— 网关把 key 放这里很常见
 *   · userinfo（`https://user:pass@host/`）—— 这是最直白的凭据形态
 */
public func aiSafeHost(url: String): String {
    if (url.size == 0) {
        return ""
    }
    let chars = ArrayList<Rune>()
    for (r in url.runes()) {
        chars.add(r)
    }
    let arr = chars.toArray()
    // 找 "://"
    var start: Int64 = 0
    var k: Int64 = 0
    while (k + 2 < arr.size) {
        if (arr[k] == r':' && arr[k + 1] == r'/' && arr[k + 2] == r'/') {
            start = k + 3
            break
        }
        k = k + 1
    }
    /*
     * ★ 抹掉 userinfo：`scheme://` 之后、**第一个 `/`/`?`/`#` 之前**，
     *   若其中含 `@`，则 `@` 及之前全是凭据。
     *   ⚠ 用"第一个 `/`/`?`/`#` 之前的**最后一个** `@`"来定位：
     *     密码本身可能含 `@`（`https://user:p@ss@host/`）⇒ 用第一个 `@` 会切错。
     */
    var hostStart = start
    var scan = start
    var lastAt: Int64 = -1
    while (scan < arr.size) {
        let c = arr[scan]
        if (c == r'/' || c == r'?' || c == r'#') {
            break
        }
        if (c == r'@') {
            lastAt = scan
        }
        scan = scan + 1
    }
    if (lastAt >= 0) {
        hostStart = lastAt + 1
    }
    /*
     * ★★ 终点与拼装：**逐 token 收集**，遇到 `?`/`#` 就停（凭据可能出现的地方）；
     *   **`/` 不停** —— 路径要保留（见上方说明）。
     *
     * ⚠ 2026-10-09 改过一次实现：原来是 `String(arr[0..hostStart]) + String(arr[hostStart..end])`，
     *   本意是"保留 scheme:// 前缀 + host/路径"。但那样**把 userinfo 又拼回来了**——
     *   `arr[0..hostStart]` 里含 `user:pass@` ⇒ 凭据照样进响应。
     *   （AC-P3-4 ② 的五条断言当场抓到：`aiSafeHost` 没抹掉 `pass`。）
     *   📌 教训：**"切一段、再接一段"的脱敏非常容易把刚切掉的东西接回来** ——
     *     凡是"抹掉中间一段"，就**重新拼装**（逐 token 收集），不要用切片拼接。
     */
    let out = ArrayList<Rune>()
    /* 先拼 `scheme://`（`://` 之前的部分原样保留，它不含凭据）。 */
    var p: Int64 = 0
    while (p < start) {
        out.add(arr[p])
        p = p + 1
    }
    /* 再从 host 起拼到终点，跳过 userinfo。 */
    var q = hostStart
    while (q < arr.size) {
        let c = arr[q]
        if (c == r'?' || c == r'#') {
            break
        }
        out.add(c)
        q = q + 1
    }
    var s = ""
    for (r in out.toArray()) {
        s = s + r.toString()
    }
    return s
}
