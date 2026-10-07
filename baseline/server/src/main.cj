package qingzhou

/*
 * SPDX-License-Identifier: MIT
 *
 * 社团管理工具 · 服务端
 * 入口：serve / serve-tls / init-admin / init-ops / retire-ops / test
 *
 * 构建：server/build.ps1（cjc 1.1.3 + stdx 1.1.3.1 + 轻舟源码同包编译 + MariaDB 驱动）
 *
 * ===== 数据层：MySQL（2026-09-20，路线 B）================================
 *
 * club-server 的持久化已从"启动读 data/db.json / 每次变更整库重写 db.json"
 * 换成"启动从 MySQL 全量载入内存 / 每次变更在一个事务里写回 MySQL"。
 * **内存模型与全部业务/派生逻辑一行未动**（见 store.cj 顶部与 mysql_store.cj）。
 *
 * 连接参数怎么给（两种，二选一）：
 *   · **DSN**（推荐）：`mysql://user:pass@host:port/db`
 *   · **命名参数**：`--mysql-host H --mysql-port P --mysql-user U --mysql-pass PW --mysql-db D`
 * 命令行里给了哪一项就以哪一项为准；没给的项取默认值
 * （127.0.0.1 : 3306 / root / 空口令 / club_server）。
 * 库不存在时**自动建**（`CREATE DATABASE IF NOT EXISTS`，utf8mb4）。
 *
 * ⚠ 为什么只支持命令行、不支持环境变量：本工具链的仓颉 std **没有** getEnv / envVars
 *   （框架 config.cj 里核对过："neither std.env nor std.process has them on this toolchain"）。
 *   所以"从环境变量读"这条实现不了 —— 见 docs/mysql-backend.md 与 docs/local-deploy.md。
 *
 * ⚠ `--data-dir` 现在**只管审计日志**（audit.log 仍写文件，见 audit.cj）：
 *   业务数据全在 MySQL 里，db.json 不再是真相来源。
 *
 * ⚠ 口令绝不进日志、也不进任何响应：启动横幅只打印 `pass=***`；见 MySqlConfig.describe()。
 *
 * 部署约束（..\docs\deploy-windows-verify.md §3）：
 *   · **cwd 必须是 exe 所在目录**——审计日志与证书都按相对路径读
 *   · 4 个 DLL 必须与 exe 同目录（含两个 OpenSSL 3 DLL，缺失时 crypto 运行时才报错；
 *     MySQL 驱动的认证哈希也依赖它们）
 */

import std.collection.*
import std.convert.*
import std.fs.*
import std.time.*
import stdx.encoding.json.*


/* 用对象持有 ServerHandle：闭包捕获 var 的语义不可靠，这里显式放进盒子里。 */
class HandleBox {
    public var handle: ?ServerHandle = None

    init() {}
}

func usage(): Unit {
    println("社团管理工具 · 服务端 v${APP_VERSION}")
    println("")
    println("用法:")
    println("  club-server init-admin <手机号> <初始密码> [DSN] [姓名选项] [连接选项]")
    println("                                                         初始化首任会长与 4 个组织（仅空库可执行）")
    println("  club-server init-ops <手机号> <口令> [DSN] [连接选项]    创建/重设运维账号（角色 ops；除移交会长外与会长同权）")
    println("  club-server retire-ops <手机号> [DSN] [连接选项]        停用运维账号（保留记录）")
    println("  club-server serve [端口] [DSN] [连接选项]               启动 HTTP 服务（默认 8080）")
    println("  club-server serve-tls [端口] [DSN] [--cert F] [--key F] [连接选项]   启动 HTTPS（默认 8443 / certs/cert.pem / certs/key.pem）")
    println("  club-server test [DSN]                                  运行单测（给 DSN 时额外做一次 MySQL 持久化往返验证）")
    println("")
    println("数据层：**MySQL**（2026-09-20 起；data/db.json 不再是真相来源）。")
    println("  · DSN 形如 mysql://用户:口令@主机:端口/库名")
    println("      例：mysql://root:clubroot123@127.0.0.1:3307/club_server")
    println("      口令里若含 @ : / ? # 等字符，写成 %XX 百分号编码（如 @ → %40）")
    println("  · 或不给 DSN，改用命名参数：")
    println("      --mysql-host 127.0.0.1 --mysql-port 3307 --mysql-user root")
    println("      --mysql-pass <口令> --mysql-db club_server")
    println("      没给到的项取默认值（127.0.0.1 : 3306 / root / 空口令 / club_server）")
    println("  · 库不存在会自动建（utf8mb4）；表不存在会自动建（7 张业务表 + 2 张元数据表）")
    println("  · 本工具链的仓颉 std 没有 getEnv —— **不支持环境变量配置**，只能走命令行")
    println("")
    println("  --data-dir <目录>   审计日志（audit.log）的落点，默认 data。业务数据不在文件里。")
    println("  --public-url <前缀>  招募链接用哪个地址对外。例：--public-url http://10.194.17.0:8080")
    println("                     不给就按「客户端连进来的 Host」拼，scheme 跟 serve/serve-tls 走。")
    println("                     ⚠ 模拟器连的是 10.0.2.2，那样拼出来的链接**只有模拟器能打开**；")
    println("                       要发到群里给队友点，就用本机局域网 IP 显式指定它。")
    println("")
    println("  --ai-endpoint <URL>   大模型端点（OpenAI 兼容的完整 URL）。**给了才启用 AI 功能**；")
    println("                        不给则 5 个智能接口一律返回 source=\"fallback\"（规则兜底、内容不为空），服务照常运行。")
    println("  --ai-model <名>       模型名（协议必填字段），例如 deepseek-chat。")
    println("  --ai-key-file <文件>  密钥文件路径（**只走文件**，不接受命令行直传，避免进 shell 历史）。")
    println("  --ai-ca <文件>        CA bundle（PEM）。⚠ Windows 上 Default 没有信任库、必须给；")
    println("                        本机开发可改用 --ai-insecure-trust-all 1。")
    println("  --ai-timeout <秒>     读 / 写超时，默认 30（允许 1..300）。")
    println("  --ai-max-concurrent <N>  同时在途的智能调用上限，默认 4（允许 1..64）。")
    println("  --ai-max-tokens <N>   单次补全的 token 上限，默认 2048（允许 64..8192）。")
    println("                        ⚠ 给太小会截断长正文 -> 非法 JSON -> 静默降级为规则兜底。")
    println("  --ai-insecure-trust-all 1  ⚠ 跳过证书校验，**仅限本机开发**（必须带值 1）。")
    println("")
    println("⚠ 必须有可连的 MySQL：club-server 从本轮起**不再能只靠一个目录跑起来**。")
    println("  起一台本机 MariaDB（便携版、不装服务）：")
    println("    & \"<MariaDB>\\bin\\mysqld.exe\" --datadir=\"<数据目录>\" --port=3307 --console")
    println("")
    println("证书必须是**带 SAN** 的自签证书（现代客户端只看 subjectAltName，完全忽略 CN）。")
    println("密码：8-32 位，只能用数字 / 英文 / 符号（如 ._/\\-!@#）。")
    println("⚠ 所有命令行参数只支持 ASCII —— 中文参数会让仓颉的 argv 解析直接抛异常（见 docs/API-NOTES.md 坑 11）。")
    println("  所以**中文姓名不能写进 --name**（写进去会在 main 之前就崩）：把姓名存成一个")
    println("  **UTF-8 文本文件**（内容就是姓名，可带 BOM 与结尾换行），用 --name-file <文件> 传入。")
    println("  不传姓名选项时，首任会长的姓名默认是「会长」。例：")
    println("    club-server init-admin 13800000000 <口令> mysql://root:pw@127.0.0.1:3307/club_server --name-file president-name.txt")
    println("    club-server init-admin 13800000000 <口令> --mysql-db club_server --name LiSi   （仅 ASCII 姓名）")
}

