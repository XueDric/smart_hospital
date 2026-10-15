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
搬迁前的服务端已踩过此坑，故沿用 **cjc 直编、框架与业务同一次调用、同一个包**。

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
| `selftest` | schema 与 ADR 不变量的**纯本地**自检（**51 项**断言） | ❌ |
| `triagetest` | P2 分诊 + 预问诊**纯逻辑**自检（**110 项**断言），不碰库不调模型 | ❌ |
| `authtest` | **口令/令牌原语自检**（含 3 个公开测试向量，**17 项**） | ❌ |
| `check-db <dsn>` | 连库 + 幂等建表 + 打印表清单（★ 标记号源域） | ✅ |
| `accept <dsn>` | 验收测试 AC-1…AC-17（**750 项断言**：AC-1…AC-13 + **AC-14/AC-15**（令牌续期回值、`/health` 日期口径）+ **AC-16/AC-17**（`ai_model` 模型配置、账号列表/排班可改）+ AC-P2-1…6 / AC-P3-1…6 / **AC-P4-1…7** / AC-BASE-1…3 / AC-AICALL-1…3 / AC-NOTICE-1…3；⚠ 只允许库名含 `test` 的测试库） | ✅ |
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

#### 2026-10-12：患者端联调补齐的接口（八项）

> 背景：鸿蒙患者端与真服务端在模拟器上联调后，暴露出 8 个"服务端缺"的点，
> 逐项补掉。**改动全部是加法**（老字段一个没删），因此对既有客户端是兼容的。

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/v1/health` | 与 `/health` **同一实现**的别名（客户端统一带 `/api/v1` 前缀时少一个特例） |
| GET | `/api/v1/schedules?department_id=&work_date=&limit=` | 三端可读；**新增** `department_name` / `doctor_name` / `doctor_title` / `version` |
| GET | `/api/v1/appointments?include_cancelled=&limit=` | 仅患者；**新增** 科室/医生名称（原先只有 id） |
| GET | `/api/v1/medical-records?limit=` | 仅患者（自己的）；**新增** `department_id` / `visit_date` / `period` + 科室/医生名称 |
| GET | `/api/v1/departments?enabled_only=` | 三端可读的**科室字典**（患者端不必再手输 `810003`）。⚠ **刻意不分页** —— 截断的下拉框对患者不可见；要控规模请用 `enabled=0`（管理端 `/api/v1/admin/departments` 才有 `limit`/`offset`/`total`） |
| GET | `/api/v1/doctors?department_id=&enabled_only=` | 三端可读的**医生字典**（带 `department_name`）；同上，**刻意不分页** |
| GET | `/api/v1/notices` | 三端可读的**公告**（仅 `enabled=1` 且 `published_at <= now`） |
| GET/POST | `/api/v1/admin/notices` | 仅管理员（`?include_disabled=` 可见停用/预排期） |
| GET/PUT/DELETE | `/api/v1/admin/notices/:id` | 仅管理员（删除是硬删；要留痕就 `PUT enabled=false`） |

> ⚠ **`/auth/me` 现在返回 `display_name`**：此前只回 `{user_id, role, patient_id, doctor_id, device_id}`，
> 患者端"同步身份信息"因此刷不出姓名（只能显示登录那一刻缓存的旧值）。
> ⚠ **挂号/退号响应新增 `remain_num` 与科室/医生名称**：客户端挂完号可就地刷新「余 N」，
> 不必再发一次排班查询。

**鉴权**：`Authorization: Bearer <token>`。令牌 32 字节随机（64 hex），有效期 30 天、
滑动续期（每天最多写一次）。**有状态**（服务端存 token → user）⇒ 停用/改口令可立即踢下线。

联调备用：`--dev-auth` 开启后可用 `X-Role: patient|doctor|admin` +
`X-Patient-Id: <id>`（患者）/ `X-Doctor-Id: <id>`（医生，`http_app.cj` 实际会读取）；
**未开启时这些头被忽略并返回 401**（有测试钉住）。

> ⚠ **这些头只在「本机回环来源」生效**（2026-10-14 加）：即使带着 `--dev-auth`，
> 从别的机器/网段打过来（来源 IP 非 `127.0.0.1`/`::1`）也会被拒：
> `401 AUTH_REQUIRED`「开发态身份头（X-Role 等）只允许本机回环地址使用（来源 x.x.x.x）」。
> 理由：`--dev-auth` 可能被误开到 `--bind 0.0.0.0`，此时任何能访问端口的人都可自封管理员；
> 回环限制让"误开"最多只影响本机。`health-check.ps1 -Mode dev|prod` 会把这条作为门禁断言。

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

# 预问诊交接（改进 1）：挂号带 previsit_id 绑定 + 医生读这一单的自述 + 病历 previsit_ref
.\tests\previsit-bridge-check.ps1 -Base http://127.0.0.1:8091 -AdminPw <管理员口令>

# 病历修订历史（改进 3）：定稿落版 / 解锁带理由 / 版本列表与逐段对比 / 权限与幂等
.\tests\revision-check.ps1    -Base http://127.0.0.1:8091 -AdminPw <管理员口令>

# 医生录入工作台（改进 2）：既往已定稿病历（隐私边界/只回 locked/exclude/limit）+ 乐观锁 409
.\tests\workbench-check.ps1   -Base http://127.0.0.1:8091 -AdminPw <管理员口令>

# 就诊时间线（改进 6）：到院→候诊→接诊→完成全链路 + 三个时间戳逐字段 + 非法流转 409 + 队列排序
.\tests\visit-timeline-check.ps1 -Base http://127.0.0.1:8091 -AdminPw <管理员口令>

# 接口契约门禁（改进 5）：样例与实测逐字节一致 + Schema 校验 + 登记完整性
.\tests\contract-check.ps1    -Base http://127.0.0.1:8091 -AdminPw <管理员口令>

# AI 分诊遥测与排障（改进 7）：质量聚合（分位数/降级率/分组）+ 按 request_id 捞单次全链路 + 隐私与版本号
.\tests\ai-telemetry-check.ps1 -Base http://127.0.0.1:8091 -AdminPw <管理员口令>

# AI 分诊评测（改进 7）：默认回放（离线可重复，只读 recorded/），-Mode live 才打真实服务端；
# -Record 重录样本；报告与指标落 docs/ai-eval/<date>.md / .metrics.json。不进 final-verify。
.\tests\ai-eval\run-ai-eval.ps1 -Mode replay
.\tests\ai-eval\run-ai-eval.ps1 -Mode live -Base http://127.0.0.1:8091 -AdminPw <管理员口令>

# 探活接口（/health 与 /api/v1/health：响应形状 + ★ 医院日期口径；无需认证）
.\tests\health-check.ps1   -Base http://127.0.0.1:8091

# 基础数据域（科室/医生/排班的 CRUD + 分诊推荐 + ★ 排班可改：不变量与乐观锁）
.\tests\base-check.ps1     -Base http://127.0.0.1:8091 -AdminPw <管理员口令>

# AI 模型配置（管理台「AI 模型配置」页）：CRUD / 校验闸门 / 连通性测试 / 缓存失效
.\tests\ai-model-check.ps1 -Base http://127.0.0.1:8091 -AdminPw <管理员口令>

# 管理台前端冒烟（无头 Edge + CDP：11 个页面逐个渲染 + 控制台/异常/4xx 全收集 + 截图）
& $env:NODE 'tests\admin-web-smoke.mjs' --base http://127.0.0.1:8091 --admin admin --pw <管理员口令>

# 文档数字对账（防"文档与实测漂移"；-Fix 自动改写）
.\tests\doc-counts.ps1
```

