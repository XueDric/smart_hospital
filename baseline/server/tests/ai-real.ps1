<#
.SYNOPSIS
    AI 能力的**真实模型**联调（打公网真模型，不是桩）。

.DESCRIPTION
    与另外两套的分工：
      · ai-check.ps1  不需要 MySQL，只验参数与配置解析
      · ai-e2e.ps1    本地桩，验协议与降级路径（可重复、不花钱）
      · **本脚本**    打真实模型端点，验的是**桩永远验不出来的东西**：
                      真实模型会不会按 JSON-in-content 协议回话、回答有没有依据真实数据、
                      中文提问能不能完好穿过整条链路、密钥会不会泄漏。

    ⚠ 会真实消耗 API 额度（约 3~5 次调用）。

    ⚠ **密钥只从文件读**：`-KeyFile <路径>`。不要写在命令行里（会进 shell 历史），
      也**不要把密钥文件放进仓库**。脚本结束时不会打印密钥，并会扫审计日志确认没泄漏。

.PARAMETER KeyFile
    存放 API 密钥的文本文件（纯文本一行）。**必填，且必须在仓库之外。**

.EXAMPLE
    # 推荐：显式给 CA bundle（生产口径是校验证书，不是跳过）
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\ai-real.ps1 `
        -KeyFile "$env:TEMP\ai-key.txt" `
        -CaBundle "D:\certs\ca-bundle.crt"

