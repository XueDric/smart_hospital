# 社团管理工具 · 前端对接说明

> 📁 **前端对接精简版** ｜ 本文件：`frontend-brief.md` ｜ [全部文档目录](README.md)

- 面向：鸿蒙客户端 / 前端开发
- 版本：v1.0（接口已冻结）
- **本文是精简版。** 完整设计见 `api-design.md`（40 个接口逐条定义）；范围与业务规则见 `v1-scope.md`

---

## 1. 这个产品要解决什么

两个问题：

1. 社团里有哪些人
2. **每件事由谁负责、做到什么程度**

**首页必须是「我的任务」，不是组织架构图。** 名录只是任务的目录——真正让人每天打开 App 的是"我负责什么"。

客户端形式：鸿蒙 App，服务端自建（HTTPS）。

---

## 2. 页面清单（11 个）

| # | 页面 | 关键点 |
| --- | --- | --- |
| 1 | **登录页** | 手机号 + 密码；注册入口；忘密码引导联系会长 |
| 2 | **我的任务**（首页） | 按截止排序；逾期红色高亮；阻塞项单独一组 |
| 3 | 任务列表 | 按部门 / 人 / 状态 / 课题筛选；新建任务入口 |
| 4 | 任务详情 | 改状态、填阻塞原因、加入日历 |
| 5 | 课题列表 | **树形**，可展开折叠；显示 `已完成 n / 共 m`（含整棵子树） |
| 6 | 课题详情 | 面包屑 + 子课题 + 本级任务 + 递归进度 |
| 7 | 成员名录 | 按 4 个组织分组；点进去看某人负责的事 |
| 8 | 加入流程 | 注册口令 + 手机号/姓名/密码 → 变 `pending` |
| 9 | 待分配审批 | 待分配列表；**多选批量分配** |
| 10 | 管理 | 部门、角色、注册口令、招募链接、重置密码、会长移交 |
| 11 | **我的 / 个人设置** | 本人信息、改密码、退出登录 |

---

## 3. 通用约定

| 项 | 约定 |
| --- | --- |
| 基地址 | `/api/v1`（健康检查 `GET /health` 无前缀） |
| 编码 | UTF-8，`application/json` |
| 认证 | `Authorization: Bearer <token>`，有效期 **30 天**，滑动续期 |
| 时间 | ISO 8601 带时区：`2026-09-20T18:00:00+08:00`；可空用 `null` |
| 分页 | `?page=1&size=50`（**page 从 1 开始**）→ `{ items, total, page, size }` |
| 幂等 | 创建类接口传可选 `client_token`（UUID），24h 内重复提交返回首次结果 |

### 响应格式

**成功**

```json
{ "ok": true, "data": { } }
```

**失败**

```json
{ "ok": false, "error": { "code": "TASK_NOT_FOUND", "message": "任务不存在", "fields": { } } }
```

### 错误处理（网络层按状态码，业务层按 code）

| 状态码 | 客户端动作 |
| --- | --- |
| 401 | **统一跳登录页**（token 失效），不需要解析 body |
| 403 | 提示无权限 |
| 400 / 409 | 按 `error.code` 显示文案；`fields` 做表单逐字段提示 |
| 429 | 提示"尝试过于频繁" |
| 500 | 通用错误提示，**不要展示后端内容** |

**常用 code**：`VALIDATION_FAILED` / `REGISTER_CODE_INVALID` / `AUTH_BAD_CREDENTIALS` / `MEMBER_PENDING` / `MEMBER_DISABLED` / `FORBIDDEN_ROLE` / `FORBIDDEN_NOT_IN_DEPT` / `FORBIDDEN_LAST_PRESIDENT` / `BLOCKER_REQUIRED` / `PLAN_CYCLE_DETECTED` / `PLAN_DEPTH_EXCEEDED` / `DEPT_NOT_EMPTY` / `MEMBER_HAS_OPEN_TASKS` / `TOO_MANY_ATTEMPTS` / `ALREADY_EXISTS` / `*_NOT_FOUND`

---

## 4. 接口清单（40 个）

### 认证（5）

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| POST | `/auth/register` | 注册（产 `pending` 账号，**即可登录**） |
| POST | `/auth/login` | 登录 |
| POST | `/auth/logout` | 注销 |
| GET | `/auth/me` | **启动必调**：校验 token + 拿权限摘要 |
| PUT | `/auth/password` | 本人改密 |

