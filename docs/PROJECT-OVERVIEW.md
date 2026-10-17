# 智慧医院智能导诊就诊系统 · 项目说明

> **一句话**：患者输入一句主诉 → AI 多步推理取证 → 推荐科室与医生 → **校验真实有号** → 一键挂号 → 医生接诊 → 生成七段式电子病历，全程落库、可追溯、可观测。
>
> 本文是**面向评审/验收的项目说明**（背景、需求、功能模块、创新点、应用价值）。
> 工程决策细节见 [HISTORY-PROJECT-BRIEF.md](HISTORY-PROJECT-BRIEF.md)，技术实现见 [SYSTEM-DESIGN.md](SYSTEM-DESIGN.md)。

---

## 1. 项目背景

**业务背景**：门诊是医院里最拥堵的一环。患者说不清症状 → 挂错科 → 反复退号重挂；医生在诊室里再问一遍已经问过的病史；病历质量完全依赖医生当场的记忆与手速；院方则拿不到"分诊准不准、号源用没用完、AI 到底帮了多少忙"这类数据。

**行业现状**：头部三甲已上线智慧医院，但实现方案普遍偏重——`FastAPI + LangChain + Redis + 向量数据库 + Vue3` 一套下来，一个单院区要维护五六个中间件。中小医院与校医院没有对应运维能力，导致这类系统"做得起、养不起"。

**本项目的技术背景**：团队具备**仓颉（Cangjie）+ 轻舟（QingZhou）**能力。仓颉是华为自研的国产化语言，轻舟是仓颉生态的 Koa 风格 Web 框架。把智慧医院的核心闭环用**国产化技术栈**重做一遍，既能验证仓颉在真实业务（并发、事务、流式、AI 编排）上的工程可用性，也是一份可直接交付的信创改造参考实现。

**为什么是"读一个参考系统 + 重写"**：项目启动时以某开源智慧医院方案为能力基线（19 个路由模块 / 21 张业务表 / 约 80 个 REST / 三端角色），逐条判断"哪些能力本仓库已有、哪些要新写、哪些是仓颉侧做不到的"，再按 P0–P5 六个阶段落地。**逐条映射与取舍**留在 [HISTORY-PROJECT-BRIEF.md §2/§4](HISTORY-PROJECT-BRIEF.md)，不在此重复。

---

## 2. 需求分析

### 2.1 角色与核心场景

| 角色 | 核心场景 | 关键诉求 |
| --- | --- | --- |
| **患者** | 说不清该挂哪个科 → 填一句主诉 → 拿到带**真实可约号源**的科室/医生推荐 → 补全预问诊 → 挂号 → 看就诊进度与病历 | 推荐必须可执行（不能推一个没号的科室）；挂号不能重复、不能超卖；界面要能说清"现在到哪一步了" |
| **医生** | 看今日接诊队列 → 到院/叫号/接诊 → 录入七段式病历 → 提交锁定 | 队列顺序稳定；病历草稿不丢、一旦定稿不可改（医疗数据不可篡改）；既往病历随手可查 |
| **管理员** | 维护科室/医生/排班号源；重置账号密码；配置 AI 能力中心与知识库 | 改配置**不重启**；密钥**不落库**；看板只出聚合不出明细 |

### 2.2 功能需求（编号可追溯）

