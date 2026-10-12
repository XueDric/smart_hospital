# 智慧医院 · 前端对接说明书（服务端 HTTP 契约）

> **这份文档是干什么的**：把本仓库 `server/` 里**当前真实存在**的服务端 HTTP 契约，逐字段写清楚，
> 让前端开发者**看完这一份就能开始接**。所有路径、字段名、错误码、默认值都逐字照抄实现，
> 不做本地化改写；中文只用于说明。
>
> **唯一事实来源是 `server/src/` 下的仓颉源码**。本文件任何与源码冲突的地方，以源码为准
> （每条断言后面都标了 `file:line`；标了「未实测」的条目是推理/守恒性结论，需要联调确认）。
>
> **适用范围**：只要某条路由**只有**管理员或医生能调，本文只给**分组概览**并明确写「前端不应调用」，
> 不浪费篇幅列字段。患者端可用的端点（18 个）+ 三端可读的排班端点（2 个）逐字段列全。
>
> **核对过的源码文件**：`server/src/http_app.cj`（1644 行，主路由）、`http_common.cj`、`http_p4.cj`、
> `http_base.cj`、`http_kb.cj`、`previsit.cj`、`triage.cj`、`domain_booking.cj`、`domain_emr.cj`、
> `auth_repo.cj`、`auth_crypto.cj`、`main.cj`、`schema.cj`；以及框架层
> `server/third_party/qingzhou/src/{bodyparser,cors,router,compose,context}.cj`（用于解释两处非信封响应）。
>
> **文档口径提示**：本项目历史上有若干份交接文档（`server/README.md`、`docs/P*-HANDOFF.md`）与实现存在出入，
> 详见 §11「本仓文档口径提示」。本文只描述服务端契约与前端通用对接要点。

---

## 1. 30 秒速览

| 项 | 值 |
| --- | --- |
| Base URL 形态 | `http://<host>:<port>` 或 `https://<host>:<port>`；**业务接口全部带前缀 `/api/v1`**（`http_app.cj:433`） |
| 默认端口 | **8080**（`main.cj:556` `var port: UInt16 = 8080`）；联调常用 `--port 8091`（明文）/ `8443`（TLS），**都只是启动参数约定，不是默认值** |
| 默认监听地址 | `127.0.0.1`（`main.cj:557`）。要局域网联调必须显式 `--bind 0.0.0.0`（`main.cj:581-583`） |
| 鉴权头 | `Authorization: Bearer <token>`；头名大小写不敏感，`Bearer` 前缀大小写不敏感，token 前后空白会被 trim（`http_app.cj:350-363`） |
| 成功信封 | `{"ok":true,"data":{…}}`，HTTP 200 / 201（`http_common.cj:225-238`） |
| 失败信封 | `{"ok":false,"error":{"code","message","fields"?}}`（`http_common.cj:241-253`） |
| 唯一例外 | `GET /health`：**在根路径、不在 `/api/v1` 下、不鉴权、不走信封**，返回平铺 `{ok,service,version,data_backend,dev_auth}`（`http_app.cj:737-745`） |
| SSE | `GET /api/v1/previsit/stream?chief_complaint=…`；线格式 `data: {"event":"meta"\|"delta"\|"done","data":{…}}\n\n`（`previsit.cj:611-616`） |
| TLS | **只在显式给 `--tls-cert/--tls-key`（或 `--tls-files`）时才启用；绝不静默降级**（`main.cj:786-836`） |
| ID 类型 | 除预问诊 `session_id` 是 64 位 hex **字符串**外，所有 id 都是 **JSON number**（Int64） |
| 时间戳 | 一律 **Unix epoch 秒**（整数），不是毫秒、不是 ISO 串 |
| 日期 | `YYYY-MM-DD` 字符串，**只做形状校验**（`http_app.cj:476-500`） |

**前端接入顺序建议**：① 起服务端（§2）→ ② 摸通信封与错误（§3）→ ③ 打通登录与 401/429（§4）
→ ④ 按域接端点（§5）→ ⑤ 接 SSE 预问诊（§7）→ ⑥ 挂号幂等与退号（§8）。

---

## 2. 把服务端跑起来（前端联调用）

### 2.1 本机开发库（仓库自管 MariaDB，端口 3317）

```powershell
cd server

# 启动（数据目录不存在时会先初始化）
.\devdb.ps1 start

# 看状态（应看到监听 127.0.0.1:3317）
.\devdb.ps1 status

# 停止
.\devdb.ps1 stop
```

依据：`server/devdb.ps1`（`param` 段默认 `Port = 3317` / `RootPassword = "devroot2026"`）；
规格说明见 `docs/DEV-DB.md`。账号与库：

| 项 | 值 |
| --- | --- |
| 业务账号 | `hospital` / `hospital_dev_2026` |
| 开发库 | `hospital` |
| 测试库 | `hospital_test`（**`accept` 只认名字含 `test` 的库**，`main.cj:945-947`） |
| 监听 | `127.0.0.1:3317`（回环，见 `docs/DEV-DB.md` 的安全一节） |

### 2.2 最小启动序列（本机实测配方）

```powershell
# 0) 确保构建产物存在（仓库已有 server\build\hospital-server.exe；重编见 server\README.md §二）
cd server

# 1) 起开发库
.\devdb.ps1 start

# 2) 建测试库（幂等）。业务账号对"新建的第三个库"没有权限，
#    若库还不存在且授权不足，create-db 会明确失败并打印可复制的 GRANT 命令。
.\build\hospital-server.exe create-db "mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital_test"

# 3) 建第一个管理员（引导入口，不经 HTTP；口令**只打印一次**）
.\build\hospital-server.exe create-admin "mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital_test"

# 4) 起 HTTP 服务（阻塞）
.\build\hospital-server.exe serve "mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital_test" --port 8091
```

DSN 格式（本项目统一）：

```
mysql://<user>:<pass>@<host>:<port>/<db>
mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital_test
```

`serve` 的完整参数（`main.cj:537-538`、`main.cj:549-671`）：

```
hospital-server.exe serve <dsn> [--port N] [--bind IP] [--dev-auth] [--prod]
                           [--tls-cert <pem> --tls-key <pem>] [--tls-files <env>]
```

* `--port` **严格解析**：非数字或 `0` 直接拒绝启动（`main.cj:565-580`）——不会静默回退 8080。
* `--bind` 默认 `127.0.0.1`；`0.0.0.0` 时启动日志会警告明文 HTTP 不要暴露公网（`main.cj:748-751`）。
* `--dev-auth` 与 `--prod` **互斥**，同时传直接拒绝启动（`http_app.cj:279-286`）。
* 未知参数直接拒绝启动（`main.cj:667-670`）——不是"忽略看不懂的选项"。
* 启动时**先跑口令/令牌原语自检**（PBKDF2 公开测试向量），自检失败拒绝启动（`main.cj:680-683`）。

### 2.3 怎么确认它活着

```powershell
Invoke-RestMethod http://127.0.0.1:8091/health
```

```json
{"ok":true,"service":"hospital-server","version":"0.2.0-p1","data_backend":"mysql","dev_auth":false}
```

| 字段 | 类型 | 含义 |
| --- | --- | --- |
| `ok` | Bool | 恒 `true`（**注意：这个 `ok` 与信封里的 `ok` 同级，但它没有 `data` 包装层**） |
| `service` | String | 恒 `"hospital-server"`（`http_app.cj:740`） |
| `version` | String | `SERVER_VERSION`，当前 `"0.2.0-p1"`（`main.cj:31`）。**当成不透明字符串**，不要按版本号做能力判断 |
| `data_backend` | String | 恒 `"mysql"`（`http_app.cj:742`） |
| `dev_auth` | Bool | `true` = 服务端以 `--dev-auth` 启动，**开发鉴权模式已开**：`X-Role`/`X-Patient-Id`/`X-Doctor-Id` 头可绕过全部认证（`http_app.cj:321-343`）。**正式联调必须为 `false`**，前端可在设置页把 `dev_auth:true` 显示成红色告警 |

> ⚠ `GET /api/v1/health` → **404**（未实测；由路由表 `http_app.cj:737` 只有根路径 `/health` 直接得出，
> 且已由手工探测确认返回平铺 `{"error":"Not Found","path":"/api/v1/health"}`，见 §12）。
> `/health` 的响应是普通 `content-length` JSON，**不是** chunked（全项目只有 `/previsit/stream` 是 chunked 流）。

### 2.4 TLS 怎么开

```powershell
# 方式一：直接给两个 PEM 路径
.\build\hospital-server.exe serve <dsn> --port 8443 --tls-cert "C:\Temp\cert.pem" --tls-key "C:\Temp\key.pem"

# 方式二：给一个 ASCII 路径的 env 文件（内容 UTF-8，每行 key=value，支持 # 注释）
#   cert=E:\...\certs\cert.pem
#   key=E:\...\certs\key.pem
.\build\hospital-server.exe serve <dsn> --port 8443 --tls-files "C:\ProgramData\smart-hospital\tls\tls.env"
```

* **绝不静默降级**：给了 TLS 参数但证书读不到 / PEM 解析失败 / 只给了一个 → **直接退出**，不回退明文
  （`main.cj:786-836`）。所以前端**不能靠探测**判断 http/https，必须由构建配置写死。
* ⚠ `--tls-cert` 走命令行 argv，而本工具链的仓颉运行时**无法接受含非 ASCII 的 argv**（`main.cj:594-599`）。
  本仓库路径含中文（`智能医院客户端`），所以直接传仓库内路径**必然启动失败**；要么把证书拷到纯 ASCII 路径，
  要么用 `--tls-files`（文件内容可以是中文，文件路径必须 ASCII）。
* 仓库自带 `server/certs/{cert.pem,key.pem,tls.env}` 与 `server/new-tls-cert.ps1`（生成带 SAN 的自签证书）可参考。
* 联调自签证书时客户端需要临时信任策略；**发布版必须走受信 HTTPS**（见 §10.1）。

---

## 3. 通用约定

### 3.1 URL 前缀与 Content-Type

| 主题 | 约定 |
| --- | --- |
| 前缀 | 业务接口都在 `/api/v1` 下；**只有 `/health` 例外** |
| 请求 `Content-Type` | 带 body 的请求用 `application/json`。**不带 `Content-Type: application/json` 时框架的 bodyParser 完全不解析 body**（`bodyparser.cj:61-86`），于是字段全缺 → 400「缺少必填字段 …」 |
| 响应 `Content-Type` | `application/json; charset=utf-8`（`http_common.cj:225-238` → `ctx.json()`，`context.cj:285-286`） |
| SSE 响应头 | `text/event-stream; charset=utf-8` + `transfer-encoding: chunked` + `cache-control: no-cache`（`http_app.cj:1262`、`context.cj:304-306`） |

### 3.2 信封与**三种**失败形状（最容易被前端踩的一条）

成功（HTTP 200/201）：

```jsonc
{ "ok": true, "data": { /* … */ } }
```

失败：**共三种形状，解析必须先判 `ok` 字段存不存在**。

**(1) 业务错误（校验 / 鉴权 / 冲突）** —— `http_common.cj:241-253`：

```json
{ "ok": false, "error": { "code": "SLOT_GONE", "message": "号源已被抢完，请选择其它排班" } }
```

`error.fields` **仅在**错误对象带了字段明细时出现（`ApiError.fields` 为 `Some`），形如 `{"字段名":"原因"}`；
`http_common.cj:245-248` 会按需附加。客户端要**判空后再读**（当前患者端路径下它很少出现）。

**(2) 请求体不是合法 JSON** —— HTTP **400**，**平铺**，**没有 `ok`、没有 `error`**：

```json
{"code":400,"message":"Invalid JSON body","data":null}
```

依据：框架 `bodyparser.cj:50-54`（`defaultBodyParserError`）在 `handleJson` 解析失败时接管响应
（`bodyparser.cj:103-109`），**在 `cors()` 之前短路**，不进入本项目的 `hospitalErrorHandler`。
⇒ 这是**唯一**一条"请求体坏掉时拿不到 `ok:false` 信封"的路径。

**(3) 未匹配路由** —— HTTP **404**，**平铺**，**没有 `ok`、没有 `error`**，且**回显请求路径**：

```json
{"error":"Not Found","path":"/api/v1/aprpointments"}
```

依据：框架 `router.cj:202-212` / `router.cj:242-245` 直接写响应。
⇒ **注意：这与本文档 §5 里业务 404（`APPOINTMENT_NOT_FOUND` 等）是两种不同形状**。前者只有 `error` 字符串，
后者有 `error.code`。拼错一个字母就会从"业务 404 信封"变成"平铺 404"。

**推荐解析顺序（ArkTS / TypeScript 伪代码）**：

```ts
type Envelope = { ok?: boolean; data?: any; error?: any; code?: number; message?: string };

function unwrap(res: Envelope): any {
  // ① 先判 ok 字段存不存在 —— 不存在 ⇒ 框架层响应（形状 2 / 3），没有业务码可读
  if (res.ok !== true && res.ok !== false) {
    if (typeof res.code === 'number') throw new ApiError('HTTP_' + res.code, res.message ?? '请求体不是合法 JSON');
    throw new ApiError('HTTP_404', res.error === 'Not Found' ? `接口不存在：${res.path}` : '响应格式未知');
  }
  // ② 有 ok:false ⇒ 才是本项目的业务错误信封
  if (res.ok === false) {
    const e = res.error ?? {};
    throw new ApiError(e.code ?? 'UNKNOWN', e.message ?? '', e.fields);
  }
  // ③ ok:true
  return res.data;
}
```

> `/health` 是**第四种**形状（平铺、有 `ok:true` 但没有 `data`）——用上面的 `unwrap` 会返回 `undefined`。
> 建议 `health()` 单独解析，不要复用同一个解析器。

### 3.3 HTTP 状态码 vs 业务码

服务端的口径是**分工**而不是二选一（`http_common.cj:8-13` 有明确说明）：

