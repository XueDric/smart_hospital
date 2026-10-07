# 智慧医院服务端（仓颉 + 轻舟）

> P0 阶段交付：**号源/挂号域的独立 MySQL 路径** + 构建链 + 验收测试。
> 架构决策见 [../docs/adr/ADR-0001-号源与挂号独立MySQL路径.md](../docs/adr/ADR-0001-号源与挂号独立MySQL路径.md)。

---

## 一、环境事实（本机实测）

| 项 | 值 | 说明 |
| --- | --- | --- |
| 编译器 | **cjc 1.2.0** | `C:\Users\ASUS\.cjenv\sdks\1.2.0\cangjie` |
| ⚠ PATH 上的 cjc | **1.1.3**（`D:\Cangjie`） | **是旧版、不可用**。版本串台症状 = 编译中途 `LLVM ERROR: Broken module found` |
| stdx | **1.1.3.1 静态** | `E:\cangjie\stdx\windows_x86_64_cjnative\static\stdx` |
| 数据库 | **MariaDB 11.4.13**（便携版）@ `127.0.0.1:3307` | `E:\cangjie\mariadb\mariadb-11.4.13-winx64` |
| 业务库 / 账号 | `hospital` / `hospital` 口令 `hospital_dev_2026` | ⚠ 开发口令，**上生产必须换** |
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
.\build\hospital-server.exe check-db "mysql://hospital:hospital_dev_2026@127.0.0.1:3307/hospital"
.\build\hospital-server.exe accept   "mysql://hospital:hospital_dev_2026@127.0.0.1:3307/hospital"

# 建第一个管理员（引导入口，不经 HTTP；口令只打印一次）
.\build\hospital-server.exe create-admin "mysql://hospital:hospital_dev_2026@127.0.0.1:3307/hospital"

# P1：启动 HTTP 服务（阻塞）—— 默认只绑 127.0.0.1
.\build\hospital-server.exe serve "mysql://hospital:hospital_dev_2026@127.0.0.1:3307/hospital" --port 8091
```

| 子命令 | 作用 | 需要 MySQL |
| --- | --- | --- |
| `selftest` | schema 与 ADR 不变量的**纯本地**自检（32 项断言） | ❌ |
| `authtest` | **口令/令牌原语自检**（含 3 个公开测试向量，17 项） | ❌ |
| `check-db <dsn>` | 连库 + 幂等建表 + 打印表清单（★ 标记号源域） | ✅ |
| `accept <dsn>` | P0 验收测试 AC-1…AC-8（32 项断言） | ✅ |
| `create-admin <dsn>` | 建/重置管理员并打印口令（**引导入口**） | ✅ |
| `serve <dsn>` | **P1**：启动 HTTP 服务（默认只绑 `127.0.0.1`） | ✅ |

⚠ `accept` **会清空业务表**，已内置库名守卫（库名不含 `test` 且不等于 `hospital` 时中止）。
⚠ `serve` 的 `--dev-auth` 是**开发态身份头**，绕过全部认证；与 `--prod` 同传会拒绝启动。
⚠ `serve` 启动时**先跑 `authtest` 再连库** —— PBKDF2 错了就没必要连库。

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
```

两个脚本**互不依赖执行顺序**（自建夹具、自清数据）。
> ⚠ 必须用 `curl -K` config 文件传 header/body —— `Start-Process -ArgumentList` 会拆坏
> 含空格的参数（详见 [../docs/P1-HANDOFF.md](../docs/P1-HANDOFF.md) §3.3）。

### 验收依据：源码哈希，不是产物哈希

cjc 的产物**不逐字节可复现**（实测：同一份源码连续两次构建，exe 的 SHA256 不同，行为一致）。
所以 `build.ps1` 每次构建都会重写 **`build/SOURCE-MANIFEST.sha256`**（45 个参与编译源文件的
SHA256 + cjc 版本 + stdx 路径 + 驱动产物哈希）—— 它的哈希是**稳定**的。
**验收请比 `SOURCE-MANIFEST.sha256` + 测试结果，不要比 exe 哈希。**

---

## 四、P0 已交付内容

| 文件 | 职责 |
| --- | --- |
| `src/schema.cj` | 最小表集 DDL（9 张：7 业务 + 2 鉴权）+ 分域范围锁死 |
| `src/domain_booking.cj` | ★ 号源/挂号域：原子扣减、幂等、取消归还（三态 `CancelOutcome`）、`visit_date` 快照 |
| `src/auth_crypto.cj` | PBKDF2-HMAC-SHA256（100k）+ 令牌原语 + **3 个公开测试向量自检** |
| `src/auth_repo.cj` | 鉴权仓储：账号、按登录名查、登录（防枚举）、令牌签发/校验/续期/吊销 |
| `src/db_bootstrap.cj` | MySQL 建连 + `SET NAMES utf8mb4` + DSN 解析 + 驱动注册 |
| `src/http_common.cj` | 统一响应/错误码表（`{ok,data}` / `{ok:false,error}`） |
| `src/http_app.cj` | HTTP 装配 + 三端权限矩阵 + `principalOf()`（令牌优先，开发态头可选） |
| `src/acceptance.cj` | AC-1…AC-8 验收测试（含异常兜底与变异测试记录） |
| `src/main.cj` | 进程入口与子命令分发 |

**最小表集（9 张）**：

| 表 | 层 | 数据访问 |
| --- | --- | --- |
| `schedule` | 号源域 · **业务状态** | 直接 SQL |
| `appointment` | 挂号域 · **业务状态** | 直接 SQL |
| `booking_idem` | 号源域 · **幂等基础设施** | 直接 SQL（仅 `BookingRepo` 写） |
| `auth_user` `auth_token` | **鉴权域** | 直接 SQL（仅 `AuthRepo` 写） |
| `department` `doctor` `patient` `medical_record` | 业务 | 内存 Store 范式（P1+ 落地） |

> ⚠ `booking_idem` 与 `auth_token` **刻意不叫** `idem` / `tokens`：
> 基线内存 Store 已占用这两个表名（`mysql_store.cj:891-892`），列定义也不同。
> 现「本侧 9 张表 ∩ 基线 10 张表 = ∅」，由 `selftest` + AC-4 钉住。

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

## 六、明确**未**做

- ❌ **令牌鉴权体系**（换取/持久化/过期回收）—— P1 用 `--dev-auth` 开发态身份头临时替代；
  换令牌时 `principalOf()` 是**唯一改点**（权限矩阵 `can()` 与身份来源已解耦）
- ❌ 内存 Store 范式（科室/医生/病历）—— AC-4 的完整回归依赖它
- ❌ 患者"我的挂号"列表、排班列表（按科室/日期）
- ❌ HTTPS（`serveTls`）—— ⚠ 基线 `certs/` 私钥**已按安全要求剔除**，需重新生成证书
- ❌ AI 分诊与预问诊 SSE（P2/P4）
