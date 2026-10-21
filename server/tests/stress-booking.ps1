# 多进程并发压测同一号源 —— 验证「不超卖」
#
# 为什么必须用**独立进程**而不是线程：本仓库（框架 + 应用）通篇没有 `spawn`，
# 仓颉 1.2.0 的多线程用法在本项目无既有先例可循。而"并发"的真实形态本来就是
# 多个进程打同一个号源 —— 所以这里用 PowerShell 起 N 个 curl.exe 子进程，
# 它们**各自建立独立 HTTP 连接**，打到同一个排班上。
#
# 这正好补上 ADR-0001 中 AC-1 标注的验证边界：
#   AC-1（单元级）证明的是「同一 version 的第二次 UPDATE 必返回 0 行」= 原子性根因；
#   本脚本证明的是「N 个真实并发请求打同一号源，成功数恰好等于号源数」= 端到端不超卖。
#
# ⚠ 含中文的 PowerShell 脚本必须 UTF-8 with BOM（PS 5.1 否则按 ANSI 解析 → 语法报错）。
#
# 用法：
#   .\stress-booking.ps1 -Base http://127.0.0.1:8091 -Tokens 20

param(
    [string]$Base = "http://127.0.0.1:8091",
    [int]$Tokens = 20,
    [int]$ScheduleTotal = 0,     # 0 = 用 Tokens 作为号源数
    [int]$SetupPort = 0,
    # ⚠ 默认指向**仓库自管 devdb**（server\devdb，端口 3317）——
    #   与本机另一台实例（3307）隔离，见 docs\dev\DEV-DB.md。
    [string]$Dsn = "mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital_test",
    [string]$AdminLogin = "admin",
    [string]$AdminPw = "",
    [string]$PatientLogin = "13800000001",
    [string]$PatientPw = "patient-pw-1",
    [switch]$UseDevAuth           # 兼容旧用法；默认走令牌
)

$ErrorActionPreference = "Stop"
if (-not $UseDevAuth -and [string]::IsNullOrEmpty($AdminPw)) {
    throw "默认走**令牌鉴权**，需要 -AdminPw（先跑 hospital-server.exe create-admin <dsn>）。`n  或显式加 -UseDevAuth 用开发态身份头（需服务端 --dev-auth 启动）。"
}

# ★ 连接参数**从 DSN 派生**（唯一事实来源）—— 见 common.ps1 顶部说明：
#   原先 DSN 与 MySql* 是两份独立参数，极易"服务端写 A 库、脚本查 B 库"，
#   实测踩过（断言一直读到空结果，看起来像 SQL 坏了）。
. "$PSScriptRoot\common.ps1"
$My = Get-MySqlClientArgs -Dsn $Dsn
$mysql = $My.Client
if (-not (Test-Path $mysql)) { throw "找不到 mariadb 客户端：$mysql（可用 `$env:HOSP_MYSQL_CLIENT 覆盖）" }

if ($ScheduleTotal -le 0) { $ScheduleTotal = $Tokens }

Write-Host "=== 并发挂号压测 ==="
Write-Host "  目标      : $Base"
Write-Host "  并发请求数: $Tokens"
Write-Host "  号源总数  : $ScheduleTotal"
$expectSuccess = [Math]::Min($Tokens, $ScheduleTotal)
Write-Host "  期望成功数: $expectSuccess（= min(请求数, 号源数)）"
Write-Host ""

