# 服务端接入大模型 API · 落地指南

> 📁 **AI 服务端接入指南** ｜ 本文件：`llm-backend-guide.md` ｜ [全部文档目录](README.md)

> **定位**：`docs/llm-client-spec.md` 写的是「**要求**」（接口语义、约束、验收标准）；本文写的是「**怎么做**」——
> 按步骤能直接开工。两份配合看：先读 spec，再照本文实施。
>
> **前置状态**：框架能力**已就位**。内置轻舟快照 `3d6c1a36`（v0.12.0）已提供
> `src/outbound.cj`（TLS / 重试退避 / 可注入传输层 / 出站并发）、`src/jsonschema.cj`（schema 校验）、
> `src/jsonx.cj` 的 `extractJson`/`parseJsonLoose`（容错提取）、`src/security.cj` 的 `redact`（日志脱敏）。
> 详见 spec §14。
>
> **当前进度（2026-10-06 更新）**：AI 能力**已全部落地**。服务端现有 **8 个 AI 源文件**：
> `ai_config.cj` · `ai_schema.cj` · `ai_client.cj` · `ai_transport.cj` · `ai_tools.cj` ·
> `ai_proposal.cj` · `ai_risk.cj` · `h_ai.cj`（另有 `main.cj` / `errors.cj` / `limits.cj` 的接点）。
> **5 个接口全部可用，且真实模型联调已跑通。**
>
> 因此本文以下内容应读作**设计与口径说明**，**不再表示「待做」**。
> **运维排障 / 值班**请看 [`llm-ops-guide.md`](llm-ops-guide.md)；**启动参数**见 `server-guide.md`。
> （原文"尚无任何 AI 代码"是 2026-10-04 的时点事实，已被评审 P3-1 指出过期。）

---

## 0. 先看这一节：为什么 P0 比原来小了很多

原计划要自建「传输层 + 归一化 + schema + 限流 + 脱敏」五个模块。框架升级后，**只剩业务层**：

| 原计划自建 | 现在怎么做 |
|---|---|
| HTTPS/TLS 客户端 | 用 `OutboundClient(StdxTransport(...), retry:, maxConcurrency:)` |
| `LlmTransport` 可注入接口 | 框架已有 `HttpTransport` + `MockTransport`（离线可测） |
| 模型输出归一化（剥围栏/括号配平） | 用 `extractJson` / `parseJsonLoose` |
| schema 校验 | 用 `JsonSchema.requireStr/requireIntIn/validate` |
| 失败分类与重试 | 框架 `RetryPolicy`（网络/429/5xx 可重试，4xx 不重试）——**正好是 spec §5.2 的规则** |
| 日志脱敏 | 用 `redact()` |

**要自己写的**只有三块：**配置**（§2）、**业务编排与降级**（§3）、**权限收敛**（§4）。

---

## 1. 需要新增/改动的文件

| 文件 | 动作 | 职责 |
|---|---|---|
| `docs/api-design.md` | **先改这个** | 新增 Part「AI 能力」：5 个接口定义 + §1.3 错误码表加 1 条。⚠ 本项目规定**文档是唯一权威，先改文档再改代码** |
| `server/src/ai_config.cj` | 新增 | `AiOptions`（端点/密钥文件/CA/超时/并发/预算）+ 启动期校验 |
| `server/src/ai_client.cj` | 新增 | 包一层框架 `OutboundClient`：把 `OutboundResponse` 映射成业务语义、做降级、写审计 |
| `server/src/ai_transport.cj` | 新增（★ 实现时才发现要加） | **自实现 `HttpTransport`**：框架 `httpclient.cj` 的 `readBodyText` 把「短读」当 EOF（长回答被截断 → 静默降级，已用分块桩确定性复现），这里改用「只有 `n <= 0` 才是流结束」，并关掉自动重定向（fail-closed） |
| `server/src/ai_schema.cj` | 新增 | 各智能功能的 `JsonSchema` 定义与提示词模板 |
| `server/src/h_ai.cj` | 新增 | 4 个 HTTP handler（`h_*.cj` 命名与既有 handler 一致） |
| `server/src/main.cj` | 改动 | 注册 4 条路由；`usage()` 加 `--ai-*` 参数说明 |
| `server/src/errors.cj` | 改动 | `errorSpec()` 增加 `AI_RATE_LIMITED` 分支 |
| `server/src/audit.cj` | 复用 | 智能调用与工具调用都要落审计，无需改动 |
| `server/src/tests.cj` | 改动 | 加入 U1–U12 单测（spec §10.2） |
| `server/tests/ai-check.ps1` + `ai-e2e.ps1` + `ai-stub.mjs` | 新增 | 两套闸门：`ai-check`（**不需要 MySQL**，验参数与配置解析）与 `ai-e2e`（真库 + 真服务 + 真 HTTP）。`ai-stub.mjs` 是可控桩（ok / garbage / fenced / e500 / e401 / slow / redirect） |
| `server/build-package.ps1` | 改动 | 部署包带上 CA bundle 与密钥文件模板 |
| `docs/local-deploy.md` | 改动 | 补「怎么配 AI 端点/CA/密钥」一节 |

