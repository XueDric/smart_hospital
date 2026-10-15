# SPDX-License-Identifier: MIT
#
# ===== previsit-bridge-check.ps1 —— 改进 1「预问诊真正交给医生」端到端验证 =====
#
# 要解决的问题（见 docs/CLINIC-LOOP-IMPROVEMENTS-2026-10-14.md §改进 1）：
#   患者填完预问诊单后，**医生在服务端根本读不到** —— "这次问诊属于哪次挂号"
#   只存在于患者**本机**的 SessionStore 里（换设备就断、医生端无从知道）。
#   本改进把绑定关系放到服务端，并给医生一个可读的摘要端点。
#
# 覆盖：
#   [1] 挂号带 previsit_id ⇒ 服务端绑定成功（previsit_bound=true，库里 appointment_id 已写）
#   [2] ★ 幂等重放（同 token 再提一次 ⇒ 200 AlreadyBooked）后**绑定结论不翻转**
#   [3] 归属：别人的会话 / 不存在的会话 ⇒ 挂号照常成功但**绝不误绑**（不落库）
#   [4] 医生侧 GET /doctor/visits/:id/previsit：本单医生可读、别人 404、患者 403
#       ★ 未绑定但患者有历史会话 ⇒ bound=false 回退（且只认**已完成**的会话）
#   [5] 病历 previsit_ref：来源痕迹如实（只记患者自述写进去的段）
#
# 用法：
#   .\previsit-bridge-check.ps1 -Base http://127.0.0.1:18092 -AdminPw <口令>
#
# ⚠⚠ **不要与 `hospital-server.exe accept` 并发跑**：accept 的 `hResetAll` 会整表清空
#   业务表（appointment / schedule / doctor / department / patient）⇒ 本脚本夹具会被
#   跑到一半删掉，表现为一片假红；两边又都会 taskkill 对方的 serve（症状是 HTTP 0）。
#   HTTP 层 e2e 与 `accept` **必须串行**（同 emr-check.ps1 顶部那段说明）。
#
# ⚠ 含中文的 PowerShell 脚本必须 **UTF-8 with BOM**（PS 5.1 否则按 ANSI 解析 → 语法报错）。

[CmdletBinding()]
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
Write-Host "=== 改进 1 预问诊 → 医生端 端到端验证 ===" -ForegroundColor Cyan
Write-Host "  目标: $Base"
Write-Host "  库  : $($My.Db)@$($My.DbHost):$($My.Port)"

# ── [0] 夹具（直接写库，精确控制前置状态）──────────────────────────────────
Write-Host ""
Write-Host "[0] 准备夹具"
$null = Invoke-MySqlScalar -My $My -Label "清病历" -Sql "DELETE FROM medical_record"
$null = Invoke-MySqlScalar -My $My -Label "清会话" -Sql "DELETE FROM previsit_session"
$null = Invoke-MySqlScalar -My $My -Label "清挂号" -Sql "DELETE FROM appointment WHERE schedule_id >= 705000"
$null = Invoke-MySqlScalar -My $My -Label "清排班" -Sql "DELETE FROM schedule WHERE id >= 705000"
$null = Invoke-MySqlScalar -My $My -Label "清医生" -Sql "DELETE FROM doctor WHERE id >= 705000"
$null = Invoke-MySqlScalar -My $My -Label "清科室" -Sql "DELETE FROM department WHERE id >= 705000"
$null = Invoke-MySqlScalar -My $My -Label "清患者" -Sql "DELETE FROM patient WHERE id >= 705000"

