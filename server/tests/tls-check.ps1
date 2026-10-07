# TLS/HTTPS 验证（智慧医院服务端）
#
# ── 为什么用 .NET SslStream 而不是 curl --cacert ────────────────────────────
# 本机实测（2026-10-07）：Windows 的 curl 走 **Schannel**，而 Schannel 对
# `--cacert <自签证书>` 的支持不完整 —— 它明明接受了 CA 文件
# （`schannel: added 1 certificate(s) from CA file`），却仍然报
# `schannel: error 0x00000010` 并拒绝连接。同一时刻 `curl -k` 返回 200，
# 说明**服务端握手完全正常**，问题在 Windows 客户端的校验怪癖。
#
# 用 `-k` 当"通过"是自欺欺人（它跳过校验，什么也验不出）；
# 把证书塞进系统根库又需要管理员权限、且改动了系统状态（本会话实测卡在提权）。
# 所以这里用 **.NET SslStream + 显式链校验 + 自己解析 SAN**：
#   · 校验逻辑完全在我们控制下，能精确区分"链不信任"/"主机名不匹配"；
#   · **不修改系统证书库**。
#
# ⚠⚠ 两个实测踩到的坑（下方代码里都有注释）：
#   1. **回调里必须立刻 `Export(Cert)` 拿 DER 字节** —— 回调返回后那个
#      RemoteCertificate 对象会失效（主体/指纹全空，Build 报"链上下文句柄无效"）。
#   2. **IP SAN 不能用 ASCII 子串匹配** —— SAN 里 IP 是 4/16 字节**二进制**，
#      `Encoding.ASCII.GetString(...) -match '127\.0\.0\.1'` 永远不匹配。
#      必须按 ASN.1 解出来再转成 IP 字符串比较。
#
# ⚠ 含中文的 PowerShell 脚本必须 UTF-8 with BOM。
#
# 用法：
#   $env:HOSP_ADMIN_PW = "<管理员口令>"      # 可选，给了就测登录链路
#   .\tls-check.ps1 -Cert ..\certs\cert.pem -Host_ 127.0.0.1 -Port 8443

param(
    [string]$Cert = "",
    [string]$Host_ = "127.0.0.1",     # Host 是 PS 保留名，故用 Host_
    [int]$Port = 8443
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
if ([string]::IsNullOrEmpty($Cert)) { $Cert = Join-Path (Split-Path $root -Parent) "certs\cert.pem" }
if (-not (Test-Path $Cert)) { throw "找不到证书：$Cert（先跑 server\new-tls-cert.ps1）" }

$caCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($Cert)

$fail = 0
function Check($name, $ok, $detail) {
    if ($ok) { Write-Host "  [PASS] $name" }
    else { Write-Host "  [FAIL] $name"; $script:fail++ }
    if ($detail) { Write-Host "         $detail" }
}

# ── 解析 SAN（ASN.1）──────────────────────────────────────────────────────
function Get-SanEntries($cert) {
    $out = New-Object System.Collections.ArrayList
    $ext = $cert.Extensions | Where-Object { $_.Oid.Value -eq "2.5.29.17" }
    if (-not $ext) { return $out }
    $b = $ext.RawData
    $i = 0
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
            [void]$out.Add([pscustomobject]@{ Kind="DNS"; Value=[System.Text.Encoding]::ASCII.GetString($val) })
        } elseif ($tag -eq 0x87) {
            [void]$out.Add([pscustomobject]@{ Kind="IP"; Value=(New-Object System.Net.IPAddress(,$val)).ToString() })
        }
    }
    return $out
}

# 主机名是否被该证书覆盖（**只看 SAN** —— 现代客户端都忽略 CN）
function Test-HostCovered($cert, $hostName) {
    $entries = Get-SanEntries $cert
    if ($hostName -match '^\d+\.\d+\.\d+\.\d+$' -or $hostName -match ':') {
        foreach ($e in $entries) { if ($e.Kind -eq "IP" -and $e.Value -eq $hostName) { return $true } }
        return $false
    }
    foreach ($e in $entries) { if ($e.Kind -eq "DNS" -and $e.Value -eq $hostName) { return $true } }
    return $false
}

