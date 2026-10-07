# 客户端 bug 交接单（2026-09-19 复核版）

> 📁 **客户端 bug 交接单** ｜ 本文件：`client-bug-handover.md` ｜ [全部文档目录](README.md)

> **给谁**：前端小组（ArkTS 客户端）。
> **复核基线**：`main` @ **`9631307`**（2026-09-19，含 `50e8dfe`「按 Figma 设计稿还原全部 13 屏外观」
> 与 `85cb659` / `42cb34f` / `9631307` 等客户端提交）。
> **背景**：2026-09-18 做过一次双端审查，服务端侧的缺陷已由服务端同学修完并推送；
> 客户端 6 条当时写成了交接单。**本轮上游更新后重新逐条复核**，结论见下表 ——
> 其中 **2 条已被 Figma 重构顺手修掉**，另 **4 条仍在**，并**新发现 1 条回归**。
>
> ⚠ **上一版的参考补丁 `docs/client-bug-handover.patch` 已删除**：它是对着 `b5c41b0`
> （Figma 重构之前）写的，现在 `TaskCard` / `ManagePage` / `MyTasksPage` 都被大幅重写，
> `git apply --check` 三个文件全部失败。需要回看当时的实现可 `git show d8e018f`。
> **本轮不再提供补丁**，请以本文的文字描述为准（每条都给了新行号与验收标准）。

---

## 一、复核结论一览

| # | 问题 | 上一轮严重度 | **本轮状态** | 位置（新行号） |
| --- | --- | --- | --- | --- |
| C-1 | 首页「阻塞中」卡片不显示阻塞原因 | 高（P0 回归） | ✅ **已由上游修掉** | `components/TaskCard.ets:67-68, 103-122` |
| C-2 | 首页截断时间裸拼 ISO、丢失逾期展示 | 中 | ✅ **已由上游修掉** | `components/TaskCard.ets:24-51, 63-65, 94-98` |
| C-3 | 管理页「重置成员密码」绕过唯一权限入口 | 中 | ❌ **仍在** | `pages/ManagePage.ets:116-118, 1213-1215, 1555` |
| C-4 | 首页无手动刷新入口 + 「下拉刷新」文案是假的 | 低 | ❌ **仍在** | `pages/MyTasksPage.ets:122`（及统计卡区 98-120） |
| C-5 | 课题树「收起全部」文案与实际状态相反 | 低 | ❌ **仍在** | `pages/PlanTreePage.ets:109` |
| C-6 | 重置密码 / 会长移交无防重复提交 | 低 | ❌ **仍在** | `pages/ManagePage.ets:1217, 1230, 1245` |
| C-7 | **`SplashPage` / `PendingWaitPage` 回归**（带 `@Entry` 但未登记路由、无任何引用） | 低 | ❌ **新发现** | `pages/SplashPage.ets:36`、`pages/PendingWaitPage.ets:40` |
| C-8 | **深链解析只认 `https://`**，联调期服务端发的是 `http://` → 点链接唤不起 App | 低（联调期影响明显） | ✅ **已解决（2026-09-22）** | `utils/InviteDeepLink.ets`、`module.json5`、`server/src/h_link.cj` |

> **C-8 已解决（2026-09-22）**：Debug 同时接受 `http` / `https`，Release 仍只接受
> `https`；浏览器落地页新增 `clubmanager://join/<token>`“打开 App 并继续注册”按钮。
> 详细改动与验收步骤见下面「二、已解决」的 C-8。
> C-1 / C-2 / C-8 保留在文档里**只为留档**，不需要你们再动手。

---

## 二、已解决（留档，无需再动）

### C-1 ✅ `TaskCard` 现在自己渲染阻塞原因

新实现不再需要外部传 prop：`TaskCard` 直接从 `task` 上取，并且渲染得比原方案完整。

| 证据 | 位置 |
| --- | --- |
| `showBlocker()`：`status === 'blocked' && task.blocker` 非空 | `components/TaskCard.ets:67-68` |
| 渲染阻塞原因高亮块（标题「阻塞原因（进入 blocked 必填）」+ 原因原文 + `StatusColor.blocked.bg` 底色） | `components/TaskCard.ets:103-122` |
| 调用点只传 `task` | `pages/MyTasksPage.ets:148`：`TaskCard({ task: t })` |
| 服务端一直下发该字段 | `server/src/views.cj:404-407` |