* **HTTP 状态码给网络层用**：401 直接踢回登录页，不必解析 body；429 直接读 `retry-after` 退避。
* **`error.code` 给业务层用**：客户端 switch 出文案。同一个 HTTP 状态可能对应多个业务码
  （401 有 `AUTH_REQUIRED` / `AUTH_BAD_CREDENTIALS` / `AUTH_TOKEN_EXPIRED` / `AUTH_RATE_LIMITED` 四个）。
* 状态码由**错误码表决定**，调用方不记数字：`apiErrorSpec(code)` 返回 `(status, message)`
  （`http_common.cj:55-197`、`http_common.cj:199-213`）。
* **未在表里登记的错误码一律兜底 500 + `服务器内部错误`**（`http_common.cj:196`），
  且绝不把内部堆栈回给客户端（`http_common.cj:298-302`）。
* 注意：`429` 是唯一一个"HTTP 状态码本身就是业务结论"的设计（限流），
  它的业务码 `AUTH_RATE_LIMITED` 与 429 一一对应（`http_common.cj:63-77` 有完整论证）。

### 3.4 可选的设备头

| 头 | 何时带 | 说明 |
| --- | --- | --- |
| `X-Device-Id` | 登录与后续请求都可选 | 稳定设备标识（设备安装 id）。**截断到 64 字符**（`http_app.cj:453-463`、`http_app.cj:502-507`） |
| `X-Device-Name` | 同上 | 给人看的名字（"Mate 60"）。同样截断到 64 |
| `X-Role` / `X-Patient-Id` / `X-Doctor-Id` | **仅当服务端 `--dev-auth` 时** | 客户端**绝不可依赖**：这是开发态绕过认证的临时形态。`X-Role` 值必须是 `patient`/`doctor`/`admin`，否则 400「未知角色：…」（`http_app.cj:321-343`） |

> ⚠ 两个设备头**一律不可信**（客户端自报）：用途**仅限**会话列表展示与 `/auth/me` 回显，
> **绝不参与授权判定**（`http_app.cj:445-448`、`auth_repo.cj:263-265`）。
> 长度截断到 64 也是防线：不截断会让一个超长请求头撞 MySQL `Data too long` 变成 500。

### 3.5 分页、排序、限额

| 主题 | 约定 |
| --- | --- |
| 分页 | **没有** `page` / `page_size` / `offset` / cursor。只有 `limit`，且**超限被静默夹住**（不报错）。配合响应里的 `count` |
| 各接口 `limit` 上限 | 患者端会碰到的三处：`schedules` 500（`domain_booking.cj:313`）；`appointments` 200（`domain_booking.cj:278`）；`medical-records` 200（`http_p4.cj:406-407`） |
| `limit <= 0` | **回退到默认值**（不是报错）：`schedules` 100、`appointments` 50、`medical-records` 50 |
| 判断"还有更多" | 只能靠 `count == limit` 粗略判断，**没有 total、没有 next cursor** |
| 列表排序 | `schedules`：`work_date ASC, period ASC, id ASC`（`domain_booking.cj:325`）；`appointments`：`created_at DESC, id DESC`（`domain_booking.cj:283`）；`auth/sessions`：`last_seen_at DESC, device_id ASC`（`auth_repo.cj:678-680`） |
| 请求体上限 | 外层 `contentLengthLimit(64 * 1024)`：`Content-Length > 64 KiB` → **413**（`http_app.cj:1602`）；内层 `bodyParser()` 兜底 **1 MiB**（`bodyparser.cj:36`），用于没有 `Content-Length` 的 chunked 请求（`http_app.cj:1603-1614`） |
| 超时 | `timeout(15000)`。⚠ **它不会打断已进入的同步 handler**：handler 没写响应时补一个 **408**，已写响应则只附加 `x-timeout-ms` 头（`http_app.cj:1617-1630`）。**客户端自己设超时更可靠** |
| CORS | `cors()` 已启用，默认 `access-control-allow-origin: *`、暴露 `X-Request-Id`（`cors.cj:32-55`）。⚠ **请求体非法 JSON** 那条 400 由 `bodyParser` 在 `cors()` 之前短路 ⇒ **不带 CORS 头**（`http_app.cj:1602-1616` 的中间件顺序 + `bodyparser.cj:68-73` 的 `return`）。做 Web 前端时这条会影响跨域下读错误体 |
| 未匹配路由 | 平铺 404（见 §3.2 形状 3），**不是** `ROUTE_NOT_FOUND` 信封 |

---

## 4. 鉴权全流程

### 4.1 令牌模型

| 项 | 值 | 依据 |
| --- | --- | --- |
| 形态 | **不透明令牌**，32 字节随机 → **64 位十六进制字符串**。**不是 JWT，客户端不得解析** | `auth_crypto.cj:77-80` |
| 有效期 | `TOKEN_TTL = 30 * 86400`（30 天） | `auth_crypto.cj:39` |
| 续期 | **服务端滑动续期**：有效期不足 `TOKEN_TTL - RENEW_AFTER` 且距上次续期 ≥ `RENEW_AFTER`（86400 s）时续到 `now + TOKEN_TTL` | `auth_crypto.cj:41-42`、`auth_repo.cj:788-792` |
| 无 refresh 接口 | **没有** `/auth/refresh`，也不需要；拿到 401 `AUTH_TOKEN_EXPIRED` 才重新登录 | `auth_repo.cj:754-812` |
| 有状态 | `auth_token` 表；服务端可随时吊销（登出 / 改口令 / 踢设备），客户端**不能**只凭本地 `expires_at` 判断有效 | `auth_repo.cj:739-752` |
| 失效途径 | ① `POST /auth/logout`（当前令牌）② `POST /auth/logout-all`（本人全部）③ `POST /auth/sessions/revoke`（按设备）④ 管理员重置口令会吊销该账号**全部**令牌（`auth_repo.cj:582`）⑤ 到期 |
| 建议持久化 | 只存 token + `expires_at` + `role` + `ref_id`。**绝不要存 password** | — |

### 4.2 `POST /api/v1/auth/login` —— 登录（唯一换令牌入口）

* **鉴权**：不需要。实现 `http_app.cj:750-798`。
* **请求头（可选）**：`X-Device-Id`、`X-Device-Name`（各截断 64，只用于会话列表展示）。

**请求体**

| 字段 | 类型 | 必填 | 约束 |
| --- | --- | --- | --- |
| `login_name` | String | **是** | 缺 → 400「缺少必填字段 login_name」；空串 → 400「字段 login_name 不能为空」（`http_common.cj:315-325`）。服务端会**归一**：trim 首尾空白 + 转小写（`auth_repo.cj:131-139`） |
| `password` | String | **是** | 同上。⚠ 字段名必须是 `password`；写成 `pass_word`/`pwd` → **400**（不是 401） |

> ⚠ **错字段名会得到 400 而不是 401**：这是最常见的对接事故。

**成功 `200`**

```json
{ "ok": true,
  "data": { "token": "9f2c…(64 hex)…", "expires_at": 1790000000, "user_id": 12,
            "role": "patient", "ref_id": 7, "display_name": "张三", "patient_id": 7 } }
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `token` | String | 64 hex，后续放 `Authorization: Bearer <token>` |
| `expires_at` | Int64 | epoch **秒** |
| `user_id` | Int64 | `auth_user.id` |
| `role` | String | `"patient"` / `"doctor"` / `"admin"` |
| `ref_id` | Int64 | 角色档案 id：patient ⇒ `patient.id`；doctor ⇒ `doctor.id`；admin ⇒ **0**（`auth_repo.cj:806-810`） |
| `display_name` | String | 展示名 |
| `patient_id` | Int64 | ⚠ **等于 `ref_id` 的便利字段，不判角色**（`http_app.cj:768-774`）。**医生登录时它是 `doctor.id`；管理员登录时是 0** |

> ⚠⚠ **绝不能用 `patient_id` 判断"这是不是一个患者"**。实测：管理员登录返回 `role:"admin", ref_id:0, patient_id:0`；
> 医生登录返回 `patient_id == doctor.id`。判角色只能看 `role`。

**错误**

| HTTP | code | 触发 |
| --- | --- | --- |
| 400 | `VALIDATION_FAILED` | 缺字段 / 空字段 / 字段名写错（`error.message` 指明是哪个字段） |
| 400 | （平铺形状） | 请求体不是合法 JSON → `{"code":400,"message":"Invalid JSON body","data":null}`（见 §3.2） |
| 401 | `AUTH_BAD_CREDENTIALS` | 账号不存在**或**口令错误**或**账号被停用（服务端刻意不区分，防枚举；`http_app.cj:792-797`、`auth_repo.cj:618-641`） |
| **429** | `AUTH_RATE_LIMITED` | 连续失败达到 `LOGIN_FAIL_LIMIT = 5` 次（`auth_repo.cj:90`）。**响应头带 `retry-after: <剩余秒数>`**（至少 1 s，`http_app.cj:789`、`auth_repo.cj:381-386`） |

**限流的实测行为**（见 §12 实测记录，脚本 `server/tests/rate-limit-check.ps1`）：

* 第 **5** 次失败就返回 429（不是第 6 次）：`recordFailure` 记完第 5 次即 `fail_count >= 5`（`auth_repo.cj:381`）。
* 锁定窗口 `LOGIN_LOCK_SECONDS = 900`（15 分钟），窗口内**即使口令正确也拒绝**（`auth_repo.cj:608-614` 在 PBKDF2 **之前**判定）。
* 锁定期内响应约 **0.045 s**（未跑 PBKDF2），正常登录约 **0.55 s**——所以"快 = 被限流"。
* `retry-after` 在**同一锁定窗口内会递减**（实测 900 → 899），前端每次 429 都要**重读**该头，不要缓存首次值。
* 限流按**归一化登录名的哈希**计数，**按账号隔离**：锁 A 账号期间用正确口令登录 B 账号照常 200（`auth_repo.cj:164-166`、`auth_repo.cj:370-388`）。
* 账号**不存在**的登录名同样会被限流（计数表与 `auth_user` 无外键），**所以它不是账号枚举 oracle**（`http_common.cj:63-74`）。
* 登录成功后**清零**失败计数（`auth_repo.cj:643-646`）。
* ⚠ 已知边界（源码如实记录）：账号级锁定的代价是**可被用来对特定账号做 15 分钟量级的拒绝服务**（`auth_repo.cj:74-88`）。

**客户端建议**：429 时用 `retry-after` 做倒计时并禁用登录按钮；不要用"剩余秒数"的本地副本跨请求复用。

**可直接粘贴的示例**

```bash
# curl（bash / Git Bash）：登录
curl -s -X POST http://127.0.0.1:8091/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -H "X-Device-Id: dev-001" -H "X-Device-Name: Mate60" \
  -d '{"login_name":"admin","password":"<口令>"}'
```

```powershell
# PowerShell（Windows 原生，推荐用它联调，避免 curl 的引号坑——见 §13.2）
$base = "http://127.0.0.1:8091"
$login = Invoke-RestMethod -Method Post -Uri "$base/api/v1/auth/login" `
  -ContentType "application/json" `
  -Headers @{ "X-Device-Id" = "dev-001"; "X-Device-Name" = "Mate60" } `
  -Body (@{ login_name = "admin"; password = "<口令>" } | ConvertTo-Json -Compress)

$tok = $login.data.token
$hdr = @{ Authorization = "Bearer $tok"; "X-Device-Id" = "dev-001" }
$me  = Invoke-RestMethod -Uri "$base/api/v1/auth/me" -Headers $hdr
$me.data | Format-List          # user_id / role / patient_id / doctor_id / device_id
```

### 4.3 其余鉴权端点

#### `GET /api/v1/auth/me` —— 当前身份（`http_app.cj:879-890`）

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `user_id` | Int64 | |
| `role` | String | `patient` / `doctor` / `admin` |
| `patient_id` | Int64 | 非患者为 **0** |
| `doctor_id` | Int64 | 非医生为 **0** |
| `device_id` | String | 回显**本次请求**的 `X-Device-Id`（没带就是 `""`），用于在会话列表里标出"这台设备" |

错误：`401 AUTH_REQUIRED`（没带令牌）/ `401 AUTH_TOKEN_EXPIRED`（令牌无效或过期）。

#### `POST /api/v1/auth/logout` —— 登出（吊销当前令牌，`http_app.cj:801-812`）

* 请求体：无（可空）。
* 成功 `200`：`{"ok":true,"data":{"logged_out":true}}`
* 错误：`401 AUTH_REQUIRED`（没带令牌）/ `401 AUTH_TOKEN_EXPIRED`（令牌无效）。
  ⚠ **令牌无效时不会假装成功**（`http_app.cj:806-807`）。

#### `POST /api/v1/auth/logout-all` —— 吊销本人全部令牌（`http_app.cj:870-876`）

* 请求体：无。
* 成功 `200`：`{"ok":true,"data":{"revoked":3}}`（`revoked` 含**当前这一条**）。

#### `GET /api/v1/auth/sessions` —— 我的设备会话（`http_app.cj:825-843`）

只返回**自己**的、且**未过期**的会话（`auth_repo.cj:676-695`）。

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `sessions` | Array | 见下 |
| `sessions[].device_id` | String | 未带则 `""` |
| `sessions[].device_name` | String | 未带则 `""` |
| `sessions[].created_at` | Int64 | epoch 秒（登录时刻） |
| `sessions[].last_seen_at` | Int64 | epoch 秒（**节流 300 s 更新**，`auth_repo.cj:717-728`） |
| `sessions[].expires_at` | Int64 | epoch 秒 |
| `count` | Int | 会话条数 |

> ⚠ **绝不返回 token 明文**（`http_app.cj:823`、`auth_repo.cj:256-265`）。
> ⚠ `device_id` 为空的会话**无法**通过下一节按设备踢掉（只能在本地忽略，或走 `logout-all`）。

#### `POST /api/v1/auth/sessions/revoke` —— 按设备踢会话（`http_app.cj:853-867`）

