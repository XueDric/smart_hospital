/*
 * ★★ 管理台「AI 模型配置」的后端（2026-10-14 新增）。
 *
 * ── 这个文件解决什么问题 ──
 *
 * 管理台要能看到**多条命名模型配置**（默认对话模型 / 默认向量模型），
 * 每条有：类型（CHAT / EMBEDDING）、提供方、接口地址、模型名、温度、
 * max_tokens、启停，并且能：新增 / 编辑 / 删除 / **连通性测试** /
 * **一键失效配置缓存**（"保存后自动失效缓存，下一次 AI 请求动态构建模型实例，
 * 无需重启服务" —— 这一句是需求原文，也是本文件所有设计的约束）。
 *
 * ── 三条边界（都是**刻意**的，不是省事）──
 *
 * ① **密钥本体绝不入库**：`key_ref` 存的是 `env:名` / `file:路径` 引用，
 *    与 `ai_setting.ai.key_ref` 同一条纪律（brief §5.3），由 `aiModelValidate`
 *    复用 `validateKeyRef` 机制性保证。接口回显时也只给"设置了没有 + 引用类型"。
 * ② **不改旧表 `ai_setting`**：`ai.enabled` 仍是总开关；旧 KV 的
 *    endpoint/model/max_tokens 仍可读，作为"一条默认模型都没有"时的回退
 *    （见 ai_settings.cj 的 aiRuntimeResolve）。这样**升级顺序自由**：
 *    先升服务端、后建配置，中间不会出现"AI 静默不可用"的窗口。
 * ③ **解析是动态的**：每次 AI 请求都问 `defaultOf(kind)`（5 秒 TTL 内存缓存 +
 *    写操作主动失效），所以改配置**不需要重启**。这正是需求里那句话的落点。
 *
 * ⚠ 为什么 `base_url` 允许写"基址"也允许写"完整 URL"：见 `aiModelRequestUrl`。
 */
package qingzhou

import std.collection.*
import stdx.encoding.json.*
/*
 * ⚠ `std.sync.*` 是给 `Mutex` 用的（缓存锁）。`AiSettingsRepo` 在 2026-10-14
 *   上游那次修复里也加了同一个 import —— 两边口径保持一致。
 */
import std.sync.*

/* ===================== 常量 ===================== */

public let AI_MODEL_KIND_CHAT: String = "CHAT"
public let AI_MODEL_KIND_EMBEDDING: String = "EMBEDDING"

public let AI_MODEL_NAME_MAX_CHARS: Int64 = 64
public let AI_MODEL_PROVIDER_MAX_CHARS: Int64 = 64
public let AI_MODEL_BASE_URL_MAX_CHARS: Int64 = 512
public let AI_MODEL_MODEL_MAX_CHARS: Int64 = 128
public let AI_MODEL_KEY_REF_MAX_CHARS: Int64 = 512

/*
 * 温度范围 0..2（OpenAI 兼容协议的实际取值范围）。
 * ⚠ 与 `ai.max_tokens` 的 64..8192 一样，**范围要在写入那一刻拦住**：
 *   温度写成 30 不会报错，只会让输出变成胡言乱语 —— 那是最难查的一类问题。
 */
public let AI_MODEL_TEMPERATURE_MIN: Float64 = 0.0
public let AI_MODEL_TEMPERATURE_MAX: Float64 = 2.0
public let AI_MODEL_MAX_TOKENS_MIN: Int64 = 64
public let AI_MODEL_MAX_TOKENS_MAX: Int64 = 8192

/* 与 `AI_SETTINGS_CACHE_TTL_SECS` 同口径：写操作主动失效，多实例靠 TTL 收敛。 */
public let AI_MODEL_CACHE_TTL_SECS: Int64 = 5

/* 连通性测试的超时（比业务调用短：它是**人在等**的一次交互）。 */
public let AI_MODEL_PROBE_TIMEOUT_SECS: Int64 = 15
public let AI_MODEL_PROBE_MAX_TOKENS: Int64 = 8
public let AI_MODEL_PROBE_SAMPLE_MAX_CHARS: Int64 = 160

public let AI_MODEL_LIST_DEFAULT_LIMIT: Int64 = 50
public let AI_MODEL_LIST_MAX_LIMIT: Int64 = 200

/* 列顺序**一处定义**：SELECT 与行解析共用，避免"加了列忘了改解析"（test-evidence 类事故）。 */
public let AI_MODEL_COLUMNS: String =
    "id, name, kind, provider, base_url, model, temperature, max_tokens, " +
    "key_ref, enabled, is_default, created_at, updated_at, updated_by"

/* 行内列号（与 AI_MODEL_COLUMNS 一一对应）。 */
let AI_MODEL_C_ID: Int64 = 0
let AI_MODEL_C_NAME: Int64 = 1
let AI_MODEL_C_KIND: Int64 = 2
let AI_MODEL_C_PROVIDER: Int64 = 3
let AI_MODEL_C_BASE_URL: Int64 = 4
let AI_MODEL_C_MODEL: Int64 = 5
let AI_MODEL_C_TEMPERATURE: Int64 = 6
let AI_MODEL_C_MAX_TOKENS: Int64 = 7
let AI_MODEL_C_KEY_REF: Int64 = 8
let AI_MODEL_C_ENABLED: Int64 = 9
let AI_MODEL_C_IS_DEFAULT: Int64 = 10
let AI_MODEL_C_CREATED_AT: Int64 = 11
let AI_MODEL_C_UPDATED_AT: Int64 = 12
let AI_MODEL_C_UPDATED_BY: Int64 = 13

/*
 * 播种用的默认两行（只在表**完全为空**时写入）。
 *
 * ★ 2026-10-17 评审整改：对话模型默认改成 **DeepSeek**（与 `ai_builtin.cj` 里
 *   内置的演示凭据配套 —— 开箱即用必须"默认行指向那把 key 能用的服务"）。
 *   向量模型**不跟着改**：DeepSeek 没有 `/embeddings` 端点，硬指过去只会 404，
 *   所以向量行仍指百练（需要时由运维填它自己的 `key_ref`）。
 *   ⚠ 这一行"不假装能用"是刻意的：向量检索的真实 provider 未接入（评审 P2-6）。
 */
