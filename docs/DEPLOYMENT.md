# 部署与打包说明（DEPLOYMENT）

> 适用范围：本仓库 `E:\harmonyOS\smart_hospital` 的服务端（仓颉 + 轻舟）、管理台静态页、鸿蒙患者端、安卓患者端。
> 文中所有命令都在 **Windows PowerShell 5.1** 下验证过；行号引用均相对仓库根。
> 口径提示：端点的唯一事实来源是 `server/src/http_app.cj` 与 `docs/FRONTEND-INTEGRATION.md`，
> `server/README.md` 的端点清单比实现旧。

---

## 1. 环境要求

| 项 | 要求 | 出处 |
| --- | --- | --- |
| 操作系统 | Windows 10/11 x64 或 Windows Server 2019+ | 本机实测环境 |
| 仓颉 SDK | **1.2.0**，绝对路径口径 `C:\Users\ASUS\.cjenv\sdks\1.2.0\cangjie` | `server/README.md:17-22` |
| stdx | 1.1.3.1，静态 `E:\cangjie\stdx\windows_x86_64_cjnative\static\stdx` | `server/README.md:17-22` |
| OpenSSL | **3.x 动态库**（`libcrypto-3-x64.dll` / `libssl-3-x64.dll`），由 `server/setup-runtime.ps1` 拷到输出目录 | `server/setup-runtime.ps1:1-40` |
| 数据库 | MariaDB 11.4.13 或 MySQL 8.x，默认 `127.0.0.1:3317` | `docs/DEV-DB.md:13`；`server/devdb.ps1:34` |
| 库/账号 | 库 `hospital`（开发）/ `hospital_test`（测试）；账号 `hospital` / `hospital_dev_2026` | `docs/DEV-DB.md:18`；`docs/DEV-DB.md:69-70` |
| PowerShell | **5.1**（含中文的 `.ps1` 必须存为 UTF-8 **with BOM**） | `server/README.md:17-22`；`server/tests/final-verify.ps1:12` |
| 服务端版本 | `0.2.0-p1` | `server/src/main.cj:34` |
| 磁盘/内存 | 编译机 ≥ 3 GB 空闲磁盘（exe 约 14.3 MB + 依赖）、≥ 4 GB 内存；运行机 ≥ 2 GB 可用内存、≥ 200 MB 磁盘 | 本机实测 |

⚠ 两条硬约束（踩过坑）：
1. **PATH 上的 cjc 1.1.3 不可用**，症状是 `LLVM ERROR: Broken module found`。`server/build.ps1` 会自己按版本挑 1.2.0，别手工覆盖。
2. **路径不能含非 ASCII**：仓颉运行时读不了含非 ASCII 的 argv（路径一旦出现在命令行参数里就会失败）。**本仓库已改名为 `E:\harmonyOS\smart_hospital`（纯 ASCII），仓内路径的这条约束已解除**；只有当 exe / 证书被放到别的含中文目录时才需要换成 ASCII 副本（如 `C:\hospital`）。

---

## 2. 服务端部署（三步）

### ① 起开发库

```powershell
cd E:\harmonyOS\smart_hospital\server
powershell -ExecutionPolicy Bypass -File .\devdb.ps1 start     # 首次会 init 数据目录
powershell -ExecutionPolicy Bypass -File .\devdb.ps1 status    # 看是否在监听 3317
```

- 数据目录 `server\devdb\data`（不入库），日志 `server\devdb\mysqld.out.log` / `mysqld.err.log`。
- `devdb.ps1` 启动时带 `--bind-address=127.0.0.1`；**不要**去掉，否则 mysqld 监听 `0.0.0.0`。
- 测试脚本用 `server/tests/common.ps1` 里的 MySQL 客户端封装（`Invoke-MySqlScalar` / `Invoke-MySqlFile`），它**不负责起库**。
  > 注：任务书所述的 `Start-TestDb` 在本仓库**并不存在**（全仓 grep 无此符号），起库统一走 `devdb.ps1`。
- 也可用自有 MySQL；把下面 DSN 换成自己的即可。**DSN 形状**：

```
mysql://<user>:<pass>@<host>:<port>/<db>
mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital_test
```

### ② 建表与迁移（幂等）

`serve` 启动时自动 `ensureSchema`（`CREATE TABLE IF NOT EXISTS`）+ `migrateSchema`（隐式迁移），**不需要手工跑 SQL**：

