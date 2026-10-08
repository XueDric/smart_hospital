/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 *
 * ===== triage_test.cj —— P2 分诊的**纯逻辑**测试（不需要数据库）=============
 *
 * 分层理由（与本项目 `selftest` / `authtest` / `accept` 的分工一致）：
 *   · **本文件**：不碰库、不调模型 —— 测"危急征象判定"与"科室判定"这两块纯逻辑。
 *     它们是最该被密集测的部分（词表 + 否定 + 共现规则，边界很多）。
 *   · `acceptance.cj` 的 AC-P2-*：**需要库** —— 测"验证层绝不给没号的推荐"。
 *   分开的好处：纯逻辑测试**任何机器上都能跑**（无库、无网），
 *   而需要库的那部分走 `accept`（已有库名守门）。
 *
 * ⚠ 本文件**不测模型路径**：本轮不接真模型（Q6 待决），所以没有模型可言。
 *   不写"假的模型测试"来充数 —— 那是制造"绿色的假保证"。
 */

package qingzhou

import std.collection.*
import stdx.encoding.json.*

/* 测试运行器（照 acceptance.cj 的 TestRunner：闭包不能捕获可变 var，必须用 class）。 */
class TriageRunner {
    var passed: Int64 = 0
    var failed: Int64 = 0

    func check(name: String, ok: Bool): Unit {
        if (ok) {
            println("  [PASS] ${name}")
            passed = passed + 1
        } else {
            println("  [FAIL] ${name}")
            failed = failed + 1
        }
    }
}

/*
 * 逐用例的异常兜底：一个用例抛异常不能让整个测试静默停在中途
 * （这个坑在 P0 的 accept 里踩过：变异测试导致零输出，看不出失败）。
 */
func triageSection(r: TriageRunner, name: String, body: () -> Unit): Unit {
    try {
        body()
    } catch (e: Exception) {
        println("  [FAIL] ${name} 抛出异常（该用例判失败）：${e.message}")
        r.failed = r.failed + 1
    }
}

/* 跑全部纯逻辑用例。返回失败项数（0 = 全通过）。 */
public func runTriageTests(): Int64 {
    let r = TriageRunner()
    println("=== P2 分诊纯逻辑自检（不碰库 / 不调模型）===")
    println("")
    rtRedFlag(r)
    rtNegation(r)
    rtVague(r)
    rtWidthMix(r)
    rtDept(r)
    rtDeptNegation(r)
    println("")
    println("=== P2 预问诊纯逻辑自检 ===")
    rpSseFrame(r)
    rpFormValue(r)
    rpTruncate(r)
    rpAssistantLines(r)
    println("")
    println("通过 ${r.passed} 项，失败 ${r.failed} 项")
    if (r.failed == 0) {
        println("✅ 分诊纯逻辑自检全部通过")
    } else {
        println("❌ 分诊纯逻辑自检失败 ${r.failed} 项")
    }
    return r.failed
}

/* ---------- 危急征象：高危词单独命中即红牌 ---------- */
func rtRedFlag(r: TriageRunner): Unit {
    println("--- 危急征象：高危词（单独命中即红牌）---")
    triageSection(r, "rtRedFlag", { =>
        // 正向：每一条都必须报红牌
        let cases: Array<String> = [
            "我父亲胸痛，出汗，已经半小时了",
            "突然口角歪斜，说话不清楚",
            "呼吸困难，喘不上气",
            "呕血两次",
            "剧烈腹痛，直不起腰",
            "孩子高热惊厥了",
            "孕38周，胎动减少",
            "误服了农药",
            "从高处坠落，腰疼得厉害",
            "昏迷不醒"
        ]
        for (c in cases) {
            let f = detectRedFlag(c)
            r.check("红牌：${c}", f.redFlag)
        }

        // 反向：普通主诉**绝不能**报红牌（误报会把正常人赶去急诊）
        let normal: Array<String> = [
            "咳嗽三天，有痰",
            "胃痛反酸",
            "皮肤瘙痒起红点",
            "血糖偏高想复查",
            "腰痛，久坐后加重",
            "孩子发烧38度，精神还好",
            "月经不调",
            "牙痛",
            "失眠多梦",
            "头晕两天"
        ]
        for (c in normal) {
            let f = detectRedFlag(c)
            r.check("不误报红牌：${c}", !f.redFlag)
        }
    })
}

