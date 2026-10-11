/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 *
 * ===== http_app.cj —— HTTP 应用装配 + 挂号闭环接口（P1）=====================
 *
 * 落地 P1：排班查询 / 挂号 / 取消 三个 REST，复用 P0 的 `BookingRepo`
 * （原子扣减 + 幂等 + 三态取消），因此并发安全由数据库保证，本文件不引入新锁。
 *
 * ── 中间件顺序（照搬迁前口径，见搬迁前 main.cj:940-953）──────────
 *   requestId → logger → bodyLimit → bodyParser → cors → timeout → router.middleware
 * 三条硬性理由：
 *   1. `bodyLimit` 必须在 `bodyParser` **之前**：框架的 bodyParser 是"先整个读进内存
 *      再比 maxBytes"，只有抢在它前面按 Content-Length 拦，大 body 才进不了内存。
 *   2. `timeout` 必须在 `router.middleware()` **之前**：router 命中后直接调 handler，
 *      我们的 handler 从不调 next()，排在 router 后面的中间件**一次都不会执行**。
 *   3. `router.middleware()` 必须**最后** use：在它之后注册的都不会跑。
 *
 * ── 三端角色（P1 简化版，如实标注）──────────────────────────────────────
 *   患者 / 医生 / 管理员三种角色，权限判定收敛到**单一函数** `can(role, action)`
 *   （搬迁前铁律：禁止 handler 手写 if 判权限，见搬迁前 perms.cj）。
 *
 *   ⚠ 与搬迁前的差异：搬迁前是"不透明令牌 + PBKDF2 三阶段加锁"，本阶段**尚未搬令牌体系**，
 *     用的是 `--dev-auth` 显式开启的**开发态身份头**（`X-Role` / `X-Patient-Id`）。
 *     这是**刻意的临时形态**：先把接口与权限骨架立起来并测通，
 *     令牌换取/持久化/过期回收放 P1 收尾。**生产启用会直接拒绝启动**（见 requireDevAuth）。
 */

package qingzhou

import std.collection.*
import std.time.*
import stdx.encoding.json.*

/* ===================== 角色与权限（单一判定函数） ===================== */

/*
 * 三端角色。
 * ⚠ 仓颉的枚举**不能用 `==` 比较**（语言坑 4：invalid binary operator '==' on Enum），
 *   所以角色比较一律走 `roleName()` 转字符串，或用 match。
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

/*
 * 权限动作。
 */
public enum Action {
    | ViewSchedule        // 查排班（三端都能看）
    | Book                // 挂号（仅患者）
    | CancelOwn           // 取消自己的挂号（患者）
    | CancelAny           // 取消任意挂号（管理员）
    | ManageSchedule      // 维护排班与号源（管理员）
    /*
     * ★ P4 新增两条。**刻意分成"读自己的"与"写自己的"两个动作**，
     *   而不是一个笼统的 `ManageMedicalRecord`：
     *     · 患者要能读**自己**的病历（医疗档案），但绝不能写；
     *     · 医生要能写**自己接诊的**病历，但边界是"自己的号"；
     *   两者的"自己的"含义还不同（患者=patient_id，医生=doctor_id）。
     *   合成一个动作就没法在 `can()` 这一层表达这个差异，
     *   只能退化成 handler 里手写 if —— 而"权限收敛到单一函数"是本项目的铁律。
     */
    | QueryOwnMedicalRecord   // 读自己的病历（患者读自己的；医生读自己接诊的）
    | WriteOwnMedicalRecord   // 写自己的病历（仅医生）
    | ManageVisit             // 接诊队列的状态流转（仅医生，限自己的号）
    | ViewDashboard           // 运营看板（仅管理员）
    /*
     * ★ 2026-10-09（基础数据域 CRUD）新增一条。
     *
     * ⚠ 为什么**不**复用 `ManageSchedule`：两者都是管理员动作，但语义不同 ——
     *   `ManageSchedule` 管的是"号源与排班"（易变的运营数据），
     *   本动作管的是"科室与医生档案"（**相对稳定的主数据**）。
     *   合成一条的后果不是"现在会出错"，而是**将来无法只放开其中一个**
     *   （例如"让科室主任改本科室医生"就必须拆开）。
     *   📌 本仓纪律：权限动作按**语义**分，不按"当前谁能做"分。
     */
    | ManageBaseData          // 维护科室/医生档案（仅管理员）
    /*
     * ★ 2026-10-09（P5 知识库）新增两条。**读与写分开**，与 P4 的病历同一考量。
     *
     * ⚠ 为什么读侧单独一条、且**不给患者**：
     *   知识库文档是**院内运营资料**（就诊须知/流程说明等），
     *   患者**不需要**直接检索它 —— 患者拿到的是分诊结论里被引用后的那段说明。
     *   把原始知识库开放给患者端，等于交出一个**可自由检索院内文档**的入口
     *   （其中可能有尚未定稿或被停用的内容）。⇒ 读侧只给**医生与管理员**。
     *   📌 权限按**语义**分、按**最小必要**给；不因为"反正只读"就放开 ——
     *     只读同样能泄露（未定稿/已停用内容）。
     */
    | QueryKnowledgeBase      // 检索知识库（医生 + 管理员；**患者不给**）
    | ManageKnowledgeBase     // 维护知识库文档（仅管理员）
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
        case ViewDashboard => return "view_dashboard"
    }
}

/*
 * ★ 权限判定的**唯一入口**（搬迁前铁律：收敛到单一函数，禁止 handler 手写 if）。
 *
 * 权限矩阵（P4 更新）：
 *
 *   动作                       患者   医生   管理员
 *   view_schedule               ✅     ✅     ✅
 *   book                        ✅     ❌     ❌
 *   cancel_own                  ✅     ❌     ❌
 *   cancel_any                  ❌     ❌     ✅
 *   manage_schedule             ❌     ❌     ✅
 *   query_own_medical_record    ✅     ✅     ❌   ← P4（"自己的"含义见 Action 注释）
 *   write_own_medical_record    ❌     ✅     ❌   ← P4（病历的临床作者只能是医生）
 *   manage_visit                ❌     ✅     ❌   ← P4（接诊队列）
 *   view_dashboard              ❌     ❌     ✅   ← P4（运营看板含全院聚合）
 *
 * ⚠ 三条刻意的选择，都值得说清：
 *   ① **管理员不能写病历** —— 病历的"作者"必须是临床人员。若管理员可写，
 *      "谁写的"就失去意义（而那是病历最要紧的属性之一）。
 *      管理员需要纠错时走**解锁**（`reopen`）这条显式通道，
 *      由医生改完再锁定 —— 修订责任仍在医生。
 *   ② **患者不能读任意病历，也不能读"自己以外"的** —— 由 handler 用
 *      `patient_id`（从令牌派生）过滤，权限只管到"这一类动作"。
 *   ③ **管理员不参与 `query_own_medical_record`** —— 管理员查病历属"审计"，
 *      与"读自己的"是两件事，本轮**没有**给管理员开通读病历的入口
 *      （未实现的动作不发权：给权限等于埋一个未测的入口）。
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
        /*
         * ★ P5 知识库两条。
         *
         * ⚠ 读侧**不给患者**（理由见 Action 枚举处的注释）：
         *   患者需要的是"分诊结论里被引用后的那句话"，不是"自由检索院内文档的入口"。
         *   📌 不因为"只读"就默认放开 —— 只读也能泄露（未定稿/已停用的内容）。
         */
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
        case ViewDashboard =>
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
 * 当前请求的身份。
 *
 * ⚠ 这是 `principalOf()` 与 `can()` 之间的**唯一契约**：
 *   身份来源怎么变（开发态头 / 令牌），这个结构不变，
 *   所以权限矩阵与业务逻辑都不用动。
 */
