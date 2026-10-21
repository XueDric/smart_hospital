# 阶段交接合并稿（P0–P5）

> 本文件由 docs/P0-HANDOFF.md、P1-HANDOFF.md、P1-OPS-HANDOFF.md、P2-HANDOFF.md、
> P3-HANDOFF.md、P4-HANDOFF.md、P5-HANDOFF.md 七份阶段交接文档合并而成（2026-10-18）。
> 合并原则：只保留"当时交付了什么、怎么验证的、留下什么问题、为什么这么决策"，
> 过程性叙事与已被后续阶段推翻的中间结论删除；**现行操作指南原样保留**。
> 各阶段原始逐条明细可在 git 历史里查到。

## 总览

| 阶段 | 主题 | 交付要点（≤40 字） | 验收方式与结果 | 遗留项数 |
| --- | --- | --- | --- | --- |
| P0 | 立项与骨架 | ADR-0001、build.ps1、schema.cj、锁号原子自减、验收套件 | `selftest`（无需库）+ `accept <dsn>` 当时「通过 32 项，失败 0 项」；变异 1 项被抓 | 5（全部移交 P1） |
| P1 | 挂号闭环 + 鉴权 + HTTPS | 4 个挂号 REST、PBKDF2 令牌鉴权、自签 HTTPS | `accept` 当时 794 项（现基线 801）；压测 20/30/40/50 抢同数号源全部卖光；`auth-check`/`tls-check`/`rate-limit-check`/`p1-extra-check` 全绿 | 2 项运维（转 P1 运维交接）+ 5 条已知边界 |
| P2 | AI 分诊 | 危急征象兜底、验证层、预问诊 SSE、三态原因码 | `triagetest` 当时 108 项（现基线 150）；`accept` 当时 118 项；2 个 HTTP 脚本；6 项变异全被抓 | 6（原列 6 项，其中 1 项在本阶段完成） |
| P3 | AI 能力中心（配置底座） | 配置库驱动、密钥只存引用、Prompt/工具开关 | `selftest` 39 项；`accept` 184 项；变异 11/11 被抓 | 5（原列 7 项，2 项收尾解决） |
| P4 | 电子病历 + 运营看板 | 七段式病历、接诊状态机、只出聚合的看板 | `selftest` 43 项；`accept` 238 项；`emr-check` 54 项连跑三次一致 | 6（另有 3 条接线边界） |
| P5 | RAG 知识库 | 零向量库轻量 RAG、关键词兜底、接进分诊 | `accept` 442 项连跑 2 次；`kb-check` 45 项；`ai-live-check` 24 项 | 6 |

---

## P0 —— 立项与骨架

### 交付

| 文件 / 产物 | 内容 |
| --- | --- |
| `adr/ADR-0001-号源与挂号独立MySQL路径.md` | 号源与挂号走独立 MySQL 路径的架构决策（Accepted） |
| `server/build.ps1` | 构建脚本，产出 `build\hospital-server.exe` 与 `build/SOURCE-MANIFEST.sha256` |
| `server/src/schema.cj` | 建表 DDL（最小表集，见下） |
| `server/src/domain_booking.cj` | 锁号原子自减 + 幂等 |
| `server/src/db_bootstrap.cj` | 建库/连库/迁移引导 |
| `server/src/acceptance.cj` | AC-1…AC-6 验收套件（落点选 `src/`：验收测试要编进 exe 才能离线跑，`server/tests/` 放的是端到端 PowerShell 脚本） |
| `server/README.md` | 服务端说明与踩坑表 |

最小表集（当时 8 张，现 **16 张**，见 `server/src/schema.cj` 的 `TABLE_*`）：`schedule`★、`appointment`★（号源域业务状态，直接 SQL）、
`booking_idem`◆（幂等基础设施，仅 `BookingRepo` 写）、`department`/`doctor`/`patient`/`medical_record`
（基础数据/患者档案/病历；内存 Store 在 P1+ 落地，rev.7 又整体拆除）。

### 验证

| 项 | 结果 |
| --- | --- |
| 构建 + 自检（无需数据库） | `cd server` → `.\build.ps1` → `.\build\hospital-server.exe selftest` |
| 验收（连库） | `$env:DSN="mysql://hospital:hospital_dev_2026@127.0.0.1:3307/hospital"` → `check-db $env:DSN` → `accept $env:DSN`，实测「通过 32 项，失败 0 项」 |
| AC-1 | 同一 version 第二次扣减 0 行 |
| AC-2 | `remain_num=0` 时绝不负数 |
| AC-3 | 同 `client_token` 只出一单 |
| AC-4 | 本侧 7 张 vs 搬迁前 10 张零交集（🟡 部分：只做结构性验证） |
| AC-5 | 无脏单 |
| AC-6 | `visit_date` 快照 |
| AC-7 | 退号如实上报（`cancel()` 的 Bool 改为三态 `CancelOutcome`：Cancelled / SlotNotRestored / NotFound） |
| AC-8 | `booking_idem` 改名后可用（该表后来按 ADR rev.4 §7 第 7 条删除） |
| 变异测试 | 把 `AND version=?` 中性化为 `AND (version=? OR 1=1)`（保留参数个数）→ AC-1 报 3 条 `[FAIL]` |

三条验证边界（原文如实标注）：

1. **AC-1 不是并发测试**：仓库通篇无 spawn，它验的是数据库层原子性（并发安全的根因），真并发压测排到 P1；
2. **AC-4 只做结构性验证**；
3. 验收依据是源码哈希 `build/SOURCE-MANIFEST.sha256`，**不比产物哈希**（exe 的 SHA256 两次构建不同，manifest 相同；cjc 产物不逐字节可复现，见 ADR §5.1）。

教训（首次变异失败）：参数个数不匹配时 `bindSql` 抛异常、测试静默中断，一条 `[FAIL]` 都没打印；补 `section()` 异常兜底。
**失败必须被说出来，不能靠崩溃顺带表达。**

### 遗留

移交 P1 的 5 项入口（后由 P1 全部关闭）：

| # | 待办 | 去向 |
| --- | --- | --- |
| 1 | 轻舟 HTTP 路由 + 中间件 | P1 完成（`http_app.cj`） |
| 2 | 挂号 REST（排班查询/挂号/取消） | P1 完成 |
| 3 | 认证与三端角色（令牌 + PBKDF2 + 三端守卫，走 `server/src/auth_*.cj`） | P1 完成 |
| 4 | 并发压测 | P1 完成（`tests\stress-booking.ps1`，AC-9） |
| 5 | 内存 Store 补 AC-4 | P1 完成（`mem_store.cj` + 四层断言；P4 rev.7 已整体拆除） |

另两条未闭环的口径：AC-4 的"逐值比对"到 P1 才升级为真跑刷盘；`booking_idem` 最终被删除。

### 关键决策

ADR-0001 的六条约束（本阶段最重要的产出）：

1. **范围锁死 3 张表**：直接 SQL 只准 `schedule`/`appointment`/`booking_idem`，新增第 4 张须开新 ADR；已写成 `selftest` 断言（`isBookingDomainTable` / `isBookingInfraTable` / `isBookingOwnedTable`）；
2. **事务内禁止出站网络**（AI/HTTP）："调 AI 判断挂哪个科"再扣号是**禁止的设计**；
3. **绝不先 SELECT 再 UPDATE**，只以 `exec()` 的受影响行数为判据；
4. `remain_num > 0` 的条件**不能省**；
5. 重试上限 1–3（默认 2）——冲突多了要改架构，不是加大重试；
6. 挂号**绝不进离线队列**（brief §5.4），必须在线直连 + 强一致确认页。

其它决策：

- **`booking_idem` 加前缀**：搬迁前有同名 `idem` 表，P1 的整库刷盘 `replaceBatched("idem", …)` 会争表（ADR §4.3.2）。
- **ADR §4.3 拆两层**：业务状态（`schedule`/`appointment`）与幂等基础设施（`booking_idem`）分开，避免"锁死 3 张"的口径与实现打架（ADR §4.3.1）。
- **`selftest` 的 DDL 断言**：原写"DDL 条数 == 表数"，脆弱；改为"每张业务表都能在 DDL 里找到"。

> **勘误（rev.3，2026-10-07）**：①「通过 21 项」这类项数一路漂移 21→32→35→31，现值以 `tests\doc-counts.ps1` 实测为准；
> ②「AC-1：同一 version 第二次扣减必然 0 行」这条结论**已被推翻** —— 扣号策略改为**一次成功的原子自减**（去掉 version 乐观锁前置），见 ADR-0001；
> ③ 最小表集 7 → 8 张（7 → +2 鉴权 = 9 → −1 删 `booking_idem` = 8）；
> ④「P1 的入口」已不是未来时，P1 已推进多轮。

本机环境（时点值）：cjc 1.2.0 @ `C:\Users\ASUS\.cjenv\sdks\1.2.0\cangjie`（PATH 上的 1.1.3 旧版 @ `D:\Cangjie` 勿用）；
stdx @ `E:\cangjie\stdx\windows_x86_64_cjnative\static\stdx`；MariaDB 11.4.13 便携版 @ `127.0.0.1:3307`，
库/账号 `hospital`/`hospital`，开发口令 `hospital_dev_2026`（**上生产必须换**）；
启动 `mysqld.exe --datadir=E:\cangjie\mariadb\data --port=3307 --console`，停 `Get-Process mysqld | Stop-Process -Force`。

---

## P1 —— 挂号闭环 + 鉴权 + HTTPS

### 交付

| 文件 | 内容 |
| --- | --- |
| `server/src/http_app.cj` | HTTP 装配 + 中间件顺序 + 统一错误出口 + 挂号 REST |
| `server/src/http_common.cj` | `{ok,data}` / `{ok:false,error}` 响应形 + 错误码表 + 三端角色矩阵 `can()` / `requireCan` |
| `server/src/main.cj` | `serve` 子命令（端口 / bind / 开发态鉴权开关） |
| `server/tests/stress-booking.ps1` | 多进程并发压测（AC-9） |
| 令牌鉴权 | PBKDF2-HMAC-SHA256（100000 次迭代、16 字节随机盐）+ `auth_token` 有状态会话 |
| HTTPS | `server/new-tls-cert.ps1`（带 SAN 的自签证书）+ `serve --tls-cert/--tls-key/--tls-files` |

业务接口：

