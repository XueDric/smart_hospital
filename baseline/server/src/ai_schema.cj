package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * AI 能力 · 提示词模板 与 模型输出 schema
 *
 * 对应：api-design.md Part 7 · llm-client-spec.md §5.4
 *
 * 为什么集中在这里声明：
 *   模型输出是**不可信输入**。任何情况下都不得直接成为写库值，
 *   必须先过 `extractJson` → `JsonValue.fromStr` → schema 校验。
 *   集中声明便于一处审计"我们到底允许模型返回什么"。
 *
 * ⚠ 一个必须知道的框架细节（读 jsonschema.cj 的 validateField 得出，不是猜的）：
 *   字段**存在但值为 `null`** 会被判为"类型不符"——因为 `jsonGetStr` 等对 `JsonNull`
 *   返回 `None`，而 `validateField` 只判 `obj.get(name)` 是否 Some。
 *   而模型非常爱显式输出 `null`。所以校验收口是：
 *       ① `aiNormalize` 按**已知键**剔掉值为 null 的项（JsonObject 在项目里
 *          只用过 size()/containsKey()/get/put，没有遍历保证，故按键清单处理最稳）
 *       ② 再把清理后的对象交给 `JsonSchema.validate`
 *       ③ 可空字段一律用 `jsonGetXxx` 宽容读取（null → None）
 */

import std.collection.*
import stdx.encoding.json.*

/* ===================== 通用 ===================== */

/* 所有功能共用的一句约束，放进 system 消息。 */
public let AI_SYSTEM_RULE: String =
    "你是社团管理系统的助手。严格只输出一个 JSON 对象：" +
    "不要解释、不要前后缀、不要 markdown 代码块。字段名与类型必须完全符合要求；" +
    "没有把握的字段请【省略该键】，不要编造，也不要输出 null。"

/* 按已知键剔掉值为 null（或缺失）的项，得到一个"干净"的对象供 schema 校验。 */
public func aiNormalize(src: JsonObject, keys: Array<String>): JsonObject {
    let out = JsonObject()
    for (k in keys) {
        let raw = src.get(k)
        var take = false
        match (raw) {
            case Some(v) =>
                match (v) {
                    case n: JsonNull => take = false
                    case _ => take = true
                }
            case None => take = false
        }
        if (take) {
            match (raw) {
                case Some(v) => out.put(k, v)
                case None => ()
            }
        }
    }
    return out
}

/* ===================== 7.1 任务建议 ===================== */

public let AI_KEYS_TASK_SUGGEST: Array<String> = ["owner_id", "due_at", "granularity", "reasons"]

/*
 * 候选负责人必须由**服务端**给出（candidates 的每一行形如
 * "id=7 姓名=张三 角色=member 在途任务=2"（实际由 h_ai.cj 的 aiCandidateLines 生成；
 *        **没有部门、也没有按期率** —— api-design 里"按期率最高"那条尚未实现，见 F-9）），模型只能从中挑，
 * 返回的 owner_id 还要再校验一次是否真在候选集里——**模型不得凭空造人**。
 */
public func aiPromptTaskSuggest(title: String, desc: String, deptName: String,
                               candidates: String, history: String): String {
    return "请为下面这个社团任务给出建议。\n\n" +
           "任务标题：${title}\n" +
           "任务描述：${if (desc.size > 0) { desc } else { "（无）" }}\n" +
           "所属部门：${deptName}\n\n" +
           "可选负责人（**只能从这份名单里挑，用其中的 id**）：\n${candidates}\n\n" +
           "部门过往同类任务（供参考，可能为空）：\n${if (history.size > 0) { history } else { "（无）" }}\n\n" +
           "请只输出一个 JSON 对象，字段如下：\n" +
           "  owner_id    ：整数，从上面名单里选的 id；实在挑不出就省略该键\n" +
           "  due_at      ：字符串，建议截止时间，格式 2026-10-20T18:00:00+08:00；给不出就省略\n" +
           "  granularity ：字符串，一句话说明是否建议拆分、怎么拆；不需要就省略\n" +
           "  reasons     ：字符串数组，**必须给**，逐条写清上面建议的依据（要能对上真实数据）"
}

public func aiSchemaTaskSuggest(): JsonSchema {
    return JsonSchema()
        .require("reasons", FArr)
        .optional("owner_id", FInt)
        .optional("due_at", FStr)
        .optional("granularity", FStr)
}

/* ===================== 7.2 通知起草 ===================== */

public let AI_KEYS_NOTICE: Array<String> = ["title", "body", "audience", "suggest_send_at"]

public func aiPromptNotice(taskTitle: String, ownerName: String, dueAt: String,
                           planPath: String, audience: String): String {
    return "请为下面这个社团任务起草一则通知。\n\n" +
           "任务：${taskTitle}\n" +
           "负责人：${if (ownerName.size > 0) { ownerName } else { "（未指定）" }}\n" +
           "截止时间：${if (dueAt.size > 0) { dueAt } else { "（未指定）" }}\n" +
           "所属课题：${if (planPath.size > 0) { planPath } else { "（无）" }}\n" +
           "受众：${audience}\n\n" +
           "请只输出一个 JSON 对象，字段如下：\n" +
           "  title           ：字符串，通知标题\n" +
           "  body            ：字符串，通知正文（说清做什么、谁负责、什么时候之前）\n" +
           "  audience        ：字符串，原样回填受众\n" +
           "  suggest_send_at ：字符串，建议发送时间（ISO 8601 带时区）；给不出就省略"
}

public func aiSchemaNotice(): JsonSchema {
    return JsonSchema()
        .requireStr("title", minLen: 1)
        .requireStr("body", minLen: 1)
}

/* ===================== 7.3 成效与延期归因 ===================== */

