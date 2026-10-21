# 接口契约变更日志

> 读法：先看**日期**，再看**客户端要不要动**。
> 形状变更的权威是 `contract/examples/`；本文只解释「为什么变、谁受影响」。
> 规则：**改响应形状 ⇒ 必须更新样例 + 本文 + 相应 Schema**，否则 `contract-check.ps1` 会红。

---

## 2026-10-17（其三）—— 退号响应新增 `already_cancelled`（仍是 67 条样例 / 24 个 Schema）

**客户端要不要动**：**建议动，不动也不会崩**。纯加法字段，旧客户端忽略即可；但它修掉的是一个会
**误导用户**的地方 —— 重复退同一单时 `slot_restored` 一直如实为 `true`（号**确实**早就还回去了），
而客户端会把它读成"这一次又把号还了一次"，于是重复弹一次"号源已归还"。

### 变更

- `contract/examples/booking-cancel-200.json`：`data` 新增 `"already_cancelled": false`（导出机重新导出）。
- `contract/schema/data-booking-cancelled.schema.json`：`required` 与 `properties` 加 `already_cancelled`（布尔）。
- 服务端实现：`http_app.cj` 的退号 handler —— 口径取**取消前**那份快照（取消后重读永远是 `cancelled`，
  问不出"之前是什么"）。
- 判读口径：`already_cancelled` 与 `slot_restored` 的组合见 `docs/FRONTEND-INTEGRATION.md` 的「退号」一节。
- 回归守卫：`server/tests/p1-extra-check.ps1` 第 `[3c]` 节。

---

## 2026-10-17（其二）—— `/health` 新增 `db` 块，`ok` 口径变为「进程活着**且库通**」（仍是 67 条样例 / 24 个 Schema）

**客户端要不要动**：**建议动，但不动也不会崩**。`/health` 是**唯一不走信封**的接口，新增的是
**加法字段**（`db`），旧客户端忽略即可；但 `ok` 的**语义收紧了**：以前恒 `true`，现在库不通时为
`false` **且响应码是 503**。若客户端拿 `ok` 判"能不能用"，这正是它想要的语义；若客户端只看
"HTTP 200 就是活着"，则需要改成"200 且 `ok:true`"（503 说明进程活着但库不通）。

### 变更

- `contract/examples/health-200.json`：新增 `"db": {"ok": true, "reconnects": 0}`（导出机重新导出）。
- `contract/schema/health.schema.json`：`required` 加 `db`；`db` 为对象，必含 `ok`（健康样例恒 `true`）
  与 `reconnects`（≥0），可选 `reason`（仅 `ok:false` 时出现，固定短句「数据库暂不可用（详见服务端日志）」
  —— **不回驱动原文**：该端点不鉴权）。
- 服务端实现：`http_app.cj` 的 `healthBody` / `sendHealth`（`/health` 与 `/api/v1/health` 共用）。
- 样例仍只钉**健康态**（200 + `ok:true`）；503 降级态的形状由本文与 `docs/FRONTEND-INTEGRATION.md`
  §2.3 / §5.19 描述（无独立样例，因为 `ok:false` 与 Schema 里的 `const:true` 冲突，而"造一次库故障"
  不适合放进导出机的固定请求序列）。

### 为什么

复验报告 **S4**：DB 单连接、失败后 `usable=false` 永不复位 ⇒ 一次数据库重启就让服务端**永久 500**，
而 `/health` 一直回 200 —— 探针摘不掉流量、运维也看不出"库断了"。修法：连接失败/`IsBroken` 时
**自动重连**（计数进 `db.reconnects`），并让 `/health` **真去探一次库**：不通 → 503 + `ok:false`。
（S4 拔库自愈与 S13 客户端样本的验收记录见 `docs/SYSTEM-DESIGN.md` 数据层「断链自愈」段与 `docs/交付快照.md`。）

---

## 2026-10-17 —— 收敛为**单一**错误信封：框架层三种平铺形状全部改写信封（仍是 67 条样例 / **24** 个 Schema）

**这是一次让契约变简单的变更**：4xx/5xx 从此**只有一种**主体形状
`{"ok":false,"error":{"code":…,"message":…}}`。触发：复验报告里的 **S14**
（`docs/` 的复验文档，2026-10-17）——「框架自己写出的错误体不是项目信封」在报告里提了 4 处。

