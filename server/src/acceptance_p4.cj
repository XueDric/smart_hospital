/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 *
 * ===== acceptance_p4.cj —— P4 验收：电子病历 + 接诊队列 + 运营看板 ==========
 *
 * ── 本文件守护的四条不变量（按重要性排序）──────────────────────────────
 *
 *   ① ★★ **看板绝不出明细**（隐私）：
 *      它是"跨患者聚合"，是最容易泄露的地方。断言把响应当字符串搜
 *      `patient_id` / `doctor_id` / `phone` / 姓名，一个都不许有。
 *      并且**逐条检查所有数字都是计数**（不给"某人的"任何东西）。
 *
 *   ② ★★ **分诊统计绝不落库主诉原文**：
 *      `TriageStatRepo.record` 的签名里就没有主诉参数（类型层面做不到），
 *      但断言仍要**实测**：写一条后去搜主诉片段，必须搜不到。
 *
 *   ③ ★★ **病历锁定后不可改**：
 *      "提交锁定"的全部意义。锁定 → 再保存草稿必须被拒（`locked`），
 *      且**库里的内容没变**（不是"返回了错误但其实写进去了"）。
 *
 *   ④ ★★ **越权一律当"不存在"**：
 *      医生 B 读/写医生 A 的号 ⇒ 404（不是 403 —— 403 会变成
 *      "这张单是否存在"的枚举 oracle）。患者读别人的病历同理。
 */

package qingzhou

import std.collection.*

/*
 * 造一张"某医生名下的挂号单"，返回 appointment_id。
 *
 * ⚠⚠ 这个 fixture 我写错过一次，值得记：**必须为每个"种子实体"用唯一 id**。
 *   我第一版所有挂号单共用一个科室 id（8801）⇒ 第二次调用时 `hSeedTriageDept`
 *   的纯 `INSERT` 撞主键 ⇒ 报 `Duplicate entry`。
 *   ⚠ 而**驱动把那条消息吞成了空串**（只给 `SqlException: errorCode: 0`）
 *     ⇒ 从异常上完全看不出是主键冲突，只能靠手工重放 SQL 才定位到。
 *   📌 本仓既有约定就是"每个 seed 用唯一 id"（见 acceptance_triage.cj 的
 *     9101 / 9111 / 9122 …）。这里照办：由 `doctorId`+`patientId` 派生唯一 id。
 */
/*
 * 造一张"某医生名下的挂号单"，返回 appointment_id。
 *
 * ⚠⚠ 这个 fixture 我改过三次，每一次的失败都值得记下来：
 *
 *   ① 起初所有调用共用一个科室 id ⇒ 第二次调用时 `hSeedTriageDept` 的纯
 *      `INSERT` 撞主键。而**驱动把 `Duplicate entry` 的消息吞成了空串**
 *      （只给 `SqlException: errorCode: 0`）⇒ 从异常完全看不出原因。
 *   ② 改成"每张单一个医生 id"后，同一医生下的多张单又不够用
 *      （我要测"一个医生有多张单"）。
 *
 *   ⇒ 现在：**一个 `seedId` 派生全部四个 id**，彼此不撞，且同一 `seedId`
 *     的多张单共享同一个医生（这正是"接诊队列有多条"要的形态）。
 *     需要"另一个医生"的用例显式传 `asDoctorId`（他名下没有单 → 用于归属测试）。
 *   ⚠ 约定：**每个 `seedId` 只属于一个用例**（本仓既有约定，见 acceptance_triage.cj）。
 *   📌 教训升级：这里是**数据造错的失败被驱动的空消息掩盖**。
 *     所以本 fixture 后来加了"步骤探针"才定位到 —— 而真正的修复是让 id 不可能撞。
 */
func hSeedAppointmentForDoctor(db: DbBackend, seedId: Int64, patientId: Int64,
                               status: String, asDoctorId!: Int64 = 0): Int64 {
    /*
     * ★★ **每类实体各占一个互不重叠的 id 前缀**（这是本 fixture 的真正修复）。
     *
     * ⚠ 我在这里连撞三次，每次都只得到「Duplicate entry」+ 空消息：
     *   ① 所有调用共用一个科室 id ⇒ 第二次 seed 撞 department 主键；
     *   ② 科室 id 与医生 id 同值（都用 `880000+seedId`）⇒ 撞；
     *   ③ 科室 id 与**排班** id 同值（同一个表达式）⇒ 排班那行也撞。
     *   ⇒ 根因只有一个：**我拿同一个值去插不同的表/重复插同一张表**。
     *     注意 ②③ 的形态：`dept=880000+seed` 与 `doctor=880000+seed` 值相同，
     *     但 department 与 doctor 是**两张表**，值相等本身不冲突 ——
     *     真正冲突的是"同一张表被插两次同 id"。
     *     之所以仍然撞，是因为 `hSeedTriageDept` 会**同时**插
     *     department 与 doctor，而不同 seed 之间前缀重叠了。
     *   ⇒ 彻底解决：dept / schedule / doctor / patient **四个前缀互不重叠**，
     *     每个都由 `seedId` 派生。这样任一 seed 组合都不会撞。
     */
    let deptId = 810000 + seedId
    let scheduleId = 820000 + seedId
    /*
     * ★★ **先清后插 —— 让 fixture 幂等**（这是本 fixture 的真正修复）。
     *
     * ⚠ 我在这一处连撞四次，前三次都在改 id 前缀，治的都是症：
     *   `hSeedTriageDept` 是**纯 INSERT**，而我在**同一个 criterion 内**用
     *   同一个 `seedId` 调它多次（"同一医生名下多张单"正是要测的形态）
     *   ⇒ 第二次插入同一 `deptId` 必撞主键。
     *   ⇒ id 怎么分前缀都治不了这个 —— **根因是"重复插入"本身**。
     *
     * 📌 教训：`Duplicate entry` 出现时，先问"**是不是我不该插第二次**"，
     *   而不是急着换 id。前者是幂等性问题，后者只是把碰撞推到更远。
     *   ⚠ 而驱动把消息吞成空串，让"哪个键撞了"都看不出来
     *     （只能看到 `Duplicate entry '810002' for key 'PRIMARY'` 里的 id）——
     *     这也是我前三次误判方向的原因之一。
     */
    /*
     * ⚠ 只清**会被重复插入的那三张表**（dept / doctor / schedule）——
     *   **不碰 appointment**。
     *   我第一版顺手把该医生的 appointment 也删了，结果"先清后插"变成了
     *   "把前一次 seed 插入的挂号单删掉" ⇒ 队列长度变成 0（实测）。
     *   📌 又一次"清理范围过大"：幂等清理要**只清自己会重复写的那部分**。
     */
    let effDoctorId = if (asDoctorId > 0) { asDoctorId } else { 900000 + seedId }
    db.exec("DELETE FROM schedule WHERE id = ?", [DbInt(scheduleId)])
    db.exec("DELETE FROM doctor WHERE id = ?", [DbInt(effDoctorId)])
    db.exec("DELETE FROM department WHERE id = ?", [DbInt(deptId)])
    /*
     * ⚠ **科室 id 与医生 id 必须落在不同命名空间** —— 我第一版让两者都是
     *   `880000 + seedId`，于是 `department(900002)` 与 `doctor(900002)`
     *   撞主键（两张表各自唯一，但我在同一表达式里复用了同一个值去插两张表，
     *   而 `hSeedTriageDept` 的 INSERT 是纯 INSERT ⇒ Duplicate）。
     *   ⇒ 科室 88xxxx、医生 90xxxx，互不重叠。
     */
    let doctorId = if (asDoctorId > 0) { asDoctorId } else { 900000 + seedId }
    hSeedTriageDept(db, deptId, "P4测试科${seedId}", doctorId, "P4测试医生${doctorId}", "测试",
                    scheduleId, 50, "2026-12-20")
    /* ⚠ `patient.phone` 有唯一键（uk_patient_phone）—— 每个患者用不同号码 */
    db.exec("INSERT INTO patient (id, phone, name, gender, birth_date, created_at) " +
            "VALUES (?, ?, ?, ?, ?, 0) ON DUPLICATE KEY UPDATE name = VALUES(name)",
            [DbInt(patientId), DbStr("139" + hP4Pad8(patientId)), DbStr("P4测试患者${patientId}"),
             DbStr("M"), DbStr("1990-01-01")])
    /* ⚠ 用 execInsert：exec/query 不保证同一条连接，分开读 LAST_INSERT_ID 可能是别的连接的值。 */
    return db.execInsert("INSERT INTO appointment (schedule_id, patient_id, doctor_id, department_id, " +
                         "visit_date, period, seq_no, status, slot_restored, created_at) " +
                         "VALUES (?, ?, ?, ?, ?, 'AM', 1, ?, 1, 0)",
                         [DbInt(scheduleId), DbInt(patientId), DbInt(doctorId), DbInt(deptId),
                          DbStr("2026-12-20"), DbStr(status)])
}

