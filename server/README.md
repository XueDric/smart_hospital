# 智慧医院服务端（仓颉 + 轻舟）

> **当前进度**：P0（号源/挂号域独立 MySQL 路径）→ **P1**（令牌鉴权 + HTTPS + 安全加固 + 内存 Store）
> → **P2**（AI 分诊 + 预问诊 SSE）**均已完成**。P3 / P4 见 [../README.md](../README.md) 的里程碑表。
>
> ⚠ 本行原写「P0 阶段交付」，**已过时**（第六份复查第 2 条指出：新读者照旧文会得出
> 与现状完全相反的结论）。与 §六 同一处置 —— **标题行也要跟着改**，不能只改列表。
>
> 架构决策见 [../docs/adr/ADR-0001-号源与挂号独立MySQL路径.md](../docs/adr/ADR-0001-号源与挂号独立MySQL路径.md)。

---

## 一、环境事实（本机实测）

| 项 | 值 | 说明 |
| --- | --- | --- |
| 编译器 | **cjc 1.2.0** | `C:\Users\ASUS\.cjenv\sdks\1.2.0\cangjie` |
| ⚠ PATH 上的 cjc | **1.1.3**（`D:\Cangjie`） | **是旧版、不可用**。版本串台症状 = 编译中途 `LLVM ERROR: Broken module found` |
| stdx | **1.1.3.1 静态** | `E:\cangjie\stdx\windows_x86_64_cjnative\static\stdx` |
| 数据库 | **仓库自管 MariaDB 11.4.13** @ `127.0.0.1:3317` | `server\devdb`（见 [../docs/DEV-DB.md](../docs/DEV-DB.md)）；启停 `.\devdb.ps1 start` |
| 业务库 / 账号 | `hospital`（开发）/ `hospital_test`（**测试**，`accept` 只认它）/ 账号 `hospital` 口令 `hospital_dev_2026` | ⚠ 开发口令，**上生产必须换** |
| Shell | **Windows PowerShell 5.1** | ⚠ 含中文的 `.ps1` **必须 UTF-8 with BOM**，否则 PS 5.1 按 ANSI 解析会**语法报错** |

> `build.ps1` 会**按版本挑 1.2.0**，不盲信 PATH —— 这一点很重要，见上表第 2 行。

---

## 二、构建

```powershell
cd server
.\build.ps1
```

首次构建前需先生成 MariaDB 驱动产物（**只做一次**）：

```powershell
cd server
.\build-mysql-driver.ps1 `
  -CangjieHome 'C:\Users\ASUS\.cjenv\sdks\1.2.0\cangjie' `
  -Stdx 'E:\cangjie\stdx\windows_x86_64_cjnative\static\stdx'
```

产物：`build\hospital-server.exe` + 运行时依赖 4 个 DLL（`setup-runtime.ps1` 负责就位）
+ `build\SOURCE-MANIFEST.sha256`（验收锚点）。

### 为什么不用 cjpm

驱动自己的 `cjpm.toml` 没声明 stdx 包，`cjpm build` 会强校验并报
`imports package 'stdx.crypto.digest' ... not added as a dependency`。
基线已踩过此坑（见 `baseline/docs/mysql-backend.md` §3.3），故沿用 **cjc 直编、框架与业务同一次调用、同一个包**。

---

## 三、运行

```powershell
cd server     # ⚠ cwd 必须是 server/，见下
.\build\hospital-server.exe selftest
.\build\hospital-server.exe authtest
.\build\hospital-server.exe check-db "mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital_test"
.\build\hospital-server.exe accept   "mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital_test"

# 建第一个管理员（引导入口，不经 HTTP；口令只打印一次）
.\build\hospital-server.exe create-admin "mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital_test"

# P1：启动 HTTP 服务（阻塞）—— 默认只绑 127.0.0.1
.\build\hospital-server.exe serve "mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital_test" --port 8091
```

