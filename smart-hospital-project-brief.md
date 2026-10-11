# 智慧医院智能导诊就诊系统 · 项目启动说明

> 📁 **新项目交接** ｜ 本文件：`smart-hospital-project-brief.md`
>
> **生成时间**：2026-10-07 ｜ **最近一次整理**：2026-10-11（资产盘点改为"落点在本仓库哪里"，去掉搬迁前的出处标注）
>
> **用途**：启动「智慧医院智能导诊就诊系统」时的**唯一上下文入口**。
> 新会话把本文件整份读完即可接续，不需要回读原对话。
>
> 📌 **本仓库现状**：只保留服务端 `server/`（仓颉 + 轻舟，**自包含**：框架与数据库驱动以使用副本形式放在 `server/third_party/`）。
> **客户端（鸿蒙患者端）由客户端同学另行开发**，接口口径**只以** **[docs/FRONTEND-INTEGRATION.md](docs/FRONTEND-INTEGRATION.md)** 为准；
> 服务端的实际接口以 `server/src/` 与那份对接说明为准（本文件的端点描述早于 P2–P5）。
> 源码注释里对早期实现的引用已统一写作「**搬迁前**」，只作口径出处说明，不指向本仓库内的任何路径。

---

## 0. 这份文档怎么用

| 你在做什么 | 读哪一节 |
| --- | --- |
| 刚进新工作区，想知道项目是什么 | §1、§2 |
| 想知道**现成的东西落在哪** | §3、§4 |
| 想知道**难点在哪、别踩什么坑** | §5 ★ 最重要 |
| 想知道技术选型为什么这么定 | §6、§7 |
| 想知道做过什么、还差什么 | §8 |
| 开工前要先拍板什么 | §10 |
| 找代码落点 | 附录 A |

> ⚠️ **第 1 节是已决事项**，除非有新的外部约束，**不要重新讨论**。
> ⚠️ 凡标注「**推断**」的数字（尤其工期）都是**未实测的粗估**，落地前请自行验证。

---

## 1. 项目定位与已确认决策

**项目名**：智慧医院智能导诊就诊系统
**一句话**：患者输入一句主诉 → AI 多步推理取证 → 推荐科室与医生 → 校验真实有号 → 一键挂号 → 医生接诊 → 生成电子病历，全程落库、可追溯、可观测。

| # | 决策项 | 结论 | 影响 |
| --- | --- | --- | --- |
| 1 | **技术能力** | 具备仓颉 / 轻舟 / ArkTS 能力 | ✅ 走**路线 A：全仓颉**（§6） |
| 2 | **患者端形态** | **鸿蒙 App（ArkTS）** | ✅ **由客户端同学另行开发**；接口口径见 [docs/FRONTEND-INTEGRATION.md](docs/FRONTEND-INTEGRATION.md) |
| 3 | **规模预期** | **单院区**（暂定） | ✅ 单实例部署即可，且**不需要 Redis** |
| 4 | **合作方** | **暂无** | ✅ 合规不阻塞，可按产品原型节奏推进；但见 §9 风险 R-4 |
| 5 | **技术路线** | 路线 A：仓颉 + 轻舟承载后端与 AI 编排；管理端前端另立一期 | 详见 §6、§7 |

---

## 2. 参考系统能力基线

**来源**：一篇微信公众号文章（`https://mp.weixin.qq.com/s/wQEM952_INw_wdymkKYHEw`）。
⚠️ 该 URL **直接抓取拿不到正文**（微信返回「环境异常/去验证」拦截页）；**本文档的参考基线来自用户手工复制的原文文字**，未做二次核验。

**参考系统技术栈**（原文口径）：FastAPI + SQLAlchemy 2.0 + Pydantic v2 + JWT/passlib + LangChain + 手写 ReAct Agent + 阿里云百炼 DashScope + MySQL 8 + Vue 3 + Element Plus。19 个路由模块、21 张业务表、约 80 个 REST 接口、三端角色（患者/医生/管理员）。

### 2.1 功能拆解（7 块）

1. **患者端**：智能分诊、智能预问诊（SSE 流式多轮采集）、预约挂号（乐观锁扣号 + 取消归还）、我的就诊/医疗档案/公告
2. **医生端**：门诊接诊队列（开始/结束/取消）、电子病历七段式（主诉/现病史/既往史/过敏史/体格检查/诊断/处理意见）草稿保存 + 提交锁定
3. **管理端-基础数据**：用户、科室、医生、排班号源、患者档案、症状标签库（一键顺延排班、重置号源、开通医生账号）
4. **管理端-AI 能力中心**：模型配置（对话/向量分开）、Prompt 模板管理、医学知识库、工具中心（MCP 8 个工具）、Agent 与 AI 观测
5. **运营看板**：科室医生患者规模、挂号趋势、号源使用率、分诊命中率、AI 调用概览
6. **接口与权限**：约 80 个 REST、三端权限由后端依赖守卫强制校验、登录按角色自动分流
7. **工程化**：通用 CRUD 路由工厂、动态 Pydantic Schema、统一响应 `{code,msg,data}`、全局异常、脚手架生成器