> **放在 `server/src/` 根下**：`build.ps1` 取的是 `server/src/*.cj`，**不递归子目录**。
> 新增顶层函数前先查重名（与轻舟同包，spec §3 C7），统一加 `ai` / `Ai` 前缀最省事。

---

## 2. 配置与密钥（对应 spec §5.1）

### 2.1 硬约束：密钥不能走环境变量

本工具链的仓颉 std **没有 `getEnv`**，所以密钥只能走**文件路径**参数。
**禁止**命令行直接传密钥（会进进程列表与 shell 历史）。

沿用 `main.cj:274` 的 `flagOf(flags, k)`（**只返回 String**，数值要自行 `parse` 并校验）：

```
--ai-endpoint <URL>          # OpenAI 兼容完整 URL
--ai-model <名字>            # 模型名（协议必填字段），如 deepseek-chat
--ai-key-file <PATH>         # 密钥文件（首尾空白会被裁剪）
--ai-ca <PATH>               # CA bundle（Windows 上必须给，见下）
--ai-timeout <秒>            # 默认 30；允许 1..300
--ai-max-concurrent <N>      # 默认 4；允许 1..64（直达 Semaphore 计数）
--ai-max-tokens <N>          # 默认 2048；允许 64..8192
                             #   ⚠ 给太小会截断长正文 -> 非法 JSON -> **静默降级**
--ai-insecure-trust-all 1    # ⚠ 仅本机开发；**必须带值**（splitFlags 只认 `--x value`）
```

### 2.2 Windows 上必须自备 CA（**Linux 上不必**）

**Windows**：`CertificateVerifyMode.Default` 必然失败
（`certificate verify failed (134), TLS alert unknown CA`）—— 它读不到可用信任库（spike R5 实测）。

**Linux**：`Default` **会读系统信任库、握手是通的** —— 2026-10-06 在 **WSL Ubuntu 26.04 + cjc 1.2.0**
上实测，`Default` 打 `api.deepseek.com` / `baidu` / `github` / `bing` 四个公网站点**全部通过**。

> ⚠ **但本服务仍然要求显式给 `--ai-ca`**（`aiValidate` 一律检查）—— 宁可早失败并说清原因，
> 也不要在 Windows 部署时运行时才炸。所以 **Linux 上也要给，内容可以就是系统那份**：
> `--ai-ca /etc/ssl/certs/ca-certificates.crt`。
>
> 📌 **勘误**：2026-10-06 本文一度被改成「与 OS 无关、两个平台都要」，那是**未实测的过度推理**；
> 随后用 WSL Ubuntu 实测推翻了它。原文的平台归属（Windows）本来就是对的。

生产（Windows）必须随部署包发一份 CA bundle，用 `CustomCA` 显式加载。

框架已经把这段封装好了，直接用：

```cangjie
import stdx.net.tls.*          // 必需：少了它运行时报 "Global TLS kit is not set"
import stdx.net.tls.common.*
import qingzhou.*

var tls = OutboundTlsOptions()
if (opts.insecureTrustAll) {
    tls.trustAll = true                     // 仅本机开发
} else {
    tls.caBundlePath = opts.caBundlePath   // 生产
}
let transport = StdxTransport(opts.timeoutSecs, tls)
let client = OutboundClient(transport, retry: policy, maxConcurrency: opts.maxConcurrent)
```

