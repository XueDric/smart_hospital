/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 *
 * ===== acceptance_triage.cj —— P2 分诊的**验收测试（需要库）**==============
 *
 * 为什么单独一个文件（而不是塞进 acceptance.cj）：
 *   `acceptance.cj` 已经 730+ 行、覆盖 AC-1…AC-12 的号源域不变量。
 *   分诊是**另一个域**（它读 schedule 但从不写），混进去会让那个文件既长又难定位。
 *   本文件的用例仍复用 `TestRunner` 与 `hResetAll` / `hSeedSchedule`，
 *   所以 runner 的 `passed/failed` 计数与既有 AC 一致（doc-counts 对账不受影响）。
 *
 * ★★ 本文件的核心是 **AC-P2-2：绝不给"没有号"的推荐**。
 *    这是 brief 创新点②（先取证后结论）在分诊上的落点，也是**唯一**能让
 *    "AI 分诊"变成医疗事故的地方：患者拿着推荐去挂号，发现没号 ——
 *    比不给推荐更坏（他可能因此耽误就诊）。
 *
 * 测试隔离纪律（照 hSeedSchedule 的做法）：
 *   每个用例先 `hResetAll`（清业务表）再自建科室/医生/排班，
 *   所以用例之间**无顺序依赖**、可单独重跑。
 *   ⚠ 排班 id 用 **9100+** 段，与 acceptance.cj 的 9001/9002 段错开，
 *     避免两个文件在同一库上互相踩（history：P0 就因为共用固定 id 踩过）。
 */

package qingzhou

/*
 * 建一个"分诊用"的科室 + 医生 + 排班（id 显式，便于用例可读）。
 *
 * ⚠ 与 `hSeedSchedule` 分开而不是复用：后者的 department 名硬编码为"内科"、
 *   医生固定 id=1，而分诊用例**必须**造多个科室（否则测不出"推荐了没号的科室"）。
 *   共用会逼着后者加一堆可选参数，反而更难读。
 */
func hSeedTriageDept(db: DbBackend, deptId: Int64, deptName: String,
                     doctorId: Int64, doctorName: String, doctorSpecialty: String,
                     scheduleId: Int64, total: Int64, workDate: String,
                     enabled!: Bool = true): Unit {
    let now = hNowEpoch()
    db.exec("INSERT INTO department (id, name, code, created_at) VALUES (?, ?, ?, ?)",
            [DbInt(deptId), DbStr(deptName), DbStr("T${deptId}"), DbInt(now)])
    db.exec("INSERT INTO doctor (id, name, department_id, title, specialty, created_at) " +
            "VALUES (?, ?, ?, ?, ?, ?)",
            [DbInt(doctorId), DbStr(doctorName), DbInt(deptId), DbStr("主任医师"),
             DbStr(doctorSpecialty), DbInt(now)])
    let en = if (enabled) { 1 } else { 0 }
    db.exec("INSERT INTO schedule (id, doctor_id, department_id, work_date, period, " +
            "total_num, remain_num, version, enabled, created_at) " +
            "VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?)",
            [DbInt(scheduleId), DbInt(doctorId), DbInt(deptId), DbStr(workDate), DbStr("AM"),
             DbInt(total), DbInt(total), DbInt(en), DbInt(now)])
}

/*
 * 只建科室 + 医生，**不建排班**（用于"该科室当前没有可挂号源"的用例）。
 */
func hSeedTriageDeptNoSlot(db: DbBackend, deptId: Int64, deptName: String,
                           doctorId: Int64, doctorName: String): Unit {
    let now = hNowEpoch()
    db.exec("INSERT INTO department (id, name, code, created_at) VALUES (?, ?, ?, ?)",
            [DbInt(deptId), DbStr(deptName), DbStr("T${deptId}"), DbInt(now)])
    db.exec("INSERT INTO doctor (id, name, department_id, title, specialty, created_at) " +
            "VALUES (?, ?, ?, ?, ?, ?)",
            [DbInt(doctorId), DbStr(doctorName), DbInt(deptId), DbStr("主任医师"),
             DbStr(""), DbInt(now)])
}

/*
 * ★★ 把"结论里**每一个** option 都真的有号"这条不变量做成**可复用的断言**。
 *
 * 为什么必须写成函数而不是在每个用例里重复：这条不变量是**贯穿所有用例**的
 * 底线（brief 创新点②）。写在用例里会让"新加一个用例忘了断言"成为可能；
 * 抽成函数后，每个用例只需一行，漏掉的概率大降。
 *
 * 断言的内容（三条，缺一条都不足以证明）：
 *   ① option 里的 schedule_id **在库里存在**；
 *   ② 它的 `remain_num > 0`（**这是最关键的一条**）；
 *   ③ 它是 enabled 的。
 */
