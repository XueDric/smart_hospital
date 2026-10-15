# AI 模型配置（管理台「AI 模型配置」页）端到端验证
#
# 为什么单独一个脚本：2026-10-14 新增的 6 条 `/api/v1/admin/ai/models*` 端点
# 是这一轮管理台里**唯一会真的往大模型服务商发请求**的接口（连通性测试），
# 也是唯一带「多条命名配置 + 默认行 + 温度」的配置面。
# 它此前零覆盖，而它坏了的现象恰好最难查：
#   · 默认行选错 ⇒ 分诊静默降级成规则（用户看到的是"AI 好像不太聪明"）
#   · request_url 拼错 ⇒ 连通性测试能过、真实分诊 404
#   · 闸门漏了 ⇒ 绕过 Prompt 校验直接落库
#
# 覆盖：
#   [1] 鉴权（无令牌 401 / 患者 403）
#   [2] 列表与播种（两条默认行、request_url 拼接、密钥不回显）
#   [3] 新建的校验闸门（明文 http / 温度越界 / 空名 / 非法 key_ref / 重名）
#   [4] PATCH 语义（只改温度不动别的）、默认行唯一
#   [5] ★★ 连通性测试：**失败也是结果**（恒 200，不 5xx），且不受 ai.enabled 影响
#   [6] 缓存失效端点（管理台「失效配置缓存」按钮）
#   [7] settings 端点的登记表闸门（prompt.* 不能从这里写）
#   [8] 删除 + 夹具残留自检
#
# ⚠ 含中文的 PowerShell 脚本必须 UTF-8 with BOM（PS 5.1 否则按 ANSI 解析 → 语法报错）。
# ⚠ header/body 全部走 curl **config 文件**（-K），理由同 auth-check.ps1。
#
# 用法：
#   .\ai-model-check.ps1 -Base http://127.0.0.1:8091 -AdminPw <口令>

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

$tmp = Join-Path $env:TEMP ("aimodel-" + [Guid]::NewGuid().ToString("N"))
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

# 夹具名前缀：脚本自建自清的唯一依据（结尾会按它自检残留为 0）
$tag = "AI-MODEL-CHK-" + ([Guid]::NewGuid().ToString("N").Substring(0, 8))

Write-Host "=== AI 模型配置端到端验证 ==="
Write-Host "  目标: $Base"
Write-Host "  夹具前缀: $tag"
Write-Host ""

# ── 登录 ───────────────────────────────────────────────────────────────────
$r = Req 'login' 'POST' '/api/v1/auth/login' @() ('{"login_name":"' + $AdminLogin + '","password":"' + $AdminPw + '"}')
if ($r.Code -ne 200) {
    # 限流是服务端的正常保护：能清就清掉计数再重试一次，然后才谈失败
    if (Test-HospLoginRateLimited -Login $AdminLogin -Resp $r -My $My) {
        $r = Req 'login2' 'POST' '/api/v1/auth/login' @() ('{"login_name":"' + $AdminLogin + '","password":"' + $AdminPw + '"}')
    }
    if ($r.Code -ne 200) { Stop-HospLogin -Login $AdminLogin -Resp $r -My $My -Base $Base -Hint '[提示] 管理员口令由 create-admin 生成；确认 -Dsn 指向的库与服务端是同一个。' }
}
$admTok = (Json $r).data.token
$AH = @("Authorization: Bearer $admTok")

# ── 1) 鉴权 ────────────────────────────────────────────────────────────────
Write-Host "[1] 鉴权"
$r = Req 'n1' 'GET' '/api/v1/admin/ai/models' @() $null
Check "无令牌 ⇒ 401（不是 200、也不是 500）" ($r.Code -eq 401) 

