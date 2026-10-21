# 鸿蒙端对接与开发说明（面向 B / C）

> 本文是鸿蒙客户端（`entry` + `common-core` + `feature-*`）的**开发者口径**，由 A 在完成基础架构与患者端后输出。
> 服务端 HTTP 契约**只以** [docs/FRONTEND-INTEGRATION.md](FRONTEND-INTEGRATION.md) 为准；本文只讲**鸿蒙侧怎么用**。

---

## 1. 工程结构与依赖方向

```
entry               壳工程：Ability、首页入口、装配注册
  └── feature-patient   患者端：页面 + 仓储 + 模型
        └── common-core 公共层：网络 / 路由 / 会话 / 配置
```

| 模块 | 类型 | 职责 | 谁负责 |
| --- | --- | --- | --- |
| `entry` | entry（HAP） | `EntryAbility`、`pages/Index`、`AppBootstrap.initialize`、`register*Feature` | A |
| `common-core` | HAR | `HttpClient`、`SseClient`、`ApiError`、`ApiConfig`、`SessionStore`、`AppRouter` | A / C |
| `feature-patient` | HAR | 患者端页面、`PatientRepository`、`MockPatientRepository`、模型 | A |
| `feature-doctor` | HAR | 医生端页面与仓储（依赖 `common-core`） | B |
| `feature-admin` | HAR | 管理端页面与仓储（依赖 `common-core`） | B |

**硬性约束**

1. 依赖**单向**：`entry → feature-* → common-core`。业务模块之间**禁止互相 import**（`feature-patient` 不得 import `feature-doctor`）。
2. 模块间通信只走 `common-core` 的**路由**与**网络层**，不共享页面组件。
3. 业务模块名在 `build-profile.json5` 里用合法标识符（如 `feature_patient`），包名用连字符（如 `feature-patient`），两者不要混。

**新增一个业务模块（以医生端为例）**

1. 仿 `feature-patient/` 建目录：`oh-package.json5`（`name: "feature-doctor"`，依赖 `common-core`）、`build-profile.json5`、`hvigorfile.ts`、`src/main/module.json5`（`type: "har"`）、`Index.ets`。
2. 在根 `build-profile.json5` 的 `modules` 里注册 `feature_doctor`。
3. 在 `entry` 的 `oh-package.json5` 加 `"feature-doctor": "file:../feature-doctor"`，并在 `EntryAbility.onCreate` 里调用你们自己的 `registerDoctorFeature()`。
4. 若与患者端同时打包，注意 `entry` 的 `OhPackage` 依赖不要形成回环。

---

## 2. 路由注册与页面跳转

路由是 `common-core` 里的单例注册表，**不依赖系统路由**，避免跨 HAR 传 builder。入口 `entry/pages/Index.ets` 订阅当前路由，`feature` 的根组件按 `route` 分发页面。

```ets
import { AppRouter, RouteName } from 'common-core';

// 注册观察者（只在 entry 根页面做一次）
AppRouter.getInstance().setObserver((name: string) => { this.route = name; });

// 页面跳转
AppRouter.getInstance().push(RouteName.PREVISIT);            // 入栈，可 back()
AppRouter.getInstance().push(RouteName.RECORD_DETAIL, params); // 带参数
AppRouter.getInstance().replace(RouteName.HOME);             // 不入栈
AppRouter.getInstance().reset(RouteName.LOGIN);              // 清栈（用于登录/登出/底部 tab）
AppRouter.getInstance().back();                              // 回上一页，空栈回首页
```

* 参数用 `Record<string, Object>`，通过 `getParam(key)` 读取；值统一是字符串/数字。
* **新增路由**：在 `common-core` 的 `RouteName` 加常量；不要在各 feature 里私自定义字符串。
* **底部 tab 与详情页的分界**：`PatientRoot` 里 `isTabRoute()` 决定是否显示 `BottomNav`；详情页自带 `PageHeader({ showBack: true })`。
* 现状：`entry` 已按登录角色分根（患者/医生/管理端各一），医生端与患者端页面没有装进同一个根。

---

## 3. HTTP 网络层（`HttpClient`）

统一入口，**不要在页面里直接用 `@kit.NetworkKit`**：

