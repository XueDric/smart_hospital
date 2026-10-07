# AI 模块审查报告（Part 7 · 4 个智能接口）

> 📁 **AI 模块审查报告（三轮）** ｜ 本文件：`ai-module-review.md` ｜ [全部文档目录](README.md)

> **谁该读**：动 `server/src/ai_client.cj` / `ai_config.cj` / `ai_schema.cj` / `h_ai.cj`、或改
> `docs/llm-*.md` / `api-design.md` Part 7 的人；以及要验收 Part 7 的人。
> **怎么读**：§0 是一句话结论与速览表；§2 是逐条缺陷（含现象 / 证据 / 触发 / 修法）；§6 是复现命令。
>
> **方法与边界（2026-10-05）**：**只读审计 + 一次实测复现**，**未改动任何产品代码**
> （审查期间 `git status` 没有新增改动；实验用的 stub 与脚本放在 gitignore 的 `server/build/`，事后已删净，
> 探针库已 DROP）。每条缺陷都标了**验证方式**：
> `[实测]`＝我在本机跑出来的；`[读码]`＝逐行读过两侧代码；`[grep]`＝全仓检索确认存在/不存在。
>
> **判缺陷的口径来源**（先读它们，避免把有意设计当 bug）：
> `docs/api-design.md` **Part 7**（该部分自称"`/api/v1/ai/*` 的唯一权威"）、`docs/llm-backend-guide.md`、
> `docs/llm-client-spec.md`、`docs/llm-frontend-guide.md`；以及本仓既有纪律：
> **`can()` 是唯一权限入口**、`s.lock` 保护 Store、`limits.cj` 统一长度上限、
> **审计必须在锁内调用**、每个修复都要有"回退即变红"的断言。
>
> ## ⚠ 状态（2026-10-05 晚追加）
>
> **本报告 §0–§8 记录的是"修复前"的状态。** 其中三条结论**已不再成立**：
> §0「这个功能现在一台机器上也启用不了」、AI-6「没有任何成员级节流」、AI-7「零测试」。
> 修复已由 6 个提交完成（`e2d33f5` → `40d1d2f`）。
> **当前状态与第二轮复验结论以 §9 为准**；§8 的「本轮新发现且未修：AI-1 ~ AI-17」也已过时。

---

## 0. 结论速览

**认证与授权是对的，密钥处理也是对的；但这个功能现在一台机器上也启用不了，而且没有任何节流、没有任何测试。**

| # | 级别 | 问题 | 验证 |
| --- | --- | --- | --- |
| **AI-1** | **P0** | **所有 `--ai-*` 参数被 CLI 白名单拒绝**：配 AI 会让 `serve` 直接退出，因此 4 个接口**永远**返回 `source:"none"` | **[实测]** + [读码] |
| AI-2 | P1 | 出站响应**短读即当 EOF** → 约 4 KB 以上的模型回答被截断，静默降级为 `fallback` | [读码]（机制确定，未活复现） |
| AI-3 | P1 | `aiAudit` 在 `s.lock` **之外**追加审计缓冲 → 与刷盘竞争，**审计行会丢** | [读码] |
| AI-4 | P1 | 逾期天数用 24 小时取整，**与 `views.cj` 的本地日界口径不一致** → AI 说 1 天、列表页说 2 天 | [读码] |
| AI-5 | P1 | `plan_id` **读了不用** —— 文档承诺的"参考该课题历史任务"根本没接 | [读码] |
| AI-6 | P1 | **没有任何成员级节流**；`AI_RATE_LIMITED`(429) 是死码 —— 与文档承诺相反，**费用可被无限刷** | [grep] |
| AI-7 | P1 | **零测试**：guide 要求的 `tests/ai-check.ps1` + `ai-stub.mjs` 不存在，`tests.cj` 零引用 | [grep] |
| AI-8 | P1 | 输入**没有长度上限**（不用 `limits.cj`）；`maxRequestBytes` 是死配置（声明了、从不读） | [grep] + [读码] |
| AI-9 | P2 | 响应形状与权威文档不符（`owner`、`basis[]`）→ 照文档写的客户端会解析失败 | [读码] |
| AI-10 | P2 | **校验发生在授权之前**，无权用户拿 400 而不是 403（违反本仓已定的顺序） | [读码] |
| AI-11 | P2 | `audience` 不做白名单，且回填的是**模型**给的值 | [读码] |
| AI-12 | P2 | `aiStripQuotes` 的 `JsonValue.fromStr` **没有 try/catch**，可能破坏"永不 5xx" | [读码] |
| AI-13 | P2 | **空/纯空白密钥文件仍判"已启用"** → 每个请求发 `Bearer `，用户看到"服务异常"而非"未配置" | [读码] |
| AI-14 | P2 | 配置**内容**错误（DER 证书 / UTF-16 密钥文件）会在启动时抛异常**且无人接住** → 服务起不来 | [读码] |
| AI-15 | P2 | 重试放大（最多 4 次 POST，spec 要求 ≤2）、纠错语用错场景、`attempts` 少报；`--ai-timeout` 无上界会溢出 | [读码] |
| AI-16 | P2 | `aiHostOnly` 只剥路径/查询串，**不剥 URL userinfo** → 密钥可能在启动日志里露头 | [读码] |
| AI-17 | P2 | `retrospective` 的**课题分支没有授权调用**（任务分支有）——今天等效，收紧读范围后会静默成绕过点 | [读码] |
| D-1 | 文档 | `llm-frontend-guide.md:6` 仍写"服务端 `/api/v1/ai/*` 尚未实现"（已实现） | [读码] |
| D-2 | 文档 | `api-design.md` §7.5 给了 `risk` 字段的完整口径，但代码里 `risk` **零命中** | [grep] |

> **一句话**：这批代码"照着自己的文档写"，但**只落地了 5 步集成里的 3 步**（路由 + 参数解析，
> 漏了白名单与 `usage()`），出站读法又继承了框架已知的短读缺陷；再加**没有任何测试**，
> 于是上面这些一条也没被拦住。

---

## 1. 模块构成（本轮审查范围）

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `server/src/ai_config.cj` | 241 | 命令行选项 → `AiOptions` + 启动期校验（未配置不是错误） |
| `server/src/ai_client.cj` | 300 | 出站调用 · 输出归一化 · 降级 · 结果元信息（`AiResult`） |
| `server/src/ai_schema.cj` | 193 | 提示词模板 + 模型输出 schema（集中声明"允许模型返回什么"） |
| `server/src/h_ai.cj` | 643 | 4 个 handler（三段式：认证 → 锁内取数 → 锁外调模型 → 审计+响应） |
| `server/src/errors.cj` | +5 | 新增 `AI_RATE_LIMITED`(429) |
| `server/src/main.cj` | +22 | 注册 4 条路由 + `aiOptionsFromFlags` |

接口：`POST /api/v1/ai/{task-suggest, notice-draft, retrospective, ask}`（一律 POST，全部需登录）。
重编通过后服务端为 **31 个源文件**（原 27）。

---

## 2. 缺陷清单

### AI-1【P0】所有 `--ai-*` 参数被 CLI 白名单拒绝 → AI 功能完全无法启用

**落点**：`main.cj:1231-1241`（`serve` 的 `extraFlags` 是空数组 + `unknownFlags` 闸门）、
`main.cj:1306-1321`（白名单本体）、`ai_config.cj:63-74`（读这些参数）、`main.cj:1268`（读取点在闸门之后）。

**现象**：按 `docs/llm-backend-guide.md:63-70` 配置 AI，服务**起不来**：

```
[实测] .\club-server.exe serve 18200 <DSN> \
         --ai-endpoint http://127.0.0.1:18999/v1/chat/completions \
         --ai-model stub --ai-key-file k.txt --ai-insecure-trust-all 1
       → 不认识的参数：--ai-endpoint
       → 用法: club-server serve [端口] [DSN] [连接选项]
       → exit 1（进程未监听端口）
```

**证据**：

- `main.cj:1231-1235`：`serve` 分支 `extraFlags = Array<String>()`（`serve-tls` 才有 `["--cert","--key"]`）；
- `main.cj:1308-1310` 的白名单**只有** `--mysql-host/-port/-user/-pass/-db`、`--data-dir`、`--port`、`--public-url`；
- `main.cj:1316-1318`：不在名单里就返回该键 → `:1237-1241` 打印并 `return 1`；
- `aiOptionsFromFlags(flags)` 在 `main.cj:1268`，**在白名单闸门之后**，所以它永远拿不到这些键；
- `ai_config.cj:81-84`：`endpoint` 为空 ⇒ `enabled=false` ⇒ 4 个接口永远 `source:"none"`。
- `usage()`（`main.cj:53-94`）也从未提到 AI，而 guide 把这一步明确列成交付项
  （`llm-backend-guide.md:41`「`main.cj` | 改动 | 注册 4 条路由；`usage()` 加 `--ai-*` 参数说明」）。

**为什么是真缺陷**：guide 与 `llm-client-spec.md` §5.1 都把 `--ai-*` 写成唯一配置入口（且密钥**只能**走文件路径），
不存在"另一种启用方式"（本工具链没有 `getEnv`，配置文件也没有被读取）。也就是说：**照文档配不上，不照文档则永远不启用**。

**修法**：把 7 个名字加进 `main.cj:1231-1235` 的 `extraFlags`（或在 `unknownFlags` 里显式放行），
并同步 `usage()`。**注意**：这条不修，AI-9~AI-16 全部无法在真实运行里验证。

### AI-2【P1】出站响应"短读即 EOF" → 长回答被截断并静默降级

**落点**：框架 `third_party/qingzhou/src/httpclient.cj:25-43`（`readBodyText`，出站的每个响应都走它，
见 `outbound.cj:185`）。

```cangjie
let n = body.read(buf)          // buf = 4096
if (n <= 0) { break }
... 
if (n < buf.size) { break }     // ← 第 38-40 行：把"没读满"当成流结束
```

**为什么是真缺陷（不是我的推断）**：同一个仓库、同一套 stdx 流，**入站侧已经踩过并修好**，
还把教训写成了两条铁律 —— `context.cj:677-680`：

> 1. **短读不是 EOF** —— `read(buf)` 允许返回少于 `buf.size` 的字节数（TCP 分段、底层缓冲都会造成），
>    只有 `n <= 0` 才是流结束。旧的「`n < 1024` 即停」把所有跨块 body 截断在第一个不满块。

入站那版（`readBodyUpTo`，`context.cj:684-699`）已按此修好；**出站这版还是旧写法**。

**触发**：任何超过约 4 KB 的合法补全（例如通知正文约 1500 汉字 ≈ 4.5 KB、或 6 条 `reasons`）。
第二次 `read` 只要返回 `n < 4096`，循环就断 → body 截断 → `JsonValue.fromStr` 失败 →
`aiParseOutput` 返回 `None` → `outcome="bad_output"` → 重试一次 → 仍然失败 → **降级为 `fallback`**。
症状是"短问题好用、长回答偶发失灵"，且**不会报错**，只会让用户看到兜底文案。