### 2.2 创新点拆解（8 条）—— ★ 关键是识别出「哪些是纪律、哪些是技术」

> 下表是**启动时点**对参考系统创新点的判断；到 P5 为止，①③④⑤⑥ 均已落地，逐项落点见 **§4**。

| # | 原文创新点 | **本质** | 启动时判断：本仓库是否已有等价物 |
| --- | --- | --- | --- |
| ① | 数据库驱动的 AI 能力中心（改配置零重启） | 配置外置 + 缓存失效 | ❌ 没有 → **P3 已落地** |
| ② | 先取证后结论，把幻觉关进笼子 | **模型输出视为不可信输入** | ✅ **已有且更严** |
| ③ | 医疗级安全兜底（24 危急关键词 + `is_red_flag`） | 纯规则保险丝 | 🟡 形状有，规则要新写 → **P2 已落地** |
| ④ | 全链路可观测（Agent 时间线/工具日志/模型日志） | 审计 + 可视化 | 🟡 审计有，时间线无 → **P4 部分落地（看板只出聚合）** |
| ⑤ | 业务闭环 + 数据闭环（`converted=1`、分诊命中率） | 转化回写 | 🟡 幂等有，回写要新写 → **P2/P4 已落地** |
| ⑥ | 零向量库轻量 RAG（MySQL JSON 存向量 + 纯 Python 余弦） | 自建检索 | ❌ 完全没有 → **P5 已落地（纯仓颉余弦）** |
| ⑦ | 模型无关 + 优雅降级 | 统一协议 + 降级不中断业务 | ✅ **已有** |
| ⑧ | 工程化提效（CRUD 工厂/动态 Schema/脚手架） | 元编程生产力 | ❌ 仓颉侧做不到同等（§6） |

> **本分析的核心洞察**：8 个创新点里，**②④⑦ 三条是「工程纪律」而非「接大模型」**，
> 恰恰也是这个系统**最难写、最容易出安全事故**的部分 —— 而这部分在本仓库**是有测试保护的生产级状态**。
> 反过来，⑧ 那类「省事」的部分，是仓颉侧最弱的地方。

### 2.3 参考系统的两个关键技术方案（值得照搬）

- **防超卖**：排班表 `version` 乐观锁 + 扣减带 `remain_num > 0` 条件
- **顺延不串号**：挂号单保存 `visit_date` **就诊日快照**，管理员一键顺延排班不影响已挂患者

---

## 3. 技术资产与落点（本仓库）

> 证据等级标注：**✅实测** = 本次在代码中直接核验到；**📄文档** = 仓库文档记载，未逐行复核。

### 3.1 框架层 —— 轻舟（QingZhou）

| 资产 | 落点 | 等级 |
| --- | --- | --- |
| 轻舟 v0.12.0 使用副本（框架快照 `MANIFEST.sha256`、连接池、健康检查、生命周期钩子、优雅关闭） | `server/third_party/qingzhou/` | 📄 |
| **SSE / chunked 流式响应原生支持**：`streamStart(contentType)` + `writeChunk()`（`String` 与 `Array<UInt8>` 两个重载），handler 返回后自动写 last-chunk | `server/third_party/qingzhou/src/context.cj:301`、`:314`、`:325` | ✅ |
| **出站 SSE / chunked 透传**（边读边转发，用完 `close()` 释放连接） | `server/third_party/qingzhou/src/httpclient.cj` | ✅ |
| 洋葱中间件、Trie 路由、静态/gzip/Range/ETag/multipart/签名 cookie | `server/third_party/qingzhou/src/` | 📄 |

> 🔥 **这是启动时最大的好消息**：参考系统的「预问诊流式打字机」在轻舟上**近乎零成本** —— P2 已落地（`server/src/previsit.cj`）。

### 3.2 数据访问层 —— 防超卖的**技术前提已具备**