/* ===================== 连接参数：DSN 与命名参数（2026-09-20） =====================
 *
 * 为什么自己解析 DSN，而不用框架的 `openStore("mysql://…")`：
 *   那个工厂在 third_party\qingzhou\src\db_factory.cj 里，而它 `import` 了 CangDbBackend
 *   （db_cangdb.cj）—— 那条构建被我们排除了（沧海 CangDB 1.0.5 与 cjc 1.1.3 不兼容）。
 *   要把工厂编进来就必须把 db_cangdb.cj 也编进来，而它引用 cangdb.* → 编不过。
 *   所以 club-server 侧**直接构造 MySqlBackend**（admin_main.cj 早就是这个做法）。
 */

/*
 * 百分号解码（`%40` → `@`）。口令里出现 @ : / ? # 时只能这样写进 DSN。
 * 非法序列（% 后面不是两位十六进制）原样保留 —— DSN 是本地配置，不是攻击面，
 * 这里的目标是"能用"，不是"严格"。
 */
func percentDecode(s: String): String {
    if (!containsAscii(s, "%")) {
        return s
    }
    let a = s.toArray()
    let out = ArrayList<UInt8>()
    var i: Int64 = 0
    while (i < a.size) {
        if (a[i] == UInt8(0x25) && i + 2 < a.size) {
            let h1 = hexVal(a[i + 1])
            let h2 = hexVal(a[i + 2])
            if (h1 >= 0 && h2 >= 0) {
                out.add(UInt8(h1 * 16 + h2))
                i += 3
                continue
            }
        }
        out.add(a[i])
        i += 1
    }
    return String.fromUtf8(out.toArray())
}

/* 十六进制字符 → 数值；不是十六进制返回 -1。 */
func hexVal(c: UInt8): Int64 {
    if (c >= UInt8(0x30) && c <= UInt8(0x39)) { return Int64(c - UInt8(0x30)) }
    if (c >= UInt8(0x61) && c <= UInt8(0x66)) { return Int64(c - UInt8(0x61)) + 10 }
    if (c >= UInt8(0x41) && c <= UInt8(0x46)) { return Int64(c - UInt8(0x41)) + 10 }
    return -1
}

/* 在这个位置找第一个分隔字符，返回下标；找不到返回 -1。 */
func idxOfChar(s: String, ch: UInt8, from: Int64): Int64 {
    let a = s.toArray()
    var i = from
    while (i < a.size) {
        if (a[i] == ch) {
            return i
        }
        i += 1
    }
    return -1
}

/* 字节切片 → String（DSN 的各段都是 ASCII，切点保证落在字符边界上）。 */
func subBytes(s: String, b: Int64, e: Int64): String {
    if (e <= b) {
        return ""
    }
    return String.fromUtf8(s.toArray()[b..e])
}

/*
 * 解析 `mysql://用户:口令@主机:端口/库名`（也接受 `mariadb://` 前缀，因为
 * 内置驱动的注册名是 mariadb —— 两种写法指同一条链路，别让用户去记哪个是哪个）。
 *
 * 容错约定（都是"能猜对就不报错"，DSN 是本地配置）：
 *   · 没有 `口令@` → 空口令；没有 `用户` → root
 *   · 没有 `:端口` → 3306；没有 `/库名` → club_server
 * 解析不出来（没有 `://`）→ 抛出带示例的中文错误。
 */
func parseDsn(dsn: String, cfg: MySqlConfig): Unit {
    var rest = ""
    if (startsWithAscii(dsn, "mysql://")) {
        rest = dsn[8..]
    } else if (startsWithAscii(dsn, "mariadb://")) {
        rest = dsn[10..]
    } else {
        /* 不回显原始 DSN：它可能包含数据库口令，且该异常会直接写入启动日志。 */
        throw Exception("DSN 必须以 mysql:// 开头（例：mysql://root:pw@127.0.0.1:3306/club_server）")
    }
    /* 库名 = 第一个 '/' 之后 */
    let slash = idxOfChar(rest, UInt8(0x2F), 0)
    var hostPart = rest
    if (slash >= 0) {
        let dbName = percentDecode(subBytes(rest, slash + 1, rest.toArray().size))
        if (dbName.size > 0) {
            cfg.db = dbName
        }
        hostPart = subBytes(rest, 0, slash)
    }
    /* 用户信息 = 最后一个 '@' 之前（口令里可能有编码过的 @，但那已经是 %40 了） */
    let at = lastIdxOfChar(hostPart, UInt8(0x40))
    if (at >= 0) {
        let userInfo = subBytes(hostPart, 0, at)
        let colon = idxOfChar(userInfo, UInt8(0x3A), 0)
        if (colon >= 0) {
            let u = percentDecode(subBytes(userInfo, 0, colon))
            if (u.size > 0) {
                cfg.user = u
            }
            cfg.pass = percentDecode(subBytes(userInfo, colon + 1, userInfo.toArray().size))
        } else if (userInfo.size > 0) {
            cfg.user = percentDecode(userInfo)
        }
        hostPart = subBytes(hostPart, at + 1, hostPart.toArray().size)
    }
    /* 主机[:端口] */
    let colon2 = lastIdxOfChar(hostPart, UInt8(0x3A))
    if (colon2 >= 0) {
        let host = subBytes(hostPart, 0, colon2)
        if (host.size > 0) {
            cfg.host = host
        }
        let ps = subBytes(hostPart, colon2 + 1, hostPart.toArray().size)
        if (ps.size > 0) {
            /* 端口非法时**明确报错**，不做"悄悄退回 3306"那种降级（会连到别的库） */
            let p = try {
                Int64.parse(ps)
            } catch (e: Exception) {
                throw Exception("DSN 里的端口不是数字：${ps}")
            }
            if (p < 1 || p > 65535) {
                throw Exception("DSN 里的端口越界（1..65535）：${p}")
            }
            cfg.port = p
        }
    } else if (hostPart.size > 0) {
        cfg.host = hostPart
    }
}

func lastIdxOfChar(s: String, ch: UInt8): Int64 {
    let a = s.toArray()
    var i = a.size - 1
    while (i >= 0) {
        if (a[i] == ch) {
            return i
        }
        i -= 1
    }
    return -1
}

/*
 * 从 argv 里摘出 `--x value` 形式的命名参数，并**返回剩下的位置参数**。
 *
 * 为什么自己摘而不是让每个子命令各写一套：club-server 有 5 个子命令、每个都接受
 * 连接参数，且位置参数个数各不相同（serve 的端口、init-admin 的姓名选项…）。
 * 统一先摘一轮，各子命令就只需要面对"纯位置参数 + 一张选项表"。
 *
 * `--x` 后面没跟值 → 抛异常（静默忽略正是"以为传了、其实没传"的来源，
 * 见 main() 里 --name 那段注释的同一条理由）。
 */
func splitFlags(args: Array<String>): (HashMap<String, String>, ArrayList<String>) {
    let flags = HashMap<String, String>()
    let pos = ArrayList<String>()
    var i: Int64 = 0
    while (i < args.size) {
        let a = args[i]
        if (startsWithAscii(a, "--")) {
            if (i + 1 >= args.size) {
                throw Exception("选项 ${a} 后面要跟一个值")
            }
            flags[a] = args[i + 1]
            i += 2
        } else {
            pos.add(a)
            i += 1
        }
    }
    return (flags, pos)
}

/* 从选项表里取一个值；没有就返回 ""。 */
func flagOf(flags: HashMap<String, String>, k: String): String {
    match (flags.get(k)) {
        case Some(v) => return v
        case None => return ""
    }
}

/*
 * 拼出最终的连接配置：
 *   默认值 → DSN（若有）→ 命名参数（若有，逐项覆盖）
 * 两者都给时命名参数优先（更具体的那一个赢）。
 * 命令行里给的位置参数若既不是 DSN 又不像旧的数据目录，这里会明确报错。
 */
