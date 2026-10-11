# P2 预问诊 HTTP / SSE + P3 AI 配置 端到端验证
#
# 与其它测试的分工：
#   · triagetest 的 rp* 用例 —— **纯逻辑**（SSE 帧格式、业务值完整性、字符截断）
#   · 本脚本 —— **HTTP 层**：流式真的流出来了、多轮状态机、业务值非流式、越权
#
# ⚠ 含中文的 PowerShell 脚本必须 UTF-8 with BOM。
#
# 用法：.\previsit-check.ps1 -Base http://127.0.0.1:8091 -AdminPw <口令>
#
# 覆盖两块：
#   [1]-[7]  P2 预问诊：SSE 帧 / 多轮状态机 / 业务值非流式 / 会话隔离
#   [8]      P3 AI 能力中心：权限、改配置零重启、★ 密钥不落库且不回显

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

# ── 8) P3 AI 能力中心 ────────────────────────────────────────────────────
Write-Host ""
Write-Host "[8] ★★ P3 AI 能力中心（权限 / 零重启 / 密钥不落库与不回显）"
$null = Invoke-MySqlScalar -My $My -Sql "DELETE FROM ai_setting" -Label "清 AI 配置"

# 8.1 权限：只有管理员能读写
$r = DoReq 'ainoauth' 'GET' '/api/v1/admin/ai/settings' @() $null
Check "无令牌读配置 → 401" ($r.Http -eq 401) ("HTTP $($r.Http)")
$r = DoReq 'aipat' 'GET' '/api/v1/admin/ai/settings' @("Authorization: Bearer $patTok") $null
Check "★ 患者读配置 → 403（AI 配置含 endpoint 与部署路径，不该对患者开放）" `
      ($r.Http -eq 403) ("HTTP $($r.Http)")

# 8.2 管理员能读，且含脱敏标记
$r = DoReq 'aiadm' 'GET' '/api/v1/admin/ai/settings' @("Authorization: Bearer $admTok") $null
Check "管理员读配置 → 200" ($r.Http -eq 200) ("HTTP $($r.Http)")
Check "响应含 items 与 enabled/disabled_reason" `
      (($null -ne $r.Json.data.items) -and ($null -ne $r.Json.data.enabled)) `
      ("enabled=$($r.Json.data.enabled)")
# ⚠⚠ 这条断言 2026-10-09 **补了自备夹具**，原因是它曾**依赖测试执行顺序**：
#   它假设「AI 未配置」，于是 enabled 必为 false。而 `ai-live-check.ps1` 会**真的去配
#   `ai_setting`** —— 它跑过之后再跑本脚本，enabled 就是 true ⇒ 本条**假红**
#   （看起来像产品坏了，其实是测试间状态泄漏）。
#
# ⇒ 正确做法是**自己把前提准备好**（本仓纪律：夹具自备，不依赖别的用例留下的状态）：
#   显式清掉 AI 总开关与端点，然后再断言「未配置 ⇒ enabled=false」。
#   📌 判据：**断言一个「未配置状态下」的性质，就必须自己制造「未配置」这个状态。**
$null = DoReq 'aiclr1' 'DELETE' '/api/v1/admin/ai/settings/ai.enabled' @("Authorization: Bearer $admTok") $null
$null = DoReq 'aiclr2' 'DELETE' '/api/v1/admin/ai/settings/ai.endpoint' @("Authorization: Bearer $admTok") $null
$r = DoReq 'aiadm2' 'GET' '/api/v1/admin/ai/settings' @("Authorization: Bearer $admTok") $null
Check "清掉配置后 enabled=false 且理由非空" `
      ($r.Json.data.enabled -eq $false -and $r.Json.data.disabled_reason.Length -gt 0) `
      ("enabled=$($r.Json.data.enabled) reason=$($r.Json.data.disabled_reason)")

# 8.3 ★★ 密钥不落库：裸密钥必须被拒（HTTP 层）
foreach ($bad in @('sk-abcdefghijklmnopqrstuvwxyz012345', 'env:sk-abcdefghijklmnopqrstuvwxyz', 'https://api.x/v1?key=sk-xxx')) {
    $r = DoReq ('aibad' + [Guid]::NewGuid().ToString('N').Substring(0,6)) 'PUT' `
         '/api/v1/admin/ai/settings/ai.key_ref' @("Authorization: Bearer $admTok") ('{"value":"' + $bad + '"}')
    Check "★★ 裸密钥被拒 400（$($bad.Substring(0,[Math]::Min(20,$bad.Length)))…）" ($r.Http -eq 400) ("HTTP $($r.Http)")
}
# ★ 并且**整个响应体里不得回显被拒的值**（否则日志/响应就成了泄露渠道）
$r = DoReq 'aiecho' 'PUT' '/api/v1/admin/ai/settings/ai.key_ref' @("Authorization: Bearer $admTok") `
     '{"value":"sk-SUPERSECRETVALUE1234567890abcdef"}'
Check "★ 拒绝响应里**不回显**被拒的值" (-not ($r.Body -match 'SUPERSECRETVALUE')) ("体=$($r.Body.Substring(0,[Math]::Min(80,$r.Body.Length)))")

# 8.4 合法引用可写；回显只给"设置了没有 + 引用类型"
$r = DoReq 'aiok' 'PUT' '/api/v1/admin/ai/settings/ai.key_ref' @("Authorization: Bearer $admTok") `
     '{"value":"env:MY_SECRET_ENV_NAME"}'
