# 客户端接入 AI 能力 · 落地指南

> 📁 **AI 客户端接入指南** ｜ 本文件：`llm-frontend-guide.md` ｜ [全部文档目录](README.md)

> **定位**：本文写客户端（鸿蒙 ArkTS，`entry/`）怎么接服务端的 5 个智能接口。
> 服务端侧的接口定义与实现见 `docs/llm-backend-guide.md`（契约以那里为准）。
>
> **前置（2026-10-05 更新）**：服务端 `/api/v1/ai/*` **已实现** —— `server/src/h_ai.cj`
> （4 个 handler）+ `main.cj` 已注册 4 条路由。**端到端联调已跑通且全绿**：
> `server/tests/ai-e2e.ps1`（真库 + 真服务 + 真 HTTP）**PASS 71 / FAIL 0**，
> `server/tests/ai-check.ps1`（不需要 MySQL）**PASS 5 / FAIL 0**。
> 审查报告 §9.2 的 R-2「本机必假红」与 R-3「一条断言都跑不出」**均已修**；
> 节流闸门已改为**确定性**的顺序快打（恰好 20 通过 + 5×429）。
> 前端可按 `source` 三分支先接，不必等联调完成；真模型接入后再验 `"model"` 分支即可并行推进。
>
> **当前客户端事实**：21 个页面 · 6 个 API 模块（`api/`）· 7 个 store（`store/`）·
> `HttpClient` 单例统一处理鉴权头与 401/403。

---

## 1. 核心设计：三种来源，三种呈现

服务端**永不**因模型故障返回 5xx，而是用 `data.source` 表达降级（见后端文档 §3.0）。
客户端必须把这三态**呈现得不一样**——这是评审"看得到"的部分，也是防止误导用户的关键。

| `source` | 含义 | 呈现规则 |
|---|---|---|
| `model` | 模型给出的 | 正常卡片，角标明示「AI 建议」 |
| `fallback` | 模型不可用，退回规则/历史统计 | **照常展示**，但标注「依据历史数据」并**弱化样式**（灰底/次要色），**不得**让用户误以为是大模型给的 |
| `none` | 连兜底都没有 | 卡片位**留一句「智能建议暂不可用」**，不放骨架、不留空白；功能本身照常可用。**⚠ 服务端目前不会发 `none`** —— 模型不可用（含 **AI 未配置**）时一律有规则兜底，走 `fallback`；这一支保留为契约第三态 |

三条硬规则：

1. **AI 只是建议，不是阻塞**：三种情况都不能挡住主流程（创建任务、看详情照常）
2. **`source` 必须透传到 UI**：禁止在 API 层把它吃掉、只留下业务字段
3. **不显示"加载中"超过预算**：超时（建议 20 s）就按 `none` 处理，见 §4

---

## 2. 新增一个 API 模块

**新建 `entry/src/main/ets/api/AiApi.ets`**，与既有 6 个模块并列，照它们的范式写
（`TaskApi.ets` 是最接近的样板）：

