package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * ===== acceptance_notice.cj —— AC-NOTICE-1…3：公告域 =====
 *
 * 这三个用例守的是 `notice` 表上**两条容易写错、且错了也看不出来**的规则：
 *
 *   ① **同名公告必须被拒**（`uk_notice_title`）。
 *      公告的"真相"是给人看的：同一个通知发两条，患者端会看到两条措辞不同、
 *      甚至互相矛盾的说法（"门诊 8 点开诊" / "门诊 9 点开诊"），
 *      而事后**无法用代码判断哪条对**。所以约束由数据库兜底。
 *
 *   ② **对患者可见 = `enabled = 1` 且 `published_at <= now`**，两个条件缺一不可。
 *      这是本仓唯一"可见性由两个字段共同决定"的域（科室/医生只有 enabled）：
 *        · 漏判 `enabled` ⇒ 下架的公告还在首页挂着；
 *        · 漏判 `published_at` ⇒ **提前写好的公告立刻曝光**（预排期形同虚设，
 *          而这类事故是"对外发布了还没定稿的内容"，不可撤回）。
 *      两个方向都要有断言，且**边界值**（恰好等于 now）必须钉住 ——
 *      `<=` 写成 `<` 只会让"准点发布"晚一秒，肉眼永远看不出来。
 *
 * 用例设计倾向与 `acceptance_base.cj` 一致：**多数断言是"拒绝/不可见"而不是"成功"**，
 * 因为 CRUD 的"能建能改"几乎不可能写错，而"该挡住没挡住"才是真会出事的地方。
 *
 * 夹具纪律：只清、只认自己造的公告（标题前缀 `ACNOTICE`），与别的用例零共享。
 */

import std.collection.*

/* 本用例的夹具前缀。用**纯 ASCII**：既能直接 `startsWith` 比较，也避免字节/字符下标之争。 */
let AC_NOTICE_PREFIX: String = "ACNOTICE"

/* 造一条公告（字段显式给全，避免"忘了设 published_at 导致默认 0"这类隐形前置）。 */
func acNoticeMake(title: String, body: String, category: String, sort: Int64,
                   enabled: Bool, publishedAt: Int64, now: Int64): Notice {
    let n = Notice()
    n.title = title
    n.body = body
    n.category = category
    n.sort = sort
    n.enabled = enabled
    n.publishedAt = publishedAt
    n.updatedBy = 0
    n.createdAt = now
    n.updatedAt = now
    return n
}

/* 只把自己造的公告挑出来（顺序保留 —— 排序断言要的就是顺序）。 */
func acNoticeMine(list: Array<Notice>): Array<Notice> {
    let out = ArrayList<Notice>()
    for (n in list) {
        if (n.title.startsWith(AC_NOTICE_PREFIX)) {
            out.add(n)
        }
    }
    return out.toArray()
}

func acNoticeClean(db: DbBackend): Unit {
    db.exec("DELETE FROM notice WHERE title LIKE 'ACNOTICE%'", Array<DbValue>())
}

/* ===================== AC-NOTICE-1：能建能读，且同名必须被拒 ===================== */