Check "合法引用 env:NAME 被接受 200" ($r.Http -eq 200) ("HTTP $($r.Http)")
Check "★★ 回显**不含**变量名（连名都不回）" (-not ($r.Body -match 'MY_SECRET_ENV_NAME'))
Check "★ 回显给出 ref_kind=env" ($r.Body -match '"ref_kind":"env"') ("$($r.Body.Substring(0,[Math]::Min(100,$r.Body.Length)))")

# 8.5 ★ endpoint 回显必须脱敏（查询串可能含凭据）
$r = DoReq 'aiep' 'PUT' '/api/v1/admin/ai/settings/ai.endpoint' @("Authorization: Bearer $admTok") `
     '{"value":"https://api.example.com/v1/chat?api-key=SECRET_IN_QUERY"}'
Check "endpoint 写入 200" ($r.Http -eq 200) ("HTTP $($r.Http)")
Check "★★ 回显不含 endpoint 的查询串（可能含凭据）" (-not ($r.Body -match 'SECRET_IN_QUERY'))
Check "★ 回显只给 host" ($r.Body -match 'api\.example\.com')
Check "★ 并标记 redacted=true（告知被脱敏过）" ($r.Body -match '"redacted":true')

# 8.6 ★★ 改配置零重启：写入后**立刻**读到新值（无重启步骤）
$r = DoReq 'aimodel' 'PUT' '/api/v1/admin/ai/settings/ai.model' @("Authorization: Bearer $admTok") `
     '{"value":"zero-restart-probe-model"}'
Check "写 model 200" ($r.Http -eq 200)
$r = DoReq 'airead' 'GET' '/api/v1/admin/ai/settings' @("Authorization: Bearer $admTok") $null
Check "★★ 同一进程立刻读到新值（**零重启**）" ($r.Body -match 'zero-restart-probe-model')
# 删除 → 回到默认（空）
$null = DoReq 'aidel' 'DELETE' '/api/v1/admin/ai/settings/ai.model' @("Authorization: Bearer $admTok") $null
$r = DoReq 'airead2' 'GET' '/api/v1/admin/ai/settings' @("Authorization: Bearer $admTok") $null
Check "删除后回到默认值（回显里不再有该值）" (-not ($r.Body -match 'zero-restart-probe-model'))

