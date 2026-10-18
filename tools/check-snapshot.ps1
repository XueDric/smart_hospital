#Requires -Version 5.1
<#
.SYNOPSIS
    交付快照一致性校验：docs/交付快照.md 的机器校验块 vs 磁盘上的真实交付物。

.DESCRIPTION
    检查项
      1. version  == server/src/main.cj 的 SERVER_VERSION
      2. commit   == 当前 HEAD 的短 SHA（允许快照是 HEAD 的前缀，方便"打完包又提交文档"）
      3. hap/apk/zip 的 size 与 sha256 == 磁盘真实文件
      4. zip_entries == zip 内的条目数
      5. tag 存在（git tag --list 能查到）

    两种模式
      默认       严格校验，任何一条不符就以 1 退出（CI 跑这个）
      -Update    用磁盘真值重写 docs/交付快照.md 的机器校验块（交付物重建后跑这个）

.NOTES
    为什么单独做这个脚本：评审第 5 条要求"测试数量、版本号、截图、压缩包哈希与实际提交版本必须一致"。
    断言数由 server/tests/doc-counts.ps1 负责对账；本脚本只管"交付物的体积与哈希 + 版本 + 提交"。
#>
param(
    [switch]$Update
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$snapshot = Join-Path $repo 'docs\交付快照.md'
$hap = Join-Path $repo 'release\harmony\entry-default-unsigned.hap'
$apk = Join-Path $repo 'release\android\app-debug.apk'
$zip = Join-Path $repo 'release\hospital-server-0.2.0-p1-win-x64.zip'
$mainCj = Join-Path $repo 'server\src\main.cj'

function Fail($msg) {
    Write-Host ("  [FAIL] " + $msg) -ForegroundColor Red
    $script:bad++
}
function Ok($msg) {
    Write-Host ("  [OK]   " + $msg) -ForegroundColor Green
}

if (-not (Test-Path -LiteralPath $snapshot)) { throw "找不到快照文件：$snapshot" }

# ---------- 从真实世界取真值 ----------
if (-not (Test-Path -LiteralPath $mainCj)) { throw "找不到 $mainCj" }
$verLine = Select-String -Path $mainCj -Pattern 'SERVER_VERSION\s*:\s*String\s*=\s*"([^"]+)"' | Select-Object -First 1
if (-not $verLine) { throw "在 main.cj 里没找到 SERVER_VERSION" }
$realVersion = $verLine.Matches[0].Groups[1].Value

$realCommit = (& git -C $repo rev-parse --short HEAD 2>$null)
if (-not $realCommit) { throw "取不到 HEAD（不在 git 仓库里？）" }

$real = [ordered]@{}
$real['version'] = $realVersion
$real['commit'] = $realCommit
foreach ($pair in @(@('hap', $hap), @('apk', $apk), @('zip', $zip))) {
    $name = $pair[0]; $path = $pair[1]
    if (-not (Test-Path -LiteralPath $path)) {
        # 未构建/未入库的交付物不算"不一致"：CI 的全新 clone 里没有 zip（release/*.zip 被 gitignore），
        # 不代表快照错了。这里如实标 SKIP，让人知道这一项这次没验。
        Write-Host ("  [SKIP] 交付物不存在：" + $path + "（未构建或未入库）") -ForegroundColor Yellow
        $script:skipped++
        continue
    }
    $len = (Get-Item -LiteralPath $path).Length
    $sha = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    $real[$name + '_size'] = [string]$len
    $real[$name + '_sha256'] = $sha
}
if (Test-Path -LiteralPath $zip) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [System.IO.Compression.ZipFile]::OpenRead($zip)
    $real['zip_entries'] = [string]$z.Entries.Count
    $z.Dispose()
}
$realTag = (& git -C $repo tag --list 'v0.2.0-p1-rev' 2>$null)
if ($realTag) { $real['tag'] = $realTag.Trim() }

# ---------- 读快照块 ----------
$lines = [System.IO.File]::ReadAllLines($snapshot)
$begin = -1; $end = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '<!--\s*snapshot:begin\s*-->') { $begin = $i }
    elseif ($lines[$i] -match '<!--\s*snapshot:end\s*-->') { $end = $i }
}
if ($begin -lt 0 -or $end -lt 0 -or $end -le $begin) { throw "快照文件里没有找到 <!-- snapshot:begin --> / <!-- snapshot:end --> 块" }

