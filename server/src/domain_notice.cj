package qingzhou

/*
 * ⚠ `ArrayList` 来自 std.collection —— 本仓踩过"漏 import 报 undeclared identifier"
 *   （见 domain_booking.cj 的同类注释），所以这里显式写上。
 *   `DbBackend`/`DbResultSet`/`DbInt`/`DbStr` 与 `BaseWriteOutcome` 等都在本包内
 *   （单 package 模式），不需要 import。
 */
import std.collection.*

/*
 * ===================== 公告域：`notice` 表的仓储 =====================
 *
 * 为什么有这一层（而不是把 SQL 直接写在路由里）：
 *   ① 与 `domain_base.cj` / `domain_emr.cj` / `kb_repo.cj` 同构 ——
 *      本仓的分层是「http_*.cj 只做解析/鉴权/序列化，domain_*.cj 独占 SQL」，
 *      于是"谁能写这张表"永远只有一处答案；
 *   ② 校验放在仓储里（而不是只放 HTTP 层）：测试与将来的 CLI 也走同一套校验，
 *      同一语义只留一处实现（照 `DepartmentRepo.create` 的注释）。
 *
 * ⚠ 本仓储**不属**号源域（`BOOKING_DOMAIN_TABLES` 只有 schedule/appointment）：
 *   公告不参与号源扣减、没有并发争抢语义 ⇒ 走直接 SQL，不进 BookingRepo。
 *   （`main.cj` 的自检里它单独成一类 `noticeTables`，理由见那里的注释。）
 *
 * ⚠ 时间一律 **epoch 秒**（与全仓一致）：格式化成年月日是**展示层**的事，
 *   放在 `http_notice.cj`。这里不碰时区 —— 否则同一个换算会有两处实现，
 *   而本仓已经写明"日期换算是最容易写错且错了也看不出来的一类代码"。
 */

/* ===================== 常量 ===================== */

/*
 * 长度上限与列宽对齐（VARCHAR(128) / VARCHAR(32) / TEXT）。
 * ⚠ 一律按**字符**计（`previsitCharLen`），不按字节 ——
 *   本仓为"字节/字符混用"栽过三次（见 server/README.md 踩坑表）：
 *   按字节判 128 时 43 个汉字就会被拒，而列本来是 128 个汉字。
 */
public let NOTICE_TITLE_MAX_CHARS: Int64 = 128
public let NOTICE_CATEGORY_MAX_CHARS: Int64 = 32
/*
 * 正文上限 2000 字：公告是**给人看的一段话**，不是知识库文档
 * （`KB_BODY_MAX_CHARS` = 20000 是"一篇须知"的量级）。
 * 给个明确上限是为了让"有人把整本书贴进公告"在写入那一刻失败，
 * 首页展示也不会被一条巨型公告拖慢。
 */
public let NOTICE_BODY_MAX_CHARS: Int64 = 2000

/* 患者侧列表默认/最大条数（首页只要最近几条；给上限防"一次拉全表"）。 */
public let NOTICE_LIST_DEFAULT_LIMIT: Int64 = 20
public let NOTICE_LIST_MAX_LIMIT: Int64 = 200

/*
 * 列清单**只写一处**，下标常量与它一一对应。
 *
 * ⚠⚠ 本仓在 `domain_booking.cj` 上吃过一次真实的亏：SELECT 列顺序散落在
 *   4 个查询里，改一处忘一处 ⇒ 按下标取值（`getInt(i, 3)`）全错位，
 *   而错位**不会抛异常**（列数相同、类型也常常兼容），
 *   表现为"字段值莫名其妙"，排查成本极高。
 *   ⇒ 公告这边：① 列清单提成一个常量，所有 SELECT 都用它；
 *     ② 下标提成命名常量（不是散落的字面量）；
 *     ③ `noticeFromRow` 里加**列数护栏**，不一致当场抛。
 *   📌 三条一起才有效：只做 ①，下标仍然会写错；只做 ③，报错点离病根太远。
 */
