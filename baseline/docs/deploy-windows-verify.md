# 服务端部署与验证（Windows）

> 📁 **Windows 部署与验证** ｜ 本文件：`deploy-windows-verify.md` ｜ [全部文档目录](README.md)

- 状态：**待执行**
- 服务器：**Windows**（与开发机同平台）
- 前置：`v1-scope.md` 技术栈已确认
- 关联：`frontend-brief.md`（轻舟 TLS 实测已移出仓库，见上层 `cangjie-upstream\qingzhou-tls-verification.md`）

> 本文替代原 `spike-linux-verify.md`。原文档基于「服务器是 Linux」的前提，**该前提已不成立**，
> 且其中大量内容（Linux SDK、glibc、交叉编译、`.so.3`）现在都不适用。**原文档已删除，避免误导。**

---

## 0. 服务器改为 Windows 带来的三个结论

| 结论 | 影响 |
| --- | --- |
| **同一平台，制品可直接复用** | 本机编好的 exe **拷过去就能跑**，不在服务器上装编译器 |
| **原「Linux 工具链」风险全部消失** | 不需要 Linux SDK、不涉及 glibc、不存在交叉编译问题 |
| **但 exe 不是自包含的** | 需随行 **4 个 DLL**，见第 2 节 |
| **还必须有可连的 MySQL / MariaDB**（2026-09-20 起） | club-server 的持久化已换成 **MySQL**，**没有它就起不来**（有意如此，不会带着空库继续跑）。库与 9 张表由程序自己建，但"一台可连的数据库"是硬前提 —— 见 §2.1 |

> **关于老师那句话**：同平台的情况下，他的判断**这次是对的**——但正确的理由是
> 「平台相同、制品可直接复用」，而不是"逻辑能跑所以哪儿都能跑"。
> 如果服务器是 Linux，同样的代码就要重编一遍，那是完全不同的工作量。

---

## 1. 目标配置基线（对齐本机，已验证）

