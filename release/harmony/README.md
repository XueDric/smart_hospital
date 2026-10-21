# 鸿蒙客户端构建与运行证据（2026-10-17 建档，2026-10-18 联调后刷新）

> 本目录是为回应评审"鸿蒙三端零构建产物、零可运行证据"而保留的**原始证据**，不是演示素材的拼贴：
> 每一张截图都对应一次 `hdc install` + `aa start` 真实运行，且关键文本另有 `uitest dumpLayout` 文本实测（登录态、聚合数字、真实模型来源）。
> 数字口径见 [docs/交付快照.md](../../docs/交付快照.md)；构建/运行故障见 [docs/DEPLOYMENT.md](../../docs/DEPLOYMENT.md)。

## 一、文件清单
| 文件 | 大小 | 说明 |
|---|---|---|
| `entry-default-unsigned.hap` | 1,758,110 B | 未签名 HAP（SHA256 `5DA919EBAC234CA80E2E3D7053455574AC15F2E928A3E728DD391CC0C3366AD0`，2026-10-20 19:34 构建，含分诊页 Mock 文案修复）|
| `pack.info` | 565 B | 打包信息（bundle `com.smart.hospital.patient`、versionCode/versionName、模块列表）|
| `build-log-2026-10-21.txt` | 8,435 B | 2026-10-19 合并队友提交（含医生端排序修复）后重建的日志（ANSI 已剥离，末行 `BUILD SUCCESSFUL in 20 s 735 ms`；65 tasks / 44 executed / 21 up-to-date）|
| `screenshots/*.jpeg` | 16 张 | 见下表 |

## 二、截图索引
| # | 文件 | 端 | 画面内容（dump 实测摘要）|
|---|---|---|---|
| 01 | `screenshots/01-admin-login.jpeg` | 管理端 | 登录页：`智慧医院 / 管理端 / 运营看板·基础数据·AI 能力中心`；`在线服务 / 演示数据` 切换、管理员账号与密码、`登录` |
| 02 | `screenshots/02-admin-dashboard.jpeg` | 管理端 | 运营看板：`累计挂号 0`、`号源使用率 0%`、`分诊命中率 0%`、`预问诊完成率 50%`、`近 7 日挂号趋势`；聚合卡片 `号源 剩余 2 / 共 2（排班 1 条）`、`病历 共 0 份`、**`AI 模型 deepseek-chat · 工具 6/6 · 提示词 0/3`**、`知识库 文档 1/1 · 切块 1/1 · 覆盖率 100%`；底部 `响应不含任何 patient_id / doctor_id / phone / name，只出聚合计数` |
| 03 | `screenshots/03-admin-ai-center.jpeg` | 管理端 | AI 能力中心：`ai.enabled=1`、`ai.endpoint=https://api.deepseek.com/chat/completions`、`ai.model=deepseek-chat`、`ai.timeout_secs=30`、`ai.max_concurrent=4`、`ai.max_tokens=2048`、`ai.key_ref`（**只显示引用，不显示密钥本体**）|
| 04 | `screenshots/04-patient-login.jpeg` | 患者端 | 登录页：`智慧医院 / 患者端 / 智能分诊 · 预问诊 · 预约挂号 · 医疗档案`；底部 `医生登录 · 管理端登录` 两个显式入口 |
| 05 | `screenshots/05-patient-home.jpeg` | 患者端 | 首页：`您好，演示患者`、`今天需要什么帮助？`、`目前没有已挂号的预约，可以先完成智能分诊再选择号源`、常用服务四宫格、`医疗公告（暂无公告）`、底部 Tab |
| 06 | `screenshots/06-patient-triage.jpeg` | 患者端 | 智能分诊：主诉 `腹痛拉肚子两天`；结论 `本院暂未开诊「消化内科」，建议咨询导诊台…`；**判断依据：① 推荐来源：模型增强 ② 校验结果：推荐备选号源 ③ 可用号源：1 个，均来自服务端实时校验** |
| 07 | `screenshots/07-patient-triage-options.jpeg` | 患者端 | 同一次分诊的推荐号源卡片：`内科 / 张医生 · 主任医师 / 2026-12-24 上午 / 余 2 / 选择该号源` |
| 08 | `screenshots/08-patient-booking.jpeg` | 患者端 | 预约挂号：`科室编号 1`、`医生编号 1`、`就诊日期 2026-12-24`、`查询号源`、分段 `全部/上午/下午` |
| 09 | `screenshots/09-patient-booking-success.jpeg` | 患者端 | 挂号结果：**`挂号成功：2026-12-24 上午，序号 1`** + `查看就诊`；号源卡片变 `已预约该号源` |
| 10 | `screenshots/10-patient-visits.jpeg` | 患者端 | 我的就诊：`当前预约 / 2026-12-24 上午 / 序号 1 · 内科 · 张医生 主任医师 / 已挂号 / 退号` |
| 11 | `screenshots/11-admin-bad-password.jpeg` | 管理端 | **复查轮新增**：密码输错时停在管理端登录页，页面内红字 `账号或密码错误`。修复前这里会被 401 当成"会话过期"清掉会话、跳回**患者**登录页（医生/管理端输入错密码就被踢走） |
| 12 | `screenshots/12-admin-dashboard-live.jpeg` | 管理端 | 三端联调时的看板实况（有真实挂号数据后）：指标卡、`近 N 日挂号趋势` 柱状、聚合指标与 AI/知识库计数 |
| 13 | `screenshots/13-doctor-queue-gated.jpeg` | 医生端 | **三端联调新增**：队列分段改为 `全部 / 上午 / 下午`，副标题 `按状态展示接诊顺序（含历史与未来日期）`；2026-10-18 那张已 `已到院`、2026-12-24 那张仍 `已挂号`（点它的「到院登记」会被日期守卫拦下，红条文案见 [docs/archive/联调记录-2026-10-18.md](../../docs/archive/联调记录-2026-10-18.md) BUG-5）|
| 14 | `screenshots/14-admin-dashboard-triage-calls.jpeg` | 管理端 | **三端联调新增**：`累计挂号 2`、`号源使用率 40%`、**`分诊调用 0`**（替换原来恒为 0 的"分诊命中率"）、`预问诊完成率 50%`、**`近 14 日挂号趋势`**（标题跟随 `trend_days`，未来日期已不再计入）、`聚合指标 号源 剩余 3 / 共 5（排班 2 条）` |
| 16 | `screenshots/16-patient-triage-mock-subtitle.jpeg` | 患者端 | 分诊页两处 Mock 文案修复：副标题「按本地演示数据给出结论（不连服务端）」+ 判断依据第 3 条「来自本地演示数据（Mock），未经服务端校验」（202,795 B）| 分诊页两处 Mock 文案修复：副标题「按本地演示数据给出结论（不连服务端）」+ 第 3 条「来自本地演示数据（Mock），未经服务端校验」|
| 17 | `screenshots/17-doctor-emr-prefilled.jpeg` | 医生端 | 医生端「一键预填」修复后：提示「已用预问诊单补齐空段（医生已写的内容不覆盖）」，现病史/既往史/过敏史当场填上，体格检查仍空（184,497 B）| 医生端「一键预填」修复后：提示「已用预问诊单补齐空段（医生已写的内容不覆盖）」，现病史/既往史/过敏史当场填上，体格检查仍空 |