$seedSql = @"
INSERT INTO department (id, name, code, created_at) VALUES (705001, '改进1验证科', 'PVBR', 0);
INSERT INTO doctor (id, name, department_id, title, specialty, created_at) VALUES (705001, '改进1医生甲', 705001, '主任医师', '测试', 0);
INSERT INTO doctor (id, name, department_id, title, specialty, created_at) VALUES (705002, '改进1医生乙', 705001, '住院医师', '测试', 0);
INSERT INTO schedule (id, doctor_id, department_id, work_date, period, total_num, remain_num, version, enabled, created_at) VALUES (705001, 705001, 705001, '2026-12-26', 'AM', 20, 20, 0, 1, 0);
INSERT INTO patient (id, phone, name, gender, birth_date, created_at) VALUES (705001, '13800070501', '改进1患者甲', 'M', '1990-01-01', 0);
INSERT INTO patient (id, phone, name, gender, birth_date, created_at) VALUES (705002, '13800070502', '改进1患者乙', 'F', '1992-02-02', 0);
INSERT INTO patient (id, phone, name, gender, birth_date, created_at) VALUES (705003, '13800070503', '改进1患者丙', 'F', '1993-03-03', 0);
INSERT INTO appointment (id, schedule_id, patient_id, doctor_id, department_id, visit_date, period, seq_no, status, slot_restored, created_at) VALUES (705004, 705001, 705001, 705001, 705001, '2026-12-26', 'AM', 4, 'booked', 1, 0);
INSERT INTO appointment (id, schedule_id, patient_id, doctor_id, department_id, visit_date, period, seq_no, status, slot_restored, created_at) VALUES (705005, 705001, 705003, 705001, 705001, '2026-12-26', 'AM', 5, 'booked', 1, 0);
"@
SqlFile 'seed' $seedSql
$seedCnt = RowCount "夹具行数" ("SELECT (SELECT COUNT(*) FROM department WHERE id=705001) + (SELECT COUNT(*) FROM doctor WHERE id IN (705001,705002))" +
    " + (SELECT COUNT(*) FROM schedule WHERE id=705001) + (SELECT COUNT(*) FROM patient WHERE id IN (705001,705002,705003))" +
    " + (SELECT COUNT(*) FROM appointment WHERE id IN (705004,705005))")
Check "夹具就绪（1 科室 / 2 医生 / 1 排班 / 3 患者 / 2 挂号单，期望 9 行）" ("$seedCnt" -eq '9') ("实得 $seedCnt 行")

# 会话夹具：甲：一张**已完成**（较旧）+ 一张**半途**（较新）；乙：一张已完成。
# ⚠ 半途那张 updated_at **更新**，用于证明回退路径只认"已完成"（否则会挑错单）。
$sidA = 'pvbridge-705001-A'
$sidHalf = 'pvbridge-705001-half'
$sidB = 'pvbridge-705002-B'
$formA = '{"chief":"上腹隐痛 3 天","duration":"3 天","severity":"影响睡眠","associated":"反酸","history":"高血压 5 年","allergy":"青霉素过敏"}'
$formB = '{"chief":"腰痛 1 周","duration":"1 周","severity":"轻微","associated":"无","history":"无","allergy":"无"}'
$pvSql = "INSERT INTO previsit_session (id, patient_id, turn, form_json, created_at, updated_at) VALUES ('$sidA', 705001, 6, '$formA', 1000, 1000);" + "`n" +
         "INSERT INTO previsit_session (id, patient_id, turn, form_json, created_at, updated_at) VALUES ('$sidHalf', 705001, 2, '{`"chief`":`"只答了这一项`"}', 2000, 2000);" + "`n" +
         "INSERT INTO previsit_session (id, patient_id, turn, form_json, created_at, updated_at) VALUES ('$sidB', 705002, 6, '$formB', 1500, 1500);"
SqlFile 'pv' $pvSql
$pvCnt = RowCount "会话行数" "SELECT COUNT(*) FROM previsit_session WHERE id IN ('$sidA','$sidHalf','$sidB')"
Check "会话夹具就绪（3 张，期望 3 行）" ("$pvCnt" -eq '3') ("实得 $pvCnt 行")
Check "夹具：sidA 已绑定列为空（0）" ((RowCount "sidA 绑定" "SELECT appointment_id FROM previsit_session WHERE id='$sidA'") -eq '0')