### 2.3 启动期校验（fail-fast，别等第一次调用才报）

| 情况 | 行为 |
|---|---|
| `--ai-endpoint` 为空 | AI 功能整体标记「未配置」，**服务照常启动**（不能因为没配大模型就起不来） |
| endpoint 非 `https://` | 除非 `--ai-insecure-trust-all`，否则拒绝启用 AI |
| CA / 密钥文件不存在 | 拒绝启用 AI，并打印**可照着做**的提示 |
| 数值参数非法 | 按启动期错误处理，不静默取默认值 |

---

## 3. 接口契约（**先写进 `docs/api-design.md`，再写代码**）

### 3.0 通用约定

- 前缀 `/api/v1/ai/`；一律 **POST**（请求体带上下文）
- 成功信封沿用 §1.2：`{ "ok": true, "data": { ... } }`
- **失败永不返回 5xx**；模型不可用是「降级」，不是错误：

```json
{
  "ok": true,
  "data": {
    "source": "fallback",
    "note": "大模型暂不可用，以下依据历史数据给出",
    "...": "具体字段见各接口"
  }
}
```

- `source` 三值，客户端据此决定怎么展示（见前端文档）：
  | 值 | 含义 |
  |---|---|
  | `model` | 模型给出的 |
  | `fallback` | 模型不可用，退回规则/历史统计 |
  | `none` | 连兜底都给不出，界面须显示「暂不可用」 |

- 权限：**一律经 `can()`**。禁止在 AI 链路里另写一套 if（会与 `perms.cj` 漂移）
- 读范围沿用既有口径：任务/课题**读**为全社团，**写**不变（见 `docs/ui-spec-conformance-review.md`）

### 3.1 `POST /api/v1/ai/task-suggest` — 创建任务时的建议

```json
// 请求
{ "title": "筹备秋季招新", "desc": "……", "plan_id": 12, "dept_id": 3 }
// 响应 data
{
  "owner": { "id": 7, "name": "张三", "dept": { "id": 3, "name": "宣传部" } },
  "due_at": "2026-10-20T18:00:00+08:00",
  "granularity": "建议拆成 2—3 个子任务：物料、场地、宣传",
  "reasons": ["张三近 3 个月按期完成率 92%", "宣传部当前在途任务 2 件，负载最低"],
  "source": "model"
}
```

- **权限**：与创建任务同权（`can(member, "create_task", …)`）
- **兜底**：按「本部门在途任务数最少 + 历史按期率最高」给规则建议
- **数据源**：**内部历史数据为主**（相似历史活动、成员按期率、部门负载）。
  联网信息只作为可选增强——外部资料对社团任务价值有限，且会把运行绑死在第三方服务上

### 3.2 `POST /api/v1/ai/notice-draft` — 起草通知

```json
// 请求
{ "task_id": 42, "audience": "members" }
// 响应 data
{
  "title": "关于筹备秋季招新的通知",
  "body": "各位成员：……请于 10 月 20 日前完成……",
  "audience": "members",
  "suggest_send_at": "2026-10-16T09:00:00+08:00",
  "source": "model"
}
```

- **权限**：能读该任务即可
- **兜底**：模板填空（任务标题 / 负责人 / 截止时间 / 课题路径）
- ⚠ 本项目**目前没有任何通知/站内信/推送能力**（已确认 `通知|notify|push` 全 0 命中）。
  所以 v1 的产物就是「一段可复制的文本」；若要做真正的发送，需另立需求

### 3.3 `POST /api/v1/ai/retrospective` — 成效总结与延期归因

```json
// 请求（二选一）
{ "task_id": 42 }
{ "plan_id": 12 }
// 响应 data
{
  "summary": "该课题 6 个任务已完成 5 个，整体按期率 83%。",
  "overdue": {
    "is_overdue": true, "days": 3,
    "causes": [ { "kind": "dependency", "detail": "等待宣传部物料交付" } ]
  },
  "suggestions": ["下次把物料准备前置到活动前 3 周"],
  "source": "model"
}
```