# 患者令牌：建一个用途单一的一次性账号（不碰既有夹具）
$patLogin = "$tag-p"
$r = Req 'p0' 'POST' '/api/v1/admin/users' $AH ('{"login_name":"' + $patLogin + '","role":"patient","ref_id":1,"display_name":"' + $tag + '","password":"Ai-Model-Chk-Pw-1!"}')
Check "夹具：建患者账号（201 新建 / 409 已存在都算成功）" ($r.Code -eq 201 -or $r.Code -eq 409)
$r = Req 'p1' 'POST' '/api/v1/auth/login' @() ('{"login_name":"' + $patLogin + '","password":"Ai-Model-Chk-Pw-1!"}')
if ($r.Code -eq 200) {
    $patTok = (Json $r).data.token
    $PH = @("Authorization: Bearer $patTok")
    $r = Req 'p2' 'GET' '/api/v1/admin/ai/models' $PH $null
    Check "★★ 患者令牌 ⇒ 403 FORBIDDEN_ROLE（模型配置里有密钥引用，不能给患者看）" `
          ($r.Code -eq 403 -and (Json $r).error.code -eq 'FORBIDDEN_ROLE')
} else {
    Check "★★ 患者令牌 ⇒ 403 FORBIDDEN_ROLE" $false
}

# ── 2) 列表与播种 ──────────────────────────────────────────────────────────
Write-Host ""
Write-Host "[2] 列表与默认行（播种）"
$r = Req 'l1' 'GET' '/api/v1/admin/ai/models?include_disabled=true' $AH $null
$lj = Json $r
CheckD "列表 ⇒ 200" ($r.Code -eq 200) ("HTTP $($r.Code)")
Check "返回 items / count / global_key_ref_set / cache_ttl_secs" `
      ($null -ne $lj.data.items -and $null -ne $lj.data.count -and `
       $null -ne $lj.data.global_key_ref_set -and $null -ne $lj.data.cache_ttl_secs)
$chat = @($lj.data.items | Where-Object { $_.kind -eq 'CHAT' -and $_.is_default -eq $true })
$emb  = @($lj.data.items | Where-Object { $_.kind -eq 'EMBEDDING' -and $_.is_default -eq $true })
CheckD "★★ 每种类型各有一个默认行（CHAT=$($chat.Count) EMBEDDING=$($emb.Count)）" `
       ($chat.Count -eq 1 -and $emb.Count -eq 1)
# ★★ request_url 是**服务端拼**出来的（客户端只填 base_url）：拼接错了，连通性测试会过、真实分诊 404
CheckD "★★ CHAT 默认行的 request_url 以 /chat/completions 结尾" `
       ($chat[0].request_url -match '/chat/completions$') ("url=$($chat[0].request_url)")
CheckD "★★ EMBEDDING 默认行的 request_url 以 /embeddings 结尾" `
       ($emb[0].request_url -match '/embeddings$') ("url=$($emb[0].request_url)")
Check "★ base_url 与 request_url 不同（说明确实是拼过的，不是原样回显）" `
      ($chat[0].base_url -ne $chat[0].request_url)
# ★★★ 密钥永不回显：key_ref 只以 key_ref_set/key_ref_kind 两个"存在性"字段出现
Check "★★★ 列表里没有 key_ref 明文（只有 key_ref_set / key_ref_kind）" `
      (-not ($r.Body -match '"key_ref"\s*:\s*"[^"]')) ("body=$($r.Body.Substring(0, [Math]::Min(240, $r.Body.Length)))")
CheckD "缓存 TTL = 5 秒（管理台把它印在提示语里）" ([int]$lj.data.cache_ttl_secs -eq 5) ("ttl=$($lj.data.cache_ttl_secs)")

# ── 3) 新建的校验闸门 ──────────────────────────────────────────────────────
Write-Host ""
Write-Host "[3] 新建（POST）的校验闸门"
function NewModel($nameSuffix, $extraJson) {
    $body = '{"name":"' + $tag + $nameSuffix + '","kind":"chat","provider":"自测",' +
            '"base_url":"https://example.invalid/v1","model":"probe-model",' + $extraJson + '}'
    return Req ("c" + $nameSuffix) 'POST' '/api/v1/admin/ai/models' $AH $body
}
$r = NewModel '-a' '"temperature":0.5,"max_tokens":1024'
$mj = Json $r
CheckD "✓ 合法新建 ⇒ 201（HTTP $($r.Code)）" ($r.Code -eq 201) ("body=$($r.Body)")
$newId = if ($r.Code -eq 201) { [int]$mj.data.id } else { 0 }
CheckD "★ kind 归一：小写 chat ⇒ CHAT（不让 'chat'/'CHAT' 变成两种类型）" `
       ($mj.data.model.kind -eq 'CHAT') ("kind=$($mj.data.model.kind)")
CheckD "★ 新建响应里带 request_url（前端不必自己拼）" `
       ($mj.data.model.request_url -match '/chat/completions$') ("url=$($mj.data.model.request_url)")
Check "★★ 温度按值返回（0.5 不是 0.5 变 0）" ([double]$mj.data.model.temperature -eq 0.5) 

$r = Req 'cdup' 'POST' '/api/v1/admin/ai/models' $AH ('{"name":"' + $tag + '-a","kind":"CHAT","provider":"自测","base_url":"https://example.invalid/v1","model":"probe-model"}')
CheckD "★★ 同名再建 ⇒ 409 AI_MODEL_NAME_TAKEN（同名两条会让'默认行'变成掷骰子）" `
       ($r.Code -eq 409 -and (Json $r).error.code -eq 'AI_MODEL_NAME_TAKEN') ("HTTP $($r.Code)")

$r = Req 'chttp' 'POST' '/api/v1/admin/ai/models' $AH ('{"name":"' + $tag + '-http","kind":"CHAT","provider":"自测","base_url":"http://example.invalid/v1","model":"probe-model"}')
CheckD "★★ 明文 http:// ⇒ 400（密钥会在网络上裸奔）" ($r.Code -eq 400) ("HTTP $($r.Code) code=$(($r.Body | ConvertFrom-Json).error.code)")

$r = Req 'ctemp' 'POST' '/api/v1/admin/ai/models' $AH ('{"name":"' + $tag + '-temp","kind":"CHAT","provider":"自测","base_url":"https://example.invalid/v1","model":"probe-model","temperature":2.5}')
Check "★ 温度 2.5（越界）⇒ 400" ($r.Code -eq 400) ("HTTP $($r.Code)")

$r = Req 'ctok' 'POST' '/api/v1/admin/ai/models' $AH ('{"name":"' + $tag + '-tok","kind":"CHAT","provider":"自测","base_url":"https://example.invalid/v1","model":"probe-model","max_tokens":8}')
Check "★ max_tokens 8（小于下限 64）⇒ 400" ($r.Code -eq 400) ("HTTP $($r.Code)")

$r = Req 'cnoname' 'POST' '/api/v1/admin/ai/models' $AH '{"kind":"CHAT","provider":"自测","base_url":"https://example.invalid/v1","model":"probe-model"}'
Check "★ 缺 name ⇒ 400（不是"建出个没名字的配置"）" ($r.Code -eq 400) ("HTTP $($r.Code)")

$r = Req 'ckind' 'POST' '/api/v1/admin/ai/models' $AH ('{"name":"' + $tag + '-kind","kind":"RERANK","provider":"自测","base_url":"https://example.invalid/v1","model":"probe-model"}')
Check "★ 未知 kind（RERANK）⇒ 400（只认 CHAT / EMBEDDING）" ($r.Code -eq 400) ("HTTP $($r.Code)")

$r = Req 'ckref' 'POST' '/api/v1/admin/ai/models' $AH ('{"name":"' + $tag + '-kref","kind":"CHAT","provider":"自测","base_url":"https://example.invalid/v1","model":"probe-model","key_ref":"sk-plaintext-not-allowed"}')
CheckD "★★ key_ref 只收 env:/file: 两种引用（明文密钥进不了库）⇒ 400" `
       ($r.Code -eq 400) ("HTTP $($r.Code) code=$(($r.Body | ConvertFrom-Json).error.code)")

# ── 4) PATCH 语义与默认行唯一 ──────────────────────────────────────────────
Write-Host ""
Write-Host "[4] PATCH 语义（只给要改的字段）"
$r = Req 'u1' 'PUT' "/api/v1/admin/ai/models/$newId" $AH '{"temperature":0.9}'
$uj = Json $r
CheckD "✓ 只改温度 ⇒ 200" ($r.Code -eq 200) ("HTTP $($r.Code) body=$($r.Body)")
CheckD "★★ 未提到的字段保持原值（max_tokens 仍 1024、model 仍 probe-model）" `
       ([int]$uj.data.model.max_tokens -eq 1024 -and $uj.data.model.model -eq 'probe-model') `
       ("max_tokens=$($uj.data.model.max_tokens) model=$($uj.data.model.model)")
Check "★★ 温度确实改成了 0.9" ([double]$uj.data.model.temperature -eq 0.9)

$r = Req 'u2' 'PUT' "/api/v1/admin/ai/models/$newId" $AH '{"key_ref":"env:AI_MODEL_CHK_KEY"}'
CheckD "★ 给 key_ref ⇒ key_ref_set=true、kind=env" `
       ($r.Code -eq 200 -and (Json $r).data.model.key_ref_set -eq $true -and (Json $r).data.model.key_ref_kind -eq 'env') `
       ("body=$($r.Body)")
$r = Req 'u3' 'PUT' "/api/v1/admin/ai/models/$newId" $AH '{"key_ref":""}'
CheckD "★ 显式给空串 ⇒ 清空（区分"没给"与"给空"）" `
       ($r.Code -eq 200 -and (Json $r).data.model.key_ref_set -eq $false) ("body=$($r.Body)")

$r = Req 'u4' 'PUT' "/api/v1/admin/ai/models/$newId" $AH '{"is_default":true}'
CheckD "★ 设为默认 ⇒ 200 且该行 is_default=true" `
       ($r.Code -eq 200 -and (Json $r).data.model.is_default -eq $true) ("body=$($r.Body)")
$r = Req 'l2' 'GET' '/api/v1/admin/ai/models?include_disabled=true' $AH $null
$chatDefaults = @((Json $r).data.items | Where-Object { $_.kind -eq 'CHAT' -and $_.is_default -eq $true })
CheckD "★★ 同一类型只能有一个默认行（实得 $($chatDefaults.Count)）" `
       ($chatDefaults.Count -eq 1) ("defaults=$(($chatDefaults | ForEach-Object { $_.id }) -join ',')")

# ── 5) ★★ 连通性测试：失败也是结果 ─────────────────────────────────────────
Write-Host ""
Write-Host "[5] ★★ 连通性测试（恒 200，不把"连不上"报成 5xx）"
$r = Req 't1' 'POST' "/api/v1/admin/ai/models/$newId/test" $AH $null
$tj = Json $r
CheckD "★★ 探测一个不存在的域名 ⇒ 仍返回 200（失败是结果，不是故障）" `
       ($r.Code -eq 200) ("HTTP $($r.Code) body=$($r.Body.Substring(0, [Math]::Min(200, $r.Body.Length)))")
Check "★ probe 带 ok/kind/model/request_url/reason/http_status/elapsed_ms/key_source 字段" `
      ($null -ne $tj.data.probe.ok -and $null -ne $tj.data.probe.request_url -and `
       $null -ne $tj.data.probe.reason -and $null -ne $tj.data.probe.http_status)
CheckD "★★ 无密钥时 reason 明确指向"密钥"（不给"未知错误"这种没法查的答复）" `
       ($tj.data.probe.ok -eq $false -and $tj.data.probe.reason -match '密钥') ("reason=$($tj.data.probe.reason)")

# ★★ 探测**不受 ai.enabled 总开关影响**：总开关关掉时更需要这个按钮来回答"配置到底通不通"
$r = Req 's0' 'GET' '/api/v1/admin/ai/settings' $AH $null
$enabledBefore = (@((Json $r).data.items | Where-Object { $_.key -eq 'ai.enabled' })[0]).value
$null = Req 's1' 'PUT' '/api/v1/admin/ai/settings/ai.enabled' $AH '{"value":"0"}'
$r = Req 't2' 'POST' "/api/v1/admin/ai/models/$newId/test" $AH $null
CheckD "★★★ ai.enabled=0 时仍能测（恒 200）—— 排查"配置对不对"不该被总开关挡住" `
       ($r.Code -eq 200) ("HTTP $($r.Code)")
$null = Req 's2' 'PUT' '/api/v1/admin/ai/settings/ai.enabled' $AH ('{"value":"' + "$enabledBefore" + '"}')
$r = Req 's3' 'GET' '/api/v1/admin/ai/settings' $AH $null
$enabledAfter = (@((Json $r).data.items | Where-Object { $_.key -eq 'ai.enabled' })[0]).value
CheckD "★ 夹具自清：ai.enabled 已还原（$enabledBefore）" ("$enabledAfter" -eq "$enabledBefore") ("before=$enabledBefore after=$enabledAfter")

# ── 6) 缓存失效端点 ────────────────────────────────────────────────────────
Write-Host ""
Write-Host "[6] 失效配置缓存（管理台按钮）"
$r = Req 'inv' 'POST' '/api/v1/admin/ai/models/invalidate' $AH $null
$ivj = Json $r
CheckD "✓ ⇒ 200 且 invalidated=true" ($r.Code -eq 200 -and $ivj.data.invalidated -eq $true) ("body=$($r.Body)")
Check "★ 响应同时报两份 TTL 与 next_call_reloads（页面据此写提示语）" `
      ($null -ne $ivj.data.model_cache_ttl_secs -and $null -ne $ivj.data.settings_cache_ttl_secs -and `
       $ivj.data.next_call_reloads -eq $true)
