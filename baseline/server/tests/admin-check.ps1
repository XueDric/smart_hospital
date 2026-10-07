# admin-check.ps1 —— 轻舟后台管理界面（examples\admin.cj + **MySQL** 数据层）端到端验证
#
# 覆盖：
#   1) 自包含产物：build\admin\admin.exe + admin-web\dist + admin.env
#   2) 静态托管 + SPA（/ 返回 index.html，assets 可取）
#   3) /api/login 签发 JWT；/api/me /api/dashboard 带 token 可用
#   4) 鉴权 + RBAC：/api/users 无 token 被拒，带 admin token 放行
#   5) 数据层是 **MySQL**（不是 CangDB、也不是本地 JSON 文件）：
#      首启自动建表 + 灌种子，随后**种子的公开默认口令必须失效**（N-29 回归闸门）
#   6) 优雅关闭：POST /admin/shutdown 后进程自行退出
#
# ⚠⚠ 新前提（2026-09-19 起）：**本脚本需要一台可连的 MySQL / MariaDB**。
#   运维台的 RBAC 数据层已从 JSON 文件（build\admin\admin-data\rbac.json）切到 MySQL，
#   连接参数取自 build\admin\admin.env 的 mysql_host / mysql_port / mysql_user /
#   mysql_pass / mysql_db（默认 127.0.0.1:3306/root/club_rbac；本机联调是 3307 +
#   口令 clubroot123）。取不到连接就是 **FAIL**，不会静默跳过 —— 数据层跑不起来时
#   "这个后台能不能用"根本没有答案，跳过只会把"没测"伪装成"通过"。
#   起一个本机 MariaDB（便携版、不装服务）：
#     & "<MariaDB>\bin\mysqld.exe" --datadir="<数据目录>" --port=3307 --console
#   详细见 docs\mysql-backend.md。
#
# 关于 HTTP 状态码（重要）：
#   上游统一响应壳把业务码放在 **body 的 code 字段**（0=成功），HTTP 状态不承载业务语义；
#   admin-web 前端也是 `fetch(...).json()` 后只看 `code`，不看 status。
#   又因为 passOnNotFound 的路由在 miss 时会先把 ctx.status 设成 404，而后匹配上的处理器
#   用 respondOk/respondErr 时并不会重设 status —— 所以**成功响应也可能带 404**。
#   这是上游 e072980（当前 HEAD）本身的行为，不是我们的改动：已逐字节比对
#   third_party\qingzhou\src\{api,router,auth}.cj 与上游一致。
#   因此本脚本对 /api/* 断言 **body.code**（业务语义），只对 /health、静态资源断言 HTTP 200
#   （上游在这两处显式设置了 status）。见 docs/API-NOTES.md「坑 34」。
#
# 用法（cwd 任意）：powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\admin-check.ps1

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot          # server\
$dir  = Join-Path $root "build\admin"
$exe  = Join-Path $dir "admin.exe"

if (-not (Test-Path $exe)) {
    Write-Host "找不到 $exe —— 先跑：powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1 -Target admin"
    exit 2
}

