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

    public init(key: String, label: String, defaultVal: String, secret!: Bool = false) {
        this.key = key
        this.label = label
        this.defaultVal = defaultVal
        this.secret = secret
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
 * 可配置项清单。
 *
 * ⚠ 刻意**收哪些、不收哪些**（可解释，不是照抄命令行参数）：
 *   收：开关 / endpoint / model / 超时 / 并发 / max_tokens / 密钥引用 / CA 路径
 *       —— 这些是"运维想调、且改了应该立刻生效"的。
 *   不收：`insecureTrustAll` —— 它是"仅本机开发跳过证书校验"的危险开关，
 *       **不该有"在运行时被改开"的路径**（那是把生产环境变成可被远程关掉 TLS 校验）。
 *       它只能由**启动参数**决定，且启动时就打醒目警告（照基线口径）。
 *       📌 这是一条**刻意的遗漏**，不是忘了 —— 写在这里免得将来有人"补齐"。
 */
public func aiSettingSpecs(): Array<AiSettingSpec> {
    return [
        AiSettingSpec(SET_AI_ENABLED, "AI 功能总开关（1/0）", "0"),
        AiSettingSpec(SET_AI_ENDPOINT, "OpenAI 兼容的完整 URL（必须 https://）", ""),
        AiSettingSpec(SET_AI_MODEL, "模型名", ""),
        AiSettingSpec(SET_AI_TIMEOUT, "读/写超时（秒，1..300）", "30"),
        AiSettingSpec(SET_AI_MAX_CONCURRENT, "出站并发上限（1..64）", "4"),
        AiSettingSpec(SET_AI_MAX_TOKENS, "max_tokens（64..8192）", "2048"),
        /*
         * ★★ 密钥**引用**（不是密钥本身）。secret=true 让它在响应里只回显"是否已设置"。
         *   值必须是 `env:` 或 `file:` 开头 —— 由 validateKeyRef 机制性保证。
         */
        AiSettingSpec(SET_AI_KEY_REF, "密钥**引用**（env:名 或 file:路径；⚠ 不存密钥本体）", "", secret: true),
        AiSettingSpec(SET_AI_CA_BUNDLE, "CA bundle 路径（PEM）", "")
    ]
}

/* 取某 key 的默认值；key 未登记返回 None。 */
public func aiSettingDefault(key: String): ?String {
    for (s in aiSettingSpecs()) {
        if (s.key == key) {
            return Some(s.defaultVal)
        }
    }
    return None
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
 * ⚠ 为什么不复用基线的 `AiOptions`（`baseline/server/src/ai_config.cj`）：
 *   ① 基线**不参与本仓编译**（`build.ps1` 只编 `server/src` 下的 .cj）——
 *      它是"只读参考"，不是依赖（见根 README 的目录结构说明）。
 *   ② 两者的**来源不同**：基线那份来自命令行参数（含 `--ai-key-file` 路径），
 *      这份来自库里的**引用**（`env:` / `file:`）。硬要同名会让人以为
 *      "改了这里 = 改了基线"，而实际没有任何联动。
 *   ③ 字段也**刻意不同**：这里**没有** `apiKeyFile` —— 密钥引用在装配时才解析，
 *      不混进"路径"字段（见 `AiSettingsRepo.options` 的注释）。
 *
 * ⚠ `insecureTrustAll` 在这里存在，但**只能由启动参数置位**，
 *   **不可**通过配置项修改（见 `aiSettingSpecs()` 的"刻意的遗漏"说明）。
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
    /* ⚠ 仅启动参数可置位；为真时启动打醒目警告。**不可**由库配置改。 */
    public var insecureTrustAll: Bool = false

    /* 校验结果。 */
    public var enabled: Bool = false
    public var disabledReason: String = ""

    public init() {}
}

/*
 * 校验运行时选项是否自洽（**只读配置，不做出站调用**）。
 *
 * 口径照基线 `aiValidate`（那份在 baseline 下不可编译，但**边界条件照抄**，
 * 因为每条边界背后都有一个实测踩出来的理由）：
 *   · endpoint 必须 https://（明文调模型 = 密钥裸奔），除非启动参数显式放行
 *   · timeout 1..300（0 = 无限等待；过大在 Duration 乘法处溢出）
 *   · maxConcurrent 1..64（它直达 Semaphore 计数）
 *   · maxTokens 64..8192（过小会截断输出 ⇒ 非法 JSON ⇒ 静默降级）
 *   · keyRef 非空（否则无法认证）
 *
 * ⚠ 与基线的**唯一差别**：这里多了"密钥引用形状"这一道（`validateKeyRef`），
 *   因为本设计的密钥来自引用而不是文件路径。
 */
public func aiRuntimeValidate(o: AiRuntimeOptions): Unit {
    if (o.endpoint.size == 0) {
        o.enabled = false
        o.disabledReason = "未配置 ${SET_AI_ENDPOINT}，AI 功能不可用（其余功能不受影响）"
        return
    }
    if (!o.insecureTrustAll && !startsWithAscii(o.endpoint.toAsciiLower(), "https://")) {
        o.enabled = false
        o.disabledReason = "endpoint 必须是 https://（明文调用大模型 = 密钥裸奔）"
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

/* ===================== 写入结果 ===================== */

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
    /* 缓存：所有项的 key→value。`cacheAt = 0` 表示未加载/已失效。 */
    private var cache: HashMap<String, String> = HashMap<String, String>()
    private var cacheAt: Int64 = 0

    public init(db: DbBackend) {
        this.db = db
    }

    /*
     * 读某项配置：**优先取库里的值**，库里没有该行则用默认值。
     *
     * ⚠ "库里没有该行"与"库里存了空串"是**两回事**：
     *   前者 ⇒ 用默认值；后者 ⇒ 就是空（例如把 endpoint 清空 = 停用 AI）。
     *   混起来会让"想清空某项"做不到（一清空就回落到默认值）。
     */
    public func get(key: String, now: Int64): String {
        if (cacheAt == 0 || now - cacheAt > AI_SETTINGS_CACHE_TTL_SECS) {
            reload(now)
        }
        if (cache.contains(key)) {
            return cache[key]
        }
        match (aiSettingDefault(key)) {
            case Some(d) => return d
            case None => return ""
        }
    }

    /* 重新加载全部配置到缓存。 */
    public func reload(now: Int64): Unit {
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

    /*
     * ★ 主动失效缓存。写入后**必须**调用 —— 这就是"改配置零重启"的全部机制。
     *
     * ⚠ 把 `cacheAt` 置 0 而不是"直接把新值塞进缓存"：
     *   后者在多实例/并发写下容易与库不一致（本实例以为写成功了，
     *   实际别的实例又改了库）。置 0 = "下次读重新查库"，**永远以库为准**。
     */
    public func invalidate(): Unit {
        cacheAt = 0
    }

    /* 写某项配置（含**未登记 key 拒绝**与**密钥引用校验**两道闸门）。 */
    public func put(key: String, value: String, now: Int64): AiSettingPutResult {
        let r = AiSettingPutResult()
        // 闸门①：必须是登记过的 key（否则 KV 表会变垃圾场）
        if (aiSettingDefault(key).isNone()) {
            r.rejected = "未知的配置项：${key}（只有登记过的 key 才能写）"
            return r
        }
        // 闸门②：★★ 密钥引用必须过形状校验 —— 这是"密钥不落库"的机制保证
        if (key == SET_AI_KEY_REF) {
            let why = validateKeyRef(value)
            if (why.size > 0) {
                r.rejected = why
                return r
            }
        }
        db.exec("INSERT INTO ai_setting (k, v, updated_at) VALUES (?, ?, ?) " +
                "ON DUPLICATE KEY UPDATE v = VALUES(v), updated_at = VALUES(updated_at)",
                [DbStr(key), DbStr(value), DbInt(now)])
        invalidate()
        r.ok = true
        return r
    }

    /* 删某项配置（回到默认值）。 */
    public func remove(key: String, now: Int64): Bool {
        if (aiSettingDefault(key).isNone()) {
            return false
        }
        let _ = db.exec("DELETE FROM ai_setting WHERE k = ?", [DbStr(key)])
        invalidate()
        return true
    }

    /*
     * ★ 把配置装配成 `AiRuntimeOptions` 并校验（复用基线的 `aiRuntimeValidate` 口径）。
     *
     * ⚠ 这一步**只读配置、不做任何出站调用** —— 它回答"配置是否自洽"，
     *   不回答"模型是否可达"。后者要等接上模型才知道。
     */
    public func options(now: Int64): AiRuntimeOptions {
        let o = AiRuntimeOptions()
        o.endpoint = get(SET_AI_ENDPOINT, now).trimAscii()
        o.model = get(SET_AI_MODEL, now).trimAscii()
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
            e.put("value", JsonString(repo.get(s.key, now)))
            e.put("default", JsonString(s.defaultVal))
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
    return o
}

/*
 * 只取 endpoint 的 `scheme://host`（去掉路径与查询串）。
 *
 * ⚠ 与基线 `aiHostOnly` 同一个理由：完整 URL 可能含查询串里的凭据
 *   （有些网关把 key 放在 `?api-key=`），打进响应/日志就是泄露。
 *   这里自己实现一份而不是复用基线的：基线那份在 `baseline/` 下，**不参与本仓编译**
 *   （见 README「基线只读参考」）。所以这是一个**有意的小重复**。
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
    var end = start
    while (end < arr.size) {
        let c = arr[end]
        if (c == r'/' || c == r'?' || c == r'#') {
            break
        }
        end = end + 1
    }
    return String(arr[0..end])
}