public let AI_MODEL_SEED_CHAT_NAME: String = "默认对话模型"
public let AI_MODEL_SEED_EMBEDDING_NAME: String = "默认向量模型"
public let AI_MODEL_SEED_PROVIDER: String = "DeepSeek"
public let AI_MODEL_SEED_BASE_URL: String = "https://api.deepseek.com"
public let AI_MODEL_SEED_CHAT_MODEL: String = "deepseek-chat"
public let AI_MODEL_SEED_EMBEDDING_PROVIDER: String = "百练"
public let AI_MODEL_SEED_EMBEDDING_BASE_URL: String = "https://dashscope.aliyuncs.com/compatible-mode/v1"
public let AI_MODEL_SEED_EMBEDDING_MODEL: String = "text-embedding-v3"
public let AI_MODEL_SEED_CHAT_TEMPERATURE: Float64 = 0.3
public let AI_MODEL_SEED_MAX_TOKENS: Int64 = 2048

/* ===================== 数据结构 ===================== */

public class AiModel {
    public var id: Int64 = 0
    public var name: String = ""
    public var kind: String = ""
    public var provider: String = ""
    public var baseUrl: String = ""
    public var model: String = ""
    public var temperature: Float64 = AI_MODEL_SEED_CHAT_TEMPERATURE
    public var maxTokens: Int64 = AI_MODEL_SEED_MAX_TOKENS
    public var keyRef: String = ""
    public var enabled: Bool = true
    public var isDefault: Bool = false
    public var createdAt: Int64 = 0
    public var updatedAt: Int64 = 0
    public var updatedBy: Int64 = 0

    public init() {}

    public func copy(): AiModel {
        let m = AiModel()
        m.id = id
        m.name = name
        m.kind = kind
        m.provider = provider
        m.baseUrl = baseUrl
        m.model = model
        m.temperature = temperature
        m.maxTokens = maxTokens
        m.keyRef = keyRef
        m.enabled = enabled
        m.isDefault = isDefault
        m.createdAt = createdAt
        m.updatedAt = updatedAt
        m.updatedBy = updatedBy
        return m
    }
}

/*
 * 写操作结果。
 *
 * ⚠ 用**字段**区分失败原因而不是抛异常：仓颉里 `UserFacingError` 会变成
 *   400 VALIDATION_FAILED，但"同名已存在"要给 **409**、"不存在"要给 **404**
 *   —— 一个异常类型表达不了三种 HTTP 状态（这正是 base/kb/notice 用 outcome 的理由）。
 */
public class AiModelWriteOutcome {
    public var ok: Bool = false
    public var id: Int64 = 0
    /* 同名冲突（409）。 */
    public var duplicate: Bool = false
    /* 目标不存在（404）。 */
    public var notFound: Bool = false
    /* 非空 = 校验失败原因（400）。 */
    public var invalid: String = ""

    public init() {}
}

/* 连通性测试结果（**不抛异常**：测试失败是"结果"，不是"服务端故障"）。 */
public class AiModelProbeResult {
    public var ok: Bool = false
    public var kind: String = ""
    public var requestUrl: String = ""
    public var model: String = ""
    public var elapsedMs: Int64 = 0
    public var httpStatus: Int64 = 0
    public var reason: String = ""
    public var sample: String = ""
    /* 用的是哪来的密钥引用：model / global / ""。 */
    public var keySource: String = ""

    public init() {}
}

/* ===================== 校验与派生 ===================== */

/* 类型规范化：大小写不敏感，非法返回 ""。 */
public func aiModelKindNormalize(kind: String): String {
    let k = kind.trimAscii().toAsciiLower()
    if (k == "chat") {
        return AI_MODEL_KIND_CHAT
    }
    if (k == "embedding") {
        return AI_MODEL_KIND_EMBEDDING
    }
    return ""
}

public func aiModelKindLabel(kind: String): String {
    if (kind == AI_MODEL_KIND_CHAT) {
        return "对话模型"
    }
    if (kind == AI_MODEL_KIND_EMBEDDING) {
        return "向量模型"
    }
    return kind
}

/*
 * 文本字段检查：非空 / 限长 / **不许含控制字符**。
 *
 * ⚠ 最后一条对本文件格外重要：`base_url` 会被直接拼进 HTTP 请求头之外的 URL，
 *   一个换行就能**注入额外的头**（CRLF injection）。所以它不是"顺手校验"，
 *   而是这个接口的**安全边界**（与公告标题禁控制字符同源）。
 */
func aiModelCheckText(v: String, what: String, maxChars: Int64, allowEmpty: Bool): String {
    if (v.size == 0) {
        if (allowEmpty) {
            return ""
        }
        return "${what}不能为空"
    }
    if (v.size > maxChars) {
        return "${what}最长 ${maxChars} 个字符（当前 ${v.size}）"
    }
    let chars = v.toArray()
    var i: Int64 = 0
    while (i < chars.size) {
        let c = Int64(chars[i])
        /* 0x00-0x1F 控制字符 + 0x7F DEL。 */
        if (c < 0x20 || c == 0x7F) {
            return "${what}不能含有控制字符（换行/制表等）"
        }
        i = i + 1
    }
    return ""
}

/*
 * 校验一条模型配置。返回 "" = 通过，否则是**可直接给运维看**的原因。
 *
 * ⚠ 这里**只读配置、不出站**：它回答"这条配置写得对不对"，
 *   不回答"这个模型能不能连上" —— 后者是 `aiModelProbe`（人主动点"连通性测试"）。
 */
