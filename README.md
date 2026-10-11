# 智慧医院智能导诊就诊系统

> 患者输入一句主诉 → AI 多步推理取证 → 推荐科室与医生 → 校验真实有号 → 一键挂号 → 医生接诊 → 生成电子病历，全程落库、可追溯、可观测。

---

## 当前进度

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| 准备 | 读取项目文档、确认技术路线（仓颉 + 轻舟）与数据模型范围 | ✅ 完成 |
| **P0** | **号源/挂号独立 MySQL 路径**：ADR + 服务端骨架 + 表集 + 原子扣减/幂等/退号 + 验收测试 | ✅ **完成**（经 rev.2 / rev.3 / rev.4 三轮复查修订；**rev.3 推翻了 P0 的乐观锁扣号策略**，rev.4 删掉死代码 `booking_idem`） |
| **P1** | **挂号闭环 + 令牌鉴权 + HTTPS + 安全加固 + 内存 Store**（⚠ 内存 Store 已于 P4 收尾时**整体拆除**，见下方 rev.7）：中间件装配 + 三端权限矩阵 + **55 个 REST** + 不透明令牌（PBKDF2 100k，3 个公开向量验过）+ **HTTPS（TLS 1.2/1.3，带 SAN 自签）** + **登录限流/失败锁定** + **口令强度校验** + **会话按设备管理** + **内存 Store（配套域）** + **多进程并发压测**（20/30/40/50 抢同数号源全部卖光；并发退号零丢号） | ✅ **P1 代码项全部完成**（剩 2 项运维，见下） |
| **P2** | **AI 分诊（工程纪律层）**：危急征象兜底（词表 + 否定 + 共现）+ **验证层（绝不给没号的推荐）**+ 三态结论 + `POST /api/v1/triage` + **预问诊多轮采集（SSE 流式）**。<br>★ **真模型已于 P3 收尾时接通**（`ai_call.cj`）；未配置时 `source=rules`（默认关闭），配置后 `source=model`。见 [P2-HANDOFF](docs/P2-HANDOFF.md) | ✅ **完成** |
| **P3** | **AI 能力中心（配置底座）**：`ai_setting` KV 表 + **改配置零重启**（写库→失效缓存）+ ★★ **密钥不引用不落库**（`env:`/`file:` 引用，机制性拒绝裸密钥）+ 脱敏回显。<br>+ **Prompt 模板落库**（缺占位符即拒）+ **AI 工具开关落库**（默认全开、可单独关）。<br>★★ **真模型已接通**（`ai_call.cj` + `ai_triage.cj`；**默认关闭**，配置后 `source=model`）。⚠ 合规决策见 [Q6-合规决策记录](docs/Q6-合规决策记录.md)。见 [P3-HANDOFF](docs/P3-HANDOFF.md) | ✅ **完成** |
| **P4** | **电子病历 + 运营看板**：七段式病历（草稿 → **提交锁定，锁定后不可改**）+ 医生**接诊队列**（状态机；**完成就诊前必须已锁定病历**）+ 患者只读自己的档案 + **运营看板**（科室/挂号趋势/号源使用率/分诊命中/预问诊完成率/病历进度/AI 配置概览）。<br>★★ **顺带改了一处架构**：`medical_record` **移出内存 Store** 改直接 SQL（[ADR-0001](docs/adr/ADR-0001-号源与挂号独立MySQL路径.md) **rev.6**）—— 因为内存 Store 在生产路径上**从未刷盘**（`flushToMysql()` 只有测试调过），而病历是医疗数据。<br>★ **真模型已接通**（分诊）；**看板只出聚合、绝不出明细**。<br>★★ **P4 收尾还清了一笔架构债**：核对"配套域生产不刷盘"时实测发现内存 Store **在生产上从未接线**（零实例化 / 零 `loadAll` / 零 `flushToMysql` / 无写入口）⇒ **整体拆除**（`mem_store.cj` + `sql_recorder.cj` 删除，源码 24→22），全库只剩**一种**数据访问范式（[ADR-0001](docs/adr/ADR-0001-号源与挂号独立MySQL路径.md) **rev.7**）。见 [P4-HANDOFF](docs/P4-HANDOFF.md) | ✅ **完成** |
| **P5** | **RAG 知识库（零向量库）**：文档 + **切块**（按字符、带重叠、**结构性保证不丢内容**）→ 向量存 MySQL JSON（**纯仓颉余弦**）→ **关键词检索为默认路**（不依赖外部服务）+ 向量路（配 embedding 端点即启用）；管理端 CRUD + 检索接口；★ **RAG 片段接进分诊**（过安全层、有界、**改不了 `options`**）+ **看板知识库规模**（含 `scan_limit_reached` 触顶告警）。⚠ 已核实 **DeepSeek 无 embeddings 端点** ⇒ 向量路未做端到端验证（算法与仓储有测试）。见 [P5-HANDOFF](docs/P5-HANDOFF.md) | ✅ **完成** |
| **客户端** | **鸿蒙患者端**（ArkTS，由客户端同学另行开发） | ⏳ **待实现** —— 接口口径见 **[前端对接说明](docs/FRONTEND-INTEGRATION.md)** |

