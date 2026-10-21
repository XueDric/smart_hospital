# SPDX-License-Identifier: MIT
#
# ===== verify-source-manifest.ps1 —— 校验「交付的二进制」对应的源码与仓库一致 =====
#
# 为什么需要它（2026-10-21，评估报告第 ③ 条的折中）：
#   `server/build/hospital-server.exe` 是**编译产物**，按仓库纪律不入库；入的是：
#     · 分发包里的 exe（release/*.zip）
#     · `server/build/SOURCE-MANIFEST.sha256`（76 个参与编译的源文件 + 3 行工具链指纹）
#   评委看仓库时无法验证"这个 exe 是这份源码编出来的"。本脚本把这件事实变成**一条命令**：
#   按 MANIFEST 重算每个文件的 sha256，逐个比对，任何一处不一致就 exit 1。
#
#   它**不需要编译器、不需要数据库、不需要 Windows 之外的任何东西**，
#   所以在 CI 的托管 runner 上也能真绿（对比 ci-pure-tests 的"缺工具链就 SKIP"）。
#
# 用法：
#   .\tools\verify-source-manifest.ps1                       # 默认读 server/build/SOURCE-MANIFEST.sha256
#   .\tools\verify-source-manifest.ps1 -Manifest <路径> -Root <仓库根>
#   .\tools\verify-source-manifest.ps1 -Quiet                # 只打汇总行（CI 用）
#
# 退出码：0 = 全部一致；1 = 有缺失/哈希不符/清单格式错；2 = 清单文件不存在（前置条件不满足）
#
# ⚠ 该 MANIFEST 由 `server/build.ps1` 在**每次编译后**重写（含当下 cjc/stdx 指纹）。
#   源码变了而 exe 没重编，本脚本会立刻红 —— 这正是它存在的意义。

[CmdletBinding()]
param(
    [string]$Manifest = "",
    [string]$Root = "",
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

if (-not $Root) {
    $Root = Split-Path -Parent $PSScriptRoot
}
$Root = (Resolve-Path -LiteralPath $Root).Path

if (-not $Manifest) {
    $Manifest = Join-Path $Root "server\build\SOURCE-MANIFEST.sha256"
}

function Say($msg, $color = "Gray") {
    if (-not $Quiet) { Write-Host $msg -ForegroundColor $color }
}

if (-not (Test-Path -LiteralPath $Manifest)) {
    Write-Host "❌ 找不到源码清单：$Manifest" -ForegroundColor Red
    Write-Host "   它是编译产物（server/build/ 不入库）。请先跑 server/build.ps1，或从分发包里解出它。" -ForegroundColor Yellow
    exit 2
}

$lines = [System.IO.File]::ReadAllLines($Manifest)
$checked = 0
$bad = @()
$missing = @()
$fingerprint = @()

foreach ($ln in $lines) {
    if ([string]::IsNullOrWhiteSpace($ln)) { continue }
    if ($ln.StartsWith("#")) {
        # 工具链指纹行（cjc / stdx / driver）：只回显，不参与文件比对
        $fingerprint += $ln.Substring(1).Trim()
        continue
    }
    if ($ln -notmatch '^(?<hash>[0-9a-fA-F]{64})  (?<rel>.+)$') {
        $bad += "清单格式无法解析：$ln"
        continue
    }
    $hash = $Matches['hash'].ToLowerInvariant()
    $rel = $Matches['rel']
    # 清单里的路径是相对 <repo>/server 的（src\... / third_party\...）
    $full = Join-Path $Root (Join-Path "server" $rel)
    if (-not (Test-Path -LiteralPath $full)) {
        $missing += $rel
        continue
    }
    $actual = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
    $checked++
    if ($actual -ne $hash) {
        $bad += ("{0}：清单 {1}… / 实际 {2}…" -f $rel, $hash.Substring(0, 12), $actual.Substring(0, 12))
    } else {
        Say ("  [OK]   " + $rel) "DarkGray"
    }
}

Say "" 
Say "源码清单：$Manifest"
foreach ($f in $fingerprint) { Say ("  指纹：" + $f) "DarkCyan" }
Say ("  比对文件数：{0}" -f $checked) "Gray"

if ($missing.Count -gt 0) {
    Write-Host ("❌ 清单里有 {0} 个文件在工作区不存在：" -f $missing.Count) -ForegroundColor Red
    $missing | ForEach-Object { Write-Host ("   - " + $_) -ForegroundColor Red }
    exit 1
}
if ($bad.Count -gt 0) {
    Write-Host ("❌ 有 {0} 处不一致（源码与交付的二进制不是同一份）：" -f $bad.Count) -ForegroundColor Red
    $bad | ForEach-Object { Write-Host ("   - " + $_) -ForegroundColor Red }
    exit 1
}
if ($checked -eq 0) {
    Write-Host "❌ 清单里没有任何可比对的文件行（格式可能被改坏了）" -ForegroundColor Red
    exit 1
}

Write-Host ("✅ 源码清单一致（{0} 个文件的 sha256 与交付二进制对应的源码逐字节相同）" -f $checked) -ForegroundColor Green
exit 0
