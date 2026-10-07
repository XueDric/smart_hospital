# 智慧医院智能导诊就诊系统 · 项目启动说明

> 📁 **新项目交接** ｜ 本文件：`smart-hospital-project-brief.md` ｜ [全部文档目录](baseline/docs/README.md)
>
> **生成时间**：2026-10-07 ｜ **生成位置**：`cangjie_web` 工作区 ｜ **基线提交**：`07a0922`
>
> **用途**：在新工作区启动「智慧医院智能导诊就诊系统」时，作为**唯一上下文入口**。
> 新会话把本文件整份读完即可接续，不需要回读原对话。

---

## 0. 这份文档怎么用

| 你在做什么 | 读哪一节 |
| --- | --- |
| 刚进新工作区，想知道项目是什么 | §1、§2 |
| 想知道**能复用哪些现成东西** | §3、§4 |
| 想知道**难点在哪、别踩什么坑** | §5 ★ 最重要 |
| 想知道技术选型为什么这么定 | §6、§7 |
| 想知道先做什么、做多久 | §8 |
| 开工前要先拍板什么 | §10 |
| 找代码落点 | 附录 A |

> ⚠️ **第 1 节是已决事项**，除非有新的外部约束，**不要在新工作区重新讨论**。
> ⚠️ 凡标注「**推断**」的数字（尤其工期）都是**未实测的粗估**，落地前请自行验证。

---

## 1. 项目定位与已确认决策

**项目名**：智慧医院智能导诊就诊系统
**一句话**：患者输入一句主诉 → AI 多步推理取证 → 推荐科室与医生 → 校验真实有号 → 一键挂号 → 医生接诊 → 生成电子病历，全程落库、可追溯、可观测。

| # | 决策项 | 结论 | 影响 |
| --- | --- | --- | --- |
| 1 | **团队** | **原班人马**（已有仓颉 / 轻舟 / ArkTS 存量能力：10 位贡献者、218 次提交、六轮代码评审） | ✅ 走**路线 A：全仓颉**，最大化复用（§6） |
| 2 | **患者端形态** | **鸿蒙 App（ArkTS）** | ✅ 复用 `entry/src` 的 21 个页面、Theme tokens、Outbox、TokenStore |
| 3 | **规模预期** | **单院区**（暂定） | ✅ 单实例部署即可 → 仓库「不能水平扩展」的缺陷**不咬人**，且**不需要 Redis** |
| 4 | **合作方** | **暂无** | ✅ 合规不阻塞，可按产品原型节奏推进；但见 §9 风险 R-4 |
| 5 | **技术路线** | 路线 A：仓颉 + 轻舟承载后端与 AI 编排；管理端沿用 Vue3 | 详见 §6、§7 |

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

| # | 原文创新点 | **本质** | 本仓库是否已有等价物 |
| --- | --- | --- | --- |
| ① | 数据库驱动的 AI 能力中心（改配置零重启） | 配置外置 + 缓存失效 | ❌ **没有** |
| ② | 先取证后结论，把幻觉关进笼子 | **模型输出视为不可信输入** | ✅ **已有且更严** |
| ③ | 医疗级安全兜底（24 危急关键词 + `is_red_flag`） | 纯规则保险丝 | 🟡 形状有（`ai_risk.cj`），规则要新写 |
| ④ | 全链路可观测（Agent 时间线/工具日志/模型日志） | 审计 + 可视化 | 🟡 审计有，时间线无 |
| ⑤ | 业务闭环 + 数据闭环（`converted=1`、分诊命中率） | 转化回写 | 🟡 幂等有，回写要新写 |
| ⑥ | 零向量库轻量 RAG（MySQL JSON 存向量 + 纯 Python 余弦） | 自建检索 | ❌ **完全没有** |
| ⑦ | 模型无关 + 优雅降级 | 统一协议 + 降级不中断业务 | ✅ **已有** |
| ⑧ | 工程化提效（CRUD 工厂/动态 Schema/脚手架） | 元编程生产力 | ❌ 仓颉侧做不到同等（§6） |

> **本分析的核心洞察**：8 个创新点里，**②④⑦ 三条是「工程纪律」而非「接大模型」**，
> 恰恰也是这个系统**最难写、最容易出安全事故**的部分 —— 而本仓库**已经是有测试保护的生产级状态**。
> 反过来，⑧ 那类「省事」的部分，是仓颉侧最弱的地方。