> **交付说明**：
> - P0 → **[docs/P0-HANDOFF.md](docs/P0-HANDOFF.md)**（⚠ 内含"本文档为 P0 时点快照 + 勘误表"声明，部分结论已被后续推翻）
> - P1 → **[docs/P1-HANDOFF.md](docs/P1-HANDOFF.md)**（含两轮外部复查的逐条修复记录）
> - 架构决策 → **[docs/adr/ADR-0001](docs/adr/ADR-0001-号源与挂号独立MySQL路径.md)**（已到 **rev.7**）
> - **前端对接** → **[docs/FRONTEND-INTEGRATION.md](docs/FRONTEND-INTEGRATION.md)**（谁要写客户端/网页，先读这一份：鉴权、18 个端点逐字段、SSE 分帧、幂等挂号、服务端缺口）
> - 本机环境 / 数据库 → **[docs/DEV-DB.md](docs/DEV-DB.md)**（仓库自管，端口 3317）
> - ⚠ **文档里的测试项数以 `server/tests/doc-counts.ps1` 的实测输出为准** —— 这个数字漂移过两次，现已机制化对账，不再靠人记。

---

## 目录结构

| 路径 | 是什么 | 能否改 |
| --- | --- | --- |
| [smart-hospital-project-brief.md](smart-hospital-project-brief.md) | **唯一上下文入口** —— 项目定位、已确认决策、资产盘点与落点、5 个硬骨头、里程碑、风险、待决问题 | ✏️ 本项目文档 |
| [docs/adr/](docs/adr/ADR-0001-号源与挂号独立MySQL路径.md) | **架构决策记录** —— ADR-0001 号源/挂号独立 MySQL 路径（P0 唯一架构级决策） | ✏️ 本项目文档 |
| [docs/P0-HANDOFF.md](docs/P0-HANDOFF.md) | P0 收尾说明：交付物、验收结果与边界、本机联调环境、P0 踩过的 12 个坑 | ✏️ 本项目文档 |
| [docs/P1-HANDOFF.md](docs/P1-HANDOFF.md) | **P1 说明**：HTTP 接口清单、权限矩阵、令牌鉴权口径与公开测试向量、并发压测结果、抓出的缺陷、未完成项 | ✏️ 本项目文档 |
| [docs/PUSH-NOTES.md](docs/PUSH-NOTES.md) | 推送备忘：本机 DNS 返回了一个连不通的 GitHub IP，以及绕过办法（实测有效） | ✏️ 本项目文档 |
| [docs/DEV-DB.md](docs/DEV-DB.md) | **仓库自管开发数据库**（端口 3317，与本机其它项目隔离）：启停、连接、DSN、重置 | ✏️ 本项目文档 |
| [docs/P1-OPS-HANDOFF.md](docs/P1-OPS-HANDOFF.md) | **P1 运维交接**：证书信任分发 / 轮换与到期监控 —— 两项**本机不可验证**，含判据与具体命令 | ✏️ 本项目文档 |
| [docs/P2-HANDOFF.md](docs/P2-HANDOFF.md) | **P2 AI 分诊交付**：边界（未接模型及原因）、核心不变式、变异测试、三个"字节/字符混用"缺陷 | ✏️ 本项目文档 |
| [docs/P3-HANDOFF.md](docs/P3-HANDOFF.md) | **P3 AI 能力中心**：密钥不落库的**机制**、改配置零重启、第五类表、诚实的边界 | ✏️ 本项目文档 |
| [docs/Q6-合规决策记录.md](docs/Q6-合规决策记录.md) | ★★ **模型出站的合规事实**：发什么出站 / 默认状态 / 六道闸门 / 未做的六项 / 谁批准 | ✏️ 本项目文档 |
| [docs/P4-HANDOFF.md](docs/P4-HANDOFF.md) | **P4 电子病历 + 运营看板**：★ 范式迁移 rev.6（病历为何移出内存 Store）+ ★★ **rev.7（内存 Store 整体拆除）**、看板隐私红线、八处真问题与教训、诚实的边界 | ✏️ 本项目文档 |
| [docs/P5-HANDOFF.md](docs/P5-HANDOFF.md) | **P5 RAG 知识库**：零向量库做法、三条硬约束、片段上限、踩坑与验证记录 | ✏️ 本项目文档 |
| [docs/FRONTEND-INTEGRATION.md](docs/FRONTEND-INTEGRATION.md) | ★ **前端对接说明**（唯一口径）：起服务 / 鉴权 / 信封与错误码 / 18 个端点逐字段 / SSE 原始帧 / 幂等挂号与退号语义 / 服务端缺口 / 前端工程纪律 | ✏️ 本项目文档 |
| [server/](server/README.md) | **智慧医院服务端**（仓颉 + 轻舟，自包含）：`src/` **33 个 `.cj`**（业务）+ `third_party/`（轻舟框架 + MariaDB 驱动，**使用副本**）+ 5 个构建/运维脚本 + `tests/` **13 个测试脚本** + `common.ps1` + README | ✏️ 本项目代码 |
| `entry/` | ⏳ **留白（预留）** —— 鸿蒙患者端由客户端同学实现；接口口径见 [前端对接说明](docs/FRONTEND-INTEGRATION.md)。⚠ 目录结构以客户端同学实际的工程为准 | — |