func resolveMySqlCfg(positionalDsn: String, flags: HashMap<String, String>): MySqlConfig {
    let cfg = MySqlConfig()
    if (positionalDsn.size > 0) {
        parseDsn(positionalDsn, cfg)
    }
    let h = flagOf(flags, "--mysql-host")
    let p = flagOf(flags, "--mysql-port")
    let u = flagOf(flags, "--mysql-user")
    let pw = flagOf(flags, "--mysql-pass")
    let d = flagOf(flags, "--mysql-db")
    if (h.size > 0) { cfg.host = h }
    if (u.size > 0) { cfg.user = u }
    if (pw.size > 0) { cfg.pass = pw }
    if (d.size > 0) { cfg.db = d }
    if (p.size > 0) {
        let pv = try {
            Int64.parse(p)
        } catch (e: Exception) {
            throw Exception("--mysql-port 不是数字：${p}")
        }
        if (pv < 1 || pv > 65535) {
            throw Exception("--mysql-port 越界（1..65535）：${pv}")
        }
        cfg.port = pv
    }
    /* 库名兜底。⚠ 这里**不**做合法性校验：真正进 `CREATE DATABASE` 的地方是
     * mysql_store.cj 的 ensureDatabase() → dbNameChecked()（标识符白名单就在那里，
     * 校验与使用紧挨着，不会出现"这里过了、那里漏了"）。原文写成"先在这里挡一道"，
     * 与代码不符，已更正。 */
    if (cfg.db.size == 0) {
        cfg.db = "club_server"
    }
    /*
     * 记下"这一份完全是默认值"这个事实 —— 命令行既没给 DSN、也没给任何 --mysql-*。
     *
     * 为什么值得单独记：默认端口是 MySQL 出厂默认 **3306**，而本机联调的便携版
     * MariaDB 在 **3307**，于是"连接参数没传进来"的表现是 `Failed to connect 10061`，
     * 看起来像服务器/端口配错。实测踩到：PowerShell 里引用了**未定义**的 `$dsn`
     * —— 未定义变量在 PowerShell 里就是空串、**不报错**，命令便悄悄退回了默认值。
     * 由 loadOrExitDb 在真正连接**之前**把这件事喊出来（见那里的打印）。
     */
    if (positionalDsn.size == 0 && h.size == 0 && p.size == 0 && u.size == 0 &&
        pw.size == 0 && d.size == 0) {
        cfg.fromDefaults = true
    }
    return cfg
}

/*
 * 位置参数里那个"连接参数槽"的取值校验。
 *
 * 老用法是 `<数据目录>`（如 `build/smoke-data`）。迁到 MySQL 之后**故意不再接受目录**：
 * 若把 `build/smoke-data` 当 DSN 悄悄忽略、转而去连默认库，就会变成
 * "以为在测临时库、实际在写正式库"—— 那是最坏的一类静默错误。
 * 所以这里明确报错，并给出两条正确写法。
 */
func dsnOrEmpty(token: String): String {
    if (token.size == 0) {
        return ""
    }
    if (startsWithAscii(token, "mysql://") || startsWithAscii(token, "mariadb://")) {
        return token
    }
    /* 不回显 token：调用方可能误把带口令的连接串写成了错误前缀。 */
    throw Exception("第二个参数现在是 **MySQL DSN**，不再是数据目录。\n" +
        "  正确写法之一：mysql://root:口令@127.0.0.1:3307/club_server\n" +
        "  正确写法之二：省略它，改用 --mysql-host / --mysql-port / --mysql-user / --mysql-pass / --mysql-db\n" +
        "  （审计日志目录请用 --data-dir <目录>；业务数据已全部在 MySQL 里）")
}


/*
 * 连接 MySQL 并全量载入；失败就退出——绝不带着空库继续跑。
 *
 * 为什么失败一律 FATAL（不重试、不降级）：
 *   "带着空库继续跑"的后果是**下一次保存把真实数据整体覆盖掉**（这是本文件
 *   从文件后端时代就有的口径，见 storeLoad 的注释）。宁可起不来，让人来看日志。
 */
func loadOrExitDb(cfg: MySqlConfig, dir: String): ?Store {
    try {
        println("[db] 连接 ${cfg.describe()}")
        /*
         * ⚠ 用的是**默认连接参数**时，在真正连接之前就喊出来。
         *
         * 触发场景（实测踩过）：PowerShell 里 `.\club-server.exe init-ops 13800000009 123456789 $dsn`
         * 而 `$dsn` 从未定义 —— 未定义变量在 PowerShell 里就是**空串**、也不报错，于是
         * 位置参数空着，程序按默认值 127.0.0.1:**3306** / root / 空口令 / club_server 去连。
         * 本机联调那台便携版 MariaDB 在 **3307**，结果就是 `Failed to connect 10061`，
         * 而错误信息里看不出"参数根本没传进来"这一层。
         * 这里把话说明白，省掉一整轮"是不是端口写错了"的排查。
         */
        if (cfg.fromDefaults) {
            println("[db] ⚠ 命令行**没有**给 DSN / --mysql-*，正在使用默认连接参数：${cfg.describe()}")
            println("[db]    若你在照文档操作，多半是 DSN 变量为空（PowerShell 引用未定义的变量 = 空串，不报错）。")
            println("[db]    本机联调的便携版 MariaDB 在 127.0.0.1:3307，正确写法：")
            println("[db]      club-server.exe <子命令> ... \"mysql://root:<口令>@127.0.0.1:3307/club_server\"")
        }
        ensureDatabase(cfg)
        let ms = MysqlStore(cfg)
        ensureSchema(ms)
        printSqlModeHint(ms)
        let s = storeLoadDb(ms, dir)
        println("[db] 已从 MySQL 载入：成员 ${s.members.size} 人  课题 ${s.plans.size} 个  任务 ${s.tasks.size} 个  部门 ${s.departments.size} 个")
        return Some(s)
    } catch (e: Exception) {
        println("[FATAL] ${e.message}")
        return None
    }
}

/*
 * 启动期打印一次服务端的 sql_mode 状态。
 *
 * 为什么值得打印：我们的参数绑定走框架的 SQL 字面量转义（只双写单引号），
 * 再补一层"反斜杠也双写"（mysql_store.cj 的 mysqlSafe）。那个补丁**假定服务端
 * 处于默认的反斜杠转义模式**；若服务端开了 NO_BACKSLASH_ESCAPES，`\\` 会被原样存成两个。
 * 这不是我们能在应用侧单方面决定的事（改 sql_mode 需要 SUPER 权限、且影响同实例的别人），
 * 所以至少让它在启动日志里可见 —— 而不是等到有人发现"文本里多了个反斜杠"才去查。
 */
func printSqlModeHint(ms: MysqlStore): Unit {
    try {
        let mode = ms.q("SELECT @@sql_mode", Array<DbValue>()).cell(0, 0)
        if (containsAscii(mode, "NO_BACKSLASH_ESCAPES")) {
            println("[db] ⚠ 服务端 sql_mode 含 NO_BACKSLASH_ESCAPES：文本里的反斜杠会被多存一个" +
                "（见 src\\mysql_store.cj 的 mysqlSafe）。要么去掉该选项，要么接受这个偏差。")
        } else {
            println("[db] sql_mode 为标准反斜杠转义模式（参数绑定已按此口径转义）")
        }
    } catch (e: Exception) {
        /* 查不到不是致命问题（有的账号看不到 @@sql_mode），不打断启动 */
        println("[db] 提示：读不到 @@sql_mode（${e.message}）")
    }
}

/* 预置 4 个组织（v1-scope §5，可改名） */
func seedDepartments(s: Store): Unit {
    let names = ["主席团", "课题部", "运营部", "宣传部"]
    var i: Int64 = 0
    while (i < names.size) {
        let d = Department()
        d.id = s.next_dept
        s.next_dept += 1
        d.name = names[i]
        d.sort = i
        s.departments[d.id] = d
        i += 1
    }
}