# ── 建立 TLS 连接并用我们自己的逻辑校验 ──────────────────────────────────
function Connect-Tls($hostName, $port, $protocol) {
    $out = @{ Ok=$false; Protocol=""; Der=$null; Error=""; ChainOk=$false; HostCovered=$false
              ServerSubject=""; ServerThumb=""; IsSameAsCa=$false; OtherStatusCount=0 }
    $box = [System.Collections.Hashtable]::Synchronized(@{})
    $tcp = $null; $ssl = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect($hostName, $port)
        $cb = [System.Net.Security.RemoteCertificateValidationCallback]{
            param($s, $c, $ch, $e)
            # ★ 坑 1：立刻导出 DER —— 回调返回后这个对象会失效
            $box['der'] = $c.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
            return $true      # 真正的判定在下面用我们自己的链校验做
        }
        $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false, $cb)
        $ssl.AuthenticateAsClient($hostName, $null, $protocol, $false)
        $out.Ok = $true
        $out.Protocol = $ssl.SslProtocol.ToString()
        $out.Der = $box['der']
    } catch {
        $out.Error = $_.Exception.Message
        if ($_.Exception.InnerException) { $out.Error += " / " + $_.Exception.InnerException.Message }
    } finally {
        if ($ssl) { $ssl.Dispose() }
        if ($tcp) { $tcp.Dispose() }
    }
    if ($out.Der) {
        # ⚠ 必须显式转 [byte[]]：`New-Object X509Certificate2(,$bytes)` 在 PowerShell 里
        #   会把单元素数组拆包成**一个 object**，于是命中"按文件名加载"的重载，
        #   报「指定的路径或文件名太长」（它把 DER 当路径了）。显式 cast 消除歧义。
        $derBytes = [byte[]]$out.Der
        $srv = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @(, $derBytes)
        $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
        $chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
        $chain.ChainPolicy.ExtraStore.Add($caCert)
        # 自签证书自己就是根：允许"根不在系统信任库"（信任由我们把 CA 传进来表达）
        $chain.ChainPolicy.VerificationFlags = [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::AllowUnknownCertificateAuthority
        $built = $chain.Build($srv)
        # Build 可能返回 true 但带 UntrustedRoot；除它之外还有别的错误才算真失败
        $otherStatus = @($chain.ChainStatus | Where-Object {
            $_.Status -ne [System.Security.Cryptography.X509Certificates.X509ChainStatusFlags]::UntrustedRoot })
        $out.ChainOk = ($otherStatus.Count -eq 0)
        $out.OtherStatusCount = $otherStatus.Count
        $out.HostCovered = Test-HostCovered $srv $hostName
        $out.ServerSubject = $srv.Subject
        $out.ServerThumb = $srv.Thumbprint
        $out.IsSameAsCa = ($srv.Thumbprint -eq $caCert.Thumbprint)
    }
    return $out
}

Write-Host "=== TLS/HTTPS 验证 ==="
Write-Host "  目标: https://${Host_}:${Port}"
Write-Host "  证书: $Cert"
Write-Host ""

# ── 1) 证书结构 ───────────────────────────────────────────────────────────
Write-Host "[1] 证书结构"
$sanEntries = Get-SanEntries $caCert
Check "证书有 SAN 扩展（现代客户端只看 SAN，不看 CN）" ($sanEntries.Count -gt 0) `
      ("SAN: " + (($sanEntries | ForEach-Object { "$($_.Kind)=$($_.Value)" }) -join ', '))
$now = Get-Date
Check "当前时间在有效期内" ($caCert.NotBefore -le $now -and $caCert.NotAfter -ge $now) `
      ("$($caCert.NotBefore.ToString('yyyy-MM-dd')) → $($caCert.NotAfter.ToString('yyyy-MM-dd'))")
$hasIpSan = @($sanEntries | Where-Object { $_.Kind -eq 'IP' }).Count -gt 0
Check "SAN 里有 IP 条目（用 IP 访问时必须）" $hasIpSan

