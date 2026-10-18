# 智慧医院智能导诊就诊系统

> 患者输入一句主诉 → AI 多步推理取证 → 推荐科室与医生 → **校验真实有号** → 一键挂号 → 医生接诊 → 生成电子病历，全程落库、可追溯、可观测。
>
> 技术栈：**仓颉（Cangjie）+ 轻舟（QingZhou）** 服务端 · **鸿蒙 ArkTS** 三端客户端 · **安卓 Kotlin** 患者端 · 零中间件（不需要 Redis / 向量库 / 消息队列）。

---

## 交付物导航

| # | 交付项 | 文档 |
| --- | --- | --- |
| 1 | **项目说明** —— 背景、需求分析、功能模块、创新点、应用价值 | [docs/PROJECT-OVERVIEW.md](docs/PROJECT-OVERVIEW.md) |
| 2 | **系统设计** —— 总体架构、模块划分、接口设计、数据流转、关键技术 | [docs/SYSTEM-DESIGN.md](docs/SYSTEM-DESIGN.md) |
| 3 | **源码仓库与版本历史** | 本文件 §仓库信息 · [CHANGELOG.md](CHANGELOG.md) |
| 4 | **可运行包 / 部署 / 环境配置** | [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) · [tools/package-release.ps1](tools/package-release.ps1) |
| 5 | **开源组件 / 第三方模型 / 外部 API / 数据集** | [docs/THIRD-PARTY.md](docs/THIRD-PARTY.md) |

---

## 仓库信息

| 项 | 值 |
| --- | --- |
| 仓库地址 | <https://github.com/XueDric/smart_hospital.git>（默认分支 `main`） |
| 版本 | `0.2.0-p1`（`server/src/main.cj:34`）= P0–P5 六阶段交付 + 第 1 个维护批次 |
| 提交历史 | 107 个提交（截至 tag `v0.2.0-p1-rev`），2026-10-07 → 2026-10-17；6 位贡献者 |
| 许可证 / 第三方 | 本项目 [MIT](LICENSE)；第三方组件清单见 [docs/THIRD-PARTY.md](docs/THIRD-PARTY.md) |

```bash
git clone https://github.com/XueDric/smart_hospital.git
cd smart_hospital
git log --oneline --graph | head -30      # 版本历史（截至 v0.2.0-p1-rev 共 107 个提交）
```

**版本历史摘要**（完整见 [CHANGELOG.md](CHANGELOG.md)）

| 日期 | 里程碑 |
| --- | --- |
| 2026-10-07 | P0 号源/挂号独立 MySQL 路径 + P1 令牌鉴权 / HTTPS / 限流 / 并发压测 |
| 2026-10-08 ~ 10-09 | P4 电子病历 + 运营看板；P5 零向量库 RAG；拆除内存 Store（统一数据访问范式） |
| 2026-10-10 ~ 10-12 | P2/P3 收尾（AI 分诊编排、AI 能力中心）；患者端联调八项接口 |
| 2026-10-13 ~ 10-15 | 鸿蒙三端 + 安卓患者端 + 管理台；门诊闭环 7 项改进；**接口契约可执行** |
| 2026-10-16 ~ 10-17 | 医生端病历工作台；复验修复 10 条（S1–S16）；DB 断链自愈；AI 配置可观测；文档与仓库收敛 |

---

