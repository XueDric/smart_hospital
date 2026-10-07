<#
.SYNOPSIS
    一键「改服务器地址 + 出包」脚本（鸿蒙客户端 / ArkTS）。

.DESCRIPTION
    把地址同时写进两个必须一致的地方，然后调用 hvigorw 编译：

      1) entry\src\main\ets\config\Env.ets
         - DEV_BASE_URL      （debug 构建用）
         - RELEASE_BASE_URL  （release 构建用；不改它，release 包会指向
                              replace-before-release.invalid 占位符，必然连不上）

      2) entry\src\main\resources\base\profile\network_config.json
         - 明文 HTTP 白名单里补上这个 IP

    签名由 build-profile.json5 的 signingConfigs 决定（见该文件注释）。
    产物默认是【未签名】的 HAP，装不到手机上。

.PARAMETER Ip
    后端电脑的局域网 IP（例如 10.179.153.237）。必填。

.PARAMETER Port
    后端端口。默认 8080。

.PARAMETER ApiPath
    接口路径前缀。默认 /api/v1。

.PARAMETER Mode
    debug（默认）或 release。release 会额外传 -p buildMode=release。

.PARAMETER NoBuild
    只改地址、不编译。用来先看一眼改了什么。

.PARAMETER DevEcoHome
    DevEco Studio 安装目录。默认 D:\DevEco Studio。

.EXAMPLE
    .\scripts\build-client.ps1 -Ip 10.179.153.237

.EXAMPLE
    .\scripts\build-client.ps1 -Ip 10.179.153.237 -NoBuild     # 只改地址

.NOTES
    ⚠ 跑之前请先【关闭 DevEco Studio】—— 它会锁住 entry\build，
      导致 hvigor 的 clean 阶段失败（Unable to delete ...entry\build）。

    本文件必须以 UTF-8 with BOM 保存，否则 Windows PowerShell 5.1 会按 GBK
    读，中文注释会把脚本解析坏。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Ip,

    [int]$Port = 8080,

    [string]$ApiPath = '/api/v1',

    [ValidateSet('debug', 'release')]
    [string]$Mode = 'debug',

    [switch]$NoBuild,

    [string]$DevEcoHome = 'D:\DevEco Studio'
)

$ErrorActionPreference = 'Stop'
# 本脚本位于仓库的 scripts\ 目录下：仓库根目录 = 脚本所在目录的父目录
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }
$Root = Split-Path $ScriptDir -Parent

# ---------------------------------------------------------------- 小工具
function Write-Step([string]$Text) { Write-Host "`n=== $Text ===" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "  [OK]   $Text" -ForegroundColor Green }
function Write-Warn2([string]$Text){ Write-Host "  [注意] $Text" -ForegroundColor Yellow }
function Write-Err2([string]$Text) { Write-Host "  [错误] $Text" -ForegroundColor Red }

# 用 .NET 写文件：保证 UTF-8 无 BOM（PowerShell 的 Set-Content -Encoding UTF8 会加 BOM）
function Write-TextNoBom([string]$Path, [string]$Text) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Text, $enc)
}

# 保留原文件的行尾风格，避免整文件 diff
function Get-Newline([string]$Text) {
    if ($Text.Contains("`r`n")) { return "`r`n" } else { return "`n" }
}

# 安全删除可能含目录符号链接的缓存树（PowerShell 的 -Recurse 会去递归链接目标而失败）
function Remove-CacheTree([string]$Dir) {
    if (-not (Test-Path -LiteralPath $Dir)) { return }
    Get-ChildItem -Recurse -Force -LiteralPath $Dir -ErrorAction SilentlyContinue |
        Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } |
        Sort-Object { $_.FullName.Length } -Descending |
        ForEach-Object {
            try {
                if ($_.PSIsContainer) { [IO.Directory]::Delete($_.FullName, $false) }
                else                  { [IO.File]::Delete($_.FullName) }
            } catch { }
        }
    Remove-Item -Recurse -Force -LiteralPath $Dir -ErrorAction SilentlyContinue
}

