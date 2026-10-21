# tools/ —— 打包与仓库卫生工具

## 这是什么

| 脚本 | 作用 |
| --- | --- |
| `package-release.ps1` | 把服务端编译产物打成**可运行程序包**（Windows x64）。解压 → 改配置 → 起库 → 双击/命令行启动，不需要装 .NET、不需要装 OpenSSL。 |
| `check-docs.ps1` | **仓库卫生门禁**：文档相对链接、`.ps1`/`.bat` 编码、旧仓库路径残留、源码注释里未闭合的 `/*`。CI 每次 push 都跑（`.github/workflows/repo-hygiene.yml`）。 |
| `set-ai-key.ps1` | **换成你自己的大模型密钥**（一条命令）：写 `server\ai-key.txt`（已 gitignore）→ 把 `ai.key_ref` 改成 `file:<绝对路径>` → 调模型自检回显 `ok=true`。用于内置演示密钥到期后、或评委想用自己的额度时。 |
| `verify-source-manifest.ps1` | **源码清单校验**：按 `server/build/SOURCE-MANIFEST.sha256` 逐行核 76 个参与编译的源文件（路径相对 `server/`）。缺文件 exit 1、缺清单 exit 2。CI 的 `source-manifest` job 用它证明「交付的 exe 对应的就是这份源码」。 |
| `ci-pure-tests.ps1` | **CI 纯逻辑三件套**：`selftest` / `authtest` / `triagetest`，不需要数据库。找不到 exe 时打印 SKIP 并 exit 0（诚实跳过，不是假绿）——CI 里代替它的角色已交给会真编译的 `build-and-test`。 |
| `resolve-cangjie-sdk-url.ps1` | **CI 用**：在仓库变量/环境变量都没给 SDK 直链时，从仓颉官网**嗅探**一个可能的 1.2.0 Windows x64 zip 直链（只认 cangjie+版本+`.zip`，不猜 CDN）。嗅不到就 exit 1，让 job 诚实报「编译层未执行」。 |
| `set-ci-sdk-url.ps1` | **（可选）覆盖 CI 的 SDK 来源**：CI 默认从本仓库 release `sdk-cache-1.2.0` 下安装包，正常情况下不用配；想换别处托管的包时才用它——校验 URL 真能下到 zip/exe，再调 GitHub API 写/更新仓库变量 `CANGJIE_SDK_URL`。详见下文。 |
| `check-snapshot.ps1` | **交付物一致性校验**：比对 `docs/交付快照.md` 里的版本/提交/HAP/APK/zip 的体积与 SHA256 与磁盘真值；`-Update` 用真值刷新快照。CI 每次 push 都跑（默认严格模式）。 |

部署全流程（环境要求、起库、生产 TLS、探活语义、故障排查）见 **[../docs/DEPLOYMENT.md](../docs/DEPLOYMENT.md)**；
本文件只讲上面这些脚本本身。

## package-release.ps1

### 用法

```powershell
cd E:\harmonyOS\smart_hospital
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\package-release.ps1
```

> 本仓库在 `E:` 上、执行策略为 `RemoteSigned` 时，未签名脚本会被拦
> （`无法加载文件 …未对文件进行数字签名`）。用 `-ExecutionPolicy Bypass` 跑单次即可，
> 不要为此改机器级策略。