```ts
import { HttpClient, ApiResponse } from './HttpClient';
import type { MemberBrief } from './AuthApi';

/** 智能结果的来源标记（服务端 data.source） */
export type AiSource = 'model' | 'fallback' | 'none';

interface AiEnvelope {
  source: AiSource;
  note?: string;
}

export interface TaskSuggestion extends AiEnvelope {
  owner: MemberBrief | null;
  due_at: string | null;          // ISO 8601 带时区，与既有接口口径一致
  granularity: string | null;
  reasons: string[];
}

export interface NoticeDraft extends AiEnvelope {
  title: string;
  body: string;
  audience: string;
  suggest_send_at: string | null;
}

export interface RetroCause { kind: string; detail: string; }

export interface Retrospective extends AiEnvelope {
  summary: string;
  overdue: { is_overdue: boolean; days: number; causes: RetroCause[] };
  suggestions: string[];
}

export interface AskBasis { kind: string; ref: string; }

export interface AskAnswer extends AiEnvelope {
  answer: string;
  basis: AskBasis[];
}

export class AiApi {
  private client: HttpClient = HttpClient.getInstance();

  /** POST /api/v1/ai/task-suggest */
  async taskSuggest(data: { title: string; desc?: string; plan_id?: number; dept_id?: number })
      : Promise<ApiResponse<TaskSuggestion>> {
    // ⚠ 第三个参数【不传】outbox —— 智能调用不进离线队列，见 §6
    return this.client.post<TaskSuggestion>('/ai/task-suggest', data);
  }

  /** POST /api/v1/ai/notice-draft */
  async noticeDraft(taskId: number, audience: string): Promise<ApiResponse<NoticeDraft>> {
    return this.client.post<NoticeDraft>('/ai/notice-draft', { task_id: taskId, audience });
  }

  /** POST /api/v1/ai/retrospective —— taskId 与 planId 二选一 */
  async retrospective(p: { taskId?: number; planId?: number }): Promise<ApiResponse<Retrospective>> {
    const body: Record<string, number> = {};
    if (p.taskId !== undefined) body.task_id = p.taskId;
    if (p.planId !== undefined) body.plan_id = p.planId;
    return this.client.post<Retrospective>('/ai/retrospective', body);
  }

  /** POST /api/v1/ai/ask */
  async ask(question: string): Promise<ApiResponse<AskAnswer>> {
    return this.client.post<AskAnswer>('/ai/ask', { question });
  }
}
```

> `HttpClient` 已有 `get/post/patch/put/delete_`，签名是
> `post<T>(path, body?, outbox?)`。**不传 `outbox` 就不会进离线队列**（源码已确认）。

**建议再抽一个展示组件** `entry/src/main/ets/components/AiCard.ets`，
统一渲染「角标 + 内容 + 依据 + 三态样式」，避免每个页面各写一遍。

---

## 3. 页面改动清单

| 页面（`entry/src/main/ets/pages/`） | 放什么 | 交互 |
|---|---|---|
| `CreateTaskPage.ets` | 标题/描述填写后出现**「智能建议」卡片**：建议负责人、建议截止时间、拆分建议、依据列表 | 默认**折叠**；点「采用」把建议填进表单字段（可再改）；点「忽略」永久收起本次 |
| `TaskDetailPage.ets` | ①「起草通知」按钮 → 弹出**通知草稿**（可编辑、可一键复制）②「成效与延期」区块（含归因与改进建议） | 草稿**只是文本**，不要做"发送"按钮——服务端目前没有任何通知/推送能力 |
| `PendingApprovalPage.ets` | 待审批条目旁的**风险徽章**（低/中/高 + 悬停/点开的理由） | 高风险条目在人工审批时高亮；**不改变既有审批流程** |
| `ProfilePage.ets` 或 `Index.ets` | 「问一问」入口 → **新增 `AskPage.ets`**：权限感知问答 | 回答下方必须展示 `basis`（依据），让用户知道答案从哪来 |
| `MyTasksPage.ets` | **不动** | 首页是"我的任务"，主动弹 AI 会干扰；最多在无任务时给一句引导文案 |

**不建议**在 `TaskListPage` / `MemberListPage` 里加 AI——列表页要快，智能调用是秒级操作。

### 3.1 字段映射注意（接真接口时最容易错）

- 服务端一律 **snake_case**（`due_at` / `suggest_send_at` / `plan_id`），与既有契约一致
- 人用 `MemberBrief`（**不含手机号**），需要展示人时复用 `MemberCard` 组件
- 时间用 ISO 8601 带时区，**展示前**走既有 `util/DateFmt.ets`，别自己 `new Date()`

---

## 4. 加载态、超时与取消

智能调用是**秒级**操作，必须处理"用户等不了"和"用户走了"：

