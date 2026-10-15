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
        /*
         * ★ 来源痕迹（2026-10-14 改进 1）：`{"session_id","sections":[…],"at"}`，
         *   告诉医生端"这几段是患者自述预填进来的"，前端据此在段标题旁显示角标。
         * ⚠ 只在**给正文时**给（`includeSections`）：列表接口不需要它，
         *   而"出站最小化"是本仓的既有纪律。
         * ⚠ 以**嵌套对象**形式返回（而不是再套一层字符串）：客户端不必二次解析
         *   JSON-in-string（那正是两端解析不一致的高发地）。
         *   坏数据（历史/手工改坏）解析失败 ⇒ 不给这个字段（不猜、不 500）。
         */
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

/*
 * ★ 2026-10-15（改进 3）：修订历史的三种出站形状。
 *
 * ⚠ 列表项**不带正文**、详情才带 —— 一次就诊可能有几十版，
 *   列表带正文会让"打开版本抽屉"变成一次几 MB 的响应
 *   （与"病历列表不给正文"同一条纪律，见 `revisions()` 的注释）。
 * ⚠ 详情里的 `sections` 与 `medicalRecordJson(...).sections` **同形状**
 *   （key/label/value/max_len）：客户端已经写好了渲染七段的那段代码，
 *   换一个形状就得再写一遍 —— 而"同一份数据两种形状"是两端不一致的高发地。
 */
