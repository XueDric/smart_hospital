# ===== revision-check.ps1 —— 改进 3「病历修订历史」端到端验证 =====
#
# 覆盖：草稿不留痕 / 定稿落 v1 / 单版详情与 404 / diff 的拒绝语义 /
#       解锁必须给理由（按字符算）/ 医生与患者都 403 或 404 / 管理员解锁落 v2 /
#       改完再定稿落 v3 且逐段可比 / 幂等不重复写审计 / 归属严格 / 患者侧不受影响。
#
# 用法：pwsh -File .\revision-check.ps1 -AdminPw <create-admin 打印的口令>
# ⚠ 与 `hospital-server.exe accept` **串行**跑（accept 会清业务表）。
# ⚠ 本文件必须 UTF-8 **with BOM**（同目录其他 .ps1 一致），否则 PS 5.1 按 ANSI 解析中文。
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
Write-Host "=== 改进 3 病历修订历史 端到端验证 ===" -ForegroundColor Cyan
Write-Host "  目标: $Base"
Write-Host "  库  : $($My.Db)@$($My.DbHost):$($My.Port)"

# ── [0] 夹具（直接写库，精确控制前置状态）────────────────────────────────
Write-Host ""
Write-Host "[0] 准备夹具"
$null = Invoke-MySqlScalar -My $My -Label "清修订" -Sql "DELETE FROM medical_record_revision"
$null = Invoke-MySqlScalar -My $My -Label "清病历" -Sql "DELETE FROM medical_record"
$null = Invoke-MySqlScalar -My $My -Label "清挂号" -Sql "DELETE FROM appointment WHERE id >= 704000"
$null = Invoke-MySqlScalar -My $My -Label "清排班" -Sql "DELETE FROM schedule WHERE id >= 704000"
$null = Invoke-MySqlScalar -My $My -Label "清医生" -Sql "DELETE FROM doctor WHERE id >= 704000"
$null = Invoke-MySqlScalar -My $My -Label "清科室" -Sql "DELETE FROM department WHERE id >= 704000"
$null = Invoke-MySqlScalar -My $My -Label "清患者" -Sql "DELETE FROM patient WHERE id >= 704000"
# ⚠ 上一轮没跑完（或此前的版本**没有**清账号这一步）时，rev3-* 会留在真库里；
#   建号走 409 分支虽然会重设口令，但「库里带着上一轮账号」本身就不是干净起点，
#   而 uk_auth_user_login 唯一键让这条路径**静默复用旧账号**（2026-10-16 第三方复查 S1）。
$null = Invoke-MySqlScalar -My $My -Label "清账号" -Sql "DELETE FROM auth_user WHERE login_name LIKE 'rev3-%'"

$seedSql = @"
INSERT INTO department (id, name, code, created_at) VALUES (704001, '改进3验证科', 'REV3', 0);
INSERT INTO doctor (id, name, department_id, title, specialty, created_at) VALUES (704001, '改进3医生甲', 704001, '主任医师', '测试', 0);
INSERT INTO doctor (id, name, department_id, title, specialty, created_at) VALUES (704002, '改进3医生乙', 704001, '住院医师', '测试', 0);
INSERT INTO schedule (id, doctor_id, department_id, work_date, period, total_num, remain_num, version, enabled, created_at) VALUES (704001, 704001, 704001, '2026-12-28', 'AM', 20, 20, 0, 1, 0);
INSERT INTO patient (id, phone, name, gender, birth_date, created_at) VALUES (704001, '13800070401', '改进3患者甲', 'M', '1990-01-01', 0);
INSERT INTO patient (id, phone, name, gender, birth_date, created_at) VALUES (704002, '13800070402', '改进3患者乙', 'F', '1991-02-02', 0);
INSERT INTO appointment (id, schedule_id, patient_id, doctor_id, department_id, visit_date, period, seq_no, status, slot_restored, created_at) VALUES (704004, 704001, 704001, 704001, 704001, '2026-12-28', 'AM', 1, 'visiting', 1, 0);
INSERT INTO appointment (id, schedule_id, patient_id, doctor_id, department_id, visit_date, period, seq_no, status, slot_restored, created_at) VALUES (704005, 704001, 704001, 704002, 704001, '2026-12-28', 'AM', 2, 'visiting', 1, 0);
"@
SqlFile 'seed' $seedSql
$seedCnt = RowCount "夹具行数" ("SELECT (SELECT COUNT(*) FROM department WHERE id=704001) + (SELECT COUNT(*) FROM doctor WHERE id IN (704001,704002))" +
    " + (SELECT COUNT(*) FROM schedule WHERE id=704001) + (SELECT COUNT(*) FROM patient WHERE id IN (704001,704002))" +
    " + (SELECT COUNT(*) FROM appointment WHERE id IN (704004,704005))")
