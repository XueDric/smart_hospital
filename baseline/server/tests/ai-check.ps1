<#
.SYNOPSIS
    AI 模块回归闸门（**不需要 MySQL**）。

.DESCRIPTION
    为什么不需要数据库：`serve` 在**连库之前**就解析参数、校验 AI 配置并打印 `[AI]` 行，
    所以「参数被接受 / 配置被正确解读」这类断言只靠启动日志就能判定
    （进程随后会因连不上 MySQL 而退出，那是预期）。

    覆盖：
      AI-1  --ai-* 被 CLI 白名单接受，且启动行显示已启用
      AI-13 空密钥文件 -> 明确判为「未配置」，而不是发 Bearer 空串
      AI-16 URL 里的 userinfo 不出现在启动日志里（防密钥露头）
      AI-2  出站读体不再把「短读」当 EOF（调用 spike/llm-truncation 的探针）

    判据：**FAIL 0**（与项目其它测试同一口径）。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\ai-check.ps1
#>
$ErrorActionPreference = "Stop"

$serverDir = Split-Path -Parent $MyInvocation.MyCommand.Path | Split-Path -Parent
$repoDir   = Split-Path -Parent $serverDir
$exe       = Join-Path $serverDir "build\club-server.exe"

if (-not (Test-Path $exe)) { throw "找不到 $exe —— 先跑 server\build.ps1" }

$script:pass = 0
$script:fail = 0
function Ok([string]$m)  { $script:pass++; Write-Host "  ok    $m" }
function Bad([string]$m) { $script:fail++; Write-Host "  FAIL  $m" }

# 起一次 serve 并抓启动日志。它随后会因连不上 MySQL 退出，属预期。
function Get-StartupLog([string[]]$argv) {
    $out = Join-Path $env:TEMP "ai-check-out.txt"
    $err = Join-Path $env:TEMP "ai-check-err.txt"
    Remove-Item $out, $err -ErrorAction SilentlyContinue
    $p = Start-Process -FilePath $exe -PassThru -NoNewWindow `
         -ArgumentList $argv -RedirectStandardOutput $out -RedirectStandardError $err
    # R-2：等它自己退出（DSN 故意不可达，连库必然失败）；只有超时才强杀。
    $p.WaitForExit(15000) | Out-Null
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    # 子进程写的是 UTF-8；PS 5.1 的 Get-Content 默认按 ANSI 读 → 中文变乱码、匹配必失败
    # （本脚本第一版就踩了这个坑）。必须显式指定 UTF8。
    $text = ((Get-Content $out -Encoding UTF8 -ErrorAction SilentlyContinue) -join "`n")
    # R-2：日志为空时断言毫无意义（否定式断言会恒真）——直接判 Bad 并带上 stderr。
    if ($text.Trim().Length -eq 0) {
        $errTxt = ((Get-Content $err -Encoding UTF8 -ErrorAction SilentlyContinue) -join "`n")
        Bad "启动日志为空，无法判定配置行为。stderr: $errTxt"
    }
    return $text
}

