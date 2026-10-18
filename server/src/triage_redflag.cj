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
 *     ② **不可绕过**：模型输出是不可信输入（照搬迁前的 ai_client.cj 口径 2），
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
/*
 * 急迫性修饰词 —— **可以**把模糊征象升级为红牌。
 *
 * ★★ 2026-10-17 评审 P2-2：这一张表原来叫 `RED_FLAG_INTENSIFIERS`，把
 *   「程度重」和「急迫」混成一张，于是「一直头晕」「严重乏力」这类**慢病主诉**
 *   被判成红牌 —— 那是**误报伤害**（把不需要急诊的人赶去急诊）。
 *   现在按**语义**拆成两张：
 *     · 本表 = 「急性起病 / 进行性加重」，命中才升级；
 *     · `RED_FLAG_CHRONIC_MODIFIERS` = 「病程长 / 程度重」，**不升级**。
 *   判据不是"听起来严重"，而是"**延误会不会有不可逆后果**"——
 *   持续半小时的胸痛会，头晕三个月不会。
 *
 * ⚠ 第二道校验（同一处修复）：修饰词必须**紧贴**模糊词（同一分句内、
 *   相距 ≤ `RED_FLAG_COOCCUR_WINDOW` 个字符），且修饰词本身**未被否定**。
 *   原来的实现是 `seg.contains(mod)` —— 整段里任意位置出现就算共现，
 *   于是「头晕，血压一直正常」也会被判红牌。现在不是了。
 */
public let RED_FLAG_URGENT_MODIFIERS: Array<String> = [
    "反复", "持续", "不停", "越来越", "加重", "加剧", "剧烈",
    "难以忍受", "无法忍受", "受不了", "突然", "突发", "骤发", "急剧"
]

/*
 * 病程 / 程度修饰词 —— **单独不足以**升级为红牌（2026-10-17 评审 P2-2 新增）。
 *
 * 为什么单列：这些词描述的是"**长期如此**"或"**程度主观_strong**"，
 * 恰恰说明**不是新发的急症**。「一直头晕」「严重乏力」「多年头痛」
 * 是慢病随访场景的典型主诉，报红牌会把规则的可信度耗光。
 * 保留成表（而不是直接删掉）是为了**可解释**与**留痕**。
 * ⚠ 2026-10-17 复查如实说明：本表**当前没有消费者** —— 判定路径不会读它，
 *   也不会把它写进 `negated`（"命中时写进 negated"是当时的设想，未实现）。
 *   保留的价值是"决策留档"：后人要回答"为什么不算红牌"，表本身就是答案。
 */
public let RED_FLAG_CHRONIC_MODIFIERS: Array<String> = [
    "一直", "长期", "多年", "经常", "总是", "严重", "轻微", "轻度", "偶尔"
]

/* 模糊词与修饰词的**共现窗口**（字符数）：同一分句内、相距不超过这么多字符才算共现。 */
public let RED_FLAG_COOCCUR_WINDOW: Int64 = 6

/*
 * 否定词。命中词**前面 `RED_FLAG_NEGATION_WINDOW` 个字符内**出现这些词 ⇒ 本次命中作废。
 * 覆盖"没有/无/未/非"与病历常用的"否认/排除"。
 *
 * ★★ 2026-10-17 复查：**裸"不"从表里删掉了**。理由：它是超级高频的构词成分
 *   （不适 / 不停 / 不同 / 不明显 / 不出血），当否定词用会**吃掉真症状** ——
 *   「腹部不适伴胸痛」里"不"距"胸痛"只有 2 个字符，会把胸痛判成"否认"⇒ 危急漏报。
 *   真正的"不"式否定收成具体词形：不伴（「不伴胸痛」）。
 * ⚠ 取舍方向：宁可多报（误报伤害小、可复核），不可漏报。
 *
 * ★★ 2026-10-17 评审 P2-1：窗口原来是 **4 个字符**，实测漏判 ——
 *   「我没有出现明显的胸痛」里"没有"距"胸痛"是 6 个字符，
 *   于是"否认了胸痛"被读成"有胸痛"（假阳性，且方向最危险：给正常人的报告标红）。
 *   现在放宽到 8，并且**只在同一分句内**数（`redFlagSegments` 已经按标点切过段，
 *   所以跨分句的"没有"不会误伤，例如「没有发烧，胸痛」里"没有"不在"胸痛"那一句）。
 */
