# 服务端代码检查报告（重点：新增后台运维页面）

- 日期：2026-10-14
- 范围：`server/` 全部代码 —— 41 个 `.cj`、`server/admin-web/`（7 个前端文件）、21 个 `.ps1`、`tests/`
- 重点：P4/P5 之后新增的**后台运维页面**（`server/admin-web` + 其 `/api/v1/admin/**` 后端）及其配套脚本/测试
- 方式：只读通读 + 交叉核对前端请求/后端 JSON 产出/错误码登记表/测试断言
- 结论：**共 30 项**（必修 4 / 应修 7 / 测试 4 / 运维脚本 7 / 提示 8），另附"已核对无问题"清单
- **修复状态（2026-10-14 当天）**：30 项**已全部处理** —— A/B/C/D 全部关闭；E1/E2/E4/E5 已修，E3/E6/E7/E8 核对后判定**无需改动**（理由见下）。逐项修法、验证证据与裁定见 [`SERVER-REVIEW-FIXES-2026-10-14.md`](SERVER-REVIEW-FIXES-2026-10-14.md)；本报告正文**保留修复前的原始描述**，便于对照与复查。
- **第二轮（2026-10-14 晚，按用户指示继续）**：原先"登记不修"的 **B8**（权限动作复用 `ManageSchedule`）与 **B9**（科室/医生列表无分页）**已根治**：
  B8 新增 `Action.ManageAi` / `Action.ManageUser`（AI 14 处、`/admin/users` 3 处改挂），B9 给管理端列表加 `limit`/`offset`/`total`（`limit` 缺省或非法 ⇒ 200；公共字典端点刻意不分页）。
  回归断言写进 `server/tests/base-check.ps1` 的 `[1.5]`/`[8]`（该脚本 74 项全绿），修法与残余边界见 FIXES 文档 §三与 §八。

## 一句话结论

新增运维页面的**功能骨架是好的**（零构建静态 SPA、同源挂载、服务端每请求鉴权、密钥不回显都做对了），但**写操作路径从未被真正验证过**：3 个必现功能缺陷 + 1 个"测试承诺的判定根本没实现"，全部指向同一个根因 —— `tests/admin-web-smoke.mjs` 只能证明"页面渲染出了字"，证明不了"按钮点得动"。

---

## 零、必修清单（建议先做这四条）

| # | 位置 | 一句话 |
|---|---|---|
| A1 | `admin-web/js/pages.js:1154` + `http_notice.cj:113` | 公告列表的「下架/重新发布」按钮必然 400，功能 100% 失败 |
| A2 | `main.cj:626-651` | 取值型参数零校验，`--bind --prod` 能吞掉 `--prod`，击穿 `--prod`/`--dev-auth` 互斥 |
| A3 | `main.cj:749-771` | 参数合法性校验晚于建库/迁移副作用，误传参会先对生产库跑 DDL |
| A4 | `http_common.cj:55-252` + `http_base.cj:118` 等 3 处 | 三个错误码抛了却没登记，客户端收到未文档化的 `code` |

---

## 一、必修：会导致功能必然失败

### A1 ★★★ 「系统公告」列表的下架/重新发布按钮 100% 失败

**证据链**

| 环节 | 位置 | 内容 |
|---|---|---|
| 前端 | `server/admin-web/js/pages.js:1154-1160` | `await API.put('/admin/notices/' + row.id, { enabled: !row.enabled })` —— **只发 `enabled`** |
| 后端 | `server/src/http_notice.cj:113-127` | `noticeFromBody()` 里 `n.title = requireStr(ctx, "title").trimAscii()`、`n.body = requireStr(ctx, "body")` —— **PUT 也强制要求** |
| 校验 | `server/src/http_common.cj:370-380` | `requireStr` 缺键即抛 `VALIDATION_FAILED 缺少必填字段 title` |
| 路由 | `server/src/http_notice.cj:204-230` | `PUT /api/v1/admin/notices/:id` 正是走 `noticeFromBody(ctx, existing.publishedAt)` |

**根因**：公告 PUT 是**整体替换语义**，而 `PUT /api/v1/admin/ai/models/:id` 是 **PATCH 语义**（`None` = 保留旧值）。同名前缀、两种语义，前端按 PATCH 的直觉写，于是必错。

**为什么没被发现**：编辑弹窗（`pages.js:1123-1152`）传了完整 `title`/`body`，走的是同一条 PUT 但能成功；列表行内按钮是唯一"只改一个字段"的调用点，而 `admin-web-smoke.mjs` 不做任何写操作（见 C1/C4）。

