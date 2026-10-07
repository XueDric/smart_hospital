# 智慧医院服务端构建脚本 —— cjc 直编（不经 cjpm），框架与业务同一次调用、同一个包。
#
# 与基线（baseline\server\build.ps1）保持同一套工具链口径：
#   cjc **1.2.0** + stdx **1.1.3.1**（静态）+ 内置轻舟源码 + 内置 MariaDB 驱动。
#
# 为什么不用 cjpm：驱动自己的 cjpm.toml 没声明 stdx 包，cjpm 会强校验并报
# 「imports package 'stdx.crypto.digest' but it is not added as a dependency」。
# 基线已踩过此坑（见 baseline\docs\mysql-backend.md §3.3），故沿用 cjc 直编。
#
# 用法：
#   .\build.ps1                                   # 自动探测工具链
#   .\build.ps1 -CangjieHome <SDK> -Stdx <stdx>   # 显式指定
#   设环境变量 CANGJIE_HOME / CANGJIE_STDX 亦可

param(
    [string]$CangjieHome = "",
    [string]$Stdx        = "",
    [string]$Vendor      = ""
)

$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
$src  = Join-Path $root "src"
$out  = Join-Path $root "build"
$tp   = Join-Path $root "third_party"
if ([string]::IsNullOrEmpty($Vendor)) { $Vendor = Join-Path $tp "qingzhou" }
New-Item -ItemType Directory -Force -Path $out | Out-Null

# ── 工具链解析 ────────────────────────────────────────────────────────────
# ⚠ 关键：**按版本挑 1.2.0**，不能只信 PATH。
#   cjenv 会把全局 CANGJIE_HOME 改写成旧 SDK，本机 PATH 上的 cjc 就是 1.1.3；
#   拿它去配 stdx 1.1.3.1 会串台，症状是编译中途 `LLVM ERROR: Broken module found`。
function Resolve-CangjieHome([string]$explicit) {
    $cands = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrEmpty($explicit)) { [void]$cands.Add($explicit) }
    foreach ($d in @((Join-Path $root "..\.tools\cangjie-1.2.0\cangjie"),
                     "D:\Cangjie", "C:\Cangjie", "E:\Cangjie",
                     (Join-Path $env:USERPROFILE "Cangjie"),
                     (Join-Path $env:ProgramFiles "Cangjie"),
                     (Join-Path $env:USERPROFILE ".cjenv\sdks\1.2.0\cangjie"))) {
        [void]$cands.Add($d)
    }
    if ($env:CANGJIE_HOME) { [void]$cands.Add($env:CANGJIE_HOME) }
    $onPath = Get-Command cjc -ErrorAction SilentlyContinue
    if ($null -ne $onPath) { [void]$cands.Add((Split-Path (Split-Path $onPath.Source) -Parent)) }

    $found = New-Object System.Collections.ArrayList
    foreach ($c in $cands) {
        if (-not [string]::IsNullOrEmpty($c) -and (Test-Path ([System.IO.Path]::Combine($c, "bin\cjc.exe")))) {
            $rp = (Resolve-Path $c).Path
            if (-not $found.Contains($rp)) { [void]$found.Add($rp) }
        }
    }
    foreach ($c in $found) {
        $v = (& (Join-Path $c "bin\cjc.exe") --version 2>&1 | Select-Object -First 1)
        if ("$v" -match '1\.2\.0') { return $c }
    }
    if ($found.Count -gt 0) { return $found[0] }
    return ""
}

