# ops-check.ps1 —— 轻舟后台「社团管理」运维页 端到端验证
#   （读：后台直连 **MySQL** 读社团库；写：以**专用运维账号**的身份走 club-server 真实 API）
#
# 覆盖：
#   1) 运维页静态入口（SPA fallback：/ 与 /club 都返回 index.html）
#   2) 后台自己的 RBAC：登录、/api/me 的 can_ops、无 token → 401、user 角色 → 403
#   3) **HTTP 状态码口径**：成功 200、拒绝 401/403（上游"成功响应带 404"已在我们入口修掉）
#   4) 只读视图：/api/club/{overview,members,depts,tasks,plans,links,audit,config,server-health}
#   5) **安全闸门**：运维接口的响应体里**不得**出现 pw_hash / pw_salt / pw_iter
#   6) **运维身份**：admin.env 的 club_user/club_pass（club-server 的 role = ops）由后台代持，
#      /api/club/session 换出令牌；**页面不需要任何社团账号口令**
#   7) 运维权限：能做「会长专属」的部门增删改与换注册口令、能处置会长；
#      **唯一的减法 = 移交会长**（403 FORBIDDEN_ROLE）；ops 不可由 API 分配
#   8) 写路径回读：注册 → 分配（含 lead/vice_lead 角色中文标签）→ 重置口令 →
#      轮换注册口令 → 新增部门 → 停用；每步都用只读视图回读，证明**读的是 club-server 正在写的那份数据**
#   9) **职责分离**：club-server 的审计里这些动作的 actor 是**运维**，不是会长
#  10) 备份：社团库从 MySQL **导出 JSON 快照** + 审计日志复制到 <后台数据目录>/club-backups/
#  11) 两个进程都能优雅关闭
#
# 隔离性：本脚本**不动**你正在用的 build\admin\admin.env —— 先备份、写入自己的一份
# （端口 18099 / club-server 18081 / 审计日志目录 ops-e2e-data / 自己的运维账号），结束再还原。
# 因此可以和一个正在跑的 admin.exe（3000）并存。
#
# ⚠ 两个端口都**可传参**：-OpsPort / -ClubPort（2026-10-06 P2-1）。
#   默认 18099 是刻意避开 Windows 保留区间的；脚本会**先试 bind**，不通就早失败并提示怎么换。
#
# ⚠ 两个库都是共享 MySQL 上的（本脚本会清表，所以必须"一人一库"）：
#   · **后台 RBAC 库** = admin.env 的 mysql_db（默认 club_rbac）—— 本脚本会 DROP 它的
#     4 张 RBAC 表，用来验证"新库首启自动建表 + 换掉种子默认口令"（N-29 闸门）。
#     所以别在和别人共用的库上跑；要隔离就改 build\admin\admin.env 的 mysql_db。
#   · **社团库** = club-server 的库（下面 $clubDb，默认 club_ops_e2e）—— 本脚本会 DROP
#     它的 9 张表当干净夹具。用**独立库名**（不是别人在用的 club），避免清掉真实社团数据。
#
# 前置：先编译两份产物（外加一台可连的 MySQL / MariaDB，见下）
#   cd server
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\build-mysql-driver.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1 -Target admin
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\ops-check.ps1
#
# ⚠⚠ 新前提（2026-09-19 起运维台、2026-09-20 起 club-server）：**必须有可连的 MySQL / MariaDB**。
#   两边都从 JSON 文件切到了 MySQL。连接参数取自 admin.env 的 mysql_*（本机联调是
#   127.0.0.1:3307 / root / clubroot123）；club-server 那边用命令行 DSN。
#   脚本开头会显式探测，取不到就给出中文提示并**判为失败**（不静默跳过 —— 数据层起不来时
#   "运维页能不能用"根本没有答案）。起一个本机便携版 MariaDB：
#     & "<MariaDB>\bin\mysqld.exe" --datadir="<数据目录>" --port=3307 --console
#   详见 docs\mysql-backend.md 与 tests\mysql-common.ps1。

param(
    # ⚠ 端口**可传参**（2026-10-06 评审 P2-1）。
    #   原先写死 $opsPort = 3099，而 Windows 的**保留端口区间**（本机 `netsh int ipv4
    #   show excludedportrange protocol=tcp` 实测 3002–3101，装了 Hyper-V/WSL 后常见）
    #   正好把它盖住 —— 运维台 bind 失败 SocketException 10013，82 项端到端一条都跑不了。
    #   默认改到 18099（与 club-server 的 18081 同属项目自用段），并与 3099 拉开距离。
    [int]$OpsPort  = 18099,   # 轻舟后台（运维台）
    [int]$ClubPort = 18081    # club-server
)

$ErrorActionPreference = 'Stop'

$root  = Split-Path -Parent $PSScriptRoot              # server\
$build = Join-Path $root "build"
$admin = Join-Path $build "admin"
$clubExe  = Join-Path $build "club-server.exe"
$adminExe = Join-Path $admin "admin.exe"

foreach ($p in @($clubExe, $adminExe)) {
    if (-not (Test-Path $p)) {
        Write-Host "找不到 $p"
        Write-Host "先跑：.\build.ps1  与  .\build.ps1 -Target admin"
        exit 2
    }
}

$clubPort  = $ClubPort
$opsPort   = $OpsPort
$clubDir   = "ops-e2e-data"        # 相对 build\：现在只放审计日志（audit.log）
$clubBase  = "http://127.0.0.1:$clubPort"
$opsBase   = "http://127.0.0.1:$opsPort"

# ⚠ 端口预检（P2-1）：**真去 bind 一下**，比写死一个机器相关的"保留区间"常量可靠。
#   Windows 的保留区间随机器不同（Hyper-V / WSL / Docker 都会占），所以不问系统要常量，
#   而是直接试 —— 试不通就早失败，并告诉用户怎么换，而不是等运维台抛 SocketException。
function Test-CanBind([int]$p) {
    try {
        $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $p)
        $l.Start()
        $l.Stop()
        return $true
    } catch {
        return $false
    }
}
foreach ($pp in @(@{ n = "运维台"; p = $opsPort }, @{ n = "club-server"; p = $clubPort })) {
    if (-not (Test-CanBind $pp.p)) {
        Write-Host ""
        Write-Host "❌ 端口 $($pp.p)（$($pp.n)）**无法绑定**：可能被别的进程占用，或落在 Windows 保留区间里。"
        Write-Host "   查保留区间：netsh int ipv4 show excludedportrange protocol=tcp"
        Write-Host "   换端口重跑：powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\ops-check.ps1 -OpsPort 18099 -ClubPort 18081"
        Write-Host ""
        exit 2
    }
}
$presPhone = "13900000001"
$presPw    = "ClubPass2026"
$opsPhone  = "13900000009"         # 专用运维账号（role = ops）
$opsPw     = "OpsPass2026"
$envFile   = Join-Path $admin "admin.env"
$envBackup = Join-Path $admin "admin.env.ops-check.bak"
$clubDb    = "club_ops_e2e"        # **社团库**：独立库名，别用别人在用的 club


