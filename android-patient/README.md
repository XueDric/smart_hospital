# 智慧医院 Android 患者端

Kotlin 原生 Views 患者端，包名 `com.smart.hospital.patient`。当前 main 基线为 `b5f5f7d6b95cd83087bc4c36bfba0b00a1f61e10`。鸿蒙内容同步该提交；平台差异由 Android 适配，后端只修复报告确认的跨平台真实缺陷。最新交接见 [FIX-FOLLOWUP-2026-10-13.md](FIX-FOLLOWUP-2026-10-13.md)，上一轮交接保留在 [FIX-HANDOFF-2026-10-13.md](FIX-HANDOFF-2026-10-13.md)。

## 工具链与证据

外部新报告 `F:/cj_cup/test-runs/fix/REPORT-FIX.md`（run_id `RUN-20261013-FIX`）记录上一轮主流程已通、BL-1 消除，以及后端排班/鉴权的真实缺陷。本工作流未运行测试、编译、脚本门禁、签名校验、设备或 API 操作。**本轮须由用户重新构建并复测，上一轮 APK 通过不能作新改动证据。** BL-2 测试设施缺陷未由本轮修改。

| 工具 | 要求 |
|---|---|
| JDK | 推荐完整 JDK 17，build 脚本接受 17～21，需 java / javac / jlink |
| Gradle | 已有完整 Wrapper 8.7，不依赖全局 Gradle |
| AGP / Kotlin | 8.5.2 / 2.0.21 |
| Android Platform | compileSdk / targetSdk 35，minSdk 26 |
| Build-Tools | AGP 默认 34.0.0，外部报告另记录已安装 35.0.0 |
| 设备工具 | Platform-Tools / Android Emulator，由用户或测试 agent 使用 |

build 脚本按 `JAVA_HOME`、仓库 `.build-tools/jdk17/`、PATH 定位 JDK。显式 JAVA_HOME 无效时明确报错，不自动换另一套 JDK。工作区 JDK 不入库。

SDK 按 `ANDROID_SDK_ROOT`、`ANDROID_HOME`、`local.properties`、`%LOCALAPPDATA%/Android/Sdk`、`C:/Android/Sdk` 查找，检查 Platform 35 和 Build-Tools 34.0.0。脚本仅在配置内容变化时维护未入库的 local.properties，保留其他键。

独立运行 verify 脚本不依赖之前 build 的进程环境：按同样顺序定位 Java，检查 java.exe、jvm.dll、lib/modules，仅查文件而不执行 java 来探测。然后设置 JAVA_HOME/PATH，让 apksigner 可启动。

## 用户执行 Debug 构建与设备验收

从仓库根目录进入工程：

```powershell
Set-Location ./android-patient
./build.ps1 -Variant debug -Offline
./verify-artifacts.ps1 -ApkPath ./app/build/outputs/apk/debug/app-debug.apk
```

离线模式需要依赖缓存齐备；首次准备缓存时去掉 `-Offline`。

下载默认优先国内源：插件和依赖使用阿里云 Google、Gradle Plugin、Public 镜像，官方仓库保留为后备。Gradle 8.7 分发包使用腾讯镜像，Wrapper 配置固定官方 SHA-256，下载超时为60秒。首次切换镜像后，同步或构建应关闭离线模式，以下载该仓库来源下尚未缓存的依赖。仅调整下载来源，不升级 AGP/Kotlin/Gradle，也不增加本项目未使用的工具链插件。

直接运行 Wrapper 时自行配置 JDK 与 SDK；以下离线命令仅在缓存已齐备时使用：

```powershell
./gradlew.bat clean :app:assembleDebug --offline --no-daemon
```

Debug 默认地址 `http://127.0.0.1:8091` 在模拟器上指向设备自身。联调任选一种：

- 测试人员执行 `adb reverse tcp:8091 tcp:8091`，保留默认地址。
- 登录前设置服务地址 `http://10.0.2.2:8091`。
- 构建传 `-ApiBaseUrl http://10.0.2.2:8091`。

