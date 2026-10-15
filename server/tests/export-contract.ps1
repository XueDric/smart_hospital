# SPDX-License-Identifier: MIT
#
# ===== export-contract.ps1 —— 接口契约样例「导出机」（改进 5，服务端侧）=====
#
# 要解决的问题（见 docs/CLINIC-LOOP-IMPROVEMENTS-2026-10-14.md §改进 5）：
#   "契约"目前只存在于**文档的字**里（docs/FRONTEND-INTEGRATION.md）。文档会漂：
#   2026-10-14 那次第三方复查就发现 §3.2 写的框架 404 形状（平铺 `{"error":"Not Found"}`）
#   与**今天的实测**（统一信封 `{"ok":false,"error":{"code":"ROUTE_NOT_FOUND"}}`）已经不一样了。
#   文档对不上时，前端按文档写解析 → 线上解不开 → 排查方向跑偏。
#
# 本脚本是"契约"的**唯一机器可读来源**：拿一台**真服务器**跑一组固定请求，
# 把「请求 + 状态码 + content-type + 响应体」落成 `contract/examples/*.json`。
# 前端拿这些样例当断言用（Pact/快照思路），而不是拿文档里的手抄 JSON。
#
# 用法：
#   # 生成/刷新样例（会写盘）
#   .\export-contract.ps1 -Base http://127.0.0.1:18092 -AdminPw <口令>
#   # 门禁：只比对，不写盘（不一致 ⇒ exit 1）
#   .\export-contract.ps1 -Base http://127.0.0.1:18092 -AdminPw <口令> -Check
#
# 与其它 e2e 脚本的关系：本脚本**只导出**（不做断言），断言在 contract-check.ps1。
#
# ⚠⚠ **不要与 `hospital-server.exe accept` 并发跑**（accept 的 hResetAll 会清表，
#   两边又都会 taskkill 对方的 serve）—— 同 emr-check.ps1 顶部那段说明。
# ⚠ 含中文的 PowerShell 脚本必须 **UTF-8 with BOM**（PS 5.1 否则按 ANSI 解析 → 语法报错）。
#
# ─── 归一化策略（**这是本脚本唯一的"技巧"，也是它的诚实之处**）──────────────────
#   跑两次真实请求不可能逐字节相同：自增 id、令牌、时间戳每次都不一样。
#   于是导出前把"每次都会变的"替换成**占位符**，把"契约本身"原样留下：
#     · 按**字段名**置零（数字）：id / *_id / created_at / updated_at / server_time …
#     · 按**字段名**替换（字符串）：token / session_id / request_id / device_id …
#     · 文本里的易变片段：`2026-12-26`→`<date>`、手机号→`<phone>`、≥4 位数字→`<N>`、
#       SSE 文本内嵌的 `"session_id":"<32位hex>"`→`<session_id>`
#   归一化**只按字段名**，不做启发式猜测 —— 否则"契约"会被脚本自己猜没。
#   字段名清单见下面的 $NormZero / $NormStr，改动必须同步 contract/README.md。
#
#   特例 `-Volatile`：极少数端点的**成员集合**依赖全院数据（管理员列表），
#   逐字节固定必然假红。这类样例显式声明 volatile 路径（写进样例文件的
#   `volatile` 字段），把该路径换成 `"<volatile>"`，只钉住信封与顺序。

[CmdletBinding()]
param(
    [string]$Base = "http://127.0.0.1:18092",
    [Parameter(Mandatory=$true)][string]$AdminPw,
    [string]$Dsn = "mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital_test",
    [string]$OutDir = "",
    [switch]$Check
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $repoRoot "contract\examples" }
$My = Get-MySqlClientArgs -Dsn $Dsn

function Info($m) { Write-Host "  $m" -ForegroundColor DarkGray }
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; exit 1 }

# ─── 归一化清单 ──────────────────────────────────────────────────────────────
# 数字型易变字段（置 0）。⚠ `turn` / `filled` / `total` / `count` / `version` 是
# **业务值**，一律**不**置零 —— 它们正是前端要断言的东西。
$NormZero = @(
    'id', 'appointment_id', 'patient_id', 'doctor_id', 'department_id', 'schedule_id',
    'user_id', 'ref_id', 'updated_by', 'created_at', 'updated_at', 'server_time',
    'expires_at', 'captured_at', 'published_at', 'at', 'seq_no', 'doc_id', 'chunk_id',
    'notice_id', 'chat_id', 'record_id', 'login_at', 'last_login_at', 'operator_user_id'
)
# 字符串型易变字段（换占位符）。
$NormStr = @{
    'token'         = '<token>'
    'session_id'    = '<session_id>'
    'client_token'  = '<client_token>'
    'request_id'    = '<request_id>'
    'device_id'     = '<device_id>'
    'previsit_id'   = '<previsit_id>'
    'refresh_token' = '<refresh_token>'
    'password'      = '<password>'
}