各脚本**互不依赖执行顺序**（自建夹具、自清数据）。
> ⚠ 必须用 `curl -K` config 文件传 header/body —— `Start-Process -ArgumentList` 会拆坏
> 含空格的参数（详见 [../docs/P1-HANDOFF.md](../docs/P1-HANDOFF.md) §3.3）。
> ⚠ `tls-check.ps1` **不用** `curl --cacert` 做主校验：Windows 的 Schannel 对自签证书的
> `--cacert` 支持不完整（实测 `schannel: error 0x00000010`，而同刻 `curl -k` 是 200），
> 所以它走 .NET `SslStream` + 显式链校验 + 自解析 SAN。理由与两个坑写在脚本头注释里。

### 管理台（`/admin/`，2026-10-14 增）

服务端**自带一个浏览器管理台**：`server/admin-web/` 是**零构建纯静态**页面（无 npm / 无打包产物），
由 `main.cj` 用轻舟的 `serveWithOpts` 挂在 `/admin`，与 API **同源同端口**（因此没有 CORS / 证书 /
反向代理话题）。

```powershell
# 起服务端后直接开（先登录：admin / create-admin 打印的口令）
start http://127.0.0.1:8091/admin
```

| 项 | 口径 |
| --- | --- |
| 页面 | 运营看板 / 用户 / 科室 / 医生 / 排班号源 / **AI 模型配置** / AI 全局设置 / Prompt 模板 / 工具中心 / 医学知识库 / 系统公告（11 页；患者档案、症状标签库、Agent 执行观测**未做**，侧栏灰显并写明原因） |
| 鉴权 | 静态页面**本身不鉴权**（谁来都能拿到 HTML），数据一律走 `/api/v1/admin/*` 逐条校验；令牌存 `localStorage`，`401` 即回登录页 |
| 密钥 | 配置里只存 `env:变量名` / `file:路径` 这类**引用**；列表接口只回 `key_ref_set` / `key_ref_kind`，**永不回显**引用本体 |
| 改配置要重启吗 | 不用。写库后立即 `invalidate()`，下一次 AI 请求按新配置动态构建模型实例（页面上的「失效配置缓存」按钮是同一件事的手动兜底） |

细节（页面 ↔ 接口映射、安全口径、为什么不用前端框架/不加构建步骤）见 [../docs/ADMIN-WEB.md](../docs/ADMIN-WEB.md)。

### 验收依据：源码哈希，不是产物哈希

cjc 的产物**不逐字节可复现**（实测：同一份源码连续两次构建，exe 的 SHA256 不同，行为一致）。
所以 `build.ps1` 每次构建都会重写 **`build/SOURCE-MANIFEST.sha256`**（轻舟框架 38 + 业务 37 =
**75 个参与编译源文件**的 SHA256 + cjc 版本 + stdx 路径 + 驱动产物哈希）—— 它的哈希是**稳定**的。
**验收请比 `SOURCE-MANIFEST.sha256` + 测试结果，不要比 exe 哈希。**

---

## 四、P0 已交付内容

| 文件 | 职责 |
| --- | --- |
| `src/schema.cj` | 最小表集 DDL（**15 张 / 9 类**：号源域 2 + **基础数据域 3**（直接 SQL）+ 鉴权域 3 + 预问诊域 1 + AI 配置域 1 + **病历域 1** + **统计域 1** + **知识库域 2** + **公告域 1**）+ 范围锁死 + 幂等迁移 |