/* ---------- 危急征象：否定式不得误报（本文件最关键的一组）---------- */
func rtNegation(r: TriageRunner): Unit {
    println("")
    println("--- 危急征象：否定式（**不得**误报）---")
    triageSection(r, "rtNegation", { =>
        /*
         * ★★ 这组用例是本文件存在的核心理由之一。
         * 中文没有词边界，裸 `contains` 会把「**没有**胸痛」判成"胸痛" ——
         * 把没病的人赶去急诊，与漏报同样是伤害。
         * 没有这组用例，否定逻辑一旦被"简化"掉就没人发现。
         */
        let negated: Array<String> = [
            "没有胸痛",
            "无发热，无胸痛",
            "否认胸痛、否认呼吸困难",
            "未曾呕血",
            "并没有昏迷",
            "排除误服可能",
            "不抽搐",
            "无呕血便血"
        ]
        for (c in negated) {
            let f = detectRedFlag(c)
            r.check("否定式不报红牌：${c}", !f.redFlag)
        }

        // ★ 但否定**只作用于同一小句**：切段后另一小句的真征象仍必须报
        let mixed: Array<String> = [
            "没有胸痛，但是呕血了",
            "否认发热，现在呼吸困难"
        ]
        for (c in mixed) {
            let f = detectRedFlag(c)
            r.check("同句否定不掩盖他句真征象：${c}", f.redFlag)
        }

        // 留档：被否定作废的命中要记下来（说明"为什么看起来该报却没报"）
        let f = detectRedFlag("没有胸痛")
        r.check("被否定的命中留档（negated 非空）", f.negated.size > 0)
        r.check("被否定的命中不进 terms", f.terms.size == 0)
    })
}

/* ---------- 危急征象：模糊词必须共现才算 ---------- */
func rtVague(r: TriageRunner): Unit {
    println("")
    println("--- 危急征象：模糊词（单独不算，需与程度/频次共现）---")
    triageSection(r, "rtVague", { =>
        /*
         * 模糊词（心慌/头晕/疼…）在日常汉语里大量用于非医疗语境：
         *   "心慌意乱"、"头晕脑胀地忙了一天"。
         * 单独命中就报红牌 ⇒ 红牌率飙到不可用（急诊被挤爆，等于没有兜底）。
         */
        let vagueAlone: Array<String> = [
            "有点心慌",
            "头晕",
            "头疼",
            "有点恶心",
            "腰疼"
        ]
        for (c in vagueAlone) {
            r.check("模糊词单独不报红牌：${c}", !detectRedFlag(c).redFlag)
        }

        // 与程度/频次共现 ⇒ 升级为红牌
        let vagueWithMod: Array<String> = [
            "反复呕吐",
            "持续头痛",
            "心慌越来越严重",
            "一直恶心不停",
            "头痛剧烈难以忍受"
        ]
        for (c in vagueWithMod) {
            r.check("共现升级为红牌：${c}", detectRedFlag(c).redFlag)
        }
    })
}

