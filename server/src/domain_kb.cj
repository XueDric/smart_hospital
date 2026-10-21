package qingzhou

import std.collection.*
import stdx.encoding.json.*

/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 * domain_kb.cj —— 知识库切块与零向量库检索：纯逻辑，无 DB、无网络调用。
 * 两条检索路（关键词/向量）的分数不可混排，返回结构的 source 必须如实透传。
 */

/* 常量（仓颉无 hoisting：必须先于使用） */

/*
 * 切块窗口按字符计（不是字节）；重叠 80 字保证跨块的句子不被切丢。
 */
public let KB_CHUNK_CHARS: Int64 = 400
public let KB_CHUNK_OVERLAP: Int64 = 80

/* 单篇正文上限（字符），防止贴整本书把库撑爆。 */
public let KB_BODY_MAX_CHARS: Int64 = 20000
/* 标题上限（列是 VARCHAR(128)）。 */
public let KB_TITLE_MAX_CHARS: Int64 = 128
/* 一次检索最多返回几块：喂给模型的上下文不能无限长。 */
public let KB_SEARCH_TOP_N: Int64 = 5

/* 只去首部 ASCII 空白、保留尾部；用 trimAscii 会把作为块断点的尾部换行一起删掉。 */
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
 * 按字符切块，相邻块重叠 overlap 字；硬性质是「不丢内容」，空正文返回空数组。
 */
public func kbChunk(body: String, window!: Int64 = KB_CHUNK_CHARS,
                    overlap!: Int64 = KB_CHUNK_OVERLAP): Array<String> {
    let out = ArrayList<String>()
    let total = previsitCharLen(body)
    if (total == 0) {
        return out.toArray()
    }
    /* window <= overlap 会让步进 <= 0 死循环，入口处夹住参数（修正而不是抛异常）。 */
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
    /* 全文转 runes 一次，之后全按字符索引。 */
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
        /* 在窗口内找最后一个换行断开；断点须落在窗口后半段，否则块切得过小。 */
        if (end < total) {
            var k = end - 1
            let floor = start + w / 2
            /* 条件必须含等号（k >= floor），否则 floor 本身那个位置被漏掉、换行永远用不上。 */
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
        /* 只去首部空白、保留尾部换行 —— 换行是块边界，去掉后「是否在段落处切开」不可验证。 */
        let trimmed = kbTrimLeftAscii(piece)
        if (kbTrimLeftAscii(trimmed).size > 0) {
            out.add(trimmed)
        }
        if (end >= total) {
            break
        }
        /* 下一块从 end - overlap 开始，保证步进 > 0。 */
        start = end - ov
    }
    return out.toArray()
}

/*
 * 余弦相似度；长度不等 / 零向量返回 0（不抛异常：库里的坏数据不该让检索崩掉）。
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
        return 0.0
    }
    return dot / (kbSqrt(na) * kbSqrt(nb))
}

/*
 * 牛顿迭代开方（不引入 std.math）；x <= 0 返回 0 而非 NaN。
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

/*
 * 朴素切词：汉字按 2-gram、英文/数字按词，去重后返回（重复词会重复计分）。
 * 不用分词库：知识库是院内短文档，召回候选块后由模型理解，召回率优先。
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

/* 汉字判定只覆盖 CJK 基本区（U+4E00..U+9FFF）；扩展区罕用字不参与 2-gram。 */
private func kbIsHan(r: Rune): Bool {
    return r >= r'\u{4E00}' && r <= r'\u{9FFF}'
}

/* 关键词得分 = 命中词数 / 查询词数；归一化后与块长无关，避免长块天然占优。 */
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

/* 检索结果 */

/*
 * 一条检索命中；source 必填，让「这次走的是哪条路」无法被忘记。
 */
public class KbHit {
    public var docId: Int64 = 0
    public var chunkId: Int64 = 0
    public var seq: Int64 = 0
    public var title: String = ""
    public var category: String = ""
    public var content: String = ""
    /* 归一化得分：关键词路 = 覆盖比例，向量路 = 余弦；两者不可直接比较。 */
    public var score: Float64 = 0.0
    /* "keyword" | "vector"，调用方必须如实透传。 */
    public var source: String = "keyword"
    /* 该块的向量；空数组 = 还没有向量（正常降级态），不是数据错误。 */
    public var embedding: Array<Float64> = Array<Float64>()
}

public let KB_SOURCE_KEYWORD: String = "keyword"
public let KB_SOURCE_VECTOR: String = "vector"

/* 按分数降序、同分按 chunkId 升序；稳定排序由比较器保证，不依赖输入顺序。 */
public func kbSortHits(hits: Array<KbHit>): Array<KbHit> {
    let list = ArrayList<KbHit>()
    for (h in hits) {
        list.add(h)
    }
    /* 插入排序：TopN 之前最多几十块，不需要快排。 */
    let arr = list.toArray()
    var i: Int64 = 1
    while (i < arr.size) {
        let cur = arr[i]
        var j = i - 1
        while (j >= 0) {
            let prev = arr[j]
            /*
             * 同分时以 chunkId 作二级键显式定序 —— 不能靠「不挪动」实现稳定：输入顺序不是本函数的契约。
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

/* 向量序列化成 JSON；空向量返回空串（不写 "[]"，那会被读成坏向量）。 */
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
 * 解析 JSON 向量；解析失败返回空数组（一行坏 JSON 不该让整个检索失败）。
 * 每个元素先判类型：asFloat() 在类型不符时抛异常。
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
            /* 非数字元素跳过而不是整条丢弃；长度不一致由 kbCosine 的长度检查兜住。 */
            i = i + 1
        }
    } catch (e: Exception) {
        return ArrayList<Float64>().toArray()
    }
    return out.toArray()
}
