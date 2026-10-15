# 接口契约变更日志

> 读法：先看**日期**，再看**客户端要不要动**。
> 形状变更的权威是 `contract/examples/`；本文只解释「为什么变、谁受影响」。
> 规则：**改响应形状 ⇒ 必须更新样例 + 本文 + 相应 Schema**，否则 `contract-check.ps1` 会红。

---

## 2026-10-15 —— 初版：38 条样例 / 19 个 Schema

**覆盖 7 组**（对应 `docs/CLINIC-LOOP-IMPROVEMENTS-2026-10-14.md` §改进 5 要求的
「三种失败形状 / 信封与业务码对应 / 时间口径 / 分页与上限」四个点）：

| 组 | 条数 | 覆盖 |
| --- | --- | --- |
| 传输层与错误信封 | 5 | `/health`、非法 JSON 400、API 未匹配路由 404、静态 404、405 |
| 鉴权 | 4 | 登录成功、口令错、缺令牌、角色不符 |
| 挂号 | 8 | 建单 201、**幂等重放 200**、by-token 反查、未知 token 404、缺参数 400、排班不存在 404、退号 200、号源被抢 409 |
| 预问诊 | 7 | SSE 流、半途作答 200（**无 form**）、作答完成 200（有 form）、读会话、会话不存在 404、跨患者 404、非法槽位 400 |
| 挂号 + 预问诊绑定 | 1 | 带 `previsit_id` 的 201（回 `previsit_bound`） |
| 病历 | 12 | 医生队列、本单预问诊、别的医生的单 404、带 `use_intake_session` 的保存 200、单查 200、患者看未锁定 404、锁定 200、锁后改 409、患者看已锁定 200、列表、医生 reopen 403、管理员 reopen 200 |
| 列表分页与上限 | 1 | `limit=9999&offset=-5` 被夹成 `50/0`（内容 volatile） |

### 修正了三处「文档与实现不符」（**以契约为准**）

1. **API 未匹配路由的 404 形状**：文档旧版说平铺 `{"error":"Not Found","path":…}`；
   实测是**本项目的错误信封** `{"ok":false,"error":{"code":"ROUTE_NOT_FOUND","message":"接口不存在：GET /api/v1/…"}}`
   （兜底中间件 `http_app.cj:2684-2706` 把框架的平铺 404 改写了）。
   平铺 404 **只**出现在静态路径（`/admin/<不存在的文件>`），且 `content-type` 是 `application/json`（**无 charset**）。
2. **405 此前完全没有记录**：平铺 `{"error":"Method Not Allowed","allow":"GET"}` + `Allow` 响应头。
3. **`ROUTE_NOT_FOUND` 此前被标为"死条目"**（"实现里未见任何 handler 抛它"）：现在它真的会被抛。

### 客户端影响

- 错误解析按 `docs/FRONTEND-INTEGRATION.md` §3.2 的**五种**形状分支：先判 `ok` 字段存不存在，
  再判 `code`（非法 JSON）/ `error === 'Method Not Allowed'`（405，读 `allow`）/ `error === 'Not Found'`（静态 404）。
- **不要**再用"404 就一定是路径拼错"来判断 —— API 404 是信封，`error.code` 会告诉你原因。
- `previsit_bound` / `request_id` / `server_time` 从本版起在挂号类响应里出现（改进 1 / 改进 4）；
  `use_intake_session` 保存后的病历里会出现 `previsit_ref`（**初值来源快照**，不是"当前作者"）。

---

## 2026-10-15 —— 改进 3：病历修订历史（48 条样例 / 22 个 Schema）

**新增 11 条、更新 4 条**（原 38 条全部保留）。覆盖 `docs/CLINIC-LOOP-IMPROVEMENTS-2026-10-14.md` §改进 3。

### 变更

- **新增 3 个端点**（都要求医生身份 + **必须是本单的接诊医生**，否则 404 `APPOINTMENT_NOT_FOUND`；
  管理员可读任意单的修订历史）：
  | 端点 | 样例 | 说明 |
  | --- | --- | --- |
  | `GET /api/v1/doctor/visits/:id/record/revisions` | `record-revisions-200` | 列表：`version` **升序**、**不带 sections**（列表带正文会让"版本抽屉"变成一次几 MB 的响应） |
  | `GET …/record/revisions/:version` | `record-revision-detail-200` | 详情：`sections[]` 与病历 `sections` **同形状**、含**全部七段**（空段也在） |
  | `GET …/record/revisions/:version/diff?against=N` | `record-revision-diff-200` | 逐段对比：`{key,label,changed,left,right}` 含全部七段；`changed` 由**服务端**判定 |
