# Changelog

本文件记录 QingZhou（轻舟）各版本的功能变化。格式参考 Keep a Changelog，
版本号遵循语义化版本（SemVer）。

## [Unreleased]

### 新增
- **流式查询构建器**（`dbquery.cj`）：参数化优先的 Select / Insert / Update /
  Delete 构建器，产出 `(sql, params)` 直接喂给 `DbBackend.query/exec` 的绑定入口。
  - 标识符校验 `sqlIdent`：只放行 `[A-Za-z_][A-Za-z0-9_]*` 与一个 `表.列` 前缀，
    其余抛异常——表名/列名无法参数化，只能校验而非转义（各后端引号语法不同）
  - 条件树：`dbEq/dbNe/dbGt/dbGe/dbLt/dbLe/dbLike/dbBetween/dbIn/dbIsNull/
    dbNotNull/dbAnd/dbOr/dbNot`，外加逃生口 `dbRaw`
  - **方言闸门 `DbDialect`**：`Common`（默认）只产出 CangDB 与 MySQL 的交集；
    `MySql` 才放行 OR / 括号分组 / `<>` / `IS NULL` / 值列表 IN / LIMIT / OFFSET /
    INSERT 列清单。越界构造在**构建期**报错，不做「MySQL 能跑、换 CangDB 就炸」
    的静默降级。后端自带方言（`DbBackend.dialect()`），`.query(be)/.exec(be)`
    自动取用
  - Update / Delete 无 WHERE 时默认拒绝，需显式 `allowFullTable()`

### 修复
- **路由静态分支不回退导致误判 404**（`router.cj`）：`walk` 命中静态段后直接返回
  该分支的结果，不做回溯。注册 `/api/users/me` 与 `/api/:module/list` 之后请求
  `/api/users/list`，静态段 `users` 先命中，但其下只挂了 `me`，查找随即判失败并
  返回 404——而 `:module/list` 本应匹配。改为静态段分支失败后继续尝试参数段与
  通配符段；回溯路径上写入的参数同步撤销，避免失败分支污染随后成功分支的取值
  （同一层可并存多个不同名的参数节点）。
- **MySQL NULL 列导致查询崩溃**（`db_mysql.cj`）：`query` 原先逐列用
  `get<String>` 取值，遇 NULL 列抛 `NoneValueException`——任何含 NULL 的查询都会
  崩。改用 `getOrNull<String>` 并把 NULL 统一为 `"NULL"`，与 CangDB 的字符串化
  约定一致，`DbResultSet.getNullable` 在两个后端行为相同。
- **MySQL 尾反斜杠逃逸**（`db_mysql.cj`）：连接后会话级固定 `NO_BACKSLASH_ESCAPES`，
  使框架的 `''` 转义在 MySQL 与 CangDB 上语义一致。此前 MySQL 默认把反斜杠也当
  转义符，以单个反斜杠结尾的值（如 `"abc\"`）会吃掉收尾引号、突破字符串边界
  （容器上已复现：`near ''abc\')'` 语法错误）。新增
  `MySqlBackend(..., noBackslashEscapes: false)` 可退回旧行为；固定后 raw SQL 不能
  再依赖反斜杠转义（`LIKE` 的 `\%` 需改写）。该设置是会话级，不改服务器全局配置。

## [0.12.0] — 2026-10-02

出站与 JSON 处理能力补齐四项（v0.11.x 批次）：出站并发控制、容错 JSON 提取、
声明式 schema 校验、日志脱敏。至此「可靠出站 + 模型输出归一化」所需的通用能力
全部就位（业务侧只剩自己的领域语义）。

### 新增
- **出站并发控制**（`outbound.cj`）：`OutboundClient` 新增 `maxConcurrency` 参数，
  用 `std.sync.Semaphore` 限制**同时在途**请求数（入站有 ratelimit 保护，
  出站此前无对应机制）。信号量在 `send` 入口 acquire、`finally` 保证归还。
- **容错 JSON 提取**（`jsonx.cj`）：`extractJson(text)` 从带杂质的文本里提取第一个
  **平衡的** JSON 对象/数组（剥 markdown 围栏、跳过前后话术）；`parseJsonLoose`
  一步完成「提取 + 严格解析」。