Check "★ 带 cleared_at 时间戳" ([int64]$ivj.data.cleared_at -gt 0) ("cleared_at=$($ivj.data.cleared_at)")
# ★ 失效后必须真的能读到"刚写进库的值"：绕过 HTTP 直接改库，再失效，再读
$null = Invoke-MySqlScalar -My $My -Sql "UPDATE ai_model SET temperature = 1.75 WHERE id = $newId" -Label "改温度"
$null = Req 'inv2' 'POST' '/api/v1/admin/ai/models/invalidate' $AH $null
$r = Req 'l3' 'GET' '/api/v1/admin/ai/models?include_disabled=true' $AH $null
$afterInv = @((Json $r).data.items | Where-Object { $_.id -eq $newId })[0]
CheckD "★★ 失效后列表读到的是**库里的新值** 1.75（证明失效不是摆设）" `
       ([double]$afterInv.temperature -eq 1.75) ("temperature=$($afterInv.temperature)")

# ── 7) settings 端点的登记表闸门 ───────────────────────────────────────────
Write-Host ""
Write-Host "[7] settings 登记表闸门（prompt.* 不能从 settings 写进去）"
$r = Req 'g1' 'PUT' '/api/v1/admin/ai/settings/prompt.dept' $AH '{"value":"绕过校验的模板 {主诉}"}'
CheckD "★★★ PUT /admin/ai/settings/prompt.dept ⇒ 400（该走 /admin/ai/prompts/:name）" `
       ($r.Code -eq 400 -and (Json $r).error.code -eq 'VALIDATION_FAILED') `
       ("HTTP $($r.Code) message=$(($r.Body | ConvertFrom-Json).error.message)")
# 闸门是"拒绝写"，不是"写进去再纠正"：库里不能留下这一行
$leak = Invoke-MySqlScalar -My $My -Sql "SELECT COUNT(*) FROM ai_setting WHERE k = 'prompt.dept'" -Label "查是否落库"
CheckD "★★★ 且库里没有留下 prompt.dept 这一行（闸门必须在写之前拦）" ("$leak" -eq '0') ("rows=$leak")

# ── 8) 删除与残留自检 ──────────────────────────────────────────────────────
Write-Host ""
Write-Host "[8] 删除与夹具自清"
$r = Req 'd1' 'DELETE' "/api/v1/admin/ai/models/$newId" $AH $null
CheckD "✓ 删除 ⇒ 200 {id, deleted:true}（硬删；"留着不用"应改用停用）" `
       ($r.Code -eq 200 -and (Json $r).data.deleted -eq $true) ("body=$($r.Body)")