public func aiModelValidate(name: String, kind: String, provider: String, baseUrl: String,
                            model: String, temperature: Float64, maxTokens: Int64,
                            keyRef: String): String {
    var why = aiModelCheckText(name.trimAscii(), "配置名称", AI_MODEL_NAME_MAX_CHARS, false)
    if (why.size > 0) {
        return why
    }
    if (aiModelKindNormalize(kind).size == 0) {
        return "类型只能是 ${AI_MODEL_KIND_CHAT}（对话）或 ${AI_MODEL_KIND_EMBEDDING}（向量），收到的是：${kind}"
    }
    why = aiModelCheckText(provider.trimAscii(), "提供方", AI_MODEL_PROVIDER_MAX_CHARS, true)
    if (why.size > 0) {
        return why
    }
    let url = baseUrl.trimAscii()
    why = aiModelCheckText(url, "接口地址", AI_MODEL_BASE_URL_MAX_CHARS, false)
    if (why.size > 0) {
        return why
    }
    /*
     * ⚠ https 强制：与 `aiRuntimeValidate` 同一条理由（明文调用大模型 = 密钥裸奔），
     *   而且这里**更早**拦住 —— 配错的代价是"密钥在网络上裸奔"，不是"报个错"。
     */
    if (!startsWithAscii(url.toAsciiLower(), "https://")) {
        return "接口地址必须是 https://（明文调用大模型 = 密钥裸奔）"
    }
    why = aiModelCheckText(model.trimAscii(), "模型名称", AI_MODEL_MODEL_MAX_CHARS, false)
    if (why.size > 0) {
        return why
    }
    /*
     * ⚠ NaN / Infinity 必须单独拦：`NaN` 与任何数比较都是 false，
     *   于是它**能穿过**范围判断（`t < min || t > max` 两个都是 false）。
     *   自己与自己比较是唯一可靠的 NaN 判定。
     */
    if (temperature != temperature) {
        return "温度不能是 NaN"
    }
    if (temperature < AI_MODEL_TEMPERATURE_MIN || temperature > AI_MODEL_TEMPERATURE_MAX) {
        return "温度必须在 ${AI_MODEL_TEMPERATURE_MIN}..${AI_MODEL_TEMPERATURE_MAX} 之间（收到 ${temperature}）"
    }
    if (maxTokens < AI_MODEL_MAX_TOKENS_MIN || maxTokens > AI_MODEL_MAX_TOKENS_MAX) {
        return "max_tokens 必须在 ${AI_MODEL_MAX_TOKENS_MIN}..${AI_MODEL_MAX_TOKENS_MAX} 之间（收到 ${maxTokens}）"
    }
    /*
     * 密钥引用可以**留空**（= 回退到全局 `ai.key_ref`），但一旦填了就必须是合法引用。
     * ⚠ 校验复用 `validateKeyRef`：密钥引用的形状只允许有一处定义。
     */
    let kr = keyRef.trimAscii()
    if (kr.size > 0) {
        if (kr.size > AI_MODEL_KEY_REF_MAX_CHARS) {
            return "密钥引用最长 ${AI_MODEL_KEY_REF_MAX_CHARS} 个字符"
        }
        let krWhy = validateKeyRef(kr)
        if (krWhy.size > 0) {
            return krWhy
        }
    }
    return ""
}

/* 密钥引用的类型（env / file / builtin / ""），**不回显引用本体**（同 aiSettingsJson 的纪律）。 */
public func aiModelKeyRefKind(keyRef: String): String {
    if (keyRefEnvName(keyRef).isSome()) {
        return "env"
    }
    if (keyRefFilePath(keyRef).isSome()) {
        return "file"
    }
    if (keyRefBuiltinName(keyRef).isSome()) {
        return "builtin"
    }
    return ""
}

/*
 * ★ 由 `base_url` + 类型派生出**真正的请求 URL**。
 *
 * 为什么要做这一步：运维在管理台填的地址有两种习惯 ——
 *   ① 填**基址**（`https://dashscope.aliyuncs.com/compatible-mode/v1`，
 *      截图上的样子就是这种）；
 *   ② 填**完整端点**（`.../v1/chat/completions`，旧 `ai.endpoint` 的习惯）。
 * 两种都常见，**让填的人记住"必须填完整"是设计缺陷**（填错的表现是
 * "连通性测试失败"，而原因藏在字符串拼接里，最难查）。
 *
 * ⇒ 规则（**显式、可预测、两种都认**）：
 *   · 结尾已经是 `/chat/completions`（CHAT）或 `/embeddings`（EMBEDDING）⇒ 原样用；
 *   · 否则：CHAT 追加 `/chat/completions`，EMBEDDING 追加 `/embeddings`；
 *   · 末尾多余的 `/` 先去掉（`.../v1/` + `/chat/completions` 会拼出 `//`）。
 *
 * ⚠ 这个派生结果会**回显**在接口里（`request_url`）并进连通性测试的结论 ——
 *   "实际请求了哪个 URL"必须能从管理台看到，否则排查只能靠猜。
 */
public func aiModelRequestUrl(baseUrl: String, kind: String): String {
    var u = baseUrl.trimAscii()
    while (u.size > 0 && aiModelLastCharIs(u, 0x2F)) {
        u = aiModelDropLast(u)
    }
    let lower = u.toAsciiLower()
    if (kind == AI_MODEL_KIND_EMBEDDING) {
        if (aiModelEndsWithAscii(lower, "/embeddings")) {
            return u
        }
        return u + "/embeddings"
    }
    if (aiModelEndsWithAscii(lower, "/chat/completions")) {
        return u
    }
    return u + "/chat/completions"
}

func aiModelLastCharIs(s: String, code: Int64): Bool {
    if (s.size == 0) {
        return false
    }
    let chars = s.toArray()
    return Int64(chars[chars.size - 1]) == code
}

func aiModelDropLast(s: String): String {
    let chars = s.toArray()
    let out = ArrayList<UInt8>()
    var i: Int64 = 0
    while (i < chars.size - 1) {
        out.add(chars[i])
        i = i + 1
    }
    return String.fromUtf8(out.toArray())
}