# 8.6b ★★ 数值项必须**写入即校验**（第七份复查第 1 条）
#      原来 PUT ai.timeout_secs=abc 返回 200、回显 abc，而运行期静默回落成 30
#      ⇒ 回显值 ≠ 生效值，且系统报"配置有效"。
foreach ($bad in @('abc', '30秒', '9999', '-1', '1.5')) {
    $r = DoReq ('ainum' + [Guid]::NewGuid().ToString('N').Substring(0,6)) 'PUT' `
         '/api/v1/admin/ai/settings/ai.timeout_secs' @("Authorization: Bearer $admTok") ('{"value":"' + $bad + '"}')
    Check "★★ 非数字/越界 timeout='$bad' → 400（不再静默回落）" ($r.Http -eq 400) ("HTTP $($r.Http)")
}
# ★ 合法值可写，且回显值 == 生效的展示值
$r = DoReq 'ainumok' 'PUT' '/api/v1/admin/ai/settings/ai.timeout_secs' @("Authorization: Bearer $admTok") '{"value":"45"}'
Check "合法 timeout=45 被接受" ($r.Http -eq 200) ("HTTP $($r.Http)")
$r = DoReq 'ainumread' 'GET' '/api/v1/admin/ai/settings' @("Authorization: Bearer $admTok") $null
Check "★★ 回显里 timeout = 45（回显值 == 生效值）" ($r.Body -match '"value":"45"') ("体含 45 = $($r.Body -match '"value":"45"')")
# ★ 空值被接受（表示回到默认值），且回显给出默认值 30（而非空串 —— 否则管理员以为没配）
$r = DoReq 'ainumblank' 'PUT' '/api/v1/admin/ai/settings/ai.timeout_secs' @("Authorization: Bearer $admTok") '{"value":"   "}'
Check "★ 空值被接受（=回默认值），不是 400" ($r.Http -eq 200) ("HTTP $($r.Http)")
Check "★★ 空值后回显是**默认值 30**，不是空串（回显 == 生效）" ($r.Body -match '"value":"30"')
Check "★ 并标记 is_default=true" ($r.Body -match '"is_default":true')

# 8.6c ★★ Prompt 模板（占位符校验 + 零重启）
$r = DoReq 'aipr' 'GET' '/api/v1/admin/ai/prompts' @("Authorization: Bearer $patTok") $null
Check "★ 患者读 Prompt → 403（Prompt 含系统指令，不该对患者开放）" ($r.Http -eq 403) ("HTTP $($r.Http)")
$r = DoReq 'aipradm' 'GET' '/api/v1/admin/ai/prompts' @("Authorization: Bearer $admTok") $null
Check "管理员读 Prompt → 200，且含三个模板" `
      ($r.Http -eq 200 -and ([regex]::Matches($r.Body, '"name":"')).Count -ge 3) ("HTTP $($r.Http)")
Check "★ Prompt 正文**原样回显**（不是机密，管理员要能核对）" ($r.Body -match '\{主诉\}')
# ★★ 缺占位符的模板必须被拒（防「AI 静默变笨」）
foreach ($bad in @('你是导诊助手，推荐科室：{候选科室}', '请判断是否需要立即就医')) {
    $bf = Join-Path $env:TEMP ("pbad" + [Guid]::NewGuid().ToString('N').Substring(0,6) + ".json")
    [System.IO.File]::WriteAllText($bf, ('{"body":"' + $bad + '"}'), (New-Object System.Text.UTF8Encoding($false)))
    $cf = Join-Path $env:TEMP ("pbad" + [Guid]::NewGuid().ToString('N').Substring(0,6) + ".cfg")
    [System.IO.File]::WriteAllText($cf, ("request = `"PUT`"`nheader = `"Authorization: Bearer $admTok`"`nheader = `"Content-Type: application/json`"`ndata = `"@" + ($bf -replace '\\','/') + "`"`nsilent`nwrite-out = `"\n__M__%{http_code}`""), (New-Object System.Text.UTF8Encoding($false)))
    $raw = (& curl.exe -s -K $cf "$Base/api/v1/admin/ai/prompts/dept" 2>&1) -join "`n"
    $code = [int](($raw -split "__M__")[1].Trim())
    Check "★★ 缺占位符的模板被拒 400（「$($bad.Substring(0,[Math]::Min(14,$bad.Length)))…」）" ($code -eq 400) ("HTTP $code")
}
# 合法模板可写，且**立刻**生效（零重启）
$okBody = '患者主诉：{主诉}｜候选科室：{候选科室}｜请只输出 JSON。'
$bf2 = Join-Path $env:TEMP "pok.json"
[System.IO.File]::WriteAllText($bf2, ('{"body":"' + $okBody + '"}'), (New-Object System.Text.UTF8Encoding($false)))
$cf2 = Join-Path $env:TEMP "pok.cfg"
[System.IO.File]::WriteAllText($cf2, ("request = `"PUT`"`nheader = `"Authorization: Bearer $admTok`"`nheader = `"Content-Type: application/json`"`ndata = `"@" + ($bf2 -replace '\\','/') + "`"`nsilent`nwrite-out = `"\n__M__%{http_code}`""), (New-Object System.Text.UTF8Encoding($false)))
$raw2 = (& curl.exe -s -K $cf2 "$Base/api/v1/admin/ai/prompts/dept" 2>&1) -join "`n"
$code2 = [int](($raw2 -split "__M__")[1].Trim())
$body2 = ($raw2 -split "__M__")[0]
Check "合法模板写入 200" ($code2 -eq 200) ("HTTP $code2")
Check "★★ 同一响应里立刻看到新模板（零重启）" ($body2 -match '请只输出 JSON')
Check "★ 且标记 customized=true" ($body2 -match '"customized":true')
$null = DoReq 'aiprdel' 'DELETE' '/api/v1/admin/ai/prompts/dept' @("Authorization: Bearer $admTok") $null
$r = DoReq 'aiprr' 'GET' '/api/v1/admin/ai/prompts' @("Authorization: Bearer $admTok") $null
Check "恢复默认后不再含自定义正文" (-not ($r.Body -match '请只输出 JSON'))
$r = DoReq 'aiprunk' 'PUT' '/api/v1/admin/ai/prompts/no_such' @("Authorization: Bearer $admTok") '{"body":"x"}'
Check "未知 Prompt 被拒 400" ($r.Http -eq 400) ("HTTP $($r.Http)")

# 8.6d ★★ AI 工具开关（禁用即真的不可用）
$r = DoReq 'aitools' 'GET' '/api/v1/admin/ai/tools' @("Authorization: Bearer $patTok") $null
Check "★ 患者读工具开关 → 403" ($r.Http -eq 403) ("HTTP $($r.Http)")
$r = DoReq 'aitoolsadm' 'GET' '/api/v1/admin/ai/tools' @("Authorization: Bearer $admTok") $null
Check "管理员读工具开关 → 200，默认全开（6 个）" `
      ($r.Http -eq 200 -and ([regex]::Matches($r.Body, '"enabled":true')).Count -eq 6) `
      ("enabled=true 个数 = $(([regex]::Matches($r.Body, '"enabled":true')).Count)")
$r = DoReq 'aitooloff' 'PUT' '/api/v1/admin/ai/tools/bookable_slots' @("Authorization: Bearer $admTok") '{"enabled":false}'
Check "关闭一个工具 200" ($r.Http -eq 200) ("HTTP $($r.Http)")
Check "★★ 回显里该工具 enabled=false（且只剩 5 个开）" `
      (([regex]::Matches($r.Body, '"enabled":true')).Count -eq 5 -and $r.Body -match '"name":"bookable_slots","label":"[^"]*","default_on":true,"enabled":false')
$r = DoReq 'aitoolon' 'PUT' '/api/v1/admin/ai/tools/bookable_slots' @("Authorization: Bearer $admTok") '{"enabled":true}'
Check "重新打开后恢复 6 个开" (([regex]::Matches($r.Body, '"enabled":true')).Count -eq 6)
$r = DoReq 'aitoolunk' 'PUT' '/api/v1/admin/ai/tools/no_such_tool' @("Authorization: Bearer $admTok") '{"enabled":true}'
Check "★ 未登记的工具被拒 400（白名单纪律：不能新增工具）" ($r.Http -eq 400) ("HTTP $($r.Http)")
$r = DoReq 'aitoolbad' 'PUT' '/api/v1/admin/ai/tools/bookable_slots' @("Authorization: Bearer $admTok") '{"enabled":"yes"}'
Check "★ enabled 非布尔被拒 400（只认 true/false，不给表达空间）" ($r.Http -eq 400) ("HTTP $($r.Http)")

# 8.7 ★ 未登记的配置项必须被拒（否则 KV 表变垃圾场）
$r = DoReq 'aiunk' 'PUT' '/api/v1/admin/ai/settings/ai.garbage' @("Authorization: Bearer $admTok") '{"value":"x"}'
Check "★ 未登记的配置项被拒 400" ($r.Http -eq 400) ("HTTP $($r.Http)")
Check "★ 且确实没进库（$(& $My.Client -h $My.DbHost -P $My.Port -u $My.User "-p$($My.Pass)" --skip-ssl $My.Db -N -B -e "SELECT COUNT(*) FROM ai_setting WHERE k='ai.garbage'" 2>$null) 行）" `
      ("$(& $My.Client -h $My.DbHost -P $My.Port -u $My.User "-p$($My.Pass)" --skip-ssl $My.Db -N -B -e "SELECT COUNT(*) FROM ai_setting WHERE k='ai.garbage'" 2>$null)".Trim() -eq '0')

# 8.8 ★★ 全表兜底扫描：库里不得出现"像密钥"的长随机串
$rows = Invoke-MySqlScalar -My $My -Sql "SELECT COUNT(*) FROM ai_setting WHERE CHAR_LENGTH(v) >= 32 AND v NOT LIKE '%:%' AND v NOT LIKE '%/%' AND v NOT LIKE '% %'" -Label "可疑行数"
Check "★★ 全表扫描：没有任何一行的值像裸密钥（可疑 $rows 行）" ("$rows".Trim() -eq '0')

# 清理
$null = Invoke-MySqlScalar -My $My -Sql "DELETE FROM ai_setting" -Label "清 AI 配置"
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