public class Principal {
    public var userId: Int64 = 0
    public var role: Role = Role.Patient
    public var patientId: Int64 = 0
    public var doctorId: Int64 = 0
    public var loginName: String = ""
}

/*
 * 开发态身份开关。
 *
 * ⚠⚠ 这是**临时形态**，不是最终鉴权：
 *   搬迁前用的是"不透明令牌 + PBKDF2 三阶段加锁"（搬迁前 auth.cj），
 *   本阶段为把接口与权限骨架先立起来、先测通，改用显式请求头。
 *
 * 三重保险，避免它悄悄上生产：
 *   1. 必须显式传 `--dev-auth` 才启用（默认关闭）；
 *   2. 启用时**每个请求**都打一行 [DEV-AUTH] 警告日志；
 *   3. 传了 `--prod` 时**直接拒绝启动**。
 *
 * ⚠ 为什么用 `--prod` 命令行开关而不是环境变量 `HOSPITAL_ENV`：
 *   本工具链的仓颉 std **没有 `getEnv`/`envVars`**
 *   （框架 config.cj:17-21 逐字核对过："neither std.env nor std.process has them"；
 *    搬迁前 main.cj:24-25 因此也明说"不支持环境变量配置，只能走命令行"）。
 *   所以这里照搬迁前的做法走命令行开关 —— 用环境变量会静默永远不生效，
 *   那比没有更糟（以为生产被保护了，其实没有）。
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
 * 从请求解析身份。
 *
 * ★ 优先级（P1 令牌体系上线后）：
 *   1. **`Authorization: Bearer <token>`** —— 正式路径。
 *      令牌是 32 字节随机 → 64 位 hex，服务端存 token → user 映射（不是无状态 JWT），
 *      所以"停用账号/改密码"能立即踢下线。
 *   2. 开发态身份头（`X-Role` / `X-Patient-Id`）—— **仅在 `--dev-auth` 下才看**，
 *      每请求打 `[DEV-AUTH]` 警告。用于本机快速联调。
 *   3. 两者都没有 → **401，明确失败**。
 *
 * ⚠ 顺序很重要：先看令牌。这样即使有人误开了 `--dev-auth`，
 *   带合法令牌的正式请求也不会走开发态分支（少一条"以为在用令牌其实在用头"的歧路）。
 *
 * ⚠ 非开发态下**绝不静默放行** —— 静默放行是最危险的失败方式。
 */
public func principalOf(ctx: Context, gate: DevAuthGate, auth: AuthRepo): Principal {
    let now = hNowEpoch()

    /* 1) 正式路径：Bearer 令牌 */
    match (bearerToken(ctx)) {
        case Some(tok) =>
            match (auth.principalByToken(tok, now)) {
                case Some(p) => return p
                case None =>
                    // 令牌无效/过期 —— 明确区分"过期"与"无效"，便于客户端决定是否跳登录页
                    throw apiErrorMsg("AUTH_TOKEN_EXPIRED",
                                      "令牌无效或已过期，请重新登录")
            }
        case None => ()
    }

    /* 2) 开发态身份头（仅 --dev-auth 下） */
    if (gate.enabled) {
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

/* 取出 Authorization: Bearer <token>（照搬迁前 auth.cj:136 口径）。 */
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
 * ★ 取消退号是否被允许 —— 把"归属"纳入权限口径（2026-10-07 修）。
 *
 * 为什么单独抽出来：原先 handler 里是
 *     `if (can(role, CancelAny)) {放行} else { requireCan(role, CancelOwn); if (归属不符) throw }`
 * —— 权限判定**被拆成了两处**，这就违反了本项目"权限收敛到单一函数"的纪律
 * （第三方复查指出：这是"禁止 handler 手写 if"被绕过的例子）。
 * 更实际的问题是：**同一条规则会被复制到下一个需要归属判定的接口上**
 * （比如"查看自己的病历"），迟早出现两处实现不一致。
 *
 * 现在的口径是**一个函数、两段都覆盖**：角色能不能退 且 这张单归不归他。
 */
public func canCancel(role: Role, actorPatientId: Int64, appointmentPatientId: Int64,
                      actorUserId: Int64, appointmentOwnerUserId: Int64): Bool {
    // 管理员：可退任意单
    if (can(role, Action.CancelAny)) {
        return true
    }
    // 患者：只能退自己的单。**按 patient 归属判定**（业务身份），
    // 不按 user 归属 —— 一个患者理论上可以有多个登录账号，但病历/挂号只认 patient。
    if (can(role, Action.CancelOwn)) {
        return actorPatientId > 0 && actorPatientId == appointmentPatientId
    }
    return false
}

/* ===================== 入参读取 ===================== */

/* 请求体必须是 JSON 对象；否则 400（而不是让框架抛 500）。 */
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
            // 空体视作空对象：让"缺字段"走统一的字段校验错误
            return JsonObject()
    }
}

/* 出参：把 BookingResult 转成 JsonObject（客户端契约）。 */
func bookingJson(r: BookingResult): JsonObject {
    let o = JsonObject()
    o.put("appointment_id", JsonInt(r.appointmentId))
    o.put("schedule_id", JsonInt(r.scheduleId))
    o.put("patient_id", JsonInt(r.patientId))
    o.put("doctor_id", JsonInt(r.doctorId))
    o.put("department_id", JsonInt(r.departmentId))
    o.put("visit_date", JsonString(r.visitDate))     // ★ 就诊日快照
    o.put("period", JsonString(r.period))
    o.put("seq_no", JsonInt(r.seqNo))
    o.put("status", JsonString(r.status))
    // ★ 退号时"号源是否已归还"必须回给客户端：否则客户端无从知道
    //   上一次那个 SlotNotRestored 告警还在不在（见 domain_booking.cj cancel 注释）。
    o.put("slot_restored", JsonBool(r.slotRestored))
    return o
}

/* ===================== 路由 ===================== */

/*
 * 装配路由。
 *
 * 路径带 `/api/v1` 前缀（与搬迁前的 api-design 口径一致，便于客户端复用同一套 base-url 处理）。
 *
 * ⚠ 三端业务接口的**身份来源**是 `principalOf(ctx, gate, auth)` ——
 *   从开发态头切到令牌，这里只改了这一个调用点的实参，业务逻辑一行未动。
 */