extend TestRunner {
    /*
     * ★★ 把"结论里**每一个** option 都真的有号"这条不变量做成**可复用断言**。
     *
     * 为什么必须抽成函数而不是在每个用例里重复：这条不变量是**贯穿所有用例**的
     * 底线（brief 创新点②）。写在用例里会让"新加用例忘了断言"成为可能；
     * 抽出来后每个用例只需一行，漏掉的概率大降。
     *
     * 断言三条（缺一条都不足以证明"可挂号"）：
     *   ① option 的 schedule_id **在库里存在**；
     *   ② `remain_num > 0`（★ 最关键）；
     *   ③ `enabled = 1`。
     *
     * ⚠ 为什么是"`TestRunner` 的扩展成员 + 显式传 `db`"这个组合（试错记录）：
     *   · 写成**自由函数**（把 `db`/`check` 当全局用）⇒ 编译不过（都不在作用域）；
     *   · 写成**扩展成员且不传 db** ⇒ 也编译不过：`TestRunner.db` 是 **`private let`**，
     *     而**扩展成员拿不到原类的 private 成员**（实测 `undeclared identifier 'db'`）。
     *   ⇒ 结论：断言用 `check`（public，计数自动并入总账），
     *     而查库用的 `db` **显式当参数传进来**。这样两边都成立且没有可见性妥协。
     */
    public func assertAllOptionsBookable(db: DbBackend, v: TriageVerdict, tag: String): Unit {
        if (v.options.size == 0) {
            // 没有 option 时，reasonCode 必须是"确实给不出推荐"的那几个之一 ——
            // 否则就是"静默什么都没给"，患者不知道发生了什么
            // ⚠ 不跨行写 `||`（仓颉会报 possibly confusing line terminator）—— 拆成多个布尔量
            let noRec1 = (v.reasonCode == TR_NO_BOOKABLE)
            let noRec2 = (v.reasonCode == TR_NO_SUCH_DEPT)
            let noRec3 = (v.reasonCode == TR_NEED_CLARIFY)
            let noRec4 = (v.reasonCode == TR_NO_COMPLAINT)
            let noRec = (noRec1 || noRec2 || noRec3 || noRec4)
            check("${tag}：无推荐时 reason_code 表明'给不出'（实得 ${v.reasonCode}）", noRec)
            return
        }
        var allOk = true
        var bad: Int64 = 0
        for (o in v.options) {
            let rs = db.query(
                "SELECT remain_num, enabled FROM schedule WHERE id = ?", [DbInt(o.scheduleId)])
            if (rs.rowCount() < 1) {
                allOk = false
                bad = bad + 1
            } else if (rs.getInt(0, 0) <= 0) {
                allOk = false
                bad = bad + 1
            } else if (rs.getInt(0, 1) == 0) {
                allOk = false
                bad = bad + 1
            }
        }
        // 把"不合格几个"放进断言名 —— 失败时立刻能看出是哪个环节
        check("★★ ${tag}：${v.options.size} 个推荐全部真的可挂号（不合格 ${bad} 个）", allOk)
    }
}

/* ===================== 用例 ===================== */

/*
 * AC-P2-1 危急征象兜底：命中即转急诊，**不给任何科室推荐**
 *
 * ★ 这条是"保险丝优先于一切"的验收：危急时做分诊本身就是错的
 *   （患者该去急诊，而不是去门诊排队）。
 *   断言要**同时**检查两件事：redFlag=true **且** options 为空 ——
 *   只检查前者不够：如果实现变成"既报红牌又推荐科室"，
 *   患者可能选后者，保险丝就失效了。
 */
public func acP2_1(runner: TestRunner, db: DbBackend): Unit {
    println("=== AC-P2-1 危急征象兜底（命中即转急诊，不给推荐）===")
    runner.section("AC-P2-1", { =>
        hResetAll(db)
        // 故意建一个**有号**的科室：如果实现错误地继续分诊，就会推荐它
        hSeedTriageDept(db, 9101, "内科", 9101, "张医生", "内科", 9101, 10, "2026-12-01")
        let repo = TriageRepo(db)
        let v = triageComplaint(repo, "我父亲胸痛，出汗，已经半小时了", "2026-11-01")
        runner.check("red_flag = true", v.redFlag)
        runner.check("reason_code = RED_FLAG（实得 ${v.reasonCode}）", v.reasonCode == TR_RED_FLAG)
        runner.check("★★ 危急时**不给任何**科室推荐（options 为空）", v.options.size == 0)
        runner.check("依据非空（进了审计素材）", v.redFlagEvidence.size > 0)
        runner.check("给患者的说明非空（兜底不得为空）", v.patientNote.size > 0)
        // 反向：非危急主诉**不应**被保险丝拦掉
        let v2 = triageComplaint(repo, "咳嗽三天", "2026-11-01")
        runner.check("非危急主诉不被误判为红牌", !v2.redFlag)
    })
}

