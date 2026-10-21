/*
 * SPDX-License-Identifier: MIT
 *
 * http_p4.cj —— P4 接口层：电子病历 + 接诊队列 + 运营看板
 * 路由仍由 http_app.cj 的 buildHospitalRouter 统一注册，本文件只提供 registerP4Routes。
 */

package qingzhou

import std.collection.*
import stdx.encoding.json.*

/* 病历 JSON */

/* 病历对外形状。patient_id / doctor_id 原样给出（只给当事人看，越权一律 404）。
 * 运营看板是跨患者聚合，那边只出计数、绝不出任何 id。 */
func medicalRecordJson(m: MedicalRecord, includeSections: Bool): JsonObject {
    let o = JsonObject()
    o.put("id", JsonInt(m.id))
    o.put("appointment_id", JsonInt(m.appointmentId))
    o.put("patient_id", JsonInt(m.patientId))
    o.put("doctor_id", JsonInt(m.doctorId))
    o.put("status", JsonString(m.status))
    o.put("locked", JsonBool(m.isLocked()))
    o.put("filled", JsonInt(m.filledCount()))
    o.put("total_sections", JsonInt(emrSections().size))
    o.put("complete", JsonBool(m.complete()))
    o.put("updated_by", JsonInt(m.updatedBy))
    o.put("created_at", JsonInt(m.createdAt))
    o.put("updated_at", JsonInt(m.updatedAt))
    /* version 直接取 updated_at：服务端乐观锁令牌就是它，相等的 version 即同一版；
     * 严格递增由 MedicalRecordRepo.emrNextStamp 保证。 */
    o.put("version", JsonInt(m.updatedAt))
    /* 提交锁定还缺哪几段（空数组 = 可以提交）。 */
    let miss = ArrayList<JsonValue>()
    for (x in m.missingRequired()) {
        miss.add(JsonString(x))
    }
    o.put("missing_required", JsonArray(miss.toArray()))
    /* 七段正文按需给出（includeSections）：列表接口不给正文，只给进度。 */
    if (includeSections) {
        let arr = ArrayList<JsonValue>()
        for (s in emrSections()) {
            let e = JsonObject()
            e.put("key", JsonString(s.key))
            e.put("label", JsonString(s.label))
            e.put("value", JsonString(m.get(s.key)))
            e.put("max_len", JsonInt(s.maxLen))
            e.put("required_to_lock", JsonBool(s.requiredToLock))
            arr.add(e)
        }
        o.put("sections", JsonArray(arr.toArray()))
        /* 预填来源痕迹 {session_id, sections, at}：只在给正文时给，列表接口不需要。
         * 以嵌套对象返回（不做 JSON-in-string）；坏数据解析失败就不给该字段，不猜、不 500。 */
        if (m.previsitRef.size > 0) {
            try {
                o.put("previsit_ref", JsonValue.fromStr(m.previsitRef))
            } catch (e: Exception) {
                ()
            }
        }
    }
    return o
}

/* 修订历史的出站形状：列表项不带正文，详情才带（一次就诊可能有几十版）。
 * 详情的 sections 与 medicalRecordJson().sections 同形状，客户端复用渲染。 */
func revisionItemJson(r: MedicalRecordRevision): JsonObject {
    let o = JsonObject()
    o.put("version", JsonInt(r.version))
    o.put("status", JsonString(r.status))
    o.put("operation", JsonString(r.operation))
    o.put("reason", JsonString(r.reason))
    o.put("operator_user_id", JsonInt(r.operatorUserId))
    /* operator_role 可能是空串：存量补写的那一版没有该历史信息，空串表示未知。 */
    o.put("operator_role", JsonString(r.operatorRole))
    o.put("created_at", JsonInt(r.createdAt))
    return o
}

/* 某一版的详情（带正文）。 */
func revisionDetailJson(r: MedicalRecordRevision): JsonObject {
    let o = revisionItemJson(r)
    o.put("record_id", JsonInt(r.recordId))
    o.put("appointment_id", JsonInt(r.appointmentId))
    let vals = emrSectionValues(r.sectionsJson)
    let arr = ArrayList<JsonValue>()
    for (s in emrSections()) {
        var text = ""
        match (vals.get(s.key)) {
            case Some(v) => text = v
            case None => ()
        }
        let e = JsonObject()
        e.put("key", JsonString(s.key))
        e.put("label", JsonString(s.label))
        e.put("value", JsonString(text))
        e.put("max_len", JsonInt(s.maxLen))
        arr.add(e)
    }
    o.put("sections", JsonArray(arr.toArray()))
    return o
}

/* 两版的逐段对比（七段都在，顺序 = emrSections() 的临床顺序）。 */
func revisionDiffJson(left: MedicalRecordRevision, right: MedicalRecordRevision): JsonObject {
    let o = JsonObject()
    o.put("appointment_id", JsonInt(right.appointmentId))
    o.put("left", revisionItemJson(left))
    o.put("right", revisionItemJson(right))
    o.put("status_changed", JsonBool(left.status != right.status))
    let arr = ArrayList<JsonValue>()
    var changed: Int64 = 0
    for (row in emrDiffRows(emrSectionValues(left.sectionsJson),
                            emrSectionValues(right.sectionsJson))) {
        let e = JsonObject()
        e.put("key", JsonString(row.key))
        e.put("label", JsonString(row.label))
        e.put("changed", JsonBool(row.changed))
        e.put("left", JsonString(row.before))
        e.put("right", JsonString(row.after))
        if (row.changed) {
            changed = changed + 1
        }
        arr.add(e)
    }
    o.put("changed_count", JsonInt(changed))
    o.put("sections", JsonArray(arr.toArray()))
    return o
}

