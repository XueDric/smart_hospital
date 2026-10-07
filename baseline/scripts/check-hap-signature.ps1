<#
.SYNOPSIS
    检查 HAP 的签名状态，并判断「能不能发给同学装」。

.DESCRIPTION
    三件事：
      1) 判断 HAP 是否带签名块
         （签名块位于「本地文件数据结束」与「中央目录开始」之间）
      2) 从签名块里取出 provision profile，看 type / app-distribution-type /
         bundle-name / 证书身份 / 有效期 / 有没有设备白名单
      3) 把 bundle-name 和 AppScope\app.json5 对一下，看是不是同一个应用

    判决口径：
      type=release + app-distribution-type=app_gallery + 无设备列表
          -> 任何设备都能装，可以发给同学
      type=debug（profile 里有 debug-info / 设备列表）
          -> 只能装在 Profile 里登记过的设备上
      没有签名块
          -> 装不上，先检查 build-profile.json5 的 products[].signingConfig

.PARAMETER Hap
    要检查的 HAP。默认取 entry\build\default\outputs\default 下最新的一份。

.EXAMPLE
    .\scripts\check-hap-signature.ps1
    .\scripts\check-hap-signature.ps1 -Hap .\社团管理工具-1.0.0-1000000-release.hap
#>
[CmdletBinding()]
param(
    [string]$Hap
)

$ErrorActionPreference = 'Stop'
# 本脚本位于仓库的 scripts\ 目录下：仓库根目录 = 脚本所在目录的父目录
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }
$Root = Split-Path $ScriptDir -Parent

function Write-Step([string]$T) { Write-Host "`n=== $T ===" -ForegroundColor Cyan }
function Write-Ok([string]$T)   { Write-Host "  [OK]   $T" -ForegroundColor Green }
function Write-Bad([string]$T)  { Write-Host "  [问题] $T" -ForegroundColor Red }
function Write-Warn3([string]$T){ Write-Host "  [注意] $T" -ForegroundColor Yellow }

# ---- 没指定就挑最新的一份 ----
if (-not $Hap) {
    $dir = Join-Path $Root 'entry\build\default\outputs\default'
    $cand = @(Get-ChildItem -Path $dir -Filter *.hap -File -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending)
    if ($cand.Count -eq 0) { Write-Bad "在 $dir 下没找到 .hap，请用 -Hap 指定"; exit 1 }
    $Hap = $cand[0].FullName
}
if (-not (Test-Path -LiteralPath $Hap)) { Write-Bad "找不到文件：$Hap"; exit 1 }
$Hap = (Resolve-Path -LiteralPath $Hap).Path

# ---- 读字节 + 定位中央目录 ----
$b   = [IO.File]::ReadAllBytes($Hap)
$len = $b.Length
$eocd = -1
for ($i = $len - 22; $i -ge 0; $i--) {
    if ($b[$i] -eq 0x50 -and $b[$i+1] -eq 0x4B -and $b[$i+2] -eq 0x05 -and $b[$i+3] -eq 0x06) { $eocd = $i; break }
}
if ($eocd -lt 0) { Write-Bad "不是有效的 ZIP/HAP（找不到 EOCD）"; exit 1 }
$cdOff = [BitConverter]::ToUInt32($b, $eocd + 16)

# ---- 走本地文件头，找本地数据结束位置 ----
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
$sigSize = $cdOff - $off

Write-Step "1. 基本信息"
Write-Host ("  文件       : {0}" -f $Hap)
Write-Host ("  大小       : {0:N0} 字节" -f $len)
Write-Host ("  本地数据止 : {0:N0}" -f $off)
Write-Host ("  中央目录起 : {0:N0}" -f $cdOff)

