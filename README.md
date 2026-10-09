# 智慧医院智能导诊就诊系统

> 患者输入一句主诉 → AI 多步推理取证 → 推荐科室与医生 → 校验真实有号 → 一键挂号 → 医生接诊 → 生成电子病历，全程落库、可追溯、可观测。

---

## 当前进度

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| 准备 | 读取文档 + 从 `cangjie_web` 搬运只读基线到 `baseline/` | ✅ 完成 |
| **P0** | **号源/挂号独立 MySQL 路径**：ADR + 服务端骨架 + 表集 + 原子扣减/幂等/退号 + 验收测试 | ✅ **完成**（经 rev.2 / rev.3 / rev.4 三轮复查修订；**rev.3 推翻了 P0 的乐观锁扣号策略**，rev.4 删掉死代码 `booking_idem`） |
| **P1** | **挂号闭环 + 令牌鉴权 + HTTPS + 安全加固 + 内存 Store**（⚠ 内存 Store 已于 P4 收尾时**整体拆除**，见下方 rev.7）：中间件装配 + 三端权限矩阵 + **48 个 REST** + 不透明令牌（PBKDF2 100k，3 个公开向量验过）+ **HTTPS（TLS 1.2/1.3，带 SAN 自签）** + **登录限流/失败锁定** + **口令强度校验** + **会话按设备管理** + **内存 Store（配套域）** + **多进程并发压测**（20/30/40/50 抢同数号源全部卖光；并发退号零丢号） | ✅ **P1 代码项全部完成**（剩 2 项运维，见下） |
| **P2** | **AI 分诊（工程纪律层）**：危急征象兜底（词表 + 否定 + 共现）+ **验证层（绝不给没号的推荐）**+ 三态结论 + `POST /api/v1/triage` + **预问诊多轮采集（SSE 流式）**。<br>★ **真模型已于 P3 收尾时接通**（`ai_call.cj`）；未配置时 `source=rules`（默认关闭），配置后 `source=model`。见 [P2-HANDOFF](docs/P2-HANDOFF.md) | ✅ **完成** |
| **P3** | **AI 能力中心（配置底座）**：`ai_setting` KV 表 + **改配置零重启**（写库→失效缓存）+ ★★ **密钥不引用不落库**（`env:`/`file:` 引用，机制性拒绝裸密钥）+ 脱敏回显。<br>+ **Prompt 模板落库**（缺占位符即拒）+ **AI 工具开关落库**（默认全开、可单独关）。<br>★★ **真模型已接通**（`ai_call.cj` + `ai_triage.cj`；**默认关闭**，配置后 `source=model`）。⚠ 合规决策见 [Q6-合规决策记录](docs/Q6-合规决策记录.md)。见 [P3-HANDOFF](docs/P3-HANDOFF.md) | ✅ **完成** |
| **P4** | **电子病历 + 运营看板**：七段式病历（草稿 → **提交锁定，锁定后不可改**）+ 医生**接诊队列**（状态机；**完成就诊前必须已锁定病历**）+ 患者只读自己的档案 + **运营看板**（科室/挂号趋势/号源使用率/分诊命中/预问诊完成率/病历进度/AI 配置概览）。<br>★★ **顺带改了一处架构**：`medical_record` **移出内存 Store** 改直接 SQL（[ADR-0001](docs/adr/ADR-0001-号源与挂号独立MySQL路径.md) **rev.6**）—— 因为内存 Store 在生产路径上**从未刷盘**（`flushToMysql()` 只有测试调过），而病历是医疗数据。<br>★ **真模型已接通**（分诊）；**看板只出聚合、绝不出明细**。<br>★★ **P4 收尾还清了一笔架构债**：核对"配套域生产不刷盘"时实测发现内存 Store **在生产上从未接线**（零实例化 / 零 `loadAll` / 零 `flushToMysql` / 无写入口）⇒ **整体拆除**（`mem_store.cj` + `sql_recorder.cj` 删除，源码 24→22），全库只剩**一种**数据访问范式（[ADR-0001](docs/adr/ADR-0001-号源与挂号独立MySQL路径.md) **rev.7**）。见 [P4-HANDOFF](docs/P4-HANDOFF.md) | ✅ **完成** |
| P5 | RAG 知识库 | ⏳ |