- **`GET …/record/revisions/:version` 取不到 ⇒ 404 `REVISION_NOT_FOUND`**（`record-revision-unknown-404`）——
  **刻意不返回空对象**：空对象会让客户端渲染出"七段全空"的假版本，看起来像病历被清空了。
- **`diff` 不带 `against` 且 `version = 1` ⇒ 400**（`record-revision-diff-no-against-400`），
  刻意不退化成"拿 v1 跟自己比"（那会返回"一切未变"，是一个**看起来成功的错答案**）。
- **`POST …/record/reopen` 现在必须带理由**：`{"reason":"…"}`，trim 后 **4–255 字符**（按**字符**不是字节）。
  缺失 ⇒ 400 `VALIDATION_FAILED`（`record-reopen-no-reason-400`）；过短 ⇒ 同码（`record-reopen-short-reason-400`）。
- **`lock` / `reopen` 的成功响应新增 `revision_version`**（`record-lock-200` / `record-reopen-admin-200`）：
  本次动作落下的修订版本号。**`0` = 审计行没写上（病历动作已成功）**⇒ 客户端当成"版本号未知/待补"，
  **不要当失败重试**（重试会走幂等路径自愈那一版）。
- **`reopen` 的权限动作从"借 `ManageSchedule`"改为语义动作 `ManageRecordRevision`**（仅管理员）：
  **授权结果不变**（`record-reopen-doctor-403` 仍是医生 403 `FORBIDDEN_ROLE`），但语义不再含混
  ——将来"让人调号源"不会连带放开"推翻已定稿的文书"。
- **患者读修订历史 ⇒ 404 `APPOINTMENT_NOT_FOUND`**（`record-revisions-patient-404`）：修订条目里含
  `reason` / `operator_role` 等内部审计话术，不给患者（这一条是**刻意**用 404 而不是 403：
  403 会告诉患者"这东西存在但不是你的"）。

### 为什么

- 改进 3 的目标：病历**锁定后**的每次"解锁→重写→再锁定"要留下可追溯的版本与理由；
  现在 `reopen` 会把 `status` 打回 `draft` 并**抹掉**"谁在什么时候为什么解锁"，
  纸质病历的"划改并签名"在系统里没有任何对应物。
- 版本只在**定稿（lock）**与**解锁（reopen）**时落行：草稿的每次 PUT 不落版本
  （否则一个上午能刷出几百版，历史变成噪声）。

### 顺带修掉的导出机缺陷（样例内容不变，但**门禁从此不再假红**）

`admin-users-page-clamped-200` 的 `volatile` 声明过去**没有真正生效**：路径写成了相对 `response` 根的
`data.items`，而导出机是按信封体解析的，解析不到就**静默 return** —— 于是文件里存的仍是**全量 items**，
一旦别的脚本往库里加了账号（`revision-check` 就会加），逐字节比对就红。
修法：路径坐标统一为信封体、解析不到**直接失败**，并让门禁断言"声明的 volatile 路径在文件里确实是
`"<volatile>"`"（已做负向验证：把旧文件放回去 ⇒ `[FAIL] … 实际是 '<array>'`，EXIT=1）。
这条**不影响客户端**，但它解释了为什么"单独跑绿的契约门禁在 `final-verify` 里会红"。

### 客户端要不要动

- **医生端**：解锁按钮的对话框**必须**收集理由（4–255 字，前后空格会被 trim）；空/过短会被 400 顶回来。
  建议在提交前本地就校验长度，别让医生写完 300 字才发现超长。
- **医生端**：病历详情页可加"版本"入口（列表 → 详情 → 对比）。注意列表是 **version 升序**；
  要"最新在上"自己反转。角标数量用 `diff` 响应的 `changed_count`，**不要**前端自己比较 `left/right`
  （两边算法一旦不同，角标就会和详情页自相矛盾）。
- **存档/兼容**：`revision_version` 是**新增可选**字段，旧客户端忽略它即可；
  但**解锁不再能不带 reason 调用** —— 若某个客户端还在发空 body，本版之后会收到 400。
- 存量已锁定病历由 `migrateSchema` 第 ⑩ 步补一版 v1（`operation='lock'`、`operator_role` **空串**、
  `created_at` = 病历的 `updated_at`）：客户端看到"只有 1 版"是正常的，**不是**历史丢了。

---

## 2026-10-15 —— 改进 2：医生工作台（既往病历 + 乐观锁）（53 条样例 / 24 个 Schema）

**新增 5 条、更新 0 条**（原 48 条全部保留）。覆盖 `docs/CLINIC-LOOP-IMPROVEMENTS-2026-10-14.md` §改进 2 的服务端部分。

### 变更

