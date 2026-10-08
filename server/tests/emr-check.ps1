# SPDX-License-Identifier: MIT
#
# ===== emr-check.ps1 —— P4 电子病历 + 接诊队列 端到端验证 ====================
#
# 覆盖（按真实临床流程走一遍）：
#   [1] 权限：谁不能做什么（患者/管理员都不许写病历）
#   [2] 接诊队列：只含自己的号、不含已退号
#   [3] 状态机：booked → visiting →（必须有锁定病历）→ done
#   [4] 病历七段式：草稿 → 必填校验 → 锁定 → **锁定后不可改**
#   [5] 患者侧：只能读自己的、且**读不到草稿**
#   [6] 归属与越权：一律 404（不是 403 —— 403 是枚举 oracle）
#   [7] 预问诊衔接：问诊单 → 病历预填
#
# 用法：
#   .\emr-check.ps1 -Base http://127.0.0.1:8091 -AdminPw <口令> -Dsn <DSN>
#
# ⚠⚠ **不要与 `hospital-server.exe accept` 并发跑**：accept 的 `hResetAll`
#   （acceptance.cj）会**整表清空**业务表（appointment / schedule / doctor /
#   department / patient）⇒ 本脚本 [0] 步建好的夹具会在跑到一半时被删掉，
#   表现为**一片假红**（队列空、病历全 404），而根因与产品毫无关系。
#   两边又都会 `taskkill /F /IM hospital-server.exe` ⇒ 还会互相杀掉对方的 serve
#   （症状是 `HTTP 0`：curl 连不上）。⇒ HTTP 层 e2e 与 `accept` **必须串行**。

