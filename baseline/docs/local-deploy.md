  # 本机部署服务端（Windows）· 一页上手

> **给第一次在本机把服务端跑起来的人**：照抄命令即可。全流程已在 **2026-09-16 本机实测通过**
> （下面的输出都是当次真实结果）；**2026-09-20 数据层换成 MySQL 后按新命令复验通过**
> （见 §2.0 / §6）。
>
> 🚀 **只是要"起起来联调"？跳到 §0.5**（三条命令 + `server\dev-serve.ps1` 一键脚本，
> 它会顺手起数据库并把客户端该填的地址打出来）。
>
> ⚠ **硬前提（2026-09-20 起）：要有一台可连的 MySQL / MariaDB。** 理由与做法见 §2.0 ——
> club-server 的持久化已从 `data/db.json` 换成 MySQL（`docs/club-server-mysql-assessment.md`）。
>
> 本文只给「最短能跑通的路 + 最容易踩的坑」。细节与权威定义在别处：
> `server-guide.md`（构建/运行/测试全貌）· `deploy-windows-verify.md`（拷到服务器那一步）·
> `API-NOTES.md` §5（会让**所有**仓颉 exe 启动即崩的 Windows 更新）· `client-build.md`（客户端构建）·
> `api-design.md`（接口唯一权威）· **`mysql-backend.md` §十二**（club-server 迁 MySQL 的落地记录）。

---

## 0. 两个形态，先选一个

| 形态 | 用途 | 怎么做 |
| --- | --- | --- |
| **① 在 `server\build\` 里直接跑** | 本机联调（客户端连它） | §2 的部署顺序，或 **§0.5 的三条命令** |
| **② 产出 `server\dist\club-server\`** | 可整体拷走（换机器 / 上服务器） | §4 |

---

## 0.5 联调速查（**只想赶紧把服务起起来，看这一节就够**）

```powershell
cd E:\harmonyOS\cangjie_web\server

# ① 第一次要先出 MySQL 驱动产物（只须一次，不入库）；以后只跑 build.cmd

> 📁 **本机部署一页上手** ｜ 本文件：`local-deploy.md` ｜ [全部文档目录](README.md)
powershell -NoProfile -ExecutionPolicy Bypass -File .\build-mysql-driver.ps1
.\build.cmd

# ② 空库要先建会长（一次就够；换库名 / 清过库才需要再来一次）
cd build
.\club-server.exe init-admin 13800000000 ClubPass2026 "mysql://root:clubroot123@127.0.0.1:3307/club_server"

# ③ 起服务 —— 数据库没起它会顺手帮你起，并把客户端该填的地址打出来
cd ..
powershell -NoProfile -ExecutionPolicy Bypass -File .\dev-serve.ps1
```

`dev-serve.ps1` 的真实输出（**客户端地址照抄这一行就行**）：

```
[dev] 数据库 127.0.0.1:3307 已在听（不重复启动）
[dev] DSN：mysql://root:clubroot123@127.0.0.1:3307/club_server
[dev] 客户端 Env.ets 里的 DEV_BASE_URL 该填：
[dev]   模拟器（和本服务同一台电脑）   http://10.0.2.2:8080/api/v1
[dev]   真机 / 队友的电脑（同一局域网） http://10.194.233.104:8080/api/v1
[dev]   本机自测（curl）               curl.exe http://127.0.0.1:8080/health
[dev] 启动：club-server.exe serve 8080 <DSN> --data-dir data
[db] 已从 MySQL 载入：成员 1 人  课题 0 个  任务 0 个  部门 4 个
监听 0.0.0.0:8080（同一局域网内用本机 IP 即可访问；仅本机调试用 127.0.0.1）
```

| 谁在跑 | 连什么地址 | 备注 |
| --- | --- | --- |
| 客户端的**模拟器**（和你在同一台电脑） | `http://10.0.2.2:8080/api/v1` | `10.0.2.2` 是模拟器眼里的"宿主机"；`Env.ets` 默认就是它 |
| 客户端的**真机** / 队友的电脑 | `http://<你的局域网IP>:8080/api/v1` | 查 IP 见 §5.2，防火墙见 §5.3 —— **这两条是"连不上"的全部原因** |
| 你本机的 curl / 浏览器 | `http://127.0.0.1:8080/health` | 服务端默认绑 `0.0.0.0`，上面三种地址同时可用 |

**常用开关**：

```powershell
.\dev-serve.ps1 -Port 9000            # 换端口
.\dev-serve.ps1 -Db club_alice        # 换库（每人一个联调库，互不干扰）
.\dev-serve.ps1 -NoDb                 # 数据库我自己起好了 / 在别人机器上，别管它
.\dev-serve.ps1 -DbOnly               # 只把数据库弄起来，不起服务
.\dev-serve.ps1 -Tls                  # 走 HTTPS（证书要有客户端实际访问地址的 SAN，见 §5.5）
```

**停服务**：`curl.exe -s -X POST http://127.0.0.1:8080/admin/shutdown`（优雅关闭，仅本机可调），
或前台窗口里直接 Ctrl+C。**起服务前**要写库的命令（`init-admin` / `init-ops` / `retire-ops`）
必须先做完 —— 原因见 §2 开头那条铁律。

> 下面 §1～§7 是**完整版**：每一条为什么这么做、每个坑长什么样、出问题怎么对号入座。
> 联调只走上面这条最短路径时不用读；**一旦哪一步不对**，再回来按编号查。

---

## 1. 前置体检（四条，缺一条就白折腾）

```powershell
# ① 仓颉 SDK + stdx：build.ps1 会自己找（显式传参 > 常见安装位置 > CANGJIE_HOME > PATH），
#    并**按版本优先挑本项目基线的 1.2.0** —— 所以不要求装在 D:\Cangjie 这种固定位置。
#    要知道它到底挑了哪套：跑一次 §2.1，看开头的 [build] 工具链： 两行。
#    本项目基线：cjc 1.2.0 + stdx 1.1.3.1（版本不符会直接停止，见 §2.1 与 §7 坑表）

# ② 那个会让所有仓颉 exe 启动即崩的 Windows 更新必须不在
Get-CimInstance Win32_QuickFixEngineering | Where-Object HotFixID -eq 'KB5124010'
#    有输出 → 先卸载它（完整证据见 docs/API-NOTES.md §5）；本次实测结果是「已卸载 ✓」

# ③ PowerShell 5.1 默认禁止跑脚本：调用 .ps1 一律带 -ExecutionPolicy Bypass
#    （嫌麻烦就用 server\build.cmd —— 包装脚本，已带好该参数，双击也能跑）

# ④ **一台可连的 MySQL / MariaDB**（2026-09-20 起是硬前提，见 §2.0）
```

> ⚠️ 第 ② 条**必须先过**：KB5124010 装着时服务端 exe 一启动就 `exit=-1073741819`（`0xC0000005`），
> 看着像代码崩了，其实与代码无关。本项目已经踩过两次（§5.1 / §5.5）。

---

## 2. 部署顺序（**照这个顺序做，别跳步**）

> **只有一条铁律：凡是要写库的命令，都必须在「起服务」之前做完。**
> 这类命令有三个：`init-admin`（建社团库）· `init-ops`（建/改运维账号）· `retire-ops`（停用运维账号）。
>
> 原因：`club-server` **只在启动时**把整库读进内存一次，运行期间**别的进程改库它不会知道**。
> 所以「先把服务起了、再回头建运维账号」会得到一个**登录一直 401**、
> 而运维页「成员名录」里**却看得见**这个账号的怪状态 —— 这是最容易误判成"口令填错了"的坑，
> 也是本节为什么要把两条初始化命令都排在起服务之前。详见 §2.7 末尾的现象对照表。
>
> 顺序总览：**2.0 起一台 MySQL → 2.1 编译（要先出驱动产物）→ 2.2 一次性初始化（会长 + 运维账号）→
> 2.3 起服务 → 2.4 验证 →（要运维台就接着 2.7）**；2.5 / 2.6 是运行期的事，随时可做。

### 2.0 起一台 MySQL（**2026-09-20 起的新前提**）

club-server 的持久化已从"整库重写 `data/db.json`"换成 **MySQL**（路线 B：只换持久化层，
`docs/club-server-mysql-assessment.md`）。**库和表都不用手工建** —— 首次连接时程序自己
`CREATE DATABASE IF NOT EXISTS` + 建 9 张表。

本机联调用的是**便携版 MariaDB**（免管理员、不注册 Windows 服务、非默认端口 3307）：