$r = Req 'd2' 'DELETE' "/api/v1/admin/ai/models/$newId" $AH $null
CheckD "★ 再删同一条 ⇒ 404 AI_MODEL_NOT_FOUND（不是 200 的假成功）" `
       ($r.Code -eq 404 -and (Json $r).error.code -eq 'AI_MODEL_NOT_FOUND') ("HTTP $($r.Code)")

# ★★ 「生效中」：默认行被删/被停用后，运行时退到该类型第一条启用的行 ——
#    这个"退而求其次"的结果必须能从接口读回来，否则页面会出现
#    「一行默认标记都没有、但 AI 确实在用某一行」的静默状态。
$r = Req 'l4' 'GET' '/api/v1/admin/ai/models?include_disabled=true' $AH $null
$chatRows = @((Json $r).data.items | Where-Object { $_.kind -eq 'CHAT' })
$chatInUse = @($chatRows | Where-Object { $_.in_use -eq $true })
CheckD "★★ 默认行被删后，同类型剩下的那行报 in_use=true（页面显示「生效中」）" `
       ($chatInUse.Count -eq 1 -and (@($chatRows | Where-Object { $_.is_default -eq $true })).Count -eq 0) `
       ("chat_rows=$($chatRows.Count) in_use=$(if ($chatInUse.Count -eq 1) { $chatInUse[0].name } else { '(none)' })")
# ★ 夹具自清：把默认位还给播种行（本脚本先把默认位抢到探针行、又把探针删了）
if ($chatRows.Count -ge 1) {
    $null = Req 'r1' 'PUT' ("/api/v1/admin/ai/models/" + $chatRows[0].id) $AH '{"is_default":true}'
}

# 清理这次跑留下的所有夹具（含上面各条校验失败但可能已落库的残渣）
$null = Invoke-MySqlScalar -My $My -Sql "DELETE FROM ai_model WHERE name LIKE '$tag%'" -Label "清模型夹具"
$null = Invoke-MySqlScalar -My $My -Sql "DELETE FROM auth_user WHERE login_name LIKE '$tag%'" -Label "清账号夹具"
$leftModels = Invoke-MySqlScalar -My $My -Sql "SELECT COUNT(*) FROM ai_model WHERE name LIKE '$tag%'" -Label "查模型残留"
$leftUsers = Invoke-MySqlScalar -My $My -Sql "SELECT COUNT(*) FROM auth_user WHERE login_name LIKE '$tag%'" -Label "查账号残留"
CheckD "★★ 结尾自检：本次夹具残留为 0（模型 $leftModels / 账号 $leftUsers）" `
       ("$leftModels" -eq '0' -and "$leftUsers" -eq '0')

# 播种的两条默认行必须还在（本脚本不该动它们）
$seedRows = Invoke-MySqlScalar -My $My -Sql "SELECT COUNT(*) FROM ai_model WHERE is_default = 1" -Label "查默认行"
CheckD "★ 两条播种默认行仍在（自测不破坏既有配置）" ([int]$seedRows -ge 2) ("default_rows=$seedRows")

Remove-Item $tmp -Recurse -Force

Write-Host ""
if ($fail -eq 0) {
    Write-Host "✅ AI 模型配置端到端验证全部通过"
    exit 0
} else {
    Write-Host "❌ AI 模型配置端到端验证失败 $fail 项"
    exit 1
}
