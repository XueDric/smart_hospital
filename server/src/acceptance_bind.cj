/*
 * 验收：参数化绑定的写路径（AC-BIND-1），守"静默改写用户数据"类缺陷。
 * 对外：acBind1(runner, db)；夹具表 ac_bind_probe 开头 DROP、结尾 DROP，不留状态。
 * 约束：必须写库后逐字节读回比对——"写进去了"不等于"写对了"。
 * 风险：驱动按整条 SQL 的 ? 个数定槽位，值里的 ? 会占槽被填 NULL；' 与 \ 未双写会写坏数据。
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
     * 三类字符的独立形态与组合形态，逐值一行，一个出错不掩盖另一个。
     * 编号：① ? 占位符 ② 单引号 ③ 反斜杠 ④ 类型 ⑤ 清理，与断言编号对应。
     */
    let cases = [
        "plain",
        "q?one",
        "a?b?c",
        "?end",
        "?//?/?",
        "a\\b",
        "a\\b\\c",
        "trail\\",
        "it's",
        "it's a q?one\\mix",
        "中?文\\路",
        "x'; DROP TABLE ac_bind_probe; -- ?"
    ]

    var i: Int64 = 0
    while (i < cases.size) {
        let v = cases[i]
        let id = i + 1

        /* 写：走框架参数化入口（全仓同一条路）。 */
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

        /*
         * 读回逐字节比对，不看报错：这是本用例的核心 —— 只认字节。
         */
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

    /* ③ 注入形态须未被执行：表仍在且行数正确。 */
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

    /* ④ 数字参数按数字比较，避免隐式转换：`WHERE id = '1'` 会失效索引且有语义差异。 */
    try {
        let rs = db.query("SELECT COUNT(*) FROM ac_bind_probe WHERE id = ?", [DbInt(1)])
        runner.check("④ 数字参数按数字比较（不靠隐式转换）", rs.getString(0, 0) == "1")
        let rs2 = db.query("SELECT COUNT(*) FROM ac_bind_probe WHERE id = ?", [DbInt(999)])
        runner.check("④ 且不存在的 id 计数为 0（比较语义正常）", rs2.getString(0, 0) == "0")
    } catch (e: Exception) {
        runner.check("④ 数字参数查询抛异常：${e.message}", false)
    }

    /* ⑤ 收尾：清理夹具表，不给别的用例留状态。 */
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

/* 十六进制预览：只在出错信息里用，本身不抛；长度截断到 24 字节。 */
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