/* 解锁理由（请求体 {"reason": "…"}）；缺字段/类型不对 ⇒ 空串，交给 emrReasonValid 判 400。 */
func emrReasonFromBody(ctx: Context): String {
    let o = bodyObj(ctx)
    match (o.get("reason")) {
        case Some(v) =>
            if (v is JsonString) {
                return v.asString().getValue()
            }
            return ""
        case None => return ""
    }
}

/* 接诊队列里的一条（挂号单 + 该单的病历进度）。 */func visitQueueItemJson(a: BookingResult, rec: ?MedicalRecord, previsitReady: Bool): JsonObject {
    let o = JsonObject()
    o.put("appointment_id", JsonInt(a.appointmentId))
    o.put("patient_id", JsonInt(a.patientId))
    o.put("doctor_id", JsonInt(a.doctorId))
    o.put("department_id", JsonInt(a.departmentId))
    o.put("visit_date", JsonString(a.visitDate))
    o.put("period", JsonString(a.period))
    o.put("seq_no", JsonInt(a.seqNo))
    o.put("status", JsonString(a.status))
    /* status 是机器判据、status_label 是给人看的中文名，两者都回，避免客户端各抄一份文案。
     * 三个时间戳 0 = 还没发生（不是缺失）。 */
    o.put("status_label", JsonString(visitStatusLabel(a.status)))
    o.put("arrived_at", JsonInt(a.arrivedAt))
    o.put("started_at", JsonInt(a.startedAt))
    o.put("finished_at", JsonInt(a.finishedAt))
    /* 本单是否有患者自述（预问诊徽标）：只认绑定了本单的会话，
     * 否则每张历史单都会亮徽标。 */
    o.put("previsit_ready", JsonBool(previsitReady))
    /* 该单的病历状态：让医生一眼看出哪些还没写/没提交。 */
    match (rec) {
        case Some(r) =>
            o.put("record_id", JsonInt(r.id))
            o.put("record_status", JsonString(r.status))
            o.put("record_filled", JsonInt(r.filledCount()))
            o.put("record_total", JsonInt(emrSections().size))
        case None =>
            o.put("record_id", JsonInt(0))
            o.put("record_status", JsonString("none"))
            o.put("record_filled", JsonInt(0))
            o.put("record_total", JsonInt(emrSections().size))
    }
    return o
}

/* 预问诊摘要（给医生看）。患者由服务端从挂号单派生，不接受客户端传 patient_id（否则串病历）。
 * 出站不含 patient_id；sections 只列已作答槽位，filled/total 表达完整度。
 * bound = 是否绑定了本单：false 时是回退到该患者最近一次已完成会话（存量兼容），前端据此换文案。 */
func visitPrevisitJson(s: PrevisitSession, bound: Bool): JsonObject {
    let o = JsonObject()
    o.put("session_id", JsonString(s.id))
    o.put("bound", JsonBool(bound))
    o.put("turn", JsonInt(s.turn))
    o.put("completed", JsonBool(s.form.complete()))
    o.put("filled", JsonInt(s.form.filled()))
    o.put("total", JsonInt(intakeSlots().size))
    o.put("captured_at", JsonInt(s.updatedAt))
    let arr = ArrayList<JsonValue>()
    for (slot in intakeSlots()) {
        match (s.form.answers.get(slot.key)) {
            case Some(v) =>
                if (v.size > 0) {
                    let e = JsonObject()
                    e.put("key", JsonString(slot.key))
                    e.put("label", JsonString(slot.label))
                    e.put("value", JsonString(v))
                    e.put("max_len", JsonInt(slot.maxLen))
                    arr.add(e)
                }
            case None => ()
        }
    }
    o.put("sections", JsonArray(arr.toArray()))
    return o
}

/* 写病历失败统一把 EmrWriteOutcome 翻成 HTTP 错误，状态码与错误码映射只此一处。
 * 未知段/超长/缺必填 ⇒ 400 VALIDATION_FAILED；已锁定 ⇒ 409 EMR_LOCKED（状态冲突是 409，不是输入错误）；
 * 预约不存在/不属于本人 ⇒ 404（不能给 403，否则成了枚举 oracle）；解锁理由不合法 ⇒ 400 VALIDATION_FAILED。 */