public let RED_FLAG_NEGATION_WINDOW: Int64 = 8

/*
 * 否定词与症状词之间**允许的间隔**（字符数）—— 2026-10-17 复查新增。
 *
 * 两档，因为两类否定词的"管辖范围"不一样：
 *   · **多字**否定（没有 / 否认 / 未见 / 无明显 …）是**述语级**的，可以隔着
 *     宾语和修饰语管到后面的症状：「我没有**出现明显的**胸痛」间隔 5，必须判否定；
 *   · **单字**否定（无 / 未 / 非 / 不）只能**紧贴**症状（间隔 ≤ 1），否则它几乎
 *     一定是别的词的构词成分：「肢体**无力**伴胸痛」（间隔 2）、
 *     「**无法**缓解的胸痛」（间隔 4）都不是在否认胸痛。
 * ⚠ 纯用一个数做不到：要求 ≥5 会把「无法缓解的胸痛」读成否认（**危急漏报**），
 *   要求 ≤3 又会把「没有出现明显的胸痛」读成肯定（误报）。两档是这里的解。
 */
public let RED_FLAG_NEGATION_GAP_MAX: Int64 = 6

/* 单字否定词允许的最大间隔（见上）。 */
public let RED_FLAG_NEGATION_GAP_SHORT: Int64 = 1

/*
 * 间隔里出现这些成分 ⇒ 否定的**作用对象是别的东西**，不能把症状判成"否认"。
 * 例：「没胃口**而且**胸痛」（连词换了主语）、「无**明显诱因**突发胸痛」
 * （否的是"诱因"，胸痛是**有**的 —— 这是最危险的漏报形态）。
 */
public let RED_FLAG_NEGATION_BLOCKERS: Array<String> = ["而", "且", "但", "却", "诱因", "原因"]

/*
 * **缺席动词** —— 单字否定（没/无/未）后面接一个"发生类"动词时，否定仍然管到症状：
 *   「从来**没**_**出现过**_呼吸困难」「**没**_**有**_胸痛」「**未**_**见**_呕血」。
 * 为什么需要这条：单字否定的间隔上限只有 1（防"无力/不适"这类构词误伤），
 * 而"没 + 出现过 + 呼吸困难"的间隔是 3 —— 不认这条就会把"从来没有过"读成"有"。
 * ⚠ 只认这些**明确的缺席述语**；"没胃口胸痛"不在此列（胃口不是缺席动词），仍报红牌。
 */
public let RED_FLAG_ABSENCE_VERBS: Array<String> = [
    "出现过", "出现", "发生过", "发生", "有过", "有", "见过", "见",
    "感觉到", "感觉", "觉得", "察觉", "发现", "碰见", "经历", "再"
]

/* 缺席动词与症状之间允许出现的修饰成分（「出现**明显的**胸痛」）。 */
public let RED_FLAG_ABSENCE_FILLERS: Array<String> = [
    "的", "过", "了", "明显", "任何", "症状", "情况", "现象", "发作", "过任何"
]

