# 鸿蒙、Android 与服务端联合审查

审查日期：2026-10-14（UTC+8）。基线：`dba5204dc81ebea4cc9dc8a000d17914594ad236` 加当前工作区。

## 范围与证据边界

采用项目 `multi-agent-orchestration` 工作流：Android 内部审查、鸿蒙与 Android 患者端对照、服务端契约审查三个只读 agent 并行；主协调复核严重问题，补查鸿蒙医生/管理端并汇总。完成判据是给出当前源码中的具体触发路径、定位、最小修复和回归判据，而非泛化最佳实践。

保留审查开始时已有的三个修改：`android-patient/README.md`、`android-patient/gradle/wrapper/gradle-wrapper.properties`、`android-patient/settings.gradle.kts`。本轮没有修改业务代码、安装依赖、构建应用、操作设备、请求业务 API 或操作数据库。

严重度：P1 为优先修复的医疗数据/安全/角色流程问题；P2 为明确的功能、可靠性或跨端契约缺陷；P3 为低影响展示问题。下列项目均有源码证据、置信度高；除 F01 的纯函数探针外，具体设备/网络/数据库复现尚未运行。并发问题由源码交错顺序确认，不冒充数据库并发实测。

## 问题总表

| 编号 | 优先级 | 所属 | 问题 |
|---|---|---|---|
| F01 | P1 | 后端 → 两端 | 截断主诉后才检查危急征象，尾部危急症状可被丢弃 |
| F02 | P1 | 后端病历 | 草稿保存可改写已锁定病历；锁定前的必填校验也存在竞态 |
| F03 | P1 | 鸿蒙公共层 | 修改服务地址仍携带旧服务的 Bearer token |
| F04 | P1 | 鸿蒙入口 | 首次安装没有医生/管理员登录入口 |
| F05 | P1 | 鸿蒙医生端 | 直接提交锁定会锁旧草稿，丢弃当前输入 |
| F06 | P2 | 鸿蒙挂号 | 切换号源或离开页面会丢失结果未确定的幂等键 |
| F07 | P2 | Android 挂退号 | 退同排班另一张单会删掉仍有效预约的幂等键 |
| F08 | P2 | 鸿蒙预问诊 | 初始开流失败后当前页面无法重试 |
| F09 | P2 | 鸿蒙公告 | 在线模式永久读取 Mock 公告 |
| F10 | P2 | 两端 ↔ 后端 | 分诊客户端超时短于模型默认超时，降级结果送不到客户端 |
| F11 | P2 | Android ↔ 后端 | 旧本地期限清除后端已续期的有效登录 |
| F12 | P2 | Android 布局 | targetSdk 35 下自建 Views 未处理系统栏 Insets |
| F13 | P2 | 鸿蒙存储 | 配置和预问诊 ID setter 没有 flush，进程重启可能丢恢复 |
| F14 | P2 | 鸿蒙日期 | 使用设备日期，与后端和 Android 医院时区不一致 |
| F15 | P2 | 鸿蒙管理端 | 完成率低于等于 10% 时被放大十倍 |
| F16 | P3 | Android 身份 | “同步身份”丢弃姓名，成功提示后仍显示旧值 |

## 具体证据、修复与回归判据

### F01：危急征象检查发生在截断之后

定位：[http_app.cj:1398](F:/cj_cup/smart_hospital/server/src/http_app.cj:1398)、[triage_redflag.cj:378](F:/cj_cup/smart_hospital/server/src/triage_redflag.cj:378)。超过 1500 字节的主诉先截成 500 字符，再进入 `triageComplaint` / `detectRedFlag`。Android 输入没有鸿蒙页面的 500 字限制，可直接触发；API 使用者同样可触发。

已用实际危急词检测源码和实际截断函数编译纯函数探针：`“咳嗽。”重复200次 + “胸痛”`，输出 `input_bytes=1806; raw_red_flag=true; after_http_truncation_red_flag=false; truncated_bytes=1500`。因此不是仅凭字符串猜测。没有危险症状的前 500 字会继续普通分诊；是否输出有号推荐取决于数据库号源，但危急分类丢失本身已证实。

探针由 cjc 1.2.0 编译，源码与产物保留在本机审查目录：[可复查探针](C:/Users/23965/.codex/visualizations/2026/10/13/01a13611-ddef-7cb1-8cd0-db8fad7362c7/hospital-audit-redflag-830b586a89554ee79345a9174198d688/redflag_probe.cj)。复跑方式：