func emrThrowOnFailure(out: EmrWriteOutcome, what: String): Unit {
    if (out.ok) {
        return
    }
    if (out.badReason) {
        throw apiErrorMsg("VALIDATION_FAILED",
                          "${what}：解锁必须填写理由（${EMR_REASON_MIN}-${EMR_REASON_MAX} 字，例如「患者要求补充过敏史」）")
    }
    if (out.noSuchAppointment) {
        throw apiErrorMsg("APPOINTMENT_NOT_FOUND", "${what}：挂号单不存在或不属于你")
    }
    if (out.locked) {
        throw apiErrorMsg("EMR_LOCKED", "${what}：病历已提交锁定，不可再改（需管理员解锁）")
    }
    if (out.conflict) {
        /* 冲突时回带服务端当前那一版（error.fields），医生端才能"保留本地输入 + 人工确认后重提"。
         * fields 只在真的读到那一版时才带（currentUpdatedAt > 0），缺字段比假时间戳好。 */
        if (out.currentUpdatedAt > 0) {
            let f = JsonObject()
            f.put("updated_at", JsonInt(out.currentUpdatedAt))
            f.put("updated_by", JsonInt(out.currentUpdatedBy))
            if (out.recordId > 0) {
                f.put("record_id", JsonInt(out.recordId))
            }
            throw apiErrorFields("EMR_CHANGED",
                                 "${what}：病历已被其他操作修改（服务端当前版本见 fields），请保留输入并重新读取后确认",
                                 f)
        }
        throw apiErrorMsg("EMR_CHANGED", "${what}：病历已被其他操作修改，请保留输入并重新读取后确认")
    }
    if (out.unknownSection) {
        throw apiErrorMsg("VALIDATION_FAILED", "${what}：未知的病历段 '${out.detail}'")
    }
    if (out.tooLong) {
        throw apiErrorMsg("VALIDATION_FAILED", "${what}：${out.detail}")
    }
    if (out.missingRequired) {
        throw apiErrorMsg("VALIDATION_FAILED",
                          "${what}：提交前必须填写 ${out.detail}（其余段可留空）")
    }
    throw apiErrorMsg("VALIDATION_FAILED", "${what}：写入未成功（原因未分类）")
}

/* 从请求体取可选的 expected_updated_at（乐观锁）：只在当前仍是这一版时才写入。
 * 缺字段/0/负数 ⇒ 0 = 不校验（向后兼容）；字段存在但不是整数 ⇒ 400，不能静默当 0（无声失效的保护更危险）。 */
func emrExpectedUpdatedAt(ctx: Context): Int64 {
    match (bodyObj(ctx).get("expected_updated_at")) {
        case None => return 0
        case Some(v) =>
            if (v is JsonInt) {
                let n = v.asInt().getValue()
                if (n > 0) {
                    return n
                }
                return 0
            }
            throw apiErrorMsg("VALIDATION_FAILED", "expected_updated_at 必须是整数（epoch 秒）")
    }
}

/* 从请求体取"段名 → 正文"的补丁（只取登记过的段）。 */
func emrPatchFromBody(ctx: Context): (HashMap<String, String>, String) {
    let out = HashMap<String, String>()
    let o = bodyObj(ctx)
    for (s in emrSections()) {
        match (o.get(s.key)) {
            case Some(v) =>
                /* 先判类型再取值：asString() 对非字符串会抛（踩坑表 Z 条）。 */
                if (v is JsonString) {
                    out[s.key] = v.asString().getValue()
                } else {
                    return (out, s.label)
                }
            case None => ()
        }
    }
    return (out, "")
}

/* 路由注册 */

/* 给病历 JSON 补这次就诊的上下文：科室名 / 医生名 / 职称 / 就诊日 / 时段。
 * medical_record 表只有 appointment_id / doctor_id，科室与就诊日从挂号单取（就诊事实的快照）。
 * 每条病历一次主键查询：档案量级是几十条；将来量大也应在 domain_emr.cj 一处 JOIN，禁止在 HTTP 层加缓存。 */
func putVisitContext(o: JsonObject, m: MedicalRecord, booking: BookingRepo, names: NameIndex): Unit {
    var depId: Int64 = 0
    match (booking.findAppointment(m.appointmentId)) {
        case Some(a) =>
            depId = a.departmentId
            o.put("department_id", JsonInt(a.departmentId))
            o.put("visit_date", JsonString(a.visitDate))
            o.put("period", JsonString(a.period))
        case None =>
            /* 挂号单不在（历史数据/被清理）⇒ 不写这几个字段，而不是写 0/空串；
             * 缺字段至少能被客户端识别为"未知"。 */
            ()
    }
    /* 名称按已知的 doctor_id 补齐（病历表自己有 doctor_id，不依赖上面那次查询）。 */
    names.putInto(o, depId, m.doctorId)
}

/* 患者基本标识：写 patient_name / patient_gender，查不到写空串而不是省略字段。
 * 只有医生侧三个端点调用：接诊队列、单份病历、既往病历 —— 医生凭编号无法确认"是不是这个人"。
 * 患者侧与看板不加（看板只出聚合，patient_name 是禁词）；只给姓名+性别，不给 phone / birth_date。 */
func putPatientInto(o: JsonObject, patientId: Int64, briefs: HashMap<Int64, PatientBrief>): Unit {
    var name = ""
    var gender = ""
    match (briefs.get(patientId)) {
        case Some(b) =>
            name = b.name
            gender = b.gender
        case None => ()
    }
    o.put("patient_name", JsonString(name))
    o.put("patient_gender", JsonString(gender))
}