# 从 admin.env 读取端口与 **MySQL 连接参数**（与 admin_main.cj 的 loadConfigFile 同源）
# 2026-09-19：数据层从 JSON 文件切到 MySQL，所以这里读的是 mysql_* 而不是 db=。
$envFile = Join-Path $dir "admin.env"
$port   = 3000
$dbHost = "127.0.0.1"
$dbPort = 3306
$dbUser = "root"
$dbPass = ""
$dbName = "club_rbac"
foreach ($line in Get-Content $envFile -Encoding UTF8) {
    $t = $line.Trim()
    if ($t -match '^port\s*=\s*(\d+)')         { $port   = [int]$Matches[1] }
    if ($t -match '^mysql_host\s*=\s*(\S+)')   { $dbHost = $Matches[1] }
    if ($t -match '^mysql_port\s*=\s*(\d+)')   { $dbPort = [int]$Matches[1] }
    if ($t -match '^mysql_user\s*=\s*(\S+)')   { $dbUser = $Matches[1] }
    if ($t -match '^mysql_pass\s*=\s*(\S*)')   { $dbPass = $Matches[1] }
    if ($t -match '^mysql_db\s*=\s*(\S+)')     { $dbName = $Matches[1] }
}
# ⚠ mysql_pass 为空时**退回本机联调的默认口令**（2026-09-20 补）。
#
# 新生成的 build\admin\admin.env 里 mysql_pass 是**空的**（build.ps1 的模板只在探测到本机
# 3307 那台时才预填口令）。而本机那台便携版 MariaDB 的 root **有口令** —— 留空会让本脚本的
# 夹具连不上，报出来的是驱动的 `Unsupported auth plugin`，从字面上完全看不出"口令为空"。
# 优先级：admin.env 里填了就用它 > 环境变量 CLUB_MYSQL_PASS > 本机联调默认 clubroot123。
if ($dbPass.Length -eq 0) {
    if ($env:CLUB_MYSQL_PASS) { $dbPass = $env:CLUB_MYSQL_PASS } else { $dbPass = "clubroot123" }
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
$base = "http://127.0.0.1:$port"

$pass = 0; $fail = 0
function Check([string]$name, [bool]$cond, [string]$extra = "") {
    if ($cond) { Write-Host "  ok    $name"; $script:pass++ }
    else       { Write-Host "  FAIL  $name  $extra"; $script:fail++ }
}

# ── MySQL 客户端（只用于"重置夹具库"与"直接查库核对"，不是被测对象）────────────
# 为什么要直接用客户端：本脚本要断言的是**数据真的进了 MySQL**（建表、种子、增删），
# 而不是"某个 JSON 文件里出现了某个字符串"。走 HTTP 只能证明接口自洽，证明不了后端。
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
    # 便携版目录名带版本号，换个版本就找不到 —— 再模糊找一层
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

# 连一次并取结果（失败抛异常；调用方自己决定是"判失败"还是"跳过某条断言"）
function MySql([string]$sql, [string]$dbName) {
    $a = @("-h", $dbHost, "-P", "$dbPort", "-u", $dbUser, "--protocol=tcp",
           "--batch", "--skip-column-names", "--connect-timeout=5")
    # 默认 --skip-ssl（2026-10-04，与共用实现 mysql-common.ps1 同口径）；
    # 要真实 TLS 就设 CLUB_MYSQL_USE_SSL=1。
    if ($env:CLUB_MYSQL_USE_SSL -ne "1") { $a += "--skip-ssl" }
    if ($dbPass.Length -gt 0) { $a += "-p$dbPass" }
    if ($dbName.Length -gt 0) { $a += $dbName }
    $a += @("-e", $sql)
    return (& $script:mysqlCli @a 2>&1)
}

# 统一请求：成功与失败（4xx/5xx）都必须能拿到 body。
# 为什么不用 Invoke-WebRequest：PS 5.1 里 4xx/5xx 会抛异常，从 $_.Exception.Response
# 读出来的流**已经是空的**（实测 body 恒为空串，会把"业务码是 0"误判成"没响应"）。
# 这里直接用 System.Net.WebRequest，成功/失败都走同一条读流路径。
function Hit($method, $path, $json, $token) {
    $h = @{}
    if ($token) { $h['Authorization'] = "Bearer $token" }
    $req = [System.Net.WebRequest]::Create("$base$path")
    $req.Proxy = $null                      # 本地回环不走系统代理
    $req.Method = $method
    $req.Timeout = 15000
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

# 取统一响应壳里的业务码；取不到返回 -999（便于和 0/401 区分）
function BizCode($r) {
    $m = [regex]::Match($r.Body, '"code"\s*:\s*(-?\d+)')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return -999
}

Write-Host "=== 轻舟后台管理界面 · 端到端（MySQL 数据层） ==="
Write-Host "  目录 $dir"
Write-Host "  端口 $port"
Write-Host "  MySQL ${dbUser}@${dbHost}:${dbPort}/${dbName}"
Write-Host ""

# ── 新前提检查（2026-09-19）：没有可连的 MySQL，这个后台根本起不来 ──────────────
# 目的是"取不到就说清楚、并判失败"，而不是让 admin.exe 在后台起不来、脚本报一句
# "服务未就绪"把真正的病因埋掉。
Check "找到 MySQL 客户端（用于重置夹具库与直接查库核对）" ($null -ne $mysqlCli) `
      "已在 PATH / CLUB_MYSQL_CLI / 常见安装位置里找过 mariadb.exe、mysql.exe"
if ($null -eq $mysqlCli) {
    Write-Host ""
    Write-Host "  ⚠ 找不到 MySQL 客户端。本脚本需要一台**可连的 MySQL / MariaDB**（运维台的 RBAC"
    Write-Host "    数据层已切到 MySQL）。三种处置："
    Write-Host "    ① 装 MySQL/MariaDB 客户端并放进 PATH；"
    Write-Host "    ② 设 `$env:CLUB_MYSQL_CLI = '<...>\bin\mariadb.exe' 指过去；"
    Write-Host "    ③ 项目内置的便携版 MariaDB：`$env:CLUB_MARIADB_HOME = 'E:\cangjie\mariadb\mariadb-11.4.13-winx64'"
    Write-Host "    （服务器本身没起的话：& '<...>\bin\mysqld.exe' --datadir='<数据目录>' --port=3307 --console）"
    Write-Host "    详见 docs\mysql-backend.md。"
}

$dbReachable = $false
if ($null -ne $mysqlCli) {
    try {
        $null = MySql "SELECT 1" ""
        $dbReachable = $true
    } catch {
        $dbReachable = $false
    }
}
Check "MySQL 可连（${dbHost}:${dbPort}，用户 ${dbUser}）" $dbReachable `
      "连接失败：$($Error[0].Exception.Message)"
if ($dbReachable) {
    # ⚠ 2026-09-20 改了夹具口径：**库也由 admin.exe 自动建**（与 club-server 的 ensureDatabase
    # 是同一个实现）。原先这里是自己 `CREATE DATABASE`，等于**替被测对象把活干了** ——
    # admin_main.cj 里那条 ensureDatabase 从来没被这套测试碰过，于是"清库之后 admin.exe
    # 起不来（Unknown database 'club_rbac'）"这种事只能靠人肉踩。
    # 现在反过来：先把库整个删掉，再断言它能自己建出来；下面那些**直查 MySQL** 的断言
    # （seed 的角色/权限）就是"库确实被建出来了"的证据。
    # 没有 mysql 客户端可删时，退回老口径（库已存在即可），不让夹具本身变成失败源。
    if ($null -ne $mysqlCli) {
        try { $null = MySql "DROP DATABASE IF EXISTS $dbName" "" } catch { }
        $stillThere = $true
        try { $null = MySql "SELECT 1" $dbName } catch { $stillThere = $false }
        Check "夹具：RBAC 库 ${dbName} 已被删掉（留给 admin.exe 自建）" (-not $stillThere) `
              "删不掉就测不出自动建库（cli=$mysqlCli）"
    } else {
        $dbOk = $true
        try { $null = MySql "SELECT 1" $dbName } catch { $dbOk = $false }
        Check "库 ${dbName} 已存在（没有 mysql 客户端，无法测自动建库）" $dbOk `
              "先建库：mariadb -h $dbHost -P $dbPort -u $dbUser -p -e `"CREATE DATABASE IF NOT EXISTS $dbName CHARACTER SET utf8mb4;`""
    }
} else {
    Write-Host ""
    Write-Host "  ⚠ 连不上 MySQL，测试无法继续（这是**失败**，不是跳过）。"
    Write-Host ("后台验证： PASS {0} / FAIL {1}" -f $pass, $fail)
    exit 1
}