### 变更

- **框架层新增可注入点**（`server/third_party/qingzhou/src/`）：
  - `router.cj`：新增 `Router.errorBody: (Int64, String) -> String`（默认 `defaultRouterErrorBody`，
    **默认行为不变**，框架自己的单测/手工清单仍走平铺）+ `defaultRouterErrorBody` 工具函数；
    5 处硬编码体（`:199` / `:204` / `:211` / `:231` / `:244`）改为 `errorBody(…, …)`。
  - `static.cj`：`StaticOptions` 原本就有 `notFoundBody` / `forbiddenBody`，本版补上
    `rangeNotSatisfiableBody`（原 416 体硬编码在 `:288`）。
- **应用侧**（`server/src/http_app.cj`）：`buildHospitalApp` 里注入
  `router.errorBody = {…}`（405 → `METHOD_NOT_ALLOWED`，其余 404 → `ROUTE_NOT_FOUND`）、
  `staticOpts.notFoundBody/forbiddenBody/rangeNotSatisfiableBody`，并把
  `.use(bodyParser())` 换成 `.use(bodyParser(hospitalBodyParserOptions()))`（`http_common.cj`），
  非法 JSON → 400 `VALIDATION_FAILED`「请求体不是合法 JSON」。
- **两处外层闸门也一起换掉**（否则会漏出平铺体，实测抓到过）：
  `.use(contentLengthLimit(hospitalContentLengthLimitOptions(64 * 1024)))` —— 便利函数
  `contentLengthLimit(maxBytes)` 内部 new 的是默认 `ContentLengthLimitOptions`，413 会回
  `{"code":413,"message":"Request body too large","data":null}`。现在 413 也是信封：
  `{"ok":false,"error":{"code":"VALIDATION_FAILED","message":"请求体过大，超出服务端允许的上限"}}`
  （文案刻意不写具体数字：同一段 onError 被外层闸门与流式读入两处复用）。
- **契约文件**：`flat-error.schema.json` / `static-not-found.schema.json` / `method-not-allowed.schema.json`
  **删除**（27 → 24）；`schema-map.json` 里 `error-invalid-json-400` /
  `error-method-not-allowed-405` / `error-static-not-found-404` 改指 `envelope-error` 并加
  `error_code` 断言（`VALIDATION_FAILED` / `METHOD_NOT_ALLOWED` / `ROUTE_NOT_FOUND`）。

### 为什么

- **平铺体让客户端无法按 `code` 分支**：`{"code":400,…}` 的 `code` 是整数、`{"error":…}` 的 `error`
  是字符串，与业务信封的 `error.code` 同名不同型 —— 客户端要么写三套解析，要么退化成 `HTTP_400`
  / `HTTP_404`，丢掉「到底哪里错」。
- **同一份 API 里出现两种 404 形状**（API 走信封、静态走平铺）没有任何收益：静态路径也在
  `/admin/**` 的同一台服务上，客户端拿到的是同一个 `res`。
- 框架的**默认值仍然可注入**：不想统一的用法（含框架自测）不受影响，所以这是**加法**不是破坏。

### 客户端影响

- **唯一**的错误形状是信封，`error.code` 是字符串业务码；解析器可以删掉 `res.error === 'Method Not Allowed'`
  / `res.error === 'Not Found'` 这类分支（留着也无害）。注意 405 的 **`Allow` 响应头仍在**
  （样例里 `response.allow` 逐字节钉住），但**响应体里不再有 `allow` 字段**。
- `common-core/src/main/ets/network/HttpClient.ets` 的 `parseFrameworkError()` 回退分支
  （`code === '400' && message === 'Invalid JSON body'` 与 `path` 分支）**不需要改**：它只在
  `ok` 字段缺席时进入，即"对面是旧服务端"，保留它正好用于向后兼容。
- 静态 404 的 `content-type` 仍是 `application/json`（**无 charset**，历史遗留）；主体是 UTF-8
  JSON，按 RFC 8259 客户端一律按 UTF-8 解析。静态 416 与其余信封一致（带 `charset=utf-8`）。

---

## 2026-10-16 —— 复核 N1/N3：`patient_name` 拿掉 `minLength: 1`、并发首建的竞态补上门禁（仍是 67 条样例 / 27 个 Schema）