# ── MySQL 连接参数（2026-09-19：运维台自己的 RBAC 库现在在 MySQL 里）─────────────
# 先按 admin.env 的现值取（用户在跑的那台服务器），下面写自己那份 env 时也沿用同一组值，
# 这样"隔离"只体现在端口/社团库/运维账号上，不体现在数据库上 —— 后面会清表，注释里说明。
$dbHost = "127.0.0.1"
$dbPort = 3306
$dbUser = "root"
$dbPass = ""
$dbName = "club_rbac"
if (Test-Path $envFile) {
    foreach ($line in (Get-Content $envFile -Encoding UTF8)) {
        $t = $line.Trim()
        if ($t -match '^mysql_host\s*=\s*(\S+)')  { $dbHost = $Matches[1] }
        if ($t -match '^mysql_port\s*=\s*(\d+)')  { $dbPort = [int]$Matches[1] }
        if ($t -match '^mysql_user\s*=\s*(\S+)')  { $dbUser = $Matches[1] }
        if ($t -match '^mysql_pass\s*=\s*(\S*)')  { $dbPass = $Matches[1] }
        if ($t -match '^mysql_db\s*=\s*(\S+)')    { $dbName = $Matches[1] }
    }
# ── 防误伤闸门（2026-09-19 加）──────────────────────────────────────────────
# 本脚本会 **DROP 掉 mysql_db 指向那个库的 RBAC 表**（用来验证"新库首启"路径）。
# 如果多人共用同一台 MySQL（例如都连局域网里那台）而都用默认库名 club_rbac，
# 那么谁跑一次本脚本，就会把所有人的 admin/user 账号清空 —— 更要命的是各人
# build\admin\admin.env 里的 admin_pass/user_pass 是**各自随机生成**的，库一被清，
# 别人那份口令立刻失效，全员被锁在后台外面。
#
# 所以默认**拒绝**在 club_rbac 上跑本脚本：
#   · 每位队友请在 build\admin\admin.env 里把 mysql_db 改成**自己的**库名
#     （如 club_rbac_alice）。库不存在时本脚本会自动建（连接账号已按 club_rbac% 授权）；
#   · 确实要在 club_rbac 上跑（例如你就是这台 MySQL 的主人、且清楚代价），
#     就设环境变量 CLUB_ALLOW_SHARED_DB=1 显式承担风险。
if ($dbName -eq 'club_rbac' -and $env:CLUB_ALLOW_SHARED_DB -ne '1') {
    Write-Host ""
    Write-Host "拒绝执行：mysql_db 是共用默认库 'club_rbac'，而本脚本会 DROP 掉它的 RBAC 表。" -ForegroundColor Red
    Write-Host "  · 共用一台 MySQL 时，请在 build\admin\admin.env 把 mysql_db 改成你自己的库名，"
    Write-Host "    例如：mysql_db=club_rbac_<你的名字>   （库会自动建）"
    Write-Host "  · 或用你自己的私库跑：`$env:CLUB_ALLOW_SHARED_DB=1` 显式承担风险后再跑。"
    Write-Host ""
    exit 1
}
}

# ⚠ mysql_pass 为空时**退回本机联调的默认口令**（2026-09-20 补）。
#
# 新生成的 build\admin\admin.env 里 mysql_pass 是**空的**（build.ps1 的模板只在探测到本机
# 3307 那台时才预填口令）。而本机那台便携版 MariaDB 的 root **有口令** —— 留空会让本脚本的
# 夹具连不上，而且 club-server 会收到 `mysql://root:@127.0.0.1:3307/…` 这种没口令的 DSN，
# 报出来的是驱动的 `Unsupported auth plugin`，从字面上完全看不出"口令为空"。
# 实测就是清掉 build\ 重新生成 env 之后本脚本直接红在这里。
# 优先级：admin.env 里填了就用它 > 环境变量 CLUB_MYSQL_PASS > 本机联调默认 clubroot123。
if ($dbPass.Length -eq 0) {
    if ($env:CLUB_MYSQL_PASS) { $dbPass = $env:CLUB_MYSQL_PASS } else { $dbPass = "clubroot123" }
}

$pass = 0; $fail = 0
function Check([string]$name, [bool]$cond, [string]$extra = "") {
    if ($cond) { Write-Host "  ok    $name"; $script:pass++ }
    else       { Write-Host "  FAIL  $name  $extra"; $script:fail++ }
}

# ── MySQL 客户端（只用于"重置夹具库"，不是被测对象）────────────────────────────
function Find-MySqlCli {
    foreach ($c in @("mariadb.exe", "mysql.exe")) {
        $g = Get-Command $c -ErrorAction SilentlyContinue
        if ($null -ne $g) { return $g.Source }
    }
    if ($env:CLUB_MYSQL_CLI -and (Test-Path $env:CLUB_MYSQL_CLI)) { return $env:CLUB_MYSQL_CLI }
    $cands = @()
    if ($env:CLUB_MARIADB_HOME) { $cands += (Join-Path $env:CLUB_MARIADB_HOME "bin\mariadb.exe") }
    $cands += @(
        "E:\cangjie\mariadb\mariadb-11.4.13-winx64\bin\mariadb.exe",
        "D:\cangjie\mariadb\mariadb-11.4.13-winx64\bin\mariadb.exe",
        "C:\mariadb\bin\mariadb.exe",
        "C:\Program Files\MariaDB 11.4\bin\mariadb.exe",
        "C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe"
    )
    foreach ($r in @("E:\cangjie\mariadb", "D:\cangjie\mariadb")) {
        if (Test-Path $r) {
            $hits = Get-ChildItem $r -Directory -ErrorAction SilentlyContinue |
                    ForEach-Object { Join-Path $_.FullName "bin\mariadb.exe" } |
                    Where-Object { Test-Path $_ }
            if ($hits) { return ($hits | Select-Object -First 1) }
        }
    }
    foreach ($c in $cands) { if (Test-Path $c) { return $c } }
    return $null
}

