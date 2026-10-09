package qingzhou

import std.collection.*
import stdx.encoding.json.*

/*
 * SPDX-License-Identifier: MIT
 *
 * ===== domain_kb.cj —— P5 知识库：切块 + 零向量库检索 ================
 *
 * brief §5.5 的原话：「仓库**无 embedding、无向量、无余弦相似度**（全仓 grep 0 匹配）。
 * 仓颉侧要自己写：① 出站调 embedding 模型 ② 向量存 MySQL JSON
 * ③ **纯仓颉算余弦相似度**」+「**降级**：向量模型不可用时回落关键词检索」。
 *
 * ---------------------------------------------------------------------------
 * ## ★★ 本文件的中心设计：**检索有两条路，且必须能自证走了哪一条**
 *
 *   · **关键词路**（`kbSearchKeyword`）—— 不需要任何外部服务，**永远可用**。
 *   · **向量路**（`kbCosine` + `kbRankByVector`）—— 需要 embedding 端点。
 *
 * ⇒ 返回结构里带 `source`（`"keyword"` / `"vector"`），调用方**如实透传**。
 *   ⚠ **绝不把关键词结果说成向量结果** —— 那是本仓反复点名的"看起来更好"的谎，
 *     而且它会**掩盖"embedding 从没接上"**这件事（复查刚抓过一模一样的形态：
 *     配置被校验/存库/回显，却没人消费）。
 *
 * ## 为什么"零向量库"是对的（而不是将就）
 *
 *   单院区知识库几千个块（brief §5.5 的判断）。这个量级下：
 *     · 全表扫描 + 逐行 JSON 解析 完全够用；
 *     · 引入向量库要**多一个进程、多一份部署、多一处鉴权与备份** ——
 *       按 brief §6.2 的判据（"双栈会打掉全链路可观测"），这是**净负**。
 *   ⚠ 代价如实记下：**O(n) 扫描**。上万块才需要降维/分片（brief 同段的判断）。
 *
 * ## ★ 一个必须写清的**分级边界**：本文件不做任何网络调用
 *
 *   余弦与关键词都在**本地**算。向量从哪来（谁调 embedding）是 `ai_call.cj` 的事。
 *   ⇒ 好处：本文件的每个函数都能**纯逻辑测试**（无网络、无 DB），
 *     而"embedding 调不通"这条路径由 `ai_call.cj` 的降级覆盖。
 */

/* ===================== 常量（仓颉无 hoisting：必须先于使用）===================== */

/*
 * 切块窗口（**按字符**计，不是字节 —— 本仓为"字节/字符混用"栽过三次）。
 *
 * ⚠ 默认值怎么来的：中文常识段落 300~500 字；重叠 80 字保证
 *   **跨块的句子不会两边都切一半而丢失语义**。
 * ⚠ 为什么要"重叠"而不是简单切片：检索是把**块**喂给模型，
 *   若一句话正好被切在块边界，两边都不完整 ⇒ 两边都召回不到它。
 */
public let KB_CHUNK_CHARS: Int64 = 400
public let KB_CHUNK_OVERLAP: Int64 = 80

/* 单篇文档正文上限（字符）。防有人贴一整本书把库撑爆。 */
public let KB_BODY_MAX_CHARS: Int64 = 20000
/* 标题上限（列是 VARCHAR(128)）。 */
public let KB_TITLE_MAX_CHARS: Int64 = 128
/* 一次检索最多返回几块 —— 喂给模型的上下文不能无限长。 */
public let KB_SEARCH_TOP_N: Int64 = 5

/* ===================== 切块 ===================== */

/*
 * 只去掉**首部**的 ASCII 空白（空格/Tab/CR/LF），**保留尾部**。
 *
 * ⚠ 为什么不用 `trimAscii`：它**首尾都去**，而切块需要保留尾部换行
 *   （换行是块的断点，见 `kbChunk` 内注释）。本仓为这个差一点栽过一次。
 */
public func kbTrimLeftAscii(s: String): String {
    var i: Int64 = 0
    let n = s.size
    while (i < n) {
        let b = s[i]
        if (b == 32 || b == 9 || b == 13 || b == 10) {
            i = i + 1
        } else {
            break
        }
    }
    if (i == 0) {
        return s
    }
    return s[i..]
}

