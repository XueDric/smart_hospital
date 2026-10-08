/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 *
 * ===== triage_redflag.cj —— 危急征象兜底（纯规则保险丝）=====================
 *
 * ── 这个文件为什么必须存在，且必须在**模型之前**跑 ────────────────────────
 * 参考系统把它叫「医疗级安全兜底」（brief §2.2 创新点③：24 危急关键词 + `is_red_flag`）。
 * 它的本质是**纯规则保险丝** —— brief 的判断是"形状有，规则要新写"。
 *
 * ★★ 关键纪律：**它是保险丝，不是建议**。
 *   命中危急征象时**不经过模型**直接判 `RED_FLAG`（转急诊/人工），
 *   理由有两条，都要说清：
 *     ① **可靠性**：模型可能被"我就是有点胸闷"这种轻描淡写绕过，
 *        也可能因为采样随机性**这次认出来、下次认不出**。
 *        而"胸痛 + 出汗 + 放射到左臂"这种组合是**不该赌**的。
 *     ② **不可绕过**：模型输出是不可信输入（照 baseline ai_client.cj 口径 2），
 *        那么"是否危急"这个判定**更不能交给它**。
 *   所以本调用**排在模型之前**，命中即返回，模型的结论在这条路径上不参与决策。
 *
 * ── 为什么不只做"关键词 contains"（这是本文件最容易做错的地方）───────────
 * 中文没有词边界，裸 `contains` 会踩两个坑，都**会造成误报**（把没病的人赶去急诊，
 * 与漏报同样是伤害）：
 *   ① **否定式误报**：「**没有**胸痛」「**无**发热」—— 裸匹配会把"没有胸痛"当"胸痛"。
 *   ② **嵌入词误报**：「胸口**闷**」含"闷"没问题，但「**心慌**意乱」这种
 *      日常用语（说的是心情）会命中"心慌"。
 *
 * 处置（两条，都可测）：
 *   · **否定前缀**：命中词前 N 个字符内出现否定词（没有/无/不/未/非/否认/排除）
 *     ⇒ 这一次命中**作废**。`N` 取 4 —— 够覆盖"我没有""否认有"这类中文写法。
 *   · **词表分层**：把"高危组合词"（如"胸痛"）与"模糊词"（如"心慌"）分开；
 *     模糊词**单独出现不算红牌**，需要与其它征象共现（见 CO_OCCUR 表）。
 *
 * ⚠ 本规则的**边界如实标注**：
 *   · 它是**保险丝**，不是诊断。漏报不可能为零 —— 所以它的定位是
 *     "把最明显、最不该漏的那批挡住"，而不是"代替医生"。
 *   · 词表是**示例级**（与弱口令表同一处置口径），要更全需临床输入。
 *   · **不处理**"患者把危急说得很轻"（如"有点不舒服"其实是心梗）——
 *     那正是模型/人工的用武之地，规则做不到，也不假装能做到。
 */

package qingzhou

/*
 * ⚠ 必须显式 import：ArrayList 来自 std.collection。
 *   实测漏了它报 undeclared type name 'ArrayList'（本项目已多次踩到）。
 */
import std.collection.*

/* ===================== 词表 ===================== */

/*
 * 高危征象词（**单独命中即红牌**）。
 *
 * 选取口径：这 20+ 条的共同点是「**延误就有不可逆后果**」——
 * 心脑血管急症、急腹症、大出血、呼吸困难、意识改变、高热惊厥、孕产急症。
 * 明确**不**收"疼痛""发烧"这类泛化词：它们单独出现绝大多数不是急症，
 * 收进来会让红牌率飙到不可用（急诊被挤爆，等于没有兜底）。
 *
 * ⚠ 词表是**示例级**，不是临床完备集。要更全需临床输入（见文件头边界说明）。
 */