- **声明式 schema 校验**（新增 `jsonschema.cj`）：`JsonSchema` 链式注册字段
  （`requireStr` / `requireIntIn` / `require` / `optional`），`validate` **一次收集
  全部错误**（非遇到第一个即返回），支持类型 / 必填 / 字符串长度 / 数值范围。
- **日志脱敏**（`security.cj`）：`redact(text)` 遮蔽 `authorization` / `api_key` /
  `token` / `password` / `secret` 等 14 个敏感字段的值（大小写不敏感、支持
  `key: value`、`"key":"value"`、`?key=value` 三种形态），保证「密钥永不入日志」。

### 修复
- **字符串切片是按字节切的**：`String[i..j]` 对多字节 UTF-8（中文）会切断序列并抛
  `Invalid utf8 byte sequence`。`extractJson` 与 `redact` 均改为**字节级扫描**
  （JSON 结构符与敏感分隔符都是 ASCII，字节级判断既正确又与编码无关）。
- **脱敏的裸串不因空格终止**：`Authorization: Bearer <token>` 若按空格截断，
  token 会漏出日志——故裸串终止符取 `, ; & 换行 制表 }`，安全侧偏保守。
- `type` 是仓颉**保留关键字**（不能作字段名/参数名），schema 里改用 `fieldType`。
- 泛型 `Option` 上直接 `!= None` 可能触发 `generic type should be used with type
  argument`（?JsonObject / ?JsonArray），改用 `match` 判空（`hasSome`）。

### 测试
- 202/202 单测通过（新增 11 例：围栏提取 / 字符串内括号 / 无 JSON / parseJsonLoose /
  schema 一次报全 / schema 通过 / 类型不符 / Authorization 脱敏 / JSON 字段脱敏 /
  普通文本不变 / **并发上限峰值 ≤ 2（6 并发请求真实压测）**）。

## [0.11.0] — 2026-10-02

出站调用能力：补齐 HTTPS 客户端（TLS）、重试退避、可注入传输层三项**通用**出站能力。
前两项让服务端能可靠调用第三方 HTTPS API，第三项让这类调用可以离线单测。

### 新增
- **出站 TLS 客户端**（`outbound.cj`）：`OutboundTlsOptions`（三种模式：`caBundlePath`
  走 CustomCA / `trustAll` 仅本机开发 / 都不设走系统 CA）+ `StdxTransport` 基于
  `ClientBuilder().tlsConfig(...)`。支持自签证书 CustomCA 握手全链路。
- **重试 + 指数退避**（`outbound.cj`）：`RetryPolicy`（`maxAttempts` / `baseDelayMs`
  / `maxDelayMs` / 抖动 / 可重试判定）。判定规则：网络错误可重试、429 可重试、
  5xx 可重试、**4xx（除 429）不重试**。退避用 `std.sync.sleep`（1.2.0 起可用）。
- **可注入传输层**（`outbound.cj`）：`HttpTransport` 接口 + `StdxTransport`（真实）
  + `MockTransport`（测试用，可编程应答队列 + 记录请求），`OutboundClient` 组合
  transport 与 retry。单测全程无网络。

### API 事实
- `CertificateVerifyMode` 自 stdx 1.1.3.1 起位于 **`stdx.net.tls.common`** 子包（主包无）。
- 它是**带参数的枚举**：`Default | TrustAll | CustomCA(Array<Certificate>) |
  CustomVerify((Array<Certificate>) -> Bool)`——CA 是 `CustomCA` 的载荷而**非**
  `TlsClientConfig` 的字段。
- `Array<X509Certificate>` 与 `Array<Certificate>` 不协变，且 `as` 返回 Option，
  需逐个拷贝并解包（`loadCaCertificates` 已封装）。
- 必须 `import stdx.net.tls.*`，否则运行时报 `Global TLS kit is not set`。
- `TlsClientConfig` 是 struct，必须 `var` 声明后才能赋字段。

### 测试
- 191/191 单测通过（新增 6 例：一次成功 / 5xx 重试后成功 / 4xx 不重试 /
  网络错误用满重试 / 退避指数增长与封顶 / **真实 TLS CustomCA 握手**）。

## [0.10.0] — 2026-09-22

工具链升级到 cjc 1.2.0 + stdx 1.1.3.1（双版本兼容），数据层依赖库
（CangDB / mysql-driver）用新工具链重编，并在新工具链下完成 admin 全链路验证。