**修法**（二选一）
1. 前端最小改动：列表按钮改为先取整行（或复用 `row` 里已有的字段）再发完整对象。
2. 后端对齐 AI 模型的做法：`noticeFromBody` 增加 `bodyStrOpt` 变体，让 PUT 真正 PATCH（缺失字段保留旧值）。

> 建议选 2，把"同前缀同语义"这条口径统一掉，否则同类坑会在 KB（`http_kb.cj:199-207` 也是整体替换）上再踩一次。

### A2 ★★★ 取值型命令行参数零校验，能吞掉下一个 flag —— 并击穿 `--prod`/`--dev-auth` 互斥

`server/src/main.cj:626-651` 的解析循环里，`--port` 走严格分支（`:630-639`，非法即 `return 2`，`0` 单独拒绝），但：

```cangjie
642:        } else if (args[i] == "--bind" && i + 1 < args.size) {
643:            bindAddr = args[i + 1]
644:            i = i + 2
645:        } else if (args[i] == "--tls-cert" && i + 1 < args.size) {
...
648:        } else if (args[i] == "--tls-key" && i + 1 < args.size) {
```

三个 flag **直接吞下一个 token**，既不检查"缺值"，也不做内容校验。

**后果（已推演，可复现）**：`serve <dsn> --dev-auth --bind --prod`
→ `--prod` 被当作绑定地址，`prod` 保持 `false`（`main.cj:620`）→ `DevAuthGate(true, false)`（`:767`）**放行** → "生产不允许 `--dev-auth`"这条唯一安全闸门失去输入。之后要么因地址非法启动失败，要么真的以开发态对外，两者都不是运维在命令行里写下的意图。

**同族问题**
- `main.cj:728-731`：缺值落到 `else`，报 **「未知参数：--port」** —— 明明已知参数，缺的是值。
- **重复 flag 静默覆盖**：`serve dsn --port 8091 --port 9999` 实际监听 9999；`--tls-cert A --tls-files f.env` 互相覆盖且无提示，且覆盖优先级无文档。
- `main.cj:977-980`：`create-admin <dsn> --force` 会创建登录名为字面量 `--force` 的管理员并打印其口令；`create-admin <dsn> admin --prod` 里 `--prod` 被静默忽略（对比 `create-db` 的严格解析 `:1071-1080`）。

**修法**：取值 flag 统一加缺值分支 —— `if (i + 1 >= args.size || args[i + 1].startsWith("--")) { println("❌ --bind 缺少取值"); return 2 }`；记录已见 flag 名，重复即 `return 2`；`create-admin` 只接受一个非空登录名。

### A3 ★★ 参数合法性校验晚于建库/迁移副作用（严重）

```cangjie
749:    try {
750:        cfg = parseDsn(dsn)
752:        db = openDatabase(cfg)
753:        ensureSchema(db)          // ← 真实执行 DDL
756:        let migrated = migrateSchema(db)   // ← 真实执行 DDL
760:    } catch (e: Exception) { ... return 1 }
765:    var gate: DevAuthGate
766:    try {
767:        gate = DevAuthGate(devAuth, prod)  // ← 互斥校验在这里才发生
768:    } catch (e: Exception) { ... return 2 }
```

`--prod` 与 `--dev-auth` 的互斥（唯一安全闸门）在 `:765-771` 才判定，而 `ensureSchema` + `migrateSchema` 已在 `:753/:756` **真实跑完**。

**后果**：`serve <dsn> --prod --dev-auth`（误加或残留参数）会**先对生产库执行一遍建表与迁移**，然后才报错退出；若 DSN 也有误，则以"连接失败 exit 1"掩盖真正的拒绝原因，运维根本看不到 `拒绝启动：--prod 时不允许开启 --dev-auth`。

**修法**：把 `:741-744` 的原语自检与 `:765-771` 的互斥校验整体上移到 `:749` 之前；或先扫一遍 `argv` 做组合校验，再连库。

### A4 ★★ 三个错误码抛了但没登记 ⇒ 客户端拿到未文档化的 `code`

`server/src/http_common.cj:55-252` 的 `apiErrorSpec` 是「错误码 → (HTTP 状态, 文案)」的**唯一映射表**，未命中走 `:251` 兜底 `(500, "服务器内部错误")`；但 `:296-299` 把**原始 `e.code` 字符串原样回给客户端**：

```cangjie
298:        err.put("code", JsonString(e.code))
```

实际抛出但**未登记**的码（`server/src` 全量 grep）：

| 错误码 | 抛出点 | 应有语义 |
|---|---|---|
| `INTERNAL_ERROR` | `http_base.cj:118`（科室/医生**全部写操作**共用 `baseThrowOnFailure`）、`http_notice.cj:96` | 500 |
| `KB_WRITE_FAILED` | `http_kb.cj:137` | 500 |
| `INTERNAL` | `http_common.cj:357`、`http_app.cj:1823`、`http_p4.cj:554` | 500（与兜底同值，仅契约混乱） |