```powershell
# 起服务（前台；关掉窗口就停）
& "E:\cangjie\mariadb\mariadb-11.4.13-winx64\bin\mysqld.exe" --defaults-file="E:\cangjie\mariadb\data\my.ini" --console

# 确认它在听 3307
Test-NetConnection 127.0.0.1 -Port 3307 | Select-Object TcpTestSucceeded
```

下面所有示例统一用这个 DSN：

```powershell
$dsn = "mysql://root:clubroot123@127.0.0.1:3307/club_server"
```

> - 口令里若含 `@ : / ? #`，在 DSN 里写成 `%40` 这样的**百分号编码**；
>   或改用命名参数（`--mysql-host/--mysql-port/--mysql-user/--mysql-pass/--mysql-db`）。
> - **不支持环境变量配置**：本工具链的仓颉 std 没有 `getEnv`，只能走命令行。
> - 库名只允许字母/数字/下划线/`$`（它会拼进 `CREATE DATABASE`，程序会先校验）。
> - 端口 3307 只是**本机联调**那台的；MySQL 出厂默认是 **3306**，换了服务器记得改。

### 2.1 编译

```powershell
cd E:\harmonyOS\cangjie_web\server
powershell -NoProfile -ExecutionPolicy Bypass -File .\build-mysql-driver.ps1   # 先出 MariaDB 驱动产物（只须一次，不入库）
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
# 等价写法（免记 Bypass、可双击）：.\build.cmd
```

真实输出（**开头三行是工具链 —— 先看清它挑了哪套 SDK**）：

```
[build] 工具链：cjc=D:\Cangjie
[build]          stdx=E:\cangjie\stdx\windows_x86_64_cjnative\static\stdx
[build]          cjc 版本：Cangjie Compiler: 1.2.0 (cjnative)
[build] 框架：轻舟 3d6c1a3（内置 third_party\qingzhou，38 个文件参与编译，含 db.cj + db_mysql.cj）
[build] 服务端 27 个文件 -> ...\server\build\club-server.exe
[build] 数据层：MySQL（src\mysql_store.cj + 驱动 ...\server\build\mysql-driver）
[build] 编译通过
[build] OpenSSL DLL 来源：D:\Program Files\Git\mingw64\bin
[build]   libcrypto-3-x64.dll  3.5.7  0330b5f558996f29…  与 EXPECTED 一致
[build]   libssl-3-x64.dll  3.5.7  feb5b300e0b3a021…  与 EXPECTED 一致
[build] 已复制 4 个依赖 DLL 到 build\
```

- **`build-mysql-driver.ps1` 必须先跑一次**：产物在 `build\mysql-driver\`（不入库）。
  缺了它 `build.ps1` 会直接 `throw` 并告诉你去跑它 —— 不会让你编出一个"能编过、一启动就报
  未注册驱动"的 exe。
- **不需要仓库外的轻舟**：框架已内置在 `server\third_party\qingzhou`，构建时逐字节校验内容清单；
  上游版本记在其中的 `UPSTREAM_COMMIT`，每次构建都会打印。
- **4 个 DLL 自动就位**（2 个来自仓颉 SDK、2 个 OpenSSL 由脚本按
  「内置目录 → `-OpenSslDir` → Git for Windows」解析），**不用手工拷**。
- 只要编译、不拷 DLL：加 `-NoDll`。
- **换一台机器不用改脚本**：`cjc` 与 `stdx` 的位置**不再写死**。探测顺序是
  显式 `-CangjieHome` / `-Stdx` → 常见安装位置（`D:\Cangjie`、`C:\Cangjie`、`E:\Cangjie`、
  `%USERPROFILE%\Cangjie`…）→ `CANGJIE_HOME` / `CANGJIE_STDX` → `PATH`，且**按版本优先 1.2.0（本项目基线）**。
- **装了 cjenv 之类版本管理器的人注意**：它会把全局 `CANGJIE_HOME` 改写成它自己的 SDK
  （本机是 1.0.5）。挑到非 1.2.0 时脚本会先打 `WARNING`、编译前还会**硬校验** 1.2.0 —— cjc 与 stdx 版本串台的症状是
  编译中途 `LLVM ERROR: Broken module found`，看着像编译器 bug，其实只是环境串台。
  显式传了错路径也会被明确告知，**不会静默忽略**。
- **上一个服务端没停干净**：`ld.lld: error: failed to write the output file: Permission denied`
  —— 这不是权限/SDK 问题，而是 exe 还在运行。脚本会先自查，并直接给出处置命令。

### 2.2 一次性初始化（**两步都在起服务之前**）

> ⚠ **先看清这条最常见的坑：`$dsn` 必须先定义，而且要在同一个窗口里。**
> PowerShell 里引用一个**从未定义**的变量**不会报错**，它就是空串 —— 于是
> `.\club-server.exe init-ops 13800000009 123456789 $dsn` 会变成"位置参数空着"，
> 程序**静默退回默认值**（127.0.0.1:**3306** / root / 空口令 / club_server），
> 报出来的却是 `Failed to connect 10061` —— 看起来像端口配错或数据库没起，
> 其实是参数根本没传进来（本机联调那台 MariaDB 在 **3307**，所以必错）。
>
> **两种写法都不会踩**：① 整块复制（下面代码块里 `$dsn` 与用法在一起）；
> ② 干脆写死 DSN，不用变量：`.\club-server.exe init-ops 13800000009 <口令> "mysql://root:clubroot123@127.0.0.1:3307/club_server"`。
> 现在程序也会在连接前把这件事喊出来（`[db] ⚠ 命令行没有给 DSN / --mysql-*，正在使用默认连接参数…`）。

```powershell
$dsn = "mysql://root:clubroot123@127.0.0.1:3307/club_server"
cd E:\harmonyOS\cangjie_web\server\build   # ← ⚠️ 必须进到 exe 所在目录：审计日志目录与证书都按**相对路径**读

# ① 建社团库 + 首任会长（**只对空库可执行**）。库/表/元数据都在这一步被自动建出来。
.\club-server.exe init-admin 13800000000 ClubPass2026 $dsn

#    想给会长起个真名（不叫默认的「会长」）就加姓名选项。
#    ⚠ 中文**不能**直接写在命令行里 —— 仓颉把 argv 拼成 String 那一步就崩，
#      早于 main 里任何校验（见 API-NOTES 坑 11）。所以中文姓名放进 UTF-8 文本文件：
[IO.File]::WriteAllText("$PWD\president-name.txt", "张三", [Text.UTF8Encoding]::new($false))
.\club-server.exe init-admin 13800000000 ClubPass2026 $dsn --name-file president-name.txt
#    ASCII 姓名可以直接给：   ... init-admin 13800000000 ClubPass2026 $dsn --name LiSi
#    两个都不给 = 默认「会长」

# ② 建运维账号（**只有要用运维台才需要**；幂等，可重复执行来重设口令）
.\club-server.exe init-ops 13800000009 <运维口令> $dsn
```

**① 真实输出**：

```
[db] 连接 mysql://root@127.0.0.1:3307/club_server pass=***
[db] sql_mode 为标准反斜杠转义模式（参数绑定已按此口径转义）
[db] 已从 MySQL 载入：成员 0 人  课题 0 个  任务 0 个  部门 0 个
已创建首任会长：会长（13800000000，成员 id=1，部门=1）
当前注册口令：DYMRXD          ← 随机 6 位，发给社团成员注册用，会长可随时更换
业务数据已在 MySQL：mysql://root@127.0.0.1:3307/club_server pass=***
审计日志目录：data（audit.log）
```

> 第一行括号里是手机号；**用了 `--name-file` / `--name` 时它显示你给的名字**（例：`已创建首任会长：张三（…）`）。
> 姓名只要求非空白，与 App 里 `PATCH /api/v1/members/{id}` 改姓名同一口径。
> 建完之后会长自己在 App 里也能改名，所以这纯粹是"省得再改一次"。
> **口令在日志里永远是 `pass=***`** —— 迁移后新增的这三行 `[db]` 不泄露任何凭据。

同时预置 4 个组织：**主席团 / 课题部 / 运营部 / 宣传部**。
想确认数据真的在库里（这也是一条很好的自检）：

```powershell
& "E:\cangjie\mariadb\mariadb-11.4.13-winx64\bin\mariadb.exe" -h 127.0.0.1 -P 3307 -u root "-pclubroot123" `
  --protocol=tcp --table club_server -e "SELECT id,name,phone,role,dept_id,status FROM members; SELECT id,name,sort FROM departments;"
```