$admTok = Tok "admin" $AdminPw
$docPw = "PvBridge1pass"
$doc2Pw = "PvBridge2pass"
$patPw = "PvBridge3pass"
$null = EnsureAccount 'doc' 'pvbridge-doc' $docPw 'doctor' 705001 '改进1医生甲'
$null = EnsureAccount 'doc2' 'pvbridge-doc2' $doc2Pw 'doctor' 705002 '改进1医生乙'
$null = EnsureAccount 'pat' 'pvbridge-pat' $patPw 'patient' 705001 '改进1患者甲'
$docTok = Tok "pvbridge-doc" $docPw
$doc2Tok = Tok "pvbridge-doc2" $doc2Pw
$patTok = Tok "pvbridge-pat" $patPw
Check "三个角色都能登录（医生甲/医生乙/患者甲）" `
      ($docTok.Length -eq 64 -and $doc2Tok.Length -eq 64 -and $patTok.Length -eq 64)

# ── [1] 挂号带 previsit_id ⇒ 服务端绑定 ────────────────────────────────────
Write-Host ""
Write-Host "[1] 挂号时把预问诊单交给这次预约（previsit_id）"
$b1 = Req 'book1' 'POST' '/api/v1/appointments' @("Authorization: Bearer $patTok") `
      ('{"schedule_id":705001,"client_token":"pvbridge-tok-1","previsit_id":"' + $sidA + '"}')
Check "挂号成功（201）" ($b1.Http -eq 201) ("HTTP $($b1.Http) $($b1.Body)")
$appt1 = [int64]$b1.Json.data.appointment_id
Check "★ 响应带 previsit_bound = true（服务端确认已绑定）" ($b1.Json.data.previsit_bound -eq $true) `
      ("previsit_bound = " + $b1.Json.data.previsit_bound)
Check "★ 库里真的写上了：previsit_session.appointment_id = $appt1" `
      ((RowCount "绑定后" "SELECT appointment_id FROM previsit_session WHERE id='$sidA'") -eq "$appt1")
$bt = Req 'bytok' 'GET' '/api/v1/appointments/by-token/pvbridge-tok-1' @("Authorization: Bearer $patTok") $null
Check "与改进 4 的 by-token 反查一致（同 id=$appt1）" ("$($bt.Json.data.appointment_id)" -eq "$appt1") `
      ("实得 $($bt.Json.data.appointment_id)")

# ── [2] ★ 幂等重放后绑定结论不翻转 ────────────────────────────────────────
# 这是**回归**断言：服务端"重放 → AlreadyBooked → 再绑一次"会走第二遍绑定；
# 而 MySQL 的 UPDATE 在"新值 = 旧值"时返回 **0 行受影响** —— 第一版实现把 0 行
# 当失败 ⇒ 重放响应谎报 previsit_bound=false（AC-P4-5 ① 抓到的就是这个）。
Write-Host ""
Write-Host "[2] ★ 幂等重放：绑定结论必须稳定"
$b2 = Req 'book2' 'POST' '/api/v1/appointments' @("Authorization: Bearer $patTok") `
      ('{"schedule_id":705001,"client_token":"pvbridge-tok-1","previsit_id":"' + $sidA + '"}')
Check "同 token 再提交 → 200 回放（不是 201）" ($b2.Http -eq 200) ("HTTP $($b2.Http)")
Check "回放拿到同一张单（$appt1）" ("$($b2.Json.data.appointment_id)" -eq "$appt1") ("实得 $($b2.Json.data.appointment_id)")
Check "★★ 回放的 previsit_bound 仍是 true（**不因重放而翻转**）" ($b2.Json.data.previsit_bound -eq $true) `
      ("previsit_bound = " + $b2.Json.data.previsit_bound)

# ── [3] 归属：别人的/不存在的会话绝不误绑 ──────────────────────────────────
Write-Host ""
Write-Host "[3] 归属：别人的会话 / 不存在的会话"
$b3 = Req 'book3' 'POST' '/api/v1/appointments' @("Authorization: Bearer $patTok") `
      ('{"schedule_id":705001,"client_token":"pvbridge-tok-3","previsit_id":"' + $sidB + '"}')
Check "拿**别人**的会话挂号：挂号仍成功（绑定失败不该拖垮挂号）" ($b3.Http -eq 201) ("HTTP $($b3.Http) $($b3.Body)")
Check "★ 且 previsit_bound = false（如实告知没绑上）" ($b3.Json.data.previsit_bound -eq $false) `
      ("previsit_bound = " + $b3.Json.data.previsit_bound)
Check "★★ 别人的会话**没有被误绑**（sidB.appointment_id 仍为 0）" `
      ((RowCount "sidB 绑定" "SELECT appointment_id FROM previsit_session WHERE id='$sidB'") -eq '0')