| 编号 | 需求 | 验收方式 |
| --- | --- | --- |
| FR-1 | 主诉 → AI 推荐科室/医生，且**推荐里只能出现当前有号的科室** | `POST /api/v1/triage` + 校验层（`server/src/triage.cj`）+ 验收用例 `acceptance_triage.cj` |
| FR-2 | 危急征象必须先于 AI 结论命中（词表 + 否定 + 共现） | `server/src/triage_redflag.cj` + `triage-check.ps1` |
| FR-3 | 预问诊多轮采集，**流式**回显（SSE） | `server/src/previsit.cj` + `previsit-check.ps1` |
| FR-4 | 挂号：幂等（同 `client_token` 不重复建单）、并发不超卖、退号归还号源 | `domain_booking.cj` + `stress-booking.ps1`（20/30/40/50 进程抢同数号源） |
| FR-5 | 接诊队列状态机：到院/候诊/接诊中/完成/取消，非法跃迁一律拒 | `domain_emr.cj:visitTransitionAllowed` + `visit-timeline-check.ps1` |
| FR-6 | 七段式电子病历：草稿 → **提交锁定**，锁定后不可改；修订历史可查可对比 | `domain_emr.cj` + `emr-check.ps1` / `revision-check.ps1` |
| FR-7 | 运营看板：科室/挂号趋势/号源使用率/分诊命中/预问诊完成率/病历进度/AI 概览 | `dashboard.cj` + 管理台页面 |
| FR-8 | AI 能力中心：模型配置、Prompt 模板、密钥引用、工具开关**全部落库、改完即生效** | `ai_settings.cj` / `ai_prompt.cj` + `ai-model-check.ps1` |
| FR-9 | 零向量库知识库：文档切块 + 关键词检索（默认路）+ 向量路（配 embedding 即启用），片段可进分诊但**改不了推荐** | `domain_kb.cj` / `kb_repo.cj` + `kb-check.ps1` |
| FR-10 | 三端权限：患者/医生/管理员各自只能做自己的事 | `http_app.cj` 角色守卫 + `auth-check.ps1` / `base-check.ps1` |

### 2.3 非功能需求

| 维度 | 要求 | 实现 |
| --- | --- | --- |
| **安全** | 口令不可逆存储；令牌不透明；**AI 密钥不落库**；管理动作按角色隔离；不泄露驱动/堆栈细节 | PBKDF2-HMAC-SHA256 × 100000 + 16B salt；64-hex 不透明令牌；密钥只存 `env:`/`file:` 引用（裸密钥机制性拒收）；`/health` 失败只给固定短句 |
| **并发** | 抢号不能超卖，退号不能丢号 | 参数化原子 `UPDATE … WHERE remain_num > 0` + 唯一键 + 同事务 INSERT |
| **可用** | AI 挂了业务不能挂；数据库闪断不能全站 500 到重启 | 三态降级（`rules` / `model` / `model:invalid`）；DB 断链自愈 + `/health` 探库（503） |
| **可运维** | 改 AI 配置不重启；升级不加手工步骤 | 配置落库 + 缓存失效；自动建表 + 编号迁移（幂等） |
| **合规** | 明确"发什么出站、默认关不关、谁能打开" | [Q6-合规决策记录.md](Q6-合规决策记录.md) |
| **可验证** | 单元/验收/契约/压测/全量 live 门禁 | `selftest` 51 + `authtest` 17 + `triagetest` 139 + `accept` 777 断言 + `final-verify` 18 项门禁 + 契约门禁（24 Schema / 67 样例） |

### 2.4 范围边界（本期**不做**）

自助注册 / 改密、支付与医保结算、多院区与多租户、短信/推送、离线队列（**挂号与 AI 调用必须在线直连**，排队等于超卖）、医生排班的图形化编辑器。理由与替代方案见 [HISTORY-PROJECT-BRIEF.md §10](HISTORY-PROJECT-BRIEF.md)。

---

## 3. 功能模块