**修法**：框架快照被 `MANIFEST.sha256` 锁死，不该改；应在 `server/src` 里实现 `HttpTransport`
（框架预留的注入点，见 `llm-client-spec.md` §14.3）用"仅 `n<=0` 判 EOF + 字节上限"的读法，
在 `AiClient.init` 传进去；并回报上游。

**验证标注**：机制在代码层确定（两侧都读过）；**我没有做活的截断复现**——因为 AI-1 把功能整个挡住了，
要跑得先修 AI-1（或临时改码）。复现方法见 §6.2。

### AI-3【P1】`aiAudit` 在 `s.lock` 之外写审计缓冲 → 丢审计行

**落点**：`h_ai.cj:228` / `:345` / `:521` / `:629`（四个 handler 的 `aiAudit(...)`），
而它们各自的 `finally { s.lock.unlock() }` 在 `:188` / `:331` / `:496` / `:615` —— **调用都在解锁之后**。

**证据**：

- `audit.cj:42` 的契约原文：「记一条审计（**在锁内调用**）」；`:54` 直接 `s.audit_pending.add(line)`，
  自己**不加锁**；
- 刷盘侧是在锁内**换引用**：`store_persistence.cj:453-457`（`s.lock.lock()` → `auditLines = s.audit_pending` →
  `s.audit_pending = ArrayList<String>()`）；
- `store.cj:247`：`public var audit_pending: ArrayList<String>`（Cangjie `ArrayList` 非线程安全）；
- 全仓其余 `audit()` 调用点（`h_secret` / `h_plan` / `h_dept` / `h_link` / `h_member`）**都在锁内** ——
  即：这个违规是 AI 模块新引入的。

**触发**：一次 AI 请求返回时，恰有另一个请求（或第二次 AI 请求）在 `snapshotFlush`/`flushPending` 里换数组 →
`add` 可能落进已被换下的旧数组 → **该行审计永远写不进 `audit.log`**；并发扩容更是未定义行为。

**影响面**：AI 的审计行正是"谁在烧钱、烧了多少"的取证材料（`aiAudit` 记 `outcome/source/attempts/ms`）。

**修法**：`aiAudit` 内部自己取一次短锁（`s.lock.lock() … finally unlock()`）再调 `audit`；
慢的出站调用仍在锁外，不冲突。

### AI-4【P1】AI 的逾期天数与列表页**对不上**

**落点**：`h_ai.cj:445`（任务分支）与 `:472`（课题分支）。

```cangjie
odDays = (now - t.due_at) / 86400        // 24 小时取整
```

**权威口径**是 `views.cj:333-342`（`overdueDaysOf`）：

```cangjie
let d = (startOfLocalDay(now) - startOfLocalDay(t.due_at)) / DAY_SECONDS   // 本地日界差
```

其注释（`views.cj:327-330`）给的例子正是：「09-12 18:00 截止、09-14 09:00 现在 → **2 天**」。

**同一个例子**，AI 这条算式得 `(39h)/24 = ` **1 天**。

**为什么是真缺陷**：`api-design.md:2028-2029` 明文要求「`overdue.is_overdue` / `overdue.days`
**必须**取自服务端既有派生量（`views.cj` 的 `is_overdue` / `overdue_days`），不得由模型生成 ——
**否则与列表页数字打架**」。现在不是模型算错，是**服务端自己**用第二套算法算出了另一个数。

**修法**：两个分支都改用 `isTaskOverdue(t, now)` / `overdueDaysOf(t, now)`（顺便消掉重复实现，
符合"同一事实只存一份"）。

### AI-5【P1】`plan_id` 读了不用

**落点**：`h_ai.cj:143` `let planId = reqIntOr(body, "plan_id", 0)` —— 之后**再没被引用**；
prompt 在 `:192` 把 `history` 写死空串：`aiPromptTaskSuggest(title, desc, deptName, candidates, "")`。

**证据**：`ai_schema.cj:77` 的模板里有「部门过往同类任务（供参考，可能为空）」一段，
于是这段**永远是「（无）」**；而 `api-design.md:1952` 把 `plan_id` 定义为
"所属课题，给了可参考该课题下的历史任务"。

**触发**：`{"title":"筹备招新","plan_id":12}` 与不带 `plan_id` 的输出**逐字节相同**；
顺带 `plan_id` 也没有负数/存在性校验。

**修法**：要么实现"该课题历史任务"（并校验 `planId > 0` 且 `s.plans` 命中），
要么删掉这个字段读取与文档那一行 —— 不要留"看起来支持、实际丢弃"的中间态。

### AI-6【P1】没有任何成员级节流；`AI_RATE_LIMITED` 是死码（费用失控）

**落点**：`errors.cj:97-99` 定义了 `AI_RATE_LIMITED`(429)；**全仓再无第二处引用**
（`[grep]`：除错误码表与文档外零命中）。

**文档三处宣称它存在**：

- `api-design.md:101`：「`AI_RATE_LIMITED` | 429 | 智能接口的成员级节流（防刷、防费用失控；见 Part 7）」
- `api-design.md:2080`：「成员级智能调用节流（防刷、防费用失控）」
- `llm-frontend-guide.md:160`：「`AI_RATE_LIMITED`（429，新增错误码）」

**实际有的**（`[读码]`）：只有 `Semaphore(maxConcurrent=4)`（**限并发、不限速率**）与
`budgetMs`（每次调用的时间预算）。服务端中间件链（`main.cj:921-932`）没有 rate limit；
`Store` 里也没有 AI 计数字段。

**触发**：任意 `active` 账号循环 `POST /api/v1/ai/ask`（该接口除登录外**不要求任何权限**），
一个接一个地调即无上限；换个 token 又是一个独立额度。每次 = 1~2 次出站调用，全是真金白银。

**修法**：在 `requireActive` 之后、`ai.call` **之前**，按 `actor.id` 做原子"查+加"滑窗
（可照 `h_auth.cj` 的 `login_fail` / `reg_fail` 既有写法），超限 `throw apiErr("AI_RATE_LIMITED")`。
按成员 id 分桶（不是按 IP）与文档口径一致。

### AI-7【P1】这个模块**一条测试都没有**

**证据（`[grep]`）**：

- `server/src/tests.cj` 里 `handleAi*` / `aiPrompt*` / `aiSchema*` / `AiClient` / `AI_RATE_LIMITED` 引用 **0 条**；
- `server/tests/` 下没有任何含 `api/v1/ai` 的脚本；
- 而 `docs/llm-backend-guide.md` 把它写成验收判据：
  `:45` 交付物含 `server/tests/ai-check.ps1` + `ai-stub.mjs`；
  `:331-334` 「§6.2 端到端（`server/tests/ai-check.ps1` + `ai-stub.mjs`）… 判据沿用本项目口径：**`FAIL 0`**」；
  `:367` 「`h_ai.cj` 4 个 handler + 路由 | `ai-check.ps1` FAIL 0」。
- 两个文件**都不存在**。

**为什么算缺陷而不是"待办"**：本仓对其它模块的纪律是"每个修复都要有会因回退而变红的断言"，
而这里连**骨架级的回归闸门**都没有，直接后果就是 AI-1/4/6 这类问题一个都拦不住。
（另：`llm-client-spec.md` 的 §U/T 用例表、§14 验收清单同样没有被实现任何一条。）

**修法**：补 `ai-check.ps1` + `ai-stub.mjs`（本地 stub 返回指定大小的补全，可同时覆盖 AI-2 的截断阈值与
AI-6 的节流断言）；再给纯函数（`aiNormalize` / `aiCauseKind` / `aiHostOnly` / `aiParseIntOr`）
加 `tests.cj` 单测——它们都不依赖网络。

### AI-8【P1】输入没有长度上限；`maxRequestBytes` 是死配置

**证据（`[grep]`）**：

- `h_ai.cj` 里 `requireLen` / `lenCheck` / `limits.cj` **零使用**；而项目口径是
  `limits.cj:50-51` 的 `MAX_TITLE_BYTES=200` / `MAX_DESC_BYTES=4000`（`h_task.cj` 等各写接口都用了），
  且 `api-design.md:1934` 明写「输入闸门 | 沿用 `limits.cj`：请求体 64 KiB、类型白名单、非 UTF-8 → 400」。
- `ai_config.cj:44` 声明了 `maxRequestBytes = 65536`，注释写「防止把整库塞进 prompt」——
  但**全仓只有这一处**，从不被读；`aiBuildRequestBody`（`ai_client.cj:216-238`）只放
  `model` / `messages` / `temperature`，**没有 `max_tokens`**。

**触发**：`title` / `desc` / `question` 只受 64 KiB body 闸门约束（`h_ai.cj:141-142`、`:591`）；
真正会撑大 prompt 的是**服务端自己拼的** `aiCandidateLines(s, deptId)`（`h_ai.cj:169`：
每个在职成员一行），无任何上限检查 → 大部门会产生远超 65536 的请求体，且不留痕。

**修法**：三个文本字段走 `requireLen`/`lenCheck`（新增 `MAX_QUESTION_BYTES`）；
在 `postOnce` 里检查构造出的 body 是否超过 `maxRequestBytes`，超过就带明确 `outcome` 降级；
请求体补 `max_tokens`。

### AI-9【P2】响应形状与权威文档不符

| 字段 | 文档（权威） | 代码实际 | 落点 |
| --- | --- | --- | --- |
| `task-suggest.owner` | `MemberBrief` 对象：`{"id":7,"name":"张三","dept":{...}}` | 扁平 `owner_id` + `owner_name` | `api-design.md:1959/1967` vs `h_ai.cj:217-223` |
| `ask.basis` | 对象数组，`basis[].kind` ∈ `permission`/`data`/`doc` | 字符串数组（`"permission: xxx"` 形式） | `api-design.md:2049/2057` vs `h_ai.cj:610-613`、`:627` |

**影响**：`llm-frontend-guide.md:52`、`:73` 就是按文档形状写给客户端的；照它实现的 ArkTS
（`owner.id` / `basis[].kind`）在真机上会取不到值。当前客户端还没有 AI 代码（`[grep]`：`*.ets` 里
无 `AiApi`/`task-suggest`），所以是**潜伏的契约裂缝**，趁没人用先对齐。

**修法**：二选一 —— 改代码贴合文档（推荐，文档是"唯一权威"），或先改 Part 7 再宣布新形状。

### AI-10【P2】校验发生在授权之前

**落点**：`h_ai.cj:145-147`（`v.need(...)` / `v.done()`）在 `:164`（`requireAccess(actor, Action.CreateTask, ...)`）
**之前**。**触发**：一个普通成员发 `{"title":""}` 得到 `400 VALIDATION_FAILED`，而真实原因是他**无权**建任务。
本仓已为这个顺序立过规矩：`h_task.cj:468-471`「先认证 → 再授权 → 最后校验入参」
（`docs/code-review.md` 复核修正第 5 条就是因为当初把校验放前面而改的）。
**修法**：把 `v.done()` 挪到授权之后（保持 `title` 的读取不变，只调整"何时抛"）。

