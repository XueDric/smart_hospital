/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 *
 * ===== domain_booking.cj —— 号源 / 挂号域（P0 核心）========================
 *
 * ★ 本文件是 ADR-0001 的落地实现：
 *   docs/adr/ADR-0001-号源与挂号独立MySQL路径.md
 *
 * 三条不可动摇的纪律（ADR §2.2）：
 *   ① 扣减走**参数化原子 UPDATE**：`remain_num = remain_num - 1` 是列表达式，
 *      所以走手写 SQL 文本；**不用** UpdateQuery.set()（它只接受值，不接受表达式，
 *      见 轻舟 dbquery.cj:492-556）。
 *   ② 成败**只看 exec() 返回的受影响行数**，绝不"先 SELECT 再 UPDATE"（那是竞态）。
 *   ③ UPDATE 与挂号单 INSERT 必须**同一个 withTransaction**。
 *
 * ⚠ 铁律（ADR §6）：withTransaction 内**绝不允许**出站网络调用（AI/HTTP）。
 *   本文件因此不 import 任何 AI/网络模块 —— 这是刻意的结构约束。
 *
 * 幂等（AC-3）用**双保险**，且**按患者隔离**：
 *   - 应用层：先按 `(patient_id, client_token)` 查**仍然有效**（status <> 'cancelled'）
 *     的既有挂号单，命中即返回（快路径）；
 *   - 数据库层：`uk_appointment_patient_token (patient_id, client_token)` 唯一索引兜底
 *     （并发下应用层可能都查不到，唯一索引让第二次 INSERT 直接失败，我们捕获后回读）。
 *   只做应用层检查在并发重复提交下是**不够的**。
 *
 * ⚠ 2026-10-07 修正（复查发现的跨患者泄露）：原实现按**全局** `client_token` 查 + 唯一索引，
 *   于是患者 B 提交患者 A 用过的 token 会命中 A 的单并原样返回（不扣号、不报错）。
 *   详见 `findAppointmentByToken` 的注释。
 * ⚠ 也**没有** `booking_idem` 登记表：它已于同日连同实现删除（ADR §7 第 7 条）——
 *   幂等的**唯一**保证就是上面这两层。
 *
 * ⚠ 仓颉语言约束（本项目已知坑，见 smart-hospital-project-brief.md §6.3）：
 *   **闭包不能捕获外部可变 `var`**（捕获的是值与 `let` 引用）。
 *   所以 withTransaction 里要回传的结果一律装在 class 的 `var` 字段里 ——
 *   见 TxSlot / TxOutcome，不要图省事去改外部 var。
 */

package qingzhou

/*
 * ⚠ 必须显式 import：列表查询（listAppointmentsByPatient / listSchedules）
 *   要用 ArrayList 收集结果。实测漏了它报 undeclared identifier 'ArrayList'。
 */
import std.collection.*

/*
 * ★ 挂号单的**列清单**（读模型的唯一出处，2026-10-15 增）。
 *
 * ⚠ 为什么抽成常量：它有 4 个使用点（`findAppointment` /
 *   `listAppointmentsByPatient` / `findAppointmentForDoctor` /
 *   `listAppointmentsByDoctor`），而 `fillFromRow` 的下标顺序**只按这一份**写。
 *   2026-10-15 加就诊时间线三列时要同时改 5 处 —— 复制粘贴式的列清单在
 *   "类型恰好兼容"时错位**不会报错**，只会把隔壁列的值读进来（本项目踩过）。
 *   📌 列清单与 `fillFromRow` 下标必须一起改；改这里就够，不必再找 4 个 SELECT。
 */
let APPT_COLS: String =
    "id, schedule_id, patient_id, doctor_id, department_id, " +
    "visit_date, period, seq_no, status, created_at, slot_restored, " +
    "arrived_at, started_at, finished_at "

/*
 * **瞬时错误**重试上限（ADR §6 调参项）。
 *
 * ⚠⚠ 语义在 2026-10-07 变了两次，注释必须跟着改（复查指出旧注释会误导）：
 *   rev.2（旧）："乐观锁冲突后的重试次数"。**这个说法已作废** ——
 *     扣号与归还都已**去掉 version 前置条件**，正常争抢下**一次就成功**，
 *     不存在"乐观锁冲突"这种失败。
 *   rev.3/4（现在）：它只管**真正的瞬时异常** —— 死锁、锁等待超时这类 InnoDB 报错
 *     （`book()` 的 catch 分支里重试，重试仍失败则**原样抛出，绝不吞**）。
 *
 * ⚠ 历史教训（留着，因为它解释了这个常量为什么不该被当成"性能旋钮"）：
 *   曾经为了压住"20 并发抢 8 个号只卖出 6 个"把 2 升到 3。
 *   但**根因不是重试不够**，而是乐观锁让并发请求互相作废 ——
 *   加大重试只是把失败换成更长的延迟，实测最穷工况下仍然少卖 15%~50%。
 *   真正的修法是去掉 version 条件（见 `tryDeductSlot`）。
 *
 * 🚫 所以：**不要**再靠调大它来"解决"高并发问题。
 *   若瞬时错误重试真的频繁耗尽，说明该加排队或改用方案 C（ADR §3）。
 */
public let MAX_BOOKING_RETRY: Int64 = 3

/*
 * 挂号专用重试预算（运行时可调）。
 *
 * ⚠ 2026-10-07 复查指出的遗留：它当初是为"抗乐观锁冲突"设的（比单测的 3 更宽），
 *   **现在这个理由已经不成立** —— 正常路径不再需要重试，它只对瞬时错误生效，
 *   因此与 `MAX_BOOKING_RETRY` **语义上重复**。
 *   保留是因为 HTTP 层调用点还在用它（改签名会牵动多处），
 *   但请注意：**它不是"HTTP 层可以多试几次"的意思**，别据此放宽任何断言。
 *   清理它需要在 HTTP 层一并改调用点，属 P1 收尾。
 */
public let HTTP_BOOKING_RETRY: Int64 = 6

/*
 * 患者可售排班的共同 SQL 谓词。alias 只由源码内的固定表名/别名传入；
 * 最后一个日期占位符由调用方绑定医院日期，不使用数据库时区。
 * EXISTS 不扩展结果列，避免挂号/退号曾出现的 JOIN 列名歧义。
 * CASE 先守住日期形状再做日历运算，历史脏日期不会进入日期转换。
 */
func bookingSchedulePredicate(alias: String): String {
    let s = alias + "."
    return s + "enabled = 1 AND " + s + "total_num > 0 AND " +
        s + "period IN ('AM', 'PM') AND " +
        "CASE WHEN " + s + "work_date REGEXP '^[1-9][0-9]{3}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$' " +
        "THEN CAST(SUBSTRING(" + s + "work_date, 9, 2) AS UNSIGNED) <= " +
        "DAY(LAST_DAY(CONCAT(SUBSTRING(" + s + "work_date, 1, 7), '-01'))) ELSE 0 END = 1 AND " +
        s + "work_date >= ? AND " +
        "EXISTS (SELECT 1 FROM department booking_dep WHERE booking_dep.id = " +
        s + "department_id AND booking_dep.enabled = 1) AND " +
        "EXISTS (SELECT 1 FROM doctor booking_doc WHERE booking_doc.id = " +
        s + "doctor_id AND booking_doc.enabled = 1 AND booking_doc.department_id = " + s + "department_id)"
}

/* ===================== 结果类型 ===================== */

/*
 * 挂号结果。
 * 用枚举而不是"抛异常/返回 null"来表达业务失败 —— 号源被抢走是**正常业务结果**，
 * 不是程序错误；把它做成异常会让调用方分不清"业务失败"与"数据库炸了"。
 */
public enum BookingOutcome {
    | Booked(Int64)                        // 成功，携带挂号单 id
    | AlreadyBooked(Int64)                 // 幂等命中，携带既有挂号单 id
    | SlotGone                             // 号源已放完（remain_num = 0；rev.3 起不存在"乐观锁冲突"这种失败）
    | ScheduleNotFound                     // 排班不存在或未启用
}

