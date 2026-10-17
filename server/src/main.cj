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
 *   （不含 exe 路径）—— 见 轻舟 main.cj:15-17。
 *
 * ⚠ P0 尚未接路由与 HTTP 服务 —— 那属 P1（挂号闭环）。此处**刻意不**先写
 *   一个空壳 listen，避免"看起来能跑其实没接口"的假象。
 */

package qingzhou

// ⚠ `exists()` / `File.readFrom()` 来自 std.fs —— TLS 分支要读 PEM 文件，
//   不加这个 import 会报 undeclared identifier（搬迁前 main.cj 同样 import 了它）。
import std.fs.*
// ⚠ `HashSet` 来自 std.collection —— serve 的参数解析用它记"哪些 flag 已经出现过"
//   （2026-10-14 修 A2：重复 flag 必须报错，不能静默后者覆盖前者）。
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
     * ⚠ 这里**不写死端口**（2026-10-07 修，第九份复查发现原写的是 3307）。
     *   usage 是使用者**第一眼**看到的东西，写一个本项目不用的端口
     *   （3307 是**本机另一台实例**，本项目自管 devdb 是 3317）会直接把人引到错地方 ——
     *   复查的人和我都真的被引过。
     *   ⇒ 给**形状**示例，端口与口令等部署事实一律指向 `docs/DEV-DB.md`：
     *     本提示不复制它们，就没有第二次漂移的机会。
     */
    println("  本机联调示例：mysql://hospital:<口令>@127.0.0.1:<端口>/hospital")
    println("  ⚠ 端口与口令**以 docs/DEV-DB.md 为准**（那是唯一事实来源；本提示刻意不写死，免得漂移）")
    println("")
    println("⚠ --dev-auth 是**开发态**身份头（X-Role/X-Patient-Id），绕过全部认证；")
    println("  与 --prod 同时传会直接拒绝启动。")
    println("  ⚠ 且**只接受来自本机回环地址（127.0.0.1 / ::1）的请求**：")
    println("     仍建议保持默认 --bind 127.0.0.1；绑 0.0.0.0 时远程请求会拿到 401。")
    println("  ⚠ 本工具链仓颉 std 无 getEnv，故生产开关走 --prod 而**不是**环境变量。")
}

/*
 * check-db：连库 + 幂等建表 + 打印表清单。
 * 返回失败项数（0 = 成功）。
 */