/*
 * 从请求头取"设备标识"（P1 收尾项 ②）。
 *
 * 约定（客户端在登录与后续请求里带上；都是**可选**的）：
 *     X-Device-Id    —— 稳定标识（设备安装 id / 浏览器指纹）
 *     X-Device-Name  —— 给人看的名字（"iPhone 15" / "Chrome on Windows"）
 *
 * ⚠⚠ **这两个值一律不可信**：它们是客户端自报的。
 *   用途仅限"会话列表的展示与区分"，**绝不参与授权判定** ——
 *   否则伪造一个 X-Device-Id 就能冒充别人的会话。
 *   授权依据始终是 Bearer token（见 principalOf）。
 *
 * ⚠ 长度截断到 64（与 DDL 一致）：不截断会让超长头直接撞 MySQL 的
 *   "Data too long" 报 500 —— 一个请求头把接口打成 500 是很容易被用来刷错误日志的。
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
 * 校验 `YYYY-MM-DD` 形状（P1 收尾项 ④ 的入参校验）。
 *
 * ⚠ 只做**形状**校验（4-2-2 数字 + 分隔符），不校验"2026-02-30 是否真实存在"：
 *   后者需要日历逻辑，而它的收益只是把一条空列表换成一条 400 —— 不值。
 *   形状校验挡住的是**手误**（`2026-13-99`、`2026/10/08`、漏一位），
 *   这才是实际会发生的错。
 *
 * ⚠ 不要为了省事用 `parseInt64Or` 去解日期 —— 它会把 `2026-13-99` 解析成
 *   2026 然后静默丢掉其余部分，那比不校验更坏。
 */