| 项 | 本机（**已验证可用**）= 服务器目标 |
| --- | --- |
| 平台 | Windows x64 |
| 编译器 | cjc **1.2.0** (cjnative)。`build.ps1` **按版本探测**，本机实测选到 `C:\Users\<用户>\.cjenv\sdks\1.2.0\cangjie`（cjenv 装的 1.2.0）。⚠ 旧稿写的"项目内 `.tools\cangjie-1.2.0\cangjie`"**在本检出里不存在**；`PATH` 上的 `cjc` 是 **1.1.3**，脚本正是靠版本比对挑 1.2.0、不会被旧 shim 抢走（2026-10-04 据实更正） |
| stdx | **1.1.3.1**，`static` 静态链接进 exe |
| 轻舟 | **随仓库内置**：`server\third_party\qingzhou`（上游 **v0.12.0 之后的 HEAD / `3d6c1a36`**，见 `UPSTREAM_COMMIT` / `PROVENANCE.md`；构建时由 `MANIFEST.sha256` 校验内容）。快照里带 `examples\admin.cj` + 预构建的 `admin-web\` |
| 编译产物 | `club-server.exe`（本文早期写作 `main.exe`，已更名；由 `server\build.ps1` 产出） |
| 编译命令 | 第 4 节，**本机已实测通过** |

---

## 2. 部署文件集（**实测**：exe + 4 个 DLL，证书与启动脚本另计）

我们解析了 `club-server.exe` 的 PE 导入表，并追到了依赖链末端：

| 文件 | 体积 | 类型 | 说明 |
| --- | --- | --- | --- |
| `club-server.exe` | — | 应用本体 | 由 `server\build.ps1` 产出；体积随版本变化（早期称 `main.exe`，10.70 MB） |
| `libcangjie-runtime.dll` | 1.22 MB | **启动期依赖** | exe 的 PE 导入表直接引用 |
| `libboundscheck.dll` | 0.04 MB | 传递依赖 | `libcangjie-runtime.dll` 引用 |
| `libcrypto-3-x64.dll` | 5.54 MB | **运行时 `dlopen`** | 不在导入表里，crypto/TLS 用到时才加载 |
| `libssl-3-x64.dll` | 0.98 MB | **运行时 `dlopen`** | 同上 |
| 配置文件 / 证书 | — | | `blog.env` 一类 + 自签证书 |

### ⚠️ 对既有文档的两处修正

1. **轻舟技能的部署说明不准确。** 它写「交付物不是单文件 exe，而是 exe + **2** 个 DLL（约 +6.5 MB）」。
   实测是 **exe + 4 个 DLL，约 18.5 MB**（该次构建的实测值；当前产物由 `build-package.ps1` 给出，约 18.8 MB）——它**漏了 `libcangjie-runtime.dll` 与 `libboundscheck.dll`**。
   只拷那 2 个 OpenSSL DLL 的话，exe 启动时会直接报缺少 `libcangjie-runtime.dll`。
2. **不需要拷整个运行时目录。** `D:\Cangjie\runtime\lib\windows_x86_64_cjnative` 下有 **51 个 DLL**，
   但根据依赖链，**只需要上面那 2 个**。

> 依赖链已闭合：`libboundscheck.dll` 只依赖 `KERNEL32.dll` / `msvcrt.dll`，均为系统自带。

### 2.1 硬前提：一台可连的 MySQL（**2026-09-20 起**）

`club-server` 的持久化已从"启动读 `data/db.json` / 每次变更整库重写"换成 **MySQL**
（`server/src/mysql_store.cj`）。**它不再能只靠一个目录跑起来** —— 拿不到可连的 MySQL 时进程会打
`[FATAL] 连接 MySQL 失败…` 并退出；**这是有意设计**，不会带着空库继续跑（否则下一次落盘会把真实数据整体覆盖）。

| 要做的 | 说明 |
| --- | --- |
| 在服务器上准备一台 MySQL / MariaDB | 本机联调用便携版 MariaDB（3307）；服务器上端口 / 口令随意 |
| **不用手工建库建表** | 首次连接时程序自己 `CREATE DATABASE IF NOT EXISTS`（utf8mb4）+ 建 **9 张表**（7 张业务表 + 2 张元数据表）；账号**需要建库权限** |
| 启动时给 DSN | `mysql://用户:口令@主机:端口/库名`，或 `--mysql-host/--mysql-port/--mysql-user/--mysql-pass/--mysql-db`；本工具链的仓颉 std 没有 `getEnv`，**不能用环境变量配置** |
| `--data-dir` 只剩审计日志 | 业务数据不在文件里；`data\` 下只有 `audit.log`，`db.json` 不再产生也不再被读 |

> 部署包**不含数据库**（那是另一台机器 / 另一个服务的事），但目标机上必须有可连的 MySQL，
> 否则 `start-https.cmd` 里的 club-server 起不来。
> 详细做法与本机踩坑见 `local-deploy.md` §2.0 / §6 与 `docs/mysql-backend.md` §十二。

---

## 3. 仍需验证的事项（为数不多）

同平台后，本机替代了绝大部分验证。剩下这些**本机确实无法替代**：

| # | 事项 | 为什么本机替代不了 |
| --- | --- | --- |
| 1 | **服务器是 x64 还是 ARM64** | 若是 Windows on ARM，制品不能直接用，要重编 |
| 2 | **公网 IP 与端口可达性** | 本机没有公网入口 |
| 3 | **防火墙 + 云安全组** | Windows 防火墙与云安全组是**两层**，都要放行 |
| 4 | 服务器上**已有什么** | 避免与老师现有的服务冲突（端口 / 资源） |
| 5 | 能用多久、归谁管 | 关系数据能否长期留存 |

---

## 4. 编译：用 `server\build.ps1`（**不要**手动列文件）

**原来的 DEF-1 补丁已经不需要了**：上游 `141a735`（2026-09-14）修好了同一处，且实现更可移植
（我们原来用 `GeneralPrivateKey`，上游改用 `RSAPrivateKey.decodeFromPem`）。
旧补丁文本备份在上层 `cangjie-upstream\` 与 `E:\cangjie\def1-local-patch.patch`，**不要再打**。

**日常构建一律用仓库里的脚本**，它已经处理好全部例外：

```powershell
cd server
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
# 产出 build\club-server.exe，并把 4 个依赖 DLL 复制到 build\
```

编译轻舟时有**两处例外**（不是改框架源码，而是在我们仓库里提供替代实现）：

| 框架文件 | 处置 |
| --- | --- |
| `src/store.cj`、`src/rbac.cj` | 上游新版 `import cangdb.*`，而沧海 CangDB 虽已开源，其 1.0.5 版本却与 cjc 1.1.3 不兼容（编译通过、运行超时）→ **从编译列表里排除**，改用 `server/src/fw_rbac_store.cj`（文件存储的数据层）+ `server/src/fw_rbac.cj`（`requirePermission` 中间件，用我们的错误格式） |
| 框架自带的入口 / 单测文件 | 与本项目的 `main.cj` / `tests.cj` 冲突 → 同样排除（**完整排除列表见 `server/build.ps1` 顶部**） |

等 CangDB 有与 cjc 1.1.3 兼容的版本之后：删掉那两个适配文件、从 `build.ps1` 的排除列表里去掉
`store.cj` / `rbac.cj`，即回到上游原版 —— 见 `HANDOFF.md` §11 的 M9 条目。

> 本文其余部分（依赖链分析、TLS 逐协议验证、公网服务器待办）仍然有效；
> **构建与运行的权威命令以 `server-guide.md` 为准**。

---

## 5. 执行步骤

### 步骤 0 · 采集服务器基线（**先做这个，把输出回传**）

```powershell
# 架构与系统
[Environment]::Is64BitOperatingSystem
$env:PROCESSOR_ARCHITECTURE          # 应为 AMD64；若是 ARM64 需重编
[Environment]::OSVersion.Version