### 组织与成员（19）

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| GET / POST | `/depts` | 组织列表 / 新建 |
| PATCH / DELETE | `/depts/{id}` | 改名排序 / 删除（非空拒绝） |
| GET | `/members` | 成员名录（**全社团可见**；`?q=` 按**姓名或部门名**模糊搜索，2026-09-16 新增） |
| GET / PATCH | `/members/{id}` | 成员详情（`stats` 含 `open_tasks` / `done_tasks` / `overdue_tasks`）/ 编辑 |
| POST | `/members/{id}/disable` | 移出社团（有未完成任务会拒绝） |
| GET | `/members/pending` | 待分配列表 |
| POST | `/members/{id}/assign` | 单个分配部门+角色 |
| POST | `/members/assign-batch` | **批量分配**（逐条报告，可部分成功） |
| POST | `/members/{id}/transfer-presidency` | 会长移交（原子操作） |
| POST | `/members/{id}/reset-password` | 重置密码（返回一次性临时密码） |
| GET | `/register-config` | 查看注册口令 |
| PUT | `/register-config/code` | 更换口令 |
| POST | `/register-config/rotate` | 随机轮换口令 |
| GET / POST | `/dept-invite-links` | 招募链接列表 / 生成 |
| DELETE | `/dept-invite-links/{token}` | 停用链接 |
| GET | `/join/{token}` | **公开**：把招募链接里的 token 换成 `{ dept, enabled }`（预填部门用，2026-09-16 新增） |

### 任务（8）

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| GET | `/tasks/mine` | **首页**：服务端已分好组 |
| GET | `/tasks` | 列表（筛选 / 分页） |
| GET / POST | `/tasks/{id}` | 详情 / 创建 |
| PATCH | `/tasks/{id}` | 编辑（改 `owner_id` 即转交） |
| PUT | `/tasks/{id}/status` | 改状态 + 填阻塞原因 |
| DELETE | `/tasks/{id}` | 删除（软删除） |
| POST | `/tasks/lookup` | **日历同步用**：批量查任务是否还在 |

### 课题（6）

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| GET | `/plans` | **整棵树**（不分页，含 `children` 与递归进度） |
| GET | `/plans/{id}` | 详情（面包屑 + 子课题 + 本级任务） |
| POST | `/plans` | 新建课题 / 子课题 |
| PATCH | `/plans/{id}` | 编辑 |
| POST | `/plans/{id}/move` | 移动（换父节点） |
| DELETE | `/plans/{id}` | 删除（子节点**上提一级**，不级联删） |

---

## 5. 核心数据结构

### MemberBrief

```json
{ "id": 12, "name": "张三", "role": "member",
  "dept": { "id": 2, "name": "运营部" },
  "status": "active", "joined_at": "…" }
```

`role`：`president` / `vice_president` / `lead` / `vice_lead` / `member`（`pending` 时 `role`、`dept` 均为 `null`）
`status`：`pending` / `active` / `disabled`
**注意：不含手机号**（隐私最小化）。

### Permissions（由 `GET /auth/me` 返回）

```json
{ "view_scope": "all", "manage_members": false, "set_role": false,
  "create_plan": false, "create_task": false, "update_any_task": false,
  "manage_depts": false, "view_register_code": false,
  "change_register_code": false, "manage_invite_links": false,
  "transfer_presidency": false }
```

`view_scope`：`all`（**所有 active 成员**）/ **`none`**（pending 账号）。`dept` / `self` 不再产生。

后 5 个布尔是**管理页四张分区卡**的显示开关（2026-09-16 新增，对应 UI 设计规格 P09/P10）：

| 字段 | 谁能看到对应入口 |
| --- | --- |
| `manage_depts` | 部门与组织（增删改）—— **仅会长** |
| `view_register_code` | 注册口令**明文** —— 会长 / 副会长 |
| `change_register_code` | 更换 / 随机轮换口令 —— **仅会长** |
| `manage_invite_links` | 招募链接增删启停 —— 会长 / 副会长 |
| `transfer_presidency` | 会长移交 —— **仅会长** |

> ⚠️ **客户端读它只是为了画界面，绝不能用它替代服务端校验。**
> 典型例子：副会长的 `manage_members` 是 `true`，但 `manage_depts` 是 `false` ——
> 「部门与组织」入口必须按 `manage_depts` 隐藏，不能因为"他是管理员"就显示出来。

### TaskBrief / TaskDetail

