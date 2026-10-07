<#
  dev-serve.ps1 —— 联调一键起服务（2026-09-20）

  联调时最常做的一件事就是"把服务端起起来"。它需要三件事同时正确：
  ① 数据库在跑；② 编译产物在；③ DSN 与库名对得上。任何一件不对，
  症状都是"队友连不上"，而排查得翻三份文档。
  这份脚本把这三件事的检查、提示与常用地址都固定下来 —— 它就是
  docs\local-deploy.md §0.5「联调速查」里那一条命令的实现。

  做的事（幂等，可重复跑）：
    ① 本机 3307 没有 MySQL 在听 → **顺手把便携版 MariaDB 起起来**（后台、无窗口）；
    ② 打印客户端该填的地址（模拟器 / 同局域网真机与队友 PC）与防火墙命令；
    ③ 前台启动 club-server（日志直接打在控制台，Ctrl+C 结束；用 §2.5 的
       /admin/shutdown 则是优雅关闭）。

  用法：
    .\dev-serve.ps1                      # 默认：8080 + club_server 库 + 本机便携版 MariaDB
    .\dev-serve.ps1 -Port 9000
    .\dev-serve.ps1 -Db club_alice       # 换个库（每人的联调库互不干扰）
    .\dev-serve.ps1 -Dsn "mysql://root:pw@127.0.0.1:3307/club_server"
    .\dev-serve.ps1 -DbOnly              # 只把数据库弄起来，不起服务
    .\dev-serve.ps1 -NoDb                # 完全不碰数据库（你已经起好了 / 数据库在别人机器上）
    .\dev-serve.ps1 -Tls                 # 走 HTTPS（需 certs\cert.pem / certs\key.pem，
                                         #   且证书 SAN 里要有客户端实际使用的地址，见 §3）

  ⚠ 参数里**不要出现中文**：仓颉 CLI 拿到非 ASCII 参数会在 main 之前就崩（API-NOTES 坑 11）。
     库名/口令/路径都用 ASCII。
#>
param(
    [int]$Port = 8080,
    [string]$Db = "club_server",
    [string]$Dsn = "",
    [switch]$Tls,
    [switch]$DbOnly,
    [switch]$NoDb,
    [string]$DataDir = "data",
    [int]$DbPort = 3307,
    [string]$DbUser = "root",
    [string]$DbPass = "clubroot123",
    # ⚠ 这两个路径是**相对 build\ 的**（服务端在 build\ 里跑，证书按相对路径读）：
    #   仓库里现成的那张在 server\certs\，所以是 ..\certs\...
    [string]$Cert = "..\certs\cert.pem",
    [string]$Key = "..\certs\key.pem"
)

$ErrorActionPreference = "Stop"
$build = Join-Path $PSScriptRoot "build"
$exe = Join-Path $build "club-server.exe"

function Say([string]$m) { Write-Host "[dev] $m" }
function Warn([string]$m) { Write-Host "[dev] $m" -ForegroundColor Yellow }

function Test-Port([string]$h, [int]$p) {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $t = $c.BeginConnect($h, $p, $null, $null)
        if (-not $t.AsyncWaitHandle.WaitOne(800)) { $c.Close(); return $false }
        $c.EndConnect($t); $c.Close(); return $true
    } catch { return $false }
}

# ---------- ① 数据库 ----------

function Find-Mysqld {
    $cands = @()
    if ($env:CLUB_MARIADB_HOME) { $cands += (Join-Path $env:CLUB_MARIADB_HOME "bin\mysqld.exe") }
    $cands += @(
        "E:\cangjie\mariadb\mariadb-11.4.13-winx64\bin\mysqld.exe",
        "D:\cangjie\mariadb\mariadb-11.4.13-winx64\bin\mysqld.exe",
        "C:\Program Files\MariaDB 11.4\bin\mysqld.exe"
    )
    foreach ($c in $cands) { if (Test-Path $c) { return $c } }
    # 便携版目录名带版本号，换个版本就找不到 —— 再模糊找一层
    foreach ($r in @("E:\cangjie\mariadb", "D:\cangjie\mariadb")) {
        if (Test-Path $r) {
            $hits = Get-ChildItem $r -Directory -ErrorAction SilentlyContinue |
                    ForEach-Object { Join-Path $_.FullName "bin\mysqld.exe" } |
                    Where-Object { Test-Path $_ }
            if ($hits) { return ($hits | Select-Object -First 1) }
        }
    }
    return $null
}