> 🔴 **关键约定**：本仓库目前**只有服务端**（`server/`，自包含：框架与数据库驱动都是使用副本，构建时校验 `MANIFEST.sha256`）。
> 客户端（鸿蒙患者端）由客户端同学另行开发，接口口径**只以** [docs/FRONTEND-INTEGRATION.md](docs/FRONTEND-INTEGRATION.md) 为准。
> （源码注释里保留了少数**搬迁前的历史标注**：旧的出处路径（目录名 + `文件:行号`）与旧部署事实的说明。它们在本仓库不可点击、不参与构建与运行。）

---

## 阅读顺序

1. **[smart-hospital-project-brief.md](smart-hospital-project-brief.md)** —— 整份读完即可接续，不需要回读原对话
   - ⚠️ §1 是**已决事项**，除非有新的外部约束，**不要重新讨论**
   - ⚠️ 标注「**推断**」的数字（尤其工期）都是**未实测的粗估**，落地前请自行验证
2. **[docs/FRONTEND-INTEGRATION.md](docs/FRONTEND-INTEGRATION.md)** —— **要写客户端/网页就先读这份**：接口口径、鉴权、SSE、幂等挂号、服务端缺口
3. **[docs/P1-HANDOFF.md](docs/P1-HANDOFF.md)** —— **服务端接口与安全底子**：接口清单、权限矩阵、令牌口径、HTTPS、两轮外部复查的逐条修复（最新进度看上面的进度表）
4. **[docs/P0-HANDOFF.md](docs/P0-HANDOFF.md)** —— P0 时点快照（⚠ 文首有勘误表：部分结论已被推翻，对照着看）
5. **[docs/adr/ADR-0001](docs/adr/ADR-0001-号源与挂号独立MySQL路径.md)** —— 为什么号源/挂号要脱离内存 Store（**rev.7**，含扣号/归还策略与内存 Store 拆除的历次修订论证）
6. **[docs/DEV-DB.md](docs/DEV-DB.md)** —— 怎么把本机数据库跑起来（仓库自管 devdb，与本机其它项目隔离）
7. **[server/README.md](server/README.md)** —— 服务端自己的说明：构建/运行/测试脚本、踩坑表、各阶段边界（⚠ 它的端点清单比实现旧，端点以 `server/src/http_app.cj` 与 [前端对接说明](docs/FRONTEND-INTEGRATION.md) 为准）

