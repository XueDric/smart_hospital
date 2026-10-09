package qingzhou

import std.collection.*
import stdx.encoding.json.*

/*
 * SPDX-License-Identifier: MIT
 *
 * ===== ai_triage.cj —— 把真模型接到分诊上（**增强层**）=============
 *
 * ## 这个文件存在的唯一理由：把"模型能改什么"钉死在类型层面
 *
 * 函数签名 `aiEnhanceTriage(v: TriageVerdict, ...)` 收的是 `TriageVerdict`，
 * 而它**只写两个字段**：`v.aiNote` 与 `v.aiReason`。
 *
 * ⚠⚠ **它绝不碰 `v.options`** —— 科室、排班、号源全部由 `triageComplaint()`
 *   （规则 + 数据库）决定，模型一个字节都改不了。
 *   这不是"我小心一点"，而是**结构上做不到**：本文件里没有对 `v.options`
 *   的任何赋值，连能构造 `TriageOption` 的途径都没有。
 *
 * ⇒ 于是 P2 立的硬性验证层「**绝不给没有号的推荐**」在接上模型之后**依然成立**，
 *   而且**不可能被绕过**。这一点很要紧：模型幻觉推荐一个没号的科室，是比规则
 *   出错**更危险**的失败 —— 它看起来很有道理，患者会照做，然后挂不上号。
 *
 * ---------------------------------------------------------------------------
 * ## 为什么"模型的输出"必须**校验**而不能直接透传
 *
 * 模型是不可信输入源（和 HTTP 请求体一样）。它会：
 *   · 输出 Markdown 标题/列表 ⇒ 前端按纯文本渲染会看到一堆 `##`
 *   · 输出"建议服用 XXX 5mg" ⇒ **这是医疗建议**，本项目绝不能给
 *   · 输出几百字论文 ⇒ 患者不会读
 *   · 输出空 / 复述 Prompt
 * ⇒ `aiSanitizeNote()` 做**白名单式**清理：只留一行、限长、去掉 Markdown 标记、
 *   并在发现**疑似诊断/用药**时**整条丢弃**（回退规则文案）。
 *   📌 丢弃而不是"改一改"：我们**没有能力**把一句医疗建议改成安全的，
 *     能做的是**不让它出去**。
 */

/* 模型给患者的说明最长多少**字符**（不是字节 —— 本仓踩过三次这个坑）。 */
public let AI_NOTE_MAX_CHARS: Int64 = 160

/* 命中这些词就**整条丢弃**模型输出（疑似诊断/用药/剂量）。 */
public let AI_NOTE_DENY: Array<String> = [
    "mg", "毫克", "克", "片", "粒", "支", "剂量", "服用", "口服", "注射", "静脉",
    "处方", "开药", "吃药", "用法用量", "每日", "一日", "一次",
    "诊断为", "确诊", "你得了", "您得了", "患的是", "可能是癌", "肿瘤",
    "手术", "化疗", "放疗", "输液",
    /*
     * ⚠ 英文剂量单位也拦：模型常写 "take 500 mg" 或 "2 tablets"。
     *   `tablet`/`capsule`/`dose`/`prescription` 同理。
     */
    "tablet", "capsule", "dose", "prescription", "take ", "twice daily",
]

/*
 * 把一个**已被规则引擎判定的**结论做模型增强。
 *
 * ⚠ 本函数**不抛异常**（模型调用已在上游被包住，这里再做一层防御）：
 *   它是分诊响应路径上的一环，任何异常都会变成患者看到 500。
 */
public func aiEnhanceTriage(v: TriageVerdict, complaint: String,
                            aiSettings: AiSettingsRepo, now: Int64): Unit {
    /*
     * ① 危急征象 ⇒ **不调模型**。
     *   理由：这时患者最需要的是"立刻就医"四个字，而不是一段更通顺的解释。
     *   多一次网络往返只会延迟它，收益为零、风险为正（网络抖动还会让人以为系统坏了）。
     */
    if (v.redFlag) {
        v.aiReason = "危急征象：优先让患者立刻看到处置建议，不进模型"
        return
    }
    /*
     * ⚠⚠ 这里**不再**放"工具开关"这道闸 —— 我原先写了一道，是**理解错了 P3**：
     *
     *   `ai.tool.*` 那六个开关（`list_departments` / `bookable_slots` /
     *   `doctor_specialty` / `redflag_scan` / `intake_slots` / `patient_history`）
     *   是**模型可调用的只读能力白名单**，**不是**"分诊这个功能要不要用 AI"的功能开关。
     *   而 `aiToolEnabled(settings, name, now)` 对**未登记**的名字**返回 false** ——
     *   所以我原先那句 `aiToolEnabled(aiSettings, AI_TOOL_TRIAGE, ...)`
     *   （`AI_TOOL_TRIAGE` 这个常量**根本不存在**）会把模型**静默关掉**：
     *   表现是"配好了却永远走规则"，而**没有任何错误信息** ——
     *   这正是本项目最忌的失败形态（"看起来对，实际没生效"）。
     *
     * ⇒ 本函数的开关就是 `ai.enabled` + `aiCanCall()`（配置齐不齐）。
     *   若将来真要"分诊单独关 AI"，那应当**新增一个功能开关键**
     *   （例如 `ai.feature.triage`），而不是挪用工具白名单。
     */
    var opts: AiRuntimeOptions
    try {
        opts = aiSettings.options(now)
    } catch (e: Exception) {
        /* 读配置失败 ⇒ 降级，不把分诊搞挂。 */
        v.aiReason = "读取 AI 配置失败，已降级为规则"
        return
    }
    let (can, why) = aiCanCall(opts)
    if (!can) {
        v.aiReason = why
        return
    }
    /*
     * ③ 组 Prompt。
     *   ⚠ 只给模型**规则已经算好的事实**（命中的科室名），**不给**它自由发挥的余地：
     *     让它"想推荐哪个科室"就回到了一开始要避免的那件事上。
     */
    let prompt = aiTriagePrompt(complaint, v)
    let r = aiCallChat(opts, prompt, now)
    if (r.ok) {
        let clean = aiSanitizeNote(r.text)
        if (clean.size == 0) {
            /*
             * 模型答了，但清理后为空（含疑似诊断/用药，或全是 Markdown）。
             * ⇒ 标 `model:invalid` 并**保留规则文案**。
             *   ⚠ 与"调用失败"分开标：这一个要**改 Prompt**，那一个要**查网络**。
             */
            v.source = "model:invalid"
            v.aiReason = "模型输出未通过安全检查（疑似诊断/用药或格式不合格），已用规则文案"
            return
        }
        v.aiNote = clean
        v.source = "model"
        return
    }
    /* ④ 调用失败 ⇒ 降级。`source` 保持 `rules`（**不假装成功**）。 */
    v.aiReason = r.reason
}

