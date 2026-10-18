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
#   [8] 真并发首建同一张单：竞态下的 409 也必须带 error.fields（2026-10-16 复核 N3）
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
    if ($r.Http -ne 200) {
        # 限流是服务端的正常保护：能清就清掉计数再重试一次，然后才谈失败
        if (Test-HospLoginRateLimited -Login $login -Resp $r -My $My) {
            $r = Req ("lg2" + $login) 'POST' '/api/v1/auth/login' @() ('{"login_name":"' + $login + '","password":"' + $pw + '"}')
        }
        if ($r.Http -ne 200) { Stop-HospLogin -Login $login -Resp $r -My $My -Base $Base }
    }
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

# ★ 2026-10-18：就诊日期门槛（server/src/http_p4.cj 的 p4RequireVisitNotFuture）只放行
#   **非未来**的号，所以夹具里的就诊日必须用「今天」而不是写死的 2026-12-25。
$emrToday = (Get-Date).ToString('yyyy-MM-dd')
$seedSql = @"
INSERT INTO department (id, name, code, created_at) VALUES (700001, 'P4端到端科', 'P4E2E', 0);
INSERT INTO doctor (id, name, department_id, title, specialty, created_at) VALUES (700001, 'P4端到端医生', 700001, '主任医师', '测试', 0);
INSERT INTO schedule (id, doctor_id, department_id, work_date, period, total_num, remain_num, version, enabled, created_at) VALUES (700001, 700001, 700001, '$emrToday', 'AM', 20, 20, 0, 1, 0);
INSERT INTO patient (id, phone, name, gender, birth_date, created_at) VALUES (700001, '13800070001', 'P4端到端患者', 'M', '1990-01-01', 0);
INSERT INTO patient (id, phone, name, gender, birth_date, created_at) VALUES (700002, '13800070002', 'P4另一患者', 'F', '1992-02-02', 0);
INSERT INTO appointment (id, schedule_id, patient_id, doctor_id, department_id, visit_date, period, seq_no, status, slot_restored, created_at) VALUES (700001, 700001, 700001, 700001, 700001, '$emrToday', 'AM', 1, 'booked', 1, 0);
INSERT INTO appointment (id, schedule_id, patient_id, doctor_id, department_id, visit_date, period, seq_no, status, slot_restored, created_at) VALUES (700002, 700001, 700002, 700001, 700001, '$emrToday', 'AM', 2, 'cancelled', 1, 0);
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
# ★★ 2026-10-16（复核 N1）：再造一张**孤儿引用**挂号单 —— `patient_id` 在 patient 表里查不到。
#
# 为什么必须有这张单：服务端对"查不到患者"给的是**空串**（`http_p4.cj` 的 `putPatientInto`），
#   而 `appointment.patient_id` **没有外键**（`schema.cj` 里 `FOREIGN KEY|REFERENCES` 命中 0 次）
#   ⇒ 患者档案迁移/清理/历史导入都会造出这种行，空串是**真实可达**的合法取值。
#   不造它，队列接口的 patient_name 就永远是真姓名，那条路**一次都跑不到**，
#   于是 contract schema 里写 `minLength: 1` 也永远不红（样例是从真库导的，复核 N1 说的就是这个）。
#   ⚠ 行数必须自己校验：`Invoke-MySqlFile` 只在"SQL 报错"时抛出，"文件没落盘"它不报（见 [7] 的坑）。
$orphanSql = @"
INSERT INTO appointment (id, schedule_id, patient_id, doctor_id, department_id, visit_date, period, seq_no, status, slot_restored, created_at) VALUES (700005, 700001, 700999, 700001, 700001, '$emrToday', 'PM', 5, 'booked', 1, 0);
"@
SqlFile 'orphan' $orphanSql
$orphanCnt = RowCount "校验孤儿引用已插入" "SELECT COUNT(*) FROM appointment a LEFT JOIN patient p ON p.id = a.patient_id WHERE a.id = 700005 AND p.id IS NULL"
Check "夹具：孤儿引用挂号单已落库（patient_id=700999，无对应患者；实得 $orphanCnt 行）" ("$orphanCnt" -eq '1')
$r = Req 'queue' 'GET' '/api/v1/doctor/visits' @("Authorization: Bearer $docTok") $null
Check "医生读队列 → 200" ($r.Http -eq 200) ("HTTP $($r.Http)")
$q = $r.Body | ConvertFrom-Json
$ids = @($q.data.items | ForEach-Object { $_.appointment_id })
Check "★ 队列含未退号的 700001" ($ids -contains 700001) ("ids=$($ids -join ',')")
Check "★★ 队列**不含**已退号的 700002" (-not ($ids -contains 700002)) ("ids=$($ids -join ',')")
Check "队列项带病历进度（record_status）" ($null -ne ($q.data.items | Where-Object { $_.appointment_id -eq 700001 } | Select-Object -First 1).record_status)
# ★★ 2026-10-16（医生端复核 ★★★ 第 2 条）：队列此前只有「患者 #700001」，医生认不出人。
$qItem = $q.data.items | Where-Object { $_.appointment_id -eq 700001 } | Select-Object -First 1
Check "★★ 队列项带 patient_name（实得「$($qItem.patient_name)」）" ($qItem.patient_name -eq 'P4端到端患者')
Check "★★ 队列项带 patient_gender（实得「$($qItem.patient_gender)」）" ($qItem.patient_gender -eq 'M')
# ★★ 复核 N1：孤儿引用 ⇒ 查不到患者 ⇒ **空串**（不是省字段、更不是 500/报错）。
#   断言刻意写 `$null -ne $oItem.patient_name -and $oItem.patient_name -eq ''`：
#   若服务端改成"查不到就省字段"，属性是 $null，`$null -eq ''` 为假 ⇒ 这条会红。
#   也就是说这条同时钉住了「形状不随数据在不在变化」这条纪律（省字段就违反了 required）。
$oItem = $q.data.items | Where-Object { $_.appointment_id -eq 700005 } | Select-Object -First 1
if ($null -eq $oItem) { $oShape = '<队列里没有这单>' }
elseif ($null -eq $oItem.patient_name) { $oShape = '<字段被省掉（null）>' }
elseif ($oItem.patient_name -eq '') { $oShape = '<空串>' }
else { $oShape = "「$($oItem.patient_name)」" }
Check "★★ 孤儿引用：该单仍出现在队列里（查不到患者不影响这单进队列）" ($null -ne $oItem)
Check "★★ 孤儿引用：patient_name 是空串而不是省字段（实得 $oShape）" `
      ($null -ne $oItem -and $null -ne $oItem.patient_name -and $oItem.patient_name -eq '')
Check "★★ 孤儿引用：patient_gender 同样是空串（实得「$(if ($null -eq $oItem) { '<无>' } else { $oItem.patient_gender } )」）" `
      ($null -ne $oItem -and $null -ne $oItem.patient_gender -and $oItem.patient_gender -eq '')