/* 注册 P4 全部端点。can(role, action) 是唯一权限判据，本文件不出现手写 role 判断（除取自己的 id）。 */
public func registerP4Routes(r: Router, auth: AuthRepo, gate: DevAuthGate,
                             booking: BookingRepo, previsit: PrevisitRepo,
                             emr: MedicalRecordRepo,
                             visit: VisitRepo, dash: DashboardRepo,
                             aiSettings: AiSettingsRepo,
                             dept: DepartmentRepo, doc: DoctorRepo): Unit {

    /* 一、医生的接诊队列 */

    /* GET /api/v1/doctor/visits —— 本人的接诊队列。
     * doctor_id 只从令牌派生，不接受查询参数，否则可读别人的患者名单。 */
    r.get("/api/v1/doctor/visits", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageVisit)
        if (p.doctorId <= 0) {
            throw apiErrorMsg("FORBIDDEN_ROLE", "该账号没有绑定医生档案，无法接诊")
        }
        let limit = parseInt64Or(ctx.queryParamOr("limit", "100"), 100)
        let rows = visit.queueForDoctor(p.doctorId, if (limit > 0 && limit <= 500) { limit } else { 100 })
        /* 患者姓名一次批量读，不在循环里逐条查（见 VisitRepo.patientBriefs）。 */
        let pids = ArrayList<Int64>()
        for (a in rows) {
            pids.add(a.patientId)
        }
        let briefs = visit.patientBriefs(pids.toArray())
        let arr = ArrayList<JsonValue>()
        for (a in rows) {
            let item = visitQueueItemJson(a, emr.findByAppointment(a.appointmentId),
                                          previsit.findByAppointment(a.appointmentId, a.patientId).isSome())
            putPatientInto(item, a.patientId, briefs)
            arr.add(item)
        }
        let o = JsonObject()
        o.put("items", JsonArray(arr.toArray()))
        o.put("count", JsonInt(rows.size))
        o.put("doctor_id", JsonInt(p.doctorId))
        sendOk(ctx, o)
    })

    /* POST /api/v1/doctor/visits/:id/arrive —— 到院登记（booked → arrived）。
     * 到院是机构事实，由医生工作台点一下，避免患者自述；复用 Action.ManageVisit。
     * 幂等由状态机给出：重复点 ⇒ 409 VISIT_BAD_STATE，不静默成功。 */
    r.post("/api/v1/doctor/visits/:id/arrive", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageVisit)
        let id = parseInt64Or(ctx.paramOr("id", "0"), 0)
        if (id <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "挂号单 id 必须是正整数")
        }
        let now = hNowEpoch()
        p4RequireVisitNotFuture(visit, id, p.doctorId, now, "到院登记")
        let out = visit.arriveVisit(id, p.doctorId, now)
        p4ThrowVisit(out, "到院登记")
        sendOk(ctx, p4VisitStateJson(id, p.doctorId, emr, visit))
    })

    /* POST /api/v1/doctor/visits/:id/waiting —— 进入候诊（arrived → waiting）。
     * 到院是"人来了"、候诊是"在队列里的位置"，合成一步就无法表达"到了但还没被叫"。 */
    r.post("/api/v1/doctor/visits/:id/waiting", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageVisit)
        let id = parseInt64Or(ctx.paramOr("id", "0"), 0)
        if (id <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "挂号单 id 必须是正整数")
        }
        p4RequireVisitNotFuture(visit, id, p.doctorId, hNowEpoch(), "进入候诊")
        let out = visit.waitingVisit(id, p.doctorId)
        p4ThrowVisit(out, "进入候诊")
        sendOk(ctx, p4VisitStateJson(id, p.doctorId, emr, visit))
    })

    /* POST /api/v1/doctor/visits/:id/start —— 开始接诊，只允许 waiting → visiting 并记 started_at。
     * 不允许 booked → visiting，否则"等了多久"没有起点。 */
    r.post("/api/v1/doctor/visits/:id/start", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageVisit)
        let id = parseInt64Or(ctx.paramOr("id", "0"), 0)
        if (id <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "挂号单 id 必须是正整数")
        }
        let now = hNowEpoch()
        p4RequireVisitNotFuture(visit, id, p.doctorId, now, "开始接诊")
        let out = visit.startVisit(id, p.doctorId, now)
        p4ThrowVisit(out, "开始接诊")
        sendOk(ctx, p4VisitStateJson(id, p.doctorId, emr, visit))
    })

    /* POST /api/v1/doctor/visits/:id/finish —— 完成就诊。
     * 前置条件是病历已提交锁定；该条件必须写进同一条 UPDATE 的 WHERE，
     * "先查病历再改状态"在并发下会漏。 */
    r.post("/api/v1/doctor/visits/:id/finish", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageVisit)
        let id = parseInt64Or(ctx.paramOr("id", "0"), 0)
        if (id <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "挂号单 id 必须是正整数")
        }
        let out = visit.finishVisit(id, p.doctorId, hNowEpoch())
        if (out.recordNotLocked) {
            throw apiErrorMsg("EMR_NOT_LOCKED",
                              "完成就诊前必须先提交锁定病历（草稿状态不算完成诊疗）")
        }
        p4ThrowVisit(out, "完成就诊")
        sendOk(ctx, p4VisitStateJson(id, p.doctorId, emr, visit))
    })

    /* POST /api/v1/doctor/visits/:id/no-show —— 标记爽约。
     * 单独一个动作：爽约与完成是两件事，混在一个端点会让病历前置条件含糊。 */
    r.post("/api/v1/doctor/visits/:id/no-show", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageVisit)
        let id = parseInt64Or(ctx.paramOr("id", "0"), 0)
        if (id <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "挂号单 id 必须是正整数")
        }
        /* allowFrom 必须含 booked / arrived / waiting：三种"没看成"的现实形态都要有出路，
         * 否则医生面对已到院但没进诊室的单无路可走。 */
        let out = visit.transition(id, p.doctorId, VISIT_NO_SHOW,
                                  [VISIT_BOOKED, VISIT_ARRIVED, VISIT_WAITING, VISIT_VISITING])
        p4ThrowVisit(out, "标记爽约")
        sendOk(ctx, p4VisitStateJson(id, p.doctorId, emr, visit))
    })

    /* 二、电子病历（医生侧） */

    /* GET /api/v1/doctor/visits/:id/record —— 读该单病历（医生）。
     * 不存在时返回空病历骨架而不是 404：医生要七段结构渲染表单，"还没写"不是错误。 */
    r.get("/api/v1/doctor/visits/:id/record", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.QueryOwnMedicalRecord)
        let id = parseInt64Or(ctx.paramOr("id", "0"), 0)
        if (id <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "挂号单 id 必须是正整数")
        }
        /* 先确认这张单属于本人（不匹配 ⇒ 404，不当 403）。 */
        let mine = visit.findForDoctor(id, p.doctorId)
        match (mine) {
            case None => throw apiErrorMsg("APPOINTMENT_NOT_FOUND", "挂号单不存在或不属于你")
            case Some(a) =>
                /* 患者姓名从挂号单的 patient_id 取：空病历骨架的 patientId 是 0，那条路也要能显示姓名。 */
                let briefs = visit.patientBriefs([a.patientId])
                match (emr.findByAppointment(id)) {
                    case Some(m) =>
                        let o = medicalRecordJson(m, true)
                        putPatientInto(o, a.patientId, briefs)
                        sendOk(ctx, o)
                    case None =>
                        let empty = MedicalRecord()
                        empty.appointmentId = id
                        let o = medicalRecordJson(empty, true)
                        putPatientInto(o, a.patientId, briefs)
                        sendOk(ctx, o)
                }
        }
    })

    /* GET /api/v1/doctor/visits/:id/previsit —— 读该单预问诊摘要（医生）。
     * 归属先按挂号单确认，再由服务端取 patient_id 查会话，患者 id 不接受客户端输入。
     * 来源两级：绑定本单 bound=true；否则回退该患者最近一次已完成会话 bound=false；都没有 ⇒ 404 PREVISIT_NOT_FOUND。 */
    r.get("/api/v1/doctor/visits/:id/previsit", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.QueryOwnMedicalRecord)
        let id = parseInt64Or(ctx.paramOr("id", "0"), 0)
        if (id <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "挂号单 id 必须是正整数")
        }
        let found = visit.findForDoctor(id, p.doctorId)
        if (found.isNone()) {
            throw apiErrorMsg("APPOINTMENT_NOT_FOUND", "挂号单不存在或不属于你")
        }
        let appt = found.getOrThrow()
        match (previsit.findByAppointment(id, appt.patientId)) {
            case Some(s) => sendOk(ctx, visitPrevisitJson(s, true))
            case None =>
                match (previsit.latestCompleteForPatient(appt.patientId)) {
                    case Some(s) => sendOk(ctx, visitPrevisitJson(s, false))
                    case None =>
                        throw apiErrorMsg("PREVISIT_NOT_FOUND",
                                          "该患者没有可用的预问诊摘要（本次未提交，历史也没有已完成的问诊单）")
                }
        }
    })

    /* PUT /api/v1/doctor/visits/:id/record —— 保存草稿（可多次，幂等 upsert）。
     * 患者归属由数据库子查询从 appointment 派生，不接受请求体 patient_id。 */
    r.put("/api/v1/doctor/visits/:id/record", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.WriteOwnMedicalRecord)
        let id = parseInt64Or(ctx.paramOr("id", "0"), 0)
        if (id <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "挂号单 id 必须是正整数")
        }
        /* 归属校验：不是本人的号 ⇒ 404（与"不存在"不可区分）。 */
        if (visit.findForDoctor(id, p.doctorId).isNone()) {
            throw apiErrorMsg("APPOINTMENT_NOT_FOUND", "挂号单不存在或不属于你")
        }
        if (bodyObj(ctx).size() == 0) {
            throw apiErrorMsg("VALIDATION_FAILED",
                              "请求体里没有任何病历段（七段：${joinStrings(emrSectionLabels(), "、")}）")
        }
        let (patch, badType) = emrPatchFromBody(ctx)
        if (badType.size > 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "字段 ${badType} 必须是字符串")
        }
        /* 可选预填：请求体带 use_intake_session 且该单还没有病历时，用预问诊单预填。
         * 已有病历一律不覆盖 —— 医生的判断优先于患者自述。 */
        let useIntake = match (bodyStr(ctx, "use_intake_session")) {
            case Some(v) => v
            case None => ""
        }
        /* 可选乐观锁：0 = 老客户端/不校验；必须在任何写之前解析，类型错要 400。 */
        let expected = emrExpectedUpdatedAt(ctx)
        var out: EmrWriteOutcome
        if (useIntake.size > 0) {
            let appt = visit.findForDoctor(id, p.doctorId).getOrThrow()
            out = emr.saveDraftWithIntake(id, p.doctorId, useIntake, appt.patientId,
                                         patch, hNowEpoch(), p.userId,
                                         expectedUpdatedAt: expected)
        } else {
            out = emr.saveDraft(id, p.doctorId, patch, hNowEpoch(), p.userId,
                                expectedUpdatedAt: expected)
        }
        emrThrowOnFailure(out, "保存草稿")
        let saved = emr.findByAppointment(id).getOrThrow()
        sendOk(ctx, medicalRecordJson(saved, true))
    })

    /* POST /api/v1/doctor/visits/:id/record/lock —— 提交锁定。
     * 必填段由 MedicalRecordRepo.lock 校验，缺则 400 并说清缺哪几段。 */
    r.post("/api/v1/doctor/visits/:id/record/lock", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.WriteOwnMedicalRecord)
        let id = parseInt64Or(ctx.paramOr("id", "0"), 0)
        if (id <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "挂号单 id 必须是正整数")
        }
        if (visit.findForDoctor(id, p.doctorId).isNone()) {
            throw apiErrorMsg("APPOINTMENT_NOT_FOUND", "挂号单不存在或不属于你")
        }
        let out = emr.lock(id, hNowEpoch(), p.userId, roleName(p.role))
        emrThrowOnFailure(out, "提交病历")
        let locked = emr.findByAppointment(id).getOrThrow()
        let o = medicalRecordJson(locked, true)
        /* 本次定稿落下的版本号（前端提示"已生成第 N 版"）。
         * 0 = 审计行没写上，但病历已锁定；客户端不得当失败重试锁（重试走幂等路径会自愈）。 */
        o.put("revision_version", JsonInt(out.revisionVersion))
        sendOk(ctx, o)
    })

    /* POST /api/v1/doctor/visits/:id/record/reopen —— 解锁（仅管理员）。
     * 管理员不能写病历，但需要解锁让医生改；动作是 ManageRecordRevision。
     * 必须给理由（4-255 字）并落进修订历史；没有理由 ⇒ 400，不得静默生效。 */
    r.post("/api/v1/doctor/visits/:id/record/reopen", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageRecordRevision)
        let id = parseInt64Or(ctx.paramOr("id", "0"), 0)
        if (id <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "挂号单 id 必须是正整数")
        }
        let out = emr.reopen(id, hNowEpoch(), p.userId, roleName(p.role), emrReasonFromBody(ctx))
        emrThrowOnFailure(out, "解锁病历")
        let m = emr.findByAppointment(id)
        if (m.isNone()) {
            throw apiErrorMsg("APPOINTMENT_NOT_FOUND", "该挂号单没有已锁定的病历可解锁")
        }
        let o = medicalRecordJson(m.getOrThrow(), true)
        /* 本次解锁落下的版本号（= 解锁前那一版；0 = 审计写入失败，病历已解锁）。 */
        o.put("revision_version", JsonInt(out.revisionVersion))
        sendOk(ctx, o)
    })

    /* 二·补、病历修订历史 */

    /* 修订历史读取权限：管理员（ManageRecordRevision）不受"这是谁的号"限制，否则审计路径对管理员恒 404；
     * 其它角色须 QueryOwnMedicalRecord 且是"本人的单"，不匹配一律 404（403 是枚举 oracle）。
     * 患者没有这条路径：内容含 reason 与 operator_role 等内部审计信息。 */
    func requireRevisionRead(p: Principal, id: Int64, visit: VisitRepo): Unit {
        if (can(p.role, Action.ManageRecordRevision)) {
            return
        }
        requireCan(p.role, Action.QueryOwnMedicalRecord)
        if (visit.findForDoctor(id, p.doctorId).isNone()) {
            throw apiErrorMsg("APPOINTMENT_NOT_FOUND", "挂号单不存在或不属于你")
        }
    }

    /* GET /api/v1/doctor/visits/:id/record/revisions —— 该单全部修订，version ASC。
     * 升序是因为"与上一版对比"要 version - 1；列表不带正文。 */
    r.get("/api/v1/doctor/visits/:id/record/revisions", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        let id = parseInt64Or(ctx.paramOr("id", "0"), 0)
        if (id <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "挂号单 id 必须是正整数")
        }
        requireRevisionRead(p, id, visit)
        let rows = emr.revisions(id)
        let arr = ArrayList<JsonValue>()
        for (r in rows) {
            arr.add(revisionItemJson(r))
        }
        let o = JsonObject()
        o.put("appointment_id", JsonInt(id))
        o.put("items", JsonArray(arr.toArray()))
        o.put("count", JsonInt(rows.size))
        sendOk(ctx, o)
    })

    /* GET /api/v1/doctor/visits/:id/record/revisions/:version —— 某一版（带正文）。
     * 没有修订行 ⇒ 404 REVISION_NOT_FOUND（不是空对象，否则渲染成七段全空）；版本号从 1 开始，0/负数 ⇒ 400。 */
    r.get("/api/v1/doctor/visits/:id/record/revisions/:version", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        let id = parseInt64Or(ctx.paramOr("id", "0"), 0)
        if (id <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "挂号单 id 必须是正整数")
        }
        let ver = parseInt64Or(ctx.paramOr("version", "0"), 0)
        if (ver <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "版本号必须是正整数（第一版是 1）")
        }
        requireRevisionRead(p, id, visit)
        match (emr.revisionAt(id, ver)) {
            case Some(r) => sendOk(ctx, revisionDetailJson(r))
            case None => throw apiErrorMsg("REVISION_NOT_FOUND", "该病历没有这一版修订")
        }
    })

    /* GET /api/v1/doctor/visits/:id/record/revisions/:version/diff?against=N —— 逐段差异，against 默认上一版。
     * v1 没有上一版 ⇒ 400 并要求显式给 against；against == version 也 400：
     * 与自身对比会返回"一切未变"这个看起来成功的假答案。 */
    r.get("/api/v1/doctor/visits/:id/record/revisions/:version/diff", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        let id = parseInt64Or(ctx.paramOr("id", "0"), 0)
        if (id <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "挂号单 id 必须是正整数")
        }
        let ver = parseInt64Or(ctx.paramOr("version", "0"), 0)
        if (ver <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "版本号必须是正整数（第一版是 1）")
        }
        let againstText = ctx.queryParamOr("against", "").trimAscii()
        var against = ver - 1
        if (againstText.size > 0) {
            against = parseInt64Or(againstText, -1)
        }
        if (against <= 0 || against == ver) {
            throw apiErrorMsg("VALIDATION_FAILED",
                              "against 必须是**另一个**版本号（第一版没有上一版，请显式指定要与哪一版对比）")
        }
        requireRevisionRead(p, id, visit)
        match (emr.revisionAt(id, ver)) {
            case Some(right) =>
                match (emr.revisionAt(id, against)) {
                    case Some(left) => sendOk(ctx, revisionDiffJson(left, right))
                    case None => throw apiErrorMsg("REVISION_NOT_FOUND", "要对比的那一版不存在")
                }
            case None => throw apiErrorMsg("REVISION_NOT_FOUND", "该病历没有这一版修订")
        }
    })

    /* 二·补、医生工作台：既往病历 */

    /* GET /api/v1/doctor/patients/:patientId/records?limit=5&exclude_appointment_id= —— 该患者既往已定稿病历。
     * 三道闸门缺一不可：QueryOwnMedicalRecord；patientTreatedByDoctor（SQL 内过滤，禁止先读出再比）；
     * 仓储再按 doctor_id + status='locked' 过滤。
     * 不是本人的患者回 404 而不是 403（403 会回答"此人是否存在"）；exclude_appointment_id 排掉正在写的这份。 */
    r.get("/api/v1/doctor/patients/:patientId/records", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.QueryOwnMedicalRecord)
        if (p.doctorId <= 0) {
            throw apiErrorMsg("FORBIDDEN_ROLE", "该账号没有绑定医生档案，无法查看既往病历")
        }
        let patientId = parseInt64Or(ctx.paramOr("patientId", "0"), 0)
        if (patientId <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "患者 id 必须是正整数")
        }
        if (!emr.patientTreatedByDoctor(p.doctorId, patientId)) {
            throw apiErrorMsg("APPOINTMENT_NOT_FOUND", "该患者在你的接诊记录里不存在")
        }
        /* 上限 20；非法/越界一律回落默认 5，与患者侧 /medical-records 的 limit 处理保持一致。 */
        let limit = parseInt64Or(ctx.queryParamOr("limit", "5"), 5)
        let capped = if (limit > 0 && limit <= 20) { limit } else { 5 }
        let exclude = parseInt64Or(ctx.queryParamOr("exclude_appointment_id", "0"), 0)
        let rows = emr.listLockedForDoctorPatient(p.doctorId, patientId, capped,
                                                 excludeAppointmentId: exclude)
        /* 名称/就诊上下文一次读全科室+医生，不在循环里查。 */
        let names = nameIndexOf(dept, doc)
        /* 患者姓名走同一套 putPatientInto。 */
        let briefs = visit.patientBriefs([patientId])
        let arr = ArrayList<JsonValue>()
        for (m in rows) {
            let item = medicalRecordJson(m, true)
            putVisitContext(item, m, booking, names)
            putPatientInto(item, patientId, briefs)
            arr.add(item)
        }
        let o = JsonObject()
        o.put("items", JsonArray(arr.toArray()))
        o.put("count", JsonInt(rows.size))
        o.put("patient_id", JsonInt(patientId))
        sendOk(ctx, o)
    })

    /* 三、电子病历（患者侧：只读自己的） */

    /* GET /api/v1/medical-records —— 本人的医疗档案列表。
     * patient_id 从令牌派生，不接受 ?patient_id=；列表不给正文（includeSections=false）。 */
    r.get("/api/v1/medical-records", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.QueryOwnMedicalRecord)
        if (p.patientId <= 0) {
            throw apiErrorMsg("FORBIDDEN_ROLE", "该账号没有绑定患者档案")
        }
        let limit = parseInt64Or(ctx.queryParamOr("limit", "50"), 50)
        let rows = emr.listForPatient(p.patientId, if (limit > 0 && limit <= 200) { limit } else { 50 })
        /* 名称/就诊上下文：一次读全科室+医生（见 nameIndexOf 的 N+1 说明）。 */
        let names = nameIndexOf(dept, doc)
        let arr = ArrayList<JsonValue>()
        for (m in rows) {
            let item = medicalRecordJson(m, false)
            putVisitContext(item, m, booking, names)
            arr.add(item)
        }
        let o = JsonObject()
        o.put("items", JsonArray(arr.toArray()))
        o.put("count", JsonInt(rows.size))
        sendOk(ctx, o)
    })

    /* GET /api/v1/medical-records/:appointmentId —— 某次就诊的病历（患者读自己的）。
     * 必须用 findByAppointmentForPatient（patient_id 进 WHERE），先读再比一旦漏掉就是数据泄露。
     * 草稿一律 404：医嘱没定稿不能当结论给患者看。 */
    r.get("/api/v1/medical-records/:appointmentId", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.QueryOwnMedicalRecord)
        if (p.patientId <= 0) {
            throw apiErrorMsg("FORBIDDEN_ROLE", "该账号没有绑定患者档案")
        }
        let id = parseInt64Or(ctx.paramOr("appointmentId", "0"), 0)
        if (id <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "挂号单 id 必须是正整数")
        }
        match (emr.findByAppointmentForPatient(id, p.patientId)) {
            case Some(m) =>
                if (!m.isLocked()) {
                    /* 草稿对患者一律 404 而不是 403：403 会暴露"这里有一份没写好的病历"。 */
                    throw apiErrorMsg("EMR_NOT_FOUND", "病历不存在或尚未提交")
                }
                let o = medicalRecordJson(m, true)
                putVisitContext(o, m, booking, nameIndexOf(dept, doc))
                sendOk(ctx, o)
            case None =>
                throw apiErrorMsg("EMR_NOT_FOUND", "病历不存在或尚未提交")
        }
    })

    /* 四、运营看板（仅管理员） */

    /* GET /api/v1/admin/dashboard —— 运营看板。
     * 隐私红线：只出聚合，绝不出明细。所有数字都是 COUNT/SUM；
     * 不出现任何 patient_id / doctor_id / phone / name；科室维度只出"科室名 + 计数"。
     * 该红线由 AC-P4-* 逐字段钉住：响应里搜不到这些字段或手机号形状。 */
    r.get("/api/v1/admin/dashboard", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ViewDashboard)
        sendOk(ctx, dash.build(hNowEpoch(), aiSettings))
    })
}

