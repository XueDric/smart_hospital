# 接口契约（可执行）

> **为什么有这个目录**：`docs/FRONTEND-INTEGRATION.md` 解释字段的**语义**（这个字段是什么意思、
> 什么情况下会出现），但它**拦不住形状漂移** —— 服务端改一个字段名、把 404 从信封换成平铺，
> 文档不会自己变红。`contract/` 把真实响应**逐字节**钉住：**形状的权威在这里**，语义在文档里。

改动契约相关代码后，`server/tests/contract-check.ps1` 会失败 —— 这是设计目标，不是噪音。

---

## 1. 目录构成

| 路径 | 是什么 | 生成方式 |
| --- | --- | --- |
| `contract/examples/*.json` | **67 条**真实响应样例（含请求、状态码、`content-type`、响应体） | `server/tests/export-contract.ps1` **自动生成，不要手工改** |
| `contract/schema/*.schema.json` | **24 个** JSON Schema：6 个 **body 级**（`artifact` / `envelope-ok` / `envelope-error` / `envelope-error-fields` / `health` / `previsit-stream`），18 个 **data 级**（`data-*.schema.json`，校验 `response.body.data`） | 手工维护 |
| `contract/schema-map.json` | 样例 → Schema 的映射（`body` / `data` / `body_text` / `error_code`）+ 文件级 Schema 声明 | 手工维护，**新增样例必须登记** |
| `contract/CHANGELOG.md` | 形状变更日志（给人看：改了什么、客户端要不要动） | 手工维护 |

样例文件的结构（`artifact.schema.json` 钉住它）：

```json
{
  "name": "booking-create-201",
  "group": "挂号",
  "request":  { "method": "POST", "path": "/api/v1/appointments", "auth": "patient" },
  "response": { "status": 201, "content_type": "application/json; charset=utf-8", "body": { "ok": true, "data": { } } }
}
```

失败形状用 `body_text`（非 JSON 主体，例如 SSE）或 `allow`（405 的 `Allow` 头）。

## 2. 怎么跑

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
cd E:\harmonyOS\smart_hospital\server

# ① 只比对（不写盘）：重新导出并与已提交样例逐字节比 —— 门禁用的就是这个
.\tests\export-contract.ps1 -Base http://127.0.0.1:18092 -AdminPw <管理员口令> -Check

# ② 更新样例（只在"形状确实该变"时用；改完必须 review diff 并登记 schema-map + CHANGELOG）
.\tests\export-contract.ps1 -Base http://127.0.0.1:18092 -AdminPw <管理员口令>

# ③ 完整门禁 = ① + Schema 校验 + 登记完整性（推荐；已并入 final-verify.ps1）
.\tests\contract-check.ps1 -Base http://127.0.0.1:18092 -AdminPw <管理员口令>

