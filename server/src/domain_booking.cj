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
 *      见 baseline/server/third_party/qingzhou/src/dbquery.cj:492-556）。
 *   ② 成败**只看 exec() 返回的受影响行数**，绝不"先 SELECT 再 UPDATE"（那是竞态）。
 *   ③ UPDATE 与挂号单 INSERT 必须**同一个 withTransaction**。
 *
 * ⚠ 铁律（ADR §6）：withTransaction 内**绝不允许**出站网络调用（AI/HTTP）。
 *   本文件因此不 import 任何 AI/网络模块 —— 这是刻意的结构约束。
 *
 * 幂等（AC-3）用**双保险**：
 *   - 应用层：先按 client_token 查既有挂号单，命中即返回（快路径）；
 *   - 数据库层：`uk_appointment_client_token` 唯一索引兜底（并发下应用层可能都查不到，
 *     唯一索引让第二次 INSERT 直接失败，我们捕获后回读既有单）。
 *   只做应用层检查在并发重复提交下是**不够的**。
 *
 * ⚠ 仓颉语言约束（本项目已知坑，见 smart-hospital-project-brief.md §6.3）：
 *   **闭包不能捕获外部可变 `var`**（捕获的是值与 `let` 引用）。
 *   所以 withTransaction 里要回传的结果一律装在 class 的 `var` 字段里 ——
 *   见 TxSlot / TxOutcome，不要图省事去改外部 var。
 */

package qingzhou

/*
 * 乐观锁冲突重试上限（ADR §6 调参项）。
 * 安全范围 1–3；**不要**为了"看起来更稳"调大 —— 超过 3 次说明热点冲突严重，
 * 正确处置是改悲观锁或加排队，而不是加重试。
 *
 * ⚠ 必须声明在使用它的 book() **之前**：仓颉不做顶层声明提升
 *   （放文件末尾会报 "variable 'X' is used before being defined"）。
 */
public let MAX_BOOKING_RETRY: Int64 = 2

/* ===================== 结果类型 ===================== */

/*
 * 挂号结果。
 * 用枚举而不是"抛异常/返回 null"来表达业务失败 —— 号源被抢走是**正常业务结果**，
 * 不是程序错误；把它做成异常会让调用方分不清"业务失败"与"数据库炸了"。
 */
public enum BookingOutcome {
    | Booked(Int64)                        // 成功，携带挂号单 id
    | AlreadyBooked(Int64)                 // 幂等命中，携带既有挂号单 id
    | SlotGone                             // 号源已变/已满（乐观锁冲突或 remain_num=0）
    | ScheduleNotFound                     // 排班不存在或未启用
}

/*
 * 取消（退号）结果 —— **三态**，刻意不用 Bool。
 *
 * 理由见 `cancel()` 的注释：把"单子取消了"与"号还回去了"压进一个 bool，
 * 必然丢掉"单已取消但号未归还"这一真实存在的中间状态，导致对外**报错方向与事实相反**。
 */
public enum CancelOutcome {
    | Cancelled                            // 单已取消，且号源已归还（或本就无需归还）
    | SlotNotRestored                     // ★ 单**已取消**，但号源未归还（需运维介入）
    | NotFound                            // 挂号单不存在
}