| 子命令 | 作用 | 需要 MySQL |
| --- | --- | --- |
| `selftest` | schema 与 ADR 不变量的**纯本地**自检（**36 项**断言） | ❌ |
| `triagetest` | P2 分诊 + 预问诊**纯逻辑**自检（**108 项**断言），不碰库不调模型 | ❌ |
| `authtest` | **口令/令牌原语自检**（含 3 个公开测试向量，**17 项**） | ❌ |
| `check-db <dsn>` | 连库 + 幂等建表 + 打印表清单（★ 标记号源域） | ✅ |
| `accept <dsn>` | 验收测试 AC-1…AC-P2-6（**118 项断言**；⚠ 只允许库名含 `test` 的测试库） | ✅ |
| `create-db <dsn>` | 幂等建库（utf8mb4）—— 测试库靠它 | ✅ |
| `create-admin <dsn>` | 建/重置管理员并打印口令（**引导入口**） | ✅ |
| `serve <dsn>` | **P1**：启动 HTTP / HTTPS 服务（默认只绑 `127.0.0.1`） | ✅ |

⚠ `accept` **会清空业务表**，已内置库名守卫（库名不含 `test` 且不等于 `hospital` 时中止）。
⚠ `serve` 的 `--dev-auth` 是**开发态身份头**，绕过全部认证；与 `--prod` 同传会拒绝启动。
⚠ `serve` 启动时**先跑 `authtest` 再连库** —— PBKDF2 错了就没必要连库。

### HTTPS

```powershell
# 生成带 SAN 的自签证书（本机所有 IP + localhost + 127.0.0.1 + ::1）
.\new-tls-cert.ps1

# 启动 HTTPS（用脚本产出的纯 ASCII 运行副本 —— 原因见下）
.\build\hospital-server.exe serve <dsn> --port 8443 --tls-files "C:\ProgramData\smart-hospital\tls\tls.env"
```

| 参数 | 说明 |
| --- | --- |
| `--tls-cert <pem>` / `--tls-key <pem>` | 直接给 PEM 路径 |
| `--tls-files <env>` | 从文件读 cert/key 路径（每行 `key=value`，`#` 注释） |

**绝不静默降级**（四条都已实测）：证书/私钥缺失 → FATAL 退出；PEM 非法 → FATAL 退出；
只给一半参数 → 拒绝启动。这些情况下**端口不会被误起成明文服务**。

> ⚠ **本仓库路径含中文，证书路径必须走 ASCII 运行副本**：
> 本工具链的仓颉运行时无法接受含非 ASCII 的 argv（在 `main` 之前就抛
> `Invalid unicode scalar value`）。`new-tls-cert.ps1` 会自动把证书复制到
> `%ProgramData%\smart-hospital\tls`（ACL 已收紧）并生成 `tls.env`。
> 试过但**不可行**的两条路：`--tls-files` 指向中文路径的配置文件、Windows 8.3 短名（本卷已禁用）。

### P1 接口

| 方法 | 路径 | 权限 |
| --- | --- | --- |
| GET | `/health` | 无 |
| POST | `/api/v1/auth/login` | 无（换令牌） |
| POST | `/api/v1/auth/logout` | 需令牌 |
| GET | `/api/v1/auth/me` | 需令牌 |
| GET | `/api/v1/schedules/:id` | 三端可读 |
| POST | `/api/v1/appointments` | 仅患者 |
| POST | `/api/v1/appointments/:id/cancel` | 患者退自己的 / 管理员退任意 |
| POST | `/api/v1/admin/schedules` | 仅管理员 |
| POST | `/api/v1/admin/users` | 仅管理员 |
| GET | `/api/v1/admin/users?login_name=` | 仅管理员（只回非敏感字段） |
| POST | `/api/v1/admin/users/:id/password` | 仅管理员（**同时吊销该账号全部令牌**） |

**鉴权**：`Authorization: Bearer <token>`。令牌 32 字节随机（64 hex），有效期 30 天、
滑动续期（每天最多写一次）。**有状态**（服务端存 token → user）⇒ 停用/改口令可立即踢下线。

联调备用：`--dev-auth` 开启后可用 `X-Role: patient|doctor|admin` + `X-Patient-Id: <id>`；
**未开启时这些头被忽略并返回 401**（有测试钉住）。

### 自动化测试脚本