/*
 * 取消（退号）结果 —— **五态**，刻意不用 Bool。
 *
 * 理由见 `cancel()` 的注释：把"单子取消了"与"号还回去了"压进一个 bool，
 * 必然丢掉"单已取消但号未归还"这一真实存在的中间状态，导致对外**报错方向与事实相反**。
 *
 * ★ 2026-10-12 增第四态 `NotCancellable`：退号是**状态机的一条边**，只有 `booked` 能走
 *   （见 domain_emr.cj 的显式流转表）。原来这里没有"状态不允许"这一态，于是把
 *   `visiting` / `done` / `no_show` 也一并退掉并归还号源 —— 覆盖就诊结果、凭空多出号源。
 *   这一态与 `NotFound` 必须分开：**"这张单不存在"与"存在但不能退"是两件事**，
 *   对外一个是 404、一个是 409，客户端要提示的话术也完全不同。
 *
 * ★ 2026-10-17 增第五态 `RecordLocked`：状态仍是 `booked`（状态机允许 cancelled），
 *   但**病历已定稿**，退号会让"一份不可再改的病历"挂在一张已退号、号源已转卖的单上
 *   （该单再也不可能 finish）。它与 `NotCancellable` 必须分开：两者虽然都是 409，
 *   但处置完全不同 —— `NotCancellable` 是"这单已经走到别的状态了，刷新看看"，
 *   `RecordLocked` 是"**病历已定稿**，要退必须先由管理员处理病历（解锁/作废修订）"。
 *   把它们压成一句话，使用者会在一个**永远不会成功**的操作上反复刷新。
 */
public enum CancelOutcome {
    | Cancelled                            // 单已取消，且号源已归还（或本就无需归还）
    | SlotNotRestored                     // ★ 单**已取消**，但号源未归还（需运维介入）
    | NotCancellable(String)              // ★ 当前状态不允许退号（携带该状态，供上层如实说明）
    | RecordLocked                        // ★ 2026-10-17 增：病历已定稿，不允许退号
    | NotFound                            // 挂号单不存在
}

/*
 * 排班行（读模型）。
 * ⚠ 只读快照，**不参与写入决策** —— 版本号可能在你拿到它的一瞬间就变了。
 *   （rev.3 前它是乐观锁的读基准；现在扣号/归还都不带 version 条件，所以这里只是展示用。）
 */
public class ScheduleRow {
    public var id: Int64 = 0
    public var doctorId: Int64 = 0
    public var departmentId: Int64 = 0
    public var workDate: String = ""
    public var period: String = "AM"
    public var totalNum: Int64 = 0
    public var remainNum: Int64 = 0
    public var version: Int64 = 0
    public var enabled: Bool = true
}

/*
 * 改排班（号源）的结果（2026-10-14 新增：管理台「排班号源」页要能改放号数与停诊）。
 *
 * ⚠ 三种失败**必须分开**，因为它们对应三个不同的 HTTP 状态与三种不同的处置：
 *   · `notFound`   —— 排班不存在（404，别改了）；
 *   · `conflict`   —— 有人在你读到它之后改过（409，**刷新后用自己的新值重试**）；
 *   · `tooSmall`   —— 放号数改到"已约数"以下了（400，**这是业务错误**，
 *                     `booked` 是当时已约的张数；重试多少次都不会成功）。
 *   把它们混成一个"失败"会让界面只能显示"保存失败"，而使用者需要知道
 *   "是刷新一下重试，还是这条路本来就走不通"。
 */
public class ScheduleUpdateOutcome {
    public var ok: Bool = false
    public var notFound: Bool = false
    public var conflict: Bool = false
    public var tooSmall: Bool = false
    /* 失败时回显当时的真实数字（已约张数 / 放号数），供界面直接说明原因。 */
    public var booked: Int64 = 0
    public var totalNum: Int64 = 0
    public var remainNum: Int64 = 0
    public var version: Int64 = 0
    /* 成功后的启用状态（PATCH 里没给 `enabled` 时 = 原值）。 */
    public var enabled: Bool = true
}

/*
 * 挂号结果明细（供上层出参）。
 */
public class BookingResult {
    public var outcome: BookingOutcome = BookingOutcome.SlotGone
    public var appointmentId: Int64 = 0
    public var scheduleId: Int64 = 0
    public var patientId: Int64 = 0
    public var doctorId: Int64 = 0
    public var departmentId: Int64 = 0
    public var visitDate: String = ""      // ★ 就诊日快照
    public var period: String = "AM"
    public var seqNo: Int64 = 0
    public var status: String = "booked"
    public var createdAt: Int64 = 0
    /*
     * ★ 退号时号源是否已归还（默认 true）。
     * 幂等路径要靠它如实回报 —— 见 `cancel()` 的注释：
     * 否则第二次退号会把第一次的 `SlotNotRestored` 告警吞成 `Cancelled`。
     */
    public var slotRestored: Bool = true
    /*
     * ★ 就诊时间线三个时间戳（2026-10-15 增，改进 6）：到院 / 开始接诊 / 完成。
     *   0 = "这一步还没发生"（与 `createdAt` 同一口径：epoch 秒）。
     *   为什么回给上层：患者端与医生端都要显示"10:05 到院、10:40 开始"，
     *   而这两个数字**只能在库里**（前端自己记的换台设备就没了）。
     */
    public var arrivedAt: Int64 = 0
    public var startedAt: Int64 = 0
    public var finishedAt: Int64 = 0
}

/* ===================== 事务回传载体 ===================== */

/*
 * 事务内要回传的结果载体。
 *
 * 为什么需要它：**仓颉闭包不能捕获外部可变 `var`**（见文件头说明）。
 * 把结果写进一个由 `let` 捕获的对象的字段，是语言允许且语义明确的写法。
 */
class TxResult {
    var booked: Bool = false
    var newId: Int64 = 0
    var released: Bool = false
    var cancelDone: Bool = false
    /*
     * ★ 实际写进库的就诊序号（`MAX(seq_no)+1` 的结果）。
     * 必须回传出来供响应回填 —— 不能在回填时用 `countBooked()` 另算一遍：
     * 前者**不回收**已用过的号，后者统计"当前**有效**单数"，两个口径不同（实测差 1）。
     */
    var seqNo: Int64 = 0
}

/* ===================== 号源域仓储 ===================== */

/*
 * 挂号域仓储：**唯一**允许对 schedule / appointment 写直接 SQL 的地方。
 *
 * ADR-0001 §4.3「范围锁死」：新增写号源/挂号单的代码必须落在这里，
 * 不得散落到其它文件 —— 否则双范式会失控。
 *
 * 依赖注入：构造时传入 DbBackend，便于单测用桩替换（AGENTS.md「所有公共方法可单测」）。
 */
public class BookingRepo {
    private let db: DbBackend

    public init(db: DbBackend) {
        this.db = db
    }

    /* ---------- 读 ---------- */

    /* 原始排班读取：供退号归还/历史与管理读取，不能加可售过滤。 */
    public func findSchedule(scheduleId: Int64): ?ScheduleRow {
        let rs = db.query(
            "SELECT id, doctor_id, department_id, work_date, period, " +
            "total_num, remain_num, version, enabled FROM schedule WHERE id = ?",
            [DbInt(scheduleId)])
        if (rs.rowCount() < 1) {
            return None
        }
        let row = ScheduleRow()
        row.id = rs.getInt(0, 0)
        row.doctorId = rs.getInt(0, 1)
        row.departmentId = rs.getInt(0, 2)
        row.workDate = rs.getString(0, 3)
        row.period = rs.getString(0, 4)
        row.totalNum = rs.getInt(0, 5)
        row.remainNum = rs.getInt(0, 6)
        row.version = rs.getInt(0, 7)
        row.enabled = rs.getInt(0, 8) != 0
        return Some(row)
    }

    /* 患者读取与新挂号使用；停用/过期/关联无效排班等同不可售。 */
    public func findBookableSchedule(scheduleId: Int64, today!: String = ""): ?ScheduleRow {
        let date = if (today.size > 0) { today } else { hTodayDate() }
        let rs = db.query(
            "SELECT s.id, s.doctor_id, s.department_id, s.work_date, s.period, " +
            "s.total_num, s.remain_num, s.version, s.enabled FROM schedule s " +
            "WHERE s.id = ? AND " + bookingSchedulePredicate("s"),
            [DbInt(scheduleId), DbStr(date)])
        if (rs.rowCount() < 1) {
            return None
        }
        let row = ScheduleRow()
        row.id = rs.getInt(0, 0)
        row.doctorId = rs.getInt(0, 1)
        row.departmentId = rs.getInt(0, 2)
        row.workDate = rs.getString(0, 3)
        row.period = rs.getString(0, 4)
        row.totalNum = rs.getInt(0, 5)
        row.remainNum = rs.getInt(0, 6)
        row.version = rs.getInt(0, 7)
        row.enabled = rs.getInt(0, 8) != 0
        return Some(row)
    }

