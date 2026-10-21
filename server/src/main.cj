/*
 * SPDX-License-Identifier: MIT
 *
 * 智慧医院智能导诊就诊系统 · 服务端
 *
 * main.cj —— 进程入口：子命令分发（serve / accept / selftest / check-db / create-admin / create-db）。
 * 入口签名照框架口径：main(args: Array<String>)，args[0] 即第一个子命令（不含 exe 路径）。
 * 约束：selftest 与口令原语自检必须在**不连库**时也能跑 —— 「号源域范围锁死」这类约定靠它成为可执行闸门，而不是文档里的一句话。
 */

package qingzhou

// ⚠ `exists()` / `File.readFrom()` 来自 std.fs —— TLS 分支要读 PEM 文件，不加这个 import 会报 undeclared identifier。
import std.fs.*
// ⚠ `HashSet` 来自 std.collection —— serve 用它记"哪些 flag 已出现过"：重复 flag 必须报错，不能静默后者覆盖前者。
import std.collection.*

/* 版本号：与 docs/adr/ADR-0001 同期。 */
public let SERVER_VERSION: String = "0.2.0-p1"

func usage(): Unit {
    println("智慧医院智能导诊就诊系统 · 服务端 ${SERVER_VERSION}")
    println("")
    println("用法：")
    println("  hospital-server.exe selftest              纯本地自检（schema 不变量，无需 MySQL）")
    println("  hospital-server.exe authtest              口令/令牌原语自检（含公开测试向量，无需 MySQL）")
    println("  hospital-server.exe check-db <dsn>        连库建表并打印表清单")
    println("  hospital-server.exe accept <dsn>          跑验收测试（AC-1…AC-17，只允许库名含 test 的库）")
    println("  hospital-server.exe triagetest            分诊纯逻辑自检（不碰库、不调模型）")
    println("  hospital-server.exe serve <dsn> [--port N] [--dev-auth] [--prod] [--bind IP]")
    println("                                  [--tls-cert <pem> --tls-key <pem>]")
    println("                                  [--tls-files <env>]")
    println("                                            启动 HTTP/HTTPS 服务（P1）")
    println("                                  --tls-files 从文件读 cert=/key= 路径（绕开 argv 的中文限制）")
    println("  hospital-server.exe version               打印版本")
    println("  hospital-server.exe --help                打印本说明（退出码 0）")
    println("  hospital-server.exe create-admin <dsn> [登录名]")
    println("                                            创建/重置管理员并打印口令（引导用）")
    println("  hospital-server.exe create-db <dsn> [--admin-dsn <dsn>]  建库 + 授权（utf8mb4）")
    println("")
    println("DSN 格式：mysql://user:pass@host:port/db")
    /*
     * ⚠ 提示里不写死端口：usage 是使用者第一眼看到的东西，写一个本项目不用的端口会直接把人引到错处。
     * 只给**形状**示例，端口与口令等部署事实指向 docs/dev/DEV-DB.md —— 不复制就没有第二次漂移的机会。
     */
    println("  本机联调示例：mysql://hospital:<口令>@127.0.0.1:<端口>/hospital")
    println("  ⚠ 端口与口令**以 docs/dev/DEV-DB.md 为准**（那是唯一事实来源；本提示刻意不写死，免得漂移）")
    println("")
    println("⚠ --dev-auth 是**开发态**身份头（X-Role/X-Patient-Id），绕过全部认证；")
    println("  与 --prod 同时传会直接拒绝启动。")
    println("  ⚠ 且**只接受来自本机回环地址（127.0.0.1 / ::1）的请求**：")
    println("     仍建议保持默认 --bind 127.0.0.1；绑 0.0.0.0 时远程请求会拿到 401。")
    println("  ⚠ 本工具链仓颉 std 无 getEnv，故生产开关走 --prod 而**不是**环境变量。")
}

/* check-db：连库 + 幂等建表 + 打印表清单；返回失败项数（0 = 成功）。 */
func checkDb(dsn: String): Int64 {
    var db: DbBackend
    /* ⚠ `cfg` 必须声明在 try **外面** —— catch 要用它拼处置命令里的库名，而仓颉没有变量提升。 */
    var cfg: MySqlConfig
    try {
        cfg = parseDsn(dsn)
        println("连接：${cfg.describe()}")
        db = openDatabase(cfg)
    } catch (e: Exception) {
        println("❌ ${e.message}")
        return 1
    }
    /*
     * ★★ 建表 + 迁移必须**包在 try/catch 里**：放在 try 之外时，权限不足会抛未捕获异常 + 驱动内部堆栈，对使用者毫无用处（真正原因在最后一行）。
     * 仓内规矩是「失败必须被说出来，不能靠崩溃表达」；accept / serve / create-admin 三处早就包好了，check-db 是最后一份。
     */
    var n: Int64 = 0
    var migrated: Int64 = 0
    try {
        n = ensureSchema(db)
        // 存量库靠 DDL 改不动，必须显式迁移（见 migrateSchema 注释）
        migrated = migrateSchema(db)
    } catch (e: Exception) {
        println("❌ 建表/迁移失败：${e.message}")
        println("")
        /* 这个报错极可能是权限不够（而不是 SQL 写错）：库是新造的、账号只有全局 CREATE 是本项目已知的配置形态，所以直接给最可能的处置，不让人去猜堆栈。 */
        println("   处置（按可能性排序）：")
        println("   ① **账号对该库没有 DDL 权限**（最常见）—— 用管理员执行：")
        println("        GRANT ALL PRIVILEGES ON `" + cfg.db + "`.* TO `" + cfg.user + "`@`localhost`;")
        println("        FLUSH PRIVILEGES;")
        println("      （跑 `create-db <同一条 DSN>` 也会打印这条现成命令）")
        println("   ② 上一步 create-db 是否**成功**？库不存在时会先在这里失败")
        println("   ③ DSN 是否指到了预期的库")
        db.close()
        return 1
    }
    println("建表：执行 ${n} 条 DDL（IF NOT EXISTS，幂等）")
    if (migrated > 0) {
        println("迁移：执行了 ${migrated} 条结构变更")
    }
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
    println("（★ = 号源/挂号域，由 BookingRepo 独占；**全部表统一走直接 SQL** —— ADR-0001 rev.7：内存 Store 已拆除）")
    db.close()
    return 0
}

/*
 * accept：跑验收测试。会**清空业务表**（appointment / schedule / doctor / department / patient），所以只允许对显式标记为测试用的库名跑。
 * 安全闸门：只认 `test` 作为**独立下划线分段**的形态（test / test_* / *_test / *_test_*），`hospital`（唯一生产库名）不再例外 —— 原判据恰好对那个真会丢数据的库名放行。
 */
