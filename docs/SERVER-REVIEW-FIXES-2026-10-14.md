# 服务端检查报告修复记录（2026-10-14）

> 对应报告：[`docs/SERVER-REVIEW-2026-10-14.md`](SERVER-REVIEW-2026-10-14.md)（30 项：必修 A1-A4、应修 B1-B9、测试 C1-C4、运维 D1-D7、低风险 E1-E8）。
> 本文件记录**每一项的修法、验证证据**，以及**有意不改的项与理由**。
> 状态：**A/B/C/D 全部关闭，E 类逐项裁定**（E1/E2/E4/E5 已修，E3/E6/E7/E8 核对后判定无需改动）。

## 一、验证证据总览（改动后的收官验证）

| 层 | 命令 | 结果 |
|---|---|---|
| 编译 | `server\build.ps1` | ✅ 框架 38 + 业务 37 = SOURCE-MANIFEST 75 文件 |
| 进程内套件 | `hospital-server.exe selftest / authtest / triagetest / accept <dsn>` | ✅ selftest 50、authtest、triagetest 110、accept 550，失败 0 |
| CLI 门禁 | 18 组参数组合（含死 DSN 反证） | ✅ 全部符合预期（见 §3.2） |
| HTTP 门禁 | `server\tests\final-verify.ps1`（18092 dev-auth / 18095 无 dev-auth / 18096 --prod） | ✅ 11 项全绿（health-check ×2 + base/auth/kb/triage/emr/previsit/ai-model/rate-limit/p1-extra） |
| 浏览器冒烟 | `node server\tests\admin-web-smoke.mjs` | ✅ `ok=true`、`SMOKE-EXIT=0`，boot/page/modal/write/logout 五类判定全 0 |
| 文档计数 | `server\tests\doc-counts.ps1` | ✅ 与实际一致（selftest 50 / triagetest 110 / accept 550 / REST 71 / AC-17） |

## 二、必修（A1-A4）

### A1 「系统公告」下架/重新发布 100% 失败
- **根因**：`server/admin-web/js/pages.js` 行内按钮只发 `{enabled:…}`，而 `server/src/http_notice.cj` 的 PUT 强制 `title`/`body`（整体替换）⇒ 必然 400。
- **修法（采纳报告建议的"后端对齐 AI 模型的 PATCH 语义"）**：
  - `server/src/http_notice.cj`：`noticeFromBody(ctx, defaultPublishedAt, existing!: ?Notice = None)`。`None`（POST）仍强制 `title`/`body`；`Some(old)`（PUT）缺失字段**保留旧值**（含 `published_at`）。PUT 分支传 `existing: Some(existing)`。
  - 同族一并对齐：`server/src/http_kb.cj` 的 PUT 也改为 **PATCH 语义**（缺失字段保留旧值；`body` 变化才重切块；`body:""` → 400 `VALIDATION_FAILED`「正文不能为空」）。
  - `server/admin-web/js/pages.js`：KB 编辑弹窗提示文案同步改为"只改想改的字段"。
- **验证**：HTTP 实测 —— 公告 `PUT {enabled:false}` 后 `title`/`body` 原样保留；`PUT {title:…}` 只改标题且 `enabled` 保持 false。KB：只改 enabled/标题**不重切块**（`chunk_count` 不变），换正文才重切块。
- **回归闸门**：写路径用例加在 `server\tests\admin-web-smoke.mjs`（见 C4）。**不**加进程内 AC：全仓不存在可构造的 `Context` 夹具（`grep 'Context()'` 无命中），而报告 C4 已指出 A1 漏检的原因正是"冒烟只读不写"。

### A2 取值型命令行参数零校验，能吞掉下一个 flag
- **修法**（`server/src/main.cj`）：
  - 新增 `func flagValueAt(args: Array<String>, i: Int64, flag: String): ?String`：取值缺失、或**下一个 token 以 `--` 开头** ⇒ 打印 `❌ <flag> 缺少取值` 并 `return 2`（不再把 `--prod` 当成 `--bind` 的值）。
  - `serve` 解析循环引入 `var seenFlags = HashSet<String>()`：**重复 flag 直接退 2**（原来是静默覆盖）。
  - `--bind` / `--tls-cert` / `--tls-key` / `--tls-files` 全部走 `flagValueAt`；`--port` 维持严格 `parseUInt16OrNone`。
  - `create-admin`：`args.size > 2` ⇒ 「参数过多」退 2；登录名 trim 后为空或以 `--` 开头 ⇒ 退 2（原是 E1：能建出登录名为 `--force` 的管理员）。
