package qingzhou

import std.collection.*
import stdx.encoding.json.*

/*
 * SPDX-License-Identifier: MIT
 *
 * acceptance_kb.cj —— AC-KB-1…5：P5 知识库
 * 断言偏结构性（拼接覆盖全文、同分顺序固定），不做"抽几块看看像不像"。
 */

/* 收集各块拼起来是否覆盖全文（去重叠后应等于原文）。 */
func kbCoveredChars(pieces: Array<String>, body: String): Bool {
    /* 逐块按序查找：每块起点必须 >= 前一块起点，否则说明丢内容或乱序。 */
    var pos: Int64 = 0
    let cs = ArrayList<Rune>()
    for (r in body.runes()) {
        cs.add(r)
    }
    for (p in pieces) {
        let pc = ArrayList<Rune>()
        for (r in p.runes()) {
            pc.add(r)
        }
        var found: Int64 = -1
        var i = pos
        while (i + pc.size <= cs.size) {
            var same = true
            var j: Int64 = 0
            while (j < pc.size) {
                if (cs[i + j] != pc[j]) {
                    same = false
                    break
                }
                j = j + 1
            }
            if (same) {
                found = i
                break
            }
            i = i + 1
        }
        if (found < 0) {
            return false
        }
        /* 允许重叠 ⇒ 下一块起点取本块起点 + 1，不能取块尾。 */
        pos = found + 1
    }
    return true
}

/* ---------- AC-KB-1：切块（★ 不丢内容 / 重叠 / 字符边界）---------- */
public func acKb1(runner: TestRunner, db: DbBackend): Unit {
    println("=== AC-KB-1 ★★★ 切块：**不丢内容**（结构性断言）+ 重叠 + 按字符 ----------")

    /* ① 短文本 ⇒ 恰好一块。 */
    let short = kbChunk("咳嗽三天，无发热。")
    runner.check("① 短文本切成 1 块（实得 ${short.size}）", short.size == 1)
    runner.check("① 且内容就是原文（trim 后一致）", short[0] == "咳嗽三天，无发热。")

    /* ② 空正文 ⇒ 0 块；不能是 1 个空块，否则会被检索命中并污染上下文。 */
    runner.check("★ ② 空正文 ⇒ 0 块", kbChunk("").size == 0)
    runner.check("★ ② 纯空白 ⇒ 0 块", kbChunk("   \n\t  ").size == 0)

    /* ③ ★ 不丢内容：造足够长且无换行的中文强制硬切，验证各块按序覆盖全文。 */
    let longBody = hRepeatChar("高血压患者需长期服药并定期监测血压。", 60)
    let pieces = kbChunk(longBody)
    runner.check("③ 长文本被切成多块（实得 ${pieces.size} 块）", pieces.size >= 2)
    runner.check("★★★ ③ 各块**按顺序覆盖全文**（没有中间被丢掉的一段）",
                 kbCoveredChars(pieces, longBody))
    var maxChars: Int64 = 0
    for (p in pieces) {
        if (previsitCharLen(p) > maxChars) {
            maxChars = previsitCharLen(p)
        }
    }
    runner.check("③ 且每块不超过窗口（${KB_CHUNK_CHARS} 字，实得最长 ${maxChars}）",
                 maxChars <= KB_CHUNK_CHARS)

    /* ④ ★ 按字符切而非按字节：多字节字符按字节切会产出非法 UTF-8。 */
    let wide = hRepeatChar("𠮷", 500)
    let wp = kbChunk(wide)
    var wideOk = true
    for (p in wp) {
        if (p.size == 0) {
            wideOk = false
        }
    }
    runner.check("★★ ④ 4 字节字符（U+20BB7）被正确切块，无空块（${wp.size} 块）", wideOk && wp.size >= 1)
    runner.check("★★ ④ 且每块字符数 ≤ 窗口（说明是按字符计）",
                 previsitCharLen(wp[0]) <= KB_CHUNK_CHARS)

    /* ⑤ 换行处优先断开。 */
    var para = ""
    var k: Int64 = 0
    while (k < 40) {
        para = para + "第一段内容约占若干字用于填充窗口。" + "\n"
        k = k + 1
    }
    let pp = kbChunk(para)
    var endsWithNl = 0
    for (p in pp) {
        if (p.endsWith("\n")) {
            endsWithNl = endsWithNl + 1
        }
    }
    runner.check("★ ⑤ 在换行处断开（${pp.size} 块中 ${endsWithNl} 块以换行收尾）", endsWithNl >= 1)

    /* ⑥ window <= overlap 会步进 ≤ 0 ⇒ 死循环；入口必须夹住参数，否则用例挂住而非变红。 */
    let degenerate = kbChunk(longBody, window: 100, overlap: 500)
    runner.check("★★ ⑥ window(100) < overlap(500) 不死循环且仍覆盖全文（${degenerate.size} 块）",
                 degenerate.size >= 1 && kbCoveredChars(degenerate, longBody))
    let zeroWin = kbChunk(longBody, window: 0, overlap: 0)
    runner.check("★★ ⑥ window=0 不死循环（回落到默认窗口，${zeroWin.size} 块）", zeroWin.size >= 2)
}

