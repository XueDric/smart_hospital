# SPDX-License-Identifier: MIT
#
# ===== ai-live-check.ps1 —— 真模型端到端验证（需要真密钥）============
#
# 这是唯一一个**必须**有真密钥才能跑的脚本，所以它：
#   · 不进入常规回归（没有密钥时**明确报告并退出 0** —— 缺密钥不是缺陷）；
#   · 绝不在任何输出/文件里回显密钥（只报长度与前缀）。
#
# ── 为什么要它（而不是只靠 accept 的 AC-AICALL-3 ④）──────────────────
#   `accept` 的 live 用例只验「出站能通 + 密钥不漏」。本脚本验**整条链路**：
#   管理端配 ai_setting → 患者调分诊 → source=model 且 ai_note 非空且不含医疗建议。
#
# ── 两个实测踩到的坑（本脚本存在的另两个理由）────────────────────────
#
#   ① **`accept` 会清空 `ai_setting`**
#      （`hResetAiSettings` → `DELETE FROM ai_setting`，测试隔离，设计正确）
#      ⇒ 「先配好、再跑 accept、再验」的顺序下配置会消失，症状是「配了却永远走 rules」。
#      ⇒ 本脚本把「配置」与「验证」放在**同一进程生命周期内**，先后不可交换。
#
#   ② **「我设了环境变量」不等于「子进程拿到了它」**
#      本 harness 里 `$env:X = ...` 之后**同进程读它可能是空的**，
#      而 `Start-Process` 起的服务自然也没有 ⇒ 分诊永远 rules。
#      正确做法是**在启动那一刻显式给环境块**（PowerShell 5.1 的 Start-Process 无 -Environment）：
#          Start-Process cmd.exe -ArgumentList @("/c",
#            "set DEEPSEEK_API_KEY=sk-... && `"<exe>`" serve <dsn> --port 8091 > o.log 2> e.log")
#      ⇒ 本脚本因此支持 `-ApiKey` 显式传参，不依赖进程继承。
#
# 用法：
#   .\ai-live-check.ps1 -AdminPw <口令> -ApiKey sk-... [-Base http://127.0.0.1:8091]