> 上一轮的诊断（「新增的 `@Prop blockerText` 没有调用点 → 死代码」）在当时是对的；
> 本轮重构把 prop 整个去掉、改成从 `task` 取，问题自然消失。

### C-2 ✅ 截断时间格式化 + 逾期展示已恢复

`TaskCard` 现在有完整的截止标签实现，口径与上一轮要求一致甚至更全：

| 情况 | 输出 | 颜色 |
| --- | --- | --- |
| `is_overdue` 且 `overdue_days > 0` | `逾期 N 天` | `StatusColor.overdue.fg` |
| `is_overdue` 且 `overdue_days` 为 0 / undefined | `已逾期` | 同上 |
| `due_at` 为空 | `无截止` | `Color.textTertiary` |
| `status === 'done'` | `M-D 已完成` | `StatusColor.done.fg` |
| 今天到期 | `今天 HH:MM` | 正常 |
| 其余 | `M-D 截止` | 正常 |

证据：`components/TaskCard.ets:24-51`（`DueLabel` 接口 + `shortDue()`，注释写明口径）、
`:63-65`（`due()`）、`:94-98`（渲染 `label` + `color`）、`:77`（标题在逾期时变红）。
`pages/MyTasksPage.ets` 不再自己拼 ISO 串（上一轮的 `dueLabel()` 已不存在）。

### C-8 ✅ 招募链接支持 Debug HTTP，并可从落地页唤起 App

链路现在分成两步，能同时兼容联调和发布：

1. 群里发送普通招募链接：Debug 是 `http://…/join/<token>`，Release 仍只接受 `https://…/join/<token>`。
2. 浏览器先打开服务端落地页；页面显示对应部门，并提供“打开 App 并继续注册”按钮。
3. 按钮使用自定义协议 `clubmanager://join/<token>`。App 接收后进入 `RegisterPage`，再用 token 调
   `GET /api/v1/join/<token>`，由服务端返回 `dept.name` 并显示部门预填。部门不会由客户端自行传参。

| 证据 | 位置 |
| --- | --- |
| Debug 接受 `http` / `https`，Release 只接受 `https` | `entry/src/main/ets/utils/InviteDeepLink.ets` 的 `extractInviteToken()` |
| 接收普通链接与 `clubmanager://join/<token>` | `entry/src/main/module.json5` 的 browsable `skills` |
| 冷启动保存 token，首页消费后进入注册页 | `EntryAbility.ets:15`、`Index.ets:30-33` |
| 落地页按钮与 token 对应部门 | `server/src/h_link.cj` 的 `handleJoinLanding()` / `joinPageHtml()` |
| 注册页显示服务端返回的部门 | `RegisterPage.ets:435-443`、`:308-320` |

**验收方法（模拟器）：**

1. 启动提供 `GET /api/v1/join/<token>` 的服务，并确认响应含 `data.dept.name`。
2. 用模拟器浏览器打开 `http://10.0.2.2:8080/join/<token>`，确认落地页显示部门并可点“打开 App 并继续注册”。
3. 点击按钮，App 进入注册页；确认出现“来自于招募链接的部门预填：…”。
4. 也可用 HDC 直接模拟浏览器唤起点：

```powershell
hdc shell aa force-stop com.club.manager
hdc shell aa start -A ohos.want.action.viewData -e entity.system.browsable -U "clubmanager://join/<token>"
```

说明：普通 `http(s)` 链接仍以浏览器落地页为准；自动直接打开 App 需要发布域名绑定的 App Linking，当前方案提供的是稳定的“落地页 → 点击按钮 → App”桥接。

---

## 三、复核结论修订（2026-10-04）

> 本节标题原为「**仍需修（4 条）**」。按 **2026-10-04** 对当前代码的逐条复核，
> **C-3 / C-4 / C-5 / C-6 均已修复**（C-1 / C-2 / C-8 在更早已修）。
> 因此下面各小节的正文（"两处硬伤都还在""`Refresh(` 命中数仍为 0""搜不到任何 `resetting`"等）
> **保留为 2026-09-19 的原始复核记录，不再对应当前代码**。

