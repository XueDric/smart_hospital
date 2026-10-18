# 版本历史（CHANGELOG）

> **仓库**：<https://github.com/XueDric/smart_hospital.git>（默认分支 `main`）
> **版本口径**：服务端 `SERVER_VERSION = 0.2.0-p1`（`server/src/main.cj:34`）；`-p<N>` 表示 P0–P5 六阶段全部交付后的维护批次。
> **提交跨度**：2026-10-07 → 2026-10-17，107 个提交（截至 tag `v0.2.0-p1-rev`），6 位贡献者。完整历史见 `git log`，本文件只记录**对外可见的能力变化**与**关键缺陷修复**。
> 格式参考 [Keep a Changelog](https://keepachangelog.com/)，按日期倒序。

---

## [0.2.0-p1-rev.1] 2026-10-18 —— 三端联调与同事提交审查批次

> 本轮做了两件事：① 鸿蒙患者/医生/管理端 + 安卓端同一条服务端上跑全流程（记录见 [docs/联调记录-2026-10-18.md](docs/联调记录-2026-10-18.md)）；
> ② 审查同事 `2cbf080` / `de47f6f` / `4265188` 三个提交并修掉其带入的缺陷（记录见 [docs/审查-同事提交-2026-10-18.md](docs/审查-同事提交-2026-10-18.md)）。
> 接口契约的破坏性变更：**无**；新增两个加法字段（病历 `version`、看板沿用既有 `trend_days`）。

### 修复（三端联调轮，7 条）

- **挂号成功后号源余量不刷新**（`feature-patient` 的 `BookingPage`）：只在 `SLOT_GONE` 分支重查，
  成功路径不刷新，卡片仍显示旧余量。改为成功后 `await loadSchedules(true)`（保留成功提示）。
- **登录响应 `patient_id` 不分角色**（`server/src/http_app.cj`）：医生登录时 `patient_id` 直接等于 `ref_id`，
  与 `/auth/me`（医生 `patient_id=0`）自相矛盾。改为按角色给值。
- **未来日期的号可以被当今天接诊**（客户端两侧）：队列里 2026-12-24 的号能一路"到院 → 候诊 → 接诊 → 完成"。
  鸿蒙与安卓都加了日期守卫（红条提示），服务端硬门槛仍待补（见下方"已知遗留"）。
- **医生队列"今日"名不副实**（`feature-doctor`）：分段写"今日"但服务端无日期参数、返回全部号。
  改为 `全部 / 上午 / 下午` 并把副标题写明"含历史与未来日期"。
- **看板"分诊命中率"永远是 0**（`feature-admin`）：`AdminRepository` 里硬编码 `result.triageHitPct = 0;`，
  服务端没有这个字段。改为真实计数「分诊调用 / 预警次数」。
- **挂号趋势含未来日期、且 14 天写成"近 7 日"**（`server/src/dashboard.cj` + `DashboardPage.ets`）：
  SQL 只设下界，2026-12-24 的号会画进趋势；标题又硬编码"近 7 日"。改为上下界都给 + 标题跟随 `trend_days`。
- **挂号列表忽略号源自带的科室/医生名**（`feature-patient`）：从"常用服务 → 预约挂号"进入时显示"科室 #1 / 医生 #1"，
  只有从分诊推荐进来才显示名字。改为优先用号源行的 `department_name / doctor_name / doctor_title`。

### 修复（同事提交审查轮，3 条 + 1 条硬保证）

- **医生队列整页崩成"响应内容不完整"**：`ContractParser.appointment()` 必填 `schedule_id`，
  而 `/api/v1/doctor/visits` 的 items 没有这个字段（患者端列表才有）。改为可选。
- **病历编辑器打不开**：`ContractParser.record()` 必填 `version`，服务端 `medicalRecordJson()` 从不输出。
  服务端补 `version`（= `updated_at`，即乐观锁令牌）。
- **乐观锁被静默绕过**：安卓发 `expected_version`，服务端读 `expected_updated_at` ⇒ 每次写都是无条件覆盖。
  安卓改发 `expected_updated_at`，版本判断从"必须 +1"改为"必须递增"。
- **服务端补 `emrNextStamp()`**（`server/src/domain_emr.cj`）：`updated_at` 是秒级时间戳，同一秒两次写会原地不动，
  而客户端把它当版本号。改为"时间前进就用时间，否则 +1"，`saveDraft / lock / reopen` 三处统一。

### 变更

- 医生队列在安卓侧补上日期守卫与"接诊队列"标题，与鸿蒙行为一致。
- `release/android/` 证据刷新：APK 1,186,278 B（SHA256 `0835107B…306F95E`）+ 新增医生工作台两张截图。

### 文档

- 新增 [docs/联调记录-2026-10-18.md](docs/联调记录-2026-10-18.md)：BUG-1…BUG-10 的位置/现象/根因/处置、验证门禁、复现命令、7 条工具坑。
- 新增 [docs/审查-同事提交-2026-10-18.md](docs/审查-同事提交-2026-10-18.md)：适配性核对表、A1/A2/A3 详解、观察项、遗留。
- [docs/整改方案-2026-10-17.md](docs/整改方案-2026-10-17.md) 增「§九 三端联调轮」。

### 已知遗留（已记账，未在本轮修）

- 服务端仍**没有就诊日期硬门槛**（只有客户端保证）；补它会牵动 `server/tests` 里大量固定日期夹具。
- 安卓 `SessionStore` 的 `check(commit())` 在落盘失败时抛 `IllegalStateException`，风格与"失败降级"不一致。
- 安卓没有契约层测试：A1/A2/A3 这类"字段名一错就整页崩"的问题只能靠人工点出来。
- 鸿蒙主题切换当前页不立即重绘（BUG-2）：插桩已证明配色取值正确，差的是组件重绘依赖，见联调记录 §四。

---
---

## [0.2.0-p1-rev] 2026-10-17 —— 评审整改批次（可运行证据 / AI 开箱即用 / 功能缺陷修正 / 文档一致）

> 依据 `docs/评审反馈-2026-10-17.md`（72/100）。逐条处置与验收口径见 [docs/整改方案-2026-10-17.md](docs/整改方案-2026-10-17.md)。
> 本批次**有业务行为变化**三处：服务端默认端口、AI 默认开启（`builtin:demo`）、三端首屏路由。接口契约无破坏性变更（仅新增 `by_source` 等加法字段）。

### 新增

- **`hvigorw.bat`（仓库根）**：自动探测 DevEco 安装位置并推出 `DEVECO_SDK_HOME` / `JAVA_HOME`，
  使用者不配环境变量即可在仓库根一条命令构建鸿蒙客户端（`assembleHap`）。
- **鸿蒙构建与运行证据入库** [`release/harmony/`](release/harmony/README.md)：`entry-default-unsigned.hap`
  （1,758,339 B，SHA256 `D6AB687F4759C7203979553632F1D2948724CCF4975B59E07B44E689BA8CFBD8`）、`pack.info`、
  剥掉 ANSI 的完整构建日志、**11 张模拟器实跑截图**（管理端登录/看板/AI 能力中心、患者端登录/首页/分诊/选号/挂号/就诊）
  —— 回应评审「鸿蒙零构建产物、零运行证据」。
- **安卓构建与运行证据入库** [`release/android/`](release/android/README.md)：`app-debug.apk`（956,718 B，
  SHA256 `52EA2F26…E374C77`）+ 4 张模拟器截图（登录 / 首页 / 分诊页 / 就诊页空态）+ 复现命令与四个**环境**坑
  —— 安卓端从"只有代码审查"变成"能编译、能装、能连真服务端登录"。
- **AI 开箱即用**：新增 `server/src/ai_builtin.cj` 与第四种密钥引用形式 **`builtin:demo`**
  （`ai.key_ref` 仍只存引用、库里永不出现裸密钥；`keyRefBuiltinName()` 用整串白名单比对）；
  默认值改为 `ai.enabled=1` + DeepSeek `deepseek-chat`，装完即可真调。
- **`server/export-ca-bundle.ps1`**：从 Windows 证书存储导出 PEM 供 `SSL_CERT_FILE` 使用
  —— 修掉「`curl` 正常但仓颉出站 `134 unknown CA`」的真因（stdx 走 OpenSSL、不读系统证书存储）。
  分发包只带脚本不带 PEM（PEM 可能含企业内网根证书）。
- **`tools/check-docs.ps1` + `.github/workflows/repo-hygiene.yml`**：文档相对链接、`.ps1` BOM、
  `.bat` 纯 ASCII、旧仓库路径残留四项门禁，每次 push/PR 自动跑（回应「无 CI」）。
  2026-10-18 增**第 5 项**：源码注释正文里的 `/*` 未同行闭合（Kotlin/仓颉块注释可嵌套，见下条缺陷）。
- **`docs/整改方案-2026-10-17.md`** 与 **`docs/答辩材料-2026-10-17.md`**：P0/P1/P2 全 27 条处置与验收口径；
  9 分钟讲稿 + 现场演示脚本 + 12 问 Q&A（回应「答辩材料为零」）。
- **客户端安全存储**：鸿蒙 `common-core/src/main/ets/storage/SecureStore.ets`（`AssetStoreKit`）、
  安卓 `android-patient/.../data/SecretStore.kt`（`AndroidKeyStore` AES-256-GCM）—— 令牌不再明文落盘。

### 变更

- **服务端默认端口 8080 → 8091**（`server/src/main.cj:707`），与鸿蒙客户端 `ApiConfig.ets:8` 及
  安卓 `DEFAULT_BASE_URL` 对齐；文档与 `tools/package-release.ps1` 生成的 `start-dev.cmd` 同步。
  改动净增 0 行，故全仓对 `main.cj` 的行号引用全部保持有效。
- **分发包补许可文件**（`tools/package-release.ps1` 5b 步）：`LICENSE.txt`、`NOTICE.txt`、
  `THIRD-PARTY.md`、`licenses/{qingzhou,mariadb-driver}-LICENSE.txt` —— 回应「分发包零 LICENSE/NOTICE」。
- **`build-profile.json5`**：删除 `signingConfigs: []` 为空时仍引用 `signingConfig: "default"` 的悬空配置
  （此前会让构建停在签名阶段；现在产出 `entry-default-unsigned.hap` 并只给一条 WARN）。
- **分诊规则引擎**（`server/src/triage_redflag.cj`）：否定窗口 4 → 8 字符且不跨分句（`RED_FLAG_NEGATION_WINDOW`）；
  强度词拆成 `RED_FLAG_URGENT_MODIFIERS`（反复/持续/加剧/突发…）与 `RED_FLAG_CHRONIC_MODIFIERS`（一直/长期/严重/轻微…），
  要求与模糊词 ≤ `RED_FLAG_COOCCUR_WINDOW`(6) 字共现且修饰词自身未被否定；同义词扩充 22 组（胸口疼/气短憋气/痰中带血…）。
- **看板不再自证「AI 没被调用」**（`server/src/dashboard.cj`）：`triage.source` 由 `triage_stat.source` 分布推导
  （`model`/`rules`/`mixed`/`none`），新增 `by_source` 明细；管理台同步展示。
- **出站调用**（`server/src/ai_call.cj`）：429/5xx/网络异常重试 1 次（退避 200 ms）+ **全链路墙钟上限**
  （`stdx.net.http` 无 `connectTimeout`，用 `Future.get(timeout)` 等价覆盖）。
- **鸿蒙主题切换**（`ThemeManager` + `entry/.../Index.ets`）：改 `@ObservedV2` + `@Trace paletteVersion`，
  删除 `themeTick` 奇偶重建整树的做法，切主题不再丢滚动位置/输入内容。
- **安卓主题色单源**（`MainActivity.kt`）：17 处 `Color.rgb(...)` 改 `getColor(R.color.*)`，取值逐一核对、视觉零变化。

### 修复

- **三端首屏抢路由**（真缺陷，运行才暴露）：`registerPatientFeature/registerDoctorFeature/registerAdminFeature`
  原先各自 `AppRouter.replace(该端登录页)`，`EntryAbility.onCreate` 依次调用 ⇒ 最后调用的管理端决定首屏，
  患者主流程在界面上不可达。改为「注册不导航」，三个登录页互相给显式入口（患者页加「医生登录 · 管理端登录」）。
- **「同步身份信息」不同步姓名**：`CurrentUser` 缺 `displayName`，`/api/v1/auth/me` 的 `display_name` 被丢弃；
  已补模型字段 + Repository 解析 + `SessionStore.setDisplayName()`。
- **患者端公告页改走真实接口**：`PatientRepository.notices()` 由 Mock 改为 `GET /api/v1/notices`（保留 Mock 开关），
  公告失败不再拖垮首页；页面改三态 + 重试。
- **`accept` 对脏库敏感**：`server/src/acceptance.cj` 的排班夹具由裸 `INSERT` 改为
  `INSERT … ON DUPLICATE KEY UPDATE`（不用 `REPLACE INTO`，避免删行副作用）；故意弄脏库后重跑仍全绿。
- **模型种子「存量库迁移」判据**：`ai.enabled` 默认改 1 后，全新库被误判为存量库而只播 1 行；
  新增 `ai_settings.hasRow()`（直查库、绕过缓存）修正判据。
- `.gitignore` 由整目录忽略 `release/` 改为白名单 `/release/*` + `!/release/harmony/`，
  使构建证据可入库而体积会变的 zip 仍被忽略。
- `server/new-tls-cert.ps1`、`tools/package-release.ps1` 补 **UTF-8 BOM**（PS 5.1 下含中文脚本
  按 ANSI 解析会 `Unexpected token`）。
- `server/tests/doc-counts.ps1` 先校验退出码与 `[FAIL]` 再数 `[PASS]`：accept 因脏库失败时
  不再把「实测不成立」误报成「文档数字漂移」；并作为第 18 项接入 `server/tests/final-verify.ps1`。
- `server/tests/previsit-check.ps1` 的「删两行 ⇒ `enabled=false`」断言随 AI 默认值一起失效（删行＝回内置默认）：
  拆成「删行 ⇒ 回内置默认且 `enabled=true`」+「显式 `ai.enabled=0` ⇒ `enabled=false` 且理由非空」两段，
  收尾删行复原。这是 **给配置项加默认值的连带效应**：所有依赖"缺行 = 不可用"的用例都要过一遍。
- `server/build.ps1:119-120` 过期注释更正（驱动源码已在仓库内 `third_party/mariadb-driver`，
  47 个 `.cj`；`.cjo` 与静态库是构建期产物）。
- 四个模块根的 `BuildProfile.ets` 不再入库（hvigor 每次构建重写、只差缩进），实测删除后仍 `BUILD SUCCESSFUL`。

- **【复查轮】危急漏报**（本轮自己引入）：否定窗口 4 → 8 后仍用 `head.contains(nego)` 判否定，
  使 `无法缓解的胸痛`、`无明显诱因突发胸痛`、`没胃口而且胸痛` **不再报红牌**。改三段式判定
  （直连间隔按否定词字数分档 6/1 + 阻断词、缺席动词链、枚举链），顿号不再当分句边界；
  新增 11 例回归，`triagetest` 139 → **150**。
- **【复查轮】内置密钥被发给第三方端点**：`ai.key_ref=builtin:demo` 是全局 KV，而 `ai_model` 每行自带
  `base_url`，种子向量行指向百炼 ⇒ 会把 DeepSeek 密钥投递给阿里云。新增 `aiBuiltinKeyHostCheck()`，
  内置密钥只允许 `api.deepseek.com`，其余直接拒绝；`accept` 777 → **782**（+5 条断言）。
- **【复查轮】出站调用说实话**：`ai_call.cj` 原先一个 `catch` 把所有异常都报成"超过 Ns 全链路上限"，
  现拆 `TimeoutException` / 一般异常两类文案；重试前判剩余预算（不足即不重试并注明）；`aiProbeEmbedding`
  早退判据由 `httpStatus == 0` 改 `!r.ok`（401/404 真因不再被覆盖）。
- **【复查轮】看板 `source` 归类**：`model:invalid` 归入 `other` 会把"只有 model:invalid、无 rules"推成 `mixed`；
  改按 `model*` / `rules*` 前缀归族。
- **【复查轮】登录 401 误伤成登出**（鸿蒙）：服务端「账号或密码错误」也是 401，`HttpClient` 见到 401 就清会话
  ⇒ 医生/管理端输错密码被踢到**患者**登录页。改为仅对带鉴权的请求做会话失效处理；模拟器实测截图为证。
- **【复查轮】令牌有效期不回写**（鸿蒙）：服务端滑动续期的新 `expires_at` 从不写回客户端 ⇒ 过期即掉登录；
  新增 `SessionStore.updateExpiresAt()` / `hasValidToken()`，`AuthGuard` 与三个登录页统一使用。
- **【复查轮】首屏缺患者分支**：`Index.ets` 只判 doctor/admin，患者冷启动先闪一帧登录页；已补分支。
- **【复查轮】安全存储三处**（鸿蒙）：`remove` + `add` 的覆盖窗口（失败时 prefs 是新账号、asset 是旧令牌 =
  身份串号）改为 `CONFLICT_RESOLUTION = OVERWRITE`；`24000008`（库未建）按"无记录"处理；空 secret 的 `put`
  不再谎报 `true`。
- **【复查轮】安卓令牌三处**：旧明文迁移不看 `SecretStore.put()` 返回值就删明文（Keystore 不可用 = 静默登出）；
  `storeTokenSecurely` 忽略写失败；解密失败被 `orEmpty()` 吞掉。改为成功才删、失败记 `Log.w` 且按未登录处理
  （新增 `@Volatile tokenPersisted`）。**2026-10-18 已在 Temurin 21 下编译通过并装模拟器实测**。
- **【复查轮】`SecretStore.kt` 注释导致整文件不编译**（真编译错误）：头部文档写了 `shared_prefs/*.xml`，
  Kotlin 块注释可嵌套 ⇒ 多出一层永不闭合的注释，整文件 `Unclosed comment`，并连带 `SessionStore.kt`
  报 4 处 `Unresolved reference 'SecretStore'`。已改写该句；顺带扫全仓 `.kt/.ets/.cj` 的"注释里的 `/*`"，
  并把这一类缺陷变成门禁：`tools/check-docs.ps1` 第 5 项（剔除字符串字面量与 `//` 行注释后判定，探针文件实测能抓住）。
- **【复查轮】启动闸门无超时**：`whenReady()` 一旦挂起就是永久白屏；改 `Promise.race([whenReady(), 1200ms])`。
- **【复查轮】管理端登出不通知服务端**：补 `AdminRepository.logout()`（网络失败仍清本地）。
- **【复查轮】分发脚本两处**：`package-release.ps1` 生成包内说明的 here-string 用了 C 风格 `\$p`（PS 不认）
  且 `$p` 已被赋成 Process 对象 ⇒ 包内排查命令乱码；`final-verify.ps1:16` 硬编码 `E:\harmonyOS\smart_hospital\server`
  ⇒ 换机器/CI 找不到 exe（改 `Split-Path -Parent $PSScriptRoot`，并让健康等待失败时杀掉进程）。
- **【复查轮】门禁脚本两处**：`doc-counts.ps1` 的 triagetest 段不判退出码（连不上库会算出"实测 0"的假 DRIFT）；
  `check-docs.ps1` 遇非 UTF-8 文件抛 `DecoderFallbackException` 整脚本退出（改报文件名后跳过）。
- **【复查轮】小项**：`StatusChip` 主题色写进 `@Param` 默认值（省略参数的调用点永久停在首帧色）；三端跨端入口
  是裸 `Text`（热区 < 44vp）；`HomePage` 刷新不复位"下一次就诊"；`clearLogin()` 不清 `previsit_session_id`。

### 修复（2026-10-18 三端联调批次，详见 [docs/联调记录-2026-10-18.md](docs/联调记录-2026-10-18.md)）

- **挂号后号源余量不刷新**（患者端 `BookingPage.ets`）：成功路径只弹「挂号成功」，列表卡片仍显示旧余量
  （只有「号源已被抢」分支才重拉）。`loadSchedules()` 增 `keepMessage` 参数，成功路径补一次刷新。
- **登录响应 `patient_id` 不分角色**（服务端 `http_app.cj`）：医生登录返回 `patient_id = ref_id`，
  与 `/auth/me` 的 `patient_id: 0, doctor_id: 1` 自相矛盾；改为按角色给值。
- **未来日期的号可以到院/接诊**（医生端 `VisitQueuePage.ets`）：就诊日为两个月后的号仍能走完
  「到院登记 → 候诊 → 接诊」，还显示「候诊 0 分钟」；新增就诊日守卫与红条提示（服务端硬门槛列待办）。
- **接诊队列「今日」名不副实**（医生端）：分段值 `ALL` 却标成「今日」，而接口无日期参数 ⇒ 未来号混进"今日"；
  改标「全部」并在副标题写明含历史与未来。
- **看板「分诊命中率」恒为 0%**（管理端）：`AdminRepository` 直接写死 `triageHitPct = 0`，服务端无该字段
  （`triage_stat` 无 `patient_id`/`appointment_id`，命中率无法回溯）；指标改为「分诊调用」= 真实 `total_calls`。
- **看板趋势含未来日期且「7 日」与 `trend_days=14` 矛盾**（服务端 `dashboard.cj` + 管理端）：趋势 SQL 补上界，
  标题跟随 `trend_days`。
- **挂号列表忽略号源自带的科室/医生名**（患者端）：从「常用服务 → 预约挂号」进入时显示「科室 #1」「医生 #1」；
  改为优先用 `department_name` / `doctor_name` / `doctor_title`，路由参数降为兜底。
- **主题切换当前页不重绘**（鸿蒙 `ThemeManager.palette()`）：裸读 `paletteVersion` 被优化掉，改为让版本号参与取值；
  插桩证明配色取值已正确，但**页面仍要重进才变色**，故列为留档缺陷并写明真修法（`AppStorageV2` + `@Monitor`
  或 `AppColor` 改 `@ObservedV2` 实例属性）。

### 文档

- 数字统一为实测值并被门禁绑定：`accept` **782**、`triagetest` **150**、`selftest` 51、`authtest` 17、
  REST **81**、`final-verify` **18 项**、**107** 个提交（截至 tag `v0.2.0-p1-rev`）、**6** 位贡献者、**26** 个测试文件。
- 新增 **`docs/联调记录-2026-10-18.md`**：三端联调走查范围、BUG-1…BUG-10 现象/根因/处置、留档 4 条与建议修法、
  验证门禁、复现命令、以及 6 条会误导判断的工具坑（`uitest inputText` 是追加、输入法候选栏被误读、安装后首启竞态…）。
- 全仓旧仓库路径（原名含中文）与「本仓库路径含中文」的过时论述清理完毕；保留的是
  「部署到含中文目录时」的条件式说明与评审核查原文存档。
- `README.md` / `docs/DEPLOYMENT.md` / `docs/HARMONY-INTERFACE-GUIDE.md` 补鸿蒙一条命令构建、
  改名后 `oh_modules` 软链重连、4 类构建故障排查、模拟器安装未签名 HAP 与 `power-shell wakeup` 细节。
- `docs/Q6-合规决策记录.md` 登记「演示默认开启 + `builtin:demo`，生产必须轮换密钥或置 0」的口径变更。

---
## [0.2.0-p1] 2026-10-17 —— 复验修复批次（11 条修复 + 3 条新增 + 1 条清理；另撤回 2 条）

### 修复（客户端契约无破坏性变更，两处**加法**字段）

- **S1** 建单端点补 `client_token` 长度校验：>64 字符由 **500 → 400** `VALIDATION_FAILED`（与查询端点同文案）。
- **S2** 并发同幂等键不再 409：扣号 0 行时先按 `(patient_id, client_token)` 回读，六进程并发实测 **1×201 + 5×200**、同一 `appointment_id`。
- **S3** 病历已定稿时退号返回 **`409 APPOINTMENT_RECORD_LOCKED`**（此前会误取消并归还号源）；未锁病例如常 200。
- **S5** 重复排班（同医生/同日期/同时段）返回 **`409 SCHEDULE_EXISTS`**（业务层查重；DB 唯一键试过后回退，理由见报告）。
- **S6** `appointment.client_token` 改 `utf8mb4_bin`（大小写敏感），只差大小写的两个幂等键不再被并成一张单。
- **S8** 文档与实现不符：按实现更正「排班停诊后挂号返回 `404 SCHEDULE_NOT_FOUND`」。
- **S12** 分诊备选分支文案区分「本院未开诊该科」，不再一律说"该科当前无可挂号源"。
- **S14** 框架层平铺错误体统一为项目信封：非法 JSON 400 / 请求体过大 413 / 路由 404 / 方法 405 / 静态 404 / Range 416。框架新增 `Router.errorBody`、`StaticOptions.rangeNotSatisfiableBody`（**默认值不变**），应用注入统一信封。
- **S4** 数据库断链自愈：链路级错误识别 → 重建数据源 → 重做 session 变量；`/health` 新增 `db:{ok,reconnects[,reason]}`，库不通返回 **503**（此前一次闪断就要重启进程）。
- **S13** AI 配置可观测、可启用：设置接口新增 `key_ref_kind` / `key_resolvable` / `model` / `model_id`；启动日志打印"已启用/未启用 + 原因"，密钥引用解析不到时告警；管理台配置页新增告警条。
- **S16** 退号响应对已取消的单据返回 **`already_cancelled:true`**（加法字段），客户端可区分"我刚退的"与"早就是取消态"。
- **撤回** S9（limit/offset 本就夹取）、S10（与 `rate-limit-check` 的既有断言冲突，保留原语义）。

### 新增

- 契约：3 个错误样例重新导出、`schema-map` 改指 `envelope-error`、新增退号 `already_cancelled` 的 Schema 约束；`contract/CHANGELOG.md` 三条变更记录。
- 回归守卫：`p1-extra-check.ps1` 新增 `[3c]` 段（8 条断言）覆盖 S16，并修掉测试夹具不清理导致的二次运行失败。
- 文档：`docs/REVERIFY-AND-FIXES-2026-10-17.md`（复验报告 + 同日修复记录，12 节）。

### 清理

- 删除 1.4 GB 本机构筑产物（Gradle/图片/构建目录），删除 11 个过期评审文档与 5 个安卓端一次性修复记录；文档收敛为「项目说明 / 系统设计 / 接口口径 / 部署 / 第三方 / 阶段记录」。

---

## 2026-10-16 —— 医生端工作台与契约复核

- 医生端**病历工作台**：乐观锁保存、冲突核对（`EMR_CHANGED` 必带 `fields`）、锚点导航、修订历史只读。
- 医生端复核 4 条整改：患者姓名随出站下发、既往病历按就诊时间排序、冲突字段明细。
- `common-core`：就诊状态语义收敛为**单一来源**（谓词 + 文案不再各处手写）。
- 契约：拿掉 `patient_name` 的 `minLength: 1`、并发首建补端到端门禁。

## 2026-10-15 —— 门诊闭环 7 项改进 + 契约可执行

- **接口契约可执行**：导出机（67 样例）+ 24 个 Schema + 双门禁（逐字节 / 结构）。
- 改进 1/4：预问诊交接、候诊与叫号；改进 2：医生录入工作台（既往病历 + 保存冲突）；改进 3：**病历修订历史**（快照 + 解锁理由 + 逐段对比）；改进 6：就诊时间线与显式状态机（到院/候诊 + 三时间戳 + 队列排序）；改进 7：AI 评测与排障闭环（遥测 + 2 个排障端点）。
- 鸿蒙客户端在 DevEco 模拟器上**实测通过**（构建/安装/联调）；三端收口到公共主题与字号 token；新增客户端设计规范。
- 管理台窄屏（手机）布局修复 + 模拟器实测。

## 2026-10-14 —— 服务端复查 30 项 + 管理台 + 安卓端

- 按复查报告修复 **30 项缺陷**（A/B/C/D 全关闭）；权限动作拆分 + 管理端列表分页。
- 服务端托管**后台管理台** `/admin/`（零第三方依赖）与 AI 模型配置。
- **安卓患者端**（Kotlin Views）落地，并修复三批复审问题（状态语义、错误处理、恢复与隔离）。

## 2026-10-13 —— 安卓端 + 医生/管理端 + 退号状态机

- `feat(android)`：Kotlin 患者端 + 挂号/鉴权不变式。
- `feat(frontend)`：医生端与管理端，接入七段式病历、基础数据与 AI 能力中心。
- 修复：**退号强制走就诊状态机**，非 `booked` 状态一律 409。

## 2026-10-12 —— 患者端联调缺口

- 补齐患者端联调缺口的**八项接口与字段**（含公告域与验收用例）。

## 2026-10-11 —— 鸿蒙患者端 + 文档整理

- `feat: add HarmonyOS patient client`（`entry` + `common-core` + `feature-patient`）。
- 文档中性化整理（去除外部来源引用）；源码清单数字按实测修正。

## 2026-10-10 —— P5 收尾与数据层修复

- P5：看板知识库规模（含 `scan_limit_reached` 触顶告警）。
- 修复：**参数化绑定静默改坏写入值**（值里含 `?` 会被写成字面量 NULL）——数据层最严重的一次缺陷。
- 修复：两处"声称存在但没接线"的 AI 机制。

## 2026-10-09 —— P5 知识库（零向量库 RAG）

- RAG 核心：切块（按字符、带重叠、结构性不丢内容）+ MySQL JSON 存向量 + **纯仓颉余弦**；无 embedding 时关键词降级。
- 知识库接口层（管理端 CRUD + 检索 + 权限）；RAG 片段接入分诊（过安全层、有界、改不了 `options`）。
- 基础数据域 CRUD + **真模型接入**（分诊增强层 + 安全清理）。
- **拆除内存 Store**，全库统一为"直接 SQL + 事务"（ADR-0001 rev.7）。

## 2026-10-08 —— P4 电子病历 + 运营看板

- 七段式病历、接诊队列、运营看板（数据层 + 接口层 + 端到端验证）；范式迁移 ADR rev.6（病历移出内存 Store）。
- `create-db` 建出来的库必须"真能用"；`check-db` 不再以堆栈表达失败。

## 2026-10-07 —— P0/P1 立项与安全底子

- **P0**：号源/挂号独立 MySQL 路径（ADR-0001 + 服务端骨架 + 8 张表 + 原子扣减/幂等/退号 + 验收测试）。
- **P1**：挂号闭环 HTTP 层、多进程并发压测（20/30/40/50 抢同数号源全卖光）、令牌鉴权体系（PBKDF2 + 不透明令牌 + 防枚举）、HTTPS（TLS 1.2/1.3 + 带 SAN 自签 + fail-closed）、登录限流/失败锁定、会话按设备管理、口令强度校验。
- 关键修复：**推翻 P0 的乐观锁扣号策略**（改为带条件原子自减）、**并发退号永久丢号源**（与"少卖"同根因的镜像路径）、删除死代码 `booking_idem`（表集 9→8）。

---

## 版本号约定

| 形态 | 含义 |
| --- | --- |
| `0.2.0-p1` | 当前版本：P0–P5 全部交付 + 第 1 个维护批次 |
| `P0`–`P5` | 阶段标识，见 [README 进度表](README.md) 与 `docs/P*-HANDOFF.md` |
| `rev.N` | ADR-0001 的修订号（架构决策改动一次 +1） |