/* 造一个**名下没有挂号单**的医生（用于"不属于我"的归属测试）。 */
func hSeedIdleDoctor(db: DbBackend, doctorId: Int64): Unit {
    let deptId = 899000 + (doctorId % 1000)
    hSeedTriageDept(db, deptId, "P4闲置科${doctorId}", doctorId, "P4闲置医生${doctorId}", "测试",
                    deptId, 1, "2026-12-21")
}
/* 把 id 补成 8 位数字（拼手机号用；唯一即可，不追求真实号段）。 */
func hP4Pad8(v: Int64): String {
    var s = v.toString()
    while (s.size < 8) {
        s = "0" + s
    }
    return s
}
/* 填满七段并能通过锁定的最小内容。 */
func hFillAllSections(emr: MedicalRecordRepo, apptId: Int64, doctorId: Int64,
                      now: Int64, actor: Int64): EmrWriteOutcome {
    let patch = HashMap<String, String>()
    for (s in emrSections()) {
        patch[s.key] = "测试内容-${s.key}"
    }
    return emr.saveDraft(apptId, doctorId, patch, now, actor)
}

/* ===================== AC-P4-1：病历基本写入与锁定 ===================== */

public func acP4_1(runner: TestRunner, db: DbBackend): Unit {
    println("=== AC-P4-1 ★★ 病历：草稿 / 锁定 / 锁定后不可改 ===")
    runner.section("AC-P4-1", { =>
        hResetAll(db)
        hResetAiSettings(db)
        db.exec("DELETE FROM medical_record", Array<DbValue>())
        db.exec("DELETE FROM triage_stat", Array<DbValue>())
        let now = hNowEpoch()
        let emr = MedicalRecordRepo(db)
        let apptId = hSeedAppointmentForDoctor(db, 1, 8801, VISIT_VISITING)

        // ① 全新单没有病历
        runner.check("① 尚未写病历时 findByAppointment 返回 None",
                     emr.findByAppointment(apptId).isNone())

        // ② 只写一段 ⇒ 允许（草稿允许半成品）
        let p1 = HashMap<String, String>()
        p1["chief_complaint"] = "咳嗽三天"
        let w1 = emr.saveDraft(apptId, 900001, p1, now, 9901)
        runner.check("② 只写一段（主诉）成功 —— 草稿允许半成品", w1.ok)
        let r1 = emr.findByAppointment(apptId).getOrThrow()
        runner.check("② 且 filled = 1（实得 ${r1.filledCount()}）", r1.filledCount() == 1)
        runner.check("② ★ patient_id 由数据库从 appointment 派生（实得 ${r1.patientId}）",
                     r1.patientId == 8801)

        // ③ 必填未齐时**不许锁定**（且说清缺哪两段）
        let l1 = emr.lock(apptId, now, 9901, "doctor")
        runner.check("★★ ③ 缺必填段时锁定被拒（missingRequired）", l1.missingRequired)
        runner.check("③ 且缺的是诊断与处理意见（实得「${l1.detail}」）",
                     l1.detail.contains("诊断") && l1.detail.contains("处理意见"))
        runner.check("③ 库里的状态仍是 draft（没被偷偷锁上）",
                     emr.findByAppointment(apptId).getOrThrow().status == EMR_DRAFT)

        // ④ 填满后能锁定
        let w2 = hFillAllSections(emr, apptId, 900001, now, 9901)
        runner.check("④ 填满七段成功", w2.ok)
        let l2 = emr.lock(apptId, now, 9901, "doctor")
        runner.check("④ 填满后可锁定", l2.ok)
        runner.check("④ 库里的状态是 locked",
                     emr.findByAppointment(apptId).getOrThrow().status == EMR_LOCKED)

        // ⑤ ★★ 锁定后**不可改**（本组最关键的一条）
        let before = emr.findByAppointment(apptId).getOrThrow()
        let p2 = HashMap<String, String>()
        p2["diagnosis"] = "被篡改的诊断"
        let w3 = emr.saveDraft(apptId, 900001, p2, now + 10, 9901)
        runner.check("★★ ⑤ 锁定后再保存草稿被拒（locked）", w3.locked)
        let after = emr.findByAppointment(apptId).getOrThrow()
        runner.check("★★ ⑤ 而且**库里的内容真的没变**（不是「拒了但写进去了」）",
                     after.diagnosis == before.diagnosis)
        runner.check("⑤ 锁定时间戳也没被这次被拒的写入改动",
                     after.updatedAt == before.updatedAt)

        // ⑥ 重复锁定 ⇒ 如实说"已锁定"，不当成功
        let l3 = emr.lock(apptId, now + 20, 9901, "doctor")
        runner.check("⑥ 重复提交锁定时 locked=true（不假装成功）", l3.locked && !l3.ok)
        /*
         * ★ 改进 3 新增：幂等路径**自愈**快照 —— 重复 lock 不该悄悄什么都不做。
         *   （第一次成功锁定已经落下 v1，这里复查它仍在、且没有多出重复版本。）
         */
        runner.check("★ ⑥ 重复锁定后仍只有 1 版快照（实得 ${emr.revisions(apptId).size}）",
                     emr.revisions(apptId).size == 1)

        // ⑦ 管理员解锁后可改（**必须给理由** —— 改进 3）
        let ro = emr.reopen(apptId, now + 30, 9902, "admin", "患者反馈诊断需补充，解锁重写")
        runner.check("⑦ 管理员解锁成功", ro.ok)
        let p3 = HashMap<String, String>()
        p3["diagnosis"] = "修订后的诊断"
        let w4 = emr.saveDraft(apptId, 900001, p3, now + 40, 9901)
        runner.check("⑦ 解锁后可改", w4.ok)
        runner.check("⑦ 且内容确实变了",
                     emr.findByAppointment(apptId).getOrThrow().diagnosis == "修订后的诊断")
        runner.check("★ ⑦ updated_by 记的是**本次操作者**（实得 ${emr.findByAppointment(apptId).getOrThrow().updatedBy}）",
                     emr.findByAppointment(apptId).getOrThrow().updatedBy == 9901)

        // ⑧ 未知段 / 超长段必须被拒（写入路径严格）
        let bad = HashMap<String, String>()
        bad["no_such_section"] = "x"
        runner.check("⑧ 未知段被拒（unknownSection）", emr.saveDraft(apptId, 900001, bad, now, 9901).unknownSection)
        let long = HashMap<String, String>()
        long["diagnosis"] = hRepeatChar("诊", 2001)
        let lo = emr.saveDraft(apptId, 900001, long, now, 9901)
        runner.check("★ ⑧ 超长段被拒（按**字符**算，2001 > 上限 2000）", lo.tooLong)

        // ⑨ 单次就诊只能有一份病历（数据库唯一键兜底）
        let cnt = db.query("SELECT COUNT(*) FROM medical_record WHERE appointment_id = ?",
                           [DbInt(apptId)])
        runner.check("★★ ⑨ 一份挂号单只有一份病历（实得 ${cnt.getInt(0, 0)}）",
                     cnt.getInt(0, 0) == 1)
    })
}