| 模块 | 主要能力 | 落点 |
| --- | --- | --- |
| **患者端**（鸿蒙 ArkTS） | 登录 / 首页（下一次就诊）/ AI 分诊 / 预问诊流式 / 约号 / 我的就诊 / 医疗档案 / 公告 / 我的 | `entry/` + `common-core/` + `feature-patient/` |
| **患者端**（安卓 Kotlin） | 同一闭环的安卓实现（Kotlin Views + AGP 8.5.2） | `android-patient/` |
| **医生端**（鸿蒙） | 接诊队列、病历工作台（七段式 + 乐观锁 + 冲突核对）、修订历史 | `feature-doctor/` |
| **管理端**（鸿蒙 + 网页） | 用户/科室/医生/排班/号源、AI 能力中心、知识库、看板 | `feature-admin/`、`server/admin-web/`（由服务端挂载在 `/admin`） |
| **AI 能力中心** | 模型配置（对话/向量分开）、Prompt 模板、密钥引用、工具开关、启动自检 | `server/src/ai_settings.cj`、`ai_prompt.cj`、`ai_model.cj` |
| **AI 分诊编排** | 危急征象 → 规则候选 → （可选）模型增强 → 校验层 → 三态结论 + RAG 片段 | `triage.cj`、`triage_redflag.cj`、`ai_triage.cj`、`ai_call.cj` |
| **预约挂号域** | 号源查询、原子扣减、幂等建单、退号归还、就诊时间线 | `domain_booking.cj`、`http_app.cj` |
| **电子病历域** | 七段式草稿、提交锁定、修订快照与差异 | `domain_emr.cj`、`http_p4.cj` |
| **知识库（RAG）** | 文档 CRUD、切块、关键词检索、向量路、片段入分诊 | `domain_kb.cj`、`kb_repo.cj`、`http_kb.cj` |
| **运营看板** | 聚合指标（不出明细） | `dashboard.cj` |
| **鉴权与安全** | 令牌、PBKDF2、登录限流/锁定、会话按设备、三端角色守卫 | `auth_crypto.cj`、`auth_repo.cj`、`http_common.cj` |
| **契约与测试** | 81 个 REST 的可执行契约（样例 + Schema + 门禁）、单元/验收/压测/全量门禁 | `contract/`、`server/src/acceptance*.cj`、`server/tests/` |

> 模块划分的层次与依赖方向见 [SYSTEM-DESIGN.md §2](SYSTEM-DESIGN.md)。

---

## 4. 创新点

> 关键区分：8 条里有 3 条是**工程纪律**（不接大模型也必须有），恰恰也是最容易出安全事故的部分；本仓库在这 3 条上是**有测试保护的生产级状态**。

| # | 创新点 | 本质 | 本仓库做法（可指认） | 类别 |
| --- | --- | --- | --- | --- |
| ① | **数据库驱动的 AI 能力中心** | 配置外置 + 缓存失效 | `ai_setting` / `ai_model` / `ai_prompt` 三张表 + 改完零重启（`ai_settings.cj`） | 技术 |
| ② | **先取证后结论，把幻觉关进笼子** | 模型输出 = 不可信输入 | 模型只能改"表述"，**改不了 `options`**；校验层复查号源真实可约（`ai_triage.cj`、`triage.cj`） | 纪律 |
| ③ | **医疗级安全兜底** | 纯规则保险丝 | 危急征象词表 + 否定词 + 共现，"胸痛但已缓解"不误报（`triage_redflag.cj`） | 纪律 |
| ④ | **全链路可观测** | 审计 + 聚合 | 分诊 `reason_code` / `ai_reason` / `degrade_reason`、AI 遥测、看板只出聚合（`triage_stat.cj`、`dashboard.cj`） | 技术 |
| ⑤ | **业务闭环 + 数据闭环** | 转化回写 | 分诊命中、挂号转化、预问诊完成率回写统计表 | 技术 |
| ⑥ | **零向量库轻量 RAG** | 自建检索 | 切块 + MySQL JSON 存向量 + **纯仓颉余弦**；关键词路为默认（`kb_repo.cj`） | 技术 |
| ⑦ | **模型无关 + 优雅降级** | 统一协议 + 降级不中断 | 兼容 OpenAI 形状的 `chat/completions`；失败/超时/输出不合规一律降级到规则，`source` 如实标注 | 纪律 |
| ⑧ | **接口契约可执行** | 契约即测试 | `contract/examples`（67 样例）+ `contract/schema`（24 Schema）+ 逐字节/结构双门禁 | 技术 |
| ⑨ | **单实例、零中间件**（本仓库新增） | 部署成本 | 不需要 Redis / 向量库 / 消息队列；数据库断链可自愈，不依赖进程重启（`db_mysql.cj`） | 技术 |
| ⑩ | **国产化栈的工程可行性验证**（本仓库新增） | 技术选型 | 仓颉跑通并发抢号、SSE 流式、事务、AI 编排、静态托管与管理台 | 技术 |

> ⑨⑩ 是本仓库相对参考系统的**差异化贡献**：参考系统用 5 个中间件换来能力，本项目用**一种数据访问范式**（直接 SQL + 事务）与**一套降级纪律**换来等价能力。

