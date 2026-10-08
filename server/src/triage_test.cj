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
    rtDept(r)
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
