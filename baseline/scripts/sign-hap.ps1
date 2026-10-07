<#
.SYNOPSIS
    用 hap-sign-tool 直接给 HAP 签名（绕开 DevEco / hvigor 的加密口令限制）。

.DESCRIPTION
    为什么需要它：
      hvigor 的签名配置要求口令是 DevEco 加密格式（长度 >= 32），手写不出来；
      而 hap-sign-tool 要的是【明文】口令。所以如果你自己持有 .p12 和口令，
      这条路可以不依赖 DevEco，且完全可脚本化。

    防呆（这两个坑都真实踩过）：
      1) 自动挑 .p7b 时【优先选调试 Profile】。发布 Profile（app_gallery）
         实测无法通过 hdc 侧载（code:9568322），选错等于白签。
      2) 校验 -Cert 的证书链里【是否含有】Profile 内嵌的那张证书。
         不配对时 hap-sign-tool 不会报错，但签出来的包一定会被设备拒绝。

.PARAMETER Hap
    要签名的 HAP（未签名）。默认取 entry\build\default\outputs\default 下
    最新的、文件名不含 signed 的 .hap。

.PARAMETER Cert
    应用证书 .cer（可以是含根证书的多级链）。不给则自动挑，并校验与 Profile 配对。

.PARAMETER Profile
    Provision Profile .p7b。不给则自动挑，【优先调试类型】。

.PARAMETER Keystore
    密钥库 .p12。默认 仓库根目录\Xue_Dric.p12。

.PARAMETER KeyAlias
    密钥别名。默认 xue。

.PARAMETER Password
    密钥库口令。不传则安全提示输入（不回显、不进历史记录）。

.PARAMETER KeyPassword
    密钥口令。默认与密钥库口令相同（DevEco 向导通常填成一样）。

.PARAMETER CompatibleVersion
    min compatible api version。本项目 compatibleSdkVersion 是 6.1.1(24)，默认 24。

.PARAMETER Install
    签完后直接 hdc install 到手机。

.PARAMETER SkipCertCheck
    跳过「证书与 Profile 配对」校验（只在确定自己在做什么时用）。

.PARAMETER AllowRelease
    允许在找不到调试 Profile 时用发布 Profile 签名（默认拒绝，因为签了也装不上）。

.EXAMPLE
    .\scripts\sign-hap.ps1
    .\scripts\sign-hap.ps1 -Cert .\tiaoshi.cer -Profile .\tiaoshiDebug.p7b -Install

.NOTES
    本文件必须以 UTF-8 with BOM 保存，否则 Windows PowerShell 5.1 会按 GBK 读。
#>
[CmdletBinding()]
param(
    [string]$Hap,
    [string]$Cert,
    [string]$Profile,
    [string]$Keystore,
    [string]$KeyAlias = 'xue',
    [string]$Password,
    [string]$KeyPassword,
    [int]$CompatibleVersion = 24,
    [string]$Out,
    [switch]$Install,
    [switch]$SkipCertCheck,
    [switch]$AllowRelease,
    [string]$DevEcoHome = 'D:\DevEco Studio'
)

$ErrorActionPreference = 'Stop'
# 本脚本位于仓库的 scripts\ 目录下：仓库根目录 = 脚本所在目录的父目录
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }
$Root = Split-Path $ScriptDir -Parent

function Write-Step([string]$T) { Write-Host "`n=== $T ===" -ForegroundColor Cyan }
function Write-Ok([string]$T)   { Write-Host "  [OK]   $T" -ForegroundColor Green }
function Write-Bad([string]$T)  { Write-Host "  [错误] $T" -ForegroundColor Red }
function Write-Warn3([string]$T){ Write-Host "  [注意] $T" -ForegroundColor Yellow }

$Jar  = Join-Path $DevEcoHome 'sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar'
$Java = Join-Path $DevEcoHome 'jbr\bin\java.exe'
$Hdc  = Join-Path $DevEcoHome 'sdk\default\openharmony\toolchains\hdc.exe'

# ---- 取 PEM 里第一段证书（Profile 内嵌的那张 = 叶子证书）----
function Get-PemCerts([string]$Text) {
    $out = @()
    foreach ($m in [regex]::Matches($Text, '(?s)-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----')) {
        try {
            $der = [Convert]::FromBase64String(($m.Groups[1].Value -replace '\s', ''))
            $c = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @(, $der)
            $out += $c
        } catch { }
    }
    return $out
}