| `src/domain_booking.cj` | ★ 号源/挂号域：原子扣减、幂等、取消归还（三态 `CancelOutcome`）、`visit_date` 快照 |
| `src/auth_crypto.cj` | PBKDF2-HMAC-SHA256（100k）+ 令牌原语 + **3 个公开测试向量自检** |
| `src/auth_repo.cj` | 鉴权仓储：账号、按登录名查、登录（防枚举）、令牌签发/校验/续期/吊销 |
| `src/db_bootstrap.cj` | MySQL 建连 + `SET NAMES utf8mb4` + DSN 解析 + 驱动注册 |
| `src/http_common.cj` | 统一响应/错误码表（`{ok,data}` / `{ok:false,error}`） |
| `src/http_app.cj` | HTTP 装配 + 三端权限矩阵 + `principalOf()`（令牌优先，开发态头可选）+ **登录限流闸门** + **会话/列表端点** |
| `src/auth_repo.cj` | 鉴权仓储：**口令强度校验（仓储层强制）** + 登录名归一 + 限流计数 + 会话按设备 |
| `src/acceptance.cj` | AC-1…AC-17 验收测试（含异常兜底与变异测试记录；AC-8 已于 2026-10-07 随 `booking_idem` 删除、AC-9 未使用；**AC-13 = 退号状态机**，2026-10-12 增；**AC-14 = 令牌续期后 `/auth/me` 回报的 `expires_at`**、**AC-15 = `/health` 的 `today`/`timezone` 口径**，均 2026-10-14 增（跨端审计 F11/F14）；**AC-16 = `ai_model` 模型配置**（播种幂等 / 默认行解析 / 温度注入运行时 / 缓存失效）、**AC-17 = 账号列表 + 排班可改**（`listUsers` 不读口令材料、`updateSchedule` 的"放号数 ≥ 已约数"不变量与乐观锁），均 2026-10-14 管理台轮增） |
| `src/acceptance_triage.cj` | AC-P2-1…AC-P2-5：分诊**验证层** + 预问诊**会话隔离**在库级成立（含变异测试记录） |
| `src/previsit.cj` | **P2 预问诊**：多轮采集状态机 + SSE 帧 + 结构化问诊单（业务值，非流式） |
| `src/ai_settings.cj` | **P3 AI 能力中心**：配置 KV 表 + 缓存失效 + ★★ 密钥引用校验（密钥不落库）+ 脱敏回显 |
| `src/ai_prompt.cj` | **P3 第二块**：Prompt 模板（占位符契约）+ AI 工具开关，复用同一 KV 与缓存 |
| `src/acceptance_ai.cj` | AC-P3-1…6：密钥不落库 / 零重启 / 配置校验 / 回显脱敏 / 占位符 / 工具开关 |
| `src/domain_emr.cj` | **P4 电子病历域**：七段式病历 + `MedicalRecordRepo`（**直接 SQL**，不属内存 Store）+ 接诊状态机 |
| `src/dashboard.cj` | **P4 运营看板**：只出聚合、绝不出明细（隐私红线写在文件头） |
| `src/triage_stat.cj` | **P4 分诊统计**：只存结论；`record()` 签名里**没有主诉参数**（类型层面存不进敏感文本） |
| `src/http_p4.cj` | **P4 接口层**：11 个端点（接诊队列 / 病历 / 看板）；路由注册仍集中在 http_app.cj |
| `src/acceptance_p4.cj` | AC-P4-1…7：病历锁定不可改 / 状态机 / 看板隐私 / 统计不落敏感文本 / **AC-P4-5 预问诊绑定与预填（改进 1）** / **AC-P4-6 病历修订历史（改进 3）** / **AC-P4-7 医生读既往病历 + 乐观锁（改进 2）** |
| `src/domain_base.cj` | **基础数据域（科室/医生）仓储**：CRUD + 唯一键冲突分类 + **引用保护**（有引用不删）+ **软删**（force） |
| `src/http_base.cj` | **基础数据域接口**（12 个端点）：科室/医生的管理端 CRUD（仅 `ManageBaseData`，管理员；**列表支持 `limit`/`offset` 且回 `total`**，见文件头"分页"一节）+ **患者可读字典** `GET /api/v1/departments`、`GET /api/v1/doctors`（**刻意不分页**） |
| `src/domain_notice.cj` | **公告域仓储**（2026-10-12）：院内公告/健康提示的 CRUD；列顺序单一定义 + 列数守卫；⚠ 公告**不进检索、不出站**（与 `kb_doc` 的边界写在文件头） |
| `src/http_notice.cj` | **公告域接口**（6 个端点）：`GET /api/v1/notices`（三端可读）+ 管理端 CRUD（仅 `ManageNotice`）；`published_at` 支持预排期 |
| `src/ai_call.cj` | **真模型出站**（P5 第一步）：TLS 出站 + 密钥**引用**解析 + **脱敏** + 失败不抛异常；2026-10-14 起请求体带 `temperature`，并新增**连通性探测**（`aiProbeChat` / `aiProbeEmbedding`） |
| `src/ai_model.cj` | **AI 模型配置域**（2026-10-14，管理台）：一个模型一行（类型 `CHAT`/`EMBEDDING`、提供方、`base_url`、模型名、温度、上限、密钥引用、启停、默认位）；`defaultOf()` 决定运行时用哪条；`aiModelSeedDefaults()` 首次播种两条默认行；密钥**只存引用、永不回显** |
| `src/ai_triage.cj` | **模型增强层**：只写 `aiNote`/`aiReason`，**绝不碰 `options`**（硬性验证层不可绕过）+ 安全清理层 |
| `src/acceptance_base.cj` | AC-BASE-1…3：科室唯一性 / 不许孤儿医生 / 删除的两种语义 |
| `src/acceptance_ai_call.cj` | AC-AICALL-1…3：可调用性 / **安全清理层（医疗建议一律丢弃）** / 响应解析 + 可选真实出站 |
| `src/acceptance_notice.cj` | AC-NOTICE-1…AC-NOTICE-3：同名唯一 / **患者可见性两条件**（含 `published_at == now` 边界与预排期）/ `limit` 夹取与硬删 |
| `src/main.cj` | 进程入口与子命令分发（含 TLS 分支与 fail-closed） |
| `new-tls-cert.ps1` | 生成带 SAN 的自签证书 + ASCII 运行副本 + ACL 收紧 |
| `tests/tls-check.ps1` | TLS 验证（SslStream 真校验、反向验证、HTTPS 业务链路） |
| `tests/health-check.ps1` | 探活接口（`/health` + `/api/v1/health`）：无需认证、响应形状、**医院日期口径 `today`/`timezone`**、两路径同实现 |
| `tests/ai-model-check.ps1` | **AI 模型配置端到端**（45 项，2026-10-14）：鉴权 / 播种 / 密钥不回显 / 校验闸门 / PATCH 语义 / 默认位唯一与 `in_use` / 连通性测试 / 缓存失效 / `settings` 登记表闸门 |
| `tests/visit-timeline-check.ps1` | **就诊时间线端到端**（47 项，2026-10-15，改进 6；2026-10-16 复核补 D6/D7）：到院/候诊鉴权与归属 / 全链路 `booked→arrived→waiting→visiting→done` / **三个时间戳逐字段**（只写自己那一个、被拒的流转一个都不写、`waiting` 不写戳）/ 非法流转（重复到院、跳步、终态回退）⇒ 409 `VISIT_BAD_STATE` / 未锁病历完成 ⇒ 409 `EMR_NOT_LOCKED` / 队列排序（待处理优先）与 `status_label` 同源 / **到院后退号 ⇒ 409 `APPOINTMENT_NOT_CANCELLABLE`，未到院退号 ⇒ 200**（D6：原先标题写"200"却拿 `booked` 夹具去撞）/ **混合态排序真断言**（D7：`waiting` 排在 `booked` 前，此前只在注释里声称验过）/ 夹具自清**只扫本夹具范围**（D8：不再全表 `DELETE FROM medical_record`） |
| `tests/ai-telemetry-check.ps1` | **分诊遥测与排障端到端**（53 项，2026-10-15，改进 7；2026-10-16 复核补 D2/红标口径）：鉴权 / 参数闸门（`group_by` 白名单、`from>to`、**非数字与 >366 天跨度 ⇒ 400**、上限夹取）/ 一次真调用后按 `request_id` 捞全链路（**17 字段**齐 + `degraded` 与 `red_flag_bypass` **互补**）/ **超长 `X-Request-Id` 端到端**（D2：写侧截 64、读侧同口径仍查得到）/ **隐私否定断言**（聚合与单次体里都搜不到主诉指纹）/ 聚合分位数与降级率**（`RED_FLAG` 不计入降级，另立 `red_flag`/`red_flag_rate`）**/ 版本号严格前进 / 夹具自清（残留为 0 会真的红） |
| `tests/ai-eval/run-ai-eval.ps1` | **AI 分诊评测**（改进 7，2026-10-15）：默认**回放**（读 `recorded/`，离线可重复，连跑两次指纹须一致）；`-Mode live [-Record]` 打真实服务端并录制样本；报告落 `../docs/ai-eval/<date>.md` + `.metrics.json`。**不进 `final-verify`**（依赖真实模型，见 [../docs/ai-eval/README.md](../docs/ai-eval/README.md)） |
| `tests/admin-web-smoke.mjs` | **管理台前端冒烟**（2026-10-14）：无头 Edge + CDP，11 个页面逐个真实渲染 + 控制台/异常/`>=400` 全收集 + 逐页截图；任一项失败 `exit 1` |
| `admin-web/` | **后台管理台的静态资源**（零构建：`index.html` + `css/` + `js/` 四个脚本），由服务端按 `/admin` 前缀托管；页面本身不鉴权，数据全走 `/api/v1/admin/*`（详见 [../docs/ADMIN-WEB.md](../docs/ADMIN-WEB.md)） |