## 当前进度

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| 准备 | 读取项目文档、确认技术路线（仓颉 + 轻舟）与数据模型范围 | ✅ 完成 |
| **P0** | **号源/挂号独立 MySQL 路径**：ADR + 服务端骨架 + 表集 + 原子扣减/幂等/退号 + 验收测试 | ✅ **完成**（经 rev.2 / rev.3 / rev.4 三轮复查修订；**rev.3 推翻了 P0 的乐观锁扣号策略**，rev.4 删掉死代码 `booking_idem`） |
| **P1** | **挂号闭环 + 令牌鉴权 + HTTPS + 安全加固**：中间件装配 + 三端权限矩阵 + **81 个 REST** + 不透明令牌（PBKDF2 100k）+ **HTTPS（TLS 1.2/1.3，带 SAN 自签）** + 登录限流/失败锁定 + 口令强度 + 会话按设备管理 + 多进程并发压测（20/30/40/50 抢同数号源全部卖光；并发退号零丢号） | ✅ **完成** |
| **P2** | **AI 分诊（工程纪律层）**：危急征象兜底（词表 + 否定 + 共现）+ **验证层（绝不给没号的推荐）** + 三态结论 + `POST /api/v1/triage` + **预问诊多轮采集（SSE 流式）**。★ 真模型已于 P3 收尾时接通；未配置时 `source=rules`。见 [阶段交接 P2](docs/PHASE-HANDOFFS.md) | ✅ **完成** |
| **P3** | **AI 能力中心（配置底座）**：`ai_setting` KV + **改配置零重启** + ★★ **密钥不引用不落库**（`env:`/`file:` 引用，机制性拒绝裸密钥）+ 脱敏回显 + Prompt 模板落库 + AI 工具开关落库。⚠ 合规决策见 [Q6-合规决策记录](docs/Q6-合规决策记录.md)。见 [阶段交接 P3](docs/PHASE-HANDOFFS.md) | ✅ **完成** |
| **P4** | **电子病历 + 运营看板**：七段式病历（草稿 → **提交锁定，锁定后不可改**）+ 医生**接诊队列**（状态机）+ 患者只读档案 + 看板（只出聚合不出明细）。★ 顺带把 `medical_record` 移出内存 Store 改直接 SQL（[ADR-0001](docs/adr/ADR-0001-号源与挂号独立MySQL路径.md) rev.6），并在收尾时**整体拆除内存 Store**（rev.7，全库只剩一种数据访问范式）。见 [阶段交接 P4](docs/PHASE-HANDOFFS.md) | ✅ **完成** |
| **P5** | **RAG 知识库（零向量库）**：切块（带重叠、结构性不丢内容）→ 向量存 MySQL JSON（**纯仓颉余弦**）→ 关键词检索为默认路 + 向量路；管理端 CRUD + 检索；RAG 片段接进分诊（过安全层、改不了 `options`）+ 看板知识库规模。⚠ DeepSeek 无 embeddings 端点 ⇒ 向量路未做端到端验证。见 [阶段交接 P5](docs/PHASE-HANDOFFS.md) | ✅ **完成** |
| **客户端** | **鸿蒙患者端 / 医生端 / 管理端**（`entry` + `common-core` + `feature-*`）+ **安卓患者端**（`android-patient`）+ **管理台网页**（`server/admin-web`，挂载在 `/admin`） | ✅ 已实现并可构建；**2026-10-17 已在华为模拟器（Pura 90 / HarmonyOS 6.1.1 / API 24）跑通患者全流程与管理端看板**（[证据](release/harmony/README.md)）；**2026-10-18 安卓端已用 JDK 21 编译并装进 Android 模拟器登录成功**（[证据](release/android/README.md)） |
| **维护批次** | 2026-10-17 复验修复 10 条（S1/S2/S3/S5/S6/S8/S12/S14/S16 + S4/S13）、契约与文档同步 | ✅ 完成（[复验报告](docs/REVERIFY-AND-FIXES-2026-10-17.md)） |

> **验收口径**：`selftest` 51 + `authtest` 17 + `triagetest` 150 + `accept` **794 条断言** + `server/tests/` 26 个测试文件（19 个可独立运行的门禁套件）+ 契约门禁（24 Schema / 67 样例）+ `final-verify` 18/18 全绿。
> ⚠ 文档里的项数以 **`server/tests/doc-counts.ps1` 的实测输出为准**，不靠人记。

> **自动门禁**：CI（`.github/workflows/repo-hygiene.yml`）每次 push/PR 跑 `tools/check-docs.ps1` ——
> 查文档相对链接、脚本 UTF-8 BOM、批处理纯 ASCII、旧仓库路径残留。本地等价命令：
> `powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\check-docs.ps1`。
> 服务端重活（`build.ps1` + `server/tests/` + `final-verify.ps1`）需 cjc 与 MariaDB 实例，仍按 `docs/DEPLOYMENT.md` 手工跑。