- **验证**：见 §3.2 的 CLI 矩阵；`serve <dsn> --dev-auth --bind --prod` 被**拒绝且未连库**（死 DSN 反证）。

### A3 参数合法性校验晚于建库/迁移副作用
- **修法**：`DevAuthGate(devAuth, prod)`（`--prod`/`--dev-auth` 互斥校验）的构造**上移到 `authSelfTest` 之后、`var db: DbBackend` 之前**（`server/src/main.cj`）。
- **验证**：`serve <死DSN> --prod --dev-auth` → 立刻拒绝，**不做任何 DDL**；DB 侧无痕。

### A4 三个错误码抛了但没登记
- **修法**：`server/src/http_common.cj` 的 `apiErrorSpec` 补登记 `INTERNAL_ERROR`(500)、`KB_WRITE_FAILED`(500「知识库写入失败」)、`INTERNAL`(500)。原兜底虽也是 500，但客户端会拿到**未文档化**的 `code`。
- **验证**：`accept` 550 项全过 + `base-check`/`kb-check` 全绿。

## 三、应修（B1-B9）

| 项 | 修法 | 验证 |
|---|---|---|
| **B1** | `server/src/http_app.cj` 的 `DELETE /api/v1/admin/ai/settings/:key`：先 `aiSettingSpecOf(key).isNone()` ⇒ 400 `VALIDATION_FAILED`，消息指向 `DELETE /api/v1/admin/ai/prompts/:name` 与 `PUT /api/v1/admin/ai/tools/:name` | HTTP：`DELETE …/settings/model_kind` → 400 且消息含正确改道；`…/prompts/triage_system` → 400「未知的 Prompt」 |
| **B2** | 删除 10 处死代码 `let body = bodyObj(ctx)`（9 处整行删除，`/api/v1/auth/sessions/revoke` 处连同无意义的 `match` 一起改成 `let deviceId = requireStr(ctx, "device_id")`）；更正建排班处"本端点受 --dev-auth + 管理员角色双重保护"陈旧注释 | 编译通过 + `auth-check` 全绿 |
| **B3** | `server/src/ai_model.cj` 的 `update`：接住 `db.exec` 的影响行数，`affected <= 0` ⇒ `r.notFound = true` | HTTP：`PUT /admin/ai/models/999999 {enabled:false}` → **404 `AI_MODEL_NOT_FOUND`**（不再静默 200） |
| **B4** | `ai_model.cj` 增加 `private let cacheLock = Mutex()`，`ensureCache`/`invalidate`/`list`/`get`/`defaultOf` 全部 `synchronized(cacheLock)`；锁序与 `AiSettingsRepo` 一致（仓储锁 → 数据库连接锁，可重入） | 编译 + `ai-model-check.ps1` 全绿 |
| **B5** | `aiModelTruncate` 改为按 **Rune** 计数与收集（原 `s.toArray()` 是字节，会切碎中文），超出部分以 `…` 收尾 | 编译 + `ai-model-check.ps1` |
| **B6** | `create`/`update` 的 `execInsert`/`exec` 包 try/catch：异常时**只有** `nameTaken(...)` 为真才置 `r.duplicate = true`（映射 409），否则 `throw e`（不吞真有故障） | `ai-model-check.ps1` 重复名用例 |
| **B7** | `server/src/auth_repo.cj` 的 `listUsers`/`countUsers`：`WHERE role <> '' AND (? = '' OR role = ?) AND (? = '' OR status = ?)`（把"数据不变量"变成"代码不变量"，仍全参数化） | `base-check`/`auth-check` 全绿 |
| **B8** | 判定为**可接受的边界**：`Action.ManageSchedule` 复用使 admin-only 语义漂移。登记到 `docs/ADMIN-WEB.md` §九「已知边界」第 5 条，建议后续补 `Action.ManageAi`/`Action.ManageUser` | 文档登记（不改代码） |
| **B9** | 判定为**规模假设**：`/admin/departments`、`/admin/doctors` 无分页。登记到 `docs/ADMIN-WEB.md` §九 第 6 条（假设 ≤200 行） | 文档登记（不改代码） |

## 四、测试体系（C1-C4）

### C1 冒烟脚本采集了信号却不计入判定
- **修法**（`server\tests\admin-web-smoke.mjs`）：
  - `bootFailures`：登录遮罩未收起 / `navItems < 11` / `whoami` 为空 / 页脚出现「读取失败」。
  - `pageFailures`：逐页 `hasErrorBox`、正文 `chars < --min-chars`(40)、侧栏无 `.nav-item.active`。
  - `failed = consoleErrors + exceptions + badResponses + bootFailures + pageFailures + modalFailures + writeFailures + logoutFailures`。
  - 断言用 `< 11`（实测侧栏 14 项 = 11 实现页 + 3 个**置灰**未实现页）；`docs/ADMIN-WEB.md` 的口径同步改正。
