<#
.SYNOPSIS
    用自己的大模型密钥替换内置演示密钥（一条命令，不必手改数据库）。

.DESCRIPTION
    背景（2026-10-18 决定）：
      · 仓库里内置的演示密钥 `builtin:demo` 有**有效期**（见 server\src\ai_builtin.cj
        的 AI_BUILTIN_DEMO_VALID_UNTIL），到期后服务端会拒绝它并提示换密钥；
      · 因此"换一把自己的密钥"必须是**一条命令**，而不是"打开数据库改 ai_setting 表"。

    脚本做三件事：
      1. 把 key 写进 server\ai-key.txt（该文件已被 .gitignore 排除，不会进仓库）；
      2. 调管理 API 把 `ai.key_ref` 改成 `file:<绝对路径>`（库里仍只存引用，不存密钥本体）；
      3. 调一次模型连通性自检，回显 ok / http_status / 耗时，失败时打印可执行的原因。

.PARAMETER ApiKey
    密钥本体。DeepSeek 形如 `sk-...`。⚠ 不要把它写进任何会被提交的文件。

.PARAMETER Base
    服务地址，默认 http://127.0.0.1:8091（与服务端、客户端的默认端口一致）。

.PARAMETER AdminPw
    管理员口令（脚本要用它登录后改配置）。
    部署时 `hospital-server.exe create-admin <dsn>` 会打印一次口令，注意保存。

.PARAMETER KeyFile
    密钥落盘路径，默认 <仓库>\server\ai-key.txt。已被 .gitignore 排除。

.PARAMETER WriteOnly
    只写文件、不调 API（服务端还没起、或想手工改配置时用）。

.EXAMPLE
    .\tools\set-ai-key.ps1 -ApiKey sk-xxxx -AdminPw Y7HE9GTDTFQK

.EXAMPLE
    .\tools\set-ai-key.ps1 -ApiKey sk-xxxx -WriteOnly
#>
param(
    [Parameter(Mandatory = $true)][string]$ApiKey,
    [string]$Base = 'http://127.0.0.1:8091',
    [string]$AdminPw = '',
    [string]$KeyFile = '',
    [switch]$WriteOnly
)

$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($KeyFile)) {
    $KeyFile = Join-Path $repo 'server\ai-key.txt'
}

$key = $ApiKey.Trim()
if ($key.Length -lt 16) {
    throw "这不像一把密钥（只有 $($key.Length) 个字符）。请确认复制完整。"
}
if (-not $key.StartsWith('sk-')) {
    Write-Warning "密钥不以 sk- 开头。如果你的服务商不用这个前缀，可以忽略这条警告。"
}

# ---------------------------------------------------------------------------
# 1) 落盘。⚠ 必须写成**无 BOM** 的纯 ASCII：
#    服务端读文件后会 trim 再放进 Authorization 头，BOM 会被当成密钥的一部分，
#    结果是"密钥明明对却一直 401" —— 这类症状最难查。
# ---------------------------------------------------------------------------
$dir = Split-Path -Parent $KeyFile
if (-not (Test-Path $dir)) {
    New-Item -ItemType Directory -Force $dir | Out-Null
}
[System.IO.File]::WriteAllText($KeyFile, $key, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "[1/3] 已写入密钥文件：$KeyFile（已 gitignore，不会进仓库）" -ForegroundColor Green

if ($WriteOnly) {
    Write-Host ""
    Write-Host "现在把服务端的密钥引用指向这个文件（任选其一）：" -ForegroundColor Cyan
    Write-Host "  · 管理台：AI 能力中心 → ai.key_ref → 编辑 → 填 file:$KeyFile"
    Write-Host "  · 或命令行：PUT $Base/api/v1/admin/ai/settings/ai.key_ref  body {`"value`":`"file:$KeyFile`"}"
    Write-Host ""
    Write-Host "（不带 -WriteOnly 再跑一次，脚本会自动完成上面两步并做连通性自检。）"
    return
}

if ([string]::IsNullOrWhiteSpace($AdminPw)) {
    throw "改配置需要管理员口令：加 -AdminPw <口令>，或只写文件用 -WriteOnly。"
}

# ---------------------------------------------------------------------------
# 2) 登录 + 改 ai.key_ref
# ---------------------------------------------------------------------------
$loginBody = @{ login_name = 'admin'; password = $AdminPw } | ConvertTo-Json -Compress
$login = Invoke-RestMethod -Uri "$Base/api/v1/auth/login" -Method Post `
    -ContentType 'application/json; charset=utf-8' `
    -Body ([System.Text.Encoding]::UTF8.GetBytes($loginBody))
$token = $login.data.token
if ([string]::IsNullOrWhiteSpace($token)) {
    throw "登录成功但没拿到令牌，响应：$($login | ConvertTo-Json -Compress -Depth 6)"
}
$headers = @{ Authorization = "Bearer $token" }

$ref = "file:$KeyFile"
$refBody = @{ value = $ref } | ConvertTo-Json -Compress
try {
    Invoke-RestMethod -Uri "$Base/api/v1/admin/ai/settings/ai.key_ref" -Method Put `
        -Headers $headers -ContentType 'application/json; charset=utf-8' `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($refBody)) | Out-Null
} catch {
    # ⚠ 只报状态与错误码，不回显 body —— 万一被拒的是密钥本体，回显就等于把它写进日志。
    $code = ''
    try { $code = ($_.ErrorDetails.Message | ConvertFrom-Json).error.code } catch { }
    throw "改 ai.key_ref 失败（HTTP $([int]$_.Exception.Response.StatusCode)${code}）。口令对吗？服务端起了吗？"
}
Write-Host "[2/3] 已把 ai.key_ref 设为 file:$KeyFile（库里只存引用，不存密钥本体）" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 3) 连通性自检：拿默认对话模型行跑一次 /test，把服务商的真实回话打出来
# ---------------------------------------------------------------------------
$models = Invoke-RestMethod -Uri "$Base/api/v1/admin/ai/models" -Headers $headers
$chat = @($models.data.items) | Where-Object { $_.kind -eq 'CHAT' -and $_.is_default } | Select-Object -First 1
if ($null -eq $chat) {
    $chat = @($models.data.items) | Where-Object { $_.kind -eq 'CHAT' } | Select-Object -First 1
}
if ($null -eq $chat) {
    Write-Warning "库里还没有对话模型行。到管理台 AI 能力中心新建一行（base_url / model）后再试。"
    return
}
$probe = Invoke-RestMethod -Uri "$Base/api/v1/admin/ai/models/$($chat.id)/test" -Method Post `
    -Headers $headers -ContentType 'application/json'
$p = $probe.data.probe
if ($p.ok) {
    Write-Host "[3/3] 自检通过：ok=true  http_status=$($p.http_status)  耗时 $($p.elapsed_ms) ms  模型 $($p.model)" -ForegroundColor Green
    Write-Host "      AI 已用你自己的密钥工作。内置演示密钥（builtin:demo）今后即使到期也不影响你。"
} else {
    Write-Warning "[3/3] 自检失败：$($p.reason)"
    Write-Host "     常见原因：endpoint 不是 https（除本机回环外强制 https）、模型名不对、密钥余额不足、"
    Write-Host "              或这台机器访问不到 api.deepseek.com（需要代理或 CA 包，见 docs\部署说明.md）。"
    exit 1
}
