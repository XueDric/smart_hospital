# 复验报告：拉取队友更新并重装后，bug 是否仍然存在（含同日修复记录）

- 日期：2026-10-17
- 复验对象：`HEAD = 9bf6a39`「Merge pull request #3 from XueDric/fix/client-visit-status-semantics」（拉取前本地 HEAD 为 `4817b7b`）
- 手段：**不只看代码，把服务端从源码重建、两个客户端重新构建并装进模拟器，逐条实测**
- 环境：MariaDB 11.4.13 @127.0.0.1:3317（库 `hospital_test`）、仓颉服务端 `hospital-server.exe 0.2.0-p1` @127.0.0.1:8091、鸿蒙模拟器 Pura 90（1320×2856）、Android 模拟器 emulator-5554（1080×2400）

> 说明：原先在跑的 `server/build/hospital-server.exe` 是 `.gitignore` 覆盖的预编译产物、来源不明，因此**先 `build.ps1` 从源码重建再从它复验**，否则「bug 是否仍存在」的结论不可信。
>
> **本轮定位**：§一–§八 是**复验当时的快照**（当时 `HEAD = 9bf6a39`、业务代码零改动）。同一天按 §八 的优先级动手修了服务端——**每条缺陷的处置与验证证据见 §九，契约/文档同步见 §十**。§一 表格里「仍然存在」「零改动」这类措辞，一律以 §九 的处置为准。

---

## 一、结论速览

| 范围 | 结论 |
|---|---|
| 队友本次更新**修好**的 | 4 项（就诊状态语义 C1、7 个新字段解析、医生端患者姓名/性别、已到院动作与退号抑制）—— 全部**运行期实测通过** |
| 服务端**仍然存在**的 | 8 条（含 3 条中危：超长 `client_token` 500、并发幂等键漏复查、病历锁定后仍可退号）—— 全部在**新二进制**上重新实测确认 |
| 客户端**仍然存在/新发现**的 | 3 条主要缺陷（冷启动永远只进管理端=重大、医生队列「今日」页签不过滤日期、患者首页「下一次就诊」取错单=中）+ 一批静态审查出的低危一致性问题 |
| 仓库本体是否被我改过（**复验当时**） | 仅 `.gitignore`（上一个任务加的 3 条本机工具链忽略项），**业务代码零改动**；同日动手修复后的完整改动清单见 §九 |

---

## 二、队友这次更新改了什么

`git diff --stat 4817b7b..9bf6a39`（节选）：

- 新增 `common-core/src/main/ets/model/VisitStatus.ets`（就诊状态单一判定层，84 行）
- `feature-patient/.../HomePage.ets`、`AppointmentsPage.ets`：状态判定改用 `VisitStatus.*`
- `feature-doctor/.../VisitQueuePage.ets`、`EmrEditPage.ets`、`DoctorRepository.ets`：队列/病历患者栏接上 `patient_name` / `patient_gender`
- `docs/FRONTEND-INTEGRATION.md`：同步文档
- **`android-patient/` 零改动**（`git diff --name-only` 里属于它的文件 = 0）

---

## 三、已被更新修好的（运行期实测）

### 1. C1：`arrived` / `waiting` / `visiting` 不再被错判为「历史」

复现步骤：把患者 1 今天的单（`933541`）通过 `POST /api/v1/doctor/visits/933541/arrive` 推进到 `arrived`，再从鸿蒙患者端看「我的就诊」。

结果（截图 `.tmp/pat-05-visits.jpg`）：**当前预约**同时列出 3 条，其中

```
2026-10-17 上午
序号 1 · 内科 · 张医生 主任医师        已到院
到院 00:45
当前状态为【已到院】，不能退号。
```

- `arrived` 被正确归入**当前预约**（而不是历史/已完成）→ 本次更新的 `VisitStatus.isActive` 生效
- 显示了 `status_label`（已到院）与 `arrived_at`（到院 00:45）→ 新增 7 字段解析生效
- 退号按钮被抑制，并给出与服务端一致的原因 → `canCancel` 判定生效
- 医生端队列同一单显示「已到院 / 到院 00:45 · 候诊 0 分钟」+ 动作「转入候诊」→ `arrived → waiting` 链路正常

### 2. C4：医生端终于能看见患者姓名/性别

截图 `.tmp/doc-04-queue.jpg`（鸿蒙医生端接诊队列）：

```
序号 1 · 测试患者            已挂号    2026-10-17 AM
序号 2 · Harmony P2（女）    已挂号    2026-10-17 AM
```

- 姓名上屏；**性别用阳性对照验证过**：患者 1 库里 `gender=''`（所以第一张卡无性别后缀），患者 2 库里 `gender='F'` → 显示「（女）」，说明映射正确、不是硬编码
- 服务端侧同样确认：`server/src/http_p4.cj:487-517` 的 `GET /api/v1/doctor/visits` 已通过 `visit.patientBriefs()` + `putPatientInto()` 批量下发 `patient_name` / `patient_gender`

**未修的相邻项**：`GET /api/v1/doctor/patients/:patientId/records`（既往病历列表）仍不解析 `patient_name`（`DoctorRepository.ets` 的 `parsePastRecord` 未动），与更新文档自述一致。

---

## 四、服务端仍然存在的缺陷（已在新二进制上逐条实测）

| # | 危 | 缺陷 | 证据 |
|---|---|---|---|
| S1 | 中 | **挂号接口不校验 `client_token` 长度** → 超 64 字符直接 **500**；而同一 token 走查询接口是 400 | `http_app.cj:2544` 用 `requireStr` 无长度校验；对照 `http_app.cj:2475-2478` 有 `>64 → VALIDATION_FAILED`；`schema.cj:370` 列为 `VARCHAR(64)` |
| S2 | 中 | **扣号 0 行时不复查幂等键** → 并发同 token 可能拿到 409 `SLOT_GONE` 而单其实已建成 | `domain_booking.cj:911-916` 直接判 `SlotGone`；同一函数 `:878-881` 做对了（`findAppointmentByToken` 回读）。实测 6 并发同 token：5 成功 + **1×409 SLOT_GONE** |
| S3 | 中 | **病历锁定后仍可被患者退号** → 号源被退回、病历变孤儿、该单再也不能 finish | 写/锁病历只校验医生归属（`http_p4.cj:721`、`:775-778`）；退号只认 `status='booked'`（`domain_booking.cj:1030-1033`）。实测：`visiting` / `done` 会被 409 拦住，但**病历 locked 而单仍 `booked`** 时可退成功 |
| S4 | 中 | **DB 单连接、失败后 `usable=false` 永不复位** → 一次 BEGIN/ROLLBACK 失败后所有请求恒 500 直到重启进程 | `third_party/qingzhou/src/db_mysql.cj:271-273`、`:303-305` 置 false，全仓**无任何处置回 true**；无连接池（`main.cj:903`） |
| S5 | 低 | **建排班无 (doctor_id, work_date, period) 唯一约束** → 同医生同时段可静默重复放号 | `http_app.cj:2705` `insertSchedule` 无查重；`schema.cj:324` 是普通索引 |
| S6 | 低 | **`client_token` 列无 COLLATE** → 按实例默认排序规则**大小写不敏感** | `schema.cj:370/394`，全仓无 `COLLATE`。实测 `CASE-A` 与 `case-a` 互相冲突（409） |
| S7 | 低 | dev-auth 取不到客户端 IP 时 **fail-open**（按本机信任） | `http_app.cj:513-515`；`isLoopbackIp("")` 返回 false。契约本身成立（不能靠 X-Forwarded-For 伪造），属写法隐患，生产不可达 |
| S8 | 低 | **文档与实现不符**：文档说读到 `enabled=1` 后被停诊应回 409 `SLOT_GONE`，实际回 **404** | `domain_booking.cj:911-913` 用可售谓词再判一次 → `ScheduleNotFound` → `http_app.cj:2587` |