/*
 * AC-P2-2 ★★ 核心：**绝不给"没有号"的推荐**
 *
 * 三种工况全覆盖（这是本用例的价值所在）：
 *   ① 科室有号          → OK，且推荐的排班真的 remain_num>0
 *   ② 科室存在但**没号** → 不得推荐该科室；要么给**有号的**备选，要么明确说没有
 *   ③ 科室**不存在**     → NO_SUCH_DEPT，且不得凭规则表凭空推荐
 */
public func acP2_2(runner: TestRunner, db: DbBackend): Unit {
    println("=== AC-P2-2 ★★ 绝不给没有号的推荐（先取证后结论）===")
    runner.section("AC-P2-2", { =>
        let repo = TriageRepo(db)

        // ① 有号 → 正常推荐，且**每个** option 都有号
        hResetAll(db)
        hSeedTriageDept(db, 9111, "呼吸内科", 9111, "李医生", "呼吸", 9111, 5, "2026-12-01")
        let v1 = triageComplaint(repo, "咳嗽三天有痰", "2026-11-01")
        runner.check("① 有号时给出推荐（实得 ${v1.reasonCode}）", v1.reasonCode == TR_OK)
        runner.check("① 推荐了至少 1 个 option", v1.options.size > 0)
        runner.check("① 推荐的是呼吸内科（实得 ${if (v1.options.size > 0) { v1.options[0].departmentName } else { "无" }}）",
              v1.options.size > 0 && v1.options[0].departmentName == "呼吸内科")
        runner.assertAllOptionsBookable(db, v1, "①")

        // ② 科室存在但**没号** → 绝不推荐它
        hResetAll(db)
        hSeedTriageDeptNoSlot(db, 9121, "呼吸内科", 9121, "李医生")
        // 另建一个有号的科室（消化内科），用于检验"备选必须也是有号的"
        hSeedTriageDept(db, 9122, "消化内科", 9122, "王医生", "消化", 9122, 8, "2026-12-02")
        let v2 = triageComplaint(repo, "咳嗽三天有痰", "2026-11-01")
        runner.check("② 首选没号时不返回 OK（实得 ${v2.reasonCode}）", v2.reasonCode != TR_OK)
        var mentionsNoSlotDept = false
        for (o in v2.options) {
            if (o.departmentName == "呼吸内科") {
                mentionsNoSlotDept = true
            }
        }
        runner.check("★★ ② 绝不把'没号的科室'放进推荐（尽管规则命中了它）", !mentionsNoSlotDept)
        /*
         * ⚠ 不跨行写 `||`（仓颉报 `possibly confusing line terminator`）——
         *   拆成多个布尔量再合并。这条坑本项目记过多次，这次是我写新文件时又犯。
         */
        let alt1 = (v2.reasonCode == TR_ALTERNATIVES)
        let alt2 = (v2.reasonCode == TR_NO_BOOKABLE)
        let alt3 = (v2.reasonCode == TR_NO_SUCH_DEPT)
        runner.check("② 给出了有号的备选（ALTERNATIVES）或明确说没有", (alt1 || alt2 || alt3))
        runner.assertAllOptionsBookable(db, v2, "②")

        // ③ 科室**不存在**：规则认得出，但本院没这个科
        hResetAll(db)
        hSeedTriageDept(db, 9131, "消化内科", 9131, "王医生", "消化", 9131, 8, "2026-12-02")
        let v3 = triageComplaint(repo, "咳嗽三天有痰", "2026-11-01")
        /*
         * ⚠ 我第一版断言 `reasonCode == NO_SUCH_DEPT`，**实测是 ALTERNATIVES** ——
         *   而实现的行为其实**更好**：本院没有"呼吸内科"，但**别的科室有号**，
         *   那就该把有号的备选给患者（而不是只说一句"没这个科"就结束）。
         *   `NO_SUCH_DEPT` 只保留给"**全院都没有任何可挂号源**"那种真给不出的情况
         *   （见下面 ③b）。
         *
         *   ⇒ 断言要写成"**给出可行动的信息**"这个真实意图，而不是钉死一个码：
         *     要么明确说本院没这个科，要么给出**有号的**备选。
         *   📌 这是"测试写得比实现更严"的典型 —— 修正**测试**，不是放宽实现。
         */
        let ok3a = (v3.reasonCode == TR_NO_SUCH_DEPT)
        let ok3b = (v3.reasonCode == TR_ALTERNATIVES)
        runner.check("③ 本院没有呼吸内科 → 明确说没有 / 或给出有号备选（实得 ${v3.reasonCode}）",
                     (ok3a || ok3b))
        var mentionsMissing = false
        for (o in v3.options) {
            if (o.departmentName == "呼吸内科") {
                mentionsMissing = true
            }
        }
        runner.check("③ 不得推荐本院不存在的科室", !mentionsMissing)
        runner.assertAllOptionsBookable(db, v3, "③")
        // ③b 规则科室不存在 **且全院无号** → 这时才轮到 NO_SUCH_DEPT
        hResetAll(db)
        hSeedTriageDeptNoSlot(db, 9132, "消化内科", 9132, "王医生")
        let v3b = triageComplaint(repo, "咳嗽三天有痰", "2026-11-01")
        runner.check("③b 全院无号且规则科室不存在 → NO_SUCH_DEPT（实得 ${v3b.reasonCode}）",
                     v3b.reasonCode == TR_NO_SUCH_DEPT)
        runner.check("③b options 为空", v3b.options.size == 0)

        /*
         * ④ 全院都没号 → 宁可空手，也不给挂不上的号
         *
         * ★★ 这里刻意造的是**"排班存在但 remain_num = 0"（约满）**这种工况，
         *   而不是"没有排班行"。
         *
         *   为什么必须专门造这一种：它和"科室完全没有排班"看起来相似，
         *   但**只有它能证明 SQL 里的 `remain_num > 0` 真的在起作用**。
         *   我最初的用例造的是"没有排班行"，于是把 `remain_num > 0` 改成 `>= 0`
         *   （让约满的排班也返回）时 **92 项断言全绿、变异未被发现** ——
         *   这是真实的覆盖率缺口，靠**变异测试**才暴露出来。
         *   📌 教训：断言"没有推荐"时，要保证**诱惑源确实存在**
         *     （这里就是那张 remain_num=0 的排班），否则测试是在"空比空"。
         */
        hResetAll(db)
        hSeedTriageDept(db, 9141, "呼吸内科", 9141, "李医生", "呼吸", 9141, 0, "2026-12-01")
        let v4 = triageComplaint(repo, "咳嗽三天有痰", "2026-11-01")
        runner.check("④ 全院无号时不返回 OK", v4.reasonCode != TR_OK)
        runner.check("★★ ④ 约满(remain_num=0)的排班**不得**被推荐（守住 SQL 的 remain_num > 0）",
                     v4.options.size == 0)
        runner.check("④ 仍然给出可读说明（兜底不得为空）", v4.patientNote.size > 0)

        // ④b 变体：科室连排班行都没有（与 ④ 是两种不同的"没号"，都要覆盖）
        hResetAll(db)
        hSeedTriageDeptNoSlot(db, 9142, "呼吸内科", 9142, "李医生")
        let v4b = triageComplaint(repo, "咳嗽三天有痰", "2026-11-01")
        runner.check("④b 科室无排班行时也不返回 OK", v4b.reasonCode != TR_OK)
        runner.check("④b options 为空", v4b.options.size == 0)

        // ⑤ 规则认不出的主诉 → 不猜
        hResetAll(db)
        hSeedTriageDept(db, 9151, "内科", 9151, "张医生", "内科", 9151, 5, "2026-12-01")
        let v5 = triageComplaint(repo, "就是不太舒服", "2026-11-01")
        runner.check("⑤ 认不出时不推荐（实得 ${v5.reasonCode}）", v5.reasonCode == TR_NEED_CLARIFY)
        runner.check("⑤ options 为空", v5.options.size == 0)
        let v6 = triageComplaint(repo, "", "2026-11-01")
        runner.check("⑤ 空主诉 → NO_COMPLAINT（实得 ${v6.reasonCode}）", v6.reasonCode == TR_NO_COMPLAINT)
    })
}