只作用于**自己**（`auth_repo.revokeSessionsByDevice` 带 `AND user_id = ?`，`auth_repo.cj:697-715`）。

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `device_id` | String | **是** | 缺 → 400「缺少必填字段 device_id」；空串 → 400「字段 device_id 不能为空」（`requireStr` 先抛，`http_app.cj:856-861` 的分支实际不可达）。要踢全部请用 `logout-all` |

成功 `200`：`{"ok":true,"data":{"revoked":1,"device_id":"dev-001"}}`（`revoked` 为 0 也返回 200）。

### 4.4 口令强度规则（仅管理员建号/重置时生效）

患者端**没有**改密/注册接口，所以这条对前端只是"知道服务端会拒什么"。规则在仓储层强制
（`auth_repo.cj:295-347`、建号与 `setPassword` 都调它）：

1. 长度 ≥ `PW_MIN_LEN = 8`（`auth_repo.cj:211`）→ 失败文案 `口令至少 8 位（当前 N 位）`
2. 必须同时含**字母**（ASCII A-Z/a-z）与**数字** → `口令必须同时包含字母与数字`
3. 不在常见弱口令表内（`auth_repo.cj:226-245`）→ `口令太常见，请换一个`
4. 不等于登录名、也不是"登录名 + 前后缀" → `口令不能与登录名相同` / `口令不能是登录名加前后缀（如 <login>123）`

失败以 **400 `VALIDATION_FAILED`** 返回，`message` 前缀为 `口令强度不足：…`
（仓储抛 `UserFacingError`，`http_common.cj:288-297` 把它映射成 400，`auth_repo.cj:525-529`）。

---

## 5. 端点清单（患者端逐字段 + 三端可读）

### 5.0 速查表

| # | 方法 + 路径 | 鉴权 | 谁能调 | 一句话 |
| --- | --- | --- | --- | --- |
| 5.1 | `GET /health` | 否 | 任何人 | 探活 / 版本 / `dev_auth` |
| 5.2 | `POST /api/v1/auth/login` | 否 | 任何人 | 登录换令牌 |
| 5.3 | `GET /api/v1/auth/me` | 是 | 任意角色 | 当前身份 |
| 5.4 | `POST /api/v1/auth/logout` | 是 | 任意角色 | 吊销当前令牌 |
| 5.5 | `POST /api/v1/auth/logout-all` | 是 | 任意角色 | 吊销本人全部令牌 |
| 5.6 | `GET /api/v1/auth/sessions` | 是 | 任意角色 | 我的设备会话列表（无 token） |
| 5.7 | `POST /api/v1/auth/sessions/revoke` | 是 | 任意角色 | 按 `device_id` 踢会话 |
| 5.8 | `POST /api/v1/triage` | 是 | **仅 patient** | AI 分诊（规则 + 真实号源校验） |
| 5.9 | `GET /api/v1/previsit/stream` | 是 | **仅 patient** | 预问诊开流（SSE） |
| 5.10 | `POST /api/v1/previsit/answer` | 是 | **仅 patient** | 提交一项问诊答案 |
| 5.11 | `GET /api/v1/previsit/:id` | 是 | **仅 patient** | 取问诊单 |
| 5.12 | `GET /api/v1/schedules` | 是 | **三端都可** | 排班 / 号源列表 |
| 5.13 | `GET /api/v1/schedules/:id` | 是 | **三端都可** | 单个排班 |
| 5.14 | `GET /api/v1/appointments` | 是 | **仅 patient** | 我的挂号列表 |
| 5.15 | `POST /api/v1/appointments` | 是 | **仅 patient** | 挂号（幂等） |
| 5.16 | `POST /api/v1/appointments/:id/cancel` | 是 | patient（自己的）/ admin（任意） | 退号 |
| 5.17 | `GET /api/v1/medical-records` | 是 | patient / doctor | 我的就诊记录（**无正文**） |
| 5.18 | `GET /api/v1/medical-records/:appointmentId` | 是 | patient / doctor | 某次就诊病历（锁定后含七段正文） |
| 5.19 | `GET /api/v1/health` | 否 | 任何人 | 探活（`/health` 的 **`/api/v1` 别名**） |
| 5.20 | `GET /api/v1/departments` | 是 | **三端都可** | 科室字典（患者端取科室名） |
| 5.21 | `GET /api/v1/doctors` | 是 | **三端都可** | 医生字典（带 `department_name`） |
| 5.22 | `GET /api/v1/notices` | 是 | **三端都可** | 公告列表（首页「医疗公告」） |
| 5.23 | `GET/POST /api/v1/admin/notices`、`GET/PUT/DELETE /api/v1/admin/notices/:id` | 是 | **仅 admin** | 公告维护（§6.1） |

> 权限判定收敛在**单一函数** `can(role, action)`（`http_app.cj:162-230`）。相关动作与角色：
> `book` = 仅 patient；`view_schedule` = 三端；`query_own_medical_record` = patient | doctor；
> `cancel_own` = 仅 patient；`cancel_any` = 仅 admin。

### 5.1 `GET /health` —— 探活与版本

见 §2.3。**唯一不走信封的接口**，实现在 `http_app.cj:737-745`。

### 5.2 `POST /api/v1/auth/login`

见 §4.2。

### 5.3 ~ 5.7 鉴权类

见 §4.3。

### 5.8 `POST /api/v1/triage` —— 智能分诊

* **鉴权**：需要；`Action.Book` ⇒ **仅 patient**。医生 / 管理员调用 → **403 `FORBIDDEN_ROLE`**
  （实测：管理员调 `/triage` → 403，见 §12）。实现 `http_app.cj:1157-1223`。

**请求体**

| 字段 | 类型 | 必填 | 约束 |
| --- | --- | --- | --- |
| `chief_complaint` | String | **是** | 缺 → 400「缺少必填字段 chief_complaint」（`http_app.cj:1161-1164`）。**空白串不是错误**：`"   "` 会走到 `reason_code = NO_COMPLAINT` 正常返回 200（实测，见 §12）。⚠ **患者身份取自令牌，body 里传 `patient_id` 无效** |

**超长处理**：若 UTF-8 **字节**数 > `TRIAGE_INPUT_MAX_BYTES = 1500`，服务端按**字符**截断到
`TRIAGE_INPUT_MAX_CHARS = 500` 字符，并把 `truncated` 置 `true`（**不报错**，`http_app.cj:1181-1186`、
`http_app.cj:593-614`）。实测 1200 字主诉 → 200 且 `truncated=true`（不是 500）。
客户端仍应在本地限制输入长度。

**成功 `200`**