- **验证**：`SMOKE-EXIT=0`、`ok=true`，8 类计数全 0。

### C2 `health-check.ps1` 恒真断言 + dev 头不限来源
- **修法**：
  - `server\tests\health-check.ps1`：新增 `-Mode any|dev|prod`；`dev_auth` 按模式断言；新增第 [5] 节「开发态身份头旁路探针」（带 `X-Role: admin` 打 `/api/v1/admin/ai/models`）。
  - `server/src/http_app.cj`：`principalOf` 里开发态身份头（`X-Role`/`X-Patient-Id`/`X-Doctor-Id`）**只允许回环来源**；新增 `isLoopbackIp(ip)`（接受 `127.x`、`::1`、`[::1]`、`::ffff:127.`）；非回环 ⇒ 401 并给出"请走 `Authorization: Bearer <token>`"的中文提示；拿不到来源 IP 时打印告警并按本机处理。
  - `server/src/main.cj` 的 banner/usage 同步说明该限制。
- **验证**：三形态实测全绿 —— dev+回环（`X-Role` 探针 200）、dev+非回环 172.29.64.1（401 + 提示）、prod（401）。**这正是"生产误开 dev-auth"能被发现**的闸门。

### C3 `common.ps1` 外部命令退出码从不检查
- **修法**（`server\tests\common.ps1`，134 → 353 行）：
  - 文件头显式 `$ErrorActionPreference = 'Stop'`。
  - `Invoke-MySqlScalar`：捕获 `$LASTEXITCODE`，非 0 **或** 输出里出现 `^\s*ERROR\s+\d{3,5}\b` 即抛（`mariadb -e "source bad.sql"` 在语句失败时**退出码仍是 0**，所以必须看输出，新增 `Get-HospMysqlServerErrors`）；`try/finally` 里恢复 EAP。
  - 新增 `Invoke-MySqlFile`；`Resolve-HospPath` / `Join-HospPathSafe` 统一路径解析（`HOSP_*` 环境变量优先）。
- **验证**：函数级用例（坏 SQL 抛、坏 .sql 文件抛、空 SELECT 告警、缺库名 DSN 抛）+ `base-check` 全绿。
- **同类隐患顺手清掉**（原列在第八节遗留第 3 条）：`server\tests\previsit-check.ps1:384-385` 曾两处直接 `& $My.Client … -e "…" 2>$null` —— 既吞掉驱动/连接错误（查询失败会静默变成空串，断言恒假），又不看 `$LASTEXITCODE`。现改为一次 `Invoke-MySqlScalar -Label "ai.garbage 行数"` 取 `$garbageRows`，供消息与断言共用；改后全仓 `server\tests\*.ps1` 再无活的 `2>$null`（仅注释里提到）。实跑 `previsit-check.ps1` **PASS 86 / FAIL 0 / exit 0**（含 `[PASS] ★ 且确实没进库（0 行）`）。

### C4 冒烟覆盖面 + 稳定性（A1 漏检的直接原因）
- **修法**：`admin-web-smoke.mjs` 重写（216 → ~330 行）
  - 稳定性：等待改为「`#content` 非空 → CDP 网络空闲（`lastNetActivity`，`--net-idle` 默认 600ms）→ `--wait` 静置 300ms」；调试端口默认**随机** 9200-9899（`--port` 可覆盖）；Edge 路径改为**探测**（`EDGE_PATH` → Program Files (x86) → Program Files → LOCALAPPDATA）。
  - 覆盖面：新增 ③模态框（打开/必填校验红字/取消关闭）与 ④**写路径 15 条**（公告新建·下架·重新发布·删除、缺 title 400、KB 新建切块·只改 enabled·只改标题不重切块·空正文 400·换正文重切块·删除、未带令牌 401、未注册路径 404 信封、B1 收窄、B3 404）+ 登出（清 localStorage → reload → 登录视图可见）。
  - 抑制手法：故意打的 4xx 会污染门禁 ⇒ `expectFailure(fn)` 在进入时 `expectedFailureUntil = +Infinity`、退出后 `Date.now()+900` 并 `sleep(950)`（CDP 事件异步），`suppressEvidence()` 同时挡 `Network.responseReceived`、`Runtime.consoleAPICalled`、`Log.entryAdded`。