# 判断 HAP 是否带签名块。
# 签名块位于「本地文件数据结束」与「中央目录开始」之间，所以判据是
# 中央目录偏移 > 本地数据结束偏移。
# ⚠ 不能用「中央目录是否紧贴 EOCD」判断 —— 有签名和没签名时，中央目录
#   都是紧贴 EOCD 的（签名块插在它前面，CD 偏移会跟着后移）。
function Test-HapSigned([string]$HapPath) {
    try {
        $b = [IO.File]::ReadAllBytes($HapPath)
        $len = $b.Length
        $eocd = -1
        for ($i = $len - 22; $i -ge 0; $i--) {
            if ($b[$i] -eq 0x50 -and $b[$i+1] -eq 0x4B -and $b[$i+2] -eq 0x05 -and $b[$i+3] -eq 0x06) { $eocd = $i; break }
        }
        if ($eocd -lt 0) { return $false }
        $cdOff = [BitConverter]::ToUInt32($b, $eocd + 16)

        # 逐个走本地文件头，算出本地数据在哪里结束
        $off = 0
        while ($off + 30 -le $len -and
               $b[$off] -eq 0x50 -and $b[$off+1] -eq 0x4B -and
               $b[$off+2] -eq 0x03 -and $b[$off+3] -eq 0x04) {
            $compSize = [BitConverter]::ToUInt32($b, $off + 18)
            $nameLen  = [BitConverter]::ToUInt16($b, $off + 26)
            $extraLen = [BitConverter]::ToUInt16($b, $off + 28)
            $next = $off + 30 + $nameLen + $extraLen + $compSize
            if ($next -le $off) { break }
            $off = $next
        }
        return ($cdOff -gt $off)
    } catch { return $false }
}

# ---------------------------------------------------------------- 0. 入参校验
Write-Step "0. 检查入参"

if ($Ip -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
    Write-Err2 "IP 格式不对：$Ip（要形如 10.179.153.237）"
    exit 1
}
foreach ($seg in $Ip.Split('.')) {
    if ([int]$seg -gt 255) { Write-Err2 "IP 段超过 255：$Ip"; exit 1 }
}

$BaseUrl = "http://{0}:{1}{2}" -f $Ip, $Port, $ApiPath
Write-Ok "服务器地址 : $BaseUrl"
Write-Ok "构建模式   : $Mode"
Write-Ok "工程根目录 : $Root"

$EnvFile = Join-Path $Root 'entry\src\main\ets\config\Env.ets'
$NcFile  = Join-Path $Root 'entry\src\main\resources\base\profile\network_config.json'

foreach ($f in @($EnvFile, $NcFile)) {
    if (-not (Test-Path -LiteralPath $f)) { Write-Err2 "找不到文件：$f"; exit 1 }
}

# ---------------------------------------------------------------- 1. 改 Env.ets
Write-Step "1. 改写 Env.ets（DEV_BASE_URL 与 RELEASE_BASE_URL 一起改）"

$envText = [IO.File]::ReadAllText($EnvFile)
$envOrig = $envText

# 用 MatchEvaluator 替换，避免 URL 里的特殊字符被当成正则替换引用
$evaluator = { param($m) $m.Groups[1].Value + $BaseUrl + $m.Groups[2].Value }

$envText = [regex]::Replace($envText, "(const\s+DEV_BASE_URL\s*:\s*string\s*=\s*')[^']*(')", $evaluator)
$envText = [regex]::Replace($envText, "(const\s+RELEASE_BASE_URL\s*:\s*string\s*=\s*')[^']*(')", $evaluator)

$expect = "const DEV_BASE_URL: string = '" + $BaseUrl + "'"
if (-not $envText.Contains($expect)) {
    Write-Err2 "DEV_BASE_URL 改写失败，文件结构可能变了。请手动检查 $EnvFile"
    exit 1
}