`TaskBrief`：`id` / `title` / `status` / `owner` / `dept` / `plan` / `due_at` / **`is_overdue`** /
**`overdue_days`** / `blocked` / **`blocker`** / **`needs_help`** / `updated_at`
`TaskDetail` = `TaskBrief` + `desc` / `plan_path`（面包屑）/ `created_by` / `created_at` / `completed_at`

- **`blocker` 现在也在 `TaskBrief` 里**（2026-09-16）：首页「阻塞中」卡片要直接渲染阻塞原因高亮块，
  不必为每张卡再打一次详情接口。非阻塞任务为 `null`。

- `overdue_days`：**逾期天数，服务端算好的**（2026-09-16 新增）。
  `is_overdue=true` 且 `overdue_days=0` 表示"今天逾期"，此时显示「已逾期」而不是「逾期 0 天」。
- `needs_help`：**求助对象**（2026-09-16 新增），形状 `{ "dept": {id,name}, "member": MemberBrief|null }`，
  没有求助对象时为 `null` —— 据此决定**渲不渲染**「需要帮助 · 宣传部 陈屿」那一行。
  写入方式：`PUT /tasks/{id}/status` 里与 `status=blocked` 一起传 `help_dept_id` / `help_member_id`
  （只填人会自动补齐部门；离开 blocked 自动清空）。

`status`：`todo` / `doing` / `blocked` / `done`（**只有 4 档**）

### PlanBrief

`id` / `title` / `owner` / `dept`（**仅顶层有值**）/ `due_at` / **`progress: { done, total }`** / `task_count`（本级）/ `child_count` / `children`

> `progress` 是**递归值**，含整棵子树的所有任务。

---

## 6. 客户端必须知道的 5 件事

### ① 注册后是 `pending`，没有权限

注册成功即返回 token，但账号**没有任何权限**。客户端应跳转「等待管理员分配」页，**而不是主界面**。
`pending` 账号可以正常登录，只是 `permissions` 全为 `false`、`view_scope` 为 `none`。

**招募链接的部门预填怎么走（2026-09-16 新增，补上了原先的空档）**：

1. 用户拿到 `https://<host>/join/<token>` 里的 token；
2. App 调 **`GET /api/v1/join/{token}`**（免认证）→ `{ "dept": {"id":2,"name":"运营部"}, "enabled": true }`；
   失效 / 停用同样是 200，但 `dept` 为 `null`、`enabled` 为 `false` → 渲染「链接已失效」；
3. 注册时把这个 **`invite_token`** 原样带上（**不用**自己换算 `dept_id`）：
   服务端解析 token 得到部门，**优先于**你传的 `dept_id`；
4. 响应里的 **`dept_hint`** 是本次实际采纳的预填（`null` = 没有）—— 用它渲染
   「来自于招募链接的部门预填：运营部。它只是 dept_hint，审批前不生效。」

> 链接只是便利：不免除注册口令（口令才是准入），也不赋予任何角色。
> 链接已停用时**注册照样成功**，只是预填退回你传的 `dept_id`（都没有就为空）。

**密码规则（2026-09-16 定稿，客户端表单要按同一口径校验）**：

| 维度 | 规则 |
| --- | --- |
| 长度 | **8–32 字节**（服务端按字节算，不是字符数） |
| 字符集 | **只允许数字、英文和符号**（可见 ASCII，如 `._/\-!@#`） |
| 禁止 | 中文、全角字符、空格 / TAB / 换行 |

- 注册的 `password` 与 `PUT /auth/password` 的 `new_password` **同一口径**；
- 违反时返回 `400 VALIDATION_FAILED`，`error.fields.password`（改密是 `fields.new_password`）
  给字段级提示 —— 直接渲染在输入框下方即可；
- ⚠️ 这处**与设计规格 P12 的「6-32 位」有意不同**（下限取 8），
  客户端校验要按 **8** 来，否则用户会在 6–7 位时被服务端挡回。

### ② 「逾期」与"逾期几天"都是服务端算好的，客户端不要自己算

`TaskBrief.is_overdue` 与 **`overdue_days`** 直接使用。分组（逾期 / 今天 / 本周 / 以后 / 无截止）
也由 `GET /tasks/mine` 返回，**客户端不重复实现**——否则跨设备口径会不一致。

**部长 / 副部长的首页会多出"本部门别人的阻塞项"**（2026-09-16 新增）：
`GET /tasks/mine` 的 `blocked` 组与时间分组里，可能混有**不是你负责、但本部门被阻塞**的任务
（设计规格 P03「部长在首页即可看到这条」）。判据是 `owner.id` 与自己的 id 是否相同；
`counts.borrowed_blocked` 给出其中有多少条。会长 / 副会长不会有这种条目。