- ⚠ **关键**：单纯报「是否延期」不必用模型——服务端**已有** `overdue_days` / `is_overdue` 派生量。
  这一项的价值全在 **`causes`（归因）与 `suggestions`**；如果只做查表，评审一句"这个 SQL 就能做"就带走了
- **兜底**：用既有派生量拼出**事实摘要**（不含归因），并标 `source = "fallback"`

### 3.4 `POST /api/v1/ai/ask` — 权限感知问答

```json
// 请求
{ "question": "我作为部长有哪些权限？" }
// 响应 data
{
  "answer": "你可以创建/编辑本部门课题与任务、审批本部门新成员的分配……",
  "basis": [
    { "kind": "permission", "ref": "can(): create_task, manage_dept_members" },
    { "kind": "data", "ref": "当前角色 vice_lead · 部门 宣传部" }
  ],
  "source": "model"
}
```

- **权限**：任何已登录成员
- ⚠ **权限类问题禁止由模型生成答案**：权限结论必须由 `can()` 计算后**拼进上下文**给模型润色。
  这样评委问"AI 说错权限怎么办"，答案是「AI 不生成权限，权限由 `can()` 算」
- **兜底**：`can()` 结果 + 静态章程条款 → 结构化回答

### 3.5 邀请风控（服务端内部，不单独开接口）

在既有 `pending` 审批流里对申请做**风险分档**，把结果作为待审批列表的一个字段暴露：

```json
{ "risk": { "level": "high", "reasons": ["同一 IP 短时间内 5 次申请"], "source": "fallback" } }
```

**不要**做成「自动通过」的开关——那只是 `if`，不是智能。

> ⚠ **2026-10-06 定稿（与本节原稿不同，以这里为准）**：
> **分档只影响排序与呈现，不影响审批动作。**
> 原稿写的「低风险自动通过 / 中风险标记待抽查 / 高风险转人工」**没有采纳** ——
> 按模型的判断**自动批准一个人入社**是安全决策，而且直接违反本模块铁律
> 「模型输出不得直接成为写库值」（`llm-client-spec` **D4**）。
>
> 落地见 `server/src/ai_risk.cj`（文件头注释写明了三条决定）、`api-design.md` §7.5、
> 以及客户端 `PendingRisk` 角标（前端只做呈现）。
> 另：模型给的分档**若没有 `reasons` 一律不采信**，回落规则兜底 ——
> 一个没有依据的「高风险」比不报还糟。

### 3.6 错误码（`docs/api-design.md` §1.3 新增）

| code | HTTP | 场景 |
|---|---|---|
| `AI_RATE_LIMITED` | 429 | 成员级智能调用节流（防刷、防费用失控） |

> **不需要**给「模型不可用」加错误码——它走 `data.source` 降级，HTTP 仍是 200。
> 这与本项目「HTTP 状态码给网络层、`error.code` 给业务层」的口径一致。

---

## 4. 实现要点（按依赖顺序）

### 第 1 步：`ai_config.cj` —— 配置与客户端工厂

产出 `AiOptions`（§2）+ 一个 `newAiClient(opts): ?OutboundClient`（未配置时返回 `None`）。
**未配置必须是一等公民**：`None` 时所有 handler 直接回 `source="none"`，不报错。

### 第 2 步：`ai_client.cj` —— 把框架能力包成业务语义

职责三件：

1. **调模型**：`client.postJson(endpoint, body, headers)`。密钥从文件读，塞进 `Authorization` 头
2. **归一化 + 校验**：`extractJson` → `JsonValue.fromStr` → `JsonSchema.validate`
   —— 校验失败**重试 1 次**，仍失败即降级（spec §5.5 D5：**禁止把幻觉写进 MySQL**）
3. **降级与审计**：无论成败都写审计（`elapsedMs` / `outcome` / `source`）；**绝不记密钥与完整 prompt**

### 第 3 步：`ai_schema.cj` —— schema 与提示词

每个功能一组 `JsonSchema` + 提示词模板。schema 要**一次收集全部错误**（框架的 `validate` 已如此）。

### 第 4 步：`h_ai.cj` —— 4 个 handler