/*
 * AC-P2-3 过度期的排班**不算可用**（"今天"的边界）
 *
 * 为什么单独一条：如果实现漏了 `work_date >= today`，
 * 患者会拿到一个**已经过期**的排班去挂号 —— 挂号接口会拒（挂号侧有校验），
 * 但分诊的承诺就落空了。这类"边界差一天"的缺陷最容易被漏测。
 */
public func acP2_3(runner: TestRunner, db: DbBackend): Unit {
    println("=== AC-P2-3 过期排班不算可用（日期边界）===")
    runner.section("AC-P2-3", { =>
        hResetAll(db)
        let repo = TriageRepo(db)
        // 昨天的排班（还有余额）—— 它**不该**被当成可挂号源
        hSeedTriageDept(db, 9161, "呼吸内科", 9161, "李医生", "呼吸", 9161, 5, "2026-11-09")
        let v = triageComplaint(repo, "咳嗽三天有痰", "2026-11-10")
        runner.check("★ 过期排班不被推荐（reason=${v.reasonCode}）", v.reasonCode != TR_OK)
        runner.check("过期排班不进 options", v.options.size == 0)

        // 同一天（今天）的排班**应该**可用 —— 边界必须包含"今天"
        hResetAll(db)
        hSeedTriageDept(db, 9162, "呼吸内科", 9162, "李医生", "呼吸", 9162, 5, "2026-11-10")
        let v2 = triageComplaint(repo, "咳嗽三天有痰", "2026-11-10")
        runner.check("★ 当天（=today）的排班可用（边界含今天）", v2.reasonCode == TR_OK)
        runner.assertAllOptionsBookable(db, v2, "当天")

        // 停用的排班不算可用
        hResetAll(db)
        hSeedTriageDept(db, 9163, "呼吸内科", 9163, "李医生", "呼吸", 9163, 5, "2026-11-20",
                        enabled: false)
        let v3 = triageComplaint(repo, "咳嗽三天有痰", "2026-11-10")
        runner.check("停用的排班不算可用（reason=${v3.reasonCode}）", v3.reasonCode != TR_OK)
        runner.check("停用的排班不进 options", v3.options.size == 0)
    })
}