func isTestDatabase(dbName: String): Bool {
    /*
     * 判据必须按**分段**判，不能用 `dbName.contains("test")`：`hospital_contest`、`latest_hospital` 都含 test 却不是测试库。
     * 有意的边界：`hospital_test_backup_2025` 会被放行（含 `_test_` 分段）—— 备份库清空不伤生产；若连备份也不许清，就把形态收紧成精确白名单。
     */
    let low = dbName.toAsciiLower()
    if (low == "test") {
        return true
    }
    if (low.startsWith("test_")) {
        return true
    }
    if (low.endsWith("_test")) {
        return true
    }
    return low.contains("_test_")
}

/* 取取值型参数的值，缺值报错：后面必须还有 token，且该 token 不以 `--` 开头 —— 否则 `--bind --prod` 会把 `--prod` 当绑定地址吞掉。 */
func flagValueAt(args: Array<String>, i: Int64, flag: String): ?String {
    if (i + 1 >= args.size) {
        println("❌ ${flag} 缺少取值")
        return None
    }
    let v = args[i + 1]
    if (v.startsWith("--")) {
        println("❌ ${flag} 缺少取值（下一个 token 是 '${v}'，看起来是另一个参数）")
        return None
    }
    return Some(v)
}

/* `path` 存在**且是目录**：不能用 `exists(path)`（判任意文件系统条目）—— 同名文件会让日志说"已挂载"，而每个 `/admin/...` 都 404。 */
func isDirectoryPath(path: String): Bool {
    try {
        let fi = FileInfo(path)
        return fi.isDirectory()
    } catch (e: Exception) {
        return false
    }
}

/*
 * 找管理台静态目录：候选按**相对进程工作目录**，覆盖三种启动方式（在 server/ 下跑、在仓库根跑、在 server/build/ 下直接跑 exe）；返回空串 = 没找到（调用方告警且不挂载）。
 * ⚠ 判据是"**目录**存在"，不是"任意同名条目存在"；失败时把找过哪些候选、解析成什么绝对路径一起打出来，否则"找不到"和"路径拼错了"在日志上一模一样。
 */
func pickAdminWebDir(): String {
    let candidates = ["admin-web", "server/admin-web", "../admin-web"]
    var i = 0
    while (i < candidates.size) {
        if (isDirectoryPath(candidates[i])) {
            return candidates[i]
        }
        i = i + 1
    }
    return ""
}

/* 找不到管理台目录时的告警：文案要含"试过哪些候选 + 解析后的绝对路径"，并打印 CWD —— CWD 是排障的第一现场。 */
func printAdminWebMissingHint(): Unit {
    println("  ⚠ 未找到管理台静态目录。依次试过（相对进程工作目录）：")
    let candidates = ["admin-web", "server/admin-web", "../admin-web"]
    for (c in candidates) {
        var abs = c
        try {
            abs = canonicalize(c).toString()
        } catch (e: Exception) {
            abs = "(无法解析)"
        }
        println("       ${c}   →  ${abs}")
    }
    /* ⚠ 插值里**不能**再写转义引号（会报 unterminated string interpolation）—— 先在语句外把值算好再插进来。 */
    var cwdText = "(无法解析)"
    try {
        cwdText = canonicalize(".").toString()
    } catch (e: Exception) {
        cwdText = "(无法解析)"
    }
    println("    当前工作目录：${cwdText}")
    println("    API 不受影响，但浏览器后台 /admin/ 不可用。请从 `server/` 目录启动。")
}


