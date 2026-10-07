# 轻舟 v0.7 数据库抽象层 与 MySQL 后端接入（2026-09-19）

> **状态：运维台（admin.exe）2026-09-19 已切、club-server 2026-09-20 也已切** ——
> 前者见 §十，后者见 **§十二**。
> 下面第一~九节是**调研期**的记录，原文保留，便于对照"当时为什么这么判断"。

> **上游变更**：轻舟新增 **数据库抽象层**（`DbBackend` 接口 + `CangDB`/`MySQL` 两个后端 + 工厂），
> `store.cj` / `rbac.cj` **不再直接 `import cangdb`** —— 这正是本项目当年为了绕开"沧海 CangDB
> 1.0.5 与 cjc 1.1.3 不兼容（编译通过、运行超时）"而写 `fw_rbac_store.cj`（文件存储适配）的原因。
> 上游提交：`748022d`（抽象层）· `280895f`（注释）· `780d5de`（**MySQL 后端真实验证通过**）。
>
> **本文只记录"能不能接、接到哪一步、还差什么"**，结论都带实测证据。

---

## 一、结论（先说结果）

| 问题 | 结论 |
| --- | --- |
| 轻舟的 MySQL 后端能下载并入库吗 | ✅ 已入库：内置快照升到 `780d5de`，新增 `db.cj` / `db_cangdb.cj` / `db_factory.cj` / `db_mysql.cj` |
| 升级后现有服务端还能编能跑吗 | ✅ 两个目标都编译通过；**六套测试全绿**（单测 507 / 冒烟 434 / TLS 22 / 契约 33 / 后台 29 / 运维页 65，全 FAIL 0） |
| MySQL 链路能接上吗 | ✅ **实测链路已通**（见 §三）：驱动注册成功、`MySqlBackend` 走到**建连**这一步才失败 |
| 为什么不能现在就宣布"接入完成" | ⚠ **本机没有 MySQL/MariaDB 服务器**，所以只能验证到"连接被拒"；端到端（建表 + RBAC 读写）需要一台可连的服务器 |
| 沧海（CangDB） | 按你的决定**暂时放弃**：`db_cangdb.cj` 依赖 `cangdb.*`，两条构建都把它排除（与上游默认构建口径一致） |

---

## 二、上游新增的东西（架构）

```
业务代码（RbacStore）       ← 我们的 admin 后台走这条
        │  依赖 DbBackend 接口（src/db.cj，零外部依赖，进默认编译）
        ▼
   ┌──────────────────────────────────┐
   │  query / exec / ensureTable / close │
   └──────────────────────────────────┘
        ▲                        ▲
  CangDbBackend            MySqlBackend
  (src/db_cangdb.cj)       (src/db_mysql.cj)
   │ 需 cangdb + libcangdb   │ std.database.sql + 社区驱动（**运行时**按注册名查找）
   │ → 本次排除               │ → **编译期零驱动依赖**
                              └ src/db_factory.cj：openStore(dsn) 按 DSN 选后端
```

关键点：**`db_mysql.cj` 编译期不需要任何驱动**（`DriverManager.getDriver("mysql")` 在运行时查找，
回退 `"mariadb"`）。所以"让服务端编译过 MySQL 后端"这件事本身没有门槛；门槛在**驱动**与**服务器**。

---

## 三、实测证据（本机 2026-09-19）

### 3.1 驱动能编能链（cjc 1.1.3）