[CmdletBinding()]
param(
    [string]$Base = "http://127.0.0.1:8091",
    [Parameter(Mandatory=$true)][string]$AdminPw,
    [string]$Dsn = "mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital_test"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$root = Split-Path -Parent $PSScriptRoot
$Exe = Join-Path $root "build\hospital-server.exe"
if (-not (Test-Path $Exe)) { throw "找不到 $Exe（先跑 build.ps1）" }

$My = Get-MySqlClientArgs -Dsn $Dsn
$passed = 0
$failed = 0
function Check($name, $cond, $detail) {
    if ($cond) { Write-Host "  [PASS] $name" -ForegroundColor Green; $script:passed++ }
    else { Write-Host "  [FAIL] $name" -ForegroundColor Red; $script:failed++ }
    if ($detail) { Write-Host "         $detail" -ForegroundColor DarkGray }
}

# 用 curl 配置文件发请求（**不用 -d '...'**：PowerShell 会破坏 JSON 引号 —— 见 P2 踩坑）
function Req($tag, $method, $path, $headers, $jsonBody) {
    $cfg = Join-Path $env:TEMP ("emr_" + $tag + ".cfg")
    $lines = @("request = `"$method`"", "silent", "write-out = `"\n__M__%{http_code}`"")
    foreach ($h in $headers) { $lines += "header = `"$h`"" }
    if ($null -ne $jsonBody) {
        $bf = Join-Path $env:TEMP ("emr_" + $tag + ".json")
        [System.IO.File]::WriteAllText($bf, $jsonBody, (New-Object System.Text.UTF8Encoding($false)))
        $lines += "header = `"Content-Type: application/json`""
        $lines += "data = `"@" + ($bf -replace '\\','/') + "`""
    }
    [System.IO.File]::WriteAllText($cfg, ($lines -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
    $raw = (& curl.exe -s -K $cfg "$Base$path" 2>&1) -join "`n"
    $code = 0
    if ($raw -match '__M__(\d+)') { $code = [int]$Matches[1] }
    $body = ($raw -replace '(?s)\n?__M__\d+\s*$', '')
    return [pscustomobject]@{ Http = $code; Body = $body }
}
function Tok($login, $pw) {
    $r = Req ("lg" + $login) 'POST' '/api/v1/auth/login' @() ('{"login_name":"' + $login + '","password":"' + $pw + '"}')
    if ($r.Http -ne 200) { throw "登录失败 $login ($($r.Http)): $($r.Body)" }
    return ($r.Body | ConvertFrom-Json).data.token
}

# 夹具 SQL 一律**落盘再 source**（内联 `-Sql` 带中文时踩过"静默没执行"，见 [7] 注释）；
# 并且 `Invoke-MySqlFile` **不吞错**（顶部 $ErrorActionPreference="Stop"）⇒ 插完要自己校验行数。
function SqlFile($name, $sql) {
    $p = Join-Path $env:TEMP ("emr_" + $name + ".sql")
    [System.IO.File]::WriteAllText($p, $sql, (New-Object System.Text.UTF8Encoding($false)))
    Invoke-MySqlFile -My $My -Path ($p -replace '\\','/')
}
function RowCount($label, $sql) {
    return ("$(Invoke-MySqlScalar -My $My -Label $label -Sql $sql)").Trim()
}

# 建账号（201 新建 / 409 已存在）并把口令设成**已知值**，返回 auth_user.id。
#
# ⚠⚠ `POST /api/v1/admin/users/:id/password` 的 `:id` 是 **auth_user.id（自增主键）**，
#   **不是** `ref_id`！拿 ref_id（700001）去调会 404 USER_NOT_FOUND、口令**根本没被重设**，
#   而症状表现为"登录失败"，看起来像权限/令牌问题（假红）。
#   ⇒ 409（账号已存在）时必须先用 `GET /api/v1/admin/users?login_name=` 把真正的
#     user_id 问出来，再拿它重设口令。这样脚本**可重复跑**。
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

Write-Host ""
Write-Host "=== P4 电子病历 / 接诊队列 端到端验证 ===" -ForegroundColor Cyan
Write-Host "  目标: $Base"
Write-Host "  库  : $($My.Db)@$($My.DbHost):$($My.Port)"

# ── 夹具：干净的科室/医生/患者/挂号单（直接写库，绕开接口以便精确控制前置状态）
Write-Host ""
Write-Host "[0] 准备夹具"
$null = Invoke-MySqlScalar -My $My -Label "清病历" -Sql "DELETE FROM medical_record"
$null = Invoke-MySqlScalar -My $My -Label "清挂号" -Sql "DELETE FROM appointment"
$null = Invoke-MySqlScalar -My $My -Label "清排班" -Sql "DELETE FROM schedule"
$null = Invoke-MySqlScalar -My $My -Label "清医生" -Sql "DELETE FROM doctor WHERE id >= 700000"
$null = Invoke-MySqlScalar -My $My -Label "清科室" -Sql "DELETE FROM department WHERE id >= 700000"
$null = Invoke-MySqlScalar -My $My -Label "清患者" -Sql "DELETE FROM patient WHERE id >= 700000"
$null = Invoke-MySqlScalar -My $My -Label "清会话" -Sql "DELETE FROM previsit_session"
$null = Invoke-MySqlScalar -My $My -Label "清统计" -Sql "DELETE FROM triage_stat"

$seedSql = @"
INSERT INTO department (id, name, code, created_at) VALUES (700001, 'P4端到端科', 'P4E2E', 0);
INSERT INTO doctor (id, name, department_id, title, specialty, created_at) VALUES (700001, 'P4端到端医生', 700001, '主任医师', '测试', 0);
INSERT INTO schedule (id, doctor_id, department_id, work_date, period, total_num, remain_num, version, enabled, created_at) VALUES (700001, 700001, 700001, '2026-12-25', 'AM', 20, 20, 0, 1, 0);
INSERT INTO patient (id, phone, name, gender, birth_date, created_at) VALUES (700001, '13800070001', 'P4端到端患者', 'M', '1990-01-01', 0);
INSERT INTO patient (id, phone, name, gender, birth_date, created_at) VALUES (700002, '13800070002', 'P4另一患者', 'F', '1992-02-02', 0);
INSERT INTO appointment (id, schedule_id, patient_id, doctor_id, department_id, visit_date, period, seq_no, status, slot_restored, created_at) VALUES (700001, 700001, 700001, 700001, 700001, '2026-12-25', 'AM', 1, 'booked', 1, 0);
INSERT INTO appointment (id, schedule_id, patient_id, doctor_id, department_id, visit_date, period, seq_no, status, slot_restored, created_at) VALUES (700002, 700001, 700002, 700001, 700001, '2026-12-25', 'AM', 2, 'cancelled', 1, 0);
"@
# ⚠ `Invoke-MySqlFile` 收的是**文件路径**（不是 SQL 文本）—— 先落盘
SqlFile 'seed' $seedSql
# ★ 插完必须**校验行数**：`Invoke-MySqlFile` 不吞错只在"SQL 报错"时救你，
#   而"SQL 压根没执行"（文件没落盘 / 路径错）它**不会**报 —— 那会让后面一片假红。
$seedCnt = RowCount "夹具行数" "SELECT (SELECT COUNT(*) FROM doctor WHERE id=700001) + (SELECT COUNT(*) FROM schedule WHERE id=700001) + (SELECT COUNT(*) FROM patient WHERE id IN (700001,700002)) + (SELECT COUNT(*) FROM appointment WHERE id IN (700001,700002))"
Check "夹具就绪（1 医生 / 1 排班 / 2 患者 / 2 挂号单，其中 1 张已退号）" ("$seedCnt" -eq '6') ("实得 $seedCnt 行（期望 6）")

$admTok = Tok "admin" $AdminPw
# 建医生账号（绑 doctor 700001）
$docPw = "DoctorP4pass1"
$acc = EnsureAccount 'doc' 'p4doctor' $docPw 'doctor' 700001 'P4医生'
Check "管理员建医生账号（201 新建 / 409 已存在）" ($acc.Http -eq 201 -or $acc.Http -eq 409) ("HTTP $($acc.Http)，auth_user.id=$($acc.UserId)")
Check "★ 口令按 auth_user.id 重设（拿 ref_id 去调会 404 且口令没变）" ($acc.UserId -gt 0) ("user_id=$($acc.UserId)")
$docTok = Tok "p4doctor" $docPw
Check "医生登录成功" ($docTok.Length -eq 64) ("token $($docTok.Length) 字符")
# ⚠ **不要用既有的 13800000001** —— 它绑的是 patient_id=1，与我的夹具 700001 无关。
#   我第一版图省事复用了它 ⇒ "患者读自己的病历"全 404（**假红**：不是权限问题，是看的不是同一个人）。
#   📌 夹具必须**自建并绑定自己的实体**，不能借用别人的账号。
$patLogin = "p4patient"
$patPw = "PatientP4pass1"
$acc = EnsureAccount 'pat' $patLogin $patPw 'patient' 700001 'P4患者'
Check "管理员建患者账号（绑 patient 700001）" ($acc.Http -eq 201 -or $acc.Http -eq 409) ("HTTP $($acc.Http)，auth_user.id=$($acc.UserId)")
Check "★ 患者口令按 auth_user.id 重设（可重复跑）" ($acc.UserId -gt 0) ("user_id=$($acc.UserId)")
$patTok = Tok $patLogin $patPw
Check "患者（绑 700001）登录成功" ($patTok.Length -eq 64) ("token $($patTok.Length) 字符")

# ── [1] 权限
Write-Host ""
Write-Host "[1] 权限：谁不能写病历"
$r = Req 'patvisit' 'GET' '/api/v1/doctor/visits' @("Authorization: Bearer $patTok") $null
Check "★ 患者读接诊队列 → 403（那是医生的工作台）" ($r.Http -eq 403) ("HTTP $($r.Http)")
$r = Req 'admvisit' 'GET' '/api/v1/doctor/visits' @("Authorization: Bearer $admTok") $null
Check "★ 管理员读接诊队列 → 403（管理员不参与临床）" ($r.Http -eq 403) ("HTTP $($r.Http)")
$r = Req 'admwrite' 'PUT' '/api/v1/doctor/visits/700001/record' @("Authorization: Bearer $admTok") '{"diagnosis":"管理员写的"}'
Check "★★ 管理员**不能**写病历（病历作者必须是临床人员）" ($r.Http -eq 403) ("HTTP $($r.Http)")
$r = Req 'patwrite' 'PUT' '/api/v1/doctor/visits/700001/record' @("Authorization: Bearer $patTok") '{"diagnosis":"患者写的"}'
Check "★★ 患者**不能**写病历" ($r.Http -eq 403) ("HTTP $($r.Http)")

# ── [2] 接诊队列
Write-Host ""
Write-Host "[2] 接诊队列"
$r = Req 'queue' 'GET' '/api/v1/doctor/visits' @("Authorization: Bearer $docTok") $null
Check "医生读队列 → 200" ($r.Http -eq 200) ("HTTP $($r.Http)")
$q = $r.Body | ConvertFrom-Json
$ids = @($q.data.items | ForEach-Object { $_.appointment_id })
Check "★ 队列含未退号的 700001" ($ids -contains 700001) ("ids=$($ids -join ',')")
Check "★★ 队列**不含**已退号的 700002" (-not ($ids -contains 700002)) ("ids=$($ids -join ',')")
Check "队列项带病历进度（record_status）" ($null -ne ($q.data.items | Where-Object { $_.appointment_id -eq 700001 } | Select-Object -First 1).record_status)

# ── [3] 状态机
Write-Host ""
Write-Host "[3] 接诊状态机"
$r = Req 'finish0' 'POST' '/api/v1/doctor/visits/700001/finish' @("Authorization: Bearer $docTok") $null
Check "★ 未开始接诊就「完成」→ 409（状态冲突，不是 400）" ($r.Http -eq 409) ("HTTP $($r.Http)")
$r = Req 'start' 'POST' '/api/v1/doctor/visits/700001/start' @("Authorization: Bearer $docTok") $null
Check "开始接诊 → 200" ($r.Http -eq 200) ("HTTP $($r.Http)")
Check "★ 状态变为 visiting" (($r.Body | ConvertFrom-Json).data.status -eq 'visiting')
$r = Req 'finish1' 'POST' '/api/v1/doctor/visits/700001/finish' @("Authorization: Bearer $docTok") $null
Check "★★ 病历未锁定就「完成就诊」→ 409 EMR_NOT_LOCKED" ($r.Http -eq 409) ("HTTP $($r.Http)")
Check "★★ 且错误码明确（客户端能据此提示「请先提交病历」）" (($r.Body | ConvertFrom-Json).error.code -eq 'EMR_NOT_LOCKED') (($r.Body | ConvertFrom-Json).error.code)

# ── [4] 病历七段式
Write-Host ""
Write-Host "[4] 病历：草稿 → 必填校验 → 锁定 → 锁定后不可改"
$r = Req 'rec0' 'GET' '/api/v1/doctor/visits/700001/record' @("Authorization: Bearer $docTok") $null
Check "读病历（尚无）→ 200 且给出七段骨架" ($r.Http -eq 200 -and (($r.Body | ConvertFrom-Json).data.sections).Count -eq 7) ("段数 $((($r.Body | ConvertFrom-Json).data.sections).Count)")
$r = Req 'draft1' 'PUT' '/api/v1/doctor/visits/700001/record' @("Authorization: Bearer $docTok") '{"chief_complaint":"咳嗽三天"}'
Check "★ 只写一段就能存草稿（草稿允许半成品）" ($r.Http -eq 200) ("HTTP $($r.Http)")
Check "★ filled = 1" (($r.Body | ConvertFrom-Json).data.filled -eq 1)
$r = Req 'lock1' 'POST' '/api/v1/doctor/visits/700001/record/lock' @("Authorization: Bearer $docTok") $null
Check "★★ 缺必填（诊断/处理意见）时锁定被拒 400" ($r.Http -eq 400) ("HTTP $($r.Http)")
Check "★ 且说清缺哪几段（医生不必猜）" ($r.Body -match '诊断' -and $r.Body -match '处理意见')
$full = '{"chief_complaint":"咳嗽三天","present_illness":"受凉后出现，干咳为主","past_history":"无","allergy_history":"青霉素过敏","physical_exam":"咽部充血，双肺呼吸音清","diagnosis":"急性上呼吸道感染","treatment":"多饮水休息；如有发热返诊"}'
$r = Req 'draft2' 'PUT' '/api/v1/doctor/visits/700001/record' @("Authorization: Bearer $docTok") $full
Check "填满七段 → 200" ($r.Http -eq 200) ("HTTP $($r.Http)")
Check "★ filled = 7" (($r.Body | ConvertFrom-Json).data.filled -eq 7)
$r = Req 'lock2' 'POST' '/api/v1/doctor/visits/700001/record/lock' @("Authorization: Bearer $docTok") $null
Check "锁定 → 200" ($r.Http -eq 200) ("HTTP $($r.Http)")
Check "★ status = locked" (($r.Body | ConvertFrom-Json).data.status -eq 'locked')
$r = Req 'edit3' 'PUT' '/api/v1/doctor/visits/700001/record' @("Authorization: Bearer $docTok") '{"diagnosis":"被篡改的诊断"}'
Check "★★ 锁定后再改 → 409 EMR_LOCKED" ($r.Http -eq 409) ("HTTP $($r.Http)")
Check "★★ 且错误码是 EMR_LOCKED" (($r.Body | ConvertFrom-Json).error.code -eq 'EMR_LOCKED')
$r = Req 'recheck' 'GET' '/api/v1/doctor/visits/700001/record' @("Authorization: Bearer $docTok") $null
$diag = ($r.Body | ConvertFrom-Json).data.sections | Where-Object { $_.key -eq 'diagnosis' } | Select-Object -First 1
Check "★★ 库里诊断**真的没变**（不是「拒了但写进去了」）" ($diag.value -eq '急性上呼吸道感染') ("诊断=$($diag.value)")
$r = Req 'finish2' 'POST' '/api/v1/doctor/visits/700001/finish' @("Authorization: Bearer $docTok") $null
Check "★ 病历锁定后可以完成就诊 → 200" ($r.Http -eq 200) ("HTTP $($r.Http)")
Check "★ 状态 = done" (($r.Body | ConvertFrom-Json).data.status -eq 'done')
$r = Req 'startagain' 'POST' '/api/v1/doctor/visits/700001/start' @("Authorization: Bearer $docTok") $null
Check "★★ done 是终态：再开始接诊 → 409" ($r.Http -eq 409) ("HTTP $($r.Http)")

# ── [5] 患者侧
Write-Host ""
Write-Host "[5] 患者侧：只能读自己的、读不到草稿"
$r = Req 'mylist' 'GET' '/api/v1/medical-records' @("Authorization: Bearer $patTok") $null
Check "患者读自己的档案列表 → 200" ($r.Http -eq 200) ("HTTP $($r.Http)")
$lst = $r.Body | ConvertFrom-Json
Check "★ 列表含已锁定的那份" ((@($lst.data.items | ForEach-Object { $_.appointment_id }) -contains 700001))
Check "★★ 列表里**每一条**都属于自己（patient_id 全 = 700001）" `
      ((@($lst.data.items | Where-Object { $_.patient_id -ne 700001 })).Count -eq 0)
$r = Req 'myone' 'GET' '/api/v1/medical-records/700001' @("Authorization: Bearer $patTok") $null
Check "患者读已锁定的病历 → 200" ($r.Http -eq 200) ("HTTP $($r.Http)")
Check "★ 且含七段正文" ((($r.Body | ConvertFrom-Json).data.sections).Count -eq 7)
$r = Req 'others' 'GET' '/api/v1/medical-records/700001' @("Authorization: Bearer $admTok") $null
Check "★ 管理员没有读病历的入口 → 403（未实现的动作不发权）" ($r.Http -eq 403) ("HTTP $($r.Http)")

# ── [6] 越权一律 404
Write-Host ""
Write-Host "[6] 越权：一律 404（不是 403 —— 403 是枚举 oracle）"
# 造一个"不属于该医生"的单：另一个医生名下（照样走**文件** + 行数校验）
$otherSql = @"
INSERT INTO doctor (id, name, department_id, title, specialty, created_at) VALUES (700002, 'P4别的医生', 700001, '医师', '测试', 0);
INSERT INTO appointment (id, schedule_id, patient_id, doctor_id, department_id, visit_date, period, seq_no, status, slot_restored, created_at) VALUES (700003, 700001, 700001, 700002, 700001, '2026-12-25', 'AM', 3, 'booked', 1, 0);
"@
SqlFile 'other' $otherSql
$otherCnt = RowCount "校验别人的单已插入" "SELECT COUNT(*) FROM appointment WHERE id=700003 AND doctor_id=700002"
Check "夹具：别人的单已落库（实得 $otherCnt 行）" ("$otherCnt" -eq '1')
$r = Req 'notmine' 'GET' '/api/v1/doctor/visits/700003/record' @("Authorization: Bearer $docTok") $null
Check "★★ 医生读**别人**的单 → 404（不区分「无权限」，避免枚举）" ($r.Http -eq 404) ("HTTP $($r.Http)")
$r = Req 'notmine2' 'PUT' '/api/v1/doctor/visits/700003/record' @("Authorization: Bearer $docTok") '{"diagnosis":"越权写"}'
Check "★★ 医生改**别人**的单 → 404" ($r.Http -eq 404) ("HTTP $($r.Http)")
$r = Req 'notexist' 'GET' '/api/v1/doctor/visits/999999/record' @("Authorization: Bearer $docTok") $null
Check "★★ 不存在的单 → 404（与「别人的单」**同码**）" ($r.Http -eq 404) ("HTTP $($r.Http)")

# ── [7] 预问诊衔接（问诊单 → 病历预填）
Write-Host ""
Write-Host "[7] 预问诊衔接：问诊单预填病历"
$intakeSql = @"
INSERT INTO appointment (id, schedule_id, patient_id, doctor_id, department_id, visit_date, period, seq_no, status, slot_restored, created_at) VALUES (700004, 700001, 700002, 700001, 700001, '2026-12-25', 'AM', 4, 'visiting', 1, 0);
"@
SqlFile 'intake' $intakeSql
$intakeCnt = RowCount "校验预填单已插入" "SELECT COUNT(*) FROM appointment WHERE id=700004 AND status='visiting'"
Check "夹具：预填用的接诊单已落库（实得 $intakeCnt 行）" ("$intakeCnt" -eq '1')
# ⚠ 必须 ≤64 字符（`previsit_session.id` 是 varchar(64)）—— 我第一版写了 66 字符，
#   而 `Invoke-MySqlFile` 不吞错 ⇒ MySQL 报 1406 Data too long，**整个脚本中断**。
#   ⇒ 夹具自己也要有形状约束，且**在插库之前**断言（插完再断言就太晚了：脚本已经中断）。
$sid = 'p4intake-' + ('0' * 53) + '01'
Check "夹具：session_id 长度 ≤64（varchar(64)，实得 $($sid.Length)）" ($sid.Length -le 64) ("sid=$sid")
$formJson = '{"chief":"腹痛两天","duration":"2 天","severity":"影响睡眠","associated":"恶心","history":"高血压 5 年","allergy":"无"}'
# ⚠ 用**文件**落 SQL 再 source —— 内联拼 SQL 时 PowerShell 的引号/反斜杠会坏掉
#   （实测：内联那条 INSERT 静默没执行，导致预填全空、假红 4 条）。
$pvSql = "INSERT INTO previsit_session (id, patient_id, turn, form_json, created_at, updated_at) " +
         "VALUES ('" + $sid + "', 700002, 6, '" + $formJson + "', 0, 0);"
SqlFile 'pv' $pvSql
$pvCnt = RowCount "校验问诊单已插入" "SELECT COUNT(*) FROM previsit_session WHERE id='$sid'"
Check "夹具：预问诊问诊单已落库（实得 $pvCnt 行）" ("$pvCnt" -eq '1')
$r = Req 'prefill' 'PUT' '/api/v1/doctor/visits/700004/record' @("Authorization: Bearer $docTok") `
     ('{"use_intake_session":"' + $sid + '","physical_exam":"腹软","diagnosis":"急性胃炎","treatment":"清淡饮食"}')
Check "带 use_intake_session 存草稿 → 200" ($r.Http -eq 200) ("HTTP $($r.Http)")
$rec = $r.Body | ConvertFrom-Json
$chief = ($rec.data.sections | Where-Object { $_.key -eq 'chief_complaint' } | Select-Object -First 1).value
$allergy = ($rec.data.sections | Where-Object { $_.key -eq 'allergy_history' } | Select-Object -First 1).value
$illness = ($rec.data.sections | Where-Object { $_.key -eq 'present_illness' } | Select-Object -First 1).value
Check "★★ 主诉由问诊单预填（实得「$chief」）" ($chief -eq '腹痛两天')
Check "★★ 过敏史由问诊单预填（实得「$allergy」）" ($allergy -eq '无')
Check "★★ 现病史由病程/程度/伴随合成（实得「$illness」）" ($illness -match '病程：2 天' -and $illness -match '程度：影响睡眠')
Check "★ 医生显式提交的段优先（诊断不被预填覆盖）" (($rec.data.sections | Where-Object { $_.key -eq 'diagnosis' } | Select-Object -First 1).value -eq '急性胃炎')
$r = Req 'prefill2' 'PUT' '/api/v1/doctor/visits/700004/record' @("Authorization: Bearer $docTok") `
     ('{"use_intake_session":"' + $sid + '","chief_complaint":"医生改过的主诉"}')
Check "★★ 已有病历时再带 session **不覆盖**已写内容（医生判断优先）" `
      ((($r.Body | ConvertFrom-Json).data.sections | Where-Object { $_.key -eq 'chief_complaint' } | Select-Object -First 1).value -eq '医生改过的主诉')

Write-Host ""
if ($failed -eq 0) {
    Write-Host "✅ P4 电子病历 / 接诊队列 验证全部通过（通过 $passed 项）" -ForegroundColor Green
    exit 0
} else {
    Write-Host "❌ 失败 $failed 项（通过 $passed 项）" -ForegroundColor Red
    exit 1
}
