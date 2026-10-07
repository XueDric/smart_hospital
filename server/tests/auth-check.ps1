# 令牌鉴权端到端测试（P1）
#
# 覆盖：登录换令牌、Bearer 鉴权、三端权限、登出吊销、改口令吊销全部令牌、
#       防枚举（同一错误码 + 计时一致）、开发态头被忽略。
#
# ⚠ 含中文的 PowerShell 脚本必须 UTF-8 with BOM（PS 5.1 否则按 ANSI 解析 → 语法报错）。
# ⚠ header/body 全部走 curl **config 文件**（-K）：
#   `Start-Process -ArgumentList` 或含空格的 -H 参数会被拆坏（详见 docs/P1-HANDOFF.md §3.3）。
#
# 用法：
#   .\auth-check.ps1 -Base http://127.0.0.1:8091 -AdminPw <口令>
#   （管理员口令由 `hospital-server.exe create-admin <dsn>` 打印）

param(
    [string]$Base = "http://127.0.0.1:8091",
    [string]$AdminLogin = "admin",
    [string]$AdminPw = "",
    [string]$PatientLogin = "13800000001",
    [string]$PatientPw = "patient-pw-1",
    [int]$PatientRefId = 1,
    [switch]$SkipTiming
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrEmpty($AdminPw)) {
    throw "必须提供 -AdminPw（先跑 hospital-server.exe create-admin <dsn> 拿到口令）"
}