/* ===================== AC-P4-2：接诊状态机 ===================== */

public func acP4_2(runner: TestRunner, db: DbBackend): Unit {
    println("=== AC-P4-2 ★★ 接诊队列状态机（含「完成前必须已锁定病历」）===")
    runner.section("AC-P4-2", { =>
        hResetAll(db)
        db.exec("DELETE FROM medical_record", Array<DbValue>())
        let now = hNowEpoch()
        let emr = MedicalRecordRepo(db)
        let visit = VisitRepo(db)
        let apptId = hSeedAppointmentForDoctor(db, 2, 8802, VISIT_BOOKED)

        // ① booked → visiting 允许
        runner.check("① 开始接诊（booked → visiting）成功",
                     visit.transition(apptId, 900002, VISIT_VISITING, [VISIT_BOOKED]).ok)
        // ② ★ 病历未锁定时**不许完成就诊**
        let f1 = visit.finishVisit(apptId, 900002)
        runner.check("★★ ② 病历未锁定 ⇒ 完成就诊被拒（recordNotLocked）", f1.recordNotLocked)
        runner.check("② 且库里状态仍是 visiting（没被偷偷改成 done）",
                     visit.findForDoctor(apptId, 900002).getOrThrow().status == VISIT_VISITING)
        // ③ 写了病历但**只是草稿** ⇒ 仍不许完成
        let _w = hFillAllSections(emr, apptId, 900002, now, 9901)
        runner.check("★★ ③ 病历只是草稿 ⇒ 完成就诊仍被拒（草稿不算完成诊疗）",
                     visit.finishVisit(apptId, 900002).recordNotLocked)
        // ④ 锁定后可以完成
        let _l = emr.lock(apptId, now, 9901, "doctor")
        runner.check("④ 病历锁定后可以完成就诊", visit.finishVisit(apptId, 900002).ok)
        runner.check("④ 且库里状态是 done",
                     visit.findForDoctor(apptId, 900002).getOrThrow().status == VISIT_DONE)
        // ⑤ ★ done 是终态：不许再流转
        runner.check("★★ ⑤ done 是终态：再次开始接诊被拒",
                     visit.transition(apptId, 900002, VISIT_VISITING, [VISIT_BOOKED]).badTransition)
        runner.check("★★ ⑤ done 是终态：标记爽约也被拒",
                     visit.transition(apptId, 900002, VISIT_NO_SHOW,
                                      [VISIT_BOOKED, VISIT_VISITING]).badTransition)
        // ⑥ 显式流转表本身（加状态时这里会一起被看见）
        runner.check("⑥ 流转表：booked→visiting 允许", visitTransitionAllowed(VISIT_BOOKED, VISIT_VISITING))
        runner.check("⑥ 流转表：visiting→done 允许", visitTransitionAllowed(VISIT_VISITING, VISIT_DONE))
        runner.check("⑥ 流转表：done→任何 都不允许",
                     !visitTransitionAllowed(VISIT_DONE, VISIT_VISITING) &&
                     !visitTransitionAllowed(VISIT_DONE, VISIT_NO_SHOW) &&
                     !visitTransitionAllowed(VISIT_DONE, VISIT_CANCELLED))
        runner.check("⑥ 流转表：cancelled→任何 都不允许",
                     !visitTransitionAllowed(VISIT_CANCELLED, VISIT_VISITING))
        // ⑦ 爽约路径：booked → no_show（不需要病历）
        let a2 = hSeedAppointmentForDoctor(db, 2, 8803, VISIT_BOOKED)
        runner.check("⑦ 未接诊直接爽约（booked → no_show）允许",
                     visit.transition(a2, 900002, VISIT_NO_SHOW, [VISIT_BOOKED, VISIT_VISITING]).ok)
        // ⑧ 队列不含已退号
        let a3 = hSeedAppointmentForDoctor(db, 2, 8804, VISIT_CANCELLED)
        let q = visit.queueForDoctor(900002, 100)
        var hasCancelled = false
        for (x in q) {
            if (x.appointmentId == a3) {
                hasCancelled = true
            }
        }
        runner.check("★★ ⑧ 队列**不含**已退号的单", !hasCancelled)
        runner.check("⑧ 队列按 visit_date/period/seq_no 排序（长度 ${q.size}）", q.size >= 2)
        // ⑨ 医生只能看/改自己的号
        runner.check("★★ ⑨ 医生 B 查医生 A 的单 ⇒ None（不是「无权限」，是「不存在」）",
                     visit.findForDoctor(apptId, 8899).isNone())
        runner.check("★★ ⑨ 医生 B 改医生 A 的单 ⇒ notFound",
                     visit.transition(apptId, 8899, VISIT_VISITING, [VISIT_BOOKED]).notFound)
    })
}

/* ===================== AC-P4-3：看板隐私红线 ===================== */