public func acNotice1(runner: TestRunner, db: DbBackend): Unit {
    println("=== AC-NOTICE-1 ★★ 公告：能建能改，且**同名必须被拒** ===")
    let repo = NoticeRepo(db)
    let now = hNowEpoch()
    acNoticeClean(db)

    /* ① 建 + 回读逐字段一致。 */
    let n = acNoticeMake("ACNOTICE-门诊调整", "自 10 月 12 日起门诊 8 点开诊。", "就诊提醒",
                         10, true, now - 60, now)
    let c1 = repo.create(n, now)
    runner.check("① 建公告成功", c1.ok)
    runner.check("① 且回传了自增 id（${c1.id}）", c1.id > 0)
    match (repo.findById(c1.id)) {
        case Some(saved) =>
            runner.check("① 回读字段一致（标题/正文/分类/排序/发布时刻）",
                         saved.title == "ACNOTICE-门诊调整" &&
                         saved.body == "自 10 月 12 日起门诊 8 点开诊。" &&
                         saved.category == "就诊提醒" && saved.sort == 10 &&
                         saved.publishedAt == now - 60)
            runner.check("① 新建默认启用（enabled = true）", saved.enabled)
            /*
             * ★ 时间戳是"历史"，由仓储统一落 now：
             *   若哪天有人把 created_at 改成"读库时间"或漏写，这条会立刻红。
             */
            runner.check("★★ ① created_at / updated_at 都落在传入的 now（仓储不自己取时间）",
                         saved.createdAt == now && saved.updatedAt == now)
        case None => runner.check("① 回读公告（不该找不到）", false)
    }

    /* ② ★★ 同名必须被拒，且**说清是 title 冲突**、且**库里确实只有 1 行**。 */
    let dup = acNoticeMake("ACNOTICE-门诊调整", "另一份说法：9 点开诊。", "通知",
                           0, true, now, now)
    let rdup = repo.create(dup, now)
    runner.check("★★ ② 同名公告被拒（duplicate）", rdup.duplicate)
    runner.check("★★ ② 且指出冲突字段是 title（不是笼统报错）", rdup.conflictField == "title")
    runner.check("★★ ② 且确实没进库（同名仍只有 1 行 —— 否则患者会看到两条矛盾公告）",
                 hScalarCount(db, "SELECT COUNT(*) FROM notice WHERE id = ${c1.id}") == 1)

    /* ③ 改名成功，且 **`created_at` 不被篡改**。 */
    match (repo.findById(c1.id)) {
        case Some(saved) =>
            let before = saved.createdAt
            let edit = acNoticeMake("ACNOTICE-门诊调整（改名后）", saved.body, saved.category,
                                    saved.sort, saved.enabled, saved.publishedAt, now)
            edit.updatedBy = 7
            let u = repo.update(c1.id, edit)
            runner.check("③ 改公告成功", u.ok)
            match (repo.findById(c1.id)) {
                case Some(after) =>
                    runner.check("③ 字段已更新（标题/更新人）",
                                 after.title == "ACNOTICE-门诊调整（改名后）" && after.updatedBy == 7)
                    runner.check("★★ ③ created_at **未被篡改**（它是历史，不该随编辑变）",
                                 after.createdAt == before)
                case None => runner.check("③ 改后回读", false)
            }
        case None => runner.check("③ 改公告（前置失败）", false)
    }

    /* ④ 参数校验：标题/分类**不许换行**，正文**允许换行**（公告常有多段）。 */
    runner.check("④ 空白标题被拒",
                 repo.create(acNoticeMake("   ", "x", "通知", 0, true, now, now), now).invalid)
    runner.check("④ 标题超 ${NOTICE_TITLE_MAX_CHARS} 字被拒（按**字符**不是字节）",
                 repo.create(acNoticeMake("ACNOTICE-" + hRepeatChar("长", NOTICE_TITLE_MAX_CHARS),
                                          "x", "通知", 0, true, now, now), now).invalid)
    runner.check("★ ④ 标题含换行被拒（换行会破坏列表排版与日志的单行假设）",
                 repo.create(acNoticeMake("ACNOTICE-换\n行", "x", "通知", 0, true, now, now),
                             now).invalid)
    runner.check("★ ④ 分类含制表符被拒",
                 repo.create(acNoticeMake("ACNOTICE-制表", "x", "通知\t类", 0, true, now, now),
                             now).invalid)
    runner.check("④ 正文超 ${NOTICE_BODY_MAX_CHARS} 字被拒（首页不能被一条巨型公告拖慢）",
                 repo.create(acNoticeMake("ACNOTICE-超长正文", hRepeatChar("长", NOTICE_BODY_MAX_CHARS + 1),
                                          "通知", 0, true, now, now), now).invalid)
    let multi = repo.create(acNoticeMake("ACNOTICE-多段正文", "第一段。\n第二段。", "健康提示",
                                         0, true, now, now), now)
    runner.check("★ ④ 正文含换行**被接受**（与标题相反 —— 多段是正常写法）", multi.ok)

    /* ⑤ 改/删不存在的 ⇒ notFound（而不是静默成功）。 */
    runner.check("⑤ 改不存在的公告 ⇒ notFound",
                 repo.update(99999999, acNoticeMake("ACNOTICE-不存在", "x", "通知", 0, true, now, now)).notFound)
    runner.check("⑤ 删不存在的公告 ⇒ notFound",
                 repo.remove(99999999).notFound)

    acNoticeClean(db)
}

/* ===================== AC-NOTICE-2：对患者的可见性（两条件 + 边界） ===================== */

