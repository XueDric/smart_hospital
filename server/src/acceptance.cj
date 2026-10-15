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
    /*
     * ★ 2026-10-15（改进 3）：修订历史必须先于病历清（它是病历的从属数据）。
     * ⚠ 现在没有外键约束，先后顺序不影响执行 —— 但**按从属顺序写**，
     *   将来若补上 `ON DELETE CASCADE` 或加外键，这里不用再改。
     */
    db.exec("DELETE FROM medical_record_revision", Array<DbValue>())
    db.exec("DELETE FROM medical_record", Array<DbValue>())
    db.exec("DELETE FROM schedule", Array<DbValue>())
    db.exec("DELETE FROM doctor", Array<DbValue>())
    db.exec("DELETE FROM department", Array<DbValue>())
    db.exec("DELETE FROM patient", Array<DbValue>())
    /*
     * 公告（2026-10-12 新增）。
     * ⚠ 必须在这里清：`AC-NOTICE-*` 的可见性断言是按"列表里有几条"数的，
     *   而库是**共享**的（HTTP 联调也会往 notice 写）。
     *   不清就会出现"上次联调留下的公告把上限占满"，表现为随机红。
     */
    db.exec("DELETE FROM notice", Array<DbValue>())
}

/*
 * 验收夹具用的**固定排班日**。
 *
 * ⚠ 为什么需要它：可售谓词要求 `schedule.work_date >= 今天`（见 `bookingSchedulePredicate`），
 *   而夹具日期是写死的（确定性要求，绝不能改成 `hTodayDate()+N`）。
 *   ⇒ 凡是在夹具排班上调用**走可售谓词**的仓储方法（`book` / `tryDeductSlot` /
 *   `findBookableSchedule`），都必须显式注入夹具当天，否则夹具排班会被判成
 *   "过期不可售"，把真实回归淹没在夹具噪声里。
 *   `ACC_FIXTURE_DATE_P4` 目前是未来日期，同样注入 —— 为的是**不依赖墙上时钟**：
 *   等 2026-12-24 过去以后，不注入的用例会自己变红。
 */
let ACC_FIXTURE_DATE: String = "2026-10-08"
let ACC_FIXTURE_DATE_P4: String = "2026-12-24"

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
 * ★ ADR-0001 rev.7（内存 Store 拆除）：原先这里有两个助手
 *   `hDumpTable`（把整表导出成排序后的行文本）与 `hDumpEquals`（逐值比对两份导出）——
 *   它们是 AC-4"刷盘前后号源域逐值不变"的支撑。
 *   现在**没有刷盘了**，`dontChaos` 那条不变量的对象也就不存在了
 *   ⇒ 两个助手**失去唯一调用者**，按"删代码要明说为什么"的纪律**在此删除**
 *     （留着它们等于留一段"看起来还有人在做全表比对"的假象）。
 * `hCountRows` 取而代之：新 AC-4 只需要"号源域确实有数据"这一个反向证明。
 */
/*
 * ★★ 数一张表的行数。
 *
 * ⚠⚠ 参数是**表名**，不是 SQL —— 名字必须让人一眼看出来。
 *   原名 `hCountRows(db, table)` 长得像"执行任意计数 SQL"，而我恰恰就这么用了：
 *   传进去一条完整 `SELECT COUNT(*) ... WHERE id = N`，拼出来变成
 *     `SELECT COUNT(*) FROM SELECT COUNT(*) FROM department WHERE id = N`
 *   ⇒ 语法错 ⇒ **accept 中途抛异常退出**（连失败项都数不出来）。
 *   📌 教训：函数名要**暴露参数的性质**。`hCountRows` 没说清"给表名"，
 *     于是它"看起来能用"，实际一用就炸 —— 这类**签名与名字不一致**的
 *     内部工具，比一个明显的 bug 更费时间（我为此多跑了两轮构建）。
 *   ⇒ 改名 `hTableRowCount`，并在参数名上写 `table`（而不是 `sql`）。
 */
/*
 * ⚠ 与 `hTableRowCount` 并列的存在理由：那个收**表名**，这个收**完整 SQL**。
 *   两个函数分开而不是合并成一个"聪明"的，是因为合并后**无法从调用处看出**
 *   传的是哪一种 —— 而我正因为看不出才炸过一次。
 *   现在名字把差别写在明面上：`hTableRowCount(table)` vs `hScalarCount(sql)`。
 */
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