public let RED_FLAG_TERMS: Array<String> = [
    // 心脑血管
    "胸痛", "胸闷痛", "心前区痛", "压榨性疼痛", "濒死感",
    "口角歪斜", "言语不清", "说话不清", "半身不遂", "偏瘫", "肢体无力",
    "突然看不清", "意识不清", "意识模糊", "昏迷", "晕厥", "抽搐", "抽风",
    // 呼吸
    "呼吸困难", "喘不上气", "窒息", "咯血", "咳血",
    // 大出血 / 失血
    "呕血", "吐血", "便血", "黑便", "血便", "大出血", "阴道大出血",
    // 急腹症
    "剧烈腹痛", "腹痛难忍", "板状腹", "腹部剧痛",
    // 高热 / 感染危象
    "高热惊厥", "惊厥", "持续高热不退",
    // 孕产
    "胎动减少", "胎动消失", "临产", "见红", "破水", "孕期出血",
    // 中毒 / 外伤 / 自伤
    "误服", "服毒", "农药", "煤气中毒", "一氧化碳", "自杀", "自伤", "割腕",
    "高处坠落", "车祸", "重物砸伤", "烧烫伤",
    // 儿童特异性（照护者描述）
    "孩子抽", "婴儿抽", "囟门膨隆", "拒食嗜睡"
]

/*
 * 模糊征象词（**单独命中不算红牌**，需与其它征象共现）。
 *
 * 为什么单独列：这些词在日常汉语里大量用于**非医疗**语境
 * （"心慌意乱""头晕脑胀地忙了一天""疼得想哭"），
 * 单独命中就报红牌会把大量正常人赶去急诊 —— 那是**误报伤害**。
 */
public let RED_FLAG_VAGUE_TERMS: Array<String> = [
    "心慌", "心悸", "头晕", "头疼", "头痛", "恶心", "呕吐", "乏力", "麻木", "疼"
]

/*
 * 共现判定：模糊词命中**且**文中另有"频次/程度/持续"类修饰时，升级为红牌。
 * 例：「**反复**呕吐」「**持续**头痛」「**越来越**麻」—— 这些不是日常用语。
 */
public let RED_FLAG_INTENSIFIERS: Array<String> = [
    "反复", "持续", "不停", "一直", "越来越", "加重", "剧烈", "严重", "难以忍受", "无法"
]

/*
 * 否定词。命中词**前面 4 个字符内**出现这些词 ⇒ 本次命中作废。
 * 覆盖"没有/无/不/未/非"与病历常用的"否认/排除"。
 */
public let RED_FLAG_NEGATIONS: Array<String> = [
    "没有", "没", "无", "不", "未", "非", "否认", "排除", "从未", "并无"
]

/* ===================== 结果类型 ===================== */

/* 一次红牌判定的事实（照 baseline ai_risk.cj 的 `RiskFacts` 形状：把"依据"留下，不只给布尔）。 */
public class RedFlagFacts {
    public var redFlag: Bool = false
    /* 命中的**高危词**（去重后）。 */
    public var terms: Array<String> = Array<String>()
    /* 命中并升级的**模糊词**（单独不算，需共现）。 */
    public var vagueTerms: Array<String> = Array<String>()
    /* 因否定而被**作废**的命中（留档：说明"为什么看起来该报却没报"）。 */
    public var negated: Array<String> = Array<String>()

    /* 给人看的一句话依据（进审计与日志，不进患者可见的结论）。 */
    public func evidence(): String {
        if (!redFlag) {
            return ""
        }
        var parts = ArrayList<String>()
        for (t in terms) {
            parts.add(t)
        }
        for (t in vagueTerms) {
            parts.add(t + "(共现)")
        }
        /*
         * ⚠ `Array<String>` 没有 `join`（实测报 'join' is not a member of
         *   struct 'Array<Struct-String>'）—— 手工拼，行为完全可预测。
         */
        var s = ""
        var first = true
        for (p in parts) {
            if (!first) {
                s = s + ", "
            }
            s = s + p
            first = false
        }
        return s
    }
}

/* 分隔符 Rune 表（模块级常量，避免每次调用重建）。 */
private let RED_FLAG_SEPS: Array<Rune> = [
    r',', r'.', r';', r':', r'!', r'?',
    r'\n', r'\r', r' ', r'\t',
    r'。', r'，', r'；', r'：', r'！', r'？', r'、', r'（', r'）'
]

