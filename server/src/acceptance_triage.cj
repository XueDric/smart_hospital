/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 * acceptance_triage.cj —— 分诊与预问诊的库级验收（需真库；用例先 hResetAll 再自建数据，无顺序依赖）。
 *
 * 排班 id 用 9100+ 段，与 acceptance.cj 的 9001/9002 段错开；核心断言见 assertAllOptionsBookable。
 */

package qingzhou

/* 建"分诊用"科室 + 医生 + 排班（id 显式便于用例可读）；不复用 hSeedSchedule：分诊用例必须造多科室。 */
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

/* 只建科室 + 医生，不建排班（"该科室当前没有可挂号源"的工况）。 */
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

extend TestRunner {
    /*
     * 断言"结论里每个 option 都真的有号"：① schedule_id 在库里存在 ② remain_num > 0 ③ enabled = 1。
     * 扩展成员拿不到 TestRunner 的 private let db（实测 undeclared identifier），故 db 显式传参。
     */
    public func assertAllOptionsBookable(db: DbBackend, v: TriageVerdict, tag: String): Unit {
        if (v.options.size == 0) {
            // 无 option 时 reasonCode 必须是"确实给不出"四种之一；不跨行写 ||（仓颉报 possibly confusing line terminator）
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
 * AC-P2-1 危急征象兜底：命中即转急诊，不给任何科室推荐。
 * 必须同时断言 redFlag=true 且 options 为空 —— 只查前者，"又报红牌又推荐"仍会误导患者。
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
        let v2 = triageComplaint(repo, "咳嗽三天", "2026-11-01")
        runner.check("非危急主诉不被误判为红牌", !v2.redFlag)
    })
}

/*
 * AC-P2-2 核心：绝不给"没有号"的推荐。有号→推荐且每个 option 真有号；有科无号→不得推荐它，
 * 只能给有号的备选或明确说没有；无此科→NO_SUCH_DEPT 或备选。
 */