Check "夹具就绪（1 科室 / 2 医生 / 1 排班 / 2 患者 / 2 挂号单，期望 8 行）" ("$seedCnt" -eq '8') ("实得 $seedCnt 行")

# ⚠ 管理员令牌必须**先**取：`EnsureAccount` 内部用 `$admTok` 调 `/api/v1/admin/users`，
#   建账号的调用若写在它前面 ⇒ 空令牌 ⇒ 静默建不出账号 ⇒ 后面登录全 401（实测踩过）。
$admTok = Tok "admin" $AdminPw

$docPw = "Rev3Doctor1pass"
$doc2Pw = "Rev3Doctor2pass"
$patPw = "Rev3Patient1pass"
$null = EnsureAccount 'doc' 'rev3-doc' $docPw 'doctor' 704001 '改进3医生甲'
$null = EnsureAccount 'doc2' 'rev3-doc2' $doc2Pw 'doctor' 704002 '改进3医生乙'
$null = EnsureAccount 'pat' 'rev3-pat' $patPw 'patient' 704001 '改进3患者甲'
$docTok = Tok "rev3-doc" $docPw
$doc2Tok = Tok "rev3-doc2" $doc2Pw
$patTok = Tok "rev3-pat" $patPw
Check "四个角色都能登录（管理员 / 医生甲 / 医生乙 / 患者甲）" `
      ($admTok.Length -eq 64 -and $docTok.Length -eq 64 -and $doc2Tok.Length -eq 64 -and $patTok.Length -eq 64)

$appt = 704004
$apptOther = 704005
$docHdr = @("Authorization: Bearer $docTok")
$doc2Hdr = @("Authorization: Bearer $doc2Tok")
$admHdr = @("Authorization: Bearer $admTok")
$patHdr = @("Authorization: Bearer $patTok")

# ── [1] 草稿不留痕 ───────────────────────────────────────────────────────
Write-Host ""
Write-Host "[1] 草稿保存（不留痕）：写满七段"
$putBody = '{"chief_complaint":"上腹隐痛 3 天","present_illness":"3 天前起病，餐后加重","past_history":"高血压 5 年","allergy_history":"无","physical_exam":"上腹轻压痛","diagnosis":"慢性胃炎","treatment":"奥美拉唑 20mg qd"}'
$r = Req 'put1' 'PUT' "/api/v1/doctor/visits/$appt/record" $docHdr $putBody
Check "① 保存草稿成功（200）" ($r.Http -eq 200) ("HTTP $($r.Http) $($r.Body)")
$r = Req 'rev0' 'GET' "/api/v1/doctor/visits/$appt/record/revisions" $docHdr $null
$rCount = -1
if ($r.Json) { $rCount = [int]$r.Json.data.count }
Check "★ ① 草稿**不**产生版本（count=0，实得 $rCount）" ($r.Http -eq 200 -and $rCount -eq 0)
Check "① 库里零修订行" ((RowCount "修订数" "SELECT COUNT(*) FROM medical_record_revision WHERE appointment_id=$appt") -eq '0')

# ── [2] 定稿 ⇒ v1 ────────────────────────────────────────────────────────
Write-Host ""
Write-Host "[2] 定稿 ⇒ 落下第 1 版"
$r = Req 'lock1' 'POST' "/api/v1/doctor/visits/$appt/record/lock" $docHdr $null
$rv = -1
$st = ""
if ($r.Json) { $rv = [int]$r.Json.data.revision_version; $st = [string]$r.Json.data.status }
Check "② 定稿成功（200）" ($r.Http -eq 200) ("HTTP $($r.Http) $($r.Body)")
Check "★ ② 响应带 revision_version=1（实得 $rv）" ($rv -eq 1)
Check "★ ② 病历状态是 locked（实得 $st）" ($st -eq 'locked')
Check "② 库里正好一版修订" ((RowCount "修订数" "SELECT COUNT(*) FROM medical_record_revision WHERE appointment_id=$appt") -eq '1')

$r = Req 'rev1' 'GET' "/api/v1/doctor/visits/$appt/record/revisions" $docHdr $null
$it = $null
if ($r.Json) { $it = @($r.Json.data.items)[0] }
Check "② 列表 count=1、version=1、operation=lock、reason 空" `
      ($null -ne $it -and [int]$it.version -eq 1 -and [string]$it.operation -eq 'lock' -and [string]$it.reason -eq '')