- 对新库：一次建齐 17 条 DDL（实测 `check-db` 输出「建表：执行 17 条 DDL（IF NOT EXISTS，幂等）」）。
- 对已存在的库（升级）：DDL 不动已有表，由迁移补列/补索引；**不清数据、不 DROP**。重复启动无副作用。
- 想只验证连库+建表：`hospital-server.exe check-db <dsn>`（打印表清单，实测 1.7 s）。

### ③ 编译并启动

```powershell
cd E:\harmonyOS\smart_hospital\server
# 首次（全新克隆）先编一次 MariaDB 驱动，产物落 server\build\mysql-driver（已被 .gitignore 忽略）
powershell -ExecutionPolicy Bypass -File .\build-mysql-driver.ps1 `
  -CangjieHome 'C:\Users\ASUS\.cjenv\sdks\1.2.0\cangjie' `
  -Stdx 'E:\cangjie\stdx\windows_x86_64_cjnative\static\stdx'
# 编服务端（实测 20~25 s）
powershell -ExecutionPolicy Bypass -File .\build.ps1
# 把 4 个运行时 DLL 放到输出目录（build.ps1 不代劳）
powershell -ExecutionPolicy Bypass -File .\setup-runtime.ps1 -OutDir .\build
```

开发模式启动（绕过鉴权，只认回环来源）：

```powershell
cd E:\harmonyOS\smart_hospital\server
# AI 出站要带信任锚：仓颉 stdx 走 OpenSSL、不读 Windows 证书存储
powershell -ExecutionPolicy Bypass -File .\export-ca-bundle.ps1
$env:SSL_CERT_FILE = "$PWD\ca-bundle.pem"
.\build\hospital-server.exe serve "mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital_test" `
  --dev-auth --bind 127.0.0.1
```

- **AI 开箱即用**：默认 `ai.enabled=1` + 密钥引用 `builtin:demo` + DeepSeek `deepseek-chat`，启动日志会打印 `AI：已启用 — 模型「默认对话模型」，endpoint https://api.deepseek.com/chat/completions，密钥引用 builtin`。`builtin:demo` 是演示密钥、随源码分发，**发布前必须轮换成 `env:…` / `file:…`**（见 [Q6-合规决策记录](Q6-合规决策记录.md)）。
- **`SSL_CERT_FILE` 不设会怎样**：AI 出站报 `出站调用异常：TLS handshake failed (client): certificate verify failed (134), TLS alert unknown CA(F)`，而同一 endpoint 用 `curl` / .NET 访问都正常 —— 因为 OpenSSL 不读 `Cert:\LocalMachine\Root`。`export-ca-bundle.ps1` 把三个存储去重导出成 PEM（本机 76 张证）；**换网络（换代理/换 CA）后要重导**。分发包里带的是脚本不是 PEM（PEM 可能含企业内网根证书，绝不随包分发）。
- 端口默认 **8091**（`server/src/main.cj:707`），绑定默认 **127.0.0.1**（`server/src/main.cj:708`）。
- **服务端与客户端默认端口已对齐为 8091**（2026-10-17 由 8080 改为 8091，评审 P2-15）：鸿蒙 `common-core/src/main/ets/config/ApiConfig.ets:8` 与安卓 `DEFAULT_BASE_URL` 的默认值都是 `http://127.0.0.1:8091`，所以按上面这条命令起来客户端**零配置即可连**；要换端口就 `--port N` 并同步改客户端（见 §4/§5）。
- `--dev-auth` 与 `--prod` **不能同传**（同传直接拒绝启动）；`--dev-auth` 下 `X-Role` / `X-Patient-Id` 只对 `127.0.0.1` / `::1` 生效。

生产模式（HTTPS，绝不静默降级）：

```powershell
cd E:\harmonyOS\smart_hospital\server
powershell -ExecutionPolicy Bypass -File .\new-tls-cert.ps1       # 自签证书（含 SAN）
.\build\hospital-server.exe serve "mysql://hospital:<口令>@127.0.0.1:3317/hospital" --port 8091 --prod `
  --tls-cert "$env:ProgramData\smart-hospital\tls\server.crt" `
  --tls-key  "$env:ProgramData\smart-hospital\tls\server.key"
```

