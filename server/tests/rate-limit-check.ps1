# 登录限流 / 失败锁定 —— 端到端验证
#
# ⚠ 含中文的 PowerShell 脚本必须 UTF-8 with BOM。
#
# 为什么单独一个脚本：限流的行为**必须**按"第 N 次"逐步验证
# （前 4 次 401、第 5 次锁定、第 6 次 429、锁定期内正确口令也被拒），
# 塞进 auth-check.ps1 会让那个脚本的"每次跑都自建夹具"假设被限流状态污染。
#
# 用法：
#   .\rate-limit-check.ps1 -Base http://127.0.0.1:8091 -AdminPw "<管理员口令>"

param(
    [string]$Base = "http://127.0.0.1:8091",
    [string]$AdminPw = "",
    [string]$Dsn = "mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital_test"
)

$ErrorActionPreference = "Stop"

# ── 与其它测试脚本一致：连接参数从 DSN 派生（唯一事实来源）──
. "$PSScriptRoot\common.ps1"
$My = Get-MySqlClientArgs -Dsn $Dsn

$fail = 0
function Check($name, $ok, $detail) {
    if ($ok) { Write-Host "  [PASS] $name" }
    else { Write-Host "  [FAIL] $name"; $script:fail++ }
    if ($detail) { Write-Host "         $detail" }
}