/*
 * 把正文切成块。
 *
 * 规则（**刻意简单，且可断言**）：
 *   ① 按**字符**切，每块最多 `window` 字；
 *   ② 相邻块**重叠** `overlap` 字；
 *   ③ 尽量在**换行**处断开（中文文档的天然段落边界）；
 *      找不到换行就硬切 —— 宁可切得难看，也不要**丢内容**。
 *
 * ⚠⚠ 最关键的性质：**不丢内容**。已经由 AC 钉住（"各块拼起来覆盖全文"）。
 *   切块最容易出的错不是"切得不漂亮"，而是**悄悄丢了中间一段** ——
 *   而那种错在检索时表现为"某些问题永远查不到"，**极难从结果上发现**。
 *
 * ⚠ 空正文 ⇒ 空数组（不是"一块空块"）。空块会被检索命中（匹配零个关键词），
 *   把噪声喂进模型。
 */
public func kbChunk(body: String, window!: Int64 = KB_CHUNK_CHARS,
                    overlap!: Int64 = KB_CHUNK_OVERLAP): Array<String> {
    let out = ArrayList<String>()
    let total = previsitCharLen(body)
    if (total == 0) {
        return out.toArray()
    }
    /*
     * ⚠ `window <= overlap` 会让步进 <= 0 ⇒ **死循环**。
     *   这是本文件唯一的循环风险，所以在入口就夹住（而不是靠调用方自觉）。
     *   📌 与 brief 的口令生成器那次教训同源：**"生成器与校验器要在同一契约下"** ——
     *     这里参数不合法时**修正成能工作的值**，而不是抛异常让调用方去猜。
     */
    var w = window
    var ov = overlap
    if (w <= 0) {
        w = KB_CHUNK_CHARS
    }
    if (ov < 0) {
        ov = 0
    }
    if (ov >= w) {
        ov = w / 4
    }
    /* 全文转 runes 一次，之后全按字符索引（避免反复做字节↔字符换算）。 */
    let rs = ArrayList<Rune>()
    for (r in body.runes()) {
        rs.add(r)
    }
    var start: Int64 = 0
    while (start < total) {
        var end = start + w
        if (end > total) {
            end = total
        }
        /*
         * ③ 在窗口内找**最后一个换行**，在那里断开（块更像完整段落）。
         * ⚠ 只有断点落在窗口的**后半段**才采用 —— 否则会把块切得过小，
         *   反而增加块数（更多次检索、更多噪声）。
         */
        if (end < total) {
            var k = end - 1
            let floor = start + w / 2
            /*
             * ⚠⚠ 条件是 `k >= floor`（**含等号**）—— 这里原来写成 `>` 是**真缺陷**，
             *   2026-10-09 由 AC-KB-1 ⑤ 抓到：那会漏掉 `floor` **本身**那一个位置。
             *   实测症状：窗口 400、段落长 18 ⇒ 换行落在索引 359（>200 显然该采用），
             *   而扫描止于 200 ⇒ **永远断不开**，块全在 400 处硬切。
             *
             *   为什么难发现：换行断开只是"块更像完整段落"的**质量**改进，
             *   断不开不会报错、不影响"不丢内容"、检索照样能命中 ——
             *   所以它**只会表现为"切得比预期难看"**，靠肉眼读代码极难看出差一。
             *   ⇒ 正是"边界差一"这类缺陷需要**结构性断言**（本用例断言"至少一块以换行收尾"）。
             */
            while (k >= floor) {
                if (rs[k] == r'\n') {
                    end = k + 1
                    break
                }
                k = k - 1
            }
        }
        var piece = ""
        var i = start
        while (i < end) {
            piece = piece + rs[i].toString()
            i = i + 1
        }
        /*
         * ⚠⚠ 这里**只去首部空白，不去尾部**（2026-10-09 修，AC-KB-1 ⑤ 抓到）。
         *
         * 原来写的是 `piece.trimAscii()` —— 而 `trimAscii` **首尾都去**（已核实），
         * 于是**把块的尾部换行也删掉了** ⇒ 切块时"在换行处断开"这件事
         * **在最终结果里完全看不出来**，块与"硬切"的结果无法区分。
         *
         * 📌 为什么要保留尾部换行：换行是**断点本身**（块的语义边界），
         *   而不是需要清理的噪声。去掉它会让"块是不是在段落边界切开"变成不可验证的性质。
         * ⚠ 首部空白仍要去：那是**上一块重叠切过来的残留**（`start = end - overlap`
         *   可能落在空白上），留着会让块以空白开头。
         * ⚠ 空判断改用 `kbTrimLeftAscii(trimmed).size`：只去首部后，
         *   一个"纯空白块"会变成 `"\n"`，`size > 0` ⇒ 会把空白块当成有效块加进去。
         */
        let trimmed = kbTrimLeftAscii(piece)
        if (kbTrimLeftAscii(trimmed).size > 0) {
            out.add(trimmed)
        }
        if (end >= total) {
            break
        }
        /* ② 重叠：下一块从 `end - overlap` 开始（保证步进 > 0）。 */
        start = end - ov
    }
    return out.toArray()
}