**样例形状没变**（`patient_name` / `patient_gender` 仍在、仍必填），变的是**值域约束**：
三个 Schema 上 `patient_name` 的 `"minLength": 1` 全部删掉。触发：
`DOCTOR-BACKEND-ISSUES-2026-10-16.md` 之后的**追加两条复核**（N1「`minLength: 1` 与『查不到给空串』自相矛盾」、
N3「并发那条出口没有端到端门禁」）。

### 变更

- `data-queue.schema.json` / `data-doctor-patient-records.schema.json` / `data-record.schema.json`：
  `patient_name` **不再设 `minLength`**（`patient_gender` 本来就没设）。字段**仍在 `required` 里** ——
  「字段永远在」与「值可能为空串」不矛盾，这两句必须同时成立。
- `data-doctor-patient-records.schema.json` 头注释的「三个不变式」更正为「五个不变式」（描述性修正，无形状影响）。

### 为什么

- **空串是真实可达的**：`appointment.patient_id` **没有外键**（`schema.cj` 里 `FOREIGN KEY` / `REFERENCES`
  零命中），门诊库一旦出现孤儿引用（患者档案迁移 / 历史数据带进来的 id），服务端按既定口径给**空串**
  （`http_p4.cj` 的 `putPatientInto`：形状不随数据在不在变化，不省字段）。那条路径上的响应就会
  **合规地**违反 `minLength: 1` —— 约束和实现两者必有一错。
- **门禁抓不到它**：样例是 `export-contract` 在真库上导的，当时 `orphan_appointments = 0`、
  `orphan_records = 0`，而 `json-schema-lite.ps1` 的 `minLength` 校验只跑样例 ⇒ 它**永远**不会红。
  一个只在「库刚好干净」时才成立的约束，比没有约束更坏：它给人「已经校验过」的错觉。
- 另一条路（查不到就省字段）被否：`data-queue.schema.json` 把 `patient_name` 列进了 `required`，
  省字段直接违约；而且会破坏「形状不随数据在不在变化」这条纪律。
- 现在这条路径由**夹具**钉住（不再靠「库里刚好没有孤儿引用」）：`server/tests/emr-check.ps1` 造一张
  `patient_id` 指向不存在患者的挂号单，断言该医生队列里 `patient_name == ''` 且 `patient_gender == ''`。

### 客户端影响

- **`patient_name` / `patient_gender` 可能是空串，这是合法值**，不是解析失败、也不是服务端 bug。
  显示不出来时请回退到 `#<patient_id>`（`patient_id` 一直在），不要渲染成 `null` / `undefined` / 空白行。
- **不要**试图用「字段缺席」与「空串」区分「有没有这个患者」：服务端**不省字段**，两种情况都是空串。

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

## 2026-10-15 —— 改进 6：就诊时间线与显式状态机（67 条样例 / 27 个 Schema）

**新增 8 条样例**（`doctor-visit-arrive-200` / `doctor-visit-waiting-200` /
`doctor-visit-start-200` / `doctor-visit-finish-200` / `doctor-visit-no-show-from-arrived-200` /
`doctor-visit-arrive-repeat-409` / `doctor-visit-start-skip-409` / `doctor-visit-finish-not-locked-409`），
**改 6 条既有样例**（5 条挂号类 + 医生队列）⇒ 覆盖 `docs/CLINIC-LOOP-IMPROVEMENTS-2026-10-14.md` §改进 6。

### 变更

- `POST /api/v1/doctor/visits/:id/arrive`、`POST /api/v1/doctor/visits/:id/waiting`：**两个新端点**。
  响应体是同一份「就诊状态 + 完整时间线」（新 Schema `data-visit-state`）：
  `appointment_id` / `status` / `status_label` / `arrived_at` / `started_at` / `finished_at` /
  `visit_date` / `period` / `seq_no` / `record_status` / `record_filled`。
- `status` 的合法取值扩到 **7 个**：`booked` / `arrived` / `waiting` / `visiting` / `done` /
  `cancelled` / `no_show`。⚠ `data-queue` 的枚举原先写的是 `finished`，而服务端常量一直是
  `done` —— 那时样例里只有 `booked`，所以没人发现；本次一并修正（这正是"契约要把枚举钉住"的意义）。