Check "★ ② 操作者如实（operator_role=doctor、user_id>0）" `
      ($null -ne $it -and [string]$it.operator_role -eq 'doctor' -and [int]$it.operator_user_id -gt 0)
Check "★ ② 列表**不带正文**（版本抽屉的列表不泄露七段）" ($null -ne $it -and $null -eq $it.sections)

# ── [3] 单版详情 + 错误码 ────────────────────────────────────────────────
Write-Host ""
Write-Host "[3] 某一版详情 + 取不到就是 404"
$r = Req 'revd1' 'GET' "/api/v1/doctor/visits/$appt/record/revisions/1" $docHdr $null
$secs = @()
$diag = ""
$apptId2 = -1
$recId = -1
if ($r.Json) {
    $secs = @($r.Json.data.sections)
    $apptId2 = [int]$r.Json.data.appointment_id
    $recId = [int]$r.Json.data.record_id
    if ($secs.Count -gt 0) { $diag = [string](@($secs | Where-Object { $_.key -eq 'diagnosis' })[0].value) }
}
Check "★ ③ 详情含**七段**（实得 $($secs.Count) 段）" ($r.Http -eq 200 -and $secs.Count -eq 7)
Check "★★ ③ 详情里的正文 == 定稿前写的（诊断「$diag」）" ($diag -eq '慢性胃炎')
Check "★ ③ 详情带 record_id / appointment_id（实得 rec=$recId appt=$apptId2）" `
      ($recId -gt 0 -and $apptId2 -eq $appt)
$r = Req 'revd99' 'GET' "/api/v1/doctor/visits/$appt/record/revisions/99" $docHdr $null
$c99 = ""
if ($r.Json) { $c99 = [string]$r.Json.error.code }
Check "★ ③ 不存在的版本 ⇒ 404 REVISION_NOT_FOUND（实得 $($r.Http)/$c99）" `
      ($r.Http -eq 404 -and $c99 -eq 'REVISION_NOT_FOUND')
$r = Req 'revd0' 'GET' "/api/v1/doctor/visits/$appt/record/revisions/0" $docHdr $null
Check "③ version=0 ⇒ 400（版本号从 1 开始，不是偏移量）" ($r.Http -eq 400) ("HTTP $($r.Http)")
$r = Req 'revdabc' 'GET' "/api/v1/doctor/visits/$appt/record/revisions/abc" $docHdr $null
Check "③ version=abc ⇒ 400（不是 500）" ($r.Http -eq 400) ("HTTP $($r.Http)")

# ── [4] diff 的拒绝语义 ──────────────────────────────────────────────────
Write-Host ""
Write-Host "[4] 逐段对比（diff）的拒绝语义"
$r = Req 'diff1' 'GET' "/api/v1/doctor/visits/$appt/record/revisions/1/diff" $docHdr $null
Check "★ ④ 第一版没有上一版 ⇒ 400 要求显式 against（不返回「一切未变」的假答案）" `
      ($r.Http -eq 400) ("HTTP $($r.Http)")