**任务可见范围（2026-09-16 变化）**：`GET /tasks`、`GET /tasks/{id}`、`GET /plans`、`GET /plans/{id}`
现在**全体成员都能看全社团**（设计规格 P02「全社团范围可见」）。
⚠️ 但**改**还是按老规矩：改状态只有负责人 / 部门管理员 / 会长 / 副会长，编辑与删除还要看创建人——
看得到不等于改得动。

### ③ 日历同步在客户端本地完成（**这是客户端的活，不是服务端**）

服务端**不存**任何日历字段。客户端本地维护映射：

```
task_id → { event_id, cached_due_at, cached_status }
```

拉取任务时比对：

| 差异 | 动作 |
| --- | --- |
| `due_at` 变了 | **更新**日历事件（不得新建） |
| `status` 变为 `done` | **删除**日历事件 |
| 任务不在服务器返回中 | **删除**日历事件 |
| 日历权限被拒绝 | 降级为导出 `.ics` + 应用内高亮 |

用 `POST /tasks/lookup` 批量确认"我加过日历的任务现在还在不在"，返回的 `missing` 数组即需清理的。

> ⚠️ 不做"更新与删除"，日历里会堆积错误的过期提醒，两周后成员就不再相信它。**这项需单独排期。**

### ④ 自签证书需要在 App 内配置信任

服务端用自签 HTTPS。**鸿蒙默认不信任自签证书**，需要在 `resources/base/profile/` 下配置网络安全配置并内置 CA 证书。

⚠️ 两个待确认项（会影响此处实现）：

- 证书**必须带 SAN**（我们的服务是 IP 访问，SAN 需写 `IP:<公网IP>`）。轻舟示例自带的证书没有 SAN，**不能直接用**
- 鸿蒙对**明文 HTTP** 也有限制，需实测确认默认行为

### ⑤ 有些 403 / 429 是**设计**，不是 bug

服务端有一批"看起来像权限出错"的响应，**不要当异常上报**，按文案提示即可：

| 场景 | 响应 | 说明 |
| --- | --- | --- |
| 副会长调整 / 重置 / 禁用**另一位副会长** | `403 FORBIDDEN_ROLE` | **同权保护**：不可作用于与自己**同权或更高权**的人。会长同样受限（不能重置自己），部长也受同一规则约束 |
| 把**最后一个会长**降级 / 移出 | `FORBIDDEN_LAST_PRESIDENT` | 社团必须始终有一位会长 |
| 注册时连续输错口令 | `429 TOO_MANY_ATTEMPTS` | 节流**按客户端 IP**（2026-09-14 起）：只影响注册，**别人的 IP 不受影响**，也不影响登录与其它接口 |
| `pending` 账号访问业务接口 | `403 MEMBER_PENDING` | 应引导到「等待管理员分配」页，不进主界面 |

**同权保护覆盖这五类动作**：重置密码 / 调部门改角色 / 移出社团 / 编辑姓名 / 审批分配
（`assign`、`assign-batch`）。

> 界面上的「管理」入口本来就该按 `permissions` 隐藏或置灰；即使显示出来、用户点了，
> 服务端也会挡住 —— 这是**双保险**，不是前后端矛盾。
> 另外：**重置密码这条连自己都禁**（会长也不能重置自己）。本人改密走 `PUT /auth/password`。

---

## 7. 客户端额外工作量（需单独排期）

| 项 | 说明 |
| --- | --- |
| **日历同步机制** | 见 6.③，含本地映射表、比对逻辑、权限被拒降级 |
| **自签证书信任** | 见 6.④，含网络安全配置与内置证书 |
| 幂等处理 | 创建类接口生成并带上 `client_token` |
| 分页与筛选 | `GET /tasks`、`GET /members` |

---

## 8. 参考文档

| 文档 | 内容 |
| --- | --- |
| `api-design.md` | **完整接口设计**：每个接口的请求/响应/错误码/权限 |
| `v1-scope.md` | 范围基准：11 个页面、6 张表、19 条业务规则 |
| *（已移出仓库）* | 服务端 TLS 实测结果（协议版本、自签证书注意事项）→ 上层 `cangjie-upstream\qingzhou-tls-verification.md` |

**接口已冻结。** 如需变更，请先提出来——改动会同时影响服务端与本文档。