| 方法 / 路径 | 权限 | 说明 |
| --- | --- | --- |
| `GET /health` | 无 | 健康检查 |
| `GET /api/v1/schedules/:id` | 三端可读 | 排班详情（含 `remain_num` / `version`） |
| `GET /api/v1/schedules` | 三端可读 | 按 `department_id` / `work_date` / `limit` 筛选（收尾补） |
| `POST /api/v1/appointments` | 仅患者 | 挂号，幂等靠 `client_token` |
| `GET /api/v1/appointments` | 仅患者 | 我的挂号（`patientId` 一律取自令牌） |
| `POST /api/v1/appointments/:id/cancel` | 患者退自己的 / 管理员退任意 | 退号 |
| `POST /api/v1/admin/schedules` | 仅管理员 | P1 测试用；正式维护界面属 P4 |

鉴权接口：

| 方法 / 路径 | 权限 | 说明 |
| --- | --- | --- |
| `POST /api/v1/auth/login` | 无 | 换令牌 |
| `POST /api/v1/auth/logout` | 需令牌 | 吊销当前令牌 |
| `GET /api/v1/auth/me` | 需令牌 | 当前身份 |
| `POST /api/v1/admin/users` | 仅管理员 | 建账号；已存在 → 409（不静默复用） |
| `GET /api/v1/admin/users?login_name=` | 仅管理员 | 只回非敏感字段，**绝不回盐/摘要** |
| `POST /api/v1/admin/users/:id/password` | 仅管理员 | 重置口令，同时吊销该账号全部令牌 |
| `GET /api/v1/auth/sessions` | 需令牌 | 我的会话（不含 token） |
| `POST /api/v1/auth/sessions/revoke` | 需令牌 | 踢单台设备 |
| `POST /api/v1/auth/logout-all` | 需令牌 | 踢全部 |

权限矩阵（7 行，收敛在 `can()` 一处）：`view_schedule` 三端 ✅；`book` / `cancel_own` 仅患者；
`cancel_any` / `manage_schedule` / `manage_ai` / `manage_user` 仅管理员。
`manage_ai` / `manage_user` 是 2026-10-14 评审 B8 补的 —— 不复用 `manage_schedule`，避免"能改排班" = "能改 AI 提示词/建管理员"。
医生无写权限（接诊写病历属 P4），不预先发权。

### 验证

| 项 | 结果 |
| --- | --- |
| 并发压测（AC-9，走令牌） | 供不应求 20 请求 / 8 号 → 成功 8、409 ×12、余量 0；高压 50/10 → 成功 10、409 ×40、余量 0；供大于求 5/20 → 成功 5、409 ×0、余量 15。断言含余量守恒与"有效挂号单 == total_num" |
| 最终压测（去掉 version 前置后） | 20/30/40/50 抢同数号源**全部卖光**（最穷工况） |
| `authtest` | 17 项；三个公开向量钉住 PBKDF2：`pbkdf2("passwd","salt",1,64)`（RFC 7914 §11）、`pbkdf2("Password","NaCl",80000,64)`（RFC 7914 §11）、`pbkdf2("password","saltSALT",100000,32)` 与 .NET `Rfc2898DeriveBytes` 对拍；非法参数（iters<=0 / dkLen<=0）必须 fail closed 返回空，不得静默降级成 1 轮 |
| 防枚举 | 账号存在 + 口令错 473.9 ms、账号不存在 448.3 ms，比值 1.06（搬迁前未防护约 13 倍差） |
| 登录限流 / 锁定 | 5 次失败 / 15 分钟窗口 / 锁 15 分钟；锁定检查在 PBKDF2 之前（解冻期失败 t≈0.55s，锁定期拒绝 t≈0.02s，断言 <0.2s）；限流不是 oracle（admin 与 nobody 都是 401×4 → 429，计时比值 1.03）；登录名归一后 7 种写法全部 429 且库里只剩 1 份计数 |
| TLS（`tests\tls-check.ps1`） | SAN 8 个条目（DNS=localhost + 7 个 IP）；TLS 1.2 真校验（链 + 主机名）协商 Tls12；TLS 1.3 协商 Tls13；TLS 1.0/1.1 被拒（服务端侧 SSPI 失败）；反向：不在 SAN 的主机名不覆盖 ✅、用不同 CA 验证必须失败 ✅；明文打 TLS 端口失败 000；HTTPS 下登录 + 带令牌 `/auth/me` 200 |
| 绝不静默降级（4 条实测） | 证书不存在 FATAL exit=1；私钥不存在 exit=1；PEM 非法 FATAL exit=1；只给 cert 或只给 key 拒绝 exit=2；端口不会被误起成明文服务 |
| 测试总览（时点值） | `selftest` 51 项、`authtest` 17 项、`accept`（AC-1…AC-P4-8）当时 794 项（现基线 801）、`auth-check` / `tls-check` / `rate-limit-check`（9 节）/ `p1-extra-check`（连跑 3 次）全绿、`doc-counts` 与实测一致、手工冒烟 401/403/404/409/400/201/200 |
| 变异测试 | 扣号把 version 塞回 → AC 变红；退号把 version 塞回 → 8 项 FAIL |

> **勘误（§3.1 的结论被推翻）**：原写"少卖已修复（把 `MAX_BOOKING_RETRY` 2→3、加 `HTTP_BOOKING_RETRY=6`）"是**假的** ——
> 复查用"请求数 == 号源数"的最穷工况重测仍少卖（20→15、40→26，耗竭率 15%~50%）。
> **正确结论：根因是 `version=?` 乐观锁在每请求互相撞车时耗尽重试预算，重试再多也治不好；修法是去掉 version 前置条件、一次成功的原子自减（`remain_num > 0` 已足够防超卖）。**
> 同一根因还在镜像路径（`releaseSlot`）上重现：并发退号会**永久丢号源**，已同样去掉 version 前置。

### 遗留

| # | 待办 | 状态 |
| --- | --- | --- |
| 1 | 证书信任分发 / 换受信任 CA | ⚠ 运维项，见「P1 运维交接」§一。本机无受信任 CA、不能改系统信任库，且客户端尚未实现 ⇒ 客户端侧无法验证 |
| 2 | 证书轮换与到期监控 | ⚠ 运维项，见「P1 运维交接」§二。检查的一半已做（`tls-check.ps1` 第 [1] 段含有效期断言，到期即红）；**告警接入**需真机调度器 |

已知边界（如实标注，不当作已完成）：

| # | 边界 | 说明 |
| --- | --- | --- |
| 1 | 账号级锁定可被用于对**特定账号**做 15 分钟 DoS | 彻底消除要按 IP 限流 / 验证码，属 P2+ |
| 2 | `SLOT_NOT_RESTORED` 从未真正抛出过 | 记入待办 |
| 3 | 弱口令表是示例级 | 真正解法是外部字典，属发布/运维 |
| 4 | 令牌随机性依赖 `std.random` | 无法证实是 CSPRNG，故**不宣称**密码学安全 |
| 5 | `work_date` 只做形状校验（4-2-2） | `2026-13-99` 形状合法 → 200 空列表（已在测试显式断言这条边界） |

### 关键决策

| 决策 | 理由 |
| --- | --- |
| **并发压测必须起独立进程** | 仓库通篇无 spawn；并发真实形态 = 多客户端同时打同号源 ⇒ 起 N 个 `curl.exe`。ADR-0001 补验证边界：AC-1（P0，数据库层，原子性根因）+ AC-9（P1，端到端，N 真实并发成功数恰好等于号源数） |
| **去掉 version 前置，改一次成功的原子自减** | 乐观锁在"请求数 == 号源数"时互相撞车，重试预算耗尽仍少卖；ADR §8 复审触发第 1 条 = 耗尽率 > 1% 就要重估 ADR §3 方案 C（悲观锁 / 排队）。教训：**不是"调大重试就完事"** |
| **有状态令牌，不用 JWT** | 服务端存 token→user；停用账号 / 改口令可立即踢下线（无状态 JWT 做不到） |
| **有效期 30 天滑动续期 + `last_renew_at` 节流** | 每天最多写一次，避免每次请求都写库 |
| **鉴权开关用命令行参数，不用环境变量** | 本工具链仓颉 std 没有 `getEnv`/`envVars`（框架 `config.cj:17-21` 核对过），环境变量会**静默永远不生效**；且 `--prod` 与 `--dev-auth` 同传拒绝启动 |
| **默认只绑 `127.0.0.1`** | 轻舟 `app.serve(port)` 默认 `bindAddr="0.0.0.0"`；本阶段是明文 HTTP + 开发态身份头，联调才 `--bind 0.0.0.0` |
| **`principalOf()` 与 `can()` 解耦** | 从开发态头切到令牌后，业务逻辑与权限矩阵**一行未改**，唯一改点是 `principalOf()` 实参。解析优先级：① `Authorization: Bearer <token>` ② 开发态头（仅 `--dev-auth`，每请求打 `[DEV-AUTH]` 警告）③ 都没有 → 401 明确失败 |
| **口令强度校验强制在仓储层** | 设置口令入口有三个（建号 / 重置 / `create-admin` CLI）；放 HTTP 层则 CLI 那条会漏。`createUser` 与 `setPassword` 都调 `checkPasswordStrength` |
| **不要求特殊字符** | NIST 不建议；会把用户推向 `Password1!` 这类可预测写法 |
| **`UserFacingError` → 400 `VALIDATION_FAILED`** | 刻意不按消息字符串 `contains` 匹配（改一个字就静默失效） |
| **`setPassword` 先校验强度、再落库 + 吊销** | 否则弱口令请求会把用户**踢下线**（拿管理员令牌发一次弱口令请求即可 DoS） |
| **登录名归一：`trimAscii` + `toAsciiLower`** | 计数键是原文哈希、账号查找走 `utf8mb4_general_ci` + PAD SPACE ⇒ `Admin`/`aDmIn`/`admin␣␣` 可绕锁。用 `toAsciiLower` 而非 locale 感知 `toLower`（土耳其 I 问题，口径必须跨机器一致）；归一在一处定义 |
| **退号时把 `client_token` 置 NULL** | 只过滤 `cancelled` 不够：唯一索引仍被占 ⇒ INSERT 撞唯一键 500；MySQL 唯一索引允许多 NULL |
| **文档数字漂移用脚本对账，不再改数字** | 新增 `server/tests/doc-counts.ps1`（跑出实测值 → 与文档对账，支持 `-Fix`） |
| **仓库自管 devdb（端口 3317）** | 项目账号没有 `CREATE DATABASE`、root 口令未知；`server\devdb.ps1`（`start` / `stop` / `status` / `reset`）一键启停，数据目录 `server\devdb\data`（不入库），规格/口令/DSN 见 `DEV-DB.md` |
| **测试脚本统一由 `-Dsn` 派生** | 原来 DSN 与 `-MySqlPort`/`-MySqlDb` 是"同一事实存两份"，实测踩过"服务端写 A 库、脚本查 B 库" |

