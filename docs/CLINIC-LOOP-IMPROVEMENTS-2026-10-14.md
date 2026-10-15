# 门诊闭环与工程质量改进方案（2026-10-14）

> **来源**：第三方复查给出的 7 条改进方向（高 5 / 中 2）。
> **本文做什么**：把每条方向拆成**后端要改什么**、**前端要改什么**（鸿蒙患者端 / 鸿蒙医生端 / 管理台 / 安卓患者端），
> 并给出**接口契约**、**验收标准**、**投入与依赖**。
> **本文不做什么**：不做排期承诺、不做设计稿（视觉走 `docs/鸿蒙app分工.md` 里 C 的规范）。
>
> **阅读指引**：服务端同学看 §一 与每条的「后端任务」；鸿蒙 A（患者端）看 1/4/6 的前端部分；
> 鸿蒙 B（医生端 + 管理端）看 1/2/3/6/7 的前端部分；C（公共模块）看 §五「契约」与 §四「公共约定」；
> 安卓同学看 4/5 的安卓部分。
>
> ⚠ **先读 §一 现状基线**：7 条里有 3 条（1/4/6）的**一半已经做完了**，
> 不知道这一点的后果是把已有的再实现一遍，或者把"其实已经有幂等"当成缺口去改契约。

---

## 一、现状基线（2026-10-14 实测，逐条给路径）

### 1.1 已经具备的（不要重复造）

| 能力 | 现状 | 证据 |
| --- | --- | --- |
| 鉴权与权限矩阵 | 令牌体系 + `Action` 枚举 + `can()` 单一判定入口；`X-Role` 等开发态身份头**仅回环来源**生效 | `server/src/http_app.cj:78-169`（Action 与矩阵说明）、`server/src/http_app.cj:171-191`（`actionName`）、`http_app.cj:193+`（`can()`） |
| 挂号幂等 | `client_token` 必填；`(patient_id, client_token)` 唯一索引；首次 **201**、同 token 重放 **200 回放同一张单**；退号把 `client_token` 置 NULL 以释放键 | `server/src/schema.cj:308-357`（表与唯一键、NULL 语义的完整注释）、`server/src/http_app.cj:2170-2183`、契约见 `docs/FRONTEND-INTEGRATION.md:711-746` |
| 退号幂等与诚实告警 | 重复退号仍 200；号源未归还时 `slot_restored:false` + `warning`，且**重试不会抹掉告警** | `docs/FRONTEND-INTEGRATION.md:748-795` |
| 号源防超卖 | `remain_num` 原子扣减（不发 `version` 前置条件），`SLOT_GONE` 409 | `server/src/schema.cj:289-304` |
| 病历七段 + 草稿/锁定 | `medical_record`（主诉/现病史/既往史/过敏史/体格检查/诊断/处理意见），`status = draft/locked`，`updated_by`，`UNIQUE(appointment_id)`；提交锁定校验必填段；完成就诊**要求病历已锁定** | `server/src/schema.cj:360-385`、`server/src/http_p4.cj:336-398`（PUT 草稿 / lock）、`http_p4.cj:269-283`（finish 的前置条件） |
| 病历并发冲突语义 | 409 `EMR_CHANGED`（"已被其他操作修改"） | `server/src/http_p4.cj:128-129` |
| 预问诊会话 | `previsit_session(id, patient_id, turn, form_json, created_at, updated_at)`；SSE 流 + 逐项作答 + 取单；有未完成会话数上限与超时回收 | `server/src/schema.cj:472-509`、`server/src/http_app.cj:1929-2032` |
| **预问诊 → 病历的预填桥**（⭐ 容易被当成"不存在"） | `PUT /doctor/visits/:id/record` 支持可选 `use_intake_session`；服务端按 **`WHERE id=? AND patient_id=?`** 校验"是你这个患者的单"，再把六槽位映射到病历四段（主诉；现病史＝病程+程度+伴随；既往史；过敏史），**仅在"该单还没有病历"时**写一次，已有病历一律不覆盖 | `server/src/http_p4.cj:355-372`（路由）、`server/src/domain_emr.cj:655-708`（`intakePrefill`）、`domain_emr.cj:710-722`（`saveDraftWithIntake`）、用例 `server/tests/emr-check.ps1:280-291` |
| 请求编号 | 框架 `requestId` 中间件**已装**，响应头回传 `X-Request-Id`，也接受客户端传入 | `server/third_party/qingzhou/src/requestid.cj:39-53`、`server/src/http_app.cj:2447` |
| 时间口径 | 服务端业务时间戳 = **epoch 秒**；`elapsed_ms` 是**毫秒** | `server/src/acceptance.cj:37-39`（`hNowEpoch`）、`server/src/ai_call.cj:158` |
| 服务端门禁 | 进程内 4 套件（`selftest` / `authtest` / `triagetest` / `accept`）+ **13 项** live 检查脚本汇总入口（含 `contract-check`） | `server/tests/final-verify.ps1`、`server/tests/doc-counts.ps1` |

### 1.2 真正的缺口（7 条各自指向的地方）

| # | 缺口 | 现状证据 |
| --- | --- | --- |
| 1 | 预问诊**没有绑到挂号单**；医生**看不到**问诊单内容（只有一次性"盲预填"）；预填的内容**不留来源**；触发途径是**本机存储**而非服务端查询 | `previsit_session` 无 `appointment_id` 列（`schema.cj:500-509`）⇒ 预填只按 `patient_id + session_id` 匹配，"哪张单配哪次预约"无人保证；`/api/v1/previsit/*` 三个端点全部由令牌派生 `patient_id`（**没有医生侧读端点**）；`visitQueueItemJson` 只带病历进度（`http_p4.cj:81-105`）⇒ 队列标不出"有预问诊"；`medical_record` 无来源列（`schema.cj:360-385`）⇒ 锁定后无法回答"这段是患者说的还是医生写的"；鸿蒙医生端取 session id 走**本机 `SessionStore`**（`EmrEditPage.ets:117`），该 id 由患者端写在同一台设备的登录态里、患者登出即清（`ProfilePage.ets:87`）⇒ 换设备/换账号就触发不了预填 |
| 2 | 医生**读不到**患者的既往病历（`/medical-records` 是"我的档案"，`/doctor/visits/:id/record` 只限本单） | `http_p4.cj:445-465`（患者侧）、`http_p4.cj:310-328`（本单，`visit.findForDoctor` 校验归属） |
| 3 | 病历**没有修订历史**；`reopen` 没有理由字段 | `schema.cj:373-379` 明确写着"本轮只记最后修改人，**没有**完整修订历史表，属后续"；`http_p4.cj:408-433`（reopen 只传 id 与操作人） |
| 4 | 结果不确定时缺一个"这次到底成没成"的确定性查询；业务响应里没有 `request_id`；**鸿蒙患者端的 `client_token` 只活在页面内存里** | 幂等本身已有（见上表），但只有"用同一 token 重发"这一条路径，没有按 token 反查；`BookingPage.ets:29`（`@Local bookingToken`）、`:98-125`（同号源复用、成功与 `SLOT_GONE` 时清空）⇒ **重进页面就会换一个新 token**，"继续确认同一预约"没有跨页面/跨进程保障；`ApiError.ets:1-16` 的 `ErrorCode` 15 个里没有"结果未确认"这一态。★ 对照实现：**安卓患者端已经做对了**（`SessionStore.kt:133-214` 持久化 + CAS 交接 + tombstone、`PatientRepository.kt:152-205` 成功后保留 token 与 `replayed` 标记、`MainActivity.kt:342-365` 三条结果横幅、`strings.xml:84,87`"退号未完成…"／"号源归还状态未确认…"）——鸿蒙患者端要补的就是这一套 |
| 5 | 契约只有**人读文档**，没有**可执行样例与解析测试**；客户端完全没有测试目录 | `docs/FRONTEND-INTEGRATION.md`（1724 行，人读）；鸿蒙 5 个模块下**没有** `ohosTest` / `*.test.ets`；`android-patient` 下**没有** `src/test` |
| 6 | 状态机**没有到院/候诊** | 只有 `booked / visiting / done / cancelled / no_show`（`server/src/domain_emr.cj:738-742`；`schema.cj:317` 注释口径一致） |
| 7 | AI 调用只有很粗的落库；没有"模型/模板版本/耗时/降级原因/请求编号"的关联 | `triage_stat` 只有 `created_at/source/reason_code/red_flag/department/truncated`（`schema.cj:480-491`，写入点 `server/src/triage_stat.cj:57`）；而内存里的结果**是有** `source/reason/elapsedMs` 的（`server/src/ai_call.cj:151-158`）⇒ 缺的是"落库"不是"采集" |