- 所有挂号类响应（新建 / 幂等重放 / 反查 / 退号）**新增** `status_label` 与
  `arrived_at` / `started_at` / `finished_at`（三个 epoch 秒，`0` = 这一步还没发生）。
- 医生队列（`GET /api/v1/doctor/visits`）的每个 item 新增同样四个字段；**排序规则变化**：
  `arrived`/`waiting`（待医生处理）排在最前，其内按 `seq_no` 升序。
- `POST /visits/:id/start` 的**前置状态收紧**：只能从 `waiting` 开始（原先是 `booked`，
  于是"人还没到就被叫号"在服务端是合法的）。
- 非法流转 ⇒ `409 VISIT_BAD_STATE`；完成就诊但病历未锁定 ⇒ `409 EMR_NOT_LOCKED`（均沿用既有业务码）。
- 三个时间戳在样例里**归一化为 0**：它们是"跑一次就变"的绝对时刻（与 `created_at` 同类）。
  这**不代表**它们不重要 —— 语义（哪一步写哪个戳、别的不许写、被拒的流转一个都不写）由
  `hospital-server.exe accept` 的 AC-P4-8 与 `server/tests/visit-timeline-check.ps1` 逐字段钉住。

### 为什么

- 原状态机把"挂号 → 接诊"压成一步（`booked → visiting`），到院时间、候诊时长、
  接诊时长三个机构最关心的量**没有地方落**。改进 6 要求把"谁几点到、几点开始看、几点看完"
  变成数据，并且把流转规则写成**显式矩阵**（原来散在各端点的 `allowFrom` 数组里，
  一处松动就会漏）。触发文档：`docs/CLINIC-LOOP-IMPROVEMENTS-2026-10-14.md` §改进 6。
- 退号仍然**只允许 `booked`**（`arrived` 之后不退号）。规格矩阵里写的是 `arrived → cancelled` 也放行，
  但写入侧的 `UPDATE … WHERE status = 'booked'` 是硬编码的 —— 两处不一致就是本仓反复踩的病，
  且到院之后号源已被消耗，退号本就该走人工/管理员路径。这条差异记录在该文档 §改进 6 的实施状态块。

### 客户端要不要动

- **医生端（必须改）**：① 接诊流程从 `start` 一步变成 `arrive → waiting → start → finish`
  （界面上是"确认到院 → 入候诊 → 叫号接诊 → 完成"）；② `status` 分支里新增 `arrived`/`waiting`
  两个取值，并且**必须**用 `status_label` 显示中文（不要自己抄一份映射表）；
  ③ 队列现在是服务端排好序的，客户端**不要再按 `seq_no` 重排**（会把待处理的排到后面）；
  ④ 显示候诊/就诊时长直接用 `started_at - arrived_at`、`finished_at - started_at`，
  三个戳都是 epoch 秒，`0` 表示"还没发生"（**不是**缺字段，不要把它当 1970 年显示）。
- **患者端（建议改）**：可以按 `status` 显示"已到院 / 候诊中 / 接诊中 / 已完成"的时间线；
  `GET /appointments/by-token/:token`、挂号响应里已经带了 `status_label` 与三个时间戳。
- **管理端**：不用动（可选：把 `arrived_at`/`started_at`/`finished_at` 放进就诊看板）。

---

## 2026-10-16 —— 复核整改：降级率与红标旁路分家、分诊统计的入参不再静默回落（仍是 67 条样例 / 27 个 Schema）

**样例条数不变**，但**重导 2 条**（`admin-ai-triage-stats-window-200`、`admin-ai-triage-calls-200`），
并**收紧 2 个 Schema 的必填**。触发：`docs/CLINIC-LOOP-IMPROVEMENTS-2026-10-14.md` §八（第三方复核 D1–D8 + 提示项）。

### 变更

- `GET /api/v1/admin/ai/triage-stats` 的 `data.overall` 与 `data.groups[]`：
  **新增必填** `red_flag`（integer ≥ 0，RED_FLAG 安全旁路的行数）与 `red_flag_rate`（0..1）。
- **`degrade_rate` 的口径变了**（同一个字段名，不同的分母含义）：现在是
  "`degrade_reason` 非空**且不是** `RED_FLAG`" 的占比，也就是**只数模型侧失败**。
  旧口径把 `RED_FLAG`（规则直接判红标、压根没调模型）也算作降级，看板会在规则正常拦截时报"AI 总在挂"。
  ⚠ `admin-ai-triage-stats-window-200.json` 里 `degrade_rate` 因此**变小**（旧口径含红标行）——
  这不是回归，是口径修正；`red_flag_rate` 就是被拿出去的那部分。