grep 确认这三个码在 `server/src` **各只出现在抛出点，没有任何测试钉住** —— 这正是它们活到今天的原因。README 第 387 行与 `http_common.cj` 内已重复 5 次的告诫（"新错误码必须同时补 `apiErrorSpec`"）被违反。

**修法**：把 `INTERNAL_ERROR`/`KB_WRITE_FAILED` 补进 `apiErrorSpec`（500），或统一改抛 `INTERNAL`。纯登记动作，零风险。

---

## 二、应修：契约 / 并发 / 一致性

### B1 ★★ `DELETE /api/v1/admin/ai/settings/:key` 缺命名空间收窄（口径分裂）

`server/src/http_app.cj:1371-1376` 的 **PUT** 有收窄：

```cangjie
1371:        if (aiSettingSpecOf(key).isNone()) {
1372:            throw apiErrorMsg("VALIDATION_FAILED", "配置项 ${key} 不在本端点的登记表里；" +
1373:                "Prompt 模板改走 PUT /api/v1/admin/ai/prompts/:name，工具开关改走 PUT /api/v1/admin/ai/tools/:name")
```

而 `:1461-1469` 的 **DELETE** 只看：

```cangjie
1465:        if (!aiSettings.remove(key, hNowEpoch())) {
1466:            throw apiErrorMsg("VALIDATION_FAILED", "未知的配置项：${key}")
```

`aiSettings.remove`（`ai_settings.cj:754-755`）只查 `aiSettingKeyKnown`，而该函数（`ai_settings.cj:200-211`）认三个命名空间：`ai.*`、`prompt.*`、`ai.tool.*`。⇒ `DELETE /api/v1/admin/ai/settings/prompt.dept` 被接受。

**定级说明**：后果仅是"该 Prompt 行回到默认值"，**不是数据洞**（删除不写值，绕不过任何校验）；但它与 PUT 的收窄自相矛盾，而 PUT 的注释（`:1354-1369`）自称该类问题已全部关闭。

### B2 ⚠ `let body = bodyObj(ctx)` 大面积死代码

`bodyBool`/`bodyStr`/`requireStr` 内部各自会调 `bodyObj`（`http_common.cj:391`），因此"先 `let body = bodyObj(ctx)` 再用 `bodyXxx` 读字段"的写法里，`body` 永远是未使用变量。共 **9 处**：`http_app.cj:1085`（sessions）、`:1158`（users）、`:1305`、`:1377`、`:1410`、`:1449`、`:1724`、`:1860`、`:2051`、`:2152`。

附带两处风格问题：`http_app.cj:1086-1088` 的 `let deviceId = match (requireStr(ctx, "device_id")) { case s => s }` 是无意义的一层 `match`；`http_app.cj:2144-2148` 的文档注释仍写"本端点受 `--dev-auth` + 管理员角色双重保护"，实际闸门早已是 bearer 令牌 + `requireCan`（注释陈旧，会误导排障）。

### B3 ★★ `AiModelRepo.update` 丢弃影响行数，删掉的行也能回 200

`server/src/ai_model.cj:629-643`：

```cangjie
629:                let _ = db.exec("UPDATE ai_model SET name = ?, ... WHERE id = ?", [...])
...
640:                invalidate()
641:                r.ok = true
642:                r.id = id
```

行数被丢进 `let _`。若该行在 `get()`（`:595`）与 UPDATE 之间被删掉，UPDATE 影响 0 行，而 `:641` 直接 `r.ok = true` ⇒ 接口回 200「改成功了」。

**这正是代码库为 `setPassword` 明确修过的同类 bug**（`auth_repo.cj:664-679` 先验存在性，注释写着"AUTH 先查存在性，否则 UPDATE 影响 0 行却回 200 —— 那是撒谎"）。同一纪律没有落到 `AiModelRepo`。

### B4 ⚠ `AiModelRepo` 完全没有 Mutex（与 `AiSettingsRepo` 的纪律不一致）

| 仓储 | 同步 |
|---|---|
| `ai_settings.cj:567` | `private let cacheLock = Mutex()`，`get`/`reload`/`invalidate`/`put` 全在 `synchronized(cacheLock)` 内，且有成文的加锁顺序（仓储锁 → 数据库连接锁） |
| `ai_model.cj` | **无任何锁**；`ensureCache(now)` 直接给共享 `cache` 赋值，`list`/`get`/`defaultOf` 迭代同一对象 |

`acceptance.cj:10-19` 明确本服务端不含 `spawn`，故**列为纪律不一致而非已证实的竞态**（真实暴露面是多进程/上游线程，未证）。

