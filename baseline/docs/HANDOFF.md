# 项目交接说明 · 社团管理工具

> 📁 **交接说明（接手项目先看）** ｜ 本文件：`HANDOFF.md` ｜ [全部文档目录](README.md)

> **下个对话从这里开始。** 本文自包含——读完它 + 第 3 节的文档，即可直接接手。

- 更新时间：**2026-10-04**
- 工作区：`E:\harmonyOS\cangjie_web`
- 设计阶段：**已完成，接口冻结**（40 / 40，2026-09-16 新增招募链接公开解析 +1）
- **当前阶段：服务端全部完成并验证**（M1–M18，含四轮独立代码评审修复 + 轻舟升级/CangDB 适配 + 容量基准与四项性能改造；此后另有 **2026-09-20 的 MySQL 持久化迁移** 与 **2026-10-04 的三条修复**：utf8mb4 会话字符集 / 落盘快照锁范围 / 测试夹具 `--skip-ssl`）；**客户端 ArkTS 已完成一轮真实接入**（`entry/src/main/ets/pages/` **21 个页面文件**、`main_pages.json` 注册 **11 个路由页**，`api/`·`store/`·`util/` 全套；`Index.ets` 已调 `AuthApi.me()`，令牌认证 + 离线 outbox + 系统日历同步 + 邀请深链均已落地），**HAP 仍未签名** —— ⚠ `client-build.md` 停在 2026-09-14、已落后客户端代码 15 天，动客户端前以代码 + `README.md`「已知缺陷与未修项」为准
- 现行测试基线（2026-10-06 复验）：**单测 595（带 DSN 648）/ 冒烟 440 / 契约 37 / 会长姓名 45 / 后台 38 / 运维页 82 / 前端逻辑 17，FAIL 0**；**TLS 关卡 4 通过 / 3 失败** —— 那 3 条是**既有环境性失败**（`server/certs` 被 gitignore、本地证书 2026-09-17；用未改动的旧二进制同样复现），**不是回归**（跑法见 `README.md` 顶部；容量基准 `server/tests/bench.ps1` 按需跑，见 `capacity-baseline.md`）

> §8、§9 是**设计阶段**给出的开工建议与待问问题，现已全部执行完，保留作方法论参考；
> §11 记录服务端从 M1 到 M11 的实际进展，**数字以那里的最新一条为准**。

---

## 1. 项目一句话

社团内部管理工具。解决两个问题：**① 社团里有哪些人 ② 每件事由谁负责、做到什么程度。**

- 客户端：鸿蒙 App（**ArkTS**）
- 服务端：仓颉 1.2.0 + 轻舟 v0.12.0，部署在 Windows 云服务器
- 第一版（v1）目标：社团内部试用 2 周

---

## 2. 技术栈（全部已冻结，不要再改）

| 项 | 决定 |
| --- | --- |
| 客户端 | 鸿蒙 App，**ArkTS**（2026-09-14 定；此前仓颉方案已退役） |
| 服务端 | **仓颉 1.2.0 + 轻舟 v0.12.0（QingZhou）框架** |
| 服务器 | **Windows**（与开发机同平台） |
| 部署 | **本机编译 → 拷制品**，服务器不装编译器 |
| 持久化 | **MySQL**（2026-09-20 起，`server/src/mysql_store.cj`）；进程内 Store 只是内存镜像，**不再是 JSON 文件落盘**（`--data-dir` 如今只剩 `audit.log`） |
| HTTPS | **轻舟原生 TLS**（不使用 Nginx） |
| 提醒 | 系统日历（**客户端本地机制**，服务端不存日历字段） |

### 实测环境事实（可直接用）

| 项 | 位置 / 值 |
| --- | --- |
| 编译器 | **1.2.0** (cjnative)。本机由 **cjenv** 装在 `C:\Users\<用户>\.cjenv\sdks\1.2.0\cangjie`；`build.ps1` **按版本**自动探测（`PATH` 上的 1.1.3 不会被选中）。⚠ **本 checkout 没有项目内 SDK**：`.tools\cangjie-1.2.0\cangjie` 已不存在（2026-10-04 核对） |
| stdx | **1.1.3.1**（与编译器是**两个包**，单独安装）。本机在 `E:\cangjie\stdx\windows_x86_64_cjnative\static\stdx` |
| 轻舟框架 | **已内置在本仓库**：`server\third_party\qingzhou`（上游 **v0.12.0 之后的 HEAD / `3d6c1a36`**；内容由 `MANIFEST.sha256` 校验，`build.ps1` 每次构建都会验），见 `third_party\qingzhou\PROVENANCE.md` |
| OpenSSL 3 | **不随仓库提交**（6.5 MB 二进制）：`build.ps1` 按 **`third_party\qingzhou\deps\openssl` → `-OpenSslDir` → Git for Windows 的 `mingw64\bin`** 顺序找并打印来源（见该目录 `README.md`） |
| 仓颉运行时 | `D:\Cangjie\runtime\lib\windows_x86_64_cjnative` |
| **DevEco Studio** | **6.1.1.300** @ `D:\DevEco Studio`：自带 SDK **API 24 / 6.1.1.125**、hvigor **6.24.4**、JBR **21**（构建客户端必须用它的 JBR，原因见 `client-build.md`） |

### 本机验证过的编译命令

**日常构建用 `server\build.ps1`**（它已处理好轻舟的排除项与我们的源文件；`server\build.cmd` 是等价包装，免记 `-ExecutionPolicy Bypass`）：

```powershell
cd server
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1   # -> build\club-server.exe + 4 个 DLL
```

脚本内部做的事（要手写时照此，**排除列表必须与脚本一致**）：

```powershell
# ⚠ 2026-10-04 更正：下面这份是**按当前 build.ps1 重写的**。旧版本漏了两类东西，
#   照抄会编不过：① 还要排除 db_cangdb.cj / db_factory.cj / jsonx_edge_test.cj；
#   ② 数据层是 MySQL，必须链上 MariaDB 驱动产物（先跑一次 build-mysql-driver.ps1）。
$CJC  = "<仓颉 SDK>\bin\cjc.exe"          # build.ps1 会自动探测（按版本优先 1.2.0）
$STDX = "E:\cangjie\stdx\windows_x86_64_cjnative\static\stdx"
$FW   = "<仓库>\server\third_party\qingzhou"   # 已内置；上游 commit 见其中的 UPSTREAM_COMMIT
$DRV  = "<仓库>\server\build\mysql-driver"     # build-mysql-driver.ps1 的产物（不入库）
$libs = (Get-ChildItem "$STDX\libstdx*.a" | ForEach-Object { "-l:$($_.Name)" })
# 轻舟：排除自带入口/自测、依赖 CangDB 的 store.cj / rbac.cj（改用我们的适配版），以及 CangDB 那几张
$fw   = Get-ChildItem "$FW\src\*.cj" |
        Where-Object { $_.Name -notin @('main.cj', 'unit_tests.cj', 'manual_runner.cj', 'store.cj',
                                        'rbac.cj', 'db_cangdb.cj', 'db_factory.cj', 'jsonx_edge_test.cj') } |
        ForEach-Object { $_.FullName }
$src  = Get-ChildItem "<仓库>\server\src\*.cj" | ForEach-Object { $_.FullName }

& $CJC @fw @src --import-path $STDX -L $STDX @libs `
       --import-path $DRV -L $DRV `
       -l:mariadb.cdbc -l:mariadb.connection -l:mariadb.protocol -lcrypt32 -Woff unused `
       -o "build\club-server.exe"