public let RED_FLAG_TERMS: Array<String> = [
    // 心脑血管 —— 胸痛的各种口语写法（★ 2026-10-17 评审 P2-3：原来只有"胸痛"，
    //   患者说"胸口疼""心口痛"就漏了。口语同义词是真实用户的第一表达习惯。）
    "胸痛", "胸闷痛", "心前区痛", "压榨性疼痛", "濒死感",
    "胸口疼", "胸口痛", "胸口闷", "心口疼", "心口痛", "胸前区痛", "胸骨后痛", "胸骨后疼痛",
    "口角歪斜", "口眼歪斜", "言语不清", "说话不清", "说话含糊", "舌根发硬",
    "半身不遂", "偏瘫", "肢体无力", "半边身子麻", "一侧无力",
    "突然看不清", "意识不清", "意识模糊", "意识丧失", "昏迷", "晕厥", "晕倒", "抽搐", "抽风",
    // 呼吸（"喘不过气/上不来气/憋气"是呼吸困难最常见的口语说法）
    "呼吸困难", "喘不上气", "喘不过气", "上不来气", "气短憋气", "憋气", "窒息", "咯血", "咳血",
    "痰中带血",
    // 大出血 / 失血
    "呕血", "吐血", "便血", "黑便", "血便", "大便发黑", "大出血", "阴道大出血",
    // 急腹症
    "剧烈腹痛", "腹痛难忍", "板状腹", "腹部剧痛", "肚子疼得厉害", "腹痛剧烈",
    // 高热 / 感染危象
    "高热惊厥", "惊厥", "持续高热不退", "高烧不退",
    // 孕产
    "胎动减少", "胎动消失", "胎动变少", "临产", "见红", "破水", "孕期出血",
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
 * 否定词 —— 见上方 `RED_FLAG_NEGATION_WINDOW` 的说明（2026-10-17 评审 P2-1：
 * 窗口 4 → 8 个字符，因为「我没有出现明显的胸痛」这种写法里"没有"距命中词 6 个字符）。
 */
public let RED_FLAG_NEGATIONS: Array<String> = [
    "没有", "没", "无任何", "无明显", "无", "未见", "未出现", "未", "非",
    "否认", "排除", "从未", "并无", "不伴", "不太", "没怎么",
    // 单字否定：只能紧贴症状（间隔 ≤ RED_FLAG_NEGATION_GAP_SHORT），否则多半是构词成分
    "不"
]

/* ===================== 结果类型 ===================== */

/* 一次红牌判定的事实（照搬迁前的 ai_risk.cj 的 `RiskFacts` 形状：把"依据"留下，不只给布尔）。 */
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
    r'。', r'，', r'；', r'：', r'！', r'？', r'（', r'）'
]

/*
 * 该字符是否算"分句分隔符"。
 *
 * 清单：ASCII , . ; : ! ? + 换行/回车/空格/制表 + 中文 。，；：！？（）。
 * ★★ 2026-10-17 复查：**顿号「、」从这里移除了** —— 它是**并列枚举**而不是分句边界。
 *   「无胸痛、咯血、呕血」按顿号切段后，"无"只作用于第一段，后两个词被误报红牌；
 *   保留在同一段里，`redFlagIsNegatedAt` 的"枚举链"判据才能把否定传递下去。
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
/* ===================== 字符空间工具（本文件所有下标运算的统一口径）===== */

/*
 * 把片段拆成 `Rune[]`。**所有涉及"下标"的判断都必须经过它**。
 *
 * ★★ 为什么必须集中到这里（这是本文件踩了两次、被复查各抓出一次的根因）：
 *
 *   仓颉 `String` 的**下标 / 切片 / `indexOf` 全都是「字节」语义**，
 *   而 `size` 是**字节数** —— 只有 `runes()` 是字符语义。
 *   一旦在同一个表达式里混用，就会出现"看起来对、只在特定宽度组合下炸"的缺陷：
 *
 *     · 第一次（复查④）：`at` 是字节偏移，我却按字符下标去切 rune 数组 ⇒
 *       窗口跳过"没有" ⇒ 误报红牌。当时我"修"成"窗口统一用字节"。
 *     · 第二次（复查⑤，本次）：那个修法**仍然错的** —— 它取的是
 *       "**片段开头**前 4 个字符"的字节数，而不是"**`at` 之前** 4 个字符"的字节数。
 *       于是当片段以 ASCII 开头（`CT显示…`，前 4 字符只占 4 字节）而命中词前是
 *       汉字（每字 3 字节）时，`from = at - 4` 落在**第二个汉字中间** ⇒
 *       `seg[from..at]` 切出非法 UTF-8 ⇒ **普通主诉直接 HTTP 500**。
 *
 *   ⇒ 结论：**不要在字节空间里做减法。** 下标一律先换算成**字符下标**，
 *     窗口、切片、回退全部在 `Rune[]` 上做，最后只需要"拼回字符串"时才碰字节。
 *     📌 这也是"逐点修 vs 按类别扫"的区别 —— 前两次我都在**同一个表达式**里
 *     打补丁，而正确做法是**把这个类别的运算全部收口到一个口径**（本函数）。
 */
func redFlagRunes(seg: String): Array<Rune> {
    let out = ArrayList<Rune>()
    for (r in seg.runes()) {
        out.add(r)
    }
    return out.toArray()
}