/* 小工具 */

/* 七段的标签（用于错误信息里告诉客户端能传哪些字段）。 */
func emrSectionLabels(): Array<String> {
    let out = ArrayList<String>()
    for (s in emrSections()) {
        out.add(s.key)
    }
    return out.toArray()
}

/* 接诊状态流转失败 → HTTP 错误（映射只此一处）。 */
func p4ThrowVisit(out: VisitOutcome, what: String): Unit {
    if (out.ok) {
        return
    }
    if (out.notFound) {
        throw apiErrorMsg("APPOINTMENT_NOT_FOUND", "${what}：挂号单不存在或不属于你")
    }
    if (out.recordNotLocked) {
        throw apiErrorMsg("EMR_NOT_LOCKED", "${what}：病历尚未提交锁定")
    }
    if (out.badTransition) {
        /* 409 而不是 400：这是状态冲突（当前状态不允许该流转），不是请求格式错。 */
        throw apiErrorMsg("VISIT_BAD_STATE",
                          "${what}：当前状态 '${out.fromStatus}' 不允许流转到 '${out.toStatus}'")
    }
    throw apiErrorMsg("INTERNAL", "${what}：未成功（原因未分类）")
}

/* 就诊日期门槛：只拦未来日期（跨零点接诊、次日补录昨天队列都是真实业务），
 * 违反则 400 VISIT_DATE_FUTURE。放在 HTTP 信任边界而不是领域层：领域层的日期夹具断言不能被墙上时钟左右。 */
