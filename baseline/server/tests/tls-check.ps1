# 本机 TLS 验证（框架原生 TLS，不用 Nginx）
#
# 覆盖 ..\docs\deploy-windows-verify.md 的关卡 3、4 与 TLS 需求文档第 4 节的关键项：
#   1. 证书带 SAN，且 IP SAN 正确（现代客户端完全忽略 CN，只看 subjectAltName）
#   2. TLS 1.2 握手成功
#   3. TLS 1.3 握手成功
#   4. TLS 1.1 被服务端拒绝（alert 70）——必须加 @SECLEVEL=0，否则是客户端自己不肯发起
#   5. TLS 1.0 被服务端拒绝
#   6. 真实 HTTPS 请求 200，且做真证书校验（curl --cacert，不加 -k）
#   7. 用错误的 CA 必须校验失败（反证第 6 条不是假通过）
#   8. 错误 IP 的 SAN 校验必须失败（反证第 1 条不是假通过）
#   9. HTTPS 下接口可用（真登录 + /auth/me）
#  10. 明文访问 TLS 端口应当失败
#
# 为什么用 curl 而不是 PowerShell 的 Invoke-WebRequest：
#   本机实测 PS 5.1 的 Invoke-WebRequest 在这个自签 HTTPS 服务上会报
#   "基础连接已经关闭: 发送时发生错误"，而同一时刻 curl、openssl s_client、
#   .NET 的 HttpWebRequest 与原始 SslStream 全部正常（详见 API-NOTES）。
#   为避免把客户端怪癖误判成服务端缺陷，这里统一用 curl 与 openssl 作为独立客户端。
#
# 用法（Windows PowerShell 5.1 默认禁止跑脚本，必须带 Bypass）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\tls-check.ps1
#
# ⚠⚠ 新前提（2026-09-20 起）：**必须有一台可连的 MySQL / MariaDB**。
#   服务端持久化已整体换成 MySQL（路线 B，见 docs\club-server-mysql-assessment.md），
#   本脚本用**专用测试库 club_tls**（绝不碰 club_rbac 或任何真实业务库），
#   开头检测客户端与可连性，取不到 → 中文提示 + 判 FAIL + 非零退出。
#   连接参数默认 127.0.0.1:3307 / root / clubroot123，可用环境变量覆盖
#   （CLUB_MYSQL_HOST/PORT/USER/PASS/DB、CLUB_MYSQL_CLI、CLUB_MARIADB_HOME）；
#   细节见 tests\mysql-common.ps1 的文件头。

param(
    [int]$Port = 18443,
    [string]$Exe = "",
    [string]$CertDir = ""
)

# 本脚本大量调用 openssl / curl，它们会把手握信息写到 stderr。
# 若用 Stop，PowerShell 会把“原生命令写了 stderr”当成致命错误直接中断脚本。
# 所有判定都走显式的 Check()。
$ErrorActionPreference = "Continue"

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrEmpty($Exe)) { $Exe = Join-Path $root "build\club-server.exe" }
if ([string]::IsNullOrEmpty($CertDir)) { $CertDir = Join-Path $root "certs" }
$certPath = Join-Path $CertDir "cert.pem"
$keyPath = Join-Path $CertDir "key.pem"
$dataRel = "build\tls-data"          # 只剩审计日志（audit.log）用；业务数据在 MySQL 里
$dataAbs = Join-Path $root $dataRel
$logOut = Join-Path $root "build\tls-server.out.log"
$logErr = Join-Path $root "build\tls-server.err.log"

# 专用测试库 + 连接检测（取不到就 FAIL 退出）
. (Join-Path $PSScriptRoot "mysql-common.ps1")
$my = Initialize-MySqlTestEnv -DefaultDb "club_tls"

$openssl = "D:\Program Files\Git\usr\bin\openssl.exe"
if (-not (Test-Path $openssl)) { $openssl = (Get-Command openssl -ErrorAction SilentlyContinue).Source }
$curl = (Get-Command curl.exe -ErrorAction SilentlyContinue).Source
if (-not $curl) { $curl = "C:\Windows\System32\curl.exe" }

if (-not $openssl) { throw "找不到 openssl" }
if (-not (Test-Path $curl)) { throw "找不到 curl.exe" }
if (-not (Test-Path $Exe)) { throw "找不到服务端可执行文件：$Exe" }
if (-not (Test-Path $certPath)) { throw "找不到证书：$certPath（先用 openssl 生成带 SAN 的自签证书）" }

$script:pass = 0
$script:fail = 0
$proc = $null

function Check([string]$name, [bool]$cond, [string]$extra = "") {
    if ($cond) {
        $script:pass++
        Write-Host ("  ok    " + $name)
    } else {
        $script:fail++
        Write-Host ("  FAIL  " + $name + "   " + $extra) -ForegroundColor Red
    }
}

