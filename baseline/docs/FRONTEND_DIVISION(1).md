# 🏓 社团管家 APP · 前端四人分工清单

> 📁 **前端分工** ｜ 本文件：`FRONTEND_DIVISION(1).md` ｜ [全部文档目录](README.md)

> **前提**：四人依靠 AI 辅助开发，后端用 HTTP 本地联调，证书问题暂缓。其中 A/B/C 三人 ArkTS 零基础；新同学 **D 原为 UI 设计**，分到「展示型」页面。
> **客户端技术栈**：鸿蒙 App —— **ArkTS 语言 + ArkUI 声明式 UI**，源文件后缀 **`.ets`**，统一放在 `entry/src/main/ets/` 下。
> **后端技术栈**：仓颉语言（**仓颉只用于服务端，客户端不用**；两边通过 HTTP/JSON 通信，语言不需要一致）。
> **易混概念**：ArkUI 是 UI 框架，写 ArkUI 页面用的语言是 **ArkTS**。**不要建任何 `.cj` 文件**，客户端代码全部是 `.ets`。
> **后端仓库**：https://github.com/XueDric/open-harmony-club-service

---

## 📦 【今天全体必须完成的 3 件事】

1. **装 DevEco Studio**（华为官网下载），安装时保持默认勾选的 **HarmonyOS SDK（ArkTS/ArkUI）** 即可，**客户端不需要选装仓颉 SDK**（仓颉只用于服务端）
2. **克隆后端仓库**：
   ```
   git clone https://github.com/XueDric/open-harmony-club-service.git
   ```
3. **用 DevEco Studio 打开仓库根目录**（含 `build-profile.json5` 的目录，**不是 `entry/` 子目录**），跑通自带的 Hello World 示例

**后端起服务的命令**（让后端同学执行，前端不用管）：
```powershell
cd server
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
cd build
.\club-server.exe init-admin 13800000000 你的密码123 dev-data
.\club-server.exe serve 8080 dev-data
# 然后后端同学会把内网 IP 发你们，比如 http://192.168.1.100:8080
```

---

## 👥 四人分工总览

| | **A 同学** | **B 同学** | **C 同学** | **D 同学（UI 设计）** |
|--|-----------|-----------|-----------|----------------------|
| **代号** | 基建 + 认证 | 分配 + 管理 | 任务 + 课题 | 成员名录 + 成员详情 |
| **管页面** | 登录 / 注册 / 等待分配 / 我的 | 待分配审批 / 管理 | 我的任务（首页） / 任务详情 / 课题树 / 课题详情 | 成员名录 / 成员详情 |
| **管接口** | 认证 5 个 + 基建层（全 39 个接口封装） | 分配 3 + 管理 11（共 14） | 任务 8 个 + 课题 6 个 | 成员 5 个 |
| **核心产出** | HTTP 客户端 + Token 管理 + 权限判断 | 批量分配、会长移交、同权保护 403 | 课题树形递归渲染、日历同步 | 名录分组、详情排版、权限隐藏按钮 |
| **阻塞谁** | **阻塞 B/C/D** | 不阻塞别人 | 不阻塞别人 | 不阻塞别人 |
| **被谁阻塞** | 无 | A 的 HTTP 客户端 | A 的 HTTP 客户端 | A 的 HTTP 客户端 |

---

## 🟢 A 同学详细任务（基建 + 认证）

### 负责的 4 个页面

| 页面 | 核心功能 |
|------|----------|
| 登录页 | 手机号 + 密码登录、注册入口、忘记密码引导联系会长 |
| 注册页 | 注册口令 + 手机号/姓名/密码 → 注册成功变 pending |
| 等待分配页 | pending 账号登录后只看到这个，提示"等待管理员分配" |
| 我的 / 设置页 | 本人信息展示、改密码、退出登录 |

### 负责的接口（7 个）

| 接口 | 用途 |
|------|------|
| `POST /auth/login` | 登录拿 token |
| `POST /auth/register` | 注册产 pending 账号 |
| `POST /auth/logout` | 注销 |
| `GET /auth/me` | **启动必调**：校验 token + 拿 permissions |
| `PUT /auth/password` | 本人改密 |
| （基建层）所有 39 个接口 | 封装 HTTP 客户端、统一拦截 401 跳登录 |