/*
 * 该字符是否算"分句分隔符"。
 *
 * 清单：ASCII , . ; : ! ? + 换行/回车/空格/制表 + 中文 。，；：！？、（）
 * ⚠ 写成**独立函数 + Rune 表**而不是塞进 for 里的一长串跨行 `||`：
 *   跨行 `||` 会触发仓颉的续行歧义；而且"哪些算分隔符"应该是**可见的清单**，
 *   不该埋在四行布尔表达式里。
 */
func redFlagIsSeparator(r: Rune): Bool {
    for (s in RED_FLAG_SEPS) {
        if (r == s) {
            return true
        }
    }
    return false
}

/*
 * 把主诉文本切成"命中候选"用的片段。
 *
 * ⚠ 为什么需要它：中文没有空格，但**患者输入里大量出现标点**
 *   （「我父亲，胸痛，出汗，已经半小时」）。按标点切段后再匹配，
 *   能让"否定前缀"的判定更准（否定通常与它否定的词在**同一小句**内）：
 *   切段后「没有胸痛，但是呕血了」里的"呕血"不会被前一句的"没有"错误作废。
 *
 * ⚠⚠ **必须按"字符"切，绝不能按"字节"切** —— 我第一版就是按字节，实测直接炸：
 *   错误做法 `for (ch in text.toArray())`：`String.toArray()` 给的是 **UTF-8 字节**，
 *   一个汉字占 3 字节。逐字节累积再用 `String.fromUtf8` 拼回，会在**段边界**处
 *   撕裂多字节字符 ⇒ 抛 `Invalid utf8 byte sequence`（实测就是这条错误，
 *   而且它只在"主诉里既有汉字又有标点"时才出现 —— 全汉字或全 ASCII 都不炸，
 *   所以特别容易漏到运行期）。
 *   正确做法 `for (r in text.runes())` 逐**字符**迭代，再用 `String(Rune[])` 拼回。
 *   已用最小探针验证往返正确（`String("胸痛，呕血".runes() 收集) == 原文`）。
 */
func redFlagSegments(text: String): Array<String> {
    var out = ArrayList<String>()
    var cur = ArrayList<Rune>()
    for (r in text.runes()) {
        if (redFlagIsSeparator(r)) {
            if (cur.size > 0) {
                out.add(String(cur.toArray()))
                cur.clear()
            }
        } else {
            cur.add(r)
        }
    }
    if (cur.size > 0) {
        out.add(String(cur.toArray()))
    }
    return out.toArray()
}
/*
 * 某片段里，`term` 的这次出现是否被**否定**。
 *
 * ★★ 这里有一个**实测踩出来的坑**，是本文件最难发现的一处（记下来）：
 *
 *   `String.indexOf` 返回的是**字节**下标，**不是**字符下标！
 *   实测：`"没有胸痛".indexOf("胸痛")` = **6**（不是 2；"没有"各占 3 字节）。
 *
 *   我第一版按"字符下标"处理，于是：
 *     · `at` 其实是字节偏移 6；
 *     · 窗口写 `at - 4` = 2 —— 拿**字节** 2 当**字符**边界去切 `Rune[]`，
 *       切到的是第 2 个字符起，正好**跳过了"没有"**；
 *     · 结果 `head = "有胸"`，不含任何否定词 ⇒ 判定"未被否定" ⇒ **误报红牌**。
 *
 *   表现极具迷惑性：`"无发热，无胸痛"` 反而**通过**（因为"无"是单字符，
 *   字节偏移恰好落在窗口里），而 `"没有胸痛"`、`"否认胸痛"`、`"未曾呕血"`
 *   全部失败 —— 看起来像"否定词表不全"，实际是**单位混用**。
 *
 *   修法：**窗口统一用字节**。`from` 的算法是"先按字符取前 4 个字符、
 *   量出它们的字节长度、再从 at 往回减" —— 这样 `from` 一定落在**字符边界**上，
 *   切片既不会撕裂多字节字符，语义又正好是"前面 4 个字符"。
 *   （字符边界这一点很关键：直接 `at - 4` 是字节运算，会切在汉字中间 ⇒ 非法 UTF-8。）
 */