/* ---------- ★★ 宽度混排：按**类别**扫，而不是逐点修 ---------- */
func rtWidthMix(r: TriageRunner): Unit {
    println("")
    println("--- ★★ 宽度混排（ASCII 窄字符 + 汉字宽字符）---")
    triageSection(r, "rtWidthMix", { =>
        /*
         * ★★ 这一组守的是**第五份复查**抓出的严重缺陷，它同时也是"测试为什么没抓到"的答案。
         *
         * 原缺陷：否定窗口的字节/字符换算取错了参照点，于是 `from` 可能落在
         *   多字节字符**中间** ⇒ `seg[from..at]` 切出非法 UTF-8 ⇒ 普通主诉 **HTTP 500**。
         *   实测触发条件极其常见（真实临床写法）：
         *       CT显示没有胸痛 / BP160没有胸痛 / 1234没有胸痛 / aaaa没有胸痛
         *   而 "血压160没有胸痛" / "糖尿病10年没有胸痛" / "aaa没有呕血" 却**正常** ——
         *   因为它们的宽度组合恰好让偏移落在字符边界上。
         *
         * 为什么原来的用例全没抓到：**所有否定用例都是等宽纯汉字**
         *   （"没有胸痛" / "否认胸痛" / "未曾呕血"），边界永远不会落在字符中间。
         *   📌 这与上一轮"变异②漏掉"是**同一个病**：用例只覆盖了一种形态，
         *     于是它验的是那种形态，而不是那条**规则**。
         *
         * ⇒ 所以这里不做"再补几个用例"，而是**按类别扫**：
         *   系统性组合「前缀宽度」×「否定写法」，把整个组合空间走一遍。
         *   任何"只在某些宽度组合下错"的实现都必然被覆盖。
         */
        let prefixes: Array<String> = [
            "", "CT显示", "BP160", "1234", "aaaa", "血压160", "糖尿病10年",
            "a", "ab", "abc", "abcd", "abcde", "体温37.5度", "x1", "患者男", "男65岁"
        ]
        let negForms: Array<String> = [
            "没有胸痛", "无胸痛", "不胸闷", "否认胸痛", "未曾呕血", "并没有昏迷",
            "没有呼吸困难", "无呕血便血", "排除误服", "不抽搐"
        ]
        var bad: Int64 = 0
        var total: Int64 = 0
        for (p in prefixes) {
            for (nf in negForms) {
                let c = p + nf
                total = total + 1
                if (detectRedFlag(c).redFlag) {
                    bad = bad + 1
                    if (bad <= 5) {
                        println("        误报红牌：'${c}'")
                    }
                }
            }
        }
        r.check("★ 宽度混排 × 否定写法 共 ${total} 组全部不报红牌（误报 ${bad} 组）", bad == 0)

        // 反向：混排 + **真**征象必须仍然报（不能矫枉过正成"一律不报"）
        let truths: Array<String> = [
            "胸痛", "呕血", "呼吸困难", "昏迷", "抽搐", "误服农药", "胎动减少"
        ]
        var missed: Int64 = 0
        var total2: Int64 = 0
        for (p in prefixes) {
            for (tv in truths) {
                let c = p + "，" + tv
                total2 = total2 + 1
                if (!detectRedFlag(c).redFlag) {
                    missed = missed + 1
                    if (missed <= 5) {
                        println("        漏报：'${c}'")
                    }
                }
            }
        }
        r.check("★ 宽度混排 × 真征象 共 ${total2} 组全部报红牌（漏报 ${missed} 组）", missed == 0)

        /*
         * 复查给的**具体**输入：必须区分两类断言（不能混成一条）。
         *
         * ⚠ 我第一版把 8 个样例**全部**断言成"不报红牌"，结果 `aaaa持续头痛` 失败 ——
         *   而它报红牌是**设计如此**（`持续` 是程度修饰 + `头痛` 是模糊词 ⇒ 共现升级）。
         *   复查表格里这一条列的是 **500（崩）**，不是"误报红牌"。
         *   ⇒ 教训：**从报告里抄样例时，要连"每条样例断言什么"一起抄清楚**；
         *     把不同性质的样例混成一条断言，会把**正确行为**报成失败。
         */
        let repro: Array<String> = [
            "CT显示没有胸痛", "BP160没有胸痛", "1234没有胸痛", "aaaa没有胸痛",
            "aaaa持续头痛", "血压160没有胸痛", "糖尿病10年没有胸痛", "aaa没有呕血"
        ]
        // ★ 断言 A（全部 8 条）：**不抛异常** —— "500"就是本次缺陷的直接表现
        var threw = false
        try {
            for (c in repro) {
                let _f = detectRedFlag(c)
            }
        } catch (e: Exception) {
            threw = true
            println("        抛异常：${e.message}")
        }
        r.check("★★ 复查的 8 个样例**全部不抛异常**（原缺陷表现为 HTTP 500）", !threw)

        // ★ 断言 B（只对"纯否定"那 7 条）：不得误报红牌
        let mustNotFlag: Array<String> = [
            "CT显示没有胸痛", "BP160没有胸痛", "1234没有胸痛", "aaaa没有胸痛",
            "血压160没有胸痛", "糖尿病10年没有胸痛", "aaa没有呕血"
        ]
        var anyBad = false
        for (c in mustNotFlag) {
            if (detectRedFlag(c).redFlag) {
                anyBad = true
                println("        复查样例仍误报红牌：'${c}'")
            }
        }
        r.check("★ 复查的 7 条**纯否定**样例不报红牌", !anyBad)

        // ★ 断言 C：混排下的"共现升级"**仍然生效**（反向，防止有人把它当误报改坏）
        r.check("★ 混排 + 程度修饰仍按设计升级为红牌（'aaaa持续头痛'）",
                detectRedFlag("aaaa持续头痛").redFlag)
    })
}