### B5 ★★ `aiModelTruncate` 按**字节**截断，会切碎中文字符

```cangjie
849: func aiModelTruncate(s: String, maxChars: Int64): String {
850:     let chars = s.toArray()          // ← UInt8 字节数组，不是字符
851:     if (chars.size <= maxChars) { return s }
...
860:     return String.fromUtf8(out.toArray()) + "…"
```

参数名 `maxChars` 是**字节数**。中文探活样本（`PROBE_SAMPLE_MAX_CHARS = 160`）会在字符中间被切开，`String.fromUtf8` 得到非法 UTF-8。

仓库对同一个坑已有三处成文证据：`http_app.cj:1735-1742`（"必须按字符截断，不能按字节截断"）、`triage_redflag.cj:186-210`（"错误做法 `for (ch in text.toArray())`"），以及现成的 `triageTruncateChars`/`previsitTruncateChars`。**修法：直接改用现成的按字符辅助函数。**
（注：同文件 `:211`/`:342-354` 的截断是**帧内比较用**的字节等价，与显示截断不同，不算缺陷。）

### B6 ⚠ 唯一键冲突没接住，会退化成 500（契约声明的是 409）

`ai_model.cj:516-526` 的 `nameTaken` 是"先查后写"，真正的唯一性由 `schema.cj:663` 的 `UNIQUE KEY uk_ai_model_name (name)` 保证。若先查后写之间被插入（或排序规则差异），INSERT/UPDATE 抛出的驱动异常**无人捕获** ⇒ 走全局兜底 `hospitalErrorHandler` ⇒ 通用 500；而 API 契约与测试声明的是 **409 `AI_MODEL_NAME_TAKEN`**。同类：`auth_repo.cj:508-541` 的 `findUser`-then-`INSERT` 竞争由 `uk_auth_user_login` 兜底，同样变成 500。

### B7 ⚠ `/admin/users` 列表过滤依赖数据不变量而非代码不变量

`auth_repo.cj:591-645`：SQL 参数化正确、`listUsers` 刻意不 SELECT `pw_salt`/`pw_hash`（**无注入、无口令枚举**，这点是对的）。但 `roleOf(非白名单 role)` 返回 `''`，只有当库里不存在 `role = ''` 的行时"`(? = '' OR role = ?)`"才等价于"不过滤" —— 依赖数据不变量。**建议显式加 `AND role <> ''`。**

### B8 ⚠ 权限动作复用导致语义漂移

AI 全套端点、`/admin/users`、`/auth/sessions` 都复用 `Action.ManageSchedule`（`http_app.cj:1157/1229/1300/1340/...`，注释 `:1479-1480` 解释了"同一页面不能有两个权限答案"的考量，可以接受）。但需登记：这条依赖"`ManageSchedule` ≡ admin-only"这一当前事实，一旦排班权限放开给护士/医生，AI 配置与用户管理会**连带失守**。建议后续补一个 `Action.ManageAi`/`Action.ManageUser` 并保留 `ManageSchedule` 仅管排班。

### B9 ⚠ `/admin/departments`、`/admin/doctors` 列表无分页

`http_base.cj:306-314`、`:394-409` 只有 `include_disabled`/`department_id`，没有 `limit`/`offset` ⇒ 前端表格无上界。已在 ADMIN-WEB.md §九 记为"≤200 行量级可接受"，此处仅登记为**规模假设**（与 Q5 未决项同源）。

---

## 三、测试体系（建议优先于功能修复处理）

### C1 ★★★ `docs/ADMIN-WEB.md:227` 承诺的判定根本没实现

`server/tests/admin-web-smoke.mjs:202`：

```js
const failed = consoleErrors.length + exceptions.length + badResponses.length + (footOk ? 0 : 1);
```

而 `booted`（`:166-171`：`loginHidden` / `navItems` / `who` / `footNote`）与逐页 `info`（`:184-192`：`activeNav` / `chars` / `head` / **`hasErrorBox`**）**只写进 JSON 报告，不参与退出码**。

**后果**：白屏（无 console error）、侧边栏少页、登录遮罩未收起、页面渲染出错误框 —— **全部 PASS**。文档却写着"任一为真即 FAIL，包括 `booted.loginHidden` 为 false、`navItems.length !== 11`"。

**修法**：把已采集的信号直接计入 `failed`，例如 `(!booted.loginHidden ? 1 : 0) + (booted.navItems !== 11 ? 1 : 0) + report.filter(p => p.hasErrorBox).length + report.filter(p => p.chars < 阈值).length`。`footOk` 那条是**正确范式**（`:172-175` 注释说明"页脚只静默少一段信息、不报控制台错误，所以必须单独断言"）—— 把同一范式推广到其余信号即可。