| 场景 | 要求 |
|---|---|
| 请求中 | 卡片内联 loading（**不要**全屏遮罩，别挡住主流程） |
| 超时 | 客户端 20 s 上限，到点按 `source = "none"` 呈现；服务端也有自己的预算 |
| 离开页面 | `aboutToDisappear()` 里**丢弃回填**（用一个 `isActive` 标志位或请求序号），避免对已销毁页面赋值 |
| 重复点击 | 按钮置灰 + in-flight 去重，别让用户连点打出 5 次模型调用（服务端有节流，但客户端也该挡） |
| 重试 | 只给**手动**「重试」按钮，**不要**自动重试——智能调用有费用，且自动重试会放大故障 |

> 客户端**没有**现成的请求取消机制（`HttpClient` 是 `http.createHttp()` 直发）。
> 所以用「丢弃回填」而不是真取消；如果后续要做真取消，需要扩 `HttpClient`，属独立改动。

---

## 5. 错误处理与权限

### 5.1 错误

- `401` / `403`：**复用 `HttpClient` 既有处理**，不要在 AiApi 里另写一套
- `AI_RATE_LIMITED`（429，新增错误码）：文案「操作过于频繁，请稍后再试」
- 其他错误码：`HttpClient.ets` 已有一张 `friendlyMessage` 映射表，**往那张表里加**，别新开分支
- **模型故障不是错误**：`ok: true` + `source != "model"`，走 §1 的降级呈现，**不要弹 toast**

### 5.2 权限

- AI 按钮/入口按 `store/PermissionStore.ets` 的既有布尔值**隐藏或置灰**
  （如「起草通知」需要能读该任务；「问一问」任何登录成员可用）
- ⚠ 客户端隐藏只是体验优化，**服务端 `can()` 才是最终判定**——不要因为前端藏了按钮就以为安全
- `source` 与权限**是两件事**：403 是真的没权限，`source != "model"` 是模型不可用/降级，别混
  ⚠ **AI 未配置时服务端发的是 `fallback`（带着规则兜底），不再是 `none`** —— 见 §10 与 `api-design.md` §7 的实现状态

---

## 6. 两条客户端纪律

### 6.1 智能调用**不进 Outbox**

`store/OutboxStore.ets` + `OutboxSync.ets` 是**离线队列**，用于「网络恢复后补发**幂等写操作**」
（如新建任务）。智能调用是**读语义的建议**：

- 离线时补发毫无意义（用户早就走开了）
- 会让队列里混入非幂等、且**有费用**的请求

做法：`AiApi` 里**不传** `post` 的第三个参数（`outbox`）。见 §2 代码注释。

### 6.2 不要把敏感信息塞进请求

- 请求体**不要**带手机号、口令、token 之类（`MemberBrief` 本来就不含手机号，别绕过它）
- 客户端**不得**直连大模型 API（密钥会随 HAP 泄露）——一律经自己的服务端
- 服务端审计只记长度/摘要，客户端日志同理：**不要**把整段 prompt 打到 hilog

---

## 7. 联调顺序（可与服务端并行）

| 步 | 做什么 | 依赖 |
|---|---|---|
| 1 | 建 `AiApi.ets` + `AiCard.ets`，**先接 mock**（本地返回三态各一份） | 无 |
| 2 | 接入 4 个页面/新增 `AskPage`，把三态呈现跑通 | 步 1 |
| 3 | 服务端上线后，改指向真接口，验 `source="fallback"` 分支 | 服务端 `h_ai.cj` |
| 4 | 服务端接真模型后，验 `source="model"` 分支 + `none` 分支 | 服务端配置 AI 端点 |

> 服务端第 3 步（见后端文档 §8）做完就能联调，**不必等真模型**。

---

## 8. 验收清单