```json
{ "ok": true, "data": {
  "red_flag": false, "reason_code": "OK", "source": "rules",
  "patient_note": "…给患者看的一句话…", "truncated": false,
  "ai_note": "", "ai_reason": "未配置模型，已按规则给出建议",
  "options": [ { "department_id": 3, "department_name": "呼吸内科",
                 "doctor_id": 9, "doctor_name": "李医生", "doctor_title": "副主任医师",
                 "schedule_id": 41, "work_date": "2026-11-20", "period": "AM",
                 "remain_num": 5, "total_remain": 12 } ],
  "count": 1 } }
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `red_flag` | Bool | `true` = 命中危急征象，**必须立刻引导就医/急诊**，此时 `options` 必为空（实测 `count=0`） |
| `reason_code` | String | 见下表 |
| `source` | String | `"rules"`（规则）/ `"model"`（模型润色成功）/ `"model:invalid"`（模型答了但不合规 ⇒ 需改 Prompt）。**模型永远不能改 `options`**（`http_app.cj:1194`、`triage.cj:99-108`） |
| `patient_note` | String | 给患者看的说明文案 |
| `truncated` | Bool | 主诉是否被截断 |
| `ai_note` | String | 模型生成的患者向文案；未启用时为 `""` |
| `ai_reason` | String | 为什么是这个 `source`（给运维看，不含密钥） |
| `options` | Array | 推荐号源，**每一个都已用真实数据库验证 `remain_num > 0`**（`http_app.cj:1146-1149`） |
| `options[].department_id` | Int64 | |
| `options[].department_name` | String | ⚠ 患者端**唯一**能拿到科室名的来源（见 §9 缺口 1） |
| `options[].doctor_id` | Int64 | |
| `options[].doctor_name` | String | ⚠ 患者端**唯一**能拿到医生姓名的来源（见 §9 缺口 2） |
| `options[].doctor_title` | String | 职称 |
| `options[].schedule_id` | Int64 | 直接拿去调 §5.15 挂号 |
| `options[].work_date` | String | `YYYY-MM-DD` |
| `options[].period` | String | `AM` / `PM` |
| `options[].remain_num` | Int64 | 该排班剩余号 |
| `options[].total_remain` | Int64 | 该科室/医生当日可用号合计 |
| `count` | Int | `options` 长度 |

**`reason_code` 取值**（`triage.cj:54-60`）

| 值 | 含义 | 客户端建议 |
| --- | --- | --- |
| `RED_FLAG` | 命中危急征象 | 强提醒 + 引导急诊/人工，**不要**展示号源列表 |
| `NO_COMPLAINT` | 主诉为空/太短 | 提示补充描述 |
| `NEED_CLARIFY` | 规则无法判定 | 提示换种说法再说一次 |
| `NO_SUCH_DEPT` | 规则认出的科室本院没有 | 提示换科室或走人工 |
| `NO_BOOKABLE` | 认出的科室当下没有可挂号源 | 提示改天/改科室 |
| `ALTERNATIVES` | 首选没号，但给了**有号的**备选 | 正常展示 `options`（并说明是备选） |
| `OK` | 推荐且**已验证有号** | 正常展示 `options` |

> ⚠ 响应里**刻意不含**内部依据（命中哪些危急关键词，`redFlagEvidence`）——它只进服务端日志/审计
> （`http_app.cj:619-621`）。实测危急响应里**没有** `red_flag_evidence` 字段。客户端不要试图推测。

**错误**：`400 VALIDATION_FAILED`（缺 `chief_complaint`）、`401 AUTH_*`、`403 FORBIDDEN_ROLE`（非患者）。

### 5.9 `GET /api/v1/previsit/stream` —— 预问诊（SSE 流）

见 §7 专章（`http_app.cj:1239-1285`）。

### 5.10 `POST /api/v1/previsit/answer` —— 提交一项问诊答案

* **鉴权**：需要；**仅 patient**（`Action.Book`）。实现 `http_app.cj:1288-1319`。
* 刻意**非流式**：它返回的是**业务值**（`http_app.cj:1230-1238` 注释：对话文本流错了只是看到半句话，业务值流错了是**状态污染**）。

**请求体**

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `session_id` | String | **是** | 缺 → 400「缺少必填字段 session_id」 |
| `slot` | String | **是** | 必须是 6 个槽位键之一，否则 400 `VALIDATION_FAILED`「未知的问诊项：\<slot\>」（`http_app.cj:1307-1309`） |
| `value` | String | 否 | 缺省 `""`。**空串不写入库也不推进 `turn`**（`previsit.cj:451-460`）：仍返回 `ok`，但 `next_slot` 不变 |

**六个槽位**（`previsit.cj:181-196`；采集顺序 = 表顺序，服务端按"槽位是否有值"推进，天然幂等）

| `key` | 给患者的问题 | 提示 | `maxLen`（**字符**） |
| --- | --- | --- | --- |
| `chief` | 您这次主要哪里不舒服？ | 例如：咳嗽、胃痛、头晕 | 200 |
| `duration` | 这个情况持续多久了？ | 例如：3 天、2 周、半年 | 60 |
| `severity` | 对日常生活影响大吗？ | 例如：轻微 / 影响睡眠 / 无法工作 | 60 |
| `associated` | 还有其它不舒服吗？（没有就写「无」） | 例如：发热、恶心、乏力 | 200 |
| `history` | 以前有没有得过什么病、或长期吃药？ | 例如：高血压 5 年，服降压药；或写「无」 | 300 |
| `allergy` | 有没有药物或食物过敏？ | 例如：青霉素过敏；或写「无」 | 200 |

* **超长** → 400 `VALIDATION_FAILED`「字段 \<slot\> 超出长度上限」，按**字符**数判（`previsit.cj:446-450`、
  `previsit.cj:636-643`）。实测：`duration` 60 个汉字 → 200；61 个汉字 → 400（**即使 61 字只有 183 字节**）。
* **`"无"` 是有效答案**（阴性），与"没答"语义不同（`previsit.cj:176-179`）——前端必须提供「无」快捷项，
  **不要**用空串代替。空串 = 跳过。
* **跳过某项 = 不提交**（不是提交空串）：提交空串只得到"没写入、状态不变"，但会在客户端产生一次多余往返。
* ⚠ `slot` 未知值会被**明确拒绝**（不静默成功）：静默成功等于允许客户端往问诊单里塞自造字段
  （`previsit.cj:434-443`）。

**成功 `200`** —— 即 `previsitSessionJson`（`http_app.cj:702-729`）

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `session_id` | String | 64 hex |
| `turn` | Int | 已推进轮数（**只有真正写入才 +1**） |
| `filled` | Int | 已填槽位数 |
| `total_slots` | Int | 恒 **6** |
| `complete` | Bool | 是否集齐 6 项 |
| `next_slot` | String | 下一个待填 `key`；完成时为 `""` |
| `next_question` | String | `next_slot` 对应的问句文本；完成时为 `""` |
| `form` | Object\<String,String\> | **仅 `complete == true` 时出现**（键为槽位 key）。未集齐时**刻意不下发**（`http_app.cj:719-727`） |

**错误**

| HTTP | code | 触发 |
| --- | --- | --- |
| 404 | `PREVISIT_NOT_FOUND` | 会话不存在**或不属于你**（刻意用 404 而非 403 防枚举，`previsit.cj:409-416`、`http_app.cj:1299-1306`） |
| 400 | `VALIDATION_FAILED` | 未知 `slot` / 超长 / 缺 `session_id` |
| 401 / 403 | `AUTH_*` / `FORBIDDEN_ROLE` | 未登录 / 非患者 |

### 5.11 `GET /api/v1/previsit/:id` —— 取问诊单

* **鉴权**：需要；**仅 patient**。实现 `http_app.cj:1322-1332`。

| 参数 | 位置 | 类型 | 说明 |
| --- | --- | --- | --- |
| `:id` | path | String | 即 `session_id`（**全项目唯一的字符串型 id**） |

* 成功 `200`：同 §5.10 的 `previsitSessionJson`。
* 错误：`404 PREVISIT_NOT_FOUND`（不存在 / 不属于你）。

### 5.12 `GET /api/v1/schedules` —— 排班 / 号源列表（三端可读）

* **鉴权**：需要；`Action.ViewSchedule` ⇒ **三种角色都可**。实现 `http_app.cj:1344-1376`。

**Query 参数**

| 参数 | 类型 | 必填 | 默认 | 说明 |
| --- | --- | --- | --- | --- |
| `department_id` | Int64 | 否 | `0` | `0` = 不过滤。非数字被 `parseInt64Or` **静默变 0**（`http_app.cj:1347`） |
| `work_date` | String | 否 | `""` | `YYYY-MM-DD`；**非空且形状非法 → 400「work_date 格式应为 YYYY-MM-DD」**（`http_app.cj:1355-1357`） |
| `limit` | Int64 | 否 | `100` | 仓储层夹到 `(0,500]`，`<= 0` 回退 100（`domain_booking.cj:313`） |

**成功 `200`**

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `schedules` | Array | 见下 |
| `schedules[].id` | Int64 | 即 `schedule_id`（拿去调 §5.15） |
| `schedules[].doctor_id` | Int64 | ⚠ **只有 id，没有医生姓名**（见 §9 缺口 2） |
| `schedules[].department_id` | Int64 | ⚠ **只有 id，没有科室名** |
| `schedules[].work_date` | String | `YYYY-MM-DD` |
| `schedules[].period` | String | `AM` / `PM` |
| `schedules[].total_num` | Int64 | 总号 |
| `schedules[].remain_num` | Int64 | 剩余号。**`0` 的行也会返回**，客户端自行显示"已约满" |
| `schedules[].enabled` | Bool | 列表里**恒 `true`**（SQL 固定 `WHERE enabled = 1`，`domain_booking.cj:315`） |
| `count` | Int | 本次返回条数（**不是**总数） |

> ⚠ 列表**不区分过去/将来**，SQL 里没有任何时间条件（`domain_booking.cj:311-326`）
> ⇒ **客户端必须自己按 `work_date` 过滤**，否则会看到历史排班。
> ⚠ 列表**没有** `version` 字段（单查才有，见 §5.13）。

### 5.13 `GET /api/v1/schedules/:id` —— 单个排班（三端可读）

* **鉴权**：需要；三端都可。实现 `http_app.cj:1415-1438`。

| 参数 | 位置 | 类型 | 说明 |
| --- | --- | --- | --- |
| `:id` | path | Int64 | 非正整数 → 400 `VALIDATION_FAILED`「排班 id 必须是正整数」 |

* 成功 `200`：`{ "id", "doctor_id", "department_id", "work_date", "period", "total_num", "remain_num", "version", "enabled" }`
  （`http_app.cj:1427-1437`）

> ⚠ **响应形状与列表不同**：单查多一个 `version`（乐观锁版本号，列表**没有**）；
> 单查的 `enabled` **可能为 `false`**（不像列表被 SQL 过滤）。
> 错误：`404 SCHEDULE_NOT_FOUND`「排班不存在或已停诊」。

### 5.14 `GET /api/v1/appointments` —— 我的挂号列表

* **鉴权**：需要；**仅 patient**。非患者**或** `patientId <= 0` ⇒
  `403 FORBIDDEN_ROLE`「该接口只对患者开放（它返回的是"我的挂号"）」（`http_app.cj:1386-1412`）。

**Query 参数**

| 参数 | 类型 | 必填 | 默认 | 说明 |
| --- | --- | --- | --- | --- |
| `include_cancelled` | String | 否 | 不含已取消 | **必须正好是字符串 `"true"`** 才生效（其他值一律当 false，`http_app.cj:1401`） |
| `limit` | Int64 | 否 | `50` | 夹到 `(0,200]`，`<= 0` 回退 50（`domain_booking.cj:278`） |

> `patient_id` **一律取自令牌**，查询参数里传了也没用（`domain_booking.cj:271-272` 明确写死这条纪律）。

* 成功 `200`：`{ "appointments": [ <bookingJson> … ], "count": N }`

**`bookingJson`（挂号单通用形状，`http_app.cj:411-426`）**

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `appointment_id` | Int64 | 挂号单 id |
| `schedule_id` | Int64 | |
| `patient_id` | Int64 | |
| `doctor_id` | Int64 | |
| `department_id` | Int64 | |
| `visit_date` | String | `YYYY-MM-DD`（**下单时的快照**，管理员之后改排班不会跟着变，`domain_booking.cj:517-519`） |
| `period` | String | `AM` / `PM` |
| `seq_no` | Int64 | 就诊序号（`MAX(seq_no)+1`，不回收已用过的号，`domain_booking.cj:721-729`） |
| `status` | String | `booked` / `visiting` / `done` / `cancelled` / `no_show`（见 §14.3） |
| `slot_restored` | Bool | 号源是否已归还（退号相关） |

> ⚠ `bookingJson` **没有** `created_at`：`BookingResult` 有该字段但不输出（`http_app.cj:411-426` 逐字段对照）。
> 所以列表顺序（`created_at DESC`）无法在客户端复现。

**错误**：`401 AUTH_*`、`403 FORBIDDEN_ROLE`。

### 5.15 `POST /api/v1/appointments` —— 挂号（幂等）

* **鉴权**：需要；`Action.Book` ⇒ **仅 patient**。实现 `http_app.cj:1441-1464`。

**请求体**

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `schedule_id` | Int64 | **是** | 缺 → 400「缺少必填数值字段 schedule_id」（`http_common.cj:359-363`） |
| `client_token` | String | **是** | **幂等键**。同 token 重放不会重复占号，而是回放同一张挂号单（`AlreadyBooked`）。前端应为每次"点击确认挂号"生成一个稳定 UUID，**重试时复用同一个值** |

> `patient_id` 取自令牌。若令牌里 `patientId <= 0`（例如管理员账号）⇒ **400 VALIDATION_FAILED**
> 「缺少 X-Patient-Id（开发态联调头）」（`http_app.cj:1449-1451`）。
> ⚠ 但管理员账号会先在 `requireCan(p.role, Action.Book)` 处拿到 **403**，所以这条实际主要影响"patient 角色但没绑患者档案"的账号。

**成功**

| HTTP | 场景 | body |
| --- | --- | --- |
| **201** | 首次成功（`Booked`） | `bookingJson` |
| **200** | **幂等回放**（同 `client_token`，`AlreadyBooked`） | **同一张** `bookingJson` |

**错误**

| HTTP | code | 触发 |
| --- | --- | --- |
| 400 | `VALIDATION_FAILED` | 缺 `schedule_id` / 缺 `client_token` / 令牌无患者档案 |
| 404 | `SCHEDULE_NOT_FOUND` | 排班不存在或已停诊（`domain_booking.cj:624-633`） |
| 409 | `SLOT_GONE` | 号源被抢完（`remain_num = 0` 或并发抢光）⇒ **刷新号源，不要自己重试** |
| 401 | `AUTH_*` | 未登录 / 令牌过期 |
| 403 | `FORBIDDEN_ROLE` | 非患者 |

> 并发说明：HTTP 层用 `HTTP_BOOKING_RETRY = 6` 次重试（`domain_booking.cj:79`），
> 但它只对**真正的瞬时错误**（死锁 / 锁等待超时）生效；逻辑层 `MAX_BOOKING_RETRY = 3`（`domain_booking.cj:67`）。
> 扣号与归还都已**去掉 `version` 前置条件**，正常争抢下一次就成功（`domain_booking.cj:429-505`）。
> **客户端不要自己重试 409**：重试也不会成功，应刷新排班列表。

### 5.16 `POST /api/v1/appointments/:id/cancel` —— 退号

* **鉴权**：需要。该接口**不**走 `requireCan`，而是 `canCancel`：管理员可退任意单；
  患者只能退**自己**的单（按 `patient_id` 比对，不是 `user_id`，`http_app.cj:377-389`）。
  实现 `http_app.cj:1467-1515`。

| 参数 | 位置 | 类型 | 说明 |
| --- | --- | --- | --- |
| `:id` | path | Int64 | `appointment_id`；非正数 → 400「挂号单 id 必须是正整数」 |

**成功 `200`** —— `bookingJson`（**退号后重新读库的快照**，不是取消前的旧值，`http_app.cj:1491-1500`）。

**特例：号源归还失败时仍是 `200`**，但 body 额外带（`http_app.cj:1501-1512`）：

| 字段 | 类型 | 值 |
| --- | --- | --- |
| `status` | String | 被强制为 `"cancelled"` |
| `slot_restored` | Bool | `false` |
| `warning` | String | `"号源归还异常，请联系人工处理"` |

> ⇒ **判断退号是否成功必须看 `data.status === 'cancelled'`**（HTTP 200 是恒定的），
> 并在 `slot_restored === false` 时展示 `warning`（提示联系人工，不要让用户反复点退号）。

**错误**

| HTTP | code | 触发 |
| --- | --- | --- |
| 404 | `APPOINTMENT_NOT_FOUND` | 无此单 |
| 403 | `FORBIDDEN_ROLE` | 退别人的单。服务端**明知**这里用 403 会泄露"该单存在"仍选 403，理由是让患者能自我诊断（`http_app.cj:1483-1488`） |
| 400 | `VALIDATION_FAILED` | `:id` 非正整数 |

> * **重复退同一单仍是 200**（幂等）：状态已是 `cancelled` 时不再动号源（`domain_booking.cj:757-772`）。
> * 若上一次 `slot_restored = false`，重试**仍会如实**返回 `slot_restored:false` + `warning`
>   （告警不会被重试抹掉，`domain_booking.cj:757-772`）。
> * ⚠ **退号会把 `client_token` 置 NULL**（`domain_booking.cj:776-794`），唯一索引是
>   `(patient_id, client_token)` ⇒ 退号后用**同一个 `client_token`** 重新挂号是合法的、会真的建新单。
>   **但本文仍建议换新 token**（见 §8.3 的取舍说明）。

### 5.17 `GET /api/v1/medical-records` —— 我的就诊记录（列表，**无正文**）

* **鉴权**：需要；`Action.QueryOwnMedicalRecord`（patient | doctor）。
  患者令牌 `patientId <= 0` ⇒ `403 FORBIDDEN_ROLE`「该账号没有绑定患者档案」（`http_p4.cj:400-416`）。

| 参数 | 类型 | 必填 | 默认 | 说明 |
| --- | --- | --- | --- | --- |
| `limit` | Int64 | 否 | `50` | **只接受 `1..200`**，否则回退 50（`http_p4.cj:406-407`） |

* 成功 `200`：`{ "items": [ medicalRecordJson(includeSections=false) ], "count": N }`
* ⚠ **列表不含病历正文**（无 `sections`），只有进度与时间。

### 5.18 `GET /api/v1/medical-records/:appointmentId` —— 某次就诊病历

* **鉴权**：同 §5.17，且 SQL 层带 `patient_id` 过滤（`findByAppointmentForPatient`，`http_p4.cj:427-451`）。

| 参数 | 位置 | 类型 | 说明 |
| --- | --- | --- | --- |
| `:appointmentId` | path | Int64 | 必须 > 0，否则 400「挂号单 id 必须是正整数」 |

**成功 `200`** —— `medicalRecordJson(m, includeSections=true)`（`http_p4.cj:39-78`）

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | Int64 | 病历 id |
| `appointment_id` | Int64 | |
| `patient_id` | Int64 | 刻意不脱敏（消费方就是数据主体本人，`http_p4.cj:32-37`） |
| `doctor_id` | Int64 | 同上 |
| `status` | String | `draft` / `locked`（`domain_emr.cj:48-49`） |
| `locked` | Bool | |
| `filled` | Int | 已填段数 |
| `total_sections` | Int | 恒 **7** |
| `complete` | Bool | 是否七段都填了 |
| `updated_by` | Int64 | 最后修改者的 `auth_user.id` |
| `created_at` / `updated_at` | Int64 | epoch 秒 |
| `missing_required` | Array\<String\> | 提交锁定前仍缺的**必填**段（空数组 = 可锁定） |
| `sections` | Array | 七段正文，**只有单查才有** |
| `sections[].key` | String | 见 §14.3 |
| `sections[].label` | String | 中文段名 |
| `sections[].value` | String | 正文 |
| `sections[].max_len` | Int64 | 该段字符上限 |
| `sections[].required_to_lock` | Bool | 是否"提交锁定"必填 |

**七个病历段**（`domain_emr.cj:83-92`）

| `key` | `label` | `max_len` | `required_to_lock` |
| --- | --- | --- | --- |
| `chief_complaint` | 主诉 | 2000 | false |
| `present_illness` | 现病史 | 4000 | false |
| `past_history` | 既往史 | 2000 | false |
| `allergy_history` | 过敏史 | 2000 | false |
| `physical_exam` | 体格检查 | 2000 | false |
| `diagnosis` | 诊断 | 2000 | **true** |
| `treatment` | 处理意见 | 4000 | **true** |

**错误**

| HTTP | code | 触发 |
| --- | --- | --- |
| 404 | `EMR_NOT_FOUND` | 病历**不存在**，**或**病历仍是草稿（未锁定）。服务端刻意让两者不可区分（`http_p4.cj:437-450`）⇒ 前端文案应是「病历尚未提交，暂不可查看」而不是「不存在」 |
| 400 | `VALIDATION_FAILED` | `:appointmentId` <= 0 |
| 403 | `FORBIDDEN_ROLE` | 令牌无患者档案 |

**患者端错误诊断表（把状态码映射成"该做什么"）**

| 现象 | 含义 | 前端动作 |
| --- | --- | --- |
| 401 + `AUTH_TOKEN_EXPIRED` | 令牌失效 | 清 token → 登录页 |
| 401 + `AUTH_REQUIRED` | 没带令牌 | 同上（通常是 bug） |
| 403 + `FORBIDDEN_ROLE` | 用非患者账号登了患者端 | 提示「本 App 仅面向患者」并登出 |
| 404 + `PREVISIT_NOT_FOUND` | 会话过期/不属于你/被回收 | 回退到开新会话（复用逻辑见 §7.3） |
| 404 + `EMR_NOT_FOUND` | 病历还没提交 | 显示「尚未提交」 |
| 404 平铺 `{"error":"Not Found"}` | **路径拼错了** | 检查路径（这是 bug，不是业务态） |
| 409 + `SLOT_GONE` | 号没了 | 刷新号源列表 |
| 429 + `AUTH_RATE_LIMITED` | 登录被限流 | 读 `retry-after` 倒计时 |

---

## 5.19+ 2026-10-12 补齐：名称 / 字典 / 公告 / 时区

> 背景：鸿蒙患者端在模拟器上与真服务端联调后，暴露出 8 个"服务端缺"的点，逐项补掉。
> **全部是加法**（老字段一个没删）：既有客户端不改也能继续跑，但要**用上**这些数据
> 需要客户端配合（见每节末尾的「客户端要做什么」）。

### 5.19 `GET /api/v1/health` —— 探活（`/api/v1` 别名）

与 `GET /health` **同一份实现**（`http_app.cj` 的 `healthJson`），响应体一字不差：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `ok` | Bool | 恒 `true`（能回就是活着） |
| `service` | String | `hospital-server` |
| `version` | String | 如 `0.2.0-p1` |
| `data_backend` | String | `mysql` |
| `dev_auth` | Bool | 服务端是否开着 `--dev-auth` |

⚠ 它**刻意不查库**：探活接口查询库会让"库慢"表现成"服务挂了"，而两者的处置完全不同。
⚠ 客户端此前定义了 `HttpClient.getRoot()` 却**没有调用方** ⇒ 建议在启动/保存服务地址时探活一次。

### 5.20 `GET /api/v1/departments` —— 科室字典（三端可读）

| 参数 | 位置 | 类型 | 说明 |
| --- | --- | --- | --- |
| `enabled_only` | query | Bool | 缺省 `false`；`true` 只回启用科室（**患者端应传 `true`**） |

**成功 `200`**：`data = { items: [...], count: N }`

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | Int64 | 科室 id（挂号页 `department_id` 就是它） |
| `name` | String | 科室名（此前患者端只能显示 `科室 #810003`） |
| `code` | String | 科室编码 |
| `location` | String | 位置，可能为空串 |
| `sort` | Int64 | 人工排序权重（小的在前） |
| `enabled` | Bool | |
| `created_at` | Int64 | epoch 秒 |