内置驱动 [Cangjie-SIG mysql-driver](https://gitcode.com/Cangjie-SIG/mysql-driver)（`mariadb` v2.0.2，
`cjc-version = "1.1.0"`）是**纯仓颉实现**（自己实现 MySQL 协议，不 bind libmysqlclient）。

```powershell
cd server
powershell -NoProfile -ExecutionPolicy Bypass -File .\build-mysql-driver.ps1
# → build\mysql-driver\ 下得到 mariadb.{protocol,connection,cdbc} 的 .cjo + 静态库
```

### 3.2 驱动注册 + MySqlBackend 链路（探针实测）

用一个最小的探针（`db.cj` + `db_mysql.cj` + 探针同包编译，链上驱动）实测输出：

```
=== 1) 驱动注册检查（import 触发注册）===
  [OK] mariadb 驱动已注册
  （mysql 驱动未注册，符合预期：只引入了 SIG mariadb）
=== 2) 构造 MySqlBackend（本机无 MySQL，预期在连接阶段失败）===
  捕获异常: Failed to connect 10061: No connection could be made because the target machine actively refused it.
```

**判读**：报的是**连接被拒**而不是"未注册 mysql/mariadb 驱动" —— 说明
`std.database.sql → DriverManager → mariadb 驱动 → MySqlBackend 建连` 整条链路是通的，
**唯一缺的是一台在 127.0.0.1:3306 上监听的 MySQL**。

### 3.3 途中踩到的三个坑（都已解决，写下来省下次时间）

| 坑 | 现象 | 处置 |
| --- | --- | --- |
| **cjpm 编不动驱动** | `cjpm build` 报 `root package 'mariadb' imports package 'stdx.crypto.digest' ... but it is not added as a dependency in cjpm.toml`（驱动自己的 cjpm.toml 只配了 `bin-dependencies.path-option`，没声明 stdx 包；cjpm 1.1.3 会强校验） | **不走 cjpm**，按子包 `protocol → connection → cdbc` 用 cjc 直编（`build-mysql-driver.ps1` 已封装）。这也是轻舟 `docs/DATABASE.md` 给的备选路径 |
| **`-l` 不能带点** | `-lmariadb.cdbc` 报 `invalid file or directory '.cdbc'`（cjc 按点号拆开了） | 用 **`-l:完整文件名`**（本项目 `build.ps1` 链 stdx 用的就是这个写法） |
| **stdx 子包符号未定义** | 只给 `-L <stdx>` 仍报 `undefined symbol: ...stdx.encoding.url...` | stdx 各子包的 `.a` 要**逐个** `-l:libstdx.*.a` 链上（`build.ps1` 里是 `Get-ChildItem "$Stdx\libstdx*.a" \| % { "-l:$($_.Name)" }`） |

另：驱动编译时会报一批 `interface 'SqlDbType' is deprecated` 警告（它写在旧版 `std.database.sql`
之上），用 `-Woff deprecated` 抑制即可，**不影响链接与运行**。运行时还需要 **OpenSSL 3 动态库**在 PATH 里
（驱动用它做认证哈希）。

---

## 四、把 admin 后台切到 MySQL：还差什么

**现状**：admin 后台的 RBAC 数据层走的是我们的 `server/src/fw_rbac_store.cj`（JSON 文件，
`build\admin\admin-data\rbac.json`），`build.ps1 -Target admin` 把框架的 `store.cj` / `db_*.cj` 排除在外。

**切换要做的事**（按工作量从小到大）：

1. **admin 构建的文件集**（`build.ps1 -Target admin`）
   - 加入框架的 `store.cj` + `db.cj` + `db_mysql.cj`；
   - 排除 `fw_rbac_store.cj`（与框架 `RbacStore` 同名同包，不能并存）；
   - 继续排除 `db_cangdb.cj` / `db_factory.cj`（前者要 cangdb；后者引用 `CangDbBackend`，排除前者的
     话会因未声明标识符而编不过 —— 所以**绕过工厂**，直接 `RbacStore(MySqlBackend(...))`）；
   - 链接驱动：`--import-path`/`-L` 指向 `build\mysql-driver`，加三个 `-l:mariadb.*`。
2. **`server/src/ops/admin_main.cj`**
   - 从 `admin.env` 读 MySQL 连接参数（host/port/user/password/database），构造
     `RbacStore(MySqlBackend(host, port, user, pass, db))`；
   - 缺失的辅助方法要补：框架 `RbacStore` 没有 `usernameTaken()`（我们 `#6` 修复用它区分"重名 vs 落盘失败"），
     可用 `findUserByUsername(username) != None` 等价替代；
   - 我们的 `SeedCreds`（首次启动随机生成 admin/user 口令并写回 `admin.env`，`code-review.md` N-29）
     需要在新路径上重建 —— 框架的 `RbacStore(db)` 不做种子账号。
3. **`admin.env`** 增加 `db_backend` 之类的开关，保留文件后端为默认值（避免没有 MySQL 时后台直接起不来）。
4. **回归**：`tests\admin-check.ps1`（29 项）与 `tests\ops-check.ps1`（65 项）都要能在新后端下跑通 ——
   它们目前断言的是文件后端的行为（含 `rbac.json` 的存在性），需要相应调整。

**结论**：第 1、4 步是"接线 + 改测试"，第 2 步要重建种子口令逻辑。**在拿到一台 MySQL 之前不建议动
默认路径** —— 会把现在全绿的 admin 后台变成无法验证的状态。

---

## 五、想真正跑通，需要的环境

| 项 | 说明 |
| --- | --- |
| MySQL / MariaDB 服务器 | 8.0 或 MariaDB 10.x 均可（上游是用 `mysql:8.0` Docker 验的）。本机**当前没有** |
| 库 | 先建一个空库（如 `club_rbac`），表由 `MySqlBackend.ensureTable()` 自动建（`CREATE TABLE IF NOT EXISTS`） |
| OpenSSL 3 动态库 | `libcrypto-3-x64.dll` 等，运行驱动时需要（本仓库已有来源，见 `build.ps1` 的探测顺序） |
| 驱动产物 | `server\build\mysql-driver\`（跑 `build-mysql-driver.ps1` 生成，**不入库**） |

拿到 MySQL 后，最小验证顺序建议：
1. 用 `build-mysql-driver.ps1` 出驱动产物；
2. 复用本文 §3.2 的探针思路（把 host/port/user/pass/db 换成真实值）——**先确认能建连**；
3. 再按 §四 切 admin 后台，跑 `admin-check.ps1` / `ops-check.ps1`。

---

## 六、附带说明：这次框架升级本身

- 内置快照：`e072980` → **`780d5de`**（`server/third_party/qingzhou/UPSTREAM_COMMIT`）。
- **我们的本地补丁已重打**：上游**仍然没有**修 `context.cj` 里"把短读当 EOF"那个 body 截断 bug
  （新版在 `bodyReadBytes` 同一处，仍是 `if (n < 1024) { loop = false }`），所以
  `server/third_party/qingzhou/PROVENANCE.md`「本地补丁」那一节**依然有效**，升级上游后必须重做。
  （本次重打后已确认文件仍是纯 LF —— 该目录被 `.gitattributes` 标了 `-text`，换行符不能动。）
- `build.ps1` 的两处文件排除清单已按**上游 `build.sh` 的权威口径**扩展为
  `main | unit_tests | manual_runner | store | rbac | db_cangdb | db_mysql | db_factory | jsonx_edge_test`
  （club-server 额外排除 `rbac.cj`、保留我们的 `fw_rbac*` 适配；`db.cj` 接口两边都保留）。
- 上游这次还带了 **SSE 流式响应**（`context.cj` / `httpclient.cj`）与 jsonx 边界测试套件，均已随快照入库。

---

## 七、端到端实测（2026-09-19，本机装了 MariaDB 11.4.13）

本机原本没有数据库，为了让"能不能接入"有个**跑通**的结论，装了一个**便携版 MariaDB**（免管理员、
不注册 Windows 服务、非默认端口）：

```powershell
# 1) 从清华 TUNA 镜像取便携包（90 MB，实测 6.5 秒）
#    https://mirrors.tuna.tsinghua.edu.cn/mariadb/mariadb-11.4.13/winx64-packages/mariadb-11.4.13-winx64.zip
# 2) 解压后初始化数据目录（--service 不给 = 不装服务）
& "$base\bin\mysql_install_db.exe" --datadir="E:\cangjie\mariadb\data" --password="<root 口令>" --port=3307
# 3) 启动（后台）
& "$base\bin\mysqld.exe" --datadir="E:\cangjie\mariadb\data" --port=3307 --console
# 4) 建空库
& "$base\bin\mariadb.exe" -h 127.0.0.1 -P 3307 -u root "-p<root 口令>" -e "CREATE DATABASE IF NOT EXISTS club_rbac CHARACTER SET utf8mb4;"
```

**探针实测输出**（`db.cj` + `db_mysql.cj` + `store.cj` + `security.cj` + 探针同包编译，链上驱动）：

```
=== 1) 驱动注册 ===
  [OK] mariadb 已注册
=== 2) 建连（127.0.0.1:3307 / club_rbac）===
  [OK] 连接已建立
=== 3) RbacStore 建表 + RBAC 读写 ===
  初始 users=2 roles=2 perms=6
  createUser -> id=3
  findUserByUsername -> probe_user roleId=1
  hasPermission -> false
  deleteUser -> true
  此后 users=2
  [OK] 端到端全通