- **验证**：`SMOKE-EXIT=0`，报告 JSON 落 `%TEMP%\smoke-run2.json`，截图 `%TEMP%\admin-shots`。

## 五、运维脚本（D1-D7）

| 项 | 修法 | 验证 |
|---|---|---|
| **D1** | `server/setup-runtime.ps1`：把 `Join-Path $env:CANGJIE_HOME …` 移入 `IsNullOrEmpty` 守卫内（原来写在数组字面量里，空变量时抛 `ParameterBindingValidationException` ⇒ 运行时 DLL **一个都不复制**） | 子代理复现修复（清空 `CANGJIE_HOME` 后候选回退仍复制成功） |
| **D2** | 同文件：硬编码 `D:\Cangjie` 改为候选列表 + `HOSP_*` 环境变量覆盖，失败时**打印搜过的全部路径**；保留 `D:\Cangjie` 优先于 `$env:CANGJIE_HOME`（理由：build 用的 `libcangjie-runtime.dll` 哈希等于 `D:\Cangjie` 1.1.3 那份，而 `CANGJIE_HOME` 指向 1.2.0） | 解析器测试 + 实跑 |
| **D3** | `server/devdb.ps1`：去掉硬编码口令（先 `AppUser` 再回退 `root`）；状态分支不再写死口令、不再 `2>$null` 吞错；新增 `Invoke-DevDbQuery`；DSN 默认**打码**（`-ShowPassword` 才显明文） | `status` 实跑（PID/端口 3317 监听、库列表正常）；`-AppPassword` 错值 → 回退 root 并告警；打码输出核对 |
| **D4** | `server/new-tls-cert.ps1`：ACL 设置失败由"只警告"改为**抛错中止**（带命令、退出码、输出） | `icacls` 打桩失败用例：抛错且**不残留私钥副本** |
| **D5** | `server/src/main.cj` 的 `createAdmin`：口令改 `eprintln`（stderr），并新增"⚠ 口令写在 stderr 上：不要用 `2>&1` 重定向"提示 | CLI 矩阵 + `p1-extra-check.ps1` 从 stderr 读到口令并验其可登录 |
| **D6** | ① `server/src/main.cj` 新增 `isDirectoryPath(path)`（`FileInfo(path).isDirectory()`，异常⇒false）与 `printAdminWebMissingHint()`（打印三个候选 + `canonicalize(...)` 绝对路径 + CWD）；`pickAdminWebDir()` 改用它（原用 `exists` 判"任意条目"）。② `--prod` 下找不到管理台目录 ⇒ **拒绝启动**（原静默 404）。③ 404 信封：`buildHospitalApp` 里 `router.passOnNotFound = true`，并在 `router.middleware()` **之后**追加中间件输出 `ROUTE_NOT_FOUND` 信封 | HTTP：`GET /api/v1/definitely-not-here` 与 `GET /no-such-static-file-xyz` 均 `404 {"ok":false,"error":{"code":"ROUTE_NOT_FOUND",…}}`；banner 提示路径核对。**边界**：`/admin` 下静态文件未命中仍由 vendored 静态层写 `{"error":"Not Found"}`，不为此外 fork 框架（已记入 `docs/ADMIN-WEB.md`） |
| **D7** | `server/src/main.cj`：无参 ⇒ usage + 退 **2**；`--help`/`-h`/`help` ⇒ usage + 退 **0**；usage 补 `triagetest`、`--tls-files`、`--help`，accept 说明改为"AC-1…AC-17，且只允许库名含 test 的库" | CLI 矩阵核对退出码与 usage 文本 |

## 六、低风险 / 需澄清（E1-E8）

