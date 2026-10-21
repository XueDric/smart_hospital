/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 *
 * ===== http_app.cj —— HTTP 应用装配 + 挂号闭环接口（P1）=====================
 *
 * 职责：路由装配与全部 REST 端点（鉴权 / AI 配置 / 分诊 / 预问诊 / 挂号退号 / 排班 / 健康检查）
 * 对外：buildHospitalApp() 装配 Middleware；can() 与 requireCan() 是唯一权限入口
 * 中间件顺序：requestId → logger → bodyLimit → bodyParser → cors → timeout → 静态层 → router.middleware
 * 不变量：bodyLimit 必须在 bodyParser 之前；timeout 与静态层必须在 router.middleware() 之前
 *         —— router 命中即调 handler 且不调 next，其后注册的中间件永不执行
 * 不变量：并发安全由 BookingRepo 的数据库事务保证，本文件不引入新锁
 */

package qingzhou

import std.collection.*
import std.time.*
import stdx.encoding.json.*


/*
 * 三端角色。仓颉枚举不能用 == 比较，角色判定一律走 match 或 roleName() 转字符串。
 */
public enum Role {
    | Patient
    | Doctor
    | Admin
}

public func roleName(r: Role): String {
    match (r) {
        case Patient => return "patient"
        case Doctor => return "doctor"
        case Admin => return "admin"
    }
}

public func roleOf(name: String): ?Role {
    if (name == "patient") {
        return Some(Role.Patient)
    }
    if (name == "doctor") {
        return Some(Role.Doctor)
    }
    if (name == "admin") {
        return Some(Role.Admin)
    }
    return None
}

/* 权限动作。按语义划分而非按"当前谁能做"划分，否则日后无法单独放开其中一条。 */
public enum Action {
    | ViewSchedule        // 查排班（三端都能看）
    | Book                // 挂号（仅患者）
    | CancelOwn           // 取消自己的挂号（患者）
    | CancelAny           // 取消任意挂号（管理员）
    | ManageSchedule      // 维护排班与号源（管理员）
    /*
     * 病历读写分开：患者只能读自己的，医生只能写自己接诊的。"自己的"含义不同
     * （患者 patient_id / 医生 doctor_id），合成一条就无法在 can() 里表达。
     */
    | QueryOwnMedicalRecord   // 读自己的病历（患者读自己的；医生读自己接诊的）
    | WriteOwnMedicalRecord   // 写自己的病历（仅医生）
    | ManageVisit             // 接诊队列的状态流转（仅医生，限自己的号）
    | ViewDashboard           // 运营看板（仅管理员）
    /* 维护科室/医生档案（仅管理员）。不复用 ManageSchedule：主数据与号源日后要能分别放开。 */
    | ManageBaseData          // 维护科室/医生档案（仅管理员）
    /* 知识库读侧只给医生与管理员：原始文档含未定稿/已停用内容，不因"只读"就放开。 */
    | QueryKnowledgeBase      // 检索知识库（医生 + 管理员；**患者不给**）
    | ManageKnowledgeBase     // 维护知识库文档（仅管理员）
    /* 三端可见的公开数据：科室/医生目录、公告。患者端要显示科室名就必须读得到。
     * 公告写侧 ManageNotice 只给管理员。 */
    | ViewBaseData            // 读科室/医生目录（三端都能看）
    | ViewNotice              // 读公告（三端都能看）
    | ManageNotice            // 维护公告（仅管理员）
    /* AI 配置与账号管理各自独立成动作（原借用 ManageSchedule）：都仍是 admin-only，
     * 但将来放开排班权限不会连带放开 AI 密钥引用与账号 —— 静默越权不会有测试变红。 */
    | ManageAi                // 维护 AI 配置（设置/Prompt/工具/模型，含密钥引用）（仅管理员）
    | ManageUser              // 维护账号与口令（建号/改口令/列号）（仅管理员）
    /* 解锁病历与读修订审计（仅管理员）。不复用 ManageSchedule：放宽排班不得连带
     * 放开"推翻已定稿医疗文书"。 */
    | ManageRecordRevision    // 解锁病历与读修订审计（仅管理员）
}

public func actionName(a: Action): String {
    match (a) {
        case ViewSchedule => return "view_schedule"
        case Book => return "book"
        case CancelOwn => return "cancel_own"
        case CancelAny => return "cancel_any"
        case ManageSchedule => return "manage_schedule"
        case QueryOwnMedicalRecord => return "query_own_medical_record"
        case WriteOwnMedicalRecord => return "write_own_medical_record"
        case ManageVisit => return "manage_visit"
        case ManageBaseData => return "manage_base_data"
        case QueryKnowledgeBase => return "query_knowledge_base"
        case ManageKnowledgeBase => return "manage_knowledge_base"
        case ViewBaseData => return "view_base_data"
        case ViewNotice => return "view_notice"
        case ManageNotice => return "manage_notice"
        case ViewDashboard => return "view_dashboard"
        case ManageAi => return "manage_ai"
        case ManageUser => return "manage_user"
        case ManageRecordRevision => return "manage_record_revision"
    }
}

/*
 * 权限判定的唯一入口（handler 内禁止手写 if）。患者：view_schedule / book / cancel_own /
 * query_own_medical_record / view_base_data / view_notice；医生另有 write_own_medical_record 与
 * manage_visit；其余 cancel_any / manage_* / view_dashboard 仅管理员。管理员不能写病历，
 * 纠错走 reopen。未实现的动作不发权。
 */
public func can(role: Role, action: Action): Bool {
    match (action) {
        case ViewSchedule => return true
        case Book =>
            match (role) {
                case Patient => return true
                case _ => return false
            }
        case CancelOwn =>
            match (role) {
                case Patient => return true
                case _ => return false
            }
        case CancelAny =>
            match (role) {
                case Admin => return true
                case _ => return false
            }
        case ManageSchedule =>
            match (role) {
                case Admin => return true
                case _ => return false
            }
        case QueryOwnMedicalRecord =>
            match (role) {
                case Patient => return true
                case Doctor => return true
                case _ => return false
            }
        case WriteOwnMedicalRecord =>
            match (role) {
                case Doctor => return true
                case _ => return false
            }
        case ManageVisit =>
            match (role) {
                case Doctor => return true
                case _ => return false
            }
        case ManageBaseData =>
            match (role) {
                case Admin => return true
                case _ => return false
            }
        /* 知识库读侧：医生 + 管理员，不给患者。 */
        case QueryKnowledgeBase =>
            match (role) {
                case Admin => return true
                case Doctor => return true
                case _ => return false
            }
        case ManageKnowledgeBase =>
            match (role) {
                case Admin => return true
                case _ => return false
            }
        /* 科室/医生目录与公告：三端可见（公开数据，无患者私有信息）。 */
        case ViewBaseData => return true
        case ViewNotice => return true
        case ManageNotice =>
            match (role) {
                case Admin => return true
                case _ => return false
            }
        case ViewDashboard =>
            match (role) {
                case Admin => return true
                case _ => return false
            }
        /* 逐条列出而不合并为 ManageAi | ManageUser：两者日后极可能分道扬镳。 */
        case ManageAi =>
            match (role) {
                case Admin => return true
                case _ => return false
            }
        case ManageUser =>
            match (role) {
                case Admin => return true
                case _ => return false
            }
        /* 解锁已定稿病历 = 推翻临床记录，仅管理员。 */
        case ManageRecordRevision =>
            match (role) {
                case Admin => return true
                case _ => return false
            }
    }
}

/* 权限不满足时抛 FORBIDDEN_ROLE（403）。 */
public func requireCan(role: Role, action: Action): Unit {
    if (!can(role, action)) {
        throw apiErrorMsg("FORBIDDEN_ROLE",
                          "角色 ${roleName(role)} 无权执行 ${actionName(action)}")
    }
}

/* ===================== 身份识别（开发态，明确标注） ===================== */

/*
 * 当前请求的身份。principalOf() 与 can() 的唯一契约：身份来源变化不影响权限与业务逻辑。
 */
public class Principal {
    public var userId: Int64 = 0
    public var role: Role = Role.Patient
    public var patientId: Int64 = 0
    public var doctorId: Int64 = 0
    public var loginName: String = ""
    /* 令牌当前有效期（epoch 秒），必须是滑动续期之后的值；开发态身份无令牌 ⇒ 保持 0。 */
    public var expiresAt: Int64 = 0
}

    /*
     * 开发态身份开关，临时形态，生产禁用。三重保险：须显式 --dev-auth；每请求打一行
     * [DEV-AUTH] 告警；传 --prod 时直接拒绝启动。用命令行开关而非环境变量：本仓 std 无 getEnv。
     */
public class DevAuthGate {
    public let enabled: Bool

    public init(enabled: Bool, prod: Bool) {
        if (enabled && prod) {
            throw Exception("拒绝启动：--prod 时不允许开启 --dev-auth。" +
                            "开发态身份头会绕过全部认证，生产环境必须走令牌。")
        }
        this.enabled = enabled
    }
}

/*
 * 解析身份，优先级：Bearer 令牌 → 开发态头（仅 --dev-auth 且仅回环来源）→ 401 AUTH_REQUIRED。
 * 先看令牌，避免误开 --dev-auth 时正式请求走开发态分支；非回环来源直接 401，不静默放行。
 */

/*
 * 客户端 IP 是否回环：127.0.0.0/8、::1、[::1]、::ffff:127.x.y.z；其余（含空串）都不是。
 */
func isLoopbackIp(ip: String): Bool {
    let s = ip.trimAscii()
    if (s.size == 0) {
        return false
    }
    if (s == "::1" || s == "[::1]") {
        return true
    }
    if (startsWithAscii(s, "127.")) {
        return true
    }
    if (startsWithAscii(s, "::ffff:127.")) {
        return true
    }
    return false
}

public func principalOf(ctx: Context, gate: DevAuthGate, auth: AuthRepo): Principal {
    let now = hNowEpoch()

    /* 1) 正式路径：Bearer 令牌 */
    match (bearerToken(ctx)) {
        case Some(tok) =>
            match (auth.principalByToken(tok, now)) {
                case Some(p) => return p
                case None =>
                    throw apiErrorMsg("AUTH_TOKEN_EXPIRED",
                                      "令牌无效或已过期，请重新登录")
            }
        case None => ()
    }

    /* 2) 开发态身份头（仅 --dev-auth 下，且仅回环来源） */
    if (gate.enabled) {
        /* 先判来源再看头：非回环来源直接 401。remoteIp() 为空 = 进程内直调，按本机处理并告警。 */
        let remoteIp = ctx.remoteIp()
        if (remoteIp.size == 0) {
            println("[DEV-AUTH] ⚠ 无法取得客户端地址（无 http ctx）——按本机处理")
        } else if (!isLoopbackIp(remoteIp)) {
            throw apiErrorMsg("AUTH_REQUIRED",
                              "开发态身份头（X-Role 等）只允许本机回环地址使用" +
                              "（来源 ${remoteIp}）；远程请走 Authorization: Bearer <token>")
        }
        match (ctx.requestHeader("X-Role")) {
            case Some(roleStr) =>
                let role = match (roleOf(roleStr)) {
                    case Some(r) => r
                    case None => throw apiErrorMsg("VALIDATION_FAILED", "未知角色：${roleStr}")
                }
                let p = Principal()
                p.role = role
                println("[DEV-AUTH] ${ctx.method()} ${ctx.path()} 以 ${roleName(role)} 身份放行" +
                        "（开发态；生产必须走令牌）")
                match (ctx.requestHeader("X-Patient-Id")) {
                    case Some(v) => p.patientId = parseInt64Or(v, 0)
                    case None => ()
                }
                match (ctx.requestHeader("X-Doctor-Id")) {
                    case Some(v) => p.doctorId = parseInt64Or(v, 0)
                    case None => ()
                }
                return p
            case None => ()
        }
    }

    /* 3) 都没有 → 401 */
    throw apiErrorMsg("AUTH_REQUIRED", "缺少 Authorization: Bearer <token>")
}

