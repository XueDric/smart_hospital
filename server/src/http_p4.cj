/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 *
 * ===== http_p4.cj —— P4 接口层：电子病历 + 接诊队列 + 运营看板 ==============
 *
 * ── 为什么单独一个文件（而不是往 http_app.cj 里再塞）──────────────────────
 *   `http_app.cj` 已经 1500+ 行（19 个端点 + JSON 助手 + 身份/权限）。
 *   P4 再往里加 11 个端点会让它变成"什么都有的一个文件"，
 *   而 P4 的三块（病历 / 接诊 / 看板）有**自己的**纪律要写清：
 *     · 病历：谁能写、锁定语义、越权一律当"不存在"；
 *     · 接诊：状态机 + "完成就诊前必须已锁定病历"；
 *     · 看板：**只出聚合、绝不出明细**（隐私）。
 *   这些说明放在一起才有用，散在 1500 行里没人会读。
 *
 * ⚠ 与 `http_app.cj` 的关系：**路由注册仍集中在那边的 `buildHospitalRouter`** ——
 *   本文件只提供 `registerP4Routes(...)`，由它调用一次。
 *   这样"有哪些端点"这件事仍然只有一处（便于 doc-counts 对账）。
 */

package qingzhou

import std.collection.*
import stdx.encoding.json.*

/* ===================== 病历 JSON ===================== */

/*
 * 病历的对外形状。
 *
 * ⚠ **`patient_id` / `doctor_id` 原样给出**（不做脱敏）—— 理由：
 *   · 这份数据本来就是给**当事人**看的（患者看自己的、医生看自己的号）；
 *   · 服务端不会把它给无关的人（越权一律 404，见各 handler）；
 *   ⇒ 在这里脱敏只会让医生分不清"这是谁的单"，没有隐私收益。
 *   📌 对比：**运营看板**是另一回事 —— 那里是"跨患者聚合"，
 *     所以那边**只出计数、绝不出任何 id**（见 `dashboardJson`）。
 */
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
    /* 提交锁定还缺哪几段（空数组 = 可以提交）。让客户端不必猜。 */
    let miss = ArrayList<JsonValue>()
    for (x in m.missingRequired()) {
        miss.add(JsonString(x))
    }
    o.put("missing_required", JsonArray(miss.toArray()))
    /*
     * ⚠ 七段正文**按需给出**（`includeSections`）：
     *   列表接口不给正文（只给进度）—— 那能让"我的档案"列表轻很多，
     *   也避免一次响应里塞进几十份完整病历。
     */
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
    }
    return o
}