/* ---------- ★★ 科室判定也必须处理否定 ---------- */
func rtDeptNegation(r: TriageRunner): Unit {
    println("")
    println("--- ★★ 科室判定：被否认的症状不得主导推荐 ---")
    triageSection(r, "rtDeptNegation", { =>
        /*
         * ★★ 第五份复查的第二个严重缺陷。实测（让心血管内科有号后）：
         *     '不胸闷，只是咳嗽'   -> 心血管内科  ✗
         *     '没有胸闷，就是咳嗽' -> 心血管内科  ✗
         *     '否认胸闷，主要咳嗽' -> 心血管内科  ✗
         *     '咳嗽'（对照）       -> 呼吸内科    ✓
         *
         * 危害比"分错科"更隐蔽：**有号校验是通过的**，于是 `reason=OK`
         * 还附了真实医生与号源 ⇒ 响应看起来权威而确定，患者很可能照着挂错科。
         *
         * 根因：保险丝那条路处理了否定，科室判定这条路用的是**裸 `seg.contains`** ——
         * 同一语义两处实现，只改了一处（本项目反复吃过的"两套口径"病）。
         */
        let cases: Array<(String, String)> = [
            ("不胸闷，只是咳嗽", "呼吸内科"),
            ("没有胸闷，就是咳嗽", "呼吸内科"),
            ("否认胸闷，主要咳嗽", "呼吸内科"),
            ("无胸闷，咳嗽三天", "呼吸内科"),
            // 对照：真的说胸闷，必须仍然给心血管内科（不能矫枉过正）
            ("胸闷心悸", "心血管内科"),
            ("血压高，胸闷", "心血管内科")
        ]
        for ((c, want) in cases) {
            let g = guessDepartment(c)
            r.check("「${c}」→ ${want}（实得 ${g.deptName}）", g.deptName == want)
        }

        // 混排也要正确（与保险丝同一类风险）
        let mixed: Array<(String, String)> = [
            ("CT显示没有胸闷，只是咳嗽", "呼吸内科"),
            ("BP160否认胸闷，主要咳嗽", "呼吸内科")
        ]
        for ((c, want) in mixed) {
            let g = guessDepartment(c)
            r.check("混排「${c}」→ ${want}（实得 ${g.deptName}）", g.deptName == want)
        }
    })
}