| # | 2026-09-19 结论 | **2026-10-04 复核** | 证据 |
| --- | --- | --- | --- |
| C-3 | ❌ 仍在 | ✅ **已修复** | `ManagePage.ets:1197` 走 `can(user,'ResetPassword',m)`；`:1227-1236` `resetCandidates()` 按 `can()` 过滤；`canResetMemberPassword()` 已删除 |
| C-4 | ❌ 仍在 | ✅ **已修复** | `MyTasksPage.ets:122` 文案已改「点击刷新」；`:135` 统计卡整块 `.onClick(...)` 刷新；全 `ets/` 已无「下拉刷新」 |
| C-5 | ❌ 仍在 | ✅ **已修复** | `PlanTreePage.ets:110` `@State expandAll: boolean = false`（原 `:109` 的 `true`） |
| C-6 | ❌ 仍在 | ✅ **已修复** | `ManagePage.ets:1172-1173` `transferring` / `resetting` 守卫 + 按钮 `.enabled(!…)`（`:1348` / `:1464` 文案「移交中…」「签发中…」） |
| **C-7** | ❌ 新发现 | ❌ **仍未修** | 两个文件未登记路由、全仓库无引用 → 见第四节 |

> ⚠️ **2026-10-04 新增的客户端缺陷不在本表**（本文件只跟踪 C-1…C-8）。
> 新发现的 C-9…C-12（任务列表只取第 1 页 / 管理页候选只取前 50 人 / 日历对账清空描述 /
> HttpClient 去重跨会话）见 `docs/client-build.md` §3.8。

### C-3【中】管理页「重置成员密码」**仍然绕过了唯一的权限入口**

| 项 | 内容 |
| --- | --- |
| 位置 | `pages/ManagePage.ets`：`canResetMemberPassword()` **:116-118**；`resetCandidates()` **:1213-1215**；卡片显隐 **:1555** |
| 现状（本轮复核） | **两处硬伤都还在**：<br>① `canResetMemberPassword()` 里是 `const role = PermissionStore.getInstance().userInfo?.role; return role === 'president' \|\| role === 'vice_president';` —— 硬编码角色，没走 `can()`；<br>② `resetCandidates()` 仍是 `this.members.filter((m: MemberOption) => m.id !== currentUserId())` —— **只排除自己**，不按目标档位/部门过滤。 |
| 后果 | **副会长打开下拉能选到会长**，选中提交后必然失败（toast「不能对同权限或更高权限的人执行此操作」+「重置失败」）——「看得见、点不动」。服务端 `server/src/perms.cj` 的 `checkAccess` 对 `ResetPassword` 有同权保护，这条 403 是**必然而非偶发**。 |
| 正确入口 | 唯一入口是 `PermissionStore.can(user, 'ResetPassword', target)`；`'ResetPassword'` 在 `PermissionAction` 里。参照 `pages/MemberDetailPage.ets` 的既有正确写法。 |
| 建议修法 | 删掉 `canResetMemberPassword()`；`resetCandidates()` 改成在 `MemberBrief[]` 上过滤 `can(user, 'ResetPassword', m)`（`can()` 需要 `MemberBrief` 才能做同权保护，所以别只存 `{id,name}` —— 当前 `MemberOption` 类型需要相应调整或与原始 `MemberBrief` 并存）；卡片显隐（:1555）也由 `can()` 派生。 |
| 验收标准 | 副会长账号 → 管理页 → 下拉里**看不到会长与其它副会长**；部长/副部长只看到本部门且权限低于自己的人；普通成员看不到该卡片。**必须用副会长账号实测**（会长账号看不出问题）。 |
| ⚠ 需与产品确认 | 改成基于 `can()` 后，**部长/副部长若 `manage_members = true` 也会看到这张卡**（候选人限本部门且权限低于自己）——这是服务端权限矩阵的语义，但与 `ManagePage` 里「部长/副部长走成员详情页，不在本页展示」的旧注释不一致。服务端同学的意见是**保持 `can()` 语义**、不额外加门控；若产品要收回，请在 `canResetMembers()` 上再叠一层角色门控。 |

### C-4【低】首页**仍无任何手动刷新入口**，且「下拉刷新」文案仍是假的