```powershell
cjc "C:/Users/23965/.codex/visualizations/2026/10/13/01a13611-ddef-7cb1-8cd0-db8fad7362c7/hospital-audit-redflag-830b586a89554ee79345a9174198d688/redflag_probe.cj" -o "C:/Users/23965/.codex/visualizations/2026/10/13/01a13611-ddef-7cb1-8cd0-db8fad7362c7/hospital-audit-redflag-830b586a89554ee79345a9174198d688/redflag_probe.exe"
& "C:/Users/23965/.codex/visualizations/2026/10/13/01a13611-ddef-7cb1-8cd0-db8fad7362c7/hospital-audit-redflag-830b586a89554ee79345a9174198d688/redflag_probe.exe"
```

修复：在合理请求体上限内先对完整主诉执行危急检测，再限制常规检索/模型输入；或明确拒绝过长输入并要求补充，不能静默删除后再给普通结论。回归：危急词在边界前后、长文本末尾、含否定上下文，均保留既有危急和否定规则。

### F02：病历写入与锁定并非同一原子约束

定位：[domain_emr.cj:424](F:/cj_cup/smart_hospital/server/src/domain_emr.cj:424)、[domain_emr.cj:442](F:/cj_cup/smart_hospital/server/src/domain_emr.cj:442)、[domain_emr.cj:534](F:/cj_cup/smart_hospital/server/src/domain_emr.cj:534)。保存先读取并判断 `isLocked`，但实际更新只有 `WHERE id = ?`；锁定独立读取必填内容，再按 `status=draft` 更新状态。HTTP 处理器没有包住这两个阶段的事务行锁。

交错一：A 保存读到 draft → B 提交锁定成功 → A 更新全文，已 locked 内容被改写，患者端可见未经该次锁定确认的新内容。交错二：A 锁定读到完整病历 → B 保存清空诊断/处理意见 → A 只按状态锁定，必填校验与锁定内容不一致。

修复：以事务行锁或可靠版本控制串行化同一病历的读、合并、必填校验与写入；保存的数据库更新必须约束 draft 状态并处理未命中。只给保存补 `WHERE status=draft` 不能单独解决第二种交错。回归：并发保存/锁定后锁定内容不可变，锁定结果必填完整；失败响应和数据库状态一致。

### F03：跨服务配置切换未隔离身份

定位：[ProfilePage.ets:74](F:/cj_cup/smart_hospital/feature-patient/src/main/ets/pages/ProfilePage.ets:74)、[HttpClient.ets:48](F:/cj_cup/smart_hospital/common-core/src/main/ets/network/HttpClient.ets:48)。在 A 登录后把 Base URL 改为 B，页面仅修改配置，下一次同步身份或业务请求仍把 A 的 token 发给 B。模式切换也保留旧身份和预问诊状态。

Android 的 [SessionStore.kt:46](F:/cj_cup/smart_hospital/android-patient/app/src/main/java/com/smart/hospital/patient/data/SessionStore.kt:46) 已在地址改变时清登录，属于确切的跨端差异。

修复：地址/模式改变时清登录、预问诊及业务缓存，回到登录页；在途响应绑定发起时的地址与身份，拒绝应用旧上下文结果。回归：切换 B 后所有请求不含 A 的凭据，A 的延迟响应不能清除或覆盖 B 的会话。

### F04：医生/管理员入口依赖尚不能产生的缓存角色

定位：[EntryAbility.ets:14](F:/cj_cup/smart_hospital/entry/src/main/ets/entryability/EntryAbility.ets:14)、[LoginPage.ets:37](F:/cj_cup/smart_hospital/feature-patient/src/main/ets/pages/LoginPage.ets:37)。首次安装 role 为空，只注册患者登录；患者登录拒绝 doctor/admin；当前没有导航到另外两个登录入口。角色模块存在但首次用户无法进入。

修复：统一登录后按服务器 role 分发，或提供三个角色的登录入口。回归：清空应用数据后分别登录 patient/doctor/admin，三个角色均可到达各自首页。Android 只定位患者端，不把它没有医生/管理员模块列为缺陷。

### F05：提交锁定不保存当前编辑值

定位：[EmrEditPage.ets:95](F:/cj_cup/smart_hospital/feature-doctor/src/main/ets/pages/EmrEditPage.ets:95)、[DoctorRepository.ets:98](F:/cj_cup/smart_hospital/feature-doctor/src/main/ets/data/DoctorRepository.ets:98)、[http_p4.cj:381](F:/cj_cup/smart_hospital/server/src/http_p4.cj:381)。先保存一份完整草稿，再修改诊断或医嘱，直接点“提交锁定”；该动作只调用 lock，不提交 `valuesMap()`，随后服务器旧 sections 覆盖页面 values，旧内容被锁定，新输入丢失。新病历则可能因服务器仍没有必填内容而锁定失败。