# ---- 找签名材料：优先 signing\ 目录，其次仓库根目录（兼容旧位置）----
$SigningDir = Join-Path $Root 'signing'
function Get-MaterialFiles([string]$Filter) {
    $dirs = @()
    if (Test-Path -LiteralPath $SigningDir) { $dirs += $SigningDir }
    $dirs += $Root
    $out = @()
    foreach ($d in $dirs) {
        $out += @(Get-ChildItem -Path $d -Filter $Filter -File -ErrorAction SilentlyContinue)
    }
    return ($out | Sort-Object LastWriteTime -Descending)
}

# ---- 读一个 .p7b 的 profile 信息 ----
function Read-Profile([string]$Path) {
    $raw = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($Path))
    $i = $raw.IndexOf('{"version-name"')
    if ($i -lt 0) { return $null }
    $d=0;$j=$i;$s=$false;$e=$false
    while ($j -lt $raw.Length) { $ch=$raw[$j]
        if ($s) { if($e){$e=$false} elseif($ch -eq '\'){$e=$true} elseif($ch -eq '"'){$s=$false} }
        else { if($ch -eq '"'){$s=$true} elseif($ch -eq '{'){$d++} elseif($ch -eq '}'){$d--; if($d -eq 0){break}} }
        $j++ }
    $prof = $raw.Substring($i, $j-$i+1) | ConvertFrom-Json
    $devCount = 0
    if ($null -ne $prof.'debug-info' -and $null -ne $prof.'debug-info'.'device-ids') {
        $devCount = @($prof.'debug-info'.'device-ids').Count
    }
    $thumb = $null
    # 调试 Profile 用 development-certificate，发布 Profile 用 distribution-certificate
    $certPem = [string]$prof.'bundle-info'.'development-certificate'
    if (-not $certPem) { $certPem = [string]$prof.'bundle-info'.'distribution-certificate' }
    if ($certPem) {
        $cs = Get-PemCerts $certPem
        if ($cs.Count -gt 0) { $thumb = $cs[0].Thumbprint }
    }
    [PSCustomObject]@{
        Path    = $Path
        Name    = Split-Path $Path -Leaf
        Type    = [string]$prof.type
        Dist    = [string]$prof.'app-distribution-type'
        Bundle  = [string]$prof.'bundle-info'.'bundle-name'
        Devices = $devCount
        CertThumb = $thumb
    }
}

# ---------------------------------------------------------------- 1. 准备签名材料
Write-Step "1. 准备签名材料"

if (-not (Test-Path -LiteralPath $Jar))  { Write-Bad "找不到 hap-sign-tool.jar：$Jar"; exit 1 }
if (-not (Test-Path -LiteralPath $Java)) { Write-Bad "找不到 java：$Java"; exit 1 }

if (-not $Hap) {
    $dir = Join-Path $Root 'entry\build\default\outputs\default'
    $cand = @(Get-ChildItem -Path $dir -Filter *.hap -File -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending)
    $pick = $cand | Where-Object { $_.Name -notmatch 'signed' } | Select-Object -First 1
    if (-not $pick) { $pick = $cand | Select-Object -First 1 }
    if (-not $pick) { Write-Bad "在 $dir 下没找到 .hap，请用 -Hap 指定"; exit 1 }
    $Hap = $pick.FullName
}
if (-not (Test-Path -LiteralPath $Hap)) { Write-Bad "找不到 HAP：$Hap"; exit 1 }
$Hap = (Resolve-Path -LiteralPath $Hap).Path

# ---- 挑 Profile：优先调试 ----
if (-not $Profile) {
    $all = @(Get-MaterialFiles '*.p7b')
    if ($all.Count -eq 0) { Write-Bad "signing\ 和仓库根目录都没有 .p7b，请用 -Profile 指定"; exit 1 }

    $infos = @()
    foreach ($f in $all) { $inf = Read-Profile $f.FullName; if ($inf) { $infos += $inf } }

    Write-Host "  可用的 Profile："
    foreach ($inf in $infos) {
        $mark = ''
        if ($inf.Type -eq 'debug') { $mark = '  <-- 调试，可侧载' } else { $mark = '  (发布：无法侧载)' }
        Write-Host ("    {0,-44} type={1,-8} 设备数={2}{3}" -f $inf.Name, $inf.Type, $inf.Devices, $mark)
    }

    $dbg = $infos | Where-Object { $_.Type -eq 'debug' } | Select-Object -First 1
    if ($dbg) {
        $Profile = $dbg.Path
        Write-Ok ("选中调试 Profile：{0}（设备数 {1}）" -f $dbg.Name, $dbg.Devices)
    } else {
        Write-Bad "找不到【调试 Profile】—— 全是发布（app_gallery）类型。"
        Write-Host "  发布 Profile 签出来的包实测无法通过 hdc 侧载（code:9568322）。" -ForegroundColor Yellow
        Write-Host "  请到 AGC → Profile 管理 → 新增 Profile → 类型选【调试】→ 选应用 + 调试证书 + 勾设备，下载 .p7b。" -ForegroundColor Yellow
        if (-not $AllowRelease) { exit 1 }
        $Profile = $infos[0].Path
        Write-Warn3 "已按 -AllowRelease 继续使用发布 Profile（大概率装不上）"
    }
} else {
    $Profile = (Resolve-Path -LiteralPath $Profile).Path
}

$profInfo = Read-Profile $Profile
if (-not $profInfo) { Write-Bad "读不出 Profile 内容：$Profile"; exit 1 }

# ---- 挑证书 ----
if (-not $Cert) {
    $c = @(Get-MaterialFiles '*.cer')
    if ($c.Count -eq 0) { Write-Bad "signing\ 和仓库根目录都没有 .cer，请用 -Cert 指定"; exit 1 }
    $Cert = $c[0].FullName
}
$Cert = (Resolve-Path -LiteralPath $Cert).Path

if (-not $Keystore) {
    # 签名材料统一放在 signing\ 下；兼容旧位置（仓库根目录）
    $prefer = Join-Path $Root 'signing\Xue_Dric.p12'
    if (Test-Path -LiteralPath $prefer) { $Keystore = $prefer }
    else { $Keystore = Join-Path $Root 'Xue_Dric.p12' }
}
foreach ($f in @($Hap, $Cert, $Profile, $Keystore)) {
    if (-not (Test-Path -LiteralPath $f)) { Write-Bad "找不到文件：$f"; exit 1 }
}

Write-Host ("  HAP       : {0}" -f (Split-Path $Hap -Leaf))
Write-Host ("  证书      : {0}" -f (Split-Path $Cert -Leaf))
Write-Host ("  Profile   : {0}" -f $profInfo.Name)
Write-Host ("  密钥库    : {0}" -f (Split-Path $Keystore -Leaf))
Write-Host ("  别名      : {0}" -f $KeyAlias)
Write-Host ("  Profile   : type={0}  dist={1}  bundle={2}  设备数={3}" -f $profInfo.Type, $profInfo.Dist, $profInfo.Bundle, $profInfo.Devices)

if ($profInfo.Type -ne 'debug') {
    Write-Warn3 "这不是调试 Profile。发布 Profile（app_gallery）实测无法 hdc 侧载，签了也装不上。"
}

# ---- 证书与 Profile 配对校验 ----
if (-not $SkipCertCheck) {
    $certCerts = Get-PemCerts ([IO.File]::ReadAllText($Cert))
    if ($certCerts.Count -eq 0) {
        Write-Warn3 "读不出 $((Split-Path $Cert -Leaf)) 里的证书，跳过配对校验"
    } elseif (-not $profInfo.CertThumb) {
        Write-Warn3 "Profile 里没有内嵌证书，跳过配对校验"
    } else {
        $thumbs = $certCerts | ForEach-Object { $_.Thumbprint }
        if ($thumbs -contains $profInfo.CertThumb) {
            Write-Ok "证书与 Profile 配对（链里含 Profile 的证书）"
        } else {
            Write-Bad "证书与 Profile 【不配对】！"
            Write-Host ("    Profile 内嵌证书指纹: {0}" -f $profInfo.CertThumb)
            Write-Host ("    {0} 链里的指纹:" -f (Split-Path $Cert -Leaf))
            foreach ($t in $thumbs) { Write-Host ("      {0}" -f $t) }
            Write-Host "  → 用这对材料签出来的包一定会被设备拒绝。请换配套的 .cer 与 .p7b。" -ForegroundColor Yellow
            Write-Host "  → 确实要强行签，加 -SkipCertCheck。" -ForegroundColor Yellow
            exit 1
        }
    }
}

# ---------------------------------------------------------------- 2. 口令
Write-Step "2. 口令"

if (-not $Password) {
    $sec = Read-Host "请输入密钥库口令（不回显）" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try   { $Password = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
if (-not $KeyPassword) { $KeyPassword = $Password }
if (-not $Password) { Write-Warn3 "口令为空，将按空口令尝试" }

# ---------------------------------------------------------------- 3. 签名
Write-Step "3. 签名（hap-sign-tool sign-app）"

if (-not $Out) { $Out = Join-Path (Split-Path $Hap -Parent) 'entry-default-signed.hap' }
$Out = [IO.Path]::GetFullPath($Out)

$signArgs = @(
    '-jar', $Jar, 'sign-app',
    '-mode', 'localSign',
    '-keyAlias', $KeyAlias,
    '-appCertFile', $Cert,
    '-profileFile', $Profile,
    '-inFile', $Hap,
    '-outFile', $Out,
    '-signAlg', 'SHA256withECDSA',
    '-keystoreFile', $Keystore,
    '-keystorePwd', $Password,
    '-keyPwd', $KeyPassword,
    '-compatibleVersion', "$CompatibleVersion",
    '-signCode', '1'
)

# java 会把普通日志/错误写到 stderr。配合 2>&1 这些行会变成 ErrorRecord，
# 若此时 ErrorActionPreference 是 Stop，脚本会在调用中途直接中断 —— 必须临时降级。
$oldEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $log = & $Java @signArgs 2>&1 | Out-String
} finally {
    $ErrorActionPreference = $oldEap
}
$log -split "`r?`n" | Where-Object { $_ -match 'INFO -|ERROR' } | ForEach-Object { Write-Host ("  " + $_) }

if (-not (Test-Path -LiteralPath $Out)) {
    Write-Bad "签名失败，没有生成输出文件"
    if ($log -match 'password was incorrect') {
        Write-Host "  → 口令不对。密钥库口令和密钥口令都要给对（DevEco 向导里通常填成同一个）。" -ForegroundColor Yellow
    }
    if ($log -match 'Read zip file failed') {
        Write-Host "  → 输入 HAP 读不了，重新编译一次再签。" -ForegroundColor Yellow
    }
    exit 1
}

# ---------------------------------------------------------------- 4. 复核签名
Write-Step "4. 复核签名块"

$b = [IO.File]::ReadAllBytes($Out)
$len = $b.Length
$eocd = -1
for ($i = $len - 22; $i -ge 0; $i--) {
    if ($b[$i] -eq 0x50 -and $b[$i+1] -eq 0x4B -and $b[$i+2] -eq 0x05 -and $b[$i+3] -eq 0x06) { $eocd = $i; break }
}
$cdOff = [BitConverter]::ToUInt32($b, $eocd + 16)
$off = 0
while ($off + 30 -le $len -and
       $b[$off] -eq 0x50 -and $b[$off+1] -eq 0x4B -and
       $b[$off+2] -eq 0x03 -and $b[$off+3] -eq 0x04) {
    $cs = [BitConverter]::ToUInt32($b, $off + 18)
    $nl = [BitConverter]::ToUInt16($b, $off + 26)
    $el = [BitConverter]::ToUInt16($b, $off + 28)
    $next = $off + 30 + $nl + $el + $cs
    if ($next -le $off) { break }
    $off = $next
}

Write-Host ("  输出   : {0}" -f $Out)
Write-Host ("  大小   : {0:N0} 字节" -f $len)
if ($cdOff -gt $off) {
    Write-Ok ("签名块 {0:N0} 字节 —— 签名成功" -f ($cdOff - $off))
} else {
    Write-Bad "没有签名块，签名没生效"
    exit 1
}

$checker = Join-Path $ScriptDir 'check-hap-signature.ps1'
if (Test-Path -LiteralPath $checker) {
    Write-Host "`n  详细验签：" -ForegroundColor Cyan
    & powershell -NoProfile -ExecutionPolicy Bypass -File $checker -Hap $Out
}

# ---------------------------------------------------------------- 5. 安装
if ($Install) {
    Write-Step "5. 安装到手机"
    & $Hdc install $Out 2>&1 | ForEach-Object { Write-Host ("  " + $_) }
} else {
    Write-Host "`n  安装命令：" -ForegroundColor Cyan
    Write-Host ('    & "{0}" install "{1}"' -f $Hdc, $Out)
}