/* 取出 Authorization: Bearer <token>。 */
public func bearerToken(ctx: Context): ?String {
    match (ctx.requestHeader("authorization")) {
        case Some(v) =>
            if (!startsWithAscii(v.toAsciiLower(), "bearer ")) {
                return None
            }
            let t = subFrom(v, 7).trimAscii()
            if (t.size == 0) {
                return None
            }
            return Some(t)
        case None => return None
    }
}

/*
 * 退号归属判定：管理员可退任意单；患者只退自己的单，按 patient 归属（不是 user 归属）。
 * 角色权限与归属判定合并在本函数，handler 不再手写 if。
 */
public func canCancel(role: Role, actorPatientId: Int64, appointmentPatientId: Int64,
                      actorUserId: Int64, appointmentOwnerUserId: Int64): Bool {
    if (can(role, Action.CancelAny)) {
        return true
    }
    if (can(role, Action.CancelOwn)) {
        return actorPatientId > 0 && actorPatientId == appointmentPatientId
    }
    return false
}


/* 请求体必须是 JSON 对象；否则 400（不让框架抛 500）。 */
public func bodyObj(ctx: Context): JsonObject {
    if (ctx.bodyJsonError().isSome()) {
        throw apiErrorMsg("VALIDATION_FAILED", "请求体不是合法 JSON")
    }
    match (ctx.bodyJson()) {
        case Some(v) =>
            match (v) {
                case o: JsonObject => return o
                case _ => throw apiErrorMsg("VALIDATION_FAILED", "请求体必须是 JSON 对象")
            }
        case None =>
            return JsonObject()
    }
}

/* BookingResult → 客户端 JSON 契约。 */
func bookingJson(r: BookingResult): JsonObject {
    let o = JsonObject()
    o.put("appointment_id", JsonInt(r.appointmentId))
    o.put("schedule_id", JsonInt(r.scheduleId))
    o.put("patient_id", JsonInt(r.patientId))
    o.put("doctor_id", JsonInt(r.doctorId))
    o.put("department_id", JsonInt(r.departmentId))
    o.put("visit_date", JsonString(r.visitDate))     // 就诊日快照
    o.put("period", JsonString(r.period))
    o.put("seq_no", JsonInt(r.seqNo))
    o.put("status", JsonString(r.status))
    /* 就诊时间线（到院/开始/完成）三端都给；0 = 该步未发生。status 与 status_label 同时给。 */
    o.put("status_label", JsonString(visitStatusLabel(r.status)))
    o.put("arrived_at", JsonInt(r.arrivedAt))
    o.put("started_at", JsonInt(r.startedAt))
    o.put("finished_at", JsonInt(r.finishedAt))
    // 号源是否已归还必须回给客户端，否则它不知道上次那条 SlotNotRestored 告警是否还在。
    o.put("slot_restored", JsonBool(r.slotRestored))
    return o
}

/*
 * 挂号/退号响应完整形状 = bookingJson + 科室/医生名 + 当前余号。
 * remain_num 在写成功之后重读排班：它属于"事务之后"的快照，不属于 BookingResult。
 * 排班已删 ⇒ 不写该字段（写 0 会被界面读成"已约满"）。previsitBound 传 None ⇒ 字段不出现。
 */
func bookingJsonFull(repo: BookingRepo, r: BookingResult, names: NameIndex,
                     ctx: Context, previsitBound!: ?Bool = None): JsonObject {
    let o = bookingJson(r)
    names.putInto(o, r.departmentId, r.doctorId)
    match (repo.findSchedule(r.scheduleId)) {
        case Some(s) => o.put("remain_num", JsonInt(s.remainNum))
        case None => ()
    }
    match (previsitBound) {
        case Some(b) => o.put("previsit_bound", JsonBool(b))
        case None => ()
    }
    putTrace(ctx, o)
    return o
}

/*
 * 往业务响应体写 request_id + server_time（epoch 秒），纯增量字段，不改变既有字段语义。
 * ctx._id 由 requestId() 中间件填充。
 */
func putTrace(ctx: Context, o: JsonObject): Unit {
    /* ctx._id 由 requestId() 中间件填充；未装配时为空串，照原样回，不编造日志里查不到的编号。 */
    o.put("request_id", JsonString(ctx._id))
    o.put("server_time", JsonInt(hNowEpoch()))
}


/* 路由装配。全部路径带 /api/v1 前缀；身份统一取自 principalOf(ctx, gate, auth)。 */
/*
 * 从 X-Device-Id / X-Device-Name 取设备标识（均可选）。两值一律不可信，只用于会话列表展示，
 * 绝不参与授权；长度截到 64 以免撞 MySQL "Data too long" 把接口打成 500。
 */
func deviceOf(ctx: Context): (String, String) {
    let id = match (ctx.requestHeader("x-device-id")) {
        case Some(v) => v.trimAscii()
        case None => ""
    }
    let name = match (ctx.requestHeader("x-device-name")) {
        case Some(v) => v.trimAscii()
        case None => ""
    }
    return (truncate64(id), truncate64(name))
}

/*
 * 校验 YYYY-MM-DD 形状（4-2-2）。只查形状不查日历真实性。不要用 parseInt64Or：
 * 它会把 2026-13-99 静默截成 2026。
 */
func isDateLike(s: String): Bool {
    if (s.size != 10) {
        return false
    }
    /* s.toArray() 给 UInt8，与 Rune 不能直接比较；统一转 Int64 与 ASCII 码比。 */
    let a = s.toArray()
    var i: Int64 = 0
    while (i < 10) {
        let c = Int64(a[i])
        if (i == 4 || i == 7) {
            if (c != 0x2D) {
                return false
            }
        } else if (!(c >= 0x30 && c <= 0x39)) {
            return false
        }
        i = i + 1
    }
    return true
}

/* 写入排班必须是日历中真实存在的日期；形状检查仍供只读筛选使用。 */
func hIsCalendarDate(s: String): Bool {
    if (!isDateLike(s)) {
        return false
    }
    let a = s.toArray()
    let year = (Int64(a[0]) - 0x30) * 1000 + (Int64(a[1]) - 0x30) * 100 +
               (Int64(a[2]) - 0x30) * 10 + Int64(a[3]) - 0x30
    let month = (Int64(a[5]) - 0x30) * 10 + Int64(a[6]) - 0x30
    let day = (Int64(a[8]) - 0x30) * 10 + Int64(a[9]) - 0x30
    if (year <= 0 || month < 1 || month > 12 || day < 1) {
        return false
    }
    var maxDay: Int64 = 31
    if (month == 4 || month == 6 || month == 9 || month == 11) {
        maxDay = 30
    } else if (month == 2) {
        maxDay = if (year % 400 == 0 || (year % 4 == 0 && year % 100 != 0)) { 29 } else { 28 }
    }
    return day <= maxDay
}

/*
 * s 是否全为 ASCII 数字（非空）。用于显式校验 from/to 等查询参数 ——
 * parseInt64Or 会把 abc 静默当成"没给参数"。
 */
func hIsAllDigits(s: String): Bool {
    if (s.size == 0) {
        return false
    }
    let a = s.toArray()
    var i: Int64 = 0
    while (i < a.size) {
        if (a[i] < 0x30 || a[i] > 0x39) {
            return false
        }
        i = i + 1
    }
    return true
}

/* 两个已校验的固定宽度日期按 ASCII 比较，医院日期不依赖宿主机时区。 */
func hScheduleDateIsPast(s: String): Bool {
    let date = s.toArray()
    let today = hTodayDate().toArray()
    var i: Int64 = 0
    while (i < 10) {
        if (date[i] != today[i]) {
            return Int64(date[i]) < Int64(today[i])
        }
        i = i + 1
    }
    return false
}

func truncate64(s: String): String {
    if (s.size <= 64) {
        return s
    }
    return s[0..64]
}
/*
 * epoch 天数 → (年, 月, 日)，用 Howard Hinnant civil_from_days：无闰年表、无循环。
 * std.time 的 DateTime 按本地时区解释，不适用于稳定可比的日期串。
 */
func civilFromDays(z0: Int64): (Int64, Int64, Int64) {
    var z = z0
    z = z + 719468
    var era: Int64 = 0
    if (z >= 0) {
        era = z / 146097
    } else {
        era = (z - 146096) / 146097
    }
    let doe = z - era * 146097
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
    let y = yoe + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    var m: Int64 = 0
    if (mp < 10) {
        m = mp + 3
    } else {
        m = mp - 9
    }
    var yy = y
    if (m <= 2) {
        yy = y + 1
    }
    return (yy, m, d)
}

/*
 * 两位补零：日期串必须固定宽度，否则字符串比较会让 9 月排在 10 月之后。
 * 加 triage 前缀是因为单 package 下与框架的 pad2 重载冲突。
 */
func triagePad2(n: Int64): String {
    if (n < 10) {
        return "0${n}"
    }
    return "${n}"
}

/*
 * 全服务端唯一的时区口径：Asia/Shanghai（固定 +8，无夏令时）。
 * "今天"是医院的业务概念，不跟随宿主机时区，否则同一份数据在不同机器上答案不同。
 * 偏移只在这里加一次。
 */
public let HOSPITAL_TZ_OFFSET_SECONDS: Int64 = 8 * 3600

/*
 * epoch 毫秒 → Asia/Shanghai 天序。负数须向下取整（仓颉整除是截断，-1/86400000 = 0）。
 */
func hDaysFromMillisShanghai(ms: Int64): Int64 {
    let shifted = ms + HOSPITAL_TZ_OFFSET_SECONDS * 1000
    var days = shifted / 86400000
    if (shifted < 0 && shifted % 86400000 != 0) {
        days = days - 1
    }
    return days
}

/* epoch 秒 → Asia/Shanghai 天序（同上，负数同样向下取整）。 */
func hDaysFromSecondsShanghai(secs: Int64): Int64 {
    let shifted = secs + HOSPITAL_TZ_OFFSET_SECONDS
    var days = shifted / 86400
    if (shifted < 0 && shifted % 86400 != 0) {
        days = days - 1
    }
    return days
}

/*
 * 今天的日期 YYYY-MM-DD（Asia/Shanghai）。参与 work_date >= today 的字符串比较，须固定宽度。
 */
func hTodayDate(): String {
    let ms = DateTime.now().toUnixTimeStamp().toMilliseconds()
    let (y, m, d) = civilFromDays(hDaysFromMillisShanghai(ms))
    return "${y}-${triagePad2(m)}-${triagePad2(d)}"
}

/*
 * epoch 秒 → YYYY-MM-DD（Asia/Shanghai）。与 hTodayDate() 共用同一偏移，
 * 否则公告日期与"今天"的判定会再次分家。
 */
public func hDateStringOf(secs: Int64): String {
    let (y, m, d) = civilFromDays(hDaysFromSecondsShanghai(secs))
    return "${y}-${triagePad2(m)}-${triagePad2(d)}"
}

/* 主诉输入上限：字符 500（实际裁剪用）、字节 1500（防超长 UTF-8 刷日志/内存）。 */
let TRIAGE_INPUT_MAX_CHARS: Int64 = 500
let TRIAGE_INPUT_MAX_BYTES: Int64 = 1500

/*
 * 按字符截取前 n 个。String 下标是字节偏移，直接 s[0..n] 会切在汉字中间 ⇒ 非法 UTF-8。
 */
