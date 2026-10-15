# 分诊遥测与排障（改进 7「AI 评测与排障闭环」的服务端读出口）端到端验证
#
# 为什么单独一个脚本：2026-10-15 新增的两条端点
#   GET /api/v1/admin/ai/triage-stats   —— 分诊质量聚合（计数 / 降级率 / p50 / p95）
#   GET /api/v1/admin/ai/triage-calls/:requestId —— 单次调用全链路
# 是**第一个把 triage_stat 读出来**的出口。它坏了的现象非常难查：
#   · 数字错（分位数插值出来的耗时在日志里根本找不到）⇒ 排障结论反向对账
#   · 隐私漏（顺手把主诉原文带出来）⇒ 合规红线破了，事后无法收回
#   · 版本号不动 ⇒ "这条结果产生于哪一版配置"永远答不上来
# 所以本脚本的重点不是"200 了没有"，而是**逐字段对质 + 隐私否定断言 + 版本号真的在动**。
#
# 覆盖：
#   [1] 鉴权（无令牌 401 / 患者 403 / 管理员 200）
#   [2] 参数闸门（group_by 白名单、注入串、from>to、limit/group_limit 夹取）
#   [3] ★★ 一次真调用 → 响应体里回编号 + 按 request_id 捞出全链路（字段齐全 + 口径如实）
#   [4] ★★★ 隐私：把我们**刚发出去的主诉原文**当作指纹在响应里找（找不到才算过）
#   [5] 聚合：计数 / 降级率 / p50<=p95 / 截断如实标注
#   [6] ★★ 配置版本号随"改配置"前进（零重启链条：改配置 → 下一次调用就带新版本号）
#   [7] 夹具自清 + 残留自检
#
# ⚠ 含中文的 PowerShell 脚本必须 UTF-8 with BOM（PS 5.1 否则按 ANSI 解析 → 语法报错）。
#   ★ 而 `edit`/`write` 工具重写文件会**丢掉 BOM** ⇒ 每次改完本文件都要重新补 BOM 再跑
#     （补法：ReadAllText + WriteAllText(..., UTF8Encoding($true))，然后 Parser::ParseFile 复验 0 错）。
# ⚠ header/body 全部走 curl **config 文件**（-K），理由同 auth-check.ps1。
# ⚠ 端口别用 8091：本机 Windows 排除段含 8037-8136 ⇒ 绑定会以
#   `SocketException: Failed to bind 10013`（WSAEACCES）失败，看起来像"服务端崩了"。
#   查排除段：`netsh int ipv4 show excludedportrange protocol=tcp`；用 18096 这类端口。
#
# 用法：
#   .\ai-telemetry-check.ps1 -Base http://127.0.0.1:18096 -AdminPw <口令>

param(
    [string]$Base = "http://127.0.0.1:8091",
    [string]$AdminLogin = "admin",
    [string]$AdminPw = "",
    [string]$Dsn = "mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital_test"
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrEmpty($AdminPw)) {
    throw "必须提供 -AdminPw（先跑 hospital-server.exe serve 前的 create-admin 拿到口令）"
}

. "$PSScriptRoot\common.ps1"
$My = Get-MySqlClientArgs -Dsn $Dsn

$fail = 0
function Check($name, $ok) {
    if ($ok) { Write-Host "  [PASS] $name" }
    else { Write-Host "  [FAIL] $name"; $script:fail++ }
}
function CheckD($name, $ok, $detail) {
    Check $name $ok
    if ($detail) { Write-Host "         $detail" }
}