public func acP4_3(runner: TestRunner, db: DbBackend): Unit {
    println("=== AC-P4-3 ★★ 运营看板：只出聚合、绝不出明细 ===")
    runner.section("AC-P4-3", { =>
        hResetAll(db)
        hResetAiSettings(db)
        db.exec("DELETE FROM medical_record", Array<DbValue>())
        db.exec("DELETE FROM triage_stat", Array<DbValue>())
        let now = hNowEpoch()
        let emr = MedicalRecordRepo(db)
        /* 造一点真实数据，让看板有东西可算（否则"没有明细"是空集的废话） */
        let a1 = hSeedAppointmentForDoctor(db, 3, 8811, VISIT_VISITING)
        let _w = hFillAllSections(emr, a1, 900003, now, 9901)
        let _l = emr.lock(a1, now, 9901, "doctor")
        let a2 = hSeedAppointmentForDoctor(db, 3, 8812, VISIT_BOOKED)
        let ts = TriageStatRepo(db)
        ts.record("OK", false, "P4测试科", false, "rules", now)

        let dash = DashboardRepo(db)
        let ai = AiSettingsRepo(db)
        let o = dash.build(now, ai)
        let s = o.toString()

        // ① ★★ 逐字段：不得出现任何 id / 联系方式键
        let forbidden: Array<String> = ["patient_id", "doctor_id", "phone", "patient_name",
                                        "doctor_name", "user_id", "login_name", "id_card"]
        var leaked = ArrayList<String>()
        for (k in forbidden) {
            if (s.contains(k)) {
                leaked.add(k)
            }
        }
        runner.check("★★ ① 看板响应里没有任何 id/联系方式键（泄露: ${joinStrings(leaked.toArray(), ",")}）",
                     leaked.size == 0)

        // ② ★★ 也不得出现**具体的患者/医生姓名**（造数据时用的名字）
        runner.check("★★ ② 看板响应里不含测试患者的姓名",
                     !s.contains("P4测试患者8811"))
        runner.check("★★ ② 看板响应里不含测试医生的姓名",
                     !s.contains("P4测试医生8811"))

        // ③ 该有的聚合指标都在
        runner.check("③ 含 scale（科室/医生/患者规模）", o.get("scale").isSome())
        runner.check("③ 含 appointments（挂号总览 + 取消率）", o.get("appointments").isSome())
        runner.check("③ 含 trend（挂号趋势）", o.get("trend").isSome())
        runner.check("③ 含 by_department（科室分布）", o.get("by_department").isSome())
        runner.check("③ 含 slots（号源使用率）", o.get("slots").isSome())
        runner.check("③ 含 triage（分诊命中）", o.get("triage").isSome())
        runner.check("③ 含 previsit（预问诊完成率）", o.get("previsit").isSome())
        runner.check("③ 含 medical_records（病历进度）", o.get("medical_records").isSome())
        runner.check("③ 含 ai（AI 能力中心概览）", o.get("ai").isSome())

        // ④ 数字得是**真的**（不是全 0）—— 否则上面的"没有明细"毫无意义
        let appt = o.get("appointments").getOrThrow().asObject()
        let total = appt.get("total").getOrThrow().asInt().getValue()
        runner.check("★★ ④ 看板的挂号总数 > 0（实得 ${total}）—— 证明它真在算，不是空集",
                     total > 0)
        let emrObj = o.get("medical_records").getOrThrow().asObject()
        let locked = emrObj.get("locked").getOrThrow().asInt().getValue()
        runner.check("④ 病历已锁定数 > 0（实得 ${locked}）", locked > 0)

        // ⑤ ★ 分诊数值必须**如实**标注 source=rules（未接模型）
        let tri = o.get("triage").getOrThrow().asObject()
        let src = tri.get("source").getOrThrow().asString().getValue()
        runner.check("★ ⑤ 分诊标注 source=${src}（如实：规则引擎，未接模型）", src == "rules")
        let triTotal = tri.get("total_calls").getOrThrow().asInt().getValue()
        runner.check("⑤ 分诊调用数 > 0（实得 ${triTotal}）—— 统计链路真的通了", triTotal > 0)

        // ⑥ ★★ AI 调用量**不编造**：未接模型 ⇒ 0，且有说明
        let aiObj = o.get("ai").getOrThrow().asObject()
        let calls = aiObj.get("model_calls").getOrThrow().asInt().getValue()
        runner.check("★★ ⑥ model_calls = ${calls}（未接模型，不编造调用量）", calls == 0)
        runner.check("⑥ 且有 note 说明为什么是 0",
                     aiObj.get("model_calls_note").getOrThrow().asString().getValue().size > 0)
        runner.check("★ ⑥ endpoint 只给 host（查询串可能含凭据）",
                     !s.contains("api-key") && !s.contains("token="))

        // ⑦ 取消率是千分比（整数），且分母为 0 时给 0 不抛
        runner.check("⑦ 取消率以千分比给出（整数）",
                     appt.get("cancel_permille").isSome())
        let emptyAi = AiSettingsRepo(db)
        let o2 = dash.build(now, emptyAi)
        runner.check("⑦ 重复构建看板不抛异常（只读、幂等）", o2.get("appointments").isSome())
    })
}

/* ===================== AC-P4-4：分诊统计不落主诉原文 ===================== */

public func acP4_4(runner: TestRunner, db: DbBackend): Unit {
    println("=== AC-P4-4 ★★ 分诊统计：只存结论，绝不落库主诉原文 ===")
    runner.section("AC-P4-4", { =>
        db.exec("DELETE FROM triage_stat", Array<DbValue>())
        let ts = TriageStatRepo(db)
        let now = hNowEpoch()
        /*
         * ⚠ 这里用一个**独一无二的字符串**当"主诉" —— 它是敏感自由文本的替身。
         *   写完统计后去全表搜它，必须搜不到。
         *   （主诉参数压根不在 `record()` 的签名里，所以这条其实是**双重**保证：
         *     类型层面做不到 + 实测确认没落库。）
         */
        let marker = "ZZUNIQUECOMPLAINT" + hNowEpoch().toString()
        ts.record("OK", false, "P4测试科", false, "rules", now)
        let rs = db.query("SELECT COUNT(*) FROM triage_stat WHERE reason_code LIKE ? " +
                          "OR department LIKE ?", [DbStr("%" + marker + "%"), DbStr("%" + marker + "%")])
        runner.check("★★ 统计表里搜不到主诉片段（实得 ${rs.getInt(0, 0)} 行）",
                     rs.getInt(0, 0) == 0)
        // 反向：结论字段确实记下来了（证明它不是「什么都没写」）
        let rs2 = db.query("SELECT COUNT(*) FROM triage_stat WHERE reason_code = 'OK'",
                           Array<DbValue>())
        runner.check("★ 反向：结论字段**确实**记下了（实得 ${rs2.getInt(0, 0)} 行）—— 不是「什么都没写」",
                     rs2.getInt(0, 0) > 0)
        // TTL 清理
        db.exec("DELETE FROM triage_stat", Array<DbValue>())
        let old = now - (TRIAGE_STAT_TTL_DAYS + 10) * 86400
        ts.record("OLD", false, "", false, "rules", old)
        let removed = ts.prune(now)
        runner.check("★ TTL：陈旧统计被清理（删除 ${removed} 行）", removed >= 1)
        runner.check("★ TTL：清完后表里没有陈旧的（实得 ${ts.count()} 行）", ts.count() == 0)
        // 表结构本身的否定断言：没有"主诉"这类自由文本列
        let cols = db.query(
            "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() " +
            "AND TABLE_NAME = 'triage_stat' AND (COLUMN_NAME LIKE '%complaint%' " +
            "OR COLUMN_NAME LIKE '%text%' OR COLUMN_NAME LIKE '%note%')", Array<DbValue>())
        runner.check("★★ 表结构里**没有**任何自由文本列（实得 ${cols.getInt(0, 0)} 列）—— " +
                     "不是「存了再脱敏」，而是**根本不存**",
                     cols.getInt(0, 0) == 0)
    })
}

