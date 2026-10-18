# ===== visit-timeline-check.ps1 —— 改进 6「就诊时间线」服务端端到端验证 =====
#
# 覆盖：
#   [1] 鉴权与归属（无令牌 401 / 患者 403 FORBIDDEN_ROLE / 他人单 404 不给枚举 oracle / id=0 400）
#   [2] 接诊队列（已退号不进队列 / 队列顺序确定 / 状态中文名与三个时间戳同源）
#   [3] ★★ 时间线全链：booked → arrived → waiting → visiting → done，
#       每一步都**落到库里的时间戳**上（等待时长 / 就诊时长真的能算出来）
#   [4] ★★ 不能跳步、不能重复、不能回退（重复到院 409、未到院就接诊 409、
#       病历没锁定不许完成就诊、完成后再到院 409）
#   [5] ★ 爽约的两个现实形态：挂了号没来（booked）与来了没被叫到（arrived）
#   [6] 夹具自清 + 残留自检
#
# 用法：powershell -File .\visit-timeline-check.ps1 -AdminPw <create-admin 打印的口令>
# ⚠ 与 `hospital-server.exe accept` **串行**跑（accept 会清业务表）。
# ⚠ 必须 UTF-8 **with BOM**（PS 5.1 否则按 ANSI 解析中文 ⇒ 语法报错）。
#   `edit`/`write` 工具重写文件会**丢掉 BOM**，改完必须补回并复验语法。
# ⚠ 夹具 id 段：**707xxx**（703/704/705/706/700 已被其它脚本占用）。