$tmp = Join-Path $env:TEMP ("aitel-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

function Req($name, $method, $path, $headers, $body) {
    $f = Join-Path $tmp "$name.cfg"
    $lines = @("request = `"$method`"")
    foreach ($h in $headers) { $lines += "header = `"$h`"" }
    if ($body) {
        $bf = Join-Path $tmp "$name.body"
        [System.IO.File]::WriteAllText($bf, $body, (New-Object System.Text.UTF8Encoding($false)))
        $lines += ('data = "@' + ($bf -replace '\\', '/') + '"')
        $lines += 'header = "Content-Type: application/json"'
    }
    $lines += 'silent'
    $lines += 'write-out = "\n__CODE__%{http_code}"'
    [System.IO.File]::WriteAllText($f, ($lines -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
    $raw = (& curl.exe -K $f "$Base$path" 2>&1) -join "`n"
    $parts = $raw -split "__CODE__"
    $code = if ($parts.Count -gt 1) { [int]$parts[1].Trim() } else { -1 }
    return @{ Code = $code; Body = $parts[0].Trim() }
}
function Json($r) { return ($r.Body | ConvertFrom-Json) }

# 夹具名前缀：脚本自建自清的唯一依据（结尾按它自检残留为 0）
$tag = "AI-TEL-CHK-" + ([Guid]::NewGuid().ToString("N").Substring(0, 8))
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$from = $now - 3600
$to = $now + 3600

# ★★ 本次调用要发出去的主诉原文：**带唯一指纹**，后面拿它当"隐私探针"。
#    用一段正常的中文主诉 + 唯一标记，避免被规则当成危急征象（走红标分支就不调模型了，
#    也就拿不到"模型/降级"那几个字段的完整样本 —— 那是另一个用例的事）。
#
# ⚠ 指纹必须与 `$tag` **不同**：`$tag` 会出现在 request_id 里（那是我们主动传的）
#   和夹具登录名里，拿它扫响应会**在自己身上误报隐私泄露**（第一次跑就这么红了两项）。
#   `$probe` 只可能来自主诉原文 —— 它在响应里出现，才是真的漏了。
$probe = "咳嗽三天有痰 BX-" + ([Guid]::NewGuid().ToString("N").Substring(0, 8))
$secret = $probe

Write-Host "=== 分诊遥测与排障端到端验证 ==="
Write-Host "  目标: $Base"
Write-Host "  夹具前缀: $tag"
Write-Host ""

# ── 登录 ───────────────────────────────────────────────────────────────────
$r = Req 'login' 'POST' '/api/v1/auth/login' @() ('{"login_name":"' + $AdminLogin + '","password":"' + $AdminPw + '"}')
if ($r.Code -ne 200) { throw "管理员登录失败（HTTP $($r.Code)）：$($r.Body)" }
$admTok = (Json $r).data.token
$AH = @("Authorization: Bearer $admTok")

# 患者账号（一次性，用途单一）——分诊接口要 Action.Book
$patLogin = "$tag-p"
$patPw = "Ai-Tele-Chk-Pw-1!"
$r = Req 'p0' 'POST' '/api/v1/admin/users' $AH ('{"login_name":"' + $patLogin + '","role":"patient","ref_id":1,"display_name":"' + $tag + '","password":"' + $patPw + '"}')
CheckD "夹具：建患者账号（201 新建 / 409 已存在都算成功）" ($r.Code -eq 201 -or $r.Code -eq 409) ("HTTP $($r.Code) $($r.Body)")
$r = Req 'p1' 'POST' '/api/v1/auth/login' @() ('{"login_name":"' + $patLogin + '","password":"' + $patPw + '"}')
if ($r.Code -ne 200) { throw "患者账号登录失败（HTTP $($r.Code)）：$($r.Body)（口令强度校验可能没通过 ⇒ 建号静默失败）" }
$patTok = (Json $r).data.token
$PH = @("Authorization: Bearer $patTok")
# ⚠ 每一次分诊调用都必须自带 X-Request-Id（2026-10-16 复核提示项）：
#   不带的话服务端会**代铸**一个 id，于是这一行遥测既不在本脚本的清理范围
#   （按 request_id LIKE '$tag%' 清），也不会出现在残留自检里 ⇒ 每跑一次就往
#   triage_stat 漏一行，而 [7] 还照样打印"残留 0"（违反本仓 README 的门禁规则 AO：
#   自检必须能真的发现自己的残留）。
$r = Req 'p2' 'POST' '/api/v1/triage' ($PH + "X-Request-Id: ${tag}-boot") ('{"chief_complaint":"' + $secret + '"}')
CheckD "夹具：患者能正常分诊（HTTP $($r.Code)）" ($r.Code -eq 200) ("body=$($r.Body.Substring(0, [Math]::Min(200, $r.Body.Length)))")

# ── 1) 鉴权 ────────────────────────────────────────────────────────────────
Write-Host "[1] 鉴权"
$r = Req 'n1' 'GET' '/api/v1/admin/ai/triage-stats' @() $null
Check "无令牌 ⇒ 401（不是 200、也不是 500）" ($r.Code -eq 401)
$r = Req 'n2' 'GET' '/api/v1/admin/ai/triage-calls/probe' @() $null
Check "无令牌（单次调用端点）⇒ 401" ($r.Code -eq 401)
$r = Req 'n3' 'GET' '/api/v1/admin/ai/triage-stats' $PH $null
CheckD "★★ 患者令牌 ⇒ 403 FORBIDDEN_ROLE（遥测里有模型/模板版本，不是患者该看的）" `
       ($r.Code -eq 403 -and (Json $r).error.code -eq 'FORBIDDEN_ROLE') ("HTTP $($r.Code)")
$r = Req 'n4' 'GET' '/api/v1/admin/ai/triage-stats' $AH $null
CheckD "管理员 ⇒ 200" ($r.Code -eq 200) ("HTTP $($r.Code) body=$($r.Body.Substring(0, [Math]::Min(160, $r.Body.Length)))")

# ── 2) 参数闸门 ────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "[2] 参数闸门（group_by 白名单 / from>to / 夹取）"
foreach ($g in @('source', 'reason_code', 'model_name')) {
    $r = Req ("g-" + $g) 'GET' ("/api/v1/admin/ai/triage-stats?group_by=$g") $AH $null
    CheckD "group_by=$g ⇒ 200" ($r.Code -eq 200) ("HTTP $($r.Code)")
}
$r = Req 'g-bad' 'GET' '/api/v1/admin/ai/triage-stats?group_by=id' $AH $null
$gj = Json $r
CheckD "★★ group_by=id ⇒ 400 VALIDATION_FAILED（列名要拼进 SQL，只认白名单）" `
       ($r.Code -eq 400 -and $gj.error.code -eq 'VALIDATION_FAILED') `
       ("HTTP $($r.Code) message=$($gj.error.message)")
$r = Req 'g-inj' 'GET' ("/api/v1/admin/ai/triage-stats?group_by=" + [uri]::EscapeDataString("source;DROP TABLE triage_stat")) $AH $null
CheckD "★★★ 注入串 ⇒ 400（不是「回退默认值继续查」）" `
       ($r.Code -eq 400) ("HTTP $($r.Code)")
$tbl = Invoke-MySqlScalar -My $My -Sql "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'triage_stat'" -Label "查表还在"
CheckD "★★★ 且 triage_stat 表仍然存在（注入真的没被执行）" ("$tbl" -eq '1') ("rows=$tbl")
$r = Req 'g-range' 'GET' '/api/v1/admin/ai/triage-stats?from=100&to=50' $AH $null
CheckD "★ from>to ⇒ 400（**不自动交换**：交换会把调用方的参数错误掩盖成一次成功）" `
       ($r.Code -eq 400) ("HTTP $($r.Code)")
$r = Req 'g-lim0' 'GET' '/api/v1/admin/ai/triage-stats?limit=0&group_limit=0' $AH $null
$j = Json $r
CheckD "★ limit=0 / group_limit=0 ⇒ 200 且夹到 1（不是 0 行、也不是 500）" `
       ($r.Code -eq 200 -and [int]$j.data.sample_limit -eq 1 -and [int]$j.data.group_limit -eq 1) `
       ("HTTP $($r.Code) sample_limit=$($j.data.sample_limit) group_limit=$($j.data.group_limit)")
$r = Req 'g-limmax' 'GET' '/api/v1/admin/ai/triage-stats?limit=999999&group_limit=999999' $AH $null
$j = Json $r
CheckD "★ limit/group_limit 超上限 ⇒ 夹到 20000 / 100（分位数在内存算，必须有上限）" `
       ($r.Code -eq 200 -and [int]$j.data.sample_limit -eq 20000 -and [int]$j.data.group_limit -eq 100) `
       ("sample_limit=$($j.data.sample_limit) group_limit=$($j.data.group_limit)")

# ── 3) 一次真调用 → 按 request_id 捞出全链路 ───────────────────────────────
Write-Host ""
Write-Host "[3] 单次调用全链路（triage-calls/:requestId）"
$rid1 = "$tag-a1"
$r = Req 't1' 'POST' '/api/v1/triage' ($PH + "X-Request-Id: $rid1") ('{"chief_complaint":"' + $secret + '"}')
$tj = Json $r
CheckD "★ 分诊响应里的 request_id == 我们发的 X-Request-Id（遥测与日志对得上号）" `
       ($r.Code -eq 200 -and $tj.data.request_id -eq $rid1) `
       ("HTTP $($r.Code) request_id=$($tj.data.request_id)")

$r = Req 'c1' 'GET' "/api/v1/admin/ai/triage-calls/$rid1" $AH $null
$cj = Json $r
CheckD "★ GET triage-calls/<刚才那个 id> ⇒ 200 且至少 1 行（落库与读出口对得上）" `
       ($r.Code -eq 200 -and [int]$cj.data.count -ge 1) ("HTTP $($r.Code) count=$($cj.data.count)")
Check "回显 request_id 与 order=id_desc（顺序口径显式给出，不靠调用方猜）" `
      ($cj.data.request_id -eq $rid1 -and $cj.data.order -eq 'id_desc')
if ([int]$cj.data.count -ge 1) {
    $it = @($cj.data.items)[0]
    $keys = @('id', 'created_at', 'source', 'reason_code', 'red_flag', 'department',
              'truncated', 'request_id', 'model_id', 'model_name', 'prompt_revision',
              'elapsed_ms', 'degrade_reason', 'degraded', 'red_flag_bypass', 'used_kb', 'kb_doc_ids')
    $missing = @($keys | Where-Object { -not ($it.PSObject.Properties.Name -contains $_) })
    CheckD "★★ 17 个排障字段一个不少（缺：$($missing -join ',')）" ($missing.Count -eq 0) `
           ("keys=$($it.PSObject.Properties.Name -join ',')")
    CheckD "★★ degraded 与 red_flag_bypass 是同一口径的**互补**布尔：RED_FLAG 旁路不算降级（看板按 degraded 过滤时不该把规则拦下来的红标算成 AI 失败）" `
           ($it.degraded -eq ($it.degrade_reason -ne '' -and $it.degrade_reason -ne 'RED_FLAG') `
            -and $it.red_flag_bypass -eq ($it.degrade_reason -eq 'RED_FLAG')) `
           ("degraded=$($it.degraded) bypass=$($it.red_flag_bypass) reason='$($it.degrade_reason)'")
    CheckD "★ source 是三种如实标注之一（实得 '$($it.source)'）" `
           (@('rules', 'model', 'model:invalid') -contains $it.source)
    $codes = @('', 'RED_FLAG', 'CONFIG_READ_FAILED', 'AI_DISABLED', 'INVALID_OUTPUT', 'CALL_FAILED')
    CheckD "★★ degrade_reason 是**稳定码表**里的值（实得 '$($it.degrade_reason)'）——给人看的 ai_reason 改文案不会让历史聚合断成两段" `
           ($codes -contains $it.degrade_reason)
    CheckD "★★ prompt_revision >= 1（0 会被读成「没读到配置」；实得 $($it.prompt_revision)）" `
           ([int]$it.prompt_revision -ge 1)
    CheckD "★ 耗时/知识库字段类型正确（elapsed_ms=$($it.elapsed_ms) used_kb=$($it.used_kb)）" `
           ($null -ne $it.elapsed_ms -and $null -ne $it.used_kb)
    CheckD "★ 请求号回显的就是我们传的那个（request_id=$($it.request_id)）" ($it.request_id -eq $rid1)
} else {
    Check "★★ 16 个排障字段一个不少" $false
}

$r = Req 'c2' 'GET' ("/api/v1/admin/ai/triage-calls/$tag-nope") $AH $null
$cj2 = Json $r
CheckD "★★ 未知 requestId ⇒ 200 + count=0（**不是 404**：没记录不等于 id 不存在）" `
       ($r.Code -eq 200 -and [int]$cj2.data.count -eq 0 -and @($cj2.data.items).Count -eq 0) `
       ("HTTP $($r.Code) count=$($cj2.data.count)")
$r = Req 'c3' 'GET' ("/api/v1/admin/ai/triage-calls/$rid1`?limit=0") $AH $null
$cj3 = Json $r
CheckD "★ limit=0 ⇒ 夹到 1 且只回 1 行" ($r.Code -eq 200 -and [int]$cj3.data.count -eq 1) `
       ("count=$($cj3.data.count)")

# ── 3b) ★★ 超长 request_id：写侧截断 + 读侧同口径截断（复核 D2 的端到端证明）──
<#
  为什么单独立一组：Web 应用防火墙 / 网关能塞进任意长度的 X-Request-Id。
  写侧截到 64（列宽）而读侧不截，就会出现最坏的排障形态 ——
  **调用当时对得上号，事后怎么查都查不到**（"排障闭环刚好好在最需要它的时候断了"）。
  server/src/triage_stat.cj 的注释早就预言过这个坑，但只有写侧做了截断（复核 D2）。
  这一组把两半都钉住：① 超长 id 不导致 400/500；② 用完整 id 也查得到那一行；
  ③ 库里落的确实是前 64 字符（不是整串、也不是空串）。
#>
$longId = 'AI-TEL-LONG-' + ('x' * 80)      # 89 字符 > 64
$r = Req 't4' 'POST' '/api/v1/triage' ($PH + "X-Request-Id: $longId") ('{"chief_complaint":"' + $secret + '"}')
CheckD "★ 超长 X-Request-Id 仍能正常分诊（遥测写入没因列宽超限被 catch 静默吞掉）" `
       ($r.Code -eq 200) ("HTTP $($r.Code)")
$r = Req 'c4a' 'GET' ("/api/v1/admin/ai/triage-calls/$longId") $AH $null
$cj4 = Json $r
CheckD "★★ 用**完整**超长 id 查得到那一行（读侧与写侧同口径截断；读侧不截时这里是 count=0）" `
       ($r.Code -eq 200 -and [int]$cj4.data.count -ge 1) ("HTTP $($r.Code) count=$($cj4.data.count)")
$stored = Invoke-MySqlScalar -My $My -Sql "SELECT request_id FROM triage_stat WHERE request_id LIKE 'AI-TEL-LONG-%' ORDER BY id DESC LIMIT 1" -Label "查截断后的 request_id"
CheckD "★★ 库里落的是前 64 字符（实得 $("$stored".Length) 字符）" `
       ("$stored".Length -eq 64 -and "$stored" -eq $longId.Substring(0, 64)) ("stored='$stored'")
$null = Invoke-MySqlScalar -My $My -Sql "DELETE FROM triage_stat WHERE request_id LIKE 'AI-TEL-LONG-%'" -Label "清超长用例痕迹"

# ── 4) ★★★ 隐私否定断言：拿刚发出去的主诉原文当指纹 ───────────────────────
Write-Host ""
Write-Host "[4] ★★★ 隐私：遥测里不许有主诉原文与个人信息"
# 再取一次"完整窗口"的聚合体（样本量更大，扫描更有意义）
$r = Req 'pv1' 'GET' ("/api/v1/admin/ai/triage-stats?from=$from&to=$to&group_by=source&limit=5000") $AH $null
$statsBody = $r.Body
CheckD "★★★ 聚合响应里**找不到我们刚发出去的主诉原文**（指纹 '$probe'）" `
       (-not $statsBody.Contains($probe)) ("HTTP $($r.Code)")
Check "★★★ 聚合响应里没有 patient_id / doctor_id / phone / chief_complaint 字段" `
      (-not ($statsBody -match 'patient_id|doctor_id|phone|chief_complaint'))
$r = Req 'pv2' 'GET' "/api/v1/admin/ai/triage-calls/$rid1" $AH $null
CheckD "★★★ 单次调用响应里**也**找不到主诉原文（连片段都不行）" `
       (-not $r.Body.Contains($probe)) ("HTTP $($r.Code)")
Check "★★ 单次调用响应里没有个人信息字段，也没有知识库正文（只有文档 id）" `
      (-not ($r.Body -match 'patient_id|doctor_id|phone|chief_complaint|"content"'))
$leak = Invoke-MySqlScalar -My $My -Sql "SELECT COUNT(*) FROM triage_stat WHERE request_id = '$rid1' AND (source LIKE '%$probe%' OR department LIKE '%$probe%' OR model_name LIKE '%$probe%')" -Label "查遥测里是否混入主诉"
CheckD "★★★ 库里这一行也没有主诉痕迹（机制性保证：record() 的签名就收不到主诉）" `
       ("$leak" -eq '0') ("rows=$leak")

# ── 5) 聚合：计数 / 降级率 / p50<=p95 / 截断如实标注 ────────────────────────
Write-Host ""
Write-Host "[5] 聚合（triage-stats）"
$r = Req 'a1' 'GET' ("/api/v1/admin/ai/triage-stats?from=$from&to=$to&group_by=source") $AH $null
$aj = Json $r
CheckD "★ 200 且 sampled >= 1（窗口里有我们刚造的那条）" `
       ($r.Code -eq 200 -and [int]$aj.data.sampled -ge 1) ("HTTP $($r.Code) sampled=$($aj.data.sampled)")
Check "回显窗口参数 from/to/group_by/sample_limit/group_limit（排障要能复现同一次查询）" `
      ($null -ne $aj.data.from -and $null -ne $aj.data.to -and $aj.data.group_by -eq 'source' -and `
       $null -ne $aj.data.sample_limit -and $null -ne $aj.data.group_limit)
CheckD "★★ 目标 request_id 的调用被算进总体（overall.total >= 1）" `
       ([int]$aj.data.overall.total -ge 1) ("total=$($aj.data.overall.total) degraded=$($aj.data.overall.degraded)")
$rate = [double]$aj.data.overall.degrade_rate
CheckD "★ 降级率在 [0,1] 内且与 计数 自洽（rate=$rate）" `
       ($rate -ge 0 -and $rate -le 1) ("degraded=$($aj.data.overall.degraded) total=$($aj.data.overall.total)")
$p50 = [int]$aj.data.overall.p50_ms
$p95 = [int]$aj.data.overall.p95_ms
CheckD "★★ p50 <= p95（分位数算反是最容易蒙混过去的错）" ($p50 -le $p95) ("p50=$p50 p95=$p95")
$groups = @($aj.data.groups)
CheckD "★ 分组非空且每组都有 bucket/total/p50_ms/p95_ms（实得 $($groups.Count) 组）" `
       ($groups.Count -ge 1 -and (@($groups | Where-Object { $null -eq $_.bucket -or $null -eq $_.total }).Count -eq 0)) `
       ("buckets=" + (($groups | ForEach-Object { "$($_.bucket):$($_.total)" }) -join ', '))
CheckD "★★ 分组按样本量降序（第一个是最大组）" `
       (@($groups).Count -ge 1 -and [int]$groups[0].total -eq (@($groups | ForEach-Object { [int]$_.total }) | Measure-Object -Maximum).Maximum) `
       ("first_total=$($groups[0].total)")
$r = Req 'a2' 'GET' ("/api/v1/admin/ai/triage-stats?from=$from&to=$to&group_by=model_name") $AH $null
CheckD "group_by=model_name 也可用（三端待办里「按模型看质量」就靠它）" ($r.Code -eq 200) ("HTTP $($r.Code)")
$r = Req 'a3' 'GET' '/api/v1/admin/ai/triage-stats?from=1&to=2&group_by=source' $AH $null
$empty = Json $r
CheckD "★★ 窗口外 ⇒ sampled=0 / total=0 / groups 空 / p50=p95=0（空样本不是「算错」，是如实为 0）" `
       ($r.Code -eq 200 -and [int]$empty.data.sampled -eq 0 -and [int]$empty.data.overall.total -eq 0 -and `
        @($empty.data.groups).Count -eq 0 -and [int]$empty.data.overall.p50_ms -eq 0) `
       ("sampled=$($empty.data.sampled) total=$($empty.data.overall.total) groups=$(@($empty.data.groups).Count)")
$r = Req 'a4' 'GET' ("/api/v1/admin/ai/triage-stats?from=$from&to=$to&group_by=source&limit=1") $AH $null
$tr = Json $r
CheckD "★★ limit=1 且窗口里有更多样本 ⇒ truncated=true（被截断必须说出来，否则「命中率下降」的结论失去依据）" `
       ($r.Code -eq 200 -and [int]$tr.data.sampled -eq 1 -and $tr.data.truncated -eq $true) `
       ("sampled=$($tr.data.sampled) truncated=$($tr.data.truncated)")

# ── 6) ★★ 版本号随"改配置"前进（零重启链条） ──────────────────────────────
Write-Host ""
Write-Host "[6] ★★ 配置版本号（改配置 ⇒ 下一次调用就带新版本号）"
$r = Req 's0' 'GET' '/api/v1/admin/ai/settings' $AH $null
$sj = Json $r
$item = @($sj.data.items | Where-Object { $_.key -eq 'ai.timeout_secs' })[0]
$wasDefault = $item.is_default
$wasValue = $item.value
CheckD "夹具：读到 ai.timeout_secs 现值（value=$wasValue default=$wasDefault）" ($null -ne $item)

$r = Req 's1' 'PUT' '/api/v1/admin/ai/settings/ai.timeout_secs' $AH '{"value":"30"}'
CheckD "夹具：写 ai.timeout_secs=30 ⇒ 200（写配置零重启的第一步）" ($r.Code -eq 200) ("HTTP $($r.Code)")
$rid2 = "$tag-b1"
$r = Req 't2' 'POST' '/api/v1/triage' ($PH + "X-Request-Id: $rid2") ('{"chief_complaint":"' + $secret + '"}')
$r = Req 'c4' 'GET' "/api/v1/admin/ai/triage-calls/$rid2" $AH $null
$rev1 = [int](@((Json $r).data.items)[0]).prompt_revision

$r = Req 's2' 'PUT' '/api/v1/admin/ai/settings/ai.timeout_secs' $AH '{"value":"31"}'
CheckD "夹具：再写 ai.timeout_secs=31 ⇒ 200" ($r.Code -eq 200) ("HTTP $($r.Code)")
$rid3 = "$tag-b2"
$r = Req 't3' 'POST' '/api/v1/triage' ($PH + "X-Request-Id: $rid3") ('{"chief_complaint":"' + $secret + '"}')
$r = Req 'c5' 'GET' "/api/v1/admin/ai/triage-calls/$rid3" $AH $null
$rev2 = [int](@((Json $r).data.items)[0]).prompt_revision

CheckD "★★★ 改配置前后两次调用的 prompt_revision **不同且前进**（$rev1 -> $rev2）：这就是「这条结果产生于哪一版配置」的答案，也证明配置改动**没有重启进程**就生效了" `
       ($rev2 -gt $rev1 -and $rev1 -ge 1) ("rev1=$rev1 rev2=$rev2")

# 恢复原值（夹具不许改动既有配置）
if ($wasDefault -eq $true) {
    $r = Req 's3' 'DELETE' '/api/v1/admin/ai/settings/ai.timeout_secs' $AH $null
    CheckD "夹具还原：原本是默认值 ⇒ DELETE 该项（回到默认）" ($r.Code -eq 200) ("HTTP $($r.Code)")
} else {
    $r = Req 's3' 'PUT' '/api/v1/admin/ai/settings/ai.timeout_secs' $AH ('{"value":"' + $wasValue + '"}')
    CheckD "夹具还原：写回原值 $wasValue" ($r.Code -eq 200) ("HTTP $($r.Code)")
}
$r = Req 's4' 'GET' '/api/v1/admin/ai/settings' $AH $null
$item2 = @((Json $r).data.items | Where-Object { $_.key -eq 'ai.timeout_secs' })[0]
CheckD "★ 还原后回显与还原前一致（value=$($item2.value) is_default=$($item2.is_default)）" `
       ($item2.value -eq $wasValue -and $item2.is_default -eq $wasDefault)

# ── 7) 夹具自清 ────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "[7] 夹具自清"
$null = Invoke-MySqlScalar -My $My -Sql "DELETE FROM auth_user WHERE login_name LIKE '$tag%'" -Label "清账号夹具"
$null = Invoke-MySqlScalar -My $My -Sql "DELETE FROM triage_stat WHERE request_id LIKE '$tag%'" -Label "清遥测夹具"
$leftUsers = Invoke-MySqlScalar -My $My -Sql "SELECT COUNT(*) FROM auth_user WHERE login_name LIKE '$tag%'" -Label "查账号残留"
$leftStats = Invoke-MySqlScalar -My $My -Sql "SELECT COUNT(*) FROM triage_stat WHERE request_id LIKE '$tag%'" -Label "查遥测残留"
# ⚠ 这条自检之所以**可信**：本脚本每一次 POST /api/v1/triage 都自带 X-Request-Id 且都带 $tag 前缀
#   （含夹具那一次 —— 它原来不带，于是每跑一次就往 triage_stat 漏一行而自检照样打印"残留 0"）。
#   超长 id 那一组用的是另一个前缀（AI-TEL-LONG-），已在 [3b] 末尾显式删除。
CheckD "★★ 结尾自检：本次夹具残留为 0（账号 $leftUsers / 遥测 $leftStats）" `
       ("$leftUsers" -eq '0' -and "$leftStats" -eq '0')

# 保留行（配置版本号所在那行）必须还在 —— 它不是配置项，但删了版本号就断了
$revRow = Invoke-MySqlScalar -My $My -Sql "SELECT COUNT(*) FROM ai_setting WHERE k = '__revision__'" -Label "查保留行"
CheckD "★ 配置版本号的保留行仍在（本次跑动不该把它删掉）" ("$revRow" -eq '1') ("rows=$revRow")

Remove-Item $tmp -Recurse -Force

Write-Host ""
if ($fail -eq 0) {
    Write-Host "✅ 分诊遥测与排障端到端验证全部通过"
    exit 0
} else {
    Write-Host "❌ 分诊遥测与排障端到端验证失败 $fail 项"
    exit 1
}