# ── 0) 取令牌（默认走真实鉴权路径）────────────────────────────────────────
# ⚠ 并发压测**必须**穿过真实鉴权：否则测的是"开了后门之后"的系统。
#   做法：登录一次拿管理员令牌 + 患者令牌，把两个令牌各写进一个**共享 config 文件**，
#   N 个 worker 都 `-K` 那个文件 —— 这样命令行上不出现令牌（也避开参数含空格被拆的坑）。
$tmpDir = Join-Path $env:TEMP ("stress-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
$tmpDirCurl = $tmpDir -replace '\\', '/'

function WriteCfg($path, $method, $headers, $bodyFile) {
    $lines = @("request = `"$method`"")
    foreach ($h in $headers) { $lines += "header = `"$h`"" }
    if ($bodyFile) {
        $lines += ('data = "@' + $bodyFile + '"')
        $lines += 'header = "Content-Type: application/json"'
    }
    [System.IO.File]::WriteAllText($path, ($lines -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
}

function Login($cfgPath, $login, $pw) {
    $bf = "$tmpDirCurl/login.body"
    [System.IO.File]::WriteAllText(($bf -replace '/', '\'),
        ('{"login_name":"' + $login + '","password":"' + $pw + '"}'),
        (New-Object System.Text.UTF8Encoding($false)))
    WriteCfg $cfgPath 'POST' @() $bf
    # ⚠ 记下原始响应与 HTTP 码：失败时要把「被限流 / 口令错 / 服务没起」分开讲清楚，
    #   而不是只回一个空串让调用方猜（2026-10-16 第三方复查 S3）。
    $out = & curl.exe -s -w "`n__M__%{http_code}" -K $cfgPath "$Base/api/v1/auth/login"
    $raw = ($out | Out-String)
    $code = 0
    if ($raw -match '__M__(\d+)') { $code = [int]$Matches[1] }
    $body = (($raw -replace '(?s)\n?__M__\d+\s*$', '')).Trim()
    $script:lastLogin = [pscustomobject]@{ Http = $code; Body = $body }
    try { return ($body | ConvertFrom-Json).data.token } catch { return "" }
}

$adminCfg = Join-Path $tmpDir 'admin.cfg'
$patCfg = Join-Path $tmpDir 'patient.cfg'
if ($UseDevAuth) {
    Write-Host "[0/4] 鉴权：**开发态身份头**（-UseDevAuth）"
    WriteCfg $adminCfg 'POST' @('X-Role: admin') $null
    WriteCfg $patCfg 'POST' @('X-Role: patient', 'X-Patient-Id: 1') $null
} else {
    Write-Host "[0/4] 鉴权：**Bearer 令牌**"
    $adminTok = Login (Join-Path $tmpDir 'login-admin.cfg') $AdminLogin $AdminPw
    if ([string]::IsNullOrEmpty($adminTok)) {
        if (Test-HospLoginRateLimited -Login $AdminLogin -Resp $script:lastLogin -My $My) {
            $adminTok = Login (Join-Path $tmpDir 'login-admin.cfg') $AdminLogin $AdminPw
        }
        if ([string]::IsNullOrEmpty($adminTok)) { Stop-HospLogin -Login $AdminLogin -Resp $script:lastLogin -My $My -Base $Base -Hint '[提示] 检查 -AdminPw；口令由 create-admin 生成。' }
    }
    $patTok = Login (Join-Path $tmpDir 'login-patient.cfg') $PatientLogin $PatientPw
    if ([string]::IsNullOrEmpty($patTok)) {
        if (Test-HospLoginRateLimited -Login $PatientLogin -Resp $script:lastLogin -My $My) {
            $patTok = Login (Join-Path $tmpDir 'login-patient.cfg') $PatientLogin $PatientPw
        }
        if ([string]::IsNullOrEmpty($patTok)) { Stop-HospLogin -Login $PatientLogin -Resp $script:lastLogin -My $My -Base $Base -Hint '[提示] 口令由 auth-check.ps1 的夹具维护（可先跑它修夹具）。' }
    }
    Write-Host "  管理员令牌 $($adminTok.Length) 字符 ｜ 患者令牌 $($patTok.Length) 字符"
    WriteCfg $adminCfg 'POST' @("Authorization: Bearer $adminTok") $null
    WriteCfg $patCfg 'POST' @("Authorization: Bearer $patTok") $null
}
Write-Host ""

# ── 1) 准备：清空并造一个干净排班 ──────────────────────────────────────────
Write-Host "[1/4] 准备干净数据…"
$sql = @"
DELETE FROM appointment;
DELETE FROM schedule;
-- ⚠ 这里原先还有一行 `DELETE FROM booking_idem;`。
--   该表已于 2026-10-07 连同实现一起删除（死代码，见 ADR-0001 §7 第 7 条），
--   继续 DELETE 它会让整个夹具脚本报错 → 压测在"准备数据"阶段就挂掉。
DELETE FROM doctor;
DELETE FROM department;
DELETE FROM patient;
ALTER TABLE schedule AUTO_INCREMENT = 1;
INSERT INTO department (id,name,code,created_at) VALUES (1,'内科','NK',0);
INSERT INTO doctor (id,name,department_id,title,created_at) VALUES (1,'张明',1,'主任医师',0);
INSERT INTO patient (id,phone,name,created_at) VALUES (1,'13800000001','王小明',0);
"@
$tmp = Join-Path $env:TEMP "stress-setup.sql"
[System.IO.File]::WriteAllText($tmp, $sql, (New-Object System.Text.UTF8Encoding($false)))
Invoke-MySqlFile -My $My -Path $tmp
Remove-Item $tmp -Force

# 建排班（走管理员接口，顺带验证写接口）
# ⚠ body 走**文件**而不是 -d 内联：PowerShell 会把内联 JSON 的花括号/引号弄成非法 JSON
#   （实测报 400 VALIDATION_FAILED，旧版文案是 `Invalid JSON body`）。`--data-binary @文件` 最稳。
$createFile = "$tmpDirCurl/create.body"
[System.IO.File]::WriteAllText(($createFile -replace '/', '\'),
    '{"doctor_id":1,"department_id":1,"work_date":"2026-11-01","period":"AM","total_num":' + $ScheduleTotal + '}',
    (New-Object System.Text.UTF8Encoding($false)))
$createCfg = Join-Path $tmpDir 'create.cfg'
# ⚠ 必须在第 0 步那份**管理员鉴权 config** 上追加 body ——
#   不能另起一个只带 body 的 config，那样会把鉴权头丢掉（实测报 AUTH_REQUIRED）。
$authLines = Get-Content $adminCfg -Encoding UTF8
$cfg = @($authLines) + @(
    ('data = "@' + $createFile + '"')
    'header = "Content-Type: application/json"'
    'silent'
    'write-out = "\n__CODE__%{http_code}"'
)
[System.IO.File]::WriteAllText($createCfg, ($cfg -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
$createOut = & curl.exe -s -K $createCfg "$Base/api/v1/admin/schedules"
Write-Host "  建排班响应: $createOut"
# ⚠ config 里带了 `write-out = "\n__CODE__%{http_code}"`，状态码会附在 body 后面 ——
#   直接 ConvertFrom-Json 会报「无效的 JSON 基元: __CODE__201」。必须先切掉。
$createJson = ($createOut -split "__CODE__")[0].Trim()
$sid = ($createJson | ConvertFrom-Json).data.schedule_id
if (-not $sid) { throw "建排班失败（鉴权是否生效？）" }

# ── 2) 并发发起：每个请求一个独立 curl 进程 ─────────────────────────────────
Write-Host ""
Write-Host "[2/4] 并发发起 $Tokens 个挂号请求（各自独立进程/连接）…"

$procs = @()
for ($i = 1; $i -le $Tokens; $i++) {
    # ⚠⚠ 关键坑（实测踩到两次，都记在这里）：
    #   1) `Start-Process -ArgumentList` 会把**含空格**的参数拆坏 ——
    #      "Authorization: Bearer xxx" 到达 curl 时被拆断，于是每个请求都 401，
    #      看起来像"服务端拒绝并发"，其实是命令行被吃了。
    #   2) PowerShell 的反引号转义在数组拼接里会**原样写入**，不会变成 JSON 的引号，
    #      于是请求体变成 {"schedule_id":1,...} 这种非法串 → 400 Invalid JSON。
    #   处置（两条一起解决）：body 与 header 全部写**文件**，命令行上只剩无空格的路径与 URL。
    $bodyFileWin = Join-Path $tmpDir "$i.body"
    [System.IO.File]::WriteAllText($bodyFileWin,
        '{"schedule_id":' + $sid + ',"client_token":"stress-' + $i + '"}',
        (New-Object System.Text.UTF8Encoding($false)))
    $bodyFileCurl = $bodyFileWin -replace '\\', '/'

    # 复用第 0 步那份**共享**的患者鉴权 config（令牌只在文件里，不落命令行）
    $cfgFile = Join-Path $tmpDir "$i.cfg"
    $authLines = Get-Content $patCfg -Encoding UTF8
    $cfg = @($authLines) + @(
        ('data = "@' + $bodyFileCurl + '"')
        'header = "Content-Type: application/json"'
        'silent'
        'write-out = "\n__CODE__%{http_code}"'
    )
    [System.IO.File]::WriteAllText($cfgFile, ($cfg -join "`n"), (New-Object System.Text.UTF8Encoding($false)))

    $outFile = Join-Path $tmpDir "$i.out"
    $errFile = Join-Path $tmpDir "$i.err"
    $p = Start-Process -FilePath "curl.exe" `
        -ArgumentList @("-K", $cfgFile, "$Base/api/v1/appointments") `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
        -NoNewWindow -PassThru
    $procs += [pscustomobject]@{ Proc = $p; Out = $outFile; Index = $i }
}
Write-Host "  已启动 $($procs.Count) 个进程，等待全部结束…"
foreach ($x in $procs) { $x.Proc.WaitForExit() }
Write-Host "  全部结束"

# ── 3) 统计结果 ────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "[3/4] 统计结果…"
$codes = @{}
$success = 0
$conflict = 0
$other = 0
foreach ($x in $procs) {
    $txt = Get-Content $x.Out -Raw -Encoding UTF8
    $m = [regex]::Match($txt, '__CODE__(\d+)')
    $code = if ($m.Success) { [int]$m.Groups[1].Value } else { -1 }
    if ($codes.ContainsKey($code)) { $codes[$code]++ } else { $codes[$code] = 1 }
    if ($code -eq 201) { $success++ }
    elseif ($code -eq 409) { $conflict++ }
    else { $other++ }
}
Write-Host "  HTTP 状态码分布："
$codes.GetEnumerator() | Sort-Object Name | ForEach-Object { Write-Host "    $($_.Name) -> $($_.Value) 次" }
Remove-Item $tmpDir -Recurse -Force

# ── 4) 断言 ────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "[4/4] 断言"
$fail = 0
function Check($name, $ok) {
    if ($ok) { Write-Host "  [PASS] $name" }
    else { Write-Host "  [FAIL] $name"; $script:fail++ }
}

# 号源真实余量（标量读取统一走 common.ps1 的 Invoke-MySqlScalar）

$remain = Invoke-MySqlScalar -My $My -Sql "SELECT remain_num FROM schedule WHERE id=$sid" -Label "remain_num"
$apptCount = Invoke-MySqlScalar -My $My -Sql "SELECT COUNT(*) FROM appointment WHERE schedule_id=$sid AND status<>'cancelled'" -Label "有效挂号单数"
$total = Invoke-MySqlScalar -My $My -Sql "SELECT total_num FROM schedule WHERE id=$sid" -Label "total_num"

Write-Host "  库中：total_num=$total remain_num=$remain 有效挂号单=$apptCount"
Write-Host ""

# ⚠ 断言必须**区分"供不应求"与"供大于求"**两种工况。
#   实测踩到：本脚本原来无条件断言 "成功数 == 号源总数"、"remain_num 恰为 0"，
#   于是"5 并发抢 20 号"（号源充裕，本来就该剩 15）被误判为 3 项失败 ——
#   **服务端行为是对的，是断言写错了**。测试写错比不写更糟：它会让人去改对的代码。
$exhausted = ($Tokens -ge $ScheduleTotal)

Check "成功数 == 期望（$success == $expectSuccess）" ($success -eq $expectSuccess)
Check "无负余量（$remain >= 0）" ([int]$remain -ge 0)
Check "无 5xx / 无异常码（其它码 $other 个）" ($other -eq 0)
Check "余量守恒：remain_num + 有效挂号单 == total_num（$remain + $apptCount == $total）" `
      (([int]$remain + [int]$apptCount) -eq [int]$total)

if ($exhausted) {
    Write-Host "  工况：供不应求（请求 $Tokens >= 号源 $ScheduleTotal）→ 期望卖光"
    Check "成功数 == 号源总数（$success == $ScheduleTotal）" ($success -eq $ScheduleTotal)
    Check "remain_num 恰为 0（卖光且未变负）" ($remain -eq "0")
    Check "有效挂号单数 == 号源数（$apptCount == $ScheduleTotal）" ("$apptCount" -eq "$ScheduleTotal")
    Check "冲突按 409 返回（$conflict 个）" ($conflict -eq ($Tokens - $ScheduleTotal))
} else {
    Write-Host "  工况：供大于求（请求 $Tokens < 号源 $ScheduleTotal）→ 期望全成功、余量正确"
    Check "成功数 == 请求数（$success == $Tokens）" ($success -eq $Tokens)
    Check "remain_num == total_num - 成功数（$remain == $($ScheduleTotal - $success)）" `
          ([int]$remain -eq ($ScheduleTotal - $success))
    Check "无 409（供大于求不该有冲突，实际 $conflict 个）" ($conflict -eq 0)
}

Write-Host ""
if ($fail -eq 0) {
    Write-Host "✅ 并发压测全部通过 —— 号源未被超卖"
    exit 0
} else {
    Write-Host "❌ 并发压测失败 $fail 项"
    exit 1
}