> **客户端要做什么**：预约页/首页把"手输科室编号"换成**选科室**；就诊列表与病历详情的
> `department_id` 用这里的 `name` 渲染（或直接用 §5.12/§5.14 已经带回的 `department_name`）。

### 5.21 `GET /api/v1/doctors` —— 医生字典（三端可读）

| 参数 | 位置 | 类型 | 说明 |
| --- | --- | --- | --- |
| `department_id` | query | Int64 | 可选；`0`/缺省 = 全部 |
| `enabled_only` | query | Bool | 缺省 `false` |

**成功 `200`**：`data = { items: [...], count: N }`

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | Int64 | 医生 id |
| `name` | String | 医生姓名 |
| `department_id` | Int64 | 所属科室 |
| `department_name` | String | **已拼好**（服务端一次性读全科室建 map，刻意不做 N+1） |
| `title` | String | 职称，如 `主任医师` |
| `specialty` | String | 擅长，可能为空串 |
| `enabled` | Bool | |
| `created_at` | Int64 | epoch 秒 |

> **客户端要做什么**：预约页按科室联动选医生；`doctor_title` 可用于列表副标题。

### 5.22 `GET /api/v1/notices` —— 公告（三端可读）

| 参数 | 位置 | 类型 | 说明 |
| --- | --- | --- | --- |
| `limit` | query | Int64 | `0`/缺省 = 服务端默认（20）；上限 200 |

**可见性**：只回 `enabled = 1` **且** `published_at <= now` 的公告（支持预排期）。

**成功 `200`**：`data = { items: [...], count: N }` —— 字段与客户端 `PatientNotice` 模型对齐

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | Int64 | |
| `title` | String | 标题（**唯一**：同名公告不允许重复建，避免两条互相矛盾） |
| `body` | String | 正文（纯文本，不含 Markdown） |
| `category` | String | 分组标签，如 `就诊提醒` / `健康提示` / `服务说明`（缺省 `通知`） |
| `date` | String | `YYYY-MM-DD`，**Asia/Shanghai**（直接显示用这个） |
| `published_at` | Int64 | epoch 秒（需要精确排序时用） |
| `sort` | Int64 | 人工权重（小的在前） |

> **客户端要做什么**：把 `PatientRepository.notices()` 从"无条件 `MockPatientRepository.notices()`"
> 改成在线模式走本端点（离线/演示模式仍可用 mock）。

### 5.23 管理端公告（仅 admin）

`GET /api/v1/admin/notices?include_disabled=&limit=` / `POST /api/v1/admin/notices` /
`GET|PUT|DELETE /api/v1/admin/notices/:id`。管理端 JSON **多出**
`enabled` / `updated_by` / `created_at` / `updated_at`。
**PUT 不传 `published_at` 时保持原发布时间**（改错别字不会把预排期公告提前发出）。
>` 客户端**不得**出现这些路径（见 §6.1）。

### 5.24 本次变更的既有端点字段（增量）

| 端点 | 新增字段 | 为什么 |
| --- | --- | --- |
| `GET /api/v1/auth/me`（§5.3） | `display_name` | 此前只回 id/role，患者端「同步身份信息」刷不出姓名 |
| `GET /api/v1/schedules`（§5.12） | `department_name` `doctor_name` `doctor_title` `version` | 患者端此前只能显示 `科室 #810003 · 医生 #900003`；`version` 供"号源已变化"提示（`/schedules/:id` 早就给了） |
| `GET /api/v1/appointments`（§5.14） | 同上三个名称 | 首页「下一次就诊」/就诊列表 |
| `POST /api/v1/appointments`（§5.15） | 名称三个 + `remain_num` | 挂完号**就地刷新「余 N」**，不必再发一次排班查询 |
| `POST /api/v1/appointments/:id/cancel`（§5.16） | 名称三个 + `remain_num` | 同上（退号后号源归还数） |
| `GET /api/v1/medical-records`（§5.17） | `department_id` `visit_date` `period` + 名称三个 | 档案列表此前连"看的哪个科、哪天"都没有 |
| `POST /api/v1/triage`（§5.8） | —（文案变更） | `patient_note` 里的 Markdown `**` 已去掉：原样显示会变成 `以下是**其它有号**的科室` |

### 5.25 时间口径：服务端「今天」= **Asia/Shanghai**

此前服务端算"今天"用的是 **UTC**，而客户端用本机日期 ⇒ 在中国（UTC+8）每天
**00:00–08:00** 这 8 小时里两者**差一天**：服务端认为"今天"还是昨天，
患者早上打开 App 时**当天上午的号会被判成"过去"而排不出来**。

现已在服务端统一为 `HOSPITAL_TZ_OFFSET_SECONDS = 8 * 3600`（`http_app.cj`），
`hTodayDate()` / `hDateStringOf()` / 看板的默认日期窗（`dashboard.cj`）全部同一口径，
并由 `selftest` 用**固定 epoch** 钉住（含"UTC 10-11T16:30 在上海应算 2026-10-12"这条跨零点断言）。

⚠ 客户端 `Theme.todayString()` 用的是**设备本地日期**：设备时区若被设成非中国时区，
仍可能出现跨零点不一致（建议客户端显示"今天"时以服务端 `date` 字段为准）。

---

## 6. 不能调的端点（前端不应出现这些路径）

以下端点**确实存在**，但权限矩阵把它们挡在患者之外（`http_app.cj:162-230`）。
患者端代码里**不得出现**这些路径。若在 `--dev-auth` 下用身份头绕过，那是配置事故，不是契约。

### 6.1 管理端 `/api/v1/admin/**` —— 全部需要 `admin`

| 方法 + 路径 | 关键点 | 源码依据 |
| --- | --- | --- |
| `POST /api/v1/admin/users` | 建账号。body `login_name`/`password`/`role`/`ref_id`/`display_name?`；patient/doctor 必须给 `ref_id > 0`；登录名已存在 → **409 `USER_EXISTS`**；**201** `{user_id, role}` | `http_app.cj:897-950` |
| `GET /api/v1/admin/users?login_name=` | `login_name` 必填，否则 400；**绝不返回盐/摘要**（只回 user_id/login_name/role/ref_id/display_name/status） | `http_app.cj:960-979` |
| `POST /api/v1/admin/users/:id/password` | `:id` 是 `auth_user.id`（**不是 `ref_id`**）；会**吊销该账号全部令牌**；账号不存在 → 404 | `http_app.cj:989-1007`、`auth_repo.cj:568-583` |
| `POST /api/v1/admin/schedules` | body `doctor_id`/`department_id`/`work_date`/`period`/`total_num`；**201** `{schedule_id,total_num,remain_num}` | `http_app.cj:1523-1543` |
| `GET /api/v1/admin/ai/settings`、`PUT/DELETE /api/v1/admin/ai/settings/:key` | AI 配置中心；**密钥绝不回显**（只回"是否已设置 + 引用类型"） | `http_app.cj:1029-1136` |
| `GET /api/v1/admin/ai/prompts`、`PUT/DELETE /api/v1/admin/ai/prompts/:name` | Prompt 模板 CRUD（正文原样回显，它不是机密） | `http_app.cj:1066-1098` |
| `GET /api/v1/admin/ai/tools`、`PUT /api/v1/admin/ai/tools/:name` | 工具开关；`enabled` **只接受 JSON 布尔** | `http_app.cj:1101-1126` |
| `GET/POST /api/v1/admin/departments`、`GET/PUT/DELETE /…/:id` | 科室 CRUD（`manage_base_data`） | `http_base.cj:172-256` |
| `GET/POST /api/v1/admin/doctors`、`GET/PUT/DELETE /…/:id` | 医生 CRUD | `http_base.cj:260-333` |
| `GET/POST /api/v1/admin/kb/docs`、`GET/PUT/DELETE /…/:id`、`GET /api/v1/admin/kb/stats` | 知识库 CRUD | `http_kb.cj:146-250` |
| `GET/POST /api/v1/admin/notices`、`GET/PUT/DELETE /api/v1/admin/notices/:id` | 公告 CRUD（`manage_notice`）；`?include_disabled=` 可见停用/预排期；**PUT 不传 `published_at` 则保持原发布时间** | `http_notice.cj:167-243` |
| `GET /api/v1/admin/dashboard` | 运营看板，**只出计数、绝不含患者 id/姓名/电话** | `http_p4.cj:466`、`dashboard.cj:240-245` |

### 6.2 医生端 `/api/v1/doctor/**`

| 方法 + 路径 | Action | 源码依据 |
| --- | --- | --- |
| `GET /api/v1/doctor/visits` | `manage_visit` | `http_p4.cj:181` |
| `POST /api/v1/doctor/visits/:id/start` \| `/finish` \| `/no-show` | `manage_visit` | `http_p4.cj:204/224/245` |
| `GET` / `PUT /api/v1/doctor/visits/:id/record` | `query_own_medical_record` / `write_own_medical_record` | `http_p4.cj:265/291` |
| `POST /api/v1/doctor/visits/:id/record/lock` | `write_own_medical_record` | `http_p4.cj:339` |
| `POST /api/v1/doctor/visits/:id/record/reopen` | **`manage_schedule`（管理员）** —— 医生端也不能解锁 | `http_p4.cj:363` |

### 6.3 刻意对患者 403 的一个"看似通用"端点

| 方法 + 路径 | 为什么患者不能用 |
| --- | --- |
| `GET /api/v1/kb/search?q=&top=` | 需要 `query_knowledge_base` = **admin \| doctor**（`http_app.cj:206-218` 明确记录「患者不给」：知识库是内部运营材料，患者只应在分诊结果里看到被引用的片段）。`top` 被夹到 `[1,20]`，默认 5；返回 `{items:[{doc_id,chunk_id,seq,title,category,content,score,source}], count, source, scanned, missing_vectors}`（`http_kb.cj:254`） |

> 另外提醒：`POST /api/v1/triage`、`GET /api/v1/previsit/*`、`GET/POST /api/v1/appointments*`
> 都要求 `book` = **仅 patient**。**医生/管理员账号调这些会拿到 403** ——
> 用管理员账号登录去点分诊页报错是**正常的，不是 bug**（实测：管理员调 `/triage` → 403）。
> ⚠ 不要与 `POST /api/v1/admin/schedules`（建排班）写混。

---

## 7. SSE 预问诊专章

### 7.1 端点与请求

```
GET /api/v1/previsit/stream?chief_complaint=<URL 编码的主诉>
Authorization: Bearer <patient token>
```

| 参数 | 位置 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- | --- |
| `chief_complaint` | query | String | 否 | 非空时会作为**第 1 个槽位 `chief` 立即落库**（`http_app.cj:1250-1252`）。超过 **200 字符**会被**按字符**截断（`http_app.cj:1244-1247`、`previsit.cj:625-634`） |

* 鉴权：`Action.Book` ⇒ **仅 patient**。实现 `http_app.cj:1239-1285`。

**响应头**（实测）：`content-type: text/event-stream; charset=utf-8`、
`transfer-encoding: chunked`、`cache-control: no-cache`（`context.cj:304-306`）。

### 7.2 线格式（**这一步做错就全崩**）

帧由 `sseFrame(event, payload)` 构造（`previsit.cj:611-616`）：

```cangjie
return "data: ${o.toString()}\n\n"   // o = {"event":…, "data":{…}}
```

⇒ 线上字节形如（下面 `\n` 是两个真实字节 `0x0A`；**每帧恰好一行 + 一个空行**）：