# 跑一次 openssl s_client，返回合并后的文本输出
function SClient([string[]]$extraArgs, [string]$stdin = "") {
    $all = @("s_client", "-connect", "127.0.0.1:$Port") + $extraArgs
    return ($stdin | & $openssl @all 2>&1 | Out-String)
}

# 用 curl 发请求（带 --cacert 做真校验），返回 @{ code; body }
# 注意：函数名不能叫 Curl —— PowerShell 里 curl 是 Invoke-WebRequest 的内置别名，
# 而别名优先级高于函数，叫 Curl 会被悄悄换成 Invoke-WebRequest。
function CurlReq([string[]]$extraArgs) {
    $tmp = Join-Path $env:TEMP ("curlb_" + [guid]::NewGuid().ToString("N") + ".txt")
    $all = @("-s", "-o", $tmp, "-w", "%{http_code}", "--cacert", $certPath) + $extraArgs
    $code = (& $curl @all 2>&1 | Out-String).Trim()
    $body = ""
    if (Test-Path $tmp) {
        $body = [System.IO.File]::ReadAllText($tmp, [System.Text.Encoding]::UTF8)
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
    return @{ code = $code; body = $body }
}

Push-Location $root
try {
    Write-Host "=== 本机 TLS 验证 ==="
    Write-Host "可执行文件: $Exe"
    Write-Host "证书      : $certPath"
    Write-Host "端口      : $Port"
    Write-Host ""

    # ---------- 准备 ----------
    if (Test-Path $dataAbs) { Remove-Item -Recurse -Force $dataAbs }
    Remove-Item $logOut, $logErr -Force -ErrorAction SilentlyContinue
    Write-Host "[准备] 初始化测试数据（清空测试库 + init-admin）"
    Reset-ClubMySqlSchema $my.Db
    & $Exe init-admin 13800000000 password123 $my.Dsn --data-dir $dataRel | Out-Null
    Check "init-admin 成功" ($LASTEXITCODE -eq 0) "exit=$LASTEXITCODE"
    Check "会长已写进 MySQL" ((Invoke-ClubMySql "SELECT COUNT(*) FROM members WHERE role='president';" $my.Db).Trim() -eq '1')

    Write-Host ""
    Write-Host "[准备] 证书 SAN（现代客户端只看 SAN，完全忽略 CN）"
    $certText = (& $openssl x509 -in $certPath -noout -text 2>&1 | Out-String)
    Check "证书含 subjectAltName" ($certText -match "Subject Alternative Name")
    Check "SAN 含 IP:127.0.0.1" ($certText -match "IP Address:127\.0\.0\.1")

    $vOk = (& $openssl verify -CAfile $certPath -verify_ip 127.0.0.1 $certPath 2>&1 | Out-String)
    Check "IP SAN 校验通过（openssl verify -verify_ip）" ($vOk -match "OK") ($vOk -replace "`r?`n", " | ")
    $vBad = (& $openssl verify -CAfile $certPath -verify_ip 10.9.9.9 $certPath 2>&1 | Out-String)
    Check "错误 IP 必须校验失败（反证上一条）" (-not ($vBad -match ": OK")) ($vBad -replace "`r?`n", " | ")

    # ---------- 启动 HTTPS ----------
    Write-Host ""
    Write-Host "[启动] serve-tls :$Port"
    $proc = Start-Process -FilePath $Exe `
        -ArgumentList @("serve-tls", "$Port", $my.Dsn, "--data-dir", $dataRel, "--cert", "certs/cert.pem", "--key", "certs/key.pem") `
        -WorkingDirectory $root -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $logOut -RedirectStandardError $logErr

    $ready = $false
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 500
        if ($proc.HasExited) { break }
        $t = SClient @("-tls1_2", "-brief")
        if ($t -match "CONNECTION ESTABLISHED") { $ready = $true; break }
    }
    if (-not $ready) {
        if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
        $tail = ""
        if (Test-Path $logOut) { $tail = [System.IO.File]::ReadAllText($logOut, [System.Text.Encoding]::UTF8) }
        throw "HTTPS 服务未能在 :$Port 就绪。日志：$tail"
    }
    Check "HTTPS 服务已就绪" $true

    # ---------- 关卡 3：TLS 1.2 / 1.3 ----------
    Write-Host ""
    Write-Host "[关卡 3] TLS 1.2 / 1.3 握手应成功"
    $o12 = SClient @("-tls1_2", "-brief")
    Check "TLS 1.2 握手成功" ($o12 -match "Protocol version: TLSv1\.2") ($o12 -replace "`r?`n", " | ")
    $o13 = SClient @("-tls1_3", "-brief")
    Check "TLS 1.3 握手成功" ($o13 -match "Protocol version: TLSv1\.3") ($o13 -replace "`r?`n", " | ")

    # ---------- 关卡 4：TLS 1.0 / 1.1 必须被服务端拒绝 ----------
    Write-Host ""
    Write-Host "[关卡 4] TLS 1.0 / 1.1 必须被服务端拒绝"
    Write-Host "        （必须加 @SECLEVEL=0，否则是客户端自己拒绝发起，属于假阴性）"
    $o11 = SClient @("-tls1_1", "-cipher", "DEFAULT@SECLEVEL=0", "-brief")
    Check "TLS 1.1 被服务端拒绝（alert 70）" ($o11 -match "alert protocol version") ($o11 -replace "`r?`n", " | ")
    $o10 = SClient @("-tls1", "-cipher", "DEFAULT@SECLEVEL=0", "-brief")
    Check "TLS 1.0 被服务端拒绝（alert 70）" ($o10 -match "alert protocol version") ($o10 -replace "`r?`n", " | ")

    # ---------- 关卡 5：真实 HTTPS 请求（真证书校验，不加 -k） ----------
    Write-Host ""
    Write-Host "[关卡 5] 真实 HTTPS 请求，且做真证书校验（curl --cacert，不加 -k）"
    $base = "https://127.0.0.1:$Port"
    $r = CurlReq @("$base/health")
    Check "HTTPS GET /health -> 200" ($r.code -eq "200") "code=$($r.code)"
    Check "响应是统一包装 ok=true" ($r.body -match '"ok":true') "body=$($r.body)"
    $r = CurlReq @("--cacert", $keyPath, "$base/health")
    Check "用错误的 CA 必须失败（反证上一条不是假通过）" ($r.code -ne "200") "code=$($r.code)"

    # ---------- 接口可用 ----------
    Write-Host ""
    Write-Host "[接口] HTTPS 下真实走一遍登录流程"
    # 注意：PS 5.1 把参数交给原生命令时会吃掉内嵌的双引号，
    # 直接把 JSON 字符串用 -d 传过去会被改坏（服务端收到非法 JSON 而返回 400）。
    # 因此把请求体写进临时文件，用 --data-binary @文件 传，字节原样送出。
    $bodyFile = Join-Path $env:TEMP ("cjbody_" + [guid]::NewGuid().ToString("N") + ".json")
    [System.IO.File]::WriteAllText($bodyFile, '{"phone":"13800000000","password":"password123"}', (New-Object System.Text.UTF8Encoding($false)))
    $r = CurlReq @("-H", "Content-Type: application/json", "--data-binary", "@$bodyFile", "$base/api/v1/auth/login")
    Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue
    Check "HTTPS 登录 -> 200" ($r.code -eq "200") "code=$($r.code)"
    $tok = ""
    try { $tok = [string](($r.body | ConvertFrom-Json).data.token) } catch { $tok = "" }
    Check "拿到 token（64 位）" ($tok.Length -eq 64) "len=$($tok.Length)"
    $r = CurlReq @("-H", "Authorization: Bearer $tok", "$base/api/v1/auth/me")
    Check "HTTPS GET /auth/me -> 200" ($r.code -eq "200") "code=$($r.code)"
    Check "身份正确（会长）" ($r.body -match '"role":"president"') "body=$($r.body)"

    # ---------- 反证：明文访问 TLS 端口 ----------
    Write-Host ""
    Write-Host "[反证] 明文 HTTP 访问 TLS 端口应失败"
    $plain = (& $curl -s -o NUL -w "%{http_code}" "http://127.0.0.1:$Port/health" 2>&1 | Out-String).Trim()
    Check "明文访问失败（不是 200）" ($plain -ne "200") "code=$plain"

    # ---------- 优雅关闭 ----------
    Write-Host ""
    Write-Host "[收尾] 通过 HTTPS 触发优雅关闭"
    $r = CurlReq @("-X", "POST", "$base/admin/shutdown")
    Check "HTTPS /admin/shutdown -> 200" ($r.code -eq "200") "code=$($r.code)"
    $proc.WaitForExit(8000) | Out-Null
    Check "进程自行退出" ($proc.HasExited)
    $logText = ""
    if (Test-Path $logOut) { $logText = [System.IO.File]::ReadAllText($logOut, [System.Text.Encoding]::UTF8) }
    Check "日志出现『服务已停止』" ($logText -match "服务已停止") "log=$logText"
    Check "服务端日志无 FATAL" ($logText -notmatch "\[FATAL\]") ""
} catch {
    $script:fail++
    $errMsg = $_.Exception.Message
    Write-Host ("  FAIL  脚本内部异常： " + $errMsg) -ForegroundColor Red
} finally {
    if ($null -ne $proc -and -not $proc.HasExited) {
        try { Stop-Process -Id $proc.Id -Force } catch { }
    }
    Pop-Location
}

Write-Host ""
Write-Host "======================================"
Write-Host ("TLS 验证： PASS {0} / FAIL {1}" -f $script:pass, $script:fail)
Write-Host "======================================"
if ($script:fail -gt 0) { exit 1 }
exit 0
