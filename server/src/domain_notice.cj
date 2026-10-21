package qingzhou

import std.collection.*

/*
 * 公告域：`notice` 表仓储（domain_*.cj 独占 SQL，http_notice.cj 只管展示与格式化）。
 * 对外：Notice / NoticeRepo：listVisible / listAll / findById / create / update / remove。
 * 约束：时间一律 epoch 秒；患者侧必须 enabled=1 且 published_at<=now，缺一则预排期公告提前曝光。
 * 约束：列清单只写一处（NOTICE_COLUMNS + 命名下标），noticeFromRow 校验列数，错位不会抛错。
 */

/* 常量 */

/* 长度上限按字符计（previsitCharLen），不按字节：列宽是 128 字，不是 128 字节。 */
public let NOTICE_TITLE_MAX_CHARS: Int64 = 128
public let NOTICE_CATEGORY_MAX_CHARS: Int64 = 32
/* 正文上限 2000 字：公告是给人看的一段话，不是知识库文档（KB_BODY_MAX_CHARS=20000）。 */
public let NOTICE_BODY_MAX_CHARS: Int64 = 2000

/* 患者侧列表默认/最大条数（首页只要最近几条；给上限防"一次拉全表"）。 */
public let NOTICE_LIST_DEFAULT_LIMIT: Int64 = 20
public let NOTICE_LIST_MAX_LIMIT: Int64 = 200

/*
 * 列清单只写一处，下标常量一一对应；`noticeFromRow` 有列数护栏，不一致当场抛（错位不报错，最难查）。
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

/* 模型 */

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

/* ===== 校验 ===== */

/*
 * 通用文本校验：非空、按字符限长、拒控制字符；`allowNewline` 只对正文开。
 * 不复用 `baseValidateName`（上限 64），否则提示与列宽不符。
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

/* 仓储 */

public class NoticeRepo {
    private let db: DbBackend

    public init(db: DbBackend) {
        this.db = db
    }

    /* 行 → 模型：下标全走命名常量；列数不符当场抛，防止相邻列串值。 */
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
     * 患者侧列表：`enabled = 1 AND published_at <= ?`，缺一不可。
     * 排序 sort ASC, published_at DESC, id DESC：id 兜住同秒发布，保证返回顺序稳定。
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
     * 建公告：直接 INSERT、不先查 —— 先查后插并发下会双双通过检查，
     * 靠唯一键 uk_notice_title 兜底，再由 `baseClassifyDuplicate` 转成 duplicate。
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
     * 改公告：不动 `created_at`；`updated_at` 由调用方传入（时间源 hNowEpoch()，测试可喂固定值）。
     * `published_at` 允许改成未来（预排期），不校验"不能晚于现在"。
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
     * 删公告：硬删。公告无引用者（不被排班/挂号/病历指向），不会留悬挂引用；
     * 要"下架留痕"改 `enabled = false`，两种语义不同，都保留。
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