func checkDb(dsn: String): Int64 {
    var db: DbBackend
    /*
     * ⚠ `cfg` 必须声明在 try **外面** —— 下面的 catch 要用它拼处置命令里的库名，
     *   而仓颉**没有变量提升**：try 块里声明的 `let cfg` 在 catch 里不可见。
     *   （这是本项目踩坑表里的 B 条，此处又遇到一次。）
     */
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
     * ★★ 建表 + 迁移必须**包在 try/catch 里**（第八份复查第 2 条）。
     *
     * 原来这两行在 try 之外 ⇒ 权限不足时抛**未捕获异常 + 完整堆栈**：
     *     An exception has occurred:
     *     SqlException: ALTER command denied to user ... 
     *        at mariadb.cdbc::ConnectionImpl::sendUpdate ...
     *        at qingzhou::checkDb(main.cj:73)
     * 这违反本仓自己立的规矩「**失败必须被说出来，不能靠崩溃表达**」——
     * 而且堆栈里全是驱动内部帧，对使用者**毫无用处**（真正的原因在最后一行）。
     *
     * ⚠ 对照：同一个 `migrateSchema` 在 `accept` / `serve` / `create-admin`
     *   三处**早就都包好了**（main.cj 各自的 try）。只有 `check-db` 漏了 ——
     *   所以这是**同一类疏漏的最后一份**，不是新问题。
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
        /*
         * 这个报错**极可能**是权限不够（而不是 SQL 写错）—— 因为"库是新造的、
         * 但账号只有全局 CREATE"是本项目已知的配置形态（见 ensureDatabaseUsable）。
         * 所以直接给出最可能的处置，而不是让人去猜堆栈。
         */
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
 * accept：跑验收测试。
 *
 * ⚠ 会**清空业务表**（appointment / schedule / doctor / department / patient），
 *   所以只允许对**显式标记为测试用**的库名跑。
 *
 * ★ 2026-10-07 修（第三方复查发现的守卫漏洞）：
 *   原判据是 `!db.contains("test") && db != "hospital"` —— 把 **`hospital`（唯一的
 *   生产库名）放进了白名单**。也就是说：守卫挡住了 `hospital_x`（退出 2），
 *   却**恰好对那个真会丢数据的库名放行**，而 `accept` 一跑就 DELETE 六张表。
 *   这不是"宽松"，是**反着的**：最该拦的那一个被放过了。
 *
 * 现在只认 `*_test` / `test_*` / `*_test_*` 这类**显式测试库**，
 * 并要求库名里带 `test`；`hospital` 本身**不再例外**。
 * 要跑验收请用专用测试库（如 `hospital_test`）——
 * `tests\*` 里的脚本本来就是这么造的。
 */
func isTestDatabase(dbName: String): Bool {
    return dbName.contains("test")
}

/*
 * 取"某个取值型参数"的值，缺值就报错（2026-10-14 修 A2）。
 *
 * 判据是**两条**，缺一不可：
 *   ① 后面真的还有一个 token（`i + 1 < args.size`）；
 *   ② 那个 token **不以 `--` 开头** —— 否则 `--bind --prod` 会把 `--prod`
 *      当成绑定地址吞掉，而这正是"击穿 --prod/--dev-auth 互斥"的走法。
 */
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

/*
 * `path` 存在**且是目录**（2026-10-14 修 D6）。
 *
 * 为什么不能用 `exists(path)`：它判的是"任意文件系统条目"。CWD 下若有一个**同名文件**
 * `admin-web`，`exists` 为真 ⇒ 启动日志说"已挂载管理台"，而每个 `/admin/...` 都 404
 * —— "目录不对"被伪装成"后台坏了"。
 */
func isDirectoryPath(path: String): Bool {
    try {
        let fi = FileInfo(path)
        return fi.isDirectory()
    } catch (e: Exception) {
        return false
    }
}

/*
 * 找管理台静态目录（2026-10-14）。
 *
 * 候选都是**相对进程工作目录**，覆盖三种真实启动方式：
 *   ① `admin-web`        —— 在 `server/` 下跑（文档里的命令都是这样写的）
 *   ② `server/admin-web` —— 在仓库根跑
 *   ③ `../admin-web`     —— 在 `server/build/` 下直接跑那个 exe
 *
 * 返回空串 = 没找到（调用方会告警且**不挂载**，见 serve 路径的注释）。
 *
 * ⚠ 判据是"**目录**存在"（`isDirectoryPath`），不是"任意同名条目存在"。
 *   失败时会把"找过哪些候选、解析成什么绝对路径"一起打出来 —— 否则
 *   "找不到"和"路径拼错了"在日志上一模一样。
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

/*
 * 找不到管理台目录时的告警（2026-10-14 修 D6）。
 *
 * 为什么单列一个函数：这段文案要包含"试过哪些候选 + 解析后的绝对路径"，
 * 而 CWD 是排障的第一现场 —— 打印 CWD 比让人猜"你在哪个目录启动的"快得多。
 */
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
    /*
     * ⚠ 插值里**不能**再写转义引号（`${canonicalize(\".\")}` 会报
     *   `unterminated string interpolation`）—— 先在语句外把值算好再插进来。
     */
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

    /*
     * 1) 表集分类断言。
     *
     * ⚠ 用**分项**断言而不是硬编码总数 —— 硬编码数字在加表时必然要手改，
     *   而漏改就变成"测试说没事、其实漂移了"。
     *   本断言已**四次**证明它有用：加鉴权表一次、删 `booking_idem` 一次、
     *   加 `auth_login_attempt` 一次、**加 `previsit_session`（P2）一次**。
     *
     * ★ 2026-10-07 重构（加 `previsit_session` 时暴露的问题）：
     *   原来是"业务表 6 + 鉴权表 3 = 9"，而 `previsit_session` **既不是**内存 Store
     *   负责的配套域表、**也不是**鉴权表 —— 它是 P2 新增的**第三种**：
     *   直接 SQL、但**不属号源域**（由 `PrevisitRepo` 独占，见 schema.cj 的 TABLE_PREVISIT）。
     *   ⇒ 硬把它塞进"业务表"会让那个数字失去含义（"业务表"到底指什么？）。
     *   所以改成**四个人口都有的分项**：
     *     ① 号源/挂号域（直接 SQL，ADR-0001 §4.3 锁死的那两张）
     *     ② 配套域（走内存 Store）
     *     ③ 鉴权域
     *     ④ **预问诊域**（直接 SQL、非号源域；P2 新增的第三类）
     *   并把"四类互不重叠、且并集 == ALL_TABLES"也断言上 ——
     *   这样"加表时忘了归类"会立刻变红，而不是悄悄混进某个数字里。
     */
    /*
     * ⚠ 这几个数**必须与来源一致**，能派生的就派生。
     *   📌 历史（两次都值得记）：
     *     · `memTables` 曾硬编码 4；P4 把 `medical_record` 移出后实际是 3，
     *       那条断言立刻变红（**好事**：把"数字与事实脱节"暴露了）。
     *     · ADR-0001 **rev.7 整体拆除内存 Store** ⇒ "配套域（走内存 Store）"这个
     *       分类**不存在了**。但 ⚠⚠ **消失的是"范式"，不是"表"**：
     *       department / doctor / patient 这三张表**还在库里、还在 `ALL_TABLES` 里、
     *       还被人读**（看板的规模统计、分诊的科室名查询）。它们只是不再经内存 Store。
     *       ⇒ 所以下面**不是**把那一项删掉（我第一版就是那么干的，结果 = 9 与
     *         `ALL_TABLES.size`(12) 对不上 —— **而那条断言恰好把它抓住了**），
     *         而是给它一个**新的归属**：`baseTables`（基础数据域）。
     *   📌 教训：**删一个概念时，先问"挂在它下面的实体去哪"**。
     *     把实体一起删掉 = 数据丢失；连分类一起删掉 = 断言数不上账。
     *     正确做法是**重新归类并写明新纪律**。
     */
    let bookingTables = BOOKING_DOMAIN_TABLES.size
    /*
     * ★ 基础数据域（rev.7 新分类，**取代**原来的"配套域（走内存 Store）"）：
     *   department / doctor / patient —— 直接 SQL 读；**目前没有写入端点**，
     *   靠人工 SQL 维护（见 README 表集说明与 P4-HANDOFF 未做清单）。
     *   ⚠ 这条纪律要写明，否则读者会以为"系统会自动积累科室/医生数据"。
     */
    let baseTables = 3
    let authTables = 3
    let previsitTables = 1
    let aiTables = 1        // ai_setting（P3 AI 能力中心；直接 SQL、非号源域、非医疗数据）
    /*
     * ★ P4 新增两张表，各成一类（**不塞进现有类**：它们的纪律不同）：
     *   · medical_record —— 临床数据，直接 SQL（`MedicalRecordRepo` 独占；rev.6 起不属内存 Store）
     *   · triage_stat —— 分诊统计，**只存计数**、不含任何患者标识，且有 TTL 清理
     *     ⇒ 与"医疗数据"（要长期留）纪律不同，单列一类。
     * 📌 为什么每次都真的加一类、而不是"归到最接近的那类"：
     *   分类的意义就是**让纪律可见**。硬塞进别类 = 那条纪律从此没人看得到。
     */
    /*
     * ★ 2026-10-15（改进 3）：病历域由 1 张变 **2 张** —— 新增 `medical_record_revision`。
     *   为什么**合进这类而不是像 P4 那样再开一类**：
     *     主类依据是"**留存纪律**是否相同"（见上面 kbTables 的注释）。
     *     修订历史与病历同为**临床数据**：长期留、不设 TTL、由 `MedicalRecordRepo` 独占写。
     *     它不属"统计数据"（triage_stat 那种只存计数、带 TTL），也不属知识库/公告。
     *   ⚠ 唯一的差别是"病历主体可改（锁定/解锁），修订行不可变" ——
     *     但那是**同一份文书内部**的关系，不是两种数据纪律。
     *   📌 这条分类是**第五次**因为加表而改动（前四次见上面注释），
     *     而"改这里"正是断言存在的目的：漏改就立刻红。
     */
    let emrTables = 2       // medical_record / medical_record_revision（临床数据，直接 SQL，MedicalRecordRepo 独占）
    let statTables = 1      // triage_stat（聚合统计，只存计数，带 TTL）
    /*
     * ★ P5 新增两张表，**合成一类**（知识库域）：
     *   · kb_doc   —— 文档（人维护的单位）
     *   · kb_chunk —— 切块（检索的单位，含 embedding JSON 或 NULL）
     * ⚠ 合成一类（而不是像 P4 那样各成一类）的理由：这两张表**纪律相同**
     *   （本院人员维护的运营资料、不含患者个人信息、走直接 SQL）。
     *   而 P4 的 `medical_record` / `triage_stat` 各成一类，是因为它们的
     *   **留存纪律不同**（临床长期留 vs 统计带 TTL）。
     * 📌 分类按**纪律是否相同**分，不按"是不是同一批加的"分。
     */
    let kbTables = 2        // kb_doc / kb_chunk（知识库，P5）
    /*
     * ★ 公告域（2026-10-12 契约补齐）。
     *   `notice` —— 院内公告/健康提示，**给人看**的展示内容：
     *     不进检索、不出站、不含患者个人信息、带 `published_at`（可预排期）。
     *   ⚠ 为什么不并进 `kbTables`：知识库会被**检索并随 Prompt 出站**，
     *     公告不会。纪律不同就单列一类 —— 这条分类的意义正是"让纪律可见"。
     *     （已在 `TABLE_NOTICE` 上方写明这两者的边界。）
     */
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
    /*
     * ★★ 病历表：`medical_record` 由 `MedicalRecordRepo` **直接 SQL** 独占写入。
     *
     * 历史（两次变迁，都留档）：
     *   · rev.6（P4）：把它**移出内存 Store** —— 因为内存 Store 在生产路径上
     *     **从未刷盘**（`flushToMysql()` 只有测试调过）⇒ 写病历 = 只写内存 + 永不落库。
     *   · rev.7（本次）：内存 Store **整体拆除** ⇒ "病历不属内存 Store"这件事
     *     从"一条需要断言的例外"变成了"**没有别的选项**"。
     *     ⇒ 只保留"表名口径一致"这条**仍有意义**的断言（它是仓储的锚点）。
     */
    check("★★ 病历表名口径一致（MedicalRecordRepo 的锚点）",
          TABLE_MEDICAL_RECORD == "medical_record")
    check("★ 分诊统计表**不**属号源域（它不是可扣号路径）",
          !BOOKING_DOMAIN_TABLES.contains(TABLE_TRIAGE_STAT))
    /*
     * ⚠ 写成"3 张表各判一次"而不是跨行 `&&` 串联 ——
     *   实测跨行时 cjc 报 `warning: possibly confusing line terminator`
     *   （仓颉把行尾当作语句终结符的候选，续行不明确）。分次 check 更清楚，也消掉警告。
     */
    check("鉴权表恰好 ${authTables} 张（auth_user / auth_token / auth_login_attempt）",
          isAuthTable(TABLE_AUTH_USER) && isAuthTable(TABLE_AUTH_TOKEN) && isAuthTable(TABLE_AUTH_ATTEMPT))
    check("业务表不误入鉴权域", !isAuthTable(TABLE_PATIENT) && !isAuthTable(TABLE_SCHEDULE))

    // 2) 每张**业务表**都有对应 DDL。
    //    ⚠ 不能断言 `SCHEMA_DDL.size == ALL_TABLES.size` —— DDL 数组里还可以有
    //      不带业务模型的表（如将来的 meta / schema_version），那样断言会误报。
    //       所以按"表名能否在 DDL 里找到"来判，这才是真正要防的漂移。
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

    /*
     * 3) ★ DDL 里不得出现任何以 `idem` 命名的表（**长期纪律**，不是"改名只改一半"的临时检查）。
     *
     * 背景：本侧曾有一张 `booking_idem`（挂号幂等登记表），2026-10-07 连同实现删除
     * （死代码，见 ADR-0001 §7 第 7 条）。这条断言现在的作用变成**防止它被复活** ——
     * 删死代码之后最怕的就是下一个人又加回一张同义表。
     *
     * 同时它仍然守着原来的撞名风险：搬迁前的内存 Store 占用了 `idem` 表名
     * （`搬迁前 mysql_store.cj:892`），P1 引入整库刷盘后同名表会争同一张表。
     */
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
     * 5a-2) ★★ "出错提示里的端口"必须是**配置驱动的**，不许写死
     *        （2026-10-07 修，第九份复查发现的一处真实漂移）。
     *
     * ── 原缺陷 ────────────────────────────────────────────────────────────
     *   连接失败时的处置提示里写死「本机联调的便携版 MariaDB 是 127.0.0.1:**3307**」，
     *   而本项目自管 devdb 早已迁到 **3317**（3307 是**本机另一台实例**，本项目不再依赖它）。
     *   ⇒ 复查的人、以及我自己在本项目里**都被它误导过**：devdb 没起来时，
     *     提示让人去查 3307，而正确处置是启动 3317。
     *   📌 根因是"**同一件事两处口径**"：端口的事实来源是 `cfg`，提示里又手写一份。
     *     而且**偏偏这是最需要准确的地方**（出错时的提示）。
     *
     * ── 为什么这里只断言"默认端口"，不在这里读源码断言文案 ────────────────
     *   我原打算在 selftest 里读 `db_bootstrap.cj` 的**源文件文本**、
     *   断言其中不含 `:3307/`。
     *   ❌ 那是错的：selftest 跑在 `build\` 目录下，读源码**依赖工作目录**
     *      （换个目录跑就变成"文件不存在"，而那不是被测对象的问题）；
     *      而且**验收的权威是 `build/SOURCE-MANIFEST.sha256` + 测试结果**，
     *      不是"运行时去读源码"—— 那会让断言与它要守的东西耦合在错误的层上。
     *   ✅ 所以拆成两半，各自放在**能看见它的那一层**：
     *      · selftest（这里）：断言**默认端口 = 3306** —— 这是编译期事实，
     *        且正是"假默认"那个缺陷的核心（原为 3307，本项目没有任何实例在那）；
     *      · `check-db` 的**输出**：打印默认配置，人/脚本一眼能核对；
     *      · `create-db-check.ps1` / `emr-check.ps1`：端到端断言提示文案里的端口
     *        **就是实际用的那个**（那才是"配置驱动"的直接证据）。
     */
    let dflt = MySqlConfig()
    check("★ 默认 MySQL 端口 = 3306（协议标准口）—— 原值曾是**本机另一台实例的端口**，" +
          "而本项目没有任何实例在那 ⇒ 是个**假默认**，会让「没拿到 DSN」与「端口写错」长得一样",
          dflt.port == 3306)
    check("★ 默认配置可打印（seed-cfg）且与实测口径一致：${dflt.describe()}",
          dflt.describe() == "hospital@127.0.0.1:3306/hospital")

    // 5b) ★ 与搬迁前的内存 Store 的表名**零交集**（P1 整库刷盘不会争表）
    //     搬迁前表名见搬迁前 mysql_store.cj:309-311
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

    /*
     * ---- ★★ DSN 解析：多字节（中文）内容不得被切坏 ----
     *
     * 为什么加这一组（第五份复查的连带要求）：复查指出我在 triage 里
     * **逐点修**字节/字符混用，而不是**按类别扫**。扫全仓时发现
     * `parseDsn` 也在同一个表达式里混用了两者：
     *     `authority[(at + 1)..]`  ← `at` 来自 `lastIndexOf("@")`，是**字节**偏移
     * 我实测确认它**恰好是安全的** —— 因为它搜的分隔符（`/ @ :`）全是**单字节 ASCII**，
     *   而 `x + 1` 又恰好是"跳过那个 1 字节分隔符"，所以整个解析**自洽地待在字节空间**里。
     *   但这属于"**碰巧对**"：它的正确性依赖"分隔符一定是 1 字节"这个隐含前提，
     *   而代码里**没有任何东西**写明或保证这一点。
     *
     * ⇒ 所以把它**钉成断言**：只要多字节输入仍解析正确，这个前提就没被破坏；
     *   哪天有人把某个分隔符改成多字节、或把某处改成字符下标，这里会立刻变红。
     *   （📌 这是"按类别扫"的正确姿势：**不重写没坏的东西，但把它的前提写成测试**。）
     */
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

    /*
     * ---- ★★ 医院时区：Asia/Shanghai（本次联调修的第 6 项）----
     *
     * 病灶：服务端算"今天"用的是 **UTC**，而患者端用本机日期。
     *   在中国（UTC+8）每天 **00:00–08:00** 这 8 小时里两者差一天：
     *   服务端认为"今天"还是昨天 ⇒ 患者早上打开 App，
     *   当天上午的号会被判成"过去"而**排不出来**（挂不了当天的号）。
     *
     * ⚠ 为什么用**固定 epoch** 断言而不是"比较 now()"：
     *   用 now() 只有在"恰好处于那 8 小时窗口内"时才会发现差异，
     *   其余 16 小时它**恒绿**（一个永远为真的测试比没有测试更坏）。
     *   固定 epoch 把那个窗口**钉死**在测试里，任何时刻跑都能证明。
     */
    println("")
    println("=== 医院时区（Asia/Shanghai）===")
    // 1791736200 = 2026-10-11T16:30:00Z = 北京时间 2026-10-12 00:30
    //   ⇒ UTC 还是 10-11，上海已经跨到 10-12：这就是那 8 小时窗口。
    check("★★ 跨零点：UTC 10-11T16:30 在上海应算 2026-10-12", hDateStringOf(1791736200) == "2026-10-12")
    // 1791732600 = 2026-10-11T15:30:00Z = 北京时间 2026-10-11 23:30（未跨零点）
    check("★ 未跨零点：UTC 10-11T15:30 在上海应算 2026-10-11", hDateStringOf(1791732600) == "2026-10-11")
    // 1791763200 = 2026-10-12T00:00:00Z = 北京时间 2026-10-12 08:00（整点边界）
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
 *   要联调再显式 `--bind 0.0.0.0`（照搬迁前的教训，
 *   搬迁前 main.cj:968-977 专门为此写过一段提醒）。
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
    var port: UInt16 = 8091  // ★ 2026-10-17 评审 P2-15：8080→8091，与客户端默认值对齐（理由见 docs/整改方案-2026-10-17.md）
    var bindAddr = "127.0.0.1"
    var devAuth = false
    var prod = false
    var tlsCert = ""
    var tlsKey = ""
    var tlsFilesGiven = false
    /*
     * ★★ 2026-10-14（第三方复查 A2 修）：取值型参数**必须**带走一个值，且 flag 不得重复。
     *
     * 原实现里只有 `--port` 是严格的，`--bind`/`--tls-cert`/`--tls-key`/`--tls-files`
     * 都写成 `... && i + 1 < args.size` 然后**直接吞下一个 token**，于是：
     *   · `serve <dsn> --dev-auth --bind --prod`
     *     → `--prod` 被当成绑定地址，`prod` 保持 false ⇒ `DevAuthGate(true, false)` 放行，
     *       "生产不允许 --dev-auth"这条**唯一安全闸门**输在了参数解析上；
     *   · `--port`（缺值）落到最后的 else，报"未知参数：--port" —— 明明已知，缺的是值。
     *
     * 现在的口径：
     *   ① 取值型 flag 后面**没有 token**、或**下一个 token 以 `--` 开头** ⇒ 报"缺少取值"退 2；
     *   ② 任何 flag **重复出现**⇒ 报重复退 2（原先"最后写的赢"是隐式规则，且
     *      `--tls-cert A --tls-files f.env` 会互相覆盖而毫无提示）。
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
            // ⚠ 严格解析：原先用 `parseUInt16Or(x, 8080)` —— 传个非数字（如 `--port abc`）
            //   会**静默退回 8080** 并照常启动，运维以为换端口了其实没换。
            //   `--port 0` 也是陷阱：parse 成功但 0 不是合法监听端口。
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
             * ★ 从**文件**读 证书/私钥 路径，而不是从命令行。
             *
             * 为什么需要这条：本工具链的仓颉运行时**无法接受含非 ASCII 的 argv** ——
             *   在 main 之前就抛 `IllegalArgumentException: Invalid unicode scalar value`，
             *   连 usage 都打不出来（搬迁前的 API 踩坑记录 坑 6 记过同一件事）。
             *   仓库已改名为 `E:\harmonyOS\smart_hospital`（纯 ASCII），仓内路径现在可以直接用；
             *   但部署目录仍可能含中文（历史根因：旧仓库名「智能医院客户端」），那时 `--tls-cert` 仍必然失败。
             *   （实测：把同一份证书拷到 `C:\Temp\...` 纯 ASCII 路径就能起来。）
             *
             * 这个参数文件本身用 ASCII 路径，内容（可含中文）用 UTF-8 读 —— 绕开 argv 限制。
             * 文件格式（每行 `key=value`，`#` 开头为注释，路径可加引号）：
             *     cert=E:\...\certs\cert.pem
             *     key=E:\...\certs\key.pem
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
             * ★★ 严格校验：给了 --tls-files 就必须真的解析出 cert 与 key。
             *
             * 为什么必须在这里挡（2026-10-07 修，第三方复查发现的**静默降级**）：
             *   原实现解析完就不管了，而后面用的是
             *       `let wantTls = tlsCert.size > 0 || tlsKey.size > 0`
             *   —— 于是只要配置文件**没被解析出有效条目**（文件内容为空、
             *   只有注释、键名大小写不符如 `Cert=`、值留空），
             *   `wantTls` 就是 false ⇒ **静默按明文 HTTP 启动**。
             *   实测：给一个只有注释的 tls.env，服务照样以明文起在 8092 且 /health 返回 200。
             *
             *   这恰好违反本文件自己承诺的"绝不静默降级"，而且正是文档警告过的
             *   "变成一台看起来正常的明文服务" —— **承诺与实现脱节，比没有承诺更危险**
             *   （运维会相信那个承诺）。
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

    /*
     * ★★ 2026-10-14（第三方复查 A3 修）：**先做组合校验，再连库**。
     *
     * 原实现把 `DevAuthGate(devAuth, prod)` 的互斥校验放在 `ensureSchema` +
     * `migrateSchema` **之后**，于是 `serve <dsn> --prod --dev-auth`（误加或残留参数）
     * 会先对目标库真实执行一遍建表与迁移，然后才拒绝启动；若 DSN 也有误，则以
     * "连接失败 exit 1"掩盖真正的拒绝原因。
     *
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
        // ★ serve 也必须迁移：否则老库上 appointment.slot_restored 不存在，
        //   退号路径会直接报 Unknown column（比静默降级"响"，但同样是坏掉）。
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
    /*
     * ★ 2026-10-14：AI 模型配置仓储（管理台「AI 模型配置」页 —— 对话模型/向量模型分开配）。
     *
     * 与 `ai_setting`（KV，8 项全局开关）**并存**而不是替换：
     *   · `ai_setting`  —— 全局总开关、超时、并发、密钥引用等"只有一份"的项；
     *   · `ai_model`    —— **多条命名配置**，按 kind 各选一条默认（本文件新建）。
     * `attachModels` 让 `AiSettingsRepo.options()` **优先**读 ai_model 的默认行、
     * 读不到再**回落**到 KV —— 所以存量库（只有 KV）不迁移也照常跑。
     */
    let aiModels = AiModelRepo(db)
    aiSettings.attachModels(aiModels)
    // P3 第二块：Prompt 模板仓储（复用 aiSettings 的 KV 表与缓存，靠 prompt. 前缀隔离）
    let prompts = PromptRepo(aiSettings)
    /*
     * P4：电子病历 + 接诊队列 + 运营看板。
     * ⚠ `medical_record` 自 P4 起**不属内存 Store**，由 `MedicalRecordRepo`
     *   直接 SQL 独占写入（ADR-0001 rev.6；理由见 domain_emr.cj 文件头）。
     */
    let emr = MedicalRecordRepo(db)
    let visit = VisitRepo(db)
    let dash = DashboardRepo(db)
    let triageStat = TriageStatRepo(db)
    /*
     * ★ 2026-10-09：基础数据域（科室/医生）仓储。
     *   ADR-0001 rev.7 拆掉内存 Store 后，这几张表由"人工 SQL 维护"变成
     *   "有管理端 CRUD" —— 补上的正是"分诊推荐科室"这条链路缺的最后一环
     *   （`triage.cj` 按科室名查 `department`，而此前**没人能往里加数据**）。
     */
    let dept = DepartmentRepo(db)
    let doc = DoctorRepo(db)
    // P5 知识库仓储（文档 CRUD + 切块 + 检索）
    let kb = KbRepo(db)
    /*
     * ★ 2026-10-12：公告域仓储（患者端首页「医疗公告」的数据源）。
     *   在此之前服务端**没有公告表也没有接口**，患者端只能显示写死的假公告
     *   —— 联调实测发现的（见 `domain_notice.cj` 文件头）。
     */
    let notices = NoticeRepo(db)
    /*
     * 播种"默认对话模型 / 默认向量模型"：**只在 `ai_model` 一行都没有时**执行
     * （幂等；存量库若旧 KV 里已有 endpoint+model，只补一条**对话**模型并继承旧值
     *  —— 见 aiModelSeedDefaults 的注释）。
     *
     * ⚠ 只在 `serve` 路径播种：`accept` / `selftest` 自己构造仓储与夹具，
     *   在这个"真实启动"路径之外偷偷写业务表，会破坏"空表"这类测试前提。
     */
    let seeded = aiModelSeedDefaults(aiModels, aiSettings, hNowEpoch())
    if (seeded > 0) {
        println("AI 模型配置：播种 ${seeded} 条默认配置（管理台「AI 模型配置」页可改）")
    }
    /*
     * ★★ 2026-10-17（S13 修）：**启动时就把 AI 的真实状态打出来**。
     *
     * 改之前：AI 没配好（没总开关 / 密钥引用解析不到）时启动日志**一个字都不说**，
     *   分诊默默走规则兜底，界面上看起来一切正常 —— 复查时正是这样：
     *   `ai_setting` 表里连 `ai.enabled` 都没有，`ai.key_ref` 为空，
     *   而管理台显示"已设置"，没人发现 AI 从未被调用过。
     *
     * ⇒ 启动即打印"能不能调用 + 为什么不能"：
     *   · 可用：模型名 + endpoint（脱敏到路径）+ 密钥引用类型；
     *   · 不可用：`disabledReason`（它由 `aiRuntimeValidate` 给出，逐项说明缺什么）。
     *
     * ⚠ 只是**打印**，不改变任何行为；读配置失败也只告警不拦启动
     *   （AI 是旁路能力，不该因为它起不来）。
     * ⚠ 密钥**本体与引用名**都不打：只打 `env` / `file` 这种类型。
     */
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
             * ★ 2026-10-17（S13 修·续）：**"已启用"不等于"能调用"**。
             *
             * `aiRuntimeValidate` 只校验 key_ref 的**形状**（`env:` / `file:` 前缀），
             * 不校验它此刻能不能解析出来 —— 于是 `env:NO_SUCH_VAR` 这种**拼错的变量名**
             * 会让总开关显示"已启用"、而每次调用都失败（只能从分诊的 ai_reason 里看出来）。
             *
             * ⇒ 这里再解析一次，解析不到就明确告警。**只打印**，不改变任何行为。
             * ⚠ refKind 已经是 `env`/`file` 这种类型词，不含变量名与路径。
             */
            if (aiOpt.keyRef.size > 0 && aiResolveKey(aiOpt.keyRef).isNone()) {
                eprintln("    ⚠ 但**密钥引用解析不到**（${refKind}）：调用会失败并回落规则兜底；请检查该环境变量/文件是否存在")
            }
        } else {
            eprintln("AI：**未启用**（分诊将只走规则兜底，患者仍能拿到结论）")
            eprintln("    原因：${aiOpt.disabledReason}")
            eprintln("    启用：管理台「AI 配置」设 ai.enabled=1 + ai.key_ref（env:变量名 或 file:路径），或见 docs/FRONTEND-INTEGRATION.md")
        }
    } catch (e: Exception) {
        eprintln("[WARN] 检查 AI 状态失败（不影响启动）：${e.message}")
    }
    /*
     * 管理台静态目录：按 **相对进程工作目录** 的候选依次找（文档里的启动命令都在
     * `server/` 下执行）。⚠ 找不到时**不挂载**并明确告警，而不是挂上去再每个请求 404
     * —— 后者看起来像"后台坏了"，真因却只是启动目录不对。
     */
    let adminWebDir = pickAdminWebDir()
    /*
     * ★ 2026-10-14（修 D6）：`--prod` 下找不到管理台目录 = **拒绝启动**。
     *
     * 理由：生产启动命令是写死的（部署脚本/工单里那条），"目录没同步过去"是**部署错误**，
     * 不是运行时选项 —— 让它带着警告继续跑，等于把"管理台打不开"变成几周后的一句
     * "后台怎么没了"。开发态（非 --prod）仍只告警：联调时不该因为少一个静态目录起不来。
     */
    if (adminWebDir.size == 0 && prod) {
        println("❌ --prod 下没找到管理台静态目录，拒绝启动（管理台属于该部署形态的一部分）。")
        printAdminWebMissingHint()
        return 1
    }
    /*
     * ★ 2026-10-17（S4 修）：把库探针交给 `/health`。
     * ⚠ 闭包**不能**直接捕获 `var db`（仓颉报 `lambda capturing mutable variables
     *   needs to be called directly`，与 db_mysql.cj 里那只观测钩子同一个坑）——
     *   所以先落一个 `let` 别名再捕获。`db` 本身仍是 `var`（`openDatabase` 会抛，
     *   赋值必须在 try 里）。
     */
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
     * ★ TLS 分支 —— 两条纪律：
     *   ① 轻舟的 `serveTls(port, certPem, keyPem)` 收的是 **PEM 字符串**而不是路径，
     *      所以读文件与异常处理都在**调用方**（搬迁前为此专门写过注释）。
     *   ② **绝不静默降级**：任何一步失败都 return，不回退到明文。
     *
     * 只给其中一个（只有 cert 没有 key，或反之）也直接拒绝 ——
     * 那多半是命令行打漏了，静默按明文起会让人以为 TLS 生效了。
     *
     * ⚠ `tlsFilesGiven` 也参与判定（2026-10-07 修）：只有"**用户表达了要 TLS**"
     *   （给了 --tls-cert/--tls-key/--tls-files 三者之一）而最终没凑齐 cert+key 时，
     *   **一律拒绝启动**。不能只看"解析出来的字符串是否非空" ——
     *   那正是静默降级的入口。
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
    /*
     * ★ 2026-10-14（第三方复查 A2/E1 修）：多给的参数**不许静默忽略**，登录名必须是个名字。
     *
     * 原实现只读 args[1] 就不管了，于是：
     *   · `create-admin <dsn> --force` → 建出**登录名字面量为 `--force`** 的管理员并打印口令
     *     （那个账号随后没人会去登录）；
     *   · `create-admin <dsn> admin --prod` → `--prod` 被静默吞掉，使用者以为有什么约束生效了。
     * 这两条都是"命令行写下的东西没生效，却也不报错"。
     */
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
     * ★★ 口令生成 + 建号，**整体包在 try/catch 里**（2026-10-07 修）。
     *
     * ── 原缺陷（第四份复查发现；我实测复现：70 次失败 6 次 = 8.6%）──────────
     * `randCode(12)` 不保证成分 ⇒ 约 7.7% 概率生成"全字母"口令 ⇒ 被本项目
     * **自己**的口令强度规则②（必须含字母与数字）拒 ⇒ 抛 `UserFacingError`。
     * 而原来的 try/catch **只包了建库那段**，于是异常直冒到顶层，
     * 用户看到的是**堆栈**（`An exception has occurred: … at qingzhou::UserFacingError::init`），
     * 而不是其它地方统一的 `❌ 清晰提示`。
     *
     * `randCode` 已改为**保证成分**，正常不再触发；但这里仍然要：
     *   ① 兜住可提示失败 → `❌` + 退出码 1（**不冒堆栈**：CLI 是给人用的，
     *      堆栈对使用者无意义，也会淹没真正的原因）；
     *   ② ★ 加一次**重试**：万一将来又出现"生成器与校验器不一致"，重试能自愈，
     *      而不是让约 1/12 的引导操作直接失败。
     *      —— `create-admin` 是**唯一的引导入口**（第一个管理员 + 口令找回），
     *      失败一次代价很高，值得这层保险。
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
     * ★ 2026-10-14（第三方复查 D5 修）：口令走 **stderr**，并明确禁止重定向。
     *
     * 原先三行全走 stdout，而运维的标准写法是 `... > deploy.log 2>&1` ——
     * 于是"只显示这一次（未落盘）"这句承诺当场失效：口令进了日志文件、CI 输出、
     * 终端 scrollback。**承诺与实现不一致，比不承诺更危险**（人会相信那句承诺）。
     *
     * 走 stderr 的意义：`> log` 只收 stdout，口令不会被顺手写进日志；
     * 要落盘必须显式 `2>` —— 那是一个"我确实要这么做"的动作。
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
 * create-db：幂等建库（CREATE DATABASE IF NOT EXISTS <db> CHARACTER SET utf8mb4）。
 *
 * 为什么需要：`accept` 现在**只允许对显式测试库跑**（库名含 `test`），
 * 而测试库得先存在。很多业务账号（本项目的 `hospital`）建连时就带库名，
 * 库不存在直接连不上 —— 于是"先建库"成了一个绕不开的动作。
 * 这里提供一个显式入口，而不是让服务每次启动都尝试建库
 * （建库通常需要比业务账号更高的权限，不该由服务进程长期持有）。
 *
 * ⚠ 账号必须**有建库权限**（或不带库名也能连）。没权限时会明确报错并给出
 *   `CREATE DATABASE ...` 手工命令，而不是含糊地说"建库失败"。
 */