$mysqlCli = Find-MySqlCli
# 社团库夹具的清理复用共用实现（tests\mysql-common.ps1 的 Reset-ClubMySqlSchema）：
# 它负责"把 9 张表的 DROP 拼在一起、并经 cmd 丢掉 stderr"（理由见那边的注释）。
# 本脚本自己那份 MySql() 用的是上面从 admin.env 读出的连接参数（**后台 RBAC 库**那套），
# 而共用实现的脚本级变量指的就是同一台服务器 —— 赋上同一组值即可。
. (Join-Path $PSScriptRoot "mysql-common.ps1")
$script:ClubMySqlCli = $mysqlCli
$script:ClubDbHost   = $dbHost
$script:ClubDbPort   = $dbPort
$script:ClubDbUser   = $dbUser
$script:ClubDbPass   = $dbPass
# 跑一句 SQL（**返回干净的 stdout**；stderr 落到临时文件并留在 `$script:MySqlLastErr`，
# 供"连不上"那一处原样打印 —— 2026-10-04 起不再把 stderr 丢给 NUL：
# 丢掉 stderr 会把"客户端 TLS/SSPI 握手失败"这类有明确指向的报错一起丢掉，
# 上层只剩"连不上 / 口令不对"，方向常常是错的。也**不并进 stdout**，免得污染解析）。
# ⚠ 为什么经 cmd 而不是 PowerShell 的 `2>$null`：本脚本是 `$ErrorActionPreference='Stop'`，
#   而 PS 5.1 在**捕获**原生命令输出时只要 stderr 非空就造 NativeCommandError 并终止脚本，
#   实测 `2>$null` 压不住（stderr 重定向了，错误记录已产生）。症状是 `DROP TABLE IF EXISTS`
#   在"表本来不存在"时的一句 information 提示就让夹具准备阶段整个崩掉。
#   同一个坑在 tests\mysql-common.ps1 里也记了一份（那边是共用实现）。
function MySql([string]$sql, [string]$dbName) {
    $a = @("-h", $dbHost, "-P", "$dbPort", "-u", $dbUser, "--protocol=tcp",
           "--batch", "--skip-column-names", "--connect-timeout=5")
    # 默认 --skip-ssl（2026-10-04，与共用实现 mysql-common.ps1 同口径）；
    # 要真实 TLS 就设 CLUB_MYSQL_USE_SSL=1。
    if ($env:CLUB_MYSQL_USE_SSL -ne "1") { $a += "--skip-ssl" }
    if ($dbPass.Length -gt 0) { $a += "-p$dbPass" }
    if ($dbName.Length -gt 0) { $a += $dbName }
    $a += @("-e", $sql)
    $parts = @(('"' + $script:mysqlCli + '"'))
    foreach ($x in $a) { $parts += ('"' + ($x -replace '"', '\"') + '"') }
    $errFile = [IO.Path]::GetTempFileName()
    $out = (& cmd /c (($parts -join ' ') + ' 2>"' + $errFile + '"') | Out-String)
    $script:MySqlLastErr = ""
    if (Test-Path $errFile) {
        $script:MySqlLastErr = [IO.File]::ReadAllText($errFile)
        Remove-Item $errFile -Force -ErrorAction SilentlyContinue
    }
    return $out
}
# 能不能连上（下面"新前提检查"用它；失败时把客户端的原始报错留给调用方去讲）
function Test-MySqlReachable {
    if ($null -eq $mysqlCli) { return $false }
    try { $null = MySql "SELECT 1" ""; return $true } catch { return $false }
}
function BizCode($r) {
    $m = [regex]::Match($r.Body, '"code"\s*:\s*(-?\d+)')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return -999
}
# 统一请求：成功与失败都要能拿到 body（PS 5.1 从 $_.Exception.Response 读流恒为空串）
function Hit($method, $path, $json, $token, $origin, $preflight) {
    $h = @{}
    if ($token)  { $h['Authorization'] = "Bearer $token" }
    if ($origin) { $h['Origin'] = $origin }
    if ($preflight) {
        # CORS 预检的判定条件是"有 Access-Control-Request-Method 头"，少了它框架不会当预检处理
        $h['Access-Control-Request-Method']  = $method
        $h['Access-Control-Request-Headers'] = 'authorization,content-type'
    }
    $url = if ($path -like 'http*') { $path } else { "$opsBase$path" }
    $req = [System.Net.WebRequest]::Create($url)
    $req.Proxy = $null
    $req.Method = $method
    $req.Timeout = 30000
    foreach ($k in $h.Keys) { $req.Headers[$k] = $h[$k] }
    if ($json) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $req.ContentType = 'application/json; charset=utf-8'
        $req.ContentLength = $bytes.Length
        $s = $req.GetRequestStream(); $s.Write($bytes, 0, $bytes.Length); $s.Close()
    }
    try { $resp = $req.GetResponse() } catch [System.Net.WebException] { $resp = $_.Exception.Response }
    if ($null -eq $resp) { return @{ Status = 0; Body = "" } }
    $reader = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
    $text = $reader.ReadToEnd(); $reader.Close(); $resp.Close()
    return @{ Status = [int]$resp.StatusCode; Body = $text }
}
# 打 club-server（浏览器视角：带 Origin）
function Club($method, $path, $json, $token) {
    return Hit $method ($clubBase + $path) $json $token "http://127.0.0.1:$opsPort"
}

Write-Host "=== 轻舟后台 · 社团管理运维页 端到端（专用运维账号） ==="
Write-Host "  运维台 $opsBase    club-server $clubBase    社团库 $clubDir"
Write-Host "  运维账号 $opsPhone（role = ops）"
Write-Host "  后台 RBAC 库 MySQL ${dbUser}@${dbHost}:${dbPort}/${dbName}"
Write-Host ""