---

## 第三方代码与素材

本仓库**自包含**：服务端需要的框架与数据库驱动都以**使用副本**形式放在 `server/third_party/` 下，
由 `server/build.ps1` 校验 `MANIFEST.sha256` 后与业务代码同一次编译。

| 组件 | 落点 |
| --- | --- |
| 轻舟框架 v0.12.0（SSE / 出站流式 / DB 抽象 / Trie 路由） | `server/third_party/qingzhou/` |
| MariaDB 驱动 + 构建/运行脚本口径 | `server/third_party/mariadb-driver/`、`server/build.ps1`、`server/devdb.ps1` |
| AI 编排（三态降级 / 校验层 / 风控）与令牌鉴权 | `server/src/ai_*.cj`、`server/src/auth_*.cj`（自包含实现） |

> ⚠ 源码与脚本注释里保留了少数**搬迁前的历史标注**（旧的出处路径、旧部署事实的说明），
> 在本仓库**不可点击**，也不参与构建；不影响任何功能。

---

## 未决问题

见 [smart-hospital-project-brief.md §10](smart-hospital-project-brief.md)，共 6 条。

| # | 问题 | 状态 |
| --- | --- | --- |
| Q1 | 新建空仓再选择性搬运，还是 fork 既有仓库？ | ✅ **已决**：新建工作区 + 选择性搬运，不带 `.git` 历史（结论不变：本仓只放自己的代码，不含任何外部素材目录） |
| Q2 | 数据模型范围：先建哪几张表？ | ✅ **已决（P0）**：最小 **8 张** = 业务 6（`department` `doctor` `schedule`★ `appointment`★ `patient` `medical_record`）+ 鉴权 2（`auth_user` `auth_token`）。★ = 走直接 SQL。**原有一张 `booking_idem`（幂等登记）已于 2026-10-07 删除**（死代码，见 [ADR-0001 rev.4 §7](docs/adr/ADR-0001-号源与挂号独立MySQL路径.md)） |
| Q3 | 患者端页面范围？ | ✅ **已决**：**主闭环 6 页**（登录 / 分诊 / 预问诊 / 约号 / 我的预约 / 我的）；就诊记录、设备管理、自助注册不在本期（服务端暂无注册/改密端点）。**客户端由客户端同学另行开发**，接口口径见 [前端对接说明](docs/FRONTEND-INTEGRATION.md) |
| Q4 | 管理端（运营看板）前端是否复用既有 Vue 3 工程？ | ⏳ 未决 —— 服务端已提供看板聚合接口（P4），前端技术栈留给写前端的一方决定 |
| Q5 | **单院区量级**：日门诊量？号源放出峰值并发？ | ⏳ 未决 —— **影响 P0 扣号路径是否要加重试/排队**（ADR-0001 §3 方案 C 的后手条件） |
| Q6 | AI 模型选型与合规 | ⏳ **选型未决；出站合规口径已落档** —— 发什么出站、默认关闭、六道闸门见 [docs/Q6-合规决策记录.md](docs/Q6-合规决策记录.md) |
