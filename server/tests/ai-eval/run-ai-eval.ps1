<#
  改进 7 · AI 分诊评测（离线优先）
  ==================================================================================
  为什么单独一个脚本（与已有测试的分工）：
    · acceptance_ai_call.cj 用假模型覆盖**工程正确性**（降级 / 超时 / 解析失败 / 安全清理）；
    · 本脚本量的是**结论准不准**（科室 Top1/Top3、红标召回与误报、降级率、耗时分布）。
    两者互补，**不要合并**：前者必须永远通过，后者是质量报告。

  ★ 本脚本**不进** final-verify.ps1：它依赖真实模型与 key（实时模式）或依赖录制样本
    （回放模式），都不该让"发布门禁"变红。发布前手动跑一次并把报告归档到 docs/ai-eval/。

  两种模式：
    · -Mode replay（**默认**）：读 server/tests/ai-eval/recorded/<case-id>.json（离线、可重复、
      不烧钱）。同一批用例连跑两次指标必须**完全一致**（脚本会打印"指标指纹"，两次相同才算可重复）。
    · -Mode live：打真实 /api/v1/triage（要 -Base + -AdminPw；会自建一个一次性患者账号，
      跑完自清），并用响应里的 request_id 去 /api/v1/admin/ai/triage-calls/:requestId 取遥测
      （source / degrade_reason / elapsed_ms / model_name / prompt_revision）。加 -Record 会把
      结果写进 recorded/，之后就能用回放模式复现这一批。

  用法：
    # 录制一批（需要跑起来的服务与管理员口令）
    .\tests\ai-eval\run-ai-eval.ps1 -Mode live -Base http://127.0.0.1:18092 -AdminPw <口令> -Record
    # 回放并出报告（不需要服务、不需要网络）
    .\tests\ai-eval\run-ai-eval.ps1 -Mode replay
    # 连跑两次做可重复性自检（两次"指标指纹"必须相同）
    .\tests\ai-eval\run-ai-eval.ps1 -Mode replay; .\tests\ai-eval\run-ai-eval.ps1 -Mode replay

  ⚠ 本文件含中文，必须存成 **UTF-8 with BOM**（`edit`/`write` 工具会剥掉 BOM，
    重写后用 [System.IO.File]::WriteAllText(..., UTF8Encoding($true)) 补回）。

  用例格式（cases.jsonl，一行一例，允许 # 注释行与空行）：
    {"id":"case-0001","chief_complaint":"...","expected_departments":["呼吸内科"],
     "expected_red_flag":false,"note":"...","labeled_by":"...","labeled_at":"2026-10-15"}

  环境依赖（写进报告，不假装是模型质量）：本机测试库的科室/号源很少，
  "本环境可判定"的用例数会单独统计 —— expected_departments 里一个都不在环境内有号科室时，
  Top1/Top3 对它没有意义（规则层拿不到那个号源），脚本会把它从"可判定"里剔除并列出。
#>
[CmdletBinding()]
param(
    [ValidateSet('replay', 'live')][string]$Mode = 'replay',
    [string]$Base = 'http://127.0.0.1:18092',
    [string]$AdminLogin = 'admin',
    [string]$AdminPw = '',
    [string]$Dsn = 'mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital_test',
    [switch]$Record,
    [string]$Cases = '',
    [string]$OutDir = '',
    [int]$Limit = 0
)

$ErrorActionPreference = 'Stop'

$EvalDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($Cases)) { $Cases = Join-Path $EvalDir 'cases.jsonl' }
$RecordedDir = Join-Path $EvalDir 'recorded'
if ([string]::IsNullOrEmpty($OutDir)) {
    $repo = (Resolve-Path (Join-Path $EvalDir '..\..\..')).Path
    $OutDir = Join-Path $repo 'docs\ai-eval'
}
if (-not (Test-Path $RecordedDir)) { New-Item -ItemType Directory -Path $RecordedDir -Force | Out-Null }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Utf8Bom = New-Object System.Text.UTF8Encoding($true)

function Write-Utf8($path, $text, $bom) {
    $enc = if ($bom) { $Utf8Bom } else { $Utf8NoBom }
    [System.IO.File]::WriteAllText($path, $text, $enc)
}

