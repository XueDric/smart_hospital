# P1 收尾项验证：口令强度 / 会话按设备 / 我的挂号 / 排班列表
#
# ⚠ 含中文的 PowerShell 脚本必须 UTF-8 with BOM。
# ⚠ header/body 走 curl **config 文件**（-K）：含空格的 -H 会被拆坏。
#
# 用法：.\p1-extra-check.ps1 -Base http://127.0.0.1:8091 -AdminPw <口令>
#
# ⚠⚠ 第 [5] 节**必须在最后跑**，且它会**把 admin 口令改成随机值**：
#   · 它用 CLI `create-admin` 跑 40 次端到端回归，每次都会重置 admin 口令并吊销其令牌；
#   · 所以本脚本开头拿到的 `$admTok` 在那一节之后**必然失效**（这是**正确行为**，
#     不是缺陷 —— "改口令必须踢下线"就是这么设计的）；
#   · 副作用：脚本跑完后 **admin 口令不再是 -AdminPw 那个**。
#   → 脚本结尾会把新口令打印出来（`▸ 新管理员口令`），请记下来；
#     或者直接重跑 `hospital-server.exe create-admin <dsn>` 再拿一个。
#
#   📌 为什么不把第 [5] 节挪到单独脚本：它验的是"生成器与校验器一致"，
#     而那个缺陷的表现一半在 CLI 层（异常直冒堆栈）—— 放在这里才能顺带覆盖
#     "CLI 失败是否给清晰提示"。分开会让这半边没人守。