# ④ 没起服务、只想校 Schema 与登记（快）
.\tests\contract-check.ps1 -AdminPw x -SkipExport
```

`contract-check.ps1` 检查三件事，**任一件失败即 exit 1**：

1. **逐字节比对**：重新导出与已提交样例是否一致（`-SkipExport` 可跳过）；
2. **Schema 校验**：每条样例的 `body` / `body_text` / `data` 是否符合登记的 Schema；
3. **登记完整性**：样例 ↔ `schema-map.json` **双向**核对（有样例没登记 = 失败；登记了不存在的 Schema = 失败）——
   这样**新端点不能偷偷绕过契约**。

## 3. 归一化：为什么样例里没有真实 id

导出机每次起服务、连的可能是不同的库，所以易变字段必须变成占位符，否则 golden 每次都不同。
规则（实现见 `export-contract.ps1` 的 `Normalize-Node` / `Scrub-Text`）：

| 类别 | 处理 | 例 |
| --- | --- | --- |
| 主键/外键/时间戳字段 | **置 0** | `id`、`appointment_id`、`department_id`、`created_at`、`server_time`、`captured_at`、`seq_no`、`operator_user_id`… |
| 令牌/会话 id 字段 | 占位符 | `<token>`、`<session_id>`、`<request_id>`、`<client_token>` |
| **文本里的**会话 id（如 SSE 帧内嵌 JSON） | 正则替换为 `<session_id>` | 否则 `previsit-stream-sse-200` 每次都变 |
| 文本里的日期 / 手机号 / 长数字 | `<date>` / `<phone>` / `<N>` | 错误消息里回显的参数 |
| 夹具专名 | `<dept>` / `<doctor>` / `<patient>` | 契约夹具的固定名字 |
| 请求路径里的数字段 | `{id}` | `/api/v1/medical-records/{id}` |
| **查询串里**值为库内自增 id 的参数 | `{id}` | `?exclude_appointment_id={id}` —— ⚠ 它同样是"每次导出都不同"的库内主键；而 `limit=9999`/`offset=-5`/`against=2` 这类**脚本文写死的常量**不归一化（它们是样例要钉住的东西）。漏了这条 → `doctor-patient-records-exclude-200` 每次都红（2026-10-15 实测） |
| 键顺序 | **排序**（`To-CanonicalJson`，非 `ConvertTo-Json`） | 保证 diff 可读、跨 PS 版本一致 |

**volatile 逃生口**：极少数样例的内容依赖整库状态（当前只有 `admin-users-page-clamped-200` 的
`data.items` / `data.count` / `data.total`），在样例文件的 `volatile` 数组里登记路径，导出机会把这些路径的值
写成 `"<volatile>"`；校验器遇到该占位符**跳过**校验。它只用来表达"这条形状有意义、内容没意义"，
**不允许**用它掩盖真实的不稳定。

> ⚠ **路径坐标**：`volatile` 里的路径相对**信封体**（`response.body`），和 `schema-map.json` 的
> `body`/`data` 靶位同一套 —— 所以 `data.items` 指 `body.data.items`。
> ⚠ **两条防呆（都是踩过坑之后加的）**：① 导出机解析不到某条 volatile 路径时**直接失败**（不静默跳过）；
> ② 门禁会断言"声明的 volatile 路径在文件里**确实是** `"<volatile>"`"。
> 没有这两条时，一条"声明了 volatile 但导出机其实没替换"的样例会在**别的脚本改了库之后**随机假红
> （2026-10-15 实测：`final-verify` 里 `contract-check` 红在 `admin-users-page-clamped-200`，
> 而单独跑它却是绿的 —— 典型的"环境相关假红"）。

## 4. 新增一条样例的步骤

1. 在 `export-contract.ps1` 里加一个 `Cap` 调用（请求 + 期望状态码）；
2. 去掉 `-Check` 跑一次，**逐行 review** 生成的 JSON（尤其确认没有真实 id/token 泄进去）；
3. 在 `schema-map.json` 的 `map` 里登记（新形状要在 `schema/` 里补 Schema）；
4. 在 `CHANGELOG.md` 记一行（日期 / 端点 / 变更 / 客户端要不要动）；
5. 跑 `contract-check.ps1` 全绿后一起提交。

## 5. 校验器支持的 Schema 子集

`server/tests/json-schema-lite.ps1`（不依赖 PS7 的 `Test-Json`，PS 5.1 与 PS7 行为一致）支持：

`type`（字符串或数组）/ `required` / `properties` / `additionalProperties: false` /
`items` / `enum` / `const` / `minimum` / `maximum` / `minLength` / `maxLength` /
`minItems` / `maxItems` / `pattern`（.NET 正则，2 秒超时）/ `title` / `description`。

⚠ **遇到不认识的关键字直接 throw**，不静默跳过 —— 否则写错的 Schema 会假装在校验。

## 6. 契约夹具

导出机自建夹具（id 段固定 **706xxx**，不与其它测试脚本冲突）：科室 `706001`（契约验证科/CTRC）、
医生 `706001`/`706002`、排班 `706001`（2026-12-26 上午，总号 20）/`706002`（2026-12-27 上午，总号 1，用于制造 `SLOT_GONE`）、
患者 `706001`/`706002`/`706003`，账号 `contract-doc` / `contract-doc2` / `contract-pat` / `contract-pat2`，
预问诊会话 `contract-706001-A`。

## 7. 契约**不**覆盖什么（别指望它）

- **字段语义**（什么时候会出现、该显示什么文案）→ `docs/FRONTEND-INTEGRATION.md`；
- **权限矩阵的全量组合**（只覆盖示例路径上的角色）；
- **数据库级不变式**（唯一键、并发、事务边界）→ `accept` 验收测试；
- **幂等/重放的行为语义**（样例只钉住"重放也返回 200 且 `appointment_id` 相同"这个形状）；
- **性能与超时**。

## 8. 这个目录已经纠正过的文档错误

| 文档旧说法 | 实测（契约样例为准） |
| --- | --- |
| "未匹配路由是平铺 `{"error":"Not Found","path":…}`" | **API** 路径是信封 `404 ROUTE_NOT_FOUND` |
| §3.2 只列 3 种失败形状 | **2026-10-17 起已收敛为 1 种**：所有 4xx/5xx（含框架的非法 JSON 400、路由/静态 404、405、416）都是 `{ok:false,error:{code,message}}`；`/health` 是第四种**成功**形状（`{ok,data}` 但字段少） |
| §3.2 那三种平铺形状（`flat-error` / `static-not-found` / `method-not-allowed`） | **已作废**（2026-10-17）：框架层改成可注入的 `router.errorBody` / `StaticOptions.notFoundBody|forbiddenBody|rangeNotSatisfiableBody`，三个 Schema 文件已删除，样例改指 `envelope-error` + `error_code` |
| `ROUTE_NOT_FOUND`"实现里未见任何 handler 抛它" | 兜底中间件会抛（`http_app.cj:2684-2706`） |