### 1.3 客户端基线（改动的落点）

```
entry/src/main/ets/                  EntryAbility（按角色注册功能）+ pages/Index（按路由前缀切根组件）
common-core/src/main/ets/            ApiConfig(42) / ApiError(69) / HttpClient(163) / SseClient(132)
                                     AppRouter(65) / SessionStore(188) / CommonComponents(298) / Theme(166) / JsonUtil(37)
feature-patient/src/main/ets/pages/  LoginPage / HomePage / TriagePage / PrevisitPage / BookingPage
                                     AppointmentsPage / RecordsPage / RecordDetailPage / NoticePage / ProfilePage
feature-patient/src/main/ets/data/   PatientRepository（真实 HTTP）+ MockPatientRepository（363 行，同签名假数据）
feature-patient/src/main/ets/model/  PatientModels（解析层：asRecord/asString/asNumber + PrevisitSlots）
feature-doctor/.../pages/            DoctorLoginPage / VisitQueuePage / EmrEditPage（仅此 3 页）
feature-doctor/.../data/             DoctorRepository + MockDoctorRepository（212 行）
feature-admin/.../pages/             AdminLoginPage / DashboardPage / DepartmentsPage / DoctorsPage
                                     SchedulesPage / UsersPage / AiCenterPage / KnowledgeBasePage（7 项侧栏）
server/admin-web/js/pages.js         管理台（浏览器）—— 与鸿蒙管理端是**两套**管理界面
android-patient/app/src/main/java/com/smart/hospital/patient/   MainActivity(721) / PatientRepository(385)
                                     SessionStore(237) / ApiClient / model/Models(39) —— **只有患者端**
```

必须知道的事实（这几条决定了改动的落点）：

1. `common-core/.../ApiConfig.ets:7-8` 默认 `ApiMode.LIVE`，`baseUrl = http://127.0.0.1:8091`。
   ⚠ 本机 **1024–15000 是 Windows 动态端口范围**，显式 bind 会得到 `WSAEACCES(10013)`
   ⇒ 本机联调请把服务端起在 **18092** 之类的端口，并在客户端把 `baseUrl` 指过去（不要改服务端默认端口）。
2. `PatientRepository.ets:38` / `:58` 等每个方法都先判 `ApiConfig.isMock()` 再分流到 Mock
   ⇒ **Mock 是同一套签名的并行实现**，加接口时两边都要加，否则演示路径会缺功能。
3. 客户端**没有测试工程**（鸿蒙 5 个模块下没有 `ohosTest`/`*.test.ets`，安卓没有 `app/src/test`、`app/src/androidTest`）。
   这直接决定了第 5 条（契约）的实施方式：先抽解析层，再喂样例。
4. **一套 HAP 装三端**：`entry/` 是唯一可安装模块，`EntryAbility.ets:11-31` 按 `SessionStore.getRole()`
   注册功能（doctor / admin / 否则 patient），`entry/.../pages/Index.ets:20-32` 按**路由前缀**切根组件
   （`doctor-` → `DoctorRoot`，`admin-` → `AdminRoot`，否则 `PatientRoot`）；`main_pages.json` 只有 `pages/Index`。
   规模：患者端 10 页 + 底部 5 tab（`PatientRoot.ets:26-28`）；**医生端只有 3 页**
   （登录/队列/病历，`DoctorRoot.ets:18-32`）；管理端 8 页（7 项侧栏）。
   ⇒ "医生端加一个页面"只要动 `feature-doctor` 与 `DoctorRoot` 的路由表，不必碰 entry。
5. 状态的中文与颜色映射**有两份**：`feature-patient/.../ui/Theme.ets:49-66`（待就诊/就诊中/已完成/已取消/爽约）
   与 `common-core/.../ui/Theme.ets:50-63`；病历状态映射在 `common-core/.../ui/Theme.ets:84-105`（`none/draft/locked`）。
   ⇒ 加状态必须两处一起改（建议顺手合并成一处，否则第 6 条一定会漏一处）。
6. Mock 仓库目前兼作"接口样例"：`MockPatientRepository.ets`（363 行）、`MockDoctorRepository.ets`（212 行）、
   `MockAdminRepository.ets`（543 行）、安卓 `res/values/data_strings.xml`（75 行）
   ⇒ 第 5 条要把这个角色正式接过来，不能让"样例"继续散在假数据里。

---

## 二、七条改进（逐条：后端 / 前端 / 契约 / 验收 / 投入）

### 改进 1（高）预问诊真正交给医生

**目标**：患者选的问诊单绑到本次预约；医生打开病历时直接看到摘要，可**按段采纳**，并且采纳的内容**标明"患者自述"**。

> ★ **先看清已有的那一半**（§一.1 最后一行的"预填桥"）：服务端**已经**能把问诊单映射成病历四段
> （`intakePrefill`：主诉；现病史＝病程+程度+伴随；既往史；过敏史），**已经**限定"只在该单还没有病历时写一次、不覆盖"，
> **已经**按 `patient_id` 校验"这单是不是这个患者的"。
> ⇒ 本项要补的不是"从零接通"，而是三件具体事：**① 绑定到挂号单**（哪张单配哪次预约）、
> **② 让医生看得见**（读端点 + 队列标记 + 界面，取代现在"患者端本机存 id、医生端盲预填"）、
> **③ 留下来源痕迹**（锁定后仍能回答"这段是患者说的"）。
> ⚠ 同时**不要删** `use_intake_session`：`server/tests/emr-check.ps1:280-291` 有用例，且它是"医生一键预填"的落地通道。

#### ✅ 实施状态：**服务端已实现（2026-10-14）**，与本文计划的差异如下

> 交付物：`schema.cj`（两列 + 索引 + `migrateSchema` ⑧⑨）、`previsit.cj`（`appointmentId` / `ownedBy` / `bindAppointment` / `findByAppointment` / `latestCompleteForPatient` / `IntakeSlot.label`）、
> `domain_emr.cj`（`previsit_ref` 落库 + `emrPrevisitRefJson`/`emrPrevisitRefSections`）、`http_p4.cj`（`visitPrevisitJson` + 新端点 + 队列 `previsit_ready`）、
> `http_app.cj`（挂号 `previsit_id`/`previsit_bound` + `registerP4Routes` 传 `previsit`）、`http_common.cj`（`PREVISIT_NOT_FOUND` 登记）。
> 验收：`accept` 新增 **AC-P4-5**（575 项断言全过）+ 新增 live 脚本 **`server/tests/previsit-bridge-check.ps1`（51 条）**；`emr-check` / `previsit-check` / `p1-extra-check` 回归全过。

| # | 计划 | 实际落地 | 为什么 |
| --- | --- | --- | --- |
| 1 | `previsit_ref TEXT NOT NULL DEFAULT ''` | **`VARCHAR(1024) NOT NULL DEFAULT ''`** | 实测 MariaDB 允许 `TEXT DEFAULT ''`，但 **MySQL 不允许任何 `TEXT/BLOB` 带 DEFAULT**（本项目 DSN 写的是 `mysql://`，不能赌部署在 MariaDB 上）。JSON 约 260 字符，1024 足够 |
| 2 | 跨患者 `previsit_id` ⇒ **400** | **201 + `previsit_bound=false`**（不报错） | 绑定是"附加交付物"，不该挡在挂号前面：断网重试时患者会因为一张过期的问诊单**挂不上号**。改成"挂号照常、如实告知没交上"，客户端文案「本次未提交预问诊」 |
| 3 | （未提） | `IntakeSlot` 加第 5 个字段 **`label`**（主诉/病程/程度/伴随/既往史/过敏史） | 医生看的是短名，患者看的是问句 `question`；口径与 `emrJoinParts([("病程",…),("程度",…),("伴随",…)])` 一致，避免第二套命名 |
| 4 | （未提） | 错误码表新增 **`PREVISIT_NOT_FOUND`**（404） | `http_common.cj` 的 `apiErrorSpec` 是白名单：不登记就 `throw` 不出来 |
| 5 | 绑定语句 `UPDATE … WHERE (appointment_id=0 OR appointment_id=?)` | 同样语句，但**返回值不等于"绑上了"**：0 行受影响也可能是"已经绑到同一张单"⇒ 实现里**再查一次**确认 | MySQL 的 `affected_rows` 在"值没变"时为 0，直接当失败会让幂等重放误报 |
| 6 | 队列标记 `previsit_ready` | 同左，但**只认"绑定了本单"**的会话（每行一次索引查询，队列 ≤100 行） | 用"该患者有历史会话"点亮会让所有历史行都亮徽标，徽标随即失去意义 |
| 7 | 读端点响应加 `previsit_ref` | `previsit_ref` 只在**单查（`includeSections=true`）且确有预填**时出现 | 列表页不需要它；没预填过就不给字段（而不是给空对象） |
| 8 | `previsit_ref` 由 `saveDraftWithIntake` 写入 | 同左，且**只记这次真的由预填写入的段**：医生在同一次请求里显式给出的段不算预填 | 诊断通常是医生自己填的，把它记成"患者自述"会误导 |