---

## 目录结构

| 路径 | 是什么 |
| --- | --- |
| [docs/](docs/) | **全部文档**：项目说明 / 系统设计 / 部署 / 第三方 / 接口口径 / 架构决策 / 阶段交付记录 |
| [server/](server/README.md) | **服务端**（自包含）：`src/` **38 个 `.cj`** + `third_party/`（轻舟框架 47 个 `.cj`，其中参与编译 38 个；MariaDB 驱动 47 个 `.cj`，均为使用副本）+ 6 个构建运维脚本 + `tests/` **26 个测试文件**（25 个 `.ps1` + `admin-web-smoke.mjs`） + `admin-web/` 管理台 |
| [contract/](contract/README.md) | **可执行接口契约**：67 个样例 + 24 个 Schema + 映射表 + 变更日志 |
| `entry/` + `common-core/` + `feature-patient/` + `feature-doctor/` + `feature-admin/` | **鸿蒙三端**（ArkTS / ArkUI V2）：HAP 壳 + 公共层 + 三个 HAR 业务模块 |
| [android-patient/](android-patient/README.md) | **安卓患者端**（Kotlin Views，AGP 8.5.2 / Gradle 8.7 / minSdk 26） |
| [tools/](tools/) | 打包脚本（生成可运行程序包） |

---

## 快速开始

```powershell
cd server
.\setup-runtime.ps1 -Force          # 恢复 OpenSSL 运行时依赖（首次）
.\devdb.ps1 start                   # 起仓库自管 MariaDB（端口 3317，数据在 devdb\data）
.\build.ps1                         # 仓颉编译（框架与业务同一次 cjc 调用）
.\export-ca-bundle.ps1              # 导出 CA 包（供 AI 出站 TLS 校验；换网络后重导一次）
$env:SSL_CERT_FILE = "$PWD\ca-bundle.pem"
.\build\hospital-server.exe serve mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital_test --dev-auth
curl.exe -s http://127.0.0.1:8091/health
```

> **AI 开箱即用**：默认 `ai.enabled=1` + 密钥引用 `builtin:demo` + DeepSeek `deepseek-chat`，
> 装完即可真调模型（启动日志会打印「AI：已启用 … 密钥引用 builtin」）。
> **这把演示密钥有有效期**（`AI_BUILTIN_DEMO_VALID_UNTIL = 2026-12-31`，见
> [server/src/ai_builtin.cj](server/src/ai_builtin.cj)）：到期后服务端会**拒绝**它，并把
> 「到期日 + 换法」写进失败原因，而不是静默降级成规则。
> 想用自己的密钥，一条命令：
>
> ```powershell
> .\tools\set-ai-key.ps1 -ApiKey sk-你自己的 -AdminPw <管理员口令>
> ```
>
> 它会写 `server\ai-key.txt`（已 gitignore）、把 `ai.key_ref` 改成 `file:<绝对路径>`、
> 再调一次模型自检确认 `ok=true`。库里始终只存**引用**，不存密钥本体。
> 背景与合规口径见 [docs/Q6-合规决策记录.md](docs/Q6-合规决策记录.md)。
> 为什么需要 `SSL_CERT_FILE`：仓颉 stdx 走 OpenSSL、不读 Windows 证书存储，缺它会报
> `TLS handshake failed (client): certificate verify failed (134)`；而 `curl` 访问同一端点正常。

鸿蒙客户端构建（**一条命令**，仓库根自带 `hvigorw.bat`，自动探测本机 DevEco Studio）：

```powershell
cd smart_hospital
.\hvigorw.bat --mode module -p product=default -p module=entry@default assembleHap --no-daemon
# 产物：entry/build/default/outputs/default/entry-default-unsigned.hap（未签名，约 1.7 MB）
```

