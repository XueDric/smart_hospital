# 把运行时依赖 DLL 放到 exe 旁边（每次干净构建后跑一次）
#
# 为什么需要它：仓颉产物是「exe + 4 个 DLL」，缺一个的典型症状是
#   运行时 CryptoException: Can not load openssl library or function SHA256_Init
# —— 而这个错**编译期毫无提示**（搬迁前的 API 踩坑记录 坑 2）。
#
# ⚠ 含中文的 PowerShell 脚本必须 UTF-8 with BOM（PS 5.1 否则按 ANSI 解析 → 语法报错）。
#
# ── 2026-10-14 复查（SERVER-REVIEW-2026-10-14 §D1 / §D2）后的两处改动 ────────
#  D1: 候选数组里**不能**裸调 `Join-Path $env:CANGJIE_HOME ...`。
#      数组字面量在进入 foreach 之前就整体求值，$env:CANGJIE_HOME 为空时
#      Join-Path 直接抛 ParameterBindingValidationException（空 Path），
#      整个脚本中止 ⇒ 「运行时 DLL 复制被静默跳过」，症状是服务端起不来却查不到原因。
#      ⇒ 现在一律走 Join-HospPathSafe（空 Base 返回 ""），候选为空串时被跳过。
#      ⚠ 顺带一个**实测**得到的语义修正：本机 $env:CANGJIE_HOME 指向的是 1.2.0 的
#        cjenv 目录，而 build\ 里现役的 libcangjie-runtime.dll 与 **D:\Cangjie（1.1.3）**
#        哈希一致。所以 CANGJIE_HOME 派生路径**只能当兜底候选，不能排在前面** ——
#        否则"改个脚本"就会偷偷把 build 里的运行时换个版本。
#  D2: 4 个 DLL 的候选路径统一走 Resolve-HospPath（参数 > 环境变量 > 候选落点 > 兜底递归），
#      找不到时把**实际搜索过的全部路径**打印出来再退出，不再只写一句"找不到"。

