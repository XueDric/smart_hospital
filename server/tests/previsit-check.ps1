# P2 预问诊 HTTP / SSE 端到端验证
#
# 与其它测试的分工：
#   · triagetest 的 rp* 用例 —— **纯逻辑**（SSE 帧格式、业务值完整性、字符截断）
#   · 本脚本 —— **HTTP 层**：流式真的流出来了、多轮状态机、业务值非流式、越权
#
# ⚠ 含中文的 PowerShell 脚本必须 UTF-8 with BOM。
#
# 用法：.\previsit-check.ps1 -Base http://127.0.0.1:8091 -AdminPw <口令>

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

$tmp = Join-Path $env:TEMP ("pv-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$null = Invoke-MySqlScalar -My $My -Sql "DELETE FROM auth_login_attempt" -Label "清限流计数"
$null = Invoke-MySqlScalar -My $My -Sql "DELETE FROM previsit_session" -Label "清预问诊会话"

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
    return @{ Http = [int]$parts[1].Trim(); Body = $parts[0].Trim(); Json = $obj; Raw = $raw }
}

# 拿 SSE 的**原始**响应体（不走 -w 的 state 拼接，直接看帧）
function GetSse($name, $path, $headers) {
    $f = Join-Path $tmp "$name.cfg"
    $lines = @('request = "GET"')
    foreach ($h in $headers) { $lines += "header = `"$h`"" }
    $lines += 'silent'
    # 用 -D 把响应头也拿出来：要验 content-type 与 chunked
    $hf = Join-Path $tmp "$name.hdr"
    $lines += ('dump-header = "' + ($hf -replace '\\','/') + '"')
    [System.IO.File]::WriteAllText($f, ($lines -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
    $body = (& curl.exe -s -K $f "$Base$path" 2>&1) -join "`n"
    $hdr = ""
    if (Test-Path $hf) { $hdr = [System.IO.File]::ReadAllText($hf) }
    return @{ Body = $body; Header = $hdr }
}

if ([string]::IsNullOrEmpty($AdminPw)) { throw "需要 -AdminPw" }
$adm = DoReq 'adm' 'POST' '/api/v1/auth/login' @() ('{"login_name":"admin","password":"' + $AdminPw + '"}')
Check "管理员登录成功" ($adm.Http -eq 200) ("HTTP $($adm.Http)")
$admTok = $adm.Json.data.token
$pat = DoReq 'pat' 'POST' '/api/v1/auth/login' @() '{"login_name":"13800000001","password":"patient-pw-1"}'
if ($pat.Http -ne 200) { throw "患者夹具不可用（先跑 auth-check.ps1）：HTTP $($pat.Http)" }
$patTok = $pat.Json.data.token

# ── 1) 权限 ───────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "[1] 权限（预问诊只对患者开放）"
$r = DoReq 'noauth' 'GET' '/api/v1/previsit/stream?chief_complaint=%E5%92%B3%E5%97%BD' @() $null
Check "无令牌 → 401" ($r.Http -eq 401) ("HTTP $($r.Http)")
$r = DoReq 'asadmin' 'GET' '/api/v1/previsit/stream?chief_complaint=x' @("Authorization: Bearer $admTok") $null
Check "管理员调 → 403" ($r.Http -eq 403) ("HTTP $($r.Http)")

# ── 2) ★★ SSE 流真的流出来了 ──────────────────────────────────────────────
Write-Host ""
Write-Host "[2] ★★ SSE 流（对话文本可流式 —— brief §5.2）"
$sse = GetSse 'sse' '/api/v1/previsit/stream?chief_complaint=%E5%92%B3%E5%97%BD%E4%B8%89%E5%A4%A9' @("Authorization: Bearer $patTok")
Check "响应 content-type 是 text/event-stream" `
      ($sse.Header -match '(?i)content-type:\s*text/event-stream') `
      (($sse.Header -split "`n" | Where-Object { $_ -match '(?i)content-type' }) -join '; ')
Check "响应是 chunked（流式传输）" `
      ($sse.Header -match '(?i)transfer-encoding:\s*chunked')
Check "响应头含 no-cache（流式必须禁缓存）" ($sse.Header -match '(?i)cache-control:\s*no-cache')

# 解析帧：SSE 帧以空行分隔，每帧以 "data: " 开头
$body = $sse.Body
Check "★ 响应体非空（真的写出来了）" ($body.Length -gt 0) ("长度 $($body.Length)")
# ★ 关键：必须**多帧**。一帧写完整个文本 = 伪装成 SSE 的普通响应
$frameCount = ([regex]::Matches($body, '(?m)^data: ')).Count
Check "★★ 至少 3 帧（meta + delta… + done）—— 多帧才叫流式，实得 $frameCount" ($frameCount -ge 3)
Check "含 meta 帧（客户端要靠它拿 session_id）" ($body -match '"event":"meta"')
Check "含 delta 帧（逐句的对话文本）" ($body -match '"event":"delta"')
Check "含 done 帧（显式告知结束，不必靠连接关闭判断）" ($body -match '"event":"done"')
# ★ 帧之间必须有空行（\n\n）——少一个 \n 客户端会一直等下一行
Check "★ 帧以空行分隔（\n\n）" ($body -match "(?s)data: .*?\n\n")
# ★ 每帧内不得有裸换行（否则一帧被拆两帧 → 患者看到半句话）
$frames = $body -split "\n\n" | Where-Object { $_.Trim().Length -gt 0 }
$bareNl = 0
foreach ($fr in $frames) {
    $lines = $fr -split "\n"
    # 一帧只允许 1 行（data: xxx）；多于 1 行说明有裸换行
    if (($lines | Where-Object { $_.Trim().Length -gt 0 }).Count -gt 1) { $bareNl++ }
}
Check "★ 每帧恰好 1 行（帧内无裸换行），异常帧 $bareNl 个" ($bareNl -eq 0)

# 从 meta 帧取 session_id
$sid = ""
foreach ($fr in $frames) {
    if ($fr -match '"event":"meta"') {
        try {
            $o = (($fr -replace '^data: ', '') | ConvertFrom-Json)
            $sid = $o.data.session_id
        } catch { }
    }
}
Check "从 meta 帧取到 session_id（64 hex）" ($sid.Length -eq 64) ("sid=$sid")

# ── 3) ★★ 多轮状态机 ──────────────────────────────────────────────────────
Write-Host ""
Write-Host "[3] ★★ 多轮采集（业务值走普通 JSON，**不流式**）"
$r = DoReq 'q1' 'GET' "/api/v1/previsit/$sid" @("Authorization: Bearer $patTok") $null
Check "取会话成功（业务值非流式）" ($r.Http -eq 200) ("HTTP $($r.Http)")
Check "★ 响应是 JSON（不是 SSE）" ($r.Json.ok -eq $true)
Check "首轮已记下主诉 → filled = 1" ($r.Json.data.filled -eq 1) ("filled=$($r.Json.data.filled)")
Check "next_slot = duration" ($r.Json.data.next_slot -eq 'duration') ("$($r.Json.data.next_slot)")
Check "★ complete = false（未采完不给表单内容）" ($r.Json.data.complete -eq $false)
Check "★ 未完成时响应里**没有** form 字段（半成品不给出去）" ($null -eq $r.Json.data.form)

# 逐项作答直到采完
$answers = @{
    'duration'   = '3 天'
    'severity'   = '影响睡眠'
    'associated' = '有发热'
    'history'    = '高血压 5 年'
    'allergy'    = '无'
}
$order = @('duration', 'severity', 'associated', 'history', 'allergy')
$i = 0
foreach ($k in $order) {
    $r = DoReq ("a$i") 'POST' '/api/v1/previsit/answer' @("Authorization: Bearer $patTok") `
         ('{"session_id":"' + $sid + '","slot":"' + $k + '","value":"' + $answers[$k] + '"}')
    $i++
}
Check "★ 6 项全部作答后 complete = true" ($r.Json.data.complete -eq $true) ("complete=$($r.Json.data.complete)")
Check "filled = 6" ($r.Json.data.filled -eq 6) ("filled=$($r.Json.data.filled)")
Check "next_slot 为空（没有下一项了）" ($r.Json.data.next_slot -eq '') ("'$($r.Json.data.next_slot)'")
Check "★ 完成后**才**出现 form 字段" ($null -ne $r.Json.data.form)
Check "  form.chief 与提交的主诉一致（实得「$($r.Json.data.form.chief)」）" `
      ($r.Json.data.form.chief -eq '咳嗽三天')
Check "  form.allergy = 无（阴性答案被如实保留）" ($r.Json.data.form.allergy -eq '无')

# ── 4) 幂等与重试安全 ─────────────────────────────────────────────────────
Write-Host ""
Write-Host "[4] 重试幂等（按值推进，不按轮次）"
$r = DoReq 'again' 'POST' '/api/v1/previsit/answer' @("Authorization: Bearer $patTok") `
     ('{"session_id":"' + $sid + '","slot":"allergy","value":"无"}')