func createDb(args: Array<String>): Int64 {
    let dsn = args[0]
    /*
     * 解析 `--admin-dsn`（照 serve 的口径：**严格解析、未知参数直接拒**，
     * 不做"忽略看不懂的选项"那种宽松处理 —— 那会让 `--admin-dsn` 拼错时静默失效，
     * 而使用者会以为已经授好权了）。
     */
    var adminDsn = ""
    var ai = 1
    while (ai < args.size) {
        if (args[ai] == "--admin-dsn") {
            // ★ 2026-10-14（第三方复查 A2 同族）：`--admin-dsn` 是**取值型**参数，
            //   缺值时报"未知参数：--admin-dsn"是**误导**（参数明明认识），
            //   使用者会去猜"是不是这个名字写错了"，而不是"我忘了给值"。
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
     * ★★ 建完库还要**让库对当前账号真的可用**（第八份复查的真问题）。
     *
     * 原来这里直接打印「✅ 库已就绪」就返回了 —— 而权限是**按库逐个授**的：
     * 本项目的 `hospital` 账号只有 `CREATE ON *.*` + 两个库的 ALL，
     * 所以它**能建第三个库、却对新库没有任何权限**。
     * ⇒ 「就绪」是**假的**：紧接着 `check-db` 的 `migrateSchema` 会在 ALTER 上被拒。
     *
     * 现在：建库 → 探测（真做一次 DDL）→ 不可用则尝试自助授权 →
     *   还不行就**明确报"已建好但用不了" + 给 root 命令**，并返回失败。
     *   📌 关键纪律：**不许把"不可用"报成"就绪"**。
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
     * ★ 2026-10-14（第三方复查 D7 修）：退出码要能被 CI 当判据用。
     *
     *   · **无参数** ⇒ usage + `return 2`（原为 0）。无参是**用法错误**，
     *     而 `deploy.ps1` 里 `hospital-server.exe $cmd ...; if ($LASTEXITCODE -ne 0)` 这类
     *     判据会把"忘了传子命令"读成"跑成功了"。
     *   · `--help` / `-h` ⇒ usage + `return 0`（约定俗成：**主动要帮助不是错误**）。
     *     原实现把它归到"未知子命令"里退 2，脚本里 `--help` 探活会误判失败。
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
