# 重新生成内置轻舟的 MANIFEST.sha256
#
# 清单的语义 = **「会被提交的那份内容」逐字节锁定**，所以必须**从索引生成**（git ls-files），
# 而不是枚举工作区 —— 后者会把 .gitignore 掉的 deps/openssl/*.dll 也写进去，
# 于是"新机器 clone（那些 DLL 本就不存在）"一构建就被拒（N-22 已实测复现）。
#
# 用法（要纳入的文件先 git add，再跑）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\update-manifest.ps1

$ErrorActionPreference = "Stop"

$vendor = $PSScriptRoot
$mf = Join-Path $vendor "MANIFEST.sha256"

# git 输出的路径总是相对**仓库根**，先算出本目录在仓库里的前缀
$prefix = (& git -C $vendor rev-parse --show-prefix).Trim().Replace('\', '/')
$tracked = & git -C $vendor ls-files
if ($LASTEXITCODE -ne 0) { throw "git ls-files 失败 —— 本目录必须在一个 git 仓库里" }

$lines = New-Object System.Collections.ArrayList
foreach ($full in $tracked) {
    $rel = $full
    if ($prefix -and $rel.StartsWith($prefix)) { $rel = $rel.Substring($prefix.Length) }
    if ($rel -eq 'MANIFEST.sha256') { continue }
    $p = Join-Path $vendor ($rel -replace '/', '\')
    if (-not (Test-Path $p)) { throw "索引里有、工作区却没有：$rel（先 git checkout 或重新 git add）" }
    $h = (Get-FileHash $p -Algorithm SHA256).Hash.ToLower()
    [void]$lines.Add("$h  $rel")
}
$sorted = ($lines | Sort-Object { $_.Split('  ')[1] })
[System.IO.File]::WriteAllText($mf, (($sorted -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))

Write-Host "[manifest] 已按**索引**重新生成：$mf"
Write-Host "[manifest] 共 $($sorted.Count) 个文件"

$untracked = & git -C $vendor ls-files --others --exclude-standard
if ($untracked) {
    Write-Host "[manifest] 注意：下列文件在工作区但**未被跟踪**，因此不在清单里；若该纳入，请先 git add 再重跑："
    $untracked | ForEach-Object { "    $_" }
}