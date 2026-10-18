# 智慧医院智能导诊就诊系统 · 系统设计

> 本文回答"这套系统是怎么搭起来的"：总体架构、模块划分、接口设计、数据流转、关键技术实现。
> 项目背景与需求见 [PROJECT-OVERVIEW.md](PROJECT-OVERVIEW.md)；逐字段接口口径见 [FRONTEND-INTEGRATION.md](FRONTEND-INTEGRATION.md)；架构决策的**论证过程**见 [adr/ADR-0001](adr/ADR-0001-号源与挂号独立MySQL路径.md)。

---

## 1. 总体架构

```
┌──────────────────────────── 客户端层（4 个端）────────────────────────────┐
│ 鸿蒙患者端 entry+common-core+feature-patient │ 鸿蒙医生端 feature-doctor    │
│ 鸿蒙管理端 feature-admin                     │ 安卓患者端 android-patient   │
│ 管理台网页 server/admin-web（服务端静态托管在 /admin）                      │
└───────────────────────────────┬───────────────────────────────────────────┘
                    HTTPS + JSON 信封 {ok,data} / {ok:false,error{code,message}}
┌───────────────────────────────▼───────────────────────────────────────────┐
│ 接入层 —— 轻舟框架（Koa 风格洋葱中间件 + Trie 路由）                        │
│  requestId → logger → 请求体上限 64 KiB → bodyParser → cors → timeout 15s  │
│  → 静态资源(/admin) → 路由 → [兜底] 404/405 信封 → 统一错误处理             │
└───────────────────────────────┬───────────────────────────────────────────┘
┌───────────────────────────────▼───────────────────────────────────────────┐
│ 业务层（handler → domain → repo，单向依赖，domain 不碰 Context）            │
│  http_app.cj / http_p4.cj / http_kb.cj / http_notice.cj / http_base.cj     │
│           ↓                                                                │
│  domain_booking.cj  domain_emr.cj  domain_kb.cj  domain_notice.cj          │
│           ↓                                                                │
│  auth_repo.cj  kb_repo.cj  triage_stat.cj  ai_settings.cj  …               │
└───────────────────────────────┬───────────────────────────────────────────┘
┌───────────────────────────────▼───────────────────────────────────────────┐
│ 数据层 —— 轻舟 DbBackend（参数化绑定 + 事务 + 断链自愈 + 探活）             │
│  MySQL / MariaDB：17 张表，启动时自动建表 + 编号迁移（幂等）                │
└───────────────────────────────────────────────────────────────────────────┘
     旁路：AI 出站（https-only，超时/并发/降级）      SSE 流式（预问诊）
```

**设计原则（这几条决定了后面的所有取舍）**

1. **只有一种数据访问范式**：直接 SQL + 事务。`exec()` 的受影响行数就是扣号/归还/锁定的判据。旧的内存 Store 范式已整体拆除（ADR-0001 rev.6/rev.7）。
2. **模型输出 = 不可信输入**：AI 只负责"把话说顺"，能不能推荐、推荐什么科室，由校验层按**真实号源**复查。
3. **事务里绝不出站**：`withTransaction` 内不允许任何网络调用（AI/HTTP），否则一个慢请求会把锁持有几秒。
4. **失败要能被看见**：任何降级都必须留下可查询的事实（`source` / `reason_code` / `degrade_reason` / `/health.db`），不许静默兜底。
5. **单实例优先**：不引入 Redis / 向量库 / 消息队列，靠数据库与进程内纪律解决并发与一致性问题。

---

## 2. 模块划分

### 2.1 服务端（`server/src/` 38 个 `.cj`）