```ets
import { HttpClient, ApiError } from 'common-core';

const data = await HttpClient.getInstance().post('/api/v1/triage', body); // 返回信封里的 data
const list = await HttpClient.getInstance().get('/api/v1/appointments?limit=200');
const health = await HttpClient.getInstance().getRoot('/health');         // 根路径、免鉴权、无 data 信封
```

| 方法 | 说明 |
| --- | --- |
| `get(path, authenticated = true)` | 业务 GET |
| `post(path, body, authenticated = true)` | 业务 POST |
| `getRoot(path)` | 根级、免鉴权（如 `/health`） |
| `buildHeaders(authenticated)` | 需要时可复用（SSE 也用它取 token） |

> ★ **服务端接口在 2026-10-12 有增量**（患者端联调后补的，全部是加法，老字段一个没删）：
> `GET /api/v1/departments`、`GET /api/v1/doctors`（患者可读的科室/医生字典）、
> `GET /api/v1/notices`（首页「医疗公告」的真实数据源）、`GET /api/v1/health`（`/health` 的
> `/api/v1` 别名）；`/schedules`、`/appointments`、`/medical-records`、挂号与退号响应**新增**
> `department_name`/`doctor_name`/`doctor_title`（挂号/退号另有 `remain_num`），
> `/auth/me` **新增** `display_name`；分诊 `patient_note` 去掉了 Markdown `**`；
> 服务端「今天」口径改为 **Asia/Shanghai**。
> 逐字段说明见 [`FRONTEND-INTEGRATION.md`](FRONTEND-INTEGRATION.md) §5.19–5.25。

**它替你做的四件事**

1. 拼 base URL（`ApiConfig.url`）、注入 `Authorization: Bearer <token>`、`X-Device-Id`、`X-Device-Name`。
2. 按服务端**三段式信封**解析：先判 `ok` 字段是否存在 →
   - 有 `ok` 且为 `false` ⇒ 抛 `ApiError{code, message, fields}`（业务错误）；
   - 无 `ok` ⇒ 按框架错误形状解析（`code`/`message`/`path`）；
   - 有 `ok` 且为 `true` ⇒ 返回 `data`；`data` 缺失时返回空对象 `{}`。
3. 读 `Retry-After` 头，填进 `ApiError.retryAfter`（用于 429 倒计时）。
4. **统一 401 拦截**：`status === 401` 或 `AUTH_REQUIRED`/`AUTH_TOKEN_EXPIRED` ⇒ `SessionStore.clearLogin()` + 跳登录页。**页面不要各写一遍**。

**错误处理范式**

```ets
try {
  const result = await repo.triage(text);
} catch (error) {
  const apiError = ApiError.from(error as Error); // 把任意 Error 规整成 ApiError
  this.errorMessage = apiError.userMessage();     // 直接用统一文案
  // 需要精细分支时用 apiError.code / apiError.status
}
```

* `ApiError.from()`：非 `ApiError` 一律归成 `NETWORK_ERROR`。
* `userMessage()`：已内置常见码的中文文案（账号密码错、限流倒计时、号源被抢、会话过期、病历未提交、登录过期）。
* **不要**按 `status` 文案判断业务；**按 `code` 分支**，`message` 只作兜底展示。

---

## 4. 鉴权与登录态（`SessionStore`）

| 关注点 | 口径 |
| --- | --- |
| 角色 | `login` 返回的 `role` 是**唯一权威**；不要用 `patient_id` 猜角色 |
| 患者端准入 | `role === 'patient'` 才放行；否则提示「本 App 仅面向患者」并登出 |
| 令牌 | 不透明字符串，**不要解析**、不要写日志、不要放 URL query |
| 有效期 | 30 天 TTL + 服务端滑动续期；**没有 refresh 接口，不要实现 `/auth/refresh`** |
| 401 | 由 `HttpClient` 统一清登录态并跳登录 |
| 403 | `FORBIDDEN_ROLE`：拿非患者账号登了患者端 ⇒ 提示 + 登出 |
| 429 | `AUTH_RATE_LIMITED`：读 `retryAfter` 做倒计时 |