param(
    [string]$OutDir = "",
    # D2：路径参数化。默认值与你机器上的现状一致，本机流程不受影响。
    [string]$CangjieHome = "",   # 仓颉 SDK 根目录（含 runtime\lib\windows_x86_64_cjnative）
    [string]$StdxHome = "",      # stdx 根目录（含 windows_x86_64_cjnative\dynamic\stdx）
    [string]$OpenSslDir = ""     # OpenSSL 3 的 DLL 所在目录（qingzhou build / target\release\bin）
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
if ([string]::IsNullOrEmpty($OutDir)) { $OutDir = Join-Path $root "build" }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

# 统一入口（D2）：Resolve-HospPath / Join-HospPathSafe 都来自 tests\common.ps1。
# 少了它就直接失败 —— 不静默退化成本地另写一份（那又是"同一事实存两份"）。
$commonPs1 = Join-Path $root "tests\common.ps1"
if (-not (Test-Path -LiteralPath $commonPs1)) {
    throw "缺少共用脚本 $commonPs1（提供 Resolve-HospPath / Join-HospPathSafe，无法解析运行时 DLL 路径）"
}
. $commonPs1

# 兜底递归根目录（原逻辑的搜索根，保留）。
$recurseRoots = @(
    "D:\Cangjie", "D:\cangjie", "C:\Cangjie", "C:\cangjie", "E:\cangjie",
    (Join-HospPathSafe $env:USERPROFILE ".cjenv")
)
# $env:CANGJIE_HOME 派生路径：只在非空时才作为**兜底候选**追加（D1 的正解）。
$cangjieHomeCandidates = @()
# ⚠ D1 正解：这里**先判空再拼接**（Join-HospPathSafe 内部就是 IsNullOrEmpty 短路），
#   $env:CANGJIE_HOME 为空时得到 ""，既不抛绑定异常、也不会污染候选列表。
# （HOSP_CANGJIE_HOME 已由下面的 EnvPaths 处理，这里不重复。）
foreach ($h in @($CangjieHome, $env:CANGJIE_HOME)) {
    $p = Join-HospPathSafe $h "runtime\lib\windows_x86_64_cjnative\libcangjie-runtime.dll"
    if (-not [string]::IsNullOrEmpty($p)) { $cangjieHomeCandidates += $p }
}
$stdxHomeCandidates = @()
foreach ($h in @($StdxHome)) {
    $p = Join-HospPathSafe $h "windows_x86_64_cjnative\dynamic\stdx\libboundscheck.dll"
    if (-not [string]::IsNullOrEmpty($p)) { $stdxHomeCandidates += $p }
}
$osslDirCandidates = @()
foreach ($d in @($OpenSslDir)) {
    foreach ($n in @('libcrypto-3-x64.dll', 'libssl-3-x64.dll')) {
        $p = Join-HospPathSafe $d $n
        if (-not [string]::IsNullOrEmpty($p)) { $osslDirCandidates += $p }
    }
}

# 需要就位的 4 个运行时 DLL。按"候选路径"逐个找 —— 不同机器来源不同。
$wanted = @(
    @{ Name = 'libcangjie-runtime.dll'
       EnvPaths = @(
           @{ Var = 'HOSP_CANGJIE_HOME'; Sub = 'runtime\lib\windows_x86_64_cjnative\libcangjie-runtime.dll' }
       )
       Candidates = @(
           "D:\Cangjie\runtime\lib\windows_x86_64_cjnative\libcangjie-runtime.dll",
           "D:\cangjie\runtime\lib\windows_x86_64_cjnative\libcangjie-runtime.dll",
           "C:\Cangjie\runtime\lib\windows_x86_64_cjnative\libcangjie-runtime.dll",
           "C:\cangjie\runtime\lib\windows_x86_64_cjnative\libcangjie-runtime.dll"
       ) + $cangjieHomeCandidates },
    @{ Name = 'libboundscheck.dll'
       EnvPaths = @(
           @{ Var = 'HOSP_STDX_HOME'; Sub = 'windows_x86_64_cjnative\dynamic\stdx\libboundscheck.dll' }
       )
       Candidates = @(
           "E:\cangjie\stdx\windows_x86_64_cjnative\dynamic\stdx\libboundscheck.dll",
           "D:\cangjie\stdx\windows_x86_64_cjnative\dynamic\stdx\libboundscheck.dll",
           "C:\Cangjie\stdx\windows_x86_64_cjnative\dynamic\stdx\libboundscheck.dll",
           "C:\cangjie\stdx\windows_x86_64_cjnative\dynamic\stdx\libboundscheck.dll"
       ) + $stdxHomeCandidates },
    @{ Name = 'libcrypto-3-x64.dll'
       EnvPaths = @(@{ Var = 'HOSP_OPENSSL_DIR' })
       Candidates = @(
           "E:\cangjie\qingzhou\build\libcrypto-3-x64.dll",
           "E:\cangjie\qingzhou\target\release\bin\libcrypto-3-x64.dll"
       ) + $osslDirCandidates },
    @{ Name = 'libssl-3-x64.dll'
       EnvPaths = @(@{ Var = 'HOSP_OPENSSL_DIR' })
       Candidates = @(
           "E:\cangjie\qingzhou\build\libssl-3-x64.dll",
           "E:\cangjie\qingzhou\target\release\bin\libssl-3-x64.dll"
       ) + $osslDirCandidates }
)

$missing = 0
foreach ($w in $wanted) {
    $dest = Join-Path $OutDir $w.Name
    if (Test-Path $dest) {
        Write-Host "[runtime] 已有 $($w.Name)"
        continue
    }
    # D2：找不到时 Resolve-HospPath -Optional 会把"搜索过的全部路径"打进告警里。
    $found = Resolve-HospPath `
        -EnvPaths $w.EnvPaths `
        -Candidates $w.Candidates `
        -RecurseRoots $recurseRoots `
        -FindName $w.Name `
        -Type File `
        -What "运行时 DLL $($w.Name)" `
        -Hint "用 -CangjieHome / -StdxHome / -OpenSslDir 指定目录，或设 `$env:HOSP_CANGJIE_HOME / `$env:HOSP_STDX_HOME / `$env:HOSP_OPENSSL_DIR。" `
        -Optional
    if ($null -eq $found) {
        Write-Warning "[runtime] 找不到 $($w.Name) —— 服务端可能起不来（OpenSSL/运行时缺库）"
        $missing = $missing + 1
        continue
    }
    Copy-Item $found -Destination $dest -Force
    Write-Host "[runtime] $($w.Name)  <- $found"
}

if ($missing -gt 0) {
    Write-Warning "[runtime] $missing 个 DLL 没找到（上面每个都列出了实际搜索过的路径）。请手工把仓颉 runtime 与 OpenSSL 3 的 DLL 放到 $OutDir"
    exit 1
}
Write-Host "[runtime] ✅ 4 个运行时 DLL 已就位：$OutDir"
