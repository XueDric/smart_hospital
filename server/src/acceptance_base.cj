package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * ===== acceptance_base.cj —— AC-BASE-1…3：基础数据域（科室/医生）=====
 *
 * 这三个用例守的是 ADR-0001 rev.7 记下的那条边界：
 * 「department/doctor 没有写入端点，靠人工 SQL 维护」——本阶段把它还清。
 *
 * 用例设计上有一个刻意的倾向：**多数断言是"拒绝"而不是"成功"**。
 * 因为 CRUD 的"能建能改"几乎不可能写错，而**约束**（同名/孤儿医生/删有引用的）
 * 才是真正会出错、且事后无法用代码修的地方。
 */

/* ---------- AC-BASE-1：科室 CRUD 与唯一性 ---------- */
public func acBase1(runner: TestRunner, db: DbBackend): Unit {
    println("=== AC-BASE-1 ★★ 科室：能建能改，且**同名必须被拒** ===")
    let dept = DepartmentRepo(db)
    let now = hNowEpoch()

    /* 造一个干净起点：只清本用例的 id 段（9_1xx），不碰别的用例。 */
    db.exec("DELETE FROM doctor WHERE department_id >= 910000 AND department_id < 920000",
            Array<DbValue>())
    db.exec("DELETE FROM department WHERE id >= 910000 AND id < 920000", Array<DbValue>())

    let d = Department()
    d.name = "AC测试内科"
    d.code = "ACBASE1"
    d.location = "门诊楼 3 层"
    d.sort = 5
    let c1 = dept.create(d, now)
    runner.check("① 建科室成功", c1.ok)
    runner.check("① 且返回了落库的 id（${c1.id}）", c1.id >= 910000 || c1.id > 0)

    match (dept.findById(c1.id)) {
        case Some(saved) =>
            runner.check("① 回读字段一致（名字/编码/位置/排序）",
                         saved.name == "AC测试内科" && saved.code == "ACBASE1" &&
                         saved.location == "门诊楼 3 层" && saved.sort == 5)
            runner.check("① 新建默认启用（enabled = true）", saved.enabled)
        case None =>
            runner.check("① 回读科室（不该找不到）", false)
    }

    /*
     * ★★ 同名必须被拒 —— 这是本用例最要紧的一条。
     * 理由（写在 schema.cj 的 uk_department_name 注释里）：
     *   `triage.cj` 用 `WHERE name = ?` 判断"该科室是否可挂号"，
     *   同名会让这条判断**分裂**。所以约束必须由**数据库**兜底。
     */
    match (dept.findById(c1.id)) {
        case Some(saved) =>
            let dup = Department()
            dup.name = saved.name
            dup.code = "ACBASE1DUP"
            let r = dept.create(dup, now)
            runner.check("★★ ② 同名科室被拒（duplicate）", r.duplicate)
            runner.check("★★ ② 且指出冲突字段是 name（不是笼统报错）",
                         r.conflictField == "name")
            /* ⚠ 用 id 计数，而且**直接 query** 而不是 `hTableRowCount`：
            后者收的是**表名**，我把完整 SQL 传进去过 —— 实测把 accept 打崩
            （已给它改名并写明参数性质，见 acceptance.cj 的注释）。 */
            runner.check("② 且确实没进库（该 id 仍只有 1 行）",
                         hScalarCount(db, "SELECT COUNT(*) FROM department WHERE id = ${c1.id}") == 1)
        case None =>
            runner.check("② 同名被拒（前置：找不到刚建的科室）", false)
    }

    /* 同编码也必须被拒（`uk_department_code`）。 */
    match (dept.findById(c1.id)) {
        case Some(saved) =>
            let dup2 = Department()
            dup2.name = "AC测试内科B"
            dup2.code = saved.code
            let r2 = dept.create(dup2, now)
            runner.check("★ ② 同编码科室被拒", r2.duplicate)
            runner.check("★ ② 且指出冲突字段是 code", r2.conflictField == "code")
        case None => runner.check("② 同编码被拒（前置失败）", false)
    }

    /* ③ 改名成功，且 **`created_at` 不被篡改**。 */
    match (dept.findById(c1.id)) {
        case Some(saved) =>
            let before = saved.createdAt
            let edit = Department()
            edit.name = "AC测试内科（改名后）"
            edit.code = saved.code
            edit.location = "门诊楼 4 层"
            edit.sort = 6
            edit.enabled = false
            let u = dept.update(c1.id, edit)
            runner.check("③ 改科室成功", u.ok)
            match (dept.findById(c1.id)) {
                case Some(after) =>
                    runner.check("③ 字段已更新（名字/位置/排序/启用位）",
                                 after.name == "AC测试内科（改名后）" &&
                                 after.location == "门诊楼 4 层" && after.sort == 6 &&
                                 !after.enabled)
                    /*
                     * ★ 这是一条**容易漏**的断言：`created_at` 是"什么时候建的"，
                     *   改科室时若把它一起写回去（或忘了保留），历史就被篡改了。
                     *   而这类损坏在数据上看不出来 —— 只能靠断言钉住。
                     */
                    runner.check("★★ ③ created_at **未被篡改**（它是历史，不该随编辑变）",
                                 after.createdAt == before)
                case None => runner.check("③ 改后回读", false)
            }
        case None => runner.check("③ 改科室（前置失败）", false)
    }

    /* ④ 参数校验。 */
    let badName = Department()
    badName.name = "   "
    badName.code = "ACBLANK"
    runner.check("④ 空白名字被拒并说明原因",
                 dept.create(badName, now).invalid)

    let badCode = Department()
    badCode.name = "AC非法编码科"
    badCode.code = "有中文"
    let bc = dept.create(badCode, now)
    runner.check("④ 编码含中文被拒（编码是给程序看的稳定标识）", bc.invalid)

    let ctrl = Department()
    ctrl.name = "AC换行\n科室"
    ctrl.code = "ACCTRL"
    let cc = dept.create(ctrl, now)
    runner.check("★ ④ 名字含控制字符被拒（换行会破坏 JSON/日志的单行假设）", cc.invalid)

    let longName = Department()
    longName.name = hRepeatChar("长", 65)
    longName.code = "ACLONG"
    let ln = dept.create(longName, now)
    runner.check("④ 名字超 64 字被拒", ln.invalid)

    /* ⑤ 删不存在的 ⇒ notFound（而不是静默成功）。 */
    let gone = dept.remove(919999, false)
    runner.check("⑤ 删不存在的科室 ⇒ notFound（不静默当成功）", gone.notFound)

    /* 清理 */
    db.exec("DELETE FROM department WHERE id >= 910000 AND id < 920000", Array<DbValue>())
}