> ⚠ 语义提醒（已写进 `docs/FRONTEND-INTEGRATION.md` §5.18）：`previsit_ref` 是**初值来源快照**，
> 医生后续编辑**不会**改它 ⇒ 角标文案应是「患者自述（已由医生编辑）」。

#### 后端任务

1. **建绑定**：`previsit_session` 加 `appointment_id BIGINT NOT NULL DEFAULT 0` + `KEY idx_previsit_appointment (appointment_id)`。
   - 新库走 `schema.cj:500-509` 的 DDL；**存量库必须走 `migrateSchema`**（`schema.cj:803+` 的写法：查 `information_schema.COLUMNS` 再 `ALTER TABLE ... ADD COLUMN`）。理由见 `schema.cj:806-813`：`CREATE TABLE IF NOT EXISTS` 对已存在的表完全无效。
2. **绑定时机**：`POST /api/v1/appointments`（`http_app.cj:2170`）请求体加**可选** `previsit_id`。
   - 校验：`SELECT patient_id FROM previsit_session WHERE id=?` 必须等于令牌里的 `patientId`，否则 **400 `VALIDATION_FAILED`**（不区分"不存在"与"不是你的"，避免枚举）。
   - 绑定语句带条件 `UPDATE previsit_session SET appointment_id=? WHERE id=? AND patient_id=? AND (appointment_id=0 OR appointment_id=?)`（幂等回放路径也要执行一次）。
3. **医生读取**：新端点 `GET /api/v1/doctor/visits/:id/previsit`（放 `http_p4.cj`，紧跟 record 端点）。
   - 鉴权：`requireCan(p.role, Action.QueryOwnMedicalRecord)` + `visit.findForDoctor(id, p.doctorId).isNone() ⇒ 404 APPOINTMENT_NOT_FOUND`（与 `http_p4.cj:317-320` 同一口径：不区分 403）。
   - 取数口径：优先取**已绑定本单**的会话；为了兼容存量（未绑定的历史单）再回退到"该患者最近一次已完成会话"，并在响应里用 `bound: true/false` 说明是哪种，前端文案不同（"本次预问诊" vs "该患者最近一次预问诊"）。
   - 响应：`{session_id, bound, turn, completed, captured_at, sections:[{key,label,value}]}`。**不回 `patient_id`**（出站最小化）。
4. **队列标记**：`visitQueueItemJson`（`http_p4.cj:81`）加 `previsit_ready: Bool`，让医生队列页能标"有预问诊"。
5. **来源痕迹落库（关键，别只在前端加前缀）**：`medical_record` 加列 `previsit_ref TEXT NOT NULL DEFAULT ''`
   （JSON：`{"session_id":"…","sections":["chief_complaint","present_illness",…],"at":<epoch 秒>}`），
   DDL + `migrateSchema` 各一处。
   - **写入点就在 `saveDraftWithIntake`（`domain_emr.cj:716`）**：它手里正好有 `intakePrefill(sessionId, patientId)` 返回的 map，
     `map.keys()` 就是"这次真正由患者自述写入的段"，**不要**在前端或路由层另算一遍（那会出现第二个"哪些段来自预问诊"的定义）。
   - 提供 `GET /api/v1/doctor/visits/:id/record` 时把 `previsit_ref` 一并回给医生端（前端据此在段标题旁显示"患者自述"角标）。
   - 理由：要的是**可追溯**。只在输入框里拼一个「患者自述：」前缀，锁定/解锁之后就再也分不清哪段是谁写的。
6. **不加新 Action**：读写都走已有的 `QueryOwnMedicalRecord` / `WriteOwnMedicalRecord`。矩阵纪律见 `http_app.cj:96-169`：新增动作要有第二个用处，否则矩阵膨胀。

#### 前端任务

| 端 | 落点 | 做什么 |
| --- | --- | --- |
| 鸿蒙患者端 | `feature-patient/.../PrevisitPage.ets` | 会话拿到 `sessionId` 后仍写 `SessionStore`（现状），但**改为"待绑定"语义**：挂号成功、服务端确认绑定后再标记已提交 |
| | `.../BookingPage.ets` | 挂号请求带 `previsit_id`；成功后展示"预问诊摘要已交给 <医生>"；未带时显示"本次未提交预问诊"（**不要把"提交了会话 id"当成"医生看到了"**） |
| | `.../model/PatientModels.ets` | `PrevisitSession` 加 `appointmentId`；挂号请求模型加可选 `previsitId` |
| 鸿蒙医生端 | `feature-doctor/.../EmrEditPage.ets` | ① 顶部「患者自述（预问诊）」折叠卡片（数据来自新读端点，**不再依赖本机 `SessionStore`**）；② 每段旁「采纳到本段」——**追加**到该段末尾（已有内容不覆盖）；③ 保留现有「一键预填」按钮，但提示改成"仅首次保存生效，已有病历不会覆盖"（现状文案见 `EmrEditPage.ets:156-184`）；④ 有 `previsit_ref` 的段显示「患者自述」角标 |
| | `feature-doctor/.../VisitQueuePage.ets` | 行内「预问诊」徽标（用 `previsit_ready`） |
| | `feature-doctor/.../data/DoctorRepository.ets` + `MockDoctorRepository.ets` | 新增 `getVisitPrevisit(appointmentId)`；`EmrRecord` 加 `previsitRef` 字段（`DoctorModels.ets:33-48`），**Mock 同步加假数据**（见 §一.3 事实 2） |
| 鸿蒙患者端（可选） | `feature-patient/.../PrevisitPage.ets` | 完成后**展示已采集的六项内容**（现状只显示"六项信息已采集完成，预问诊单已生成。"，`PrevisitPage.ets:160-162`）——否则患者无从确认自己填了什么，也无法理解医生看到的摘要 |

#### 验收

- 进程内（`server/src/acceptance_p4.cj` 风格新增 AC）：① 跨患者 `previsit_id` ⇒ 400；② 绑定后本单医生读得到且 `bound=true`；③ 另一位医生读 ⇒ 404；④ 未绑定但该患者有历史会话 ⇒ `bound=false`；⑤ 采纳后 `medical_record.previsit_ref.sections` 落库且**与 `intakePrefill` 实际写入的段一致**（用同一个 map 推导，别两处各写一遍）；⑥ 锁定后仍可读。
- live：`server/tests/previsit-check.ps1` 扩 3 条（现有 86 项）、`emr-check.ps1` 补 1 条（`use_intake_session` 的既有用例不得回归），并入 `final-verify.ps1` 汇总表。
- 手工：挂号（带 previsit_id）→ 医生队列出现徽标 → 进病历 → 看到自述 → 采纳 → 保存 → 锁定 → 重开仍能看到「患者自述」角标。

**投入**：后端 1.5 人日 / 医生端 1.5 人日 / 患者端 0.5 人日。**依赖**：§四 的 request_id 与时间口径约定（先定后写）。

---

### 改进 2（高）改善医生录入工作台

**目标**：同屏看到**本次问诊 + 既往记录**；分段导航、未保存提示、保存时间、提交前预览。

#### 后端任务

1. **新增医生读既往病历的端点**（现在根本没有）：`GET /api/v1/doctor/patients/:patientId/records?limit=5&exclude_appointment_id=`。
   - **隐私边界（必须先定）**：仅当该患者在该医生名下**至少有一条** appointment 时放行，否则 404（不区分 403，避免"这个患者是否存在/是否看过病"的枚举面）。SQL 里做归属判断，不在应用层"先读再比"（同 `http_p4.cj:467-475` 的纪律）。
   - 只返回 `status='locked'` 的病历（草稿是医生个人的工作稿，给另一个医生看会造成"未定稿当结论"，口径见 `http_p4.cj:473-474`）。
   - 正文全给（`medicalRecordJson(m, true)`），上限 20，返回带 `count`。
2. **乐观锁（支撑"未保存提示"与并发）**：`PUT /doctor/visits/:id/record` 支持可选 `expected_updated_at`；与库里 `updated_at` 不一致 ⇒ 409 `EMR_CHANGED`（语义已存在，`http_p4.cj:128-129`），并回带**当前**的 `updated_at`/`updated_by` 让前端能提示"已被 X 修改"。
3. **自动保存**不需要新端点（PUT 已是幂等 upsert，`http_p4.cj:331`），但要在契约里写明"重复 PUT 同内容是允许的、不会产生版本"。
4. 队列页分组所需的排序与过滤由服务端给（见改进 6），不在客户端排。