/* ---------- AC-KB-2：余弦相似度（★ 边界含 NaN）---------- */
public func acKb2(runner: TestRunner, db: DbBackend): Unit {
    println("=== AC-KB-2 ★★★ 余弦：长度不等 / 零向量 ⇒ **绝不返回 NaN** ===")

    /* ① 自身相似 = 1。 */
    let a: Array<Float64> = [1.0, 2.0, 3.0]
    let self = kbCosine(a, a)
    runner.check("① 与自身余弦 ≈ 1（实得 ${self}）", self > 0.999 && self < 1.001)

    /* ② 正交 = 0。 */
    let x: Array<Float64> = [1.0, 0.0]
    let y: Array<Float64> = [0.0, 1.0]
    runner.check("② 正交向量余弦 = 0（实得 ${kbCosine(x, y)}）", kbCosine(x, y) == 0.0)

    /* ③ 反向 = -1。 */
    let neg: Array<Float64> = [-1.0, 0.0]
    runner.check("③ 反向向量余弦 ≈ -1（实得 ${kbCosine(x, neg)}）",
                 kbCosine(x, neg) < -0.999)

    /* ④ ★ 零向量 ⇒ 0，不是 NaN：NaN 的任何比较恒 false ⇒ 排序不可预测（同一查询两次结果不同）。
     * `x != x` 是判 NaN 的标准手法。 */
    let zero: Array<Float64> = [0.0, 0.0]
    let c1 = kbCosine(zero, zero)
    runner.check("★★★ ④ 双零向量 ⇒ 0 且**不是 NaN**（实得 ${c1}）", c1 == 0.0 && !(c1 != c1))
    let c2 = kbCosine(a, zero)
    runner.check("★★★ ④ 单零向量 ⇒ 0 且不是 NaN（实得 ${c2}）", c2 == 0.0 && !(c2 != c2))

    /* ⑤ 长度不等 ⇒ 0（数据问题不能让检索崩）。 */
    let short2: Array<Float64> = [1.0]
    let c3 = kbCosine(a, short2)
    runner.check("★★ ⑤ 长度不等 ⇒ 0 且不抛异常（实得 ${c3}）", c3 == 0.0)
    runner.check("★ ⑤ 空数组 ⇒ 0（实得 ${kbCosine(Array<Float64>(), a)}）",
                 kbCosine(Array<Float64>(), a) == 0.0)

    /* ⑥ kbSqrt 边界：负/零 ⇒ 0，不是 NaN。 */
    runner.check("⑥ kbSqrt(0) = 0（不是 NaN）", kbSqrt(0.0) == 0.0)
    runner.check("⑥ kbSqrt(-1) = 0（不是 NaN）", kbSqrt(-1.0) == 0.0)
    let s4 = kbSqrt(4.0)
    runner.check("⑥ kbSqrt(4) ≈ 2（实得 ${s4}）", s4 > 1.999 && s4 < 2.001)

    /* ⑦ 向量 ↔ JSON 往返。 */
    let v: Array<Float64> = [0.5, -1.25, 3.0]
    let js = kbVectorToJson(v)
    let back = kbVectorFromJson(js)
    runner.check("⑦ 向量 JSON 往返长度一致（${v.size} -> ${back.size}）", back.size == v.size)
    var same = back.size == v.size
    if (same) {
        var i: Int64 = 0
        while (i < v.size) {
            if (back[i] < v[i] - 0.0001 || back[i] > v[i] + 0.0001) {
                same = false
            }
            i = i + 1
        }
    }
    runner.check("⑦ 且逐元素相等（实得 ${js}）", same)

    /* ⑧ 空向量序列化成空串而不是 "[]"，两者语义不同（见 domain_kb.cj）。 */
    runner.check("★★ ⑧ 空向量 ⇒ 空串（不是 \"[]\"）", kbVectorToJson(Array<Float64>()).size == 0)
    runner.check("★ ⑧ 空串解析 ⇒ 空数组", kbVectorFromJson("").size == 0)
    runner.check("★ ⑧ 坏 JSON ⇒ 空数组（不抛异常）", kbVectorFromJson("{not json").size == 0)
    runner.check("★ ⑧ 非数组 JSON ⇒ 空数组", kbVectorFromJson("{\"a\":1}").size == 0)
    runner.check("★ ⑧ 部分坏元素 ⇒ 保留好元素（1,2）",
                 kbVectorFromJson("[1, \"x\", 2]").size == 2)
}