```text
data: {"event":"meta","data":{"session_id":"ab12…64hex…","turn":1,"total_slots":6}}\n\n
data: {"event":"delta","data":{"text":"明白了，您主要是「咳嗽三天」。"}}\n\n
data: {"event":"delta","data":{"text":"为了帮医生更快了解情况，我再问几个问题，一共 6 项。"}}\n\n
data: {"event":"delta","data":{"text":"第 2/6 项：这个情况持续多久了？"}}\n\n
data: {"event":"delta","data":{"text":"（例如：3 天、2 周、半年）"}}\n\n
data: {"event":"done","data":{"session_id":"ab12…","next_slot":"duration"}}\n\n
```

**四条硬性要求**：

1. **必须严格按 `\n\n` 分帧**：`\n` 只是行结束，`\n\n` 才是"事件结束"。少一个 `\n` 客户端会一直等下一行
   （表现为"卡住不动"，`previsit.cj:608-609`）。
2. **帧内不会有裸换行**：payload 是 **JSON 字符串**，服务端把内部换行转义成 `\n` 两个字符
   （`previsit.cj:599-607`，并有测试断言"帧内不含裸换行"）。**所以不要按行拆文本再拼 JSON**——
   要剥掉前缀 `data: ` 后整体 `JSON.parse`。
3. **帧可能被 TCP 分片切开**：一次 `on('dataReceive')` 回调**不等于**一帧；多字节汉字也可能被切在中间。
   ⇒ 必须**整段解码**（ArkTS 用 `buffer` 累积 + `TextDecoderStream`/`util.TextDecoder`，
   或把收到的 chunk 累积成字节缓冲区，再按 `\n\n` 的字节序列（`0x0A 0x0A`）切分并逐一 UTF-8 解码）。
   ⚠ 先 `toString()` 再找 `\n\n` 在汉字跨 chunk 截断时会产生替换字符（U+FFFD）。
4. `transfer-encoding: chunked` ⇒ 无 `content-length`，不要试图先读长度。

**帧内业务对象在 `data` 里又包了一层**：外层是 `{event, data}`，业务字段在**内层 `data`**。

| 事件 | 内层 payload 字段 | 说明 |
| --- | --- | --- |
| `meta` | `session_id` String（64 hex）、`turn` Int、`total_slots` Int（恒 6） | **第一帧**。必须先拿到 `session_id` 才能调 §5.10 / §5.11 |
| `delta` | `text` String | 一句对话文本；**一帧一句**，客户端按序追加渲染 |
| `done` | `session_id` String、`next_slot` String（完成时 `""`） | **终止帧**，显式结束，**不必靠连接关闭判断** |

> 实测（`server/tests/previsit-check.ps1`）：`chief_complaint=咳嗽三天` 时响应体 **394 B、4 帧**
> （meta + 2 delta + done），每帧恰好 1 行、帧间空行分隔，`session_id` 为 64 位 hex。
> 帧数**不固定**：delta 条数取决于会话状态与是否给了主诉（完成时会输出 3 条 delta，见 `previsit.cj:565-570`）。

### 7.3 `session_id` 的复用与回收（决定前端是"一个会话走到底"还是"每次重开"）

| 阈值 | 值 | 依据 |
| --- | --- | --- |
| 同一患者**未完成**会话上限 | `PREVISIT_MAX_OPEN = 5` | `previsit.cj:134` |
| 同一患者**已完成**会话上限 | `PREVISIT_MAX_DONE = 50` | `previsit.cj:143` |
| 未完成会话闲置回收 | `PREVISIT_ABANDONED_TTL = 1800` s（30 分钟） | `previsit.cj:125` |

* 每次 `create()`（即每次开新流）都会**顺手** `pruneStale()`（清闲置未完成会话）与
  `capSessions()`（超上限丢最旧的未完成会话），`previsit.cj:322-388`。
* 已完成的会话是**医疗记录素材**，不在 `pruneStale` 里删，只受 `PREVISIT_MAX_DONE` 约束。
* ⇒ **反复开新流会挤掉最旧的未完成会话**。前端应把 `session_id` **持久化并复用**：
  进入预问诊页时先 `GET /api/v1/previsit/:id`，404 才开新流（`session_id` 只在当次响应的 `meta` 帧里给出）。
* ⚠ 会话不可恢复成"接着答"的交互之外用途：服务端**没有**"列出我的预问诊会话"接口（见 §9 缺口）。

### 7.4 多轮推进的业务语义

* 采集顺序固定为 §5.10 的六项；推进判据是"**该槽位当前有没有值**"，不是 `turn`
  （`previsit.cj:239-253`）⇒ **重复提交同一槽位是幂等的**（网络重试不会跳过一个字段）。
* **空 `value` 不落库、不推进 `turn`**（`previsit.cj:451-460`）：
  - 「跳过此项」= **不提交**（或提交空串，等价于什么都没发生）；
  - 「无」= **有效阴性答案**，会被真实写入 —— 前端必须提供「无」的快捷项。
* 超过 `maxLen`（按**字符**）→ 400「字段 \<slot\> 超出长度上限」。
* **`form` 只在 `complete == true` 时出现**（`http_app.cj:719-727`）：未完成时只给
  `filled`/`total_slots`/`next_slot`/`next_question` 做进度，**不给半成品表单**
  （理由：半成品表单可能被当成"已完成的就诊前信息"提交给医生，`http_app.cj:695-701`）。
* 完成后的 `delta` 文案里有一句**免责声明**（"不能替代医生诊断"），`previsit.cj:565-568`——
  前端渲染时**不要过滤掉**。

### 7.5 流式错误怎么读

* 流**尚未开始时**出错走正常信封（`401` / `403`）。
* 会话创建后立即读回失败会抛 `apiErrorMsg("INTERNAL", …)`，该码**未登记** ⇒ **500 / `服务器内部错误`**
  （`http_app.cj:1256`）。
* 已经进入流式模式后**不可能**再走 `sendOk/sendError`（会二次写响应体，`http_app.cj:1283-1284`）
  ⇒ 流中断只能靠**连接关闭**判断（没有 `error` 帧类型）。
  **前端必须给流设置超时与重试**，并把"未收到 `done` 帧"当成失败。

---

## 8. 挂号的关键语义（这一节决定"会不会造脏单"）

### 8.1 `client_token` 是幂等键

* 幂等由**两层**保证（`domain_booking.cj:21-32`）：
  ① 应用层按 `(patient_id, client_token)` 查**仍有效**（`status <> 'cancelled'`）的既有单 → 命中即回放；
  ② 数据库唯一索引 `(patient_id, client_token)` 兜底并发（撞索引后回读既有单，`domain_booking.cj:659-676`）。
* ⇒ 同 token 重放：**200** + 同一张 `bookingJson`；首次成功：**201**。
* ⇒ 同 token **跨患者互不影响**（2026-10-07 修的跨患者泄露缺陷，`domain_booking.cj:209-233`）。
* ⚠ 幂等键在**用户点击那一刻**生成并缓存，直到请求成功为止。**失败重试必须复用同一个值**，
  否则号源紧张时会重复占号。
* ⚠ **换号源必须换新 token**：`client_token` 代表"一次挂号意图"，复用它去挂另一个 `schedule_id`
  只会回放原来那张单（`AlreadyBooked` 快路径只按 `(patient_id, client_token)` 查，**不看 schedule_id**，`domain_booking.cj:234-246`）。
  这是最容易踩的一条：**用户改选了另一个号源，前端必须重新生成 token**。

### 8.2 退号

* `POST /api/v1/appointments/:id/cancel` **永远返回 200**（单存在且权限通过时）：
  成功与否**必须看返回体的 `status === 'cancelled'`**。
* `slot_restored: false` 时要展示 `warning`（`"号源归还异常，请联系人工处理"`）。
* 重复退同一单仍是 200（幂等），且**不会抹掉**上一次的 `slot_restored:false` 告警
  （`domain_booking.cj:757-772`）。
* 服务端**退号会把 `client_token` 置 NULL**（`domain_booking.cj:776-794`）：
  唯一索引 `(patient_id, client_token)` 因此被释放。

### 8.3 "退了再挂"要不要换 token？—— 一个必须说清的取舍

源码事实：**同一个 token 重新挂号是合法的**（会真的建新单，不会撞唯一键，`domain_booking.cj:776-794`）。

但本文**建议仍然换新 token**，理由：

* "同一个 token = 同一次意图"是幂等键的语义（`domain_booking.cj:229-233`）。
  退号是**终结**了那一次意图，重新挂号是**新的一次**意图；
* 服务端不保留"当初是哪个 token 建的"这条信息（置 NULL 的代价，源码如实记录），
  所以前端**无法**从服务端回读去判断"这个 token 是不是已经用过"；
* 换 token 的成本是 0（一行 UUID），而不换 token 的唯一收益是"理论上可以少生成一次"。

### 8.4 `SLOT_GONE` 的正确处置

* 409 `SLOT_GONE` = 号源被抢完（`remain_num = 0` 或并发抢光）。
* **刷新号源列表**，不要自己重试：`book()` 对"扣号返回 0 行"是**直接返回 SlotGone**，
  并不重试（`domain_booking.cj:694-701`），重试只会拿到同样的结果。
* 注意：`tryDeductSlot` 的 SQL 条件是 `remain_num > 0 AND enabled = 1`（`domain_booking.cj:459-465`），
  所以**停用的排班**也会表现为 `SLOT_GONE`（而不是 `SCHEDULE_NOT_FOUND`）：
  `findSchedule` 命中但 `enabled = false` 时 `book()` 返回 `ScheduleNotFound`（`domain_booking.cj:630-633`），
  而"读到时 enabled=1、扣减时被改成 0"会落到 `SLOT_GONE`。两种都要能用 UI 表达。

---

## 9. 服务端缺口（前端必须先知道，否则会白写页面）

> 这些是写前端时最容易撞墙的地方。**请在实现对应界面之前先确认服务端是否补齐。**

| # | 缺口 | 影响哪个页面 | 现在的替代做法 / 证据 |
| --- | --- | --- | --- |
| 1 | ~~**没有患者可读的科室列表**~~ ✅ **已补齐 2026-10-12** | 「选科室挂号」现在可以独立构建 | 补了 `GET /api/v1/departments`（三端可读，见 §5.20）。管理端仍走 `/api/v1/admin/departments` |
| 2 | ~~**没有患者可读的医生列表 / 详情**~~ ✅ **已补齐 2026-10-12** | 号源列表可以显示「P4测试医生900003 主任医师」 | 补了 `GET /api/v1/doctors`（三端可读、带 `department_name`，见 §5.21） |
| 3 | ~~**排班无科室名/医生名联表**~~ ✅ **已补齐 2026-10-12** | 同上 | `GET /api/v1/schedules` 现在回 `department_name` / `doctor_name` / `doctor_title` / `version`；`GET /appointments`、`/medical-records`、挂号与退号响应同样补齐（§5.24） |
| 4 | **没有 `GET /api/v1/appointments/:id` 单查** | 无法深链到单张挂号单；从推送直接打开详情做不到 | 只有列表 `GET /api/v1/appointments`。⇒ 详情页要么从列表点入带上完整对象，要么本地缓存 |
| 5 | **没有患者自助注册** | 无法做注册页 | 只有 `POST /api/v1/admin/users`（`http_base.cj` 文件头明确记录 patient CRUD 被刻意排除，PII / 个保法）。⇒ 患者账号必须由院内前台建 |
| 6 | **没有患者改密 / 忘记密码** | 无法做"安全设置"页 | 只能找管理员走 `POST /api/v1/admin/users/:id/password`（会踢下线） |
| 7 | **没有令牌刷新接口**（且不需要） | —— | 30 天 TTL + 服务端滑动续期（`auth_repo.cj:754-792`）。**不要去实现 `/auth/refresh`** |
| 8 | **没有真正的分页** | 长列表无法"加载更多" | 只有 `limit`（超限**静默夹住**），无 `total` / `cursor` / `page`。⇒ 只能靠 `count == limit` 猜"可能还有更多"，并用 `work_date` 等条件把结果集收窄 |
| 9 | **排班不做"未来过滤"** | 「今日可约」会混入历史排班 | `domain_booking.cj:311-326` 无时间条件。⇒ 客户端必须自己按 `work_date` 过滤。**服务端的"今天"已改为 Asia/Shanghai**（§5.25，与北京时间一致） |
| 10 | **没有按名搜索科室/医生** | 无法做搜索框 | 只能按 `department_id` 精确过滤，且需要先知道 id（而缺口 1 让前端拿不到 id 列表） |
| 11 | ~~**没有消息 / 推送端点**~~ ✅ **公告已补齐 2026-10-12**（推送仍未做） | 消息中心 / 首页「医疗公告」 | 补了 `GET /api/v1/notices`（三端可读）+ 管理端 CRUD（§5.22/§5.23）。⚠ **到诊提醒这类主动推送仍没有** ⇒ 本地通知 + 本地保存的 `visit_date`/`period` |
| 12 | **没有"这单还能不能退"的判定字段** | 退号按钮无法准确置灰 | 无 `can_cancel` 字段。`bookingJson` 里只有 `status`；服务端**不校验是否已过就诊时间**。⇒ 用 `status === 'booked'` 粗略判断，并对 403/404 做兜底提示 |
| 13 | **分诊结果无法跳详情** | `options` 给了 `department_id`/`doctor_id`，但没有详情页可取（缺口 1/2） | ⇒ 分诊结果页**直接就地展示号源并允许挂号**，不做"科室详情"跳转 |
| 14 | **没有 AI 流式分诊** | 分诊页不能做逐字输出 | 只有预问诊是 SSE；`POST /api/v1/triage` 是一次性 JSON（`http_app.cj:1157-1223` 无 stream 分支）。⇒ 分诊页用 loading 态即可 |

> 另有一条"半个缺口"：`GET /api/v1/previsit/:id` 能按 `session_id` 取单，但**没有"列出我的预问诊会话"**
> 接口（`http_app.cj` 里只有 3 条 previsit 路由）⇒ 客户端必须自己持久化 `session_id`。

