/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 * ai_prompt.cj —— Prompt 模板与 AI 工具开关（落库 + 缓存失效 ⇒ 改配置零重启）。
 *
 * 对外：PromptSlot / PromptRepo（body / customized / put / reset）、aiToolToggles / aiToolEnabled / aiToolSet。
 * 约束：写模板必须过长度与必需占位符校验；分诊安全尾段由代码固定拼，禁止被模板覆盖。
 */

package qingzhou

import std.collection.*
import stdx.encoding.json.*

/* Prompt 槽位契约 */

/*
 * 槽位契约：name / label / 必需占位符 / 长度上限。
 * 必需占位符在写入时校验：缺 `{主诉}` 的模板存不进去，否则模型收到空人设，不报错只是变笨。
 */
public class PromptSlot {
    public let name: String
    public let label: String
    public let required: Array<String>
    public let maxLen: Int64

    public init(name: String, label: String, required: Array<String>, maxLen: Int64) {
        this.name = name
        this.label = label
        this.required = required
        this.maxLen = maxLen
    }
}

public let PROMPT_DEPT: String = "dept"
public let PROMPT_PREVISIT: String = "previsit"
public let PROMPT_REDFLAG: String = "redflag"
/*
 * `triage` 槽位：库里模板只决定任务描述；安全尾段（不下诊断/不提药名/≤80 字/纯文本）由代码固定拼接，
 * 禁止被模板覆盖 —— 安全不变量不能交给可编辑的文本。
 */
public let PROMPT_TRIAGE: String = "triage"

/*
 * 四个槽位各对应一处真实逻辑：dept ↔ guessDepartment()、previsit ↔ previsitAssistantLines()、
 * redflag ↔ detectRedFlag()、triage ↔ 分诊转写。redflag 只作辅助，保险丝仍是纯规则。
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
                   2000),
        /* 必需 `{主诉}`/`{科室}`：模型在这里没有选科室的权力。 */
        PromptSlot(PROMPT_TRIAGE,
                   "分诊患者说明：把系统判定转写成患者能读的一两句",
                   ["{主诉}", "{科室}"],
                   2000)
    ]
}

public func promptSlotOf(name: String): ?PromptSlot {
    for (s in promptSlots()) {
        if (s.name == name) {
            return Some(s)
        }
    }
    return None
}

/*
 * 默认模板（库里没有该行时用它），刻意带齐必需占位符。
 * 分支必须用 `if (name == 常量)`，禁止 `match` + String 常量做 case 标签：
 * 常量会被当成绑定变量（catch-all），所有分支命中第一个，返回错数据且不报错。
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
    /* 只写任务、不写安全规则：安全尾段由 `aiTriagePromptWith()` 用代码拼。 */
    if (name == PROMPT_TRIAGE) {
        return "你是医院导诊助手。患者主诉：{主诉}\n" +
               "系统已按规则判定应去：{科室}\n" +
               "请用一到两句中文向患者说明：为什么会建议去这个科室、就诊前可以准备什么。"
    }
    return ""
}

/*
 * 复用 `AiSettingsRepo`：同表、同缓存失效，key 加 `prompt.` 前缀隔离命名空间。
 * 不另建表 —— 缓存失效逻辑只该有一份；代价是 aiSettingsJson() 会列出 prompt 行，按前缀过滤。
 */
public class PromptRepo {
    private let settings: AiSettingsRepo

    public init(settings: AiSettingsRepo) {
        this.settings = settings
    }

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
     * 写模板三闸门：必须登记过 / 长度按字符计 / 必需占位符必须都在；空值 = 恢复默认（删行）。
     * 失败返回 AiSettingPutResult.rejected，不抛异常。
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
            let _ = settings.remove(keyOf(name), now)
            r.ok = true
            return r
        }
        if (previsitCharLen(v) > slot.maxLen) {
            r.rejected = "模板超出长度上限 ${slot.maxLen} 字符（当前 ${previsitCharLen(v)}）"
            return r
        }
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

/* 拼接字符串数组：`Array<String>` 与 `ArrayList` 都没有 `join`（实测报错），故抽成公共函数。 */
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

/* 工具开关 */

/*
 * 工具开关契约：只做登记与开关，不做派发（派发依赖出站模型调用，尚未接入）。
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

public let AI_TOOL_KEY_PREFIX: String = "ai.tool."

/*
 * 六条只读工具，静态白名单：模型不能新增工具、不能改参数语义；默认全开，开关供运维临时关掉某条。
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

public func aiToolKnown(name: String): Bool {
    for (t in aiToolToggles()) {
        if (t.name == name) {
            return true
        }
    }
    return false
}

public func aiToolDefaultOn(name: String): Bool {
    for (t in aiToolToggles()) {
        if (t.name == name) {
            return t.defaultOn
        }
    }
    return false
}

/*
 * 工具可用性的唯一判据：未登记 ⇒ 不可用；无行 ⇒ 默认值；只有明确 `1` 才开，其余值（0/空/垃圾）⇒ 关。
 * 失败方向选安全一侧：写坏的值只会让工具被关，而非静默放宽。
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

/* 只接受 `0`/`1`（不收 true/on/yes）；未知工具 → rejected。 */
public func aiToolSet(settings: AiSettingsRepo, name: String, on: Bool, now: Int64): AiSettingPutResult {
    let r = AiSettingPutResult()
    if (!aiToolKnown(name)) {
        r.rejected = "未知的 AI 工具：${name}（只有登记过的工具才能开关）"
        return r
    }
    return settings.put(AI_TOOL_KEY_PREFIX + name, if (on) { "1" } else { "0" }, now)
}

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