### 你要写的文件（按顺序来）

```
entry/src/main/ets/
├── api/HttpClient.ets          ← 第 1 个写！封装所有 HTTP 请求（用 @kit.NetworkKit 的 http 模块）
├── api/AuthApi.ets             ← 认证相关接口
├── api/TaskApi.ets             ← 给 C 用
├── api/DeptApi.ets             ← 给 B 用
├── api/MemberApi.ets           ← 给 B 用
├── api/PlanApi.ets             ← 给 C 用
├── store/TokenStore.ets        ← Token 存哪里（用 @kit.ArkData 的 Preferences 持久化）
├── store/PermissionStore.ets   ← /auth/me 返回的权限
├── pages/SplashPage.ets        ← 启动页（检查登录状态）
├── pages/LoginPage.ets
├── pages/RegisterPage.ets
├── pages/PendingWaitPage.ets
└── pages/ProfilePage.ets
```
> 注意：页面写完后必须在 `entry/src/main/resources/base/profile/main_pages.json` 里登记路径，否则跳转黑屏。

### HTTP 客户端必须做到的事

1. baseUrl 写死 `http://后端内网IP:8080`（等后端公网部署 + 证书搞定后改一行切 HTTPS）
2. 所有请求自动加 `Authorization: Bearer <token>`
3. 收到 **401 无条件跳登录页**（token 失效）
4. 收到 **403 提示"无权限"**
5. 收到 `VALIDATION_FAILED` 逐字段提示
6. 用 try-catch 处理网络异常，不要崩溃

### 第一周每天做什么

| 天 | 任务 | 具体动作 |
|----|------|----------|
| **Day 1** | 跑通 Hello World + 搭基建骨架 | 把 HttpClient.ets 写出来，先用 mock 数据返回 |
| **Day 2** | 接通真实后端 | 让后端起服务，调通 `GET /auth/me` |
| **Day 3** | 登录 + 注册页面 | 调通 `POST /auth/login` 和 `POST /auth/register` |
| **Day 4** | 启动页 + 路由守卫 | App 启动 → 自动跳登录/首页/等待分配 |
| **Day 5** | "我的"页面 + 改密码 | 调通 `PUT /auth/password` |

### AI 提问模板（直接复制用）

> "这是后端接口定义：`GET /auth/me` 返回 `{ ok: true, data: { view_scope, manage_members, set_role, create_plan, create_task, update_any_task } }`。用 **ArkTS**（HarmonyOS NEXT，文件后缀 .ets）写一个 HttpClient.ets，用 @kit.NetworkKit 的 http 模块发请求，要求：1. baseUrl 写死 http://后端IP:8080 2. 所有请求自动加 Authorization: Bearer token 3. 收到 401 返回一个特殊错误码 4. 用 try-catch 处理网络异常 5. 不要用 any 类型，接口响应要先声明 interface"

### 必须记住的坑

| 坑 | 说明 |
|----|------|
| **pending 账号处理** | 注册成功后 token 已返回，但 permissions 全 false、view_scope = none，必须跳等待页而不是主界面 |
| **启动流程** | App 启动 → 读 token → GET /auth/me → 成功且非 pending → 进首页；pending → 等待页；401 → 登录页 |
| **错误码映射** | AUTH_BAD_CREDENTIALS → "手机号或密码错误"；REGISTER_CODE_INVALID → "注册口令错误" |

---

## 🟡 B 同学详细任务（分配 + 管理）

### 负责的 2 个页面

| 页面 | 核心功能 |
|------|----------|
| 待分配审批 | 待分配列表、**多选批量分配**部门+角色 |
| 管理页（最复杂） | 部门增删改、注册口令查看/更换/轮换、招募链接生成/停用、重置密码、**会长移交** |

### 负责的接口（14 个）