---

## 10. 前端工程注意

### 10.1 传输安全：release 必须 HTTPS

* 服务端默认是**明文 HTTP**，启动日志会明确警告"令牌与口令会明文过网"（`main.cj:838-840`）。
* 只要处理**患者标识**（`patient_id`）与**病历正文**，release 构建就**必须**走 HTTPS；
  明文 HTTP **只应出现在 debug**。
* 服务端 TLS 是显式开启且**绝不静默降级**（`main.cj:786-836`）⇒ 前端**不能靠探测**判断协议，
  必须由构建配置（如 HarmonyOS 的 product 维度）写死 base URL。
* 自签证书需要客户端的网络信任配置；正式环境必须换受信证书。
* ⚠ 令牌与口令都是**不透明但敏感**的凭据：不要写进日志、不要放进 URL query。

### 10.2 `RED_FLAG` 的正确处理（医疗安全相关）

* 分诊返回 `red_flag === true` 时，服务端**保证 `options` 为空**（实测 `count = 0`）。
* 前端**不得自己拼号源、也不得展示任何"推荐科室"**：唯一正确的动作是
  **强提醒 + 引导急诊/人工**（`triage.cj:86-88`、`http_app.cj:633-636`）。这是产品级红线。
* 服务端**刻意不返回**命中的危急关键词（`red_flag_evidence` 只在服务端日志/审计），
  ⇒ 前端**不要**试图复述"因为您说了胸痛"。

### 10.3 在线强一致：不要做离线补发队列

* **分诊**与**预问诊**都是在线强一致操作：
  - 预问诊的答案落库即状态推进（`previsit.cj:461-474`），离线补发会让 `turn`/`filled` 与服务端错位；
  - 分诊结论会被用于挂号，结论过期必须重算。
* **挂号**更不能离线补发：`client_token` 幂等只覆盖"同一意图重试"，覆盖不了"网络恢复后重放一个旧意图"
  ⇒ 会制造脏单（重复占号 / 用户拿到两张单）。
* 正确做法：请求失败时**明确告知用户**，并把 `client_token` 保留到该次挂号意图结束（成功或用户放弃）。

### 10.4 日期与"今天"的口径差异

* 服务端 `hTodayDate()` 用 **UTC**（`http_app.cj:566-584`），返回 `YYYY-MM-DD`。
* 客户端拼 `work_date` 用**本地时区** ⇒ 跨零点时服务端"今天"可能比本地**早一天**。
  现象：本地以为"今天的号"查不到（分诊的号源筛选用的是服务端 UTC 今天）。
* ⚠ 服务端**没有任何接口**返回"服务端的今天"（`/health` 不返回日期），所以客户端**无法**拿到那个 UTC 日期。
* 建议：客户端做"今天之后"过滤时，**不要假设服务端的今天**——用本地日期做一次宽松过滤（例如保留 `>= 本地今天 - 1 天`），
  并以**分诊返回的 `work_date`** 为权威来展示与排序；"当天号查不到"最终以分诊 `reason_code` 为准（`NO_BOOKABLE` = 真的没号）。

### 10.5 网络层工程约定（非契约）

1. **统一封装解析器**：按 §3.2 的三段式判断（先判 `ok` 是否存在），抛 `ApiError{code,message,fields}`。
2. **单一 401 拦截器**：清 token → 跳登录页。不要在每个页面各写一次。
3. **`role` 分流**：登录后按 `role` 决定进患者首页还是提示「本 App 仅面向患者」。
   **不要用 `patient_id` 判角色**（§4.2）。
4. **不要解析 token**：不透明字符串，长度 64 hex。
5. **记录 `x-request-id`**：每个响应都带（32 位 hex），CORS 也显式暴露了它（`cors.cj:35-36`）。
   报障时带上它能直接对到服务端日志。
6. **SSE 客户端**：按 §7.2 的四条硬性要求实现；给流设置超时；未收到 `done` 视为失败。
7. **超时**：服务端 `timeout(15000)` 不会打断慢 handler（只补 408 或加 `x-timeout-ms` 头）
   ⇒ **客户端自己设 10~15 s 超时**更可靠。
8. **错误文案**：优先按 `error.code` 分支；`message` 只用于兜底展示（服务端文案可能变）。

---

## 11. 本仓文档口径提示（读别的文档前先读这段）

本仓库历史上存在多份交接文档（`server/README.md`、`docs/P1-HANDOFF.md`、`docs/P4-HANDOFF.md` 等），
它们与实现存在若干出入。**以源码为准**。已发现的 7 条（已核到 `file:line`）：

| # | 文档说法 | 实现事实 | 本文口径 |
| --- | --- | --- | --- |
| 1 | `server/README.md` 的启动示例用 `--port 8091` / `8443`，容易让人以为这是默认端口 | **默认端口是 8080**（`main.cj:556`）；8091/8443 只是启动参数约定 | §1、§2.2 明确写"默认 8080，8091/8443 只是约定" |
| 2 | 一般文档措辞会让人以为"患者可搜知识库" | `GET /api/v1/kb/search` 需要 `query_knowledge_base`（admin\|doctor）⇒ **患者 403**（`http_app.cj:206-218` 有明确设计说明） | §6.3 |
| 3 | `docs/P4-HANDOFF.md` 未提 `record/reopen` 的实际鉴权 | `http_p4.cj:363` 用 `requireCan(p.role, Action.ManageSchedule)` ⇒ **reopen 是管理员动作，医生也 403** | §6.2 |
| 4 | 登录响应里的 `patient_id` 容易被读成"患者 id" | 实现是 `u.refId` 且**不判角色**（`http_app.cj:774`）⇒ 医生/管理员登录时它只是各自的档案 id | §4.2（含实测） |
| 5 | 错误码表里可能登记着 `AUTH_TOKEN_INVALID` | **`apiErrorSpec` 里没有这个码**（`http_common.cj:55-197`）：令牌无效/过期一律 `AUTH_TOKEN_EXPIRED` 401，message「令牌无效或已过期，请重新登录」（`http_app.cj:313-316`） | §14.1 只列实现里真实存在的码 |
| 6 | 文档写"连续失败 5 次后锁定"，容易被读成"第 6 次才 429" | 实现在 `recordFailure` 之后判 `fail_count >= 5` ⇒ **第 5 次失败就返回 429**（`auth_repo.cj:381-386`）。实测确认 | §4.2 |
| 7 | 错误码表里登记着 409 `SLOT_NOT_RESTORED` | 该码在当前实现路径中**不会被抛出**（**死条目**）：归还失败走的是 **200 + `warning`**（`http_app.cj:1501-1512`）。`apiErrorSpec` 里有它，但没有任何 handler 抛它 | §14.1 标"死条目"；§5.16 写清实际形态 |

> 另外两条**版本口径**提示：
> * `version` 返回 `"0.2.0-p1"`（`main.cj:31`），但功能上 P2（分诊/预问诊）/P4（病历/接诊/看板）/P5（知识库）
>   都已实现 —— **不要按版本号做能力判断**。
> * `server/README.md` 的端点清单只列了 P1 的 10 个，**不是全部端点**；本文 §5/§6 按源码路由表整理。

---

## 12. 附：本机端到端实测记录

> **以下为 2026-10-11 实测**，服务端 `hospital-server.exe` 跑在 `127.0.0.1:8091`，
> 库为 `hospital_test@127.0.0.1:3317`。脚本在 `server/tests/`，**可复现**。
> ⚠ 诚实标注：既有 5 个测试脚本**全绿**（`auth-check` / `triage-check` / `previsit-check` /
> `stress-booking` / `rate-limit-check`，合计 25 + 24 + 86 + 8 + 16 项断言）；
> 而**手工裸探测**只完成 `health` / `login` / `429` 三项。
> **SSE 原始字节、answer 空值语义、挂号幂等与退号 token 复用**这三条是由**既有脚本断言**覆盖的，
> **没有独立的手工原始字节证据** —— 不要把它读成"全部手工验证过"。

### 12.1 `GET /health` 原始返回

```json
{"ok":true,"service":"hospital-server","version":"0.2.0-p1","data_backend":"mysql","dev_auth":false}
```

* 平铺、**无信封**、**不在 `/api/v1` 下**（实测 `GET /api/v1/health` → 404）。
* 是 `content-length: 100` 的普通 JSON，**不是 chunked**（只有 `/previsit/stream` 是 chunked）。

### 12.2 `auth-check.ps1`（25 项）

* **无令牌访问业务接口 → 401，错误码 `AUTH_REQUIRED`**。
  ★ 与契约核对：一致（`http_app.cj:346` 抛 `AUTH_REQUIRED`，message「缺少 Authorization: Bearer \<token\>」）。
* 错误口令 → 401；**账号不存在 → 同一个错误码**（防枚举）；计时比 **1.20**（< 2 判为防枚举成立）。
* 乱令牌 → 401（`AUTH_TOKEN_EXPIRED`）。
* 管理员重置口令后**旧令牌立即失效 → 401**；旧口令登录失败 → 401；新口令登录成功 → 200。
* 登出 → 200；**登出后同一令牌 → 401**。
* 患者建排班 / 建账号 → **403 `FORBIDDEN_ROLE`**；患者查排班**不是 403**（有则 200 / 无则 404）。
* 不存在的账号查 `/admin/users` → 404 `USER_NOT_FOUND`。

### 12.3 `rate-limit-check.ps1`（16 项）

* `LOGIN_FAIL_LIMIT = 5`；**第 5 次失败即刻 429 `AUTH_RATE_LIMITED`**（不是第 6 次）。
* 锁定期内响应约 **0.045 s**（未跑 PBKDF2）vs 正常登录约 **0.55 s**。
* 大小写 / 首尾空格共 **7 种等价写法**都被归一到**同一计数行**（`normalizeLoginName`，`auth_repo.cj:131-139`）。
* **不存在的登录名同样第 5 次起 429**（⇒ 不是账号枚举 oracle）。
* 成功登录**清零**计数。
* `retry-after` 在同一锁定窗口内递减（实测 900 → 899）；不同账号互不影响（锁 A 时 B 用正确口令照常 200）。

### 12.4 `triage-check.ps1`（24 项）

* 管理员调 `POST /api/v1/triage` → **403**（患者侧接口）。
* 缺 `chief_complaint` → **400 `VALIDATION_FAILED`**；**空白主诉 → 200 `reason_code=NO_COMPLAINT`**。
* 危急 → `red_flag=true`、`count=0`（**一个号源都不给**），响应里**不含**内部依据 `red_flag_evidence`。
* 号满的排班**不出现**在 `options`（`reason_code=ALTERNATIVES count=1`）；有号后能推荐（`reason_code=OK`、`remain_num=3`）。
* `source=rules`。
* **1200 字主诉 → 200 且 `truncated=true`**（不是 500）。

### 12.5 `previsit-check.ps1`（86 项，含 SSE）

* 响应头：`content-type: text/event-stream; charset=utf-8`、**chunked**、`cache-control: no-cache`。
* 响应体 **394 B、4 帧**（meta + delta… + done）；**每帧恰好 1 行、帧间空行分隔**。
* `session_id` 是 **64 位 hex**。
* 未采完时响应**没有** `form` 字段；**6 项采完才出现** `form`。
* 未知槽位 / 超长值 → **400**。
* **长度按字符算**：60 个汉字 → 200，61 个汉字 → 400（即使 61 字 = 183 字节）。
* 空白答案（`"   "`）语义：不写入、不推进（对应源码 `previsit.cj:445-460` 的 `trimAscii` + 空值分支）。
* **不存在的 `session_id` → 404**；**别人的有效 `session_id` → 同样 404**（`PREVISIT_NOT_FOUND`，刻意不可枚举）。

### 12.6 `stress-booking.ps1`（8 项）

* 20 并发抢 20 个号 → **201 × 20**；`remain_num = 0`；有效挂号单 **20**；余量守恒；**无超卖、无 5xx**。

### 12.7 未覆盖（如实标注）

| 主题 | 状态 |
| --- | --- |
| SSE **原始字节**逐字节核对（`\n\n` 的字节序列、汉字跨 chunk 切分） | **由脚本断言覆盖**（帧计数 + 每帧 1 行 + 空行分隔），**无独立手工原始字节证据** |
| `POST /previsit/answer` **空值语义**（空串不落库、不推进 `turn`） | **由脚本断言覆盖**，无独立手工证据（源码 `previsit.cj:451-460`） |
| 挂号**幂等重放**与**退号后 token 复用** | **由脚本断言覆盖**（`stress-booking` 的重复提交用例、`p1-extra-check` 的退号用例），无独立手工证据 |
| §3.2 的"非法 JSON 平铺 400"与"未知路径平铺 404" | **源码级**（`bodyparser.cj:50-54`、`router.cj:202-212`）确认，但**未在本次实测中手工复现** |
| §3.5 的"非法 JSON 的 400 不带 CORS 头" | **源码级**推理（`bodyParser` 在 `cors()` 之前短路），**未实测** |

---

## 13. 附：手工验证与工具坑

### 13.1 手工验证配方

```bash
# 1) 探活（若为 false 说明不是开发态，符合预期）
curl -s http://127.0.0.1:8091/health

# 2) 登录（JSON 一定用文件传给 curl，见 §13.2）
printf '%s' '{"login_name":"admin","password":"<口令>"}' > /tmp/login.json
curl -s -X POST http://127.0.0.1:8091/api/v1/auth/login \
  -H "Content-Type: application/json" --data-binary @/tmp/login.json

# 3) 带令牌查身份
curl -s http://127.0.0.1:8091/api/v1/auth/me -H "Authorization: Bearer <token>"

# 4) 故意打错路径 —— 看平铺 404（对比业务 404 的形状差异）
curl -s -i http://127.0.0.1:8091/api/v1/aprpointments -H "Authorization: Bearer <token>"
```

### 13.2 三个"后人必踩"的工具坑

