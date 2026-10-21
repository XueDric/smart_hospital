/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 *
 * domain_booking.cj —— 号源与挂号域：扣减、退号、幂等、排班维护。
 *
 * 号源扣减与归还只走参数化原子 UPDATE（remain_num = remain_num - 1 / + 1，
 * WHERE remain_num > 0 / remain_num < total_num），成败只看 exec() 受影响行数。
 * 扣号与 INSERT 挂号单必须同一个 withTransaction；事务内禁止出站网络调用（AI/HTTP）。
 * 幂等按患者隔离：(patient_id, client_token) 有效单快路径 + uk_appointment_patient_token 唯一索引兜底。
 */

package qingzhou

/* import std.collection.*：列表查询要用 ArrayList，漏了报 undeclared identifier 'ArrayList'。 */
import std.collection.*

/* 挂号单列清单：唯一出处，fillFromRow 的下标顺序只按这一份写，改列必须同时改下标；复制多份错位不报错只读错列。 */
let APPT_COLS: String =
    "id, schedule_id, patient_id, doctor_id, department_id, " +
    "visit_date, period, seq_no, status, created_at, slot_restored, " +
    "arrived_at, started_at, finished_at "

/* 瞬时错误（死锁 / 锁等待超时）重试上限；重试仍失败原样抛出，调大它解决不了并发少卖。 */
public let MAX_BOOKING_RETRY: Int64 = 3

/* HTTP 层重试预算；语义与 MAX_BOOKING_RETRY 重复，仅因调用点暂留，不是可多试几次。 */
public let HTTP_BOOKING_RETRY: Int64 = 6

/*
 * 患者可售谓词：启用、AM/PM、日期形状与日历、科室医生有效且归属一致；EXISTS 不扩展列；日期占位符由调用方绑定，不用库时区。
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

/* 挂号结果：号源被抢空是正常业务结果，用枚举而非异常/null，免得分不清业务失败与数据库故障。 */
public enum BookingOutcome {
    | Booked(Int64)
    | AlreadyBooked(Int64)
    | SlotGone
    | ScheduleNotFound
}

/*
 * 退号结果五态，不用 Bool：「单已取消」与「号已归还」分开；404 与 409 处置、话术不同。
 */
public enum CancelOutcome {
    | Cancelled
    | SlotNotRestored
    | NotCancellable(String)
    | RecordLocked
    | NotFound
}

/* 排班读模型：只读快照，不参与写入决策，版本号随时可变。 */
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
 * 改排班三种失败必须分开：notFound(404) / conflict(409 刷新重试) / tooSmall(400 业务错误)。
 */
public class ScheduleUpdateOutcome {
    public var ok: Bool = false
    public var notFound: Bool = false
    public var conflict: Bool = false
    public var tooSmall: Bool = false
    public var booked: Int64 = 0
    public var totalNum: Int64 = 0
    public var remainNum: Int64 = 0
    public var version: Int64 = 0
    public var enabled: Bool = true
}

/* 挂号结果明细（供上层出参）。 */
public class BookingResult {
    public var outcome: BookingOutcome = BookingOutcome.SlotGone
    public var appointmentId: Int64 = 0
    public var scheduleId: Int64 = 0
    public var patientId: Int64 = 0
    public var doctorId: Int64 = 0
    public var departmentId: Int64 = 0
    public var visitDate: String = ""
    public var period: String = "AM"
    public var seqNo: Int64 = 0
    public var status: String = "booked"
    public var createdAt: Int64 = 0
    /* 退号时号源是否已归还；幂等路径必须如实回报，否则重试会把 SlotNotRestored 告警吞成 Cancelled。 */
    public var slotRestored: Bool = true
    /* 到院 / 开始接诊 / 完成三列（epoch 秒，0 = 未发生）；前端自记换设备即丢，只能在库里。 */
    public var arrivedAt: Int64 = 0
    public var startedAt: Int64 = 0
    public var finishedAt: Int64 = 0
}

/* 事务内结果载体：仓颉闭包不能捕获外部可变 var，结果一律写进 let 捕获对象的字段。 */
class TxResult {
    var booked: Bool = false
    var newId: Int64 = 0
    var released: Bool = false
    var cancelDone: Bool = false
    /* 实际写进库的就诊序号（MAX(seq_no)+1），必须回传供响应回填；用 countBooked() 另算会报错号。 */
    var seqNo: Int64 = 0
}