function Resolve-Stdx([string]$explicit, [string]$sdkHome) {
    $cands = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrEmpty($explicit)) { [void]$cands.Add($explicit) }
    if ($env:CANGJIE_STDX) { [void]$cands.Add($env:CANGJIE_STDX) }
    $roots = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrEmpty($sdkHome)) {
        [void]$roots.Add((Split-Path $sdkHome -Parent))
        [void]$roots.Add($sdkHome)
    }
    foreach ($r in @((Join-Path $root "..\.tools\stdx"),
                     "E:\cangjie", "D:\cangjie", "C:\cangjie", (Join-Path $env:USERPROFILE "cangjie"))) {
        [void]$roots.Add($r)
    }
    foreach ($c in $cands) { if (Test-Path $c) { return (Resolve-Path $c).Path } }
    foreach ($r in $roots) {
        foreach ($sub in @("stdx\windows_x86_64_cjnative\static\stdx", "stdx\static\stdx")) {
            $p = [System.IO.Path]::Combine($r, $sub)
            if (Test-Path $p) { return (Resolve-Path $p).Path }
        }
    }
    return ""
}

$CangjieHome = Resolve-CangjieHome $CangjieHome
if ([string]::IsNullOrEmpty($CangjieHome)) {
    throw ("找不到仓颉 SDK 1.2.0（cjc.exe）。`n" +
           "  任选其一：.\build.ps1 -CangjieHome <SDK目录> / 设 `$env:CANGJIE_HOME / 把 cjc 放进 PATH")
}
$Stdx = Resolve-Stdx $Stdx $CangjieHome
if ([string]::IsNullOrEmpty($Stdx)) {
    throw "找不到 stdx 静态库（libstdx*.a）。用 -Stdx <...\windows_x86_64_cjnative\static\stdx> 或设 `$env:CANGJIE_STDX。"
}

$Cjc = Join-Path $CangjieHome "bin\cjc.exe"
$ver = (& $Cjc --version 2>&1 | Select-Object -First 1)
Write-Host "[build] 工具链：$CangjieHome"
Write-Host "[build]          cjc 版本：$ver"
Write-Host "[build]          stdx=$Stdx"
if ("$ver" -notmatch '1\.2\.0') {
    throw "本机 cjc 是 '$ver'，本项目要求 1.2.0 + stdx 1.1.3.1（版本串台症状：LLVM ERROR: Broken module found）"
}

# ── 文件集 ────────────────────────────────────────────────────────────────
# 框架：轻舟 src\*.cj，排除它自己的 main/单测与需要 cangdb 的后端。
#   注意 db_mysql.cj **必须编进来** —— 我们的 MySQL 数据层直接构造 MySqlBackend。
$fwExclude = @('main.cj', 'unit_tests.cj', 'manual_runner.cj', 'store.cj', 'rbac.cj',
               'db_cangdb.cj', 'db_factory.cj', 'jsonx_edge_test.cj')
$fw = Get-ChildItem (Join-Path $Vendor "src\*.cj") |
      Where-Object { $_.Name -notin $fwExclude } |
      ForEach-Object { $_.FullName }

# 业务：src\*.cj（医院自己的代码）
$app = Get-ChildItem (Join-Path $src "*.cj") | ForEach-Object { $_.FullName }
if ($app.Count -eq 0) { throw "没有找到服务端源码：$src" }

# ── MariaDB 驱动 ──────────────────────────────────────────────────────────
# 驱动不在仓库里（54 个文件、只在构建期需要），从**只读基线**取 .cjo 与静态库。
# 若基线里没有产物，给出可照做的指引（基线有 build-mysql-driver.ps1 可生成）。
$drvDir = Join-Path $tp "mariadb-driver-build"
if (-not (Test-Path $drvDir)) {
    $drvBuild = Join-Path $root "build\mysql-driver"
    if (Test-Path $drvBuild) { $drvDir = $drvBuild }
}
$useDriver = Test-Path (Join-Path $drvDir "mariadb.cdbc.cjo")
$extraImportPath = @()
$extraLibPath    = @()
$extraLibs       = @()
if ($useDriver) {
    $extraImportPath = @("--import-path", $drvDir)
    $extraLibPath    = @("-L", $drvDir)
    # ⚠ 必须用 -l:完整文件名 —— `-lmariadb.cdbc` 会被 cjc 按点号拆开
    #   （报 invalid file or directory '.cdbc'）。基线 mysql-backend.md §3.3 坑 2。
    $extraLibs       = @("-l:mariadb.cdbc", "-l:mariadb.connection", "-l:mariadb.protocol")
    Write-Host "[build] 驱动：$drvDir"
} else {
    Write-Warning "未找到 MariaDB 驱动产物（$drvDir）。将**不带驱动**编译 —— 可以验证语法与类型，但运行时无法连库。"
    Write-Warning "  生成驱动：见 baseline\docs\mysql-backend.md §3.1（baseline\server\build-mysql-driver.ps1）"
}