### 新增
- **工具链双版本兼容**：cjc 1.0.5（LTS）→ 1.2.0、stdx 1.0.5.1 → 1.1.3.1。
  cjc 1.2.0 配 stdx 1.0.5.1 会运行时 segfault（二进制不兼容，官方
  「1.2.0 与早期产物不兼容」），配 stdx 1.1.3.1 则 185 单测、9 示例编译、
  TLS 握手（TLSv1.3）全过——**兼容边界是 stdx 1.1.x 起**。
- **stdx 新目录名探测**（`build.sh` / `qz`）：stdx 1.1.x 起目录名改为
  `{os}_{arch}_cjnative`（x64→x86_64、mac→macos，不含版本号），`find_stdx`
  新格式优先 + 旧格式兜底，并支持 `CANGJIE_STDX_PATH` 官方环境变量。

### 修复
- **mysql-driver 重编适配**：stdx 1.1.3.1 把 `CertificateVerifyMode` 从
  `stdx.net.tls` 主包移到 `stdx.net.tls.common` 子包，`maria_connection_factory.cj`
  补 `import stdx.net.tls.common.*`（本地适配，未提交上游）。
- **build.sh examples skip 补全**：`db_todo`（依赖 CangDB）与 `lib_hello`
  （库用法 `import qingzhou.*`）此前未进 skip 列表，批量编译中断。
- **数据层依赖库重编**：CangDB（`cjc -p cangdb --output-type=staticlib`）与
  SIG mysql-driver（protocol→connection→cdbc 逐子包）均用 cjc 1.2.0 重编。

### 验证
- admin e2e 全链路（新工具链）：CangDB 数据层（seed/建户/唯一约束/RBAC/改密）
  + MySQL 数据层（驱动新库二进制兼容 + 跨进程落库验证）+ HTTP 冒烟
  （login 签发 JWT / 错密码 401）全部通过。

## [0.9.0] — 2026-09-20

生产化运维能力：连接池 / 健康检查 / 生命周期钩子 / 路由增强 / 结构化日志，
并以全维度压测（HTTP 并发 800、SSE / WebSocket、multipart 大文件）验证并发
健壮性。框架从「功能完整」进入「可运维」阶段。

### 新增
- **健康检查中间件**（`health.cj`）：K8s 风格 liveness/readiness 双端点。
  `GET /healthz` 存活检查不跑探针恒 200（避免依赖故障引发重启风暴）；
  `GET /health` 就绪检查执行全部注册探针（`() -> Bool`，异常按 DOWN 计并
  携带错误信息），全过 200、任一失败 503 + 明细 JSON（含 `uptimeMs`）。
  响应带 `Cache-Control: no-store`；非 GET/HEAD 请求健康路径回 405；
  其余路径透传。`HealthCheckOptions` 链式注册探针，路径可配。
- **生命周期钩子**（`app.cj`）：`onListen(cb)`（serve 线程启动后触发，fail-fast
  异常上抛）+ `onShutdown(cb)`（`shutdown()` 排空在途请求后按注册序触发，单钩子
  异常隔离不阻断其余钩子）。典型用法：连接池 / 日志 sink 挂 `onShutdown`，
  进程优雅关闭时自动回收（`app.onShutdown({ => pool.close() })`）。
- **路由增强**（`router.cj`）：可选参数 `:id?`（注册时展开为具体路径，单条
  pattern 上限 3 个）；命名通配符 `*path`（尾部命名吞尾）；中途 `*` 匹配单段
  （匿名或 `*name` 命名注入）；分组路由 `router.group(prefix, mw:)`（前缀挂载 +
  组级中间件洋葱包裹，嵌套继承）；命名路由 `name:` + `urlFor(name, params:)`
  反向生成 URL（可选参数缺省跳过、必填缺失返回 None）。
- **结构化日志 sink**（`logger.cj`）：`jsonLogFormatter`（每请求一行 JSON，字段
  id/ip/method/path/status/elapsed_ms，基于 JsonBuilder 自动转义）+ `fileLogWriter`
  （追加写文件，`File.appendTo` 即开即写即关）。配合既有 `LoggerOptions` 注入点，
  补齐「结构化日志 + 文件 sink」缺口（v0.1 起列入计划）。