**最小表集（16 张 / 10 域）**：

| 表 | 域 · 纪律 | 数据访问 |
| --- | --- | --- |
| `schedule` | 号源域 · **业务状态** | 直接 SQL（仅 `BookingRepo` 写；**原子自减**，ADR-0001 范围锁死） |
| `appointment` | 挂号域 · **业务状态** | 直接 SQL（仅 `BookingRepo` 写） |
| `department` `doctor` `patient` | **基础数据域** | 直接 SQL 读；⚠ **无写入端点**（靠人工 SQL 维护 —— 见下方 rev.7 说明） |
| `auth_user` `auth_token` `auth_login_attempt` | **鉴权域** | 直接 SQL（仅 `AuthRepo` 写） |
| `previsit_session` | **预问诊域** · 医疗数据 | 直接 SQL（仅 `PrevisitRepo` 写；★ P2 起**刻意不进**任何缓存范式） |
| `ai_setting` | **AI 配置域** · 配置 | 直接 SQL（KV；写库即失效缓存 ⇒ 改配置零重启）；⚠ 密钥**只存引用**不存明文 |
| `ai_model` | **AI 模型配置域**（2026-10-14） · 配置 | 直接 SQL（仅 `AiModelRepo` 写；一个模型一行、同类型唯一默认位；⚠ 密钥同样**只存引用**；运行时由 `AiSettingsRepo.options()` 按默认行**整体覆盖**旧 KV） |
| `medical_record` | **病历域** · 临床数据 | 直接 SQL（仅 `MedicalRecordRepo` 写；锁定后不可改） |
| `triage_stat` | **统计域** · 聚合 | 直接 SQL（只存计数，**不含任何患者标识**，带 180 天 TTL） |
| `notice` | **公告域** · 展示内容 | 直接 SQL（仅 `NoticeRepo` 写）；⚠ **不进检索、不随 Prompt 出站**（与 `kb_doc` 的分界）；`published_at` 支持预排期 |

> ★★ **ADR-0001 rev.7（2026-10-07）：内存 Store 已整体拆除，全库只剩一种数据访问范式。**
> 原"内存 Store 范式"的 `mem_store.cj` / `sql_recorder.cj` **已删除** ——
> 实测它**在生产上从未接线**（生产零实例化、零 `loadAll`、零 `flushToMysql`，
> 且**没有"往内存里写"的入口方法**）⇒ 那三张表实际是**只读参考数据**。
> ⇒ 因此 `department`/`doctor`/`patient` 归入新的**基础数据域**：
>   **直接 SQL 读，但目前没有写入端点**（靠人工 SQL 维护）。
>   ⚠ 这句话要留着 —— 否则读者会以为"系统会自动积累科室/医生数据"。
> 详见 [../docs/adr/ADR-0001](../docs/adr/ADR-0001-号源与挂号独立MySQL路径.md) rev.7。