func deptIdByName(s: Store, name: String): Int64 {
    for ((_k, d) in s.departments) {
        if (d.name == name) {
            return d.id
        }
    }
    return 0
}

/* ===================== 会长姓名的输入通道（2026-09-17） =====================
 *
 * 为什么姓名不能直接当第 4 个命令行参数：**中文参数会让程序在 main 之前就崩**。
 * 实测 `club-server.exe init-admin 13700000001 TestPass2026 nametest 张三` →
 * 无输出、exit 1，只有 `IllegalArgumentException: Invalid unicode scalar value.`；
 * 中文放在手机号 / 口令 / 数据目录任一位置都一样，切代码页（936 / 65001）也不行 ——
 * 它抛在仓颉把 argv 拼成 String 那一步，早于本文件里的任何代码（docs/API-NOTES.md 坑 11）。
 * 所以中文姓名只能**绕开 argv**：写进一个 UTF-8 文本文件，用 `--name-file` 传路径。
 * （也评估过环境变量：仓颉 std 没有 `getEnv` / `envVars`，见 third_party/qingzhou/src/config.cj
 *   的说明 —— 不适合拿一个未验证的 API 去搭功能，所以不采用。）
 */

/* ASCII 空白：空格 / 制表 / LF / CR / VT / FF。姓名文件多半带一个结尾换行。 */
func isAsciiSpaceByte(c: UInt8): Bool {
    return c == UInt8(0x20) || c == UInt8(0x09) || c == UInt8(0x0A) ||
        c == UInt8(0x0D) || c == UInt8(0x0B) || c == UInt8(0x0C)
}

/*
 * 去掉首尾 ASCII 空白。只切**空白字节**，所以边界一定落在字符边界上，
 * 不会把一个多字节汉字切开（这也是不按"字符"裁剪的原因）。
 */
func trimAsciiBlank(s: String): String {
    let a = s.toArray()
    var b: Int64 = 0
    var e: Int64 = a.size
    while (b < e && isAsciiSpaceByte(a[b])) {
        b += 1
    }
    while (e > b && isAsciiSpaceByte(a[e - 1])) {
        e -= 1
    }
    if (b == 0 && e == a.size) {
        return s
    }
    return String.fromUtf8(a[b..e])
}

/* 从 UTF-8 文本文件读一个姓名；任何问题都打印人话并返回 None。 */
func readNameFile(path: String): ?String {
    var bytes: Array<UInt8>
    try {
        bytes = File.readFrom(path)
    } catch (e: Exception) {
        println("读不到姓名文件：${path}（${e.message}）")
        return None
    }
    /* PowerShell 5.1 的 `Set-Content -Encoding UTF8` 写出来是**带 BOM** 的，这里替用户剥掉 */
    if (bytes.size >= 3 && bytes[0] == UInt8(0xEF) && bytes[1] == UInt8(0xBB) && bytes[2] == UInt8(0xBF)) {
        bytes = bytes[3..]
    }
    var text = ""
    try {
        text = String.fromUtf8(bytes)
    } catch (e: Exception) {
        println("姓名文件不是合法的 UTF-8：${path}")
        return None
    }
    let name = trimAsciiBlank(text)
    if (isBlank(name)) {
        println("姓名文件是空的：${path}（文件内容应当就是这个人的姓名）")
        return None
    }
    return Some(name)
}

/*
 * 首任会长用**初始化命令**预置（api-design §2.8 决策 8），
 * 不采用"首个注册者自动成为会长"——那等于把社团管理权交给第一个扫码的人。
 *
 * name：首任会长的姓名；调用方已保证非空白（默认「会长」）。
 * 与 HTTP 的 `PATCH /api/v1/members/{id}` 同一口径 —— 那边也只要求姓名非空白（见 h_member.cj）。
 */
func cmdInitAdmin(phone: String, pw: String, cfg: MySqlConfig, dir: String, name: String): Int64 {
    if (!isPhone(phone)) {
        println("手机号格式不正确（11 位，以 1 开头）")
        return 1
    }
    /* 与注册 / 改密同一口径（D-6：8–32 字节 + 只用数字/英文/符号），别让初始化命令成为第三条规则 */
    let pwErr = passwordError(pw)
    if (pwErr.size > 0) {
        println(pwErr)
        return 1
    }
    let loaded = loadOrExitDb(cfg, dir)
    let s = match (loaded) {
        case Some(x) => x
        case None => return 1
    }
    s.lock.lock()
    try {
        if (presidentCount(s) > 0) {
            println("已存在会长账号：init-admin 只能对空库执行一次")
            return 1
        }
        if (memberByPhone(s, phone).isSome()) {
            println("该手机号已存在，不能重复初始化")
            return 1
        }
        if (s.departments.size == 0) {
            seedDepartments(s)
        }
        let now = nowEpoch()
        let m = Member()
        m.id = s.next_member
        s.next_member += 1
        m.name = name
        m.phone = phone
        let rec = newPasswordRecord(pw)
        m.pw_salt = rec[0]
        m.pw_hash = rec[1]
        m.pw_iter = rec[2]
        m.role = "president"
        m.dept_id = deptIdByName(s, "主席团")
        m.status = "active"
        m.joined_at = now
        s.members[m.id] = m

        if (s.register_code.size == 0) {
            s.register_code = newRegisterCode()
            s.register_code_by = m.id
            s.register_code_at = now
        }
        /* 命令行路径，不在 HTTP 请求里，没有刷盘中间件可依赖 → 用同步落盘。 */
        storeSaveNow(s)

        println("已创建首任会长：${name}（${phone}，成员 id=${m.id}，部门=${m.dept_id}）")
        println("当前注册口令：${s.register_code}")
        println("业务数据已在 MySQL：${cfg.describe()}")
        println("审计日志目录：${s.dir}（audit.log）")
    } finally {
        s.lock.unlock()
    }
    return 0
}

/*
 * 运维账号（`role = "ops"`）的建号 / 重设口令 —— 2026-09-16 新增。
 *
 * 为什么要专门的账号：运维不该由会长本人做（职责分离）。运维人员用后台自己的账号
 * （admin/admin123）登录运维台，运维台再用这个账号去调 club-server ——
 * 于是审计里 actor 是"运维"，而不是会长。
 *
 * 为什么只能用命令行建（API 不给分配这一档，见 views.cj 的 isKnownRole）：
 * 运维的权限是"除移交会长外与会长同权"，比副会长大；若 API 能分配它，
 * 会长就能造出权限略高于自己的账号，绕过"会长只能通过移交产生"这条约束。
 * 本机命令 = 需要有这台机器的访问权，与 /admin/shutdown 的本机信任同一档。
 *
 * 幂等：手机号已存在就**重设口令 + 把角色校准回 ops**（人员轮换时重新发凭据就是这个用法）。
 */