| 层 | 文件 | 职责 |
| --- | --- | --- |
| **入口与装配** | `main.cj` | 子命令（`serve` / `create-admin` / `selftest` / `db-*`）、参数解析、启动自检、优雅关闭、AI 启动提示 |
| | `http_app.cj` | 中间件装配、**全部路由注册**、角色守卫、健康检查、框架层错误体注入 |
| | `http_common.cj` | 信封与错误码表（`apiErrorSpec`）、角色守卫、请求体上限/解析越界统一封装 |
| | `http_base.cj` | 基础数据域 HTTP（科室/医生/患者/账号） |
| | `db_bootstrap.cj` | 连接自检、建库建表、迁移编排 |
| | `schema.cj` | 17 张表的 DDL + 编号迁移（对已存在的库只做 ALTER） |
| **域逻辑** | `domain_booking.cj` | 号源查询、**原子扣减 + 幂等**、退号归还、就诊时间线状态机调用 |
| | `domain_emr.cj` | 七段式病历草稿/锁定、修订快照、就诊状态机（`visitTransitionAllowed`） |
| | `domain_kb.cj` | 知识库文档与切块、检索（关键词 + 向量路） |
| | `domain_notice.cj` | 公告域 |
| | `domain_base.cj` | 基础数据域规则 |
| **HTTP 分组** | `http_p4.cj` | 病历 / 接诊队列 / 看板 / 患者档案 |
| | `http_kb.cj` | 知识库管理端 CRUD + 检索 |
| | `http_notice.cj` | 公告 |
| **鉴权** | `auth_crypto.cj` | PBKDF2-HMAC-SHA256 ×100000、口令强度、令牌生成 |
| | `auth_repo.cj` | 用户/令牌/登录失败表、登录、会话按设备管理、限流锁定 |
| **AI** | `ai_settings.cj` | 配置读取（DB 驱动）+ 校验 + 密钥引用解析（`env:`/`file:`） |
| | `ai_model.cj` | 模型清单（对话/向量分开，默认模型） |
| | `ai_prompt.cj` | Prompt 模板落库 + 占位符校验 |
| | `ai_call.cj` | 出站调用（OpenAI 形状 `chat/completions`）、超时/并发、三态降级 |
| | `ai_triage.cj` | 分诊编排：规则 → 模型增强 → 安全清理 → 失败降级 |
| | `triage.cj` | 规则分诊 + **校验层**（绝不给没号的推荐）+ 三态结论 |
| | `triage_redflag.cj` | 危急征象词表 + 否定词 + 共现 |
| | `triage_stat.cj` | 分诊命中/转化统计落库 |
| **预问诊** | `previsit.cj` | 多轮采集 + **SSE 流式**回显 + 会话持久化 |
| **看板** | `dashboard.cj` | 聚合指标（科室/趋势/使用率/命中/完成率/病历进度/AI 概览），只出聚合 |
| **知识库仓储** | `kb_repo.cj` | 切块、纯仓颉余弦、关键词检索降级 |
| **测试与验收** | `acceptance*.cj`（9 个）+ `triage_test.cj` | 782 条断言的验收套件（随二进制内置，`hospital-server.exe authtest/triagetest` 可跑） |

### 2.2 客户端

| 端 | 结构 | 说明 |
| --- | --- | --- |
| 鸿蒙（ArkTS / ArkUI V2） | `entry`（HAP 壳）→ `feature-patient` / `feature-doctor` / `feature-admin`（HAR）→ `common-core`（HAR） | 单向依赖：feature 只依赖 common-core；网络/鉴权/SSE/持久化/主题全部在公共层 |
| 安卓（Kotlin Views） | `android-patient/app` | AGP 8.5.2 / Kotlin 2.0.21 / Gradle 8.7 / minSdk 26 / compileSdk 35 |
| 管理台网页 | `server/admin-web/` | 零第三方依赖的原生 JS/CSS，由服务端以静态资源挂载在 `/admin` |

### 2.3 契约（`contract/`）

| 目录 | 内容 |
| --- | --- |
| `contract/examples/` | 67 个**逐字节**样例（每个端点至少一例，含错误形状） |
| `contract/schema/` | 24 个 JSON Schema（18 个 data 级 + 6 个 body 级） |
| `contract/schema-map.json` | 样例 → Schema 映射 |
| `contract/CHANGELOG.md` | 契约变更（含"客户端要不要动"的判断） |

---

## 3. 接口设计

### 3.1 统一信封

```jsonc
{ "ok": true,  "data": { … } }                                    // 成功
{ "ok": false, "error": { "code": "SLOT_GONE", "message": "…",     // 失败
                          "fields": { "login_name": "…" } } }       // fields 仅校验类错误
```