# ── HTTP（curl -K 配置文件，避免命令行引号/中文编码问题；见 ai-telemetry-check.ps1 同款）──
$tmp = Join-Path $env:TEMP ("aieval-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

function Req($name, $method, $path, $headers, $body) {
    $f = Join-Path $tmp "$name.cfg"
    $lines = @("request = `"$method`"")
    foreach ($h in $headers) { $lines += "header = `"$h`"" }
    if ($body) {
        $bf = Join-Path $tmp "$name.body"
        Write-Utf8 $bf $body $false
        $lines += ('data = "@' + ($bf -replace '\\', '/') + '"')
        $lines += 'header = "Content-Type: application/json"'
    }
    $lines += 'silent'
    $lines += 'write-out = "\n__CODE__%{http_code}"'
    Write-Utf8 $f ($lines -join "`n") $false
    $raw = (& curl.exe -K $f "$Base$path" 2>&1) -join "`n"
    $parts = $raw -split "__CODE__"
    $code = if ($parts.Count -gt 1) { [int]$parts[1].Trim() } else { -1 }
    return @{ Code = $code; Body = $parts[0].Trim() }
}
function Json($r) { return ($r.Body | ConvertFrom-Json) }

# ── 用例 ─────────────────────────────────────────────────────────────────────
$caseList = @()
$lineNo = 0
foreach ($line in [System.IO.File]::ReadAllLines($Cases, [System.Text.Encoding]::UTF8)) {
    $lineNo++
    $t = $line.Trim()
    if ($t.Length -eq 0 -or $t.StartsWith('#')) { continue }
    try { $o = $t | ConvertFrom-Json } catch { throw "cases.jsonl 第 $lineNo 行不是合法 JSON：$t" }
    foreach ($k in @('id', 'chief_complaint', 'expected_departments', 'expected_red_flag')) {
        if ($null -eq $o.$k) { throw "cases.jsonl 第 $lineNo 行缺字段 $k" }
    }
    $caseList += $o
}
if ($Limit -gt 0) { $caseList = $caseList | Select-Object -First $Limit }
if ($caseList.Count -eq 0) { throw "没有可用用例（$Cases）" }

Write-Host "=== AI 分诊评测（改进 7）==="
Write-Host "  模式: $Mode$(if ($Record) { ' + 录制' } else { '' })"
Write-Host "  用例: $($caseList.Count) 条（$Cases）"
Write-Host "  输出: $OutDir"
Write-Host ""

$env_deps = @()
$samples = @()          # 每项: @{ case=...; triage=...; telemetry=... }
$unrecorded = @()
$errors = @()

if ($Mode -eq 'live') {
    if ([string]::IsNullOrEmpty($AdminPw)) { throw "live 模式必须提供 -AdminPw" }
    . (Join-Path $EvalDir '..\common.ps1')
    $My = Get-MySqlClientArgs -Dsn $Dsn

    $depRaw = Invoke-MySqlScalar -My $My -Sql "SELECT IFNULL(GROUP_CONCAT(DISTINCT d.name SEPARATOR ','), '') FROM schedule s JOIN doctor doc ON doc.id = s.doctor_id JOIN department d ON d.id = doc.department_id WHERE s.remain_num > 0" -Label "查本环境有号科室"
    if ($depRaw) { $env_deps = @($depRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    Write-Host "  本环境有号科室: $(if ($env_deps.Count) { $env_deps -join '、' } else { '（无）' })"

    $r = Req 'login' 'POST' '/api/v1/auth/login' @() ('{"login_name":"' + $AdminLogin + '","password":"' + $AdminPw + '"}')
    if ($r.Code -ne 200) { throw "管理员登录失败（HTTP $($r.Code)）：$($r.Body)" }
    $admTok = (Json $r).data.token
    $AH = @("Authorization: Bearer $admTok")

    $tag = "AI-EVAL-" + ([Guid]::NewGuid().ToString("N").Substring(0, 8))
    $patLogin = "$tag-p"
    $patPw = "Ai-Eval-Pw-1!"
    $r = Req 'p0' 'POST' '/api/v1/admin/users' $AH ('{"login_name":"' + $patLogin + '","role":"patient","ref_id":1,"display_name":"' + $tag + '","password":"' + $patPw + '"}')
    if ($r.Code -ne 201 -and $r.Code -ne 409) { throw "建评测患者账号失败（HTTP $($r.Code)）：$($r.Body)" }
    $r = Req 'p1' 'POST' '/api/v1/auth/login' @() ('{"login_name":"' + $patLogin + '","password":"' + $patPw + '"}')
    if ($r.Code -ne 200) { throw "评测患者登录失败（HTTP $($r.Code)）：$($r.Body)（口令强度校验没过会静默建号失败）" }
    $patTok = (Json $r).data.token
    $PH = @("Authorization: Bearer $patTok")

    $i = 0
    foreach ($c in $caseList) {
        $i++
        $rid = "$tag-$($c.id)"
        $body = @{ chief_complaint = $c.chief_complaint } | ConvertTo-Json -Compress
        $r = Req "t$i" 'POST' '/api/v1/triage' ($PH + @("X-Request-Id: $rid")) $body
        if ($r.Code -ne 200) {
            $errors += "$($c.id): /triage HTTP $($r.Code) $($r.Body)"
            Write-Host "  [$i/$($caseList.Count)] $($c.id) ✗ HTTP $($r.Code)"
            continue
        }
        $tri = (Json $r).data
        $tele = $null
        $r2 = Req "c$i" 'GET' "/api/v1/admin/ai/triage-calls/$rid" $AH $null
        if ($r2.Code -eq 200) {
            $j2 = Json $r2
            if ($j2.data.items -and $j2.data.items.Count -gt 0) { $tele = $j2.data.items[0] }
        }
        $samples += @{ case = $c; triage = $tri; telemetry = $tele }
        if ($Record) {
            $rec = [ordered]@{ case_id = $c.id; chief_complaint = $c.chief_complaint; recorded_at = (Get-Date).ToString('s'); triage = $tri; telemetry = $tele }
            Write-Utf8 (Join-Path $RecordedDir "$($c.id).json") ($rec | ConvertTo-Json -Depth 8) $false
        }
        $src = if ($tri.source) { $tri.source } else { '?' }
        Write-Host "  [$i/$($caseList.Count)] $($c.id)  source=$src  red_flag=$($tri.red_flag)  options=$(@($tri.options).Count)"
    }
    if ($Record) {
        Write-Utf8 (Join-Path $RecordedDir '_env.json') ([ordered]@{ recorded_at = (Get-Date).ToString('s'); departments = $env_deps } | ConvertTo-Json) $false
    }

    # 夹具自清（账号与本次遥测）
    $null = Invoke-MySqlScalar -My $My -Sql "DELETE FROM auth_user WHERE login_name LIKE '$tag%'" -Label "清评测账号"
    $null = Invoke-MySqlScalar -My $My -Sql "DELETE FROM triage_stat WHERE request_id LIKE '$tag%'" -Label "清评测遥测"
} else {
    $envFile = Join-Path $RecordedDir '_env.json'
    if (Test-Path $envFile) {
        $e = ([System.IO.File]::ReadAllText($envFile, [System.Text.Encoding]::UTF8)) | ConvertFrom-Json
        if ($e.departments) { $env_deps = @($e.departments) }
    }
    Write-Host "  本环境有号科室（录制时）: $(if ($env_deps.Count) { $env_deps -join '、' } else { '（未记录）' })"
    foreach ($c in $caseList) {
        $f = Join-Path $RecordedDir "$($c.id).json"
        if (-not (Test-Path $f)) { $unrecorded += $c.id; continue }
        $rec = ([System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8)) | ConvertFrom-Json
        $samples += @{ case = $c; triage = $rec.triage; telemetry = $rec.telemetry }
    }
}

# ── 指标 ─────────────────────────────────────────────────────────────────────
function Percentile($values, $p) {
    # 最近秩法（与 server/src/triage_stat.cj 的 triagePercentile 同一口径）：不做插值，
    # 因为插值会造出一个从未真实发生过的耗时，报告里出现它只会误导。
    $arr = @($values | Sort-Object)
    $n = $arr.Count
    if ($n -eq 0) { return 0 }
    $rank = [int][Math]::Floor(([double]$p * $n + 99) / 100)
    if ($rank -lt 1) { $rank = 1 }
    if ($rank -gt $n) { $rank = $n }
    return [int64]$arr[$rank - 1]
}

$optDeps = { param($tri) @($tri.options | ForEach-Object { $_.department_name }) }

$eligible = @()   # 本环境可判定（expected 与 env 有交集）
foreach ($s in $samples) {
    $exp = @($s.case.expected_departments)
    if ($exp.Count -eq 0) { continue }
    if ($env_deps.Count -gt 0) {
        $hit = $false
        foreach ($e in $exp) { if ($env_deps -contains $e) { $hit = $true; break } }
        if ($hit) { $eligible += $s }
    } else {
        $eligible += $s
    }
}

$top1 = 0; $top3 = 0; $top1All = 0; $top3All = 0
foreach ($s in $samples) {
    $exp = @($s.case.expected_departments)
    if ($exp.Count -eq 0) { continue }
    $deps = & $optDeps $s.triage
    if ($deps.Count -ge 1 -and $deps[0] -eq $exp[0]) { $top1All++ }
    if ($deps.Count -gt 0) { foreach ($e in $exp) { if ($deps[0..([Math]::Min(2, $deps.Count - 1))] -contains $e) { $top3All++; break } } }
}
foreach ($s in $eligible) {
    $exp = @($s.case.expected_departments)
    $deps = & $optDeps $s.triage
    if ($deps.Count -ge 1 -and $deps[0] -eq $exp[0]) { $top1++ }
    if ($deps.Count -gt 0) { foreach ($e in $exp) { if ($deps[0..([Math]::Min(2, $deps.Count - 1))] -contains $e) { $top3++; break } } }
}

$expRed = @($samples | Where-Object { $_.case.expected_red_flag -eq $true })
$redHit = @($expRed | Where-Object { $_.triage.red_flag -eq $true })
$redMiss = @($expRed | Where-Object { $_.triage.red_flag -ne $true })
$redFp = @($samples | Where-Object { $_.case.expected_red_flag -ne $true -and $_.triage.red_flag -eq $true })

# ★ 降级判据必须与 /api/v1/admin/ai/triage-stats **同源**（2026-10-16 复核 D4）：
#   权威口径 = "模型侧失败" = degrade_reason 非空 **且不是 RED_FLAG**。
#   RED_FLAG 是"规则直接判红标、压根没调模型"的**良性旁路**，混进降级率会让
#   降级率虚高（临床上看起来像"AI 总在失败"，实际是分诊规则正常拦截）。
#   旧写法 `$_.triage.source -ne 'model'` 是**第二份实现**，与服务端注释里明写的
#   "不要写 source != model" 直接冲突 —— 两份口径迟早对不上（评测说 0.9、看板说 0.5，
#   而且没人知道该信哪个）。所以这里只读服务端已经算好的降级码，不再自己判 source。
$hasTelemetry = @($samples | Where-Object { $_.telemetry -and $null -ne $_.telemetry.degrade_reason }).Count -gt 0
$degraded = @($samples | Where-Object {
    if ($_.telemetry -and $null -ne $_.telemetry.degrade_reason) {
        $_.telemetry.degrade_reason -ne '' -and $_.telemetry.degrade_reason -ne 'RED_FLAG'
    } else {
        # 老录制样本没有 degrade_reason 字段：退回 source 口径，并在指标里显式标出来，
        # 免得读者以为它和新样本同源。
        $_.triage.source -ne 'model'
    }
})
$bypass = @($samples | Where-Object { $_.telemetry -and $_.telemetry.degrade_reason -eq 'RED_FLAG' })
$degradeCriterion = if ($hasTelemetry) { 'model_side_failure（degrade_reason 非空且非 RED_FLAG）' } else { 'source != model（无遥测，回退口径）' }
$elapsed = @($samples | Where-Object { $_.telemetry -and $null -ne $_.telemetry.elapsed_ms } | ForEach-Object { [int64]$_.telemetry.elapsed_ms })
$modelIds = @($samples | Where-Object { $_.telemetry } | ForEach-Object { [string]$_.telemetry.model_id } | Sort-Object -Unique)
$modelNames = @($samples | Where-Object { $_.telemetry } | ForEach-Object { [string]$_.telemetry.model_name } | Sort-Object -Unique)
$revs = @($samples | Where-Object { $_.telemetry } | ForEach-Object { [string]$_.telemetry.prompt_revision } | Sort-Object -Unique)
$degradeReasons = @($samples | Where-Object { $_.telemetry } | ForEach-Object { [string]$_.telemetry.degrade_reason } | Group-Object | ForEach-Object { "$($_.Name)=$($_.Count)" })

function Rate($num, $den) { if ($den -eq 0) { return 0.0 } ; return [Math]::Round([double]$num / [double]$den, 4) }

$metrics = [ordered]@{
    date                = (Get-Date).ToString('yyyy-MM-dd')
    mode                = $Mode
    cases               = $caseList.Count
    samples             = $samples.Count
    unrecorded          = $unrecorded.Count
    env_departments     = @($env_deps)
    top1_eligible       = $eligible.Count
    top1_hits           = $top1
    top1_rate           = (Rate $top1 $eligible.Count)
    top3_hits           = $top3
    top3_rate           = (Rate $top3 $eligible.Count)
    top1_rate_all       = (Rate $top1All $samples.Count)
    redflag_expected    = $expRed.Count
    redflag_hits        = $redHit.Count
    redflag_recall      = (Rate $redHit.Count $expRed.Count)
    redflag_false_pos   = $redFp.Count
    degrade_rate        = (Rate $degraded.Count $samples.Count)
    degrade_reasons     = @($degradeReasons)
    degrade_criterion   = $degradeCriterion
    redflag_bypass      = $bypass.Count
    p50_ms              = (Percentile $elapsed 50)
    p95_ms              = (Percentile $elapsed 95)
    model_ids           = @($modelIds)
    model_names         = @($modelNames)
    prompt_revisions    = @($revs)
}
$metricsJson = ($metrics | ConvertTo-Json -Depth 6)
$sha = [System.Security.Cryptography.SHA256]::Create()
$hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes(($metrics | ConvertTo-Json -Depth 6 -Compress)))
$fingerprint = ([BitConverter]::ToString($hashBytes) -replace '-', '').Substring(0, 16).ToLower()

Write-Host ""
Write-Host "── 指标 ──────────────────────────────────────────────"
Write-Host ("  样本 {0}/{1}（未录制 {2}）" -f $samples.Count, $caseList.Count, $unrecorded.Count)
Write-Host ("  科室 Top1  {0}/{1} = {2}（全量口径 {3}）" -f $top1, $eligible.Count, $metrics.top1_rate, $metrics.top1_rate_all)
Write-Host ("  科室 Top3  {0}/{1} = {2}" -f $top3, $eligible.Count, $metrics.top3_rate)
Write-Host ("  红标召回   {0}/{1} = {2}；误报 {3} 例" -f $redHit.Count, $expRed.Count, $metrics.redflag_recall, $redFp.Count)
Write-Host ("  降级率     {0}/{1} = {2}  口径：{3}  红标旁路 {4} 例  {5}" -f $degraded.Count, $samples.Count, $metrics.degrade_rate, $degradeCriterion, $bypass.Count, ($degradeReasons -join ' '))
Write-Host ("  耗时 p50/p95 = {0} / {1} ms（样本 {2}）" -f $metrics.p50_ms, $metrics.p95_ms, $elapsed.Count)
Write-Host ("  模型 id    {0}；模型名 {1}；模板 revision {2}" -f (($modelIds -join ',')), (($modelNames -join ',')), (($revs -join ',')))
Write-Host ("  ★ 指标指纹 {0}（回放模式连跑两次必须相同 ⇒ 可重复）" -f $fingerprint)
if ($unrecorded.Count) { Write-Host ("  未录制: {0}" -f ($unrecorded -join ', ')) }
if ($errors.Count) { Write-Host ("  ⚠ 调用失败 {0} 条: {1}" -f $errors.Count, ($errors -join ' | ')) }
Write-Host ""

# ── 报告与指标归档 ───────────────────────────────────────────────────────────
$stamp = (Get-Date).ToString('yyyy-MM-dd')
$metricsPath = Join-Path $OutDir "$stamp.metrics.json"
$reportPath = Join-Path $OutDir "$stamp.md"

# 与上一份指标对比（找最新的、日期不同的那份）
$prev = $null
Get-ChildItem (Join-Path $OutDir '*.metrics.json') -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne "$stamp.metrics.json" } |
    Sort-Object Name -Descending | Select-Object -First 1 | ForEach-Object {
        try { $prev = ([System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8)) | ConvertFrom-Json; $prev | Add-Member -NotePropertyName '_file' -NotePropertyValue $_.Name -Force } catch { }
    }

$delta = @()
if ($prev) {
    foreach ($k in @('top1_rate', 'top3_rate', 'redflag_recall', 'redflag_false_pos', 'degrade_rate', 'redflag_bypass', 'p50_ms', 'p95_ms')) {
        $delta += ('| {0} | {1} | {2} | {3} |' -f $k, $prev.$k, $metrics.$k, $(if ("$($prev.$k)" -eq "$($metrics.$k)") { '不变' } else { '**变化**' }))
    }
}

$rows = @()
foreach ($s in $samples) {
    $exp = (@($s.case.expected_departments) -join '、')
    $deps = (& $optDeps $s.triage) -join '、'
    $mark = if ($s.triage.red_flag -eq $true) { '🚩' } else { '' }
    $rows += ('| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} |' -f `
        $s.case.id, $s.case.chief_complaint, $exp, $deps, $mark, $s.triage.source, `
        $(if ($s.telemetry) { $s.telemetry.elapsed_ms } else { '' }), `
        $(if ($s.telemetry) { $s.telemetry.degrade_reason } else { '' }))
}
$missRows = @()
foreach ($s in $redMiss) { $missRows += ('| {0} | {1} | 期望红标=true，实得 false |' -f $s.case.id, $s.case.chief_complaint) }
foreach ($s in $redFp) { $missRows += ('| {0} | {1} | 期望红标=false，实得 true（误报） |' -f $s.case.id, $s.case.chief_complaint) }

$ineligible = @($samples | Where-Object { $eligible -notcontains $_ } | ForEach-Object { $_.case.id })

$md = @()
$md += "# AI 分诊评测报告 · $stamp"
$md += ""
$md += "> 由 ``server/tests/ai-eval/run-ai-eval.ps1`` 生成（**不要手工改**）。"
$md += "> 评测**不进** ``final-verify.ps1``：它量的是「结论准不准」，依赖真实模型或录制样本。"
$md += ""
$md += "## 1. 本次运行"
$md += ""
$md += "| 项 | 值 |"
$md += "| --- | --- |"
$md += "| 模式 | ``$Mode``$(if ($Record) { ' + 录制' } else { '' }) |"
$md += "| 用例数 / 有样本 | $($caseList.Count) / $($samples.Count) |"
$md += "| 未录制（回放模式） | $(if ($unrecorded.Count) { $unrecorded -join '、' } else { '无' }) |"
$md += "| 样本量（本环境可判定 Top1/Top3） | $($eligible.Count) |"
$md += "| 本环境有号科室 | $(if ($env_deps.Count) { $env_deps -join '、' } else { '（未记录）' }) |"
$md += "| 模型 id / 模型名 | $(if ($modelIds.Count) { $modelIds -join '、' } else { '—' }) / $(if ($modelNames.Count) { $modelNames -join '、' } else { '—' }) |"
$md += "| 模板 revision | $(if ($revs.Count) { $revs -join '、' } else { '—' }) |"
$md += "| 指标指纹（可重复性凭据） | ``$fingerprint`` |"
$md += ""
$md += "⚠ **模型 id = 0 表示本次走的是 KV 配置**（没有 ``ai_model`` 行）；``model_name`` 仍是真正发出去的模型名。"
$md += "若 ``ai.key_ref`` 为空，服务端**不会出站**，此时 ``source=rules``、``degrade_reason=AI_DISABLED`` —— "
$md += "这一批报告量的是**规则层基线**，不是模型质量。"
$md += ""
$md += "## 2. 指标"
$md += ""
$md += "| 指标 | 值 | 说明 |"
$md += "| --- | --- | --- |"
$md += "| 科室 Top1 命中 | $top1 / $($eligible.Count) = $($metrics.top1_rate) | 期望科室（第一个）等于 ``options[0]``；全量口径 $($metrics.top1_rate_all) |"
$md += "| 科室 Top3 命中 | $top3 / $($eligible.Count) = $($metrics.top3_rate) | 期望科室出现在前 3 个号源里 |"
$md += "| 红标召回 | $($redHit.Count) / $($expRed.Count) = $($metrics.redflag_recall) | ``expected_red_flag=true`` 的用例里真的被判红标 |"
$md += "| 红标误报 | $($redFp.Count) | 非急症被判红标（会让患者白跑急诊） |"
$md += "| 降级率 | $($degraded.Count) / $($samples.Count) = $($metrics.degrade_rate) | **模型侧失败**：``degrade_reason`` 非空且非 ``RED_FLAG``（与 ``/admin/ai/triage-stats`` 同一判据）；本次口径：$($degradeCriterion) |"
$md += "| 红标旁路 | $($bypass.Count) | ``degrade_reason='RED_FLAG'``：规则直接判红标、没调模型，属良性旁路，**不计入降级率** |"
$md += "| 降级原因分布 | $(if ($degradeReasons.Count) { $degradeReasons -join '、' } else { '—' }) | 稳定码见 ``docs/archive/FRONTEND-INTEGRATION.md`` §5.31 |"
$md += "| 耗时 p50 / p95 | $($metrics.p50_ms) / $($metrics.p95_ms) ms（样本 $($elapsed.Count)） | 最近秩法，与 ``triage-stats`` 同一口径 |"
$md += ""
if ($prev) {
    $md += "### 与上一份报告（``$($prev._file)``）对比"
    $md += ""
    $md += "| 指标 | 上一份 | 本次 | 变化 |"
    $md += "| --- | --- | --- | --- |"
    $md += $delta
    $md += ""
} else {
    $md += "> 这是第一份报告，没有可比对的上一份（后续报告会自动与本目录里最新的一份对比）。"
    $md += ""
}
$md += "## 3. 逐例明细"
$md += ""
$md += "| 用例 | 主诉 | 期望科室 | 实得科室（前 3） | 红标 | source | elapsed_ms | degrade_reason |"
$md += "| --- | --- | --- | --- | --- | --- | --- | --- |"
$md += $rows
$md += ""
if ($missRows.Count) {
    $md += "## 4. 红标缺口（要业务/规则一起看）"
    $md += ""
    $md += "| 用例 | 主诉 | 判定 |"
    $md += "| --- | --- | --- |"
    $md += $missRows
    $md += ""
}
if ($ineligible.Count) {
    $md += "## 5. 本环境判定不了的用例"
    $md += ""
    $md += "这些用例的期望科室在本环境（测试库）**没有号源**，Top1/Top3 对它们没有意义"
    $md += "（推荐接口只会给「真的有号」的科室）：$(($ineligible) -join '、')。"
    $md += "换到真实号源环境后它们会自动进入可判定集合。"
    $md += ""
}
if ($errors.Count) {
    $md += "## 6. 调用失败"
    $md += ""
    foreach ($e in $errors) { $md += "- $e" }
    $md += ""
}
$md += "---"
$md += ""
$md += "## 怎么复现这一份报告"
$md += ""
$md += '```'
$md += '# 回放（离线，不需要服务）：'
$md += '.\server\tests\ai-eval\run-ai-eval.ps1 -Mode replay'
$md += '# 连跑两次，两次打印的"指标指纹"必须相同（可重复性自检）'
$md += '# 重新录制（需要跑起来的服务 + 管理员口令）：'
$md += '.\server\tests\ai-eval\run-ai-eval.ps1 -Mode live -Base http://127.0.0.1:18092 -AdminPw <口令> -Record'
$md += '```'

Write-Utf8 $metricsPath $metricsJson $false
Write-Utf8 $reportPath ($md -join "`n") $true
Write-Host "  已写报告: $reportPath"
Write-Host "  已写指标: $metricsPath"
if ($unrecorded.Count) { exit 2 }
if ($samples.Count -eq 0) { exit 3 }
exit 0