- `new-tls-cert.ps1` 会把证书额外复制成 **纯 ASCII 路径**的运行副本到 `%ProgramData%\smart-hospital\tls`：仓库改名 `smart_hospital` 后仓内路径已全 ASCII、可直接用仓内路径，但生产机仍建议用这份运行副本，把私钥与源码树分开（也是部署到含中文目录时的兜底，`server/README.md:88-108`）。
- `--prod` 要求 `dev_auth=false`，且**必须能找到 `admin-web` 静态目录**（`server/src/main.cj:1034-1038`），否则拒绝启动。

管理员账号（口令随机生成并打印一次，请立刻保存）：

```powershell
.\build\hospital-server.exe create-admin "mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital"
```

**探活**：

```powershell
Invoke-WebRequest -Uri http://127.0.0.1:8091/health -UseBasicParsing | Select-Object -Expand Content
```

- **HTTP 200** = 进程活着**且**库通（`db.ok=true`）；**HTTP 503** = 进程活着但库不通（`db.ok=false`）。
  语义见 `server/src/http_app.cj:1194-1199`（探针据此摘流量），响应体字段见 `server/src/http_app.cj:1163-1192`。
- 别名 `/api/v1/health` 同语义；`db.reconnects` 非 0 说明链路抖过并已自愈。
- 本机实测：`{"ok":true,...,"db":{"ok":true,"reconnects":0}}`。

**优雅关闭**：框架提供 `shutdown()`（停 accept → 排空在途请求 → 跑 `onShutdown` 钩子，`server/third_party/qingzhou/src/app.cj:179-197`）；
但 **Windows 控制台没有 SIGINT→shutdown 的接线**（`server/third_party/qingzhou/src/app.cj:164-166` 明说），所以：

- 正常收尾：等请求跑完再关窗口 / `Ctrl+C`，进程退出后 `db.close()` 由 `serve` 尾部执行（`server/src/main.cj:1159-1163`）。
- 强制：`Get-Process hospital-server | Stop-Process -Force`（会中断在途请求，但不会损坏数据）。

---

## 3. 管理台网页

- 目录 `server/admin-web/`（7 个文件：`index.html` + `css/style.css` + `js/{api,app,pages,ui}.js` + `favicon.svg`），**零构建、无需单独部署**。
- 由服务端以静态资源挂载在 **`/admin`**，与 API 同源同端口（`server/src/main.cj:229-239`；`server/README.md:255-273`）。
- 服务端按**相对进程工作目录**依次找 `admin-web`、`server/admin-web`、`../admin-web`，所以**从 `server/` 或包根目录启动**最稳。
- 静态页本身不鉴权；数据走 `/api/v1/admin/*`，需要管理员 `Authorization: Bearer <token>`。

```powershell
Invoke-WebRequest -Uri http://127.0.0.1:8091/admin/ -UseBasicParsing | Select-Object StatusCode
```

本机实测：`200`（3516 字节）。

---

## 4. 鸿蒙端（ArkTS）

| 项 | 值 | 出处 |
| --- | --- | --- |
| IDE | DevEco Studio（本机装在 `D:\DevEco Studio`） | `docs/HARMONY-INTERFACE-GUIDE.md:242` |
| 兼容/目标 SDK | `5.0.0(12)` | `build-profile.json5`（products[0].compatibleSdkVersion / targetSdkVersion） |
| hvigor | `modelVersion 5.0.0`；**引擎 6.26.4**（随 DevEco 分发，`--version` 可查） | `hvigor/hvigor-config.json5`；`oh-package.json5` |
| Node / JDK | DevEco 自带 `tools\node`（v24.14.1）与 `tools\jbr`（17），**不要用系统 PATH 上的**（见下） | 本机实测 |

**推荐：用仓库根的一行包装（自动探测 DevEco、SDK、JDK 路径，无需配环境变量）**

```powershell
cd E:\harmonyOS\smart_hospital
.\hvigorw.bat --mode module -p product=default -p module=entry@default assembleHap --no-daemon
```

`hvigorw.bat` 只做三件事：按 `%HVIGOR_HOME%` → `D:\DevEco Studio\tools\hvigor\bin` → `C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin` → `%LOCALAPPDATA%\Huawei\DevEcoStudio\...` 的顺序找到 DevEco 自带的 `hvigorw.bat`；据其反推 `DEVECO_SDK_HOME=<DevEco>\sdk`、`JAVA_HOME=<DevEco>\jbr` 并把 `%JAVA_HOME%\bin` 前置到 PATH；最后把参数原样转发。