> **勘误（`server/README.md` §六「明确未做」5/5 过时）**：令牌鉴权（`c80e344`）、内存 Store（`a4123e1`）、
> 我的挂号/排班列表（`3c05497`）、HTTPS（`061ad0d`）、AI 分诊与预问诊（`bf87a4f`/`e5d2a33`）**全部已完成**，
> 照该节阅读会得出与现状相反的结论。处置照 P0 的"时点快照 + 勘误表"，并把"当前真实未做清单"指到别处，不再维护第二份会过期的清单。

> **勘误（端口）**：P0/P1 时点快照里的 `3307` 是当时真实在用的端口，**保留原样**；现行事实是本项目自管 devdb 在 **3317**（以 `docs/DEV-DB.md` 为准）。
> 区分标准：**"当时发生了什么"保留原样；"现在该怎么做"必须指向当前事实。**

---

### P1 运维交接（原 docs/P1-OPS-HANDOFF.md）

> 性质：P1 剩余清单里唯一没做的两项。**不是代码问题，而是部署/运维问题**，必须在真机做，判据与本机测试不同。
> 本机做不了的原因有三条：无受信任 CA；不能改系统信任库（需管理员权限且改系统状态，agent 不应擅自修改用户系统信任配置）；鸿蒙客户端尚未开发无法验。

#### 一、证书信任分发（换受信任 CA）

现状：`server/new-tls-cert.ps1` 生成**自签**证书（含 SAN，覆盖 `localhost` + 本机各 IP），客户端必须**显式信任**。
实测老问题：Windows 的 `curl` 走 Schannel，对自签证书 `--cacert` 支持不完整（`schannel: error 0x00000010`），
故 `tests\tls-check.ps1` 改用 .NET `SslStream` + 显式链校验 + 自解析 SAN。

判据 4 条：

1. 证书链到**受信任根**（不再 `UntrustedRoot`，去掉 `AllowUnknownCertificateAuthority` 后 `Build=True`）；
2. 主机名匹配（SAN 覆盖实际访问名/IP，`tls-check.ps1` 第 [2] 段）；
3. **不依赖 `-k`/insecure** 完成业务请求（`curl` 不带 `-k` 调 `/health` 返回 200）；
4. 客户端真机登录挂号（客户端未开发，**无法进行**）。

具体做法三选一：

| 方案 | 做法 | 备注 |
| --- | --- | --- |
| ① **院内 CA（推荐）** | 院内 CA 签发证书、SAN 填实际域名/IP，CA 根证书分发到客户端；服务端只换 cert/key，**代码零改动**：`server\new-tls-cert.ps1`（仅占位）＋ `.\build\hospital-server.exe serve <dsn> --port 8443 --tls-files "C:\ProgramData\smart-hospital\tls\tls.env"` | 首选 |
| ② 内网无 CA 但能装根证书 | 沿用自签流程，但把 `cert.pem` 作为根分发到客户端信任库 | 只解决"客户端不报错"，**不是真正公信力** |
| ③ 公网域名 + 公网 CA | 需真实域名与 80/443 可达 | 本机不具备 |

换证书注意事项：

- 证书路径尽量**纯 ASCII**（仓颉运行时无法接受含非 ASCII 的 `argv`）；仓库已改名 `E:\harmonyOS\smart_hospital`，部署到中文目录仍建议 `--tls-files` 指向 `%ProgramData%\smart-hospital\tls\tls.env`；
- 换证书后**必须重跑** `tests\tls-check.ps1`；
- `serve` 的 **fail-closed 不要动**（证书/私钥缺失或 PEM 非法一律拒绝启动，绝不静默降级明文，四条已实测）。

#### 二、证书轮换与到期监控

现状：有效期 **3 年**（`new-tls-cert.ps1` 生成时 +3 年），**靠人记**；到期那天服务照常启动
（TLS 握手时客户端报错），**没有预警**。本机做不了，因为监控价值在**长期运行 + 告警通道**。

本机已完成的一半：

```powershell
.\server\tests\tls-check.ps1 -Cert "C:\ProgramData\smart-hospital\tls\cert.pem" -Host_ 127.0.0.1 -Port 8443
```

第 [1] 段断言"当前时间在有效期内"并打印 `NotBefore → NotAfter`，**exit code 非 0 = 已过期或即将过期**，可直接进 CI/监控。

仍需运维做的 4 条：

1. 把检查接进调度器（**每日一次**），失败**告警到人**；
2. **提前 30 天**开始告警（3 年期证书），告警阈值可配，并用"快过期"的测试证书验证过会响；
3. **轮换流程**：新证书签发 → 部署 → 重启 → 复验 → 旧证书下线，在非生产窗口**演练过至少一次（含回滚）**；
4. **私钥分发与保存规范**：私钥不入库，`.gitignore` 已排除 `*.pem` 与 `server/certs/`，不进聊天工具，有访问控制。

> 注：本例程检查的是"当前是否在有效期内"，**不区分**"还有 2 年"与"还有 2 天"；要提前告警需调度侧按 `NotAfter` 算差值，或把阈值检查加进 `tls-check.ps1`（属代码改动）。此处如实标注为"未做"。

#### 三、方法论（为什么单独拆出这两项）

P1-HANDOFF §9 曾把剩余项混在一张表里，其中代码类已全部完成、运维类本机不可验证。
混在一起的风险是"剩下的都不太重要"的错觉 —— 而证书信任恰恰是"HTTPS 到底有没有用"的分水岭
（**自签 + 不信任 ≈ 只防了被动窃听**）。

---

### P1 运行手册（原 P1-HANDOFF.md 第 6 节「怎么跑」，原样保留）

```powershell
cd server
.\build.ps1

# 1) 口令/令牌原语自检（不需要数据库）
.\build\hospital-server.exe authtest

# 2) 建第一个管理员（引导入口，不经 HTTP；口令只打印一次）
#   ⚠ 端口与口令**以 docs/DEV-DB.md 为准**：本项目自管 devdb 是 **3317**
#     （下面写 3317 是为了"照抄即能跑"；若你的实例改了端口，改这里）
.\build\hospital-server.exe create-admin "mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital"

# 3a) 启动 **HTTPS**（推荐；先生成证书）
.\new-tls-cert.ps1
.\build\hospital-server.exe serve "mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital" `
    --port 8443 --tls-files "C:\ProgramData\smart-hospital\tls\tls.env"

# 3b) 或启动明文 HTTP（仅限可信本机/内网；启动时会打印明文警告）
.\build\hospital-server.exe serve "mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital" --port 8091
```

```powershell
# 另开一个终端
curl.exe -s https://127.0.0.1:8443/health --cacert "C:\ProgramData\smart-hospital\tls\cert.pem"
# ⚠ Windows 的 curl 走 Schannel，对自签证书的 --cacert 支持不完整（见 §5 注释）；
#   要严格验证证书请用 .\tests\tls-check.ps1（走 .NET SslStream）。

# 登录换令牌
curl.exe -s -k -X POST -H "Content-Type: application/json" `
  -d '{\"login_name\":\"admin\",\"password\":\"<上一步打印的口令>\"}' `
  https://127.0.0.1:8443/api/v1/auth/login

# 用令牌调业务接口
curl.exe -s -k -H "Authorization: Bearer <token>" https://127.0.0.1:8443/api/v1/auth/me

