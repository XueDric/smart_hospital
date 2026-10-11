<p align="center">
  <img src="logo.svg" alt="QingZhou 轻舟" width="128" height="128">
</p>

# QingZhou (轻舟) — Koa 风格 Web 框架 for Cangjie

> 面向仓颉语言的轻量级、类型安全 Web 框架，采用可组合的洋葱式中间件模型。

**v0.12.0** · 仓颉 1.2.0 · stdx 1.1.3.1 · 211 单测 · 核心微秒级 · 并发 800 QPS≈4000

---

## 特性

- **洋葱中间件** — 可组合的 `(Context, () -> Unit) -> Unit` 模型 + 框架级错误链
- **Trie 路由** — 静态段 / `:param` / `:id?` 可选参数 / 命名通配符 + method 分发 + 404/405 + 分组路由（前缀 + 组级中间件 + 嵌套）+ 命名路由 `urlFor` 反向生成
- **请求体** — bodyBytes / JSON / 表单懒读取，InputStream 只消费一次；大文件上传可调 `maxRequestBodySize`
- **静态资源** — MIME 查表 + Range/206 + ETag/304 + Last-Modified + 内存缓存
- **中间件套件** — bodyParser / requestId / logger（JSON 结构化 + 文件 sink）/ timeout / CORS / cookies 全选项
- **安全** — 密码哈希（加盐迭代）+ 签名 cookie（HMAC-SHA256）+ 服务端 session
- **HTTPS/TLS** — `serveTls` / `listenTls` 一行启用 TLSv1.3，证书链 + 私钥 PEM 直传
- **认证 / 授权** — 标准 JWT（HS256 + exp 过期）+ RBAC（用户→角色→权限）+ token 鉴权中间件
- **前后端分离** — SPA fallback + 统一响应格式 `{code, message, data}` + CORS
- **生产加固** — 请求限流（固定窗口 + 429）+ 安全响应头（nosniff/DENY/CSP）+ 熔断器
- **WebSocket** — `wsHandler` / `upgradeWebSocket` 双向长连接（HTTP Upgrade）
- **混合认证** — JWT + session 双凭证（`resolveIdentity` / `requireSession`）
- **出站 HTTP** — 薄封装 + **出站增强**（HTTPS/TLS `CustomCA`、重试指数退避、并发上限、可注入传输层可离线单测）
- **多数据库** — `DbBackend` 抽象层，CangDB / MySQL 可切换，改 DSN 即换库；参数化查询 / 事务 / 类型化取值 / 唯一约束方言下沉 / 连接池（`SimpleDbPool`）
- **查询构建器** — `SelectQuery` / `InsertQuery` / `UpdateQuery` / `DeleteQuery` 流式构建，参数化优先；方言闸门自动区分 CangDB 子集与 MySQL 全量构造
- **健康检查** — K8s 风格 liveness（`/healthz` 恒 200）+ readiness（`/health` 跑探针，失败 503 + 明细报告）
- **生命周期** — `onListen` / `onShutdown` 钩子 + 优雅关闭（排空在途请求）
- **输出归一化** — 容错 JSON 提取（剥 markdown 围栏）`extractJson` + 声明式 schema 校验 `JsonSchema`（一次报全错误）
- **安全** — 日志脱敏 `redact`（遮蔽 Bearer/api_key/token 等 14 个敏感字段）
- **进阶** — gzip 压缩 / multipart 上传（字节级二进制安全）/ SSE 流式 / 配置加载 / 性能基准

## 快速上手（5 分钟）

```cangjie
let router = Router()
    .get("/", { ctx: Context, _: () -> Unit => ctx.status(200).body("hello") })
    .post("/users", { ctx: Context, _: () -> Unit => ctx.status(201).json("{\"ok\":true}") })

let app = QingZhouApp()
    .use(requestId())
    .use(logger())
    .use(bodyParser())
    .use(router.middleware())
    .onError(jsonErrorHandler())

app.listen(3000)
```

### 作为库使用（推荐）

QingZhou 也能「安装库 → import 使用」，不需要框架源码。