/* 某**字符**下标 `chat` 之前（不含）的窗口文本，最多 `width` 个字符。 */
func redFlagWindowBefore(chars: Array<Rune>, chat: Int64, width: Int64): String {
    if (chat <= 0 || chars.size == 0) {
        return ""
    }
    var from: Int64 = 0
    if (chat > width) {
        from = chat - width
    }
    if (from >= chat) {
        return ""
    }
    if (chat > chars.size) {
        return ""
    }
    return String(chars[from..chat])
}

/* ===================== 否定判定（字符空间）===================== */

/*
 * ★★ 字符下标 `chat` 处的那次命中，是否被**否定**（2026-10-17 复查重写）。
 *
 * 演化过程（三次，前两次都错，值得留档）：
 *   ① 窗口写死 4：`我没有出现明显的胸痛`（"没有"距"胸痛"6 字）漏判 ⇒ 否认被读成"有"；
 *   ② 窗口放宽到 8 + `head.contains(nego)`：**反向漏报更危险** —— 窗口内任何
 *      一个否定词都算数，于是
 *        「无法缓解的胸痛」      "无法"修饰的是"缓解"，胸痛必须报红牌；
 *        「无明显诱因突发胸痛」  "无明显"修饰的是"诱因"；
 *        「没胃口而且胸痛」      "没"在另一个并列成分里。
 *      三种全被读成"否认" ⇒ **危急信号漏报**（比误报危险得多）；
 *   ③ 现在：否定词必须与症状词**挨得够近**（间隔 ≤ `RED_FLAG_NEGATION_GAP_MAX`），
 *      且间隔里不得出现把否定指向别处的连接成分（`RED_FLAG_NEGATION_BLOCKERS`）；
 *      另加一条**并列枚举**通道（「无胸痛、咯血、呕血」三个词都被"无"否定）。
 *
 * 判据汇总：
 *   ① 直接否定 —— 8 字窗口内有否定词，间隔 ≤ 3 且无阻断成分；
 *   ② 枚举否定 —— 8 字窗口内有否定词，其后的路径全由「红牌词 + 顿号」组成。
 * ⚠ 窗口与间隔都按**字符**数，不是字节 —— 理由见 `redFlagRunes` 的长注释。
 * ⚠ 窗口不跨分句，因为 `redFlagSegments` 已按标点切段（顿号**不在**分隔符里）。
 */
func redFlagIsNegatedAt(chars: Array<Rune>, chat: Int64): Bool {
    if (chat <= 0) {
        return false
    }
    if (redFlagNegatedDirect(chars, chat)) {
        return true
    }
    if (redFlagNegatedByAbsenceVerb(chars, chat)) {
        return true
    }
    return redFlagNegatedByEnumeration(chars, chat)
}

/* 判据 ①：否定词紧邻本次命中（间隔受 `RED_FLAG_NEGATION_GAP_MAX` 限制且无阻断成分）。 */
func redFlagNegatedDirect(chars: Array<Rune>, chat: Int64): Bool {
    var i = redFlagWindowStart(chars, chat, RED_FLAG_NEGATION_WINDOW)
    while (i < chat) {
        for (nego in RED_FLAG_NEGATIONS) {
            let nc = redFlagRunes(nego)
            if (nc.size > 0 && redFlagMatchAt(chars, i, nc)) {
                let after = i + nc.size
                let gap = chat - after
                let limit = if (nc.size <= 1) { RED_FLAG_NEGATION_GAP_SHORT } else { RED_FLAG_NEGATION_GAP_MAX }
                if (gap >= 0 && gap <= limit) {
                    if (!redFlagGapHasBlocker(String(chars[after..chat]))) {
                        return true
                    }
                }
            }
        }
        i = i + 1
    }
    return false
}

/* 间隔里是否出现"把否定指向别处"的连接成分（「无法**缓解**的胸痛」）。 */
func redFlagGapHasBlocker(gap: String): Bool {
    for (b in RED_FLAG_NEGATION_BLOCKERS) {
        if (gap.contains(b)) {
            return true
        }
    }
    return false
}

/*
 * 判据 ①b：**单字否定 + 缺席动词**（「从来没出现过呼吸困难」）。
 * 从否定词末尾走到症状词开头：只允许「缺席动词」与「修饰填充」交替出现。
 */