> **为什么不用官方 `hvigorw`**：仓库里的 `hvigor/hvigor-wrapper.js` 是 **0 字节**（与 DevEco「New Project」模板生成的占位文件一致），官方 wrapper 首次运行要联网 `npm install pnpm` + 把 `@ohos/hvigor` 装到 `%USERPROFILE%\.hvigor`；离线 / 受限网络下会卡在 `EPERM` 或 `ETIMEDOUT`。本仓库选择**复用本机 DevEco 的 hvigor，不下载任何东西**，代价是依赖本机已装 DevEco Studio。

<details>
<summary>等价的显式环境变量写法（CI 或不想用包装脚本时）</summary>

```powershell
$env:DEVECO_SDK_HOME = 'D:\DevEco Studio\sdk'
$env:JAVA_HOME       = 'D:\DevEco Studio\jbr'      # PATH 上的 java 若是 1.7，PackageHap 会 UnsupportedClassVersionError(52.0)
$env:Path = "D:\DevEco Studio\jbr\bin;D:\DevEco Studio\tools\node;D:\DevEco Studio\tools\ohpm\bin;D:\DevEco Studio\tools\hvigor\bin;$env:Path"
& 'D:\DevEco Studio\tools\hvigor\bin\hvigorw.bat' --mode module -p product=default -p module=entry@default assembleHap --no-daemon
```

</details>

- **成功标志** `BUILD SUCCESSFUL`（本机实测 65 tasks / 约 23 s 首编、4 s 增量），产物 `entry/build/default/outputs/default/entry-default-unsigned.hap`（约 1.7 MB）+ `pack.info`。
- **已入库的构建与运行证据**：[release/harmony/](../release/harmony/README.md) —— `entry-default-unsigned.hap`（1748913 B，SHA256 `745D07E08A236EC4205AB9A103899064F6B4D07FA369230F1C40CE7EC664C6A3`）、`pack.info`、`build-log-2026-10-17.txt`（剥掉 ANSI 的完整日志）+ `screenshots/` **10 张模拟器实跑截图**（每张都有对应 `uitest dumpLayout` 文本实测）。这是「客户端可构建、可运行」的现场证据，不是二次生成的转述。
- **装进模拟器（未签名也能装）**：在华为模拟器（Pura 90 / HarmonyOS 6.1.1 / API 24）实测 `hdc install -r …hap` 直接成功，**不需要先签名**；启动前若屏幕锁定，`aa start` 会报 `10106102 The device screen is locked…`，先 `hdc shell power-shell wakeup`（注意 `Emulator.exe -instance … -power` 是关屏，别用）：
  ```powershell
  & "D:\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" install -r .\entry\build\default\outputs\default\entry-default-unsigned.hap
  & "…\hdc.exe" shell power-shell wakeup
  & "…\hdc.exe" rport tcp:8091 tcp:8091        # 让模拟器里的 App 能连本机服务端
  & "…\hdc.exe" shell aa start -a EntryAbility -b com.smart.hospital.patient
  ```
- ⚠ **仓库目录改名后必做一次软链重连**：`oh_modules/` 下指向本仓模块的 junction 里存的是**绝对路径**，仓库从 `智能医院客户端` 改名成 `smart_hospital` 后它们悬空，hvigor 会打 `WARN: Please confirm the symbolic link is valid` 并抛 12 个 `10505001 ArkTS Compiler Error: Cannot find module 'common-core'`。修法是重新链接（任选其一）：
  ```powershell
  cd E:\harmonyOS\smart_hospital
  ohpm install                        # 首选：按 oh-package.json5 重建
  # 或手工重连（示例：entry 指向 common-core 的那一个）
  cmd /c rmdir entry\oh_modules\common-core
  cmd /c mklink /J entry\oh_modules\common-core E:\harmonyOS\smart_hospital\common-core
  ```
  共 7 个：`entry\oh_modules\{common-core,feature-patient,feature-doctor,feature-admin}` + `feature-{admin,doctor,patient}\oh_modules\common-core`。