- [ ] `source="model"` 时角标显示「AI 建议」，`fallback` 时显示「依据历史数据」，
      本地初始态 `none` 时显示「暂不可用」
      > ⚠ **服务端只会发 `model` / `fallback` 两个值**（2026-10-06 核实：R-8 之后 AI 未配置
      > 也走 `fallback` + 有内容的规则兜底）。客户端类型里的 `none` 是**自己的初始/不可用态**，
      > 不会被服务端返回 —— 但**保留它是正确的**（请求还没回来时就是"无结果"）。
- [ ] 三种情况下**创建任务 / 看详情的主流程都不被阻塞**
- [ ] 服务端返回 200 + `source="fallback"`（**含 AI 未配置**）时，**界面不弹错、不留白骨架**
- [ ] 20 s 超时后按 `none` 呈现，且**页面无残留 loading**
- [ ] 请求中途返回/离开页面，**不对已销毁页面赋值**（无 `undefined` 报错）
- [ ] 连续点击只发出一次请求
- [ ] 关掉服务端 AI 配置后，其余功能**全部照常可用**
- [ ] 断网时智能调用**不进入 Outbox**（可在 `OutboxStore` 里断言为空）
- [ ] hilog 中**无 prompt 全文、无 token**

---

## 9. 三个 UX 决策 —— **已拍板（2026-10-06，前端同学确认）**

| # | 决策 | 结论 | 理由（前端同学给的原话摘要） |
|---|---|---|---|
| 1 | 创建任务页的建议卡片 | **默认折叠** | `CreateTaskPage` 是**表单填写流**，标题/描述一填完就自动弹开 AI 卡片会把表单顶下去、**打断填写节奏**。折叠态保留一个「**AI 建议 · N 条**」的紧凑提示，点开才看内容；**别折到完全看不见** |
| 2 | 「采用建议」的粒度 | **逐字段采用 + 顶部「全部采用」** | `TaskSuggestion` 是 4 个独立字段（负责人 / 截止 / 拆分 / 依据），用户常常**只想采纳截止时间、保留自己选的负责人**；纯整块采用太粗，会逼用户「要么全要要么全不要」 |
| 3 | 「问一问」入口位置 | **「我的」页**（`ProfilePage` 的 settings 卡片附近） | 它是**低频**问答助手；首页（我的任务）要保持专注、不能塞，放首页顶部会干扰主流程。一行入口 `pushTo('pages/AskPage')`，对设计稿冲击最小 |

> **服务端不需要任何改动** —— 三条都是纯客户端的呈现 / 交互决策，接口契约不变。
>
> 但实现时有**两个来自服务端的提醒**（依据见 §10 的实现事实）：
>
> 1. 决策 1 的「**N 条**」计数并非四个接口都有：`task-suggest` 是 `reasons.length`、
>    `retrospective` 是 `suggestions.length`；而 `notice-draft`（标题 + 正文）与 `ask`（一段回答）
>    **没有"条数"概念** —— 这两个折叠态用固定文案即可，别硬凑一个数字。
> 2. 决策 2 的「负责人」字段要取 `owner.id`，而 **`owner` 可能为 `null`**
>    （模型编出来的 id 会被服务端丢弃，见 §10.1）—— 该字段的「采用」按钮在 `owner == null` 时要**置灰**。

---

## 10. 附录：四种响应的**确切形状**（照这个写解析，别猜）

> 以下取自 `server/src/h_ai.cj` 的**实际实现**（2026-10-06）。
> 信封沿用既有契约：成功 `{ ok: true, data: {…} }`；失败 `{ ok: false, error: { code, message, fields } }`。
>
> **五个接口一律 `POST` + `Content-Type: application/json` + `Authorization: Bearer <token>`**
> （都要登录；token 复用 `HttpClient` 既有的）。请求体只需给下面列出的字段，其余可选。

### 10.1 `POST /api/v1/ai/task-suggest`　请求：`{ "title": "…", "desc"?, "plan_id"?, "dept_id"? }`