### 同批实测确认的其他服务端问题

| # | 危 | 问题 | 证据 |
|---|---|---|---|
| S9 | 中低 | **`limit` / `offset` 不校验也不夹取**：`limit=0`/`-1`/`abc`/`offset=-5` 一律**静默返回全表**（无上界） | `GET /api/v1/admin/users`，`auth_user` 36 行时上述取值都返回 36 条；仅 `limit=1/2`、`offset=99999` 正常 |
| S10 | 中 | **限流按账号锁定，能锁死真实患者** | `LOGIN_FAIL_LIMIT=5`、`LOGIN_LOCK_SECONDS=900`（`auth_repo.cj:90/92`）。实测对 `13800000001` 连打 5 次错口令后，**该患者用正确口令也拿 429**；`admin` 不受影响。即知道手机号就能把该患者锁在门外 15 分钟 |
| S11 | 中低 | **同一患者可自占同一排班多个号**（无约束） | 两个不同 `client_token` 都 `201`（seq 1、2），`/appointments count=2` |
| S12 | 中 | **规则兜底文案与事实不符** | `{"chief_complaint":"咳嗽三天"}` → `patient_note`「建议就诊：**呼吸内科**（该科当前无可挂号源）」，但本院 `department` 表只有 1 行（id=1 内科/NK），**根本没有呼吸内科**。根因：`triage.cj:506-510` 专门区分出的 `TR_NO_SUCH_DEPT` 被 `:527-547` 的备选分支覆盖，为此写的 `:554-558`「在本院暂未开诊」在常见情形下不可达 |
| S13 | 中 | **AI 实际未启用**（配置缺口，非代码缺陷）：分诊完全由规则引擎承担 | `triage_stat` 行 `degrade_reason=AI_DISABLED`、`source=rules`、`elapsed_ms=0`；`ai_reason` 明说「未配置 `ai.key_ref`（必须是 `env:名` 或 `file:路径`）」。管理台显示的「模型 qwen-plus · 工具 6/6」只是配了模型名，没有可用密钥。红旗路径正确（`red_flag:true`、`options:[]`、提示立即急诊） |
| S14 | 中低 | **框架层错误不走统一三段式信封** | body 非法 JSON → `400 {"code":400,"message":"Invalid JSON body","data":null}`（无 `ok`、无 `error` 对象）；方法不匹配 → `405 {"error":"Method Not Allowed","allow":"GET"}`，`error` 是**字符串**，客户端按契约取 `body.error.code` 只会得到 `undefined` |
| S15 | 低 | `GET /api/v1/kb/search` 用患者令牌 → `403 FORBIDDEN_ROLE`「角色 patient 无权执行 query_knowledge_base」（需与患者端是否存在知识库入口对照） | 实测 |
| S16 | 低 | 对已取消的单**重复退号**仍回 `slot_restored=true`（字段不反映「本次是否真的归还」） | 实测：第二次退号 remain 不再增长，但字段仍 true |
| S17 | 低 | 同一类 id 校验两个端点口径不一致：`/schedules/abc` → 400 `VALIDATION_FAILED`，`/previsit/abc` → 404 `PREVISIT_NOT_FOUND` | 实测 |

**明确排除的（查过且清白）**：超卖（10 并发抢 2 号 → 恰好 2×201 + 8×409 `SLOT_GONE`，`remain_num 2→0`、`version 0→2`）；顺序与并发幂等（同 token 8 并发 → 1×201 + 7×200，只落 1 行）；越权退号（患者退他人单 → `403 FORBIDDEN_ROLE`，管理员可退任意单）；正常退号归还号源（含 6 并发退同一单只涨一次）；退号后同一 `client_token` 可复用；仅 `booked` 可退；`/admin/users` 不泄露 `pw_hash`/`pw_salt`；路径穿越被规范化后 404。

---

## 五、客户端仍然存在/新发现的缺陷

### C-A【重大·新发现】冷启动永远只能进管理端

- **现象**：全新安装后启动只有管理端登录页；登录页上没有切端的入口；按返回键直接退出应用。**患者与医生的登录页在界面上不可达。**
- **根因**：三个 Feature 的注册函数都**无条件覆写当前路由**——
  - `feature-patient/src/main/ets/PatientFeature.ets:4` `AppRouter.getInstance().replace(RouteName.LOGIN)`
  - `feature-doctor/src/main/ets/DoctorFeature.ets:4` `...replace(RouteName.DOCTOR_LOGIN)`
  - `feature-admin/src/main/ets/AdminFeature.ets:4` `...replace(RouteName.ADMIN_LOGIN)`
  - 而 `entry/.../EntryAbility.ets` 的 `onCreate` 顺序是 patient → doctor → **admin** ⇒ **最后注册者胜出**
- **不是本次更新引入**：`EntryAbility` 最后改动 `75fc8f7`(2026-10-15)、`PatientFeature` `29f058d`(10-11)、`DoctorFeature`/`AdminFeature` `17e1b70`(10-13)，均在本次更新之前
- **反证（运行期）**：在 ASCII 副本里把注册顺序改成 doctor→admin→**patient**，冷启动即落在**患者端登录页**；改成 patient→admin→**doctor**，即落在**医生端登录页**（截图 `.tmp/pat-02-login.jpg`、`.tmp/doc-01.jpg`）。两版都能 BUILD SUCCESSFUL、HAP 同样 1,709,977 字节 ⇒ 唯一变量就是注册顺序
- 附带事实：`AdminLoginPage.build()` 只有「在线服务/演示数据 + 账号 + 密码 + 登录」，**没有任何切换端的 UI**；医生/患者登录页同理。`Index.ets` 的 `renderRoot` 只按路由前缀选根组件，`AppRouter.currentRoute` 初值就是 `'login'`（患者端），但只要注册发生过就一定被覆写

### C-B【中·新发现】医生队列「今日」页签不过滤日期

- 现象：点「今日」后列出的全是**未来**的单（截图里 3 条中 2 条是 `2026-12-24`）；「上午/下午」只按 `period` 过滤，同样跨日期
- 代码：`VisitQueuePage.ets` 的 `filtered()`——`if (this.filter === 'ALL') return items`（不比对日期），否则 `item.period === this.filter`；页签 `segment('ALL','今日')`
- 服务端侧：`GET /api/v1/doctor/visits` **只接受 `limit`，没有日期参数**（`http_p4.cj:487-517`），所以客户端必须自己按 `visitDate` 过滤，但没做
- 本次更新使问题更明显：副标题从「队列仅显示序号与患者编号，不显示姓名」改成了「**按状态展示今日接诊顺序**」（`VisitQueuePage.ets:234`），把「今日」写进了界面文案
- 后果：医生会在「今日」下看到未来日期的单（本项目已有两条 12-24），日期越积越多越误导；也无法只看当天

### C-C【中·新发现】患者首页「下一次就诊」取错单

- 现象（UI 复现，截图 `.tmp/pat-04-home.jpg`）：「下一次就诊」显示 **2026-12-24 上午 · 已挂号**，而该患者**今天（10-17）有一条已到院**的单——今天正在就诊的单被挡住
- 机制：`GET /api/v1/appointments` 的排序是 `created_at DESC, id DESC`（`domain_booking.cj:381`，口径注释 `:368-369`「最近挂的在前」），而 `HomePage.ets:59-67` 遍历取**第一条**非终态（`VisitStatus.isActive` 命中即 `break`）⇒ 取到的是「最近**下单**的有效单」而不是「最近**要就诊**的单」
- 实测顺序：`[1] 933543 12-24 booked`、`[2] 933541 10-17 **arrived**`、`[3] 933540 12-24 booked`
- 即本次把判据放宽到 `isActive` 只修了一半：`arrived` 现在算「活单」了，但排序口径没变，仍会被更晚下单的单顶掉