| 项 | 内容 |
| --- | --- |
| 位置 | `pages/MyTasksPage.ets:122`（`Text('下拉刷新')`）；统计卡区 `:98-120` |
| 现状（本轮复核） | 全客户端 `Refresh(` **命中数仍为 0**（本轮重新 grep 确认），而页面上仍写着「下拉刷新」；`:185` 那个 `onClick` 是**错误态的「重试」按钮**，不是刷新入口。 |
| 后果 | 用户按提示下拉没有任何反应；首页唯一更新途径仍是切 Tab / 从子页返回。 |
| 建议修法 | 二选一：**(a)** 给一个真实可点的刷新入口（统计卡整块 `Row` 加 `.onClick(() => { if (!this.loading) this.load() })`），并把文案改成与实现一致（如「尚未同步 / 点击刷新」）；**(b)** 真做下拉刷新（`Refresh({ refreshing: ... })` 包住滚动容器）再接 `this.load()`。**无论选哪个，文案必须与实现一致。** |
| 验收标准 | 按界面提示操作**确实能刷新**；不存在「提示了下拉但不能下拉」。 |

### C-5【低】课题树「收起全部」文案**仍与实际状态相反**（要点两次）

| 项 | 内容 |
| --- | --- |
| 位置 | `pages/PlanTreePage.ets:109`（`@State expandAll: boolean = true`）；按钮文案在同文件渲染处；默认折叠逻辑在 `PlanTreeNode.aboutToAppear` |
| 现状（本轮复核） | `@State expandAll: boolean = true` 未变，而深层节点仍默认折叠 → 首屏按钮显示「收起全部」但实际是部分展开；想「展开全部」的用户点一下反而全部收起，**必须点两次**。 |
| 建议修法 | 把初值改成与实际默认折叠状态一致（`false`），或让按钮文案由实际折叠状态派生。**别动** `toggleExpandAll()` / `@Watch('onExpandAll')` / 递归传参的切换逻辑（它们是对的）。 |
| 验收标准 | 进入课题页时按钮文案与当前折叠状态一致；点一次即达到文案承诺的效果。 |

### C-6【低】管理页「重置密码 / 会长移交」**仍无防重复提交**

| 项 | 内容 |
| --- | --- |
| 位置 | `pages/ManagePage.ets`：`submitTransfer()` **:1217**、`doTransfer()` **:1230**、`submitReset()` **:1245** |
| 现状（本轮复核） | 三个函数都在，但文件里**搜不到任何** `resetting` / `transferring` / `submitting` 之类的 in-flight 守卫，也没有相应的按钮禁用。 |
| 后果 | 请求返回前按钮可点，快速双击会发两次请求。`POST /members/{id}/reset-password` 会**作废目标全部令牌并签发新临时密码** —— 连点两次会签发两枚，界面只展示后返回的那枚；若用户已把第一枚转发出去，那枚已失效且**没有任何提示**。 |
| 建议修法 | 照 `CreateTaskPage` / `CreatePlanPage` / `MemberDetailPage` 已有的 `submitting` 写法：各加一个 `@State`，入口 `if (this.xxx) return`，进入置 `true`，`try/finally` 复位，请求期间 `.enabled(false)`（文案可切「签发中…」「移交中…」）。 |
| 验收标准 | 弹窗里快速双击「生成临时密码」只发一次请求、只签发一枚；请求期间按钮为禁用态。 |

---

## 四、新发现（1 条）

### C-7【低】**`SplashPage` / `PendingWaitPage` 回归：文件在、带 `@Entry`、但既未登记路由也无任何引用**

