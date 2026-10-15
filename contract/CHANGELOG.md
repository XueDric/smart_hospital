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