func isDateLike(s: String): Bool {
    if (s.size != 10) {
        return false
    }
    /*
     * ⚠ 用 `Int64(a[i])` 与 **ASCII 码**比，不要写 `a[i] != r'-'` ——
     *   实测报 `invalid binary operator '!=' on type 'UInt8' and 'Rune'`：
     *   `s.toArray()` 给的是 UInt8，而 `r'-'` 是 Rune，两者不能直接比。
     *   统一转 Int64 再比（0x2D = '-'，0x30..0x39 = '0'..'9'）。
     */
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

func truncate64(s: String): String {
    if (s.size <= 64) {
        return s
    }
    return s[0..64]
}
/*
 * 把 epoch **天数**转成 (年, 月, 日)。
 *
 * ── 为什么自己写而不用库 ────────────────────────────────────────────────
 * 仓颉 std 里没有可直接用的"epoch → 年月日"（`std.time` 给的是 `DateTime`
 * 的字段访问，但它按**本地时区**解释，而我们要的是**稳定可比**的日期字符串）。
 *
 * 用的是 Howard Hinnant 的 `civil_from_days`（公有领域算法）：
 * 它**不需要闰年表、不需要 13 个月的数组、不需要循环**，
 * 只有整数除法 —— 所以"闰年判断"这类最容易写错的地方在这里根本不存在。
 *
 * ⚠ 已用 9 个已知日期**逐个核对**（含 `2000-02-29` 这个世纪闰日、
 *   `2026-10-01`、`1970-01-01` 等），全部吻合 —— 见 triage 的测试记录。
 *   这类"手写日期算法"必须这样验，不能只跑一个"今天"看着对就完事。
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
 * 两位补零（日期串必须是**固定宽度**，否则字符串比较 `"2026-9-1" >= "2026-10-01"`
 * 会给出错误结果 —— 逐字符比时字符 `9` 大于 `1`，会让 9 月排在 10 月之后）。
 *
 * ⚠ 名字带 `triage` 前缀：本项目是**单 package**（全部 .cj 编成一个包），
 *   而框架里已有一个 `pad2` —— 实测报 `function 'pad2' has overload conflicts`。
 *   单包模式下**所有顶层名字共享一个命名空间**，加前缀是最省事的隔离方式。
 */
func triagePad2(n: Int64): String {
    if (n < 10) {
        return "0${n}"
    }
    return "${n}"
}

/*
 * 今天的日期（UTC），格式 `YYYY-MM-DD`。
 *
 * ⚠ 用 **UTC** 而不是本地时区：这个值会参与 `work_date >= today` 的**字符串比较**，
 *   而字符串比较隐含"格式固定宽度"（见 `pad2` 的注释）。
 *   用 UTC 让同一份数据在任何时区的机器上给出相同结果 ——
 *   测试因此可复现（本地时区会让 CI 与开发机在同一天的边界上产生不同结论）。
 *   单院区场景下 UTC 与本地最多差几小时，"今天"的偏差对分诊无实质影响，
 *   而**可复现性**的收益是实打实的。
 */
func hTodayDate(): String {
    let ms = DateTime.now().toUnixTimeStamp().toMilliseconds()
    var days = ms / 86400000
    if (ms < 0 && ms % 86400000 != 0) {
        days = days - 1
    }
    let (y, m, d) = civilFromDays(days)
    return "${y}-${triagePad2(m)}-${triagePad2(d)}"
}

/*
 * 主诉输入的**字符**上限与**字节**上限。
 *
 * 两个都要：字节上限防"用超长 UTF-8 刷日志/内存"，
 * 字符上限是**实际裁剪**用的（见 `triageTruncateChars` 的说明）。
 * 500 字符足够容纳一段完整主诉（正常主诉几十字），不会误伤真实用户。
 */
let TRIAGE_INPUT_MAX_CHARS: Int64 = 500
/* 500 个字符最坏情况（中文 3 字节）= 1500 字节；留一点余量 */
let TRIAGE_INPUT_MAX_BYTES: Int64 = 1500

/*
 * 按**字符**截取前 n 个字符。
 *
 * ⚠ 存在的唯一理由：`String` 的下标/切片是**字节**偏移，直接 `s[0..n]`
 *   会在多字节字符中间切断 ⇒ 非法 UTF-8 ⇒ 下游抛 `Invalid utf8 byte sequence`。
 *   逐 `Rune` 收集到第 n 个为止，天然落在字符边界上。
 *   已用最小探针验证 `String("胸痛，呕血".runes() 收集)` 能正确往返。
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
 * 把分诊结论序列化成响应体。
 *
 * ⚠ 字段命名与错误码一样用 **snake_case**（与既有接口一致）。
 * ⚠ 刻意**不**把 `redFlagEvidence` 放进响应 —— 它是**内部依据**（命中哪些词），
 *   给患者看会变成"你自己说你胸痛"式的复述，没有价值；给攻击者看则暴露了
 *   词表结构（可用于试探绕过）。它只进服务端日志/审计。
 */
/*
 * ★ P5：为分诊取**知识库参考片段**。
 *
 * ⚠ 为什么单独一个函数（而不是在 handler 里内联三行）：
 *   ① 它包含**两个降级决定**（危急时不检索、检索出错不抛），
 *      内联会让 handler 里多出一段 try —— 而 handler 已经很长；
 *   ② 它必须**永不抛异常**：知识库是**旁路增强**，
 *      检索失败/表不存在都不该把患者正在等的分诊变成 500。
 *      （本仓纪律：旁路出错靠 `ai_reason` 说出来，不靠崩溃。）
 *
 * ⚠⚠ 危急征象时**不检索**，与 `aiEnhanceTriage` 里"不调模型"同一条理由：
 *   那时患者最需要的是"立刻就医"四个字，多一次数据库检索毫无收益。
 *   而且这条判断要放在**这里**（检索之前），不能只在 `aiEnhanceTriage` 里 ——
 *   否则检出 redFlag 却仍然白跑一次检索。
 */
func triageRagHits(kb: KbRepo, complaint: String, v: TriageVerdict): Array<KbHit> {
    if (v.redFlag) {
        return Array<KbHit>()
    }
    try {
        let res = kb.searchKeyword(complaint, topN: KB_SEARCH_TOP_N)
        return res.hits
    } catch (e: Exception) {
        /* 检索失败 ⇒ 当作"没有参考资料"，分诊照常。 */
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
    /*
     * ★ 2026-10-09 接真模型后新增两个字段（**只增不改**，老客户端不受影响）：
     *   · `ai_note`   —— 模型给的患者说明（无模型 / 降级时为空）
     *   · `ai_reason` —— 为什么没给（**给运维看**，不含密钥）
     *
     * ⚠⚠ `source` 字段的语义**没有变**：它仍如实标注这次结论的来源 ——
     *   `model`（模型答了）/ `model:invalid`（答了但没过安全检查）/ `rules`（降级）。
     *
     * ⚠ 这两个字段曾**漏掉过一次**，记下来：我上一轮用 PowerShell 的
     *   `$t.Replace("...\"ai_note\"...", ...)` 去改，而 PowerShell 的双引号串里
     *   `\"` 是**字面反斜杠 + 引号**（不是转义）⇒ 锚点永远匹配不上 ⇒ **静默什么都没做**。
     *   症状是"模型调通了、`source=model`、库里统计也对，但 `ai_note` 永远是空"，
     *   看起来像模型没产出内容 —— 而真相是这个字段根本没被输出。
     *   📌 教训：**改动后要验证目标确实变了**（看 diff / 看输出），
     *     不要因为"替换命令没报错"就假定它生效了。
     */
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
 * 把预问诊会话序列化成响应体（**业务值**，只走非流式路径）。
 *
 * ⚠ `form` 只在 `complete() == true` 时才输出 —— 半成品问诊单给出去，
 *   客户端可能把它当"已完成的就诊前信息"提交给医生。
 *   未完成时输出 `progress`（已填项数/总项数）让界面显示进度，但**不给表单内容**。
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
    // 下一个问题也一并给出：客户端不必再猜（它是**问句文本**，不是业务值）
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
public func buildHospitalRouter(repo: BookingRepo, auth: AuthRepo, gate: DevAuthGate, triage: TriageRepo, previsit: PrevisitRepo, aiSettings: AiSettingsRepo, prompts: PromptRepo,
                           emr: MedicalRecordRepo, visit: VisitRepo,
                           dash: DashboardRepo, triageStat: TriageStatRepo,
                           dept: DepartmentRepo, doc: DoctorRepo, kb: KbRepo): Router {
    let r = Router()

    /* ---------- 健康检查（无需认证，供压测与探活）---------- */
    r.get("/health", { ctx: Context, _: () -> Unit =>
        let o = JsonObject()
        o.put("ok", JsonBool(true))
        o.put("service", JsonString("hospital-server"))
        o.put("version", JsonString(SERVER_VERSION))
        o.put("data_backend", JsonString("mysql"))
        o.put("dev_auth", JsonBool(gate.enabled))
        ctx.status(200).json(o.toString())
    })

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
            // 顺带回身份摘要，省一次 /me 往返
            match (auth.findUser(loginName)) {
                case Some(u) =>
                    o.put("user_id", JsonInt(u.id))
                    o.put("role", JsonString(roleName(u.role)))
                    o.put("ref_id", JsonInt(u.refId))
                    o.put("display_name", JsonString(u.displayName))
                    /*
                     * ★ 顺手回 `patient_id`（2026-10-07，写 P1 收尾项测试时发现）：
                     *   患者登录后最需要它来调 `/api/v1/appointments`（"我的挂号"），
                     *   而此前只有 `/auth/me` 才给 —— 等于每次登录后都要多一次往返。
                     *   与 `/auth/me` 的口径保持一致（role=patient 时 = ref_id）。
                     */
                    o.put("patient_id", JsonInt(u.refId))
                case None => ()
            }
            sendOk(ctx, o)
            return
        }
        if (res.locked) {
            /*
             * ★ 被限流（P1 安全加固，2026-10-07）。返回 429 + `Retry-After`。
             *
             * ⚠ 这个分支**对"账号存在"与"账号不存在"一视同仁** ——
             *   因为限流按登录名记，且计数表 `auth_login_attempt` 与 `auth_user`
             *   **没有外键**（见 schema.cj 的说明）。所以它**不是**账号枚举的 oracle：
             *   连续输错 5 次后，存在的名字与不存在的名字都在第 6 次拿到 429。
             */
            ctx.header("retry-after", res.retryAfterSeconds.toString())
            throw apiError("AUTH_RATE_LIMITED")
        }
        /*
         * ⚠ 账号不存在与口令错误**返回同一个错误码**（AUTH_BAD_CREDENTIALS）。
         *   分开回就是在告诉攻击者"这个手机号注册过" ——
         *   而"谁在本院看过病"正是最该保护的信息（见 auth_crypto.cj loginCreds）。
         */
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
 * P1 收尾项 ②：令牌按设备管理。
 *
 * 只看**自己的**会话（`p.userId`）—— 没有"管理员看别人会话"的入口，
 * 因为那会把"谁在哪台设备登录过"变成可查询信息（隐私面）。
 * 管理员要踢人应走"重置口令"（那会吊销该账号全部令牌）。
 *
 * ⚠ 返回里**不含 token**：列出会话只需能区分是哪一台（见 SessionInfo 注释）。
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
 * ★ 两条安全设计（都写在 auth_repo.revokeSessionsByDevice 的注释里）：
 *   ① **只作用于自己**（`p.userId`）：不信任请求体里的任何 user_id；
 *   ② `device_id` 为空 → **明确拒绝 400**，而不是"删掉所有空 device_id 的会话"
 *      （那等于踢全部，而调用方以为自己只踢一台）。
 *      要踢全部请显式调 `POST /auth/logout-all`。
 */
r.post("/api/v1/auth/sessions/revoke", { ctx: Context, _: () -> Unit =>
    let p = principalOf(ctx, gate, auth)
    let body = bodyObj(ctx)
    let deviceId = match (requireStr(ctx, "device_id")) {
        case s => s
    }
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
        // 回显本次请求的设备标识：客户端据此在会话列表里标出"这台设备"
        let (devId, _devName) = deviceOf(ctx)
        o.put("device_id", JsonString(devId))
        sendOk(ctx, o)
    })

    /* ---------- POST /api/v1/admin/users —— 建账号（仅管理员）---------- */
    /*
     * P1 需要能造出可登录的账号；正式的账号管理界面属 P4。
     * 与建排班同理，受**认证 + 管理员角色**双重保护。
     */
    r.post("/api/v1/admin/users", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageSchedule)
        let body = bodyObj(ctx)
        let loginName = requireStr(ctx, "login_name")
        let password = requireStr(ctx, "password")
        let roleStr = requireStr(ctx, "role")
        let role = match (roleOf(roleStr)) {
            case Some(r) => r
            case None => throw apiErrorMsg("VALIDATION_FAILED", "未知角色：${roleStr}")
        }
        // ref_id：患者/医生必填（指向业务实体），管理员为 0
        var refId: Int64 = 0
        match (bodyInt64(ctx, "ref_id")) {
            case Some(v) => refId = v
            case None => ()
        }
        // ref_id：患者/医生必填（指向业务实体），管理员为 0。
        // ⚠ 仓颉的枚举**不能用 `==`**（语言坑 4：invalid binary operator '==' on Enum），
        //   所以角色判定一律走 match（或用 roleName() 转字符串比较）。
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
        /*
         * ★ 登录名已存在 → **409 明确报错**，不静默复用既有账号。
         *
         * 踩过的坑（本端点自己）：`AuthRepo.createUser` 是幂等的 ——
         * 已存在就返回既有 id。若这里直接回 201，就会出现
         * 「建账号成功、但传的 password 被静默忽略」这种**看起来成功其实没生效**的响应，
         * 调用方（人和脚本都会）据此以为账号建好了、口令是新的 —— 然后登录失败找不到原因。
         * 建账号与改口令是两件事，必须让调用方知道是哪一件。
         */
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

    /* ---------- GET /api/v1/admin/users?login_name= —— 按登录名查账号（仅管理员）---------- */
    /*
     * 用途：前台"这个手机号对应的账号 id 是多少"是常规需求；
     * 测试夹具也需要它来把已存在的账号口径拉回已知状态。
     *
     * ⚠ **只返回非敏感字段** —— 绝不回 pw_salt / pw_hash（哪怕给管理员也不回：
     *   口令材料没有任何前端用途，回它只是给泄露多开一条路）。
     */
    r.get("/api/v1/admin/users", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageSchedule)
        let loginName = ctx.queryParamOr("login_name", "")
        if (loginName.size == 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "缺少查询参数 login_name")
        }
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
    })

    /* ---------- POST /api/v1/admin/users/:id/password —— 重置口令（仅管理员）---------- */
    /*
     * 医院必须能重置忘记的口令（前台帮患者重置是常规操作）。
     *
     * ★ 安全语义：`setPassword` 会**吊销该账号的全部令牌** ——
     *   改口令必须踢下线，否则"口令泄露 → 改口令"这个补救动作是无效的
     *   （旧令牌仍然能用）。这条有测试钉住。
     */
    r.post("/api/v1/admin/users/:id/password", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageSchedule)
        let uid = parseInt64Or(ctx.paramOr("id", "0"), 0)
        if (uid <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "user_id 必须是正整数")
        }
        let body = bodyObj(ctx)
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

    /* ===================== AI 能力中心（P3）===================== */

    /*
     * ★★ 三条设计要点（P3 的核心）：
     *
     *   ① **改配置零重启**：写库 → `invalidate()` → 下次读拿到新值。
     *      没有"重启服务"这一步（那是参考系统创新点①要解决的痛点）。
     *
     *   ② ★★ **密钥绝不落库、也绝不回显**：
     *      · 库里的 `ai.key_ref` 只存**引用**（`env:名` / `file:路径`），
     *        形状由 `validateKeyRef()` 机制性把关；
     *      · 回显时 `secret` 项**只给"是否已设置 + 引用类型"**，
     *        连变量名/路径都不回（路径会泄露部署结构）。
     *      即使是管理员也不回明文 —— 与"账号接口绝不回 pw_hash"同一条纪律。
     *
     *   ③ **写操作仅管理员**（`Action.ManageSchedule`），读也是 ——
     *      AI 配置包含 endpoint 与部署路径信息，不该对患者/医生开放。
     */

    /* ---------- GET /api/v1/admin/ai/settings —— 读配置（仅管理员，秘密项脱敏）---------- */
    r.get("/api/v1/admin/ai/settings", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageSchedule)
        sendOk(ctx, aiSettingsJson(aiSettings, hNowEpoch()))
    })

    /* ---------- PUT /api/v1/admin/ai/settings/:key —— 改一项配置（仅管理员）---------- */
    /*
     * ⚠ 用 PUT + 路径参数（而不是 POST 一个 JSON 体）：配置项是**幂等的键值写**，
     *   PUT 的语义正好；而且这样"改了哪一项"在访问日志里一眼可见（便于审计）。
     */
    r.put("/api/v1/admin/ai/settings/:key", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageSchedule)
        let key = ctx.paramOr("key", "")
        let body = bodyObj(ctx)
        let value = match (bodyStr(ctx, "value")) {
            case Some(v) => v
            case None => ""
        }
        let res = aiSettings.put(key, value, hNowEpoch())
        if (!res.ok) {
            /*
             * ⚠ 拒绝原因**如实回给调用方**（它是给运维看的话，不含敏感信息）——
             *   但**不回显被拒的值**：如果那是一个误写成裸密钥的值，
             *   回显它就等于把密钥写进了响应体与访问日志。
             */
            throw apiErrorMsg("VALIDATION_FAILED", res.rejected)
        }
        sendOk(ctx, aiSettingsJson(aiSettings, hNowEpoch()))
    })

    /* ---------- GET /api/v1/admin/ai/prompts —— 读 Prompt 模板（仅管理员）---------- */
    /*
     * ⚠ Prompt 正文**原样回显**（不做脱敏）：它不是机密 —— 它是"让模型干什么"的
     *   指令文本，管理员必须能核对。**密钥才脱敏**，两者不是一回事。
     */
    r.get("/api/v1/admin/ai/prompts", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageSchedule)
        sendOk(ctx, aiPromptsJson(prompts, hNowEpoch()))
    })

    /* ---------- PUT /api/v1/admin/ai/prompts/:name —— 改模板（仅管理员）---------- */
    r.put("/api/v1/admin/ai/prompts/:name", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageSchedule)
        let name = ctx.paramOr("name", "")
        let body = bodyObj(ctx)
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
        requireCan(p.role, Action.ManageSchedule)
        let name = ctx.paramOr("name", "")
        if (!prompts.reset(name, hNowEpoch())) {
            throw apiErrorMsg("VALIDATION_FAILED", "未知的 Prompt：${name}")
        }
        sendOk(ctx, aiPromptsJson(prompts, hNowEpoch()))
    })

    /* ---------- GET /api/v1/admin/ai/tools —— AI 工具开关（仅管理员）---------- */
    r.get("/api/v1/admin/ai/tools", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageSchedule)
        sendOk(ctx, aiToolsJson(aiSettings, hNowEpoch()))
    })

    /* ---------- PUT /api/v1/admin/ai/tools/:name —— 开关某工具（仅管理员）---------- */
    /*
     * ⚠ 请求体的 `enabled` 只接受 `true`/`false`（布尔），不接受 "1"/"yes"/"on"：
     *   多一种写法就多一处口径，而"开关只有两态"没必要给表达空间。
     */
    r.put("/api/v1/admin/ai/tools/:name", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageSchedule)
        let name = ctx.paramOr("name", "")
        let body = bodyObj(ctx)
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
        requireCan(p.role, Action.ManageSchedule)
        let key = ctx.paramOr("key", "")
        if (!aiSettings.remove(key, hNowEpoch())) {
            throw apiErrorMsg("VALIDATION_FAILED", "未知的配置项：${key}")
        }
        sendOk(ctx, aiSettingsJson(aiSettings, hNowEpoch()))
    })
    /* ===================== 业务接口 ===================== */

    /* ---------- POST /api/v1/triage —— 智能分诊（P2）---------- */
    /*
     * ★★ 三条设计口径（brief §5.2 + 搬迁前 `ai_client.cj` 口径 2）：
     *
     *   ① **结论非流式**：本接口一次性返回**校验过**的结论，绝不流式吐分诊结果。
     *      理由：这是**业务值**（要拿它去挂号）。流式会让客户端先拿到
     *      "推荐心内科"再拿到"其实推荐呼吸科"，而它可能已经拿第一句去挂号了。
     *   ② **先取证后结论**：`triageComplaint` 内部先跑危急征象保险丝，
     *      再做科室判定，**最后必须过 `TriageRepo` 的真实号源校验** ——
     *      返回的每个 option 都对应库里 `remain_num > 0` 的真实排班。
     *      没有任何"模型说的"内容会直接进 `options`。
     *   ③ **三态如实标注**：`source` 目前**只可能是 `rules`** —— 本轮不接真模型
     *      （Q6「AI 模型选型与合规」仍是待决问题，主诉属敏感信息）。
     *      刻意**不**把它标成 `model` 来显得"AI 已完成"。
     *
     * 权限：`Action.Book`（患者）。
     * ⚠ 患者 id 从**令牌**取，不从请求体取 —— 与「我的挂号」同一纪律。
     */
    r.post("/api/v1/triage", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.Book)
        let body = bodyObj(ctx)
        let complaint = match (bodyStr(ctx, "chief_complaint")) {
            case Some(v) => v
            case None => throw apiErrorMsg("VALIDATION_FAILED", "缺少必填字段 chief_complaint")
        }
        /*
         * 长度上限：主诉是**用户输入**，直接进词表匹配与日志。
         * 不设上限等于让一个请求把日志刷爆（也顺带保护分词循环）。
         * 这里不报错而是**截断**：患者多写几句不该被拒 —— 多出来的内容
         * 对分诊无用，但拒掉会让体验变差。截断这个动作**如实上报**（truncated
         * 字段），不静默。
         *
         * ⚠⚠ **必须按"字符"截断，不能按"字节"截断** —— 我第一版就是 `text[0..500]`，
         *   实测**超长中文主诉直接 500**：`String` 的下标是**字节**偏移，
         *   而一个汉字占 3 字节，500 不是 3 的倍数 ⇒ 切在汉字中间 ⇒
         *   拼出**非法 UTF-8**（下游 `redFlagSegments` 抛 `Invalid utf8 byte sequence`）。
         *
         *   这个缺陷形态很典型：**只在"输入足够长且长度不是字符宽度的整数倍"时才炸**，
         *   所以短输入的手工测试完全发现不了（我一开始用 12 字测是好的）。
         *   已由 `triage-check.ps1` 的"超长主诉"用例守住。
         */
        var text = complaint
        var truncated = false
        if (text.size > TRIAGE_INPUT_MAX_BYTES) {
            text = triageTruncateChars(complaint, TRIAGE_INPUT_MAX_CHARS)
            truncated = true
        }
        let today = hTodayDate()
        let v = triageComplaint(triage, text, today)
        /*
         * ★★ 2026-10-09：**模型增强层**（P3 建好配置底座后补上的最后一环）。
         *
         * ── 它做什么、不做什么（这个边界是本段最要紧的部分）──────────────
         *   ✅ 做：把「给患者看的那句话」写得更好读。
         *   ❌ 不做：**不碰 `v.options`**。科室/排班/号源永远由规则 + 数据库决定。
         *   ⇒ 于是 P2 立的硬性验证层「**绝不给没有号的推荐**」在接上模型之后
         *     **依然成立且不可能被绕过** —— 模型幻觉推荐一个没号的科室，是比
         *     规则出错更危险的失败（它看起来很有道理，患者会照做然后挂不上号）。
         *
         * ── 四种情形，四种如实标注 ──────────────────────────────────────
         *   · 未配置/未启用   ⇒ source=rules，`ai_reason` 说明为什么
         *   · 调用成功        ⇒ source=model，`ai_note` 是模型文字
         *   · 模型答了但不合格 ⇒ source=model:invalid（**要改 Prompt**，不是查网络）
         *   · 调用失败        ⇒ source=rules（降级），`ai_reason` 带**脱敏后**的原因
         * ⚠ **危急征象时不调模型**：那正是要立刻就医的场景，多一次网络往返
         *   只会延迟患者看到「立即就医」，收益为零、风险为正。
         */
        aiEnhanceTriage(v, text, aiSettings, hNowEpoch(), ragHits: triageRagHits(kb, text, v))
        /*
         * ★ P4：把**结论**记进统计表（看板的"分诊命中率"靠它）。
         *
         * ⚠ 记的是**结论字段**，**不是 `text`（主诉原文）** ——
         *   `TriageStatRepo.record` 的签名里**根本没有**主诉参数，
         *   所以"想记主诉"在**类型层面**就做不到（比注释约束硬）。
         *   主诉是患者自己写的一句话，是最敏感的自由文本；看板只需要计数
         *   （见 triage_stat.cj 文件头）。
         *
         * ⚠ `record()` 内部**吞异常** —— 统计是旁路，
         *   绝不能把患者正在等的分诊响应变成 500。
         */
        let topDept = if (v.options.size > 0) { v.options[0].departmentName } else { "" }
        triageStat.record(v.reasonCode, v.redFlag, topDept, truncated, v.source, hNowEpoch())
        sendOk(ctx, triageJson(v, truncated))
    })
    /* ===================== 预问诊（P2，SSE 流式）===================== */

    /*
     * ★★ 为什么预问诊的"对话文本"走 SSE，而业务值走普通 JSON
     *    —— brief §5.2 明确点名"这是本节最容易做错的地方"。详见 previsit.cj 文件头。
     *
     * 路由分工（这个划分本身就是纪律）：
     *   GET  /api/v1/previsit/stream   开新会话 + **流式**吐第一轮追问（对话文本）
     *   POST /api/v1/previsit/answer   提交一个答案 → 返回**结构化业务值**（问诊单状态）
     *
     * ⚠ `answer` **刻意不用 SSE**：它返回的是"下一个问题 + 已填项数 + 是否完成"，
     *   其中"已填项数/是否完成"是**业务值** —— 流式会让客户端拿到中间态
     *   （"已完成 3/6" → "已完成 4/6"），而它可能已经据此更新了界面进度条。
     *   对话文本流错了只是看到半句话；**业务值流错了是状态污染**。
     */
    r.get("/api/v1/previsit/stream", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.Book)
        let chief = ctx.queryParamOr("chief_complaint", "").trimAscii()
        /*
         * ⚠ 主诉先按**字符**截断再落库：按字节会在汉字中间切断 ⇒ 非法 UTF-8。
         *   （本项目已因按字节截断吃过一次 HTTP 500，见 triageTruncateChars 的注释。）
         */
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
        /*
         * ★ 进入流式模式。`streamStart` 设 content-type + transfer-encoding: chunked
         *   （框架会在首次 write 时刷响应头，handler 返回时自动写 last-chunk）。
         */
        let _ = ctx.streamStart("text/event-stream; charset=utf-8")
        // 帧 ①：会话元信息（客户端拿到 session_id 才能继续推进多轮）
        let meta = JsonObject()
        meta.put("session_id", JsonString(sid))
        meta.put("turn", JsonInt(sess.turn))
        meta.put("total_slots", JsonInt(intakeSlots().size))
        ctx.writeChunk(sseFrame("meta", meta))
        // 帧 ②…：逐句吐"对话文本"（每句一帧 —— 这就是"可流式"的那一半）
        for (line in previsitAssistantLines(sess, None)) {
            let o = JsonObject()
            o.put("text", JsonString(line))
            ctx.writeChunk(sseFrame("delta", o))
        }
        // 帧 末：显式告知流结束（客户端不必靠连接关闭来判断）
        let done = JsonObject()
        done.put("session_id", JsonString(sid))
        done.put("next_slot", JsonString(match (sess.nextSlot()) {
            case Some(sl) => sl.key
            case None => ""
        }))
        ctx.writeChunk(sseFrame("done", done))
        // ⚠ 已经流式写出 ⇒ **不能**再走 sendOk/sendError（那会二次写响应体）
        //   所以这里什么都不返回，让 handler 自然结束。
    })

    /* ---------- POST /api/v1/previsit/answer —— 提交一项答案（业务值，非流式）---------- */
    r.post("/api/v1/previsit/answer", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.Book)
        let sid = requireStr(ctx, "session_id")
        let key = requireStr(ctx, "slot")
        let body = bodyObj(ctx)
        let value = match (bodyStr(ctx, "value")) {
            case Some(v) => v
            case None => ""
        }
        let r = previsit.answer(sid, p.patientId, key, value, hNowEpoch())
        /*
         * ⚠ 会话不存在时返回 **404 而不是 403**：
         *   403 等于告诉调用方"这个 session_id 存在但不属于你" —— 那是个枚举 oracle，
         *   攻击者可以据此试探哪些会话 id 有效。404 对"不存在"与"不属于你"给同一答案。
         */
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
    /* ---------- GET /api/v1/schedules —— 排班列表（按科室/日期，P1 收尾项 ④）---------- */
    /*
     * 之前只有 `GET /schedules/:id`（按 id 查单个）。患者端要"看某科室某天有哪些号"
     * 只能靠猜 id —— 那是不可用的，所以补上列表。
     *
     * 查询参数（都可选）：`department_id`、`work_date`（YYYY-MM-DD）、`limit`
     * 三端可读（与查单个同一权限 Action.ViewSchedule）。
     *
     * ⚠ 含"已约满"（remain_num = 0）的排班 —— 藏起来会让患者以为"这天没排班"。
     *   是否可挂由客户端看 remain_num 自己判断。
     */
    r.get("/api/v1/schedules", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ViewSchedule)
        let depId = parseInt64Or(ctx.queryParamOr("department_id", "0"), 0)
        let date = ctx.queryParamOr("work_date", "").trimAscii()
        let lim = parseInt64Or(ctx.queryParamOr("limit", "100"), 100)
        /*
         * ⚠ 日期格式先校验再进 SQL：`work_date` 走**参数化**绑定（不会被注入），
         *   但格式检查仍有价值 —— 它把"typo 成 2026-13-99 却返回空列表"
         *   变成一条明确的 400，而不是让调用方以为"那天真没排班"。
         */
        if (date.size > 0 && !isDateLike(date)) {
            throw apiErrorMsg("VALIDATION_FAILED", "work_date 格式应为 YYYY-MM-DD")
        }
        let list = repo.listSchedules(departmentId: depId, workDate: date, limit: lim)
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
            o.put("enabled", JsonBool(s.enabled))
            arr.add(o)
        }
        let o = JsonObject()
        o.put("schedules", JsonArray(arr.toArray()))
        o.put("count", JsonInt(list.size))
        sendOk(ctx, o)
    })

    /* ---------- GET /api/v1/appointments —— 我的挂号（P1 收尾项 ③）---------- */
    /*
     * ★ **只看自己的**：patientId 一律取自**令牌**（`p.patientId`），
     *   **绝不**从查询参数取 —— 否则就是一个"改个参数读别人挂号"的越权接口。
     *   管理员/医生要看别人的挂号属 P4 运营看板，需另开接口并单独定权限。
     *
     * 查询参数：`include_cancelled=true` 才带上已取消的单（默认只看有效的）。
     */
    r.get("/api/v1/appointments", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        /*
         * ⚠ 判断角色要用 `match`/`roleName()`，**不能**写 `p.role != Role.Patient` ——
         *   仓颉的 enum 没有 `!=`（实测报
         *   `invalid binary operator '!=' on type 'Enum-Role' and 'Enum-Role'`）。
         *   本项目已多次踩到这个（见 http_app.cj 里其它角色判定）。
         */
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
        let arr = ArrayList<JsonValue>()
        for (a in list) {
            arr.add(bookingJson(a))
        }
        let o = JsonObject()
        o.put("appointments", JsonArray(arr.toArray()))
        o.put("count", JsonInt(list.size))
        sendOk(ctx, o)
    })

    /* ---------- GET /api/v1/schedules/:id —— 查排班（三端可读）---------- */
    r.get("/api/v1/schedules/:id", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ViewSchedule)
        let sid = parseInt64Or(ctx.paramOr("id", "0"), 0)
        if (sid <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "排班 id 必须是正整数")
        }
        let found = repo.findSchedule(sid)
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
        sendOk(ctx, o)
    })

    /* ---------- POST /api/v1/appointments —— 挂号（仅患者）---------- */
    r.post("/api/v1/appointments", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.Book)
        let body = bodyObj(ctx)
        let scheduleId = requireInt(ctx, "schedule_id")
        let clientToken = requireStr(ctx, "client_token")
        // 患者只能给自己挂号：不接受 body 里的 patient_id，
        // 一律用**身份里的** patientId。这样"帮别人挂号"这个面根本不存在。
        if (p.patientId <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "缺少 X-Patient-Id（开发态联调头）")
        }
        let now = hNowEpoch()
        // HTTP 层用更大的重试预算抗瞬时并发（见 domain_booking.cj 的
        // HTTP_BOOKING_RETRY 注释：默认 3 在 20 并发抢 8 号时会少卖）。
        let result = repo.book(p.patientId, scheduleId, clientToken, now,
                               maxRetry: HTTP_BOOKING_RETRY)
        // 幂等命中按 200 返回（不是 201）：没有新建资源
        match (result.outcome) {
            case Booked(_) => sendCreated(ctx, bookingJson(result))
            case AlreadyBooked(_) => sendOk(ctx, bookingJson(result))
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
        /*
         * 谁能退这张单：**单一判定函数**（见 canCancel）——
         * 管理员退任意；患者只退自己的。角色权限与归属判定都收敛在那里，
         * handler 不再手写 if（本项目纪律，也是第三方复查要求修的点）。
         */
        if (!canCancel(p.role, p.patientId, appt.patientId, p.userId, 0)) {
            // ⚠ 是否泄露"这张单存在"？这里有取舍：明确 403 便于患者自查"退错单了"；
            //   若要严格防枚举应改回 404。当前选 403，并在此显式记录这个取舍。
            throw apiErrorMsg("FORBIDDEN_ROLE",
                              "无权取消该挂号单（管理员可退任意单；患者只能退自己的）")
        }
        match (repo.cancel(id, hNowEpoch())) {
            case Cancelled =>
                /*
                 * ⚠ 必须**取消后重读**，不能用上面那个 appt 快照。
                 *   踩过的坑：appt 是取消**之前**读的，status 还是 "booked"，
                 *   直接回它会让客户端看到"退号成功但状态仍是已挂号"——
                 *   自相矛盾的响应比不返回还糟。
                 */
                match (repo.findAppointment(id)) {
                    case Some(after) => sendOk(ctx, bookingJson(after))
                    case None => throw apiError("APPOINTMENT_NOT_FOUND")
                }
            case SlotNotRestored =>
                // ★ 单已取消但号源未归还：HTTP 上算成功（单确实退了），
                //   但带一个显式标记让客户端提示"需人工处理"，绝不谎报失败。
                match (repo.findAppointment(id)) {
                    case Some(after) =>
                        let o = bookingJson(after)
                        o.put("status", JsonString("cancelled"))
                        o.put("slot_restored", JsonBool(false))
                        o.put("warning", JsonString("号源归还异常，请联系人工处理"))
                        sendOk(ctx, o)
                    case None => throw apiError("APPOINTMENT_NOT_FOUND")
                }
            case NotFound => throw apiError("APPOINTMENT_NOT_FOUND")
        }
    })

    /* ---------- POST /api/v1/admin/schedules —— 建排班（仅管理员）---------- */
    /*
     * P1 需要有办法造出真实号源才能测"扣号/退号/并发"。
     * 正式的排班维护界面属 P4（运营看板），这里先给一个**受 --dev-auth + 管理员角色
     * 双重保护**的最小写入接口；不开 --dev-auth 时它和业务接口一样直接 401。
     */
    r.post("/api/v1/admin/schedules", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageSchedule)
        let body = bodyObj(ctx)
        let doctorId = requireInt(ctx, "doctor_id")
        let departmentId = requireInt(ctx, "department_id")
        let workDate = requireStr(ctx, "work_date")
        let period = requireStr(ctx, "period")
        let total = requireInt(ctx, "total_num")
        if (total < 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "total_num 不能为负")
        }
        let now = hNowEpoch()
        repo.insertSchedule(doctorId, departmentId, workDate, period, total, now)
        let sid = repo.lastInsertId()
        let o = JsonObject()
        o.put("schedule_id", JsonInt(sid))
        o.put("total_num", JsonInt(total))
        o.put("remain_num", JsonInt(total))
        sendCreated(ctx, o)
    })
    /* ===================== P4：病历 + 接诊队列 + 运营看板 ===================== */
    /*
     * ⚠ 定义在 `http_p4.cj`（那一块有自己的纪律要写清：病历锁定语义、
     *   接诊状态机、"看板只出聚合"）。这里只**注册** ——
     *   于是"有哪些端点"仍然只有一处可数（便于 doc-counts 对账）。
     */
    registerP4Routes(r, auth, gate, repo, emr, visit, dash, aiSettings)

    /*
     * ★ 2026-10-09：基础数据域（科室/医生）的管理端 CRUD。
     *
     * ⚠ 为什么**必须**在这里调用（而不是让 http_base.cj 自己注册）：
     *   本仓纪律是"路由注册集中可见"—— 调用点写在一处，
     *   `doc-counts.ps1` 才能**数得清端点总数**（它扫的就是这几个登记在册的文件）。
     *   若让每个域自己注册，端点总数会变成"运行时才知道"，
     *   文档对账就失去依据 —— 而本仓**已经因为"计数脚本漏扫文件"踩过一次**
     *   （P4 时它漏扫 http_p4.cj，把 38 个端点报成 27 个）。
     */
    registerBaseRoutes(r, auth, gate, dept, doc)
    /*
     * ★ P5 知识库。
     * ⚠ 同样登记在这个函数里（理由见上）：`doc-counts.ps1` 才能数清端点总数。
     *   本仓已因"计数脚本漏扫文件"踩过一次（P4 把 27 报成 38 的前身），
     *   ⇒ 新增文件必须**同时**更新 `doc-counts.ps1` 的清单（端点 48 -> 55）。
     */
    registerKbRoutes(r, auth, gate, kb)

    return r
}