/*
 * 后缀判断（stdx 没有 endsWith 的 ascii 版；本项目只在这里需要）。
 * ⚠ 逐字节比较：中文按 UTF-8 多字节比，但这里的后缀全是 ascii，
 *   所以"字节数 = 字符数"的前提成立。
 */
func aiModelEndsWithAscii(s: String, tail: String): Bool {
    if (tail.size > s.size) {
        return false
    }
    let a = s.toArray()
    let b = tail.toArray()
    let start = a.size - b.size
    var i: Int64 = 0
    while (i < b.size) {
        if (a[start + i] != b[i]) {
            return false
        }
        i = i + 1
    }
    return true
}

public func aiModelClampLimit(limit: Int64): Int64 {
    if (limit <= 0) {
        return AI_MODEL_LIST_DEFAULT_LIMIT
    }
    if (limit > AI_MODEL_LIST_MAX_LIMIT) {
        return AI_MODEL_LIST_MAX_LIMIT
    }
    return limit
}

/* ===================== 仓储 ===================== */

/*
 * 模型配置仓储。
 *
 * ── 缓存（与 `AiSettingsRepo` 同款，理由也一样）──
 *   读走内存缓存（避免每个 AI 请求都查库），写**主动失效**。
 *   `invalidate()` 只置 `cacheAt = 0`（不塞新值）：下一次读自然重查 ——
 *   这样"写"与"刷新"不会各写一半。
 *
 * ⚠ 多实例部署时，别的实例最迟 `AI_MODEL_CACHE_TTL_SECS` 秒后跟上。
 *   要做到"立刻全局失效"需要一个共享的失效通道（本项目还没有，也不假装有）。
 */
public class AiModelRepo {
    private let db: DbBackend
    /*
     * ★ 2026-10-14（第三方复查 B4 修）：缓存必须与 `AiSettingsRepo` 同款地加锁。
     *
     * 原实现**没有任何锁**：`ensureCache()` 直接给共享的 `cache` 赋值，
     * 而 `list`/`get`/`defaultOf` 同时在迭代同一个对象。
     * 本服务端当前不含 `spawn`（见 acceptance.cj），所以这不是已证实的竞态 ——
     * 但"同一个进程里两个仓储，一个加锁一个不加"本身就是纪律分裂：
     * 谁把 AI 调用挪到工作线程，谁就会踩到那个"只有一半的锁"。
     *
     * 锁序与 `AiSettingsRepo` **完全一致**（仓储锁 → 数据库连接锁，可重入）：
     *   `ensureCache` 在仓储锁内调 `reload()`；写操作在 `db.exec` 返回后才 `invalidate()`，
     *   不持有连接锁反向获取仓储锁。
     */
    private let cacheLock = Mutex()
    private var cache: ArrayList<AiModel> = ArrayList<AiModel>()
    private var cacheAt: Int64 = 0

    public init(db: DbBackend) {
        this.db = db
    }

    private func rowToModel(rs: DbResultSet, i: Int64): AiModel {
        let m = AiModel()
        m.id = rs.getInt(i, AI_MODEL_C_ID)
        m.name = rs.getString(i, AI_MODEL_C_NAME)
        m.kind = rs.getString(i, AI_MODEL_C_KIND)
        m.provider = rs.getString(i, AI_MODEL_C_PROVIDER)
        m.baseUrl = rs.getString(i, AI_MODEL_C_BASE_URL)
        m.model = rs.getString(i, AI_MODEL_C_MODEL)
        m.temperature = rs.getFloat(i, AI_MODEL_C_TEMPERATURE)
        m.maxTokens = rs.getInt(i, AI_MODEL_C_MAX_TOKENS)
        m.keyRef = rs.getString(i, AI_MODEL_C_KEY_REF)
        m.enabled = rs.getInt(i, AI_MODEL_C_ENABLED) != 0
        m.isDefault = rs.getInt(i, AI_MODEL_C_IS_DEFAULT) != 0
        m.createdAt = rs.getInt(i, AI_MODEL_C_CREATED_AT)
        m.updatedAt = rs.getInt(i, AI_MODEL_C_UPDATED_AT)
        m.updatedBy = rs.getInt(i, AI_MODEL_C_UPDATED_BY)
        return m
    }

    private func reload(): ArrayList<AiModel> {
        let out = ArrayList<AiModel>()
        /* ⚠ 按 id 升序：同一 kind 有多条 is_default=1 时，**取 id 最小的那条**是
           确定性规则（部分失败的写操作不该让"用哪个模型"变得不可预测）。 */
        let rs = db.query("SELECT " + AI_MODEL_COLUMNS + " FROM ai_model ORDER BY id ASC",
                          Array<DbValue>())
        var i: Int64 = 0
        while (i < rs.rowCount()) {
            out.add(rowToModel(rs, i))
            i = i + 1
        }
        return out
    }

    private func ensureCache(now: Int64): Unit {
        synchronized(cacheLock) {
            if (cacheAt == 0 || now - cacheAt > AI_MODEL_CACHE_TTL_SECS) {
                cache = reload()
                cacheAt = now
            }
        }
    }

    /* 主动失效（写操作后调用；管理台的「失效配置缓存」按钮也调它）。 */
    public func invalidate(): Unit {
        synchronized(cacheLock) {
            cacheAt = 0
        }
    }

    public func list(includeDisabled: Bool, now: Int64): ArrayList<AiModel> {
        ensureCache(now)
        let out = ArrayList<AiModel>()
        synchronized(cacheLock) {
            for (m in cache) {
                if (!includeDisabled && !m.enabled) {
                    continue
                }
                out.add(m.copy())
            }
        }
        return out
    }

    public func get(id: Int64, now: Int64): ?AiModel {
        ensureCache(now)
        synchronized(cacheLock) {
            for (m in cache) {
                if (m.id == id) {
                    return Some(m.copy())
                }
            }
        }
        return None
    }