### AI-11【P2】`audience` 不做白名单，且回填模型给的值

`api-design.md:1985` 定义为 `members`（默认）/ `leads` / `all`；代码 `h_ai.cj:283` 收任意字符串，
`:328` 把它原样塞进 prompt（`ai_schema.cj:104`），`:342` 又把**模型返回的** `audience` 回给客户端
（`aiSchemaNotice()` 只声明了 `title`/`body`，没约束它）。
**修法**：白名单校验；回填一律用请求里的值，不用模型的。

### AI-12【P2】`aiStripQuotes` 的 `JsonValue.fromStr` 没有保护

`h_ai.cj:399-401` 直接 `JsonValue.fromStr(raw)`；而同一模块其它调用点都包了 try/catch
（`ai_client.cj:251`、`:272`），说明它**会抛**。它跑在 `aiPutCauses` 里（`:386`），输入是**原始模型输出** ——
一旦抛出且无人接住，就破坏 `api-design.md:1927` 的「永不 5xx」。
**不确定**：我无法证明存在让 `JsonString.toString()` 产出不可解析串的输入（stdx 只有 `.cjo`）。
**修法**（无论如何都便宜）：包一层 try/catch，失败就回落成原串。

### AI-13【P2】空/纯空白密钥文件仍判"已启用"

`ai_config.cj:107-116` 只判"文件存在"；`:139-141` 的 `aiTrim(File.readFrom(...))` 可能得到 `""`；
`ai_client.cj:152` 于是发 `"Bearer " + ""`。
**触发**：`New-Item k.txt`（或模板密钥文件忘了填）→ 每个请求 401 → `ai_client.cj:188` 归为 `http_error`
→ 用户看到"智能服务返回异常"，**而不是**"未配置"。
**修法**：`aiValidate` 里把空密钥判成 `enabled=false` + 明确 `disabledReason`。

### AI-14【P2】配置**内容**出错会让整个服务起不来（与自述矛盾）

`ai_config.cj:19-20` 写的是「未配置不是错误……**服务照常启动**」，但校验只看"文件在不在"
（`:112-130`），真正的解码发生在**构造期**：`ai_client.cj:82` → `ai_config.cj:140`
`String.fromUtf8(File.readFrom(...))`；`ai_client.cj:90` → `outbound.cj:69-77` `X509Certificate.decodeFromPem(...)`。
而 `main.cj:946` 的 `buildApp(s, box)` 与 `main.cj:731` 的 `newAiClient(...)` **都没有 try**。
**触发（举例）**：`--ai-ca ca.der`（DER 不是 PEM）→ 解析抛异常；
密钥文件是 PowerShell 5.1 用 `>`/`Out-File` 写出来的 UTF-16LE（带 `FF FE`）→ `String.fromUtf8` 抛异常
（本仓 `limits.cj:141-147` 正是靠这个行为挡非 UTF-8）。
**修法**：内容校验放进 `aiValidate`（非空、PEM 可解析），并把客户端构造包进 try → 失败降级为
`enabled=false` + `disabledReason`。

### AI-15【P2】重试放大 / 纠错语用错场景 / `attempts` 少报 / `--ai-timeout` 溢出

- **重试放大**：框架层 `RetryPolicy(2, 300, 2000)`（`ai_client.cj:92`）按 `outbound.cj` 的构造签名是
  `maxAttempts=2, baseDelayMs=300, maxDelayMs=2000` —— 即**框架自己最多发 2 次**；外面又套了一层
  `while (attempt < 2 ...)`（`:131`）→ 5xx/429/网络情况下**最多 4 次 POST**。
  而 `llm-client-spec.md:174` 的口径是 `retryMax = 1`（**整次调用最多 2 次尝试**）——
  光框架那一层就已经把这 2 次用完了。
- **纠错语用错**：`:217-219` 只要 `attempt > 1` 就追加"上一次的输出不是合法 JSON……"，
  但网络/5xx 失败时**根本没有"上一次输出"**；`:129-130` 的注释自己说这层只该给"输出不合法"用。
- **`attempts` 少报**：`AiResult.attempts`（`:138`/`:147`）只数外层次数，而审计行写的是
  `attempts=${r.attempts}`（`h_ai.cj:69`）→ 真实出站次数被低估。
- **`--ai-timeout` 无上界**：`ai_config.cj:92-96` 只判 `<= 0`；`outbound.cj:161` 是
  `Duration.second * timeoutSecs`，Cangjie 整数溢出**会抛**，而调用点在 `buildApp` 里（同 AI-14，无人接住）。
  `--ai-timeout 10000000000`（秒/毫秒混用的常见笔误）即可让服务启动失败。

**修法**：外层只对 `bad_output` 重试；重试预算做成配置并与 spec 对齐；`attempts` 记真实出站次数；
`timeoutSecs` 范围校验（如 1..300）。

### AI-16【P2】`aiHostOnly` 不剥 URL userinfo → 密钥可能在启动日志露头

`ai_config.cj:155-176` 的扫描停在 `/`、`?`、`#`，**不处理 `user:pass@`**；而 `:149` 会打印
`endpoint=${aiHostOnly(o.endpoint)}`。若运维把凭据写进 URL（`https://sk-xxxx@host/v1/...`），
**每次启动都会把 `sk-xxxx@host` 打到 stdout**（查询串里的密钥反而被剥掉了）。
**修法**：先切掉最后一个 `@` 之前的部分，或只打印 `://` 之后到第一个 `/` 的 host。

### 其它（死代码 / 硬化，各一行）

- `aiDisabledResponse`（`h_ai.cj:60`）、`AI_KEYS_RETRO_OVERDUE`（`ai_schema.cj:121`）、
  整组 §7.5（`aiPromptInviteRisk` / `aiSchemaInviteRisk` / `AI_KEYS_RISK`）**都无调用点**；
- `AiClient.close()`（`ai_client.cj:98-100`）**没有任何调用者**，没有关闭出站客户端的路径；
- `fileExists`（`ai_config.cj:180-187`）为了判存在把整个文件读进来，CA 因此被读两遍；
- `aiNowMs()`（`ai_client.cj:298-300`）用 `DateTime.now()`（**墙钟**）而注释称"单调性"，
  时钟回拨会让 `elapsedMs` 为负（好在有 `attempt < 2` 兜底）；且与 `timex.cj` 的 `nowEpoch()` 重复造轮子；
- 非数字的 `--ai-timeout` / `--ai-max-concurrent` 报的是"必须大于 0 / 必须 ≥ 1"，而不是"不是数字"——
  方向对（fail-closed）但文案误导。

### AI-17【P2】`retrospective` 课题分支没有授权调用

任务分支有 `requireAccess(actor, Action.ViewTasks, aiTargetOfTask(t))`（`h_ai.cj:434`），
课题分支（`:449-482`）**一次都没有** —— 与 `api-design.md:1931`「权限：一律经
`can(member, action, target)`；禁止在 AI 链路里另写一套判定」不对称。
**当前无可利用性**：`scopeAllows` 让 `ViewTasks` 对全社团放开（`perms.cj:246-250`，D-3 的决定），
所以现在两条分支实际等效。**但**：一旦将来收紧读范围，这里会**静默**成为绕过点（因为它压根没判）。
**修法**：补上 `requireAccess`，与任务分支对齐。

---

## 3. 文档与代码不一致（D 类）

| # | 文档说 | 代码实际 | 建议 |
| --- | --- | --- | --- |
| **D-1** | `llm-frontend-guide.md:6`：「**前置**：服务端 `/api/v1/ai/*` **尚未实现**。但前端不必等……」 | 本轮 commit `9dbcd28` 已接通 4 个 handler + 路由 | 改成"服务端已实现（`h_ai.cj`），可按 `source` 三分支对接"；该句是 guide 那批提交里写下的，比实现早一步 |
| **D-2** | `api-design.md:2063-2073` §7.5 给了完整口径：在 `pending` 审批流内部做风险分档、响应带 `risk:{level,reasons,source}`、出现在 `GET /members/pending` 每条记录上 | `[grep]` `server/src` 里 `risk` **零命中**；只有 `ai_schema.cj` 三个无调用点的符号 | 要么补实现，要么在 Part 7 明确标"未实现/推迟"——Part 7 自称"唯一权威"，不能留这种落差 |

---

## 4. 核对为**正确**的部分（复查时不必重复怀疑）

- **认证**：4 个 handler 的第一句都是 `requireActive(ctx, s)`（`h_ai.cj:139/280/406/589`）；
  未登录、`pending`、`disabled` 都进不来；路由各注册一次（`main.cj:742-753`）。
- **授权**：全部经 `can()` / `requireAccess`，文件里没有手写角色 `if`；`task-suggest` 用
  `requireAccess(Action.CreateTask, tgt)` 且 `tgt.dept_id` 取自请求 → 普通成员被拒、部长跨部门被拒
  （`roleAllows` / `scopeAllows` 的既有语义）。
- **锁纪律（三段式）**：出站调用**一律在 `s.lock` 之外**（解锁 `188`→调用 `195`、`331`→`call`、
  `496`→`507`、`615`→`621`）；`aiOwnerNameOf` 自己取短锁且只在锁外被调用；`aiPlanPath` 有深度上限 8。
  ⇒ 不会出现"一次 30 秒的模型调用把整个服务串行化"。
- **密钥处理**：只以**文件路径**传入（不进 argv/env/shell 历史）；唯一用途是
  `headers["authorization"] = "Bearer " + apiKey`（`ai_client.cj:152`）；日志、审计、响应里都不含密钥；
  审计只记 `outcome/source/attempts/ms`（`h_ai.cj:67-70`）；`resp.networkError` 只被用来判断
  `"timeout"`（`:174`），不回显。
- **TLS**：默认**开启校验**（`CustomCA`，`ai_client.cj:84-89` / `outbound.cj:81-92`）；
  明文 `http://` 只在 `--ai-insecure-trust-all 1`（精确匹配 `"1"`）时放行（`ai_config.cj:71/86-91`）；
  `.noProxy()`（`outbound.cj:156/163`）与运维台那次修复同口径（避免系统代理劫持）。
- **模型输出当不可信输入**：`aiExtractContent` → `extractJson` → `JsonValue.fromStr` → `aiNormalize`（白名单键）
  → `JsonSchema.isValid`，不合法重试一次再降级（`ai_client.cj:131-148`、`:246-268`、`ai_schema.cj:38-59`）；
  `owner_id` 还要在**服务端构造的候选集**里复核（`h_ai.cj:199-209`），模型不能凭空造人。
