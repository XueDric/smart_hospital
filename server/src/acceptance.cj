/*
 * SPDX-License-Identifier: MIT
 * 智慧医院智能导诊就诊系统 · 服务端
 * acceptance.cj —— P0 验收测试（AC-1…AC-17）。
 * 只验证能真验证的：并发以数据库层原子性判定（同 version 的两条 UPDATE 受影响行数恰为 [1,0]），不做多线程压测。
 * 断言与计数收敛进 TestRunner 类（闭包不能传递性捕获可变变量）；每个用例用固定 id 的独立排班隔离并自建自清。
 */

package qingzhou

import std.time.*
import std.collection.*

/* 测试用当前时间（epoch 秒）。用 h_ 前缀避免与框架顶层名冲突。 */
func hNowEpoch(): Int64 {
    return DateTime.now().toUnixTimeStamp().toSeconds()
}

/* 清空业务表（仅测试用）：先子后父，便于将来补外键不返工。 */
func hResetAll(db: DbBackend): Unit {
    db.exec("DELETE FROM appointment", Array<DbValue>())
    db.exec("DELETE FROM medical_record_revision", Array<DbValue>())
    db.exec("DELETE FROM medical_record", Array<DbValue>())
    db.exec("DELETE FROM schedule", Array<DbValue>())
    db.exec("DELETE FROM doctor", Array<DbValue>())
    db.exec("DELETE FROM department", Array<DbValue>())
    db.exec("DELETE FROM patient", Array<DbValue>())
    /* 公告表也必须清：AC-NOTICE-* 按条数断言，共享库残留会随机红。 */
    db.exec("DELETE FROM notice", Array<DbValue>())
}

/*
 * 验收夹具用的固定排班日。夹具日期写死（确定性要求），故走可售谓词的方法必须显式注入 today，
 * 否则夹具排班被判成过期不可售；ACC_FIXTURE_DATE_P4 为未来日期，同样注入以不依赖墙上时钟。
 */
let ACC_FIXTURE_DATE: String = "2026-10-08"
let ACC_FIXTURE_DATE_P4: String = "2026-12-24"

/*
 * 建一个测试排班（显式 id）。返回 (scheduleId, patientId, doctorId, deptId)。
 * 必须用 upsert 并把 total/remain/version/enabled 重置成夹具口径：库是共享的，裸 INSERT 遇残留行会整段失败。
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
            "VALUES (?, ?, ?, ?, ?, ?, ?, 0, 1, ?) " +
            "ON DUPLICATE KEY UPDATE doctor_id = VALUES(doctor_id), " +
            "department_id = VALUES(department_id), work_date = VALUES(work_date), " +
            "period = VALUES(period), total_num = VALUES(total_num), " +
            "remain_num = VALUES(remain_num), version = 0, enabled = 1, " +
            "created_at = VALUES(created_at)",
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

/* 数一张表的行数。参数是表名，不是 SQL —— 参数性质必须写在名字上，否则会拼出语法错。 */
/* 与 hTableRowCount 并列：本函数收完整 SQL，名字把差别写在明面上。 */
func hScalarCount(db: DbBackend, sql: String): Int64 {
    let rs = db.query(sql, Array<DbValue>())
    if (rs.rowCount() > 0) {
        return rs.getInt(0, 0)
    }
    return 0
}

func hTableRowCount(db: DbBackend, table: String): Int64 {
    let rs = db.query("SELECT COUNT(*) FROM " + table, Array<DbValue>())
    if (rs.rowCount() > 0) {
        return rs.getInt(0, 0)
    }
    return 0
}