    /*
     * 解析"某类型的生效模型"。
     *
     * 口径（**刻意宽容**，理由：宁可"有一就能用"，也不要"必须手工指定默认"）：
     *   ① 优先 `enabled = 1 AND is_default = 1`（多条时取 id 最小的）；
     *   ② 没有默认行 ⇒ 取该类型下 `enabled = 1` 的**第一条**（id 最小）；
     *   ③ 该类型一条启用的都没有 ⇒ None（调用方回退旧 KV，见 aiRuntimeResolve）。
     */
    public func defaultOf(kind: String, now: Int64): ?AiModel {
        ensureCache(now)
        var firstEnabled: ?AiModel = None
        var explicitDefault: ?AiModel = None
        synchronized(cacheLock) {
            for (m in cache) {
                if (m.kind != kind || !m.enabled) {
                    continue
                }
                if (firstEnabled.isNone()) {
                    firstEnabled = Some(m.copy())
                }
                if (m.isDefault && explicitDefault.isNone()) {
                    explicitDefault = Some(m.copy())
                }
            }
        }
        match (explicitDefault) {
            case Some(_) => return explicitDefault
            case None => return firstEnabled
        }
    }

    /* 表里一共有几条（播种判断用；不看缓存，直接数）。 */
    public func countAll(): Int64 {
        let rs = db.query("SELECT COUNT(*) FROM ai_model", Array<DbValue>())
        if (rs.rowCount() == 0) {
            return 0
        }
        return rs.getInt(0, 0)
    }

    private func nameTaken(name: String, exceptId: Int64): Bool {
        let rs = db.query("SELECT id FROM ai_model WHERE name = ?", [DbStr(name)])
        var i: Int64 = 0
        while (i < rs.rowCount()) {
            if (rs.getInt(i, 0) != exceptId) {
                return true
            }
            i = i + 1
        }
        return false
    }

    /*
     * 把"某类型只应有一条默认"这条**集合级不变量**做出来。
     *
     * ⚠ 为什么不用事务：本项目其余仓储也都是"多条语句顺序执行"的风格，
     *   而且这里失败的最坏后果只是"同一 kind 有两条 is_default=1"——
     *   而 `defaultOf` 取 id 最小 ⇒ **结果仍然确定**。
     *   ⇒ 用一条确定性规则兜住一个非原子写入，比引入本项目还没有的事务更划算。
     */
    private func clearOtherDefaults(kind: String, keepId: Int64, now: Int64): Unit {
        let _ = db.exec("UPDATE ai_model SET is_default = 0, updated_at = ? " +
                        "WHERE kind = ? AND id <> ?",
                        [DbInt(now), DbStr(kind), DbInt(keepId)])
    }

