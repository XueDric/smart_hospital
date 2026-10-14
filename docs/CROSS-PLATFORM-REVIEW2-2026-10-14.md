# 第二轮联合审查：修复复核与新增问题

日期：2026-10-14（UTC+8）。审查 HEAD：`a2d3402c529effdf58c77a8acce2c0e5ac49bbd8`；修复提交：`880af50`；上轮基线：`dba5204dc81ebea4cc9dc8a000d17914594ad236`。

## 结论与边界

当前后端不能编译，存在一个确定的修复回归阻断。第二轮共确认 **8 项新增发现：2 项 P1、6 项 P2**，其中 3 项由本轮修复引入，5 项为本轮新识别的既存缺陷。另有上轮 9 项鸿蒙专属问题明确未修，不重复计算为新发现。

三个只读 agent 分别复核 Android、鸿蒙与服务端，协调者交叉检查严重问题并实际编译服务端。Android 检查使用已安装的 `android-kotlin-development` 生命周期和错误处理指导，保留项目原生 Views 架构。

未改业务源码，未安装依赖，未操作设备、API、运行中的服务或数据库。审查前已有的 Android README、Gradle Wrapper 和 settings 三处修改保留。新增文件仅本报告；编译及纯函数探针保存在授权的隔离输出目录。

证据等级：R01 已实际编译复现；R04 已执行实际危急检测函数并计时；其余为高置信源码路径，尚未做设备或真实数据库复现。源码修复成立不等于构建、设备及数据库验收通过。

## 上轮 16 项问题的复核

| 旧项 | 当前状态 | 说明 |
|---|---|---|
| F01 长主诉危急漏报 | 原漏报已修，出现性能回归 | 完整文本进入危急识别，尾部危急词与否定均经纯函数复测；见 R04 |
| F02 病历保存/锁定竞态 | 原状态及内容竞态在源码上已覆盖 | 保存、锁定使用相同 draft/二进制正文/元数据快照；当前 R01 阻止构建，目标 SQL 未实测，R02 仍影响事务隔离 |
| F03 跨服务 token | 未修 | 鸿蒙公共层和 Profile 未改 |
| F04 首次角色入口 | 未修 | EntryAbility 和患者登录页未改 |
| F05 提交锁定旧值 | 未修 | 鸿蒙 EmrEditPage 未改 |
| F06 鸿蒙挂号幂等 | 未修 | BookingPage 未改 |
| F07 Android 退其他单误删键 | 原问题已修，恢复场景出现回归 | 新取消 ID 比较正确；取消结果不确定后的新单被旧 completed ID 拒绝，见 R03 |
| F08 鸿蒙开流重试 | 未修 | PrevisitPage 未改 |
| F09 在线公告 Mock | 未修 | PatientRepository.notices 仍只调用 Mock |
| F10 分诊超时 | 原模型等待问题已缓解 | Android 专属45秒；后端12秒增强额度。SQL/危急扫描仍不受总截止约束，见 R04；不是整体 HTTP 硬截止 |
| F11 Android 登录续期 | 源码已修，设备未验 | 在线不依旧期限清登录；启动 me，网络失败保留，权威拒绝清除 |
| F12 Android Insets | 源码已修，设备未验 | API30+ 系统栏、缺口、IME 绝对 padding；旧版本保留框架适配 |
| F13 鸿蒙恢复 flush | 未修 | SessionStore 两个 setter 未改 |
| F14 鸿蒙医院日期 | 未修 | todayString 仍使用设备时区 |
| F15 鸿蒙完成率单位 | 未修 | AdminRepository 原千分比条件转换未改 |
| F16 Android 姓名同步 | 源码已修，设备未验 | 解析姓名、匹配上下文后更新缓存并重绘；旧服务缺字段时保留原值 |

修复交付文件 [AUDIT-FIXES-2026-10-14.md](F:/cj_cup/smart_hospital/android-patient/AUDIT-FIXES-2026-10-14.md) 明确说明只改 Android/后端，并保留上述 9 项。`git diff dba5204..HEAD` 中没有 entry/common-core/feature-patient/feature-doctor/feature-admin 改动；再次逐项读取源码确认了这一点。

## 新问题清单