```

**结论**：`轻舟 db_mysql.cj + MariaDB 驱动 + 本机 MariaDB` 这条链路**从建表、灌种子到增删查全部跑通**。
也就是说"接入"在技术上是**已验证可行**的，不是纸上推演。

（顺带印证了上游 `780d5de` 那条修复：`admin` 角色的权限确实是 6 个 —— 它修的是"`1..6` 半开区间
只灌了 5 个"那个 off-by-one。）

---

## 八、⚠ 切到框架自带 `RbacStore` 会**回归 N-29**（公开默认口令），必须先处理

这是本次调研**最重要的发现**，比"能不能接"更要紧。

框架的 `RbacStore(db)` 在**首次打开时自动建表并灌种子**（`third_party/qingzhou/src/store.cj`
的 `ensureSchema()` / `seed()`），而它的种子账号是**写死的公开默认口令**：

```cangjie
// store.cj:104-111
if (db.query("SELECT * FROM users").rowCount() == 0) {
    // admin / admin123，角色 admin
    let adminHash = hashPassword("admin123", "qz2026", 1000)
    db.exec("INSERT INTO users VALUES (1, 'admin', '${adminHash}', 1)")
    // user / user123，角色 user
    let userHash = hashPassword("user123", "qz2026", 1000)
    db.exec("INSERT INTO users VALUES (2, 'user', '${userHash}', 2)")
}
```

而**我们自己在 2026-09-17 修掉的 N-29 正是这件事**（见 `docs/code-review.md` N-29）：

> 运维台默认口令 —— 首次启动改成**随机生成**两个 16 位十六进制口令、只打印一次并写入
> `build\admin\admin.env`；并**别用 `admin123` 这类公开默认值**。

也就是说：**直接切到框架的 `RbacStore(db)`，会把 N-29 原样带回来** —— 而这个后台按框架设计
监听 `0.0.0.0:3000`（`docs/local-deploy.md` §2.7 明确提醒过不要暴露），公开默认口令是实打实的风险。

**切换时必须一并做的事**（建议方案）：

1. 在**我们自己的入口**里判定"这次是不是新库"：构造 `RbacStore(db)` **之前**先查一次
   `users` 表是否为空（或先查库是否存在）；
2. 若是新库 → 构造之后**立即**把 `admin` / `user` 两个账号的口令**覆盖成随机值**
   （生成逻辑直接复用 `fw_rbac_store.cj` 的 `SeedCreds` 那套 16 位十六进制），并写入 `admin.env`；
3. 保留现有的"检测到旧库仍是 `admin123` 时**醒目告警**"那套提示；
4. 把这条写进 `admin-check.ps1` 的断言（"新库首次启动后，用 `admin123` 登录**必须失败**"）——
   否则这个回归下次没人会发现。

> 换句话说：**框架的 DB 抽象层可以放心用，但它的种子账号不能直接用。** 我们的 `fw_rbac_store.cj`
> 里那段随机口令 + 告警的逻辑，迁移时要**原样搬过去**，不能因为"框架自带种子"就丢掉。

---

## 九、更新后的结论

| 问题 | 结论 |
| --- | --- |
| MySQL 后端能入库、能编译、能切换吗 | ✅ 能。已入库（`db.cj`/`db_mysql.cj`/`db_factory.cj`/`db_cangdb.cj`），`build.ps1` 排除清单已对齐上游口径 |
| 驱动呢 | ✅ 已入库（`third_party/mariadb-driver/`）+ `build-mysql-driver.ps1` 一条命令出产物 |
| 端到端能跑通吗 | ✅ **已跑通**（§七）：建表 + 灌种子 + RBAC 增删查全过（本机 MariaDB 11.4.13，端口 3307） |
| 那还差什么 | 把 **admin 后台**切过去：改文件集（§四）+ **处理 §八 的 N-29 回归** + 调整 `admin-check`/`ops-check` 断言 |
| 沧海 CangDB | 按决定放弃；`db_cangdb.cj` 两条构建都排除 |

---

## 十、落地记录：运维台已切到 MySQL（2026-09-19，分支 `feat/admin-mysql`）

§一~九是调研；这一节是**实际做完的改动、验证结果、以及调研期没预见到的一个坑**。

### 10.1 改了什么

| 文件 | 改动 |
| --- | --- |
| `server/build.ps1` | **只动 `-Target admin` 分支**：框架排除清单去掉 `store.cj`（于是 admin 编到框架 `store.cj` + `db_mysql.cj`）；`$app` 去掉 `fw_rbac_store.cj`；新增 `$drvDir = build\mysql-driver` 检查（缺 `mariadb.cdbc.cjo` 就 `throw`，提示先跑 `build-mysql-driver.ps1`）；`cjc` 那次调用按 `$extraImportPath/@extraLibPath/@extraLibs` 三个数组追加驱动参数（这三个数组在 **club-server 分支下为空**，所以没有污染）；`admin.env` 模板从 `db=` 换成 `mysql_host/mysql_port/mysql_user/mysql_pass/mysql_db`（`mysql_port` 生成时会探测 3307 → 本机便携版 MariaDB 直接可用，否则写 3306）|
| `server/src/ops/admin_main.cj` | `RbacStore(MySqlBackend(host, port, user, pass, db))` 取代 `RbacStore(dbPath, creds)`；`dbPath`/`rbacDb` 相关字段与 `opsDirOf()` 删除；新增 N-29 的"新库换口令"（见 10.3）；`usernameTaken()` → `findUserByUsername(...).isSome()`；`/api/club/config` 的 `rbac_db` 换成 `rbac_backend`+`rbac_database`；**`import mariadb.cdbc.*`（见 10.2）** |
| `server/tests/admin-check.ps1` | 断言从"JSON 文件存在/可解析/含 6 个 code"换成"直查 MySQL 的建表与行数"；新增开头 **MySQL 可连性前置检查**（取不到 → 中文提示 + **判失败**）；新增 **N-29 回归闸门**（`admin123`/`user123` 必须被拒）；写路径的用户名带时间戳（库不再每次重建，固定名字会假红）。29 → **38** 项 |
| `server/tests/ops-check.ps1` | 隔离用的 `admin.env` 改写 `mysql_*`（数据层在共享的 MySQL 库里，注释写明"要隔离就换 `mysql_db`"）；夹具改成 `DROP TABLE` 制造"新库"；同样加 MySQL 前置检查与 N-29 闸门；**去掉了 `$adminPw = "admin123"` 的回退值**（那个回退会让闸门形同虚设）。65 → **70** 项 |

**没动的**：`fw_rbac_store.cj` / `fw_rbac.cj`（club-server 仍在用）、`third_party/qingzhou/**`、
`entry/**`；club-server 那条构建的排除清单与产物行为一个字节都没变。

### 10.2 ⚠ 调研期没预见的坑：**必须 import 驱动包，`-l:` 链接不够**

`docs/DATABASE.md` 与 `db_mysql.cj` 的注释都说"import 其 cdbc 包即可（import 触发驱动注册）"。
实际做法容易漏掉"import"这半句：只在链接命令里加 `-l:mariadb.cdbc` 等三个静态库，
编译、链接**全过**，一启动就抛：

```
Exception: 未注册 mysql/mariadb 驱动：请引入 mysqlclient4cj 或 Cangjie-SIG mysql-driver…
```

原因：驱动的注册是 `third_party/mariadb-driver/src/cdbc/driver.cj:23` 那条
**包顶层 `let _ = DriverManager.register("mariadb", MariaDBDriver())`** ——
静态库里没被引用的包，顶层初始化不会执行。而 `db_mysql.cj` 是"运行时按注册名查找"，
它自己**不会** import 任何驱动包，所以这个责任只能落在用它的那一方。

处置：`server/src/ops/admin_main.cj` 顶部加 `import mariadb.cdbc.*`（文件里有长注释说明别删）。
这条 import 只在 admin 构建里成立（只有它带 `--import-path build\mysql-driver`），
club-server 那条既不编这个文件也不链驱动，因此不引入新依赖。

### 10.3 N-29 是怎么保住的

框架 `RbacStore(db)` 的构造会**自动建表并灌种子**，种子口令是写死的 `admin123`/`user123`
（§八）。所以"判定新库"必须发生在**构造之前**，构造之后只能看到已经被灌进去的默认口令哈希：

```cangjie
var freshDb = false
try {
    freshDb = (rbacs.query("SELECT * FROM users").rowCount() == 0)   // 表不存在 → 抛 → 新库
} catch (e: Exception) {
    freshDb = true
}
let store = RbacStore(rbacs)                                          // 这里才建表 + 灌种子
...
if (freshDb) {
    let adminPass = if (adminPassCfg.size > 0) { adminPassCfg } else { randomHex(8) }  // 16 位十六进制
    let userPass  = if (userPassCfg.size  > 0) { userPassCfg  } else { randomHex(8) }
    store.deleteUser(1); store.deleteUser(2)                          // 框架没有"改口令"，只能删了重建
    store.createUser("admin", hashPassword(adminPass, "qz2026", 1000), 1)   // nextUserId = max+1 → 正好补回 1
    store.createUser("user",  hashPassword(userPass,  "qz2026", 1000), 2)   // 与 fw_rbac_store.cj 同盐同轮数
    persistSeedCreds(envPath, adminPass, userPass)                    // 写回 admin.env，只打印一次
```

`randomHex(8)`、`hashPassword(pw, "qz2026", 1000)` 与 `fw_rbac_store.cj` 的 `seed()` 逐字对口径；
`admin_pass`/`user_pass` **已填则优先用填的值**这一条也保留了。
id 必须落回 1/2：`requirePermission` 按数字 userId 判权限、`/admin/shutdown` 要求 `roleId == 1`，
id 错位会让这些闸门全部错位。

顺带修掉一个**真实存在的老毛病**：`persistSeedCreds` 原先是无条件 `File.appendTo`，
而 `Config` 的解析是"后出现的键覆盖先出现的" —— 清库重跑几次之后 `admin.env` 里会堆出
多段 `admin_pass=`，**第一条还是空的/旧值**，照着文件登录就一直失败。
现在改成"逐行重写，遇到 `admin_pass`/`user_pass` 就地替换，没有才补一段"，文件里永远只有一条。

### 10.4 验证结果（本机，MariaDB 11.4.13 @ 127.0.0.1:3307）

| 命令 | 结果 |
| --- | --- |
| `build-mysql-driver.ps1` | 通过（6 个产物） |
| `build.ps1`（club-server） | 通过，32 个框架文件、24 个服务端文件 |
| `build.ps1 -Target admin` | 通过，35 个框架文件（含 store.cj + db_mysql.cj）、7 个 app 文件，链接驱动 |
| `tests/admin-check.ps1` | **PASS 38 / FAIL 0**（含 2 条 N-29 闸门） |
| `tests/ops-check.ps1` | **PASS 70 / FAIL 0**（含 2 条 N-29 闸门） |
| `build\club-server.exe test` | **PASS 507 / FAIL 0**（未回归） |
| `tests/smoke.ps1` | **PASS 434 / FAIL 0**（未回归） |

另外手工验过两条失败路径：**驱动产物目录被挪走**时 admin 构建给出"先跑 build-mysql-driver.ps1"
的明确报错；**MySQL 连不上**时 `admin-check.ps1` 打出 `FAIL MySQL 可连…` 与中文处置提示并
以非零码退出（不静默跳过）。

### 10.5 代价（必须知道）

**`admin-check.ps1` / `ops-check.ps1` 从此需要一台可连的 MySQL。** 这是本次切换的直接代价：
测试不能再用"删掉一个 JSON 文件"来制造干净夹具，也不能只靠 HTTP 断言证明"数据真落到了后端"。
脚本开头会显式探测并按**失败**处理，所以不会把"没测"伪装成"通过"；
但**放一台没有数据库的机器上，这两个脚本会红**，而不是"跳过"。
`ops-check.ps1` 还会 `DROP TABLE` 掉 `admin.env` 里 `mysql_db` 指向的那个库的 4 张 RBAC 表 ——
别拿它跑在与别人共用的库上。

---

## 十一、局域网共用一台 MySQL（队友"只连你的库"方案）

> 需求：队友**不必各自装 MySQL**，只把 `admin.env` 的 `mysql_host` 指向局域网里跑着 MySQL 的那台机器。

### 11.1 结论：可行，已在本机配好

| 前提 | 状态 |
| --- | --- |
| MySQL 监听所有网卡 | ✅ MariaDB 默认就是 `0.0.0.0:3307`（`netstat` 实测） |
| 主机防火墙放行 | ✅ 已有 `mysqld.exe` 入站 Allow（Public profile，本机 WLAN 正是 Public） |
| **允许远程连接的账号** | ⚠ **默认没有** —— `mysql_install_db` 只建 `root@localhost/127.0.0.1/::1`。已新建 `club@10.194.%` |

已执行的授权（**口令见下，请自行更换**）：

```sql
CREATE DATABASE IF NOT EXISTS club_rbac CHARACTER SET utf8mb4;
CREATE USER IF NOT EXISTS 'club'@'10.194.%' IDENTIFIED BY '<REDACTED-本地开发口令>';
GRANT ALL PRIVILEGES ON `club\_rbac%`.* TO 'club'@'10.194.%';   -- 通配：覆盖各人自己的库
FLUSH PRIVILEGES;
```

**验证方式**（重要）：从**局域网 IP** 连（而不是 127.0.0.1）才算真的走了远程路径 ——
源地址变成 `10.194.x.x` 后，`root@localhost/127.0.0.1` **不匹配**，只有 `club@10.194.%` 能进：

```powershell
mariadb -h 10.194.233.104 -P 3307 -u club -p -e "SELECT CURRENT_USER();"
# 实测输出：club@10.194.%
```

### 11.2 队友怎么配（每人三行）

在各自的 `server\build\admin\admin.env` 里改：

```
mysql_host=10.194.233.104          # ← 跑 MySQL 那台机器的局域网 IP（会变，见 11.4）
mysql_port=3307
mysql_user=club
mysql_pass=<向 MySQL 主人索取>
mysql_db=club_rbac_<你的名字>       # ← 关键：用自己的库，别用 club_rbac
```

然后照常跑：

```powershell
cd server
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1 -Target admin
cd build\admin ; .\admin.exe            # 首启会自动建库、建表、灌随机口令并写回你的 admin.env
```

### 11.3 ⚠ 必须"一人一库" —— 否则会互相清库

`admin-check.ps1` / `ops-check.ps1` 会 **`DROP` 掉 `mysql_db` 指向库的那 4 张 RBAC 表**
（用来验证"新库首启"路径）。如果大家都用默认的 `club_rbac`：

- 谁跑一次测试 → **所有人的 admin/user 账号被清空**；
- 更糟的是各人 `admin_pass`/`user_pass` 是**各自随机生成**的，库一被清，
  别人那份口令立刻失效 → **全员被锁在后台外面**。

所以两个脚本里都加了一道**防误伤闸门**（2026-09-19）：解析完 `admin.env` 后，
若 `mysql_db` 恰为共用的 `club_rbac`，则**拒绝执行**并给出中文提示；确实要跑就设
`$env:CLUB_ALLOW_SHARED_DB=1` 显式承担风险。已双向实测：

```
mysql_db=club_rbac          → 拒绝执行 … exit=1
CLUB_ALLOW_SHARED_DB=1      → 放行，PASS 38 / FAIL 0
mysql_db=club_rbac_verify   → 正常 PASS 38 / FAIL 0（且共用库 club_rbac 未被触碰，仍有 2 个账号）
```

### 11.4 ⚠ 两个现实约束

1. **局域网 IP 是 DHCP 的，而且变得很勤**：本项目这一台在 2026-09-18~19 期间从
   `10.194.208.10` → `10.194.250.2` → `10.194.233.104` 变了三次。
   队友填的 `mysql_host` **随时可能失效**。建议：① 让网管给个固定 IP / DHCP 保留；
   ② 或者每轮联调前由 MySQL 主人跑一遍 `(Get-NetIPAddress -AddressFamily IPv4 | ? { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' }).IPAddress`
   把当前 IP 发群里。**注意你的授权是 `club@10.194.%`**：如果 IP 跑出 `10.194.0.0/16`
   （换网段了），这个账号也会失效，需要按新网段重建账号。
2. **安全**：校园网是个很大的共享网段（本机 ARP 表里同时能看到 30+ 台邻居），
   把 MySQL 暴露在上面意味着**同网段的任何人都能尝试连接**。当前用的是
   `club@10.194.%` + 30 位随机口令把面收窄了一些，但这**不等于安全**。
   请：不要把 `root` 开放到远程；只在联调期开着；联调完 `DROP USER 'club'@'10.194.%'`
   或直接停掉 mysqld。**这台便携 MariaDB 只是本机联调用的，不是生产。**

### 11.5 换口令 / 撤销

```powershell
# 换口令
mariadb -h 127.0.0.1 -P 3307 -u root -p -e "ALTER USER 'club'@'10.194.%' IDENTIFIED BY '<新口令>'; FLUSH PRIVILEGES;"
# 撤销远程入口（联调结束后建议执行）
mariadb -h 127.0.0.1 -P 3307 -u root -p -e "DROP USER 'club'@'10.194.%'; FLUSH PRIVILEGES;"
```

---

## 十二、落地记录：club-server 也切到 MySQL（2026-09-20，分支 `feat/club-server-mysql`）

§十 切的是**运维台自己的 RBAC**；这一节是**社团业务库本身**。口径来自
`docs/club-server-mysql-assessment.md` 的**路线 B：只换持久化层**，且是用户明确要求的
（"不采用文件存储"）。

### 12.1 一句话做法

```
启动：MySQL SELECT 9 张表  →  喂给现成的 *FromJson  →  内存 Store（与原来一模一样）
变更：一个事务里只写"这一轮真正变了的东西"（REPLACE 变化的行 + DELETE 删掉的行）
```

**内存模型、7 张 `HashMap`、全部 `*ToJson`/`*FromJson`、所有 handler、`perms.cj`、`views.cj`、
逾期 / 课题树递归 / 时间桶分组 / 部门范围判定 —— 一行未动。** 这是"507 条单测语义不变"的前提。

> ⚠ **落盘是增量的**（第一版写成了"每次 `DELETE` 全表 + 重插全部行"，被基准打回来）：
> `tests/bench.ps1` 实测 1000 成员 + 1000 任务时，**建一个任务要 1511 ms** —— 因为每次提交
> 都要重写几千行，而 club-server 的写入是"请求链末端同步落盘"，这个代价直接变成写接口延迟。
> 改成增量后同一个基准是 **133 ms**（登录 509 ms，本身是 PBKDF2 的固定成本）。
> 语义没变：仍是**一个事务**、仍是**提交后才响应**，只是写集从"全库"缩到"变化量"。
> 做法见 `mysql_store.cj` 的 `PersistedState` / `snapshotOf` / `writeDbToMysql`
> 与 `Store.persisted`（上一次成功落盘的基准）。⚠ **`snapshotOf` 有硬契约：必须在 `s.lock` 内调用** ——
> 正路是 `storeSnapshot` 把值语义拷贝放进 `Snapshot.entities` 带出锁，落盘路径只持 `save_lock`、
> **不要**在那里现读内存表（2026-10-04 修的数据竞争，见 §12.11）。删除必须**显式**发 `DELETE WHERE pk=?` ——
> 这条有专门断言盯着（单测 `testMysqlRoundTrip` 的 ⑥ 段：删内存记录后库里也必须消失）。

### 12.2 表结构（9 张）

7 张业务表与 `store.cj` 的逻辑表**同名**（`departments` / `members` / `plans` / `tasks` /
`invite_links` / `tokens` / `idem`），另有 2 张元数据表（`meta` 整数、`meta_str` 字符串）
装 `next_dept` / `next_member` / `next_plan` / `next_task` / `register_code*` ——
这几个字段在文件版里就是**库级**的，不属于任何一张表，所以单独放，避免"哪一行的副本才是权威"。

列名与类型从 `*ToJson` 的键推导：整数 `BIGINT`、字符串 `TEXT`（**不用 NULL**：结果集是按
String 取值的，业务语义本来就是"空串 = 无"）、`enabled` 用 `TINYINT`。
主键：4 张用 `id`，3 张用各自的字符串键。全部 `CREATE TABLE IF NOT EXISTS`（幂等）。
完整 DDL 是 `server/src/mysql_store.cj` 的 `SCHEMA_DDL`。

### 12.3 四个必须知道的坑（都是实测踩到的）

| 坑 | 现象 | 处置 |
| --- | --- | --- |
| **`sqlEscape` 只做 SQL 标准转义** | 我们复用框架的 `sqlQuote`（只把 `'` 双写），而 MySQL **默认还开着反斜杠转义** → 含 `\` 的姓名/任务描述被吃掉字符；**值以 `\` 结尾时还会把收尾引号转义掉**（SQL 词法跑飞）。写 MySQL 往返单测时被断言当场抓住 | 在**绑定前**再双写一层反斜杠（`mysql_store.cj` 的 `mysqlSafe`，写入路径统一过它）。启动时打印一次服务端 `sql_mode` 状态：若开了 `NO_BACKSLASH_ESCAPES` 会**明说**"会多存一个反斜杠"。这是"框架绑定不完整"的代价，已在原反馈清单记着（清单已随反馈闭环删除） |
| **框架升级后把会话改成 `NO_BACKSLASH_ESCAPES`**（2026-10-02，随轻舟 v0.12.0 快照 `3d6c1a36` 引入）⭐ | 新快照的 `db_mysql.cj` 新增参数 `noBackslashEscapes`，且**默认 `true`** —— 连接后执行 `SET SESSION sql_mode = CONCAT(@@SESSION.sql_mode, ',NO_BACKSLASH_ESCAPES')`。它这么做的理由（让框架的 `''` 转义在 MySQL 与 CangDB 上语义一致）**对不用 CangDB 的我们不成立**；而上面那条的 `mysqlSafe` 是按**默认**口径转义的 → 会话真开了它，转义出的 `\\` 会被**原样**存成两个反斜杠 | 在 `MysqlStore` 建连处**显式传 `noBackslashEscapes: false`**。**不能反过来改 `mysqlSafe`** —— 库里既有数据都是按默认口径写进去的，改口径会让老数据读出来多一个反斜杠。回归闸门是 `club-server test <DSN>` 的 MySQL 往返两条（课题/任务描述含引号+反斜杠）：升级后当场红了 2 条，传 `false` 后 `PASS 561 / FAIL 0`。⚠ **不带 DSN 时这两条会被跳过**，所以只跑 `PASS 510` 是漏网的 |
| **驱动必须 `import`，`-l:` 链接不够** | 与 §10.2 同一条：静态库里没被引用的包，顶层注册不会执行。少了它就到建连才报"未注册 mariadb 驱动" | `server/src/mysql_store.cj` 顶部 `import mariadb.cdbc.*`（有长注释说明别删） |
| **链接驱动必须 `-l:完整文件名`** | `-lmariadb.cdbc` 被 cjc 按点号拆开 → `invalid file or directory '.cdbc'` | `build.ps1` 用 `-l:mariadb.cdbc` 这种写法（§3.3 老坑，这次两条分支都要用） |

### 12.4 接线方式

```powershell
# DSN（推荐）
club-server.exe serve 8080 mysql://user:pass@host:3307/club_server
club-server.exe init-admin 13800000000 <口令> mysql://... --name-file n.txt
club-server.exe serve-tls 8443 mysql://... --cert certs\cert.pem --key certs\key.pem

# 命名参数（没给的项取默认值 127.0.0.1 : 3306 / root / 空口令 / club_server）
club-server.exe serve 8080 --mysql-host 127.0.0.1 --mysql-port 3307 --mysql-user root `
                           --mysql-pass <口令> --mysql-db club_server

# 单测：不给 DSN 就不碰数据库；给了就额外跑一次 MySQL 持久化往返与增量落盘验证
#（2026-10-04 实测：不带 DSN 510 条 / 带 DSN 562 条，差值 52 条是 MySQL 断言；该差值随断言增删会漂移）
club-server.exe test
club-server.exe test "mysql://root:<口令>@127.0.0.1:3307/club_test"
```

- **库与表自动建**（`CREATE DATABASE IF NOT EXISTS` + `CREATE TABLE IF NOT EXISTS`），
  首次连接不需要人工准备 —— 库名只允许 `[A-Za-z0-9_$]`（它会进 DDL，先过白名单）。
- **`--data-dir` 现在只管审计日志**（`audit.log` 仍写文件、不入库 —— 追加写的行日志不属于那 9 张表，
  本次刻意不动它，避免把"谁做了什么"的可追溯性一起改掉）。
- **不支持环境变量配置**：本工具链的仓颉 std 没有 `getEnv` / `envVars`（§十 的框架 `config.cj`
  里核对过）。所以只能走命令行 —— 这一点与"任务书建议从环境变量读"不同，是**做不到**，不是没做。
- **口令绝不进日志/响应**：启动横幅只打 `pass=***`（`MySqlConfig.describe()`）。

### 12.5 「响应 200 ⇒ 已落盘」靠什么保证

中间件顺序没变：`snapshotFlush` 仍挂在 `router` **之前**、`ctx.commit()` **之前**：

```
handler 改内存 → finally 解锁 → snapshotFlush → flushPending → writeSnapshot
   → writeDbToMysql（一个事务：REPLACE 变化行 + DELETE 删掉的行，提交返回）
   → dispatch 返回 → ctx.commit() 发响应
```

所以事务**提交完成之后**响应才写出去 —— 与文件版"写完 `.tmp`→rename 才响应"逐字同构。
序号守卫（`seq` / `saved_seq`）也原样保留：并发写盘收敛到最新快照。
（MySQL 下 `storeSnapshot` **不渲染 `renderDb`** —— 库里没有"整库文本"这个东西；但**锁内仍要取一份快照**：
2026-10-04 起它把内存表**值语义拷贝**进 `Snapshot.entities`（见 §12.11），锁内开销是 O(表大小) 的纯内存拷贝，
DB 往返仍在锁外。文件后端一直是"锁内序列化"。）

### 12.6 运维台的读路径同步改了（同样只换数据源）

`ops/admin_main.cj` 的 `withClub` 原先每请求 `storeLoad(dataDir)` 读 `db.json`；
现在改成连 MySQL（复用 club-server 那份 `storeLoadDb`，两个进程共用**同一套字段映射**，
不可能漂移）。`admin.env` 的新键：

```
mysql_host/mysql_port/mysql_user/mysql_pass   # 与后台 RBAC 共用（同一实例）
mysql_db=club_rbac                            # 后台自己的 RBAC 库
club_mysql_db=club_server                     # ← 新增：**社团库**（club-server 连的那个）
club_data=../data                             # 保留，但现在只表示**审计日志目录**
```

> ⚠ `club_mysql_db` 的默认值是 **`club_server`**（= club-server 的 `MySqlConfig.db` 默认值）。
> 2026-09-20 之前这里写的是 `club`，于是**开箱即错**：运维页一打开就是
> `Unknown database 'club'`。现在报错会把实例上现有的 `club*` 库列出来（实测那个坑已修）。

`/api/club/config` 的键也随之改口径（删掉会撒谎的 `club_db_file`，改给
`club_database` / `club_mysql` / `club_audit_file`）。

⚠ **概览端点也得一起改**（2026-09-20 收尾时补的）：`/api/club/overview` 原先报
`db_file` / `db_exists` / `db_bytes` / `db_mtime`（四个键都指向 `data/db.json`）——
迁到 MySQL 后那个文件**不再产生**，继续报就是撒谎：运维页会永远显示
「库文件 `<…>\db.json` · 0.0 KB · 最后写入 —」，运维看到只会以为"库空了 / 落盘坏了"。
现在改成 **`db_backend`**（`mysql` / `file`），文件侧只保留真正还在写的 **`audit`**
（`file` / `bytes` / `lines`）；库名与 `host:port` 由 `/api/club/config` 给。
`ops/club_view.cj` 的其余视图逻辑一行未动（它拿到的仍是内存 `Store`），
但 `admin-web` 运维页里引用旧键的那几处文案跟着改了，`dist` 也重编了一份。

**「一键备份」改成"从 MySQL 导出 JSON 快照"**（用 `renderDb`，与原 `db.json` 同结构、同一套
`*ToJson`）+ 审计日志副本 —— 备份**产物**是文件，但**存储层仍是 MySQL**。

### 12.7 测试面：四个脚本改为"专用测试库"

`smoke.ps1` / `tls-check.ps1` / `client-contract-check.ps1` / `ops-check.ps1` 原先靠
"一个临时数据目录"隔离，现在各自用**专用测试库**（`club_smoke` / `club_tls` /
`club_contract` / `club_ops_e2e`），开头**显式探测可连性，取不到就判 FAIL + 非零退出**
（不静默跳过）。共用实现抽在 **`server/tests/mysql-common.ps1`**（客户端探测 / 可连性检查 /
清 9 张表 / 统一的中文失败提示），用法是 dot-source。

⚠ 两个 PS 5.1 的坑（都写进 `mysql-common.ps1` 的注释了）：
① **`$ErrorActionPreference='Stop'` 下原生命令写 stderr 会终止脚本**，而 `2>$null` **压不住** ——
必须在 **cmd 层** `2>NUL`；
② 这四个 `.ps1` 是 **BOM + CRLF**，用不支持 BOM 的工具改写会让 PowerShell 按 GBK 解析、
**整份脚本语法错**（本轮真的踩了一次，症状是"第 149 行 Array index expression is missing"）。

### 12.8 验证结果（本机，MariaDB 11.4.13 @ 127.0.0.1:3307）

| 命令 | 结果 |
| --- | --- |
| `build.ps1` | 通过（33 个框架文件 + 25 个服务端文件，链接 MariaDB 驱动） |
| `build.ps1 -Target admin` | 通过（35 个框架文件 + 8 个 app 文件） |
| `club-server.exe test` | **PASS 507 / FAIL 0**（不给 DSN，不碰数据库） |
| `club-server.exe test <DSN>` | **PASS 555 / FAIL 0**（507 + 48 条 MySQL 往返/增量断言） |
| `tests/smoke.ps1` | **PASS 440 / FAIL 0**（含 §27 的 11 条请求体闸门） |
| `tests/tls-check.ps1` | **PASS 23 / FAIL 0** |
| `tests/client-contract-check.ps1` | **PASS 33 / FAIL 0** |
| `tests/admin-check.ps1` | **PASS 38 / FAIL 0**（未受影响） |
| `tests/ops-check.ps1` | **PASS 82 / FAIL 0**（含备份导出与直查库比对 + 概览键口径三条） |
| `tests/init-name-check.ps1` | **PASS 44 / FAIL 0**（改用专用测试库 `club_name_*`；"不能半途建库"改成直查 `information_schema`；§9 盯"不给 DSN 时必须先喊出来"） |
| `tests/bench.ps1`（容量基准，按需） | 1000 成员 + 1000 任务：登陆 507 ms / 列表任务 44 ms / 名录 30 ms / **建任务 124 ms** |

> 上表是**迁移完成后在本机重跑一遍**的实测输出，含 2026-09-20 收尾补的两处：
> ① 运维页概览的键口径改动（`ops-check` 从 79 条涨到 **82** 条）；
> ② `limits.cj` 闸门 ④「非 UTF-8 请求体 → 400 而不是 500」（`smoke` 从 438 条涨到 **440** 条，
> §27.10/§27.11；这条与 MySQL 无关，是同一轮独立复核顺手发现并修掉的，见 `API-NOTES.md` 坑 41）。
> 测试要连库：账号/端口/库名可用 `CLUB_MYSQL_*` 环境变量覆盖，
> 取不到库时脚本**判 FAIL 并非零退出**，不静默跳过。

真数据端到端（`init-admin` → `SELECT` → HTTP 建任务 → `SELECT` → 删掉审计目录后重启仍在）
的原始输出见本次改动的交付报告；结论是**数据只在 MySQL 里**，`db.json` 不再产生。
另有**一份独立复核脚本**（走 HTTP 而不是直接调内部函数）验证了：中文部门名入库后原样读回 ·
增量写让库里的行数 4→5 · 删除部门后回到 4 且那一行确实不在 · 含引号与**结尾反斜杠**的标题
原样往返 · 删掉审计目录后重启数据仍在（15 项全过）。脚本是临时件，不随仓库提交。

### 12.9 代价（必须知道）

1. **club-server 从此需要一台可连的 MySQL** —— "拷 exe + 4 个 DLL + 一个目录就能跑"这条
   最省事的路径失效了。没有数据库时它是**起不来**（有意的：宁可起不来，也不带着空库跑，
   否则下一次落盘会把真实数据整体覆盖）。
2. **编译前要先跑一次 `build-mysql-driver.ps1`**（产物不入库）；`build.ps1` 在缺产物时会
   明确 `throw` 并告诉你去跑它。
3. **多实例仍不安全**：内存 Store 每进程一份、没有失效通知 —— 两个 club-server 写同一个库
   会互相覆盖（这是路线 B 的固有代价，不是 bug）。

### 12.10 ⚠ 2026-10-04 修复（P0）：驱动握手写死 `utf8mb3` → 必须显式 `SET NAMES utf8mb4`

**现象**：库与 9 张表都是 `utf8mb4`，但**连接侧是 `utf8mb3`**，而框架没有字符集开关、全仓也没人发
`SET NAMES`。于是**一个 4 字节 UTF-8 字符（emoji）**就让 INSERT 报 `1366 Incorrect string value`。
后果不是"那一条失败"而是**整库停写**：落盘是**一个事务**，失败即整体回滚，而"已落盘基准"
`s.persisted` 只在提交成功后推进 —— 那条坏数据永远留在内存里、每次落盘都重试、每次都失败。

**实测证据**（2026-10-04，本机 MariaDB 11.4.13 + 本仓库 exe）：

```
建一条标题带 emoji 的任务        → HTTP 500 INTERNAL
紧接着建一条普通 ASCII 任务      → HTTP 500 INTERNAL   ← 已被卡死
再建一条纯中文（3 字节）任务     → HTTP 500 INTERNAL   ← 已被卡死
GET /tasks                      → HTTP 200，内存里 4 条；而库里只有 1 行
```

即"**读装作没事、写全军覆没**"，直到重启（重启会丢掉所有未落盘的写入）。
**触发面不需要认证**：注册时的姓名就是自由文本。

**根因**：
- 驱动握手把连接字符集写死成 **33 = utf8mb3** ——
  `third_party/mariadb-driver/src/protocol/client_handshake_response.cj:156-161` 的 `getDefault()` → `.setCharset(33)`；
- 框架没有字符集参数 —— `third_party/qingzhou/src/db_mysql.cj:40-67` 只在 `noBackslashEscapes` 为真时
  发一句 `SET SESSION sql_mode`；
- 我们的代码此前也没发 `SET NAMES`。

**修法**：`server/src/mysql_store.cj` 建连后**立刻** `db.exec("SET NAMES utf8mb4", Array<DbValue>())`
（驱动与框架快照都被 `MANIFEST.sha256` 锁死、不该改，所以修在我们自己的文件里）；设置失败直接抛出并给出处置提示。

**回归闸门**：MySQL 往返测试里的 4 字节字符断言（`testMysqlRoundTrip`：标题 `"2026 招新🙂"`，并核对字节数为 15）。
把 `SET NAMES` 撤掉，带 DSN 的单测**当场变红**（已双向验证）。⚠ **不给 DSN 时它会被跳过。**
该问题同时作为上游能力缺口记录在案（原反馈清单 C-8；清单已删除）。

### 12.11 同日另两处修复（P1 数据竞争 + 测试脚本的客户端 TLS）

**(a) P1：`snapshotOf` 被挪回锁内（MySQL 落盘路径的数据竞争）**

原先 MySQL 落盘路径在**只持 `s.save_lock`** 时调 `snapshotOf(s)` 遍历 `s.departments` / `s.members` /
`s.plans` / `s.tasks` / …，而 handler 正持 `s.lock` 改同一批 `HashMap` —— 违反本仓库自己定的纪律
（`HashMap` 非线程安全）。后果不只是 UB：**撕裂出来的一行会被 REPLACE 回库，并被记成新的"已落盘基准"**，
之后不再有写入去纠正它，等于把不一致持久化下来。

**修法**：`storeSnapshot`（契约：调用方已持 `s.lock`）在锁内把内存表**值语义拷贝**进新增的
`Snapshot.entities`；`writeSnapshot` 把它交给 `writeDbToMysql(s, cur)`，**DB 往返仍在 `s.lock` 之外**
（只由 `save_lock` 串行）。`snapshotOf` 保留（启动期 `storeLoadDb` 建基准；单测自造 `Snapshot` 的兜底分支），
但**不许在只持 `save_lock` 的地方调用**。

> ⚠ **没有**改成"刷盘时再加 `s.lock`"：那会造成 `save_lock → s.lock` 与既有 `storeSave`
> （`s.lock → save_lock`）的**锁序反转**（仓颉重复加锁是挂住而非抛错）。

**代价（有意接受）**：每次提交多一次 O(表大小) 的**纯内存**拷贝 —— 文件后端本来就在锁内序列化，
所以这是"与文件后端逐字同构"。§12.5 那句"锁内只自增一个序号"遂按此修正。

**(b) `tests/mysql-common.ps1`（及 `tests/admin-check.ps1`、`tests/ops-check.ps1` 各自的客户端参数副本）
默认加 `--skip-ssl`，且连接失败时不再吞掉客户端 stderr**

**现象**：某些 Windows 环境下客户端 TLS/SSPI 握手失败
（`ERROR 2026 (HY000): TLS/SSL error: no credentials. Error 0x8009030E(SEC_E_NO_CREDENTIALS)`），
而**库完全可达**（同口令加 `--skip-ssl` 立刻连上）。更糟的是原先把客户端 stderr 丢了，只剩一句
"连不上 / 口令不对" —— **7 个依赖 MySQL 的套件全部中止在夹具阶段**，方向常常是错的。

**处置**：默认加 `--skip-ssl`；需要真实 TLS 的机器设 `$env:CLUB_MYSQL_USE_SSL=1` 退回原行为。
连接失败时**保留并打印客户端原始报错**，并明确提示"这是客户端 TLS/握手问题，不是口令问题"。

**(c) 复核补记（2026-10-04 深夜）：本节 (a)(b) 与 §12.10 的代码改动**此前并不在本检出里**，已按本节描述重做**

复核 HEAD `72b2b89` 时发现：上面三处**代码**改动在工作区与**全部 git 历史**里都不存在 ——

- `git log --all -S "SET NAMES"` 与 `-S "entities"` **只命中文档**（README / `API-NOTES` 坑 44 / 本节），
  没有任何一条提交改过 `mysql_store.cj` 或 `store_persistence.cj` 的这两处；
- `mysql_store.cj` 从未出现过 `SET NAMES`；`Snapshot` 从未有过 `entities` 字段；
  `writeDbToMysql` 一直是**单参**、且在只持 `save_lock` 的地方调 `snapshotOf(s)`
  —— 正是本节 (a) 描述的**修复前**形态；
- `store_persistence.cj` 自 `15d7015`（2026-09-30，538 行）起内容**一直没变**（blob `55c99796`）。

也就是说：**本节文字进了仓（提交 `c82e72e` 引入 README 那行"已修"），而对应的三处改动只存在于当时做它的那份工作副本里，从未提交** —— 因此它在这份检出里从来就不存在，不是"后来被谁删了"。

**处置（本次）**：按本节文字原样重做三处，并**补了一条不需要 DSN 的契约断言**：

| 项 | 落点 | 复验 |
| --- | --- | --- |
| ① 字符集 P0 | `mysql_store.cj` 构造里 `SET NAMES utf8mb4`（失败即抛）+ `tests.cj` 的 4 字节断言 | 编译通过；`SET NAMES utf8mb4` 已进产物 |
| ② S-2 落盘竞争 | `Snapshot.entities` + `storeSnapshot` 锁内值语义拷贝 + `writeDbToMysql(s, cur)` | 编译通过 |
| ③ 客户端参数 | `mysql-common.ps1`（+ `ops-check` / `admin-check` 私有副本）：默认 `--skip-ssl`、stderr 落临时文件并原样打印 | 假客户端实测：stdout 仍干净、stderr 留住 |

本机复验：`build.ps1` 与 `build.ps1 -Target admin` **均编译通过**；`club-server.exe test`（不给 DSN）**PASS 512 / FAIL 0**
（510 基线 + 新增 2 条"文件后端的快照不带 entities"断言）。

> ⚠ **带 DSN 的那两条闸门这次没能在本机跑**：这台机器没有 MariaDB 服务端（`mysqld`/客户端都不在），
> 从镜像取二进制包又被拦（403）。请在**能连库的机器**上补跑
> `club-server.exe test "<DSN>"`，并核对 emoji 那条断言通过；届时 §12.12 里"带 DSN 562"
> 应更新为实际数字（新增 3 条断言后约 **565**）。

### 12.12 2026-10-04 复测结果（含上面三处修复）

| 命令 | 结果 |
| --- | --- |
| `club-server.exe test`（不给 DSN） | **PASS 510 / FAIL 0** |
| `club-server.exe test <DSN>` | **PASS 562 / FAIL 0** |
| `tests/smoke.ps1` | **PASS 440 / FAIL 0** |
| `tests/client-contract-check.ps1` | **PASS 33 / FAIL 0** |
| `tests/init-name-check.ps1` | **PASS 45 / FAIL 0** |
| `tests/admin-check.ps1` | **PASS 38 / FAIL 0** |
| `tests/ops-check.ps1` | **PASS 82 / FAIL 0** |
| `web-logic-check.mjs` | **PASS 17 / FAIL 0** |
| `tests/tls-check.ps1` | **PASS 4 / FAIL 3** |

> ⚠ `tls-check` 的 3 条 FAIL 是**预先存在的环境问题**（`server/certs` 未入库，本机副本是 2026-09-17 的；
> 用改动前的二进制复现同一结果），**不是本轮的回归，也不要按"全绿"读**。§12.8 里的 23 / 0 是
> 2026-09-20 那一轮的记录。
