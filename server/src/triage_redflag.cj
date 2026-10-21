/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 * triage_redflag.cj —— 危急征象兜底：纯规则保险丝，排在模型之前，命中即判 RED_FLAG。
 * 判定不经过模型：模型可被绕过、输出不可信；漏报不可能为零，词表是示例级，不代替医生。
 */

package qingzhou

/* ArrayList 来自 std.collection；漏了它报 undeclared type name 'ArrayList'。 */
import std.collection.*

/* 词表 */

/*
 * 高危征象词（单独命中即红牌）：口径是「延误就有不可逆后果」。
 * 不收「疼痛」「发烧」这类泛化词 —— 单独出现绝大多数不是急症，收进来会让红牌率不可用。
 */
/*
 * 急迫性修饰词：可把模糊征象升级为红牌。只收「急性起病 / 进行性加重」；
 * 「一直 / 严重」这类病程词不升级（那是慢病主诉，误报同样是伤害）。
 * 修饰词必须紧贴模糊词（同分句、距离 ≤ RED_FLAG_COOCCUR_WINDOW）且自身未被否定。
 */
public let RED_FLAG_URGENT_MODIFIERS: Array<String> = [
    "反复", "持续", "不停", "越来越", "加重", "加剧", "剧烈",
    "难以忍受", "无法忍受", "受不了", "突然", "突发", "骤发", "急剧"
]

/* 病程 / 程度修饰词：单独不足以升级为红牌；保留成表是为了可解释，判定路径当前不读它。 */
public let RED_FLAG_CHRONIC_MODIFIERS: Array<String> = [
    "一直", "长期", "多年", "经常", "总是", "严重", "轻微", "轻度", "偶尔"
]

/* 模糊词与修饰词的共现窗口（字符数）：同分句内、相距不超过这么多字符才算共现。 */
public let RED_FLAG_COOCCUR_WINDOW: Int64 = 6

/*
 * 否定词：命中词前 RED_FLAG_NEGATION_WINDOW 个字符内出现即作废本次命中。
 * 裸「不」不在表里 —— 它是高频构词成分（不适 / 不停 / 不伴），当否定词用会吃掉真症状。
 * 窗口取 8（「并未出现明显的胸痛」间隔 6），且只在同一分句内数。
 */
public let RED_FLAG_NEGATION_WINDOW: Int64 = 8

/*
 * 否定词与症状词之间允许的间隔：多字否定是述语级的，可隔宾语；单字否定只能紧贴症状，否则多半是别的词的一部分。
 */
public let RED_FLAG_NEGATION_GAP_MAX: Int64 = 6

/* 单字否定词允许的最大间隔。 */
public let RED_FLAG_NEGATION_GAP_SHORT: Int64 = 1

/* 间隔里出现这些成分 ⇒ 否定作用于别的东西，不能判成否认（「无诱因突发胸痛」是最危险的漏报形态）。 */
public let RED_FLAG_NEGATION_BLOCKERS: Array<String> = ["而", "且", "但", "却", "诱因", "原因"]

/*
 * 缺席动词：单字否定后接「出现 / 发生」类动词时否定仍管到症状（「从来没出现过呼吸困难」）。
 * 只认这些明确的缺席述语；「没胃口胸痛」不在此列，仍报红牌。
 */
public let RED_FLAG_ABSENCE_VERBS: Array<String> = [
    "出现过", "出现", "发生过", "发生", "有过", "有", "见过", "见",
    "感觉到", "感觉", "觉得", "察觉", "发现", "碰见", "经历", "再"
]

/* 缺席动词与症状之间允许出现的修饰成分（「出现明显的胸痛」）。 */
public let RED_FLAG_ABSENCE_FILLERS: Array<String> = [
    "的", "过", "了", "明显", "任何", "症状", "情况", "现象", "发作", "过任何"
]

public let RED_FLAG_TERMS: Array<String> = [
    /* 按系统分组：心脑血管、呼吸、大出血、急腹症、高热、孕产、中毒外伤、儿童（照护者描述）。 */
    "胸痛", "胸闷痛", "心前区痛", "压榨性疼痛", "濒死感",
    "胸口疼", "胸口痛", "胸口闷", "心口疼", "心口痛", "胸前区痛", "胸骨后痛", "胸骨后疼痛",
    "口角歪斜", "口眼歪斜", "言语不清", "说话不清", "说话含糊", "舌根发硬",
    "半身不遂", "偏瘫", "肢体无力", "半边身子麻", "一侧无力",
    "突然看不清", "意识不清", "意识模糊", "意识丧失", "昏迷", "晕厥", "晕倒", "抽搐", "抽风",
    "呼吸困难", "喘不上气", "喘不过气", "上不来气", "气短憋气", "憋气", "窒息", "咯血", "咳血",
    "痰中带血",
    "呕血", "吐血", "便血", "黑便", "血便", "大便发黑", "大出血", "阴道大出血",
    "剧烈腹痛", "腹痛难忍", "板状腹", "腹部剧痛", "肚子疼得厉害", "腹痛剧烈",
    "高热惊厥", "惊厥", "持续高热不退", "高烧不退",
    "胎动减少", "胎动消失", "胎动变少", "临产", "见红", "破水", "孕期出血",
    "误服", "服毒", "农药", "煤气中毒", "一氧化碳", "自杀", "自伤", "割腕",
    "高处坠落", "车祸", "重物砸伤", "烧烫伤",
    "孩子抽", "婴儿抽", "囟门膨隆", "拒食嗜睡"
]

/*
 * 模糊征象词：单独命中不算红牌 —— 它们在日常汉语里大量用于非医疗语境（「心慌意乱」），
 * 单独报红牌会把正常人赶去急诊；须与急迫性修饰词共现才升级。
 */