- 客户端**只判 `code`，不判 HTTP 状态码**（状态码由 `apiErrorSpec` 统一映射，仅作运维观测）。
- 状态码与默认文案集中在 `server/src/http_common.cj` 的 `apiErrorSpec(code)`。
- 框架层错误（非法 JSON 400 / 请求体过大 413 / 路由未匹配 404 / 方法不匹配 405 / 静态 404/416）**也已统一成同一信封**（2026-10-17 完成），细节见 [FRONTEND-INTEGRATION.md §3.2](FRONTEND-INTEGRATION.md)。

### 3.2 端点规模与分组

| 分组 | 路径模板数 | 说明 |
| --- | --- | --- |
| `/api/v1/admin/**` | 26 | 用户/科室/医生/排班/号源/患者/AI 配置/知识库/看板 |
| `/api/v1/doctor/**` | 14 | 接诊队列、病历工作台、既往病历、修订历史、预问诊交接 |
| `/api/v1/auth/**` | 6 | 登录、登出、会话列表/撤销、当前用户 |
| `/api/v1/previsit/**` | 3 | 会话创建、SSE 流、补全 |
| `/api/v1/appointments/**` | 3 | 建单、退号、按幂等键回查 |
| 其它 | 10 | `medical-records`(2) `schedules`(2) `triage` `doctors` `departments` `notices` `kb` `health` |

> 路径模板 62 个 ≈ **81 个方法+路径组合**（以 `server/tests/doc-counts.ps1` 实测为准：同一路径的 GET/PUT/DELETE 各算一个）。

### 3.3 鉴权

| 项 | 口径 |
| --- | --- |
| 令牌 | 64-hex 不透明串，`Authorization: Bearer <token>`，30 天滑动续期 |
| 口令存储 | PBKDF2-HMAC-SHA256 ×100000 + 16B 随机 salt（`auth_crypto.cj`） |
| 角色 | `patient` / `doctor` / `admin`，由守卫在路由层强制，handler 内不写分支 |
| 登录限流 | 同账号连续失败 5 次锁定 900s → `429 AUTH_RATE_LIMITED` + `retry-after` |
| 开发态身份 | `--dev-auth` 下可用 `X-Role` / `X-Patient-Id` 头绕过认证；与 `--prod` **互斥**（同时传直接拒绝启动） |

### 3.4 幂等与退号语义（客户端最容易做错的地方）

| 场景 | 服务端行为 |
| --- | --- |
| 同 `patient` + 同 `client_token` 重复建单 | 返回**同一张**挂号单（200，非 201），六进程并发实测 1×201 + 5×200 |
| 号源放完 | `409 SLOT_GONE` |
| 排班不存在/已停诊 | `404 SCHEDULE_NOT_FOUND` |
| 退号 | 已 booked → 取消 + 归还号源（`slot_restored:true`）；已取消 → 200 且 `already_cancelled:true`；病历已锁定 → `409 APPOINTMENT_RECORD_LOCKED`；非可退状态 → `409 APPOINTMENT_NOT_CANCELLABLE` |

> `client_token` 最长 64 字符（服务端校验，超长 400）；退号时服务端把 `client_token` 置 NULL 以允许键复用。

### 3.5 SSE（预问诊）

`GET /api/v1/previsit/:id/stream` 返回 `text/event-stream`，帧为 `event:` + `data:`（JSON）。服务端在 handler 内 `streamStart()` → 多次 `writeChunk()` → 返回后自动写 last-chunk（`server/third_party/qingzhou/src/context.cj:301-325`）。原始帧样例见 [FRONTEND-INTEGRATION.md §6](FRONTEND-INTEGRATION.md)。

---

## 4. 数据流转

### 4.1 挂号（并发安全的关键链路）