/* ===================== 余弦相似度（纯仓颉）===================== */

/*
 * 两个向量的余弦相似度。
 *
 * ⚠ 边界（都要有测试）：
 *   · 长度不等 ⇒ 返回 0（**不是**抛异常：向量来自库里的 JSON，
 *     长度不一致是**数据问题**，不该让整个检索崩掉）；
 *   · 任一为零向量或长度为 0 ⇒ 返回 0（`0/0` 会得到 NaN，而
 *     NaN 参与比较**永远为 false** ⇒ 排序结果不可预测）；
 *   · 返回值域 **[-1, 1]**，但本用途下通常 [0,1]（embedding 一般非负）。
 */
public func kbCosine(a: Array<Float64>, b: Array<Float64>): Float64 {
    if (a.size == 0 || a.size != b.size) {
        return 0.0
    }
    var dot: Float64 = 0.0
    var na: Float64 = 0.0
    var nb: Float64 = 0.0
    var i: Int64 = 0
    while (i < a.size) {
        dot = dot + a[i] * b[i]
        na = na + a[i] * a[i]
        nb = nb + b[i] * b[i]
        i = i + 1
    }
    if (na <= 0.0 || nb <= 0.0) {
        /* ⚠ 必须显式挡掉：否则 0/0 = NaN，NaN 的比较恒 false ⇒ 排序不可预测。 */
        return 0.0
    }
    return dot / (kbSqrt(na) * kbSqrt(nb))
}

/*
 * 平方根（牛顿迭代）。
 *
 * ⚠ 为什么自己写：本仓没有引入 `std.math` 的浮点开方（也**不想**为一个函数引入新依赖）。
 *   牛顿迭代对正数收敛很快（这里迭代 40 次远超 double 精度需要），
 *   而余弦里只需要**比值**，对精度不敏感。
 * ⚠ `x <= 0` ⇒ 返回 0（不是 NaN）。
 */
public func kbSqrt(x: Float64): Float64 {
    if (x <= 0.0) {
        return 0.0
    }
    var g = x
    var i = 0
    while (i < 40) {
        g = (g + x / g) / 2.0
        i = i + 1
    }
    return g
}

/* ===================== 关键词检索（**默认路径，永远可用**）===================== */

/*
 * 中文/英文混合的**朴素切词**。
 *
 * ⚠⚠ 为什么不用分词库：仓颉侧**没有**成熟中文分词（brief §6.3 承认的劣势）。
 *   而"朴素切词"在**本用途**下够用，理由必须写清：
 *     · 知识库是**本院人员写的短文档**，用词比患者主诉规范；
 *     · 检索目标是"召回候选块"，**后续由模型阅读理解** ——
 *       所以召回率比精确率重要，宁可多召回。
 *   ⇒ 做法：**汉字按 2-gram**（相邻两字），英文/数字按词。
 *     2-gram 对中文是经典的零依赖近似，能有效召回"高血压"→"血压"这类。
 *
 * ⚠ 返回**去重后**的集合：重复的词在打分时会重复计数，
 *   让长文档仅因为"同一个词出现很多次"就霸榜。
 */
