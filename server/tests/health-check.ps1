# 探活接口验证：/health 与 /api/v1/health
#
# 为什么单独一个脚本：探活接口此前**零测试覆盖**（全仓 grep 无任何脚本打过 /health），
# 而它从 2026-10-14 起多担了一件事 —— 把**医院今天**与时间口径发给客户端
# （跨端审计 F14：客户端原来自已用设备本地日期算"今天"，时区不对就会查不到号）。
# 一个"没有任何测试、但被客户端当权威日期源"的接口，正是最不该出错的那种。
#
# 覆盖：
#   [1] 无需认证即可访问（部署探针都按这个假设写）
#   [2] 响应形状（ok/service/version/data_backend/dev_auth）
#   [3] ★★ 医院日期口径：today == UTC+8 的日期，timezone == Asia/Shanghai
#   [4] 两个路径是**同一份实现**（别名不能各说各话）
#
# ⚠ 含中文的 PowerShell 脚本必须 UTF-8 with BOM（PS 5.1 否则按 ANSI 解析 → 语法报错）。
# ⚠ 注释只能用 PowerShell 的 `#`：写 C 风格块注释会被当命令执行。
#
# 用法：.\health-check.ps1 -Base http://127.0.0.1:8091

param(
    [string]$Base = "http://127.0.0.1:8091"
)

$ErrorActionPreference = "Stop"

$fail = 0
function Check($name, $ok, $detail) {
    if ($ok) { Write-Host "  [PASS] $name" }
    else { Write-Host "  [FAIL] $name"; $script:fail++ }
    if ($detail) { Write-Host "         $detail" }
}

$tmp = Join-Path $env:TEMP ("health-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

# 发一个请求（探活是 GET，不需要认证头）。返回 @{ Code; Body }
function Req($name, $path) {
    $f = Join-Path $tmp "$name.cfg"
    $lines = @('request = "GET"')
    $lines += 'silent'
    $lines += 'write-out = "\n__CODE__%{http_code}"'
    [System.IO.File]::WriteAllText($f, ($lines -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
    $raw = (& curl.exe -K $f "$Base$path" 2>&1) -join "`n"
    $parts = $raw -split "__CODE__"
    $code = if ($parts.Count -gt 1) { [int]$parts[1].Trim() } else { -1 }
    return @{ Code = $code; Body = $parts[0].Trim() }
}

function Json($r) { return ($r.Body | ConvertFrom-Json) }

Write-Host "=== 探活接口验证 ==="
Write-Host "  目标: $Base"
Write-Host ""

# ── 1) 无需认证 ────────────────────────────────────────────────────────────
Write-Host "[1] 无需认证即可访问"
$h = Req 'h1' '/health'
Check "GET /health → 200（不带任何令牌）" ($h.Code -eq 200) ("HTTP $($h.Code)")
$hApi = Req 'h2' '/api/v1/health'
Check "GET /api/v1/health → 200（api 前缀别名）" ($hApi.Code -eq 200) ("HTTP $($hApi.Code)")

# ── 2) 响应形状 ────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "[2] 响应形状"
$j = Json $h
Check "ok = true" ($j.ok -eq $true) ("ok=$($j.ok)")
Check "service = hospital-server（压测/探针按它识别服务）" ($j.service -eq 'hospital-server') ("service=$($j.service)")
Check "带 version（实得 $($j.version)）" (-not [string]::IsNullOrEmpty($j.version))
Check "带 data_backend（实得 $($j.data_backend)）" (-not [string]::IsNullOrEmpty($j.data_backend))
Check "带 dev_auth 布尔（实得 $($j.dev_auth)）" ($j.dev_auth -eq $true -or $j.dev_auth -eq $false)
# 探活**不能**泄露配置细节（它是未认证接口）
Check "不泄露敏感字段（无 password/secret/dsn 字样）" `
      (-not ($h.Body -match 'password|secret|dsn|token')) ("body=$($h.Body)")

# ── 3) ★★ 医院日期口径（跨端审计 F14）────────────────────────────────────
Write-Host ""
Write-Host "[3] ★★ 医院日期与时间口径（F14）"
$today = $j.today
Check "带 today 字段（实得「$today」）" (-not [string]::IsNullOrEmpty($today))
Check "today 形如 YYYY-MM-DD" ($today -match '^\d{4}-\d{2}-\d{2}$') ("today=$today")
Check "timezone = Asia/Shanghai" ($j.timezone -eq 'Asia/Shanghai') ("timezone=$($j.timezone)")
# ★★ 关键断言：today 必须等于 UTC+8 的当天 —— 客户端拿设备本地日期算不出来时才需要它，
#    所以服务端自己算错时区，这个字段就毫无价值（而且比不提供更糟：它看起来权威）。
$expect = [DateTimeOffset]::UtcNow.ToOffset([TimeSpan]::FromHours(8)).ToString('yyyy-MM-dd')
Check "★★ today == UTC+8 当天（期望 $expect，实得 $today）" ($today -eq $expect) ("today=$today expect=$expect")

# ── 4) 两个路径是同一份实现 ────────────────────────────────────────────────
Write-Host ""
Write-Host "[4] 别名一致性（/health 与 /api/v1/health）"
$jApi = Json $hApi
Check "★★ 两个路径的 today 一致（别名不能各说各话）" ($jApi.today -eq $j.today) ("$($j.today) vs $($jApi.today)")
Check "两个路径的 timezone 一致" ($jApi.timezone -eq $j.timezone)
Check "两个路径的 version 一致" ($jApi.version -eq $j.version)

Remove-Item $tmp -Recurse -Force

Write-Host ""
if ($fail -eq 0) {
    Write-Host "✅ 探活接口验证全部通过"
    exit 0
} else {
    Write-Host "❌ 探活接口验证失败 $fail 项"
    exit 1
}
