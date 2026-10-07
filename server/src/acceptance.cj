/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 *
 * ===== acceptance.cj —— P0 验收测试（对应 ADR-0001 §5 的 AC-1…AC-6）======
 *
 * 设计原则：**只验证能真验证的，并如实标注验证方式的边界。**
 *
 * ⚠ 关于并发验证的诚实说明：
 *   本仓库（框架 + 应用）**通篇没有 `spawn`**，仓颉 1.2.0 的多线程能力在本项目中
 *   尚无既有用法可循。因此 **AC-1 不做多线程并发测试**，而是做
 *   **数据库层的原子性判定**（两条带同一 version 的 UPDATE，断言受影响行数恰为 [1,0]）。
 *
 *   这**不是**"并发测试"，也**不冒充**并发测试：
 *   · 它证明的是「同一条 UPDATE 在 version 已过期时必然返回 0 行」——
 *     这是 InnoDB 行内原子判定，正是并发安全的**根因**；
 *   · 真正的并发压测应在 P1 有了 HTTP 接口之后，用多个独立进程打同一号源
 *     （那才是真实的并发路径）。届时补测，本文件的 AC-1 保留为"原子性"证据。
 *
 * ⚠ 结构说明（为什么要有 TestRunner 类）：
 *   验收逻辑**不能**写成"外层 var 计数 + 嵌套闭包"的形式 —— 仓颉会报
 *   `lambda captured a mutable variable transitively, lambda cannot be used as a param`。
 *   所以计数与断言收敛成 `TestRunner` 的**类字段/方法**，闭包只捕获 `this`（不可变）。
 *   这是本项目第二次踩这个语言约束（第一次在 domain_booking.cj 的 TxResult）。
 *
 * 每个用例自带清理：用**固定 id 的独立排班**隔离，避免相互污染。
 */

package qingzhou

import std.time.*

/* 测试用当前时间（epoch 秒）。用 h_ 前缀避免与框架顶层名冲突。 */
func hNowEpoch(): Int64 {
    return DateTime.now().toUnixTimeStamp().toSeconds()
}

/*
 * 清空业务表（仅测试用）。顺序：先子后父 —— 本 schema 未建外键，
 * 但保持顺序可在将来加外键时不返工。
 */
func hResetAll(db: DbBackend): Unit {
    db.exec("DELETE FROM appointment", Array<DbValue>())
    db.exec("DELETE FROM medical_record", Array<DbValue>())
    db.exec("DELETE FROM schedule", Array<DbValue>())
    db.exec("DELETE FROM doctor", Array<DbValue>())
    db.exec("DELETE FROM department", Array<DbValue>())
    db.exec("DELETE FROM patient", Array<DbValue>())
}

/*
 * 建一个测试排班（显式 id，便于用例可读）。返回 (scheduleId, patientId, doctorId, deptId)。
 *
 * ⚠ 用 `INSERT IGNORE`：P0 的用例每次都会重建部门/医生/患者（id 固定为 1），
 *   而 P1 的 HTTP 联调也往同一库写——若用裸 INSERT，第二次跑 accept 就会
 *   因主键冲突整段失败。IGNORE 让"基础数据已存在"变成无害的前置条件。
 */
func hSeedSchedule(db: DbBackend, scheduleId: Int64, total: Int64,
                   workDate: String): (Int64, Int64, Int64, Int64) {
    let now = hNowEpoch()
    db.exec("INSERT IGNORE INTO department (id, name, code, created_at) VALUES (?, ?, ?, ?)",
            [DbInt(1), DbStr("内科"), DbStr("NK"), DbInt(now)])
    db.exec("INSERT IGNORE INTO doctor (id, name, department_id, title, created_at) " +
            "VALUES (?, ?, ?, ?, ?)",
            [DbInt(1), DbStr("张医生"), DbInt(1), DbStr("主任医师"), DbInt(now)])
    db.exec("INSERT IGNORE INTO patient (id, phone, name, created_at) VALUES (?, ?, ?, ?)",
            [DbInt(1), DbStr("13800000000"), DbStr("测试患者"), DbInt(now)])
    db.exec("INSERT INTO schedule (id, doctor_id, department_id, work_date, period, " +
            "total_num, remain_num, version, enabled, created_at) " +
            "VALUES (?, ?, ?, ?, ?, ?, ?, 0, 1, ?)",
            [DbInt(scheduleId), DbInt(1), DbInt(1), DbStr(workDate), DbStr("AM"),
             DbInt(total), DbInt(total), DbInt(now)])
    return (scheduleId, 1, 1, 1)
}

