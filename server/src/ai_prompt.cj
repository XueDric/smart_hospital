/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 *
 * ===== ai_prompt.cj —— P3 第二块：Prompt 模板 + 工具开关（都落库、都零重启）=====
 *
 * 补的是 brief §2.2 创新点① 的另两部分（第一块「配置底座」在 ai_settings.cj）：
 *   · **Prompt 模板落库** —— 参考系统里 Prompt 在 `h_ai.cj` 里**硬编码**，
 *     改一句话要重编译重启；这里落库 + 缓存失效 ⇒ **改模板零重启**。
 *   · **工具开关落库** —— 哪些 AI 工具启用/禁用可在线调整。
 *
 * ── 本文件遵守的两条既有纪律 ──────────────────────────────────────────────
 *   ① **同一语义只留一处实现**：缓存与"失效"复用 `AiSettingsRepo`，
 *      不另造一套。Prompt 只用**独立的命名空间**（`prompt.*` 前缀）与它共用同一张表。
 *   ② **写路径严格**：模板必须过"长度上限 + 必需占位符"校验，不合法直接拒。
 *
 * ⚠⚠ **边界（必须说清，否则会被误读成"AI 已接通"）**：
 *   本轮仍未接真模型（Q6 合规待决）。所以这里的 Prompt 模板与工具开关
 *   都是**机制**：它们能存、能改、能零重启生效、能被校验；
 *   但**还没有任何出站代码去消费它们**（没有 `ai_client`）。
 *   接上模型时，拼 prompt 的地方改成 `aiPromptGet("triage", 变量表)`、
 *   派发工具的地方改成先查 `aiToolEnabled(name)` —— 两行接入点已经备好。
 */

package qingzhou

import std.collection.*
import stdx.encoding.json.*

/* ===================== Prompt 用途登记表（静态白名单）===================== */

/*
 * 一处 Prompt 的"契约"：它叫什么、给谁用、**必须**含哪些占位符。
 *
 * ⚠ 为什么要有"必需占位符"这一列（而不是只做长度校验）：
 *   Prompt 模板最容易出的错是"**漏了变量**" —— 改了模板、忘了留 `{主诉}`，
 *   模型收到一段没有患者信息的空白人设，输出看起来正常但完全没用。
 *   这种错**不报错、不崩溃**，只是"AI 变笨了"，最难查。
 *   ⇒ 所以把"必需占位符"写成契约，写入时就校验：
 *     缺 `{主诉}` 的模板**根本存不进去**。
 *
 * ⚠ 占位符语法用 `{名字}`（花括号 + 中文名），与参考系统一致；
 *   校验是**纯字符串包含**（不做模板引擎）—— 因为最终拼装仍是代码做的，
 *   这里只保证"该有的洞都在"。
 */
public class PromptSlot {
    public let name: String
    public let label: String
    /* 必需占位符（含花括号），缺一个就不让存。 */
    public let required: Array<String>
    /* 模板长度上限（字符）。 */
    public let maxLen: Int64

    public init(name: String, label: String, required: Array<String>, maxLen: Int64) {
        this.name = name
        this.label = label
        this.required = required
        this.maxLen = maxLen
    }
}

/* Prompt 名的常量（免得字符串散落各处拼错）。 */
public let PROMPT_DEPT: String = "dept"
public let PROMPT_PREVISIT: String = "previsit"
public let PROMPT_REDFLAG: String = "redflag"

/*
 * 三处 Prompt 的登记表。
 *
 * ⚠ 每一项都对应**本项目已有的一处真实逻辑**，不是凭空造的：
 *   · `dept`     ↔ `guessDepartment()`（关键词规则做的科室判定）
 *   · `previsit` ↔ `previsitAssistantLines()`（规则生成的追问话术）
 *   · `redflag`  ↔ `detectRedFlag()`（规则做的危急征象判定）
 *   这三处正是"接上模型时要替换/增强"的点 ——
 *   所以把它们的 Prompt 先做成可配置的，接模型时不必再改表结构。
 *
 * ⚠ `redflag` 那条的必需占位符只有 `{主诉}`：它的定位是**辅助**，
 *   而**保险丝本身仍是纯规则**（见 triage_redflag.cj 文件头）——
 *   绝不能让"模型是否认得出危急"变成唯一防线。
 */
public func promptSlots(): Array<PromptSlot> {
    return [
        PromptSlot(PROMPT_DEPT,
                   "科室判定：由主诉推断应就诊科室",
                   ["{主诉}", "{候选科室}"],
                   4000),
        PromptSlot(PROMPT_PREVISIT,
                   "预问诊追问：生成下一句追问话术",
                   ["{主诉}", "{已有信息}", "{待问项}"],
                   4000),
        PromptSlot(PROMPT_REDFLAG,
                   "危急征象辅助识别（⚠ 只是辅助；真正的保险丝是纯规则）",
                   ["{主诉}"],
                   2000)
    ]
}