### C-D 及一批低危（静态审查，多数未逐条运行验证）

| # | 危 | 位置 | 问题 |
|---|---|---|---|
| C-D | 低 | `HomePage.ets:54-58` | `load()` 未复位 `hasNextAppointment`，刷新后可能留着已退号的旧卡片（仅置 true、从不置 false） |
| C-E | 低 | `common-core/.../model/VisitStatus.ets:5`、`:63` | 两处「权威引用」行号指错（`visitStatusLabel` 实际在 `domain_emr.cj:1499` 而非 `:1455`；退号权威是 `domain_emr.cj:1437-1452 `visitTransitionAllowed``，而 `http_app.cj:575` 的 `canCancel()` 根本不看 status）——该文件的立身之本就是「服务端变了这里必须同步」，引用错位会让下次同步查错文件 |
| C-F | 低 | `EmrEditPage.ets:147` | 保存草稿后本地「患者自述」角标被清空（`previsit_ref` 只在单查 `includeSections=true` 时下发，PUT 响应没有） |
| C-G | 低 | `EmrEditPage.ets:449-478` | `loadConflict` 的 catch 清空 `conflictServerValues` 却仍弹框 → 医生读不到服务端版本时只能放弃保存 |
| C-H | 低 | `DoctorRepository.ets:379` + `EmrEditPage.ets:160` | `revision_version` 只有 lock/reopen 会写，PUT/GET 响应都不带 → 真机永**不**显示「修订 vN」，而 mock 里塞了 v3（**用 mock 验证该字段会得到假阳性**） |
| C-I | 低 | `feature-admin/.../DepartmentsPage.ets:74`、`DoctorsPage.ets:79` | 更新路径硬编码 `'enabled': true`（科室还多 `'sort': 0`）→ 编辑一个已停用的科室/医生会**静默把它改回启用**（对照 `KnowledgeBasePage.ets:104-107` 写对了） |
| C-J | 低 | `RecordHistoryPage.ets:81-95` | 先同步写 `selectedVersion`、正文靠 `await` → 加载期标题/正文错配；`finally` 提前把 busy 置 false，`.enabled(!this.busy)` 拦不住连点 |
| C-K | 低 | `KnowledgeBasePage.ets:48-60` | `filtered()` 只匹配 `doc.title`，按正文关键词搜会显示「无匹配文档」 |
| C-L | 低 | `SchedulesPage.ets:53` | 只校验日期非空、不校验 `YYYY-MM-DD`（自由文本） |
| C-M | 低 | `UsersPage.ets:76-94` | 重置口令失败时 `resetUserId` 未清 → 失败后改点其他用户会带着上一个密码 |
| C-N | 低 | `AdminRepository` | `departments`/`doctors`/`kbDocs` 均不传 `limit`、不读 `total`（缺省 200 截断无提示） |
| C-O | 低 | `common-core/.../JsonUtil.ets:23-28` | `asBool` 用 `Boolean(value)` → 字符串 `"false"` 得 `true`（未证实有端点下发字符串布尔） |
| C-P | 低 | `VisitQueuePage.ets:406` | `.opacity(item.status === 'done' \|\| item.status === 'no_show' ? 0.6 : 1)` 漏 `cancelled`（当前不可复现：服务端队列 SQL 已排除 cancelled） |
| C-Q | 低 | 安卓端智能分诊页 | 空输入提交的客户端校验红字「请先描述主要症状」**不随用户输入消失**（输入 37 字符后仍在） |

---

## 六、复现配方（本机）

```powershell
# 1) 服务端（必须从源码重建，别用来源不明的 build\ 产物）
cd server; .\build.ps1
.\build\hospital-server.exe serve mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital_test --port 8091 --dev-auth --bind 127.0.0.1

# 2) 鸿蒙：hvigor 拒绝中文工程路径，必须先 robocopy 出 ASCII 副本
#    副本 E:\harmonyOS\sh_client_live2 内构建，构建后 hdc 隧道：
hdc rport tcp:18096 tcp:8091      # ⚠ 第二参数是【主机端口】，不是设备端口
#    副本内 ApiConfig/SessionStore 的默认地址已改为 http://127.0.0.1:18096

# 3) 安卓：AGP 也拒绝中文路径，走 subst + 全部家目录重定向进仓库
subst X: E:\harmonyOS\智能医院客户端
#    GRADLE_USER_HOME/JAVA_HOME/ANDROID_HOME/ANDROID_USER_HOME/TEMP 全指到仓库内
#    X:\android-patient> .\gradlew.bat :app:assembleDebug --no-daemon "-Pkotlin.compiler.execution.strategy=in-process"
```

**会伪装成「代码 bug」的 4 个环境坑**（排障前先排除）：
1. `hdc rport tcp:<设备端口> tcp:<主机端口>` —— 第二个参数是**主机端口**。文档里 `tcp:18096 tcp:18096` 能用是因为当时服务端也在 18096；照抄到「服务端在 8091」的环境必然 `Failed to receive data from the peer`
2. 设备端口 8091 会被 hdc 残留监听占住（`[Fail]TCP Port listen failed at 8091`）——**不是** Windows 动态端口排除段（本机排除段里没有 8091）
3. `uitest uiInput inputText` 会**前缀一个杂散字符**，且**打不出大写**（`keyEvent` 送的是未加 Shift 的小写字母）⇒ 填表用「先 click、再 inputText/keyEvent、再 `keyEvent Back` 收键盘」，每步截图核对；测大写口令请改用全小写口令的测试账号
4. `hdc shell snapshot_display -f x.jpeg` 产出的是 **JPEG**，存成 `.png` 会被读图工具以「扩展名与字节不符」拒绝
5. 同一端口起两个 `serve` 进程时**两个都不会退出**，此后所有碰库请求 500 —— 起服前先确认只有一个进程

---

## 七、我动过的东西 / 遗留