if ($envText -eq $envOrig) {
    Write-Warn2 "Env.ets 内容无变化（地址本来就是 $BaseUrl）"
} else {
    Write-TextNoBom $EnvFile $envText
    Write-Ok "已写入 $EnvFile"
}

# ---------------------------------------------------------------- 2. 改 network_config.json
Write-Step "2. 改写 network_config.json（明文 HTTP 白名单）"

$hosts = New-Object System.Collections.Generic.List[string]
foreach ($h in @('10.0.2.2', '127.0.0.1', 'localhost')) { $hosts.Add($h) }
if (-not $hosts.Contains($Ip)) { $hosts.Add($Ip) }

$ncOrig = [IO.File]::ReadAllText($NcFile)
$nl = Get-Newline $ncOrig

# base-config 的值原样保留：脚本只负责「把 IP 加进白名单」，不替使用者做安全判断
$baseCleartext = 'false'
$mBc = [regex]::Match($ncOrig, '"base-config"\s*:\s*\{[^}]*"cleartext-traffic-permitted"\s*:\s*(true|false)')
if ($mBc.Success) { $baseCleartext = $mBc.Groups[1].Value }

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('{')
$lines.Add('  "network-security-config": {')
$lines.Add('    "base-config": {')
$lines.Add(('      "cleartext-traffic-permitted": {0}' -f $baseCleartext))
$lines.Add('    },')
$lines.Add('    "domain-config": [')
$lines.Add('      {')
$lines.Add('        "cleartext-traffic-permitted": true,')
$lines.Add('        "domains": [')
for ($i = 0; $i -lt $hosts.Count; $i++) {
    $comma = ''
    if ($i -lt $hosts.Count - 1) { $comma = ',' }
    $lines.Add('          {')
    $lines.Add('            "include-subdomains": false,')
    $lines.Add(('            "name": "{0}"' -f $hosts[$i]))
    $lines.Add(('          }}{0}' -f $comma))
}
$lines.Add('        ]')
$lines.Add('      }')
$lines.Add('    ]')
$lines.Add('  }')
$lines.Add('}')

Write-TextNoBom $NcFile (($lines -join $nl) + $nl)
Write-Ok "已写入 $NcFile"
Write-Ok "白名单：$($hosts -join ', ')"
Write-Ok "base-config 保持原值：cleartext-traffic-permitted = $baseCleartext"
Write-Warn2 "docs\local-deploy.md 5.4 记录这个键在本机 SDK 里可能是惰性配置；这里按保险起见一并改。"

# ---------------------------------------------------------------- 3. 编译
$OutputDir = Join-Path $Root 'entry\build\default\outputs\default'

if ($NoBuild) {
    Write-Step "3. 已指定 -NoBuild，跳过编译"
    Write-Host "`n地址已改好。要编译请去掉 -NoBuild 再跑一次。" -ForegroundColor Yellow
    exit 0
}

Write-Step "3. 编译（hvigorw assembleHap）"

$HvigorBat = Join-Path $DevEcoHome 'tools\hvigor\bin\hvigorw.bat'
if (-not (Test-Path -LiteralPath $HvigorBat)) {
    Write-Err2 "在 $DevEcoHome 下找不到 hvigorw.bat，请用 -DevEcoHome 指定 DevEco 安装目录"
    exit 1
}

# 必须用 DevEco 自带 JBR：系统 PATH 上的 java 可能是 JDK7，会让最后一步 PackageHap 挂掉
$env:DEVECO_SDK_HOME = Join-Path $DevEcoHome 'sdk'
$env:JAVA_HOME       = Join-Path $DevEcoHome 'jbr'
$env:PATH            = (Join-Path $DevEcoHome 'jbr\bin') + ';' +
                       (Join-Path $DevEcoHome 'tools\node') + ';' +
                       (Join-Path $DevEcoHome 'tools\ohpm\bin') + ';' + $env:PATH

$hvigorArgs = @('assembleHap', '--no-daemon')
if ($Mode -eq 'release') { $hvigorArgs += @('-p', 'buildMode=release') }