| 能力 | 落点 | 等级 |
| --- | --- | --- |
| `exec(sql): Int64` / `exec(sql, params): Int64` —— **返回受影响行数**（参数化占位符 `?`） | `server/third_party/qingzhou/src/db.cj:105`、`:129` | ✅ |
| `withTransaction(body)` —— 自动 begin/commit/rollback | `server/third_party/qingzhou/src/db.cj:152` | ✅ |
| `dbRaw(sql, ps)` —— 需要「列表达式」时用（如 `col = col - 1`） | `server/third_party/qingzhou/src/dbquery.cj:89` | ✅ |
| `SelectQuery` / `UpdateQuery` / `InsertQuery` 构建器 + `exec(be)`（注意 `UpdateQuery.set` 只接受**值**，不接受表达式） | `server/third_party/qingzhou/src/dbquery.cj:484-606` | ✅ |
| **本仓库数据层现状**：表与迁移 | `server/src/schema.cj` | ✅ |
| **本仓库数据层现状**：连接/自检/启动 | `server/src/db_bootstrap.cj`、`server/src/main.cj` | ✅ |

> ⚠️ 搬迁前的服务端曾有一条「全量载入内存 + 全局锁 + 每次提交整体替换各表」的旧持久化范式。
> 它已于 P4 收尾**整体拆除**（[ADR-0001](docs/adr/ADR-0001-号源与挂号独立MySQL路径.md) **rev.6 / rev.7**）：
> 现在全库只有**一种**数据访问范式 —— **直接 SQL + 事务**，`exec()` 的受影响行数就是扣号/归还的判据。

### 3.3 业务机制层 —— 已落地

| 机制 | 落点 | 等级 | 用法 |
| --- | --- | --- | --- |
| **幂等**：`client_token` + 唯一索引 `uk_appointment_patient_token (patient_id, client_token)`；**退号把 token 置 NULL**（键可复用） | `server/src/domain_booking.cj`、`server/src/schema.cj:328` | ✅ | 防重复挂号 |
| **限流**：登录失败节流 → `429 AUTH_RATE_LIMITED`（响应头 `retry-after`） | `server/src/http_app.cj:790`、`server/src/http_common.cj:75` | ✅ | 抢号/登录防护 |
| **鉴权**：不透明令牌 + PBKDF2 100k；三端角色守卫 | `server/src/auth_crypto.cj`、`server/src/auth_repo.cj` | ✅ | 患者/医生/管理员 |
| **统一响应与错误码表**：`sendOk` / `sendCreated` / `sendError` + `apiErrorSpec(code): (状态码, 默认文案)` | `server/src/http_common.cj:55`、`:225`、`:241` | ✅ | 直接复用 |
| **权限收敛**：角色不满足一律 `apiError("FORBIDDEN_ROLE")`，不在 handler 里手写分支 | `server/src/http_common.cj`、`server/src/http_app.cj` | ✅ | 三端角色 |

### 3.4 AI 编排层 —— **本仓库最值钱的资产**

| 能力 | 落点 | 等级 |
| --- | --- | --- |
| **模型出站 + 三态降级**：模型失败/超时/输出不合规一律**降级不抛异常**，兜底不得为空 | `server/src/ai_call.cj` | ✅ |
| **AI 能力中心（DB 驱动配置）**：`ai_setting` KV + 改配置零重启 + ★★ **密钥不落库**（只存 `env:`/`file:` 引用，机制性拒绝裸密钥） | `server/src/ai_settings.cj` | ✅ |
| **Prompt 模板落库**（缺占位符即拒） | `server/src/ai_prompt.cj` | ✅ |
| **分诊编排** + **验证层（绝不给没号的推荐；模型不能改 `options`）** | `server/src/ai_triage.cj`、`server/src/triage.cj` | ✅ |
| **危急征象兜底**（词表 + 否定 + 共现） | `server/src/triage_redflag.cj` | ✅ |
| **RAG 片段接进分诊**（过安全层、有界） | `server/src/kb_repo.cj`、`server/src/domain_kb.cj` | ✅ |
| 三态来源 `rules` / `model` / `model:invalid`（默认关闭，配置后才有 `model`） | `server/src/triage.cj`、`server/src/ai_call.cj` | ✅ |
| **配置从命令行改成 DB** 的改造点已内化：`aiSettingsFromFlags()` → `ai_setting` 表 | `server/src/ai_settings.cj` | ✅ |

### 3.5 客户端层（鸿蒙患者端）

> ⏳ **留白** —— 客户端代码**不在本仓库**，由客户端同学另行开发。
> 写客户端只需读 **[docs/FRONTEND-INTEGRATION.md](docs/FRONTEND-INTEGRATION.md)**：鉴权、18 个端点逐字段、SSE 原始帧、幂等挂号与退号语义、服务端缺口、前端工程纪律。
>
> ⚠️ **必须对齐的红线**：**挂号与 AI 调用必须在线直连，绝不进离线队列** —— 见 §5.4。