```powershell
# 令牌鉴权端到端（登录/权限/登出/改口令踢下线/防枚举计时）
.\tests\auth-check.ps1     -Base http://127.0.0.1:8091 -AdminPw <管理员口令>

# 多进程并发压测（走令牌；默认不用 --dev-auth）
.\tests\stress-booking.ps1 -Base http://127.0.0.1:8091 -Tokens 50 -ScheduleTotal 10 -AdminPw <管理员口令>

# TLS/HTTPS 验证（SslStream 真校验；需 HTTPS 已启动）
$env:HOSP_ADMIN_PW = "<管理员口令>"
.\tests\tls-check.ps1      -Cert "C:\ProgramData\smart-hospital\tls\cert.pem" -Port 8443

# 登录限流 / 失败锁定（9 节，含"归一变体不得绕过锁定"）
.\tests\rate-limit-check.ps1 -Base http://127.0.0.1:8091 -AdminPw <管理员口令>

# P1 收尾 4 项：口令强度 / 会话按设备 / 我的挂号 / 排班列表
.\tests\p1-extra-check.ps1   -Base http://127.0.0.1:8091 -AdminPw <管理员口令>

# P2 预问诊 HTTP / SSE（流式帧格式 + 多轮状态机 + 会话隔离）
.\tests\previsit-check.ps1    -Base http://127.0.0.1:8091 -AdminPw <管理员口令>

# 文档数字对账（防"文档与实测漂移"；-Fix 自动改写）
.\tests\doc-counts.ps1
```

三个脚本**互不依赖执行顺序**（自建夹具、自清数据）。
> ⚠ 必须用 `curl -K` config 文件传 header/body —— `Start-Process -ArgumentList` 会拆坏
> 含空格的参数（详见 [../docs/P1-HANDOFF.md](../docs/P1-HANDOFF.md) §3.3）。
> ⚠ `tls-check.ps1` **不用** `curl --cacert` 做主校验：Windows 的 Schannel 对自签证书的
> `--cacert` 支持不完整（实测 `schannel: error 0x00000010`，而同刻 `curl -k` 是 200），
> 所以它走 .NET `SslStream` + 显式链校验 + 自解析 SAN。理由与两个坑写在脚本头注释里。

### 验收依据：源码哈希，不是产物哈希

cjc 的产物**不逐字节可复现**（实测：同一份源码连续两次构建，exe 的 SHA256 不同，行为一致）。
所以 `build.ps1` 每次构建都会重写 **`build/SOURCE-MANIFEST.sha256`**（45 个参与编译源文件的
SHA256 + cjc 版本 + stdx 路径 + 驱动产物哈希）—— 它的哈希是**稳定**的。
**验收请比 `SOURCE-MANIFEST.sha256` + 测试结果，不要比 exe 哈希。**

---

## 四、P0 已交付内容

| 文件 | 职责 |
| --- | --- |
| `src/schema.cj` | 最小表集 DDL（9 张：6 业务 + 3 鉴权）+ 范围锁死 + 幂等迁移 |
| `src/mem_store.cj` | **内存 Store 范式**（配套域：department/doctor/patient/medical_record）—— 一次事务整体替换 `MEM_TABLES` |
| `src/sql_recorder.cj` | `DbBackend` 录制装饰器（**测试工具**）：录下实际发出的 SQL，供 AC-4 断言"没碰号源域" |
| `src/domain_booking.cj` | ★ 号源/挂号域：原子扣减、幂等、取消归还（三态 `CancelOutcome`）、`visit_date` 快照 |
| `src/auth_crypto.cj` | PBKDF2-HMAC-SHA256（100k）+ 令牌原语 + **3 个公开测试向量自检** |
| `src/auth_repo.cj` | 鉴权仓储：账号、按登录名查、登录（防枚举）、令牌签发/校验/续期/吊销 |
| `src/db_bootstrap.cj` | MySQL 建连 + `SET NAMES utf8mb4` + DSN 解析 + 驱动注册 |
| `src/http_common.cj` | 统一响应/错误码表（`{ok,data}` / `{ok:false,error}`） |
| `src/http_app.cj` | HTTP 装配 + 三端权限矩阵 + `principalOf()`（令牌优先，开发态头可选）+ **登录限流闸门** + **会话/列表端点** |
| `src/auth_repo.cj` | 鉴权仓储：**口令强度校验（仓储层强制）** + 登录名归一 + 限流计数 + 会话按设备 |
| `src/acceptance.cj` | AC-1…AC-P2-6 验收测试（含异常兜底与变异测试记录） |
| `src/acceptance_triage.cj` | AC-P2-1…AC-P2-5：分诊**验证层** + 预问诊**会话隔离**在库级成立（含变异测试记录） |
| `src/previsit.cj` | **P2 预问诊**：多轮采集状态机 + SSE 帧 + 结构化问诊单（业务值，非流式） |
| `src/main.cj` | 进程入口与子命令分发（含 TLS 分支与 fail-closed） |
| `new-tls-cert.ps1` | 生成带 SAN 的自签证书 + ASCII 运行副本 + ACL 收紧 |
| `tests/tls-check.ps1` | TLS 验证（SslStream 真校验、反向验证、HTTPS 业务链路） |