    public func create(m: AiModel, now: Int64, byUserId: Int64): AiModelWriteOutcome {
        let r = AiModelWriteOutcome()
        let name = m.name.trimAscii()
        let kind = aiModelKindNormalize(m.kind)
        let provider = m.provider.trimAscii()
        let url = m.baseUrl.trimAscii()
        let model = m.model.trimAscii()
        let keyRef = m.keyRef.trimAscii()
        let why = aiModelValidate(name, kind, provider, url, model, m.temperature, m.maxTokens, keyRef)
        if (why.size > 0) {
            r.invalid = why
            return r
        }
        if (nameTaken(name, 0)) {
            r.duplicate = true
            return r
        }
        /*
         * ★★ 2026-10-14（第三方复查 B6 修）：把唯一键冲突**接住**，回 409 而不是 500。
         *
         * 上面那句 `nameTaken` 是"先查后写"——两个请求同时查、都没有同名，
         * 然后一起 INSERT：真正的唯一性由 `uk_ai_model_name` 保证，于是**第二个** INSERT
         * 抛驱动异常。原实现没人接它 ⇒ 冒到全局兜底 ⇒ 客户端拿到 500「服务器内部错误」，
         * 而契约与测试声明的是 **409 AI_MODEL_NAME_TAKEN**（"同名配置已存在，是你选的冲突"）。
         *
         * 500 与 409 的差别在这里是**可操作性**：500 让人去查服务端日志，
         * 409 让人改个名字重试。既然表上已经有唯一键，就该让它的语义传到客户端。
         */
        var id: Int64 = 0
        try {
            /*
             * ⚠ 用 `execInsert` 而不是 `exec` + `SELECT LAST_INSERT_ID()`：
             *   新框架的 exec/query **不保证落在同一条连接**（上游因此把两处裸读 LAST_INSERT_ID
             *   全换成 execInsert，见 domain_booking.cj 的踩坑注释）。分开调用时读到的可能是
             *   别的连接的上一次自增值，或者干脆是 0 —— 表现是"新建配置成功但 id=0"，
             *   接着 `clearOtherDefaults` 会把**所有**行都当成别的行处理。
             */
            id = db.execInsert("INSERT INTO ai_model (name, kind, provider, base_url, model, temperature, " +
                               "max_tokens, key_ref, enabled, is_default, created_at, updated_at, updated_by) " +
                               "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                               [DbStr(name), DbStr(kind), DbStr(provider), DbStr(url), DbStr(model),
                                DbFloat(m.temperature), DbInt(m.maxTokens), DbStr(keyRef),
                                DbInt(if (m.enabled) { 1 } else { 0 }),
                                DbInt(if (m.isDefault) { 1 } else { 0 }),
                                DbInt(now), DbInt(now), DbInt(byUserId)])
        } catch (e: Exception) {
            /*
             * ⚠ 这里**只**把"同名"这一种解释成 409，其余异常照旧上抛（退化成 500）——
             *   把任何写失败都说成"重名"会让真正的故障（库断了、列类型改了）
             *   显示成"改个名字再试"，那比 500 更难排查。
             */
            if (nameTaken(name, 0)) {
                r.duplicate = true
                return r
            }
            throw e
        }
        if (m.isDefault) {
            clearOtherDefaults(kind, id, now)
        }
        invalidate()
        r.ok = true
        r.id = id
        return r
    }

    /*
     * 改一条配置。
     *
     * ⚠ 语义是 **PATCH（缺省 = 保持原值）**，不是 PUT（缺省 = 回默认）：
     *   管理部门最怕的是一次"只想改温度"的保存把密钥引用清空 ——
     *   而清空后 AI **静默不可用**（表现是"AI 突然不工作了"）。
     *   📌 与公告的 `published_at`（缺省 = 该行原值）同一条理由。
     */
    public func update(id: Int64, name: ?String, kind: ?String, provider: ?String, baseUrl: ?String,
                       model: ?String, temperature: ?Float64, maxTokens: ?Int64, keyRef: ?String,
                       enabled: ?Bool, isDefault: ?Bool, now: Int64, byUserId: Int64): AiModelWriteOutcome {
        let r = AiModelWriteOutcome()
        match (get(id, now)) {
            case None =>
                r.notFound = true
                return r
            case Some(cur) =>
                var nName = cur.name
                match (name) { case Some(v) => nName = v.trimAscii(); case None => () }
                var nKind = cur.kind
                match (kind) { case Some(v) => nKind = aiModelKindNormalize(v); case None => () }
                var nProvider = cur.provider
                match (provider) { case Some(v) => nProvider = v.trimAscii(); case None => () }
                var nUrl = cur.baseUrl
                match (baseUrl) { case Some(v) => nUrl = v.trimAscii(); case None => () }
                var nModel = cur.model
                match (model) { case Some(v) => nModel = v.trimAscii(); case None => () }
                var nTemp = cur.temperature
                match (temperature) { case Some(v) => nTemp = v; case None => () }
                var nTokens = cur.maxTokens
                match (maxTokens) { case Some(v) => nTokens = v; case None => () }
                var nKeyRef = cur.keyRef
                match (keyRef) { case Some(v) => nKeyRef = v.trimAscii(); case None => () }
                var nEnabled = cur.enabled
                match (enabled) { case Some(v) => nEnabled = v; case None => () }
                var nDefault = cur.isDefault
                match (isDefault) { case Some(v) => nDefault = v; case None => () }
                let why = aiModelValidate(nName, nKind, nProvider, nUrl, nModel, nTemp, nTokens, nKeyRef)
                if (why.size > 0) {
                    r.invalid = why
                    return r
                }
                if (nameTaken(nName, id)) {
                    r.duplicate = true
                    return r
                }
                /*
                 * ★ 2026-10-14（第三方复查 B3 修）：**不许把影响行数丢进 `let _`**。
                 *
                 * 原实现 UPDATE 之后直接 `r.ok = true`。若这一行在
                 * `get()`（上面的 match）与 UPDATE 之间被别人删掉，UPDATE 影响 0 行，
                 * 而接口仍然回 200「改成功了」—— **响应在撒谎**。
                 *
                 * 这正是本仓为 `setPassword` 明确修过的同类 bug
                 * （auth_repo.cj 注释："AUTH 先查存在性，否则 UPDATE 影响 0 行却回 200 —— 那是撒谎"）。
                 * 同一条纪律必须落到这里：0 行受影响 ⇒ 当"没这行"处理（404），
                 * 由调用方映射成 `AI_MODEL_NOT_FOUND`。
                 */
                var affected: Int64 = 0
                try {
                    affected = db.exec("UPDATE ai_model SET name = ?, kind = ?, provider = ?, base_url = ?, " +
                                    "model = ?, temperature = ?, max_tokens = ?, key_ref = ?, enabled = ?, " +
                                    "is_default = ?, updated_at = ?, updated_by = ? WHERE id = ?",
                                    [DbStr(nName), DbStr(nKind), DbStr(nProvider), DbStr(nUrl), DbStr(nModel),
                                     DbFloat(nTemp), DbInt(nTokens), DbStr(nKeyRef),
                                     DbInt(if (nEnabled) { 1 } else { 0 }),
                                     DbInt(if (nDefault) { 1 } else { 0 }),
                                     DbInt(now), DbInt(byUserId), DbInt(id)])
                } catch (e: Exception) {
                    /* 与 create 同一条口径：**只有**"确实重名了"才解释成 409，其余照旧上抛。 */
                    if (nameTaken(nName, id)) {
                        r.duplicate = true
                        return r
                    }
                    throw e
                }
                if (affected <= 0) {
                    r.notFound = true
                    return r
                }
                if (nDefault) {
                    clearOtherDefaults(nKind, id, now)
                }
                invalidate()
                r.ok = true
                r.id = id
                return r
        }
    }

    public func remove(id: Int64, now: Int64): Bool {
        let rs = db.query("SELECT id FROM ai_model WHERE id = ?", [DbInt(id)])
        if (rs.rowCount() == 0) {
            return false
        }
        let _ = db.exec("DELETE FROM ai_model WHERE id = ?", [DbInt(id)])
        invalidate()
        return true
    }
}

/* ===================== 播种（表为空时）===================== */

/*
 * 表**完全为空**时写入初始配置。两种情形分开处理：
 *
 *   ① 存量库（旧 KV 已配好 endpoint + model）⇒ 把它**搬成一条默认对话模型**。
 *      为什么：升级后 AI 必须**继续能用**。若这时什么都不建，
 *      解析逻辑虽然会回退旧 KV（所以也不会坏），但管理台上会**一条都没有** ——
 *      运维会以为"配置丢了"（体验问题，也是可解释性问题）。
 *   ② 全新库 ⇒ 写入与产品截图一致的两行示例（对话 + 向量），`enabled = 1`。
 *      ★ 2026-10-17（评审整改）：密钥引用现在**默认就有**（`ai.key_ref` 默认
 *      `builtin:demo`，见 `server/src/ai_builtin.cj`），所以全新库装完即能真调模型
 *      —— 评审原话是"默认零模型调用，智能深度无法现场证明"。两行里的 `key_ref`
 *      仍留空（= 用全局那把内置引用），换真实密钥时只改 KV 一处即可。
 *      要停用 AI，把 `ai.enabled` 置 0（`docs/Q6-合规决策记录.md` 的口径不变）。
 *
 * ⚠ 只判"表空不空"，**不覆盖任何已有行**（幂等，可重复调用）。
 */