**② 真实输出**（最后四行是 2026-09-17 新加的告警，正是为了拦住"先起服务再 init-ops"）：

```
[db] 连接 mysql://root@127.0.0.1:3307/club_server pass=***
[db] sql_mode 为标准反斜杠转义模式（参数绑定已按此口径转义）
[db] 已从 MySQL 载入：成员 1 人  课题 0 个  任务 0 个  部门 4 个
已创建运维账号：13800000009（成员 id=2，角色 ops）
权限：除「移交会长」外与会长同权；不可由 API 分配，只能用本命令创建
下一步：用这个手机号 + 口令**直接登录运维台**（http://127.0.0.1:3000/）就行
        （也可以把凭据填进 build\admin\admin.env 的 club_user / club_pass 让后台代持，二选一）
业务数据已在 MySQL：mysql://root@127.0.0.1:3307/club_server pass=***

⚠ 如果 club-server **正在运行**，它内存里还是旧的库 —— 必须**重启 club-server**，
  上面这个账号才能登录（否则登录一直 401，而运维页的名录里却看得见它）。
  正确顺序：先 init-ops，再启动 club-server；已经起了就先停掉再起。
```

> **口令规则**（`init-admin` / `init-ops` / 注册 / 改密同一口径）：**8–32 字节**，
> 只能用**数字 / 英文 / 符号**（不能有空格、中文、全角字符）。
> 所以 8 位纯字母数字虽然合法但很弱，对外部署请换掉。
> **运维账号在 App 的名录里看不到**（服务端过滤掉系统账号，免得客户端显示成"待分配"），
> 只在运维台的「成员名录」里显示为「运维」。
> 退役：`.\club-server.exe retire-ops 13800000009 $dsn`
> （`retire-ops` 同样写库，所以**也要放在起服务之前**，或做完重启服务）。

### 2.3 起服务

```powershell
# 最省事：一条命令（数据库没起会顺手帮你起，并打印客户端该填的地址）—— 见 §0.5
..\dev-serve.ps1

# 等价的手工写法：
# HTTP（本机联调最省事）
.\club-server.exe serve 8080 $dsn

# HTTPS（手机端正式使用走这条，见 §3）
.\club-server.exe serve-tls 8443 $dsn --cert certs\cert.pem --key certs\key.pem

# 不给 DSN 也可以用命名参数（没给的项取默认值）
.\club-server.exe serve 8080 --mysql-host 127.0.0.1 --mysql-port 3307 --mysql-user root --mysql-pass clubroot123 --mysql-db club_server

# 要让「招募链接」发给队友也能点开，就显式告诉服务端"对外是哪个地址"（见 §2.6）
.\club-server.exe serve 8080 <DSN> --public-url http://10.194.17.0:8080
```

启动横幅会明写**绑定地址**（联调时最该看的一行）：

```
社团管理工具 · 服务端 v0.1.0
监听 0.0.0.0:8080（同一局域网内用本机 IP 即可访问；仅本机调试用 127.0.0.1）
  mysql://root@127.0.0.1:3307/club_server pass=***  成员 1 人  课题 0 个  任务 0 个
QingZhou listening on 0.0.0.0:8080
```

前台运行日志直接打控制台；要后台跑（联调时常用）：

```powershell
$p = Start-Process .\club-server.exe -ArgumentList @("serve","8080",$dsn) -PassThru -WindowStyle Hidden `
       -RedirectStandardOutput server.out.log -RedirectStandardError server.err.log
```

端口被占用先查：`netstat -ano | findstr :8080`。

> ⚠️ **起了服务之后，就别再跑 `init-admin` / `init-ops` / `retire-ops` 了。**
> 它们是**另一个进程去改库**，而运行中的 club-server 只在启动时读过一次 ——
> **改了不生效**（新账号登录 401；停用的账号仍能用旧令牌）。
> 真要在运行期加/改运维账号：**先 `2.5` 停服务 → 执行命令 → 再起服务**。
>
> ⚠️ **别指望看日志文件里的启动横幅**：仓颉的 stdout 在**重定向到文件**时是块缓冲，
> 进程被强杀时缓冲区不会落盘（实测 `-RedirectStandardOutput` 出来的 `.out.log` 是 0 字节）。
> 想看那几行 `[db]` / 监听横幅，要么前台跑，要么用 `/admin/shutdown` **优雅关闭**。

### 2.4 验证它真的活着

**"服务好像在几分钟不访问之后自己停了？"** —— 2026-09-21 实测过：**没有这种机制**。
起一个 club-server **完全不发任何请求**（连 `/health` 都不探）12 分钟，进程 24 次检查全部存活；
框架的 server builder 只设了 `addr/port/TLS`，**没有任何 idle / read 超时**；
我们代码里也没有自动关停（唯一的 `sleep(1s)` 在关停路径里，`timeout(15000)` 是**单个请求**
15 秒超时，不是空闲关服）。

真退出了，**按这三条一眼分辨**（顺序就是排查顺序）：

| 现象 | 结论 | 处置 |
| --- | --- | --- |
| 起服务的窗口里打印了 **`服务已停止`** | 是**优雅关停**：有人调了 club-server 的 `/admin/shutdown` —— 最常见的是点了**运维页右上角的「优雅停服」**按钮 | 重新 `dev-serve.ps1` 起；不想被误点就别把运维页开着点来点去 |
| 窗口还在/还在，但 `Get-Process club-server` 查不到，且**没打印**那句话 | 被**外部强杀**：关了那个窗口、任务管理器结束进程、或者**有人在它运行时重新编译**（`build.ps1` 前必须先停 exe —— 本项目里这条最常见） | 起服务后**别关那个窗口**；要重编译先自己停一次 |
| 事件日志里有 `Application Error` | 才是真的崩了 | `Get-WinEvent -LogName Application -MaxEvents 50 \| Where-Object Message -match 'club-server'`；目前**从未出现过** |

最快的"到底活着没"判据（不依赖浏览器）：

```powershell
Get-Process club-server -ErrorAction SilentlyContinue | Select-Object Id,StartTime
curl.exe -s http://127.0.0.1:8080/health
```

> ⚠️ **别用浏览器打开 `http://127.0.0.1:8080/`** —— 根路径没有页面，会返回 **404**
> （浏览器还会顺带请求 `/favicon.ico`，同样是 404）。**这不是故障**：服务端是 API 服务，
> 非 API 的入口只有三个 —— `/health`（免认证，浏览器打开会看到 JSON）· `/join/{token}`
> （招募链接落地页，免认证、HTML）· `/admin/shutdown`（仅本机）；其余全部在 `/api/v1/` 下。
> 看到那两行 404，恰恰说明**服务端已经起来并且在记请求日志**。
> 想在浏览器里确认"活着"，请打开 **`http://127.0.0.1:8080/health`**。
```powershell
curl.exe -s http://127.0.0.1:8080/health
# {"ok":true,"data":{"status":"ok","version":"0.1.0","time":"2026-09-16T13:20:08+08:00"}}

# 再登录一次，确认接口链路通（拿令牌）
'{"phone":"13800000000","password":"ClubPass2026"}' | Set-Content body.json -Encoding ASCII
curl.exe -s -X POST http://127.0.0.1:8080/api/v1/auth/login -H "Content-Type: application/json" --data-binary "@body.json"
# {"ok":true,"data":{"token":"1c207a3c…","expires_at":"2026-10-16T13:20:08+08:00","member":{…}}}
Remove-Item body.json
```

> ⚠️ **用 `curl.exe`，不要用 `curl`** —— PowerShell 里 `curl` 是 `Invoke-WebRequest` 的别名，参数不通用。

数据落在 **MySQL** 里（2026-09-20 起）；`--data-dir`（默认 `data`）下**只有审计日志**：

```
MySQL  <库名>  9 张表：departments / members / plans / tasks / invite_links / tokens / idem
                      + meta / meta_str（计数器与注册口令）
build\data\audit.log      敏感操作审计（重置密码 / 换口令 / 移出成员 / 会长移交 …）
```

> **`db.json` 不再产生**（也**不再被读**）：迁移前的旧文件留着不影响。
> 想直接看库里有什么，用 §2.2 给的那条 `mariadb.exe ... SELECT`；
> 想导出成 JSON 快照，用运维页的「一键备份」（见 §2.7）。

### 2.5 停止服务

```powershell
curl.exe -s -X POST http://127.0.0.1:8080/admin/shutdown
# {"ok":true,"data":{"status":"shutting-down"}}      ← 进程随后自行退出
```