### 3.6 工程化与测试

- **测试脚本**：`server/tests/` **13 个 `.ps1`** + `common.ps1` —— `auth-check` / `base-check` / `create-db-check` / `emr-check` / `kb-check` / `previsit-check` / `rate-limit-check` / `stress-booking` / `tls-check` / `triage-check` / `ai-live-check` / `p1-extra-check` / `doc-counts`；⚠️ **项数以 `doc-counts.ps1` 的实测输出为准**（这个数字漂移过两次，现已机制化对账）
- **构建**：`server/build.ps1` 按版本探测 SDK，并生成源码哈希清单 `SOURCE-MANIFEST.sha256`，框架与业务**同一次调用、同一个包**
- **文档文化**：每个阶段一份 HANDOFF（P0–P5）+ 一份架构 ADR（已到 **rev.7**）+ 一份前端对接说明 + 本启动说明

---

## 4. 逐项复用映射（参考系统能力 → 本仓库落点）

| 参考系统能力 | 本仓库落点 | 状态 |
| --- | --- | --- |
| 智能分诊（多步推理） | `server/src/ai_triage.cj` + `triage.cj` | ✅ **P2**（模型路 P3 接通） |
| 先取证后结论（模型输出不可信） | `server/src/triage.cj` 验证层 | ✅ **P2** |
| 危急征象兜底 | `server/src/triage_redflag.cj` | ✅ **P2** |
| **预问诊 SSE 流式** | `server/src/previsit.cj` + 轻舟 `streamStart` | ✅ **P2**（近乎零成本） |
| 预约挂号 / 原子扣号 | `server/src/domain_booking.cj` + `db.exec` 受影响行数 | ✅ **P0/P1** |
| 挂号幂等 | `client_token` + 唯一索引（退号释放） | ✅ **P0/P1** |
| 抢号/登录限流 | `server/src/http_app.cj` + `http_common.cj` | ✅ **P1** |
| 三端鉴权 | `server/src/auth_crypto.cj` / `auth_repo.cj` | ✅ **P1** |
| 统一响应 + 全局异常 | `server/src/http_common.cj` | ✅ **P1** |
| 顺延不串号（`visit_date` 快照） | `server/src/domain_booking.cj`、`schema.cj` | ✅ **P0** |
| 电子病历七段式 + 草稿锁定 | `server/src/domain_emr.cj` | ✅ **P4** |
| 运营看板（**只出聚合，绝不出明细**） | `server/src/dashboard.cj` | ✅ **P4** |
| **AI 能力中心（DB 驱动配置）** | `server/src/ai_settings.cj` | ✅ **P3**（密钥不落库） |
| Prompt 模板管理 | `server/src/ai_prompt.cj` | ✅ **P3** |
| 医学知识库 RAG | `server/src/domain_kb.cj`、`kb_repo.cj`、`http_kb.cj` | ✅ **P5**（零向量库；向量路未端到端验证） |
| 全链路可观测时间线 | `dashboard.cj`（聚合）+ 各阶段 HANDOFF | 🟡 **部分** |
| CRUD 路由工厂 | 手写链式路由 | ❌ 见 §6 劣势 |
| 动态 Schema | 手写校验（`server/src/http_common.cj`） | ❌ **仓颉做不到同等**（§6） |

---

## 5. 五个启动时识别的硬骨头 ★（含落地结论）

### 5.1 号源并发必须脱离内存 Store —— **唯一的架构级决策**（✅ P0 落地；旧范式 P4 整体拆除）

**问题**：搬迁前的持久化范式是「全量载入内存 + 全局锁 + 每次提交整体替换各表」。若把排班表塞进那套内存 Store，会同时继承三个代价：

1. **整表替换写放大** —— 每次挂号重写整个排班/订单表
2. **全局锁跨一次网络事务持有**（原文：「这把锁是**跨一次网络事务**持有的」）
3. 并发扣减被完全串行化

而且内存 Store 是**每进程一份、没有失效通知** ⇒ 「跨实例共享同一份数据」不成立。

**做法（已落地）**：号源 / 挂号**单独成域、不进内存 Store**，由 MySQL 权威：

```cangjie
// 复刻参考系统的 version 乐观锁 + remain_num > 0 条件，并利用 exec() 的受影响行数
let n = db.exec(
  "UPDATE schedule SET remain_num = remain_num - 1, version = version + 1 " +
  "WHERE id = ? AND version = ? AND remain_num > 0",
  [DbInt(sid), DbInt(ver)])
if (n == 1) { /* 抢到 → 写挂号单 */ } else { /* 号源已变 → 重试或明确失败 */ }
```