/* 接诊队列里的一条（挂号单 + 该单的病历进度）。 */
func visitQueueItemJson(a: BookingResult, rec: ?MedicalRecord): JsonObject {
    let o = JsonObject()
    o.put("appointment_id", JsonInt(a.appointmentId))
    o.put("patient_id", JsonInt(a.patientId))
    o.put("doctor_id", JsonInt(a.doctorId))
    o.put("department_id", JsonInt(a.departmentId))
    o.put("visit_date", JsonString(a.visitDate))
    o.put("period", JsonString(a.period))
    o.put("seq_no", JsonInt(a.seqNo))
    o.put("status", JsonString(a.status))
    /* 该单的病历状态：让医生一眼看出"哪些还没写/没提交"。 */
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

/*
 * 写病历失败时**统一**把 `EmrWriteOutcome` 翻成 HTTP 错误。
 *
 * ⚠ 抽成一个函数（而不是每个 handler 各写一遍）：状态码与错误码的映射
 *   只该有一处，否则四个端点迟早给出不一致的码。
 *   📌 映射刻意区分：
 *     · 未知段 / 超长 / 缺必填  ⇒ 400 VALIDATION_FAILED（客户端可以改）
 *     · 已锁定                  ⇒ 409 EMR_LOCKED（**状态冲突**，不是输入错误；
 *                                  409 才能让客户端区分"改不了"与"写错了"）
 *     · 预约不存在 / 不属于我   ⇒ 404（**不区分 403**：区分开就是枚举 oracle）
 */
func emrThrowOnFailure(out: EmrWriteOutcome, what: String): Unit {
    if (out.ok) {
        return
    }
    if (out.noSuchAppointment) {
        throw apiErrorMsg("APPOINTMENT_NOT_FOUND", "${what}：挂号单不存在或不属于你")
    }
    if (out.locked) {
        throw apiErrorMsg("EMR_LOCKED", "${what}：病历已提交锁定，不可再改（需管理员解锁）")
    }
    if (out.conflict) {
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

/* 从请求体里取"段名 → 正文"的补丁（只取**登记过的**段）。 */
func emrPatchFromBody(ctx: Context): (HashMap<String, String>, String) {
    let out = HashMap<String, String>()
    let o = bodyObj(ctx)
    for (s in emrSections()) {
        match (o.get(s.key)) {
            case Some(v) =>
                /* ⚠ 先判类型再取值：`asString()` 对非字符串会抛（踩坑表 Z 条） */
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

/* ===================== 路由注册 ===================== */

/*
 * ★ 2026-10-12：给病历 JSON 补"这次就诊的上下文"——
 *   科室名 / 医生名 / 职称 / 就诊日 / 时段。
 *
 * 为什么必须补（患者端实测）：档案列表与详情此前只有 `doctor_id`，
 * 患者看到的是「#930813 · 医生 #900003」，**看不出这是哪个科的哪一次就诊**；
 * 而同一个 app 的挂号页却能显示「P4测试科3 · P4测试医生900003」。
 * ⇒ 一份说自己"已提交锁定"的病历，患者却认不出是哪次看病 —— 这不可用。
 *
 * 数据来源：`medical_record` 表**只有** `appointment_id` / `doctor_id`，
 *   没有 `department_id` / `visit_date` ⇒ 从挂号单取（那才是就诊事实的快照，
 *   也与 `/appointments` 返回的是同一条记录，患者能对上）。
 *
 * ⚠ 这里**每条病历查一次挂号单**（`findAppointment` 走主键）。
 *   已知代价：列表有 N 条就有 N 次主键查询。接受它的理由：
 *   · 本接口是"某个患者自己的档案"，量级是个位数到几十条（不是全院扫描）；
 *   · 主键查询很便宜，且**绝不能**用"把科室名拼进 SQL JOIN"随手改了
 *     `domain_emr.cj` 的列映射（那正是本仓栽过的"列顺序只有一处定义"的坑）。
 *   📌 若将来档案量真的变到几百条以上，正确做法是在 `domain_emr.cj` 里
 *      **一处** JOIN `appointment`/`department`/`doctor`，而不是在 HTTP 层加缓存。
 */
func putVisitContext(o: JsonObject, m: MedicalRecord, booking: BookingRepo, names: NameIndex): Unit {
    var depId: Int64 = 0
    match (booking.findAppointment(m.appointmentId)) {
        case Some(a) =>
            depId = a.departmentId
            o.put("department_id", JsonInt(a.departmentId))
            o.put("visit_date", JsonString(a.visitDate))
            o.put("period", JsonString(a.period))
        case None =>
            /*
             * 挂号单不在（历史数据/被清理）⇒ **不写**这几个字段，而不是写 0/空串：
             * 写 `department_id = 0` 会让客户端去查一个不存在的科室，
             * 写空 `visit_date` 会显示成空白 —— 缺字段至少能被客户端识别为"未知"。
             */
            ()
    }
    /* 名称永远按**已知的 doctor_id** 补齐（病历表自己有 doctor_id，不依赖上面那次查询）。 */
    names.putInto(o, depId, m.doctorId)
}

/*
 * 注册 P4 的全部端点。
 *
 * ⚠ `can(role, action)` 是**唯一**的权限判据；本文件里不出现任何
 *   "role == Doctor" 这类手写判断（除"取自己的 id"之外）。
 */
public func registerP4Routes(r: Router, auth: AuthRepo, gate: DevAuthGate,
                             booking: BookingRepo, emr: MedicalRecordRepo,
                             visit: VisitRepo, dash: DashboardRepo,
                             aiSettings: AiSettingsRepo,
                             dept: DepartmentRepo, doc: DoctorRepo): Unit {

    /* ========== 一、医生的接诊队列 ========== */

    /*
     * GET /api/v1/doctor/visits —— 我的接诊队列。
     *
     * ⚠ `doctor_id` **只从令牌派生**，不接受查询参数 ——
     *   否则医生 A 传上 B 的 id 就能读 B 的队列（那是患者名单泄露）。
     */
    r.get("/api/v1/doctor/visits", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageVisit)
        if (p.doctorId <= 0) {
            throw apiErrorMsg("FORBIDDEN_ROLE", "该账号没有绑定医生档案，无法接诊")
        }
        let limit = parseInt64Or(ctx.queryParamOr("limit", "100"), 100)
        let rows = visit.queueForDoctor(p.doctorId, if (limit > 0 && limit <= 500) { limit } else { 100 })
        let arr = ArrayList<JsonValue>()
        for (a in rows) {
            arr.add(visitQueueItemJson(a, emr.findByAppointment(a.appointmentId)))
        }
        let o = JsonObject()
        o.put("items", JsonArray(arr.toArray()))
        o.put("count", JsonInt(rows.size))
        o.put("doctor_id", JsonInt(p.doctorId))
        sendOk(ctx, o)
    })

    /*
     * POST /api/v1/doctor/visits/:id/start —— 开始接诊。
     * 只允许 `booked → visiting`。
     */
    r.post("/api/v1/doctor/visits/:id/start", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageVisit)
        let id = parseInt64Or(ctx.paramOr("id", "0"), 0)
        if (id <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "挂号单 id 必须是正整数")
        }
        let out = visit.transition(id, p.doctorId, VISIT_VISITING, [VISIT_BOOKED])
        p4ThrowVisit(out, "开始接诊")
        sendOk(ctx, p4VisitStateJson(id, p.doctorId, emr, visit))
    })

    /*
     * POST /api/v1/doctor/visits/:id/finish —— 完成就诊。
     *
     * ★★ 前置条件是**病历已提交锁定**。理由：完成就诊意味着诊断结束，
     *   而"就诊完成但没病历"在真实医院里是不允许的（那等于没记录诊疗行为）。
     *   ⚠ 该前置条件写在**同一条 UPDATE 的 WHERE 里**（见 VisitRepo.finishVisit），
     *     而不是"先查病历再改状态" —— 后者在并发下会漏。
     */
    r.post("/api/v1/doctor/visits/:id/finish", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageVisit)
        let id = parseInt64Or(ctx.paramOr("id", "0"), 0)
        if (id <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "挂号单 id 必须是正整数")
        }
        let out = visit.finishVisit(id, p.doctorId)
        if (out.recordNotLocked) {
            throw apiErrorMsg("EMR_NOT_LOCKED",
                              "完成就诊前必须先提交锁定病历（草稿状态不算完成诊疗）")
        }
        p4ThrowVisit(out, "完成就诊")
        sendOk(ctx, p4VisitStateJson(id, p.doctorId, emr, visit))
    })

    /*
     * POST /api/v1/doctor/visits/:id/no-show —— 标记患者爽约。
     * ⚠ 单独一个动作（而不是 `finish` 带参数）：爽约与完成是**两件事**，
     *   混在一个端点里会让"是否写了病历"这个前置条件变得含糊。
     */
    r.post("/api/v1/doctor/visits/:id/no-show", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageVisit)
        let id = parseInt64Or(ctx.paramOr("id", "0"), 0)
        if (id <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "挂号单 id 必须是正整数")
        }
        let out = visit.transition(id, p.doctorId, VISIT_NO_SHOW,
                                  [VISIT_BOOKED, VISIT_VISITING])
        p4ThrowVisit(out, "标记爽约")
        sendOk(ctx, p4VisitStateJson(id, p.doctorId, emr, visit))
    })

    /* ========== 二、电子病历（医生侧） ========== */

    /*
     * GET /api/v1/doctor/visits/:id/record —— 读该单的病历（医生）。
     * 不存在时返回一份**空病历骨架**（而不是 404）：医生要拿七段的结构去渲染表单，
     * "还没写"是正常状态，不是错误。
     */
    r.get("/api/v1/doctor/visits/:id/record", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.QueryOwnMedicalRecord)
        let id = parseInt64Or(ctx.paramOr("id", "0"), 0)
        if (id <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "挂号单 id 必须是正整数")
        }
        /* 先确认这张单是**我的**（不匹配 ⇒ 404，不当成 403） */
        if (visit.findForDoctor(id, p.doctorId).isNone()) {
            throw apiErrorMsg("APPOINTMENT_NOT_FOUND", "挂号单不存在或不属于你")
        }
        match (emr.findByAppointment(id)) {
            case Some(m) => sendOk(ctx, medicalRecordJson(m, true))
            case None =>
                let empty = MedicalRecord()
                empty.appointmentId = id
                sendOk(ctx, medicalRecordJson(empty, true))
        }
    })

    /*
     * PUT /api/v1/doctor/visits/:id/record —— 保存草稿（可多次；幂等 upsert）。
     *
     * ⚠ 患者归属由**数据库子查询**从 appointment 派生（见 MedicalRecordRepo.saveDraft），
     *   不接受请求体里的 patient_id —— 那是最容易被篡改的字段。
     */
    r.put("/api/v1/doctor/visits/:id/record", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.WriteOwnMedicalRecord)
        let id = parseInt64Or(ctx.paramOr("id", "0"), 0)
        if (id <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "挂号单 id 必须是正整数")
        }
        /* 归属校验：不是我的号 ⇒ 404（与"不存在"不可区分） */
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
        /*
         * ★ 可选预填：请求体带 `use_intake_session` 时，**首次**保存会先用
         *   该患者的预问诊问诊单预填（P2 → P4 的衔接）。
         *   ⚠ 只在该单**还没有病历**时生效；已有病历一律不覆盖
         *     （医生的判断优先于患者自述）。
         */
        let useIntake = match (bodyStr(ctx, "use_intake_session")) {
            case Some(v) => v
            case None => ""
        }
        var out: EmrWriteOutcome
        if (useIntake.size > 0) {
            let appt = visit.findForDoctor(id, p.doctorId).getOrThrow()
            out = emr.saveDraftWithIntake(id, p.doctorId, useIntake, appt.patientId,
                                         patch, hNowEpoch(), p.userId)
        } else {
            out = emr.saveDraft(id, p.doctorId, patch, hNowEpoch(), p.userId)
        }
        emrThrowOnFailure(out, "保存草稿")
        let saved = emr.findByAppointment(id).getOrThrow()
        sendOk(ctx, medicalRecordJson(saved, true))
    })

    /*
     * POST /api/v1/doctor/visits/:id/record/lock —— 提交锁定。
     *
     * ⚠ 必填段（诊断 / 处理意见）由 `MedicalRecordRepo.lock` 校验；
     *   缺则 400 并**说清缺哪几段**（不说清的话医生只能一段段试）。
     */
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
        let out = emr.lock(id, hNowEpoch(), p.userId)
        emrThrowOnFailure(out, "提交病历")
        let locked = emr.findByAppointment(id).getOrThrow()
        sendOk(ctx, medicalRecordJson(locked, true))
    })

    /*
     * POST /api/v1/doctor/visits/:id/record/reopen —— 解锁（**仅管理员**）。
     *
     * ⚠ 这是"修订通道"：管理员**不能写病历**（见 can() 的说明），
     *   但需要能解锁让医生改。所以这条端点要求 `CancelAny` 这类
     *   "管理动作"权限 —— 这里用 `ViewDashboard` 不合适，故单独查角色：
     *   ⚠⚠ 这是本文件里**唯一**一处直接看角色，理由与处置都写在下面。
     */
    r.post("/api/v1/doctor/visits/:id/record/reopen", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        /*
         * ⚠ 为什么这里不写 `requireCan(p.role, 某个 Action)`：
         *   权限矩阵里**没有**"解锁病历"这个动作，而它是管理员专属的写操作。
         *   两条路：① 加一个 Action（那要动权限矩阵与它的测试）；
         *           ② 复用已有的管理员动作。
         *   我选 ②：复用 `ManageSchedule`（当前= 管理员专属的管理动作），
         *   并在这里显式说明 —— 而不是新增一个只被一个端点用到的 Action
         *   （那会让权限矩阵膨胀，而矩阵的价值在于"能一眼看全"）。
         *   📌 若将来解锁需要独立授权（例如"只有医务科能解锁"），
         *     再把它提升为独立 Action —— 那时它就有了第二个用处。
         */
        requireCan(p.role, Action.ManageSchedule)
        let id = parseInt64Or(ctx.paramOr("id", "0"), 0)
        if (id <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "挂号单 id 必须是正整数")
        }
        let out = emr.reopen(id, hNowEpoch(), p.userId)
        emrThrowOnFailure(out, "解锁病历")
        let m = emr.findByAppointment(id)
        if (m.isNone()) {
            throw apiErrorMsg("APPOINTMENT_NOT_FOUND", "该挂号单没有已锁定的病历可解锁")
        }
        sendOk(ctx, medicalRecordJson(m.getOrThrow(), true))
    })

    /* ========== 三、电子病历（患者侧：只读自己的） ========== */

    /*
     * GET /api/v1/medical-records —— 我的医疗档案（列表）。
     *
     * ⚠ `patient_id` 从令牌派生；**不接受** `?patient_id=` ——
     *   与"我的挂号"同一条纪律（传了也忽略）。
     * ⚠ 列表**不给正文**（`includeSections=false`）：一次几十份完整病历
     *   既大又没必要（列表只需要进度与时间）。
     */
    r.get("/api/v1/medical-records", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.QueryOwnMedicalRecord)
        if (p.patientId <= 0) {
            throw apiErrorMsg("FORBIDDEN_ROLE", "该账号没有绑定患者档案")
        }
        let limit = parseInt64Or(ctx.queryParamOr("limit", "50"), 50)
        let rows = emr.listForPatient(p.patientId, if (limit > 0 && limit <= 200) { limit } else { 50 })
        /* ★ 名称/就诊上下文：一次读全科室+医生（见 `nameIndexOf` 的 N+1 说明）。 */
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

    /*
     * GET /api/v1/medical-records/:appointmentId —— 某次就诊的病历（患者读自己的）。
     *
     * ⚠ 用 `findByAppointmentForPatient`（带 patient_id 条件）而不是
     *   "先读再比 patient_id" —— 后者一旦有人重构漏掉比较就是**数据泄露**。
     *   前者把隔离做进了 SQL 的 WHERE 里。
     * ⚠ 未锁定（草稿）的病历**不给患者看**：草稿是医生还没定稿的工作稿，
     *   给患者看会造成"医嘱还没写完就被当成结论"。⇒ 草稿一律 404。
     */
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
                    /*
                     * ⚠ 草稿对患者**一律 404**（不是 403）：
                     *   403 会告诉患者"这里确实有一份还没写好的病历"，
                     *   而 404 与"没有病历"不可区分 —— 少一个信息泄露面。
                     */
                    throw apiErrorMsg("EMR_NOT_FOUND", "病历不存在或尚未提交")
                }
                let o = medicalRecordJson(m, true)
                putVisitContext(o, m, booking, nameIndexOf(dept, doc))
                sendOk(ctx, o)
            case None =>
                throw apiErrorMsg("EMR_NOT_FOUND", "病历不存在或尚未提交")
        }
    })

    /* ========== 四、运营看板（仅管理员） ========== */

    /*
     * GET /api/v1/admin/dashboard —— 运营看板。
     *
     * ★★ 隐私红线：**只出聚合，绝不出明细**。
     *   具体到本响应里：
     *     · 所有数字都是 COUNT/SUM，没有一行患者或医生的原始记录；
     *     · **不出现任何 patient_id / doctor_id / phone / name**；
     *     · 科室维度只出"科室名 + 计数"（科室不是隐私，且管理员本就要看）。
     *   ⚠ 这条红线由测试**逐字段**钉住（AC-P4-*）：把响应当字符串搜
     *     `patient_id` / `doctor_id` / 手机号形状，一个都不许有。
     */
    r.get("/api/v1/admin/dashboard", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ViewDashboard)
        sendOk(ctx, dash.build(hNowEpoch(), aiSettings))
    })
}