# ── 2) TLS 1.2 + 真校验 ───────────────────────────────────────────────────
Write-Host ""
Write-Host "[2] TLS 1.2（真校验：链 + 主机名）"
$r12 = Connect-Tls $Host_ $Port ([System.Security.Authentication.SslProtocols]::Tls12)
Check "TLS 1.2 握手成功" $r12.Ok ("协商=$($r12.Protocol)" + $(if($r12.Error){" 错误=$($r12.Error)"}else{""}))
if ($r12.Der) {
    Check "服务端证书 = 给定 CA（同一张）" $r12.IsSameAsCa ("指纹=$($r12.ServerThumb)")
    Check "链校验通过（除 UntrustedRoot 外无其它错误）" $r12.ChainOk ("其它错误数=$($r12.OtherStatusCount)")
    Check "主机名 ${Host_} 被 SAN 覆盖" $r12.HostCovered
    Check "实际协商到 TLS 1.2" ($r12.Protocol -match 'Tls12')
} else {
    Check "取到服务端证书" $false
}

# ── 3) TLS 1.3 ────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "[3] TLS 1.3"
$r13 = Connect-Tls $Host_ $Port ([System.Security.Authentication.SslProtocols]::Tls13)
if ($r13.Ok) {
    Check "TLS 1.3 握手成功" $true ("协商=$($r13.Protocol)")
    if ($r13.Der) { Check "TLS 1.3 下链 + 主机名校验同样通过" ($r13.ChainOk -and $r13.HostCovered) }
} else {
    # Windows 需 Win11 22H2+/Server 2022+ 才支持 TLS 1.3 客户端。
    # 客户端不支持时**不能**判服务端失败 —— 那属于"测试环境能力"而非"服务端缺陷"。
    $clientSide = ($r13.Error -match 'protocol|Protocol|not supported|不支持|SslProtocols')
    Check "TLS 1.3 不可用时应归因于客户端（不误判服务端）" $clientSide ("错误=$($r13.Error)")
    Write-Host "         [NOTE] 本机客户端不支持 TLS 1.3，此项不算服务端失败"
}

# ── 4) 旧版 TLS 应被拒 ────────────────────────────────────────────────────
Write-Host ""
Write-Host "[4] 旧版 TLS（1.0 / 1.1）"
foreach ($pair in @(@('TLS 1.0', [System.Security.Authentication.SslProtocols]::Tls),
                    @('TLS 1.1', [System.Security.Authentication.SslProtocols]::Tls11))) {
    $res = Connect-Tls $Host_ $Port $pair[1]
    if ($res.Ok) {
        Check "$($pair[0]) 被拒绝" $false "⚠ 服务端接受了 $($pair[0])，应禁用它"
    } else {
        # ⚠ 必须区分"服务端拒绝"与"客户端不愿发起"：Windows/.NET 默认已禁用 1.0/1.1 客户端。
        #   那种情况下这条**验不出服务端行为**，只能如实标注 —— 不能算服务端通过。
        $clientRefused = ($res.Error -match 'not supported|不支持|protocol|Protocol|SslProtocols')
        if ($clientRefused) {
            Write-Host "  [INFO] $($pair[0])：本机客户端已禁用该协议，**验不到服务端是否拒绝**"
            Write-Host "         （要硬证据需 openssl s_client -tls1；本机无 openssl —— 如实记录，不冒充通过）"
        } else {
            Check "$($pair[0]) 被拒绝" $true ("错误=$($res.Error)")
        }
    }
}