/* 读某排班当前 (remain_num, version)。 */
func hScheduleState(db: DbBackend, scheduleId: Int64): (Int64, Int64) {
    let rs = db.query("SELECT remain_num, version FROM schedule WHERE id = ?",
                      [DbInt(scheduleId)])
    if (rs.rowCount() < 1) {
        return (-1, -1)
    }
    return (rs.getInt(0, 0), rs.getInt(0, 1))
}

/* 读某排班下的挂号单条数。 */
func hAppointmentCount(db: DbBackend, scheduleId: Int64): Int64 {
    let rs = db.query("SELECT COUNT(*) FROM appointment WHERE schedule_id = ?",
                      [DbInt(scheduleId)])
    if (rs.rowCount() < 1) {
        return 0
    }
    return rs.getInt(0, 0)
}

/* 读某挂号单的 visit_date（快照）。 */
func hVisitDate(db: DbBackend, appointmentId: Int64): String {
    let rs = db.query("SELECT visit_date FROM appointment WHERE id = ?",
                      [DbInt(appointmentId)])
    if (rs.rowCount() < 1) {
        return ""
    }
    return rs.getString(0, 0)
}

/* ===================== 测试运行器 ===================== */

/*
 * 断言与计数收敛为类字段/方法 —— 绕开"闭包传递性捕获可变变量"的语言约束。
 * 见文件头说明。
 */
public class TestRunner {
    private let db: DbBackend
    private let repo: BookingRepo
    public var failed: Int64 = 0
    public var passed: Int64 = 0

    public init(db: DbBackend) {
        this.db = db
        this.repo = BookingRepo(db)
    }

    /* 一条断言。 */
    public func check(name: String, ok: Bool): Unit {
        if (ok) {
            println("  [PASS] ${name}")
            passed = passed + 1
        } else {
            println("  [FAIL] ${name}")
            failed = failed + 1
        }
    }

    /*
     * 跑一个用例段：**任何异常都记为该段失败，而不是让整个测试进程崩掉**。
     *
     * 为什么必须有这层：实测过一次 —— 去掉 `version = ?` 乐观锁条件后，
     * `bindSql` 因「占位符数与参数数不等」直接抛异常，测试**没有输出任何 [FAIL]**
     * 就中断了。那种"崩掉"看起来像环境问题，而真相是断言本该失败。
     * 测试工具必须把失败**说清楚**，不能靠崩溃来"顺带"表明有问题。
     */
    public func section(name: String, body: () -> Unit): Unit {
        try {
            body()
        } catch (e: Exception) {
            println("  [FAIL] ${name} 抛出异常（该用例判失败）：${e.message}")
            failed = failed + 1
        }
    }

    /* ---------- AC-2 ---------- */
    public func ac2(): Unit {
        println("=== AC-2 号满不超卖 ===")
        section("AC-2", { =>
            hSeedSchedule(db, 9001, 0, "2026-10-08")     // total=0, remain=0
            let deducted = repo.tryDeductSlot(9001)
            let (remain, ver) = hScheduleState(db, 9001)
            check("remain_num=0 时扣减返回 false", !deducted)
            check("扣减失败后 remain_num 仍为 0（未变负）", remain == 0)
            check("扣减失败后 version 未变（仍为 0）", ver == 0)
        })
    }

    /* ---------- AC-1 ---------- */
    public func ac1(): Unit {
        println("=== AC-1 原子扣减：每单位号源恰被扣一次 ===")
        section("AC-1", { =>
            hResetAll(db)
            hSeedSchedule(db, 9002, 5, "2026-10-08")
            /*
             * ⚠ 本用例在 2026-10-07 被**改写**，因为扣号策略本身改了：
             *   原先用 `version = ?` 乐观锁，断言是"同一 version 的第二次扣减必失败"。
             *   实测那个策略在"请求数≈号源数"时少卖 15%~50%（见 tryDeductSlot 注释），
             *   已改成**无 version 条件的原子自减** —— 于是"同一 version 第二次也成功"
             *   成为**正确行为**，旧断言反而会挡住修复。
             *
             * 现在的断言聚焦真正的不变量：**扣减次数恰好等于号源数，且永不为负**。
             */
            var ok: Int64 = 0
            var i: Int64 = 0
            while (i < 5) {
                if (repo.tryDeductSlot(9002)) {
                    ok = ok + 1
                }
                i = i + 1
            }
            let (remain, ver) = hScheduleState(db, 9002)
            check("5 次扣减全部成功（恰好等于号源数）", ok == 5)
            check("remain_num 归零（5 → 0）", remain == 0)
            check("version 随每次成功 +1（0 → 5）", ver == 5)
            // 第 6 次必须失败（号已售完）
            check("第 6 次扣减失败（号已售完，不超卖）", !repo.tryDeductSlot(9002))
            let (remain2, _) = hScheduleState(db, 9002)
            check("售完后 remain_num 仍为 0（未变负）", remain2 == 0)
        })
    }