    /*
     * 按 (患者, client_token) 查**仍然有效**的既有挂号单 id；不存在返回 None（幂等快路径）。
     *
     * ── ★ 为什么必须按患者隔离（2026-10-07 修，第三方复查发现的严重缺陷）──
     * 原实现是 `WHERE client_token = ?`（**全局**查），而 `client_token` 是**客户端自己**
     * 生成的字符串（客户端契约里就是 `"booking-1"` 这类）。于是：
     *   · 患者 B 提交患者 A 用过的 client_token → 命中 A 的单并**原样返回**，
     *     既不扣号、也不报错 ⇒ **跨患者数据泄露**（B 拿到了 A 的挂号单内容），
     *     同时 B 以为自己挂上了（"成功了但没有票"）。
     *   · 有人退号后，同 token 重挂 → 命中那张**已取消**的单并返回，
     *     患者拿到一张 cancelled 的单却以为挂上了。
     *
     * 这两条都不是理论问题：复查方实测复现了两连击。
     *
     * ── 修法（两条一起）──────────────────────────────────────────────────
     *   1. **按 (patient_id, client_token) 查**，唯一索引也改成这个组合
     *      ⇒ 不同患者用同一个 token 字符串**互不影响**；
     *   2. **只把 `status <> 'cancelled'` 的单当作幂等命中**
     *      ⇒ 已取消的单不再被复用；退号后同 token 可以正常重挂。
     *
     * ⚠ 幂等的语义边界（写清楚，免得下次又改错）：
     *   幂等要防的是"**同一次挂号意图**被重复提交"。所以它以
     *   **"该患者当前是否已有一张有效单"** 为准 —— 单一旦被取消，
     *   那次意图已经了结，token 就该可以再用。
     */
    public func findAppointmentByToken(patientId: Int64, clientToken: String): ?Int64 {
        if (clientToken.size == 0) {
            return None
        }
        let rs = db.query(
            "SELECT id FROM appointment " +
            "WHERE patient_id = ? AND client_token = ? AND status <> 'cancelled'",
            [DbInt(patientId), DbStr(clientToken)])
        if (rs.rowCount() < 1) {
            return None
        }
        return Some(rs.getInt(0, 0))
    }

    /* 读挂号单明细。 */
    public func findAppointment(appointmentId: Int64): ?BookingResult {
        let rs = db.query(
            "SELECT " + APPT_COLS +
            "FROM appointment WHERE id = ?",
            [DbInt(appointmentId)])
        if (rs.rowCount() < 1) {
            return None
        }
        // 复用 fillFromRow：列顺序只有一处定义（见其注释）
        return Some(fillFromRow(rs, 0))
    }

    /*
     * ★ 某患者的挂号列表（P1 收尾项 ③："我的挂号"）。
     *
     * ── 口径（三条，都要说清否则容易各写各的）──────────────────────────────
     *   ① **默认只返回有效单**（`status <> 'cancelled'`）：患者打开"我的挂号"
     *      想看的是"我还剩哪些号"，把已取消的混在里面会让列表越用越乱。
     *      要看历史就显式传 `includeCancelled = true`。
     *   ② 排序 `created_at DESC, id DESC` —— 最近挂的在前；加 `id` 是为了
     *      **同秒内也稳定**（否则同一个 created_at 的多条顺序随机，测试会抖）。
     *   ③ **必须按 patientId 过滤**，由调用方从**令牌**取（见 http_app 的
     *      `/api/v1/appointments`），绝不能从请求参数取 —— 否则就是越权读别人的挂号。
     *
     * `limit` 上限保护：不让一次查询把整表拖出来（默认 50，最大 200）。
     */
    public func listAppointmentsByPatient(patientId: Int64, includeCancelled!: Bool = false,
                                          limit!: Int64 = 50): Array<BookingResult> {
        let cap = if (limit <= 0) { 50 } else if (limit > 200) { 200 } else { limit }
        let sql = "SELECT " + APPT_COLS +
                  "FROM appointment WHERE patient_id = ?" +
                  (if (includeCancelled) { "" } else { " AND status <> 'cancelled'" }) +
                  " ORDER BY created_at DESC, id DESC LIMIT ?"
        let rs = db.query(sql, [DbInt(patientId), DbInt(cap)])
        let out = ArrayList<BookingResult>()
        var i: Int64 = 0
        while (i < rs.rowCount()) {
            out.add(fillFromRow(rs, i))
            i = i + 1
        }
        return out.toArray()
    }

    /*
     * ★ 排班列表（P1 收尾项 ④：按科室/日期筛选）。
     *
     * ── 为什么要有它 ────────────────────────────────────────────────────────
     * 之前只有 `GET /schedules/:id`（按 id 查单个）。患者端要"看某科室某天有哪些号"
     * 只能靠猜 id —— 那是不可用的。
     *
     * ── 筛选语义（都**可选**，给了才加条件）────────────────────────────────
     *   · departmentId > 0 → 该科室
     *   · workDate 非空    → 该就诊日（精确匹配；日期区间查询属 P4 排班视图）
     *   患者列表遵守共同可售谓词（启用/有效日期时段/关联启用与归属）；
     *   管理/医生读取保留原 `enabled = 1` 范围，以便维护历史或失效的关联。
     *   并在 SQL 层按 `work_date, period, id` 排序（稳定，不靠应用层再排）。
     *
     * ⚠ **不做"只显示有号"的过滤**：`remain_num = 0` 的排班也要返回，
     *   让客户端能显示"已约满" —— 把满号的行藏起来会让患者以为"这天没排班"。
     *   是否可挂由 `remain_num` 字段自行判断。
     */
    public func listSchedules(departmentId!: Int64 = 0, workDate!: String = "",
                              limit!: Int64 = 100, bookableOnly!: Bool = true): Array<ScheduleRow> {
        let cap = if (limit <= 0) { 100 } else if (limit > 500) { 500 } else { limit }
        var sql = "SELECT s.id, s.doctor_id, s.department_id, s.work_date, s.period, s.total_num, " +
                  "s.remain_num, s.version, s.enabled FROM schedule s WHERE " +
                  (if (bookableOnly) { bookingSchedulePredicate("s") } else { "s.enabled = 1" })
        let params = ArrayList<DbValue>()
        if (bookableOnly) {
            params.add(DbStr(hTodayDate()))
        }
        if (departmentId > 0) {
            sql = sql + " AND s.department_id = ?"
            params.add(DbInt(departmentId))
        }
        if (workDate.size > 0) {
            sql = sql + " AND s.work_date = ?"
            params.add(DbStr(workDate))
        }
        sql = sql + " ORDER BY s.work_date ASC, s.period ASC, s.id ASC LIMIT ?"
        params.add(DbInt(cap))
        let rs = db.query(sql, params.toArray())
        let out = ArrayList<ScheduleRow>()
        var i: Int64 = 0
        while (i < rs.rowCount()) {
            let r = ScheduleRow()
            r.id = rs.getInt(i, 0)
            r.doctorId = rs.getInt(i, 1)
            r.departmentId = rs.getInt(i, 2)
            r.workDate = rs.getString(i, 3)
            r.period = rs.getString(i, 4)
            r.totalNum = rs.getInt(i, 5)
            r.remainNum = rs.getInt(i, 6)
            r.version = rs.getInt(i, 7)
            r.enabled = rs.getInt(i, 8) != 0
            out.add(r)
            i = i + 1
        }
        return out.toArray()
    }