public let RED_FLAG_VAGUE_TERMS: Array<String> = [
    "心慌", "心悸", "头晕", "头疼", "头痛", "恶心", "呕吐", "乏力", "麻木", "疼"
]

/* 否定词表，口径见 RED_FLAG_NEGATION_WINDOW。 */
public let RED_FLAG_NEGATIONS: Array<String> = [
    "没有", "没", "无任何", "无明显", "无", "未见", "未出现", "未", "非",
    "否认", "排除", "从未", "并无", "不伴", "不太", "没怎么",
    "不"
]

/* 一次红牌判定的事实：把依据留下，不只给布尔。 */
public class RedFlagFacts {
    public var redFlag: Bool = false
    /* 命中的高危词（去重后）。 */
    public var terms: Array<String> = Array<String>()
    /* 命中并升级的模糊词（单独不算，需共现）。 */
    public var vagueTerms: Array<String> = Array<String>()
    /* 因否定而作废的命中（留档：说明「为什么看着该报却没报」）。 */
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
        /* Array<String> 没有 join，手工拼；行为完全可预测。 */
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
 * 该字符是否算分句分隔符。顿号「、」不在其中：它是并列枚举而不是分句边界，
 * 保留在同一段里，否定的枚举链判据才能把否定传递下去（「无胸痛、咯血、呕血」）。
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
 * 把主诉切成片段：中文没有空格、患者输入里大量标点，按标点切段后否定才在同一小句内生效。
 * 必须按字符切，绝不能按字节切：String.toArray() 给的是 UTF-8 字节，会在段边界撕裂多字节字符。
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
 * 把片段拆成 Rune[]；所有涉及下标的判断都必须经过它。
 * 仓颉 String 的下标 / 切片 / indexOf / size 都是字节语义，只有 runes() 是字符语义；在字节空间里做减法会在汉字中间切断、切出非法 UTF-8。
 */
func redFlagRunes(seg: String): Array<Rune> {
    let out = ArrayList<Rune>()
    for (r in seg.runes()) {
        out.add(r)
    }
    return out.toArray()
}

/* 某字符下标 chat 之前（不含）的窗口文本，最多 width 个字符。 */
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

/* 否定判定（字符空间） */

/*
 * 字符下标 chat 处的那次命中是否被否定：否定词须挨得够近（间隔 ≤ RED_FLAG_NEGATION_GAP_MAX），
 * 间隔里不得有把否定指向别处的连接成分，另有一条并列枚举通道。
 * 窗口与间隔都按字符数，不按字节；窗口不跨分句（redFlagSegments 已切段，顿号不在分隔符里）。
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

/* 判据 ①：否定词紧邻本次命中（间隔受限且无阻断成分）。 */
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

/* 间隔里是否有把否定指向别处的连接成分（「无法缓解的胸痛」）。 */
func redFlagGapHasBlocker(gap: String): Bool {
    for (b in RED_FLAG_NEGATION_BLOCKERS) {
        if (gap.contains(b)) {
            return true
        }
    }
    return false
}

/* 判据 ①b：单字否定 + 缺席动词（「从来没出现过呼吸困难」）；中间只允许动词与填充交替出现。 */
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

/* [from, to) 是否由缺席动词 / 修饰填充组成（至少一个动词）。 */
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

/* [from, to) 是否正好由「红牌词 / 并列连接符」组成；也接受红牌词直接相邻（「无呕血便血」）。 */
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

/* 窗口起点（字符下标），供两段式判定共用。 */
func redFlagWindowStart(chars: Array<Rune>, chat: Int64, width: Int64): Int64 {
    if (chat > width) {
        return chat - width
    }
    return 0
}

/* 字符下标 at 处是否出现 term（纯匹配，不做否定判定）。 */
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
 * 模糊词与急迫性修饰词是否共现：修饰词须在共现窗口内、只认 RED_FLAG_URGENT_MODIFIERS、
 * 且修饰词自身未被否定（「疼痛没有加重」不升级）。
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
                let before = if (modEnd <= termAt) { termAt - modEnd <= RED_FLAG_COOCCUR_WINDOW } else { false }
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
 * 片段里 term 是否未被否定地出现一次；命中记进 hits，被否定的记进 negated。
 * String 入口供常规科室规则复用；完整危急检测用下方 Rune 入口，同一片段只转换一次。
 */
func redFlagHit(seg: String, term: String, hits: ArrayList<String>,
                negated: ?ArrayList<String>): Bool {
    return redFlagHitChars(redFlagRunes(seg), term, hits, negated)
}

/*
 * 顺序比较 Rune，不为每个否定命中从头算偏移；否定命中后只前进一个字符，保持重叠命中语义。
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
 * 模糊词升级判定：未被否定 + 附近有未被否定的急迫性修饰词 ⇒ 升级红牌；三条缺一不可。
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
 * 危急征象判定：纯规则，不碰数据库、不调模型。顺序：切段 → 高危词命中即红牌 →
 * 模糊词需与急迫性修饰词近距离共现才升级 → 都没命中则不是红牌，negated 留档供审计。
 */
public func detectRedFlag(chiefComplaint: String): RedFlagFacts {
    let f = RedFlagFacts()
    let segs = redFlagSegments(chiefComplaint)
    /* 一次建立字符数组，高危与模糊两轮共享。 */
    let segmentChars = ArrayList<Array<Rune>>()
    for (seg in segs) {
        segmentChars.add(redFlagRunes(seg))
    }
    let negated = ArrayList<String>()
    let highHits = ArrayList<String>()
    let vagueHits = ArrayList<String>()

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
     * ③ 模糊词须与急迫性修饰词近距离共现；旧实现把「段内有修饰词」与「模糊词命中」分开判，两者之间没有关系。
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