- **工程路径必须纯 ASCII**：hvigor 在 `ProjectInspection` 阶段用 `00306003 Specification Limit Violation / Invalid project path` 直接拒绝含中文的工程路径，`subst` 也绕不过（会 realpath 回真实路径）。本仓库已改名为 `E:\harmonyOS\smart_hospital`，**该问题已消除**；若你把仓库克隆到含中文的目录仍会复现，此时用 robocopy 一份 ASCII 副本再构建（`docs/HARMONY-INTERFACE-GUIDE.md:259-262`）。
- **签名**：`build-profile.json5` 的 `signingConfigs` 为空时，把 `products[0].signingConfig` 去掉 → 只报 `WARN: No signingConfig found for product default`，产出**未签名 HAP**；模拟器可直接安装（见上一条），分发给真机/上架才需要 DevEco「自动签名」或本机调试证书（`docs/HARMONY-INTERFACE-GUIDE.md:282-284`）。仓库里已按此去掉悬空引用（2026-10-17）。
- **接口地址**：`common-core/src/main/ets/config/ApiConfig.ets:8` 的 `baseUrlValue = 'http://127.0.0.1:8091'`（默认值同时出现在 `ApiConfig.ets:42`）；改这一处即可，`ApiConfig.restore()`/`url()` 会统一拼接。

---

## 5. 安卓端

| 项 | 值 | 出处 |
| --- | --- | --- |
| JDK | 17（build 脚本接受 17~21） | `android-patient/README.md:11`；`android-patient/app/build.gradle.kts:60-63` |
| Gradle | 8.7（自带完整 Wrapper） | `android-patient/gradle/wrapper/gradle-wrapper.properties` |
| AGP / Kotlin | 8.5.2 / 2.0.21 | `android-patient/build.gradle.kts:2-3` |
| SDK | compileSdk 35、minSdk 26、targetSdk 35；versionCode 1000000 / versionName 1.0.0 | `android-patient/app/build.gradle.kts:16,20-23` |

```powershell
cd E:\harmonyOS\smart_hospital\android-patient
.\build.ps1 -Variant debug -Offline                                # 封装脚本（推荐）
.\gradlew.bat clean :app:assembleDebug --offline --no-daemon       # 直接跑 Wrapper
adb install -r .\app\build\outputs\apk\debug\app-debug.apk
```

- 接口地址：`app/build.gradle.kts` 用 `-PapiBaseUrl` / 环境变量 `API_BASE_URL` 注入 `BuildConfig.DEFAULT_BASE_URL`
  （`android-patient/app/build.gradle.kts:6-7,40,47`）。debug 缺省 `http://127.0.0.1:8091`，release 缺省 `https://example.invalid`。
  例：`.\build.ps1 -Variant debug -Offline -ApiBaseUrl http://10.0.2.2:8091`（模拟器回环宿主机，`android-patient/README.md:44`）。
- release 额外强制：`-PapiBaseUrl=https://…` + `ANDROID_KEYSTORE_PATH/PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`（`app/build.gradle.kts:66-78`；`android-patient/README.md:67`）。
- 产物：`app/build/outputs/apk/release/app-release.apk`（+ `.aab`，AAB 不能直接 `adb install`）。

**2026-10-18 实测（debug）**：`.\build.ps1 -Variant debug` → `BUILD SUCCESSFUL`，APK 956,718 B；装进 AVD `Medium_Phone_API_37.0` 后 `adb reverse tcp:8091 tcp:8091` + 真实账号登录成功。四个**环境**坑（都与本仓代码无关）：① 本机只有 JDK 25，Gradle 8.7 / AGP 8.5.2 需要 **17–21**；② 写 `%USERPROFILE%\.gradle` 被安全软件拦 ⇒ `$env:GRADLE_USER_HOME` 指到工作区；③ `google()/mavenCentral()` 在本网络无进展 ⇒ 本机 init 脚本加镜像；④ `C:\Users\<用户>\.android\debug.keystore` 与 Kotlin 临时目录同样被拦 ⇒ `$env:ANDROID_SDK_HOME` / `$env:TEMP` 指到工作区。逐步命令与截图见 [release/android/README.md](../release/android/README.md)。

---

## 6. 可运行程序包（`tools/package-release.ps1`）

```powershell
cd E:\harmonyOS\smart_hospital
powershell -ExecutionPolicy Bypass -File .\tools\package-release.ps1
# 可选：-OutDir D:\dist  -Version 0.2.0-p1  -SkipBuild
```