/*
 * AC-P2-4 **多医生/多排班**时只给"最早能看的"，且号源数汇总正确
 *
 * 为什么单独测：`toOptions` 按医生归并（同一医生多个排班只留最早的）。
 * 归并逻辑写错的两个典型后果：
 *   · 同一医生出现多次（患者看到重复选项，不知道该选哪个）；
 *   · `totalRemain` 算错（患者对"号紧不紧"产生错误预期）。
 */
public func acP2_4(runner: TestRunner, db: DbBackend): Unit {
    println("=== AC-P2-4 多医生/多排班归并（按医生、保留最早）===")
    runner.section("AC-P2-4", { =>
        hResetAll(db)
        let now = hNowEpoch()
        db.exec("INSERT INTO department (id, name, code, created_at) VALUES (?, ?, ?, ?)",
                [DbInt(9171), DbStr("呼吸内科"), DbStr("T9171"), DbInt(now)])
        // 同一个医生两个排班（11-20 有 3 个号、11-15 有 2 个号）
        db.exec("INSERT INTO doctor (id, name, department_id, title, specialty, created_at) " +
                "VALUES (?, ?, ?, ?, ?, ?)",
                [DbInt(9171), DbStr("李医生"), DbInt(9171), DbStr("主任医师"),
                 DbStr("呼吸"), DbInt(now)])
        db.exec("INSERT INTO schedule (id, doctor_id, department_id, work_date, period, " +
                "total_num, remain_num, version, enabled, created_at) " +
                "VALUES (?, ?, ?, ?, ?, ?, ?, 0, 1, ?)",
                [DbInt(9171), DbInt(9171), DbInt(9171), DbStr("2026-11-20"), DbStr("AM"),
                 DbInt(3), DbInt(3), DbInt(now)])
        db.exec("INSERT INTO schedule (id, doctor_id, department_id, work_date, period, " +
                "total_num, remain_num, version, enabled, created_at) " +
                "VALUES (?, ?, ?, ?, ?, ?, ?, 0, 1, ?)",
                [DbInt(9172), DbInt(9171), DbInt(9171), DbStr("2026-11-15"), DbStr("PM"),
                 DbInt(2), DbInt(2), DbInt(now)])
        // 另一个医生，11-18 有 4 个号
        db.exec("INSERT INTO doctor (id, name, department_id, title, specialty, created_at) " +
                "VALUES (?, ?, ?, ?, ?, ?)",
                [DbInt(9173), DbStr("赵医生"), DbInt(9171), DbStr("副主任医师"),
                 DbStr("哮喘"), DbInt(now)])
        db.exec("INSERT INTO schedule (id, doctor_id, department_id, work_date, period, " +
                "total_num, remain_num, version, enabled, created_at) " +
                "VALUES (?, ?, ?, ?, ?, ?, ?, 0, 1, ?)",
                [DbInt(9173), DbInt(9173), DbInt(9171), DbStr("2026-11-18"), DbStr("AM"),
                 DbInt(4), DbInt(4), DbInt(now)])

        let repo = TriageRepo(db)
        let v = triageComplaint(repo, "咳嗽三天有痰", "2026-11-10")
        runner.check("给出推荐", v.reasonCode == TR_OK)
        // 两个医生 → 恰好 2 个 option（李医生归并成 1 个）
        runner.check("★ 同一医生只出现一次（期望 2 个 option，实得 ${v.options.size}）",
              v.options.size == 2)
        // 按就诊日升序 → 李医生(11-15) 在前，赵医生(11-18) 在后
        runner.check("★ 按最早就诊日排序（实得 ${if (v.options.size > 0) { v.options[0].workDate } else { "无" }}）",
              v.options.size > 0 && v.options[0].workDate == "2026-11-15")
        // 李医生两个排班合计 2+3=5
        runner.check("★ 同医生的号源数汇总正确（期望 5，实得 ${if (v.options.size > 0) { v.options[0].totalRemain } else { -1 }}）",
              v.options.size > 0 && v.options[0].totalRemain == 5)
        runner.assertAllOptionsBookable(db, v, "归并")
    })
}