#### 前端任务（医生端，主战场）

- `EmrEditPage.ets` 重排：
  - 患者栏（固定顶部或左栏）：姓名/性别/就诊日/序号 + **预问诊摘要卡**（改进 1）+ **既往就诊列表**（点开只读对比）；
  - 七段表单 + **段锚点导航**（主诉…处理意见），滚动联动高亮；
  - 顶部状态条：`已保存 14:03:21`（用响应 `updated_at`，按 §5.25 的 Asia/Shanghai 口径格式化）/ `未保存改动`（本地脏标记）/ `重新加载`。
- **离开保护**：`NavDestination` 返回 / 切页时若有脏数据 ⇒ 弹「放弃改动 / 继续编辑」。
- **提交前预览**：七段只读汇总 + 缺段提示（直接用服务端 `missing_required`，`http_p4.cj:53-58` 已经给了）。
- **冲突处理**：收到 409 `EMR_CHANGED` ⇒ 保留本地输入 + 展示"服务端最新版"，人工确认后再提交（不要在后台静默覆盖）。
- `VisitQueuePage.ets`：动作按钮随状态变化（`开始接诊` / `完成就诊` / `爽约`，端点已存在）。

#### 验收

- 后端：新端点权限矩阵（同科不同医生、跨科医生、患者三种身份的返回）；乐观锁 409；只回 locked。
- 前端：断网/杀进程后重进，草稿仍在（服务端 PUT 幂等）；两处并发改 ⇒ 后提交者拿到 409 并保留输入；预览内容与已保存内容一致（逐段比对）。

**投入**：后端 1 人日 / 医生端 3 人日。**依赖**：改进 1（摘要卡）、改进 3（版本历史入口同页）——建议 2 与 3 排同一条线，先 2 后 3。

---

### 改进 3（高）保留病历修订历史

**目标**：定稿时保存**不可变版本**；记录解锁**理由、操作者和时间**；能看前后两版。

#### 后端任务

1. **新表** `medical_record_revision`：
   ```sql
   id BIGINT AUTO_INCREMENT PK,
   record_id BIGINT NOT NULL, appointment_id BIGINT NOT NULL, version BIGINT NOT NULL,
   status VARCHAR(16) NOT NULL,            -- 快照产生时的病历状态（locked/draft）
   sections_json TEXT NOT NULL,            -- 七段正文快照（含空段，便于逐段 diff）
   operation VARCHAR(24) NOT NULL,         -- lock / reopen / archive（预留）
   reason VARCHAR(255) NOT NULL DEFAULT '',
   operator_user_id BIGINT NOT NULL, operator_role VARCHAR(16) NOT NULL,
   created_at BIGINT NOT NULL,
   UNIQUE KEY uk_rev (record_id, version), KEY idx_rev_appt (appointment_id, version)
   ```
   - 加进 `SCHEMA_DDL` **并**加进 `ALL_TABLES`（`schema.cj:210-216`）。
     ⚠ **会触发 selftest 的表数分项断言**（`main.cj:331` 的注释说明"加表必须同步改"）⇒ 同一提交里改断言，否则 `selftest` 变红。
2. **版本产生时机（本项最容易做歪的地方，先定死）**：
   - `record/lock` ⇒ 写入 `version = max+1` 的 `locked` 快照（**定稿即不可变**）；
   - `record/reopen` ⇒ 写入一条 `operation='reopen'`、带 `reason` 的审计行，并把病历状态改回 `draft`；
   - 再次 `lock` ⇒ `version+1` 的新快照；
   - **草稿保存不落版本**（否则一天几十版、体积与噪声不可控）——取舍写进文档与注释。
3. **`reopen` 增理由**（现在完全没有，`http_p4.cj:408-433`）：请求体必填 `reason`（4–255 字），`emr.reopen(id, now, userId, reason)`；缺理由 ⇒ 400。
4. **新端点**：
   - `GET /api/v1/doctor/visits/:id/record/revisions`（列表：version/status/operation/operator/reason/created_at，**不含正文**）；
   - `GET /api/v1/doctor/visits/:id/record/revisions/:version`（含 `sections`）；
   - `GET /api/v1/doctor/visits/:id/record/revisions/:version/diff?against=<version>` ⇒ 返回 `[{key,label,before,after,changed}]`。
     **diff 放服务端**：七段 diff 若让三个客户端各写一遍，迟早出现三种"哪里变了"。
5. **权限**：新增 `Action.ManageRecordRevision`（管理员：解锁 + 读全部审计），医生读本单版本走 `QueryOwnMedicalRecord`。
   这条动作**有第二个用处**（解锁 + 审计读），符合 `http_app.cj:96-169` 的"按语义分"纪律。
6. **存量数据**：上线时对已有 `status='locked'` 的病历补 v1 快照，幂等 SQL（`INSERT ... SELECT ... WHERE NOT EXISTS`），放 `migrateSchema`。
7. **容量估算**：单份七段 ≈ 2–4 KB；按 60 单/天、每单 1–2 版 ≈ 0.5 MB/天 ⇒ 不需要归档策略，但要在表注释里写清。

#### 前端任务

- 医生端 `EmrEditPage.ets` 加「版本历史」入口 → 抽屉：
  - 列表行：`v2 · 2026-10-14 15:02 · 张医生（医生）· 已锁定`；`解锁`行显示理由（必填内容）；
  - 点开 ⇒ 只读查看该版本七段；
  - 「与上一版对比」⇒ 逐段高亮变化（直接用服务端 diff，不要自己算）；
- 「解锁」对话框强制填理由（≤255），提交按钮在理由为空时禁用；
- 管理端（可选）：管理员在管理台按挂号单查审计（复用同一端点，权限 `ManageRecordRevision`）。

#### 验收

- 进程内 AC：锁定 ⇒ v1；解锁（带理由）⇒ 审计行；改动后锁定 ⇒ v2；diff 结果与预期逐段一致；另一位医生读 ⇒ 404；revision 表不被 PUT 影响（写一次 PUT 草稿，断言版本数不变）；`updated_by` 与 `operator_user_id` 一致。
- live：`server/tests/emr-check.ps1` 扩展（现有 54 项）。
- 手工：两版对比界面能看出"诊断"变了而"主诉"没变。

**投入**：后端 2.5 人日 / 医生端 2 人日。**依赖**：无（可与 1 并行）；但与 2 同页，建议 2 先 3 后。

---

### 改进 4（高）让患者看懂操作结果

**目标**：网络中断时显示"预约结果尚未确认"，提供"继续确认同一预约"；复用现有幂等机制。

> ⚠ 先说清两件事：
> ① **幂等机制已经有了**（`client_token`，201/200 回放，`FRONTEND-INTEGRATION.md:711-746`）；
> ② **安卓患者端已经把这套用对了**——token 持久化 + 状态 CAS + "结果未确认"文案全都在（见下表最后一行的路径）。
> ⇒ 真正的缺口只有两个：鸿蒙患者端的 token **只活在页面内存里**（`BookingPage.ets:29,98-125`，重进即换新 token），
> 以及服务端少一个"按 token 反查"的出口。**安卓端基本不用改**，它的实现反过来就是鸿蒙的参照物。

#### 后端任务（小）—— ✅ **已实现（2026-10-14）**，下面留原文 + 落地说明

1. ✅ **反查端点已上线**：`GET /api/v1/appointments/by-token/:token`（患者身份；`patientId` 取自令牌并与 token 组合查询）
   ⇒ 200 单 / 404（无此 token，或已退号释放）/ 400（空 token、或 > 64 字符）/ 403（非患者）。
   实现 `server/src/http_app.cj`（`repo.findAppointmentByToken` 复用 `domain_booking.cj:310-322`，
   此方法**本已存在**，只是此前只有"重提交"一条路径在用它）。契约见 `docs/FRONTEND-INTEGRATION.md` §5.27。
2. ✅ **响应已补两个字段**（挂/退号相关端点，含 `slot_restored:false` 特例）：
   `server_time`（epoch 秒，与 §一.1 口径一致）与 `request_id`。
   ⚠ 落地细节与原文有一处不同：框架**没有** `ctx.id()` 访问器，请求编号是 `Context` 的公开字段 **`ctx._id`**
   （由 `requestId()` 中间件填充，见 `third_party/qingzhou/src/context.cj:53`）；中间件未装配时它是空串，
   服务端**不自己编一个**（编一个日志里查不到的编号比留空更坏）。另一个边界：
   **错误信封不带 `request_id`** —— 从失败响应取编号请读**响应头** `X-Request-Id`。