$tmp = Join-Path $env:TEMP ("authcheck-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

$fail = 0
function Check($name, $ok) {
    if ($ok) { Write-Host "  [PASS] $name" }
    else { Write-Host "  [FAIL] $name"; $script:fail++ }
}

# 发一个请求。返回 @{ Code; Body }
function Req($name, $method, $path, $headers, $body) {
    $f = Join-Path $tmp "$name.cfg"
    $lines = @("request = `"$method`"")
    foreach ($h in $headers) { $lines += "header = `"$h`"" }
    if ($body) {
        $bf = Join-Path $tmp "$name.body"
        [System.IO.File]::WriteAllText($bf, $body, (New-Object System.Text.UTF8Encoding($false)))
        $lines += ('data = "@' + ($bf -replace '\\', '/') + '"')
        $lines += 'header = "Content-Type: application/json"'
    }
    $lines += 'silent'
    $lines += 'write-out = "\n__CODE__%{http_code}"'
    [System.IO.File]::WriteAllText($f, ($lines -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
    $raw = (& curl.exe -K $f "$Base$path" 2>&1) -join "`n"
    $parts = $raw -split "__CODE__"
    $code = if ($parts.Count -gt 1) { [int]$parts[1].Trim() } else { -1 }
    return @{ Code = $code; Body = $parts[0].Trim() }
}

function Login($name, $login, $pw) {
    $r = Req $name 'POST' '/api/v1/auth/login' @() ('{"login_name":"' + $login + '","password":"' + $pw + '"}')
    if ($r.Code -ne 200) { return "" }
    return ($r.Body | ConvertFrom-Json).data.token
}

function Json($r) { return ($r.Body | ConvertFrom-Json) }

Write-Host "=== 令牌鉴权端到端测试 ==="
Write-Host "  目标: $Base"
Write-Host ""

# ── 1) 无令牌 → 401 ────────────────────────────────────────────────────────
Write-Host "[1] 未认证访问"
$r = Req 'a1' 'GET' '/api/v1/schedules/1' @() $null
Check "无令牌访问业务接口 → 401" ($r.Code -eq 401)
Check "错误码为 AUTH_REQUIRED" ((Json $r).error.code -eq "AUTH_REQUIRED")

# ── 2) 开发态头应被忽略（未开 --dev-auth）────────────────────────────────
$r = Req 'a2' 'GET' '/api/v1/schedules/1' @('X-Role: admin') $null
Check "未开 --dev-auth 时 X-Role 头被忽略 → 401" ($r.Code -eq 401)

# ── 3) 登录 ────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "[2] 登录"
$rBad = Req 'a3' 'POST' '/api/v1/auth/login' @() ('{"login_name":"' + $AdminLogin + '","password":"wrong"}')
Check "错误口令 → 401" ($rBad.Code -eq 401)
$rNo = Req 'a4' 'POST' '/api/v1/auth/login' @() '{"login_name":"no-such-user-xyz","password":"wrong"}'
Check "账号不存在 → 同一个错误码（防枚举）" `
      ((Json $rBad).error.code -eq (Json $rNo).error.code -and (Json $rNo).error.code -eq "AUTH_BAD_CREDENTIALS")

$admin = Login 'a5' $AdminLogin $AdminPw
Check "管理员登录成功并拿到 64 字符令牌" ($admin.Length -eq 64)

# ── 4) Bearer 鉴权 ────────────────────────────────────────────────────────
Write-Host ""
Write-Host "[3] Bearer 鉴权"
$r = Req 'a6' 'GET' '/api/v1/auth/me' @("Authorization: Bearer $admin") $null
Check "/auth/me → 200" ($r.Code -eq 200)
Check "角色为 admin" ((Json $r).data.role -eq "admin")
$r = Req 'a7' 'GET' '/api/v1/auth/me' @('Authorization: Bearer not-a-real-token') $null
Check "乱令牌 → 401" ($r.Code -eq 401)

# ── 5) 造/取患者账号，验三端权限 ──────────────────────────────────────────
Write-Host ""
Write-Host "[4] 三端权限"
# ★ 测试必须**自建可复现的夹具**，不能依赖"上次跑完留下的状态"。
#   实测踩到过：脚本第一次跑失败 8 项，根因就是它假定患者口令是 patient-pw-1，
#   而上一轮手工测试已经把它改掉了 —— 于是后面全部级联失败。
#
# 做法：① 试建账号；② 若已存在（409），则**用登录名反查 user_id** 再重置口令。
#   第②步需要"按登录名查 id"——这正是 `GET /api/v1/admin/users?login_name=` 的用途，
#   它同时也是前台"我账号的 id 是多少"的常规需求。
$r = Req 'a8' 'POST' '/api/v1/admin/users' @("Authorization: Bearer $admin") `
     ('{"login_name":"' + $PatientLogin + '","password":"' + $PatientPw + '","role":"patient","ref_id":' + $PatientRefId + ',"display_name":"测试患者"}')
$created = ($r.Code -eq 201)
Check "管理员建患者账号（201 新建 / 409 已存在）" ($r.Code -eq 201 -or $r.Code -eq 409)

# 无论新建还是已存在，都把夹具口令拉回已知值
$r = Req 'a8b' 'GET' ("/api/v1/admin/users?login_name=" + $PatientLogin) @("Authorization: Bearer $admin") $null
if ($r.Code -eq 200) {
    $puid = (Json $r).data.user_id
    $null = Req 'a8c' 'POST' "/api/v1/admin/users/$puid/password" @("Authorization: Bearer $admin") `
            ('{"password":"' + $PatientPw + '"}')
    Check "夹具口令已重置为已知值" $true
} else {
    Check "按登录名查到患者 user_id" $false
}

$ptok = Login 'a9' $PatientLogin $PatientPw
Check "患者登录成功（夹具口令有效）" ($ptok.Length -eq 64)
$r = Req 'a10' 'GET' '/api/v1/auth/me' @("Authorization: Bearer $ptok") $null
Check "患者 /auth/me 带 patient_id" ((Json $r).data.patient_id -eq $PatientRefId)

$r = Req 'a11' 'POST' '/api/v1/admin/schedules' @("Authorization: Bearer $ptok") `
     '{"doctor_id":1,"department_id":1,"work_date":"2026-12-31","period":"AM","total_num":1}'
Check "患者建排班 → 403 FORBIDDEN_ROLE" ($r.Code -eq 403)
$r = Req 'a12' 'POST' '/api/v1/admin/users' @("Authorization: Bearer $ptok") `
     '{"login_name":"zzz","password":"yyy","role":"patient","ref_id":1}'
Check "患者建账号 → 403" ($r.Code -eq 403)

# ⚠ 这里断言的是**权限**（患者能读），不是"那条排班一定存在"。
#   实测踩到：原先写死断言 `== 200`，而 `stress-booking.ps1` 会把 schedule 表清空 ——
#   于是单独跑 auth-check（或在压测之后跑）会因为"排班不存在"而假失败。
#   正确的断言是：**可以读**（200）或**排班不存在**（404），但**绝不能是 403**。
#   403 才说明权限判定错了；404 只说明夹具里没数据，与权限无关。
$r = Req 'a13' 'GET' '/api/v1/schedules/1' @("Authorization: Bearer $ptok") $null
Check "患者查排班（有则 200 / 无则 404，但绝不是 403）" `
      ($r.Code -eq 200 -or $r.Code -eq 404)
Check "患者查排班未因权限被拒（非 403）" ($r.Code -ne 403)

# ── 6) 登出吊销 ───────────────────────────────────────────────────────────
Write-Host ""
Write-Host "[5] 登出与吊销"
$throwaway = Login 'a14' $PatientLogin $PatientPw
$r = Req 'a15' 'POST' '/api/v1/auth/logout' @("Authorization: Bearer $throwaway") $null
Check "登出 → 200" ($r.Code -eq 200)
$r = Req 'a16' 'GET' '/api/v1/auth/me' @("Authorization: Bearer $throwaway") $null
Check "登出后同一令牌失效 → 401" ($r.Code -eq 401)

# ── 7) ★ 改口令吊销全部令牌 ───────────────────────────────────────────────
Write-Host ""
Write-Host "[6] 改口令必须踢下线"
$tokA = Login 'a17' $PatientLogin $PatientPw
$newPw = "rotated-" + (Get-Random -Minimum 100000 -Maximum 999999)
# 找 user_id
$me = Json (Req 'a18' 'GET' '/api/v1/auth/me' @("Authorization: Bearer $tokA") $null)
$uid = $me.data.user_id
$r = Req 'a19' 'POST' "/api/v1/admin/users/$uid/password" @("Authorization: Bearer $admin") `
     ('{"password":"' + $newPw + '"}')
Check "管理员重置口令 → 200" ($r.Code -eq 200)
$r = Req 'a20' 'GET' '/api/v1/auth/me' @("Authorization: Bearer $tokA") $null
Check "★ 旧令牌立即失效 → 401" ($r.Code -eq 401)
$r = Req 'a21' 'POST' '/api/v1/auth/login' @() ('{"login_name":"' + $PatientLogin + '","password":"' + $PatientPw + '"}')
Check "旧口令登录失败 → 401" ($r.Code -eq 401)
$r = Req 'a22' 'POST' '/api/v1/auth/login' @() ('{"login_name":"' + $PatientLogin + '","password":"' + $newPw + '"}')
Check "新口令登录成功 → 200" ($r.Code -eq 200)
# 还原口令，便于脚本重复跑
$null = Req 'a23' 'POST' "/api/v1/admin/users/$uid/password" @("Authorization: Bearer $admin") `
        ('{"password":"' + $PatientPw + '"}')

$r = Req 'a24' 'POST' '/api/v1/admin/users/99999/password' @("Authorization: Bearer $admin") '{"password":"x"}'
Check "不存在的账号 → 404 USER_NOT_FOUND" ($r.Code -eq 404)

# ── 8) 防枚举计时 ─────────────────────────────────────────────────────────
if (-not $SkipTiming) {
    Write-Host ""
    Write-Host "[7] 防枚举计时（各 5 次）"
    $tExist = @(); $tNone = @()
    foreach ($i in 1..5) {
        $tExist += (Measure-Command {
            $null = Req "t1$i" 'POST' '/api/v1/auth/login' @() ('{"login_name":"' + $AdminLogin + '","password":"definitely-wrong"}')
        }).TotalMilliseconds
        $tNone += (Measure-Command {
            $null = Req "t2$i" 'POST' '/api/v1/auth/login' @() '{"login_name":"no-such-user-xyz","password":"definitely-wrong"}'
        }).TotalMilliseconds
    }
    $a1 = ($tExist | Measure-Object -Average).Average
    $a2 = ($tNone | Measure-Object -Average).Average
    $ratio = [Math]::Max($a1, $a2) / [Math]::Min($a1, $a2)
    Write-Host ("    账号存在(口令错) 平均 {0:N1} ms ｜ 账号不存在 平均 {1:N1} ms" -f $a1, $a2)
    Write-Host ("    比值 {0:N2}（基线未防护时约 13 倍）" -f $ratio)
    Check "计时接近（比值 < 2）⇒ 防枚举成立" ($ratio -lt 2)
}

Remove-Item $tmp -Recurse -Force
Write-Host ""
if ($fail -eq 0) {
    Write-Host "✅ 令牌鉴权端到端测试全部通过"
    exit 0
} else {
    Write-Host "❌ 令牌鉴权测试失败 $fail 项"
    exit 1
}
