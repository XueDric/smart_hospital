<#
.SYNOPSIS
    把仓颉 SDK 的下载直链写进 GitHub 仓库变量 CANGJIE_SDK_URL，并用它做一次前置校验。

.DESCRIPTION
    为什么需要这一步：
      `.github/workflows/repo-hygiene.yml` 的 `build-and-test` job 要"真的编译一次"，
      就得先拿到仓颉 SDK 1.2.0 的 zip。官方下载页
      （https://cangjie-lang.cn/download/1.2.0）的直链是**前端点击时签名生成**的，
      不在 HTML、__INITIAL_STATE__ 或任何可静态抓取的 JS 里 —— 所以直链只能由人在
      浏览器里点一次「Windows x64 SDK 下载」，从 F12 → Network 里复制那个 .zip 的 URL。

    拿到 URL 之后，**其余全自动**：本脚本负责
      1. 校验 URL 真的能下到一个 zip（HTTP 200/206、Content-Type 或 Content-Length
         像 zip、前 1 KB 以 "PK" 开头），校验不过直接退出，不会写脏变量；
      2. 从环境变量或本机 git 凭据（git credential-manager）取 token；
      3. 调 GitHub REST API 写入仓库变量（已存在则更新，不存在则创建）；
      4. 回读确认，token 全程不打印。

    token 需要的权限：对目标仓库的 Actions variables 读写（classic PAT 的 `repo` 作用域，
    或 fine-grained token 的 Variables: Read and write）。Git Credential Manager 存下的
    OAuth token 通常够用；不够时脚本会把 GitHub 的原始报错打出来。

.PARAMETER Url
    浏览器里复制出来的 SDK zip 直链（通常很长，带签名参数）。

.PARAMETER Repo
    目标仓库，默认 XueDric/smart_hospital。

.PARAMETER Name
    变量名，默认 CANGJIE_SDK_URL。

.PARAMETER Token
    显式提供 token（不传则读 $env:GITHUB_TOKEN，再不行走 git 凭据）。

.PARAMETER DryRun
    只做第 1 步的 URL 校验，不写任何东西。

.EXAMPLE
    pwsh tools/set-ci-sdk-url.ps1 -Url 'https://.../cangjie-sdk-windows-x64-1.2.0.zip?sign=...'

.EXAMPLE
    pwsh tools/set-ci-sdk-url.ps1 -Url '...' -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Url,
    [string]$Repo = 'XueDric/smart_hospital',
    [string]$Name = 'CANGJIE_SDK_URL',
    [string]$Token = '',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Step([string]$msg) { Write-Host ("[set-sdk-url] " + $msg) }

# ---------------------------------------------------------------- 1. 校验 URL
Write-Step ("校验 URL：" + $Url.Substring(0, [Math]::Min(80, $Url.Length)) + $(if ($Url.Length -gt 80) { "…" } else { "" }))

if ($Url -notmatch '^https://') {
    throw "只接受 https:// 直链（提交的是 zip 下载地址，不是网页地址）：$Url"
}

function Get-ProbeHeaders([string]$u) {
    # HEAD 最快：只读头，不下载。有的仓库/对象存储不支持 HEAD（405），调用方再退回 Range GET。
    $h = & curl.exe -sS -I -L --max-time 30 $u 2>&1 | Out-String
    return $h
}
function Parse-Probe([string]$hdr) {
    $o = [pscustomobject]@{ Code = 0; Type = ''; Bytes = 0L }
    $line = ($hdr -split "`r?`n" | Where-Object { $_ -match '^HTTP/' } | Select-Object -Last 1)
    if ($line -match '\s(?<c>\d{3})') { $o.Code = [int]$matches['c'] }
    $m = [regex]::Match($hdr, '(?im)^content-type:\s*(?<v>[^\r\n]+)')
    if ($m.Success) { $o.Type = $m.Groups['v'].Value.Trim() }
    $m = [regex]::Match($hdr, '(?im)^content-range:\s*bytes\s+\d+-\d+/(?<n>\d+)')
    if ($m.Success) { $o.Bytes = [int64]$m.Groups['n'].Value }
    else {
        $m = [regex]::Match($hdr, '(?im)^content-length:\s*(?<n>\d+)')
        if ($m.Success) { $o.Bytes = [int64]$m.Groups['n'].Value }
    }
    return $o
}