修复：提交前保存当前编辑值并确认成功，再锁定；更完整方案是原子“保存并提交”。保存中禁止继续编辑，避免响应覆盖后续输入。回归：直接提交后患者所见内容必须等于医生点击时的最新输入，失败时保留输入。

独立反证复核确认没有隐藏自动保存；医生常规提交静默丢失诊断/处理意见且锁定后需要管理员解锁，故定为 P1。

### F06：鸿蒙幂等键只有单页单号源生命周期

定位：[BookingPage.ets:98](F:/cj_cup/smart_hospital/feature-patient/src/main/ets/pages/BookingPage.ets:98)、[domain_booking.cj:674](F:/cj_cup/smart_hospital/server/src/domain_booking.cj:674)。A 挂号已提交但响应丢失 → 选 B 生成另一 token → 再选 A 生成新 token，服务器只按 `(patient_id, client_token)` 去重，能再次创建 A 并扣号。离开页面或进程终止也会丢键。

Android [SessionStore.kt:114](F:/cj_cup/smart_hospital/android-patient/app/src/main/java/com/smart/hospital/patient/data/SessionStore.kt:114) 已按服务、患者和号源持久化并复用 token。

修复：按身份/号源保存未确定请求的幂等键；重入和成功重放仍保留，确认相应预约取消后再释放。回归：响应丢失后切号源、返回、重启，A 始终重放同一预约且只扣一次。

### F07：Android 取消按号源清键而非按预约清键

定位：[PatientRepository.kt:188](F:/cj_cup/smart_hospital/android-patient/app/src/main/java/com/smart/hospital/patient/data/PatientRepository.kt:188)、[SessionStore.kt:136](F:/cj_cup/smart_hospital/android-patient/app/src/main/java/com/smart/hospital/patient/data/SessionStore.kt:136)。本机 A 保存 token T，另一设备同患者同排班创建 B；本机退 B 就无条件删除排班下 A 的 T，后续重试生成新键创建 C。服务器唯一约束 [schema.cj:354](F:/cj_cup/smart_hospital/server/src/schema.cj:354) 没有禁止不同 token 的同排班多单，因此前提成立。

修复：原子比较本地 completed appointment ID 与取消的 ID，只清匹配的键；同时处理取消响应晚到、新预约已完成的顺序。回归：退 B 后重试仍重放 A，不产生 C、不额外扣号。

### F08：鸿蒙预问诊开流失败后无法在当前页恢复

定位：[PrevisitPage.ets:79](F:/cj_cup/smart_hospital/feature-patient/src/main/ets/pages/PrevisitPage.ets:79)、[PrevisitPage.ets:284](F:/cj_cup/smart_hospital/feature-patient/src/main/ets/pages/PrevisitPage.ets:284)。成功前先加入 messages；catch 仅显示错误。连接失败、缺 done、或流后 GET 失败时 messages 非空而 nextSlot 为空，开始按钮隐藏，输入及提交禁用，没有失败重试入口。用户可能通过退出重进恢复，但当前页操作流程已中断。

修复：无 ID 时恢复起始表单；有 ID 时重读现有会话，提供重试、重开和返回入口。回归：分别在连接前、meta 后、done 后 GET 阶段断网，再恢复网络，均能继续且不重复创建会话。

### F09：在线公告错接 Mock

定位：[PatientRepository.ets:225](F:/cj_cup/smart_hospital/feature-patient/src/main/ets/data/PatientRepository.ets:225)、[http_notice.cj:133](F:/cj_cup/smart_hospital/server/src/http_notice.cj:133)。`notices()` 永久返回 Mock，未判断模式，也未访问已经存在的 `GET /api/v1/notices`；院方发布/撤下的公告不会进入患者页面。

修复：在线异步取真实 items，演示模式才使用 Mock，补加载与重试。回归：发布、修改、下架公告后患者列表及时反映变化。Android 没有公告页面和请求，另记为功能缺口，不能描述成它已经正确接入。

### F10：模型等待与客户端超时不一致