| 分类 | 接口 |
|------|------|
| 部门写 | `POST /depts` · `PATCH /depts/{id}` · `DELETE /depts/{id}` |
| 分配 | `GET /members/pending` · `POST /members/{id}/assign` · `POST /members/assign-batch` |
| 管理 | `POST /members/{id}/transfer-presidency` · `POST /members/{id}/reset-password` |
| 注册 | `GET /register-config` · `PUT /register-config/code` · `POST /register-config/rotate` |
| 招募 | `GET /dept-invite-links` · `POST /dept-invite-links` · `DELETE /dept-invite-links/{token}` |

### 你要写的文件

```
entry/src/main/ets/
├── pages/PendingApprovalPage.ets  ← 待分配审批（含批量分配）
├── pages/ManagePage.ets           ← 管理页（最复杂！）
└── components/
    ├── AssignDialog.ets           ← 分配弹窗（单个/批量）
    ├── DeptEditDialog.ets         ← 部门改名
    ├── RegisterConfigCard.ets     ← 注册口令
    ├── InviteLinkList.ets         ← 招募链接
    ├── PasswordResetDialog.ets    ← 重置密码
    └── TransferPresidentDialog.ets ← 会长移交（最严肃的弹窗）
```
> B 负责的 2 个页面**静态壳已完成**（主题 token 在 `core/Theme.ets`），颜色/圆角/间距一律用 Theme 里的 token，不要在页面里写死颜色值。下一步把页内 mock/TODO 换成真实接口调用。

### 第一周每天做什么（前 2 天不依赖 A）

| 天 | 任务 | 具体动作 |
|----|------|----------|
| **Day 1** | 学 ArkUI 列表 + 弹窗 | 写假的待分配列表 + 批量分配弹窗壳子 |
| **Day 2** | 写管理页壳子 | 部门/口令/招募链接/会长移交各区块搭好，用假数据 |
| **Day 3** | 等 A 的 HTTP 客户端 → 接真接口 | 先接通待分配 `GET /members/pending` |
| **Day 4** | 批量分配 | 调通 `POST /members/assign-batch`，处理「部分失败逐条展示」 |
| **Day 5** | 管理页 + 会长移交 | 调通注册口令、招募链接、会长移交、重置密码 |

### 你必须记住的坑（后端设计，不是 bug）

| 坑 | 现象 | 你该怎么做 |
|----|------|----------|
| **同权保护** | 副会长改另一个副会长 → 403 FORBIDDEN_ROLE | UI 上对同权者**直接隐藏按钮**，别等报错 |
| **最后一个会长** | 想移交最后一个会长 → 403/409 FORBIDDEN_LAST_PRESIDENT | UI 上判断一下，没别的会长就禁用 |
| **批量分配部分失败** | 5 条里 2 条因同权保护失败 | UI 要展示"3 成功 2 失败"，别一口气全成或全败 |
| **部门非空不能删** | 删有成员的部门 → DEPT_NOT_EMPTY | UI 上先检查有没有人 |
| **自己不能重置自己密码** | 重置自己密码 → 403 | UI 上对自己隐藏重置按钮 |
| **权限驱动 UI 隐藏** | 副会长看不到部门增删改、更换注册口令、会长移交 | 读 /auth/me 返回的 permissions 来决定显示 |

### AI 提问模板

> "后端 `POST /members/assign-batch` 接口，请求体是 `{dept_id, role, member_ids: number[]}`，返回 `{ok: true, data: {succeeded: number[], failed: [{id, code}]}}`。用 **ArkTS + ArkUI**（.ets 文件）写一个批量分配弹窗，左边是待分配成员列表（Checkbox 多选），右边是部门和角色 Select 下拉，提交后逐条展示结果。注意：ArkTS 不允许对象字面量当类型，请求/响应结构必须先写 interface 声明。"

---

## 🟣 D 同学详细任务（成员名录 + 成员详情）

> **背景**：新加入，原 UI 设计。分到「展示型」页面 —— 读多写少，正好发挥 UI 功底（卡片、分组、详情排版、权限隐藏按钮）。

### 负责的 2 个页面

| 页面 | 核心功能 |
|------|----------|
| 成员名录 | 按 4 个组织（主席团/课题部/运营部/宣传部）分组展示，点人看详情 |
| 成员详情 | 查看某人负责的任务、编辑姓名（权限受限）、移出社团 |

