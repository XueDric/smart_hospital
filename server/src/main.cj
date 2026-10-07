/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 *
 * ===== main.cj —— 进程入口 ================================================
 *
 * P0 阶段本文件只做两件事：
 *   1. 给出可编译、可运行的进程入口（让构建链与部署形态先立起来）；
 *   2. `selftest` 子命令：**不需要数据库**地自检 schema 与 ADR-0001 的不变量，
 *      让「号源域范围锁死」这类约定有可执行的闸门，而不只是文档里的一句话。
 *
 * 用法：
 *   hospital-server.exe selftest        # 纯本地自检，无需 MySQL
 *   hospital-server.exe check-db <dsn>  # 连库：建表 + 打印表清单（P0 联调用）
 *
 * ⚠ 入口签名照框架口径：`main(args: Array<String>)`，其中 **args[0] 即第一个参数**
 *   （不含 exe 路径）—— 见 baseline/server/third_party/qingzhou/src/main.cj:15-17。
 *
 * ⚠ P0 尚未接路由与 HTTP 服务 —— 那属 P1（挂号闭环）。此处**刻意不**先写
 *   一个空壳 listen，避免"看起来能跑其实没接口"的假象。
 */

package qingzhou

/* 版本号：与 docs/adr/ADR-0001 同期。 */
public let SERVER_VERSION: String = "0.1.0-p0"

func usage(): Unit {
    println("智慧医院智能导诊就诊系统 · 服务端 ${SERVER_VERSION}")
    println("")
    println("用法：")
    println("  hospital-server.exe selftest              纯本地自检（无需 MySQL）")
    println("  hospital-server.exe check-db <dsn>        连库建表并打印表清单")
    println("  hospital-server.exe accept <dsn>          跑 P0 验收测试（ADR-0001 AC-1…AC-6）")
    println("  hospital-server.exe version               打印版本")
    println("")
    println("DSN 格式：mysql://user:pass@host:port/db")
    println("  本机联调示例：mysql://hospital:hospital_dev_2026@127.0.0.1:3307/hospital")
    println("")
    println("⚠ P0 阶段尚未提供 HTTP 接口（属 P1 挂号闭环）。")
}

/*
 * check-db：连库 + 幂等建表 + 打印表清单。
 * 返回失败项数（0 = 成功）。
 */
func checkDb(dsn: String): Int64 {
    var db: DbBackend
    try {
        let cfg = parseDsn(dsn)
        println("连接：${cfg.describe()}")
        db = openDatabase(cfg)
    } catch (e: Exception) {
        println("❌ ${e.message}")
        return 1
    }
    let n = ensureSchema(db)
    println("建表：执行 ${n} 条 DDL（IF NOT EXISTS，幂等）")
    println("")
    println("表清单：")
    let rs = db.query("SHOW TABLES", Array<DbValue>())
    var i: Int64 = 0
    while (i < rs.rowCount()) {
        let name = rs.getString(i, 0)
        var mark = "  "
        if (isBookingDomainTable(name)) {
            mark = "★ "      // 号源域（走直接 SQL，ADR-0001）
        }
        println("  ${mark}${name}")
        i = i + 1
    }
    println("")
    println("（★ = 号源/挂号域，走直接 SQL；其余属内存 Store 范式，见 ADR-0001 §4.2）")
    db.close()
    return 0
}

/*
 * accept：跑 P0 验收测试。
 * ⚠ 会**清空业务表**，只能对着专用测试库跑，绝不可指向有数据的库。
 */
func accept(dsn: String): Int64 {
    var db: DbBackend
    try {
        let cfg = parseDsn(dsn)
        if (!cfg.db.contains("test") && cfg.db != "hospital") {
            println("⚠ 警告：目标库是 '${cfg.db}'，看起来不是专用测试库。")
            println("  验收测试会清空业务表。中止。")
            return 2
        }
        println("连接：${cfg.describe()}")
        db = openDatabase(cfg)
        ensureSchema(db)
    } catch (e: Exception) {
        println("❌ ${e.message}")
        return 1
    }
    println("")
    let failed = runAcceptance(db)
    db.close()
    return failed
}

/*
 * selftest：把"文档里的约定"变成"可执行的断言"。
 *
 * 为什么值得单独做：ADR-0001 §4.3 把架构债关进笼子的手段之一就是
 * 「直接 SQL 仅限 schedule / appointment 两张表，新增第三张必须再开 ADR」。
 * 这条约定如果只写在文档里，下一次加表的人必然违反；写成断言才拦得住。
 *
 * 返回：失败项数（0 = 全通过），便于 CI 用退出码判定。
 */
