/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 *
 * ===== sql_recorder.cj —— 记录被执行过的 SQL（**测试工具**，不是生产组件）=====
 *
 * ── 为什么需要它（这是 AC-4 能做到"机制性证明"的关键）──────────────────────
 * AC-4 要验的是「整库刷盘**不会**波及号源域（schedule / appointment）」。
 * 只断言"刷完之后 schedule 里的值没变"是**弱**的：
 *   · 刷盘可能**确实读了/写了** schedule 又恰好写回原值（写放大仍存在，只是值相同）；
 *   · 或者将来有人把 schedule 加进遍历源，但刷出的值碰巧一样 —— 断言照样绿。
 *
 * 所以这里换一种更强的验法：**把刷盘实际发出的 SQL 全录下来，按表名分类**，
 * 然后断言 `schedule` / `appointment` **从未出现在任何一条 SQL 里**。
 * 这是**机制性证明**（"根本没碰"），不是"碰了但值没变"。
 *
 * ── 为什么能这么做 ────────────────────────────────────────────────────────
 * 框架的 `DbBackend` 是个**接口**（third_party/qingzhou/src/db.cj:100），
 * 而且参数化方法 `query(sql, params)` / `exec(sql, params)` 有**默认实现**，
 * 走 `bindSql(sql, params)` → 单参数版本。所以：
 *   装饰器只需实现 6 个抽象方法 + 2 个单参数方法，参数化调用会被默认实现
 *   转发进来 ⇒ **一条都不会漏**。
 *
 * ⚠ 生产路径**不要**用它（每次调用多一层与一次字符串处理）。
 *   它只为测试存在；`accept` 里按需包一层。
 */

package qingzhou

import std.collection.*
import std.regex.*

/*
 * SQL 录制器：实现 DbBackend，把每条 SQL 记下来后转发给真实后端。
 */
public class SqlRecorder <: DbBackend {
    private let inner: DbBackend
    /*
     * 录下来的语句原文（按发生顺序）。
     * ⚠ 用 ArrayList 而非 Set：顺序有诊断价值（能看出事务里的先后）。
     */
    public var statements: ArrayList<String> = ArrayList<String>()

    public init(inner: DbBackend) {
        this.inner = inner
    }

    /* ---------- 录制 + 转发 ---------- */

    public func query(sql: String): DbResultSet {
        statements.add(sql)
        return inner.query(sql)
    }

    public func exec(sql: String): Int64 {
        statements.add(sql)
        return inner.exec(sql)
    }

    public func ensureTable(name: String, columns: String): Unit {
        statements.add("ENSURE TABLE " + name)
        inner.ensureTable(name, columns)
    }

    public func close(): Unit {
        inner.close()
    }

    public func beginTransaction(): Unit {
        statements.add("BEGIN")
        inner.beginTransaction()
    }

    public func commitTransaction(): Unit {
        statements.add("COMMIT")
        inner.commitTransaction()
    }

    public func rollbackTransaction(): Unit {
        statements.add("ROLLBACK")
        inner.rollbackTransaction()
    }

    /*
     * 参数化版本**必须**覆盖：默认实现会走 `bindSql` 再调单参数版本（也能录到），
     * 但那样录到的是**拼好的常量 SQL**。这里显式覆盖，录到的同样是拼好的文本
     * （因为我们关心中"碰了哪张表"，与绑定形式无关），同时避免依赖默认实现的细节。
     */
    public func query(sql: String, params: Array<DbValue>): DbResultSet {
        return query(bindSql(sql, params))
    }

    public func exec(sql: String, params: Array<DbValue>): Int64 {
        return exec(bindSql(sql, params))
    }

    /* ---------- 查询接口 ---------- */

    public func clear(): Unit {
        statements.clear()
    }

    public func count(): Int64 {
        return statements.size
    }

    /*
     * ★ 录到的语句里**是否提到过某张表**。
     *
     * 判定方式：按**词边界**匹配表名，而不是裸 `contains`。
     *   ⚠ 裸 contains 会误判：`appointment` 是 `appointment_x` 的子串；
     *     更现实的是本项目里 `auth_login_attempt` 与 `appointment` 无关但都含字母，
     *     真正会咬人的是 `schedule` 与 `schedule_id`（列名！）——
     *     `SELECT ... WHERE schedule_id = ?` 里的 `schedule_id` **不是**表 `schedule`。
     *   所以用正则 `\b<表名>\b`，且要求表名后面不紧跟 `_`（即排除 `schedule_id` 这类列名）。
     *
     * ⚠ 这仍有理论误判空间（比如别名恰好叫 schedule）。对本项目的用途足够，
     *   且**误判方向是安全的**：宁可多报"碰了"（测试变红让人来查），
     *   也不要漏报"没碰"。
     */
    public func mentionsTable(table: String): Bool {
        // SQL 里表名可能被反引号包着，也可能直接跟在 FROM/INTO/UPDATE/JOIN 后面
        let pat = "(?i)(^|[^A-Za-z0-9_])" + table + "([^A-Za-z0-9_]|$)"
        let re = Regex(pat)
        for (s in statements) {
            if (re.find(s).isSome()) {
                return true
            }
        }
        return false
    }

    /* 列出录到的语句里出现过的**内存 Store 表**（用于断言"该碰的都碰了"）。 */
    public func mentionedMemTables(): Array<String> {
        let out = ArrayList<String>()
        for (t in MEM_TABLES) {
            if (mentionsTable(t)) {
                out.add(t)
            }
        }
        return out.toArray()
    }
}