func cmdInitOps(phone: String, pw: String, cfg: MySqlConfig, dir: String): Int64 {
    if (!isPhone(phone)) {
        println("手机号格式不正确（11 位，以 1 开头）")
        return 1
    }
    let pwErr = passwordError(pw)
    if (pwErr.size > 0) {
        println(pwErr)
        return 1
    }
    let loaded = loadOrExitDb(cfg, dir)
    let s = match (loaded) {
        case Some(x) => x
        case None => return 1
    }
    s.lock.lock()
    try {
        let rec = newPasswordRecord(pw)
        let now = nowEpoch()
        match (memberByPhone(s, phone)) {
            case Some(m) =>
                m.pw_salt = rec[0]
                m.pw_hash = rec[1]
                m.pw_iter = rec[2]
                m.role = "ops"
                m.status = "active"
                revokeOtherTokens(s, m.id, "")
                storeSaveNow(s)
                println("已重设运维账号口令：${phone}（成员 id=${m.id}，角色已校准为 ops）")
            case None =>
                let m = Member()
                m.id = s.next_member
                s.next_member += 1
                m.name = "运维"
                m.phone = phone
                m.pw_salt = rec[0]
                m.pw_hash = rec[1]
                m.pw_iter = rec[2]
                m.role = "ops"
                /* 运维不属于任何部门：dept_id = 0（它不是社团干部，名录里会排在最后） */
                m.dept_id = 0
                m.status = "active"
                m.joined_at = now
                s.members[m.id] = m
                storeSaveNow(s)
                println("已创建运维账号：${phone}（成员 id=${m.id}，角色 ops）")
        }
        println("权限：除「移交会长」外与会长同权；不可由 API 分配，只能用本命令创建")
        println("下一步：用这个手机号 + 口令直接登录运维台（http://127.0.0.1:3000/）就行")
        println("        （也可以把凭据填进 build\\admin\\admin.env 的 club_user / club_pass 让后台代持，二选一）")
        println("业务数据已在 MySQL：${cfg.describe()}")
        /*
         * 2026-09-17 加这段告警，2026-09-20 迁 MySQL 后**依然成立**：
         * club-server 只在**启动时**把库读进内存一次（现在是从 MySQL 读，语义没变）。
         * 所以"服务已经起着"时执行本命令，账号只落到库里、内存里没有 ——
         * 表现为**登录一直 401**；更坑的是运维台「成员名录」是**直读库**的，
         * 页面里**看得见**这个「运维」账号，于是极易被误判成"口令填错了"。
         * 这条实测复现过（先起服务再 init-ops → 401；重启服务 → 200）。
         */
        println("")
        println("⚠ 如果 club-server **正在运行**，它内存里还是旧的库 —— 必须**重启 club-server**，")
        println("  上面这个账号才能登录（否则登录一直 401，而运维页的名录里却看得见它）。")
        println("  正确顺序：先 init-ops，再启动 club-server；已经起了就先停掉再起。")
    } finally {
        s.lock.unlock()
    }
    return 0
}

/* 运维账号退役：停用它（保留记录，审计里仍能查到它做过什么）。 */
func cmdRetireOps(phone: String, cfg: MySqlConfig, dir: String): Int64 {
    if (!isPhone(phone)) {
        println("手机号格式不正确（11 位，以 1 开头）")
        return 1
    }
    let loaded = loadOrExitDb(cfg, dir)
    let s = match (loaded) {
        case Some(x) => x
        case None => return 1
    }
    s.lock.lock()
    try {
        let m = match (memberByPhone(s, phone)) {
            case Some(x) => x
            case None =>
                println("没有这个手机号的成员：${phone}")
                return 1
        }
        if (m.role != "ops") {
            /* 只退役运维账号：误把普通成员（尤其会长）停用掉是没法接受的副作用 */
            println("该账号的角色是 ${m.role}，不是运维账号；retire-ops 只处理 ops")
            return 1
        }
        m.status = "disabled"
        revokeOtherTokens(s, m.id, "")
        storeSaveNow(s)
        println("已停用运维账号：${phone}（成员 id=${m.id}）")
        println("若要彻底删除，直接在 MySQL 里删掉 members 表那一行（或换个手机号重建）")
        /* 同 init-ops：club-server 只在启动时读库一次，运行中改库不会生效（见 init-ops 那段注释）。 */
        println("⚠ 若 club-server 正在运行，**必须重启它**这次停用才会生效（否则旧令牌仍可用）。")
    } finally {
        s.lock.unlock()
    }
    return 0
}

/* 优雅关闭端点：仅本机可访问。 */
func handleShutdown(ctx: Context, box: HandleBox): Unit {
    if (!isLocalPeer(ctx)) {
        throw apiErrMsg("FORBIDDEN_ROLE", "该端点仅允许本机访问（来自 ${peerOf(ctx)}）")
    }
    let data = JsonObject()
    jPutStr(data, "status", "shutting-down")
    sendOk(ctx, data)
    /* 不能在请求线程里直接 shutdown()——那会等待本请求自己结束，形成死锁。
     * 交给后台线程，请求正常返回后再关。 */
    match (box.handle) {
        case Some(h) => spawn {
            /*
             * 先等 1 秒再关：`shutdown()` 里的 `server.close()` 会停止 accept 并收尾，
             * 但它**不等本请求的响应写出去**。实测（2026-09-16，8 次里 6 次）客户端会拿到
             * `HTTP 200` + **空 body** —— 本端点是 Windows 上唯一的关停入口，
             * 回执照样丢失就很难判断"到底关没关"。宁可晚 1 秒关，也要让回执可靠。
             * 回归闸门：tests/ops-check.ps1 断言关停响应体是 ok:true。
             */
            sleep(Duration.second * 1)
            h.shutdown()
        }
        case None => ()
    }
}