Check "★ 重复提交同一项不改变状态（仍 complete、filled 仍 6）" `
      ($r.Json.data.complete -eq $true -and $r.Json.data.filled -eq 6) `
      ("filled=$($r.Json.data.filled)")
$r = DoReq 'empty' 'POST' '/api/v1/previsit/answer' @("Authorization: Bearer $patTok") `
     ('{"session_id":"' + $sid + '","slot":"allergy","value":"   "}')
Check "★ 空值不覆盖已有答案（空 ≠ 没答）" ($r.Json.data.form.allergy -eq '无') ("allergy=$($r.Json.data.form.allergy)")

# ── 5) 业务值校验：未知槽位 / 超长 ────────────────────────────────────────
Write-Host ""
Write-Host "[5] 业务值校验"
$r = DoReq 'badslot' 'POST' '/api/v1/previsit/answer' @("Authorization: Bearer $patTok") `
     ('{"session_id":"' + $sid + '","slot":"id_card","value":"x"}')
Check "★ 未知槽位被拒（不能让客户端塞任意键进表单）" ($r.Http -eq 400) ("HTTP $($r.Http)")
# 超长：duration 上限 60 字符
$long = 'a' * 61
$r = DoReq 'toolong' 'POST' '/api/v1/previsit/answer' @("Authorization: Bearer $patTok") `
     ('{"session_id":"' + $sid + '","slot":"duration","value":"' + $long + '"}')
Check "★ 超长值被拒 400（按**字符**数，不是字节）" ($r.Http -eq 400) ("HTTP $($r.Http)")
# ★ 中文超长（按字节会误判：20 个汉字 = 60 字节，恰好卡在 60 字节边界）
$cn = '持' * 61
$r = DoReq 'toolongcn' 'POST' '/api/v1/previsit/answer' @("Authorization: Bearer $patTok") `
     ('{"session_id":"' + $sid + '","slot":"duration","value":"' + $cn + '"}')