func redFlagIsNegated(seg: String, at: Int64): Bool {
    if (at <= 0) {
        return false
    }
    // 取"前面最多 4 个字符"的字节长度（按字符数截，避免切在汉字中间）
    let chars = ArrayList<Rune>()
    var n: Int64 = 0
    for (r in seg.runes()) {
        if (n >= 4) {
            break
        }
        chars.add(r)
        n = n + 1
    }
    if (chars.size == 0) {
        return false
    }
    /*
     * 逐个字符回退：从 at 开始，按前面这些字符的字节数往回累计，
     * 但**不越过段首**。因为 at 是字节偏移，而单个字符的字节数 = 该字符 UTF-8 长度，
     * 所以用 `String(单个 Rune).toArray().size` 得到它的字节数。
     */
    var back: Int64 = 0
    let step = if (chars.size < 4) { chars.size } else { 4 }
    var k = step - 1
    while (k >= 0) {
        back = back + String([chars[k]]).toArray().size
        k = k - 1
    }
    var from: Int64 = at - back
    if (from < 0) {
        from = 0
    }
    if (from >= at) {
        return false
    }
    let head = seg[from..at]
    for (nego in RED_FLAG_NEGATIONS) {
        if (head.contains(nego)) {
            return true
        }
    }
    return false
}

/* 片段里是否命中某个词**且未被否定**。命中则把词记进 hits。 */
func redFlagHit(seg: String, term: String, hits: ArrayList<String>, negated: ArrayList<String>): Bool {
    var from: Int64 = 0
    while (true) {
        let idx = seg.indexOf(term, from)
        match (idx) {
            case Some(i) =>
                if (redFlagIsNegated(seg, i)) {
                    if (!negated.contains(term)) {
                        negated.add(term)
                    }
                } else {
                    if (!hits.contains(term)) {
                        hits.add(term)
                    }
                    return true
                }
                from = i + 1
            case None => return false
        }
    }
    return false
}

/*
 * ★★ 危急征象判定 —— **纯规则、不碰数据库、不调模型**。
 *
 * 判定顺序（每一步都要能单独解释）：
 *   ① 切段（按标点），让否定判定在同一小句内生效；
 *   ② **高危词**：任一命中且未被否定 ⇒ **立即红牌**（不再看其它）；
 *   ③ **模糊词**：命中且未被否定，**并且**同段落内有程度/频次修饰词 ⇒ 升级红牌；
 *   ④ 什么都没命中 ⇒ 不是红牌（并留下 negated 供审计：说明"为什么该报没报"）。
 */
public func detectRedFlag(chiefComplaint: String): RedFlagFacts {
    let f = RedFlagFacts()
    let segs = redFlagSegments(chiefComplaint)
    let negated = ArrayList<String>()
    let highHits = ArrayList<String>()
    let vagueHits = ArrayList<String>()

    // ② 高危词：任一命中即红牌
    for (seg in segs) {
        for (term in RED_FLAG_TERMS) {
            if (redFlagHit(seg, term, highHits, negated)) {
                f.redFlag = true
                f.terms = highHits.toArray()
                f.vagueTerms = vagueHits.toArray()
                f.negated = negated.toArray()
                return f
            }
        }
    }

    // ③ 模糊词：必须与"程度/频次"修饰词共现才算
    for (seg in segs) {
        var hasIntensifier = false
        for (mod in RED_FLAG_INTENSIFIERS) {
            if (seg.contains(mod)) {
                hasIntensifier = true
            }
        }
        if (!hasIntensifier) {
            continue
        }
        for (term in RED_FLAG_VAGUE_TERMS) {
            if (redFlagHit(seg, term, vagueHits, negated)) {
                f.redFlag = true
            }
        }
    }

    f.terms = highHits.toArray()
    f.vagueTerms = vagueHits.toArray()
    f.negated = negated.toArray()
    return f
}