### C2 ★★ `health-check.ps1:69` 是恒真式断言

```powershell
69: Check "带 dev_auth 布尔（实得 $($j.dev_auth)）" ($j.dev_auth -eq $true -or $j.dev_auth -eq $false)
```

开也过、关也过 ⇒ **现有测试体系里没有任何一条断言能发现"生产实例跑在 `--dev-auth` 下"**。

与以下三点叠加即为"误开即失守、且测试永远绿灯"的完整链路：
- `http_app.cj:386-395`：`--dev-auth` 下 `X-Role: admin` 直接映射 `Role.Admin`，**无回环地址校验**（grep 确认全仓无 `remoteAddr`/loopback 判据）；
- `main.cj:845-854`：`--dev-auth` 允许 `--bind 0.0.0.0`，仅打印警告；
- `http_app.cj:929-939`：未认证的 `/health`/`/api/v1/health` **公开 `dev_auth` 字段**，恰好充当"本实例开了旁路"的扫描探针。

**修法**：断言改为按模式判定（生产必须 `dev_auth -eq $false`），期望值从参数/环境注入；另外让 `principalOf` 只在回环来源时接受 dev 头。

### C3 ★★ `common.ps1` 外部命令退出码从不检查

`server/tests/common.ps1:78-134`：`Invoke-MySqlScalar`（`:104`）与 `Invoke-MySqlFile`（`:133`）都**不查 `$LASTEXITCODE`**，只在"无行"时告警（`:118-123`）。⇒ MySQL 连不上或 SQL 报错时，调用方拿到空结果集继续跑，断言静默失效（典型的"不可能失败"的断言）。

另：`:93` 注释声称"本文件顶部设了 `$ErrorActionPreference`"，**实际文件里没有该赋值** —— 它依赖调用方 dot-source 前自行设置。

**修法**：两个函数内 `if ($LASTEXITCODE -ne 0) { throw ... }`；文件头显式 `$ErrorActionPreference = 'Stop'`。

### C4 ★★ smoke 脚本覆盖面缺口 + 稳定性（这是 A1 漏过去的直接原因）

**完全未覆盖**：任何**写操作**（建/改/删排班、启停科室与医生、知识库写入、公告发布/下架）、模态框（打开/取消/确认删除）、表单校验路径（必填/越界/错误提示）、分页与筛选、登出与 401 跳转、角色差异。

**非确定性**：固定 `PAGE_WAIT_MS = 900`（`:41`）与固定 `sleep`，**不等 `Page.loadEventFired`/网络空闲** ⇒ 慢机随机失败；调试端口写死 `9333`（`:40`）、Edge 路径写死（`:39`）⇒ 无法并行、无法换浏览器。

---

## 四、运维脚本

### D1 ★★ `setup-runtime.ps1:23` —— 空环境变量导致整个运行时复制被跳过

```powershell
13: $ErrorActionPreference = "Stop"
...
23:        (Join-Path $env:CANGJIE_HOME "runtime\lib\windows_x86_64_cjnative\libcangjie-runtime.dll")
```

`Join-Path` 写在**数组字面量里**，在任何分支判断之前就被求值，而文件头是 `$ErrorActionPreference = "Stop"`。`CANGJIE_HOME` 未设置时抛 `ParameterBindingValidationException: 无法将参数绑定到参数 'Path'，因为该参数是空值。`，`:48` 的 `IsNullOrEmpty` 守卫**根本没机会执行** ⇒ `libcrypto-3-x64.dll`/`libssl-3-x64.dll`/`libboundscheck.dll` 一个都不会被复制。

**后果**：干净机器按 README 走完 setup，exe 起不来（缺 DLL），而报错文本与"缺 DLL"毫无关系。

**修法**：把 `Join-Path` 移入 `if (-not [string]::IsNullOrEmpty($env:CANGJIE_HOME)) { ... }` 内求值，或改用字符串拼接。

### D2 ⚠ 硬编码绝对路径，换机即废

`setup-runtime.ps1:21-35`（`D:\Cangjie`、`C:\Cangjie`、`E:\cangjie\qingzhou\build\libcrypto-3-x64.dll`）、`devdb.ps1:37` 与 `common.ps1:53`（`E:\cangjie\mariadb\mariadb-11.4.13-winx64`）、`admin-web-smoke.mjs:39`（Edge 路径）。

失败时静默退化（`:52-58` 的兜底递归搜索带 `-ErrorAction SilentlyContinue`），只在最后统计数量后 `exit 1`，**不打印"我找过哪些路径"**。**修法**：统一参数/环境变量入口；缺失时列出搜索路径。

### D3 ⚠ `devdb.ps1` 明文口令 + 状态分支忽略参数 + 吞 stderr