func buildApp(s: Store, box: HandleBox): QingZhouApp {
    /* AI 客户端：未配置时 newAiClient 返回 None，handler 据此给 source="fallback"
       服务照常运行（api-design Part 7 的口径：模型不可用不是错误）。 */
    let ai = newAiClient(aiOptionsCurrent())
    let router = Router()
        /* 运维 */
        .get("/health", { ctx: Context, _: () -> Unit =>
            handleHealth(ctx)
        })
        .post("/admin/shutdown", { ctx: Context, _: () -> Unit =>
            handleShutdown(ctx, box)
        })
        /* Part 7 · AI 能力（api-design Part 7）—— 全部 POST，
           一律返回 200 + data.source（model / fallback / none），**永不返回 5xx**。 */
        .post("/api/v1/ai/task-suggest", { ctx: Context, _: () -> Unit =>
            handleAiTaskSuggest(ctx, s, ai)
        })
        .post("/api/v1/ai/notice-draft", { ctx: Context, _: () -> Unit =>
            handleAiNoticeDraft(ctx, s, ai)
        })
        .post("/api/v1/ai/retrospective", { ctx: Context, _: () -> Unit =>
            handleAiRetrospective(ctx, s, ai)
        })
        .post("/api/v1/ai/ask", { ctx: Context, _: () -> Unit =>
            handleAiAsk(ctx, s, ai)
        })
        /* Part 7.6 · 智能体（工具循环，只读）—— 一次请求可能调 1..4 次模型 */
        .post("/api/v1/ai/agent", { ctx: Context, _: () -> Unit =>
            handleAiAgent(ctx, s, ai)
        })
        /* Part 7.9 · 确认并执行 AI 提议（写操作）。**不调模型**，失败必须显式报错 */
        .post("/api/v1/ai/agent/confirm", { ctx: Context, _: () -> Unit =>
            handleAiAgentConfirm(ctx, s, ai)
        })
        /* 招募链接落地页（无需登录，L-2）。链接是发到群里的，点开必须有内容。 */
        .get("/join/:token", { ctx: Context, _: () -> Unit =>
            handleJoinLanding(ctx, s)
        })
        /* Part 2 · 认证与注册 */
        .post("/api/v1/auth/register", { ctx: Context, _: () -> Unit =>
            handleRegister(ctx, s)
        })
        .post("/api/v1/auth/login", { ctx: Context, _: () -> Unit =>
            handleLogin(ctx, s)
        })
        .post("/api/v1/auth/logout", { ctx: Context, _: () -> Unit =>
            handleLogout(ctx, s)
        })
        .get("/api/v1/auth/me", { ctx: Context, _: () -> Unit =>
            handleMe(ctx, s)
        })
        .put("/api/v1/auth/password", { ctx: Context, _: () -> Unit =>
            handleChangePassword(ctx, s)
        })
        /* Part 3 · 组织与成员（19） */
        .get("/api/v1/depts", { ctx: Context, _: () -> Unit =>
            handleDeptList(ctx, s)
        })
        .post("/api/v1/depts", { ctx: Context, _: () -> Unit =>
            handleDeptCreate(ctx, s)
        })
        .patch("/api/v1/depts/:id", { ctx: Context, _: () -> Unit =>
            handleDeptUpdate(ctx, s)
        })
        .delete("/api/v1/depts/:id", { ctx: Context, _: () -> Unit =>
            handleDeptDelete(ctx, s)
        })
        .get("/api/v1/members", { ctx: Context, _: () -> Unit =>
            handleMemberList(ctx, s)
        })
        /* 静态段优先（router.cj 的 walk 先查 Static 再查 Param），
         * 但仍显式排在 :id 之前，避免将来换路由实现时踩坑。 */
        .get("/api/v1/members/pending", { ctx: Context, _: () -> Unit =>
            handleMemberPending(ctx, s, ai)
        })
        .post("/api/v1/members/assign-batch", { ctx: Context, _: () -> Unit =>
            handleMemberAssignBatch(ctx, s)
        })
        .get("/api/v1/members/:id", { ctx: Context, _: () -> Unit =>
            handleMemberDetail(ctx, s)
        })
        .patch("/api/v1/members/:id", { ctx: Context, _: () -> Unit =>
            handleMemberUpdate(ctx, s)
        })
        .post("/api/v1/members/:id/disable", { ctx: Context, _: () -> Unit =>
            handleMemberDisable(ctx, s)
        })
        .post("/api/v1/members/:id/assign", { ctx: Context, _: () -> Unit =>
            handleMemberAssign(ctx, s)
        })
        .post("/api/v1/members/:id/transfer-presidency", { ctx: Context, _: () -> Unit =>
            handleTransferPresidency(ctx, s)
        })
        .post("/api/v1/members/:id/reset-password", { ctx: Context, _: () -> Unit =>
            handleResetPassword(ctx, s)
        })
        .get("/api/v1/register-config", { ctx: Context, _: () -> Unit =>
            handleRegisterConfigGet(ctx, s)
        })
        .put("/api/v1/register-config/code", { ctx: Context, _: () -> Unit =>
            handleRegisterConfigPut(ctx, s)
        })
        .post("/api/v1/register-config/rotate", { ctx: Context, _: () -> Unit =>
            handleRegisterConfigRotate(ctx, s)
        })
        .get("/api/v1/dept-invite-links", { ctx: Context, _: () -> Unit =>
            handleInviteLinkList(ctx, s)
        })
        .post("/api/v1/dept-invite-links", { ctx: Context, _: () -> Unit =>
            handleInviteLinkCreate(ctx, s)
        })
        .delete("/api/v1/dept-invite-links/:token", { ctx: Context, _: () -> Unit =>
            handleInviteLinkDisable(ctx, s)
        })
        /* 招募链接的公开 JSON 解析（D-16，2026-09-16）：App 用它把 token 换成 dept_id。
         * 免认证 —— 与上面那个 HTML 落地页同源，只暴露部门名与启停状态。 */
        .get("/api/v1/join/:token", { ctx: Context, _: () -> Unit =>
            handleJoinResolve(ctx, s)
        })
        /* Part 4 · 任务（8） */
        .get("/api/v1/tasks/mine", { ctx: Context, _: () -> Unit =>
            handleTasksMine(ctx, s)
        })
        .post("/api/v1/tasks/lookup", { ctx: Context, _: () -> Unit =>
            handleTaskLookup(ctx, s)
        })
        .get("/api/v1/tasks", { ctx: Context, _: () -> Unit =>
            handleTaskList(ctx, s)
        })
        .post("/api/v1/tasks", { ctx: Context, _: () -> Unit =>
            handleTaskCreate(ctx, s)
        })
        .get("/api/v1/tasks/:id", { ctx: Context, _: () -> Unit =>
            handleTaskDetail(ctx, s)
        })
        .patch("/api/v1/tasks/:id", { ctx: Context, _: () -> Unit =>
            handleTaskUpdate(ctx, s)
        })
        .put("/api/v1/tasks/:id/status", { ctx: Context, _: () -> Unit =>
            handleTaskStatus(ctx, s)
        })
        .delete("/api/v1/tasks/:id", { ctx: Context, _: () -> Unit =>
            handleTaskDelete(ctx, s)
        })
        /* Part 5 · 课题（6） */
        .get("/api/v1/plans", { ctx: Context, _: () -> Unit =>
            handlePlanTree(ctx, s)
        })
        .post("/api/v1/plans", { ctx: Context, _: () -> Unit =>
            handlePlanCreate(ctx, s)
        })
        .get("/api/v1/plans/:id", { ctx: Context, _: () -> Unit =>
            handlePlanDetail(ctx, s)
        })
        .patch("/api/v1/plans/:id", { ctx: Context, _: () -> Unit =>
            handlePlanUpdate(ctx, s)
        })
        .post("/api/v1/plans/:id/move", { ctx: Context, _: () -> Unit =>
            handlePlanMove(ctx, s)
        })
        .delete("/api/v1/plans/:id", { ctx: Context, _: () -> Unit =>
            handlePlanDelete(ctx, s)
        })

    /*
     * 统一错误出口：
     *   ApiError → 按错误码表落状态码与 {ok:false,error:{code,message,fields}}
     *   其它异常 → 记日志 + 500 INTERNAL，**不向客户端暴露堆栈**（api-design §1.3）
     */
    let errHandler: Middleware = { ctx: Context, _: () -> Unit =>
        match (ctx.err()) {
            case Some(e: ApiError) => sendError(ctx, e)
            case Some(e) =>
                println("[ERROR] ${ctx.method()} ${ctx.path()} -> ${e.message}")
                sendError(ctx, apiErr("INTERNAL"))
            case None => ()
        }
    }

    /*
     * 中间件顺序说明（P1 M-5）：timeout 原先写在 router.middleware() **之后**，
     * 那是错的位置。轻舟的 use() 按注册顺序串成洋葱，先注册的在**外层**；
     * 而 router 命中路由后是直接 `h(ctx, next)` 调用 handler，我们的 handler 从不调 next()，
     * 因此排在 router 后面的 timeout 中间件**一次都没有被执行过**——
     * 它既没计时，也没机会发 408。
     * 移到 router 之前（外层）才会真正参与：dispatch 前后各计一次时。
     *
     * 即便如此也要说清楚它的能力边界（读 timeout.cj 的实现）：它是"事后软超时"，
     * 只能在 handler 返回后判断是否超时，**无法中断**已经跑起来的同步 handler。
     * 真正的防线是 handler 里不做慢操作；这一层是给将来不留神写出的慢路径兜底。
     *
     * 中间件顺序说明 2（容量基准动作 4）：snapshotFlush 也**必须**在 router 之前。
     *   顺序是「handler 改内存 → finally 解锁 → 本中间件写盘 → dispatch 返回 → ctx.commit() 发响应」。
     *   写盘因此落在锁外（不再阻塞其他请求），又仍然早于响应 ——
     *   「响应 200 ⇒ 数据已落盘」这条语义没有打折，见 store.cj 的 storeSave/flushPending。
     *   它同时兼顾了"没命中路由/没改数据"的请求：此时 pending 为空，flushPending 是空操作。
     *
     * 中间件顺序说明 3（2026-09-17）：bodyLimit 也排在最外层（bodyParser 之前），
     * 理由见 limits.cj 的文件头 —— 框架的 bodyParser"先读后判"，只有前置才挡得住大 body。
     */
    return QingZhouApp()
        .use(requestId())
        .use(logger())
        /* 2026-09-17：bodyLimit 必须排在 bodyParser **之前**（外层）——
         * 框架的 bodyParser 是"先把整个 body 读进内存、再比 maxBytes"，
         * 只有抢在它前面按 Content-Length 拦，大 body 才根本进不了内存。
         * 详见 limits.cj 的文件头注释（含能力边界：chunked 编码时看不出来）。 */
        .use(bodyLimit())
        .use(bodyParser(bodyParserOptions()))
        .use(cors())
        .use(timeout(15000))
        .use(snapshotFlush(s))
        .use(router.middleware())
        .onError(errHandler)
}