/* ---------- AC-BASE-2：医生 CRUD 与"不许有孤儿医生" ---------- */
public func acBase2(runner: TestRunner, db: DbBackend): Unit {
    println("=== AC-BASE-2 ★★ 医生：必须属于存在的科室（不许产生孤儿医生）===")
    let dept = DepartmentRepo(db)
    let doc = DoctorRepo(db)
    let now = hNowEpoch()

    db.exec("DELETE FROM doctor WHERE id >= 920000 AND id < 930000", Array<DbValue>())
    db.exec("DELETE FROM department WHERE id >= 920000 AND id < 930000", Array<DbValue>())

    let d = Department()
    d.name = "ACBASE2外科"
    d.code = "ACBASE2"
    let cd = dept.create(d, now)
    runner.check("① 前置：建一个科室", cd.ok)
    /* 需要一个**已停用**的科室来测"不能往停用科室挂医生"。 */
    let dOff = Department()
    dOff.name = "ACBASE2停用科"
    dOff.code = "ACBASE2OFF"
    dOff.enabled = false
    let cdOff = dept.create(dOff, now)
    runner.check("① 前置：建一个**已停用**的科室", cdOff.ok)

    /* ② ★★ 孤儿医生必须被拒（本仓无外键，靠应用层守）。 */
    let orphan = Doctor()
    orphan.name = "孤儿医生"
    orphan.departmentId = 929999
    let ro = doc.create(orphan, now)
    runner.check("★★ ② 科室不存在 ⇒ 建医生被拒（**不许产生孤儿医生**）", ro.invalid)
    runner.check("② 且说明原因（含科室 id，便于排查）",
                 ro.detail.contains("科室不存在"))

    let toOff = Doctor()
    toOff.name = "挂停用科的医生"
    toOff.departmentId = cdOff.id
    let ro2 = doc.create(toOff, now)
    runner.check("★ ② 往**已停用**科室挂医生也被拒（否则会出现自相矛盾的状态）",
                 ro2.invalid)

    /* ③ 正常建医生。 */
    let doc1 = Doctor()
    doc1.name = "AC测试医生甲"
    doc1.departmentId = cd.id
    doc1.title = "主治医师"
    doc1.specialty = "普外"
    let rc = doc.create(doc1, now)
    runner.check("③ 建医生成功", rc.ok)
    match (doc.findById(rc.id)) {
        case Some(saved) =>
            runner.check("③ 回读字段一致",
                         saved.name == "AC测试医生甲" && saved.departmentId == cd.id &&
                         saved.title == "主治医师" && saved.specialty == "普外")
        case None => runner.check("③ 回读医生", false)
    }

    /* ④ 列表按科室过滤。 */
    let inDept = doc.listAll(cd.id)
    runner.check("④ 按科室过滤只返回该科室的医生（实得 ${inDept.size} 位）",
                 inDept.size >= 1)
    /* ⚠ `foreign` 是仓颉关键字（实测报 `expected identifier or pattern after var`）⇒ 换名。 */
    var mismatched = 0
    for (x in inDept) {
        if (x.departmentId != cd.id) {
            mismatched = mismatched + 1
        }
    }
    runner.check("④ 且**没有**混入其它科室的医生", mismatched == 0)

    /* ⑤ 名字校验同样生效。 */
    let badDoc = Doctor()
    badDoc.name = ""
    badDoc.departmentId = cd.id
    runner.check("⑤ 医生空名被拒", doc.create(badDoc, now).invalid)

    /* ⑥ 删不存在的 ⇒ notFound。 */
    runner.check("⑥ 删不存在的医生 ⇒ notFound", doc.remove(929999, false).notFound)

    /* 清理 */
    db.exec("DELETE FROM doctor WHERE id >= 920000 AND id < 930000", Array<DbValue>())
    db.exec("DELETE FROM department WHERE id >= 920000 AND id < 930000", Array<DbValue>())
}

