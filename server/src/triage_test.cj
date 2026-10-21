/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 *
 * triage_test.cj —— P2 分诊与预问诊的纯逻辑自检（不连库、不调模型）。
 * 覆盖：危急征象（高危词/否定/模糊共现/宽度混排）、科室判定、SSE 帧格式、问诊单完整性、字符截断、增强预算。
 * 约束：只测规则层；没有真模型就不写假的模型测试，避免绿色的假保证。需要库的验证层断言在 acceptance.cj 的 AC-P2-*。
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

/* 逐用例异常兜底：一个用例抛异常不能让整个测试静默停在中途，该用例判失败即可。 */
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
    rtReviewP2(r)
    rtWidthMix(r)
    rtDept(r)
    rtDeptNegation(r)
    rtEnhanceBudget(r)
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

func rtNegation(r: TriageRunner): Unit {
    println("")
    println("--- 危急征象：否定式（**不得**误报）---")
    triageSection(r, "rtNegation", { =>
        /*
         * 中文没有词边界，裸 contains 会把「没有胸痛」判成"胸痛"，把没病的人赶去急诊 —— 与漏报同样是伤害；这组用例就是否定逻辑的守门人。
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

func rtVague(r: TriageRunner): Unit {
    println("")
    println("--- 危急征象：模糊词（单独不算，需与程度/频次共现）---")
    triageSection(r, "rtVague", { =>
        /*
         * 模糊词（心慌/头晕/疼）在日常汉语里大量用于非医疗语境，单独命中就报红牌会让红牌率飙到不可用 —— 必须与程度/频次共现才升级。
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

/*
 * P2-1 / P2-2 / P2-3 的回归用例：必须报与必须不报成对出现，只测"改后不报了"会写出一个一律不报的假绿。
 * P2-1 否定窗口过窄（假阳性）；P2-2 慢性/程度修饰词误升级（假阳性）；P2-3 词表只有"胸痛"漏口语同义（假阴性）。
 */
func rtReviewP2(r: TriageRunner): Unit {
    println("")
    println("--- ★★ 评审 P2-1 / P2-2 / P2-3 回归 ---")
    triageSection(r, "rtReviewP2", { =>
        /* P2-1：否定词距离命中词 6 个字符，必须仍作废（旧 4 字符窗口在这里全部误报）。 */
        let farNegation: Array<String> = [
            "我没有出现明显的胸痛",
            "病人否认发生过任何胸痛",
            "从来没出现过呼吸困难",
            "不太觉得有胸闷痛",
            "没有呕吐过血"
        ]
        for (c in farNegation) {
            r.check("P2-1 否定跨 6 字符仍作废：${c}", !detectRedFlag(c).redFlag)
        }

        /* P2-1 反向：窗口放宽到 8 最容易引入"太贪心"，否定不能跨分句吞掉真征象。 */
        let crossClause: Array<String> = [
            "没有发烧，胸痛",
            "否认高血压，突然胸口疼",
            "没有咳嗽，现在喘不过气"
        ]
        for (c in crossClause) {
            r.check("P2-1 反向：跨分句的真征象仍报红牌：${c}", detectRedFlag(c).redFlag)
        }

        /*
         * 否定窗口放宽后，contains(nego) 会把与本次命中无关的否定词也算成否认 —— 下面是"无关否定不得吃掉真征象"的护栏。
         */
        let unrelatedNegation: Array<String> = [
            "无法缓解的胸痛",
            "无明显诱因突发胸痛",
            "没胃口而且胸痛",
            "腹部不适伴胸痛"
        ]
        for (c in unrelatedNegation) {
            r.check("P2-1 复查：无关否定词不得吃掉真征象：${c}", detectRedFlag(c).redFlag)
        }

        /*
         * 真否定仍要判否定（间隔短、无阻断成分）。"不伴"是具体词形 —— 裸"不"已从否定表删除，否则会吃掉"不适/不停/不明显"里的症状。
         */
        let realNegation: Array<String> = [
            "不伴胸痛",
            "无胸痛",
            "没有胸痛",
            "未见明显胸痛"
        ]
        for (c in realNegation) {
            r.check("P2-1 复查：真否定仍作废：${c}", !detectRedFlag(c).redFlag)
        }

        /*
         * 顿号是并列枚举而非分句边界："无胸痛、咯血、呕血"三项都被"无"否定；"胸痛但无咯血"只有咯血被否定。
         */
        r.check("P2-1 复查：顿号并列里的否定传递到后续项", !detectRedFlag("无胸痛、咯血、呕血").redFlag)
        r.check("P2-1 复查：并列里的肯定项仍报红牌", detectRedFlag("胸痛但无咯血").redFlag)
        r.check("P2-1 复查：顿号不切断肯定并列", detectRedFlag("胸痛、咯血").redFlag)

        /* P2-2：慢性/程度修饰词 + 模糊词不得升级（"一直头晕""严重乏力"都不是红牌）。 */
        let chronicOnly: Array<String> = [
            "一直头晕",
            "严重乏力",
            "多年头痛",
            "经常心慌",
            "长期恶心",
            "一直有点头晕，睡不好"
        ]
        for (c in chronicOnly) {
            r.check("P2-2 慢性/程度修饰词不升级红牌：${c}", !detectRedFlag(c).redFlag)
        }

        /* P2-2 反向：急迫性修饰词仍必须升级，否则共现机制等于废掉。 */
        let urgentStill: Array<String> = [
            "突然头痛",
            "头晕越来越重",
            "恶心加重",
            "恶心剧烈",
            // 注意：胸闷既不在高危词表（那里只有胸闷痛）也不在模糊词表，所以"胸闷剧烈"不该报红牌 ——
            // 写断言前先确认这个词在哪张表里，否则测的是自己的误记。
            "乏力突然加重"
        ]
        for (c in urgentStill) {
            r.check("P2-2 反向：急迫修饰词仍升级红牌：${c}", detectRedFlag(c).redFlag)
        }

        /* P2-2 第三道：修饰词被否定时不升级（"疼痛没有加重"是好转的表述）。 */
        let modNegated: Array<String> = [
            "头痛没有加重",
            "头晕未见加重"
        ]
        for (c in modNegated) {
            r.check("P2-2 修饰词被否定则不升级：${c}", !detectRedFlag(c).redFlag)
        }

        /* P2-3：口语同义词与"胸痛"同级，单独命中即红牌，但不得引入误报。 */
        r.check("P2-3 「胸口疼」单独命中即红牌", detectRedFlag("胸口疼").redFlag)
        r.check("P2-3 「心口痛」单独命中即红牌", detectRedFlag("心口痛").redFlag)
        r.check("P2-3 「喘不过气」单独命中即红牌", detectRedFlag("喘不过气").redFlag)
        r.check("P2-3 「上不来气」单独命中即红牌", detectRedFlag("上不来气").redFlag)
        r.check("P2-3 「痰中带血」单独命中即红牌", detectRedFlag("痰中带血").redFlag)
        r.check("P2-3 「肚子疼得厉害」单独命中即红牌", detectRedFlag("肚子疼得厉害").redFlag)
        r.check("P2-3 情绪用语「心情闷得慌」**不**报红牌（同义词不能引入误报）",
                !detectRedFlag("心情闷得慌").redFlag)
        r.check("P2-3 反向：否定同义词同样作废（「没有胸口疼」）",
                !detectRedFlag("没有胸口疼").redFlag)
    })
}

func rtWidthMix(r: TriageRunner): Unit {
    println("")
    println("--- ★★ 宽度混排（ASCII 窄字符 + 汉字宽字符）---")
    triageSection(r, "rtWidthMix", { =>
        /*
         * 守的是宽度混排：否定窗口的字节/字符换算取错参照点会让起点落在多字节字符中间 —— 切出非法 UTF-8，普通主诉直接 HTTP 500。
         * 旧用例全是等宽纯汉字、边界永远不落在字符中间，只验了形态没验规则；这里改为按类别扫「前缀宽度 × 否定写法」的整个组合空间。
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
         * 复查给的 8 个具体输入要分两类断言：全部不抛异常（500 是原缺陷的表现）、其中 7 条纯否定不报红牌。
         * "aaaa持续头痛"按设计该报红牌（持续 = 程度修饰 + 头痛 = 模糊词，共现升级），混成一条会把正确行为报成失败。
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

func rtDeptNegation(r: TriageRunner): Unit {
    println("")
    println("--- ★★ 科室判定：被否认的症状不得主导推荐 ---")
    triageSection(r, "rtDeptNegation", { =>
        /*
         * 科室判定没处理否定时，"不胸闷，只是咳嗽"会推心血管内科，而有号校验是通过的、reason = OK，响应看起来权威 —— 比单纯分错科更危险。
         * 根因是裸 seg.contains：保险丝那条路处理了否定，同一语义两处实现只改了一处。
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

        // 顺序纪律：专科必须排在泛科之前（先匹配到的胜出）。
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
 * SSE 帧格式是"流式有没有按协议来"的唯一保证，错了只表现为客户端卡住、服务端日志完全看不出来。
 * 三条硬要求：帧必须恰好以 \n\n 结尾、帧内不得有裸换行、必须以 "data: " 开头（冒号后要空格）。
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
 * 业务值语义：关键区分是"无"与"留空"——「无过敏史」是有效阴性答案，医生可据此放心用药；留空是没答，医生必须再问。
 * 两者混起来会让问诊单出现"既往史 = 空"，而医生无法解释那是哪一种。
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

/* 按字符截断：本项目已因按字节截断吃过一次 HTTP 500，同类风险不能只在一处防。 */
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

/* 对话文本必须分句给出（可逐帧流出），终态带免责声明。 */
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

/*
 * 审计 F10：客户端等待上限 15s（Android）/ 20s（鸿蒙）比模型侧默认 30s 超时更短；模型慢时客户端先断开，服务端已备好的规则降级结果送不出去，患者看到的是请求失败。
 * 契约约束：TRIAGE_ENHANCEMENT_BUDGET_MS 是含 RAG 取数的整体截止时间，必须小于客户端最紧的 15s 并留余量，否则"降级结果送得出去"这个前提就没了。
 */
func rtEnhanceBudget(r: TriageRunner): Unit {
    println("")
    println("--- ★ 模型增强预算 vs 客户端等待上限（F10）---")
    triageSection(r, "rtEnhanceBudget", { =>
        let clientMinWaitMs: Int64 = 15000
        r.check("★★ 增强预算 < 客户端最紧的等待上限（${TRIAGE_ENHANCEMENT_BUDGET_MS}ms < ${clientMinWaitMs}ms）",
                TRIAGE_ENHANCEMENT_BUDGET_MS < clientMinWaitMs)
        r.check("★ 且留出余量（预算 ≤ 上限的 80%），避免「刚好赶上」变成常态",
                TRIAGE_ENHANCEMENT_BUDGET_MS * 10 <= clientMinWaitMs * 8)
    })
}