public func acP2_2(runner: TestRunner, db: DbBackend): Unit {
    println("=== AC-P2-2 ★★ 绝不给没有号的推荐（先取证后结论）===")
    runner.section("AC-P2-2", { =>
        let repo = TriageRepo(db)

        hResetAll(db)
        hSeedTriageDept(db, 9111, "呼吸内科", 9111, "李医生", "呼吸", 9111, 5, "2026-12-01")
        let v1 = triageComplaint(repo, "咳嗽三天有痰", "2026-11-01")
        runner.check("① 有号时给出推荐（实得 ${v1.reasonCode}）", v1.reasonCode == TR_OK)
        runner.check("① 推荐了至少 1 个 option", v1.options.size > 0)
        runner.check("① 推荐的是呼吸内科（实得 ${if (v1.options.size > 0) { v1.options[0].departmentName } else { "无" }}）",
              v1.options.size > 0 && v1.options[0].departmentName == "呼吸内科")
        runner.assertAllOptionsBookable(db, v1, "①")

        hResetAll(db)
        hSeedTriageDeptNoSlot(db, 9121, "呼吸内科", 9121, "李医生")
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
        let alt1 = (v2.reasonCode == TR_ALTERNATIVES)
        let alt2 = (v2.reasonCode == TR_NO_BOOKABLE)
        let alt3 = (v2.reasonCode == TR_NO_SUCH_DEPT)
        runner.check("② 给出了有号的备选（ALTERNATIVES）或明确说没有", (alt1 || alt2 || alt3))
        runner.assertAllOptionsBookable(db, v2, "②")

        hResetAll(db)
        hSeedTriageDept(db, 9131, "消化内科", 9131, "王医生", "消化", 9131, 8, "2026-12-02")
        let v3 = triageComplaint(repo, "咳嗽三天有痰", "2026-11-01")
        /*
         * ③ 断言写"给出可行动的信息"而非钉死一个码：本院无呼吸内科但别科有号时应返回 ALTERNATIVES，
         * NO_SUCH_DEPT 只留给"全院无任何可挂号源"（③b）。
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
        hResetAll(db)
        hSeedTriageDeptNoSlot(db, 9132, "消化内科", 9132, "王医生")
        let v3b = triageComplaint(repo, "咳嗽三天有痰", "2026-11-01")
        runner.check("③b 全院无号且规则科室不存在 → NO_SUCH_DEPT（实得 ${v3b.reasonCode}）",
                     v3b.reasonCode == TR_NO_SUCH_DEPT)
        runner.check("③b options 为空", v3b.options.size == 0)

        /*
         * ④ 造"排班存在但 remain_num = 0"，而不是"无排班行"：
         * 只有前者能证明 SQL 的 remain_num > 0 在起作用 —— 曾把判据改成 >= 0 而断言全绿。
         */
        hResetAll(db)
        hSeedTriageDept(db, 9141, "呼吸内科", 9141, "李医生", "呼吸", 9141, 0, "2026-12-01")
        let v4 = triageComplaint(repo, "咳嗽三天有痰", "2026-11-01")
        runner.check("④ 全院无号时不返回 OK", v4.reasonCode != TR_OK)
        runner.check("★★ ④ 约满(remain_num=0)的排班**不得**被推荐（守住 SQL 的 remain_num > 0）",
                     v4.options.size == 0)
        runner.check("④ 仍然给出可读说明（兜底不得为空）", v4.patientNote.size > 0)

        hResetAll(db)
        hSeedTriageDeptNoSlot(db, 9142, "呼吸内科", 9142, "李医生")
        let v4b = triageComplaint(repo, "咳嗽三天有痰", "2026-11-01")
        runner.check("④b 科室无排班行时也不返回 OK", v4b.reasonCode != TR_OK)
        runner.check("④b options 为空", v4b.options.size == 0)

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
 * AC-P2-3 过期排班不算可用：漏了 work_date >= today 就会推荐过期排班，挂号侧虽会拒，
 * 但分诊的承诺已落空。边界含今天。
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
 * AC-P2-4 多医生/多排班归并：toOptions 按医生归并（同医生只留最早）。
 * 归并写错会导致同一医生重复出现，或 totalRemain 汇总错。
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
        runner.check("★ 同一医生只出现一次（期望 2 个 option，实得 ${v.options.size}）",
              v.options.size == 2)
        runner.check("★ 按最早就诊日排序（实得 ${if (v.options.size > 0) { v.options[0].workDate } else { "无" }}）",
              v.options.size > 0 && v.options[0].workDate == "2026-11-15")
        runner.check("★ 同医生的号源数汇总正确（期望 5，实得 ${if (v.options.size > 0) { v.options[0].totalRemain } else { -1 }}）",
              v.options.size > 0 && v.options[0].totalRemain == 5)
        runner.assertAllOptionsBookable(db, v, "归并")
    })
}

/* 预问诊（库级） */

/*
 * AC-P2-5 预问诊会话按患者隔离：库里 find(sid, 别的患者) 必须返回 None。
 * 在库级钉住 SQL 的 patient_id 条件 —— 问诊单含既往史/过敏史，越权读取等于泄露病史。
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
        runner.check("① 本人能读到自己的会话", repo.find(sid, 9501).isSome())
        runner.check("★★ ② 别的患者读不到（find 必须带 patient_id 条件）",
                     repo.find(sid, 9502).isNone())
        let w = repo.answer(sid, 9502, "duration", "篡改", now)
        runner.check("★★ ③ 别的患者写不了（answer 同样带 patient_id）", w.noSuchSession)
        let mine = repo.find(sid, 9501).getOrThrow()
        runner.check("④ 篡改未生效（duration 仍未被别人写入）",
                     !mine.form.answers.contains("duration"))
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
 * AC-P2-6 预问诊会话不会无界增长。判据是"六个槽位齐不齐"，不是 form_json 是否为空：
 * GET /previsit/stream?chief_complaint=... 会立刻写入主诉，故用例必须带 chief_complaint 复刻真实调用。
 */