# stdx 各子包的 .a 要**逐个**链上（只给 -L 会报 undefined symbol: ...stdx.encoding.url...）
$libs = (Get-ChildItem "$Stdx\libstdx*.a" | ForEach-Object { "-l:$($_.Name)" })

$exe = Join-Path $out "hospital-server.exe"
if (Test-Path $exe) {
    try {
        $fs = [IO.File]::Open($exe, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $fs.Close()
    } catch {
        throw ("编译输出被占用：$exe`n  原因：还有 hospital-server.exe 在运行。`n" +
               "  处置：Get-Process hospital-server -ErrorAction SilentlyContinue | Stop-Process -Force")
    }
}

Write-Host "[build] 框架：轻舟（$($fw.Count) 个 .cj 参与编译）"
Write-Host "[build] 业务：$($app.Count) 个 .cj -> $exe"

& $Cjc @fw @app --import-path $Stdx -L $Stdx @libs @extraImportPath @extraLibPath @extraLibs `
    -lcrypt32 -Woff unused -o $exe
if ($LASTEXITCODE -ne 0) { throw "编译失败 (exit $LASTEXITCODE)" }
Write-Host "[build] ✅ 编译通过：$exe"

# ── 源码哈希清单（SOURCE-MANIFEST.sha256）─────────────────────────────────
# ⚠ 为什么不用**产物**哈希当验收依据（2026-10-07 实测确认）：
#   cjc 的输出**不逐字节可复现** —— 同一份源码重建，exe 的 SHA256 会变
#   （行为一致，属编译器正常现象：内嵌时间戳/路径/布局差异）。
#   所以"产物哈希对不对"**不能**用来判验收。可复现的锚点是：
#       源码哈希 + 测试结果
#   本清单把参与编译的**每一个源文件**的 SHA256 记下来，供验收时比对，
#   口径与基线的 MANIFEST.sha256 一致（基线拿它锁轻舟框架快照）。
$manifest = Join-Path $out "SOURCE-MANIFEST.sha256"
$lines = New-Object System.Collections.ArrayList
$allSrc = @($app) + @($fw)
foreach ($f in ($allSrc | Sort-Object)) {
    $h = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLower()
    $rel = $f.Substring($root.Length).TrimStart('\')
    # 格式与 sha256sum 一致：<hash>  <相对路径>
    [void]$lines.Add("$h  $rel")
}
# 同时记录固定输入的指纹：工具链版本 + stdx 路径 + 驱动产物哈希
[void]$lines.Add("# cjc=$ver")
[void]$lines.Add("# stdx=$Stdx")
if ($useDriver) {
    $drvHash = (Get-FileHash -LiteralPath (Join-Path $drvDir "mariadb.cdbc.cjo") -Algorithm SHA256).Hash.ToLower()
    [void]$lines.Add("# driver(mariadb.cdbc.cjo)=$drvHash")
}
[System.IO.File]::WriteAllLines($manifest, $lines, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "[build] 源码清单：$manifest（$($allSrc.Count) 个文件）"
Write-Host "[build] ⚠ 验收请比**源码哈希 + 测试结果**，不要比 exe 哈希（cjc 产物不逐字节可复现）"
