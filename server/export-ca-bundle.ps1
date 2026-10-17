# SPDX-License-Identifier: MIT
#
# ===== export-ca-bundle.ps1 —— 导出 Windows 信任根到 PEM（给仓颉运行时的 OpenSSL 用）===
#
# 为什么需要它（2026-10-17 实测，评审整改）：
#   仓颉 stdx 的 HTTPS 客户端走 **OpenSSL**，不读 Windows 证书存储。本机实测
#   `POST /api/v1/admin/ai/models/:id/test` 报：
#     TLS handshake failed (client): certificate verify failed (134), TLS alert unknown CA(F)
#   而同一台机器上 `curl.exe`（Schannel）与 PowerShell（.NET）访问同一个 endpoint 都是 200。
#   ⇒ 不是网络、不是密钥，是**这个进程没有信任锚**。
#
# 做法：把 Windows 的「受信任的根证书颁发机构」+「中间 CA」导出一个 PEM 包，
#   再让服务端进程带上环境变量 `SSL_CERT_FILE=<这个文件>`（OpenSSL 认这个变量）。
#
# ⚠ 这是**运维动作**，不改系统状态：只读证书存储、只写一个文件。
# ⚠ 不要把"某台机器导出的 CA 包"塞进对外分发包 —— 它可能含企业内网根证书。
#   分发包里带的是**本脚本**，首次启动时在目标机上现场导一次。
#
# 用法：
#   .\export-ca-bundle.ps1
#   .\export-ca-bundle.ps1 -Out C:\certs\ca.pem
#   $env:SSL_CERT_FILE = "<仓库>\server\build\ca-bundle.pem"
#
# 判据（做完怎么证明）：
#   `curl -X POST .../api/v1/admin/ai/models/<id>/test` 返回
#   `"probe":{"ok":true,...,"http_status":200}`；不再是 134 / unknown CA。

[CmdletBinding()]
param(
    # 输出路径；默认 server\build\ca-bundle.pem（已在 .gitignore 里）
    [string]$Out = ""
)

$ErrorActionPreference = "Stop"

$root = $PSScriptRoot                             # server\
if ([string]::IsNullOrEmpty($Out)) {
    $Out = Join-Path $root "ca-bundle.pem"           # 默认 server\ca-bundle.pem（不入库）
}
$dir = Split-Path -Parent $Out
if (-not (Test-Path $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }

$sb = New-Object System.Text.StringBuilder
$seen = @{}
$count = 0

# 三个存储：本机的根 + 中间 CA，以及当前用户的根（企业环境常把根推到这里）
foreach ($store in @('Cert:\LocalMachine\Root', 'Cert:\LocalMachine\CA', 'Cert:\CurrentUser\Root')) {
    foreach ($c in Get-ChildItem $store -ErrorAction SilentlyContinue) {
        $b64 = [Convert]::ToBase64String($c.RawData, 'InsertLineBreaks')
        if ($seen.ContainsKey($b64)) { continue }
        $seen[$b64] = $true
        [void]$sb.AppendLine("# " + $c.Subject)
        [void]$sb.AppendLine("-----BEGIN CERTIFICATE-----")
        [void]$sb.AppendLine($b64)
        [void]$sb.AppendLine("-----END CERTIFICATE-----")
        $count++
    }
}

if ($count -eq 0) {
    throw "从 Windows 证书存储里一张证书都没读到（不是管理员也可能读，但这一台确实为空）"
}

[System.IO.File]::WriteAllText($Out, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "[ok] 已导出 $count 张证书 -> $Out（$([math]::Round((Get-Item $Out).Length / 1kb, 1)) KB）"
Write-Host ""
Write-Host "下一步（当前 PowerShell 会话里生效）：" -ForegroundColor Cyan
Write-Host "  `$env:SSL_CERT_FILE = `"$Out`""
Write-Host "  然后重启服务端。启动脚本 start-dev.cmd 会自动带上它。"
Write-Host ""
Write-Host "⚠ 换网络环境（换到另一家医院内网、开了新代理）后要重新导一次。" -ForegroundColor Yellow