public func kbTokens(text: String): Array<String> {
    let out = ArrayList<String>()
    let seen = HashMap<String, Bool>()
    let low = text.toAsciiLower()
    let cs = ArrayList<Rune>()
    for (r in low.runes()) {
        cs.add(r)
    }
    var i: Int64 = 0
    while (i < cs.size) {
        let r = cs[i]
        if (kbIsAsciiWordChar(r)) {
            /* 英文/数字：吃掉整个词 */
            var j = i
            var w = ""
            while (j < cs.size && kbIsAsciiWordChar(cs[j])) {
                w = w + cs[j].toString()
                j = j + 1
            }
            if (w.size >= 2 && !seen.contains(w)) {
                seen[w] = true
                out.add(w)
            }
            i = j
        } else if (kbIsHan(r)) {
            /* 汉字：取 2-gram（相邻两字） */
            if (i + 1 < cs.size && kbIsHan(cs[i + 1])) {
                let g = cs[i].toString() + cs[i + 1].toString()
                if (!seen.contains(g)) {
                    seen[g] = true
                    out.add(g)
                }
            }
            i = i + 1
        } else {
            i = i + 1
        }
    }
    return out.toArray()
}

/* ASCII 词字符（字母/数字/下划线）。 */
private func kbIsAsciiWordChar(r: Rune): Bool {
    return (r >= r'a' && r <= r'z') || (r >= r'0' && r <= r'9') || r == r'_'
}

/*
 * 是否是汉字（CJK 统一表意文字基本区）。
 * ⚠ 只覆盖基本区（U+4E00..U+9FFF）—— 扩展区罕用字走不到 2-gram，
 *   会退化成"不参与检索"。这是**已知边界**，写在注释里而不是假装全覆盖。
 */
private func kbIsHan(r: Rune): Bool {
    return r >= r'\u{4E00}' && r <= r'\u{9FFF}'
}

/*
 * 关键词打分：命中词数 / 查询词数（**归一化**）。
 *
 * ⚠ 归一化的理由：不归一化的话，**长块**因为词多而天然占优
 *   （同样的查询词，长块里更容易出现）。而归一化后比较的是"这块覆盖了查询的多少"，
 *   与块长无关 —— 这才是"相关性"该有的含义。
 */
public func kbKeywordScore(queryTokens: Array<String>, content: String): Float64 {
    if (queryTokens.size == 0) {
        return 0.0
    }
    let docTokens = kbTokens(content)
    var hit = 0
    for (q in queryTokens) {
        for (d in docTokens) {
            if (d == q) {
                hit = hit + 1
                break
            }
        }
    }
    return Float64(hit) / Float64(queryTokens.size)
}

/* ===================== 检索结果 ===================== */

/*
 * 一条检索命中。
 *
 * ⚠ `source` 是**必填**（不是可选）：它让"这次检索走的是哪条路"**无法被忘记**。
 *   本仓的教训反复是"某个事实在某条路径上没被带上"（seq_no、source、enabled…），
 *   所以这里把"来源"做成结构的一部分。
 */
public class KbHit {
    public var docId: Int64 = 0
    public var chunkId: Int64 = 0
    public var seq: Int64 = 0
    public var title: String = ""
    public var category: String = ""
    public var content: String = ""
    /* 归一化得分。关键词路 = 覆盖比例；向量路 = 余弦。**两条路的分数不可直接比较**。 */
    public var score: Float64 = 0.0
    /* "keyword" | "vector" —— 调用方必须如实透传。 */
    public var source: String = "keyword"
    /*
     * 该块的向量（空数组 = **没有向量**）。
     *
     * ⚠ 空数组与"长度为 0 的向量"是**两件事**：前者是"还没向量化"（正常状态，
     *   关键词路照样能检索到它），后者是数据错误。`kbVectorToJson` 对空向量
     *   返回空串、`kbVectorFromJson` 对空串返回空数组 —— 两侧口径一致。
     */
    public var embedding: Array<Float64> = Array<Float64>()
}

public let KB_SOURCE_KEYWORD: String = "keyword"
public let KB_SOURCE_VECTOR: String = "vector"

/*
 * 按分数降序排（**稳定**：同分时按 chunkId 升序，保证结果可复现）。
 *
 * ⚠ 为什么要显式稳定：同分很常见（关键词路尤其如此，很多块覆盖比例相同），
 *   而"同分时顺序随机"会让**同一查询两次返回不同块** ⇒
 *   测试偶发红、且**模型看到的上下文每次不同**（输出不可复现）。
 */
