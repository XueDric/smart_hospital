# tools/ —— 打包工具

## 这是什么

`package-release.ps1`：把服务端编译产物打成**可运行程序包**（Windows x64）。
解压 → 改配置 → 起库 → 双击/命令行启动，不需要装 .NET、不需要装 OpenSSL。

部署全流程（环境要求、起库、生产 TLS、探活语义、故障排查）见 **[../docs/DEPLOYMENT.md](../docs/DEPLOYMENT.md)**；
本文件只讲这个脚本本身。

## 用法

```powershell
cd E:\harmonyOS\智能医院客户端
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

## 它按顺序做什么

1. 停掉正在跑的 `hospital-server`（否则编译输出被占用）。
2. 调 `server\build.ps1` 真编译（**首次克隆**还要先 `server\build-mysql-driver.ps1`，否则报
   `can not find package 'mariadb.cdbc'`；脚本会把这个失败原样抛出）。
3. 缺 4 个运行时 DLL 时自动调 `server\setup-runtime.ps1 -OutDir server\build`。
4. 收 `server\build\` **顶层**可运行文件（exe + 4 个 DLL + `SOURCE-MANIFEST.sha256`），
   跳过 `*.cjo` 与 `mysql-driver\` 等编译中间产物；再收 `server\admin-web\`（存在才收）。
5. 生成 `README-运行说明.txt`（UTF-8 **with BOM**）与 `start-dev.cmd`（双击启动，改里面的 `DSN`/`PORT`）。
6. 打 zip 到 `$OutDir\hospital-server-<Version>-win-x64.zip`（条目分隔符统一 `/`，跨工具可解）。
7. 打印包内清单、文件数、压缩前后体积、总耗时；删掉临时 staging 目录。

幂等：重复跑覆盖旧包。失败一律非 0 退出并打印原因。

## 实测数字（本机，`SERVER_VERSION = 0.2.0-p1`）

| 项 | 值 |
| --- | --- |
| 编译耗时（`server\build.ps1`） | **21.1 s**（首次另需驱动编译 5.9 s） |
| 整包耗时 | **23.6 s** |
| 包内文件数 | **15** |
| zip 体积 | **7.81 MB** |
| 解压后体积 | **22.18 MB** |
| 产物 | `release\hospital-server-0.2.0-p1-win-x64.zip` |

包内清单（15 个）：

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
```

解压验证（`%TEMP%`，ASCII 路径）：

- `hospital-server.exe version` → `0.2.0-p1`（退出码 0）
- `hospital-server.exe selftest` → `✅ 自检全部通过`，51 项 0 失败
- `serve` 起来后 `/health` → **200**，`{"ok":true,…,"db":{"ok":true,"reconnects":0}}`
- `/admin/` → **200**（3516 字节）

## 注意

- **`release\` 是生成物，通常不入库**。仓库 `.gitignore:81-82` 已收录 `release/`（本脚本不碰 `.gitignore`），
  所以 `git status` 里不会出现这个 zip；请也不要手工 `git add -f release/`——每次重新打包体积都会变。
- 包解压后请放在**纯 ASCII 路径**（如 `C:\hospital`）再运行：仓颉运行时读不了含中文的 argv，
  证书路径同理。
- 包内**不含**证书与私钥，也不含数据库：生产部署请用 `server\new-tls-cert.ps1` 另配证书。
- 包内 `SOURCE-MANIFEST.sha256` 记的是**源码哈希**：验收比源码哈希 + 测试结果，
  不要比 exe 哈希（cjc 产物不逐字节可复现）。
- 脚本本身含中文，必须保持 **UTF-8 with BOM**（用编辑器改完请确认 BOM 还在，
  否则 PS 5.1 会 `Unexpected token`）。