整段包在 `withTransaction` 里，与挂号单 INSERT 同事务。

**结果（比启动时的预期更彻底）**：P4 收尾核对「配套域生产不刷盘」时实测发现，那套内存 Store **在生产路径上从未接线**（零实例化 / 零 `loadAll` / 零 `flushToMysql` / 无写入口）⇒ 已**整体拆除**（`mem_store.cj` + `sql_recorder.cj` 删除）。因此启动时担心的「两种数据访问范式」这笔架构债**已经还清**，全库只剩直接 SQL 一种范式（[ADR-0001](docs/adr/ADR-0001-号源与挂号独立MySQL路径.md) rev.6 / rev.7）。

### 5.2 出站流式是一个隐蔽缺口，且不能无脑全流式（✅ P2 落地）

轻舟能**对外**流式，但对**模型侧**是「整体收完 JSON → 校验 → 才返回」。参考系统用 DashScope SSE 做打字机。

**必须分开处理**（这是本节最容易做错的地方）：

| 场景 | 是否流式 | 理由 |
| --- | --- | --- |
| 预问诊**对话文本** | ✅ 可以流式 | 它就是自然语言，不是业务值 |
| 分诊**结论**（科室/医生/号源） | ❌ **必须非流式 + 校验后返回** | 无脑流式 = 拆掉参考系统创新点② |

落地口径：`previsit.cj` 逐句下推 `delta` 帧（`data: {...}\n\n`），分诊 `POST /triage` 一次性返回**校验过的**结论；**绝不把没校验过的内容当业务值返回**。

### 5.3 AI 配置要从「命令行参数」改成「数据库驱动」（✅ P3 落地）

启动时的现状是配置全部来自命令行（`--ai-endpoint` / `--ai-model` / `--ai-key-file` / `--ai-timeout` / `--ai-max-concurrent` / `--ai-max-tokens`）。

**已落地**：配置落到 `ai_setting` KV 表（写库 → 失效缓存 ⇒ **改配置零重启**）。

⚠️ **一处安全红线（已机制化）**：改成 DB 驱动时**把密钥写进库是倒退** ⇒ 库里**只存引用**（`env:` 名或 `file:` 路径），裸密钥会被**机制性拒绝**，回显一律脱敏。详见 [docs/P3-HANDOFF.md](docs/P3-HANDOFF.md)。

### 5.4 挂号绝不能进离线队列

「先入队、回前台重试」的语义用在挂号上 = **用户以为挂上了，其实没有**。

**挂号与 AI 调用同理**：必须**在线直连** + 强一致确认页；「取消并归还号源」也必须走在线路径，
且**退号是否成功要看返回体 `status == 'cancelled'`，不能只看 HTTP 码**。

> 客户端由客户端同学实现时请照此口径，细节见 [docs/FRONTEND-INTEGRATION.md](docs/FRONTEND-INTEGRATION.md)。

### 5.5 RAG 是全新模块，但没有现成库（✅ P5 落地）

启动时仓库**无 embedding、无向量、无余弦相似度**（全仓 grep 0 匹配）。仓颉侧自己写：

1. 出站调 embedding 模型（复用 `ai_call.cj` 的出站与降级口径）
2. 向量存 MySQL JSON（复刻参考系统的做法）
3. **纯仓颉算余弦相似度** —— 编译型语言，比参考系统的纯 Python 快

**规模判断**：单院区知识库几千 chunk 完全够用；上万 chunk 才需要降维/分片。
**降级**：向量模型不可用时回落**关键词检索**（与参考系统一致，也是本仓库的默认路）。

⚠️ 已核实 **DeepSeek 无 embeddings 端点** ⇒ 向量路**未做端到端验证**（切块与余弦、仓储层有测试覆盖）。见 [docs/P5-HANDOFF.md](docs/P5-HANDOFF.md)。

---

## 6. 技术路线决策

### 6.1 已定：路线 A —— 全仓颉 + 轻舟

理由：在「难的地方」（AI 编排、取证校验、降级、审计）有**存量优势**；
只在「烦的地方」（ORM、元编程）需要还债，而那部分可以靠人力补。

### 6.2 三路线对比（保留备查）

