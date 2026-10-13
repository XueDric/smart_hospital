# Android 修复交接 · 2026-10-13

依据外部 `F:/cj_cup/test-runs/REPORT.md`、`F:/cj_cup/test-runs/ux/logic-findings.md` 与 `F:/cj_cup/test-runs/android/HANDOFF-T5.md`，run_id `RUN-20261013-022016`。非 Android 内容已同步 main `ce22df2445eaba3277b8c976b69fcae0a948c0f6`，本轮只修改 Android。

本工作流未运行测试、编译、脚本门禁、签名校验、设备操作或 API 请求。外部报告的旧 APK 结果不代表本轮源码通过，用户需重新构建 APK 并按以下清单复测；当前状态为 **实现后待验证**。

## main 同步与原工作区备份

HEAD 已快进到上述 main 提交。受版本控制的非 Android 文件与 origin/main 没有差异；报告 BL-1 指出的本地 SQL 改动已随同步移除，当前服务进程是否使用新源码没有验证。BL-2 的测试库隔离与孤儿账号根因没有另行改动。

同步前的非 Android 本地修改保留在 Git stash 中，名称为 `codex-before-main-sync-20261013 tracked non-android changes` 和 `codex-before-main-sync-20261013 additional ignore changes`。原非 Android 未跟踪的源码、工具和文档移至 `C:/Users/23965/AppData/Local/Packages/sandbox.{78f2e73a-df1a-45da-bd14-50a90f1a2148}/AC/Temp/smart-hospital-before-main-sync-20261013`。这些备份没有重新套用到 main；本地工具缓存与 agent 配置继续保留。

## 报告编号回归清单

| REPORT ID | 对应 UX / T5 | 交接内容与用户需确认的结果 |
|---|---|---|
| H-1 | UX B-01 | 错误密码显示原因并保留登录名、清密码；会话失效后新登录页显示原因；切页期间旧 401 不得误清新账号 |
| H-2 | UX H-01 | 完成后能开始新一轮；客户端完成态不继续向旧问诊提交答案；服务端完成后拒写仍属于后端验收 |
| H-3 / M-11 | UX H-02 | Debug 全程显著标注演示与非真实预约；登出清演示身份；Release 禁演示入口与 mock 分支 |
| H-4 | UX H-04 / T5 F-13 | 分诊长度提示与截断反馈可见，不能声称服务端分析了完整长描述 |
| H-5 | UX H-03 / T5 F-02/F-11 | 仅 SSE done 才确认开流完成；随后 GET 结构化状态驱动 filled/total_slots/next_slot/next_question；delta 仅作启动说明，不作当前问题或进度依据 |
| H-6 | UX M-06 / T5 F-01 | 主诉不放 URL query；main 未读取 header 时，用 JSON answer 提交用户真实 chief；会话失效不写占位主诉 |
| M-2 | UX M-07 | 新旧 token 均须同步落盘成功才发送请求；超时及进程重启复用持久 token；幂等回放显示已有预约；退号后新挂号生命周期正确 |
| L-1 | UX L-03 / T5 F-05 | slot_restored 缺少/异常时不显示“号源已归还”，保留 warning |
| L-2 | UX M-01 / T5 F-09 | 所有在线 API 受冷却保护，公共 banner 显示剩余秒数；登录按钮冷却时禁用；非登录动作按钮尚未全部灰禁，仍可点但不发送网络请求 |
| L-3 | UX B-02 | 档案入口和已完成预约可进入只读病历；不向患者显示草稿正文；不存在/不可访问有恢复提示 |
| L-4 | T5 F-12 | 日期使用医院 Asia/Shanghai 口径，query 编码正确，分诊选中号源不串号 |

REPORT H-7～H-9、其余服务端 M 项、L-5～L-8 及 BL-1/BL-2 不属于本轮 Android 源码修复，不宣称已修复。挂号/退号服务端 500、测试清活体库与孤儿账号等根因必须另由最新 main 和外部验收确认。

## 附加 UX 与辅助工具验收

| 项目 | 用户需复测 / 当前范围 |
|---|---|
| UX M-02 | 同一个 Activity 的切 tab/返回保留分诊草稿/结果、日期和预问诊草稿；只保留页面内存，不承诺 Activity 重建或进程终止恢复草稿；退出清患者内容 |
| UX M-03/M-04 | 断网可页内重试；售罄刷新余号；作答 404 回到重新填写真实主诉，不反复向旧 session 提交 |
| UX M-05 | meta 后断流仍失败但保留已知 session；恢复加载不重复新建；仅 done 可确认流完成 |
| UX L-01/L-02 | 危急 patient_note 与拨号入口；AI 说明不直接显示 ai_reason 的上游诊断信息 |
| UX L-04/L-06 | 登录前服务地址可改；404/5xx/非法信封使用安全患者文案 |
| UX L-05 | **全面 strings.xml 资源化尚未完成**，本轮只提取 app_name、演示与部分关键提示；其余中文硬编码仍是后续改进项 |
| UX L-07/L-08 | 读屏状态/返回描述；API 33+ 平台回调和旧版返回行为；首页再次返回退出 |
| 时段/名称/演示号源 | AM/PM/未知时段容错；名称来自 main 接口；第二排班的医生、科室、日期时段和 ID 正确 |
| 身份与异步退出 | 同步身份核对患者角色、用户与档案 ID；退出处理中暂缓页面跳转，避免退出结果丢弃；旧身份请求不能覆盖新账号 |
| T5 F-06/F-07 | 独立校验脚本按 JAVA_HOME→工作区 JDK→PATH 找 Java，按 PATH/SDK 找 apksigner；缺运行文件或签名失败明确失败；local.properties 不入库 |
| 工具链 | 完整 JDK、SDK Platform 35 / Build-Tools 34.0.0 / Wrapper；本轮需用户重新编译，不能复用旧 APK 通过结论 |
| Release | HTTPS、四项签名配置、APK 签名升级/AAB 分发由外部验证，BuildConfig.DEBUG=false 禁演示 |

## 兼容性和证据边界

main 当前 stream 读取的是 legacy query，不能把 Android 适配说成服务端已支持 X-Previsit-Chief。Android 先读 SSE，再 GET 会话状态；如 chief 尚未采集，以 JSON answer 提交用户真实主诉。delta 标成“启动时系统说明”，当前下一问以结构化状态为准，避免旧主诉问题与下一问混淆。

病历列表只读进度与就诊上下文，详情仅显示服务端允许患者读取且锁定的病历。草稿内存保留与持久幂等 token / session 恢复是不同能力：后两者需要进程重启回归，前者没有持久化承诺。

AGP 8.5.2 对 compileSdk 35 的既有警告不等于本轮编译结果。本轮没有运行构建或验证，外部报告 RED 不因代码修改自动变为 PASS。