public let NOTICE_COLUMNS: String =
    "id, title, body, category, sort, enabled, published_at, updated_by, created_at, updated_at"
public let NOTICE_COLUMN_COUNT: Int64 = 10

public let NOTICE_COL_ID: Int64 = 0
public let NOTICE_COL_TITLE: Int64 = 1
public let NOTICE_COL_BODY: Int64 = 2
public let NOTICE_COL_CATEGORY: Int64 = 3
public let NOTICE_COL_SORT: Int64 = 4
public let NOTICE_COL_ENABLED: Int64 = 5
public let NOTICE_COL_PUBLISHED_AT: Int64 = 6
public let NOTICE_COL_UPDATED_BY: Int64 = 7
public let NOTICE_COL_CREATED_AT: Int64 = 8
public let NOTICE_COL_UPDATED_AT: Int64 = 9

/* ===================== 模型 ===================== */

public class Notice {
    public var id: Int64 = 0
    public var title: String = ""
    /* 正文允许**换行**（公告常有多段），但不允许其它控制字符 —— 见 `noticeCheckText`。 */
    public var body: String = ""
    public var category: String = "通知"
    /* 排序权重（小的在前）。与 `department.sort` 同义：人工可控的展示顺序。 */
    public var sort: Int64 = 0
    public var enabled: Bool = true
    /* 发布时刻（epoch 秒）。**晚于当前时间 = 预排期**，患者侧此时看不到。 */
    public var publishedAt: Int64 = 0
    public var updatedBy: Int64 = 0
    public var createdAt: Int64 = 0
    public var updatedAt: Int64 = 0
}

/* ===================== 校验 ===================== */

/*
 * 通用文本校验：非空、按字符限长、拒绝控制字符。
 *
 * ⚠ `allowNewline` 只对**正文**开：公告正文多段是正常写法，
 *   而标题/分类含换行只会破坏列表排版与日志的单行假设。
 * ⚠ 不复用 `baseValidateName`：它的上限是 `BASE_NAME_MAX`(64)，
 *   拿来判 128 字符的标题会给出"最长 64 字"这种**与列宽不符**的提示 ——
 *   提示必须与真实约束一致，否则使用者会以为系统坏了。
 */
public func noticeCheckText(v: String, what: String, maxChars: Int64, allowNewline: Bool): String {
    let t = v.trimAscii()
    if (t.size == 0) {
        return "${what}不能为空"
    }
    if (previsitCharLen(t) > maxChars) {
        return "${what}最长 ${maxChars} 字"
    }
    for (b in t.toArray()) {
        if (b < 0x20 || b == 0x7F) {
            if (allowNewline && (b == 10 || b == 13)) {
                continue
            }
            return "${what}不能含控制字符（换行/制表等）"
        }
    }
    return ""
}

/* 整条公告的校验（空字符串 = 通过）。 */
public func noticeValidate(n: Notice): String {
    let titleErr = noticeCheckText(n.title, "公告标题", NOTICE_TITLE_MAX_CHARS, false)
    if (titleErr.size > 0) {
        return titleErr
    }
    let catErr = noticeCheckText(n.category, "公告分类", NOTICE_CATEGORY_MAX_CHARS, false)
    if (catErr.size > 0) {
        return catErr
    }
    return noticeCheckText(n.body, "公告正文", NOTICE_BODY_MAX_CHARS, true)
}

/* 把调用方给的 limit 夹到 [1, NOTICE_LIST_MAX_LIMIT]；<=0 视为默认值。 */
public func noticeClampLimit(limit: Int64): Int64 {
    if (limit <= 0) {
        return NOTICE_LIST_DEFAULT_LIMIT
    }
    if (limit > NOTICE_LIST_MAX_LIMIT) {
        return NOTICE_LIST_MAX_LIMIT
    }
    return limit
}

/* ===================== 仓储 ===================== */

public class NoticeRepo {
    private let db: DbBackend