定位：[ApiClient.kt:70](F:/cj_cup/smart_hospital/android-patient/app/src/main/java/com/smart/hospital/patient/data/ApiClient.kt:70)、[HttpClient.ets:61](F:/cj_cup/smart_hospital/common-core/src/main/ets/network/HttpClient.ets:61)、[ai_settings.cj:147](F:/cj_cup/smart_hospital/server/src/ai_settings.cj:147)、[http_app.cj:1422](F:/cj_cup/smart_hospital/server/src/http_app.cj:1422)。Android 普通读取等待 15 秒、鸿蒙 20 秒，后端同步模型默认读写超时 30 秒，配置允许到 300 秒。开启模型后，超过客户端等待时间的合法响应或规则降级，客户端先报 NETWORK。

修复：给分诊建立明确的整体截止时间，约束模型/RAG预算，并匹配客户端端点专属等待时间，保留余量；不能只加自动重试。回归：模拟 16、21、30 秒模型响应/超时，两个客户端均按约定收到结果或明确超时，后端降级可送达。

### F11：滑动续期没有同步本地有效期

定位：[SessionStore.kt:71](F:/cj_cup/smart_hospital/android-patient/app/src/main/java/com/smart/hospital/patient/data/SessionStore.kt:71)、[MainActivity.kt:94](F:/cj_cup/smart_hospital/android-patient/app/src/main/java/com/smart/hospital/patient/MainActivity.kt:94)、[auth_repo.cj:825](F:/cj_cup/smart_hospital/server/src/auth_repo.cj:825)。D0 登录本地到期 D30；D20 请求后服务端延至 D50；D31 重启 Android 仍按 D30 清登录并清恢复状态。`auth/me` 不返回新期限，客户端也没有更新渠道。

修复：本地期限到达后先通过权威身份接口判断，不独自清在线 token；或扩充最新期限契约并同步。回归：模拟上述时间顺序仍保持有效在线会话，真实过期/撤销则清除。

### F12：Android 15 系统栏安全区域缺失

定位：[MainActivity.kt:87](F:/cj_cup/smart_hospital/android-patient/app/src/main/java/com/smart/hospital/patient/MainActivity.kt:87)、[build.gradle.kts:21](F:/cj_cup/smart_hospital/android-patient/app/build.gradle.kts:21)。targetSdk 35，满屏 FrameLayout 和自建导航/标题没有 WindowInsets、fitsSystemWindows 或退出边缘布局配置。Android 15 默认边缘布局下可能覆盖顶部 banner 和底部操作；具体遮挡程度需设备验证。