public func acNotice2(runner: TestRunner, db: DbBackend): Unit {
    println("=== AC-NOTICE-2 ★★ 患者可见性：enabled 与 published_at **两个条件缺一不可** ===")
    let repo = NoticeRepo(db)
    let now = hNowEpoch()
    acNoticeClean(db)

    /* ① 正常可见（已启用 + 已到发布时刻）。 */
    let live = acNoticeMake("ACNOTICE-可见", "已发布。", "通知", 1, true, now - 10, now)
    let rl = repo.create(live, now)
    runner.check("① 前置：建一条已发布的公告", rl.ok)

    /* ② 停用 ⇒ 不可见；但**行还在**（是"下架"不是"删除"）。 */
    let off = acNoticeMake("ACNOTICE-已停用", "下架了。", "通知", 2, false, now - 10, now)
    let ro = repo.create(off, now)
    runner.check("① 前置：建一条**已停用**的公告", ro.ok)

    /* ③ 预排期（未来）⇒ 不可见。 */
    let future = acNoticeMake("ACNOTICE-预排期", "还没到点。", "通知", 3, true, now + 3600, now)
    let rf = repo.create(future, now)
    runner.check("① 前置：建一条**未来**才发布的公告", rf.ok)

    /* ④ 边界：恰好等于 now ⇒ **必须可见**（`<=` 不是 `<`）。 */
    let edge = acNoticeMake("ACNOTICE-准点", "整点发布。", "通知", 4, true, now, now)
    let re = repo.create(edge, now)
    runner.check("① 前置：建一条 `published_at == now` 的公告", re.ok)

    let visible = acNoticeMine(repo.listVisible(now, 100))
    /*
     * 期望 **2** 条：`ACNOTICE-可见` 与 `ACNOTICE-准点`。
     *   · 已停用的被 `enabled = 1` 挡掉；
     *   · 预排期的被 `published_at <= now` 挡掉。
     * ⚠ 这条"总数"断言是**下一条反向证明的对照**：若哪天有人把两个条件之一删了，
     *   总数会变成 3 或 4，先在这里红，而不是等患者端首页多挂一条公告。
     */
    runner.check("★ ② 患者侧恰好看到 2 条（已发布 + 准点；停用与预排期都被挡）", visible.size == 2)

    var sawLive = false
    var sawOff = false
    var sawFuture = false
    var sawEdge = false
    for (n in visible) {
        if (n.title == "ACNOTICE-可见") { sawLive = true }
        if (n.title == "ACNOTICE-已停用") { sawOff = true }
        if (n.title == "ACNOTICE-预排期") { sawFuture = true }
        if (n.title == "ACNOTICE-准点") { sawEdge = true }
    }
    runner.check("② 已发布的在列表里", sawLive)
    runner.check("★★ ② **已停用**的不在患者列表里（否则下架的公告还挂在首页）", !sawOff)
    runner.check("★★ ② **未来的**不在患者列表里（否则预排期形同虚设、内容提前曝光）", !sawFuture)
    runner.check("★★ ② 边界：`published_at == now` **可见**（`<=` 写成 `<` 会让准点发布晚一拍）", sawEdge)

    /*
     * ★★ 反向证明：停用/预排期是**隐藏**而不是**删除**。
     *   只断言"看不见"会让"其实被删了"也通过（假绿）——
     *   管理员还得能查到它们才能改回来。
     */
    match (repo.findById(ro.id)) {
        case Some(saved) => runner.check("★★ ② 停用的公告**仍在库里**且 enabled = false（是下架不是删除）",
                                         !saved.enabled)
        case None => runner.check("② 停用的公告应仍能被管理员查到", false)
    }
    match (repo.findById(rf.id)) {
        case Some(saved) => runner.check("★★ ② 预排期的公告**仍在库里**且发布时间未变（到点自动出现）",
                                         saved.publishedAt == now + 3600 && saved.enabled)
        case None => runner.check("② 预排期的公告应仍在库里", false)
    }
    let all = repo.listAll()
    runner.check("② 管理侧 listAll 默认**含**停用与预排期（管理员要能维护全量）",
                 acNoticeMine(all).size == 4)
    runner.check("② 管理侧 listAll(includeDisabled=false) 过滤掉停用的",
                 acNoticeMine(repo.listAll(includeDisabled: false)).size == 3)

    /* ⑤ 排序：`sort` 小的在前；同 sort 时**新的在前**（首页置顶用）。 */
    acNoticeClean(db)
    let sa = acNoticeMake("ACNOTICE-排序A", "x", "通知", 1, true, now - 300, now)
    let sb = acNoticeMake("ACNOTICE-排序B", "x", "通知", 5, true, now - 300, now)
    let sc = acNoticeMake("ACNOTICE-排序C", "x", "通知", 5, true, now - 100, now)
    runner.check("① 前置：造 3 条用于排序", repo.create(sa, now).ok &&
                 repo.create(sb, now).ok && repo.create(sc, now).ok)
    let ordered = acNoticeMine(repo.listVisible(now, 100))
    /* 期望：A（sort 1）→ C（sort 5、更新）→ B（sort 5、更旧）。 */
    let expect = "ACNOTICE-排序A|ACNOTICE-排序C|ACNOTICE-排序B"
    var actual = ""
    for (n in ordered) {
        if (actual.size > 0) { actual = actual + "|" }
        actual = actual + n.title
    }
    runner.check("★★ ⑤ 顺序 = sort 升序，同权重时新的在前（实得 ${actual}）", actual == expect)

    acNoticeClean(db)
}

