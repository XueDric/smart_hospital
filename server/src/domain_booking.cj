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
 *
 * ⚠ 2026-10-07（P1 并发压测修正）：原值 2（= 共 3 次尝试）在
 *   「20 个并发进程抢 8 个号」下**不够** —— 实测只卖出 6 个，剩 2 个号没人抢到
 *   （失败方向是**少卖**而不是超卖，但仍然是错的）。
 *   升到安全范围上限 3（= 共 4 次尝试）。
 *
 * ⚠ 但**不要**靠无限加大重试来"解决"高并发：重试是**有代价**的
 *   （每次重试都是额外的读+写往返）。真正的处置见 ADR §3 方案 C（悲观锁）或加排队。
 *   这里的 3 是安全范围上限，不是"越大越好"。
 */
public let MAX_BOOKING_RETRY: Int64 = 3

/*
 * 挂号专用重试预算（运行时可调）。
 * HTTP 层用 bigger 的预算抗瞬时并发；单测/验收用默认值。
 */
public let HTTP_BOOKING_RETRY: Int64 = 6

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
    /*
     * ★ 退号时号源是否已归还（默认 true）。
     * 幂等路径要靠它如实回报 —— 见 `cancel()` 的注释：
     * 否则第二次退号会把第一次的 `SlotNotRestored` 告警吞成 `Cancelled`。
     */
    public var slotRestored: Bool = true
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
            "SELECT id, schedule_id, patient_id, doctor_id, department_id, " +
            "visit_date, period, seq_no, status, created_at, slot_restored " +
            "FROM appointment WHERE id = ?",
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
        r.slotRestored = rs.getInt(0, 10) != 0
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
     * ★ 核心：**一次成功**的原子扣减（不带 version 条件）。
     *
     * 返回 true = 扣号成功（受影响行数 1）；false = 号已放完（`remain_num > 0` 不成立）。
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
    public func tryDeductSlot(scheduleId: Int64): Bool {
        let n = db.exec(
            "UPDATE schedule SET remain_num = remain_num - 1, version = version + 1 " +
            "WHERE id = ? AND remain_num > 0 AND enabled = 1",
            [DbInt(scheduleId)])
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
     *
     * ⚠ 必须是 public：HTTP 层建完排班要回 `schedule_id` 给客户端，
     *   而 `exec()` 只返回受影响行数（见上面 insertAppointment 的踩坑注释）。
     */
    public func lastInsertId(): Int64 {
        let rs = db.query("SELECT LAST_INSERT_ID()", Array<DbValue>())
        if (rs.rowCount() < 1) {
            return 0
        }
        return rs.getInt(0, 0)
    }

    /* ---------- 写：排班（管理员） ---------- */

    /*
     * 新建排班（号源）。
     *
     * 新排班 `version = 0`、`remain_num = total_num` —— 与乐观锁起点一致。
     * 调用方随后用 `lastInsertId()` 取自增 id。
     */
    public func insertSchedule(doctorId: Int64, departmentId: Int64, workDate: String,
                               period: String, totalNum: Int64, now: Int64): Int64 {
        return db.exec(
            "INSERT INTO schedule " +
            "(doctor_id, department_id, work_date, period, total_num, remain_num, " +
            " version, enabled, created_at) VALUES (?, ?, ?, ?, ?, ?, 0, 1, ?)",
            [DbInt(doctorId), DbInt(departmentId), DbStr(workDate), DbStr(period),
             DbInt(totalNum), DbInt(totalNum), DbInt(now)])
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
                     now: Int64, maxRetry!: Int64 = MAX_BOOKING_RETRY): BookingResult {
        let r = BookingResult()

        // 1) 幂等快路径：该患者**当前有效**的单 → 直接返回（只读，不开事务）
        let dup = findAppointmentByToken(patientId, clientToken)
        if (dup.isSome()) {
            return fillFromAppointment(dup.getOrThrow())
        }

        // 2) 读一次排班（拿 doctor/department/就诊日快照；**version 不再参与扣号**）
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
                    if (tryDeductSlot(scheduleId)) {
                        let seq = nextSeqNo(scheduleId)
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
                r.seqNo = countBooked(scheduleId)
                r.createdAt = now
                r.outcome = BookingOutcome.Booked(tx.newId)
                return r
            }

            /*
             * 扣号返回 0 行 = **号真的放完了**（`remain_num > 0` 不成立）。
             * ⚠ 这里**不能重试**：重试只会再拿到 0 行，却把"号已售完"这个
             *   明确结论拖成"重试耗尽后的 SlotGone"—— 结果一样，但白烧预算，
             *   而且在高并发下会掩盖真正的问题（少卖就是被这个掩盖出来的）。
             */
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
            let n = db.exec(
                "UPDATE appointment SET status = 'cancelled', cancelled_at = ?, " +
                "client_token = NULL WHERE id = ? AND status <> 'cancelled'",
                [DbInt(now), DbInt(appointmentId)])
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
        // 单没取消成功（并发下别人先取消了）：复查后按幂等处理
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
     *
     * ⚠ 这里的 version 条件**保留**且是必要的：`releaseSlot` 要满足
     *   `remain_num < total_num`（防止把号源加到超过放出量），
     *   而"读 version → 归还"之间若被别的写方插进来就会拿到过期 version 失败。
     *   归还路径的并发强度远低于挂号（退号是低频操作），重试代价可接受。
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
