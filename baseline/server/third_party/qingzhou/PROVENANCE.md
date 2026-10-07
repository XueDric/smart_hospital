# 内置轻舟（QingZhou）框架快照

本目录固定一份可复现的轻舟源码快照，服务端构建不会读取仓库外的轻舟目录。

| 项 | 值 |
| --- | --- |
| 上游仓库 | https://gitcode.com/BIT-FSSLab/QingZhou |
| 上游 commit | `3d6c1a3635f9aa4a191cd6aa5ede8bf3a387b753`（**v0.12.0 之后的 HEAD**；最近标签为 `v0.12.0 = 871ff16`） |
| 快照时间 | 2026-10-02 |
| 工具链基线 | cjc 1.2.0 + stdx 1.1.3.1 |
| 完整性 | `MANIFEST.sha256`（由当前仓库已跟踪文件生成） |
| 许可证 | `LICENSE`（MIT） |
| 上一版 | `fbc823d`（自述对应 v0.10.0）—— ⚠ **该哈希在上游已查不到**，见下方「供应链核对」 |

## v0.12.0 带来的能力（本次快照同步的主要内容）

自 v0.10.0 起上游有 8 个新提交，其中两个版本直接补齐了「服务端出站调用大模型 API」所需的框架能力：

| 版本 | 内容 |
| --- | --- |
| v0.11.0 (`4354eba`) | **出站增强**：HTTPS/TLS 客户端 · 重试退避 · 可注入传输层 |
| v0.12.0 (`871ff16`) | **出站并发控制** · 容错 JSON 提取 · schema 校验 · 日志脱敏 |
| v0.12.0 之后 6 个提交 | 路由静态分支 404 误判修复 · 参数化查询 · MySQL `NO_BACKSLASH_ESCAPES` · NULL 列崩溃修复 |

新增源文件三个：`src/outbound.cj`（405 行，`OutboundClient`/`HttpTransport`/`StdxTransport`/`MockTransport`/`RetryPolicy`/`OutboundTlsOptions`）、
`src/jsonschema.cj`（193 行，`JsonSchema` 校验）、`src/dbquery.cj`（610 行，参数化查询）。

> 对照「服务端大模型出站调用」的需求，详见 `docs/llm-client-spec.md` §14 —— 该节逐条核对了本快照提供的能力与仍需项目自写的部分。

## 供应链核对（2026-10-02）

| 项 | 结论 |
| --- | --- |
| 上一版记录的 `fbc823d` | ❌ **上游 `git log --all` 无此提交**（很可能来自上游改写历史之前的旧哈希） |
| 上一版快照的 `src/*.cj` 内容 | ✅ 与上游标签 **v0.10.0 (`f0dd9851`)** 的 `src/*.cj` **逐字节一致**（SHA-256 全等） |
| 本版快照的 `src/*.cj` 内容 | ✅ 与上游 `3d6c1a36` 的 `src/*.cj` **逐字节一致**（63 个受跟踪文件全部核对） |

→ 即：**内容一直可信，只是哈希要能被上游核验**。本次已改为上游现存的实际 commit。

v0.12.0 把工具链保持在 cjc 1.2.0，并加入出站 TLS、重试退避、可注入传输层、出站并发控制、容错 JSON 提取、schema 校验、日志脱敏、参数化查询等能力。项目构建脚本按同一版本重新编译框架与本地业务源码；框架源码与业务源码仍在一次 cjc 调用中编译，避免二进制接口漂移。

## 快照内容

仓库保留上游 `src/*.cj`（**46 个**，含本次新增的 `outbound.cj` / `jsonschema.cj` / `dbquery.cj`）、
`examples/admin.cj`、`admin-web/`、`admin.env`、`README.md`、`CHANGELOG.md`、`cjpm.toml` 和许可证文件。
上游的其他演示站点（`examples/` 下的 `hello.cj`、`https.cj`、`rest_api.cj`、`blog.cj` 等 14 个文件）
**没有进入项目构建输入**，按既有约定不纳入快照。

`server/build.ps1` 根据目标选择框架文件：

- 默认 `club-server` 排除上游入口、测试、RBAC 存储和 CangDB 工厂，使用项目的 `fw_rbac*.cj` 适配层；MySQL 抽象层与内置驱动仍参与编译。
- `-Target admin` 保留框架 `store.cj` 与 MySQL 后端，排除 CangDB 工厂文件，由项目自己的运维入口接入业务库。

## 升级纪律

升级时先更新 `UPSTREAM_COMMIT`，再用同一份上游文件集覆盖快照并重新生成 `MANIFEST.sha256`。随后检查 `server/src/fw_rbac_store.cj`、`server/src/fw_rbac.cj` 与框架 API 是否仍匹配，并重编 MySQL 驱动。

框架文件保持上游原样；项目行为修复放在 `server/src` 或构建脚本中。任何快照变更都要重新执行服务端单测、HTTP 冒烟、TLS、客户端契约、后台和运维页检查。

## Android 交叉编译

仓颉 1.2.0 的 Android 支持通过独立的 `android/build.ps1` 试验入口验证。该入口只编译平台无关的 Cangjie 适配层，不把 Windows 服务端（TLS、MariaDB 和文件系统依赖）直接当作 Android 应用；完整 Android UI 仍由 Android 工程承载。