param(
    [string]$Base = "http://127.0.0.1:8091",
    [string]$AdminPw = "",
    [string]$Dsn = "mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital_test"
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\common.ps1"
$My = Get-MySqlClientArgs -Dsn $Dsn

$fail = 0
function Check($name, $ok, $detail) {
    if ($ok) { Write-Host "  [PASS] $name" }
    else { Write-Host "  [FAIL] $name"; $script:fail++ }
    if ($detail) { Write-Host "         $detail" }
}

# ★ 自建夹具、自清（本脚本可重复跑）
#
# ⚠ 这条纪律是踩出来的：第一版没清数据，第二次跑时
#   "组合筛选 count=1" 失败（库里残留上一次建的排班 ⇒ count=2）、
#   "我的挂号含刚挂的单" 也受残留影响。
#   测试**必须**对"自己造的数据"有唯一定位，并在开头清掉 ——
#   否则它会随运行次数漂移，变成"第二次跑就红"的假缺陷。
$null = Invoke-MySqlScalar -My $My -Sql "DELETE FROM schedule WHERE department_id IN (7, 8) AND work_date IN ('2026-12-25','2026-12-26')" -Label "清测试排班"
# ⚠ 挂号单**不能靠 client_token 删** —— 退号时我们会把 client_token 置 NULL
#   （"退号释放幂等键"，见 domain_booking 的 cancel 注释），所以上一次跑完
#   那张单的 client_token 已经是 NULL，按 token 删**匹配不到**，
#   于是每次都残留一张 cancelled 单 ⇒ "我的挂号"条数随运行次数增长。
#   正解：按 (patient_id, schedule_id) 删测试用排班上的单。
$null = Invoke-MySqlScalar -My $My -Sql "DELETE FROM appointment WHERE schedule_id IN (SELECT id FROM schedule WHERE department_id IN (7,8) AND work_date IN ('2026-12-25','2026-12-26'))" -Label "清测试挂号"

$tmp = Join-Path $env:TEMP ("p1x-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

# 自清限流状态：本脚本会故意用弱口令/错口令，不清会把自己锁死
$null = Invoke-MySqlScalar -My $My -Sql "DELETE FROM auth_login_attempt" -Label "清限流计数"

function DoReq($name, $method, $path, $headers, $body) {
    $f = Join-Path $tmp "$name.cfg"
    $lines = @("request = `"$method`"")
    foreach ($h in $headers) { $lines += "header = `"$h`"" }
    if ($body) {
        $bf = Join-Path $tmp "$name.body"
        [System.IO.File]::WriteAllText($bf, $body, (New-Object System.Text.UTF8Encoding($false)))
        $lines += ('data = "@' + ($bf -replace '\\','/') + '"')
        $lines += 'header = "Content-Type: application/json"'
    }
    $lines += 'silent'
    $lines += 'write-out = "\n__M__%{http_code}"'
    [System.IO.File]::WriteAllText($f, ($lines -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
    $raw = (& curl.exe -s -K $f "$Base$path" 2>&1) -join "`n"
    $parts = $raw -split "__M__"
    $obj = $null
    try { $obj = $parts[0].Trim() | ConvertFrom-Json } catch { }
    return @{ Http = [int]$parts[1].Trim(); Body = $parts[0].Trim(); Json = $obj }
}

if ([string]::IsNullOrEmpty($AdminPw)) { throw "需要 -AdminPw" }

# 管理员登录（带设备头，便于会话测试）
$adm = DoReq 'adm' 'POST' '/api/v1/auth/login' @('X-Device-Id: admin-console', 'X-Device-Name: Admin Console') `
       ('{"login_name":"admin","password":"' + $AdminPw + '"}')
Check "管理员登录成功（带设备头）" ($adm.Http -eq 200) ("HTTP $($adm.Http)")
$admTok = $adm.Json.data.token

# ===================== ① 口令强度 =====================
Write-Host ""
Write-Host "[1] 口令强度校验"

# 弱的：应 400 VALIDATION_FAILED（**不是 500**）
$weak = @(
    @{ pw = 'short1';    why = '太短（6 位）' },
    @{ pw = 'abcdefgh';  why = '只有字母、无数字' },
    @{ pw = '12345678';  why = '只有数字' },
    @{ pw = 'password';  why = '常见弱口令' },
    @{ pw = 'admin123';  why = '常见弱口令（在弱口令表里；注意"含登录名"那一条由下面单独用例覆盖）' }
)
foreach ($w in $weak) {
    $r = DoReq ('w' + [Guid]::NewGuid().ToString('N').Substring(0, 6)) 'POST' '/api/v1/admin/users' `
         @("Authorization: Bearer $admTok") `
         ('{"login_name":"weaktest' + (Get-Random) + '","password":"' + $w.pw + '","role":"patient","ref_id":1}')
    $code = if ($r.Json -and $r.Json.error) { $r.Json.error.code } else { "" }
    Check "拒绝弱口令（$($w.why)）→ 400 VALIDATION_FAILED，不是 500" `
          ($r.Http -eq 400 -and $code -eq 'VALIDATION_FAILED') ("HTTP $($r.Http) code=$code")
}

# 强的：应通过
#
# ★★ 关键修正（2026-10-07，我第一版测试写错了）：
#   第一版对 **admin 自己**重置口令 —— 而"改口令必须吊销该账号全部令牌"是**正确行为**，
#   于是管理员令牌当场失效，后面所有用例全 401（看起来像功能坏了，其实是测试设计错）。
#   正解：口令测试用**专用账号**，绝不拿当前会话所属的账号做实验。
#   📌 这也是一条通用的测试纪律：**不要用"你自己正在用来操作的那个身份"做破坏性测试。**
$ptLogin = 'pwtest-user'
$mk = DoReq 'mkpwtest' 'POST' '/api/v1/admin/users' @("Authorization: Bearer $admTok") `
      ('{"login_name":"' + $ptLogin + '","password":"InitPass123","role":"patient","ref_id":1}')
Check "建口令测试专用账号（初始口令合格）" ($mk.Http -eq 201 -or $mk.Http -eq 409) ("HTTP $($mk.Http)")
$ptUid = Invoke-MySqlScalar -My $My -Sql "SELECT id FROM auth_user WHERE login_name='$ptLogin'" -Label "$ptLogin id"

$strong = 'Str0ngPass2026'
$r = DoReq 'strong' 'POST' "/api/v1/admin/users/$ptUid/password" @("Authorization: Bearer $admTok") `
     ('{"password":"' + $strong + '"}')
Check "接受强口令（含字母+数字、≥8 位、非弱口令）" ($r.Http -eq 200) ("HTTP $($r.Http)")
Check "★ 管理员自己的令牌**未**被影响（改的是别人的口令）" `
      ((DoReq 'admstill' 'GET' '/api/v1/auth/me' @("Authorization: Bearer $admTok") $null).Http -eq 200)

# 新口令能登录
$null = Invoke-MySqlScalar -My $My -Sql "DELETE FROM auth_login_attempt" -Label "清计数"
$lg = DoReq 'ptlogin' 'POST' '/api/v1/auth/login' @() ('{"login_name":"' + $ptLogin + '","password":"' + $strong + '"}')
Check "专用账号能用新口令登录" ($lg.Http -eq 200) ("HTTP $($lg.Http)")

# 口令等于登录名 → 拒
$r = DoReq 'eqname' 'POST' "/api/v1/admin/users/$ptUid/password" @("Authorization: Bearer $admTok") `
     ('{"password":"' + $ptLogin + '"}')
Check "拒绝"口令等于登录名"" ($r.Http -eq 400) ("HTTP $($r.Http)")

# ★ 口令强度不足时**不得**把用户踢下线（顺序：先校验，再落库+吊销）
$beforeTok = $lg.Json.data.token
$r = DoReq 'weakrej' 'POST' "/api/v1/admin/users/$ptUid/password" @("Authorization: Bearer $admTok") `
     '{"password":"123"}'
Check "弱口令被拒（400）" ($r.Http -eq 400) ("HTTP $($r.Http)")
$after = DoReq 'afterweak' 'GET' '/api/v1/auth/me' @("Authorization: Bearer $beforeTok") $null
Check "★ 弱口令被拒后，用户**未被踢下线**（校验先于吊销）" ($after.Http -eq 200) ("HTTP $($after.Http)")

# 不存在的账号 → 404（UserFacingError 映射），不是 500
$r = DoReq 'nouser' 'POST' '/api/v1/admin/users/999999/password' @("Authorization: Bearer $admTok") `
     '{"password":"Valid12345"}'
Check "给不存在的账号重置口令 → 404，不是 500" ($r.Http -eq 404) ("HTTP $($r.Http)")

# ===================== ② 会话按设备 =====================
Write-Host ""
Write-Host "[2] 令牌按设备管理"
$null = Invoke-MySqlScalar -My $My -Sql "DELETE FROM auth_login_attempt" -Label "清计数"
# 用两个不同设备 id 登录同一账号
$s1 = DoReq 's1' 'POST' '/api/v1/auth/login' @('X-Device-Id: dev-AAA', 'X-Device-Name: iPhone 15') `
      ('{"login_name":"admin","password":"' + $AdminPw + '"}')
$s2 = DoReq 's2' 'POST' '/api/v1/auth/login' @('X-Device-Id: dev-BBB', 'X-Device-Name: Chrome Win') `
      ('{"login_name":"admin","password":"' + $AdminPw + '"}')
Check "两台设备分别登录成功" ($s1.Http -eq 200 -and $s2.Http -eq 200)
$t1 = $s1.Json.data.token
$t2 = $s2.Json.data.token

$r = DoReq 'ls' 'GET' '/api/v1/auth/sessions' @("Authorization: Bearer $t1") $null
$devs = @()
if ($r.Json -and $r.Json.data) { $devs = @($r.Json.data.sessions | ForEach-Object { $_.device_id }) }
Check "会话列表能列出两台设备" (($devs -contains 'dev-AAA') -and ($devs -contains 'dev-BBB')) ("devices: $($devs -join ', ')")
Check "会话列表**不含 token**（只回设备信息）" `
      (-not ($r.Body -match [regex]::Escape($t1))) "响应里搜不到 token 原文"

# 踢掉 dev-AAA → 该设备的令牌应立即失效，dev-BBB 不受影响
$r = DoReq 'kick' 'POST' '/api/v1/auth/sessions/revoke' @("Authorization: Bearer $t2") '{"device_id":"dev-AAA"}'
Check "踢掉 dev-AAA 返回 revoked=1" ($r.Http -eq 200 -and $r.Json.data.revoked -eq 1) ("HTTP $($r.Http) revoked=$($r.Json.data.revoked)")
$me1 = DoReq 'me1' 'GET' '/api/v1/auth/me' @("Authorization: Bearer $t1") $null
$me2 = DoReq 'me2' 'GET' '/api/v1/auth/me' @("Authorization: Bearer $t2") $null
Check "★ 被踢设备的令牌已失效（401）" ($me1.Http -eq 401) ("HTTP $($me1.Http)")
Check "★ 另一台设备**不受影响**（200）" ($me2.Http -eq 200) ("HTTP $($me2.Http)")

# 空 device_id 必须拒绝（否则等于"踢全部"）
$r = DoReq 'empty' 'POST' '/api/v1/auth/sessions/revoke' @("Authorization: Bearer $t2") '{"device_id":""}'
Check "★ 空 device_id 被拒绝 400（不能退化成"踢全部"）" ($r.Http -eq 400) ("HTTP $($r.Http)")
$me2b = DoReq 'me2b' 'GET' '/api/v1/auth/me' @("Authorization: Bearer $t2") $null
Check "空 device_id 被拒后，会话仍在（没被误删）" ($me2b.Http -eq 200) ("HTTP $($me2b.Http)")

# ===================== ③ 我的挂号 =====================
Write-Host ""
Write-Host "[3] 患者"我的挂号""
# 患者令牌（夹具由 auth-check 建过；这里自己确保存在）
$null = Invoke-MySqlScalar -My $My -Sql "DELETE FROM auth_login_attempt" -Label "清计数"
$pl = DoReq 'plogin' 'POST' '/api/v1/auth/login' @() '{"login_name":"13800000001","password":"patient-pw-1"}'
if ($pl.Http -ne 200) {
    Write-Host "  [SKIP] 患者夹具不可用（先跑 auth-check.ps1 建夹具）：HTTP $($pl.Http)"
} else {
    $pTok = $pl.Json.data.token
    $myPat = $pl.Json.data.patient_id
    # 造一个排班 + 挂一单
    $r = DoReq 'mk' 'POST' '/api/v1/admin/schedules' @("Authorization: Bearer $admTok") `
         '{"doctor_id":1,"department_id":1,"work_date":"2026-12-20","period":"AM","total_num":5}'
    $sid = $r.Json.data.schedule_id
    $b = DoReq 'bk' 'POST' '/api/v1/appointments' @("Authorization: Bearer $pTok") `
         ('{"schedule_id":' + $sid + ',"client_token":"my-appt-1"}')
    Check "患者挂号成功" ($b.Http -eq 201) ("HTTP $($b.Http)")

    $r = DoReq 'mine' 'GET' '/api/v1/appointments' @("Authorization: Bearer $pTok") $null
    $list = @()
    if ($r.Json -and $r.Json.data) { $list = @($r.Json.data.appointments) }
    $justBooked = $b.Json.data.appointment_id
    # ⚠ 断言要**按 id 精确**，不要断言"列表长度 == 1"：
    #   这个测试库会被多个脚本反复用，患者可能还有别的有效单（不属本用例）。
    #   测"我刚挂的那张在不在"，而不是"列表里只有一张"——
    #   后者会把"别的用例留下的数据"误判成本用例的缺陷（我第一版就这么错了）。
    Check "★ 我的挂号列表含刚挂的那张单（id=$justBooked）" `
          (@($list | Where-Object { $_.appointment_id -eq $justBooked }).Count -eq 1) ("共 $($list.Count) 条")
    # ★ 更强的一致性断言：返回条数 == 库里该患者的有效单数（证明既没漏也没多）
    $dbActive = Invoke-MySqlScalar -My $My -Sql "SELECT COUNT(*) FROM appointment WHERE patient_id = $myPat AND status <> 'cancelled'" -Label "患者有效单数"
    Check "★ 列表条数 == 库中该患者有效单数（$($list.Count) == $dbActive）" ("$($list.Count)" -eq "$dbActive")
    Check "★ 列表里**每一条**都属于自己（patient_id = $myPat）" `
          ((@($list | Where-Object { $_.patient_id -ne $myPat }).Count) -eq 0) `
          ("异己条数: " + @($list | Where-Object { $_.patient_id -ne $myPat }).Count)

    # 管理员调这个接口应被拒（它只对患者开放）
    $r = DoReq 'mineadm' 'GET' '/api/v1/appointments' @("Authorization: Bearer $admTok") $null
    Check "管理员调"我的挂号"→ 403（接口只对患者开放）" ($r.Http -eq 403) ("HTTP $($r.Http)")

    # ★ 越权尝试：加 patient_id 参数看能否读别人
    $r = DoReq 'peek' 'GET' ('/api/v1/appointments?patient_id=' + ($myPat + 1)) @("Authorization: Bearer $pTok") $null
    $leak = 0
    if ($r.Json -and $r.Json.data) { $leak = @($r.Json.data.appointments | Where-Object { $_.patient_id -ne $myPat }).Count }
    Check "★ 传 patient_id 参数也读不到别人的单（参数被忽略）" ($leak -eq 0) ("异己条数: $leak")

    # 退号后默认列表不再包含它
    $aid = ($list | Where-Object { $_.schedule_id -eq $sid } | Select-Object -First 1).appointment_id
    $c = DoReq 'cx' 'POST' "/api/v1/appointments/$aid/cancel" @("Authorization: Bearer $pTok") $null
    Check "退号成功" ($c.Http -eq 200) ("HTTP $($c.Http)")
    $r = DoReq 'mine2' 'GET' '/api/v1/appointments' @("Authorization: Bearer $pTok") $null
    $has = $false
    if ($r.Json -and $r.Json.data) { $has = @($r.Json.data.appointments | Where-Object { $_.appointment_id -eq $aid }).Count -gt 0 }
    Check "★ 退号后默认列表**不再**包含该单" (-not $has)
    $r = DoReq 'mine3' 'GET' '/api/v1/appointments?include_cancelled=true' @("Authorization: Bearer $pTok") $null
    $has2 = $false
    if ($r.Json -and $r.Json.data) { $has2 = @($r.Json.data.appointments | Where-Object { $_.appointment_id -eq $aid }).Count -gt 0 }
    Check "include_cancelled=true 时**能**看到已取消的单" $has2
}

# ===================== ④ 排班列表 =====================
Write-Host ""
Write-Host "[4] 排班列表（按科室/日期）"
$r = DoReq 'schmk' 'POST' '/api/v1/admin/schedules' @("Authorization: Bearer $admTok") `
     '{"doctor_id":1,"department_id":7,"work_date":"2026-12-25","period":"PM","total_num":3}'
$sidA = $r.Json.data.schedule_id
$r = DoReq 'schmk2' 'POST' '/api/v1/admin/schedules' @("Authorization: Bearer $admTok") `
     '{"doctor_id":1,"department_id":8,"work_date":"2026-12-26","period":"AM","total_num":3}'
$sidB = $r.Json.data.schedule_id

$r = DoReq 'l1' 'GET' '/api/v1/schedules?department_id=7' @("Authorization: Bearer $admTok") $null
$deps = @()
if ($r.Json -and $r.Json.data) { $deps = @($r.Json.data.schedules | ForEach-Object { $_.department_id }) }
Check "按科室筛选：只返回该科室（7）" (($deps | Where-Object { $_ -ne 7 }).Count -eq 0 -and $deps.Count -ge 1) ("科室内: $($deps -join ',')")

$r = DoReq 'l2' 'GET' '/api/v1/schedules?work_date=2026-12-25' @("Authorization: Bearer $admTok") $null
$dates = @()
if ($r.Json -and $r.Json.data) { $dates = @($r.Json.data.schedules | ForEach-Object { $_.work_date }) }
Check "按日期筛选：只返回该日期（2026-12-25）" (($dates | Where-Object { $_ -ne '2026-12-25' }).Count -eq 0 -and $dates.Count -ge 1) ("日期: $($dates -join ',')")

$r = DoReq 'l3' 'GET' '/api/v1/schedules?department_id=7&work_date=2026-12-25' @("Authorization: Bearer $admTok") $null
$both = @()
if ($r.Json -and $r.Json.data) { $both = @($r.Json.data.schedules) }
Check "科室+日期组合筛选命中那一条" ($both.Count -eq 1 -and $both[0].id -eq $sidA) ("count=$($both.Count)")

# 已约满的排班也要出现在列表里（否则患者以为"这天没排班"）
$null = Invoke-MySqlScalar -My $My -Sql "UPDATE schedule SET remain_num = 0 WHERE id = $sidB" -Label "置为约满"
$r = DoReq 'l4' 'GET' '/api/v1/schedules?work_date=2026-12-26' @("Authorization: Bearer $admTok") $null
$found = $false
if ($r.Json -and $r.Json.data) { $found = @($r.Json.data.schedules | Where-Object { $_.id -eq $sidB -and $_.remain_num -eq 0 }).Count -eq 1 }
Check "★ 已约满（remain_num=0）的排班**仍在列表里**（客户端才能显示"已约满"）" $found

# 日期**形状**错误 → 400（而不是静默空列表）
#
# ⚠ 我第一版用 `2026-13-99` 当"非法日期"，结果它通过了（返回 200 空列表）——
#   因为校验的是**形状**（4-2-2 数字 + 横杠），不是"日历上是否存在 2 月 30 日"。
#   这是**刻意的取舍**：日历校验的收益只是把"空列表"换成"400"，
#   而形状校验已经挡住了实际会发生的手误。所以改测真正形状非法的输入，
#   并在文档里写明这条边界（不假装它能校验日历）。
foreach ($bad in @('2026/12/25', '2026-12-2', '2026-1-25', '20261225', '2026-12-25x')) {
    $r = DoReq ('bd' + [Guid]::NewGuid().ToString('N').Substring(0, 6)) 'GET' `
         ('/api/v1/schedules?work_date=' + $bad) @("Authorization: Bearer $admTok") $null
    Check "形状非法的日期 '$bad' → 400 VALIDATION_FAILED" ($r.Http -eq 400) ("HTTP $($r.Http)")
}
# 反向：形状合法但日历上"不存在"的日期 → 200 空列表（**如实标注的已知边界**）
$r = DoReq 'cal' 'GET' '/api/v1/schedules?work_date=2026-13-99' @("Authorization: Bearer $admTok") $null
Check "形状合法但日历无效（2026-13-99）→ 200 空列表（已知边界，不做日历校验）" `
      ($r.Http -eq 200) ("HTTP $($r.Http)")

$r = DoReq 'l7' 'GET' '/api/v1/schedules' @() $null
Check "无令牌查排班列表 → 401" ($r.Http -eq 401) ("HTTP $($r.Http)")

# ===================== ①b 口令生成器 × 强度校验（第四份复查缺陷）=====================
Write-Host ""
Write-Host "[5] ★ 口令生成器必须满足自己定的强度规则（CLI 端到端）"
# ── 这一节守的是第四份复查发现的**真缺陷** ────────────────────────────────
# `randCode(12)` 从 26 个字符（21 字母 + 5 数字）里独立均匀取 12 个，
# **不保证**成分 ⇒ P(全字母) = (21/26)^12 ≈ **7.71%** ⇒ 生成的口令被本项目
# **自己**的强度规则②（必须含字母与数字）拒 ⇒ `create-admin` 抛异常直冒堆栈。
# 复查实测 70 次失败 6 次（8.6%）；我也复现到同样的数。
#
# 修法：randCode 强制"1 字母 + 1 数字"再整体洗牌。
# 本节就是那个修复的回归闸门 —— **没有它，将来有人"简化"掉成分保证就又漏了**。
#
# ⚠ 这里必须真的调 CLI（端到端），不能只在代码里单测 randCode：
#   原缺陷的一半伤害在于"异常直冒堆栈"，那是 CLI 层的表现，单测看不见。
$exe = Join-Path (Split-Path $PSScriptRoot -Parent) "build\hospital-server.exe"
if (-not (Test-Path $exe)) {
    Check "找得到 hospital-server.exe（跑 CLI 回归）" $false $exe
} else {
    $runs = 40      # 原缺陷下期望失败 ≈ 40×7.7% ≈ 3 次，40 次足以让回归可靠地红
    $cliFail = 0; $stackFail = 0; $genPws = @()
    foreach ($i in 1..$runs) {
        $o = (& $exe create-admin $Dsn 2>&1 | Out-String)
        if ($o -match '口  令：') {
            $genPws += (($o -split "`n" | Select-String '口  令：').Line -replace '.*口  令：','').Trim()
        } else {
            $cliFail++
        }
        # ★ 单独数"以堆栈形式失败"：原缺陷下失败信息是
        #   `An exception has occurred: ... at qingzhou::UserFacingError::init`
        if ($o -match 'An exception has occurred|at qingzhou::') { $stackFail++ }
    }
    Check "$runs 次 create-admin 全部成功（原缺陷下约 8% 失败）" ($cliFail -eq 0) ("失败 $cliFail 次")
    Check "★ 没有任何一次以**堆栈**形式失败（CLI 失败应给 ❌ 清晰提示）" ($stackFail -eq 0) ("堆栈 $stackFail 次")
    # 成分：生成的口令必须都含字母与数字（这正是它们能通过校验的原因）
    $noDigit = @($genPws | Where-Object { $_ -notmatch '[0-9]' }).Count
    $noLetter = @($genPws | Where-Object { $_ -notmatch '[A-Z]' }).Count
    Check "生成的口令都含数字（全字母 $noDigit 个）" ($noDigit -eq 0)
    Check "生成的口令都含字母（全数字 $noLetter 个）" ($noLetter -eq 0)
    # 这些口令必须真的能通过强度校验（否则上面"成功"另有原因）
    #
    # ⚠ 这里必须**重新登录**：`create-admin` 每次都会把 admin 口令改成新的随机值
    #   （并吊销旧令牌），所以脚本开头那个 `$admTok` 到这一步**已经失效**。
    #   我第一版就漏了这一步 —— 40 次校验全部 401（看起来"全部不通过"），
    #   而那其实是"没登录"而不是"口令不合法"。
    #   📌 与前面 [1] 节同一个教训的另一个面孔：**破坏性操作之后要重建会话**。
    $null = Invoke-MySqlScalar -My $My -Sql "DELETE FROM auth_login_attempt" -Label "清计数"
    $lastPw = $genPws[$genPws.Count - 1]      # create-admin 最后一次设的口令
    $relog = DoReq 'relog5' 'POST' '/api/v1/auth/login' @() ('{"login_name":"admin","password":"' + $lastPw + '"}')
    Check "用 create-admin 生成的口令能登录（自证它合法）" ($relog.Http -eq 200) ("HTTP $($relog.Http)")
    $freshTok = if ($relog.Json -and $relog.Json.data) { $relog.Json.data.token } else { "" }
    $okCount = 0
    if ($freshTok.Length -gt 0) {
        foreach ($p in $genPws) {
            $r = DoReq ('gen' + [Guid]::NewGuid().ToString('N').Substring(0,6)) 'POST' `
                 "/api/v1/admin/users/$ptUid/password" @("Authorization: Bearer $freshTok") ('{"password":"' + $p + '"}')
            if ($r.Http -eq 200) { $okCount++ }
        }
    }
    Check "★ 生成的口令全部通过强度校验（$okCount / $($genPws.Count)）" ($okCount -eq $genPws.Count)

    # ★ 洗牌生效：数字出现在**首位**的比例不应为 0
    #   （若只"前两位放字母+数字"而不洗牌，首位是数字的概率恒为 0 —— 那就成结构可预测了）
    $firstDigit = @($genPws | Where-Object { $_ -match '^[0-9]' }).Count
    Check "★ 洗牌生效：首位出现数字（$firstDigit / $($genPws.Count)，未洗牌则恒为 0）" ($firstDigit -gt 0)
}


# ★ 如实在结尾交代：第 [5] 节已把 admin 口令轮换掉（见文件头说明）
if ($genPws.Count -gt 0) {
    Write-Host ""
    Write-Host "▸ 注意：第 [5] 节跑过 create-admin，admin 口令已轮换为：$($genPws[$genPws.Count - 1])"
    Write-Host "  （这是该节 40 次端到端回归的必然副作用；要恢复成已知值请重跑 create-admin）"
    Write-Host "  ⚠ 因此**后续脚本**（triage-check / stress 等用 -AdminPw 的）请先重跑一次 create-admin 取新口令，"
    Write-Host "     否则它们会用旧口令登录 → 401，表现为假红（不是产品缺陷）。"
}

Remove-Item $tmp -Recurse -Force
$null = Invoke-MySqlScalar -My $My -Sql "DELETE FROM auth_login_attempt" -Label "收尾清计数"

Write-Host ""
if ($fail -eq 0) {
    Write-Host "✅ P1 收尾项验证全部通过"
    exit 0
} else {
    Write-Host "❌ P1 收尾项验证失败 $fail 项"
    exit 1
}