/* ===================== P2 预问诊（库级）===================== */

/*
 * AC-P2-5 ★★ 预问诊会话**按患者隔离** —— 这是本组最重要的一条。
 *
 * 为什么必须在**库级**测（而不是只靠 HTTP 层）：HTTP 层的越权用例走的是同一段
 * `PrevisitRepo.find`，但它是"端到端黑盒"——如果哪天有人把 `find` 的
 * `patient_id` 条件去掉，HTTP 用例**确实**会变红，但排查时要绕一大圈。
 * 库级用例把这条不变式**钉在 SQL 上**：`find(sid, 别的患者)` 必须返回 None。
 *
 * 危害说明：问诊单里有既往史/过敏史 —— 那是最敏感的一类信息。
 * 越权读到别人的问诊单，等于泄露他人病史（比泄露手机号严重得多）。
 */
public func acP2_5(runner: TestRunner, db: DbBackend): Unit {
    println("=== AC-P2-5 ★★ 预问诊会话按患者隔离 ===")
    runner.section("AC-P2-5", { =>
        hResetAll(db)
        db.exec("DELETE FROM previsit_session", Array<DbValue>())
        let now = hNowEpoch()
        let repo = PrevisitRepo(db)

        // 患者 1 建会话并作答
        let sid = repo.create(9501, now)
        let _a = repo.answer(sid, 9501, "chief", "咳嗽三天", now)
        // ① 本人能读到
        runner.check("① 本人能读到自己的会话", repo.find(sid, 9501).isSome())
        // ② ★★ 别的患者**读不到**（这是 SQL 里 patient_id 条件的直接断言）
        runner.check("★★ ② 别的患者读不到（find 必须带 patient_id 条件）",
                     repo.find(sid, 9502).isNone())
        // ③ ★★ 别的患者**写不了**
        let w = repo.answer(sid, 9502, "duration", "篡改", now)
        runner.check("★★ ③ 别的患者写不了（answer 同样带 patient_id）", w.noSuchSession)
        // ④ 篡改确实没生效
        let mine = repo.find(sid, 9501).getOrThrow()
        runner.check("④ 篡改未生效（duration 仍未被别人写入）",
                     !mine.form.answers.contains("duration"))
        // ⑤ 不存在的会话
        runner.check("⑤ 不存在的 session_id → None", repo.find("nope", 9501).isNone())

        // ⑥ ★ 未知槽位必须被拒（不能让客户端塞任意键进医疗记录）
        let bad = repo.answer(sid, 9501, "id_card", "110101199001011234", now)
        runner.check("★ ⑥ 未知槽位被拒（unknownSlot 非空）", bad.unknownSlot.size > 0)
        let after = repo.find(sid, 9501).getOrThrow()
        runner.check("⑥ 未知字段**没有**进表单（表单里不会有自造键）",
                     !after.form.answers.contains("id_card"))

        // ⑦ 长度上限按**字符**算：61 个汉字（183 字节）必须被拒
        let cn61 = hRepeatChar("持", 61)
        let tl = repo.answer(sid, 9501, "duration", cn61, now)
        runner.check("★ ⑦ 61 个汉字被拒（长度按字符，不按字节）", tl.tooLong.size > 0)
        // 恰好 60 个汉字 → 接受
        let cn60 = hRepeatChar("持", 60)
        let ok60 = repo.answer(sid, 9501, "duration", cn60, now)
        runner.check("★ ⑦ 恰好 60 个汉字被接受（边界包含）", ok60.ok)

        // ⑧ ★ 空值不写入（"空" ≠ "无"）
        let before = repo.find(sid, 9501).getOrThrow()
        let hadHistory = before.form.answers.contains("history")
        let _e = repo.answer(sid, 9501, "history", "   ", now)
        let after2 = repo.find(sid, 9501).getOrThrow()
        runner.check("★ ⑧ 空值不写入表单（留空 ≠ 阴性答案）",
                     after2.form.answers.contains("history") == hadHistory)
        // 而「无」要被如实保留
        let _n = repo.answer(sid, 9501, "history", "无", now)
        let after3 = repo.find(sid, 9501).getOrThrow()
        runner.check("★ ⑧ 「无」是有效答案，被如实保留", after3.form.answers["history"] == "无")

        // ⑨ 幂等：重复提交同一槽位不改变已填项数
        let f1 = after3.form.filled()
        let _r2 = repo.answer(sid, 9501, "history", "无", now)
        let f2 = repo.find(sid, 9501).getOrThrow().form.filled()
        runner.check("★ ⑨ 重复提交不改变已填项数（重试幂等）", f1 == f2)

        // ⑩ 全部采完后 complete = true（这就是"可以出业务值"的信号）
        for (sl in intakeSlots()) {
            let _x = repo.answer(sid, 9501, sl.key, "x", now)
        }
        let full = repo.find(sid, 9501).getOrThrow()
        runner.check("⑩ 六项齐备后 complete = true", full.form.complete())
        runner.check("⑩ filled = 6", full.form.filled() == 6)
        // ★ 且**别的患者仍然读不到**这个已完成的问诊单（最该保护的时刻）
        runner.check("★★ ⑩ 采完后别的患者依然读不到", repo.find(sid, 9502).isNone())
    })
}