param(
    [string]$Base = "http://127.0.0.1:18096",
    [Parameter(Mandatory=$true)][string]$AdminPw,
    [string]$Dsn = "mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital_test"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$My = Get-MySqlClientArgs -Dsn $Dsn
$passed = 0
$failed = 0
function Check($name, $cond, $detail) {
    if ($cond) { Write-Host "  [PASS] $name" -ForegroundColor Green; $script:passed++ }
    else { Write-Host "  [FAIL] $name" -ForegroundColor Red; $script:failed++ }
    if ($detail) { Write-Host "         $detail" -ForegroundColor DarkGray }
}

# ⚠ 用 curl 配置文件发请求（不用 -d '...'：PowerShell 会破坏 JSON 引号）
function Req($tag, $method, $path, $headers, $jsonBody) {
    $cfg = Join-Path $env:TEMP ("vtl_" + $tag + ".cfg")
    $lines = @("request = `"$method`"", "silent", "write-out = `"\n__M__%{http_code}`"")
    foreach ($h in $headers) { $lines += "header = `"$h`"" }
    if ($null -ne $jsonBody) {
        $bf = Join-Path $env:TEMP ("vtl_" + $tag + ".json")
        [System.IO.File]::WriteAllText($bf, $jsonBody, (New-Object System.Text.UTF8Encoding($false)))
        $lines += "header = `"Content-Type: application/json`""
        $lines += "data = `"@" + ($bf -replace '\\','/') + "`""
    }
    [System.IO.File]::WriteAllText($cfg, ($lines -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
    $raw = (& curl.exe -s -K $cfg "$Base$path" 2>&1) -join "`n"
    $code = 0
    if ($raw -match '__M__(\d+)') { $code = [int]$Matches[1] }
    $body = ($raw -replace '(?s)\n?__M__\d+\s*$', '')
    $obj = $null
    try { $obj = $body | ConvertFrom-Json } catch { }
    return [pscustomobject]@{ Http = $code; Body = $body; Json = $obj }
}
function Tok($login, $pw) {
    $r = Req ("lg" + $login) 'POST' '/api/v1/auth/login' @() ('{"login_name":"' + $login + '","password":"' + $pw + '"}')
    if ($r.Http -ne 200) {
        # 限流是服务端的正常保护：能清就清掉计数再重试一次，然后才谈失败
        if (Test-HospLoginRateLimited -Login $login -Resp $r -My $My) {
            $r = Req ("lg2" + $login) 'POST' '/api/v1/auth/login' @() ('{"login_name":"' + $login + '","password":"' + $pw + '"}')
        }
        if ($r.Http -ne 200) { Stop-HospLogin -Login $login -Resp $r -My $My -Base $Base }
    }
    return ($r.Body | ConvertFrom-Json).data.token
}
function SqlFile($name, $sql) {
    $p = Join-Path $env:TEMP ("vtl_" + $name + ".sql")
    [System.IO.File]::WriteAllText($p, $sql, (New-Object System.Text.UTF8Encoding($false)))
    Invoke-MySqlFile -My $My -Path ($p -replace '\\','/')
}
function RowCount($label, $sql) {
    return ("$(Invoke-MySqlScalar -My $My -Label $label -Sql $sql)").Trim()
}
# 库里该单的字段（回读真值 —— 只信响应等于只信实现的自述）
function ApptCol($id, $col) {
    return ("$(Invoke-MySqlScalar -My $My -Label "读 $col" -Sql "SELECT $col FROM appointment WHERE id = $id")").Trim()
}
function EnsureAccount($tag, $login, $pw, $role, $refId, $display) {
    $body = '{"login_name":"' + $login + '","password":"' + $pw + '","role":"' + $role + '"' +
            ',"ref_id":' + $refId + ',"display_name":"' + $display + '"}'
    $r = Req ("mk" + $tag) 'POST' '/api/v1/admin/users' @("Authorization: Bearer $admTok") $body
    $uid = 0
    if ($r.Http -eq 201) {
        $uid = ($r.Body | ConvertFrom-Json).data.user_id
    } elseif ($r.Http -eq 409) {
        $q = Req ("find" + $tag) 'GET' ('/api/v1/admin/users?login_name=' + $login) @("Authorization: Bearer $admTok") $null
        if ($q.Http -eq 200) { $uid = ($q.Body | ConvertFrom-Json).data.user_id }
    }
    if ($uid -gt 0) {
        $null = Req ("pw" + $tag) 'POST' ('/api/v1/admin/users/' + $uid + '/password') `
                @("Authorization: Bearer $admTok") ('{"password":"' + $pw + '"}')
    }
    return [pscustomobject]@{ Http = $r.Http; UserId = $uid }
}
# 队列里某些单的 id 序列（按响应顺序，逗号分隔字符串）
function QueueIds($resp) {
    if ($null -eq $resp.Json -or $null -eq $resp.Json.data) { return "" }
    return (@($resp.Json.data.items | ForEach-Object { [int]$_.appointment_id }) -join ',')
}

Write-Host ""
Write-Host "=== 改进 6 就诊时间线 端到端验证 ===" -ForegroundColor Cyan
Write-Host "  目标: $Base"
Write-Host "  库  : $($My.Db)@$($My.DbHost):$($My.Port)"

# ── [0] 夹具（直接写库，精确控制前置状态）────────────────────────────────
Write-Host ""
Write-Host "[0] 准备夹具"
$null = Invoke-MySqlScalar -My $My -Label "清病历" -Sql "DELETE FROM medical_record WHERE appointment_id >= 707000"
$null = Invoke-MySqlScalar -My $My -Label "清挂号" -Sql "DELETE FROM appointment WHERE id >= 707000"
$null = Invoke-MySqlScalar -My $My -Label "清排班" -Sql "DELETE FROM schedule WHERE id >= 707000"
$null = Invoke-MySqlScalar -My $My -Label "清医生" -Sql "DELETE FROM doctor WHERE id >= 707000"
$null = Invoke-MySqlScalar -My $My -Label "清科室" -Sql "DELETE FROM department WHERE id >= 707000"
$null = Invoke-MySqlScalar -My $My -Label "清患者" -Sql "DELETE FROM patient WHERE id >= 707000"
# ★ 2026-10-18：就诊日期门槛（server/src/http_p4.cj 的 p4RequireVisitNotFuture）拦的是
#   **未来**就诊日，所以主夹具用「今天」，另造一张 7 天后的号专门验拦截。
$vtlToday = (Get-Date).ToString('yyyy-MM-dd')
$vtlFuture = (Get-Date).AddDays(7).ToString('yyyy-MM-dd')
$seedSql = @"
INSERT INTO department (id, name, code, created_at) VALUES (707001, '改进6验证科', 'VT6', 0);
INSERT INTO doctor (id, name, department_id, title, specialty, created_at) VALUES (707001, '改进6医生甲', 707001, '主任医师', '测试', 0);
INSERT INTO doctor (id, name, department_id, title, specialty, created_at) VALUES (707002, '改进6医生乙', 707001, '住院医师', '测试', 0);
INSERT INTO schedule (id, doctor_id, department_id, work_date, period, total_num, remain_num, version, enabled, created_at) VALUES (707001, 707001, 707001, '$vtlToday', 'AM', 20, 20, 0, 1, 0);
INSERT INTO patient (id, phone, name, gender, birth_date, created_at) VALUES (707001, '13800070701', '改进6患者甲', 'M', '1990-01-01', 0);
INSERT INTO appointment (id, schedule_id, patient_id, doctor_id, department_id, visit_date, period, seq_no, status, slot_restored, created_at) VALUES (707004, 707001, 707001, 707001, 707001, '$vtlToday', 'AM', 1, 'booked', 0, 0);
INSERT INTO appointment (id, schedule_id, patient_id, doctor_id, department_id, visit_date, period, seq_no, status, slot_restored, created_at) VALUES (707005, 707001, 707001, 707001, 707001, '$vtlToday', 'AM', 2, 'booked', 0, 0);
INSERT INTO appointment (id, schedule_id, patient_id, doctor_id, department_id, visit_date, period, seq_no, status, slot_restored, created_at) VALUES (707006, 707001, 707001, 707001, 707001, '$vtlToday', 'AM', 3, 'booked', 0, 0);
INSERT INTO appointment (id, schedule_id, patient_id, doctor_id, department_id, visit_date, period, seq_no, status, slot_restored, created_at) VALUES (707007, 707001, 707001, 707002, 707001, '$vtlToday', 'AM', 4, 'booked', 0, 0);
INSERT INTO appointment (id, schedule_id, patient_id, doctor_id, department_id, visit_date, period, seq_no, status, slot_restored, created_at) VALUES (707008, 707001, 707001, 707001, 707001, '$vtlToday', 'AM', 5, 'cancelled', 1, 0);
INSERT INTO appointment (id, schedule_id, patient_id, doctor_id, department_id, visit_date, period, seq_no, status, slot_restored, created_at) VALUES (707009, 707001, 707001, 707001, 707001, '$vtlToday', 'AM', 6, 'booked', 0, 0);
INSERT INTO appointment (id, schedule_id, patient_id, doctor_id, department_id, visit_date, period, seq_no, status, slot_restored, created_at) VALUES (707010, 707001, 707001, 707001, 707001, '$vtlFuture', 'AM', 7, 'cancelled', 1, 0);
"@
SqlFile "vtl_seed" $seedSql
Check "① 夹具就位：预约 7 张（booked 6 / cancelled 1；含 1 张 7 天后的号用于验日期门槛）" ((RowCount "数夹具" "SELECT COUNT(*) FROM appointment WHERE id >= 707000") -eq '7') `
      "count=$(RowCount '数夹具' 'SELECT COUNT(*) FROM appointment WHERE id >= 707000')"

$admTok = Tok "admin" $AdminPw
$a1 = EnsureAccount "vtldoc"  "vtl-doc"  "Vt1pass9" "doctor"  707001 "改进6医生甲"
$a2 = EnsureAccount "vtldoc2" "vtl-doc2" "Vt2pass9" "doctor"  707002 "改进6医生乙"
$a3 = EnsureAccount "vtlpat"  "vtl-pat"  "Vt3pass9" "patient" 707001 "改进6患者甲"
Check "① 三个账号都建好（user_id > 0）" ($a1.UserId -gt 0 -and $a2.UserId -gt 0 -and $a3.UserId -gt 0) `
      "doc=$($a1.UserId) doc2=$($a2.UserId) pat=$($a3.UserId) http=$($a1.Http)/$($a2.Http)/$($a3.Http)"
$docTok  = Tok "vtl-doc"  "Vt1pass9"
$doc2Tok = Tok "vtl-doc2" "Vt2pass9"
$patTok  = Tok "vtl-pat"  "Vt3pass9"
$DH  = @("Authorization: Bearer $docTok")
$D2H = @("Authorization: Bearer $doc2Tok")
$PH  = @("Authorization: Bearer $patTok")

# ── [1] 鉴权与归属 ──────────────────────────────────────────────────────
Write-Host ""
Write-Host "[1] 鉴权与归属"
$r = Req "v0" 'POST' '/api/v1/doctor/visits/707005/arrive' @() $null
Check "★★ ① 无令牌 ⇒ 401（不是 404：先鉴权再谈归属）" ($r.Http -eq 401) "HTTP $($r.Http)"
$r = Req "v1" 'POST' '/api/v1/doctor/visits/707005/arrive' $PH $null
Check "★ ① 患者令牌 ⇒ 403 FORBIDDEN_ROLE（患者不能替自己登记到院）" ($r.Http -eq 403 -and $r.Json.error.code -eq 'FORBIDDEN_ROLE') `
      "HTTP $($r.Http) code=$($r.Json.error.code)"
$r = Req "v2" 'POST' '/api/v1/doctor/visits/707007/arrive' $DH $null
Check "★★ ① 医生乙的单，医生甲来登记 ⇒ 404（不是 403：403 会变成「这张单存在吗」的枚举 oracle）" `
      ($r.Http -eq 404 -and $r.Json.error.code -eq 'APPOINTMENT_NOT_FOUND') "HTTP $($r.Http) code=$($r.Json.error.code)"
$r = Req "v3" 'POST' '/api/v1/doctor/visits/0/arrive' $DH $null
Check "① id=0 ⇒ 400 VALIDATION_FAILED" ($r.Http -eq 400 -and $r.Json.error.code -eq 'VALIDATION_FAILED') `
      "HTTP $($r.Http) code=$($r.Json.error.code)"
$r = Req "v4" 'POST' '/api/v1/doctor/visits/707999/arrive' $DH $null
Check "★★ ① 不存在的单 ⇒ **同一个** 404（与「别人的单」不可区分）" `
      ($r.Http -eq 404 -and $r.Json.error.code -eq 'APPOINTMENT_NOT_FOUND') "HTTP $($r.Http)"

# ── [2] 接诊队列 ────────────────────────────────────────────────────────
Write-Host ""
Write-Host "[2] 接诊队列 GET /api/v1/doctor/visits"
$r = Req "q1" 'GET' '/api/v1/doctor/visits' $DH $null
Check "② 队列 200" ($r.Http -eq 200) "HTTP $($r.Http)"
Check "★ ② 已退号（707008）不在队列里" ((QueueIds $r) -notmatch '707008') "ids=$(QueueIds $r)"
Check "★ ② 别人的单（707007）不在我的队列里" ((QueueIds $r) -notmatch '707007') "ids=$(QueueIds $r)"
Check "★★ ② 同为 booked 时按 seq_no 排（707004 → 707005 → 707006 → 707009）" `
      ((QueueIds $r) -eq '707004,707005,707006,707009') "ids=$(QueueIds $r)"
$i0 = @($r.Json.data.items)[0]
Check "★ ② 每行带状态中文名（界面不必自己抄中文表；标签与状态常量同处定义）" `
      ($i0.status -eq 'booked' -and $i0.status_label -eq '已挂号') `
      "status=$($i0.status) label=$($i0.status_label)"
Check "★★ ② 每行带三个时间戳（未发生 ⇒ 0，不是 -1/缺字段）" `
      ($i0.arrived_at -eq 0 -and $i0.started_at -eq 0 -and $i0.finished_at -eq 0) `
      "arrived=$($i0.arrived_at) started=$($i0.started_at) finished=$($i0.finished_at)"
Check "② doctor_id 只从令牌派生（回显的是我）" ($r.Json.data.doctor_id -eq 707001) "doctor_id=$($r.Json.data.doctor_id)"

# ── [3] 时间线全链 ──────────────────────────────────────────────────────
Write-Host ""
Write-Host "[3] 时间线全链（707005：到院 → 候诊 → 接诊 → 完成）"
$r = Req "t1" 'POST' '/api/v1/doctor/visits/707005/arrive' $DH $null
$arrivedAt = [int]$r.Json.data.arrived_at
Check "★★ ③ 到院登记 ⇒ 200 + status=arrived + arrived_at 落库（响应回读）" `
      ($r.Http -eq 200 -and $r.Json.data.status -eq 'arrived' -and $arrivedAt -gt 0) `
      "HTTP $($r.Http) status=$($r.Json.data.status) arrived_at=$arrivedAt"
Check "★★ ③ 且**库里**真的写进去了（不信响应自述）" ((ApptCol 707005 'arrived_at') -eq "$arrivedAt") `
      "db=$(ApptCol 707005 'arrived_at') resp=$arrivedAt"
Check "③ 此刻 started_at/finished_at 仍是 0（只写这一步的时间戳）" `
      ((ApptCol 707005 'started_at') -eq '0' -and (ApptCol 707005 'finished_at') -eq '0')
$r = Req "t2" 'POST' '/api/v1/doctor/visits/707005/waiting' $DH $null
Check "★★ ③ 进入候诊 ⇒ 200 + status=waiting（没有独立时间戳列：等待区间用 arrived_at→started_at 表达）" `
      ($r.Http -eq 200 -and $r.Json.data.status -eq 'waiting' -and $r.Json.data.status_label -eq '候诊中') `
      "HTTP $($r.Http) status=$($r.Json.data.status)"
<#
  ★★ 本改进的**带头特性**必须在 HTTP 层被断言（2026-10-16 复核 D7）：
    此前两次取队列分别是"全 booked"与"done + no_show" —— 那时按 seq_no 排
    与按状态优先级排**结果相同**，于是"到院/候诊优先"这条从未真正被验证过
    （把排序改回纯 seq_no 也照样绿）。
    这里刻意造成"混合状态且序号逆序"的局面：707005（waiting，seq_no=2）必须
    排在 707004（booked，seq_no=1）**前面** —— 只有状态优先级的实现才会这样。
#>
$r = Req "t2q" 'GET' '/api/v1/doctor/visits' $DH $null
Check "★★ ③ 混合状态下候诊的 707005（seq_no=2）排在 booked 的 707004（seq_no=1）之前（到院/候诊优先）" `
      ((QueueIds $r) -eq '707005,707004,707006,707009') "ids=$(QueueIds $r)"
$r = Req "t3" 'POST' '/api/v1/doctor/visits/707005/start' $DH $null
$startedAt = [int]$r.Json.data.started_at
Check "★★ ③ 开始接诊 ⇒ 200 + status=visiting + started_at 落库" `
      ($r.Http -eq 200 -and $r.Json.data.status -eq 'visiting' -and $startedAt -gt 0) `
      "HTTP $($r.Http) status=$($r.Json.data.status) started_at=$startedAt"
Check "★★ ③ 等待时长 = started_at - arrived_at = $($startedAt - $arrivedAt) 秒 —— 时间线真的能回答「等了多久」" `
      (($startedAt - $arrivedAt) -ge 0)
$r = Req "t4" 'POST' '/api/v1/doctor/visits/707005/finish' $DH $null
Check "★★ ③ 病历未锁定 ⇒ 完成就诊被拒 409 EMR_NOT_LOCKED" `
      ($r.Http -eq 409 -and $r.Json.error.code -eq 'EMR_NOT_LOCKED') "HTTP $($r.Http) code=$($r.Json.error.code)"
Check "★★ ③ 且被拒时 finished_at **仍是 0**（不写半个时间戳）" ((ApptCol 707005 'finished_at') -eq '0') `
      "db=$(ApptCol 707005 'finished_at')"
$full = '{"chief_complaint":"发热咳嗽 2 天","present_illness":"2 天前受凉后发热，最高 38.5 度，伴咳嗽","past_history":"无","allergy_history":"无","physical_exam":"咽部充血","diagnosis":"急性上呼吸道感染","treatment":"对症退热，多饮水，3 天后复诊"}'
$r = Req "t5" 'PUT' '/api/v1/doctor/visits/707005/record' $DH $full
Check "③ 先存病历草稿 ⇒ 200" ($r.Http -eq 200) "HTTP $($r.Http)"
$r = Req "t6" 'POST' '/api/v1/doctor/visits/707005/record/lock' $DH $null
Check "③ 提交锁定 ⇒ 200" ($r.Http -eq 200) "HTTP $($r.Http)"
$r = Req "t7" 'POST' '/api/v1/doctor/visits/707005/finish' $DH $null
$finishedAt = [int]$r.Json.data.finished_at
Check "★★ ③ 锁定后完成就诊 ⇒ 200 + status=done + finished_at 落库（医生收工那一刻）" `
      ($r.Http -eq 200 -and $r.Json.data.status -eq 'done' -and $finishedAt -gt 0) `
      "HTTP $($r.Http) status=$($r.Json.data.status) finished_at=$finishedAt"
Check "★★ ③ 就诊时长 = finished_at - started_at = $($finishedAt - $startedAt) 秒" (($finishedAt - $startedAt) -ge 0)
Check "★★ ③ 时间线单调：arrived_at <= started_at <= finished_at" `
      ($arrivedAt -le $startedAt -and $startedAt -le $finishedAt) "arrived=$arrivedAt started=$startedAt finished=$finishedAt"

# ── [4] 不能跳步 / 不能重复 / 不能回退 ──────────────────────────────────
Write-Host ""
Write-Host "[4] 状态机闸门"
$r = Req "g1" 'POST' '/api/v1/doctor/visits/707005/arrive' $DH $null
Check "★★ ④ 已完成的单再次到院 ⇒ 409 VISIT_BAD_STATE（终态不可回退）" `
      ($r.Http -eq 409 -and $r.Json.error.code -eq 'VISIT_BAD_STATE') "HTTP $($r.Http) code=$($r.Json.error.code)"
$r = Req "g2" 'POST' '/api/v1/doctor/visits/707004/start' $DH $null
Check "★★ ④ 未到院就直接接诊 ⇒ 409（不能跳步：否则「等了多久」没有起点）" `
      ($r.Http -eq 409 -and $r.Json.error.code -eq 'VISIT_BAD_STATE') "HTTP $($r.Http)"
$r = Req "g3" 'POST' '/api/v1/doctor/visits/707004/waiting' $DH $null
Check "★★ ④ 未到院就进候诊 ⇒ 409（到院是候诊的前置）" `
      ($r.Http -eq 409 -and $r.Json.error.code -eq 'VISIT_BAD_STATE') "HTTP $($r.Http)"
$r = Req "g4" 'POST' '/api/v1/doctor/visits/707009/arrive' $DH $null
Check "④ 到院 707009 ⇒ 200（为下面两个闸门造 arrived 状态）" ($r.Http -eq 200) "HTTP $($r.Http)"
$r = Req "g5" 'POST' '/api/v1/doctor/visits/707009/arrive' $DH $null
Check "★★ ④ 重复到院（已 arrived）⇒ 409（不静默成功：静默会让界面以为刚那一下生效了）" `
      ($r.Http -eq 409 -and $r.Json.error.code -eq 'VISIT_BAD_STATE') "HTTP $($r.Http)"
$r = Req "g6" 'POST' '/api/v1/doctor/visits/707009/start' $DH $null
Check "★★ ④ 已到院但未候诊就接诊 ⇒ 409（必须先被叫号）" `
      ($r.Http -eq 409 -and $r.Json.error.code -eq 'VISIT_BAD_STATE') "HTTP $($r.Http)"

# ── [5] 爽约的两个现实形态 + 退号 ───────────────────────────────────────
Write-Host ""
Write-Host "[5] 爽约与退号"
$r = Req "n1" 'POST' '/api/v1/doctor/visits/707006/no-show' $DH $null
Check "★★ ⑤ 挂了号没来（booked）⇒ 可标记爽约（否则这类单无路可走）" `
      ($r.Http -eq 200 -and $r.Json.data.status -eq 'no_show' -and $r.Json.data.status_label -eq '已爽约') `
      "HTTP $($r.Http) status=$($r.Json.data.status) label=$($r.Json.data.status_label)"
$r = Req "n2" 'POST' '/api/v1/doctor/visits/707009/no-show' $DH $null
Check "★★ ⑤ 来了没被叫到（arrived，改进 6 新增的可爽约状态）⇒ 200" `
      ($r.Http -eq 200 -and $r.Json.data.status -eq 'no_show') "HTTP $($r.Http) status=$($r.Json.data.status)"
$r = Req "n3" 'POST' '/api/v1/doctor/visits/707009/waiting' $DH $null
Check "★★ ⑤ 已爽约的单再进候诊 ⇒ 409（终态不可回退）" `
      ($r.Http -eq 409 -and $r.Json.error.code -eq 'VISIT_BAD_STATE') "HTTP $($r.Http)"
$r = Req "n4" 'POST' '/api/v1/doctor/visits/707008/arrive' $DH $null
Check "★★ ⑤ 已退号的单，医生到院登记 ⇒ 409（退号不是「到院前」状态）" `
      ($r.Http -eq 409 -and $r.Json.error.code -eq 'VISIT_BAD_STATE') "HTTP $($r.Http) code=$($r.Json.error.code)"
Check "★ ⑤ 且退号单的时间戳全为 0（退号不写就诊时间线）" `
      ((ApptCol 707008 'arrived_at') -eq '0' -and (ApptCol 707008 'started_at') -eq '0' -and (ApptCol 707008 'finished_at') -eq '0')

<#
  ★★ 退号闸门的两半都要测（2026-10-16 复核 D6）：
    原用例名叫「患者退掉**只到院**的单 707004 ⇒ 200」，可夹具里的 707004 全程是
    booked —— 它测的其实是**未到院**的单可退，而"已到院的单能不能退"这条
    （改进 6 的刻意设计：到院后号源已消耗 ⇒ 不许退）**一次都没被验证**，
    用例名却宣称验过了。措辞与被测行为不符，是"假绿"最容易藏身的地方。
    ⇒ 拆成两条：① 已到院 ⇒ 409（并核库状态没变）；② 未到院 ⇒ 200。
#>
$r = Req "n5" 'POST' '/api/v1/doctor/visits/707004/arrive' $DH $null
Check "★ ⑤ 先把 707004 登记到院（为验证「已到院的单不能退」造前置状态）" ($r.Http -eq 200) "HTTP $($r.Http)"
$r = Req "n6" 'POST' '/api/v1/appointments/707004/cancel' $PH $null
<#
  ⚠ 期望的是 **APPOINTMENT_NOT_CANCELLABLE**，不是 `VISIT_BAD_STATE`（2026-10-16 实测改正）：
    退号走的是患者端点 `POST /api/v1/appointments/:id/cancel`，它把"单存在但不能退"
    映射成这个**既有**业务码；`VISIT_BAD_STATE` 专属于医生侧流转端点
    （arrive / waiting / start / finish / no-show）。两个码分工不同、不能互换 ——
    断言写错码会让脚本在"服务端其实是对的"时报红，比不写还坏。
    另外：PowerShell 没有 C 风格的斜杠星号注释（写成那样会被当成命令执行、
    脚本静默中断）；块注释用小于号井号开头、井号大于号结尾，而且**不能嵌套** ——
    所以注释正文里也不要写出这两个标记，否则注释会提前结束、后面的中文被当成命令。
#>
Check "★★ ⑤ 患者退掉**已到院**的 707004 ⇒ 409 APPOINTMENT_NOT_CANCELLABLE（退号仍只允许 booked；到院后号源已消耗，走人工/管理员）" `
      ($r.Http -eq 409 -and $r.Json.error.code -eq 'APPOINTMENT_NOT_CANCELLABLE') "HTTP $($r.Http) code=$($r.Json.error.code)"
Check "★★ ⑤ 且被拒后库里状态**仍是 arrived**（不是「拒了但写进去了」）" ((ApptCol 707004 'status') -eq 'arrived') `
      "status=$(ApptCol 707004 'status')"
$r = Req "n7" 'POST' '/api/v1/appointments/707007/cancel' $PH $null
Check "★★ ⑤ 患者退掉**未到院**的 707007 ⇒ 200（退号仍只允许 booked）" ($r.Http -eq 200) `
      "HTTP $($r.Http) $($r.Body.Substring(0, [Math]::Min(120, $r.Body.Length)))"
Check "★ ⑤ 且库里状态变成 cancelled" ((ApptCol 707007 'status') -eq 'cancelled') "status=$(ApptCol 707007 'status')"
$r = Req "cq" 'GET' '/api/v1/doctor/visits' $DH $null
Check "★★ ⑤ 最终队列顺序：arrived 707004 最前 → done 707005 → 两个 no_show 按 seq_no（707006 → 707009），已退号一律不在" `
      ((QueueIds $r) -eq '707004,707005,707006,707009') "ids=$(QueueIds $r)"
Check "★ ⑤ 已退号的 707008 与别人的单 707007 都不在队列里" `
      (((QueueIds $r) -notmatch '707008') -and ((QueueIds $r) -notmatch '707007')) "ids=$(QueueIds $r)"

# ── [5b] ★ 就诊日期门槛（2026-10-18 补）────────────────────────────────
Write-Host ""
Write-Host "[5b] 就诊日期门槛：未来日期的号不能进接诊流程"
# 707010 = 7 天后的号（$vtlFuture）。客户端侧有日期守卫，但客户端可以被绕过，
# 所以服务端必须自己拦 —— 这一段断的就是"绕过客户端直接打接口"这条路。
# 夹具里 707010 先置 cancelled（免得干扰上面的队列顺序断言）；这里翻成 booked，
# 因为"日期门槛"要拦的正是**能到院**的那张单。
$null = Invoke-MySqlScalar -My $My -Label "启用未来号" -Sql "UPDATE appointment SET status = 'booked', slot_restored = 0, arrived_at = 0 WHERE id = 707010"
$r = Req "f1" 'POST' '/api/v1/doctor/visits/707010/arrive' $DH $null
Check "★★ 就诊日期门槛：7 天后的号「确认到院」⇒ 409 VISIT_DATE_FUTURE" `
      ($r.Http -eq 409 -and $r.Json.error.code -eq 'VISIT_DATE_FUTURE') `
      "HTTP $($r.Http) code=$($r.Json.error.code)"
Check "★★ 且错误信息里带了就诊日与今天（能让人一眼看懂为什么被拒）" `
      (("$($r.Json.error.message)" -match $vtlFuture) -and ("$($r.Json.error.message)" -match $vtlToday)) `
      "msg=$($r.Json.error.message)"
Check "★★ 且库里这张单**没有被写脏**（status 仍 booked、arrived_at 仍 0）" `
      (((ApptCol 707010 'status') -eq 'booked') -and ((ApptCol 707010 'arrived_at') -eq '0')) `
      "status=$(ApptCol 707010 'status') arrived_at=$(ApptCol 707010 'arrived_at')"
$r = Req "f2" 'POST' '/api/v1/doctor/visits/707010/waiting' $DH $null
Check "★★ 就诊日期门槛：未来号「进入候诊」同样被拒（409 VISIT_DATE_FUTURE）" `
      ($r.Http -eq 409 -and $r.Json.error.code -eq 'VISIT_DATE_FUTURE') `
      "HTTP $($r.Http) code=$($r.Json.error.code)"
$r = Req "f3" 'POST' '/api/v1/doctor/visits/707010/start' $DH $null
Check "★★ 就诊日期门槛：未来号「开始接诊」同样被拒（409 VISIT_DATE_FUTURE）" `
      ($r.Http -eq 409 -and $r.Json.error.code -eq 'VISIT_DATE_FUTURE') `
      "HTTP $($r.Http) code=$($r.Json.error.code)"
Check "★★ 三次被拒后状态仍是 booked（一条 UPDATE 都没执行成功）" `
      ((ApptCol 707010 'status') -eq 'booked') "status=$(ApptCol 707010 'status')"
# 让这张单不再参与下面的队列顺序断言（它此刻是 booked，会排进队列）
$null = Invoke-MySqlScalar -My $My -Label "收尾未来号" -Sql "UPDATE appointment SET status = 'cancelled', slot_restored = 1 WHERE id = 707010"
# ── [6] 夹具自清 ────────────────────────────────────────────────────────
Write-Host ""
Write-Host "[6] 夹具自清"
$null = Invoke-MySqlScalar -My $My -Label "清病历" -Sql "DELETE FROM medical_record WHERE appointment_id >= 707000"
$null = Invoke-MySqlScalar -My $My -Label "清挂号" -Sql "DELETE FROM appointment WHERE id >= 707000"
$null = Invoke-MySqlScalar -My $My -Label "清排班" -Sql "DELETE FROM schedule WHERE id >= 707000"
$null = Invoke-MySqlScalar -My $My -Label "清医生" -Sql "DELETE FROM doctor WHERE id >= 707000"
$null = Invoke-MySqlScalar -My $My -Label "清科室" -Sql "DELETE FROM department WHERE id >= 707000"
$null = Invoke-MySqlScalar -My $My -Label "清患者" -Sql "DELETE FROM patient WHERE id >= 707000"
$null = Invoke-MySqlScalar -My $My -Label "清账号" -Sql "DELETE FROM auth_user WHERE login_name LIKE 'vtl-%'"
$left = RowCount "查残留" "SELECT (SELECT COUNT(*) FROM appointment WHERE id >= 707000) + (SELECT COUNT(*) FROM doctor WHERE id >= 707000) + (SELECT COUNT(*) FROM auth_user WHERE login_name LIKE 'vtl-%')"
Check "★★ ⑤ 结尾自检：本次夹具残留为 0" ($left -eq '0') "left=$left"

Write-Host ""
if ($failed -eq 0) {
    Write-Host "✅ 就诊时间线端到端验证全部通过（$passed 项）" -ForegroundColor Green
    exit 0
} else {
    Write-Host "❌ 就诊时间线端到端验证失败 $failed 项（通过 $passed 项）" -ForegroundColor Red
    exit 1
}