    /* ---------- AC-10：最穷工况不少卖（第三方复查发现的严重缺陷）---------- */
    public func ac10(): Unit {
        println("=== AC-10 请求数 == 号源数时**不得少卖** ===")
        section("AC-10", { =>
            /*
             * 这是 2026-10-07 复查复现出来的**严重缺陷**的回归闸门：
             * 原乐观锁策略在 N 并发抢 N 号时只卖出 15%~50%（20→15、40→26）。
             *
             * ⚠ 本用例是**单线程顺序**模拟（Cangjie 侧无 spawn，真并发由
             *   tests\stress-booking.ps1 用独立进程覆盖）。它守的是
             *   「扣号策略本身不再自我作废」这条不变量 ——
             *   乐观锁时代这条断言**必然失败**（第二次带旧 version 就 0 行）。
             */
            hResetAll(db)
            let n: Int64 = 20
            hSeedSchedule(db, 9008, n, "2026-10-08")
            var ok: Int64 = 0
            var i: Int64 = 0
            while (i < n) {
                if (repo.tryDeductSlot(9008)) {
                    ok = ok + 1
                }
                i = i + 1
            }
            let (remain, _) = hScheduleState(db, 9008)
            check("N 次扣减全部成功（无自我作废）", ok == n)
            check("余量为 0（卖光）", remain == 0)
        })
    }

    /* ---------- AC-5 ---------- */
    public func ac5(): Unit {
        println("=== AC-5 失败不留下部分状态 ===")
        section("AC-5", { =>
            hResetAll(db)
            hSeedSchedule(db, 9003, 1, "2026-10-08")
            let a = repo.book(1, 9003, "tok-ac5-a", hNowEpoch())   // 抢走唯一号
            let b = repo.book(1, 9003, "tok-ac5-b", hNowEpoch())   // 号已满 → 必然失败
            let (remain, _) = hScheduleState(db, 9003)
            let count = hAppointmentCount(db, 9003)
            check("首个挂号成功", isBooked(a))
            check("第二个挂号返回 SlotGone", isSlotGone(b))
            check("失败后 remain_num 为 0（未被扣成负）", remain == 0)
            check("失败后挂号单仍只有 1 张（未留脏单）", count == 1)
        })
    }

    /* ---------- AC-3 ---------- */
    public func ac3(): Unit {
        println("=== AC-3 幂等：同 token 只出一张单 ===")
        section("AC-3", { =>
            hResetAll(db)
            hSeedSchedule(db, 9004, 3, "2026-10-08")
            let tok = "tok-ac3-fixed"
            let a = repo.book(1, 9004, tok, hNowEpoch())
            let b = repo.book(1, 9004, tok, hNowEpoch())          // 重复提交
            let count = hAppointmentCount(db, 9004)
            let (remain, _) = hScheduleState(db, 9004)
            check("首次挂号成功", isBooked(a))
            check("重复提交返回 AlreadyBooked", isAlreadyBooked(b))
            check("两次提交指向同一张单", a.appointmentId == b.appointmentId)
            check("库中只有 1 张单", count == 1)
            check("号源只被扣 1 次（3 → 2）", remain == 2)
        })
    }