func redFlagNegatedByAbsenceVerb(chars: Array<Rune>, chat: Int64): Bool {
    var i = redFlagWindowStart(chars, chat, RED_FLAG_NEGATION_WINDOW)
    while (i < chat) {
        for (nego in RED_FLAG_NEGATIONS) {
            let nc = redFlagRunes(nego)
            if (nc.size != 1 || !redFlagMatchAt(chars, i, nc)) {
                continue
            }
            if (redFlagAbsencePathCovers(chars, i + nc.size, chat)) {
                return true
            }
        }
        i = i + 1
    }
    return false
}

/* `[from, to)` 是否由「缺席动词 / 修饰填充」组成（至少一个动词）。 */
func redFlagAbsencePathCovers(chars: Array<Rune>, from: Int64, to: Int64): Bool {
    if (from >= to) {
        return false
    }
    var pos = from
    var verbs: Int64 = 0
    while (pos < to) {
        var advanced = false
        for (v in RED_FLAG_ABSENCE_VERBS) {
            let vc = redFlagRunes(v)
            if (vc.size > 0 && vc.size <= to - pos && redFlagMatchAt(chars, pos, vc)) {
                pos = pos + vc.size
                verbs = verbs + 1
                advanced = true
                break
            }
        }
        if (!advanced) {
            for (f in RED_FLAG_ABSENCE_FILLERS) {
                let fc = redFlagRunes(f)
                if (fc.size > 0 && fc.size <= to - pos && redFlagMatchAt(chars, pos, fc)) {
                    pos = pos + fc.size
                    advanced = true
                    break
                }
            }
        }
        if (!advanced) {
            return false
        }
        if (pos > to) {
            return false
        }
    }
    return verbs > 0 && pos == to
}

/* 判据 ②：否定词与本次命中之间只有「红牌词 + 顿号」（「无胸痛、咯血、呕血」）。 */
func redFlagNegatedByEnumeration(chars: Array<Rune>, chat: Int64): Bool {
    var i = redFlagWindowStart(chars, chat, RED_FLAG_NEGATION_WINDOW)
    while (i < chat) {
        for (nego in RED_FLAG_NEGATIONS) {
            let nc = redFlagRunes(nego)
            if (nc.size > 0 && redFlagMatchAt(chars, i, nc)) {
                let after = i + nc.size
                if (after <= chat && redFlagEnumerationCovers(chars, after, chat)) {
                    return true
                }
            }
        }
        i = i + 1
    }
    return false
}

/*
 * `[from, to)` 是否正好由「红牌词 / 顿号等并列连接符」组成（可空，允许空区间）。
 * ⚠ 也接受**红牌词直接相邻**（「无呕血便血」这种不写顿号的并列）。
 *   这条放宽是有意的：判错的代价不对称 —— 多判"否认"是漏报（危险），
 *   多判"肯定"是误报（可复核）。而能凑成"红牌词紧邻"的写法几乎只有并列。
 */
func redFlagEnumerationCovers(chars: Array<Rune>, from: Int64, to: Int64): Bool {
    var pos = from
    var hops: Int64 = 0
    while (pos < to) {
        var advanced = false
        let r = chars[pos]
        if (r == r'、' || r == r'和' || r == r'及' || r == r'与') {
            pos = pos + 1
            advanced = true
        }
        if (!advanced) {
            var best: Int64 = 0
            for (term in RED_FLAG_TERMS) {
                let tc = redFlagRunes(term)
                if (tc.size > best && tc.size <= to - pos && redFlagMatchAt(chars, pos, tc)) {
                    best = tc.size
                }
            }
            for (term in RED_FLAG_VAGUE_TERMS) {
                let tc = redFlagRunes(term)
                if (tc.size > best && tc.size <= to - pos && redFlagMatchAt(chars, pos, tc)) {
                    best = tc.size
                }
            }
            if (best > 0) {
                pos = pos + best
                advanced = true
            }
        }
        if (!advanced) {
            return false
        }
        hops = hops + 1
        if (hops > 16) {
            return false
        }
    }
    return true
}

/* 窗口起点（字符下标），窗口宽度 `width`；供两段式判定共用。 */
func redFlagWindowStart(chars: Array<Rune>, chat: Int64, width: Int64): Int64 {
    if (chat > width) {
        return chat - width
    }
    return 0
}

/*
 * 字符下标 `at` 处是否出现 `term`（纯匹配，不做否定判定）。
 * 供"共现窗口"这类需要**位置**的判定复用，避免再写一遍 Rune 比较。
 */