- **重试分类**：4xx（除 429）不重试；429/5xx/网络才重试 —— 与 `llm-client-spec.md:234` 一致。
- **不写库**：4 个 handler 都不改 Store（审计缓冲除外），因此没有"半改状态 + 4xx"的风险。
- **无 SSRF 面**：URL 只来自运维配置，没有请求可控的主机/头；用户文本只进 body。
- **`timeout(15000)` 不会把 AI 变成 5xx**：框架的超时是**事后软超时**，会保留 handler 已写的响应
  （`timeout.cj:72-82`）。

---

## 5. 我没有验证的（明确标注，不猜）

1. **AI-2 的活复现**：需要先修 AI-1（或临时改码）才能把请求打到模型路径；机制由两侧代码 + 框架自己的教训确定。
2. **3xx 重定向是否带着 `Authorization` 跟过去**（若跟，密钥会转发给重定向目标）。
   `autoRedirect` 在 stdx 里存在但代码没设置，而 stdx 只有 `.cjo` 无源码 → 需要一个返回 302 的 stub 才能定论。
3. **stdx 客户端日志级别**是否会把请求头打进 stdout（`llm-client-spec.md` 的 E-3 是已知的 stdout 污染项）。
4. `AiClient.close()` 从不调用**是否**影响进程退出（未测）。
5. AI-12 是否存在真的能让 `JsonString.toString()` 产出不可解析串的输入。

---

## 6. 复现命令

### 6.1 AI-1（已实测，5 秒）

```powershell
cd server
powershell -NoProfile -ExecutionPolicy Bypass -File .\build-mysql-driver.ps1   # 只需一次
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1                # -> build\club-server.exe
cd build
$dsn = "mysql://root:clubroot123@127.0.0.1:3307/club_probe_ai"
[IO.File]::WriteAllText("$PWD\k.txt", "sk-dummy", [Text.UTF8Encoding]::new($false))
# 本机开发口径：http + --ai-insecure-trust-all 1（生产应改成 https + --ai-ca <PEM>）
.\club-server.exe serve 18200 $dsn --ai-endpoint http://127.0.0.1:18999/v1/chat/completions `
    --ai-model stub --ai-key-file k.txt --ai-insecure-trust-all 1
# 期望（现状）：不认识的参数：--ai-endpoint   → exit 1，进程未监听端口
# 修好后应看到启动行：[AI] 已启用 —— endpoint=127.0.0.1 超时=30s 并发=4 校验=⚠ 跳过证书校验（仅限本机开发）
```

> 判据：`serve` 能起来 **且** 启动日志出现 `[AI] 已启用`（未启用时打的是 `[AI]：未启用 —— <原因>`）。

### 6.2 AI-2（截断）：用本地 stub 扫响应体大小

思路（我这次搭过一版，放在 gitignore 的 `server/build/`，用完已删）：
写一个**本地 stub**（Node，无依赖）对任意 POST 返回 OpenAI 兼容补全，内容是一个合法的
`{"answer":"...", "basis":["permission: x"]}`，并把 `answer` 填充到**指定字节数**；
再用 `--ai-endpoint http://127.0.0.1:<port>/v1/chat/completions --ai-insecure-trust-all 1` 起服务，
逐档扫 `300 / 3000 / 4000 / 4200 / 5000 / 9000 / 20000` 字节，看 `data.source` 是 `model` 还是 `fallback`。
**判据**：小于 4 KB 全部 `model`、跨过 4 KB 开始出现 `fallback` ⇒ 截断坐实（阈值应落在 4096 的整数倍附近）。

### 6.3 AI-6（无节流）

修好 AI-1 后，用同一个 stub 起服务，登录后连打 30 次 `POST /api/v1/ai/ask`：
**判据**：全程没有一次 429，且 stub 侧计数 == 30 ⇒ 节流确实不存在。
（`GET /stats` 之类由 stub 自己暴露，脚本里读它即可。）

### 6.4 AI-4（口径不一致）

`views.cj:327-330` 的例子直接可用：造一条 `due_at` 为「前天 18:00」、`now` 为「今天 09:00」的任务 →
`GET /tasks` 应给 `overdue_days: 2`，而 `POST /api/v1/ai/retrospective {"task_id":N}` 现在给 `overdue.days: 1`。

---

## 7. 建议修复顺序

1. **AI-1**（3 行：`extraFlags` + `usage()`）—— 不修，后面所有 AI 工作都无法验证；
2. **AI-4 / AI-3 / AI-5**（小改，且都有明确的对照实现/既有写法可抄）；
3. **AI-6**（防费用；错误码已就绪、文档已承诺）；
4. **AI-7**（补 `ai-check.ps1` + `ai-stub.mjs`；§6.2/§6.3 的 stub 思路可直接用，一次覆盖截断与节流）；
5. **AI-8 + AI-9/AI-10/AI-11**（输入闸门与契约对齐，趁客户端还没写 AI 代码）；
6. **AI-2**（自实现 `HttpTransport`）与其余 P2；其中 **AI-14/AI-15 要一起做**（都把"配置错误"变成"起步就崩"）。

> 每条修复都请配一个**回退即变红**的断言（AI-1 可用 `ai-check.ps1` 里的"参数被接受 + `[AI] 已启用`"，
> AI-4 用 §6.4 的例子，AI-6 用 30 连打的 429 闸门）。

---

## 8. 承接下一轮（本轮未修的都在上面）

- 已在别处记录、本轮不重复计数的：`/members?status=` 枚举、`reset-password` 无 CAS、
  `/tasks/mine` 未分页、`Task.source` 死字段、`handlePlanMove` 不清 `department` 缓存、
  `Random()` 加密可预测性未验证、运维台绑 `0.0.0.0`、开发口令 `13800000009 / admin123`。
- 本轮**新发现且未修**的：AI-1 ~ AI-17、D-1、D-2。
- 与 AI 无关但同批出现的：`docs/llm-client-spec.md` 里的 §U/§T 用例、§14 验收清单
  （`dispatchAiTool` + 权限收敛、工具调用循环上限、多轮预算）**均未实现**；
  那部分属"P1 增强"，验收前需要先决定做不做。

---

## 附：这次审查的覆盖边界

- **读了**：`ai_config.cj` / `ai_client.cj` / `ai_schema.cj` / `h_ai.cj` 全文；
  `errors.cj`、`audit.cj`、`main.cj`（路由与 CLI 相关区域）、`limits.cj`、`perms.cj`、`views.cj`（逾期派生量）、
  `store_persistence.cj`（刷盘换数组那段）、`auth.cj`；框架 `outbound.cj`、`httpclient.cj`、
  `timeout.cj`、`context.cj`（short-read 那条铁律）；文档 `api-design.md` Part 7、
  `llm-backend-guide.md`、`llm-client-spec.md`、`llm-frontend-guide.md`。
- **没做**：真机/公网真实模型联调；3xx 重定向实验；stdx 日志级别实验；对框架快照做任何修改（它被
  `MANIFEST.sha256` 逐字节锁定，改它会被构建拒绝）。
- **工作区**：本轮未改任何产品代码；实验产物（stub、脚本、密钥占位文件、响应样本）全部在
  gitignore 的 `server/build/` 下，事后已删除；探针库 `club_probe_ai` 已 DROP。

---

## 9. 第二轮复验（2026-10-05 晚 · 修复后）

> **谁该读**：同上；但**只想知道"现在能不能用、还剩什么坑"的话，读本节就够了。**
>
> **修复来源**：`e2d33f5`（AI-1 + 7 条 P1/P2）· `442d744`（AI-9/10/11）· `4a9a2df`（AI-2 + AI-5）·
> `c294f24`（AI-6 + AI-7 + D-1/D-2）· `a0c6e5e`（AI-8 余项 / AI-14 / AI-15 + 清死代码）·
> `40d1d2f`（端到端测试）。
>
> **方法**：**只读复验**（重编后跑单测与两套新脚本 + 两处**实测 A/B** + 一个 **cjc 1.2.0 探针**），
> 未改动任何产品代码。验证标签：`[实测]`＝本机跑出来的；`[探针]`＝用项目自己的编译器写小程序验证语义；
> `[读码]`＝逐行读两侧；`[grep]`＝全仓检索。
> 本轮由**两个独立复查**并行进行，下面 **R-1 与 R-2 被双方各自独立复现**（结论一致）。

### 9.1 第一轮 17 条的修复验收

| 项 | 结论 | 第二轮证据 |
| --- | --- | --- |
| AI-1 | ✅ **已修** | `[实测]` 启动日志出现 `[AI] AI：已启用 —— endpoint=127.0.0.1:18999 超时=30s 并发=4 校验=⚠ 跳过证书校验（仅限本机开发）`；`main.cj:1247-1254` 两条子命令都放行 7 个参数、`:82-90` 进了 `usage()`；拼错的 `--ai-modell` 仍被拒 |
| AI-2 | ✅ **已修**（代码层） | `ai_transport.cj:44-62` 只用 `n <= 0` 判 EOF（+256 KB 上限）；`ai_client.cj:97-108` 确实换用了 `AiTransport`。**但闸门测的是副本**，见 R-5 |
| AI-3 | ✅ **已修** | `h_ai.cj:134-142` `aiAudit` 自锁；4 个调用点 `:346/548/751/860` 均在解锁 `:304/533/726/846` **之后** → 无重入、无死锁；慢的出站调用仍在锁外 |
| AI-4 | ✅ **已修** | `h_ai.cj:659/665` 改用 `isTaskOverdue`（`store_queries.cj:263`）/ `overdueDaysOf`（`views.cj:333`）→ 与列表页同为本地日界口径 |
| AI-5 | 🟡 **部分** | 历史真的接上了 + `PLAN_NOT_FOUND`（`h_ai.cj:281-286`）；但 `plan_id < 0` 被**静默忽略**（`if (planId > 0)`），且新读没有课题授权（R-7） |
| AI-6 | 🟡 **部分** | `[实测]` 25 连打：**#1–#20 → 200 `source=model`，#21–#25 → 429**，且桩只收到 **20** 次调用（被拒请求没打到付费 API）→ 速率闸门**真的生效**；但它的清理路径是新崩溃（R-1） |
| AI-7 | 🟡 **部分** | 三套脚本已建；但**两套在本机跑不起来/会假红**（R-2 / R-3）、**8 条修复没有任何闸门**（AI-3/4/5/8/11/12/14/17）、`tests.cj` 仍是 **0** 条 AI 单测 |
| AI-8 | 🟡 **部分** | `lenCheck`（`h_ai.cj:241-242`）、`MAX_QUESTION_BYTES`（`limits.cj:57`）、`maxRequestBytes` 真的被读（`ai_client.cj:181-183`）、补了 `max_tokens`（`:270`）；但超限被误归为 `http_error`（R-10）、`max_tokens=1024` 硬编码（R-14） |
| AI-9 | ✅ **已修** | `owner` = `MemberBrief`（`h_ai.cj:335-341/353-361`）、`basis` = `[{kind,ref}]`（`:409-429`）；`aiOwnerBriefOf` 自锁且只在锁外调用 → 没引入新数据竞争。顺带留下死变量（R-15） |
| AI-10 | ✅ **已修** | `v.done()` 移到 `requireAccess` 之后（`h_ai.cj:260→268`、`:648→650`、`:687→689`） |
| AI-11 | 🟡 **部分** | 白名单 + 一律回填请求值（`h_ai.cj:476-478/545`）；但非法值被**静默纠正为 `members`**（`"leader"` 这种笔误 → 发给全员的错误受众，且不给 400） |
| AI-12 | ✅ **已修** | `h_ai.cj:608-617` try/catch，失败回落原串 |
| AI-13 | ✅ **已修** | `[实测]` `[AI] AI：未启用 —— 密钥文件是空的（或只有空白字符）：<路径>`（`ai_config.cj:129-142`） |
| AI-14 | 🟡 **部分** | 启动期就验 UTF-8 与 PEM（`ai_config.cj:129-142/164-175`）；`[实测]` CA 缺失 → 未启用且**服务照常启动**；但 `AiClient.init` 会**重新读、重新解析**（校验与使用之间存在 TOCTOU），`newAiClient`（`main.cj:741`）仍无保护；`--ai-max-concurrent` 无上界（R-12） |
| AI-15 | 🟡 **部分** | 框架重试归零（`RetryPolicy(1,…)`，`ai_client.cj:107`）、外层 ≤2、`attempts`=真实 POST 数、纠错语只在 `bad_output` 追加、`--ai-timeout` 1..300（`[实测]` `10000000000` → 未启用）；**但归零重试时把退避一起删掉了**（R-6），且 20 s 预算仍只是"两次尝试之间"的检查（单次上限仍 30 s） |
| AI-16 | ✅ **已修** | `[实测]` `http://sk-secret@127.0.0.1:18999/…` 启动日志只出现 `endpoint=127.0.0.1:18999`（`ai_config.cj:218-238`）；但桩从不校验 `Authorization`，`Bearer` 拼装无测试（R-17） |
| AI-17 | ✅ **已修** | `h_ai.cj:683-687` 课题分支补上 `requireAccess(actor, Action.ViewTasks, ptgt)` |
| D-1 | ✅ **已修** | `llm-frontend-guide.md:6` 已改为"已实现" |
| D-2 | ✅ **已修** | `api-design.md:2065-2068` 已明确标 §7.5 尚未实现 |

