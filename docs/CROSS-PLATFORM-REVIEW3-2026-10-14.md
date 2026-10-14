# 第三轮联合审查：修复复核与过度防御检查

日期：2026-10-14（UTC+8）。HEAD：`6b7997081e73202c7f405c7f5f06c92492b410c6`。差异基线：`a2d3402c529effdf58c77a8acce2c0e5ac49bbd8`，包括 `c9a41e8` 修复及合入的上游提交。

## 结论与审查口径

发现 **4 项新增确认的问题：3 项 P2、1 项 P3**，没有新增高置信 P1。它们是本轮新识别的既存问题，不宣称全部由本次修改引入。另有 **2 项可简化但非 bug 的实现**。上轮鸿蒙保留项继续未修，单独列出，不重复计数。

本轮新增要求为“禁止过度防御性编程”。据此检查：

- 不把未知故障猜成正常业务拒绝，不吞掉在线操作结果。
- 不让客户端的重复校验推翻服务器的权威业务状态。
- 同一状态验证与更新明确由一处原子完成，避免重复远程依赖。
- 鉴权、输入边界、病历锁定、幂等、旧响应隔离、事务隔离和资源释放有明确用途，继续保留。
- 可选字段的契约默认值与明确标识的规则降级，不仅因为存在 fallback 就算缺陷；没有具体错误路径的风格疑点不计为 bug。

采用三个只读 agent 分别审查 Android、鸿蒙与服务端，协调者复核证据并实际编译当前后端。Android 使用已安装的 android-kotlin-development 中适用的生命周期、错误处理指导，保留原生 Views 架构。

没有修改业务代码、安装依赖、操作设备、业务 API、运行中的服务或数据库。三个原有 Android README/Gradle 工作区修改完整保留。新增项目文件仅本报告；编译与探针位于隔离输出目录。

## 新问题

### T01 · P2：数据库故障被猜成参数错误或重复记录

主位置：[domain_base.cj:566](F:/cj_cup/smart_hospital/server/src/domain_base.cj:566)、[kb_repo.cj:622](F:/cj_cup/smart_hospital/server/src/kb_repo.cj:622)。两个 tolerant helper 捕获所有 Exception，只保存 message，再交给字符串分类器。

[baseClassifyDuplicate:607](F:/cj_cup/smart_hospital/server/src/domain_base.cj:607) 和 [kbClassifyDuplicate:646](F:/cj_cup/smart_hospital/server/src/kb_repo.cj:646) 把空消息猜成重复；其他不认识的数据库异常在 [domain_base.cj:610](F:/cj_cup/smart_hospital/server/src/domain_base.cj:610)、[kb_repo.cj:652](F:/cj_cup/smart_hospital/server/src/kb_repo.cj:652) 被改成 invalid。HTTP 层随后返回400或409，掩盖真正的服务故障。

明确触发：连接已因回滚失败被禁用，之后创建科室、公告或知识库；requireUsable 抛“数据库连接已关闭或事务回滚失败”，却得到“参数不合法”。如果底层异常消息为空，则被误报同名记录。新增 execInsert 的 ID 查询和 Statement 清理也处于这个过宽捕获范围内。

**实际源纯函数验证：**

```text
message=数据库连接已关闭或事务回滚失败
base_duplicate=false; base_invalid=true
kb_duplicate=false; kb_invalid=true

message=
base_duplicate=true; base_invalid=false
kb_duplicate=true; kb_invalid=false

message=Duplicate entry 'x' for key 'uk_department_name'
base_duplicate=true; kb_duplicate=true
```

探针直接使用原结果类型与分类函数，不连接数据库：[错误分类探针](C:/Users/23965/.codex/visualizations/2026/10/13/01a13611-ddef-7cb1-8cd0-db8fad7362c7/hospital-audit-round3-errors-f67d84e2b4694e2192ab7dcf51ef54c9/probe.cj)。HTTP 映射见 [http_base.cj:114](F:/cj_cup/smart_hospital/server/src/http_base.cj:114)、[http_kb.cj:133](F:/cj_cup/smart_hospital/server/src/http_kb.cj:133)。

最小修复：仅确认的唯一键错误转换409；其余保留原异常并上抛，交给统一服务错误处理。删除“空消息猜重复”和“未知数据库错误转参数错误”，不新增猜测查询、重试或重连机制。若驱动丢弃错误码，应在驱动边界保留类型/错误码，不能靠空消息推断。

回归判据：已知唯一键冲突仍409；连接关闭、SQL/ID读取/资源清理故障为服务错误，不能让用户修改合法输入来解决。置信度高：源码链与实际分类函数结果已确认；未运行真实数据库故障注入。

### T02 · P2：AI 配置旧快照能够覆盖写后失效