function Scrub-Text([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return $s }
    $t = $s
    $t = $t -replace '\d{4}-\d{2}-\d{2}', '<date>'
    $t = $t -replace '1[3-9]\d{9}', '<phone>'
    # 夹具里的科室/医生/患者名（名字会出现在错误文案里）
    $t = $t -replace '契约验证科', '<dept>'
    $t = $t -replace '契约医生[甲乙]', '<doctor>'
    $t = $t -replace '契约患者[甲乙丙]', '<patient>'
    # ⚠ **SSE 文本内部的会话 id**：`{"session_id":"033bf373ada7…"}`（32 位 hex）。
    #   字段名替换只对**对象属性**生效，管不到一串文本里的 JSON ——
    #   漏了这条，previsit-stream-sse-200 每次导出都会变（实测就是这样抓到的）。
    #   必须排在下面 `\d{4,}` 之前：hex 里也有长数字，先抹整段才不会只抹掉数字部分。
    $t = $t -replace '("session_id"\s*:\s*")[0-9a-fA-F]{8,}(")', '${1}<session_id>${2}'
    # 剩下的长数字（自增 id 出现在 message 里）
    $t = $t -replace '\d{4,}', '<N>'
    return $t
}

function Normalize-Node($node) {
    if ($null -eq $node) { return $null }
    if ($node -is [string]) { return (Scrub-Text $node) }
    if ($node -is [bool] -or $node -is [int] -or $node -is [int64] -or $node -is [double]) { return $node }
    if ($node -is [System.Collections.IDictionary]) {
        # 见 To-CanonicalJson 里同一处注释：ordered 字典必须走 Keys，不能走 PSObject 属性。
        $o = [ordered]@{}
        foreach ($k in @($node.Keys)) {
            $v = $node[$k]
            if ($NormStr.ContainsKey($k) -and ($v -is [string])) { $o[$k] = $NormStr[$k]; continue }
            if (($NormZero -contains $k) -and ($v -is [int] -or $v -is [int64] -or $v -is [double])) { $o[$k] = 0; continue }
            $o[$k] = Normalize-Node $v
        }
        return $o
    }
    $props = @($node.PSObject.Properties)
    if ($props.Count -gt 0 -and -not ($node -is [System.Array])) {
        $o = [ordered]@{}
        foreach ($p in $props) {
            $k = $p.Name
            $v = $p.Value
            if ($NormStr.ContainsKey($k) -and ($v -is [string])) { $o[$k] = $NormStr[$k]; continue }
            if (($NormZero -contains $k) -and ($v -is [int] -or $v -is [int64] -or $v -is [double])) { $o[$k] = 0; continue }
            $o[$k] = Normalize-Node $v
        }
        return $o
    }
    if ($node -is [System.Array]) {
        $a = @()
        foreach ($x in $node) { $a += ,(Normalize-Node $x) }
        return ,$a
    }
    return $node
}

function Norm-Path([string]$p) {
    # 路径里的自增 id（整段都是数字）→ {id}；token/会话 id 这类含字母的段不动。
    $q = $p -replace '/(\d+)(?=/|$)', '/{id}'
    # ⚠ 查询串里的自增 id 也要归一化：
    #   `?exclude_appointment_id=123` 里的 123 是当天新建挂号单的自增主键，**每次导出都不同**
    #   ⇒ 不归一化这条样例每次都红（2026-10-15 实测：doctor-patient-records-exclude-200 第 6 行）。
    #   只处理"值是库内自增 id"的键；`limit=9999` / `offset=-5` / `against=2` 这类**脚本里写死的常量**不动
    #   —— 它们正是那些样例要钉住的东西。
    $q = $q -replace '([?&](?:exclude_appointment_id|appointment_id|patient_id|schedule_id|doctor_id)=)\d+', '${1}{id}'
    return $q
}

# 把 volatile 路径（形如 data.items）换成 "<volatile>"，让这类样例只钉信封。
#
# ⚠ 路径是相对**信封体**（`response.body`）的，和 `schema-map.json` 里 `body`/`data` 两个靶位同一套坐标
#   —— 于是 `data.items` 指 `body.data.items`。
# ⚠ 路径解析不到时**直接失败**，不静默跳过：静默跳过 = 声明了 volatile 却还在逐字节比真实数据，
#   结果就是"这条样例随机假红"（2026-10-15 实测踩到：`data.items` 写成相对 response 根的路径，
#   于是 `$cur` 变 $null、函数悄悄 return，文件里存的仍是全量 items，final-verify 里 contract-check 红）。
function Set-Volatile($bodyNode, [string]$path) {
    $parts = $path.Split('.')
    $cur = $bodyNode
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        if ($null -eq $cur) { break }
        if ($cur -is [System.Collections.IDictionary]) { $cur = $cur[$parts[$i]] } else { $cur = $cur.($parts[$i]) }
    }
    $leaf = $parts[$parts.Count - 1]
    if ($null -eq $cur) {
        Fail ("volatile 路径 '{0}' 在响应体里**解析不到**：样例会随库状态假红。请核对路径拼写（相对 body，例如 data.items）" -f $path)
    }
    $hasLeaf = if ($cur -is [System.Collections.IDictionary]) { $cur.Contains($leaf) } else { $null -ne $cur.PSObject.Properties[$leaf] }
    if (-not $hasLeaf) {
        Fail ("volatile 路径 '{0}' 的最后一段 '{1}' 在响应体里不存在：样例会随库状态假红" -f $path, $leaf)
    }
    if ($cur -is [System.Collections.IDictionary]) { $cur[$leaf] = '<volatile>' } else { $cur.$leaf = '<volatile>' }
}

