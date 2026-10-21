package qingzhou

import std.collection.*
import stdx.encoding.json.*
import std.time.*

/*
 * SPDX-License-Identifier: MIT
 *
 * ===== http_base.cj —— 基础数据域的管理端接口（科室 / 医生）==============
 *
 * 职责：科室/医生的管理端 CRUD + 患者可读的字典（id → 名称）
 * 对外：registerBaseRoutes()、baseThrowOnFailure()、NameIndex / nameIndexOf()
 * 权限：admin 路由走 Action.ManageBaseData，字典路由走 Action.ViewBaseData（三端可读）
 * 端点：/api/v1/admin/departments|doctors（CRUD）、/api/v1/departments|doctors（只读目录）
 * 分页：列表认 limit/offset，缺省与上限同为 200（字典表，下拉框不能静默截断）
 * 不变量：患者侧两条字典接口刻意不分页 —— 截断等于"患者选不到某个科室"
 * 不变量：新错误码必须同时补 apiErrorSpec，否则正常业务拒绝会被报成 500
 */

/* 科室 → JSON。 */
public func baseDepartmentJson(d: Department): JsonObject {
    let o = JsonObject()
    o.put("id", JsonInt(d.id))
    o.put("name", JsonString(d.name))
    o.put("code", JsonString(d.code))
    o.put("location", JsonString(d.location))
    o.put("sort", JsonInt(d.sort))
    o.put("enabled", JsonBool(d.enabled))
    o.put("created_at", JsonInt(d.createdAt))
    return o
}

/* 医生 → JSON。 */
public func baseDoctorJson(d: Doctor, departmentName: String): JsonObject {
    let o = JsonObject()
    o.put("id", JsonInt(d.id))
    o.put("name", JsonString(d.name))
    o.put("department_id", JsonInt(d.departmentId))
    /* 带上科室名：省掉客户端自己拼名字（两次查询之间科室可能改名 ⇒ 显示不一致）。 */
    o.put("department_name", JsonString(departmentName))
    o.put("title", JsonString(d.title))
    o.put("specialty", JsonString(d.specialty))
    o.put("enabled", JsonBool(d.enabled))
    o.put("created_at", JsonInt(d.createdAt))
    return o
}

/*
 * 仓储写入结果 → HTTP。错误码走 apiErrorSpec，不在 handler 里手写状态码，
 * 否则同一错误在两处可能给不同状态码。
 */
public func baseThrowOnFailure(out: BaseWriteOutcome): Unit {
    if (out.ok) {
        return
    }
    if (out.notFound) {
        throw apiErrorMsg("BASE_NOT_FOUND", "科室或医生不存在")
    }
    if (out.duplicate) {
        if (out.conflictField == "name") {
            throw apiErrorMsg("BASE_NAME_TAKEN", "同名已存在（科室名必须唯一：分诊按科室名查询）")
        }
        if (out.conflictField == "code") {
            throw apiErrorMsg("BASE_CODE_TAKEN", "该编码已被占用")
        }
        throw apiErrorMsg("BASE_NAME_TAKEN", "同名或同编码已存在")
    }
    if (out.inUse) {
        throw apiErrorMsg("BASE_IN_USE", "不能删除：${out.inUseBy}。可改用 force=true 停用（软删）")
    }
    if (out.invalid) {
        throw apiErrorMsg("VALIDATION_FAILED", out.detail)
    }
    /* 兜底：不该发生，但**不静默**（宁可 500 也不要假装成功）。 */
    throw apiErrorMsg("INTERNAL_ERROR", "写入未成功且原因未知")
}

/* 从请求体读科室（`enabled` 缺省 true —— 新建默认启用）。 */
public func baseDepartmentFromBody(ctx: Context): Department {
    let d = Department()
    d.name = requireStr(ctx, "name").trimAscii()
    d.code = requireStr(ctx, "code").trimAscii()
    d.location = bodyStr(ctx, "location") ?? ""
    d.location = d.location.trimAscii()
    d.sort = bodyInt64(ctx, "sort") ?? 0
    d.enabled = bodyBool(ctx, "enabled") ?? true
    return d
}

/* 从请求体读医生。 */
public func baseDoctorFromBody(ctx: Context): Doctor {
    let d = Doctor()
    d.name = requireStr(ctx, "name").trimAscii()
    match (bodyInt64(ctx, "department_id")) {
        case Some(v) => d.departmentId = v
        case None => throw apiErrorMsg("VALIDATION_FAILED", "缺少 department_id")
    }
    d.title = (bodyStr(ctx, "title") ?? "").trimAscii()
    d.specialty = (bodyStr(ctx, "specialty") ?? "").trimAscii()
    d.enabled = bodyBool(ctx, "enabled") ?? true
    return d
}