$r = Req 'diff1b' 'GET' "/api/v1/doctor/visits/$appt/record/revisions/1/diff?against=1" $docHdr $null
Check "★ ④ against == version ⇒ 400（不与自己对比）" ($r.Http -eq 400) ("HTTP $($r.Http)")
$r = Req 'diff99' 'GET' "/api/v1/doctor/visits/$appt/record/revisions/1/diff?against=99" $docHdr $null
Check "④ 对比的一方不存在 ⇒ 404 REVISION_NOT_FOUND" ($r.Http -eq 404) ("HTTP $($r.Http)")

# ── [5] 解锁必须给理由 ───────────────────────────────────────────────────
Write-Host ""
Write-Host "[5] 解锁必须给理由（长度按**字符**算）"
$r = Req 'ro0' 'POST' "/api/v1/doctor/visits/$appt/record/reopen" $admHdr '{}'
$c0 = ""
if ($r.Json) { $c0 = [string]$r.Json.error.code }
Check "★★ ⑤ 没有理由 ⇒ 400 VALIDATION_FAILED（实得 $($r.Http)/$c0）" `
      ($r.Http -eq 400 -and $c0 -eq 'VALIDATION_FAILED')
$r = Req 'ro1' 'POST' "/api/v1/doctor/visits/$appt/record/reopen" $admHdr '{"reason":"太短"}'
Check "★★ ⑤ 中文理由「太短」（2 字）⇒ 仍 400（**按字符**算，不是字节）" ($r.Http -eq 400) ("HTTP $($r.Http)")
$stAfter = RowCount "状态" "SELECT status FROM medical_record WHERE appointment_id=$appt"
$revAfter = RowCount "修订数" "SELECT COUNT(*) FROM medical_record_revision WHERE appointment_id=$appt"
Check "★★ ⑤ 被拒的解锁**没有**改库（仍 locked / 仍 1 版；实得 $stAfter / $revAfter）" `
      ($stAfter -eq 'locked' -and $revAfter -eq '1')
$r = Req 'rodoc' 'POST' "/api/v1/doctor/visits/$appt/record/reopen" $docHdr '{"reason":"医生想改诊断，请解锁"}'
$c1 = ""
if ($r.Json) { $c1 = [string]$r.Json.error.code }
Check "★★ ⑤ 医生调解锁 ⇒ 403 FORBIDDEN_ROLE（实得 $($r.Http)/$c1）" `
      ($r.Http -eq 403 -and $c1 -eq 'FORBIDDEN_ROLE')
$r = Req 'ropat' 'POST' "/api/v1/doctor/visits/$appt/record/reopen" $patHdr '{"reason":"患者想改诊断，请解锁"}'
Check "★ ⑤ 患者调解锁 ⇒ 403（权限矩阵先拦）" ($r.Http -eq 403) ("HTTP $($r.Http)")

# ── [6] 管理员带理由解锁 ⇒ v2 ────────────────────────────────────────────
Write-Host ""
Write-Host "[6] 管理员带理由解锁 ⇒ 第 2 版（内容 = 解锁前那一版）"
$r = Req 'ro2' 'POST' "/api/v1/doctor/visits/$appt/record/reopen" $admHdr '{"reason":"患者要求补充过敏史，解锁重写"}'
$rv2 = -1
$st2 = ""
if ($r.Json) { $rv2 = [int]$r.Json.data.revision_version; $st2 = [string]$r.Json.data.status }
Check "⑥ 解锁成功（200）" ($r.Http -eq 200) ("HTTP $($r.Http) $($r.Body)")
Check "★ ⑥ revision_version=2（实得 $rv2）" ($rv2 -eq 2)
Check "⑥ 病历回到 draft（实得 $st2）" ($st2 -eq 'draft')
$r = Req 'rev2' 'GET' "/api/v1/doctor/visits/$appt/record/revisions" $admHdr $null
$v2 = $null
if ($r.Json) { $v2 = @($r.Json.data.items)[1] }
Check "★★ ⑥ v2 记的是**解锁前那一版**（status=locked、operation=reopen）" `
      ($null -ne $v2 -and [string]$v2.status -eq 'locked' -and [string]$v2.operation -eq 'reopen')
$v2Reason = ""
if ($null -ne $v2) { $v2Reason = [string]$v2.reason }
Check "★★ ⑥ 理由落档（实得「$v2Reason」）" ($v2Reason -eq '患者要求补充过敏史，解锁重写')
Check "★ ⑥ 操作者是 admin（如实记「谁推翻的」）" ($null -ne $v2 -and [string]$v2.operator_role -eq 'admin')