```

> ⚠️ 少排除一个就会报 `can not find package 'cangdb'`，或撞上框架自带的 `main` / 单测符号；
> **漏掉 `--import-path $DRV` 与那三个 `-l:mariadb.*` 会报找不到驱动**。
> 所以这几行**只作原理说明**：真要编译请用 `build.ps1`（它自己会校验这些）。

### 后台管理界面 + 「社团管理」运维页（`build.ps1 -Target admin`）

后台这份现在有**两个页面**：上游那套（仪表盘 / 用户管理，管**后台自己的账号**），
和我们加的 **「社团管理」运维页 `/club`**（管**社团的真实数据**）。

```powershell
cd server
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1 -Target admin   # -> build\admin\admin.exe
cd build\admin
.\admin.exe                                                                     # http://127.0.0.1:3000/
# 登录框填「运维账号」：手机号 + 运维口令（club-server init-ops 建的那个）—— 写操作即该身份
# 运维页 http://127.0.0.1:3000/club
powershell -NoProfile -ExecutionPolicy Bypass -File ..\tests\admin-check.ps1    # 后台自身 38 项
powershell -NoProfile -ExecutionPolicy Bypass -File ..\tests\ops-check.ps1      # 运维页（含运维账号登录 / 写路径）82 项
node ..\tests\web-logic-check.mjs                                              # 前端逻辑 17 项（401 处理，Node 直接跑）
cd ..\.. ; powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\init-name-check.ps1   # init-admin 会长姓名选项 45 项
```

- **入口是我们自己的** `server\src\ops\admin_main.cj`（不是上游 `examples\admin.cj`；后者留在快照里逐字节原样、只作对照）。
  它保留上游那套后台路由，另外加 `/api/club/**`，并顺手修掉上游"成功响应也可能带 404"的状态码问题
  （链尾 `statusNormalizer()` 按 body 的 `code` 回写状态；**内置框架一行未改**）。
- **运维页的两条链路**（别混淆）：
  **读** = 后台进程**只读**社团库（**MySQL**：`admin.env` 的 `club_mysql_db`，与 `mysql_*` 同实例、不同库）→ club-server 没起也能看；
  **写** = 后台用 **admin.env 里的专用运维账号**（club-server 的 `role = ops`）换一个令牌交给页面，
  页面直连 club-server 的真实 API（`/api/v1/**`，CORS 已开）→ club-server 始终是唯一写入者，
  权限（N-7）、两阶段赋值（N-15）、部门一致性（N-18）全部仍然生效。
  **后台进程不会写社团库** —— 写路径一律转给 club-server（它是唯一写入者）；让两个进程各写各的会绕过权限、两阶段赋值与部门一致性校验，等于静默改坏数据。
- **运维不该由会长执行（2026-09-16 定）**：运维人员**只登录后台一次** —— 2026-09-17 起
  **直接用 club-server 的运维账号登录即可**（登录框填手机号 + 运维口令，无需改任何配置）；
  也可以用后台账号 `admin`（口令由 `admin.exe` 首次启动随机生成、打印一次并写入
  `build\admin\admin.env` —— 不再是写死的 `admin123`，见 N-29），
  页面上不出现任何社团账号口令。club-server 侧的运维身份是新增的内置 `ops` 档：
  权限 = **除「移交会长」外与会长同权**（能做部门增删改、换注册口令、重置会长的口令），
  **不可由 API 分配**，只能本机命令建：
  `club-server init-ops <手机号> <口令> [DSN]` / 退役 `club-server retire-ops <手机号> [DSN]`
  （第 3 个位置参数 **2026-09-20 起是 DSN**，不再是数据目录 —— 旧写法会被明确拒绝）。
  → club-server 的 `audit.log` 里 **actor 是"运维"**，与会长做的操作分得清清楚楚。
- 运维页能做的写操作：分配/改派、停用、重置口令（含会长的）、换注册口令、**部门增删改**、
  优雅停服 club-server；**移交会长是会长专属**（按钮会明确提示，服务端也 403）。
- **只读视图是白名单**：`src/ops/club_view.cj` 不复用 `store.cj` 的 `memberToJson`（那个会把
  `pw_salt/pw_hash/pw_iter` 一起写出来），运维接口里**不含任何口令材料** ——
  `tests/ops-check.ps1` 有专门一条闸门盯着这点。
- 前端在 `server\admin-web`（上游版本 + `views/Club.vue`），`dist` 随仓库提交；
  改前端需要 Node：`cd server\admin-web ; npm install ; npm run build`。
- 产物自包含：`admin.exe` + `admin-web\dist` + `admin.env`（首建生成随机 `secret`，不覆盖）+ 4 个 DLL；
  **cwd 必须是 `build\admin`**（上游按相对路径读配置与前端）。
- 后台账号 `admin`（角色 1）、`user`（角色 2）；**口令不写死**（N-29）：`admin.exe` 首次启动
  （建库）时随机生成一对（各 16 个十六进制字符），控制台打印一次并写入 `build\admin\admin.env`
  的 `admin_pass` / `user_pass`；库里若仍是老的公开默认口令，启动会醒目告警。
  `/api/club/**` **只放给角色 1**
  （`user` 拿到 403）。⚠️ 这两条是**轻舟 RBAC 那套口令**（现在也在 **MySQL** 里，库名见 `admin.env` 的 `mysql_db`），
  与 club-server 的账号（PBKDF2，存在 **club-server 那个库**里，见 `club_mysql_db`）**不是一套**，不能互用 ——
  运维人员用前者，写操作的身份是后者的 `ops` 账号。
- 详见 `docs\API-NOTES.md`「坑 34」（状态码）与「坑 36」（关停回执竞态，已修）。

#### 运维账号（`ops`）操作手册

运维人员**只登录后台**（**直接用运维账号登录**：手机号 + 运维口令；也可用后台账号，口令见 `build\admin\admin.env`）；club-server 侧的身份是**专用运维账号**（`role = ops`）。

| 要做什么 | 怎么做 |
| --- | --- |
| 建号 / 重设口令 | `cd server\build` → `..\club-server.exe init-ops <手机号> <口令> <DSN>`（第 3 个位置参数是 **DSN**，不再是数据目录；幂等，可重复执行来重设口令。本机开发库现在是 `13800000009 / admin123`）。⚠️ **必须在 club-server 未运行时执行** —— 它只在启动时把库读进内存一次，运行期别的进程改库它不知道：新账号登录恒 **401**，而运维页名录直读**库**、照样看得见它；已经起了就先停掉再起 |
| 让运维台能用它 | **最简单：直接用运维账号登录运维台**（登录框填手机号 + 运维口令，2026-09-17 起两种凭据都认）—— 不需要改任何配置文件。备选是让后台代持：把手机号/口令填进 `build\admin\admin.env` 的 `club_user` / `club_pass`（留空则运维页只能看不能改，页面会提示），⚠️ 改完**必须重启 `admin.exe`** —— 它只在启动时读一次 `admin.env` |
| 换人 / 退役 | `..\club-server.exe retire-ops <手机号> <DSN>`（第 2 个位置参数是 **DSN**；停用并作废其全部令牌；记录保留，审计仍可追溯） |
| 它能看到什么 | 除「移交会长」外与会长同权：成员处置 / 部门增删改 / 换注册口令 / 重置**会长**的口令 / 停服 |
| 它在哪儿可见 | **App 名录里看不到**（服务端过滤系统账号，客户端不需要为它改标签）；运维台 `/club` 的「成员名录」里能看到，标签「运维」；按 id 查详情仍可达 |
| 事后怎么追 | `<数据目录>/audit.log` 里 `actor=` 是运维账号 → `GET /api/club/audit`（运维台「审计日志」标签页） |

> 三条不变量（都有测试闸门）：**移交会长必须 403**（会长专属）、**`ops` 不能用 API 分配**
> （只能用 `init-ops`，否则会长能造出权限略高于自己的账号）、**会长也不能停用运维账号**（同档保护）。

---

## 3. 文档地图（写代码时按需查）

| 文档 | 用途 | 什么时候看 |
| --- | --- | --- |
| `v1-scope.md` | **范围基准** v0.10：11 页面、6 张表、19 条业务规则、权限矩阵 | 想知道"这个要不要做" |
| **`ui-spec-conformance-review.md`** | **UI 设计规格（13 页 PDF）↔ 服务端一致性审计**：15 条差异逐条带页码原话与 `文件:行` 证据、4 条设计稿自相矛盾、已对齐清单、处置口径 | **动服务端契约前先看这个**——尤其"任务/课题**读**范围已全社团、**写**范围未动"这条边界 |
| `api-design.md` | **完整接口设计** Part 1–6，40 个接口逐条定义 | **写服务端时全程对照** |
| `frontend-brief.md` | **前端对接精简版**：页面清单、通用约定、错误码、**5 件必知事项** | **客户端同事先看这个** |
| **`client-build.md`** | **客户端构建与现状**：ArkTS 构建命令、两个环境坑、迁移记录、剩余 TODO | **动客户端前先看这个** |
| **`client-bug-handover.md`** | **客户端 bug 交接单**：C-1…C-7 逐条（位置 · 根因 · 证据 · 修法 · 验收）+ 「核查过但不是 bug」清单 | **客户端同学改代码前必看** |
| ~~`client-integration-review{,-2,-3}.md`~~ | 历史的三轮接入适配检查 —— **2026-09-20 清理仓库时移除**（内容已被 `client-bug-handover.md` 取代；找回：`git log --diff-filter=D -- docs/client-integration-review.md`） | 只在追溯历史时看 |
| `deploy-windows-verify.md` | 部署与验证、目标配置基线 | 部署时看 |
| **`code-review.md`** | **代码评审报告（三轮）**：24 + 9 + 4 条，全部已修，附回退实测证据 | 想知道"哪些坑已经踩过、为什么这样写" |
| **`capacity-baseline.md`** | **容量基准与四项性能改造**：可复现基准（`server/tests/bench.ps1`）、改造前后实测矩阵、每项的**真实**收益与"没测出收益"的地方、容量阈值 | 被问"近千人扛不扛得住""这项优化值不值"时 |
| `README.md` | 仓库唯一入口：进度、目录结构、六条最容易踩的坑 | 第一次打开这个仓库时 |
| *（对外材料已移出仓库）* | 轻舟 TLS 实测与缺陷清单、仓颉运行时缺陷报告 —— 见上层 `cangjie-upstream\` | 追溯上游问题时看 |
| **`server-guide.md`** | **服务端**：构建/初始化/运行/测试、进度表、两条实现纪律 | **写服务端时先看** |
| **`local-deploy.md`** | **本机部署一页上手**（2026-09-16 全流程实测，2026-09-17 重写 §2 顺序）：体检 → 部署顺序 → HTTPS → 部署包 → 连客户端 → 备份 → 坑表 | **第一次上手时先看这个** |
| **`API-NOTES.md`** | **服务端**：编译期 API 事实清单 + **44 条**踩坑记录（编号到 44；本轮新增「驱动握手写死 utf8mb3」这条） | 加新函数前先查（避让框架同名符号） |

---

## 4. 已冻结的设计（摘要）

### 4.1 页面（11 个）

登录页 · **我的任务（首页）** · 任务列表 · 任务详情 · 课题列表（树） · 课题详情 · 成员名录 · 加入流程 · 待分配审批 · 管理 · 我的/个人设置

### 4.2 数据模型（6 张表）

| 表 | 关键字段 |
| --- | --- |
| `Department` | id / name / sort（**无 lead_id**） |
| `Member` | name / **phone（登录账号）** / password_hash / role / dept_id / **status**（`pending`/`active`/`disabled`） |
| `Plan` 课题 | title / **parent_id（自引用，多级）** / **owner_id 必填** / **dept_id 仅顶层** / due_at |
| `Task` | title / **owner_id 必填且唯一** / plan_id / status（4 档）/ **blocker** / due_at / **updated_at** / **deleted_at** |
| `RegisterConfig` | **code（明文）** / updated_by |
| `DeptInviteLink` | token / dept_id / enabled |

### 4.3 角色（固定 5 档，不可自定义）

`president` 会长 · `vice_president` 副会长 · `lead` 部长 · `vice_lead` 副部长 · `member` 成员

- **副会长 = 与会长同权**，但有明确例外（2026-09-14 定稿）：
  - 不能「移交会长」；
  - **不能更换注册口令**（仅可查看）、**不能部门增删改**（会长独占）；
  - **不能作用于与自己同权或更高权的人** —— 会长 / 副会长 / 部长一律适用
    （对会长而言"同权"只剩自己，所以会长也不能重置自己）。
    ⚠️ 覆盖 **重置密码 / 调部门改角色 / 移出社团 / 编辑姓名 / 审批分配（`assign`、`assign-batch`）** 五类动作；
    其中"重置密码"连**自己**也禁（该操作会作废目标全部令牌，对本人执行＝"响应 200、自己当场掉线"）。
    ⚠️ **客户端要能处理这类 `403 FORBIDDEN_ROLE`**（不是界面 bug，是同权保护）——
    具体见 `frontend-brief.md`。
- 组织固定 4 个：主席团 · 课题部 · 运营部 · 宣传部

### 4.4 接口（40 个）

按模块：认证 5 · 组织与成员 20 · 任务 8 · 课题 6（= 39 个业务接口）+ 运维 `/health`，共 40。**完整定义见 `api-design.md`。**

### 4.5 19 条业务规则中最关键的 8 条

1. **一个任务只能有一个负责人**（必填，不可置空）
2. **任务状态只有 4 档**（todo/doing/blocked/done），**不做进度百分比**
3. **进入 `blocked` 必须填 `blocker`** → 否则 `BLOCKER_REQUIRED`
4. **课题不设 status**，进度由整棵子树**递归聚合**
5. **删除课题 = 子节点上提一级**，绝不级联删除
6. **系统必须始终至少有一个 `president`**
7. **课题树禁止环形引用**（移动时校验，否则递归会拖垮服务）
8. **注册与授权分离**：注册只建账号（`pending`），角色全部由会长授予

---

## 5. 贯穿全项目的设计原则（**违反会导致返工**）

> 这五条是从设计过程中反复修正出来的，写代码时请自觉遵守。

| 原则 | 具体体现 |
| --- | --- |
| **同一事实只存一份** | 删了 `Department.lead_id`；课题不设 status；逾期不设状态；`Plan.dept_id` 只在顶层 |
| **能从事实推导的就不存** | 逾期由 `due_at` 算；课题进度由任务聚合 |
| **绝不级联删除** | 删课题上提；任务软删除 |
| **权限判定收敛到一个函数** | `can(member, action, target)`；**禁止在每个 handler 里手写 if** |
| **服务端权威** | `updated_at` 服务端生成；逾期/分组服务端算；客户端读 `permissions` 只用于画界面 |

---

## 6. 已验证的技术事实（**不要重复踩坑**）

| 事实 | 说明 |
| --- | --- |
| **TLS 可用（但关卡不是全绿）** | TLS 1.2/1.3 握手成功；TLS 1.0/1.1 **被服务端拒绝**（alert 70）；HTTPS 请求返回 200。⚠️ `tests/tls-check.ps1` 现行 **4 通过 / 3 失败** —— 那 3 条是**既有环境性失败**（`server/certs` 被 gitignore、本机证书是 2026-09-17 的旧件；未改动的旧二进制同样复现），**不是回归** |
| **测试基线（2026-10-06）** | 单测 **595**（带 DSN **648**）/ 冒烟 **440** / 契约 **37** / 会长姓名 **45** / 后台 **38** / 运维页 **82** / 前端逻辑 **17**，FAIL 0；**TLS 4 通过 / 3 失败（既有环境性，非回归）**（跑法见 `README.md`） |
| **容量（近千人规模）** | 1000 成员 + 1000 任务（0.51 MB 库）：列表 30 ms 级、写 30 ms 级、4 并发登录 0.9 s；3000 + 3000（1.54 MB）分别约 45 / 48 ms 与 0.98 s。单机单进程**够用**；重新设计的阈值是 `db.json > 20 MB` 或日均写数千次 —— 全部实测见 `capacity-baseline.md` |
| **部署文件集** | **制品 5 个 / 约 18.8 MB**：`club-server.exe` + `libcangjie-runtime.dll` + `libboundscheck.dll` + `libcrypto-3-x64.dll` + `libssl-3-x64.dll`（证书 2、启动脚本 2、`README.txt`、`dll-versions.txt` 另计 —— 整个 `dist\club-server\` 共 10 个文件）；由 `server/build-package.ps1` 生成 |
| **运行时只需 2 个 DLL** | runtime 目录有 51 个，只需 `libcangjie-runtime.dll` 与 `libboundscheck.dll` |

### ⚠️ 必须知道的坑

| 坑 | 表现 / 解法 |
| --- | --- |
| **轻舟新版 `store.cj` / `rbac.cj` 依赖 CangDB** | `import cangdb.*` 找不到包（CangDB 已开源，但其 1.0.5 版本与 cjc 1.1.3 不兼容：编译通过、运行超时）→ 仍用 `server/src/fw_rbac_store.cj`（文件存储）+ `fw_rbac.cj`（我们的错误格式）适配，`build.ps1` 排除框架原版 |
| **块注释里不能出现 `/*`** | 仓颉块注释可嵌套 → 会吞到文件末尾，报 `unterminated block comment` |
| **服务 `cwd` 必须是 exe 所在目录** | 数据目录与证书按相对路径读；`cwd` 不对会出现**假失败 + 假通过** |
| **crypto 缺 OpenSSL 3 时** | **编译期无警告**，运行时才 500；两个 DLL 必须与 exe 同目录 |
| **项目路径保持纯 ASCII** | 否则 `cjpm` 报 `Invalid utf8 byte sequence` |
| **用工具局部编辑 `.ps1` 会丢 BOM** | PS 5.1 按 ANSI 解析中文注释，报 `MissingEndCurlyBrace` / `意外的标记` 这类**看起来像手写语法错**的解析失败。改完 `.ps1` 必须确认 BOM 仍在（2026-09-14 已实证 4 次：`smoke.ps1` ×2、`build.ps1` ×2 —— 含**文件编辑工具**改中文注释那次） |
| **Windows 无 `std.runtime.Signal`** | 优雅关闭靠 `POST /admin/shutdown`，**该端点必须限制为本机可访问** |
| **部署别只拷 2 个 OpenSSL DLL** | 会启动即失败——还缺 `libcangjie-runtime.dll` |

### 本地补丁（DEF-1）—— **2026-09-14 已撤销**

上游 `141a735`「修复 TLS 验证报告缺陷（DEF-1~DEF-5）」已修同一处，且实现更可移植
（我们原来用的是 `GeneralPrivateKey`，备份在 `E:\cangjie\def1-local-patch.patch`）：

```diff
-        let key = PrivateKey.decodeFromPem(keyPem)
+        // RSAPrivateKey.decodeFromPem 在 stdx 1.0.5.1 与 1.1.3.1 均实现
+        let key = RSAPrivateKey.decodeFromPem(keyPem)
```

**已实测**：升到 `3ea387e`（2026-09-14）以及再升到 `e072980`（2026-09-16）后，`tests/tls-check.ps1` 都是 **22 / 0 全绿**，撤补丁不影响 TLS。

→ 结论：本项目现在**跑在轻舟上游原版上，对框架源码没有任何补丁**。
唯一的例外是 CangDB 适配，但那不是改框架源码，而是在我们自己仓库里提供替代实现（见 §11 与
`server/src/fw_rbac_store.cj` 的文件头）。

---

## 7. 未决事项

> **以 §11.4 的现行清单为准**（本节原表已合并过去，避免两处各写一份而逐渐不一致）。
> 仍未解决的仍是那几项：**服务器步骤 0**（架构 / 公网 IP / 端口 / 防火墙 + 云安全组）、
> **服务器可用期限与备份交接人**，以及**轻舟的 CangDB 依赖（CangDB 已开源，但其 1.0.5 版本与 cjc 1.1.3 不兼容：编译通过、运行超时）**。
> 已定：忘记密码不做自助找回（由管理员重置；会长也一样，见 §4.3 的口径）。

---

## 8. 开工建议顺序（设计阶段的历史建议，**已全部执行完**）

> 服务端与客户端可以并行，但**服务端先跑通全链路**能最快排除风险。

### 第 0 步（30 分钟，先做）：验证全链路
在 `E:\cangjie\qingzhou` 起一个最小服务 → 本机访问 → 打包 6 个文件 → 确认能跑。
（**历史记录**：当时框架还在仓库外；2026-09-15 起已内置到 `server\third_party\qingzhou`。）
**目的是把"编译→运行→部署"这条链路先打通**，再往里塞业务逻辑。

### 第 1 步：服务端骨架
- `Store` 接口 + 文件落盘实现（原子写：先写 `.tmp` 再 `rename`）
- 统一响应包装（`{ok, data}` / `{ok, error:{code,message,fields}}`）
- 错误码表（`api-design.md` §1.3）
- **权限函数 `can(member, action, target)`**（Part 1 §1.6）★ 先写它
- 认证中间件

### 第 2 步：按 Part 顺序实现接口
`Part 2 认证` → `Part 3 组织与成员` → `Part 4 任务` → `Part 5 课题`

### 第 3 步：客户端
按 `frontend-brief.md`。**注意两项需单独排期的客户端工作**：
- 日历同步机制（本地映射 + `POST /tasks/lookup` 比对）
- 自签证书信任配置（证书**必须带 SAN**，写 `IP:<公网IP>`）

---

## 9. 设计阶段列出的待问问题（**均已确认，保留备查**）

1. 从**服务端**还是**客户端**先写？
2. 服务器信息（架构 / 公网 IP / 可用端口）能否现在提供？
3. 是否需要我先搭出服务端骨架（Store + 权限函数 + 一个能跑通的最小端点）？

---

## 10. 一句话提醒

**接口已冻结**，`api-design.md` 是唯一权威。若实现中发现设计问题，**先改文档再改代码**，不要只改代码——否则前后端会各按各的记忆实现。

---

## 11. 服务端进展（2026-09-13 更新）

> 客户端由小组其他成员并行推进；本工作区当前只做服务端。
> 轻舟已于 2026-09-14 升级到 **`3ea387e`**（DEF-1 上游已修，本地补丁已撤），
> 2026-09-16 再升到 **`e072980`**（= 上游 HEAD，顺带纳入轻舟自带的**后台管理界面**）；
> 新版新增的 `src/store.cj` / `src/rbac.cj` 因依赖 CangDB（CangDB 已开源，但其 1.0.5 版本与 cjc 1.1.3 不兼容：编译通过、运行超时），仍由我们的适配版提供，
> `build.ps1` 中排除框架原版。

### 11.1 已完成并验证：M1 骨架 + M2 组织与成员

> 下表数字是 **M2 完成当时（2026-09-13）的快照**，保留用于对照；**当前基线见 §11.3 与 `README.md`**。

代码在 `server/src/`（**M2 当时 23 个源文件；2026-10-04 核对为 27 个**，多出 `limits.cj`、`mysql_store.cj` 等），详见 `server-guide.md`。
**接口进度（当时）24 / 39**（认证 5 + 组织与成员 19）；其余为任务 8、课题 6、运维 1（`/health` 已做）。

| 验证（2026-09-13 快照） | 结果 |
| --- | --- |
| 从零构建 | ✅ 通过 |
| 单测 `club-server.exe test` | ✅ **PASS 164 / FAIL 0** |
| 冒烟测试（真实 HTTP，`tests/smoke.ps1`） | ✅ **PASS 165 / FAIL 0** |
| 部署文件集 | exe 10.65 MB + 4 个 DLL ≈ **18.4 MB** |

- **M1**：构建链路 · Store 与原子落盘 · 统一响应/错误码 · 时间与时区（自实现历法，与 .NET 独立对拍）·
  **`can(member, action, target)`** · Part 2 认证 5 接口 · `/health` · `/admin/shutdown`（限本机）。
- **M2**：部门增删改（会长独占）· 成员名录/详情/编辑 · 移出社团 · 待分配与**批量分配**（逐条报告、部分成功）·
  **会长移交原子性**与「最后一个会长」保护 · 重置密码（含审计日志）· 注册口令查看/更换/轮换 · 招募链接。

**测试自己抓到的真 bug**（不是预置的，都是会真出事的那种）：
`Directory.create(recursive:true)` 在目录已存在时照样抛异常（会让第二次落盘直接崩）；
副会长被误允许更换注册口令；空目录 `remove` 抛异常导致单测中断。

### 11.2 本轮文档修订（先改文档再改代码）

| # | 修订 | 文档位置 |
| --- | --- | --- |
| 1 | **部门增删改改为会长独占**（原 §3.8/矩阵写副会长 ✅，与 §3.1/§6.1「DELETE 限会长」冲突） | `api-design` §3.1/§3.8/§6.1/§6.4 · `v1-scope` §3.4.3 |
| 2 | **会长只能由「移交会长」产生**：`assign` 与 `PATCH /members` 拒绝 `role=president` | `api-design` §3.3/§3.4 · `v1-scope` 规则 11 |
| 3 | `Member` 新增 **`dept_hint`** 字段（招募链接的部门预填） | `v1-scope` §5 · `api-design` §3.3 |
| 4 | 密码长度**按字节**校验的口径说明 | `api-design` §2.3 注 5 |
| 5 | `client_token` 幂等的落地范围：注册靠手机号唯一性挡住重复；幂等落在任务/课题创建类接口（M3/M4） | `api-design` §1.9 · `v1-scope` v0.11 说明 |
| 6 | `MEMBER_HAS_OPEN_TASKS` 的任务清单放 **`error.fields.tasks`**；该接口幂等 | `api-design` §3.2 |
| 7 | `DELETE /depts/{id}` 的 `DEPT_NOT_EMPTY` **也检查顶层课题**；已退出成员/历史任务的 `dept_id` 置 0 | `api-design` §3.1 |
| 8 | `DELETE /dept-invite-links/{token}` 是**停用**（`enabled=false`，记录保留）且**幂等** | `api-design` §3.7 |
| 9 | `PATCH /members/{id}` 字段级权限；待分配成员只接受 `name` | `api-design` §3.2 |
| 10 | `assign` 对 `disabled` 成员即"恢复"，成功后清空 `dept_hint` | `api-design` §3.3 |
| 11 | `GET /plans` 的 `depth` 上限统一为 **6**（原 §5.2 写 10，与 §5.1 及树的硬上限矛盾） | `api-design` §5.2 |
| 12 | M4 的 9 条实现口径（`include_progress` 语义、`move` 提升顶层时的部门、移动深度校验、跨部门错误码、写接口响应形状、删除计数…） | `api-design` §5.11（新增） |

`v1-scope.md` 顶部修订记录已加 **v0.11**。

### 11.3 下一步

| 里程碑 | 内容 | 状态 |
| --- | --- | --- |
| ~~M2~~ | ~~Part 3 组织与成员 19 个接口~~ | ✅ **已完成** |
| M3 | Part 4 任务 8 个接口（`/tasks/mine` 服务端分组、`BLOCKER_REQUIRED`、软删除、`/tasks/lookup`、`client_token` 幂等） | ✅ **已完成并验证**（单测 197 / 冒烟 220 全绿） |
| M4 | Part 5 课题 6 个接口（环形校验、深度 6、删除上提、O(n) 聚合） | ✅ **已完成并验证**（单测 233 / 冒烟 280 全绿） |
| M5 | 打包部署 · 带 SAN 自签证书 · TLS 关卡 | 🟡 **本机部分已完成**（TLS 22 项全绿 + 部署包 18.8 MB 端到端跑通）；公网部署**卡在服务器步骤 0**（架构 / 公网 IP / 端口 / 防火墙） |
| M6 | 按 `docs/code-review.md` **第一轮**修缺陷（3 个 P0 权限漏洞 + 8 个 P1 + 13 个 P2，共 24 条） | ✅ **已完成并验证**（单测 273 / 冒烟 325 / TLS 22 全绿，2026-09-14） |
| M7 | `docs/code-review.md` **第二轮**：独立复验第一轮 24 条（全部确认修复）+ **9 条新发现**（N-1…N-9） | ✅ **已完成**——9 条全部处理（N-8 按约定不改）：N-1（落地页 HTML 转义）/ N-2 / N-3 / N-4 / N-5（`idem` 补 `checkLoaded`）/ **N-6（注册节流改为按客户端 IP + 递增退避，因此未新增接口，接口计数仍是 39 / 39）** / **N-7（不可作用于同权或更高权的人，已从"重置密码"推广到改名 / 改角色 / 禁用）** / N-9（CSP），每条都带"回退即变红"的回归断言。当轮基线 **单测 322 / 冒烟 347 / TLS 22 全绿** |
| M8 | `docs/code-review.md` **第三轮复验**：复验第二轮 9 条 + **4 条新发现**（N-10…N-13） | ✅ **已完成**——第二轮 9 条全部确认修复；**N-10**（`assign` / `assign-batch` 漏在同权保护之外：副会长可降级同权者，甚至用 `assign` 推翻会长对同权者的移出决定）已修，批量改为逐条判定；N-11 文档限定词、N-12 裸 IPv6 退化注释、N-13 分布式局限说明均已处理 |
| M9 | **升级轻舟到 `3ea387e` + 适配 CangDB 缺失的 RBAC 层**：上游 `141a735` 修好 DEF-1 → 本地补丁撤销；框架新增的 `src/store.cj` / `src/rbac.cj` 依赖 CangDB（CangDB 已开源，但其 1.0.5 版本与 cjc 1.1.3 不兼容：编译通过、运行超时）→ 仍用 `server/src/fw_rbac_store.cj`（文件存储的数据层）+ `fw_rbac.cj`（`requirePermission` 中间件、我们的错误格式）替代，`build.ps1` 排除框架原版 | ✅ **已完成并验证**（提交 `d77c500`）：撤补丁后 TLS 关卡重跑 **22 / 0 全绿**；当轮基线 **单测 322 / 冒烟 347 / TLS 22**。等 CangDB 有与 cjc 1.1.3 兼容的版本后，删掉两个适配文件、从排除列表去掉 `store.cj` / `rbac.cj` 即可回到上游原版 |
| M10 | **容量基准与四项性能改造**（`docs/capacity-baseline.md`）：新增可复现基准 `server/tests/bench.ps1`（真实 HTTP，可与 `git worktree` 旧提交对比）；排序插入→堆 · PBKDF2 移出锁 · 令牌回收 · 整库落盘移出锁 | ✅ **已完成并验证**（提交 `f47088f`）：4 并发登录 **1574 → 867 ms**（串行因子 0.99 → 0.56）是唯一有量级收益的一项；排序与落盘在千人档落在噪声内，价值是**最坏情况下界**与**库变大后的锁占用** —— 文档里已如实写明。当轮基线 **单测 349 / 冒烟 347 / TLS 22 全绿**（2026-09-15） |
| M11 | `docs/code-review.md` **第四轮复验**：6 条新发现（**N-14** 本机判定子串匹配 `::1` → 远程 IPv6 可关停服务 · **N-15** 被 4xx 拒绝却留半改状态并落盘 · **N-16** 登录时序侧信道可枚举手机号 · **N-17** 审计 IO 在锁内 · **N-18** 任务可挂任意部门课题 · **N-19** 招募 token 仅 32 位），另指出 `/admin/shutdown` 缺反例断言 | ✅ **已完成并验证**：6 条全修 + 补 3 组单测闸门与 1 段冒烟闸门。**N-16 时间表：修复前 388/382/431 ms 对 28/29/30 ms（13×），修复后 486/453/453 对 433/484/464（≈1.0×）**。当前基线 **单测 387 / 冒烟 360 / TLS 22 全绿**（2026-09-15） |
| M12 | **按《鸿蒙俱乐部-全场景UI设计规格》对齐服务端**（13 页 PDF 逐条对照，报告见 `docs/ui-spec-conformance-review.md`）。按决定落地 8 条（含队友复验补的 2 条）：**D-1** 权限摘要补 5 个管理布尔（`manage_depts` / `view_register_code` / `change_register_code` / `manage_invite_links` / `transfer_presidency`，**全部由 `can()` 推导**）· **D-2** `GET /members?q=` 按姓名或部门名搜索（手机号不参与，隐私最小化）· **D-3** 任务/课题**读**范围放开到全社团（`view_scope` 对 active 统一 `all`；**写**范围一字未改）· **D-4** 阻塞任务的**求助对象** `needs_help`（进 blocked 时可带 `help_dept_id` / `help_member_id`，离开自动清空）+ 部长/副部长首页带出本部门阻塞项（`counts.borrowed_blocked`）· **D-5** `TaskBrief.overdue_days`（本地日界差）· **D-7** 成员详情 `stats` 补 `done_tasks` / `overdue_tasks` | ✅ **已完成并验证**：`Task` 加两个字段（旧库无需迁移，`reqIntOr` 容错）；三处旧断言按新口径更新，并补"回退即变红"闸门（单测 +45、冒烟 +35）。当前基线 **单测 471 / 冒烟 421 / TLS 22 / 契约 30 全绿**（2026-09-16）。**D-6（密码口径）定稿为 8–32 字节 + 只允许数字/英文/符号**（`passwordError()` 作唯一入口，注册/改密/`init-admin` 三处共用；有意偏离设计稿 P12 的 6 位下限）；其余 8 条差异（D-8~D-14）**按决定保留原版本**；**D-15（首页阻塞原因）/ D-16（招募链接预填闭环，接口 39→40）**为队友复验后追加 |
| M13 | **升级轻舟到 `e072980`（= 上游 HEAD）+ 纳入自带后台管理界面**：快照换成 `e072980`（`src/` 29 → **36** 个文件，新增 `jwt.cj` / `ratelimit.cj` / `securityheaders.cj` / `websocket.cj` / `httpclient.cj` / `hybrid.cj` / `circuit.cj`；上游删掉了 `cjpm.lock`），并新增 `build.ps1 -Target admin` → `build\admin\admin.exe`（自包含 exe + `admin-web\dist` + `admin.env`；前端产物随仓库提交，**部署机不需要 Node/npm**）。后台数据层同样路由到**本地 JSON 文件**（复用 `fw_rbac_store.cj`；沧海 CangDB 已开源，但其 1.0.5 版本与 cjc 1.1.3 不兼容：编译通过、运行超时）。新增 `tests/admin-check.ps1` 端到端把关 | ✅ **已完成并验证**：五套全绿 —— **单测 471 / 冒烟 421 / TLS 22 / 跨仓契约 30 / 后台端到端 29**（2026-09-16）。附带查清一个**上游特性**：业务码在 body 的 `code`、HTTP 状态不承载语义，且 `passOnNotFound` 路由 miss 时会污染 `ctx.status` → **成功响应也可能带 404**（已逐字节比对 `src/api.cj` / `src/router.cj` / `src/auth.cj` 与上游一致；前端只看 `code` 所以界面正常）。细节见 `API-NOTES` 坑 34 |
| M14 | **「社团管理」运维页**（后台里加 `/club`）：后台入口改成我们自己的 `server/src/ops/admin_main.cj`（上游那套路由照旧 + `/api/club/**` + 链尾 `statusNormalizer()` 修掉"成功响应带 404"）；新增 `club_view.cj`（社团库**只读**白名单视图：概览/名录/部门/任务/课题/招募链接/审计）与 `club_json.cj`（让 `store.cj` 能单独编进这条构建）；**读**直读库文件、**写**以专用运维账号的身份走 club-server 真实 API；前端另起 `server/admin-web`（上游版本 + `Club.vue`，`dist` 随仓库提交）。顺带修了一个**既有缺陷**：`POST /admin/shutdown` 的回执会被关停线程抢先关连接吞掉（实测 8 次里 6 次空 body），现在关停线程先等 1 秒 | ✅ **已完成并验证**：**单测 471 / 冒烟 421 / TLS 22 / 契约 30 / 后台 29 / 运维页 42** 全绿（2026-09-16）。三条闸门值得一提：运维接口**不含 `pw_*`**、`user` 角色访问 `/api/club/**` 得 403、关停回执必须是 `ok:true`（坑 36 的回归闸门） |
| M15 | **运维身份独立于会长**（用户 2026-09-16 定："运维不应由会长执行，应有专门的运营人员；账号 admin，密码 admin123"）：新增内置身份 **`ops`**（`roleRank` 与会长同档；`roleAllows` = 除「移交会长」外全放行；`scopeAllows` 全社团；`checkAccess` 里豁免"同档不可互处置"这道闸，所以能处置会长）；`views.cj` 的 `roleLabel`/`permissionsOf` 覆盖它；**不可由 API 分配**（`isKnownRole` 里没有它）→ 只能 `club-server init-ops <手机号> <口令>` 建、`retire-ops` 停用。运维台侧：`admin.env` 新增 `club_user`/`club_pass`，新增 `/api/club/session`（后台代持该账号换令牌，内存缓存 6 小时），前端去掉会长登录表单改为自动取会话，并修掉角色代号写错（`lead`/`vice_lead`，原先误写成 `minister`）。顺带补齐**部门新增/改名**的审计（原先只有删除记了）。**系统账号在 App 名录里隐藏**（按甲方选择"隐藏系统账号"而不是让客户端补标签）：`GET /members` 与 `?q=` 都不返回 `role = ops`，按 id 查详情仍可达 | ✅ **已完成并验证**：**单测 490 / 冒烟 427 / TLS 22 / 契约 30 / 后台 29 / 运维页 64** 全绿（2026-09-17 复验；2026-09-16 时为 52，之后新增"运维账号可直接登录运维台"的 12 条闸门）。关键闸门：运维可换注册口令/建部门/重置**会长**口令，但**移交会长必须 403**；`ops` 不能用 API 分配（400）；会长也不能停用运维账号（同档保护）；审计里 `actor` 是"运维"；名录/搜索都搜不到系统账号。本机开发库已按甲方口令建了运维账号 `13800000009 / admin123`（生产必须换） |
| M16 | **运维账号可直接登录运维台**（用户 2026-09-17 反馈："本机调试时登录框仍预填 admin/admin123，能不能改成用 §2.2 建的运维账号登录"）：登录框去掉硬编码预填的 `admin`/`admin123`（N-29 后那对值已作废，预填只会把人直接带进"登录失败"）；`/api/login` 改为**两种凭据都认** —— ① 后台自己的账号（轻舟 RBAC：`admin`/`user`）② club-server 的**运维账号**（手机号 + 运维口令），后者由 **club-server 校验**（它才是口令权威，且写路径也走它，两边不会各说各话 —— "登录成功了但写操作说凭据被拒"这种分裂状态因此不存在）。身份用 JWT 主体 **`ops:<手机号>`** 表达：**不新增角色、不迁移 `rbac.json`**，框架的 `requirePermission` 对非数字主体判 `userId=-1`，于是后台管理接口（用户/角色/权限）对运维身份**自然关闭**，运维接口由 `requireClubOps` 显式放行这一形态。`/api/me` 对该身份返回 `role=ops` / `can_ops=true` / `is_ops_account=true`（前端据此显示「社团管理」、隐藏「用户管理」，否则点进去会被 401 拦截器弹回登录页）。登录时把输入的凭据留在**内存**里供 `/api/club/session` 换令牌，因此**不必再手改 `admin.env` 的 `club_user`/`club_pass`**（那条路仍作为备选保留，向后兼容）。另加**按客户端 IP 的登录节流**（阈值取 club-server 的一半、回环豁免）：登录框会把非后台账号转发给 club-server 校验，不拦一道的话，局域网内刷运维台登录就可能把 club-server 的登录桶刷满、把真运维一起锁在门外（N-21 的同一类问题）。**【2026-09-18 补记】这条理由的一半已作废**：club-server 的"按 IP 登录桶"已随"应用层不做抗 DDoS"（见 `code-review.md` N-21 后续决定）移除，所以"别把 club-server 的桶刷满"不再成立；运维台这一道按 IP 节流**保留**，它守的是**后台口令本身**（未认证端点上的口令穷举），与流量型攻击无关。顺带修两个既有缺陷：`App.vue` 的 `me` 是 setup 时的一次性快照，登录后走 SPA 跳转不重读 → **刚登录时侧边栏的「社团管理」入口根本不出现**（必须手动刷新一次）；`init-ops` 的输出只写"把凭据填进 admin.env"，与新的推荐路径不一致 | ✅ **已完成并验证**：**单测 490 / 冒烟 427 / TLS 22 / 契约 30 / 后台 29 / 运维页 64** 全绿（2026-09-17）。新增 12 条闸门（`tests/ops-check.ps1` 第 4b 段）：运维账号可登录、`/api/me` 身份是 ops、运维身份**进不了** `/api/users`、口令错 → 401 且提示含处置方向、**会长账号登运维台 → 403**（职责分离）、后台账号 `admin` 仍可登录（老路径未被挤掉） |
| M17 | **修掉运维台前端两个缺陷**（2026-09-17 用户实测报告，详见 `code-review.md` 第七轮 **N-32 / N-33**）：**N-32** `api.js` 把两类 401 混为一谈 —— ① 没登录/令牌过期 ② 已登录但这条接口不归你；用运维账号登录时 `Dashboard.vue` 那句 `try { await api.perms() } catch {}` 的 catch 永远轮不到（api.js 在 catch 之前就 `window.location.href='/login'`），于是**仪表盘渲染出来的一瞬间又被整页跳回登录页**；口令打错时 `/api/login` 的 401 也走这条路 → **错误提示一闪即逝、输入被清空**。改为按"这条接口是否任何登录身份都该能用"分流：登录接口与后台管理接口（`/api/users|roles|perms`）上的 401 只抛不跳。**N-33** 轻舟的 ETag 只按**文件字节大小**生成（`static.cj:32` 的 `makeETag(size)`），而 vite 重建后 `index.html` 只有 hash 文件名变、**字节数不变**（实测重建前后都是 **399 字节**，`git cat-file -s` 两版相同）→ ETag 相同 → 浏览器拿到 **304** 继续用旧 HTML，而它引用的旧 `index-<hash>.js` 已被 vite 删除 → **JS 404 → 白屏**（`/club` 是新 URL、无缓存条目，所以正常，这就是"首页白、子页好"）。运维台关闭 ETag（框架不动，它受 MANIFEST 锁定） | ✅ **已完成并验证**：**单测 490 / 冒烟 427 / TLS 22 / 契约 30 / 后台 29 / 运维页 64 / 前端逻辑 17** 全绿（2026-09-17）。新增前端逻辑闸门 `server/tests/web-logic-check.mjs`（Node 直接驱动 `api.js`，假 fetch/localStorage/window，17 条），并**做了 A/B**：把 `api.js` 退回旧逻辑后**恰好 4 条变红**，修复后 17/0 |
| M18 | **`init-admin` 可指定首任会长姓名**（用户 2026-09-17 需求："创建会长时可以输入其名字（而非默认会长）"）：新增 `--name <ASCII 姓名>` 与 **`--name-file <UTF-8 文件>`** 两个选项，**老的三参数调用行为一字不变**（不给则仍默认「会长」）。中文姓名只能走文件 —— **中文命令行参数会让程序在 `main` 之前就崩**（`IllegalArgumentException: Invalid unicode scalar value.`，实测与参数位置、代码页都无关，见 `API-NOTES.md` 坑 11），这条功能的形状就是被这个硬约束逼出来的；也评估过环境变量通道，但仓颉 std 没有 `getEnv`/`envVars`（`third_party/qingzhou/src/config.cj` 有记录），不拿未验证的 API 搭功能。解析上顺带做了三件小事：数据目录仍可选（用"第 4 个参数是否以 `--` 开头"区分目录与选项，于是 `init-admin P W --name-file f.txt` 也能用）· **不认识的参数明确报错**（不再静默忽略 —— 静默忽略正是"以为传了名字、其实没传"的来源）· `--name` 与 `--name-file` 互斥。姓名文件允许带 UTF-8 BOM（PS 5.1 的 `Set-Content -Encoding UTF8` 就带）与结尾换行，均予处理；姓名只要求非空白，与 `PATCH /api/v1/members/{id}` 同口径 | ✅ **已完成并验证**：新增 `tests/init-name-check.ps1`（**40 项**：默认值 · ASCII · 中文 UTF-8 往返 · BOM · 首尾空白裁剪 · 省掉数据目录 · 7 类错误用法且都不得半途写库 · 非空库仍拒绝）。当轮基线 **单测 490 / 冒烟 427 / TLS 22 / 契约 30 / 会长姓名 40 / 后台 29 / 运维页 64 / 前端逻辑 17** 全绿（2026-09-17） |

**接口进度 40 / 40**：认证 5 · 组织与成员 20 · 任务 8 · 课题 6（= 39 个业务接口）+ 运维 `/health`。
（早期写「38 / 39」是把 `/health` 漏算了；2026-09-16 新增 `GET /api/v1/join/{token}`（D-16）后为 40。
另有一个**不在接口清单里**的公开 HTML 落地页 `GET /join/{token}`。）

#### ✅ 环境故障已定位并已规避（2026-09-13 晚）

当晚本机**所有仓颉 exe 启动即崩**（`0xC0000005`；故障模块恒为 `msvcrt.dll`、偏移 `0x62f1e`，
自行解析 PE 导出表得知落在 **`wcslen`**）：本项目 exe、轻舟框架 exe、`cjenv.exe`，
连 1.0.5 与 1.1.3 两套 SDK 的产物都一样；用"进 `main` 就写文件"的探针确认 **`main()` 根本没执行**。

**根因**：事件日志显示 **21:40:35「2026-09 预览更新 (KB5124010) 安装成功」**，紧随 21:40:13 的开机；
当日 13:58 时 M2 的 165 项冒烟测试还是全绿的。

**受控验证**：**22:18 卸载 KB5124010 并重启后立即恢复**（UBR 26300.9539 → 26300.9445）：
最小 hello world 正常、单测 **197/0**、冒烟 **220/0**。
卸载前后**唯一版本变化的已加载模块是 `ntdll.dll`（9539 → 9278）**，
`msvcrt`/`ucrtbase`/`msvcp_win`/`KERNEL32`/`KERNELBASE` 全未变
——这也解释了"`msvcrt!wcslen` 机器码一字未改却崩在那里"。

完整证据链与复现源码见：
上层的 `cangjie-upstream\cangjie-runtime-startup-crash.md`（**已提交给仓颉团队**）、
`API-NOTES.md` §5、以及同目录的 `cangjie-upstream\repro.cj`。
（当时的证据 zip 是一次性产物，已按需删除；结论都固化在上述文档里。）


同一时段还发现：`build.ps1` 原先依赖环境里的 `CANGJIE_HOME`，而 **cjenv 把它切到了 1.0.5**，
造成"前端 1.1.3 + 后端 LLVM 1.0.5"串台、编译器直接崩。已在 `build.ps1` 里显式钉死工具链。

### 11.4 仍未决

| # | 事项 | 影响 |
| --- | --- | --- |
| 1 | **服务器步骤 0 未跑** | 卡 M5：需确认架构是否 x64、公网 IP、端口、防火墙+安全组 |
| 2 | **CangDB 已开源但 1.0.5 与 cjc 1.1.3 不兼容**（编译通过、运行超时），故**框架 RBAC 那一层**仍以文件适配版代替 | **已知限制 / 不阻塞**：轻舟新版 `store.cj`/`rbac.cj` 依赖它，club-server 的**框架 RBAC** 仍用 `fw_rbac_store.cj` + `fw_rbac.cj` 顶上（`build.ps1` 排除框架原版 —— 见 `build.ps1` 的排除清单注释）。⚠ **但这与"社团数据存哪儿"是两件事**：**社团数据的持久化 2026-09-20 起已是 MySQL**（`server/src/mysql_store.cj` + 框架 `db.cj`/`db_mysql.cj` + 内置 MariaDB 驱动），运维台（`-Target admin`）2026-09-19 起也是框架 `store.cj` + MySQL（见 `docs/mysql-backend.md`）。等 CangDB 有与当前工具链兼容的版本后，再考虑替换回上游实现（**撤排除前必须重测**：升到 cjc 1.2.0 之后没有重新验证过 CangDB） |
| 2b | ~~轻舟后台的成功响应也可能带 HTTP 404~~ | ✅ 已修（2026-09-16）：入口换成我们自己的 `src/ops/admin_main.cj` 后，加了链尾 `statusNormalizer()` 按 body 的 `code` 回写状态码；**内置框架一行未改**。见 `API-NOTES` 坑 34 |
| 2c | **运维账号的生命周期与口令** | 只能用 `club-server init-ops`（重设口令）/ `retire-ops`（停用）管理，API 不给分配这一档。本机开发库现在是 `13800000009 / admin123`（按甲方指定的口令）—— **生产必须换强口令**，它等价于"会长权限减移交" |
| 2d | ~~客户端不认识 `ops` 角色~~ | ✅ 已按"**隐藏系统账号**"解决（服务端侧）：`GET /members` 名录与 `?q=` 搜索都不返回 `role = ops` 的账号 → **客户端零改动**，名录里也不会冒出"待分配"的运维账号。要看/管它用运维台（仍显示「运维」）。闸门在 smoke（名录不含 / 搜索不含 / 按 id 仍在） |
| 2e | **改运维页前端需要 Node** | `dist` 随仓库提交，**部署机不需要 Node**；但改 `server\admin-web\src` 的人要 `npm install && npm run build`（本机用 DevEco 自带 node 18 + npm 10 实测通过） |
| 3 | 工作区原先**不是 git 仓库** | 2026-09-13 已建 GitHub 仓库 `XueDric/open-harmony-club-service` 并上传；提交作者为 `XueDric <318242380+XueDric@users.noreply.github.com>`。**2026-09-14 已把三轮评审修复 + 仓库整理全部推送**，远端 `main` 与本地 HEAD 一致 |
| 3b | **推送 github 的网络** | 2026-09-14 实测**直连可用**（`git push origin main` 直接成功，此前记录的"直连不通"已不适用）。若哪天直连超时（约 20s），改走本地代理：<br>`git -c http.proxy=http://127.0.0.1:7897 -c https.proxy=http://127.0.0.1:7897 push origin main`<br>（直连超时**别误判成权限问题**） |
| 4 | 忘记密码：v1 由会长重置 | 已定 |
| 5 | 服务器可用期限、备份交接人 | 需向老师确认 |

---

### 11.5 客户端交接要点（**客户端同事从这里开始**）

> **技术栈已定：ArkTS**（2026-09-14；此前的仓颉方案已退役）。
> **现状（2026-10-04 据实更正）**：`pages/` **21 个页面文件**、`main_pages.json` 注册 **11 个路由页**；
> `api/`（AuthApi · MemberApi · TaskApi · PlanApi · DeptApi · HttpClient）+ `store/`（Token / Session /
> Permission / ServerConfig / Outbox / CalendarMap）+ `util/`（CalendarSync · ClientToken · DateFmt ·
> PlanTree · InviteDeepLink · RouterUtils）+ `components/`（5）+ `core/Theme.ets` + `config/Env.ets` 均已落地，
> 页面**已在调真接口**（`Index.ets` → `AuthApi.me()`），令牌认证 / 离线 outbox / 系统日历同步 / 邀请深链均在；
> **HAP 仍未签名、未上真机**。
> 构建命令与两个环境坑 → 见 **`client-build.md`**；⚠ 该文档正文停在 2026-09-14，其 §3.3/§3.4/§3.5 已是历史记录，
> **当前缺陷清单见 `client-build.md` §3.8 与本仓库 `README.md`「已知缺陷与未修项」**。

#### A. 先让它跑起来

```powershell
$ds = "D:\DevEco Studio"
$env:DEVECO_SDK_HOME = "$ds\sdk"      # DevEco 自带 SDK（API 24 / 6.1.1.125）
$env:JAVA_HOME       = "$ds\jbr"      # ⚠ 必须用它的 JBR 21；本机 PATH 上是 JDK 1.7，会报 UnsupportedClassVersionError
$env:PATH = "$ds\jbr\bin;$ds\tools\node;$ds\tools\ohpm\bin;$env:PATH"
Set-Location E:\harmonyOS\cangjie_web
& "$ds\tools\hvigor\bin\hvigorw.bat" assembleHap --no-daemon
```

产物：`entry/build/default/outputs/default/entry-default-**unsigned**.hap`。
用 DevEco 打开项目直接 Build 也可以（IDE 会自己用对 JBR）；**但定稿前命令行也要能过**，
否则 CI / 别人机器上会重现同一个 Java 版本坑。

#### B. 客户端当前进度（2026-10-04 复核）

| 项 | 状态 | 说明 |
| --- | --- | --- |
| 页面 | **21 个页面文件 / 11 个路由页** | `main_pages.json` 注册：ServerConfig · Index · Login · Register · Pending · TaskDetail · PlanDetail · CreateTask · CreatePlan · Approve · Admin；**首页第一个 Tab 即「我的任务」**。⚠ **C-7 未修**：`SplashPage` / `PendingWaitPage` 是死代码（未登记、无引用） |
| 接口 | **已接真接口** | `api/`：AuthApi / MemberApi / TaskApi / PlanApi / DeptApi / HttpClient；令牌认证、离线 outbox（`OutboxStore`/`OutboxSync`）、系统日历同步（`CalendarSync`）、邀请深链（`InviteDeepLink`）均已实现 |
| 构建 | ✅ 通过 | `hvigorw assembleHap` → BUILD SUCCESSFUL（清空 `build` 干净重建同样通过） |
| 签名 | ❌ 未配 | 产物是 unsigned，**装不上设备** |
| 真机 | 未验证 | `hdc list targets` 为空；模拟器镜像有 6.1.1 / 7.0.0 |

#### C. 交接清单（按优先级）

1. **配置签名**（唯一挡住"装到手机"的一步）：DevEco → `File > Project Structure > Signing Configs`
   勾 **Automatically generate signature**（需登录华为账号）。之后 `assembleHap` 产出已签名 HAP。
2. **确认首页方向** ✅ **已对齐**：`Index.ets` 现为 5 个 Tab（**我的任务** / 任务 / 课题 / 名录 / 我的），
   首页就是「我的任务」，与 `frontend-brief.md` §1 一致（原记录"三个 Tab 全是成员 / 管理方向"已过时）。
3. ~~补 8 个缺失页面~~ ✅ **页面已齐**：登录 / 注册 / 我的任务 / 任务列表 / 任务详情 / 课题列表 / 课题详情 /
   加入流程 / 我的设置等均在 `pages/` 下（21 个文件，`main_pages.json` 注册 11 个路由页）。
   **当前要做的不是补页面**，而是收敛已知缺陷（见 `client-build.md` §3.8）。
4. ~~接接口~~ ✅ **已接**（`api/` 层 + `TokenStore` 令牌认证）。仍要读 `frontend-brief.md` + `api-design.md`（唯一权威）；
   `client-build.md` 停在 2026-09-14，其契约差异清单以**代码与契约测试**（`tests/client-contract-check.ps1`，33 项全绿）为准 ——
   最容易踩的三点仍然是：
   ① 部门 id 服务端从 **1** 开始（页面里是 0 起，而 `dept_id = 0` 含义是**未分配**）；
   ② 角色下拉**不能有 `president`**（`assign` / `PATCH /members` 一律拒绝，会长只能走移交）；
   ③ 成员详情**拿不到手机号**（`MemberBrief` 不含手机号，只有 `GET /auth/me` 的本人视图有）。
5. **"有界面没逻辑"已基本接线**：`ManagePage.ets` 直接持有 `MemberApi` / `DeptApi`，重置密码 / 移出社团 /
   新建部门 / 随机轮换 / 移交会长都走服务端。⚠ 但 `client-build.md` §3.5 那份清单停在 2026-09-14，
   是否有残留的"只写不读 `@State`"需按当前代码复核。
6. **`pending` 账号要跳「等待管理员分配」页**，不进主界面（见下面 E 段第 4 条）。

#### D. 两项需**单独排期**的客户端工作（brief §6.③ 与 §6.④）

- **日历同步机制**：服务端**不存**日历字段，全部在客户端本地完成 —— 本地维护
  `task_id → {event_id, cached_due_at, cached_status}`，拉任务时比对（`due_at` 变→更新、
  `status=done`→删除、不在服务端返回中→删除、权限被拒→降级为 `.ics` 导出），
  用 `POST /tasks/lookup` 的 `missing` 批量回收。**不做更新/删除，日历会堆错误提醒。**
- **自签证书信任**：鸿蒙默认不信任自签证书，要在 `resources/base/profile/` 配网络安全配置并内置 CA。
  ⚠️ 证书**必须带 SAN**（服务是 IP 访问，SAN 写 `IP:<公网IP>`）；轻舟示例自带证书**没有 SAN，不能用**。

#### E. 接口与错误码

精简版看 `frontend-brief.md`（页面清单 / 通用约定 / 错误码 / **5 件必知事项**），
完整定义看 `api-design.md`。**接口已冻结（40 / 40），要改先提出来。**

**要能处理这几类"看起来像 bug 的 403 / 429"**（都属于服务端设计，不是缺陷）：

- **同权保护**：副会长试图降级 / 禁用 / 重置 / 改名另一位副会长 → `403 FORBIDDEN_ROLE`（见 §4.3）；
  该规则覆盖五类动作：重置密码 / 调部门改角色 / 移出社团 / 编辑姓名 / **审批分配（`assign`、`assign-batch`）**；
- **最后一个会长**：`403/409 FORBIDDEN_LAST_PRESIDENT`；
- **注册被节流**：`429 TOO_MANY_ATTEMPTS` —— 节流**按客户端 IP**（2026-09-14 起），
  只影响注册、不影响登录与其它接口；
- **`pending` 账号**：能登录但 `permissions` 全 false、`view_scope = none`，
  客户端应跳「等待管理员分配」页，**不进主界面**。

#### F. 本机联调起服务

```powershell
cd server
powershell -NoProfile -ExecutionPolicy Bypass -File .\build-mysql-driver.ps1   # 一次性：出 MySQL 驱动产物
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1               # 编译（并拷 4 个依赖 DLL）
# 或 .\build.cmd（同上，且双击可跑）；也可以 .\dev-serve.ps1 一键起 MariaDB + 服务
# **没装 SDK 的机器**直接用部署包，见下文与 local-deploy.md §4
cd build
$dsn = "mysql://root:clubroot123@127.0.0.1:3307/club_server"   # ⚠ 不定义就是空串，会静默退回默认参数
.\club-server.exe init-admin 13800000000 ClubPass2026 $dsn     # 预置首任会长 + 4 个组织
#    会长姓名（不给则默认「会长」）：--name LiSi（ASCII）
#    中文**必须走文件**：--name-file n.txt（文件内容即姓名；中文当参数会让程序在 main 之前崩，见 API-NOTES 坑 11）
.\club-server.exe serve 8080 $dsn                              # HTTP
# HTTPS： .\club-server.exe serve-tls 8443 $dsn --cert ..\certs\cert.pem --key ..\certs\key.pem
```

> ⚠️ **2026-09-20 起这些位置参数是 DSN**（不再是数据目录 `dev-data`），证书 / 私钥必须用 `--cert` / `--key`；
> 业务数据在 MySQL 里，`--data-dir` 只管 `audit.log`。
> ⚠️ **`cwd` 必须是 exe 所在目录**（审计日志目录与证书按相对路径读）；
> 冒烟脚本用独立测试库 `club_smoke` 与独立审计目录 `build\smoke-data`，不会碰你的联调库。

> **注意**：客户端用 HTTPS 连自签服务时要先做 D 段第二条（内置 CA）；联调阶段可先用
> `serve 8080` 走 HTTP —— 但 HarmonyOS 对**明文 HTTP 也有限制**，需实测确认默认行为。

---

### 11.6 仓库结构（2026-09-14 · ArkTS 迁移后）

| 变动 | 说明 |
| --- | --- |
| **客户端换栈**（2026-09-14） | `entry/` 由**仓颉**改为 **ArkTS**：页面在 `entry/src/main/ets/pages/`、入口 `entry/src/main/ets/entryability/EntryAbility.ets`。原仓颉脚手架（`src/main/cangjie/`、`cjpm.toml/.lock`、`src/test/`、`src/ohosTest/`）已删除；构建方式见 `client-build.md` |
| **对外材料移出仓库** | 仓颉运行时缺陷报告 + Issue 稿件 + 最小复现 `repro.cj`、轻舟 TLS 需求与实测 → 上层 `E:\harmonyOS\cangjie-upstream\`（5 个文件）。仓库内 17 处引用已改写为指向那里 |
| **删除** | 早先删掉了 `entry/src/test`、`entry/src/ohosTest` 的 DevEco 模板示例（8 个文件）；本次迁移又删掉仓颉客户端的 5 个跟踪文件 |
| **入库文件** | **65 个**：`server` 25 · `entry` 18 · `docs` 9 · `AppScope` 5 · 根配置 7 · 其它 1 |
| **`server/build/` 是构建产物** | 构建产物、冒烟/TLS 测试数据、日志都不入库。**下次跑测试前先执行 `build.ps1`** |
| **轻舟快照入库**（2026-09-15，2026-09-16 升级） | `server/third_party/qingzhou/`：`src/`（36 个）+ `examples/admin.cj` + `admin.env` + `admin-web/`（含预构建 `dist/`）+ `LICENSE`/`README.md`/`CHANGELOG.md`/`cjpm.toml`；版本记在 `UPSTREAM_COMMIT`（现 `e072980`）、内容由 `MANIFEST.sha256`（61 个文件）逐字节锁定。`deps/openssl/*.dll`（6.5 MB）**不入库** |
| **`build.ps1 -Target admin` 另起一份产物** | `server/build/admin/`：`admin.exe` + `admin-web/` + `admin.env` + 4 个 DLL + `admin-data/`（运行时生成）。**全在 `build/` 下，不入库** |
| **保留（不入库）** | `server/dist/`（完整部署包，可直接部署）· `server/certs/`（证书 + 私钥）· `oh_modules/`（鸿蒙依赖，重装需联网）· `.idea/`、`local.properties` · `entry/build/`（HAP 产物） |