/* 号源域仓储 */

/* 唯一允许对 schedule / appointment 写直接 SQL 的地方；构造注入 DbBackend 便于单测替换。 */
public class BookingRepo {
    private let db: DbBackend

    public init(db: DbBackend) {
        this.db = db
    }

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
     * 查 (患者, client_token) 的有效单（status <> 'cancelled'）：必须按患者隔离，全局查 token 会跨患者泄露并误报成功。
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
        return Some(fillFromRow(rs, 0))
    }

    /* 默认只返回有效单（includeCancelled 看历史）；排序 created_at DESC, id DESC；patientId 必须取自令牌否则越权。 */
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

    /* 可选按科室 / 就诊日筛选；患者视图走共同可售谓词；不隐藏 remain_num = 0，否则患者以为没排班。 */
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

    /* 把结果集第 i 行装配成 BookingResult；列顺序只此一处，下标与 APPT_COLS 必须同步。 */
    /* 按 id + doctor_id 读单；不存在与不属于该医生都返回 None，区分 403/404 会成存在性 oracle。 */
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
     * 医生接诊队列（不含已退号）：先按状态优先级（到院→候诊→接诊中→已挂号→已完成→爽约），
     * 再按 visit_date / period / seq_no；最后 id ASC 必需 —— 排序键无唯一约束又带 LIMIT，
     * 并列时同一请求会返回不同集合。
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

    /* 写：原子扣号 */

    /*
     * 一次成功的原子扣减：remain_num = remain_num - 1 与守卫 remain_num > 0 在同一条 UPDATE 内由 InnoDB
     * 原子求值，不会丢更新也不会减成负数；返回 true 即受影响行数为 1。
     * 不带 version 前置条件：判定与写入同语句，乐观锁在此只让并发互相作废；version 列仍 +1 供管理端编辑。
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
     * 归还号源：守卫 remain_num < total_num 保证不超过放出量；不带 version —— 带 version 且无重试会让号源永久丢失。
     */
    public func releaseSlot(scheduleId: Int64): Bool {
        let n = db.exec(
            "UPDATE schedule SET remain_num = remain_num + 1, version = version + 1 " +
            "WHERE id = ? AND remain_num < total_num",
            [DbInt(scheduleId)])
        return n == 1
    }

    /*
     * 插入挂号单并返回自增 id（execInsert 同临界区取 ID）；visit_date 写调用方快照，并发撞唯一索引由 book() 回读。
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

    /* 按 (doctor_id, work_date, period) 判存在，不含 enabled；否则同时段重复建排班会让号源翻倍。 */
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

    /* 新排班 remain_num = total_num、version = 0；返回本次 INSERT 生成 ID，不随后另读 LAST_INSERT_ID。 */
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
     * 改放号数与停诊（PATCH 语义）：一条原子 UPDATE 同时做 version 乐观锁、守卫放号数不得小于已约数
     * （remain_num + (? - total_num) >= 0，同语句求值）、余量同步加减不变；SET 里 remain_num 必须写在 total_num 之前。
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
        /* 影响 0 行时回读分辨原因：先判存在、再判版本、最后判放号数太小，不猜。 */
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
                    /* 三类都不是却 0 行 ⇒ 读与写之间被改过又改回，按冲突处理，不报成功。 */
                    out.conflict = true
                }
        }
        return out
    }

    /*
     * 挂号主流程：幂等快路径 → 读可售排班 → 事务内原子扣号 + INSERT；重试只给瞬时错误，冲突与 0 行先复查幂等键。
     */
    public func book(patientId: Int64, scheduleId: Int64, clientToken: String,
                     now: Int64, maxRetry!: Int64 = MAX_BOOKING_RETRY,
                     today!: String = ""): BookingResult {
        let r = BookingResult()
        /* today 仅供验收夹具注入写死的排班日期，生产路径不传，语义与注入前一致。 */
        let todayDate = if (today.size > 0) { today } else { hDateStringOf(now) }

        let dup = findAppointmentByToken(patientId, clientToken)
        if (dup.isSome()) {
            return fillFromAppointment(dup.getOrThrow())
        }

        var attempt: Int64 = 0
        while (attempt <= maxRetry) {
            let cur = findBookableSchedule(scheduleId, today: todayDate)
            if (cur.isNone()) {
                r.outcome = BookingOutcome.ScheduleNotFound
                return r
            }
            let s = cur.getOrThrow()

            let tx = TxResult()
            try {
                db.withTransaction({ =>
                    if (tryDeductSlot(scheduleId, today: todayDate)) {
                        /*
                         * 必须把实际写入的 seq 存进 tx 回填：countBooked() 统计当前有效单数，口径不同会报错号。
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
                 * 唯一索引冲突 = 并发重复提交，回读既有单；其它异常可重试，耗尽后原样抛出绝不吞。
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
                r.visitDate = s.workDate
                r.period = s.period
                r.status = "booked"
                r.seqNo = tx.seqNo
                r.createdAt = now
                r.outcome = BookingOutcome.Booked(tx.newId)
                return r
            }

            /*
             * 扣号 0 行不能重试，但必须先复查幂等键再分类，否则并发同 token 重发会收到 409，一次挂号变两次。
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
     * 下一个序号 = MAX(seq_no) + 1（COUNT + 1 会与在座号撞号）；无唯一约束兜底，极端并发可能重号，只作叫号展示。
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
     * 取消挂号并归还号源（在线路径，不进离线队列），返回五态而非 Bool：「单已取消但号未归还」是真实中间态，
     * 压进 bool 会对外报反方向；NotCancellable(409) 与 NotFound(404) 分开；已取消的单重复取消不动号源。
     */
    public func cancel(appointmentId: Int64, now: Int64): CancelOutcome {
        let found = findAppointment(appointmentId)
        if (found.isNone()) {
            return CancelOutcome.NotFound
        }
        let a = found.getOrThrow()
        if (a.status == "cancelled") {
            /* 幂等路径必须如实回报上次的 slot_restored，否则用户重试会把 SlotNotRestored 告警抹掉。 */
            if (!a.slotRestored) {
                return CancelOutcome.SlotNotRestored
            }
            return CancelOutcome.Cancelled
        }
        /*
         * 退号必须走状态机：只有 booked 可退，其它状态退号会覆盖就诊结果并凭空多出号源。
         * 判据唯一来自 domain_emr.cj 的 visitTransitionAllowed；前置判断只为对外结果，护栏是带 status 的原子 UPDATE。
         */
        if (!visitTransitionAllowed(a.status, VISIT_CANCELLED)) {
            return CancelOutcome.NotCancellable(a.status)
        }
        /*
         * 病历已定稿（locked）的单不能退号：否则病历成孤儿，该单永远走不到 done；草稿仍可退。
         */
        if (emrHasLockedRecord(db, appointmentId)) {
            return CancelOutcome.RecordLocked
        }
        let tx = TxResult()
        db.withTransaction({ =>
            /*
             * 退号必须释放幂等键（client_token 置 NULL），否则同 token 重挂撞 (patient_id, client_token) 唯一键报 500；
             * 唯一索引允许多个 NULL，空串不行。
             */
            /*
             * NOT EXISTS 才是真护栏（与 finish 同源）：前置 SELECT 挡不住并发，放进 WHERE 才能关窗。
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
                /* slot_restored 必须与 status 在同一事务内更新，否则会露出「单已取消但标记仍旧」的中间态。 */
                let flag: Int64 = if (tx.released) { 1 } else { 0 }
                db.exec("UPDATE appointment SET slot_restored = ? WHERE id = ?",
                        [DbInt(flag), DbInt(appointmentId)])
            }
        })
        /* 未取消成功说明执行时已不是 booked：已取消则幂等回报，其它状态如实报不可退。 */
        if (!tx.cancelDone) {
            let again = findAppointment(appointmentId)
            if (again.isNone()) {
                return CancelOutcome.NotFound
            }
            let b = again.getOrThrow()
            if (b.status == "cancelled") {
                if (!b.slotRestored) {
                    return CancelOutcome.SlotNotRestored
                }
                return CancelOutcome.Cancelled
            }
            /*
             * 返回 NotFound 是误报；状态仍为 booked 却没退成功只可能是病历锁定抢在前面，必须报 RecordLocked。
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

    /* 归还某排班号源：排班被删视为已取消即可；必须与「标 cancelled」同一事务，否则号会漏还。 */
    func releaseSlotFor(scheduleId: Int64): Bool {
        let s = findSchedule(scheduleId)
        if (s.isNone()) {
            return true
        }
        return releaseSlot(scheduleId)
    }

    /* 把既有挂号单 id 补成完整结果；查不到明细退化为只带 id 的 AlreadyBooked，幂等语义仍成立。 */
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