```ets
import { SessionStore } from 'common-core';

await SessionStore.saveLogin(token, expiresAt, userId, role, refId, patientId, displayName);
SessionStore.hasToken();  SessionStore.getRole();  SessionStore.getPatientId();
SessionStore.clearLogin();
```

`SessionStore` 由 `AppBootstrap.initialize(context)` 在 `EntryAbility.onCreate` 里初始化（基于 `@kit.ArkData` 的 Preferences）。**任何页面在 Ability 起来之前都不要读它**。

---

## 5. SSE 流式预问诊（`SseClient`）

只有预问诊是流式；**分诊是一次性 JSON，不要做打字机**。

```ets
import { SseClient, SseHandlers } from 'common-core';

const handlers: SseHandlers = {
  onMeta: (sessionId: string) => { /* 存 session_id */ },
  onDelta: (text: string) => { /* 追加文本 */ },
  onDone: () => { /* 收尾 */ }
};
await SseClient.getInstance().open('/api/v1/previsit/stream?chief_complaint=' + encodeURIComponent(text), handlers);
```

**四条硬性要求（已在 `SseClient` 实现，B 复用即可）**

1. **字节累积再解码**：以 `ArrayBuffer` 收字节，按 `\n\n` 切帧后再 `TextDecoder('utf-8')` 解码，**绝不按字符切**（中文会被截断）。
2. **严格 `\n\n` 分帧**：帧未结束的残字节留在缓冲区，跨 chunk 继续拼。
3. **必须收到 `done`**：`dataEnd` 时若没收到 `done`，按 `SSE_INCOMPLETE` 报错，**不要当作成功**。
4. **错误帧**：`event: "error"` 直接抛 `ApiError(code, message)`。

**多轮推进**：SSE 只负责开场；后续每一问用 `POST /api/v1/previsit/answer`（普通 JSON）。空答案是**不合法的**（不推进轮次），「无」是合法值。`form` 字段**只在 `complete === true` 时存在**。`session_id` 必须由客户端自己持久化（服务端**没有**「列出我的预问诊会话」接口）。

---

## 6. Mock / 在线 双模式

`ApiConfig` 控制 base URL 与模式；`ApiConfig.isMock()` 为真时仓储走 `MockPatientRepository`，否则走真实 `HttpClient`。

```ets
import { ApiConfig, ApiMode, SessionStore } from 'common-core';

ApiConfig.mode = ApiMode.MOCK;          // 或 ApiMode.LIVE
ApiConfig.baseUrl = 'http://127.0.0.1:8091';
SessionStore.setApiConfig(ApiConfig.mode, ApiConfig.baseUrl); // 持久化
```

* 模式与 base URL 持久化在 `SessionStore`，`AppBootstrap.initialize` 启动时 `ApiConfig.restore(...)` 还原。
* **Mock 只覆盖患者端数据**（登录、分诊、预问诊、排班、挂号、退号、档案、公告）。B 写医生端/管理端时，需要自己在 `feature-doctor`/`feature-admin` 里补 Mock 仓储。
* 页面切换模式入口见 `ProfilePage`（患者端）与 `LoginPage`。
* **release 必须 HTTPS**：base URL 由构建/product 维度写死，不要靠探测协议；明文 HTTP 只用于本机联调。

---

## 7. 挂号幂等与退号语义（患者端已实现，B/C 需知晓）

**挂号（`POST /api/v1/appointments`）**

* 请求体 `{ schedule_id, client_token }`；`client_token` 是**幂等键**。
* 一次「点击确认挂号」生成**一个** token，**重试复用同一个值**；同 token 重放返回同一张挂号单（HTTP 200），首次成功是 201。
* **换号源就要换新 token**（一次点击 = 一个意图）。
* `409 SLOT_GONE`：号源被抢完 ⇒ **刷新列表，不要自动重试**。
* **不要做离线补发队列**：幂等只覆盖「同一意图重试」，覆盖不了「网络恢复后重放旧意图」，会造脏单。

**退号（`POST /api/v1/appointments/:id/cancel`）**

* HTTP **200 不代表退号成功**，**必须判 `data.status === 'cancelled'`**。
* 若 `data.slot_restored === false`，展示 `data.warning`（「号源归还异常，请联系人工处理」），**不要让用户反复点退号**。
* **没有 `can_cancel` 字段**：只能按 `status === 'booked'` 粗略决定是否显示退号按钮，并对 403/404 兜底。
* 重复退同一单仍是 200（幂等）；退号会把 `client_token` 置空。

