package qingzhou

import std.collection.*
import std.time.*
import stdx.encoding.json.*

/* RAG/config/Prompt 已用时间从分诊模型等待额度扣除；SQL 自身由部署侧限时。 */
public let TRIAGE_ENHANCEMENT_BUDGET_MS: Int64 = 12000

/*
 * SPDX-License-Identifier: MIT
 *
 * ai_triage.cj —— 把真模型接到分诊上（增强层）
 * 严格边界：模型只给措辞，结论由规则与知识库给 —— 本文件对 v.options 无任何赋值。
 * 模型输出是不可信输入，必须过 aiSanitizeNote 白名单清理，违规整条丢弃。
 */

/* 患者可见说明的字符上限（按字符不按字节）。 */
public let AI_NOTE_MAX_CHARS: Int64 = 160

/* RAG 片段按"不可信输入"处理：逐条清理、总长有界；只影响措辞，不影响 options（否则知识库可绕过"绝不给没号的推荐"）。 */
public let AI_RAG_TOTAL_CHARS: Int64 = 600

/* 单条片段喂给模型前的最大字符数（块本身 ≤ KB_CHUNK_CHARS，这里再压一道）。 */
public let AI_RAG_PER_HIT_CHARS: Int64 = 300

/* 检索命中 → 已清理、已有界的片段文本；空串表示无可用片段（调用方不加参考资料段）。
 * 每条带标题：便于模型注明出处，也为排障留下召回线索。 */
public func aiRagContext(hits: Array<KbHit>): String {
    if (hits.size == 0) {
        return ""
    }
    var out = ""
    var used: Int64 = 0
    for (h in hits) {
        if (used >= AI_RAG_TOTAL_CHARS) {
            break
        }
        let body = aiSanitizeNote(h.content)
        if (body.size == 0) {
            continue
        }
        let title = aiSanitizeNote(h.title)
        var piece = aiTruncateChars(body, AI_RAG_PER_HIT_CHARS)
        if (title.size > 0) {
            piece = "【${title}】${piece}"
        }
        /* 分隔符必须计入 used：条目越多越容易累加超界（曾实测 611 > 600）。 */
        let sep = if (out.size > 0) { "\n· " } else { "· " }
        let sepLen = previsitCharLen(sep)
        let remain = AI_RAG_TOTAL_CHARS - used - sepLen
        if (remain <= 0) {
            break
        }
        if (previsitCharLen(piece) > remain) {
            piece = aiTruncateChars(piece, remain)
        }
        if (piece.size == 0) {
            break
        }
        out = out + sep + piece
        used = used + sepLen + previsitCharLen(piece)
    }
    return out
}


/* 命中这些词就整条丢弃模型输出（疑似诊断/用药/剂量）。 */
public let AI_NOTE_DENY: Array<String> = [
    "mg", "毫克", "克", "片", "粒", "支", "剂量", "服用", "口服", "注射", "静脉",
    "处方", "开药", "吃药", "用法用量", "每日", "一日", "一次",
    "诊断为", "确诊", "你得了", "您得了", "患的是", "可能是癌", "肿瘤",
    "手术", "化疗", "放疗", "输液",
    "tablet", "capsule", "dose", "prescription", "take ", "twice daily",
]

/* 对已被规则判定的结论做模型增强：只写 aiNote / aiReason / 统计字段。
 * 不抛异常 —— 它处在分诊响应路径上，抛异常会让患者看到 500。
 */