- `GET /api/v1/admin/ai/triage-calls` 的 `data.items[]`：**新增必填** `red_flag_bypass`（boolean），
  与既有 `degraded` **互补**（同一判据的两个方向，不会同时为真），便于前端不解析 `degrade_reason` 字符串也能分类。
  `degrade_reason` 的枚举不变（`""` / `RED_FLAG` / `CONFIG_READ_FAILED` / `AI_DISABLED` / `INVALID_OUTPUT` / `CALL_FAILED`）。
- `GET /api/v1/admin/ai/triage-stats` 的入参校验**从静默回落改成 400 `VALIDATION_FAILED`**：
  `?from=abc`、`?from=-1`（非非负整数）、`from > to`、`to - from > 366 天` 现在都报错并给出原因；
  只有**完全不传**（空串）才用默认的"最近 24 小时"。⚠ 这四类**没有新增样例**（样例只覆盖形状，
  参数校验由 `hospital-server.exe accept` 的 AC-P3-7 与 `server/tests/ai-telemetry-check.ps1` 钉住）。
- `GET /api/v1/doctor/visits`（`data-visit-state`）**形状不变**，但"查不到就诊"分支的 JSON
  补齐了 `status_label`/`arrived_at`/`started_at`/`finished_at`（此前该分支少这三个戳）。
  当前没有样例落在那个分支，所以本条**不影响任何既有样例**，写在这里是为了让"字段缺席 vs 查不到"这一区分有出处。
- `GET /api/v1/admin/ai/triage-stats` 的排序：`?group_by=doctor` 等分组的**分组发生在内存**（语义白名单 + 参数化查询），
  文档里"列名拼进 `GROUP BY`"的注释是错的，已改（无形状影响）。

### 为什么

- **两个统计量必须分开**：混在一起时，一条"红标拦截率上升"的好消息会以"AI 降级率上升"的坏消息出现在看板上，
  运维据此去查模型 —— 查错了方向。分家之后 `degraded + red_flag + 真用上模型 = total`，是个能自洽核对的口径。
- **入参静默回落是静默错误**：`?from=abc` 回落到 24h，调用者以为拿到了自己指定的区间，数字却是另一个窗口的；
  这种错误比 400 难发现得多（400 至少吵）。跨度上限 366 天不是技术极限，而是"再宽就该做预聚合表"的界，
  否则"一次请求扫全表"只是少打几个字的事。
- 判据/统计都**只在服务端定义一次**（`triageDegradeIsFailure` / `triageDegradeIsRedFlagBypass`）：
  评测脚本此前自己写了一遍 `source != model`，两份实现迟早对不上（评测说 0.9、看板说 0.5，没人知道该信哪个）。

### 客户端要不要动

- **管理台（必须改）**：① 分诊看板的"降级率"旁边补一列"红标旁路率"（`red_flag_rate`），
  否则用户会把"降级率下降"误读成"模型变好了"；② 调用明细里用 `red_flag_bypass` 而不是解析
  `degrade_reason === 'RED_FLAG'` 来标红标行（同样的信息，少一次字符串比较）；
  ③ 分诊统计请求里 `from`/`to` 现在**可能返回 400**（非数字、倒序、超 366 天），
  按 `docs/FRONTEND-INTEGRATION.md` §3.2 的错误信封显示 `error.message` 即可 —— **不要再把它当成"空窗口"**。
- **医生端 / 患者端**：不用动（本次没有改挂号、医生工作台、就诊时间线的既有形状）。
- 兼容性：`red_flag` / `red_flag_rate` / `red_flag_bypass` 都是**纯增量字段**，
  旧客户端忽略它们即可；唯一需要重新理解的是 `degrade_rate` 的**分母含义**。

---

## 2026-10-16 —— 医生端复核整改：患者姓名上出站、既往病历排序变成契约、EMR_CHANGED 的 fields 不再缺失（仍是 67 条样例 / 27 个 Schema）

来源：医生端同学提的 `DOCTOR-BACKEND-ISSUES-2026-10-16.md`（基线 `3655143`）里的 4 条，
本条目对应其中 3 条形状/语义变更（第 4 条只是收紧 Schema 的 required，见下）。