**回归面无损**：单测 `PASS 510 / FAIL 0`（重编后）。

### 9.2 第二轮新发现（R-1 … R-17）

> **修复状态（2026-10-05 深夜追加）**：本节 R-1…R-17 已由两个提交处理 ——
> `0212e41`（R-1 / R-2 / R-3 / R-4 / R-6 / R-7 / R-8 / R-9〔前半〕/ R-10 / R-12 / R-13 / R-15）、
> `72b2b89`（R-5 / R-11 / R-14 / R-16〔部分〕/ R-17）。两提交自报验证：服务端 32 文件编译通过 ·
> 单测 **PASS 510 / FAIL 0** · `ai-check.ps1` **PASS 5 / FAIL 0** · `ai-e2e.ps1` **PASS 39 / FAIL 0**。
> **仍开放**：R-16 的两处尾巴（`tests.cj` 里 AI 单测仍 **0** 条；`llm-backend-guide.md` §8 排期表未标完成状态）。
> **第三轮（2026-10-05 深夜追加）**：提交 `1cfcfd4` 依本节 R-9 的根因结论，把**固定窗口改成滑动窗口**、
> 把**检查点归位**到「授权/校验之后、出站调用之前」，并把 e2e 的节流用例改成**并发突发** ——
> 该修复**已复核成立**，但第三轮又查出 **10 条**新缺口（含这轮改动直接带出来的 3 条，其中 3 条已实测坐实）。
> 详见 **§9.7**。
> 下面各条正文**保留"修复前"的描述**，便于对照根因；行号若已漂移，以正文说明为准。

#### R-1【P1 · 最该先修】节流清理"边遍历边删"→ 抛异常 → **500**（违反"永不 5xx"）

**落点**：`h_ai.cj:61-67`（`g_aiRate.remove(k)` 在 `for ((k, e) in g_aiRate)` 里）。

**证据**：`[探针]` 用项目自己的 **cjc 1.2.0** 写最小程序验证 Cangjie `HashMap` 语义：

```
caseA(n=4,   half=false): THROWS after removed=1  msg=''  size_now=3   ← 与 h_ai.cj:61-67 同形状
caseA(n=600, half=true ): THROWS after removed=1  msg=''  size_now=599
caseB(n=600) collect-then-remove: ok, size=300                         ← 仓库既有写法，正常
```

**触发**：`g_aiRate.size > AI_RATE_PRUNE_AT`（512）—— 即**进程存活期内有 512 个以上不同成员调用过任一 AI 接口**
（每条记录一次调用就留下，不成功清理就永不回收）——**且**有一条记录已过 60 s 窗口。

**后果**：异常从 `aiRateCheck` 穿出。它在 4 个 handler 里都是 `requireActive` 之后的**第一句、且不在任何 try 内**
（`h_ai.cj` 里唯一的 `catch` 在 `:614`，属 retrospective 内部）→ 框架按非 `ApiError` 处理 → **500 INTERNAL**，
而 `e.message` 为空、日志里只有一行空白原因。
**准确的影响面**（探针显示每次只成功删掉 1 条就抛）：该请求 500 并顺带回收一条过期记录，下一个请求再重复
—— 所以在 >512 成员规模下是**持续性的间歇 500**（不是一次性、也不必重启），而 AI 的"永不 5xx"契约**已被打破**。

**为什么是缺陷而非有意**：`api-design.md:1927` 明写「**永不返回 5xx**」；
且仓库自己早有正确写法 —— `h_auth.cj:123-135 pruneLoginFail`、`:165-177 pruneIpFail` 都是"先收进 `doomed`，循环外再删"。

**修法（3 行）**：照 `pruneLoginFail` 改成 collect-then-remove；另建议给 `aiRateCheck` 加一层 `catch`，
保证**任何**异常都不会从它逃出去。

#### R-2【P1】新闸门 `ai-check.ps1` 在文档指定的开发环境上**必然假红**

**证据**：`[实测]` 重编后运行 → **`PASS 3 / FAIL 2`，exit 1**：

```
FAIL  AI-1 启动行未见「已启用」（实际：）        ← 日志是空的
FAIL  AI-13 空密钥文件未被拦住
```

**根因（A/B 实测定位）**：

| 场景 | 结果 |
| --- | --- |
| DSN 指向**连不上**的端口（进程自己退出） | 日志正常出现 `[AI] AI：已启用 —— endpoint=127.0.0.1:18999 …` ✅ |
| 脚本原样：DSN 指向本机 3307（**MariaDB 正在跑**） | 进程 4 s 后仍活着 → `Stop-Process -Force` 强杀 → **日志 0 字节** ❌ |

- 脚本头部的前提是「**不需要 MySQL**；进程会因连不上 MySQL 而退出，属预期」（`ai-check.ps1:6-8`）。
  但本机 3307 上 MariaDB 正在跑（正是 `docs/local-deploy.md` 指定的联调环境），且 `ensureDatabase`
  会**自动建库** —— `[实测]` `club_ai_check` 库确实被建出来了，证明连接是成功的。
- 于是进程一直活着被强杀，而**仓颉 `println` 在 stdout 重定向到文件时是块缓冲**（`API-NOTES.md` 坑 35 自己记着）
  → 缓冲区随进程被杀而丢失。
- 三条"否定式"断言（参数被接受、userinfo 未泄漏）在**空日志**上恒真 → 只暴露 2 条；
  其中 **AI-16 的"密钥没泄漏"断言在空日志下永远不可能失败**。

**修法**：改成"DSN 指向一个**故意不可达**的端口 + `WaitForExit` 后读日志"（配置类断言本来就不需要真库）；
断言要有**正向证据**；日志为空要直接判 `Bad`；并把 `ai-check-err.txt`（stderr）也打出来。

#### R-3【P1】新闸门 `ai-e2e.ps1` 在本机**一条断言都跑不出**

`[实测]` 两处硬伤，各自独立致死：

1. **输出被重定向/CI 下 `Test-NetConnection` 会崩**：`:67`、`:116` 的 `Write-Progress` 抛
   `ReadConsoleOutput` → 在 `$ErrorActionPreference = "Stop"` 下脚本当场中止（`> log` 时实测如此）；
   加上 `$ProgressPreference = "SilentlyContinue"` 才过得去。
2. 过去之后死在第 **76-78 行** 的 mariadb 调用：**没有 `--skip-ssl`**，也没复用 `tests/mysql-common.ps1`
   → 本机客户端 TLS/SSPI 失败 `ERROR 2026 (HY000) … SEC_E_NO_CREDENTIALS` → NativeCommandError → 中止。

**这正是本仓已标准化的坑**：`smoke.ps1`/`ops-check.ps1`/`tls-check.ps1` 都 dot-source `mysql-common.ps1`
（默认带 `--skip-ssl`），**只有这个新脚本自己另起了一套客户端调用**。

**修法**：脚本里设 `$ProgressPreference='SilentlyContinue'`（或改用 `TcpClient` 探测）；复用 `mysql-common.ps1`，
或至少给所有客户端调用补 `--skip-ssl`。

#### R-4【P2】新 e2e 把数据目录写进仓库且不清

`ai-e2e.ps1:38-39` 把 `--data-dir` 写成 `ai-e2e-data` → 落到 **`server/ai-e2e-data/`**；
该目录**不在 `.gitignore`**（`[实测]` `git check-ignore` 返回非 0；只忽略 `**/build` 与 `/server/data`），
工作区里已留下未跟踪的 `audit.log`（`git add -A` 会被误提交）。
删除只在开头做一次（`:80`），`finally` 不删。
**对照**：`ops-check.ps1` 用 `build\ops-e2e-data`，并在 `:266-267` 明确写过这个坑
（「否则日志会落到 server\ops-e2e-data（本轮真踩过一次）」）；`smoke.ps1` 用 `build\smoke-data`。
**修法**：改到 `build\ai-e2e-data` + `finally` 删除。

#### R-5【P2】AI-2 的闸门测的是**副本**，不是产物；且默认 SKIP

`ai-check.ps1:107` 认的是 `spike/llm-truncation/probe.cj` 里**手抄的** `readFixed`，
而线上是 `server/src/ai_transport.cj` 的 `aiReadBodyText` —— 把 `AiTransport` 换回 `StdxTransport`
（正是 AI-2 的回归）闸门**依然绿**；探针未构建时还打印 `SKIP` 而**不判失败**，与仓库"不静默跳过"的口径不符
（`smoke.ps1` 的规矩是"取不到 → 判 FAIL + 非零退出"）。
**修法**：用现成的分块桩直接打真接口（`POST /api/v1/ai/ask` 要一个 ≥5 KB 的 `answer`，断言 `source=model`）。

#### R-6【P2】归零重试时**把退避一起删掉了** → 429/5xx 会被立刻重打

