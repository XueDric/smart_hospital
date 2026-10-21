<#
.SYNOPSIS
  尽力解析仓颉 SDK（cangjie-sdk-windows-x64-<版本>.zip）的直链。

.DESCRIPTION
  官网 https://cangjie-lang.cn/download/<版本> 的下载按钮是前端签名生成的，直链**会变**，
  所以这里只做两件事：
    1) 抓页面，把 `https?://...<版本>...zip` 形态的链接抠出来（哪天官网把直链写进 HTML 就能用）；
    2) 抠不到就 exit 1，由调用方（CI 的 build-and-test job）打印"编译层未执行"的说明。
  **本脚本不猜路径、不拼 CDN 地址** —— 猜出来的链接迟早 404，那比没有更糟。

  实测（2026-10-21）：官网页面只给文件名与大小（`cangjie-sdk-windows-x64-1.2.0.zip` / 250.7MB），
  直链由点击时的接口返回，因此本脚本当前**稳定返回 exit 1**；这是如实结果，不是故障。
  要在 CI 里真编译，请配仓库变量 `CANGJIE_SDK_URL`。

.PARAMETER Version
  版本号，默认 1.2.0（与 server/build/SOURCE-MANIFEST.sha256 里的 `# cjc=` 指纹一致）。

.PARAMETER Quiet
  成功时只输出 URL（供 `$url = & script -Quiet` 取用）。

.OUTPUTS
  成功：stdout 输出 URL（一条），exit 0。失败：exit 1。
#>
[CmdletBinding()]
param(
    [string]$Version = '1.2.0',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$page = "https://cangjie-lang.cn/download/$Version"

function Write-Info([string]$msg) { if (-not $Quiet) { Write-Host $msg } }

try {
    Write-Info "抓取官网下载页：$page"
    $resp = Invoke-WebRequest -Uri $page -TimeoutSec 30 -UseBasicParsing
} catch {
    Write-Info "❌ 下载页抓取失败：$($_.Exception.Message)"
    exit 1
}

# 只认"看起来就是 SDK zip"的链接：主机任意，但路径里必须同时出现 cangjie 与版本号与 .zip
$pattern = 'https?://[^\s"''<>]+?cangjie[^\s"''<>]*?sdk[^\s"''<>]*?' + [regex]::Escape($Version) + '[^\s"''<>]*?\.zip'
$hits = [regex]::Matches($resp.Content, $pattern, 'IgnoreCase') | ForEach-Object { $_.Value } | Select-Object -Unique

if (-not $hits -or $hits.Count -eq 0) {
    Write-Info "❌ 页面里没有 $Version 的 SDK 直链（直链由前端签名生成，不在 HTML 里）"
    Write-Info "  要在 CI 真编译，请配置仓库变量 CANGJIE_SDK_URL；本地编译直接用已装的 CANGJIE_HOME。"
    exit 1
}

$url = @($hits)[0]
Write-Info "✅ 解析到直链：$url"
Write-Output $url
exit 0