    /*
     * 把结果集的第 i 行装配成 BookingResult。
     *
     * ⚠ 抽出来是为了**让列顺序只有一处定义** —— 上面 findAppointment /
     *   listAppointmentsByPatient / findAppointmentByToken 的 SELECT 列顺序
     *   必须完全一致，各写一份 getInt(0, n) 下标就迟早会错位（而且错位后
     *   类型恰好兼容时**不会报错**，只会读到隔壁列的值）。
     */
    /*
     * ★ 按 id + **医生**读挂号单（P4 接诊队列用；2026-10-07 增）。
     *
     * ⚠ 为什么放在 BookingRepo 而不是 VisitRepo：列清单与 `fillFromRow` 的下标顺序
     *   都定义在**本文件** —— 换个文件再写一遍 SELECT 就等于有了第二份列顺序，
     *   而列顺序错位在类型恰好兼容时**不报错**，只会读到隔壁列。
     *   📌 所以"读挂号单"这个语义**只在 BookingRepo 里实现一次**，VisitRepo 调它。
     *
     * ⚠ 不匹配（不存在 / 不属于该医生）一律返回 None：**不区分 404 与 403** ——
     *   区分开就成了"这张单是否存在"的枚举 oracle。
     */
    public func findAppointmentForDoctor(appointmentId: Int64, doctorId: Int64): ?BookingResult {
        let rs = db.query(
            "SELECT " + APPT_COLS +
            "FROM appointment WHERE id = ? AND doctor_id = ?",
            [DbInt(appointmentId), DbInt(doctorId)])
        if (rs.rowCount() < 1) {
            return None
        }
        return Some(fillFromRow(rs, 0))
    }

    /*
     * ★ 某医生的接诊队列（P4；不含已退号的单）。
     *
     * ── 排序（2026-10-15 改进 6 改）───────────────────────────────────────
     * 先按**就诊流程优先级**（`visitQueueRank`：已到院 → 候诊中 → 接诊中 →
     *   已挂号 → 已完成 → 已爽约），再按 `visit_date, period, seq_no`。
     *
     * ⚠ 为什么必须把"到院/候诊"提到最前：队列原来是纯 `seq_no` 顺序，
     *   于是 1 号患者没来、2 号已经到了，医生的屏幕上 2 号仍排在后面 ——
     *   医生只能自己在一屏里找"谁到了"。到院状态落库后，排序就能如实反映
     *   "谁在等"。终态（已完成/已爽约）排在最后，但**仍在队列里**：
     *   医生需要回头核"今天这个号最后怎么了"。
     * ⚠ 这个 CASE 与 `domain_emr.cj` 的 `visitQueueRank` **必须一致**
     *   （SQL 里排序才能配合 LIMIT；AC-P4-8 用那个函数预测顺序并逐项比对）。
     *
     * ⚠⚠ 最后一级 `id ASC` 是**必需的兜底**（2026-10-16 复核 D5）：
     *   `visit_date`/`period`/`seq_no` 三列在库上都没有唯一约束
     *   （测试夹具与并发补号都可能造出并列行），而这条 SQL 带 `LIMIT` ——
     *   排序键并列时 MySQL 不保证返回顺序，于是**同一个请求可能返回不同集合**，
     *   表现为"页面刷新一次就少了一个号"。加一个唯一的自增列做兜底，
     *   顺序才是确定的（本文件其它带 LIMIT 的查询同样都有兜底）。
     */
    public func listAppointmentsByDoctor(doctorId: Int64, limit: Int64): Array<BookingResult> {
        let out = ArrayList<BookingResult>()
        let rs = db.query(
            "SELECT " + APPT_COLS +
            "FROM appointment WHERE doctor_id = ? AND status <> ? " +
            "ORDER BY (CASE status " +
            "WHEN 'arrived' THEN 0 WHEN 'waiting' THEN 1 WHEN 'visiting' THEN 2 " +
            "WHEN 'booked' THEN 3 WHEN 'done' THEN 4 WHEN 'no_show' THEN 5 ELSE 6 END) ASC, " +
            "visit_date ASC, period ASC, seq_no ASC, id ASC LIMIT ?",
            [DbInt(doctorId), DbStr("cancelled"), DbInt(limit)])
        var i: Int64 = 0
        while (i < rs.rowCount()) {
            out.add(fillFromRow(rs, i))
            i = i + 1
        }
        return out.toArray()
    }

    public func fillFromRow(rs: DbResultSet, i: Int64): BookingResult {
        let r = BookingResult()
        r.appointmentId = rs.getInt(i, 0)
        r.scheduleId = rs.getInt(i, 1)
        r.patientId = rs.getInt(i, 2)
        r.doctorId = rs.getInt(i, 3)
        r.departmentId = rs.getInt(i, 4)
        r.visitDate = rs.getString(i, 5)
        r.period = rs.getString(i, 6)
        r.seqNo = rs.getInt(i, 7)
        r.status = rs.getString(i, 8)
        r.createdAt = rs.getInt(i, 9)
        r.slotRestored = rs.getInt(i, 10) != 0
        /* ⚠ 下标 11/12/13 与 `APPT_COLS` 的列序一一对应（改一处必须改另一处）。 */
        r.arrivedAt = rs.getInt(i, 11)
        r.startedAt = rs.getInt(i, 12)
        r.finishedAt = rs.getInt(i, 13)
        r.outcome = BookingOutcome.AlreadyBooked(r.appointmentId)
        return r
    }

    /* 某排班已占用的号数（用于生成就诊序号）。 */
    public func countBooked(scheduleId: Int64): Int64 {        let rs = db.query(
            "SELECT COUNT(*) FROM appointment WHERE schedule_id = ? AND status <> 'cancelled'",
            [DbInt(scheduleId)])
        if (rs.rowCount() < 1) {
            return 0
        }
        return rs.getInt(0, 0)
    }

    /* ---------- 写：原子扣号 ---------- */

    /*
     * ★ 核心：**一次成功**的原子扣减（不带 version 条件）。
     *
     * 返回 true = 扣号成功（受影响行数 1）；false = 号已放完或排班已不可售。
     *
     * ── 为什么去掉 `version = ?`（2026-10-07 修，第三方复查发现的严重少卖）────
     * 原实现是乐观锁：`WHERE id = ? AND version = ? AND remain_num > 0`，
     * 调用方拿着**读到的** version 去扣，失败就重读重试。
     *
     * 实测它在**最穷工况**（请求数 ≈ 号源数）下严重少卖：
     *     20 并发抢 20 号 → 只卖出 15~17     （少卖 15~25%）
     *     30 并发抢 30 号 → 只卖出 22~23     （少卖 23~27%）
     *     40 并发抢 40 号 → 只卖出 25~26     （少卖 35~38%）
     * 原因：N 个请求同时读到同一个 version，只有一个能成功，其余全部作废；
     * 重试时它们又读到同一个新 version、再次互撞 —— 重试预算（3~6 次）迅速耗尽。
     * 这直接触发了 ADR §8 的复审阈值（耗尽率 > 1% → 重估方案 C），实测耗竭率高达 **50%**。
     *
     * ── 为什么去掉 version 是**更正确**而不是更冒险 ──────────────────────────
     * 防超卖真正依赖的只有两件事，**都在同一条 UPDATE 里由 InnoDB 原子求值**：
     *   · `remain_num = remain_num - 1` —— 原子自减，不会丢更新；
     *   · `remain_num > 0`             —— 永不减成负数（AC-2）。
     * version 是**乐观锁**手段，而乐观锁解决的问题是"**跨语句**的检查-后-写"
     * （读出来判断、隔一会儿再写回去）。这里的判定与写入**在同一条语句内**完成，
     * 根本不存在那个窗口 —— 所以 version 条件不提供任何额外保护，
     * 只贡献了"并发请求互相作废"。去掉它，N 个请求就能**一次成功 N 个**。
     *
     * ⚠ `version` 列**保留并在成功时 +1**：它是给**管理端并发编辑**用的
     *   （管理员改排班时防止覆盖别人的改动），不再是扣号路径的前置条件。
     *   语义变化已记入 ADR-0001（rev.3）。
     */
    public func tryDeductSlot(scheduleId: Int64, today!: String = ""): Bool {
        let date = if (today.size > 0) { today } else { hTodayDate() }
        let n = db.exec(
            "UPDATE schedule SET remain_num = remain_num - 1, version = version + 1 " +
            "WHERE id = ? AND remain_num > 0 AND " + bookingSchedulePredicate("schedule"),
            [DbInt(scheduleId), DbStr(date)])
        return n == 1
    }

