# 社团管理工具 · 服务端

> 📁 **服务端指南** ｜ 本文件：`server-guide.md` ｜ [全部文档目录](README.md)

> 仓颉 1.2.0 + [轻舟 QingZhou](https://gitcode.com/BIT-FSSLab/QingZhou) v0.12.0 · **MySQL 存储**（2026-09-20 起）· Windows 部署
> 接口权威：`api-design.md`（40 个接口：39 个业务 + `/health`）· 范围权威：`v1-scope.md`
> **只想赶紧起起来联调**：看 `local-deploy.md` **§0.5**（三条命令 / `server\dev-serve.ps1` 一键脚本）
> 与 **§5**（客户端怎么连、队友连不上怎么查）；本节是**细节版**。

## 这个服务端解决什么

第 1 节的两个问题：**① 社团里有哪些人 ② 每件事由谁负责、做到什么程度**。

首页接口是 `GET /tasks/mine`（我的任务），不是组织架构图。

---

## 快速开始

> **第一次在本机跑起来**：照 **`local-deploy.md`**（一页上手，含体检与坑表）走更快；本节是细节版。

```powershell
# 1. 编译（并复制 4 个依赖 DLL 到 build\）
#    ⚠ 2026-09-20 起：先出 MySQL 驱动产物（只须一次，不入库）
powershell -NoProfile -ExecutionPolicy Bypass -File .\build-mysql-driver.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
# 等价包装（免记 -ExecutionPolicy Bypass，可双击）：.\build.cmd

# 2. 起一台 MySQL（库/表会自动建；本机联调用便携版 MariaDB，见 local-deploy.md §2.0）
#    或直接用一键脚本：powershell -NoProfile -ExecutionPolicy Bypass -File .\dev-serve.ps1

# 3. 到 exe 所在目录操作（与部署形态一致：一切按相对路径）
cd build
$dsn = "mysql://root:clubroot123@127.0.0.1:3307/club_server"

# 4. 初始化首任会长（同时预置 4 个组织与一个随机注册口令）
.\club-server.exe init-admin 13800000000 ClubPass2026 $dsn

#    要启用 AI 能力（可选）：见下面「带 AI 能力启动」一节 —— 不给 --ai-endpoint 就是完全不启用，
#    服务端照常跑、AI 接口一律 200 + fallback，不会 5xx。
# 5. 起服务
.\club-server.exe serve 8080 $dsn
```

> ⚠️ **`cwd` 必须是 exe 所在目录**（**审计日志目录**与证书按相对路径读）。部署时同理。
> 数据落在 **MySQL** 里（`data\db.json` 不再是真相来源，2026-09-20 起）；
> `--data-dir`（默认 `data`）下只剩 `audit.log`。

### 命令行

| 命令 | 说明 |
| --- | --- |
| `club-server serve [端口] [DSN] [连接选项]` | 启动 HTTP（默认 `8080`；DSN 缺省为 `127.0.0.1:3306/root/空口令/club_server`） |
| `club-server serve-tls [端口] [DSN] [--cert F] [--key F]` | 启动 HTTPS（默认 `8443` / `certs\cert.pem` / `certs\key.pem`） |
| `club-server init-admin <手机号> <初始密码> [DSN] [姓名选项]` | 预置首任会长 + 4 个组织（仅空库可执行）。姓名选项：`--name <ASCII 姓名>` / `--name-file <UTF-8 文件>`；**中文姓名只能走文件**（中文当命令行参数会让程序在 `main` 之前就崩，见 `API-NOTES.md` 坑 11）；两个都不给则默认「会长」 |
| `club-server init-ops <手机号> <口令> [DSN]` | 创建/重设**运维账号**（角色 `ops`：除「移交会长」外与会长同权；不可由 API 分配） |
| `club-server retire-ops <手机号> [DSN]` | 停用运维账号（保留记录，审计仍可追溯） |
| `club-server test [DSN]` | 运行单测（**不给 DSN 也能跑**：507 条全对内存 Store；给了再加一次 MySQL 往返验证） |
| `POST /admin/shutdown` | 优雅关闭（**仅本机可访问**；Windows 无信号机制） |

> **连接参数的两种写法**（二选一，命令行给了哪项就以哪项为准）：
> DSN `mysql://用户:口令@主机:端口/库名`，或命名参数
> `--mysql-host H --mysql-port P --mysql-user U --mysql-pass PW --mysql-db D`。
> `--data-dir <目录>` 只决定**审计日志**落点（默认 `data`）——
> **它不再是数据目录**：老写法 `init-admin P W data` 会被明确拒绝并告诉你改成 DSN。
> **不支持环境变量**：本工具链的仓颉 std 没有 `getEnv`。

### 本机跑 HTTPS（框架原生 TLS，不用 Nginx）

```powershell
# 1. 生成**带 SAN** 的自签证书（现代客户端完全忽略 CN，只看 subjectAltName）
#    ⚠ SAN 里要写**客户端实际访问的地址**：真机/队友联调时必须有你的局域网 IP
#      （现查：local-deploy.md §5.2；仓库里现成那张只有 127.0.0.1 + localhost）
$openssl = "D:\Program Files\Git\usr\bin\openssl.exe"
& $openssl req -x509 -newkey rsa:2048 -nodes `
  -keyout certs\key.pem -out certs\cert.pem -days 3650 `
  -subj "/C=CN/O=Club/CN=club-server" `
  -addext "subjectAltName=IP:127.0.0.1,IP:10.194.233.104,DNS:localhost"

# 2. 起 HTTPS（连接参数是 DSN，证书用 --cert/--key 命名参数）
cd build
$dsn = "mysql://root:clubroot123@127.0.0.1:3307/club_server"
.\club-server.exe init-admin 13800000000 ClubPass2026 $dsn
.\club-server.exe serve-tls 8443 $dsn --cert ..\certs\cert.pem --key ..\certs\key.pem
# 等价：..\dev-serve.ps1 -Tls -Port 8443

# 3. 完整验证（协议版本、SAN、真证书校验、HTTPS 接口、明文反证）
powershell -NoProfile -ExecutionPolicy Bypass -File ..\tests\tls-check.ps1
```

> 部署到公网时把 SAN 里的地址换成真实公网 IP，并用
> `openssl verify -CAfile certs\cert.pem -verify_ip <公网IP> certs\cert.pem` 自检。
> 私钥绝不入库：`server/certs` 与 `server/dist` 都已在 `.gitignore` 中。
> 多人联调时先走明文 HTTP 确认链路、再上 HTTPS（证书问题很容易掩盖网络问题，
> 见 `local-deploy.md` §5.5）。

### 带 AI 能力启动（可选，2026-10-06 补）

> **不给 `--ai-endpoint` 就等于完全不启用 AI** —— 服务端照常启动，5 个 AI 接口返回
> `200 + data.source=fallback`（不依赖模型的规则兜底内容），**永不 5xx**。
> 所以 AI 是**纯增量**的：本地只跑业务、不配它完全没问题。

#### 怎么起（可复制，按你的库改 DSN）

```powershell
cd server\build

# ① 密钥与 CA 都放**仓库外**，且路径里**不能有空格**
#    ⚠ 项目的命令行按空格切分参数：--ai-ca "D:\Program Files\…" 会被切成 "D:\Program"
#      （实测踩到过，症状是启动行报「CA bundle 不存在：D:\Program」）
$key = "$env:TEMP\ai-key.txt"                       # 内容就是一行 sk-…
$ca  = "$env:TEMP\ai-ca-bundle.crt"                 # 从 Git 自带的拷一份，绕开空格
Copy-Item 'D:\Program Files\Git\mingw64\etc\ssl\certs\ca-bundle.crt' $ca -Force

# ② 起服务
.\club-server.exe serve 8080 mysql://root:clubroot123@127.0.0.1:3307/club `
    --data-dir build/ai-data `
    --ai-endpoint https://api.deepseek.com/v1/chat/completions `
    --ai-model    deepseek-chat `
    --ai-key-file $key `
    --ai-ca       $ca
```

启动时应看到一行 `[AI] …已启用`：
**只打印主机名**（路径与 query 会被剥掉），**密钥从不打印**。

HTTPS 形态同理，把 `serve` 换成 `serve-tls` 并加 `--cert/--key` 即可（见上一节）。

#### 8 个参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `--ai-endpoint <URL>` | 无 | **OpenAI 兼容的完整 URL**（要带 `/v1/chat/completions`）。**给了才启用 AI** |
| `--ai-model <名>` | 无 | 协议必填字段，如 `deepseek-chat` |
| `--ai-key-file <文件>` | 无 | 密钥文件路径。**只走文件**，不接受命令行直传（避免进 shell 历史） |
| `--ai-ca <文件>` | 无 | CA bundle（PEM）。**Windows 上必须给**（见下面坑 ③） |
| `--ai-timeout <秒>` | `30` | 读/写超时，允许 `1..300` |
| `--ai-max-concurrent <N>` | `4` | 同时在途的智能调用上限，允许 `1..64`（直达 Semaphore 计数） |
| `--ai-max-tokens <N>` | `2048` | 单次补全 token 上限，允许 `64..8192`（过小会截断输出→静默降级） |
| `--ai-insecure-trust-all 1` | 关 | ⚠ 跳过证书校验，**仅限本机开发**；**必须带值 `1`** |

> 参数越界**不会让服务起不来** —— 会在启动行说明**为什么没启用**，这是有意的
> （AI 配错不该拖垮整个服务端）。

#### 三个实测踩过的坑

1. **CA 路径不能含空格。** 项目的命令行按空格切分参数，`--ai-ca "D:\Program Files\…"`
   会被切成 `D:\Program`。→ 先 `Copy-Item` 到无空格路径（如 `$env:TEMP`）再用。
2. **端点是完整 URL**，不是 base。要写 `https://api.deepseek.com/v1/chat/completions`，
   只写 `https://api.deepseek.com` 会 404。
3. **`Default` 校验在 Windows 上必然失败**（`unknown CA(134)`），所以生产必须给 `--ai-ca`。
   ⚠ **Linux（含 WSL）上 `Default` 其实可用**（会读系统信任库，2026-10-06 实测四个公网站点全通），
   但本服务**一律要求显式给** —— Linux 上直接填系统那份：`--ai-ca /etc/ssl/certs/ca-certificates.crt`。
   纯本机图省事可 `--ai-insecure-trust-all 1`，但**别带进部署**。

> 出问题时（怎么判断状态、为什么全 fallback、429 怎么处理、审计在哪）
> 见 **[`llm-ops-guide.md`](llm-ops-guide.md)**。

#### 怎么验证 AI 真的通了

| 想验什么 | 命令 | 要库吗 |
|---|---|---|
| 参数与配置解析对不对、为什么没启用 | `tests\ai-check.ps1` | **不要**（serve 在连库前就打印 `[AI]` 行） |
| 协议与降级路径（可重复、不花钱） | `tests\ai-e2e.ps1` | 要 MySQL |
| **真的能调通模型** | `tests\ai-real.ps1 -KeyFile <仓库外的密钥文件> -CaBundle <CA>` | 要 MySQL，**且会花钱** |

三者的分工：`ai-check` 不需要库 / `ai-e2e` 用本地桩 / `ai-real` 打真实端点。
**前两个任何时候都该是绿的**；`ai-real` 只在改到出站链路或验收时跑。

#### 最少一步的接入验证

起好服务后，用会长登录拿 token，然后：

```powershell
# ⚠ 必须按 UTF-8 **字节**发 body：PS 5.1 传字符串默认用 ISO-8859-1，中文会变乱码
$json = @{ question = "我有哪些权限？" } | ConvertTo-Json
Invoke-RestMethod -Uri "http://127.0.0.1:8080/api/v1/ai/ask" -Method Post `
    -Headers @{ Authorization = "Bearer $token" } `
    -ContentType "application/json; charset=utf-8" `
    -Body ([Text.Encoding]::UTF8.GetBytes($json))
```

看返回的 `data.source`：`model` = 真模型答的；`fallback` = 走了规则兜底
（此时看启动行/`ai-check` 找原因）。**两者都是 HTTP 200**，别拿状态码判断 AI 是否可用。

### 生成部署包

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build-package.ps1
```

产出 `server\dist\club-server\`：exe + 4 个 DLL + `certs\` + 启动脚本 + 部署说明，约 **18.8 MB**。
整个目录拷到服务器即可运行（同平台，服务器不需要装编译器）。

---

## 当前进度

| 里程碑 | 内容 | 状态 |
| --- | --- | --- |
| **M1 骨架** | 构建链路 · Store 与原子落盘 · 统一响应/错误码 · 时间与时区 · `can()` 权限函数 · 认证 5 接口 · `/health` · 单测 + 冒烟测试 | ✅ **已完成** |
| **M2 组织与成员** | Part 3 的 **19 个接口**：部门增删改（会长独占）· 成员名录/详情/编辑 · 移出社团 · 待分配与**批量分配** · **会长移交（原子）** · 重置密码 · 注册口令 · 招募链接 | ✅ **已完成** |
| **M3 任务** | Part 4 的 **8 个接口**：我的任务（服务端分组）· 列表筛选 · 详情 · 创建（含 `client_token` 幂等）· 编辑/转交 · 状态流转与阻塞原因 · 软删除 · 日历同步 `lookup` | ✅ **已完成并验证** |
| **M4 课题** | Part 5 的 **6 个接口**：课题树（森林 + 递归进度）· 详情（面包屑 + 本级任务）· 创建（dept_id 只顶层）· 编辑 · 移动（**环形校验** + 深度 6 + 禁止跨部门）· 删除（**子节点上提，绝不级联**） | ✅ **已完成并验证** |
| **M5 部署** | 带 SAN 自签证书 · **框架原生 TLS**（1.2/1.3 通过、1.0/1.1 被服务端拒绝）· 部署包（exe + 4 DLL + 证书 + 启动脚本 + 说明，18.8 MB）· 从部署目录端到端跑通 | 🟡 **本机部分已完成**；公网部署验证**待服务器信息**（架构 / 公网 IP / 端口 / 防火墙） |
| **M6 评审缺陷修复** | 按 `docs/code-review.md` **第一轮**处理 24 条：3 个 P0 权限漏洞 · 8 个 P1 · 13 个 P2（23 条改代码 + 1 条仅记录），并补上会真正失败的回归断言 | ✅ **已完成并验证** |
| **M7 第二轮评审** | `docs/code-review.md` 第二轮：独立复验第一轮 24 条（全部确认修复）+ **9 条新发现**（N-1…N-9） | ✅ **已完成**——9 条全部处理（N-8 按约定不改）：N-1（落地页转义）/ N-2 / N-3 / N-4 / N-5（`idem` 补校验）/ **N-6（注册节流改按客户端 IP + 递增退避，未新增接口 → 仍是 39 / 39）** / **N-7（不可作用于同权或更高权的人，已推广到改名 / 改角色 / 禁用）** / N-9（CSP），每条都带"回退即变红"的回归断言。当轮基线 **300 / 347 / 22 全绿** |
| **M8 第三轮复验** | `docs/code-review.md` 第三轮：复验第二轮 9 条 + **4 条新发现**（N-10…N-13） | ✅ **已完成**——第二轮 9 条全部确认修复；**N-10**（`assign` / `assign-batch` 未纳入同权保护，副会长可降级同权者、甚至用 `assign` 推翻会长的移出决定）已修，批量改为逐条判定；N-11 / N-12 / N-13 均已按建议处理。当轮基线 **300 / 347 / 22 全绿** |
| **M9 轻舟升级** | 升级到 `3ea387e`（上游 `141a735` 修好 DEF-1，本地补丁撤销）+ 适配 CangDB 不可用的 RBAC 层（CangDB 已开源，但其 1.0.5 版本与 cjc 1.1.3 不兼容：编译通过、运行超时；改用 `fw_rbac_store.cj` 文件存储数据层 + `fw_rbac.cj` 的 `requirePermission`） | ✅ **已完成并验证**：撤补丁后 TLS 重跑 **22 / 0 全绿**；当轮基线 **322 / 347 / 22 全绿** |
| **M10 容量与性能** | 可复现容量基准（`server/tests/bench.ps1`，真实 HTTP + 与旧提交编译的 exe 对比）· 四项改造：列表排序插入→**堆排序** · **PBKDF2 移出全局锁** · 过期**令牌回收** · 整库落盘移出锁 | ✅ **已完成并验证**：4 并发登录 **1574 → 867 ms**（串行因子 0.99 → 0.56）是唯一有量级收益的一项；排序与落盘在千人档落在噪声带内，价值是**最坏情况下界**与**库变大后的锁占用**。**当轮基线 349 / 347 / 22 全绿**（2026-09-15，见 `capacity-baseline.md`） |
| **M11 第四轮复验修复** | `docs/code-review.md` 第四轮 6 条：**N-14** 本机判定改按地址相等（原为子串匹配 `::1`，可被远程 IPv6 关停服务）· **N-15** 四个 handler 改两阶段赋值（被 4xx 拒绝不再留半改状态）· **N-16** 登录两条路径等价 PBKDF2（堵住时序枚举手机号）· **N-17** 审计 IO 移出锁 · **N-18** 任务与课题必须同部门 · **N-19** 招募 token 32 字节 | ✅ **已完成并验证**：新增单测闸门 `testLoopbackPeer` / `testLoginCreds` / `testAuditDeferred` 与冒烟 §22.5。**当轮基线 387 / 360 / 22 全绿**（2026-09-15） |
| **M12 按 UI 设计规格对齐** | 《鸿蒙俱乐部-全场景UI设计规格》13 页逐条对照（报告 `docs/ui-spec-conformance-review.md`），按决定落地 8 条：**D-1** 权限摘要 5 个管理布尔 · **D-2** 名录 `?q=` 搜索 · **D-3** 任务/课题**读**范围放开到全社团（**写**不变）· **D-4** 阻塞任务求助对象 `needs_help` · **D-5** `overdue_days` · **D-7** 成员详情补 `done_tasks`/`overdue_tasks` · **D-15** 首页阻塞原因 · **D-16** 招募链接预填闭环（接口 39→40）。**D-6** 密码口径定稿 **8–32 字节 + 只允许数字/英文/符号** | ✅ **已完成并验证**：**当前基线 471 / 421 / 22 / 契约 30 全绿**（2026-09-16） |
| **M13 轻舟升级 + 自带后台** | 内置框架升到 **`e072980`**（= 上游 HEAD；`src/` 29 → **36** 个文件，新增 `jwt` / `ratelimit` / `securityheaders` / `websocket` / `httpclient` / `hybrid` / `circuit`）；新增 **`build.ps1 -Target admin`** → `build\admin\admin.exe`（上游 `examples\admin.cj` + 预构建 `admin-web\dist`，**部署机不需要 Node/npm**），数据层复用 `fw_rbac_store.cj` **落到本地 JSON 文件**；新增 `tests/admin-check.ps1` 端到端把关 | ✅ **已完成并验证**：**五套全绿 471 / 421 / 22 / 契约 30 / 后台 29**（2026-09-16）。附带查清上游"业务码在 body 的 `code`、成功响应也可能带 HTTP 404"这一特性（`API-NOTES` 坑 34，**不改内置框架**） |
| **M14 「社团管理」运维页** | 后台加一页 `/club`：入口换成我们自己的 `server/src/ops/admin_main.cj`（上游那套路由 + `/api/club/**` + 链尾 `statusNormalizer()` 修状态码）；`club_view.cj` 提供社团库**只读**白名单视图（概览/名录/部门/任务/课题/招募链接/审计）；`club_json.cj` 让 Store 三文件编进这条构建。**读**直连 MySQL，**写**以专用运维账号的身份走 club-server 真实 API；前端另起 `server/admin-web`（上游版本 + `Club.vue`） | ✅ **已完成并验证**：**运维页端到端 42 / 0**（`tests/ops-check.ps1`）。顺带修了 `POST /admin/shutdown` 回执被吞的既有缺陷（实测 8 次里 6 次空 body）——见 `API-NOTES` 坑 36 |
| **M15 运维身份 `ops`** | 新增内置身份 **`ops`**（运维不该由会长执行）：`roleRank` 与会长同档、`roleAllows` 除「移交会长」外全放行、`scopeAllows` 全社团、`checkAccess` 豁免"同档不可互处置"（所以能处置会长）；**不可由 API 分配**，只能 `club-server init-ops` / `retire-ops`。运维台侧：`admin.env` 加 `club_user`/`club_pass`，新增 `/api/club/session`（后台代持换令牌），前端去掉会长登录表单；顺带修掉角色代号写错（`lead`/`vice_lead` 被误写成 `minister`）、补齐部门新增/改名的审计 | ✅ **已完成并验证**：**单测 490 / 冒烟 422 / 运维页端到端 52** 全绿。闸门：运维能换注册口令/建部门/重置会长口令，但**移交会长必须 403**；`ops` 不能 API 分配；审计 `actor` 是"运维" |

**接口进度：40 / 40**（认证 5 + 组织与成员 20 + 任务 8 + 课题 6 = 39 个业务接口，另加运维 `/health`）。
另有一个不在接口清单里的公开页面 `GET /join/{token}`（招募链接落地页，无需登录）。
> 后台/运维页的接口（`/api/login`、`/api/club/**` 等）**不属于**上面这 40 个业务接口，
> 它们是运维工具自己的面，见 `server/src/ops/`。

---

## 代码结构

```
server/
  build.ps1               构建脚本（cjc + stdx + 轻舟同包编译；构建前先校验内置框架的内容清单；工具链自动探测；`-Target admin` 另出轻舟后台）
  build.cmd               build.ps1 的包装（免 -ExecutionPolicy Bypass）
  third_party/qingzhou/   内置的轻舟框架源码（36 个 .cj + examples/admin.cj + admin-web/ 含预构建 dist + LICENSE；OpenSSL 两个 DLL 不提交，构建时自动找；出处见其 PROVENANCE.md）
  src/
    main.cj               入口：serve / init-admin / init-ops / retire-ops / test + 全部路由注册
    store.cj              Store 数据模型与 JSON 字段映射
    store_persistence.cj  文件后端加载、快照与原子落盘
    store_queries.cj      查询、排序、幂等与课题树辅助
    errors.cj             错误码表（api-design §1.3 的代码化）
    jsonw.cj              响应包装 {ok,data}/{ok,error} + 取参 + 字段校验器
    views.cj              对外 JSON 视图（人/部门/任务/课题/链接/注册配置）
    perms.cj              ★ can(member, action, target) —— 全项目唯一权限判定点
    auth.cj               口令哈希（PBKDF2-HMAC-SHA256）、令牌、认证辅助
    timex.cj              时间与时区（ISO8601 +08:00、逾期判定、历法换算）
    ids.cj                ID / 令牌 / 易读口令
    strx.cj               字节级字符串工具
    paging.cj             分页与 query 取参（page/size，pathId）
    audit.cj              敏感操作审计日志（重置密码、换口令、删除部门/课题…）
    h_auth.cj             Part 2 认证（5）
    h_dept.cj             Part 3.1 部门（4）
    h_member.cj           Part 3.2–3.4 名录/授权/会长移交（8）
    h_secret.cj           Part 3.5–3.6 重置密码与注册配置（4）
    h_link.cj             Part 3.7 招募链接（3）
    h_task.cj             Part 4 任务（8）
    h_plan.cj             Part 5 课题（6）
    h_ops.cj              健康检查、本机判定
    fw_rbac_store.cj      轻舟 RBAC 数据层的本地适配（文件存储；替代依赖 CangDB 的上游版）
    fw_rbac.cj            轻舟 requirePermission 中间件的本地适配（改用我们的错误格式）
    tests.cj              单测（club-server.exe test）
  src/ops/                运维台（build.ps1 -Target admin）专用；**不参与服务端构建**（取的是 src/*.cj，不递归）
    admin_main.cj         运维台入口：上游后台路由 + /api/club/** + 状态码修正
    club_view.cj          社团库只读视图（概览/名录/部门/任务/课题/链接/审计；白名单字段，不含口令材料）
    club_json.cj          jsonw.cj 里 6 个工具的自包含替身（让 Store 三文件编进运维台）
  admin-web/              运维台前端（Vue 3 源码 + 预构建 dist；比上游多了 views/Club.vue）
  tests/smoke.ps1         冒烟测试（打真实 HTTP）
  tests/tls-check.ps1     TLS 验证（curl + openssl，避开 PS 5.1 自签证书的怪癖）
  tests/client-contract-check.ps1  前后端契约回归（客户端声明的每条路径/方法，服务端都认得）
  tests/admin-check.ps1   后台自身端到端（RBAC + MySQL 数据层：登录/增删/落盘/优雅关闭）
  tests/ops-check.ps1     「社团管理」运维页端到端（直连 MySQL 读库 + club-server 写路径 + 审计 + 备份）
  tests/bench.ps1         容量基准（真实 HTTP；可对旧提交编译的 exe 做前后对比）
  tests/ai-check.ps1      AI 参数与配置解析（**不需要 MySQL**；serve 在连库前就打印 [AI] 行）
  tests/ai-e2e.ps1        AI 五个接口端到端（真库 + 真服务 + 真 HTTP + 可控桩 ai-stub.mjs）
tests/ai-real.ps1       AI **真实模型**联调（打公网端点；验桩验不出来的东西，会花钱）
```

> **AI 模块的三套测试（2026-10-06 更新）**：分工是「不需要库 / 本地桩 / 真模型」三层。
> `ai-check.ps1` 说明见文件头 ——
> 它的 DSN **故意指向不可达端口**，这样 `serve` 必然连库失败并自然退出，
> 启动日志才拿得到（本地 3307 上通常跑着 MariaDB，指向它会让进程一直活着、
> 被强杀时 stdout 块缓冲丢失 → 日志 0 字节 → 否定式断言恒真，见 R-2）。
> `ai-e2e.ps1` 需要 `server/build/club-server.exe` 与本机 MariaDB（3307）；
> 它内含 **AI-2 的真实回归闸门**：用 `spike/llm-truncation/stub.mjs` 分块慢发
> （1000 字节 / 20ms）一个 20 KB 的回答，断言 `source=model` ——
> 若把 `AiTransport` 换回框架的 `StdxTransport`，响应会被短读截断而变红。

> 编译期 API 事实清单与踩坑记录已移到 **`docs/API-NOTES.md`**（2026-09-14 整理仓库时统一归入 `docs/`）。

---

## 测试

> ⚠ **2026-09-20 起，下面除单测外都需要一台可连的 MySQL/MariaDB。**
> 四个会起 club-server 的脚本各自用**专用测试库**（`club_smoke` / `club_tls` / `club_contract` /
> `club_ops_e2e`），开头显式探测可连性，**取不到就判 FAIL 并以非零码退出**（不静默跳过）。
> 默认连 `127.0.0.1:3307`，可用 `CLUB_MYSQL_HOST/PORT/USER/PASS/DB` 覆盖；共用夹具在
> `server\tests\mysql-common.ps1`（**2026-10-04 起默认带 `--skip-ssl`**，要开 SSL 用 `CLUB_MYSQL_USE_SSL=1`；
> 连接失败时会把客户端真实 stderr 打出来）。
> 当前基线（2026-10-04 复验）：单测 **595**（带 DSN **648**）· 冒烟 **440** · 契约 **37** ·
> 姓名选项 **45** · 后台 **38** · 运维页 **82** · 前端逻辑 **17**，全部 **FAIL 0**；
> **TLS 4 通过 / 3 失败** —— 那 3 条是**既有环境性失败**（`server/certs` 被 gitignore、本地证书 2026-09-17；
> 未改动的旧二进制同样复现），**不是回归**，别读成"TLS 绿"。

```powershell
# 单测（**不需要数据库**）：时间/历法、口令哈希、权限矩阵、注册节流、落盘往返与坏记录拒绝、
# 视图/分页、任务分组、课题树与聚合、堆排序边界、令牌回收、两段式落盘契约、轻舟 RBAC 适配层、
# 本机判定（N-14）、登录口令材料（N-16）、审计缓冲（N-17）（595 项）
.\build\club-server.exe test
# 再给一个 DSN，会额外跑一次 MySQL 持久化往返 + 增量落盘验证（+53 项 → 648；含 4 字节字符的 utf8mb4 回归断言）
.\build\club-server.exe test "mysql://root:clubroot123@127.0.0.1:3307/club_test"

# 冒烟：真实 HTTP、状态码、错误码、权限边界、幂等、环形校验、删除上提、审计日志、
# 落地页转义与 CSP、重启持久性、被拒请求不留半改状态、UI 规格对齐（D-1…D-7）、
# §27 请求体闸门 11 条（413/415/411/非法 JSON/非 UTF-8）（440 项）
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\smoke.ps1

# TLS：证书 SAN、TLS 1.2/1.3 通过、1.0/1.1 被拒、真证书校验下走一遍登录
#（2026-10-04 本机实测 4 通过 / 3 失败，失败为既有环境性 —— server\certs 不入库、本机证书是 2026-09-17 的旧件）
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\tls-check.ps1

# 前后端契约：客户端声明的每条路径与方法（37 项）
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\client-contract-check.ps1

# init-admin 的会长姓名选项（ASCII / --name-file / BOM / 空白 / 非空库拒绝）+ 「不给 DSN 时要先喊出来」（45 项）
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\init-name-check.ps1

# 轻舟后台端到端（38 项；先 build.ps1 -Target admin；需要 MySQL）
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\admin-check.ps1

# 「社团管理」运维页端到端（82 项；会自己起 club-server(18081) 与运维台(18099)）
#   端口可传参：-OpsPort / -ClubPort（默认 18099 / 18081，刻意避开 Windows 保留区间 3002–3101）
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\ops-check.ps1

# 容量基准（按需，不属于关卡）：单发耗时 + 4 并发墙钟；
# 用 -Exe 指向旧提交编译出的 exe，即可做同脚本、同数据形状的前后对比（见文件头注释）
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\bench.ps1
```

单测覆盖纯逻辑（脱离 HTTP），冒烟测试覆盖接口层行为，契约套件盯"客户端与服务端的口径不漂移"，
后台套件盯轻舟那份产物（**RBAC 与社团库都在 MySQL**）。
冒烟/契约/TLS/运维页各自用**专用测试库**（`club_smoke` / `club_contract` / `club_tls` / `club_ops_e2e`），
**不会碰你的正式库**；容量基准用 `club_bench`。审计日志仍写在各自独立的 `build\*-data` 目录下。

> 容量数据、四项性能改造各自的真实收益（以及**没测出收益**的那两项）见 **`capacity-baseline.md`**。

---

## 设计约定（改代码前先读）

HANDOFF §5 的五条原则在这里的落点：

| 原则 | 落点 |
| --- | --- |
| **同一事实只存一份** | 口令拆成 `pw_salt/pw_hash/pw_iter` 字段，不存复合字符串；`Plan.dept_id` 只顶层 |
| **能推导的就不存** | 逾期由 `due_at` 算（`isOverdue`）；课题进度由任务聚合（M4） |
| **绝不级联删除** | 任务软删除 `deleted_at`；删课题子节点上提（M4） |
| **权限收敛到一个函数** | `perms.cj` 的 `checkAccess` / `requireAccess`；**禁止在 handler 里手写权限 if** |
| **服务端权威** | `updated_at`、逾期、分组、`is_overdue` 全部服务端生成 |

### 两条实现纪律

1. **锁纪律**：`requireMember` / `requireActive` **内部会加 `s.lock`**，调用它们时绝不能已持有该锁
   （Mutex 不可重入，会死锁）。handler 的统一形状是：**先认证拿 Member，再单独加锁做修改**。
2. **空值约定**：`Int64` 用 `0` 表示"无"（`parent_id=0` 顶层、`plan_id=0` 独立、时间 `0` 为 null）。
   1970 年不会成为真实业务值。

---

## 已知待确认项

见 `HANDOFF.md` §7 与本次 M1 报告；其中一项是**文档内部冲突**：

- `api-design.md` §3.1 / §6.1 写 `DELETE /depts/{id}` **限会长**，§3.8 汇总表写「部门增删改 ✅✅（含副会长）」。
  当前实现按**更严格**的一侧（会长独占），代码里已标注待确认。