/* ---------- AC-BASE-3：删除的两种语义（引用保护 vs 软删） ---------- */
public func acBase3(runner: TestRunner, db: DbBackend): Unit {
    println("=== AC-BASE-3 ★★ 删除：有引用就拒，force 才软删（**绝不硬删**）===")
    let dept = DepartmentRepo(db)
    let doc = DoctorRepo(db)
    let now = hNowEpoch()

    db.exec("DELETE FROM appointment WHERE department_id >= 930000 AND department_id < 940000",
            Array<DbValue>())
    db.exec("DELETE FROM schedule WHERE department_id >= 930000 AND department_id < 940000",
            Array<DbValue>())
    db.exec("DELETE FROM doctor WHERE department_id >= 930000 AND department_id < 940000",
            Array<DbValue>())
    db.exec("DELETE FROM department WHERE id >= 930000 AND id < 940000", Array<DbValue>())

    let d = Department()
    d.name = "ACBASE3有引用的科"
    d.code = "ACBASE3"
    let cd = dept.create(d, now)
    runner.check("① 前置：建科室", cd.ok)

    let doc1 = Doctor()
    doc1.name = "ACBASE3医生"
    doc1.departmentId = cd.id
    let rd = doc.create(doc1, now)
    runner.check("① 前置：该科室下有 1 位医生", rd.ok)

    /*
     * ★★ 核心：默认删除**必须被拒**，且说清"被谁引用"。
     */
    let blocked = dept.remove(cd.id, false)
    runner.check("★★ ② 科室下有医生 ⇒ 默认删除被拒（inUse）", blocked.inUse)
    runner.check("★★ ② 且说清被谁引用（不是笼统「不能删」）",
                 blocked.inUseBy.contains("医生"))
    runner.check("★★ ② 且**库里那行还在**（拒绝是真的拒绝，不是删了再报错）",
                 hScalarCount(db, "SELECT COUNT(*) FROM department WHERE id = ${cd.id}") == 1)

    /*
     * ★ 医生侧：被排班/挂号引用时同样拒。
     * ⚠ 这里刻意用**真实**的 schedule + appointment 行（而不是只看计数），
     *   因为"计数对不对"和"引用关系对不对"是两件事。
     */
    db.exec("INSERT INTO schedule (id, doctor_id, department_id, work_date, period, " +
            "total_num, remain_num, version, enabled, created_at) " +
            "VALUES (930001, ?, ?, '2027-01-01', 'AM', 5, 5, 0, 1, 0)",
            [DbInt(rd.id), DbInt(cd.id)])
    let docBlocked = doc.remove(rd.id, false)
    runner.check("★★ ③ 医生名下有排班 ⇒ 默认删除被拒", docBlocked.inUse)
    runner.check("③ 且说清是排班", docBlocked.inUseBy.contains("排班"))

    /* ★★ 病历引用是最要紧的一条：作者必须可解析。 */
    db.exec("INSERT INTO appointment (id, schedule_id, patient_id, doctor_id, department_id, " +
            "visit_date, period, seq_no, status, slot_restored, created_at) " +
            "VALUES (930001, 930001, 1, ?, ?, '2027-01-01', 'AM', 1, 'done', 1, 0)",
            [DbInt(rd.id), DbInt(cd.id)])
    db.exec("INSERT INTO medical_record (appointment_id, patient_id, doctor_id, " +
            "chief_complaint, present_illness, past_history, allergy_history, " +
            "physical_exam, diagnosis, treatment, status, updated_by, created_at, updated_at) " +
            "VALUES (930001, 1, ?, 'x', '', '', '', '', 'd', 't', 'locked', 0, 0, 0)",
            [DbInt(rd.id)])
    /* 先把排班删掉，让"病历"成为唯一剩下的引用 —— 这样能**单独**验证病历那条。 */
    db.exec("DELETE FROM schedule WHERE id = 930001", Array<DbValue>())
    let recBlocked = doc.remove(rd.id, false)
    runner.check("★★★ ④ 医生名下有**病历** ⇒ 默认删除被拒（临床留档的作者必须可解析）",
                 recBlocked.inUse)
    runner.check("★★★ ④ 且说清是病历（这条损坏事后无法用代码修）",
                 recBlocked.inUseBy.contains("病历"))

    /*
     * ★★ ⑤ `force=true` ⇒ **软删**（不是硬删）。
     *   两条断言缺一不可：① 行还在；② enabled 变 0。
     *   只断言①会让"完全没动"也通过（假绿）。
     */
    let forced = doc.remove(rd.id, true)
    runner.check("★★ ⑤ force=true 时删除成功", forced.ok)
    runner.check("★★ ⑤ **行仍在库里**（软删；历史挂号/病历还能解析出医生名）",
                 hScalarCount(db, "SELECT COUNT(*) FROM doctor WHERE id = ${rd.id}") == 1)
    match (doc.findById(rd.id)) {
        case Some(after) =>
            runner.check("★★ ⑤ 且 enabled 已置 0（证明真的动了，不是「什么都没做」）",
                         !after.enabled)
        case None =>
            runner.check("★★ ⑤ 软删后仍应能查到该医生", false)
    }

    /* ★ ⑥ 科室 force 时，其下医生一并停用（避免"科室停了医生还能排班"）。 */
    db.exec("UPDATE doctor SET enabled = 1 WHERE id = ?", [DbInt(rd.id)])
    let fdept = dept.remove(cd.id, true)
    runner.check("★ ⑥ 科室 force=true ⇒ 软删成功", fdept.ok)
    match (dept.findById(cd.id)) {
        case Some(after) =>
            runner.check("★ ⑥ 科室 enabled = 0（行保留）", !after.enabled)
        case None => runner.check("★ ⑥ 科室软删后仍应存在", false)
    }
    match (doc.findById(rd.id)) {
        case Some(afterDoc) =>
            runner.check("★★ ⑥ 且该科室下的医生**也**被停用（否则状态自相矛盾）",
                         !afterDoc.enabled)
        case None => runner.check("★ ⑥ 医生应仍在", false)
    }

    /* 清理 */
    db.exec("DELETE FROM medical_record WHERE appointment_id = 930001", Array<DbValue>())
    db.exec("DELETE FROM appointment WHERE id = 930001", Array<DbValue>())
    db.exec("DELETE FROM doctor WHERE department_id >= 930000 AND department_id < 940000",
            Array<DbValue>())
    db.exec("DELETE FROM department WHERE id >= 930000 AND id < 940000", Array<DbValue>())
}