public let AI_KEYS_RETRO: Array<String> = ["summary", "causes", "suggestions"]

/*
 * ⚠ 关键：`is_overdue` / `days` **不由模型生成**，由服务端既有派生量算好后
 * 作为事实写进 prompt；模型只负责 `causes`（归因）与 `suggestions`（改进建议）。
 * 这样列表页的数字与这里永远一致。
 */
public func aiPromptRetro(summaryFacts: String, overdueFacts: String): String {
    return "下面是一个社团任务/课题的**客观事实**（已由系统统计好，不要改动这些数字）：\n\n" +
           "${summaryFacts}\n\n" +
           "延期情况：${overdueFacts}\n\n" +
           "请只输出一个 JSON 对象，字段如下：\n" +
           "  summary     ：字符串，两三句话的成效总结（只能基于上面的事实）\n" +
           "  causes      ：字符串数组，**延期归因**，每条格式 \"kind: 说明\"，\n" +
           "                kind 只能取 dependency / overload / granularity / scope_drift / external / unknown\n" +
           "  suggestions ：字符串数组，可执行的改进建议\n" +
           "若并未延期，causes 给空数组。"
}

public func aiSchemaRetro(): JsonSchema {
    return JsonSchema()
        .requireStr("summary", minLen: 1)
        .require("causes", FArr)
        .require("suggestions", FArr)
}

/* ===================== 7.4 权限感知问答 ===================== */

public let AI_KEYS_ASK: Array<String> = ["answer", "basis"]

/*
 * ⚠ 权限结论**禁止**由模型生成：调用方必须先用 `can()` 算出结果，
 * 作为"事实"传进来（permFacts），模型只做语言组织。
 * 这样"AI 说错权限"在结构上不可能发生——评委问起来，答案就是这一句。
 */
public func aiPromptAsk(question: String, whoFacts: String, permFacts: String, docFacts: String): String {
    return "用户在社团管理系统里提问，请基于下面给出的**事实**回答。\n" +
           "【硬性要求】只能使用下面列出的事实，**不要推测、不要补充系统没有的权限**。\n\n" +
           "提问：${question}\n\n" +
           "提问者身份（系统判定）：\n${whoFacts}\n\n" +
           "提问者权限（系统判定，这是权威结论）：\n${permFacts}\n\n" +
           "相关社团规则条款（可能为空）：\n${if (docFacts.size > 0) { docFacts } else { "（无）" }}\n\n" +
           "请只输出一个 JSON 对象，字段如下：\n" +
           "  answer ：字符串，直接回答提问者的问题\n" +
           "  basis  ：字符串数组，列出你依据了哪些事实，每条格式 \"permission: xxx\" / " +
           "\"data: xxx\" / \"doc: xxx\""
}

public func aiSchemaAsk(): JsonSchema {
    return JsonSchema()
        .requireStr("answer", minLen: 1)
        .require("basis", FArr)
}

/* ===================== 7.5 邀请风控 ===================== */

public let AI_KEYS_RISK: Array<String> = ["level", "reasons"]

public func aiPromptInviteRisk(applicantFacts: String, linkFacts: String, ipFacts: String): String {
    return "请评估这条入社申请的风险等级。\n\n" +
           "申请人信息：${applicantFacts}\n" +
           "邀请链接信息：${linkFacts}\n" +
           "来源与频次：${ipFacts}\n\n" +
           "请只输出一个 JSON 对象，字段如下：\n" +
           "  level   ：字符串，只能是 low / medium / high 之一\n" +
           "  reasons ：字符串数组，逐条说明判断依据"
}

public func aiSchemaInviteRisk(): JsonSchema {
    return JsonSchema()
        .requireStr("level", minLen: 1)
        .require("reasons", FArr)
}

/* ===================== 7.6 智能体：工具循环（只读，Phase 1）===================== */

public let AI_KEYS_AGENT: Array<String> = ["final", "tool", "args"]

/*
 * Agent 提示词。协议是 **JSON-in-content**（**不是**原生 function calling）——
 * 这样能直接复用现有链路（`extractJson` → `aiNormalize` → `JsonSchema` 校验），
 * 不必在传输层之上再叠一层 `tool_calls` 解析，桩与测试也不用改。
 *
 * 模型每轮**只能二选一**：
 *   还要查数据 -> {"tool": "...", "args": {...}}
 *   可以回答了 -> {"final": "..."}
 */
public func aiPromptAgent(question: String, who: String, perms: String,
                          tools: String, history: String): String {
    return "你是社团管理系统的助手，可以调用下面这些**只读**工具查数据，再回答问题。\n\n" +
           "提问者：${who}\n" +
           "提问者权限（系统判定，**这是权威结论**，不要自己推断权限）：\n${perms}\n" +
           "可用工具（**只能用这些**，不能发明新工具）：\n${tools}\n" +
           (if (history.size > 0) { "\n你已经查到的数据：\n${history}\n" } else { "" }) +
           "\n提问：${question}\n\n" +
           "每一轮**只输出一个** JSON 对象，二选一：\n" +
           "  还要查数据 -> {\"tool\": \"工具名\", \"args\": {\"...\": \"...\"}}\n" +
           "  可以回答了 -> {\"final\": \"给提问者的回答（中文、简洁、必须依据上面查到的真实数据；查不到就说查不到，不要编）\"}\n" +
           "不要输出解释，不要 markdown 代码块。"
}

/*
 * 两个分支都合法，所以 schema 只校验"字段类型对"，**不强制**必须是哪一个。
 * （哪一个是哪个由 handler 判断，见 h_ai.cj 的 aiAgentLoop。）
 */
public func aiSchemaAgent(): JsonSchema {
    return JsonSchema()
        .optional("final", FStr)
        .optional("tool", FStr)
        .optional("args", FObj)
}