# 干净起见：清掉上一次的表，验证"首次启动自动建表 + 灌种子"。
# 判据只用 users 表（admin_main.cj 也是这么判"新库"的）—— 表不存在时客户端会报错，
# 那正是"干净库"的形态，吞掉即可。
try { $null = MySql "DROP TABLE IF EXISTS users, roles, permissions, role_permissions" $dbName } catch { }

# 旧的文件后端产物：**只删不建**。留着它会让"到底走的是哪条路"变得可疑（一份看着新鲜的
# rbac.json 摆在那里，谁也说不清是哪次运行留下的）。
$oldFile = Join-Path $dir "admin-data\rbac.json"
if (Test-Path $oldFile) { Remove-Item $oldFile -Force }
if (Test-Path "$oldFile.tmp") { Remove-Item "$oldFile.tmp" -Force }

$p = Start-Process -FilePath $exe -WorkingDirectory $dir -PassThru -WindowStyle Hidden `
     -RedirectStandardOutput (Join-Path $dir "admin.out.log") -RedirectStandardError (Join-Path $dir "admin.err.log")
$ready = $false
for ($i = 0; $i -lt 80; $i++) {
    Start-Sleep -Milliseconds 200
    if ($p.HasExited) { break }
    try { if ((Invoke-WebRequest "$base/health" -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200) { $ready = $true; break } } catch { }
}
try {
    Check "服务就绪（/health）" $ready
    if (-not $ready) { Get-Content (Join-Path $dir "admin.err.log") -ErrorAction SilentlyContinue | Select-Object -First 10; throw "未就绪" }

    # ---- 运维路由（上游在这里显式设了 status，可以断言 HTTP 200）----
    $r = Hit "GET" "/health" $null $null
    Check "GET /health -> HTTP 200 且 status=ok" (($r.Status -eq 200) -and ($r.Body -match '"status"\s*:\s*"ok"')) "status=$($r.Status) body=$($r.Body)"

    # ---- 静态前端（SPA）----
    $r = Hit "GET" "/" $null $null
    Check "GET / -> HTTP 200 返回前端页面" ($r.Status -eq 200) "status=$($r.Status)"
    Check "页面是 Vue 构建产物（含 assets 引用）" ($r.Body -match 'assets/index-') "len=$($r.Body.Length)"
    $m = [regex]::Match($r.Body, '/assets/[^"]+\.js')
    if ($m.Success) {
        $r2 = Hit "GET" $m.Value $null $null
        Check "静态资源可取（$($m.Value)）" ($r2.Status -eq 200) "status=$($r2.Status)"
    } else { Check "静态资源可取" $false "首页里没解析到 /assets/*.js" }

    # ---- 登录（种子账号）----
    # N-29（2026-09-17）：后台口令不再写死。首次建库时 admin.exe 会随机生成并**追加**到
    # admin.env 的 admin_pass / user_pass，所以必须在**面板启动之后**重新读一次。
    #
    # 2026-09-19 切到 MySQL 后，这里**第一件事**就是打那道回归闸门：框架 RbacStore 的种子口令
    # 是写死的公开默认值（third_party\qingzhou\src\store.cj:104-111 的 admin123 / user123），
    # 若 admin_main.cj 里那段"新库换随机口令"被删掉或改坏，下面这几条会立刻变红 ——
    # 这是本项目唯一会拦住"N-29 回归"的自动断言，别把它删了或放宽。
    $r = Hit "POST" "/api/login" '{"username":"admin","password":"admin123"}' $null
    Check "N-29 闸门：新库首启后 admin123 **必须**被拒（框架种子口令已被覆盖）" `
        ((BizCode $r) -ne 0) "code=$(BizCode $r) body=$($r.Body)"
    $r = Hit "POST" "/api/login" '{"username":"user","password":"user123"}' $null
    Check "N-29 闸门：新库首启后 user123 **必须**被拒" ((BizCode $r) -ne 0) "code=$(BizCode $r) body=$($r.Body)"

    $adminPw = ""
    $userPw  = ""
    foreach ($line in (Get-Content $envFile -Encoding UTF8)) {
        $t = $line.Trim()
        if ($t -match '^admin_pass\s*=\s*(\S+)') { $adminPw = $Matches[1] }
        if ($t -match '^user_pass\s*=\s*(\S+)')  { $userPw  = $Matches[1] }
    }
    Check "首启把随机口令写回了 admin.env（admin_pass / user_pass）" `
        (($adminPw.Length -ge 8) -and ($userPw.Length -ge 8)) "admin_pass 长度=$($adminPw.Length) user_pass 长度=$($userPw.Length)"

    # 库里那两条记录也必须是**随机口令的哈希**，不是默认口令的哈希 ——
    # 只断言"HTTP 401"还不够：那也能由"表里压根没这两个账号"造成，而后者是坏得更彻底的情形。
    try {
        # 默认口令的哈希算不出来（要先知道框架的哈希实现），所以换个等价的判据：
        # 把两行取出来核对 **id ↔ 账号 ↔ 角色** 的对应关系。换口令的做法是 delete + create，
        # 最容易出错的正是"新用户拿不到原来的 id"这一步 —— 而 id 被换乱会让
        # requirePermission（按数字 userId 判权限）与 /admin/shutdown（要求 roleId==1）
        # 全部错位，这类故障在 HTTP 层很难看出来。
        $seedRows = (MySql "SELECT id, username, role_id FROM users ORDER BY id" $dbName | Out-String).Trim()
        Check "库里种子账号就位（1=admin/role 1、2=user/role 2）" `
            (($seedRows -match '1\s+admin\s+1') -and ($seedRows -match '2\s+user\s+2')) "rows=[$seedRows]"
    } catch {
        Check "库里种子账号就位（1=admin/role 1、2=user/role 2）" $false "$($_.Exception.Message)"
    }

    $r = Hit "POST" "/api/login" (ConvertTo-Json @{ username = "admin"; password = $adminPw } -Compress) $null
    Check "POST /api/login -> code=0" ((BizCode $r) -eq 0) "code=$(BizCode $r) body=$($r.Body)"
    $token = $null
    if ($r.Body -match '"token"\s*:\s*"([^"]+)"') { $token = $Matches[1] }
    Check "拿到 JWT token" ($null -ne $token -and $token.Length -gt 40) "token=$($token)"
    Check "token 形如 JWT（三段点分）" ($token -split '\.').Count -eq 3

    $r = Hit "POST" "/api/login" '{"username":"admin","password":"wrong-password"}' $null
    Check "密码错误 -> code=401" ((BizCode $r) -eq 401) "code=$(BizCode $r) body=$($r.Body)"

    # ---- 登录即可访问 ----
    $r = Hit "GET" "/api/me" $null $token
    Check "GET /api/me（带 token）-> code=0 且 username=admin" (((BizCode $r) -eq 0) -and ($r.Body -match '"username"\s*:\s*"admin"')) "code=$(BizCode $r) body=$($r.Body)"
    $r = Hit "GET" "/api/dashboard" $null $token
    Check "GET /api/dashboard -> code=0 且含 stats" (((BizCode $r) -eq 0) -and ($r.Body -match 'stats')) "code=$(BizCode $r) body=$($r.Body)"

    # ---- 鉴权 + RBAC ----
    $r = Hit "GET" "/api/users" $null $null
    Check "GET /api/users 无 token -> code=401（鉴权生效）" ((BizCode $r) -eq 401) "code=$(BizCode $r) body=$($r.Body)"
    $r = Hit "GET" "/api/users" $null "not-a-jwt"
    Check "GET /api/users 伪造 token -> code=401" ((BizCode $r) -eq 401) "code=$(BizCode $r) body=$($r.Body)"
    $r = Hit "GET" "/api/users" $null $token
    Check "GET /api/users 带 admin token -> code=0（RBAC 放行）" (((BizCode $r) -eq 0) -and ($r.Body -match '"username"\s*:\s*"admin"')) "code=$(BizCode $r) body=$($r.Body)"
    $r = Hit "GET" "/api/roles" $null $token
    Check "GET /api/roles -> code=0 且含 admin/user" (((BizCode $r) -eq 0) -and ($r.Body -match 'admin') -and ($r.Body -match 'user')) "code=$(BizCode $r) body=$($r.Body)"
    $r = Hit "GET" "/api/perms" $null $token
    Check "GET /api/perms -> code=0 且含 user:list" (((BizCode $r) -eq 0) -and ($r.Body -match 'user:list')) "code=$(BizCode $r) body=$($r.Body)"

    # ---- 写路径：建用户 -> 出现在列表里 -> 删除 -> 从列表消失 ----
    # 用户名带时间戳：库是 MySQL、不像原来的 JSON 文件那样每次被本脚本删掉重建，
    # 固定名字连跑两次会被"重名拒绝"挡在第一步（那是**正确行为**，但会让本脚本假红）。
    $tmpUser = "e2e-tmp-" + (Get-Date -Format 'yyyyMMddHHmmss')
    $r = Hit "POST" "/api/users" (ConvertTo-Json @{ username = $tmpUser; password = "e2e-tmp-pw"; roleId = 2 } -Compress) $token
    Check "POST /api/users -> code=0（写路径可用）" ((BizCode $r) -eq 0) "code=$(BizCode $r) body=$($r.Body)"
    $newId = $null
    if ($r.Body -match '"id"\s*:\s*(\d+)') { $newId = $Matches[1] }
    $r = Hit "GET" "/api/users" $null $token
    Check "新建用户出现在列表里" ($r.Body -match [regex]::Escape($tmpUser)) "body=$($r.Body)"
    if ($null -ne $newId) {
        # 直接查库：证明这条确实写进了 MySQL（而不是只在进程内存里）
        try {
            $inDb = (MySql "SELECT COUNT(*) FROM users WHERE username = '$tmpUser'" $dbName | Out-String).Trim()
            Check "新建的用户真的落到了 MySQL 的 users 表" ($inDb -eq "1") "count=[$inDb]"
        } catch {
            Check "新建的用户真的落到了 MySQL 的 users 表" $false "$($_.Exception.Message)"
        }
        $r = Hit "DELETE" "/api/users/$newId" $null $token
        Check "DELETE /api/users/:id -> code=0" ((BizCode $r) -eq 0) "code=$(BizCode $r) body=$($r.Body)"
        $r = Hit "GET" "/api/users" $null $token
        Check "删除后不再出现在列表里" (-not ($r.Body -match [regex]::Escape($tmpUser))) "body=$($r.Body)"
        try {
            $gone = (MySql "SELECT COUNT(*) FROM users WHERE username = '$tmpUser'" $dbName | Out-String).Trim()
            Check "删除也真的落到了 MySQL（表里 0 行）" ($gone -eq "0") "count=[$gone]"
        } catch {
            Check "删除也真的落到了 MySQL（表里 0 行）" $false "$($_.Exception.Message)"
        }
    } else { Check "DELETE /api/users/:id -> code=0" $false "没有解析到新建用户的 id" }

    # ---- 数据层：必须是 **MySQL**（不是 CangDB、也不是本地 JSON 文件）----
    # 原来的四条断言是"admin-data\rbac.json 存在 + 能解析 + 含 admin + 含 6 个 code"，
    # 切到 MySQL 后**无法等价表达成文件断言**，于是换成"直查库里的行数"——
    # 断言强度不减（都证明"数据真的落到了后端"），只是换了后端去看它。
    try {
        $tbl = (MySql "SHOW TABLES" $dbName | Out-String)
        Check "框架自动建了 4 张表（users/roles/permissions/role_permissions）" `
            (($tbl -match 'users') -and ($tbl -match 'roles') -and ($tbl -match 'permissions') -and ($tbl -match 'role_permissions')) "tables=[$($tbl -replace "`r`n", ',')]"
        $permN = (MySql "SELECT COUNT(*) FROM permissions" $dbName | Out-String).Trim()
        Check "库里 seed 了 6 个权限" ($permN -eq "6") "count=[$permN]"
        $rpN = (MySql "SELECT COUNT(*) FROM role_permissions" $dbName | Out-String).Trim()
        Check "库里 seed 了 7 条角色-权限（admin 6 条 + user 1 条；上游 off-by-one 修复的体现）" ($rpN -eq "7") "count=[$rpN]"
        $roleN = (MySql "SELECT COUNT(*) FROM roles" $dbName | Out-String).Trim()
        Check "库里 seed 了 2 个角色（admin/user）" ($roleN -eq "2") "count=[$roleN]"
    } catch {
        Check "直查 MySQL 核对建表与种子数据" $false "$($_.Exception.Message)"
    }
    # 反向断言：文件后端的产物**不应该**再被创建（它是"到底走了哪条路"的直接证据）
    Check "文件后端产物 rbac.json 未被创建（数据层确实换成了 MySQL）" (-not (Test-Path $oldFile)) "仍是文件：$oldFile"

    # ---- 优雅关闭（需 admin 角色）----
    $r = Hit "POST" "/admin/shutdown" '{}' $token
    Check "POST /admin/shutdown -> code=0" ((BizCode $r) -eq 0) "code=$(BizCode $r) body=$($r.Body)"
    $exited = $false
    for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Milliseconds 250; if ($p.HasExited) { $exited = $true; break } }
    Check "进程自行退出（优雅关闭走完）" $exited
    $log = Get-Content (Join-Path $dir "admin.out.log") -ErrorAction SilentlyContinue
    Check "日志出现 graceful shutdown complete" (($log -join "`n") -match 'graceful shutdown complete')
    $err = Get-Content (Join-Path $dir "admin.err.log") -ErrorAction SilentlyContinue
    Check "stderr 无异常" ([string]::IsNullOrWhiteSpace(($err -join ""))) "err=$($err -join ' ')"
} finally {
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
}

Write-Host ""
Write-Host ("后台验证： PASS {0} / FAIL {1}" -f $pass, $fail)
if ($fail -gt 0) { exit 1 }
exit 0