$hdrText = Get-ProbeHeaders $Url
$probe = Parse-Probe $hdrText

# HEAD 不可用（405/403/501）或拿不到类型时，退回 Range GET 取前 1 KB 看魔数。
# PS 5.1 的 Invoke-WebRequest 不允许 -Headers 带 Range，所以统一用 curl。
$magic = ''
$usedRange = $false
if ($probe.Code -eq 0 -or $probe.Code -eq 405 -or $probe.Code -eq 501 -or $probe.Type -eq '') {
    $usedRange = $true
    $probeFile = Join-Path ([System.IO.Path]::GetTempPath()) ("sdk-probe-" + [guid]::NewGuid().ToString('N') + ".bin")
    $hdrText2 = & curl.exe -sS -D - -o $probeFile -r 0-1023 --max-time 45 $Url 2>&1 | Out-String
    $p2 = Parse-Probe $hdrText2
    if ($p2.Code -ne 0) { $probe = $p2 }
    if (Test-Path $probeFile) {
        $buf = [System.IO.File]::ReadAllBytes($probeFile)
        if ($buf.Length -ge 2) { $magic = [System.Text.Encoding]::ASCII.GetString($buf, 0, 2) }
        Remove-Item -LiteralPath $probeFile -Force -ErrorAction SilentlyContinue
    }
}

if ($probe.Code -ne 200 -and $probe.Code -ne 206) {
    throw ("这个 URL 拿不到文件（HTTP " + $probe.Code + "）。`n" +
        "常见原因：直链带签名有效期（几分钟就过期）、需要登录态、或复制到的是网页地址而不是 .zip。")
}

if ($probe.Type -match 'text/html') {
    throw ("这个 URL 返回的是网页（Content-Type=" + $probe.Type + "），不是 zip。`n" +
        "官方下载页对任意路径都回 200 + text/html，所以必须回到页面点一次「Windows x64 SDK 下载」，" +
        "在 F12 → Network 里复制**类型是 x-zip / octet-stream 的那一条**的 Request URL。")
}

$zipByType = ($probe.Type -match 'zip|x-zip|octet-stream|application/unknown|force-download')
$zipBySize = ($probe.Bytes -gt 50MB)
$zipByMagic = ($magic -eq 'PK')

if (-not ($zipByType -or $zipBySize -or $zipByMagic)) {
    throw ("这个 URL 看起来不是 zip" +
        $(if ($usedRange) { "（已取前 1 KB：魔数='" + $magic + "'）" } else { "（HEAD 没给出可判定的类型）" }) +
        "：Content-Type=" + $probe.Type + "，大小=" + $probe.Bytes + " 字节。`n" +
        "请确认复制的是 SDK zip 的 Request URL。")
}

Write-Step ("✅ 看起来是真 zip：HTTP " + $probe.Code + "，Content-Type=" + $probe.Type +
    "，大小≈" + $(if ($probe.Bytes -gt 0) { [Math]::Round($probe.Bytes / 1MB, 1).ToString() + " MB" } else { "未知" }) +
    "，判据=" + $(if ($zipByMagic) { "魔数 PK" } elseif ($zipByType) { "Content-Type" } else { "体积 > 50 MB" }))

if ($DryRun) {
    Write-Step "-DryRun：只校验，不写变量。"
    exit 0
}
# ---------------------------------------------------------------- 2. 取 token
if ([string]::IsNullOrWhiteSpace($Token)) { $Token = [Environment]::GetEnvironmentVariable('GITHUB_TOKEN') }
if ([string]::IsNullOrWhiteSpace($Token)) { $Token = [Environment]::GetEnvironmentVariable('GH_TOKEN') }