    /*
     * 归还号源（退号 / 取消）。
     *
     * ★ **不带 version 前置条件** —— 与 `tryDeductSlot` 的修法镜像对称（2026-10-07 修）。
     *
     * ── 为什么必须去掉 version（复查发现的**严重**缺陷）──────────────────────
     * 原实现是 `WHERE id = ? AND version = ? AND remain_num < total_num`。
     * 而 `releaseSlotFor` **没有任何重试** —— 于是并发退号时：
     *   N 个退号事务读到**同一个** version，只有一个能归还成功，
     *   其余全部拿到 0 行 ⇒ `SlotNotRestored` ⇒ **号源永久丢失**，需人工重置。
     *
     * 实测（10 个号源、10 张单**同时**退）：
     *     成功归还 5 张 / **丢失 5 个号源** / remain_num = 5（应为 10）
     *   而每个患者都收到了"退号成功"的 200 响应。
     *   3 个人同时退号就已经中招（丢失 1 个）—— **不是极端工况**。
     *
     * ── 为什么去掉它仍然安全（与扣号同一套论证）──────────────────────────
     * 防止"归还超过放出量"真正依赖的是 `remain_num < total_num`，
     * 它和 `remain_num = remain_num + 1` 在**同一条 UPDATE 内**由 InnoDB 原子求值 ——
     * 不存在"检查-后-写"的跨语句窗口。
     *   · 并发退号：N 条 UPDATE 竞争同一行，InnoDB 行锁使它们**串行**执行，
     *     每条都看到前一條的结果 ⇒ N 个号源**全部归还**，不会少、不会多。
     *   · 反复"挂号→退号"：`remain_num < total_num` 保证**永远不会超过放出量**。
     *
     * ⚠ 上一版的注释在这里写着"归还路径并发强度低、重试代价可接受"——
     *   但代码里**根本没有重试**。注释暗示了一个不存在的缓解措施，这种"注释撒谎"
     *   比没有注释更坏（它会让人不去查真正的失败路径）。实测已证实后果。
     *
     * 📌 教训（本轮最重要的一条）：**同一个根因会在"镜像路径"上重现。**
     *   修 `tryDeductSlot` 时我只改了"扣"，没顺手检查"还"—— 而两者用的是同一个
     *   错误模式（version 前置条件 + 无重试）。以后修这类缺陷必须**双向核对**。
     */
    public func releaseSlot(scheduleId: Int64): Bool {
        let n = db.exec(
            "UPDATE schedule SET remain_num = remain_num + 1, version = version + 1 " +
            "WHERE id = ? AND remain_num < total_num",
            [DbInt(scheduleId)])
        return n == 1
    }

    /*
     * 插入挂号单。返回**新行的自增 id**。
     *
     * ⚠⚠ 踩过的坑（P0 验收测试 AC-3/AC-6 抓出来的）：
     *   `DbBackend.exec()` 返回的是**受影响行数**（INSERT 恒为 1），
     *   **不是**自增 id。把它当 id 返回会让所有新增挂号单的 id 都是 1 ——
     *   于是"两次提交指向同一张单"这类断言会因为 id 都是 1 而**假通过**，
     *   而 visit_date 查询会指向不存在的行（这坑真的发生过）。
     *   正确做法：execInsert 在同一连接临界区完成 INSERT 与生成 ID 读取。
     *
     * ⚠ `visit_date` 写入的是**调用方传来的快照值**，不是从 schedule 现查的 ——
     *   这正是"顺延不串号"的实现点（AC-6）：管理员之后改 schedule.work_date，
     *   已挂号单的 visit_date 不会跟着变。
     *
     * ⚠ 并发重复提交时唯一索引会抛异常 → 由调用方捕获并回读（见 book()）。
     */
    public func insertAppointment(scheduleId: Int64, patientId: Int64, doctorId: Int64,
                                  departmentId: Int64, visitDate: String, period: String,
                                  seqNo: Int64, clientToken: String, now: Int64): Int64 {
        return db.execInsert(
            "INSERT INTO appointment " +
            "(schedule_id, patient_id, doctor_id, department_id, visit_date, period, " +
            " seq_no, status, client_token, created_at, cancelled_at) " +
            "VALUES (?, ?, ?, ?, ?, ?, ?, 'booked', ?, ?, 0)",
            [DbInt(scheduleId), DbInt(patientId), DbInt(doctorId), DbInt(departmentId),
             DbStr(visitDate), DbStr(period), DbInt(seqNo), DbStr(clientToken), DbInt(now)])
    }

    /* ---------- 写：排班（管理员） ---------- */

    /*
     * ★ 2026-10-17 增：按「医生 + 就诊日 + 时段」找已有排班，返回其 id。
     *
     * 为什么要它（实测确认的缺陷）：`insertSchedule` 是**裸 INSERT**，
     *   同一医生同一天同一时段可以建出任意多条排班 —— 实测连发两次**完全相同的**
     *   请求得到两条 201（schedule_id 930010 / 930011），号源合计翻倍（20 → 40）。
     *   号源翻倍不是"多卖几张"这么轻：它意味着**同一个医生在同一时段被排了两份工**，
     *   放号数与余量在管理台上再也对不上账。
     *
     * ⚠ 判据用 `(doctor_id, work_date, period)` 三元组，**不含 `enabled`**：
     *   已停诊（`enabled = 0`）的那条也是"这个时段已经排过了"，
     *   正确处置是**改它**（`PUT /admin/schedules/:id` 打开 `enabled`），
     *   而不是再建一条 —— 否则停诊记录越积越多，患者端还会看到"两条同样的排班"。
     * ⚠ 与 `listSchedules` 的分工：那个是"按科室/日期列给患者看的读模型"，
     *   不带 `doctor_id`；这里只需要一个 id 做存在性判断。
     */
    public func findScheduleIdByDoctorSlot(doctorId: Int64, workDate: String,
                                           period: String): ?Int64 {
        let rs = db.query(
            "SELECT id FROM schedule WHERE doctor_id = ? AND work_date = ? AND period = ? " +
            "ORDER BY id ASC LIMIT 1",
            [DbInt(doctorId), DbStr(workDate), DbStr(period)])
        if (rs.rowCount() > 0) {
            return Some(rs.getInt(0, 0))
        }
        return None
    }

    /*
     * 新建排班（号源）。
     *
     * 新排班 `version = 0`、`remain_num = total_num` —— 与乐观锁起点一致。
     * 返回本次 INSERT 的生成 ID，不能随后单独读取连接的 LAST_INSERT_ID。
     */
    public func insertSchedule(doctorId: Int64, departmentId: Int64, workDate: String,
                               period: String, totalNum: Int64, now: Int64): Int64 {
        return db.execInsert(
            "INSERT INTO schedule " +
            "(doctor_id, department_id, work_date, period, total_num, remain_num, " +
            " version, enabled, created_at) VALUES (?, ?, ?, ?, ?, ?, 0, 1, ?)",
            [DbInt(doctorId), DbInt(departmentId), DbStr(workDate), DbStr(period),
             DbInt(totalNum), DbInt(totalNum), DbInt(now)])
    }

