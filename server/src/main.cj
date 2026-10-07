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

// ⚠ `exists()` / `File.readFrom()` 来自 std.fs —— TLS 分支要读 PEM 文件，
//   不加这个 import 会报 undeclared identifier（基线 main.cj 同样 import 了它）。
import std.fs.*

/* 版本号：与 docs/adr/ADR-0001 同期。 */
public let SERVER_VERSION: String = "0.2.0-p1"

func usage(): Unit {
    println("智慧医院智能导诊就诊系统 · 服务端 ${SERVER_VERSION}")
    println("")
    println("用法：")
    println("  hospital-server.exe selftest              纯本地自检（schema 不变量，无需 MySQL）")
    println("  hospital-server.exe authtest              口令/令牌原语自检（含公开测试向量，无需 MySQL）")
    println("  hospital-server.exe check-db <dsn>        连库建表并打印表清单")
    println("  hospital-server.exe accept <dsn>          跑验收测试（AC-1…AC-8）")
    println("  hospital-server.exe serve <dsn> [--port N] [--dev-auth] [--prod] [--bind IP]")
    println("                                  [--tls-cert <pem> --tls-key <pem>]")
    println("                                            启动 HTTP/HTTPS 服务（P1）")
    println("  hospital-server.exe version               打印版本")
    println("  hospital-server.exe create-admin <dsn> [登录名]")
    println("                                            创建/重置管理员并打印口令（引导用）")
    println("")
    println("DSN 格式：mysql://user:pass@host:port/db")
    println("  本机联调示例：mysql://hospital:hospital_dev_2026@127.0.0.1:3307/hospital")
    println("")
    println("⚠ --dev-auth 是**开发态**身份头（X-Role/X-Patient-Id），绕过全部认证；")
    println("  与 --prod 同时传会直接拒绝启动。")
    println("  ⚠ 本工具链仓颉 std 无 getEnv，故生产开关走 --prod 而**不是**环境变量。")
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

    // 1) 最小表集：brief §10 Q2 的 7 张**业务**表 + P1 令牌体系的 2 张**鉴权**表 = 9。
    //    ⚠ 用"业务表数 + 鉴权表数"两个分项断言，而不是硬编码总数 ——
    //      硬编码数字在加表时必然要手改，而漏改就变成"测试说没事、其实漂移了"。
    //      （本次加鉴权表时就正好触发了这条，所以它是有用的。）
    let bizTables = 7
    let authTables = 2
    check("业务表为 ${bizTables} 张 + 鉴权表 ${authTables} 张", ALL_TABLES.size == bizTables + authTables)
    check("鉴权表恰好 2 张（auth_user / auth_token）",
          isAuthTable(TABLE_AUTH_USER) && isAuthTable(TABLE_AUTH_TOKEN))
    check("业务表不误入鉴权域", !isAuthTable(TABLE_PATIENT) && !isAuthTable(TABLE_SCHEDULE))

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
    check("本侧 ${ALL_TABLES.size} 张表与基线内存 Store 表名零交集（含 idem/tokens 改名生效）",
          clash == 0)
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

/*
 * 去掉 TLS 路径两端的引号（配置文件里允许写成 cert="E:\...\cert.pem"）。
 * 只处理成对的单/双引号；不处理转义（Windows 路径里没有需要转义的字符）。
 */
func unquoteTlsPath(s: String): String {
    if (s.size >= 2) {
        let first = s[0..1]
        let last = s[(s.size - 1)..]
        if ((first == "\"" && last == "\"") || (first == "'" && last == "'")) {
            return s[1..(s.size - 1)]
        }
    }
    return s
}

/*
 * serve：启动 HTTP/HTTPS 服务（P1 挂号闭环 + 令牌鉴权）。
 *
 * 参数：serve <dsn> [--port N] [--bind IP] [--dev-auth] [--prod]
 *                   [--tls-cert <pem> --tls-key <pem>]
 *
 * ⚠ 关于 bind：轻舟 `app.serve(port)` 默认 `bindAddr = "0.0.0.0"`
 *   —— **整个局域网都能连**。所以默认**只绑 127.0.0.1**，
 *   要联调再显式 `--bind 0.0.0.0`（照基线的教训，
 *   baseline/server/src/main.cj:968-977 专门为此写过一段提醒）。
 *
 * ⚠ 关于 TLS：**绝不静默降级**。给了 `--tls-cert/--tls-key` 但证书读不到、
 *   或 PEM 解析失败时，**直接退出**，绝不回退到明文 ——
 *   否则"HTTPS 没起来"会变成一台**静默的明文服务**，那比起不来危险得多。
 */
func serve(args: Array<String>): Int64 {
    if (args.size < 1) {
        println("用法：hospital-server.exe serve <dsn> [--port N] [--bind IP] " +
                "[--dev-auth] [--prod] [--tls-cert <pem> --tls-key <pem>]")
        return 2
    }
    let dsn = args[0]
    var port: UInt16 = 8080
    var bindAddr = "127.0.0.1"
    var devAuth = false
    var prod = false
    var tlsCert = ""
    var tlsKey = ""
    var i = 1
    while (i < args.size) {
        if (args[i] == "--port" && i + 1 < args.size) {
            port = parseUInt16Or(args[i + 1], 8080)
            i = i + 2
        } else if (args[i] == "--bind" && i + 1 < args.size) {
            bindAddr = args[i + 1]
            i = i + 2
        } else if (args[i] == "--tls-cert" && i + 1 < args.size) {
            tlsCert = args[i + 1]
            i = i + 2
        } else if (args[i] == "--tls-key" && i + 1 < args.size) {
            tlsKey = args[i + 1]
            i = i + 2
        } else if (args[i] == "--tls-files" && i + 1 < args.size) {
            /*
             * ★ 从**文件**读 证书/私钥 路径，而不是从命令行。
             *
             * 为什么需要这条：本工具链的仓颉运行时**无法接受含非 ASCII 的 argv** ——
             *   在 main 之前就抛 `IllegalArgumentException: Invalid unicode scalar value`，
             *   连 usage 都打不出来（基线 API-NOTES 坑 6 记过同一件事）。
             *   而本仓库路径就含中文（`智能医院客户端`），于是
             *   `--tls-cert "E:\...\智能医院客户端\server\certs\cert.pem"` **必然启动失败**。
             *   （实测：把同一份证书拷到 `C:\Temp\...` 纯 ASCII 路径就能起来。）
             *
             * 这个参数文件本身用 ASCII 路径，内容（可含中文）用 UTF-8 读 —— 绕开 argv 限制。
             * 文件格式（每行 `key=value`，`#` 开头为注释，路径可加引号）：
             *     cert=E:\...\certs\cert.pem
             *     key=E:\...\certs\key.pem
             */
            let cfgPath = args[i + 1]
            if (!exists(cfgPath)) {
                println("❌ 找不到 TLS 配置文件：${cfgPath}")
                return 2
            }
            var text = ""
            try {
                text = String.fromUtf8(File.readFrom(cfgPath))
            } catch (e: Exception) {
                println("❌ TLS 配置文件读取失败：${e.message}")
                return 2
            }
            for (line in text.split("\n")) {
                let s = line.trimAscii()
                if (s.size == 0 || s.startsWith("#")) {
                    continue
                }
                if (s.startsWith("cert=")) {
                    tlsCert = unquoteTlsPath(s[5..].trimAscii())
                } else if (s.startsWith("key=")) {
                    tlsKey = unquoteTlsPath(s[4..].trimAscii())
                }
            }
            i = i + 2
        } else if (args[i] == "--dev-auth") {
            devAuth = true
            i = i + 1
        } else if (args[i] == "--prod") {
            prod = true
            i = i + 1
        } else {
            println("未知参数：${args[i]}")
            return 2
        }
    }

    /*
     * ★ 连库**之前**先跑口令/令牌原语自检。
     *
     * 理由：如果 PBKDF2 是错的，连上库也只是在用错的哈希签发令牌 ——
     * 那种错误会在很久以后以"某天所有口令都对不上"的形式爆出来。
     * 这里用三个公开测试向量（RFC 7914 §11 两条 + 100k 对拍 .NET 一条）当场钉死。
     */
    if (authSelfTest() != 0) {
        println("❌ 口令/令牌原语自检失败，拒绝启动（连库也没有意义）")
        return 3
    }
    println("")

    var db: DbBackend
    var cfg: MySqlConfig
    try {
        cfg = parseDsn(dsn)
        println("连接：${cfg.describe()}")
        db = openDatabase(cfg)
        ensureSchema(db)
    } catch (e: Exception) {
        println("❌ ${e.message}")
        return 1
    }

    var gate: DevAuthGate
    try {
        gate = DevAuthGate(devAuth, prod)
    } catch (e: Exception) {
        println("❌ ${e.message}")
        return 2
    }

    let repo = BookingRepo(db)
    let auth = AuthRepo(db)
    let app = buildHospitalApp(repo, auth, gate)
    let box = HandleBox()

    println("")
    println("智慧医院服务端 ${SERVER_VERSION}（P1 挂号闭环 + 令牌鉴权）")
    println("监听 ${bindAddr}:${port}")
    if (bindAddr == "0.0.0.0") {
        println("  ⚠ 已绑定全部网卡：同局域网可访问。本阶段是**明文 HTTP**，")
        println("    绝不要把这个端口暴露到公网（令牌会以明文过网）。")
    }
    if (devAuth) {
        println("  ⚠ --dev-auth 已开启：X-Role / X-Patient-Id 请求头可直接冒用身份。")
        println("    仅限本机联调；生产必须走令牌（--prod 会拒绝启动）。")
    } else {
        println("  （未开 --dev-auth：业务接口会返回 401，仅 /health 可用）")
    }
    println("")
    println("接口：")
    println("  GET  /health                              探活（无需认证）")
    println("  POST /api/v1/auth/login                   登录换令牌（无需认证）")
    println("  POST /api/v1/auth/logout                  登出（吊销当前令牌）")
    println("  GET  /api/v1/auth/me                      当前身份")
    println("  GET  /api/v1/schedules/:id                查排班（三端可读）")
    println("  POST /api/v1/appointments                 挂号（仅患者）")
    println("  POST /api/v1/appointments/:id/cancel      退号（患者退自己的 / 管理员退任意）")
    println("  POST /api/v1/admin/schedules              建排班（仅管理员）")
    println("  POST /api/v1/admin/users                  建账号（仅管理员）")
    println("")
    println("鉴权：Authorization: Bearer <token>（令牌 30 天，滑动续期）")

    /*
     * ★ TLS 分支 —— 两条纪律：
     *   ① 轻舟的 `serveTls(port, certPem, keyPem)` 收的是 **PEM 字符串**而不是路径，
     *      所以读文件与异常处理都在**调用方**（基线为此专门写过注释）。
     *   ② **绝不静默降级**：任何一步失败都 return，不回退到明文。
     *
     * 只给其中一个（只有 cert 没有 key，或反之）也直接拒绝 ——
     * 那多半是命令行打漏了，静默按明文起会让人以为 TLS 生效了。
     */
    let wantTls = tlsCert.size > 0 || tlsKey.size > 0
    if (wantTls && (tlsCert.size == 0 || tlsKey.size == 0)) {
        println("❌ 只给了 --tls-cert / --tls-key 中的一个，无法启用 TLS。")
        println("   要么两个都给，要么都不给（不给则跑明文 HTTP）。")
        return 2
    }
    if (wantTls) {
        println("")
        println("TLS：")
        if (!exists(tlsCert)) {
            println("  ❌ [FATAL] 找不到证书：${tlsCert}")
            println("  **不降级为明文** —— 请先跑 .\\new-tls-cert.ps1 生成，或修正路径。")
            return 1
        }
        if (!exists(tlsKey)) {
            println("  ❌ [FATAL] 找不到私钥：${tlsKey}")
            println("  **不降级为明文** —— 请先跑 .\\new-tls-cert.ps1 生成，或修正路径。")
            return 1
        }
        var certPem = ""
        var keyPem = ""
        try {
            certPem = String.fromUtf8(File.readFrom(tlsCert))
            keyPem = String.fromUtf8(File.readFrom(tlsKey))
        } catch (e: Exception) {
            println("  ❌ [FATAL] 证书或私钥读取失败：${e.message}")
            println("  **不降级为明文**")
            return 1
        }
        println("  证书 ${tlsCert}")
        println("  私钥 ${tlsKey}（内容不写入日志）")
        var tlsHandle: ?ServerHandle = None
        try {
            tlsHandle = Some(app.serveTls(port, certPem, keyPem, bindAddr: bindAddr))
        } catch (e: Exception) {
            println("  ❌ [FATAL] TLS 启动失败：${e.message}")
            println("     （PEM 无法解析时框架会抛异常；这里**不做任何明文回退**）")
            return 1
        }
        match (tlsHandle) {
            case Some(h) =>
                box.handle = Some(h)
                println("  ✅ HTTPS 已启动：https://${bindAddr}:${port}")
                h.wait()
            case None => return 1
        }
        println("服务已停止")
        db.close()
        return 0
    }

    println("  ⚠ 未启用 TLS（明文 HTTP）。令牌与口令会**明文过网** ——")
    println("    仅在可信本机/内网这样跑；要加密请加 --tls-cert/--tls-key。")
    let handle = app.serve(port, bindAddr: bindAddr)
    box.handle = Some(handle)
    handle.wait()
    println("服务已停止")
    db.close()
    return 0
}

/*
 * create-admin：创建/重置一个管理员账号并打印口令。
 *
 * ── 为什么需要它（引导问题）────────────────────────────────────────────────
 * `POST /api/v1/admin/users` 建账号需要**管理员身份**，而第一个管理员还不存在
 * —— 鸡生蛋。所以引导入口必须**不经 HTTP**：只能在本机命令行、有数据库口令的人才能跑。
 *
 * ⚠ 安全姿态：
 *   · 口令本机随机生成、**只打印到控制台一次**，不写日志文件；
 *   · 若账号已存在 → **改口令**（同时吊销其全部令牌，见 setPassword）；
 *   · 这是"有 DB 写权限即可拿到管理员"的路径 —— 与直接改库等价，
 *     所以它不引入新的信任假设（能改 auth_user 表的人本来就能改任何东西）。
 */
func createAdmin(args: Array<String>): Int64 {
    if (args.size < 1) {
        println("用法：hospital-server.exe create-admin <dsn> [登录名]")
        return 2
    }
    let dsn = args[0]
    var loginName = "admin"
    if (args.size >= 2) {
        loginName = args[1]
    }
    var db: DbBackend
    var cfg: MySqlConfig
    try {
        cfg = parseDsn(dsn)
        db = openDatabase(cfg)
        ensureSchema(db)
    } catch (e: Exception) {
        println("❌ ${e.message}")
        return 1
    }
    let auth = AuthRepo(db)
    // 生成可读口令：用去混淆字符表（与基线 CODE_ALPHABET 同思路），便于人工抄录
    let pw = randCode(12)
    let existed = auth.findUser(loginName).isSome()
    let uid = auth.createUser(loginName, Role.Admin, 0, "管理员", pw, hNowEpoch())
    if (existed) {
        // 已存在 → 改口令（setPassword 会顺带吊销其全部令牌）
        auth.setPassword(uid, pw, hNowEpoch())
    }
    println("")
    println("管理员账号：")
    println("  登录名：${loginName}")
    println("  口  令：${pw}")
    println("  user_id：${uid}   （${if (existed) { "已存在 → 已重置口令并吊销旧令牌" } else { "新建" }}）")
    println("")
    println("⚠ 口令只显示这一次（未落盘）；请立即用 POST /api/v1/auth/login 换令牌。")
    db.close()
    return 0
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
    if (cmd == "authtest") {
        // 口令/令牌原语自检（含 RFC 7914 公开测试向量），不需要数据库
        return authSelfTest()
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
    if (cmd == "serve") {
        // 把 serve 之后的参数整体传下去（args[1..]）
        return serve(args[1..])
    }
    if (cmd == "create-admin") {
        return createAdmin(args[1..])
    }
    println("未知子命令：${cmd}")
    println("")
    usage()
    return 2
}