> **已入库的构建与运行证据**：[release/harmony/](release/harmony/README.md) 内有 2026-10-17 的
> `entry-default-unsigned.hap`（1758339 B，SHA256 `70A7EB53…CC17479D`）、`pack.info`、完整构建日志
> （`BUILD SUCCESSFUL`，65 tasks），以及**模拟器实跑的 11 张截图 + 对应 `dumpLayout` 文本实测**
> （患者登录 → 首页 → 智能分诊 → 选号 → 挂号成功 → 我的就诊；管理端登录 → 运营看板 → AI 能力中心）。
> **未签名 HAP 可直接装进模拟器**（`hdc install -r …hap`），签名只在分发给真机时需要。
>
> ⚠ **仓库目录改名后必做**：`oh_modules/` 里指向模块的 junction 仍是旧绝对路径，需重新链接一次
> （`ohpm install` 或按 [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) §鸿蒙构建 的 `mklink /J` 重连），
> 否则会报 `10505001 ArkTS Compiler Error: Cannot find module 'common-core'`。

完整步骤、生产模式（`--prod` + TLS）、鸿蒙/安卓构建、可运行程序包、故障排查见 **[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md)**。

---

## 阅读顺序

| 你的目的 | 先读 |
| --- | --- |
| 了解项目是什么、做了什么创新 | [docs/PROJECT-OVERVIEW.md](docs/PROJECT-OVERVIEW.md) |
| 看架构与技术实现 | [docs/SYSTEM-DESIGN.md](docs/SYSTEM-DESIGN.md) → [adr/ADR-0001](docs/adr/ADR-0001-号源与挂号独立MySQL路径.md) |
| 把系统跑起来 / 交付部署 | [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) · [docs/DEV-DB.md](docs/DEV-DB.md) |
| 写客户端 / 对接接口 | [docs/FRONTEND-INTEGRATION.md](docs/FRONTEND-INTEGRATION.md)（唯一口径）· [docs/HARMONY-INTERFACE-GUIDE.md](docs/HARMONY-INTERFACE-GUIDE.md) |
| 看 UI 规范 | [docs/UI-DESIGN.md](docs/UI-DESIGN.md) |
| 查历史决策与踩坑 | [docs/PHASE-HANDOFFS.md](docs/PHASE-HANDOFFS.md)（P0–P5 合并稿）· [复验报告](docs/REVERIFY-AND-FIXES-2026-10-17.md) |
| 确认第三方合规 | [docs/THIRD-PARTY.md](docs/THIRD-PARTY.md) · [Q6-合规决策记录](docs/Q6-合规决策记录.md) |

---

## 未决问题

见 [docs/PHASE-HANDOFFS.md](docs/PHASE-HANDOFFS.md) 附录「启动时的 6 个待决问题」，共 6 条。

| # | 问题 | 状态 |
| --- | --- | --- |
| Q1 | 新建空仓再选择性搬运，还是 fork 既有仓库？ | ✅ **已决**：新建工作区 + 选择性搬运 |
| Q2 | 数据模型范围：先建哪几张表？ | ✅ **已决（P0）**：最小 8 张（业务 6 + 鉴权 2），现扩展到 **17 张**（含 AI/知识库/预问诊/统计） |
| Q3 | 患者端页面范围？ | ✅ **已决**：主闭环 6 页（登录 / 分诊 / 预问诊 / 约号 / 我的预约 / 我的）+ 档案 / 公告，已由鸿蒙与安卓两端实现 |
| Q4 | 管理端前端是否复用既有 Vue 3 工程？ | ✅ **事实已收敛**：未复用 Vue，改为**零第三方依赖的原生 JS 管理台**（`server/admin-web/`），由服务端静态托管在 `/admin` |
| Q5 | 单院区量级：日门诊量？号源放出峰值并发？ | ⏳ 未决 —— 影响扣号路径是否要加重试/排队 |
| Q6 | AI 模型选型与合规 | 🟡 选型未决；出站合规口径已落档（[Q6](docs/Q6-合规决策记录.md)） |
