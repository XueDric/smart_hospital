# 客户端 ↔ 服务端 契约回归（把接入检查里"客户端声明的路径与方法"那张表自动化
# —— 原始那张表在 docs/client-integration-review.md §3，该文件已于 2026-09-20 移出仓库，
#    现行的客户端交接单是 docs/client-bug-handover.md）
#
# 做两件事：
#   1. 从 entry/src/main/ets/api/*.ets 里抽出客户端**实际声明**的每一条 (方法, 路径)；
#   2. 起一个真服务端，逐条打过去，断言**既不是 404（路径写错）也不是 405（方法写错）**。
#
# 判据怎么来的：
#   服务端先按 `方法 + 路径` 命中路由，再在 handler 里做认证。所以**不带令牌**时，
#   正确的路径+方法会返回 401（路由存在、只是需要登录），免登录接口返回 400 级参数错误；
#   只有路径写错才会 404、方法写错才会 405 —— 一条断言同时抓住两类错。
#
# 用法（Windows PowerShell 5.1 需带 Bypass）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\client-contract-check.ps1
#
# 两个已经踩过的坑（改本脚本时注意）：
#   · **不要给 GET 带请求体**：PS 5.1 的 Invoke-WebRequest 会拿不到响应对象（返回 -1），
#     于是所有 GET 都变成假 FAIL；
#   · **模板字面量里的引号**：`/members${qs ? '?' + qs : ''}` 这种路径不能用
#     "读到下一个引号为止"的正则去抽，否则会被截成 `/members${qs`。
#
# 为什么不做成单测：这是**跨仓契约**（客户端源码 vs 服务端路由表），
# 单测只能测服务端自己；而这条链最容易出错的恰恰是"两边都自认为对"。
#
# ⚠⚠ 新前提（2026-09-20 起）：**必须有一台可连的 MySQL / MariaDB**。
#   服务端持久化已整体换成 MySQL（路线 B，见 docs\club-server-mysql-assessment.md），
#   本脚本用**专用测试库 club_contract**（绝不碰 club_rbac 或任何真实业务库），
#   开头检测客户端与可连性，取不到 → 中文提示 + 判 FAIL + 非零退出。
#   连接参数默认 127.0.0.1:3307 / root / clubroot123，可用环境变量覆盖
#   （CLUB_MYSQL_HOST/PORT/USER/PASS/DB、CLUB_MYSQL_CLI、CLUB_MARIADB_HOME）；
#   细节见 tests\mysql-common.ps1 的文件头。

