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
    /*
     * ★ 2026-10-12（患者端联调发现的契约缺口）新增三条。
     *
     * 背景不是"想加功能"，而是**实测出来的窟窿**：患者端首页/就诊列表/医疗档案
     * 拿到 `/appointments`、`/schedules` 之后只有 `department_id` / `doctor_id`，
     * 界面上只能显示「科室 #810003 · 医生 #900003」——
     * 因为**患者角色拿不到任何科室/医生字典**（那两个列表此前只在
     * `/api/v1/admin/departments|doctors` 下、仅管理员）。
     * 公告更彻底：**服务端没有这张表、也没有这个端点**，首页那块只能是写死的假数据。
     *
     * ⚠ 为什么 `ViewBaseData` 与 `ViewSchedule` 分开（而不是复用后者）：
     *   `ViewSchedule` 管的是**排班号源**（会变、与挂号强相关），
     *   本动作管的是**科室/医生主数据**（相对稳定、与挂号无关）。
     *   合成一条的后果不是"现在出错"，而是**将来无法只放开其中一个**
     *   （例如"只让患者看科室介绍，但不开放排班查询"就必须拆开）。
     *   📌 本仓纪律（见上面 ManageBaseData 的注释）：权限动作按**语义**分，
     *     不按"当前谁能做"分 —— 那是这条纪律的第二次应用，不是例外。
     *
     * ⚠ `ViewNotice` 为什么给**三端**：公告是**面向所有人**的院内通知
     *   （就诊提醒、健康提示、服务说明），本来就是"公开信息"。
     *   它不属知识库：知识库会被检索并随 Prompt 出站，
     *   公告只是展示（见 schema.cj `TABLE_NOTICE` 的边界说明）。
     *   写侧（`ManageNotice`）同理只给管理员 —— 读与写分开，与 P4/P5 一致。
     */
    | ViewBaseData            // 读科室/医生目录（三端都能看）
    | ViewNotice              // 读公告（三端都能看）
    | ManageNotice            // 维护公告（仅管理员）
    /*
     * ★ 2026-10-14（第三方复查 B8 的**根治**）新增两条。
     *
     * 背景：AI 全套端点（14 处）与 `/admin/users`（3 处）此前都写
     *   `requireCan(p.role, Action.ManageSchedule)` —— 当时**行为**是对的
     *   （`ManageSchedule` 恰好 = admin-only），但那是**巧合**，
     *   不是矩阵表达出来的事实：它把"能不能改排班"和"能不能改 AI 密钥引用/
     *   建管理员账号"绑成了同一个答案。
     *
     * ⚠ 为什么不能就这么留着（"现在反正都是管理员"）：
     *   一旦排班权限按业务需要放开（例如"护士长可调号源"是极常见的诉求），
     *   **AI 配置与账号管理会跟着一起失守** —— 而且失守方式是"没有报错、
     *   没有测试变红"的静默越权：改的是 `can()` 里一行，漏的是另外 17 个端点。
     *   这正是本仓纪律（权限动作按**语义**分，不按"当前谁能做"分）要防的事。
     *
     * ⚠ 为什么不复用 `ManageBaseData`（科室/医生档案）：
     *   那是**主数据**（相对稳定的档案），AI 是**运行时配置**（含 endpoint、
     *   密钥引用、模型参数），账号管理是**身份与凭据**。三者的变更审批口径
     *   天然不同（改 AI 密钥引用要能审计、建管理员账号要更严），
     *   合成一条就再也拆不开。
     *
     * 📌 本次只**新增动作、不改授权结果**：两条都是 admin-only，
     *   所以对现有客户端**零行为变化**；变的是"以后能只动其中一个"。
     */
    | ManageAi                // 维护 AI 配置（设置/Prompt/工具/模型，含密钥引用）（仅管理员）
    | ManageUser              // 维护账号与口令（建号/改口令/列号）（仅管理员）
    /*
     * ★ 2026-10-15（改进 3：病历修订历史）新增一条。
     *
     * 覆盖两个动作：**解锁病历**（`record/reopen`）与**读全部修订审计**。
     *
     * ⚠ 为什么这次**必须**新增动作，而不是继续复用 `ManageSchedule`：
     *   改进 3 落地前，`record/reopen` 复用的是 `ManageSchedule`，并写了理由
     *   （"没有'解锁病历'这个动作，复用一个管理员动作避免矩阵膨胀"）。
     *   那条理由的前提是"该端点只有一个用处"。现在前提变了：
     *   本动作有了**第二个用处**（修订历史的审计读）—— 正是当时写下的
     *   "等它有了第二个用处再提升为独立 Action"。
     *   ⚠ 关键区别不在"谁能用"（两者今天都是 admin-only，授权结果不变），
     *     而在**将来能不能只放开其中一个**：把"解锁病历"和"调整号源排班"
     *     绑成同一个答案，意味着某天"让护士长调号源"会连带把
     *     "推翻已定稿的医疗文书"一起放开 —— 而且不会有任何测试变红。
     *   📌 本仓纪律（第四次应用）：权限动作按**语义**分，不按"当前谁能做"分。
     */
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
 * 权限矩阵（2026-10-12 契约补齐新增三行）：
 *
 *   view_base_data              ✅     ✅     ✅   ← 读科室/医生目录（患者要它才能显示科室名）
 *   view_notice                 ✅     ✅     ✅   ← 读公告（面向所有人的院内通知）
 *   manage_notice               ❌     ❌     ✅   ← 维护公告
 *
 * 权限矩阵（2026-10-14 B8 根治新增两行 —— 原先这两类端点借用 manage_schedule）：
 *
 *   manage_ai                   ❌     ❌     ✅   ← AI 配置/模型/Prompt/工具/密钥引用
 *   manage_user                 ❌     ❌     ✅   ← 账号与口令（建号/改口令/列号）
 *
 * ⚠ 这两行是"把巧合变成事实"：它们此前的授权结果与现在**完全一致**
 *   （都是 admin-only），区别在于矩阵里现在**看得见**这两个动作 ——
 *   将来放开 `manage_schedule`（例如给护士长调号源）不会再连带把
 *   AI 密钥引用与账号管理一起放开。详见 `Action` 枚举处的长注释。
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
        /*
         * ★ 2026-10-12 新增三条。
         *
         * ⚠ 前两条**三端都给**，与 `ViewSchedule` 同侧：
         *   科室/医生目录与公告都是"没有患者私有信息"的公开数据 ——
         *   患者在界面上要显示"呼吸内科 / 张医生"就必须读得到它。
         *   若不给患者，客户端只能显示 `科室 #810003`（正是本次要修的窟窿）。
         * ⚠ 第三条只给管理员：公告面向全院发布，能改它的人越少越好
         *   （错发的公告比错发的排班更难收回 —— 患者已经看到了）。
         */
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
        /*
         * ★ 2026-10-14（B8 根治）新增两条 —— 都是 admin-only。
         *
         * ⚠ 这里**故意**写成与其他"仅管理员"动作一样的形状（而不是写一句
         *   `case ManageAi | ManageUser => ...`）：仓颉的 `match` 支持多模式，
         *   但这两条将来**极可能分道扬镳**（例如"只让信息科改 AI endpoint"
         *   或"只让医务科建账号"），并列写在一起会让下次拆分时少看见一处。
         *   逐条列出的成本是几行，漏改的代价是静默越权。
         */
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
        /*
         * ★ 2026-10-15（改进 3）新增：解锁已定稿病历（= 推翻一份临床记录）。
         *
         * ⚠ 授权结果与它此前借用的 `ManageSchedule` **完全一致**（都是 admin-only），
         *   所以这次拆分不改变任何人的实际权限 —— 改的是"语义"：
         *   以后若要放宽排班（例如让科室主任改班）就不会**顺带**放宽解锁病历。
         */
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
    /*
     * ★ 2026-10-14（跨端审计 F11）：令牌的**当前**有效期（epoch 秒）。
     *
     * ⚠ 必须是"**滑动续期之后**"的值，不能是查出来的旧值：
     *   续期就发生在 `principalByToken` 里，若这里回填续期前的数，
     *   客户端按它做本地倒计时就会比服务端**早一天**进登录页
     *   （审计里 Android 端"本地有效期不同步"就是这个字段缺失导致的）。
     * ⚠ 开发态身份（`--dev-auth` 的请求头）没有令牌 ⇒ 保持 0，
     *   客户端见到 0 应理解为"本次不是令牌会话"。
     */
    public var expiresAt: Int64 = 0
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
 *      **且只接受来自本机回环地址的请求**（见下方 `isLoopbackIp`），每请求打 `[DEV-AUTH]` 警告。
 *   3. 两者都没有 → **401，明确失败**。
 *
 * ⚠ 顺序很重要：先看令牌。这样即使有人误开了 `--dev-auth`，
 *   带合法令牌的正式请求也不会走开发态分支（少一条"以为在用令牌其实在用头"的歧路）。
 *
 * ⚠ 非开发态下**绝不静默放行** —— 静默放行是最危险的失败方式。
 *
 * ⚠ 2026-10-14（检查报告 C2 的第二半）：**开发态身份头原来不看到达地址**，
 *   于是"`--dev-auth` + `--bind 0.0.0.0`"= 任何能连上端口的人都能用 `X-Role: admin`
 *   拿到管理员身份。现在补上回环判定：**非回环来源即便开了 `--dev-auth` 也不认这两个头**，
 *   并且**明确 401 报错**（不是静默忽略 —— 静默会让本机联调者以为头生效了）。
 */