func accept(dsn: String): Int64 {
    var db: DbBackend
    try {
        let cfg = parseDsn(dsn)
        if (!isTestDatabase(cfg.db)) {
            println("❌ 拒绝执行：目标库 '${cfg.db}' 不是显式测试库。")
            println("   accept 会**清空业务表**（挂号/病历/排班/科室/医生/患者/公告），")
            println("   所以只允许库名含 `test` 的库。")
            println("   例：mysql://.../<your>_test  （或先建一个 hospital_test 库）")
            return 2
        }
        println("连接：${cfg.describe()}")
        db = openDatabase(cfg)
        ensureSchema(db)
        // ★ 存量库靠 DDL 是改不动的（CREATE TABLE IF NOT EXISTS 对已有表无效），必须显式迁移
        let migrated = migrateSchema(db)
        if (migrated > 0) {
            println("迁移：执行了 ${migrated} 条结构变更")
        }
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
 * selftest：把文档里的约定变成可执行断言。ADR-0001 §4.3 的「直接 SQL 仅限 schedule / appointment，新增第三张必须再开 ADR」只写在文档里，下一次加表的人必然违反；写成断言才拦得住。
 * 返回失败项数（0 = 全通过），便于 CI 用退出码判定。
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

    /*
     * 1) 表集分类断言：用**分项**断言而不是硬编码总数 —— 硬编码数字在加表时必然要手改，漏改就变成"测试说没事、其实漂移了"。
     * 分类按**留存与写入纪律**划分（号源/挂号域的直接 SQL 两张、基础数据域、鉴权域、预问诊域、病历域、知识库域、公告域），并断言各类互不重叠、并集 == ALL_TABLES —— "加表时忘了归类"才会立刻变红。
     */
    /*
     * ⚠ 这几个数**必须与来源一致**，能派生的就派生：硬编码数字与事实脱节，靠"总数对不上"那条断言抓住。
     * 教训：删一个概念时先问"挂在它下面的实体去哪" —— 连实体一起删 = 数据丢失，连分类一起删 = 断言数不上账；正确做法是**重新归类并写明新纪律**。
     */
    let bookingTables = BOOKING_DOMAIN_TABLES.size
    /* ★ 基础数据域（取代原「配套域（走内存 Store）」）：department / doctor / patient 直接 SQL 读；
       科室与医生有管理端 CRUD（`http_base.cj`），**患者档案仍没有写入端点**，只能人工 SQL / 导入维护。 */
    let baseTables = 3
    let authTables = 3
    let previsitTables = 1
    let aiTables = 1        // ai_setting（P3 AI 能力中心；直接 SQL、非号源域、非医疗数据）
    /* ★ P4 两张表各成一类（纪律不同）：medical_record —— 临床数据，直接 SQL，`MedicalRecordRepo` 独占；triage_stat —— 只存计数、不含患者标识、带 TTL。 */
    /* ★ 病历域两张：medical_record 与 medical_record_revision 同为临床数据（长期留、不设 TTL、同一仓储独占写），故合进一类；差别只是主体可改、修订行不可变。 */
    let emrTables = 2       // medical_record / medical_record_revision（临床数据，直接 SQL，MedicalRecordRepo 独占）
    let statTables = 1      // triage_stat（聚合统计，只存计数，带 TTL）
    /* ★ 知识库域：kb_doc（文档）+ kb_chunk（切块，含 embedding JSON 或 NULL）合成一类 —— 纪律相同：本院人员维护、不含患者个人信息、直接 SQL。 */
    let kbTables = 2        // kb_doc / kb_chunk（知识库，P5）
    /* ★ 公告域：notice 是**给人看**的展示内容，不进检索、不出站、不含患者信息、带 `published_at`（可预排期）；知识库会随 Prompt 出站，公告不会，故不合并。 */
    let noticeTables = 1
    let totalTables = bookingTables + baseTables + authTables + previsitTables + aiTables +
                      emrTables + statTables + kbTables + noticeTables
    check("表集共 ${totalTables} 张 = 号源域 ${bookingTables} + 基础数据域 ${baseTables}（department/doctor/patient，直接 SQL、无写入端点） + 鉴权域 ${authTables} + 预问诊域 ${previsitTables} + AI 配置域 ${aiTables} + 病历域 ${emrTables} + 统计域 ${statTables} + 知识库域 ${kbTables} + 公告域 ${noticeTables}（★ 无「内存 Store 域」：rev.7 已拆除）",
          ALL_TABLES.size == totalTables)
    check("号源/挂号域恰好 ${bookingTables} 张（schedule / appointment）",
          BOOKING_DOMAIN_TABLES.size == bookingTables)
    check("★ 预问诊表**不**属号源域（否则会被误当作可扣号路径）",
          !BOOKING_DOMAIN_TABLES.contains(TABLE_PREVISIT))
    check("★ AI 配置表**不**属号源域（它是配置，不是可扣号路径）",
          !BOOKING_DOMAIN_TABLES.contains(TABLE_AI_SETTING))
    check("★ 基础数据域恰好 ${baseTables} 张，且这三张**都不属**号源域",
          !BOOKING_DOMAIN_TABLES.contains(TABLE_DEPARTMENT) &&
          !BOOKING_DOMAIN_TABLES.contains(TABLE_DOCTOR) &&
          !BOOKING_DOMAIN_TABLES.contains(TABLE_PATIENT))
    /* ★★ medical_record 由 `MedicalRecordRepo` **直接 SQL** 独占写入：内存 Store 从不刷盘，写病历会只写内存；只保留"表名口径一致"这条断言（仓储的锚点）。 */
    check("★★ 病历表名口径一致（MedicalRecordRepo 的锚点）",
          TABLE_MEDICAL_RECORD == "medical_record")
    check("★ 分诊统计表**不**属号源域（它不是可扣号路径）",
          !BOOKING_DOMAIN_TABLES.contains(TABLE_TRIAGE_STAT))
    /* ⚠ 写成"3 张表各判一次"而不是跨行 `&&` 串联 —— 跨行时 cjc 报 possibly confusing line terminator，分次 check 更清楚。 */
    check("鉴权表恰好 ${authTables} 张（auth_user / auth_token / auth_login_attempt）",
          isAuthTable(TABLE_AUTH_USER) && isAuthTable(TABLE_AUTH_TOKEN) && isAuthTable(TABLE_AUTH_ATTEMPT))
    check("业务表不误入鉴权域", !isAuthTable(TABLE_PATIENT) && !isAuthTable(TABLE_SCHEDULE))

    // 2) 每张**业务表**都有对应 DDL。⚠ 不能断言 `SCHEMA_DDL.size == ALL_TABLES.size` —— DDL 里还可以有不带业务模型的表（如 meta / schema_version），那样会误报；按"表名能否在 DDL 里找到"判。
    var ddlMiss = 0
    for (t in ALL_TABLES) {
        var hit = false
        for (sql in allSchemaDdl()) {
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
    check("DDL 条数不少于业务表数（${allSchemaDdl().size} ≥ ${ALL_TABLES.size}）",
          allSchemaDdl().size >= ALL_TABLES.size)

    /* 3) ★ DDL 里不得出现以 `idem` 命名的表（**长期纪律**）：`booking_idem` 已作为死代码删除，这条断言改为**防止它被复活**；
       同时守着撞名风险 —— 搬迁前的内存 Store 占用了 `idem` 表名，整库刷盘后同名表会争同一张表。 */
    var staleIdem = false
    for (sql in allSchemaDdl()) {
        if (sql.contains("CREATE TABLE IF NOT EXISTS idem")) {
            staleIdem = true
        }
    }
    check("DDL 里没有任何以 idem 命名的表（不得与搬迁前撞名，也不得复活死代码）", !staleIdem)

    // 4) 全部 DDL 幂等（IF NOT EXISTS）+ utf8mb4
    for (sql in allSchemaDdl()) {
        if (!sql.contains("IF NOT EXISTS")) {
            println("  [FAIL] 非幂等 DDL：${sql}")
            failed = failed + 1
        }
        if (!sql.contains("utf8mb4")) {
            println("  [FAIL] DDL 缺 utf8mb4：${sql}")
            failed = failed + 1
        }
    }

    // 5) ★ ADR-0001 §4.3 范围锁死：直接 SQL 域**只准**这两张业务状态表
    check("号源域业务状态表恰为 2（${BOOKING_DOMAIN_TABLES.size}）", BOOKING_DOMAIN_TABLES.size == 2)
    check("schedule 属号源域", isBookingDomainTable(TABLE_SCHEDULE))
    check("appointment 属号源域", isBookingDomainTable(TABLE_APPOINTMENT))
    check("department 不属号源域", !isBookingDomainTable(TABLE_DEPARTMENT))
    check("doctor 不属号源域", !isBookingDomainTable(TABLE_DOCTOR))
    check("patient 不属号源域", !isBookingDomainTable(TABLE_PATIENT))
    check("medical_record 不属号源域", !isBookingDomainTable(TABLE_MEDICAL_RECORD))
    check("schedule 由 BookingRepo 拥有", isBookingOwnedTable(TABLE_SCHEDULE))
    check("appointment 由 BookingRepo 拥有", isBookingOwnedTable(TABLE_APPOINTMENT))
    check("department 不由 BookingRepo 拥有", !isBookingOwnedTable(TABLE_DEPARTMENT))
    // ★ 表集里不得有 idem 命名的表（防止死代码复活）
    var idemLike = 0
    for (t in ALL_TABLES) {
        if (t.contains("idem")) {
            idemLike = idemLike + 1
        }
    }
    check("表集里没有以 idem 命名的表", idemLike == 0)

    /*
     * ★★ 5a-2) 出错提示里的端口必须**配置驱动**、不许写死：原提示写死 127.0.0.1:3307（本项目 devdb 早已是 3317，3307 属本机另一台实例），devdb 没起来时提示把人引到错处。
     * 只断言"默认端口 = 3306"这类编译期事实，不在这里读源码断言文案：selftest 跑在 build/ 下，读源码依赖工作目录；文案的端到端断言放在 create-db-check.ps1 / emr-check.ps1（那才是"配置驱动"的直接证据）。
     */
    let dflt = MySqlConfig()
    check("★ 默认 MySQL 端口 = 3306（协议标准口）—— 原值曾是**本机另一台实例的端口**，" +
          "而本项目没有任何实例在那 ⇒ 是个**假默认**，会让「没拿到 DSN」与「端口写错」长得一样",
          dflt.port == 3306)
    check("★ 默认配置可打印（seed-cfg）且与实测口径一致：${dflt.describe()}",
          dflt.describe() == "hospital@127.0.0.1:3306/hospital")

    // 5b) ★ 与搬迁前的内存 Store 的表名**零交集**（整库刷盘不会争表），搬迁前表名见 mysql_store.cj:309-311
    let legacyTables: Array<String> = ["departments", "members", "plans", "tasks",
                                         "invite_links", "tokens", "idem",
                                         "meta", "meta_str", "schema_version"]
    var clash = 0
    for (t in ALL_TABLES) {
        for (bt in legacyTables) {
            if (t == bt) {
                println("  [FAIL] 表 ${t} 与搬迁前的内存 Store 撞名")
                clash = clash + 1
            }
        }
    }
    check("本侧 ${ALL_TABLES.size} 张表与搬迁前的内存 Store 表名零交集", clash == 0)

    // 6) ★ 防超卖两支柱必须在 DDL 里（ADR AC-2 / AC-1）
    var hasVersion = false
    var hasRemain = false
    var hasVisitDate = false
    var hasClientToken = false
    for (sql in allSchemaDdl()) {
        if (sql.contains("version BIGINT")) { hasVersion = true }
        if (sql.contains("remain_num BIGINT")) { hasRemain = true }
        if (sql.contains("visit_date VARCHAR")) { hasVisitDate = true }
        if (sql.contains("client_token VARCHAR")) { hasClientToken = true }
    }
    // ⚠ 文案订正：version 列还在，但 rev.3 起**不是**扣号的前置条件了（别再叫它"乐观锁列"）
    check("schedule 有 version 列（供管理端防覆盖；rev.3 起不参与扣号）", hasVersion)
    check("schedule 有 remain_num 列", hasRemain)
    check("appointment 有 visit_date 就诊日快照列", hasVisitDate)
    check("appointment 有 client_token 幂等键列", hasClientToken)

    /* ★★ DSN 解析：多字节（中文）内容不得被切坏。`parseDsn` 把 `lastIndexOf("@")` 的**字节**偏移当字节用，实测安全（分隔符 `/` `@` `:` 都是单字节 ASCII），
       但这是"碰巧对"：前提没写在代码里，故钉成断言 —— 谁把分隔符改成多字节、或改用字符下标，这里立刻变红。 */
    println("")
    println("=== DSN 解析（多字节输入）===")
    let dsnCases: Array<(String, String, String, String, String)> = [
        // dsn, 期望 user, 期望 pass, 期望 host, 期望 db
        ("mysql://hospital:pw@127.0.0.1:3317/hospital_test", "hospital", "pw", "127.0.0.1", "hospital_test"),
        // 密码含中文（3 字节字符）
        ("mysql://hospital:密码2026@127.0.0.1:3317/hospital_test", "hospital", "密码2026", "127.0.0.1", "hospital_test"),
        // 库名含中文
        ("mysql://hospital:pw@127.0.0.1:3317/医院_test", "hospital", "pw", "127.0.0.1", "医院_test"),
        // 用户名含中文
        ("mysql://管理员:pw@127.0.0.1:3317/db_test", "管理员", "pw", "127.0.0.1", "db_test"),
        // 三项全含中文
        ("mysql://管理员:密码@主机:3317/库_test", "管理员", "密码", "主机", "库_test"),
        // 无端口（默认 3306）
        ("mysql://u:p@localhost/db_test", "u", "p", "localhost", "db_test")
    ]
    var dsnAllOk = true
    for ((dsn, wu, wp, wh, wd) in dsnCases) {
        try {
            let c = parseDsn(dsn)
            if (c.user != wu || c.pass != wp || c.host != wh || c.db != wd) {
                dsnAllOk = false
                println("        '${dsn}' -> user='${c.user}' pass='${c.pass}' host='${c.host}' db='${c.db}'")
            }
        } catch (e: Exception) {
            dsnAllOk = false
            println("        '${dsn}' 抛异常：${e.message}")
        }
    }
    check("★ ${dsnCases.size} 条 DSN（含中文用户名/密码/主机/库名）解析正确", dsnAllOk)

    /* ★★ 医院时区 Asia/Shanghai：服务端算"今天"曾是 UTC，中国每天 00:00–08:00 与患者端差一天 ⇒ 早上挂不了当天的号。
       ⚠ 用**固定 epoch** 断言而不是比较 now()：now() 只在恰好落在那 8 小时窗口时才红，其余 16 小时恒绿（永远为真的测试比没有更坏）。 */
    println("")
    println("=== 医院时区（Asia/Shanghai）===")
    // 1791736200 = UTC 16:30 = 北京时间次日 00:30 ⇒ UTC 还是前一天、上海已跨零点：这就是那 8 小时窗口。
    check("★★ 跨零点：UTC 10-11T16:30 在上海应算 2026-10-12", hDateStringOf(1791736200) == "2026-10-12")
    // 1791732600 = UTC 15:30 = 北京时间 23:30（未跨零点）
    check("★ 未跨零点：UTC 10-11T15:30 在上海应算 2026-10-11", hDateStringOf(1791732600) == "2026-10-11")
    // 1791763200 = UTC 00:00 = 北京时间 08:00（整点边界）
    check("★ 整点边界：UTC 10-12T00:00 在上海应算 2026-10-12", hDateStringOf(1791763200) == "2026-10-12")
    check("★★ 「今天」与日期格式化同一口径（hTodayDate == hDateStringOf(now)）",
          hTodayDate() == hDateStringOf(hNowEpoch()))

    println("")
    if (failed == 0) {
        println("✅ 自检全部通过")
    } else {
        println("❌ 自检失败 ${failed} 项")
    }
    return failed
}

/* 去掉 TLS 路径两端的引号（配置里允许写成 cert="E:\...\cert.pem"）；只处理成对的单/双引号，不处理转义。 */
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
 * serve：启动 HTTP/HTTPS 服务（挂号闭环 + 令牌鉴权）。参数：serve <dsn> [--port N] [--bind IP] [--dev-auth] [--prod] [--tls-cert <pem> --tls-key <pem>]
 * 安全约束：默认**只绑 127.0.0.1**（轻舟 `app.serve` 默认 0.0.0.0 = 整个局域网都能连），要联调再显式 `--bind 0.0.0.0`。TLS **绝不静默降级**：证书读不到或 PEM 解析失败直接退出，绝不回退明文。
 */
func serve(args: Array<String>): Int64 {
    if (args.size < 1) {
        println("用法：hospital-server.exe serve <dsn> [--port N] [--bind IP] " +
                "[--dev-auth] [--prod] [--tls-cert <pem> --tls-key <pem>]")
        return 2
    }
    let dsn = args[0]
    var port: UInt16 = 8091  // ★ 2026-10-17：8080→8091，与客户端默认值对齐（改端口要同步改客户端默认 Base URL）
    var bindAddr = "127.0.0.1"
    var devAuth = false
    var prod = false
    var tlsCert = ""
    var tlsKey = ""
    var tlsFilesGiven = false
    /*
     * ★★ 取值型参数**必须**带走一个值，且 flag 不得重复：原来 `--bind` / `--tls-*` 直接吞下一个 token，于是 `--bind --prod` 把 `--prod` 当绑定地址 ⇒ `DevAuthGate(true, false)` 放行，"生产不允许 --dev-auth"这条唯一安全闸门输在参数解析上。
     * 口径：① 缺值、或下一个 token 以 `--` 开头 ⇒ 报"缺少取值"退 2；② 任何 flag 重复出现 ⇒ 退 2（原先"最后写的赢"是隐式规则，`--tls-cert` 与 `--tls-files` 会互相覆盖而毫无提示）。
     */
    var seenFlags = HashSet<String>()
    var i = 1
    while (i < args.size) {
        let flag = args[i]
        if (seenFlags.contains(flag)) {
            println("❌ 参数重复：${flag}（同一参数只允许给一次；否则\"谁覆盖谁\"会变成隐藏规则）")
            return 2
        }
        seenFlags.add(flag)
        if (flag == "--port") {
            // ⚠ 严格解析：原用 `parseUInt16Or(x, 8080)`，非数字（`--port abc`）会**静默退回 8080** 照常启动；`--port 0` 也是陷阱（parse 成功但不是合法监听端口）。
            let rawOpt = flagValueAt(args, i, "--port")
            if (rawOpt.isNone()) {
                return 2
            }
            let raw = rawOpt.getOrThrow()
            let parsedOk = parseUInt16OrNone(raw)
            if (parsedOk.isNone()) {
                println("❌ --port 的值不是合法端口号：'${raw}'（期望 1~65535）")
                return 2
            }
            let pv = parsedOk.getOrThrow()
            if (pv == 0) {
                println("❌ --port 不能为 0")
                return 2
            }
            port = pv
            i = i + 2
        } else if (flag == "--bind") {
            let vOpt = flagValueAt(args, i, "--bind")
            if (vOpt.isNone()) {
                return 2
            }
            bindAddr = vOpt.getOrThrow()
            i = i + 2
        } else if (flag == "--tls-cert") {
            let vOpt = flagValueAt(args, i, "--tls-cert")
            if (vOpt.isNone()) {
                return 2
            }
            tlsCert = vOpt.getOrThrow()
            i = i + 2
        } else if (flag == "--tls-key") {
            let vOpt = flagValueAt(args, i, "--tls-key")
            if (vOpt.isNone()) {
                return 2
            }
            tlsKey = vOpt.getOrThrow()
            i = i + 2
        } else if (flag == "--tls-files") {
            /*
             * ★ 从**文件**读证书/私钥路径，而不是从命令行：仓颉运行时无法接受含非 ASCII 的 argv（main 之前就抛 Invalid unicode scalar value），部署目录含中文时 `--tls-cert` 必然失败。
             * 参数文件本身用 ASCII 路径，内容（可含中文）按 UTF-8 读，每行 `key=value`、`#` 开头为注释、路径可加引号（cert=... / key=...）。
             */
            let cfgPathOpt = flagValueAt(args, i, "--tls-files")
            if (cfgPathOpt.isNone()) {
                return 2
            }
            let cfgPath = cfgPathOpt.getOrThrow()
            tlsFilesGiven = true          // ★ 记下"用户确实要求 TLS"，供后面严格校验用
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
            /*
             * ★★ 严格校验：给了 `--tls-files` 就必须真的解析出 cert 与 key。否则 `wantTls` 为 false ⇒ **静默按明文 HTTP 启动**（文件为空、只有注释、键名大小写不符如 `Cert=`、值留空都会走到这里）。
             * 这恰好违反本文件承诺的"绝不静默降级"：承诺与实现脱节比没有承诺更危险 —— 运维会相信那个承诺。
             */
            if (tlsCert.size == 0) {
                println("❌ --tls-files 里没有解析到 cert=（文件：${cfgPath}）")
                println("   期望每行形如 `cert=<证书路径>`；当前文件内容为：")
                for (line in text.split("\n")) {
                    println("     | ${line}")
                }
                println("   **拒绝启动**：不静默降级为明文 HTTP。")
                return 2
            }
            if (tlsKey.size == 0) {
                println("❌ --tls-files 里没有解析到 key=（文件：${cfgPath}）")
                println("   期望每行形如 `key=<私钥路径>`。")
                println("   **拒绝启动**：不静默降级为明文 HTTP。")
                return 2
            }
            i = i + 2
        } else if (flag == "--dev-auth") {
            devAuth = true
            i = i + 1
        } else if (flag == "--prod") {
            prod = true
            i = i + 1
        } else {
            println("未知参数：${flag}")
            return 2
        }
    }

    /*
     * ★ 连库**之前**先跑口令/令牌原语自检：PBKDF2 若是错的，连上库也只是在用错的哈希签发令牌，错误会在很久以后以"某天所有口令都对不上"的形式爆出来。
     * 用三个公开测试向量（RFC 7914 §11 两条 + 100k 对拍 .NET 一条）当场钉死。
     */
    if (authSelfTest() != 0) {
        println("❌ 口令/令牌原语自检失败，拒绝启动（连库也没有意义）")
        return 3
    }
    println("")

    /*
     * ★★ **先做组合校验，再连库**：`DevAuthGate(devAuth, prod)` 的互斥校验原来在 `ensureSchema` + `migrateSchema` 之后，于是 `serve <dsn> --prod --dev-auth` 会先对目标库真实建表迁移、然后才拒绝启动。
     * 口径：**参数层面的拒绝，一行 DDL 都不许跑**。DDL 是副作用，副作用不能用来做校验。
     */
    var gate: DevAuthGate
    try {
        gate = DevAuthGate(devAuth, prod)
    } catch (e: Exception) {
        println("❌ ${e.message}")
        return 2
    }

    var db: DbBackend
    var cfg: MySqlConfig
    try {
        cfg = parseDsn(dsn)
        println("连接：${cfg.describe()}")
        db = openDatabase(cfg)
        ensureSchema(db)
        // ★ serve 也必须迁移：否则老库上 appointment.slot_restored 不存在，退号路径会直接报 Unknown column。
        let migrated = migrateSchema(db)
        if (migrated > 0) {
            println("迁移：执行了 ${migrated} 条结构变更（存量库补结构）")
        }
    } catch (e: Exception) {
        println("❌ ${e.message}")
        return 1
    }

    let repo = BookingRepo(db)
    let auth = AuthRepo(db)
    // P2 分诊的**只读**仓储：只读 schedule/doctor/department，不写（见 buildHospitalApp 注释）
    let triage = TriageRepo(db)
    // P2 预问诊会话仓储（直接 SQL；不属号源域，也不进内存 Store —— 见 schema.cj TABLE_PREVISIT）
    let previsit = PrevisitRepo(db)
    // P3 AI 能力中心配置仓储（DB 驱动 + 缓存失效；密钥只存引用，见 ai_settings.cj）
    let aiSettings = AiSettingsRepo(db)
    /* ★ AI 模型配置仓储（管理台「AI 模型配置」页，对话/向量模型分开配）与 `ai_setting`（KV）并存：ai_model 是多条命名配置、按 kind 各选一条默认；
       `attachModels` 让 `options()` 优先读 ai_model 默认行、读不到再回落 KV ⇒ 存量库（只有 KV）不迁移也照常跑。 */
    let aiModels = AiModelRepo(db)
    aiSettings.attachModels(aiModels)
    // P3 第二块：Prompt 模板仓储（复用 aiSettings 的 KV 表与缓存，靠 prompt. 前缀隔离）
    let prompts = PromptRepo(aiSettings)
    /* P4：电子病历 + 接诊队列 + 运营看板。⚠ `medical_record` 不属内存 Store，由 `MedicalRecordRepo` 直接 SQL 独占写入。 */
    let emr = MedicalRecordRepo(db)
    let visit = VisitRepo(db)
    let dash = DashboardRepo(db)
    let triageStat = TriageStatRepo(db)
    /* ★ 基础数据域（科室/医生）仓储：这几张表从"人工 SQL 维护"变成"有管理端 CRUD"，补上"分诊推荐科室"缺的最后一环（`triage.cj` 按科室名查 `department`）。 */
    let dept = DepartmentRepo(db)
    let doc = DoctorRepo(db)
    // P5 知识库仓储（文档 CRUD + 切块 + 检索）
    let kb = KbRepo(db)
    /* ★ 公告域仓储（患者端首页「医疗公告」的数据源）：此前没有公告表也没有接口，患者端只能显示写死的假公告。 */
    let notices = NoticeRepo(db)
    /*
     * 播种"默认对话模型 / 默认向量模型"：**只在 `ai_model` 一行都没有时**执行（幂等；存量库若旧 KV 已有 endpoint+model，只补一条对话模型并继承旧值）。
     * ⚠ 只在 `serve` 路径播种：`accept` / `selftest` 自己构造仓储与夹具，在这个真实启动路径之外偷写业务表会破坏"空表"这类测试前提。
     */
    let seeded = aiModelSeedDefaults(aiModels, aiSettings, hNowEpoch())
    if (seeded > 0) {
        println("AI 模型配置：播种 ${seeded} 条默认配置（管理台「AI 模型配置」页可改）")
    }
    /* ★★ **启动时就把 AI 的真实状态打出来**：没配好时原来一个字都不说，分诊默默走规则兜底、管理台还显示"已设置"。
       输出"能不能调用 + 为什么不能"（可用 ⇒ 模型名 + 脱敏 endpoint + 引用类型；不可用 ⇒ `disabledReason`）；只打印、不改行为，密钥本体与引用名都不打。 */
    try {
        let aiOpt = aiSettings.options(hNowEpoch())
        if (aiOpt.enabled) {
            var refKind = "未配置"
            if (keyRefEnvName(aiOpt.keyRef).isSome()) {
                refKind = "env"
            } else if (keyRefFilePath(aiOpt.keyRef).isSome()) {
                refKind = "file"
            } else if (keyRefBuiltinName(aiOpt.keyRef).isSome()) { refKind = "builtin" }
            eprintln("AI：**已启用** — 模型「${aiOpt.modelName}」，endpoint ${aiSafeHost(aiOpt.endpoint)}，密钥引用 ${refKind}")
            /*
             * ★ "已启用"不等于"能调用"：`aiRuntimeValidate` 只校验 key_ref 的**形状**（`env:` / `file:` 前缀），不校验此刻能否解析 —— `env:NO_SUCH_VAR` 这种拼错的变量名会让总开关显示已启用、而每次调用都失败。
             * ⇒ 这里再解析一次，解析不到就明确告警。只打印，不改变行为；refKind 是类型词，不含变量名与路径。
             */
            if (aiOpt.keyRef.size > 0 && aiResolveKey(aiOpt.keyRef).isNone()) {
                eprintln("    ⚠ 但**密钥引用解析不到**（${refKind}）：调用会失败并回落规则兜底；请检查该环境变量/文件是否存在")
            }
        } else {
            eprintln("AI：**未启用**（分诊将只走规则兜底，患者仍能拿到结论）")
            eprintln("    原因：${aiOpt.disabledReason}")
            eprintln("    启用：管理台「AI 配置」设 ai.enabled=1 + ai.key_ref（env:变量名 或 file:路径），或见 docs/dev/FRONTEND-INTEGRATION.md")
        }
    } catch (e: Exception) {
        eprintln("[WARN] 检查 AI 状态失败（不影响启动）：${e.message}")
    }
    /* 管理台静态目录：按**相对进程工作目录**的候选依次找；⚠ 找不到时**不挂载**并明确告警，而不是挂上去再每个请求 404 —— 后者看起来像"后台坏了"。 */
    let adminWebDir = pickAdminWebDir()
    /* ★ `--prod` 下找不到管理台目录 = **拒绝启动**："目录没同步过去"属部署错误，带着警告继续跑会把"后台打不开"拖成几周后才发现。开发态仍只告警。 */
    if (adminWebDir.size == 0 && prod) {
        println("❌ --prod 下没找到管理台静态目录，拒绝启动（管理台属于该部署形态的一部分）。")
        printAdminWebMissingHint()
        return 1
    }
    /* ★ 把库探针交给 `/health`。⚠ 闭包**不能**直接捕获 `var db`（仓颉报 lambda capturing mutable variables needs to be called directly），
       先落一个 `let` 别名再捕获；`db` 本身仍是 `var`（`openDatabase` 会抛，赋值必须在 try 里）。 */
    let dbProbeRef: DbBackend = db
    let app = buildHospitalApp(repo, auth, gate, triage, previsit, aiSettings, aiModels, prompts,
                               emr, visit, dash, triageStat, dept, doc, kb, notices,
                               adminWebDir: adminWebDir,
                               dbProbe: { => dbProbeRef.probe() })
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
        println("    仅限本机联调（服务端只认回环来源 127.0.0.1 / ::1 的这类头）；")
        println("    生产必须走令牌（--prod 会拒绝启动）。")
    } else {
        println("  （未开 --dev-auth：业务接口会返回 401，仅 /health 可用）")
    }
    if (adminWebDir.size > 0) {
        println("  管理台：http://${bindAddr}:${port}/admin/   （静态页面 + 同源 /api/v1）")
    } else {
        printAdminWebMissingHint()
    }
    println("")
    println("接口：")
    println("  GET  /health                              探活（无需认证）")
    println("  GET  /api/v1/health                       探活（同上，api 前缀别名）")
    println("  POST /api/v1/auth/login                   登录换令牌（无需认证）")
    println("  POST /api/v1/auth/logout                  登出（吊销当前令牌）")
    println("  GET  /api/v1/auth/me                      当前身份（含 display_name）")
    println("  GET  /api/v1/schedules/:id                查排班（三端可读）")
    println("  POST /api/v1/appointments                 挂号（仅患者）")
    println("  POST /api/v1/appointments/:id/cancel      退号（患者退自己的 / 管理员退任意）")
    println("  POST /api/v1/admin/schedules              建排班（仅管理员）")
    println("  POST /api/v1/admin/users                  建账号（仅管理员）")
    println("  GET  /api/v1/departments                  科室目录（三端可读，患者端取科室名）")
    println("  GET  /api/v1/doctors                      医生目录（三端可读，带 department_name）")
    println("  GET  /api/v1/notices                      公告（三端可读）")
    println("  GET  /api/v1/admin/notices                公告管理（仅管理员）")
    println("")
    println("鉴权：Authorization: Bearer <token>（令牌 30 天，滑动续期）")

    /*
     * ★ TLS 分支两条纪律：① 轻舟 `serveTls(port, certPem, keyPem)` 收的是 **PEM 字符串**而不是路径，读文件与异常处理都在调用方；② **绝不静默降级**，任何一步失败都 return，不回退明文。
     * 只给 cert 或只给 key 也直接拒绝（多半是命令行打漏了）；`tlsFilesGiven` 参与判定 —— 用户表达了要 TLS 而最终没凑齐 cert+key 时**一律拒绝启动**，不能只看解析出的字符串是否非空（那正是静默降级的入口）。
     */
    let wantTls = tlsCert.size > 0 || tlsKey.size > 0 || tlsFilesGiven
    if (wantTls && (tlsCert.size == 0 || tlsKey.size == 0)) {
        println("❌ 要求了 TLS，但没有凑齐证书与私钥（cert='${tlsCert}' key='${tlsKey}'）。")
        println("   请两个都给：--tls-cert <pem> --tls-key <pem>，或用 --tls-files <env>。")
        println("   **拒绝启动**：不静默降级为明文 HTTP。")
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
 * create-admin：创建/重置管理员账号并打印口令。`POST /api/v1/admin/users` 建号需要管理员身份，而第一个管理员还不存在 —— 所以引导入口必须**不经 HTTP**：只能在本机命令行、有数据库口令的人才能跑。
 * ⚠ 安全姿态：口令本机随机生成、**只打印到控制台一次**、不写日志文件；账号已存在则改口令并吊销其全部令牌；这是"有 DB 写权限即可拿到管理员"的路径，与直接改库等价，不引入新的信任假设。
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
    /* ★ 多给的参数**不许静默忽略**，登录名必须是个名字：原来只读 `args[1]`，于是 `--force` 会变成登录名、`--prod` 被静默吞掉。 */
    if (args.size > 2) {
        println("❌ 参数过多：create-admin 只接受 <dsn> [登录名]，多的参数是 '${args[2]}'。")
        println("   （这里没有别的开关；如果你以为有，它其实一直没生效。）")
        return 2
    }
    if (loginName.startsWith("--")) {
        println("❌ 登录名不能以 `--` 开头：'${loginName}' 看起来是一个参数，而不是名字。")
        println("   要建默认管理员就别传第二个参数（默认登录名 admin）。")
        return 2
    }
    if (loginName.trimAscii().size == 0) {
        println("❌ 登录名不能为空（空名账号建出来也登不进来）。")
        return 2
    }
    var db: DbBackend
    var cfg: MySqlConfig
    try {
        cfg = parseDsn(dsn)
        db = openDatabase(cfg)
        ensureSchema(db)
        let _ = migrateSchema(db)
    } catch (e: Exception) {
        println("❌ ${e.message}")
        return 1
    }
    let auth = AuthRepo(db)
    /*
     * ★★ 口令生成 + 建号**整体包在 try/catch 里**：`randCode(12)` 曾不保证成分（约 7.7% 概率生成全字母口令）⇒ 被本项目自己的强口令规则②拒 ⇒ `UserFacingError` 直冒到顶层，用户看到的是堆栈而不是 `❌` 提示。
     * 生成器已改为保证成分，但这里仍要：① 兜住可提示失败 ⇒ `❌` + 退出码 1（CLI 不冒堆栈）；② 加一次**重试** —— 生成器与校验器再不一致时能自愈，而不是让约 1/12 的引导操作直接失败。
     */
    var pw = ""
    var uid: Int64 = 0
    var existed = false
    var attempt: Int64 = 0
    while (attempt < 2) {
        pw = randCode(12)
        try {
            existed = auth.findUser(loginName).isSome()
            uid = auth.createUser(loginName, Role.Admin, 0, "管理员", pw, hNowEpoch())
            if (existed) {
                // 已存在 → 改口令（setPassword 会顺带吊销其全部令牌）
                auth.setPassword(uid, pw, hNowEpoch())
            }
            attempt = 2      // 成功，跳出循环
        } catch (e: Exception) {
            attempt = attempt + 1
            if (attempt >= 2) {
                // 重试也用完了 → 明确报错，不冒堆栈
                println("❌ 创建管理员失败：${e.message}")
                println("  处置：① 确认库可写、账号未被锁定；")
                println("        ② 这是引导入口，失败**不影响**已有账号；")
                println("        ③ 若反复失败请把上面这行信息报给开发（**不要贴口令**）。")
                db.close()
                return 1
            }
            println("⚠ 生成的口令未通过强度校验，正在重试一次…")
        }
    }
    println("")
    println("管理员账号：")
    println("  登录名：${loginName}")
    /*
     * ★ 口令走 **stderr** 并明确禁止重定向：原先三行全走 stdout，而运维标准写法是 `... > deploy.log 2>&1` ⇒ "只显示这一次"当场失效（口令进了日志文件、CI 输出、终端 scrollback）。
     * 走 stderr 后 `> log` 只收 stdout、口令不会被顺手写进日志；要落盘必须显式 `2>` —— 那是一个"确实要这么做"的动作。
     */
    eprintln("  口  令：${pw}")
    println("  user_id：${uid}   （${if (existed) { "已存在 → 已重置口令并吊销旧令牌" } else { "新建" }}）")
    println("")
    println("⚠ 口令只显示这一次（未落盘）；请立即用 POST /api/v1/auth/login 换令牌。")
    println("⚠ 口令写在 **stderr** 上：不要用 `2>&1` 重定向本命令的输出到文件/工单/聊天记录。")
    db.close()
    return 0
}

/*
 * create-db：幂等建库（CREATE DATABASE IF NOT EXISTS <db> CHARACTER SET utf8mb4）。`accept` 只允许对显式测试库跑，而测试库得先存在；业务账号建连就带库名，库不存在直接连不上。
 * 提供显式入口而不是让服务每次启动都尝试建库（建库通常要更高权限，不该由服务进程长期持有）。⚠ 账号**必须有建库权限**，没权限时明确报错并给出手工 `CREATE DATABASE` 命令。
 */
func createDb(args: Array<String>): Int64 {
    let dsn = args[0]
    /* 解析 `--admin-dsn`：照 serve 的口径**严格解析、未知参数直接拒** —— 宽松处理会让拼错时静默失效，而使用者以为已经授好权了。 */
    var adminDsn = ""
    var ai = 1
    while (ai < args.size) {
        if (args[ai] == "--admin-dsn") {
            // ★ `--admin-dsn` 是**取值型**参数，缺值时报"未知参数：--admin-dsn"是误导（参数明明认识），使用者会去猜名字写错了，而不是"忘了给值"。
            if (ai + 1 >= args.size) {
                println("❌ --admin-dsn 缺少取值（它需要一个带 GRANT OPTION 的账号 DSN）")
                println("用法：hospital-server.exe create-db <dsn> [--admin-dsn <管理员 DSN>]")
                return 2
            }
            if (args[ai + 1].startsWith("--")) {
                println("❌ --admin-dsn 缺少取值：下一项 '${args[ai + 1]}' 看起来是另一个参数。")
                println("   想写的是 `--admin-dsn mysql://root:***@127.0.0.1:3317/mysql` 这种。")
                return 2
            }
            adminDsn = args[ai + 1]
            ai = ai + 2
        } else {
            println("未知参数：${args[ai]}")
            println("用法：hospital-server.exe create-db <dsn> [--admin-dsn <管理员 DSN>]")
            return 2
        }
    }
    var cfg: MySqlConfig
    try {
        cfg = parseDsn(dsn)
    } catch (e: Exception) {
        println("❌ ${e.message}")
        return 1
    }
    if (cfg.db.size == 0) {
        println("❌ DSN 里没有库名")
        return 2
    }
    try {
        ensureDatabase(cfg)
    } catch (e: Exception) {
        println("❌ ${e.message}")
        return 1
    }
    /*
     * ★★ 建完库还要**让库对当前账号真的可用**：权限按库逐个授，`hospital` 账号只有 `CREATE ON *.*` + 两个库的 ALL ⇒ 能建第三个库、却对新库没有任何权限，紧接着 `check-db` 的 `migrateSchema` 会在 ALTER 上被拒。
     * 现在：建库 → 探测（真做一次 DDL）→ 不可用则尝试自助授权 → 还不行就明确报"已建好但用不了" + 给 root 命令并返回失败。纪律：**不许把"不可用"报成"就绪"**。
     */
    var usable: Int64 = 0
    if (adminDsn.size > 0) {
        /* 给了管理员 DSN ⇒ 建库 + 授权 + 探通，一步到位 */
        usable = ensureDatabaseUsableWithAdmin(cfg, adminDsn)
    } else {
        usable = ensureDatabaseUsable(cfg)
    }
    if (usable != 0) {
        return usable
    }
    println("✅ 库已就绪且可用：${cfg.db}（CHARACTER SET utf8mb4，账号 ${cfg.user} 可 DDL）")
    return 0
}


main(args: Array<String>): Int64 {
    // args[0] 即第一个参数（不含 exe 路径）
    /*
     * ★ 退出码要能被 CI 当判据用：无参数 ⇒ usage + `return 2`（无参是用法错误，原为 0，脚本里的 `$LASTEXITCODE` 判据会把"忘了传子命令"读成成功）；`--help` / `-h` ⇒ usage + `return 0`（主动要帮助不是错误）。
     */
    if (args.size < 1) {
        usage()
        return 2
    }
    let cmd = args[0]
    if (cmd == "--help" || cmd == "-h" || cmd == "help") {
        usage()
        return 0
    }
    // 注：这里用 if 链而非 match —— 仓颉的 match 分支体是**单表达式**，而这些分支需要多语句。
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
    if (cmd == "triagetest") {
        // P2 分诊纯逻辑自检（不碰库 / 不调模型）
        return runTriageTests()
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
    if (cmd == "create-db") {
        if (args.size < 2) {
            println("用法：hospital-server.exe create-db <dsn> [--admin-dsn <管理员 DSN>]")
            println("")
            println("  <dsn>         目标库（业务账号，例如 hospital）—— 必须带库名")
            println("  --admin-dsn   可选。给一个有 GRANT OPTION 的账号，本命令会**一步授好**")
            println("                （不给的话：新库对业务账号没有权限，check-db/accept/serve 会失败）")
            return 2
        }
        return createDb(args[1..])
    }
    println("未知子命令：${cmd}")
    println("")
    usage()
    return 2
}
