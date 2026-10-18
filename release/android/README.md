# 安卓患者端 · 构建与实跑证据（2026-10-18）

本目录证明：**安卓患者端在真实工具链下能编译、能安装、能连真实服务端登录**。
与 [release/harmony/](../harmony/README.md) 的鸿蒙证据互补 —— 两端跑的是同一套服务端接口。

## 1. 文件清单

| 文件 | 大小 | 说明 |
| --- | --- | --- |
| `app-debug.apk` | 1,186,278 B | `.\build.ps1 -Variant debug` 产物（debug 签名，仅用于模拟器/自测） |
| `01-android-login.png` | 104,364 B | 登录页：`智慧医院 / 智能导诊·预约挂号·医疗档案`，含登录名与密码输入、登录、进入演示、设置服务地址 |
| `02-android-home.png` | 123,400 B | 用真实账号 `13800000000` 登录后的首页：`您好，演示患者`（姓名来自服务端 `display_name`）+ 快捷服务四入口 + 底部五个 Tab |
| `03-android-triage.png` | 108,619 B | 智能分诊页：症状输入框、字数计数、`开始分诊` |
| `04-android-visits.png` | 75,169 B | 我的就诊页空态：`还没有挂号记录` + `刷新预约`（此刻库里确实没有该患者的挂号，见下） |
| `05-android-doctor-queue.png` | 104,164 B | 医生工作台 · `接诊队列`（同事 `de47f6f` 新增）：`1 号 · 患者 #1 / 2026-12-24 上午 / 已挂号 / 病历：已定稿 / 打开病历`，`刷新队列`、`退出医生账号` |
| `07-android-doctor-queue-dark.png` | 79,100 B | `接诊队列`在**暗色**下的样子（2026-10-18 夜：`ThemeController.isNight()` 收敛为唯一判定入口后重截）：`1 号 · 患者 #1 / 2026-12-24 上午 / 已挂号 / 病历：草稿` |
| `06-android-doctor-record.png` | 206,816 B | 医生工作台 · 病历编辑页（暗色主题）：`门诊病历 · 2 号`、`版本 0`、`确认到院 / 标记爽约`、预问诊与既往病历折叠区；顶部红条是**服务端停掉时**的 `网络连接失败，请检查服务地址或网络`（同事 `2cbf080` 的本地化文案，实测生效） |

APK SHA-256：`0F2AEFAF8096C8770C55F5DBDC1F60BC332CBB83B737C9EFFBEF8160EBDCA9FE`（2026-10-18 23:5x，在 A1/A2/A3 修复之上又合入：`SessionStore` 存储失败不再抛异常、`ThemeController.isNight()` 单一判定、`themes.xml` 窗口属性对齐；**契约层单测 10/10 通过**）

## 2. 怎么复现（本机实测命令）

```powershell
# ① 编译（JDK 必须是 17–21；本机用 Temurin 21，见 §3）
cd E:\harmonyOS\smart_hospital\android-patient
.\build.ps1 -Variant debug
# 成功标志：BUILD SUCCESSFUL + [build] 完成：debug

# ② 起服务端（另开一个窗口）
cd E:\harmonyOS\smart_hospital\server
.\build\hospital-server.exe serve "mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital_test" --port 8091

# ③ 起模拟器（AVD 已在列表里；无窗口模式足够截图）
& "$env:LOCALAPPDATA\Android\Sdk\emulator\emulator.exe" -avd Medium_Phone_API_37.0 -no-window -no-audio -no-boot-anim -gpu swiftshader_indirect

# ④ 装包 + 端口反代 + 启动
$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
& $adb devices                      # 期望一行 emulator-5556  device
& $adb -s emulator-5556 reverse tcp:8091 tcp:8091
& $adb -s emulator-5556 install -r .\app\build\outputs\apk\debug\app-debug.apk
& $adb -s emulator-5556 shell am start -n com.smart.hospital.patient/.MainActivity

# ⑤ 截图
& $adb -s emulator-5556 shell screencap -p /sdcard/s.png
& $adb -s emulator-5556 pull /sdcard/s.png .\s.png
```

## 3. 本机踩到的四个环境坑（与代码无关，记录以便复现）

