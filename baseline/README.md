# 社团管理工具

社团内部管理工具，解决两个问题：**① 社团里有哪些人 ② 每件事由谁负责、做到什么程度。**

首页是「我的任务」，不是组织架构图。名录只是任务的目录——真正让人每天打开 App 的是"我负责什么"。

| 项 | 值 |
| --- | --- |
| 客户端 | 鸿蒙 App（**ArkTS**）—— 见 `entry/`、`AppScope/`，页面在 `entry/src/main/ets/pages/`（**21 个页面文件**）。**本机已实测可编译打包**（见 `docs/client-build.md`）；**已接真实接口**（早期"未接接口"的说法已于 2026-10-04 更正） |
| 服务端 | 仓颉 **1.2.0** + [轻舟 QingZhou](https://gitcode.com/BIT-FSSLab/QingZhou) **v0.12.0**，Windows 部署 |
| 持久化 | **MySQL**（2026-09-20 起）：内存 `Store` 全量载入 + 每变更在一个事务里写回（路线 B：只换持久化层）。**需要一台可连的 MySQL/MariaDB** |
| 传输 | **框架原生 TLS**（不用 Nginx），自签证书必须带 SAN |
| 第一版目标 | 社团内部试用 2 周 |

---

## 当前进度

| 模块 | 内容 | 状态 |
| --- | --- | --- |
| **服务端 M1 骨架** | 构建链路 · Store 与原子落盘 · 统一响应/错误码 · 时间与时区 · **`can()` 权限函数** · 认证 5 接口 | ✅ 完成并验证 |
| **服务端 M2 组织与成员** | 部门增删改（会长独占）· 名录/详情/编辑 · 移出社团 · 待分配与**批量分配** · **会长移交（原子）** · 重置密码 · 注册口令 · 招募链接 | ✅ 完成并验证 |
| **服务端 M3 任务** | 我的任务（服务端分组）· 列表筛选 · 详情 · 创建（`client_token` 幂等）· 编辑/转交 · 状态流转与阻塞原因 · 软删除 · 日历同步 `lookup` | ✅ 完成并验证 |
| **服务端 M4 课题** | 课题树（递归进度）· 详情（面包屑）· 创建 · 编辑 · 移动（**环形校验** + 深度 6 + 禁止跨部门）· 删除（**子节点上提，绝不级联**） | ✅ 完成并验证 |
| **服务端 M5 部署** | 带 SAN 自签证书 · TLS 1.2/1.3 通过、1.0/1.1 被拒 · 部署包 18.8 MB · 从部署目录端到端跑通 | 🟡 本机完成；**公网部署待服务器信息** |
| **服务端代码评审修复（第一轮）** | 按 `docs/code-review.md` 修完 3 个 P0 权限漏洞 + 8 个 P1 + 13 个 P2，并补上会真正失败的回归测试 | ✅ 完成并验证 |
| **服务端代码评审（第二轮）** | `docs/code-review.md` 的 9 条新发现：文档类 N-2 / N-3 / N-4 · **N-1**（落地页 HTML 转义）+ **N-9**（CSP）· **N-7**（不可作用于同权/更高权的人，已从"重置密码"推广到改角色 / 禁用 / 改名）· **N-5**（`idem` 补校验）· **N-6**（注册节流改**按客户端 IP + 递增退避**，因此无需新增接口）—— **全部处理完毕**（N-8 按约定不改），每条都补了会因回退而变红的断言 | ✅ 完成并验证 |
| **服务端代码评审（第三轮）** | `docs/code-review.md` 第三轮复验：第二轮 9 条**全部确认修复**；新发现 4 条（**N-10** `assign`/`assign-batch` 漏在同权保护之外 · N-11 文档限定词 · N-12 裸 IPv6 退化 · N-13 分布式尝试）—— **已全部处理**。N-10 的两个面（降级同权者、用 `assign` 推翻会长对同权者的移出决定）都已堵住 | ✅ 完成并验证 |
| **轻舟升级与 CangDB 适配** | 升级轻舟到 **v0.12.0 之后的 HEAD / `3d6c1a36`**（v0.10.0 → v0.12.0，补齐出站 HTTPS/重试、并发闸门、容错 JSON、schema 校验、日志脱敏、参数化查询）；`store.cj` / `rbac.cj` 仍按项目架构排除，使用 `server/src/fw_rbac_store.cj` + `fw_rbac.cj` 适配。**⚠ 升级后必须显式传 `noBackslashEscapes: false`** —— 新框架默认把会话 `sql_mode` 固定成 `NO_BACKSLASH_ESCAPES`，会让反斜杠多存一个（见 `docs/mysql-backend.md` §12.3） | ✅ **完成并验证**（2026-10-02）：Windows 本机六套全绿 —— 单测 **510 / 562（带 DSN）** · 冒烟 **440** · TLS **23** · 契约 **33** · 后台 **38** · 运维页 **82**，全部 **FAIL 0**；Linux 侧亦实编实跑通过 |
| **轻舟后台管理界面（新增）** | 随轻舟 **v0.12.0** 快照提供后台管理界面，`build.ps1 -Target admin` 生成 `build\admin\admin.exe`（自包含：exe + 前端 + `admin.env`）。当前运维台和 club-server 都使用 MySQL 数据层；端到端验证脚本为 `server/tests/admin-check.ps1` | ✅ **完成并验证**（后台端到端 **38 / 0**、运维页端到端 **82 / 0**；2026-10-02 随 v0.12.0 快照复跑）|
| **「社团管理」运维页（新增）** | 后台里加一页 `/club`：**读**直接读社团库文件（`server/src/ops/*`，club-server 不在跑也能看），**写**由后台以**专用运维账号**（club-server 的 `role = ops`）的身份调用 club-server 真实 API（分配/停用/重置口令/换注册口令/部门增删/优雅停服），另带概览、任务/课题/招募链接查询、**审计日志**与**一键备份**。入口是我们自己的 `src/ops/admin_main.cj`（上游 `examples/admin.cj` 只作对照、逐字节原样）；顺手修掉上游"成功响应也可能带 404"的状态码问题。端到端验证 `server/tests/ops-check.ps1` | ✅ 完成并验证（运维页端到端 **82 / 0**） |
| **运维身份独立于会长（新增）** | 运维**不该由会长执行**：新增内置身份 **`ops`**（权限 = 会长去掉「移交会长」，**不可由 API 分配**，只能 `club-server init-ops <手机号> <口令>` 创建、`retire-ops` 停用）。运维人员只登录后台（口令由 `admin.exe` 首次启动随机生成），后台代持运维账号去调 club-server → **审计里 actor 是运维**，与会长做的操作分得清清楚楚。顺带补齐部门新增/改名的审计（原先只有删除记了） | ✅ 完成并验证（单测 490 / 冒烟 422 全绿） |
| **服务端容量基准与四项性能改造** | 按"接近千人"的容量问题做了可复现基准（`server/tests/bench.ps1`，真实 HTTP + 旧版本 worktree 对比），并落地四项改造：① 列表排序插入排序→**堆排序** ② **PBKDF2 移出全局锁**（三阶段加锁）③ 过期**令牌回收** ④ 整库落盘移出锁（请求链末端刷盘）。实测只有 ② 有量级收益（**4 并发登录 1574 → 867 ms**），①④ 在千人档落在噪声内、价值是最坏情况下界 —— 见 `docs/capacity-baseline.md` | ✅ 完成并验证（单测 349 / 冒烟 347 / TLS 22） |
| **服务端第四轮复验修复** | 按 `docs/code-review.md` **第四轮**的 6 条新发现修：**N-14**（本机判定用子串匹配 `::1` → 远程 IPv6 可远程关停服务，改成按地址相等比白名单）· **N-15**（4 个 handler 被 4xx 拒绝却留下半改状态并落盘，改成两阶段赋值）· **N-16**（登录时序侧信道可枚举手机号，改成两条路径等价 PBKDF2）· **N-17**（审计 IO 移出锁）· **N-18**（任务可挂任意部门课题，补部门一致性）· **N-19**（招募 token 32 位 → 32 字节） | ✅ 完成并验证（单测 387 / 冒烟 360 / TLS 22） |
| **按 UI 设计规格对齐服务端** | 拿《鸿蒙俱乐部-全场景UI设计规格》13 页逐条对服务端，8 条按设计稿落地（含队友复验补的 2 条）：**D-1** 权限摘要补 5 个管理布尔（由 `can()` 推导）· **D-2** 名录 `?q=` 搜索姓名或部门 · **D-3** 任务/课题**读**范围放开到全社团（写不变）· **D-4** 阻塞任务的**求助对象** `needs_help` + 部长首页带出本部门阻塞项 · **D-5** 任务**逾期天数** `overdue_days` · **D-7** 成员详情补 `done_tasks` / `overdue_tasks`。另**定稿密码口径**（D-6：8–32 字节 + 只允许数字/英文/符号，有意偏离设计稿的 6 位下限）；其余按决定保留原版本。逐条证据见 `docs/ui-spec-conformance-review.md` | ✅ 完成并验证（单测 471 / 冒烟 421 / TLS 22 / 契约 30） |
| **客户端（ArkTS）** | 技术栈定为 **ArkTS**（2026-09-14）。**已远超"3 页 / 假数据"的早期状态**（2026-10-04 据实更正）：`entry/src/main/ets/pages/` 现有 **21 个页面文件**，`resources/base/profile/main_pages.json` 登记 **11 条路由**；另有完整的 `api/`（`AuthApi` / `MemberApi` / `TaskApi` / `PlanApi` / `DeptApi` + `HttpClient`）、`store/`（7 个状态仓：`TokenStore` / `SessionStore` / `PermissionStore` / `ServerConfigStore` / 离线 `OutboxStore`+`OutboxSync` / `CalendarMapStore`）、`util`+`utils`（日历同步 / 深链 / 日期 / 课题树）、`components/`（5 个）、`core/Theme.ets`、`config/Env.ets`。页面**已在调真实接口**（如 `Index.ets` 调 `/auth/me`；登录、注册、名录、任务、课题、管理页均走 `api/` 层），并具备令牌鉴权、与服务端同口径的 `PermissionStore.can()`、离线队列与系统日历同步。⚠ **客户端相关文档滞后**：`docs/client-build.md` 最后更新 2026-09-14，而页面最后改动 2026-09-29 | 🟡 可构建（**未签名**）；**待签名 + 待真机联调**（不再是"待接接口"） |
| **club-server 持久化迁 MySQL（2026-09-20）** | 按 `docs/club-server-mysql-assessment.md` 的**路线 B**（只换持久化层）把 club-server 的数据层从"整库重写 `data/db.json`"换成 **MySQL**：新增 `server/src/mysql_store.cj`（建库建表 / 全量载入 / **一个事务**里落盘，全部**参数化** SQL）· CLI 接受 **DSN**（`mysql://user:pass@host:port/db`）或 `--mysql-*` · `snapshotFlush` 语义不变（**200 ⇒ 事务已提交**）· **内存模型与全部业务/派生逻辑一行未动**（507 条单测语义不变）· 运维页的社团库读取同步改为直连 MySQL（`club_mysql_db`），「一键备份」改成从 MySQL 导出 JSON 快照 · 新增 `tests/mysql-common.ps1` 共用测试库夹具。**代价：club-server 从此需要一台可连的 MySQL** | ✅ 完成并验证（单测 507 / 带 DSN 555 / 冒烟 440 / TLS 23 / 契约 33 / 后台 38 / 运维页 82，全 FAIL 0） |
| **迁移收尾的两个修正（2026-09-20）** | ① **运维页概览不再撒谎**：`/api/club/overview` 原来报 `db_file` / `db_exists` / `db_bytes` / `db_mtime`（都指向 `data/db.json`），迁到 MySQL 后那个文件不再产生 → 页面会永远显示「库文件 …\db.json · 0.0 KB · 最后写入 —」，看着像"库空了"。改成 `db_backend` + 只报真正还在写的 `audit`（`file`/`bytes`/`lines`），运维页文案与 `dist` 一并重编。 ② **非 UTF-8 请求体不再 500**：客户端按 GBK 发 JSON（PS 5.1 不写 charset 时的默认行为）会让框架 `bodyJson()` 里的 `String.fromUtf8` 先抛、异常绕过 `_bodyJsonError` → **500**；已在 `limits.cj` 补闸门 ④（带上限流式读 + 应用层接住解码异常）→ **400 `INVALID_JSON`**。两条都补了回归闸门（冒烟 §27.10/§27.11、运维页检查 +3 条），见 `docs/API-NOTES.md` 坑 41 | ✅ 完成并验证（冒烟 440 / 运维页 82，全 FAIL 0） |
| **服务端 P0/P1 修复（2026-10-04）** | ① **P0 字符集**：驱动握手把会话字符集写死成 **utf8mb3（id 33）**，而库与 9 张表都是 utf8mb4，全仓又没有任何 `SET NAMES` —— 于是**一个 4 字节 UTF-8 字符（emoji）就让之后的所有写入持续 500**（读请求仍返回 200，读的是未落盘的内存；实测建 4 条只提交 1 行），而触发点落在**无需认证**的注册姓名/自由文本上。已在 `mysql_store.cj` 建连后补 `SET NAMES utf8mb4`，并补 4 字节回归断言（回退即红）。② **P1 落盘竞争**：MySQL 刷盘原先**不持 `s.lock`** 就遍历内存 HashMap（只持 `save_lock`）→ 改为在 `storeSnapshot`（锁内）拷好、随 `Snapshot.entities` 带出锁，`writeDbToMysql(s, cur)`；文件后端一行未动。③ **P1 测试脚本**：`tests/mysql-common.ps1`（及 `admin-check` / `ops-check` 里的私有副本）默认带 **`--skip-ssl`**（`$env:CLUB_MYSQL_USE_SSL=1` 可关），且**不再吞掉客户端 stderr** —— 否则本机 7 套脚本会因客户端 TLS/SSPI 握手失败而**误报「连不上 MySQL」**（库其实是好的） | ✅ 完成并验证（2026-10-04）：单测 **510 / 562（带 DSN）** · 冒烟 **440** · 契约 **33** · 会长姓名 **45** · 后台 **38** · 运维页 **82** · 前端逻辑 **17**，全 **FAIL 0**；`-Target admin` 亦重新编译通过。⚠ TLS 那 23 项本机**跑不全**（`server/certs` 不入库、本机那份是 2026-09-17 的旧件 → SAN 检查 4/3 失败）；已用**改动前**的二进制复现同样结果，证明与本次改动无关 |
**接口进度 40 / 40**（认证 5 · 组织与成员 20 · 任务 8 · 课题 6 = 39 个业务接口，另加运维 `/health` 1 个）。
> 口径说明 1：早期写「38 / 39」是把 `docs/api-design.md` §6.1「接口总清单」里的 `/health` 漏算了。
> 口径说明 2：2026-09-16 新增 `GET /api/v1/join/{token}`（招募链接的公开 JSON 解析，D-16）后为 **40 / 40**。
> 此外还有一个**不在接口清单里**的公开 HTML 页面 `GET /join/{token}`（招募链接落地页，给浏览器看的）。

**四套测试全部通过**（每次改动都要跑）：
**⚠ 前置（2026-09-20 起）：`smoke.ps1` / `tls-check.ps1` / `client-contract-check.ps1` / `ops-check.ps1`
都需要一台可连的 MySQL/MariaDB**（服务端持久化已换成 MySQL）。四个脚本各自用**专用测试库**
（`club_smoke` / `club_tls` / `club_contract` / `club_ops_e2e`），开头显式探测可连性，
取不到就**判 FAIL 并以非零码退出**（不静默跳过）。默认连 `127.0.0.1:3307`（本机便携版 MariaDB，
见 `docs/mysql-backend.md`），可用 `CLUB_MYSQL_HOST/PORT/USER/PASS/DB` 覆盖。
> ⚠️ **2026-10-04 起**：这些脚本调 mariadb/mysql 客户端时**默认加 `--skip-ssl`**。原因是部分
> Windows 环境下客户端会在 TLS/SSPI 握手阶段就失败（`TLS/SSL error: no credentials … SEC_E_NO_CREDENTIALS`），
> 而**库本身是好的** —— 旧版本没有这个开关，会把它报成「连不上 MySQL / 口令不对」，把排查方向带偏。
> 需要真实 TLS 的机器设 `$env:CLUB_MYSQL_USE_SSL=1` 关掉它。连接失败时脚本现在会**打印客户端原始报错**。

`club-server.exe test` **不需要** MySQL（单测只构造内存 Store）；给它一个 DSN 会额外跑一次
MySQL 持久化往返 + 增量落盘验证（**+52 条断言**，含 4 字节 UTF-8 字符的回归闸门）。

```powershell
cd server
.\build\club-server.exe test                                              # 单测 595 项（不带 DSN）
.\build\club-server.exe test "mysql://root:clubroot123@127.0.0.1:3307/club_test"   # 595 + MySQL 往返 53 项（含 4 字节字符闸门）
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\smoke.ps1     # HTTP 冒烟 440 项（含 §27 请求体闸门 11 条）
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\tls-check.ps1 # TLS 23 项（⚠ 需要带 SAN 的证书，见 docs/server-guide.md）
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\client-contract-check.ps1  # 前后端契约 37 项
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\init-name-check.ps1        # init-admin 的会长姓名选项 45 项（不碰正式库）
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\bench.ps1     # 容量基准（按需，见 docs/capacity-baseline.md）
```

> 冒烟里原本有一条**会因机器而异**的用例（N-21 的"登录按 IP 节流"反证，需要一块**非回环网卡**），
> 已于 **2026-09-18 随该节流一起移除** —— 口径是"应用层不做抗 DDoS，流量层的事交给网络侧"
> （见 `code-review.md` 的 N-21 后续决定）。现在冒烟**没有依赖网卡的用例，项数是确定的**；
> 判据仍然是 **`FAIL 0`**。

**后台 / 运维页另有几套**（改了 `build.ps1 -Target admin`、`fw_rbac_store.cj`、`src/ops/*`、轻舟快照或前端后都要跑）：

```powershell
cd server
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1 -Target admin   # 编运维台（会带上 server\admin-web\dist）
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\admin-check.ps1     # 后台自身（RBAC + MySQL）38 项
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\ops-check.ps1       # 「社团管理」运维页 82 项（含运维账号登录 / 写路径 / 备份导出）
node .\tests\web-logic-check.mjs                                                 # 前端逻辑 17 项（401 不该整页跳转，见 code-review N-32）
```

> 改了前端源码（`server\admin-web\src`）要重建 `dist`（需要 Node）：
> `cd server\admin-web ; npm install ; npm run build` —— 部署机不需要 Node，`dist` 随仓库提交。
> 本机没装 npm 时可直接用仓库里已有的 vite：`node node_modules\vite\bin\vite.js build`。
> ⚠️ 运维台**关闭了 ETag**（`admin_main.cj` 的 `staticOpts.enableETag = false`）：轻舟的 ETag 只按
> 文件字节大小生成，而 vite 重建后 `index.html` 字节数不变（只有 hash 文件名变）→ 浏览器会拿到
> 304 卡在旧 HTML 上、而它引用的旧 JS 已被删除 → **白屏**。见 code-review N-33。

---

## 目录结构

```
README.md                    本文件：唯一入口，看这一个就能了解项目状态
docs/                        所有文档（设计、验证、报告、指南）
server/                      服务端（仓颉）
  build.cmd                  build.ps1 的包装（免记 -ExecutionPolicy Bypass；双击也行）
  build.ps1                  编译（cjc + stdx + 轻舟同包编译；工具链自动探测）
  build-mysql-driver.ps1     编译内置 MariaDB 驱动产物（编译服务端前必须先跑一次；产物不入库）
  dev-serve.ps1              ★ **联调一键起服务**：顺手起便携版 MariaDB + 起服务 + 打印客户端该填的地址
  build-package.ps1          生成部署包 dist\club-server\（exe + 4 DLL + 证书 + 说明）
  src/                       27 个源文件，按职责分层（见下）
  src/ops/                   运维台（`-Target admin`）专用源码：入口 + 社团库只读视图 + JSON 小工具替身
  admin-web/                 运维台前端（Vue 3 源码 + **预构建 dist**，在上游版本上加了「社团管理」页）
  tests/                     冒烟、TLS、前后端契约、容量基准、后台与运维页端到端脚本
  build/                     构建输出（每次编译重建，不入库）；build\admin\ 是运维台那份
  dist/                      部署包（含私钥，不入库）
  certs/                     自签证书与私钥（不入库）
  third_party/qingzhou/      内置的轻舟框架快照（出处与维护见其中的 PROVENANCE.md）
entry/  AppScope/  hvigor/   鸿蒙客户端工程（ArkTS；DevEco 要求这些在根目录）
  entry/src/main/ets/pages/           页面：Index / MemberList / MemberDetail / PendingApproval / Manage
  entry/src/main/ets/entryability/    EntryAbility.ets（UIAbility，loadContent('pages/Index')）
  entry/src/main/resources/base/profile/main_pages.json   页面路由登记（ArkTS 必需）
docs/                        见下方「文档索引」
```

### 服务端源码分层（`server/src/`）

| 文件 | 职责 |
| --- | --- |
| `main.cj` | 入口：`serve` / `serve-tls` / `init-admin` / **`init-ops`** / **`retire-ops`** / `test` + 全部路由注册 + **DSN / `--mysql-*` 连接参数解析** |
| `store.cj` / `store_persistence.cj` / `store_queries.cj` | Store 的三部分：数据模型与 JSON 字段映射；文件后端的原子加载/落盘（**快照在锁内、写盘在锁外**）；查询、堆排序、幂等与课题树辅助。**`Store.mysql` 非空时落盘改走 MySQL**（下方 `mysql_store.cj`） |
| **`mysql_store.cj`** | ★ **MySQL 持久化层（2026-09-20）**：建库建表（幂等）· `SELECT` 9 张表 → 复用 `*FromJson` 全量载入 · `writeDbToMysql` 在**一个事务**里整体替换（`DELETE` + 多行参数化 `INSERT`）· DSN/命名参数解析 · `MysqlStore` 封装 |
| **`perms.cj`** | ★ **`can(member, action, target)`——全项目唯一的权限判定点** |
| `auth.cj` | 口令哈希（PBKDF2-HMAC-SHA256）· 令牌 · 认证辅助 |
| `errors.cj` / `jsonw.cj` / `views.cj` | 错误码表 · 响应包装与取参 · 对外 JSON 视图 |
| `timex.cj` / `ids.cj` / `strx.cj` / `paging.cj` / `audit.cj` | 时间与时区 · ID 与随机口令 · 字符串工具 · 分页 · 敏感操作审计 |
| `h_auth.cj` `h_dept.cj` `h_member.cj` `h_secret.cj` `h_link.cj` `h_task.cj` `h_plan.cj` `h_ops.cj` | 各模块的 HTTP handler（按 api-design 的 Part 分组） |
| `fw_rbac_store.cj` / `fw_rbac.cj` | 轻舟 RBAC 的**本地适配层**（上游版依赖 CangDB；沧海 CangDB 已开源，但其 1.0.5 版本与 cjc 1.1.3 不兼容：编译通过、运行超时）：文件存储的数据层 + `requirePermission` 中间件 |
| `tests.cj` | 单测（`club-server.exe test`）；容量基准见 `server/tests/bench.ps1` |

### 运维台源码（`server/src/ops/`，只参与 `-Target admin`）

| 文件 | 职责 |
| --- | --- |
| `admin_main.cj` | 运维台入口：上游那套后台路由（登录/用户/角色/权限/健康/关停）+ **`/api/club/**`** 运维接口（含 `/api/club/session`：用专用运维账号换 club-server 令牌）+ 状态码修正（`statusNormalizer`）+ **社团库从 MySQL 载入**（`withClub`）+ **备份 = 从 MySQL 导出 JSON 快照** |
| `club_view.cj` | 社团库**只读**视图：概览 / 名录 / 部门 / 任务 / 课题 / 招募链接 / 审计日志（**白名单字段，绝不带 `pw_*`**） |
| `club_json.cj` | `jsonw.cj` 里 6 个小工具的自包含替身 —— 让 Store 三文件能编进运维台 |

> 这三张文件**不参与**服务端构建（`build.ps1` 取的是 `server/src/*.cj`，不递归子目录），
> 因此不会和 `jsonw.cj` 的同名函数撞车（轻舟"同包同名"是本项目记录过的坑）。
> **例外**：Store 三文件与 `mysql_store.cj`（都在 `server/src/` 下）两条构建**都要编**
> —— 运维台的社团库读取复用的就是 club-server 那份载入代码。

---

## 5 分钟上手（服务端）

> **⚠ 先准备一台可连的 MySQL / MariaDB（2026-09-20 起这是硬前提）。**
> club-server 的持久化已经从"一个 `data/db.json` 文件"换成了 MySQL（路线 B，见
> `docs/club-server-mysql-assessment.md`）。库与表都**不用手工建** —— 首次连接时程序会
> `CREATE DATABASE IF NOT EXISTS` + 建 9 张表。起一台本机便携版 MariaDB（免管理员、不装服务）：
>
> ```powershell
> & "E:\cangjie\mariadb\mariadb-11.4.13-winx64\bin\mysqld.exe" --datadir="E:\cangjie\mariadb\data" --port=3307 --console
> ```
>
> 下面示例统一用 `mysql://root:clubroot123@127.0.0.1:3307/club_server`
> （本机联调那台的参数）；口令里若含 `@ : / ? #`，在 DSN 里写成 `%40` 这样的百分号编码。

```powershell
cd server

# 1. 编译（并把 4 个依赖 DLL 复制到 build\）
#    ⚠ 编译前需要驱动产物：先跑一次 .\build-mysql-driver.ps1（只须一次，产物不入库）
powershell -NoProfile -ExecutionPolicy Bypass -File .\build-mysql-driver.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
#    不想记 -ExecutionPolicy Bypass 就用包装脚本：.\build.cmd（参数相同，双击亦可）
#    没有仓颉 SDK 的机器请直接用部署包（见 docs\local-deploy.md §4），**不需要编译**

# 2. 到 exe 所在目录操作（与部署形态一致：一切按相对路径）
cd build
$dsn = "mysql://root:clubroot123@127.0.0.1:3307/club_server"
.\club-server.exe init-admin 13800000000 ClubPass2026 $dsn   # 预置首任会长 + 4 个组织
#    会长姓名（不给则默认「会长」）：ASCII 用 --name LiSi；
#    **中文必须走文件**（中文当命令行参数会让程序在 main 之前就崩，见 docs\API-NOTES.md 坑 11）：
#    [IO.File]::WriteAllText("$PWD\n.txt","张三",[Text.UTF8Encoding]::new($false))
#    .\club-server.exe init-admin 13800000000 ClubPass2026 $dsn --name-file n.txt
.\club-server.exe serve 8080 $dsn                           # HTTP 起服务
# 或者 HTTPS（先用 openssl 生成带 SAN 的证书，见 docs\server-guide.md）
.\club-server.exe serve-tls 8443 $dsn --cert ..\certs\cert.pem --key ..\certs\key.pem

# 3. 不想写 DSN 就用命名参数（没给的项取默认值 127.0.0.1:3306 / root / 空口令 / club_server）
.\club-server.exe serve 8080 --mysql-host 127.0.0.1 --mysql-port 3307 --mysql-user root --mysql-pass clubroot123 --mysql-db club_server
```

> 🚀 **联调懒得记上面这些？** 回 `server\` 跑一条：
> `powershell -NoProfile -ExecutionPolicy Bypass -File .\dev-serve.ps1`
> —— 它会**顺手把便携版 MariaDB 起起来**（没起的话）、起服务，并把客户端该填的地址
> （模拟器 `10.0.2.2` / 真机与队友的局域网 IP）和防火墙命令直接打出来。
> 完整教程与"队友连不上"的六步排查见 **`docs/local-deploy.md` §0.5 与 §5**。
>
> ⚠ **`$dsn` 必须先定义，而且别只复制最后一行。** PowerShell 引用一个**未定义**的变量
> **不报错**，就是空串 —— 于是命令悄悄退回默认值（`127.0.0.1:**3306**` / root / 空口令），
> 报出来是 `Failed to connect 10061`，看着像"端口配错/数据库没起"。本机联调那台 MariaDB 在
> **3307**，所以照文档逐行复制特别容易中这一枪。程序现在会在连接**之前**提示
> 「⚠ 命令行没有给 DSN / --mysql-*，正在使用默认连接参数…」。

> **`cwd` 必须是 exe 所在目录**——**审计日志目录**（`--data-dir`，默认 `data`）与证书都按相对路径读。
> 部署包里的 `start-https.cmd` 已经做了 `cd /d "%~dp0"`。
> **业务数据不在文件里了**：`--data-dir` 现在只决定 `audit.log` 的落点
> （`data/db.json` 不再是真相来源；迁移前的旧文件留着也不会被读）。
> **本工具链的仓颉 std 没有 `getEnv`**，所以**不支持环境变量配置**，连接参数只能走命令行。

### 后台管理界面 + 「社团管理」运维页（可选）

后台这份现在有**两个页面**：上游那套（仪表盘 / 用户管理，管的是**后台自己的账号**），
以及我们加的 **「社团管理」运维页 `/club`**（管的是**社团的真实数据**）。
前端产物已随仓库提交，**部署机不需要 Node/npm**：

```powershell
cd server
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1 -Target admin   # -> build\admin\admin.exe
cd build\admin
.\admin.exe        # http://127.0.0.1:3000/  （运维页：http://127.0.0.1:3000/club）
```

- 后台账号 `admin`（角色 1）、`user`（角色 2）；**口令首次启动（建库）时随机生成**（各 16 个
  十六进制字符），控制台**打印一次**并写入 `build\admin\admin.env` 的 `admin_pass` / `user_pass`，
  之后不再回显 —— 想自己指定就把这两行取消注释填值（**别用 `admin123` 这类公开默认值**，
  2026-09-17 前它就是默认值，见 `code-review.md` N-29）。端口/密钥/令牌时长也在
  `build\admin\admin.env`（首次构建生成随机 64 位 `secret`，之后不覆盖）。
  ⚠ 这两条是**轻舟 RBAC 那套口令**（现在也在 MySQL 里，库名见 `admin.env` 的 `mysql_db`），
  与 `club-server` 的会长/成员账号（PBKDF2，存在 `club-server` 那个库里，见 `club_mysql_db`）
  **不是一套**，两边不能互用。
- **运维台（后台）自身的数据层**：最初是本地 JSON 文件（`build\admin\admin-data\rbac.json`）—— 沧海 CangDB 已开源，但其 1.0.5 版本与 cjc 1.1.3 不兼容（编译通过、运行超时），当时便复用我们的 `server/src/fw_rbac_store.cj`（内存 `Store` + 写时原子落盘：先 `.tmp` 再 `rename`）。**2026-09-19 起运维台已改用框架 `store.cj` + MySQL**，见 `docs/mysql-backend.md`。
- 运维页 `/club` 放给**后台的 admin 角色**，或**直接用运维账号登录进来的身份**
  （后端 `/api/club/**` 同口径；后台的 `user` 角色拿到 403）。
  它**读**社团库 —— **2026-09-20 起是直连 MySQL**（`admin.env` 的 `club_mysql_db`，默认 `club_server`，
  与 club-server 连的是同一个库、同一个实例；host/port/user/pass 复用 `mysql_*`），
  club-server 不在跑也能看（读的是**库**，不是谁的内存）；
  **写**在 club-server 侧的身份是**专用运维账号**（`role = ops`）—— 所以运维人员
  **不需要知道任何会长口令**，页面上也不出现任何社团账号的口令：
  1. 先在 club-server 建运维账号（一次性）：`club-server init-ops <手机号> <口令> [DSN]`
     → 权限 = **除「移交会长」外与会长同权**；退役用 `club-server retire-ops <手机号> [DSN]`。
     它**不可由 API 分配**（否则会长能造出权限略高于自己的账号），只能这样建。
  2. **直接用这个手机号 + 口令登录运维台**（2026-09-17 起登录框两种凭据都认）——
     不用改任何配置文件，写操作就是该账号的身份。
     也可以改用「后台代持」：把手机号/口令填进 `admin.env` 的 `club_user` / `club_pass`
     （留空 = 运维页只能看不能改，页面会提示），但**改完必须重启 `admin.exe`**。
  3. 页面直连 club-server 做写操作（令牌由后台代持，内存缓存 6 小时）。
  → 于是 club-server 的**审计里 actor 是"运维"**，与会长做的操作分得清清楚楚（职责分离）。
     会长 / 成员账号登运维台会被 **403**（运维不该由会长执行）。
- 运维页能做的写操作：分配/改派、停用、重置口令（含**会长的**口令）、换注册口令、
  **部门增删改**、优雅停服 club-server；**移交会长是会长专属，运维不参与**（按钮会明确提示）。
  另带概览、任务/课题/招募链接、**审计日志**（解析 `audit.log`）与**一键备份** ——
  备份的产物是"**从 MySQL 导出的一份 JSON 快照**"（与原 `db.json` 同结构，用同一套
  `*ToJson` 渲染）+ 审计日志副本，落在 `admin-data\club-backups\`；**存储层仍是 MySQL**，
  快照只是导出物。
- 验证：`tests\admin-check.ps1`（**38 / 0**，后台自身）+ `tests\ops-check.ps1`（**82 / 0**，运维页含运维账号登录与写路径）。
- **上游那个状态码特性已在我们自己的入口修掉**：上游 `respondOk/respondErr` 只写 body 的 `code`，
  而 `passOnNotFound` 路由 miss 时会先把 `ctx.status` 置成 404 → "成功响应带 404"。
  我们的 `src/ops/admin_main.cj` 加了一个链尾 `statusNormalizer()` 按 `code` 回写状态码
  （现在 `/api/me`、`/api/club/**` 都是 200，拒绝是 401/403）。**内置框架没动**，
  归属证据与细节见 `docs/API-NOTES.md`「坑 34」。

---

## 文档索引（全部在 `docs/`）

| 文档 | 用途 | 什么时候看 |
| --- | --- | --- |
| **`docs/HANDOFF.md`** | **交接说明**：项目现状、已冻结设计、验证过的技术事实、未决事项 | **接手项目先看这个** |
| `docs/server-guide.md` | 服务端指南：构建/运行/测试、进度、两条实现纪律 | 动服务端代码前看 |
| **`docs/local-deploy.md`** | **本机部署一页上手**：**§0.5 联调速查**（三条命令 + 一键脚本 `server\dev-serve.ps1`）· 前置体检 · **部署顺序**（编译 → 一次性初始化〔会长 + 运维账号〕 → 起服务 → 验证 → 停止 → 注册 → 可选运维台）· HTTPS · 部署包 · **§5 客户端怎么连 + "队友连不上"六步排查**（同一网络 / 防火墙 / 地址写法 / 明文被拦）· 清库重来 · 数据与备份 · 坑表 | **第一次在本机跑服务端、或要拉队友联调看这个** |
| **`docs/API-NOTES.md`** | 编译期 API 事实清单 + **40 余条踩坑记录**（含"轻舟成功响应也可能带 HTTP 404"「坑 34」、"关停端点回执可能丢失"「坑 36」、"仓颉枚举不能用 `==`"「坑 38」、"框架 `bodyJson()` 让非 UTF-8 请求体变 500"「坑 41」） | 加新函数前先查（避让框架同名符号） |
| `docs/api-design.md` | **接口设计的唯一权威**：40 个接口逐条定义 | 写服务端时全程对照 |
| **`docs/code-review.md`** | **代码评审报告（六轮）**：一 24 条 · 二 9 条 · 三 4 条（N-1…N-13）· 四 6 条 + N-20 · 五 4 条（N-21 登录 CPU 放大 / N-22 构建脚本陷阱…）· 六 3 条（**N-29 运维台默认口令** / N-30 测试环境依赖…）—— 前五轮已修并复验，**第六轮见文末** | 想了解"哪些坑已经踩过、为什么这样写" |
| `docs/v1-scope.md` | 范围基准：11 页面、6 张表、19 条业务规则、权限矩阵 | 想知道"这个要不要做" |
| **`docs/ui-spec-conformance-review.md`** | **UI 设计规格 ↔ 服务端一致性审计**：13 页逐条对照、15 条差异（含 4 条设计稿自相矛盾）+ 已对齐清单 + 处置口径 | **改服务端契约前先看这个**（尤其是"读范围全社团、写不变"这条边界） |
| `docs/frontend-brief.md` | 前端对接精简版 | 客户端同事看 |
| **`docs/client-build.md`** | **客户端构建与现状**：构建命令、两个环境坑（JBR / SDK 路径）、ArkTS 迁移记录、剩余 TODO | **动客户端前先看这个** |
| **`docs/client-bug-handover.md`** | **客户端 bug 交接单（给前端小组）**：2026-09-18 双端审查发现的客户端缺陷 + 逐条复核结果（C-1…C-7），含**位置 · 根因 · 证据 · 建议修法 · 验收标准** + 「核查过但不是 bug」清单。**接接口前先对一遍**。<br>⚠ 2026-09-20 清理仓库时移除了历史的三轮 `client-integration-review{,-2,-3}.md`（内容已被本文取代；要看原文用 `git log --diff-filter=D -- docs/client-integration-review.md` 找回） | 前端小组修客户端前先看 |
| **`docs/mysql-backend.md`** | **轻舟 v0.7 数据库抽象层 与 MySQL 后端接入**：上游 DB 抽象层架构 · 升级与适配（含**重打框架本地补丁**、`build.ps1` 排除清单对齐）· **端到端实测已跑通**（本机 MariaDB 11.4.13）· ⚠ **切框架 `RbacStore` 会回归 N-29（`admin123` 公开默认口令），必须先处理** · admin 切换清单与环境前提 · **§十二 club-server 侧的做法与前提** | 想用 MySQL 替掉文件存储前看 |
| **`docs/club-server-mysql-assessment.md`** | **club-server 数据层迁 MySQL**：原文是 2026-09-19 的**可行性评估**（结论"现在不迁"），**2026-09-20 已按其中的路线 B 实做并落地** —— 顶部有「已迁」结论与逐条做法；正文的现状量化（`store.cj` 1422 行 / 51 处全局锁 / 218 处表访问 / 77 处落盘 / 507 条单测对着内存 Store）、框架 `DbBackend` 的能力缺口、**上游 MySQL 路径字符串拼 SQL 的注入风险**、三条候选路线都保留，便于对照"当时为什么这么判断" | 有人提"club-server 也用 MySQL"时先看这个 |
| ~~`docs/qingzhou-upstream-issues.md`~~ | **已删除（2026-10-04）**：原本是给轻舟团队的待改进清单（外部使用方反馈）。**反馈已闭环**——上游 v0.12.0 的 CHANGELOG **直接引用了本清单的条目号**，确认修复 A-1 / A-2 / A-3 / A-4 / A-5 / A-7 / B-1 / B-2 共 8 条；C-3、C-6 亦已修。其余条目（如 C-8 字符集）在**本项**的处置记录见 `docs/API-NOTES.md`。<br>要看原文：`git log --diff-filter=D -- docs/qingzhou-upstream-issues.md` | 想知道"当年给上游提过什么"时用 git 找回 |
| **`docs/capacity-baseline.md`** | **容量基准与四项性能改造**：可复现的实测矩阵（改造前/后 × 1000/3000）、每项改造的真实收益与**没测出收益的地方**、容量阈值 | 想知道"近千人扛不扛得住""哪项优化真有用" |
| `docs/deploy-windows-verify.md` | 部署与验证步骤、目标配置基线 | 部署时看 |
| **`docs/d-member-module.md`** | **客户端 D 模块（成员名录 P06 + 成员详情 P07）交付说明**：功能概览 · 需求逐项核对（已实现/未实现+原因）· 权限矩阵 · 逐项验证步骤（含期望文字）· 待决策清单。**附带记录本次修掉的全工程编译阻塞（`MemberApi.ets` 重复 `disable()`）** | 看/改「名录」「成员详情」两页时；以及**任何人构建客户端失败时** |
| *（对外材料已移出仓库）* | 仓颉运行时缺陷报告 + Issue 稿件 + 最小复现（`repro.cj`）、轻舟 TLS 需求与实测 —— 都在仓库上层 `cangjie-upstream\`（完整路径 `E:\harmonyOS\cangjie-upstream\`） | 追溯上游问题来源时 |

---

## 环境事实（本机已验证）

| 项 | 位置 / 值 |
| --- | --- |
| 编译器 | **1.2.0** (cjnative, x86_64-w64-mingw32)。`build.ps1` 是**按版本探测**的：本机实测选到 `C:\Users\<用户>\.cjenv\sdks\1.2.0\cangjie`（cjenv 安装的 1.2.0）。⚠ 以前这里写"项目内 SDK 解压目录 `.tools/cangjie-1.2.0/cangjie`" —— **该目录在本检出里不存在**；而 `PATH` 上的 `cjc` 是 **1.1.3**，`build.ps1` 正是靠版本比对**优先挑 1.2.0**、不会被旧 shim 抢走（2026-10-04 据实更正）。换机器时用 `-CangjieHome <目录>` 或 `CANGJIE_HOME` 显式指定 |
| stdx | **1.1.3.1**。注意 `stdx` 与编译器是**两个包**，要分别安装；本机在 `E:\cangjie\stdx\windows_x86_64_cjnative\static\stdx` |
| 轻舟框架 | **已内置在本仓库**：`server/third_party/qingzhou`，上游 **v0.12.0 之后的 HEAD / `3d6c1a3635f9aa4a191cd6aa5ede8bf3a387b753`**（最近标签 v0.12.0 = `871ff16`），内容由 `MANIFEST.sha256` 校验，构建脚本每次构建都验。快照含连接池、健康检查、生命周期钩子、路由增强、结构化日志，以及 v0.11/v0.12 新增的**出站 HTTPS/TLS + 重试退避、出站并发闸门、容错 JSON 提取、`JsonSchema` 校验、日志脱敏、参数化查询构建器**；见 `server/third_party/qingzhou/PROVENANCE.md` |
| OpenSSL 3 | **不随仓库提交**（6.5 MB 二进制）：`build.ps1` 按 **`third_party/qingzhou/deps/openssl` → `-OpenSslDir` → Git for Windows 的 `mingw64\bin`** 顺序找，并打印实际来源；详见 `server/third_party/qingzhou/deps/openssl/README.md` |
| 仓颉运行时 | `D:\Cangjie\runtime\lib\windows_x86_64_cjnative` |
| openssl CLI | `D:\Program Files\Git\usr\bin\openssl.exe`（生成证书、TLS 验证用） |
| **DevEco Studio** | **6.1.1.300**（`D:\DevEco Studio`）—— 自带 SDK **API 24 / 6.1.1.125**、hvigor 6.24.4、JBR **21**。构建客户端见 `docs/client-build.md` |

### 八条最容易踩的坑

1. **4 个 DLL 必须与 exe 同目录**：`libcangjie-runtime.dll`、`libboundscheck.dll`、`libcrypto-3-x64.dll`、`libssl-3-x64.dll`。缺 OpenSSL 两个时**编译期无警告**，运行时才报错。
2. **`cwd` 必须是 exe 所在目录**，否则**审计日志目录**与证书读不到，会出现"假失败 + 假通过"。业务数据已不在文件里（2026-09-20 起在 MySQL）。
3. **同包编译会撞名字**：我们与轻舟同一个 `package qingzhou`，框架已占用 `pad2`、`verifyPassword`、`randomHex`、`bodyStr` 等。加顶层函数前先查 `docs/API-NOTES.md`。
4. **轻舟新版的 `store.cj` / `rbac.cj` 依赖外部 CangDB**（`gitcode.com/BIT-FSSLab/CangDB` 已开源，但我们验证到的仓颉 1.0.5 版本与 cjc 1.1.3 不兼容：编译通过、运行超时）。我们仍用适配版代替：`server/src/fw_rbac_store.cj`（数据层换成文件存储）+ `fw_rbac.cj`（响应用我们的错误格式），`build.ps1` 里排除框架原版；**轻舟自带的后台（`-Target admin`）起初也复用同一个 `fw_rbac_store.cj` 把数据落到 JSON 文件**（2026-09-19 起运维台已改用框架 `store.cj` + MySQL，见 `docs/mysql-backend.md`）。**⚠ 2026-09-20 起 club-server 的持久化也是 MySQL**（`server/src/mysql_store.cj`，两条构建都编框架 `db_mysql.cj`、都链 MariaDB 驱动）。**升级轻舟后必须重跑全部测试（单测/冒烟/TLS/契约/后台端到端/运维页端到端）。**
5. **证书必须带 SAN**：现代客户端完全忽略 CN，只看 `subjectAltName`。按真实公网 IP 重签后再部署。
6. **私钥绝不入库**：`server/certs` 与 `server/dist` 都已在 `.gitignore`；用 `git check-ignore -v <路径>` 自检。
7. **club-server 需要一台可连的 MySQL**（2026-09-20 起）：没有数据库时它**起不来**（这是有意的：
   宁可起不来，也不带着空库跑，否则下一次落盘会把真实数据整体覆盖）。库与表都自动建。
   **编译前**还要先跑一次 `build-mysql-driver.ps1` 生成驱动产物（不入库）。
8. **MySQL 的会话字符集必须显式设成 utf8mb4**（2026-10-04 修过一次 P0，值得记住这一类）：
   内置驱动的握手把连接字符集**写死成 utf8mb3（id 33）**，而库与 9 张表都是 utf8mb4，框架也没有
   字符集开关 —— 于是**一个 emoji 就能让之后所有写入持续 500**（读还正常，读的是内存）。
   现在 `MysqlStore` 建连后固定发 `SET NAMES utf8mb4`，并有一条 4 字节字符的回归断言钉着。
   **换驱动 / 换客户端 / 换框架快照时，先确认这条还在**（详见 `docs/mysql-backend.md` 的字符集一节）。

> 完整的 40 余条踩坑记录（含 PowerShell 5.1 的七个坑、cjenv 切换 SDK 打断构建、本次的字符集坑等）见 **`docs/API-NOTES.md` 第 3 节**。

---

## 未决事项

| # | 事项 | 卡住什么 |
| --- | --- | --- |
| 1 | **服务器步骤 0 未跑**：架构是否 x64、公网 IP、可用端口、防火墙 + 云安全组 | 卡 M5 的公网部署验证 |
| 2 | **CangDB 已开源但 1.0.5 与 cjc 1.1.3 不兼容**（编译通过、运行超时），故仍以文件存储适配层代替。**但它只影响 RBAC 那一层**：运维台（`-Target admin`）2026-09-19 起已改用框架 `store.cj` + MySQL；**club-server 2026-09-20 起持久化也在 MySQL**（`src/mysql_store.cj`，不碰框架 `store.cj`/`rbac.cj`，也不碰 CangDB）。等 CangDB 有与 cjc 1.1.3 兼容的版本后，再考虑替换回上游实现 | **已知限制 / 不阻塞** |
| 3 | 给轻舟的需求文档已更正（去掉 Linux 前提） | 需补发一份更正 |
| 4 | 忘记密码：v1 由会长重置，不做自助找回 | 已定 |
| 5 | 服务器可用期限、备份交接人（至少两人） | 需向老师确认 |
| 6 | 鸿蒙侧载分发（AGC 内部测试轨道、签名证书） | 流程耗时可能超过开发本身，**建议尽早启动** |
| 7 | **客户端待办（2026-10-04 据实更正）**：① **签名未配**（产出 `entry-default-unsigned.hap`，装不上设备）—— 仍成立；② ~~只做了 3 / 11 页、缺首页「我的任务」~~ **已不成立**：现有 **21 个页面文件** + **11 条登记路由**，首页「我的任务」已在；③ ~~页面全是假数据、未接任何接口~~ **已不成立**：页面已在调真实接口。**当前真实待办**见下方「已知缺陷与未修项」 | 签名/侧载流程见 `docs/client-build.md`；⚠ 该文档正文**已滞后**（最后更新 2026-09-14），状态以本节为准 |
| 8 | ~~轻舟后台的成功响应也可能带 HTTP 404~~ | ✅ **已在我们的入口修掉**（`src/ops/admin_main.cj` 的 `statusNormalizer()`；内置框架未动）。见 `API-NOTES` 坑 34 |
| 9 | **运维账号的口令要换**：本机开发数据目录里建的是 `13800000009 / admin123`（按甲方指定的口令） | 生产上必须换强口令（`club-server init-ops` 可重设）；它等价于"会长权限减移交" |
| 10 | ~~客户端不认识 `ops` 角色~~ | ✅ **已按"隐藏系统账号"解决（服务端侧）**：`GET /members` 名录与 `?q=` 搜索都**不返回** `role = ops` 的账号（它不是社团成员），客户端不需要任何改动。要看/管这个账号用运维台（它直连社团库，仍然显示「运维」）。按 id 查详情仍可达（是隐藏不是丢失，smoke 有闸门盯着） |
| 12 | **club-server 重新需要一台 MySQL**（2026-09-20 起，用户的明确要求） | 部署面从"拷 exe + 4 个 DLL + 一个目录"变成"上述 **+ 一台可连的 MySQL/MariaDB**"。已同步进 `docs/local-deploy.md` / `README.md` / `docs/mysql-backend.md`；`smoke.ps1` / `tls-check.ps1` / `client-contract-check.ps1` / `ops-check.ps1` 都会**显式探测并按失败处理**（不静默跳过）。**"跨实例共享同一份数据"仍然不成立**：内存 Store 是每进程一份、没有失效通知（路线 B 的已知代价，见评估文档 §七） |
| 11 | **改运维页前端需要 Node** | `dist` 随仓库提交，部署机不需要 Node；改 `server\admin-web\src` 的人要 `npm install && npm run build`（本机用 DevEco 自带 node 18 + npm 10 实测通过） |

---

## 已知缺陷与未修项（2026-10-04 盘点）

> 这一节是**已经复现或已经定位到代码行**的缺陷清单，不是"愿望清单"。每条都给了落点，接手的人可以顺着看。
> 打 ✅ 的三条是 **2026-10-04 本轮已修**的（留在这里是为了让"什么时候修过、怎么修的"可追溯）。
> 详细的评审历史仍在 `docs/code-review.md`；本轮新增的三条也已写进 `docs/mysql-backend.md` 与 `docs/API-NOTES.md`。

### 服务端

| # | 级别 | 缺陷 | 落点 | 状态 |
| --- | --- | --- | --- | --- |
| **S-1** | **P0** | **一个 4 字节 UTF-8 字符（emoji）就让之后所有写入持续 500**，而读请求仍返回 200（读的是未落盘的内存）。根因：驱动握手把会话字符集写死成 utf8mb3（id 33），库与 9 张表却是 utf8mb4，全仓又没有任何 `SET NAMES`。实测建 4 条只提交 1 行；触发点无需认证（注册姓名） | `third_party/mariadb-driver/src/protocol/client_handshake_response.cj:156`（`setCharset(33)`）、`server/src/mysql_store.cj` 构造 | ✅ **已修**：建连后 `SET NAMES utf8mb4`；`tests.cj` 的 MySQL 往返加 4 字节断言（回退即红，已验证） |
| **S-2** | **P1** | MySQL 刷盘**不持 `s.lock`** 就遍历内存 HashMap（只持 `save_lock`），与 handler 的写入并发 → 撕裂快照还可能被记成"已落盘基准" | `store_persistence.cj`（原 `writeSnapshot` → `writeDbToMysql` → `snapshotOf`） | ✅ **已修**：`storeSnapshot`（锁内）拷好 → `Snapshot.entities` → `writeDbToMysql(s, cur)`；文件后端未动 |
| **S-3** | **P1** | 7 套测试脚本默认不带 `--skip-ssl` 且把客户端 stderr 丢进 NUL → 在客户端 TLS/SSPI 握手失败的机器上**误报「连不上 MySQL」**，一条断言都跑不了 | `tests/mysql-common.ps1`、`tests/admin-check.ps1`、`tests/ops-check.ps1` | ✅ **已修**：默认 `--skip-ssl`（`CLUB_MYSQL_USE_SSL=1` 可关）+ 失败时打印客户端原文 |
| S-4 | P1 | **类型不对的可选字段被静默忽略**：`jsonGetStr/Int64` 对"键不存在"和"类型不对"都返回 `None`，于是 `{"title":123}` → 200 但什么都没改；更糟的是**数值型 `due_at` 会静默清空截止时间** | `jsonw.cj` 请求取参层、`h_task.cj` / `h_plan.cj` / `h_member.cj` / `h_dept.cj` | ✅ **已修**：存在但类型错误的字段统一返回 `VALIDATION_FAILED`；缺失或显式 `null` 仍按原契约处理，并补了回归测试 |
| S-5 | P2 | `GET /members?status=pending\|disabled` 任何 active 成员都能用来枚举"申请人 / 已退出者" | `h_member.cj` | ⬜ 未修（**产品决策**，评审文档已记） |
| S-6 | P2 | `reset-password` 缺 compare-and-set：两人同时重置同一成员时，先返回 200 的那个临时口令会被覆盖 | `h_secret.cj` | ⬜ 未修（三种取舍都不便宜，**有意接受**） |
| S-7 | P2 | `/tasks/mine` 无分页；列表在分页前做全量投影 | `h_task.cj` | ⬜ 未修（属"等 CangDB"那一类） |
| S-8 | P2 | `sortedTasksByDue` 的"无截止"哨兵 `9e12` 落在**可达的 `due_at` 区间内**（`parseIso` 接受到 9999 年 ≈ `2.53e14`）→ "9999-12-31"这种写法会排到无截止任务**之后**，与 `api-design.md` 相反 | `store_queries.cj` | ✅ **已修**：改为按“有截止 / 无截止、截止时间、任务 id”直接比较，不再使用有限时间哨兵；补了 9999 年回归测试 |
| S-9 | P2 | `handlePlanMove` 换父分支不清子课题的 `dept_id`（当前无可观测错误） | `h_plan.cj` | ⬜ 未修（评审文档记为清理项） |
| S-10 | P2 | `Task.source` 是死字段（落盘有、接口不读不写） | `store.cj` | ⬜ 未修（记为清理项） |
| S-11 | 硬化 | **会话令牌/口令盐/临时口令全部来自 `std.random.Random()`**（30 天有效的令牌）；碰撞风险已被实测排除，但"是否密码学不可预测"**仍未定论** | `ids.cj:22-31`、`auth.cj` | ⬜ 未定论（建议换 `stdx.crypto` 随机源） |
| S-12 | P2 | 运维台仍监听 `0.0.0.0`，只有防火墙提示、没有代码级限制 | `src/ops/admin_main.cj` | ⬜ 未修 |
| S-13 | P2 | 开发用运维口令 `13800000009 / admin123` 写在文档里 | 本文件未决事项 #9、`docs/HANDOFF.md` | ⬜ 未修（已标注"生产必须换"） |
| S-14 | 注意 | `storeSave` 在持有 `s.lock` 的同时取 `save_lock`；当年"等接上数据库一并解决"的延期理由**已经成立**——现在这把锁是**跨一次网络事务**持有的 | `store_persistence.cj` | ⬜ 未动（本轮只改了"读内存表"的锁范围，未改加锁顺序，以免引入锁序反转） |

### 客户端

> `docs/client-bug-handover.md` 的 C-1…C-6、C-8 经复核**均已修复**（阻塞原因显示、截断时间/逾期、重置密码走 `can()`、刷新入口、收起文案、防重复提交、深链 http）。下面是**仍然存在**的。

| # | 级别 | 缺陷 | 落点 | 状态 |
| --- | --- | --- | --- | --- |
| C-7 | P2 | `SplashPage` / `PendingWaitPage` 是**死代码**：既未登记路由、也无任何引用（且 `SplashPage` 跳向未登记的 `pages/PendingWaitPage`）；其 `ApiRequestError` 分支永远不会命中（`HttpClient` 从不 throw） | `pages/SplashPage.ets`、`pages/PendingWaitPage.ets`、`main_pages.json` | ⬜ **未修**（已记入交接单） |
| C-9 | P1 | **任务列表永远只有第 1 页**：写死 `{page:1,size:50}`，界面却硬编码「第 1 / 1 页」；「未完成」还是在这 50 条上做本地过滤 → 超过 50 条的任务不可达 | `pages/TaskListPage.ets:56,81-86,194` | ⬜ **未修**（同仓 `MemberListPage` 有"循环拉全"的正确写法可照抄） |
| C-10 | P1 | **会长移交 / 重置候选只取前 50 人**：`memberApi.list()` 不带分页，服务端默认 `size=50` → 活跃成员超过 50 时**无法移交给第 51 名以后的人** | `pages/ManagePage.ets:1181` | ⬜ **未修** |
| C-11 | P1 | **日历对账会把事件描述清空**：`reconcile` 用 `''` 覆盖 `description`，而数据源 `POST /tasks/lookup` 只返回 4 个字段（无 `title`/`desc`） | `util/CalendarSync.ets:335`、`h_task.cj:804-808` | ⬜ **未修** |
| C-12 | P2 | `HttpClient` 的 GET 并发去重只按 `path` 记忆、且 `SessionStore.clearAll()` 不清它 → 重登/换服务器后可能复用上一位用户的响应 | `api/HttpClient.ets:90,280-293` | ⬜ 未修（硬化项；复现依赖时序） |

### 仓库 / 构建

| # | 级别 | 缺陷 | 落点 | 状态 |
| --- | --- | --- | --- | --- |
| B-1 | P2 | `build.ps1 -Target admin` 用**合并式** `Copy-Item` 拷前端产物，从不清理目标目录 → 废弃的 hash 产物在 `dist` 里越堆越多（**现已提交 2 个 JS + 2 个 CSS，而 `index.html` 只引用其中一对**） | `build.ps1:371-372`、`server/admin-web/dist` | ⬜ 未修 |
| B-2 | P2 | 文档滞后：`docs/client-build.md` 停在 2026-09-14（客户端"3 页 / 假数据"的说法即源于此）；本文件此前也有单测 507、`src/` 23 个文件、`.tools` SDK 路径等已过期的数字 | `docs/client-build.md` 等 | 🟡 **本文件 2026-10-04 已更正**；其余文档见各文件顶部说明 |

---

## 设计原则（违反会导致返工）

| 原则 | 具体体现 |
| --- | --- |
| **同一事实只存一份** | 删了 `Department.lead_id`；课题不设 status；逾期不设状态；`Plan.dept_id` 只在顶层 |
| **能从事实推导的就不存** | 逾期由 `due_at` 算；课题进度由整棵子树的任务聚合 |
| **绝不级联删除** | 删课题子节点上提；任务软删除 |
| **权限判定收敛到一个函数** | `can(member, action, target)`；**禁止在每个 handler 里手写 if** |
| **服务端权威** | `updated_at`、逾期、分组、`is_overdue` 全部服务端生成 |
