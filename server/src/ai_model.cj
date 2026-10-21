/*
 * ai_model 表（命名模型配置）的仓储、校验与连通性测试。
 * 对外：AiModel、AiModelWriteOutcome、AiModelProbeResult，仓储 AiModelRepo（list/get/defaultOf/
 * create/update/remove/invalidate），aiModelValidate、aiModelRequestUrl、aiModelProbe、
 * aiModelSeedDefaults、aiModelJson。
 *
 * 约束：key_ref 只存引用（env:/file:/builtin:），密钥本体禁止入库；base_url 必须 https://；
 * 改配置立即失效缓存，下一次 AI 请求动态构建实例，不需重启。
 */
package qingzhou

import std.collection.*
import stdx.encoding.json.*
import std.sync.*

/* 常量 */

public let AI_MODEL_KIND_CHAT: String = "CHAT"
public let AI_MODEL_KIND_EMBEDDING: String = "EMBEDDING"

public let AI_MODEL_NAME_MAX_CHARS: Int64 = 64
public let AI_MODEL_PROVIDER_MAX_CHARS: Int64 = 64
public let AI_MODEL_BASE_URL_MAX_CHARS: Int64 = 512
public let AI_MODEL_MODEL_MAX_CHARS: Int64 = 128
public let AI_MODEL_KEY_REF_MAX_CHARS: Int64 = 512

/* 温度 0..2（OpenAI 兼容协议取值范围）；与 max_tokens 的 64..8192 一样，必须在写入那一刻拦住：
 * 写成 30 不报错，只会让输出变成胡言乱语。 */
public let AI_MODEL_TEMPERATURE_MIN: Float64 = 0.0
public let AI_MODEL_TEMPERATURE_MAX: Float64 = 2.0
public let AI_MODEL_MAX_TOKENS_MIN: Int64 = 64
public let AI_MODEL_MAX_TOKENS_MAX: Int64 = 8192

/* 与 AI_SETTINGS_CACHE_TTL_SECS 同口径：写操作主动失效，多实例靠 TTL 收敛。 */
public let AI_MODEL_CACHE_TTL_SECS: Int64 = 5

/* 连通性测试超时：比业务调用短，因为这是人在等的一次交互。 */
public let AI_MODEL_PROBE_TIMEOUT_SECS: Int64 = 15
public let AI_MODEL_PROBE_MAX_TOKENS: Int64 = 8
public let AI_MODEL_PROBE_SAMPLE_MAX_CHARS: Int64 = 160

public let AI_MODEL_LIST_DEFAULT_LIMIT: Int64 = 50
public let AI_MODEL_LIST_MAX_LIMIT: Int64 = 200

/* 列顺序一处定义：SELECT 与行解析共用，避免"加了列忘了改解析"。 */
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
 * 播种用的默认两行（只在表完全为空时写入）。对话指向 DeepSeek（与 ai_builtin.cj 的内置演示凭据配套）；
 * 向量仍指百练 —— DeepSeek 无 /embeddings 端点，硬指过去只会 404，故不假装能用。
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
 * 写操作结果。用字段区分失败原因而非抛异常：一个异常类型表达不了 400/404/409 三种 HTTP 状态。
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

/* 连通性测试结果（不抛异常：测试失败是"结果"，不是服务端故障）。 */
public class AiModelProbeResult {
    public var ok: Bool = false
    public var kind: String = ""
    public var requestUrl: String = ""
    public var model: String = ""
    public var elapsedMs: Int64 = 0
    public var httpStatus: Int64 = 0
    public var reason: String = ""
    public var sample: String = ""
    /* 密钥来自哪里：model / global / ""。 */
    public var keySource: String = ""

    public init() {}
}

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
 * 文本字段检查：非空 / 限长 / 不许含控制字符。最后一条是安全边界 —— base_url 会被拼进 URL，
 * 一个换行就能注入额外的请求头（CRLF injection）。
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