> ⚠ `auth_token` **刻意不叫** `tokens`：搬迁前内存 Store 已占用该表名
> （`mysql_store.cj:891`），列定义也不同。
> 现「本侧 8 张表 ∩ 搬迁前 10 张表 = ∅」，由 `selftest` + AC-4 钉住，
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
    一个 emoji 就会让之后**所有写入持续 500** 直到重启（搬迁前的 API 踩坑记录 坑 44）。
11. **OpenSSL 3 DLL 必须与 exe 同目录**，否则运行时 `CryptoException: Can not load openssl library`。
    处置：`setup-runtime.ps1`。
12. **`SELECT LAST_INSERT_ID()` 与 MySQL `AUTO_INCREMENT` 起点**：清表用 `DELETE` 不重置自增，
    所以测试用**显式 id**，避免依赖自增序列。
13. **`cancel()` 不能用 `Bool` 表达结果**：把"单子取消了"与"号还回去了"压进一个 bool，
    必然丢掉"单已取消但号未归还"这一真实中间态，于是对外**报错方向与事实相反**
    （已改为**四态** `CancelOutcome`，AC-7 + AC-13 钉住）。
    ★ 2026-10-12 补第四态 `NotCancellable(status)`：退号是**状态机的一条边**，
    只有 `booked` 能退；原子 UPDATE 必须带 `WHERE status = 'booked'`
    （原来写 `status <> 'cancelled'`，于是 `visiting`/`done`/`no_show` 都能被退掉并归还号源
    —— 见 `docs/CODE-REVIEW-2026-10-12.md` 第 1 条）。
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
| M | **仓颉的块注释会嵌套**：注释里写 `/api/v1/admin/*`，那个 `/*` 会**开一个新的嵌套注释** | 整份文件报 `unterminated block comment`，且 cjc 把范围指到**文件末尾**（`http_app.cj:1538` → 一直到 EOF），**看不出是哪一行** ⇒ 白找很久 | 注释里写通配路径写 `admin` / `admin/…`，**绝不写 `admin/*`**。同族坑：注释里也不能出现 `*/` |
| M | **断言"没有 X"时，要让 X 真的存在过** | P2 变异测试：把 `remain_num > 0` 改成 `>= 0`（约满也推荐），**92 项断言全绿** —— 因为用例造的是"科室没有排班行"，诱惑源根本不在 | 改造成"排班存在但 `remain_num = 0`"后变异立刻 **2 FAIL**。否则测试验的是"列表是空的"，而不是"不该出现的项没出现" |
| AA | ★★ **"探测"必须探"真正需要的那件事"** | 我两次探错：① 拿 `CREATE TABLE` 探"库可用吗" —— 而 `CREATE ON *.*` 是全局的 ⇒ 新库上**永远允许** ⇒ **必然假阳性**，还留下垃圾表；② 拿"对已存在的表 ALTER"探 —— 全新库里没有表 ⇒ 兜底判"不可用" ⇒ **管理员授好权了也报失败**。正解：`CREATE TEMPORARY TABLE`（零残留，验 CREATE）+ 对已存在表 `ALTER ... ENGINE=InnoDB`（幂等，验 ALTER），**两者都过才算可用** | **探更弱的能力会给出"看起来通过"的假阳性，比不探更坏** |
| AB | ★★ **`GRANT` 独立于库存在 —— 删库 ≠ 撤权** | 测试脚本里只 `DROP DATABASE` 没 `REVOKE` ⇒ 授权仍留在 `mysql.db` ⇒ 重建同名库时权限**立刻生效** ⇒ "必须失败"那条用例变成成功（**假红**）。第二遍跑才暴露 | 前置清理要**既撤权又删库**，并**直接查 `mysql.db` 断言残留为 0**（不假设 REVOKE 成功）。测试必须**自建夹具**，不能依赖残留状态 |
| Y | ★★★ **String 常量不能当 `match` 的 case 标签**（会变成 catch-all 绑定！） | 我写 `match (name) { case PROMPT_DEPT => ... case PROMPT_PREVISIT => ... }`，而 `PROMPT_DEPT` 是 **String 常量**。探针实测（`let A: String = "dept"`）：`match(A)`→A ✓；`match("previsit")`→**也命中 A** ✗；`match("zzz")`→**还是命中 A** ✗。⇒ `promptDefaultBody("previsit")` **一直返回 dept 的模板** | **String 的分支一律用 `if (x == 常量)`**。⚠ `case None` / `case Patient` 那些**没问题** —— 它们是 Option/枚举构造子，不是 String 常量。**不报错、不崩溃，只是返回错数据**，靠"值上的断言"才照得出来 |
| Z | ★★ **读用户输入时先用 `is` 判类型再取值** | `{"enabled":"yes"}` 让 `v.asBool().getValue()` **抛异常** ⇒ 全局兜底 ⇒ **500**（字段类型不对是客户端错误，该 400）。实测 `PUT /admin/ai/tools/x {"enabled":"yes"}` → 500 | `if (v is JsonBool) { ...asBool()... } else { return None }`，由调用方给准确 400。📌 `asXxx()` 在类型不符时**抛异常**，不是返回 None |
| X | ★★ **写路径要严格，读路径才宽容**（不要拿"读时的兜底"当"写时的校验"） | `PUT ai.timeout_secs=abc` 返回 200、回显 `abc`，而读取时 `parseInt64Or` 把它**静默换成默认值 30** ⇒ **回显值 ≠ 生效值**，且系统报"配置有效"。更能说明危害的是：库里越界的 `9999` 本来正确地给了 `enabled=false`，被"改成"`abc` 后 **enabled 反而翻成 true** —— 写错一个值把报警变成了绿灯 | 校验放到 `put()`（与 `key_ref` 同一道闸门）；`parseInt64Or` 那种"尽力解析 + 兜底"只该用在**读**路径 |
| V | **注释里不能出现 ``*/``（即使它只是文字）** | 我在块注释里写了 glob 例子 ``server/src/*.cj``，其中的 ``*/`` **提前闭合了注释** ⇒ 报 `unterminated block comment`，而报错行指向别处 | 注释里要写 glob/通配时，避开 ``/*`` 与 ``*/`` 相邻（换成文字描述）。**写完注释也要编译一遍** |
| W | ★★ **脱敏必须只在一处做**（同一个病第 N 次） | `aiSettingsJson` 把 endpoint 当非秘密项**原样回显**，于是 `?token=SECRET` 进了响应体与访问日志 —— 而我**已经在 `aiSafeHost()` 里为日志脱敏过一次** | 回显统一走 `aiSafeHost()` + 加 `redacted` 字段。这条与 P 条（同一语义只准一处实现）是同一个病换了面孔 |
| S | **字符串字面量里不能嵌 ASCII 双引号** | 中文文案里写「写"无"」时用了 ASCII 引号，而它同时是**字符串定界符** ⇒ 报 `unclosed delimiter: '('`（且错误位置指向别处，很难查） | 中文文案里的引用一律用 CJK 引号「」或『』。**写完含引号的中文文案必须编译一遍** |
| T | ★ **变异测试的「判定脚本」本身也要可信** | 我判定「变异是否被发现」的 PowerShell 用了带 ANSI 颜色的输出匹配，且 `[FAIL]` 计数写错 ⇒ 明明 27 项 FAIL，却报「未被发现」 | 用**退出码**判定（0/1 最可靠）。📌 **看到「未被发现」时先怀疑判定方式** —— 否则会去改一个本来正确的测试 |
| U | **别用 PowerShell 字符串替换去改仓颉源码做变异测试** | 反复被 CRLF / 转义 / 行内容漂移坑到，两次直接把源文件改坏（`unclosed delimiter`），只能手工修回 | 用**结构化编辑**（edit 工具）改变异点；或把该不变式下沉成**库级验收断言**（如 AC-P2-5）——比字符串变异更稳、诊断价值也更高 |
| O | ★★ **不要在"字节空间"里做算术减法**（L 条的根因，第五份复查） | 我上一轮把"字符减 4"改成"字节减 4"，**换汤不换药** —— 两种写法都假设"前面几个字符宽度均匀"。ASCII+汉字混排时 `from` 落进汉字中间 ⇒ 非法 UTF-8 ⇒ 普通主诉 **HTTP 500**（`CT显示没有胸痛`） | 把这类运算**全部收口到一个口径**：统一转 `Rune[]`，下标/窗口/切片一律在字符空间做，只在必要时显式换算字节（并对"不在字符边界"返回 -1 拒绝）。**别在同一个表达式里混用两种单位** |
| P | ★★ **同一个语义只准有一处实现**（本项目反复踩到） | 红色保险丝处理了否定，科室判定用**裸 `contains`** ⇒ "不胸闷，只是咳嗽" 推荐**心血管内科**；因有号校验通过，响应 `reason=OK` **看起来权威** | `guessDepartment` 改为**复用** `redFlagSegments` + `redFlagHit`。历史同类：登录名归一、连接参数、文档数字 |
| Q | **测试只覆盖一种形态 ⇒ 它验的是那种形态，不是那条规则** | 否定用例全是**等宽纯汉字**（"没有胸痛"），边界永不落在字符中间 ⇒ 上面那个 500 全漏。与"变异②漏掉"**同构** | 改成**按类别扫**：16 种前缀宽度 × 10 种否定写法 = **160 组**，反向再来 112 组。**补样例不如扫组合** |
| AG | ★★ **"出错时的提示"里绝不写死部署事实**（端口/口令/路径）—— **从配置派生** | 连接失败的提示写死「本机 MariaDB 是 127.0.0.1:**3307**」，而本项目自管 devdb 早已是 **3317**（3307 是本机另一台便携实例）。★ **复查的人和我自己都被它误导过**：devdb 没起来时提示让人去查 3307。⚠ 而同类漂移**一路修了很多处**（DEV-DB、README、脚本默认 DSN），**只有这几处"出错才显示"的文案漏了** —— 偏偏那是最需要准确的地方 | 提示改为回显 `${cfg.host}:${cfg.port}`（**实际用的那个**），并指向 `docs/DEV-DB.md` 作为唯一事实来源 —— **不复制那个数字，就没有第二次漂移的机会**。另：`MySqlConfig.port` 默认值 `3307 → 3306`（原值是**假默认**："没拿到 DSN"与"端口写错"会长得一模一样） |
| AH | ★ 区分**"时点快照"与"现行指南"**，别一刀切 | `P0/P1-HANDOFF` 历史段落的 3307 **保留原样**（那是当时的事实，本仓口径是"时点快照+勘误表"）；但 `P1-HANDOFF` 的**「## 6. 怎么跑」**是照着抄就要能跑的**现行指南** ⇒ 必须改成 3317 | **"当时发生了什么"保留原样；"现在该怎么做"必须指向当前事实** |
| AC | ★★ **不要在一个项目里第一次使用某条 SQL 形态**（尤其当失败只给空消息时） | 我用 `INSERT ... SELECT` 让数据库把 `patient_id` 带进病历 —— 全仓（**含搬迁前带进来的代码**）**零处用过**这个形态，驱动的 `getOrBuildSql()` 那条路径没被验证过 ⇒ 仓颉侧必失败，而异常是 `SqlException: errorCode: 0`（**驱动把 MySQL 报错文本吞成空串**），同一条 SQL 用 mariadb 客户端手工重放却成功 | 改成「先读 `appointment` + 纯 `INSERT`」，不变量没变（`patient_id` 仍来自挂号单）。**先用项目跑熟的形态** |
| AD | ★★ **新增错误码必须同时补 `apiErrorSpec`**（否则一律 500） | 我用了 `EMR_LOCKED` / `EMR_NOT_LOCKED` / `VISIT_BAD_STATE` / `EMR_NOT_FOUND` 但没登记 ⇒ 落到兜底 `(500,…)` ⇒ "病历已锁定不能改"这种**正常业务拒绝**被报成服务端故障。★ 而**纯逻辑层测试抓不到**（直接调仓储、不过 HTTP 映射）—— 是端到端脚本抓出来的 | 补 `apiErrorSpec` 四条（409/409/409/404），并记住：**新错误码必须有走 HTTP 的用例** |
| AE | ★★ **`Duplicate entry` 先问"是不是我不该插第二次"** | 测试 fixture 连撞四次，我前三次都在**改 id 前缀**（治症）：根因是 `hSeedTriageDept` 是纯 `INSERT` 而我**同一 criterion 内重复调用** ⇒ 根因是**幂等性**，不是 id 撞车。修法：fixture 先清后插，且**只清自己会重复写的那几张表**（我第一版把 `appointment` 也清了 ⇒ 队列长度变 0） | 换 id 只是把碰撞推到更远。**幂等清理要只清自己会重复写的部分** |
| AF | **测试夹具必须自建并绑定自己的实体** | 我图省事复用既有的 `13800000001` 当患者账号，它绑的是 `patient_id=1`，而夹具用 700001 ⇒ "患者读自己的病历"全 404（**不是权限问题，是看的不是同一个人**）。另：预问诊 `session_id` 写了 67 字符而列是 `varchar(64)` ⇒ INSERT 静默被拒 ⇒ 预填全空 | 夹具**自建账号**并绑定自己的 id；夹具自己也要有**形状约束**（列长度） |
| R | **"碰巧对"的代码要把前提写成测试，而不是重写** | `parseDsn` 也混用字节/字符，但**恰好安全**（分隔符全是 1 字节 ASCII + `x+1` 恰好跳过它）；这个前提**没被写下来** | 不重写没坏的东西，但加 6 条含中文用户名/密码/主机/库名的 DSN 断言 —— 前提被破坏时立刻变红 |
| N | **`.ps1` 存盘必须带 UTF-8 BOM** | 我用 `UTF8Encoding($false)`（无 BOM）改写 `doc-counts.ps1`，PowerShell 按 ANSI 读 ⇒ 满屏乱码 + `意外的标记` 解析错 | 所有 `server/**/*.ps1` 统一 `UTF8Encoding($true)` |
| J | ★★ **"生成器"与"校验器"必须在同一契约下**（2026-10-07 的真实缺陷） | `create-admin` 约 **8.6%** 概率失败且**冒堆栈** —— `randCode(12)` 从 21 字母 + 5 数字里独立取值，**不保证成分**，于是自己的口令被**自己的**强度规则拒 | `randCode` 强制 1 字母 + 1 数字再整体洗牌；`createAdmin` 整体 try/catch + 重试一次。**加校验规则时必问：我们自己的生成器 / 默认值 / 夹具满足它吗？** |
| K | **改写"清单 / 白名单"时最容易漏掉"原本已有的项"** | 我扩容弱口令表（补 40 余条）时**漏掉了原有的 `admin123`** —— 是测试用例当场抓到（期望 400 拿到 201） | 补回并加齐同类变体。**改清单要"读原清单 → 增补"，不要"重写"** |
| I | **PowerShell 的 `MatchEvaluator` scriptblock 里必须用 `#` 注释** | 写 C 风格 `/* */` → `无法将"/*"项识别为 cmdlet` | 改 `#`。（同类：`.ps1` 文件本身也是 PowerShell 上下文） |
| AI | ★★ **"按今天过滤"的新规则会把固定日期的验收夹具整体判成过期**（2026-10-14 跨平台审计后） | 上游给号源加了可售谓词（`work_date >= 今天` + 科室/医生启用且归属一致）后，`accept` 从全绿变成 **466/497（31 项红）**，症状全是"扣号不生效、`remain_num` 不变、`响应 seq_no 与落库 seq_no 一致（0 == -1）`"—— 看起来像并发/回填出了大问题，实际一行 SQL 都没错 | 夹具日期**必须写死**（确定性），所以修法是给 `book()` 加 `today!` 注入口（`tryDeductSlot` / `findBookableSchedule` 上游已有同款），夹具显式传 `today: ACC_FIXTURE_DATE`（`acceptance.cj` 顶部两个常量）。⇒ **凡是新增"按今天过滤"的规则，都要同时给夹具留注入口**，否则回归会伪装成业务缺陷 |
| AJ | ★★ **"服务端自己知道的事实"必须能从接口读回来**（2026-10-14，跨端审计 F11） | 服务端会**滑动续期**（`principalByToken` 里 `expires_at = now + TTL` 回写、每天最多写一次），但 `/auth/me` **不回** `expires_at` ⇒ 各端只能拿登录那一刻的旧值倒计时：Android 在令牌**仍然有效**时把用户踢回登录页、并清掉预问诊恢复状态。**这不是客户端 bug**，是服务端少回了一个字段 | `/auth/me` 返回**续期后**的 `expires_at`（`Principal.expiresAt` 每次请求都回填，不依赖"这次是否真的写了库"—— 测试 24h 节流下会漏）；`auth-check.ps1` 新增"与登录响应一致且在未来"。⇒ **凡是服务端会在后台改变的状态，都要有接口能读到它当前的值** |
| AK | ★★ **"今天"这种环境事实不能靠客户端猜**（2026-10-14，跨端审计 F14） | 全项目 `today` 一律 `Asia/Shanghai`（`HOSPITAL_TZ_OFFSET_SECONDS`），但客户端拿**设备本地时区**拼 `work_date` ⇒ 设备时区不对或跨零点就查不到当天号源，现象是"App 说今天没号、网页有号" | `/health` 与 `/api/v1/health` 回 `today` + `timezone`；`accept` 的 AC-15 与 `tests\health-check.ps1` 同时钉住"等于 UTC+8 当天"（**不要**只断言"字段存在"——那在错误的时区实现下也绿）。⇒ **凡属"当前环境事实"（今天、时区、汇率、费率），服务端要主动发** |
| AL | ★★ **静态托管的前缀不能带尾斜杠**（2026-10-14 管理台接入时实测） | 轻舟 `static.cj` 的前缀守卫是"**余部要么为空、要么以 `/` 开头**"：`prefix="/admin/"` 时 `/admin/js/app.js` 的余部是 `js/app.js`（不以 `/` 开头）⇒ 一律 `next()` 透传 ⇒ **除 `/admin/` 之外所有资源 404**，而 404 体是**路由**的（`{"error":"Not Found","path":…}`）—— 看起来像"路由把静态路径抢了"，方向完全错 | 前缀写 `"/admin"`（不带尾斜杠）：子路径余部 `"/js/…"` 正常；裸 `/admin` 余部为空 ⇒ 被静态层按**目录**认领回 `index.html`（所以那条 `/admin → 302 /admin/` 的路由是**永不执行的死代码**，已删）⇒ `index.html` 里的资源**必须写绝对路径**（`/admin/css/…`），否则浏览器停在 `/admin` 时会去取 `/css/…`。另：`spaFallback=false`，避免打错的 js 回一段 HTML 让浏览器报 `Unexpected token '<'` |
| AM | ★ **仓颉的块注释可以嵌套** ⇒ 注释里永远不要出现 `/*` | 我在注释里写了挂载路径的 glob 写法（`/admin/**`、`js/*.js`），其中 `/*` 又开了一层块注释 ⇒ `error: unterminated block comment`，报错位置指到文件末尾，**看不出是注释的问题** | 注释里写"`/admin` 前缀下的所有资源"这种**不含 `/*` 的表述**。⇒ 同类坑：写路径/正则进注释时，先想"这里有没有 `/*`" |
| AN | ★★ **"用户指定的默认"与"运行时真正生效"是两个事实，不能只回一个**（2026-10-14 管理台） | 模型配置有 `is_default`（用户指定）。默认行被**停用**或**删除**后，运行时 `defaultOf()` 会退到"该类型第一条启用的行"—— 但接口只回 `is_default` ⇒ 页面出现**一行"默认"标记都没有、而 AI 确实在用某一行**的状态，用户永远找不到自己在用哪条配置（这正是 AJ 的又一实例） | 列表/新建/修改三处回显都带 `in_use`（由 `aiModelInUse()` 统一算，避免三处各写一遍分叉）；页面在 `in_use && !is_default` 时显示「生效中」并注明原因 |
| AO | ★★ **测试脚本的"自清"要覆盖它改过的**所有**状态，否则会出现"首跑红、复跑绿"**（2026-10-14） | `ai-model-check.ps1` 为了验证"同类型只有一个默认行"，把 `is_default` 抢到探针行上，删掉探针后**该类型就没有默认行了** —— 清掉了自己的行，却把"播种行不再默认"留在了库里。表现：第一次跑 3 项红、第二次全绿，**看起来像偶发**（最难查的一类假故障） | 清理段补一步"把默认位还给播种行"，并断言 `default_rows >= 2` + 夹具残留为 0。⇒ **夹具自清的验收标准是"跑完的库与跑前一致"，不是"我建的行没了"** |
| AP | ★★ **模拟器会自己息屏/上锁，"黑屏截图"不是应用崩了**（2026-10-16 管理台窄屏复验） | 息屏或锁屏时 `snapshot_display` 出的图是**全黑**（1320×2856、≈60 KB），此时所有 `uitest uiInput click` 都打空（我一度以为页面改坏了）；`power-shell timeout -o 3600000` 只挡**息屏超时**、挡不住**锁屏** | 用**文件字节数**判活（>100 KB 才算有内容）；恢复顺序：`power-shell wakeup` → 仍黑则 `uinput -K -d 18 -u 18`（电源键，注意它**是切换**：屏幕亮着按它就熄）→ `uitest uiInput swipe 660 2400 660 800` 上滑解锁 |
| AQ | ★★ **IME 弹出后注入的文本会被输入法吞掉**（同次复验） | 登录页：登录名 `zzcheck` 能填进去，紧接着点「口令」再注入 ⇒ 口令框**始终为空**；地址栏那次更早的表现是**开头 `http:` 被吃掉**（URL 成了 `//127.0.0.1:18096/admin`） | 输入前先把键盘收起来（点页面空白处），或直接用 `hdc shell "uinput -K -t <文本>"`；另：`click 1031 2618` **只在键盘弹出时**是"回车"，键盘不在时那个坐标是浏览器自己的工具栏（会打开标签页切换器） |
| AR | ★★ **静态文件改了却看到旧样式 ⇒ 先怀疑浏览器缓存，不是自己没生效**（2026-10-16） | `/admin/css/style.css` 的响应头只有 `ETag` + `Last-Modified`、**没有 `Cache-Control`**（`Invoke-WebRequest` 实测）；服务端已经吐出新规则（响应体含 `.table-wrap`），浏览器仍用旧 CSS ⇒ 我差点把改对的东西回滚 | 验证静态改动时**换一个 origin**（另起 `--port 18097` + `hdc rport tcp:18097 tcp:18097`，localStorage 也是按 origin 隔离的）或清缓存；**"刷新后没变"不能当结论** |

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
| ~~❌ 内存 Store 范式（科室/医生/病历）~~ | ★★ **2026-10-07 rev.7 已整体拆除** —— 实测它**在生产上从未接线**（零实例化/零 loadAll/零 flushToMysql/无写入口）⇒ `mem_store.cj` 与 `sql_recorder.cj` 删除，AC-4 重写为"范式唯一化"。见 [ADR-0001](../docs/adr/ADR-0001-号源与挂号独立MySQL路径.md) rev.7 | ~~`a4123e1`~~ |
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