/* 生成 n 个重复字符（测试用；避免在测试里写 60 个汉字字面量）。 */
func hRepeatChar(c: String, n: Int64): String {
    var s = ""
    var i: Int64 = 0
    while (i < n) {
        s = s + c
        i = i + 1
    }
    return s
}
/*
 * AC-P2-6 ★ 预问诊会话**不会无界增长**（第六份复查第 1 条）。
 *
 * 复查实测：连续 12 次 `GET /previsit/stream` ⇒ 表新增 12 行，
 * 而全仓**没有任何地方**清理它。我也复现了（连开 42 次 ⇒ 42 行）。
 *
 * ⚠⚠ 修的过程中我踩了一个**认知错误**，值得记下来：
 *   我第一版把"被放弃的会话"判成 `form_json = ''` —— **错**。
 *   `GET /previsit/stream?chief_complaint=...` 会**立刻把主诉写进表单**，
 *   所以刚开的会话 `form_json` 就已经是 `{"chief":"咳嗽"}`（非空）。
 *   实测连开 42 次，那条 DELETE **一行都匹配不到**（"修了"但没生效）。
 *   真正的判据是"**六个槽位齐不齐**"。
 *   ⇒ 本用例里**必须**故意带上 `chief_complaint`（复刻真实调用），
 *     否则测的是"空表单"这条**不存在的**路径，缺陷会再次漏过。
 */