    /*
     * 改排班：放号数（`totalNum`）与停诊（`enabled`），**PATCH 语义**（None = 不改）。
     *
     * ★ 一条原子 UPDATE 同时兜住三件事（互不矛盾，也不需要事务）：
     *   ① `version = ?` 前置条件 —— 乐观锁：把"读-改-写"的窗口**显式化**。
     *      与扣号/归还那边刻意去掉 version 不同（见 `tryDeductSlot` 的长注释）：
     *      那两处失败会**丢号源/少卖**，所以必须"一次就成功"；
     *      这里是**人在页面上编辑**，冲突的代价只是"刷新一下"，用乐观锁正好。
     *   ② `remain_num + (? - total_num) >= 0` —— 不变量"**放号数不得小于已约数**"
     *      留在 **SQL 的 WHERE 里**，不是在应用里"先读后判"：
     *      "已约数" = `total_num - remain_num` 是**同一行内**算出来的，
     *      先读后判会有一个窗口（读完 3 张已约、另一个请求又约了 1 张 ⇒ 改小成功、
     *      于是 4 张已约的排班放号数变成 3 —— 界面上"已约 > 放号"这种无法解释的状态）。
     *   ③ 改 `total_num` 时**保持已约数不变**：`remain_num` 同步加减同一个差值。
     *      ⚠ 直接写 `remain_num = 新放号数` 等于把已卖出去的号当没卖过（**超卖**）。
     *      ⚠ 只改 `enabled` 时差值为 0 ⇒ 那条不变量恒成立，不会被误判成"太小"。
     *
     * ★★ `SET` 里 `remain_num` 必须写在 `total_num` **前面**（这一条踩过）：
     *   MySQL 的 `UPDATE` **按书写顺序求值，且后面的表达式看到的是前面刚赋的新值**
     *   —— 先写 `total_num = ?` 再写 `remain_num = remain_num + (? - total_num)`，
     *   那个 `total_num` 已经是**新值** ⇒ 差值恒为 0 ⇒ 余量原地不动，
     *   而"已约数"被凭空放大（放号 10 改 20 后仍是 10 张可约、却显示已约 10）。
     *   反过来的另一个坑：`WHERE` 里看到的**始终是旧值**（先判后改），
     *   所以不变量那半句 `remain_num + (? - total_num) >= 0` 用不着改。
     *
     * ⚠ 影响 0 行时**回读分辨原因，不猜**：三类失败（不存在 / 版本冲突 / 放号数太小）
     *   对应三个不同的 HTTP 状态与三种不同的处置。把"改到 0 张"也报成"并发冲突"
     *   是最容易写错的一处 —— 使用者会一直刷新重试一个**永远不会成功**的操作。
     */
    public func updateSchedule(id: Int64, totalNum: ?Int64, enabled: ?Bool,
                               version: Int64): ScheduleUpdateOutcome {
        let out = ScheduleUpdateOutcome()
        let before = findSchedule(id)
        match (before) {
            case None =>
                out.notFound = true
                return out
            case Some(row) =>
                out.totalNum = row.totalNum
                out.remainNum = row.remainNum
                out.booked = row.totalNum - row.remainNum
                out.version = row.version
        }
        let base = before.getOrThrow()
        let wantEnabled = match (enabled) {
            case Some(v) => v
            case None => base.enabled
        }
        let newTotal = match (totalNum) {
            case Some(v) => v
            case None => base.totalNum
        }
        let n = db.exec(
            "UPDATE schedule SET remain_num = remain_num + (? - total_num), total_num = ?, " +
            "enabled = ?, version = version + 1 " +
            "WHERE id = ? AND version = ? AND remain_num + (? - total_num) >= 0",
            [DbInt(newTotal), DbInt(newTotal), DbInt(if (wantEnabled) { 1 } else { 0 }),
             DbInt(id), DbInt(version), DbInt(newTotal)])
        if (n > 0) {
            out.ok = true
            out.totalNum = newTotal
            out.enabled = wantEnabled
            match (findSchedule(id)) {
                case Some(r) =>
                    out.remainNum = r.remainNum
                    out.version = r.version
                    out.booked = r.totalNum - r.remainNum
                case None => ()
            }
            return out
        }
        /*
         * 0 行 ⇒ 回读一次，把原因**分成三类**（顺序有意义：
         * 先判"还在不在"，再判"版本对不对"，最后才是"数太小"）。
         */
        match (findSchedule(id)) {
            case None => out.notFound = true
            case Some(r) =>
                out.totalNum = r.totalNum
                out.remainNum = r.remainNum
                out.booked = r.totalNum - r.remainNum
                out.version = r.version
                if (r.version != version) {
                    out.conflict = true
                } else if (newTotal < out.booked) {
                    out.tooSmall = true
                } else {
                    /*
                     * 三类都不是却 0 行 ⇒ 只可能是"读与写之间被别的事务改过又改回来了"。
                     * 按冲突处理（让调用方重读一次），**不报成功**。
                     */
                    out.conflict = true
                }
        }
        return out
    }

    /*
     * ⚠ 这里原先有 `idemKey()` / `putIdem()` / `pruneIdem()` 三个方法，
     *   操作 `booking_idem` 表做"应用级幂等登记"。**2026-10-07 删除**（含表）。
     *
     * 为什么删（完整论证见 ADR-0001 §7 第 7 条）：
     *   1. **已被更硬的机制覆盖**：幂等由 `book()` 的"先查 + `(patient_id, client_token)`
     *      唯一索引兜底"保证，而唯一索引是**数据库级**约束 ——
     *      比"应用先 INSERT IGNORE 登记、再决定要不要写业务表"更强，
     *      因为应用级登记与业务写入之间仍有窗口。
     *   2. **它从未在生产路径上被调用**：`book()`/`cancel()` 全程不碰它，
     *      只有验收测试 AC-8 在测 ⇒ **AC-8 测的是一条生产不走的路**，
     *      这种"绿色的假保证"比没有测试更坏。
     *   3. 它存在的理论价值是"操作本身不幂等"的场景（如支付：需要独立记下
     *      "这笔请求处理过"，因为支付没有天然唯一键）。挂号**有**天然唯一键
     *      （患者 + client_token），用不上这一层。
     *
     * ✅ 代价（如实记录）：失去"登记与业务写入解耦"的能力。
     *   若将来真的接入了**无天然唯一键**的写操作（支付/出站调用），
     *   需要重新引入幂等登记表 —— 那时也应重新开 ADR，而不是复活这张表。
     */

    /* ---------- 主流程：挂号 ---------- */

