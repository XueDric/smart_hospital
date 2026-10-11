# 生成带 SAN 的自签 TLS 证书（智慧医院服务端）
#
# ── 为什么必须带 SAN ───────────────────────────────────────────────────────
# **现代 TLS 客户端完全忽略 CN（Common Name），只看 subjectAltName。**
# 搬迁前踩过这个坑：证书 SAN 只写 127.0.0.1/localhost，而联调用的是**局域网 IP**，
# 于是 `tls-check` 的 SAN 断言必失败 —— 那不是 TLS 实现的问题，是证书签得不够。
# 所以本脚本默认把 **127.0.0.1 / ::1 / localhost / 本机所有 IPv4** 都写进 SAN。
#
# ── 为什么不用 openssl ────────────────────────────────────────────────────
# 本机**没有 openssl.exe**（PATH 与 Git 目录里都没有，只有运行时 DLL）。
# 所以用 .NET 的 CertificateRequest 原生生成 —— 它支持 SubjectAlternativeNameBuilder，
# 能签出与 openssl 等价（含 SAN）的证书。
#
# ── 产物 ──────────────────────────────────────────────────────────────────
#   server\certs\cert.pem   证书（PEM）
#   server\certs\key.pem    私钥（PEM）
# ⚠ **两者都不入库**（见 .gitignore）：私钥入库等于泄露。
#   搬迁前就是因此把 certs/ 整体忽略的。
#
# 用法：
#   .\new-tls-cert.ps1                          # 自动收集本机 IP
#   .\new-tls-cert.ps1 -ExtraDns "hospital.local" -ExtraIp "10.0.0.5"
#   .\new-tls-cert.ps1 -Days 3650 -Force

