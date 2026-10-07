<#
.SYNOPSIS
    AI 四个接口的端到端联调（**真起 MySQL + 真起服务 + 真发 HTTP**）。

.DESCRIPTION
    与 ai-check.ps1 的分工：那个不需要 MySQL，只验参数与配置解析；
    本脚本把四个接口在真实运行里打一遍，验的是**行为**：
      · source=model   —— 桩返回合法结构化输出
      · source=fallback —— 桩返回非法 JSON（归一化失败 → 重试 → 降级）
      · source=fallback —— 桩返回 500（可重试）
      · source=fallback —— 桩返回 401（**不可重试**，应立刻降级）
      · source=fallback —— 桩挂掉（网络失败）
      · source=none    —— 服务未配 --ai-endpoint
      · 全程**永不返回 5xx**
      · 成员级节流见到 429

    判据：FAIL 0。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\ai-e2e.ps1
#>
param(
    # F-3：跨窗口边界用例需要约 61 秒，默认不跑；加 -SlowGate 开启。
    # 不加时，下面的"并发 25 -> 20/5"**无法区分**滑动窗口与固定窗口（两者在 1 秒突发下都是 20/5）。
    [switch]$SlowGate,
    [int]$Port = 18300,
    [int]$StubPort = 19100,
    [string]$MariaDbHome = "E:\cangjie\mariadb\mariadb-11.4.13-winx64",
    [string]$MySqlHost = "127.0.0.1",
    [int]$MySqlPort = 3307,
    [string]$MySqlUser = "root",
    [string]$MySqlPass = "clubroot123"
)

$ErrorActionPreference = "Stop"
# R-3（2026-10-05 晚修）：Test-NetConnection 会写进度条，而 Write-Progress 在输出被重定向
# （> log / CI）时抛 ReadConsoleOutput；配上 $ErrorActionPreference="Stop" 会让脚本当场中止。
$ProgressPreference = "SilentlyContinue"
$testsDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$serverDir = Split-Path -Parent $testsDir
$root      = Split-Path -Parent $serverDir
$exe       = Join-Path $serverDir "build\club-server.exe"
$stub      = Join-Path $testsDir "ai-stub.mjs"
$dataRel   = "build\ai-e2e-data"
$dataAbs   = Join-Path $serverDir $dataRel
$db        = "club_ai_e2e"
$dsn       = "mysql://${MySqlUser}:${MySqlPass}@${MySqlHost}:${MySqlPort}/${db}"
$base      = "http://127.0.0.1:${Port}/api/v1"

$script:pass = 0; $script:fail = 0
function Ok([string]$m)  { $script:pass++; Write-Host "  ok    $m" }
function Bad([string]$m) { $script:fail++; Write-Host "  FAIL  $m" }
function Check([string]$m, [bool]$c) { if ($c) { Ok $m } else { Bad $m } }

if (-not (Test-Path $exe)) { throw "找不到 $exe —— 先跑 server\build.ps1" }

$mysqlCli = Join-Path $MariaDbHome "bin\mysql.exe"
if (-not (Test-Path $mysqlCli)) { throw "找不到 mysql.exe：$mysqlCli" }

$procs = @()
function Stop-All {
    foreach ($p in $script:procs) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    $script:procs = @()
}
trap { Stop-All; break }