参数：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-OutDir` | `release`（相对仓库根） | 产物目录；相对路径按仓库根解析 |
| `-Version` | 源码 `SERVER_VERSION` | 读 `server/src/main.cj:34`；读不到用 git 短 SHA；再不行用 `dev` |
| `-SkipBuild` | 关 | 跳过 `server\build.ps1`，直接打包 `server\build\` 现有产物 |

### 它按顺序做什么

1. 停掉正在跑的 `hospital-server`（否则编译输出被占用）。
2. 调 `server\build.ps1` 真编译（**首次克隆**还要先 `server\build-mysql-driver.ps1`，否则报
   `can not find package 'mariadb.cdbc'`；脚本会把这个失败原样抛出）。
3. 缺 4 个运行时 DLL 时自动调 `server\setup-runtime.ps1 -OutDir server\build`。
4. 收 `server\build\` **顶层**可运行文件（exe + 4 个 DLL + `SOURCE-MANIFEST.sha256`），
   跳过 `*.cjo`、`*.log`、`*.pem`/`*.key` 与 `mysql-driver\` 等编译中间产物/密钥材料；
   再收 `server\admin-web\`（存在才收）与 `server\export-ca-bundle.ps1`（AI 出站 TLS 信任锚的导出脚本）。
5. 生成 `README-运行说明.txt`（UTF-8 **with BOM**）与 `start-dev.cmd`（双击启动，改里面的 `DSN`/`PORT`，
   默认端口 **8091**，与服务端/客户端默认值一致；启动前会**自动导一次 CA 包**并设 `SSL_CERT_FILE`）。
6. **5b. 打许可文件（2026-10-17 加，对应评审 P0-5）**：`LICENSE.txt`、`THIRD-PARTY.md`、
   `licenses/qingzhou-LICENSE.txt`、`licenses/mariadb-driver-LICENSE.txt`，并生成 `NOTICE.txt`
   （UTF-8 with BOM；轻舟 MIT、MariaDB 驱动 Apache-2.0、OpenSSL 3、仓颉运行时 DLL、admin-web 零框架共 5 项归属）。
   这一步不是可选装饰：Apache-2.0 的 §4 要求分发时随附许可证与归属声明。
7. 打 zip 到 `$OutDir\hospital-server-<Version>-win-x64.zip`（条目分隔符统一 `/`，跨工具可解）。
8. 打印包内清单、文件数、压缩前后体积、总耗时；删掉临时 staging 目录。

幂等：重复跑覆盖旧包。失败一律非 0 退出并打印原因。

### 实测数字（本机，`SERVER_VERSION = 0.2.0-p1`）

| 项 | 值 |
| --- | --- |
| 编译耗时（`server\build.ps1`） | **21.1 s**（首次另需驱动编译 5.9 s） |
| 整包耗时 | **23.6 s**（`-SkipBuild` 时 1.5 s） |
| 包内文件数 | **21**（运行时 9 + 许可 5 + admin-web 7 合 1 项计 → 清单 11 项 + CA 导出脚本） |
| zip 体积 | **7.83 MB** |
| 解压后体积 | **22.22 MB** |
| 产物 | `release\hospital-server-0.2.0-p1-win-x64.zip` |

包内清单：

```
hospital-server.exe           14 620.5 KB
libcangjie-runtime.dll         1 246.5 KB
libboundscheck.dll                43.0 KB
libcrypto-3-x64.dll            5 669.2 KB
libssl-3-x64.dll               1 002.7 KB
SOURCE-MANIFEST.sha256             7.1 KB
admin-web/  (7 个文件)          ~112 KB
README-运行说明.txt                5.5 KB
start-dev.cmd                      0.6 KB
LICENSE.txt                        1.1 KB
NOTICE.txt                         1.9 KB
THIRD-PARTY.md                    13.1 KB
licenses/qingzhou-LICENSE.txt      1.1 KB
licenses/mariadb-driver-LICENSE.txt 11.3 KB
export-ca-bundle.ps1               3.4 KB
```

> **CA 信任锚为什么不随包**：仓颉 stdx 走 OpenSSL、不读 Windows 证书存储，AI 出站需要 `SSL_CERT_FILE`
> 指向一份 PEM。但机器导出的 PEM 可能含**企业内网根证书**，随包分发等于泄露内网拓扑 ⇒
> 包里只放**导出脚本**，目标机首次启动时自己导（`start-dev.cmd` 已自动化这一步）。
> 换网络/换代理后要重导一次；判据是 `POST /api/v1/admin/ai/models/:id/test` 返回
> `data.probe.ok=true` 且 `http_status=200`。

解压验证（`%TEMP%`，ASCII 路径）：

- `hospital-server.exe version` → `0.2.0-p1`（退出码 0）
- `hospital-server.exe selftest` → `✅ 自检全部通过`，51 项 0 失败
- `serve` 起来后 `/health` → **200**，`{"ok":true,…,"db":{"ok":true,"reconnects":0}}`
- `/admin/` → **200**（3516 字节）

### 注意

- **`release\` 是按白名单入库的**（2026-10-17 改）：`.gitignore` 是 `/release/*` + `!/release/harmony/`，
  即 `release/harmony/` 下的**鸿蒙构建证据**会入库，而 `hospital-server-*.zip` 这类每次体积都变的产物不入库。
  不要手工 `git add -f release/*.zip`。
- 包解压后请放在**纯 ASCII 路径**（如 `C:\hospital`）再运行：仓颉运行时读不了含中文的 argv，
  证书路径同理。
- 包内**不含**证书与私钥，也不含数据库：生产部署请用 `server\new-tls-cert.ps1` 另配证书。
- 包内 `SOURCE-MANIFEST.sha256` 记的是**源码哈希**：验收比源码哈希 + 测试结果，
  不要比 exe 哈希（cjc 产物不逐字节可复现）。
- 脚本本身含中文，必须保持 **UTF-8 with BOM**（用编辑器改完请确认 BOM 还在，
  否则 PS 5.1 会 `Unexpected token`）。`check-docs.ps1` 第 2 项会替你检查。

## check-docs.ps1 —— 仓库卫生门禁

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\check-docs.ps1
```

查五项，任一不过退出码 1：

| # | 检查 | 为什么要有 |
| --- | --- | --- |
| 1 | 所有 `.md` 的**相对链接**指向真实文件（外链、页内锚点、`third_party/` 内的上游 README 跳过） | 本项目改目录、改措辞后曾出现坏链（`HISTORY-PROJECT-BRIEF.md` 指向仓库根的那两条） |
| 2 | 含非 ASCII 的 `.ps1` 必须有 **UTF-8 BOM** | PS 5.1 按 ANSI 解析会乱码/`Unexpected token`；实测踩过（`new-tls-cert.ps1`、`package-release.ps1`） |
| 3 | `.bat`/`.cmd` 必须**纯 ASCII** | cmd 在 GBK 代码页下会把 UTF-8 中文注释解析坏，实测报 `'wrapper.js' is not recognized` |
| 4 | 任何文件都不得再出现**旧的中文仓库绝对路径** | 2026-10-17 仓库改名为 `smart_hospital`；防止文档/脚本又写回旧路径 |
| 5 | **源码注释正文里不得出现** `/*`（`.kt` / `.ets` / `.cj` / `.java` / `.ts`） | Kotlin 与仓颉的块注释**可嵌套**：注释里写一句 `shared_prefs/*.xml` 就会再开一层、原文的 `*/` 只关掉内层 ⇒ 整文件 `Unclosed comment`，还会连带别的文件报 `Unresolved reference`（2026-10-18 实测）。字符串字面量（如路由 `"/files/*"`）与 `//` 行注释里的 `/*` 不算 |