# R-2（2026-10-05 晚修）：DSN 故意指向**不可达**端口。
# 本地 3307 上通常正跑着 MariaDB（正是文档指定的联调环境），指向它时 serve 会连上库、
# 一直活着 → 被 Stop-Process 强杀 → 仓颉 println 在重定向到文件时是**块缓冲**，
# 缓冲区随进程消失 → 日志 0 字节 → 三条"否定式"断言在空日志上恒真（假红）。
# 配置类断言本来就不需要真库，所以让它必然连不上、自然退出即可。
$dsn       = "mysql://root:clubroot123@127.0.0.1:1/club_ai_check"
$endpoint  = "http://127.0.0.1:18999/v1/chat/completions"
$keyFile   = Join-Path $env:TEMP "ai-check-key.txt"
$emptyKey  = Join-Path $env:TEMP "ai-check-empty.txt"
[IO.File]::WriteAllText($keyFile,  "sk-dummy", [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($emptyKey, "",         [Text.UTF8Encoding]::new($false))

Write-Host ""
Write-Host "AI 模块检查（不需要 MySQL）"
Write-Host "======================================"

# ---- AI-1：参数被接受 + 启动行显示已启用 ----
$log1 = Get-StartupLog @('serve', '18211', $dsn, '--ai-endpoint', $endpoint,
                         '--ai-model', 'stub', '--ai-key-file', $keyFile,
                         '--ai-insecure-trust-all', '1')
if ($log1 -match '不认识的参数') {
    Bad "AI-1 参数仍被 CLI 拒绝（配 AI 会让 serve 直接退出）"
} else {
    Ok "AI-1 --ai-* 参数被 CLI 接受"
}
if ($log1 -match '已启用') {
    Ok "AI-1 启动行显示 AI 已启用"
} else {
    Bad "AI-1 启动行未见「已启用」（实际：$($log1 -split "`n" | Select-Object -First 1)）"
}

# ---- AI-16：userinfo 不得出现在启动日志 ----
$log2 = Get-StartupLog @('serve', '18212', $dsn,
                         '--ai-endpoint', 'http://sk-secret@127.0.0.1:18999/v1/chat/completions',
                         '--ai-model', 'stub', '--ai-key-file', $keyFile,
                         '--ai-insecure-trust-all', '1')
if ($log2 -match 'sk-secret') {
    Bad "AI-16 URL userinfo 泄漏进了启动日志"
} else {
    Ok "AI-16 URL userinfo 未出现在启动日志"
}

# ---- AI-13：空密钥文件必须判为未配置 ----
$log3 = Get-StartupLog @('serve', '18213', $dsn, '--ai-endpoint', $endpoint,
                         '--ai-model', 'stub', '--ai-key-file', $emptyKey,
                         '--ai-insecure-trust-all', '1')
if ($log3 -match '密钥文件是空的') {
    Ok "AI-13 空密钥文件被判为「未配置」"
} else {
    Bad "AI-13 空密钥文件未被拦住（会在每个请求上发 Bearer 空串）"
}

# ---- AI-2：出站读体的短读截断（探针在 spike/llm-truncation） ----
$probe = Join-Path $repoDir "spike\llm-truncation\build\probe.exe"
$stub  = Join-Path $repoDir "spike\llm-truncation\stub.mjs"
if ((Test-Path $probe) -and (Test-Path $stub)) {
    $sp = Start-Process -FilePath "node" -ArgumentList "stub.mjs", "19001" -PassThru -NoNewWindow `
          -WorkingDirectory (Split-Path -Parent $stub)
    Start-Sleep -Seconds 2
    try {
        $pr = & $probe "http://127.0.0.1:19001" 2>&1 | Out-String
        # 探针里的「框架截断」是在**演示框架的缺陷**（那是预期的，也是修法的依据）；
        # 我们要断言的是**正确读法**没有被截断 —— 探针为此输出纯 ASCII 判定行
        # （PS 5.1 按 ANSI 读子进程输出，中文匹配不可靠）。
        if ($pr -match 'FIXED_READER_OK=1') {
            Ok "AI-2 正确读法未出现短读截断（框架读法的截断同时被探针记录）"
        } else {
            Bad "AI-2 探针未给出 FIXED_READER_OK=1（读体逻辑可能回退）"
        }
    } finally {
        Stop-Process -Id $sp.Id -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-Host "  SKIP  AI-2 探针未构建（先跑 spike\llm-truncation\build.ps1）"
}

Remove-Item $keyFile, $emptyKey -Force -ErrorAction SilentlyContinue

Write-Host "======================================"
Write-Host "AI 模块检查： PASS $script:pass / FAIL $script:fail"
Write-Host "======================================"
if ($script:fail -gt 0) { exit 1 }