每个 handler 的形状固定为「**取数 → 调模型（锁外）→ 回锁写**」三段式（spec §6.4）：

```cangjie
func handleTaskSuggest(ctx: Context, s: Store): Unit {
    let actor = requireMember(ctx, s)              // 401/403 由既有机制处理
    let body  = ctx.bodyJson()                      // 既有闸门已挡非法/超大请求体
    let title = jsonStr(body, "title")
    /* ① 锁内：只取数，立刻出锁 */
    let snapshot = s.readForAi(title, ...)
    /* ② 锁外：慢调用（可与其他请求重叠）+ 信号量限流 */
    let sug = aiClient.suggestTask(snapshot)        // 内部已含降级
    /* ③ 写审计（锁外） */
    auditAi(actor, "task_suggest", sug.source, sug.elapsedMs)
    respondOk(ctx, sug.toJson())                    // 无论如何 200
}
```

⚠ **`Store` 的锁之内禁止出现任何出站调用**——已实测：锁内做 I/O 会把并发彻底串行化
（4×2s：8088 ms vs 锁外 2034 ms）。命名约定：凡以 `Locked` 结尾的函数，评审时一律查其调用链。

### 第 5 步：`main.cj` 注册路由

沿用既有 fluent 链，插到 Part 4 之后：

```cangjie
.post("/api/v1/ai/task-suggest", { ctx: Context, _: () -> Unit => handleTaskSuggest(ctx, s) })
.post("/api/v1/ai/notice-draft", { ctx: Context, _: () -> Unit => handleNoticeDraft(ctx, s) })
.post("/api/v1/ai/retrospective", { ctx: Context, _: () -> Unit => handleRetrospective(ctx, s) })
.post("/api/v1/ai/ask",          { ctx: Context, _: () -> Unit => handleAiAsk(ctx, s) })
```

### 第 6 步（P1）：工具调用与 `can()` 收敛

智能体可调既有 40 个接口，但：

```cangjie
/* 全模块唯一允许执行「模型产生的动作」的入口；内部必须调用 can() */
public func dispatchAiTool(actor: Member, tool: String, args: HashMap<String, String>): ToolResult
```

硬要求：工具白名单是**静态表**（模型不能新增工具）· 参数当不可信输入走 `limits.cj` ·
循环上限 4 轮 · **denied 必须写审计** · 权限只用 `can()`（spec §5.6 T1–T6）。

**架构叙事**（答辩主线）：**智能体不能绕过权限系统**——模型只是"提议"，能否执行由 `can()` 决定。

---

## 5. 与既有代码的衔接点（照着接，别另起炉灶）

| 衔接对象 | 怎么接 |
|---|---|
| 鉴权 / 角色 | 复用 `auth.cj` + handler 里既有的 `requireMember` 一类入口 |
| 权限 | **只用** `perms.cj` 的 `can(member, action, target)` |
| 请求体闸门 | 复用 `limits.cj`（64 KiB、类型白名单、非 UTF-8 → 400 `INVALID_JSON`） |
| 响应信封 | 复用 `jsonw.cj` 的 `respondOk` / 错误包装 |
| 错误码 | 改 `errors.cj` 的 `errorSpec()`；**先改 `api-design.md` §1.3** |
| 审计 | 复用 `audit.cj`（写盘在锁外，见 N-17） |
| 时间 | 复用 `timex.cj`（epoch → ISO8601+08:00），别自己格式化 |
| 派生量 | 复用 `views.cj` 的 `overdue_days` / `is_overdue` / 课题进度聚合 |

---

## 6. 测试与验收

### 6.1 单测（`server/src/tests.cj`，**不联网**）

用框架的 `MockTransport` 驱动 `OutboundClient`，全程离线。必测 U1–U12 见 spec §10.2，
其中前 5 条直接来自已跑过的 spike（回归闸门）：合法 / 围栏 / 带话术 / 截断 / 字符串内含花括号。

### 6.2 端到端（`server/tests/ai-check.ps1` + `ai-e2e.ps1` + `ai-stub.mjs`）

**已落地** —— `spike/llm-http/stub.mjs` 已收编成 `server/tests/ai-stub.mjs` 并按 AI 语义扩写：