- `:22` `-RootPassword "devroot2026"` 明文入库；
- `:119` `Invoke-Status` 写死 `-phospital_dev_2026`（**忽略 `$RootPassword` 与任何参数**）并 `2>$null` 吞掉 MySQL 错误 ⇒ 口令不符时"状态"显示空白而非报错，与 init/start 行为不一致；
- `:91` 打印的 DSN **含明文口令**，便于复制的同时也进入终端历史/工单/聊天记录。

### D4 ⚠ `new-tls-cert.ps1:299-321` ACL 失败只警告不中止

`icacls` 退出码有检查，但失败仅置 `$aclOk` 警告并继续 ⇒ 私钥目录 ACL 未收紧也会继续复制到 `%ProgramData%`（风险放大）。

### D5 ⚠ `create-admin` 把管理员口令打到 stdout

`main.cj:1040-1045`：

```cangjie
1042:    println("  口  令：${pw}")
1045:    println("⚠ 口令只显示这一次（未落盘）；请立即用 POST /api/v1/auth/login 换令牌。")
```

"只显示一次"的设计意图是对的，但 `> deploy.log 2>&1`、CI 日志、终端 scrollback、TTY 录制都会把明文口令落盘 —— 与 `:1045` 自己"未落盘"的承诺矛盾。**修法**：改写 stderr 并提示"请勿重定向到文件"，或加 `--quiet`；README 明确禁止重定向该命令输出。

### D6 ⚠ 管理台目录探测与 404 形状

- `main.cj:183-193` `pickAdminWebDir` 用 `exists` 判"任意文件系统条目"（`:179-181` 注释写的是"目录存在"）⇒ CWD 下同名**文件**也会被认为"管理台已找到"，`:855-860` 不告警，`/admin/*` 全 404，而启动日志说"已挂载"。候选路径相对**进程 CWD**。
- `main.cj:855-860` 找不到目录只 `println("⚠ …")`，**不影响退出码**；`http_app.cj:2397` 只在 `adminWebDir.size > 0` 时挂载，于是 `/admin` 落到框架兜底，返回 `{"error":"Not Found","path":"/admin"}` —— **不是本项目统一的 `{"ok":false,"error":{code,message}}` 信封**。
- 佐证：`ROUTE_NOT_FOUND` 在 `server/src` **只在 `http_common.cj:129` 的登记表出现，全仓无任何构造点** —— 已登记但从未使用（死码），框架级 404 没有复用本项目信封。

**修法**：探测判据换成"存在且为目录"并打印解析后的绝对路径；缺失时按 `--prod` 直接失败退出（否则至少 `exit 1`）；框架级 404 复用 `ROUTE_NOT_FOUND`。

> ⚠ 2026-10-17 更新：框架层三种平铺错误体（非法 JSON 400 / 静态 404 / 405）已统一为项目信封；见 contract/CHANGELOG.md 与 docs/FRONTEND-INTEGRATION.md §3.2。（本节 D6 记录的"框架兜底 404 是平铺体"同样已作废：`ROUTE_NOT_FOUND` 现在既覆盖 API 未命中，也覆盖静态未命中。）

### D7 ⚠ CLI 退出码与 usage 不一致

- `main.cj:1127-1130`：无参数 `usage(); return 0`，而 `badcmd`/`--help` 都是 `return 2` ⇒ CI 用 `$LASTEXITCODE` 判"是否成功运行"时，无参调用被判成功。
- `main.cj:1181-1184`：`--help`/`-h` 打印 **「未知子命令：--help」** 并 `return 2`（约定俗成应为 0）。
- usage（`main.cj:33-64`）**未登记**已实现的 `triagetest`（`:1145-1148`）与 `--tls-files`（`:651-721`）⇒ 只能靠 README 发现。
- `main.cj:977-980`：`create-admin` 对多余参数静默丢弃（同 A2）。

---

## 五、需澄清 / 低风险（8 项）