```jsonc
{ "ok": true, "data": {
    "owner": { "id": 7, "name": "张三", "dept": { "id": 2, "name": "宣传部" } },  // MemberBrief 或 null
    "due_at": "2026-10-20T18:00:00+08:00",   // ISO 8601 带时区；模型给的不合规会被**丢弃成 null**
    "granularity": "建议拆成 2—3 个子任务",     // 或 null
    "reasons": ["…"],                        // 字符串数组，可能为空数组
    "source": "model",                       // model | fallback
    "note": "…"                              // 仅 source != "model" 时出现
} }
```

⚠ `owner` 是**对象**，不是扁平的 `owner_id` / `owner_name`（早期版本曾是扁平字段）。
⚠ 服务端只在**候选名单**里挑人；模型编出来的 id 会被丢弃 → `owner` 为 `null`。前端要能处理 null。

### 10.2 `POST /api/v1/ai/notice-draft`　请求：`{ "task_id": 123, "audience"?: "members"|"leads"|"all" }`

```jsonc
{ "ok": true, "data": {
    "title": "关于…的通知",
    "body": "各位成员：\n\n…",
    "audience": "members",                   // **一律回填请求里的值**，不用模型给的
    "suggest_send_at": "2026-10-16T09:00:00+08:00",  // 或 null（不合规会丢弃）
    "source": "model",
    "note": "…"
} }
```

### 10.3 `POST /api/v1/ai/retrospective`　请求：`{ "task_id": 123 }` **或** `{ "plan_id": 45 }`（二选一）

```jsonc
{ "ok": true, "data": {
    "summary": "…",
    "overdue": {
        "is_overdue": true,
        "days": 2,                           // **服务端自己算的**，与列表页口径一致（本地日界）
        "causes": [ { "kind": "dependency", "detail": "dependency: 等待物料交付" } ]
    },                                       // kind ∈ dependency|overload|granularity|scope_drift|external|unknown
    "suggestions": ["…"],
    "source": "model",
    "note": "…"
} }
```

⚠ `overdue.is_overdue` / `days` **永远来自服务端派生量**，不是模型说的——所以它一定和任务列表页一致，前端别自己再算一遍。

### 10.4 `POST /api/v1/ai/ask`　请求：`{ "question": "我能重置成员口令吗？" }`

```jsonc
{ "ok": true, "data": {
    "answer": "根据系统判定，你当前的权限是（判定基于「你本人」与「本部门普通成员」两种代表性目标）：\n- …",
    "basis": [ { "kind": "permission", "ref": "can() 的系统判定结果" } ],   // kind ∈ permission|data|doc
    "source": "fallback",
    "note": "智能服务暂时不可用，以下依据历史数据给出"
} }
```

⚠ `answer` 里的权限清单**由服务端用 `can()` 算好再交给模型润色**（模型不生成权限结论）。
服务端未配 AI 时，`answer` 仍是这份清单本身——所以这个接口**在没配 AI 时也有用**，别把它当纯装饰。

### 10.5 客户端必须处理的非 2xx

| 状态 | `error.code` | 场景 | 客户端该做什么 |
|---|---|---|---|
| **429** | `AI_RATE_LIMITED` | 本成员 60 秒内智能调用超过 20 次 | 提示「操作过于频繁，请稍后再试」；**不要自动重试**（会继续吃配额） |
| 400 | `VALIDATION_FAILED` | `title` / `question` 为空或超长、`plan_id` 为负 | 走既有表单校验提示；`error.fields` 里有字段名 |
| 403 | `FORBIDDEN_ROLE` / `FORBIDDEN_NOT_IN_DEPT` | 对该任务 / 课题无权限 | 走既有 403 处理 |
| 404 | `TASK_NOT_FOUND` / `PLAN_NOT_FOUND` | 引用的对象不存在 | 提示对象已删除并刷新 |