这是**仅本机可访问**的端点（Windows 没有信号机制，只能靠它优雅关闭）；远程打会 403。

---

### 2.6 注册第一个新账号（两步：**凭口令注册 → 会长分配**）

**① 注册口令在哪** —— `init-admin` 的输出里（如 `当前注册口令：DYMRXD`）。忘了就问服务端要（会长令牌）：

```powershell
curl.exe -s http://127.0.0.1:8080/api/v1/register-config -H "Authorization: Bearer <会长令牌>"
# {"ok":true,"data":{"code":"DJ6EA4","updated_at":"...","updated_by":{...}}}
```

换口令也是会长权限：`PUT /api/v1/register-config/code`（自定义）· `POST /api/v1/register-config/rotate`（随机换）。

**② 注册**（字段规则：`register_code` 必填 · `phone` 必须是合法手机号 · `password` **8-32 位、只用数字/英文/符号** · `name` 必填）：

```powershell
# 注意：中文姓名要用 **UTF-8 无 BOM** 的文件体，别用 Set-Content（ASCII 会变 ???，UTF8 会带 BOM）
[IO.File]::WriteAllText("$PWD\b.json", '{"register_code":"DJ6EA4","phone":"13900000002","name":"新同学","password":"newmember123"}', [Text.UTF8Encoding]::new($false))
curl.exe -s -X POST http://127.0.0.1:8080/api/v1/auth/register -H "Content-Type: application/json" --data-binary "@b.json"
# {"ok":true,"data":{"token":"...","member":{"id":2,"role":null,"dept":null,"status":"pending",...}}}
```

> 注册即登录，但账号是 **`pending`**、权限全 `false` —— 客户端会跳到「等待管理员分配」页。
> 这一步**不是 bug**：角色只能由会长授予（v1-scope 的权限设计）。

**③ 会长分配部门 + 角色** —— 分配后账号才 `active`、才有权限：

```powershell
curl.exe -s http://127.0.0.1:8080/api/v1/members/pending -H "Authorization: Bearer <会长令牌>"
curl.exe -s -X POST http://127.0.0.1:8080/api/v1/members/2/assign -H "Authorization: Bearer <会长令牌>" `
  -H "Content-Type: application/json" --data-binary "@b2.json"      # {"dept_id":2,"role":"member"}
# {"ok":true,"data":{"id":2,"role":"member","dept":{"id":2,"name":"课题部"},"status":"active",...}}
```

App 里对应「**待分配审批**」页（会长/副会长可见），两步都在界面上点得到。

**招募链接（可选，招新时更好用）**：会长 `POST /api/v1/dept-invite-links {"dept_id":3}` 拿到 token →
把 `http://<服务端地址>/join/<token>` 发到群里 → 新同学打开看到部门名，注册时带上 `dept_id` →
待分配列表里会带 **`dept_hint`**（会长一眼看出他想进哪个部门）。
> **链接不免除注册口令** —— 链接是便利，口令才是准入。

⚠️ **链接里的地址是怎么来的（2026-09-22 修过一个把这里彻底搞坏的 bug）**：

| | 服务端给出的 url | 说明 |
| --- | --- | --- |
| `serve 8080`（明文，联调默认） | `http://<客户端连进来的 Host>:8080/join/<token>` | scheme 跟着启动形态走：**serve → http** |
| `serve-tls 8443` | `https://<…>:8443/join/<token>` | **serve-tls → https** |
| 加 `--public-url http://10.194.17.0:8080` | `http://10.194.17.0:8080/join/<token>` | **显式指定**，优先级最高（结尾多余的 `/` 会被去掉） |

- **原先 scheme 硬编码成 `https`**，而联调跑的是明文 `serve 8080` → 链接变成
  `https://…:8080`，浏览器拿 TLS 去敲 HTTP 端口，结果就是**"无法连接"**（模拟器内置浏览器里同样）。
  这就是"招募链接复制到浏览器打不开"的原因。
- **Host 取自"客户端连服务端时用的地址"**：模拟器的 `DEV_BASE_URL=http://10.0.2.2:8080`
  会让链接变成 `http://10.0.2.2:8080/join/xxx` —— 那个地址**只有模拟器自己能解析**，
  复制到 PC 浏览器、或发给队友都打不开。**要发群里就显式指定**：

  ```powershell
  .\club-server.exe serve 8080 <DSN> --public-url http://10.194.17.0:8080   # 换成 §5.2 现查到的本机 IP
  # 用 dev-serve.ps1 也行：它已经把本机局域网 IP 打出来了，照抄即可
  ```
- 落地页本身是**免认证**的 `GET /join/{token}`（返回一张说明页，只含部门名），
  自检：`curl.exe -s -o NUL -w "%{http_code}" <服务端给出的 url>` → **200** 才算通。

> ⚠️ **注册口令试错是按客户端 IP 节流的**（15 分钟内错 10 次 → 锁 5 分钟起、逐次翻倍，
> 见 `API-NOTES.md` N-6）。它是**内存态**：被自己锁住时，**重启服务即可清零**。

---

### 2.7 可选：后台管理界面 + 「社团管理」运维页

后台这份有两个页面：上游那套（仪表盘 / 用户管理，管**后台自己的账号**）和我们加的
**「社团管理」运维页 `/club`**（管**社团的真实数据**）。前端产物已随仓库提交，**不需要 Node/npm**：

```powershell
cd E:\harmonyOS\cangjie_web\server
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1 -Target admin   # -> build\admin\admin.exe
cd build\admin
.\admin.exe        # 后台 http://127.0.0.1:3000/   运维页 http://127.0.0.1:3000/club
# 另开一个窗口跑端到端验证：后台自身 38 项 / 运维页（含运维账号登录、写路径与备份导出）82 项
# ⚠ 这两个脚本都需要**可连的 MySQL**（后台 RBAC 与社团库都在库里），取不到会判 FAIL 并退出
# ⚠ 它们会 DROP 掉 club_rbac 的表来验"新库首启"，所以别和正在用的面板同时跑
powershell -NoProfile -ExecutionPolicy Bypass -File ..\tests\admin-check.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File ..\tests\ops-check.ps1
```

> ⚠️ **`admin.exe` 不接受命令行参数**（和 club-server 不一样！）。连接参数、端口、密钥
> 全在 `admin.env` 里。写 `.\admin.exe "mysql://root:口令@127.0.0.1:3307/club_server"` 不会报错，
> **参数被静默忽略**，面板照旧用 `admin.env` 的 `mysql_db`（`club_rbac`）—— 实测有人这么写过，
> 结果被一句 `Unknown database 'club_rbac'` 带偏。现在程序会把"这些参数已被忽略"直接打出来。
> club-server 是 `club-server <子命令> ... <DSN>`，两者形态不同，别照抄。
>
> ✅ **RBAC 库不用手工建**（2026-09-20 起）：`admin.exe` 启动时会像 club-server 那样
> `CREATE DATABASE IF NOT EXISTS`（同一个 `ensureDatabase`）。账号没有建库权限时才会失败，
> 那时它会把原因和手工建库语句一起打出来。

> ⚠️ **运维台监听的是 `0.0.0.0:3000`，不是只绑本机。**
> 轻舟的 `app.serve(port)` 默认 `bindAddr = "0.0.0.0"`（v0.8 起支持 `serve(port, bindAddr: "127.0.0.1")`，
> 但**我们的入口还没暴露这个开关**，要加就是在 `src/ops/admin_main.cj` 里加一个 `--bind`），
> 所以上面那个 `http://127.0.0.1:3000/` 只是"在本机怎么访问它"，
> 并不意味着别人连不上 —— **同一局域网/公网能到 3000 端口的人都能打开这个页面**。
> 它能看到整个社团库（含手机号与审计日志），因此请用防火墙只对运维机放行 3000，
> 不要把它暴露出去（`admin.exe` 启动时也会把这一行打印出来）。

- **后台账号口令：首次启动时随机生成，不在仓库里、也不是任何固定值。**
  第一次运行（建库）时 `admin.exe` 会生成一对口令（各 16 个十六进制字符），
  **打印在控制台一次**并追加到 `build\admin\admin.env` 的 `admin_pass` / `user_pass`；
  之后启动只提示"见 admin.env"，不再回显。想自己指定就把这两行取消注释后填值
  （**别用 `admin123` 这类公开默认值** —— 2026-09-17 前它就是默认值，见 `code-review.md` N-29）。
  账号是 `admin`（角色 1）与 `user`（角色 2）。