# ── [3] 状态机
Write-Host ""
Write-Host "[3] 接诊状态机"
$r = Req 'finish0' 'POST' '/api/v1/doctor/visits/700001/finish' @("Authorization: Bearer $docTok") $null
Check "★ 未开始接诊就「完成」→ 409（状态冲突，不是 400）" ($r.Http -eq 409) ("HTTP $($r.Http)")
$r = Req 'start0' 'POST' '/api/v1/doctor/visits/700001/start' @("Authorization: Bearer $docTok") $null
Check "★★ 改进 6：没到院就直接「开始接诊」→ 409（不能跳步）" ($r.Http -eq 409) ("HTTP $($r.Http)")
Check "★★ 且错误码是 VISIT_BAD_STATE" (($r.Body | ConvertFrom-Json).error.code -eq 'VISIT_BAD_STATE') (($r.Body | ConvertFrom-Json).error.code)
$r = Req 'arrive' 'POST' '/api/v1/doctor/visits/700001/arrive' @("Authorization: Bearer $docTok") $null
Check "★ 到院登记 → 200" ($r.Http -eq 200) ("HTTP $($r.Http)")
Check "★ 状态变为 arrived" (($r.Body | ConvertFrom-Json).data.status -eq 'arrived')
Check "★ 且写了 arrived_at（> 0）" ((($r.Body | ConvertFrom-Json).data.arrived_at) -gt 0)
$r = Req 'waiting' 'POST' '/api/v1/doctor/visits/700001/waiting' @("Authorization: Bearer $docTok") $null
Check "★ 进入候诊 → 200" ($r.Http -eq 200) ("HTTP $($r.Http)")
Check "★ 状态变为 waiting" (($r.Body | ConvertFrom-Json).data.status -eq 'waiting')
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
# ★★ 2026-10-16：**空病历骨架**这条也要带姓名 —— 姓名取自挂号单而不是病历行
#   （骨架的 patient_id 是 0；从病历行取就会在这条路上显示成空）。
Check "★★ 空病历骨架也带 patient_name（实得「$(($r.Body | ConvertFrom-Json).data.patient_name)」）" ((($r.Body | ConvertFrom-Json).data.patient_name) -eq 'P4端到端患者')
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
INSERT INTO appointment (id, schedule_id, patient_id, doctor_id, department_id, visit_date, period, seq_no, status, slot_restored, created_at) VALUES (700003, 700001, 700001, 700002, 700001, '$emrToday', 'AM', 3, 'booked', 1, 0);
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
INSERT INTO appointment (id, schedule_id, patient_id, doctor_id, department_id, visit_date, period, seq_no, status, slot_restored, created_at) VALUES (700004, 700001, 700002, 700001, 700001, '$emrToday', 'AM', 4, 'visiting', 1, 0);
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