$b4 = Req 'book4' 'POST' '/api/v1/appointments' @("Authorization: Bearer $patTok") `
      '{"schedule_id":705001,"client_token":"pvbridge-tok-4","previsit_id":"no-such-intake-xyz"}'
Check "不存在的会话 id：挂号成功（201）" ($b4.Http -eq 201) ("HTTP $($b4.Http)")
Check "★ previsit_bound = false（不报 500、不静默假装成功）" ($b4.Json.data.previsit_bound -eq $false) `
      ("previsit_bound = " + $b4.Json.data.previsit_bound)
# 同一张单不能被第二次挂号抢走（一次自述只属于一次就诊）
$b5 = Req 'book5' 'POST' '/api/v1/appointments' @("Authorization: Bearer $patTok") `
      ('{"schedule_id":705001,"client_token":"pvbridge-tok-5","previsit_id":"' + $sidA + '"}')
Check "★ 已经绑给 $appt1 的会话，再拿去挂新单 ⇒ bound=false（不许一单两用）" `
      ($b5.Http -eq 201 -and $b5.Json.data.previsit_bound -eq $false) `
      ("HTTP $($b5.Http) bound=" + $b5.Json.data.previsit_bound)
Check "★ 且它仍绑在**原来**那张单上（$appt1）" `
      ((RowCount "绑定未变" "SELECT appointment_id FROM previsit_session WHERE id='$sidA'") -eq "$appt1")
# 不带 previsit_id：字段照样出现（=false），客户端不必区分"缺字段"与"没绑上"
$b6 = Req 'book6' 'POST' '/api/v1/appointments' @("Authorization: Bearer $patTok") `
      '{"schedule_id":705001,"client_token":"pvbridge-tok-6"}'
Check "不带 previsit_id 也能正常挂号（201）" ($b6.Http -eq 201) ("HTTP $($b6.Http)")
Check "★ 且 previsit_bound 字段**存在**并如实为 false（客户端不必区分「缺字段」与「没绑上」）" `
      (($b6.Json.data.PSObject.Properties.Name -contains 'previsit_bound') -and ($b6.Json.data.previsit_bound -eq $false)) `
      ("实际字段：" + (($b6.Json.data.PSObject.Properties.Name) -join ','))

# ── [4] 医生侧摘要端点 ────────────────────────────────────────────────────
Write-Host ""
Write-Host "[4] 医生侧：GET /api/v1/doctor/visits/:id/previsit"
$d1 = Req 'docget' 'GET' "/api/v1/doctor/visits/$appt1/previsit" @("Authorization: Bearer $docTok") $null
Check "本单医生可读（200）" ($d1.Http -eq 200) ("HTTP $($d1.Http) $($d1.Body)")
Check "★ session_id 就是绑定的那张（$sidA）" ("$($d1.Json.data.session_id)" -eq $sidA) ("实得 $($d1.Json.data.session_id)")
Check "★ bound = true（这是**本次就诊**填的）" ($d1.Json.data.bound -eq $true)
Check "completed = true / filled = total = 6" `
      ($d1.Json.data.completed -eq $true -and $d1.Json.data.filled -eq 6 -and $d1.Json.data.total -eq 6) `
      ("completed=$($d1.Json.data.completed) filled=$($d1.Json.data.filled) total=$($d1.Json.data.total)")
Check "★ 主诉如实回给出站（实得「$(SecVal $d1 'chief')」）" ((SecVal $d1 'chief') -eq '上腹隐痛 3 天')
Check "★ 槽位带**中文短名**（label），医生端不必自己维护一份映射" `
      ((@($d1.Json.data.sections)[0].label).Length -gt 0) ("label=" + (@($d1.Json.data.sections)[0].label))
