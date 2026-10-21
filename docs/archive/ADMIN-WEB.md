# 服务端托管的后台管理台（`/admin/`）

> 一句话：`server/admin-web/` 是**零构建的纯静态浏览器管理台**，由服务端自己挂在 `/admin`，
> 与 REST API **同源同端口**；数据一律走 `/api/v1/admin/*`，页面本身不做任何鉴权。
>
> 2026-10-14 增。需求来自「智慧医院导诊后台」的设计稿：**AI 模型配置**（多模型、类型、提供方、
> 温度、上限、启停、连通性测试、失效配置缓存）+ 侧栏其余页面。

---

## 一、为什么是"服务端托管静态页"，不是别的形态

| 形态 | 否决/采纳的理由 |
| --- | --- |
| ❌ 继续扩鸿蒙原生 `feature-admin`（ArkTS 8 页） | 它是**设备端**应用：要装到鸿蒙设备/模拟器才能用，改一行要重新编译打包；而"配置模型、看用量"是运维动作，应该打开浏览器就能做 |
| ❌ 另起一个前端工程（Vue/React + npm 构建） | 引入 `node_modules` 与打包产物 ⇒ 出现"源码是新的、跑起来是旧的"，并且本仓的管理台**没有任何前端构建链**（`server/admin-web/` 内没有 `package.json`，也不参与 `build.ps1`；vendored 的轻舟快照里另有一份上游 Vue3 演示 `admin-web/`，与本管理台无关、不参与构建）；为 11 个页面引入一整套工具链，维护成本远大于收益 |
| ✅ **服务端托管的纯静态 SPA** | 同源同端口 ⇒ **没有 CORS、没有证书、没有反向代理**话题；改完刷新即生效；仓里只多出几个 `.html/.css/.js` 文本文件；`git diff` 看得见每一行 |

**代价（明确接受）**：没有框架 ⇒ 没有响应式与虚拟 DOM，页面用原生 `document.createElement`
风格的 `h()` 助手拼装（`js/ui.js`）；数据量按"管理台"规模假设（一页 ≤ 200 行）。

---

## 二、怎么跑

```powershell
# 1) 构建（在 server/ 下；含管理台静态文件不需要额外步骤——它们是运行时读的普通文件）
.\build.ps1

# 2) 起服务端（管理台随服务端一起上线）
.\build\hospital-server.exe serve "mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital_test" --port 8091

# 3) 打开（首次登录用 create-admin 打印的口令）
start http://127.0.0.1:8091/admin
```

- 启动 banner 会打印 `管理台：http://<addr>:<port>/admin/`。
- **找不到目录时不会静默降级**：`pickAdminWebDir()` 依次找 `admin-web` / `server/admin-web` /
  `../admin-web`（相对**进程工作目录**），找不到就打印告警并**不挂载**（API 不受影响）。
  ⇒ 从仓库根目录起服务端时，第 2 个候选会命中；从 `server/` 起是第 1 个。
- 为什么判"目录存在"而不是"`index.html` 存在"：部署不全时应该报"管理台不可用"，
  而不是让它表现为"功能没做"。

---

## 三、目录结构

```
server/admin-web/
├── index.html          壳页面（登录视图 + 顶栏/侧栏/内容区 + modal/toast 挂载点）
├── favicon.svg         纯文本 SVG 图标（不引二进制资源）
├── css/style.css       无框架样式（CSS 变量 + 十几个组件类）
└── js/
    ├── api.js          fetch 封装：统一信封拆包、ApiError、令牌存取、401 回调
    ├── ui.js           h/table/card/toast/openModal/confirmBox/fmtTime/fmtPermille…
    ├── pages.js        11 个页面（注册进 window.HOSPITAL_PAGES）
    └── app.js          登录流程 + 侧栏生成 + #/<id> 哈希路由 + 面包屑
```