# ── [8] 真并发首建同一张单（2026-10-16 复核 N3）
#
# 为什么必须有这一段：问题 1 修完后，`http_p4.cj` 里仍留着一条**故意**不带 `error.fields`
#   的 EMR_CHANGED 出口（`out.currentUpdatedAt <= 0` 时）—— 契约口径本身没错（拿不到真值就不编），
#   但它今天只剩**一条**路可达：两个请求几乎同时**首建同一张挂号单**的病历 ⇒ 两边都先读到
#   "还没有病历"，一个 INSERT 成功、另一个撞唯一键 `uk_record_appointment`，回读时又拿不到当前版本。
#   仓库自己写着"真正那条路径只有真并发才走得到"（`acceptance_p4.cj`），而验收里钉的是
#   `baseDuplicateMessage` **这个助手函数**，不是那句 catch 的真实路径；
#   `stress-booking.ps1` 压的是挂号超卖，也没有"两个请求同时首建一张单的病历"。
#   ⇒ 这条路径此前没有端到端门禁。本段用**独立进程真并发**补上，断言核心不是"撞没撞上"，
#     而是**一旦撞上，那个 409 必须带 error.fields**（外加唯一键与不丢更新这两条不变式）。
#
# ⚠ 为什么用独立 curl 进程而不是线程：与 `stress-booking.ps1` 同因（本仓通篇没有 spawn），
#   且进程各自独立 ⇒ 服务端收到的是真的两个并发请求，而不是一个连接上的顺序请求。
# ⚠ 令牌走 curl 配置文件（`-K`），不上命令行（否则会出现在进程表里被人看到）。
# ⚠ 载荷用**纯 ASCII**（`race-<轮>-<工>`）：下面要拿库里的值跟"赢家原文"比对，
#   而 mariadb 客户端在 Windows 上的输出编码不可靠（中文可能变成乱码 ⇒ 假红）。
Write-Host ""
Write-Host "[8] 真并发：两个请求同时首建同一张单的病历"
$raceDir = Join-Path $env:TEMP ("emrrace-" + [Guid]::NewGuid().ToString("N"))
$null = New-Item -ItemType Directory -Path $raceDir -Force
$raceRounds = 8
$raceWorkers = 6
$raceBadCode = @()
$raceBadFields = @()
$raceBadRows = @()
$raceLost = @()
$raceWon = 0
$raceConflict = 0
$raceRoundsHit = 0
for ($rd = 1; $rd -le $raceRounds; $rd++) {
    $raceId = 700100 + $rd
    $raceSeq = 100 + $rd
    $raceSql = "INSERT INTO appointment (id, schedule_id, patient_id, doctor_id, department_id, visit_date, period, seq_no, status, slot_restored, created_at) VALUES ($raceId, 700001, 700002, 700001, 700001, '$emrToday', 'AM', $raceSeq, 'visiting', 1, 0);"
    SqlFile ("race" + $rd) $raceSql
    $racePre = RowCount "竞态单 $raceId 起跑前无病历" "SELECT COUNT(*) FROM medical_record WHERE appointment_id = $raceId"
    if ("$racePre" -ne '0') {
        $raceBadRows += "第 $rd 轮：起跑前就已经有 $racePre 行病历（夹具不对，本轮作废）"
        continue
    }
    $procs = @()
    for ($w = 0; $w -lt $raceWorkers; $w++) {
        $bodyFile = Join-Path $raceDir ("b$rd-$w.json")
        # 带 use_intake_session：走"预填"那条更长的路径（医生显式提交的段仍优先 ⇒ 下面的
        # "存下来的必须是某个赢家的原文"依然有效）
        $payload = '{"chief_complaint":"race-' + $rd + '-' + $w + '","use_intake_session":"' + $sid + '"}'
        [System.IO.File]::WriteAllText($bodyFile, $payload, (New-Object System.Text.UTF8Encoding($false)))
        $cfg = Join-Path $raceDir ("c$rd-$w.cfg")
        # ⚠⚠ `data` 这一行**必须单独拼**（不能用数组字面量里 `"data = `"@" + …`）：
        #   实测那样拼出来的是 `data = "@` + 换行 + 路径（PowerShell 把它当成了**here-string**），
        #   而 curl 报的是 `option -K: error encountered when reading a file` —— 看起来像
        #   "配置文件读不了"，与真因（配置内容坏了）差着十万八千里，白查半天。
        #   ⇒ 常量段用**单引号**拼，`@` 旁边不留转义引号，就不可能有这个歧义。
        $raceData = $bodyFile -replace '\\','/'
        $lines = @("request = `"PUT`"", "silent", "write-out = `"\n__M__%{http_code}`"",
                   "header = `"Authorization: Bearer $docTok`"",
                   "header = `"Content-Type: application/json`"")
        $lines += ('data = "@' + $raceData + '"')
        [System.IO.File]::WriteAllText($cfg, ($lines -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
        $outFile = Join-Path $raceDir ("o$rd-$w.txt")
        $procs += Start-Process -FilePath "curl.exe" `
                  -ArgumentList @("-s", "-K", $cfg, "$Base/api/v1/doctor/visits/$raceId/record") `
                  -RedirectStandardOutput $outFile -NoNewWindow -PassThru
    }
    foreach ($pr in $procs) { $pr.WaitForExit() }
    $hitThisRound = 0
    $wonThisRound = @()
    for ($w = 0; $w -lt $raceWorkers; $w++) {
        $raw = [System.IO.File]::ReadAllText((Join-Path $raceDir ("o$rd-$w.txt")))
        $code = 0
        if ($raw -match '__M__(\d+)') { $code = [int]$Matches[1] }
        $body = ($raw -replace '(?s)\n?__M__\d+\s*$', '')
        if ($code -eq 200) {
            $raceWon++
            $wonThisRound += ("race-" + $rd + "-" + $w)
        } elseif ($code -eq 409) {
            $raceConflict++
            $hitThisRound++
            $code409 = ''
            $fUp = 0
            $fBy = 0
            try {
                $j = $body | ConvertFrom-Json
                $code409 = "$($j.error.code)"
                if ($null -ne $j.error.fields) {
                    if ($null -ne $j.error.fields.updated_at) { $fUp = [int64]$j.error.fields.updated_at }
                    if ($null -ne $j.error.fields.updated_by) { $fBy = [int64]$j.error.fields.updated_by }
                }
            } catch { $code409 = "<响应不是合法 JSON：$body>" }
            if ($code409 -ne 'EMR_CHANGED' -or $fUp -le 0 -or $fBy -le 0) {
                $raceBadFields += "第 $rd 轮 worker$w：code=$code409 updated_at=$fUp updated_by=$fBy body=$body"
            }
        } else {
            $raceBadCode += "第 $rd 轮 worker$w：HTTP $code（既不是 200 也不是 409）body=$body"
        }
    }
    if ($hitThisRound -gt 0) { $raceRoundsHit++ }
    $raceRows = RowCount "竞态单 $raceId 终态病历行数" "SELECT COUNT(*) FROM medical_record WHERE appointment_id = $raceId"
    if ("$raceRows" -ne '1') { $raceBadRows += "第 $rd 轮：终态 $raceRows 行病历（期望恰好 1 行）" }
    if ($wonThisRound.Count -gt 0) {
        $raceStored = (RowCount "竞态单 $raceId 存下来的主诉" "SELECT chief_complaint FROM medical_record WHERE appointment_id = $raceId").Trim()
        $okStored = $false
        foreach ($wv in $wonThisRound) { if ($raceStored -eq $wv) { $okStored = $true } }
        if (-not $okStored) { $raceLost += "第 $rd 轮：库里存的是「$raceStored」，但 200 的赢家写的是 $($wonThisRound -join ' / ')" }
    }
}
Write-Host "  竞态实测：$raceRounds 轮 × $raceWorkers 并发 —— 200 共 $raceWon 次、409 共 $raceConflict 次、撞上窗口的轮次 $raceRoundsHit/$raceRounds" -ForegroundColor DarkGray
Check "★★ 真并发：每个响应都是 200 或 409（没有 5xx、没有 HTTP 0 = 连不上）" ($raceBadCode.Count -eq 0) ($raceBadCode -join ' | ')
Check "★★ 真并发：**任何** 409 都必须带 error.fields（updated_at / updated_by > 0）" ($raceBadFields.Count -eq 0) ($raceBadFields -join ' | ')
Check "★★ 真并发：每张单终态**恰好 1 行**病历（唯一键 uk_record_appointment 成立）" ($raceBadRows.Count -eq 0) ($raceBadRows -join ' | ')
Check "★★ 真并发：库里存下来的段必须是某个赢家的原文（没有半截 / 没被覆盖）" ($raceLost.Count -eq 0) ($raceLost -join ' | ')
Check "★★ 真并发：至少有一轮真的撞上首建竞态（撞不上说明本用例只跑了一半）" ($raceRoundsHit -gt 0) `
      "撞上 $raceRoundsHit/$raceRounds 轮（撞不上不是产品缺陷，是本机没凑上那个窗口；但覆盖也就没落到那条 catch 上）"
# 收尾：删竞态临时目录（**先校验解析后的绝对路径确实在 TEMP 下**，不拿算出来的路径直接删）
$raceDirFull = [System.IO.Path]::GetFullPath($raceDir)
if ($raceDirFull.StartsWith([System.IO.Path]::GetFullPath($env:TEMP)) -and (Test-Path $raceDirFull)) {
    Remove-Item -Recurse -Force $raceDirFull
}

Write-Host ""
if ($failed -eq 0) {
    Write-Host "✅ P4 电子病历 / 接诊队列 验证全部通过（通过 $passed 项）" -ForegroundColor Green
    exit 0
} else {
    Write-Host "❌ 失败 $failed 项（通过 $passed 项）" -ForegroundColor Red
    exit 1
}