- **连接池**（`dbpool.cj`）：`DbPool` 接口（acquire/release/close/idleCount）+
  `SimpleDbPool` 实现（`std.sync.Mutex` 保护空闲栈，LIFO 复用，capacity 限制空闲
  保有量）+ `openPool(dsn, capacity)` 工厂。解决单连接被并发请求共享时的两个
  隐患：底层驱动非线程安全、`withTransaction` 事务在共享连接上串线。无外部依赖，
  进默认编译集。
- **并发压测验证（P2）**：HTTP 并发 800/800（32 线程，QPS≈4000）、SSE 并发流
  16/16（20 chunk 完整有序）、WebSocket 并发 echo 16/16（20 帧完整）、multipart
  8MB 大文件 3/3、二进制 1MB（全字节范围）完整——框架并发与大流量行为健康。

### 修复
- **multipart 二进制载荷损坏**（P2 压测发现）：`parseMultipart` 旧实现把整个
  body 经 `String.fromUtf8` 转字符串再 split，非 UTF-8 二进制文件（PNG/ZIP 等）
  抛 "Invalid utf8 byte sequence"（整个请求 500）。改为字节级解析：boundary
  字节搜索（`indexOfBytes`）+ 头部块（ASCII 安全）才转字符串、内容保持原始
  字节，二进制上传不再损坏（含单测回归）。
- **大文件上传被拒**（P2 压测发现）：stdx 服务端默认请求体上限较低，8MB body
  收到 "The content too large."。`serve/serveTls/listen/listenTls` 新增
  `maxRequestBodySize!: ?Int64 = None` 命名参数（None 走 stdx 默认），大文件
  上传场景显式调大即可。
- **shutdown() 与 serve() bind 的启动竞态**（生命周期钩子测试发现）：
  `shutdown()` 紧跟 `serve()` 调用时，`server.close()` 可能先于 serve 线程的
  bind() 执行，serve 线程以 "Socket is already closed" 异常退出。现在
  `shutdown()` 对停服调用容错（异常打印不重抛），保证无论服务状态如何都
  推进到 onShutdown 收尾钩子。生产场景（运行后关停）不受影响。

### 计划
- C-6 / C-7 / D-3 / D-4 四项反馈：待外部使用方重发原文后补分诊
- A-6 优雅关闭信号：待 stdx / std 支持 Windows 信号后接入
- Schema 迁移 / 包拆分上架：后续版本方向待定

## [0.8.0] — 2026-09-20

数据层抽象层能力补齐（参数化查询 / 事务 / 类型化取值 / 唯一约束）+ 外部使用方
22 项反馈修复。相对 0.5.0 的实质增强：`DbBackend` 从「SQL 字符串接口」升级为
「类型化参数 + 事务 + 类型化取值 + 方言下沉」的完整数据层，CangDB / MySQL
双后端行为一致。

### 修复（外部使用方 22 项反馈 · 2026-09-19）

正确性：
- **A-1 body 读取短读截断**（`context.cj`）：旧版把「read 返回值小于缓冲区
  大小」误判为 EOF，跨块 body（典型 >4KB）被静默截断；且 try..catch 吞掉
  I/O 异常折算为 EOF。读取统一收敛到 `readBodyUpTo`（短读继续读、异常
  传播），配套短读流 stub 回归测试。
- **A-2 bodyParser 限额形同虚设**：旧版先全量读入内存再判 413，非
  json/form/text 类型完全无上限。改为流式限额 `Context.bodyBytesCapped`
  （超限立即停读回 413，不缓存）；新增 `contentLengthLimit` 中间件
  （仅按 Content-Length 头预检、不消费流，未知长度可配 411 拒绝）。
- **A-3 bodyParser 错误格式不统一**：`{"error":"..."}` → 统一壳
  `{"code":N,"message":"...","data":null}`，与 api.cj 一致。
- **A-4 passOnNotFound 状态残留**：透传前 lookup 已预写 404 状态/body/
  content-type，下游成功响应带着 404 状态码出门。新增 `Context.resetResponse`
  并在透传前复位。
- **A-5 Content-Type 大小写敏感**：`"Application/JSON"` 被当未知类型透传，
  归一到小写再比较。