public func acP2_6(runner: TestRunner, db: DbBackend): Unit {
    println("=== AC-P2-6 ★ 预问诊会话不会无界增长 ===")
    runner.section("AC-P2-6", { =>
        hResetAll(db)
        db.exec("DELETE FROM previsit_session", Array<DbValue>())
        let now = hNowEpoch()
        let repo = PrevisitRepo(db)

        // ★ 每次开流都带上主诉（复刻真实调用 —— 这是上面那个认知错误的关键）
        var i: Int64 = 0
        while (i < 20) {
            let sid = repo.create(9701, now)
            let _a = repo.answer(sid, 9701, "chief", "咳嗽", now)
            i = i + 1
        }
        let rs = db.query("SELECT COUNT(*) FROM previsit_session WHERE patient_id = 9701",
                          Array<DbValue>())
        let n = if (rs.rowCount() > 0) { rs.getInt(0, 0) } else { 0 }
        runner.check("★ 连开 20 次未采完的会话后，行数被压到上限 ${PREVISIT_MAX_OPEN}（实得 ${n}）",
                     n <= PREVISIT_MAX_OPEN)
        runner.check("★ 且不是「全删了」（保留最新几条，实得 ${n}）", n > 0)

        // ★ 已完成的问诊单**不得**被"开新会话"顶掉（那是医疗记录）
        db.exec("DELETE FROM previsit_session", Array<DbValue>())
        let sidDone = repo.create(9702, now)
        for (sl in intakeSlots()) {
            let _x = repo.answer(sidDone, 9702, sl.key, "x", now)
        }
        // 再开一堆未采完的会话，把未采完的挤爆
        var j: Int64 = 0
        while (j < 20) {
            let s2 = repo.create(9702, now)
            let _a2 = repo.answer(s2, 9702, "chief", "咳嗽", now)
            j = j + 1
        }
        runner.check("★★ 已完成的问诊单**未被**新会话顶掉（医疗记录不能因开新会话而丢）",
                     repo.find(sidDone, 9702).isSome())
        let doneNow = repo.find(sidDone, 9702).getOrThrow()
        runner.check("★★ 且它的表单内容仍完整", doneNow.form.complete())

        // ★ TTL：未采完且已陈旧 ⇒ 被 pruneStale 清掉
        db.exec("DELETE FROM previsit_session", Array<DbValue>())
        let old = now - PREVISIT_ABANDONED_TTL - 60      // 超过 TTL
        let sidOld = repo.create(9703, old)
        let _ao = repo.answer(sidOld, 9703, "chief", "咳嗽", old)
        let removed = repo.pruneStale(now)
        runner.check("★ 陈旧的未采完会话被清理（删除 ${removed} 行）", removed >= 1)
        runner.check("★ 清理后读不到它", repo.find(sidOld, 9703).isNone())

        // ★ TTL **不得**误删：未采完但**还新**的会话必须留着
        db.exec("DELETE FROM previsit_session", Array<DbValue>())
        let sidFresh = repo.create(9704, now)
        let _af = repo.answer(sidFresh, 9704, "chief", "咳嗽", now)
        let _r2 = repo.pruneStale(now)
        runner.check("★★ TTL 不误删「还新」的未采完会话（患者正在作答中）",
                     repo.find(sidFresh, 9704).isSome())

        // ★ TTL **不得**误删已完成的
        db.exec("DELETE FROM previsit_session", Array<DbValue>())
        let sidDone2 = repo.create(9705, old)
        for (sl in intakeSlots()) {
            let _x = repo.answer(sidDone2, 9705, sl.key, "x", old)
        }
        let _r3 = repo.pruneStale(now)
        runner.check("★★ TTL 不删**已采完**的问诊单（即使很旧 —— 它属数据保留策略，不归 prune 管）",
                     repo.find(sidDone2, 9705).isSome())

        /*
         * ★★ 第七份复查第 2 条：**判据不得被答案内容影响**。
         *
         * 原来的判据是 `LIKE '%槽位名%'` 计数，我论证过"六个 key 两两不是彼此的子串"
         * —— 那个前提**成立但不充分**：答案**文本**里可以出现槽位名。
         * 我实测复现：
         *     `{"chief":"咳嗽 duration severity associated history allergy"}`
         *     ⇒ 真实键数 = 1，LIKE 计数 = 6 ⇒ 被判成"已完成" ⇒ 永不被压实。
         *
         * 现在判据是 `JSON_LENGTH(JSON_KEYS(form_json))`（数真实键，与值无关）。
         * 本用例**用 SQL 层直接验证**它不受内容影响 —— 这是唯一能守住这条的地方
         * （纯逻辑测试走的是内存表单，压根碰不到这段 SQL）。
         */
        db.exec("DELETE FROM previsit_session", Array<DbValue>())
        // 手工插一条"只答 1 项、但答案里塞了另外 5 个槽位名"的会话（**绕过 repo**，
        // 因为 repo.answer 会拒绝未知槽位；而这条攻击面正是"直接写库/未来别的写路径"）
        db.exec("INSERT INTO previsit_session (id, patient_id, turn, form_json, created_at, updated_at) " +
                "VALUES (?, ?, 1, ?, ?, ?)",
                [DbStr("probe-1slot-5names"), DbInt(9706), DbStr(""), DbInt(now), DbInt(now)])
        db.exec("UPDATE previsit_session SET form_json = ? WHERE id = ?",
                [DbStr("{\"chief\":\"咳嗽 duration severity associated history allergy\"}"),
                 DbStr("probe-1slot-5names")])
        // 它**不应该**被算作已完成 ⇒ 属于"未采完" ⇒ 会被压实逻辑处理
        let probe = db.query("SELECT " + previsitCompleteSql() + " FROM previsit_session WHERE id = ?",
                             [DbStr("probe-1slot-5names")])
        let judgedComplete = if (probe.rowCount() > 0) { probe.getInt(0, 0) != 0 } else { false }
        runner.check("★★ 答案文本里塞满槽位名**不能**让它被判成已完成（判据与内容无关）",
                     !judgedComplete)
        // 反向：真正答满的必须被判成已完成（防止"一律判未完成"这种过度修正）
        let sidFull = repo.create(9707, now)
        for (sl in intakeSlots()) {
            let _x = repo.answer(sidFull, 9707, sl.key, "x", now)
        }
        let full2 = db.query("SELECT " + previsitCompleteSql() + " FROM previsit_session WHERE id = ?",
                             [DbStr(sidFull)])
        let judgedFull = if (full2.rowCount() > 0) { full2.getInt(0, 0) != 0 } else { false }
        runner.check("★★ 反向：真正答满 6 项的仍被判成已完成", judgedFull)
        // ★ 坏 JSON 不得被当成"已完成"（否则它会永不清理）
        db.exec("INSERT INTO previsit_session (id, patient_id, turn, form_json, created_at, updated_at) " +
                "VALUES (?, ?, 1, ?, ?, ?)",
                [DbStr("probe-badjson"), DbInt(9706), DbStr(""), DbInt(now), DbInt(now)])
        db.exec("UPDATE previsit_session SET form_json = ? WHERE id = ?",
                [DbStr("{坏 JSON"), DbStr("probe-badjson")])
        let badRs = db.query("SELECT " + previsitCompleteSql() + " FROM previsit_session WHERE id = ?",
                             [DbStr("probe-badjson")])
        let badComplete = if (badRs.rowCount() > 0) { badRs.getInt(0, 0) != 0 } else { true }
        runner.check("★★ 坏 JSON 会话**不得**被判成已完成（否则它永不清理；JSON_LENGTH 会返回 NULL 就是这个洞）",
                     !badComplete)
    })
}