> **不会有 5xx**：模型超时 / 上游 4xx-5xx / 网络不通 / 输出不是合法 JSON —— 服务端**一律**返回 200 并降级为
> `source = "fallback"`（带 `note`）。所以前端**不要**为「模型服务出错」写 toast 或错误页。

### 10.6 `note` 的取值（前端可以直接展示，也可自行改写）

| 触发 | `note` |
|---|---|
| 超时 | 智能建议超时，以下依据历史数据给出 |
| 服务端并发已满 | 当前智能请求较多，以下依据历史数据给出 |
| 429 / 5xx / 网络不通 | 智能服务暂时不可用，以下依据历史数据给出 |
| 上游返回 4xx | 智能服务返回异常，以下依据历史数据给出 |
| 提示词超过服务端上限 | 本次请求内容过长，已改用规则建议 |
| 模型输出被 token 上限截断 | 回答被长度上限截断，建议缩小问题范围或调大 `--ai-max-tokens` |
| 输出不是合法 JSON（重试后仍不行） | 智能建议暂时不可用，以下依据历史数据给出 |
| **服务端未配置 AI** | 「智能建议 / 起草 / 归因 / 问答」暂不可用（AI 未配置）—— 按功能用词不同 |
---

### 10.7 `POST /api/v1/ai/agent`（智能体：工具循环，**只读**）

请求：`{ "question": "本部门这周有几条逾期任务？" }`

```jsonc
{ "ok": true, "data": {
    "answer": "本部门本周有 3 条逾期任务：…",
    "steps": [
      { "tool": "list_dept_open_tasks", "allowed": true,  "summary": "12 条", "payload": "…" },
      { "tool": "list_pending_members", "allowed": false, "summary": "权限不足", "payload": "…" }
    ],
    "rounds": 2,          // 实际用了几轮
    "calls": 3,           // 实际向模型发了几次 POST（**费用可见**）
    "basis": [            // ★ 对象数组 [{kind, ref}]，**两条路径同形状**（见下方第 4 点）
      { "kind": "permission", "ref": "can() 的系统判定结果" },
      { "kind": "data",       "ref": "工具查询结果（见 steps）" }
    ],
    "source": "model",    // model | fallback
    "note": ""
} }
```

**与 §10.4 `ask` 的区别**：`ask` 只能回答「系统已经知道的事」（权限、规则）；
`agent` 能**先查数据再回答**。所以「有多少 / 哪些」这类问题要用 `agent`。

**前端必须注意的四点：**

1. **`calls` 可能是 1~4**（一次请求最多 4 轮模型调用）—— 所以它**明显比 `ask` 慢**。
   客户端超时预算要放宽（建议 **25 s**；服务端自己的总预算是 20 s），
   且 loading 文案建议区分「正在查询…」而不是笼统的「思考中」。
2. **`steps` 是「查了什么」**，可以渲染成一条折叠的时间线。
   `allowed=false` 的步骤显示成「无权限访问」，但**不要弹错误** —— 那是**正常降级路径**，
   不是失败（模型试了一个它没权限的工具，服务端拒绝了，然后它会换一个或直接回答）。
3. **`source="fallback"` 时 `answer` 仍然有内容** —— 服务端会把**已经查到的数据**直接拼成回答
   （兜底不为空）。照常展示、只把角标换成「依据历史数据」即可，**不要**因为不是 `model` 就丢掉 `answer`。
4. **`basis` 只有一种形状：对象数组 `[{kind, ref}]`**（`kind ∈ permission / data / doc`），
   **与 `source` 是 `model` 还是 `fallback` 无关** —— 按 §10.4 的同一套解析即可。
   > 📌 **2026-10-06 修（前端报障）**：此前**模型路径返回的是字符串数组**
   > （`["permission: …", "data: …"]`），而**降级路径是对象数组** ⇒ 同一个字段、
   > 同一份 `source=fallback`，形状却取决于「AI 配没配」，客户端没法可靠消费。
   > 已修正，并在 `tests\ai-e2e.ps1` 对 `agent` / `agentloop` / `agentbad` 三条剧本各加了断言。
   > **之前为此写的绕行/不消费逻辑可以撤掉了。**