例外（写死在脚本里、有注释说明）：
脚本自身要写出被查的路径模式。**新增例外请连理由一起写**，否则下次没人知道为什么放行。

CI：`.github/workflows/repo-hygiene.yml` 在每次 push/PR 上跑同一条命令。
服务端重活（`build.ps1` + `server/tests/` + `final-verify.ps1`）**故意不上 CI**——需要 cjc 1.2.0、
stdx 1.1.3.1、自编 MariaDB 驱动和 MariaDB 实例，托管 runner 装不全，硬凑的红灯只会被绕过。

## set-ai-key.ps1 —— 换自己的大模型密钥

```powershell
# 完整流程：写文件 → 改 ai.key_ref → 调模型自检
.\tools\set-ai-key.ps1 -ApiKey sk-你自己的 -AdminPw <管理员口令>

# 只写文件（服务端还没起、或想手工改配置）
.\tools\set-ai-key.ps1 -ApiKey sk-你自己的 -WriteOnly
```

| 步骤 | 动作 | 为什么这么设计 |
| --- | --- | --- |
| 1 | 写 `server\ai-key.txt`（**无 BOM**、纯 ASCII，`.gitignore` 已排除） | BOM 会被当成密钥的一部分 ⇒ 明明密钥对却一直 401，是最难查的一类症状 |
| 2 | `PUT /api/v1/admin/ai/settings/ai.key_ref` = `file:<绝对路径>` | 库里仍然只存**引用**，不存密钥本体（`ai_settings.cj` 的不变量） |
| 3 | `POST /api/v1/admin/ai/models/<默认对话模型>/test`，回显 `ok / http_status / 耗时` | 换密钥后必须**现场自证**，不能"改完就当成功" |

失败时只打印状态码与错误码、**不回显响应体**——万一是把密钥误填进了别的字段，
回显就等于把它写进日志。内置演示密钥的有效期机制见
[../server/src/ai_builtin.cj](../server/src/ai_builtin.cj) 的 `AI_BUILTIN_DEMO_VALID_UNTIL`。

## set-ci-sdk-url.ps1

> **正常情况下你不需要这个脚本。** CI 默认从本仓库的 release `sdk-cache-1.2.0`
> 下载官方安装包并 `/S /D=` 静默安装，不依赖任何签名直链。只有当你想改成
> 「别处托管的 zip/exe」时，才需要用它覆盖仓库变量 `CANGJIE_SDK_URL`。

背景：官方下载页
（<https://cangjie-lang.cn/download/1.2.0>）的直链是**点击时由前端签名生成**的，
`curl` 拿不到（对任意路径都回 `200 + text/html`，看起来像成功、其实是网页兜底）。
所以这一步只能由人在浏览器里做一次：

1. 打开下载页 → 点「Windows x64 SDK 下载」；
2. F12 → Network → 找到类型是 `x-zip` / `octet-stream` 的那一条请求 → 右键 Copy → Copy link address；
3. 把复制的直链交给脚本（**一条命令**，其余全自动）：

```powershell
cd E:\harmonyOS\smart_hospital
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\set-ci-sdk-url.ps1 -Url '<粘贴直链>'
```

脚本做四件事：校验（HTTP 200/206 + 不是 `text/html` + 像 zip）→ 取 token（`$env:GITHUB_TOKEN`
或本机 git 凭据）→ `POST`/`PATCH` 写仓库变量 `CANGJIE_SDK_URL` → 回读确认。token 全程不打印；
token 需要 `repo` 作用域（或 fine-grained 的 Variables: Read and write）。

只想校验不想写：加 `-DryRun`。换仓库/换变量名：`-Repo owner/name -Name OTHER_NAME`。

配好之后，Actions 里手动跑一次 **Repo Hygiene**，`build-and-test` 的「校验 SDK 压缩包」这一
步通过即说明直链持续可用（直链带签名时可能几小时就失效，失效时重跑一次本脚本换新链接即可；
失效不会让 job 假绿 —— 它会失败并说明原因）。