    /*
     * 挂号（P0 主流程）。
     *
     * 流程：
     *   1. 幂等快路径：client_token 已有单 → AlreadyBooked（只读，不开事务）
     *   2. 读排班（拿 version 与 visit_date 快照）；不存在 → ScheduleNotFound
     *   3. 【事务】原子扣号 + INSERT 挂号单
     *   4. 唯一索引冲突（并发同 token）→ 回读既有单 → AlreadyBooked
     *
     * ⚠ 重试预算（`MAX_BOOKING_RETRY`）现在只用于**真正的瞬时错误**
     *   （死锁 / 锁等待超时这类 InnoDB 异常），**不再用于 version 冲突** ——
     *   因为扣号已经没有 version 前置条件，正常争抢下**一次就能成功**
     *   （见 tryDeductSlot 的注释）。
     *
     * ⚠ 还要注意**不能对"重试"这件事本身抱有幻想**：
     *   本函数原先把 version 冲突也当可重试，结果在最穷工况（请求数≈号源数）
     *   下少卖 15%~50%。**凡是被判为"可重试"的失败，都会在高并发下累积成丢单**，
     *   所以判据必须严格 —— 只retry 那些"下次大概率会不同"的错误。
     */
    public func book(patientId: Int64, scheduleId: Int64, clientToken: String,
                     now: Int64, maxRetry!: Int64 = MAX_BOOKING_RETRY,
                     today!: String = ""): BookingResult {
        let r = BookingResult()
        /*
         * 「今天」默认取 `now` 所在的那一天。`today` 是给**验收夹具**用的注入口：
         *   夹具刻意用写死的排班日期（如 2026-10-08）来保证确定性，而可售谓词要求
         *   `work_date >= 今天` —— 不注入就会把夹具排班一律判成"过期不可售"，
         *   于是把"回填号源"这类真实回归淹没在夹具噪声里。
         *   生产路径（HTTP 层）不传该参数，语义与加注入前**完全一致**。
         */
        let todayDate = if (today.size > 0) { today } else { hDateStringOf(now) }

        // 1) 幂等快路径：该患者**当前有效**的单 → 直接返回（只读，不开事务）
        let dup = findAppointmentByToken(patientId, clientToken)
        if (dup.isSome()) {
            return fillFromAppointment(dup.getOrThrow())
        }

        // 2) 读一次排班（拿 doctor/department/就诊日快照；**version 不再参与扣号**）
        var attempt: Int64 = 0
        while (attempt <= maxRetry) {
            let cur = findBookableSchedule(scheduleId, today: todayDate)
            if (cur.isNone()) {
                r.outcome = BookingOutcome.ScheduleNotFound
                return r
            }
            let s = cur.getOrThrow()

            // ★ 事务：扣号 + 写单必须同事务（ADR §2.2 细节 ③）。
            // 结果经 TxResult 回传 —— 仓颉闭包不能捕获外部可变 var。
            let tx = TxResult()
            try {
                db.withTransaction({ =>
                    if (tryDeductSlot(scheduleId, today: todayDate)) {
                        /*
                         * ★ 把真正写进库的那个 seq **带出来**（存进 tx），
                         *   供响应回填使用 —— 不要回填时另算一遍（2026-10-07 修）。
                         *
                         * 复查实测的不一致：退掉 seq=1 的单后再挂，库里落 seq_no=2，
                         * 而 HTTP 响应报 seq_no=1。根因就是回填用了 `countBooked()`：
                         *   它统计的是"**当前有效**单数"，而 seq 是 `MAX(seq_no)+1`
                         *   （不回收已用过的号）—— **两个口径根本不是一回事**。
                         * 就诊序号是给患者看、用来叫号的，报错号等于误导患者。
                         */
                        let seq = nextSeqNo(scheduleId)
                        tx.seqNo = seq
                        tx.newId = insertAppointment(scheduleId, patientId, s.doctorId,
                                                     s.departmentId, s.workDate, s.period,
                                                     seq, clientToken, now)
                        tx.booked = true
                    }
                })
            } catch (e: Exception) {
                /*
                 * 两种可能，必须分开处理：
                 *   ① 唯一索引冲突 = 并发重复提交（同患者同 token 的单刚插进去）
                 *      → 回读既有单，返回幂等结果（**这不是错误**）；
                 *   ② 其它（死锁 / 锁等待超时 / 连接问题）→ 值得重试；
                 *      重试仍失败则**原样抛出，绝不吞**（吞掉就变成"静默丢单"）。
                 */
                let again = findAppointmentByToken(patientId, clientToken)
                if (again.isSome()) {
                    return fillFromAppointment(again.getOrThrow())
                }
                attempt = attempt + 1
                if (attempt > maxRetry) {
                    throw e
                }
                continue
            }

            if (tx.booked) {
                r.appointmentId = tx.newId
                r.scheduleId = scheduleId
                r.patientId = patientId
                r.doctorId = s.doctorId
                r.departmentId = s.departmentId
                r.visitDate = s.workDate      // ★ 就诊日快照
                r.period = s.period
                r.status = "booked"
                // ★ 用**实际写入**的那个 seq（tx.seqNo），不要回算
                r.seqNo = tx.seqNo
                r.createdAt = now
                r.outcome = BookingOutcome.Booked(tx.newId)
                return r
            }

            /*
             * 扣号返回 0 行：号已放完，或排班/关联实体在读取后被停用。
             * ⚠ 这里**不能重试**：重试只会再拿到 0 行，却把"号已售完"这个
             *   明确结论拖成"重试耗尽后的 SlotGone"—— 结果一样，但白烧预算，
             *   而且在高并发下会掩盖真正的问题（少卖就是被这个掩盖出来的）。
             */
            /*
             * ★ 2026-10-17 补：扣号 0 行时**必须先复查幂等键**，与上面 catch 分支
             *   (`:878-881`) 的"唯一索引冲突 → 回读既有单"是**同一条纪律**。
             *
             * 漏掉的后果（实测复现，6/6 轮）：同一个 `client_token` 的并发重发里，
             *   请求 A 抢到最后一个号并建单成功，请求 B 与它并发、扣号时余量已是 0
             *   ⇒ 0 行 ⇒ 直接落到下面判成 `SlotGone`，于是 B 拿到 **409「号源已被抢空」**，
             *   而它自己的那张单**其实已经存在**（A 建的就是它的 token）。
             *   客户端按契约"同值重试必须 200 重放"处理，这里却报失败 ⇒
             *   界面提示患者挂号失败、患者改约别的号源 ⇒ **一次挂号变成两次**。
             *
             * ⚠ 为什么这条路径和"排班被停用"也有关：无论最终该判 SlotGone 还是
             *   ScheduleNotFound，只要这个 token 已经有单，正确结论就只有一个 ——
             *   幂等回放（200）。所以复查要放在**分类之前**。
             * ⚠ 成本：只在"扣号 0 行"这条失败路径上多一次索引查询
             *   （唯一键 `uk_appointment_patient_token` 精确命中），不在热路径上。
             */
            let againAfterDeduct = findAppointmentByToken(patientId, clientToken)
            if (againAfterDeduct.isSome()) {
                return fillFromAppointment(againAfterDeduct.getOrThrow())
            }
            if (findBookableSchedule(scheduleId, today: todayDate).isNone()) {
                r.outcome = BookingOutcome.ScheduleNotFound
                return r
            }
            r.outcome = BookingOutcome.SlotGone
            return r
        }

        r.outcome = BookingOutcome.SlotGone
        return r
    }

    /*
     * 下一个就诊序号 = 当前最大 seq_no + 1。
     *
     * ⚠ 原实现是 `COUNT(*) + 1`：退号后会**复用**已释放的序号
     *   （1,2,3 → 退掉 2 → 下一个又拿到 3，与在座的 3 号撞号）。
     *   改用 `MAX(seq_no) + 1` 保证单调递增、不重号。
     *
     * ⚠ 已知限制（如实标注）：本方法 + INSERT 之间**没有**唯一约束兜底，
     *   极端并发下仍可能取到相同的 seq_no（两条都在 MAX 之后取到同一个值）。
     *   就诊序号只是"排队叫号"的展示信息、不是业务主键，因此当前接受这一点；
     *   真要严格需要单独一个计数器行或对 (schedule_id, seq_no) 加唯一索引 +
     *   捕获冲突重取 —— 那属于 P4 叫号功能范围。
     */
    public func nextSeqNo(scheduleId: Int64): Int64 {
        let rs = db.query(
            "SELECT COALESCE(MAX(seq_no), 0) + 1 FROM appointment WHERE schedule_id = ?",
            [DbInt(scheduleId)])
        if (rs.rowCount() < 1) {
            return 1
        }
        return rs.getInt(0, 0)
    }