- 若 `admin.env` 里仍是老库的 `admin123`，启动时会**醒目告警**；处置办法是清掉那个库的
  `users` 表后重启（会重新随机生成并写回 `admin.env`）。
- 端口 / 密钥 / 令牌时长在 `admin.env`（首次构建生成随机 `secret`，之后不覆盖）。
- **`admin.env` 的 MySQL 连接参数是首次 `-Target admin` 时生成的**：`build.ps1` 会探测
  127.0.0.1 上 **3307 / 3306** 哪个在听，把 `mysql_port` 写成那个；**探测到 3307**（本项目文档里
  那台便携版 MariaDB）时还会把 `mysql_pass` 预填成文档里的口令。
  ⚠ 换了别的 MySQL（或在 3306 上）时模板**不猜口令**、留空 —— 而"口令留空"的表现是
  连不上（驱动报 `Unsupported auth plugin` 或认证失败），**报错里看不出是口令为空**，
  记得自己去 `admin.env` 填 `mysql_pass`。`tests\admin-check.ps1` / `ops-check.ps1`
  对这种空口令有兜底（退回 `CLUB_MYSQL_PASS` → 本机联调默认口令），所以它们红/不红
  不能代替你确认面板真能连上。
- 后台**自己的 RBAC** 数据落在 **MySQL**（`admin.env` 的 `mysql_db`，默认 `club_rbac`；
  库会自动建、表由框架 `RbacStore` 首次打开时建并灌种子）。
  原先那个 `build\admin\admin-data\rbac.json` 文件后端在 2026-09-19 已被取代；新库上那两个
  种子账号（`admin` / `user`）的口令会**当场换成随机值**并写回 `admin.env`（N-29）。
- 运维页 `/club` **只放给角色 1**（`user` 拿到 403），或**直接用运维账号登录进来的身份**。
  它**读**社团库 —— **2026-09-20 起是直连 MySQL**（`admin.env` 的 `club_mysql_db`，默认 `club_server`；
  host/port/user/pass 复用 `mysql_*`；与 club-server 连的是同一个库），
  所以 **club-server 没起也能看**（读的是库，不是谁的内存）。
  `club_data` 这个键**还留着，但只表示审计日志目录**（`/api/club/audit` 读那里的 `audit.log`）。
- **写操作的身份是"专用运维账号"**（运维不该由会长执行）。它的权限 = **除「移交会长」外与会长同权**
  （能重置会长的口令、能改部门、能换注册口令），**不可由 API 分配**，只能用 CLI 建。
  这个账号**已经在 §2.2 ② 建好了** —— 那是它唯一该建的位置（起服务之前），这里不再重复。
  **怎么让它生效：直接用运维账号登录面板**（2026-09-17 起，登录框两种凭据都认）——
  **不需要改任何配置文件**：

  ```powershell
  cd E:\harmonyOS\cangjie_web\server\build\admin
  .\admin.exe            # 然后浏览器开 http://127.0.0.1:3000/
  #   手机号 / 用户名：13800000009
  #   口令          ：<运维口令>    ← 与 §2.2 ② 建账号时用的完全一致
  ```

  登录后「社团管理」页顶部会显示身份 **`13800000009`（运维）**，写操作就是这个账号发的。
  后台自己的账号 `admin` / `user` **也仍然能登**（口令见 `build\admin\admin.env` 的
  `admin_pass` / `user_pass`，首次启动时随机生成、只在控制台打印过一次）——
  那条路管的是**后台自身**（仪表盘 / 用户管理），不是社团数据。

  > **备选：把凭据写进 `admin.env`（`club_user` / `club_pass`）由后台代持。**
  > 适合"不想每次登录都输运维口令"的场景。走这条路要注意：
  > `club_api` 必须是 **`http://`**（见下面的已知限制）· 端口与 §2.3 起服务时一致 ·
  > `club_mysql_db` 与 §2.2 的 DSN 里的库名**一模一样**（**这是最容易漏的一条**）：
  > 对不上时运维页要么报 `Unknown database 'xxx'`、要么一片空数据，而 club-server 那边明明有数据。
  > 2026-09-20 之前的模板写的是 `club`，而 club-server 的默认库名是 **`club_server`** —— 已改齐；
  > 现在报错还会把**这台实例上现有的 club\* 库**列出来，照着填即可；
  > **而且改完必须重启 `admin.exe`**（它只在启动时读一次）。两条路可以只选一条，也可以都配上。

  **两条"必须重启"**（最容易踩，两个进程都**不热加载**）：

  | 你做了什么 | 必须 |
  | --- | --- |
  | 在 club-server **已经运行**时执行 `init-ops` | **重启 club-server** |
  | 改过 `build\admin\admin.env`（`club_user`/`club_pass`/`club_api`/`club_mysql_db`/`mysql_*`） | **重启 admin.exe** |

  原因：`club-server` **只在启动时**把库读进内存一次，运行期别人改库它不知道；
  `admin.exe` 也**只在启动时**读一次 `admin.env`。所以"边跑边改"一律不生效。
  （用运维账号登录那条路不读 `admin.env` 的 `club_user`/`club_pass`，因此不受这条限制。）
  ⚠ 运维页**每请求现连现读** MySQL，所以 club-server 那边写入的数据**立刻**能在页面上看到
  （这一条比迁移前更好：以前要等 club-server 落盘、且要读它写出的那个文件）。

  **怎么确认配好了**：登录后浏览器开 `http://127.0.0.1:3000/club`，「社团管理」页顶部应显示
  **运维身份 `13800000009`（运维）**。若报错，按下表对号入座 —— **登录时报的错与页面上的错
  是同一套口径**（登录时校验用的就是 club-server 本身，所以问题能在登录这一步就暴露）：

  | 现象 | 真实原因 | 处置 |
  | --- | --- | --- |
  | 页面上提示**还没有运维会话 / 只能看不能改** | 既没用运维账号登录过，`admin.env` 的 `club_user`/`club_pass` 也是空的（**或改了 `admin.env` 没重启面板**） | 用运维账号重新登录一次；或填好这两行 → **重启 admin.exe** |
  | 登录时提示**该账号不是运维账号**（HTTP 403） | 拿会长 / 成员账号去登运维台了 —— 运维台只接受 `role = ops` | 改用 §2.2 ② 建的运维账号（运维不该由会长执行） |
  | **登录一直 401**，但「成员名录」里**看得见**那个「运维」账号 | `init-ops` 是在 club-server **已运行**时执行的：账号只落到库里、没进内存 | **重启 club-server**（名录读库、登录打 API，所以会出现"半可见"这种最迷惑人的状态） |
  | 提示**连不上 club-server** | `club_api` 的地址/端口与 club-server 实际不符，或 club-server 还没起 | 先起 club-server；再对齐 `club_api` 与启动端口（`serve-tls` 是 https，见下） |
  | 提示**连不上 HTTPS 的 club-server** | `club_api` 写成了 `https://` | 改成明文 HTTP 端口（见下面的已知限制） |
  | 提示**凭据被拒绝** | 口令错，或账号被 `retire-ops` 停用，或刚 `init-ops` 但没重启 club-server | 核对口令 / 重新 `init-ops` 后**重启 club-server** |

  > **已知限制：面板的写路径不能走 HTTPS。**
  > `club-server` 可以 `serve-tls 8443`（手机端就该走这条），但**面板出站的 HTTP 客户端没有 TLS 配置**
  > （轻舟 `httpclient.cj` 的文件头写明"需要 TLS 请直接用 `stdx.net.http.Client`"），自签证书也过不了校验。
  > 实测把 `club_api` 指向 `https://…:8443` **一定连不上**（现象见上表第 4 行）。
  > 所以要用运维台**写数据**时，让 `club-server` **另以明文 HTTP 起一个本机端口**（如 `serve 8080`），
  > 把 `club_api` 指向它，并**用防火墙限制该端口只对本机/运维机开放**。手机端继续走 8443，两者不冲突。

  → 用运维账号做的写操作，在 club-server 审计日志里 `actor` 是**运维**而不是会长（职责分离可追溯）。
  → 该账号**在 App 名录里看不到**、只在运维台名录里显示为「运维」—— 原因见 §2.2 的说明。