- `ai-stub.mjs` 实际模式：`ok`（合法）/ `garbage`（非 JSON 话术）/ `fenced`（代码围栏包裹）/
  `e500` / `e401` / `slow`（睡 5 s，验超时）。
  ⚠ **没有 429 分支** —— 要验"429 可重试"得先补桩；`slow` 目前也没有任何用例调用。
- `ai-check.ps1`：配置与 CLI 类断言（参数被接受、空密钥判未配置、URL userinfo 不入日志）
  + 引用 `spike/llm-truncation/` 的**短读**探针。
- `ai-e2e.ps1`：真库 + 真服务 + 真 HTTP 的端到端联调（含成员级节流的 429 与"非法 JSON → 降级"）。

判据沿用本项目口径：**`FAIL 0`**。

> ⚠ **当前状态（2026-10-05 第二轮复验）：两套脚本在本机都还跑不到 `FAIL 0`。**
> `ai-check.ps1` 报 `PASS 3 / FAIL 2`（服务进程活着被强杀 → 块缓冲的 stdout 丢失，而三条断言在空日志上恒真）；
> `ai-e2e.ps1` 先在 `Test-NetConnection`、后在缺 `--skip-ssl` 的客户端调用处中止。
> 逐条证据与修法见 `docs/ai-module-review.md` §9.2 的 **R-2 / R-3**。

### 6.3 手工验收

1. 删掉 CA → 启动打印可照做的提示，**服务仍能起**，AI 标记为未配置
2. endpoint 改错 → 智能接口返回 **200 + `source` 非 model**，**不返回 5xx**
3. 并发 4 个「起草通知」→ 总耗时 ≈ 单次耗时（**不是 4 倍**）——锁外 I/O 的回归闸门
4. 全仓 grep 审计/日志输出，确认**无密钥泄漏**

---

## 7. 已知坑（实现时必看）

| # | 坑 | 处置 |
|---|---|---|
| 1 | 缺 `import stdx.net.tls.*` | 运行时 `Global TLS kit is not set` |
| 2 | 缺 OpenSSL 两个 DLL | 运行时 `Can not load openssl library or function CRYPTO_get_ex_new_index` |
| 3 | **Windows** 上用 `Default` 校验 | 必然 `unknown CA` → 用 `CustomCA`（Linux 实测 Default 可用，见 §2.2） |
| 4 | 没 `.noProxy()` | 回环地址被系统代理拦成 `502 upstream connect failed` |
| 5 | `OutboundClient` 的限流是**阻塞** `acquire()` | 想要「过载即降级」需自己包一层 `tryAcquire` + ≤500 ms 等待（框架侧已作为 **E-1** 反馈上游） |
| 6 | 超时读/写共用一个值 | 大模型首字节慢，必要时自建薄封装（**E-2**） |
| 7 | logger 未暴露 → 超时刷 stdout | 见 **E-3**；暂时接受，或自建封装 |
| 8 | 与轻舟同包顶层重名 | 加 `ai`/`Ai` 前缀；先查 `docs/API-NOTES.md` |
| 9 | 含中文的新 `.ps1` | 必须存成 **UTF-8 with BOM**（PS 5.1 否则按 GBK 解码吞代码） |

---

## 8. 建议排期

| 步 | 内容 | 出口 |
|---|---|---|
| 1 | 改 `api-design.md`（5 接口 + 1 错误码） | 文档定稿，团队对齐契约 |
| 2 | `ai_config` + `ai_client` + `ai_schema` | 单测 U1–U6/U8–U12 全绿（离线） |
| 3 | `h_ai.cj` 4 个 handler + 路由 | `ai-check.ps1` FAIL 0；能真实调通一个公网 HTTPS 端点 |
| 4 | 部署包带 CA + 密钥模板；`local-deploy.md` 补章节 | 手工验收 1–4 通过 |
| 5 | （P1）`dispatchAiTool` + 权限收敛 | denied 路径有测试；权限只走 `can()` |

> 第 3 步做完即可与客户端联调——**前端可以先对接 `source="none"` / `"fallback"` 的通路**，
> 不必等真模型接入。