# 端口占用
netstat -ano | findstr "LISTENING"

# 防火墙现状
netsh advfirewall show allprofiles state
```

> 服务器上**已经跑了什么**务必先看清，别与老师的现有服务抢端口。

### 步骤 1 · 本机编译

见第 4 节。**本机已完成过一次，可直接复用现有产物。**

### 步骤 2 · 打包

**现在这一步有脚本了**：`server\build-package.ps1` 直接产出 `server\dist\club-server\`
（exe + 4 个 DLL + `certs\` + 启动脚本 + 部署说明，约 18.8 MB），整个目录拷到服务器即可。
手动打包的话，文件集是 **exe + 4 个 DLL**：

```
club-server\
  club-server.exe
  libcangjie-runtime.dll
  libboundscheck.dll
  libcrypto-3-x64.dll
  libssl-3-x64.dll
  certs\cert.pem  certs\key.pem    # 自签证书（带 SAN，见步骤 5）
```

### 步骤 3 · 拷到服务器并试跑

**注意：`cwd` 必须是 exe 所在目录**——配置与证书按相对路径读取。

```powershell
cd club-server
.\club-server.exe serve-tls 8443 "mysql://root:<口令>@<MySQL主机>:3306/club_server" --cert certs\cert.pem --key certs\key.pem
```

> ⚠ **2026-09-20 起这条命令的形状变了**：第 2 个位置参数是 **DSN**（不再是数据目录 `data`），
> 证书 / 私钥必须用 `--cert` / `--key`（不给就是 `certs\cert.pem` / `certs\key.pem`）。
> 照旧写法会先按默认连接参数（`127.0.0.1:3306 / root / 空口令`）试连 MySQL、连不上就直接 `[FATAL]` 退出；
> 就算 3306 上真有库，也会被 `存在多余的位置参数（serve-tls 的证书/私钥请用 --cert / --key）` 挡下。
> 审计日志目录改用 `--data-dir <目录>`。

→ **关卡 1、2**

### 步骤 4 · 逐个协议验证 TLS

用本机同一套命令（已实测通过）：

```powershell
$openssl = "D:\Program Files\Git\usr\bin\openssl.exe"
& $openssl s_client -connect <服务器IP>:8443 -tls1_2 -brief   # 期望成功
& $openssl s_client -connect <服务器IP>:8443 -tls1_3 -brief   # 期望成功
& $openssl s_client -connect <服务器IP>:8443 -tls1_1 -cipher "DEFAULT@SECLEVEL=0" -brief  # 期望被服务端拒绝
```

→ **关卡 3、4**

> ⚠️ 测 TLS 1.1 时**必须加 `@SECLEVEL=0`**，否则是客户端自己不肯发起（假阴性），
> 那不能证明服务端行为。详见上层 `cangjie-upstream\qingzhou-tls-verification.md` 第 4 节。

### 步骤 5 · 自签证书（**必须带 SAN**）

```powershell
$IP = "<服务器公网IP>"
& $openssl req -x509 -newkey rsa:2048 -nodes `
  -keyout cert.pem -out cert.pem.tmp `
  -days 3650 -subj "/C=CN/O=Club/CN=$IP" `
  -addext "subjectAltName=IP:$IP,DNS:localhost"
```

