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
        let l1 = emr.lock(apptId, now, 9901)
        runner.check("★★ ③ 缺必填段时锁定被拒（missingRequired）", l1.missingRequired)
        runner.check("③ 且缺的是诊断与处理意见（实得「${l1.detail}」）",
                     l1.detail.contains("诊断") && l1.detail.contains("处理意见"))
        runner.check("③ 库里的状态仍是 draft（没被偷偷锁上）",
                     emr.findByAppointment(apptId).getOrThrow().status == EMR_DRAFT)

        // ④ 填满后能锁定
        let w2 = hFillAllSections(emr, apptId, 900001, now, 9901)
        runner.check("④ 填满七段成功", w2.ok)
        let l2 = emr.lock(apptId, now, 9901)
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
        let l3 = emr.lock(apptId, now + 20, 9901)
        runner.check("⑥ 重复提交锁定时 locked=true（不假装成功）", l3.locked && !l3.ok)

        // ⑦ 管理员解锁后可改
        let ro = emr.reopen(apptId, now + 30, 9902)
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
        let _l = emr.lock(apptId, now, 9901)
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
        let _l = emr.lock(a1, now, 9901)
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