| # | 位置 | 内容 |
|---|---|---|
| E1 | `main.cj:977-980` + `auth_repo.cj:131-139/508-541` | `create-admin` 允许空登录名；`normalizeLoginName` 后 `createUser` 是否拒绝空名/超长名**未确认** ⇒ 未确认能否建出"空登录名管理员行"（该行随后无法登录） |
| E2 | `http_common.cj:343-360` | 兜底 handler 的 `case None => ()` 吞掉"有异常但未写响应"的状态 ⇒ 若中间件消费异常却不写响应，客户端得到空 200/挂起而非 500（需具体路径才触发） |
| E3 | `main.cj:894-900` | `wantTls` 把 `tlsFilesGiven` 也算作"要求 TLS"，缺证书/私钥即拒绝启动、不回退明文 —— **行为正确**；但 `--tls-files` 指向的 env 文件权限过宽即泄露私钥**路径** |
| E4 | `README:151` | 未记录 `X-Doctor-Id`（`http_app.cj:400-403` 实际会读取），与 A2/A3 同源 |
| E5 | `main.cj:1040-1045` | 见 D5（口令落盘），已列运维项 |
| E6 | `http_app.cj:915-961` | `/health` 恒 200 且不鉴权（有意设计，供探活）；仅需注意 `dev_auth` 字段的探针价值（见 C2） |
| E7 | `third_party/qingzhou/src/static.cj:195-203` + `http_app.cj:2402` | `enableCache=false` ⇒ 每次静态请求都读盘。与 `spaFallback=false`、前缀 `/admin` 一致，是 ADMIN-WEB.md 的有意选择；仅大量并发静态资源时有系统调用开销 |
| E8 | `http_common.cj:355` | 驱动异常 `e.message` 打到 stdout，是否夹带 SQL 文本未逐一验证；常规写路径均为参数化且传哈希，判为低风险 |

---

## 六、已核对**无问题**（正面结论，避免重复排查）

**机密与鉴权**
- 密钥不落库、不回显：`ai_model.cj:737-779` 只回 `key_ref_set`/`key_ref_kind`/`key_source`；`ai_settings` 的 secret 项只回"是否已设 + 引用种类"；`AiModelProbe` 的 `reason` 经 `aiRedact`。
- `main.cj:459-464` 有**硬断言** `dflt.describe() == "hospital@127.0.0.1:3306/hospital"` ⇒ `MySqlConfig.describe()` 不含口令；`check-db`（`:80`）、`accept`（`:195-222`）、`create-db`（`:1120`）只打印库名/账号。
- 访问日志不含机密：`third_party/qingzhou/src/logger.cj:37` 只记 `method + path`（不含 query/body/header）。
- 全局兜底不外泄：`http_common.cj:355-357` 只把 `e.message` 打 stdout，响应体固定 `ApiError("INTERNAL", 500, "服务器内部错误", None)`，堆栈从不进响应。
- `auth_repo.cj` 口令策略（≥8 位且含字母+数字、弱口令表、不得等于/包含登录名，**刻意不强制特殊字符**，符合 NIST）与**令牌吊销顺序**（先验强度再吊销 —— 注释说明"否则持有管理令牌者可发一个弱口令请求把用户踢下线"）—— 正确。
- `listUsers` 参数化且**不 SELECT `pw_salt`/`pw_hash`** —— 无注入、无口令枚举。
- `--dev-auth` **默认关闭**（`main.cj:619 var devAuth = false`），全仓只有两处构造 `DevAuthGate`：`main.cj:767`（serve，由 `--prod` 互斥保护）与 `acceptance.cj:756`（写死 `false,false`）⇒ **不存在"默认开启"路径**（风险在 A2 的击穿与 C2 的恒真断言）。

**运维页面 / 静态挂载**
- 静态页面本身不鉴权是**有意设计**（页面内无数据），`/api/v1/admin/**` 每请求校验令牌 + 角色；`index.html` 用**绝对路径**引资源，`:29-34` 注释解释了原因（`/admin` 不带斜杠也返回 index.html）。
- 前缀守卫正确：`static.cj:138-161` 要求余部以 `/` 开头或为空 ⇒ **`/administrator` 不会误命中 `/admin`**；`/admin` 与 `/admin/` 都能拿到 index.html。
- 静态中间件注册在 `router.middleware()` **之前**（`http_app.cj:2396-2405`）—— 顺序正确。
- `spaFallback=false` + 前缀无尾斜杠 `/admin` —— 正是 README 记录的坑，实现符合。

**业务正确性（重点抽查）**
- 排班 `PUT` 的乐观锁与"放号数 ≥ 已约数"不变量：`domain_booking.cj:664-730` 单条原子 SQL，且 `remain_num` **必须写在 `total_num` 之前**（MySQL SET 左到右求值，反了会让余量静默不变、已约数虚增）—— 注释讲得很清楚，**实现正确**；0 行时按 `不存在 → 版本冲突 → 数太小` 顺序分类（`:706-728`）。
- `POST /api/v1/triage`：患者专属（`Action.Book`），`chief_complaint` 按**字符**截断（`triageTruncateChars`），AI 增强**从不改 `v.options`**，`triageStat.record` 异常被吞（有意）。
- `POST /admin/ai/models/:id/test`：从**库里**读行（不信请求体）、永远 200、`reason` 经 `aiRedact`、**刻意绕过 `ai.enabled`** —— 注释说明"诊断动作，先上线再验证的顺序不能反"，设计合理。
- 看板 `dashboard.cj:116-368`：每个指标独立 catch 包裹 ⇒ 缺表渲染成 0 而不是整页 500，代价（真实故障显示为 0）由各块 `source` 字段缓解；`scale.source` 的措辞与 ADR-0001 rev.7 一致（Store 已移除）。
- `HOSPITAL_PAGES` 与实际挂载的 ADMIN-WEB.md 声明一致：11 个页面 ↔ 对应端点全部存在；3 个未实现页面（患者档案 / 症状标签库 / Agent 执行观测）在侧边栏**显式标灰并给出理由**，不是静默缺失。