# ---------- 新前提检查（2026-09-19）：没有可连的 MySQL，运维台根本起不来 ----------
# 目的是"取不到就说清楚、并判失败"，而不是让 admin.exe 起不来、脚本报一句"服务未就绪"
# 把真正的病因埋掉。
Check "找到 MySQL 客户端（用于重置夹具库）" ($null -ne $mysqlCli) `
      "已在 PATH / CLUB_MYSQL_CLI / 常见安装位置里找过 mariadb.exe、mysql.exe"
Check "MySQL 可连（${dbHost}:${dbPort}，用户 ${dbUser}）" ($null -ne $mysqlCli -and (Test-MySqlReachable)) `
      "起服务器：& '<MariaDB>\bin\mysqld.exe' --datadir='<数据目录>' --port=$dbPort --console（详见 docs\mysql-backend.md）"
if ($null -eq $mysqlCli -or -not (Test-MySqlReachable)) {
    Write-Host ""
    Write-Host "  ⚠ 连不上 MySQL / 找不到客户端，测试无法继续（这是**失败**，不是跳过）。"
    Write-Host "    运维台自己的 RBAC 数据层已切到 MySQL，连接参数取自 build\admin\admin.env 的 mysql_*。"
    Write-Host "    可设 `$env:CLUB_MYSQL_CLI 或 `$env:CLUB_MARIADB_HOME 指到内置的便携版 MariaDB。"
    # 2026-10-04：把客户端的原始报错原样打出来（否则只剩"连不上"，方向常常是错的）
    if ($script:MySqlLastErr) {
        Write-Host "  客户端原始报错（$mysqlCli）：" -ForegroundColor Yellow
        Write-Host ($script:MySqlLastErr.Trim()) -ForegroundColor Yellow
    }
    Write-Host ("运维页验证： PASS {0} / FAIL {1}" -f $pass, $fail)
    exit 1
}

# ---------- 夹具：干净的社团库 + 会长 + 运维账号 + 自己的 admin.env ----------
$clubAbs = Join-Path $build $clubDir
if (Test-Path $clubAbs) { Remove-Item $clubAbs -Recurse -Force }
# 社团库（club-server 的库）清成空库当夹具 —— 用独立库名，不碰别人的 club。
# club-server 首次连会自动建库建表，这里先 DROP 表即可（库不存在时 DROP 是空操作）。
$clubDsn = "mysql://${dbUser}:${dbPass}@${dbHost}:${dbPort}/${clubDb}"
Write-Host "  社团库 MySQL ${dbUser}@${dbHost}:${dbPort}/${clubDb}（测试专用）"
Reset-ClubMySqlSchema $clubDb
# ⚠ 审计日志目录是**相对 cwd** 的（README 六条坑之一）：必须在 build\ 下执行，
#   否则日志会落到 server\ops-e2e-data（本轮真踩过一次，那时是数据目录，现在是审计目录）。
Push-Location $build
$initOut  = & $clubExe init-admin $presPhone $presPw $clubDsn --data-dir $clubDir 2>&1
$initOut2 = & $clubExe init-admin "13900000008" $presPw $clubDsn --data-dir $clubDir 2>&1   # 非空库：应被拒绝
$opsOut   = & $clubExe init-ops $opsPhone $opsPw $clubDsn --data-dir $clubDir 2>&1
$opsOut2  = & $clubExe init-ops $opsPhone $opsPw $clubDsn --data-dir $clubDir 2>&1          # 幂等：重设口令
Pop-Location
$registerCode = ""
if (($initOut -join "`n") -match '当前注册口令：([A-Z0-9]+)') { $registerCode = $Matches[1] }
if (Test-Path $envFile) { Copy-Item $envFile $envBackup -Force }
# 2026-09-19：admin.env 里给出的是 **mysql_\*** 而不是 db=（数据层已换成 MySQL）。
# 2026-09-20：再加 **club_mysql_db** —— 运维台读的社团库现在也是 MySQL 库
#   （不再是 club_data 目录下的 db.json）；club_data 只表示审计日志目录。
# 「隔离」体现在端口 / 社团库（$clubDb）/ 运维账号上；RBAC 库沿用你那份 admin.env 的值，
# 但下面会把它的表清空（验证"新库首启自动建表 + 换掉种子默认口令"）——
# 别拿一个和别人共用的库跑本脚本，要隔离就把这里的 mysql_db 改成另一个库名。
$envLines = @(
    "port=$opsPort",
    "mysql_host=$dbHost",
    "mysql_port=$dbPort",
    "mysql_user=$dbUser",
    "mysql_pass=$dbPass",
    "mysql_db=$dbName",
    "club_mysql_db=$clubDb",
    "secret=ops-check-0123456789abcdef0123456789abcdef",
    "ttl=7200",
    "club_data=../$clubDir",
    "club_api=$clubBase",
    "club_port=$clubPort",
    "club_user=$opsPhone",
    "club_pass=$opsPw"
)
[System.IO.File]::WriteAllLines($envFile, $envLines, [System.Text.UTF8Encoding]::new($false))
# 清掉后台的表 = 制造"新库"（表由 admin.exe 首启自动建、并换掉种子默认口令）。
# 判据同 admin_main.cj：只看 users 表；表不存在时客户端报错，那正是干净库的形态。
try { $null = MySql "DROP TABLE IF EXISTS users, roles, permissions, role_permissions" $dbName } catch { }
# 旧的文件后端产物（本脚本以前用它做隔离）不再需要，顺手清掉，免得混淆"走的哪条路"
Remove-Item (Join-Path $admin "admin-data\ops-e2e-rbac.json") -Force -ErrorAction SilentlyContinue