```powershell
adb devices -l
adb reverse tcp:8091 tcp:8091
adb install -r ./app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n com.smart.hospital.patient/.MainActivity
```

真机需设备可达的后端地址。Debug 支持 HTTP 联调，Release 要求 HTTPS。DevEco 鸿蒙模拟器不能代替 Android AVD 验收 APK。

演示仅 Debug 可用，必须标明非真实预约；Release 的 BuildConfig.DEBUG=false 禁止演示入口和 mock 分支。演示走通不能证明真实 API、SSE、鉴权或余量守恒通过。

原 `../tools/validate-android-client.ps1` 已随非 Android 本地内容归档，不是当前可调用门禁；字符串存在性也不是行为验证。

## 用户执行 Release APK / AAB 构建

发布 keystore 放仓库外，使用 keytool 交互输入密码：

```powershell
keytool -genkeypair -v -keystore C:/secure/smart-hospital-release.jks -alias smart-hospital -keyalg RSA -keysize 4096 -validity 10000
```

通过安全渠道设置当前会话/CI Secret：`ANDROID_KEYSTORE_PATH`、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`、`API_BASE_URL`。不把密码、令牌或私钥写进代码、命令历史和日志。

```powershell
./build.ps1 -Variant release -Offline -Bundle -ApiBaseUrl $env:API_BASE_URL
./verify-artifacts.ps1 -ApkPath ./app/build/outputs/apk/release/app-release.apk -AabPath ./app/build/outputs/bundle/release/app-release.aab
```

产物为 `app/build/outputs/apk/release/app-release.apk` 和 `app/build/outputs/bundle/release/app-release.aab`。`-Bundle` 仅 release 使用。

verify 优先 PATH 的 apksigner，否则按 SDK Build-Tools 版本降序查找；缺 Java/apksigner 或签名失败会明确失败。脚本校验 APK 签名并输出 APK/AAB 哈希，**AAB 哈希不是 AAB 签名或安装验证**。AAB 不能直接 adb install，需测试平台或 bundletool。

记录 commit、versionName/versionCode、构建时间、证书、产物 SHA-256 和在线回归证据。相同源码重建 APK 不保证逐字节相同，哈希仅标识一次产物。升级须保持签名并递增 versionCode。

## 当前行为与待复测范围

预问诊由 SSE done 确认开流完成，再以 GET 结构化状态驱动进度和下一问。delta 仅展示“启动时系统说明”；用户真实主诉通过 JSON answer 补交，不放 stream URL query 或 header，后端保持既有 query 语义。

公共 banner 展示在线请求的剩余冷却秒数，API 层阻止冷却期发请求；页面网络动作灰禁，并独立保留请求进行中、已完成、无余号等业务状态。已打开的系统确认弹窗按钮不在灰禁注册表内，仍由 API 层拦截。旧页面返回429也会立即刷新当前页冷却状态。

分诊/日期/问诊草稿只在当前 Activity 内存保留，用于切页和返回；不承诺进程终止或 Activity 重建恢复草稿。幂等 token 和问诊 session 的持久恢复另需复测。应用自有中文文案、日期提示及显示格式已迁入字符串资源；服务端返回的问诊、病历和名称继续使用原数据。

挂号及退号结果在「我的就诊」保留提示，便于截图取证；账号、模式或服务地址切换会清除。测试方可按 `com.smart.hospital.patient:id/` 下的 `login_name`、`login_password`、`login_submit`、`login_message`、`cooldown_banner`、`appointment_outcome` 定位，避免依赖点击坐标。

本对话每30分钟监控 main 新提交，有变化时通知影响范围，不自动合并或覆盖工作区。当前基线记录在本机 `MAIN-WATCH.json`，该运行状态不入库。

用户复测时声明在线/演示模式、实例和数据库，使用稳定独立夹具，并按交接文件检查 REPORT H-1～H-6、M-2/M-11、L-1～L-4及附加 UX 项。Release、慢网/SSE、进程重启和业务全流程由用户或独立测试 agent 负责；本对话收到结果后继续修复。