| 维度 | **A. 仓颉+轻舟（选定）** | B. 混合 | C. 全 Python |
| --- | --- | --- | --- |
| AI 编排（校验/降级/兜底/审计） | ✅ **已有生产级 + 测试** | 同 A | 要从零试错 |
| SSE 流式 | ✅ 框架原生 | 同 A | ✅ |
| ORM / 表建模 | ❌ 手写 SQL 映射（参照 `server/src/schema.cj` 的量级） | 同 A | ✅ SQLAlchemy 碾压 |
| 动态 Schema / CRUD 工厂 | ❌ **仓颉静态类型做不到动态 Pydantic**；闭包**不能捕获外部可变 `var`** | 同 A | ✅ |
| RAG / 科学计算 | 🟡 手写，够用 | ✅ | ✅ numpy |
| 部署 | ✅ 单 exe + 4 DLL | ❌ 双栈 | 🟡 依赖地狱 |
| 招人 / 长期维护 | ❌ 仓颉开发者稀缺 | ❌ | ✅ |
| 上手成本 | ✅ 存量肌肉记忆 | 🟡 | ❌ |

> ⚠️ **B 路线要警惕**：双栈 = 双份部署、双份鉴权、双份可观测 ——
> **正好会打掉参考系统创新点④（全链路可观测）**。不推荐。

### 6.3 仓颉侧的真实劣势（必须承认，别回避）

1. **无 ORM / 无动态 Schema**：8 张表要手写映射。**这是最实在的成本**。
2. **CRUD 工厂受限**：仓颉闭包**不能捕获外部可变 `var`**（需用 class 持 `var` 字段 + 捕获 `let` 引用）；且仓库铁律是「权限判定收敛到统一守卫，禁止 handler 手写 if」，工厂必须能内置权限钩子。
3. **LangChain 缺失**：**这条不算真劣势** —— 参考系统自己就写了「LangChain 不可用时自动降级 httpx 直连」，说明它只是薄封装；本仓库的出站调用是自建的。

---

## 7. 目标架构

```
┌─────────────────────────────────────────────┐
│  鸿蒙患者端（ArkTS，由客户端同学另行开发）      │
│  患者：分诊 / 预问诊(SSE) / 挂号 / 我的预约    │
└──────────────────┬──────────────────────────┘
                   │ HTTPS（在线直连，不进离线队列）
┌──────────────────▼──────────────────────────┐
│  仓颉 + 轻舟 单进程（单院区单实例）            │
│                                             │
│  ┌───────────────┐   ┌────────────────────┐ │
│  │ 业务域         │   │ AI 编排             │ │
│  │ 科室/医生/排班 │   │ ai_triage 分诊      │ │
│  │ 挂号/病历/看板 │   │ triage 验证层+兜底   │ │
│  │ 知识库/RAG     │   │ ai_call 出站+降级   │ │
│  └───────┬───────┘   │ ai_settings 配置    │ │
│          │           └─────────┬──────────┘ │
│  ┌───────▼───────────────────┐ │            │
│  │ 统一数据访问：参数化 SQL    │◄┘            │
│  │ 原子 UPDATE + 事务         │              │
│  │ （内存 Store 已整体拆除）   │              │
│  └───────────┬───────────────┘              │
└──────────────┼──────────────────────────────┘
               │
        ┌──────▼──────┐        ┌────────────────┐
        │  MySQL 8    │        │ 管理端前端       │
        │  业务+AI配置 │        │ （另立一期；     │
        │  +向量(JSON) │        │  接口已就绪）    │
        └─────────────┘        └────────────────┘
```

**关键点**：全库只有**一种**数据访问范式（直接 SQL + 事务）；号源/挂号是最早走这条路的域，其余业务域在 P1–P5 陆续并入同一范式。

---

## 8. 里程碑与现状

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| **P0** | 建 科室/医生/排班/挂号单/病历 等表；**号源域独立路径 + 写 ADR** | ✅ **完成**（rev.2–rev.4 三轮复查修订） |
| **P1** | **挂号闭环**：排班 → 号源 → 原子扣号 → 幂等 → 退号归还；+ 令牌鉴权 + HTTPS + 限流 | ✅ **完成**（剩 2 项运维，见 [docs/P1-OPS-HANDOFF.md](docs/P1-OPS-HANDOFF.md)） |
| **P2** | AI 分诊（纪律层）+ 预问诊 SSE 多轮采集 | ✅ **完成** |
| **P3** | AI 能力中心：配置/Prompt/开关落库 + 密钥不落库 | ✅ **完成** |
| **P4** | 电子病历 + 接诊队列 + 运营看板 + **内存 Store 整体拆除** | ✅ **完成** |
| **P5** | RAG 知识库（零向量库） | ✅ **完成**（向量路未端到端验证） |
| **客户端** | 鸿蒙患者端（ArkTS） | ⏳ **待实现** —— 见 [docs/FRONTEND-INTEGRATION.md](docs/FRONTEND-INTEGRATION.md) |