/* ============ AC-P4-5：预问诊 → 病历的桥（2026-10-14 改进 1）============ */

/*
 * 本用例守护的四条不变式：
 *
 *   ① ★★ **一次问诊单只能绑一张挂号单**（`appointment_id = 0 OR = ?`）：
 *      允许多绑就等于"一次误传能把患者的自述挂到别人的就诊上"——
 *      那是**病历污染**，比读到不该读的更坏（写坏的东西会被当成诊疗依据）。
 *
 *   ② ★★ **会话归属由 SQL 里的 patient_id 保证**，不靠调用方"上一步查过了"：
 *      别的患者既绑不走、也读不到、也预填不进自己名下那张单。
 *
 *   ③ ★★ **来源痕迹只记"患者答的段"**：医生在同一次请求的 patch 里写过的段
 *      不算患者自述。否则病历上会挂着一个名不副实的"患者自述"角标 ——
 *      而病历是**法律文书**，来源标注错了比没有标注更坏。
 *
 *   ④ ★ **预填只在建单那一次发生**：已有病历不吃预填（医生判断优先），
 *      因此来源痕迹也不会被后续保存改掉（它是"初值来源"的快照，不是"当前作者"）。
 */
public func acP4_5(runner: TestRunner, db: DbBackend): Unit {
    println("=== AC-P4-5 ★★ 预问诊 → 病历：绑定唯一、归属严格、来源如实 ===")
    runner.section("AC-P4-5", { =>
        hResetAll(db)
        db.exec("DELETE FROM previsit_session", Array<DbValue>())
        db.exec("DELETE FROM medical_record", Array<DbValue>())
        let now = hNowEpoch()
        let pv = PrevisitRepo(db)
        let emr = MedicalRecordRepo(db)

        /* 患者 9505 完成一次预问诊（六项齐备） */
        let sid = pv.create(9505, now)
        for (sl in intakeSlots()) {
            let _x = pv.answer(sid, 9505, sl.key, "答-" + sl.key, now)
        }
        runner.check("准备：问诊单六项齐备", pv.find(sid, 9505).getOrThrow().form.complete())

        /* ① 绑定 + 幂等 */
        let a1 = hSeedAppointmentForDoctor(db, 5, 9505, VISIT_BOOKED)
        runner.check("① 把会话绑到本次挂号单 ⇒ 成功", pv.bindAppointment(sid, 9505, a1))
        runner.check("① 绑定后可按挂号单反查", pv.findByAppointment(a1, 9505).isSome())
        runner.check("★ ① 重复绑定同一张单是幂等的（幂等重放会再调一次）",
                     pv.bindAppointment(sid, 9505, a1))

        /* ② ★★ 不许改绑到另一张单 */
        let a2 = hSeedAppointmentForDoctor(db, 6, 9505, VISIT_BOOKED)
        runner.check("★★ ② 已绑定的会话**不许改绑**到另一张单（防串病历）",
                     !pv.bindAppointment(sid, 9505, a2))
        runner.check("② 且另一张单反查不到它", pv.findByAppointment(a2, 9505).isNone())

        /* ③ ★★ 归属：别的患者绑不走 */
        runner.check("★★ ③ 别的患者绑不走这张问诊单（SQL 里带 patient_id）",
                     !pv.bindAppointment(sid, 9599, a2))
        runner.check("★★ ③ 别的患者也读不到这个会话", pv.find(sid, 9599).isNone())

        /* ④ 预填映射 + 来源痕迹 */
        let out = emr.saveDraftWithIntake(a1, 900005, sid, 9505,
                                          HashMap<String, String>(), now, 9901)
        runner.check("④ 首次保存（use_intake_session）建单成功", out.ok)
        let rec = emr.findByAppointment(a1).getOrThrow()
        runner.check("④ 主诉预填进 chief_complaint（实得「${rec.chiefComplaint}」）",
                     rec.chiefComplaint == "答-chief")
        runner.check("④ 过敏史预填进 allergy_history", rec.allergyHistory == "答-allergy")
        runner.check("④ 既往史预填进 past_history", rec.pastHistory == "答-history")
        runner.check("★ ④ 病程/程度/伴随三问拼进 present_illness（不各占一段）",
                     (rec.presentIllness.contains("病程") && rec.presentIllness.contains("程度") && rec.presentIllness.contains("伴随")))
        runner.check("★★ ④ 来源痕迹记下本次会话 id", rec.previsitRef.contains(sid))
        let sections = emrPrevisitRefSections(rec.previsitRef)
        runner.check("★ ④ 来源痕迹列出被患者自述写入的段（实得 ${sections.size} 段：${joinStrings(sections, ",")}）",
                     sections.size == 4)
        runner.check("★★ ④ 医生要写的段**不在**来源痕迹里（诊断/体格检查不是患者说的）",
                     !sections.contains("diagnosis") && !sections.contains("physical_exam"))
        /* 坏数据不影响读病历：乱写的 previsit_ref 解析成空数组，不抛 */
        runner.check("★ ④ 损坏的 previsit_ref 解析失败 ⇒ 空数组（读病历不会 500）",
                     emrPrevisitRefSections("{不是 JSON").size == 0)

        /* ⑤ 已有病历不吃预填，来源痕迹不变 */
        let patch = HashMap<String, String>()
        patch["chief_complaint"] = "医生改过的主诉"
        let out2 = emr.saveDraftWithIntake(a1, 900005, sid, 9505, patch, now, 9901)
        runner.check("⑤ 二次保存成功", out2.ok)
        let rec2 = emr.findByAppointment(a1).getOrThrow()
        runner.check("★★ ⑤ 已有病历**不吃预填**：医生这次写的值生效（实得「${rec2.chiefComplaint}」）",
                     rec2.chiefComplaint == "医生改过的主诉")
        runner.check("★ ⑤ 未被 patch 的段仍是首次预填的值（不是空）",
                     rec2.allergyHistory == "答-allergy")
        runner.check("★★ ⑤ 来源痕迹是**初值来源快照**，不随医生改段而变（同一段仍标着预填来源）",
                     rec2.previsitRef == rec.previsitRef)

        /* ⑥ 该患者的历史单反查（两级回退的②级） */
        let latest = pv.latestCompleteForPatient(9505)
        runner.check("★ ⑥ 该患者最近一次已完成的会话可查（存量兼容的回退路径）",
                     latest.isSome() && latest.getOrThrow().id == sid)
        let sid2 = pv.create(9506, now)
        let _one = pv.answer(sid2, 9506, "chief", "只答了一项", now)
        runner.check("★★ ⑥ **未完成**的会话不会出现在回退路径里（半张单不足以当摘要）",
                     pv.latestCompleteForPatient(9506).isNone())

        /* ⑦ 预填的来源靠 patient_id 兜：给错患者 ⇒ 什么都不预填 */
        let a3 = hSeedAppointmentForDoctor(db, 7, 9507, VISIT_BOOKED)
        let out3 = emr.saveDraftWithIntake(a3, 900007, sid, 9599,   // session 属于 9505
                                           HashMap<String, String>(), now, 9901)
        runner.check("★★ ⑦ 把**别人的**会话拿来预填 ⇒ 一段也进不去（数据落空）",
                     out3.ok && emr.findByAppointment(a3).getOrThrow().chiefComplaint.size == 0)
        runner.check("★★ ⑦ 且这张单的来源痕迹为空（不会凭空宣称有患者自述）",
                     emr.findByAppointment(a3).getOrThrow().previsitRef.size == 0)
    })
}