### 负责的接口（5 个）

| 分类 | 接口 |
|------|------|
| 名录 | `GET /members` · `GET /depts` |
| 详情 | `GET /members/{id}` · `PATCH /members/{id}` · `POST /members/{id}/disable` |

### 你要写的文件

```
entry/src/main/ets/
├── pages/MemberListPage.ets       ← 成员名录
├── pages/MemberDetailPage.ets     ← 成员详情
└── components/
    └── MemberCard.ets             ← 复用：成员卡片
```
> 这两个页面的**静态壳已完成**（假数据已在页内，见 `MemberListPage.ets` / `MemberDetailPage.ets`）。下一步把页内硬编码的假数据换成 `MemberApi` / `DeptApi` 的真实调用；主题 token 用 `core/Theme.ets`。API 层 A 已备好：`MemberApi.list()/detail()/update()/disable()`、`DeptApi.list()`。

### 第一周每天做什么（前 2 天不依赖 A）

| 天 | 任务 | 具体动作 |
|----|------|----------|
| **Day 1** | 摸熟现有静态壳 | 读懂 `MemberListPage.ets` 的假数据结构和 `MemberCard` 该放哪 |
| **Day 2** | 名录接真接口 | 用 `MemberApi.list()` + `DeptApi.list()` 替换假数据 |
| **Day 3** | 详情接真接口 | `MemberApi.detail(id)` 加载详情 + 统计 |
| **Day 4** | 编辑姓名 | 调通 `MemberApi.update(id, {name})`（注意权限受限） |
| **Day 5** | 移出社团 | 调通 `MemberApi.disable(id)` + 「最后会长」禁用判断 |

### 你必须记住的坑（后端设计，不是 bug）

| 坑 | 现象 | 你该怎么做 |
|----|------|----------|
| **编辑姓名权限受限** | 普通成员不能改别人名字 → 403 FORBIDDEN_ROLE | 读 /auth/me 的 permissions，没权限就隐藏编辑按钮 |
| **最后一个会长不能移出** | 移出最后一个会长 → FORBIDDEN_LAST_PRESIDENT | UI 判断「是否唯一会长」，是就禁用移出按钮 |
| **名下有未完成任务** | 移出有未完成任务的人 → MEMBER_HAS_OPEN_TASKS | 详情里展示 open_tasks 数，>0 时提示先交接任务 |
| **状态语义** | active / pending / disabled 三种 | 名录默认只显示 active，别把 pending 混进来 |

### AI 提问模板

> "后端 `GET /members` 返回 `{ok:true, data:{items:[{id,name,role,dept_id,status,...}]}}`，`GET /depts` 返回部门列表。用 **ArkTS + ArkUI**（.ets 文件）写一个成员名录页，按 4 个部门分组（List + Section）展示成员，点卡片跳详情。注意：ArkTS 不允许对象字面量当类型，成员结构先声明 interface。"

---

## 🔵 C 同学详细任务（任务 + 课题）

### 负责的页面

| 页面 | 核心功能 |
|------|----------|
| **我的任务（首页）** | 按截止时间分组（逾期/今天/本周/以后/无截止），**服务端已分好组**，逾期红色高亮，阻塞项单独一组 |
| 任务列表 + 新建 + 详情 | 按部门/人/状态/课题筛选；新建任务；详情页改状态（4 档）、**blocked 必须填原因** |
| 课题列表 + 详情 | **树形可展开折叠**；显示 `已完成 n / 共 m`（递归整棵子树）；详情页面包屑 + 子课题 + 本级任务 |
| 日历同步（独立专项） | 见下方单独说明 |

### 负责的接口（14 个）