/*
 * 排班行（读模型）。
 * ⚠ 只读快照，不参与写入决策 —— 版本号可能在你拿到它的一瞬间就变了（这正是乐观锁的前提）。
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

    /* 按 id 读排班；不存在返回 None。 */
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

    /* 按 client_token 查既有挂号单 id；不存在返回 None（幂等快路径）。 */
    public func findAppointmentByToken(clientToken: String): ?Int64 {
        if (clientToken.size == 0) {
            return None
        }
        let rs = db.query(
            "SELECT id FROM appointment WHERE client_token = ?", [DbStr(clientToken)])
        if (rs.rowCount() < 1) {
            return None
        }
        return Some(rs.getInt(0, 0))
    }

    /* 读挂号单明细。 */
    public func findAppointment(appointmentId: Int64): ?BookingResult {
        let rs = db.query(
            "SELECT id, schedule_id, patient_id, doctor_id, department_id, " +
            "visit_date, period, seq_no, status, created_at FROM appointment WHERE id = ?",
            [DbInt(appointmentId)])
        if (rs.rowCount() < 1) {
            return None
        }
        let r = BookingResult()
        r.appointmentId = rs.getInt(0, 0)
        r.scheduleId = rs.getInt(0, 1)
        r.patientId = rs.getInt(0, 2)
        r.doctorId = rs.getInt(0, 3)
        r.departmentId = rs.getInt(0, 4)
        r.visitDate = rs.getString(0, 5)
        r.period = rs.getString(0, 6)
        r.seqNo = rs.getInt(0, 7)
        r.status = rs.getString(0, 8)
        r.createdAt = rs.getInt(0, 9)
        r.outcome = BookingOutcome.AlreadyBooked(r.appointmentId)
        return Some(r)
    }

    /* 某排班已占用的号数（用于生成就诊序号）。 */
    public func countBooked(scheduleId: Int64): Int64 {
        let rs = db.query(
            "SELECT COUNT(*) FROM appointment WHERE schedule_id = ? AND status <> 'cancelled'",
            [DbInt(scheduleId)])
        if (rs.rowCount() < 1) {
            return 0
        }
        return rs.getInt(0, 0)
    }

    /* ---------- 写：原子扣号 ---------- */

    /*
     * ★ 核心：带乐观锁的原子扣减。
     *
     * 返回 true = 扣号成功（受影响行数 1）；false = 号源已变或已满。
     *
     * 为什么这一条 SQL 就是并发安全的全部：
     *   InnoDB 对该行的 UPDATE 会加行锁，`version = ?` 与 `remain_num > 0`
     *   在**同一个语句**里被求值 —— 两个并发请求里只有一个能满足 version 条件，
     *   另一个受影响行数为 0。不存在"检查与修改之间"的窗口。
     *
     * ⚠ 必须有 `remain_num > 0`：只靠 version 无法阻止"号已放完但 version 未变"
     *   （例如管理员手工把 remain_num 改成 0）。这条条件保证**永不出现负数**（AC-2）。
     */
    public func tryDeductSlot(scheduleId: Int64, expectedVersion: Int64): Bool {
        let n = db.exec(
            "UPDATE schedule SET remain_num = remain_num - 1, version = version + 1 " +
            "WHERE id = ? AND version = ? AND remain_num > 0 AND enabled = 1",
            [DbInt(scheduleId), DbInt(expectedVersion)])
        return n == 1
    }

    /*
     * 归还号源（退号 / 取消）。
     * 同样带 version 条件；`remain_num < total_num` 防止归还超过放出量
     * （否则反复"挂号→退号"可以把号源刷到超过总数）。
     */
    public func releaseSlot(scheduleId: Int64, expectedVersion: Int64): Bool {
        let n = db.exec(
            "UPDATE schedule SET remain_num = remain_num + 1, version = version + 1 " +
            "WHERE id = ? AND version = ? AND remain_num < total_num",
            [DbInt(scheduleId), DbInt(expectedVersion)])
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
     *   正确做法：INSERT 后紧跟一条 `SELECT LAST_INSERT_ID()`。
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
        db.exec(
            "INSERT INTO appointment " +
            "(schedule_id, patient_id, doctor_id, department_id, visit_date, period, " +
            " seq_no, status, client_token, created_at, cancelled_at) " +
            "VALUES (?, ?, ?, ?, ?, ?, ?, 'booked', ?, ?, 0)",
            [DbInt(scheduleId), DbInt(patientId), DbInt(doctorId), DbInt(departmentId),
             DbStr(visitDate), DbStr(period), DbInt(seqNo), DbStr(clientToken), DbInt(now)])
        return lastInsertId()
    }

    /*
     * 取本连接上一次 INSERT 生成的自增 id。
     * 与 insertAppointment 同一连接、紧邻调用，故 LAST_INSERT_ID() 语义成立。
     */
    func lastInsertId(): Int64 {
        let rs = db.query("SELECT LAST_INSERT_ID()", Array<DbValue>())
        if (rs.rowCount() < 1) {
            return 0
        }
        return rs.getInt(0, 0)
    }

    /* ---------- 写：幂等记录 ---------- */

    /*
     * 幂等键：`idemKey("booking", patientId, clientToken)`。
     * 口径沿用基线（baseline/server/src/store.cj:136 的 IdemRecord、
     * store_queries.cj:373 的 idemKey），但**落在本侧自己的 `booking_idem` 表** ——
     * 基线内存 Store 已占用 `idem` 表名且列定义不同（见 schema.cj 文件头）。
     */
    public func idemKey(kind: String, actorId: Int64, token: String): String {
        return "${kind}:${actorId}:${token}"
    }

    /*
     * 登记幂等键。已存在则返回 false（调用方据此判定重复提交）。
     * 24h 窗口由调用方按 now 清理（见 pruneIdem）。
     */
    public func putIdem(key: String, now: Int64): Bool {
        if (key.size == 0) {
            return true
        }
        let n = db.exec(
            "INSERT IGNORE INTO booking_idem (idem_key, created_at) VALUES (?, ?)",
            [DbStr(key), DbInt(now)])
        return n == 1
    }

    /* 清理过期幂等键，返回删除行数。窗口默认 24h。 */
    public func pruneIdem(now: Int64, windowSeconds!: Int64 = 86400): Int64 {
        return db.exec("DELETE FROM booking_idem WHERE created_at < ?",
                       [DbInt(now - windowSeconds)])
    }

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
     * ⚠ 失败重试是**重读 version 后重试**，不是盲目重发同一条 SQL
     *   （盲目重发只会用同一个过期 version 再失败一次）。
     *
     * ⚠ 重试上限 MAX_BOOKING_RETRY 默认 2（ADR §6 安全范围 1–3）。
     *   超过上限说明热点冲突严重，应改方案 C（悲观锁）或加排队 ——
     *   **不要靠加大重试次数掩盖**（那只是把失败换成更长的延迟）。
     */
    public func book(patientId: Int64, scheduleId: Int64, clientToken: String,
                     now: Int64, maxRetry!: Int64 = MAX_BOOKING_RETRY): BookingResult {
        let r = BookingResult()

        // 1) 幂等快路径：同 token 已有单 → 直接返回既有单（只读，不开事务）
        let dup = findAppointmentByToken(clientToken)
        if (dup.isSome()) {
            return fillFromAppointment(dup.getOrThrow())
        }

        // 2) 扣号 + 写单，失败则**重读 version** 后重试
        var attempt: Int64 = 0
        while (attempt <= maxRetry) {
            let cur = findSchedule(scheduleId)
            if (cur.isNone()) {
                r.outcome = BookingOutcome.ScheduleNotFound
                return r
            }
            let s = cur.getOrThrow()
            if (!s.enabled) {
                r.outcome = BookingOutcome.ScheduleNotFound
                return r
            }

            // ★ 事务：扣号 + 写单必须同事务（ADR §2.2 细节 ③）。
            // 结果经 TxResult 回传 —— 仓颉闭包不能捕获外部可变 var。
            let tx = TxResult()
            try {
                db.withTransaction({ =>
                    if (tryDeductSlot(scheduleId, s.version)) {
                        let seq = countBooked(scheduleId) + 1
                        tx.newId = insertAppointment(scheduleId, patientId, s.doctorId,
                                                     s.departmentId, s.workDate, s.period,
                                                     seq, clientToken, now)
                        tx.booked = true
                    }
                })
            } catch (e: Exception) {
                // 唯一索引冲突 = 并发重复提交（另一条同 token 的单刚插进去）
                // → 回读既有单返回幂等结果；**不是**幂等冲突就原样抛出，不吞
                let again = findAppointmentByToken(clientToken)
                if (again.isSome()) {
                    return fillFromAppointment(again.getOrThrow())
                }
                throw e
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
                r.seqNo = countBooked(scheduleId)
                r.createdAt = now
                r.outcome = BookingOutcome.Booked(tx.newId)
                return r
            }

            // 扣号失败：号满则重试无意义，直接判 SlotGone；否则重读 version 再试
            let re = findSchedule(scheduleId)
            if (re.isNone()) {
                r.outcome = BookingOutcome.ScheduleNotFound
                return r
            }
            if (re.getOrThrow().remainNum <= 0) {
                r.outcome = BookingOutcome.SlotGone
                return r
            }
            attempt = attempt + 1
        }

        r.outcome = BookingOutcome.SlotGone
        return r
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
     * 两件事的状态被压进一个 bool，就必然丢失信息。改为三态：
     *   · `Cancelled`        —— 单已取消且号已归还（正常路径）
     *   · `SlotNotRestored`  —— **单已取消**（已提交，不可回滚），但号源未归还
     *                           → 调用方应告知用户"已退号"，并把号源不一致**记进运维告警**，
     *                             由管理员用重置号源修，**不要**让用户重复点击退号
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
            return CancelOutcome.Cancelled       // 幂等
        }
        let tx = TxResult()
        db.withTransaction({ =>
            let n = db.exec(
                "UPDATE appointment SET status = 'cancelled', cancelled_at = ? " +
                "WHERE id = ? AND status <> 'cancelled'",
                [DbInt(now), DbInt(appointmentId)])
            if (n == 1) {
                tx.cancelDone = true
                tx.released = releaseSlotFor(a.scheduleId)
            }
        })
        // 单没取消成功（并发下别人先取消了）：复查后按幂等处理
        if (!tx.cancelDone) {
            let again = findAppointment(appointmentId)
            if (again.isNone()) {
                return CancelOutcome.NotFound
            }
            if (again.getOrThrow().status == "cancelled") {
                return CancelOutcome.Cancelled
            }
            return CancelOutcome.NotFound
        }
        if (!tx.released) {
            // ★ 单已取消（已提交）但号源没还回 —— 必须如实上报，不能报 false
            return CancelOutcome.SlotNotRestored
        }
        return CancelOutcome.Cancelled
    }

    /*
     * 归还某排班的号源（读当前 version 后再还）。
     * ⚠ 必须在事务内调用：读 version 与归还之间不能有其它写方插进来，
     *   否则会拿着过期 version 归还失败。
     */
    func releaseSlotFor(scheduleId: Int64): Bool {
        let s = findSchedule(scheduleId)
        if (s.isNone()) {
            return true       // 排班被删，单已取消即可
        }
        return releaseSlot(scheduleId, s.getOrThrow().version)
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