func triageTruncateChars(s: String, n: Int64): String {
    let buf = ArrayList<Rune>()
    for (r in s.runes()) {
        if (buf.size >= n) {
            break
        }
        buf.add(r)
    }
    return String(buf.toArray())
}
/*
 * 分诊结论 → 响应体。redFlagEvidence 是内部依据（命中哪些词），不出站：
 * 给患者看是复述，给攻击者看会暴露词表结构。
 */
/*
 * 为分诊取知识库参考片段（旁路增强）。永不抛异常：检索失败当作"没有参考资料"。
 * 危急征象时不检索 —— 与 aiEnhanceTriage 不调模型同一理由，且判断要在检索之前。
 */
func triageRagHits(kb: KbRepo, complaint: String, v: TriageVerdict): Array<KbHit> {
    if (v.redFlag) {
        return Array<KbHit>()
    }
    try {
        let res = kb.searchKeyword(complaint, topN: KB_SEARCH_TOP_N)
        return res.hits
    } catch (e: Exception) {
        /* 检索失败 ⇒ 当作没有参考资料，分诊照常。 */
        return Array<KbHit>()
    }
}

func triageJson(v: TriageVerdict, truncated: Bool): JsonObject {
    let o = JsonObject()
    o.put("red_flag", JsonBool(v.redFlag))
    o.put("reason_code", JsonString(v.reasonCode))
    o.put("source", JsonString(v.source))
    o.put("patient_note", JsonString(v.patientNote))
    o.put("truncated", JsonBool(truncated))
    /* 只增不改：ai_note = 模型给患者的说明，ai_reason = 为什么没给（给运维看，不含密钥）。
     * source 语义不变：model / model:invalid / rules。 */
    o.put("ai_note", JsonString(v.aiNote))
    o.put("ai_reason", JsonString(v.aiReason))
    let arr = ArrayList<JsonValue>()
    for (x in v.options) {
        let e = JsonObject()
        e.put("department_id", JsonInt(x.departmentId))
        e.put("department_name", JsonString(x.departmentName))
        e.put("doctor_id", JsonInt(x.doctorId))
        e.put("doctor_name", JsonString(x.doctorName))
        e.put("doctor_title", JsonString(x.doctorTitle))
        e.put("schedule_id", JsonInt(x.scheduleId))
        e.put("work_date", JsonString(x.workDate))
        e.put("period", JsonString(x.period))
        e.put("remain_num", JsonInt(x.remainNum))
        e.put("total_remain", JsonInt(x.totalRemain))
        arr.add(e)
    }
    o.put("options", JsonArray(arr.toArray()))
    o.put("count", JsonInt(v.options.size))
    return o
}
/*
 * 预问诊会话 → 响应体（业务值，只走非流式）。form 仅在 complete() 为真时输出，
 * 未完成只给 progress（已填项数/总项数），半成品问诊单不得交给医生。
 */
func previsitSessionJson(s: PrevisitSession): JsonObject {
    let o = JsonObject()
    o.put("session_id", JsonString(s.id))
    o.put("turn", JsonInt(s.turn))
    o.put("filled", JsonInt(s.form.filled()))
    o.put("total_slots", JsonInt(intakeSlots().size))
    o.put("complete", JsonBool(s.form.complete()))
    let next = s.nextSlot()
    o.put("next_slot", JsonString(match (next) {
        case Some(sl) => sl.key
        case None => ""
    }))
    // 下一个问题一并给出（是问句文本，不是业务值）
    o.put("next_question", JsonString(match (next) {
        case Some(sl) => sl.question
        case None => ""
    }))
    if (s.form.complete()) {
        let f = JsonObject()
        for (sl in intakeSlots()) {
            if (s.form.answers.contains(sl.key)) {
                f.put(sl.key, JsonString(s.form.answers[sl.key]))
            }
        }
        o.put("form", f)
    }
    return o
}
/*
 * 健康检查响应体（/health 与 /api/v1/health 共用同一实现）。只回服务活着 + 版本 + 数据后端 +
 * 开发态鉴权开关 + 医院今天，不查库。today/timezone 让客户端不必自己算时区。
 */
/*
 * 当场探一次库：db.ok 来自一次真实往返（SELECT 1，不碰业务表）。库不通 ⇒ 503 + db.ok=false；
 * ok 的口径 = 进程活着且库通。失败原因不回驱动原文（本端点不鉴权），细节只进 [HEALTH] 日志。
 */
func healthBody(gate: DevAuthGate, dbProbe: ?DbProbe): (Bool, String) {
    var dbOk = true
    var dbReconnects: Int64 = 0
    match (dbProbe) {
        case Some(f) =>
            let (ok, n, reason) = f()
            dbOk = ok
            dbReconnects = n
            if (!ok) {
                println("[HEALTH] 库探活失败：${reason}")
            }
        case None => ()
    }
    let o = JsonObject()
    o.put("ok", JsonBool(dbOk))
    o.put("service", JsonString("hospital-server"))
    o.put("version", JsonString(SERVER_VERSION))
    o.put("data_backend", JsonString("mysql"))
    o.put("dev_auth", JsonBool(gate.enabled))
    o.put("today", JsonString(hTodayDate()))
    o.put("timezone", JsonString("Asia/Shanghai"))
    let d = JsonObject()
    d.put("ok", JsonBool(dbOk))
    d.put("reconnects", JsonInt(dbReconnects))
    if (!dbOk) {
        d.put("reason", JsonString("数据库暂不可用（详见服务端日志）"))
    }
    o.put("db", d)
    return (dbOk, o.toString())
}

/* 两个 /health 路径共用：只探一次库，按结果给 200 / 503。 */
func sendHealth(ctx: Context, gate: DevAuthGate, dbProbe: ?DbProbe): Unit {
    let (dbOk, body) = healthBody(gate, dbProbe)
    let code: Int64 = if (dbOk) { 200 } else { 503 }
    ctx.status(code).json(body)
}