/* 组给模型的 Prompt（只含规则已判定的事实）。 */
public func aiTriagePrompt(complaint: String, v: TriageVerdict): String {
    var deptHint = ""
    if (v.options.size > 0) {
        deptHint = v.options[0].departmentName
    }
    var b = "患者主诉：${complaint}\n"
    if (deptHint.size > 0) {
        b = b + "系统已按规则判定应去：${deptHint}\n"
    }
    b = b + "\n请用**一到两句**中文向患者说明：为什么会建议去这个科室、就诊前可以准备什么。\n" +
        "要求：\n" +
        "· 不要下诊断、不要提任何药名或剂量、不要承诺疗效；\n" +
        "· 纯文本，不要 Markdown 标记；\n" +
        "· 不超过 80 字；\n" +
        "· 不要复述上面的系统判定，直接给患者建议。"
    return b
}

/*
 * 模型输出 → 可给患者看的**安全文本**。
 *
 * 白名单式清理，顺序不能变：
 *   ① 只取第一行（多段一律丢掉，避免"建议…"藏在第 3 段）
 *   ② 去 Markdown 标记（`#`、`*`、`` ` ``、`>`、列表符）
 *   ③ 命中**禁用词** ⇒ 返回空串（**整条丢弃**，见文件头）
 *   ④ 按**字符**截断到 `AI_NOTE_MAX_CHARS`
 *   ⑤ 去掉控制字符（含换行 —— 已有"只取第一行"，这里是二道保险）
 *
 * ⚠ 返回空串是**合法结果**，调用方必须处理（把 source 标成 `model:invalid`）。
 */
public func aiSanitizeNote(raw: String): String {
    /* ① 第一行 */
    var line = raw
    let nl = raw.indexOf("\n")
    match (nl) {
        case Some(i) => line = raw[0..i]
        case None => ()
    }
    line = line.trimAscii()
    /* ② 去 Markdown */
    line = aiStripMarkdown(line)
    /* ③ 禁用词（大小写不敏感：模型会写 "Take 500mg"） */
    let low = line.toAsciiLower()
    for (w in AI_NOTE_DENY) {
        if (low.contains(w.toAsciiLower())) {
            return ""
        }
    }
    /* ④ 按字符截断 */
    if (previsitCharLen(line) > AI_NOTE_MAX_CHARS) {
        line = aiTruncateChars(line, AI_NOTE_MAX_CHARS)
    }
    /* ⑤ 控制字符（防"第一行"判断被 \r 之类绕过） */
    if (baseHasControlChar(line)) {
        return ""
    }
    return line.trimAscii()
}

/*
 * 这段文本是否含"疑似诊断/用药"的词汇。
 *
 * ⚠ 为什么做成产品侧函数而不是让测试自己遍历 `AI_NOTE_DENY`：
 *   那是**实现细节**（清单本身会变），测试依赖它的形状会让"改清单"变成
 *   "改测试"。对外只暴露"这段文本安全吗"这一个**语义**问题。
 */
public func aiNoteHasDenyWord(s: String): Bool {
    let low = s.toAsciiLower()
    for (w in AI_NOTE_DENY) {
        if (low.contains(w.toAsciiLower())) {
            return true
        }
    }
    return false
}

/* 去掉常见的 Markdown 标记（只做**去标记**，不做解析）。 */
public func aiStripMarkdown(s: String): String {
    var out = s
    for (m in ["**", "__", "##", "#", "*", "`", ">", "- ", "· ", "1. ", "2. "]) {
        out = out.replace(m, "")
    }
    return out.trimAscii()
}

/* 按**字符**截断（`String` 字节下标的坑见 triage.cj 里那段注释）。 */
public func aiTruncateChars(s: String, maxChars: Int64): String {
    if (previsitCharLen(s) <= maxChars) {
        return s
    }
    var out = ""
    var n: Int64 = 0
    for (r in s.runes()) {
        if (n >= maxChars) {
            break
        }
        out = out + r.toString()
        n = n + 1
    }
    return out
}