---

## 8. 服务端缺口（写页面前必读，否则会白写）

| # | 缺口 | 影响 | 鸿蒙侧现状 |
| --- | --- | --- | --- |
| 1 | 无患者可读的**科室列表** | 无法独立做「选科室」 | 只能从**分诊 `options[].department_name`** 间接得到 |
| 2 | 无患者可读的**医生列表/详情** | 号源列表显示不出医生名 | `GET /schedules` 只回 `doctor_id`；医生名只能来自分诊 `options` |
| 3 | 排班**不联表**科室名/医生名 | 同上 | 号源列表只能显示「科室 #3 / 医生 #9」 |
| 4 | 无 `GET /appointments/:id` 单查 | 无法深链挂号单详情 | 从列表点入或本地缓存对象 |
| 5 | 无患者**自助注册** | 做不了注册页 | 账号由院内前台建 |
| 6 | 无患者**改密/找回密码** | 做不了安全设置 | 找管理员重置 |
| 7 | 无**令牌刷新**且不需要 | —— | 30 天 TTL + 滑动续期，**不要实现 refresh** |
| 8 | 无**真分页** | 长列表不能「加载更多」 | 只有 `limit`（超限静默夹住）；用 `count == limit` 猜「可能还有」 |
| 9 | 排班**不做未来过滤** | 「今日可约」混入历史 | **客户端自己按 `work_date` 过滤**，且与服务端 **UTC** 的「今天」对齐（见下） |
| 10 | 无按名搜索科室/医生 | 做不了搜索框 | 只能按 `department_id` 精确过滤 |
| 11 | 无**消息/推送**端点 | 做不了消息中心 | 只能本地通知 + 本地存的 `visit_date/period` |
| 12 | 无 `can_cancel` 判定字段 | 退号按钮无法精确置灰 | 见 §7 |
| 13 | 分诊结果无法跳详情 | —— | 分诊结果页**就地展示号源并允许挂号** |
| 14 | 无 **AI 流式分诊** | 分诊不能逐字输出 | 分诊用 loading 态即可 |

**「今天」的口径差异**：服务端用 **Asia/Shanghai** 的今天（`http_app.cj` 的 `hDateStringOf`，全服务端唯一时区口径），客户端拼 `work_date` 用**本地时区**，跨零点可能差一天。服务端**没有**接口返回「服务端的今天」，所以客户端做「今天之后」过滤时用**宽松过滤**（如保留 `>= 本地今天 - 1 天`），并以**分诊返回的 `work_date`** 为权威展示。「当天查不到」最终以分诊 `reason_code === 'NO_BOOKABLE'` 为准。

---

## 9. 代码约定（患者端已落地，建议 B/C 对齐）

* **状态管理统一 V2**：`@ComponentV2` + `@Local` / `@Param` / `@Event`，**不要 V1/V2 混用**。
* **组件参数命名避坑**：不要用 `enabled` / `background` 当 `@Param` 名（与 ArkUI 内置属性冲突）。现有组件用 `isEnabled`、`chipBackground`。
* **列表刷新**：ArkTS V2 对数组做整体**重新赋值**触发刷新（`this.list = next`），不要原地 `push` 后指望刷新。
* **`Row` 没有 `minHeight`**：需要固定高度用 `.height(...)`。
* **日期工具**：`todayString()` / `nowToken()` / `formatEpoch()` / `periodText()` 等都在 `common-core/src/main/ets/ui/Theme.ets`；B 若需要，建议把公共部分上移到 `common-core`，避免各 feature 各写一份。
* **颜色/尺寸**：沿用医疗青绿主题（`#00A9A7`），字号/间距见 `Theme.ets` 的 `AppText` / `AppSize`。C 的主题规范落地后以规范为准。

---

## 10. 本地构建与校验

**一条命令（推荐）**——仓库根自带 `hvigorw.bat`，会自动探测本机 DevEco Studio 的 hvigor / SDK / JDK：

```powershell
cd E:\harmonyOS\smart_hospital
.\hvigorw.bat --mode module -p product=default -p module=entry@default assembleHap --no-daemon
```

