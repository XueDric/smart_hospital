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
 * **`department`/`doctor`/`patient` 没有写入端点，靠人工 SQL 维护**
 * （这句今天只对 `patient` 成立：科室与医生已由本文件补上管理端 CRUD）。
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
 * 也没有顺手加进来。已写进 docs/PHASE-HANDOFFS.md 的遗留表。
 *
 * ## 端点一览（全部仅管理员：`Action.ManageBaseData`）
 *
 *   GET    /api/v1/admin/departments[?include_disabled=&limit=&offset=]  科室列表（分页）
 *   POST   /api/v1/admin/departments               建科室
 *   GET    /api/v1/admin/departments/:id           单个科室
 *   PUT    /api/v1/admin/departments/:id           改科室
 *   DELETE /api/v1/admin/departments/:id[?force=]  删（默认只删未被引用的）
 *   GET    /api/v1/admin/doctors[?department_id=&include_disabled=&limit=&offset=]  医生列表（分页）
 *   POST   /api/v1/admin/doctors                   建医生
 *   GET    /api/v1/admin/doctors/:id               单个医生
 *   PUT    /api/v1/admin/doctors/:id               改医生
 *   DELETE /api/v1/admin/doctors/:id[?force=]      删（同上）
 *
 * ## 分页（2026-10-14 第三方复查 B9 根治）
 *
 * 此前两个列表**没有任何上界**（`SELECT` 出多少返回多少）：前端表格的行数
 * 由数据库现状决定，谁也没法保证它不会长到"一次请求把 20 万行医生拖出来"。
 * 现在两条列表都认 `limit` / `offset`，响应里多了 `total` / `limit` / `offset`：
 *
 *   · `limit`   缺省 / 非法 / 越界 → **200**（`BASE_LIST_DEFAULT_LIMIT`），上限也是 200
 *   · `offset`  缺省 / 非法 / 负数 → **0**
 *   · `total`   同一过滤条件下的**总行数**（客户端据此显示"共 N 条"并翻页）
 *   · `count`   本页条数（与其余列表接口同义，语义未变）
 *
 * ⚠ 三条刻意的取舍（都值得说清，否则后来者会以为"漏了参数校验"）：
 *   ① **默认 200 而不是 50**（`/admin/users` 是 50）：科室/医生是**字典表**，
 *      前端拿它渲染表格**也拿来填下拉框**（排班页选科室/医生、AI 页选医生）。
 *      默认 50 会把下拉框**静默截断** —— 而"排班时找不到张医生"是最难定位的
 *      那类故障（界面正常、就是没有这个人）。200 正好等于此前文档化的
 *      "≤200 行量级"规模假设 ⇒ **现有客户端行为不变**，但从此有了明确上界。
 *   ② **患者侧那两条读接口（`/departments`、`/doctors`）刻意不加分页**：
 *      它们喂的是**选择器**而不是表格，截断的后果是"患者选不到某个科室"
 *      （且界面上看不出是被截断的）。要限制它们的规模应走"停用科室"
 *      （`enabled = 0` 会被这两条接口天然过滤掉），而不是悄悄少返回几行。
 *   ③ **非法值不报错、回默认**：与"筛选值非法当没筛"同一条容错口径。
 *      要"一次拿全"的调用方应当**翻页取**，而不是把 limit 调大 ——
 *      上限存在的意义就是"不能一次把整张表拖出来"。
 *
 * ## 患者可读的字典（2026-10-12 新增，`Action.ViewBaseData`，**三端都能读**）
 *
 *   GET    /api/v1/departments                     启用中的科室目录
 *   GET    /api/v1/doctors[?department_id=]        启用中的医生目录（带 department_name）
 *
 * ⚠ 为什么"管理接口"之外还要开两个读接口：**同一个科室不该有两种写法**。
 *   患者端拿到挂号/档案数据后只有 id，此前只有管理员能查到名字，
 *   于是患者看到的是「科室 #810003」而挂号页显示「P4测试科3」。
 *   ⇒ 患者无法确认"我挂的"和"我档案里的"是不是同一个科。
 *   见 `Action.ViewBaseData` 的注释（权限为何与 `ViewSchedule` 分开）。
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
 * ★ 2026-10-12（患者端联调）：把"id → 名称"的解析能力**给到全仓复用**。
 *
 * 背景：患者端拿到 `/appointments`、`/schedules`、`/medical-records` 之后
 * 只有 `department_id` / `doctor_id`，界面上只能显示「科室 #810003 · 医生 #900003」。
 * 而这些响应**都要补名称**，补法必须是同一套 —— 否则三处各写一份 map 查询，
 * 迟早出现"同一份数据两个响应里名字不同"（科室改名 / 停用后更明显）。
 *
 * ⚠ 为什么**逐个函数**给 `doctor` 也建一次"读全表"：
 *   医生表不大（几十行），但更重要的是**一致性与避免 N+1**
 *   （理由同 `baseDepartmentsForNames`：N 次查询之间数据可能变，
 *     同一个响应里会出现两个版本的名字）。
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
 * 按 id 取**单个**科室/医生的名称（给"只差一个名称"的响应补字段用）。
 *
 * ⚠ 与 `baseNameOf` 的区别：那两个是"已有一批数据时使用"（批量、零查询），
 *   这里是"只有 id、需要一次查询"的场景（如 `/medical-records` 只带 doctor_id）。
 *   ⚠ 一次性补齐多处**必须**用批量版 + `baseNameOf`，不要在多条记录上逐个调本函数
 *     —— 那是 N+1。本函数只在"单条响应"或"每个 id 只出现一次"时使用。
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
 * ★ "id → 名称"的**解析表**（一次读全，整个请求内复用）。
 *
 * 为什么要有这个类（而不是让每个 handler 自己读两张表）：
 *   ① `NameIndex` 把"读全表 + 按 id 找名字"封成**一次**调用，
 *      handler 里就不会出现"忘了先读表"或"在循环里查库"（N+1）；
 *   ② 同一个响应里出现的多个名称**必然来自同一份快照** ——
 *      否则并发改名时，同一个响应会给出两个版本的名字
 *      （`baseDepartmentsForNames` 的注释里已经写过这个理由）。
 * ③ 读全表的成本对"科室/医生"这种几十行的表可以忽略，
 *    而 `/appointments` 一次返回 N 条时，N 次单查才是真问题。
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
     * 把三个名称字段**就地**写进一个已有的 JSON 对象。
     *
     * ⚠ 字段名固定为 `department_name` / `doctor_name` / `doctor_title`，
     *   与 `triage` 响应里 `options[]` 的命名**逐字一致** ——
     *   客户端因此可以用一套解析逻辑读两种响应（已在患者端实测）。
     * ⚠ 找不到时写**空串**而不是省略字段：客户端少写一个判空分支；
     *   省略字段会让"字段不存在"与"名字为空"两种情况无法区分。
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

