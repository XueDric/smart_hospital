# 客户端（ArkTS）· 构建方式与现状

> 📁 **客户端构建与现状** ｜ 本文件：`client-build.md` ｜ [全部文档目录](README.md)

> **技术栈已定：ArkTS。** 2026-09-14 组内决定客户端用 ArkTS（不再是仓颉）。
> 本文记录三件事：**本机怎么构建（已实测通过）**、**本次迁移改了什么**、**还没做完的部分**。
>
> ⚠️ **本文档正文停在 2026-09-14，客户端此后改了很多 —— 读 §3「还没做完」之前务必先看这一句。**
> **2026-10-04 复核的现状**：`entry/src/main/ets/pages/` 有 **21 个页面文件**，`main_pages.json`
> 登记 **11 条路由**；已有完整的 `api/`（`AuthApi` / `MemberApi` / `TaskApi` / `PlanApi` /
> `DeptApi` / `HttpClient`）、`store/`（7 个状态仓）、`util`+`utils`、`components/`、`core/`、
> `config/`；页面**已在调真实接口**（`Index.ets` 启动即调 `/auth/me`），全 `ets/` 已搜不到「假数据」。
> 所以下面 §3.3 / §3.4 / §3.5 里"只有 3 个页面""没有任何网络层""有界面没逻辑"等说法**都已过时** ——
> 它们按原文保留为 **2026-09-14 的历史记录**；**当前真实待办见 §3.8 与 README「已知缺陷与未修项」**。

| 项 | 值 |
| --- | --- |
| DevEco Studio | **6.1.1.300**（build `DS-243.24978.46.36.611300`），装在 `D:\DevEco Studio` |
| 自带 SDK | `D:\DevEco Studio\sdk` —— **API 24 / 6.1.1.125**（与项目 `compatibleSdkVersion: 6.1.1(24)` 匹配） |
| hvigor | 6.24.4 · node 18.20.1 · ohpm 6.1.2.285 · JBR **21.0.8** |
| 构建结果 | **BUILD SUCCESSFUL**，产物 `entry/build/default/outputs/default/entry-default-unsigned.hap`（316,534 字节） |

---

## 1. 本机构建（实测通过）

```powershell
cd E:\harmonyOS\cangjie_web
$ds = "D:\DevEco Studio"
$env:DEVECO_SDK_HOME = "$ds\sdk"
$env:JAVA_HOME       = "$ds\jbr"                                    # ← 见坑 ①
$env:PATH            = "$ds\jbr\bin;$ds\tools\node;$ds\tools\ohpm\bin;$env:PATH"
& "$ds\tools\hvigor\bin\hvigorw.bat" assembleHap --no-daemon
```

产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`

内部已确认包含编译后的字节码 `ets/modules.abc`（165 KB），
`ets/sourceMaps.map` 登记了**当时（2026-09-14）**的 6 个源文件：`EntryAbility.ets` + 5 个页面 —— 说明页面确实参与了编译。
> **2026-10-04 现状**：`pages/` 下 **21 个页面文件**、`main_pages.json` 登记 **11 条路由**，另有 `api/`、`store/`、`util/`+`utils/`、`components/`、`core/`、`config/`，全部参与编译。

### 两个必踩的环境坑

#### ① 必须用 DevEco 自带的 JBR，不能用系统 PATH 上的 java

本机 PATH 上的 `java` 是 **JDK 1.7.0_80**（`C:\Windows\system32\java.exe`，
另有 `C:\Program Files\Java\jre7`），而 hvigor 的打包工具是 **Java 8 字节码**：

```
java.lang.UnsupportedClassVersionError: ohos/CompressEntrance : Unsupported major.minor version 52.0
（major.minor 52.0 = Java 8；JDK 7 装不下）
```

**症状**：`CompileArkTS` 会**成功**，只在最后的 `PackageHap` 挂掉 —— 看起来像"打包工具坏了"，
其实是 Java 版本问题。修法：`JAVA_HOME=D:\DevEco Studio\jbr` + `jbr\bin` 放 PATH 最前（JBR 是 21.0.8）。

#### ② `DEVECO_SDK_HOME` 要指向 DevEco 自带的 SDK

用户目录 `%LOCALAPPDATA%\Huawei\Sdk` 下只有 `licenses` / `system-image`，**没有实际 SDK 组件**；
真正可用的是 DevEco 自带的 `D:\DevEco Studio\sdk`（API 24）。不设这个变量 hvigor 找不到 SDK。

---

## 2. 本次迁移做了什么（2026-09-14）

### 迁移前的状态：**根本构建不了**

```
> hvigor ERROR: 00303038 Configuration Error
  Schema validate failed, at file: entry\build-profile.json5
  propertyName: 'cangjieOptions'
  allowedValues: [ 'resOptions','externalNativeOptions','sourceOption','napiLibFilterOption',
                   'arkOptions','nativeLib','removePermissions','generateSharedTgz' ]