/* ---------- AC-KB-3：关键词检索与稳定排序 ---------- */
public func acKb3(runner: TestRunner, db: DbBackend): Unit {
    println("=== AC-KB-3 ★★ 关键词：归一化 / 2-gram / **稳定排序** ===")

    /* ① 汉字 2-gram。 */
    let tk = kbTokens("高血压患者")
    var hasGram = false
    for (t in tk) {
        if (t == "高血" || t == "血压") {
            hasGram = true
        }
    }
    runner.check("① 汉字切出 2-gram（含「高血」或「血压」，共 ${tk.size} 个）", hasGram)

    /* ② 英文按词（≥2 字母），单字母不切。 */
    let tk2 = kbTokens("CT scan and a MRI")
    var hasCt = false
    var hasA = false
    for (t in tk2) {
        if (t == "ct") {
            hasCt = true
        }
        if (t == "a") {
            hasA = true
        }
    }
    runner.check("② 英文切成小写词（含 ct=${hasCt}）", hasCt)
    runner.check("② 单字母不成词（不含 a=${!hasA}）", !hasA)

    /* ③ 去重：重复串里的跨词 gram 是 2-gram 固有性质；这里钉的是"结果无重复项"。 */
    let tk3 = kbTokens("血压血压血压")
    let uniq = HashMap<String, Bool>()
    var dupFound = false
    for (x in tk3) {
        if (uniq.contains(x)) {
            dupFound = true
        }
        uniq[x] = true
    }
    runner.check("★ ③ 无重复 token（共 ${tk3.size} 个：血压 + 跨词 gram 压血）",
                 !dupFound && tk3.size == 2)

    /* ④ 归一化：长块不得因词多而天然占优，覆盖比例相同则应同分。 */
    let q = kbTokens("高血压")
    let sShort = kbKeywordScore(q, "高血压需长期服药。")
    let sLong = kbKeywordScore(q, "高血压需长期服药。" + hRepeatChar("无关填充内容。", 50))
    runner.check("★★ ④ 覆盖比例相同时，长块得分**不高于**短块（${sShort} vs ${sLong}）",
                 sLong <= sShort + 0.0001)

    /* ⑤ 完全不相关 ⇒ 0，不给基础分。 */
    runner.check("★ ⑤ 完全无关 ⇒ 0（实得 ${kbKeywordScore(q, "骨折需要固定。")}）",
                 kbKeywordScore(q, "骨折需要固定。") == 0.0)
    runner.check("★ ⑤ 空查询 ⇒ 0", kbKeywordScore(Array<String>(), "高血压") == 0.0)

    /* ⑥ ★ 稳定排序：同分按 chunkId 升序，否则同一查询两次返回不同块（输出不可复现）。 */
    let hits = ArrayList<KbHit>()
    let ids: Array<Int64> = [30, 10, 20, 5]
    for (idv in ids) {
        let h = KbHit()
        h.chunkId = idv
        h.score = 0.5
        hits.add(h)
    }
    let sorted = kbSortHits(hits.toArray())
    var orderOk = true
    var i: Int64 = 1
    while (i < sorted.size) {
        if (sorted[i - 1].chunkId > sorted[i].chunkId) {
            orderOk = false
        }
        i = i + 1
    }
    runner.check("★★ ⑥ 同分时按 chunkId 升序（稳定排序，实得 " +
                 "${sorted[0].chunkId},${sorted[1].chunkId},${sorted[2].chunkId},${sorted[3].chunkId}）",
                 orderOk)

    /* ⑦ 降序：高分在前。 */
    let h2 = ArrayList<KbHit>()
    let hLow = KbHit(); hLow.chunkId = 1; hLow.score = 0.1
    let hHigh = KbHit(); hHigh.chunkId = 2; hHigh.score = 0.9
    h2.add(hLow); h2.add(hHigh)
    let s2 = kbSortHits(h2.toArray())
    runner.check("⑦ 按分数降序（高分在前，实得首位 score=${s2[0].score}）", s2[0].score == 0.9)
}