> **一键安装 `qz` 命令**（已独立成 CLI 工具仓库 [qingzhou-cli](https://gitcode.com/xuguowei/qingzhou-cli)）：
>
> ```bash
> # macOS / Linux / Git Bash
> curl -fsSL 'https://api.gitcode.com/api/v5/repos/xuguowei/qingzhou-cli/raw/install.sh?ref=main' | sh
> ```
>
> ```powershell
> # Windows PowerShell
> irm 'https://api.gitcode.com/api/v5/repos/xuguowei/qingzhou-cli/raw/install.ps1?ref=main' | iex
> ```
>
> 装好后任意目录可用全局 `qz`。

```bash
qz install                      # 1. 拉取框架并编译为库（等价 npm i）
qz run my-app.cj 3000           # 2. 编译并运行你的应用
```

```cangjie
// my-app.cj —— 只需 import qingzhou.*，其余由 qz 自动补齐
import qingzhou.*

main() {
    let router = Router()
        .get("/", { ctx: Context, _: () -> Unit =>
            ctx.status(200).header("content-type", "text/plain; charset=utf-8").body("hello") })
    let app = QingZhouApp().use(router.middleware())
    app.listen(3000)
}
```

`qz` 自动处理 `--import-path` / `-L` / `-l` 与 stdx 依赖。示例见 `examples/lib_hello.cj`。若在框架仓库内开发，用 `./build.sh` 源码直编。

### 源码构建（框架开发者）

若需要构建框架本体 / 跑单测 / 启动演示服务，用 `build.sh` 源码直编（Linux / macOS / Windows Git Bash，详见 `build.cmd.txt`；cjpm 在本机不稳定，走 cjc 直编）：

```bash
./build.sh build          # 编译主程序
./build.sh test           # 编译并运行 211 项单测
./build.sh serve 3000     # 启动演示服务
curl http://127.0.0.1:3000/
```

`build.sh` 自动探测平台与 stdx 路径；Windows 下编译前需先杀旧进程（老 exe 锁文件导致 lld Permission denied）。

## 目录结构

```
qingzhou/
├── src/                 # 框架源码（43 个 .cj，单包）
│   ├── compose.cj       # 洋葱调度 + 错误链
│   ├── context.cj       # Context：请求代理 + 响应缓冲
│   ├── app.cj           # QingZhouApp + 优雅关闭（ServerHandle）
│   ├── router.cj        # Trie 路由
│   ├── cookies.cj       # Cookie 读写 + RFC 6265 选项
│   ├── static.cj        # 静态资源（Range/ETag/Last-Modified/缓存）
│   ├── mime.cj          # MIME 查表
│   ├── range.cj         # Range 解析（单段 + 多段 multipart）
│   ├── etag.cj          # ETag 生成/匹配 + HTTP date
│   ├── bodyparser.cj    # bodyParser 中间件
│   ├── requestid.cj     # requestId 中间件
│   ├── logger.cj        # logger 中间件
│   ├── cors.cj          # CORS 中间件
│   ├── timeout.cj       # timeout 中间件
│   ├── compress.cj      # gzip 压缩中间件
│   ├── multipart.cj     # multipart/form-data 解析
│   ├── config.cj        # 配置容器 + key=value 加载
│   ├── jsonx.cj         # JSON 序列化 + 安全访问器
│   ├── jwt.cj           # 标准 JWT（HS256 + base64url + exp 过期）
│   ├── api.cj           # 统一响应壳 respondOk/respondErr
│   ├── auth.cj          # token 鉴权中间件（authRequired）
│   ├── ratelimit.cj     # 请求限流中间件（固定窗口 429）
│   ├── securityheaders.cj # 安全响应头中间件（nosniff/DENY/CSP）
│   ├── circuit.cj       # 熔断器（closed/open/half-open 状态机）
│   ├── websocket.cj     # WebSocket 支持（upgradeWebSocket/wsHandler）
│   ├── hybrid.cj        # session + JWT 混合认证
│   ├── httpclient.cj    # 出站 HTTP 调用薄封装（httpGetText/Json/PostJson）
│   ├── outbound.cj      # 出站增强（TLS/重试退避/并发上限/HttpTransport 可注入）
│   ├── jsonschema.cj    # 声明式 JSON schema 校验
│   ├── security.cj      # 密码哈希 + 签名 cookie
│   ├── session.cj       # 服务端 session
│   ├── store.cj         # RbacStore 数据访问层（依赖 DbBackend 接口）
│   ├── rbac.cj          # requirePermission RBAC 中间件
│   ├── db.cj            # DbBackend 抽象接口 + DbResultSet
│   ├── db_cangdb.cj     # CangDB 后端（实现 DbBackend）
│   ├── db_mysql.cj      # MySQL 后端（实现 DbBackend，需驱动）
│   ├── db_factory.cj    # openStore / openPool 工厂（按 DSN 选后端）
│   ├── dbpool.cj        # DbPool 接口 + SimpleDbPool 线程安全连接池
│   ├── dbquery.cj       # 流式查询构建器（参数化优先 + 方言闸门）
│   ├── health.cj        # 健康检查中间件（liveness + readiness）
│   ├── util.cj          # 内置解析器
│   ├── middleware.cj    # jsonErrorHandler + respond 助手
│   ├── unit_tests.cj    # std.unittest 场景
│   └── manual_runner.cj # 手动断言 runner（cjc 直编入口）
├── examples/            # 11 个示例（hello/REST API/静态站/中间件/博客/HTTPS/WS/HTTP client/后台管理/DB todo/库用法）
├── admin-web/           # 后台管理系统前端（Vue 3 + Vite，构建产物 dist/ 已托管）
├── public/              # 静态资源 demo（PNG/SVG/CSS/JS/250KB bin）
├── public_blog/         # 博客示例前端静态资源
├── docs/                # 9 份文档 + OpenAPI 规范（见下表）
├── build.sh             # 跨平台构建脚本（build/test/serve/examples/clean）
├── build.cmd.txt        # Windows 下已验证的 cjc 编译命令 + curl 验证手册
├── deploy.sh            # 博客部署脚本（启停 / 健康检查 / 优雅关闭）
├── deploy-admin.sh      # 后台管理部署脚本（鉴权关闭 / 健康检查）
├── benchmark.cj         # 性能压测（微基准 + 端到端吞吐）
├── blog.env             # 博客示例环境配置
├── admin.env            # 后台管理示例配置（端口 / 密钥 / token 有效期）
├── cjpm.toml            # 备用（Windows cjpm 不稳定，见文件内说明）
├── CHANGELOG.md         # 版本变更记录
├── LICENSE              # MIT 许可证
└── README.md
```

## 文档

| 文档 | 说明 |
|------|------|
| [API.md](docs/API.md) | 全量 API 参考（签名 / 默认值 / 示例） |
| [CAVEATS.md](docs/CAVEATS.md) | 仓颉语言坑 + stdx API 反直觉点 |
| [PACKAGING.md](docs/PACKAGING.md) | 包拆分与发布方案 |
| [BENCHMARK.md](docs/BENCHMARK.md) | 性能基准（微基准 + 端到端吞吐） |
| [DEPLOYMENT.md](docs/DEPLOYMENT.md) | 部署指南（启停 / 健康检查 / 优雅关闭） |
| [openapi.yaml](docs/openapi.yaml) | 后台管理系统 API 的 OpenAPI 3.0 规范 |
| [DATABASE.md](docs/DATABASE.md) | 多数据库支持与切换（DbBackend 抽象层） |
| [CODE_STYLE.md](docs/CODE_STYLE.md) | 编码规范与仓颉注释避坑 |
| [TOOLCHAIN.md](docs/TOOLCHAIN.md) | 工具链兼容矩阵（cjc / stdx 版本配对与切换） |

## 示例

[examples/](examples/README.md) 11 个独立可跑示例：

- `hello.cj` — 最小应用
- `rest_api.cj` — 内存 todo CRUD（bodyParser / requestId / 分页）
- `static_site.cj` — 静态站 + Range/ETag/CORS
- `middlewares.cj` — 中间件组合（reflect CORS / JSON 日志 / 超时）
- `blog.cj` — 完整博客（用户系统 + 文章 CRUD + 鉴权 + 静态前端）
- `https.cj` — HTTPS 服务（`serveTls` / TLSv1.3 / 自签证书）
- `ws.cj` — WebSocket echo 服务（`wsHandler` / 双向长连接）
- `http_client.cj` — 出站 HTTP 调用 + 熔断器降级
- `admin.cj` — 前后端分离后台管理系统（JWT + RBAC + CangDB 持久化 + Vue 前端）
- `db_todo.cj` — 轻舟 × CangDB 集成（嵌入式数据库持久化，重启不丢）
- `lib_hello.cj` — 库安装方式使用（配合 `qz` 工具，见上文「作为库使用」）

## 测试

```text
$ build\qingzhou.exe test
...
All 211 unit-test scenarios PASSED
```

`src/unit_tests.cj`（`std.unittest` 的 `@Test`/`@Expect`）与 `src/manual_runner.cj`（手动断言）
维护同一份场景，cjc 直编跑手动版，无需依赖 `cjpm test`。

## 已知边界

详见 [docs/CAVEATS.md](docs/CAVEATS.md)，关键几条：

- **仓颉块注释支持嵌套** — 注释里写 `/*`（如 `text/*`）会开新嵌套吞掉后续代码，**铁律：块注释里绝不写 `/*` 字面量**
- **stdx `ResponseBuilder` 是不可变链** — `b.body(bytes)` 不接返回值则 body 改动丢失（content-length: 0）
- **仓颉 std 无 Windows OS 信号** — 优雅关闭走 HTTP 端点（`getEnv` 自 1.2.0 起由 `std.env` 提供）
- **stdx 服务器默认请求体上限较低** — 约 8MB 即拒收（"The content too large."），大文件上传场景用 `app.serve(port, maxRequestBodySize: Some(n))` 调大
- **Windows 下编译前需先杀旧进程** — 老 exe 锁文件导致 lld Permission denied

## 编码规范

注释风格与仓颉注释避坑见 [docs/CODE_STYLE.md](docs/CODE_STYLE.md)。

## License

[MIT](LICENSE) © 2026 guowei, BIT Foundational Software And Systems Lab