- **A-7 ETag 仅含 size**：同尺寸替换文件 304 不刷新。静态服务改用
  `makeETagWithMtime`（`"<size>-<YYYYMMDDHHmmss>"` 复合指纹）。

安全：
- **B-1 SQL 注入**：`store.cj` 登录/建户路径裸拼 username，可被
  `' OR '1'='1` 注入绕过认证。新增 `sqlEscape`/`sqlQuote`（`db.cj`，
  `''` 标准转义，CangDB/MySQL 通用），含外部输入的插值全部改造；
  MySQL 尾反斜杠残余风险文档化（建议 NO_BACKSLASH_ESCAPES，见
  `docs/DATABASE.md`）。根治见下方「参数化查询（C-1）」。
- **B-2 默认口令无改密入口**：`RbacStore.changePassword`（随机新盐）+
  admin 示例 `POST /api/password`（登录即可改本人密码）。

### 新增
- `Context.bodyBytesCapped(maxBytes)`：流式限额读取（A-2 配套）
- `Context.resetResponse()`：响应缓冲区复位（A-4 配套）
- `contentLengthLimit` 中间件 + `ContentLengthLimitOptions`（A-2 配套）
- `sqlEscape`/`sqlQuote`：SQL 字符串转义（B-1 配套）
- `RbacStore.changePassword`（B-2）
- `makeETagWithMtime`（A-7 配套，static 默认启用）
- `serve`/`serveTls`/`listen`/`listenTls` 新增 `bindAddr!` 命名参数（C-5，
  默认 0.0.0.0 保持兼容，可绑 127.0.0.1 等）
- `openStore("mysql://user:pass@host:port/db")` 真实接入（C-4/D-2）：旧版
  无条件 throw，现按 DSN 解析构造 `MySqlBackend`（口令可含 @，端口缺省
  3306，错误消息脱敏）；编译集需带 `db_mysql.cj`，运行时需驱动（见
  `docs/DATABASE.md`）
- 回归测试 +16（manual runner 共 149 场景）：短读/超限/411/统一壳/404
  复位/复合 ETag/sqlQuote/RbacStore 注入与改密（RecordingBackend）

### 参数化查询（C-1 · 2026-09-20）

- **框架级类型化参数绑定**（`db.cj`）：新增 `DbValue` 枚举
  （`DbInt`/`DbFloat`/`DbStr`/`DbBool`/`DbNull`）、`dbValueLiteral`
  （类型感知字面量化：字符串必转义、数字原样、Bool→1/0、Null→NULL）、
  `bindSql`（`?` 占位符按序替换，数量不匹配抛异常）。
- `DbBackend` 接口新增默认实现 `query(sql, params)` / `exec(sql, params)`：
  所有后端（含未来新增）自动获得参数化能力，行为一致；后端可覆盖为
  服务器端预处理（如 std.database.sql 驱动的 `PreparedStatement.set<T>`）。
- `RbacStore` 的登录/建户/改密/种子用户全部改用 `?` 占位符 + `DbValue`
  参数，业务代码彻底移除手写 `sqlQuote` 拼接（B-1 的根治）。
- 回归测试 +5（manual runner 共 154 场景）。

### 事务（C-2 · 2026-09-20）

- `DbBackend` 接口新增事务能力：`beginTransaction`/`commitTransaction`/
  `rollbackTransaction` 三个抽象方法 + `withTransaction(body)` 默认方法
  （自动 begin → body → commit，body 抛异常回滚并重新抛出）。
- `CangDbBackend` 包装 `cangdb.Db.begin/commit/rollback`（commit=sync 落盘，
  rollback=walRollback+重载 catalog）；`MySqlBackend` 持有
  `Connection.createTransaction()` 的 `Transaction` 并透传 begin/commit/rollback。
- 回归测试 +2（manual runner 共 156 场景）：withTransaction 提交/回滚语义
  （RecordingBackend）；CangDB 真事务端到端探针（回滚数据消失、提交保留）。

### 类型化取值（C-3 · 2026-09-20）

- `DbResultSet` 新增类型化取值方法：`getInt(i,j)` / `getFloat(i,j)` /
  `getString(i,j)` / `getNullable(i,j)`（NULL 约定：空串或 "NULL" → None），
  业务代码摆脱手写 `Int64.parse(cell(...))`。