/* ---------- AC-KB-4：仓储（★ 改文档后旧块必须消失）---------- */public func acKb4(runner: TestRunner, db: DbBackend): Unit {
    println("=== AC-KB-4 ★★★ 仓储：改正文后**旧块必须消失** + 检索如实标注 source ===")
    let repo = KbRepo(db)
    let now = hNowEpoch()

    /* 清本用例文档（按标题前缀，避免误伤）。 */
    let olds = repo.listDocs()
    for (d in olds) {
        if (d.title.startsWith("ACKB")) {
            let _r = repo.remove(d.id)
        }
    }

    /* ① 建文档 ⇒ 自动切块。 */
    let longBody = hRepeatChar("高血压需要长期服药并监测血压。", 80)
    let c1 = repo.create("ACKB高血压须知", "内科", longBody, 9901, now)
    runner.check("① 建文档成功", c1.ok)
    match (repo.findById(c1.id)) {
        case Some(d) =>
            runner.check("① 且块数 > 1（实得 ${d.chunkCount}）", d.chunkCount >= 2)
            runner.check("① 正文完整保存（字符数一致）",
                         previsitCharLen(d.body) == previsitCharLen(longBody.trimAscii()))
        case None =>
            runner.check("① 回读文档（不该找不到）", false)
    }

    /* ② ★ 重名被拒：同一主题两份矛盾文档会被同时召回。 */
    let dup = repo.create("ACKB高血压须知", "内科", "另一份内容。", 9901, now)
    runner.check("★★ ② 同标题被拒（duplicate）", dup.duplicate)

    /* ③ 个人信息形态被拒（合规闸门）。 */
    let piPhone = repo.create("ACKB含手机号", "", "患者张三电话 13800138000 请随访。", 9901, now)
    runner.check("★★ ③ 正文含手机号形态 ⇒ 被拒（知识库不得放患者信息）", piPhone.invalid)
    runner.check("★ ③ 且说明原因（含「个人信息」）", piPhone.detail.contains("个人信息"))
    let piId = repo.create("ACKB含身份证", "", "身份证 110101199003071234 见附件。", 9901, now)
    runner.check("★★ ③ 正文含身份证形态 ⇒ 被拒", piId.invalid)
    /* ③之二 「17 位数字 + X」也须被拒：数字段只累加 0-9，末位 X 时仅 17 位、不触发 maxRun >= 18。
     * 合规闸门漏掉最常见写法比没有更糟，大小写各一条用例。 */
    let piIdX = repo.create("ACKB含身份证X", "", "身份证 11010119900307123X 见附件。", 9901, now)
    runner.check("★★ ③ 正文含「17 位 + 大写 X」身份证 ⇒ **被拒**（原来漏判；理由：${piIdX.detail}）", piIdX.invalid)
    let piIdx = repo.create("ACKB含身份证x", "", "身份证 11010119900307123x 见附件。", 9901, now)
    runner.check("★★ ③ 正文含「17 位 + 小写 x」身份证 ⇒ 被拒", piIdx.invalid)
    /* 反向：16 位数字 + X 不是身份证形状，不得误杀。 */
    let ok16 = repo.create("ACKB十六位加X", "", "编号 1234567890123456X 是设备序列号。", 9901, now)
    runner.check("★ ③ 对照：16 位数字 + X **不误杀**（不是身份证形状）", ok16.ok)
    let _rm16 = repo.remove(ok16.id)
    /* 反向：17 位纯数字不是身份证形状。 */
    let ok17 = repo.create("ACKB十七位纯数字", "", "编号 12345678901234567 是设备序列号。", 9901, now)
    runner.check("★ ③ 对照：17 位**纯数字** 不误杀", ok17.ok)
    let _rm17 = repo.remove(ok17.id)
    /* 对照：正常医学文本不得被误杀，否则闸门只是"一律拒绝"的假绿。 */
    let okDoc = repo.create("ACKB正常文档", "内科", "血压 140/90 mmHg 属于偏高，需复诊评估。", 9901, now)
    runner.check("★★ ③ 对照：含数字的正常医学文本**不被误杀**", okDoc.ok)
    let _rm = repo.remove(okDoc.id)

    /* ④ 空/超长校验。 */
    runner.check("④ 空标题被拒", repo.create("", "", "正文", 9901, now).invalid)
    runner.check("④ 空正文被拒", repo.create("ACKB空正文", "", "   ", 9901, now).invalid)
    runner.check("④ 超长正文被拒",
                 repo.create("ACKB超长", "", hRepeatChar("字", KB_BODY_MAX_CHARS + 10), 9901, now).invalid)

    /* ⑤ 改文档 ⇒ 重新切块。 */
    let longer = hRepeatChar("糖尿病需要控制饮食并监测血糖。", 140)
    let u = repo.update(c1.id, "ACKB高血压须知", "内科", longer, true, 9901, now + 10)
    runner.check("⑤ 改文档成功", u.ok)
    var countAfter: Int64 = 0
    match (repo.findById(c1.id)) {
        case Some(d) => countAfter = d.chunkCount
        case None => ()
    }
    runner.check("⑤ 块数随正文变长而增加（${countAfter} 块）", countAfter >= 4)

    /* ⑥ ★ 改短后旧的长块必须消失：只 upsert 不删尾部会留下 seq >= 新块数的旧块，检索会召回已删除正文。 */
    let shortBody = "短正文：仅一段。"
    let _u2 = repo.update(c1.id, "ACKB高血压须知", "内科", shortBody, true, 9901, now + 20)
    var countShort: Int64 = 0
    match (repo.findById(c1.id)) {
        case Some(d) => countShort = d.chunkCount
        case None => ()
    }
    runner.check("★★★ ⑥ 改短后块数**减少到 1**（实得 ${countShort}）—— 尾部旧块已删", countShort == 1)
    let cnt = kbCount1(db, "SELECT COUNT(*) FROM kb_chunk WHERE doc_id = ${c1.id}")
    runner.check("★★★ ⑥ 且库里该文档的块**确实只有 1 行**（实得 ${cnt}）", cnt == 1)

    /* ⑦ 关键词路可用且 source 如实。 */
    let _ = repo.create("ACKB检索用", "内科", "高血压患者应当低盐饮食并规律服药。", 9901, now)
    let rk = repo.searchKeyword("高血压", topN: 5)
    runner.check("★ ⑦ 关键词检索能命中（${rk.hits.size} 条，扫过 ${rk.scanned} 块）", rk.hits.size >= 1)
    runner.check("★★ ⑦ 且 `source` 如实标注为 keyword（**不是** vector）",
                 rk.source == KB_SOURCE_KEYWORD)
    var kwOk = true
    for (h in rk.hits) {
        if (h.source != KB_SOURCE_KEYWORD) {
            kwOk = false
        }
    }
    runner.check("★★ ⑦ 每条命中也都标 keyword（不只是顶层字段）", kwOk)
    runner.check("★ ⑦ 命中的块确实含查询词（实得「${rk.hits[0].content}」）",
                 rk.hits[0].content.contains("高血压"))

    /* ⑧ 空查询/纯标点 ⇒ 空结果，不返回随机块。 */
    runner.check("★ ⑧ 纯标点查询 ⇒ 空结果", repo.searchKeyword("，。！").hits.size == 0)

    /* ⑨ 向量路：库里无向量 ⇒ 空结果 + missingVectors 如实回报。 */
    /* ⑨ 前置：先清掉库里所有向量，自己制造"无向量"状态 —— 断言某状态就必须制造该状态。
     * 清全表而非只清本文档：断言的是"库内"无向量。 */
    db.exec("UPDATE kb_chunk SET embedding = NULL, embedded_at = 0", Array<DbValue>())
    let vecLeft = kbCount1(db, "SELECT COUNT(*) FROM kb_chunk WHERE embedding IS NOT NULL")
    runner.check("★★ ⑨ 前提就绪：库里确实没有向量（实得 ${vecLeft}）", vecLeft == 0)
    let rv = repo.searchVector([1.0, 2.0, 3.0], topN: 5)
    runner.check("★★ ⑨ 库里无向量 ⇒ 向量检索空结果（不是回落到关键词冒充向量）",
                 rv.hits.size == 0)
    runner.check("★ ⑨ 且 `source` 仍如实标 vector（说明「这条路跑了但没数据」）",
                 rv.source == KB_SOURCE_VECTOR)
    runner.check("★★ ⑨ 且 `missingVectors` 如实回报（实得 ${rv.missingVectors} > 0）",
                 rv.missingVectors > 0)

    /* ⑩ 写向量后向量路能命中，且与关键词路各自标注 source。 */
    let pend = repo.pendingChunks(50)
    runner.check("⑩ 有「待向量化」的块（${pend.size} 个）", pend.size >= 1)
    var embedded = 0
    for (p in pend) {
        /* 按内容长度造假向量，只为验证管线，不冒充真 embedding。 */
        let v: Array<Float64> = [Float64(previsitCharLen(p.content)) , 1.0, 0.5]
        if (repo.setEmbedding(p.chunkId, v, now)) {
            embedded = embedded + 1
        }
    }
    runner.check("⑩ 写入向量成功（${embedded} 个）", embedded >= 1)
    let rv2 = repo.searchVector([Float64(previsitCharLen(pend[0].content)), 1.0, 0.5], topN: 3)
    runner.check("★★ ⑩ 有向量后向量路能命中（${rv2.hits.size} 条）", rv2.hits.size >= 1)
    runner.check("★★ ⑩ 且标 source=vector", rv2.source == KB_SOURCE_VECTOR &&
                 rv2.hits[0].source == KB_SOURCE_VECTOR)

    /* ⑪ 停用文档 ⇒ 其块不再被检索到（enabled 属于检索语义）。 */
    let docOff = repo.create("ACKB将被停用", "内科", "高血压停用测试专用内容甲乙丙。", 9901, now)
    let before = repo.searchKeyword("停用测试专用").hits.size
    let _u3 = repo.update(docOff.id, "ACKB将被停用", "内科",
                          "高血压停用测试专用内容甲乙丙。", false, 9901, now + 30)
    let after = repo.searchKeyword("停用测试专用").hits.size
    runner.check("★★ ⑪ 停用前能检索到（${before} 条），停用后检索不到（${after} 条）",
                 before >= 1 && after == 0)

    /* ⑫ 删文档 ⇒ 块连带真删（与 department 软删不同）。 */
    let _rm2 = repo.remove(docOff.id)
    runner.check("★★ ⑫ 删文档后其块也消失",
                 kbCount1(db, "SELECT COUNT(*) FROM kb_chunk WHERE doc_id = ${docOff.id}") == 0)
    runner.check("★ ⑫ 删不存在的文档 ⇒ notFound", repo.remove(99999999).notFound)

    /* ⑬ 看板规模统计真实。 */
    let st = repo.stats()
    runner.check("★ ⑬ stats() 给出 docs/chunks 与向量覆盖率",
                 st.containsKey("docs") && st.containsKey("chunks") &&
                 st.containsKey("embedding_coverage_pct"))

    /* 清理。 */
    for (d in repo.listDocs()) {
        if (d.title.startsWith("ACKB")) {
            let _r = repo.remove(d.id)
        }
    }
}