func redFlagMatchAt(chars: Array<Rune>, at: Int64, termChars: Array<Rune>): Bool {
    if (termChars.size == 0 || at < 0 || at + termChars.size > chars.size) {
        return false
    }
    var matched: Int64 = 0
    while (matched < termChars.size && chars[at + matched] == termChars[matched]) {
        matched = matched + 1
    }
    return matched == termChars.size
}

/*
 * ★★ 模糊词与**急迫性**修饰词是否构成"共现"（2026-10-17 评审 P2-2 重写）。
 *
 * 语义：在模糊词命中位置 `termAt` 的前后 `RED_FLAG_COOCCUR_WINDOW` 个字符内，
 *   存在一个**未被否定**的急迫性修饰词。
 *
 * 与旧实现的差别（三条，缺一条都还是错）：
 *   ① 修饰词只认 `RED_FLAG_URGENT_MODIFIERS`（"一直/严重"不在里面）；
 *   ② 要求**距离近**（同分句内 ≤ 窗口），不再 `seg.contains(mod)` 整段命中；
 *   ③ 修饰词自身**不能是否定** ——「疼痛没有加重」不该升级。
 */
func redFlagHasUrgentCooccur(chars: Array<Rune>, termAt: Int64, termLen: Int64): Bool {
    let termEnd = termAt + termLen
    for (mod in RED_FLAG_URGENT_MODIFIERS) {
        let modChars = redFlagRunes(mod)
        if (modChars.size == 0 || modChars.size > chars.size) {
            continue
        }
        var at: Int64 = 0
        let last = chars.size - modChars.size
        while (at <= last) {
            if (redFlagMatchAt(chars, at, modChars)) {
                let modEnd = at + modChars.size
                // 修饰词在模糊词**之前**：`modEnd` 到 `termAt` 之间不超过窗口
                let before = if (modEnd <= termAt) { termAt - modEnd <= RED_FLAG_COOCCUR_WINDOW } else { false }
                // 修饰词在模糊词**之后**（"头痛加重"）：`at` 到 `termEnd` 之间不超过窗口
                let after = if (at >= termEnd) { at - termEnd <= RED_FLAG_COOCCUR_WINDOW } else { false }
                if ((before || after) && !redFlagIsNegatedAt(chars, at)) {
                    return true
                }
            }
            at = at + 1
        }
    }
    return false
}

/*
 * ★★ 片段里 `term` 是否**未被否定地**出现一次。
 *
 * 返回：命中且未被否定 ⇒ true；并顺带把"命中词/被否定的词"记进 hits / negated。
 *
 * 保留 String 入口供常规科室规则复用；完整危急检测用下方 Rune 入口，
 * 同一片段只转换一次。匹配、否定窗口和下一次起点全部使用字符下标。
 */
func redFlagHit(seg: String, term: String, hits: ArrayList<String>,
                negated: ?ArrayList<String>): Bool {
    return redFlagHitChars(redFlagRunes(seg), term, hits, negated)
}

/*
 * 顺序比较 Rune，不再为每个否定命中从头计算字符/字节偏移。
 * 每个候选起点最多比较 termChars.size 个字符；否定判定见 `redFlagIsNegatedAt`
 * （8 字符窗口 + 间隔 ≤ 3 + 并列枚举通道，不再是"窗口内出现即作废"）。
 * 对固定词表，全文工作量 O(n*k*m)，k 是词数、m 是最长词长，均为常量。
 * 否定命中后仍只前进一个字符，保持原 indexOf 实现对重叠命中的语义。
 */
func redFlagHitChars(chars: Array<Rune>, term: String, hits: ArrayList<String>,
                     negated: ?ArrayList<String>): Bool {
    let termChars = redFlagRunes(term)
    if (termChars.size == 0 || termChars.size > chars.size) {
        return false
    }
    var at: Int64 = 0
    let last = chars.size - termChars.size
    while (at <= last) {
        var matched: Int64 = 0
        while (matched < termChars.size && chars[at + matched] == termChars[matched]) {
            matched = matched + 1
        }
        if (matched == termChars.size) {
            if (redFlagIsNegatedAt(chars, at)) {
                match (negated) {
                    case Some(acc) =>
                        if (!acc.contains(term)) {
                            acc.add(term)
                        }
                    case None => ()
                }
            } else {
                if (!hits.contains(term)) {
                    hits.add(term)
                }
                return true
            }
        }
        at = at + 1
    }
    return false
}