/* `?force=true` —— 删除语义的唯一开关（见 domain_base.cj 文件头）。 */
public func baseForceFlag(ctx: Context): Bool {
    let v = ctx.queryParamOr("force", "false")
    return v == "true" || v == "1"
}

/*
 * 医生列表的科室名批量解析：一次读全建 map，不做逐行查询（N+1），
 * 也让同一个响应里的名字来自同一份快照。
 */
public func baseDepartmentsForNames(repo: DepartmentRepo): Array<Department> {
    return repo.listAll()
}

/* 在已读入的科室列表里按 id 找名字（找不到给空串，**不抛**）。 */
public func baseNameOf(depts: Array<Department>, id: Int64): String {
    for (d in depts) {
        if (d.id == id) {
            return d.name
        }
    }
    return ""
}

/*
 * id → 名称的解析能力，全仓复用（/appointments、/schedules、/medical-records 都要补名称）。
 * 补法必须同一套，否则同一份数据在两个响应里名字不同。医生表同理：读全表，避免 N+1。
 */
public func baseDoctorsForNames(repo: DoctorRepo): Array<Doctor> {
    /* 0 = 不限科室（全仓口径，见 `registerBaseRoutes` 里的注释）。 */
    return repo.listAll(0, includeDisabled: true)
}

/* 在已读入的医生列表里按 id 找姓名（找不到给空串，**不抛**）。 */
public func baseDoctorNameOf(docs: Array<Doctor>, id: Int64): String {
    for (d in docs) {
        if (d.id == id) {
            return d.name
        }
    }
    return ""
}

/* 同上，取职称（`主任医师` 之类）。找不到给空串 —— 界面上显示空比显示"null"好。 */
public func baseDoctorTitleOf(docs: Array<Doctor>, id: Int64): String {
    for (d in docs) {
        if (d.id == id) {
            return d.title
        }
    }
    return ""
}

/*
 * 按 id 取单个名称（给"只差一个名称"的单条响应补字段）。
 * 一次性补齐多处必须用批量版 + baseNameOf —— 逐条调本函数就是 N+1。
 */
public func baseDepartmentNameById(dept: DepartmentRepo, id: Int64): String {
    match (dept.findById(id)) {
        case Some(d) => return d.name
        case None => return ""
    }
}

public func baseDoctorNameById(doc: DoctorRepo, id: Int64): String {
    match (doc.findById(id)) {
        case Some(d) => return d.name
        case None => return ""
    }
}

public func baseDoctorTitleById(doc: DoctorRepo, id: Int64): String {
    match (doc.findById(id)) {
        case Some(d) => return d.title
        case None => return ""
    }
}

/*
 * id → 名称的解析表（一次读全，整个请求内复用）：handler 里不会出现"忘了先读表"
 * 或"在循环里查库"，同一个响应里的名称也必然来自同一份快照。
 */
public class NameIndex {
    private let depts: Array<Department>
    private let docs: Array<Doctor>

    public init(depts: Array<Department>, docs: Array<Doctor>) {
        this.depts = depts
        this.docs = docs
    }

    public func departmentName(id: Int64): String {
        return baseNameOf(this.depts, id)
    }

    public func doctorName(id: Int64): String {
        return baseDoctorNameOf(this.docs, id)
    }

    public func doctorTitle(id: Int64): String {
        return baseDoctorTitleOf(this.docs, id)
    }

    /*
     * 把三个名称字段就地写进已有的 JSON 对象：department_name / doctor_name / doctor_title，
     * 与 triage 响应 options[] 的命名逐字一致。找不到写空串而不是省略字段，
     * 客户端因此少一个判空分支。
     */
    public func putInto(o: JsonObject, departmentId: Int64, doctorId: Int64): Unit {
        o.put("department_name", JsonString(this.departmentName(departmentId)))
        o.put("doctor_name", JsonString(this.doctorName(doctorId)))
        o.put("doctor_title", JsonString(this.doctorTitle(doctorId)))
    }
}

/* 读全科室 + 全医生（含停用：历史排班/档案里的旧 id 仍要能解析出名字）。 */
public func nameIndexOf(dept: DepartmentRepo, doc: DoctorRepo): NameIndex {
    return NameIndex(baseDepartmentsForNames(dept), baseDoctorsForNames(doc))
}

/* 列表分页的默认值与上限。两者故意同取 200：科室/医生是字典表，正常规模与可接受规模
 * 同一量级；默认压到 50 只会逼客户端显式传 limit，反而容易"少了一半数据"。 */
public let BASE_LIST_DEFAULT_LIMIT: Int64 = 200
public let BASE_LIST_MAX_LIMIT: Int64 = 200