> ⚠️ 启动时给各阶段的**工期粗估**（1–3 周/阶段）是**推断，未实测**，仅供排序参考，不要当承诺。
> **实际进度**以根 [README.md](README.md) 的进度表为准。

---

## 9. 风险登记

| # | 风险 | 级别 | 说明 / 缓解 |
| --- | --- | --- | --- |
| **R-2** | ~~架构债：双数据访问范式~~ | 🟢 **已消除** | 内存 Store 已于 P4 收尾整体拆除（[ADR-0001](docs/adr/ADR-0001-号源与挂号独立MySQL路径.md) rev.7），全库只剩直接 SQL 一种范式 |
| **R-3** | 手写 SQL 映射的人力成本 | 🟡 中 | §6.3。缓解：只建必要表（8 张），不做 21 张 |
| **R-4** | **医疗合规**（病历/预问诊 = 敏感个人信息） | 🟠 中高 | 参考系统**通篇未提合规**（它是演示项目）。真实落地需个保法合规、等保、实名、留存。**暂无合作方 → 当前不阻塞**，但**一旦有真实医院合作方，合规会变成第一优先级且工期不可压缩**。出站口径见 [docs/Q6-合规决策记录.md](docs/Q6-合规决策记录.md) |
| **R-5** | 无真实 HIS/医保/支付对接 | 🟡 中 | 参考系统也没有。原型阶段用模拟数据即可，但**要留接口位** |
| **R-6** | 仓颉生态迭代速度（新模型/新框架适配慢） | 🟢 低 | 统一走 OpenAI 兼容协议可缓解（仓库已有此设计） |
| **R-7** | 密钥落库倒退 | 🟢 低 | §5.3 已机制化（只存 `env:`/`file:` 引用） |

---

## 10. 待决问题（进新工作区先回答）

| # | 问题 | 状态 / 为什么重要 |
| --- | --- | --- |
| **Q1** | **新建空仓再选择性搬运，还是 fork 既有仓库？** | ✅ **已决**：新建工作区 + 选择性搬运，不带 `.git` 历史；本仓只放自己的代码 |
| **Q2** | **数据模型范围**：先建哪几张表？ | ✅ **已决（P0）**：最小 **8 张** = 业务 6（`department` `doctor` `schedule`★ `appointment`★ `patient` `medical_record`）+ 鉴权 2（`auth_user` `auth_token`）。★ = 走直接 SQL |
| **Q3** | **患者端页面范围**？ | ✅ **已决**：**主闭环 6 页**（登录 / 分诊 / 预问诊 / 约号 / 我的预约 / 我的）；就诊记录、设备管理、自助注册不在本期（服务端暂无注册/改密端点）。**客户端由客户端同学另行开发**，口径见 [docs/FRONTEND-INTEGRATION.md](docs/FRONTEND-INTEGRATION.md) |
| **Q4** | **管理端（运营看板）前端**是否复用既有 Vue 3 工程？ | ⏳ **未决** —— 服务端已提供看板聚合接口（`server/src/dashboard.cj`），前端技术栈留给写前端的一方决定 |
| **Q5** | **单院区的具体量级**：日门诊量？号源放出峰值并发？ | ⏳ **未决** —— 决定扣号路径是否需要加重试/排队，以及是否真的永远不需要 Redis |
| **Q6** | **AI 模型选型与合规**：用哪家？患者主诉属敏感信息，**出境/第三方处理需评估** | ⏳ **选型未决；出站合规口径已落档**（发什么出站 / 默认关闭 / 六道闸门）见 [docs/Q6-合规决策记录.md](docs/Q6-合规决策记录.md) |

---

## 附录 A · 关键代码落点索引

**轻舟框架**（`server/third_party/qingzhou/src/`）
- `context.cj:301` `streamStart(contentType)` — 进入 SSE/chunked 模式 ｜ `:314` / `:325` 两个 `writeChunk()` 重载
- `httpclient.cj` — 出站 SSE/chunked 透传
- `db.cj:105` `exec(sql)` 接口 ｜ `:129` `exec(sql, params)`（**返回受影响行数**）｜ `:152` `withTransaction(body)`
- `dbquery.cj:89` `dbRaw(sql, ps)` ｜ `:484-606` 各查询构建器的 `exec(be)`

