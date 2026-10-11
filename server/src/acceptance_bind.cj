/*
 * 验收：**参数化绑定的写路径**（AC-BIND-1）—— 专门守一类"静默改写用户数据"的缺陷。
 *
 * 为什么单独立一档：本仓曾同时踩中**三个**互相独立、且都**不报错**的绑定缺陷，
 * 每一个都能把用户输入改成别的东西：
 *   ① 值里的 `?` 被写成字面量 **NULL**（`q?one` ⇒ `qNULLone`）
 *      —— 根因：轻舟显式给 MySQL 连接设了 `prepare.mode=client`，而驱动在该模式下
 *      按**整条 SQL 里 `?` 的字符个数**定参数槽位（`prepare_statement_client.cj:45`），
 *      数据里那个 `?` 也占一个槽位、没人绑定 ⇒ 填成 `NULL`。
 *   ② 值里的 `'` **没有双写**（`it's` ⇒ SQL 变成 `'it's'`，语法直接跑飞、
 *      整条 INSERT 失败）—— 而在**读回用于比对**时又会静默对不上，看起来像"数据没存进去"。
 *   ③ 值里的 `\` **没有双写**（`a\b` ⇒ 存成 `a` + 退格符；`trail\` ⇒ 逃逸收尾引号、
 *      整条 SQL 语法错）—— 根因：框架 `sqlEscape` 只做 SQL 标准的 `''` 双写，
 *      而 MySQL 默认会话**还开着反斜杠转义**。
 *
 * ⇒ 三条的共同教训：**"写进去了"不等于"写对了"**。本用例因此不看"有没有报错"，
 *   而是把值写进库、再**逐字节读回比对**，并额外确认注入形态没有真的执行。
 *
 * ⚠ 本用例只碰自己的表 `ac_bind_probe`，开头 DROP、结尾 DROP，不给别的用例留状态。
 */
package qingzhou

public func acBind1(runner: TestRunner, db: DbBackend): Unit {
    println("=== AC-BIND-1 ★★★ 参数化绑定：含 ? / \\ / ' 的值必须**原样**往返 ----------")

    try {
        let _ = db.exec("DROP TABLE IF EXISTS ac_bind_probe")
        let _ = db.exec("CREATE TABLE ac_bind_probe (id INT PRIMARY KEY, v TEXT)")
    } catch (e: Exception) {
        runner.check("① 建夹具表失败：${e.message}", false)
        return
    }

    /*
     * 覆盖三类字符各自的**独立形态**与**组合形态**。
     * 每个值都单独一行，一个出错不会掩盖另一个。
     */
    let cases = [
        "plain",
        "q?one",              // ① 单个 ?
        "a?b?c",              // ① 多个 ?
        "?end",               // ① ? 在开头（切分会产生空首段）
        "?//?/?",             // ① 全是 ?
        "a\\b",               // ③ 反斜杠
        "a\\b\\c",            // ③ 多个反斜杠
        "trail\\",            // ③ **以反斜杠结尾**（会逃逸收尾引号的那种）
        "it's",               // ② 单引号
        "it's a q?one\\mix",  // 三者组合
        "中?文\\路",           // 多字节 + 组合
        "x'; DROP TABLE ac_bind_probe; -- ?"  // 注入形态（既有 ' 又有 ?）
    ]

    var i: Int64 = 0
    while (i < cases.size) {
        let v = cases[i]
        let id = i + 1

        /* 写：走框架参数化入口（也是全仓 28 处调用的同一条路）。 */
        var threw = ""
        try {
            let _ = db.exec("INSERT INTO ac_bind_probe (id, v) VALUES (?, ?)", [DbInt(id), DbStr(v)])
        } catch (e: Exception) {
            threw = e.message
        }
        runner.check("② [${i}] 含特殊字符的值可以写入（值=${hHexPreview(v)}）" +
                     (if (threw.size > 0) { "：${threw}" } else { "" }),
                     threw.size == 0)
        if (threw.size > 0) {
            i += 1
            continue
        }

        /* 读回：逐字节比对。这是本用例的核心 —— 不看报错，看**字节**。 */
        var got = "(没读到)"
        var readThrew = ""
        try {
            let rs = db.query("SELECT v FROM ac_bind_probe WHERE id = ?", [DbInt(id)])
            if (rs.rowCount() > 0) {
                got = rs.getString(0, 0)
            }
        } catch (e: Exception) {
            readThrew = e.message
        }
        if (readThrew.size > 0) {
            runner.check("★ [${i}] 读回不抛异常：${readThrew}", false)
        } else {
            runner.check("★★ [${i}] 写出的值与读回的**逐字节一致**" +
                         "（入=${hHexPreview(v)} 出=${hHexPreview(got)}）",
                         got == v)
        }
        i += 1
    }

    /* ③ 注入形态没有真的执行：表还在，且行数正确。 */
    var total = "0"
    try {
        let rs = db.query("SELECT COUNT(*) FROM ac_bind_probe")
        total = rs.getString(0, 0)
    } catch (e: Exception) {
        runner.check("③ 表不见了（说明末尾那条注入真的执行了）：${e.message}", false)
        return
    }
    runner.check("★★★ ③ 注入形态未被执行：表仍在且行数为 ${cases.size}（实得 ${total}）",
                 total == cases.size.toString())

    /*
     * ④ 反向：**不同类型**的值不会被误加引号 —— 数字必须以数字形态落库，
     *    否则 `WHERE id = '1'` 这类比较会依赖隐式转换（索引失效且有语义差异）。
     */
    try {
        let rs = db.query("SELECT COUNT(*) FROM ac_bind_probe WHERE id = ?", [DbInt(1)])
        runner.check("④ 数字参数按数字比较（不靠隐式转换）", rs.getString(0, 0) == "1")
        let rs2 = db.query("SELECT COUNT(*) FROM ac_bind_probe WHERE id = ?", [DbInt(999)])
        runner.check("④ 且不存在的 id 计数为 0（比较语义正常）", rs2.getString(0, 0) == "0")
    } catch (e: Exception) {
        runner.check("④ 数字参数查询抛异常：${e.message}", false)
    }

    /* ⑤ 收尾：自己清干净，不给别的用例留状态。 */
    var cleaned = false
    try {
        let _ = db.exec("DROP TABLE IF EXISTS ac_bind_probe")
        let rs = db.query("SELECT COUNT(*) FROM information_schema.tables" +
                          " WHERE table_schema = DATABASE() AND table_name = 'ac_bind_probe'")
        cleaned = (rs.getString(0, 0) == "0")
    } catch (e: Exception) {
        runner.check("⑤ 清理夹具表失败：${e.message}", false)
    }
    runner.check("⑤ 夹具表已清理（本用例残留为 0）", cleaned)
}

/*
 * 十六进制预览：把值转成可读的 hex，**出错时也不会抛**（探针本身不能成为失败源）。
 * 只在出错信息里用，所以长度截断到 48 个 hex 字符。
 */
func hHexPreview(s: String): String {
    var out = ""
    var i = 0
    while (i < s.size && i < 24) {
        let b = UInt8(s[i])
        out += hHexDigit(b >> 4) + hHexDigit(b & 15)
        i += 1
    }
    if (s.size > 24) {
        out += "…"
    }
    return out
}

func hHexDigit(n: UInt8): String {
    let digits = "0123456789ABCDEF"
    let idx = Int64(n)
    return digits[idx..(idx + 1)]
}