| 分类 | 接口 |
|------|------|
| 任务 | `GET /tasks/mine`（首页服务端已分组）· `GET /tasks`（列表筛选分页）· `GET /tasks/{id}` · `POST /tasks`（新建传 client_token）· `PATCH /tasks/{id}`（编辑/转交改 owner_id）· `PUT /tasks/{id}/status`（改状态 + 填 blocker）· `DELETE /tasks/{id}`（软删除）· `POST /tasks/lookup`（日历同步专用） |
| 课题 | `GET /plans`（整棵树，含递归进度）· `GET /plans/{id}`（详情+面包屑）· `POST /plans`（新建课题/子课题，传 client_token）· `PATCH /plans/{id}` · `POST /plans/{id}/move`（移动换父节点）· `DELETE /plans/{id}`（子节点上提一级） |

### 你要写的文件

```
entry/src/main/ets/
├── pages/MyTasksPage.ets         ← 首页！"我的任务"
├── pages/TaskListPage.ets        ← 任务列表（筛选）
├── pages/TaskDetailPage.ets      ← 任务详情（改状态）
├── pages/CreateTaskPage.ets      ← 新建任务
├── pages/PlanTreePage.ets        ← 课题树（树形展开）
├── pages/PlanDetailPage.ets      ← 课题详情
├── pages/CreatePlanPage.ets      ← 新建课题
└── util/
    └── CalendarSync.ets          ← 日历同步（独立模块）
```
> 新建页面同样要在 `main_pages.json` 登记。底部导航由现有 `pages/Index.ets` 统一管理（Tabs），C 的"我的任务"要作为第 4 个 Tab 接入，不要自己另建导航。

### 第一周每天做什么（前 2 天不依赖 A）

| 天 | 任务 | 具体动作 |
|----|------|----------|
| **Day 1** | 学 ArkUI 列表分组 | 写假的"我的任务"，按 逾期/今天/本周/以后/无截止 分组 |
| **Day 2** | 写静态页面壳子 | 首页 + 任务详情 + 课题树 全搭好，用假数据 |
| **Day 3** | 等 A 的 HTTP 客户端 → 接真接口 | 先接通首页 `GET /tasks/mine` |
| **Day 4** | 任务详情 + 新建 + 改状态 | 调通 8 个任务接口 |
| **Day 5** | 课题树 + 课题详情 | 调通 6 个课题接口，写树形递归渲染 |

### 你必须记住的坑

| 坑 | 现象 | 你该怎么做 |
|----|------|----------|
| **首页分组信服务端** | 不要自己算逾期！`GET /tasks/mine` 已经分好组了 | 直接渲染服务端返回的 `{ overdue, today, ... }` |
| **blocked 必须填 blocker** | 改状态到 blocked 不填原因 → BLOCKER_REQUIRED | UI 上切 blocked 时**强制弹输入框**，填完才提交 |
| **课题删除 = 子节点上提** | 删课题不会级联删子课题 | UI 上提示"其子课题将提升到上一级" |
| **进度是递归值** | `PlanBrief.progress: {done, total}` 含整棵子树 | 直接用，别自己递归算 |
| **任务状态只有 4 档** | todo / doing / blocked / done | 不做进度百分比！ |
| **client_token 幂等** | 创建任务/课题时传 UUID，24h 内重复提交返回首次结果 | 防止用户手抖点两次新建出两个 |

### 日历同步（Day 7-8 做，别提前碰）

**这是客户端独有的活，后端不管。**

本地维护一张映射表：
```
task_id → { event_id, cached_due_at, cached_status }
```

| 情况 | 动作 |
|------|------|
| 任务截止时间变了 | **更新**日历事件（不要新建） |
| 任务变成 done | **删除**日历事件 |
| 任务被删了 | **删除**日历事件 |
| 日历权限被拒 | 降级：导出 `.ics` 文件让用户手动导入 |

调 `POST /tasks/lookup` 批量确认"我加过日历的任务还在不在"，返回的 `missing` 就是要清理的。

> **⚠️ 这项绝对不能省**——后端原话："不做更新与删除，日历里会堆积错误的过期提醒，两周后成员就不再相信它。"

### AI 提问模板

> "用 **ArkTS + ArkUI**（.ets 文件）写一个树形可展开的列表组件，展示课题数据。每个课题有 title、progress {done, total}、children（递归嵌套）。点击左侧箭头展开/折叠，显示已完成 n/共 m 的进度。递归数据结构请用显式 interface 声明（如 `children: PlanNode[]`），不要用 any。"