/* ===================== AC-NOTICE-3：limit 夹取 与 硬删 ===================== */

public func acNotice3(runner: TestRunner, db: DbBackend): Unit {
    println("=== AC-NOTICE-3 ★ limit 夹取（防一次拉全表）与硬删语义 ===")
    let repo = NoticeRepo(db)
    let now = hNowEpoch()
    acNoticeClean(db)

    /*
     * ① limit 夹取规则本身（纯函数，先钉住口径）：
     *   <=0 ⇒ 默认 20；>200 ⇒ 200；其余原样。
     *   ⚠ 这条断言的意义：`limit` 是**外部输入**，没有夹取就能被用来拉全表。
     */
    runner.check("① limit <= 0 ⇒ 默认 ${NOTICE_LIST_DEFAULT_LIMIT}",
                 noticeClampLimit(0) == NOTICE_LIST_DEFAULT_LIMIT &&
                 noticeClampLimit(-3) == NOTICE_LIST_DEFAULT_LIMIT)
    runner.check("① limit 超上限 ⇒ 夹到 ${NOTICE_LIST_MAX_LIMIT}",
                 noticeClampLimit(NOTICE_LIST_MAX_LIMIT + 1) == NOTICE_LIST_MAX_LIMIT &&
                 noticeClampLimit(999999) == NOTICE_LIST_MAX_LIMIT)
    runner.check("① limit 正常值原样保留", noticeClampLimit(5) == 5)

    /* ② 造 5 条，验证 limit 真的截断（而不是"夹了参数但查询没带 LIMIT"）。 */
    var i: Int64 = 1
    var allOk = true
    while (i <= 5) {
        let made = repo.create(acNoticeMake("ACNOTICE-批${i}", "x", "通知", i, true, now - 100, now), now)
        if (!made.ok) { allOk = false }
        i = i + 1
    }
    runner.check("① 前置：造 5 条公告", allOk)
    runner.check("★ ② limit=2 时恰好回 2 条（截断真的生效）",
                 acNoticeMine(repo.listVisible(now, 2)).size == 2)
    runner.check("② limit=999999 时被夹到 200（不会因参数而多回）",
                 acNoticeMine(repo.listVisible(now, 999999)).size == 5)

    /* ③ 硬删：删掉后查不到、列表不含、且**同名可以被重新建**（唯一键释放）。 */
    let first = acNoticeMine(repo.listVisible(now, 1))[0]
    let del = repo.remove(first.id)
    runner.check("③ 删公告成功", del.ok)
    runner.check("③ 删除后回传的 id 就是被删的那条", del.id == first.id)
    match (repo.findById(first.id)) {
        case Some(_) => runner.check("★ ③ 删除后 findById 应为空", false)
        case None => runner.check("★ ③ 删除后 findById 为空", true)
    }
    var stillThere = false
    for (n in repo.listVisible(now, 100)) {
        if (n.id == first.id) { stillThere = true }
    }
    runner.check("③ 删除后不再出现在列表里", !stillThere)
    runner.check("★ ③ 同一个 id 再删 ⇒ notFound（不静默当成功）", repo.remove(first.id).notFound)
    runner.check("★★ ③ 删掉后**同名可以重建**（唯一键已释放，否则这个名字永久不可用）",
                 repo.create(acNoticeMake(first.title, "重建。", "通知", 6, true, now, now), now).ok)

    acNoticeClean(db)
}