/* 找某 Prompt 的契约；未登记返回 None。 */
public func promptSlotOf(name: String): ?PromptSlot {
    for (s in promptSlots()) {
        if (s.name == name) {
            return Some(s)
        }
    }
    return None
}

/*
 * 默认模板（库里没有该行时用它）。刻意带齐必需占位符 —— 保证默认值本身合法。
 *
 * ⚠⚠ **这里刻意用 `if (name == 常量)` 而不是 `match`** —— 这是一个**实测踩出来的
 *   语言陷阱**（第七份复查之后我自己抓到的）：
 *
 *   我原来写的是
 *       match (name) {
 *           case PROMPT_DEPT => return "..."
 *           case PROMPT_PREVISIT => return "..."
 *           case PROMPT_REDFLAG => return "..."
 *           case _ => return ""
 *       }
 *   而 `PROMPT_DEPT` 是 **String 常量**。探针实测（`match(x) { case A => ... }`
 *   with `let A: String = "dept"`）：
 *       match(A)   -> 命中 case A     ✓
 *       match(B)   -> **也命中 case A**  ✗   （B = "previsit"）
 *       match("zzz") -> **还是命中 case A** ✗
 *   ⇒ **String 常量在 case 里被当成"绑定变量"（catch-all），按值比较根本不发生。**
 *     于是 `promptDefaultBody(PREVISIT)` 一直返回 **dept 的模板**。
 *
 *   ⚠ 危害形态：**不报错、不崩溃，只是返回错的数据**。
 *     我是被"默认模板必须含齐自己的占位符"这条断言抓出来的
 *     （previsit 的模板缺 `{已有信息}`/`{待问项}`）—— 断言写在**值**上，
 *     才照出了这个"看起来对"的实现。
 *
 *   ⚠ 为什么 `case None` / `case Patient` 那些没问题：它们是
 *     **枚举构造子 / Option 构造子**，不是 String 常量，按值匹配正常。
 *     全仓扫过：只有本文件这三处是"String 常量当 case 标签"。
 *
 *   ⇒ 结论：**String 的分支判断一律用 `==`，不要用 `match` + 常量标签。**
 *     已记进 server/README.md 踩坑表。
 */
public func promptDefaultBody(name: String): String {
    if (name == PROMPT_DEPT) {
        return "你是医院导诊助手。患者主诉：{主诉}\n" +
               "可推荐的科室：{候选科室}\n" +
               "请只输出一个 JSON：{\"dept\":\"科室名\",\"reason\":\"一句话依据\"}。\n" +
               "⚠ 只能从上面的候选科室里选，不要编造本院没有的科室。"
    }
    if (name == PROMPT_PREVISIT) {
        return "你是门诊预问诊助手。患者主诉：{主诉}\n" +
               "已采集信息：{已有信息}\n" +
               "本次要问的一项是：{待问项}\n" +
               "请用一句自然、口语化的中文追问，不要一次问多项，不要给诊断结论。"
    }
    if (name == PROMPT_REDFLAG) {
        return "请判断下面主诉里是否出现需要立即就医的危急征象：{主诉}\n" +
               "只输出 {\"red_flag\":true/false,\"hit\":\"命中的表述\"}。"
    }
    return ""
}

/* ===================== Prompt 仓储 ===================== */

/*
 * Prompt 仓储 —— **复用 `AiSettingsRepo`**（同一张表、同一套缓存与失效），
 * 只是把 key 加上 `prompt.` 前缀做**命名空间隔离**。
 *
 * ⚠ 为什么复用而不是另建一张表 + 另一套缓存（这是刻意的设计选择）：
 *   · 另建一套 = 又一次"同一件事两处实现"（本项目的反复病）；
 *   · 缓存失效的逻辑（写后置 0、TTL 兜底多实例）只该有**一份**；
 *   · KV 表的语义本来就适合"按需增删的配置项"。
 *   代价：`aiSettingsJson()` 会把 prompt 行也列出来（用前缀过滤即可，见下）。
 */
public class PromptRepo {
    private let settings: AiSettingsRepo

    public init(settings: AiSettingsRepo) {
        this.settings = settings
    }

    /* key 前缀（命名空间）。 */
    private func keyOf(name: String): String {
        return "prompt.${name}"
    }

    /* 取模板正文；未配置则返回默认模板。 */
    public func body(name: String, now: Int64): String {
        let v = settings.get(keyOf(name), now)
        if (v.size > 0) {
            return v
        }
        return promptDefaultBody(name)
    }

