# 编译内置的 MariaDB/MySQL 驱动（Cangjie-SIG mysql-driver）
#
# 为什么需要这个脚本：轻舟 v0.7 起有了数据库抽象层（src/db.cj + src/db_mysql.cj），
# MySQL 后端在**编译期零驱动依赖**、运行时按注册名查找驱动。所以要用 MySQL，
# 必须另备一个驱动并把它链进来 —— 本脚本就是把 server\third_party\mariadb-driver
# 编成 `.cjo` + 静态库，供服务端 / admin 链接。
#
# 产物（默认 server\build\mysql-driver\）：
#   mariadb.protocol.cjo   + mariadb.protocol      （协议层）
#   mariadb.connection.cjo + mariadb.connection    （连接层）
#   mariadb.cdbc.cjo       + mariadb.cdbc          （CDBC 接口层，qingzhou 的 db_mysql.cj 用这个）
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\build-mysql-driver.ps1
#   powershell ... -File .\build-mysql-driver.ps1 -CangjieHome <SDK 1.2.0> -Stdx <stdx 1.1.3.1>
#
# 注意（2026-09-19 实测）：
#   · 驱动是纯仓颉实现（自己实现 MySQL 协议），不需要 libmysqlclient 之类的 C 库；
#     但认证用到 OpenSSL 3 的 crypto **动态库**，运行时必须在 PATH 里（本仓库沿用
#     build.ps1 找的那份 Git for Windows 的 mingw64\bin，或 third_party\qingzhou\deps\openssl）。
#   · 驱动的 cjpm.toml **没有声明 stdx 依赖**，所以 `cjpm build` 会报
#     "imports package 'stdx.crypto.digest' ... not added as a dependency"。本脚本因此
#     不走 cjpm，而是按子包（protocol → connection → cdbc）用 cjc 直编 ——
#     这也是轻舟 docs/DATABASE.md 给的备选路径。
#   · 编译 cdbc 时会报若干 `interface 'SqlDbType' is deprecated` 警告（驱动写在旧版
#     std.database.sql 之上），用 -Woff deprecated 抑制；不影响链接与运行。
#   · 链接方要**按完整文件名**链接（`-l:mariadb.cdbc` 这种写法），因为 `-lmariadb.cdbc`
#     会被 cjc 按点号拆开（实测报 `invalid file or directory '.cdbc'`）。