/* ---------- AC-KB-5：★ RAG 片段接入分诊（三条硬约束）---------- */
public func acKb5(runner: TestRunner, db: DbBackend): Unit {
    let repo = KbRepo(db)
    println("=== AC-KB-5 ★★★ RAG 片段：过安全层 / 有界 / **改不了 options** ===")

    /* ① 空命中 ⇒ 空串，不是空段落（空段落会诱导模型自己编参考资料）。 */
    runner.check("① 空命中 ⇒ 空串", aiRagContext(Array<KbHit>()).size == 0)

    /* 造一条正常命中。 */
    let h1 = KbHit()
    h1.title = "就诊须知"
    h1.content = "就诊前请携带既往病历与检查资料，便于医生快速了解病情。"
    let one: Array<KbHit> = [h1]
    let ctx1 = aiRagContext(one)
    runner.check("★ ② 正常片段被采纳且**带上标题**（便于模型措辞与排障）", ctx1.contains("就诊须知"))
    runner.check("★ ② 且以列表符开头（结构清晰）", ctx1.startsWith("· "))

    /* ③ ★ 片段也要过安全层：含用药/诊断的片段必须丢弃 —— 依据是"这段文本会不会原样给患者看"，与来源无关。 */
    let bad = KbHit()
    bad.title = "某材料"
    bad.content = "建议服用氨氯地平 5mg，每日一次。"
    let badArr: Array<KbHit> = [bad]
    runner.check("★★★ ③ 含用药的片段被**整条丢弃**（不是过滤掉药名后留下）",
                 aiRagContext(badArr).size == 0)

    /* ④ 混排：坏片段被丢、好片段保留。 */
    let mixed: Array<KbHit> = [bad, h1]
    let ctxMixed = aiRagContext(mixed)
    runner.check("★★ ④ 好坏混排时，好的留下、坏的丢掉（不是整批丢弃）",
                 ctxMixed.size > 0 && ctxMixed.contains("就诊须知"))
    runner.check("★★ ④ 且坏片段的内容**没有**出现在结果里", !ctxMixed.contains("氨氯地平"))

    /* ⑤ ★ 有界：50 条长片段总长不得超过 AI_RAG_TOTAL_CHARS（按字符，不是字节）。 */
    let many = ArrayList<KbHit>()
    var k: Int64 = 0
    while (k < 50) {
        let h = KbHit()
        h.title = "材料${k}"
        h.content = hRepeatChar("高血压需要长期管理并定期随访。", 10)
        many.add(h)
        k = k + 1
    }
    let ctxMany = aiRagContext(many.toArray())
    let ctxLen = previsitCharLen(ctxMany)
    runner.check("★★ ⑤ 总长有界（${ctxLen} ≤ ${AI_RAG_TOTAL_CHARS} 字符）", ctxLen <= AI_RAG_TOTAL_CHARS)
    runner.check("★ ⑤ 且确实取到了内容（不是「为了有界干脆全丢」，实得 ${ctxLen} 字符）", ctxLen > 0)

    /* ⑥ ★ Prompt 必须挡住"按资料改推荐"：否则模型会复述知识库里的科室，而该科室可能没号。 */
    let v = TriageVerdict()
    let o = TriageOption()
    o.departmentName = "呼吸内科"
    v.options = [o]
    let pr = aiTriagePrompt("咳嗽三天", v, ragHits: one)
    runner.check("★★★ ⑥ Prompt 含参考资料段", pr.contains("参考资料"))
    runner.check("★★★ ⑥ 且明确写了「不要去哪个科室以系统判定为准」", pr.contains("以系统判定为准"))
    runner.check("★★ ⑥ 且仍带上规则判定的科室（模型据此措辞）", pr.contains("呼吸内科"))

    /* ⑦ 无命中 ⇒ Prompt 完全不变，不留空段。 */
    let prNo = aiTriagePrompt("咳嗽三天", v)
    runner.check("★★ ⑦ 无命中时 Prompt **不含**参考资料段（不留空段诱导模型编造）",
                 !prNo.contains("参考资料"))
    runner.check("★ ⑦ 且与显式传空数组等价", prNo == aiTriagePrompt("咳嗽三天", v, ragHits: Array<KbHit>()))

    /* ⑧ 接入 RAG 后 options 依然只由规则决定。 */
    let v2 = TriageVerdict()
    let o2 = TriageOption()
    o2.departmentName = "心内科"
    o2.remainNum = 0
    v2.options = [o2]
    let _ = aiRagContext(one)
    let _p2 = aiTriagePrompt("咳嗽", v2, ragHits: one)
    runner.check("★★★ ⑧ 组 Prompt 不改 `options`（推荐科室与号源仍是规则给的）",
                 v2.options.size == 1 && v2.options[0].departmentName == "心内科" &&
                 v2.options[0].remainNum == 0)
    runner.check("★★★ ⑧ 且没有把知识库里的科室名塞进 options",
                 v2.options.size == 1)

    /* ⑨ ★ stats() 必须给出"能否检索全"的布尔结论：KB_SCAN_LIMIT 触顶后超出的块静默检索不到，
     * 只有 scan_limit_reached 能暴露；且当前必须断言为 false，否则恒 true 的假信号也能过。 */
    let st = repo.stats()
    runner.check("★★ ⑨ stats() 回报 scan_limit 与**布尔结论** scan_limit_reached",
                 st.containsKey("scan_limit") && st.containsKey("scan_limit_reached"))
    /* JsonObject.get 返回 ?JsonValue：必须先 match 取出再判类型（asBool 不是 Option 的方法）。 */
    var reached = true
    match (st.get("scan_limit_reached")) {
        case Some(jv) =>
            if (jv is JsonBool) {
                reached = jv.asBool().getValue()
            }
        case None => ()
    }
    runner.check("★★ ⑨ 当前块数远小于上限 ⇒ scan_limit_reached = false（不是恒 true 的假信号）",
                 !reached)
    runner.check("★★ ⑨ 且带口径说明（0% 时不能让人以为功能坏了）",
                 st.containsKey("scan_limit_note") && st.containsKey("embedding_note"))
}