/* ---------- 科室判定 ---------- */
func rtDept(r: TriageRunner): Unit {
    println("")
    println("--- 科室判定（规则实现）---")
    triageSection(r, "rtDept", { =>
        let cases: Array<(String, String)> = [
            ("咳嗽三天有痰", "呼吸内科"),
            ("胃痛反酸烧心", "消化内科"),
            ("血糖高想复查", "内分泌科"),
            ("腰痛久坐加重", "骨科"),
            ("皮肤瘙痒起红点", "皮肤科"),
            ("眼睛红流泪", "眼科"),
            ("孩子发烧", "儿科"),
            ("月经不调", "妇产科"),
            ("尿频尿急", "泌尿外科"),
            ("牙痛", "口腔科")
        ]
        for ((complaint, want) in cases) {
            let g = guessDepartment(complaint)
            r.check("「${complaint}」→ ${want}（实得 ${g.deptName}）", g.deptName == want)
        }

        // ★ 顺序纪律：专科必须优先于泛科
        //   "胸闷" 同时能被"内科"的某个词命中吗？不能 —— 但"心慌"这类
        //   如果内科词表里有泛化词就会抢。这里钉住"心血管内科 排在 内科 之前"。
        let g1 = guessDepartment("胸闷心悸")
        r.check("★ 专科优先：胸闷心悸 → 心血管内科（不是内科）", g1.deptName == "心血管内科")
        // 泛化主诉才落到内科
        let g2 = guessDepartment("发烧乏力")
        r.check("泛化主诉 → 内科", g2.deptName == "内科")

        // 认不出 ⇒ 必须返回"没找到"，而不是随便给一个科室
        let g3 = guessDepartment("就是不太舒服")
        r.check("认不出时不乱猜（found = false）", !g3.found())
        let g4 = guessDepartment("")
        r.check("空主诉不猜", !g4.found())

        // 命中依据要留下（审计/解释用）
        let g5 = guessDepartment("咳嗽")
        r.check("命中依据非空", g5.matched.size > 0)

        // ★ 规则表自身的完整性（防"改了表但漏了字段"）
        let rules = deptRules()
        r.check("规则表非空", rules.size > 0)
        var allHaveKw = true
        for (x in rules) {
            if (x.keywords.size == 0) {
                allHaveKw = false
            }
        }
        r.check("每条规则都有关键词", allHaveKw)
        // 最后一条应当是泛科（"内科"），因为顺序有意义（先匹配到的胜出）
        r.check("★ 泛科排在最后（顺序即纪律）", rules[rules.size - 1].deptName == "内科")
    })
}

/* ===================== P2 预问诊 纯逻辑用例 ===================== */

/*
 * SSE 帧格式 —— 这一组是"流式到底有没有按协议来"的唯一保证。
 *
 * ⚠ 为什么必须有：SSE 的坑全在**格式**上，而且错了以后表现是"客户端卡住"
 *   或"看到半句话"，从服务端日志里**完全看不出来**。三条硬要求：
 *     ① 帧必须**恰好**以 `\n\n` 结尾（少一个 `\n` 客户端会一直等下一行）；
 *     ② 帧内**不得有裸换行**（否则一帧被拆成两帧）；
 *     ③ 必须是 `data: ` 前缀（少个空格有些客户端就不认）。
 */
func rpSseFrame(r: TriageRunner): Unit {
    println("")
    println("--- SSE 帧格式 ---")
    triageSection(r, "rpSseFrame", { =>
        let o = JsonObject()
        o.put("text", JsonString("好的。"))
        let f = sseFrame("delta", o)
        r.check("① 帧以 \\n\\n 结尾（两个换行才算事件结束）", f.endsWith("\n\n"))
        // ② 帧内不得有裸换行：去掉结尾那两个，中间不能再有
        let body = f[0..(f.size - 2)]
        var hasBareNl = false
        for (ch in body.toArray()) {
            if (Int64(ch) == 0x0A || Int64(ch) == 0x0D) {
                hasBareNl = true
            }
        }
        r.check("② 帧内无裸换行（否则一帧会被拆成两帧）", !hasBareNl)
        r.check("③ 以 `data: ` 开头（注意冒号后的空格）", f.startsWith("data: "))
        r.check("④ 含事件名", f.contains("\"delta\""))
        // ★ 关键：文本里带 **真换行** 时也必须仍然只有帧尾那两个换行
        let o2 = JsonObject()
        o2.put("text", JsonString("第一行\n第二行\r\n第三行"))
        let f2 = sseFrame("delta", o2)
        let body2 = f2[0..(f2.size - 2)]
        var bare2 = false
        for (ch in body2.toArray()) {
            if (Int64(ch) == 0x0A || Int64(ch) == 0x0D) {
                bare2 = true
            }
        }
        r.check("★ 文本内含真换行时，帧内仍无裸换行（JSON 转义生效）", !bare2)
        r.check("★ 且结尾仍是 \\n\\n", f2.endsWith("\n\n"))
    })
}