param(
    [string]$CangjieHome = "",
    [string]$Stdx = "",
    [string]$OutDir = ""
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$drv  = Join-Path $root "third_party\mariadb-driver"
if ([string]::IsNullOrEmpty($OutDir)) { $OutDir = Join-Path $root "build\mysql-driver" }

if (-not (Test-Path $drv)) { throw "找不到内置驱动：$drv" }

# ── 工具链探测（与 build.ps1 同口径，简化版；显式传参优先）─────────────────
if ([string]::IsNullOrEmpty($CangjieHome)) {
    foreach ($d in @((Join-Path $root "..\.tools\cangjie-1.2.0\cangjie"),
                     (Join-Path $root "..\.tools\cangjie-1.2.0\cangjie"),
                     "D:\Cangjie", "C:\Cangjie", "E:\Cangjie", (Join-Path $env:USERPROFILE "Cangjie"), $env:CANGJIE_HOME)) {
        if (-not [string]::IsNullOrEmpty($d) -and (Test-Path ([System.IO.Path]::Combine($d, "bin\cjc.exe")))) { $CangjieHome = $d; break }
    }
}
if ([string]::IsNullOrEmpty($CangjieHome)) { throw "找不到仓颉 SDK（cjc.exe）。用 -CangjieHome 显式指定。" }
$Cjc = Join-Path $CangjieHome "bin\cjc.exe"
if (-not (Test-Path $Cjc)) { throw "Cangjie compiler not found: $Cjc" }
$cjcVersion = (& $Cjc --version 2>&1 | Select-Object -First 1)
if ("$cjcVersion" -notmatch '1\.2\.0') {
    throw "This driver build requires Cangjie 1.2.0; current: $cjcVersion"
}

if ([string]::IsNullOrEmpty($Stdx)) {
    foreach ($d in @((Join-Path $root "..\.tools\stdx\windows_x86_64_cjnative\static\stdx"),
                     (Join-Path $root "..\.tools\cangjie-stdx-windows-x64-1.1.3.1\windows_x86_64_cjnative\static\stdx"),
                     "E:\cangjie\stdx\windows_x86_64_cjnative\static\stdx",
                     "D:\cangjie\stdx\windows_x86_64_cjnative\static\stdx",
                     "C:\cangjie\stdx\windows_x86_64_cjnative\static\stdx",
                     (Join-Path $env:USERPROFILE "cangjie\stdx\windows_x86_64_cjnative\static\stdx"),
                     $env:CANGJIE_STDX)) {
        if (-not [string]::IsNullOrEmpty($d) -and (Test-Path (Join-Path $d "libstdx.a"))) { $Stdx = $d; break }
    }
}
if ([string]::IsNullOrEmpty($Stdx)) { throw "找不到 stdx 的静态库（libstdx*.a）。用 -Stdx 显式指定。" }

Write-Host "[driver] cjc  = $Cjc"
Write-Host "[driver] stdx = $Stdx"
Write-Host "[driver] 源码 = $drv"
Write-Host "[driver] 产物 = $OutDir"
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

# cjc 与 stdx 版本串台会以 LLVM ERROR 的形式炸在编译中途，先钉死环境（与 build.ps1 同理由）
$env:CANGJIE_HOME = $CangjieHome
$env:PATH = (Join-Path $CangjieHome "bin") + ";" +
            (Join-Path $CangjieHome "third_party\llvm\bin") + ";" + $env:PATH

# 只取非测试源；驱动自带 *_test.cj（依赖 unittest），不进产物
function SrcOf([string]$sub, [string]$pattern) {
    $files = Get-ChildItem (Join-Path $drv "src\$sub") -Filter $pattern |
             Where-Object { $_.Name -notmatch 'test' } | ForEach-Object { $_.FullName }
    if ($files.Count -eq 0) { throw "没有找到源文件：$sub\$pattern" }
    return $files
}

# 顺序：protocol → connection → cdbc（后者依赖前者，所以前者的产物要进 --import-path）
$steps = @(
    @{ name = "mariadb.protocol";   dir = "protocol"   },
    @{ name = "mariadb.connection"; dir = "connection" },
    @{ name = "mariadb.cdbc";       dir = "cdbc"       }
)

foreach ($s in $steps) {
    $files = SrcOf $s.dir "*.cj"
    Write-Host "[driver] 编译 $($s.name)（$($files.Count) 个文件）…"
    $cargs = @($files) +
            @("--import-path", $Stdx, "--import-path", $OutDir) +
            @("-L", $Stdx, "-L", $OutDir) +
            @("-Woff", "unused", "-Woff", "deprecated", "--output-type=staticlib") +
            @("-o", (Join-Path $OutDir $s.name))
    & $Cjc @cargs
    if ($LASTEXITCODE -ne 0) { throw "编译失败：$($s.name) (exit $LASTEXITCODE)" }
}

Write-Host "[driver] 编译通过。产物："
Get-ChildItem $OutDir | Sort-Object Name | ForEach-Object {
    Write-Host ("  {0,-26} {1,10:N0} 字节" -f $_.Name, $_.Length)
}
Write-Host ""
Write-Host "[driver] 链接方用法（注意 -l: 完整文件名，不能用 -lmariadb.cdbc）："
Write-Host "  --import-path <产物目录> -L <产物目录> -l:mariadb.cdbc -l:mariadb.connection -l:mariadb.protocol"
Write-Host ""
Write-Host "[driver] 提醒：运行时还需要 ① 可达的 MySQL/MariaDB 服务器 ② OpenSSL 3 动态库在 PATH 里。"