修复：对原生 Views 应用系统栏和 display cutout Insets，并验证输入法可见性。回归：API 35 手势、三键、缺口屏和键盘弹出时核心按钮可见可点。依据：[Android 官方 Views 指南](https://developer.android.com/develop/ui/views/layout/edge-to-edge)。

### F13：鸿蒙配置及问诊恢复没有主动落盘

定位：[SessionStore.ets:100](F:/cj_cup/smart_hospital/common-core/src/main/ets/storage/SessionStore.ets:100)。两个 setter 仅 putSync，不 flush；后续登录/清登录才可能顺带 flush。登录后创建问诊或修改配置，随即终止进程，恢复值可能仍是旧值。依据：[华为 Preferences 文档](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-data-preferences)，缓存修改与持久化有区别。

修复：setter 统一 flush，处理失败，必要时等待恢复 ID 持久化完成再确认。回归：创建会话后直接终止并重开，能读取同一 session；配置保存后重启值一致。尚未执行鸿蒙进程终止实测。

### F14：鸿蒙查询日期跟随设备时区

定位：[Theme.ets:131](F:/cj_cup/smart_hospital/feature-patient/src/main/ets/ui/Theme.ets:131)、[BookingPage.ets:57](F:/cj_cup/smart_hospital/feature-patient/src/main/ets/pages/BookingPage.ets:57)。todayString 用设备本地年月日，默认查询及“过去日期”过滤均依赖它；Android [MainActivity.kt:651](F:/cj_cup/smart_hospital/android-patient/app/src/main/java/com/smart/hospital/patient/MainActivity.kt:651) 与后端医院日期按 UTC+8。跨时区且日期不一致时，会查错日期或隐藏医院仍可预约的当天号源。

修复：明确统一医院时区或使用后端返回医院日期。回归：固定同一时刻，设备切换 UTC+8/UTC/UTC+9 等时区，两端查询和过滤一致。

### F15：千分比转换随数值改变

定位：[AdminRepository.ets:319](F:/cj_cup/smart_hospital/feature-admin/src/main/ets/data/AdminRepository.ets:319)、[dashboard.cj:229](F:/cj_cup/smart_hospital/server/src/dashboard.cj:229)。后端字段始终是 `done * 1000 / total`，客户端仅值大于 100 时才除 10。1/20 完成返回 50，却显示 50%，正确是 5%；2/20 返回 100，显示 100% 而非 10%。

修复：按固定单位始终除 10，精度策略另行统一。回归：0/20、1/20、2/20、3/20、20/20 均准确，边界没有跳变。

### F16：同步身份未同步姓名

定位：[PatientRepository.kt:64](F:/cj_cup/smart_hospital/android-patient/app/src/main/java/com/smart/hospital/patient/data/PatientRepository.kt:64)、[MainActivity.kt:488](F:/cj_cup/smart_hospital/android-patient/app/src/main/java/com/smart/hospital/patient/MainActivity.kt:488)、[http_app.cj:1098](F:/cj_cup/smart_hospital/server/src/http_app.cj:1098)。服务器返回 display_name，但 Android CurrentUser/me 丢弃，成功回调只提示，不更新存储和姓名展示。

修复：解析姓名，确认身份上下文匹配后更新缓存与界面。回归：管理员改名，患者同步后首页/个人页显示新姓名。

## 差异与验证缺口

- 鸿蒙还忽略部分服务端新增的医生/科室名称和病历就诊信息：[PatientRepository.ets:277](F:/cj_cup/smart_hospital/feature-patient/src/main/ets/data/PatientRepository.ets:277)。Android 已解析。鸿蒙挂号页应逐条使用实际排班名称，避免改变筛选后仍沿用路由里的旧科室标签。
- SSE 主诉方式不同：鸿蒙 query、Android 空 query 开流后 JSON answer。服务端支持两种，未发现由此产生的必然契约错误；query 方式会让敏感文本进入 URL，可沿 Android 方式统一。
- 已核对的核心路径包括登录/身份、排班、分诊、预问诊开流与 answer、挂号/退号、患者病历列表/详情。未发现足以报告的 Android 路径、请求方法或基础信封字段整体不匹配。此结论不代替在线联调。
- 上轮 SSE done、主诉 JSON、冷却按钮状态分离、Android 幂等键持久化、退号 slot_restored 警示均已有实现，没有重复报告为未修。
- 服务端成功测试夹具仍大量使用已过去的 `2026-10-08`：[acceptance.cj:237](F:/cj_cup/smart_hospital/server/src/acceptance.cj:237)。新可售日期规则会拒绝它们，需要用动态当前/未来日期更新成功夹具；历史负例继续保留。本轮没有运行有数据库副作用的套件。
- 未验证：完整 Android/Harmony 构建、真机布局、Release 签名、真实 TLS 信任、慢网 SSE、目标数据库 SQL 兼容与并发守恒。已有文档中的“待复测”没有转换为已通过。

## 安卓技能检索与后续工作流

已读取 find-skills，检查 skills.sh 并尝试 `npx skills find android`；本机 CLI 未返回结果，转为在线目录和源仓库核查，没有安装软件。

读取并采用 [android-kotlin-development](https://github.com/aj-geddes/useful-ai-prompts/blob/main/skills/android-kotlin-development/SKILL.md) 的生命周期、配置变化和错误处理清单。检索时目录显示约 1.4K 安装，源仓库约 359 stars：[目录](https://skills.sh/aj-geddes/useful-ai-prompts)、[源仓库](https://github.com/aj-geddes/useful-ai-prompts)。它大量面向 MVVM/Compose/Retrofit，本项目为原生 Views，仅采用适用的审查项，没有据此要求整体重写。

官方 [android/skills](https://github.com/android/skills) 检索时约 7.8K stars；其 edge-to-edge skill 明确要求 Compose，不适合直接套本工程，因此 F12 使用官方 Views 文档。未核实的单技能安装数不编造。

建议修复协作顺序：

1. 后端 owner 修 F01/F02，独立 QA 用长主诉纯函数及隔离测试库并发验证。
2. 鸿蒙 owner 修 F03/F04/F05/F06/F08/F09，再补存储、日期、名称与比例。公共层修改由单一 owner 负责。
3. Android owner 修 F07/F11/F12/F16；F10 由后端和两端共同确定截止时间契约。
4. 独立 QA 先修动态日期夹具，再在隔离数据库和声明明确的在线模式下跑流程；检查账号、地址、模式切换、响应丢失和进程重启。

本轮产物是审查报告，共 5 项 P1、10 项 P2、1 项 P3。最小下一步为先修 F01/F02/F03/F04/F05 并添加对应有区分力的回归，再处理患者挂号/问诊主流程。