- `RbacStore` 的 UserRow / RoleRow / PermRow 组装与权限查询全部改用
  `getInt` / `getString` 类型化取值。
- 回归测试 +2（manual runner 共 158 场景）。

### 唯一约束（B-3 · 2026-09-20）

- `RbacStore.createUser` 改为事务内「查重 + 插入」，username 重名抛
  `IllegalArgumentException`（消除旧版「唯一性由调用方保证」的 TOCTOU
  缺陷）；`ensureSchema` 为 `users.username` 建唯一索引（`CREATE UNIQUE
  INDEX`，两后端 SQL 一致，重复建索引幂等忽略）。
- admin 示例 `POST /api/users` 捕获重名转 409。
- MySQL 后端：连接改用 `prepare.mode=client`（server 模式的
  COM_STMT_PREPARE 不支持 DDL）；唯一索引经 `ensureUniqueIndex` 方言下沉
  （MySQL 的 TEXT 列建索引须指定前缀长度 `username(255)`）。
- 回归测试 +2（manual runner 共 160 场景）；CangDB 唯一约束端到端探针
  （首次创建 / 重名查重抛异常 / 索引拦截重复插入 / ensureSchema 幂等）；
  MySQL 容器数据层验证 9/9（C-1/C-2/C-3/B-3）。

### 变更
- `build.sh`：`store.cj`/`rbac.cj` 移入默认编译（自 v0.7 起仅依赖 DbBackend
  接口，无外部库）；`examples` 批量构建跳过 admin 并给手工编译指引
- `db_factory.cj`：MySQL DSN 分支从「引导报错」改为真实接入

### 新增（出站 HTTP / SSE / 数据库抽象层）

- **出站 HTTP helper**（`httpclient.cj`）：`httpGetText`/`httpGetJson`/`httpPostJson`，
  非 2xx / 网络错误 / 解析失败统一返回 None
- **SSE 流式响应**（`context.cj`）：`streamStart`/`writeChunk` + 客户端侧
  `HttpStream`/`postStream` 逐块读取
- **数据库抽象层**（`db.cj` + `db_cangdb.cj` + `db_mysql.cj` + `db_factory.cj`）：
  `DbBackend` 接口 + `DbResultSet`，CangDB / MySQL 双后端，`openStore(dsn)`
  工厂按 DSN 切换（`cangdb:admin.cjdb` / `mysql://...`），业务代码零改动；
  `store.cj` 重构为依赖接口（见 `docs/DATABASE.md`）
- **jsonx 边界测试套件**（`src/jsonx_edge_test.cj`）：std.unittest 12 用例，
  覆盖空对象 / 类型不符 / 嵌套 / 特殊字符 / 超大数字（含一处实测 stdx
  浮点序列化缺陷的边界钉死）；`./build.sh test-jsonx` 运行

### 修复
- **store.cj 种子数据 bug**：admin 角色权限灌入误用半开区间 `1..6`（只灌 5 个），
  改为闭区间 `1..=6`——MySQL 后端端到端验证时发现，CangDB 路径同样存在

### 变更
- `db_mysql.cj` 驱动层改为双社区驱动兼容（运行时按注册名查找，编译期零驱动依赖）：
  mysqlclient4cj（注册名 `mysql`）/ Cangjie-SIG mysql-driver（注册名 `mariadb`）；
  MySQL 后端已在 mysql:8.0（Docker）上完成 RBAC 全功能端到端验证
- `build.sh`：`test-jsonx` 子命令（cjc --test 编译并运行 std.unittest 套件）；
  jsonx_edge_test.cj 与 unit_tests.cj 同样排除出默认编译

## [0.5.0] — 2026-09-15

完整后台管理系统案例 + 生产化：标准 JWT、RBAC、数据库持久化、前端工程化、部署工具。

### 新增
- **标准 JWT**（`jwt.cj`）：RFC 7519 HS256 + base64url + `iat`/`exp` 过期，
  替换旧的自定 `userId.sig` hex 签名格式，与外部 JWT 生态兼容