    /* ---------- AC-6 ---------- */
    public func ac6(): Unit {
        println("=== AC-6 顺延不串号（visit_date 快照）===")
        section("AC-6", { =>
            hResetAll(db)
            hSeedSchedule(db, 9005, 3, "2026-10-08")
            let a = repo.book(1, 9005, "tok-ac6", hNowEpoch())
            let before = hVisitDate(db, a.appointmentId)
            // 管理员一键顺延排班：2026-10-08 → 2026-10-15
            db.exec("UPDATE schedule SET work_date = ?, version = version + 1 WHERE id = ?",
                    [DbStr("2026-10-15"), DbInt(9005)])
            let after = hVisitDate(db, a.appointmentId)
            let schedDate = db.query("SELECT work_date FROM schedule WHERE id = ?",
                                     [DbInt(9005)]).getString(0, 0)
            check("挂号时 visit_date 快照 = 排班当日", before == "2026-10-08")
            check("顺延排班后 schedule.work_date 已变", schedDate == "2026-10-15")
            check("★ 已挂号单的 visit_date 未被改动（仍 2026-10-08）", after == "2026-10-08")
        })
    }

    /* ---------- AC-4 ---------- */
    public func ac4(): Unit {
        println("=== AC-4 号源域表独立于内存 Store 整体替换 ===")
        section("AC-4", { =>
            /*
             * 验证方式（两层，如实说明）：
             *  (a) **结构性**：断言号源域表名与基线内存 Store 的表名集合**零交集** ——
             *      整体替换只遍历 `PersistedState.entities`（baseline mysql_store.cj:1097
             *      `writeDbToMysql(s, cur)`），零交集即"整体替换不会碰号源域"。
             *  (b) **完整回归**：要在 P1 引入内存 Store（科室/医生/病历）之后，
             *      执行一次整库刷盘并断言 schedule/appointment 逐值不变。
             *
             *  所以本项在 P0 只完成 (a)，判为「部分验证」，**不冒充已完成**。
             */
            /*
             * ⚠ 2026-10-07 复查修正：原来只比 `BOOKING_DOMAIN_TABLES`（2 张）与基线
             *   表名的交集 —— 那**恰好**是 0，但那时本侧另有一张 `booking_idem`
             *   （旧名 `idem`）与基线的 `idem` 是**真撞名**，只是没被这个断言覆盖到。
             *   现在比**全部业务表**与基线**全部**表名的交集，并把基线完整表名列全
             *   （含 meta / meta_str / schema_version —— 也要一起比对，
             *   否则将来本侧新建同名表会漏检）。
             *
             * 📌 该撞名已通过**删除**那张表彻底消除（2026-10-07，见 ADR §7 第 7 条）。
             *   但本断言**必须保留** —— 它守的是一条**长期纪律**：
             *   "本侧的每张表名都不得与基线内存 Store 撞名"（P1 引入整库刷盘后
             *   同名表会争同一张表）。把断言删掉等于把纪律也删了。
             */
            let baselineTables: Array<String> = ["departments", "members", "plans", "tasks",
                                                 "invite_links", "tokens", "idem",
                                                 "meta", "meta_str", "schema_version"]
            var overlap = 0
            for (t in ALL_TABLES) {
                for (b in baselineTables) {
                    if (t == b) {
                        overlap = overlap + 1
                        println("  [FAIL] 表 ${t} 与基线内存 Store 撞名 —— 整库刷盘会争同一张表")
                    }
                }
            }
            check("全部 ${ALL_TABLES.size} 张业务表与基线表名零交集", overlap == 0)
            check("号源域业务状态表恰为 schedule/appointment", BOOKING_DOMAIN_TABLES.size == 2)
            /*
             * ★ 钉住"表集里不再有任何以 idem 命名的表"。
             *   这不是在测已删除的代码，而是**防止它被复活**：
             *   死代码被删掉后，最怕的是下一个人又加回来一张同义表。
             */
            var idemLike = 0
            for (t in ALL_TABLES) {
                if (t.contains("idem")) {
                    idemLike = idemLike + 1
                }
            }
            check("表集中不再有以 idem 命名的表（遗留给删干净了）", idemLike == 0)
            println("  [NOTE] AC-4 完整回归（真跑一次整库刷盘后断言逐值不变）需 P1 引入内存 Store 后进行")
        })
    }