`ai_client.cj:107` 的 `RetryPolicy(1, …)` 让框架 `shouldRetry` 恒为 false → `outbound.cj:371` 的
`sleep(retry.delayMsFor(attempt))` 成死代码；而外层重试循环（`ai_client.cj:150-167`）**没有任何 sleep**。
于是**恰好在被限流（429）或 5xx 时**，第二次 POST 立即打出 —— 正是框架"指数退避 + 抖动"要防的捶打，
费用也随之翻倍。**修法**：保留框架 2 次尝试并删掉外层循环，或在外层补退避。

#### R-7【P2】AI-5 新接的"课题历史"**没有对课题授权**

`h_ai.cj:260` 的 `requireAccess` 用的是 `tgt.dept_id = deptId`（**请求里的部门**、动作 `CreateTask`）；
`:281-286` 的课题分支只做 `s.plans.get(planId)` **存在性**检查，随后 `aiPlanHistoryLines` 把该课题最多 8 条
任务标题塞进**发给外部模型**的 prompt。
**准确说**：按 D-3「读范围全社团」，这些数据任何在职成员本来就能通过接口读到，**今天不构成越权**；
问题是①与**同一批**为 retrospective 加的 AI-17 检查不对称，②"请求方指定的课题内容被聚合进第三方 prompt"
缺一道明确判定。另 `PLAN_NOT_FOUND` 顺带成了 plan_id 探针（危害极小）。
**修法**：照 AI-17 给课题构造 `Target` 再 `requireAccess(actor, Action.ViewTasks, …)`；`plan_id < 0` 直接 400。

#### R-8【P2】`source:"none"` 却带着完整规则兜底 → 照文档写的客户端会**丢掉可用内容**

文档：`api-design.md:1928`「`none` = **连兜底都给不出**」「`fallback` = 模型不可用、退回规则或历史统计」；
`llm-frontend-guide.md:25` 让客户端把 `none` 渲染成「智能建议暂不可用」、**不放内容**。
代码：AI 未配置时返回 `AI_SOURCE_NONE` **+ 完整 fallback 对象**（`h_ai.cj:349-350 / 551-552 / 754-755 / 863-864`）。
**后果**：合规客户端把本来能用的兜底内容整块丢掉；§7.1 要求的兜底是以错误标签发出去的。
**修法**：这种情况返回 `fallback` + note；或改 Part 7 与前端指南的定义（`main.cj:83` 的 usage 与代码同口径，
所以现状是"文档三处 vs 代码"两套说法）。

#### R-9【P2 · 根因已定位（2026-10-05 深夜）】节流跑在授权/校验**之前**，且模型没开也照样 429

`aiRateCheck(actor.id)` 原是四个 handler 在 `requireActive` 后的**第一句**（修前 `h_ai.cj:232/466/621/820`），
而 `requireAccess` / `v.done()` / `reqObj` 都在其后。后果：本该 403/400 的请求可能先拿到 **429**
（把 AI-10 刚恢复的"认证→授权→校验"顺序从另一侧破坏）；**畸形/无权请求也消耗配额**；
`ai == None`（纯本地响应、零成本）同样会被限流。
**修法**：移到授权之后；`ai == None` 时跳过计数 → **前半已修**（改为 `aiRateCheckIfEnabled(ai, actor.id)`，
现位于 `h_ai.cj:288/534/699/908`）；**后半（顺序）原先"试过、回退、待定位"，根因见下。**

##### 根因：**不是位置问题，是"固定窗口（20 次 / 60 秒）+ 单次调用耗时"**

修复方曾把检查挪到「授权/校验之后」，实测**连打 25 次全 200、零 429**，遂回退并记录"待根因定位"
（见提交 `0212e41` 的 R-9 条与 `h_ai.cj:282-286` 的现场注释）。2026-10-05 深夜用**同一二进制、
同一条代码路径**做 A/B 实测，**唯一变量是桩的响应延迟**：

| 场景 | 桩延迟 | 25 次总耗时 | 结果 |
| --- | --- | --- | --- |
| A 快速连打（§9.1 的口径） | 0 ms | **1 s** | `200=20` + **`429=5`**（`#21` 起 429） |
| B 同样的代码，只是每次调用慢 4 秒 | 4000 ms | **101 s** | **`200=25`，零 429** |

**场景 B 一行代码都没动**，却完整复现了"连打 25 次全 200、无 429" —— 因此该症状**不能**作为
"位置不对"的证据。

机制（`h_ai.cj:111-127`）是**固定窗口**的**速率**限流：

```cangjie
if (now - e.window_start >= AI_RATE_WINDOW_SECS) {   // 60 s
    e.window_start = now; e.count = 1; return         // 窗口一到就清零重来
}
if (e.count >= AI_RATE_LIMIT) { throw ... }           // 20
e.count += 1
```

它只在**同一个 60 秒窗口内累计到 21 次**时才触发。设单次耗时 T，则一个窗口内最多能数到 ≈ 60/T，
**要够到 20 必须 T ≲ 3 秒**：T = 4 s 时每个窗口最多数到 ~15 次就滚窗清零 → **顺序打多少次都不会 429**。
而 25 次 / 101 秒 ≈ **14.9 次每分钟**，**本来就在 20/分钟的额度之内** ——「没有 429」是**正确行为**，
不是限流失效。

> 一句话：**"连打 25 次"只有在 25 次真的挤进同一分钟时才算"超额"；调用一慢，这个测试就不再是超额测试。**

**这同时解释了 e2e 里「#12 起 429」**：桶是**按成员、四个接口共用**的，而 e2e 在这 25 次循环之前
已跑过十几个成功用例，同一成员在同一窗口内已用掉约 8 个额度 → 循环里第 **12** 个就撞线。
`#12` 与 `#21` 的差异由此而来，**也反证限流本身工作正常**。

**为什么"位置"不可能是原因**：实测反证见上表；代码上，对任何走模型路径、最终返回 200 的请求，
只要检查点在 `c.call(...)`（`h_ai.cj:940`）**之前**就一定会执行并计数 —— **只有放到 `sendOk(...)`
（`:949`/`:957`）之后才会失效**；而 `/ai/ask` **没有 `requireAccess`**，其"授权/校验之后"只可能落在
`v.done()`（`:915`）→ `match (ai)`（`:938`）之间，**仍在模型调用之前**。
→ **R-9 的顺序那一半并没有不可修，位置可以放心动。**（那次"完全失效"的实验大概率被另一个变量污染：
要么当时 AI 未启用，`aiRateCheckIfEnabled` 按设计跳过计数；要么那一次每次调用更慢。）

##### 顺着根因挖出的**真问题**（比 R-9 本身更该修）

1. **慢调用可以无限绕过限流**：只要每次调用 ≥3 s，打一万次也不会 429 —— 而这条设计目标的原文是
   **防费用失控**，恰恰在这个场景下是**漏的**（无限花费，只是速率低）。建议按 **P1** 对待。
2. **阈值随延迟漂移**（`#12` vs `#21`），可观测行为不确定，写不出确定性回归。
3. **四个接口共用一个桶**：`notice-draft` 的用量会把 `ask` 顶成 429。

**修法**：改**滑动窗口**（保留最近 N 次调用时间戳，判 `count(now-60s) >= 20`）或**令牌桶**，
让"20 次/60 秒"在任意延迟下都成立；**回归闸门必须制造真实突发** —— 用**并发**（如 25 个并发请求）
而不是"顺序连打 25 次"（顺序连打在慢端点上天然测不出限流；并发还顺带验证计数的原子性）。

**关于顺序（把 R-9 收尾的正确姿势）**：仓库自己的惯例是「**校验 → 限流 → 昂贵操作**」——
`h_auth.cj` 的 `handleLogin` 是 `reqObj(452) → v.done(459) → 锁定检查(477) → PBKDF2(506)`。
所以 AI 侧应为：**`requireActive` → `reqObj` + 字段校验（含 `lenCheck`）→ `requireAccess` → 计数 → 出站调用**
—— 比 403 晚（无权请求不吃配额、也不该看到 429），比出站调用早（真正花钱之前拦住）。

**未验证**：没有真的把检查挪到上述区间去跑（需改产品代码）—— 结论由「实测证明症状与位置无关」+
「调用点必然被执行」两条推理链合成；也未实测"AI 未启用时 25 连打"那一路（`None` 分支跳过计数属读码结论）。

#### R-10【P2】`maxRequestBytes` 超限走 413 → 被归成 `http_error`（甩锅服务商）

`ai_client.cj:181-183` 自造 `OutboundResponse(413, "")`，与上游真实 413 无法区分 → `aiClassify` → `http_error`
→ 用户看到「**智能服务返回异常**」，审计也记 `outcome=http_error`。
而 `llm-client-spec.md:222` 本来定义了独立的 `TooLarge`。**修法**：独立 outcome（如 `too_large`）+ 中立文案。

#### R-11【P2】审计行缺规范要求的字段

`llm-client-spec.md:470` 要求每次调用记 `elapsedMs / outcome / **status** / attempts / **endpoint 主机名**`；
`h_ai.cj:135` 只记 `outcome/source/attempts/ms` —— 缺 `status` 与主机名，且 `AiResult`（`ai_client.cj:39-60`）
**根本不携带上游 status**，光改 handler 补不上。

#### R-12【P2】`--ai-max-concurrent` 无上界

`ai_config.cj` 只判 `maxConcurrent < 1`，**没有上界**（`--ai-timeout` 刚为同类问题补了 1..300），
该值直达 `Semaphore(opts.maxConcurrent)`。取值极端时是否抛异常/OOM 未验证；若抛，
其路径与 AI-14 同类（`AiClient.init` → `newAiClient` → `buildApp` 无 try）。**修法**：同样限个上界（如 1..64）。

#### R-13【P2】AI-15 的重试闸门太松，测不出回归

`ai-e2e.ps1:199` 用 `(($after500 - $before500) -le 2)` —— `+0 / +1 / +2` 都算过，
所以"究竟有没有重试"根本没被断言（AI-15 的原缺陷是 4 次）。`ai_client.cj:150` 已把上限定为 2，
**判据应为 `-eq 2`**。

#### R-14【P2】`max_tokens = 1024` 硬编码且不可配（AI-8 新引入）

`ai_client.cj:270`。中文约 1500 字的通知正文就可能超过 1024 token → 输出被截断 → 非法 JSON →
**静默降级为 fallback** —— 与 AI-2 修掉的那个症状同类，只是换了个成因。
**修法**：做成配置项，或按功能给不同上限（通知正文 ≥ 2048）。

#### R-15【P2】AI-9 顺手留下的死代码

`h_ai.cj:314 var ownerName = ""` 在 `:328/:329` 被赋值、**再没被读过**（响应改用了 `aiOwnerBriefOf`）；
`aiOwnerNameOf`（`:371-381`）只为喂这个死变量而存在。而提交 `a0c6e5e` 自称"清死代码"。

#### R-16【P2】文档债（本轮新增/仍存在）