$clubProc = $null; $adminProc = $null
try {
    Check "init-admin 建库并给出注册口令" ($registerCode.Length -ge 4) "code=[$registerCode]"
    Check "init-admin 对非空库幂等拒绝（不覆盖数据）" (($initOut2 -join "`n") -match '已存在会长账号') "out=$($initOut2 -join ' ')"
    Check "init-ops 创建专用运维账号" (($opsOut -join "`n") -match '已创建运维账号') "out=$($opsOut -join ' ')"
    Check "init-ops 幂等（重设口令 + 校准角色）" (($opsOut2 -join "`n") -match '已重设运维账号口令') "out=$($opsOut2 -join ' ')"

    $clubProc = Start-Process -FilePath $clubExe -ArgumentList @("serve", "$clubPort", $clubDsn, "--data-dir", $clubDir) `
        -WorkingDirectory $build -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $build "ops-e2e-club.out.log") -RedirectStandardError (Join-Path $build "ops-e2e-club.err.log")
    $adminProc = Start-Process -FilePath $adminExe -WorkingDirectory $admin -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $admin "ops-e2e.out.log") -RedirectStandardError (Join-Path $admin "ops-e2e.err.log")

    $ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 250
        try {
            $a = (Invoke-WebRequest "$opsBase/health" -UseBasicParsing -TimeoutSec 2).StatusCode
            $b = (Invoke-WebRequest "$clubBase/health" -UseBasicParsing -TimeoutSec 2).StatusCode
            if ($a -eq 200 -and $b -eq 200) { $ready = $true; break }
        } catch { }
    }
    Check "两个服务都就绪（运维台 + club-server）" $ready
    if (-not $ready) { throw "未就绪" }

    # ---------- 1) 静态入口 ----------
    $r = Hit "GET" "/club" $null $null $null
    Check "GET /club -> 200 且是前端页面（SPA fallback）" (($r.Status -eq 200) -and ($r.Body -match 'assets/index-')) "status=$($r.Status)"
    $r = Hit "GET" "/" $null $null $null
    Check "GET / -> 200" ($r.Status -eq 200) "status=$($r.Status)"

    # ---------- 2) 后台 RBAC ----------
    # N-29（2026-09-17）：后台口令不再写死。本脚本开跑前把后台那几张表**清空了**
    # （2026-09-19 换成 MySQL 之后，"删掉自己的 rbac.json"这个动作等价于 DROP TABLE），
    # 所以这里**必然是首次建库** —— admin.exe 会随机生成口令并追加到 admin.env 的
    # admin_pass / user_pass，因此必须在**面板启动之后**读它。
    #
    # ⚠ 这里**刻意不再回退到 "admin123"**（换 MySQL 前的老写法是 `$adminPw = "admin123"`）：
    #   那个回退值会让本脚本在"口令换随机"这段逻辑坏掉时**照样通过**——
    #   只要库里恰好留着公开默认口令，"用 admin123 登录"就会成功。回退值现在只在
    #   下面那条**反向断言**里出现（默认口令必须被拒）。与 admin-check.ps1 同一口径。
    $r = Hit "POST" "/api/login" '{"username":"admin","password":"admin123"}' $null $null
    Check "N-29 闸门：admin123 **必须**被拒（新库首启已换掉框架种子口令）" `
        ((BizCode $r) -ne 0) "code=$(BizCode $r) body=$($r.Body)"
    $r = Hit "POST" "/api/login" '{"username":"user","password":"user123"}' $null $null
    Check "N-29 闸门：user123 **必须**被拒" ((BizCode $r) -ne 0) "code=$(BizCode $r) body=$($r.Body)"

    $adminPw = ""
    $userPw  = ""
    foreach ($line in (Get-Content $envFile -Encoding UTF8)) {
        $t = $line.Trim()
        if ($t -match '^admin_pass\s*=\s*(\S+)') { $adminPw = $Matches[1] }
        if ($t -match '^user_pass\s*=\s*(\S+)')  { $userPw  = $Matches[1] }
    }
    Check "首启把随机口令写回了 admin.env" (($adminPw.Length -ge 8) -and ($userPw.Length -ge 8)) `
        "admin_pass 长度=$($adminPw.Length) user_pass 长度=$($userPw.Length)"
    $r = Hit "POST" "/api/login" (ConvertTo-Json @{ username = "admin"; password = $adminPw } -Compress) $null $null
    Check "后台登录 -> code=0" ((BizCode $r) -eq 0) "body=$($r.Body)"
    $token = $null
    if ($r.Body -match '"token"\s*:\s*"([^"]+)"') { $token = $Matches[1] }
    Check "拿到后台 token" ($null -ne $token -and $token.Length -gt 40)
    $r = Hit "GET" "/api/me" $null $token $null
    Check "GET /api/me -> HTTP 200 且 can_ops=true" (($r.Status -eq 200) -and ($r.Body -match '"can_ops"\s*:\s*true')) "status=$($r.Status) body=$($r.Body)"

    $r = Hit "GET" "/api/club/overview" $null $null $null
    Check "运维接口无 token -> HTTP 401 且 code=401" (($r.Status -eq 401) -and ((BizCode $r) -eq 401)) "status=$($r.Status) body=$($r.Body)"

    $r = Hit "POST" "/api/login" (ConvertTo-Json @{ username = "user"; password = $userPw } -Compress) $null $null
    $tokenUser = $null
    if ($r.Body -match '"token"\s*:\s*"([^"]+)"') { $tokenUser = $Matches[1] }
    $r = Hit "GET" "/api/club/overview" $null $tokenUser $null
    Check "运维接口 user 角色 -> HTTP 403 且 code=403" (($r.Status -eq 403) -and ((BizCode $r) -eq 403)) "status=$($r.Status) body=$($r.Body)"

    # ---------- 3) 只读视图 ----------
    $r = Hit "GET" "/api/club/overview" $null $token $null
    Check "GET /api/club/overview -> HTTP 200（不是上游那个 404）" ($r.Status -eq 200) "status=$($r.Status)"
    $ov = $null
    if ((BizCode $r) -eq 0) { $ov = ($r.Body | ConvertFrom-Json).data }
    Check "概览：1 个会长 / 4 个部门 / 社团库有数据" (($null -ne $ov) -and ($ov.members.total -eq 2) -and ($ov.members.president -eq 1) -and ($ov.depts -eq 4) -and ($ov.members.total -gt 0)) "ov=$($r.Body)"
    Check "概览：注册口令可读（运维需要发口令）" (($null -ne $ov) -and $ov.register.has_code) "register=$($ov.register | ConvertTo-Json -Compress)"
    # 概览的键名口径（2026-09-20）：与 /api/club/config 同一件事 —— 业务数据在 **MySQL** 里，
    # data 目录下的 db.json **不再产生**。原先概览报 db_file / db_exists / db_bytes / db_mtime，
    # 迁移后会永远显示「库文件 …\db.json · 0.0 KB · 最后写入 —」，那是会误导运维的谎话
    # （看起来像"库空了"）。现在改成 db_backend=mysql，文件侧只报真正还在写的 audit.log。
    Check "概览不再报 db.json（db_file / db_exists / db_bytes / db_mtime 全删）" `
        (-not ($r.Body -match 'db_file|db_exists|db_bytes|db_mtime')) "body=$($r.Body)"
    Check "概览标明后端是 mysql（db_backend）" (($null -ne $ov) -and ($ov.db_backend -eq 'mysql')) "backend=$($ov.db_backend)"
    Check "概览仍报审计日志（file 指向 audit.log / bytes 与 lines 是数）" `
        (($null -ne $ov) -and ($ov.audit.file -match 'audit\.log$') -and ($ov.audit.bytes -is [int]) -and ($ov.audit.lines -is [int])) "audit=$($ov.audit | ConvertTo-Json -Compress)"

    $r = Hit "GET" "/api/club/config" $null $token $null
    Check "GET /api/club/config -> 200 且给出 club-server 地址、社团库、运维账号" `
        (($r.Status -eq 200) -and ($r.Body -match [regex]::Escape($clubBase)) -and ($r.Body -match [regex]::Escape($clubDb)) -and ($r.Body -match '"ops_account_configured"\s*:\s*true')) "body=$($r.Body)"
    # 键名口径（2026-09-20）：社团库是 **MySQL 库**，不再是 club_data 下的 db.json。
    # 断言"没有会撒谎的 club_db_file 键"，并且新键给的是库名 + 审计日志路径。
    Check "config 不再声称有个 db.json（club_db_file 已删）" (-not ($r.Body -match 'club_db_file')) "body=$($r.Body)"
    Check "config 给出社团库名 club_database=$clubDb" ($r.Body -match ('"club_database"\s*:\s*"' + [regex]::Escape($clubDb) + '"')) "body=$($r.Body)"
    Check "config 给出审计日志路径（club_audit_file）" ($r.Body -match '"club_audit_file"\s*:\s*"[^"]*audit\.log"') "body=$($r.Body)"

    $r = Hit "GET" "/api/club/members" $null $token $null
    Check "GET /api/club/members -> 200（会长 + 运维 共 2 人）" (($r.Status -eq 200) -and ($r.Body -match '"total"\s*:\s*2')) "body=$($r.Body)"
    Check "名录视图**不含** pw_hash / pw_salt / pw_iter" (-not ($r.Body -match 'pw_hash|pw_salt|pw_iter')) "泄露？$($r.Body)"
        # 对照：**App 的名录里看不到系统账号**（h_member 的 handleMemberList 过滤 role = ops，
# 免得客户端把运维显示成"待分配"），而运维台直读社团库（2026-09-20 起是直连 MySQL）、
# **照常显示**它 —— 这里断言的是后者；
    # 前者由 smoke.ps1 的"名录里没有运维账号"三条闸门盯着。
    Check "运维账号在运维台名录里能认出（role = ops；App 名录里是隐藏的）" ($r.Body -match '"role"\s*:\s*"ops"') "body=$($r.Body)"
    $r = Hit "GET" "/api/club/depts" $null $token $null
    Check "GET /api/club/depts -> 200 且主席团 1 人" (($r.Status -eq 200) -and ($r.Body -match '主席团') -and ($r.Body -match '"active_members"\s*:\s*1')) "body=$($r.Body)"
    # 分页上界（2026-09-18 回归闸门，见 club_view.cj 的 clubPaging）：page 无上界时
    # `(page - 1) * size` 在仓颉里溢出即抛，异常又被链上 passOnNotFound 留下的 404 壳吞掉，
    # 于是**有效端点被说成"不存在"**（HTTP 404 + {"error":"Not Found"}）。夹到 1e6 后必须是 200。
    $r = Hit "GET" "/api/club/members?page=9223372036854775807&size=500" $null $token $null
    Check "GET /api/club/members?page=Int64.max -> 200（page 夹紧，不再 404）" (($r.Status -eq 200) -and ((BizCode $r) -eq 0)) "status=$($r.Status) body=$($r.Body)"
    foreach ($ep in '/api/club/tasks', '/api/club/plans', '/api/club/links', '/api/club/audit?limit=50') {
        $r = Hit "GET" $ep $null $token $null
        Check "GET $ep -> code=0" ((BizCode $r) -eq 0) "status=$($r.Status) body=$($r.Body)"
    }
    $r = Hit "GET" "/api/club/server-health" $null $token $null
    Check "GET /api/club/server-health -> up=true（后台侧探测 club-server）" (($r.Status -eq 200) -and ($r.Body -match '"up"\s*:\s*true')) "body=$($r.Body)"

    # ---------- 4) 运维会话：后台代持专用运维账号，页面不接触任何社团口令 ----------
    $r = Hit "GET" "/api/club/session" $null $token $null
    $sess = $null
    if ((BizCode $r) -eq 0) { $sess = ($r.Body | ConvertFrom-Json).data }
    Check "GET /api/club/session -> 已配置运维账号" (($r.Status -eq 200) -and $sess.configured) "body=$($r.Body)"
    Check "运维会话身份 = 专用运维账号（role = ops，标签「运维」）" `
        (($sess.identity.role -eq 'ops') -and ($sess.identity.role_label -eq '运维') -and ($sess.identity.phone -eq $opsPhone)) "identity=$($sess.identity | ConvertTo-Json -Compress)"
    $ctoken = $sess.token
    Check "拿到 club-server 运维令牌（无需任何社团账号口令）" ($null -ne $ctoken -and $ctoken.Length -gt 40) "token=$ctoken"

    $r = Club "GET" "/api/v1/auth/me" $null $ctoken
    Check "该令牌在 club-server 侧确实是 ops 身份" (($r.Status -eq 200) -and ($r.Body -match '"role"\s*:\s*"ops"')) "body=$($r.Body)"

    # ---------- 4b) 用**运维账号**直接登录运维台（2026-09-17 新增） ----------
    # 登录框不再预填 admin/admin123（那对公开默认值 N-29 起已作废），也不再只认后台账号：
    # 手机号 + 运维口令即可登进来，登进来之后写路径用的就是这同一个账号。
    $r = Hit "POST" "/api/login" (ConvertTo-Json @{ username = $opsPhone; password = $opsPw } -Compress) $null $null
    Check "运维账号可登录运维台（手机号 + 运维口令）-> code=0" ((BizCode $r) -eq 0) "status=$($r.Status) body=$($r.Body)"
    $opsToken = $null
    if ($r.Body -match '"token"\s*:\s*"([^"]+)"') { $opsToken = $Matches[1] }
    Check "拿到运维身份的会话令牌" ($null -ne $opsToken -and $opsToken.Length -gt 40)

    $r = Hit "GET" "/api/me" $null $opsToken $null
    Check "该会话 /api/me 身份 = ops（role=ops 且 can_ops=true）" `
        (($r.Status -eq 200) -and ($r.Body -match '"role"\s*:\s*"ops"') -and ($r.Body -match '"can_ops"\s*:\s*true')) "status=$($r.Status) body=$($r.Body)"
    Check "/api/me 标出这是运维账号登录（is_ops_account，前端据此藏掉后台管理入口）" `
        ($r.Body -match '"is_ops_account"\s*:\s*true') "body=$($r.Body)"
    Check "运维身份的用户名就是登录用的手机号" ($r.Body -match [regex]::Escape($opsPhone)) "body=$($r.Body)"

    $r = Hit "GET" "/api/club/overview" $null $opsToken $null
    Check "运维身份可读写运维接口（overview -> HTTP 200）" ($r.Status -eq 200) "status=$($r.Status) body=$($r.Body)"

    # 后台管理接口（用户 / 角色 / 权限）必须仍然只对 admin 開放：运维身份在那里没有条目
    $r = Hit "GET" "/api/users" $null $opsToken $null
    Check "运维身份进不了后台用户管理（不是 200）" (($r.Status -eq 401) -or ($r.Status -eq 403)) "status=$($r.Status) body=$($r.Body)"

    # 两类失败必须在**登录这一步**就分清楚，且都不能放行
    $r = Hit "POST" "/api/login" (ConvertTo-Json @{ username = $opsPhone; password = "WrongPass2026" } -Compress) $null $null
    Check "运维口令错 -> HTTP 401（不是 500、更不是放行）" (($r.Status -eq 401) -and ((BizCode $r) -eq 401)) "status=$($r.Status) body=$($r.Body)"
    Check "口令错的提示给出处置方向（提到 init-ops / club-server，而不是干巴巴一句 invalid）" `
        ($r.Body -match 'init-ops|club-server') "body=$($r.Body)"

    $r = Hit "POST" "/api/login" (ConvertTo-Json @{ username = $presPhone; password = $presPw } -Compress) $null $null
    Check "会长账号**不能**登录运维台（运维不该由会长执行）-> HTTP 403" (($r.Status -eq 403) -and ((BizCode $r) -eq 403)) "status=$($r.Status) body=$($r.Body)"
    Check "403 的提示说明只接受 init-ops 建的运维账号" ($r.Body -match '运维账号') "body=$($r.Body)"

    # 后备账号仍要能登 —— 新路径不能把老路径挤掉
    $r = Hit "POST" "/api/login" (ConvertTo-Json @{ username = "admin"; password = $adminPw } -Compress) $null $null
    Check "后台账号 admin 仍可登录（老路径未被挤掉）" ((BizCode $r) -eq 0) "status=$($r.Status) body=$($r.Body)"

    # ---------- 5) 写路径（全部以运维身份） ----------
    $r = Hit "OPTIONS" "$clubBase/api/v1/members/2/assign" $null $null "http://127.0.0.1:$opsPort" $true
    Check "club-server CORS 预检 -> 204（浏览器直连的前提）" ($r.Status -eq 204) "status=$($r.Status)"

    $r = Club "POST" "/api/v1/auth/register" ("{""register_code"":""$registerCode"",""phone"":""13900000002"",""name"":""运维测试"",""password"":""TestPass2026"",""dept_id"":2}") $null
    Check "注册一个待分配成员 -> ok=true" (($r.Status -eq 201) -and ($r.Body -match '"ok"\s*:\s*true')) "body=$($r.Body)"

    $r = Hit "GET" "/api/club/members?status=pending" $null $token $null
    $pend = ($r.Body | ConvertFrom-Json).data.items
    Check "运维页立刻看到这条待分配（读的是同一个 MySQL 库）" (($r.Body -match '运维测试') -and ($r.Body -match '课题部')) "body=$($r.Body)"
    $mid = 0
    if ($null -ne $pend -and $pend.Count -ge 1) { $mid = $pend[0].id }

    $r = Club "POST" "/api/v1/members/$mid/assign" '{"role":"ops","dept_id":2}' $ctoken
    Check "ops 不可由 API 分配（只能用 init-ops 创建）" (($r.Body -match '"ok"\s*:\s*false') -and ($r.Body -match 'VALIDATION_FAILED')) "body=$($r.Body)"

    $r = Club "POST" "/api/v1/members/$mid/assign" '{"role":"lead","dept_id":2}' $ctoken
    Check "分配为部长（role = lead）-> ok=true" (($r.Status -eq 200) -and ($r.Body -match '"ok"\s*:\s*true')) "body=$($r.Body)"
    $r = Hit "GET" "/api/club/members?q=运维测试" $null $token $null
    Check "角色中文标签正确（lead → 部长；代号写错会显示空白）" ($r.Body -match '"role_label"\s*:\s*"部长"') "body=$($r.Body)"

    $r = Hit "GET" "/api/club/overview" $null $token $null
    Check "写入后概览随之变化（active=3 / pending=0）" (($r.Body -match '"active"\s*:\s*3') -and ($r.Body -match '"pending"\s*:\s*0')) "body=$($r.Body)"

    $r = Club "POST" "/api/v1/members/1/reset-password" '{}' $ctoken
    Check "运维可重置**会长**的口令（会长忘口令是典型运维场景）" (($r.Status -eq 200) -and ($r.Body -match 'temporary_password"\s*:\s*"[^"]+')) "body=$($r.Body)"

    $r = Club "POST" "/api/v1/register-config/rotate" '{}' $ctoken
    $newCode = ""
    if ($r.Body -match '"code"\s*:\s*"([A-Z0-9]+)"') { $newCode = $Matches[1] }
    Check "运维可换注册口令（副会长做不到，会长/运维才行）" ($newCode.Length -ge 4 -and $newCode -ne $registerCode) "old=$registerCode new=$newCode"
    Check "换口令的 updated_by 是运维（职责分离可见）" ($r.Body -match '"name"\s*:\s*"运维"') "body=$($r.Body)"

    $r = Club "POST" "/api/v1/depts" '{"name":"用户运营部","sort":9}' $ctoken
    Check "运维可新增部门（部门增删改：会长与运维独占）" (($r.Status -eq 201) -and ($r.Body -match '"ok"\s*:\s*true')) "status=$($r.Status) body=$($r.Body)"

    $r = Club "POST" "/api/v1/members/1/transfer-presidency" '{"self_role":"vice_president"}' $ctoken
    Check "运维**不能**移交会长（这一档唯一的减法）" (($r.Status -eq 403) -and ($r.Body -match 'FORBIDDEN_ROLE')) "status=$($r.Status) body=$($r.Body)"

    $r = Club "POST" "/api/v1/members/$mid/disable" '{}' $ctoken
    Check "停用成员 -> ok=true" (($r.Status -eq 200) -and ($r.Body -match '"ok"\s*:\s*true')) "body=$($r.Body)"
    $r = Hit "GET" "/api/club/members?status=disabled" $null $token $null
    Check "运维页读到 disabled 名单" ($r.Body -match '运维测试') "body=$($r.Body)"

    # ---------- 6) 审计：动作 + **actor 是运维**（职责分离） ----------
    $r = Hit "GET" "/api/club/audit?limit=50" $null $token $null
    $au = ($r.Body | ConvertFrom-Json).data
    Check "审计日志解析出敏感操作（assign / reset-password / rotate / create-dept / disable）" `
        (($au.shown -ge 5) -and ($r.Body -match 'assign-member') -and ($r.Body -match 'reset-password') -and ($r.Body -match 'rotate-register-code')) "shown=$($au.shown)"
    Check "审计里 actor 是**运维**而不是会长（职责分离）" `
        (($au.items | Where-Object { $_.actor_name -eq '运维' } | Measure-Object).Count -ge 3) "actors=$(($au.items | ForEach-Object { $_.actor_name }) -join ',')"
    Check "审计行解析成功（parsed 全 true）" (-not ($r.Body -match '"parsed"\s*:\s*false')) ""

    # ---------- 7) 备份（2026-09-20 起：从 MySQL **导出 JSON 快照**，不是复制 db.json） ----------
    # 判据比原来强：不仅"文件真的落盘"，还要
    #   ① 快照**能被解析成 JSON**、② 里面真的有社团库的内容（部门/成员）、
    #   ③ 内容与**直查 MySQL** 的结果对得上（这才是"导出的是同一份数据"的证据）。
    $r = Hit "POST" "/api/club/backup" '{}' $token $null
    $bk = $null
    if ((BizCode $r) -eq 0) { $bk = ($r.Body | ConvertFrom-Json).data }
    Check "备份 -> code=0 且文件真的落盘" (($null -ne $bk) -and ($bk.files.Count -ge 1) -and (Test-Path (Join-Path $admin ($bk.files[0] -replace '/', '\')))) "body=$($r.Body)"
    $snapPath = $null
    if (($null -ne $bk) -and ($bk.files.Count -ge 1)) { $snapPath = (Join-Path $admin ($bk.files[0] -replace '/', '\')) }
    $snap = $null
    if ($null -ne $snapPath -and (Test-Path $snapPath)) {
        try { $snap = [System.IO.File]::ReadAllText($snapPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { $snap = $null }
    }
    Check "备份件是可解析的 JSON 快照（导出格式 = 原 db.json 结构）" ($null -ne $snap) "path=$snapPath"
    $myMembers = [int](MySql "SELECT COUNT(*) FROM members;" $clubDb).Trim()
    $myDepts   = [int](MySql "SELECT COUNT(*) FROM departments;" $clubDb).Trim()
    Check "快照里的成员数与 MySQL 直查一致" (($null -ne $snap) -and ($snap.members.Count -eq $myMembers)) "snap=$($snap.members.Count) mysql=$myMembers"
    Check "快照里的部门数与 MySQL 直查一致" (($null -ne $snap) -and ($snap.departments.Count -eq $myDepts)) "snap=$($snap.departments.Count) mysql=$myDepts"
    Check "快照带注册口令（运维换口令后要能对上）" (($null -ne $snap) -and ($snap.register_code.Length -ge 4)) "code=$($snap.register_code)"
    Check "备份响应里有 db_bytes（= 快照字节数）" (($null -ne $bk) -and ($bk.db_bytes -gt 0)) "bytes=$($bk.db_bytes)"
    Check "备份响应标明数据源是 mysql（不是文件）" (($null -ne $bk) -and ($bk.source -like 'mysql*')) "source=$($bk.source)"

    # ---------- 8) 优雅关闭 ----------
    # 这条同时是**回归闸门**：原先 handleShutdown 立刻 spawn shutdown()，
    # 会先于本响应写出把服务 close 掉 → 客户端拿到 200 + **空 body**（实测 8 次里 6 次）。
    # 现在关停线程先 sleep 1 秒再关（见 server/src/main.cj 的注释）。
    $r = Club "POST" "/admin/shutdown" '{}' $ctoken
    Check "club-server 优雅关闭 -> HTTP 200 且回执 ok=true" (($r.Status -eq 200) -and ($r.Body -match '"ok"\s*:\s*true')) "status=$($r.Status) body=[$($r.Body)]"
    $r = Hit "POST" "/admin/shutdown" '{}' $token $null
    Check "运维台优雅关闭 -> code=0" ((BizCode $r) -eq 0) "body=$($r.Body)"
    $clubGone = $false; $adminGone = $false
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 250
        if ($clubProc.HasExited)  { $clubGone = $true }
        if ($adminProc.HasExited) { $adminGone = $true }
        if ($clubGone -and $adminGone) { break }
    }
    Check "两个进程都自行退出" ($clubGone -and $adminGone) "club=$clubGone admin=$adminGone"
    $log = Get-Content (Join-Path $admin "ops-e2e.out.log") -ErrorAction SilentlyContinue
    Check "运维台日志出现 graceful shutdown complete" (($log -join "`n") -match 'graceful shutdown complete')
    $err = Get-Content (Join-Path $admin "ops-e2e.err.log") -ErrorAction SilentlyContinue
    Check "运维台 stderr 无异常" ([string]::IsNullOrWhiteSpace(($err -join ""))) "err=$($err -join ' ')"
} finally {
    if ($null -ne $clubProc  -and -not $clubProc.HasExited)  { Stop-Process -Id $clubProc.Id  -Force }
    if ($null -ne $adminProc -and -not $adminProc.HasExited) { Stop-Process -Id $adminProc.Id -Force }
    # 还原你自己的 admin.env（本脚本只是借它跑一遍）
    if (Test-Path $envBackup) { Move-Item $envBackup $envFile -Force }
}

Write-Host ""
Write-Host ("运维页验证： PASS {0} / FAIL {1}" -f $pass, $fail)
if ($fail -gt 0) { exit 1 }
exit 0