# 自动化测试
$env:HOSP_ADMIN_PW = "<口令>"
.\tests\auth-check.ps1     -Base http://127.0.0.1:8091 -AdminPw $env:HOSP_ADMIN_PW
.\tests\stress-booking.ps1 -Base http://127.0.0.1:8091 -Tokens 50 -ScheduleTotal 10 -AdminPw $env:HOSP_ADMIN_PW
.\tests\tls-check.ps1      -Cert "C:\ProgramData\smart-hospital\tls\cert.pem" -Port 8443
```

> ⚠ `serve` 是**阻塞**的；`stress-booking.ps1` 会**清空业务表**后再造数据。
> 脚本**互不依赖执行顺序**（各自夹具自建自清）。
> 📌 这句话在 2026-10-07 被第三份复查**证伪过一次** —— `auth-check.ps1` 的计时段会把
> `admin` 锁死却不清限流状态，导致它**第二次跑必失败**、也会连累后续 stress/tls。
> 已修（见 §6.5.9），现在**实测连跑两次 + 紧接着跑 stress 都正常**。

---

## P2 —— AI 分诊

### 交付

| 文件 / 端点 | 内容 |
| --- | --- |
| `src/triage_redflag.cj` | 危急征象兜底（纯规则保险丝）：词表 + 否定判定 + 共现升级；不碰库、不调模型 |
| `src/triage.cj` | 科室判定 + **验证层** + 结论装配 |
| `src/triage_test.cj` | 纯逻辑自检（`triagetest` 子命令，60 项起） |
| `src/acceptance_triage.cj` | AC-P2-1…4（分诊） |
| `tests/triage-check.ps1` | 分诊 HTTP 端到端 |
| `src/previsit.cj` | 问诊槽位静态表 + 会话状态机 + SSE 帧构造 + 结构化问诊单 |
| `src/schema.cj` | 新增 `previsit_session`（**第三类表**） |
| `GET /api/v1/previsit/stream` | 开新会话 + **流式**吐第一轮追问（对话文本） |
| `POST /api/v1/previsit/answer` | 提交一项答案 → 返回**结构化业务值**（非流式） |
| `GET /api/v1/previsit/:id` | 取问诊单（非流式） |
| `tests/previsit-check.ps1` | HTTP / SSE 端到端（含帧格式与越权） |

分诊接口：`POST /api/v1/triage`（权限 `Action.Book`，即患者），请求 `{ "chief_complaint": "咳嗽三天有痰" }`。

原因码（稳定、可断言，与给患者看的文案分离）：`RED_FLAG`（转急诊，不给任何科室推荐）、`OK`（推荐且已验证有号）、
`ALTERNATIVES`（首选没号/不存在，但给出有号的备选）、`NO_BOOKABLE`（该科没号且全院无号）、
`NO_SUCH_DEPT`（规则认出的科室本院未开诊且全院无号）、`NEED_CLARIFY`（认不出主诉，不猜）、
`NO_COMPLAINT`（主诉为空/太短，不猜）。

### 验证

| 层 | 命令 / 方法 | 结果 |
| --- | --- | --- |
| 纯逻辑 | `hospital-server.exe triagetest` | ✅ 108 项（分诊 + 预问诊；不碰库、不调模型） |
| 库级 | `hospital-server.exe accept <dsn>` | ✅ 118 项（含 AC-P2-1…6） |
| HTTP 分诊 | `tests\triage-check.ps1` | ✅ 全绿（权限/入参/兜底/验证层/形状/截断/越权） |
| HTTP 预问诊 | `tests\previsit-check.ps1` | ✅ 全绿（SSE 帧/多轮/业务值/越权） |
| 变异 | 6 项 | ✅ 全部被抓住（② 经补用例后） |
| 对账 | `tests\doc-counts.ps1` | ✅ 文档数字与实测一致（含 `triagetest` 与端点数） |

变异测试清单（证明测试真的在守）：

| # | 变异 | 结果 |
| --- | --- | --- |
| ① | 危急征象保险丝失效（`detectRedFlag` 恒 false） | ✅ accept 3 FAIL |
| ② | 验证层 `remain_num > 0` → `>= 0` | ⚠ **首次未被发现** → 补"约满"工况后 2 FAIL |
| ③ | 日期边界失效（过期排班也算可用） | ✅ accept 2 FAIL |
| ④ | 否定判定失效 | ✅ triagetest 10 FAIL |
| ⑤ | 否定窗口退回字节空间 | ✅ triagetest 6 FAIL，报 `Invalid utf8 byte sequence` |
| ⑥ | `guessDepartment` 退回裸 `contains` | ✅ triagetest 6 FAIL |

> **勘误（§2.4 的时点快照）**：原文写"`source` 目前**只有** `rules`、刻意不设 `none`" —— 这是 P2 时点的取值；
> P3 收尾接通真模型后，取值已扩为 `model` / `rules` / `model:invalid`，见 P3 与 `docs/FRONTEND-INTEGRATION.md`。

### 遗留

| # | 项 | 阻塞于 / 去向 |
| --- | --- | --- |
| 1 | **接入真模型**（`source: "model"`） | **Q6 合规评估**（主诉属敏感信息）——P3 收尾已接通 |
| 2 | 词表的**临床完备性** | 需临床输入；当前是**示例级**，文件头已写明"不是临床完备集" |
| 3 | ✅ ~~预问诊**多轮采集**的流式~~ | **本阶段已完成**（见"交付"）；对话文本可流式、**结论不可**（故该条保留在此仅作历史记录） |
| 4 | 分诊**命中率**回写、`converted=1` 数据闭环 | P3（brief 创新点⑤） |
| 5 | 分诊结论**落库审计** | 目前只进服务端日志；P4 已建 `triage_stat`（不含主诉） |
| 6 | **RAG**（知识库检索增强） | P5 已完成 |

其中 1 曾是**唯一的硬阻塞**（合规），2 需要外部输入，3–6 属后续阶段 —— 它们接上时，保险丝 / 验证层 / 三态**一行不用改**。

### 关键决策

| 决策 | 理由 |
| --- | --- |
| **只做"工程纪律"，不接真模型** | brief §2.2 的 8 个创新点里，②先取证后结论 / ④全链路可观测 / ⑦模型无关 + 优雅降级，**本质是工程纪律而非接大模型**，且是最容易出安全事故的部分；接模型只需替换 `guessDepartment` 一个函数 |
| **绝不给"没有号"的推荐（验证层）** | 患者拿着推荐去挂号发现没号，**比不给推荐更坏**。实现是 `WHERE d.name = ? AND s.enabled = 1 AND s.remain_num > 0 AND s.work_date >= ?` 四个条件缺一不可：科室不存在 / 排班停用 / 已约满 / 已过期 |
| **"今天"由调用方传参，不在 SQL 里 `CURDATE()`** | 后者会让测试依赖数据库时区、偶发变红 |
| **危急兜底做三层（高危词 / 否定 / 共现）** | 中文没有词边界，裸 `contains` 会误报；把没病的人赶去急诊与漏报同样是伤害 |
| **词表刻意不收泛化词**（`疼痛` / `发烧`） | 单独出现绝大多数不是急症，收进来会让红牌率飙到不可用 |
| **结论非流式** | 分诊结论是**业务值**（要拿它去挂号）；流式会让客户端拿着"推荐心内科"去挂号、随后又变成"呼吸科" |
| **`red_flag_evidence` 不进响应** | 给患者看是复述；给攻击者看则暴露词表结构（可试探绕过）。只进服务端日志 |
| **超长主诉按字符截断 + 上报 `truncated`** | `String` 下标是**字节**偏移，按字节切会撕裂汉字 ⇒ 非法 UTF-8 ⇒ 500 |
| **字节/字符运算全部收口到一处** | 新增 `redFlagRunes` / `redFlagWindowBefore` / `redFlagCharToByte` / `redFlagByteToChar`（不在字符边界返回 -1 拒绝）/ `redFlagIsNegatedAt`；`guessDepartment` 复用同一套（不再自己写 `seg.contains(kw)`） |
| **对话文本流式、业务值一次性** | brief §5.2：追问的话流错了患者再问一次无害；问诊单字段流错了可能已写进病历草稿 —— **那是医疗记录污染**。`POST .../answer` **刻意不用 SSE**（"已完成 3/6"是业务值） |
| **`previsit_session` 是第三类表** | 它既不是号源域也不是内存 Store 的配套域；`selftest` 于是从"业务表 6 + 鉴权表 3"改成**四个分项 + "四类互不重叠且并集 == ALL_TABLES"**，加表忘了归类会立刻变红 |
| **两档保留阈值** | 未采完会话 TTL 30 分钟（患者中途放弃、无恢复入口）；已完成问诊单不设 TTL，只压上限 50 条（是**患者档案素材**）。两者都在 `create()` 里顺手调用（照 `pruneTokens`/`pruneAttempts` 的既有模式） |
| **`PrevisitRepo.answer` 的 UPDATE 必须带 `patient_id`** | 复查判断"不可利用"是对的（`patient_id` 建表后从不更新），但安全性依赖两步之间的**隐含前提**是脆的 ⇒ 让这条 UPDATE **自己**就是安全的 |
| **`previsitParseForm` 保留"不抛异常"但加日志，只打前 200 字符** | 只读操作不该 500；但静默会让"我明明答了怎么是空的"查不出原因。`form_json` 含既往史/过敏史，打全量等于把病历抄进日志（日志的访问控制通常比库弱） |

> **勘误（`server/README.md` §六 5/5 过时）**：令牌鉴权 / 内存 Store / 我的挂号与排班列表 / HTTPS / AI 分诊与预问诊
> 五条**全部已完成**，逐条加勘误表并保留原条目为历史记录；顺带修了"文件头那句「P0 阶段交付」"（L3）与根 README 的**重复计项**（预问诊被 P2 与 P4 两处认领）。

---

## P3 —— AI 能力中心（配置底座）

### 交付

| 文件 / 端点 | 内容 |
| --- | --- |
| `src/ai_settings.cj` | 配置项静态白名单 + 运行时选项与校验 + 仓储（含缓存失效）+ 脱敏视图 |
| `src/schema.cj` | 新增 `ai_setting`（**第五类表**） |
| `GET /api/v1/admin/ai/settings` | 读配置（仅管理员，秘密项脱敏） |
| `PUT /api/v1/admin/ai/settings/:key` | 改一项（仅管理员，写后即生效） |
| `DELETE /api/v1/admin/ai/settings/:key` | 删一项（回到默认值） |
| `GET /api/v1/admin/ai/prompts` | 读三个 Prompt 模板（正文原样回显 —— 不是机密，管理员要能核对） |
| `PUT /api/v1/admin/ai/prompts/:name` | 改模板（**缺必需占位符直接拒**） |
| `DELETE /api/v1/admin/ai/prompts/:name` | 恢复默认模板 |
| `GET /api/v1/admin/ai/tools` | 六个 AI 工具的开关状态 |
| `PUT /api/v1/admin/ai/tools/:name` | 开关某工具（只接受 `true`/`false`） |
| `acceptance_ai.cj` | AC-P3-1…4 |

三处 Prompt 都对应本项目**已有的一处真实逻辑**（接模型时要替换/增强的点）：

| Prompt | 对应现有逻辑 | 必需占位符 |
| --- | --- | --- |
| `dept` | `guessDepartment()`（关键词规则） | `{主诉}` `{候选科室}` |
| `previsit` | `previsitAssistantLines()`（规则话术） | `{主诉}` `{已有信息}` `{待问项}` |
| `redflag` | `detectRedFlag()`（纯规则保险丝） | `{主诉}` |

### 验证

| 层 | 结果 |
| --- | --- |
| `selftest` | ✅ 39 项（表集分类扩到五类 + 两条否定断言） |
| `accept` | ✅ 184 项（含 AC-P3-1…6 + 数值闸门 + 占位符/工具开关断言） |
| `triagetest` | ✅ 当时 108 项（现基线 150） |
| `previsit-check.ps1` | ✅ 全绿（第 [8] 节 34 项 P3 HTTP 断言，含数值写入闸门） |
| 变异测试 | ✅ 11/11 被抓住（含"分派改回 `match` + String 常量 ⇒ 两条断言变红"） |
| `doc-counts` | ✅ 文档数字与实测一致（AC 上限扩到三套体系） |

> **勘误（"仍未接真模型"）**：该结论**已被推翻** —— P3 收尾接通了 `ai_call.cj` + `ai_triage.cj`，
> 配置底座**真的有人消费**了；合规口径见 `docs/Q6-合规决策记录.md`（2026-10-17 起演示环境默认开启 + `builtin:demo`，生产必须置回 0 并轮换密钥，主诉会出站给第三方）。

### 遗留

| # | 边界 | 说明 |
| --- | --- | --- |
| 1 | **没有配置变更审计表** | 只进服务端日志（`updated_at` 落在行上，但"谁改的"没记） |
| 2 | **单实例验证** | 缓存失效在多实例下只能靠 TTL 收敛，**未被实测**（本机单实例）；已在注释里写明理由与代价 |
| 3 | **工具开关只是"机制"，没有派发** | 工具执行依赖出站模型调用；接上时派生前查 `aiToolEnabled()` 即可，接入点已备好 |
| 4 | **Prompt 模板只存不用** | 拼 prompt 的地方目前仍是规则/硬编码；接模型时改成 `PromptRepo.body()` + 变量替换 |
| 5 | **回显的 endpoint 是脱敏后的 host** | 加 `redacted` 字段告知；但 `options()` 内部用的是**完整 URL** —— "回显脱敏"与"内部可用"是两条路径，不要以为配置里只存了 host |

（原 §六还有两条至此已解决：~~仍未接真模型~~、~~Prompt 模板 / 工具开关落库~~ —— 后者落在同一张 KV 表、共用同一套缓存失效。）

### 关键决策

| 决策 | 理由 |
| --- | --- |
| **密钥只存引用，不落地库** | brief §5.3 点名的安全回归风险："改成 DB 驱动时把密钥写进库是倒退"；库里只存 `env:SMART_HOSPITAL_AI_KEY` / `file:C:\ProgramData\...\ai.key` |
| **`validateKeyRef()` 只放行两种形状，且不止判前缀** | 只判前缀的话 `env:sk-abcdef...` 就能把密钥存进库、同时满足前缀要求，等于整条约束不存在。被拒形状含裸密钥、`env:` + 密钥本体、变量名不以字母/下划线开头、含非法字符、不含任何分隔符的"路径"、带密钥的 URL |
| **三层断言（一层比一层硬）** | ① 合法引用能存、9 种非法形状全被拒；② 被拒的值**真的没进库**；③ 全表兜底扫描 —— 任何一行的值都不得是"像密钥"的长随机串（防将来有人加别的写库路径绕过 `put()`） |
| **用 KV 表而非"一列一项"** | AI 配置项随模型协议演进增删；一列一项 ⇒ 每次加参数都要 DDL 变更 + 迁移 |
| **改配置零重启：写库 → `invalidate()`（`cacheAt` 置 0）→ 下次读重新查库** | 不"把新值塞进缓存"：多实例/并发写下那容易与库不一致；置 0 = **永远以库为准** |
| **缓存仍保留 5s TTL** | 多实例收不到别人的失效通知，只能靠 TTL 收敛；本机单实例不触发，但"不能因此不写"，否则上多实例就是静默的正确性缺陷 |
| **`insecureTrustAll` 不做成配置项** | 它是"仅本机开发跳过证书校验"的危险开关，**不该有运行时被改开的路径**；只能由启动参数决定。这是**刻意的遗漏** |
| **`ai.key_ref` 不进 `AiRuntimeOptions` 的路径字段** | 引用在装配时才解析 ⇒ "库里存引用、本体在环境/文件"这条边界在**类型上**就不会被混 |
| **数值类配置写入即校验（`numMin`/`numMax`）** | 原来只有 `key_ref` 写入即校验，数值项"写了不管、读时 `parseInt64Or` 静默回落" ⇒ 回显与生效值不一致；更糟的真实时序：库里越界 `9999`（正确地给 `enabled=false`）被"改成" `abc` 后 `enabled` **反而翻成 true** —— 一个写错的编辑把报警变成绿灯。空值**显式例外**（表示回默认） |
| **回显一律给"生效值" + `is_default` 字段** | 原来回显原始值（空 = 没设），而生效值是默认值，管理员会以为"这项没配" |
| **"是否采完"用 `JSON_LENGTH(JSON_KEYS(form_json))` 并 `IFNULL(...,0)`** | `LIKE '%槽位名%'` 会被**答案内容**影响（一个只答 1 项的会话永远不被压实，存储上限可被对抗性绕过）；`JSON_LENGTH(''或坏 JSON)` 返回 NULL ⇒ `getInt` 抛异常 ⇒ 一条坏数据能升级成"整个预问诊不可用"（`create()` 里跑） |
| **工具开关"只有明确的 `1` 才算开"** | 反过来（"不是 0 就算开"）会让写坏的值变"开着" = **静默放宽**；从严的失败方向是"工具被关掉"，可见、可查、无害 ⇒ 与 ADR / 限流那几处的取舍一致：**失败方向选安全的那侧** |
| **必要时才依赖 DB 高级特性** | 改用 JSON 函数与早前"不依赖 DB 高级特性"的偏好方向相反，但正确性 > 可移植性，且本来就用 JSON 语义存 `form_json`，不新增约束面（理由已写进代码注释） |

两个语言/工具链陷阱（都已加闸门）：

- ★★ **`match` 的 `case` 里写 String 常量会被当成"绑定变量"（catch-all）**，按值比较根本不发生 ⇒
  `promptDefaultBody(PREVISIT)` 一直返回 `dept` 的模板，**不报错、不崩溃，只是返回错的数据**。
  被"默认模板必须含齐自己的占位符"这条断言抓出来；改成 `if (name == 常量)`，并新增"三个默认模板两两不同"直接守这个陷阱。
- **`asXxx()` 在类型不符时是抛异常，不是返回 None** ⇒ `{"enabled":"yes"}` 直接 500。
  读用户输入必须先 `is JsonBool` 判类型再取值，由调用方给准确 400。

`create-db` 的真问题（第八份复查）：建出来的库**同一个账号用不了** —— 业务账号是 `GRANT CREATE ON *.*`（只能建库）
+ 按库逐个授 `ALL PRIVILEGES`，所以能 `CREATE DATABASE` 但对新库没有任何权限。
修法：`ensureDatabaseUsable()`（探测 → 自助授权 → 还不行就**明确报"已建好但用不了"** + 可复制的 root 命令 + exit=2）+ 新增 `--admin-dsn`（带 `GRANT OPTION`，建库 + 授权 + 探通一步到位，**允许不带库名**）。
**不许把"不可用"报成"就绪"。**

探可用性错了三次才定下来（都是"探错了能力"）：`CREATE TABLE` 探测表 → `CREATE ON *.*` 是全局的，新库上永远允许 ⇒ 必然误报"可用"还留垃圾表；
对"已存在的应用表 ALTER" → 全新库里没有应用表 ⇒ 管理员明明授好权也报"用不了"；
最终 `CREATE TEMPORARY TABLE`（零残留）+ 对已存在应用表 `ALTER ... ENGINE=InnoDB`（幂等改写）**两者都必须过**。
教训：**"探测"必须探"我们真正需要的那件事"，而不是一件相关但更弱的事。**
另：授权语句**不要硬编码 host** —— 同一个 DSN 可能被认成 `user@localhost` 或 `user@127.0.0.1`，一律用 `CURRENT_USER()` 拼授权语句。

---

## P4 —— 电子病历 + 运营看板

### 交付

数据层：

| 文件 | 内容 |
| --- | --- |
| `src/domain_emr.cj` | 七段式病历模型 + `MedicalRecordRepo`（**直接 SQL**）+ 接诊状态机 `VisitRepo` |
| `src/dashboard.cj` | 运营看板仓储（**只出聚合**；指标口径与"为什么不给某些维度"写在文件头） |
| `src/triage_stat.cj` | 分诊结论留痕（**签名里没有主诉参数** —— 类型层面就存不进敏感文本） |
| `src/schema.cj` | 新表 `triage_stat`；`medical_record` 加 `updated_by` + **存量库补列迁移** |

接口层（`src/http_p4.cj`，18 个端点）：

```
GET  /api/v1/doctor/visits                      接诊队列（只含自己的号、不含已退号）
POST /api/v1/doctor/visits/:id/start            开始接诊（booked → visiting）
POST /api/v1/doctor/visits/:id/finish           完成就诊（★ 要求病历已锁定）
POST /api/v1/doctor/visits/:id/no-show          标记爽约
GET  /api/v1/doctor/visits/:id/record           读病历（无则给七段骨架）
PUT  /api/v1/doctor/visits/:id/record           存草稿（幂等 upsert；可带问诊单预填）
POST /api/v1/doctor/visits/:id/record/lock      提交锁定（校验必填段）
POST /api/v1/doctor/visits/:id/record/reopen    解锁（**仅管理员**）
GET  /api/v1/medical-records                    我的医疗档案（列表，无正文）
GET  /api/v1/medical-records/:appointmentId     某次就诊的病历（患者只读自己的）
GET  /api/v1/admin/dashboard                    运营看板（仅管理员）
```

权限矩阵（仍收敛在 `can()` 一处）：

| 动作 | 患者 | 医生 | 管理员 |
| --- | --- | --- | --- |
| `query_own_medical_record` | ✅ | ✅ | ❌ |
| `write_own_medical_record` | ❌ | ✅ | ❌ |
| `manage_visit` | ❌ | ✅ | ❌ |
| `view_dashboard` | ❌ | ❌ | ✅ |

### 验证

| 层 | 结果 |
| --- | --- |
| `selftest` | ✅ 当时 43 项（现基线 51 项） |
| `accept` | ✅ 238 项（P4 净增 54：AC-P4-1 病历锁定 / AC-P4-2 状态机 / AC-P4-3 看板隐私 / AC-P4-4 统计不落敏感文本；rev.7 后 AC-4 由 14 项精简为 6 项） |
| `emr-check.ps1` | ✅ 54 项全绿，**连跑三次一致（exit 0）** —— 权限 / 队列 / 状态机 / 七段式 / 患者侧 / 越权 404 / 预问诊预填 |
| AC-4（**范式唯一化**，rev.7 重写） | ✅ 6 项通过（分类 / 号源域锁死 / 搬迁前零交集 / 反向有数据） |
| 其余 5 个 HTTP 脚本 + stress | ✅ 全绿 |
| `doc-counts` | ✅ 一致（端点计数脚本本身也修了两个缺陷：只认 `del(` 漏 `delete(`、只扫 `http_app.cj` 漏 `http_p4.cj` —— 实测 27+18+…=81 个 HTTP 路由） |
| 变异测试 | ✅ 拆掉"锁定后不可改"的守门 ⇒ `AC-P4-1` 的 ⑤ 立刻变红 |
| 卫生检查 | ✅ 17 个 `.ps1` 全带 BOM 且语法 0 错；`.cj` 注释全配平；文档链接 153 条全通 |

> **勘误（三条）**：① `MEM_TABLES` 由 4 张（rev.5）→ 3 张（rev.6）→ 内存 Store **整体拆除**（rev.7）；
> ② `department`/`doctor`/`patient` 的归属从"内存 Store 范式"改为**基础数据域（直接 SQL 读）**；
> ③ 出错提示里的端口 `3307` 已作废，正确做法是**从 `cfg` 派生**实际端口（本项目自管 devdb 是 3317）。

### 遗留

| # | 边界 | 说明 |
| --- | --- | --- |
| 1 | ★ **基础数据域没有写入端点**（2026-10-21 补记：现只剩 `patient`） | `department`/`doctor`/`patient` 是直接 SQL 读；记录这条边界时**没有任何端点能建科室/医生/患者**（靠人工 SQL 维护）。P5 的 `bb0e792` 已补上科室/医生管理端 CRUD（`server/src/http_base.cj`），本条现在只对 `patient` 成立。这是 rev.7 拆掉内存 Store 后**新记录**的边界（原先被"内存 Store 范式"这个说法掩盖了） |
| 2 | ~~没有病历修订历史~~（**已补**） | 记录此边界时只记 `updated_by`；现已有 `medical_record_revision` 表 + `…/record/revisions[/:version[/diff]]` 三个只读端点 + `tests/revision-check.ps1` |
| 3 | **看板未做"调用耗时/趋势对比"** | 真模型已接入 ⇒ `ai.model_calls` 是真实分布（`model`/`rules`/`model:invalid`）；仍未做**耗时**统计（`elapsedMs` 已能测，但未入库） |
| 4 | **未做小样本抑制（k-匿名阈值）** | 已不提供年龄/性别维度，但科室维度在小科室下仍可能间接暴露就诊人数 |
| 5 | **接诊队列无分页游标** | 只有 `limit`（上限 500）；跨科室/跨日的大列表需要游标 |
| 6 | **未做"爽约"的自动判定** | `no-show` 是医生手工标记；"到点未接诊自动爽约"需要定时任务 |

另 3 条"接线边界"（第十份复查，见下文关键决策）：`readTimeout` 配 3 秒实际 30 秒兜底、`ca_bundle_path` 不支持（写入即拒）、
`max_concurrent` 的容量**不随配置变**（启动后首次出站时定下）。

（原 §六另两条已解决：~~三张表仍在内存 Store 且生产不刷盘~~ → rev.7 整体拆除；~~未接真模型~~ → P3 收尾。）
预问诊**刻意仍不调模型**（结构化槽位由规则产出更稳），合规决策见 `docs/Q6-合规决策记录.md`。

### 关键决策

| 决策 | 理由 |
| --- | --- |
| **`medical_record` 移出内存 Store（ADR-0001 rev.6）** | ① 本仓已为同类数据判过一次（P2 把 `previsit_session` 排除在内存 Store 外，理由"它是医疗数据必须立刻持久化"），而病历装的是诊断与处理意见、比问诊单**更**典型；② 内存 Store 在**生产路径上从未刷盘**（`main.cj`/`http_app.cj` 完全不引用 `MemStore`，`flushToMysql()`/`loadAll()` 的生产调用点为零）⇒ 若病历走内存 Store，"医生写病历"的实际效果是**只写进程内存、永不落库**。对科室/排班是可补的工程债，对病历是**数据丢失** |
| **锁定即不可改，`lock` 用条件 UPDATE**（`WHERE status='draft'`） | "先查再写"在并发下会双写成功；条件 UPDATE 的**影响行数**就是判据（与号源扣减同一手法） |
| **"完成就诊前必须已锁定病历"写进同一条 UPDATE 的 `WHERE`** | 否则"先查病历再改状态"在并发下会漏 —— 判据与写入必须是同一个原子动作 |
| **患者归属只从 `appointment` 派生**，不接受请求体传入 | 请求体里的 `patient_id` 最容易被篡改；派生后"病历的 patient_id"与"挂号单的 patient_id"不可能不一致 |
| **必填段只设「诊断」与「处理意见」** | 真实门诊里既往史/过敏史允许写"无"或留空，但没有诊断的病历不是病历；七段全必填会逼医生乱填。由 `emrSections()` 单一来源给出 |
| **管理员不能写病历** | 病历最要紧的属性之一是"谁写的"；纠错走**解锁**（`reopen`）这条显式通道，由医生改完再锁定，**修订责任仍在医生** |
| **看板四条隐私红线（机制性）** | ① 查询只允许 `COUNT(*)`/`SUM(...)`/分组键；② 分组键只允许 `department.name` 与 `visit_date`；③ 响应**不含任何** `patient_id`/`doctor_id`/`phone`/`name`；④ 三条由验收测试**逐字段**钉住（把响应当字符串搜这些键） |
| **刻意不提供"按年龄/性别分布"** | 看起来是聚合，但小科室里等价于个人识别（当天只有 1 个患者时"60 岁以上 1 人"等于说出年龄）—— k-匿名的朴素版本，在没有明确 k 阈值前不提供该维度 |
| **`triage_stat` 不含主诉原文** | 分诊输入是患者自己写的一句话（最敏感的自由文本）；一旦落库就成了"一份没有病历的病情记录"，而看板只需要计数。**不是"存了再脱敏"，而是根本不存** —— `record()` 的签名里没有主诉参数，类型层面做不到 |
| **rev.7 整体拆除内存 Store（三选一里选 B）** | A 补全（加写入口 + `loadAll` + 定时刷盘）会引入本项目迄今没有的后台定时器，且仍有"两次刷盘之间崩溃丢改动"的窗口；C 只改看板标注会让 ~490 行未接线代码继续误导读者。B 拆掉：生产行为几乎不变（三张表本就只被读），却消掉"两种范式并存"与"文档比实现先进"。**"不接线的东西"不是中立的**，是负资产；将来真需要缓存（ADR §8 横向扩展触发条件）再建 |
| **消失的是"范式"，不是"表"** | 三张表仍在库里、仍在 `ALL_TABLES` 里、仍被人读 ⇒ `selftest` 不是删掉那一项，而是给它**新归属：基础数据域**（直接 SQL 读；当时没有写入端点，靠人工 SQL 维护；P5 起科室/医生已补端点） |
| **AC-4 重写为"数据访问范式唯一化"** | 原断言"刷盘不波及号源域"没有对象了，但要保证的事仍在：没有第二条路径能碰号源域。四层：① 每张业务表都归属一个域（无孤儿表）② 号源域的表只准 `BookingRepo` 写 ③ 表名与搬迁前内存 Store 零交集 ④ 反向：号源域确实有数据（否则③是"空比空"的假绿） |
| **刻意不写"没有内存 Store"这类运行期断言** | 按踩坑表 M 条：断言"没有 X"的前提是 X 真的存在；那些名字已不存在，硬写字符串比较是空洞的 ⇒ 交给**编译器**（引用 `MEM_TABLES`/`MemStore` 直接编译失败）。编译期保证比运行期断言硬 |
| **提示里的端口从 `cfg` 派生** | 端口的事实来源是 DSN 里的 `cfg`；提示里再手写一份 = 同一件事两处口径 ⇒ 迟早漂移。**本提示不复制那个数字，就没有第二次漂移的机会** |
| **`MySqlConfig.port` 默认值 3307 → 3306** | 3307 是"假默认"：本项目没有任何实例在那 ⇒ "什么都不传"必然失败，且它看起来像对的（一个具体的、像配置过的数字），于是"没拿到 DSN"与"端口写错"两种故障长得一模一样。取协议标准口，任何"没拿到 DSN"都会以一个明显不对的端口暴露 |
| **`accept` 与 HTTP 层 e2e 必须串行** | `hResetAll` 会整表清空业务表，而 e2e 脚本在同一张库里插夹具 ⇒ 并发时 `accept` 删掉夹具、e2e 全红（看起来像产品坏了）；两者收尾都 `taskkill /F /IM hospital-server.exe`，会互相杀 `serve`（`curl` 返回 `HTTP 0`）。`accept` 因其"整表清空"语义是唯一必然冲突的一方，必须独占 |
| **配置项要么真生效，要么明确说它不生效** | `ai.timeout_secs` 已接 `ClientBuilder`/`HttpRequestBuilder` 的 read/write timeout；`ai.ca_bundle_path` 无入口（`TlsClientConfig.certificate` 是客户端证书 mTLS，不是信任锚）⇒ 标 `unsupported` 并在 `put()` 写入即拒，给出"把 CA 装进系统信任库"或"升级 stdx"的处置。"看起来生效"是最坏的一种（把排查引向错误方向） |
| **测试夹具要用自己的命名空间，并按自己的命名空间清理** | 按 id 段清不到（成功建的科室 id 是 `AUTO_INCREMENT`）、按名字会与别的用例的固定名字撞 `UNIQUE(department.name)` ⇒ INSERT 静默失败 ⇒ 断言假红。已统一 `BASET`/`BASEDEL` 编码前缀 |

> **勘误（第十份复查：三个旋钮"被校验、被存库、被回显，却没有任何地方消费"）**：
> ① `ai.timeout_secs` 原先没接线（患者请求实测挂起 21 秒）→ 已接；但**必须如实写清两个边界**：框架 `ClientBuilder` **没有 connect 超时**
> （成员只有 `readTimeout`/`writeTimeout`/`poolSize`/`maxFrameSize`/`autoRedirect`/proxy/logger），不可达地址那一段由操作系统 TCP 超时决定（本机实测约 21 秒，应用层改不了）；
> 且请求级 `readTimeout(Duration)` **被传递但未被框架采纳** —— 配 3 秒实测 30222 ms、`ai_reason = 出站调用异常：Failed to read data: read data timeout.`（超时确实触发、如实降级到 rules，但耗时是框架默认 30 秒）。
> ② `elapsedMs` 恒为 0 → 已改为读真时钟（`DateTime.now()`）：**用参数当"当前时间"就等于假设调用是瞬时的**。
> ③ `ai.max_concurrent` 没接线 → 已加进程内 `Semaphore` 闸。

---

## P5 —— RAG 知识库

### 交付

| 文件 / 表 / 端点 | 内容 |
| --- | --- |
| `schema.cj`（`KB_SCHEMA_DDL`，2 张） | 表集 12 → **14** |
| `kb_doc` | 文档（**人维护的单位**）；`title` **唯一键**；`enabled` 而非删除 |
| `kb_chunk` | 切块（**检索的单位**）；`embedding` 存 **JSON 数组、允许 NULL**；唯一键 `(doc_id, seq)` |
| `domain_kb.cj` | 核心算法，无 DB、无网络 ⇒ 每个函数都能纯逻辑测试：`kbChunk` / `kbCosine` / `kbSqrt` / `kbTokens` / `kbKeywordScore` / `kbSortHits` / `kbVectorToJson` / `kbVectorFromJson` |
| `kb_repo.cj` | 文档 CRUD + 重切 upsert（旧块必消失）+ 两条检索路 + 向量写入 + 规模统计 |
| `http_kb.cj` | 7 个端点；端点总数 48 → **55** |
| `ai_triage.cj` + `http_app.cj` | RAG 接进分诊：`aiRagContext(hits)` → 片段进 Prompt 的「参考资料」段；`triageRagHits()` 取片段 |
| `dashboard.cj` | `GET /admin/dashboard` 新增 `knowledge_base` 块 |

接口（7 个端点）：

```
管理端（ManageKnowledgeBase，仅管理员）
  GET/POST/GET:id/PUT:id/DELETE:id  /api/v1/admin/kb/docs
  GET                               /api/v1/admin/kb/stats
检索（QueryKnowledgeBase，医生 + 管理员；**患者不给**）
  GET  /api/v1/kb/search?q=&top=
```

看板 `knowledge_base` 块字段：`docs` / `docs_enabled` / `chunks` / `chunks_embedded` /
`embedding_coverage_pct` / `scan_limit` / **`scan_limit_reached`** / `note`。

### 验证

```
selftest      当时 45 项 ✅（表集 12 -> 14 + 知识库域；现基线 51）
authtest      17 项 ✅
triagetest   当时 108 项 ✅（现基线 150）
accept       442 项 ✅ **连跑 2 次一致**（AC-KB-1…5 + AC-BIND-1）
kb-check      45 项 ✅（HTTP 端到端：权限/错误码/切块/停用/删除/**看板块**）
ai-live-check 24 项 ✅（真模型：source=model、密钥不落库、模型绕不过验证层；**结尾自检残留为 0**）
auth 25 / rate-limit 16 / triage 24 / previsit 86 / emr 54 / base 49 / p1-extra 49  ✅
★ 顺序混合验证（复查点名）：base-check ×2 全绿；base-check → triage-check ×2 全绿
★ ai-live-check ×2 全绿且**两次之间残留为 0**
doc-counts ✅ 一致（端点 48 -> 55、accept 442、selftest 45）
```

> **勘误（两层检索的"看起来更好"）**：绝不把关键词结果说成向量结果 —— 它会**掩盖"embedding 从没接上"**。
> 两层都如实标注 `source`（`"keyword"` / `"vector"`）。

### 遗留

| # | 事项 | 说明 |
| --- | --- | --- |
| 1 | **向量路未真正跑通** | 因为**没有可用的 embedding 端点**（DeepSeek 无此 API：`POST https://api.deepseek.com/embeddings` → 404、`/v1/embeddings` → 404）。算法与仓储都有测试，但**没有端到端的真实向量检索验证** |
| 2 | 无分片/降维 | `KB_SCAN_LIMIT` 触顶即上限（已可观测，但未实现分片） |
| 3 | 无中文分词库 | 用**汉字 2-gram** 近似；`kbIsHan` 只覆盖 CJK 基本区（U+4E00..U+9FFF），扩展区罕用字不参与检索 |
| 4 | 无向量化任务/定时器 | `pendingChunks()` 与 `setEmbedding()` 已就绪，但**没有**驱动它们的调度 |
| 5 | 知识库**未接预问诊** | 只接了分诊；预问诊刻意保持确定性规则（结构化槽位由模型产出风险更高） |
| 6 | 姓名等个人信息仍需**人工把关** | 中文姓名无法可靠区分于普通词，见 §五合规 |

另有一处既有隐患（P5 收尾发现、未在本次修）：`accept` 的 `hResetAll` 清 `department` 时**不连带** `schedule` ⇒
实测存在**孤儿排班**（`NOT EXISTS(department)`）；而 `bookableSlotsInDepartment` 是 `JOIN department` 的（孤儿不会被推荐），
当前**不影响行为**，但会让"按 `department_id` 数有号排班"的核对偏多。

### 关键决策

| 决策 | 理由 |
| --- | --- |
| **两层、可自证** | 关键词检索不依赖外部服务 ⇒ 默认路径、永远可用、有真实测试；向量检索需 embedding 端点 ⇒ 已实现（余弦/序列化/排序都有测试），接上端点即启用 |
| **不依赖向量库** | 向量存 MySQL JSON + 纯仓颉余弦；`kb_chunk.embedding` 允许 NULL（关键词路不需要向量）—— 这正是"零向量库"的关键 |
| **两张表而不是一张** | 切块策略会变（窗口/重叠），而**改策略不该动文档**；`(doc_id, seq)` 唯一键让重切 upsert 不留旧块幽灵行 |
| **`title` 唯一键** | 知识库最容易出的问题是同一主题写了两份互相矛盾的文档，而检索会把两份都召回 ⇒ 模型看到矛盾内容。让"重名"在写入那一刻失败 |
| **`enabled` 而非删除** | 停用后历史检索仍可解释 |
| **`department`/`doctor`/`patient` 等基础数据与 KB 表分域** | `selftest` 新增知识库域；另修"`selftest` 漏看 `KB_SCHEMA_DDL`"（表集断言 5 项失败而表实际建出来了）⇒ 新增 `allSchemaDdl()` 作为**唯一答案** |
| **片段是不可信输入，必须过 `aiSanitizeNote`** | 片段来自 `kb_doc.body`，由本院人员维护、比模型编的可信，但「可信来源」≠「可信格式」⇒ 只取首行、去 Markdown、命中用药/诊断词**整条丢**。判据：**清理的依据是"这段文本会不会原样给患者看"，不是"它从哪来"** |
| **必须有界：`AI_RAG_TOTAL_CHARS = 600`（按字符）** | 50 条 × 400 字 = 2 万字会顶掉「患者主诉」的注意力位置、把 token 成本乘几倍而收益递减 |
| **★★ 模型仍然一个字节都改不了 `options`** | 接入 RAG 后这条更重要了：知识库文档里很可能写着"高血压请挂心内科"，若模型能据此改推荐，就等于**知识库内容可以绕过 P2 的硬性验证层**（推荐一个没号的科室）。Prompt 里明确写「不要去哪个科室以系统判定为准」；`ai_triage.cj` 里依然没有任何对 `v.options` 的赋值 |
| **`ragHits` 为空则 Prompt 完全不变** | 不加空的「参考资料：」段 —— 那会诱导模型**自己编**参考资料 |
| **`KB_SCAN_LIMIT = 5000` 且必须可观测** | brief §5.5 说单院区几千 chunk 够用、上万才需分片，5000 正好落在上沿 ⇒ 到了该分片时 `scanned` 会顶到 5000。响应带 `scanned`，`stats()` 回报 `scan_limit` / `scan_limit_reached` / `scan_limit_note`（直接给布尔结论，不让人自己去比） |
| **看板必须放知识库块** | `GET /admin/kb/stats` 只有知道要去看的人才会调，而看板的用途是看清全局；知识库是分诊说明文案的来源，覆盖率长期 0% 应被例行巡检看到，而不是等人抱怨"模型说的和院内须知不一致" |
| **看板用自己的 `count1`（内部 catch），不用 `kbCount1`** | 后者是裸查询、表缺失会直接抛；看板恰恰是"系统出问题时给人看的那一页"，它自己 500 会让人以为整个系统坏了。**同名/近名的两个取数助手，容错语义可能完全不同** |
| **合规三层处置（不假装代码保证了合规）** | ① 管理端写入时机制性拒绝明显的个人信息形态（18 位数字 / **17 位 + X** / 11 位手机号）；② 表注释与接口文档写明；③ Q6 记录里如实列为「仍需人工把关」。知识库文档本身不出站，但**检索命中的片段会随 Prompt 出站给第三方** ⇒ 知识库里不得放患者个人信息 |
| **「降级路径」必须是可测的默认路径（纪律 AI）** | 若把关键词做成"很少走的兜底"，它就永远不会被测到 ⇒ 真需要它时才发现它坏了 |
| **两条路的分数不可比时不要混排（纪律 AJ）** | 关键词分是"覆盖比例"、向量分是"余弦"，量纲不同 ⇒ 混排等于用不可比的数排序；正确做法是二选一（由"有没有 embedding"决定）并如实标注 `source` |
| **切块最易错的不是"切得难看"，而是悄悄丢内容（纪律 AK）** | 丢内容在检索时表现为"某些问题永远查不到"，极难从结果上发现 ⇒ 用"各块按顺序覆盖全文"这种结构性断言钉住 |
| **能被静默触发的上限必须有显式「已触顶」信号（纪律 AL）** | 只回报总块数不够（看到 6000 未必联想到只扫 5000） |
| **测试脚本要自检「本脚本的残留为 0」（纪律 AM）** | 清理漏一个前缀 ⇒ 残留跨轮累积 ⇒ 伪装成**别的脚本的产品缺陷**（本阶段实证坑了 `triage-check`，排查两轮） |

框架级缺陷（P5 期间撞出，不属于 P5 功能范围）：**绑定值被静默改写** —— 往任何字段写含 `?` 的值，
库里会变成**字面量 `NULL`**（`https://h/p?q=1` → `https://h/pNULLq=1`；`x'; DROP TABLE t; -- ?` → `x'; DROP TABLE t; -- NULL`）。
与字段无关 ⇒ 主诉、病历正文、知识库文档、科室名、模型 endpoint 全在内。根因是**三个各自独立、口径互不一致的转义层**：
框架 `sqlEscape`/`sqlQuote`（只双写 `'`，不管 `\` 和 `?`）、本仓 `mysqlBindEscapeFor`、
驱动 `ClientPrepareStatement`（**按整条 SQL 里 `?` 的字符个数**定参数槽位，**不认识引号**）。
修法：① 去掉 `prepare.mode=client` 连接参数，回落 `ServerPrepareStatement`（引号内的 `?` 就是数据）；
② 在 `MySqlBackend` 里自己实现参数拼装，`DbStr` 走 `"'" + mysqlBindEscapeFor(s, true) + "'"`，**不调框架 `sqlQuote`**（否则 `sqlEscape` 会把已双写的 `'` 再双写）；
③ 转义只放在 `MySqlBackend`，不放进通用 `bindSql`。

> 三条走过弯路才得到的纪律：**「写进去了」不等于「写对了」**（这一族缺陷全都不抛异常，`exec` 成功、行数对、`SELECT` 也查得到，
> 只是内容被改了 ⇒ 必须 `HEX()` 逐字节读回来比）；**守卫必须做变异测试**（`AC-BIND-1` 关掉反斜杠双写后 `accept` 立刻 6 项失败）；
> **探针自己也是被测系统的一部分**（用 `sqlQuote` 当判等字面量去比含 `\` 的值必然对不上，把探针的错报成了链路的错）。
>
> 顺带修掉两处「声称存在但没接线」：`insecureTrustAll` 注释写"只能由启动参数置位"而全仓没有赋值点 ⇒ 改名 `allowPlaintextEndpoint` 并如实陈述"本版本恒为 false、不提供明文放行"；
> `aiSafeHost` 原本把**路径**也抹掉，只剩 `scheme://host` ⇒ 对话模型与向量模型很可能是同一 host 的不同路径，管理员无法确认有没有配反 ⇒ 保留路径，只抹 userinfo 与 `?query`/`#fragment`。

---

## 跨阶段遗留总表

| 阶段 | 未做 / 待决项 | 当前状态 |
| --- | --- | --- |
| P0 | 轻舟 HTTP 路由 + 中间件、挂号 REST、三端鉴权、并发压测、内存 Store 补 AC-4 | 已解决（P1；内存 Store 已于 P4 rev.7 拆除） |
| P0 | `booking_idem` 幂等表 | 已解决（ADR rev.4 §7 第 7 条删除，理由唯一索引是更硬保证） |
| P1 | 证书信任分发 / 换受信任 CA | **未做**（运维，本机不可验证；判据与本机测试不同，见「P1 运维交接」§一） |
| P1 | 证书轮换与到期监控 | **半做**：到期检查脚本已就绪（`tls-check.ps1` 第 [1] 段），调度器 + 提前 30 天告警未接 |
| P1 | 按 IP 限流 / 验证码（消除账号级锁定的 DoS 面） | 未做（P2+） |
| P1 | `SLOT_NOT_RESTORED` 从未真正抛出 | 未做（待办） |
| P1 | 弱口令表仍是示例级（真正解法是外部字典） | 未做（发布/运维） |
| P2 | 词表的临床完备性 | 部分推进：**已解决**的 P2-1/P2-2/P2-3（否定窗口 4→8、强度词拆分、词表扩 22 组，`triagetest` 150 项） |
| P2 | 词表仍非临床完备集（需临床输入） | 未做 |
| P2 | 分诊命中率回写 / `converted=1` 闭环 | 未做 |
| P2 | 分诊结论落库审计 | 已解决（P4 `triage_stat`，不含主诉原文） |
| P2 | RAG 知识库检索增强 | 已解决（P5） |
| P3 | 配置变更审计表（"谁改的"没记） | 未做 |
| P3 | 多实例下的缓存失效行为（只靠 TTL 收敛） | 未做（本机单实例，未被实测） |
| P3 | 工具开关只是机制、没有 dispatcher | 未做（P2-5 定为 ⏸：机制已备但无 dispatcher） |
| P3 | Prompt 模板只存不用 | 未做（P2-4 定为 ⏸：模板只存不用） |
| P3 | 回显 endpoint 只给脱敏 host（内部仍用完整 URL） | 现状说明（加 `redacted` 字段告知，见 P5 的 `aiSafeHost` 改造） |
| P3 | `create-db` 建库不可用 / `check-db` 未捕获异常 | 已解决（`ensureDatabaseUsable()` + `--admin-dsn` + `create-db-check.ps1` 17 项） |
| P4 | 基础数据域（科室/医生/患者）没有写入端点 | **部分完成**：科室/医生已由 P5 补上管理端 CRUD（`http_base.cj`）；`patient` 仍靠人工 SQL |
| P4 | 病历修订历史 | **已完成**（`medical_record_revision` + 3 个只读端点 + `revision-check.ps1`） |
| P4 | 看板"调用耗时/趋势对比"（`elapsedMs` 未入库） | 未做（`source` 分布已按 P2-7 改为真实分布 ✅） |
| P4 | 小样本抑制（k-匿名阈值） | 未做 |
| P4 | 接诊队列分页游标 | 未做（只有 `limit` 上限 500） |
| P4 | "爽约"自动判定 | 未做（需定时任务） |
| P4 | `ai.timeout_secs` 未接线 / 无 connect 超时 | 部分解决：**已解决**的 P2-8（重试 1 次 + 全链路墙钟上限）；框架仍无 `connectTimeout`、请求级 `readTimeout` 未被采纳（实测 30 秒兜底） |
| P4 | `ai.ca_bundle_path` 无信任锚入口 | 已按"明确拒绝"处置（`unsupported`，`put()` 写入即 400） |
| P4 | `ai.max_concurrent` 容量不随配置变 | 已知边界（启动后首次出站时定下） |
| P5 | 向量路未真正跑通（无可用的 embedding 端点） | 部分解决：**已解决**中的 P2-6 只做到"默认播种指向真实 embedding 端点（百练 `text-embedding-v3`）"，检索仍走演示向量，管理端与文档均标明"演示用假向量" |
| P5 | 分片/降维（`KB_SCAN_LIMIT` 触顶即上限） | 未做（触顶已可观测） |
| P5 | 中文分词库（现用 2-gram，仅 CJK 基本区） | 未做 |
| P5 | 向量化任务 / 定时器 | 未做（`pendingChunks()`/`setEmbedding()` 已就绪） |
| P5 | 知识库接预问诊 | 未做（刻意：预问诊保持确定性规则） |
| P5 | 姓名等个人信息的人工把关 | 未做（代码无法完整保证，Q6 记录如实列明） |
| P5 | `accept` 的 `hResetAll` 留下孤儿排班 | 已知隐患（当前不影响行为，见 P5 遗留） |
---

## 附录 · 启动时点决策（原 `docs/HISTORY-PROJECT-BRIEF.md` 精简）

> 该文件已于 2026-10-18 合并进本稿并删除；仍被 ADR-0001 与 `docs/PROJECT-OVERVIEW.md` 引用的三块内容（参考系统技术方案、五个硬骨头、风险登记、待决问题）原文保留如下，其余过程性分析见 git 历史。

### 参考系统的两个关键技术方案（当年决定照搬）

- **防超卖**：排班表 `version` 乐观锁 + 扣减带 `remain_num > 0` 条件
- **顺延不串号**：挂号单保存 `visit_date` **就诊日快照**，管理员一键顺延排班不影响已挂患者

### 五个启动时识别的硬骨头与落地结论

| # | 硬骨头 | 结论 |
| --- | --- | --- |
| 5.1 | 号源并发必须脱离内存 Store —— **唯一的架构级决策** | ✅ P0 落地：号源/挂号**单独成域**、以 MySQL 为权威（`version` 乐观锁 + `remain_num > 0` + 与挂号单 INSERT 同事务）。P4 收尾实测内存 Store **在生产路径上从未接线** ⇒ 整体拆除（`mem_store.cj`、`sql_recorder.cj` 删除，[ADR-0001](adr/ADR-0001-号源与挂号独立MySQL路径.md) rev.6/rev.7），全库只剩直接 SQL 一种范式 |
| 5.2 | 出站流式是一个隐蔽缺口，且不能无脑全流式 | ✅ P2 落地：**预问诊走 SSE 流式**，分诊仍一次性返回（流式只用在"要边问边答"的地方） |
| 5.3 | AI 配置要从「命令行参数」改成「数据库驱动」 | ✅ P3 落地：`ai_setting` KV + 改配置零重启 + **密钥只存引用**（`env:`/`file:`/`builtin:`，裸密钥机制性拒收） |
| 5.4 | 挂号绝不能进离线队列 | ✅ 从未引入队列：挂号与 AI 调用**在线直连**（排队等于超卖） |
| 5.5 | RAG 是全新模块，但没有现成库 | ✅ P5 落地：切块 → 向量存 MySQL JSON → **纯仓颉余弦**；关键词检索为默认路，向量路受"DeepSeek 无 embeddings"限制未端到端验证 |

### 风险登记（状态已更新到 2026-10-18）

| # | 风险 | 级别 | 说明 / 缓解 |
| --- | --- | --- | --- |
| **R-2** | ~~架构债：双数据访问范式~~ | 🟢 **已消除** | 内存 Store 已于 P4 收尾整体拆除，全库只剩直接 SQL |
| **R-3** | 手写 SQL 映射的人力成本 | 🟡 中 | 只建必要表（当时 8 张，现 16 张），不做参考系统的 21 张 |
| **R-4** | **医疗合规**（病历/预问诊 = 敏感个人信息） | 🟠 中高 | 参考系统通篇未提合规。真实落地需个保法/等保/实名/留存；**有真实医院合作方时合规是第一优先级且工期不可压缩**。当前出站口径见 [Q6-合规决策记录.md](Q6-合规决策记录.md) |
| **R-5** | 无真实 HIS/医保/支付对接 | 🟡 中 | 原型阶段用模拟数据，**留接口位** |
| **R-6** | 仓颉生态迭代速度 | 🟢 低 | 统一走 OpenAI 兼容协议可缓解 |
| **R-7** | 密钥落库倒退 | 🟢 低 | 已机制化：只存引用，裸密钥拒收 |

### 启动时的 6 个待决问题与现状

| # | 问题 | 现状 |
| --- | --- | --- |
| **Q1** | 新建空仓再选择性搬运，还是 fork 既有仓库？ | ✅ 已决：新建工作区 + 选择性搬运（不带 `.git` 历史） |
| **Q2** | 数据模型范围：先建哪几张表？ | ✅ 已决（P0）：当时最小 **8 张**（现 16 张）= 业务 6（`department` `doctor` `schedule`★ `appointment`★ `patient` `medical_record`）+ 鉴权 2（`auth_user` `auth_token`）★ = 走直接 SQL |
| **Q3** | 患者端页面范围？ | ✅ 已决：主闭环 6 页；就诊记录/设备管理/自助注册不在本期（服务端暂无注册/改密端点）。口径见 [FRONTEND-INTEGRATION.md](FRONTEND-INTEGRATION.md) |
| **Q4** | 管理端看板前端是否复用既有 Vue 工程？ | ✅ 已决：管理台改用**零框架原生 JS**（`server/admin-web/`），不引前端工程 |
| **Q5** | 单院区量级（日门诊量、号源峰值并发）？ | ⏳ 未决：决定扣号路径是否需要重试/排队，以及是否真不需要 Redis |
| **Q6** | AI 模型选型与合规 | ⏳ 选型已定 DeepSeek（对话）+ 百炼（向量，未端到端验证）；**出站合规口径已落档**，见 [Q6-合规决策记录.md](Q6-合规决策记录.md) |