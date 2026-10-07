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
    [string]$Dsn = "mysql://hospital:hospital_dev_2026@127.0.0.1:3307/hospital"
)

$ErrorActionPreference = "Stop"

$mysql = "E:\cangjie\mariadb\mariadb-11.4.13-winx64\bin\mariadb.exe"
if (-not (Test-Path $mysql)) { throw "找不到 mariadb 客户端：$mysql" }

if ($ScheduleTotal -le 0) { $ScheduleTotal = $Tokens }

Write-Host "=== 并发挂号压测 ==="
Write-Host "  目标      : $Base"
Write-Host "  并发请求数: $Tokens"
Write-Host "  号源总数  : $ScheduleTotal"
$expectSuccess = [Math]::Min($Tokens, $ScheduleTotal)
Write-Host "  期望成功数: $expectSuccess（= min(请求数, 号源数)）"
Write-Host ""

# ── 1) 准备：清空并造一个干净排班 ──────────────────────────────────────────
Write-Host "[1/4] 准备干净数据…"
$sql = @"
DELETE FROM appointment;
DELETE FROM schedule;
DELETE FROM booking_idem;
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
& $mysql -h 127.0.0.1 -P 3307 -u hospital "-phospital_dev_2026" --skip-ssl hospital -e "source $tmp" | Out-Null
Remove-Item $tmp -Force

# 建排班（走管理员接口，顺带验证写接口）
# ⚠ body 走**文件**而不是 -d 内联：PowerShell 会把内联 JSON 的花括号/引号弄成非法 JSON
#   （实测报 `Invalid JSON body`）。`--data-binary @文件` 最稳。
$createFile = Join-Path $env:TEMP "stress-create.json"
[System.IO.File]::WriteAllText($createFile,
    "{`"doctor_id`":1,`"department_id`":1,`"work_date`":`"2026-11-01`",`"period`":`"AM`",`"total_num`":$ScheduleTotal}",
    (New-Object System.Text.UTF8Encoding($false)))
$createOut = & curl.exe -s -X POST -H "X-Role: admin" -H "Content-Type: application/json" --data-binary "@$createFile" "$Base/api/v1/admin/schedules"
Remove-Item $createFile -Force
Write-Host "  建排班响应: $createOut"
$sid = ($createOut | ConvertFrom-Json).data.schedule_id
if (-not $sid) { throw "建排班失败" }

# ── 2) 并发发起：每个请求一个独立 curl 进程 ─────────────────────────────────
Write-Host ""
Write-Host "[2/4] 并发发起 $Tokens 个挂号请求（各自独立进程/连接）…"
$tmpDir = Join-Path $env:TEMP ("stress-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

$procs = @()
# ⚠ curl config 文件里**反斜杠是转义符**，Windows 路径必须写成正斜杠
#   （实测："@C:\Users\..." 被读成 "C:Users..." → Failed to open）。
#   curl on Windows 接受正斜杠路径，所以这里统一替换。
$tmpDirCurl = $tmpDir -replace '\\', '/'
for ($i = 1; $i -le $Tokens; $i++) {
    # ⚠⚠ 关键坑（实测踩到两次，都记在这里）：
    #   1) `Start-Process -ArgumentList` 会把**含空格**的参数拆坏 ——
    #      "X-Role: patient" 到达 curl 时变成 "X-Role:"，于是每个请求都 401，
    #      看起来像"服务端拒绝并发"，其实是命令行被吃了。
    #   2) PowerShell 的反引号转义在数组拼接里会**原样写入**，不会变成 JSON 的引号，
    #      于是请求体变成 {"schedule_id":1,...} 这种非法串 → 400 Invalid JSON。
    #   处置（两条一起解决）：body 写**独立文件**，config 里用 `data = "@文件"`，
    #   命令行上只剩无空格的路径与 URL。
    $bodyFileWin = Join-Path $tmpDir "$i.body"
    [System.IO.File]::WriteAllText($bodyFileWin,
        '{"schedule_id":' + $sid + ',"client_token":"stress-' + $i + '"}',
        (New-Object System.Text.UTF8Encoding($false)))
    $bodyFileCurl = $bodyFileWin -replace '\\', '/'

    $cfgFile = Join-Path $tmpDir "$i.cfg"
    $cfg = @(
        'request = "POST"'
        'header = "X-Role: patient"'
        'header = "X-Patient-Id: 1"'
        'header = "Content-Type: application/json"'
        ('data = "@' + $bodyFileCurl + '"')
        'silent'
        'write-out = "\n__CODE__%{http_code}"'
    ) -join "`n"
    [System.IO.File]::WriteAllText($cfgFile, $cfg, (New-Object System.Text.UTF8Encoding($false)))

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

# 号源真实余量
$remain = (& $mysql -h 127.0.0.1 -P 3307 -u hospital "-phospital_dev_2026" --skip-ssl hospital -N -B -e "SELECT remain_num FROM schedule WHERE id=$sid").Trim()
$apptCount = (& $mysql -h 127.0.0.1 -P 3307 -u hospital "-phospital_dev_2026" --skip-ssl hospital -N -B -e "SELECT COUNT(*) FROM appointment WHERE schedule_id=$sid AND status<>'cancelled'").Trim()
$total = (& $mysql -h 127.0.0.1 -P 3307 -u hospital "-phospital_dev_2026" --skip-ssl hospital -N -B -e "SELECT total_num FROM schedule WHERE id=$sid").Trim()

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