---

## 🔄 设计稿对齐 · 进度与剩余分工（2026-09-18）

> 背景：把设计规格《鸿蒙俱乐部-全场景UI设计规格.pdf》（13 屏）逐屏对照现有客户端，审计出缺口清单。下面记「已修复」与「剩余分工」。
> 分工原则：任务·课题域的缺口（原 C 的页面）主体交给 **E 同学**；管理域的缺口落在 B 自己的页面归 **B**，另从任务域里分两个小块（#2 needs_help 读取侧、#6 数量标签）给 **B** 平衡工作量。

### ✅ B 同学本轮已完成

| # | 事项 | 涉及文件 |
|---|------|----------|
| 1 | **Logo 落地**：登录页 logo + 桌面分层图标（前景/背景）+ 启动窗口图标 | `media/logo.png` · `AppScope/.../foreground+background.png` · `entry/.../foreground+background.png` · `startIcon.png` · `LoginPage.ets` |
| 2 | **权限入口 bug 修复**：待分配审批入口改按角色（会长/副会长）判定，部长不再误见入口被 403 | `PermissionStore.ets`（新增 `AssignPending`）· `ApprovePage.ets` · `ProfilePage.ets` |
| 3 | **逾期文案**：详情页「已逾期 N 天」；首页/成员详情「逾期 0 天」→「已逾期」 | `TaskDetailPage.ets` · `MyTasksPage.ets` · `MemberDetailPage.ets` |
| 4 | P02 任务列表「共 X 项 · 全社团范围可见」副行 | `TaskListPage.ets` |
| 5 | P12 注册页「链接已失效」提示 | `RegisterPage.ets` |
| 6 | 管理页「重置密码」死代码挂载 + 权限口修正（会长/副会长） | `ManagePage.ets` |
| 7 | **needs_help 读取侧**：首页卡片 + 任务卡片渲染「需要帮助 · 部门 姓名」行 | `MyTasksPage.ets` · `TaskCard.ets` |
| 8 | **needs_help 读取侧补 P03**：任务详情阻塞高亮块加「需要帮助 · 部门 姓名」行 | `TaskDetailPage.ets` |
| 9 | **P05 数量标签**：课题详情「子课题 · N」「本级任务 N」 | `PlanDetailPage.ets` |
| 10 | **会长移交二次确认**：移交会长前弹二次确认（不可撤销警告） | `ManagePage.ets` |

### ⏳ 剩余工作分工（B vs E）

| # | 事项 | 代码量 | 负责人 |
|---|------|--------|--------|
| 1 | **needs_help 写入侧**：任务详情选「求助部门/求助成员」+ `save()` 带 `help_dept_id`/`help_member_id` + 回显 | 中-大（~180 行） | **E** |
| 2 | 部长首页 `borrowed_blocked` 区分（本部门别人被阻塞的任务单独标记） | 中（~50 行） | **E** |
| 3 | P02 任务列表分页 / 加载更多（现在写死 page=1 size=50） | 中（~70 行） | **E** |
| 4 | P04 课题树「全部」部门筛选（**已实现 2026-10-04 复核**：`PlanTreePage.ets` 的 `deptFilter` / 「全部」胶囊）+ 子课题新建入口 | 中（~100 行） | **E**（仅剩子课题新建入口） |
| 5 | 日历同步 `.ics` 导出降级（独立专项，原 C 的 Day 7-8） | 大 | ~~E~~ **已实现（2026-10-04 复核：`util/CalendarSync.ets` 的 `buildTaskIcs()` 与导出分支）** |