> **2026-10-05 晚追加**：下面第 1、2、3、4 条**已改掉**（`README.md` 四处 + `llm-backend-guide.md` §6.2 +
> `llm-frontend-guide.md` 前置段 + `llm-client-spec.md` 状态行）；第 5、6 条仍开放。
> **并更正一处我自己的错误**：原来这里写「`docs/llm-backend-guide.md:331-334` 指向**不存在的**
> `spike/llm-http/stub.mjs`」—— 这是错的，**该文件确实存在**（3436 B，与 `FINDINGS.md`/`build.ps1`/
> `spike_main.cj` 同在）。真正的错是它声称桩覆盖「合法/非法/超时/**429**/500 五类」：
> `ai-stub.mjs` 的实际模式是 `ok`/`garbage`/`fenced`/`e500`/`e401`/`slow`，**没有 429 分支**。

- `docs/ai-module-review.md` **自身**头部与 §8 曾整体停在修复前（本节即为此而加；§0 一句话结论仍属历史）。
- ~~`README.md:274/275`（第二轮审查时新增的入口行）已过时~~ → **已改**（并把进度表那行与本报告索引行一并改准；
  见 §9.2 上方的修复记录）。
- ~~`docs/llm-backend-guide.md:331-334`~~ → **已改**（§6.2 现在写实际模式、明说没有 429 分支，
  并标注两套脚本当前跑不到 `FAIL 0`）。
- ~~`docs/llm-client-spec.md:6` 仍标「**未实现**」~~ → **已改为分层表述**（出站客户端 + 4 个接口这一层已实现；
  `dispatchAiTool`/工具调用/多轮/§6.1 单测 U1–U12/§14 清单/审计 `status`+主机名/`TooLarge` 独立分类仍未实现）。
- `tests.cj` 里 AI 单测仍为 **0** 条（AI-7 修法里"给纯函数加单测"那半没做）。
- 规范测试清单 `docs/server-guide.md` 与任何聚合 runner/CI 都没有收录这两套新脚本（仓库无 `.github/`）。
- `docs/llm-backend-guide.md` §8「建议排期」的出口仍写 `ai-check.ps1` FAIL 0 等**未标注完成状态**的判据，
  且通篇未反映"已实现"，建议按需补一列状态。

#### R-17【P2】桩不校验 `Authorization`，也没有 429/超时分支

`ai-stub.mjs` 接受任意（或缺失）`Authorization`（`:48-64`），所以
`ai_client.cj:185` 的 `headers["authorization"] = "Bearer " + apiKey` **没有任何测试证明**；
`mode=ok → source=model` 在密钥完全缺失时也会通过。另 `slow` 模式（`:84-88`）是死代码。
**修法**：`/__stats` 回报最近一次 `authorization` 是否等于期望值，并在 e2e 里断言。

#### 其它观察

- **残留进程**：跑完这两套脚本后，工作区**残留了一个 `club-server` 进程**（已手动清理）——
  说明新增脚本在异常/中断路径上不保证收干净。
- **`AiClient.close()`**（`ai_client.cj:113-115`）仍**没有任何调用者**；`buildApp` 有两条调用路径
  （`main.cj:956`、`:1014`），每次 serve/test 都会建一个不关闭的出站连接池（进程退出时无害）。
- **`aiNowMs`**（`ai_client.cj:331-333`）注释称单调、实际用墙钟 `DateTime.now()`（回拨会让 `elapsedMs` 为负）。

### 9.3 仍未闭合（第一轮遗留）

`api-design.md` §7.5 邀请风控（`aiPromptInviteRisk`/`aiSchemaInviteRisk`/`AI_KEYS_RISK` 一组符号**仍无调用点**）；
第一轮"未验证"三项依旧未验证：**3xx 重定向是否带 `Authorization` 跟过去**、
**stdx 客户端日志级别**、`AiClient.close()` 从不调用是否影响退出。

### 9.4 本轮**未**验证（不猜）

1. **R-1 的端到端 500**：机制用 `[探针]` 证明、异常路径用 `[读码]` 证明；但没造 513 个成员去跑真实 500。
2. **R-6 的实际间隔**：只核了"没有 sleep + 框架重试已关"两处代码事实，没造 429 场景去数两次 POST 的间隔。
3. `Accept-Encoding`/gzip 响应是否会让 `String.fromUtf8` 抛（与修复前的框架路径同源，不算回归）。
4. `--ai-max-concurrent` 取极端值时是抛异常还是 OOM。

### 9.5 修复优先级（第二轮）