Check "★ captured_at > 0（前端文案要用它说「预填于 …」）" ([int64]$d1.Json.data.captured_at -gt 0) `
      ("captured_at=" + $d1.Json.data.captured_at)
Check "★★ 出站**不含 patient_id**（医生读摘要不需要它，多给只增加泄露面）" ($d1.Body -notmatch 'patient_id')

$d2 = Req 'doc2get' 'GET' "/api/v1/doctor/visits/$appt1/previsit" @("Authorization: Bearer $doc2Tok") $null
Check "★★ 另一位医生读同一张单 → 404（与「不存在」**同码**，不是 403 枚举 oracle）" ($d2.Http -eq 404) ("HTTP $($d2.Http)")
$d3 = Req 'patget' 'GET' "/api/v1/doctor/visits/$appt1/previsit" @("Authorization: Bearer $patTok") $null
# ⚠ 患者调这个端点得到的是 **404**，不是 403：
#   患者角色**有** `QueryOwnMedicalRecord` 权限（他要读自己的病历），所以
#   `requireCan` 放行；真正挡住他的是下一步的归属校验 —— 而那里对这个端点要求
#   "这张单必须是**我的号**"，patient 身份的 doctorId=0 ⇒ 查不到 ⇒ **按不存在处理**。
#   这正是本仓的纪律：归属不匹配一律 404（403 会变成"单号是否存在"的枚举 oracle）。
Check "患者调医生端点 → 404（归属不匹配一律 404，不给枚举 oracle）" ($d3.Http -eq 404) ("HTTP $($d3.Http)")
$d4 = Req 'badid' 'GET' '/api/v1/doctor/visits/abc/previsit' @("Authorization: Bearer $docTok") $null
Check "非法 id（abc）→ 400（不是 500）" ($d4.Http -eq 400) ("HTTP $($d4.Http)")

# ★ 未绑定但患者有历史已完成会话（夹具 705004 由直接写库产生，appointment_id 从未绑过）
$d5 = Req 'fallback' 'GET' '/api/v1/doctor/visits/705004/previsit' @("Authorization: Bearer $docTok") $null
Check "★ 未绑定的单：回退到该患者最近一次**已完成**会话（200）" ($d5.Http -eq 200) ("HTTP $($d5.Http) $($d5.Body)")
Check "★★ 且 bound = false —— 前端据此换成「该患者最近一次预问诊单」的文案" ($d5.Json.data.bound -eq $false) `
      ("bound=" + $d5.Json.data.bound)
Check "★★ 回退挑的是**已完成**那张（$sidA），不是更新但半途的 $sidHalf" `
      ("$($d5.Json.data.session_id)" -eq $sidA) ("实得 $($d5.Json.data.session_id)")
$d6 = Req 'nosession' 'GET' '/api/v1/doctor/visits/705005/previsit' @("Authorization: Bearer $docTok") $null
Check "★★ 完全没有会话的患者 → 404 PREVISIT_NOT_FOUND（可判别的码，不是笼统 404）" `
      ($d6.Http -eq 404 -and $d6.Json.error.code -eq 'PREVISIT_NOT_FOUND') `
      ("HTTP $($d6.Http) code=" + $d6.Json.error.code)

# 队列徽标：只有**绑定本单**的才算（否则历史单全亮徽标）
# ⚠ 队列响应的列表字段叫 **`items`**（不是 `visits`）—— 第一版写错字段名，
#   拿到的是 `@($null)`（Count 恒为 1）⇒ 后面三条断言全假红。字段名一律照 http_p4.cj 抄。
$q = Req 'queue' 'GET' '/api/v1/doctor/visits' @("Authorization: Bearer $docTok") $null
$items = @($q.Json.data.items)
$it1 = @($items | Where-Object { $_.appointment_id -eq $appt1 } | Select-Object -First 1)
$it4 = @($items | Where-Object { $_.appointment_id -eq 705004 } | Select-Object -First 1)
Check "队列里能查到本单（$appt1）" ($it1.Count -eq 1) ("队列共 $($items.Count) 条")
Check "★ 队列里本单 previsit_ready = true" ($it1[0].previsit_ready -eq $true)
Check "★★ 未绑定的单 previsit_ready = false（徽标 = 本次就诊有自述，不是「这患者填过」）" `
      ($it4[0].previsit_ready -eq $false)