function Invoke-Hvigor {
    # hvigor 会把普通告警写到 stderr。配合 2>&1 这些行会变成 ErrorRecord，
    # 若此时 ErrorActionPreference 是 Stop，脚本会在编译中途直接中断 —— 必须临时降级。
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $all = & $HvigorBat @hvigorArgs 2>&1
    } finally {
        $ErrorActionPreference = $oldEap
    }
    $all | ForEach-Object { Write-Host $_ }
    return ($all | Out-String)
}

$log = Invoke-Hvigor

# hvigor 的用户级缓存坏掉时会报 ENOENT ...@ohos\hvigor\bin\hvigor.js —— 删掉那个 workspace 重试一次
if ($log -match 'ENOENT' -and $log -match 'hvigor\.js') {
    $m = [regex]::Match($log, '([A-Za-z]:\\[^\r\n]*?)\\node_modules\\@ohos\\hvigor\\bin\\hvigor\.js')
    if ($m.Success) {
        $cacheWs = $m.Groups[1].Value
        Write-Warn2 "检测到 hvigor 缓存损坏，正在清理并重试：$cacheWs"
        Remove-CacheTree $cacheWs
        $log = Invoke-Hvigor
    }
}

if ($log -notmatch 'BUILD SUCCESSFUL') {
    Write-Err2 "编译失败。请看上面的 hvigor 输出。"
    Write-Host "`n常见原因：" -ForegroundColor Yellow
    if ($log -match 'Unable to delete|正由另一进程使用') {
        Write-Host "  ★ entry\build 被占用 —— 多半是 DevEco Studio 开着，请先关掉它再跑" -ForegroundColor Yellow
    }
    Write-Host "  - DevEco 安装路径不对（用 -DevEcoHome 指定）"
    Write-Host "  - ArkTS 代码有语法或类型错误"
    exit 1
}

# ---------------------------------------------------------------- 4. 报告产物
Write-Step "4. 产物"

# 优先报「已签名」的那份：hvigor 签名成功时产的是 entry-default-signed.hap，
# 但旧的 entry-default-unsigned.hap 不会自动删除，只按时间挑可能挑错。
$hapCandidates = @(Get-ChildItem -Path $OutputDir -Filter *.hap -File -ErrorAction SilentlyContinue |
                   Sort-Object LastWriteTime -Descending)
$hap = $hapCandidates | Where-Object { Test-HapSigned $_.FullName } | Select-Object -First 1
if (-not $hap) { $hap = $hapCandidates | Select-Object -First 1 }

if (-not $hap) {
    Write-Warn2 "在 $OutputDir 下没找到 .hap"
    exit 0
}

$signed = Test-HapSigned $hap.FullName
Write-Host ("  文件   : {0}" -f $hap.FullName)
Write-Host ("  大小   : {0:N0} 字节" -f $hap.Length)
Write-Host ("  时间   : {0}" -f $hap.LastWriteTime)

if ($signed) {
    Write-Host "  签名   : 已签名 - 可以直接安装" -ForegroundColor Green
} else {
    Write-Host "  签名   : 未签名 - 装不上手机" -ForegroundColor Red
    Write-Host ""
    Write-Host "  检查 build-profile.json5：" -ForegroundColor Yellow
    Write-Host "    - app.signingConfigs 里要有配置"
    Write-Host "    - app.products[].signingConfig 必须引用它的 name（最容易漏）"
}

$hdc = Join-Path $DevEcoHome 'sdk\default\openharmony\toolchains\hdc.exe'
Write-Host ""
Write-Host "  验签（推荐发给同学前先跑）：" -ForegroundColor Cyan
Write-Host '    .\scripts\check-hap-signature.ps1'
Write-Host "  安装到手机：" -ForegroundColor Cyan
Write-Host ('    & "{0}" install "{1}"' -f $hdc, $hap.FullName)
Write-Host ""
Write-Host "  别忘了：手机要和后端电脑在同一个网络，且 club-server 正在运行。" -ForegroundColor Cyan
