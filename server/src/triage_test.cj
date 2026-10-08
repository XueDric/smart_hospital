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