public func aiEnhanceTriage(v: TriageVerdict, complaint: String,
                            aiSettings: AiSettingsRepo, now: Int64,
                            ragHits!: Array<KbHit> = Array<KbHit>(),
                            deadlineMs!: Int64 = 0): Unit {
    /* ① 危急征象不调模型：患者最需要"立刻就医"，多一次网络往返只增加延迟。 */
    if (v.redFlag) {
        v.aiReason = "危急征象：优先让患者立刻看到处置建议，不进模型"
        /* 用常量 TR_RED_FLAG，与 triageDegradeIsRedFlagBypass() 同一判据，避免两处字面量分叉。 */
        v.aiDegradeReason = TR_RED_FLAG
        return
    }
    /* 开关只有 ai.enabled + aiCanCall()；ai.tool.* 是模型只读能力白名单，不是功能开关。 */
    var opts: AiRuntimeOptions
    try {
        opts = aiSettings.options(now)
    } catch (e: Exception) {
        /* 读配置失败 ⇒ 降级，不把分诊搞挂。 */
        v.aiReason = "读取 AI 配置失败，已降级为规则"
        v.aiDegradeReason = "CONFIG_READ_FAILED"
        return
    }
    let (can, why) = aiCanCall(opts)
    if (!can) {
        v.aiReason = why
        v.aiDegradeReason = "AI_DISABLED"
        return
    }
    /* 过了 aiCanCall 之后才记调用事实（之前记会造成"用了模型"的假象）；aiUsedKb = ragHits 非空。 */
    v.aiModelId = opts.modelId
    v.aiModelName = opts.modelName
    v.aiUsedKb = ragHits.size > 0
    if (v.aiUsedKb) {
        /* aiKbDocIds 只拼文档 id，不抄标题/正文（避免与知识库原文分叉）。 */
        var ids = ""
        for (h in ragHits) {
            if (ids.size > 0) {
                ids = ids + ","
            }
            ids = ids + h.docId.toString()
        }
        v.aiKbDocIds = ids
    }
    /* ③ 组 Prompt：只给规则已算好的事实；P5 片段已在调用方清理限长，为空则整段不加。 */
    /* 模板从库里取；读不到返回空串 ⇒ 退回默认模板，DB 挂时分诊照跑。 */
    let template = aiTriageTemplateOf(aiSettings, now)
    let prompt = aiTriagePromptWith(complaint, v, template, ragHits: ragHits)
    let remaining = if (deadlineMs > 0) {
        deadlineMs - DateTime.now().toUnixTimeStamp().toMilliseconds()
    } else { TRIAGE_ENHANCEMENT_BUDGET_MS }
    let r = aiCallChatBudget(opts, prompt, now, remaining)
    /* 耗时无论成败都记（0 = 没走到拿到响应那一步），排障看 p50/p95。 */
    v.aiElapsedMs = r.elapsedMs
    if (r.ok) {
        let clean = aiSanitizeNote(r.text)
        if (clean.size == 0) {
            /* 清理后为空 ⇒ 标 model:invalid，保留规则文案；与调用失败分开标。 */
            v.source = "model:invalid"
            v.aiReason = "模型输出未通过安全检查（疑似诊断/用药或格式不合格），已用规则文案"
            v.aiDegradeReason = "INVALID_OUTPUT"
            return
        }
        v.aiNote = clean
        v.source = "model"
        return
    }
    /* ④ 调用失败 ⇒ 降级。source 保持 rules（不假装成功）。 */
    v.aiReason = r.reason
    /* degrade_reason 存稳定码（CALL_FAILED 等）供看板聚合；人话只进 aiReason。 */
    v.aiDegradeReason = "CALL_FAILED"
}

/* 取库里配的分诊模板（prompt.triage）；空串（含读库异常）表示用代码默认模板。 */
func aiTriageTemplateOf(aiSettings: AiSettingsRepo, now: Int64): String {
    try {
        let repo = PromptRepo(aiSettings)
        return repo.body(PROMPT_TRIAGE, now)
    } catch (e: Exception) {
        return ""
    }
}

/* 模板渲染：{主诉} / {科室} / {红牌}；占位符须与 promptSlots() 的 PromptSlot.required 一致。 */
func aiTriageRenderTemplate(template: String, complaint: String, v: TriageVerdict): String {
    var deptHint = "（未判定）"
    if (v.options.size > 0) {
        deptHint = v.options[0].departmentName
    }
    var b = template.replace("{主诉}", complaint)
    b = b.replace("{科室}", deptHint)
    /* {红牌} 当前不会出现在 Prompt 里（红牌在开头就旁路），保留供模板作者写分情形措辞。 */
    let flagText = if (v.redFlag) { "是" } else { "否" }
    b = b.replace("{红牌}", flagText)
    return b
}