func cmdServe(port: UInt16, cfg: MySqlConfig, dir: String): Int64 {
    let loaded = loadOrExitDb(cfg, dir)
    let s = match (loaded) {
        case Some(x) => x
        case None => return 1
    }
    if (presidentCount(s) == 0) {
        println("[WARN] 当前没有任何会长账号，请先执行：club-server init-admin <手机号> <初始密码>")
    }
    let box = HandleBox()
    let app = buildApp(s, box)
    println("社团管理工具 · 服务端 v${APP_VERSION}")
    /*
     * 监听地址必须写出来（2026-09-20，为联调）：
     *   轻舟的 `app.serve(port)` 默认 `bindAddr = "0.0.0.0"`（框架文档明确），
     *   也就是**整个局域网都能连**。原先这里只打 `监听 :8080`，
     *   联调时"队友连不上"的第一反应往往是"服务端是不是只绑了本机"——
     *   把 `0.0.0.0` 打出来 + 给一句怎么让别人连，能省掉一轮排查。
     *   ⚠ 这也意味着**别把这个端口暴露到公网**（明文 HTTP、无任何访问控制）。
     *   ⚠ v0.8 起框架支持 `serve(port, bindAddr: "127.0.0.1")` 只绑本机，
     *     我们的入口暂时没有暴露这个开关；要加的话是 cmdServe 里加一个 `--bind`。
     */
    println("监听 0.0.0.0:${port}（同一局域网内用本机 IP 即可访问；仅本机调试用 127.0.0.1）")
    println("  ${cfg.describe()}  成员 ${s.members.size} 人  课题 ${s.plans.size} 个  任务 ${s.tasks.size} 个")
    let handle = app.serve(port)
    box.handle = Some(handle)
    handle.wait()
    println("服务已停止")
    return 0
}

/*
 * HTTPS 启动。
 *
 * 轻舟的 serveTls(port, certPem, keyPem) 收的是 **PEM 字符串**而不是文件路径，
 * 因此读文件、异常处理都在调用方（见上层 cangjie-upstream\qingzhou-tls-verification.md 第 3 节的责任转移）。
 *
 * ⚠ 绝不静默降级：证书或私钥读不到、解析失败时**直接退出**，
 * 不允许 catch 之后回退到明文 serve()——那会让"HTTPS 没起来"变成静默的明文服务。
 */
func cmdServeTls(port: UInt16, cfg: MySqlConfig, dir: String, certPath: String, keyPath: String): Int64 {
    let loaded = loadOrExitDb(cfg, dir)
    let s = match (loaded) {
        case Some(x) => x
        case None => return 1
    }
    if (presidentCount(s) == 0) {
        println("[WARN] 当前没有任何会长账号，请先执行：club-server init-admin <手机号> <初始密码>")
    }
    if (!exists(certPath)) {
        println("[FATAL] 找不到证书：${certPath}")
        return 1
    }
    if (!exists(keyPath)) {
        println("[FATAL] 找不到私钥：${keyPath}")
        return 1
    }
    var certPem = ""
    var keyPem = ""
    try {
        certPem = String.fromUtf8(File.readFrom(certPath))
        keyPem = String.fromUtf8(File.readFrom(keyPath))
    } catch (e: Exception) {
        println("[FATAL] 证书或私钥读取失败：${e.message}")
        return 1
    }

    let box = HandleBox()
    let app = buildApp(s, box)
    println("社团管理工具 · 服务端 v${APP_VERSION}  (HTTPS)")
    println("监听 0.0.0.0:${port}（同一局域网内用本机 IP 即可访问；仅本机调试用 127.0.0.1）")
    println("  ${cfg.describe()}  成员 ${s.members.size} 人")
    println("证书 ${certPath}")
    println("私钥 ${keyPath}（内容不会写入日志）")

    var handle: ?ServerHandle = None
    try {
        handle = Some(app.serveTls(port, certPem, keyPem))
    } catch (e: Exception) {
        println("[FATAL] TLS 启动失败：${e.message}")
        println("        （PEM 无法解析时框架会抛异常；这里不做任何明文回退）")
        return 1
    }
    match (handle) {
        case Some(h) =>
            box.handle = Some(h)
            h.wait()
        case None => return 1
    }
    println("服务已停止")
    return 0
}

/*
 * 位置参数里的连接槽：第一个形如 `mysql://…` 的元素即 DSN。
 *
 * 允许"省略"（用命名参数或默认值），也允许它出现在端口之前或之后
 * （`serve mysql://… 8080` 与 `serve 8080 mysql://…` 都认）——
 * 这两种顺序在文档与脚本里都出现过，不必强迫用户记哪一种。
 * 返回 (残余位置参数, 提到的 DSN)。
 */
func extractDsn(pos: ArrayList<String>): (ArrayList<String>, String) {
    let rest = ArrayList<String>()
    var dsn = ""
    for (x in pos) {
        if (dsn.size == 0 && (startsWithAscii(x, "mysql://") || startsWithAscii(x, "mariadb://"))) {
            dsn = x
        } else {
            rest.add(x)
        }
    }
    return (rest, dsn)
}

/*
 * 去掉字符串结尾的 '/'（可能连续多个）。
 *
 * 给 `--public-url` 用：用户写 `http://10.194.17.0:8080/` 与不带斜杠应当等价
 * （拼链接时我们自己加 `/join/...`，多一个斜杠就变成 `//join/...`）。
 * 仓颉的字符串没有现成的 trimEnd，就按字节截。
 */
func trimTrailingSlash(u0: String): String {
    var u = u0
    while (u.size > 0) {
        let a = u.toArray()
        if (a[a.size - 1] == UInt8(0x2F)) {
            u = String.fromUtf8(a[0..a.size - 1])
        } else {
            break
        }
    }
    return u
}

/* 从选项表取端口；没给或非法 → 报错。返回 -1 表示报错（已打印原因）。 */
func portOr(flags: HashMap<String, String>, dflt: UInt16): Int64 {
    let s = flagOf(flags, "--port")
    if (s.size == 0) {
        return Int64(dflt)
    }
    let v = try {
        UInt16.parse(s)
    } catch (e: Exception) {
        println("端口不合法: ${s}")
        return -1
    }
    return Int64(v)
}

/* 审计日志目录：--data-dir（默认 data）。业务数据不在文件里，见文件头。 */
func dataDirOf(flags: HashMap<String, String>): String {
    let d = flagOf(flags, "--data-dir")
    if (d.size == 0) {
        return "data"
    }
    return d
}