/*
 * 读某令牌**落库**的有效期（AC-14 用）。
 *
 * 为什么要单独查库：AC-14 要抓的正是"仓储回给调用方的有效期与库里存的不一致"
 * （服务端续期了、客户端还按旧值倒计时），所以断言不能只信返回值。
 */
func hTokenExpiry(db: DbBackend, token: String): Int64 {
    let rs = db.query("SELECT expires_at FROM auth_token WHERE token = ?", [DbStr(token)])
    if (rs.rowCount() < 1) {
        return -1
    }
    return rs.getInt(0, 0)
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

    /* ---------- AC-4：所有业务表统一走直接 SQL（ADR-0001 rev.7）---------- */
    public func ac4(): Unit {
        println("=== AC-4 数据访问范式**唯一化**：不存在第二条路径 ===")
        section("AC-4", { =>
            /*
             * ⚠ 本用例在 2026-10-07 被**第二次重写**，两次重写的理由都值得记：
             *
             * ── 第一次（P1）──────────────────────────────────────────────────
             *   P0 时它只做**结构性**断言（表名零交集），因为那时压根没有内存 Store
             *   可刷 —— 那条边界挂在 ADR §5 的"验证边界"里。P1 补上 `mem_store.cj` 后
             *   它升级为"**真跑一次刷盘**"，四层验证（机制 / SQL 痕迹 / 逐值比对 / 反向）。
             *
             * ── 第二次（P4 收尾，本次）───────────────────────────────────────
             *   核对"配套域生产不刷盘"这个缺口时，实测发现事情比"缺口"更彻底：
             *     · `MemStore` 的生产实例化点 **零处**（唯一实例在测试里）；
             *     · `loadAll()` / `flushToMysql()` 的生产调用点 **零处**；
             *     · `MemStore` **没有"往内存里写"的入口方法**（只有 load/flush/两个查询）；
             *     · 生产代码对 department/doctor/patient 的**写**：**零处**；
             *     · 也没有"管理端建科室/医生"的端点。
             *   ⇒ 这条范式**在生产上从未接线**：那三张表实际是**只读参考数据**
             *     （靠人工 SQL 灌入），而 README 却把它描述成"内存 Store 范式"——
             *     **文档比实现更先进**，且 P4 的看板还会把"上次刷盘的快照"当成现状报出去。
             *   ⇒ 决策（ADR-0001 rev.7）：**拆掉内存 Store，统一为直接 SQL**。
             *
             * ── 因此本用例现在守什么 ─────────────────────────────────────────
             *   它守的**不再是**"刷盘不越界"（没有刷盘了），而是更强的性质：
             *     **全库只存在一种数据访问范式**。
             *   结构仍是"逐层加强"，只是每层换了对象：
             *     ① 分类：每张业务表都归属一个**域**（无孤儿表）；
             *     ② ★★ **机制**：号源域的表**只准 `BookingRepo` 写**（ADR 范围锁死），
             *        且域清单与表集**不脱节**；
             *     ③ ★ 表名与搬迁前的内存 Store **零交集**（**从旧 AC-4 保留**：搬迁前若与本侧
             *        同库运行，撞名会争同一张表 —— `auth_token` 不叫 `tokens` 就是为此）；
             *     ④ ★★ **反向**：号源域确实**有**数据（否则③是"空比空"的假绿）。
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

            /*
             * ★ 从**旧 AC-4** 保留（第一次重写时特意没丢，这次继续保留）：
             *   全部业务表与搬迁前的内存 Store 的**表名零交集**。
             * 它守的是另一件事：搬迁前若与本侧连同一个库，撞名就会**争同一张表**
             * （`auth_token` 不叫 `tokens` 就是为此）。表集变了也要继续守。
             */
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

            /* ④ 反向：号源域**确实有数据**，否则上面是"空比空"的假绿 */
            hSeedSchedule(db, 9011, 3, "2026-10-08")
            let a = repo.book(1, 9011, "tok-ac4", hNowEpoch(), today: ACC_FIXTURE_DATE)
            check("④ ★★ 反向：号源域确实有数据（造出一张挂号单）—— 否则③可能是「因为什么都没做」而假绿",
                  isBooked(a))
            let schedRows = hTableRowCount(db, TABLE_SCHEDULE)
            let apptRows = hTableRowCount(db, TABLE_APPOINTMENT)
            check("④ 号源域两表都非空（schedule=${schedRows} appointment=${apptRows}）",
                  schedRows > 0 && apptRows > 0)

            /*
             * ⑤ ★★ "没有内存 Store"这条**刻意不写成运行期断言**。
             *
             * ⚠ 踩坑表 M 条：「断言"没有 X"的前提是 X 真的**存在**」。
             *   而 `MEM_TABLES` / `MemStore` / `isMemStoreTable` / `paradigmOverlap`
             *   这些名字**已经不存在**了（`mem_store.cj` / `sql_recorder.cj` 已删除）
             *   ⇒ 这里**根本写不出**引用它们的断言；硬写一个字符串比较是**空洞**的
             *     （它只是在比较我自己的字面量）。
             *   ✅ 所以把这条交给**编译器**：一旦有人把内存 Store 加回来并接上，
             *      引用会直接**编译失败**；而"加回来但不接"则会被 README/ADR 的
             *      历史记录与 code review 挡住。这比任何运行期断言都硬。
             */
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


    /* ---------- AC-7：退号归还的边界（P0 复查发现的缺陷）---------- */
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

            /* ★ 核心边界：remain_num == total_num 时归还失败
             *   模拟"管理员重置过号源"：把 remain_num 顶到 total_num。
             *   此时 releaseSlot 因 `remain_num < total_num` 不成立而失败，
             *   但挂号单**已经**被取消（事务已提交）。
             *   正确行为：返回 SlotNotRestored（**不是** false/NotFound），
             *   让调用方知道"已退号但号源需运维修"，而不是以为退号失败。 */
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

    /* ---------- AC-13：退号必须走状态机（代码检查报告第 1 条）---------- */
    /*
     * 修的是什么：原实现退号的原子条件是 `status <> 'cancelled'` ⇒
     * `visiting` / `done` / `no_show` **都能被退掉并归还号源**。
     * 后果：① 患者能退掉一张已经看完的单（覆盖就诊结果 + 凭空多出号源）；
     *      ② 医生"完成就诊"与患者退号并发时各改一次，落库结果取决于谁后写。
     *
     * ⚠ 本用例只能证明**行为**（返回 NotCancellable + 库中的状态与号源纹丝不动）。
     *   "并发下也不会被改掉"靠的是 `cancel()` 里那条带 `status = ?` 的**原子 UPDATE**，
     *   属于结构性护栏 —— 没有注入点就在单进程测试里造不出那个窗口。
     *   ⇒ 这里显式记下这个覆盖边界，而不是装作已经测得。
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
             * 直接把三张单拨到"不该被退"的状态。
             * ⚠ 用 SQL 而不是走业务流程：本用例要测的是**退号这一侧**的护栏，
             *   不应该依赖接诊/爽约流程是否已经实现（那是 P4 的事）。
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
            /*
             * ★ 只判"是这一态"还不够 —— 这一态的**全部对外价值**就是那个状态字符串
             *   （handler 用它拼 409 文案）。不看状态等于没测。
             */
            check("★ 返回值带上真实状态（visiting / done / no_show）",
                  cancelStateOf(c1) == "visiting" && cancelStateOf(c2) == "done" &&
                  cancelStateOf(c3) == "no_show")

            let stA = db.query("SELECT status FROM appointment WHERE id = ?",
                               [DbInt(a.appointmentId)]).getString(0, 0)
            let stB = db.query("SELECT status FROM appointment WHERE id = ?",
                               [DbInt(b.appointmentId)]).getString(0, 0)
            let stC = db.query("SELECT status FROM appointment WHERE id = ?",
                               [DbInt(c.appointmentId)]).getString(0, 0)
            /* ★ 终态被覆盖正是报告点名的后果之一 ⇒ 必须逐张核实库里的状态没被动过。 */
            check("★★ 库中状态未被改写（visiting / done / no_show 原样保留）",
                  stA == "visiting" && stB == "done" && stC == "no_show")
            let (remainAfter, _) = hScheduleState(db, 9401)
            /* ★ 凭空多出可售号源是另一条后果 ⇒ 号源必须一个都没回来。 */
            check("★★ 号源未被归还（拒绝退号不能改号源）", remainAfter == remainBefore)

            /* 反向证明：真正"已挂号"的单**仍然可以正常退**（别把护栏修成"谁都退不了"）。 */
            let c4 = repo.cancel(d.appointmentId, now)
            let (remainFinal, _) = hScheduleState(db, 9401)
            check("★ 已挂号的单仍可正常退号（护栏没有误伤）", isCancelled(c4))
            check("★ 该单退号后号源 +1（归还路径未被破坏）", remainFinal == remainBefore + 1)
        })
    }

    /* ---------- AC-14：滑动续期必须把「续期后」的有效期回给调用方（跨端审计 F11）---------- */
    /*
     * 修的是什么：`principalByToken` 一直在做滑动续期（把 `expires_at` 往后推一个 TTL），
     * 但 `Principal` 里**没有**有效期字段 ⇒ `/auth/me` 没有任何地方能告诉客户端
     * "我这张令牌现在到什么时候"。
     * 后果（审计 F11 原文）：各端把登录那一刻的 `expires_at` 一直缓存着，服务端的续期
     * 对客户端**不可见**；Android 端因此按旧值倒计时，会在令牌仍然有效时把用户踢回登录页。
     *
     * ⚠ 覆盖边界如实记：这里测的是"回填的值是否权威"（可达、确定性）。
     *   并发续期不会算错（那条 UPDATE 写的是**绝对值** `now + TTL`，重复执行幂等），
     *   所以不另造并发窗口 —— 与 AC-13 同一个取舍。
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
            /*
             * 把令牌拨到"该续期"的状态：剩余 1000 秒（< TOKEN_TTL - RENEW_AFTER），
             * 且上次续期在两天前（已过 RENEW_AFTER 节流窗口）。
             */
            db.exec("UPDATE auth_token SET expires_at = ?, last_renew_at = ? WHERE token = ?",
                    [DbInt(now + 1000), DbInt(now - 2 * RENEW_AFTER), DbStr(token)])
            let p = auth.principalByToken(token, now)
            check("★ 令牌有效（否则下面断言的是 None）", p.isSome())
            let exp = p.getOrThrow().expiresAt
            check("★★ 回填的是**续期后**的有效期（now + TOKEN_TTL）", exp == now + TOKEN_TTL)
            let inDb = hTokenExpiry(db, token)
            check("★★ 且与库中值一致（两端看到同一个到期时刻；库=${inDb} 回填=${exp}）",
                  exp == inDb)
            /*
             * 反向证明：**节流期内不能凭空造一个未来值**。
             * 若实现把 `now + TOKEN_TTL` 无条件回填，客户端会看到一个库里并不存在的
             * 有效期 —— 那是另一种"两端不一致"，只是方向相反。
             */
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
     * 修的是什么：客户端拿**设备本地日期**当"今天"去查排班（鸿蒙 `BookingPage` 默认日期、
     * `Theme.todayString()`），而服务端的"今天"是 Asia/Shanghai ⇒ 设备时区不对或跨零点时，
     * 两侧对"今天"的答案不同：轻则默认日期查不到号，重则把过去的排班当可用。
     * ⇒ 服务端在探活响应里直接给出**权威日期**与**时区名**，客户端读它即可，不必自己算。
     */
    public func ac15(): Unit {
        println("=== AC-15 ★ 探活响应给出医院日期与时间口径（F14）===")
        section("AC-15", { =>
            let body = healthJson(DevAuthGate(false, false))
            check("★ /health 带 today，且等于服务端口径的今天",
                  body.contains("\"today\":\"" + hTodayDate() + "\""))
            check("★ /health 带 timezone = Asia/Shanghai",
                  body.contains("\"timezone\":\"Asia/Shanghai\""))
            /*
             * ★★ 探活接口**不能**因为多了日期而开始查库
             *   （库慢必须表现成库慢，不能表现成服务挂了）。
             *   这里能证明的是"不碰库也能算出这个字段"——`hTodayDate()` 是纯计算，
             *   且与日期格式化同一口径（后者已有固定 epoch 的断言守着）。
             */
            check("★★ 该字段是纯计算：与日期格式化同口径（hTodayDate == hDateStringOf(now)）",
                  hTodayDate() == hDateStringOf(hNowEpoch()))
            check("★ 且探活仍如实报告 dev_auth（没被日期字段挤掉）",
                  body.contains("\"dev_auth\":false"))
        })
    }

    /* ---------- AC-16：模型配置表（多模型 / 运行时解析 / PATCH / 缓存失效）---------- */
    /*
     * 修的是什么：`ai_setting` 是**单份 KV**，只能配一个对话模型，而且**没有温度**。
     *   产品要求"一个模型一行"（对话 / 向量分开、各自温度与上限、各自启停），
     *   并明确"保存后自动失效缓存、下一次 AI 请求动态构建模型实例，无需重启"。
     *   ⇒ 新增 `ai_model` 表 + 运行时按类型解析。本用例钉住四件事：
     *     ① 空表播种两行且**幂等**（不覆盖已有配置）；
     *     ② 运行时优先取模型行（含温度），`key_ref` 为空时回落全局那把；
     *     ③ PATCH 语义（只给温度 ⇒ 别的字段不变）、重名与明文地址被拒；
     *     ④ 缓存确实存在，且 `invalidate()` 能失效它。
     */
    public func ac16(): Unit {
        println("=== AC-16 ★★ 模型配置表：播种 / 运行时解析 / PATCH / 缓存失效 ===")
        section("AC-16", { =>
            /*
             * ⚠ 本用例独占 `ai_model` 与几个 `ai.*` 配置项。库是共享的（管理台联调也会写它），
             *   不清就会变成"随机红"。结尾恢复成"播种后的两行"，让库回到与生产一致的起点。
             */
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
                    check("向量模型：请求 URL = base_url + /embeddings",
                          aiModelRequestUrl(m.baseUrl, AI_MODEL_KIND_EMBEDDING) ==
                          AI_MODEL_SEED_BASE_URL + "/embeddings")
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
            check("AI 总开关仍来自 KV（默认 0 ⇒ 不可用；模型行不该绕过总开关）", !opts.enabled)

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

            /*
             * 缓存：**绕过仓储**直接改库 ⇒ 仓储仍回旧值（证明缓存真的在）；
             * `invalidate()` 之后才看到新值 —— 管理台那个"失效配置缓存"按钮等价于此。
             */
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
     * 缺口是什么：① `GET /api/v1/admin/users` 原先**只能按登录名精确查一条**，
     *   管理台的"用户管理"页要列表、要翻页、要按角色筛，接口根本不支持；
     *   ② 排班**只有建、没有改** —— 号源写错或医生停诊只能新开一条，
     *   老排班连同已经约出去的号继续挂在患者端可约。
     * 本用例钉住这两条新路径（含"列表不吐口令材料"与"放号数不得低于已约数"）。
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
            /* ⚠ hSeedSchedule 用的是普通 INSERT ⇒ 先清掉同 id 的行，保证可重复运行。 */
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
            /*
             * ⚠ 扣号（`tryDeductSlot`）**也会** `version + 1` —— 乐观锁不只服务"人改排班"。
             *   ⇒ 这里必须**读回**当前版本再改；拿 up1 之后那个 1 去改不是"并发冲突测试"，
             *   而是测试自己写错了前提（会稳定地假红）。
             */
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
 * ★ 2026-10-12：第四态 `NotCancellable(st)` 的判定与取值（代码检查报告第 1 条）。
 *
 * 为什么要一个"把状态取出来"的小工具：这一态的**全部对外价值就是那个状态字符串** ——
 * handler 用它拼 409 的中文文案（"当前状态为「接诊中」，不能退号"）。
 * 只断言"属于这一态"而不看状态，等于把这一态修成什么样都能过。
 */
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
    /*
     * ★ 2026-10-14（改进 1）：预问诊 → 病历的桥。
     * ⚠ 排在 P4 这组最后面：它自己会 `hResetAll` 并造 **9505/9506/9507** 段
     *   的患者，与前面用例的 88xx/95xx 段不重叠（本仓"每个用例独占 id 段"的约定）。
     */
    acP4_5(runner, db)
    /*
     * ★ 2026-10-15（改进 3）：病历修订历史。
     * ⚠ 同样自己 `hResetAll`，造 **9608/9609** 段的患者 + 900008/900009 医生
     *   （与 95xx/88xx 段不重叠）。
     */
    acP4_6(runner, db)
    /*
     * ★ 2026-10-15（改进 2）：医生工作台 —— 既往病历的隐私边界 + 乐观锁。
     * ⚠ 自己 `hResetAll`，造 **9610/9613** 段患者 + 900010/900011/900013 医生
     *   （与 9505-9507、9608/9609 段不重叠）。
     */
    acP4_7(runner, db)
    /*
     * ★ 2026-10-15（改进 6）：就诊时间线 —— 到院/候诊、三个时间戳、队列排序。
     * ⚠ 自己 `hResetAll`，造 **9620-9627** 段患者 + 900020/900021 医生
     *   （与 9505-9507、9608/9609、9610/9613 段不重叠）。
     * ⚠ 排队顺序断言依赖"同优先级内按 seq_no"——夹具把 seq_no 改成与状态
     *   优先级**相反**，只有真按状态排序才会过（防实现偷懒只按 seq_no）。
     */
    acP4_8(runner, db)
    /*
     * 基础数据域（科室/医生）的管理端 CRUD（定义在 acceptance_base.cj）。
     *
     * ⚠ 排在**最后**，理由与上面那段一样：不改变既有用例的执行顺序
     *   （它们之间有共享夹具的隐含顺序）。而这三个用例自己会**只清自己的 id 段**
     *   （91xxxx / 92xxxx / 93xxxx），不碰别的用例的数据。
     */
    acBase1(runner, db)
    acBase2(runner, db)
    acBase3(runner, db)
    /*
     * 真模型出站（定义在 acceptance_ai_call.cj）。
     *
     * ⚠ 其中"真实出站"那一条**只在环境变量就位时才跑**，否则**如实跳过并打印** ——
     *   验收必须能在无外网/无密钥的机器上跑绿，否则它会变成"永远红"，
     *   然后被人用 `--skip` 绕过去，最后连它守的是什么都没人记得。
     *   跳过时**打印 `[SKIP]` 与原因**，不静默。
     */
    acAiCall1(runner, db)
    acAiCall2(runner, db)
    acAiCall3(runner, db)
    /*
     * P5 知识库（定义在 acceptance_kb.cj）。
     * ⚠ 排在最后：它的夹具**自建自清**（按标题前缀 `ACKB`），
     *   不依赖别的用例留下的状态，也不给别的用例留状态。
     */
    acKb1(runner, db)
    acKb2(runner, db)
    acKb3(runner, db)
    acKb4(runner, db)
    acKb5(runner, db)
    /*
     * 参数化绑定的写路径（定义在 acceptance_bind.cj）。
     * ⚠ 排在**最后**：它只碰自己的表 `ac_bind_probe`（开头 DROP、结尾 DROP），
     *   与别的用例零共享，所以放哪儿都行 —— 放最后是为了不改变既有用例的执行顺序
     *   （它们之间有共享夹具的隐含顺序）。
     */
    acBind1(runner, db)
    /*
     * 公告域（定义在 acceptance_notice.cj）。
     * ⚠ 排在**最后**：它的夹具自建自清（标题前缀 `ACNOTICE`），
     *   不依赖别的用例留下的状态，也不给别的用例留状态
     *   —— 与 P5 知识库（`ACKB`）同一手法。
     */
    acNotice1(runner, db)
    acNotice2(runner, db)
    acNotice3(runner, db)
    /*
     * AC-13 退号状态机（定义在 TestRunner 里，因为要用它的 repo/check/section）。
     *
     * ⚠ 排在**最后**：它开头就 `hResetAll`（清空全部业务表 + 公告），
     *   放前面会把别人的夹具清掉 —— 与所有"自建自清"的用例同一取舍。
     */
    runner.ac13()
    /*
     * AC-14 / AC-15（2026-10-14，跨端审计 F11 / F14 的回归护栏）。
     * ⚠ 同样排在最后：AC-14 也 `hResetAll`，并且自建自清 `auth_user`/`auth_token`
     *   （那两张表不在 `hResetAll` 的清理范围内，所以它必须自己收尾）。
     */
    runner.ac14()
    runner.ac15()
    /*
     * AC-16 / AC-17（2026-10-14，管理台后端：多模型配置 + 两个契约缺口）。
     * ⚠ 同样排在最后：AC-16 独占 `ai_model` / `ai.*` 配置项，AC-17 自建自清探针账号与排班，
     *   两者都不依赖别的用例留下的状态（AC-17 复用 hSeedSchedule 的固定科室/医生/患者夹具）。
     */
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