public func aiModelSeedDefaults(repo: AiModelRepo, settings: AiSettingsRepo, now: Int64): Int64 {
    if (repo.countAll() > 0) {
        return 0
    }
    var n: Int64 = 0
    let ep = settings.get(SET_AI_ENDPOINT, now).trimAscii()
    let md = settings.get(SET_AI_MODEL, now).trimAscii()
    /*
     * ★ 2026-10-17（评审整改）：**必须同时要求"库里有这一行"**。
     *   原来只判 `ep.size > 0 && md.size > 0` —— 在默认值为空串的年代这恰好等价于
     *   "存量库配过"；现在默认值是内置 DeepSeek 端点/模型，全新库也会落到这个分支，
     *   于是只播 1 行、provider 还写"（继承自旧配置）"，向量模型直接缺失。
     *   判据改成"真有行 + 非空"，两个条件都满足才算存量配置。
     */
    if (ep.size > 0 && md.size > 0 && settings.hasRow(SET_AI_ENDPOINT) &&
        settings.hasRow(SET_AI_MODEL)) {
        let m = AiModel()
        m.name = AI_MODEL_SEED_CHAT_NAME
        m.kind = AI_MODEL_KIND_CHAT
        m.provider = "（继承自旧配置）"
        m.baseUrl = ep
        m.model = md
        m.temperature = AI_MODEL_SEED_CHAT_TEMPERATURE
        m.maxTokens = parseInt64Or(settings.get(SET_AI_MAX_TOKENS, now), AI_MODEL_SEED_MAX_TOKENS)
        m.keyRef = ""
        m.enabled = true
        m.isDefault = true
        let r = repo.create(m, now, 0)
        if (r.ok) {
            n = n + 1
        }
        return n
    }
    let chat = AiModel()
    chat.name = AI_MODEL_SEED_CHAT_NAME
    chat.kind = AI_MODEL_KIND_CHAT
    chat.provider = AI_MODEL_SEED_PROVIDER
    chat.baseUrl = AI_MODEL_SEED_BASE_URL
    chat.model = AI_MODEL_SEED_CHAT_MODEL
    chat.temperature = AI_MODEL_SEED_CHAT_TEMPERATURE
    chat.maxTokens = AI_MODEL_SEED_MAX_TOKENS
    chat.enabled = true
    chat.isDefault = true
    if (repo.create(chat, now, 0).ok) {
        n = n + 1
    }
    let emb = AiModel()
    emb.name = AI_MODEL_SEED_EMBEDDING_NAME
    emb.kind = AI_MODEL_KIND_EMBEDDING
    emb.provider = AI_MODEL_SEED_EMBEDDING_PROVIDER
    emb.baseUrl = AI_MODEL_SEED_EMBEDDING_BASE_URL
    emb.model = AI_MODEL_SEED_EMBEDDING_MODEL
    /* 向量模型没有温度语义 ⇒ 存 0（并在页面上不展示温度列，见 admin-web）。 */
    emb.temperature = 0.0
    emb.maxTokens = AI_MODEL_SEED_MAX_TOKENS
    emb.enabled = true
    emb.isDefault = true
    if (repo.create(emb, now, 0).ok) {
        n = n + 1
    }
    return n
}

/* ===================== JSON 视图 ===================== */

/*
 * 一条配置的可回显视图。
 *
 * ★★ 安全要点（与 `aiSettingsJson` 同源）：`key_ref` 是**引用**，不回显引用本体，
 *    只回"引用了没有 + 引用类型 + 生效来源（本条 / 全局）"。
 *    连 `env:变量名` 也不回：变量名会泄露部署约定（同 ai.key_ref 的处理）。
 */
public func aiModelJson(m: AiModel, globalKeyRefSet: Bool, inUse!: Bool = false): JsonObject {
    let o = JsonObject()
    o.put("id", JsonInt(m.id))
    o.put("name", JsonString(m.name))
    o.put("kind", JsonString(m.kind))
    o.put("kind_label", JsonString(aiModelKindLabel(m.kind)))
    o.put("provider", JsonString(m.provider))
    o.put("base_url", JsonString(m.baseUrl))
    /* ★ 实际会请求的 URL（派生结果）—— 排查时必须看得到它。 */
    o.put("request_url", JsonString(aiModelRequestUrl(m.baseUrl, m.kind)))
    o.put("model", JsonString(m.model))
    o.put("temperature", JsonFloat(m.temperature))
    o.put("max_tokens", JsonInt(m.maxTokens))
    let hasOwn = m.keyRef.size > 0
    o.put("key_ref_set", JsonBool(hasOwn || globalKeyRefSet))
    o.put("key_ref_kind", JsonString(aiModelKeyRefKind(m.keyRef)))
    /* 生效的密钥引用来自哪：本条配置 / 全局 ai.key_ref / 都没有。 */
    var src = ""
    if (hasOwn) {
        src = "model"
    } else if (globalKeyRefSet) {
        src = "global"
    }
    o.put("key_source", JsonString(src))
    o.put("enabled", JsonBool(m.enabled))
    o.put("is_default", JsonBool(m.isDefault))
    /*
     * ★★ `in_use`：**运行时实际会选中的那一行**（`defaultOf` 的答案）。
     *
     * 它与 `is_default` 会分叉，且分叉不是异常情况：
     *   · 默认行被停用 ⇒ defaultOf 退到"该类型第一条启用的行"
     *   · 默认行被删除 ⇒ 同上（删除不自动改嫁默认位）
     * 此时若 UI 只按 `is_default` 画「默认」标记，页面会出现
     * **一行标记都没有、但 AI 确实在用某一行**的状态 —— 用户永远找不到
     * 自己在用的到底是哪条配置，只能靠猜。所以把"谁在生效"也作为事实回给页面。
     *   口径：`is_default` = 用户指定的默认；`in_use` = 运行时真正选中的。
     */
    o.put("in_use", JsonBool(inUse))
    o.put("created_at", JsonInt(m.createdAt))
    o.put("updated_at", JsonInt(m.updatedAt))
    o.put("updated_by", JsonInt(m.updatedBy))
    return o
}