/*
 * ★★ 业务值：问诊单的"完整性"语义。
 *
 * 这一组守的是 brief §5.2 那条纪律的**落点**：
 * 业务值只有在**齐备并校验通过**后才有意义。关键区分是"**无**"与"**留空**"：
 *   · 「无过敏史」是**有效阴性答案** —— 医生据此可以放心用药；
 *   · 留空是**没答** —— 医生必须再问一遍。
 *   把两者混起来会让问诊单出现"既往史 = 空"，而医生无法解释那是哪种。
 */
func rpFormValue(r: TriageRunner): Unit {
    println("")
    println("--- 业务值：问诊单完整性 ---")
    triageSection(r, "rpFormValue", { =>
        let f = PrevisitForm()
        r.check("空表单 complete = false", !f.complete())
        r.check("空表单 filled = 0", f.filled() == 0)

        // 填满前 5 项（故意留 allergy 不填）
        let slots = intakeSlots()
        var i: Int64 = 0
        while (i < slots.size - 1) {
            f.answers[slots[i].key] = "x"
            i = i + 1
        }
        r.check("差一项时 complete = false", !f.complete())
        r.check("filled = ${slots.size - 1}", f.filled() == slots.size - 1)
        // ★ 填齐最后一项
        f.answers[slots[slots.size - 1].key] = "无"
        r.check("★ 全部有值后 complete = true", f.complete())
        r.check("★ 「无」是**有效答案**（不是「没答」）—— 第 6 项填「无」也算齐",
                f.answers["allergy"] == "无")
        // 反向：把它删掉就又不完整（证明 complete 依赖的是"有键"而不是别的）
        f.answers.remove("allergy")
        r.check("反向：删掉该项又变回不完整", !f.complete())

        // 会话状态机：nextSlot 按槽位表顺序推进，且**按值判定**（重提同一项不会跳字段）
        let s = PrevisitSession()
        r.check("空会话 nextSlot = 第 1 项（chief）", match (s.nextSlot()) {
            case Some(x) => x.key == "chief"
            case None => false
        })
        s.form.answers["chief"] = "咳嗽"
        r.check("填了 chief 后 nextSlot = 第 2 项（duration）", match (s.nextSlot()) {
            case Some(x) => x.key == "duration"
            case None => false
        })
        // ★ 幂等：重复写同一个键，nextSlot 不前进（网络重试安全）
        s.form.answers["chief"] = "咳嗽三天"
        r.check("★ 重写同一槽位不推进 nextSlot（重试幂等）", match (s.nextSlot()) {
            case Some(x) => x.key == "duration"
            case None => false
        })
        // 填满后 nextSlot = None（这就是"可以出业务值"的信号）
        for (sl in slots) {
            s.form.answers[sl.key] = "x"
        }
        r.check("填满后 nextSlot = None", s.nextSlot().isNone())

        // 表单 JSON 往返（存库用的序列化形式）
        let json = previsitFormJson(f)
        let back = previsitParseForm(json)
        r.check("表单 JSON 往返后键数一致", back.filled() == f.filled())
        // ★ 含特殊字符的答案必须能安全往返（手工拼 JSON 会在这里出问题）
        let f2 = PrevisitForm()
        f2.answers["chief"] = "咳嗽「带引号」和\n换行"
        let back2 = previsitParseForm(previsitFormJson(f2))
        r.check("★ 含引号/换行的答案往返无损", back2.answers["chief"] == f2.answers["chief"])
        // 坏 JSON 不得抛异常（只读操作不该 500）
        var threw = false
        try {
            let _bad = previsitParseForm("{不是合法 json")
        } catch (e: Exception) {
            threw = true
        }
        r.check("★ 库里的坏 JSON 不抛异常（退化成空表单，不 500）", !threw)
        r.check("坏 JSON 解析成空表单", !previsitParseForm("{坏").complete())
    })
}