public func buildHospitalRouter(repo: BookingRepo, auth: AuthRepo, gate: DevAuthGate, triage: TriageRepo, previsit: PrevisitRepo, aiSettings: AiSettingsRepo, aiModels: AiModelRepo, prompts: PromptRepo,
                           emr: MedicalRecordRepo, visit: VisitRepo,
                           dash: DashboardRepo, triageStat: TriageStatRepo,
                           dept: DepartmentRepo, doc: DoctorRepo, kb: KbRepo,
                           notices: NoticeRepo,
                           dbProbe!: ?DbProbe): Router {
    let r = Router()

    /* ---------- 健康检查（无需认证，供压测与探活）---------- */
    /* ⚠ /health 不在 /api/v1 下（探针与压测脚本按此写死）；/api/v1/health 是给客户端拼 base-url 的别名。
     * 两条都调同一份 healthJson，不存在两份实现。 */
    r.get("/health", { ctx: Context, _: () -> Unit =>
        sendHealth(ctx, gate, dbProbe)
    })
    r.get("/api/v1/health", { ctx: Context, _: () -> Unit =>
        sendHealth(ctx, gate, dbProbe)
    })
    /* 不注册 GET /admin → /admin/：静态层前缀 "/admin" 会连余部为空的请求一起认领，那条路由永远轮不到。
     * 前端因此必须用绝对路径引用资源（/admin/css/style.css）。 */
    /* ===================== 鉴权接口 ===================== */

    /* ---------- POST /api/v1/auth/login —— 登录换令牌 ---------- */
    r.post("/api/v1/auth/login", { ctx: Context, _: () -> Unit =>
        let loginName = requireStr(ctx, "login_name")
        let password = requireStr(ctx, "password")
        let now = hNowEpoch()
        // 设备标识（可选、不可信，仅用于会话列表展示 —— 见 deviceOf 注释）
        let (devId, devName) = deviceOf(ctx)
        let res = auth.login(loginName, password, now, deviceId: devId, deviceName: devName)
        if (res.succeeded()) {
            let o = JsonObject()
            o.put("token", JsonString(res.token))
            o.put("expires_at", JsonInt(res.expiresAt))
            match (auth.findUser(loginName)) {
                case Some(u) =>
                    o.put("user_id", JsonInt(u.id))
                    o.put("role", JsonString(roleName(u.role)))
                    o.put("ref_id", JsonInt(u.refId))
                    o.put("display_name", JsonString(u.displayName))
                    /* patient_id 按角色给：只有患者回 ref_id，其它角色回 0（与 /auth/me 保持一致）。 */
                    let loginPatientId = match (u.role) {
                        case Patient => u.refId
                        case _ => 0
                    }
                    o.put("patient_id", JsonInt(loginPatientId))
                case None => ()
            }
            sendOk(ctx, o)
            return
        }
        if (res.locked) {
            /* 被限流：429 + Retry-After。按登录名计数，auth_login_attempt 与 auth_user 无外键，
             * 所以对存在/不存在的账号一视同仁，不构成账号枚举 oracle。 */
            ctx.header("retry-after", res.retryAfterSeconds.toString())
            throw apiError("AUTH_RATE_LIMITED")
        }
        /* 账号不存在与口令错误同码 AUTH_BAD_CREDENTIALS：分开回等于告诉攻击者这个手机号注册过。 */
        throw apiError("AUTH_BAD_CREDENTIALS")
    })

    /* ---------- POST /api/v1/auth/logout —— 登出（吊销当前令牌）---------- */
    r.post("/api/v1/auth/logout", { ctx: Context, _: () -> Unit =>
        let tok = match (bearerToken(ctx)) {
            case Some(t) => t
            case None => throw apiError("AUTH_REQUIRED")
        }
        // 先确认令牌有效（无效令牌登出应报 401，而不是假装成功）
        let _ = principalOf(ctx, gate, auth)
        let _ = auth.revokeToken(tok)
        let o = JsonObject()
        o.put("logged_out", JsonBool(true))
        sendOk(ctx, o)
    })

    
/* ---------- GET /api/v1/auth/sessions —— 我的活跃会话（按设备）---------- */
/*
 * 令牌按设备管理。只看自己的会话（p.userId），没有管理员看别人会话的入口；返回里不含 token。
 * 管理员要踢人走"重置口令"（会吊销该账号全部令牌）。
 */
r.get("/api/v1/auth/sessions", { ctx: Context, _: () -> Unit =>
    let p = principalOf(ctx, gate, auth)
    let now = hNowEpoch()
    let list = auth.listSessions(p.userId, now)
    let arr = ArrayList<JsonValue>()
    for (s in list) {
        let o = JsonObject()
        o.put("device_id", JsonString(s.deviceId))
        o.put("device_name", JsonString(s.deviceName))
        o.put("created_at", JsonInt(s.createdAt))
        o.put("last_seen_at", JsonInt(s.lastSeenAt))
        o.put("expires_at", JsonInt(s.expiresAt))
        arr.add(o)
    }
    let o = JsonObject()
    o.put("sessions", JsonArray(arr.toArray()))
    o.put("count", JsonInt(list.size))
    sendOk(ctx, o)
})

/* ---------- POST /api/v1/auth/sessions/revoke —— 踢掉指定设备的会话 ---------- */
/*
 * 只作用于自己（p.userId），不信任请求体里的 user_id；device_id 为空 ⇒ 400，不删全部会话。
 */
r.post("/api/v1/auth/sessions/revoke", { ctx: Context, _: () -> Unit =>
    let p = principalOf(ctx, gate, auth)
    let deviceId = requireStr(ctx, "device_id")
    if (deviceId.size == 0) {
        throw apiErrorMsg("VALIDATION_FAILED", "device_id 不能为空（踢全部会话请用 /auth/logout-all）")
    }
    let n = auth.revokeSessionsByDevice(p.userId, deviceId)
    let o = JsonObject()
    o.put("revoked", JsonInt(n))
    o.put("device_id", JsonString(deviceId))
    sendOk(ctx, o)
})

/* ---------- POST /api/v1/auth/logout-all —— 踢掉自己全部会话 ---------- */
r.post("/api/v1/auth/logout-all", { ctx: Context, _: () -> Unit =>
    let p = principalOf(ctx, gate, auth)
    let n = auth.revokeAllTokens(p.userId)
    let o = JsonObject()
    o.put("revoked", JsonInt(n))
    sendOk(ctx, o)
})

/* ---------- GET /api/v1/auth/me —— 当前身份 ---------- */
    r.get("/api/v1/auth/me", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        let o = JsonObject()
        o.put("user_id", JsonInt(p.userId))
        o.put("role", JsonString(roleName(p.role)))
        o.put("patient_id", JsonInt(p.patientId))
        o.put("doctor_id", JsonInt(p.doctorId))
        /* 补 display_name：principalByToken 只填 userId/role/patientId/doctorId，这里按 userId 查一次。
         * 查不到（账号已删）不带该字段也不报错 —— 令牌有效即会话成立，回 404 会让客户端卡在登录态。 */
        match (auth.findUserById(p.userId)) {
            case Some(u) => o.put("display_name", JsonString(u.displayName))
            case None => ()
        }
        let (devId, _devName) = deviceOf(ctx)
        o.put("device_id", JsonString(devId))
        /* 回当前令牌有效期（滑动续期之后）。dev-auth 下无令牌 ⇒ 0，客户端应理解为"非令牌会话"。 */
        o.put("expires_at", JsonInt(p.expiresAt))
        sendOk(ctx, o)
    })

    /* ---------- POST /api/v1/admin/users —— 建账号（仅管理员）---------- */
    /* 建账号受"认证 + 管理员"双重保护。AuthRepo.createUser 幂等，所以下面要自己判重。 */
    r.post("/api/v1/admin/users", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageUser)
        let loginName = requireStr(ctx, "login_name")
        let password = requireStr(ctx, "password")
        let roleStr = requireStr(ctx, "role")
        let role = match (roleOf(roleStr)) {
            case Some(r) => r
            case None => throw apiErrorMsg("VALIDATION_FAILED", "未知角色：${roleStr}")
        }
        var refId: Int64 = 0
        match (bodyInt64(ctx, "ref_id")) {
            case Some(v) => refId = v
            case None => ()
        }
        // ref_id：患者/医生必填（指向业务实体），管理员为 0。仓颉枚举不能用 ==，角色判定走 match/roleName()
        match (role) {
            case Patient =>
                if (refId <= 0) {
                    throw apiErrorMsg("VALIDATION_FAILED", "患者账号必须给 ref_id（patient.id）")
                }
            case Doctor =>
                if (refId <= 0) {
                    throw apiErrorMsg("VALIDATION_FAILED", "医生账号必须给 ref_id（doctor.id）")
                }
            case Admin => ()
        }
        let displayName = match (bodyStr(ctx, "display_name")) {
            case Some(v) => v
            case None => loginName
        }
        /* 登录名已存在 ⇒ 409 USER_EXISTS，不静默复用：否则会出现"建号成功但 password 被忽略"。 */
        if (auth.findUser(loginName).isSome()) {
            throw apiErrorMsg("USER_EXISTS",
                              "登录名已存在：${loginName}（要改口令请调 POST /api/v1/admin/users/:id/password）")
        }
        let uid = auth.createUser(loginName, role, refId, displayName, password, hNowEpoch())
        let o = JsonObject()
        o.put("user_id", JsonInt(uid))
        o.put("role", JsonString(roleName(role)))
        sendCreated(ctx, o)
    })

    /* ---------- GET /api/v1/admin/users —— 账号查询 / 列表（仅管理员）---------- */
    /* 只返回非敏感字段，绝不回 pw_salt / pw_hash（给管理员也不回）。
     * 给了 login_name ⇒ 精确查单条（找不到 404 USER_NOT_FOUND）；否则列表模式（limit/offset/role/status）。 */
    r.get("/api/v1/admin/users", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageUser)
        let loginName = ctx.queryParamOr("login_name", "")
        if (loginName.size > 0) {
            match (auth.findUser(loginName)) {
                case Some(u) =>
                    let o = JsonObject()
                    o.put("user_id", JsonInt(u.id))
                    o.put("login_name", JsonString(u.loginName))
                    o.put("role", JsonString(roleName(u.role)))
                    o.put("ref_id", JsonInt(u.refId))
                    o.put("display_name", JsonString(u.displayName))
                    o.put("status", JsonString(u.status))
                    sendOk(ctx, o)
                case None => throw apiErrorMsg("USER_NOT_FOUND", "账号不存在：${loginName}")
            }
            return
        }
        /* limit 缺省 50、夹到 1..200；非法值回默认，offset 负数夹到 0（负偏移在 SQL 里是错误）。 */
        var limit = parseInt64Or(ctx.queryParamOr("limit", "50"), 50)
        if (limit < 1 || limit > 200) {
            limit = 50
        }
        var offset = parseInt64Or(ctx.queryParamOr("offset", "0"), 0)
        if (offset < 0) {
            offset = 0
        }
        let roleFilter = ctx.queryParamOr("role", "")
        let statusFilter = ctx.queryParamOr("status", "")
        let rows = auth.listUsers(limit, offset, roleFilter, statusFilter)
        let items = JsonArray()
        var n: Int64 = 0
        for (u in rows) {
            let e = JsonObject()
            /* 列表项键名与精确查询一致（user_id 而非 id）。 */
            e.put("user_id", JsonInt(u.id))
            e.put("login_name", JsonString(u.loginName))
            e.put("role", JsonString(roleName(u.role)))
            e.put("ref_id", JsonInt(u.refId))
            e.put("display_name", JsonString(u.displayName))
            e.put("status", JsonString(u.status))
            items.add(e)
            n = n + 1
        }
        let o = JsonObject()
        o.put("items", items)
        o.put("count", JsonInt(n))
        o.put("total", JsonInt(auth.countUsers(roleFilter, statusFilter)))
        o.put("limit", JsonInt(limit))
        o.put("offset", JsonInt(offset))
        sendOk(ctx, o)
    })

    /* ---------- POST /api/v1/admin/users/:id/password —— 重置口令（仅管理员）---------- */
    /* 重置口令会吊销该账号全部令牌：改口令必须踢下线，否则"口令泄露后补救"无效。 */
    r.post("/api/v1/admin/users/:id/password", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageUser)
        let uid = parseInt64Or(ctx.paramOr("id", "0"), 0)
        if (uid <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "user_id 必须是正整数")
        }
        let password = requireStr(ctx, "password")
        // 先确认账号存在（否则 UPDATE 影响 0 行、却回 200 —— 那是撒谎）
        if (!auth.userExists(uid)) {
            throw apiErrorMsg("USER_NOT_FOUND", "账号不存在：${uid}")
        }
        auth.setPassword(uid, password, hNowEpoch())
        let o = JsonObject()
        o.put("user_id", JsonInt(uid))
        o.put("tokens_revoked", JsonBool(true))
        sendOk(ctx, o)
    })

    /* ===================== AI 能力中心 ===================== */

    /* 三条设计要点：① 改配置零重启（写库 → invalidate() → 下次读拿到新值）；
     * ② 密钥绝不落库也绝不回显，库里只存引用（env: / file:），回显只说"是否已设置"；
     * ③ 读写都仅管理员（Action.ManageAi）。 */

    /* ---------- GET /api/v1/admin/ai/settings —— 读配置（仅管理员，秘密项脱敏）---------- */
    r.get("/api/v1/admin/ai/settings", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageAi)
        sendOk(ctx, aiSettingsJson(aiSettings, hNowEpoch()))
    })

    /* ---------- PUT /api/v1/admin/ai/settings/:key —— 改一项配置（仅管理员）---------- */
    /* 用 PUT + 路径参数：配置项是幂等的键值写，且"改了哪一项"在访问日志里一眼可见。 */
    r.put("/api/v1/admin/ai/settings/:key", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageAi)
        let key = ctx.paramOr("key", "")
        /* 命名空间闸门：本端点只写 ai.* 静态登记项。AiSettingsRepo.put() 是共享入口，其登记判定
         * 还认 prompt.* 与 ai.tool.*，不收窄就能绕过 PromptRepo 的占位符/长度校验直接落库。 */
        if (aiSettingSpecOf(key).isNone()) {
            throw apiErrorMsg("VALIDATION_FAILED",
                "配置项 ${key} 不在本端点的登记表里；" +
                "Prompt 模板改走 PUT /api/v1/admin/ai/prompts/:name，" +
                "工具开关改走 PUT /api/v1/admin/ai/tools/:name")
        }
        let value = match (bodyStr(ctx, "value")) {
            case Some(v) => v
            case None => ""
        }
        let res = aiSettings.put(key, value, hNowEpoch())
        if (!res.ok) {
            /* 拒绝原因如实回给调用方，但不回显被拒的值：那可能是一个误写成裸密钥的值。 */
            throw apiErrorMsg("VALIDATION_FAILED", res.rejected)
        }
        sendOk(ctx, aiSettingsJson(aiSettings, hNowEpoch()))
    })

    /* ---------- GET /api/v1/admin/ai/prompts —— 读 Prompt 模板（仅管理员）---------- */
    /* Prompt 正文原样回显（它不是机密，管理员要能核对）；只有密钥才脱敏。 */
    r.get("/api/v1/admin/ai/prompts", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageAi)
        sendOk(ctx, aiPromptsJson(prompts, hNowEpoch()))
    })

    /* ---------- PUT /api/v1/admin/ai/prompts/:name —— 改模板（仅管理员）---------- */
    r.put("/api/v1/admin/ai/prompts/:name", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageAi)
        let name = ctx.paramOr("name", "")
        let text = match (bodyStr(ctx, "body")) {
            case Some(v) => v
            case None => ""
        }
        let res = prompts.put(name, text, hNowEpoch())
        if (!res.ok) {
            throw apiErrorMsg("VALIDATION_FAILED", res.rejected)
        }
        sendOk(ctx, aiPromptsJson(prompts, hNowEpoch()))
    })

    /* ---------- DELETE /api/v1/admin/ai/prompts/:name —— 恢复默认模板（仅管理员）---------- */
    r.delete("/api/v1/admin/ai/prompts/:name", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageAi)
        let name = ctx.paramOr("name", "")
        if (!prompts.reset(name, hNowEpoch())) {
            throw apiErrorMsg("VALIDATION_FAILED", "未知的 Prompt：${name}")
        }
        sendOk(ctx, aiPromptsJson(prompts, hNowEpoch()))
    })

    /* ---------- GET /api/v1/admin/ai/tools —— AI 工具开关（仅管理员）---------- */
    r.get("/api/v1/admin/ai/tools", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageAi)
        sendOk(ctx, aiToolsJson(aiSettings, hNowEpoch()))
    })

    /* ---------- PUT /api/v1/admin/ai/tools/:name —— 开关某工具（仅管理员）---------- */
    /* enabled 只接受布尔 true/false，不接受 "1"/"yes"/"on"。 */
    r.put("/api/v1/admin/ai/tools/:name", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageAi)
        let name = ctx.paramOr("name", "")
        let on = match (bodyBool(ctx, "enabled")) {
            case Some(b) => b
            case None => throw apiErrorMsg("VALIDATION_FAILED", "缺少必填字段 enabled（true/false）")
        }
        let res = aiToolSet(aiSettings, name, on, hNowEpoch())
        if (!res.ok) {
            throw apiErrorMsg("VALIDATION_FAILED", res.rejected)
        }
        sendOk(ctx, aiToolsJson(aiSettings, hNowEpoch()))
    })
    /* ---------- DELETE /api/v1/admin/ai/settings/:key —— 删一项（回到默认值）---------- */
    r.delete("/api/v1/admin/ai/settings/:key", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageAi)
        let key = ctx.paramOr("key", "")
        /* 收窄必须与 PUT 一致：共享的 aiSettingKeyKnown 认三个命名空间，否则
         * DELETE /admin/ai/settings/prompt.dept 会绕过 prompts 端点把 Prompt 行删回默认值。 */
        if (aiSettingSpecOf(key).isNone()) {
            throw apiErrorMsg("VALIDATION_FAILED",
                "配置项 ${key} 不在本端点的登记表里；" +
                "Prompt 模板改走 DELETE /api/v1/admin/ai/prompts/:name，" +
                "工具开关改走 PUT /api/v1/admin/ai/tools/:name（工具没有『删除』语义，只有开关）")
        }
        if (!aiSettings.remove(key, hNowEpoch())) {
            throw apiErrorMsg("VALIDATION_FAILED", "未知的配置项：${key}")
        }
        sendOk(ctx, aiSettingsJson(aiSettings, hNowEpoch()))
    })
    /* ===================== AI 模型配置（ai_model 表）===================== */
    /* 分工：ai/settings 是全局 KV（总开关/超时/并发/全局密钥引用），ai/models 是一个模型一行。
     * 运行期取"默认对话模型"那一行整体覆盖 KV，不做逐字段合并。权限同为 Action.ManageAi。 */

    /* ---------- GET /api/v1/admin/ai/models —— 列表（仅管理员）---------- */
    r.get("/api/v1/admin/ai/models", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageAi)
        /* include_disabled 默认 "true"，只有字面 "false" 才过滤停用（与科室/医生/公告同口径）。 */
        let includeDisabled = ctx.queryParamOr("include_disabled", "true") != "false"
        let now = hNowEpoch()
        let globalKeyRefSet = aiSettings.get(SET_AI_KEY_REF, now).trimAscii().size > 0
        let items = JsonArray()
        var n: Int64 = 0
        for (m in aiModels.list(includeDisabled, now)) {
            items.add(aiModelJson(m, globalKeyRefSet, inUse: aiModelInUse(aiModels, m, now)))
            n = n + 1
        }
        let o = JsonObject()
        o.put("items", items)
        o.put("count", JsonInt(n))
        /* global_key_ref_set 一并回：管理台据此标出「自带密钥 / 用全局密钥 / 没有密钥」。 */
        o.put("global_key_ref_set", JsonBool(globalKeyRefSet))
        o.put("cache_ttl_secs", JsonInt(AI_MODEL_CACHE_TTL_SECS))
        sendOk(ctx, o)
    })

    /* ---------- POST /api/v1/admin/ai/models —— 新增一条（仅管理员）---------- */
    r.post("/api/v1/admin/ai/models", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageAi)
        let m = AiModel()
        m.name = bodyStrOr(ctx, "name", "")
        m.kind = bodyStrOr(ctx, "kind", "")
        m.provider = bodyStrOr(ctx, "provider", "")
        m.baseUrl = bodyStrOr(ctx, "base_url", "")
        m.model = bodyStrOr(ctx, "model", "")
        /* 缺省值只在这里给（温度 0.3、上限 2048）：写入路径要把"没给"与"给了非法值"分开，
         * 后者必须 400，不能静默变默认。 */
        m.temperature = match (bodyFloatOpt(ctx, "temperature")) {
            case Some(v) => v
            case None => AI_MODEL_SEED_CHAT_TEMPERATURE
        }
        m.maxTokens = match (bodyInt64(ctx, "max_tokens")) {
            case Some(v) => v
            case None => AI_MODEL_SEED_MAX_TOKENS
        }
        m.keyRef = bodyStrOr(ctx, "key_ref", "")
        m.enabled = match (bodyBool(ctx, "enabled")) {
            case Some(v) => v
            case None => true
        }
        m.isDefault = match (bodyBool(ctx, "is_default")) {
            case Some(v) => v
            case None => false
        }
        let res = aiModels.create(m, hNowEpoch(), p.userId)
        if (res.duplicate) {
            throw apiErrorMsg("AI_MODEL_NAME_TAKEN", "同名模型配置已存在：${m.name.trimAscii()}")
        }
        if (!res.ok) {
            throw apiErrorMsg("VALIDATION_FAILED", res.invalid)
        }
        let created = aiModels.get(res.id, hNowEpoch())
        let o = JsonObject()
        o.put("id", JsonInt(res.id))
        match (created) {
            case Some(row) =>
                let now2 = hNowEpoch()
                o.put("model", aiModelJson(row, aiSettings.get(SET_AI_KEY_REF, now2).trimAscii().size > 0,
                                          inUse: aiModelInUse(aiModels, row, now2)))
            case None => ()
        }
        sendCreated(ctx, o)
    })

    /* ---------- POST /api/v1/admin/ai/models/invalidate —— 失效配置缓存 ---------- */
    /* 正常写操作内部已 invalidate()；此入口用于跨实例与直改库两种情形（TTL 最迟 5 秒收敛）。 */
    r.post("/api/v1/admin/ai/models/invalidate", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageAi)
        let now = hNowEpoch()
        /* 两张表的缓存一起清：ai_model → AiModelRepo，ai_setting → AiSettingsRepo。 */
        aiModels.invalidate()
        aiSettings.invalidate()
        let o = JsonObject()
        o.put("invalidated", JsonBool(true))
        o.put("model_cache_ttl_secs", JsonInt(AI_MODEL_CACHE_TTL_SECS))
        o.put("settings_cache_ttl_secs", JsonInt(AI_SETTINGS_CACHE_TTL_SECS))
        o.put("next_call_reloads", JsonBool(true))
        o.put("cleared_at", JsonInt(now))
        sendOk(ctx, o)
    })

    /* ---------- PUT /api/v1/admin/ai/models/:id —— 改一条（仅管理员）---------- */
    /* 语义是 PATCH：没给的字段保持原值。按 PUT 回默认会把 key_ref 清空，AI 随后静默不可用。 */
    r.put("/api/v1/admin/ai/models/:id", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageAi)
        let id = parseInt64Or(ctx.paramOr("id", ""), 0)
        if (id <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "模型配置 id 必须是正整数")
        }
        let res = aiModels.update(id, bodyStr(ctx, "name"), bodyStr(ctx, "kind"),
                                  bodyStr(ctx, "provider"), bodyStr(ctx, "base_url"),
                                  bodyStr(ctx, "model"), bodyFloatOpt(ctx, "temperature"),
                                  bodyInt64(ctx, "max_tokens"), bodyStr(ctx, "key_ref"),
                                  bodyBool(ctx, "enabled"), bodyBool(ctx, "is_default"),
                                  hNowEpoch(), p.userId)
        if (res.notFound) {
            throw apiErrorMsg("AI_MODEL_NOT_FOUND", "模型配置不存在：${id}")
        }
        if (res.duplicate) {
            throw apiErrorMsg("AI_MODEL_NAME_TAKEN", "同名模型配置已存在")
        }
        if (!res.ok) {
            throw apiErrorMsg("VALIDATION_FAILED", res.invalid)
        }
        let now = hNowEpoch()
        let o = JsonObject()
        o.put("id", JsonInt(res.id))
        match (aiModels.get(res.id, now)) {
            case Some(row) =>
                o.put("model", aiModelJson(row, aiSettings.get(SET_AI_KEY_REF, now).trimAscii().size > 0,
                                          inUse: aiModelInUse(aiModels, row, now)))
            case None => ()
        }
        sendOk(ctx, o)
    })

    /* ---------- DELETE /api/v1/admin/ai/models/:id —— 删一条（仅管理员）---------- */
    /* 硬删（与知识库文档同口径）。要"留着但不使用"就 PUT enabled=false。 */
    r.delete("/api/v1/admin/ai/models/:id", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageAi)
        let id = parseInt64Or(ctx.paramOr("id", ""), 0)
        if (id <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "模型配置 id 必须是正整数")
        }
        if (!aiModels.remove(id, hNowEpoch())) {
            throw apiErrorMsg("AI_MODEL_NOT_FOUND", "模型配置不存在：${id}")
        }
        let o = JsonObject()
        o.put("id", JsonInt(id))
        o.put("deleted", JsonBool(true))
        sendOk(ctx, o)
    })

    /* ---------- POST /api/v1/admin/ai/models/:id/test —— 连通性测试（仅管理员）---------- */
    /* 真实出站，会真的打到模型服务商；失败也回 200（ok=false + reason 是结果，不是服务端故障）；
     * 不受 ai.enabled 总开关影响，但 https 强制与密钥可解析照旧。 */
    r.post("/api/v1/admin/ai/models/:id/test", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageAi)
        let id = parseInt64Or(ctx.paramOr("id", ""), 0)
        if (id <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "模型配置 id 必须是正整数")
        }
        let now = hNowEpoch()
        /* 从库/缓存拿行，不用请求体里的临时配置：要测的是实际生效的那一条。 */
        match (aiModels.get(id, now)) {
            case None => throw apiErrorMsg("AI_MODEL_NOT_FOUND", "模型配置不存在：${id}")
            case Some(m) =>
                let pr = aiModelProbe(m, aiSettings, now)
                let o = JsonObject()
                o.put("id", JsonInt(id))
                o.put("probe", aiModelProbeJson(pr))
                sendOk(ctx, o)
        }
    })

    /* ---------- GET /api/v1/admin/ai/triage-stats —— 分诊遥测聚合（仅管理员）---------- */
    /* 分诊遥测聚合（triage_stat 的读出口，原先只有写）。
     * group_by 白名单（source / reason_code / model_name），非法值 400 —— 列名要拼进 SQL；
     * from/to 为 epoch 秒，缺省最近 24 小时，from > to 直接 400（不自动交换，那会掩盖参数错误）；
     * limit 默认 5000、上限 20000，分位数在内存里算，被截断时 truncated=true；group_limit 默认 20。
     * 响应不含主诉原文与患者/医生标识：本表没存主诉，是机制性保证。 */
    r.get("/api/v1/admin/ai/triage-stats", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageAi)
        let groupBy = ctx.queryParamOr("group_by", "source").trimAscii()
        if (!triageStatGroupByOk(groupBy)) {
            throw apiErrorMsg("VALIDATION_FAILED",
                              "group_by 只支持 source、reason_code、model_name")
        }
        let now = hNowEpoch()
        /* from/to 先判"给的是不是整数"：原来 parseInt64Or 加 "<=0 用默认" 会把 ?from=abc
         * 静默变成最近 24 小时。给了值就必须是非负整数，空串才用默认窗口。 */
        let fromRaw = ctx.queryParamOr("from", "").trimAscii()
        let toRaw = ctx.queryParamOr("to", "").trimAscii()
        if (fromRaw.size > 0 && !hIsAllDigits(fromRaw)) {
            throw apiErrorMsg("VALIDATION_FAILED", "from 必须是 epoch 秒（非负整数）")
        }
        if (toRaw.size > 0 && !hIsAllDigits(toRaw)) {
            throw apiErrorMsg("VALIDATION_FAILED", "to 必须是 epoch 秒（非负整数）")
        }
        var to = parseInt64Or(toRaw, 0)
        var from = parseInt64Or(fromRaw, 0)
        if (to <= 0) {
            to = now
        }
        if (from <= 0) {
            from = to - 86400
        }
        if (from > to) {
            throw apiErrorMsg("VALIDATION_FAILED", "from 不能大于 to")
        }
        /* 窗口跨度上限 366 天：上不封顶则"一次请求扫全表"只是少打几个字的事。 */
        if (to - from > TRIAGE_STAT_WINDOW_MAX_SECS) {
            throw apiErrorMsg("VALIDATION_FAILED",
                              "from 与 to 的跨度不能超过 366 天（要更长请做预聚合）")
        }
        var sampleLimit = parseInt64Or(ctx.queryParamOr("limit",
                                                        "${TRIAGE_STAT_SAMPLE_DEFAULT}"),
                                       TRIAGE_STAT_SAMPLE_DEFAULT)
        if (sampleLimit < 1) {
            sampleLimit = 1
        }
        if (sampleLimit > TRIAGE_STAT_SAMPLE_MAX) {
            sampleLimit = TRIAGE_STAT_SAMPLE_MAX
        }
        var groupLimit = parseInt64Or(ctx.queryParamOr("group_limit",
                                                       "${TRIAGE_STAT_GROUP_DEFAULT}"),
                                      TRIAGE_STAT_GROUP_DEFAULT)
        if (groupLimit < 1) {
            groupLimit = 1
        }
        if (groupLimit > TRIAGE_STAT_GROUP_MAX) {
            groupLimit = TRIAGE_STAT_GROUP_MAX
        }
        let w = triageStat.windowRows(from, to, sampleLimit)
        sendOk(ctx, triageStatWindowJson(w, groupBy, from, to, sampleLimit, groupLimit))
    })

    /* ---------- GET /api/v1/admin/ai/triage-calls/:requestId —— 单次调用全链路（仅管理员）---------- */
    /* 按 X-Request-Id 捞单次分诊全链路。返回数组：request_id 无唯一约束，可能多行。
     * 空数组回 200 + count:0 而不是 404 —— 请求可能在落库前就被拦下（限流/校验/鉴权）。
     * 只有结论码/科室名/文档 id，不含主诉原文与个人信息。 */
    r.get("/api/v1/admin/ai/triage-calls/:requestId", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageAi)
        let requestId = ctx.paramOr("requestId", "").trimAscii()
        if (requestId.size == 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "requestId 不能为空")
        }
        var limit = parseInt64Or(ctx.queryParamOr("limit", "20"), 20)
        if (limit < 1) {
            limit = 1
        }
        if (limit > 100) {
            limit = 100
        }
        let rows = triageStat.callsByRequest(requestId, limit)
        let items = JsonArray()
        for (r in rows) {
            items.add(triageCallJson(r))
        }
        let o = JsonObject()
        o.put("request_id", JsonString(requestId))
        o.put("items", items)
        o.put("count", JsonInt(Int64(items.size())))
        /* 口径显式回显：新→旧（id DESC）。 */
        o.put("order", JsonString("id_desc"))
        sendOk(ctx, o)
    })

    /* ===================== 业务接口 ===================== */

    /* ---------- POST /api/v1/triage —— 智能分诊 ---------- */
    /* 三条口径：① 结论非流式（它是业务值，客户端会拿它去挂号）；② 先取证后结论 —— 每个 option
     * 都过 TriageRepo 的真实号源校验（remain_num > 0），模型说的内容不进 options；③ source 如实标注。
     * 权限 Action.Book；患者 id 取自令牌，不从请求体取。 */
    r.post("/api/v1/triage", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.Book)
        // 增强预算只覆盖模型等待：同步 SQL/规则/RAG 不可被该截止中断，已用时间先扣除。
        let enhancementDeadline = DateTime.now().toUnixTimeStamp().toMilliseconds() +
                                  TRIAGE_ENHANCEMENT_BUDGET_MS
        let complaint = match (bodyStr(ctx, "chief_complaint")) {
            case Some(v) => v
            case None => throw apiErrorMsg("VALIDATION_FAILED", "缺少必填字段 chief_complaint")
        }
        /* 主诉长度上限。完整主诉先过危急检测（保留否定上下文），仅常规检索与模型输入截断。
         * 必须按字符截断：按字节会在汉字中间切断 ⇒ 非法 UTF-8 ⇒ 500（triage-check.ps1 有用例守）。 */
        var text = complaint
        var truncated = false
        if (text.size > TRIAGE_INPUT_MAX_BYTES) {
            text = triageTruncateChars(complaint, TRIAGE_INPUT_MAX_CHARS)
            truncated = true
        }
        let today = hTodayDate()
        let v = triageComplaint(triage, text, today, redFlagComplaint: Some(complaint))
        /* 模型增强层只写"给患者看的那句话"，不碰 v.options —— 科室与号源永远由规则 + 数据库决定，
         * 所以"绝不给没有号的推荐"在接上模型后依然不可绕过。四态如实标注：未配置/失败 ⇒ source=rules，
         * 成功 ⇒ model，答了但不合格 ⇒ model:invalid。危急征象时不调模型。 */
        // RAG 在当前请求内取完，worker 只持有网络配置与 Prompt（同步 SQL 不能由 Future 中断）。
        let ragHits = triageRagHits(kb, text, v)
        aiEnhanceTriage(v, text, aiSettings, hNowEpoch(), ragHits: ragHits,
                        deadlineMs: enhancementDeadline)
        /* 把结论字段记进 triage_stat（看板的分诊命中率靠它）。record() 签名里没有主诉参数，
         * "记主诉"在类型层面就做不到；record() 内部吞异常，统计失败不能影响分诊响应。
         * 遥测字段全部取自 v（调用当时记下），不回头查配置 —— 否则会把 A 模型的结果记成 B 模型。 */
        let topDept = if (v.options.size > 0) { v.options[0].departmentName } else { "" }
        triageStat.record(v.reasonCode, v.redFlag, topDept, truncated, v.source, hNowEpoch(),
                          requestId: ctx._id,
                          modelId: v.aiModelId,
                          modelName: v.aiModelName,
                          promptRevision: aiSettings.revision(hNowEpoch()),
                          elapsedMs: v.aiElapsedMs,
                          degradeReason: v.aiDegradeReason,
                          usedKb: v.aiUsedKb,
                          kbDocIds: v.aiKbDocIds)
        /* 响应体回 request_id + server_time（纯增量）。排障端点只能按 request_id 查，而患者端默认
         * 不带 X-Request-Id，这个编号必须回到调用方手里。不引入主诉原文或任何个人信息。 */
        let triageOut = triageJson(v, truncated)
        putTrace(ctx, triageOut)
        sendOk(ctx, triageOut)
    })
    /* ===================== 预问诊（SSE 流式）===================== */

    /* 对话文本走 SSE，业务值走普通 JSON：
     *   GET  /api/v1/previsit/stream  开新会话 + 流式吐第一轮追问
     *   POST /api/v1/previsit/answer  提交一个答案 → 结构化业务值（已填项数/是否完成），非流式
     * 业务值是状态，流错了是状态污染；对话文本流错了只是看到半句话。 */
    r.get("/api/v1/previsit/stream", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.Book)
        let chief = ctx.queryParamOr("chief_complaint", "").trimAscii()
        /* 主诉按字符截断再落库：按字节会在汉字中间切断 ⇒ 非法 UTF-8。 */
        let ccap = if (previsitCharLen(chief) > 200) { previsitTruncateChars(chief, 200) } else { chief }
        let now = hNowEpoch()
        let sid = previsit.create(p.patientId, now)
        if (ccap.size > 0) {
            let _ = previsit.answer(sid, p.patientId, "chief", ccap, now)
        }
        let found = previsit.find(sid, p.patientId)
        let sess = match (found) {
            case Some(s) => s
            case None => throw apiErrorMsg("INTERNAL", "会话创建后立即读取失败")
        }
        /* streamStart 设 content-type + chunked，handler 返回时框架自动写 last-chunk。 */
        let _ = ctx.streamStart("text/event-stream; charset=utf-8")
        // 帧 ①：会话元信息（客户端要 session_id 才能推进多轮）
        let meta = JsonObject()
        meta.put("session_id", JsonString(sid))
        meta.put("turn", JsonInt(sess.turn))
        meta.put("total_slots", JsonInt(intakeSlots().size))
        ctx.writeChunk(sseFrame("meta", meta))
        // 帧 ②…：逐句吐对话文本（每句一帧）
        for (line in previsitAssistantLines(sess, None)) {
            let o = JsonObject()
            o.put("text", JsonString(line))
            ctx.writeChunk(sseFrame("delta", o))
        }
        // 帧 末：显式告知流结束，客户端不必靠连接关闭判断
        let done = JsonObject()
        done.put("session_id", JsonString(sid))
        done.put("next_slot", JsonString(match (sess.nextSlot()) {
            case Some(sl) => sl.key
            case None => ""
        }))
        ctx.writeChunk(sseFrame("done", done))
        // 已流式写出 ⇒ 不能再走 sendOk/sendError（会二次写响应体），让 handler 自然结束。
    })

    /* ---------- POST /api/v1/previsit/answer —— 提交一项答案（业务值，非流式）---------- */
    r.post("/api/v1/previsit/answer", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.Book)
        let sid = requireStr(ctx, "session_id")
        let key = requireStr(ctx, "slot")
        let value = match (bodyStr(ctx, "value")) {
            case Some(v) => v
            case None => ""
        }
        let r = previsit.answer(sid, p.patientId, key, value, hNowEpoch())
        /* 会话不存在回 404 而不是 403：403 等于说"这个 session_id 存在但不属于你"，是枚举 oracle。 */
        if (r.noSuchSession) {
            throw apiErrorMsg("PREVISIT_NOT_FOUND", "预问诊会话不存在或已失效")
        }
        if (r.unknownSlot.size > 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "未知的问诊项：${r.unknownSlot}")
        }
        if (r.tooLong.size > 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "字段 ${r.tooLong} 超出长度上限")
        }
        let found = previsit.find(sid, p.patientId)
        let sess = match (found) {
            case Some(s) => s
            case None => throw apiErrorMsg("PREVISIT_NOT_FOUND", "预问诊会话不存在或已失效")
        }
        sendOk(ctx, previsitSessionJson(sess))
    })

    /* ---------- GET /api/v1/previsit/:id —— 取已采集的问诊单（业务值，非流式）---------- */
    r.get("/api/v1/previsit/:id", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.Book)
        let sid = ctx.paramOr("id", "")
        let found = previsit.find(sid, p.patientId)
        let sess = match (found) {
            case Some(s) => s
            case None => throw apiErrorMsg("PREVISIT_NOT_FOUND", "预问诊会话不存在或已失效")
        }
        sendOk(ctx, previsitSessionJson(sess))
    })
    /* ---------- GET /api/v1/schedules —— 排班列表（按科室/日期）---------- */
    /* 参数都可选：department_id、work_date（YYYY-MM-DD）、limit；三端可读（Action.ViewSchedule）。
     * 含已约满（remain_num = 0）的排班 —— 藏起来会让患者以为这天没排班，能否可挂由客户端看 remain_num。 */
    r.get("/api/v1/schedules", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ViewSchedule)
        let depId = parseInt64Or(ctx.queryParamOr("department_id", "0"), 0)
        let date = ctx.queryParamOr("work_date", "").trimAscii()
        let lim = parseInt64Or(ctx.queryParamOr("limit", "100"), 100)
        /* 日期格式先校验再进 SQL：参数化绑定挡住注入，格式检查把 typo 变成明确的 400。 */
        if (date.size > 0 && !isDateLike(date)) {
            throw apiErrorMsg("VALIDATION_FAILED", "work_date 格式应为 YYYY-MM-DD")
        }
        let bookableOnly = match (p.role) {
            case Patient => true
            case _ => false
        }
        let list = repo.listSchedules(departmentId: depId, workDate: date, limit: lim,
                                      bookableOnly: bookableOnly)
        /* 补 department_name / doctor_name / doctor_title 与 version：患者角色读不到科室/医生字典，
         * 名称必须服务端给，否则界面只能显示"科室 #810003"。名称解析走 nameIndexOf（一次读全表），
         * 不逐行查库，避免 N+1。 */
        let names = nameIndexOf(dept, doc)
        let arr = ArrayList<JsonValue>()
        for (s in list) {
            let o = JsonObject()
            o.put("id", JsonInt(s.id))
            o.put("doctor_id", JsonInt(s.doctorId))
            o.put("department_id", JsonInt(s.departmentId))
            o.put("work_date", JsonString(s.workDate))
            o.put("period", JsonString(s.period))
            o.put("total_num", JsonInt(s.totalNum))
            o.put("remain_num", JsonInt(s.remainNum))
            o.put("version", JsonInt(s.version))
            o.put("enabled", JsonBool(s.enabled))
            names.putInto(o, s.departmentId, s.doctorId)
            arr.add(o)
        }
        let o = JsonObject()
        o.put("schedules", JsonArray(arr.toArray()))
        o.put("count", JsonInt(list.size))
        sendOk(ctx, o)
    })

    /* ---------- GET /api/v1/appointments —— 我的挂号 ---------- */
    /* 只看自己的：patientId 一律取自令牌，绝不从查询参数取。
     * include_cancelled=true 才带上已取消的单。 */
    r.get("/api/v1/appointments", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        /* 角色判定用 match/roleName()：仓颉枚举没有 !=。 */
        let isPatient = match (p.role) {
            case Patient => true
            case _ => false
        }
        if (!isPatient || p.patientId <= 0) {
            throw apiErrorMsg("FORBIDDEN_ROLE", "该接口只对患者开放（它返回的是\"我的挂号\"）")
        }
        let inc = ctx.queryParamOr("include_cancelled", "") == "true"
        let lim = parseInt64Or(ctx.queryParamOr("limit", "50"), 50)
        let list = repo.listAppointmentsByPatient(p.patientId, includeCancelled: inc, limit: lim)
        /* 每条挂号补科室名/医生名/职称（理由同 /schedules）。 */
        let names = nameIndexOf(dept, doc)
        let arr = ArrayList<JsonValue>()
        for (a in list) {
            let item = bookingJson(a)
            names.putInto(item, a.departmentId, a.doctorId)
            arr.add(item)
        }
        let o = JsonObject()
        o.put("appointments", JsonArray(arr.toArray()))
        o.put("count", JsonInt(list.size))
        sendOk(ctx, o)
    })

    /* ---------- GET /api/v1/appointments/by-token/:token —— 按幂等键反查（改进 4）---------- */
    /* 按幂等键反查这张单（只读通道）：客户端断网时用它区分"没发出去"与"已落库"。
     * patientId 取自令牌并与 token 组合查询（WHERE patient_id, client_token），猜到 token 也拿不到别人的单。
     * findAppointmentByToken 只认 status <> 'cancelled'（退号会把 client_token 置 NULL 释放幂等键），
     * 所以 404 有两种含义：没落库，或已退号释放 —— 对客户端动作一样，都是可用同一 token 重新提交。 */
    r.get("/api/v1/appointments/by-token/:token", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        let isPatient = match (p.role) {
            case Patient => true
            case _ => false
        }
        if (!isPatient || p.patientId <= 0) {
            throw apiErrorMsg("FORBIDDEN_ROLE", "该接口只对患者开放（它查的是\"我的挂号\"）")
        }
        let token = ctx.paramOr("token", "").trimAscii()
        /* 形状校验在查库之前：空串必查不到，> 64 字符越过 client_token VARCHAR(64) 上限 ⇒ 显式 400。 */
        if (token.size == 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "缺少幂等键 token（路径形如 /api/v1/appointments/by-token/<token>）")
        }
        if (token.size > 64) {
            throw apiErrorMsg("VALIDATION_FAILED",
                              "幂等键最长 64 个字符（收到 " + token.size.toString() + " 个）——客户端生成时应自行截断")
        }
        match (repo.findAppointmentByToken(p.patientId, token)) {
            case Some(id) => match (repo.findAppointment(id)) {
                case Some(found) =>
                    /* 与挂号响应对齐：previsitBound 同样给，客户端要用它比对。 */
                    sendOk(ctx, bookingJsonFull(repo, found, nameIndexOf(dept, doc), ctx,
                        previsitBound: previsit.findByAppointment(found.appointmentId,
                                                                  found.patientId).isSome()))
                /* 查得到 id 却读不出明细 = 并发窗口（刚被退号/删掉）。对外按"不存在"回答。 */
                case None => throw apiErrorMsg("APPOINTMENT_NOT_FOUND",
                                               "该幂等键对应的挂号单已不存在（可能刚刚被退号）")
            }
            case None => throw apiErrorMsg("APPOINTMENT_NOT_FOUND",
                                           "该幂等键没有对应的有效挂号单（那次提交未成功，或已被退号释放）")
        }
    })

    /* ---------- GET /api/v1/schedules/:id —— 查排班（三端可读）---------- */
    r.get("/api/v1/schedules/:id", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ViewSchedule)
        let sid = parseInt64Or(ctx.paramOr("id", "0"), 0)
        if (sid <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "排班 id 必须是正整数")
        }
        let found = match (p.role) {
            case Patient => repo.findBookableSchedule(sid)
            case _ => repo.findSchedule(sid)
        }
        if (found.isNone()) {
            throw apiError("SCHEDULE_NOT_FOUND")
        }
        let s = found.getOrThrow()
        let o = JsonObject()
        o.put("id", JsonInt(s.id))
        o.put("doctor_id", JsonInt(s.doctorId))
        o.put("department_id", JsonInt(s.departmentId))
        o.put("work_date", JsonString(s.workDate))
        o.put("period", JsonString(s.period))
        o.put("total_num", JsonInt(s.totalNum))
        o.put("remain_num", JsonInt(s.remainNum))
        o.put("version", JsonInt(s.version))
        o.put("enabled", JsonBool(s.enabled))
        /* 单个排班与 /schedules 列表返回同一份数据，形状必须一致。 */
        nameIndexOf(dept, doc).putInto(o, s.departmentId, s.doctorId)
        sendOk(ctx, o)
    })

    /* ---------- POST /api/v1/appointments —— 挂号（仅患者）---------- */
    r.post("/api/v1/appointments", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.Book)
        let scheduleId = requireInt(ctx, "schedule_id")
        let clientToken = requireStr(ctx, "client_token")
        /* client_token 形状校验，与 by-token 端点同口径：超长会撞 MySQL "Data too long" ⇒ 500 而非 400。 */
        if (clientToken.size == 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "缺少幂等键 client_token")
        }
        if (clientToken.size > 64) {
            throw apiErrorMsg("VALIDATION_FAILED",
                              "幂等键最长 64 个字符（收到 ${clientToken.size} 个）——客户端生成时应自行截断")
        }
        // 患者只能给自己挂号：不接受 body 里的 patient_id，一律用身份里的 patientId。
        if (p.patientId <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "缺少 X-Patient-Id（开发态联调头）")
        }
        let now = hNowEpoch()
        // HTTP 层用更大的重试预算抗瞬时并发（HTTP_BOOKING_RETRY：默认 3 在 20 并发抢 8 号时会少卖）。
        let result = repo.book(p.patientId, scheduleId, clientToken, now,
                               maxRetry: HTTP_BOOKING_RETRY)
        /* 可选：在服务端把这张单与患者的预问诊单绑定（previsit_id）。
         * 绑定失败不影响挂号，只体现在 previsit_bound:false —— 为记账问题回滚挂号等于让患者白跑。
         * bindAppointment 的 WHERE 是 appointment_id = 0 OR = ?，防止把自述挂到别人的就诊上；
         * 幂等重放（AlreadyBooked）走到这里也幂等。 */
        let pvId = match (bodyStr(ctx, "previsit_id")) {
            case Some(v) => v
            case None => ""
        }
        var pvBound = false
        if (pvId.size > 0 && result.appointmentId > 0) {
            pvBound = previsit.bindAppointment(pvId, p.patientId, result.appointmentId)
        }
        // 幂等命中按 200 返回（不是 201）：没有新建资源
        let names = nameIndexOf(dept, doc)
        match (result.outcome) {
            case Booked(_) => sendCreated(ctx, bookingJsonFull(repo, result, names, ctx,
                                                              previsitBound: pvBound))
            case AlreadyBooked(_) => sendOk(ctx, bookingJsonFull(repo, result, names, ctx,
                                                                previsitBound: pvBound))
            case SlotGone => throw apiError("SLOT_GONE")
            case ScheduleNotFound => throw apiError("SCHEDULE_NOT_FOUND")
        }
    })

    /* ---------- POST /api/v1/appointments/:id/cancel —— 退号 ---------- */
    r.post("/api/v1/appointments/:id/cancel", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        let id = parseInt64Or(ctx.paramOr("id", "0"), 0)
        if (id <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "挂号单 id 必须是正整数")
        }
        let found = repo.findAppointment(id)
        if (found.isNone()) {
            throw apiError("APPOINTMENT_NOT_FOUND")
        }
        let appt = found.getOrThrow()
        /* 谁能退这张单：单一判定函数 canCancel（管理员任意、患者仅自己），handler 不手写 if。 */
        if (!canCancel(p.role, p.patientId, appt.patientId, p.userId, 0)) {
            // 取舍：明确 403 便于患者自查"退错单了"；严格防枚举应改 404。
            throw apiErrorMsg("FORBIDDEN_ROLE",
                              "无权取消该挂号单（管理员可退任意单；患者只能退自己的）")
        }
        /* 多带 already_cancelled（本次调用之前是否已取消）：区分"本次真的退了"与"幂等重放"。
         * 口径取自取消前的 appt 快照 —— 取消后重读永远是 cancelled，答不出"之前是什么"。 */
        let wasCancelled = appt.status == "cancelled"
        match (repo.cancel(id, hNowEpoch())) {
            /* 退号响应同样带 remain_num：退号的意义就是还号，客户端要立刻显示归还后的余号。 */
            case Cancelled =>
                /* 必须取消后重读：上面的 appt 快照 status 还是 booked，回它就成了自相矛盾。 */
                match (repo.findAppointment(id)) {
                    case Some(after) =>
                        let o = bookingJsonFull(repo, after, nameIndexOf(dept, doc), ctx)
                        o.put("already_cancelled", JsonBool(wasCancelled))
                        sendOk(ctx, o)
                    case None => throw apiError("APPOINTMENT_NOT_FOUND")
                }
            case SlotNotRestored =>
                // 单已取消但号源未归还：HTTP 上算成功，但带标记让客户端提示"需人工处理"，不谎报失败。
                match (repo.findAppointment(id)) {
                    case Some(after) =>
                        let o = bookingJsonFull(repo, after, nameIndexOf(dept, doc), ctx)
                        o.put("status", JsonString("cancelled"))
                        o.put("slot_restored", JsonBool(false))
                        o.put("already_cancelled", JsonBool(wasCancelled))
                        o.put("warning", JsonString("号源归还异常，请联系人工处理"))
                        sendOk(ctx, o)
                    case None => throw apiError("APPOINTMENT_NOT_FOUND")
                }
            case NotFound => throw apiError("APPOINTMENT_NOT_FOUND")
            /* 409 而不是 403：这张单是你的，但当前状态不能退（谁登录都一样）。
             * 与外层 canCancel 的 403（不是你的单）是两件事，不能合并。 */
            case NotCancellable(st) =>
                throw apiErrorMsg("APPOINTMENT_NOT_CANCELLABLE",
                                  "该挂号单当前状态为「" + visitStatusLabel(st) + "」，不能退号")
            /* 409 APPOINTMENT_RECORD_LOCKED：状态没问题但病历已定稿 —— 刷新无用，必须先处理定稿状态
             * （管理员走病历修订/解锁）或直接就诊。压成 NotCancellable 会让人在走不通的位置反复重试。 */
            case RecordLocked =>
                throw apiErrorMsg("APPOINTMENT_RECORD_LOCKED",
                                  "该挂号单的病历已定稿（锁定后不可再修改），不能退号；" +
                                  "如确需退号，请先联系管理员处理该次病历")
        }
    })

    /* ---------- POST /api/v1/admin/schedules —— 建排班（仅管理员）---------- */
    /* 建排班：认证 + 管理员双重保护。不开 --dev-auth 时带真实管理员令牌照样能过，
     * --dev-auth 只多一条本机 X-Role 捷径（不要把"没有捷径"当成"进不来"）。 */
    r.post("/api/v1/admin/schedules", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageSchedule)
        let doctorId = requireInt(ctx, "doctor_id")
        let departmentId = requireInt(ctx, "department_id")
        let workDate = requireStr(ctx, "work_date")
        let period = requireStr(ctx, "period")
        let total = requireInt(ctx, "total_num")
        if (total <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "total_num 必须是正整数")
        }
        if (!hIsCalendarDate(workDate) || hScheduleDateIsPast(workDate)) {
            throw apiErrorMsg("VALIDATION_FAILED", "work_date 必须是 YYYY-MM-DD 格式的有效日期，且不能早于医院今天")
        }
        if (period != "AM" && period != "PM") {
            throw apiErrorMsg("VALIDATION_FAILED", "period 只能是 AM 或 PM")
        }
        let department = dept.findById(departmentId)
        if (department.isNone()) {
            throw apiErrorMsg("VALIDATION_FAILED", "department_id 对应的科室不存在")
        }
        if (!department.getOrThrow().enabled) {
            throw apiErrorMsg("VALIDATION_FAILED", "不能为停用科室创建排班")
        }
        let doctor = doc.findById(doctorId)
        if (doctor.isNone()) {
            throw apiErrorMsg("VALIDATION_FAILED", "doctor_id 对应的医生不存在")
        }
        let selectedDoctor = doctor.getOrThrow()
        if (!selectedDoctor.enabled || selectedDoctor.departmentId != departmentId) {
            throw apiErrorMsg("VALIDATION_FAILED", "医生必须启用且属于所选科室")
        }
        /* 同一医生 + 同一天 + 同一时段只能有一条排班：重复建会让号源翻倍（idx_schedule_doctor_date
         * 是普通索引，拦不住）。报 409 并带上已存在的 id，调用方应去 PUT 那一条，而不是新建。
         * 先查后插残留一个并发窗口，刻意不用唯一键兜（会与"排班可顺延"冲突）—— 如实登记，靠管理台兜。 */
        match (repo.findScheduleIdByDoctorSlot(doctorId, workDate, period)) {
            case Some(existingId) =>
                throw apiErrorMsg("SCHEDULE_EXISTS",
                                  "该医生在 " + workDate + " " + period + " 已有排班" +
                                  "（schedule_id = " + existingId.toString() + "），" +
                                  "请直接修改该排班（改放号数 / 恢复停诊），不要新建")
            case None => ()
        }
        let now = hNowEpoch()
        let sid = repo.insertSchedule(doctorId, departmentId, workDate, period, total, now)
        let o = JsonObject()
        o.put("schedule_id", JsonInt(sid))
        o.put("total_num", JsonInt(total))
        o.put("remain_num", JsonInt(total))
        sendCreated(ctx, o)
    })

    /* ---------- PUT /api/v1/admin/schedules/:id —— 改放号数 / 停诊（仅管理员）---------- */
    /* 语义是 PATCH：没给的字段保持原值。version 必填（乐观锁的读基准，由 GET /schedules/:id 返回），
     * 缺 version ⇒ 400 而不是默认 0 —— 默认 0 会让每一次编辑都变成冲突。 */
    r.put("/api/v1/admin/schedules/:id", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageSchedule)
        let sid = parseInt64Or(ctx.paramOr("id", ""), 0)
        if (sid <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "排班 id 必须是正整数")
        }
        let version = requireInt(ctx, "version")
        /* 两个可选字段都不设默认：缺省 = 不改这一项。按 0 处理会把排班改成 0 张（等于停号）。 */
        let totalOpt = bodyInt64(ctx, "total_num")
        if (totalOpt.isSome() && totalOpt.getOrThrow() <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "total_num 必须是正整数")
        }
        let enabledOpt = bodyBool(ctx, "enabled")
        if (totalOpt.isNone() && enabledOpt.isNone()) {
            throw apiErrorMsg("VALIDATION_FAILED", "至少要给 total_num 或 enabled 之一")
        }
        let res = repo.updateSchedule(sid, totalOpt, enabledOpt, version)
        if (res.notFound) {
            throw apiErrorMsg("SCHEDULE_NOT_FOUND", "排班不存在或已停诊：${sid}")
        }
        if (res.conflict) {
            /* 409 SCHEDULE_CONFLICT 要带上当前 version，否则前端只能整页重刷、丢掉刚填的数字。 */
            throw apiErrorMsg("SCHEDULE_CONFLICT",
                "该排班已被他人修改（你手里的 version = ${version}，当前的 version = ${res.version}），" +
                "请刷新后重试")
        }
        if (res.tooSmall) {
            throw apiErrorMsg("VALIDATION_FAILED",
                "放号数不能小于已约张数（已约 ${res.booked} 张，放号数 ${res.totalNum}，" +
                "待约 ${res.remainNum}）")
        }
        if (!res.ok) {
            throw apiErrorMsg("VALIDATION_FAILED", "排班更新失败")
        }
        let o = JsonObject()
        o.put("schedule_id", JsonInt(sid))
        o.put("total_num", JsonInt(res.totalNum))
        o.put("remain_num", JsonInt(res.remainNum))
        /* booked = 已约张数（= total − remain）—— 放号数不能改到它以下。 */
        o.put("booked", JsonInt(res.booked))
        o.put("version", JsonInt(res.version))
        o.put("enabled", JsonBool(res.enabled))
        sendOk(ctx, o)
    })
    /* ===================== 病历 + 接诊队列 + 运营看板 ===================== */
    /* 定义在 http_p4.cj（病历锁定语义、接诊状态机、看板只出聚合），这里只注册，
     * 让"有哪些端点"只有一处可数。 */
    registerP4Routes(r, auth, gate, repo, previsit, emr, visit, dash, aiSettings, dept, doc)

    /* 基础数据域的管理端 CRUD 也在这里注册：路由集中可见，doc-counts.ps1 才数得清端点总数。 */
    registerBaseRoutes(r, auth, gate, dept, doc)
    /* P5 知识库同样登记在此（新增文件须同步 doc-counts.ps1 的清单）。 */
    registerKbRoutes(r, auth, gate, kb)
    /* 公告域同样登记在此（doc-counts.ps1 的 $regFiles 已加入 http_notice.cj）。 */
    registerNoticeRoutes(r, auth, gate, notices)

    return r
}