# ── [7] 改完再定稿 ⇒ v3 + 逐段对比 ──────────────────────────────────────
Write-Host ""
Write-Host "[7] 改完再定稿 ⇒ v3；diff v3↔v2 只标出真正改动的段"
$r = Req 'put2' 'PUT' "/api/v1/doctor/visits/$appt/record" $docHdr '{"allergy_history":"青霉素过敏"}'
Check "⑦ 解锁后可改（200）" ($r.Http -eq 200) ("HTTP $($r.Http) $($r.Body)")
$r = Req 'lock2' 'POST' "/api/v1/doctor/visits/$appt/record/lock" $docHdr $null
$rv3 = -1
if ($r.Json) { $rv3 = [int]$r.Json.data.revision_version }
Check "★ ⑦ 再次定稿 ⇒ revision_version=3（实得 $rv3）" ($r.Http -eq 200 -and $rv3 -eq 3)
$r = Req 'diff32' 'GET' "/api/v1/doctor/visits/$appt/record/revisions/3/diff?against=2" $docHdr $null
$cc = -1
$sectCount = -1
$changedKeys = @()
$leftAllergy = ""
$rightAllergy = ""
if ($r.Json) {
    $cc = [int]$r.Json.data.changed_count
    $diffSecs = @($r.Json.data.sections)
    $sectCount = $diffSecs.Count
    $changedKeys = @($diffSecs | Where-Object { $_.changed } | ForEach-Object { $_.key })
    $al = @($diffSecs | Where-Object { $_.key -eq 'allergy_history' })[0]
    $leftAllergy = [string]$al.left
    $rightAllergy = [string]$al.right
}
Check "★ ⑦ 对比含七段（实得 $sectCount）" ($sectCount -eq 7)
Check "★★ ⑦ 只有 allergy_history 标 changed（changed_count=$cc）" `
      ($cc -eq 1 -and $changedKeys.Count -eq 1 -and $changedKeys[0] -eq 'allergy_history')
Check "★★ ⑦ 对比的两侧值都对（「$leftAllergy」→「$rightAllergy」）" `
      ($leftAllergy -eq '无' -and $rightAllergy -eq '青霉素过敏')

# ── [8] 幂等：重复定稿不新增版本 ─────────────────────────────────────────
Write-Host ""
Write-Host "[8] 重复定稿：走幂等路径，不新增版本"
$r = Req 'lock3' 'POST' "/api/v1/doctor/visits/$appt/record/lock" $docHdr $null
$c409 = ""
if ($r.Json) { $c409 = [string]$r.Json.error.code }
Check "★ ⑧ 已锁定再定稿 ⇒ 409 EMR_LOCKED（实得 $($r.Http)/$c409）" `
      ($r.Http -eq 409 -and $c409 -eq 'EMR_LOCKED')
Check "★★ ⑧ 修订仍是 3 版（幂等路径**不**写重复审计）" `
      ((RowCount "修订数" "SELECT COUNT(*) FROM medical_record_revision WHERE appointment_id=$appt") -eq '3')

# ── [9] 归属严格 ─────────────────────────────────────────────────────────
Write-Host ""
Write-Host "[9] 归属严格：别的医生 / 患者读不到修订历史"
$r = Req 'revother' 'GET' "/api/v1/doctor/visits/$appt/record/revisions" $doc2Hdr $null
Check "★★ ⑨ 另一位医生读 ⇒ 404（与「不存在」不可区分）" ($r.Http -eq 404) ("HTTP $($r.Http)")
$r = Req 'revpat' 'GET' "/api/v1/doctor/visits/$appt/record/revisions" $patHdr $null
Check "★★ ⑨ 患者读 ⇒ 404（修订历史含内部审计话术，不给患者）" ($r.Http -eq 404) ("HTTP $($r.Http)")
$r = Req 'revadm' 'GET' "/api/v1/doctor/visits/$appt/record/revisions" $admHdr $null
Check "★ ⑨ 管理员读任何单 ⇒ 200（否则审计路径对他永远 404）" ($r.Http -eq 200) ("HTTP $($r.Http)")
$r = Req 'revother2' 'GET' "/api/v1/doctor/visits/$apptOther/record/revisions" $docHdr $null
Check "⑨ 医生读别人的单 ⇒ 404" ($r.Http -eq 404) ("HTTP $($r.Http)")