### 变更

- **`GET /api/v1/doctor/visits`（`visits-queue-200`）**：每个 `items[]` **新增**
  `patient_name`（String，必填，查不到患者时是**空串**而不是省字段）与 `patient_gender`（String，可空串）。
- **`GET /api/v1/doctor/visits/:id/record`（`record-get-200`）**：新增同样两个字段，**可选**
  （Schema 里不进 `required`）—— 因为同一张 `data-record` Schema 还被 PUT / 锁定 / 解锁的响应共用，
  那些响应不带姓名。⚠ **空病历骨架也带**（那时姓名取自**挂号单**，骨架自己的 `patient_id` 是 0）。
- **`GET /api/v1/doctor/patients/:patientId/records`（`doctor-patient-records-200`）**：每份既往病历
  都带 `patient_name` / `patient_gender`（必填，同样空串兜底）。
- **同一条端点的排序变成契约**：由 `updated_at DESC, id DESC` 改为
  **`visit_date DESC, period DESC, id DESC`**（就诊时间倒序）。Schema 与本文都写明了这一点。
- **`envelope-error-fields`**：`error.fields.required` 由 `[updated_at, updated_by, record_id]`
  收窄为 **`[updated_at, updated_by]`** —— `record_id` 变成**可选**（只有确实存在记录行时才给）。

### 为什么

- **姓名（★★★）**：在此之前，`patient.name` **全仓没有任何地方读过** —— 医生端三条接口都只回
  `patient_id`，工作台的「患者栏」只能写「患者 #700001」，医生在诊室里认不出人。
  而改进 2 的设计（`docs/CLINIC-LOOP-IMPROVEMENTS-2026-10-14.md:186`）本来就要求患者栏显示**姓名/性别**
  ⇒ 这是**遗漏**，不是刻意的最小化。边界保持不变：患者侧端点与 `/admin/dashboard` 仍然不出姓名
  （看板的禁用词表 `acceptance_p4.cj:428` 里就有 `patient_name`），姓名只给「本人 + 接诊医生」。
- **排序（★★）**：`updated_at` 是「这份记录最后一次被写」的时间。解锁 → 重写 → 再锁定会刷新它，
  于是一份**旧就诊**的病历会被顶到既往列表最前面 —— 医生看到的顺序取决于「管理员今天解锁了哪一份」，
  与就诊先后无关。改用就诊时间后，顺序只随就诊事实变化。
- **`fields` 缺失（★★★）**：`PUT …/record` 的冲突有**两条出口**。流行的乐观锁那条
  （`expected_updated_at` 与库里不符）一直会填 `updated_at`/`updated_by`；但「两条请求同时首次保存」
  撞唯一键 `uk_medical_record_appointment` 的那条，此前只回读 `recordId`/`locked`，
  **不回填** `updated_at`/`updated_by` ⇒ 它吐出的 409 没有 `error.fields`，
  而它的契约（`envelope-error-fields`）说 `fields` 必填 —— 客户端读 `fields.updated_at` 会拿到 `undefined`。
  现在两条出口填**同一组值**（来自「当前库里那一版」或「刚建出来的那一版」）。
- **`record_id` 为什么改成可选（★）**：它不是「一定有」的东西 —— 真正读到了那一行才有。
  契约要么说「一定有」（那就得在拿不到时编一个假值），要么说「可能有」。选后者：
  **缺字段比假字段好**（`http_p4.cj:316-318` 的既有纪律）。

### 客户端要不要动

- **医生端（必须改）**：① 队列行 / 工作台患者栏改用 `patient_name`（`patient_gender` 可空）；
  ② 既往病历列表**不要再自己排序** —— 服务端已按就诊时间倒序，客户端重排会把它排回去；
  ③ 收到 409 `EMR_CHANGED` 时 `fields.updated_at` / `fields.updated_by` **一定在**，
  `fields.record_id` **可能不在** ⇒ 解析时要按可选处理（否则会出现"打不开的冲突弹窗"）。
- **患者端 / 管理台**：不用动（本次没有改它们的任何形状；看板口径没变）。
- 兼容性：三个新增字段都是**纯增量**，旧客户端忽略即可；**唯一需要重新理解的是既往列表的顺序**。

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