1. **JDK 版本**：DevEco Studio 自带 `jbr` 是 25、Android Studio 自带 `jbr` 也是 25，而 Gradle 8.7 + AGP 8.5.2 只支持 **17–21**（`UnsupportedClassVersionError`）。解：下 Temurin 21 放到 `android-patient\.build-tools\jdk17\jdk-21.x`（`build.ps1` 的 `Resolve-Jdk` 会扫这个目录），`.build-tools/` 不入库。
2. **`gradle-wrapper` 下载被拦**：写 `%USERPROFILE%\.gradle` 被安全软件拒绝（`gradle-8.7-bin.zip.lck` 反复"拒绝访问"）。解：`$env:GRADLE_USER_HOME='<仓库>\.build-tools\gradle-home'`，并把 `gradle-8.7-bin.zip` 手动放进 `...\wrapper\dists\gradle-8.7-bin\<hash>\`。
3. **依赖解析慢**：`google()/mavenCentral()` 在本网络长期无进展。解：在本机 `GRADLE_USER_HOME/init.d/` 放一个只加镜像的 init 脚本（阿里云 4 个仓库前置，原仓库保留兜底）。该脚本属于本机环境，**不在仓库里**。
4. **`debug.keystore` 位置**：默认 `C:\Users\<用户>\.android\debug.keystore`，写它同样可能被拦。解：`$env:ANDROID_SDK_HOME` 指到工作区内目录，`ANDROID_USER_HOME` 同步指过去；Kotlin 编译器的临时文件同理，`$env:TEMP`/`$env:TMP` 指到工作区内的 `tmp`。

## 4. 与代码有关的真实修复（都已入库）

- `app/src/main/java/com/smart/hospital/patient/data/SecretStore.kt` 头部文档里写了 `shared_prefs/*.xml`，Kotlin 的块注释**可嵌套**，注释里的 `/*` 会再开一层注释且永不闭合 ⇒ 整文件 `Syntax error: Unclosed comment`，连带 `SessionStore.kt` 报 4 处 `Unresolved reference 'SecretStore'`。已改写成不含 `/*` 的表述。
- `SessionStore.kt` 的令牌路径（P2-14）：迁移失败不再删明文、写失败不再假装成功、解密失败不再静默返回空串（详见 `docs/整改方案-2026-10-17.md` §8 第 7/8 条）。
- `SessionStore` 的 7 处 `check(commit())` 改为 `persist()`：本地存储写失败不再抛 `IllegalStateException`（`commit()` 失败时内存值其实已生效，抛异常等于把"下次可能要重试"升级成闪退）。
- `ThemeController.isNight()` 成为唯一明暗判定入口，`attachContext()`/`refresh()` 共用；两份 `themes.xml` 窗口属性对齐（浅色补 `windowBackground`，消除启动首帧纯白）。
- 新增契约层单测 `app/src/test/java/.../ContractParserTest.kt`（10 个用例，金样本在 `app/src/test/resources/contracts/`，从本机服务端真实抓取）：`.\gradlew.bat testDebugUnitTest` → 10/10 PASS。
- 同事 `de47f6f` 带入的 3 个契约缺陷（队列缺 `schedule_id`、病历缺 `version`、乐观锁字段名 `expected_version` vs `expected_updated_at`）已修，并顺手对齐鸿蒙侧的队列标题与日期守卫（详见 `docs/审查-同事提交-2026-10-18.md`）。

## 5. 已知边界

- 本 APK 是 **debug 签名**，只能装模拟器/自测设备；对外分发要走 `-Variant release` + 仓库外 keystore（`android-patient/README.md` §Release 构建）。
- 安卓侧现有**契约层 JVM 单测** 10 个（不需要模拟器），但 UI 层仍是"人工驱动 + 截图"：登录、首页、分诊页、就诊页、医生队列、病历编辑页。分诊的**模型输出**证据在鸿蒙侧（`release/harmony/screenshots/06-patient-triage.jpeg`），两端打的是同一个 `POST /api/v1/triage`。
- `04-android-visits.png` 显示空态是**当时的真实数据**（库里该账号没有挂号单），不是接口故障。