3. ⏳ **契约写死"message 面向用户"**（`SLOT_GONE`、`APPOINTMENT_NOT_CANCELLABLE` 的中文 message 直接展示）：
   已在 `FRONTEND-INTEGRATION.md` §5.16/§14.2 有口径，本轮**未**新增文字（属文档口径，不改代码）。
4. ✅ **未动 200/201 语义**：幂等回放仍是 200 + 同一 `appointment_id`（`p1-extra-check.ps1` 已把这条钉进断言）。

> **验证**：`server/tests/p1-extra-check.ps1` 新增 9 条断言（挂号响应带 `request_id`/`server_time`、
> 同 token 重提交 200 且 id 相同、by-token 命中同一 id、未知 token 404、65 字符 token 400、
> 管理员 403、反查响应带两个溯源字段）。**实跑 PASS，失败 0**（`P1-EXTRA-EXIT=0`）。

#### 前端任务（本项主战场）

| 端 | 落点 | 做什么 |
| --- | --- | --- |
| 鸿蒙患者端 | `BookingPage.ets:29,98-135` + `common-core/.../SessionStore.ets`（或新建 `PendingBookingStore`） | 把 `@Local bookingToken`（内存）改为**按号源持久化**：提交前生成并落盘、成功后**保留**（用于重试识别同一单）、退号后清除、换号源换新 token。可直接照搬安卓的四条语义（见末行） |
| | `BookingPage.ets:116-125` | 现在只对 `SLOT_GONE` 特判、其余走 `apiError.userMessage()`（兜底"请求失败，请稍后重试"）：改为**区分"结果未确认"**（超时/断连/5xx/`NETWORK_ERROR`/`SSE_INCOMPLETE`）⇒ 显示「预约结果尚未确认」+ 两个动作：**继续确认同一预约**（同 token 重发）/ **查询这次请求的结果**（by-token GET）。**不出现"重新挂号"**（换 token 会重复占号） |
| | `common-core/.../network/ApiError.ets:1-16` | `ErrorCode` 15 个里没有"结果未确认"这一态 ⇒ 新增（例如 `BOOKING_UNCONFIRMED`）并给出面向用户的文案；**不要**复用 `NETWORK_ERROR` 的通用文案（那会让用户以为"没提交，重来就行"） |
| | `HomePage.ets` / `AppointmentsPage.ets` | 冷启动若发现未确认的 pending 记录 ⇒ 顶部卡片「有一次未确认的预约」 |
| | `common-core/.../ui/Theme.ets:50-63`（**合并** `feature-patient/.../ui/Theme.ets:49-66`） | 状态人话映射：`booked`=已预约 / `visiting`=接诊中 / `done`=已完成 / `no_show`=爽约 / `cancelled`=已退号（现在两份，先合并成一处，见 §一.3 事实 5） |
| 安卓患者端 | `SessionStore.kt:133-214`、`PatientRepository.kt:152-205`、`MainActivity.kt:342-365`、`res/values/strings.xml:84,87` | **已完成，作为参照**：① `bookingToken(scheduleId)` 用 preferences 持久化并在读取时校验（`:140`）；② `markBookingCompleted` / `markBookingReplacementIfCurrent`（A→B 交接 CAS，`:166-189`）/ `clearBookingIfCompleted`（tombstone，保留 token，`:191-214`）；③ `replayed = status == 200 \|\| knownId == appointmentId`（`:189`）且**成功后仍保留 token**（`:193` 有注释）；④ 三条结果横幅（成功/回放/`booking_result_status`）与 `appointmentOutcomeWarning`（`:348`）。本项只需**接上新端点**（by-token 反查）——若暂不做 UI，至少把它用于"结果未确认"时的一次静默对账 |

`slot_restored:false` + `warning` 必须原样展示（不要让用户反复点退号），口径见 `FRONTEND-INTEGRATION.md:760-769`；安卓已有 `cancel_incomplete` / `cancel_restore_unconfirmed` 两条文案可直接抄。

#### 验收

- live/脚本：同 token 连发 3 次 ⇒ 库里只有 1 张单，后两次 200 且 `appointment_id` 相同；by-token 反查命中同一 id。
- **"响应丢失"演练**：`curl` 发出挂号后**丢弃响应**（不管返回值），再用 by-token 反查 ⇒ 能拿到那张单（证明"结果未确认"可收敛）。
- 客户端：断网重试 UI 走查（打开飞行模式提交 → 关闭 → 点"继续确认"）；**杀进程重进**后仍能"继续确认同一预约"（这是鸿蒙现在做不到的那一条）。

**投入**：后端 1 人日 / 患者端（鸿蒙）1.5 人日 / 安卓端 0.5 人日（只接反查端点）。**依赖**：无。**建议最先做**（收益/投入比最高，且不动状态机）。

---

### 改进 5（高）把接口约定变成可执行契约

**目标**：登录、挂退号、预问诊、病历四组接口有**共享响应样例与解析测试**；每个测试独立准备夹具。

**做法一句话**：**样例由服务端真实响应导出**（不是手抄），鸿蒙与安卓**吃同一批样例**跑解析测试；契约一变，三端同时红。

#### ✅ 实施状态：**服务端已实现（2026-10-15）**，与本文计划的差异如下

| # | 计划 | 实际落地 | 为什么 |
| --- | --- | --- | --- |
| 1 | `contract/schema/*.json` 一层 Schema 管到底 | **19 个 Schema 分两层**：8 个 **body 级**（含 `artifact` —— 钉住样例文件**自身**的结构）+ 11 个 **data 级**（`data-*.schema.json`，只校 `response.body.data`），映射表 `contract/schema-map.json` | `data` 才是客户端真正吃的东西；分层后新增端点常能复用 body 级 Schema，只补一个 data 级 |
| 2 | 门禁"要求显式 `-Fix` 更新契约" | 更新契约 = **不带 `-Check`** 跑导出机（写盘）；门禁只有"比对"、**没有** `-Fix` | 一个开关同时表示"检查"和"顺手改掉"极易误提交；写盘必须显式、单独一步 |
| 3 | "三种失败形状"（§3.2） | 实测 **5 种**：业务信封 / 非法 JSON 平铺 **400** / 静态平铺 **404** / **405 + `Allow` 头** / `/health`（第四种**成功**形状）；且 **API 未匹配路由现在是信封 404 `ROUTE_NOT_FOUND`**，**不再**是平铺 | 实测（`PUT /health`、故意打错路径）暴露旧文档漏了 405、且 404 形状**已过期** —— 契约机制第一次运行就纠正了文档（详见 `contract/README.md` §8） |
| 4 | 分页与上限"有样例" | `admin-users-page-clamped-200` 的 `data.items/count/total` 声明为 **volatile**（值写 `"<volatile>"`），只钉形状与夹取后的 `limit/offset` | 这三项内容依赖整库状态，钉死会让 golden 每次都变 —— 用**显式登记的逃生口**，而不是掩盖不稳定（`contract/README.md` §3） |
| 5 | 并入 `final-verify.ps1`（11 → 12+ 项） | 实际 **12 → 13 项**，且 `contract-check` **必须排在 `p1-extra-check` 之前** | `p1-extra-check` 会重设管理员口令，而导出机要用 final-verify 现场生成的那个口令登录 |
| 6 | —— | 额外加**登记完整性双向校验**：有样例没登记 ⇒ 失败；登记了不存在的 Schema ⇒ 失败 | 否则新端点可以只加样例、不登记 Schema，悄悄绕过契约 |
| 7 | —— | Schema 校验器自研（`server/tests/json-schema-lite.ps1`），**遇到不认识的关键字直接 throw** | PS 5.1 没有 `Test-Json`；且写错的 Schema 必须报错，不能静默"通过" |

**验收（反证）已做**（这是本文 §验收 要求的"必须做"那条，只是用服务端门禁先做了一遍）：
故意改样例里的一句错误文案 ⇒ 门禁红（`[DIFF] error-route-not-found-404.json 行 16`，exit 1）；
删掉 `health-200` 的必填 `timezone` ⇒ Schema 红（`缺必填字段 'timezone'`，exit 1）；还原 ⇒ **38 条全绿**。

**鸿蒙端/安卓端任务不变**（见下）。服务端侧**已完成**：客户端接入时 `contract/examples/` 是可直接吃的样例源。

#### 后端任务

1. **目录约定**（仓库根，跨端共享）：
   ```
   contract/examples/*.json     # 真实响应样例（4 组 × 3~6 个：成功 + 400/401/403/404/409 + 幂等回放 + 边界）
   contract/schema/*.json       # JSON Schema（类型/必填/枚举）
   contract/CHANGELOG.md        # 契约变更记录（谁、何时、改了哪个字段）
   ```
