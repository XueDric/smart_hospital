#requires -Version 5.1
<#
.SYNOPSIS
仓库卫生门禁：文档链接、脚本编码、批处理 ASCII、旧路径残留、注释嵌套。

.DESCRIPTION
把"靠人眼复查一次"的五件事变成可重跑的一条命令（评审 P1-4/P1-6 的落点其一）：
  1) 所有 .md 里的**相对链接**必须指向真实存在的文件（外链、页内锚点跳过）；
  2) **含中文的 .ps1 必须带 UTF-8 BOM**，否则 PS 5.1 按 ANSI 解析会乱码/报 Unexpected token；
  3) **.bat 必须是纯 ASCII**（cmd 在 GBK 代码页下会把 UTF-8 中文注释解析坏，实测报 wrapper.js 不是命令）；
  4) 任何文件都不得再出现旧仓库绝对路径 `harmonyOS\智能医院...`（2026-10-17 已改名）；
  5) **源码注释正文里不得出现 /***：Kotlin/仓颉块注释可嵌套，注释里的 /* 会吃成一层永不闭合，整文件不编译（2026-10-18 实测踩过）。

用法：
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\check-docs.ps1
  powershell ... -File tools\check-docs.ps1 -Verbose   # 逐个文件打印检查结果

退出码：0 = 全绿；1 = 有违规（详见输出）。
⚠ 本脚本含中文，必须保存为 UTF-8 with BOM。
#>
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
# `.build-tools` 是本地一次性工具目录（JDK/Gradle 缓存、联调脚本，已在 .gitignore 里），
# 不参与仓库卫生检查 —— 否则把本地临时脚本也算成"仓库违规"，红灯指向的不是提交内容。
$skip = @('node_modules', 'oh_modules', 'build', 'release', '.git', '.hvigor', '.hvigor-user-home', '.gradle', 'dist', '.build-tools')
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
Write-Host ("[1/5] Markdown 相对链接：检查 {0} 条" -f $mdChecked)

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
Write-Host ("[2/5] PowerShell 编码：{0} 个 .ps1 不合规" -f $psBad)

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
Write-Host ("[3/5] 批处理 ASCII：{0} 个 .bat 不合规" -f $batBad)

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
Write-Host ("[4/5] 旧路径残留：{0} 个文件" -f $oldBad)

# ── 5) 源码注释里的 `/*`（嵌套注释） ──────────────────────────────────────
# Kotlin 与仓颉的块注释**可嵌套**：注释正文里出现 `/*` 会再开一层，原文的 `*/` 只关掉
# 内层，外层永远不闭合 ⇒ 整文件 syntax error（2026-10-18 实测：SecretStore.kt 里一句
# `shared_prefs/*.xml` 让整文件不编译，并连带另一个文件报 Unresolved reference）。
# 判据：同一行里 `/*` 之前有非空白内容（不是"行首开注释"），且该行此后再无 `*/`。
$nestedBad = 0
$nestedExt = @('.kt', '.ets', '.cj', '.java', '.ts')
foreach ($f in $files | Where-Object { $_.Extension -in $nestedExt }) {
    try {
        $lines = [System.IO.File]::ReadAllLines($f.FullName, [System.Text.UTF8Encoding]::new($false, $true))
    } catch {
        continue
    }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        # 先把字符串字面量挖掉：`"/files/*"` 这类路由/通配写法是数据不是注释，不该报。
        $stripped = [regex]::Replace($line, '"[^"]*"', '""')
        $stripped = [regex]::Replace($stripped, "'[^']*'", "''")
        $idx = $stripped.IndexOf('/*')
        if ($idx -lt 0) { continue }
        # 行注释（//）里的 /* 无害：行注释不嵌套，整体到行尾就结束。
        $lineComment = $stripped.IndexOf('//')
        if ($lineComment -ge 0 -and $lineComment -lt $idx) { continue }
        $before = ''
        if ($idx -gt 0) { $before = $stripped.Substring(0, $idx) }
        if ($before.Trim().Length -eq 0) { continue }
        if ($before.TrimEnd().EndsWith('*')) { continue }
        if ($stripped.Substring($idx + 2).Contains('*/')) { continue }
        Add-Problem ("注释嵌套：{0}:{1} 行内出现 /* 且同行未闭合（Kotlin/仓颉块注释可嵌套，会吃掉后续代码；改成不含 /* 的写法，或让它在同一行闭合）" -f $f.FullName.Substring($repo.Length + 1), ($i + 1))
        $nestedBad++
    }
}
Write-Host ("[5/5] 注释嵌套：{0} 处 /* 未同行闭合" -f $nestedBad)

Write-Host ''
if ($problems.Count -eq 0) {
    Write-Host "OK 仓库卫生检查全绿"
    exit 0
}
Write-Host ("FAIL 共 {0} 处违规：" -f $problems.Count)
foreach ($p in $problems) { Write-Host "  - $p" }
exit 1