try {
    Write-Host ""
    Write-Host "AI 端到端联调"
    Write-Host "======================================"

    # ---------- 0. MariaDB 必须在跑 ----------
    $up = Test-NetConnection -ComputerName $MySqlHost -Port $MySqlPort -InformationLevel Quiet -WarningAction SilentlyContinue 2>$null
    if (-not $up) { throw "MySQL ${MySqlHost}:${MySqlPort} 连不上 —— 先起便携版 MariaDB（见 docs/local-deploy.md）" }
    Ok "MySQL ${MySqlHost}:${MySqlPort} 可达"

    # ---------- 1. 干净的库 ----------
    # ⚠ 必须用**长选项**。`-p$MySqlPass` 会被 PowerShell 拆成两个 token（`-p` + 口令），
    #    而 MySQL 把「`-p` 后跟空格」解释成【交互式索要口令】——
    #    非交互上下文里认证必然失败：ERROR 1045 (using password: YES)。
    #    实测同一口令：`-p$MySqlPass` -> 1045；`--password=$MySqlPass` -> OK。
    & $mysqlCli "--host=$MySqlHost" "--port=$MySqlPort" "--user=$MySqlUser" `
        "--password=$MySqlPass" "--skip-ssl" `
        -e "DROP DATABASE IF EXISTS $db; CREATE DATABASE $db CHARACTER SET utf8mb4;" 2>&1 | Out-Null
    Check "测试库 $db 已重建（干净夹具）" ($LASTEXITCODE -eq 0)
    if (Test-Path $dataAbs) { Remove-Item -Recurse -Force $dataAbs }

    # ---------- 2. init-admin ----------
    Push-Location $serverDir
    & $exe init-admin 13800000000 password123 $dsn --data-dir $dataRel 2>&1 | Out-Null
    $initExit = $LASTEXITCODE
    Pop-Location
    Check "init-admin 成功" ($initExit -eq 0)

    # ---------- 3. AI 桩 ----------
    $stubProc = Start-Process -FilePath "node" -ArgumentList "ai-stub.mjs", "$StubPort" -PassThru -NoNewWindow -WorkingDirectory $testsDir
    $script:procs += $stubProc
    Start-Sleep -Seconds 2
    Check "AI 桩已起（:$StubPort）" (-not $stubProc.HasExited)

    $keyFile = Join-Path $env:TEMP "ai-e2e-key.txt"
    [IO.File]::WriteAllText($keyFile, "sk-e2e-dummy", [Text.UTF8Encoding]::new($false))

    function Set-StubMode([string]$m) {
        Invoke-WebRequest -Uri "http://127.0.0.1:$StubPort/__mode?m=$m" -Method Post -UseBasicParsing | Out-Null
    }
    function Get-StubStats {
        (Invoke-WebRequest -Uri "http://127.0.0.1:$StubPort/__stats" -UseBasicParsing).Content | ConvertFrom-Json
    }

    # ---------- 4. 起服务（配 AI） ----------
    function Start-Club([string[]]$extra) {
        $out = Join-Path $env:TEMP "ai-e2e-out.txt"; $err = Join-Path $env:TEMP "ai-e2e-err.txt"
        Remove-Item $out, $err -ErrorAction SilentlyContinue
        $argv = @("serve", "$Port", $dsn, "--data-dir", $dataRel) + $extra
        $p = Start-Process -FilePath $exe -PassThru -NoNewWindow -WorkingDirectory $serverDir `
             -ArgumentList $argv -RedirectStandardOutput $out -RedirectStandardError $err
        $script:procs += $p
        # 等端口就绪
        for ($i = 0; $i -lt 40; $i++) {
            Start-Sleep -Milliseconds 500
            if (Test-NetConnection -ComputerName 127.0.0.1 -Port $Port -InformationLevel Quiet -WarningAction SilentlyContinue 2>$null) { break }
        }
        return $p
    }
    function Stop-Club([object]$p) {
        if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 1 }
    }

    $aiFlags = @("--ai-endpoint", "http://127.0.0.1:$StubPort/v1/chat/completions",
                 "--ai-model", "stub", "--ai-key-file", $keyFile, "--ai-insecure-trust-all", "1")
    $srv = Start-Club $aiFlags
    Check "serve 已起（配了 AI）" (-not $srv.HasExited)

    # ---------- 5. 登录 ----------
    $loginBody = @{ phone = "13800000000"; password = "password123" } | ConvertTo-Json
    # 同上：按 UTF-8 字节发，避免 PS 5.1 用 ISO-8859-1 编码中文
    $login = Invoke-RestMethod -Uri "$base/auth/login" -Method Post `
        -Body ([Text.Encoding]::UTF8.GetBytes($loginBody)) -ContentType "application/json; charset=utf-8"
    $token = $login.data.token
    Check "登录拿到 token" ($null -ne $token -and $token.Length -gt 10)
    $headers = @{ Authorization = "Bearer $token" }

    # 每次调用都记 HTTP 状态 —— 「永不 5xx」要靠它判定
    $script:statuses = @()
    function CallAi([string]$path, [hashtable]$body) {
        try {
            # ⚠ 必须发 UTF-8 **字节**：PS 5.1 的 `-Body <字符串>` 默认按 ISO-8859-1 编码，
            #    中文载荷到达服务端时已经是乱码。这个坑是**真实模型联调**时踩出来的：
            #    /ai/ask 的提问变成乱码，模型的回答是"您没有提供具体的提问内容"。
            #    而桩根本不看内容，所以这条链路的"中文能完好穿过"从来没被真正验证过。
            $json = $body | ConvertTo-Json -Depth 6
            $r = Invoke-WebRequest -Uri "$base$path" -Method Post -Headers $headers `
                 -Body ([Text.Encoding]::UTF8.GetBytes($json)) `
                 -ContentType "application/json; charset=utf-8" -UseBasicParsing
            $script:statuses += [int]$r.StatusCode
            return @{ status = [int]$r.StatusCode; data = ($r.Content | ConvertFrom-Json).data }
        } catch {
            $st = 0
            try { $st = [int]$_.Exception.Response.StatusCode } catch { }
            $script:statuses += $st
            return @{ status = $st; data = $null }
        }
    }

    # ---------- 6. 正常路径：四个接口 ----------
    Write-Host ""
    Write-Host "--- 桩 mode=ok（应全部 source=model）---"
    Set-StubMode "ok"

    $r1 = CallAi "/ai/task-suggest" @{ title = "筹备秋季招新" }
    Check "task-suggest 200" ($r1.status -eq 200)
    Check "task-suggest source=model" ($r1.data.source -eq "model")
    Check "task-suggest owner 是 MemberBrief 对象（AI-9）" ($null -ne $r1.data.owner -and $null -ne $r1.data.owner.name)
    Check "task-suggest reasons 非空" ($r1.data.reasons.Count -ge 1)
    # R-17：证明 Authorization 真的按 "Bearer <密钥>" 拼出来了（桩会记录它看到的值）
    Check "请求带上了正确的 Bearer 密钥（R-17）" ((Get-StubStats).authSeen -contains "Bearer sk-e2e-dummy")

    $r2 = CallAi "/ai/notice-draft" @{ task_id = 0; audience = "members" }
    # task_id=0 应 400（校验失败），不是 500
    Check "notice-draft 非法 task_id -> 400（不是 5xx）" ($r2.status -eq 400)

    $r3 = CallAi "/ai/retrospective" @{ task_id = 999999 }
    Check "retrospective 不存在的任务 -> 404（不是 5xx）" ($r3.status -eq 404)

    $r4 = CallAi "/ai/ask" @{ question = "我有哪些权限？" }
    Check "ask 200" ($r4.status -eq 200)
    Check "ask source=model" ($r4.data.source -eq "model")
    Check "ask basis 是对象数组（AI-9）" ($r4.data.basis.Count -ge 1 -and $null -ne $r4.data.basis[0].kind)

    # ---------- 7. 降级路径 ----------
    Write-Host ""
    Write-Host "--- 桩 mode=garbage（非法 JSON -> 重试 -> 降级）---"
    Set-StubMode "garbage"
    $g = CallAi "/ai/ask" @{ question = "我有哪些权限？" }
    Check "garbage 仍 200（永不 5xx）" ($g.status -eq 200)
    Check "garbage -> source=fallback" ($g.data.source -eq "fallback")
    Check "garbage -> 带 note 告知用户" ($g.data.note.Length -gt 0)

    Write-Host ""
    Write-Host "--- 桩 mode=fenced（```json 围栏 → 归一化后应成功）---"
    Set-StubMode "fenced"
    $f = CallAi "/ai/ask" @{ question = "我有哪些权限？" }
    Check "fenced 仍 200" ($f.status -eq 200)
    Check "fenced -> source=model（extractJson 剥围栏生效）" ($f.data.source -eq "model")

    Write-Host ""
    Write-Host "--- 桩 mode=e500（可重试 → 降级）---"
    Set-StubMode "e500"
    $before500 = (Get-StubStats).requests
    $e5 = CallAi "/ai/ask" @{ question = "我有哪些权限？" }
    $after500 = (Get-StubStats).requests
    Check "e500 仍 200" ($e5.status -eq 200)
    Check "e500 -> source=fallback" ($e5.data.source -eq "fallback")
    Check "e500 发生了重试（请求数恰好 +2 —— 上限就是 2 次尝试）" (($after500 - $before500) -eq 2)

    Write-Host ""
    Write-Host "--- 桩 mode=e401（不可重试 → 立刻降级）---"
    Set-StubMode "e401"
    $before401 = (Get-StubStats).requests
    $e4 = CallAi "/ai/ask" @{ question = "我有哪些权限？" }
    $after401 = (Get-StubStats).requests
    Check "e401 仍 200" ($e4.status -eq 200)
    Check "e401 -> source=fallback" ($e4.data.source -eq "fallback")
    Check "e401 不重试（请求数只 +1）" (($after401 - $before401) -eq 1)

    # ---------- 8. 桩挂掉（网络失败） ----------
    Write-Host ""
    Write-Host "--- 桩停掉（网络失败 -> 降级）---"
    Stop-Process -Id $stubProc.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    $down = CallAi "/ai/ask" @{ question = "我有哪些权限？" }
    Check "桩挂掉仍 200" ($down.status -eq 200)
    Check "桩挂掉 -> source=fallback" ($down.data.source -eq "fallback")

    # ---------- 9. 节流（AI-6 / R-9）----------
    Write-Host ""
    Write-Host "--- 成员级节流：**并发**突发 25 个（窗口 20 次 / 60 秒）---"
    # ⚠ 必须用**并发**而不是"顺序连打 25 次"。
    # 评审 A/B 实测：同一二进制、同一代码路径，唯一变量是桩延迟 ——
    #   桩 0 ms    -> 200x20 + 429x5
    #   桩 4000 ms -> 200x25 + 429x0（101 秒 约 14.9 次/分，本来就在额度内）
    # 顺序连打在慢端点上**天然测不出限流**（那是对的，不是失效）。
    # 另外必须先**重启服务**拿一个全新的桶，否则前面十几个用例已经吃掉额度，
    # 断言就不确定了（评审看到过 #12 起 429，就是这个原因）。
    # ⚠ F-1 之后必须**让桩活着且响应快**再测限流：
    # 桩停掉时每个请求都慢（两次尝试 + 退避），并发的其余请求会落进 `overloaded`
    # 分支并**退还额度**（这正是 F-1 的目的），于是永远撞不到 20 —— 全 200。
    # 限流测的是"真实模型调用次数"，所以要让请求真的打到桩上。
    $stubProc = Start-Process -FilePath "node" -ArgumentList "ai-stub.mjs", "$StubPort" -PassThru -NoNewWindow -WorkingDirectory $testsDir
    $script:procs += $stubProc
    Start-Sleep -Seconds 2
    Stop-Club $srv
    $srv = Start-Club $aiFlags
    Add-Type -AssemblyName System.Net.Http
    $hc = New-Object System.Net.Http.HttpClient
    $hc.DefaultRequestHeaders.Authorization =
        New-Object System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", $token)
    # ⚠ 这里用**顺序**快打，不是并发 —— F-1 之后这是唯一正确的测法：
    # 额度只统计**真实模型调用**，而并发数受 --ai-max-concurrent(4) 限制，
    # 多余的并发请求会落进 `overloaded` 并**退还额度**，
    # 于是并发突发**永远撞不到 20**（实测 25 并发全 200 —— 那是正确行为）。
    # 根因分析的原话：「只有 25 次真的挤进同一分钟时才算超额」，
    # 顺序快打（桩活着、每次约 10 ms）正好保证 25 次落在同一分钟内。
    $codes = @()
    for ($i = 0; $i -lt 25; $i++) {
        $content = New-Object System.Net.Http.StringContent('{"question":"突发"}', [Text.Encoding]::UTF8, "application/json")
        $resp = $hc.PostAsync("$base/ai/ask", $content).Result
        $codes += [int]$resp.StatusCode
    }
    $n200 = ($codes | Where-Object { $_ -eq 200 }).Count
    $n429 = ($codes | Where-Object { $_ -eq 429 }).Count
    Write-Host "      （实际状态码：$($codes -join ',')）"
    Check "顺序快打 25 次：恰好 20 个通过、5 个 429（额度只算真实模型调用）" ($n200 -eq 20 -and $n429 -eq 5)
    Check "节流期间也没有 5xx" (($codes | Where-Object { $_ -ge 500 }).Count -eq 0)
    $hc.Dispose()

    # ---------- 9.7 /ai/agent：工具循环（Phase 1 只读）----------
    Write-Host ""
    Write-Host "--- /ai/agent 工具循环 ---"
    # 新进程 -> 全新桶，避免被上面的节流用例影响
    Stop-Club $srv
    $srv = Start-Club $aiFlags

    Set-StubMode "agent"
    $ag = CallAi "/ai/agent" @{ question = "本部门有多少人？" }
    Check "agent 仍 200" ($ag.status -eq 200)
    Check "agent source=model" ($ag.data.source -eq "model")
    Check "agent 真的调了工具（steps 非空）" ($ag.data.steps.Count -ge 1)
    Check "agent 工具被放行（allowed=true）" ($ag.data.steps[0].allowed -eq $true)
    Check "agent 走了 2 轮（先查工具再回答）" ($ag.data.rounds -eq 2)
    Check "agent 的 answer 来自模型的 final" ($ag.data.answer -like "*第 2 轮*")
    # ★ 2026-10-06：前端报过"同一接口 basis 两种形状"（模型路径手搓字符串数组、
    #   降级路径是对象数组），所以这里按 ask 同款口径钉死形状（AI-9）。
    Check "★ agent basis 是对象数组（AI-9）" ($ag.data.basis.Count -ge 1 -and $null -ne $ag.data.basis[0].kind)
    Check "★ agent basis 的 ref 非空" ($null -ne $ag.data.basis[0].ref -and "$($ag.data.basis[0].ref)".Length -gt 0)

    Set-StubMode "agentloop"
    $lp = CallAi "/ai/agent" @{ question = "反复查" }
    Check "agentloop 仍 200" ($lp.status -eq 200)
    Check "agentloop 轮数被截停在 4（T4 循环上限）" ($lp.data.rounds -eq 4)
    Check "agentloop 被截停后仍给得出答案（兜底不为空）" ($lp.data.answer.Length -gt 5)
    Check "agentloop 的 source 不是 model（没有 final）" ($lp.data.source -ne "model")
    # ★★ 这条就是前端报的那个 bug 的正身：**source≠model 时 basis 仍必须是对象数组**。
    #    修复前它走的是"模型路径"的手搓字符串数组 —— 形状取决于 AI 配没配，客户端没法消费。
    Check "★★ agentloop（source≠model）basis 仍是对象数组（前端报的那条）" `
        ($lp.data.basis.Count -ge 1 -and $null -ne $lp.data.basis[0].kind)
    Check "★ agentloop basis 的 kind 合法（permission/data/doc）" `
        ($lp.data.basis[0].kind -in @("permission", "data", "doc"))

    Set-StubMode "agentbad"
    $bd = CallAi "/ai/agent" @{ question = "试个不存在的工具" }
    Check "agentbad 仍 200（永不 5xx）" ($bd.status -eq 200)
    Check "agentbad basis 是对象数组（AI-9）" ($bd.data.basis.Count -ge 1 -and $null -ne $bd.data.basis[0].kind)
    Check "未知工具被拒（allowed=false，模型不能发明工具 T2）" ($bd.data.steps[0].allowed -eq $false)
    Set-StubMode "ok"

    # ---------- 9.75 P2 写操作全链路（提议 → 确认 → 回查 → 重放）----------
    Write-Host ""
    Write-Host "--- P2 写操作：提议 → 确认 → 回查数据库 → 重复确认 ---"
    Stop-Club $srv
    $srv = Start-Club $aiFlags          # 新进程 -> 新桶

    # 需要一个**属于自己**的任务：会长建一个，owner 设成自己
    $meId = $login.data.member.id
    $meDept = 0
    if ($null -ne $login.data.member.dept) { $meDept = $login.data.member.dept.id }
    # 直接调用（不走 CallAi），失败时把服务端的拒绝原因打出来，便于定位
    try {
        $tr = Invoke-WebRequest -Uri "$base/tasks" -Method Post -Headers $headers `
              -Body ([Text.Encoding]::UTF8.GetBytes((@{ title = "P2 写操作 e2e 任务"; owner_id = $meId; dept_id = $meDept; client_token = "p2-e2e-1" } | ConvertTo-Json))) `
              -ContentType "application/json; charset=utf-8" -UseBasicParsing
        $tj = $tr.Content | ConvertFrom-Json
        Write-Host "      建任务返回（前 260 字）：$($tr.Content.Substring(0, [Math]::Min(260, $tr.Content.Length)))"
        $taskR = @{ status = [int]$tr.StatusCode; data = $tj.data }
    } catch {
        $st = 0; $body = ""
        try { $st = [int]$_.Exception.Response.StatusCode; $body = (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() } catch { }
        Write-Host "      建任务被拒：status=$st  body=$body"
        $taskR = @{ status = $st; data = $null }
    }
    $taskId = 0
    # ⚠ 两个实测踩到的坑（症状都是"建出测试任务 id=0"）：
    #   ① 建任务返回的是 **201 Created**，不是 200 —— 判据要写成 2xx，别写死 -eq 200
    #   ② 响应是 { ok, data: { task: { id, … } } } —— **task 嵌了一层**，不是 data.id
    if ($taskR.status -ge 200 -and $taskR.status -lt 300 -and $null -ne $taskR.data -and $null -ne $taskR.data.task) {
        $taskId = [int]$taskR.data.task.id
    }
    Check "建出测试任务（id=$taskId）" ($taskId -gt 0)

    if ($taskId -gt 0) {
        Invoke-WebRequest -Uri "http://127.0.0.1:$StubPort/__mode?m=agentwrite&task=$taskId" -Method Post -UseBasicParsing | Out-Null
        $aw = CallAi "/ai/agent" @{ question = "帮我把这个任务标记为完成" }
        Check "agent（写工具）仍 200" ($aw.status -eq 200)
        Check "**模型只产出提议、没有直接执行**" ($null -ne $aw.data.proposal)
        $ptok = ""
        if ($null -ne $aw.data.proposal) { $ptok = "$($aw.data.proposal.token)" }
        Check "提议带确认令牌（ap_ 前缀）" ($ptok -like "ap_*")
        Check "提议带**服务端算出的 diff**" ($null -ne $aw.data.proposal.diff -and $aw.data.proposal.diff.Count -ge 1)
        # ★ 关键：提议阶段**不能**改数据
        # ⚠ CallAi **永远用 POST**，而读任务必须用 GET —— 用错方法会拿到空 data（实测踩到）
        # ⚠ 读任务的响应同样嵌了一层（data.task.…）—— 两种形状都接受
        $st1 = ""
        try {
            $r1 = Invoke-WebRequest -Uri "$base/tasks/$taskId" -Method Get -Headers $headers -UseBasicParsing
            $d1 = ($r1.Content | ConvertFrom-Json).data
            $st1 = "$($d1.task.status)"
            if (-not $st1) { $st1 = "$($d1.status)" }
        } catch { $st1 = "GET失败" }
        Check "★ 提议阶段任务状态**未变**（仍是 todo，实际 '$st1'）" ($st1 -eq "todo")

        $cf = CallAi "/ai/agent/confirm" @{ token = $ptok }
        Check "确认执行 200" ($cf.status -eq 200)
        Check "确认返回 resource_id" ([int]$cf.data.resource_id -eq $taskId)
        $st2 = ""
        try {
            $r2 = Invoke-WebRequest -Uri "$base/tasks/$taskId" -Method Get -Headers $headers -UseBasicParsing
            $d2 = ($r2.Content | ConvertFrom-Json).data
            $st2 = "$($d2.task.status)"
            if (-not $st2) { $st2 = "$($d2.status)" }
        } catch { $st2 = "GET失败" }
        Check "★ 确认后**数据库里真的改了**（status=done，实际 '$st2'）" ($st2 -eq "done")

        $rp = CallAi "/ai/agent/confirm" @{ token = $ptok }
        Check "★ 同一令牌重复确认 -> 409（不会二次执行）" ($rp.status -eq 409)
        $bg = CallAi "/ai/agent/confirm" @{ token = "ap_deadbeefdeadbeef" }
        Check "不存在的令牌 -> 404" ($bg.status -eq 404)
        $nt = CallAi "/ai/agent/confirm" @{ question = "x" }
        Check "缺 token -> 400（不是 5xx）" ($nt.status -eq 400)
        Set-StubMode "ok"
    }

    # ---------- 9.8 F-4：出站不得跟随 3xx（fail-closed）----------
    Write-Host ""
    Write-Host "--- 桩 mode=redirect（F-4：不得跟随 3xx）---"
    # ⚠ 必须重启服务拿**全新的桶**：上面刚做完 25 连打的节流用例，
    # 桶里已经压满 20 个时间戳，紧接着的请求会直接吃 429（不是我们要测的东西）。
    Stop-Club $srv
    $srv = Start-Club $aiFlags
    $before = (Get-StubStats).stolen
    Set-StubMode "redirect"
    $rd = CallAi "/ai/ask" @{ question = "重定向用例" }
    $after = (Get-StubStats).stolen
    Check "重定向仍 200（永不 5xx）" ($rd.status -eq 200)
    Check "重定向 -> source=fallback（http_error，可见且不可重试）" ($rd.data.source -eq "fallback")
    Check "F-4：重定向目标**从未被请求**（fail-closed；实测 stolen=$after）" ($after -eq $before)
    Set-StubMode "ok"
    # ---------- 10. 未配 AI -> source=none ----------
    Write-Host ""
    Write-Host "--- 重启服务但**不配** --ai-endpoint（应 source=none）---"
    Stop-Club $srv
    $srv2 = Start-Club @()
    Check "serve 已起（未配 AI）" (-not $srv2.HasExited)
    $none = CallAi "/ai/ask" @{ question = "我有哪些权限？" }
    Check "未配 AI 仍 200" ($none.status -eq 200)
    # R-8（2026-10-05 晚修）：AI 未配置时我们**确实给得出规则兜底**，所以来源是
    # fallback 而不是 none（api-design §7：none = 连兜底都给不出）。原先返 none
    # 会让合规客户端把本来可用的兜底内容整块丢掉。
    Check "未配 AI -> source=fallback（R-8：有兜底内容就不该报 none）" ($none.data.source -eq "fallback")
    Check "未配 AI -> 回答里仍给出 can() 的权限事实（兜底不为空）" ($none.data.answer.Length -gt 5)
    Stop-Club $srv2


    # ---------- 9.5 F-3：跨窗口边界（唯一能区分滑动/固定窗口的用例）----------
    Write-Host ""
    if ($SlowGate) {
        Write-Host "--- F-3 跨窗口边界（约 61 秒）---"
        Stop-Club $srv
        $srv = Start-Club $aiFlags
        $hc2 = New-Object System.Net.Http.HttpClient
        $hc2.DefaultRequestHeaders.Authorization =
            New-Object System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", $token)
        $script:hc2 = $hc2
        function Send-Burst([int]$n) {
            $ts = @()
            for ($i = 0; $i -lt $n; $i++) {
                $c = New-Object System.Net.Http.StringContent('{"question":"边界用例"}', [Text.Encoding]::UTF8, "application/json")
                $ts += $script:hc2.PostAsync("$base/ai/ask", $c)
            }
            [System.Threading.Tasks.Task]::WaitAll($ts)
            return @($ts | ForEach-Object { [int]$_.Result.StatusCode })
        }
        # t0 打 1 次 -> t0+59 打 18 次（两种实现都放行，共 19 个时间戳）
        # -> 跨过 t0+60 后在 t0+61 再打 5 次：
        #      滑动窗口：t0 那个已过期，只剩 t0+59 的 18 个 -> 放行 2 个（2x200 + 3x429）
        #      固定窗口：t0+60 已清零 -> 5 个全放行
        Send-Burst 1 | Out-Null
        Start-Sleep -Seconds 59
        Send-Burst 18 | Out-Null
        Start-Sleep -Seconds 2
        $b5 = Send-Burst 5
        $n200 = ($b5 | Where-Object { $_ -eq 200 }).Count
        $n429 = ($b5 | Where-Object { $_ -eq 429 }).Count
        Write-Host "      t0+61 的 5 次：$($b5 -join ',')"
        Check "跨窗口边界：滑动窗口应只放行 2 个（固定窗口会放行 5 个）" ($n200 -eq 2 -and $n429 -eq 3)
        $hc2.Dispose()
    } else {
        Write-Host "  NOTE  F-3 跨窗口边界用例未运行（加 -SlowGate 开启，约 61 秒）——"
        Write-Host "        不加时，下面的并发突发闸门**无法区分**滑动窗口与固定窗口（两者在 1 秒突发下都是 20/5）。"
    }
    # ---------- 10.5 AI-2 的真实回归闸门（R-5）----------
    Write-Host ""
    Write-Host "--- 分块慢发桩 + 20 KB 回答（AI-2 的真实闸门）---"
    # 原先 ai-check.ps1 认的是 spike/llm-truncation/probe.cj 里**手抄的** readFixed，
    # 而线上是 server/src/ai_transport.cj 的 aiReadBodyText —— 把 AiTransport 换回
    # StdxTransport（正是 AI-2 那个回归）闸门依然绿。这里改为**打真接口**：
    # 分块桩每 1000 字节 / 20ms 发一块（逼出短读），回答 20 KB；
    # 若走框架的 readBodyText，响应会被截断成 ~1000 字节 -> 非法 JSON -> source 变 fallback。
    $bigStub = Join-Path $root "spike\llm-truncation\stub.mjs"
    if (Test-Path $bigStub) {
        $bp = Start-Process -FilePath "node" -ArgumentList "stub.mjs", "19101" -PassThru -NoNewWindow `
              -WorkingDirectory (Split-Path -Parent $bigStub)
        $script:procs += $bp
        Start-Sleep -Seconds 2
        # 新进程 -> 节流计数是全新的，不会受上面 25 连打影响
        $srv3 = Start-Club @("--ai-endpoint", "http://127.0.0.1:19101/v1/chat/completions?size=20000",
                             "--ai-model", "stub", "--ai-key-file", $keyFile, "--ai-insecure-trust-all", "1")
        $big = CallAi "/ai/ask" @{ question = "随便问" }
        Check "20 KB 回答仍 200" ($big.status -eq 200)
        Check "20 KB 回答 -> source=model（R-5：真走了 AiTransport 的读体）" ($big.data.source -eq "model")
        Stop-Club $srv3
        Stop-Process -Id $bp.Id -Force -ErrorAction SilentlyContinue
    } else {
        Bad "找不到 $bigStub —— AI-2 的真实闸门无法运行"
    }

    # ---------- 11. 全局：永不 5xx ----------
    Write-Host ""
    $bad = @($script:statuses | Where-Object { $_ -ge 500 })
    Check "全程没有任何 5xx（共 $($script:statuses.Count) 次 AI 调用）" ($bad.Count -eq 0)
    $zero = @($script:statuses | Where-Object { $_ -eq 0 })
    Check "没有任何请求因异常中断（status=0）" ($zero.Count -eq 0)
}
finally {
    Stop-All
    Remove-Item (Join-Path $env:TEMP "ai-e2e-key.txt") -Force -ErrorAction SilentlyContinue
    # R-4：数据目录必须清掉，否则审计日志会留在工作区（git add -A 会误提交）
    if (Test-Path $dataAbs) { Remove-Item -Recurse -Force $dataAbs -ErrorAction SilentlyContinue }
}

Write-Host "======================================"
Write-Host "AI 端到端联调： PASS $script:pass / FAIL $script:fail"
Write-Host "======================================"
if ($script:fail -gt 0) { exit 1 }