| 项 | 裁定 |
|---|---|
| **E1** | **已修**：`create-admin` 拒绝空/纯空白登录名、以 `--` 开头的登录名、以及多余参数（见 A2）。 |
| **E2** | **已修**：`server/src/http_common.cj` 兜底 `case None => ()` 改为判定 `ctx._committed || ctx._peekBody().size > 0`；若"异常被消费且未写响应"则打印 `[ERROR] … 兜底回 500` 并写 `ApiError("INTERNAL", 500, "服务器内部错误")`。判据含 body 非空，因为只看 `_committed` 会把"已写 body 未 commit"的响应写第二遍。 |
| **E3** | **不改**：`wantTls` 把 `--tls-files` 也算作要求 TLS、缺证书即拒绝启动——**行为正确**（安全默认）。`tls.env` 权限属部署纪律，已在 `docs/ADMIN-WEB.md` 提醒。 |
| **E4** | **已修**：`server/README.md` 补 `X-Doctor-Id`，并新增警告段——开发态头**仅本机回环**生效，非回环即使带 `--dev-auth` 也 401（附理由与 `health-check.ps1 -Mode dev\|prod` 门禁说明）。 |
| **E5** | = D5，**已修**。 |
| **E6** | **不改**：`/health` 恒 200 且不鉴权是探活设计；报告担心的"`dev_auth` 字段被滥用作探针"已由 C2 的按模式断言覆盖。 |
| **E7** | **不改**：静态 `enableCache=false` + `spaFallback=false` + 前缀 `/admin` 是 `docs/ADMIN-WEB.md` 的**有意选择**（开发期改文件即生效）；仅在高并发静态资源下有系统调用开销。 |
| **E8** | **不改**：驱动异常 `e.message` 只打 stdout、响应体固定 `服务器内部错误`、堆栈从不进响应；常规写路径全参数化。判定为低风险。 |

## 七、修复过程中额外发现并一并处理的问题

1. **三个 live 脚本夹具不幂等**（报告未列，是修复后复跑才暴露的）：
   - `server\tests\kb-check.ps1`：夹具改为"先清 `kbchkdoc`/`kbchkpat` 账号与 doctor 900103 / patient 960001 / department 900103，再幂等自建"，登录账号的 `ref_id` 指向**确实存在**的医生行。**根因**：`auth_repo.cj` 的 `authReferenceExists(role, refId)` 在校验口令**之后**还要求绑定档案存在，而它一律返回 `AUTH_BAD_CREDENTIALS`（防枚举）⇒ 夹具残留导致"口令对却 401"。
   - `server\tests\triage-check.ps1`：去掉撞 `department.name` 唯一键的重复科室 9212（呼吸内科），schedule 9212 改为挂在 9201 上的 9202。
   - `server\tests\p1-extra-check.ps1`：补科室 7/8、医生 7/8 的幂等夹具；create-admin 断言改为**快速失败**（原来是嵌套 `try`+`$_` 白名单，`$ErrorActionPreference='Stop'` 下失效后每轮白跑）；口令改从 stderr 读。
   - **另一处坑**：`create-admin 2>&1 | Out-String` 会把同一条 stderr 变成**两行**（ErrorRecord 消息行 + `+ CategoryInfo …` 复述行），逐行 `Select-String` 会一次塞进 2 个值、且**最后一个**是残渣（`XXX:String) [], RemoteException`）⇒ 必须用 `[regex]::Matches($o,'口\s*令：\s*([A-Za-z0-9]+)')` 取**首个**匹配。
2. **`edit`/`write` 工具落盘会丢 UTF-8 BOM**：含中文的 `.ps1` 在 PS 5.1 下会按 ANSI 解析而报「意外的标记」。本次统一复查：21 个 `.ps1` 全部补回 BOM（`[System.IO.File]::WriteAllText($p,$t,(New-Object System.Text.UTF8Encoding($true)))`），并在改动过的脚本头部保留这条提醒。
3. **本机 1024-15000 是 Windows 动态端口范围**：显式 bind 会 `WSAEACCES(10013)`。所有脚本/文档示例端口改为 ≥15001，并在 `docs/ADMIN-WEB.md` 与 `server/README.md` 标注该坑。
4. **`final-verify.ps1`（新增）**：一次起三个实例（18092 dev-auth / 18095 裸 / 18096 `--prod`）跑完 11 项 HTTP 门禁并输出 EXIT 汇总表，作为本次与后续复查的一键回归。

## 八、遗留（不影响本报告关闭，供后续排期）

1. **B8 的根治**：新增 `Action.ManageAi` / `Action.ManageUser`，让权限矩阵不再靠 `ManageSchedule` 复用（当前 admin-only 语义正确，但语义漂移）。
2. **B9 的分页**：`/admin/departments`、`/admin/doctors` 在行数超过约 200 时需分页（当前假设已文档化）。
3. **子代理交付的运维脚本**中，`devdb.ps1` 的 start/stop/init 全流程与 `new-tls-cert.ps1` 的端到端签发未实跑（只做了函数级/打桩验证），建议在干净机器上补一次演练。
4. **`docs/ADMIN-WEB.md` §九** 的两条边界（权限动作复用、无分页）需要在后续版本关闭时同步删除。

> 原第 3 条（`previsit-check.ps1:384-385` 的 `2>$null`）已在本次收口时一并修掉，见 §C3 末条。