/* 校验一条配置：返回 "" = 通过，否则是可直接给运维看的原因。只读配置、不出站（连不连得上归 aiModelProbe）。 */
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
    /* 强制 https：明文调用大模型 = 密钥裸奔，且必须在这里更早拦住，而不是等运行时。 */
    if (!startsWithAscii(url.toAsciiLower(), "https://")) {
        return "接口地址必须是 https://（明文调用大模型 = 密钥裸奔）"
    }
    why = aiModelCheckText(model.trimAscii(), "模型名称", AI_MODEL_MODEL_MAX_CHARS, false)
    if (why.size > 0) {
        return why
    }
    /* NaN 必须单独拦：NaN 与任何数比较都为 false，能穿过 t < min || t > max 的范围判断；
     * 自己与自己比较是唯一可靠的 NaN 判定。 */
    if (temperature != temperature) {
        return "温度不能是 NaN"
    }
    if (temperature < AI_MODEL_TEMPERATURE_MIN || temperature > AI_MODEL_TEMPERATURE_MAX) {
        return "温度必须在 ${AI_MODEL_TEMPERATURE_MIN}..${AI_MODEL_TEMPERATURE_MAX} 之间（收到 ${temperature}）"
    }
    if (maxTokens < AI_MODEL_MAX_TOKENS_MIN || maxTokens > AI_MODEL_MAX_TOKENS_MAX) {
        return "max_tokens 必须在 ${AI_MODEL_MAX_TOKENS_MIN}..${AI_MODEL_MAX_TOKENS_MAX} 之间（收到 ${maxTokens}）"
    }
    /* 密钥引用可留空（回退全局 ai.key_ref）；填了就必须合法，校验复用 validateKeyRef —— 引用形状只允许一处定义。 */
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

/* 密钥引用的类型（env / file / builtin / ""），不回显引用本体（同 aiSettingsJson 的纪律）。 */
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
 * 由 base_url + 类型派生真正的请求 URL。运维两种填法都认：结尾已是 /chat/completions（CHAT）或
 * /embeddings（EMBEDDING）⇒ 原样用，否则追加；末尾多余的 / 先去掉（否则拼出 //）。
 * 派生结果回显为 request_url 并进连通性结论：实际打了哪个地址必须能从管理台看到。
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
 * 后缀判断（stdx 无 ascii 版 endsWith）。逐字节比较：后缀全是 ascii，故字节数 = 字符数。
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
 * 模型配置仓储。读走内存缓存（避免每个 AI 请求都查库），写主动失效：invalidate() 只置 cacheAt = 0，
 * 下一次读自然重查，这样"写"与"刷新"不会各写一半。
 * 多实例部署靠 AI_MODEL_CACHE_TTL_SECS 秒后收敛（无共享失效通道，不假装有）。
 */