做的事：停 `hospital-server` → `server\build.ps1` 编译 → 缺 DLL 时自动 `setup-runtime.ps1` →
收 `server\build\` 顶层可运行文件（跳过 `*.cjo`、`mysql-driver\` 等中间产物）+ `server\admin-web\` →
生成 `README-运行说明.txt`（UTF-8 with BOM）与 `start-dev.cmd`（双击启动）→ 打 zip → 打印清单与体积。

- 产物：`release\hospital-server-<Version>-win-x64.zip`（`-Version` 默认读 `server/src/main.cj:34` 的 `SERVER_VERSION`，读不到退 git 短 SHA，再退 `dev`）。
- `release\` 是**生成物，不入库**（已收录于 `.gitignore`；需要交付时用脚本重新生成，或直接把 zip 作为附件提交）。
- 本机实测：编译 21.1 s，整包 23.6 s，**15 个文件**，zip **7.81 MB**，解压后 **22.18 MB**。
- 包内清单：`hospital-server.exe`、`libcangjie-runtime.dll`、`libboundscheck.dll`、`libcrypto-3-x64.dll`、`libssl-3-x64.dll`、`SOURCE-MANIFEST.sha256`、`admin-web/`（7 个文件）、`README-运行说明.txt`、`start-dev.cmd`。
- 用法：解压到 **ASCII 路径** → 改 `start-dev.cmd` 里的 `DSN`/`PORT` → 起库（§2①）→ 双击 `start-dev.cmd`（或命令行 `.\hospital-server.exe serve <dsn> --dev-auth`，默认端口 8091）→ `http://127.0.0.1:8091/health`。
- 实测验证：解压到 `%TEMP%` 后 `hospital-server.exe version` → `0.2.0-p1`；`selftest` → 51 项通过；`serve` 起来后 `/health` 200 且 `db.ok=true`、`/admin/` 200。

---

## 7. 验收清单

| 命令 | 查什么 | 预期输出 | 耗时量级（本机实测） |
| --- | --- | --- | --- |
| `hospital-server.exe version` | 版本串 | `0.2.0-p1`（⚠ `--version` **不是**合法参数，会退 2 并打印用法） | < 0.1 s |
| `… selftest` | 纯本地 schema/口径不变量，**不连库** | `✅ 自检全部通过`，51 项 0 失败 | **0.14 s** |
| `… authtest` | 口令/令牌原语 + 公开测试向量，**不连库** | `✅ 口令/令牌原语自检全部通过`，17 项 0 失败 | **4.39 s**（PBKDF2 100k 迭代，慢是正常的） |
| `… triagetest` | 分诊纯逻辑（危急征象/问询流/三态结论），不碰库不调模型 | `通过 150 项，失败 0 项` | **0.08 s** |
| `… check-db <dsn>` | 连库 + 幂等建表 + 打印表清单 | `建表：执行 17 条 DDL（IF NOT EXISTS，幂等）` + 表清单 | **1.7 s** |
| `tests\contract-check.ps1 -Base … -AdminPw …` | ①重新导出契约与 `contract/examples/**` **逐字节**比对 ②用 `contract/schema/*.json` 校验形状与分类 | 全部一致 / 校验通过；`-SkipExport` 只跑校验（`server/tests/contract-check.ps1:3-27`） | 需实例 + 管理员口令；**本机实测全绿**：载入 Schema 24 个、样例 67 条、`PASS 69 / FAIL 0` |
| `tests\final-verify.ps1` | 一次跑完 **18 项** HTTP 门禁（三种实例：18092 `--dev-auth`、18095 裸、18096 `--prod`；末项 `doc-counts` 对账文档数字）+ 汇总 `EXIT` 表 | 全 `EXIT=0`；脚本自己起停三个实例并生成管理员口令（`server/tests/final-verify.ps1:1-13,63-93`） | 分钟级；**本机实测 18/18 `EXIT=0`**（端口须 ≥15001；`contract-check` 必须排在 `p1-extra-check` 之前，后者会重设管理员口令） |
| `… accept <dsn>` | AC-1…AC-17 全量验收（782 项），**会清空业务表** | 只允许库名含 `test`；非测试库直接退 2（`server/src/main.cj:274-301`） | 长；**禁止在业务库跑** |

> 测试项数以 `server/tests/doc-counts.ps1` 的实测输出为准；上表的 `0.14 s / 4.39 s / 0.08 s / 1.7 s` 是本机 `0.2.0-p1` 包的实测值。

---

## 8. 常见故障排查