/*
 * 按**字符**截断 —— 本项目已因"按字节截断"吃过一次 HTTP 500，
 * 这一组把它钉死在预问诊这条入口上（同类风险不能只在一处防）。
 */
func rpTruncate(r: TriageRunner): Unit {
    println("")
    println("--- 输入截断（字符空间）---")
    triageSection(r, "rpTruncate", { =>
        r.check("字符数：'胸痛' = 2（不是 6 字节）", previsitCharLen("胸痛") == 2)
        r.check("字符数：ASCII 'abcd' = 4", previsitCharLen("abcd") == 4)
        // ★ 混排（窄+宽）截断不得切坏 —— 与 triage 那次 500 同一个坑
        let mixed = "CT显示没有胸痛aaaa持续头痛"
        let cut = previsitTruncateChars(mixed, 5)
        r.check("★ 混排截断到 5 字符 = 'CT显示没'（实得 '${cut}'）", cut == "CT显示没")
        r.check("★ 截断结果是合法 UTF-8（能正常算字符数）", previsitCharLen(cut) == 5)
        r.check("截断不超长", previsitCharLen(previsitTruncateChars(mixed, 3)) == 3)
        r.check("n 大于长度时原样返回", previsitTruncateChars("abc", 99) == "abc")
        r.check("n = 0 返回空", previsitTruncateChars("abc", 0).size == 0)
        // 逐长度遍历：任何长度都不得切坏（按类别扫，不逐点试）
        var allOk = true
        var n: Int64 = 0
        while (n <= previsitCharLen(mixed)) {
            let c = previsitTruncateChars(mixed, n)
            if (previsitCharLen(c) != n) {
                allOk = false
            }
            n = n + 1
        }
        r.check("★ 0..长度 全遍历，每个截断结果的字符数都恰好等于 n", allOk)
    })
}

/*
 * 对话文本（可流式的那一半）：必须**分句**给出，且最终态有免责声明。
 */
func rpAssistantLines(r: TriageRunner): Unit {
    println("")
    println("--- 对话文本（可流式的那一半）---")
    triageSection(r, "rpAssistantLines", { =>
        let s = PrevisitSession()
        s.form.answers["chief"] = "咳嗽"
        s.turn = 0
        let l1 = previsitAssistantLines(s, None)
        // ★ 必须分句（>=2 行）—— 一次给一整段就不叫"流式"了
        r.check("★ 首轮对话文本是**多行**（可逐帧流出），实得 ${l1.size} 行", l1.size >= 2)
        var mentionsChief = false
        for (x in l1) {
            if (x.contains("咳嗽")) {
                mentionsChief = true
            }
        }
        r.check("★ 首轮回述主诉（让患者确认没被误解）", mentionsChief)
        var hasNextQ = false
        for (x in l1) {
            if (x.contains("持续多久")) {
                hasNextQ = true
            }
        }
        r.check("首轮末尾问下一个槽位（duration）", hasNextQ)

        // 中途：不重复回述主诉，但要带进度
        s.turn = 1
        let l2 = previsitAssistantLines(s, Some("chief"))
        var hasProgress = false
        for (x in l2) {
            if (x.contains("/")) {
                hasProgress = true
            }
        }
        r.check("中途带进度（形如 第 N/M 项）", hasProgress)

        // ★ 终态：必须声明"不能替代医生诊断"
        let full = PrevisitSession()
        for (sl in intakeSlots()) {
            full.form.answers[sl.key] = "x"
        }
        let l3 = previsitAssistantLines(full, Some("allergy"))
        var hasDisclaimer = false
        for (x in l3) {
            if (x.contains("不能替代医生诊断")) {
                hasDisclaimer = true
            }
        }
        r.check("★★ 采完后明确声明「不能替代医生诊断」（否则患者以为已看完病）", hasDisclaimer)
        r.check("采完后不再提问（无 '第 ' 开头的进度行）", !l3[0].contains("第 "))
    })
}