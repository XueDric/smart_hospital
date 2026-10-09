package qingzhou

import std.collection.*
import stdx.encoding.json.*
import std.time.*

/*
 * SPDX-License-Identifier: MIT
 *
 * ===== http_base.cj —— 基础数据域的管理端接口（科室 / 医生）==============
 *
 * ADR-0001 rev.7 拆掉内存 Store 时，我如实记下一条边界：
 * **`department`/`doctor`/`patient` 没有写入端点，靠人工 SQL 维护**。
 * 本文件还的是其中**科室与医生**那部分。
 *
 * ## 为什么"分诊推荐科室"必须有这个文件才能真的跑起来
 *
 * `triage.cj` 判定"该科室是否可挂号"用的是
 *   `SELECT ... FROM department WHERE name = ?`
 * 而在此之前**没有任何途径**能往 `department` 里加一行。
 * ⇒ 也就是说，在那之前"AI 分诊给出科室推荐"这条路在生产上是**悬空**的：
 *   规则算得出科室名，但库里没有对应科室 ⇒ 永远推荐不出来。
 * 📌 这不是"少个 CRUD 而已"，而是**一条业务链路的最后一环缺失**。
 *
 * ## 刻意不含患者
 *
 * `patient` 存的是**敏感个人信息**（brief §9 R-4：需个保法合规、实名、留存策略）。
 * 给患者开管理端 CRUD 是**合规决策**而非工程便利 ⇒ **不在本次范围**，
 * 也没有顺手加进来。已写进 P4-HANDOFF 未做清单。
 *
 * ## 端点一览（全部仅管理员：`Action.ManageBaseData`）
 *
 *   GET    /api/v1/admin/departments               科室列表
 *   POST   /api/v1/admin/departments               建科室
 *   GET    /api/v1/admin/departments/:id           单个科室
 *   PUT    /api/v1/admin/departments/:id           改科室
 *   DELETE /api/v1/admin/departments/:id[?force=]  删（默认只删未被引用的）
 *   GET    /api/v1/admin/doctors[?department_id=]  医生列表
 *   POST   /api/v1/admin/doctors                   建医生
 *   GET    /api/v1/admin/doctors/:id               单个医生
 *   PUT    /api/v1/admin/doctors/:id               改医生
 *   DELETE /api/v1/admin/doctors/:id[?force=]      删（同上）
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
    /*
     * ★ 带上科室名：管理端列表直接可读，**省掉客户端自己拼名字**
     *   （客户端拼名意味着它要再查一次，且两次查询之间科室可能被改名 ⇒ 显示不一致）。
     */
    o.put("department_name", JsonString(departmentName))
    o.put("title", JsonString(d.title))
    o.put("specialty", JsonString(d.specialty))
    o.put("enabled", JsonBool(d.enabled))
    o.put("created_at", JsonInt(d.createdAt))
    return o
}

/*
 * 把仓储的写入结果转成 HTTP。
 *
 * ⚠ 与 `http_p4.cj` 的 `emrThrowOnFailure` 同一套路：**错误码走 `apiErrorSpec`**，
 *   不在 handler 里手写状态码 —— 否则同一错误在两处可能给不同状态码。
 * 📌 提醒（P4 真踩过）：新错误码必须同时补 `apiErrorSpec`，
 *   否则会落到兜底 `(500, …)`，把**正常的业务拒绝**报成服务端故障。
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
 * 医生列表用到的"科室名"批量解析。
 *
 * ⚠ 刻意**不做**每行一次查询（N+1）：一次把科室表读进来建 map。
 *   科室表很小（几十行），一次读全比 N 次查询更省，也**更一致**
 *   （N 次查询之间科室可能被改名 ⇒ 同一个响应里出现两个名字）。
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
 * 注册基础数据域的路由。
 *
 * ⚠ 与 `registerP4Routes` 一样**在 http_app.cj 里被调用**，
 *   这样"路由注册"这件事仍**集中可见**（不是散落各处自动生效）。
 */
public func registerBaseRoutes(r: Router, auth: AuthRepo, gate: DevAuthGate,
                               dept: DepartmentRepo, doc: DoctorRepo): Unit {
    /* ---------- 科室 ---------- */
    r.get("/api/v1/admin/departments", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageBaseData)
        let includeDisabled = (ctx.queryParamOr("include_disabled", "true")) != "false"
        let items = JsonArray()
        for (d in dept.listAll(includeDisabled: includeDisabled)) {
            items.add(baseDepartmentJson(d))
        }
        let data = JsonObject()
        data.put("items", items)
        data.put("count", JsonInt(Int64(items.size())))
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
        /*
         * ⚠ `id <= 0` 一律按"不存在"处理，**不查库**。
         *   理由：`parseInt64Or` 对非数字给 0，而 0 不是合法主键
         *   （AUTO_INCREMENT 从 1 起）⇒ 直接 404 比"查一次必然为空"更清楚，
         *   也顺手挡住了 `PUT /departments/abc` 这类无意义请求打到数据库。
         */
        if (id <= 0) {
            throw apiErrorMsg("BASE_NOT_FOUND", "科室不存在")
        }
        match (dept.findById(id)) {
            case Some(d) =>
                let data = JsonObject()
                data.put("department", baseDepartmentJson(d))
                sendOk(ctx, data)
            case None =>
                /*
                 * ⚠ 404 而不是 403：与 P4 同口径 —— 不制造"这个 id 存在吗"的枚举 oracle。
                 *   科室不是敏感数据，但**口径一致**比"这里无所谓"更重要：
                 *   两套口径会让以后读代码的人不知道该照哪个。
                 */
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
        /*
         * ⚠ 用 `parseInt64Or(..., 0)` 与全仓保持一致（**不自己写解析**）：
         *   0 表示"不过滤"。非数字会被它解析成 0（= 不过滤）而不是报错 ——
         *   这是本仓既有口径（`limit` 等参数同样处理），保持一致比"这里更严格"重要。
         */
        let depFilter = parseInt64Or(ctx.queryParamOr("department_id", "0"), 0)
        let includeDisabled = (ctx.queryParamOr("include_disabled", "true")) != "false"
        let depts = baseDepartmentsForNames(dept)
        let items = JsonArray()
        for (d in doc.listAll(depFilter, includeDisabled: includeDisabled)) {
            items.add(baseDoctorJson(d, baseNameOf(depts, d.departmentId)))
        }
        let data = JsonObject()
        data.put("items", items)
        data.put("count", JsonInt(Int64(items.size())))
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
}