```

即：**stock hvigor 不认识 `cangjieOptions`**，连配置校验都过不去。也就是说旧客户端在本机从未构建成功过。

### 改动清单

| # | 改动 | 说明 |
| --- | --- | --- |
| 1 | 页面移入模块 | `client-arkts/pages/*.ets` → **`entry/src/main/ets/pages/`**（`git mv`，历史保留） |
| 2 | **新增** `entry/src/main/ets/entryability/EntryAbility.ets` | ArkTS 的 `UIAbility`，`onWindowStageCreate` 里 `windowStage.loadContent('pages/Index')` |
| 3 | `entry/src/main/resources/base/profile/main_pages.json` | `{}` → `{"src": ["pages/Index"]}`（**之前是空对象，页面无法被路由**） |
| 4 | `entry/src/main/module.json5` | 加 `"pages": "$profile:main_pages"`；删掉模块级 `srcEntry`（原仓颉 AbilityStage）；ability 的 `srcEntry` 改为 `./ets/entryability/EntryAbility.ets` |
| 5 | `entry/build-profile.json5` | 删掉 `cangjieOptions` 与 `nativeLib`（前者被 hvigor 拒绝） |
| 6 | **退役仓颉客户端** | 删除 `entry/src/main/cangjie/`、`entry/cjpm.toml`、`entry/cjpm.lock`、`entry/src/test/`、`entry/src/ohosTest/`（都是仓颉脚手架） |
| 7 | 删除 `client-arkts/` 目录 | 页面已移入模块；旧 README 的判断（"不能直接使用"）已被本次迁移取代，内容并入本文 |
| 8 | **应用身份**（`AppScope/app.json5`） | `bundleName` `com.example.cangjie_web` → **`com.club.manager`**；`vendor` `example` → `club` |
| 9 | **应用名/文案** | `app_name` `cangjie_web` → `社团管理工具`；`module_desc` / `EntryAbility_desc` / `EntryAbility_label` 三处占位文案（`module description` / `description` / `label`）→ 中文 |
| 10 | **包描述** | 根 `oh-package.json5` 与 `entry/oh-package.json5` 的 `"Please describe the basic information."` → 项目说明 |
| 11 | **代码检查范围**（`code-linter.json5`） | `files` 去掉 `**/*.cj`（客户端已无仓颉代码） |
| 12 | **`.gitignore`** | 删掉 4 条仓颉客户端专用规则（`**/cj_res`、`**/*.cj.macrocall`、`**/ability_mainability_entry.cj`、`**/module_**_entry.cj`），补 ArkTS 的 `**/.preview` |
| 13 | **`build-profile.json5`（app 级）** | 删掉悬空的 `"signingConfig": "default"`（`signingConfigs` 是空数组，属于悬空引用） |

> 第 6 项是**删除**操作，但删掉的是 DevEco 初始模板（`README.md` 早就写明"仍是模板、未接任何接口"），
> 且全部在 git 历史里，需要时可 `git checkout <commit> -- entry/src/main/cangjie` 取回。

> ⚠️ **`bundleName` 是应用身份**：改了它，设备上会被当作**另一个 App**（不会覆盖旧的）。
> 现在（未发布、未上架）是改名的唯一无痛时机。若你们有自己的域名，把 `com.club.manager`
> 换成自己的反向域名即可 —— 只需改 `AppScope/app.json5` 一处，然后重新构建。

---

## 3. 还没做完（TODO）

### 3.1 签名 —— 装到手机前的最后一步

构建日志：

```
WARN: No signingConfig found for product default
```

产物是 `entry-default-**unsigned**.hap`，**不能安装到设备**。
`build-profile.json5` 的 `app.signingConfigs` 是空数组 `[]`（原先 product 里还留着一个悬空的
`"signingConfig": "default"`，已清掉，现在的告警更直白）。

**怎么补**：在 DevEco 里 `File > Project Structure > Signing Configs` 勾选 **Automatically generate signature**（需登录华为账号），
它会写入调试签名；之后 `assembleHap` 产出即为已签名 HAP。

### 3.2 没连设备，所以只验证到"编译 + 打包"

```
hdc list targets  →  [Empty]      （当前无设备/模拟器在线）
可用模拟器镜像：HarmonyOS-6.1.1、HarmonyOS-7.0.0
```

**已证实的**：ArkTS 代码编译通过、HAP 打包成功、当时 6 个源文件都进了字节码
（**2026-10-04 现状**：21 个页面文件、11 条登记路由，全部参与编译）。
**未证实的**：真机/模拟器上的实际运行效果。

### 3.3 页面缺口（2026-09-14 记录，2026-10-04 已补齐）

`docs/frontend-brief.md` §2 要求 **11 个页面**，当时只有 **3 个**（成员名录 / 待分配审批 / 管理）。

当时的缺口清单：登录、注册、**我的任务（首页）**、任务列表、任务详情、课题列表、课题详情、加入流程、我的设置。

> **2026-10-04 现状更新：本节描述的缺口已补齐。** 当前 `pages/` 共 **21 个页面文件**、
> `main_pages.json` 登记 **11 条路由**：`ServerConfigPage`（2026-09-29 新增，联调时配置服务端地址）/
> `Index`（首页五 Tab：我的任务 / 任务 / 课题 / 名录 / 我的）/ `LoginPage` / `RegisterPage`（含招募深链预填）/
> `PendingPage`（等待管理员分配）/ `TaskDetailPage` / `PlanDetailPage` / `CreateTaskPage` / `CreatePlanPage` /
> `ApprovePage` / `AdminPage`。
> 首页方向**已对齐 brief**：`Index.ets` 的第一个 Tab 就是「**我的任务**」，不是组织架构图；
> 「加入流程」= `RegisterPage` 的招募链接预填 + `PendingPage`。
> 另：`SplashPage` / `PendingWaitPage` 两个文件仍在，但**未登记路由、无任何引用**（死代码，见 `client-bug-handover.md` C-7）。

### 3.4 与接口契约的差异（2026-09-14 记录）

> **2026-10-04 现状更新**：本表是 **2026-09-14 的差距清单**，下列 8 项**均已由真实接口层解决** ——
> 客户端现有 `api/`（`AuthApi` / `MemberApi` / `TaskApi` / `PlanApi` / `DeptApi` / `HttpClient`），
> `Index.ets` 启动即调 `AuthApi.me()`；全 `ets/` 已搜不到「假数据」。本表**保留为历史记录**，不再对应当前代码。

原有页面**没有任何网络层**（当时全目录 grep `http|fetch|api/v1|Authorization|token` → 0 命中），
当时 4 个文件里都有 `// ====== 假数据 ======`。接真接口时要处理：
| # | 现状 | 服务端口径 | 后果 |
| --- | --- | --- | --- |
| 1 | 部门 id 用 **0..3** | 服务端 `next_dept` 从 **1** 开始；`dept_id = 0` = **未分配** | 会把「主席团」当未分配 |
| 2 | 字段 camelCase：`deptId`/`deptName`/`joinedAt`/`dueAt` | snake_case，且 `dept` 是对象 `{id,name}` | 需一层 DTO 映射 |
| 3 | 角色下拉含 **`president`** | `assign`/`assign-batch`/`PATCH /members` **一律拒绝** `role=president` | 必 `400` |
| 4 | 成员详情显示**手机号** | `MemberBrief` **不含手机号**（只有 `GET /auth/me` 的本人视图有） | 拿不到数据 |
| 5 | 「管理」入口无条件显示 | 应按 `permissions` 隐藏/置灰（服务端还会再挡一次） | 双保险缺一半 |
| 6 | 没有「等待管理员分配」页 | `pending` 账号**必须**跳该页，不进主界面 | pending 用户直进主界面 |
| 7 | `selectedDeptId` 同时当「下标」和「部门 id」用 | id ≠ 下标 | 会选错部门 |
| 8 | 日期用 `'2026-09-01'` | ISO 8601 带时区 | 需转换 |