主位置：[ai_settings.cj:592](F:/cj_cup/smart_hospital/server/src/ai_settings.cj:592)、[ai_settings.cj:598](F:/cj_cup/smart_hospital/server/src/ai_settings.cj:598)、[invalidate:609](F:/cj_cup/smart_hospital/server/src/ai_settings.cj:609)。AiSettingsRepo 的 cache/cacheAt 没有仓储级同步。数据库连接锁只覆盖 query，不能保护 query 返回后的缓存发布。

确定的并发顺序：

1. 请求 A 查询得到旧配置 ai.enabled=1，查询返回后暂停。
2. 管理请求 B 写 ai.enabled=0，调用 invalidate；其响应重新读到新配置并返回200。
3. A 恢复，将旧 fresh 发布为 cache，并把 cacheAt 设置为有效时间。
4. B 成功之后的新分诊请求命中旧 cache，仍按开启状态调用模型，直到 TTL 过期。

写后失效位置：[ai_settings.cj:704](F:/cj_cup/smart_hospital/server/src/ai_settings.cj:704)；响应位置：[http_app.cj:1304](F:/cj_cup/smart_hospital/server/src/http_app.cj:1304)。现有5秒TTL用于多实例收敛，不消除单实例旧快照覆盖失效的问题；整数秒与 `>5` 判断可使窗口接近6秒。

最小修复：一个仓储级 Mutex 保护 get、reload 从查询到发布的全过程及 invalidate，保持锁顺序一致。无需增加重试、额外默认值或新的缓存版本登记。回归：强制 A旧读→B写入并返回→A发布的顺序，B返回后的新读必须是新值。

置信度高：独立源码复核确认无同步保护；尚未做数据库并发实测。本项只报告关闭成功后的新请求仍消费旧配置，不扩大为已经发生的数据泄露，也不涉及关闭前已开始的模型任务。

### T03 · P2：设备时钟的可售复判会误拦医院当天号源

主位置：[PatientRepository.kt:121](F:/cj_cup/smart_hospital/android-patient/app/src/main/java/com/smart/hospital/patient/data/PatientRepository.kt:121)、[PatientRepository.kt:129](F:/cj_cup/smart_hospital/android-patient/app/src/main/java/com/smart/hospital/patient/data/PatientRepository.kt:129)。Android 请求前拒绝设备日期之前的查询，收到响应后又按设备日期过滤。虽然固定了 Asia/Shanghai 时区，日期仍来自设备时钟。

触发条件：医院时间10-14 23:57，设备快5分钟显示10-15 00:02。查询医院仍可售的10-14，客户端在发请求前直接400；若请求在跨日前发出、跨日后收到，也会过滤服务器返回的仍可售号源。

服务端已经按医院日期和实体启用状态过滤患者可售排班，并在健康接口提供 today/timezone。Android目前没有调用或解析这两个字段；修复说明声称接收该健康日期，超出了实际实现。此处问题是设备时钟偏差，不是上轮鸿蒙设备时区问题的重复计数。

最小简化：保留日期格式解析，删除客户端用设备日期再次判定可售性的逻辑，让服务器决定业务有效性；默认查询日期统一使用医院 today。无需增加失败时猜日期的多层缓存/兜底。

回归判据：固定医院日期，设备快/慢跨午夜以及请求前后跨日，仍能查询、展示服务器确认可售的号源。置信度高，但影响以设备时钟偏差为条件；未调整设备执行验证。

### T04 · P3：在线注销失败被吞掉，正常退出提示失真

主位置：[PatientRepository.kt:84](F:/cj_cup/smart_hospital/android-patient/app/src/main/java/com/smart/hospital/patient/data/PatientRepository.kt:84)。runCatching 的结果被丢弃，网络、429、500等注销失败均不再传播。

[MainActivity.kt:532](F:/cj_cup/smart_hospital/android-patient/app/src/main/java/com/smart/hospital/patient/MainActivity.kt:532) 已有区分正常注销与“仅退出本设备”的两个分支，但在线失败被仓储吞掉，正常分支仍显示成功。例如冷却期间点击普通退出按钮，API层发请求前抛429，服务器未收到注销，客户端却提示正常退出。

最小修复：用 finally 确保本地清理，同时保留或返回在线注销失败结果，让已有本地退出提示生效；不增加自动重试。回归：成功时确认已吊销，断网/冷却/500时完成本地退出并明确在线吊销未确认。

置信度高：源码有完整可达路径，未运行设备/API复现。此项是结果状态被隐藏，不能据此声称已经发生凭据泄露。

## 可简化但非 bug