**最小表集（8 张）**：

| 表 | 层 | 数据访问 |
| --- | --- | --- |
| `schedule` | 号源域 · **业务状态** | 直接 SQL |
| `appointment` | 挂号域 · **业务状态** | 直接 SQL |
| `auth_user` `auth_token` | **鉴权域** | 直接 SQL（仅 `AuthRepo` 写） |
| `department` `doctor` `patient` `medical_record` | 业务 | 内存 Store 范式（P1+ 落地） |

> ⚠ `auth_token` **刻意不叫** `tokens`：基线内存 Store 已占用该表名
> （`mysql_store.cj:891`），列定义也不同。
> 现「本侧 8 张表 ∩ 基线 10 张表 = ∅」，由 `selftest` + AC-4 钉住，
> 并额外断言"表集里没有任何以 `idem` 命名的表"（防止已删除的死代码被复活）。
>
> 📌 本表集曾含一张 `booking_idem`（幂等登记），**2026-10-07 连同实现与 AC-8 删除**
> —— 幂等已由 `(patient_id, client_token)` 唯一索引完整保证，那张表从未进入生产路径。
> 见 [../docs/adr/ADR-0001](../docs/adr/ADR-0001-号源与挂号独立MySQL路径.md) rev.4 §7 第 7 条。

---

## 五、P0 踩过的坑（都已解决，写下来省下次时间）

1. **PS 5.1 + 无 BOM 的中文 `.ps1`** → 脚本语法报错（不是编码乱码那么轻）。
   处置：**所有含中文的 `.ps1` 存成 UTF-8 with BOM**（本目录 `build.ps1`、`build-mysql-driver.ps1` 已带 BOM）。
2. **PATH 上的 cjc 是 1.1.3**，`CANGJIE_HOME` 也可能被 cjenv 改写成旧版。
   处置：`build.ps1` 按 **版本号**挑 1.2.0，而不是按位置。
3. **`exec()` 返回的是受影响行数，不是自增 id**。
   把 `INSERT` 的返回值当 id 用 → 所有新单 id 都是 1 → AC-3/AC-6 **假通过/查询错行**。
   处置：INSERT 后紧跟 `SELECT LAST_INSERT_ID()`。**这坑是验收测试抓出来的。**
4. **驱动必须在被编译的文件里 `import` 才会注册**（仅 `-l:` 链接不够）。
   处置：`db_bootstrap.cj` 顶层 `import mariadb.cdbc.*`。
5. **仓颉闭包不能捕获外部可变 `var`**，甚至**传递性**捕获也不行
   （`lambda captured a mutable variable transitively, lambda cannot be used as a param`）。
   处置：结果装在 class 的 `var` 字段里回传（`TxResult`、`TestRunner`）。
6. **`match` 的分支体是单表达式**，不能写多语句块。
   处置：多语句分支改用 `if` 链。
7. **没有 `String.substring`**，用范围切片 `s[a..b]` / `s[n..]`。
8. **`indexOf` / `lastIndexOf` 返回 `?Int64`**（不是 -1 哨兵），要与 `Int64` 比较必须先 `isNone()`/`getOrThrow()`。
9. **`Int64.parse` 需要 `import std.convert.*`**。
10. **`SET NAMES utf8mb4` 不能省**：驱动握手把会话字符集写死成 utf8mb3，
    一个 emoji 就会让之后**所有写入持续 500** 直到重启（基线 API-NOTES 坑 44）。
11. **OpenSSL 3 DLL 必须与 exe 同目录**，否则运行时 `CryptoException: Can not load openssl library`。
    处置：`setup-runtime.ps1`。