Check "★ 61 个汉字（183 字节）也被拒 —— 长度按字符算" ($r.Http -eq 400) ("HTTP $($r.Http)")
$cn60 = '持' * 60
$r = DoReq 'okcn' 'POST' '/api/v1/previsit/answer' @("Authorization: Bearer $patTok") `
     ('{"session_id":"' + $sid + '","slot":"duration","value":"' + $cn60 + '"}')
Check "★ 恰好 60 个汉字被接受（边界包含）" ($r.Http -eq 200) ("HTTP $($r.Http)")

# ── 6) ★ 越权：别人的会话读不到 ──────────────────────────────────────────
Write-Host ""
Write-Host "[6] ★ 会话隔离（越权尝试）"
# 用一个不存在的 session_id
$r = DoReq 'nope' 'GET' '/api/v1/previsit/0000000000000000000000000000000000000000000000000000000000000000' `
     @("Authorization: Bearer $patTok") $null
Check "★ 不存在的 session_id → 404（**不是** 403：403 会泄露 id 是否存在）" `
      ($r.Http -eq 404) ("HTTP $($r.Http)")
Check "错误码为 PREVISIT_NOT_FOUND" ($r.Json.error.code -eq 'PREVISIT_NOT_FOUND') ("$($r.Json.error.code)")
# ★ 关键：另一个患者拿**别人的** session_id —— 必须也是 404（同一答案，不可区分）
#   造第二个患者账号并登录
$null = Invoke-MySqlScalar -My $My -Sql "INSERT IGNORE INTO patient (id, phone, name, created_at) VALUES (9601,'13900000001','越权测试患者',0)" -Label "建患者9601"
$r2 = DoReq 'mkuser' 'POST' '/api/v1/admin/users' @("Authorization: Bearer $admTok") `
      '{"login_name":"13900000001","password":"Peek12345","role":"patient","ref_id":9601}'