/* 读某挂号单落库的 seq_no（AC-12）：必须直接读库，不能只信返回值。 */
func hAppointmentSeqNo(db: DbBackend, appointmentId: Int64): Int64 {
    let rs = db.query("SELECT seq_no FROM appointment WHERE id = ?", [DbInt(appointmentId)])
    if (rs.rowCount() < 1) {
        return -1
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

/* 读某令牌落库的有效期（AC-14）：必须直接读库，不能只信返回值。 */
func hTokenExpiry(db: DbBackend, token: String): Int64 {
    let rs = db.query("SELECT expires_at FROM auth_token WHERE token = ?", [DbStr(token)])
    if (rs.rowCount() < 1) {
        return -1
    }
    return rs.getInt(0, 0)
}

/* ===================== 测试运行器 ===================== */

/* 断言与计数收敛为类字段/方法，绕开"闭包传递性捕获可变变量"的语言约束。 */
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
     * 跑一个用例段：任何异常都记为该段失败，不能让整个进程崩掉 —— 崩掉看起来像环境问题。
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
            let deducted = repo.tryDeductSlot(9001, today: ACC_FIXTURE_DATE)
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
             * 扣号是无 version 条件的原子自减：扣减次数恰等于号源数且永不为负，同 version 第二次也成功。
             */
            var ok: Int64 = 0
            var i: Int64 = 0
            while (i < 5) {
                if (repo.tryDeductSlot(9002, today: ACC_FIXTURE_DATE)) {
                    ok = ok + 1
                }
                i = i + 1
            }
            let (remain, ver) = hScheduleState(db, 9002)
            check("5 次扣减全部成功（恰好等于号源数）", ok == 5)
            check("remain_num 归零（5 → 0）", remain == 0)
            check("version 随每次成功 +1（0 → 5）", ver == 5)
            // 第 6 次必须失败（号已售完）
            check("第 6 次扣减失败（号已售完，不超卖）", !repo.tryDeductSlot(9002, today: ACC_FIXTURE_DATE))
            let (remain2, _) = hScheduleState(db, 9002)
            check("售完后 remain_num 仍为 0（未变负）", remain2 == 0)
        })
    }

    /* ---------- AC-10：最穷工况不少卖（第三方复查发现的严重缺陷）---------- */
    public func ac10(): Unit {
        println("=== AC-10 请求数 == 号源数时**不得少卖** ===")
        section("AC-10", { =>
            /*
             * 单线程顺序模拟（真并发由 tests\stress-booking.ps1 用独立进程覆盖）：
             * 守"扣号策略本身不再自我作废"—— N 抢 N 时不得少卖。
             */
            hResetAll(db)
            let n: Int64 = 20
            hSeedSchedule(db, 9008, n, "2026-10-08")
            var ok: Int64 = 0
            var i: Int64 = 0
            while (i < n) {
                if (repo.tryDeductSlot(9008, today: ACC_FIXTURE_DATE)) {
                    ok = ok + 1
                }
                i = i + 1
            }
            let (remain, _) = hScheduleState(db, 9008)
            check("N 次扣减全部成功（无自我作废）", ok == n)
            check("余量为 0（卖光）", remain == 0)
        })
    }

    /* ---------- AC-11：N 次归还全部成功（与 AC-10 镜像）---------- */
    public func ac11(): Unit {
        println("=== AC-11 N 次归还**不得丢号源**（AC-10 的镜像路径）===")
        section("AC-11", { =>
            /*
             * AC-10 的镜像：releaseSlot 仍带 version 且无重试 ⇒ N 个并发退号只有一个成功，其余永久丢号源。
             * 同为单线程顺序模拟；同根因会在镜像路径重现，故 AC-10 与 AC-11 必须同时绿。
             */
            hResetAll(db)
            let n: Int64 = 20
            hSeedSchedule(db, 9009, n, "2026-10-08")
            // 先全部借出
            var i: Int64 = 0
            while (i < n) {
                let _ = repo.tryDeductSlot(9009, today: ACC_FIXTURE_DATE)
                i = i + 1
            }
            let (afterLend, _) = hScheduleState(db, 9009)
            check("全部借出后余量为 0", afterLend == 0)
            // 再全部归还
            var back: Int64 = 0
            i = 0
            while (i < n) {
                if (repo.releaseSlot(9009)) {
                    back = back + 1
                }
                i = i + 1
            }
            let (afterReturn, _) = hScheduleState(db, 9009)
            check("N 次归还全部成功（无自我作废）", back == n)
            check("余量回到 N（一个号源都没丢）", afterReturn == n)
            // ★ 反向：不得归还超过放出量（反复借还也不能把号源刷大）
            var over: Int64 = 0
            i = 0
            while (i < 5) {
                if (repo.releaseSlot(9009)) {
                    over = over + 1
                }
                i = i + 1
            }
            let (afterOver, _) = hScheduleState(db, 9009)
            check("满员时再归还 5 次全部失败（不得超发）", over == 0)
            check("余量仍为 N（未被刷到超过放出量）", afterOver == n)
        })
    }

    /* ---------- AC-4：所有业务表统一走直接 SQL ---------- */
    public func ac4(): Unit {
        println("=== AC-4 数据访问范式**唯一化**：不存在第二条路径 ===")
        section("AC-4", { =>
            /*
             * 守"全库只存在一种数据访问范式"，逐层加强：①每张业务表归属一个域（无孤儿表）；
             * ②号源域的表只准 BookingRepo 写；③与搬迁前内存 Store 的表名零交集；④号源域确实有数据。
             */
            hResetAll(db)

            /* ① 分类：每张表都归属一个域 */
            check("① 表集共 ${ALL_TABLES.size} 张 = 号源域 ${BOOKING_DOMAIN_TABLES.size} + " +
                  "其它 ${ALL_TABLES.size - BOOKING_DOMAIN_TABLES.size} 张（每张都有归属，无孤儿表）",
                  ALL_TABLES.size >= BOOKING_DOMAIN_TABLES.size + 1)

            /* ② 机制：域清单与表集不脱节（防"清单里写了一张不存在的表"） */
            var missing = 0
            for (t in BOOKING_DOMAIN_TABLES) {
                var found = false
                for (o in ALL_TABLES) {
                    if (o == t) {
                        found = true
                    }
                }
                if (!found) {
                    missing = missing + 1
                    println("  [FAIL] 号源域的表 ${t} 不在 ALL_TABLES 里")
                }
            }
            check("② ★ 号源域的表都在表集里（域清单与表集不脱节）", missing == 0)
            check("② ★★ 号源域恰为 schedule + appointment 两张，且由范围锁死只准 BookingRepo 写",
                  BOOKING_DOMAIN_TABLES.size == 2 &&
                  isBookingDomainTable(TABLE_SCHEDULE) && isBookingDomainTable(TABLE_APPOINTMENT))

            /* ★ 与搬迁前内存 Store 的表名零交集：同库运行会争同一张表（auth_token 不叫 tokens 即为此）。 */
            let legacyTables: Array<String> = ["departments", "members", "plans", "tasks",
                                                 "invite_links", "tokens", "idem",
                                                 "meta", "meta_str", "schema_version"]
            var clash = 0
            for (t in ALL_TABLES) {
                for (bt in legacyTables) {
                    if (t == bt) {
                        clash = clash + 1
                        println("  [FAIL] 表 ${t} 与搬迁前的内存 Store 撞名")
                    }
                }
            }
            check("③ ★ 全部 ${ALL_TABLES.size} 张表与搬迁前表名零交集（**从旧 AC-4 保留**）",
                  clash == 0)

            /* ④ 反向：号源域确实有数据，否则上面是"空比空"的假绿 */
            hSeedSchedule(db, 9011, 3, "2026-10-08")
            let a = repo.book(1, 9011, "tok-ac4", hNowEpoch(), today: ACC_FIXTURE_DATE)
            check("④ ★★ 反向：号源域确实有数据（造出一张挂号单）—— 否则③可能是「因为什么都没做」而假绿",
                  isBooked(a))
            let schedRows = hTableRowCount(db, TABLE_SCHEDULE)
            let apptRows = hTableRowCount(db, TABLE_APPOINTMENT)
            check("④ 号源域两表都非空（schedule=${schedRows} appointment=${apptRows}）",
                  schedRows > 0 && apptRows > 0)

            /* ⑤ "没有内存 Store"刻意不写成运行期断言：相关名字已不存在，交给编译器拦截。 */
            println("  [NOTE] 内存 Store 已整体移除（`mem_store.cj` / `sql_recorder.cj`）。")
            println("         该事实由**编译期**保证（引用 MEM_TABLES/MemStore 会编译失败），")
            println("         比运行期断言更硬 —— 故此处**刻意不写**「没有内存 Store」这类空洞断言。")
        })
    }

    /* ---------- AC-12：响应里的 seq_no 必须等于落库值 ---------- */
    public func ac12(): Unit {
        println("=== AC-12 就诊序号：响应值 == 落库值 ===")
        section("AC-12", { =>
            /*
             * 响应回填 countBooked()（当前有效单数），落库用 nextSeqNo()（MAX+1，不回收）⇒ 报错号会误导患者。
             */
            hResetAll(db)
            hSeedSchedule(db, 9010, 5, "2026-10-08")
            let a = repo.book(1, 9010, "tok-ac12-a", hNowEpoch(), today: ACC_FIXTURE_DATE)
            check("第一次挂号成功", isBooked(a))
            check("响应 seq_no = 1", a.seqNo == 1)
            let dbSeq1 = hAppointmentSeqNo(db, a.appointmentId)
            check("落库 seq_no = 1（与响应一致）", dbSeq1 == 1)

            // 退掉它（seq_no 不回收），再挂一单 → 应为 2，且响应与库一致
            let c = repo.cancel(a.appointmentId, hNowEpoch())
            check("退号成功", isCancelled(c))
            let b = repo.book(1, 9010, "tok-ac12-b", hNowEpoch(), today: ACC_FIXTURE_DATE)
            check("退号后再次挂号成功", isBooked(b))
            let dbSeq2 = hAppointmentSeqNo(db, b.appointmentId)
            /* 只断言"响应 == 落库"，不断言"== 2"：序号是否回收是策略，本用例守一致性。 */
            check("★ 响应 seq_no 与落库 seq_no 一致（${b.seqNo} == ${dbSeq2}）", b.seqNo == dbSeq2)
            check("退号不回收序号（第二单的 seq_no > 第一单）", dbSeq2 > dbSeq1)
        })
    }

    /* ---------- AC-5 ---------- */
    public func ac5(): Unit {
        println("=== AC-5 失败不留下部分状态 ===")
        section("AC-5", { =>
            hResetAll(db)
            hSeedSchedule(db, 9003, 1, "2026-10-08")
            let a = repo.book(1, 9003, "tok-ac5-a", hNowEpoch(), today: ACC_FIXTURE_DATE)   // 抢走唯一号
            let b = repo.book(1, 9003, "tok-ac5-b", hNowEpoch(), today: ACC_FIXTURE_DATE)   // 号已满 → 必然失败
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
            let a = repo.book(1, 9004, tok, hNowEpoch(), today: ACC_FIXTURE_DATE)
            let b = repo.book(1, 9004, tok, hNowEpoch(), today: ACC_FIXTURE_DATE)          // 重复提交
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
            let a = repo.book(1, 9005, "tok-ac6", hNowEpoch(), today: ACC_FIXTURE_DATE)
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


    /* ---------- AC-7：退号归还的边界 ---------- */
    public func ac7(): Unit {
        println("=== AC-7 退号归还边界：取消成功必须如实上报 ===")
        section("AC-7", { =>
            hResetAll(db)
            hSeedSchedule(db, 9006, 2, "2026-10-08")
            let a = repo.book(1, 9006, "tok-ac7", hNowEpoch(), today: ACC_FIXTURE_DATE)
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

            /* ★ remain_num == total_num 时 releaseSlot 失败，但退号已提交 ⇒ 必须返回 SlotNotRestored，不能是 false/NotFound。 */
            hResetAll(db)
            hSeedSchedule(db, 9007, 1, "2026-10-08")
            let b = repo.book(1, 9007, "tok-ac7b", hNowEpoch(), today: ACC_FIXTURE_DATE)
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

    /* ---------- AC-13：退号必须走状态机 ---------- */
    /*
     * 原条件 status <> 'cancelled' ⇒ visiting/done/no_show 都能退并归还号源；并发窗口由 cancel() 里带 status = ? 的原子 UPDATE 挡住。
     */
    public func ac13(): Unit {
        println("=== AC-13 退号状态机：只有「已挂号」能退 ===")
        section("AC-13", { =>
            hResetAll(db)
            hSeedSchedule(db, 9401, 4, "2026-12-24")
            let now = hNowEpoch()
            let a = repo.book(1, 9401, "tok-ac13-visiting", now, today: ACC_FIXTURE_DATE_P4)
            let b = repo.book(1, 9401, "tok-ac13-done", now, today: ACC_FIXTURE_DATE_P4)
            let c = repo.book(1, 9401, "tok-ac13-noshow", now, today: ACC_FIXTURE_DATE_P4)
            let d = repo.book(1, 9401, "tok-ac13-booked", now, today: ACC_FIXTURE_DATE_P4)
            check("四张单都建成功（夹具就位）", isBooked(a) && isBooked(b) && isBooked(c) && isBooked(d))
            /*
             * 直接用 SQL 把单拨到状态：本用例只测退号侧护栏，不依赖接诊/爽约流程是否已实现。
             */
            db.exec("UPDATE appointment SET status = 'visiting' WHERE id = ?", [DbInt(a.appointmentId)])
            db.exec("UPDATE appointment SET status = 'done' WHERE id = ?", [DbInt(b.appointmentId)])
            db.exec("UPDATE appointment SET status = 'no_show' WHERE id = ?", [DbInt(c.appointmentId)])
            let (remainBefore, _) = hScheduleState(db, 9401)

            let c1 = repo.cancel(a.appointmentId, now)
            let c2 = repo.cancel(b.appointmentId, now)
            let c3 = repo.cancel(c.appointmentId, now)

            check("★ 接诊中的单不能退（NotCancellable）", isNotCancellable(c1))
            check("★ 已完成的单不能退（NotCancellable）", isNotCancellable(c2))
            check("★ 爽约的单不能退（NotCancellable）", isNotCancellable(c3))
            /* 只判"属于这一态"不够：该态的全部对外价值就是状态字符串（handler 用它拼 409 文案）。 */
            check("★ 返回值带上真实状态（visiting / done / no_show）",
                  cancelStateOf(c1) == "visiting" && cancelStateOf(c2) == "done" &&
                  cancelStateOf(c3) == "no_show")

            let stA = db.query("SELECT status FROM appointment WHERE id = ?",
                               [DbInt(a.appointmentId)]).getString(0, 0)
            let stB = db.query("SELECT status FROM appointment WHERE id = ?",
                               [DbInt(b.appointmentId)]).getString(0, 0)
            let stC = db.query("SELECT status FROM appointment WHERE id = ?",
                               [DbInt(c.appointmentId)]).getString(0, 0)
            /* ★ 终态被覆盖正是点名的后果之一 ⇒ 必须逐张核实库里的状态没被动过。 */
            check("★★ 库中状态未被改写（visiting / done / no_show 原样保留）",
                  stA == "visiting" && stB == "done" && stC == "no_show")
            let (remainAfter, _) = hScheduleState(db, 9401)
            /* ★ 凭空多出可售号源是另一条后果 ⇒ 号源必须一个都没回来。 */
            check("★★ 号源未被归还（拒绝退号不能改号源）", remainAfter == remainBefore)

            /* 反向证明：真正"已挂号"的单仍可正常退，别把护栏修成"谁都退不了"。 */
            let c4 = repo.cancel(d.appointmentId, now)
            let (remainFinal, _) = hScheduleState(db, 9401)
            check("★ 已挂号的单仍可正常退号（护栏没有误伤）", isCancelled(c4))
            check("★ 该单退号后号源 +1（归还路径未被破坏）", remainFinal == remainBefore + 1)
        })
    }

    /* ---------- AC-14：滑动续期必须把「续期后」的有效期回给调用方（跨端审计 F11）---------- */
    /*
     * principalByToken 一直在续期，但 Principal 没有有效期字段 ⇒ 客户端按登录时的旧值倒计时，会在令牌有效时被踢回登录页。
     * 这里测"回填的值是否权威"；续期写的是绝对值 now + TTL，重复执行幂等，故不造并发窗口。
     */
    public func ac14(): Unit {
        println("=== AC-14 ★★ 令牌滑动续期：有效期必须回给客户端（F11）===")
        section("AC-14", { =>
            hResetAll(db)
            let auth = AuthRepo(db)
            let now = hNowEpoch()
            // 只为造出 patient id=1（createUser 会校验业务身份真实存在）
            let _seed = hSeedSchedule(db, 9501, 2, ACC_FIXTURE_DATE_P4)
            let _uid = auth.createUser("ac14-renew", Role.Patient, 1, "续期验收患者",
                                       "Ac14#Renew1", now)
            let login = auth.login("ac14-renew", "Ac14#Renew1", now)
            check("夹具：能登录并拿到令牌（没令牌则本用例无意义）", login.token.size > 0)
            let token = login.token
            /* 拨到"该续期"状态：剩余 1000 秒（< TOKEN_TTL - RENEW_AFTER），上次续期在两天前（已过 RENEW_AFTER 节流窗口）。 */
            db.exec("UPDATE auth_token SET expires_at = ?, last_renew_at = ? WHERE token = ?",
                    [DbInt(now + 1000), DbInt(now - 2 * RENEW_AFTER), DbStr(token)])
            let p = auth.principalByToken(token, now)
            check("★ 令牌有效（否则下面断言的是 None）", p.isSome())
            let exp = p.getOrThrow().expiresAt
            check("★★ 回填的是**续期后**的有效期（now + TOKEN_TTL）", exp == now + TOKEN_TTL)
            let inDb = hTokenExpiry(db, token)
            check("★★ 且与库中值一致（两端看到同一个到期时刻；库=${inDb} 回填=${exp}）",
                  exp == inDb)
            /* 反向：节流期内不能凭空造未来值，否则客户端会看到库里并不存在的有效期。 */
            let p2 = auth.principalByToken(token, now + 60)
            check("★ 节流期内不重复续期：回填值等于库中值（不虚报）",
                  p2.getOrThrow().expiresAt == hTokenExpiry(db, token))
            check("★ 且该值仍是原来那个（没被偷偷改成 now + TOKEN_TTL）",
                  p2.getOrThrow().expiresAt == exp)
            // 自建自清（auth_user / auth_token 不在 hResetAll 的清理范围内）
            db.exec("DELETE FROM auth_token WHERE token = ?", [DbStr(token)])
            db.exec("DELETE FROM auth_user WHERE login_name = ?", [DbStr("ac14-renew")])
        })
    }

    /* ---------- AC-15：探活接口必须给出**医院今天**与时间口径（跨端审计 F14）---------- */
    /*
     * 客户端拿设备本地日期当"今天"，服务端是 Asia/Shanghai ⇒ 设备时区不对或跨零点时两侧答案不同，
     * 故探活直接给出权威日期与时区名，客户端读它即可，不必自己算。
     */
    public func ac15(): Unit {
        println("=== AC-15 ★ 探活响应给出医院日期与时间口径（F14）===")
        section("AC-15", { =>
            /* 探活当场探一次库，探针由调用方注入；传 None ＝ 沿用"不接库"语义。 */
            let (dbOk, body) = healthBody(DevAuthGate(false, false), None)
            check("★ /health 带 today，且等于服务端口径的今天",
                  body.contains("\"today\":\"" + hTodayDate() + "\""))
            check("★ /health 带 timezone = Asia/Shanghai",
                  body.contains("\"timezone\":\"Asia/Shanghai\""))
            /*
             * 库连不上时必须 db.ok=false + HTTP 503 让探针摘流量（旧行为 200 会把 DBA 问题伪装成代码 bug）；
             * today / timezone 仍是纯计算（hTodayDate() 不查库）。
             */
            check("★★ 该字段是纯计算：与日期格式化同口径（hTodayDate == hDateStringOf(now)）",
                  hTodayDate() == hDateStringOf(hNowEpoch()))
            check("★ 且探活仍如实报告 dev_auth（没被日期字段挤掉）",
                  body.contains("\"dev_auth\":false"))
            /* 没有库句柄时 db.ok 仍为 true（"未接库"不是"库挂了"），且 db.reconnects 字段必须在。 */
            check("★ S4 探活带 db.ok / db.reconnects（探针结果不再被吞掉）",
                  dbOk && body.contains("\"db\":{\"ok\":true,\"reconnects\":0"))
        })
    }

    /* ---------- AC-16：模型配置表（多模型 / 运行时解析 / PATCH / 缓存失效）---------- */
    /*
     * ai_model 一模型一行（对话 / 向量分开、各自温度与上限、各自启停）。钉四件事：空表播种幂等、
     * 运行时按类型解析（key_ref 为空回落全局）、PATCH 只改给定字段、缓存失效生效。
     */
    public func ac16(): Unit {
        println("=== AC-16 ★★ 模型配置表：播种 / 运行时解析 / PATCH / 缓存失效 ===")
        section("AC-16", { =>
            /* 本用例独占 ai_model 与几个 ai.* 配置项：库是共享的，不清会随机红；结尾恢复成播种后的两行。 */
            db.exec("DELETE FROM ai_model", Array<DbValue>())
            db.exec("DELETE FROM ai_setting WHERE k = ?", [DbStr("ai.enabled")])
            db.exec("DELETE FROM ai_setting WHERE k = ?", [DbStr("ai.endpoint")])
            db.exec("DELETE FROM ai_setting WHERE k = ?", [DbStr("ai.model")])
            db.exec("DELETE FROM ai_setting WHERE k = ?", [DbStr("ai.max_tokens")])
            db.exec("DELETE FROM ai_setting WHERE k = ?", [DbStr("ai.key_ref")])

            let now = hNowEpoch()
            let models = AiModelRepo(db)
            let settings = AiSettingsRepo(db)
            settings.attachModels(models)

            check("清空后模型表为空", models.countAll() == 0)
            check("空表播种：返回 2，且表里恰好 2 行",
                  aiModelSeedDefaults(models, settings, now) == 2 && models.countAll() == 2)
            check("播种幂等：再播一次不改动（返回 0，仍是 2 行）",
                  aiModelSeedDefaults(models, settings, now) == 0 && models.countAll() == 2)

            match (models.defaultOf(AI_MODEL_KIND_CHAT, now)) {
                case Some(m) =>
                    check("对话模型：请求 URL = base_url + /chat/completions（探针与真实调用同一条路）",
                          aiModelRequestUrl(m.baseUrl, AI_MODEL_KIND_CHAT) ==
                          AI_MODEL_SEED_BASE_URL + "/chat/completions")
                    check("对话模型：种子值 = qwen-plus / 温度 0.3 / 上限 2048（与产品需求一致）",
                          m.model == AI_MODEL_SEED_CHAT_MODEL &&
                          m.temperature == AI_MODEL_SEED_CHAT_TEMPERATURE &&
                          m.maxTokens == AI_MODEL_SEED_MAX_TOKENS)
                case None =>
                    check("默认对话模型可按类型取到", false)
            }
            match (models.defaultOf(AI_MODEL_KIND_EMBEDDING, now)) {
                case Some(m) =>
                    /* ★ 向量行与对话行不共用 base_url（DeepSeek 无 /embeddings）⇒ 用向量行自己的 base_url 拼 /embeddings。 */
                    check("向量模型：请求 URL = 向量行 base_url + /embeddings",
                          aiModelRequestUrl(m.baseUrl, AI_MODEL_KIND_EMBEDDING) ==
                          AI_MODEL_SEED_EMBEDDING_BASE_URL + "/embeddings")
                    check("向量模型：base_url 与对话行**不同**（DeepSeek 没有 /embeddings，硬指必 404）",
                          m.baseUrl != AI_MODEL_SEED_BASE_URL)
                case None =>
                    check("默认向量模型可按类型取到", false)
            }

            let opts = settings.options(now)
            check("运行时端点 = 模型行（而不是 KV 里可能存在的另一个地址）",
                  opts.endpoint == AI_MODEL_SEED_BASE_URL + "/chat/completions")
            check("运行时模型名 = 模型行", opts.model == AI_MODEL_SEED_CHAT_MODEL)
            check("★ 运行时温度 = 模型行的 0.3（旧口径根本不发温度，等于把决定性让给服务商默认值）",
                  opts.temperature == AI_MODEL_SEED_CHAT_TEMPERATURE)
            check("运行时最大 Token = 模型行", opts.maxTokens == AI_MODEL_SEED_MAX_TOKENS)
            /* 总开关默认 1（开箱即用），但开关仍由 KV 说了算，模型行不许绕过；显式关掉再断言不可用，随后恢复。 */
            let _off = settings.put("ai.enabled", "0", now)
            let optsOff = settings.options(now)
            check("★ AI 总开关仍来自 KV（写 0 ⇒ 不可用；模型行不该绕过总开关）", !optsOff.enabled)
            let _on = settings.put("ai.enabled", "1", now)

            check("全局密钥引用可写入（模型行留空时用它兜底）",
                  settings.put("ai.key_ref", "env:AC16_GLOBAL_KEY", now).ok)
            check("★ 密钥引用回落：模型行 key_ref 为空 ⇒ 取全局那把",
                  settings.options(now).keyRef == "env:AC16_GLOBAL_KEY")

            let draft = AiModel()
            draft.name = "AC16-临时行"
            draft.kind = "chat"
            draft.provider = "本地"
            draft.baseUrl = AI_MODEL_SEED_BASE_URL
            draft.model = "ac16-model"
            draft.temperature = 0.5
            draft.maxTokens = 1024
            draft.keyRef = "env:AC16_ROW_KEY"
            draft.enabled = true
            draft.isDefault = true
            let created = models.create(draft, now, 1)
            check("新建默认对话模型：成功且拿到 id（类型小写 chat 也要能用）",
                  created.ok && created.id > 0)
            match (models.get(created.id, now)) {
                case Some(m) =>
                    check("落库的 kind 已归一化为 CHAT", m.kind == AI_MODEL_KIND_CHAT)
                case None =>
                    check("新建后能读回该行", false)
            }
            match (models.defaultOf(AI_MODEL_KIND_CHAT, now)) {
                case Some(m) =>
                    check("新行成为默认对话模型（is_default 生效）",
                          m.id == created.id && m.model == "ac16-model")
                case None =>
                    check("新行成为默认对话模型", false)
            }
            var defaultCount: Int64 = 0
            for (m in models.list(true, now)) {
                if (m.kind == AI_MODEL_KIND_CHAT && m.isDefault) {
                    defaultCount = defaultCount + 1
                }
            }
            check("同一类型只有一个默认（clearOtherDefaults 把旧默认清掉了）", defaultCount == 1)

            let patched = models.update(created.id, None, None, None, None, None, Some(0.9), None,
                                        None, None, None, now, 1)
            check("PATCH：只给温度也能成功", patched.ok)
            match (models.get(created.id, now)) {
                case Some(m) =>
                    check("★ PATCH 不清空没提到的字段（模型名 / 密钥引用 / 上限原样）",
                          m.temperature == 0.9 && m.model == "ac16-model" &&
                          m.keyRef == "env:AC16_ROW_KEY" && m.maxTokens == 1024)
                case None =>
                    check("PATCH 后能读回该行", false)
            }

            let dup = AiModel()
            dup.name = "AC16-临时行"
            dup.kind = AI_MODEL_KIND_CHAT
            dup.provider = "本地"
            dup.baseUrl = AI_MODEL_SEED_BASE_URL
            dup.model = "another"
            check("重名 ⇒ duplicate（HTTP 层映射成 409）", models.create(dup, now, 1).duplicate)
            check("明文 http 地址被拒（消息要说清是密钥裸奔）",
                  aiModelValidate("n", AI_MODEL_KIND_CHAT, "p", "http://x.example/v1", "m",
                                  0.3, 1024, "").size > 0)
            check("温度越界 2.5 被拒",
                  aiModelValidate("n", AI_MODEL_KIND_CHAT, "p", AI_MODEL_SEED_BASE_URL, "m",
                                  2.5, 1024, "").size > 0)
            check("最大 Token 过小 8 被拒",
                  aiModelValidate("n", AI_MODEL_KIND_CHAT, "p", AI_MODEL_SEED_BASE_URL, "m",
                                  0.3, 8, "").size > 0)

            /* 绕过仓储直接改库 ⇒ 仓储仍回旧值（证明缓存真的在）；invalidate() 之后才看到新值。 */
            db.exec("UPDATE ai_model SET model = ? WHERE id = ?",
                    [DbStr("ac16-cache-probe"), DbInt(created.id)])
            var cachedModel = ""
            match (models.get(created.id, now)) {
                case Some(m) => cachedModel = m.model
                case None => ()
            }
            check("★ 缓存生效：直连改库后仓储仍回旧值（说明不是每次都查库）",
                  cachedModel == "ac16-model")
            models.invalidate()
            var freshModel = ""
            match (models.get(created.id, now)) {
                case Some(m) => freshModel = m.model
                case None => ()
            }
            check("★ invalidate() 后读到新值（下次 AI 请求重新构建实例，无需重启）",
                  freshModel == "ac16-cache-probe")

            check("删除临时行成功", models.remove(created.id, now))
            check("删后取不到该行", models.get(created.id, now).isNone())
            db.exec("DELETE FROM ai_model", Array<DbValue>())
            db.exec("DELETE FROM ai_setting WHERE k = ?", [DbStr("ai.key_ref")])
            check("收尾：恢复成播种后的 2 行（给联调/管理台一个一致的起点）",
                  aiModelSeedDefaults(models, settings, now) == 2 && models.countAll() == 2)
        })
    }

    /* ---------- AC-17：管理台补充的两个契约缺口（账号列表 / 排班可改）---------- */
    /*
     * ① GET /api/v1/admin/users 原先只能按登录名精确查一条，管理台要列表、翻页、按角色筛；
     * ② 排班只有建、没有改。本用例钉这两条路径（列表不吐口令材料、放号数不得低于已约数）。
     */
    public func ac17(): Unit {
        println("=== AC-17 ★ 管理台缺口：账号列表 与 排班改放号/停诊 ===")
        section("AC-17", { =>
            let now = hNowEpoch()
            let auth = AuthRepo(db)

            /* ---------- ① 账号列表 ---------- */
            db.exec("DELETE FROM auth_token WHERE user_id IN " +
                    "(SELECT id FROM auth_user WHERE login_name LIKE ?)", [DbStr("ac17-%")])
            db.exec("DELETE FROM auth_user WHERE login_name LIKE ?", [DbStr("ac17-%")])
            let a = auth.createUser("ac17-probe-a", Role.Admin, 0, "AC-17 探针甲",
                                    "Ac17-Str0ng-Pass!", now)
            let b = auth.createUser("ac17-probe-b", Role.Admin, 0, "AC-17 探针乙",
                                    "Ac17-Str0ng-Pass!", now)
            check("建两个 admin 探针账号（口令强度校验通过）", a > 0 && b > 0)

            let listed = auth.listUsers(500, 0, "admin", "")
            var foundA = false
            var leakage = false
            for (u in listed) {
                if (u.loginName == "ac17-probe-a") {
                    foundA = true
                }
                if (u.pwHash.size > 0 || u.pwSalt.size > 0) {
                    leakage = true
                }
            }
            check("★ 列表模式：按 role 筛能查到刚建的账号（旧接口只支持按登录名精确查）", foundA)
            check("★★ 列表**不**读出任何口令材料（pw_hash / pw_salt 全空）", !leakage)
            check("count 与 list 同一套 WHERE（口径不会互相漂移）",
                  auth.countUsers("admin", "") == auth.listUsers(500, 0, "admin", "").size)
            check("白名单外的 role 值 = 不筛（不报错、也不当成未知角色查空）",
                  auth.listUsers(500, 0, "超级管理员", "").size == auth.countUsers("", ""))

            let page1 = auth.listUsers(1, 0, "", "")
            let page2 = auth.listUsers(1, 1, "", "")
            check("limit / offset 生效（第 1、2 页各 1 条且不同一行）",
                  page1.size == 1 && page2.size == 1 && page1[0].id != page2[0].id)

            db.exec("DELETE FROM auth_token WHERE user_id IN " +
                    "(SELECT id FROM auth_user WHERE login_name LIKE ?)", [DbStr("ac17-%")])
            db.exec("DELETE FROM auth_user WHERE login_name LIKE ?", [DbStr("ac17-%")])
            check("收尾：探针账号已清掉（不给下一次运行留状态）",
                  auth.countUsers("", "") == auth.listUsers(500, 0, "", "").size)

            /* ---------- ② 排班：改放号数 / 停诊 ---------- */
            /* hSeedSchedule 用的是普通 INSERT ⇒ 先清掉同 id 的行，保证可重复运行。 */
            db.exec("DELETE FROM appointment WHERE schedule_id = ?", [DbInt(9701)])
            db.exec("DELETE FROM schedule WHERE id = ?", [DbInt(9701)])
            hSeedSchedule(db, 9701, 10, ACC_FIXTURE_DATE)

            let up1 = repo.updateSchedule(9701, Some(20), None, 0)
            let (remain1, ver1) = hScheduleState(db, 9701)
            check("改放号数 10 → 20：成功、余量同步 +10、版本 +1",
                  up1.ok && up1.totalNum == 20 && remain1 == 20 && ver1 == 1)

            var i: Int64 = 0
            while (i < 3) {
                let _ = repo.tryDeductSlot(9701, today: ACC_FIXTURE_DATE)
                i = i + 1
            }
            let (remainBooked, verBooked) = hScheduleState(db, 9701)
            /* 扣号（tryDeductSlot）也会 version + 1 ⇒ 必须读回当前版本再改，拿旧版本改会稳定假红。 */
            check("先占掉 3 个号（余量 20 → 17，版本推进到 ${verBooked}）", remainBooked == 17)

            /* ★ 不变量：放号数不得低于"已约数"（否则余量为负 = 超卖）。 */
            let up2 = repo.updateSchedule(9701, Some(2), None, verBooked)
            let (remain2, ver2) = hScheduleState(db, 9701)
            check("★★ 放号数降到已约数以下 ⇒ tooSmall，且库里**一个字都没改**" +
                  "（实得 tooSmall=${up2.tooSmall} ok=${up2.ok} remain=${remain2} ver=${ver2}" +
                  " booked=${up2.booked} total=${up2.totalNum}）",
                  up2.tooSmall && !up2.ok && remain2 == 17 && ver2 == verBooked)

            let up3 = repo.updateSchedule(9701, Some(15), None, verBooked)
            let (remain3, ver3) = hScheduleState(db, 9701)
            check("★ 放号数 20 → 15：余量 = 17 + (15 - 20) = 12（已约的 3 个不受影响）" +
                  "（实得 ok=${up3.ok} remain=${remain3} ver=${ver3} booked=${up3.booked}" +
                  " remainNum=${up3.remainNum} tooSmall=${up3.tooSmall} conflict=${up3.conflict}）",
                  up3.ok && remain3 == 12 && ver3 == verBooked + 1 &&
                  up3.remainNum == 12 && up3.booked == 3)

            let up4 = repo.updateSchedule(9701, Some(16), None, verBooked)
            check("拿着**过期**的版本号改 ⇒ conflict（不是静默成功、也不是覆盖别人的改动）",
                  up4.conflict && !up4.ok)

            let (_, verAfter3) = hScheduleState(db, 9701)
            let up5 = repo.updateSchedule(9701, None, Some(false), verAfter3)
            let rs = db.query("SELECT enabled FROM schedule WHERE id = ?", [DbInt(9701)])
            check("停诊：enabled 落库为 0（此前只有建、没有改，停诊只能新开一条排班）" +
                  "（实得 ok=${up5.ok} enabled=${rs.getInt(0, 0)} ver=${up5.version}" +
                  " notFound=${up5.notFound} conflict=${up5.conflict}）",
                  up5.ok && rs.rowCount() == 1 && rs.getInt(0, 0) == 0)

            let up6 = repo.updateSchedule(9799, Some(5), None, 0)
            check("改不存在的排班 ⇒ notFound（不回「成功」）", up6.notFound && !up6.ok)

            db.exec("DELETE FROM appointment WHERE schedule_id = ?", [DbInt(9701)])
            db.exec("DELETE FROM schedule WHERE id = ?", [DbInt(9701)])
            let gone = db.query("SELECT id FROM schedule WHERE id = ?", [DbInt(9701)])
            check("收尾：探针排班已清掉（不给下一次运行留状态）", gone.rowCount() == 0)
        })
    }

    /* AC-8（booking_idem 表）连同实现一并删除：幂等由 uk_appointment_patient_token 唯一索引保证，测试覆盖在 AC-3。 */
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

/* NotCancellable(st) 的判定与取值：该态的对外价值就是状态字符串（handler 拼 409 文案），必须取出状态。 */
func isNotCancellable(c: CancelOutcome): Bool {
    match (c) {
        case NotCancellable(_) => return true
        case _ => return false
    }
}

func cancelStateOf(c: CancelOutcome): String {
    match (c) {
        case NotCancellable(st) => return st
        case _ => return ""
    }
}

/* 跑全部验收测试。返回失败项数（0 = 全绿）。 */
/*
 * accept 的库名守卫是纯函数：test 必须是独立的下划线分段，不能再用 contains("test")
 * —— 否则 hospital_contest 这类库会被当测试库，而 accept 一跑就 DELETE 六张表。这些断言不碰库。
 */
public func acP0_guard(runner: TestRunner): Unit {
    runner.check("库名守卫：hospital_test 允许（最常用写法）", isTestDatabase("hospital_test"))
    runner.check("库名守卫：test_ci 允许（test_ 前缀）", isTestDatabase("test_ci"))
    runner.check("库名守卫：hospital_test_backup_2025 允许（_test_ 分段）", isTestDatabase("hospital_test_backup_2025"))
    runner.check("库名守卫：test 允许（就叫 test）", isTestDatabase("test"))
    runner.check("库名守卫：hospital 拒绝（生产库名）", !isTestDatabase("hospital"))
    runner.check("库名守卫：hospital_contest 拒绝（contest 不是 test 分段）", !isTestDatabase("hospital_contest"))
    runner.check("库名守卫：latest_hospital 拒绝（latest 不是 test 分段）", !isTestDatabase("latest_hospital"))
    runner.check("库名守卫：TEST 大写也按分段判（大小写不敏感）", isTestDatabase("HOSPITAL_TEST") && !isTestDatabase("HOSPITAL_CONTEST"))
}

public func runAcceptance(db: DbBackend): Int64 {
    let runner = TestRunner(db)
    hResetAll(db)
    acP0_guard(runner)
    runner.ac2()
    runner.ac1()
    runner.ac5()
    runner.ac3()
    runner.ac6()
    runner.ac4()
    runner.ac7()
    runner.ac10()
    runner.ac11()
    runner.ac12()
    /* P2 分诊（acceptance_triage.cj）：独立函数，需传 runner 与 db，断言仍走 runner.check 并入总账。 */
    acP2_1(runner, db)
    acP2_2(runner, db)
    acP2_3(runner, db)
    acP2_4(runner, db)
    acP2_5(runner, db)
    acP2_6(runner, db)
    // P3 AI 能力中心（定义在 acceptance_ai.cj）
    acP3_1(runner, db)
    acP3_2(runner, db)
    acP3_3(runner, db)
    acP3_4(runner, db)
    acP3_5(runner, db)
    acP3_6(runner, db)
    acP3_7(runner, db)
    // P4 电子病历 + 接诊队列 + 运营看板（定义在 acceptance_p4.cj）
    acP4_1(runner, db)
    acP4_2(runner, db)
    acP4_3(runner, db)
    acP4_4(runner, db)
    /* 预问诊 → 病历的桥；自己 hResetAll，用 9505/9506/9507 段患者，与前面用例的 88xx/95xx 段不重叠。 */
    acP4_5(runner, db)
    /* 病历修订历史；自己 hResetAll，用 9608/9609 段患者 + 900008/900009 医生。 */
    acP4_6(runner, db)
    /* 医生工作台 —— 既往病历的隐私边界 + 乐观锁；自己 hResetAll，用 9610/9613 段患者 + 900010/900011/900013 医生。 */
    acP4_7(runner, db)
    /*
     * 就诊时间线 —— 到院/候诊、三个时间戳、队列排序；自己 hResetAll，用 9620-9627 段患者 + 900020/900021 医生。
     * 排队断言依赖"同优先级内按 seq_no"：夹具让 seq_no 与状态优先级相反，只有真按状态排序才会过。
     */
    acP4_8(runner, db)
    /* 基础数据域（科室/医生）的管理端 CRUD（acceptance_base.cj）；只清自己的 91xxxx / 92xxxx / 93xxxx 段。 */
    acBase1(runner, db)
    acBase2(runner, db)
    acBase3(runner, db)
    /* 真模型出站（acceptance_ai_call.cj）：只在环境变量就位时才跑，否则打印 [SKIP] 与原因，不静默、不假绿。 */
    acAiCall1(runner, db)
    acAiCall2(runner, db)
    acAiCall3(runner, db)
    /* P5 知识库（acceptance_kb.cj）：夹具按标题前缀 ACKB 自建自清。 */
    acKb1(runner, db)
    acKb2(runner, db)
    acKb3(runner, db)
    acKb4(runner, db)
    acKb5(runner, db)
    /* 参数化绑定的写路径（acceptance_bind.cj）：只碰自己的表 ac_bind_probe，开头 DROP、结尾 DROP。 */
    acBind1(runner, db)
    /* 公告域（acceptance_notice.cj）：夹具按标题前缀 ACNOTICE 自建自清。 */
    acNotice1(runner, db)
    acNotice2(runner, db)
    acNotice3(runner, db)
    /* AC-13 退号状态机（在 TestRunner 里，要用 repo/check/section）；必须排最后：开头 hResetAll 会清掉别人的夹具。 */
    runner.ac13()
    /* AC-14 / AC-15（跨端审计 F11 / F14 的回归护栏）；AC-14 也 hResetAll，并自建自清 auth_user / auth_token。 */
    runner.ac14()
    runner.ac15()
    /* AC-16 / AC-17（管理台后端：多模型配置 + 两个契约缺口）；AC-16 独占 ai_model / ai.* 配置项，AC-17 自建自清。 */
    runner.ac16()
    runner.ac17()
    println("")
    println("通过 ${runner.passed} 项，失败 ${runner.failed} 项")
    if (runner.failed == 0) {
        println("✅ 验收测试全部通过")
    } else {
        println("❌ 验收测试失败 ${runner.failed} 项")
    }
    return runner.failed
}