1. **R-1**（3 行，唯一会打破"永不 5xx"契约、并在目标规模下持续 500 的）
2. **R-2 + R-3**（让两套新闸门在**文档指定的开发环境**上真能跑；否则等于没有闸门）
3. **R-6**（退避；直接放大费用与被限流风险）
4. **R-4**（数据目录挪到 `build\` + `finally` 删）
5. **R-7 / R-8**（语义/契约问题，改动便宜 —— **已修**）· **R-9 的"顺序"半边**（**根因已定位**：
   位置可放心动，按"认证 → 校验 → 授权 → 计数 → 出站"排即可）·
   **R-9 挖出的"固定窗口可被慢调用绕过"**（建议**升为 P1**：改滑动窗口/令牌桶，
   并把回归闸门从"顺序连打 25 次"改成**并发突发**）
6. **R-5 / R-13 / R-14 / R-10 / R-11 / R-12 / R-17**（闸门收紧与配置补齐）
7. **R-15 / R-16**（死代码与文档同步；R-16 里 `README.md:274/275` 两行可直接改）

> 每条修复都请配一个**回退即变红**的断言：R-1 用"513 条计数后仍返回 200/非 500"，
> R-6 用"429 后两次 POST 的时间差 ≥ 退避基准"，R-3 用"CI/重定向下也能 FAIL 0"。

### 9.6 本轮的覆盖边界

- **读了**：`ai_transport.cj`（新增，全文）、`h_ai.cj`、`ai_client.cj`、`ai_config.cj` 全文；
  `main.cj`（AI/CLI 相关区域）、`limits.cj` 增量、`audit.cj`、`store_persistence.cj`（换数组那段）、
  框架 `outbound.cj`/`httpclient.cj`/`timeout.cj`/`context.cj`；`tests/ai-check.ps1`、`tests/ai-e2e.ps1`、
  `tests/ai-stub.mjs`、`.gitignore`；文档 `api-design.md` Part 7、`llm-backend-guide.md`、
  `llm-client-spec.md`、`llm-frontend-guide.md`、`README.md`。
- **跑了**：`build.ps1` 重编、单测（510/0）、`ai-check.ps1`（PASS 3 / FAIL 2）、`ai-e2e.ps1`（中止）、
  两处 A/B 启动实验、25 连打节流实测、cjc 1.2.0 探针。
- **没做**：真机/公网真实模型联调；对框架快照的任何修改（被 `MANIFEST.sha256` 锁死，改了会被构建拒绝）。
- **工作区**：本轮**未改任何产品代码**；所有实验产物（探针、stub、脚本、密钥占位）都在 gitignore 的
  `server/build/` 下，事后已删除；探针库已 DROP；**额外需注意**：`server/ai-e2e-data/` 是 `ai-e2e.ps1` 的产物
  （R-4），审查期间未代为删除。

---

## 9.7 第三轮复验（2026-10-05 深夜 · R-9 修复后）

> **谁该读**：同上；**只想知道"现在还剩哪些坑"，读 §9.7.2 就够。**
>
> **被复验的修复**：提交 `1cfcfd4`「R-9 根因修复 —— 固定窗口改滑动窗口 + 检查点归位 + 并发闸门」，
> 它依据的是 §9.2 R-9 里那份 A/B 根因结论。
> **方法**：**只读复验 + 三处实测**（并发突发复现、并发下的 `data.source` 分布、302 重定向探针），
> **未改动任何产品代码**；另有一个**独立并行复查**参与，其结论与本节互相印证（下面对每条都注明来源）。
> 标签：`[实测]`＝本机跑出来的 · `[读码]`＝逐行读两侧 · `[grep]`＝全仓检索。

### 9.7.1 R-9 的修复验收（我独立复核）

| 检查项 | 结论 |
| --- | --- |
| 滑动窗口判据 | ✅ trim-then-judge（先滑出窗口再判额度）；拒掉的请求**不落时间戳**；单成员最多 20 条 → 内存有界 |
| `AiRateEntry` 语义 | ✅ 是 `class`。**若是 `struct`，`HashMap.get` 返回副本 → 计数永不累积 → 限流整体失效**（值得记录：这是一处很容易踩空的语义依赖） |
| 调用点归位 | ✅ 4 处（`h_ai.cj:400/620/821/942`）都在 `s.lock` 区间**之外**（锁区间 `325-390` / `574-610` / `716-808` / `920-933`）→ 无 `s.lock → g_aiRateLock` 嵌套 |
| 无绕过路径 | ✅ 恰好 4 个 `c.call`（`:403/623/825/945`），每个前面有且只有一个 `aiRateCheckIfEnabled` → 没有 200 路径能跳过计数；`ai == None` 仍跳过 |
| 原子性 | `[实测]` 25 个**并发**请求 → 恰好 **`200=20` + `429=5`**（计数在 `g_aiRateLock` 下是原子的） |
| 闸门 | ✅ 单测 **510 / 0** · `ai-check.ps1` **PASS 5 / FAIL 0**（R-2 修好）· `ai-e2e.ps1` **PASS 39 / FAIL 0，exit 0**（R-3 修好） |

### 9.7.2 第三轮新发现（F-1 … F-10）

#### F-1【P2 · `[实测]` 坐实】配额被"没有真正调用模型"的请求吃掉：**20 个额度换 4 次真实调用**

**落点**：`h_ai.cj:400/620/821/942` 每次都消耗一个时间戳；但两条路径**一个出站请求都不发**——
`ai_client.cj:133` `if (!sem.tryAcquire()) { … "overloaded" … }`（并发闸门满 → 瞬时兜底）
与 `ai_client.cj:205` `return OutboundResponse(-413, "")`（prompt 超 `maxRequestBytes` 自拒）。

**实测**（就是新闸门那个场景：25 并发、默认 `--ai-max-concurrent 4`）：

```
status:  200=20   429=5
这 20 个 200 的 data.source：  model=4    fallback=16
桩实际收到：  {"count":4}
```

即 **花掉 20 个配额、只有 4 次真花钱**（16 次是闸门满的瞬时兜底）。

**为什么是缺陷**：模块自己立过原则 —— `h_ai.cj:87` 说 `ai == None` 是"纯本地兜底、**零成本**"所以不计数；
`overloaded` 与 `too_large` 同为零出站，却没被排除。这是**多计**（不是绕过），故 P2。
**修法**：`outcome == "overloaded" || status == -413` 时**退还**该时间戳，或只在第一次真正 `postOnce` 时计数。

#### F-2【P2】归位之后**丢掉了削峰**：被限流的请求仍全额付 O(成员×任务) 扫描，且持全局锁

**落点**：检查点在锁区间之后，而锁内是 `aiCandidateLines`（`h_ai.cj:226-244`：`for 成员 { for 任务 }`）
+ `aiFallbackOwner`（`:267-288`：同构双重循环）+ `aiPlanHistoryLines`（`:250-264`）。
**触发**：成员打满 20 次后继续打 `task-suggest`，**每个 429 仍要在 `s.lock` 里跑约 2×成员×任务 次迭代**
（200 成员 × 4000 任务 ≈ 160 万次/请求）→ 单个已认证成员即可让全服务在全局锁上排队。
**修法**：加只读的 `aiRatePeek(memberId)`（已满就抛 429、**不加时间戳**）放在 `requireActive` 之后，
"消耗额度"的那个留在原处。**代价要写进文档**：已被限流的成员会**先看到 429 再看到 403**（与 R-9 的初衷部分相反，但比丢削峰更划算）。

#### F-3【P2 · 闸门无效】新的并发闸门**测不出"回退到固定窗口"**

**落点**：`tests/ai-e2e.ps1:251` 断言"并发 25 → 恰好 20 / 5"。
**问题**：**固定窗口在 1 秒突发下也给出 20/5** —— 这正是本文件 **§9.2 R-9 那张 A/B 表**里的实测数据
（固定窗口、桩 0 ms → `200=20 + 429=5`）。所以把实现改回固定窗口，这条闸门**仍然全绿**，
违反 §9.5 要求的"回退即变红"；而它替换掉的"顺序连打 25 次"在慢端点上同样测不出（§9.2 R-9 已论证）。
**真正能区分的用例**（跨窗口边界的双突发）：t0 打 1 次 → t0+59 打 18 次（两种实现都放行，共 19 个时间戳）→
**t0+61 打 5 次**：滑动窗口只剩 t0+59 那 18 个时间戳有效 → 只放行 2 个（**2×200 + 3×429**）；
固定窗口已在 t0+60 清零 → **5×200**。
**修法**：把这条闸门换成上述跨边界用例（约 61 秒，可按需加开关）。

#### F-4【P2 · `[实测]`】出站**静默跟随 3xx**（顺带结清第一轮悬案）

**实测**（A 返回 302 → B 记录收到的头）：

```
A(端点)       收到: POST /v1/chat/completions   auth="Bearer sk-SECRET-probe-key"
B(重定向目标) 收到: GET  /steal                 auth=null            ← 关键结论
客户端看到:    http=200  source=model
```

- **好消息（第一轮的"3xx 是否带 Authorization"问题就此结清）**：**密钥不会被转发**；
  POST 被降级成 GET、**body 也丢掉** → 不会把 prompt 送给第三方。
- **但仍是隐患**：① 被劫持/配错的 endpoint 能让本服务器去请求**任意主机**（很窄的 SSRF/内网探测面）；
  ② 带重定向的 endpoint 会**静默**退化成"无 body 的 GET" → 恒 fallback，而日志里看不出是重定向导致的。
- **修法**：关掉自动重定向（fail-closed），或至少对 3xx 记一条日志 / 独立 outcome。

#### F-5【P2】滑动窗口用**墙钟** `nowEpoch()`

`h_ai.cj:98` `let now = nowEpoch()`，判据 `:69`/`:139` `now - t < AI_RATE_WINDOW_SECS`。
时钟**回拨** Δ → 所有时间戳年龄为负 → 该成员被 429 长达 Δ，**且 `aiRateStale` 永不返回 true → 清理永不发生**（表会涨）；
**前跳**则配额被提前清空。工具链里有单调时钟（`timeout.cj:65` 用的 `MonoTime`）。
**修法**：窗口改存 `MonoTime.now().toMilliseconds()`，常量用 `60_000`。

#### F-6【P2】模型给的时间串**不做格式校验**

`api-design.md` §7.1/§7.2 规定 `due_at`、`suggest_send_at` 是 **ISO 8601 带时区**，
但 `h_ai.cj:625-629` 一带用 `aiPutStrOrNull` **原样透传**模型值 → 模型回"明天下午"就直接到客户端。
**修法**：在服务端边界校验/规范化，不合格就丢弃该键（比透传脏值好）。

#### F-7【P2】`finish_reason` 从不检查 → 长度截断被误判成"模型输出不合法"

`ai_client.cj:341` 只取 `choices[0].message.content`，**全文没有任何地方读 `finish_reason`**。
`--ai-max-tokens` 偏小（默认 2048、**可调到 64**）或上游按自身上限截断 → 输出被砍断 → 归为 `bad_output`。后果三层：
① 重试会追加「上一次的输出不是合法 JSON」——对长度截断是**错误归因**，还可能促使模型**写得更短**；
② 多花一次注定无效的付费调用（预算没变）；③ 用户只看到笼统的"暂不可用"，**运维也拿不到"是 token 预算不够"这个信号**。
（`llm-client-spec.md` 未要求检查它，属**自诊断缺口**而非违约。）

#### F-8【P3】`too_large` 路径的 `attempts=1` 是假的

`ai_client.cj:156` 先 `attempt += 1` 再进 `postOnce`，而 `:205` 直接返回 `-413` **不发请求**
→ 审计记 `outcome=too_large status=-413 attempts=1`，**真实 POST 数为 0**，与 AI-15"`attempts` = 真实 POST 次数"矛盾。

#### F-9【P3】文档与注释承诺的字段/判据**代码里没有**

- `api-design.md:1970`：「兜底：按「本部门在途任务数最少 **+ 历史按期率最高**」」——
  而 `h_ai.cj:266` 的规则只有"在途最少（并列取 id 小的优先）"，`:387` 的 reasons 也只提在途。
- `ai_schema.cj:67` 注释称候选行形如 `"id=7 姓名=张三 部门=宣传部 在途=2 按期率=92%"`，
  而 `h_ai.cj:238` 实际发的是 `"- id=… 姓名=… 角色=… 在途任务=…"` —— **没有部门、没有按期率，多了角色**。
  于是文档举例里那种"按期完成率 92%"的 reasons **在结构上无法被模型 grounding**（数据从未进 prompt）。
**修法**：实现每成员按期率（并用于候选行与 tie-break），或改文档 + 删掉那句过时注释。

#### F-10【P3】清理失败的 `catch` 是空体

`h_ai.cj:131-133` `catch (e: Exception) { }` —— 将来清理真出问题会**完全无声**，表悄悄涨。
**修法**：至少 `println("[WARN] ai rate prune: ${e.message}")`。

### 9.7.3 第三轮核对为**正确**的（不必再怀疑）

- 滑动窗口判据与边界（`now - t < 60` 的闭区间理论可容 40 次，属 `count(now-60s) >= 20` 该公式的固有性质，非缺陷）；
- `e.stamps = keep` **无别名问题**（`keep` 是新表，旧表只被读一次）；
- 被拒请求**不消耗也不延长**窗口；内存有界，且 prune 仍是 collect-then-remove（R-1 的修法保持住了）；
- `nowEpoch()` **确实是秒**（与 `aiNowMs()` 的毫秒不同，单位没串）；
- 4 个检查点**无锁嵌套**、**无绕过路径**、`ai == None` 仍跳过；
- `-413` 与上游真实 413 可区分，且 `too_large` **不可重试**（`aiRetryable` 只放行 timeout / network / rate_limited / server_error）；
- `aiValidate` 各条 `disabledReason` **都不含原始 endpoint** → 密钥不会被打进启动日志；
- 框架 `extractJson` / `matchBalanced` **实现正确**（跳过字符串字面量内的括号、深度归零时才判开闭类型、嵌套不匹配返回 None）；
- `aiParseOutput` 与 `aiExtractContent` **两层都有 try/catch** → 畸形模型输出不会变成 500；
- `notice-draft` 响应字段与 `AI_KEYS_NOTICE` / 文档一致（含 `suggest_send_at`）；
- e2e 的"重启拿新桶"成立（桶是模块级、进程级；令牌持久化所以复用 Bearer 有效；`/ai/ask` 的 429 只有这一个来源）；
- `timeout(15000)` 是事后软超时，**不会**把慢的 AI 调用变成 5xx。

### 9.7.4 未验证（第三轮）

1. **F-2 的放大倍数**：只做了结构化确认（循环嵌套 + 持锁），**没有压测**那 160 万次迭代的真实耗时。
2. **F-3 的跨边界用例**：给出了算术推导与用例设计，**没有真跑 61 秒那一版**。
3. `catch (e: Exception)` 是否覆盖仓颉 HashMap 的那类异常已不重要（根因 R-1 已从源头移除）。
4. 重启路径上的端口复用 / 绑定失败（Windows `TIME_WAIT`）：`ai-e2e.ps1` 只在**首次**启动时断言存活，
   后续重启处没有"serve 已起"断言（失败会响亮地失败，但断言不对称）。

### 9.7.5 第三轮修复优先级

1. **F-1 + F-2** —— 都是本轮改动**直接带出来**的：一个让额度虚耗 5 倍，一个让被限流的请求继续压全局锁；
2. **F-3** —— 补一条**真正能挡住回退**的闸门（当前那条对 R-9 的修复没有保护力）；
3. **F-4** —— 出站 fail-closed（顺带把 3xx 记进日志）；
4. **F-5 / F-7** —— 单调时钟 + `finish_reason`（自诊断）；
5. **F-6 / F-8 / F-9 / F-10** —— 边界校验与文档同步。

### 9.7.6 第三轮的覆盖边界与环境

- **读了**：`h_ai.cj`、`ai_client.cj`、`ai_config.cj`、`ai_transport.cj`、`ai_schema.cj`；
  `tests/ai-e2e.ps1`、`ai-check.ps1`、`ai-stub.mjs`；`main.cj`（AI/CLI/中间件/错误处理）、
  `limits.cj`、`audit.cj`、`perms.cj`、`store.cj`、`store_persistence.cj`、`timex.cj`；
  框架 `jsonx.cj`（`extractJson`/`matchBalanced`）、`outbound.cj`、`timeout.cj`；`1cfcfd4`/`0212e41`/`72b2b89` 的 diff。
- **跑了**：`build.ps1` 重编 · 单测（510/0）· `ai-check.ps1`（5/0）· `ai-e2e.ps1`（39/0）·
  25 并发突发实测（20/5）· 25 并发下的 `source` 分布与桩计数（model=4 / fallback=16 / 桩 4）·
  302 重定向探针（密钥未转发）。
- **没做**：真机/公网真实模型联调；对框架快照的任何修改（被 `MANIFEST.sha256` 锁死）。
- **工作区**：本轮**未改任何产品代码**；所有实验产物（探针、stub、脚本、密钥占位、日志）都在 gitignore 的
  `server/build/` 下，事后**已全部删除**；探针库已 DROP；**这次跑完 `ai-e2e.ps1` 不再残留 `ai-e2e-data`**（R-4 确认修好）。