/*
 * 这一行是不是**运行时实际会选中**的那条（见 `aiModelJson` 的 `in_use` 说明）。
 * 单独抽成函数：列表、新建、修改三条回显路径都要用同一个口径算，
 * 三处各写一遍就会分叉（而"哪个在生效"正是最不能分叉的事实）。
 */
public func aiModelInUse(repo: AiModelRepo, m: AiModel, now: Int64): Bool {
    match (repo.defaultOf(m.kind, now)) {
        case Some(d) => d.id == m.id
        case None => false
    }
}

/* ===================== 连通性测试 ===================== */
/*
 * 对一条配置做**真实出站**的连通性测试。
 *
 * ★ 三个刻意的设计决定（都会体现在返回里）：
 *   ① **不受 `ai.enabled` 总开关影响**：这是**诊断**动作 ——
 *      如果测试必须先打开总开关，运维就得"先放它上线再验证"，顺序反了。
 *      （其余安全闸一个不少：https 强制 + 密钥必须能解析出来。）
 *   ② **不抛异常**：连不上是**结果**，不是服务端故障 —— 返回 `ok=false` + 原因，
 *      HTTP 仍然 200（管理台据此显示"连通性测试：失败 + 为什么"）。
 *   ③ 把**实际请求的 URL** 与**用了哪来的密钥**一起回显：
 *      排查时"到底打了哪个地址 / 用的谁的密钥"是最常被问的两件事。
 */
public func aiModelProbe(m: AiModel, settings: AiSettingsRepo, now: Int64): AiModelProbeResult {
    let out = AiModelProbeResult()
    out.kind = m.kind
    out.model = m.model
    out.requestUrl = aiModelRequestUrl(m.baseUrl, m.kind)
    var keyRef = m.keyRef.trimAscii()
    if (keyRef.size > 0) {
        out.keySource = "model"
    } else {
        keyRef = settings.get(SET_AI_KEY_REF, now).trimAscii()
        if (keyRef.size > 0) {
            out.keySource = "global"
        }
    }
    if (keyRef.size == 0) {
        out.reason = "未配置密钥引用：本条为空，且全局 `${SET_AI_KEY_REF}` 也为空。" +
            "请在本条配置里填 `env:变量名`/`file:路径`，或到「AI 设置」页配全局密钥引用"
        return out
    }
    let krWhy = validateKeyRef(keyRef)
    if (krWhy.size > 0) {
        out.reason = krWhy
        return out
    }
    let r = if (m.kind == AI_MODEL_KIND_EMBEDDING) {
        aiProbeEmbedding(out.requestUrl, m.model, keyRef, timeoutSecs: AI_MODEL_PROBE_TIMEOUT_SECS)
    } else {
        aiProbeChat(out.requestUrl, m.model, keyRef, m.temperature,
                    maxTokens: AI_MODEL_PROBE_MAX_TOKENS,
                    timeoutSecs: AI_MODEL_PROBE_TIMEOUT_SECS)
    }
    out.ok = r.ok
    out.elapsedMs = r.elapsedMs
    out.httpStatus = r.httpStatus
    out.reason = r.reason
    var s = r.text.trimAscii()
    if (s.size > AI_MODEL_PROBE_SAMPLE_MAX_CHARS) {
        s = aiModelTruncate(s, AI_MODEL_PROBE_SAMPLE_MAX_CHARS)
    }
    out.sample = s
    return out
}

/*
 * 按**字符**截断探活样本（2026-10-14 修 B5）。
 *
 * ⚠ 原实现取 `s.toArray()` —— 那是 **UInt8 字节数组**，参数名却叫 `maxChars`：
 *   中文样本（`AI_MODEL_PROBE_SAMPLE_MAX_CHARS = 160`）会在字符中间被切开，
 *   `String.fromUtf8` 得到非法 UTF-8，再往响应里塞就是坏 JSON / 前端乱码。
 *
 * 本仓对同一个坑已有三处成文证据（`triageTruncateChars` / `previsitTruncateChars`
 * 以及 `triage_redflag.cj` 的"错误做法 `for (ch in text.toArray())`"）——
 * 这里改成同一口径：逐 `Rune` 收集到第 n 个为止，天然落在字符边界上。
 */
func aiModelTruncate(s: String, maxChars: Int64): String {
    var count: Int64 = 0
    for (r in s.runes()) {
        count = count + 1
    }
    if (count <= maxChars) {
        return s
    }
    let out = ArrayList<Rune>()
    for (r in s.runes()) {
        if (out.size >= maxChars) {
            break
        }
        out.add(r)
    }
    return String(out.toArray()) + "…"
}

public func aiModelProbeJson(p: AiModelProbeResult): JsonObject {
    let o = JsonObject()
    o.put("ok", JsonBool(p.ok))
    o.put("kind", JsonString(p.kind))
    o.put("model", JsonString(p.model))
    o.put("request_url", JsonString(p.requestUrl))
    o.put("elapsed_ms", JsonInt(p.elapsedMs))
    o.put("http_status", JsonInt(p.httpStatus))
    o.put("key_source", JsonString(p.keySource))
    o.put("reason", JsonString(p.reason))
    o.put("sample", JsonString(p.sample))
    return o
}