| 项目 | 位置 | 简化建议 |
|---|---|---|
| 每次重放前额外读取完整预约历史 | [PatientRepository.kt:151](F:/cj_cup/smart_hospital/android-patient/app/src/main/java/com/smart/hospital/patient/data/PatientRepository.kt:151) | 同 token POST 的权威结果与接管机制已能处理旧 A掉出200条历史；删除这项前置依赖，保留展示历史时的取消同步。减少一次网络动作，不删除幂等键与晚到响应保护。 |
| 同一会话锁内重复身份校验 | [PatientRepository.kt:69](F:/cj_cup/smart_hospital/android-patient/app/src/main/java/com/smart/hospital/patient/data/PatientRepository.kt:69) | me调用方和updateCurrentUserIfCurrent重复检查相同上下文；明确由一处原子验证并写缓存，保留不同失败类型的语义及跨账号隔离。 |

以下不属于过度防御，建议保留：权限与角色约束；病历锁定/必填；SSE done；挂号幂等与持久化；旧响应隔离；事务完整范围锁；未知事务状态禁用连接；Statement/QueryResult 的 finally 清理。本轮 ArkTS typed空请求体与 Mock工厂可见性修正是编译约束，不是冗余保护。

通用 JsonUtil 默认值目前没有找到稳定触发的正常流程错误，不仅凭风格计bug。鸿蒙 getRoot复用信封解析会把平铺health丢成{}，但当前没有调用者；应接医院日期时明确平铺解析，不扩散猜测多种响应形状的 fallback。

## 上轮问题与跨端残留

| 旧项 | 当前复核 |
|---|---|
| R01 编译阻断 | 已修。原当前完整服务端隔离编译退出0，没有使用影子修补源码。 |
| R02 共享连接事务/ID | 原根因在源码上已修。query/exec/物化/完整事务共用可重入锁，execInsert原子读取ID，生产创建入口均迁移；数据库失败交错仍待实测。 |
| R03 Android取消恢复 | 原回归在源码上已修。同T接受新B并退休旧A，历史只同步明确取消，不以200条列表缺失作为取消证据。 |
| R04 危急扫描 | 实际函数等价/性能验证通过，见下面证据；预算提前覆盖规则已用时间，但仍不宣称同步SQL有硬截止。 |
| R05–R08 鸿蒙编辑/预填/注销 | 全部未修，继续保留，不重复计数。 |
| F03/F04/F05/F06/F08/F09/F13/F14/F15 | 九项鸿蒙专属仍未修；本轮鸿蒙变更仅编译类型/可见性与锁文件。 |
| F11/F16 Android身份 | 新expires_at可选解析及姓名更新保留；在线有效性由服务器判断，不因旧本地期限清登录。 |
| F11鸿蒙覆盖 | 患者/医生/管理员登录仍用最初expiresAt，me不更新最新期限。服务端已续期的令牌可能无法自动恢复；是跨端覆盖残留，不是本轮回归。 |
| 医院日期与health | 服务端today/timezone已提供，两端都没有完整消费；鸿蒙F14仍在，Android另有T03的设备时钟误判。 |

## 实际验证及未验证范围

- 按项目固定cjc 1.2.0、stdx静态库、现有MariaDB驱动和相同业务/框架文件集，对原当前源做完整隔离编译：`Review3 compile exit: 0`。产物在授权visualizations目录，未启动服务、未覆盖原服务exe。
- 实际Mutex探针：同线程两次lock后正常两次unlock，输出 `same_thread_double_lock=true`，确认修复使用的可重入性质。没有把此探针冒充数据库并发验收。
- 危急规则实际源码对照a2d3402旧算法：4720组高危词、否定、emoji、重叠及标点案例，redFlag/evidence零差异。重复否定7000/14000/28000项耗时86/164/317ms；上轮7000项12644ms，已消除近二次增长。本机测量不推广为所有部署硬件固定时延。
- 原规则与性能探针：[probe.cj](C:/Users/23965/.codex/visualizations/2026/10/13/01a13611-ddef-7cb1-8cd0-db8fad7362c7/hospital-audit-round3-rules-7dc65ed4c50e4e23950ddcd0083f261c/probe.cj)。
- T01实际分类函数已编译执行；T02/T03/T04为高置信源码证据，未做对应并发/设备/网络注入。
- 未执行Android/Harmony整包构建、Release签名、真机布局、真实TLS/SSE或数据库并发验收。当前源码可编译不代表两端整体交付已通过。

最小下一步：后端删除T01错误猜测并同步T02缓存发布；Android删除T03设备可售复判、让T04注销结果正常传播。独立QA分别验证已知唯一键/真实故障、配置写后新读、跨日偏差、在线与本地注销。实现时沿用本轮“必要边界、单一责任、异常不伪装”的口径，避免继续堆额外fallback。