1. **PowerShell 里把含双引号的 JSON 直接交给 `curl.exe` 会被剥引号** ⇒ 服务端回
   `{"code":400,"message":"Invalid JSON body","data":null}`（就是 §3.2 的形状 2）。
   必须写进文件再 `--data-binary "@文件"`，或干脆用 `Invoke-RestMethod -Body (@{…} | ConvertTo-Json -Compress)`。
2. **PowerShell 的数组 splat `@a` 是位置传参**，**不能**用来传 `-Base` / `-Dsn` / `-AdminPw` 这类**命名**参数。
   要传命名参数请用**哈希表** splat `@params`（`$params = @{ Base = …; Dsn = … }`）。
3. ⚠ 探测副作用：`stress-booking.ps1` 会**清空重建** `department` / `doctor` / `schedule`
   （跑完只剩 1 条 `remain_num = 0` 的排班）。要接着做分诊实测，**得自己先补夹具**。

---

## 14. 附录

### 14.1 错误码总表（`http_common.cj:55-197`，**包含枚举值**）

| HTTP | code | message（服务端默认文案） | 患者端会不会遇到 |
| --- | --- | --- | --- |
| 401 | `AUTH_REQUIRED` | 未登录或缺少令牌 | ✅（没带令牌） |
| 401 | `AUTH_BAD_CREDENTIALS` | 账号或密码错误 | ✅（登录） |
| 401 | `AUTH_TOKEN_EXPIRED` | 登录已过期，请重新登录 | ✅（令牌无效**或**过期；message 会被覆盖成「令牌无效或已过期，请重新登录」`http_app.cj:314-315`） |
| 429 | `AUTH_RATE_LIMITED` | 登录失败次数过多，请稍后再试 | ✅（登录，带 `retry-after`） |
| 403 | `FORBIDDEN_ROLE` | 当前角色无权执行此操作 | ✅（用非患者账号登了患者端；退别人的单） |
| 400 | `VALIDATION_FAILED` | 参数校验失败（**具体原因在 `error.message`**） | ✅ |
| 404 | `SCHEDULE_NOT_FOUND` | 排班不存在或已停诊 | ✅ |
| 409 | `SLOT_GONE` | 号源已被抢完，请选择其它排班 | ✅ |
| 404 | `APPOINTMENT_NOT_FOUND` | 挂号单不存在 | ✅ |
| 404 | `PREVISIT_NOT_FOUND` | 预问诊会话不存在或已失效 | ✅ |
| 404 | `EMR_NOT_FOUND` | 病历不存在或尚未提交 | ✅ |
| 409 | `EMR_LOCKED` | 病历已提交锁定，不可修改（需管理员解锁） | ❌（医生端） |
| 409 | `EMR_NOT_LOCKED` | 完成就诊前必须先提交锁定病历 | ❌（医生端） |
| 409 | `VISIT_BAD_STATE` | 当前就诊状态不允许该操作 | ❌（医生端） |
| 404 | `ROUTE_NOT_FOUND` | 接口不存在 | ⚠ **实现里未见任何 handler 抛它**；路径不匹配时走的是框架的**平铺 404**（§3.2 形状 3） |
| 409 | `SLOT_NOT_RESTORED` | 已退号，但号源归还异常，请联系人工处理 | ❌ **死条目**：登记在表里但当前实现路径**不抛**（归还失败走 200 + `warning`，`http_app.cj:1501-1512`） |
| 404 | `USER_NOT_FOUND` | 账号不存在 | ❌（管理端） |
| 409 | `USER_EXISTS` | 登录名已存在 | ❌（管理端） |
| 404 | `BASE_NOT_FOUND` | 科室或医生不存在 | ❌（管理端） |
| 409 | `BASE_NAME_TAKEN` | 同名已存在 | ❌（管理端） |
| 409 | `BASE_CODE_TAKEN` | 该编码已被占用 | ❌（管理端） |
| 409 | `BASE_IN_USE` | 该记录正被引用，不能删除 | ❌（管理端） |
| 404 | `KB_DOC_NOT_FOUND` | 知识库文档不存在 | ❌（管理端） |
| 409 | `KB_TITLE_TAKEN` | 已存在同名知识库文档 | ❌（管理端） |
| 500 | *（任何未登记码，含 `INTERNAL` / `INTERNAL_ERROR` / `KB_WRITE_FAILED`）* | 服务器内部错误 | ✅（兜底） |

> ⚠ **不存在** `AUTH_TOKEN_INVALID` 这个码（见 §11 第 5 条）。
> ⚠ 框架层还有**两个非本表**的状态码：**400 `Invalid JSON body`** 与 **404 `Not Found`**（平铺形状，§3.2）、
> **413**（body 超 64 KiB / 1 MiB）、**405**（方法不匹配，返回平铺 `{"error":"Method Not Allowed","allow":"…"}`，`router.cj:227-231`）、
> **408**（handler 超时且未写响应，`http_app.cj:1617-1630`）。

### 14.2 逐字 `error.message` 速查（仅供兜底展示）

**优先按 `code` 分支**；下列 `message` 只在 `VALIDATION_FAILED` 下才有必要匹配，且**都可能随服务端改动而变**。

| 位置 | message |
| --- | --- |
| `requireStr` 缺失 | `缺少必填字段 <key>` |
| `requireStr` 空串 | `字段 <key> 不能为空` |
| `requireInt` 缺失 | `缺少必填数值字段 <key>` |
| `bodyObj` | `请求体不是合法 JSON` / `请求体必须是 JSON 对象` |
| login 限流 | `登录失败次数过多，请稍后再试`（+ 头 `retry-after`） |
| logout 无令牌 | `缺少 Authorization: Bearer <token>` |
| 令牌无效/过期 | `令牌无效或已过期，请重新登录` |
| 角色不符 | `角色 <role> 无权执行 <action_name>`（如 `角色 admin 无权执行 book`） |
| schedules 日期 | `work_date 格式应为 YYYY-MM-DD` |
| schedules/:id | `排班 id 必须是正整数` |
| appointments 列表 | `该接口只对患者开放（它返回的是"我的挂号"）` |
| appointments 建单（无患者档案） | `缺少 X-Patient-Id（开发态联调头）` |
| appointments 退号 | `无权取消该挂号单（管理员可退任意单；患者只能退自己的）` |
| appointments 退号告警 | `号源归还异常，请联系人工处理` |
| previsit 未知槽位 | `未知的问诊项：<slot>` |
| previsit 超长 | `字段 <slot> 超出长度上限` |
| medical-records | `该账号没有绑定患者档案` |
| 未登录（兜底） | `未登录或缺少令牌` |
| 兜底 500 | `服务器内部错误` |

### 14.3 枚举值总表

**`role`**（`http_app.cj:49-55`）：`patient` | `doctor` | `admin`

**`appointment.status`**（`domain_emr.cj:661-673` 附近的接诊状态机）：

| 值 | 含义 |
| --- | --- |
| `booked` | 已挂号（新建单的默认值，`domain_booking.cj:530`） |
| `visiting` | 接诊中（医生端流转） |
| `done` | 已完成就诊 |
| `cancelled` | 已取消（退号） |
| `no_show` | 爽约 |

**`schedule.period`**：`AM` | `PM`（默认 `AM`，`domain_booking.cj:117`；**服务端不对取值做枚举校验**，前端要容错显示未知值）

**分诊 `reason_code`**（`triage.cj:54-60`）：`RED_FLAG` | `NO_COMPLAINT` | `NEED_CLARIFY` | `NO_SUCH_DEPT` | `NO_BOOKABLE` | `ALTERNATIVES` | `OK`

**分诊 `source`**（`triage.cj:46-47` + `http_app.cj:1201-1203`）：`rules` | `model` | `model:invalid`

**预问诊 `slot`**（`previsit.cj:181-196`）：`chief` | `duration` | `severity` | `associated` | `history` | `allergy`

**SSE `event`**（`http_app.cj:1264-1282`）：`meta` | `delta` | `done`

**病历 `status`**（`domain_emr.cj:48-49`）：`draft` | `locked`。
▸ 接诊队列里还有第三个**展示用**值 `"none"`（无病历时，`http_p4.cj:98-102`）——那是 `record_status`，不是 `medical_record.status`。

**病历七段 key**（`domain_emr.cj:83-92`）：`chief_complaint`(主诉) | `present_illness`(现病史) |
`past_history`(既往史) | `allergy_history`(过敏史) | `physical_exam`(体格检查) |
`diagnosis`(诊断, 必填锁) | `treatment`(处理意见, 必填锁)

**`auth_user.status`**：`active`（只有 `active` 能登录，`auth_repo.cj:622-623`）

### 14.4 响应示例汇总（可直接做 mock）

```jsonc
// GET /health（平铺，无 data 包装）
{ "ok": true, "service": "hospital-server", "version": "0.2.0-p1",
  "data_backend": "mysql", "dev_auth": false }

// POST /api/v1/auth/login
{ "ok": true, "data": { "token": "9f2c…(64 hex)…", "expires_at": 1790000000,
  "user_id": 12, "role": "patient", "ref_id": 7, "display_name": "张三", "patient_id": 7 } }

// GET /api/v1/auth/me
{ "ok": true, "data": { "user_id": 12, "role": "patient",
  "patient_id": 7, "doctor_id": 0, "device_id": "dev-001" } }

// GET /api/v1/schedules?department_id=3&work_date=2026-11-20
{ "ok": true, "data": { "schedules": [
  { "id": 41, "doctor_id": 9, "department_id": 3, "work_date": "2026-11-20",
    "period": "AM", "total_num": 20, "remain_num": 5, "enabled": true } ], "count": 1 } }

// POST /api/v1/triage
{ "ok": true, "data": { "red_flag": false, "reason_code": "OK", "source": "rules",
  "patient_note": "建议挂呼吸内科，今天上午还有号。", "truncated": false,
  "ai_note": "", "ai_reason": "未配置模型，已按规则给出建议",
  "options": [ { "department_id": 3, "department_name": "呼吸内科",
    "doctor_id": 9, "doctor_name": "李医生", "doctor_title": "副主任医师",
    "schedule_id": 41, "work_date": "2026-11-20", "period": "AM",
    "remain_num": 5, "total_remain": 12 } ], "count": 1 } }

// POST /api/v1/previsit/answer（未集齐：没有 form）
{ "ok": true, "data": { "session_id": "ab12…(64 hex)…", "turn": 2, "filled": 2,
  "total_slots": 6, "complete": false, "next_slot": "severity",
  "next_question": "对日常生活影响大吗？" } }

// POST /api/v1/previsit/answer（集齐：出现 form）
{ "ok": true, "data": { "session_id": "ab12…(64 hex)…", "turn": 6, "filled": 6,
  "total_slots": 6, "complete": true, "next_slot": "", "next_question": "",
  "form": { "chief": "咳嗽三天", "duration": "3 天", "severity": "轻微",
            "associated": "无", "history": "无", "allergy": "青霉素过敏" } } }

// POST /api/v1/appointments  → 201（首次）或 200（幂等回放）
{ "ok": true, "data": { "appointment_id": 501, "schedule_id": 41, "patient_id": 7,
  "doctor_id": 9, "department_id": 3, "visit_date": "2026-11-20", "period": "AM",
  "seq_no": 6, "status": "booked", "slot_restored": true } }

// POST /api/v1/appointments/501/cancel（号源归还异常的特例，仍 200）
{ "ok": true, "data": { "appointment_id": 501, "schedule_id": 41, "patient_id": 7,
  "doctor_id": 9, "department_id": 3, "visit_date": "2026-11-20", "period": "AM",
  "seq_no": 6, "status": "cancelled", "slot_restored": false,
  "warning": "号源归还异常，请联系人工处理" } }

// GET /api/v1/medical-records/501（已锁定，含七段）
{ "ok": true, "data": { "id": 88, "appointment_id": 501, "patient_id": 7, "doctor_id": 9,
  "status": "locked", "locked": true, "filled": 7, "total_sections": 7, "complete": true,
  "updated_by": 3, "created_at": 1790000000, "updated_at": 1790003600,
  "missing_required": [],
  "sections": [ { "key": "chief_complaint", "label": "主诉", "value": "咳嗽三天",
    "max_len": 2000, "required_to_lock": false } ] } }

// 业务错误
{ "ok": false, "error": { "code": "SLOT_GONE", "message": "号源已被抢完，请选择其它排班" } }

// 框架层：请求体不是合法 JSON（平铺，无 ok / 无 error）
{ "code": 400, "message": "Invalid JSON body", "data": null }

// 框架层：路径不匹配（平铺，回显 path）
{ "error": "Not Found", "path": "/api/v1/aprpointments" }
```

---

## 15. 一页速查（贴到工位上）

```
base        http://127.0.0.1:8091                     （默认端口其实是 8080）
前缀        /api/v1            例外：/health 在根路径、不鉴权、不走信封
鉴权        Authorization: Bearer <64hex>             （头名/Bearer 前缀大小写不敏感）
成功        {"ok":true,"data":{…}}         200 / 201
失败        {"ok":false,"error":{code,message,fields?}}
框架失败    {"code":400,"message":"Invalid JSON body","data":null}
            {"error":"Not Found","path":"/api/v1/…"}
SSE         data: {"event":"meta|delta|done","data":{…}}\n\n  严格按 \n\n 分帧、整段解码
挂号        client_token 幂等键：重放 → 200，首次 → 201；换号源 = 换 token
退号        永远 200，成功看 data.status==='cancelled'；slot_restored:false 要提示 warning
分诊        red_flag=true ⇒ options 必空 ⇒ 引导急诊，绝不自己拼号源
预问诊      空 value 不落库不推进；"无" 是有效答案；form 只在 complete 后出现
401         清 token → 登录页
429         读 retry-after 做倒计时（同一窗口内会递减）
403         用非患者账号登了患者端 ⇒ 提示"本 App 仅面向患者"
拼错路径    平铺 404 ⇒ 这是 bug，不是业务态
```

---

**文档结束。** 任何与 `server/src/*.cj` 冲突之处，以源码为准；本文标注「未实测」的条目请在联调时确认后再据以编码。