12. **`SELECT LAST_INSERT_ID()` 与 MySQL `AUTO_INCREMENT` 起点**：清表用 `DELETE` 不重置自增，
    所以测试用**显式 id**，避免依赖自增序列。
13. **`cancel()` 不能用 `Bool` 表达结果**：把"单子取消了"与"号还回去了"压进一个 bool，
    必然丢掉"单已取消但号未归还"这一真实中间态，于是对外**报错方向与事实相反**
    （已改为三态 `CancelOutcome`，AC-7 钉住）。
14. **产物哈希不能当验收依据**：cjc 输出不逐字节可复现；用 `SOURCE-MANIFEST.sha256` + 测试。
16. **`Start-Process -ArgumentList` 会拆坏含空格的参数**：`"X-Role: patient"` 到达 curl 变成
    `"X-Role:"` → 每个请求 401，压测显示"0 成功"，**看起来像服务端拒绝并发**。
    处置：header/body 走 curl **config 文件**（`-K`），命令行只剩无空格路径。
17. **curl config 里反斜杠是转义符**：`@C:\Users\...` 被读成 `C:Users...` → 路径写**正斜杠**。
18. **PowerShell 反引号转义在数组拼接里原样写入**：JSON 变成非法串（`400 Invalid JSON`）。
    处置：body 写**独立文件**，config 用 `data = "@文件"`。
19. **`std.env` 没有 `getEnv`**：本工具链仓颉 std 不提供读环境变量
    （框架 `config.cj:17-21` 逐字核对过）。所以任何"用环境变量做开关"的设计都会
    **静默永不生效** —— 改用命令行开关（`--prod`）。
20. **乐观锁重试预算不足会「少卖」**：`MAX_BOOKING_RETRY=2` 在 20 并发抢 8 号时只卖出 6 个
    （剩 2 个号没人抢到）。失败方向是少卖而非超卖，但仍是缺陷 —— 已升到 3 +
    HTTP 层用 6。**别靠无限加重试解决高并发**，那是把失败换成延迟。

---

### ★ 追加 A–I（2026-10-07 P1 收尾时又踩到 / 新踩到的）

> ⚠ 用**字母**编号而不是接着上面的数字：两段是不同时间记的，数字接续容易在增删时错位。