param(
    [string]$OutDir = "",
    [string[]]$ExtraDns = @(),
    [string[]]$ExtraIp = @(),
    [int]$Days = 825,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
if ([string]::IsNullOrEmpty($OutDir)) { $OutDir = Join-Path $root "certs" }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$certPath = Join-Path $OutDir "cert.pem"
$keyPath  = Join-Path $OutDir "key.pem"

if ((Test-Path $certPath) -and -not $Force) {
    Write-Host "[cert] 已存在：$certPath"
    Write-Host "[cert] 要重新生成请加 -Force"
    exit 0
}

# ── 收集 SAN ───────────────────────────────────────────────────────────────
# DNS：localhost 必带；再按需加 -ExtraDns
$dnsNames = New-Object System.Collections.ArrayList
[void]$dnsNames.Add("localhost")
foreach ($d in $ExtraDns) { if ($d) { [void]$dnsNames.Add($d) } }

# IP：回环 + 本机所有 IPv4（含 ::1）+ -ExtraIp
$ipAddresses = New-Object System.Collections.ArrayList
[void]$ipAddresses.Add([System.Net.IPAddress]::Loopback)          # 127.0.0.1
[void]$ipAddresses.Add([System.Net.IPAddress]::IPv6Loopback)      # ::1
$localIps = @()
try {
    $localIps = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object { $_.IPAddress -notmatch '^127\.' } |
                Select-Object -ExpandProperty IPAddress -Unique
} catch {
    # 退路：用 DNS 反查本机名解析出的地址
    try { $localIps = [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
          Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
          ForEach-Object { $_.IPAddressToString } } catch { $localIps = @() }
}
foreach ($ip in $localIps) {
    $parsed = $null
    if ([System.Net.IPAddress]::TryParse($ip, [ref]$parsed)) { [void]$ipAddresses.Add($parsed) }
}
foreach ($ip in $ExtraIp) {
    $parsed = $null
    if ([System.Net.IPAddress]::TryParse($ip, [ref]$parsed)) { [void]$ipAddresses.Add($parsed) }
    else { Write-Warning "[cert] -ExtraIp '$ip' 不是合法 IP，已忽略" }
}

# ⚠ 去重但**保序**：不能直接把 ArrayList 丢给 HashSet 后乱序输出，
#   否则输出不可复现（同样的输入两次得到不同 SAN 顺序）。
$dnsFinal = New-Object System.Collections.ArrayList
foreach ($d in $dnsNames) { if (-not $dnsFinal.Contains($d)) { [void]$dnsFinal.Add($d) } }
$ipFinal = New-Object System.Collections.ArrayList
foreach ($i in $ipAddresses) { if (-not $ipFinal.Contains($i)) { [void]$ipFinal.Add($i) } }

Write-Host "[cert] DNS SAN : $($dnsFinal -join ', ')"
Write-Host "[cert] IP  SAN : $(($ipFinal | ForEach-Object { $_.ToString() }) -join ', ')"

# ── 生成 RSA 私钥与自签证书请求 ────────────────────────────────────────────
$rsa = [System.Security.Cryptography.RSA]::Create(2048)

$dn = New-Object System.Security.Cryptography.X509Certificates.X500DistinguishedName(
        "CN=smart-hospital-server, O=Smart Hospital (self-signed)")
$req = New-Object System.Security.Cryptography.X509Certificates.CertificateRequest(
        $dn, $rsa,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)

$san = New-Object System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder
foreach ($d in $dnsFinal) { $san.AddDnsName($d) }
foreach ($i in $ipFinal)  { $san.AddIpAddress($i) }
$req.CertificateExtensions.Add($san.Build())

# 基本约束。
# ⚠⚠ 这里必须是 **CA:TRUE** —— 是实测出来的，不是照抄：
#   自签证书要能作为**它自己的信任锚**通过客户端校验，Schannel（Windows TLS 栈，
#   Windows 上的 curl 默认就用它）要求该证书**可作 CA**。
#   第一版写的是 CA:FALSE，实测结果：
#     curl --cacert cert.pem https://127.0.0.1:8443/health
#     → `schannel: error 0x00000010`，连接被拒；
#     而同一时刻 `curl -k` 返回 200 ⇒ 握手本身没问题，就是校验不过。
#   改成 CA:TRUE 后 --cacert 通过。
#   安全性说明：**没有变差** —— 持有这把私钥的人本来就能签发任意证书，
#   CA:FALSE 拦不住任何东西；真正的信任边界是"客户端有没有把它放进信任库"。
$req.CertificateExtensions.Add(
    (New-Object System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension($true, $false, 0, $true)))
# 用途：服务器认证 + 数字签名
# ⚠ 位或必须**先算好再传**：写成 `New-Object ... (A -bor B, $true)` 时，
#   PowerShell 会把 `-bor` 当成 New-Object 自己的参数名，报
#   「X509KeyUsageFlags 不包含名为 op_BitwiseOr 的方法」（实测踩到）。
$kuFlags = [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature -bor
           [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyEncipherment
$ku = New-Object System.Security.Cryptography.X509Certificates.X509KeyUsageExtension($kuFlags, $true)
$req.CertificateExtensions.Add($ku)
$eku = New-Object System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension(
        (New-Object System.Security.Cryptography.OidCollection), $true)
$eku.EnhancedKeyUsages.Add((New-Object System.Security.Cryptography.Oid("1.3.6.1.5.5.7.3.1")))  # serverAuth
$req.CertificateExtensions.Add($eku)

$notBefore = [DateTime]::UtcNow.AddDays(-1)      # 留 1 天余量，避免"刚签就 not yet valid"
$notAfter  = [DateTime]::UtcNow.AddDays($Days)
$cert = $req.CreateSelfSigned($notBefore, $notAfter)

# ── 导出 PEM ───────────────────────────────────────────────────────────────
# ⚠ .NET Framework 的 PowerShell 5.1 **没有** ExportCertificatePem / ExportPkcs8PrivateKeyPem
#   （那是 .NET 7+ 的 API），所以这里手工做 base64 + 64 列折行的 PEM 编码。
function ConvertTo-Pem([byte[]]$der, [string]$label) {
    $b64 = [Convert]::ToBase64String($der)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("-----BEGIN $label-----")
    for ($i = 0; $i -lt $b64.Length; $i += 64) {
        $len = [Math]::Min(64, $b64.Length - $i)
        [void]$sb.AppendLine($b64.Substring($i, $len))
    }
    [void]$sb.AppendLine("-----END $label-----")
    return $sb.ToString()
}

# 证书 → PEM（DER 用 Export(X509ContentType.Cert) 拿）
$certPem = ConvertTo-Pem ($cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)) "CERTIFICATE"

# ── 私钥 → PKCS#1 PEM（手工构造 DER）────────────────────────────────────────
# ⚠ 为什么要手工做：**PowerShell 5.1 跑在 .NET Framework 上**，那个版本
#   · 没有 .NET 7+ 的 `ExportPkcs8PrivateKeyPem()` / `ExportRSAPrivateKey()`；
#   · RSA 实例是 `RSACng`，只有 `ExportParameters()`。
#   实测报「RSACng 不包含名为 ExportRSAPrivateKey 的方法」。
#   所以这里按 RFC 8017 A.1.2 手工拼 RSAPrivateKey 的 DER：
#     SEQUENCE { version INTEGER(0), n, e, d, p, q, dp, dq, qinv }  ← 全 INTEGER
#   用 PKCS#1（"BEGIN RSA PRIVATE KEY"）而不是 PKCS#8：
#   框架走 OpenSSL 的 RSAPrivateKey.decodeFromPem，PKCS#1 是它最直接的输入形态。
function ConvertTo-DerLength([int]$n) {
    if ($n -lt 0x80) { return ,([byte[]]@($n)) }
    if ($n -le 0xFF) { return ,([byte[]]@(0x81, $n)) }
    if ($n -le 0xFFFF) { return ,([byte[]]@(0x82, [byte](($n -shr 8) -band 0xFF), [byte]($n -band 0xFF))) }
    return ,([byte[]]@(0x83, [byte](($n -shr 16) -band 0xFF),
                       [byte](($n -shr 8) -band 0xFF), [byte]($n -band 0xFF)))
}
function ConvertTo-DerInteger([byte[]]$v) {
    # 去掉前导 0（保留至少 1 字节）
    $i = 0
    while ($i -lt $v.Length - 1 -and $v[$i] -eq 0) { $i++ }
    $body = $v[$i..($v.Length - 1)]
    # ⚠ INTEGER 是**有符号**的：最高位为 1 时必须补一个 0x00 前缀，
    #   否则 OpenSSL 会把它读成负数而拒绝整个私钥。
    if (($body[0] -band 0x80) -ne 0) { $body = ,([byte]0) + $body }
    return ,([byte[]]@(0x02) + (ConvertTo-DerLength $body.Length) + $body)
}
function ConvertTo-DerSequence([byte[][]]$parts) {
    $inner = New-Object System.Collections.Generic.List[byte]
    foreach ($p in $parts) { foreach ($b in $p) { $inner.Add($b) } }
    $innerArr = $inner.ToArray()
    return ,([byte[]]@(0x30) + (ConvertTo-DerLength $innerArr.Length) + $innerArr)
}

$p8 = $rsa.ExportParameters($true)   # includePrivateParameters = true
$pkcs1 = ConvertTo-DerSequence @(
    (ConvertTo-DerInteger ([byte[]]@(0))),   # version = 0（双素数 RSA）
    (ConvertTo-DerInteger $p8.Modulus),
    (ConvertTo-DerInteger $p8.Exponent),
    (ConvertTo-DerInteger $p8.D),
    (ConvertTo-DerInteger $p8.P),
    (ConvertTo-DerInteger $p8.Q),
    (ConvertTo-DerInteger $p8.DP),
    (ConvertTo-DerInteger $p8.DQ),
    (ConvertTo-DerInteger $p8.InverseQ)
)
$keyPem = ConvertTo-Pem $pkcs1 "RSA PRIVATE KEY"

# 换行统一成 CRLF 之外的形式无所谓（PEM 解析器都容忍），但**必须以换行结尾**
[System.IO.File]::WriteAllText($certPath, $certPem, (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText($keyPath,  $keyPem,  (New-Object System.Text.UTF8Encoding($false)))

$rsa.Dispose()

# ── 自检：把刚写的文件读回来，确认 SAN 与有效期真的对 ────────────────────────
Write-Host ""
Write-Host "[cert] 自检（重新读回文件校验）"
$reread = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($certPath)
Write-Host "  主体    : $($reread.Subject)"
Write-Host "  有效期  : $($reread.NotBefore.ToLocalTime().ToString('yyyy-MM-dd')) → $($reread.NotAfter.ToLocalTime().ToString('yyyy-MM-dd'))"

$sanExt = $reread.Extensions | Where-Object { $_.Oid.Value -eq "2.5.29.17" }
if (-not $sanExt) {
    Write-Warning "[cert] ⚠ 证书里没有 SAN 扩展 —— 现代客户端会拒绝它"
    exit 1
}

# ⚠ 手工解析 SAN 的 ASN.1：
#   本 PowerShell 是 .NET Framework，**没有** .NET 7+ 的
#   `X509SubjectAlternativeNameExtension`（实测报"找不到类型"），
#   而 `Format($false)` 只给出缩略文本（"DNS Name=…"之类）不足以断言"IP SAN 正确"。
#   SAN 的 GeneralNames 结构简单，直接按 tag 解就够了：
#     SEQUENCE { [2] dNSName IA5String | [7] iPAddress OCTET STRING(4|16) ... }
function Get-SanEntries([System.Security.Cryptography.X509Certificates.X509Extension]$ext) {
    $b = $ext.RawData
    $out = New-Object System.Collections.ArrayList
    $i = 0
    # 外层 SEQUENCE
    if ($b[$i] -ne 0x30) { return $out }
    $i++
    $len = $b[$i]; $i++
    if ($len -band 0x80) { $n = $len -band 0x7F; $len = 0; for ($k=0;$k -lt $n;$k++){ $len = ($len -shl 8) -bor $b[$i]; $i++ } }
    $end = $i + $len
    while ($i -lt $end) {
        $tag = $b[$i]; $i++
        $l = $b[$i]; $i++
        if ($l -band 0x80) { $n = $l -band 0x7F; $l = 0; for ($k=0;$k -lt $n;$k++){ $l = ($l -shl 8) -bor $b[$i]; $i++ } }
        $val = $b[$i..($i + $l - 1)]; $i += $l
        if ($tag -eq 0x82) {
            [void]$out.Add([pscustomobject]@{ Kind = "DNS"; Value = [System.Text.Encoding]::ASCII.GetString($val) })
        } elseif ($tag -eq 0x87) {
            [void]$out.Add([pscustomobject]@{ Kind = "IP";  Value = (New-Object System.Net.IPAddress(,$val)).ToString() })
        } elseif ($tag -eq 0x81) {
            [void]$out.Add([pscustomobject]@{ Kind = "Email"; Value = [System.Text.Encoding]::ASCII.GetString($val) })
        } else {
            [void]$out.Add([pscustomobject]@{ Kind = ("tag0x{0:X2}" -f $tag); Value = ($val | ForEach-Object { $_.ToString("X2") }) -join '' })
        }
    }
    return $out
}

$sanEntries = Get-SanEntries $sanExt
Write-Host "  SAN     : $((($sanEntries | ForEach-Object { "$($_.Kind)=$($_.Value)" })) -join ', ')"

# ★ 硬断言：必须有 IP SAN，且含 127.0.0.1 —— 这是搬迁前踩过的坑
#   （只写 CN 或只写 localhost，现代客户端会全部拒绝）。
$sanIps = @($sanEntries | Where-Object { $_.Kind -eq "IP" } | ForEach-Object { $_.Value })
$sanDns = @($sanEntries | Where-Object { $_.Kind -eq "DNS" } | ForEach-Object { $_.Value })
if ($sanIps.Count -eq 0) {
    Write-Warning "[cert] ⚠ SAN 里没有任何 IP —— 用 IP 访问时会被拒"
    exit 1
}
if ($sanIps -notcontains "127.0.0.1") {
    Write-Warning "[cert] ⚠ SAN 里没有 127.0.0.1"
    exit 1
}
if ($sanDns -notcontains "localhost") {
    Write-Warning "[cert] ⚠ SAN 里没有 localhost"
    exit 1
}
Write-Host "  密钥文件: $(if (Test-Path $keyPath) { '存在（' + (Get-Item $keyPath).Length + ' 字节）' } else { '缺失！' })"
Write-Host "  证书含私钥: $($reread.HasPrivateKey) （应为 False —— 私钥在单独文件里）"
Write-Host ""
Write-Host "[cert] ✅ 已生成："
Write-Host "  证书 $certPath"
Write-Host "  私钥 $keyPath"

# ── 额外产出一份**纯 ASCII 路径**的运行用副本 ──────────────────────────────
# ★ 为什么必须这样：**本工具链的仓颉运行时无法接受含非 ASCII 的 argv** ——
#   在 main 之前就抛 `IllegalArgumentException: Invalid unicode scalar value`
#   （搬迁前的 API 踩坑记录 坑 6）。而本仓库路径含中文（`智能医院客户端`），
#   所以 `--tls-cert "<含中文的路径>"` **必然启动失败**（实测确认）。
#
#   试过的两条"看起来能绕"的路，实测**都不行**，记下来省下次时间：
#     · `--tls-files <配置文件>`：配置文件自己的路径也在中文目录下 → 同样炸；
#     · Windows 8.3 短名（`GetFile().ShortPath`）：本卷**禁用了 8.3 名**，
#       返回的还是长名 → 没用。
#
#   所以做法是：把证书/私钥**复制到一棵纯 ASCII 目录树**，配置文件也放那里、
#   内容里只有 ASCII 路径 → 命令行与文件内容**全 ASCII**。
#   位置选 %ProgramData%\smart-hospital\tls（机器级、适合服务），
#   并把该目录 ACL **收紧到 当前用户 + Administrators + SYSTEM**（私钥不外泄）。
$rtDir = Join-Path $env:ProgramData "smart-hospital\tls"
if (-not (Test-Path $rtDir)) { New-Item -ItemType Directory -Path $rtDir -Force | Out-Null }

$me = "$env:USERDOMAIN\$env:USERNAME"
$aclOk = $true
try {
    icacls $rtDir /inheritance:r /grant:r "${me}:(OI)(CI)F" "Administrators:(OI)(CI)F" "SYSTEM:(OI)(CI)F" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { $aclOk = $false }
} catch { $aclOk = $false }

$rtCert = Join-Path $rtDir "cert.pem"
$rtKey  = Join-Path $rtDir "key.pem"
$rtEnv  = Join-Path $rtDir "tls.env"
Copy-Item $certPath $rtCert -Force
Copy-Item $keyPath  $rtKey  -Force

$envLines = @(
    "# TLS 证书路径表（由 new-tls-cert.ps1 生成）",
    "# 内容与文件名**必须全是 ASCII** —— 仓颉 argv 不支持非 ASCII（见脚本注释）。",
    "# 用法：.\build\hospital-server.exe serve <dsn> --port 8443 --tls-files `"$rtEnv`"",
    "cert=$rtCert",
    "key=$rtKey"
)
[System.IO.File]::WriteAllText($rtEnv, ($envLines -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))

Write-Host "  运行副本（纯 ASCII，供命令行使用）："
Write-Host "    $rtCert"
Write-Host "    $rtKey"
Write-Host "    $rtEnv"
Write-Host "  运行副本权限: $(if ($aclOk) { '✅ 已收紧为 当前用户/Administrators/SYSTEM' } else { '⚠ icacls 未成功，请手工确认目录权限' })"
Write-Host "  路径是否全 ASCII: $(if (($rtEnv -notmatch '[^\x00-\x7F]')) { '✅ 是' } else { '❌ 否' })"
Write-Host ""
Write-Host "⚠ 都不入库（.gitignore 已排除）；私钥请勿外传。"
Write-Host ""
Write-Host "启动 HTTPS（用运行副本，绕开中文路径的 argv 限制）："
Write-Host "  .\build\hospital-server.exe serve <dsn> --port 8443 --tls-files `"$rtEnv`""