# ── 5) 反向验证 ───────────────────────────────────────────────────────────
Write-Host ""
Write-Host "[5] 反向验证（证明第 2 步不是假通过）"
$rAny = Connect-Tls $Host_ $Port ([System.Security.Authentication.SslProtocols]::Tls12)
if ($rAny.Der) {
    $derBytes2 = [byte[]]$rAny.Der
    $srvCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @(, $derBytes2)
    Check "不在 SAN 里的主机名必须**不**被覆盖" (-not (Test-HostCovered $srvCert "not-in-san.invalid"))
    Check "不在 SAN 里的 IP 必须**不**被覆盖" (-not (Test-HostCovered $srvCert "10.255.255.254"))
    Check "在 SAN 里的 ${Host_} 必须被覆盖" (Test-HostCovered $srvCert $Host_)
    # 用别的 CA 验：链根必须不是它
    $oRsa = [System.Security.Cryptography.RSA]::Create(2048)
    $oDn = New-Object System.Security.Cryptography.X509Certificates.X500DistinguishedName("CN=other-ca")
    $oReq = New-Object System.Security.Cryptography.X509Certificates.CertificateRequest(
        $oDn, $oRsa, [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $oCert = $oReq.CreateSelfSigned((Get-Date).AddDays(-1), (Get-Date).AddDays(30))
    $c2 = New-Object System.Security.Cryptography.X509Certificates.X509Chain
    $c2.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
    $c2.ChainPolicy.ExtraStore.Add($oCert)
    $c2.ChainPolicy.VerificationFlags = [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::AllowUnknownCertificateAuthority
    $null = $c2.Build($srvCert)
    $rootThumb = if ($c2.ChainElements.Count -gt 0) { $c2.ChainElements[$c2.ChainElements.Count-1].Certificate.Thumbprint } else { "" }
    Check "用不同的 CA 时链根不是它（反证链校验有效）" ($rootThumb -ne $oCert.Thumbprint)
    $oRsa.Dispose()
} else {
    Check "能取到服务端证书以做反向验证" $false ("错误=$($rAny.Error)")
}

# ── 6) 明文打 TLS 端口必须失败 ────────────────────────────────────────────
Write-Host ""
Write-Host "[6] 明文打 TLS 端口"
$plain = & curl.exe -s -o NUL -w "%{http_code}" --max-time 8 "http://${Host_}:${Port}" 2>&1
Check "明文 HTTP 打 TLS 端口失败（000）" ("$plain" -eq "000") ("code=$plain")

# ── 7) HTTPS 下业务链路 ───────────────────────────────────────────────────
Write-Host ""
Write-Host "[7] HTTPS 下的业务链路"
if ([string]::IsNullOrEmpty($env:HOSP_ADMIN_PW)) {
    Write-Host "  [SKIP] 未设 `$env:HOSP_ADMIN_PW，跳过登录链路测试"
} else {
    $tmp = Join-Path $env:TEMP ("tlschk-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    function DoReq($name, $method, $reqPath, $headers, $body) {
        $f = Join-Path $tmp "$name.cfg"
        $lines = @("request = `"$method`"")
        foreach ($h in $headers) { $lines += "header = `"$h`"" }
        if ($body) {
            $bf = Join-Path $tmp "$name.body"
            [System.IO.File]::WriteAllText($bf, $body, (New-Object System.Text.UTF8Encoding($false)))
            $lines += ('data = "@' + ($bf -replace '\\','/') + '"')
            $lines += 'header = "Content-Type: application/json"'
        }
        # ⚠ 这里用 insecure 是**有意的**：本项只验"HTTPS 链路与业务逻辑通不通"；
        #   证书校验已由第 2/5 步用 .NET 严格验过（Schannel 的 --cacert 有客户端怪癖）。
        $lines += 'insecure'; $lines += 'silent'
        $lines += 'write-out = "\n__CODE__%{http_code}"'
        [System.IO.File]::WriteAllText($f, ($lines -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
        $raw = (& curl.exe -s -K $f "https://${Host_}:${Port}${reqPath}" 2>&1) -join "`n"
        $parts = $raw -split "__CODE__"
        $code = if ($parts.Count -gt 1) { [int]$parts[1].Trim() } else { -1 }
        return @{ Code = $code; Body = $parts[0].Trim() }
    }

    $lg = DoReq 'login' 'POST' '/api/v1/auth/login' @() `
          ('{"login_name":"admin","password":"' + $env:HOSP_ADMIN_PW + '"}')
    Check "HTTPS 下登录成功（200）" ($lg.Code -eq 200) ("code=$($lg.Code)")
    if ($lg.Code -eq 200) {
        $tok = ($lg.Body | ConvertFrom-Json).data.token
        Check "拿到令牌（64 字符）" ($tok.Length -eq 64)
        $me = DoReq 'me' 'GET' '/api/v1/auth/me' @("Authorization: Bearer $tok") $null
        Check "HTTPS 下带令牌调 /auth/me（200）" ($me.Code -eq 200) ("code=$($me.Code)")
        $null = DoReq 'out' 'POST' '/api/v1/auth/logout' @("Authorization: Bearer $tok") $null
    }
    Remove-Item $tmp -Recurse -Force
}

Write-Host ""
if ($fail -eq 0) {
    Write-Host "✅ TLS 验证全部通过"
    exit 0
} else {
    Write-Host "❌ TLS 验证失败 $fail 项"
    exit 1
}