> **交付说明**：
> - P0 → **[docs/P0-HANDOFF.md](docs/P0-HANDOFF.md)**（⚠ 内含"本文档为 P0 时点快照 + 勘误表"声明，部分结论已被后续推翻）
> - P1 → **[docs/P1-HANDOFF.md](docs/P1-HANDOFF.md)**（**最新**；含两轮外部复查的逐条修复记录）
> - 架构决策 → **[docs/adr/ADR-0001](docs/adr/ADR-0001-号源与挂号独立MySQL路径.md)**（已到 **rev.4**）
> - 本机环境 / 数据库 → **[docs/DEV-DB.md](docs/DEV-DB.md)**（仓库自管，端口 3317）
> - ⚠ **文档里的测试项数以 `server/tests/doc-counts.ps1` 的实测输出为准** —— 这个数字漂移过两次，现已机制化对账，不再靠人记。

---

## 目录结构

| 路径 | 是什么 | 能否改 |
| --- | --- | --- |
| [smart-hospital-project-brief.md](smart-hospital-project-brief.md) | **唯一上下文入口** —— 项目定位、已确认决策、可复用资产盘点、5 个硬骨头、里程碑、风险、待决问题 | ✏️ 本项目文档 |
| [docs/adr/](docs/adr/ADR-0001-号源与挂号独立MySQL路径.md) | **架构决策记录** —— ADR-0001 号源/挂号独立 MySQL 路径（P0 唯一架构级决策） | ✏️ 本项目文档 |
| [docs/P0-HANDOFF.md](docs/P0-HANDOFF.md) | P0 收尾说明：交付物、验收结果与边界、本机联调环境、P0 踩过的 12 个坑 | ✏️ 本项目文档 |
| [docs/P1-HANDOFF.md](docs/P1-HANDOFF.md) | **P1 说明**：HTTP 接口清单、权限矩阵、令牌鉴权口径与公开测试向量、并发压测结果、抓出的缺陷、未完成项 | ✏️ 本项目文档 |
| [docs/PUSH-NOTES.md](docs/PUSH-NOTES.md) | 推送备忘：本机 DNS 返回了一个连不通的 GitHub IP，以及绕过办法（实测有效） | ✏️ 本项目文档 |
| [docs/DEV-DB.md](docs/DEV-DB.md) | **仓库自管开发数据库**（端口 3317，与社团那台彻底隔离）：启停、连接、DSN、重置 | ✏️ 本项目文档 |
| [docs/P1-OPS-HANDOFF.md](docs/P1-OPS-HANDOFF.md) | **P1 运维交接**：证书信任分发 / 轮换与到期监控 —— 两项**本机不可验证**，含判据与具体命令 | ✏️ 本项目文档 |
| [docs/P2-HANDOFF.md](docs/P2-HANDOFF.md) | **P2 AI 分诊交付**：边界（未接模型及原因）、核心不变式、变异测试、三个"字节/字符混用"缺陷 | ✏️ 本项目文档 |
| [docs/P3-HANDOFF.md](docs/P3-HANDOFF.md) | **P3 AI 能力中心**：密钥不落库的**机制**、改配置零重启、第五类表、诚实的边界 | ✏️ 本项目文档 |
'| [docs/Q6-合规决策记录.md](docs/Q6-合规决策记录.md) | ★★ **模型出站的合规事实**：发什么出站 / 默认状态 / 六道闸门 / 未做的六项 / 谁批准 | ✏️ 本项目文档 |
| [docs/P4-HANDOFF.md](docs/P4-HANDOFF.md) |' **P4 电子病历 + 运营看板**：★ 范式迁移 rev.6（病历为何移出内存 Store）+ ★★ **rev.7（内存 Store 整体拆除）**、看板隐私红线、八处真问题与教训、诚实的边界 | ✏️ 本项目文档 |
| [server/](server/README.md) | **智慧医院服务端**（仓颉 + 轻舟）：`src/` **22 个 `.cj`** + 5 个构建/运维脚本 + `tests/` **10 个测试脚本** + `common.ps1` + README | ✏️ 本项目代码 |
| [baseline/](baseline/SNAPSHOT.md) | **只读参考基线** —— 复制自 `cangjie_web`，**352 文件 / 7.53 MB**，基线提交 `07a0922`（上传前已剔除机密材料，见其 §二·补） | 🚫 **只读，勿就地改** |
| [baseline/SNAPSHOT.md](baseline/SNAPSHOT.md) | 基线说明：来源/提交/排除清单/路径映射表/复用风险 | ✏️ 复制说明 |
| `entry/` | ⚠️ **目前尚不存在** —— 鸿蒙患者端将来落这里，取用 `baseline/entry/` 作模板 | — |

> 🔴 **关键约定**：`baseline/` 是素材库，**只读**。智慧医院的代码写在 `server/`、`entry/`，
> 需要哪块就从基线取模板**新写**，不要在基线里就地改 —— 基线保持可回查、可比对。