### 3.5 有界面没逻辑的地方（2026-09-14 记录，均已修复）

> **2026-10-04 现状更新**：本节描述的「只写不读」`@State`（`showResetPassword` / `showDisableConfirm` /
> `showRotateConfirm` / `showAddDialog` / `showTransferConfirm` / `showResetPasswordConfirm`）在当前代码里
> **已全部不存在**；「编辑 / 删除 / 复制 / 更换口令 / 生成链接 / 搜索」均已接上 `onClick`（见 `ManagePage.ets` 等）。
> 本节保留为 2026-09-14 记录。

以下 `@State` **只写不读**（赋值了但 `build()` 里从未判断），按钮点下去不会弹东西：

`showResetPassword`、`showDisableConfirm`（成员详情）· `showRotateConfirm`、`showAddDialog`、
`showTransferConfirm`、`showResetPasswordConfirm`（管理页）

另有：「编辑」「删除」是纯 `Text` 无 `onClick`；「复制」「更换口令」无 `onClick`；
「+ 生成链接」`onAction` 是空函数；「🔍 搜索成员」是 `Text` 不是输入框；
成员详情的 `memberId` 只被赋值、未用于取数（点谁都显示同一个人）。

### 3.6 命名与占位（已在本次适配中处理）

- `AppScope/app.json5` 的 `bundleName` 已从 `com.example.cangjie_web` 改为 **`com.club.manager`**（见 §2 第 8 项）；
- `app_name` 已改为 **社团管理工具**；
- `entry/.../string.json` 的三处占位文案已改为中文；
- 两个 `oh-package.json5` 的占位描述已替换。