main(args: Array<String>): Int64 {
    if (args.size == 0) {
        usage()
        return 1
    }
    let cmd = args[0]

    /* test 不走 MySQL 连接（它自己看 DSN 决定是否加做一次往返验证）。 */
    if (cmd == "test") {
        var tDsn = ""
        if (args.size > 1) {
            tDsn = args[1]
        }
        var tCfg: ?MySqlConfig = None
        if (tDsn.size > 0) {
            let c = MySqlConfig()
            try {
                parseDsn(tDsn, c)
                tCfg = Some(c)
            } catch (e: Exception) {
                println("[FATAL] ${e.message}")
                return 1
            }
        }
        return runTests(tCfg)
    }

    /*
     * 先把命名参数摘出来，各子命令只面对"纯位置参数 + 一张选项表"。
     * 不认识的位置参数 / 缺值的选项都在这里明确报错（静默忽略是"以为传了、
     * 其实没传"的来源，见 init-admin 那段注释）。
     */
    var flags = HashMap<String, String>()
    var rest = ArrayList<String>()
    var dsn = ""
    try {
        let parts = splitFlags(Array<String>(args.size - 1, { i => args[i + 1] }))
        flags = parts[0]
        let ex = extractDsn(parts[1])
        rest = ex[0]
        dsn = dsnOrEmpty(ex[1])
    } catch (e: Exception) {
        println("[FATAL] ${e.message}")
        return 1
    }

    if (cmd == "init-admin") {
        if (rest.size < 2) {
            println("用法: club-server init-admin <手机号> <初始密码> [DSN] [--name <姓名> | --name-file <文件>] [连接选项]")
            println("  姓名选项：--name <ASCII 姓名>  或  --name-file <UTF-8 文本文件>")
            println("  ⚠ 中文姓名**只能**走 --name-file —— 中文命令行参数会让程序在 main 之前就崩（API-NOTES 坑 11）")
            println("  两个都不给时，首任会长的姓名是「会长」")
            return 1
        }
        var name = ""
        var nameFile = ""
        for (k in flags.keys()) {
            if (k == "--name") { name = flagOf(flags, k) }
            else if (k == "--name-file") { nameFile = flagOf(flags, k) }
        }
        let bad = unknownFlags(flags, ["--name", "--name-file"])
        if (bad.size > 0) {
            println("不认识的参数：${bad}")
            println("用法: club-server init-admin <手机号> <初始密码> [DSN] [--name <姓名> | --name-file <文件>] [连接选项]")
            return 1
        }
        if (name.size > 0 && nameFile.size > 0) {
            println("--name 与 --name-file 只能给一个（--name 只支持 ASCII，中文请用 --name-file）")
            return 1
        }
        if (nameFile.size > 0) {
            let fromFile = match (readNameFile(nameFile)) {
                case Some(n) => n
                case None => return 1
            }
            name = fromFile
        }
        if (name.size == 0) {
            name = "会长"
        }
        /* 与 HTTP 的 PATCH /members 同口径：姓名非空白即可（见 h_member.cj） */
        if (isBlank(name)) {
            println("姓名不能是空白")
            return 1
        }
        let cfg = try {
            resolveMySqlCfg(dsn, flags)
        } catch (e: Exception) {
            println("[FATAL] ${e.message}")
            return 1
        }
        return cmdInitAdmin(rest[0], rest[1], cfg, dataDirOf(flags), trimAsciiBlank(name))
    }

    if (cmd == "init-ops") {
        if (rest.size < 2) {
            println("用法: club-server init-ops <手机号> <口令> [DSN] [连接选项]")
            println("  创建/重设**运维账号**（角色 ops：除「移交会长」外与会长同权）")
            return 1
        }
        let bad = unknownFlags(flags, [])
        if (bad.size > 0) {
            println("不认识的参数：${bad}")
            println("用法: club-server init-ops <手机号> <口令> [DSN] [连接选项]")
            return 1
        }
        let cfg = try {
            resolveMySqlCfg(dsn, flags)
        } catch (e: Exception) {
            println("[FATAL] ${e.message}")
            return 1
        }
        return cmdInitOps(rest[0], rest[1], cfg, dataDirOf(flags))
    }

    if (cmd == "retire-ops") {
        if (rest.size < 1) {
            println("用法: club-server retire-ops <手机号> [DSN] [连接选项]")
            return 1
        }
        let bad = unknownFlags(flags, [])
        if (bad.size > 0) {
            println("不认识的参数：${bad}")
            println("用法: club-server retire-ops <手机号> [DSN] [连接选项]")
            return 1
        }
        let cfg = try {
            resolveMySqlCfg(dsn, flags)
        } catch (e: Exception) {
            println("[FATAL] ${e.message}")
            return 1
        }
        return cmdRetireOps(rest[0], cfg, dataDirOf(flags))
    }

    if (cmd == "serve" || cmd == "serve-tls") {
        let dflt: UInt16 = if (cmd == "serve") { 8080 } else { 8443 }
        /*
         * AI-1（2026-10-05 修）：原先 serve / serve-tls 的白名单里**漏了 7 个 --ai-* 参数**，
         * 于是照文档配 AI 会让 serve 直接打印"不认识的参数"并以 1 退出 ——
         * 服务起不来，5 个智能接口永远只能返回 source:"fallback"。
         * 两条子命令都要放行（AI 配置与是否 TLS 无关）。
         */
        let extraFlags: Array<String> = if (cmd == "serve") {
            ["--ai-endpoint", "--ai-model", "--ai-key-file", "--ai-ca",
             "--ai-timeout", "--ai-max-concurrent", "--ai-max-tokens", "--ai-insecure-trust-all"]
        } else {
            ["--cert", "--key",
             "--ai-endpoint", "--ai-model", "--ai-key-file", "--ai-ca",
             "--ai-timeout", "--ai-max-concurrent", "--ai-max-tokens", "--ai-insecure-trust-all"]
        }
        let bad = unknownFlags(flags, extraFlags)
        if (bad.size > 0) {
            println("不认识的参数：${bad}")
            println("用法: club-server ${cmd} [端口] [DSN] [连接选项]" +
                if (cmd == "serve") { "" } else { " [--cert <证书> --key <私钥>]" })
            return 1
        }
        var port = Int64(dflt)
        let fp = portOr(flags, dflt)
        if (fp < 0) {
            return 1
        }
        port = fp
        /* 位置参数里还能给一个裸端口（老写法 `serve 8080` 照旧可用）。 */
        if (rest.size > 0) {
            let pp = try {
                Int64(UInt16.parse(rest[0]))
            } catch (e: Exception) {
                /* 位置参数可能是误传的 DSN，不能把其中的口令写进日志。 */
                println("第一个位置参数不是合法端口")
                return 1
            }
            port = pp
        }
        let cfg = try {
            resolveMySqlCfg(dsn, flags)
        } catch (e: Exception) {
            println("[FATAL] ${e.message}")
            return 1
        }
        /* AI 配置：解析 + 校验 + 记入全局（**只在启动时写一次**）。
           未配置不是错误——只是 AI 功能不可用，服务照常起。 */
        let aiOpts = aiOptionsFromFlags(flags)
        setAiOptions(aiOpts)
        println("[AI] ${aiDescribe(aiOpts)}")
        let dir = dataDirOf(flags)
        if (cmd == "serve") {
            if (rest.size > 1) {
                println("存在多余的位置参数（serve 只接受一个端口，后面请用 --x 选项）")
                return 1
            }
            /* 招募链接怎么拼：明文服务用 http（2026-09-22 修 —— 原先硬编码 https，
             * 于是本机联调跑 serve 8080 时，发出去的链接是 https://…:8080，点开必然"无法连接"）。 */
            INVITE_URL_SCHEME = "http"
            INVITE_URL_BASE = trimTrailingSlash(flagOf(flags, "--public-url"))
            return cmdServe(UInt16(port), cfg, dir)
        }
        let certPath = if (flagOf(flags, "--cert").size > 0) { flagOf(flags, "--cert") } else { "certs/cert.pem" }
        let keyPath = if (flagOf(flags, "--key").size > 0) { flagOf(flags, "--key") } else { "certs/key.pem" }
        if (rest.size > 1) {
            println("存在多余的位置参数（serve-tls 的证书/私钥请用 --cert / --key）")
            return 1
        }
        /* HTTPS 服务：链接用 https（与上面同一条理由，只是方向相反）。 */
        INVITE_URL_SCHEME = "https"
        INVITE_URL_BASE = trimTrailingSlash(flagOf(flags, "--public-url"))
        return cmdServeTls(UInt16(port), cfg, dir, certPath, keyPath)
    }

    usage()
    return 1
}

/*
 * 检查选项名是否都认识；返回第一个不认识的（没有则空串）。
 *
 * 为什么要挡：拼错的选项名（`--mysql-hostt`）若被静默忽略，程序会**连到默认库**上
 * 继续跑 —— 那是"以为在操作 A 库、实际在动 B 库"这类最坏的静默错误。
 * extra 是本子命令特有的选项（如 --name / --cert）。
 */
func unknownFlags(flags: HashMap<String, String>, extra: Array<String>): String {
    for (k in flags.keys()) {
        var ok = k == "--mysql-host" || k == "--mysql-port" || k == "--mysql-user" ||
            k == "--mysql-pass" || k == "--mysql-db" || k == "--data-dir" || k == "--port" ||
            k == "--public-url"
        for (x in extra) {
            if (k == x) {
                ok = true
            }
        }
        if (!ok) {
            return k
        }
    }
    return ""
}