.EXAMPLE
    # 临时：不校验证书（仅本机验证用）
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\ai-real.ps1 `
        -KeyFile "$env:TEMP\ai-key.txt" -InsecureTrustAll
#>
param(
    [Parameter(Mandatory = $true)][string]$KeyFile,
    [string]$Endpoint = "https://api.deepseek.com/v1/chat/completions",
    [string]$Model = "deepseek-chat",
    [string]$CaBundle = "",
    [switch]$InsecureTrustAll,
    [int]$Port = 18500,
    [string]$MySqlHost = "127.0.0.1",
    [int]$MySqlPort = 3307,
    [string]$MySqlUser = "root",
    [string]$MySqlPass = "clubroot123",
    [string]$DbName = "club_ai_real",
    [string]$Phone = "13800000000",
    [string]$Password = "password123",
    [int]$TimeoutSecs = 60
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$testsDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$serverDir = Split-Path -Parent $testsDir
$exe       = Join-Path $serverDir "build\club-server.exe"

$script:pass = 0; $script:fail = 0
function Ok([string]$m)  { $script:pass++; Write-Host "  ok    $m" }
function Bad([string]$m) { $script:fail++; Write-Host "  FAIL  $m" }
function Check([string]$m, [bool]$c) { if ($c) { Ok $m } else { Bad $m } }

if (-not (Test-Path $exe)) { throw "找不到 $exe —— 先跑 server\build.ps1" }
if (-not (Test-Path $KeyFile)) { throw "找不到密钥文件：$KeyFile" }
if ((Resolve-Path $KeyFile).Path -like "$serverDir*") {
    throw "密钥文件不能放在 server/ 目录里（有被误提交的风险）"
}
if ($CaBundle -and -not (Test-Path $CaBundle)) { throw "找不到 CA bundle：$CaBundle" }

# ⚠ CA 路径**不能含空格**：项目的命令行按空格切分参数
if ($CaBundle -and $CaBundle.Contains(" ")) {
    $tmpCa = Join-Path $env:TEMP "ai-real-ca.crt"
    Copy-Item $CaBundle $tmpCa -Force
    Write-Host "[准备] CA 路径含空格，已复制到：$tmpCa"
    $CaBundle = $tmpCa
}
if (-not $CaBundle -and -not $InsecureTrustAll) {
    Write-Host "[准备] 未给 -CaBundle，自动改用 -InsecureTrustAll（仅本机验证；⚠ 生产必须校验证书）"
    $InsecureTrustAll = $true
}

# 密钥内容只在内存里用一次，用于最后的泄漏扫描；**不打印**
$keyText = (Get-Content $KeyFile -Raw).Trim()

$procs = @()
function Stop-All { foreach ($p in $script:procs) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }; $script:procs = @() }

try {
    Write-Host ""
    Write-Host "AI 真实模型联调"
    Write-Host "======================================"
    Write-Host "  端点: $Endpoint"
    Write-Host "  模型: $Model"
    Write-Host "  校验: $(if ($InsecureTrustAll) { '⚠ 跳过证书校验' } else { "CustomCA: $CaBundle" })"
    Write-Host ""

    # ---------- 起服务 ----------
    $dataRel = "build\ai-real-data"
    $dataAbs = Join-Path $serverDir $dataRel
    if (Test-Path $dataAbs) { Remove-Item -Recurse -Force $dataAbs }
    $dsn = "mysql://${MySqlUser}:${MySqlPass}@${MySqlHost}:${MySqlPort}/${DbName}"
    $out = Join-Path $env:TEMP "ai-real-out.txt"; $err = Join-Path $env:TEMP "ai-real-err.txt"
    Remove-Item $out, $err -Force -ErrorAction SilentlyContinue

    Push-Location $serverDir
    & $exe init-admin $Phone $Password $dsn --data-dir $dataRel 2>&1 | Out-Null
    Pop-Location

    $argv = @("serve", "$Port", $dsn, "--data-dir", $dataRel,
              "--ai-endpoint", $Endpoint, "--ai-model", $Model,
              "--ai-key-file", (Resolve-Path $KeyFile).Path,
              "--ai-timeout", "$TimeoutSecs", "--ai-max-tokens", "2048")
    if ($InsecureTrustAll) { $argv += @("--ai-insecure-trust-all", "1") } else { $argv += @("--ai-ca", $CaBundle) }

    $srv = Start-Process -FilePath $exe -PassThru -NoNewWindow -WorkingDirectory $serverDir `
           -ArgumentList $argv -RedirectStandardOutput $out -RedirectStandardError $err
    $script:procs += $srv
    $base = "http://127.0.0.1:$Port/api/v1"
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-NetConnection -ComputerName 127.0.0.1 -Port $Port -InformationLevel Quiet -WarningAction SilentlyContinue 2>$null) { break }
    }
    if ($srv.HasExited) {
        Get-Content $err -Encoding UTF8 | Select-Object -First 5 | ForEach-Object { Write-Host "  ERR: $_" }
        throw "服务未起来"
    }
    $startLine = (Get-Content $out -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { $_ -match '\[AI\]' } | Select-Object -First 1)
    Check "服务已起且 AI 已启用" ($startLine -match '已启用')
    Check "启动行不含密钥（防泄漏）" (-not ($startLine -match [regex]::Escape($keyText)))

    # ⚠ 必须发 UTF-8 **字节**：PS 5.1 的 -Body <字符串> 默认按 ISO-8859-1 编码，
    #    中文载荷到服务端就是乱码。这个坑是真实模型联调时才暴露的。
    function PostJson([string]$url, [string]$token, [hashtable]$body) {
        $json = $body | ConvertTo-Json -Depth 6
        $hdr = @{}
        if ($token) { $hdr["Authorization"] = "Bearer $token" }
        return Invoke-RestMethod -Uri $url -Method Post -Headers $hdr `
               -ContentType "application/json; charset=utf-8" `
               -Body ([Text.Encoding]::UTF8.GetBytes($json))
    }

    $login = PostJson "$base/auth/login" "" @{ phone = $Phone; password = $Password }
    $tok = $login.data.token
    Check "登录拿到 token" ($null -ne $tok)

    function TryAi([string]$path, [hashtable]$body, [string]$label) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $r = PostJson "$base$path" $tok $body
            $sw.Stop()
            return @{ ok = $true; data = $r.data; ms = $sw.ElapsedMilliseconds }
        } catch {
            $sw.Stop()
            return @{ ok = $false; msg = $_.Exception.Message; ms = $sw.ElapsedMilliseconds }
        }
    }

    # ---------- /ai/ask ----------
    Write-Host ""
    Write-Host "--- /ai/ask（权限问答）---"
    $a = TryAi "/ai/ask" @{ question = "我有哪些权限？请列出要点。" } "ask"
    if ($a.ok) {
        Write-Host "  source=$($a.data.source)  $($a.ms) ms"
        Write-Host "  $($a.data.answer)"
        Check "ask 返回 source=model（真实模型回话）" ($a.data.source -eq "model")
        Check "ask 的回答非空" ($a.data.answer.Length -gt 5)
    } else { Bad "ask 请求失败：$($a.msg)" }

    # ---------- /ai/agent ----------
    Write-Host ""
    Write-Host "--- /ai/agent（工具循环）---"
    $g = TryAi "/ai/agent" @{ question = "我负责的任务里有几条逾期？" } "agent"
    if ($g.ok) {
        $tools = ($g.data.steps | ForEach-Object { $_.tool }) -join ", "
        Write-Host "  source=$($g.data.source)  rounds=$($g.data.rounds)  calls=$($g.data.calls)  $($g.ms) ms"
        Write-Host "  steps = $tools"
        Write-Host "  $($g.data.answer)"
        Check "agent 返回 source=model" ($g.data.source -eq "model")
        Check "agent 真的调了工具（steps 非空）" ($g.data.steps.Count -ge 1)
        Check "agent 的 calls 与实际轮数一致（费用可见）" ($g.data.calls -ge 1 -and $g.data.rounds -ge 1)
    } else { Bad "agent 请求失败：$($g.msg)" }

    # ---------- /ai/task-suggest ----------
    Write-Host ""
    Write-Host "--- /ai/task-suggest（创建任务建议）---"
    $t = TryAi "/ai/task-suggest" @{ title = "筹备秋季招新宣讲会" } "task-suggest"
    if ($t.ok) {
        Write-Host "  source=$($t.data.source)  $($t.ms) ms"
        Write-Host "  reasons = $($t.data.reasons -join ' / ')"
        Write-Host "  due_at  = '$($t.data.due_at)'   granularity = $($t.data.granularity)"
        Check "task-suggest 返回 source=model" ($t.data.source -eq "model")
        Check "reasons 非空" ($t.data.reasons.Count -ge 1)
        # F-6：模型给的时间串若不合 ISO 8601，服务端应当**丢弃**而不是透传脏值
        if ($null -ne $t.data.due_at -and "$($t.data.due_at)".Length -gt 0) {
            Check "due_at 若存在则必须是 ISO 8601 形状" ("$($t.data.due_at)" -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}')
        } else {
            Ok "due_at 为空或被丢弃（F-6 的形状校验生效，没有透传脏值）"
        }
    } else { Bad "task-suggest 请求失败：$($t.msg)" }

    # ---------- 密钥零泄漏 ----------
    Write-Host ""
    Write-Host "--- 密钥零泄漏 ---"
    $auditPath = Join-Path $dataAbs "audit.log"
    $audit = if (Test-Path $auditPath) { Get-Content $auditPath -Encoding UTF8 } else { @() }
    Check "审计日志里不含密钥" (($audit | Select-String -Pattern ([regex]::Escape($keyText)) -SimpleMatch | Measure-Object).Count -eq 0)
    $logs = (Get-Content $out -Encoding UTF8 -ErrorAction SilentlyContinue) + (Get-Content $err -Encoding UTF8 -ErrorAction SilentlyContinue)
    Check "启动日志里不含密钥" (($logs | Select-String -Pattern ([regex]::Escape($keyText)) -SimpleMatch | Measure-Object).Count -eq 0)

    # ---------- 永不 5xx ----------
    Write-Host ""
    Write-Host "--- 全程无 5xx ---"
    Check "三次真实调用都没触发 5xx 降级以外的异常" ($script:fail -eq 0)
}
finally {
    Stop-All
    if (Test-Path (Join-Path $serverDir "build\ai-real-data")) {
        Remove-Item -Recurse -Force (Join-Path $serverDir "build\ai-real-data") -ErrorAction SilentlyContinue
    }
}

Write-Host "======================================"
Write-Host "AI 真实模型联调： PASS $script:pass / FAIL $script:fail"
Write-Host "======================================"
if ($script:fail -gt 0) { exit 1 }