Check "★ 队列项**不含** previsit_ref（列表不出正文/来源，出站最小化）" `
      (($it1[0].PSObject.Properties.Name) -notcontains 'previsit_ref')

# ── [5] 病历来源痕迹 previsit_ref ─────────────────────────────────────────
Write-Host ""
Write-Host "[5] 病历里的来源痕迹（previsit_ref）"
$w1 = Req 'write1' 'PUT' "/api/v1/doctor/visits/$appt1/record" @("Authorization: Bearer $docTok") `
      ('{"use_intake_session":"' + $sidA + '","diagnosis":"慢性胃炎"}')
Check "带 use_intake_session 存草稿 → 200" ($w1.Http -eq 200) ("HTTP $($w1.Http) $($w1.Body)")
Check "★★ 响应带 previsit_ref（**对象**，不是 JSON 字符串）" ($null -ne $w1.Json.data.previsit_ref) `
      ("previsit_ref 类型：" + $w1.Json.data.previsit_ref.GetType().Name)
Check "★★ previsit_ref.session_id = $sidA" ("$($w1.Json.data.previsit_ref.session_id)" -eq $sidA) `
      ("实得 $($w1.Json.data.previsit_ref.session_id)")
$keys = SecKeys $w1
Check "★ 痕迹只列患者自述写进去的段（实得：$($keys -join ',')）" `
      (($keys -contains 'chief_complaint') -and ($keys -contains 'present_illness') -and ($keys -contains 'past_history') -and ($keys -contains 'allergy_history'))
Check "★★ 医生自己要写的段**不在**痕迹里（诊断不是患者说的）" (-not ($keys -contains 'diagnosis')) ("keys=$($keys -join ',')")
Check "★ 现病史由病程/程度/伴随合成（实得「$(SecVal $w1 'present_illness')」）" `
      ((SecVal $w1 'present_illness') -match '病程' -and (SecVal $w1 'present_illness') -match '程度')
Check "previsit_ref.at > 0" ([int64]$w1.Json.data.previsit_ref.at -gt 0) ("at=" + $w1.Json.data.previsit_ref.at)
# ⚠ 单独取一次响应再断言：`(Req …).Body` 这种"括号调用 + 取属性"在 PS 5.1 里会被
#   解析器拒掉（实测报「表达式或语句中包含意外的标记')'」）—— 拆成两行最省事。
$ql = Req 'list' 'GET' '/api/v1/doctor/visits' @("Authorization: Bearer $docTok") $null
Check "★ 列表接口不给 previsit_ref（只给正文时给）" ($ql.Body -notmatch 'previsit_ref')

# 医生改写某一段后：痕迹是**初值来源快照**，不随改写而变（语义必须是"最初从哪来"）
$w2 = Req 'write2' 'PUT' "/api/v1/doctor/visits/$appt1/record" @("Authorization: Bearer $docTok") `
      ('{"use_intake_session":"' + $sidA + '","chief_complaint":"医生改写后的主诉"}')
Check "二次保存成功" ($w2.Http -eq 200) ("HTTP $($w2.Http)")
Check "★★ 已有病历不吃预填：医生改写生效（实得「$(SecVal $w2 'chief_complaint')」）" `
      ((SecVal $w2 'chief_complaint') -eq '医生改写后的主诉')
Check "★ 未被改写的段仍是预填值（过敏史 = 青霉素过敏）" ((SecVal $w2 'allergy_history') -eq '青霉素过敏')
Check "★★ 痕迹保持为初值来源快照（同一 session_id，段集合不变）" `
      (("$($w2.Json.data.previsit_ref.session_id)" -eq $sidA) -and ((SecKeys $w2).Count -eq $keys.Count))

Write-Host ""
if ($failed -eq 0) {
    Write-Host "✅ 改进 1（预问诊 → 医生端）验证全部通过（通过 $passed 项）" -ForegroundColor Green
    exit 0
} else {
    Write-Host "❌ 改进 1 验证失败 $failed 项（通过 $passed 项）" -ForegroundColor Red
    exit 1
}