⚠ `index.html` 里的资源**必须写绝对路径**（`/admin/css/style.css`）：裸 `/admin`（不带尾斜杠）
会被静态层按目录认领并回 `index.html`，此时相对路径会被解析成 `/css/style.css` ⇒ 404。
理由见 [../server/README.md(../../server/README.md) 坑 **AL**。

---

## 四、页面清单 ↔ 接口映射

| 页面（`#/<id>`） | 主要接口 | 备注 |
| --- | --- | --- |
| 运营看板 `dashboard` | `GET /api/v1/admin/dashboard`、`GET /health` | `/health` 是**唯一平铺返回**（没有 `data` 信封）的接口，故 `API.health()` 显式声明 `raw`；页脚显示"服务端版本 / 数据后端 / 今天(时区)" |
| 用户管理 `users` | `GET/POST /api/v1/admin/users`、`POST /:id/password` | 列表模式本轮新增（`limit/offset/role/status`）；口令材料**永不出现**在响应里 |
| 科室管理 `departments` | `GET/POST/PUT/DELETE /api/v1/admin/departments` | 删除遇 `BASE_IN_USE` 时追问是否 `?force=true` 软删；列表底部有**条数行**（`共 N 个科室，本页 M 条`，截断时追加警告） |
| 医生管理 `doctors` | `GET/POST/PUT/DELETE /api/v1/admin/doctors` | 科室下拉**加载完成才渲染**（失败原因写在控件旁的 hint 上，不再只在 toast 里一闪而过）；列表底部有**条数行**（`共 N 位医生`） |
| 排班号源 `schedules` | `GET /api/v1/schedules`、`POST/PUT /api/v1/admin/schedules[/:id]` | 页面自算 `已约 = 放号 − 余量`；编辑弹窗里的 `version` 标注"乐观锁，不要改"；底部写的是**「本页 N 条」**（该接口只回 `count`，没有 `total`） |
| **AI 模型配置** `ai-models` | `GET/POST/PUT/DELETE /api/v1/admin/ai/models[/:id]`、`POST /invalidate`、`POST /:id/test` | 本轮新增（截图主页面）。温度只对 `CHAT` 有意义，`EMBEDDING` 行显示 `—` |
| AI 全局设置 `ai-settings` | `GET/PUT/DELETE /api/v1/admin/ai/settings[/:key]` | 密钥项只显示"是否已设置 + 引用类型"，可回默认值 |
| Prompt 模板 `ai-prompts` | `GET/PUT/DELETE /api/v1/admin/ai/prompts[/:name]` | 三项：`dept` / `previsit` / `redflag`；**空串 = 删行恢复默认**；服务端校验必需占位符与长度 |
| 工具中心 `ai-tools` | `GET/PUT /api/v1/admin/ai/tools[/:name]` | 白名单 6 条只读工具，开关即时生效 |
| 医学知识库 `kb` | `GET/POST/PUT/DELETE /api/v1/admin/kb/docs[/:id]`、`GET /admin/kb/stats` | 概览里的 `embedding_note` 直接回答"为什么没召回" |
| 系统公告 `notices` | `GET/POST/PUT/DELETE /api/v1/admin/notices[/:id]` | 患者端只看"已启用且生效时间已到"的公告（服务端过滤） |
| 患者档案 / 症状标签库 / Agent 执行观测 | —— | **未做**：侧栏灰显并写明原因（后端目前没有这三块的接口） |

### 4.1 列表条数与"截断"的显示纪律（2026-10-14 第三轮复查后收紧）

服务端分页（B9）给了 `total`，但**没有 `limit` 的请求不等于"全都要"**：`limit <= 0` 走默认值，
默认也是 200（`server/src/http_base.cj` 的 `BASE_LIST_DEFAULT_LIMIT` / `BASE_LIST_MAX_LIMIT`）。
所以前端（`js/pages.js`）定下三条规矩：

1. **凡列表/下拉一律显式传 `limit: PAGE_MAX`**（`const PAGE_MAX = 200`，与服务端上限对齐）。
   不传时"被截断"在界面上完全看不出来——这是最危险的一种静默。
2. **列表页底部必须有条数行**：`共 N <单位>，本页 M 条（offset=…，limit=…）`；
   仅当 `total > offset + count` 时才追加一句红字警告「还有 K 个未显示（单页上限 200）」。
   把"库里就这么多"和"上限挡住了一部分"分开——前者正常，后者使用者必须知道。
3. **下拉被截断时用控件旁的 hint 说明**（下拉里只能显示 `items`，装不下"还有多少条"）：
   `⚠ 仅显示前 200 个科室（共 431 个科室，超出单页上限 200）—— 请先用搜索/筛选缩小范围`。
   典型受害场景：排班表单的**医生**下拉是必填项，超过 200 位时排在后面的科室会显示成"没有医生"。

⚠ 这条纪律被钉进了冒烟：`tests/admin-web-smoke.mjs` 的 `REQUIRED_TEXT` 要求科室页正文含
`共 … 个科室`、医生页含 `共 … 位医生`、排班页含 `本页 … 条`。这些字眼掉了页面照样能渲染、
正文照样够长，只有真的点进去才会发现，所以必须由冒烟拦。

---

## 五、鉴权与安全口径

1. **静态页面本身不鉴权**：任何人拿到 `index.html` 都能打开登录页。这是刻意的——
   页面里没有任何数据，数据全部来自逐条校验的 `/api/v1/admin/*`。
2. **令牌**：`POST /api/v1/auth/login` 拿不透明令牌，存 `localStorage`（键 `hospital_admin_token`），
   之后所有请求带 `Authorization: Bearer`。`401` ⇒ 清会话 + 回登录页（`API.setUnauthorizedHandler`）。
   启动时用 `/auth/me` **验证**既有令牌并要求 `role === 'admin'`（不是"有令牌就当登录成功"）。
3. **密钥永不回显**：配置里只存引用（`env:变量名` / `file:路径`），接口只回
   `key_ref_set`（有没有）/ `key_ref_kind`（env|file）/ `key_source`（本条|全局）。
   连 `env:变量名` 本身也不回——变量名会泄露部署约定。
4. **账号列表不读口令材料**：`AuthRepo.listUsers()` 的 SELECT **故意不选** `pw_salt/pw_hash`，
   "列表被整页导出"是最常见的泄露路径（`auth-check.ps1` 有断言钉住）。
5. **连通性测试不泄漏密钥**：探测失败时的 `reason` 是脱敏后的（`aiRedact`），
   且**失败也是结果**（恒 `200` + `probe.ok=false`），不会被误当成服务故障。
6. **同源**：页面与 API 同端口 ⇒ 不涉及 CORS；服务端 CORS 中间件仍是默认值（`origin="*"`），
   因为页面本身不使用跨源请求。

---

## 六、本轮新增 / 扩展的服务端接口

### 6.1 AI 模型配置（`ai_model` 表）

| 方法与路径 | 要点 |
| --- | --- |
| `GET /api/v1/admin/ai/models?include_disabled=` | 回 `items[{id,name,kind,kind_label,provider,base_url,request_url,model,temperature,max_tokens,key_ref_set,key_ref_kind,key_source,enabled,is_default,in_use,created_at,updated_at,updated_by}]` + `count` / `global_key_ref_set` / `cache_ttl_secs` |
| `POST /api/v1/admin/ai/models` | body `name/kind/provider/base_url/model/temperature/max_tokens/key_ref/enabled/is_default`；缺省 温度 `0.3`、上限 `2048`、`enabled=true`；**201** `{id, model}`；重名 ⇒ `409 AI_MODEL_NAME_TAKEN` |
| `PUT /api/v1/admin/ai/models/:id` | **PATCH 语义：缺省的键保持原值**（否则"只想改温度"会把 `key_ref` 清空）；`"key_ref": ""` 才表示清空 |
| `DELETE /api/v1/admin/ai/models/:id` | **硬删**；"留着不用"请用 `PUT enabled=false` |
| `POST /api/v1/admin/ai/models/invalidate` | 同时失效模型与全局设置两份缓存，回 `{invalidated, model_cache_ttl_secs, settings_cache_ttl_secs, next_call_reloads, cleared_at}` |
| `POST /api/v1/admin/ai/models/:id/test` | 从**库里**取该行（不接受请求体里的临时值，否则"测通了但存的是另一份"），恒 `200`，回 `{id, probe:{ok,kind,model,request_url,elapsed_ms,http_status,key_source,reason,sample}}`；**刻意绕过 `ai.enabled`** —— 排查"配置对不对"不该被总开关挡住 |

校验闸门（写入前）：`https://` 强制（明文调用大模型 = 密钥裸奔）、`temperature ∈ [0,2]`、
`max_tokens ∈ [64,8192]`、名称/提供方/地址/模型名非空且不含控制字符、`key_ref` 非空时必须是
`env:` / `file:` 引用。

### 6.2 账号列表（`GET /api/v1/admin/users` 双模式）

- 给了 `login_name` ⇒ **原来的精确查询**（找不到仍 `404 USER_NOT_FOUND`，老调用方零改动）。
- 没给 ⇒ 列表模式：`limit`（默认 50，越界回默认）、`offset`、`role`、`status`（白名单外的值 =
  不筛），回 `{items, count, total, limit, offset}`；列表项键名与精确查询**保持一致**（`user_id`）。

### 6.3 排班可改（`PUT /api/v1/admin/schedules/:id`）

此前**只有建、没有改**：号源写错或医生停诊只能再开一条排班，老排班连同已经约出去的号
继续挂在患者端可约。现在支持 PATCH `total_num` / `enabled` + `version` 乐观锁：

- 不变量"放号数 ≥ 已约数"放在**一条原子 SQL 里**（`remain_num + (? - total_num) >= 0`），
  影响 0 行时回读分辨"不存在 / 版本冲突 / 数太小"三类，**不猜**；
- 改 `total_num` 时 `remain_num` 同步加减同一差值 ⇒ 已约数保持不变（不会超卖）；
- `404 SCHEDULE_NOT_FOUND` / `409 SCHEDULE_CONFLICT`（消息带上双方版本号）/ `400`。

### 6.4 顺带修掉的一个真实漏洞

`aiSettingKeyKnown()` **也认 `prompt.*` / `ai.tool.*`**，而原来的闸门只作用于 `key_ref` 与数值项
⇒ `PUT /api/v1/admin/ai/settings/prompt.dept` 能**绕过** `PromptRepo` 的占位符/长度校验直接落库。
现在 `PUT .../ai/settings/:key` 只接受**登记表里的 `ai.*` 项**，其余一律 `400` 并在消息里
指路（Prompt 走 `PUT /admin/ai/prompts/:name`，工具走 `PUT /admin/ai/tools/:name`）。

---

## 七、运行时怎么用这些配置

```
ai_model 表（多条命名配置，每种类型一个默认）
   │  defaultOf(kind)：优先 enabled + is_default，取 id 最小；否则该类型第一条 enabled；都没有 ⇒ None
   ▼
AiSettingsRepo.options(now)  ← KV 里的 ai.enabled / 旧 ai.endpoint / ai.model / ai.key_ref
   │  默认模型行**整体覆盖** KV（端点、模型、密钥、温度、上限）
   │  · key_ref 为空 = 回落全局 ai.key_ref（不覆盖）
   │  · endpoint 过 aiModelRequestUrl() 拼成**完整请求 URL**（/chat/completions）
   ▼
AiRuntimeOptions（含 temperature，此前根本没有这个字段）
   ▼
ai_call.cj：请求体 model / max_tokens / messages / **temperature**
```

- 旧口径**不发 `temperature`** = 把决定性交给服务商默认值（通常是 1.0）⇒ 同一份主诉在
  不同服务商上表现不一致。现在随行下发，缺省 `0.3`。
- 缓存 TTL 5 秒（`aiModel.reload` / `AiSettingsRepo.reload`），任何写操作都会 `invalidate()`
  ⇒ "保存后自动失效缓存，下一次请求动态构建实例，无需重启"（页面提示语说的就是这件事）。

---

## 八、怎么验证

| 手段 | 覆盖 |
| --- | --- |
| `tests\ai-model-check.ps1`（**46 条断言**，含 2 条按条件执行） | 模型配置全链路：鉴权（无令牌 401 / 患者 403）、播种的两条默认行与 `request_url` 拼接、密钥不回显、校验闸门（明文 http / 温度越界 / 空名 / 未知类型 / 非法 `key_ref` / 重名）、PATCH 语义、`is_default` 唯一、连通性测试恒 200 且不受 `ai.enabled` 影响、缓存失效**真的**读到库里的新值、`settings` 闸门（并断言库里没留下那行）、删除与夹具自清 |
| `tests\admin-web-smoke.mjs` | 无头 Edge + CDP：真实 boot 流程 + **11 个页面逐个渲染** + **写路径**（公告新建/下架/重新发布/删除、知识库 PATCH/空正文 400/重切块、必填校验、`DELETE ai/settings/:key` 收窄、`PUT` 不存在模型 404、未注册路径 404 信封、未带令牌 401、登出回登录页）；模态框能开能关；收集 `console.error` / 未捕获异常 / `>=400` 响应，逐页截图。**判定全部计入退出码**：登录遮罩未收起 / 侧栏项数少于页面清单 / `whoami` 为空 / 页脚"读取失败" / 某页正文过短 / 某页有错误框 / 侧栏无高亮 / **某页正文缺少必须出现的字眼**（`REQUIRED_TEXT`：科室页 `共 … 个科室`、医生页 `共 … 位医生`、排班页 `本页 … 条` —— 见 §4.1）——任一为真即 FAIL |
| `tests\base-check.ps1` | 基础数据域 + 排班可改（不变量 400 / 版本冲突 409 / 停诊 PATCH / 404 / 空改动 400）+ **B8 权限动作**（AI 配置 403 且 message 是 `manage_ai`、`/admin/users` 是 `manage_user`、排班仍是 `manage_schedule` —— 证明动作名真的换了，而不是"权限被整体收紧"）+ **B9 分页**（`limit`/`offset` 真翻页、`total` 是**真总数**、`limit` 0/非数字/9999 ⇒ 200、`offset` 负数 ⇒ 0、`total` 跟着 `include_disabled` 与 `department_id` 过滤、公共选择器端点**没有** `total`） |
| `tests\auth-check.ps1` | 令牌域 + 本轮新增的账号列表模式（分页 / 筛选 / 白名单外当不筛 / 不吐 `pw_hash`） |
| `accept`（AC-16 / AC-17） | 服务端侧的确定性证明：播种幂等、`defaultOf` 与 `request_url`、运行时覆盖与温度、`key_ref` 回落、缓存与 `invalidate`、`listUsers` 不读口令材料、`updateSchedule` 的原子不变量与乐观锁 |

冒烟脚本用法：

```powershell
& $env:NODE tests\admin-web-smoke.mjs --base http://127.0.0.1:15001 --admin admin --pw <口令> --out <截图目录>
# 可选：--port <调试端口>（默认随机，避免并行打架）、--edge <msedge.exe>（默认自动探测常见安装位置）、
#       --wait / --net-idle / --min-chars（页面静置与正文长度门禁；默认按**网络空闲**等待，不再死等固定毫秒）
```

> ⚠ 本机 **1024–15000 是 Windows 动态端口范围**（`netsh int ipv4 show dynamicport tcp`），
> 显式 bind 该区间会拿到 `WSAEACCES(10013)`「以一种访问权限不允许的方式做了一个访问套接字的尝试」。
> 服务端/冒烟脚本请用 **≥15001** 的端口（文档里的 8091 是给正常机器写的）。

**2026-10-16 复跑**（本轮改了 `server/admin-web` 的 CSS/JS 之后）：

```powershell
$node = "D:\DevEco Studio\tools\node\node.exe"   # 或任何 ≥18 的 node
& $node tests\admin-web-smoke.mjs --base http://127.0.0.1:18096 --admin zzcheck --pw <口令> `
  --out $env:TEMP\adm-smoke --edge "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
```

退出码 **0**：11 个页面逐个渲染 + 写路径全绿，且 `consoleErrors` / `exceptions` / `badResponses` / `writeFailures` 四个数组**全空**（截图在 `--out` 目录）。

---

## 九、已知边界（明确未做）

1. **患者档案 / 症状标签库 / Agent 执行观测** 三页未实现：后端没有对应接口（`triage_stat` 只有聚合）。
2. **`EMBEDDING` 只做"配置 + 连通性测试"**：不做批量向量化回填；生产检索仍走关键词路
   （`embedding_note` 在知识库页原样显示这个事实）。
3. **`ai.ca_bundle_path` 仍不支持**：stdx 1.1.3.1 的 `TlsClientConfig` 只有 mTLS、没有信任锚入口，
   写入会被 400 拒绝（写明"不会生效，故拒绝写入"）。
4. 管理台**不做**多用户/角色区分：能登录管理台的就是 `admin`（与 `/api/v1/admin/*` 的权限口径一致）。
5. **权限动作复用（评审 B8，2026-10-14 已修）**：AI 全套端点原先复用 `Action.ManageSchedule`，
   现改为 **`Action.ManageAi`**；`/admin/users` 改为 **`Action.ManageUser`**（两者都仍是 admin-only，
   所以行为不变，变的是**语义**：403 的 message 里会打印要求的动作名，可直接看到是哪一个）。
   **遗留边界**：`http_p4.cj:421` 的"复诊重开"仍用 `Action.ManageSchedule`（属排班域动作，刻意保留）；
   `/auth/sessions/*`（查看/踢设备）**不做**动作检查 —— 它们只作用于调用者自己的 `userId`，是自服务。
6. **列表分页（评审 B9，2026-10-14 已修）**：`/admin/departments`、`/admin/doctors` 支持
   `limit`/`offset`，响应新增 `total`（同 `include_disabled`/`department_id` 过滤下的**真总数**）、
   `limit`、`offset`；`limit` 缺省/非数字/<1/>200 ⇒ **200**，`offset` 非法 ⇒ 0。
   **遗留边界**：① 公共 `/api/v1/departments`、`/api/v1/doctors` **刻意不分页**（截断的下拉框对患者
   不可见；要控规模请用 `enabled=0`）；② 管理台前端**尚未接分页控件**（列表页有上一页/下一页的只有
   用户管理），其余列表按显式 `limit=200` 拉取，**超出部分在界面上有红字警告**（见 §4.1）——
   要彻底解决就是给这几个列表页补分页控件，或给排班号源页的服务端接口补 `total`/`offset`
   （它现在只回 `count`，所以页面写的是"本页 N 条"而不是"共 N 条"）。
7. **窄屏（手机 / 竖屏）已修到"能用"，没做到"好看"**（2026-10-16，详见 §十一）：
   侧栏横过来当标签条、表格在卡片内部横向滚动、弹窗全宽、顶栏换行。仍未做的：
   ① 表格的「操作」列要**横向滑一下**才看得到（表内滚动，属预期）；
   ② `启用` 这种 2 字复选框标签在窄屏会**竖排折行**（能读，不好看，没为它单独调样式）；
   ③ 端内 `feature-admin` 看板**没有** arrived/waiting 计数（网页看板有，那是 2026-10-16 复核的另一项）。

---

## 十、这一轮踩到的坑（详细版见 [../server/README.md(../../server/README.md) 坑表）

| 编号 | 一句话 |
| --- | --- |
| AL | 静态托管前缀**不能带尾斜杠**（`/admin/` 会让子资源全 404）；裸 `/admin` 被静态层按目录认领 ⇒ `index.html` 资源必须写绝对路径；`spaFallback=false` |
| AM | 仓颉**块注释可嵌套** ⇒ 注释里不要出现 `/*`（`/admin/**`、`js/*.js` 都会触发 `unterminated block comment`，报错位置还指到文件末尾） |
| AN | "用户指定的默认（`is_default`）"与"运行时真正生效（`in_use`）"是**两个事实**，只回一个就会出现"没有任何默认标记、但 AI 确实在用某一行" |
| AO | 测试脚本的自清要覆盖它改过的**所有**状态：抢走默认位再删掉自己那行 ⇒ 库进入"该类型没有默认行"，表现为**首跑红、复跑绿**的假偶发 |
| — | PowerShell 下 `curl -d '<json>'` 的引号会被剥（服务端报 400 `VALIDATION_FAILED`，旧版文案是 `Invalid JSON body`）⇒ JSON 写文件 + `-d "@file"`；`Invoke-WebRequest` 在非交互模式直接不可用 |
| — | 含中文的 `server/**/*.ps1` **必须 UTF-8 with BOM**；`edit` 工具会剥掉 BOM ⇒ 改完要用 `UTF8Encoding($true)` 重写（否则 PS 5.1 按 ANSI 解析报"意外的标记"） |
| AP | ★★ **模拟器会自己息屏 + 上锁，"黑屏截图"不等于应用崩了** | `snapshot_display` 在息屏/锁屏时给**全黑**图（1320×2856、≈60 KB），此时 `uitest uiInput click` 全部打空；`power-shell timeout -o` 只挡息屏超时、**挡不住锁屏** | 截图**按字节数**判活（>100 KB 才算有内容）；恢复：`power-shell wakeup` → 仍黑则 `uinput -K -d 18 -u 18`（电源键，**是切换**）→ 上滑解锁 |
| AQ | ★★ **IME 弹出后注入文本会被输入法吞掉** | 登录名能填、紧接着点「口令」再注入就**始终为空**；地址栏那次表现为**开头 `http:` 被吃掉** | 输入前先收键盘（点空白处），或用 `hdc shell "uinput -K -t <文本>"`；`click 1031 2618` 只在键盘弹出时才是"回车"，否则是浏览器工具栏 |
| AR | ★★ **静态文件改了却看到旧样式 ⇒ 先怀疑浏览器缓存** | 静态响应只有 `ETag` + `Last-Modified`、**没有 `Cache-Control`**；服务端已吐新规则，浏览器仍用旧 CSS | 验证静态改动**换 origin**（另起端口 + `hdc rport`）或清缓存；**"刷新后没变"不能当结论** |

---

## 十一、窄屏（手机 / 模拟器）修复与实测（2026-10-16）

**怎么发现的**：把管理台放到 HarmonyOS 模拟器（Pura 90，1320×2856 @560dpi，浏览器视口约 **377 CSS px**）里逐页走了一遍。
旧规则只有一条 `@media (max-width: 820px){ .sidebar{display:none} }` ⇒ 手机上出现三个**真**问题：

| # | 现象 | 根因 | 修法 |
| --- | --- | --- | --- |
| 1 | 手机上**没有任何页面入口**（侧栏是唯一导航，被藏掉了），只能手改地址栏哈希 | 藏侧栏却没有替代导航 | 侧栏在窄屏**横过来当标签条**：`.sidebar{flex-direction:row}` + `.sidebar > #nav{display:flex;overflow-x:auto}`，`.nav-group-title{display:none}`，`.nav-item.active` 改用下边框高亮。**不新增 JS 分支**（同一份 `.nav-item`） |
| 2 | 列多的表把**整页**撑宽 ⇒ 横向滚动条把顶栏/卡片/弹窗一起拖走，看起来像「页面坏了」 | `table.grid` 直接挂在卡片里，没有滚动容器 | `js/ui.js` 的 `table()` 外面包一层 `.table-wrap{overflow-x:auto}`；长英文串（URL / `key_ref` / 表名）加 `overflow-wrap:anywhere`，让它在卡片里折行 |
| 3 | 顶栏一行放不下，中文被挤成**竖排单字**；弹窗固定宽度超出视口 ⇒ **复选框标签被推到屏幕外**（看起来像「没有标签」） | `.topbar` 固定高度不换行；`.modal.wide` 宽度写死 | 窄屏 `.topbar{height:auto;flex-wrap:wrap}`、面包屑 `flex:1 1 100%;order:3` 独占一行、`.whoami` 省略号；`.modal,.modal.wide{width:100%}` + `.modal-mask{padding:20px 10px}` |

改动共 **2 个文件、+48 行**：`server/admin-web/css/style.css`（+44/−1）、`server/admin-web/js/ui.js`（+4/−1）。

### 11.1 模拟器实测证据

设备 `127.0.0.1:5555`（HarmonyOS 6.1.1 / API 24 / x86_64），浏览器 `com.huawei.hmos.browser`；
服务端 **另起一份**在 18097（换 origin 绕开缓存），`hdc rport tcp:18097 tcp:18097`，管理员 `zzcheck` 登录。
截图存主机 `%TEMP%`（`C:\Users\ASUS\AppData\Local\Temp\`）：

| 图 | 内容 |
| --- | --- |
| `hos_n2.jpeg`、`hos_r5.jpeg` | `http://127.0.0.1:18097/admin/` 登录页 |
| `hos_L3.jpeg` | **运营看板**：顶栏一行（品牌 + `管理员 (admin)` + 退出登录）、面包屑独占一行、**导航标签条**出现；数据与库一致（科室/医生 `1 / 1`、挂号总数 `22`、已约 19 · 已到院 1 · 候诊 1 · 就诊中 1 · 完成 0、号源余量 `38 / 60`） |
| `hos_L4.jpeg` | **用户管理**：表格在卡片内横向滚动，列宽不再挤压整页 |
| `hos_L5.jpeg` | **新增账号弹窗**：完全落在视口内，`登录名 / 初始口令 / 角色 / 关联 ID / 显示名` 标签齐全 |
| `hos_M2.jpeg` | **AI 模型配置**：接口地址列**自动折行**（`dashscope.aliyuncs.com/compatible-mode/v1`） |
| `hos_M4.jpeg` | **新增模型配置弹窗**底部：`启用`、`设为该类型的默认（同类型只有一个默认）` 及提示**都可见**（修复前它们在视口外） |

复现命令：

```powershell
# 1) 另起一份服务端（新 origin，避开浏览器缓存与已占用的端口）
& server\build\hospital-server.exe serve 'mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital' --port 18097 --dev-auth
# 2) 端口反向映射：模拟器里的 127.0.0.1:18097 ⇒ 主机 18097
& "<SDK>\openharmony\toolchains\hdc.exe" rport tcp:18097 tcp:18097
# 3) 浏览器进 http://127.0.0.1:18097/admin/ ，用管理员账号登录
```

> ⚠ 模拟器驱动有三个坑（息屏上锁 / IME 吞字 / 浏览器缓存），已单独记进 §十 的 AP、AQ、AR 三行。

### 11.2 同时跑的门禁

- `tests\admin-web-smoke.mjs`（无头 Edge + CDP，见 §八）：退出码 **0**，11 页渲染 + 写路径全绿，四个错误数组全空。
- 模拟器逐页（本轮实际走过）：`#/dashboard`、`#/users`（含新增弹窗）、`#/ai-models`（含新增弹窗）。
  其余页共用同一批组件（顶栏/标签条/表格/弹窗），由上面的冒烟脚本覆盖。