- **新增端点 `GET /api/v1/doctor/patients/:patientId/records`**（样例 `doctor-patient-records-200`、
  `doctor-patient-records-exclude-200`）—— 医生在自己的工作台上取**这位患者**的既往已定稿病历。
  三条闸门同时生效，且都由本契约钉住：
  | 闸门 | 不满足时 | 样例 |
  | --- | --- | --- |
  | 必须是医生（患者没有医生档案） | 403 `FORBIDDEN_ROLE` | `doctor-patient-records-patient-403` |
  | 该患者必须**在这位医生名下**挂过号（判断在 SQL 里） | 404 `APPOINTMENT_NOT_FOUND` | `doctor-patient-records-other-doctor-404` |
  | 只回**已定稿**、且带正文与就诊上下文 | —（本就要给的） | `doctor-patient-records-200` |
- **`items[]` 的 `status` 只可能是 `locked`**：草稿属于"正在写的那一份"，不会从既往列表漏出去
  （样例里同一患者另有一张**只有草稿**的单，它不在 `items` 里 —— 这条样例同时证明了"能取到"与"不外泄"）。
- **`?exclude_appointment_id=`**：工作台显示"既往"时要把正在写的这一份排除，
  否则医生会看到两份"本次就诊"（`doctor-patient-records-exclude-200` 的 `count = 0` 就是这个语义）。
- **`?limit=` 默认 5、上限 20，非法/越界一律回落默认**（不报 400，与患者侧 `/medical-records` 同一脾气）。
- **`PUT /api/v1/doctor/visits/:id/record` 新增可选 `expected_updated_at`**（样例
  `record-put-expected-stale-409`）。带上它且与服务端当前版本不符 ⇒ **409 `EMR_CHANGED`**，
  且**新增 `error.fields`**（`updated_at` / `updated_by` / `record_id`）如实回报当前那一版 ——
  这是本契约里**唯一**带 `fields` 的错误，配 `envelope-error-fields`（其余错误仍用 `envelope-error`，
  它禁止额外成员，所以"多带字段"本身也会被门禁抓到）。
- **不带 `expected_updated_at` ⇒ 行为与旧版完全一致**（不校验），客户端可以逐个入口上线。
- **已定稿的单仍优先回 `EMR_LOCKED`**（`record-put-locked-409` 未变）：先讲最要紧的事，
  而不是让客户端以为"只要重新读一次版本就能写进去"。

### 为什么

- 工作台的目标是"同屏写完本次 + 对照既往"：患者侧 `/medical-records` 走**令牌里的 patient_id**，
  医生拿不到"我面前这位患者"这条路；而让客户端自己拼 patient_id 又等于把全院病历的枚举权交出去
  （自增整数），所以归属判断必须在服务端、且在 SQL 里。
- "不是我的患者"回 **404 而不是 403**：403 等于回答"这位患者真实存在"，那就是一个枚举 oracle。
- 乐观锁：医生在诊室电脑和移动端各开一份草稿是常态，没有 `expected_updated_at` 时
  **后提交的会静默覆盖先提交的**（现有 `draftSnapshotSql` 只做同一次请求内的乐观比较，
  客户端无从表达"我读到的是哪一版"）。

### 客户端要不要动

- **医生端（必须）**：读取病历时记住 `data.updated_at`，提交时把它作为 `expected_updated_at` 回传；
  收到 409 `EMR_CHANGED` 时**保留医生已输入的内容**，提示"这份病历已被他人修改"，
  并可用 `error.fields.updated_at` 显示差异新旧；**不要**自动重试覆盖（那正是要防的事）。
- **医生端（建议）**：角标/入口用 `status` 判定，别用 `sections` 是否为空 —— 草稿也有正文。
- **存档/兼容**：`expected_updated_at` 是**可选**请求字段，旧客户端不发也能继续工作（只是没有并发保护）。

---

## 2026-10-15 —— 改进 7：AI 分诊遥测与排障端点（59 条样例 / 26 个 Schema）

**新增 6 条、更新 0 条**（原 53 条全部保留）。覆盖 `docs/CLINIC-LOOP-IMPROVEMENTS-2026-10-14.md` §改进 7 的服务端部分。

### 变更

- **新增端点 `GET /api/v1/admin/ai/triage-stats`**（样例 `admin-ai-triage-stats-200`、`admin-ai-triage-stats-window-200`）
  —— 分诊质量看板：给 `total` / `degraded` / `degrade_rate` / `p50_ms` / `p95_ms`，可按
  `group_by=source|reason_code|model_name` 分桶。
  - `group_by` 是**要拼进 SQL 的列名** ⇒ 只认这三个字面量，其余（含空串、`id`、注入串）
    一律 **400 `VALIDATION_FAILED`**（样例 `admin-ai-triage-stats-bad-group-400`）；**绝不回退默认值继续查**。
  - `from` / `to` 缺省 = 最近 24 小时；`from > to` ⇒ **400**（不自动交换 —— 交换会把客户的参数错误掩盖成"查询成功但空"）。
  - `limit`（样本上限）默认 `5000`、夹到 `1..20000`；`group_limit` 默认 `20`、夹到 `1..100`。
    回显实际用的 `sample_limit` / `group_limit` / `sampled` / `truncated`，客户端不必猜。
  - `overall.bucket` 恒为 `"all"`（聚合体不是分组体，但字段形状完全一致，前端一套渲染）。