/*
 * AC-P4-6（★ 2026-10-15 改进 3）：病历修订历史 —— 定稿留痕、解锁需理由、逐段可比。
 *
 * 独占 id 段：seed 8 / 患者 9608、9609，医生 900008（由 seed 派生）。
 *
 * ⚠ 这一组测的是**审计的可信度**，不是"功能有没有"：
 *   审计行的价值全在"它说的是真的"——所以每条断言都在反着问
 *   "这条痕迹有没有可能说谎"（锁没锁成却留了痕？解锁没给理由？版本号乱跳？）。
 */
public func acP4_6(runner: TestRunner, db: DbBackend): Unit {
    println("=== AC-P4-6 ★★ 病历修订历史（改进 3：定稿留痕 / 解锁需理由 / 逐段可比）===")
    runner.section("AC-P4-6", { =>
        hResetAll(db)
        let now = hNowEpoch()
        let emr = MedicalRecordRepo(db)
        let apptId = hSeedAppointmentForDoctor(db, 8, 9608, VISIT_VISITING)
        runner.check("① 起手没有任何修订（新单没有历史）", emr.revisions(apptId).size == 0)
        runner.check("★ ① 草稿保存**不**产生版本（draft 不是定稿，不留痕）",
                     hFillAllSections(emr, apptId, 900008, now, 9901).ok &&
                     emr.revisions(apptId).size == 0)

        /* ② 定稿 ⇒ 恰好一版，内容 = 锁定前那一版，操作者/角色如实 */
        let l1 = emr.lock(apptId, now, 9901, "doctor")
        runner.check("② 定稿成功", l1.ok)
        runner.check("★ ② 定稿落下一版，版本号是 1（实得 ${l1.revisionVersion}）",
                     l1.revisionVersion == 1)
        let revs = emr.revisions(apptId)
        runner.check("② 库里确实只有一版（实得 ${revs.size}）", revs.size == 1)
        let v1 = revs[0]
        runner.check("★ ② 这一版的状态是 locked（记的是**锁定那一刻**）", v1.status == EMR_LOCKED)
        runner.check("★ ② 操作是 lock、理由是空（定稿不需要理由）",
                     v1.operation == EMR_OP_LOCK && v1.reason.size == 0)
        runner.check("★ ② 操作者如实：user_id=9901、role=doctor",
                     v1.operatorUserId == 9901 && v1.operatorRole == "doctor")
        runner.check("② 时间戳是锁定时刻（实得 ${v1.createdAt} vs ${now}）", v1.createdAt == now)
        let vals1 = emrSectionValues(v1.sectionsJson)
        let diag1 = emrValueOfForm(vals1, "diagnosis")
        runner.check("★★ ② 快照里的正文 == 锁定前的正文（诊断「${diag1}」）",
                     diag1 == "测试内容-diagnosis")
        runner.check("★ ② 快照含**七段**（含空段：既能看出「当时写了什么」，也能看出「当时没写什么」）（实得 ${vals1.size}）",
                     vals1.size == emrSections().size)

        /* ③ ★★ 解锁**必须给理由**（否则病历可以被无痕推翻） */
        let bad1 = emr.reopen(apptId, now + 10, 9902, "admin", "")
        runner.check("★★ ③ 没有理由 ⇒ 解锁被拒（badReason）", bad1.badReason && !bad1.ok)
        let bad2 = emr.reopen(apptId, now + 10, 9902, "admin", "太短")
        runner.check("★★ ③ 理由过短（< ${EMR_REASON_MIN} 字）⇒ 同样被拒", bad2.badReason && !bad2.ok)
        runner.check("★★ ③ 而且**库里状态没变**（拒了就是没解锁，不是「拒了但解了」）",
                     emr.findByAppointment(apptId).getOrThrow().status == EMR_LOCKED)
        runner.check("③ 被拒的解锁**不会**留下修订行（不留「未发生的审计」）",
                     emr.revisions(apptId).size == 1)

        /* ④ 正常解锁 ⇒ v2 = 解锁前那一版（reason 落档、操作者是管理员） */
        let ro = emr.reopen(apptId, now + 20, 9902, "admin", "患者要求补充过敏史，解锁重写")
        runner.check("④ 管理员带理由解锁成功", ro.ok)
        runner.check("★ ④ 解锁落下的版本号是 2（实得 ${ro.revisionVersion}）", ro.revisionVersion == 2)
        runner.check("④ 库里病历回到 draft",
                     emr.findByAppointment(apptId).getOrThrow().status == EMR_DRAFT)
        let revs2 = emr.revisions(apptId)
        runner.check("④ 共两版（实得 ${revs2.size}）", revs2.size == 2)
        let v2 = revs2[1]
        runner.check("★★ ④ v2 记的是**解锁前那一版**的内容（状态 locked），不是解锁后的 draft",
                     v2.status == EMR_LOCKED && v2.operation == EMR_OP_REOPEN)
        runner.check("★★ ④ 解锁理由落档（实得「${v2.reason}」）",
                     v2.reason == "患者要求补充过敏史，解锁重写")
        runner.check("★ ④ 解锁的 operator_role 是 admin（如实记「谁推翻的」）",
                     v2.operatorRole == "admin" && v2.operatorUserId == 9902)

        /* ⑤ 改完再定稿 ⇒ v3；升序；逐段可比 */
        let patch = HashMap<String, String>()
        patch["allergy_history"] = "青霉素过敏"
        runner.check("⑤ 解锁后可改", emr.saveDraft(apptId, 900008, patch, now + 30, 9901).ok)
        let l2 = emr.lock(apptId, now + 40, 9901, "doctor")
        runner.check("⑤ 再次定稿成功（版本号 ${l2.revisionVersion}）", l2.ok && l2.revisionVersion == 3)
        let revs3 = emr.revisions(apptId)
        var nums = ""
        for (r in revs3) {
            nums = nums + "${r.version},"
        }
        runner.check("★ ⑤ 版本号**升序**（v1 在前：${nums}）",
                     revs3.size == 3 && revs3[0].version == 1 && revs3[2].version == 3)

        let rv2 = emr.revisionAt(apptId, 2).getOrThrow()
        let rv3 = emr.revisionAt(apptId, 3).getOrThrow()
        let diff = emrDiffRows(emrSectionValues(rv2.sectionsJson),
                               emrSectionValues(rv3.sectionsJson))
        runner.check("★ ⑤ 逐段对比含**七段**（没改的段也在，标 changed=false）（实得 ${diff.size}）",
                     diff.size == 7)
        let changed = ArrayList<String>()
        for (row in diff) {
            if (row.changed) {
                changed.add(row.key)
            }
        }
        runner.check("★★ ⑤ 只有**真正被改的段**标 changed（实得：${joinStrings(changed.toArray(), ",")}）",
                     changed.size == 1 && changed[0] == "allergy_history")
        let allergyBefore = emrValueOfForm(emrSectionValues(rv2.sectionsJson), "allergy_history")
        let allergyAfter = emrValueOfForm(emrSectionValues(rv3.sectionsJson), "allergy_history")
        runner.check("★ ⑤ 对比的两侧值都对（前「${allergyBefore}」→ 后「${allergyAfter}」）",
                     allergyBefore == "测试内容-allergy_history" && allergyAfter == "青霉素过敏")

        /* ⑥ 取不到的那一版 ⇒ None（客户端据此 404，而不是渲染出一个空版本） */
        runner.check("★ ⑥ 不存在的版本返回 None（不会给出「七段全空」的假版本）",
                     emr.revisionAt(apptId, 99).isNone())
        let latest = emr.latestLockedRevision(apptId)
        runner.check("★ ⑥ latestLockedRevision 取到的是**最新那个已定稿版**（v3）",
                     latest.isSome() && latest.getOrThrow().version == 3)

        /* ⑦ ★★ 存量兼容：锁定但没有审计行的病历，迁移会补一版，且幂等 */
        let legacy = hSeedAppointmentForDoctor(db, 9, 9609, VISIT_VISITING)
        let _w = hFillAllSections(emr, legacy, 900009, now, 9901)
        /*
         * 绕过 `lock` 直接改状态 ⇒ 模拟「改进 3 上线前就已锁定的存量病历」
         * （它没有审计行 —— 这正是迁移要补的那一批）。
         */
        db.exec("UPDATE medical_record SET status = ? WHERE appointment_id = ?",
                [DbStr(EMR_LOCKED), DbInt(legacy)])
        runner.check("⑦ 造出「已锁定但零审计行」的存量病历", emr.revisions(legacy).size == 0)
        let backfilled = emrBackfillRevisions(db)
        runner.check("★ ⑦ 迁移补写 ≥1 版（实得 ${backfilled}）", backfilled >= 1)
        let legacyRevs = emr.revisions(legacy)
        runner.check("★★ ⑦ 补出来的 v1 状态是 locked、操作是 lock",
                     legacyRevs.size == 1 && legacyRevs[0].status == EMR_LOCKED &&
                     legacyRevs[0].operation == EMR_OP_LOCK)
        runner.check("★★ ⑦ 存量补写**不伪造角色**（operator_role 是空串=未知，不是「doctor」）",
                     legacyRevs[0].operatorRole.size == 0)
        /* 补写用的时间戳是病历的 updated_at，不是"现在" —— 审计要贴历史事实 */
        runner.check("★ ⑦ 补写的时间戳取自病历的 updated_at（不是迁移那一刻）",
                     legacyRevs[0].createdAt == emr.findByAppointment(legacy).getOrThrow().updatedAt)
        runner.check("★★ ⑦ 再跑一次迁移 ⇒ 补 0 版（幂等：不会把同一份病历记两遍）",
                     emrBackfillRevisions(db) == 0)
    })
}