/* 组给模型的 Prompt（旧签名：用代码里的默认模板）。 */
public func aiTriagePrompt(complaint: String, v: TriageVerdict,
                           ragHits!: Array<KbHit> = Array<KbHit>()): String {
    return aiTriagePromptWith(complaint, v, "", ragHits: ragHits)
}

/* 组 Prompt：任务段来自模板（可配）+ 参考资料段 + 安全尾段（不可配）。
 * 固定安全尾段不可被模板覆盖：不下诊断、不提药名、≤80 字是免责与可用性底线。
 * 模型只给措辞，结论由规则与知识库给（options 始终由规则决定）。
 */
public func aiTriagePromptWith(complaint: String, v: TriageVerdict, template: String,
                               ragHits!: Array<KbHit> = Array<KbHit>()): String {
    var head = template
    if (head.trimAscii().size == 0) {
        head = promptDefaultBody(PROMPT_TRIAGE)
    }
    var b = aiTriageRenderTemplate(head, complaint, v)
    /* 参考资料段只为措辞："供措辞参考" + "不要去哪个科室以系统判定为准"，防止知识库文档被复述成推荐。
     * rag 为空则整段不加（留空的"参考资料："会诱导模型编造）。 */
    let rag = aiRagContext(ragHits)
    if (rag.size > 0) {
        b = b + "\n参考资料（供措辞参考；**不要去哪个科室以系统判定为准**）：\n" + rag + "\n"
    }
    b = b + "\n要求：\n" +
        "· 不要下诊断、不要提任何药名或剂量、不要承诺疗效；\n" +
        "· 纯文本，不要 Markdown 标记；\n" +
        "· 不超过 80 字；\n" +
        "· 不要复述上面的系统判定，直接给患者建议。"
    return b
}

/* 模型输出 → 可给患者看的安全文本；白名单清理，顺序不能变：
 * 取首行 → 去 Markdown → 命中禁用词整条丢弃 → 按字符截断 → 去控制字符。
 * 返回空串是合法结果，调用方必须处理（标 model:invalid）。 */
public func aiSanitizeNote(raw: String): String {
    var line = raw
    let nl = raw.indexOf("\n")
    match (nl) {
        case Some(i) => line = raw[0..i]
        case None => ()
    }
    line = line.trimAscii()
    line = aiStripMarkdown(line)
    let low = line.toAsciiLower()
    for (w in AI_NOTE_DENY) {
        if (low.contains(w.toAsciiLower())) {
            return ""
        }
    }
    if (previsitCharLen(line) > AI_NOTE_MAX_CHARS) {
        line = aiTruncateChars(line, AI_NOTE_MAX_CHARS)
    }
    if (baseHasControlChar(line)) {
        return ""
    }
    return line.trimAscii()
}

/* 文本是否含疑似诊断/用药词：对外只暴露"这段文本安全吗"这一语义问题。
 * 不暴露 AI_NOTE_DENY 的形状，避免改清单变成改测试。 */
public func aiNoteHasDenyWord(s: String): Bool {
    let low = s.toAsciiLower()
    for (w in AI_NOTE_DENY) {
        if (low.contains(w.toAsciiLower())) {
            return true
        }
    }
    return false
}

/* 去掉常见 Markdown 标记（只做去标记，不做解析）。 */
public func aiStripMarkdown(s: String): String {
    var out = s
    for (m in ["**", "__", "##", "#", "*", "`", ">", "- ", "· ", "1. ", "2. "]) {
        out = out.replace(m, "")
    }
    return out.trimAscii()
}

/* 按字符截断（String 字节下标的坑见 triage.cj）。 */
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