**脚本**
- 21 个 `.ps1` **全部带 UTF-8 BOM**（含中文注释的文件不会 mojibake）。
- `build.ps1:161` `if ($LASTEXITCODE -ne 0) { throw "编译失败" }` **有**检查；`build-mysql-driver.ps1:107` 每步检查。
- `new-tls-cert.ps1` 显式规避 PS 5.1 缺失的 `ExportPkcs8PrivateKeyPem`（`:136-196` 手拼 PKCS#1/PEM），并对 SAN 做硬断言（含 `127.0.0.1`、`localhost`，`:258-269`）。
- `--port` 严格性已达标：`parseUInt16OrNone`（`third_party/qingzhou/src/util.cj:36-42`）靠 stdlib `UInt16.parse` 的整串语义，`abc`/`8080abc`/`-1`/`65536` 均被拒（缺值与重复见 A2）。

---

## 七、建议修复顺序

按"每单位成本能挡掉的故障"排序；前三条改动都很小，且可用现有脚本直接回归。

| 顺序 | 项 | 理由 | 验证方式 |
|---|---|---|---|
| 1 | **A1** 公告按钮（前端一行，或后端改 PATCH） | 用户直接看得见的功能坏 | 手工点一次列表行按钮；补 C4 的写操作用例 |
| 2 | **C1** smoke 判定计入已采集信号 | 它是 A1 能瞒过 CI 的原因；不改则后续修完仍无保护 | 故意改坏一页，确认脚本变红 |
| 3 | **A4** 登记三个错误码 | 纯登记，零风险 | `tests/*.ps1` 全跑 |
| 4 | **A2 + A3** 参数校验前置 + 取值 flag 缺值检查 | 安全闸门恢复有效 | `serve <dsn> --dev-auth --bind --prod` 必须拒绝且不碰库 |
| 5 | **B1 / B2 / B3 / B7** 口径与死代码收敛；**B5** 换按字符截断 | 一致性，防止同类坑复发 | `build.ps1` + `accept` + `ai-model-check.ps1` |
| 6 | **C2** `dev_auth` 断言改按模式 + dev 头限回环 | 让"生产误开 dev-auth"能被发现 | `health-check.ps1` 在 `--dev-auth` 实例上必须红 |
| 7 | **D1** `setup-runtime.ps1` 一行 | 干净机器部署 | 清空 `CANGJIE_HOME` 后跑一遍 |
| 8 | **C3 / C4** 测试基建（退出码检查 + 写操作覆盖） | 后续所有改动的护栏 | 自检 |
| 9 | **B4 / B6** `AiModelRepo` 补锁 + 唯一键异常映射 409 | 低概率契约缺口 | 并发/重复名用例 |

---

## 附：本次检查覆盖的文件

**服务端源码**：`main.cj`、`http_app.cj`、`http_common.cj`、`http_base.cj`、`http_kb.cj`、`http_notice.cj`、`http_p4.cj`、`ai_model.cj`、`ai_settings.cj`、`ai_prompt.cj`、`ai_call.cj`、`auth_repo.cj`、`auth_crypto.cj`、`dashboard.cj`、`domain_booking.cj`、`domain_base.cj`、`domain_emr.cj`、`domain_kb.cj`、`domain_notice.cj`、`kb_repo.cj`、`schema.cj`、`db_bootstrap.cj`、`triage.cj`、`triage_redflag.cj`、`previsit.cj`、`acceptance*.cj`

**管理台前端**：`index.html`、`css/style.css`、`js/api.js`、`js/ui.js`、`js/pages.js`、`js/app.js`、`favicon.svg`

**脚本与测试**：`build.ps1`、`build-mysql-driver.ps1`、`devdb.ps1`、`setup-runtime.ps1`、`new-tls-cert.ps1`、`tests/`（21 个）

**文档**：`README.md`、`server/README.md`、`docs/ADMIN-WEB.md`、`docs/FRONTEND-INTEGRATION.md`、`docs/DEV-DB.md`、`docs/P0-P5-HANDOFF.md`、`docs/adr/ADR-0001-*.md`、`smart-hospital-project-brief.md`、`server/third_party/qingzhou/src/{static,logger,util}.cj`（旁证）