func revisionItemJson(r: MedicalRecordRevision): JsonObject {
    let o = JsonObject()
    o.put("version", JsonInt(r.version))
    o.put("status", JsonString(r.status))
    o.put("operation", JsonString(r.operation))
    o.put("reason", JsonString(r.reason))
    o.put("operator_user_id", JsonInt(r.operatorUserId))
    /*
     * ⚠ `operator_role` 可能是**空串**：存量病历补写的那一版没有这个历史信息
     *   （迁移时只有 `updated_by`）。空串对客户端是"未知"，不是"没有角色"。
     */
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

/* 两版的逐段对比（七段都在、顺序 = `emrSections()` 的临床顺序）。 */
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

/* 解锁理由（请求体 `{"reason": "…"}`）；缺字段/类型不对 ⇒ 空串（交给 emrReasonValid 判 400）。 */
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
    /*
     * ★ 本单是否有患者自述（2026-10-14 改进 1）：队列页据此标「预问诊」徽标，
     *   让医生在进病历页**之前**就知道有没有可看的摘要。
     * ⚠ 只要**绑定了本单**的会话才算（"该患者最近有一次问诊单"不算 ——
     *   那会让队列对每张历史单都亮徽标，徽标就失去意义）。
     */
    o.put("previsit_ready", JsonBool(previsitReady))
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
 * ★ 预问诊摘要（2026-10-14 增，改进 1）—— 给**医生**看的患者自述。
 *
 * ⚠ 为什么不直接把 `GET /api/v1/previsit/:sid` 复用过来：那条端点的归属键是
 *   **患者**（会话属于谁），而医生手里只有挂号单。让医生端拿 patient_id 去反查
 *   等于把"这次会话属于哪位患者"这个判断从服务端挪到了客户端 —— 客户端一旦
 *   传错就是**串病历**。这里改成由服务端从**挂号单**派生患者（见路由）。
 *
 * ⚠ 出站字段刻意**不含 patient_id**：
 *   · 医生端已经有这张单的患者信息（队列/病历接口里就有）；
 *   · 摘要接口是"给我这一单的自述"，多给一个 id 只增加泄露面，不增加能力。
 *
 * ⚠ `sections` 只列**已作答**的槽位（不是六个都列）：
 *   医生看的是"患者说了什么"，空槽位是噪音；`filled`/`total` 负责表达完整度。
 *   已完成的会话两者相等，半途的会话医生也能一眼看出缺几项。
 *
 * ⚠ `bound`（是否**绑定了本单**）必须回给出站：
 *   服务端在"本单没绑定"时会回退到该患者最近一次已完成的会话（存量兼容），
 *   但那**未必是这次就诊**填的。前端据此换文案（"本次就诊的预问诊单" vs
 *   "该患者最近一次预问诊单"）—— 不给出站，前端就只能把两者都说成"本次"。
 */
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
 *     · 解锁理由不合法          ⇒ 400 VALIDATION_FAILED（★ 改进 3 新增：
 *                                  理由缺失/过短与"字段填错"同类 —— 是**可以改**的输入问题，
 *                                  不是状态冲突；给 409 会让客户端以为"重试就好"）
 */
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
                             booking: BookingRepo, previsit: PrevisitRepo,
                             emr: MedicalRecordRepo,
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
            arr.add(visitQueueItemJson(a, emr.findByAppointment(a.appointmentId),
                                       previsit.findByAppointment(a.appointmentId, a.patientId).isSome()))
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
     * GET /api/v1/doctor/visits/:id/previsit —— 读该单的预问诊摘要（医生）。
     *
     * 归属：先按挂号单确认"这张单是我的"（不匹配 ⇒ 404，与"不存在"不可区分），
     * 再由**服务端**从挂号单取 `patient_id` 去查会话 —— 患者 id 不接受客户端输入
     * （那等于把"这次会话属于哪位患者"交给客户端判断，传错就是串病历）。
     *
     * 两级来源（响应里的 `bound` 区分）：
     *   ① 绑定了本单的会话 ⇒ `bound = true`（改进 1 之后的新单走这条）；
     *   ② 本单没绑定 ⇒ 该患者最近一次**已完成**的会话 ⇒ `bound = false`（存量兼容：
     *      改进 1 之前挂号从不上报 `previsit_id`，那些历史单永远绑不上）。
     * 两级都没有 ⇒ 404 `PREVISIT_NOT_FOUND`。
     *   ⚠ "这次没填预问诊"是**正常状态**，不是错误，所以错误码必须可判别
     *     （只给一个笼统 404，前端就没法区分"没有摘要"与"单号写错了"）。
     */
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
        let out = emr.lock(id, hNowEpoch(), p.userId, roleName(p.role))
        emrThrowOnFailure(out, "提交病历")
        let locked = emr.findByAppointment(id).getOrThrow()
        let o = medicalRecordJson(locked, true)
        /*
         * ★ 改进 3：本次定稿落下的版本号（前端用它做"已生成第 N 版"的提示）。
         *   ⚠ `0` = **审计行没写上**（`writeRevision` 两次都被唯一键/连接问题挡下），
         *     此时病历**已经锁定**（业务动作成功）—— 客户端不该把这当失败重试锁，
         *     重试会走幂等路径并**自愈**那一版（`ensureLockRevision`）。
         *     契约里 `0` 必须被理解为"版本号未知/待补"，不是"没有版本"。
         */
        o.put("revision_version", JsonInt(out.revisionVersion))
        sendOk(ctx, o)
    })

    /*
     * POST /api/v1/doctor/visits/:id/record/reopen —— 解锁（**仅管理员**）。
     *
     * ⚠ 这是"修订通道"：管理员**不能写病历**（见 can() 的说明），
     *   但需要能解锁让医生改。
     *
     * ★ 2026-10-15（改进 3）两处收紧：
     *   ① 权限从"借 `ManageSchedule`"改为**语义动作** `ManageRecordRevision`
     *      —— 授权结果不变（两者今天都是 admin-only），但将来能只放开其中一个
     *      （见 `Action` 枚举里的理由）。
     *   ② **必须给理由**（`{"reason": "…"}`，4-255 字）：解锁是推翻一份
     *      已经定稿的医疗文书，事由必须留档（理由会落进修订历史，
     *      与"解锁前那一版"的内容一起成为审计证据）。
     *      ⇒ 没有理由的解锁现在是 **400**，而不是静默生效。
     */
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
        /* ★ 本次解锁落下的版本号（= 解锁前那一版；0 = 审计写入失败，病历已解锁）。 */
        o.put("revision_version", JsonInt(out.revisionVersion))
        sendOk(ctx, o)
    })

    /* ========== 二·补、病历修订历史（改进 3） ========== */

    /*
     * 修订历史的读取权限：**医生读自己接诊的单，管理员读任何单，患者没有这条路径**。
     *
     * 顺序有意义：
     *   ① 管理员（`ManageRecordRevision`）⇒ **不受"这是谁的号"限制**：
     *      解锁本来就是他做的，而管理员账号没有 `doctorId` ——
     *      若也要求 `findForDoctor` 命中，这条审计路径对管理员永远 404。
     *   ② 其它角色 ⇒ 必须 `QueryOwnMedicalRecord`（医生/患者都有这条动作），
     *      再确认"这张单是**我的**"：不匹配一律 **404**（与写病历同一口径 ——
     *      区分 403 就是"哪些挂号单存在"的枚举 oracle）。
     *      ⇒ 患者实际走到 ② 会被归属校验挡下（他的 `doctorId` 是 0）⇒ 404。
     * ⚠ 为什么**不给患者**看修订历史：这里含 `reason`（例如"录入错误，解锁重写"）
     *   与 `operator_role` 等内部审计信息。患者要的"这份病历定稿过没有"
     *   由病历接口的 `status` 表达；把内部审计话术直接给患者，
     *   等于让患者替我们做质控解释。
     */
    func requireRevisionRead(p: Principal, id: Int64, visit: VisitRepo): Unit {
        if (can(p.role, Action.ManageRecordRevision)) {
            return
        }
        requireCan(p.role, Action.QueryOwnMedicalRecord)
        if (visit.findForDoctor(id, p.doctorId).isNone()) {
            throw apiErrorMsg("APPOINTMENT_NOT_FOUND", "挂号单不存在或不属于你")
        }
    }

    /*
     * GET /api/v1/doctor/visits/:id/record/revisions —— 该单的全部修订（**升序**）。
     *
     * ⚠ 顺序是 `version ASC`（v1 在前），见 `MedicalRecordRepo.revisions()` 的注释：
     *   "与上一版对比"要的是 `version - 1`，倒序会让"上一版"指向未来。
     *   客户端要"最新在上"自己 reverse 一行即可。
     * ⚠ 列表**不带正文**（版本/操作/理由/操作者/时间）。
     */
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

    /*
     * GET /api/v1/doctor/visits/:id/record/revisions/:version —— 某一版（带正文）。
     *
     * ⚠ 没有修订行 ⇒ 404 `REVISION_NOT_FOUND`（**不是**空对象）：
     *   空对象会让客户端渲染出一个"七段全空的版本"，看起来像病历被清空了。
     * ⚠ 版本号从 **1** 开始（`0`/负数 ⇒ 400）：`version` 是资源标识，不是偏移量。
     */
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

    /*
     * GET /api/v1/doctor/visits/:id/record/revisions/:version/diff?against=N
     *   —— 某一版与另一版的逐段差异（`against` 默认 = **上一版**）。
     *
     * ⚠ 默认"上一版"是"这次改了什么"的默认诉求；但 **v1 没有上一版**，
     *   此时默认值会算成 0 ⇒ 400 并要求显式给 `against`。
     *   刻意**不**退化成"拿 v1 跟自己比"：那会返回"一切未变"，
     *   是一个**看起来成功**的错答案（比报错坏得多）。
     * ⚠ `against == version` 也拒（400）：与自己对比同样是那个假答案。
     */
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