> ⚠ **写操作需要二次确认**（P2 起）：`steps` 里的**只读**工具不产生任何副作用；
> 但若响应里出现 **`proposal`**，表示模型提出了一个**写操作**（例如改任务状态），
> **此时还没有落库** —— 必须由用户在界面上确认后，调 §10.8 的 `/ai/agent/confirm` 才会执行。
> 提议带 `token`（5 分钟有效、一次性、绑当前用户）与**服务端算出的 `diff`**，确认页请展示 `diff`。

**工具白名单**（6 个：**5 个只读 + 1 个写**）：`list_my_tasks` · `task_detail` · `dept_stats` ·
`list_dept_open_tasks` · `list_pending_members` · **`set_my_task_status`（写，L1）**。
前端**不需要**知道这些名字 —— 它们只出现在 `steps[].tool` 里，仅供展示。

---

### 10.8 `POST /api/v1/ai/agent/confirm`（**写操作**：确认并执行）

**这是唯一会真正改数据的 AI 接口**，也是最需要前端配合做对的：

```jsonc
// 请求
{ "token": "ap_7f3c9e12…" }        // 来自 10.7 的 data.proposal.token

// 成功
{ "ok": true, "data": {
    "tool": "set_my_task_status",
    "resource_id": 501,
    "summary": "已把「招新物料」的状态改为 done"
} }
```

**前端必读的四条：**

1. **`proposal` 是"待确认"，不是"已完成"。**
   `/ai/agent` 返回 `proposal` 时，`answer` 只是"我准备做一个改动，需要你确认后才会生效"。
   **在用户点确认、且 confirm 返回 200 之前，界面上不能显示成"已完成"**。

2. **要展示 `proposal.diff`，不要只展示 `answer`。**
   `diff` 是**服务端算出来的** from→to（如 `status: todo → done`），
   而 `answer` 只是模型的一句话。用户确认的必须是前者 —— 这是防"模型说的和实际做的不一致"。

3. **这四种失败都要能显示，且语义不同：**

   | HTTP | `error.code` | 界面该怎么表现 |
   |---|---|---|
   | 409 | `AI_PROPOSAL_USED` | **"这个操作已经执行过了"** —— 可能是用户重复点了确认；**不要**提示成错误，刷新一下状态即可 |
   | 410 | `AI_PROPOSAL_EXPIRED` | "确认超时（5 分钟），请重新让助手操作" + 提供重新生成的入口 |
   | 404 | `AI_PROPOSAL_NOT_FOUND` | 令牌无效（换账号、重启等）→ 同上，重新生成 |
   | 409 | `AI_PROPOSAL_EXEC_FAILED` | **业务规则拒绝**（如进入"阻塞"却没填原因）→ 把 `error.message` 显示出来 |
   
   > ⚠ **它与 10.1~10.4 的降级语义完全不同**：那些接口"模型挂了也返回 200 + fallback"，
   > 而 confirm 的失败**必须显式展示** —— 用户得知道**没写成**。

4. **`AI_PROPOSAL_EXEC_FAILED` 之后，同一个令牌**还能再用。
   服务端在执行业务规则被拒时**不标记已消费**（因为没有副作用发生）。
   所以你可以让用户改完条件（例如补上阻塞原因）后**重试同一个令牌**，
   而不必重新走一遍 `/ai/agent`。令牌仍会在 5 分钟后过期。

**确认按钮的建议文案**：不要写"确定"，写清动作本身，例如
「确认把「招新物料」的状态改为 done」—— 让用户在点之前就知道会发生什么。

**不需要二次输入密码**：令牌已经绑定到当前登录用户（换账号用不了），
且只能做一次。再叠一层验证会把体验搞重，收益很小。