> 若你们有自己的域名，把 `com.club.manager` 换成自己的反向域名即可（改 `AppScope/app.json5` 一处）。

### 3.7 IDE 缓存里仍有仓颉痕迹（仅本机，不入库）

`.idea/` 是 DevEco 的本地缓存（`.gitignore` 已忽略），里面还有上一次仓颉方案留下的东西：

```
.idea/.deveco/cangjie/dependency.json        ← 仍指向已删除的 entry/src/test/cangjie
.idea/.deveco/cangjie/cj-plugin-cache/*      ← 仓颉插件的 build-profile schema 缓存
.idea/workspace.xml                          ← 仍有 SyncCangjieResource 运行配置
```

**处理**：在 DevEco 里对该项目做一次 **Sync**（或关闭项目后删除 `.idea/.deveco/cangjie`）即可。
它们不影响命令行构建（`hvigorw` 不看 `.idea`），只影响 IDE 里的提示。

---

## 3.8 当前真实待办与已知缺陷（2026-10-04 复核）

> §3.1 / §3.2 **仍然成立**（**签名未配**、**没连设备**，只验证到"编译 + 打包"）。
> §3.3 / §3.4 / §3.5 是 2026-09-14 的历史记录，**不要再当 TODO 读**。
> 下面是 2026-10-04 对当前代码复核出来的、**仍然存在**的客户端缺陷 —— 它们不是"缺功能"，是会出错。

| # | 级别 | 缺陷 | 落点 |
| --- | --- | --- | --- |
| C-7 | P2 | `SplashPage` / `PendingWaitPage` 是**死代码**：未登记路由、无任何引用（`SplashPage` 还跳向未登记的 `pages/PendingWaitPage`）；且 `HttpClient` 从不 throw，它那个 `ApiRequestError` 分支永远不会命中 | `pages/SplashPage.ets:163`、`pages/PendingWaitPage.ets`、`main_pages.json` |
| C-9 | P1 | **任务列表永远只有第 1 页**：写死 `{ page: 1, size: 50 }`，界面却硬编码「第 1 / 1 页」；「未完成」是在这 50 条上做**本地**过滤 → 第 50 条以后的任务不可达，"未完成"还可能显示为空 | `pages/TaskListPage.ets:56,81-86,194`（正确对照：`MemberListPage.ets:99-129` 的"循环拉全"） |
| C-10 | P1 | **会长移交 / 重置密码候选只取前 50 人**：`memberApi.list()` 不带分页，服务端默认 `size=50` → 活跃成员超过 50 时**无法移交给第 51 名以后的人** | `pages/ManagePage.ets:1181` |
| C-11 | P1 | **日历对账会把事件描述清空**：`reconcile` 在 `due_at` 变化时用 `''` 覆盖 `description`；根因是数据源 `POST /tasks/lookup` 只返回 `id/due_at/status/updated_at`（无 `title`/`desc`），客户端却把它当 `TaskBrief` 用 | `util/CalendarSync.ets:335`、`server/src/h_task.cj:804-808` |
| C-12 | P2 | `HttpClient` 的 GET 并发去重**只按 `path` 记忆**，且 `SessionStore.clearAll()` 不清它 → 重登 / 换服务器地址后可能复用上一位用户的响应 | `api/HttpClient.ets:90,280-293`、`store/SessionStore.ets:12-17` |

**已核对为正确 / 已修**（供接手确认，不要重复修）：C-1 阻塞原因显示 · C-2 截断时间与逾期 ·
C-3 重置密码走 `can()` · C-4 刷新入口 · C-5 收起文案 · C-6 防重复提交 · C-8 深链放行 http。
逐条证据见 `docs/client-bug-handover.md`（该文第三节已按本表更新）。