> **2026-10-04 补记（复核当前代码）**：上表第 5 项（`.ics` 导出降级）**已在 `util/CalendarSync.ets` 实现**；
> 第 4 项的**部门筛选已实现**（`PlanTreePage.ets` 的 `deptFilter` 与「全部」胶囊），只剩"子课题新建入口"待确认；
> 第 1（`needs_help` 写入侧）、第 2（`borrowed_blocked`）两项经复核**仍未实现** —— 两者在代码里只有
> `api/TaskApi.ets` 的字段声明（写入侧缺失）。
> 另：第 3 项**不只是"缺功能"，而是已确认缺陷** —— `TaskListPage.ets:56` 写死 `{ page: 1, size: 50 }`、
> `:194` 页码文案写死 `第 1 / 1 页`，第 50 条以后的任务不可达；「未完成」还是在这 50 条上做本地过滤。
> 详见 `docs/client-build.md` §3.8 与 `README.md`「已知缺陷与未修项」。

> ⚠️ 涉及文件位置：`needs_help` 读写 → `TaskDetailPage.ets`；`borrowed_blocked` → `MyTasksPage.ets`；分页 → `TaskListPage.ets`；部门筛选 → `PlanTreePage.ets`；数量标签 → `PlanDetailPage.ets`；会长移交二次确认 → `ManagePage.ets`。

---

## 🤝 协作规范

| 事项 | 做法 |
|------|------|
| **Git 分支** | 主分支 `main`，A 提交基建代码；B 建 `feature/member-admin`；C 建 `feature/task`；D 建 `feature/member-view`；各自提交，A 负责合并到 main |
| **接口文档** | 所有人读后端仓库里的 `frontend-brief.md`，别自己猜接口长啥样 |
| **每天同步** | 5 分钟群里说：今天做了啥、卡在哪、需要谁帮忙 |
| **AI 提问模板** | 把后端接口定义贴进去，说"**用 ArkTS + ArkUI（.ets）** 写 XXX"，别让 AI 瞎猜接口，也别让它生成仓颉代码 |
| **假数据联调** | B/C 前 2 天用硬编码假数据，A 的基建出来后把 `mockGet()` 换成 `TaskApi.list()` 就行 |
| **统一 baseUrl** | 所有人用 `http://后端内网IP:8080`，别各写各的 |

---

## 🎯 一周目标

| 时间 | 全体 | A | B | C | D |
|------|------|---|---|---|---|
| **Day 1** | 跑通 Hello World | HttpClient 骨架 | 待分配假数据 | 首页假数据 | 摸熟名录静态壳 |
| **Day 2** | — | 接通后端 HTTP | 管理页壳子 | 首页+详情静态壳 | 名录接真接口 |
| **Day 3** | — | 登录/注册 | 接待分配接口 | 接真接口首页 | 详情接真接口 |
| **Day 4** | — | 启动页路由 | 批量分配 | 任务全接口 | 编辑姓名 |
| **Day 5** | **联调** | 我的/设置 | 管理页+会长移交 | 课题树 | 移出社团 |

**周五下午：全组联调，从注册账号 → 登录 → 分配 → 建任务 → 改状态 → 看课题进度，走一遍全流程。**

---

## 📚 四人各自的学习清单

| 内容 | A | B | C | D |
|------|---|---|---|---|
| ArkTS 语言基础（变量/类型/函数/类/async/Promise，禁 any） | ✅ | ✅ | ✅ | ✅ |
| ArkUI 声明式组件（Text/Button/Column/Row/Stack） | ✅ | ✅ | ✅ | ✅ |
| ArkUI 列表（List/ListItem/Section） | ✅ | ✅ | ✅ | ✅ |
| 表单 + 校验 | ✅ | ✅ | ✅ | ✅ |
| 弹窗 Dialog / AlertDialog | | ✅ | ✅ | ✅ |
| 树形递归渲染 | | | ✅ | |
| ArkUI Navigation / Tabs 导航 | ✅ | ✅ | ✅ | ✅ |
| @ohos.net.http 网络请求 | ✅ | | | |
| AppStorage / Preferences 持久化 | ✅ | | | |
| @ohos.calendar 日历 API | | | ✅ | |
| 鸿蒙运行时权限申请 | ✅ | | ✅ | |

---

## 🚨 快速求助

任何人遇到问题，把以下信息发群里（或问 AI）：
1. 报错截图/文字
2. 你写的代码（贴相关部分）
3. 你期望的结果是什么

**参考文档**：后端仓库根目录的 `frontend-brief.md`（接口对接精简版，必读）