- **仓库本体**：仅 `.gitignore` 有未提交改动（上一个任务加的 `.build-tools/`、`.gradle-home/`、`.android-home/` 三条本机工具链忽略项，16 插入 4 删除）。**业务代码零改动**，`HEAD = 9bf6a39`（**复验当时**；同日动手修复后的业务代码改动清单见 §九）
- **工作区外/内的一次性产物**（可随时删）：ASCII 构建副本 `E:\harmonyOS\sh_client_live`、`E:\harmonyOS\sh_client_live2`；抓包中继 `E:\harmonyOS\relay.ps1` + `relay.log`；scratch 目录 `%TEMP%\hosp`；截图/日志 `E:\harmonyOS\智能医院客户端\.tmp\`
- **测试数据（都在 `hospital_test`，可随时清空）**：
  - 账号：`hmtest`(id 430, admin)、`hm_pat2`(434, patient ref_id 2)、`hm_doc`(435, doctor ref_id 1)
  - 我把 `13800000001`(id 2) 的口令重置为 `pat2026test`（原为 `patient-pw-1`）——**如需还原请告知**
  - `appointment` 4 行、`schedule` 2 行（含我为今天新建的 930012）、`auth_token` 248 行
  - 解锁账号用：`DELETE FROM hospital_test.auth_login_attempt;`
- **仍在运行**：MariaDB 3317、服务端 8091（PID 45404，**单进程**）、Android 模拟器 emulator-5554、鸿蒙模拟器（hdc 目标 `127.0.0.1:5557`）+ 隧道 `tcp:18096→tcp:8091`
- **本轮未做的**：C1 修复的**安卓端**运行期复验（安卓包未重装，因为本次更新没碰 `android-patient/`）；`feature-admin` 各页的运行期复验（C-I/C-K/C-L/C-M/C-N 只做了静态审查）

---

## 八、建议的修复优先级

1. **C-A（重大）**：三个 Feature 注册时不要无条件 `replace()`；应先看 `SessionStore.getRole()`，或在管理端登录页加「切换端」入口。这是「装完就能用」的前置条件
2. **S1 / S2 / S3（中）**：三条都属「同一文件里已有正确写法」的低风险补丁；S3 需先定口径（病历 locked 后是否允许退号）
3. ~~**S9 / S10（中）**：`limit/offset` 加 clamp（挂号域仓储已有正确写法可抄）；限流从「按账号锁」改为「按 账号+IP」或失败延迟递增，避免知道手机号即可锁死患者~~ —— **两条都已作废**（2026-10-17 同日复核）：S9 读源码后确认**本来就 clamp**（§九 9.7 末条「S9 撤回」）；S10 被 `rate-limit-check.ps1` 的既有断言推翻（锁定窗口内**刻意**不跑 PBKDF2），属限流策略变更、需 owner 拍板（§九 9.7）
4. **C-C / C-B（中）**：首页改按 `visit_date` 升序且到院/候诊优先；医生队列补按 `visitDate === today` 过滤（或服务端加日期参数）
5. **S12（中）**：`triage.cj` 的备选分支不要覆盖 `TR_NO_SUCH_DEPT`，或在文案里区分「本院未开诊」与「该科无可挂号源」
6. **S13（配置）**：给服务端配 `ai.key_ref`，否则 AI 分诊一直是规则引擎兜底

---

## 九、同日修复：逐条处置与运行期证据

### 9.0 改动集

| 文件 | 规模 | 对应 |
|---|---|---|
| `server/src/http_app.cj` | +106 | S1 幂等键长度、S3 映射 409、S5 重复排班 409、S14 框架出口接线 |
| `server/src/domain_booking.cj` | +103 | S2 扣号失败后按幂等键复查、S3 第五态 `RecordLocked` |
| `server/src/domain_emr.cj` | +25 | S3 新增 `emrHasLockedRecord(db, appointmentId)` |
| `server/src/http_common.cj` | +132 | S3/S5/S14 错误码登记、`errorEnvelopeString`、`hospitalBodyParserOptions` |
| `server/src/schema.cj` | +104 | S6 `COLLATE utf8mb4_bin`（DDL + 迁移 ⑭）、迁移 ⑮（DROP 掉 S5 的唯一键） |
| `server/src/triage.cj` | +31 | S12 备选分支文案 |
| `server/third_party/qingzhou/src/router.cj` | +42/−? | S14 404/405 平铺体 → 可注入信封 |
| `server/third_party/qingzhou/src/static.cj` | +11 | S14 静态 404/403/416 平铺体 |
| `server/src/auth_repo.cj` | **0（先改后回退）** | S10，见 9.7 |
| `contract/*`、6 个 docs、`server/README.md`、`admin-web/js/api.js`、2 个 tests 注释 | 见 §十 | 契约与文档同步 |

> 复验当日**未提交**任何业务代码；所有改动都发生在同一天下午的修复环节，`git diff` 可逐行核对。

### 9.1 S1 超长 `client_token`：500 → 400

- **修法**：`POST /api/v1/appointments` 的取参处补长度校验，**照抄同文件查询端点的正确写法**（`http_app.cj:2472-2478`）——空 ⇒ `VALIDATION_FAILED`；`> 64` ⇒ `VALIDATION_FAILED`「幂等键最长 64 个字符（收到 N 个）——客户端生成时应自行截断」。建单端点落在 `http_app.cj:2555-2562`。
- **为什么是缺陷**：`appointment.client_token` 是 `VARCHAR(64)`，超长值由 MySQL 抛 `Data too long`，被 `hospitalErrorHandler` 的兜底分支变成 `500 INTERNAL`（同类输入两个端点两种行为）。
- **运行期证据**：65 字符 ⇒ `400 {"ok":false,"error":{"code":"VALIDATION_FAILED","message":"幂等键最长 64 个字符（收到 65 个）——客户端生成时应自行截断"}}`；同一 token 重放仍 `200` 且 `appointment_id` 不变（幂等语义未破）。

### 9.2 S2 并发同 token：偶发 409 `SLOT_GONE` → 恒定 1×201 + (N−1)×200

- **修法**：`domain_booking.cj` 的 `book()` 在**扣号失败**的分支里，先按 `(patient_id, client_token)` 复查一次是否已有单（`:878-881` 的 `findAppointmentByToken` 就是既有正确写法，`catch` 分支在用）；查到了 ⇒ 按幂等重放返回既有单，查不到才如实报 `SlotGone`。
- **为什么是缺陷**：并发下 N 个请求都通过"券后检查"，MySQL 行锁让其中一个成功、其余扣号失败；失败的请求**已经带着同一个幂等键**却报 `SLOT_GONE`，客户端会以为号被抢走。
- **运行期证据**：同一 `client_token` 6 个**独立进程并发**打同一号源（`total_num=8`）⇒ HTTP **5×200 + 1×201、0×409**，6 个响应的 `appointment_id` **全部等于 933645**、`seq_no=2`，`remain_num` 只减 1（8→7→6）。
  （第一轮探测把 `curl -w` 的输出与 `-o` 混在一个流里，读到的码是 `401000000000` 这种拼接垃圾——**已作废、重测**，这里只用第二轮的数据。）

### 9.3 S3 病历定稿后仍可退号 → 409 `APPOINTMENT_RECORD_LOCKED`

- **口径决定**：**病历一锁定（`locked`）就不允许退号**。理由是 `done` 的前提是病历已锁定（`emr-check.ps1` 钉住"未锁定不能完成就诊 ⇒ 409 `EMR_NOT_LOCKED`"），若允许退号，这张单再也无法 `finish`，锁定的病历会变成**挂在已退号单上的孤儿**；真要退，应当先由管理员处理病历（解锁 / 作废修订）。
- **修法**：`CancelOutcome` 增第五态 `RecordLocked`（`domain_booking.cj:142,152-153`，注释写明它与 `NotCancellable` 都是 409 但**处置不同**）；`cancel()` 在**状态机判定之后**（`:1067-1068` 先判 `visitTransitionAllowed`）再查病历是否锁定 —— 事务内 UPDATE 影响 0 行且存在锁定病历时 ⇒ `RecordLocked`（`:1087`），事务外的复查路径同理（`:1164`）；判定由 `domain_emr.cj:1416 emrHasLockedRecord(db, appointmentId)` 提供（复用 `:1741-1757` 的 `EXISTS (SELECT 1 FROM medical_record …)` 习语）。`http_app.cj:2686` 映射成 `409 APPOINTMENT_RECORD_LOCKED`，`http_common.cj:145` 登记文案。
- **安全性**：新增枚举态不会破坏既有匹配 —— `acceptance.cj` 的 `match` 用 `case _` 兜底；`visit-timeline-check.ps1:297-298` 期望的 `arrived` 单仍是 `APPOINTMENT_NOT_CANCELLABLE`（状态机判定在前，两者不抢）。
- **运行期证据**：锁定病历后退号 ⇒ `409 {"code":"APPOINTMENT_RECORD_LOCKED","message":"该挂号单的病历已定稿（锁定后不可再修改），不能退号；如确需退号，请先联系管理员处理该次病历"}`；**同一排班未锁病历的另一张单退号仍 `200`**（`slot_restored:true`，`remain_num` 从 2 回到 3）——证明不是把退号一律堵死。
- **顺带修掉一个不一致**：`http_app.cj:2393` 的 `GET /api/v1/appointments` 里 `include_cancelled` 与状态文案都走同一套 `visitStatusLabel`，`status_label` 现在是「已退号」（`s3_cancel_nolock.json`）。

### 9.4 S5 重复排班：静默新增 → 409 `SCHEDULE_EXISTS`

- **走过的弯路（必须记下来）**：第一版我给 `schedule` 加了 `UNIQUE KEY uk_schedule_doctor_slot (doctor_id, work_date, period)`。**验收套件当场红了 2 项** —— 它（以及 `base-check.ps1`）会**刻意造同一医生同时段的多条排班**来测「放号数/停诊/乐观锁」，DB 唯一键把测试夹具自己挡死了。⇒ 已回退：**不在 DB 层加约束**，改由**业务层**在同一事务里先查再插，返回 `409 SCHEDULE_EXISTS`，并在迁移 ⑮ 里**主动 DROP 掉**这个索引（兼容已经跑过中间版本的库）。
- **修法**：`domain_booking.cj` 新增 `findScheduleIdByDoctorSlot(doctorId, workDate, period): ?Int64`；`http_app.cj:2758` 命中即 `throw apiErrorMsg("SCHEDULE_EXISTS", …)`，文案带上既有 `schedule_id` 与"请直接修改该排班（改放号数 / 恢复停诊），不要新建"；`http_common.cj:97` 登记错误码。
- **残留窗口（如实记录）**：查-插不是原子操作。两个管理端请求**同时**建同一时段，理论上仍可能各插一条 —— 这是为了不破坏验收套件而**刻意选择**的：DB 层的强约束会在 `base-check` 上红，业务层检查则是尽力而为。要彻底闭合需要"唯一键 + 允许同医生同时段多排班"的建模重做（属产品决策，不在本轮范围）。
- **运行期证据**：同一 `(doctor_id, work_date, period)` 第二次建 ⇒ `409 SCHEDULE_EXISTS`「该医生在 2027-03-12 AM 已有排班（schedule_id = 930019），请直接修改该排班（改放号数 / 恢复停诊），不要新建」（修复前第二次也是 `201`）。

### 9.5 S6 `client_token` 大小写敏感（`utf8mb4_bin`）

- **修法**：DDL 里 `client_token VARCHAR(64) COLLATE utf8mb4_bin NULL DEFAULT NULL`（`schema.cj:390`）；**迁移 ⑭**（`:1301-1332`）对已有库 `MODIFY COLUMN` 到同一 collation（先查 `information_schema.columns` 的当前 collation，已是 `utf8mb4_bin` 就跳过）。
- **为什么是缺陷**：`uk_appointment_patient_token` 在 `utf8mb4_general_ci` 下**大小写不敏感**，`CASE-A` 与 `case-a` 会被当成同一个幂等键 ⇒ 客户端两个逻辑上不同的请求被静默合并成一张单。
- **运行期证据**：同一患者、同一排班，`verify-…-CASE-A` 与 `verify-…-case-a` 各建一单 ⇒ **两张单**（`933649` / `933650`，`seq_no` 1 与 2）；`CASE-A` 原样重放仍回 `933649`（`200`）—— 大小写敏感**且**幂等未被破坏。
- **迁移核对**：`information_schema.columns` 里 `hospital_test.appointment.client_token` 的 `COLLATION_NAME = utf8mb4_bin`。

### 9.6 S14 框架层平铺错误体 → 统一信封

修复前有**四处**由框架自己写、绕开项目信封的出口（非法 JSON 400 / 未匹配路由 404 / 方法不匹配 405 / 请求体过大 413），另加**静态层**的 404 与 416（框架本来就留了可配项，是应用没配）：

| 出口 | 修复前 | 修复后（实测） |
|---|---|---|
| 非法 JSON 请求体 | `400 {"code":400,"message":"Invalid JSON body","data":null}` | `400 {"ok":false,"error":{"code":"VALIDATION_FAILED","message":"请求体不是合法 JSON"}}` |
| 未匹配路由 | `404 {"error":"Not Found","path":"…"}` | `404 {"ok":false,"error":{"code":"ROUTE_NOT_FOUND","message":"接口不存在：GET /api/v1/nope"}}` |
| 方法不匹配 | `405 {"error":"Method Not Allowed","allow":"GET"}` | `405 {"ok":false,"error":{"code":"METHOD_NOT_ALLOWED","message":"Method Not Allowed（允许的方法：GET）"}}` |
| 静态资源未命中 | `404 {"error":"Not Found"}` | `404 {"ok":false,"error":{"code":"ROUTE_NOT_FOUND","message":"静态资源不存在"}}` |
| Range 越界 | `416 {"error":"Range Not Satisfiable"}` | `416 {"ok":false,"error":{"code":"RANGE_NOT_SATISFIABLE","message":"Range 请求超出文件大小"}}` |
| 请求体过大 | `413 {"code":413,"message":"Request body too large","data":null}` | `413 {"ok":false,"error":{"code":"VALIDATION_FAILED","message":"请求体过大，超出服务端允许的上限"}}` |

- **修法（三层）**：① 框架 `router.cj` 新增可注入的 `Router.errorBody: (Int64, String) -> String`（默认仍是自己的老形状，**不改变框架单独使用时的行为**），5 处硬编码体改走它；`static.cj` 的 `StaticOptions` 增 `rangeNotSatisfiableBody`（`notFoundBody`/`forbiddenBody` 本来就有）。② 应用侧 `http_app.cj` 注入：`router.errorBody = { status, msg => errorEnvelopeString(status == 405 ? "METHOD_NOT_ALLOWED" : "ROUTE_NOT_FOUND", msg, None) }`，静态层注入三条文案；`.use(bodyParser())` 改成 `.use(bodyParser(hospitalBodyParserOptions()))`，其 `onError` 把框架的英文短语**记服务端日志**、对外只发信封；并把外层 `.use(contentLengthLimit(64 * 1024))` 换成 `.use(contentLengthLimit(hospitalContentLengthLimitOptions(64 * 1024)))`（`http_common.cj:456`）—— **只换 bodyParser 不够，实测 70 KB 仍漏平铺体**。③ `http_common.cj` 抽 `errorEnvelopeString(code, message, fields)` 供 `sendError` 与上述注入点共用（信封只有一处定义）。
- **为什么值得改**：客户端契约是「只判 `code`，不判 HTTP 状态」，而这三种出口**没有 `code`**，客户端只能退回按英文文案/状态码分支（`docs/FRONTEND-INTEGRATION.md` 旧版就是这么写的：`res.error === 'Method Not Allowed'`）——多端很难保持一致。
- **⚠ 413 这一条是「先漏后补」的自我修正（如实记录）**：请求体上限有**两层**闸门 —— 外层 `contentLengthLimit(64 * 1024)`（按 `Content-Length` 预检，`http_app.cj:2930`）与内层 `bodyParser()` 的 1 MiB（用于**没有** `Content-Length` 的 chunked 请求）。第一版我只换了内层，实测 **70 KB 请求仍漏出框架自带的 `413 {"code":413,"message":"Request body too large","data":null}`**；补上外层的 `hospitalContentLengthLimitOptions(64 * 1024)`（`http_common.cj:456`，`onError` 复用同一段处理）后才闭合。文案**刻意不写具体数字**，因为同一段 `onError` 被两层复用。
- **运行期实测（本轮重建后）**：① 70 KB（带 `Content-Length`，外层闸门）⇒ `413` 信封；② 1.2 MB（`Transfer-Encoding: chunked`、无 `Content-Length`，内层闸门）⇒ `413` 信封；③ 静态资源 `Range: bytes=99999999-` ⇒ `416` 信封 + `content-range: bytes */<size>`。已在 `contract/CHANGELOG.md` 与 §十 记明。
- **契约同步**：`contract/examples/{error-invalid-json-400,error-method-not-allowed-405,error-static-not-found-404}.json` 三个样例**重新导出**为信封形状，`contract/schema-map.json` 改指 `envelope-error` 并加 `error_code` 断言，`flat-error`/`method-not-allowed`/`static-not-found` 三个 Schema **删除**（详见 §十）。

### 9.7 三条「**不改**」的处置（都是复核后的自我修正）

| 项 | 原报告说法 | 复核结论 |
|---|---|---|
| **S10** 登录锁定 | 「知道手机号即可把患者锁死 900 秒」= 中危缺陷 | **不是缺陷，是刻意的权衡，已回退**。`server/tests/rate-limit-check.ps1:6,87-88,111-113,117-121` 明确断言「锁定期内**不跑 PBKDF2**（`Sec < 0.2`，否则限流反成攻击者的 CPU 放大器）」与「锁定期内**正确口令也被拒**（防"换个大小写就是新预算"）」，并写了理由。我原先的实现（锁定期间照常校对口令）会让每次被拒请求都烧 ~0.5s PBKDF2 **并推翻这 4 条断言** ⇒ 已 `git checkout -- server/src/auth_repo.cj` 回退，改动集里该文件为 0。真要在"锁不死患者"与"不放大 CPU"之间取平衡，该改的是**限流维度**（账号+IP / 指数退避 / 只延迟不拒绝），属策略变更，需 owner 拍板 |
| **S7** `--dev-auth` 取不到 IP 时放行 | 提权风险 | **生产不可达，不改**。`http_app.cj:495-534`：只有 `--dev-auth` **且** 来自回环才认 `X-Role`；`remoteIp` 为空只在「无 http ctx」时出现，而那条路径**只有进程内调用者**（测试/自检），外部请求不可能构造。已在本报告留档，不引入无人能复现行为的改动 |
| **S16** 静态 404 平铺体 | 列为缺陷 | **本来就不是缺陷（但已顺手修掉）**：`static.cj` 的 `StaticOptions` 一直有 `notFoundBody`/`forbiddenBody`，是**应用没配**。本轮把它连同 `rangeNotSatisfiableBody` 一起配成信封 |

**S9 撤回**（§八 第 3 条已同此更正）：原报告称 `GET /api/v1/admin/users` 的 `limit/offset` 未 clamp —— 读源码后确认**已经 clamp**（`http_app.cj:1471-1478`，响应体里还会如实回 `limit`），`contract/examples/admin-users-page-clamped-200.json` 正是这条契约的样例。原结论作废，**未改一行代码**。
> ⚠ **编号勘误**：本轮早先的修改说明里把这条写成了「S8 撤回」—— **S8 是另一条缺陷**（文档与实现不符），处置见 9.8。

### 9.8 S8 文档与实现不符：停诊 / 被改停的排班到底回哪个 code

- **原报告说法**（§六 S8 行）：文档说「读到时 `enabled=1`、扣减时被停诊应回 409 `SLOT_GONE`」，实际回 **404**。
- **复核结论：实现是对的、文档写反了** ⇒ 按实现改文档（`docs/FRONTEND-INTEGRATION.md` §8.4 `:2011-2020`，2026-10-17 就地更正）。判据是同一条可售谓词 `bookingSchedulePredicate`（`domain_booking.cj:104-113`：排班 `enabled = 1 AND total_num > 0` **且**科室 `enabled = 1` **且**医生 `enabled = 1`）：
  - 入口判一次（`findBookableSchedule`，`:875-877`）⇒ 停诊的排班**根本进不了扣号**，直接 `ScheduleNotFound`；
  - 扣号 0 行后**再判一次**（`:968-971`）⇒ 「读到时 `enabled=1`、扣减时被改成 0」这条竞态也归 `ScheduleNotFound`；只有排班**仍可售**、纯粹号放完了才落 `SlotGone`（`:972`）。
- **为什么这样更对**：`SLOT_GONE` 的语义是「被别人抢走了 ⇒ 刷新列表」，而「排班被停掉」刷新也没用、该显示「该排班已停诊 / 不存在」。两者动作相同（回列表刷新）、文案不同，前端两种都要能表达（已写进文档）。
- **⚠ 这条行为是被 S2 的修复顺带改变的**：修复前「扣号 0 行」**不复查**，那条竞态确实会落到 `SlotGone`（与文档旧文案一致）；S2 加的「先按幂等键回读、再按可售谓词分类」把分类改准了 —— 所以**文档这次不改，反而会变成新的不一致**。
- **运行期证据**（本轮重建后实测）：新建排班 `930021`（doctor 1 / 2027-04-02 / AM / total 3）⇒ 先挂一单 `201`（`933652`）；`UPDATE schedule SET enabled=0 WHERE id=930021`（库里确认 `enabled=0`）后再用**另一个幂等键**挂号 ⇒ **`404 {"ok":false,"error":{"code":"SCHEDULE_NOT_FOUND","message":"排班不存在或已停诊"}}`** —— 与文档更正后的口径一致：停诊的排班是 `SCHEDULE_NOT_FOUND`，不是 `SLOT_GONE`。（探测数据已清理）

---

## 十、契约与文档同步（同日，未改任何行为代码）

### 10.1 `contract/` —— 机器可读契约（**门禁三步骤全绿**）

| 动作 | 文件 | 内容 |
|---|---|---|
| 重新导出 | `contract/examples/error-invalid-json-400.json` | 平铺 `{"code":400,"message":"Invalid JSON body","data":null}` → 信封 `{"ok":false,"error":{"code":"VALIDATION_FAILED","message":"请求体不是合法 JSON"}}` |
| 重新导出 | `contract/examples/error-method-not-allowed-405.json` | 平铺 `{"error":"Method Not Allowed","allow":"GET"}` → 信封 `METHOD_NOT_ALLOWED`（`allow` 仍在**响应头**，体里不再有） |
| 重新导出 | `contract/examples/error-static-not-found-404.json` | 平铺 `{"error":"Not Found"}` → 信封 `ROUTE_NOT_FOUND`「静态资源不存在」 |
| 改指 | `contract/schema-map.json` | 上述三条样例的 `body` 由 `flat-error` / `method-not-allowed` / `static-not-found` 改为 `envelope-error`，并补 `error_code` 断言 |
| 删除 | `contract/schema/{flat-error,method-not-allowed,static-not-found}.schema.json` | 3 个 Schema 作废（Schema 总数 **27 → 24**，body 级 **9 → 6**） |
| 更新 | `contract/README.md:16` / `:125` / `:127` | 数量与「那三种平铺形状已作废」的口径 |
| 新增 | `contract/CHANGELOG.md`（2026-10-17 条目） | 变更、原因、客户端影响；含 413 外层闸门与「框架默认值不变（仍是加法不是破坏）」 |

- 门禁口径：`server/tests/contract-check.ps1` = ①样例字节比对 ②Schema 校验 ③登记完整性（样例 ↔ `schema-map.json` 双向）；③已并入 `server/tests/final-verify.ps1`。
- `contract-check.ps1:10` 那句「某个 404 悄悄从业务信封变成平铺错误」保留 —— 它描述的是**漂移风险**，与本次收敛不矛盾。

### 10.2 `docs/` 与源码注释（共 10 个**既有**文件，均为措辞/行号，**无行为变更**；本报告为新增的第 11 个文件）

| 文件 | 改动 |
|---|---|
| `docs/FRONTEND-INTEGRATION.md` | §3.2 标题与总述改为「只有一种失败形状」+ 作废横幅；形状 (2) 非法 JSON、(4) 静态 404、(5) 405 改写信封；新增形状 (6) 413、(7) 416；新增「改前→改后对照表」（6 行真机实测）；新增「实现方式」（框架注入点 + 应用注入点）；`unwrap` 伪代码改为只认 `ok === false`（旧平铺回退 `parseLegacyFlat` 保留并注明用途）；§3.5、§4.2（新增 413 行）、患者端诊断表、§12.7、§13.1、§13.2、§14.1（新增 405/416 两行）、§14.4、§15 速查同步 |
| `docs/ADMIN-WEB.md:259` | 「服务端报 `Invalid JSON body`」→「400 `VALIDATION_FAILED`（旧版文案是 `Invalid JSON body`）」 |
| `server/README.md:457` | 路由 404 体改信封；保留"静态前缀不能带尾斜杠"的经验 |
| `server/src/http_app.cj:3047,3050-3056` | 兜底中间件注释：码表行号 `:129`→`:148`；「静态 404 仍是平铺」这条边界标为**已作废**（2026-10-17 改结论：仍不 fork 框架，因为 `StaticOptions` 本来就可配） |
| `server/tests/export-contract.ps1:5-11` | 仅注释：第三方复查那段与今天实测已不同 → 注明「2026-10-17 起框架层三种平铺体已全部改写信封」 |
| `server/tests/stress-booking.ps1:141` | 仅注释：`Invalid JSON body` → 400 `VALIDATION_FAILED` |
| `server/admin-web/js/api.js:109-113` | 仅注释：旧「没有统一信封」的举例改为 408 等未被应用接管的出口 |
| `docs/SERVER-REVIEW-2026-10-14.md:306`、`docs/SERVER-REVIEW-FIXES-2026-10-14.md:103`、`docs/CLINIC-LOOP-IMPROVEMENTS-2026-10-14.md:398` | 各**追加一行** 2026-10-17 更新说明（正文按"带日期报告不改写"的纪律保留原样） |

- **刻意保留的「旧说法」**：① `/health` 系（`docs/FRONTEND-INTEGRATION.md:33/:2146/:2233/:2415`、`docs/ADMIN-WEB.md:70` 等）—— 那是**成功**形状，不是错误形状，至今真实；② 明确标注「历史 / 已作废 / 可选回退」的段落与对照表"改前"列（保日期证据）；③ 框架 `router.cj:91-94/:104`、`static.cj:51-60` 的**默认平铺值**（框架自测仍走它以证"默认行为不变"）。
- **两个 `.ps1` 的 BOM**：`export-contract.ps1`、`stress-booking.ps1` 经 edit 工具保存后丢了 UTF-8 BOM（PS 5.1 会把中文注释解析成乱码甚至语法错），已用 `New-Object System.Text.UTF8Encoding($true)` 重写并实测首三字节 `EF BB BF`。

## 十一、同日续修：S4（DB 单连接不自愈）与 S13（AI 配置静默失效）

> 承接 §九/§十。§四 里这两条原本标「**未修**」与「**配置缺口**」，本轮都落到了代码与运行期证据上。

### 11.0 改动集（本轮新增，均无契约破坏）

| 文件 | 改了什么 |
|---|---|
| `server/third_party/qingzhou/src/db.cj` | 新增 `public type DbProbe = () -> (Bool, Int64, String)`（仓颉不接受 `?() -> …` 写法，见 11.1 坑 0）与 `DbBackend.probe()` 默认实现（自己 catch，探活失败是「答案」不是异常） |
| `server/third_party/qingzhou/src/db_mysql.cj` | **自愈核心**：`conn`/`tx` 改 `var`、新增 `drv`/`reopenUrl`/`reopenOptions`/`closed`/`reconnects`/`lastFailure`；`requireUsable()` → `ensureUsable()`（锁内重建连接）；`noteFailure()` + `isBrokenConnectionError()`；`probe()` 覆盖；`commitTransaction`/`rollbackTransaction` 的连接失效分支 |
| `server/src/http_app.cj` | `healthJson` → `healthBody` + `sendHealth`：`/health` 真的探库，库不通 ⇒ **503** + `ok:false` + `db:{ok:false,reason}`；`dbProbe` 作为可选参数从 `main` 穿到路由 |
| `server/src/main.cj` | 传 `dbProbe: { => dbProbeRef.probe() }`（闭包不能捕获 `var`，见坑 3）；AI 启动提示改走 **stderr** 并补「密钥引用解析不到」告警 |
| `server/src/ai_settings.cj` | `aiSettingsJson()` 新增 `key_ref_kind` / `key_resolvable` / `model` / `model_id` 四个字段（后两个此前只有模型行 id，排障看不出「发给了谁」） |
| `server/admin-web/js/pages.js` | AI 配置页新增告警条：`enabled && key_ref.set && key_resolvable===false` ⇒ 显式提示「密钥引用解析不到」 |
| `contract/examples/health-200.json`、`contract/schema/health.schema.json` | `/health` 增 `db` 块（`ok`/`reconnects`/可选 `reason`），`ok` 由常量改为布尔 |
| `server/tests/health-check.ps1` | 断言 `db.ok === true`（探库通了才算健康） |
| `docs/FRONTEND-INTEGRATION.md`、`contract/CHANGELOG.md` | `/health` 新形状与 503 语义、AI 启用步骤、变更记录 |

### 11.1 S4：一次连接闪断 ⇒ 全站 500 到重启

**症状**（§四 原文）：`DbMysql` 单连接，任何一次断链把 `usable` 打成 `false` 且**永不复位** ⇒ 之后每个请求都 500，只能重启进程。

**根因分三层**：① 没有重连路径（`requireUsable` 只会抛）；② 「是否废了」的判断只看 6 个英文子串，Windows 上的真实文案一条都不匹配；③ `/health` 根本不碰库，所以「进程活着 / 库已死」在监控上是同一个 200。

**实现**：

1. **连接可换**：`ensureUsable()` 在 `connectionLock` 内做「关旧 → 新建 → 重做会话口径 → 复位 `usable`、`reconnects++`」。只在两种情况下拒绝重连：已显式 `close()`（优雅关闭后不许诈尸）、`transactionActive`（事务没结束而连接坏了，重连会**静默吞掉**未提交写入 ⇒ 宁可这一个请求 500）。
2. **失效判定**：`noteFailure(msg)` 只在**链路级**文案上打 `usable=false`（`server has gone away` / `lost connection` / `broken pipe` / `connection reset` / `commands out of sync` / `error 2006/2013` / `eof` + 实测补的 `failed to read/write data`、`forcibly closed`、`connection aborted`、`10053/10054/10060`、`error 1927`）。**不**把重复键/语法错/死锁当失效 —— 否则一个重复键风暴能把库打爆。
3. **提交/回滚不假装成功**：`commitTransaction` 遇连接失效直接抛「本次事务未确认提交」（COMMIT 成没成只有服务端知道）；`rollbackTransaction` 遇失效**跳过** ROLLBACK 并返回 —— 那里一抛会盖掉 `withTransaction` 的原始异常。
4. **`/health` 探库**：真跑一次 `SELECT 1`，通了 `200`、不通 `503`；`db.reconnects` 就是「这进程自愈过几次」。失败原因**不回**驱动原文（端点不鉴权），只写日志。

**运行期证据**（真实演练，`max_connections=1` + `KILL` 掉服务端那条连接来造「库不可连」）：

| 阶段 | `/health` | `GET /api/v1/departments` |
|---|---|---|
| 基线 | `200`，`db:{ok:true,reconnects:0}` | `200` |
| 断链中 | `503`，`db:{ok:false,reconnects:0,reason:"数据库暂不可用（详见服务端日志）"}` | 触发重连，恢复后 `200` |
| 恢复额度后（**未重启进程**） | `200`，`db:{ok:true,reconnects:1}` | `200` |

**三个实测坑（都不是设计问题，是"以为写对了"）**：

- **坑 0（编译）**：`?() -> (Bool, Int64, String)` 在仓颉里解析成别的东西 ⇒ `expected ',' or ')', found '='`。只能给函数类型起别名 `DbProbe`。
- **坑 1（判定漏词）**：第一版重连**一次都没触发** —— 杀连接后驱动抛 `Failed to write data 10053: An established connection was aborted by the software in your host machine.`，六个老关键词全不匹配，`usable` 一直是 `true`。补词后 `reconnects` 才从 0 动起来。**教训**：靠文案匹配判定链路故障，必须拿真实故障的文案来校准，不能凭记忆写。
- **坑 2（池被污染）**：补词后 `reconnects` 涨到 1，但紧接着 `SELECT 1` 抛 `SqlException("closed")`，此后**再也不重连**（`closed` 不在关键词表里，`usable` 保持 `true`）。根因是复用了 `ds` —— 那是 std 的连接池，坏过一次的连接被标记 closed，`ds.connect()` 交给你的「新」连接一执行就报 closed。⇒ 改成 `drv.open(reopenUrl, reopenOptions)` **重建数据源**（新池），旧池整体丢弃。这一条不实测根本发现不了：日志上「重连成功」的假象很完整。
- **坑 3（闭包捕获）**：`main` 里 `var db` 不能被闭包直接捕获（`lambda capturing mutable variables needs to be called directly`），要先 `let dbProbeRef: DbBackend = db` 再捕获。
- **坑 4（日志看不见）**：`println` 走 stdout，在管道里是块缓冲 ⇒ 排障时「一个字都没有」。DB 诊断与 AI 启动提示全部改 `eprintln`（与 `create-admin` 打印口令同一口径）。

### 11.2 S13：AI 配好了却不生效，且没有任何提示

**症状**（§四 原文）：`ai.key_ref` 没配 / 总开关 0；分诊静默走规则兜底，页面上看不出为什么。

**为什么**不改成「解析不到就拒绝保存」：`acceptance.cj:847`、`acceptance_ai.cj:43/45/202/299/387`、`ai-live-check.ps1:118` 共 6 处夹具写的是**假引用**（`env:AC16_GLOBAL_KEY`、`file:/etc/smart-hospital/ai.key` …），硬拒会把现有套件全打红。⇒ 改走**可观测**路线（配置仍可存，但"此刻到底能不能调"必须能看见）：

1. **接口字段**：`GET /admin/ai/settings` 增 `key_ref_kind`（`env`/`file`/空，**不回变量名与路径**）、`key_resolvable`（**真去解析一次**，改完环境变量不必重启就能看到它翻 true）、`model` / `model_id`（生效的模型名与行 id）。
2. **启动日志（stderr）**：已启用时打印模型/endpoint/引用类型；**解析不到就多打一行告警**；未启用时打印原因与启用方法。
3. **管理台**：`pages.js` 在「已启用但引用解析不到」时挂告警条，直说"调用会失败并回落规则兜底"。
4. **失败可见**：分诊响应的 `ai_reason` 必须给出**人能读**的原因，而不是空着。

**运行期证据（三条路径，全部实测）**：

| 场景 | `/admin/ai/settings` | 分诊 `ai_reason` |
|---|---|---|
| A 默认（总开关 0、无 key_ref） | `enabled:false`，`disabled_reason:"未配置 ai.key_ref（必须是 env:名 或 file:路径）"` | `未配置 ai.key_ref（必须是 env:名 或 file:路径）` |
| B 已启用 + `key_ref=env:S13_TEST_KEY_UNSET`（变量不存在） | `enabled:true`，`key_ref_kind:"env"`，`key_resolvable:false` | `环境变量 S13_TEST_KEY_UNSET 未设置或为空（注意：要设在**服务进程**的环境里，不是设在你敲命令的那个窗口）` |
| C 已启用 + 变量已设 + endpoint 指向死端口 | `key_resolvable:true` | `出站调用异常：Failed to read data 10054: An existing connection was forcibly closed by the remote host.` |

B 的启动日志同时出现：`AI：**已启用** — 模型「默认对话模型」，endpoint https://…/chat/completions，密钥引用 env` + `    ⚠ 但**密钥引用解析不到**（env）：调用会失败并回落规则兜底；请检查该环境变量/文件是否存在`。