    /* 该模板是否是"被管理员改过"的（false = 用的默认模板）。 */
    public func customized(name: String, now: Int64): Bool {
        return settings.get(keyOf(name), now).size > 0
    }

    /*
     * ★★ 写模板 —— 三道闸门（与 `ai.key_ref` 的"写入即校验"同一纪律）。
     *
     * ① **必须是登记过的 Prompt**（否则 KV 表会变垃圾场）；
     * ② **长度上限**（按**字符**数，不按字节 —— 按字节会误伤中文，见 previsit 的教训）；
     * ③ ★ **必需占位符必须都在**（缺 `{主诉}` 的模板根本存不进去）。
     *   这条是"防 AI 变笨"的机制：漏了变量的模板**不报错也不崩溃**，
     *   只是输出变得没用 —— 那是最难查的一类故障。
     *
     * ⚠ 空值 = 恢复默认模板（显式例外，与数值项同一口径）。
     */
    public func put(name: String, body: String, now: Int64): AiSettingPutResult {
        let r = AiSettingPutResult()
        let slot = match (promptSlotOf(name)) {
            case Some(s) => s
            case None =>
                r.rejected = "未知的 Prompt：${name}（只有登记过的才能写）"
                return r
        }
        let v = body.trimAscii()
        if (v.size == 0) {
            // 空 = 恢复默认：直接删行（比存空串更干净，也让 customized() 正确返回 false）
            let _ = settings.remove(keyOf(name), now)
            r.ok = true
            return r
        }
        if (previsitCharLen(v) > slot.maxLen) {
            r.rejected = "模板超出长度上限 ${slot.maxLen} 字符（当前 ${previsitCharLen(v)}）"
            return r
        }
        // ③ 必需占位符
        var missing = ArrayList<String>()
        for (ph in slot.required) {
            if (!v.contains(ph)) {
                missing.add(ph)
            }
        }
        if (missing.size > 0) {
            r.rejected = "模板缺少必需占位符：${joinStrings(missing.toArray(), "、")} —— " +
                         "漏了变量的模板不会报错，只会让输出变得没用（最难查的一类问题）"
            return r
        }
        return settings.put(keyOf(name), v, now)
    }

    /* 恢复默认模板（删行）。 */
    public func reset(name: String, now: Int64): Bool {
        if (promptSlotOf(name).isNone()) {
            return false
        }
        return settings.remove(keyOf(name), now)
    }
}

/*
 * 把字符串数组用分隔符连起来。
 *
 * ⚠ 自己写是因为 `Array<String>` **没有** `join`（实测报
 *   `'join' is not a member of struct 'Array<Struct-String>'`），
 *   而 `ArrayList` 也没有 —— 本项目已因此手写过两次（见 triage_redflag.cj）。
 *   抽成一个公共函数，避免第三次。
 */
public func joinStrings(a: Array<String>, sep: String): String {
    var s = ""
    var first = true
    for (x in a) {
        if (!first) {
            s = s + sep
        }
        s = s + x
        first = false
    }
    return s
}

/* ===================== 工具开关 ===================== */

/*
 * 一个 AI 工具的开关契约。
 *
 * ⚠⚠ 这里**只做登记与开关**，不做派发 —— 因为工具的执行依赖出站模型调用，
 *   而本轮仍未接模型。如实标注：这是**开关机制**，不是"AI 工具已可用"。
 *   接上模型时：派发前查 `aiToolEnabled(name)` 即可（接入点已备好）。
 */
public class AiToolToggle {
    public let name: String
    public let label: String
    /* 默认是否启用（**默认全开** —— 参考系统口径：工具白名单里列出的就可用）。 */
    public let defaultOn: Bool

    public init(name: String, label: String, defaultOn!: Bool = true) {
        this.name = name
        this.label = label
        this.defaultOn = defaultOn
    }
}

/* 工具开关的 key 前缀。 */
public let AI_TOOL_KEY_PREFIX: String = "ai.tool."

/*
 * 六条**只读**工具 —— 照搬迁前的 `aiToolSpecs()` 的"静态白名单"纪律：
 *   模型既不能新增工具，也不能改参数语义。
 *
 * ⚠ 全部 `defaultOn = true`：白名单里列出的默认可用。
 *   开关的意义是"**运维能临时关掉某条**"（例如某个工具在院内部署里不适用），
 *   而不是"默认关着等你去开"（那会让接上模型后所有人默认没工具可用）。
 */