public func acP2_6(runner: TestRunner, db: DbBackend): Unit {
    println("=== AC-P2-6 ★ 预问诊会话不会无界增长 ===")
    runner.section("AC-P2-6", { =>
        hResetAll(db)
        db.exec("DELETE FROM previsit_session", Array<DbValue>())
        let now = hNowEpoch()
        let repo = PrevisitRepo(db)

        // 每次开流都带主诉（复刻真实调用）
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
         * 判据不得被答案内容影响：旧判据 LIKE '%槽位%' 在答案文本里塞满槽位名时会误判成已完成。
         * 现判据 JSON_LENGTH(JSON_KEYS(form_json))；此处从 SQL 层直接验证，纯逻辑测试碰不到。
         */
        db.exec("DELETE FROM previsit_session", Array<DbValue>())
        // 手工插一条"只答 1 项、答案里塞满另外 5 个槽位名"的会话（绕过 repo：repo.answer 拒未知槽位）。
        db.exec("INSERT INTO previsit_session (id, patient_id, turn, form_json, created_at, updated_at) " +
                "VALUES (?, ?, 1, ?, ?, ?)",
                [DbStr("probe-1slot-5names"), DbInt(9706), DbStr(""), DbInt(now), DbInt(now)])
        db.exec("UPDATE previsit_session SET form_json = ? WHERE id = ?",
                [DbStr("{\"chief\":\"咳嗽 duration severity associated history allergy\"}"),
                 DbStr("probe-1slot-5names")])
        // 它**不应该**被算作已完成 ⇒ 属于"未采完" ⇒ 会被压实逻辑处理
        /*
         * 用 COUNT(*) 包一层：判据含 JSON_KEYS，坏 JSON 给 NULL，直接 getInt 会抛异常并中断整轮 accept。
         * 测试"抛异常"与测试"报失败"不是一回事，前者会掩盖后者。
         */
        let probe = db.query("SELECT COUNT(*) FROM previsit_session WHERE id = ? AND " +
                             previsitCompleteSql(), [DbStr("probe-1slot-5names")])
        let judgedComplete = (probe.rowCount() > 0) && (probe.getInt(0, 0) != 0)
        runner.check("★★ 答案文本里塞满槽位名**不能**让它被判成已完成（判据与内容无关）",
                     !judgedComplete)
        // 反向：真正答满的必须被判成已完成（防止"一律判未完成"这种过度修正）
        let sidFull = repo.create(9707, now)
        for (sl in intakeSlots()) {
            let _x = repo.answer(sidFull, 9707, sl.key, "x", now)
        }
        let full2 = db.query("SELECT COUNT(*) FROM previsit_session WHERE id = ? AND " +
                             previsitCompleteSql(), [DbStr(sidFull)])
        let judgedFull = (full2.rowCount() > 0) && (full2.getInt(0, 0) != 0)
        runner.check("★★ 反向：真正答满 6 项的仍被判成已完成", judgedFull)
        // ★ 坏 JSON 不得被当成"已完成"（否则它会永不清理）
        db.exec("INSERT INTO previsit_session (id, patient_id, turn, form_json, created_at, updated_at) " +
                "VALUES (?, ?, 1, ?, ?, ?)",
                [DbStr("probe-badjson"), DbInt(9706), DbStr(""), DbInt(now), DbInt(now)])
        db.exec("UPDATE previsit_session SET form_json = ? WHERE id = ?",
                [DbStr("{坏 JSON"), DbStr("probe-badjson")])
        let badRs = db.query("SELECT COUNT(*) FROM previsit_session WHERE id = ? AND " +
                             previsitCompleteSql(), [DbStr("probe-badjson")])
        let badComplete = (badRs.rowCount() > 0) && (badRs.getInt(0, 0) != 0)
        runner.check("★★ 坏 JSON 会话**不得**被判成已完成（否则它永不清理；JSON_LENGTH 会返回 NULL 就是这个洞）",
                     !badComplete)
    })
}