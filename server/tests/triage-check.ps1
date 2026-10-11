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
# ⚠ 这条断言 2026-10-09 **改过** —— 它原先写死 source -eq "rules"，理由是"本轮未接真模型"。
#   真模型接入后，**配了模型的环境下 source 会是 model**，于是这条断言在**配了模型就跑红**
#   —— 而那不是缺陷，是断言过时了。
#
# ⇒ 现在守的是**真正的不变量**：source 必须**如实**标注，且只能是这三个已知值之一。
#   注意它与 accept 里那条"未配置 ⇒ rules"是**两件事**：
#   那条测降级路径（配置为空），这条测标注合法性（配没配都成立）。
#
# ⚠ PowerShell 用 # 注释，**没有 C 风格块注释** —— 我在这里写过 /* */，
#   实测报 `CommandNotFoundException: /*`（脚本突然中止、连 [FAIL] 都没有）。
#   全仓扫过，只有这一处。
$src = $r.Json.data.source
Check "★ source 如实标注（rules / model / model:invalid 三者之一，实得「$src」）" `
      (@("rules","model","model:invalid") -contains $src) ("source=$src")
Check "含 truncated 字段（截断不静默）" ($null -ne $r.Json.data.truncated)
Check "响应里不含 red_flag_evidence（内部依据不外泄）" (-not ($r.Body -match 'red_flag_evidence'))

# 超长主诉：应被截断而不是 500
$long = '咳嗽' * 400
$r = DoReq 'long' 'POST' '/api/v1/triage' @("Authorization: Bearer $patTok") ('{"chief_complaint":"' + $long + '"}')
Check "超长主诉（1200 字）→ 200 且 truncated=true（不是 500）" `
      ($r.Http -eq 200 -and $r.Json.data.truncated -eq $true) ("HTTP $($r.Http) truncated=$($r.Json.data.truncated)")

# ── 5b) ★★ 宽度混排（ASCII 窄字符 + 汉字宽字符）不得 500 ──────────────────
Write-Host ""
Write-Host "[5b] ★★ 宽度混排：真实临床写法不得 500（第五份复查缺陷）"
# ── 这一节守的是第五份复查抓出的严重缺陷 ─────────────────────────────────
# 否定窗口的字节/字符换算取错了参照点（取的是"片段开头前 4 个字符"的字节数，
# 而不是"命中词之前 4 个字符"的字节数），于是当片段以 ASCII 开头而命中词前是汉字时，
# `from` 落在多字节字符**中间** ⇒ 切出非法 UTF-8 ⇒ **普通主诉直接 HTTP 500**。
#
# 实测触发条件极常见：CT显示没有胸痛 / BP160没有胸痛 / 1234没有胸痛 / aaaa没有胸痛
# 而"血压160没有胸痛"/"糖尿病10年没有胸痛"/"aaa没有呕血"却正常 ——
# 因为它们的宽度组合恰好让偏移落在字符边界上。
#
# ⚠ 为什么 triagetest 当时没抓到：所有否定用例都是**等宽纯汉字**（"没有胸痛"），
#   边界永远不落在字符中间。所以本节的用例**必须**含窄+宽混排 ——
#   这正是"逐点修 vs 按类别扫"的教训。
$mixCases = @(
    'CT显示没有胸痛', 'BP160没有胸痛', '1234没有胸痛', 'aaaa没有胸痛',
    'aaaa持续头痛', '血压160没有胸痛', '糖尿病10年没有胸痛', 'aaa没有呕血',
    '男65岁，没有胸闷，只是咳嗽', 'x1否认呕血'
)
$mixBad = @()
foreach ($c in $mixCases) {
    $r = DoReq ('mx' + [Guid]::NewGuid().ToString('N').Substring(0,6)) 'POST' '/api/v1/triage' `
         @("Authorization: Bearer $patTok") ('{"chief_complaint":"' + $c + '"}')
    if ($r.Http -ne 200) { $mixBad += "$c -> $($r.Http)" }
}
Check "★★ $($mixCases.Count) 条宽度混排主诉全部 200（0 条 500）" ($mixBad.Count -eq 0) ($mixBad -join ' | ')

# ── 5c) ★★ 被否认的症状不得主导科室推荐 ───────────────────────────────────
Write-Host ""
Write-Host "[5c] ★★ 科室判定必须处理否定（第五份复查缺陷二）"
# 造一个"有号的心血管内科"—— 让错推荐**看起来权威**（否则一眼就能看出不对）
$null = Invoke-MySqlScalar -My $My -Sql "INSERT INTO department (id,name,code,created_at) VALUES (9211,'心血管内科','T9211',0)" -Label "建心内科"
$null = Invoke-MySqlScalar -My $My -Sql "INSERT INTO doctor (id,name,department_id,title,specialty,created_at) VALUES (9211,'测试心内医生',9211,'主任医师','心血管',0)" -Label "建心内医生"
$null = Invoke-MySqlScalar -My $My -Sql "INSERT INTO schedule (id,doctor_id,department_id,work_date,period,total_num,remain_num,version,enabled,created_at) VALUES (9211,9211,9211,'2026-12-28','AM',5,5,0,1,0)" -Label "建心内排班"
$null = Invoke-MySqlScalar -My $My -Sql "INSERT INTO department (id,name,code,created_at) VALUES (9212,'呼吸内科','T9212',0)" -Label "建呼吸科"
$null = Invoke-MySqlScalar -My $My -Sql "INSERT INTO doctor (id,name,department_id,title,specialty,created_at) VALUES (9212,'测试呼吸医生',9212,'主任医师','呼吸',0)" -Label "建呼吸医生"
$null = Invoke-MySqlScalar -My $My -Sql "INSERT INTO schedule (id,doctor_id,department_id,work_date,period,total_num,remain_num,version,enabled,created_at) VALUES (9212,9212,9212,'2026-12-28','AM',5,5,0,1,0)" -Label "建呼吸排班"
foreach ($c in @('不胸闷，只是咳嗽', '没有胸闷，就是咳嗽', '否认胸闷，主要咳嗽')) {
    $r = DoReq ('ng' + [Guid]::NewGuid().ToString('N').Substring(0,6)) 'POST' '/api/v1/triage' `
         @("Authorization: Bearer $patTok") ('{"chief_complaint":"' + $c + '"}')
    $dept = ''
    if ($r.Json.data.options -and @($r.Json.data.options).Count -gt 0) {
        $dept = @($r.Json.data.options)[0].department_name
    }
    Check "★ 「$c」→ 呼吸内科（不是心血管内科；实得 $dept）" ($dept -eq '呼吸内科') ("$dept")
}
# 对照：真的说胸闷，必须仍然给心血管内科（不能矫枉过正成"一律不给"）
$r = DoReq 'ngpos' 'POST' '/api/v1/triage' @("Authorization: Bearer $patTok") '{"chief_complaint":"胸闷心悸"}'
$dept2 = ''
if ($r.Json.data.options -and @($r.Json.data.options).Count -gt 0) { $dept2 = @($r.Json.data.options)[0].department_name }
Check "★ 对照：真的胸闷 → 心血管内科（实得 $dept2）" ($dept2 -eq '心血管内科')

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