public func aiToolToggles(): Array<AiToolToggle> {
    return [
        AiToolToggle("list_departments", "列本院科室（分诊用）"),
        AiToolToggle("bookable_slots", "查某科室**当前可挂号**的号源（分诊的验证层依赖它）"),
        AiToolToggle("doctor_specialty", "查医生专长（用于推荐医生）"),
        AiToolToggle("redflag_scan", "危急征象扫描（⚠ 真正的保险丝是纯规则，这条只是辅助）"),
        AiToolToggle("intake_slots", "列预问诊待采集项"),
        AiToolToggle("patient_history", "查**本人**既往问诊单（⚠ 只读自己，不接受 patient_id 参数）")
    ]
}

/* 某工具是否登记过。 */
public func aiToolKnown(name: String): Bool {
    for (t in aiToolToggles()) {
        if (t.name == name) {
            return true
        }
    }
    return false
}

/* 取某工具的默认开关。 */
public func aiToolDefaultOn(name: String): Bool {
    for (t in aiToolToggles()) {
        if (t.name == name) {
            return t.defaultOn
        }
    }
    return false
}

/*
 * ★★ **工具是否可用** —— 这是工具开关的**唯一判据**（派发前必须走它）。
 *
 * 语义（三条，都要说清）：
 *   ① 未登记的工具 ⇒ **不可用**（白名单纪律：模型不能新增工具）；
 *   ② 库里没该行 ⇒ 用默认值（默认全开）；
 *   ③ 库里存 `1` ⇒ 开；存**其它任何值**（含 `0`/空/垃圾）⇒ **关**。
 *      ⚠ 第 ③ 条刻意**从严**：只有明确的 `1` 才算开。
 *        反过来（"只要不是 0 就算开"）会让一个写坏的值（如 `abc`）变成"开着"，
 *        那是**静默放宽**；而从严的失败方向是"工具被关掉"——可见、可查、无害。
 *        📌 这与 ADR/限流那几处的取舍一致：**失败方向要选安全的那一侧**。
 */
public func aiToolEnabled(settings: AiSettingsRepo, name: String, now: Int64): Bool {
    if (!aiToolKnown(name)) {
        return false
    }
    let v = settings.get(AI_TOOL_KEY_PREFIX + name, now).trimAscii()
    if (v.size == 0) {
        return aiToolDefaultOn(name)
    }
    return v == "1"
}

/* 已启用的工具数（给运营看板/自检用）。 */
public func aiToolEnabledCount(settings: AiSettingsRepo, now: Int64): Int64 {
    var n: Int64 = 0
    for (t in aiToolToggles()) {
        if (aiToolEnabled(settings, t.name, now)) {
            n = n + 1
        }
    }
    return n
}

/*
 * 设置某工具的开关。
 *
 * ⚠ 只接受 `0` / `1` 两个值（不接受 "true"/"on"/"yes" 之类）：
 *   多一种写法就多一处口径，而"开关只有两态"这件事没必要给用户表达空间。
 */
public func aiToolSet(settings: AiSettingsRepo, name: String, on: Bool, now: Int64): AiSettingPutResult {
    let r = AiSettingPutResult()
    if (!aiToolKnown(name)) {
        r.rejected = "未知的 AI 工具：${name}（只有登记过的工具才能开关）"
        return r
    }
    return settings.put(AI_TOOL_KEY_PREFIX + name, if (on) { "1" } else { "0" }, now)
}

/* ===================== 视图（给接口/运维看）===================== */

/* Prompt 使用情况（正文**原样给出** —— 它不是机密，且管理员要能核对）。 */
public func aiPromptsJson(repo: PromptRepo, now: Int64): JsonObject {
    let arr = ArrayList<JsonValue>()
    for (s in promptSlots()) {
        let e = JsonObject()
        e.put("name", JsonString(s.name))
        e.put("label", JsonString(s.label))
        e.put("required", JsonArray(s.required.map({ x => JsonString(x) })))
        e.put("max_len", JsonInt(s.maxLen))
        e.put("customized", JsonBool(repo.customized(s.name, now)))
        e.put("body", JsonString(repo.body(s.name, now)))
        arr.add(e)
    }
    let o = JsonObject()
    o.put("prompts", JsonArray(arr.toArray()))
    return o
}

/* 工具开关视图。 */
public func aiToolsJson(settings: AiSettingsRepo, now: Int64): JsonObject {
    let arr = ArrayList<JsonValue>()
    for (t in aiToolToggles()) {
        let e = JsonObject()
        e.put("name", JsonString(t.name))
        e.put("label", JsonString(t.label))
        e.put("default_on", JsonBool(t.defaultOn))
        e.put("enabled", JsonBool(aiToolEnabled(settings, t.name, now)))
        arr.add(e)
    }
    let o = JsonObject()
    o.put("tools", JsonArray(arr.toArray()))
    o.put("count_enabled", JsonInt(aiToolEnabledCount(settings, now)))
    return o
}