/*
 * 客户端 IP 是否为本机回环。
 *
 * 接受的写法（`Context.remoteIp()` 已剥掉端口，但 IPv6 会留下方括号）：
 *   · `127.0.0.1` / `127.x.y.z` —— 整个 `127.0.0.0/8` 按 RFC 1122 都算回环；
 *   · `::1` / `[::1]` —— IPv6 回环；
 *   · `::ffff:127.x.y.z` —— IPv4-mapped IPv6 形式的回环。
 * 其余（含空串）一律**不是**回环。
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
                    // 令牌无效/过期 —— 明确区分"过期"与"无效"，便于客户端决定是否跳登录页
                    throw apiErrorMsg("AUTH_TOKEN_EXPIRED",
                                      "令牌无效或已过期，请重新登录")
            }
        case None => ()
    }

    /* 2) 开发态身份头（仅 --dev-auth 下，且仅回环来源） */
    if (gate.enabled) {
        /*
         * ⚠ 先判来源，再判头：**非回环来源连"有没有 X-Role"都不看**，
         *   直接 401 —— 否则等于把 "--dev-auth 只能本机用"这条口径交给客户端自觉。
         * 📌 `remoteIp()` 为空 = 没有 http 传输信息（框架内部直调 handler 的进程内测试）。
         *   这种情形按"本机"处理（它根本没有网络来源可言），但打一行明显警告。
         */
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
    /*
     * ★ 2026-10-15（改进 6）：就诊时间线也回给**患者**。
     *
     * 为什么必须在挂号/列表/退号的响应里就有（而不是只给医生端）：
     *   患者打开"我的挂号"要看到的是"我 10:05 到院、10:40 开始接诊、11:20 完成"。
     *   这些数字只有服务端知道（`appointment.arrived_at/started_at/finished_at`），
     *   前端各自记一份换台设备就没了 —— 而这正是"我在医院等了三小时"这类
     *   投诉时唯一能拿出的事实。
     * ⚠ `status_label` 与 `status` 都给：见 `http_p4.cj` 的同一处理（机器判据 + 人话）。
     * ⚠ 0 = 该步还没发生（与 `created_at` 同口径）。
     */
    o.put("status_label", JsonString(visitStatusLabel(r.status)))
    o.put("arrived_at", JsonInt(r.arrivedAt))
    o.put("started_at", JsonInt(r.startedAt))
    o.put("finished_at", JsonInt(r.finishedAt))
    // ★ 退号时"号源是否已归还"必须回给客户端：否则客户端无从知道
    //   上一次那个 SlotNotRestored 告警还在不在（见 domain_booking.cj cancel 注释）。
    o.put("slot_restored", JsonBool(r.slotRestored))
    return o
}

/*
 * ★ 2026-10-12：挂号/退号响应的**完整形状** = `bookingJson` + 名称 + 当前余号。
 *
 * 为什么 `remain_num` 要在这里补（而不是加进 `BookingResult`）：
 *   `BookingResult` 是**这一次事务的结果**（扣了几个号、序号多少），
 *   而 `remain_num` 是**事务之后的库存快照** —— 两者语义不同：
 *   并发下"我扣了 1 个"与"还剩 N 个"之间别人可能又挂了号，
 *   把快照塞进事务结果会让人误以为它属于那一次事务。
 *   ⇒ 这里在写成功**之后**重读排班，拿的是"此刻的真相"。
 *
 * ⚠ 重读失败（排班被删）时**不写这个字段**，而不是写 0：
 *   `remain_num = 0` 的含义是"**已约满**"，而"排班不存在"是另一回事
 *   —— 写 0 会让界面显示"已约满"，而真实情况是这张排班已经没了。
 *   客户端按"字段不存在 = 未知，请看错误/重新查询"处理。
 *
 * ⚠ 名称取自 `names`（请求内的一次性快照），与响应里其它字段同源。
 *
 * ★ 2026-10-14（改进 1）：`previsitBound` 用 **`?Bool`** 而不是 `Bool = false`。
 *   同一条预约在三个端点回出（挂号 / 按幂等键反查 / 退号），但"是否绑定了
 *   预问诊单"只在**前两个**上是有意义的事实，退号响应里它既不相关也已过期。
 *   写成 `false` 会让"没查"与"确实没绑"长得一样 —— 那是**用同一个值表达两种
 *   语义**（本项目已有教训：`PrevisitAnswerOutcome` 复用字段漏判过一次）。
 *   传 `None` ⇒ 这个字段根本不出现；客户端对"字段不存在"的既有处理是"未知"。
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
 * ★ 2026-10-14（改进 4「让患者看懂操作结果」的服务端半步）：把"这一次请求"的两个
 *   **溯源字段**写进业务响应。
 *
 * 为什么要写在 **body 里**而不是只靠响应头 `X-Request-Id`：
 *   头在**成功的**响应里一直都在（框架 `requestId()` 中间件，见
 *   third_party/qingzhou/src/requestid.cj），但"挂号结果未确认"这个场景恰恰是
 *   **客户端压根没拿到响应**（断网/超时/进程被杀）——此时它唯一的线索是自己
 *   手里的幂等键。所以真正解决问题的不是这个字段，而是
 *   `GET /api/v1/appointments/by-token/:token`（见下面的路由）。
 *   带 `request_id` 的价值在**另一半场景**：客户端**拿到了**响应却看不懂
 *   （比如被中间设备改写、或前端解析失败），用户把编号报给客服，服务端日志里
 *   能一一对上（`requestId()` 会把它写进每条访问日志）。
 *
 * `server_time` 是服务端当前时间（**epoch 秒**，与全项目时间口径一致，见
 * `hNowEpoch()`）。客户端拿它与本机时间相减即可判断"我是不是离线太久/
 * 本机时钟错乱"，从而把"结果未确认"提示得更准确——本项目已有一次教训：
 * 设备时间跳变让"预约是否过期"算错，所以时间**一律以服务端为准**上报。
 *
 * ⚠ 两个字段都在 `data` 里（信封内），与业务字段平级，客户端可忽略。
 *   它们**不改变**任何既有字段的含义，所以对老客户端是纯增量。
 */