```
POST /api/v1/appointments {schedule_id, client_token, …}
  ├─ 参数校验（client_token ≤64、schedule 存在且可售）
  ├─ 先按 (patient_id, client_token) 回查 → 命中即直接返回旧单（幂等，不重复扣号）
  └─ withTransaction
       ① UPDATE schedule SET remain_num = remain_num - 1, version = version + 1
              WHERE id = ? AND remain_num > 0 AND enabled = 1        -- 受影响行数=1 才算抢到
       ② INSERT INTO appointment (…, client_token, visit_date 快照)
              -- 唯一键 uk_appointment_patient_token 兜底并发重复
       commit
  失败分类：①=0 行 → 再判"排班是否还可售" → SLOT_GONE / SCHEDULE_NOT_FOUND
            ②唯一键冲突 → 回查同 token 的单据 → 返回旧单（200）
```

**为什么不用乐观锁**：ADR-0001 rev.3 的实测结论——`WHERE version = ?` 在高并发下会大量失败重试并引入"版本冲突"这种对用户无意义的错误；改成"带条件的原子自减"后，判据只剩"有没有号"。

**就诊日快照**：挂号单存 `visit_date`，管理员事后顺延排班也不会让已挂患者串号。

### 4.2 退号

```
POST /api/v1/appointments/:id/cancel
  ├─ 状态机前置判定（非 booked 且非 cancelled → APPOINTMENT_NOT_CANCELLABLE）
  ├─ 病历 locked 检查（emrHasLockedRecord → APPOINTMENT_RECORD_LOCKED）
  └─ withTransaction
       UPDATE appointment SET status='cancelled', cancelled_at=?, client_token=NULL
         WHERE id = ? AND status='booked'
       UPDATE schedule SET remain_num = remain_num + 1 WHERE id = ?
       记录 slot_restored（归还失败要能被看见，不能假装成功）
```

### 4.3 AI 分诊（三态降级）

```
POST /api/v1/triage {chief_complaint, …}
  ① 危急征象规则（词表+否定+共现）→ 命中即给出"立即就医"结论，不再问模型
  ② 规则候选（按科室/症状映射）+ 号源校验（只保留当前有号的科室）
  ③ 模型增强（可选；未启用则 source=rules）
       出站失败/超时/输出不合规 → 降级到规则，degrade_reason=CALL_FAILED
  ④ 校验层复查：模型不得新增科室、不得删空推荐（options 以规则结果为准）
  ⑤ RAG 片段（有界、过安全层）附加为"参考信息"，不参与决策
  ⑥ 落 triage_stat（命中/转化），返回 source / reason_code / ai_reason
```

### 4.4 电子病历（草稿 → 锁定）

```
PUT  /api/v1/doctor/visits/:id/record        保存草稿（status=draft，不落版本）
POST /api/v1/doctor/visits/:id/record/lock   提交锁定（status=locked，写 revision 快照）
     └─ 前置：就诊状态必须允许（visitTransitionAllowed）；锁后 saveDraft 一律拒绝
GET  …/record/revisions[/:version[/diff]]    修订历史与逐段对比（只读）
```

### 4.5 数据模型（17 张表）

| 分组 | 表 |
| --- | --- |
| 基础数据 | `department` `doctor` `patient` `notice` |
| 号源与挂号 | `schedule` `appointment` |
| 病历 | `medical_record` `medical_record_revision` |
| 鉴权 | `auth_user` `auth_token` `auth_login_attempt` |
| 预问诊 | `previsit_session` |
| AI | `ai_setting` `ai_model` |
| 知识库 | `kb_doc` `kb_chunk` |
| 统计 | `triage_stat` |

关键约束：`uk_appointment_patient_token (patient_id, client_token)`（幂等兜底）、`uk_record_appointment (appointment_id)`（一诊一历）、`uk_department_name`、`client_token VARCHAR(64) COLLATE utf8mb4_bin`（大小写敏感，避免两个不同幂等键被当成同一个）。

---

## 5. 关键技术实现