2. **导出机**：`server/tests/export-contract.ps1` —— 起服务端 → 按固定请求序列打真实请求 → 写 `contract/examples/*.json`。
   - 必须**归一化**：把 `id`、`token`、`created_at`、`request_id` 等易变字段替换为占位（否则 golden 每次都变，测试变成噪声）；
   - 键排序后写盘，保证 diff 可读。
3. **门禁**：`server/tests/contract-check.ps1` —— ① 重新导出与已提交样例逐字节比对（不一致 ⇒ 失败，并要求显式 `-Fix` 更新契约）；② 用 `contract/schema` 校验样例。并入 `final-verify.ps1`（现 11 项 → 12+ 项）。
4. 四个"必须被契约覆盖"的点（都在 `docs/FRONTEND-INTEGRATION.md` 里有描述，但没有样例）：
   - **三种失败形状**（§3.2）：业务错误信封、框架 404（`{"error":"Not Found"}`）、静态 404；
   - **信封与业务码的对应**（§3.3）；
   - **时间口径**（§5.25 Asia/Shanghai 的"今天" vs epoch 秒）；
   - **分页与上限**（§3.5）。

#### 鸿蒙端任务

1. **抽解析层**：把现在散在 `PatientRepository.ets` / 各页面里的 `asRecord/asString/asNumber` 取字段代码收敛到 `common-core/src/main/ets/dto/`（响应 → 模型），使"喂一段 JSON 得到模型"成为可测函数。
   （现在 `feature-*/model/*Models.ets` 只有类型 + 工具，映射写在仓库类里，**不可注入、不可测** —— 这是要先动的地方。）
2. **契约测试**：`common-core/src/ohosTest/ets/test/ContractParse.test.ets`，读 `contract/examples/*.json`，逐样例断言：字段齐全 + 类型正确 + 缺可选字段时的降级行为（例如 `missing_required` 缺席时按空数组处理）。
3. **夹具独立**：每个测试用例自带独立前置数据（沿用 `server/tests/*.ps1` 里 `$CleanPrefixes` 的做法：不同前缀的科室/医生/排班），不要共用"9 号医生"这类固定 id。

#### 安卓端任务

`android-patient/app/src/test/java/com/smart/hospital/patient/ContractParseTest.kt`：读同一批 `contract/examples/*.json`，断言 `Models.kt` 解析结果与鸿蒙端一致（同一字段名、同一空值语义）。

#### 验收

- **反证（必须做）**：故意把样例里 `appointment_id` 改成 `appointmentId` ⇒ 服务端 `contract-check` 红、鸿蒙契约测试红、安卓契约测试红；改回 ⇒ 三处全绿。不做这条，"契约测试"很可能在空转。
- 新加入的接口（改进 1/3/6/7）在合入时**必须**同时更新 `contract/examples` 与 `CHANGELOG.md`。

**投入**：服务端导出机 + 门禁 2 人日 / 鸿蒙 dto 抽取 + 测试 2.5 人日 / 安卓 1 人日。
**依赖**：无，且**应最先做**——它是改进 1/3/6/7 的公共地基。

---

### 改进 6（中）补到院与候诊环节

**目标**：先做明确的到院确认，再区分**待到院 / 已到院 / 接诊中 / 完成**；患者同步看到状态。

#### 后端任务

1. **状态机扩展**：`domain_emr.cj:738-742` 增 `VISIT_ARRIVED = "arrived"`、`VISIT_WAITING = "waiting"`，并把 `visitTransitionAllowed` 写成**显式流转表**：
   ```
   booked  → arrived | cancelled | no_show
   arrived → waiting | cancelled | no_show
   waiting → visiting | no_show
   visiting→ done（要求病历已锁定，已有约束）
   ```
   `done / cancelled / no_show` 为终态。**一次性写成矩阵 + 逐格单测**（现有 AC 就是这种风格）。
2. **端点**（动作名即业务动作，别做成通用的 `set-status`）：
   - `POST /api/v1/doctor/visits/:id/arrive`（到院确认）
   - `POST /api/v1/doctor/visits/:id/waiting`（进入候诊）
   - 权限：`Action.ManageVisit`（医生本人，`visit.findForDoctor` 校验归属）。
3. **时间戳列**：`appointment` 加 `arrived_at`、`started_at`、`finished_at`（BIGINT，默认 0）——患者端时间线、运营统计都要用；DDL + `migrateSchema` 各一处。
4. **队列排序由服务端给**：`GET /api/v1/doctor/visits`（`http_p4.cj:226`）改为 `arrived/waiting` 优先、`seq_no` 升序；不要让三个客户端各排一遍。
5. **谁确认到院**：**先做医护侧确认**（医生端；管理台可选）。患者自助签到列为"暂不做"（见 §六）——它需要当天窗口、频率限制、设备绑定等一整组约束，否则等于开放的代刷接口。
6. **测试**：状态矩阵逐格 allow/deny；非法流转 ⇒ 409 `VISIT_BAD_STATE`（映射已存在，`http_p4.cj:546-553`）；退号仍只允许 `booked`。

#### 前端任务

| 端 | 落点 | 做什么 |
| --- | --- | --- |
| 医生端 | `VisitQueuePage.ets` | 按状态分组（待到院 / 已到院 / 候诊中 / 接诊中 / 已完成）；行内动作随状态变化（确认到院 → 进入候诊 → 开始接诊 → 完成就诊 / 爽约）；显示序号、就诊日、预问诊徽标 |
| 患者端 | `AppointmentsPage.ets`、`RecordDetailPage.ets` | 状态时间线（已预约 → 已到院 → 候诊中 → 接诊中 → 已完成），用 `arrived_at/started_at/finished_at`；文案「请到 <科室> 分诊台报到」 |
| 管理台（浏览器） | `server/admin-web/js/pages.js` | （可选）看板加"今日到院率 / 当前候诊人数"，需 `dashboard` 支持 |

#### 验收

- 状态矩阵单测覆盖每一格（含"已完成不能回到候诊"这类负例）。
- live：在 `final-verify.ps1` 里新增 `visit-check.ps1`（到院 → 候诊 → 接诊 → 完成 全链路 + 两条非法流转 + 退号限制）。
- 手工：患者端能在状态变化后 30 秒内（刷新）看到新状态。

**投入**：后端 2.5 人日 / 医生端 1.5 人日 / 患者端 1 人日。**依赖**：改进 3（改状态机会牵动病历锁定的测试）+ 改进 5（新状态要进契约样例）。

---

### 改进 7（中）AI 评测与排障闭环

**目标**：用业务人员标注的案例做评测；把**模型、模板版本、耗时、降级原因**关联起来，**复用已有请求编号**。

> 关键前提：AI 结果的 `source`（rules/model）、`reason`（降级原因）、`elapsedMs` **在内存里已经有了**（`server/src/ai_call.cj:151-158`），
> `X-Request-Id` 中间件也已经在跑（`http_app.cj:2447`）⇒ 这条**主要是"落库 + 查询 + 展示"**，不是重写调用链。

#### 后端任务

1. **遥测落库**：`triage_stat`（`schema.cj:480-491`，写入点 `triage_stat.cj:57`）加列：
   `request_id VARCHAR(64)`、`model_id BIGINT`、`model_name VARCHAR(64)`、`prompt_revision BIGINT`、`elapsed_ms BIGINT`、`degrade_reason VARCHAR(64)`、`used_kb TINYINT`。
   - 写入时把 `ctx.id()`、当前模型（`AiModelRepo`）、模板版本、`ai_call` 的 `reason/elapsedMs` 一起落库；
   - DDL + `migrateSchema` 各一处（老库靠 `CREATE TABLE IF NOT EXISTS` 改不动，见 `schema.cj:806-813`）。
2. **模板/模型版本**：`ai_setting` 加 `revision BIGINT NOT NULL DEFAULT 0`（每次 PUT 自增）；模型版本用 `ai_model.id`。
   ⇒ 排障时能回答"那天的输出是哪个模板版本产生的"。
3. **排障端点**（管理端，权限 `Action.ManageAi`）：
   - `GET /api/v1/admin/ai/triage-stats?from&to&group_by=source|reason_code|model_name` ⇒ 计数、降级率、耗时 p50/p95；
   - `GET /api/v1/admin/ai/triage-calls/:requestId` ⇒ 单次调用全链路（时间、source、reason、模型、模板 revision、耗时、是否用 KB、命中的 `kb_doc` id）。
   - ⚠ **合规红线**：`dashboard` 的既有口径是"patient_id / doctor_id / 手机号形状一个都不许有"（`http_p4.cj:513-516`）。
     主诉原文属敏感健康信息 ⇒ 排障端点**默认不返回主诉原文**；若业务确需，须另立合规决策并记录（参照 `docs/Q6-合规决策记录.md`）。