    public init(db: DbBackend) {
        this.db = db
    }

    /*
     * 行 → 模型。列的**下标**全部走命名常量，并在开头校验列数。
     *
     * ★ 这条护栏是**可执行的纪律**：`NOTICE_COLUMNS` 与映射一旦不同步
     *   （改列忘改下标、或改下标忘改列），这里当场抛异常并把两个数字打出来，
     *   而不是让相邻列的值悄悄串到别的字段上。
     */
    private func noticeFromRow(rs: DbResultSet, i: Int64): Notice {
        match (rs.row(i)) {
            case Some(row) =>
                if (row.size != NOTICE_COLUMN_COUNT) {
                    throw Exception("notice 结果集列数 ${row.size} ≠ 映射 ${NOTICE_COLUMN_COUNT}：" +
                                    "请检查 NOTICE_COLUMNS 与 noticeFromRow / NOTICE_COL_* 是否一致")
                }
            case None => throw Exception("notice 结果集缺第 ${i} 行")
        }
        let n = Notice()
        n.id = rs.getInt(i, NOTICE_COL_ID)
        n.title = rs.getString(i, NOTICE_COL_TITLE)
        n.body = rs.getString(i, NOTICE_COL_BODY)
        n.category = rs.getString(i, NOTICE_COL_CATEGORY)
        n.sort = rs.getInt(i, NOTICE_COL_SORT)
        n.enabled = rs.getInt(i, NOTICE_COL_ENABLED) != 0
        n.publishedAt = rs.getInt(i, NOTICE_COL_PUBLISHED_AT)
        n.updatedBy = rs.getInt(i, NOTICE_COL_UPDATED_BY)
        n.createdAt = rs.getInt(i, NOTICE_COL_CREATED_AT)
        n.updatedAt = rs.getInt(i, NOTICE_COL_UPDATED_AT)
        return n
    }

    /*
     * 患者侧列表：**只看得到"已启用且已到发布时刻"的公告**。
     *
     * ⚠ 两个条件缺一不可：
     *   · `enabled = 1` —— 停用的公告不该出现（同 kb_doc 的软删纪律）；
     *   · `published_at <= now` —— 预排期的公告到点才出现；
     *     只判 enabled 会让"提前写好的公告"立刻曝光。
     * ⚠ 排序 `sort ASC, published_at DESC, id DESC`：`sort` 是人工权重（置顶用），
     *   同权重时新的在前；`id DESC` 兜住"同一秒发布的两条"，
     *   让**同一请求的返回顺序稳定**（不稳定排序会让客户端列表跳动）。
     */
    public func listVisible(now: Int64, limit: Int64): Array<Notice> {
        let lim = noticeClampLimit(limit)
        let rs = db.query("SELECT " + NOTICE_COLUMNS + " FROM notice " +
                          "WHERE enabled = 1 AND published_at <= ? " +
                          "ORDER BY sort ASC, published_at DESC, id DESC LIMIT ?",
                          [DbInt(now), DbInt(lim)])
        let out = ArrayList<Notice>()
        var i: Int64 = 0
        while (i < rs.rowCount()) {
            out.add(noticeFromRow(rs, i))
            i = i + 1
        }
        return out.toArray()
    }

    /* 管理侧列表：默认**含**停用与未到点的（管理员要看全量才能维护）。 */
    public func listAll(includeDisabled!: Bool = true, limit!: Int64 = NOTICE_LIST_MAX_LIMIT): Array<Notice> {
        var sql = "SELECT " + NOTICE_COLUMNS + " FROM notice"
        if (!includeDisabled) {
            sql = sql + " WHERE enabled = 1"
        }
        sql = sql + " ORDER BY sort ASC, published_at DESC, id DESC LIMIT ?"
        let rs = db.query(sql, [DbInt(noticeClampLimit(limit))])
        let out = ArrayList<Notice>()
        var i: Int64 = 0
        while (i < rs.rowCount()) {
            out.add(noticeFromRow(rs, i))
            i = i + 1
        }
        return out.toArray()
    }