func p4RequireVisitNotFuture(visit: VisitRepo, appointmentId: Int64, doctorId: Int64,
                             now: Int64, what: String): Unit {
    match (visit.findForDoctor(appointmentId, doctorId)) {
        case Some(a) =>
            if (visit.visitIsFuture(a.visitDate, now)) {
                throw apiErrorMsg("VISIT_DATE_FUTURE",
                                  "${what}：该号的就诊日是 ${a.visitDate}，今天（${hDateStringOf(now)}）不能到院登记/接诊")
            }
        case None =>
            /* 不存在或不属于本人 —— 交给下游状态机按 404 统一处理，这里不抢先报错。 */
            return
    }
}
/* 回显该单最新状态 + 病历状态。 */
func p4VisitStateJson(appointmentId: Int64, doctorId: Int64,
                      emr: MedicalRecordRepo, visit: VisitRepo): JsonObject {
    let o = JsonObject()
    o.put("appointment_id", JsonInt(appointmentId))
    match (visit.findForDoctor(appointmentId, doctorId)) {
        case Some(a) =>
            o.put("status", JsonString(a.status))
            /* 状态中文名与三个时间戳：任何一次流转的响应都自带完整时间线。 */
            o.put("status_label", JsonString(visitStatusLabel(a.status)))
            o.put("arrived_at", JsonInt(a.arrivedAt))
            o.put("started_at", JsonInt(a.startedAt))
            o.put("finished_at", JsonInt(a.finishedAt))
            o.put("visit_date", JsonString(a.visitDate))
            o.put("period", JsonString(a.period))
            o.put("seq_no", JsonInt(a.seqNo))
        case None =>
            /* 病历不存在也要补齐字段：响应形状不能随"这单在不在"变化，契约按"字段总是存在"钉。
             * 缺单语义：状态空串 + 三个时间戳 0（"没有这单"而非"还没发生"）。 */
            o.put("status", JsonString(""))
            o.put("status_label", JsonString(""))
            o.put("arrived_at", JsonInt(0))
            o.put("started_at", JsonInt(0))
            o.put("finished_at", JsonInt(0))
            o.put("visit_date", JsonString(""))
            o.put("period", JsonString(""))
            o.put("seq_no", JsonInt(0))
    }
    match (emr.findByAppointment(appointmentId)) {
        case Some(m) =>
            o.put("record_status", JsonString(m.status))
            o.put("record_filled", JsonInt(m.filledCount()))
        case None =>
            o.put("record_status", JsonString("none"))
            o.put("record_filled", JsonInt(0))
    }
    return o
}