# ── [10] 顺带回归：患者侧病历接口不受影响 ───────────────────────────────
Write-Host ""
Write-Host "[10] 顺带回归：患者侧病历接口不受影响"
$r = Req 'patrec' 'GET' "/api/v1/medical-records/$appt" $patHdr $null
Check "★ ⑩ 患者能读到**自己**的病历（锁定后可见，200）" ($r.Http -eq 200) ("HTTP $($r.Http)")
$r = Req 'patrec2' 'GET' "/api/v1/medical-records/$apptOther" $patHdr $null
Check "⑩ 患者的另一张单没有病历 ⇒ 404" ($r.Http -eq 404) ("HTTP $($r.Http)")
$r = Req 'patrev' 'GET' "/api/v1/doctor/visits/$appt/record/revisions/1" $patHdr $null
Check "★★ ⑩ 患者读**单版详情**同样 404（两条读取路径口径一致）" ($r.Http -eq 404) ("HTTP $($r.Http)")

# ── [11] 夹具自清（2026-10-16 第三方复查 S1）──────────────────────────────
# 此前的版本只清 704000 段业务行，**没清自己建的三个账号** —— 真库实测跑完后
# 仍留着 rev3-doc / rev3-doc2 / rev3-pat。这里补齐，并像 visit-timeline-check 那样
# 末尾自检「本次夹具残留为 0」，否则"漏清"这种问题只能靠人肉 SQL 发现。
Write-Host ""
Write-Host "[11] 夹具自清"
$null = Invoke-MySqlScalar -My $My -Label "清修订" -Sql "DELETE FROM medical_record_revision"
$null = Invoke-MySqlScalar -My $My -Label "清病历" -Sql "DELETE FROM medical_record"
$null = Invoke-MySqlScalar -My $My -Label "清挂号" -Sql "DELETE FROM appointment WHERE id >= 704000"
$null = Invoke-MySqlScalar -My $My -Label "清排班" -Sql "DELETE FROM schedule WHERE id >= 704000"
$null = Invoke-MySqlScalar -My $My -Label "清医生" -Sql "DELETE FROM doctor WHERE id >= 704000"
$null = Invoke-MySqlScalar -My $My -Label "清科室" -Sql "DELETE FROM department WHERE id >= 704000"
$null = Invoke-MySqlScalar -My $My -Label "清患者" -Sql "DELETE FROM patient WHERE id >= 704000"
$null = Invoke-MySqlScalar -My $My -Label "清账号" -Sql "DELETE FROM auth_user WHERE login_name LIKE 'rev3-%'"
$left = RowCount "查残留" ("SELECT (SELECT COUNT(*) FROM department WHERE id >= 704000)" +
    " + (SELECT COUNT(*) FROM doctor WHERE id >= 704000) + (SELECT COUNT(*) FROM schedule WHERE id >= 704000)" +
    " + (SELECT COUNT(*) FROM patient WHERE id >= 704000) + (SELECT COUNT(*) FROM appointment WHERE id >= 704000)" +
    " + (SELECT COUNT(*) FROM medical_record_revision) + (SELECT COUNT(*) FROM auth_user WHERE login_name LIKE 'rev3-%')")
Check "★★ ⑪ 结尾自检：本次夹具残留为 0（含 rev3-* 账号）" ($left -eq '0') "left=$left"

Write-Host ""
if ($failed -eq 0) {
    Write-Host "=== 结果：通过 $passed 项，失败 0 项 ===" -ForegroundColor Green
    Write-Host "REVISION-CHECK-EXIT=0" -ForegroundColor Green
    exit 0
}
Write-Host "=== 结果：通过 $passed 项，失败 $failed 项 ===" -ForegroundColor Red
Write-Host "REVISION-CHECK-EXIT=1" -ForegroundColor Red
exit 1