param(
    [int]$Port = 18098,
    [string]$Exe = "",
    [string]$ClientApiDir = ""
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot          # server\
$repo = Split-Path -Parent $root                  # 仓库根
if ([string]::IsNullOrEmpty($Exe)) { $Exe = Join-Path $root "build\club-server.exe" }
if (-not (Test-Path $Exe)) { throw "找不到服务端可执行文件：$Exe（先跑 build.ps1）" }
if ([string]::IsNullOrEmpty($ClientApiDir)) { $ClientApiDir = Join-Path $repo "entry\src\main\ets\api" }
if (-not (Test-Path $ClientApiDir)) { throw "找不到客户端 api 目录：$ClientApiDir" }

# 专用测试库 + 连接检测（取不到就 FAIL 退出）
. (Join-Path $PSScriptRoot "mysql-common.ps1")
$my = Initialize-MySqlTestEnv -DefaultDb "club_contract"

Push-Location $root    # keep cwd = repo\server: 审计日志等相对路径都相对它（踩过：cwd 不同 => 各写一份）
$dataRel = "build\contract-data"     # 只剩审计日志（audit.log）用；业务数据在 MySQL 里
$dataAbs = Join-Path $root $dataRel
$logOut  = Join-Path $root "build\contract.out.log"
$logErr  = Join-Path $root "build\contract.err.log"
$base    = "http://127.0.0.1:$Port"

$BT = [char]0x60; $SQ = [char]0x27; $DQ = [char]0x22   # 反引号 / 单引号 / 双引号

# 从 $text 的 $pos 起读一个字符串字面量（三种定界符都支持）。
# 反引号模板里的 ${...} 允许含引号，所以按花括号配对整体跳过。
function Read-Literal([string]$text, [int]$pos) {
    if ($pos -ge $text.Length) { return $null }
    $open = $text[$pos]
    if ($open -ne $BT -and $open -ne $SQ -and $open -ne $DQ) { return $null }
    $i = $pos + 1
    $sb = New-Object System.Text.StringBuilder
    while ($i -lt $text.Length) {
        $ch = $text[$i]
        if ($open -eq $BT -and $ch -eq '$' -and ($i + 1) -lt $text.Length -and $text[$i + 1] -eq '{') {
            $ps = $i
            $depth = 0
            while ($i -lt $text.Length) {
                if ($text[$i] -eq '{') { $depth++ }
                elseif ($text[$i] -eq '}') { $depth--; if ($depth -eq 0) { $i++; break } }
                $i++
            }
            [void]$sb.Append($text.Substring($ps, $i - $ps))      # 占位符统一记为 ${...}，稍后替换
            continue
        }
        if ($ch -eq $open) { return $sb.ToString() }
        [void]$sb.Append($ch)
        $i++
    }
    return $null
}

# ---------- 1. 抽取客户端声明 ----------
$methodMap = @{ get = 'GET'; post = 'POST'; put = 'PUT'; patch = 'PATCH'; 'delete_' = 'DELETE' }
$callHead = [regex]'this\.client\.(get|post|put|patch|delete_)\s*<[^>]*>\s*\('
$calls = New-Object System.Collections.ArrayList

foreach ($f in (Get-ChildItem "$ClientApiDir\*.ets")) {
    $text = [System.IO.File]::ReadAllText($f.FullName, [System.Text.UTF8Encoding]::new($false))
    foreach ($m in $callHead.Matches($text)) {
        $p = $m.Index + $m.Length
        while ($p -lt $text.Length -and [char]::IsWhiteSpace($text[$p])) { $p++ }
        $lit = Read-Literal $text $p
        if ($null -eq $lit) { continue }
        $verb = $m.Groups[1].Value
        # 占位符分两类：路径参数（${id}/${token}）→ 换成 1；拼 query（${qs ? ...}）→ 整段丢掉
        $path = ''
        $last = 0
        foreach ($pm in [regex]::Matches($lit, '\$\{([^}]*)\}')) {
            $path += $lit.Substring($last, $pm.Index - $last)
            if (-not $pm.Groups[1].Value.Contains('?')) { $path += '1' }
            $last = $pm.Index + $pm.Length
        }
        $path += $lit.Substring($last)
        $q = $path.IndexOf('?')
        if ($q -ge 0) { $path = $path.Substring(0, $q) }
        $path = ($path -replace '[^/A-Za-z0-9_\-\.]', '')  # 去掉拼接残留，只留路径字符
        [void]$calls.Add(@{ verb = $methodMap[$verb]; path = "/api/v1$path"; file = $f.Name; raw = $lit })
    }
}
if ($calls.Count -eq 0) { throw "没从 $ClientApiDir 抽到任何调用，检查正则或目录" }

# ---------- 2. 起服务端 ----------
if (Test-Path $dataAbs) { Remove-Item -Recurse -Force $dataAbs }
Remove-Item $logOut, $logErr -Force -ErrorAction SilentlyContinue
Reset-ClubMySqlSchema $my.Db
& $Exe init-admin 13800000000 password123 $my.Dsn --data-dir $dataRel | Out-Null
if ($LASTEXITCODE -ne 0) { throw "init-admin 失败（exit=$LASTEXITCODE）" }

$proc = Start-Process -FilePath $Exe -ArgumentList @("serve", "$Port", $my.Dsn, "--data-dir", $dataRel) `
    -WorkingDirectory $root -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $logOut -RedirectStandardError $logErr
$ready = $false
for ($i = 0; $i -lt 100; $i++) {
    Start-Sleep -Milliseconds 100
    if ($proc.HasExited) { break }
    try { if ((Invoke-WebRequest "$base/health" -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200) { $ready = $true; break } } catch { }
}
if (-not $ready) {
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
    throw "服务未能在 :$Port 就绪；看 $logOut / $logErr"
}

# 只有 POST/PUT/PATCH 带体；GET/DELETE 一定不要带（PS 5.1 会拿不到响应，返回 -1）
function Hit($method, $path, $token) {
    $headers = @{}
    if ($token) { $headers['Authorization'] = "Bearer $token" }
    $p = @{ Method = $method; Uri = "$base$path"; UseBasicParsing = $true; Headers = $headers; TimeoutSec = 15 }
    if ($method -eq 'POST' -or $method -eq 'PUT' -or $method -eq 'PATCH') {
        $p['ContentType'] = 'application/json; charset=utf-8'
        $p['Body'] = [System.Text.Encoding]::UTF8.GetBytes('{}')
    }
    try { $r = Invoke-WebRequest @p; return [int]$r.StatusCode }
    catch {
        $resp = $_.Exception.Response
        if ($null -ne $resp) { return [int]$resp.StatusCode }
        return -1
    }
}

$script:pass = 0; $script:fail = 0; $script:bad = New-Object System.Collections.ArrayList
try {
    Write-Host "=== 客户端 ↔ 服务端 契约回归 ==="
    Write-Host "客户端声明来源: $ClientApiDir"
    Write-Host "抽到 $($calls.Count) 条调用"
    Write-Host ""

    $login = Invoke-WebRequest -Method POST -Uri "$base/api/v1/auth/login" -UseBasicParsing `
        -ContentType 'application/json; charset=utf-8' `
        -Body ([System.Text.Encoding]::UTF8.GetBytes('{"phone":"13800000000","password":"password123"}'))
    $token = ($login.Content | ConvertFrom-Json).data.token

    foreach ($c in $calls) {
        $anon = Hit $c.verb $c.path ""
        $auth = Hit $c.verb $c.path $token
        $ok = ($anon -ne 404) -and ($anon -ne 405) -and ($anon -ne -1)
        $tag = if ($ok) { 'ok  ' } else { 'FAIL' }
        if ($ok) { $script:pass++ } else { $script:fail++; [void]$script:bad.Add($c) }
        "{0} {1,-6} {2,-40} 未登录={3,-4} 已登录={4,-4} ({5})" -f $tag, $c.verb, $c.path, $anon, $auth, $c.file
    }

    Write-Host ""
    if ($script:fail -eq 0) {
        Write-Host "契约回归： PASS $($script:pass) / FAIL 0 —— 客户端声明的每条路径与方法，服务端都认得。"
    } else {
        Write-Host "契约回归： PASS $($script:pass) / FAIL $($script:fail)" -ForegroundColor Red
        Write-Host "（下面这些是**真写错**的：404=路径不存在 / 405=方法不对）" -ForegroundColor Red
        foreach ($b in $script:bad) { Write-Host "  $($b.verb) $($b.path)   （客户端原文：$($b.raw)）" -ForegroundColor Red }
    }
} finally {
    if ($null -ne $proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
    if (Test-Path $dataAbs) { Remove-Item -Recurse -Force $dataAbs -ErrorAction SilentlyContinue }
    Pop-Location
}
if ($script:fail -gt 0) { exit 1 }