| # | 技术点 | 做法 | 位置 |
| --- | --- | --- | --- |
| 1 | **原子扣号 + 幂等** | 带条件自减 + 唯一键 + 同事务 INSERT；先回查再扣号 | `domain_booking.cj` |
| 2 | **就诊状态机** | 显式跃迁表，非法跃迁一律 409；到院/候诊/接诊三段时间戳 | `domain_emr.cj:visitTransitionAllowed` |
| 3 | **令牌与限流** | 不透明令牌 + PBKDF2 100k + 失败计数表（窗口 + 锁定期）+ 会话按设备 | `auth_crypto.cj`、`auth_repo.cj` |
| 4 | **数据库断链自愈** | 链路级错误识别 → 重建 Datasource → 重做 session 变量；事务未结束拒绝自动重连；`/health` 探库并 503 | `third_party/qingzhou/src/db_mysql.cj`、`http_app.cj:healthBody` |
| 5 | **自动建表与迁移** | 启动时 `CREATE TABLE IF NOT EXISTS` + 编号迁移（先查 `information_schema` 再 `ALTER`），重复执行安全 | `schema.cj`、`db_bootstrap.cj` |
| 6 | **框架层错误体可注入** | `Router.errorBody` / `StaticOptions.{notFound,forbidden,rangeNotSatisfiable}Body` 暴露为可配置项（框架默认值不变），应用注入统一信封 | `third_party/qingzhou/src/router.cj`、`static.cj`；应用侧 `http_app.cj:2973`（`passOnNotFound`）、`:2986`（`errorBody`）、`:3099-3102`（静态三种 body） |
| 7 | **SSE / chunked 出站流式** | 服务端 `streamStart/writeChunk`；出站边读边转发并在结束时 `close()` | `context.cj`、`httpclient.cj`、`previsit.cj` |
| 8 | **AI 三态降级 + 校验层** | 出站失败/超时/不合规 → 规则兜底且如实标注 `source`；校验层按真实号源复查 | `ai_call.cj`、`ai_triage.cj`、`triage.cj` |
| 9 | **密钥不落库** | 只存 `env:NAME` / `file:path` 引用，裸密钥机制性拒收；设置页回显 `key_ref_kind` / `key_resolvable` | `ai_settings.cj` |
| 10 | **零向量库 RAG** | 切块（按字符、带重叠、结构性不丢内容）→ MySQL JSON 存向量 → 纯仓颉余弦；无 embedding 时走关键词路 | `kb_repo.cj`、`domain_kb.cj` |
| 11 | **契约即测试** | 导出机生成样例 → 逐字节比对 + Schema 结构校验双门禁 | `contract/`、`tests/contract-check.ps1`、`tests/export-contract.ps1` |
| 12 | **全量 live 门禁** | 一条命令起三个实例跑 17 次运行（16 个脚本，含契约、AI、限流） | `tests/final-verify.ps1` |

---

## 6. 质量保障

| 层次 | 内容 | 规模 |
| --- | --- | --- |
| 单元自检 | `hospital-server.exe selftest` / `authtest` / `triagetest` | 51 + 17 + 150 项 |
| 验收套件 | `accept`（`acceptance*.cj`，随二进制） | **782 条断言** |
| 接口套件 | `server/tests/*.ps1` | 26 个测试文件（25 个 `.ps1` + 1 个 `.mjs`）= 19 个可独立运行的门禁套件 + `common.ps1` + `final-verify.ps1` + 4 个辅助脚本（`doc-counts` / `json-schema-lite` / `export-contract` / `stress-booking`）+ `admin-web-smoke.mjs` |
| 契约门禁 | 样例逐字节 + Schema 结构 | 67 样例 / 24 Schema，PASS 69 / FAIL 0 |
| 压测 | 20/30/40/50 进程抢同数号源 | 号源全部卖光、零超卖、零丢号 |
| 全量门禁 | `final-verify.ps1` | 18/18 全绿 |

---

## 7. 已知边界

| 边界 | 说明 | 后续方向 |
| --- | --- | --- |
| 单实例部署 | 未做水平扩展；会话在 DB，但扣号依赖单库事务 | 多实例需引入连接级限流或分库 |
| DB 串行访问 | 单连接（断链可自愈，但吞吐受限于串行 SQL） | 引入连接池需先解决事务语义 |
| 向量路未端到端验证 | 缺可用的 embedding 端点（DeepSeek 无 embeddings） | 配 DashScope/其它兼容端点即可启用；算法与仓储已有测试 |
| 无推送 | 就诊进度靠客户端轮询/拉取 | 接 WebSocket 或推送通道 |
| 管理台零框架 | 原生 JS，无构建链 | 复杂交互再考虑引入框架 |