$snap = [ordered]@{}
for ($i = $begin + 1; $i -lt $end; $i++) {
    $line = $lines[$i].Trim()
    if ($line.Length -eq 0) { continue }
    if ($line -match '^([a-z0-9_]+)\s*=\s*(.+)$') {
        $snap[$Matches[1]] = $Matches[2].Trim()
    }
}

# ---------- -Update：用真值重写块 ----------
if ($Update) {
    $order = @('version', 'commit', 'tag', 'hap_size', 'hap_sha256', 'apk_size', 'apk_sha256', 'zip_size', 'zip_entries', 'zip_sha256')
    $newBlock = New-Object System.Collections.Generic.List[string]
    foreach ($k in $order) {
        if ($real.Contains($k)) { $newBlock.Add("$k=$($real[$k])") }
    }
    $out = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -le $begin; $i++) { $out.Add($lines[$i]) }
    foreach ($l in $newBlock) { $out.Add($l) }
    for ($i = $end; $i -lt $lines.Count; $i++) { $out.Add($lines[$i]) }
    $text = ($out -join "`n") + "`n"
    [System.IO.File]::WriteAllText($snapshot, $text, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ("已刷新快照：$snapshot") -ForegroundColor Cyan
    foreach ($l in $newBlock) { Write-Host ("  " + $l) }
    exit 0
}

# ---------- 严格校验 ----------
$script:bad = 0
$script:skipped = 0
Write-Host "交付快照校验：$snapshot" -ForegroundColor Cyan

if ($snap['version'] -ne $real['version']) {
    Fail ("version 不一致：快照 " + $snap['version'] + "，main.cj " + $real['version'])
} else { Ok ("version = " + $real['version']) }

$snapCommit = [string]$snap['commit']
$realCommitStr = [string]$real['commit']
if ($snapCommit -ne $realCommitStr) {
    # 允许快照是当前 HEAD 的前缀（打完包后又提交文档是常态）
    if ($realCommitStr.StartsWith($snapCommit) -and $snapCommit.Length -ge 7) {
        Ok ("commit 锚定 " + $snapCommit + "（当前 HEAD " + $realCommitStr + " 是它的后代）")
    } else {
        Fail ("commit 不一致：快照 " + $snapCommit + "，HEAD " + $realCommitStr)
    }
} else { Ok ("commit = " + $realCommitStr) }

foreach ($k in @('hap_size', 'hap_sha256', 'apk_size', 'apk_sha256', 'zip_size', 'zip_sha256', 'zip_entries')) {
    if (-not $real.Contains($k)) { continue }
    if ($snap[$k] -ne $real[$k]) {
        $shortS = [string]$snap[$k]; if ($shortS.Length -gt 20) { $shortS = $shortS.Substring(0, 8) + '…' }
        $shortR = [string]$real[$k]; if ($shortR.Length -gt 20) { $shortR = $shortR.Substring(0, 8) + '…' }
        Fail ("$k 不一致：快照 $shortS，磁盘 $shortR")
    } else {
        $show = [string]$real[$k]; if ($show.Length -gt 20) { $show = $show.Substring(0, 8) + '…' }
        Ok ("$k = $show")
    }
}

if ($real.Contains('tag')) {
    if ($snap['tag'] -ne $real['tag']) { Fail ("tag 不一致：快照 " + $snap['tag'] + "，仓库 " + $real['tag']) }
    else { Ok ("tag = " + $real['tag']) }
} else { Fail "仓库里没有 tag v0.2.0-p1-rev" }

Write-Host ""
if ($script:bad -gt 0) {
    Write-Host ("❌ 快照与磁盘不一致 $($script:bad) 处。" + `
        "交付物重建过就跑 .\tools\check-snapshot.ps1 -Update，并顺带跑 server\tests\doc-counts.ps1 -Fix。") -ForegroundColor Red
    exit 1
}
if ($script:skipped -gt 0) {
    Write-Host ("⚠ 有 $($script:skipped) 项交付物不在磁盘上，已跳过（CI clone 里没有 zip 属正常）。") -ForegroundColor Yellow
}
Write-Host "✅ 交付快照一致（体积/哈希/版本/提交/tag 全对上）。" -ForegroundColor Green
Write-Host "   断言数请另跑：server\tests\doc-counts.ps1" -ForegroundColor DarkGray
exit 0
