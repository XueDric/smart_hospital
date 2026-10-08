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
// AC-4 的逐值比对要用 ArrayList（hDumpTable）；实测漏了它报 `undeclared identifier 'ArrayList'`
import std.collection.*

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

/*
 * ★ 把一张表**全列全行**导成"规范化文本数组"（AC-4 的逐值比对用）。
 *
 * ── 为什么必须"全列"而不是只查几列 ──────────────────────────────────────
 * AC-4 要证的是"刷盘**没有**碰到号源域"。只比对 `remain_num` 之类的少数列是**弱**的：
 * 刷盘完全可能改了 `version` / `created_at` / 某个快照列，而断言照样绿。
 * 所以这里从 `information_schema` **动态取全列**，逐行逐列拼成文本。
 *
 * ── 为什么要排序 ────────────────────────────────────────────────────────
 * SQL 不保证返回顺序（没有 ORDER BY 时尤其如此）。不排序的话，
 * "顺序变了"会被误报成"值变了"，把测试变成偶发红。
 * 排序的是**规范化后的行文本**，所以与列的物理顺序无关。
 */
func hDumpTable(db: DbBackend, table: String): Array<String> {
    let cols = db.query(
        "SELECT column_name FROM information_schema.columns " +
        "WHERE table_schema = DATABASE() AND table_name = ? ORDER BY ordinal_position",
        [DbStr(table)])
    let names = ArrayList<String>()
    var i: Int64 = 0
    while (i < cols.rowCount()) {
        names.add(cols.getString(i, 0))
        i = i + 1
    }
    if (names.size == 0) {
        return Array<String>()      // 表不存在：返回空数组，由调用方判定
    }
    var collist = ""
    var first = true
    for (n in names) {
        if (!first) {
            collist = collist + ", "
        }
        collist = collist + n
        first = false
    }
    let rs = db.query("SELECT " + collist + " FROM " + table, Array<DbValue>())
    let rows = ArrayList<String>()
    var r: Int64 = 0
    while (r < rs.rowCount()) {
        var line = ""
        var c: Int64 = 0
        while (c < names.size) {
            // 用 \u0001 当列分隔符：正常数据里不会出现，避免"值里含分隔符"造成假一致
            line = line + names[c] + "=" + rs.cell(r, c) + "\u{0001}"
            c = c + 1
        }
        rows.add(line)
        r = r + 1
    }
    let arr = rows.toArray()
    // 插入排序（Array<String> 没有 sort 成员，同 mem_store.sortedIds 的理由）
    var a: Int64 = 1
    while (a < arr.size) {
        let cur = arr[a]
        var b = a - 1
        while (b >= 0 && arr[b] > cur) {
            arr[b + 1] = arr[b]
            b = b - 1
        }
        arr[b + 1] = cur
        a = a + 1
    }
    return arr
}

/* 两份表导出是否逐值一致（含行数）。不一致时打印第一处差异，省得再手工查库。 */
func hDumpEquals(a: Array<String>, b: Array<String>): Bool {
    if (a.size != b.size) {
        println("    行数不同：刷盘前 ${a.size} 行 / 刷盘后 ${b.size} 行")
        return false
    }
    var i: Int64 = 0
    while (i < a.size) {
        if (a[i] != b[i]) {
            println("    差异 @ 第 ${i} 行：")
            println("      刷盘前: ${a[i]}")
            println("      刷盘后: ${b[i]}")
            return false
        }
        i = i + 1
    }
    return true
}