4. **评测（离线优先）**：
   - `server/tests/ai-eval/cases.jsonl`：业务人员标注（`chief_complaint`、`expected_departments[]`、`expected_red_flag`、`note`、`labeled_by`、`labeled_at`）；
   - `server/tests/ai-eval/run-ai-eval.ps1`：两种模式 —— **回放**（用录制响应，离线、可重复、不烧钱，默认）与 **实时**（打真实模型）；
   - 指标：科室 Top1/Top3 命中率、红标召回/误报、`source` 降级率、耗时 p50/p95、与上一版模板的对比；
   - 报告落 `docs/ai-eval/<date>.md`（写明样本量、模型 id、模板 revision）。
   - 与既有测试的分工要写清楚：`acceptance_ai_call.cj` 已用假模型覆盖**降级/超时/解析失败**（属"工程正确性"）；评测脚本负责**质量**（属"结论准不准"）。两者互补，不要合并。
5. **门禁定位**：评测**不进** `final-verify.ps1`（依赖真实模型与 key，不稳定）；发布前手动跑并归档报告。

#### 前端任务

| 端 | 落点 | 做什么 |
| --- | --- | --- |
| 管理台（浏览器） | `server/admin-web/js/pages.js`（AI 能力中心加 Tab）或新页 | AI 看板：成功率/降级率（按 `reason_code` 分组）、耗时分布、未命中 TopN、按 `request_id` 搜索单次调用 |
| | 同上 | 评测报告页：只读展示 `docs/ai-eval/*.md` 摘要（或后端给 JSON） |
| 鸿蒙患者端 / 医生端 | `common-core` 错误组件 + 相关页面 | 错误与结果页展示 `request_id`（"请把此编号告知客服"）——与改进 4 同一处实现，不要做两遍 |
| 鸿蒙管理端 | `feature-admin/.../AiCenterPage.ets` | （可选）与管理台同源的看板；**注意管理台与管理端是两套界面**，先做哪一套要明确 |

#### 验收

- 落库：跑一次分诊 ⇒ `triage_stat` 新行带非空 `request_id`、`elapsed_ms > 0`、`source` 正确；构造降级（不配 key）⇒ `degrade_reason` 非空、`source='rules'`。
- 排障：用响应头里的 `X-Request-Id` 调 `triage-calls/:requestId` ⇒ 能拿到那一刻的模型/模板/耗时。
- 评测：同一批 `cases.jsonl` 连跑两次（回放模式）⇒ 指标完全一致（证明可重复）；换模板 revision 后指标变化能被报告体现。

**投入**：后端 3 人日（落库 + 2 端点 + 迁移）/ 评测脚本 1.5 人日（含与业务人员对齐标注口径）/ 管理台 2 人日。
**依赖**：改进 5（`triage` 响应进契约样例）+ 合规确认（主诉原文能否入库/展示）。

---

## 三、实施顺序（按依赖，不按优先级）

> 优先级都是"高/中"，但**依赖关系**决定了真正该先做哪个。
> 关键判断：改进 5 与"请求编号贯通"是**公共地基**，先做它们能让后面 4 条少返工。

| 阶段 | 内容 | 并行度 | 为什么是这个顺序 |
| --- | --- | --- | --- |
| **0. 地基** | 改进 5（契约导出机 + 三端解析测试）；改进 7 里"`request_id` 落库与回传"的小切片 | 服务端 1 人 + 鸿蒙 C（dto 抽取） | 后面每条都要新增接口；没有样例驱动的门禁，接口一改就要人肉同步三端文档 |
| **1. 低风险高收益** | 改进 4（患者结果确定性）；改进 1（预问诊交接） | 患者端 1 人 + 服务端/医生端 1 人 | 都不动状态机、不动病历结构；投入小、用户可感知 |
| **2. 结构与体验** | 改进 3（修订历史）→ 改进 2（工作台） | 服务端 1 人 + 医生端 1 人（同一条线串行） | 3 是数据层，2 是同页的交互层；先 3 后 2 可避免同页改两遍 |
| **3. 大改动** | 改进 7（看板 + 评测）；改进 6（到院/候诊） | 服务端 1 人 + 管理台 1 人；6 最后 | 6 改状态机，牵动三端 + 全部病历/就诊测试，放在最后风险最低 |

**跨阶段纪律**（写进 PR 模板/自查清单）：
1. 新增或修改端点 ⇒ 必须同时更新 `contract/examples` 与 `contract/CHANGELOG.md`；
2. 新增表/列 ⇒ 必须同时改 `migrateSchema`（老库）与 `ALL_TABLES`（`schema.cj:210`），并同步 `selftest` 的表数断言（`main.cj:331`）；
3. 新增权限动作 ⇒ 必须满足"有第二个用处"，否则复用现有动作（`http_app.cj:96-169` 的纪律）；
4. 客户端加接口 ⇒ **真实实现与 Mock 实现同签名同提交**（`ApiConfig.isMock()` 分流，见 §一.3）；
5. 测试夹具自带独立前缀，不依赖"上一轮跑剩的数据"。

---

## 四、跨项公共约定（先定，后写代码）

这 6 条会被上面多条同时碰到，**先在契约里定死**，避免每个端点各自发明：

| # | 约定 | 内容 | 现状 |
| --- | --- | --- | --- |
| 1 | 时间 | 业务时间戳一律 **epoch 秒**；耗时类字段用**毫秒**且字段名带 `_ms`；"今天/本周"按 **Asia/Shanghai** 计算 | 已一致（`schema.cj` 注释、`FRONTEND-INTEGRATION.md:984-999`） |
| 2 | 失败信封 | 三种形状要能区分：业务错误 `{ok:false,error:{code,message}}`、框架 404、静态 404；客户端**只按 `code` 分支**，`message` 面向用户直出 | `FRONTEND-INTEGRATION.md:170-233` |
| 3 | 请求编号 | 客户端可传 `X-Request-Id`，服务端原样回带；业务写操作把 `ctx.id()` 落库（改进 7）；错误页展示该编号 | 中间件已有（`http_app.cj:2447`），落库待做 |
| 4 | 幂等键 | `client_token` 由客户端生成、**提交前落盘**、重试复用、退号释放、再次挂号换新；服务端保证"同 token 回放同一单" | 已实现（`FRONTEND-INTEGRATION.md:711-746`） |
| 5 | 分页 | `limit`/`offset`；列表类上限 200（`BASE_LIST_MAX_LIMIT`）；**客户端一律显式传 `limit` 并比对 `total`**，不把 `limit<=0` 当"全都要" | 服务端已做（`docs/ADMIN-WEB.md` §4.1、`http_base.cj`），客户端待跟 |
| 6 | 权限动作 | 新动作按语义分、有第二个用处才新增；行为变化必须体现在矩阵注释与测试里 | 已立纪律（`http_app.cj:96-169`） |

---

## 五、验收与回归闸门（改哪块必跑哪条）

| 改动范围 | 必须跑的闸门 | 说明 |
| --- | --- | --- |
| 服务端任何改动 | `server/build.ps1`（框架 38 + 业务 37 = 75 文件） | 编译不过就别谈测试 |
| 服务端业务逻辑 | 进程内四套件：`selftest` / `authtest` / `triagetest`（110 项）/ `accept <dsn>`（575 项） | `accept` 需要 DSN；`server/tests/doc-counts.ps1` 会顺带重跑并核对文档数字 |
| HTTP 契约层 | `server/tests/final-verify.ps1`（现 **13 项**，全绿 exit 0；含 `previsit-bridge-check` 与 `contract-check`） | ⚠ 本机端口必须 ≥15001；脚本前先 `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force`；含中文的 .ps1 必须带 **UTF-8 BOM** |
| 契约变更 | `server/tests/contract-check.ps1`（改进 5，已并入 final-verify 第 13 项）：改动**响应形状** ⇒ 逐字节比对红 / Schema 红 / 登记缺失红 | 更新样例 = 不带 `-Check` 跑 `export-contract.ps1`（写盘），再 review diff + 登记 `schema-map.json` + 写 `contract/CHANGELOG.md` |
| 管理台（浏览器） | `server/tests/admin-web-smoke.mjs`（`SMOKE-EXIT=0`，写路径 + 模态框 + 逐页断言） | 需要 Edge；断言失败会写进退出码 |
| 文档数字 | `server/tests/doc-counts.ps1` | 加表/加端点/加 AC 后**必然**失败，这是设计意图：改代码的人必须同步文档 |
| 鸿蒙客户端 | 新增契约解析测试（改进 5） | 现在**没有**任何客户端测试 ⇒ 这条要先建 |
| AI 质量 | `server/tests/ai-eval/run-ai-eval.ps1`（手动/发布前） | 不进默认门禁（依赖真实模型） |