Write-Step "2. 签名块"
if ($sigSize -le 0) {
    Write-Bad "没有签名块 —— 这份包【装不上手机】"
    Write-Host "  检查 build-profile.json5：" -ForegroundColor Yellow
    Write-Host "    - app.signingConfigs 里要有 name 为 default 的配置"
    Write-Host "    - app.products[].signingConfig 必须写成 `"default`"（最容易漏这一条）"
    exit 2
}
Write-Ok ("有签名块，{0:N0} 字节" -f $sigSize)

# ---- 从签名块里取 provision profile ----
$start = [Math]::Max(0, $off - 65536)
$region = [Text.Encoding]::GetEncoding(28591).GetString($b, $start, $cdOff - $start)
$i = $region.IndexOf('{"version-name"')
if ($i -lt 0) {
    Write-Warn3 "签名块里没找到 provision profile（可能是别的格式），只能确认「已签名」"
    exit 0
}
$depth = 0; $j = $i; $inStr = $false; $esc = $false
while ($j -lt $region.Length) {
    $c = $region[$j]
    if ($inStr) {
        if ($esc) { $esc = $false } elseif ($c -eq '\') { $esc = $true } elseif ($c -eq '"') { $inStr = $false }
    } else {
        if ($c -eq '"') { $inStr = $true }
        elseif ($c -eq '{') { $depth++ }
        elseif ($c -eq '}') { $depth--; if ($depth -eq 0) { break } }
    }
    $j++
}
$prof = $region.Substring($i, $j - $i + 1) | ConvertFrom-Json

Write-Step "3. Provision Profile"
$profType  = [string]$prof.type
$distType  = [string]$prof.'app-distribution-type'
$bundle    = [string]$prof.'bundle-info'.'bundle-name'
$nb = [DateTimeOffset]::FromUnixTimeSeconds([long]$prof.validity.'not-before').LocalDateTime
$na = [DateTimeOffset]::FromUnixTimeSeconds([long]$prof.validity.'not-after').LocalDateTime

Write-Host ("  profile 类型        : {0}" -f $profType)
Write-Host ("  分发类型            : {0}" -f $distType)
Write-Host ("  bundle-name         : {0}" -f $bundle)
Write-Host ("  developer-id        : {0}" -f $prof.'bundle-info'.'developer-id')
Write-Host ("  issuer              : {0}" -f $prof.issuer)
Write-Host ("  有效期              : {0:yyyy-MM-dd} ~ {1:yyyy-MM-dd}" -f $nb, $na)

$hasDebugInfo = $null -ne $prof.'debug-info'
if ($hasDebugInfo) {
    $ids = @($prof.'debug-info'.'device-ids')
    Write-Warn3 ("这是【调试 Profile】，带设备白名单（{0} 台）—— 只能装在名单里的设备上" -f $ids.Count)
    foreach ($id in $ids) { Write-Host ("            {0}" -f $id) }
} else {
    Write-Ok "没有设备白名单（发布 Profile）—— 任何设备都能装"
}

# ---- 开发者证书身份 ----
Write-Step "4. 开发者证书"
$certPem = [string]$prof.'bundle-info'.'development-certificate'
$certKind = 'development-certificate（调试）'
if (-not $certPem) {
    $certPem = [string]$prof.'bundle-info'.'distribution-certificate'
    $certKind = 'distribution-certificate（发布）'
}
if ($certPem -match 'BEGIN CERTIFICATE') {
    Write-Host ("  字段   : {0}" -f $certKind)
    # 只取第一段（可能是多级链，整体 decode 会失败）
    $mCert = [regex]::Match($certPem, '(?s)-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----')
    try {
        $der  = [Convert]::FromBase64String(($mCert.Groups[1].Value -replace '\s', ''))
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @(, $der)
        Write-Host ("  主体   : {0}" -f $cert.Subject)
        Write-Host ("  颁发者 : {0}" -f $cert.Issuer)
        Write-Host ("  有效期 : {0:yyyy-MM-dd} ~ {1:yyyy-MM-dd}" -f $cert.NotBefore, $cert.NotAfter)
    } catch {
        Write-Warn3 ("证书解析失败：{0}" -f $_.Exception.Message)
    }
} else {
    Write-Warn3 "profile 里既没有 development-certificate 也没有 distribution-certificate"
}

# ---- 和本工程 bundleName 对比 ----
Write-Step "5. 和本工程是否同一个应用"
$appJson = Join-Path $Root 'AppScope\app.json5'
if (Test-Path -LiteralPath $appJson) {
    $m = [regex]::Match([IO.File]::ReadAllText($appJson), '"bundleName"\s*:\s*"([^"]+)"')
    if ($m.Success) {
        $local = $m.Groups[1].Value
        Write-Host ("  本工程 bundleName : {0}" -f $local)
        Write-Host ("  profile bundleName: {0}" -f $bundle)
        if ($local -eq $bundle) { Write-Ok "一致 —— 是同一个应用，能覆盖安装" }
        else { Write-Bad "不一致！这份包会装成另一个 App" }
    }
} else {
    Write-Warn3 "找不到 AppScope\app.json5，跳过对比"
}

# ---- 最终结论 ----
Write-Step "结论"
if ($hasDebugInfo) {
    Write-Host "  ⚠️ 调试签名 —— 只能装到 Profile 里登记过的设备" -ForegroundColor Yellow
    Write-Host "     你本人的手机可以装；同学的手机装不上，除非把他的 UDID 也登记进去并重新签名"
    Write-Host "     另外：手机若开着【纯净模式】，即使是调试签名也可能被拒（code:9568322）"
} elseif ($profType -eq 'release' -and $distType -eq 'app_gallery' -and -not $hasDebugInfo) {
    Write-Host "  ✅ 发布签名，无设备限制 —— 【可以发给同学装】" -ForegroundColor Green
    Write-Host "     同学端：开开发者模式 + USB 调试，然后 hdc install <这份.hap>"
    if ([DateTime]::Now -gt $na) { Write-Bad "但 Profile 已过期（{0:yyyy-MM-dd}），需要重新申请" -f $na }
    elseif (($na - [DateTime]::Now).TotalDays -lt 30) { Write-Warn3 ("Profile 还有 {0:N0} 天过期" -f ($na - [DateTime]::Now).TotalDays) }
} else {
    Write-Host ("  ⚠️ 已签名，但分发类型是 {0}，请自行确认其安装范围" -f $distType) -ForegroundColor Yellow
}