/*
 * 读某挂号单**落库**的 seq_no —— 用于断言"响应值与落库值一致"（AC-12）。
 *
 * 为什么要单独查库：AC-12 要抓的正是"响应说一个、库里存另一个"这类不一致，
 * 所以断言**不能**只信返回值，必须直接读库比对。
 */
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

    /* ---------- AC-11：N 次归还全部成功（与 AC-10 镜像）---------- */
    public func ac11(): Unit {
        println("=== AC-11 N 次归还**不得丢号源**（AC-10 的镜像路径）===")
        section("AC-11", { =>
            /*
             * 这是 2026-10-07 复查发现的**严重**缺陷的回归闸门，也是 AC-10 的镜像：
             * `tryDeductSlot` 去掉 version 后，`releaseSlot` **仍然带 version 前置条件**，
             * 而 `releaseSlotFor` 没有任何重试 —— 于是 N 个并发退号里只有一个能归还成功，
             * 其余永久丢号源。
             *
             * 实测（端到端 10 并发退号）：原实现只归还 5 个、**丢 5 个号源**，
             * 而每个患者都收到"退号成功"的 200。
             *
             * 📌 教训：**同一根因会在镜像路径上重现**。修"扣"时必须顺手核对"还"。
             *   本用例就是把这个核对固化成断言：AC-10 与 AC-11 必须**同时**绿。
             *
             * ⚠ 同为单线程顺序模拟（真并发由 tests\stress-booking.ps1 覆盖）；
             *   它守的不变量是"归还路径不再自我作废"—— version 时代这条**必然失败**。
             */
            hResetAll(db)
            let n: Int64 = 20
            hSeedSchedule(db, 9009, n, "2026-10-08")
            // 先全部借出
            var i: Int64 = 0
            while (i < n) {
                let _ = repo.tryDeductSlot(9009)
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

    /* ---------- AC-4：整体替换刷盘后号源域不变（P1 补完）---------- */
    public func ac4(): Unit {
        println("=== AC-4 内存 Store 整体替换刷盘**不波及**号源域 ===")
        section("AC-4", { =>
            /*
             * ⚠ 本用例在 2026-10-07 被**重写**。P0 时它只做**结构性**断言
             *   （表名零交集），因为那时压根没有内存 Store 可刷 —— 那条边界写在
             *   ADR §5 的"验证边界"里，一直挂到 P1。
             *
             * 现在 `mem_store.cj` 补上了配套域的 Store（照基线 store.cj / writeDbToMysql
             * 的本质：一次事务内整体替换清单里的表），所以本用例可以**真跑一次刷盘**。
             *
             * 四层验证（逐层加强，只做前两层是**弱**的）：
             *   ① **机制**：`MEM_TABLES ∩ BOOKING_DOMAIN_TABLES == ∅`
             *      —— 刷盘的遍历源里就没有号源域，这是根因层的保证；
             *   ② **SQL 痕迹**：把刷盘实际发出的 SQL 全录下来，断言 `schedule` /
             *      `appointment` **从未出现**在**任何一条**语句里
             *      —— 这是"根本没碰"，比"碰了但值没变"强得多；
             *   ③ **逐值比对**：刷盘前后把 schedule / appointment 两表全列读出来比对
             *      —— 防"SQL 里没提但通过别的路径改了"；
             *   ④ **反向**：刷盘**确实**改了它该管的表
             *      —— 否则前三层可能是"因为什么都没做"而假绿（这正是复查反复强调的
             *      "永远绿色的假保证"）。
             */
            hResetAll(db)

            // ① 机制层：两套范式的表集不相交
            let overlap = paradigmOverlap()
            check("① 两套范式表集无交集（MEM_TABLES ∩ BOOKING_DOMAIN_TABLES = ∅）",
                  overlap.size == 0)
            check("① 内存 Store 负责 4 张表", MEM_TABLES.size == 4)
            check("① schedule 不由内存 Store 负责", !isMemStoreTable(TABLE_SCHEDULE))
            check("① appointment 不由内存 Store 负责", !isMemStoreTable(TABLE_APPOINTMENT))
            check("① department 由内存 Store 负责", isMemStoreTable(TABLE_DEPARTMENT))

            /*
             * ★ 从**旧 AC-4** 保留下来的一条断言（2026-10-07 重写时特意没丢）：
             *   全部业务表与基线内存 Store 的**表名零交集**。
             * 旧 AC-4 主体已被"真跑一次刷盘"取代，但这条守的是另一件事 ——
             * P1 引入整库刷盘后，本侧若与基线撞名就会**争同一张表**
             * （`auth_token` 不叫 `tokens` 就是为此）。
             * 表集变了（现 9 张）也要继续守，所以跟着搬过来。
             */
            let baselineTables: Array<String> = ["departments", "members", "plans", "tasks",
                                                 "invite_links", "tokens", "idem",
                                                 "meta", "meta_str", "schema_version"]
            var clash = 0
            for (t in ALL_TABLES) {
                for (bt in baselineTables) {
                    if (t == bt) {
                        clash = clash + 1
                        println("  [FAIL] 表 ${t} 与基线内存 Store 撞名")
                    }
                }
            }
            check("① 全部 ${ALL_TABLES.size} 张表与基线表名零交集", clash == 0)

            /*
             * 造"号源域 + 配套域"同时存在的真实场景：
             * 挂号会产生 appointment/schedule 行，同时我们往内存表里放数据。
             */
            hSeedSchedule(db, 9011, 3, "2026-10-08")
            let a = repo.book(1, 9011, "tok-ac4", hNowEpoch())
            check("造出一张挂号单（号源域有真实数据）", isBooked(a))

            // ③ 的前置：刷盘前把号源域两表**全列**读出来
            let beforeSchedule = hDumpTable(db, "schedule")
            let beforeAppointment = hDumpTable(db, "appointment")
            check("号源域快照非空（否则断言是空比空）",
                  beforeSchedule.size > 0 && beforeAppointment.size > 0)

            // ② 的前置：用录制器包一层，捕获刷盘发出的全部 SQL
            let rec = SqlRecorder(db)
            let mem = MemStore(rec)
            let _ = mem.loadAll()

            // 往内存表里放/改数据，让这次刷盘**确实有活干**
            let dp = MemDepartment()
            dp.id = 9011
            dp.name = "AC4 测试科室"
            dp.code = "AC4"
            dp.location = "测试楼"
            dp.sort = 1
            dp.enabled = true
            dp.createdAt = hNowEpoch()
            mem.departments[dp.id] = dp

            let dc = MemDoctor()
            dc.id = 9011
            dc.name = "AC4 测试医生"
            dc.departmentId = 9011
            dc.title = "医师"
            dc.createdAt = hNowEpoch()
            mem.doctors[dc.id] = dc

            rec.clear()
            let written = mem.flushToMysql()
            check("② 刷盘确实写了行（written = ${written} > 0）", written > 0)

            // ② SQL 痕迹：号源域**从未出现**
            check("② ★ 刷盘 SQL 里从未出现 schedule（含 schedule_id 这类列名不算）",
                  !rec.mentionsTable(TABLE_SCHEDULE))
            check("② ★ 刷盘 SQL 里从未出现 appointment",
                  !rec.mentionsTable(TABLE_APPOINTMENT))
            // ② 反向：该碰的表确实碰了
            let touched = rec.mentionedMemTables()
            check("② 反向：刷盘确实碰了全部 4 张内存表（实碰 ${touched.size} 张）",
                  touched.size == MEM_TABLES.size)

            // ③ 逐值比对：号源域**一个字节都没变**
            let afterSchedule = hDumpTable(db, "schedule")
            let afterAppointment = hDumpTable(db, "appointment")
            check("③ ★ schedule 刷盘前后逐值一致",
                  hDumpEquals(beforeSchedule, afterSchedule))
            check("③ ★ appointment 刷盘前后逐值一致",
                  hDumpEquals(beforeAppointment, afterAppointment))

            // ④ 反向：内存表确实被刷进去了（否则可能"什么都没做"而假绿）
            let cnt = db.query("SELECT COUNT(*) FROM department WHERE id = 9011",
                               Array<DbValue>()).getInt(0, 0)
            check("④ 反向：内存表数据确实落库（department id=9011 存在）", cnt == 1)
            let dcn = db.query("SELECT COUNT(*) FROM doctor WHERE id = 9011",
                               Array<DbValue>()).getInt(0, 0)
            check("④ 反向：doctor id=9011 存在", dcn == 1)

            /*
             * 还剩下的那条边界（如实标注，不冒充已验）：
             * 本 Store 的刷盘是**整表替换**（简化），基线是**脏行裁剪**。
             * 两边都不碰号源域，所以 AC-4 的不变量已验；
             * 但"脏行裁剪的性能收益"没验，也没必要在此验。
             */
            println("  [NOTE] 本 Store 用整表替换（较基线脏行裁剪是**更强**的写放大）——")
            println("         连它都不波及号源域 ⇒ 脏行裁剪版更不会。性能差异不在 AC-4 范围。")
        })
    }

    /* ---------- AC-12：响应里的 seq_no 必须等于落库值 ---------- */
    public func ac12(): Unit {
        println("=== AC-12 就诊序号：响应值 == 落库值 ===")
        section("AC-12", { =>
            /*
             * 复查实测的不一致：退掉 seq=1 的单后再挂，库里落 `seq_no=2`，
             * 而 HTTP 响应报 `seq_no=1`。
             * 根因：响应回填用了 `countBooked()`（统计**当前有效**单数），
             * 而落库用的是 `nextSeqNo()`（`MAX(seq_no)+1`，**不回收**已用过的号）——
             * 两个口径不是一回事。就诊序号是给患者看、用来叫号的，报错号会误导患者。
             *
             * 本用例直接钉住"第一次挂号的返回序号 == 库里那一行的 seq_no"。
             */
            hResetAll(db)
            hSeedSchedule(db, 9010, 5, "2026-10-08")
            let a = repo.book(1, 9010, "tok-ac12-a", hNowEpoch())
            check("第一次挂号成功", isBooked(a))
            check("响应 seq_no = 1", a.seqNo == 1)
            let dbSeq1 = hAppointmentSeqNo(db, a.appointmentId)
            check("落库 seq_no = 1（与响应一致）", dbSeq1 == 1)

            // 退掉它（seq_no 不回收），再挂一单 → 应为 2，且响应与库一致
            let c = repo.cancel(a.appointmentId, hNowEpoch())
            check("退号成功", isCancelled(c))
            let b = repo.book(1, 9010, "tok-ac12-b", hNowEpoch())
            check("退号后再次挂号成功", isBooked(b))
            let dbSeq2 = hAppointmentSeqNo(db, b.appointmentId)
            /*
             * ⚠ 这里**只断言"响应 == 落库"**，不断言"== 2" ——
             *   序号是否连续/是否回收是策略问题，而本用例守的是**一致性**问题
             *   （响应不能说一个、库里存另一个）。策略变了也不该让本用例变红。
             */
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
    runner.ac11()
    runner.ac12()
    /*
     * P2 分诊（定义在 acceptance_triage.cj）。
     * ⚠ 这几个是**独立函数**（不是 TestRunner 的成员），所以要把 runner 与 db 传进去 ——
     *   而它们内部的断言仍走 runner.check，计数照样并入总账。
     *   排在最后：不改变既有 AC-1…AC-12 的执行顺序（那些用例之间有共享夹具的隐含顺序）。
     */
    acP2_1(runner, db)
    acP2_2(runner, db)
    acP2_3(runner, db)
    acP2_4(runner, db)
    acP2_5(runner, db)
    println("")
    println("通过 ${runner.passed} 项，失败 ${runner.failed} 项")
    if (runner.failed == 0) {
        println("✅ 验收测试全部通过")
    } else {
        println("❌ 验收测试失败 ${runner.failed} 项")
    }
    return runner.failed
}