---

## 六、暂不做（明确写出，防止范围蔓延）

| 不做 | 为什么 |
| --- | --- |
| 患者自助到院签到 | 需要当天窗口 + 频率限制 + 设备绑定 + 审计一整组约束，否则就是开放的代刷接口；先做医护侧确认 |
| 病历版本的分支/回滚 | 医疗记录要的是"可追溯"，不是"可撤销"；回滚会破坏审计链。要改内容就走"解锁 → 改 → 再锁定" |
| 实时叫号/排队大屏 | 属独立子系统（叫号机、屏幕、语音），与本方案无关 |
| AI 在线 A/B 分流 | 先离线评测拿到基线；在线分流需要流量切分、埋点与合规评审 |
| 把 diff 放到客户端算 | 三端各写一遍"哪里变了"必然分叉；服务端算一次（改进 3） |
| 给患者开放知识库检索 | 既有决策：知识库是院内运营资料，患者只拿被引用的那段（`http_app.cj:104-115`） |
| 改服务端默认端口 8091 | 8091 在 Windows 动态端口段内（本机不可显式 bind）；这是**环境**问题，用 `--port 18092` 解决，不要改默认值去迁就某一台机器 |

---

## 七、客户端清点结论（2026-10-14 逐文件核对，供各条落地时对照）

| 主题 | 现状（含路径） | 对哪条有影响 |
| --- | --- | --- |
| 三端同 App | `EntryAbility.ets:11-31` 按 `SessionStore.getRole()` 注册；`Index.ets:20-32` 按路由前缀 `doctor-`/`admin-` 切根组件；`main_pages.json` 只有 `pages/Index` | 1/2/3/6/7（加页面只动 feature-* 与各 Root 的路由表） |
| 医生端只有 3 页 | 登录 / 队列 / 病历（`DoctorRoot.ets:18-32`）；队列标题写明"队列仅显示序号与患者编号，不显示姓名"（`VisitQueuePage.ets:120-121`） | 2/6（工作台与候诊分组都要在这 3 页里扩，或新增页） |
| 病历页现状 | 字段全部由服务端下发（`EmrSection{key,label,value,maxLen,requiredToLock}`，`DoctorModels.ets:25-31`）；只有 存草稿 / 锁定 / 接手 / 完成 / 爽约 五个动作；**没有**分段导航、保存时间、未保存提示、提交前预览（`EmrEditPage.ets`） | 2/3 |
| 病历无历史 | `EmrRecord`（`DoctorModels.ets:33-48`）= `status/locked/filled/totalSections/complete/updatedBy/createdAt/updatedAt/missingRequired/sections`，**无** revision/version/audit；无相关 TODO | 3 |
| 患者可见性 | 仅 `locked` 可读：`RecordsPage.ets:40` 过滤 `draft`；安卓更硬：`PatientRepository.kt:363` 非 locked 直接抛 404 `EMR_NOT_FOUND` | 3（版本/历史对患者的暴露口径要单独定，建议不暴露） |
| 预问诊客户端 | 字段由服务端 `next_slot/next_question/form` 驱动；客户端硬编码 6 槽位仅用于 label 与长度校验（`PatientModels.ets:139-147`：主诉 200 / 持续时间 60 / 影响程度 60 / 伴随症状 200 / 既往史 300 / 过敏史 200）；完成后**只显示一句**"六项信息已采集完成，预问诊单已生成。"（`PrevisitPage.ets:160-162`） | 1 |
| 医生端取预问诊的唯一途径 | `EmrEditPage.ets:113-138` 读**本机** `SessionStore.getPrevisitSessionId()` → `saveDraft(..., sessionId)` → `DoctorRepository.ets:95-97` 塞进 `use_intake_session`；按钮「一键预填」在 `:181-184`，横幅文案"可由预问诊单预填（use_intake_session，仅首次）" | 1（要替换成服务端读端点） |
| 挂号 token | 鸿蒙：内存态（见 §一.2 第 4 行）；安卓：持久化 + CAS + tombstone（同上） | 4 |
| 到院/候诊 | 全仓**无代码**（正则查 `到院｜候诊｜checkin｜签到｜排队｜waiting` 只命中 3 处标题/按钮文案与 1 处公告）；状态集合就是 `booked/visiting/done/cancelled/no_show`（`domain_emr.cj:738-742`） | 6 |
| 状态文案 | 两份：`feature-patient/.../ui/Theme.ets:49-66` 与 `common-core/.../ui/Theme.ets:50-63`；病历状态在 `common-core/.../ui/Theme.ets:84-105` | 6（加状态前先合并） |
| AI 展示 | 只有 `source`（`feature-patient/.../ui/Theme.ets:84-95`：规则引擎 / 模型增强 / 模型输出待复核）与 `reasonText()`（`:97-111`）；**模型名、模板版本、耗时、降级原因、请求编号全仓 `.ets` 无命中** | 7 |
| 管理端 AI 页 | 只做**配置盘点**（`AdminRepository.ets:328-334` 的 `enabled/model/tools_enabled/tools_total/prompts_total/prompts_customized`；`AiCenterPage.ets:136-140` 三个 tab：模型配置 / Prompt 模板 / 工具开关），**不是**运行时统计 | 7 |
| "样例"现状 | 三个 Mock 仓库（363/212/543 行）+ 安卓 `data_strings.xml`（75 行）是事实上的样例库；客户端**两个平台都没有测试目录** | 5 |

---

## 附：本篇引用的关键位置索引

**服务端**
- `server/src/schema.cj:210-216`（`ALL_TABLES`）、`:288-385`（排班/挂号/病历 DDL 与注释）、`:472-509`（预问诊）、`:480-491`（`triage_stat`）、`:803+`（`migrateSchema` 存量迁移写法）
- `server/src/http_app.cj:78-191`（Action 与矩阵）、`:1061-1083`（health/login）、`:1929-2032`（预问诊）、`:2098-2132`（我的挂号）、`:2170-2196`（挂号/退号）、`:2447`（中间件装配）
- `server/src/http_p4.cj:39-105`（病历/队列 JSON）、`:226-301`（接诊队列与流转）、`:310-433`（读/存/锁定/解锁）、`:445-501`（患者侧病历）、`:517-521`（看板）、`:536-555`（流转失败映射）
- `server/src/domain_emr.cj:655-722`（**预问诊→病历预填桥**：`intakePrefill` / `saveDraftWithIntake`）、`:738-742`（就诊状态常量）
- `server/src/ai_call.cj:125-158`（`source`/`reason`/`elapsedMs`）、`server/src/triage_stat.cj:57`（落库写入点）
- `server/tests/final-verify.ps1`、`server/tests/doc-counts.ps1`、`server/tests/admin-web-smoke.mjs`、`server/tests/emr-check.ps1:280-291`（`use_intake_session` 用例）

**客户端**
- `common-core/src/main/ets/config/ApiConfig.ets:6-51`（LIVE/MOCK 与 baseUrl）、`.../network/ApiError.ets:1-16`（`ErrorCode` 清单）
- `entry/src/main/ets/entryability/EntryAbility.ets:11-31`、`entry/src/main/ets/pages/Index.ets:20-32`（按角色/前缀分发）
- `feature-patient/src/main/ets/data/PatientRepository.ets:28-60`（Mock 分流样例）、`.../model/PatientModels.ets`
- `feature-patient/src/main/ets/pages/BookingPage.ets:29,98-135`（内存态 token）、`.../PrevisitPage.ets:40-67,82-93,160-162`
- `feature-doctor/src/main/ets/pages/{VisitQueuePage,EmrEditPage}.ets`、`.../data/DoctorRepository.ets`
- `android-patient/app/src/main/java/com/smart/hospital/patient/{SessionStore.kt,PatientRepository.kt,MainActivity.kt}`、`app/src/main/res/values/strings.xml`
- `feature-admin/src/main/ets/pages/AiCenterPage.ets`、`android-patient/app/src/main/java/com/smart/hospital/patient/`

**文档**
- `docs/FRONTEND-INTEGRATION.md`（1724 行，人读契约：§3 通用约定、§5 逐端点、§5.15/5.16 挂退号幂等）
- `docs/ADMIN-WEB.md`（管理台，含 §4.1 列表截断纪律）
- `docs/Q6-合规决策记录.md`（合规口径，改进 7 触碰主诉原文时需参照）
