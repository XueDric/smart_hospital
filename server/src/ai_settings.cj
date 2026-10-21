/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 *
 * ===== ai_settings.cj —— AI 能力中心配置：数据库驱动、改配置零重启 =====
 * 写库即清缓存 + 5 s TTL ⇒ 改配置零重启；多实例靠 TTL 收敛。
 * 库里只存引用不存密钥：ai.key_ref 只能是 env:名 / file:路径 / builtin:demo。
 */

package qingzhou

import std.collection.*
import std.sync.*
import stdx.encoding.json.*

/* ===================== 配置项定义（静态白名单）===================== */

/* 一个可配置项。静态白名单：只有这里列出的 key 能写进配置表，put() 拒绝未登记的 key。 */
public class AiSettingSpec {
    public let key: String
    public let label: String
    /* 默认值（库里没有该行时用它）。 */
    public let defaultVal: String
    /* 是否敏感：敏感项的**值**永不出现在任何响应里，只回显"是否已设置"。 */
    public let secret: Bool
    /* 数值范围（min 与 max 同时 > 0 才启用校验）。
     * 必须写入即校验：否则回显 abc、生效 30，回显 ≠ 生效且系统报"配置有效"。 */
    public let numMin: Int64
    public let numMax: Int64
    /* 已登记但本版本不支持（如 ai.ca_bundle_path）。
     * 必须写入即拒并给出理由：TlsClientConfig 没有信任锚入口，接了也是假生效。 */
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

/* 配置版本号所在的那一行（保留键 __revision__）。版本号不能寄生在会被删掉的行上：
 * 否则空表与首次写入同版本、删空最后一项还会让版本倒退。
 * 保留行不在 ai.* / prompt.* / ai.tool.* 命名空间 ⇒ 接口写不进也删不掉。 */
public let SET_AI_REVISION_ROW: String = "__revision__"

/* 可配置项清单。只收"运维想调、改了立刻生效"的项。
 * 禁止收任何"放行明文 / 跳过 TLS 校验"的开关：那等于让生产可被远程关掉 TLS 校验。 */
public func aiSettingSpecs(): Array<AiSettingSpec> {
    return [
        /* 总开关默认 1 并预置 DeepSeek 接入，开箱即用；对外发布前必须复核 Q6 结论。 */
        AiSettingSpec(SET_AI_ENABLED, "AI 功能总开关（1/0；默认 1，开箱即用）", "1"),
        AiSettingSpec(SET_AI_ENDPOINT, "OpenAI 兼容的完整 URL（必须 https://）", AI_BUILTIN_DEFAULT_ENDPOINT),
        AiSettingSpec(SET_AI_MODEL, "模型名", AI_BUILTIN_DEFAULT_MODEL),
        AiSettingSpec(SET_AI_TIMEOUT, "读/写超时（秒，1..300）", "30", numMin: 1, numMax: 300),
        AiSettingSpec(SET_AI_MAX_CONCURRENT, "出站并发上限（1..64）", "4", numMin: 1, numMax: 64),
        AiSettingSpec(SET_AI_MAX_TOKENS, "max_tokens（64..8192）", "2048", numMin: 64, numMax: 8192),
        /* 密钥引用（不是密钥本身）。secret=true ⇒ 响应里只回显"是否已设置"。 */
        AiSettingSpec(SET_AI_KEY_REF,
                      "密钥**引用**（env:名 / file:路径 / builtin:demo（演示密钥有效期至 ${AI_BUILTIN_DEMO_VALID_UNTIL}）；⚠ 不存密钥本体）",
                      AI_BUILTIN_DEFAULT_KEY_REF, secret: true),
        /* 本版本不支持：TlsClientConfig 只支持客户端证书(mTLS)，没有 CA bundle 入口。
         * 与其留一个"看起来生效"的旋钮，不如写入即拒。 */
        AiSettingSpec(SET_AI_CA_BUNDLE, "CA bundle 路径（⚠ 本版本不支持：框架未暴露信任锚配置）",
                      "", unsupported: true,
                      unsupportedReason: "本版本无法生效：stdx 1.1.3.1 的 TlsClientConfig 只支持「客户端证书(mTLS)」，没有自定义信任锚(CA bundle)入口。" +
                          "若需要连自建 CA 的服务，请把该 CA 装进操作系统的信任库，或升级到暴露了信任锚配置的 stdx 版本。")
    ]
}

/* 按 key 取配置项定义（找不到返回 None）。put() 用它判断"已登记但不支持"。 */
public func aiSettingSpecOf(key: String): ?AiSettingSpec {
    for (s in aiSettingSpecs()) {
        if (s.key == key) {
            return Some(s)
        }
    }
    return None
}

/* 三类 key（ai.* / prompt.* / ai.tool.*）各有登记表，合法性判断只此一处。 */
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

/* 某 key 的默认值（三类通用）；未登记返回空串，读路径降级为空是正确的。 */
public func aiSettingDefaultOf(key: String): String {
    match (aiSettingDefaultOfRaw(key)) {
        case Some(d) => return d
        case None => ()
    }
    if (startsWithAscii(key, "prompt.")) {
        // Prompt 的默认模板由 PromptRepo 拼装；空串表示"库里没有 ⇒ 回落默认模板"。
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

/* 取静态登记表里的默认值；未登记返回 None。名字带 Raw 以区分三类通用的 aiSettingDefaultOf()。 */
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

/* 校验"密钥引用"—— 这是"密钥不落库"的机制保证。
 * 只接受 env:名 / file:路径 / builtin:demo，其余一律拒绝。
 * 不能只判前缀：否则 env:sk-xxx 就能把密钥本体写进库。 */
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
        /* 环境变量名形状 [A-Za-z_][A-Za-z0-9_]*：必须收紧，否则 env:sk-abcdef 这类值会被当变量名入库。 */
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
        /* 路径形状：含 / 或 \ 或以盘符开头 —— 不含分隔符的 file: 值不像真路径。 */
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
    if (startsWithAscii(t.toAsciiLower(), AI_BUILTIN_SCHEME)) {
        /* 内置引用按白名单比对名字（目前只有 demo），避免 builtin:sk-xxx 入库。 */
        match (keyRefBuiltinName(t)) {
            case Some(_) => return ""
            case None => return "内置引用只支持 `builtin:demo`（白名单）—— `builtin:` 后面只能是已登记的内置名字"
        }
    }
    return "只接受 `env:变量名` / `file:路径` / `builtin:demo` 三种形式 —— " +
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

/* 由数据库配置装配出的运行时 AI 选项。
 * allowPlaintextEndpoint 本版本恒为 false（无赋值点，fail-closed）：明文 endpoint 一律被拒。 */
public class AiRuntimeOptions {
    public var endpoint: String = ""
    public var model: String = ""
    /* 密钥**引用**（env:名 / file:路径），不是密钥本体。 */
    public var keyRef: String = ""
    public var caBundlePath: String = ""
    public var timeoutSecs: Int64 = 30
    public var maxConcurrent: Int64 = 4
    public var maxTokens: Int64 = 2048
    /* 采样温度：显式发 0.7，不再依赖服务商默认值（同一主诉要给稳定排序）。
     * 0 是合法取值（最确定），不是"未配置"，故用 Float64。 */
    public var temperature: Float64 = 0.7
    /* ⚠ 本版本**恒为 false**（没有任何赋值点，见下方说明）。 */
    public var allowPlaintextEndpoint: Bool = false

    /* 本次用的是哪个模型（排障遥测）：调用与落库之间可能被改配置，不能事后才查。
     * modelId=0 表示走 KV，modelName 仍是实际发出的模型名。 */
    public var modelId: Int64 = 0
    public var modelName: String = ""

    public var enabled: Bool = false
    public var disabledReason: String = ""

    public init() {}
}

/* 校验运行时选项是否自洽（只读配置，不做出站调用）。
 * 边界：endpoint 必须 https://、timeout 1..300、并发 1..64、maxTokens 64..8192、keyRef 过 validateKeyRef。 */
public func aiRuntimeValidate(o: AiRuntimeOptions): Unit {
    if (o.endpoint.size == 0) {
        o.enabled = false
        o.disabledReason = "未配置 ${SET_AI_ENDPOINT}，AI 功能不可用（其余功能不受影响）"
        return
    }
    if (!o.allowPlaintextEndpoint && !startsWithAscii(o.endpoint.toAsciiLower(), "https://")) {
        o.enabled = false
        /* 错误消息必须说清"本版本没有明文放行开关"，否则运维会去翻不存在的启动参数。 */
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
        o.disabledReason = "未配置 ${SET_AI_KEY_REF}（必须是 env:名 / file:路径 / builtin:demo）"
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

/* 纯十进制整数（可带前导负号）。写入路径必须严格：parseInt64Or 回兜底值，
 * 无法区分"非数字"与"越界"，而两者要给不同拒绝理由。 */
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
            return false
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

/* 写入结果：ok=false 时 rejected 带可直接给运维的拒绝原因。 */
public class AiSettingPutResult {
    public var ok: Bool = false
    public var rejected: String = ""
}

/* ===================== 仓储（含缓存与失效）===================== */

/* AI 配置仓储 —— "改配置零重启"的落点：读走内存缓存，写主动失效缓存。
 * 写库即清缓存 + 5 s TTL ⇒ 改配置零重启；多实例收不到失效通知，只能靠 TTL 收敛，
 * 本机单实例下 TTL 不触发也不能删（否则上多实例会静默不一致）。 */
public let AI_SETTINGS_CACHE_TTL_SECS: Int64 = 5

/* AI 配置仓储：读走缓存（TTL 5 s），写库后主动失效缓存。 */
public class AiSettingsRepo {
    private let db: DbBackend
    /* 可重入：get 在仓储锁内调用 reload；锁序为仓储锁 → 数据库连接锁。
     * 写操作释放连接锁后才 invalidate，不得反向获取仓储锁。 */
    private let cacheLock = Mutex()
    /* 缓存：所有项的 key→value。`cacheAt = 0` 表示未加载/已失效。 */
    private var cache: HashMap<String, String> = HashMap<String, String>()
    private var cacheAt: Int64 = 0
    /* 多模型配置（ai_model）的可选装配点：None ⇒ 只走 KV 口径。
     * 不能在 options() 里 getOrThrow：那会把"没接模型表"变成运行期崩溃。 */
    private var models: ?AiModelRepo = None

    public init(db: DbBackend) {
        this.db = db
    }

    /* 接上模型表（`main.cj` 里构造完两个仓储后调用一次）。 */
    public func attachModels(m: AiModelRepo): Unit {
        models = Some(m)
    }

    /* 读某项配置：优先取库里的值，库里没有该行则用默认值。
     * "没有该行"与"存了空串"必须区分（后者=清空，如 endpoint 清空即停用 AI）；数值项无"空"这一态。 */
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

    /* 某项在库里有行吗。get() 分不清"库里有行"和"用默认值"（都返回非空），
     * 判"存量库"一律问库，不要拿 get() 当探针；绕过缓存直接查库。 */
    public func hasRow(key: String): Bool {
        let rs = db.query("SELECT k FROM ai_setting WHERE k = ?", [DbStr(key)])
        return rs.rowCount() > 0
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

    /* 主动失效缓存：写入后必须调用 —— 这就是"改配置零重启"的全部机制。
     * 置 cacheAt=0 而不是把新值塞进缓存：永远以库为准，避免多实例/并发下不一致。 */
    public func invalidate(): Unit {
        synchronized(cacheLock) {
            cacheAt = 0
        }
    }

    /* 写某项配置（含**未登记 key 拒绝**与**密钥引用校验**两道闸门）。 */
    public func put(key: String, value: String, now: Int64): AiSettingPutResult {        let r = AiSettingPutResult()
        /* 闸门①：必须是已登记的 key，否则 KV 表会变垃圾场（ai.* / prompt.* / ai.tool.* 三类）。 */
        if (!aiSettingKeyKnown(key)) {
            r.rejected = "未知的配置项：${key}（只有登记过的 key 才能写）"
            return r
        }
        /* 闸门①之二：已登记但本版本不支持的项拒绝写入 —— 写入 200 却没人消费是最坏的失败。 */
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
        /* 闸门③：数值项写入即校验。能在写入时判定的错，不要留到读取时静默回落。
         * 空值例外且必须显式接受：它表示回到默认值（与 remove 等价）。 */
        let trimmed = value.trimAscii()
        var spec: ?AiSettingSpec = None
        for (s in aiSettingSpecs()) {
            if (s.key == key) {
                spec = Some(s)
            }
        }
        /* 只有静态登记项做数值校验：Prompt 模板与工具开关走各自的闸门。 */
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
        /* 存 trim 后的值：否则回显 "   " 而生效值是默认值，又一次"回显 ≠ 生效"。 */
        let stored = trimmed
        db.exec("INSERT INTO ai_setting (k, v, updated_at) VALUES (?, ?, ?) " +
                "ON DUPLICATE KEY UPDATE v = VALUES(v), updated_at = VALUES(updated_at)",
                [DbStr(key), DbStr(stored), DbInt(now)])
        bumpRevision(now)
        invalidate()
        r.ok = true
        return r
    }

    /* 把配置版本号推进一格：写入、删除都算一次配置变更。
     * 不用"整表 +1"（版本号寄生于会被删的行，会丢格/倒退）；不用"先读 MAX 再写"（并发丢格）；用库内自增。 */
    private func bumpRevision(now: Int64): Unit {
        /* 一条语句管两种情况：不存在 ⇒ 插入 revision=1；已存在 ⇒ 库内自增，两次变更记两格。 */
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
        /* 删除也是改配置，同样推进版本号：删掉一项会让生效值跳回默认值。 */
        let _ = db.exec("DELETE FROM ai_setting WHERE k = ?", [DbStr(key)])
        bumpRevision(now)
        invalidate()
        return true
    }

    /* 当前配置版本号：普通行 revision 恒 0，MAX(revision) 即保留行的值。
     * "还没有任何配置"用 0 表达（不是 1），否则会与"第一次改配置后"撞号；不是事务隔离级别。 */
    public func revision(now: Int64): Int64 {
        /* 必须自己 try/catch：调用点（http_app.cj 分诊路由）是具名实参，在 record() 函数体前求值，
         * 那里的 catch 护不住。库一抖会冒到兜底 500 —— 统计是旁路，不能影响分诊结论。回 0 语义安全。 */
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

    /* 把配置装配成 AiRuntimeOptions 并校验（只读配置，不做任何出站调用）。 */
    public func options(now: Int64): AiRuntimeOptions {
        let o = AiRuntimeOptions()
        o.endpoint = get(SET_AI_ENDPOINT, now).trimAscii()
        o.model = get(SET_AI_MODEL, now).trimAscii()
        /* 先记 KV 口径的模型名，再由默认模型行覆盖；modelId 保持 0 = 没有模型行。 */
        o.modelName = o.model
        o.timeoutSecs = parseInt64Or(get(SET_AI_TIMEOUT, now), 30)
        o.maxConcurrent = parseInt64Or(get(SET_AI_MAX_CONCURRENT, now), 4)
        o.maxTokens = parseInt64Or(get(SET_AI_MAX_TOKENS, now), 2048)
        o.caBundlePath = get(SET_AI_CA_BUNDLE, now).trimAscii()
        o.keyRef = get(SET_AI_KEY_REF, now).trimAscii()
        /* 密钥引用不进 apiKeyFile：它是引用不是路径，边界在类型上就不能混。 */
        let masterOn = get(SET_AI_ENABLED, now).trimAscii() == "1"
        /* ai_model 的默认对话模型整行覆盖 KV 的 endpoint / model / key_ref / temperature / max_tokens。
         * 必须整行覆盖而不是逐字段合并：否则会出现"新表 base_url + 旧表 model"这种拼出来的模型。
         * key_ref 为空例外（沿用全局那把）；base_url 是基地址，必须过 aiModelRequestUrl 拼 /chat/completions。 */
        match (models) {
            case Some(mr) =>
                match (mr.defaultOf(AI_MODEL_KIND_CHAT, now)) {
                    case Some(m) =>
                        o.endpoint = aiModelRequestUrl(m.baseUrl, AI_MODEL_KIND_CHAT)
                        o.model = m.model
                        /* 带走"这一行是谁"：名字优先用行名，为空时退回模型名（排障看到空名字等于没记）。 */
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

/* 配置的可回显视图（JSON）。安全要点：secret 项只回显"是否已设置"，绝不回显值本身。 */
public func aiSettingsJson(repo: AiSettingsRepo, now: Int64): JsonObject {
    let o = JsonObject()
    let items = ArrayList<JsonValue>()
    for (s in aiSettingSpecs()) {
        let e = JsonObject()
        e.put("key", JsonString(s.key))
        e.put("label", JsonString(s.label))
        e.put("secret", JsonBool(s.secret))
        if (s.secret) {
            /* 敏感项只回"设置了没有" + 引用类型（env / file / builtin），连变量名与路径都不回。 */
            let v = repo.get(s.key, now)
            e.put("set", JsonBool(v.size > 0))
            var kind = ""
            if (keyRefEnvName(v).isSome()) {
                kind = "env"
            } else if (keyRefFilePath(v).isSome()) {
                kind = "file"
            } else if (keyRefBuiltinName(v).isSome()) {
                kind = "builtin"
            }
            e.put("ref_kind", JsonString(kind))
        } else if (s.key == SET_AI_ENDPOINT) {
            /* endpoint 非秘密，但值不能原样回显：网关常把凭据放在查询串里。脱敏只能在一处做（aiSafeHost）。 */
            let full = repo.get(s.key, now)
            e.put("value", JsonString(aiSafeHost(full)))
            e.put("default", JsonString(s.defaultVal))
            /* 告知"是否被脱敏过"，避免管理员以为配置里真的只存了 host */
            e.put("redacted", JsonBool(full.size > 0 && aiSafeHost(full) != full))
        } else {
            /* 回显的 value 必须是生效值：原始值非空回原始值，为空回默认值，于是"回显 == 生效"。
             * default / is_default 单独给出，便于区分"手设的"与"默认的"。 */
            let raw = repo.get(s.key, now)
            let shown = if (raw.size > 0) { raw } else { s.defaultVal }
            e.put("value", JsonString(shown))
            e.put("default", JsonString(s.defaultVal))
            e.put("is_default", JsonBool(raw.size == 0))
        }
        items.add(e)
    }
    o.put("items", JsonArray(items.toArray()))
    /* 生效状态：只给"能不能用 + 为什么"，endpoint 也脱敏。 */
    let opt = repo.options(now)
    o.put("enabled", JsonBool(opt.enabled))
    o.put("disabled_reason", JsonString(opt.disabledReason))
    o.put("endpoint_host", JsonString(aiSafeHost(opt.endpoint)))
    /* key_ref_kind / key_resolvable / model / model_id：把"真的能调用吗"拆成可判定字段。
     * enabled 只回答配置是否自洽，不回答密钥此刻取不取得到 —— 两者混谈会把排查引向错误方向。 */
    var refKind = ""
    if (keyRefEnvName(opt.keyRef).isSome()) {
        refKind = "env"
    } else if (keyRefFilePath(opt.keyRef).isSome()) {
        refKind = "file"
    } else if (keyRefBuiltinName(opt.keyRef).isSome()) {
        refKind = "builtin"
    }
    o.put("key_ref_kind", JsonString(refKind))
    o.put("key_resolvable", JsonBool(refKind.size > 0 && aiResolveKey(opt.keyRef).isSome()))
    o.put("model", JsonString(opt.modelName))
    o.put("model_id", JsonInt(opt.modelId))
    return o
}

/* 抹掉 endpoint 的凭据部分，保留到路径为止（scheme://host[:port]/path）。
 * 查询串 ?.../#... 与 userinfo 必须抹掉（真凭据位置）；路径必须保留，
 * 否则管理员无法核对"对话模型与向量模型有没有配反"。必须重新拼装，不能用切片拼接。 */
public func aiSafeHost(url: String): String {
    if (url.size == 0) {
        return ""
    }
    let chars = ArrayList<Rune>()
    for (r in url.runes()) {
        chars.add(r)
    }
    let arr = chars.toArray()
    var start: Int64 = 0
    var k: Int64 = 0
    while (k + 2 < arr.size) {
        if (arr[k] == r':' && arr[k + 1] == r'/' && arr[k + 2] == r'/') {
            start = k + 3
            break
        }
        k = k + 1
    }
    /* userinfo：scheme:// 之后、第一个 /?# 之前，取最后一个 @ —— 密码本身可能含 @。 */
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
    /* 重新拼装：先抄 scheme://，再从 host 拼到终点（跳过 userinfo）；遇 ?/# 停。 */
    let out = ArrayList<Rune>()
    var p: Int64 = 0
    while (p < start) {
        out.add(arr[p])
        p = p + 1
    }
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