| # | 坑 | 现象 | 处置 |
| --- | --- | --- | --- |
| A | **`cjc` 报 `undeclared identifier` 时，先怀疑"是不是方法写成了自由函数"** | `trimAscii(raw)` 报未声明 —— 而 `raw.trimAscii()` 正常。错误信息**不提示"你可能漏了接收者"** | 改成 `raw.trimAscii()`。排查时白试了几轮 import（`std.convert` / `std.collection`） |
| B | **仓颉没有全局提升（no hoisting）** | 把 `deviceOf` / `MEM_TABLES` 定义在**使用之后** → 直接报未声明 | 定义移到使用之前。⚠ 这条已记过一次，本次又犯 —— 写新函数时**先放前面** |
| C | **enum 不能 `!=`** | `p.role != Role.Patient` → `invalid binary operator '!=' on type 'Enum-Role' and 'Enum-Role'` | 用 `match`，或比 `roleName()`。⚠ 本项目**第四次**踩到，务必一次记住 |
| D | **`s.toArray()` 给 UInt8，`r'-'` 是 Rune，不能直接比** | `a[i] != r'-'` → 类型不匹配 | 统一 `Int64(a[i])` 与 ASCII 码比（`0x2D` = `-`） |
| E | **`cjc` 报 `generics type arguments do not match the constraint`** | 想写泛型 `sortedKeys<K,V>(m: HashMap<K,V>) where K <: Comparable<K>` —— `HashMap` 的类型参数带约束，接不上 | 退成"收 ArrayList 再排序"的具化写法 |
| F | **`Array<T>` 没有 `sort()`** | `arr.sort()` → `'sort' is not a member of struct 'Array<Int64>'`；也找不到可用的 `std.sort` | 自己写插入排序（只需"确定顺序"，量级几十~几百） |
| G | **跨行 `&&` / `+` 串联触发 `possibly confusing line terminator`** | 仓颉把行尾当语句终结符候选 | 拆行写，或把运算符留在行尾 |
| H | **`build.ps1` 看不到完整编译诊断** | 它只抛 `编译失败 (exit N)`，没有文件:行:列 | 直接调 `cjc`（带 `--import-path` / `-L` / `-l:` 那一串）才能拿到全部错误与 `==> 文件:行:列`。**排查编译错时优先这么做** |
| L | ★★ **仓颉 `String` 的下标/切片/`indexOf` 都是「字节」语义，不是字符** | P2 里连踩三次：① 按字节截断主诉 → 超长中文直接 **500**；② `"没有胸痛".indexOf("胸痛")` = **6**（不是 2），否定窗口算错 ⇒ **误报红牌**；③ 逐字节拼回字符串撕裂汉字 ⇒ `Invalid utf8 byte sequence` | 只有 `runes()` 是字符语义。**要按字符就全程 `runes()` + `String(Rune[])`**；要按字节就别混用字符单位 |
| M | **断言"没有 X"时，要让 X 真的存在过** | P2 变异测试：把 `remain_num > 0` 改成 `>= 0`（约满也推荐），**92 项断言全绿** —— 因为用例造的是"科室没有排班行"，诱惑源根本不在 | 改造成"排班存在但 `remain_num = 0`"后变异立刻 **2 FAIL**。否则测试验的是"列表是空的"，而不是"不该出现的项没出现" |
| S | **字符串字面量里不能嵌 ASCII 双引号** | 中文文案里写「写"无"」时用了 ASCII 引号，而它同时是**字符串定界符** ⇒ 报 `unclosed delimiter: '('`（且错误位置指向别处，很难查） | 中文文案里的引用一律用 CJK 引号「」或『』。**写完含引号的中文文案必须编译一遍** |
| T | ★ **变异测试的「判定脚本」本身也要可信** | 我判定「变异是否被发现」的 PowerShell 用了带 ANSI 颜色的输出匹配，且 `[FAIL]` 计数写错 ⇒ 明明 27 项 FAIL，却报「未被发现」 | 用**退出码**判定（0/1 最可靠）。📌 **看到「未被发现」时先怀疑判定方式** —— 否则会去改一个本来正确的测试 |
| U | **别用 PowerShell 字符串替换去改仓颉源码做变异测试** | 反复被 CRLF / 转义 / 行内容漂移坑到，两次直接把源文件改坏（`unclosed delimiter`），只能手工修回 | 用**结构化编辑**（edit 工具）改变异点；或把该不变式下沉成**库级验收断言**（如 AC-P2-5）——比字符串变异更稳、诊断价值也更高 |
| O | ★★ **不要在"字节空间"里做算术减法**（L 条的根因，第五份复查） | 我上一轮把"字符减 4"改成"字节减 4"，**换汤不换药** —— 两种写法都假设"前面几个字符宽度均匀"。ASCII+汉字混排时 `from` 落进汉字中间 ⇒ 非法 UTF-8 ⇒ 普通主诉 **HTTP 500**（`CT显示没有胸痛`） | 把这类运算**全部收口到一个口径**：统一转 `Rune[]`，下标/窗口/切片一律在字符空间做，只在必要时显式换算字节（并对"不在字符边界"返回 -1 拒绝）。**别在同一个表达式里混用两种单位** |
| P | ★★ **同一个语义只准有一处实现**（本项目反复踩到） | 红色保险丝处理了否定，科室判定用**裸 `contains`** ⇒ "不胸闷，只是咳嗽" 推荐**心血管内科**；因有号校验通过，响应 `reason=OK` **看起来权威** | `guessDepartment` 改为**复用** `redFlagSegments` + `redFlagHit`。历史同类：登录名归一、连接参数、文档数字 |
| Q | **测试只覆盖一种形态 ⇒ 它验的是那种形态，不是那条规则** | 否定用例全是**等宽纯汉字**（"没有胸痛"），边界永不落在字符中间 ⇒ 上面那个 500 全漏。与"变异②漏掉"**同构** | 改成**按类别扫**：16 种前缀宽度 × 10 种否定写法 = **160 组**，反向再来 112 组。**补样例不如扫组合** |
| R | **"碰巧对"的代码要把前提写成测试，而不是重写** | `parseDsn` 也混用字节/字符，但**恰好安全**（分隔符全是 1 字节 ASCII + `x+1` 恰好跳过它）；这个前提**没被写下来** | 不重写没坏的东西，但加 6 条含中文用户名/密码/主机/库名的 DSN 断言 —— 前提被破坏时立刻变红 |
| N | **`.ps1` 存盘必须带 UTF-8 BOM** | 我用 `UTF8Encoding($false)`（无 BOM）改写 `doc-counts.ps1`，PowerShell 按 ANSI 读 ⇒ 满屏乱码 + `意外的标记` 解析错 | 所有 `server/**/*.ps1` 统一 `UTF8Encoding($true)` |
| J | ★★ **"生成器"与"校验器"必须在同一契约下**（2026-10-07 的真实缺陷） | `create-admin` 约 **8.6%** 概率失败且**冒堆栈** —— `randCode(12)` 从 21 字母 + 5 数字里独立取值，**不保证成分**，于是自己的口令被**自己的**强度规则拒 | `randCode` 强制 1 字母 + 1 数字再整体洗牌；`createAdmin` 整体 try/catch + 重试一次。**加校验规则时必问：我们自己的生成器 / 默认值 / 夹具满足它吗？** |
| K | **改写"清单 / 白名单"时最容易漏掉"原本已有的项"** | 我扩容弱口令表（补 40 余条）时**漏掉了原有的 `admin123`** —— 是测试用例当场抓到（期望 400 拿到 201） | 补回并加齐同类变体。**改清单要"读原清单 → 增补"，不要"重写"** |
| I | **PowerShell 的 `MatchEvaluator` scriptblock 里必须用 `#` 注释** | 写 C 风格 `/* */` → `无法将"/*"项识别为 cmdlet` | 改 `#`。（同类：`.ps1` 文件本身也是 PowerShell 上下文） |