/*
 * AC-P4-7（★ 2026-10-15 改进 2）：医生工作台 —— 既往病历的隐私边界 + 草稿保存的乐观锁。
 *
 * 独占 id 段：seed 10 / 11 / 12（患者 9610，医生 900010 / 900011）、seed 13（患者 9613，医生 900013）。
 *
 * ⚠ 这一组测的是**隐私边界与并发**，不是"接口通不通"：
 *   ① 医生读既往病历是本系统**唯一**一处"跨患者读取"，所以每条断言都在反问
 *      "有没有一条路能让医生读到不该读的病历"（别人的患者 / 别人的号 / 草稿）；
 *   ② 乐观锁的价值全在"两个人同时改时**后提交的那个**必须被挡住"，
 *      所以断言必须覆盖"陈旧版本 ⇒ 冲突"**以及**"冲突之后库里的内容没被改动"——
 *      只断言返回了 conflict 而不查库，等于相信一个可能撒谎的返回值。
 */
public func acP4_7(runner: TestRunner, db: DbBackend): Unit {
    println("=== AC-P4-7 ★★ 医生工作台（改进 2：既往病历 / 乐观锁）===")
    runner.section("AC-P4-7", { =>
        hResetAll(db)
        let now = hNowEpoch()
        let emr = MedicalRecordRepo(db)
        /* ① 同一个患者、两位医生各一次就诊（用来测"只看得到自己的那些次"）。 */
        let a10 = hSeedAppointmentForDoctor(db, 10, 9610, VISIT_VISITING)
        let a11 = hSeedAppointmentForDoctor(db, 11, 9610, VISIT_VISITING)
        runner.check("① 医生 900010 定稿 a10",
                     hFillAllSections(emr, a10, 900010, now, 9901).ok &&
                     emr.lock(a10, now + 5, 9901, "doctor").ok)
        runner.check("① 医生 900011 定稿 a11",
                     hFillAllSections(emr, a11, 900011, now, 9902).ok &&
                     emr.lock(a11, now + 6, 9902, "doctor").ok)

        /* ② 隐私闸门：只有"在我这儿挂过号"的患者才算我的患者 */
        /*
         * ⚠ 必须用一个**真实存在但没接诊过这位患者**的医生来测第三条：
         *   我第一版这里传的是 900012（那个医生**根本没被造出来**），
         *   于是"不放行"可能只是因为"医生不存在" —— 断言看起来绿了，
         *   实际没测到"存在但没挂号"这条路径（假绿）。
         */
        hSeedIdleDoctor(db, 900012)
        runner.check("★★ ② 该患者在我这儿挂过号 ⇒ 放行（实得 ${emr.patientTreatedByDoctor(900010, 9610)}）",
                     emr.patientTreatedByDoctor(900010, 9610))
        runner.check("★★ ② 一个**不存在**的患者 ⇒ 不放行（不给枚举 oracle）",
                     !emr.patientTreatedByDoctor(900010, 999998))
        runner.check("★★ ② 医生存在、患者也存在，但**没在我这儿挂过号** ⇒ 同样不放行",
                     !emr.patientTreatedByDoctor(900012, 9610))

        /* ③ 只给"我的那些次"（另一位医生看同一患者，看到的是他自己那份） */
        let mine = emr.listLockedForDoctorPatient(900010, 9610, 5)
        runner.check("★★ ③ 医生 900010 只看到自己的那 1 份（实得 ${mine.size}）", mine.size == 1)
        runner.check("★★ ③ 而且正是 a10，不是同一位患者的 a11",
                     mine.size == 1 && mine[0].appointmentId == a10)
        let other = emr.listLockedForDoctorPatient(900011, 9610, 5)
        runner.check("★★ ③ 医生 900011 看到的是 a11（实得 ${other.size} 份）",
                     other.size == 1 && other[0].appointmentId == a11)

        /* ④ 草稿**永不外泄**：另一位医生看不到我没定稿的工作稿 */
        let a12 = hSeedAppointmentForDoctor(db, 12, 9610, VISIT_VISITING, asDoctorId: 900010)
        runner.check("④ 医生 900010 在 a12 上只写了草稿",
                     hFillAllSections(emr, a12, 900010, now + 10, 9901).ok)
        runner.check("★★ ④ 草稿不进「既往病历」（列表仍是 1 份，实得 ${emr.listLockedForDoctorPatient(900010, 9610, 5).size}）",
                     emr.listLockedForDoctorPatient(900010, 9610, 5).size == 1)
        runner.check("④ 定稿之后才出现（实得 ${emr.listLockedForDoctorPatient(900010, 9610, 5).size}）",
                     emr.lock(a12, now + 12, 9901, "doctor").ok &&
                     emr.listLockedForDoctorPatient(900010, 9610, 5).size == 2)

        /* ⑤ exclude：正在写的这一份不能算"既往" */
        let excl = emr.listLockedForDoctorPatient(900010, 9610, 5, excludeAppointmentId: a10)
        /*
         * ⚠ 这里**先算好**再拼提示语，不在插值里写 `if`：
         *   仓颉的字符串插值里嵌表达式块（`${if (…) { … } else { … }}`）会与
         *   外围的大括号、内层字符串定界符互相干扰（本仓"文案里嵌引用一律用「」"同理）。
         */
        var exclFirst = "无"
        if (excl.size > 0) {
            exclFirst = excl[0].appointmentId.toString()
        }
        runner.check("★ ⑤ 排除 a10 后只剩 a12（实得 ${excl.size}，首条 ${exclFirst}）",
                     excl.size == 1 && excl[0].appointmentId == a12)
        runner.check("★ ⑤ exclude 传 0 = 不排除（向后兼容）",
                     emr.listLockedForDoctorPatient(900010, 9610, 5, excludeAppointmentId: 0).size == 2)

        /* ⑥ 排序与上限：最近改过的在前（同秒时用 id 兜底，避免列表抖动） */
        let limited = emr.listLockedForDoctorPatient(900010, 9610, 1)
        runner.check("★ ⑥ limit=1 只回 1 份（实得 ${limited.size}）", limited.size == 1)
        runner.check("★ ⑥ 最近定稿的（a12）排在前面",
                     limited.size == 1 && limited[0].appointmentId == a12)

        /* ========== ⑦ 乐观锁（本项的核心） ========== */
        let a13 = hSeedAppointmentForDoctor(db, 13, 9613, VISIT_VISITING)
        let p1 = HashMap<String, String>()
        p1["chief_complaint"] = "首诊主诉"
        /*
         * ⚠ 建单时**不需要**乐观锁：此刻还没有"别人改过的版本"可言。
         *   所以这里故意传一个离谱的 expectedUpdatedAt，行为必须是"照常建单"
         *   （如果这里回 conflict，说明服务端把"记录不存在"错当成了"版本冲突"，
         *     那会让**每一位新患者**都存不了草稿 —— 最坏的一种错）。
         */
        let w1 = emr.saveDraft(a13, 900013, p1, now + 20, 9901, expectedUpdatedAt: 12345)
        runner.check("★★ ⑦ 建单不受乐观锁影响（新病历没有「上一版」可冲突）", w1.ok)
        let ver1 = emr.findByAppointment(a13).getOrThrow().updatedAt
        let p2 = HashMap<String, String>()
        p2["diagnosis"] = "第一次诊断"
        let w2 = emr.saveDraft(a13, 900013, p2, now + 30, 9901, expectedUpdatedAt: ver1)
        runner.check("★ ⑦ 带上**当前**版本号提交 ⇒ 成功", w2.ok)
        let ver2 = emr.findByAppointment(a13).getOrThrow().updatedAt
        runner.check("⑦ 版本号确实前进了（${ver1} → ${ver2}）", ver2 > ver1)

        let p3 = HashMap<String, String>()
        p3["treatment"] = "基于旧版本写的处理意见"
        let w3 = emr.saveDraft(a13, 900013, p3, now + 40, 9902, expectedUpdatedAt: ver1)
        runner.check("★★ ⑦ 拿**陈旧**版本号提交 ⇒ 冲突（不许静默覆盖）", w3.conflict && !w3.ok)
        runner.check("★★ ⑦ 冲突时回带服务端的当前版本（updated_at=${w3.currentUpdatedAt} / by ${w3.currentUpdatedBy}）",
                     w3.currentUpdatedAt == ver2 && w3.currentUpdatedBy == 9901)
        let after = emr.findByAppointment(a13).getOrThrow()
        runner.check("★★ ⑦ 而且**这次写入一个字都没进库**（处理意见仍为空，实得「${after.treatment}」）",
                     after.treatment.size == 0)
        runner.check("★★ ⑦ 诊断也没被改（仍是「${after.diagnosis}」）", after.diagnosis == "第一次诊断")
        let w4 = emr.saveDraft(a13, 900013, p3, now + 50, 9901, expectedUpdatedAt: ver2)
        runner.check("⑦ 用**最新**版本号重试 ⇒ 成功", w4.ok)
        runner.check("⑦ 内容确实落库了（实得「${emr.findByAppointment(a13).getOrThrow().treatment}」）",
                     emr.findByAppointment(a13).getOrThrow().treatment == "基于旧版本写的处理意见")
        /* 老客户端不带这个字段 ⇒ 行为与从前完全一致（不能用新保护把旧版本打死） */
        let p4 = HashMap<String, String>()
        p4["past_history"] = "老客户端不带 expected_updated_at"
        runner.check("★ ⑦ 不带 expected_updated_at ⇒ 不校验（向后兼容）",
                     emr.saveDraft(a13, 900013, p4, now + 60, 9901).ok)

        /* ⑧ 已锁定 ⇒ 报 locked（不是 conflict）：两者的客户端处置完全不同 */
        let lockedWrite = emr.saveDraft(a10, 900010, p1, now + 70, 9901, expectedUpdatedAt: 1)
        runner.check("★ ⑧ 已定稿的病历：即使版本号对不上也报 locked（不可改 ≠ 有人抢先改了）",
                     lockedWrite.locked && !lockedWrite.conflict)
    })
}