| 编号 | 优先级 | 类型 | 问题 |
|---|---|---|---|
| R01 | P1 | 修复回归 | HashMap.containsKey 不存在，当前后端无法编译 |
| R02 | P1 | 新发现的既存缺陷 | 请求共享单连接，事务范围不隔离，回滚与生成 ID 可串请求 |
| R03 | P2 | 修复回归 | 退号响应丢失后重挂成功，Android 却持续拒绝新预约结果 |
| R04 | P2 | 修复回归 | 全文危急检测出现二次复杂度，合法主诉扫描耗时12.6秒 |
| R05 | P2 | 新发现的既存缺陷 | 鸿蒙知识库编辑缺少 PUT 必需的正文，在线保存必然400 |
| R06 | P2 | 新发现的既存缺陷 | 编辑停用科室/医生会重新启用，科室排序被重置 |
| R07 | P2 | 新发现的既存缺陷 | 医生一键预填被七段空字符串覆盖，实际无预填却提示成功 |
| R08 | P2 | 新发现的既存缺陷 | 医生/管理员退出仅清本地，未吊销服务器 token |

### R01：当前服务端构建阻断

位置：[domain_emr.cj:457](F:/cj_cup/smart_hospital/server/src/domain_emr.cj:457)。新增预填逻辑使用 `patch.containsKey(k)`，而项目要求的仓颉 1.2.0 `HashMap` 使用 `contains(k)`。

协调者按 server/build.ps1 的同一业务/框架文件集、cjc 1.2.0、stdx 静态库和当前 MariaDB 驱动产物编译，输出指向隔离目录，未覆盖 server/build 的服务程序。实际输出：

```text
error: 'containsKey' is not a member of class 'HashMap<Struct-String, Struct-String>'
==> server/src/domain_emr.cj:457:28
if (!patch.containsKey(k)) {
1 error generated, 1 error printed.
Review compile exit: 1
```

最小修复：改成 `patch.contains(k)`。独立纯 HashMap 编译探针已确认该 API 正确。协调者还只在隔离副本改这一处，以副本代替原文件编译其余当前全源码，诊断编译成功 `exit=0`。**此结果确认修法并排查后续编译错误，工作区源码仍未修，不能宣称当前 HEAD 构建通过。**

回归判据：原工作区完整服务端构建通过，重新生成并验收该版本产物。诊断目录：[hospital-review2-build](C:/Users/23965/.codex/visualizations/2026/10/13/01a13611-ddef-7cb1-8cd0-db8fad7362c7/hospital-review2-build/domain_emr.cj)。

### R02：共享连接缺少完整事务隔离

证据链：[main.cj:747](F:/cj_cup/smart_hospital/server/src/main.cj:747) 向各仓储传同一个 db；[MySqlBackend:26](F:/cj_cup/smart_hospital/server/third_party/qingzhou/src/db_mysql.cj:26) 只有一个 conn/tx；[withTransaction:152](F:/cj_cup/smart_hospital/server/third_party/qingzhou/src/db.cj:152) 没有事务范围锁；驱动 [maria_connection.cj:81](F:/cj_cup/smart_hospital/server/third_party/mariadb-driver/src/connection/maria_connection.cj:81) 只对单条命令加锁，query/update 相同；[maria_transaction.cj:100](F:/cj_cup/smart_hospital/server/third_party/mariadb-driver/src/connection/maria_transaction.cj:100) begin 发送普通 BEGIN。

请求 A BEGIN→扣号→请求 B 同连接 BEGIN，MySQL 会隐式提交 A 的事务。A/B 的后续 INSERT 进入 B 的事务；一个请求 ROLLBACK 可能撤销另一个请求的 INSERT，已经提交的 A 扣号却无法回滚。非事务病历保存也可能插入其他请求的挂号事务，先报告成功而后被别人的回滚撤销。这是源码可构造的执行交错，尚未实际注入数据库失败。