- 只读视图是白名单：运维接口里**不含任何口令材料**（`pw_salt` / `pw_hash` / `pw_iter`）。
- **`cwd` 必须是 `build\admin`**（按相对路径读 `admin.env` 与 `admin-web\dist`）。
- 这套后台与 `club-server` **互不影响**（不同端口、不同数据文件、不同 exe），可以同时跑。
- 已修掉上游那个"成功响应也可能带 404"的状态码问题（在我们的入口里按 body 的 `code` 回写状态，
  内置框架未动）—— 见 `API-NOTES.md`「坑 34」；关停回执丢失的竞态见「坑 36」。

## 3. HTTPS（手机端正式使用要走这条）

自签证书**必须带 SAN**（现代客户端完全忽略 CN，只看 `subjectAltName`）：

```powershell
$openssl = "D:\Program Files\Git\usr\bin\openssl.exe"
cd E:\harmonyOS\cangjie_web\server
& $openssl req -x509 -newkey rsa:2048 -nodes `
  -keyout certs\key.pem -out certs\cert.pem -days 3650 `
  -subj "/C=CN/O=Club/CN=127.0.0.1" `
  -addext "subjectAltName=IP:127.0.0.1,DNS:localhost"

cd build
..\club-server.exe serve-tls 8443 $dsn --cert ..\certs\cert.pem --key ..\certs\key.pem

# 一条命令验完：协议版本（1.2/1.3 通、1.0/1.1 拒）+ SAN + 真证书校验下走一遍登录
# ⚠ 需要可连的 MySQL（用专用测试库 club_tls；取不到判 FAIL 退出）
powershell -NoProfile -ExecutionPolicy Bypass -File ..\tests\tls-check.ps1
# 2026-10-04 本机实测：PASS 4 / FAIL 3。失败的三条是 SAN 相关（证书里没有客户端实际用的地址），
# 根因是 server\certs 不入库、本机那份是 2026-09-17 的旧件（SAN 只有 127.0.0.1 / localhost）。
# 用**改动前**的二进制复现同样结果 ⇒ 与代码无关，不是 TLS 实现坏了。
# 要跑绿：先按 §3 重签一张带 SAN 的证书（或按 §5.5 加上客户端实际访问的 IP）。
```

换真实公网 IP 部署时：把 SAN 里的 `127.0.0.1` 换成该 IP，并用
`openssl verify -CAfile certs\cert.pem -verify_ip <IP> certs\cert.pem` 自检。
**私钥绝不入库**：`server\certs` 与 `server\dist` 都在 `.gitignore`。

---

## 4. 部署包（可整体拷走）

```powershell
cd E:\harmonyOS\cangjie_web\server
powershell -NoProfile -ExecutionPolicy Bypass -File .\build-package.ps1            # 带证书
powershell -NoProfile -ExecutionPolicy Bypass -File .\build-package.ps1 -SkipCert   # 不带
```

产出 `server\dist\club-server\`（约 **19 MB**）：

```
club-server.exe  + 4 个 DLL        制品 5 个
certs\cert.pem   certs\key.pem     证书 2
start-http.cmd   start-https.cmd   启动脚本 2（脚本内已 cd + chcp 65001，双击即可，中文不乱码）
README.txt       dll-versions.txt  说明 + **实际打包进去**的 DLL 版本与 sha256（便于追溯）
```

整个目录拷到目标机即可运行 —— **同平台（Windows x64），目标机不需要装编译器**。

> ⚠ **2026-09-20 起还要加上第 3 件东西：一台可连的 MySQL。** 部署包本身不含数据库
> （那是另一台机器/另一个服务的事），但 club-server 没有它就起不来。
> 目标机上要在 `start-http.cmd` / `start-https.cmd` 里把 DSN 写对（脚本里的 `serve` 那行），
> 或在启动命令里补 `--mysql-*`。详见 §2.0 与 `docs/mysql-backend.md` §十二。

发包给队友可以直接用压缩包：`server\dist\club-server-<日期>.zip`（约 **6.8 MB**，
`build-package.ps1` 之后用 `Compress-Archive` 打一次即可）。因为是二进制，**不进 git**，
只能这样发过去 —— 队友 `git clone` 是拿不到 exe 的。
拷过去之后按 `README.txt` 走：`club-server.exe init-admin … <DSN>` → 双击 `start-https.cmd`。

> **给不装编译器的队友**：这个目录就是给他们用的（同平台、免编译）。只要不动 Cangjie / 轻舟源码，
> 换掉 exe + 4 个 DLL 即可；改了服务端源码才需要 SDK 自己编（§2.1）。
>
> 上公网服务器还要采集 4 件事（本机替代不了）：架构是 x64 还是 ARM64 · 公网 IP 与端口可达性 ·
> **防火墙与云安全组是两层都要放行** · 服务器上已有什么服务。详见 `deploy-windows-verify.md` §3。

---

## 5. 让客户端的 App 连上它（**联调的主战场**）

### 5.1 三种客户端各填什么

| 客户端跑在哪 | 服务端地址 | 说明 |
| --- | --- | --- |
| **模拟器**（和你在同一台电脑） | `http://10.0.2.2:8080/api/v1` | 模拟器里 `127.0.0.1` 指它自己，宿主机要用 `10.0.2.2`（`Env.ets` 的 `DEV_BASE_URL` 默认就是这个，**不用改**） |
| **真机（同一局域网）** | `http://<服务端那台机器的局域网IP>:8080/api/v1` | 改 `entry/src/main/ets/config/Env.ets` 的 `DEV_BASE_URL` |
| **队友的电脑 / 模拟器** | 同上（填**你**的局域网 IP） | 他不需要仓库、不需要数据库，只要能到你的 8080 |
| 真机走 HTTPS | `https://<IP>:8443/api/v1` | 要先在 App 里内置自签 CA，见 §5.5（**证书 SAN 里必须有这个 IP**） |

> 服务端**默认绑 `0.0.0.0`**（启动横幅会明写 `监听 0.0.0.0:8080`），所以**不需要改任何配置**
> 就能被局域网访问 —— 卡住你的从来不是绑定地址，而是下面 §5.3 的防火墙和 §5.4 的"是不是同一个网络"。
>
> ⚠ **改 `DEV_BASE_URL` 要重新编译客户端**（它是编译期常量）。联调时频繁换 IP 的话很烦 ——
> 加一个"运行时手填服务器地址"的调试入口是**客户端那边的事**（属于 `client-bug-handover.md`
> 里给前端小组的建议范畴），服务端这边不需要任何改动。

### 5.2 查服务端这台机器的局域网 IP（**别抄文档里的旧 IP**）

IP 会随 DHCP 变（本项目实测：同一天里从 `10.194.208.10` 变成 `10.194.233.104`），
所以**每次联调现查**：

```powershell
# 取"默认路由那块网卡"的地址 —— 比 ipconfig 里一堆虚拟网卡好认
$udp = New-Object System.Net.Sockets.UdpClient
$udp.Connect("8.8.8.8", 65530)
$udp.Client.LocalEndPoint.Address.ToString()   # 例：10.194.233.104
$udp.Close()
# 这台机器完全没有默认路由（离线/只连了内网交换机）时上面那句会抛异常，那就退回：
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | Select-Object IPAddress,InterfaceAlias

# 或者直接问 dev-serve.ps1：它启动时会把该填的地址打出来（§0.5）
```

### 5.3 放行防火墙（**只对真机/队友需要；本机自测不需要**）

用**管理员** PowerShell 跑一次即可（`-DisplayName` 只是标签，重复执行会报已存在，无害）：

```powershell
New-NetFirewallRule -DisplayName "club-server 8080" -Direction Inbound -Protocol TCP -LocalPort 8080 -Action Allow
# 走 HTTPS 就再来一条 8443；运维台要用再来一条 3000（而且 3000 只对运维机放行，见 §2.7）
```

> Windows 防火墙是**按程序还是按端口**拦、以及有没有第三方安全软件，都可能让"本该通"变成不通。
> 判断方法很直接：**在队友那台机器**上 `Test-NetConnection <你的IP> -Port 8080`
> —— `False` 就是网络/防火墙层面，**与服务端代码无关**，别去翻服务端日志。

### 5.4 "队友连不上"的排查顺序（按这个顺序，一次就能定位）