| 症状 | 原因 | 处置 |
| --- | --- | --- |
| `编译输出被占用：…\hospital-server.exe`，或链接报占用 | 还有 `hospital-server.exe` 在跑 | `Get-Process hospital-server -ErrorAction SilentlyContinue \| Stop-Process -Force` 后重编 |
| `[devdb] 启动失败` / 建库超时；端口 3317 不监听 | 3317 已被占用（本机其它实例）或 mysqld 起不来 | `Get-NetTCPConnection -State Listen \| Where-Object LocalPort -eq 3317`；看 `server\devdb\mysqld.err.log`；或 `devdb.ps1 stop` 后重启 |
| `CryptoException: Can not load openssl library or function SHA256_Init`（运行期，编译期无提示） | 4 个运行时 DLL 没跟 exe 放一起 | `.\setup-runtime.ps1 -OutDir .\build`（或其 `-OpenSslDir` 指到含 `libcrypto-3-x64.dll` 的目录）；包用户确认解压目录里有那两个 `libcrypto/libssl` DLL |
| `Unexpected token` / 语法错乱，指向一个明明正确的 `.ps1` | 文件不是 **UTF-8 with BOM**，PS 5.1 按 ANSI 解析 | `[System.IO.File]::WriteAllText($p,$text,(New-Object System.Text.UTF8Encoding($true)))` 重存 |
| `无法加载文件 …未对文件 …进行数字签名`（`UnauthorizedAccess`/`PSSecurityException`） | 执行策略为 `RemoteSigned`，而仓库在 `E:` 上被当作远程脚本 | `powershell -NoProfile -ExecutionPolicy Bypass -File .\xxx.ps1`，或 `Set-ExecutionPolicy -Scope Process Bypass` |
| 客户端 401 | 未开 `--dev-auth` 却发 `X-Role`/`X-Patient-Id`；或 `--dev-auth` 下**远程来源**发这些头（只认 `127.0.0.1`/`::1`）；或令牌缺失/过期 | 正式路径用 `Authorization: Bearer <token>`；本地联调确认 `--bind 127.0.0.1` 且请求确从回环发出 |
| 客户端 403 | 令牌有效但角色不足（权限矩阵按路由） | 用对应角色令牌；`/api/v1/admin/*` 需管理员 |
| `/health` 200 但业务接口 500 | 旧版 `/health` 只回静态字段；当前版本已改为**当场探库**，库不通即 503 | 确认 exe 是当前版本；503 时查 DSN/口令/库是否在跑 |
| `/admin/` 404 或启动日志「未找到管理台静态目录」 | 启动目录里没有 `admin-web`（候选只有 `admin-web`、`server/admin-web`、`../admin-web`） | 从 `server\`（或包根）启动；`--prod` 缺 admin-web 会**直接拒绝启动** |
| `LLVM ERROR: Broken module found` | cjc 版本串台（用了 PATH 上的 1.1.3） | 让 `build.ps1` 自己挑 1.2.0；不要手工指定错误的 `-CangjieHome` |
| `can not find package 'mariadb.cdbc'` | 没编驱动（全新克隆） | 先跑 `build-mysql-driver.ps1`（见 §2③），产物在 `server\build\mysql-driver` |
| `10505001 ArkTS Compiler Error: Cannot find module 'common-core'`（12 个）+ `WARN: Please confirm the symbolic link is valid` | 仓库目录改名后，`oh_modules/` 里的 junction 还指向旧绝对路径 | 按 §4「改名后必做一次软链重连」（`ohpm install` 或 `mklink /J` 重连 7 个链接） |
| `00306003 Specification Limit Violation / Invalid project path` | 工程路径含中文/非 ASCII | 仓库已在 `E:\harmonyOS\smart_hospital`；克隆到中文目录时 robocopy 一份 ASCII 副本再构建 |
| `00308003 … ENOENT … node_modules\@ohos\hvigor\bin\hvigor.js` / 首次运行卡在 `npm install pnpm` | 官方 `hvigorw` 的 `hvigor-wrapper.js` 是 0 字节占位，需联网自举工具链；受限网络下失败 | 用仓库根 `.\hvigorw.bat`（复用本机 DevEco 的 hvigor，不下载），见 §4 |
| `PackageHap` 报 `UnsupportedClassVersionError: … 52.0` | PATH 上的 `java` 是 1.7，不是 DevEco 自带的 17 | 设 `JAVA_HOME=<DevEco>\jbr` 并把 `%JAVA_HOME%\bin` 前置到 PATH（`hvigorw.bat` 已自动处理） |