| 项 | 内容 |
| --- | --- |
| 位置 | `entry/src/main/ets/pages/SplashPage.ets:36`、`entry/src/main/ets/pages/PendingWaitPage.ets:40`（两处均为 `@Component`，**不带 `@Entry`** —— 2026-10-04 复核更正：原文写的是 `@Entry`）；路由表 `entry/src/main/resources/base/profile/main_pages.json` |
| 现状 | 这两个页面在 2026-09-18 曾被删除（提交 `7a9278d`「删除两个不可达的孤儿页面」，理由是它们**不在 `main_pages.json` 里、也没有任何引用**）；本轮更新（`85cb659` 那批）把它们**又加回来了**（各 +196 / +218 行）。**2026-10-04 复核**：`main_pages.json` 现在是 **11 个路由**（`ServerConfigPage`（2026-09-29 新增）/ `Index` / `LoginPage` / `RegisterPage` / `PendingPage` / `TaskDetailPage` / `PlanDetailPage` / `CreateTaskPage` / `CreatePlanPage` / `ApprovePage` / `AdminPage`），而这两个页面**仍然不在其中**，全仓库 `.ets` 里也**仍然没有任何地方引用它们** —— 即：**C-7 至今未修**。 |
| 为什么算问题 | ① 若**不是**设计需要的：它们是死代码，且 `@Entry` 与「未登记路由」的组合会让后来人误以为可用（本项目 2026-09-16 就为此立过规矩：**登记进 `main_pages.json` 的页面必须有 `@Entry`，不登记的页面不要留 `@Entry`**）；② 若**是** Figma 设计需要的（启动页 / 等待分配页）：那缺的是**接线** —— 没有入口会跳过去，用户永远看不到。 |
| 建议处置 | 请判断这两个页面在本轮 Figma 设计里的定位：<br>· **需要** → 在 `main_pages.json` 补登记，并从 `EntryAbility`（启动页）或相应流程（等待分配页）真正跳转过去；<br>· **不需要** → 删掉这两个文件（或至少去掉 `@Entry`），避免再变成孤儿。 |
| 验收标准 | `@Entry` 页面集合与 `main_pages.json` 的登记集合**一一对应**（**2026-10-04 复核：当前 11 ↔ 11，已相等**）；另有两个**不带 `@Entry`、也未登记**的孤儿页面 `SplashPage` / `PendingWaitPage`，应从界面可达或删除。 |

---

## 五、上一轮「核查过但不是 bug」的清单（**本轮未复验，仅供参考**）

> ⚠ 本轮 Figma 重构重写了 `entry/` 下的多数文件，下表是 **2026-09-18 那一版代码**的结论。
> 若要复用请**以当前代码为准**重新确认。

| 项 | 上一轮结论 |
| --- | --- |
| `components/SegmentedControl.ets` | 未见 bug；`selectedIndex` 由 `indexOf()` 派生恒在范围内。仅提示 `options` 目前是普通成员（不可动态更新）。 |
| `ProgressBar` 参数改名 `trackHeight` | 正确，两个调用点都已用新名，`10505001` 冲突已消除。 |
| `PermissionStore` 新增 `AssignPending` | 与服务端一致；运维账号不再显示该入口（客户端本就不渲染 `ops`）。 |
| `RegisterPage` 的 `inviteInvalid` | 正确：服务端对失效链接返回 200 + `enabled:false`，注册对无效 token 不阻断。 |
| 创建/编辑任务与课题的请求负载 | 与 `h_task.cj` 的白名单（title/desc/owner_id/plan_id/due_at）匹配。 |
| `Env.ets` 的联调地址 | 上游 `9fec83e` 已改为 `http://10.0.2.2:8080`。**跨机联调**要改成后端电脑的局域网 IP —— `10.0.2.2` 是"跑模拟器的那台电脑"的地址，别用在"服务器在别人机器上"的场景。 |
| `ManagePage` 会长移交二次确认的 `AlertDialog` 层级 | **不确定**：`bindContentCover` 打开时调 `AlertDialog.show()`，若被覆盖层挡住会表现为"点了确认没反应"。需真机/模拟器实测。 |

---

## 六、给前端小组的验收建议

1. 按 **2026-10-04 复核，本文件只剩 C-7 一条待处理**（即上面两个孤儿页面定去留）。C-1 / C-2 早已由 2026-09-19 的重构解决；**C-3 / C-4 / C-5 / C-6 也已修复**（证据见第三节的修订表）。
2. 建议顺序：**C-7**（决定文件去留，一分钟的事）。C-3 / C-4 / C-5 / C-6 已无需再排。
   ⚠ 2026-10-04 新发现的客户端缺陷（**C-9…C-12**：任务列表只取第 1 页 / 管理页候选只取前 50 人 / 日历对账清空描述 / HttpClient 去重跨会话）**不在本文件**，见 `docs/client-build.md` §3.8。
3. 每条都写了**可操作的验收标准**，请按条自测。
4. 客户端改完请**重新构建并装机实测**。顺带说明：服务端本轮除 C-8 的落地页按钮外**没有其他改动**，且已含 2026-09-18 那批修复
   （请求体闸门 411/413/415、`INVALID_JSON` 信封、框架"短读当 EOF"补丁）——
   如果联调中看到 411/413/415，那是服务端**有意**的拒绝，见 `docs/api-design.md` §1.3 的错误码表。