/*
 * ★★ 模糊词"升级"判定（2026-10-17 评审 P2-2 新增，取代原来的两段式判定）。
 *
 * 一次扫描同时回答三个问题：
 *   ① 这个模糊词**未被否定**地出现了吗？
 *   ② 它附近（≤ `RED_FLAG_COOCCUR_WINDOW`）有**急迫性**修饰词吗？
 *   ③ 那个修饰词本身**没被否定**吗？（"疼痛没有加重"不升级）
 * 三条全成立 ⇒ 升级为红牌，并把模糊词记进 `hits`；被否定的仍进 `negated` 留档。
 */
func redFlagVagueUpgrade(chars: Array<Rune>, term: String, hits: ArrayList<String>,
                         negated: ?ArrayList<String>): Bool {
    let termChars = redFlagRunes(term)
    if (termChars.size == 0 || termChars.size > chars.size) {
        return false
    }
    var at: Int64 = 0
    let last = chars.size - termChars.size
    while (at <= last) {
        if (redFlagMatchAt(chars, at, termChars)) {
            if (redFlagIsNegatedAt(chars, at)) {
                match (negated) {
                    case Some(acc) =>
                        if (!acc.contains(term)) {
                            acc.add(term)
                        }
                    case None => ()
                }
            } else if (redFlagHasUrgentCooccur(chars, at, termChars.size)) {
                if (!hits.contains(term)) {
                    hits.add(term)
                }
                return true
            }
        }
        at = at + 1
    }
    return false
}

/*
 * ★★ 危急征象判定 —— **纯规则、不碰数据库、不调模型**。
 *
 * 判定顺序（每一步都要能单独解释）：
 *   ① 切段（按标点），让否定判定在同一小句内生效；
 *   ② **高危词**：任一命中且未被否定 ⇒ **立即红牌**（不再看其它）；
 *   ③ **模糊词**：命中且未被否定，**并且**附近（≤ 6 字符）有**急迫性**修饰词 ⇒ 升级红牌
 *      （2026-10-17 评审 P2-2：修饰词分"急迫 / 慢性"两类，只有前者能升级）；
 *   ④ 什么都没命中 ⇒ 不是红牌（并留下 negated 供审计：说明"为什么该报没报"）。
 */
public func detectRedFlag(chiefComplaint: String): RedFlagFacts {
    let f = RedFlagFacts()
    let segs = redFlagSegments(chiefComplaint)
    // 一次建立字符数组，高危和模糊两轮共享；不按每个否定 hit 重扫前缀。
    let segmentChars = ArrayList<Array<Rune>>()
    for (seg in segs) {
        segmentChars.add(redFlagRunes(seg))
    }
    let negated = ArrayList<String>()
    let highHits = ArrayList<String>()
    let vagueHits = ArrayList<String>()

    // ② 高危词：任一命中即红牌
    for (chars in segmentChars) {
        for (term in RED_FLAG_TERMS) {
            if (redFlagHitChars(chars, term, highHits, Some(negated))) {
                f.redFlag = true
                f.terms = highHits.toArray()
                f.vagueTerms = vagueHits.toArray()
                f.negated = negated.toArray()
                return f
            }
        }
    }

    /*
     * ③ 模糊词：必须与**急迫性**修饰词**近距离**共现才算（2026-10-17 评审 P2-2）。
     *
     * 这一段的旧实现是两步分离的：先 `seg.contains(mod)` 判整段有没有修饰词，
     * 再 `redFlagHitChars` 判模糊词有没有命中 —— **两者之间没有任何关系**。
     * 后果是「头晕，血压一直正常」被判红牌（"一直"在另一处），
     * 以及「一直头晕」「严重乏力」被判红牌（"一直/严重"本来不该升级）。
     * 现在合成**一个**判定：`redFlagVagueUpgrade`，位置、距离、否定一起看。
     */
    for (chars in segmentChars) {
        for (term in RED_FLAG_VAGUE_TERMS) {
            if (redFlagVagueUpgrade(chars, term, vagueHits, Some(negated))) {
                f.redFlag = true
            }
        }
    }

    f.terms = highHits.toArray()
    f.vagueTerms = vagueHits.toArray()
    f.negated = negated.toArray()
    return f
}