/* triage 由调用方传入：本函数拿不到 db。分诊仓储只读 schedule/doctor/department，
 * 与 ADR-0001 §4.3「号源域写操作只经 BookingRepo」一致 —— "分诊不会改号源"是类型层面的。 */
public func buildHospitalApp(repo: BookingRepo, auth: AuthRepo, gate: DevAuthGate,
                             triage: TriageRepo, previsit: PrevisitRepo,
                             aiSettings: AiSettingsRepo, aiModels: AiModelRepo, prompts: PromptRepo,
                             emr: MedicalRecordRepo, visit: VisitRepo,
                             dash: DashboardRepo, triageStat: TriageStatRepo,
                             dept: DepartmentRepo, doc: DoctorRepo, kb: KbRepo,
                             notices: NoticeRepo, adminWebDir!: String = "",
                             // /health 的库探针由调用方注入：本函数刻意不持有 db。
                             dbProbe!: ?DbProbe): QingZhouApp {
    let router = buildHospitalRouter(repo, auth, gate, triage, previsit, aiSettings, aiModels, prompts,
                                     emr, visit, dash, triageStat, dept, doc, kb, notices,
                                     dbProbe: dbProbe)
    /* 让 router 透传未命中的路径，由末尾自注册的中间件回统一信封。须早于 router.middleware() 构造。 */
    router.passOnNotFound = true
    /* 路由器直写的 404/405 也要走三段式信封：它们不经过 app.onError，只能在这里换钩子（errorBody）。
     * code 用 ROUTE_NOT_FOUND / METHOD_NOT_ALLOWED。 */
    router.errorBody = { status: Int64, msg: String =>
        let code = if (status == 405) { "METHOD_NOT_ALLOWED" } else { "ROUTE_NOT_FOUND" }
        errorEnvelopeString(code, msg, None)
    }
    var app = QingZhouApp()
        .use(requestId())
        .use(logger())
        // bodyLimit 必须排在 bodyParser 之前（外层）：框架的 bodyParser 先读进内存再比 maxBytes，
        // 只有按 Content-Length 抢在它前面拦，大 body 才进不了内存。上限 64 KiB，onError 用统一信封。
        .use(contentLengthLimit(hospitalContentLengthLimitOptions(64 * 1024)))
        /* bodyParser 的真实上限是框架默认的 1 MiB（用于没有 Content-Length 的 chunked 请求），
         * 与上面 64 KiB 外层闸门是两层。opts 必须传，否则 400/413 会回框架默认平壳。 */
        .use(bodyParser(hospitalBodyParserOptions()))
        .use(cors())
        /* timeout(15000) 不能中断已进入的同步 handler（先 next() 跑完再比 elapsed），只能事后补 408
         * 或加 x-timeout-ms 头。⇒ 挂号/退号路径不能有慢操作，事务内禁止出站网络调用。 */
        .use(timeout(15000))
    /* 管理台静态资源挂 /admin/，必须排在 router.middleware() 之前（否则全被路由 404）。
     * 静态页面本身不鉴权，数据仍逐条校验令牌与角色：看得到页面 ≠ 读得到数据。
     * enableCache = false（改了立刻生效）；spaFallback = false（哈希路由用不到，且会把打错的静态
     * 路径变成 200 + HTML）。前缀必须写 "/admin" 不带尾斜杠：带斜杠时余部不以 '/' 开头 ⇒ 全 404。 */
    if (adminWebDir.size > 0) {
        let staticOpts = StaticOptions("/admin")
        staticOpts.indexFile = "index.html"
        staticOpts.spaFallback = false
        /* 静态层自己的 404/403/416 也统一信封：框架把这三条做成可配项，不需要 fork。 */
        staticOpts.notFoundBody = errorEnvelopeString("ROUTE_NOT_FOUND", "静态资源不存在", None)
        staticOpts.forbiddenBody = errorEnvelopeString("FORBIDDEN_ROLE", "静态资源禁止访问", None)
        staticOpts.rangeNotSatisfiableBody =
            errorEnvelopeString("RANGE_NOT_SATISFIABLE", "Range 请求超出文件大小", None)
        staticOpts.apiPrefix = "/api"
        staticOpts.enableCache = false
        app = app.use(serveWithOpts(adminWebDir, staticOpts))
    }
    return app
        .use(router.middleware())
        /* 给框架自己的 404 套统一信封：passOnNotFound 让未命中透传到这里，
         * 中间件必须注册在 router.middleware() 之后（洋葱模型里后注册的在其 next() 之后）。 */
        .use({ ctx: Context, _: () -> Unit =>
            sendError(ctx, apiErrorMsg("ROUTE_NOT_FOUND",
                                       "接口不存在：${ctx.method()} ${ctx.path()}"))
        })
        .onError({ ctx: Context, _: () -> Unit => hospitalErrorHandler(ctx) })
}

/* HandleBox 持有 ServerHandle：必须放在 class 字段里，仓颉闭包不能捕获可变变量。 */
public class HandleBox {
    public var handle: ?ServerHandle = None

    public init() {}
}