- **统一响应格式**（`api.cj`）：`respondOk`/`respondErr` → `{code, message, data}`
- **token 鉴权中间件**（`auth.cj`）：`authRequired` + `issueToken`/`verifyToken`
- **RBAC 中间件**（`rbac.cj`）：`requirePermission(store, method, path, code)`
- **SPA fallback**（`static.cj`）：`StaticOptions.spaFallback`/`apiPrefix`
- **多 Router 透传**（`router.cj`）：`Router.passOnNotFound`
- **后台管理系统示例**（`examples/admin.cj`）：登录 / 用户 / 角色 / 权限 CRUD，
  基于 CangDB 嵌入式数据库（`store.cj` 的 `RbacStore`）
- **Vue 3 前端**（`admin-web/`）：登录 / 仪表盘 / 用户管理，SPA + Bearer token
- **部署脚本**（`deploy-admin.sh`）+ `admin.env`：启停 / 健康检查 / 鉴权优雅关闭
- **OpenAPI 规范**（`docs/openapi.yaml`）：完整接口描述

### 变更
- token 从「无过期的 hex 签名」升级为「标准 JWT（默认 2 小时有效，校验过期 / 篡改 / 密钥）」
- `authRequired` 同时保护 `/api` 与 `/admin` 运维路径

### 已知边界
- `store.cj` / `rbac.cj` 依赖外部 CangDB（`libcangdb.a`），不在默认编译范围内，
  需单独链接（见 `build.cmd.txt` 或 admin 编译命令）

## [0.4.0] — 2026-09-10

库分发：从「源码分发」升级为「库分发」，对齐 Koa 的开发体验。

### 新增
- **库编译**：框架 22 个源文件可编译为 `qingzhou.cjo`（编译期）+ `libqingzhou.a`
  （链接期）——这正是 stdx 的发布方式，无需 cjpm build
- **`qz` 构建工具**：`qz lib`（编译框架库）/ `qz build app.cj` / `qz run app.cj`，
  自动补齐 `--import-path` / `-L` / `-l` 与 stdx 依赖
- **`examples/lib_hello.cj`**：`import qingzhou.*` 的最小库用法示例

### 变更
- 用户项目从「框架源码一起编译」改为「`import qingzhou.*` + 链接库」

## [0.3.0] — 2026-09-10

生产化加固：从「功能完整」走向「生产可用」。

### 新增
- **静态资源内存缓存**（`static.cj`）：`StaticCache` + `StaticOptions.enableCache`，
 文件字节读一次后跨请求复用（热资源命中后 0ms），ETag/Range/304 逻辑不变
- **优雅关闭**（`app.cj`）：`QingZhouApp.serve(port)` 非阻塞启动返回
 `ServerHandle`，`shutdown()` 停止接新连接 + 排空在途请求，`wait()` 阻塞等待；
 原有 `listen(port)` 保持阻塞语义（等价 `serve().wait()`）
- **配置加载**（`config.cj`）：`Config` 键值容器 + 类型访问器
 （`get/getOr/getInt/getIntOr/getBool/getBoolOr/getFloat`）+
 `loadConfigFile`（key=value 文件，.env 风格）+ `parseConfigText`

### 变更
- `listen()` 内部重构为 `serve().wait()`，行为向后兼容

### 已知边界
- 环境变量 API：Cangjie 1.0.5 std 无 `getEnv/envVars`（`std.env` 仅进程控制），
 配置暂只能从文件/参数加载，需环境变量可走 CFFI
- OS 信号：`std.runtime.Signal` 不支持 Windows，优雅关闭在 Windows 上需程序化
 触发（管理端点 / 第二线程），POSIX 可接 SIGINT

## [0.2.0] — 2026-09-10

基于实战 demo（轻舟博客）暴露的缺口，补齐类型安全与生产化能力。

### 新增
- **JSON 工具层**（`jsonx.cj`）：`JsonBuilder` 序列化 + 安全访问器
 `jsonGetStr/jsonGetInt64/...` + `bodyStr/bodyStrOr` body 读取
- **结构化 state**：`ctx.state` 从 String 改为 `HashMap<String,String>` +
 `setState/getState/getStateOr`
- **安全原语**（`security.cj`）：`hashPassword/verifyPassword`（加盐迭代哈希）
 + `signValue/verifySigned`（HMAC-SHA256 签名）+ `randomHex`