$null = DoReq 'resetpw' 'POST' '/api/v1/admin/users/9601/password' @("Authorization: Bearer $admTok") '{"password":"Peek12345"}'
$p2 = DoReq 'p2login' 'POST' '/api/v1/auth/login' @() '{"login_name":"13900000001","password":"Peek12345"}'
if ($p2.Http -eq 200) {
    $patTok2 = $p2.Json.data.token
    $r = DoReq 'peek' 'GET' "/api/v1/previsit/$sid" @("Authorization: Bearer $patTok2") $null
    Check "★★ 别的患者拿**有效** session_id → 同样 404（不可区分，非枚举 oracle）" `
          ($r.Http -eq 404) ("HTTP $($r.Http)")
    $r = DoReq 'peekans' 'POST' '/api/v1/previsit/answer' @("Authorization: Bearer $patTok2") `
         ('{"session_id":"' + $sid + '","slot":"duration","value":"篡改"}')
    Check "★★ 别的患者**不能改写**我的问诊单" ($r.Http -eq 404) ("HTTP $($r.Http)")
} else {
    Check "（夹具）第二患者登录（跳过则为环境问题）" $false ("HTTP $($p2.Http)")
}

# ── 7) ★ 明确边界：流式响应不能事后改状态码 ──────────────────────────────
Write-Host ""
Write-Host "[7] ★ 记录的边界（如实标注，不是缺陷）"
# 流式一旦开始写出，就无法再改成 4xx/5xx —— 所以"主诉为空"这种情况
# 必须在 streamStart **之前**判断完（当前实现就是这么做的：空主诉照常开会话，
# 由第 1 个问题去问，而不是回 400）。这里把它钉成"行为断言"，免得将来被误改。
$sse2 = GetSse 'sse2' '/api/v1/previsit/stream' @("Authorization: Bearer $patTok")
Check "★ 空主诉不报错，而是照常开流并问第 1 项（流式前不做 4xx）" `
      (($sse2.Body -match '"event":"meta"') -and ($sse2.Body -match 'main哪里不舒服|主要哪里不舒服')) `
      "（这是刻意设计：流式响应无法在开始后再改为错误码）"

# 清理
$null = Invoke-MySqlScalar -My $My -Sql "DELETE FROM previsit_session" -Label "清预问诊会话"
$null = Invoke-MySqlScalar -My $My -Sql "DELETE FROM auth_login_attempt" -Label "收尾清计数"
Remove-Item $tmp -Recurse -Force

Write-Host ""
if ($fail -eq 0) {
    Write-Host "✅ P2 预问诊 HTTP / SSE 验证全部通过"
    exit 0
} else {
    Write-Host "❌ P2 预问诊 HTTP / SSE 验证失败 $fail 项"
    exit 1
}