* 成功标志：`BUILD SUCCESSFUL`（本机 65 tasks，首编约 23 s、增量约 4 s），产物在
  `entry/build/default/outputs/default/entry-default-unsigned.hap`（约 1.7 MB，未签名）。
* 当前只剩 ArkTS **警告**：`common-core/.../KeyValueStore.ets:19,27,35,41,48,55,62` 的
  "Function may throw exceptions"、`ThemeManager.ets:101` 的 `matchMediaSync` 已废弃、
  `feature-admin/.../KnowledgeBasePage.ets:62` 的 `@Component` 成员名不能叫 `create`。均不影响构建。

### 10.1 本机（2026-10-17）实测可用的配方

仓库已改名为 `E:\harmonyOS\smart_hospital`（**纯 ASCII，可直接在仓库内构建**）。
旧问题「`00306003 Specification Limit Violation / Invalid project path`」只会在把仓库克隆到含中文的目录时复现，
那时才需要 robocopy 一份 ASCII 副本再构建（`subst` 映射盘符绕不过，hvigor 会 realpath 回真实路径）。

不想用仓库根的包装脚本时，等价的手工配方（本机路径为 `D:\DevEco Studio`）：

```powershell
$env:DEVECO_SDK_HOME = 'D:\DevEco Studio\sdk'
$env:JAVA_HOME       = 'D:\DevEco Studio\jbr'   # 必须：PATH 上的 java 若是 1.7，PackageHap 会 UnsupportedClassVersionError(52.0)
$env:Path = "D:\DevEco Studio\jbr\bin;D:\DevEco Studio\tools\node;D:\DevEco Studio\tools\ohpm\bin;D:\DevEco Studio\tools\hvigor\bin;$env:Path"
cd E:\harmonyOS\smart_hospital
& 'D:\DevEco Studio\tools\hvigor\bin\hvigorw.bat' --mode module -p product=default -p module=entry@default assembleHap --no-daemon
```

* `hvigorw.bat` 的探测顺序：`%HVIGOR_HOME%` → `D:\DevEco Studio\tools\hvigor\bin` →
  `C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin` → `%LOCALAPPDATA%\Huawei\DevEcoStudio\...`；
  找不到时打印明确提示并退 1（可改为直接用 DevEco Studio 的 `Build > Build Hap(s)`）。
* **为什么不用官方 `hvigorw`**：仓库的 `hvigor/hvigor-wrapper.js` 是 **0 字节**（与 DevEco「New Project」
  模板的占位文件一致），官方 wrapper 首次运行要联网装 pnpm + `@ohos/hvigor` 到 `%USERPROFILE%\.hvigor`；
  离线环境会失败。本仓库改为复用本机 DevEco 自带的 hvigor 6.26.4，不下载任何东西。
* ⚠ **仓库目录改名后要重连一次 `oh_modules` 软链**（绝对路径的 junction 会悬空，症状是
  `10505001 ArkTS Compiler Error: Cannot find module 'common-core'`）：`ohpm install`，或手工
  `mklink /J` 重连 7 个链接。详见 [docs/DEPLOYMENT.md(../DEPLOYMENT.md) §4。
* `signingConfigs` 为空时，`build-profile.json5` 的 `products[0]` 已**不再引用** `signingConfig`，
  只报 `WARN: No signingConfig found for product default`，产物是**未签名 HAP**——要装机得先用
  DevEco 自动签名或本机调试证书签名。
* 若需要把 hvigor 的缓存/工具链装到别处（C 盘清理、CI 隔离），设 `HVIGOR_USER_HOME=<绝对路径>` 即可；
  该目录默认是 `%USERPROFILE%\.hvigor`。
* 2026-10-17 的构建证据已入库：[release/harmony/(../../release/harmony/)
  （HAP + `pack.info` + 完整日志）。
* 模拟器安装、UI 自动化、与真实服务端联调的完整命令与实测结论见
  [docs/FRONTEND-INTEGRATION.md](FRONTEND-INTEGRATION.md) §5.33。
* 服务端联调（本机库、建库、起服务）见 [docs/FRONTEND-INTEGRATION.md](FRONTEND-INTEGRATION.md) §2。