[CmdletBinding()]
param(
    [string]$Base = "http://127.0.0.1:8091",
    [Parameter(Mandatory=$true)][string]$AdminPw,
    [string]$Dsn = "mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital_test",
    [string]$KeyEnv = "DEEPSEEK_API_KEY",
    [string]$ApiKey = ""
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

function Req($tag, $method, $path, $headers, $jsonBody) {
    $cfg = Join-Path $env:TEMP ("ailive_" + $tag + ".cfg")
    $lines = @("request = `"$method`"", "silent", "write-out = `"\n__M__%{http_code}`"")
    foreach ($h in $headers) { $lines += "header = `"$h`"" }
    if ($null -ne $jsonBody) {
        $bf = Join-Path $env:TEMP ("ailive_" + $tag + ".json")
        [System.IO.File]::WriteAllText($bf, $jsonBody, (New-Object System.Text.UTF8Encoding($false)))
        $lines += "header = `"Content-Type: application/json`""
        $lines += "data = `"@" + ($bf -replace '\\','/') + "`""
    }
    [System.IO.File]::WriteAllText($cfg, ($lines -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
    $raw = (& curl.exe -s -K $cfg "$Base$path" 2>&1) -join "`n"
    $code = 0
    if ($raw -match '__M__(\d+)') { $code = [int]$Matches[1] }
    return [pscustomobject]@{ Http = $code; Body = ($raw -replace '(?s)\n?__M__\d+\s*$','') }
}

function Tok($login, $pw) {
    $body = '{"login_name":"' + $login + '","password":"' + $pw + '"}'
    $r = Req ("lg" + $login) 'POST' '/api/v1/auth/login' @() $body
    if ($r.Http -ne 200) {
        # 限流是服务端的正常保护：能清就清掉计数再重试一次，然后才谈失败
        if (Test-HospLoginRateLimited -Login $login -Resp $r -My $My) {
            $r = Req ("lg2" + $login) 'POST' '/api/v1/auth/login' @() ('{"login_name":"' + $login + '","password":"' + $pw + '"}')
        }
        if ($r.Http -ne 200) { Stop-HospLogin -Login $login -Resp $r -My $My -Base $Base }
    }
    return ($r.Body | ConvertFrom-Json).data.token
}

function SqlFile($sql) {
    $p = Join-Path $env:TEMP "ailive_sql.sql"
    [System.IO.File]::WriteAllText($p, $sql, (New-Object System.Text.UTF8Encoding($false)))
    Invoke-MySqlFile -My $My -Path ($p -replace '\\','/')
}

function One($sql) {
    return (Invoke-MySqlScalar -My $My -Label "scalar" -Sql $sql | Out-String).Trim()
}

Write-Host ""
Write-Host "=== 真模型端到端验证 ===" -ForegroundColor Cyan
Write-Host "  目标: $Base"
Write-Host "  库  : $($My.Db)@$($My.DbHost):$($My.Port)"

# ── [0] 密钥
Write-Host ""
Write-Host "[0] 密钥与前置"
$key = if (-not [string]::IsNullOrEmpty($ApiKey)) { $ApiKey } else { [Environment]::GetEnvironmentVariable($KeyEnv) }
if ([string]::IsNullOrEmpty($key)) {
    Write-Host "  [SKIP] 既没给 -ApiKey，环境变量 $KeyEnv 也没设 ⇒ 无法做真模型验证。" -ForegroundColor Yellow
    Write-Host "         这不是失败：缺密钥不是缺陷。补上后重跑。" -ForegroundColor Yellow
    exit 0
}
Check "拿到密钥（长度 $($key.Length)，不回显内容）" ($key.Length -ge 16)
Check "形态像密钥（sk- 前缀）" ($key.StartsWith("sk-")) ("前缀 " + $key.Substring(0,3))

$admTok = Tok "admin" $AdminPw

# ── [1] 经管理端 API 配 ai_setting
Write-Host ""
Write-Host "[1] 经管理端 API 配置 ai_setting"
$pairs = @(
    @('ai.enabled', '1'),
    @('ai.endpoint', 'https://api.deepseek.com/chat/completions'),
    @('ai.model', 'deepseek-chat'),
    @('ai.key_ref', ("env:" + $KeyEnv)),
    @('ai.timeout_secs', '30'),
    @('ai.max_tokens', '512')
)
$cfgOk = $true
foreach ($p in $pairs) {
    $url = "/api/v1/admin/ai/settings/" + $p[0]
    $body = '{"value":"' + $p[1] + '"}'
    $r = Req 'cfg' 'PUT' $url @("Authorization: Bearer $admTok") $body
    if ($r.Http -ne 200) { $cfgOk = $false; Write-Host "         $($p[0]) -> HTTP $($r.Http)" }
}
Check "六项配置全部写入成功" $cfgOk

# ── [2] 密钥不落库
Write-Host ""
Write-Host "[2] 密钥不落库（P3 的机制性纪律）"
$rows = One "SELECT COUNT(*) FROM ai_setting WHERE v LIKE '%sk-%'"
Check "ai_setting 里没有任何一行含 sk-（实得 $rows）" ("$rows" -eq '0')
$kv = One "SELECT v FROM ai_setting WHERE k = 'ai.key_ref'"
Check "库里存的是引用而不是密钥本体（实得 $kv）" ($kv -eq ("env:" + $KeyEnv))

# ── [3] 夹具
Write-Host ""
Write-Host "[3] 夹具"
$r = Req 'mkdept' 'POST' '/api/v1/admin/departments' @("Authorization: Bearer $admTok") '{"name":"AILive呼吸科","code":"AILIVE"}'
$did = 0
if ($r.Http -eq 201) { $did = [int](($r.Body | ConvertFrom-Json).data.id) }
if ($did -le 0) { $did = [int](One "SELECT id FROM department WHERE name = 'AILive呼吸科' ORDER BY id DESC LIMIT 1") }
$r = Req 'mkdoc' 'POST' '/api/v1/admin/doctors' @("Authorization: Bearer $admTok") ('{"name":"AILive医生","department_id":' + $did + ',"title":"医师"}')
$docId = 0
if ($r.Http -eq 201) { $docId = [int](($r.Body | ConvertFrom-Json).data.id) }
if ($docId -le 0) { $docId = [int](One "SELECT id FROM doctor WHERE name = 'AILive医生' ORDER BY id DESC LIMIT 1") }
SqlFile "DELETE FROM schedule WHERE department_id = $did;
INSERT INTO schedule (doctor_id, department_id, work_date, period, total_num, remain_num, version, enabled, created_at)
  VALUES ($docId, $did, '2027-07-01', 'AM', 10, 10, 0, 1, 0);"
$sc = One "SELECT COUNT(*) FROM schedule WHERE department_id = $did"
Check "科室「AILive呼吸科」+ 医生 + 有号排班就绪（schedule=$sc）" ($did -gt 0 -and $docId -gt 0 -and "$sc" -eq '1')

# ★ 规则认出的科室必须**真的有号**，否则分诊会走 `TR_ALTERNATIVES` 备选分支
#   （`triage.cj` 的 ④：`bookableSlotsInDepartment(guess.deptName,…)` 为空时
#    "尽力给出**有号的**备选"，options 就变成"其它科室"，本脚本的断言随之失去意义）。
#
# ⚠ 为什么这里必须**自己制造前提**：
#   主诉"咳嗽三天"经 `deptRules()` 命中 **「呼吸内科」**（`triage.cj:157-159` 词表含"咳嗽"），
#   而 `bookableSlotsInDepartment` 是按 `WHERE d.name = ?` 精确匹配的。
#   实测（2026-10-10）：库里**没有**「呼吸内科」这一行 ⇒ 分诊返回的是备选列表
#   （响应=810003,1777777 而库=810003,1777777,1777779），
#   我先前那条"options = 库里有号部门集合"的断言于是**报红，但红得没有意义**——
#   它红的原因是"库里没有呼吸内科"，与"模型有没有改 options"毫无关系。
#   📌 纪律（本仓 AK/AM 同源）：**断言必须建立在自己制造的前提上**，
#   不能建立在"上一轮测试碰巧留下的残留"上 —— 那正是 `base-check` 假红的成因。
$null = SqlFile "DELETE FROM schedule WHERE department_id IN (SELECT id FROM department WHERE name = 'AILive呼吸内科');
INSERT INTO department (name, code, enabled, created_at)
  VALUES ('AILive呼吸内科', 'AILIVERESP', 1, 0);
INSERT INTO doctor (name, department_id, title, enabled, created_at)
  SELECT 'AILive呼吸医生', id, '医师', 1, 0 FROM department WHERE name = 'AILive呼吸内科';
INSERT INTO schedule (doctor_id, department_id, work_date, period, total_num, remain_num, version, enabled, created_at)
  SELECT dr.id, dr.department_id, '2027-07-02', 'AM', 10, 10, 0, 1, 0
    FROM doctor dr WHERE dr.name = 'AILive呼吸医生';"
$wantDept = [int](One "SELECT id FROM department WHERE name = 'AILive呼吸内科'")
$wantSch = [int](One "SELECT COUNT(*) FROM schedule WHERE department_id = $wantDept AND remain_num > 0 AND enabled = 1 AND work_date >= '2026-10-10'")
Check "★ 前提就绪：规则命中的「AILive呼吸内科」确实有号（dept=$wantDept schedule=$wantSch）" `
      ($wantDept -gt 0 -and $wantSch -ge 1)

$uid = 0
$r = Req 'mkpat' 'POST' '/api/v1/admin/users' @("Authorization: Bearer $admTok") '{"login_name":"ailivepat","password":"Zq4nRw8t","role":"patient","ref_id":950001}'
if ($r.Http -eq 201) { $uid = [int](($r.Body | ConvertFrom-Json).data.user_id) }
if ($uid -le 0) { $uid = [int](One "SELECT id FROM auth_user WHERE login_name = 'ailivepat'") }
$null = Req 'setpw' 'POST' ("/api/v1/admin/users/" + $uid + "/password") @("Authorization: Bearer $admTok") '{"password":"Zq4nRw8t"}'
$patTok = Tok "ailivepat" "Zq4nRw8t"
Check "患者账号就绪（token $($patTok.Length) 字符）" ($patTok.Length -eq 64)

# ── [4] 真模型分诊
Write-Host ""
Write-Host "[4] 真模型分诊（配置 → 出站 → 安全清理 → 响应）"
$r = Req 'tri' 'POST' '/api/v1/triage' @("Authorization: Bearer $patTok") '{"chief_complaint":"咳嗽三天，有点低烧"}'
Check "分诊 → 200" ($r.Http -eq 200) ("HTTP $($r.Http)")
$j = $r.Body | ConvertFrom-Json
Check "source = model（真的走了模型）" ($j.data.source -eq 'model') ("source=" + $j.data.source)
# ⚠ 这里**不**断言"推荐了某个具体科室名" —— 那是 rules 的职责（triage-check 覆盖），
#   而且科室名是**规则的静态词表**决定的（咳嗽 ⇒ 呼吸内科），本脚本建什么名字都不影响它。
#   我先前硬断言"AILive呼吸科"会被推荐，结果是**假红**：库里若存在另一行同名科室（残留），
#   分诊按 `WHERE name = ?` 命中的是那一行。
#   ⇒ 本脚本只管**模型那一段**：options 仍由规则+数据库给出，且**都有号**。
Check "options 仍由规则+数据库给出（本脚本建的有号科室在库中可见）" `
      ((@($j.data.options | Where-Object { $_.remain_num -gt 0 })).Count -eq @($j.data.options).Count) `
      ("推荐=" + (($j.data.options | ForEach-Object { $_.department_name }) -join ','))
Check "推荐里没有无号的排班（模型绕不过这条硬性验证层）" `
      ((@($j.data.options | Where-Object { $_.remain_num -le 0 })).Count -eq 0)

# ★ 上一条只证明了"推荐项都有号"，那是**弱**断言：一个返回**空数组**的 options 也能通过。
#   补一条**精确**断言（前提由 [3] 自己制造，见上方 ★ 说明）：
#   ① 规则命中的「AILive呼吸内科」**必须**出现在 options 里 —— 它确实有号，没理由不出现；
#   ② options 里每一个 department_id **都必须**在库里有号 —— 这条是"模型一个字节都改不了
#      options"（P5 三条硬约束）的**可测形式**：模型若能往里加料，加的必然是一个
#      库中无号的科室，于是这里就会红。
$optDept = @($j.data.options | ForEach-Object { [int]$_.department_id })
$optUniq = @($optDept | Sort-Object -Unique)
Check "★★ options 含规则命中的「AILive呼吸内科」（它有号，模型没把它吃掉）" `
      ($optDept -contains $wantDept) `
      ("响应=" + ($optDept -join ',') + " 规则命中=$wantDept")

# ② 逐个回库核对"这个部门确实有号"。做成一句 SQL 拿回"无号部门"的名单最省事：
$noSlot = @()
foreach ($d in $optUniq) {
    $n = [int](One "SELECT COUNT(*) FROM schedule WHERE department_id = $d AND remain_num > 0 AND enabled = 1 AND work_date >= '2026-10-10'")
    if ($n -lt 1) { $noSlot += $d }
}
Check "★★ options 里每个部门在库里都有号（模型加不进无号的料）" `
      ($noSlot.Count -eq 0) `
      ("无号的=" + ($noSlot -join ',') + " 响应=" + ($optUniq -join ','))
Check "★★ options 无重复部门（同一科只出现一次）" `
      (@($optDept).Count -eq $optUniq.Count) `
      ("响应=" + ($optDept -join ','))
Check "ai_note 非空（模型真的产出了给患者的说明）" ($j.data.ai_note.Length -gt 0) ("ai_note=" + $j.data.ai_note)
$note = $j.data.ai_note
$denyPat = 'mg|毫克|剂量|服用|口服|处方|注射|输液|诊断为|确诊|手术|tablet|dose'
Check "ai_note 不含疑似诊断/用药词汇（安全清理层生效）" (-not ($note -match $denyPat))
Check "ai_note 是单行纯文本（无换行、无 Markdown 标记）" `
      ((-not ($note -match "[\r\n]")) -and (-not ($note -match '\*\*|##')))
Check "响应体里不含密钥" (-not ($r.Body -match [regex]::Escape($key)))

# ── [5] 真实调用计数
Write-Host ""
Write-Host "[5] 真实调用计数（看板口径）"
$mc = One "SELECT COUNT(*) FROM triage_stat WHERE source = 'model'"
Check "triage_stat 记下了 source=model（实得 $mc 行）" ([int]$mc -ge 1)
$dash = Req 'dash' 'GET' '/api/v1/admin/dashboard' @("Authorization: Bearer $admTok") $null
$ai = ($dash.Body | ConvertFrom-Json).data.ai
Check "看板 model_calls = $($ai.model_calls)（> 0，不再是硬编码 0）" ([int]$ai.model_calls -ge 1)
Check "看板给出 source 分布（rules=$($ai.rules_calls) invalid=$($ai.model_invalid_calls)）" `
      ($null -ne $ai.rules_calls -and $null -ne $ai.model_invalid_calls)
Check "看板说明了口径（不含预问诊）" ($ai.model_calls_note -match '预问诊')

# ── [6] ★ 清理并自检残留为 0
#
# ⚠ 为什么必须清理（AM 纪律，P5 阶段立的）：
#   本脚本此前**从不清理**，只在建夹具时"建不出来就按名字反查复用"。
#   后果是残留跨轮累积，而它踩的坑和 `base-check` 那次**一模一样**：
#   `accept` 的 `hResetAll` 只清业务表**不重置 AUTO_INCREMENT** ⇒
#   下轮 INSERT 可能撞上残留行的主键 ⇒ **静默失败** ⇒
#   随后"分诊该推荐这个科室"的断言假红，**读起来完全像产品缺陷**。
#   （2026-10-10 实测残留：department 1760546 / doctor 900192 / auth_user 29。）
#
# ⚠ 删除顺序不能换：本仓**无外键**，全靠应用层守。
#   被引用的是 department/doctor/user，所以必须先删引用方（schedule），
#   再删 auth_user 的令牌，最后才删医生、科室、账号。
$null = SqlFile @"
DELETE FROM schedule     WHERE department_id IN (SELECT id FROM department WHERE name LIKE 'AILive%');
DELETE FROM auth_token   WHERE user_id IN (SELECT id FROM auth_user WHERE login_name LIKE 'ailive%');
DELETE FROM auth_user    WHERE login_name LIKE 'ailive%';
DELETE FROM doctor       WHERE name LIKE 'AILive%';
DELETE FROM department   WHERE name LIKE 'AILive%';
"@

Write-Host ""
Write-Host "[6] ★ 结尾自检：本脚本的夹具残留为 0"
$leftDept = [int](One "SELECT COUNT(*) FROM department WHERE name LIKE 'AILive%'")
$leftDoc = [int](One "SELECT COUNT(*) FROM doctor WHERE name LIKE 'AILive%'")
$leftUsr = [int](One "SELECT COUNT(*) FROM auth_user WHERE login_name LIKE 'ailive%'")
$leftSch = [int](One "SELECT COUNT(*) FROM schedule WHERE department_id IN (SELECT id FROM department WHERE name LIKE 'AILive%')")
Check "★★ 科室/医生/账号/排班残留均为 0（实得 $leftDept/$leftDoc/$leftUsr/$leftSch）" `
      ($leftDept -eq 0 -and $leftDoc -eq 0 -and $leftUsr -eq 0 -and $leftSch -eq 0)

Write-Host ""
if ($failed -eq 0) {
    Write-Host "✅ 真模型端到端验证全部通过（通过 $passed 项）" -ForegroundColor Green
    exit 0
} else {
    Write-Host "❌ 失败 $failed 项（通过 $passed 项）" -ForegroundColor Red
    exit 1
}