> ⚠️ **轻舟示例自带的证书没有 SAN，不能直接用**——现代客户端只认 SAN、完全忽略 CN。
> 我们的 App 要连 IP，SAN 必须写成 `IP:<公网IP>`。

### 步骤 6 · 验证 crypto 与落盘

→ **关卡 5、6**

### 步骤 7 · 常驻（Windows 服务）

Windows 没有 systemd，可选方案：

| 方案 | 说明 |
| --- | --- |
| **任务计划程序**（推荐） | 内置、可设开机启动 + 失败重启，最省事 |
| `sc.exe create` | 原生服务，但需要程序实现服务控制接口 |
| NSSM | 第三方包装器，简单可靠 |

**优雅关闭**：Windows 无 `std.runtime.Signal`，轻舟用 `POST /admin/shutdown` 端点实现；
若沿用该方案，**该端点必须限制为仅本机可访问**，否则任何人都能远程关停服务。

### 步骤 8 · 放行端口（**两层都要做**）

1. **Windows 防火墙**：`netsh advfirewall firewall add rule ...`
2. **云安全组**（华为云控制台）：入方向添加 8443

> 只做一层，从外面就是连不上。这是最常见的部署卡点。

---

## 6. 六个验收关卡

原 Linux 版的六个关卡全部保留，但**难度大幅下降**（同平台，工具链问题不复存在）：

| # | 关卡 | 判定标准 |
| --- | --- | --- |
| 1 | 服务能在服务器上启动 | 进程存活，日志无异常 |
| 2 | `GET /health` | 返回 **HTTP 200** |
| 3 | TLS 1.2 / 1.3 握手 | 成功 |
| 4 | TLS 1.0 / 1.1 | **被服务端拒绝**（alert 70） |
| 5 | **crypto 可用** | 调用哈希/session **不是 500** |
| 6 | 数据落盘可持久 | 写入 → 重启 → 仍能读到 |

---

## 7. 需要回传的信息

1. 步骤 0 的**全部**输出（尤其 `PROCESSOR_ARCHITECTURE`）
2. 服务启动后的完整日志
3. `openssl s_client` 的完整输出
4. 防火墙与安全组的放行结果

---

## 8. 风险与回退

| 风险 | 应对 |
| --- | --- |
| 服务器是 **ARM64 Windows** | 需在服务器上装仓颉 SDK 重编，或换实例 |
| 端口被老师现有服务占用 | 换端口，同步改安全组与客户端基地址 |
| 服务器可用期限不确定 | **每日备份到服务器之外**，交接给至少两人 |
| 轻舟 TLS 上游修复后行为变化 | 重新跑第 6 节关卡 3、4 |

> 回退成本很低：接口与数据模型是语言无关的（`api-design.md`），
> 真要换服务端实现，客户端一行不用改。