| # | 检查 | 命令 / 判据 |
| --- | --- | --- |
| 1 | 服务端在你本机活着吗 | `curl.exe -s http://127.0.0.1:8080/health` → `{"ok":true,...}` |
| 2 | 服务端绑的是全网卡吗 | 启动横幅有 `监听 0.0.0.0:8080`（`127.0.0.1:8080` 只有本机能连） |
| 3 | **你和他在同一个网络吗** | 两边分别 `ipconfig`，前三段（如 `10.194.233.x`）要能互相 ping 通；**这是本项目真实踩过的一次**——队友在另一个网段，怎么调防火墙都没用 |
| 4 | 防火墙放行了吗 | 队友机器上 `Test-NetConnection <你的IP> -Port 8080` → `True` 才算过 |
| 5 | 地址写对了吗 | 真机/队友：`http://<你的IP>:8080/api/v1`；模拟器：`http://10.0.2.2:8080/api/v1`（**`10.0.2.2` 只在"模拟器与你在同一台电脑"时成立**） |
| 6 | 明文 HTTP 被系统拦了吗 | 登录页报 `NETWORK_ERROR` → 见下面那段（改走 HTTPS + 内置 CA） |

> **明文 HTTP 会不会被系统拦？** 客户端那份 `network_config.json` 的键名在本机 SDK / hvigor 里**不存在**
> （第四轮已实测：`app.json5` / `module.json5` 内联 `network` 会被 schema 直接拒绝），属**惰性配置**。
> 想确认只能实测：登录页若报 `NETWORK_ERROR` 就是被拦了 → 改走 HTTPS + 内置 CA（§5.5）。
> 联调阶段**先用 HTTP**：少一层证书信任问题，能最快确认"链路通不通"。

### 5.5 走 HTTPS（真机正式使用 / 明文被拦时）

自签证书**必须带 SAN，且 SAN 里要写客户端实际用的那个地址**（IP 或域名）——
现代客户端完全不看 CN，只认 SAN；上一轮队友连不上，有一条就是证书里没有他的访问地址。

```powershell
# 在 server\ 下执行（把 IP 换成 §5.2 查到的那个）
& "D:\Program Files\Git\usr\bin\openssl.exe" req -x509 -newkey rsa:2048 -nodes `
  -keyout certs\key.pem -out certs\cert.pem -days 365 `
  -subj "/CN=club-server" `
  -addext "subjectAltName=IP:127.0.0.1,IP:10.194.233.104,DNS:localhost"

cd build
.\club-server.exe serve-tls 8443 <DSN> --cert ..\certs\cert.pem --key ..\certs\key.pem
# 等价：..\dev-serve.ps1 -Tls -Port 8443    （默认证书路径就是 ..\certs\cert.pem / ..\certs\key.pem）
```

> ⚠️ **仓库里现成那张 `server\certs\cert.pem` 的 SAN 只有 `IP:127.0.0.1, DNS:localhost`**
> （实测 `openssl x509 -text`）—— 真机或用局域网 IP 访问它**必然报证书不匹配**。
> 也就是说：**要多人/跨机走 HTTPS，就得先按上面那条命令重签**（把 IP 换成你的）。
> `dev-serve.ps1 -Tls` 启动时会把这件事再提醒一遍。

- 自签证书**客户端默认不信任** —— 要么在 App 里内置这张 CA，要么联调阶段就先用 HTTP。
  （证书名不匹配的报错、信任链报错，都属这一类，**不是服务端没起来**。）
- 换 IP 后**必须重签**（SAN 变了），否则又变成"证书名不匹配"。

> **联调建议的顺序**：先用 HTTP 把"链路通不通"确认下来（§5.1～§5.4），
> 再换 HTTPS 处理"明文被系统拦 / 要演示正式形态"（本节）。
> 反过来做的话，证书问题会掩盖真正的网络问题 —— 上一轮就是这么绕了一圈。

### 5.6 清库重来 / 换一套干净的联调数据

联调时把数据试脏了是常态，干净重来只要两条：

```powershell
# ① 丢掉这个库（**先确认 club-server 已停**，否则它内存里那份会在下次落盘时写回来）
& "E:\cangjie\mariadb\mariadb-11.4.13-winx64\bin\mariadb.exe" -h 127.0.0.1 -P 3307 -u root "-pclubroot123" --protocol=tcp -e "DROP DATABASE IF EXISTS club_server;"

