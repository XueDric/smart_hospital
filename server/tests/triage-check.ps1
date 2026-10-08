# P2 分诊 HTTP 端到端验证
#
# 与 `triagetest`（纯逻辑）和 `accept`（库级）的分工：
#   · triagetest —— 危急征象/科室判定的**纯逻辑**（不碰库、不调模型）
#   · accept AC-P2-* —— **验证层**（绝不给没号的推荐）在库级成立
#   · 本脚本 —— **HTTP 层**：权限、入参校验、响应形状、非流式一次性返回
#
# ⚠ 含中文的 PowerShell 脚本必须 UTF-8 with BOM。
# ⚠ header/body 走 curl **config 文件**（-K）：含空格的 -H 会被拆坏。
#
# 用法：.\triage-check.ps1 -Base http://127.0.0.1:8091 -AdminPw <口令>

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

$tmp = Join-Path $env:TEMP ("trg-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

# 自清：本脚本会造科室/排班，也可能触发限流（错口令），两边都清
$null = Invoke-MySqlScalar -My $My -Sql "DELETE FROM auth_login_attempt" -Label "清限流计数"
$null = Invoke-MySqlScalar -My $My -Sql "DELETE FROM schedule WHERE department_id BETWEEN 9200 AND 9299" -Label "清测试排班"
$null = Invoke-MySqlScalar -My $My -Sql "DELETE FROM doctor WHERE department_id BETWEEN 9200 AND 9299" -Label "清测试医生"
$null = Invoke-MySqlScalar -My $My -Sql "DELETE FROM department WHERE id BETWEEN 9200 AND 9299" -Label "清测试科室"

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

# ── 鉴权准备 ──────────────────────────────────────────────────────────────
$adm = DoReq 'adm' 'POST' '/api/v1/auth/login' @() ('{"login_name":"admin","password":"' + $AdminPw + '"}')
Check "管理员登录成功" ($adm.Http -eq 200) ("HTTP $($adm.Http)")
$admTok = $adm.Json.data.token

# 患者夹具（auth-check 建过；这里自己确保存在）
$pat = DoReq 'pat' 'POST' '/api/v1/auth/login' @() '{"login_name":"13800000001","password":"patient-pw-1"}'
if ($pat.Http -ne 200) { throw "患者夹具不可用（先跑 auth-check.ps1）：HTTP $($pat.Http)" }
$patTok = $pat.Json.data.token

# ── 1) 权限 ───────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "[1] 权限（分诊只对患者开放）"
$r = DoReq 'noauth' 'POST' '/api/v1/triage' @() '{"chief_complaint":"咳嗽三天"}'
Check "无令牌 → 401" ($r.Http -eq 401) ("HTTP $($r.Http)")
$r = DoReq 'asadmin' 'POST' '/api/v1/triage' @("Authorization: Bearer $admTok") '{"chief_complaint":"咳嗽三天"}'
Check "管理员调 → 403（该接口是患者侧）" ($r.Http -eq 403) ("HTTP $($r.Http)")

# ── 2) 入参校验 ───────────────────────────────────────────────────────────
Write-Host ""
Write-Host "[2] 入参校验"
$r = DoReq 'nobody' 'POST' '/api/v1/triage' @("Authorization: Bearer $patTok") '{}'
Check "缺 chief_complaint → 400 VALIDATION_FAILED" `
      ($r.Http -eq 400 -and $r.Json.error.code -eq 'VALIDATION_FAILED') ("HTTP $($r.Http)")
$r = DoReq 'empty' 'POST' '/api/v1/triage' @("Authorization: Bearer $patTok") '{"chief_complaint":"   "}'
Check "空白主诉 → 200 且 reason_code=NO_COMPLAINT（不是 400：空主诉是合法输入）" `
      ($r.Http -eq 200 -and $r.Json.data.reason_code -eq 'NO_COMPLAINT') `
      ("HTTP $($r.Http) reason=$($r.Json.data.reason_code)")

# ── 3) 危急征象：HTTP 层也要挡住 ──────────────────────────────────────────
Write-Host ""
Write-Host "[3] ★ 危急征象兜底（HTTP 层）"
$r = DoReq 'urgent' 'POST' '/api/v1/triage' @("Authorization: Bearer $patTok") `
     '{"chief_complaint":"我父亲胸痛，出汗，已经半小时了"}'
Check "★ red_flag = true" ($r.Http -eq 200 -and $r.Json.data.red_flag -eq $true) ("HTTP $($r.Http)")
Check "★ reason_code = RED_FLAG" ($r.Json.data.reason_code -eq 'RED_FLAG') ("$($r.Json.data.reason_code)")
Check "★★ 危急时**不给任何**科室推荐（count = 0）" ($r.Json.data.count -eq 0) ("count=$($r.Json.data.count)")
Check "给患者的说明非空" ($r.Json.data.patient_note.Length -gt 0)
# ★ 内部依据**不得**出现在响应里（暴露词表结构 = 可被试探绕过）
Check "★ 内部依据 red_flag_evidence **不在**响应里" (-not ($r.Body -match 'red_flag_evidence'))

# ── 4) ★★ 核心：绝不给没号的推荐（HTTP 端到端）────────────────────────────
Write-Host ""
Write-Host "[4] ★★ 绝不给没有号的推荐（HTTP 端到端）"
# 造一个"呼吸内科"但**只有一张约满的排班**
$null = Invoke-MySqlScalar -My $My -Sql "INSERT INTO department (id,name,code,created_at) VALUES (9201,'呼吸内科','T9201',0)" -Label "建科室"
$null = Invoke-MySqlScalar -My $My -Sql "INSERT INTO doctor (id,name,department_id,title,specialty,created_at) VALUES (9201,'测试李医生',9201,'主任医师','呼吸',0)" -Label "建医生"
$null = Invoke-MySqlScalar -My $My -Sql "INSERT INTO schedule (id,doctor_id,department_id,work_date,period,total_num,remain_num,version,enabled,created_at) VALUES (9201,9201,9201,'2026-12-15','AM',5,0,0,1,0)" -Label "建约满排班"
$r = DoReq 'full' 'POST' '/api/v1/triage' @("Authorization: Bearer $patTok") '{"chief_complaint":"咳嗽三天有痰"}'
$hasFull = $false
if ($r.Json.data.options) { $hasFull = @($r.Json.data.options | Where-Object { $_.schedule_id -eq 9201 }).Count -gt 0 }
Check "★★ 约满（remain_num=0）的排班**不得**出现在推荐里" (-not $hasFull) `
      ("reason=$($r.Json.data.reason_code) count=$($r.Json.data.count)")

# 给它补上号源 → 现在**应该**能推荐（反证：不是"永远不推荐呼吸内科"）
$null = Invoke-MySqlScalar -My $My -Sql "UPDATE schedule SET remain_num = 3 WHERE id = 9201" -Label "补号源"
$r = DoReq 'avail' 'POST' '/api/v1/triage' @("Authorization: Bearer $patTok") '{"chief_complaint":"咳嗽三天有痰"}'
$okRec = $false
if ($r.Json.data.options) { $okRec = @($r.Json.data.options | Where-Object { $_.schedule_id -eq 9201 }).Count -gt 0 }
Check "★ 反向：有号后**能**推荐呼吸内科（证明上一条不是'永远不推荐'）" $okRec `
      ("reason=$($r.Json.data.reason_code) count=$($r.Json.data.count)")
Check "推荐的排班 remain_num > 0" `
      ($r.Json.data.options[0].remain_num -gt 0) ("remain_num=$($r.Json.data.options[0].remain_num)")
Check "结论非流式一次性返回（options 与 count 同体）" `
      (($null -ne $r.Json.data.options) -and ($null -ne $r.Json.data.count))

# ── 5) 响应形状与安全 ─────────────────────────────────────────────────────
Write-Host ""
Write-Host "[5] 响应形状 / 三态标注"
$r = DoReq 'shape' 'POST' '/api/v1/triage' @("Authorization: Bearer $patTok") '{"chief_complaint":"咳嗽三天有痰"}'
Check "source 如实标注为 rules（本轮**未接**真模型）" ($r.Json.data.source -eq 'rules') ("source=$($r.Json.data.source)")
Check "含 truncated 字段（截断不静默）" ($null -ne $r.Json.data.truncated)
Check "响应里不含 red_flag_evidence（内部依据不外泄）" (-not ($r.Body -match 'red_flag_evidence'))

# 超长主诉：应被截断而不是 500
$long = '咳嗽' * 400
$r = DoReq 'long' 'POST' '/api/v1/triage' @("Authorization: Bearer $patTok") ('{"chief_complaint":"' + $long + '"}')
Check "超长主诉（1200 字）→ 200 且 truncated=true（不是 500）" `
      ($r.Http -eq 200 -and $r.Json.data.truncated -eq $true) ("HTTP $($r.Http) truncated=$($r.Json.data.truncated)")

# ── 6) 越权：患者 id 从令牌取，参数无效 ───────────────────────────────────
Write-Host ""
Write-Host "[6] ★ 越权尝试（分诊不涉及他人数据，但确认参数不被信任）"
$r = DoReq 'peek' 'POST' ('/api/v1/triage?patient_id=99999') @("Authorization: Bearer $patTok") '{"chief_complaint":"咳嗽三天有痰"}'
Check "传 patient_id 参数不影响结果（仍正常返回本患者可挂号源）" ($r.Http -eq 200) ("HTTP $($r.Http)")

# 清理
$null = Invoke-MySqlScalar -My $My -Sql "DELETE FROM schedule WHERE department_id BETWEEN 9200 AND 9299" -Label "清测试排班"
$null = Invoke-MySqlScalar -My $My -Sql "DELETE FROM doctor WHERE department_id BETWEEN 9200 AND 9299" -Label "清测试医生"
$null = Invoke-MySqlScalar -My $My -Sql "DELETE FROM department WHERE id BETWEEN 9200 AND 9299" -Label "清测试科室"
$null = Invoke-MySqlScalar -My $My -Sql "DELETE FROM auth_login_attempt" -Label "收尾清计数"
Remove-Item $tmp -Recurse -Force

Write-Host ""
if ($fail -eq 0) {
    Write-Host "✅ P2 分诊 HTTP 端到端验证全部通过"
    exit 0
} else {
    Write-Host "❌ P2 分诊 HTTP 端到端验证失败 $fail 项"
    exit 1
}
