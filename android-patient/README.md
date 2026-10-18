# 智慧医院 · Android 患者端

Kotlin 原生 Views 实现的患者端（包名 `com.smart.hospital.patient`），覆盖与鸿蒙患者端相同的主闭环：登录 / 首页 / AI 分诊 / 预问诊（SSE）/ 约号 / 我的就诊 / 医疗档案 / 公告 / 我的。

接口口径**只以** [docs/FRONTEND-INTEGRATION.md](../docs/FRONTEND-INTEGRATION.md) 为准；两端差异只体现在 UI 框架与平台能力上（鸿蒙为 ArkTS + ArkUI V2，安卓为 Kotlin Views）。

## 首页预约适配

“下一次就诊”按鸿蒙 `c75b15e` 的规则选择活动预约：优先接诊中、候诊中、已到院、已挂号，再按日期、时段和序号比较；刷新先清掉旧卡，终态不参与。详见 [首页适配交接](HOME-APPOINTMENT-ALIGNMENT-2026-10-18.md)。本轮只做源码复核，运行结果待用户验证。

本轮继续补齐科室/医生编号与时段筛选、在线公告、当前/历史预约分组、服务端状态文案、手动主题及页面内服务地址设置。演示数据现含七态预约，另有空闲排班可演示新挂号。完整实现范围与用户复测项见 [跨端功能适配交接](CROSS-PLATFORM-PARITY-2026-10-18.md)。

## 工具链

| 工具 | 要求 |
| --- | --- |
| JDK | 完整 JDK 17–21（需 `java` / `javac` / `jlink`；**2026-10-18 实测 Temurin 21 编译通过**，JDK 25 会因 Gradle 8.7 / AGP 8.5.2 不支持而失败） |
| Gradle | 自带 Wrapper 8.7，不依赖全局 Gradle |
| AGP / Kotlin | 8.5.2 / 2.0.21 |
| Android Platform | compileSdk / targetSdk **35**，minSdk **26** |
| Build-Tools | 34.0.0（AGP 默认）或 35.0.0 |
| 设备工具 | Platform-Tools（`adb`）、Android Emulator（AVD） |

`build.ps1` 按 `JAVA_HOME` → 仓库 `.build-tools/jdk17/` → `PATH` 定位 JDK；SDK 按 `ANDROID_SDK_ROOT` → `ANDROID_HOME` → `local.properties` → `%LOCALAPPDATA%/Android/Sdk` → `C:/Android/Sdk` 查找。`.build-tools/` 与 `local.properties` 都不入库。

## 构建与安装

```powershell
Set-Location ./android-patient
./build.ps1 -Variant debug -Offline            # 首次准备依赖缓存时去掉 -Offline
./verify-artifacts.ps1 -ApkPath ./app/build/outputs/apk/debug/app-debug.apk

adb devices -l
adb reverse tcp:8091 tcp:8091                  # 模拟器里 127.0.0.1 指向设备自身
adb install -r ./app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n com.smart.hospital.patient/.MainActivity
```

也可以直接用 Wrapper（自行配置 JDK 与 SDK）：

```powershell
./gradlew.bat clean :app:assembleDebug --offline --no-daemon
```

## 服务端地址

Debug 默认 `http://127.0.0.1:8091`。联调三选一：

1. `adb reverse tcp:8091 tcp:8091`（保留默认地址）；
2. 模拟器里把地址设为 `http://10.0.2.2:8091`；
3. 构建时传 `-ApiBaseUrl http://10.0.2.2:8091`。

**Debug 允许 HTTP 联调，Release 强制 HTTPS**（与鸿蒙端一致）。

## Release 构建

签名 keystore 放在仓库外，口令只走环境变量（`ANDROID_KEYSTORE_PATH` / `ANDROID_KEYSTORE_PASSWORD` / `ANDROID_KEY_ALIAS` / `ANDROID_KEY_PASSWORD` / `API_BASE_URL`），**不要**写进代码或命令历史：

```powershell
./build.ps1 -Variant release -Offline -Bundle -ApiBaseUrl $env:API_BASE_URL
./verify-artifacts.ps1 -ApkPath ./app/build/outputs/apk/release/app-release.apk `
                      -AabPath ./app/build/outputs/bundle/release/app-release.aab
```

`verify-artifacts.ps1` 校验 APK 签名并输出 APK/AAB 的 SHA-256；注意 **AAB 哈希不等于签名或安装验证**，AAB 需 bundletool 或测试平台安装。

## 已知边界

- **2026-10-18 已实测**：`.\build.ps1 -Variant debug` → `BUILD SUCCESSFUL`（APK 956,718 B），装进 Android 模拟器（`Medium_Phone_API_37.0`）后用真实账号登录成功（`您好，演示患者`），服务端地址靠 `adb reverse tcp:8091 tcp:8091` 保留默认值。证据与**本机环境坑**（JDK 25 不可用、`GRADLE_USER_HOME` / `ANDROID_SDK_HOME` / `TEMP` 需重定向、依赖镜像）见 [release/android/README.md](../release/android/README.md)。
- 演示模式（mock 数据）**仅在 Debug** 可用，Release 中 `BuildConfig.DEBUG=false` 会关闭演示入口与 mock 分支；演示走通不等于真实 API/SSE/鉴权/余量守恒通过。
- 挂号与退号**必须在线直连**，不进离线队列（排队等于超卖）。
- 分诊/问诊草稿只保留在当前 Activity 内存，进程被杀后不恢复；幂等 `client_token` 的持久恢复需由测试确认。
- 本目录不包含服务端；起服务见 [docs/DEPLOYMENT.md](../docs/DEPLOYMENT.md)。