public class AiModelRepo {
    private let db: DbBackend
    /*
     * 缓存必须与 AiSettingsRepo 同款加锁：ensureCache 给共享 cache 赋值，list/get/defaultOf 同时迭代它。
     * 锁序一致（仓储锁 → 数据库连接锁，可重入）：写操作在 db.exec 返回后才 invalidate()，不反向获取。
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
     * 解析某类型的生效模型：① enabled=1 AND is_default=1（多条取 id 最小）② 否则该类型第一条启用的
     * ③ 都没有 ⇒ None，调用方回退旧 KV（见 ai_settings.cj 的 aiRuntimeResolve）。
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

    /* "某类型只应有一条默认"是集合级不变量：用确定性规则（defaultOf 取 id 最小）兜住一个非原子写入，不引入项目里还没有的事务。 */
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
         * 唯一键冲突要接住并回 409，而不是 500：上面 nameTaken 是先查后写，两个请求同时插入时，真正的唯一性由
         * uk_ai_model_name 保证，第二个 INSERT 抛驱动异常。500 让人去翻日志，409 让人改名重试。
         */
        var id: Int64 = 0
        try {
            /* 用 execInsert 而非 exec + SELECT LAST_INSERT_ID()：exec/query 不保证同一条连接，
             * 分开调用会读到别的连接的自增值或 0，表现是"新建成功但 id=0"，接着 clearOtherDefaults 会误判所有行。 */
            id = db.execInsert("INSERT INTO ai_model (name, kind, provider, base_url, model, temperature, " +
                               "max_tokens, key_ref, enabled, is_default, created_at, updated_at, updated_by) " +
                               "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                               [DbStr(name), DbStr(kind), DbStr(provider), DbStr(url), DbStr(model),
                                DbFloat(m.temperature), DbInt(m.maxTokens), DbStr(keyRef),
                                DbInt(if (m.enabled) { 1 } else { 0 }),
                                DbInt(if (m.isDefault) { 1 } else { 0 }),
                                DbInt(now), DbInt(now), DbInt(byUserId)])
        } catch (e: Exception) {
            /* 只把"确实重名"解释成 409，其余异常照旧上抛（退化为 500）：否则真故障会被显示成"改个名字再试"。 */
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
     * 语义是 PATCH（缺省 = 保持原值）而非 PUT：一次"只想改温度"的保存不能把 key_ref 清空，
     * 清空后 AI 静默不可用（表现是"AI 突然不工作了"）。
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
                 * 不许把 UPDATE 的影响行数丢进 let _：该行可能在 get() 与 UPDATE 之间被删掉，影响 0 行仍回 200
                 * = 响应在撒谎。0 行受影响 ⇒ 当"没这行"处理（404），由调用方映射成 AI_MODEL_NOT_FOUND。
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
                    /* 与 create 同一条口径：只有"确实重名了"才解释成 409，其余照旧上抛。 */
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

/*
 * 表完全为空时写入初始配置（幂等，可重复调用，不覆盖任何已有行）。
 * 存量库（旧 KV 已配 endpoint + model）⇒ 搬成一条默认对话模型：否则管理台一条都没有，运维会以为配置丢了。
 * 全新库 ⇒ 写对话 + 向量两行示例。要停用 AI，把 ai.enabled 置 0。
 */
public func aiModelSeedDefaults(repo: AiModelRepo, settings: AiSettingsRepo, now: Int64): Int64 {
    if (repo.countAll() > 0) {
        return 0
    }
    var n: Int64 = 0
    let ep = settings.get(SET_AI_ENDPOINT, now).trimAscii()
    let md = settings.get(SET_AI_MODEL, now).trimAscii()
    /* 必须同时要求"库里有这一行"：只判非空的话，默认值非空的今天会让全新库落到存量分支，
     * 只播 1 行且向量模型缺失。 */
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
    /* 向量模型没有温度语义 ⇒ 存 0（页面上也不展示温度列）。 */
    emb.temperature = 0.0
    emb.maxTokens = AI_MODEL_SEED_MAX_TOKENS
    emb.enabled = true
    emb.isDefault = true
    if (repo.create(emb, now, 0).ok) {
        n = n + 1
    }
    return n
}

/*
 * 一条配置的可回显视图。key_ref 是引用，不回显本体：只给 key_ref_set / key_ref_kind / key_source。
 * 连 env:变量名 也不回 —— 变量名会泄露部署约定（同 ai.key_ref 的处理）。
 */
public func aiModelJson(m: AiModel, globalKeyRefSet: Bool, inUse!: Bool = false): JsonObject {
    let o = JsonObject()
    o.put("id", JsonInt(m.id))
    o.put("name", JsonString(m.name))
    o.put("kind", JsonString(m.kind))
    o.put("kind_label", JsonString(aiModelKindLabel(m.kind)))
    o.put("provider", JsonString(m.provider))
    o.put("base_url", JsonString(m.baseUrl))
    /* 实际会请求的 URL（派生结果）—— 排查时必须看得到它。 */
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
     * in_use = 运行时实际会选中的那一行（defaultOf 的答案），与 is_default 会分叉：默认行被停用或被删除时，
     * UI 只按 is_default 画标记会出现"一行标记都没有、但 AI 确实在用某一行"。口径：is_default = 用户指定，
     * in_use = 运行时真正选中。
     */
    o.put("in_use", JsonBool(inUse))
    o.put("created_at", JsonInt(m.createdAt))
    o.put("updated_at", JsonInt(m.updatedAt))
    o.put("updated_by", JsonInt(m.updatedBy))
    return o
}

/* 这一行是不是运行时实际会选中的那条：列表/新建/修改三条回显路径共用同一口径，各写一遍会分叉。 */
public func aiModelInUse(repo: AiModelRepo, m: AiModel, now: Int64): Bool {
    match (repo.defaultOf(m.kind, now)) {
        case Some(d) => d.id == m.id
        case None => false
    }
}

/*
 * 真实出站的连通性测试。① 不受 ai.enabled 总开关影响：这是诊断动作，否则运维得先上线再验证；
 * ② 不抛异常：连不上是结果不是故障（ok=false + reason，HTTP 仍 200）；
 * ③ 回显实际请求 URL 与用了哪来的密钥。
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
 * 按字符截断探活样本：s.toArray() 是 UInt8 字节数组，会在中文字符中间切开，得到非法 UTF-8；
 * 改逐 Rune 收集，天然落在字符边界上。
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