- **新增端点 `GET /api/v1/admin/ai/triage-calls/:requestId`**（样例 `admin-ai-triage-calls-200`、`-unknown-200`）
  —— 单次调用的全链路：`source` / `reason_code` / `model_id` / `model_name` / `prompt_revision` /
  `elapsed_ms` / `degrade_reason` / `used_kb` / `kb_doc_ids`。
  - 未知 `requestId` ⇒ **200 + `count: 0`**，**不是 404**：没有遥测行 ≠ 这个编号不存在
    （限流、参数校验、鉴权阶段拦下的请求本来就不写统计），回 404 会把排障的人引向不存在的错误。
  - `items[]` 按 `id` 降序（`order: "id_desc"`）；`request_id` 无唯一约束，故返回**数组**。
- **`POST /api/v1/triage` 的响应新增 `request_id` 与 `server_time`**（与挂号类响应一致，见初版条目）。
  这是本次唯一的**既有端点形状变更**：排障闭环只能按 `request_id` 查，而患者端默认不带
  `X-Request-Id`；响应里不回编号，患者说"这条分诊不对"时运营就无从取号。
- **两个新端点都要管理员权限**（`Action.ManageAi`，样例 `admin-ai-triage-stats-patient-403`），
  没有新造权限动作：这一屏是"模型/模板的运行效果"，本就在 AI 配置责任范围内。

### 为什么

- 改进 7 要的是"**能看着数据排障**"：在此之前 `triage_stat` 只写不读，线上分诊质量、降级率、
  耗时分布全靠猜；新增的列（`request_id` / `model_id` / `model_name` / `prompt_revision` /
  `elapsed_ms` / `degrade_reason` / `used_kb` / `kb_doc_ids`）就是为这两个端点服务的。
- **`p50/p95` 用最近秩法、对整数毫秒不做插值**：插值会造出一个**从未真实发生过**的耗时
  （比如 p95 = 437.6ms），排障时去日志里找这个数只会白费时间。契约把窗口样例的
  `p50_ms = 412`、`p95_ms = 900`（3 行样本）逐字节钉住，任何"更聪明的"实现都会红。
- **降级率带 4 位小数**（`0.6667`）：`degrade_rate` 是给人看的比例，精度写进契约后
  "0.67 还是 0.6667"就不再是实现自由。
- **合规红线：这两个端点永远拿不到主诉原文**。机制性保证：`triage_stat` 表里**根本没有主诉列**
  （`triageStat.record()` 的签名里没有这个参数），只有 `truncated` 布尔与科室名；
  `kb_doc_ids` 只给命中的文档 **id**，不给正文片段；`request_id` 是客户端传来的关联键，
  **不是身份凭证**，也不含患者标识。看板既有口径（不得出现 patient_id / doctor_id / 手机号 /
  姓名形状）在这两个端点上继续成立，Schema 里也没有这些字段的位置。
- `degrade_reason` 用**稳定码**（`RED_FLAG` / `CONFIG_READ_FAILED` / `AI_DISABLED` /
  `INVALID_OUTPUT` / `CALL_FAILED`，空串 = 真用上了模型）而不是给人看的说明文字：
  改文案不会让历史聚合断成两段；`degraded` 是它的冗余布尔，省得前端记"空串 = 正常"。
- `prompt_revision` 取的是**调用当时的配置版本号**（`ai_setting` 的整表版本）。

### 客户端要不要动

- **管理端（新增）**：AI 质量页接这两个端点。列表为空是正常结果，别当错误处理；
  `truncated: true` 要显式提示"样本被截断，分位数是抽样的"。
- **患者端 / 医生端**：不用动。`POST /api/v1/triage` 只是**多**了 `request_id` / `server_time`，
  旧解析不受影响；但如果要做"反馈这条分诊不对"，把 `request_id` 一起带上（运营才能定位）。
- **别把 `request_id` 当权限**：它是客户端可自造的关联键，服务端只用来串联日志与遥测。

---

## 模板（新增条目照抄）

```markdown
## YYYY-MM-DD —— 一句话概括

### 变更
- `端点 / 样例名`：改了什么（字段增删、状态码、形状）

### 为什么
- 触发这次变更的需求 / bug（带 issue 或文档章节）

### 客户端要不要动
- 不用动 / 必须改（具体到解析哪一段、读到什么要兜底）
```
