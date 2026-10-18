#requires -Version 5.1
<#
.SYNOPSIS
仓库卫生门禁：文档链接、脚本编码、旧路径残留。

.DESCRIPTION
把"靠人眼复查一次"的三件事变成可重跑的一条命令（评审 P1-4/P1-6 的落点其一）：
  1) 所有 .md 里的**相对链接**必须指向真实存在的文件（外链、页内锚点跳过）；
  2) **含中文的 .ps1 必须带 UTF-8 BOM**，否则 PS 5.1 按 ANSI 解析会乱码/报 Unexpected token；
  3) **.bat 必须是纯 ASCII**（cmd 在 GBK 代码页下会把 UTF-8 中文注释解析坏，实测报 wrapper.js 不是命令）；
  4) 任何文件都不得再出现旧仓库绝对路径 `harmonyOS\智能医院...`（2026-10-17 已改名）。

用法：
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\check-docs.ps1
  powershell ... -File tools\check-docs.ps1 -Verbose   # 逐个文件打印检查结果

退出码：0 = 全绿；1 = 有违规（详见输出）。
⚠ 本脚本含中文，必须保存为 UTF-8 with BOM。
#>
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$skip = @('node_modules', 'oh_modules', 'build', 'release', '.git', '.hvigor', '.hvigor-user-home', '.gradle', 'dist')
$sep  = [System.IO.Path]::DirectorySeparatorChar

function Test-Skipped([string]$full) {
    foreach ($d in $script:skip) {
        if ($full.IndexOf("$script:sep$d$script:sep") -ge 0) { return $true }
    }
    return $false
}

$problems = New-Object System.Collections.ArrayList
function Add-Problem([string]$msg) { [void]$script:problems.Add($msg) }

$files = Get-ChildItem -Path $repo -Recurse -File | Where-Object { -not (Test-Skipped $_.FullName) }
Write-Verbose ("扫描 {0} 个文件（已跳过 {1}）" -f $files.Count, ($skip -join ', '))

# ── 1) Markdown 相对链接 ───────────────────────────────────────────────────
$mdChecked = 0
$linkRe = [regex]'!?\[[^\]]*\]\(([^)\r\n]+)\)'
foreach ($f in $files | Where-Object { $_.Extension -eq '.md' -and $_.FullName.IndexOf("${sep}third_party${sep}") -lt 0 }) {
    $text = [System.IO.File]::ReadAllText($f.FullName, [System.Text.UTF8Encoding]::new($false))
    foreach ($m in $linkRe.Matches($text)) {
        $target = $m.Groups[1].Value.Trim()
        if ($target.StartsWith('<') -and $target.EndsWith('>')) { $target = $target.Substring(1, $target.Length - 2) }
        if ($target -match '^(https?|mailto|file):' -or $target.Contains('://')) { continue }
        if ($target.StartsWith('#') -or $target.Length -eq 0) { continue }
        if ($target.Contains('|') -or $target.Contains('*')) { continue }
        $path = $target
        $hash = $path.IndexOf('#')
        if ($hash -ge 0) { $path = $path.Substring(0, $hash) }
        if ($path.Length -eq 0) { continue }
        $path = $path.Replace('/', $sep).Replace('%20', ' ')
        $abs = if ($path.StartsWith($sep)) { Join-Path $repo $path.TrimStart($sep) } else { Join-Path $f.DirectoryName $path }
        $mdChecked++
        if (-not (Test-Path -LiteralPath $abs)) {
            $rel = $f.FullName.Substring($repo.Length + 1)
            Add-Problem "坏链：$rel -> $target"
        }
    }
}
Write-Host ("[1/4] Markdown 相对链接：检查 {0} 条" -f $mdChecked)

# ── 2) .ps1 编码（含中文必须 BOM）─────────────────────────────────────────
$psBad = 0
foreach ($f in $files | Where-Object { $_.Extension -in '.ps1', '.psm1' }) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $nonAscii = $false
    foreach ($b in $bytes) { if ($b -gt 0x7F) { $nonAscii = $true; break } }
    if ($nonAscii -and -not $hasBom) {
        Add-Problem ("编码：{0} 含非 ASCII 但无 UTF-8 BOM（PS 5.1 会按 ANSI 解析）" -f $f.FullName.Substring($repo.Length + 1))
        $psBad++
    }
}
Write-Host ("[2/4] PowerShell 编码：{0} 个 .ps1 不合规" -f $psBad)

# ── 3) .bat 必须纯 ASCII ──────────────────────────────────────────────────
$batBad = 0
foreach ($f in $files | Where-Object { $_.Extension -in '.bat', '.cmd' }) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    foreach ($b in $bytes) {
        if ($b -gt 0x7F) {
            Add-Problem ("编码：{0} 含非 ASCII 字节（cmd 在 GBK 代码页下会解析坏，必须纯 ASCII）" -f $f.FullName.Substring($repo.Length + 1))
            $batBad++
            break
        }
    }
}
Write-Host ("[3/4] 批处理 ASCII：{0} 个 .bat 不合规" -f $batBad)

# ── 4) 旧仓库路径残留 ─────────────────────────────────────────────────────
# 2026-10-17 仓库由 `智能医院客户端` 改名为 `smart_hospital`（ASCII）。
# 只查**带盘符/反斜杠的绝对路径写法**，允许文档在叙述历史时提旧名（如 DEPLOYMENT 的改名说明）。
$oldBad = 0
$oldRe = [regex]'harmonyOS[\\/]+\u667a\u80fd\u533b\u9662'
# 例外：评审原文存档按"当时现场"保留，不改；本脚本自身要写出被查的路径模式。
$allowOld = @("docs${sep}评审反馈-2026-10-17.md", "tools${sep}check-docs.ps1")
foreach ($f in $files | Where-Object { $_.Extension -in '.md', '.ps1', '.cj', '.ets', '.kt', '.json5', '.json', '.bat', '.js', '.mjs' }) {
    # ✅ 2026-10-17 复查：ReadAllText 遇到非 UTF-8 字节会抛 DecoderFallbackException，
    #    在 EAP=Stop 下直接堆栈退出 —— 报的是"脚本崩了"，而不是"这个文件不是 UTF-8"。
    try {
        $text = [System.IO.File]::ReadAllText($f.FullName, [System.Text.UTF8Encoding]::new($false, $true))
    } catch {
        Add-Problem ("编码：{0} 不是合法 UTF-8（请转存为 UTF-8）" -f $f.FullName.Substring($repo.Length + 1))
        continue
    }
    $isAllowed = $false
    foreach ($a in $allowOld) { if ($f.FullName.EndsWith($a)) { $isAllowed = $true } }
    if ((-not $isAllowed) -and $oldRe.IsMatch($text)) {
        Add-Problem ("旧路径：{0} 仍含已改名的中文仓库路径（见 docs/REVERIFY-AND-FIXES-2026-10-17.md）" -f $f.FullName.Substring($repo.Length + 1))
        $oldBad++
    }
}
Write-Host ("[4/4] 旧路径残留：{0} 个文件" -f $oldBad)

Write-Host ''
if ($problems.Count -eq 0) {
    Write-Host "OK 仓库卫生检查全绿"
    exit 0
}
Write-Host ("FAIL 共 {0} 处违规：" -f $problems.Count)
foreach ($p in $problems) { Write-Host "  - $p" }
exit 1