C 证明「已配置」确实会**真的发出去**（此前连发都不发），失败也能落到 `ai_reason` 上；三条路径 `source` 始终是 `rules` —— 降级不阻塞患者拿结论。

### 11.3 边界与**未做**（写清楚，免得被当成已修）

- **S4 不还原 in-flight 事务**：连接在事务中途坏掉时，只保证「不假装提交成功」，不保证重放。要重放得有业务级幂等键，那是另一件事。
- **S4 靠文案判定失效**：`isBrokenConnectionError` 是子串匹配，没有可移植错误码通道。抓不到的形态仍会走「下一次真正失败时重来一遍」的兜底路径 —— 代价是多一次失败请求，不是永久卡死。
- **单连接仍是单连接**：本轮治的是「断了能自愈」，不是「并发连池」。串行化仍是刻意设计（见 `db_mysql.cj` 顶部注释），高并发要换连接池是 P2 的事。
- **S13 的 `ai.ca_bundle_path` 仍不支持**：框架未暴露信任锚配置 ⇒ 只能自签 CA 之外的环境直连。已在配置页明示「本版本不支持」。
- **S13 只支持 `https://`**：实测 `--dev-auth` 环境下把 endpoint 指向本地 http 桩会被强制规则挡掉（这是有意的，避免把密钥发到明文通道）。
- **`hm_pat2` 的绑定**：`accept` 会清业务表，patient 2 被清掉后该账号成了孤儿（登录报 `AUTH_BAD_CREDENTIALS`）⇒ 已把 `auth_user.ref_id` rebind 到 patient 1。**这是环境修复，不是代码修复**，下次跑 `accept` 后仍需重做。

### 11.4 门禁

| 门禁 | 结果 |
|---|---|
| `hospital-server.exe selftest` | **EXIT=0**（自检全部通过） |
| `hospital-server.exe accept <dsn>` | **762 项通过 / 0 失败**，EXIT=0 |
| `server/tests/final-verify.ps1` | **17/17 全绿**（含 `contract-check`，Schema 24 个、样例 67 条 PASS 69 / FAIL 0） |
| `/health` 探库 / 503 语义 | 演练见 11.1 表 |
| S13 三条路径 | 见 11.2 表 |

> ⚠ `accept` 会**清空业务表**。跑完已复原环境：`create-admin` 重置 `admin` 口令（本机为 `EE9XLGLU9HDT`）、四个演示账号口令复位并逐个登录实测通过；库内保留 科室「内科」(1)、医生「张医生」(1)、患者「测试患者」(1)、排班 `9501`（2026-12-24 AM，总号 2）。