- **服务端 session**（`session.cj`）：`SessionStore` + `session` 中间件
- **query 解析**：`ctx.query/queryParam/queryParamOr/queryParams`
- **内置解析器**（`util.cj`）：`parseInt64OrNone/parseUInt16OrNone/...`
- **多 Range**（`range.cj`）：`parseRanges` + multipart/byteranges 响应
- **gzip 压缩**（`compress.cj`）：`gzipCompress` + `compress` 中间件
- **multipart 上传**（`multipart.cj`）：手写 boundary 解析 + `multipart` 中间件
- **Last-Modified**（`etag.cj`）：`fileLastModified` + `formatHttpDate` +
 If-Modified-Since → 304

### 文档
- `docs/GAPS.md`：缺口清单（P0/P1/P2 + 功能缺口全部解决）
- `docs/CAVEATS.md`：15 条仓颉语言坑
- `docs/PACKAGING.md`：qingzhou + qingzhou-middlewares 两包拆分方案

### 测试
- 单测 63 → **107**（+44），端到端回归全绿

## [0.1.0] — 2026-09-10

首个完整版本。Koa 风格的仓颉 Web 框架，功能全部完成。

### 技术验证
- 洋葱模型中间件调度（`Dispatcher` + `compose`）
- stdx.net.http 集成：`CatchAllDistributor` 接管全部分发
- `QingZhouApp.use()` / `listen()` 最小应用闭环

### 内核
- `Context` 响应缓冲（status / body / header / json 链式 API）
- 错误通道：业务链异常 → `onError` 链 → 兜底 500
- `commit()` 幂等写出；std.unittest 测试基建

### 路由
- Trie 路由：静态段 / `:param` / `*` 通配
- GET/POST/PUT/DELETE/PATCH/ALL 方法分发
- 404（JSON body）与 405（+ `Allow` 头）自动响应
- 路由以中间件形态挂载（`router.middleware()`）

### 请求体 / JSON / Cookie
- 惰性 body 读取 + 缓存（InputStream 只消费一次）
- `bodyBytes()` / `body()` / `bodyJson()` / `bodyJsonError()` / `bodyForm()`
- URL-decode（手写，多字节 UTF-8 安全）
- `contentType()` 参数剥离；基础 Cookie get/set

### 静态资源
- `serve` / `serveAt` / `serveWithOpts` 静态中间件
- MIME 查表（40+ 扩展名），二进制 body 响应通路
- 路径穿越防护（403）；目录 index.html；前缀段匹配

### 视频 / 缓存友好
- Range（RFC 7233）：`bytes=start-end` / `start-` / `-N` 后缀
- 206 Partial Content + Content-Range；416 + `bytes */size`
- 多区间 / 不可解析 Range 按规范忽略（回退 200）
- ETag（RFC 7232）：size 指纹强校验器；If-None-Match → 304（含 `*` 与 `W/` 弱前缀）
- HEAD 头-only 响应；`Accept-Ranges: bytes` 全响应携带

### 中间件套件
- `bodyParser`：JSON/form/text 预解析，400 坏 JSON（短路，不进 handler）、
 413 超限（默认 1 MiB）、未知 Content-Type 透传
- `cookies`：完整 RFC 6265 `CookieOptions`
 （maxAge/expires/path/domain/secure/httpOnly/sameSite）
- `cors`：预检 OPTIONS 204 短路；origin 支持 `*` / `reflect` / 固定域；
 credentials 守护
- `logger`：access log（MonoTime 计时），可定制 formatter/writer
- `requestId`：入站头透传 / 16 字节 hex 生成；响应头回写
- `timeout`：软超时（408 覆盖 或 `X-Timeout-Ms` 标注）

### 文档与发布
- `docs/API.md`：全量 API 参考（8 章 + 已知边界）
- `examples/`：hello / rest_api / static_site / middlewares 四个独立示例
 （全部编译 + 端到端验证）
- `cjpm.toml`（备用，含 Windows cjpm 不稳定说明）；README 快速上手
- 测试总计：63 单测场景 + 11 静态端到端 + 10 中间件端到端 + 示例端到端全绿

### 已知边界
- 无 Last-Modified / If-Modified-Since（std.fs 无 mtime、std.time 无 UTC 工厂）
- ETag 仅 size 指纹（单目录内碰撞可忽略）
- timeout 为软超时（std 无线程调度器，无法硬中断）
- 同名响应头覆盖语义（stdx ResponseBuilder 限制；多 Set-Cookie 内部合并）