<#
  便携版 MariaDB 的 my.ini 与数据目录**不一定在同一个地方**。
  本机实测的布局是"版本目录 + 同级的 data 目录"：
      E:\cangjie\mariadb\mariadb-11.4.13-winx64\bin\mysqld.exe   ← 程序
      E:\cangjie\mariadb\data\my.ini                             ← 配置（datadir/端口都在这里）
  所以按优先级找，**找到了才用 --defaults-file**（datadir 由它决定，比命令行猜可靠）。
#>
function Find-MyIni([string]$mysqldPath) {
    if ($env:CLUB_MARIADB_MYINI -and (Test-Path $env:CLUB_MARIADB_MYINI)) { return $env:CLUB_MARIADB_MYINI }
    $mhome = Split-Path (Split-Path $mysqldPath -Parent) -Parent     # ...\mariadb-11.4.13-winx64
    $root = Split-Path $mhome -Parent                                # ...\mariadb
    foreach ($c in @((Join-Path $mhome "data\my.ini"), (Join-Path $root "data\my.ini"), (Join-Path $mhome "my.ini"))) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

<# 起不来时把错误日志的尾巴打出来 —— 比让用户自己去猜"为什么没起来"有用得多。 #>
function Show-DbLog([string]$mysqldPath) {
    $mhome = Split-Path (Split-Path $mysqldPath -Parent) -Parent
    foreach ($c in @((Split-Path $mhome -Parent) + "\mysqld.log.err",
                     (Join-Path $mhome "data\mysqld.log.err"),
                     (Split-Path $mhome -Parent) + "\mysqld.err")) {
        if (Test-Path $c) {
            Warn "数据库错误日志（$c）最后 10 行："
            Get-Content $c -Tail 10 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "      $_" }
            return
        }
    }
}

if (-not $NoDb) {
    if (Test-Port "127.0.0.1" $DbPort) {
        Say "数据库 127.0.0.1:$DbPort 已在听（不重复启动）"
    } else {
        $mysqld = Find-Mysqld
        if (-not $mysqld) {
            Warn "找不到 mysqld.exe —— 请自己起一台 MySQL，或设 `$env:CLUB_MARIADB_HOME 指过去。"
            Warn "（也可以加 -NoDb 表示「我知道，别管数据库」）"
            exit 1
        }
        # ⚠ 变量别叫 `$home` —— 那是 PowerShell 的**只读自动变量**，赋值直接报错（本轮实测踩到）
        $mhome = Split-Path (Split-Path $mysqld -Parent) -Parent
        $ini = Find-MyIni $mysqld
        if ($ini) {
            Say "启动便携版 MariaDB：$mysqld"
            Say "  --defaults-file=$ini"
            Start-Process -FilePath $mysqld -ArgumentList @("--defaults-file=$ini", "--console") -WindowStyle Hidden | Out-Null
        } elseif (Test-Path (Join-Path $mhome "data")) {
            Say "启动便携版 MariaDB：$mysqld（--datadir=$mhome\data --port=$DbPort）"
            Start-Process -FilePath $mysqld -ArgumentList @("--datadir=$(Join-Path $mhome 'data')", "--port=$DbPort", "--console") -WindowStyle Hidden | Out-Null
        } else {
            Warn "找到了 mysqld.exe（$mysqld）却找不到它的 my.ini / data 目录。"
            Warn "请手工起数据库，或设 `$env:CLUB_MARIADB_MYINI 指向 my.ini，或用 -NoDb 跳过。"
            exit 1
        }
        $ok = $false
        for ($i = 0; $i -lt 30; $i++) {
            Start-Sleep -Milliseconds 500
            if (Test-Port "127.0.0.1" $DbPort) { $ok = $true; break }
        }
        if ($ok) { Say "数据库已就绪（127.0.0.1:$DbPort）" }
        else { Warn "等了 15 秒还没起来。"; Show-DbLog $mysqld; Warn "（也可以加 -NoDb 跳过这一步）"; exit 1 }
    }
}

if ($Dsn.Length -eq 0) {
    $Dsn = "mysql://${DbUser}:${DbPass}@127.0.0.1:${DbPort}/${Db}"
}
Say "DSN：$Dsn"

if ($DbOnly) { Say "-DbOnly：到此为止，服务端没起。"; exit 0 }