$tmp = Join-Path $env:TEMP ("rlc-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

# 登录一次，返回 @{ Http; Code; Sec; Token }
function Try-Login($name, $pwd) {
    $bf = Join-Path $tmp "body.json"
    $payload = '{"login_name":"' + $name + '","password":"' + $pwd + '"}'
    [System.IO.File]::WriteAllText($bf, $payload, (New-Object System.Text.UTF8Encoding($false)))
    $cf = Join-Path $tmp "req.cfg"
    [System.IO.File]::WriteAllText($cf,
        ("request = `"POST`"`nheader = `"Content-Type: application/json`"`ndata = `"@" + ($bf -replace '\\','/') + "`"`nsilent`nwrite-out = `"\n__M__%{http_code}|%{time_total}`""),
        (New-Object System.Text.UTF8Encoding($false)))
    $raw = (& curl.exe -s -K $cf "$Base/api/v1/auth/login" 2>&1) -join "`n"
    $parts = $raw -split "__M__"
    $meta = ($parts[1].Trim()) -split '\|'
    $obj = $null
    try { $obj = $parts[0].Trim() | ConvertFrom-Json } catch { }
    return @{
        Http  = [int]$meta[0]
        Sec   = [double]$meta[1]
        Code  = if ($obj -and $obj.error) { $obj.error.code } else { "" }
        Token = if ($obj -and $obj.data) { $obj.data.token } else { "" }
    }
}

# 清掉这两个名字的限流状态，让脚本可重复跑（自建夹具、自清）
function Reset-Attempts {
    $null = Invoke-MySqlScalar -My $My -Sql "DELETE FROM auth_login_attempt" -Label "清限流计数"
}

Write-Host "=== 登录限流 / 失败锁定验证 ==="
Write-Host "  目标: $Base"
Write-Host "  库  : $($My.Db)@$($My.DbHost):$($My.Port)"
Write-Host ""

if ([string]::IsNullOrEmpty($AdminPw)) { throw "需要 -AdminPw（管理员口令）" }

Reset-Attempts
Reset-Attempts

# ── 1) 连续失败：第 1~4 次 401，第 5 次（达到阈值那一刻）起 429 ────────
Write-Host "[1] 连续错误口令（阈值 LOGIN_FAIL_LIMIT = 5）"
$codes = @()
foreach ($i in 1..5) {
    $r = Try-Login 'admin' 'definitely-wrong-password'
    $codes += "$($r.Http)"
    Write-Host "         第 $i 次 -> HTTP $($r.Http) code=$($r.Code) t=$([math]::Round($r.Sec,3))s"
}
Check "前 4 次都是 401 AUTH_BAD_CREDENTIALS" (($codes[0..3] -join ',') -eq '401,401,401,401') ($codes -join ',')
Check "第 5 次 -> 429（第 5 次失败使计数达到阈值，**即刻**锁定）" ($codes[4] -eq '429') ($codes -join ',')

# ── 2) 锁定期内继续尝试：一直是 429，且不再烧 PBKDF2 ──────────────────
Write-Host ""
Write-Host "[2] 锁定期内继续尝试"
$r6 = Try-Login 'admin' 'definitely-wrong-password'
Check "第 6 次 -> 429（AUTH_RATE_LIMITED）" ($r6.Http -eq 429 -and $r6.Code -eq 'AUTH_RATE_LIMITED') ("HTTP $($r6.Http) code=$($r6.Code)")
# ★ 锁定时直接拒绝、**不跑 PBKDF2** —— 否则限流反成攻击者的 CPU 放大器
Check "锁定期内响应显著更快（未跑 PBKDF2，限流不放大 CPU）" ($r6.Sec -lt 0.2) ("t=$([math]::Round($r6.Sec,3))s（解冻期实测约 0.55s）")

# ── 3) ★★ 锁定期内**等价写法**也必须被拒（防"换一个字符就是新预算"）────
Write-Host ""
Write-Host "[3] ★★ 归一口径：大小写 / 首尾空格变体不得绕过锁定"
# ── 这一节守的是第三份复查发现的**严重**缺陷 ──────────────────────────────
# 原实现按**登录名字符串**记计数，而账号查找是 TC 不敏感
# （utf8mb4_general_ci + PAD SPACE）。于是换个写法就换一份新预算：
#     先把 admin 锁死 -> 再用**正确口令**试：
#        'Admin'   -> 200 拿到令牌     ← 绕过！
#        'aDmIn'   -> 200 拿到令牌
#        'admin  ' -> 200 拿到令牌     ← 尾空格，变体可无限长
# 实测当时库里躺着**两份**计数。
#
# 修法：库与哈希共用同一个归一值（trimAscii + toAsciiLower）。
# 本节就是那个修复的回归闸门 —— 没有它，将来有人"优化"掉归一就又漏了。
$variants = @('Admin', 'aDmIn', 'ADMIN', 'admin  ', '  admin', "`tadmin", 'Admin ')
$bypass = @()
foreach ($v in $variants) {
    $r = Try-Login $v $AdminPw        # ★ 用**正确口令** —— 只靠锁定拦住
    $bypass += "$($r.Http)"
}
Check "全部 $($variants.Count) 个等价写法都被拒（无一漏网）" `
      (($bypass | Where-Object { $_ -ne '429' }).Count -eq 0) `
      ("写法: " + ($variants -join ' | '))
Check "且都不是 200（正确口令也没用）" (($bypass -join ',') -notmatch '200') ($bypass -join ',')
$rows = Invoke-MySqlScalar -My $My -Sql "SELECT COUNT(*) FROM auth_login_attempt" -Label "计数行数"
Check "库里只有 1 份计数行（归一后同一个键；原缺陷下是多份）" ("$rows" -eq '1') ("实际 $rows 行")

# ── 4) ★ 锁定期内用正确口令（归一写法）也被拒 ─────────────────────
Write-Host ""
Write-Host "[4] ★ 锁定期内用正确口令（归一写法）"
$r7 = Try-Login 'admin' $AdminPw
Check "正确口令也被拒 -> 429" ($r7.Http -eq 429) ("HTTP $($r7.Http) code=$($r7.Code)")

# ── 5) ★★ 防枚举：不存在的账号同样被限流，且**前 4 次同码**──────────
Write-Host ""
Write-Host "[5] ★★ 不存在的登录名是否同样被限流（防枚举）"
$ncodes = @()
foreach ($i in 1..6) {
    $r = Try-Login 'nobody-no-such-user' 'whatever'
    $ncodes += "$($r.Http)"
}
Check "不存在的账号第 5 次起同样 429（与存在账号**同一点**切换）" (($ncodes[4..5] -join ',') -eq '429,429') ($ncodes -join ',')
Check "且前 4 次与存在账号**同码**（不泄露存在性）" (($ncodes[0..3] -join ',') -eq '401,401,401,401') ($ncodes -join ',')

# ── 6) 计时：存在 vs 不存在，失败路径耗时应同量级 ────────────────────
Write-Host ""
Write-Host "[6] 防枚举计时（两条路径都跑 PBKDF2）"
Reset-Attempts
Reset-Attempts
$tExist = @(); $tNone = @()
foreach ($i in 1..3) {
    $tExist += (Try-Login 'admin' 'wrong-pw').Sec
    $tNone  += (Try-Login 'nobody-no-such-user' 'wrong-pw').Sec
}
$avgE = ($tExist | Measure-Object -Average).Average
$avgN = ($tNone  | Measure-Object -Average).Average
$ratio = if ($avgE -gt 0) { [math]::Round($avgN / $avgE, 2) } else { 0 }
Check "两条路径耗时同量级（比值 0.5~2.0）" ($ratio -ge 0.5 -and $ratio -le 2.0) ("存在 avg=$([math]::Round([double]$avgE,3))s  不存在 avg=$([math]::Round([double]$avgN,3))s  比值=$ratio")

# ── 7) 成功登录会清零计数 ─────────────────────────────────────────────
Write-Host ""
Write-Host "[7] 成功登录清零失败计数"
Reset-Attempts
foreach ($i in 1..3) { $null = Try-Login 'admin' 'wrong-pw' }     # 攒 3 次失败（未到阈值 5）
$ok = Try-Login 'admin' $AdminPw
Check "攒 3 次失败后用正确口令能登录成功" ($ok.Http -eq 200 -and $ok.Token.Length -eq 64) ("HTTP $($ok.Http) token=$($ok.Token.Length) 字符")
$cnt = Invoke-MySqlScalar -My $My -Sql "SELECT COUNT(*) FROM auth_login_attempt" -Label "剩余计数行"
Check "成功登录后计数行已清（剩 $cnt 行；pruneAttempts 顺带清理）" ("$cnt" -eq '0') ("实际 $cnt")
# 再失败 3 次应仍不被锁（因为计数已清零，重新从 1 数）
$again = @()
foreach ($i in 1..3) { $again += (Try-Login 'admin' 'wrong-pw').Http }
Check "清零后再失败 3 次仍不被锁（未被历史累计误伤）" (($again -join ',') -eq '401,401,401') ($again -join ',')

# ── 8) 清理陈旧计数行（含归一化不破坏正常注册/登录）─────────────────────
Write-Host ""
Write-Host "[8] 陈旧计数行清理"
Reset-Attempts
$null = Try-Login 'stale-user-xyz' 'wrong'
$before = Invoke-MySqlScalar -My $My -Sql "SELECT COUNT(*) FROM auth_login_attempt" -Label "清理前"
# 把该行的 last_fail_at 改成很久以前，再触发一次成功登录（成功路径会调用 pruneAttempts）
Invoke-MySqlScalar -My $My -Sql "UPDATE auth_login_attempt SET last_fail_at = 1" -Label "伪装陈旧" | Out-Null
$null = Try-Login 'admin' $AdminPw
$after = Invoke-MySqlScalar -My $My -Sql "SELECT COUNT(*) FROM auth_login_attempt" -Label "清理后"
Check "陈旧行被清掉（$before -> $after）" ([int]$after -lt [int]$before) ("前 $before 后 $after")

# ── 9) ★ 归一只用于计数口径，不改变"能登录"的行为 ─────────────────────
Write-Host ""
Write-Host "[9] ★ 归一不破坏正常登录（各种等价写法 + 正确口令都该成功）"
Reset-Attempts
$okCodes = @()
foreach ($v in @('admin', 'Admin', 'ADMIN', 'admin  ')) {
    $okCodes += "$((Try-Login $v $AdminPw).Http)"
}
Check "4 种等价写法 + 正确口令全部 200" (($okCodes -join ',') -eq '200,200,200,200') ($okCodes -join ',')

Remove-Item $tmp -Recurse -Force

Write-Host ""
if ($fail -eq 0) {
    Write-Host "✅ 登录限流验证全部通过"
    exit 0
} else {
    Write-Host "❌ 登录限流验证失败 $fail 项"
    exit 1
}