[MySQL 官方事务说明](https://dev.mysql.com/doc/refman/8.4/en/implicit-commit.html) 明确说明 BEGIN/START TRANSACTION 会隐式提交现有事务，不能嵌套。逐条命令锁不能提供请求级事务隔离。

同一根因还影响 [insertAppointment:580](F:/cj_cup/smart_hospital/server/src/domain_booking.cj:580) 的 INSERT 与后续独立 [LAST_INSERT_ID:600](F:/cj_cup/smart_hospital/server/src/domain_booking.cj:600)：两者之间其他请求的 INSERT 可改变该连接的 ID，响应关联到错误的挂号单。

最小安全修复：请求/事务独占连接，在完整生命周期归还；临时共享连接方案必须隔离事务期间的**所有** query/exec，单独锁 withTransaction 不够。保持同连接的生成 ID 读取原子性。回归：在隔离数据库单服务进程中并发挂号、退号、保存病历，强制 BEGIN/扣号/INSERT 交错及失败，断言号源守恒、失败无残留、成功病历不回滚、返回预约 ID 正确。已有成功抢号压力不能替代这些失败交错断言。

### R03：取消响应不确定后的旧 completed ID 拒绝新单

位置：[SessionStore.kt:152](F:/cj_cup/smart_hospital/android-patient/app/src/main/java/com/smart/hospital/patient/data/SessionStore.kt:152)、[PatientRepository.kt:185](F:/cj_cup/smart_hospital/android-patient/app/src/main/java/com/smart/hospital/patient/data/PatientRepository.kt:185)。新护栏只要本地 `completed` 非空且不等于返回预约 ID，就拒绝完成结果。

复现：成功挂 A，保存 completed=A/token=T；退 A 在服务器提交，但返回超时或断开，客户端未做取消清理；刷新可见 A 已取消；再次挂同排班。后端 [domain_booking.cj:875](F:/cj_cup/smart_hospital/server/src/domain_booking.cj:875) 已释放 T，新请求可创建 B并实际扣号、返回201；客户端仍记 A，拒绝 B并报 BOOKING_CHANGED。后续重试服务器重放 B，客户端仍拒绝。预约列表 [PatientRepository.kt:192](F:/cj_cup/smart_hospital/android-patient/app/src/main/java/com/smart/hospital/patient/data/PatientRepository.kt:192) 没有同步该生命周期；键跨重启与退出保留，因此刷新、重启或重登不能恢复。另一设备或管理员取消 A也触发同一根因。

最小修复：以权威预约状态同步本地 completed/cancelled 生命周期，在确认旧 A取消后允许接受新 B；保留迟到旧响应防护，不能简单去掉 ID 比较。回归：取消提交后丢响应、外部取消、旧响应晚到/新单先到和进程重启均保持正确，实际新单不被持续显示为失败。

### R04：全文危急规则扫描存在二次复杂度

位置：[redFlagHit:295](F:/cj_cup/smart_hospital/server/src/triage_redflag.cj:295)、[字符到字节换算:333](F:/cj_cup/smart_hospital/server/src/triage_redflag.cj:333)、[字节到字符换算:350](F:/cj_cup/smart_hospital/server/src/triage_redflag.cj:350)。每次否定命中都重新从文本开头扫描以转换索引。修复 F01后输入不再限为前500字，重复否定词产生接近 O(n²) 的工作量。

使用实际源码的纯函数探针输入 `“无胸痛”重复n次`，本机输出：

| n | UTF-8字节 | 危急判定 | 耗时毫秒 |
|---|---|---|---|
| 500 | 4500 | false | 79 |
| 1000 | 9000 | false | 272 |
| 2000 | 18000 | false | 991 |
| 4000 | 36000 | false | 3869 |
| 7000 | 63000 | false | 12644 |

7000项加 JSON包装仍小于64KiB请求限制。扫描发生于 [triage.cj:435](F:/cj_cup/smart_hospital/server/src/triage.cj:435)，而12秒增强截止到 [http_app.cj:1423](F:/cj_cup/smart_hospital/server/src/http_app.cj:1423) 才建立；扫描12.6秒后还能再等模型，可能超过鸿蒙20秒等待，多请求并发还会放大CPU占用。测量是本机数值，不推广为所有硬件的固定耗时。

修复：一次 Rune扫描并缓存字节索引/前缀关系，匹配和否定窗口保持线性；继续识别完整主诉，不能恢复有漏报的截断方案。回归：危险/否定词位于长文本末尾均准确；长度翻倍耗时不再近四倍，并检查全链路截止覆盖范围。探针：[probe.cj](C:/Users/23965/.codex/visualizations/2026/10/13/01a13611-ddef-7cb1-8cd0-db8fad7362c7/hospital-audit-round2-redflag-0b095abee09349cda30dc7eb5bf3ca51/probe.cj)。

### R05：知识库编辑请求不符合整体替换契约

位置：[KnowledgeBasePage.ets:101](F:/cj_cup/smart_hospital/feature-admin/src/main/ets/pages/KnowledgeBasePage.ets:101)。编辑只发 title/category/enabled，缺 body。后端 [http_kb.cj:198](F:/cj_cup/smart_hospital/server/src/http_kb.cj:198) 将缺 body变空，按 PUT整体替换，再由 [kb_repo.cj:513](F:/cj_cup/smart_hospital/server/src/kb_repo.cj:513) 拒绝“正文不能为空”。任意已有文档修改标题或分类在线保存都返回400。

修复：编辑前 GET详情，提交保留的原正文或新正文；列表不含 body，不能仅靠列表拼 PUT。回归：只改标题/分类能成功，正文与块数据按约定保持正确。

### R06：编辑操作覆盖启用状态和排序

位置：[DoctorsPage.ets:75](F:/cj_cup/smart_hospital/feature-admin/src/main/ets/pages/DoctorsPage.ets:75)、[DepartmentsPage.ets:69](F:/cj_cup/smart_hospital/feature-admin/src/main/ets/pages/DepartmentsPage.ets:69)。创建和编辑均固定 enabled=true，科室还固定 sort=0；edit不保存原值。服务器按请求写 enabled/sort，因此仅修改停用实体的姓名、职称或位置，也会重新启用；非零科室排序被重置。

修复：编辑状态携带原 enabled/sort，只在明确更改时覆盖；新建使用默认值。回归：停用医生/科室改描述后仍停用，排序不改变；重新启用须明确操作。

### R07：一键预填的空 patch屏蔽问诊内容

位置：[EmrEditPage.ets:57](F:/cj_cup/smart_hospital/feature-doctor/src/main/ets/pages/EmrEditPage.ets:57)、[prefill:124](F:/cj_cup/smart_hospital/feature-doctor/src/main/ets/pages/EmrEditPage.ets:124)、[domain_emr.cj:457](F:/cj_cup/smart_hospital/server/src/domain_emr.cj:457)。valuesMap对全部七段发字段，包括空字符串；后端预填只补 patch未包含的字段，再应用 patch，因此七个空 key屏蔽主诉/现病史/既往史/过敏史。修复 R01使源码可运行后，新空病历且客户端持有对应患者有效 session ID时，预填会建空草稿并提示成功。

修复：预填动作仅提交医生实际已填的非空段，其余省略；普通保存继续允许空串用于清字段。回归：四段问诊正确预填，医生已有输入优先。独立医生设备目前也缺从选中患者获取问诊 ID的流程，正常场景可能看不到入口；这是另一个流程衔接缺口，不与本项重复计数。

### R08：高权限角色注销未吊销在线凭据

位置：[VisitQueuePage.ets:112](F:/cj_cup/smart_hospital/feature-doctor/src/main/ets/pages/VisitQueuePage.ets:112)、[AdminRoot.ets:45](F:/cj_cup/smart_hospital/feature-admin/src/main/ets/AdminRoot.ets:45)。医生/管理员退出仅clearLogin并跳登录，不调用后端 logout；患者 Profile则已调用。服务器 [http_app.cj:1005](F:/cj_cup/smart_hospital/server/src/http_app.cj:1005) 只有收到注销才吊销该 token，故本地退出后旧 token仍有效，直到其他吊销或到期。

修复：两个角色均调用公共注销接口，再清本地身份；网络失败也允许本地退出，并清楚表达在线吊销未确认。回归：在线正常注销后，保存的旧 token请求被401拒绝，其他设备会话按既有规则保留。

## 已排除与待验证

- 新错误码实际为 `EMR_CHANGED`，不是 `EMR_CONFLICT`。服务端正确映射409；鸿蒙通用错误信封会正常抛错，未枚举常量不构成解析不兼容。冲突后的重新读取/合并入口仍不足，但不另计高置信新bug。
- AI worker持有独立options/prompt，不捕获数据库、HTTP响应或规则结论；未发现新增跨线程DB访问或迟到结果覆盖响应。
- 未发现 Android 当前生命周期/后台身份切换足以稳定触发的新覆盖问题，不重新报告旧候选。普通 SharedPreferences存 token是源码事实，但没有仅据技能建议把它计为已证实漏洞。
- 鸿蒙名称字段、旧科室标签、公告缺口、医生问诊ID来源，以及成功验收夹具固定过去日期等上轮补充事项尚未处理。鸿蒙姓名同步也没有覆盖 Android F16的修复。
- 未执行 Android/Harmony整包构建、设备布局、Release签名、真实TLS/SSE、MySQL/MariaDB并发及SQL行为验收。病历快照参数/顺序经源码复核无明确错误，实际数据库验证仍必需。

## 最小修复与验收顺序

1. 后端 owner先修 R01，并让原工作区构建通过；当前隔离诊断编译产物不作为发布产物。
2. 后端 owner处理 R02连接/事务归属，再由独立QA在隔离数据库验证失败交错、号源与病历守恒。
3. Android owner修 R03取消结果不确定的恢复；后端 owner修 R04线性全文检测与总等待预算。
4. 鸿蒙 owner处理上轮保留的9项及 R05–R08；公共会话层由单一owner修改，其他agent只复核。
5. 重新构建两端并做在线回归，记录源码版本、产物、数据库实例、模式和具体失败路径；不能用上轮APK通过代替本版本验收。