# ---------- ② 编译产物 ----------

if (-not (Test-Path $exe)) {
    Warn "没有 $exe —— 先跑一次（要先出 MySQL 驱动产物）："
    Warn "  powershell -NoProfile -ExecutionPolicy Bypass -File .\build-mysql-driver.ps1"
    Warn "  powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1"
    exit 1
}

$other = Get-Process club-server -ErrorAction SilentlyContinue
if ($other) {
    Warn "已经有一个 club-server 在跑（PID $($other.Id -join ',')）—— 同一端口起第二个会失败。"
    Warn "先停掉：Get-Process club-server | Stop-Process -Force"
    exit 1
}

# ---------- ③ 客户端该填什么 ----------

$lan = $null
try {
    # 取"默认路由用的那块网卡"的地址（比枚举所有网卡再猜更准）
    $udp = New-Object System.Net.Sockets.UdpClient
    $udp.Connect("8.8.8.8", 65530)
    $lan = $udp.Client.LocalEndPoint.Address.ToString()
    $udp.Close()
} catch { }
if (-not $lan) {
    try {
        $lan = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
                Select-Object -First 1 -ExpandProperty IPAddress)
    } catch { }
}

$scheme = if ($Tls) { "https" } else { "http" }

# -Tls 时先把证书查清楚：**证书 SAN 里没有客户端实际用的地址 = 客户端报"证书不匹配"**，
# 而那个报错看起来很像"服务端没起来"。这里只说事实，不替用户改证书。
if ($Tls) {
    Push-Location $build
    $certOk = Test-Path $Cert
    $keyOk = Test-Path $Key
    Pop-Location
    if (-not ($certOk -and $keyOk)) {
        Warn "-Tls：找不到证书/私钥（相对 build\ 解析）：$Cert / $Key"
        Warn "  先按 docs\local-deploy.md §5.5 生成一张，或用 -Cert / -Key 指定别的路径。"
        exit 1
    }
    Warn "-Tls：证书是 $Cert —— **它的 SAN 里必须包含客户端实际访问的地址**（$lan / 10.0.2.2）。"
    Warn "  仓库里现成那张的 SAN 只有 127.0.0.1 + localhost，真机/队友连它会报证书不匹配。"
    Warn "  要用就先按 §5.5 重签（换 IP 也要重签）。"
}

Say ""
Say "客户端 Env.ets 里的 DEV_BASE_URL 该填："
Say "  模拟器（和本服务同一台电脑）   ${scheme}://10.0.2.2:$Port/api/v1"
if ($lan) {
    Say "  真机 / 队友的电脑（同一局域网） ${scheme}://${lan}:$Port/api/v1"
} else {
    Warn "  没探到局域网 IP —— 用 ipconfig 自己看一眼"
}
Say "  本机自测（curl）               curl.exe ${scheme}://127.0.0.1:$Port/health"
Say ""
Say "队友连不上时按顺序查：① 是不是同一个网络 ② 防火墙（下面这条用**管理员** PowerShell 跑一次）"
Say "  New-NetFirewallRule -DisplayName `"club-server $Port`" -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow"
Say ""
Say "从别的机器先探一刀（把 IP 换成上面那个）："
Say "  Test-NetConnection ${lan} -Port $Port        # False = 防火墙/不同网段，不是服务端的问题"
Say ""
Say "⚠ 服务跑在**这个窗口**里：关掉窗口 = 服务停（那种停法不会打印「服务已停止」）。"
Say "  要优雅停：curl.exe -s -X POST ${scheme}://127.0.0.1:$Port/admin/shutdown"
Say "  另：**有人在它运行时重新编译**（build.ps1 前必须先停 exe）也会把它杀掉 —— 服务端本身没有空闲自动关服。"
Say ""

# ---------- ④ 起服务 ----------

Push-Location $build   # ⚠ 必须在 exe 所在目录：审计日志与证书都按相对路径读
try {
    if ($Tls) {
        Say "启动：club-server.exe serve-tls $Port <DSN> --cert $Cert --key $Key"
        & $exe serve-tls "$Port" $Dsn --cert $Cert --key $Key --data-dir $DataDir
    } else {
        Say "启动：club-server.exe serve $Port <DSN> --data-dir $DataDir"
        & $exe serve "$Port" $Dsn --data-dir $DataDir
    }
} finally {
    Pop-Location
}