/* ===================== 应用装配 ===================== */

/*
 * ⚠ `triage` 由**调用方**传入（而不是在这里 `TriageRepo(db)`）：
 *   本函数拿不到 `db`（它只收仓储对象）。让调用方建好再传，
 *   保证"谁持有 db、谁决定暴露哪些仓储"这件事只有一处。
 *   分诊仓储是**只读**的：它只读 `schedule/doctor/department`，不做任何写 ——
 *   与 ADR-0001 §4.3「号源域写操作只经 BookingRepo」一致。
 *   拆成独立对象而不是把只读查询塞进 BookingRepo，是为了让
 *   "分诊不会改号源"在**类型层面**成立，而不是靠约定。
 */
public func buildHospitalApp(repo: BookingRepo, auth: AuthRepo, gate: DevAuthGate,
                             triage: TriageRepo, previsit: PrevisitRepo,
                             aiSettings: AiSettingsRepo, prompts: PromptRepo,
                             emr: MedicalRecordRepo, visit: VisitRepo,
                             dash: DashboardRepo, triageStat: TriageStatRepo,
                             dept: DepartmentRepo, doc: DoctorRepo, kb: KbRepo): QingZhouApp {
    let router = buildHospitalRouter(repo, auth, gate, triage, previsit, aiSettings, prompts,
                                     emr, visit, dash, triageStat, dept, doc, kb)
    return QingZhouApp()
        .use(requestId())
        .use(logger())
        // bodyLimit 必须排在 bodyParser **之前**（外层）：框架的 bodyParser 是
        // "先把整个 body 读进内存、再比 maxBytes"，只有抢在它前面按 Content-Length
        // 拦，大 body 才进不了内存。
        // ⚠ 搬迁前的 `bodyLimit()` 是**搬迁前自己写的**（搬迁前 limits.cj:83），
        //   不在框架里；这里用框架原生的 `contentLengthLimit(maxBytes)`（bodyparser.cj:168）。
        //   上限 64 KiB —— 与搬迁前 MAX_BODY_BYTES 同口径（limits.cj:47）。
        .use(contentLengthLimit(64 * 1024))
        /*
         * ⚠ bodyParser() 的真实上限是**框架默认的 1 MiB**（bodyparser.cj:36
         *   `maxBytes = 1024 * 1024`），**不是**上面那个 64 KiB。
         *   两者关系是：
         *     · `contentLengthLimit(64 KiB)` —— 外层闸门，按 **Content-Length** 拦，
         *       所以声明了长度的大 body 在进内存**之前**就被挡掉（在 bodyParser 之前 use）；
         *     · `bodyParser()` 的 1 MiB —— 内层兜底，用于**没有 Content-Length** 的
         *       请求（chunked 编码时外层闸门看不出来，只能靠它）。
         *   实测：发 100 KiB 的 body → 413（外层闸门生效）。
         *   （复查指出"文档说 64 KiB、注释说 1 MiB"的口径不一致，根因就是把
         *     两个不同层的限额混着说了。这里把关系写清楚，数字不再打架。）
         */
        .use(bodyParser())
        .use(cors())
        /*
         * ⚠ `timeout(15000)` **不能中断**已经进入的同步 handler —— 这是实测确认的
         *   框架语义，不是配置问题：timeout.cj:64-83 的实现是
         *       `next()`（**同步跑完整个下游**）→ 再比较 elapsed → 超时才补一个 408。
         *   所以它只能"事后补告警"（handler 没写响应时给 408；
         *   已经写了响应就只加一个 `x-timeout-ms` 响应头），
         *   **不会**把慢 handler 掐掉、也不会释放它占的线程。
         *
         *   对本项目意味着什么：挂号/退号路径里**不能有慢操作**
         *   （这也是"事务内禁止出站网络调用"那条纪律的另一面 —— 见 ADR-0001 §6）。
         *   真正的超时保护要靠：① 单条 SQL 的 `innodb_lock_wait_timeout`；
         *   ② 未来若引入 AI/HTTP 出站，必须在**事务外**做并自带超时。
         */
        .use(timeout(15000))
        .use(router.middleware())
        .onError({ ctx: Context, _: () -> Unit => hospitalErrorHandler(ctx) })
}

/*
 * 持有 ServerHandle。
 * 必须放在 class 的字段里而不是闭包捕获的 var —— 仓颉闭包不能捕获可变变量
 * （本项目已踩过两次，见 domain_booking.cj 的 TxResult）。
 */
public class HandleBox {
    public var handle: ?ServerHandle = None

    public init() {}
}