**本仓库服务端**（`server/src/`）
- `main.cj` 命令行与自检 ｜ `schema.cj` 表与迁移 ｜ `db_bootstrap.cj` 连接与启动
- `http_app.cj` 全部路由与守卫 ｜ `http_common.cj` 信封/错误码/统一响应（`apiErrorSpec:55`、`sendOk:225`、`sendError:241`）
- `auth_crypto.cj` / `auth_repo.cj` 账号与令牌 ｜ `domain_booking.cj` 挂号/退号/幂等 ｜ `domain_base.cj` + `http_base.cj` 基础数据
- `triage.cj` / `triage_redflag.cj` / `ai_triage.cj` 分诊、兜底与校验层 ｜ `previsit.cj` 预问诊 SSE
- `ai_call.cj` 模型出站 ｜ `ai_settings.cj` 配置 ｜ `ai_prompt.cj` Prompt ｜ `dashboard.cj` 看板
- `domain_emr.cj` 病历与接诊队列 ｜ `domain_kb.cj` + `kb_repo.cj` + `http_kb.cj` 知识库
- `acceptance*.cj` 仓颉侧验收自检

**客户端**（`entry/`）：⏳ **留白** —— 由客户端同学另行开发，先读 [docs/FRONTEND-INTEGRATION.md](docs/FRONTEND-INTEGRATION.md)

**管理端前端**：⏳ 另立一期（服务端已有运营看板聚合接口）

**测试**：`server/tests/`（13 个 `.ps1` + `common.ps1`；项数以 `doc-counts.ps1` 为准）

**关键文档**：[README.md](README.md)（进度与目录）｜ [docs/FRONTEND-INTEGRATION.md](docs/FRONTEND-INTEGRATION.md)（前端唯一口径）｜ [docs/adr/ADR-0001](docs/adr/ADR-0001-号源与挂号独立MySQL路径.md)（架构决策 rev.7）｜ `docs/P0-HANDOFF.md` … `docs/P5-HANDOFF.md` ｜ [docs/DEV-DB.md](docs/DEV-DB.md)（本机数据库）｜ [docs/Q6-合规决策记录.md](docs/Q6-合规决策记录.md)（出站合规）｜ [docs/PUSH-NOTES.md](docs/PUSH-NOTES.md)（推送备忘）

---

## 附录 B · 参考系统技术栈（原文口径，备查）

- **后端**：FastAPI（19 个路由模块）、SQLAlchemy 2.0 + PyMySQL（21 张表）、Pydantic v2 + pydantic-settings、JWT + passlib(pbkdf2_sha256)
- **AI 层**：LangChain `langchain_openai.ChatOpenAI`、**手写 ReAct Agent 状态机（最多 6 轮）**、阿里云百炼 DashScope（OpenAI 兼容，`qwen-plus` + `text-embedding-v3` 1024 维）、SSE
- **数据**：MySQL 8（业务 + AI 配置 + Prompt + 知识库 + 向量 JSON + 全链路调用日志）
- **前端**：Vue 3 + Vue Router + Vite + Element Plus（主题色 `#00a9a7`）+ Axios 拦截器 + 自研 SSE 解析器
- **工程化**：通用 CRUD 路由工厂、动态 Pydantic Schema、统一响应 `{code,msg,data}`、全局异常、loguru、代码脚手架生成器

---

## 附录 C · 证据等级与未验证项

**✅ 本次实测核验**（直接读代码得到）：轻舟 SSE（`context.cj:301/314/325`）、`exec()` 返回受影响行数（`db.cj:129`）、`withTransaction`（`db.cj:152`）、`dbRaw`（`dbquery.cj:89`）、`client_token` 幂等唯一索引（`schema.cj:328`）、错误码表与统一响应（`http_common.cj:55/225/241`）、登录限流（`http_app.cj:790`）、RAG 实现（`kb_repo.cj` / `domain_kb.cj`）、**DeepSeek 无 embeddings 端点**。

**📄 文档记载未逐行复核**：轻舟快照版本与 `MANIFEST.sha256`、各阶段 HANDOFF 里的历史细节与测试项数（一律以 `server/tests/doc-counts.ps1` 的实测输出为准）。

**🧮 推断（未实测，落地前必须验证）**：
1. §8 各阶段工期（启动时的粗估）
2. 「单院区单实例下 MySQL 原子 UPDATE 吞吐绰绰有余」—— 需按 Q5 的真实量级压测
3. §7 架构图与阶段划分

---

> **一句话总结**：参考系统最值钱的不是「接了 LangChain」，而是把大模型关进了业务约束的笼子；
> **这套笼子本仓库已经造好了**，而且是带测试的。项目要做的不是重新发明笼子，而是**把笼子里的动物换成医疗业务**——
> 科室/号源/病历/知识库都已就位，剩下的一块是**客户端**（口径见 [docs/FRONTEND-INTEGRATION.md](docs/FRONTEND-INTEGRATION.md)）。