func selftest(): Int64 {
    var failed: Int64 = 0

    func check(name: String, ok: Bool): Unit {
        if (ok) {
            println("  [PASS] ${name}")
        } else {
            println("  [FAIL] ${name}")
            failed = failed + 1
        }
    }

    println("=== schema 自检 ===")

    // 1) 七张最小表齐备（brief §10 Q2 建议最小集 7 张）
    check("最小表集为 7 张（实际 ${ALL_TABLES.size}）", ALL_TABLES.size == 7)

    // 2) 每张**业务表**都有对应 DDL。
    //    ⚠ 不能断言 `SCHEMA_DDL.size == ALL_TABLES.size` —— DDL 数组里还可以有
    //      不带业务模型的表（如将来的 meta / schema_version），那样断言会误报。
    //       所以按"表名能否在 DDL 里找到"来判，这才是真正要防的漂移。
    var ddlMiss = 0
    for (t in ALL_TABLES) {
        var hit = false
        for (sql in SCHEMA_DDL) {
            if (sql.contains("CREATE TABLE IF NOT EXISTS ${t} ")) {
                hit = true
            }
        }
        if (!hit) {
            ddlMiss = ddlMiss + 1
        }
        check("表 ${t} 有对应 DDL", hit)
    }
    check("每张业务表都有 DDL（缺 ${ddlMiss} 张）", ddlMiss == 0)
    check("DDL 条数不少于业务表数（${SCHEMA_DDL.size} ≥ ${ALL_TABLES.size}）",
          SCHEMA_DDL.size >= ALL_TABLES.size)

    // 3) 已移除的旧表名不应再出现（防改名只改一半）
    var staleIdem = false
    for (sql in SCHEMA_DDL) {
        if (sql.contains("CREATE TABLE IF NOT EXISTS idem ")) {
            staleIdem = true
        }
    }
    check("DDL 里没有裸 'idem' 表（已改名 booking_idem）", !staleIdem)

    // 4) 全部 DDL 幂等（IF NOT EXISTS）+ utf8mb4
    for (sql in SCHEMA_DDL) {
        if (!sql.contains("IF NOT EXISTS")) {
            println("  [FAIL] 非幂等 DDL：${sql}")
            failed = failed + 1
        }
        if (!sql.contains("utf8mb4")) {
            println("  [FAIL] DDL 缺 utf8mb4：${sql}")
            failed = failed + 1
        }
    }

    // 5) ★ ADR-0001 §4.3 范围锁死：直接 SQL 域
    //    —— 业务状态表**只准**两张；幂等基础设施表单列（不是业务状态）
    check("号源域业务状态表恰为 2（${BOOKING_DOMAIN_TABLES.size}）", BOOKING_DOMAIN_TABLES.size == 2)
    check("号源域幂等基础设施表恰为 1", BOOKING_INFRA_TABLES.size == 1)
    check("schedule 属号源域", isBookingDomainTable(TABLE_SCHEDULE))
    check("appointment 属号源域", isBookingDomainTable(TABLE_APPOINTMENT))
    check("department 不属号源域", !isBookingDomainTable(TABLE_DEPARTMENT))
    check("doctor 不属号源域", !isBookingDomainTable(TABLE_DOCTOR))
    check("patient 不属号源域", !isBookingDomainTable(TABLE_PATIENT))
    check("medical_record 不属号源域", !isBookingDomainTable(TABLE_MEDICAL_RECORD))
    check("booking_idem 不是业务状态表", !isBookingDomainTable(TABLE_BOOKING_IDEM))
    check("booking_idem 是幂等基础设施表", isBookingInfraTable(TABLE_BOOKING_IDEM))
    check("booking_idem 由 BookingRepo 拥有", isBookingOwnedTable(TABLE_BOOKING_IDEM))
    check("department 不由 BookingRepo 拥有", !isBookingOwnedTable(TABLE_DEPARTMENT))

    // 5b) ★ 与基线内存 Store 的表名**零交集**（P1 整库刷盘不会争表）
    //     基线表名见 baseline/server/src/mysql_store.cj:309-311
    let baselineTables: Array<String> = ["departments", "members", "plans", "tasks",
                                         "invite_links", "tokens", "idem",
                                         "meta", "meta_str", "schema_version"]
    var clash = 0
    for (t in ALL_TABLES) {
        for (bt in baselineTables) {
            if (t == bt) {
                println("  [FAIL] 表 ${t} 与基线内存 Store 撞名")
                clash = clash + 1
            }
        }
    }
    check("本侧 7 张表与基线内存 Store 表名零交集（含 idem 改名生效）", clash == 0)
    check("本侧不再有裸 'idem' 表", !isBookingOwnedTable("idem"))

    // 6) ★ 防超卖两支柱必须在 DDL 里（ADR AC-2 / AC-1）
    var hasVersion = false
    var hasRemain = false
    var hasVisitDate = false
    var hasClientToken = false
    for (sql in SCHEMA_DDL) {
        if (sql.contains("version BIGINT")) { hasVersion = true }
        if (sql.contains("remain_num BIGINT")) { hasRemain = true }
        if (sql.contains("visit_date VARCHAR")) { hasVisitDate = true }
        if (sql.contains("client_token VARCHAR")) { hasClientToken = true }
    }
    check("schedule 有 version 乐观锁列", hasVersion)
    check("schedule 有 remain_num 列", hasRemain)
    check("appointment 有 visit_date 就诊日快照列", hasVisitDate)
    check("appointment 有 client_token 幂等键列", hasClientToken)

    println("")
    if (failed == 0) {
        println("✅ 自检全部通过")
    } else {
        println("❌ 自检失败 ${failed} 项")
    }
    return failed
}

main(args: Array<String>): Int64 {
    // args[0] 即第一个参数（不含 exe 路径）
    if (args.size < 1) {
        usage()
        return 0
    }
    let cmd = args[0]
    // 注：这里用 if 链而非 match —— 仓颉的 match 分支体是**单表达式**，
    // 而这些分支需要多语句（这坑在 domain_booking.cj 也踩过一次）。
    if (cmd == "version") {
        println(SERVER_VERSION)
        return 0
    }
    if (cmd == "selftest") {
        return selftest()
    }
    if (cmd == "check-db") {
        if (args.size < 2) {
            println("用法：hospital-server.exe check-db <dsn>")
            return 2
        }
        return checkDb(args[1])
    }
    if (cmd == "accept") {
        if (args.size < 2) {
            println("用法：hospital-server.exe accept <dsn>")
            return 2
        }
        return accept(args[1])
    }
    println("未知子命令：${cmd}")
    println("")
    usage()
    return 2
}
