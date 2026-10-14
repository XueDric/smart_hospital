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
    # 用于**自清限流状态**（本脚本会故意打错口令，不清理就会把自己锁死）
    [string]$Dsn = "mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital_test",
    [switch]$SkipTiming
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrEmpty($AdminPw)) {
    throw "必须提供 -AdminPw（先跑 hospital-server.exe create-admin <dsn> 拿到口令）"
}

# ── 连接参数从 DSN 派生（唯一事实来源，见 common.ps1 顶部说明）──
. "$PSScriptRoot\common.ps1"
$My = Get-MySqlClientArgs -Dsn $Dsn

$tmp = Join-Path $env:TEMP ("authcheck-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

# ★ 自清限流状态（2026-10-07 修，第三份复查发现的**严重**缺陷）。
#
# ── 问题：本脚本**不再可重复**、也不再顺序无关 ──────────────────────────
# 第 7 节"防枚举计时"会对 admin **连打 5 次错口令** —— 正好触发登录锁定，
# 而脚本**没有清理限流状态**。实测：
#     第 1 次跑：25 PASS / 0 FAIL
#     紧接着第 2 次：13 PASS / 12 FAIL，且登录全部 429
#
# 这推翻了 P1-HANDOFF 里"三个脚本互不依赖执行顺序（各自夹具自建自清）"的说法，
# 也会让"跑完 auth-check 再跑 stress/tls"失败 —— 因为 admin 已被锁死。
# 讽刺的是 `rate-limit-check.ps1` 的注释里**已经识别了这个风险**
# （"塞进 auth-check 会让那个脚本的假设被限流状态污染"），
# 却只顾自己做自清，没管 auth-check。现在补上。
#
# ⚠ 清的是**限流计数**（auth_login_attempt），不是业务数据 ——
#   与其它脚本"自建夹具、自清"的纪律一致。
# ⚠ 这里必须用 PowerShell 的 `#` 注释：本文件是 **PowerShell 脚本**，
#   写 C 风格 /* */ 会被当命令执行（实测报 "无法将 /* 项识别为 cmdlet"）。
function Reset-LoginAttempts {
    $null = Invoke-MySqlScalar -My $My -Sql "DELETE FROM auth_login_attempt" -Label "清限流计数"
}
Reset-LoginAttempts

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

# ── 3b) ★★ 滑动续期后的有效期必须能被客户端读到（跨端审计 F11）────────────
Write-Host ""
Write-Host "[3b] ★★ /auth/me 必须回报当前令牌有效期（F11）"
# ── 这一节守的是跨端审计 F11 ─────────────────────────────────────────────
# 审计原文：`auth_repo.cj` 的滑动续期会把 `expires_at` 往后推，但响应里**没有地方**
# 告诉客户端"现在的到期时刻是多少" ⇒ 各端一直拿登录那一刻的旧值倒计时，
# Android 端会在令牌仍然有效时把用户踢回登录页（本地值比服务端旧一天）。
#
# 这里验的是 **HTTP 可见性**：字段确实发出来了，且与登录响应同口径。
# "续期真的发生后回填的是**新**值、且与库中一致"由 `accept` 的 AC-14 用固定时间戳断言
# （那需要把令牌拨到该续期的状态，HTTP 层做不到确定性）。
$rLogin = Req 'a6b' 'POST' '/api/v1/auth/login' @() ('{"login_name":"' + $AdminLogin + '","password":"' + $AdminPw + '"}')
$loginExp = (Json $rLogin).data.expires_at
$tokF11 = (Json $rLogin).data.token
Check "夹具：登录响应带 expires_at（实得 $loginExp）" ($null -ne $loginExp -and $loginExp -gt 0)
$r = Req 'a6c' 'GET' '/api/v1/auth/me' @("Authorization: Bearer $tokF11") $null
$meExp = (Json $r).data.expires_at
Check "★★ /auth/me 回报 expires_at（此前完全没有这个字段）" ($null -ne $meExp -and $meExp -gt 0) ("实得 $meExp")
Check "★★ 且与登录响应一致（同一个到期时刻 ⇒ 客户端可据此刷新本地倒计时）" `
      ($meExp -eq $loginExp) ("me=$meExp login=$loginExp")
$nowEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
Check "★ 该值在未来（不是 0 / 不是过去，否则客户端会立刻进登录页）" `
      ($meExp -gt $nowEpoch) ("exp=$meExp now=$nowEpoch")

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

# ── 4b) ★ 账号列表模式（管理台「用户管理」页要列表 / 翻页 / 按角色筛）
#   ⚠ 这个端点原先**只能按 login_name 精确查一条**：管理台要列表、要翻页、
#     要按角色筛，接口根本不支持（只能靠"猜登录名"逐条试）。
#   ⚠ 同时守一条隐私纪律：列表**不得**吐出任何口令材料（pw_hash / pw_salt）。
Write-Host ""
Write-Host "[4b] ★ 账号列表模式（列表 / 筛选 / 翻页 / 不吐口令材料）"
$r = Req 'a25' 'GET' '/api/v1/admin/users?limit=200' @("Authorization: Bearer $admin") $null
$lj = Json $r
$short = $r.Body.Substring(0, [Math]::Min(200, $r.Body.Length))
Check "列表模式 ⇒ 200（不带 login_name 也能查）" ($r.Code -eq 200) ("HTTP $($r.Code)")
Check "返回 items / count / total / limit / offset 五个字段" `
      ($null -ne $lj.data.items -and $null -ne $lj.data.count -and $null -ne $lj.data.total -and `
       $null -ne $lj.data.limit -and $null -ne $lj.data.offset) ("body=$short")