$tokenSource = '参数/环境变量'
if ([string]::IsNullOrWhiteSpace($Token)) {
    $tokenSource = 'git 凭据管理器'
    $inp = "protocol=https`nhost=github.com`n`n"
    $out = ($inp | & git credential-manager get 2>$null | Out-String)
    $lines = $out -split "`r?`n"
    $Token = (($lines | Where-Object { $_ -like 'password=*' }) -replace '^password=', '')
}

if ([string]::IsNullOrWhiteSpace($Token)) {
    throw "拿不到 GitHub token：请设 `$env:GITHUB_TOKEN，或用 -Token 传入（需 repo 作用域 / Variables 读写）。"
}
Write-Step ("token 来源：" + $tokenSource + "（长度 " + $Token.Length + "，内容不打印）")

$headers = @{
    Authorization          = "token $Token"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = 'smart_hospital-set-ci-sdk-url'
}

function Invoke-Gh([string]$method, [string]$uri, $body) {
    $args2 = @{ Method = $method; Uri = $uri; Headers = $headers; TimeoutSec = 60 }
    if ($body) { $args2['Body'] = ($body | ConvertTo-Json -Compress); $args2['ContentType'] = 'application/json' }
    try { return Invoke-RestMethod @args2 }
    catch {
        $code = ''
        try { $code = [int]$_.Exception.Response.StatusCode } catch {}
        $raw = ''
        try {
            $sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $raw = $sr.ReadToEnd()
        } catch {}
        return [pscustomobject]@{ __error = $true; __code = $code; __raw = $raw; __msg = $_.Exception.Message }
    }
}

# ---------------------------------------------------------------- 3. 写变量
Write-Step ("写入仓库变量 " + $Repo + " / " + $Name)
$payload = @{ name = $Name; value = $Url }
$created = $null
$posted = Invoke-Gh 'POST' ("https://api.github.com/repos/" + $Repo + "/actions/variables") $payload

if ($posted -and -not $posted.__error) {
    $created = 'created'
} elseif ($posted.__code -eq 409) {
    Write-Step "变量已存在 → 改为更新"
    $updated = Invoke-Gh 'PATCH' ("https://api.github.com/repos/" + $Repo + "/actions/variables/" + $Name) @{ name = $Name; value = $Url }
    if ($updated -and -not $updated.__error) { $created = 'updated' }
    else {
        Write-Step ("更新失败（HTTP " + $updated.__code + "）：" + $updated.__raw)
        # 兼容老 API：也试一次 PUT
        $put = Invoke-Gh 'PUT' ("https://api.github.com/repos/" + $Repo + "/actions/variables/" + $Name) @{ name = $Name; value = $Url }
        if ($put -and -not $put.__error) { $created = 'updated(put)' }
        else {
            Write-Step ("PUT 也失败（HTTP " + $put.__code + "）：" + $put.__raw)
            throw "写变量失败：token 可能没有 Actions variables 的写权限（需要 repo 作用域或 Variables: Read and write）。"
        }
    }
} else {
    Write-Step ("创建失败（HTTP " + $posted.__code + "）：" + $posted.__raw)
    throw "写变量失败：token 可能没有 Actions variables 的写权限（需要 repo 作用域或 Variables: Read and write）。"
}

# ---------------------------------------------------------------- 4. 回读
$list = Invoke-Gh 'GET' ("https://api.github.com/repos/" + $Repo + "/actions/variables") $null
if ($list -and -not $list.__error) {
    $hit = @($list.variables | Where-Object { $_.name -eq $Name })
    if ($hit.Count -gt 0) {
        $same = ($hit[0].value -eq $Url)
        Write-Step ("✅ 已写入（" + $created + "）：" + $Name + " 长度 " + ([string]$hit[0].value).Length +
            "，回读" + $(if ($same) { "一致" } else { "**不一致**（请重跑）" }))
        if (-not $same) { exit 1 }
    } else {
        Write-Step ("⚠ 回读没看到 " + $Name + "（可能需要几十秒生效）")
    }
} else {
    Write-Step "⚠ 回读失败，但写入已返回成功"
}

Write-Step "下一步：Actions 里手动跑一次 Repo Hygiene（或推一个提交），build-and-test 的「校验 SDK 压缩包」这一步应能通过。"