# ─── 规范化 JSON 文本（自己写，不用 ConvertTo-Json）──────────────────────────
# 理由：门禁是"逐字节比对"，所以序列化必须**跨 PowerShell 版本确定**。
# ConvertTo-Json 在 5.1 / 7 上对数组缩进、Unicode 转义的处理不同 ⇒ 会假红。
function Quote-Json([string]$s) {
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.Append('"')
    foreach ($ch in $s.ToCharArray()) {
        switch ($ch) {
            '"'  { $null = $sb.Append('\"') }
            '\'  { $null = $sb.Append('\\') }
            "`n" { $null = $sb.Append('\n') }
            "`r" { $null = $sb.Append('\r') }
            "`t" { $null = $sb.Append('\t') }
            default {
                if ([int]$ch -lt 0x20) { $null = $sb.Append('\u' + ([int]$ch).ToString('x4')) }
                else { $null = $sb.Append($ch) }
            }
        }
    }
    $null = $sb.Append('"')
    return $sb.ToString()
}

function To-CanonicalJson($node, [int]$indent = 0) {
    $pad = ' ' * $indent
    if ($null -eq $node) { return 'null' }
    if ($node -is [bool]) { if ($node) { return 'true' } else { return 'false' } }
    if ($node -is [int] -or $node -is [int64]) { return ([string]$node) }
    if ($node -is [double]) { return $node.ToString([System.Globalization.CultureInfo]::InvariantCulture) }
    if ($node -is [string]) { return (Quote-Json $node) }
    if ($node -is [System.Array]) {
        $items = @($node)
        if ($items.Count -eq 0) { return '[]' }
        $parts = @()
        foreach ($x in $items) { $parts += ((' ' * ($indent + 2)) + (To-CanonicalJson $x ($indent + 2))) }
        return "[`n" + ($parts -join ",`n") + "`n$pad]"
    }
    if ($node -is [System.Collections.IDictionary]) {
        # ⚠ `[ordered]@{}` 是 **IDictionary**，不是 PSCustomObject：直接落到下面的
        #   `$node.PSObject.Properties` 分支会序列化出 Count/Keys/Values 这些 .NET
        #   属性（第一版就是这么错的，样例文件里 request/response 全成了字典内部结构）。
        $keys = @($node.Keys)
        if ($keys.Count -eq 0) { return '{}' }
        $parts = @()
        foreach ($k in $keys) {
            $parts += ((' ' * ($indent + 2)) + (Quote-Json ([string]$k)) + ': ' + (To-CanonicalJson $node[$k] ($indent + 2)))
        }
        return "{`n" + ($parts -join ",`n") + "`n$pad}"
    }
    $props = @($node.PSObject.Properties)
    if ($props.Count -eq 0) { return '{}' }
    $parts = @()
    foreach ($p in $props) {
        $parts += ((' ' * ($indent + 2)) + (Quote-Json $p.Name) + ': ' + (To-CanonicalJson $p.Value ($indent + 2)))
    }
    return "{`n" + ($parts -join ",`n") + "`n$pad}"
}