### 2.3 参考系统的两个关键技术方案（值得照搬）

- **防超卖**：排班表 `version` 乐观锁 + 扣减带 `remain_num > 0` 条件
- **顺延不串号**：挂号单保存 `visit_date` **就诊日快照**，管理员一键顺延排班不影响已挂患者

---

## 3. 可复用资产盘点（本仓库）

> 证据等级标注：**✅实测** = 本次在代码/文档中直接核验到；**📄文档** = 仓库文档记载，未逐行复核。

### 3.1 框架层 —— 轻舟（QingZhou）已内置

| 资产 | 落点 | 等级 |
| --- | --- | --- |
| 轻舟 v0.12+ 快照，`MANIFEST.sha256` 逐字节校验、连接池、健康检查、生命周期钩子、优雅关闭 | `server/third_party/qingzhou` | 📄 |
| **SSE / chunked 流式响应原生支持**：`streamStart(contentType)` + `writeChunk()`，handler 返回后自动写 last-chunk | [context.cj:301](baseline/server/third_party/qingzhou/src/context.cj#L301)、[context.cj:314](baseline/server/third_party/qingzhou/src/context.cj#L314) | ✅ |
| **出站 SSE / chunked 透传**（边读边转发，用完 `close()` 释放连接） | [httpclient.cj:124](baseline/server/third_party/qingzhou/src/httpclient.cj#L124) | ✅ |
| 洋葱中间件、Trie 路由、静态/gzip/Range/ETag/multipart/签名 cookie | `server/third_party/qingzhou/src` | 📄 |

> 🔥 **这是本轮最大的好消息**：文章的「预问诊流式打字机」在轻舟上**近乎零成本**。

### 3.2 数据访问层 —— 防超卖的**技术前提已具备**

| 能力 | 落点 | 等级 |
| --- | --- | --- |
| `DbBackend.exec(sql, params): Int64` —— **返回受影响行数** | [db.cj:100-105](baseline/server/third_party/qingzhou/src/db.cj#L100-L105) | ✅ |
| `withTransaction(body)` —— 自动 begin/commit/rollback | [db.cj:152](baseline/server/third_party/qingzhou/src/db.cj#L152) | ✅ |
| 参数化查询 `query/exec(sql, Array<DbValue>)`，`?` 占位符 | [db.cj:124-131](baseline/server/third_party/qingzhou/src/db.cj#L124-L131) | ✅ |
| `dbRaw(sql, ps)` —— 需要「列表达式」时用（如 `col = col - 1`） | [dbquery.cj:89](baseline/server/third_party/qingzhou/src/dbquery.cj#L89) | ✅ |
| `UpdateQuery.set/filter/exec` 构建器（注意 `set` 只接受**值**，不接受表达式） | [dbquery.cj:492-556](baseline/server/third_party/qingzhou/src/dbquery.cj#L492-L556) | ✅ |
| MySQL 持久化层：`SCHEMA_DDL`、schema 版本/迁移、`SET NAMES utf8mb4`、`MysqlStore` 薄封装 | [mysql_store.cj:313](baseline/server/src/mysql_store.cj#L313)、[mysql_store.cj:218](baseline/server/src/mysql_store.cj#L218) | ✅ |
| ⚠️ **但持久化范式是「全量载入内存 + 全局锁 + 每次提交整体替换各表」** | [mysql_store.cj:30-37](baseline/server/src/mysql_store.cj#L30-L37) | ✅ |

### 3.3 业务机制层 —— 可直接复用

| 机制 | 落点 | 等级 | 挂号场景用法 |
| --- | --- | --- | --- |
| **幂等**：`IdemRecord` + `idemKey(kind, actorId, token)` 24h 去重 | [store.cj:136](baseline/server/src/store.cj#L136)、[store_queries.cj:373](baseline/server/src/store_queries.cj#L373) | ✅ | `idemKey("booking", …)` 防重复挂号 |
| **限流**：成员级节流 → 429 | `h_ai.cj` | ✅ | 抢号限流 |
| 框架全局限流 `rateLimit(600, 60)` | `ops/admin_main.cj` | ✅ | 兜底 |
| **鉴权**：不透明令牌 + PBKDF2 **三阶段加锁**（PBKDF2 移出全局锁） | `auth.cj`、[capacity-baseline.md:115-134](baseline/docs/capacity-baseline.md#L115-L134) | ✅ | 直接用；4 并发登录 1574→867 ms |
| **权限收敛**：`can(member, action, target)` 单一判定函数 | `perms.cj` | 📄 | 改成三端角色，**机制保留** |
| **审计** | `audit.cj` | 📄 | 病历/挂号操作留痕 |
| 请求体闸门（413/415/411/非 UTF-8→400） | [limits.cj:47](baseline/server/src/limits.cj#L47)、[limits.cj:83](baseline/server/src/limits.cj#L83) | ✅ | 直接复用 |
| 统一响应 `{ok,data}` / `{ok:false,error:{code}}` + `onError` | `errors.cj`、`jsonw.cj` | 📄 | 直接复用 |

### 3.4 AI 编排层 —— **本仓库最值钱的资产**

| 能力 | 落点 | 等级 |
| --- | --- | --- |
| **工具白名单静态表** `aiToolSpecs()`（模型不能新增工具）；只读工具 + `write:Bool` 标记 | [ai_tools.cj:54](baseline/server/src/ai_tools.cj#L54)、[ai_tools.cj:34](baseline/server/src/ai_tools.cj#L34) | ✅ |
| 该文件**自己写明**：从只读升级为读写「只需加条目 + 加分支，**结构不用改**」 | [ai_tools.cj:17-18](baseline/server/src/ai_tools.cj#L17-L18) | ✅ |
| **Agent 多轮循环**（思考 → 调工具 → 观察 → 再思考），锁纪律：锁外调模型 → 锁内跑 1 个工具 → 锁外回灌 | `h_ai.cj` 的 `aiAgentLoop` | 📄 |
| **模型输出不可信**三口径：①失败一律降级不抛异常 ②`extractJson` 剥围栏 → 严格解析 → 归一化 → `JsonSchema` 校验 → 重试一次 → 降级 ③限流用 `tryAcquire` 不排队 | [ai_client.cj:15-20](baseline/server/src/ai_client.cj#L15-L20) | ✅ |
| **写操作两段式**：提议 → 用户确认 → 执行（`ai_proposal.cj`） | `ai_proposal.cj`、`/ai/agent/confirm` | ✅ |
| 风控打分（低/中/高 + 理由） | `ai_risk.cj` | ✅ |
| 出站 HTTPS/TLS + 重试退避 + 并发闸门 | `ai_transport.cj` | 📄 |
| 三态输出 `model` / `fallback` / `none`，**兜底不得为空** | [ai_client.cj:33-46](baseline/server/src/ai_client.cj#L33-L46) | ✅ |

### 3.5 客户端层（ArkTS）

`entry/src/main/ets/`：21 个页面、`HttpClient`（401/403 统一处理 + GET 并发去重）、`TokenStore`（**Asset Store 安全存储**）、`OutboxStore`/`OutboxSync`（离线队列 + 幂等 `client_token`）、`CalendarSync`、`PermissionStore`（`can()`）、`Theme.ets`（设计 token 唯一同源）、`RouterUtils`、`InviteDeepLink`。

> ⚠️ **红线**：`AiApi.ets` 明确写着「智能调用**不传** outbox，**绝不进离线队列**」——
> 挂号同理**必须走在线直连**，见 §5 第 4 条。

### 3.6 工程化与文档

- **7 套测试脚本**：`server/tests/` 下 `smoke.ps1`(440 项)、`bench.ps1`、`tls-check.ps1`、`client-contract-check.ps1`(37)、`admin-check.ps1`(38)、`ops-check.ps1`(82)、AI 三件套（`ai-check` / `ai-e2e` / `ai-real` + `ai-stub.mjs`）；单测 595（不给 DSN）/ 648（给 DSN）
- **构建**：`server/build.ps1` 按版本探测 SDK（基线 cjc **1.2.0** + stdx **1.1.3.1**）、校验 `MANIFEST.sha256`
- **管理端已是 Vue 3**：`server/admin-web/src` + 随仓库提交的 `dist` —— **运营看板可直接沿用这套**
- **文档文化**：`docs/code-review.md`（六轮评审逐条闭环）、[capacity-baseline.md](baseline/docs/capacity-baseline.md)、[API-NOTES.md](baseline/docs/API-NOTES.md)（40+ 条踩坑）

---

## 4. 逐项复用映射

| 参考系统能力 | 本仓库落点 | 复用度 | 要做什么 |
| --- | --- | --- | --- |
| 智能分诊（ReAct 多步推理） | `ai_tools.cj` + `aiAgentLoop` | ⭐⭐⭐⭐⭐ | **只加工具条目** |
| 先取证后结论 | [ai_client.cj:15-20](baseline/server/src/ai_client.cj#L15-L20) | ⭐⭐⭐⭐⭐ | 补 `verify_recommendation()` |
| 危急征象兜底 | `ai_risk.cj` 同形状 | ⭐⭐⭐⭐ | 新写规则，简单 |
| **预问诊 SSE 流式** | [context.cj:301](baseline/server/third_party/qingzhou/src/context.cj#L301) | ⭐⭐⭐⭐⭐ | **近乎零成本**（但见 §5 第 2 条） |
| 预约挂号 / 乐观锁扣号 | [db.cj:104](baseline/server/third_party/qingzhou/src/db.cj#L104) + [db.cj:152](baseline/server/third_party/qingzhou/src/db.cj#L152) | ⭐⭐⭐ | **必须新开脱离内存 Store 的路径**（§5 第 1 条） |
| 挂号幂等 | [store.cj:136](baseline/server/src/store.cj#L136) | ⭐⭐⭐⭐⭐ | 直接用 |
| 抢号限流 | `h_ai.cj` 节流 + `rateLimit` | ⭐⭐⭐⭐ | 直接用 |
| 三端鉴权 | 令牌 + PBKDF2 + `can()` | ⭐⭐⭐⭐ | 机制搬，**角色枚举重做** |
| 统一响应 + 全局异常 | `errors.cj` / `jsonw.cj` | ⭐⭐⭐⭐⭐ | 已有 |
| 顺延不串号（`visit_date` 快照） | 无 | ⭐⭐ | 新写，简单 |
| 电子病历七段式 + 草稿锁定 | 无直接对应 | ⭐⭐ | 新域 |
| 运营看板 | `server/admin-web`（Vue 3） | ⭐⭐⭐ | 补指标 |
| **AI 能力中心（DB 驱动配置）** | [ai_config.cj:75](baseline/server/src/ai_config.cj#L75) 全部来自**命令行参数** | ⭐ | **最大改造项**（§5 第 3 条） |
| Prompt 模板管理 | 无（硬编码在 `h_ai.cj`） | ⭐ | 建表 + 缓存 + 保存失效 |
| **医学知识库 RAG** | **全仓 0 匹配** | ⭐ | **全新模块**（§5 第 5 条） |
| 工具中心（注册/启停） | 静态白名单 + AI 审计 | ⭐⭐⭐ | 静态表 → DB 表 |
| 全链路可观测时间线 | `audit.cj` + AI 审计 | ⭐⭐⭐ | 补时间线落库与可视化 |
| CRUD 路由工厂 | 手写链式路由 | ⭐ | 见 §6 劣势 |
| 动态 Pydantic Schema | `jsonw.cj` 手写校验 | ⭐ | **仓颉做不到同等**（§6） |

---

## 5. 五个必须新建的硬骨头 ★

### 5.1 号源并发必须脱离内存 Store —— **唯一的架构级决策**

**问题**：仓库持久化范式是「全量载入内存 + 全局锁 + 每次提交整体替换各表」（[mysql_store.cj:30-37](baseline/server/src/mysql_store.cj#L30-L37)）。若把排班表塞进 `PersistedState`，会同时继承三个代价：

1. **整表替换写放大** —— 每次挂号重写整个排班/订单表
2. **`s.lock` 跨一次网络事务持有** —— [README.md:362](baseline/README.md#L362) 的 **S-14**（原文：「这把锁是**跨一次网络事务**持有的」）
3. 并发扣减被完全串行化

而且 [README.md:334](baseline/README.md#L334) 未决 #12 明确记载：

> **「跨实例共享同一份数据仍然不成立：内存 Store 是每进程一份、没有失效通知」**

**做法**：号源 / 挂号**单独成域、不进内存 Store**，由 MySQL 权威：

```cangjie
// 复刻参考系统的 version 乐观锁 + remain_num > 0 条件，并利用 exec() 的受影响行数
let n = db.exec(
  "UPDATE schedule SET remain_num = remain_num - 1, version = version + 1 " +
  "WHERE id = ? AND version = ? AND remain_num > 0",
  [DbInt(sid), DbInt(ver)])
if (n == 1) { /* 抢到 → 写挂号单 */ } else { /* 号源已变 → 重试或明确失败 */ }
```

整段包在 `withTransaction` 里，与挂号单 INSERT 同事务。**因为新表不进 `PersistedState`，`writeDbToMysql` 的整体替换不会碰它** —— 无双写冲突（此推论基于 `mysql_store.cj` 的替换语义，**建议落地时写测试钉住**）。

**代价（必须写进 ADR）**：服务端从此有**两种数据访问范式**。对「真项目」这是明确的架构债。

### 5.2 出站流式是一个隐蔽缺口，且不能无脑全流式

轻舟能**对外**流式，但 `ai_client.cj` 对**模型侧**是「整体收完 JSON → 校验 → 才返回」。参考系统用 DashScope SSE 做打字机。

**必须分开处理**（这是本节最容易做错的地方）：

| 场景 | 是否流式 | 理由 |
| --- | --- | --- |
| 预问诊**对话文本** | ✅ 可以流式 | 它就是自然语言，不是业务值 |
| 分诊**结论**（科室/医生/置信度） | ❌ **必须非流式 + 校验后返回** | 无脑流式 = 拆掉参考系统创新点② |

`ai_client.cj` 设计口径 2 原文：「**绝不把没校验过的内容当业务值返回**」。分诊结论必须走这条。

### 5.3 AI 配置要从「命令行参数」改成「数据库驱动」

现状：`aiOptionsFromFlags()` 从 `--ai-endpoint` / `--ai-model` / `--ai-key-file` / `--ai-ca` / `--ai-timeout` / `--ai-max-concurrent` / `--ai-max-tokens` 读（[ai_config.cj:75](baseline/server/src/ai_config.cj#L75)）。已有 `setAiOptions` / `aiOptionsCurrent` 两个改点（[ai_config.cj:321](baseline/server/src/ai_config.cj#L321)、[ai_config.cj:325](baseline/server/src/ai_config.cj#L325)），说明改造面不大。

⚠️ **一处安全回归风险**：参考系统说「API Key 支持 `env:` 回落、**密钥不落库**」，而本仓库现在是 `--ai-key-file`（文件读取 + `aiValidate` 校验存在）。改成 DB 驱动时，**把密钥写进库是倒退** —— 建议库里只存引用路径 / `env:` 名，密钥本体仍留文件或环境变量。

### 5.4 挂号绝不能进离线队列

`OutboxStore` 是「先入队、回前台重试」的语义。用在挂号上 = **用户以为挂上了，其实没有**。

这个坑仓库自己已经踩过并立了规矩：[AiApi.ets:3](baseline/entry/src/main/ets/api/AiApi.ets#L3) ——
「关键纪律：智能调用**不传** outbox（post 第三参留空），**绝不进离线队列**」。

**挂号同理**：必须在线直连 + 强一致确认页。参考系统的「取消并归还号源」也要走在线路径。

### 5.5 RAG 是全新模块，但没有现成库

仓库**无 embedding、无向量、无余弦相似度**（全仓 grep 0 匹配）。仓颉侧要自己写：

1. 出站调 embedding 模型（`ai_transport.cj` 可扩展）
2. 向量存 MySQL JSON（复刻参考系统 `kb_chunk.embedding` 的做法）
3. **纯仓颉算余弦相似度** —— 编译型语言，比参考系统的纯 Python 快

**规模判断**：单院区知识库几千 chunk 完全够用；上万 chunk 才需要降维/分片。
**降级**：向量模型不可用时回落关键词检索（与参考系统一致）。

---

## 6. 技术路线决策

### 6.1 已定：路线 A —— 全仓颉 + 轻舟

理由：**团队是原班人马**，在「难的地方」（AI 编排、取证校验、降级、审计）有**存量优势**；
只在「烦的地方」（ORM、元编程）需要还债，而那部分可以靠人力补。

### 6.2 三路线对比（保留备查）

| 维度 | **A. 仓颉+轻舟（选定）** | B. 混合 | C. 全 Python |
| --- | --- | --- | --- |
| AI 编排（ReAct/校验/降级/审计） | ✅ **已有生产级 + 测试** | 同 A | 要从零试错 |
| SSE 流式 | ✅ 框架原生 | 同 A | ✅ |
| ORM / 表建模 | ❌ 手写 SQL 映射（参照 `mysql_store.cj` 1362 行的量级） | 同 A | ✅ SQLAlchemy 碾压 |
| 动态 Schema / CRUD 工厂 | ❌ **仓颉静态类型做不到动态 Pydantic**；闭包**不能捕获外部可变 `var`** | 同 A | ✅ |
| RAG / 科学计算 | 🟡 手写，够用 | ✅ | ✅ numpy |
| 部署 | ✅ 单 exe + 4 DLL | ❌ 双栈 | 🟡 依赖地狱 |
| 招人 / 长期维护 | ❌ 仓颉开发者稀缺 | ❌ | ✅ |
| 团队上手成本 | ✅ 存量肌肉记忆 | 🟡 | ❌ |

> ⚠️ **B 路线要警惕**：双栈 = 双份部署、双份鉴权、双份可观测 ——
> **正好会打掉参考系统创新点④（全链路可观测）**。不推荐。

### 6.3 仓颉侧的真实劣势（必须承认，别回避）

1. **无 ORM / 无动态 Schema**：21 张表要手写映射。**这是最实在的成本**。
2. **CRUD 工厂受限**：仓颉闭包**不能捕获外部可变 `var`**（需用 class 持 `var` 字段 + 捕获 `let` 引用）；且仓库铁律是「权限判定收敛到 `can()`，禁止 handler 手写 if」，工厂必须能内置权限钩子。
3. **LangChain 缺失**：**这条不算真劣势** —— 参考系统自己就写了「LangChain 不可用时自动降级 httpx 直连」，说明它只是薄封装；本仓库 `ai_transport.cj` 已自建。

---

## 7. 目标架构

```
┌─────────────────────────────────────────────┐
│  鸿蒙 App（ArkTS）  entry/src 经验复用        │
│  患者：分诊 / 预问诊(SSE) / 挂号 / 档案       │
└──────────────────┬──────────────────────────┘
                   │ HTTPS（在线直连，不进离线队列）
┌──────────────────▼──────────────────────────┐
│  仓颉 + 轻舟 单进程（单院区单实例）            │
│                                             │
│  ┌───────────────┐   ┌────────────────────┐ │
│  │ 业务域         │   │ AI 编排             │ │
│  │ 科室/医生/排班 │   │ aiAgentLoop         │ │
│  │ 挂号/病历/看板 │   │ ai_tools 工具白名单  │ │
│  │ → 内存 Store   │   │ ai_client 校验+降级  │ │
│  └───────┬───────┘   │ ai_proposal 提议确认 │ │
│          │           └─────────┬──────────┘ │
│  ┌───────▼───────────────────┐ │            │
│  │ ★ 号源/挂号：独立路径      │◄┘            │
│  │   参数化原子 UPDATE        │              │
│  │   乐观锁 + remain_num>0    │              │
│  │   withTransaction          │              │
│  │   （不进内存 Store）        │              │
│  └───────────┬───────────────┘              │
└──────────────┼──────────────────────────────┘
               │
        ┌──────▼──────┐        ┌────────────────┐
        │  MySQL 8    │        │ Vue3 管理端     │
        │  业务+AI配置 │        │ server/admin-web│
        │  +向量(JSON) │        │ 基础数据/AI中心 │
        └─────────────┘        │ 运营看板        │
                               └────────────────┘
```

**关键点**：号源/挂号是**唯一**走「直接 SQL」的域，其余业务域沿用内存 Store 范式。

---

## 8. 里程碑与排期建议

> ⚠️ 以下工期均为**推断（粗估，未实测）**，仅供排序参考，**不要当承诺**。

| 阶段 | 内容 | 粗估 | 说明 |
| --- | --- | --- | --- |
| **P-1** | **仓颉杯作品收尾交付** | — | **截止 2026-10-23**，见 §9 R-1。**新项目不要掺进来** |
| **P0** | fork 仓库 → 砍社团域 → 建 科室/医生/排班/挂号单/病历 五表；**号源域独立路径 + 写 ADR** | 1–2 周 | 架构决策落定 |
| **P1** | **挂号闭环**：排班 → 号源 → 乐观锁扣号 → 幂等 → 退号归还 | 2–3 周 | ★ **全项目风险最高，必须最先做** |
| **P2** | AI 分诊：加工具条目 → `verify_recommendation()` → 危急关键词兜底 | 1–2 周 | 复用度最高，但**必须排在 P1 之后**（分诊正确性依赖真实号源） |
| **P3** | AI 能力中心：配置/Prompt/工具开关落 MySQL + 缓存失效 | 1–2 周 | 注意 §5.3 密钥不落库 |
| **P4** | 预问诊 SSE + 电子病历 + 运营看板 | 2–3 周 | |
| **P5** | RAG 知识库 | 1–2 周 | 不影响主闭环，可最后做 |

**前 P0–P1 就能验证项目死活**，且都落在团队能力圈内。

---

## 9. 风险登记

| # | 风险 | 级别 | 说明 / 缓解 |
| --- | --- | --- | --- |
| **R-1** | **与仓颉杯收尾撞车** | 🔴 高 | 截止 **2026-10-23**（[cangjie-cup-2026-evaluation.md:10](baseline/docs/cangjie-cup-2026-evaluation.md#L10)），该文档自己的结论是「**把开发停在这里，转去做呈现**」（[同文档:317](baseline/docs/cangjie-cup-2026-evaluation.md#L317)）。**先把比赛交付掉** |
| **R-2** | **架构债：双数据访问范式** | 🟡 中 | §5.1。缓解：限制在号源/挂号域，写 ADR + 测试钉住「整体替换不碰新表」 |
| **R-3** | 手写 SQL 映射的人力成本 | 🟡 中 | §6.3。缓解：只建必要表，不做 21 张 |
| **R-4** | **医疗合规**（病历/预问诊 = 敏感个人信息） | 🟠 中高 | 参考系统**通篇未提合规**（它是演示项目）。真实落地需个保法合规、等保、实名、留存。**暂无合作方 → 当前不阻塞**，但**一旦有真实医院合作方，合规会变成第一优先级且工期不可压缩** |
| **R-5** | 无真实 HIS/医保/支付对接 | 🟡 中 | 参考系统也没有。原型阶段用模拟数据即可，但**要留接口位** |
| **R-6** | 仓颉生态迭代速度（新模型/新框架适配慢） | 🟢 低 | 统一走 OpenAI 兼容协议可缓解（仓库已有此设计） |
| **R-7** | 密钥落库倒退 | 🟢 低 | §5.3 已给缓解方案 |

---

## 10. 待决问题（进新工作区先回答）

| # | 问题 | 为什么重要 |
| --- | --- | --- |
| **Q1** | **新项目是 fork 本仓库，还是新建空仓再选择性搬运？** | fork 会带上社团域的全部历史与测试（噪音大但脚手架齐全）；空仓干净但要从零搭构建/测试 |
| **Q2** | **数据模型范围**：参考系统 21 张表，我们**先建哪几张**？ | 建议最小集：科室/医生/排班/号源/挂号单/患者档案/病历 = 7 张。表数直接决定 §6.3 的人力成本 |
| **Q3** | **患者端页面范围**：复用哪些既有页面？ | 参考系统患者端 6 类页面；`entry/src` 有 21 页可作组件来源 |
| **Q4** | **管理端是否复用 `server/admin-web`（Vue3）？** | 复用则运营看板省一大截；但要注意它是**运维台**，信息架构要重做 |
| **Q5** | **单院区的具体量级**：日门诊量？号源放出峰值并发？ | 决定 §5.1 的扣号路径是否需要加重试/排队，以及是否真的永远不需要 Redis |
| **Q6** | **AI 模型选型与合规**：用哪家？（参考系统用百炼 DashScope）患者主诉属敏感信息，**出境/第三方处理需评估** | 影响 P2/P3 排期与 §9 R-4 |

---

## 附录 A · 关键代码落点索引

**轻舟框架**（`server/third_party/qingzhou/src/`）
- `context.cj:301` `streamStart(contentType)` — 进入 SSE/chunked 模式
- `context.cj:314` `writeChunk(bytes|String)` — 流式写块
- `httpclient.cj:124` — 出站 SSE/chunked 透传
- `db.cj:100-105` `DbBackend` 接口 / `exec()` 返回受影响行数
- `db.cj:124-131` 参数化 `query/exec(sql, Array<DbValue>)`
- `db.cj:152` `withTransaction(body)`
- `dbquery.cj:89` `dbRaw(sql, ps)` ｜ `dbquery.cj:492-556` `UpdateQuery`

**本仓库服务端**（`server/src/`）
- `mysql_store.cj:30-37` 整体替换语义 ｜ `:218` exec ｜ `:313` `SCHEMA_DDL`
- `ai_tools.cj:17-18` 只读→读写「结构不用改」 ｜ `:34` `write` 标记 ｜ `:54` `aiToolSpecs()`
- `ai_client.cj:15-20` 三条设计口径 ｜ `:33-46` 三态来源
- `ai_config.cj:75` `aiOptionsFromFlags` ｜ `:321` `setAiOptions` ｜ `:325` `aiOptionsCurrent`
- `ai_proposal.cj` 写操作提议两段式
- `store.cj:136` `IdemRecord` ｜ `store_queries.cj:373` `idemKey`
- `limits.cj:47` `MAX_BODY_BYTES` ｜ `:83` `bodyLimit()`
- `h_ai.cj` `aiAgentLoop`
- `perms.cj` `can()`

**客户端**（`entry/src/main/ets/`）
- `api/AiApi.ets:3` **不进离线队列**的红线
- `store/OutboxStore.ets`、`store/OutboxSync.ets`、`store/TokenStore.ets`、`store/SessionStore.ets`
- `core/Theme.ets` 设计 token 唯一同源
- `api/HttpClient.ets` 401/403 统一处理

**管理端**（Vue 3）：`server/admin-web/src` ｜ 产物 `server/admin-web/dist`（随仓库提交）

**测试**：`server/tests/`（`smoke.ps1` / `bench.ps1` / `tls-check.ps1` / `client-contract-check.ps1` / `admin-check.ps1` / `ops-check.ps1` / `ai-*.ps1`）

**关键文档**：[README.md](baseline/README.md)（未决事项 + 已知缺陷 + 设计原则）｜ [capacity-baseline.md](baseline/docs/capacity-baseline.md) ｜ [API-NOTES.md](baseline/docs/API-NOTES.md) ｜ [v1-scope.md](baseline/docs/v1-scope.md) ｜ [mysql-backend.md](baseline/docs/mysql-backend.md) ｜ [llm-client-spec.md](baseline/docs/llm-client-spec.md) ｜ [cangjie-cup-2026-evaluation.md](baseline/docs/cangjie-cup-2026-evaluation.md)

---

## 附录 B · 参考系统技术栈（原文口径，备查）

- **后端**：FastAPI（19 个路由模块）、SQLAlchemy 2.0 + PyMySQL（21 张表）、Pydantic v2 + pydantic-settings、JWT + passlib(pbkdf2_sha256)
- **AI 层**：LangChain `langchain_openai.ChatOpenAI`、**手写 ReAct Agent 状态机（最多 6 轮）**、阿里云百炼 DashScope（OpenAI 兼容，`qwen-plus` + `text-embedding-v3` 1024 维）、SSE
- **数据**：MySQL 8（业务 + AI 配置 + Prompt + 知识库 + 向量 JSON + 全链路调用日志）
- **前端**：Vue 3 + Vue Router + Vite + Element Plus（主题色 `#00a9a7`）+ Axios 拦截器 + 自研 SSE 解析器
- **工程化**：通用 CRUD 路由工厂、动态 Pydantic Schema、统一响应 `{code,msg,data}`、全局异常、loguru、代码脚手架生成器

---

## 附录 C · 证据等级与未验证项

**✅ 本次实测核验**（直接读代码/文档得到）：轻舟 SSE 支持、`exec()` 返回受影响行数、`withTransaction`、`dbRaw`、`IdemRecord`/`idemKey`、`ai_toolSpecs` 静态白名单、`ai_client` 三口径、`ai_config` 来自命令行参数、`mysql_store` 整体替换语义、`README` 未决 #12 与 S-14、`admin-web` 是 Vue 3、RAG 相关 **0 匹配**、容量基线数字。

**📄 文档记载未逐行复核**：轻舟快照版本与 MANIFEST、`can()` 实现、`audit.cj`、`ai_transport.cj`、`aiAgentLoop` 细节、测试项数（595/648/440/…）。

**🧮 推断（未实测，落地前必须验证）**：
1. §8 全部工期
2. §5.1「新表不进 `PersistedState` 则整体替换不碰它」—— 建议落地即写测试钉住
3. 「单院区单实例下 MySQL 原子 UPDATE 吞吐绰绰有余」—— 需按 Q5 的真实量级压测
4. §7 架构图与阶段划分

---

> **一句话总结**：参考系统最值钱的不是「接了 LangChain」，而是把大模型关进了业务约束的笼子；
> **这套笼子本仓库已经造好了**，而且是带测试的。新项目要做的是**换掉笼子里的动物**——
> 从「社团任务」换成「科室/号源/病历」，再补上 RAG 与 DB 驱动的 AI 配置这两块全新件。