## 三、怎么复现（不需要 DevEco 界面）

```powershell
# 1) 构建（仓库根，自动探测 DevEco 位置并配好 SDK/JDK）
.\hvigorw.bat --mode module -p product=default -p module=entry@default assembleHap --no-daemon

# 2) 起服务端（另开一个窗口；先导 CA 包供 AI 出站使用）
powershell -NoProfile -ExecutionPolicy Bypass -File .\server\export-ca-bundle.ps1
$env:SSL_CERT_FILE = "$PWD\server\ca-bundle.pem"
.\server\build\hospital-server.exe serve "mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital_test"

# 3) 模拟器装包并启动（未签名 HAP 可直接装模拟器）
& "D:\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" install -r .\entry\build\default\outputs\default\entry-default-unsigned.hap
& "D:\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" rport tcp:8091 tcp:8091
& "D:\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" shell aa start -a EntryAbility -b com.smart.hospital.patient

# 4) 截图（比 -screenshot 参数可靠）
& "…\hdc.exe" shell snapshot_display -f /data/local/tmp/x.jpeg
& "…\hdc.exe" file recv /data/local/tmp/x.jpeg .\x.jpeg
```

**构建成功标志**：`BUILD SUCCESSFUL`；仅剩一条 `WARN: No signingConfig found for product default`（仓库不携带证书，属预期）。

## 四、本次运行环境的已知边界

- 模拟器：华为 **Pura 90**，HarmonyOS 6.1.1 / **API 24**；仓库 `compatibleSdkVersion` 为 5.0.0(12)，向后兼容，安装运行正常。
- 模拟器首次启动若 `kernel panic`（`Attempted to kill init!`），用 `Emulator.exe -start "Pura 90" -bootMode reset -noWindow` 重置后再起。
- 屏幕锁定时 `aa start` 会报 `10106102 The device screen is locked…`：先 `hdc shell power-shell wakeup`（`Emulator.exe -instance … -power` 是"关屏"，别用）。
- 未签名包只能装模拟器/开发者模式真机；正式分发需在 DevEco 里配置本机签名（本仓库刻意不含任何证书与口令）。