func putTrace(ctx: Context, o: JsonObject): Unit {
    /*
     * `ctx._id` 由 `requestId()` 中间件填充（信任客户端传入的 `X-Request-Id`，
     * 否则自己铸一个 32 位十六进制）。中间件未装配时它是空串 —— 这里照原样回，
     * 不自己造一个：**编造一个日志里查不到的编号比留空更坏**。
     */
    o.put("request_id", JsonString(ctx._id))
    o.put("server_time", JsonInt(hNowEpoch()))
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
 * `s` 是否全为 ASCII 数字（非空）。
 *
 * 用途：管理端查询参数的**显式**校验 —— 见 triage-stats 路由里对 `from`/`to` 的处理。
 * 为什么不用 `parseInt64Or` 直接判：它的语义是"解析不了就回兜底值"，
 * 于是 `?from=abc` 会被静默当成"没给参数"，调用者拿到的是另一个窗口的数据。
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
 * ★★ 全服务端**唯一的时区口径**：Asia/Shanghai（UTC+8）。
 *
 * 背景（实测发现的口径不一致，2026-10-12 修）：
 *   此前 `hTodayDate()` 用 **UTC** 的"天序"，于是：
 *     · 服务端"今天"在北京时间 00:00~08:00 之间**还是昨天**；
 *     · 而客户端 `ui/Theme.ets:131 todayString()` 用的是**设备本地日期**。
 *   ⇒ 每天有 8 小时窗口，两端对"今天"的答案不同：
 *     患者端把"今天"的排班当今天查，服务端却按昨天过滤 `work_date >= today`
 *     ⇒ **当天上午的号查不出来**（"明明有号却说没有"），
 *     而这恰好是门诊最忙、最不能出错的时段。
 *
 * ⚠ 为什么是**固定 +8** 而不是"取服务器时区"：
 *   ① 中国全境单一时区（Asia/Shanghai），**没有夏令时** ⇒ 固定偏移永远正确，
 *      不需要引入时区数据库；
 *   ② 服务端可能部署在任何时区的机器上（CI 是 UTC、开发机是 UTC+8），
 *      "按宿主机时区"会让**同一份数据在不同机器上给出不同答案**，
 *      而测试因此不可复现。固定偏移让结论与部署位置无关。
 *   📌 一般化：**"今天"是一个业务概念（医院的今天），不是机器属性。**
 *
 * ⚠ 与 `civilFromDays` / `triagePad2` 的关系：偏移**只在这里加一次**，
 *   日期换算仍然只有那两处实现（本仓写明"日期换算是最容易写错且错了也看不出来"）。
 */
public let HOSPITAL_TZ_OFFSET_SECONDS: Int64 = 8 * 3600

/*
 * epoch **毫秒** → Asia/Shanghai 的"天序"（1970-01-01 起的天数）。
 * ⚠ 负数（1970 年之前）向下取整：`-1 / 86400000` 在仓颉里是 0（截断），
 *   而正确结果是 -1。虽然现实中不会有 1970 年前的排班，
 *   但**取整方向错**这类 bug 一旦出现极难定位 ⇒ 显式处理并写明。
 */
func hDaysFromMillisShanghai(ms: Int64): Int64 {
    let shifted = ms + HOSPITAL_TZ_OFFSET_SECONDS * 1000
    var days = shifted / 86400000
    if (shifted < 0 && shifted % 86400000 != 0) {
        days = days - 1
    }
    return days
}

/* epoch **秒** → Asia/Shanghai 的"天序"（同上，负数同样向下取整）。 */
func hDaysFromSecondsShanghai(secs: Int64): Int64 {
    let shifted = secs + HOSPITAL_TZ_OFFSET_SECONDS
    var days = shifted / 86400
    if (shifted < 0 && shifted % 86400 != 0) {
        days = days - 1
    }
    return days
}

/*
 * 今天的日期（**Asia/Shanghai**），格式 `YYYY-MM-DD`。
 *
 * ⚠ 这个值会参与 `work_date >= today` 的**字符串比较**，而字符串比较隐含
 *   "格式固定宽度"（见 `triagePad2` 的注释）—— 所以补零不能省。
 * ⚠ 时区口径见 `HOSPITAL_TZ_OFFSET_SECONDS` 上方：改成 +8 就是为了与
 *   患者端设备上的本地日期**一致**（此前用 UTC，每天有 8 小时窗口对不上）。
 */
func hTodayDate(): String {
    let ms = DateTime.now().toUnixTimeStamp().toMilliseconds()
    let (y, m, d) = civilFromDays(hDaysFromMillisShanghai(ms))
    return "${y}-${triagePad2(m)}-${triagePad2(d)}"
}

/*
 * epoch **秒** → `YYYY-MM-DD`（Asia/Shanghai）。
 *
 * 用途：把库里存的时间戳渲染成**给人看的日期**（公告的 `date` 字段）。
 * ⚠ 与 `hTodayDate()` 共用同一个偏移与同一套换算 —— 这是刻意的：
 *   如果这里另写一份，公告显示的日期与"今天"的判定就会再次分家
 *   （那正是本次要修的病灶）。
 */
public func hDateStringOf(secs: Int64): String {
    let (y, m, d) = civilFromDays(hDaysFromSecondsShanghai(secs))
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
/*
 * 健康检查的响应体（`/health` 与 `/api/v1/health` 共用**同一份实现**）。
 *
 * ⚠ 只回"服务活着 + 版本 + 数据后端 + 是否开着开发态鉴权"+（2026-10-14 起）
 *   **医院今天**，**不查库**：探活接口查询库会让"库慢"表现成"服务挂了"，
 *   而这两件事的处置完全不同（重启进程 vs 查数据库）。
 *
 * ★ 2026-10-14（跨端审计 F14）：新增 `today` / `timezone`。
 *   起因：客户端拿**设备本地日期**去查排班（鸿蒙 `BookingPage` 默认日期、
 *   `Theme.todayString()`），而服务端"今天"是 Asia/Shanghai —— 设备时区不对
 *   或跨零点时，两侧对"今天"的答案不同：轻则默认日期查不到号，重则把
 *   过去的排班当可用（审计里"日期跟随设备时区"就是这么来的）。
 *   ⇒ 服务端把**权威日期**直接发出来，客户端只需读它，不必自己算时区。
 *   `hTodayDate()` 是纯计算（无库查询），所以探活接口仍然不碰数据库。
 */
/*
 * ★ 2026-10-17（S4 修）：`/health` 从"只回静态字段"改成"**当场探一次库**"。
 *
 * 改之前它完全不碰数据库 —— 库连不上时 `/health` 依旧 200，而所有业务接口 500
 * （实测：`KILL <连接 id>` 之后进程活着、探活全绿、每个请求 500，只能重启）。
 * 探针/负载均衡器于是把"全站不可用"判成健康，值班的人先看到"接口 500"而不是
 * "库挂了"，把一个 DBA 问题伪装成代码 bug —— 这一半比"连接不重连"更容易误诊。
 *
 * 现在：
 *   · `db.ok` 来自一次**真实往返**（`SELECT 1`，经 `DbBackend.probe()`，不碰业务表）；
 *   · 库不通 ⇒ 响应码 **503**（探针据此摘流量）+ `db.ok=false` + 固定短句原因；
 *   · `db.reconnects` 是累计重连次数 —— 非 0 说明链路抖过（S4 自愈生效的证据）。
 *
 * ⚠ `ok` 的口径随之收紧：以前恒为 `true`（= "进程活着"），现在 = "进程活着**且**库通"。
 *   客户端若拿 `ok` 判断"能不能用"，这正是它想要的语义。
 * ⚠ 失败原因**不回驱动原文**：本端点不鉴权，而驱动文案可能含用户名/主机名。
 *   细节只进服务端日志（`[HEALTH]` 前缀）。
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

/* 两个 `/health` 路径共用的 responder：**只探一次库**，按结果给 200 / 503。 */
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
    /*
     * ⚠ 路径**不在 `/api/v1` 下**（历史原因：它比 api 前缀更早就存在，
     *   压测脚本与部署探针都按 `/health` 写）。
     * ★ 2026-10-12：**再加一个 `/api/v1/health` 别名**。
     *   起因：患者端的 `ApiConfig` 会把所有请求拼在 `/api/v1` 之后，
     *   于是客户端想探活只能特判这一个路径 —— 一个"客户端要多写一个 if"的
     *   历史包袱。两个路径都留着（老探针不破），新代码可以走 api 前缀。
     *   两个 handler 都调同一个 `healthJson`，**不存在两份实现**。
     */
    r.get("/health", { ctx: Context, _: () -> Unit =>
        sendHealth(ctx, gate, dbProbe)
    })
    r.get("/api/v1/health", { ctx: Context, _: () -> Unit =>
        sendHealth(ctx, gate, dbProbe)
    })
    /*
     * ★ 这里**曾经**有一条 `GET /admin → 302 /admin/` 的路由，2026-10-14 删除。
     *
     * 删它的原因不是"不需要"，而是"永远轮不到"：静态中间件用前缀 "/admin"
     * 时会把余部为空的 `/admin` 也认领掉（前缀匹配成功 + 余部为空 ⇒ 目录
     * ⇒ 回 indexFile），所以这个 handler 是**死代码**。
     * 为了让它生效而把前缀改成 "/admin/" 更糟：框架守卫要求余部以 '/' 开头，
     * 那会让 `/admin` 前缀下的**所有资源**都透传到路由上 404（实测）。
     *
     * 结论：不靠重定向，改由**前端用绝对路径引用资源**（见 admin-web/index.html
     * 的 `/admin/css/style.css`、`/admin/js/api.js` 等）—— 这样 `/admin` 与 `/admin/`
     * 两种入口都能正常渲染。详细推理见 `buildHospitalApp` 里静态挂载的注释。
     */
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
    /*
     * ⚠ 2026-10-14（第三方复查 B2 修）：这里原先是
     *     `let body = bodyObj(ctx)` + `let deviceId = match (requireStr(ctx, "device_id")) { case s => s }`
     *   —— 两处都是噪声：`requireStr` 内部自己会调 `bodyObj`（http_common.cj），
     *   而那个只有单一 `case s =>` 的 match 等于直接赋值。噪声的代价不是多打几个字，
     *   而是**读代码的人会以为 body 被解析过一次、后面拿到的就是原始 JSON**。
     */
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
        /*
         * ★ 2026-10-12：补 `display_name`（此前只有登录响应里有）。
         *
         * 实测踩到的后果：患者端「我的 → 同步身份信息」调的就是本接口，
         * 而它不回姓名 ⇒ 改过姓名（或换设备登录）后按"同步"**刷不出新名字**，
         * 界面上一直是登录那一刻的旧值（客户端把它缓存在 SessionStore 里）。
         *   ⇒ 一个叫"同步身份信息"的按钮做不了它名字里写的事。
         *
         * ⚠ 取法：`principalByToken` 只填 userId/role/patientId/doctorId
         *   （**不查 auth_user 的其余字段**，见 auth_repo.cj 的注释），
         *   所以这里按 userId 补一次查询。
         * ⚠ 查不到（账号在登录后被删）**不报错**，只是不带这个字段：
         *   令牌还有效就说明会话成立，此时回 404 会让客户端卡在登录态里出不去。
         */
        match (auth.findUserById(p.userId)) {
            case Some(u) => o.put("display_name", JsonString(u.displayName))
            case None => ()
        }
        // 回显本次请求的设备标识：客户端据此在会话列表里标出"这台设备"
        let (devId, _devName) = deviceOf(ctx)
        o.put("device_id", JsonString(devId))
        /*
         * ★ 2026-10-14（跨端审计 F11）：回**当前**令牌有效期（滑动续期后的值）。
         *
         * 起因：续期发生在服务端（`principalByToken`，每天最多一次），但响应里
         *   从来没有地方告诉客户端"你现在的 expires_at 是多少" ⇒ 各端只能一直
         *   用登录那一刻的值做本地判断，续期对客户端**不可见**。
         * ⚠ `--dev-auth` 下没有令牌 ⇒ `expiresAt = 0`，客户端应把 0 当作
         *   "本次不是令牌会话"而不是"立刻过期"。
         */
        o.put("expires_at", JsonInt(p.expiresAt))
        sendOk(ctx, o)
    })

    /* ---------- POST /api/v1/admin/users —— 建账号（仅管理员）---------- */
    /*
     * P1 需要能造出可登录的账号；正式的账号管理界面属 P4。
     * 与建排班同理，受**认证 + 管理员角色**双重保护。
     */
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

    /* ---------- GET /api/v1/admin/users —— 账号查询 / 列表（仅管理员）---------- */
    /*
     * 用途：前台"这个手机号对应的账号 id 是多少"是常规需求；
     * 测试夹具也需要它来把已存在的账号口径拉回已知状态。
     *
     * ⚠ **只返回非敏感字段** —— 绝不回 pw_salt / pw_hash（哪怕给管理员也不回：
     *   口令材料没有任何前端用途，回它只是给泄露多开一条路）。
     *
     * ★ 2026-10-14：**同一路径补了列表模式**（管理台「用户管理」页需要一张能翻页的表）。
     *   两种语义由参数决定，**互不干扰**：
     *     · 给了 `login_name` ⇒ **按登录名精确查单条**（原语义原样保留，
     *       找不到仍 404 USER_NOT_FOUND —— 老的调用方与测试脚本一个字都不用改）；
     *     · 没给 `login_name` ⇒ **列表模式**：`limit`/`offset`/`role`/`status`，
     *       回 `{items,count,total,limit,offset}`。
     *   为什么不做成两个路径：两件事读的是**同一张表、同一批字段**，
     *   分成两条会让"字段只改了一边"这类不一致有机会发生。
     */
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
        /*
         * 列表模式。⚠ `limit` 缺省 50、夹到 1..200：与知识库/公告的"默认给一页、
         * 但不给无限"同一口径（无上限的列表 = 一次请求把库拖出来）。
         * ⚠ 非法值（0/负数/非数字）**回默认 50**而不是报错 —— 与"筛选值非法当没筛"
         *   同一条容错口径；`offset` 负数夹到 0（负偏移在 SQL 里是错误，不能透传）。
         */
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
            /*
             * ⚠ 列表项的键名与精确查询**保持一致**（`user_id` 而不是 `id`）：
             *   同一个路径两种模式，字段名不一致会让前端写两次解包。
             */
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
        /* `count` = 本页条数（与其余列表接口同义）；`total` = 符合条件的总数。 */
        o.put("count", JsonInt(n))
        o.put("total", JsonInt(auth.countUsers(roleFilter, statusFilter)))
        o.put("limit", JsonInt(limit))
        o.put("offset", JsonInt(offset))
        sendOk(ctx, o)
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
     *   ③ **写操作仅管理员**（`Action.ManageAi`；读也是）——
     *      AI 配置包含 endpoint 与部署路径信息，不该对患者/医生开放。
     */

    /* ---------- GET /api/v1/admin/ai/settings —— 读配置（仅管理员，秘密项脱敏）---------- */
    r.get("/api/v1/admin/ai/settings", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageAi)
        sendOk(ctx, aiSettingsJson(aiSettings, hNowEpoch()))
    })

    /* ---------- PUT /api/v1/admin/ai/settings/:key —— 改一项配置（仅管理员）---------- */
    /*
     * ⚠ 用 PUT + 路径参数（而不是 POST 一个 JSON 体）：配置项是**幂等的键值写**，
     *   PUT 的语义正好；而且这样"改了哪一项"在访问日志里一眼可见（便于审计）。
     */
    r.put("/api/v1/admin/ai/settings/:key", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageAi)
        let key = ctx.paramOr("key", "")
        /*
         * ★★ 命名空间闸门：本端点**只写 `ai.*` 静态登记项**（2026-10-14 修的真实漏洞）。
         *
         *   `AiSettingsRepo.put()` 是**共享**入口 —— 同一张 KV 表上挂了三个命名空间
         *   （`ai.*` / `prompt.*` / `ai.tool.*`，见那里的注释），所以它的"已登记"判定
         *   （`aiSettingKeyKnown`）**也认** `prompt.*` 与 `ai.tool.*`。而本端点是
         *   "配置项"语义的入口 ⇒ 于是
         *     `PUT /api/v1/admin/ai/settings/prompt.dept`（body 任意文本）
         *   能**绕过** `PromptRepo.put()` 的占位符/长度校验直接落库，
         *   而 `aiPromptsJson()` 与运行时都会读到它 —— 校验被静默跳过，
         *   配置却"看起来写成功了"。这是本仓一贯抓的那一类：
         *   **同一份数据有两个入口，只有一个入口装了闸门**。
         *
         *   ⇒ 处置：**在这个入口收窄**，不去动共享的 `put()` ——
         *     它的另外两个调用方（PromptRepo 的闸门在 PromptRepo.put 里、
         *     工具开关的闸门在 aiToolSet 里）都各自有校验，动共享层会连带改两处语义。
         *   ⚠ 消息里必须写明**该走哪条路**，否则调用方只会对着同一个 400 反复重试。
         */
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
    /*
     * ⚠ 请求体的 `enabled` 只接受 `true`/`false`（布尔），不接受 "1"/"yes"/"on"：
     *   多一种写法就多一处口径，而"开关只有两态"没必要给表达空间。
     */
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
        /*
         * ★★ 2026-10-14（第三方复查 B1 修）：**命名空间收窄必须与 PUT 一致**。
         *
         * 只信 `aiSettings.remove()` 是不够的：它内部走的是共享的 `aiSettingKeyKnown`，
         * 而那个函数认**三个**命名空间（`ai.*` / `prompt.*` / `ai.tool.*`）⇒
         * `DELETE /api/v1/admin/ai/settings/prompt.dept` 会被接受，把 Prompt 行删回默认值。
         *
         * 后果本身不是数据洞（删除不写值、绕不过任何校验），但它让
         * "PUT 收窄了、DELETE 没收窄"这个**口径分裂**留在同一对方法上：
         * 谁按 PUT 的报错提示去改用 prompts 端点，就会以为 DELETE 也该如此；
         * 而 DELETE 却照收 —— 自相矛盾的 API 比严格收窄的 API 更难用。
         * ⇒ 同一张登记表，两个入口用**同一条**闸门（消息里给出正确路径）。
         */
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
    /* ===================== AI 模型配置（`ai_model` 表）===================== */
    /*
     * ★ 与 `/admin/ai/settings` 的**分工**（两页并存，必须一句话说清）：
     *   · `ai/settings` —— **全局**事实：总开关、超时、并发、全局密钥引用兜底…；
     *   · `ai/models`   —— **一个模型一行**：类型(CHAT|EMBEDDING)/提供方/接口地址/
     *     模型名称/温度/最大Token/启停/是否默认。
     *   运行期装配口径：`AiSettingsRepo.options()` 取"默认对话模型"那一行**整体覆盖**
     *   KV（理由见那里的注释：逐字段合并会拼出一个"两个来源的模型"，没人知道请求发给了谁）。
     *
     * ⚠ 权限用 `Action.ManageAi`（与既有 14 条 AI 端点同一个动作）——
     *   同一个页面上出现两个权限动作，会让"谁能改 AI"有两个答案。
     *   📌 2026-10-14（B8 根治）之前这里借的是 `Action.ManageSchedule`：
     *     行为同样是 admin-only，但那让"改 AI"与"改排班"共用一个答案，
     *     详见 `Action` 枚举处的新增注释。
     */

    /* ---------- GET /api/v1/admin/ai/models —— 列表（仅管理员）---------- */
    r.get("/api/v1/admin/ai/models", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageAi)
        /*
         * ⚠ `include_disabled` 与科室/医生/公告**同口径**：默认 "true"（都返回），
         *   只有字面 "false" 才过滤停用。停用的配置本身就是管理台要看的对象 ——
         *   过滤掉会让"我那条配置怎么不见了"变成一个只能靠猜的问题。
         */
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
        /*
         * ★ 把"全局有没有密钥引用"一起回：管理台据此把每一行标成
         *   「自带密钥 / 用全局密钥 / 没有密钥」。少了这个字段，页面只能对
         *   `key_source == "global"` 的行显示一个无法解释的"已设置"。
         */
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
        /*
         * 缺省值取"播种那两行"的同款：温度 0.3、上限 2048。
         * ⚠ 缺省**只在这里**给（而不是在 `AiModel` 的字段默认值里兜）：
         *   写入路径要能把"没给"和"给了非法值"分开 —— 后者必须 400，不能静默变默认。
         */
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

    /*
     * ---------- POST /api/v1/admin/ai/models/invalidate —— 失效配置缓存 ----------
     *
     * ⚠ 路径必须注册在 `/models/:id` 之前？—— 本仓的 `:id` 路由都是 PUT/DELETE，
     *   POST 只有这一条与 `/:id/test`，**不存在**"POST /models/xxx 被当成 id"的歧义。
     *   （为保险起见仍然把它排在 `/:id/test` 之前：路由匹配顺序在 Trie 实现里
     *     依赖注册顺序时，先注册更具体的字面量路径是稳妥做法。）
     *
     * ★ 为什么需要这个按钮：写操作**已经**会主动失效缓存（`put`/`create`/`update`/`remove`
     *   内部都调 `invalidate()`），所以正常路径用不到它。它存在是为了**跨实例**与
     *   **直改数据库**这两种情形：前者最迟 5 秒（TTL）收敛，后者要等下一次写或 TTL。
     *   有一个显式入口，"我刚在库里改了配置、怎么还没生效"就不用靠猜。
     */
    r.post("/api/v1/admin/ai/models/invalidate", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageAi)
        let now = hNowEpoch()
        /*
         * 两张表各自的缓存在**两个仓储**里：
         *   · `ai_model` → AiModelRepo（模型行）
         *   · `ai_setting` → AiSettingsRepo（全局 KV）
         * 一次按钮两边都清 —— 否则"失效配置缓存"这个名字与实际效果不符
         * （管理台的分工是两页，但缓存是使用者看不见的东西，不该让他分两次点）。
         */
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
    /*
     * ⚠ 语义是 **PATCH**：请求体里**没给**的字段保持原值（见 `AiModelRepo.update` 的注释）。
     *   最典型的场景是"只想改温度"—— 若按 PUT 语义把缺省字段回默认，
     *   一次保存就会把 `key_ref` 清空，AI 随后**静默不可用**。
     */
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
    /*
     * ⚠ **硬删**（与知识库文档同口径），不是软删停用：
     *   需要"留着但不使用"时把 `enabled` 改成 false（PUT）即可。
     *   两条路都能表达"不用它"，就不该再给第三个含义模糊的开关。
     */
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
    /*
     * ★★ 三条口径（都在 `aiModelProbe` 的注释里，接口层再点名一次）：
     *   ① **真实出站**：这条路会真的打到大模型服务商 —— 它不是"配置自检"。
     *   ② **失败也回 200**：`ok=false` + `reason` 是**结果**，不是服务端故障；
     *      管理台据此显示"失败 + 为什么"，而不是弹一个 500 让人以为后端坏了。
     *   ③ **不受 `ai.enabled` 总开关影响**：这是诊断动作 ——
     *      若必须先打开总开关才能测，顺序就反了（先上线再验证）。
     *      ⚠ 其余安全闸一个不少：https 强制 + 密钥必须能解析出来。
     */
    r.post("/api/v1/admin/ai/models/:id/test", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageAi)
        let id = parseInt64Or(ctx.paramOr("id", ""), 0)
        if (id <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "模型配置 id 必须是正整数")
        }
        let now = hNowEpoch()
        /*
         * ⚠ 从**库/缓存拿行**（而不是从请求体拿一份临时配置）：
         *   要测的必须是"保存下来的那条"，否则"页面上的值"与"实际生效的值"
         *   会再次分叉 —— 而分叉正是这条路要消除的东西。
         */
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
    /*
     * ★ 2026-10-15（改进 7「AI 评测与排障闭环」）。
     *
     * ── 它解决什么问题 ────────────────────────────────────────────────────
     *   `triage_stat` 从 P4 起就在**写**（source / reason_code / red_flag / 科室），
     *   但**从来没有读的出口**：想知道"这周模型调用占比 / 降级率 / 耗时分布"，
     *   只能登库敲 SQL。⇒ 这里补上读的一侧，让"分诊质量"变成可查的聚合。
     *
     * ── 权限为什么是 `ManageAi` 而不是新动作 ──────────────────────────────
     *   与 `/admin/ai/` 下的其余端点**同一道闸门**（settings / prompts / tools /
     *   models 都是 `Action.ManageAi`）。这一屏的内容是"模型与模板的运行效果"，
     *   属于 AI 配置的责任范围 ⇒ 复用既有动作，不新造权限
     *   （新动作要么有第二个用处、要么复用，见 P4-HANDOFF 纪律）。
     *
     * ── 参数与边界 ────────────────────────────────────────────────────────
     *   · `group_by`：**白名单**（source / reason_code / model_name），
     *     非法值一律 400 —— 列名要拼进 SQL，绝不"回退默认值继续查"；
     *   · `from` / `to`：epoch 秒，缺省 = 最近 24 小时；`from > to` 直接 400
     *     （**不自动交换**：交换会把调用方的参数错误掩盖成一次"成功"的查询）；
     *   · `limit`：抽样上限（默认 5000，上限 20000）—— 分位数是**在内存里算**的
     *     （MySQL 无 percentile 函数），必须有上限；被截断时 `truncated = true`，
     *     调用方必须在界面上说出来，否则"命中率下降"的结论会失去依据；
     *   · `group_limit`：返回的分组数上限（默认 20，上限 100）。
     *
     * ⚠ 隐私：响应里**不含**主诉原文、患者/医生 id、手机号（见 `triageStatWindowJson`
     *   顶部的合规红线）。本表根本就没存主诉，是**机制性**保证而不是"记得过滤"。
     */
    r.get("/api/v1/admin/ai/triage-stats", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageAi)
        let groupBy = ctx.queryParamOr("group_by", "source").trimAscii()
        if (!triageStatGroupByOk(groupBy)) {
            throw apiErrorMsg("VALIDATION_FAILED",
                              "group_by 只支持 source、reason_code、model_name")
        }
        let now = hNowEpoch()
        /*
         * ★ 2026-10-16（复核提示项）：`from`/`to` **先判"给的到底是不是整数"**。
         *
         * 原来直接 `parseInt64Or(..., 0)` 再"`<= 0` 就用默认值"：
         * `?from=abc` 与 `?from=-1` 于是**静默变成**"最近 24 小时"，
         * 看板会把一个拼错的参数当成一次成功的查询 —— 数字是另一个窗口的，
         * 而调用者以为自己查的是他指定的区间（静默错误比 400 难发现得多）。
         * ⇒ 给了值就必须是合法的非负整数；没给（空串）才用默认窗口。
         */
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
        /*
         * ⚠ 窗口跨度上限：`to` 可以填到未来（无妨），但跨度不设上限时
         *   "一次请求扫全表"就只是少打几个字的事（采样上限虽在，扫表本身就够贵）。
         *   366 天是一个"再宽就该做预聚合表"的界，不是技术极限。
         */
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
    /*
     * ★ 2026-10-15（改进 7）。
     *
     *   用途：患者/运营报"这条主诉分诊得不对"时，凭 `X-Request-Id` 把**那一次**
     *   的链路捞出来对质：走了模型还是规则、降级原因、模型与模板版本、耗时、
     *   有没有用知识库、命中哪几篇 `kb_doc`。
     *
     * ── 为什么返回**数组**（而不是一个对象）────────────────────────────────
     *   `request_id` 来自客户端请求头（`X-Request-Id`），**没有唯一约束** ——
     *   同一个 id 被复用（或伪造）时会有多行。⇒ 如实体贴"这次 id 对应的所有行"，
     *   而不是假装它唯一、丢掉其余行。
     *
     * ── 为什么空数组是 **200** 而不是 404 ────────────────────────────────
     *   "没有遥测行"是一个**如实的答案**：请求可能在分诊落库之前就被拦下
     *   （限流、参数校验失败、鉴权失败），那些路径**本来就不写统计**。
     *   回 404 会把"没记录"说成"id 不存在"，让排障的人去查一个并不存在的错误。
     *   ⇒ 200 + `count: 0`，并在文档里把这条口径写清。
     *
     * ⚠ 隐私同 `triageCallJson`：只有结论码/科室名/文档 id，没有主诉原文与个人信息。
     *   也**不要**把这个端点当成"按 requestId 查患者"的入口 —— 它查的是遥测，
     *   而遥测按设计就没有患者标识。
     */
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
        /* 口径显式回显：新→旧（`id DESC`）。调用方不必去猜顺序。 */
        o.put("order", JsonString("id_desc"))
        sendOk(ctx, o)
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
        // 从已授权请求开始计增强额度：全文规则/检索已用时也扣除模型等待。
        // 同步SQL/规则扫描不可由该截止中断，不能把它当作整体HTTP硬截止。
        let enhancementDeadline = DateTime.now().toUnixTimeStamp().toMilliseconds() +
                                  TRIAGE_ENHANCEMENT_BUDGET_MS
        let complaint = match (bodyStr(ctx, "chief_complaint")) {
            case Some(v) => v
            case None => throw apiErrorMsg("VALIDATION_FAILED", "缺少必填字段 chief_complaint")
        }
        /*
         * 长度上限：主诉是**用户输入**，直接进词表匹配与日志。
         * 不设上限等于让一个请求把日志刷爆（也顺带保护分词循环）。
         * 完整主诉先过危急检测（保留否定上下文）；仅常规检索和模型解释输入
         * 截断。请求体另有 bodyLimit，不能把尾部危急词静默删除。
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
        let v = triageComplaint(triage, text, today, redFlagComplaint: Some(complaint))
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
        // 同步SQL不能由Future中断：RAG在当前请求取完，worker只持有网络配置和Prompt。
        // 已用规则/检索/RAG时间扣除，预算不足直接规则降级；模型等待仅用剩余额度。
        let ragHits = triageRagHits(kb, text, v)
        aiEnhanceTriage(v, text, aiSettings, hNowEpoch(), ragHits: ragHits,
                        deadlineMs: enhancementDeadline)
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
         *
         * ★ 2026-10-15（改进 7）：除结论字段外，再落一批**调用事实**
         *   （`ctx._id` 请求编号 / 模型 id+名 / 配置版本 / 耗时 / 降级码 / 是否用知识库）。
         *   ⚠ 它们全部来自 `v` 上的遥测字段（由 `aiEnhanceTriage` 在**调用当时**记下），
         *     而**不是**在这里回头去查一次配置 —— 配置是"改了就生效（零重启）"的，
         *     回头查会把"A 模型的结果"记成"B 模型"（这是排障日志最不能容忍的失真）。
         *   ⚠ 唯一的例外是 `promptRevision`：它是**配置库**的属性，只能现查
         *     （`aiSetting.revision` 一句 `SELECT MAX(revision)`，表极小、有主键）。
         *     代价是每请求一次点查；换来的是"这条结果产生于哪一版配置"可追溯。
         *   ⚠⚠ `ctx._id` 同样**不是**患者输入（框架中间件填的请求编号），
         *     与"绝不落主诉原文"这条红线无关 —— 红线仍然由 `record()` 的签名守着。
         */
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
        /*
         * ★★ 2026-10-15（改进 7）：分诊响应体里回 `request_id`（+ `server_time`，见 `putTrace`）。
         *
         * 为什么必须有（写 live 检查时被自己的用例红出来的）：
         *   `record()` 把 `ctx._id` 落进了 `triage_stat`，排障端点又**只能按它查**，
         *   于是"这一次分诊"的编号就是唯一的入口。可原来的分诊响应体里**没有**它 ——
         *   患者端只发主诉、不带 `X-Request-Id` 头时（默认就是如此），这个编号只存在于
         *   服务端日志与统计表里：患者说"这条分诊不对"，运营**无从取号**，
         *   改进 7 的排障闭环就在第一步断了。
         *   ⇒ 与挂号（`appointmentJson` 里的 `putTrace`）保持同一口径：编号回到调用方手里。
         *
         * ⚠ 纯增量：两个字段都在 `data` 里、不改变任何既有字段含义（老客户端可忽略），
         *   且**不引入**主诉原文或任何个人信息 —— 编号是框架中间件填的请求号。
         */
        let triageOut = triageJson(v, truncated)
        putTrace(ctx, triageOut)
        sendOk(ctx, triageOut)
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
        let bookableOnly = match (p.role) {
            case Patient => true
            case _ => false
        }
        let list = repo.listSchedules(departmentId: depId, workDate: date, limit: lim,
                                      bookableOnly: bookableOnly)
        /*
         * ★ 2026-10-12：补 `department_name` / `doctor_name` / `doctor_title` 与 `version`。
         *
         * 为什么名称必须**服务端**给（而不是客户端拿 id 自己拼）：
         *   患者端此前只能显示「科室 #810003 · 医生 #900003」——
         *   因为库里的名字在 `department` / `doctor` 表，而**患者角色读不到**
         *   （那两个接口挂在 `/api/v1/admin` 下且仅管理员）。
         *   ⇒ 结果:同一个科室，挂号页显示「P4测试科3」、就诊列表显示「#810003」。
         *   这不是美观问题：患者**无法核对**自己挂的科与档案里的科是不是同一个。
         *
         * ⚠ `version` 一并给：客户端做"号源已变化"提示要用它
         *   （`/schedules/:id` 早就回了，列表却不给 —— 同一份数据两种形状）。
         * ⚠ 名称解析走 `nameIndexOf`（**一次读全表**），不是每行查一次库：
         *   `/schedules` 一次返回几十行，逐行查就是几十次往返（N+1）。
         */
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
        /*
         * ★ 2026-10-12：每条挂号补科室名/医生名/职称（理由同 `/schedules`）。
         *   患者端首页「下一次就诊」与「我的就诊」都靠这三个字段，
         *   此前只有 id ⇒ 界面只能显示「科室 #810003 · 医生 #900003」。
         */
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
    /*
     * ★ 2026-10-14（改进 4「让患者看懂操作结果」的服务端主件）：
     *   为什么需要它：挂号的幂等键 `client_token` 是**客户端生成**的。网络中断时
     *   客户端根本不知道"那一次提交到底成没成"——它手里只有 token。此前它唯一的
     *   补救手段是**再提交一次**（靠幂等键回放），但那把"查询"和"下单"混在了一起：
     *     · 若上一次其实没发出去，重提交会**真的建一张单**（用户以为只是"再确认一次"）；
     *     · 若上一次发出去了，重提交拿到回放的单，界面显示"预约成功"，
     *       但客户端**无法区分**"这是我刚才那次"还是"这是上一次的结果"。
     *   ⇒ 给一条**只读**通道：拿 token 问服务端"这个 token 现在对应哪张单"。
     *     客户端于是可以给出诚实的两个动作：「查询结果」（本端点）与
     *     「继续确认同一预约」（继续用**同一个** token 提交）。
     *
     * ⚠ 归属：`patientId` 一律取自**令牌**，并且与 token 组合查询
     *   （`findAppointmentByToken` 的 WHERE 就是 `(patient_id, client_token)`）——
     *   别人即使猜到 token，也只会得到"没有这张单"，不会泄露他人挂号。
     *   与 `/api/v1/appointments` 同源的越权口径（见其注释）。
     *
     * ⚠ 语义边界（必须说清，否则客户端会误以为它"永远不会 404"）：
     *   `findAppointmentByToken` **只认 `status <> 'cancelled'`**，因为退号会把
     *   `client_token` 置 NULL（`domain_booking.cj` 的 cancel 注释：退号即释放
     *   幂等键，好让同一个 token 能重挂）。所以本端点返回 404 有两种含义：
     *   ① 那次提交**没有落库**；② 那次落库了，但单已被退号释放。
     *   这两种情况对客户端的**动作是一样的**（可以放心用同一个 token 重新提交），
     *   所以不额外区分——多一个状态码只会让三端多一处分支。
     *   响应体里带 `status`，客户端拿到 200 时按订单状态展示即可。
     */
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
        /*
         * 形状校验放在查库之前：空串必然查不到（`findAppointmentByToken` 直接
         * 返回 None），而 **> 64 字符**是列定义的上限（`client_token VARCHAR(64)`）——
         * 显式 400 比让客户端拿着一个"永远 404"的 token 反复重试要诚实得多，
         * 后者会表现成"我的预约一直查不到"，而真因是客户端自己生成时没截断。
         */
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
                    /*
                     * ★ 与挂号响应对齐（改进 1）：同一条预约经不同端点回出时，
                     *   "这次就诊有没有绑上患者的自述"这个字段必须同样存在，
                     *   否则客户端"提交未确认 → 反查"这条路径上会突然少一个字段
                     *   （而它恰恰是用来跟原响应比对的）。
                     */
                    sendOk(ctx, bookingJsonFull(repo, found, nameIndexOf(dept, doc), ctx,
                        previsitBound: previsit.findByAppointment(found.appointmentId,
                                                                  found.patientId).isSome()))
                /*
                 * 查得到 id 却读不出明细：**并发下的真实窗口**（另一个请求刚把它退号/
                 * 删掉了）。对外仍按"这张单不存在"回答——客户端据此走"重新提交"，
                 * 这比返回 500 让它卡在"未知状态"要好。
                 */
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
        /*
         * ★ 2026-10-12：单个排班也补名称 —— `/schedules`（列表）与这里
         *   返回**同一份数据**，形状必须一致（否则客户端要为同一实体的两个端点
         *   写两套解析，且"列表里有名字、详情里没有"这种差异迟早变成 bug）。
         */
        nameIndexOf(dept, doc).putInto(o, s.departmentId, s.doctorId)
        sendOk(ctx, o)
    })

    /* ---------- POST /api/v1/appointments —— 挂号（仅患者）---------- */
    r.post("/api/v1/appointments", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.Book)
        let scheduleId = requireInt(ctx, "schedule_id")
        let clientToken = requireStr(ctx, "client_token")
        /*
         * ★ 形状校验（2026-10-17 补）：与 `GET /appointments/by-token/:token` 的
         *   `:2472-2478` **同一口径** —— 那边的注释把理由写全了（列是 VARCHAR(64)），
         *   但这边漏了同样的检查，于是"同一个幂等键，查得到 400、写进去 500"。
         *
         * ⚠ 不检查的后果是 **500 而不是 400**：超长值直接撞 MySQL 的
         *   "Data too long for column 'client_token'"，`hospitalErrorHandler`
         *   把它归到"未预期异常" ⇒ `INTERNAL` + 500，客户端看到的是一句
         *   "服务器内部错误"，而真因是它自己生成令牌时没截断 —— 与
         *   `http_app.cj:735-736` 记的那次"超长头撞 Data too long"是同一类。
         */
        if (clientToken.size == 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "缺少幂等键 client_token")
        }
        if (clientToken.size > 64) {
            throw apiErrorMsg("VALIDATION_FAILED",
                              "幂等键最长 64 个字符（收到 ${clientToken.size} 个）——客户端生成时应自行截断")
        }
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
        /*
         * ★ 可选：把这张单和患者的预问诊单**在服务端**绑上（2026-10-14 改进 1）。
         *
         * 为什么要它：此前"这次预问诊属于哪次挂号"只存在于客户端本机的
         * SessionStore 里（换设备就断、医生端也无从知道）。绑定之后，
         * 医生端可以从挂号单反查出患者自述（`GET /doctor/visits/:id/previsit`）。
         *
         * ⚠ 绑定**失败不影响挂号**：号已经挂上了，为了一个"自述挂不上"的
         *   记账问题去回滚挂号，等于让患者白跑一趟。失败只体现在响应字段里
         *   （`previsit_bound: false`），由客户端提示"预问诊未关联本次预约"。
         *   失败的真实场景：会话不属于该患者、或已绑到**另一张**单
         *   （`bindAppointment` 里 `appointment_id = 0 OR = ?` 那条纪律，
         *   防止一次误传把自述挂到别人的就诊上）。
         * ⚠ 幂等重放（`AlreadyBooked`）也会走到这里：重复绑定同一张单是幂等的
         *   （返回 true），所以重试不会把 true 变成 false。
         */
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
        /*
         * ★★ 2026-10-17 增（复验报告 S16）：**区分"本次真的退了"与"本来就已经退了"**。
         *
         * 修复前：对一张已取消的单重复退号，响应里的 `slot_restored` 仍是落库的真实值
         * （`true`）—— 字段本身没错（号**确实**已经回到池子），但客户端会把它读成
         * "这一次又把号还了一次"，于是重复弹一次"号源已归还"。运维看日志也分不清
         * 到底发生了几次归还。
         *
         * 现在多带一个 `already_cancelled`：**这一调用之前**单是否已是取消态。
         *   - `false` + `slot_restored:true`  ⇒ 本次退号成功，且号已归还
         *   - `true`  + `slot_restored:true`  ⇒ 本次是幂等重放，号**之前就**归还过了
         *   - `true`/`false` + `slot_restored:false` ⇒ 号源未归还，需人工处理（见 warning）
         *
         * ⚠ 口径来自**取消前**那份快照（`appt`，上面为鉴权读的），不是取消后重读的
         *   那一份 —— 后者状态永远是 `cancelled`，问了也答不出"之前是什么"。
         */
        let wasCancelled = appt.status == "cancelled"
        match (repo.cancel(id, hNowEpoch())) {
            /*
             * ★ 2026-10-12：退号响应同样带 `remain_num`。
             *   理由与挂号同源，但**更关键**：退号的整个意义就是"把号还回去"，
             *   客户端要立刻显示归还后的余号（此前它只能自己再发一次
             *   `/schedules` 查询，而实测那次刷新没做 ⇒ 界面一直显示旧数字）。
             */
            case Cancelled =>
                /*
                 * ⚠ 必须**取消后重读**，不能用上面那个 appt 快照。
                 *   踩过的坑：appt 是取消**之前**读的，status 还是 "booked"，
                 *   直接回它会让客户端看到"退号成功但状态仍是已挂号"——
                 *   自相矛盾的响应比不返回还糟。
                 */
                match (repo.findAppointment(id)) {
                    case Some(after) =>
                        let o = bookingJsonFull(repo, after, nameIndexOf(dept, doc), ctx)
                        o.put("already_cancelled", JsonBool(wasCancelled))
                        sendOk(ctx, o)
                    case None => throw apiError("APPOINTMENT_NOT_FOUND")
                }
            case SlotNotRestored =>
                // ★ 单已取消但号源未归还：HTTP 上算成功（单确实退了），
                //   但带一个显式标记让客户端提示"需人工处理"，绝不谎报失败。
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
            /*
             * ★ 2026-10-12（代码检查报告第 1 条）：单**存在**，但当前状态不允许退号。
             *
             * ⚠ 与外层 `canCancel` 的 403 是两件事，不能合并：
             *   403 = "这张单不是你的"（归属/角色问题，换个人登录就能退）；
             *   409 = "这张单是你的，但它现在不能退"（业务状态问题，谁登录都一样）。
             * 文案带上中文状态名（`visitStatusLabel`，与流转表同处维护）——
             * 患者据此能分清该去就诊（接诊中）、还是这单已经结束了（已完成/已退号/爽约）。
             */
            case NotCancellable(st) =>
                throw apiErrorMsg("APPOINTMENT_NOT_CANCELLABLE",
                                  "该挂号单当前状态为「" + visitStatusLabel(st) + "」，不能退号")
            /*
             * ★ 2026-10-17 增：状态没问题（还是 `booked`），但**病历已定稿**。
             *
             * 与上面 `NotCancellable` 分开的理由就是"处置不同"：
             *   `NotCancellable` = 这单已经走到别的状态了 → 刷新看看；
             *   `RecordLocked`   = 病历定稿了 → **刷新永远没用**，必须先把这份病历
             *                      定稿状态处理掉（管理员走病历修订/解锁），或直接就诊。
             * 压成同一句话会让使用者在一个走不通的位置反复重试。
             * ⚠ 用 409 而不是 403：这是**业务状态**问题，谁登录都一样（与上面同口径）。
             */
            case RecordLocked =>
                throw apiErrorMsg("APPOINTMENT_RECORD_LOCKED",
                                  "该挂号单的病历已定稿（锁定后不可再修改），不能退号；" +
                                  "如确需退号，请先联系管理员处理该次病历")
        }
    })

    /* ---------- POST /api/v1/admin/schedules —— 建排班（仅管理员）---------- */
    /*
     * P1 需要有办法造出真实号源才能测"扣号/退号/并发"。
     * 正式的排班维护界面属 P4（运营看板），这里先给一个**受认证 + 管理员角色
     * 双重保护**的最小写入接口。
     *
     * ⚠ 更正（2026-10-14，第三方复查 B2）：这里原先写"不开 `--dev-auth` 时它和业务接口
     *   一样直接 401"——**不对**。`--dev-auth` 只多给一条本地测试用的 `X-Role` 捷径；
     *   不开它时，带**真实管理员令牌**的请求照样能过（这正是管理台在用的方式，
     *   生产环境就是不开 `--dev-auth` 的）。把"没有捷径"说成"进不来"，
     *   会让人以为生产环境没有建排班的口子，从而去开 `--dev-auth`——那才是真危险。
     */
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
        /*
         * ★ 2026-10-17 补：同一医生 + 同一天 + 同一时段**只能有一条排班**。
         *
         * 实测缺陷（修复前）：连发两次完全相同的请求得到**两条 201**，
         *   `total_num` 各 20 ⇒ 同医生同时段号源合计 40（`schedule` 表上
         *   `KEY idx_schedule_doctor_date` 是**普通索引**，拦不住）。
         *   号源翻倍 = 同一个医生在同一时段被排了两份工，管理台的放号数/余量再也对不上。
         *
         * ⚠ 报 **409 并带上已存在的那条 id**：调用方真正要做的是"去改那一条"
         *   （`PUT /admin/schedules/:id`），只回一句"重复了"它还是不知道该改谁。
         * ⚠ 不用 400：请求本身没写错，是**资源已存在**（同 `USER_EXISTS` 的口径）。
         * ⚠ 这里是"先查后插"，**残留一个并发窗口**（两个同时到达的完全相同的 POST
         *   仍可能各插一条）。这次刻意**不用数据库唯一键兜**：试过
         *   `UNIQUE KEY (doctor_id, work_date, period)`，代价是 `accept` 红 2 项
         *   （夹具 AC-P4-7/8 刻意让多个 seed 共用一个医生、同一天同一时段）
         *   且与"排班可顺延（改 work_date）"冲突（顺延到已有时段会撞库报错）。
         *   详见 `schema.cj` 的 schedule DDL 注释与迁移 ⑮。
         *   ⇒ 如实登记：这个窗口要靠"管理台不重复点、失败后刷新"兜，
         *     而不是假装它不存在。
         */
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
    /*
     * ★★ 为什么必须有这一条（2026-10-14 补的真实缺口）：
     *   在此之前**只有** `POST /admin/schedules`（建），没有任何改的入口 ⇒
     *   "放号数写错了"或"这位医生今天停诊"只能**新开一条**排班，
     *   而老的那条连同已经约出去的号一起留在那里 —— 患者端照样能约到它。
     *   管理台「排班号源」页若只有"新增"，等于把使用者推向这个坑。
     *
     * ⚠ 语义是 **PATCH**：请求体里没给的字段保持原值（同 AI 模型配置那条）。
     * ⚠ `version` **必填**（乐观锁的读基准）：它由 `GET /schedules/:id` 返回。
     *   不给就无从判断"你看到的是不是最新的那一版"—— 那正是并发编辑要防的事。
     *   缺 `version` ⇒ 400（而不是"默认 0"：默认 0 会让**每一次**编辑都变成冲突，
     *   使用者只会看到"总是失败"而不知道少传了字段）。
     */
    r.put("/api/v1/admin/schedules/:id", { ctx: Context, _: () -> Unit =>
        let p = principalOf(ctx, gate, auth)
        requireCan(p.role, Action.ManageSchedule)
        let sid = parseInt64Or(ctx.paramOr("id", ""), 0)
        if (sid <= 0) {
            throw apiErrorMsg("VALIDATION_FAILED", "排班 id 必须是正整数")
        }
        let version = requireInt(ctx, "version")
        /*
         * ⚠ 两个可选字段都**不设默认**：缺省 = "不改这一项"。
         *   "没给 total_num 却按 0 处理"会把排班改成 0 张（等于停号），
         *   而调用方只是想改 enabled —— 这是我们必须避免的一类静默破坏。
         */
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
            /*
             * ⚠ 409 的信息量必须够：把**当前**的 version 一起回，
             *   否则前端只能整页重刷（而重刷会丢掉使用者刚填的数字）。
             */
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
        /* `booked` = 已约张数（= total − remain）—— 放号数不能改到它以下。 */
        o.put("booked", JsonInt(res.booked))
        o.put("version", JsonInt(res.version))
        o.put("enabled", JsonBool(res.enabled))
        sendOk(ctx, o)
    })
    /* ===================== P4：病历 + 接诊队列 + 运营看板 ===================== */
    /*
     * ⚠ 定义在 `http_p4.cj`（那一块有自己的纪律要写清：病历锁定语义、
     *   接诊状态机、"看板只出聚合"）。这里只**注册** ——
     *   于是"有哪些端点"仍然只有一处可数（便于 doc-counts 对账）。
     */
    registerP4Routes(r, auth, gate, repo, previsit, emr, visit, dash, aiSettings, dept, doc)

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
    /*
     * ★ 2026-10-12：公告域（患者可读 + 管理员维护）。
     * ⚠ 同样登记在这里：`doc-counts.ps1` 的 `$regFiles` 已加入 `http_notice.cj`
     *   —— 新增**文件**必须同时更新那个清单，否则端点总数会静默少算
     *   （本仓已因"计数脚本漏扫文件"踩过一次）。
     */
    registerNoticeRoutes(r, auth, gate, notices)

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
                             aiSettings: AiSettingsRepo, aiModels: AiModelRepo, prompts: PromptRepo,
                             emr: MedicalRecordRepo, visit: VisitRepo,
                             dash: DashboardRepo, triageStat: TriageStatRepo,
                             dept: DepartmentRepo, doc: DoctorRepo, kb: KbRepo,
                             notices: NoticeRepo, adminWebDir!: String = "",
                             // ★ 2026-10-17（S4 修）：`/health` 的库探针由**调用方**注入 ——
                             //   本函数刻意不持有 db（见上方注释），但 health 要问"库还通吗"，
                             //   所以让持有 db 的那一侧（main.cj）把探针传进来，与本函数
                             //   "谁持有 db、谁决定暴露什么"的既有约定一致。
                             dbProbe!: ?DbProbe): QingZhouApp {
    let router = buildHospitalRouter(repo, auth, gate, triage, previsit, aiSettings, aiModels, prompts,
                                     emr, visit, dash, triageStat, dept, doc, kb, notices,
                                     dbProbe: dbProbe)
    /*
     * ★★ 2026-10-14（第三方复查 D6 修）：让 router **透传未命中的路径**，
     * 改由本函数末尾自己关的中间件回统一信封（原因见那里的注释）。
     * 必须在这里就置位（早于 `router.middleware()` 的构造）。
     */
    router.passOnNotFound = true
    /*
     * ★★ 2026-10-17（S14 修）：路由器**直接写出**的 404/405 也必须走本应用的三段式信封。
     *
     * 修的是什么（实测抓到的契约违反）：`router.cj` 原来硬编码
     *   `{"error":"Method Not Allowed","allow":"GET"}` / `{"error":"Not Found","path":…}`。
     *   客户端 `HttpClient.parseResponse` 严格读 `ok` / `error.code`，遇到这种平铺体
     *   只能报"响应格式非法"，把真因（方法不匹配 / 路径不存在）盖掉。
     * ⚠ 这两条响应**不经过** `app.onError`（路由器自己写完就返回），所以只能在这里
     *   把钩子换掉 —— 业务层里 `sendError(...)` 的正确写法对它无效。
     * ⚠ code 用已登记的 `ROUTE_NOT_FOUND` / `METHOD_NOT_ALLOWED`（见 http_common.cj
     *   的错误码表），客户端按 code 分支即可，不必看 status。
     */
    router.errorBody = { status: Int64, msg: String =>
        let code = if (status == 405) { "METHOD_NOT_ALLOWED" } else { "ROUTE_NOT_FOUND" }
        errorEnvelopeString(code, msg, None)
    }
    var app = QingZhouApp()
        .use(requestId())
        .use(logger())
        // bodyLimit 必须排在 bodyParser **之前**（外层）：框架的 bodyParser 是
        // "先把整个 body 读进内存、再比 maxBytes"，只有抢在它前面按 Content-Length
        // 拦，大 body 才进不了内存。
        // ⚠ 搬迁前的 `bodyLimit()` 是**搬迁前自己写的**（搬迁前 limits.cj:83），
        //   不在框架里；这里用框架原生的 `contentLengthLimit(maxBytes)`（bodyparser.cj:168）。
        //   上限 64 KiB —— 与搬迁前 MAX_BODY_BYTES 同口径（limits.cj:47）。
        // ★ 2026-10-17（S14 修）：不能再用便利函数 `contentLengthLimit(64 * 1024)` ——
        //   它走框架**默认** onError，413 会回 `{"code":413,...}` 平壳（实测残留）。
        //   改成传自己组好的 opts，两处限流出口（外层 64 KiB / 内层 1 MiB）共用同一个信封。
        .use(contentLengthLimit(hospitalContentLengthLimitOptions(64 * 1024)))
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
         *
         * ★★ 2026-10-17（S14 修）：必须传 opts 把 `onError` 换成统一信封。
         *   框架默认的 `defaultBodyParserError` 写的是 `{"code":400,"message":
         *   "Invalid JSON body","data":null}` —— 没有 `ok`、没有 `error` 对象，
         *   客户端按三段式信封解析必然解不开。而 body parser 在**进入 handler 之前**
         *   就回应并短路，所以业务层里 `bodyObj()` 那套正确写法根本执行不到：
         *   **只能在这里换**，改 handler 没用。
         */
        .use(bodyParser(hospitalBodyParserOptions()))
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
    /*
     * ★ 管理台静态资源（2026-10-14）：与 API **同源同端口**挂在 `/admin/` 下。
     *
     * 为什么必须排在 `router.middleware()` **之前**：中间件按注册顺序进入，
     * 静态中间件要用前缀守卫"只认领 /admin/ 下面的路径、其余 `.next()` 透传"，
     * 只有先经过它，`/api/...` 才仍然由路由处理。反过来挂（在路由之后）
     * 就永远轮不到它 —— 每个静态请求都会先撞上路由的 404。
     *
     * ⚠ 与 `--dev-auth` / 令牌鉴权的关系：**静态页面本身不鉴权**
     *   （否则浏览器第一次访问就得先登录，而这只是"取一份 JS/HTML"）。
     *   真正的数据访问一律走 `/api/v1/admin/…`，那是**逐条**校验令牌与角色的
     *   —— 也就是说"看得到页面"不等于"读得到数据"，这是刻意的：
     *   一个没有登录的人打开 `/admin/` 只会看到一个登录框。
     *
     * ⚠ `enableCache = false`：框架默认把文件字节在**进程生命周期内**缓存
     *   （static.cj:57-62 明说"开发期请关掉，否则要重启才能看到改动"）。
     *   管理台是要反复改的界面，"改了没生效"这种错觉的排查成本远高于
     *   每次请求多读一次磁盘（这里的文件总量是几十 KB 量级）。
     *
     * ⚠ `spaFallback = false`（而不是 true）——**2026-10-14 实测后改的口径**：
     *   本管理台的前端路由是**哈希路由**（`#/ai-models`），所以"深层链接"永远
     *   不会出现在 `ctx.path()` 里，SPA 回退**没有用得上的场景**。
     *   而开着它有两个实实在在的坏处：
     *     ① 打错的静态路径（例如 `js/page.js` 少个 s）会回 200 + HTML，
     *        浏览器随后报 "Unexpected token '<'" —— 真因（路径写错）被这层
     *        回退藏起来了；
     *     ② 让"这个 URL 到底存不存在"在管理台上无法用状态码回答。
     *   关掉之后：`/admin/` 200、`/admin/js/app.js` 200、
     *   `/admin/whatever` 404（JSON 体，与 API 的 404 同形状）。
     *
     * ⚠ 前缀必须写 **"/admin"（不带尾斜杠）**，**不能**写 "/admin/"。
     *   框架的前缀守卫（static.cj:138-153）在被认领之后还要求
     *   "余部要么为空、要么以 '/' 开头"：
     *     · 前缀 "/admin"  → `/admin/js/app.js` 的余部是 "/js/app.js" ✓（可用）
     *     · 前缀 "/admin/" → 余部变成 "js/app.js"，**不**以 '/' 开头 ⇒ `next()`
     *       ⇒ 落到路由上 404 —— 即"除 `/admin/` 首页之外**所有资源都 404**"。
     *       这是 2026-10-14 实测到的（`/admin/js/pages.js` 回的是路由的
     *       `{"error":"Not Found","path":…}`，而不是静态层的 404）。
     *   代价：前缀不带尾斜杠时，`/admin`（余部为空）会被静态层**自己**认领，
     *   按"目录 ⇒ indexFile"回一份 index.html 200 ⇒ 早先那条
     *   `GET /admin → 302 /admin/` 的路由**永远轮不到**，已删除（死代码）。
     *   于是前端**必须用绝对路径引用资源**（`/admin/css/style.css`…）：
     *   否则浏览器停在 `/admin`（无尾斜杠）时会把 `css/style.css` 解析成
     *   `/css/style.css` ⇒ 静态层不认领 ⇒ 404。这一条由 index.html 守住。
     */
    if (adminWebDir.size > 0) {
        let staticOpts = StaticOptions("/admin")
        staticOpts.indexFile = "index.html"
        staticOpts.spaFallback = false
        /*
         * ★★ 2026-10-17（S14 修，附带）：静态层自己的 404/403/416 也统一信封。
         *
         * 框架把这三条响应体做成了**可配项**（static.cj:51 `notFoundBody`、
         *   :53 `forbiddenBody`，第三条 `rangeNotSatisfiableBody` 为本次新增），
         *   所以不需要 fork 框架 —— 这也替换掉了下面原来那句
         *   "那条路径只被浏览器访问……故不为此 fork 框架"的边界记录：
         *   该 404 早已进了机器可读契约
         *   `contract/examples/error-static-not-found-404.json`，
         *   而管理台自己的 JS 也是按 `error.message` 取错误文案的（admin-web/js/api.js），
         *   拿到平铺的 `{"error":"Not Found"}` 只能显示成一句无意义的兜底。
         */
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
        /*
         * ★★ 2026-10-14（第三方复查 D6 修）：给**框架自己的 404** 套上本项目的统一信封。
         *
         * 原实现：router 未命中就直写 `{"error":"Not Found","path":"/nope"}`
         * （router.cj:196）—— **没有 `ok`、没有 `error.code`**。
         * 客户端按 `{ok,error:{code,message}}` 解析时这一条解不开，于是
         * "接口不存在"在前端表现成"响应解析异常"，排查方向直接跑偏。
         *
         * 改法：`passOnNotFound = true`（router.cj:88）让未命中**透传**到
         * 本中间件，由它回与其它接口同形状的 404（`ROUTE_NOT_FOUND`，
         * 登记在 http_common.cj:148 ⇒ 404）。中间件必须注册在
         * `router.middleware()` **之后**：洋葱模型里后注册的要在前者 `next()` 之后才轮到。
         *
         * ⚠ 边界（**2026-10-17 起作废**，只作历史）：本节写下时 `/admin` 下**静态文件**的 404
         *   还是框架静态层自己写的 `{"error":"Not Found"}`（`third_party` 里的 vendored 代码），
         *   当时理由是"那条路径只被浏览器访问、不经过 API 客户端，故不为此 fork 框架"。
         *   ⇒ 2026-10-17 改了结论：**仍不 fork 框架**，因为 `StaticOptions` 本来就有
         *   `notFoundBody` / `forbiddenBody`（本次再补 `rangeNotSatisfiableBody`），
         *   上面几行已把它们注成信封。
         */
        .use({ ctx: Context, _: () -> Unit =>
            sendError(ctx, apiErrorMsg("ROUTE_NOT_FOUND",
                                       "接口不存在：${ctx.method()} ${ctx.path()}"))
        })
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