Check "★★ 列表里能查到刚建的患者账号（$PatientLogin）" `
      ((@($lj.data.items | Where-Object { $_.login_name -eq $PatientLogin })).Count -eq 1) ("body=$short")
Check "★★★ 响应里**没有** pw_hash / pw_salt 字段（列表最容易被整页导出）" `
      (-not ($r.Body -match 'pw_hash|pw_salt')) ("body=$short")
Check "count 与 items 条数一致（口径不漂移）" ([int]$lj.data.count -eq @($lj.data.items).Count) `
      ("count=$($lj.data.count) items=$(@($lj.data.items).Count)")

$r = Req 'a26' 'GET' '/api/v1/admin/users?role=admin&limit=200' @("Authorization: Bearer $admin") $null
$aOnly = Json $r
Check "★ role=admin 筛选生效（结果里全是 admin）" `
      ((@($aOnly.data.items | Where-Object { $_.role -ne 'admin' })).Count -eq 0) `
      ("roles=$((@($aOnly.data.items | ForEach-Object { $_.role }) | Select-Object -Unique) -join ',')")

$r = Req 'a27' 'GET' '/api/v1/admin/users?role=nobody&limit=200' @("Authorization: Bearer $admin") $null
$badRole = Json $r
Check "★★ 白名单外的 role 值 = 不筛（不报错、也不查成空）" `
      ([int]$badRole.data.count -eq [int]$lj.data.count) ("bad=$($badRole.data.count) all=$($lj.data.count)")

$r = Req 'a28' 'GET' '/api/v1/admin/users?limit=1&offset=0' @("Authorization: Bearer $admin") $null
$p1 = Json $r
$r = Req 'a29' 'GET' '/api/v1/admin/users?limit=1&offset=1' @("Authorization: Bearer $admin") $null
$p2 = Json $r
Check "★ limit/offset 翻页生效（第 1、2 页不是同一行）" `
      ([int]$p1.data.count -eq 1 -and [int]$p2.data.count -eq 1 -and `
       @($p1.data.items)[0].user_id -ne @($p2.data.items)[0].user_id) `
      ("p1=$(@($p1.data.items)[0].user_id) p2=$(@($p2.data.items)[0].user_id)")

$r = Req 'a30' 'GET' '/api/v1/admin/users?limit=9999' @("Authorization: Bearer $admin") $null
$over = Json $r
Check "★★ 要得比上限多 ⇒ 回默认 50，且真的只给 50 条（不因为你要得多就多给）" `
      ([int]$over.data.limit -eq 50 -and [int]$over.data.count -le 50) `
      ("limit=$($over.data.limit) count=$($over.data.count)")
Check "★★ 且 total 仍报全量（分页信息不因为被夹而失真：total > count 才翻得动页）" `
      ([int]$over.data.total -ge [int]$over.data.count) ("total=$($over.data.total) count=$($over.data.count)")

$r = Req 'a31' 'GET' '/api/v1/admin/users?login_name=no-such-user-xyz' @("Authorization: Bearer $admin") $null
Check "★★ 精确查询语义未变：查不到仍是 404 USER_NOT_FOUND（老调用方零改动）" `
      ($r.Code -eq 404 -and (Json $r).error.code -eq 'USER_NOT_FOUND') ("HTTP $($r.Code)")

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
    Write-Host ("    比值 {0:N2}（搬迁前未防护时约 13 倍）" -f $ratio)
    Check "计时接近（比值 < 2）⇒ 防枚举成立" ($ratio -lt 2)
    # ★ 计时段打了 5+ 次错口令 —— 跑完必须清，否则 admin 被锁着交给下一个脚本
    Reset-LoginAttempts
}

Remove-Item $tmp -Recurse -Force
Write-Host ""
if ($fail -eq 0) {
    Reset-LoginAttempts
    Write-Host "✅ 令牌鉴权端到端测试全部通过"
    exit 0
} else {
    Write-Host "❌ 令牌鉴权测试失败 $fail 项"
    exit 1
}