    /* ---------- AC-7：退号归还的边界（P0 复查发现的缺陷）---------- */
    public func ac7(): Unit {
        println("=== AC-7 退号归还边界：取消成功必须如实上报 ===")
        section("AC-7", { =>
            hResetAll(db)
            hSeedSchedule(db, 9006, 2, "2026-10-08")
            let a = repo.book(1, 9006, "tok-ac7", hNowEpoch())
            // 正常退号
            let c1 = repo.cancel(a.appointmentId, hNowEpoch())
            let (remain1, _) = hScheduleState(db, 9006)
            check("正常退号返回 Cancelled", isCancelled(c1))
            check("正常退号后号源归还（2-1+1 = 2）", remain1 == 2)
            // 幂等：再退一次
            let c2 = repo.cancel(a.appointmentId, hNowEpoch())
            let (remain2, _) = hScheduleState(db, 9006)
            check("重复退号仍是 Cancelled（幂等）", isCancelled(c2))
            check("重复退号不会把号源刷多（仍为 2）", remain2 == 2)

            /* ★ 核心边界：remain_num == total_num 时归还失败
             *   模拟"管理员重置过号源"：把 remain_num 顶到 total_num。
             *   此时 releaseSlot 因 `remain_num < total_num` 不成立而失败，
             *   但挂号单**已经**被取消（事务已提交）。
             *   正确行为：返回 SlotNotRestored（**不是** false/NotFound），
             *   让调用方知道"已退号但号源需运维修"，而不是以为退号失败。 */
            hResetAll(db)
            hSeedSchedule(db, 9007, 1, "2026-10-08")
            let b = repo.book(1, 9007, "tok-ac7b", hNowEpoch())
            // 管理员重置号源：remain_num 顶满到 total_num（version 也随之变）
            db.exec("UPDATE schedule SET remain_num = total_num, version = version + 1 " +
                    "WHERE id = ?", [DbInt(9007)])
            let c3 = repo.cancel(b.appointmentId, hNowEpoch())
            let cancelled = db.query("SELECT status FROM appointment WHERE id = ?",
                                     [DbInt(b.appointmentId)]).getString(0, 0)
            check("★ 归还失败时返回 SlotNotRestored（不再谎报失败）", isSlotNotRestored(c3))
            check("★ 该情形下挂号单**确实已取消**（与实际状态一致）", cancelled == "cancelled")
        })
    }

    /*
     * ⚠ 原先这里是 **AC-8：`booking_idem` 表可正常读写**。
     *   **2026-10-07 连同表与实现一起删除**（决策见 ADR-0001 §7 第 7 条）。
     *
     * 为什么删掉这个"通过的测试"而不是留着：它测的是一条**生产路径根本不走**的代码 ——
     * `book()` / `cancel()` 从不调用 `putIdem`/`pruneIdem`。一个永远绿色的测试
     * 会让人以为幂等由那张表保证，从而**看不见真正的保证**（唯一索引）。
     * 这种"假保证"比没有测试更危险。
     *
     * 📌 幂等的真实保证在哪：`appointment` 上的
     *   `UNIQUE KEY uk_appointment_patient_token (patient_id, client_token)`
     *   + `book()` 的事务内先查。测试覆盖：AC-3（重复提交同一 token）。
     */
}

/* 结果判定小工具（避免在多处重复写 match）。 */
func isBooked(r: BookingResult): Bool {
    match (r.outcome) {
        case Booked(_) => return true
        case _ => return false
    }
}

func isAlreadyBooked(r: BookingResult): Bool {
    match (r.outcome) {
        case AlreadyBooked(_) => return true
        case _ => return false
    }
}

func isSlotGone(r: BookingResult): Bool {
    match (r.outcome) {
        case SlotGone => return true
        case _ => return false
    }
}

/* CancelOutcome 的三态判定。 */
func isCancelled(c: CancelOutcome): Bool {
    match (c) {
        case Cancelled => return true
        case _ => return false
    }
}

func isSlotNotRestored(c: CancelOutcome): Bool {
    match (c) {
        case SlotNotRestored => return true
        case _ => return false
    }
}

/*
 * 跑全部验收测试。返回失败项数（0 = 全绿）。
 */
public func runAcceptance(db: DbBackend): Int64 {
    let runner = TestRunner(db)
    hResetAll(db)
    runner.ac2()
    runner.ac1()
    runner.ac5()
    runner.ac3()
    runner.ac6()
    runner.ac4()
    runner.ac7()
    runner.ac10()
    println("")
    println("通过 ${runner.passed} 项，失败 ${runner.failed} 项")
    if (runner.failed == 0) {
        println("✅ 验收测试全部通过")
    } else {
        println("❌ 验收测试失败 ${runner.failed} 项")
    }
    return runner.failed
}