    /*
     * 取消挂号并归还号源（在线路径，**绝不进离线队列** —— brief §5.4）。
     *
     * ── 为什么返回 `CancelOutcome` 而不是 `Bool`（P0 复查发现的真缺陷）──────
     * 原实现返回 `tx.cancelDone && tx.released`。于是存在一条
     * **「单子取消了、号没还回，却对外报失败」** 的路径：
     *   `releaseSlotFor` 因为 `remain_num < total_num` 不成立而失败
     *   （例如管理员重置过号源，`remain_num == total_num`），
     *   此时事务**已经提交** —— 挂号单 status 已是 cancelled，号源却没加回去，
     *   而调用方收到 `false`，会以为"取消失败"从而**再去重试或误报**。
     *
     * 两件事的状态被压进一个 bool，就必然丢失信息。改为四态：
     *   · `Cancelled`        —— 单已取消且号已归还（正常路径）
     *   · `SlotNotRestored`  —— **单已取消**（已提交，不可回滚），但号源未归还
     *                           → 调用方应告知用户"已退号"，并把号源不一致**记进运维告警**，
     *                             由管理员用重置号源修，**不要**让用户重复点击退号
     *   · `NotCancellable`   —— ★ 单在，但当前状态**不允许**退号（只有 `booked` 能退，
     *                           见 domain_emr.cj 的流转表）；对外是 409，不是 404
     *   · `NotFound`         —— 单不存在
     *
     * 幂等：已取消的单再次取消，返回 `Cancelled`（不重复动号源）。
     */
    public func cancel(appointmentId: Int64, now: Int64): CancelOutcome {
        let found = findAppointment(appointmentId)
        if (found.isNone()) {
            return CancelOutcome.NotFound
        }
        let a = found.getOrThrow()
        if (a.status == "cancelled") {
            /*
             * ★ 幂等路径也必须**如实**回报上次的结果（2026-10-07 修）。
             *
             * 原实现这里无条件 `return Cancelled` —— 而 `Cancelled` 的语义是
             * "已取消 **且号已归还**"。于是第一次退号因 `remain_num == total_num`
             * 没能归还时：
             *     第 1 次 → SlotNotRestored + 告警（诚实）
             *     第 2 次（用户重试）→ Cancelled，**告警被抹掉**
             * 实测复现。运维告警不该被一次无关的重试消掉。
             * 现在按落库的 `slot_restored` 返回真实状态。
             */
            if (!a.slotRestored) {
                return CancelOutcome.SlotNotRestored
            }
            return CancelOutcome.Cancelled
        }
        /*
         * ★★ 2026-10-12：**退号必须走状态机** —— 只有 `booked` 可以退。
         *
         * 修的是什么（代码检查报告第 1 条，高优先级）：
         *   原实现的原子 UPDATE 条件是 `status <> 'cancelled'`，于是
         *   `visiting`（接诊中）/ `done`（已完成）/ `no_show`（爽约）**都能被改成 cancelled**
         *   并把号源加回去。后果有两条，都很实在：
         *     ① 患者可以退掉一张**已经看完**的单 —— 覆盖就诊结果，且凭空多出一个可售号源；
         *     ② 医生点"完成就诊"与患者退号并发时，两边各改一次，落库状态取决于谁后写。
         *
         * 口径**唯一来自 domain_emr.cj 的显式流转表**（`visitTransitionAllowed`）：
         *   它只允许 `booked → cancelled`，`done` / `no_show` / `cancelled` 都是终态。
         *   ⚠ 这里**刻意不写** `status == "booked"` 这样的字面判断 —— 那等于把同一条规则
         *     抄成第二份，将来流转表放开（比如允许"接诊中"退号）时这份不会跟着变。
         *
         * ⚠ 这只是**前置判断**（为了给出准确的对外结果）。真正的护栏是下面那条
         *   带 `status = ?` 的原子 UPDATE —— 并发下"先读后判"永远可能过期
         *   （报告里也点明了"仅增加前置 SELECT 检查不能解决并发问题"）。
         */
        if (!visitTransitionAllowed(a.status, VISIT_CANCELLED)) {
            return CancelOutcome.NotCancellable(a.status)
        }
        /*
         * ★★ 2026-10-17 增：**病历已定稿（locked）的单不能退号**。
         *
         * 与上面那条状态机的分工：状态机管"这张单走到哪一步了"，这条管"这张单的病历
         * 是不是已经定稿了" —— 两件事都成立才允许退。实测确认的缺陷（修复前）：
         *   `booked` 的单 → 医生写病历 + **锁定**（`medical_record.status = 'locked'`）
         *   → 患者退号仍然 200 ⇒ 组合状态 `appt=cancelled` + `emr=locked`，
         *   号源回到池子（`remain_num` 归还、可能被卖给别人）。
         *   而 `finish` 要求 `visiting` + 病历已锁定，`cancelled` 是终态 ⇒
         *   **该单永远走不到 `done`**，那份定稿病历成了孤儿
         *   （`UNIQUE KEY uk_record_appointment` 保证不可能再建第二份）。
         *
         * ⚠ 口径**唯一来自病历状态**（`emrHasLockedRecord`），这里不写
         *   "有没有病历"这种判断：草稿（draft）本来就该允许退号
         *   （医生还没定稿，退号后草稿随单作废是合理的）。
         */
        if (emrHasLockedRecord(db, appointmentId)) {
            return CancelOutcome.RecordLocked
        }
        let tx = TxResult()
        db.withTransaction({ =>
            /*
             * ★ 退号时**释放幂等键**：把 client_token 置 NULL。
             *
             * 为什么必须做（2026-10-07 修，实测 500）：
             *   唯一索引是 (patient_id, client_token)。已取消的单如果继续占着那个 token，
             *   患者想用同一个 token 重挂时 INSERT 就撞唯一键 → **500**。
             *   只在查询侧过滤 cancelled 是不够的 —— 索引不管你查不查。
             *
             * 为什么置 NULL 而不是空串：MySQL 唯一索引**允许多个 NULL**（NULL != NULL），
             *   所以"置 NULL = 释放"天然成立，且同一患者可以有多张已取消的单。
             *   空串不行：第二个被取消的单会撞 (patient_id, '')。
             *
             * 代价（如实记录）：退号后我们就**不再保留**"当初是哪个 token 建的"这条信息。
             *   挂号单的 id / 时间 / 就诊日都还在，业务上不需要 token 做回溯。
             */
            /*
             * ⚠ `NOT EXISTS` 那半句是**真正的护栏**（与 `finish` 的写法同源，
             *   见 domain_emr.cj 里 `UPDATE appointment ... AND EXISTS (SELECT 1 FROM
             *   medical_record mr WHERE ... mr.status = ?)`）：
             *   上面的前置 SELECT 只能给出准确的对外结果，**挡不住并发** ——
             *   医生在同一瞬间点"提交锁定病历"时，先读后判必然过期，
             *   于是定稿病历照样挂在一张刚退号、号源已归还的单上。
             *   把条件放进 WHERE，判据与更新在**同一条语句**里求值，窗口才关上。
             */
            let n = db.exec(
                "UPDATE appointment SET status = 'cancelled', cancelled_at = ?, " +
                "client_token = NULL WHERE id = ? AND status = ? " +
                "AND NOT EXISTS (SELECT 1 FROM medical_record mr " +
                "WHERE mr.appointment_id = appointment.id AND mr.status = ?)",
                [DbInt(now), DbInt(appointmentId), DbStr(VISIT_BOOKED), DbStr(EMR_LOCKED)])
            if (n == 1) {
                tx.cancelDone = true
                tx.released = releaseSlotFor(a.scheduleId)
                /*
                 * ★ 把"号是否已归还"落库 —— 幂等路径要靠它如实回报。
                 * ⚠ 必须与 status 的更新在**同一个事务**里，否则会出现
                 *   "单已取消、slot_restored 还是旧值"的中间态被后续请求读到。
                 */
                let flag: Int64 = if (tx.released) { 1 } else { 0 }
                db.exec("UPDATE appointment SET slot_restored = ? WHERE id = ?",
                        [DbInt(flag), DbInt(appointmentId)])
            }
        })
        /*
         * 单没取消成功：说明事务执行的那一刻它**已经不是 `booked`** 了（并发或状态已流转）。
         * 复查后如实分派：已取消 → 幂等回报；其它状态 → 状态不允许退号。
         */
        if (!tx.cancelDone) {
            let again = findAppointment(appointmentId)
            if (again.isNone()) {
                return CancelOutcome.NotFound
            }
            let b = again.getOrThrow()
            if (b.status == "cancelled") {
                // 同上：如实回报，不要吞掉别人的 SlotNotRestored
                if (!b.slotRestored) {
                    return CancelOutcome.SlotNotRestored
                }
                return CancelOutcome.Cancelled
            }
            /*
             * ⚠ 原实现这里返回 `NotFound` —— 那是**误报**：单子明明在，只是状态不适合退
             *   （典型的：医生刚好点了"开始接诊"）。把"不能退"说成"不存在"，客户端只能提示
             *   "挂号单不存在"，患者据此**永远查不出真正原因**。
             */
            /*
             * ★ 2026-10-17：状态**仍是 `booked`** 却没退成功，只可能是上面那条
             *   `NOT EXISTS` 挡住的 —— 即"提交病历锁定"与"患者退号"并发，
             *   锁先落地。这时报 `NotCancellable('booked')` 会拼出
             *   「当前状态为「已挂号」，不能退号」这种自相矛盾的话术，
             *   使用者只会在一个永远不会成功的位置反复重试。如实报 `RecordLocked`。
             */
            if (emrHasLockedRecord(db, appointmentId)) {
                return CancelOutcome.RecordLocked
            }
            return CancelOutcome.NotCancellable(b.status)
        }
        if (!tx.released) {
            // ★ 单已取消（已提交）但号源没还回 —— 必须如实上报，不能报 false
            return CancelOutcome.SlotNotRestored
        }
        return CancelOutcome.Cancelled
    }

    /*
     * 归还某排班的号源。
     *
     * ⚠ 2026-10-07 起**不再需要**先读 version —— `releaseSlot` 已去掉 version 前置条件
     *   （见其注释：带 version 会导致并发退号永久丢号源）。
     *   所以这里只需先确认排班存在（排班被删则视为"单已取消即可"，返回 true）。
     *
     * ⚠ 必须在事务内调用：与"把单标为 cancelled"同一个事务，
     *   否则会出现"单取消了、号没还"或反之（ADR §2.2 细节 ③）。
     */
    func releaseSlotFor(scheduleId: Int64): Bool {
        let s = findSchedule(scheduleId)
        if (s.isNone()) {
            return true       // 排班被删，单已取消即可
        }
        return releaseSlot(scheduleId)
    }

    /*
     * 把"既有挂号单 id"补全成完整结果（幂等返回用）。
     * 查不到明细时退化为只带 id 的 AlreadyBooked —— 幂等语义仍成立。
     */
    func fillFromAppointment(appointmentId: Int64): BookingResult {
        let full = findAppointment(appointmentId)
        if (full.isSome()) {
            return full.getOrThrow()
        }
        let r = BookingResult()
        r.appointmentId = appointmentId
        r.outcome = BookingOutcome.AlreadyBooked(appointmentId)
        return r
    }
}