/*
 * 从 query 取 (limit, offset)。容错口径与 /admin/users 一致：limit 非数字/越界 ⇒
 * BASE_LIST_DEFAULT_LIMIT，offset 负数 ⇒ 0（负偏移在 SQL 里是错误，不能透传）。
 */
func basePageOf(ctx: Context): (Int64, Int64) {
    var limit = parseInt64Or(ctx.queryParamOr("limit", "${BASE_LIST_DEFAULT_LIMIT}"), BASE_LIST_DEFAULT_LIMIT)
    if (limit < 1 || limit > BASE_LIST_MAX_LIMIT) {
        limit = BASE_LIST_DEFAULT_LIMIT
    }
    var offset = parseInt64Or(ctx.queryParamOr("offset", "0"), 0)
    if (offset < 0) {
        offset = 0
    }
    return (limit, offset)
}

/*
 * 注册基础数据域路由。由 http_app.cj 调用，让路由注册集中可见。
 */
public func registerBaseRoutes(r: Router, auth: AuthRepo, gate: DevAuthGate,
                               dept: DepartmentRepo, doc: DoctorRepo): Unit {
    /* ---------- 科室 ---------- */
    r.get("/api/v1/admin/departments", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageBaseData)
        let includeDisabled = (ctx.queryParamOr("include_disabled", "true")) != "false"
        /* 分页（见文件头分页一节）。 */
        let (limit, offset) = basePageOf(ctx)
        let items = JsonArray()
        for (d in dept.listAll(includeDisabled: includeDisabled, limit: limit, offset: offset)) {
            items.add(baseDepartmentJson(d))
        }
        let data = JsonObject()
        data.put("items", items)
        data.put("count", JsonInt(Int64(items.size())))
        /* `total` = 同一 `include_disabled` 过滤下的总行数（count 只是本页条数）。 */
        data.put("total", JsonInt(dept.countAll(includeDisabled: includeDisabled)))
        data.put("limit", JsonInt(limit))
        data.put("offset", JsonInt(offset))
        sendOk(ctx, data)
    })

    r.post("/api/v1/admin/departments", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageBaseData)
        let d = baseDepartmentFromBody(ctx)
        let out = dept.create(d, DateTime.now().toUnixTimeStamp().toSeconds())
        baseThrowOnFailure(out)
        let data = JsonObject()
        data.put("id", JsonInt(out.id))
        match (dept.findById(out.id)) {
            case Some(saved) => data.put("department", baseDepartmentJson(saved))
            case None => ()
        }
        sendCreated(ctx, data)
    })

    r.get("/api/v1/admin/departments/:id", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageBaseData)
        let id = parseInt64Or(ctx.paramOr("id", "0"), 0)
        /* id <= 0 一律按"不存在"处理、不查库：parseInt64Or 对非数字给 0，而 0 不是合法主键。 */
        if (id <= 0) {
            throw apiErrorMsg("BASE_NOT_FOUND", "科室不存在")
        }
        match (dept.findById(id)) {
            case Some(d) =>
                let data = JsonObject()
                data.put("department", baseDepartmentJson(d))
                sendOk(ctx, data)
            case None =>
                /* 404 而不是 403：与 P4 同口径，不制造"这个 id 存在吗"的枚举 oracle。 */
                throw apiErrorMsg("BASE_NOT_FOUND", "科室不存在")
        }
    })

    r.put("/api/v1/admin/departments/:id", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageBaseData)
        let id = parseInt64Or(ctx.paramOr("id", "0"), 0)
        let d = baseDepartmentFromBody(ctx)
        let out = dept.update(id, d)
        baseThrowOnFailure(out)
        let data = JsonObject()
        data.put("id", JsonInt(id))
        match (dept.findById(id)) {
            case Some(saved) => data.put("department", baseDepartmentJson(saved))
            case None => ()
        }
        sendOk(ctx, data)
    })

    r.delete("/api/v1/admin/departments/:id", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageBaseData)
        let id = parseInt64Or(ctx.paramOr("id", "0"), 0)
        let force = baseForceFlag(ctx)
        let out = dept.remove(id, force)
        baseThrowOnFailure(out)
        let data = JsonObject()
        data.put("id", JsonInt(id))
        /* 如实告诉调用方"到底是删了还是停用了" —— 两者的后果不同。 */
        data.put("soft_deleted", JsonBool(force))
        sendOk(ctx, data)
    })

    /* ---------- 医生 ---------- */
    r.get("/api/v1/admin/doctors", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageBaseData)
        /* department_id 用 parseInt64Or(..., 0)：0 = 不过滤，非数字也解析成 0（与全仓一致）。 */
        let depFilter = parseInt64Or(ctx.queryParamOr("department_id", "0"), 0)
        let includeDisabled = (ctx.queryParamOr("include_disabled", "true")) != "false"
        /* 分页（见文件头分页一节）。 */
        let (limit, offset) = basePageOf(ctx)
        let depts = baseDepartmentsForNames(dept)
        let items = JsonArray()
        for (d in doc.listAll(depFilter, includeDisabled: includeDisabled, limit: limit, offset: offset)) {
            items.add(baseDoctorJson(d, baseNameOf(depts, d.departmentId)))
        }
        let data = JsonObject()
        data.put("items", items)
        data.put("count", JsonInt(Int64(items.size())))
        /* `total` 与 `listAll` 用**同一套过滤**（department_id + include_disabled）。 */
        data.put("total", JsonInt(doc.countAll(depFilter, includeDisabled: includeDisabled)))
        data.put("limit", JsonInt(limit))
        data.put("offset", JsonInt(offset))
        sendOk(ctx, data)
    })

    r.post("/api/v1/admin/doctors", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageBaseData)
        let d = baseDoctorFromBody(ctx)
        let out = doc.create(d, DateTime.now().toUnixTimeStamp().toSeconds())
        baseThrowOnFailure(out)
        let data = JsonObject()
        data.put("id", JsonInt(out.id))
        let depts = baseDepartmentsForNames(dept)
        match (doc.findById(out.id)) {
            case Some(saved) =>
                data.put("doctor", baseDoctorJson(saved, baseNameOf(depts, saved.departmentId)))
            case None => ()
        }
        sendCreated(ctx, data)
    })

    r.get("/api/v1/admin/doctors/:id", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageBaseData)
        let id = parseInt64Or(ctx.paramOr("id", "0"), 0)
        if (id <= 0) {
            throw apiErrorMsg("BASE_NOT_FOUND", "医生不存在")
        }
        match (doc.findById(id)) {
            case Some(d) =>
                let depts = baseDepartmentsForNames(dept)
                let data = JsonObject()
                data.put("doctor", baseDoctorJson(d, baseNameOf(depts, d.departmentId)))
                sendOk(ctx, data)
            case None => throw apiErrorMsg("BASE_NOT_FOUND", "医生不存在")
        }
    })

    r.put("/api/v1/admin/doctors/:id", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageBaseData)
        let id = parseInt64Or(ctx.paramOr("id", "0"), 0)
        let d = baseDoctorFromBody(ctx)
        let out = doc.update(id, d)
        baseThrowOnFailure(out)
        let data = JsonObject()
        data.put("id", JsonInt(id))
        let depts = baseDepartmentsForNames(dept)
        match (doc.findById(id)) {
            case Some(saved) =>
                data.put("doctor", baseDoctorJson(saved, baseNameOf(depts, saved.departmentId)))
            case None => ()
        }
        sendOk(ctx, data)
    })

    r.delete("/api/v1/admin/doctors/:id", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageBaseData)
        let id = parseInt64Or(ctx.paramOr("id", "0"), 0)
        let force = baseForceFlag(ctx)
        let out = doc.remove(id, force)
        baseThrowOnFailure(out)
        let data = JsonObject()
        data.put("id", JsonInt(id))
        data.put("soft_deleted", JsonBool(force))
        sendOk(ctx, data)
    })

    /*
     * 患者可读的字典（不带 admin 前缀：它们不是管理接口，是目录）。
     * 患者端只有 id，没有这条通道就只能显示「科室 #810003」，而挂号页显示科室名。
     * 只读、只给展示字段，停用科室不返回；历史排班里的旧名仍由 nameIndexOf（含停用）解析。
     */
    r.get("/api/v1/departments", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ViewBaseData)
        let items = JsonArray()
        /* `includeDisabled: false` —— 目录只给启用的（见上面的说明）。 */
        for (d in dept.listAll(includeDisabled: false)) {
            items.add(baseDepartmentJson(d))
        }
        let data = JsonObject()
        data.put("items", items)
        data.put("count", JsonInt(Int64(items.size())))
        sendOk(ctx, data)
    })

    r.get("/api/v1/doctors", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ViewBaseData)
        /* department_id 口径同上：0 = 不过滤。 */
        let depFilter = parseInt64Or(ctx.queryParamOr("department_id", "0"), 0)
        let depts = baseDepartmentsForNames(dept)
        let items = JsonArray()
        for (d in doc.listAll(depFilter, includeDisabled: false)) {
            items.add(baseDoctorJson(d, baseNameOf(depts, d.departmentId)))
        }
        let data = JsonObject()
        data.put("items", items)
        data.put("count", JsonInt(Int64(items.size())))
        sendOk(ctx, data)
    })
}
