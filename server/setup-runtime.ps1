# 把运行时依赖 DLL 放到 exe 旁边（每次干净构建后跑一次）
#
# 为什么需要它：仓颉产物是「exe + 4 个 DLL」，缺一个的典型症状是
#   运行时 CryptoException: Can not load openssl library or function SHA256_Init
# —— 而这个错**编译期毫无提示**（基线 API-NOTES 坑 2）。
#
# ⚠ 含中文的 PowerShell 脚本必须 UTF-8 with BOM（PS 5.1 否则按 ANSI 解析 → 语法报错）。

param(
    [string]$OutDir = ""
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
if ([string]::IsNullOrEmpty($OutDir)) { $OutDir = Join-Path $root "build" }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

# 需要就位的 4 个运行时 DLL。按"候选路径"逐个找 —— 不同机器来源不同。
$wanted = @(
    @{ Name = 'libcangjie-runtime.dll'; Candidates = @(
        "D:\Cangjie\runtime\lib\windows_x86_64_cjnative\libcangjie-runtime.dll",
        "C:\Cangjie\runtime\lib\windows_x86_64_cjnative\libcangjie-runtime.dll",
        (Join-Path $env:CANGJIE_HOME "runtime\lib\windows_x86_64_cjnative\libcangjie-runtime.dll")
      ) },
    @{ Name = 'libboundscheck.dll'; Candidates = @(
        "E:\cangjie\stdx\windows_x86_64_cjnative\dynamic\stdx\libboundscheck.dll",
        "D:\cangjie\stdx\windows_x86_64_cjnative\dynamic\stdx\libboundscheck.dll"
      ) },
    @{ Name = 'libcrypto-3-x64.dll'; Candidates = @(
        "E:\cangjie\qingzhou\build\libcrypto-3-x64.dll",
        "E:\cangjie\qingzhou\target\release\bin\libcrypto-3-x64.dll"
      ) },
    @{ Name = 'libssl-3-x64.dll'; Candidates = @(
        "E:\cangjie\qingzhou\build\libssl-3-x64.dll",
        "E:\cangjie\qingzhou\target\release\bin\libssl-3-x64.dll"
      ) }
)

$missing = 0
foreach ($w in $wanted) {
    $dest = Join-Path $OutDir $w.Name
    if (Test-Path $dest) {
        Write-Host "[runtime] 已有 $($w.Name)"
        continue
    }
    $found = $null
    foreach ($c in $w.Candidates) {
        if (-not [string]::IsNullOrEmpty($c) -and (Test-Path $c)) { $found = $c; break }
    }
    if ($null -eq $found) {
        # 兜底：在常见根目录里搜一遍
        foreach ($r in @("D:\Cangjie", "C:\Cangjie", "E:\cangjie", (Join-Path $env:USERPROFILE ".cjenv"))) {
            if (Test-Path $r) {
                $hit = Get-ChildItem $r -Recurse -File -Filter $w.Name -ErrorAction SilentlyContinue |
                       Select-Object -First 1
                if ($null -ne $hit) { $found = $hit.FullName; break }
            }
        }
    }
    if ($null -eq $found) {
        Write-Warning "[runtime] 找不到 $($w.Name) —— 服务端可能起不来（OpenSSL/运行时缺库）"
        $missing = $missing + 1
        continue
    }
    Copy-Item $found -Destination $dest -Force
    Write-Host "[runtime] $($w.Name)  <- $found"
}

if ($missing -gt 0) {
    Write-Warning "[runtime] $missing 个 DLL 没找到。请手工把仓颉 runtime 与 OpenSSL 3 的 DLL 放到 $OutDir"
    exit 1
}
Write-Host "[runtime] ✅ 4 个运行时 DLL 已就位：$OutDir"