# ② 重新建（库/表/4 个部门/会长都是这一步自动建出来的），再起服务
cd build
.\club-server.exe init-admin 13800000000 ClubPass2026 "mysql://root:clubroot123@127.0.0.1:3307/club_server"
cd .. ; .\dev-serve.ps1
```

> 想**同时**保留旧数据，就别 DROP —— 换个库名即可：`init-admin ... <DSN 里换成 club_server2>`，
> `dev-serve.ps1 -Db club_server2`。
> ⚠ **只有 club-server 一个进程可以写这个库**：多开一个 club-server 写同一个库会互相覆盖
> （内存 Store 每进程一份、没有失效通知，路线 B 的已知代价）。

---

## 6. 数据与备份（唯一不能省的一步）

- **真相来源是 MySQL**（2026-09-20 起）：一个库、9 张表。
  **把那个库纳入每日备份**（`mysqldump`），并至少交接给两个人 —— 这是这个项目里唯一"丢了就没了"的东西。
- 单独备份 `audit.log`（`--data-dir`，默认 `build\data\`）—— 它**不在**数据库里。
- 运维页的「一键备份」按钮会**从 MySQL 导出一份 JSON 快照**（与原 `db.json` 同结构，
  可直接当离线副本/迁移材料），和审计日志副本一起落到 `build\admin\admin-data\club-backups\`。
  它**不是**存储层的一部分，只是导出物。
- 别把审计目录放在会被清理的位置：`server\build\` 是构建产物目录（`**/build` 在 `.gitignore`），
  长期使用建议放在 `dist\club-server\data\`（部署包形态）并单独备份。
- 迁移前的 `db.json` **不会被读**，但**别急着删** —— 保留到确认新库数据无误为止（它就是最原始的那份底稿）。

---

## 7. 坑表（都是本项目真踩过的）

| 坑 | 现象 | 解法 |
| --- | --- | --- |
| **`$dsn` 是个空串** | 报 `Failed to connect 10061`，而日志第一行连的是 `127.0.0.1:**3306**`、`pass=(empty)` —— 看着像"端口配错/数据库没起" | PowerShell 引用**未定义**的变量**不报错**，就是空串 → 位置参数空着 → 程序静默退回默认值（3306/root/空口令）。**整块复制**命令，别只复制最后一行；或直接写死 DSN。程序现在会在连接**之前**打印「⚠ 命令行没有给 DSN / --mysql-*，正在使用默认连接参数…」（`init-name-check.ps1` §9 有闸门） |
| **KB5124010** | 所有仓颉 exe `0xC0000005` 启动即崩 | 卸载该更新（`API-NOTES.md` §5） |
| **执行策略** | `无法加载文件 build.ps1，因为在此系统上禁止运行脚本` | 调用时带 `-ExecutionPolicy Bypass` |
| **cwd 不对** | 报错，或出现"假失败 + 假通过" | `cd` 到 exe 所在目录（部署包的启动脚本已 `cd /d "%~dp0"`） |
| **`curl` 是别名** | 参数不生效/行为诡异 | 用 `curl.exe` |
| **DLL 少了** | 缺 `libcangjie-runtime.dll` → 启动即失败；缺 OpenSSL 两个 → **编译期无警告**、运行时密码哈希/TLS 才 500 | 制品是 **exe + 4 个 DLL**，一个都不能少；`build.ps1` 会自动就位 |
| **端口占用** | 起不来 | `netstat -ano \| findstr :8080` |
| **客户端连不上** | 本机正常、外部不通 | **先按 §5.4 的六步走一遍**（"是不是同一个网络"排第 3，本项目真踩过）；防火墙**与**云安全组是两层，都要放行 |
| **自签证书没 SAN** | 客户端报证书名称不匹配 | 重签证书，SAN 里写客户端实际使用的地址（换 IP 就要重签，见 §5.5） |
| **`$home` 赋值报错** | `Cannot overwrite variable HOME because it is read-only or constant` | PowerShell 的 `$HOME` 是**只读自动变量**，脚本里别拿它当局部变量名（写 `dev-serve.ps1` 时实测踩到） |
| **`.ps1` 里写了 C 风格注释** | 运行时 `/* : The term '/*' is not recognized…`，而**语法检查报 0 错误** | PowerShell 的块注释是 `<# … #>`；`/* … */` 会被当成命令名 —— 这类错误**只在执行时暴露**，所以新脚本必须真跑一遍，不能只做 `Parser::ParseFile` |
| **cjenv 抢 `CANGJIE_HOME`** | 脚本挑了 1.0.5，编译中途 `LLVM ERROR: Broken module found` | 按版本挑**基线的 1.2.0**（脚本会先警告，编译前还会硬校验）；`-CangjieHome` 显式指定，见 §2.1 |
| **测试脚本报「连不上 MySQL / 口令错」，而库其实是好的** | `admin-check.ps1` / `ops-check.ps1` / `tls-check.ps1` 等套件在夹具阶段就 FAIL 退出，错误像"库没起 / 口令不对" | 本机 mariadb/mysql 客户端的 **TLS/SSPI 握手**失败（`ERROR 2026 (HY000): TLS/SSL error: no credentials` / `SEC_E_NO_CREDENTIALS`），库本身完全正常。**2026-10-04 起** `tests\mysql-common.ps1`（及 `admin-check` / `ops-check` 里的私有副本）**默认给客户端加 `--skip-ssl`**（真实 TLS 场景设 `$env:CLUB_MYSQL_USE_SSL=1` 关掉它），并且**不再吞掉客户端 stderr** —— 连接失败时那行 stderr 就是唯一诊断依据。看到这类报错先看 stderr 里有没有 TLS/SSL/SSPI，别急着改口令 |
| **输出 exe 被占用** | `ld.lld: failed to write the output file: Permission denied` | 不是权限问题：`Get-Process club-server \| Stop-Process -Force` 后重编 |
| **机器上没装仓颉 SDK** | `找不到仓颉 SDK（cjc.exe）` | 装 SDK（§2.1），或直接用**部署包**（§4，免编译） |
| **启动脚本里中文乱码** | 双击后服务端中文日志是乱码 | 启动脚本已加 `chcp 65001 >nul`；2026-09-16 之前生成的包请重新 `build-package.ps1` |
| **没跑 `build-mysql-driver.ps1`** | `build.ps1` 直接 `throw`「`build\mysql-driver` 里没有 `mariadb.cdbc.cjo`」 | 先跑一次 `.\build-mysql-driver.ps1`（只须一次，产物不入库） |
| **MySQL 连不上** | 启动即 `[FATAL] 连接 MySQL 失败…` 并退出（**这是有意的**：不带空库继续跑） | ① 服务器起着吗（`Test-NetConnection 127.0.0.1 -Port 3307`）② DSN/口令/端口对不对 ③ 账号有没有建库权限（程序会试 `CREATE DATABASE IF NOT EXISTS`） |
| **报「未注册 mysql/mariadb 驱动」** | 编译链接全过、一启动就抛这句 | 说明驱动包没被**引用**（不是没链接）：`src/mysql_store.cj` 顶部那条 `import mariadb.cdbc.*` 不能删；改过就重编 |
| **运维页报 `Unknown database 'club'`** | 打开 `/club` 就是这句；club-server 那边一切正常 | `admin.env` 的 `club_mysql_db` 与 club-server 实际用的库名不一致（老模板默认写 `club`，而 club-server 默认是 **`club_server`**）。改齐 + **重启 admin.exe**；报错里现在会列出实例上现有的 club\* 库。 |
| **运维页数据是空的，但 club-server 明明有数据** | 两边连的不是同一个库 | 同上：对齐 `admin.env` 的 `club_mysql_db` 与 club-server 的 DSN 库名；改完**重启 admin.exe** |
| **"服务跑几分钟就自己停了？"** | 想确认是不是有"空闲自动关服" | **没有这种机制**：实测空闲 6.5 分钟、每 30 秒探一次 `/health`，14 次全是 200、进程一直在（框架的 server builder 只设了 addr/port/TLS，没有任何 idle/read 超时）。真停了按这个顺序查：① **是不是点了运维页右上角的「优雅停服」**（它调的正是 club-server 的 `/admin/shutdown`，1 秒后进程退出，启动窗口会打印「服务已停止」）② 起服务的那个**窗口/终端是不是被关了**（强杀不会打印「服务已停止」）③ 电脑是否睡眠 ④ 别把"写请求 500"当成"服务停了"——`/health` 还 200 就说明服务活着，去查 MySQL（`Test-NetConnection 127.0.0.1 -Port 3307`） |
| **招募链接复制进浏览器报"无法连接"** | 链接形如 `https://…:8080/join/xxx`，而联调跑的是**明文** `serve 8080` | 2026-09-22 前的 bug：链接的 scheme 被硬编码成 `https`。现在跟着启动形态走（serve→http / serve-tls→https）。**另一个常见原因是 Host**：链接里是模拟器的 `10.0.2.2`，只有模拟器能解析 —— 要发给队友就加 `--public-url http://<本机局域网IP>:8080`。详见 §2.6 |
| **`init-admin P W data` 报「第二个参数现在是 MySQL DSN」** | 迁移前的写法把**数据目录**当第二个参数，现在那里是 **DSN** | 用 `mysql://用户:口令@主机:端口/库名`；审计日志目录用 `--data-dir <目录>` 单独给 |
| **文本里的反斜杠多了/少了** | 启动日志里那一行 `sql_mode` 提示 | 默认反斜杠转义模式下我们已按该口径转义；若服务端开了 `NO_BACKSLASH_ESCAPES`，会**明说**"会多存一个反斜杠"（见 `mysql-backend.md` §12.3） |

---

## 附 · 本文的实测记录

| 项 | 值 |
| --- | --- |
| 实测时间 | 2026-09-16（全流程）；**2026-09-17 复验并重写 §2**；**2026-09-20 数据层换 MySQL 后按新命令复验（§2.0 / §2.2 / §2.3 / §3 / §6 已更新）**；**2026-09-20 晚新增 §0.5 联调速查 + `server\dev-serve.ps1`（脚本已实测：数据库停着时能自己起来、服务能起、`/admin/shutdown` 能优雅关停）** |
| 结论 | §2 部署顺序 + §4 部署包 + §3 TLS 全部通过。**2026-09-20 复验后的测试基线**：单测 **507**（不带 DSN）/ **555**（带 DSN，含 48 条 MySQL 往返/增量断言）· 冒烟 **440** · TLS **23** · 跨仓契约 **33** · 后台端到端 **38** · 运维页端到端 **82**，全部 **FAIL 0** |
| §5 重写的原因 | 联调时"连不上"有**四种**互不相干的原因（不在同一网络 / 防火墙 / 地址写法 / 明文被拦），原先挤成一张三行表 + 一句防火墙命令，最容易把"网络不通"误判成"服务端坏了"。现在拆成 §5.1 填什么 → §5.2 现查 IP（**文档里再也不写死 IP**：本机 IP 当天就从 `10.194.208.10` 漂到 `10.194.233.104`）→ §5.3 防火墙 → §5.4 六步排查表 → §5.5 HTTPS/SAN → §5.6 清库重来 |
| §2 重写的原因 | 原 §2 把「起服务」排在「建运维账号」之前（运维账号当时放在 §2.7 才讲），**照做必定踩到**「先起服务再 `init-ops` → 登录 401、而名录里看得见账号」。现把两条初始化命令（`init-admin` / `init-ops`）统一并入 §2.2，排在起服务之前；§2.7 只留"把凭据交给面板"两步。三处根因与复现见 `code-review.md` 第六轮补记 |
| 演示数据 | `server\build` 被 `.gitignore` 忽略（`**/build`），**新克隆里既没有 `db.json`、也没有数据库** —— 照 §2.0 起一台 MySQL、再照 §2.2 自己 `init-admin` 定口令即可（全文示例统一用 `ClubPass2026`，见 §2.2 / §2.4）。本机那台另留了个演示库，其**会长口令以当时 `init-admin` 的输入为准、文档不记录**；正式用前换一个库名重新初始化 |
| 队友视角复现 | 全新 `git clone` + 清空 `CANGJIE_HOME`/cjenv 的 PATH 后 `build.ps1` 自动挑到 `D:\Cangjie` 1.1.3 并**编译通过**；**2026-09-20 补充**：新克隆还要先跑 `build-mysql-driver.ps1`、并有一台可连的 MySQL。部署包解压后 `cmd /c start-http.cmd` → `/health` **200**、`init-admin` → 库里出现 1 成员 + 4 部门（`build\data\` 下只有 `audit.log`） |
| 未覆盖 | 公网部署（缺服务器信息）、真机/模拟器上的客户端联调（本机无设备）、**多实例共写同一个库**（路线 B 明确不支持，见 `mysql-backend.md` §12.9）。§5.4 那张排查表里的每一条都有出处（多处是"队友真连不上"的复盘），但**没有第二台机器逐条复现**；§5.5 的 openssl 命令与 §3 同源，换 IP 后请按 §5.2 现查再签 |