## 六、明确**未**做

> ⚠⚠ **本节是"时点快照"，不是当前状态**（2026-10-07 修订，第六份复查第 2 条指出）。
>
> **历史横幅**：本节的 5 条**已经全部做完**（见下表）。一个照本节阅读的新读者
> （或新会话的 agent）会得出与现状**完全相反**的结论 —— 这正是复查点名的问题。
>
> 处置口径**照 `docs/P0-HANDOFF.md`**（那边对同类问题用了"时点快照 + 勘误表"，
> 处理得好）：本节保留原样作为**历史记录**，但**逐条加勘误**，
> 并把"当前真实未做的清单"指到别处 —— **不再维护第二份会过期的清单**。

| 本节原记「未做」 | 现状 | 落地提交 |
| --- | --- | --- |
| ❌ 令牌鉴权体系（换取/持久化/过期回收） | ✅ **已做**：不透明令牌 + PBKDF2 100k + 登录限流 + 会话按设备 | `c80e344` 起 |
| ❌ 内存 Store 范式（科室/医生/病历） | ✅ **已做**：`mem_store.cj` + AC-4 四层断言 + 两道变异测试 | `a4123e1` |
| ❌ 患者"我的挂号"列表、排班列表（按科室/日期） | ✅ **已做**：`GET /api/v1/appointments` + `GET /api/v1/schedules` | `3c05497` |
| ❌ HTTPS（`serveTls`） | ✅ **已做**：TLS 1.2/1.3 + 带 SAN 自签 + fail-closed | `061ad0d` |
| ❌ AI 分诊与预问诊 SSE | ✅ **已做**：分诊（`bf87a4f`）+ 预问诊 SSE（`e5d2a33`） | `bf87a4f` / `e5d2a33` |

### 当前真实的「未做」清单 —— 只此一处

- **[docs/P2-HANDOFF.md §七](../docs/P2-HANDOFF.md)** —— P2 范围内未做 / 待决项
  （接真模型阻塞于 Q6 合规、词表临床完备性、RAG 等）
- **[docs/P1-OPS-HANDOFF.md](../docs/P1-OPS-HANDOFF.md)** —— 两项**运维**未做
  （证书信任分发、轮换与到期监控）
- **根 [README.md](../README.md) 的里程碑表** —— P3 / P4 尚未开始
- ❌ AI 分诊与预问诊 SSE（P2/P4）