public func kbSortHits(hits: Array<KbHit>): Array<KbHit> {
    let list = ArrayList<KbHit>()
    for (h in hits) {
        list.add(h)
    }
    /* 插入排序：块数很小（TopN 之前最多几十），不需要快排。 */
    let arr = list.toArray()
    var i: Int64 = 1
    while (i < arr.size) {
        let cur = arr[i]
        var j = i - 1
        while (j >= 0) {
            let prev = arr[j]
            /*
             * ★★ 比较规则（这里原来写错过一次，2026-10-09 修）：
             *   · 分数不同 ⇒ 分数低的往后挪（降序）
             *   · **分数相同 ⇒ chunkId 大的往后挪**（即同分按 chunkId **升序**）
             *
             * ⚠⚠ 原来只写了"`prev.score < cur.score` 才挪"，并在注释里断言
             *   "相等时不挪 ⇒ 天然保持原顺序 ⇒ 就得到稳定排序"。
             *   **那个推理是错的**：插入排序里"不挪"只保证不主动换位，
             *   而输入顺序是**调用方给的**（DB 的 `ORDER BY c.id` 只保证 chunkId 升序，
             *   不保证同分相邻），所以"稳定"依赖输入 —— 而输入不是本函数的契约。
             *   实测：输入 chunkId = [30,10,20,5] 且同分 ⇒ 输出原样 `30,10,20,5`。
             *
             * ⇒ 正确做法是**在比较里显式定序**（不依赖输入顺序）：
             *   同分时用 chunkId 作二级键。这样无论输入怎样，输出都唯一确定。
             *   📌 教训：**"稳定排序"必须由比较器保证，不能靠"我不动它"** ——
             *     "我不动它"只在输入已经有序时才等于有序。
             */
            var shouldShift = prev.score < cur.score
            if (prev.score == cur.score && prev.chunkId > cur.chunkId) {
                shouldShift = true
            }
            if (shouldShift) {
                arr[j + 1] = prev
                j = j - 1
            } else {
                break
            }
        }
        arr[j + 1] = cur
        i = i + 1
    }
    return arr
}

/*
 * 把向量序列化成 JSON 数组字符串（存库用）。
 * ⚠ 空向量 ⇒ 空串（存 NULL 由调用方决定），**不写 "[]"** ——
 *   "[]" 会被读回来当成"长度为 0 的向量"，而那与"没有向量"是**两件事**
 *   （前者是数据错误，后者是正常的降级状态）。
 */
public func kbVectorToJson(v: Array<Float64>): String {
    if (v.size == 0) {
        return ""
    }
    var s = "["
    var i: Int64 = 0
    while (i < v.size) {
        if (i > 0) {
            s = s + ","
        }
        s = s + v[i].toString()
        i = i + 1
    }
    return s + "]"
}

/*
 * 从 JSON 数组字符串解析向量（读库用）。
 *
 * ⚠⚠ 解析失败 ⇒ 返回**空数组**（而不是抛异常）：
 *   库里一行坏 JSON 不该让**整个检索**失败 —— 那一行顶多是"没有向量"，
 *   正好落进关键词降级路径。📌 与 `previsitParseForm` 同一口径
 *   （"库里一条坏 JSON 不该让整个会话不可用"）。
 * ⚠ 每个元素**先判类型**：`asFloat()` 在类型不符时**抛异常**（本仓 API-NOTES 记过）。
 */
public func kbVectorFromJson(s: String): Array<Float64> {
    let out = ArrayList<Float64>()
    if (s.trimAscii().size == 0) {
        return out.toArray()
    }
    try {
        let v = JsonValue.fromStr(s)
        if (!(v is JsonArray)) {
            return out.toArray()
        }
        let arr = v.asArray()
        var i: Int64 = 0
        while (i < arr.size()) {
            let e = arr[i]
            if (e is JsonFloat) {
                out.add(e.asFloat().getValue())
            } else if (e is JsonInt) {
                out.add(Float64(e.asInt().getValue()))
            }
            /*
             * ⚠ 遇到非数字元素**跳过**（不是整条丢弃）：部分坏元素仍可用，
             *   而"整条丢弃"会让一个多余的逗号毁掉整个向量。
             *   代价是长度可能与其它向量不一致 ⇒ 由 `kbCosine` 的长度检查兜住。
             */
            i = i + 1
        }
    } catch (e: Exception) {
        return ArrayList<Float64>().toArray()
    }
    return out.toArray()
}