/* ===================== 小工具 ===================== */

/* 七段的标签（用于错误信息里告诉客户端"能传哪些字段"）。 */
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
        /*
         * ⚠ 409 而不是 400：这是**状态冲突**（当前状态不允许该流转），
         *   不是请求格式错。客户端据此可以提示"这张单已结束"而不是"参数错了"。
         */
        throw apiErrorMsg("VISIT_BAD_STATE",
                          "${what}：当前状态 '${out.fromStatus}' 不允许流转到 '${out.toStatus}'")
    }
    throw apiErrorMsg("INTERNAL", "${what}：未成功（原因未分类）")
}

/* 回显该单的最新状态 + 病历状态。 */
func p4VisitStateJson(appointmentId: Int64, doctorId: Int64,
                      emr: MedicalRecordRepo, visit: VisitRepo): JsonObject {
    let o = JsonObject()
    o.put("appointment_id", JsonInt(appointmentId))
    match (visit.findForDoctor(appointmentId, doctorId)) {
        case Some(a) =>
            o.put("status", JsonString(a.status))
            o.put("visit_date", JsonString(a.visitDate))
            o.put("period", JsonString(a.period))
            o.put("seq_no", JsonInt(a.seqNo))
        case None =>
            o.put("status", JsonString(""))
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