    public func findById(id: Int64): ?Notice {
        let rs = db.query("SELECT " + NOTICE_COLUMNS + " FROM notice WHERE id = ?", [DbInt(id)])
        if (rs.rowCount() == 0) {
            return None
        }
        return noticeFromRow(rs, 0)
    }

    /*
     * 建公告。
     *
     * ⚠ 直接 INSERT、**不先查**：先查后插在并发下会两个都通过检查，
     *   然后一个撞唯一键 (`uk_notice_title`) —— 那时再报"重复"就晚了（已抛异常）。
     *   靠数据库唯一键兜底，再由 `baseClassifyDuplicate` 把冲突转成 `duplicate`。
     *   （与 `DepartmentRepo.create` 一字不差的理由。）
     */
    public func create(n: Notice, now: Int64): BaseWriteOutcome {
        let out = BaseWriteOutcome()
        let err = noticeValidate(n)
        if (err.size > 0) {
            return out.markInvalid(err)
        }
        let ins = baseExecTolerant(db,
            "INSERT INTO notice (title, body, category, sort, enabled, published_at, " +
            "updated_by, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [DbStr(n.title.trimAscii()), DbStr(n.body), DbStr(n.category.trimAscii()),
             DbInt(n.sort), DbInt(if (n.enabled) { 1 } else { 0 }), DbInt(n.publishedAt),
             DbInt(n.updatedBy), DbInt(now), DbInt(now)], returnInsertId: true)
        if (!ins.ok) {
            return baseClassifyDuplicate(ins.message, out)
        }
        return out.markOk(ins.generatedId)
    }

    /*
     * 改公告。
     *
     * ⚠ **不动 `created_at`**（它是"什么时候建的"，改它等于篡改历史）；
     *   `updated_at` 由调用方传进来刷新（仓储不自己取时间 ——
     *   全仓的时间来源是 `hNowEpoch()`，测试里要能喂固定值）。
     * ⚠ `published_at` 允许改成未来（那正是"预排期"），不校验"不能晚于现在"。
     */
    public func update(id: Int64, n: Notice): BaseWriteOutcome {
        let out = BaseWriteOutcome()
        match (findById(id)) {
            case None => out.notFound = true; return out
            case Some(_) => ()
        }
        let err = noticeValidate(n)
        if (err.size > 0) {
            return out.markInvalid(err)
        }
        let up = baseExecTolerant(db,
            "UPDATE notice SET title = ?, body = ?, category = ?, sort = ?, enabled = ?, " +
            "published_at = ?, updated_by = ?, updated_at = ? WHERE id = ?",
            [DbStr(n.title.trimAscii()), DbStr(n.body), DbStr(n.category.trimAscii()),
             DbInt(n.sort), DbInt(if (n.enabled) { 1 } else { 0 }), DbInt(n.publishedAt),
             DbInt(n.updatedBy), DbInt(n.updatedAt), DbInt(id)])
        if (!up.ok) {
            return baseClassifyDuplicate(up.message, out)
        }
        return out.markOk(id)
    }

    /*
     * 删公告：**硬删**。
     *
     * ⚠ 与 `DepartmentRepo.remove` 不同（那边要查引用、且可软删），因为公告
     *   **没有任何引用者**（不被排班/挂号/病历指向）⇒ 硬删不会留悬挂引用。
     *   要"下架但留痕"就改 `enabled = false`（那才是软删的语义）——
     *   两个动作语义不同，所以**都给**，而不是只留一个让人猜。
     */
    public func remove(id: Int64): BaseWriteOutcome {
        let out = BaseWriteOutcome()
        match (findById(id)) {
            case None => out.notFound = true; return out
            case Some(_) => ()
        }
        let del = baseExecTolerant(db, "DELETE FROM notice WHERE id = ?", [DbInt(id)])
        if (!del.ok) {
            out.detail = del.message
            return out
        }
        return out.markOk(id)
    }
}