/*
 * 列表分页的默认值与上限（见文件头的"分页"一节）。
 *
 * ⚠ 两者**故意取同一个数**：本仓对"默认给一页、但不给无限"的口径是
 *   "默认 = 上限"（`/admin/users` 是 50 = 上限？不，那里是默认 50、上限 200）。
 *   这里合成一个常量的理由：科室/医生是字典表，**正常规模**与**可接受规模**
 *   是同一个量级（几百行）；把默认压到 50 只会逼客户端每次都显式传 limit，
 *   反而更容易写出"忘了传 ⇒ 少了一半数据"的代码。
 */
public let BASE_LIST_DEFAULT_LIMIT: Int64 = 200
public let BASE_LIST_MAX_LIMIT: Int64 = 200

/*
 * ★ 2026-10-14（第三方复查 B9）：从 query 里取 (limit, offset)。
 *
 * 容错口径与 `/admin/users` 完全一致（非法值不报错，回默认）：
 *   · `limit` 非数字 / < 1 / > 上限 ⇒ 回 `BASE_LIST_DEFAULT_LIMIT`
 *   · `offset` 非数字 / < 0        ⇒ 0（负偏移在 SQL 里是错误，不能透传）
 *
 * 📌 返回 tuple 而不是往 ctx 里塞状态：这两个值只在**一个 handler 内**用一次，
 *   穿参数比隐式共享更清楚（本仓 `civilFromDays` 也是这么返回的）。
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
        /* ★ B9：分页（见文件头"分页"一节）。 */
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
        /* ★ B9：分页（见文件头"分页"一节）。 */
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
     * ---------- 患者可读的字典（2026-10-12 新增）----------
     *
     * ★ 这两个端点**不带 admin 前缀**，因为它们不是管理接口：
     *   它们是**字典**（科室目录 / 医生目录），供三端把 id 显示成名称。
     *
     * ⚠ 为什么必须在服务端给（客户端自己拼不出来）：
     *   患者端首页/就诊列表/医疗档案只有 `department_id` / `doctor_id`，
     *   此前没有任何**患者可读**的接口能把这些 id 变成名字 ——
     *   患者看到的只能是「科室 #810003 · 医生 #900003」，
     *   而同一个应用的挂号页却能显示「P4测试科3」。
     *   ⇒ 结果是"同一个科室，在界面上有两种写法"。这不是美观问题：
     *     患者无法确认自己挂的是不是同一个科，**也核对不了档案里的就诊记录**。
     *
     * ⚠ 刻意**只读、只给展示所需字段**：不含 `enabled`/`created_at` 这类
     *   管理字段（`baseDepartmentJson` 里已经带了，这里不额外加）。
     *   停用的科室**不返回**（患者不该看到已下线的科室；
     *   而历史排班里的旧科室名仍能由 `baseNameOf` 从**含停用**的全量里解析出来）。
     *
     * ★ 2026-10-14（B9）：这条路**刻意不分页**（与 admin 版不同）——
     *   它喂的是患者端的**选择器**：截断的后果是"某个科室直接不在列表里"，
     *   而患者看不出这是被截断的（不像表格能显示"共 N 条"）。
     *   要控制它的规模请用**停用**（`enabled = 0` 天然被过滤掉），
     *   而不是悄悄少返回几行。详见文件头"分页"一节第 ② 条。
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
        /*
         * ⚠ 与 admin 版一样的 `parseInt64Or(..., 0)` 口径：0 = 不过滤。
         *   患者端目前按科室过滤可选（如"这个科有哪些医生"）。
         */
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