# ─── HTTP 助手（curl 配置文件；**不用 -d '...'**，PowerShell 会破坏 JSON 引号）──
function Req($tag, $method, $path, $headers, $jsonBody) {
    $cfg = Join-Path $env:TEMP ("ctr_" + $tag + ".cfg")
    $hdrFile = Join-Path $env:TEMP ("ctr_" + $tag + ".hdr")
    $bodyFile = Join-Path $env:TEMP ("ctr_" + $tag + ".body")
    if (Test-Path $hdrFile) { Remove-Item $hdrFile -Force }
    if (Test-Path $bodyFile) { Remove-Item $bodyFile -Force }
    $hdrFwd = $hdrFile -replace '\\', '/'
    # ⚠ 逐条 `+=` 追加，**不要**写成一个 @(...) 字面量里带 `"` + 表达式 + `"`：
    #   实测那种写法被 PowerShell 解析成三个数组元素，配置文件里出现裸引号行，
    #   curl 报 `option -K: blank argument where content is expected`（踩过）。
    $lines = @()
    $lines += 'request = "' + $method + '"'
    $lines += 'silent'
    $lines += 'dump-header = "' + $hdrFwd + '"'
    # ⚠⚠ 响应体必须让 curl **直接写文件**，绝不能走 stdout 让 PowerShell 去解码：
    #   原生命令的 stdout 按控制台代码页（本机 GBK）解码，UTF-8 的响应体会被糟蹋成
    #   `"display_name":"管���?` —— 连 JSON 的闭合引号都被吃掉，ConvertFrom-Json 报
    #   “无效的 JSON 应为一个 : 或 }”（踩过：管理员登录那一步就炸，导出机 EXIT=1）。
    #   写文件后按 UTF-8 读回，才是**字节精确**。write-out 只剩纯 ASCII 状态码，走 stdout 安全。
    $lines += 'output = "' + ($bodyFile -replace '\\', '/') + '"'
    $lines += 'write-out = "__M__%{http_code}"'
    foreach ($h in $headers) { $lines += 'header = "' + $h + '"' }
    if ($null -ne $jsonBody) {
        $bf = Join-Path $env:TEMP ("ctr_" + $tag + ".json")
        [System.IO.File]::WriteAllText($bf, $jsonBody, (New-Object System.Text.UTF8Encoding($false)))
        $lines += 'header = "Content-Type: application/json"'
        $lines += 'data = "@' + ($bf -replace '\\', '/') + '"'
    }
    [System.IO.File]::WriteAllText($cfg, ($lines -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
    # ⚠ curl 写 stderr 时，$ErrorActionPreference='Stop' 会把 NativeCommandError 变成
    #   终止性错误 —— 单条请求的 curl 噪声不该中断整个导出，故此处临时放宽。
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $raw = (& curl.exe -s -K $cfg "$Base$path" 2>&1) -join "`n"
    $ErrorActionPreference = $prevEap
    $code = 0
    if ($raw -match '__M__(\d+)') { $code = [int]$Matches[1] }
    $body = ''
    if (Test-Path $bodyFile) { $body = [System.IO.File]::ReadAllText($bodyFile, [System.Text.Encoding]::UTF8) }
    $ct = ''
    $allow = ''
    if (Test-Path $hdrFile) {
        $h = [System.IO.File]::ReadAllText($hdrFile)
        if ($h -match '(?im)^content-type:\s*(.+?)\s*$') { $ct = $Matches[1].Trim() }
        if ($h -match '(?im)^allow:\s*(.+?)\s*$') { $allow = $Matches[1].Trim() }
    }
    $obj = $null
    try { $obj = $body | ConvertFrom-Json } catch { $obj = $null }
    return [pscustomobject]@{ Http = $code; Body = $body; Json = $obj; ContentType = $ct; Allow = $allow }
}
function Tok($login, $pw) {
    $r = Req ("lg-" + $login) 'POST' '/api/v1/auth/login' @() ('{"login_name":"' + $login + '","password":"' + $pw + '"}')
    if ($r.Http -ne 200) { throw "登录失败 $login (HTTP $($r.Http)): $($r.Body)" }
    return ($r.Body | ConvertFrom-Json).data.token
}
function SqlFile($name, $sql) {
    $p = Join-Path $env:TEMP ("ctr_" + $name + ".sql")
    [System.IO.File]::WriteAllText($p, $sql, (New-Object System.Text.UTF8Encoding($false)))
    Invoke-MySqlFile -My $My -Path ($p -replace '\\', '/')
}
function RowCount($label, $sql) { return ("$(Invoke-MySqlScalar -My $My -Label $label -Sql $sql)").Trim() }
# 建账号（201 新建 / 409 已存在）并把口令设成已知值；返回 auth_user.id。
function EnsureAccount($tag, $login, $pw, $role, $refId, $display) {
    $body = '{"login_name":"' + $login + '","password":"' + $pw + '","role":"' + $role + '"' +
            ',"ref_id":' + $refId + ',"display_name":"' + $display + '"}'
    $r = Req ("mk-" + $tag) 'POST' '/api/v1/admin/users' @("Authorization: Bearer $admTok") $body
    $uid = 0
    if ($r.Http -eq 201) { $uid = ($r.Body | ConvertFrom-Json).data.user_id }
    elseif ($r.Http -eq 409) {
        $q = Req ("find-" + $tag) 'GET' ('/api/v1/admin/users?login_name=' + $login) @("Authorization: Bearer $admTok") $null
        if ($q.Http -eq 200) { $uid = ($q.Body | ConvertFrom-Json).data.user_id }
    }
    if ($uid -gt 0) {
        $null = Req ("pw-" + $tag) 'POST' ('/api/v1/admin/users/' + $uid + '/password') `
                @("Authorization: Bearer $admTok") ('{"password":"' + $pw + '"}')
    }
    return [pscustomobject]@{ Http = $r.Http; UserId = $uid }
}

# ─── 捕获 ────────────────────────────────────────────────────────────────────
$Script:Docs = New-Object System.Collections.ArrayList
function Cap($name, $group, $method, $path, $auth, $headers, $jsonBody, $volatile = @()) {
    $r = Req ("c-" + $name) $method $path $headers $jsonBody
    if ($r.Http -le 0) { Fail "$name 没拿到 HTTP 状态码（服务在跑吗？）$($r.Body)" }
    $resp = [ordered]@{ status = $r.Http; content_type = $r.ContentType }
    if ($null -ne $r.Json) { $resp['body'] = Normalize-Node $r.Json }
    else { $resp['body_text'] = Scrub-Text $r.Body }
    if ($r.Http -eq 405 -and $r.Allow.Length -gt 0) { $resp['allow'] = $r.Allow }
    $doc = [ordered]@{
        name    = $name
        group   = $group
        request = [ordered]@{ method = $method; path = (Norm-Path $path); auth = $auth }
    }
    $doc['response'] = $resp
    if (@($volatile).Count -gt 0) {
        $doc['volatile'] = @($volatile)
        # ⚠ 相对**信封体**（$resp['body']）解析，与 schema-map 的 body/data 靶位同一套坐标。
        foreach ($vp in $volatile) { Set-Volatile $resp['body'] $vp }
    }
    $null = $Script:Docs.Add([pscustomobject]$doc)
    Info ("{0,-46} {1} {2}" -f $name, $r.Http, $r.ContentType)
    return $r
}

Write-Host ""
Write-Host "=== 契约样例导出（改进 5）===" -ForegroundColor Cyan
Write-Host "  目标: $Base"
$mode = if ($Check) { '只比对（-Check）' } else { '导出（会写盘）' }
Write-Host "  模式: $mode"
Write-Host "  输出: $OutDir"
Write-Host "  库  : $($My.Db)@$($My.DbHost):$($My.Port)"

# ── 夹具（直接写库，精确控制前置状态；id 段 706xxx 为本脚本独占）──────────────
Write-Host ""
Write-Host "[0] 准备夹具"
$null = Invoke-MySqlScalar -My $My -Label "清病历" -Sql "DELETE FROM medical_record WHERE patient_id >= 706000"
$null = Invoke-MySqlScalar -My $My -Label "清会话" -Sql "DELETE FROM previsit_session WHERE patient_id >= 706000"
$null = Invoke-MySqlScalar -My $My -Label "清挂号" -Sql "DELETE FROM appointment WHERE schedule_id >= 706000"
$null = Invoke-MySqlScalar -My $My -Label "清排班" -Sql "DELETE FROM schedule WHERE id >= 706000"
$null = Invoke-MySqlScalar -My $My -Label "清医生" -Sql "DELETE FROM doctor WHERE id >= 706000"
$null = Invoke-MySqlScalar -My $My -Label "清科室" -Sql "DELETE FROM department WHERE id >= 706000"
$null = Invoke-MySqlScalar -My $My -Label "清患者" -Sql "DELETE FROM patient WHERE id >= 706000"

$seedSql = @"
INSERT INTO department (id, name, code, created_at) VALUES (706001, '契约验证科', 'CTRC', 0);
INSERT INTO doctor (id, name, department_id, title, specialty, created_at) VALUES (706001, '契约医生甲', 706001, '主任医师', '测试', 0);
INSERT INTO doctor (id, name, department_id, title, specialty, created_at) VALUES (706002, '契约医生乙', 706001, '住院医师', '测试', 0);
INSERT INTO schedule (id, doctor_id, department_id, work_date, period, total_num, remain_num, version, enabled, created_at) VALUES (706001, 706001, 706001, '2026-12-26', 'AM', 20, 20, 0, 1, 0);
INSERT INTO schedule (id, doctor_id, department_id, work_date, period, total_num, remain_num, version, enabled, created_at) VALUES (706002, 706001, 706001, '2026-12-27', 'AM', 1, 1, 0, 1, 0);
INSERT INTO patient (id, phone, name, gender, birth_date, created_at) VALUES (706001, '13800070601', '契约患者甲', 'M', '1990-01-01', 0);
INSERT INTO patient (id, phone, name, gender, birth_date, created_at) VALUES (706002, '13800070602', '契约患者乙', 'F', '1992-02-02', 0);
INSERT INTO patient (id, phone, name, gender, birth_date, created_at) VALUES (706003, '13800070603', '契约患者丙', 'F', '1993-03-03', 0);
"@
SqlFile 'seed' $seedSql
$seedCnt = RowCount "夹具行数" ("SELECT (SELECT COUNT(*) FROM department WHERE id=706001) + (SELECT COUNT(*) FROM doctor WHERE id IN (706001,706002))" +
    " + (SELECT COUNT(*) FROM schedule WHERE id IN (706001,706002)) + (SELECT COUNT(*) FROM patient WHERE id IN (706001,706002,706003))")
if ("$seedCnt" -ne '8') { Fail "夹具未就绪：期望 8 行，实得 $seedCnt" }
Info "夹具就绪（1 科室 / 2 医生 / 2 排班 / 3 患者）"

$admTok = Tok "admin" $AdminPw
$docPw = "Contract1pass"; $doc2Pw = "Contract2pass"
$patPw = "Contract3pass"; $pat2Pw = "Contract4pass"
$null = EnsureAccount 'doc'  'contract-doc'  $docPw  'doctor'  706001 '契约医生甲'
$null = EnsureAccount 'doc2' 'contract-doc2' $doc2Pw 'doctor'  706002 '契约医生乙'
$null = EnsureAccount 'pat'  'contract-pat'  $patPw  'patient' 706001 '契约患者甲'
$null = EnsureAccount 'pat2' 'contract-pat2' $pat2Pw 'patient' 706002 '契约患者乙'
$docTok = Tok "contract-doc" $docPw
$doc2Tok = Tok "contract-doc2" $doc2Pw
$patTok = Tok "contract-pat" $patPw
$pat2Tok = Tok "contract-pat2" $pat2Pw
$A = @("Authorization: Bearer $docTok")
$A2 = @("Authorization: Bearer $doc2Tok")
$P = @("Authorization: Bearer $patTok")
$P2 = @("Authorization: Bearer $pat2Tok")
$AD = @("Authorization: Bearer $admTok")

# ── [1] 传输层 / 错误信封（三种失败形状 + 405 + /health 时间口径）────────────
Write-Host ""
Write-Host "[1] 传输层与错误信封"
$null = Cap 'health-200' 'envelope' 'GET' '/health' 'none' @() $null
$null = Cap 'error-invalid-json-400' 'envelope' 'POST' '/api/v1/auth/login' 'none' @() '{"login_name":' 
$null = Cap 'error-route-not-found-404' 'envelope' 'GET' '/api/v1/no-such-path' 'none' @() $null
$null = Cap 'error-method-not-allowed-405' 'envelope' 'PUT' '/health' 'none' @() '{"a":1}'
$null = Cap 'error-static-not-found-404' 'envelope' 'GET' '/admin/no-such-file.js' 'none' @() $null

# ── [2] 鉴权 ────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "[2] 鉴权"
$null = Cap 'auth-login-200' 'auth' 'POST' '/api/v1/auth/login' 'none' @() ('{"login_name":"contract-pat","password":"' + $patPw + '"}')
$null = Cap 'auth-login-bad-password-401' 'auth' 'POST' '/api/v1/auth/login' 'none' @() '{"login_name":"contract-pat","password":"wrong-password"}'
$null = Cap 'auth-token-missing-401' 'auth' 'GET' '/api/v1/appointments' 'none' @() $null
$null = Cap 'auth-role-forbidden-403' 'auth' 'GET' '/api/v1/doctor/visits' 'patient' $P $null

# ── [3] 挂号（含改进 4 的 by-token 与溯源字段）──────────────────────────────
Write-Host ""
Write-Host "[3] 挂号"
$b1 = Cap 'booking-create-201' 'booking' 'POST' '/api/v1/appointments' 'patient' $P `
      '{"schedule_id":706001,"client_token":"contract-tok-1"}'
if ($b1.Http -ne 201) { Fail "挂号未成功（HTTP $($b1.Http)）：$($b1.Body)" }
$appt1 = [int64]$b1.Json.data.appointment_id
$null = Cap 'booking-replay-200' 'booking' 'POST' '/api/v1/appointments' 'patient' $P `
        '{"schedule_id":706001,"client_token":"contract-tok-1"}'
$null = Cap 'booking-by-token-200' 'booking' 'GET' '/api/v1/appointments/by-token/contract-tok-1' 'patient' $P $null
$null = Cap 'booking-by-token-unknown-404' 'booking' 'GET' '/api/v1/appointments/by-token/no-such-token' 'patient' $P $null
$null = Cap 'booking-validation-missing-schedule-400' 'booking' 'POST' '/api/v1/appointments' 'patient' $P '{}'
$null = Cap 'booking-schedule-not-found-404' 'booking' 'POST' '/api/v1/appointments' 'patient' $P `
        '{"schedule_id":709999,"client_token":"contract-tok-2"}'
$null = Cap 'booking-cancel-200' 'booking' 'POST' ("/api/v1/appointments/$appt1/cancel") 'patient' $P $null
# 号源抢完：706002 只有 1 个号
$null = Req 'slotfill' 'POST' '/api/v1/appointments' $P '{"schedule_id":706002,"client_token":"contract-tok-slot1"}'
$null = Cap 'booking-slot-gone-409' 'booking' 'POST' '/api/v1/appointments' 'patient' $P2 `
        '{"schedule_id":706002,"client_token":"contract-tok-slot2"}'

# ── [4] 预问诊（SSE 线格式 + 逐项作答 + 归属）────────────────────────────────
Write-Host ""
Write-Host "[4] 预问诊"
$null = Cap 'previsit-stream-sse-200' 'previsit' 'GET' '/api/v1/previsit/stream?chief_complaint=%E4%B8%8A%E8%85%B9%E9%9A%90%E7%97%9B3%E5%A4%A9' 'patient' $P $null
$sid = 'contract-706001-A'
SqlFile 'pv' ("INSERT INTO previsit_session (id, patient_id, turn, form_json, created_at, updated_at) VALUES ('$sid', 706001, 0, '{}', 1000, 1000);")
if ((RowCount "会话" "SELECT COUNT(*) FROM previsit_session WHERE id='$sid'") -ne '1') { Fail "会话夹具未就绪" }
$slots = @(
    @('chief', '上腹隐痛 3 天'),
    @('duration', '3 天'),
    @('severity', '影响睡眠'),
    @('associated', '反酸'),
    @('history', '高血压 5 年，服降压药'),
    @('allergy', '青霉素过敏')
)
for ($i = 0; $i -lt $slots.Count; $i++) {
    $body = '{"session_id":"' + $sid + '","slot":"' + $slots[$i][0] + '","value":"' + $slots[$i][1] + '"}'
    if ($i -eq 0) { $null = Cap 'previsit-answer-200' 'previsit' 'POST' '/api/v1/previsit/answer' 'patient' $P $body }
    elseif ($i -eq $slots.Count - 1) { $null = Cap 'previsit-answer-complete-200' 'previsit' 'POST' '/api/v1/previsit/answer' 'patient' $P $body }
    else { $null = Req ("ans" + $i) 'POST' '/api/v1/previsit/answer' $P $body }
}
$null = Cap 'previsit-get-200' 'previsit' 'GET' "/api/v1/previsit/$sid" 'patient' $P $null
$null = Cap 'previsit-get-unknown-404' 'previsit' 'GET' '/api/v1/previsit/no-such-session' 'patient' $P $null
$null = Cap 'previsit-cross-patient-404' 'previsit' 'GET' "/api/v1/previsit/$sid" 'patient' $P2 $null
$null = Cap 'previsit-answer-unknown-slot-400' 'previsit' 'POST' '/api/v1/previsit/answer' 'patient' $P `
        ('{"session_id":"' + $sid + '","slot":"no_such_slot","value":"x"}')

# ── [5] 挂号带上预问诊单（改进 1：服务端绑定）────────────────────────────────
Write-Host ""
Write-Host "[5] 挂号 + 预问诊绑定"
$b2 = Cap 'booking-create-with-previsit-201' 'booking' 'POST' '/api/v1/appointments' 'patient' $P `
      ('{"schedule_id":706001,"client_token":"contract-tok-3","previsit_id":"' + $sid + '"}')
if ($b2.Http -ne 201) { Fail "带预问诊的挂号未成功（HTTP $($b2.Http)）：$($b2.Body)" }
$appt2 = [int64]$b2.Json.data.appointment_id

# ── [6] 病历（含 previsit_ref 来源痕迹、锁定、患者可见性）────────────────────
Write-Host ""
Write-Host "[6] 病历"
$null = Cap 'visits-queue-200' 'record' 'GET' '/api/v1/doctor/visits' 'doctor' $A $null
$null = Cap 'visits-previsit-200' 'record' 'GET' ("/api/v1/doctor/visits/$appt2/previsit") 'doctor' $A $null
$null = Cap 'visits-previsit-other-doctor-404' 'record' 'GET' ("/api/v1/doctor/visits/$appt2/previsit") 'doctor' $A2 $null
$null = Cap 'record-put-with-intake-200' 'record' 'PUT' ("/api/v1/doctor/visits/$appt2/record") 'doctor' $A `
        ('{"use_intake_session":"' + $sid + '","diagnosis":"急性上呼吸道感染",' +
         '"treatment":"多饮水，必要时对症退热；三天无好转复诊","physical_exam":"咽部充血，扁桃体 I 度肿大"}')
$null = Cap 'record-get-200' 'record' 'GET' ("/api/v1/doctor/visits/$appt2/record") 'doctor' $A $null
$null = Cap 'record-patient-before-lock-404' 'record' 'GET' ("/api/v1/medical-records/$appt2") 'patient' $P $null
$null = Cap 'record-lock-200' 'record' 'POST' ("/api/v1/doctor/visits/$appt2/record/lock") 'doctor' $A $null
$null = Cap 'record-put-locked-409' 'record' 'PUT' ("/api/v1/doctor/visits/$appt2/record") 'doctor' $A `
        '{"diagnosis":"锁定后篡改"}'
$null = Cap 'record-patient-after-lock-200' 'record' 'GET' ("/api/v1/medical-records/$appt2") 'patient' $P $null
$null = Cap 'records-list-200' 'record' 'GET' '/api/v1/medical-records' 'patient' $P $null
# 重新打开：**医生 403、管理员 200** —— 这条把"状态回退的权限门槛"钉进契约。
# ★ 2026-10-15（改进 3）两处变化，契约里都要看得见：
#   ① 解锁**必须给理由**（`{"reason":"…"}`，4-255 **字符**）⇒ 无理由/过短都是 400；
#   ② 权限从「借 ManageSchedule」改为语义动作 `ManageRecordRevision`（授权结果不变，医生仍 403）。
$null = Cap 'record-reopen-doctor-403' 'record' 'POST' ("/api/v1/doctor/visits/$appt2/record/reopen") 'doctor' $A `
        '{"reason":"医生想改诊断，请解锁"}'
$null = Cap 'record-reopen-no-reason-400' 'record' 'POST' ("/api/v1/doctor/visits/$appt2/record/reopen") 'admin' $AD '{}'
$null = Cap 'record-reopen-short-reason-400' 'record' 'POST' ("/api/v1/doctor/visits/$appt2/record/reopen") 'admin' $AD `
        '{"reason":"太短"}'
$null = Cap 'record-reopen-admin-200' 'record' 'POST' ("/api/v1/doctor/visits/$appt2/record/reopen") 'admin' $AD `
        '{"reason":"患者要求补充过敏史，解锁重写"}'

# ── [6.5] 修订历史（改进 3）：列表 / 单版详情 / 逐段对比 ────────────────────
Write-Host ""
Write-Host "[6.5] 病历修订历史"
$null = Cap 'record-revisions-200' 'record' 'GET' ("/api/v1/doctor/visits/$appt2/record/revisions") 'doctor' $A $null
$null = Cap 'record-revision-detail-200' 'record' 'GET' ("/api/v1/doctor/visits/$appt2/record/revisions/1") 'doctor' $A $null
$null = Cap 'record-revision-unknown-404' 'record' 'GET' ("/api/v1/doctor/visits/$appt2/record/revisions/99") 'doctor' $A $null
# 第一版没有上一版 ⇒ 默认 against 会算成 0 ⇒ **400 要求显式指定**（不退化成"一切未变"的假答案）
$null = Cap 'record-revision-diff-no-against-400' 'record' 'GET' ("/api/v1/doctor/visits/$appt2/record/revisions/1/diff") 'doctor' $A $null
# 患者读修订历史 ⇒ 404（这里含 reason / operator_role 等内部审计话术，不给患者）
$null = Cap 'record-revisions-patient-404' 'record' 'GET' ("/api/v1/doctor/visits/$appt2/record/revisions") 'patient' $P $null
# 解锁后改一段、再定稿 ⇒ 第 3 版；与第 2 版逐段对比，只有改动的那段标 changed
$null = Cap 'record-put-after-unlock-200' 'record' 'PUT' ("/api/v1/doctor/visits/$appt2/record") 'doctor' $A `
        '{"allergy_history":"青霉素过敏"}'
$null = Cap 'record-lock-again-200' 'record' 'POST' ("/api/v1/doctor/visits/$appt2/record/lock") 'doctor' $A $null
$null = Cap 'record-revision-diff-200' 'record' 'GET' ("/api/v1/doctor/visits/$appt2/record/revisions/3/diff?against=2") 'doctor' $A $null

# ── [6.6] 医生工作台：既往病历 + 乐观锁（改进 2）──────────────────────────
Write-Host ""
Write-Host "[6.6] 医生工作台：既往病历（改进 2）与乐观锁 expected_updated_at"
# ⚠ 顺序有讲究：**先**造一张"只有草稿"的单，再取既往病历 —— 这样这条样例同时证明了
#   "草稿不外泄"，而不是只证明"能取到"。
$b3 = Req 'wb-book' 'POST' '/api/v1/appointments' $P '{"schedule_id":706001,"client_token":"contract-tok-wb"}'
if ($b3.Http -ne 201) { Fail "工作台夹具挂号未成功（HTTP $($b3.Http)）：$($b3.Body)" }
$appt3 = [int64]$b3.Json.data.appointment_id
$null = Req 'wb-draft' 'PUT' ("/api/v1/doctor/visits/$appt3/record") $A '{"chief_complaint":"咽痛 1 天"}'
# 既往病历：本单医生读本患者（appt2 已定稿 ⇒ 出现在历史里；appt3 是草稿 ⇒ 不出现）
$null = Cap 'doctor-patient-records-200' 'record' 'GET' '/api/v1/doctor/patients/706001/records' 'doctor' $A $null
# 排除"正在写的这一份"（工作台不该把本次就诊算成既往）
$null = Cap 'doctor-patient-records-exclude-200' 'record' 'GET' ("/api/v1/doctor/patients/706001/records?exclude_appointment_id=$appt2") 'doctor' $A $null
# 隐私闸门：另一位医生**从没接诊过**这位患者 ⇒ 404（不是 403，403 等于回答"这人存在"）
$null = Cap 'doctor-patient-records-other-doctor-404' 'record' 'GET' '/api/v1/doctor/patients/706001/records' 'doctor' $A2 $null
# 患者自己调医生端点 ⇒ 403（患者没有医生档案）
$null = Cap 'doctor-patient-records-patient-403' 'record' 'GET' '/api/v1/doctor/patients/706001/records' 'patient' $P $null
# 乐观锁：拿**过期**版本提交 ⇒ 409 EMR_CHANGED，且 error.fields 回报当前那一版
$null = Cap 'record-put-expected-stale-409' 'record' 'PUT' ("/api/v1/doctor/visits/$appt3/record") 'doctor' $A `
        '{"chief_complaint":"并发改的","expected_updated_at":1}'

# ── [7] 列表分页与上限（成员集合依赖全院数据 ⇒ 只钉形状）────────────────────
Write-Host ""
Write-Host "[7] 列表分页与上限（volatile：只钉形状与夹取后的 limit/offset）"
$null = Cap 'admin-users-page-clamped-200' 'admin' 'GET' '/api/v1/admin/users?limit=9999&offset=-5&role=patient' 'admin' $AD $null `
        @('data.items', 'data.count', 'data.total')

# ── 落盘 / 比对 ─────────────────────────────────────────────────────────────
Write-Host ""
if (-not (Test-Path $OutDir)) { $null = New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$same = 0; $diff = @(); $new = @()
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
foreach ($d in $Script:Docs) {
    $text = (To-CanonicalJson $d 0) + "`n"
    $file = Join-Path $OutDir ($d.name + '.json')
    if (Test-Path $file) {
        $old = [System.IO.File]::ReadAllText($file)
        if ($old -eq $text) { $same++; continue }
        if ($Check) {
            $diff += $d.name
            $ol = $old -split "`n"; $nl = $text -split "`n"
            $ln = 0
            while ($ln -lt $ol.Count -and $ln -lt $nl.Count -and $ol[$ln] -eq $nl[$ln]) { $ln++ }
            Write-Host ("  [DIFF] {0}.json  行 {1}" -f $d.name, ($ln + 1)) -ForegroundColor Red
            if ($ln -lt $ol.Count) { Write-Host ("         已提交: " + $ol[$ln].Trim()) -ForegroundColor DarkGray }
            if ($ln -lt $nl.Count) { Write-Host ("         实测  : " + $nl[$ln].Trim()) -ForegroundColor DarkGray }
        } else {
            [System.IO.File]::WriteAllText($file, $text, $utf8NoBom)
            $diff += $d.name
            Write-Host "  [更新] $($d.name).json" -ForegroundColor Yellow
        }
    } else {
        if ($Check) { Write-Host "  [缺失] $($d.name).json（已提交样例里没有这一条）" -ForegroundColor Red; $diff += $d.name }
        else {
            [System.IO.File]::WriteAllText($file, $text, $utf8NoBom)
            $new += $d.name
            Write-Host "  [新增] $($d.name).json" -ForegroundColor Yellow
        }
    }
}
if ($Check) {
    $known = @{}
    foreach ($d in $Script:Docs) { $known[($d.name + '.json')] = $true }
    $extra = @(Get-ChildItem $OutDir -Filter '*.json' -File | Where-Object { -not $known.ContainsKey($_.Name) })
    foreach ($e in $extra) { Write-Host "  [多余] $($e.Name)（服务器不再产出该样例）" -ForegroundColor Red }
    Write-Host ""
    Write-Host ("比对完成：一致 {0} / 不一致 {1} / 多余 {2}" -f $same, $diff.Count, $extra.Count) -ForegroundColor Cyan
    if ($diff.Count -gt 0 -or $extra.Count -gt 0) {
        Write-Host "契约样例与实测不一致 ⇒ 要么改代码，要么用不带 -Check 的方式重新导出并提交样例。" -ForegroundColor Red
        exit 1
    }
    exit 0
}
Write-Host ""
Write-Host ("导出完成：新增 {0} / 更新 {1} / 未变 {2}，共 {3} 条 → {4}" -f $new.Count, $diff.Count, $same, $Script:Docs.Count, $OutDir) -ForegroundColor Cyan
exit 0
