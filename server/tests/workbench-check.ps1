# ===== workbench-check.ps1 —— 改进 2「医生录入工作台」服务端端到端验证 =====
#
# 覆盖：既往病历端点（归属三闸门 / 隐私 404 不给枚举 oracle / 只看已定稿 /
#      exclude_appointment_id / limit 上限与非法回落 / 就診上下文与正文/
#      乐观锁 expected_updated_at（正确、过期 409 + 当前版本回报、非整数 400、
#      不带=向后兼容、新建不校验、已定稿时 EMR_LOCKED 优先、他人 404）。
#
# 用法：pwsh -File .\workbench-check.ps1 -AdminPw <create-admin 打印的口令>
# ⚠ 与 `hospital-server.exe accept` **串行**跑（accept 会清业务表）。
# ⚠ 必须 UTF-8 **with BOM**（PS 5.1 否则按 ANSI 解析中文）。
#
param(
    [string]$Base = "http://127.0.0.1:18092",
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

# 用 curl 配置文件发请求（**不用 -d '...'**：PowerShell 会破坏 JSON 引号 —— 见 P2 踩坑）
function Req($tag, $method, $path, $headers, $jsonBody) {
    $cfg = Join-Path $env:TEMP ("pvb_" + $tag + ".cfg")
    $lines = @("request = `"$method`"", "silent", "write-out = `"\n__M__%{http_code}`"")
    foreach ($h in $headers) { $lines += "header = `"$h`"" }
    if ($null -ne $jsonBody) {
        $bf = Join-Path $env:TEMP ("pvb_" + $tag + ".json")
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
    if ($r.Http -ne 200) { throw "登录失败 $login ($($r.Http)): $($r.Body)" }
    return ($r.Body | ConvertFrom-Json).data.token
}
function SqlFile($name, $sql) {
    $p = Join-Path $env:TEMP ("pvb_" + $name + ".sql")
    [System.IO.File]::WriteAllText($p, $sql, (New-Object System.Text.UTF8Encoding($false)))
    Invoke-MySqlFile -My $My -Path ($p -replace '\\','/')
}
function RowCount($label, $sql) {
    return ("$(Invoke-MySqlScalar -My $My -Label $label -Sql $sql)").Trim()
}
# 建账号（201 新建 / 409 已存在）并把口令设成已知值，返回 auth_user.id。
# ⚠ `:id` 是 **auth_user.id**（自增主键），不是 ref_id —— 拿 ref_id 去调会 404 且口令没变。
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
# 取响应里 sections 中某段的 value（不存在 ⇒ 空串）。
# ⚠ 参数是 `Req` 返回的**整个包装对象**（含 Http/Body/Json），所以走 `.Json.data`
#   —— 第一版写成 `.data`，于是每次都取到空串、四条断言假红（实测）。
function SecVal($resp, $key) {
    if ($null -eq $resp -or $null -eq $resp.Json -or $null -eq $resp.Json.data -or $null -eq $resp.Json.data.sections) { return "" }
    $s = @($resp.Json.data.sections | Where-Object { $_.key -eq $key } | Select-Object -First 1)
    if ($s.Count -eq 0) { return "" }
    return [string]$s[0].value
}
function SecKeys($resp) {
    if ($null -eq $resp -or $null -eq $resp.Json -or $null -eq $resp.Json.data -or $null -eq $resp.Json.data.previsit_ref) { return @() }
    return @($resp.Json.data.previsit_ref.sections)
}
Write-Host ""
Write-Host "=== 改进 2 医生工作台 端到端验证 ===" -ForegroundColor Cyan
Write-Host "  目标: $Base"
Write-Host "  库  : $($My.Db)@$($My.DbHost):$($My.Port)"

# ── [0] 夹具（直接写库，精确控制前置状态）────────────────────────────────
Write-Host ""
Write-Host "[0] 准备夹具"
$null = Invoke-MySqlScalar -My $My -Label "清病历" -Sql "DELETE FROM medical_record"
$null = Invoke-MySqlScalar -My $My -Label "清挂号" -Sql "DELETE FROM appointment WHERE id >= 703000"
$null = Invoke-MySqlScalar -My $My -Label "清排班" -Sql "DELETE FROM schedule WHERE id >= 703000"
$null = Invoke-MySqlScalar -My $My -Label "清医生" -Sql "DELETE FROM doctor WHERE id >= 703000"
$null = Invoke-MySqlScalar -My $My -Label "清科室" -Sql "DELETE FROM department WHERE id >= 703000"
$null = Invoke-MySqlScalar -My $My -Label "清患者" -Sql "DELETE FROM patient WHERE id >= 703000"
$seedSql = @"
INSERT INTO department (id, name, code, created_at) VALUES (703001, '改进2验证科', 'WB2', 0);
INSERT INTO doctor (id, name, department_id, title, specialty, created_at) VALUES (703001, '改进2医生甲', 703001, '主任医师', '测试', 0);
INSERT INTO doctor (id, name, department_id, title, specialty, created_at) VALUES (703002, '改进2医生乙', 703001, '住院医师', '测试', 0);
INSERT INTO schedule (id, doctor_id, department_id, work_date, period, total_num, remain_num, version, enabled, created_at) VALUES (703001, 703001, 703001, '2026-12-29', 'AM', 20, 20, 0, 1, 0);
INSERT INTO patient (id, phone, name, gender, birth_date, created_at) VALUES (703001, '13800070301', '改进2患者甲', 'M', '1990-01-01', 0);
INSERT INTO patient (id, phone, name, gender, birth_date, created_at) VALUES (703002, '13800070302', '改进2患者乙', 'F', '1991-02-02', 0);
INSERT INTO appointment (id, schedule_id, patient_id, doctor_id, department_id, visit_date, period, seq_no, status, slot_restored, created_at) VALUES (703004, 703001, 703001, 703001, 703001, '2026-12-29', 'AM', 1, 'visiting', 1, 0);
INSERT INTO appointment (id, schedule_id, patient_id, doctor_id, department_id, visit_date, period, seq_no, status, slot_restored, created_at) VALUES (703005, 703001, 703001, 703002, 703001, '2026-12-29', 'AM', 2, 'visiting', 1, 0);
INSERT INTO appointment (id, schedule_id, patient_id, doctor_id, department_id, visit_date, period, seq_no, status, slot_restored, created_at) VALUES (703006, 703001, 703001, 703001, 703001, '2026-12-29', 'AM', 3, 'visiting', 1, 0);
INSERT INTO appointment (id, schedule_id, patient_id, doctor_id, department_id, visit_date, period, seq_no, status, slot_restored, created_at) VALUES (703007, 703001, 703001, 703001, 703001, '2026-12-29', 'AM', 4, 'visiting', 1, 0);
"@
SqlFile "wb_seed" $seedSql

$admTok = Tok "admin" $AdminPw
# ⚠ 必须检查建号结果：口令强度不够（< 8 位）或 ref_id 不存在时建号**静默失败**，
#   随后登录全 401，而报错点在 Tok 里、看不出是建号的问题（第一次就踩了：口令写成 7 位）。
$a1 = EnsureAccount "wbdoc"  "wb-doc"  "Wb1pass9" "doctor"  703001 "改进2医生甲"
$a2 = EnsureAccount "wbdoc2" "wb-doc2" "Wb2pass9" "doctor"  703002 "改进2医生乙"
$a3 = EnsureAccount "wbpat"  "wb-pat"  "Wb3pass9" "patient" 703001 "改进2患者甲"
Check "① 三个账号都建好（user_id > 0）" ($a1.UserId -gt 0 -and $a2.UserId -gt 0 -and $a3.UserId -gt 0) "doc=$($a1.UserId) doc2=$($a2.UserId) pat=$($a3.UserId) http=$($a1.Http)/$($a2.Http)/$($a3.Http)"
$docTok  = Tok "wb-doc"  "Wb1pass9"
$doc2Tok = Tok "wb-doc2" "Wb2pass9"
$patTok  = Tok "wb-pat"  "Wb3pass9"

# ── [1] 造两份病历：703004 定稿（既往）、703006 草稿（不得外泄）───────────
Write-Host ""
Write-Host "[1] 造病历（一份定稿、一份草稿）"
$full703004 = '{"chief_complaint":"间断上腹痛 3 天","present_illness":"3 天前无明显诱因出现上腹痛，进食后加重","past_history":"无","allergy_history":"无","physical_exam":"上腹轻压痛","diagnosis":"慢性胃炎","treatment":"抑酸护胃，2 周后复诊"}'
$r = Req "wbPut4" 'PUT' '/api/v1/doctor/visits/703004/record' @("Authorization: Bearer $docTok") $full703004
Check "① PUT 草稿 703004 ⇒ 200" ($r.Http -eq 200) "HTTP $($r.Http)"
$r = Req "wbLock4" 'POST' '/api/v1/doctor/visits/703004/record/lock' @("Authorization: Bearer $docTok") $null
Check "① 定稿 703004 ⇒ 200 且 revision_version=1" ($r.Http -eq 200 -and $r.Json.data.revision_version -eq 1) "HTTP $($r.Http) ver=$($r.Json.data.revision_version)"
$draft703006 = '{"chief_complaint":"咽痛 1 天","diagnosis":"急性咽炎"}'
$r = Req "wbPut6" 'PUT' '/api/v1/doctor/visits/703006/record' @("Authorization: Bearer $docTok") $draft703006
Check "① 703006 只存草稿 ⇒ 200" ($r.Http -eq 200) "HTTP $($r.Http)"

# ── [2] 既往病历端点 ────────────────────────────────────────────────────
Write-Host ""
Write-Host "[2] 既往病历 GET /api/v1/doctor/patients/:patientId/records"
$r = Req "wbHist1" 'GET' '/api/v1/doctor/patients/703001/records' @("Authorization: Bearer $docTok") $null
Check "★★ ② 本单医生读本患者既往 ⇒ 200" ($r.Http -eq 200) "HTTP $($r.Http)"
Check "② 带正文：每份 7 段" (@($r.Json.data.items[0].sections).Count -eq 7) "段数=$(@($r.Json.data.items[0].sections).Count)"
Check "★ ② 只有已定稿：草稿单 703006 不在内" (@($r.Json.data.items | Where-Object { $_.appointment_id -eq 703006 }).Count -eq 0)
Check "② count 与 items 条数一致" ($r.Json.data.count -eq @($r.Json.data.items).Count) "count=$($r.Json.data.count) items=$(@($r.Json.data.items).Count)"
Check "② 带就診上下文（科室名/医生名）" ($r.Json.data.items[0].department_name -eq '改进2验证科') "dept=$($r.Json.data.items[0].department_name)"
Check "② 回显 patient_id（前端不必再拼）" ($r.Json.data.patient_id -eq 703001)
$r = Req "wbHist2" 'GET' '/api/v1/doctor/patients/703001/records?exclude_appointment_id=703004' @("Authorization: Bearer $docTok") $null
Check "★ ② exclude_appointment_id 排除本次 ⇒ 已定稿的它就只剩 0 条" ($r.Http -eq 200 -and $r.Json.data.count -eq 0) "HTTP $($r.Http) count=$($r.Json.data.count)"
$r = Req "wbHist3" 'GET' '/api/v1/doctor/patients/703001/records?limit=1' @("Authorization: Bearer $docTok") $null
Check "② limit=1 ⇒ 只回 1 条" ($r.Http -eq 200 -and $r.Json.data.count -eq 1) "count=$($r.Json.data.count)"
$r = Req "wbHist4" 'GET' '/api/v1/doctor/patients/703001/records?limit=abc' @("Authorization: Bearer $docTok") $null
Check "② limit 非法 ⇒ 回落默认（200 而不是 400，与患者侧一致）" ($r.Http -eq 200 -and $r.Json.data.count -ge 1) "HTTP $($r.Http) count=$($r.Json.data.count)"

# ── [3] 隐私闸门与身份矩阵 ──────────────────────────────────────────────
Write-Host ""
Write-Host "[3] 隐私闸门与身份矩阵"
$r = Req "wbHist5" 'GET' '/api/v1/doctor/patients/703002/records' @("Authorization: Bearer $docTok") $null
Check "★★ ③ 患者存在、但没在我这儿挂过号 ⇒ 404（不是 403）" ($r.Http -eq 404 -and $r.Json.error.code -eq 'APPOINTMENT_NOT_FOUND') "HTTP $($r.Http) code=$($r.Json.error.code)"
$r = Req "wbHist6" 'GET' '/api/v1/doctor/patients/999998/records' @("Authorization: Bearer $docTok") $null
Check "★★ ③ 不存在的患者 ⇒ **同一个** 404（不给枚举 oracle）" ($r.Http -eq 404 -and $r.Json.error.code -eq 'APPOINTMENT_NOT_FOUND') "HTTP $($r.Http) code=$($r.Json.error.code)"
$r = Req "wbHist7" 'GET' '/api/v1/doctor/patients/703001/records' @("Authorization: Bearer $doc2Tok") $null
Check "★ ③ 另一位**确实接诊过**该患者的医生 ⇒ 200（闸门是按医生算的）" ($r.Http -eq 200) "HTTP $($r.Http)"
$r = Req "wbHist8" 'GET' '/api/v1/doctor/patients/703001/records' @("Authorization: Bearer $patTok") $null
Check "★ ③ 患者令牌 ⇒ 403（患者没有医生档案）" ($r.Http -eq 403 -and $r.Json.error.code -eq 'FORBIDDEN_ROLE') "HTTP $($r.Http) code=$($r.Json.error.code)"
$r = Req "wbHist9" 'GET' '/api/v1/doctor/patients/0/records' @("Authorization: Bearer $docTok") $null
Check "③ patientId=0 ⇒ 400" ($r.Http -eq 400) "HTTP $($r.Http)"
$r = Req "wbHist10" 'GET' '/api/v1/doctor/patients/703001/records' @() $null
Check "③ 无令牌 ⇒ 401" ($r.Http -eq 401) "HTTP $($r.Http)"

# ── [4] 乐观锁 expected_updated_at ──────────────────────────────────────
Write-Host ""
Write-Host "[4] 乐观锁 expected_updated_at（PUT /doctor/visits/:id/record）"
$g = Req "wbGet6" 'GET' '/api/v1/doctor/visits/703006/record' @("Authorization: Bearer $docTok") $null
$ver1 = [int64]$g.Json.data.updated_at
Check "④ 读到当前版本 updated_at > 0" ($ver1 -gt 0) "ver1=$ver1"
$r = Req "wbExp1" 'PUT' '/api/v1/doctor/visits/703006/record' @("Authorization: Bearer $docTok") ('{"allergy_history":"青霉素过敏","expected_updated_at":' + $ver1 + '}')
Check "★★ ④ 带**正确** expected_updated_at ⇒ 200" ($r.Http -eq 200) "HTTP $($r.Http) code=$($r.Json.error.code)"
$ver2 = [int64]$r.Json.data.updated_at
$r = Req "wbExp2" 'PUT' '/api/v1/doctor/visits/703006/record' @("Authorization: Bearer $docTok") ('{"allergy_history":"今天改的","expected_updated_at":' + $ver1 + '}')
Check "★★ ④ 带**过期** expected_updated_at ⇒ 409 EMR_CHANGED" ($r.Http -eq 409 -and $r.Json.error.code -eq 'EMR_CHANGED') "HTTP $($r.Http) code=$($r.Json.error.code)"
Check "★★ ④ 409 里如实回报**当前**版本（updated_at/updated_by/record_id）" ($r.Json.error.fields.updated_at -eq $ver2 -and $r.Json.error.fields.updated_by -gt 0 -and $r.Json.error.fields.record_id -gt 0) "fields=$($r.Json.error.fields | ConvertTo-Json -Compress)"
$after = Req "wbGet6b" 'GET' '/api/v1/doctor/visits/703006/record' @("Authorization: Bearer $docTok") $null
Check "★★ ④ 被拒之后正文没被改动（不是「只报错但照写」）" ((SecVal $after 'allergy_history') -eq '青霉素过敏') "实得=$(SecVal $after 'allergy_history')"
$r = Req "wbExp3" 'PUT' '/api/v1/doctor/visits/703006/record' @("Authorization: Bearer $docTok") '{"allergy_history":"无","expected_updated_at":"abc"}'
Check "④ expected_updated_at 非整数 ⇒ 400 VALIDATION_FAILED" ($r.Http -eq 400 -and $r.Json.error.code -eq 'VALIDATION_FAILED') "HTTP $($r.Http) code=$($r.Json.error.code)"
$r = Req "wbExp4" 'PUT' '/api/v1/doctor/visits/703006/record' @("Authorization: Bearer $docTok") '{"allergy_history":"无"}'
Check "★ ④ 不带 expected_updated_at ⇒ 200（向后兼容，客户端可逐条上线）" ($r.Http -eq 200) "HTTP $($r.Http)"
$r = Req "wbExp5" 'PUT' '/api/v1/doctor/visits/703004/record' @("Authorization: Bearer $docTok") '{"treatment":"篡改","expected_updated_at":1}'
Check "★ ④ 已定稿的单：EMR_LOCKED 优先于 EMR_CHANGED（先讲最要紧的事）" ($r.Http -eq 409 -and $r.Json.error.code -eq 'EMR_LOCKED') "HTTP $($r.Http) code=$($r.Json.error.code)"
$r = Req "wbExp6" 'PUT' '/api/v1/doctor/visits/703007/record' @("Authorization: Bearer $docTok") '{"chief_complaint":"新建时不校验版本","expected_updated_at":12345}'
Check "★ ④ 新建单带 expected_updated_at ⇒ 200（没有「当前版本」可比）" ($r.Http -eq 200) "HTTP $($r.Http) code=$($r.Json.error.code)"
$r = Req "wbExp7" 'PUT' '/api/v1/doctor/visits/703006/record' @("Authorization: Bearer $doc2Tok") '{"allergy_history":"别的医生改的"}'
Check "★★ ③ 别的医生改**不是我的单** ⇒ 404（归属先于一切）" ($r.Http -eq 404 -and $r.Json.error.code -eq 'APPOINTMENT_NOT_FOUND') "HTTP $($r.Http) code=$($r.Json.error.code)"

# ── 汇总 ────────────────────────────────────────────────────────────────
Write-Host ""
if ($failed -eq 0) {
    Write-Host "WORKBENCH-CHECK: 通过 $passed 项，失败 0 项" -ForegroundColor Green
    exit 0
} else {
    Write-Host "WORKBENCH-CHECK: 通过 $passed 项，失败 $failed 项" -ForegroundColor Red
    exit 1
}