---

## 阅读顺序

1. **[smart-hospital-project-brief.md](smart-hospital-project-brief.md)** —— 整份读完即可接续，不需要回读原对话
   - ⚠️ §1 是**已决事项**，除非有新的外部约束，**不要重新讨论**
   - ⚠️ 标注「**推断**」的数字（尤其工期）都是**未实测的粗估**，落地前请自行验证
2. **[docs/P1-HANDOFF.md](docs/P1-HANDOFF.md)** —— **当前进度在这里**：接口清单、权限矩阵、令牌口径、HTTPS、两轮外部复查的逐条修复
3. **[docs/P0-HANDOFF.md](docs/P0-HANDOFF.md)** —— P0 时点快照（⚠ 文首有勘误表：部分结论已被推翻，对照着看）
4. **[docs/adr/ADR-0001](docs/adr/ADR-0001-号源与挂号独立MySQL路径.md)** —— 为什么号源/挂号要脱离内存 Store（**rev.7**，含扣号/归还策略与内存 Store 拆除的历次修订论证）
5. **[docs/DEV-DB.md](docs/DEV-DB.md)** —— 怎么把本机数据库跑起来（仓库自管 devdb，与社团隔离）
6. [baseline/SNAPSHOT.md](baseline/SNAPSHOT.md) —— 基线里有什么、缺什么、链接怎么对上
7. [baseline/docs/qingzhou-api-fact-sheet.md](baseline/docs/qingzhou-api-fact-sheet.md) —— **轻舟 API 事实清单**（每条带 file:line，写接口前必读）
8. [baseline/docs/API-NOTES.md](baseline/docs/API-NOTES.md) —— 编译期 API 事实 + 45 条踩坑（**写仓颉前必读**）

---

## 基线快照包含什么

| 资产 | 落点 | 复用度 |
| --- | --- | --- |
| 轻舟框架 v0.12.0（SSE / 出站流式 / DB 抽象 / Trie 路由） | `baseline/server/third_party/qingzhou/` | ⭐⭐⭐⭐⭐ |
| **AI 编排**（工具白名单 / 三态降级 / 提议确认 / 风控） | `baseline/server/src/ai_*.cj` | ⭐⭐⭐⭐⭐ |
| 服务端源码 33 个 `.cj`（含 `mysql_store.cj` 1362 行量级） | `baseline/server/src/` | ⭐⭐⭐⭐⭐ |
| 7 套测试脚本（冒烟 440 / 契约 / 后台 / 运维 / AI 三件套） | `baseline/server/tests/` | ⭐⭐⭐⭐ |
| 鸿蒙 ArkTS 客户端（21 页面 + api/ + 7 状态仓 + Theme） | `baseline/entry/` | ⭐⭐⭐⭐ |
| Vue 3 管理端（源码 + 随仓库提交的 `dist`） | `baseline/server/admin-web/` | ⭐⭐⭐ |
| 29 份中文文档（六轮评审 / 容量基线 / 45 条踩坑） | `baseline/docs/` | ⭐⭐⭐⭐⭐ |

---

## 未决问题

见 [smart-hospital-project-brief.md §10](smart-hospital-project-brief.md)，共 6 条。

| # | 问题 | 状态 |
| --- | --- | --- |
| Q1 | fork 本仓库，还是新建空仓再选择性搬运？ | ✅ **已决**：新建工作区 + 选择性搬运 → 基线落在 `baseline/`，不带 `.git` 历史 |
| Q2 | 数据模型范围：先建哪几张表？ | ✅ **已决（P0）**：最小 **8 张** = 业务 6（`department` `doctor` `schedule`★ `appointment`★ `patient` `medical_record`）+ 鉴权 2（`auth_user` `auth_token`）。★ = 走直接 SQL。**原有一张 `booking_idem`（幂等登记）已于 2026-10-07 删除**（死代码，见 [ADR-0001 rev.4 §7](docs/adr/ADR-0001-号源与挂号独立MySQL路径.md)） |
| Q3 | 患者端页面范围：复用哪些既有页面？ | ⏳ 未决 |
| Q4 | 管理端是否复用 `baseline/server/admin-web`（Vue3）？ | ⏳ 未决 |
| Q5 | **单院区量级**：日门诊量？号源放出峰值并发？ | ⏳ 未决 —— **影响 P0 扣号路径是否要加重试/排队**（ADR-0001 §3 方案 C 的后手条件） |
| Q6 | AI 模型选型与合规 | ⏳ 未决 |