---

## 5. 应用价值

**对患者**：把"该挂哪个科"从经验判断变成**可执行推荐**——推荐里每个科室都能当场约到号，不白跑一趟；就诊进度（已挂号 → 已到院 → 候诊 → 接诊中 → 完成）在端上可见。

**对医生**：病历从"事后补"变"当场成稿"，七段式结构化 + 定稿锁定，既往病历按就诊时间一键可查，减少重复问诊与漏项。

**对医院管理者**：拿到分诊命中率、号源使用率、预问诊完成率这些**可动决策的数据**；AI 能力可开关、可换模型、可审计，不需要停机。

**对信创改造**：整套系统在国产语言（仓颉）与国产框架（轻舟）上跑通了一条完整的医疗业务闭环，可作为同行业系统迁移的**参考实现**——包括踩过的坑（字节/字符、`NO_BACKSLASH_ESCAPES`、断链重连）都写进了 ADR 与交接文档。

**可复用资产**（与业务无关，可直接搬到别的仓颉项目）：

| 资产 | 位置 |
| --- | --- |
| Koa 风格中间件 + Trie 路由 + SSE/chunked 出站流式 + 静态/gzip/Range/ETag | `server/third_party/qingzhou/` |
| 数据库抽象 + 参数化绑定 + 事务 + **断链自愈 + 探活** | `server/third_party/qingzhou/src/db*.cj` |
| 统一信封 + 错误码表 + 角色守卫 + 请求体上限统一封装 | `server/src/http_common.cj` |
| 契约门禁（导出机 + Schema + 逐字节比对） | `contract/`、`server/tests/contract-check.ps1` |
| AI 编排纪律（三态降级 / 校验层 / 密钥引用不落库） | `server/src/ai_*.cj` |
| 全量 live 门禁（一条命令 17 次运行 / 16 个脚本） | `server/tests/final-verify.ps1` |

---

## 6. 项目团队

按 `git shortlog -sne` 实测（2026-10-07 → 10-17，截至 tag `v0.2.0-p1-rev` 共 107 个提交）：

| 贡献者 | 提交数 |
| --- | --- |
| XueDric | 84 |
| Haocheng Sun | 8 |
| fallensp | 6 |
| lyz1679 | 4 |
| FallenSP78 | 3 |
| pyf | 2 |

> 合计 **107** 个提交（截至 tag `v0.2.0-p1-rev`）。`fallensp` 与 `FallenSP78` 是两个不同的提交身份（不同邮箱），未合并统计。

协作方式：服务端（仓颉）与三端客户端（鸿蒙 ArkTS / 安卓 Kotlin / 管理台）并行推进，接口以 [contract/](../contract/) 的可执行契约 + [FRONTEND-INTEGRATION.md](FRONTEND-INTEGRATION.md) 为唯一口径，跨端分歧以契约门禁红/绿判定。

---

## 7. 交付物索引

| 交付项 | 文档 |
| --- | --- |
| 项目说明（本文） | `docs/PROJECT-OVERVIEW.md` |
| 系统设计（架构/模块/接口/数据流/关键技术） | [SYSTEM-DESIGN.md](SYSTEM-DESIGN.md) |
| 源码仓库与版本历史 | [README](../README.md) · [CHANGELOG](../CHANGELOG.md) |
| 部署、环境配置、可运行包 | [DEPLOYMENT.md](DEPLOYMENT.md) |
| 开源组件 / 模型 / 外部 API / 数据集 | [THIRD-PARTY.md](THIRD-PARTY.md) |
| 接口逐字段口径（前端唯一口径） | [FRONTEND-INTEGRATION.md](FRONTEND-INTEGRATION.md) |
| 架构决策记录 | [adr/ADR-0001](adr/ADR-0001-号源与挂号独立MySQL路径.md) |
| 阶段交付与验收证据 | `P0`–`P5`-HANDOFF、[REVERIFY-AND-FIXES-2026-10-17.md](REVERIFY-AND-FIXES-2026-10-17.md) |
| AI 出站合规 | [Q6-合规决策记录.md](Q6-合规决策记录.md) |
