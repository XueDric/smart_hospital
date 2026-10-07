<#
.SYNOPSIS
    编译仓颉出站 HTTP/HTTPS spike。

.DESCRIPTION
    独立于 club-server 的构建链——只编 spike_main.cj 一个文件，
    链上 stdx（静态）+ OpenSSL + 仓颉运行时，产出自包含的 build\spike.exe。

    为什么单独一套：spike 要验的是「裸 stdx.net.http + stdx.net.tls 能不能调 HTTPS」，
    而轻舟的 httpclient.cj 没有 TLS 入口（其文件头写明"需要 TLS 请直接用 stdx.net.http.Client"）。
    所以这里刻意不引轻舟，避免它把结论搅浑。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
#>
[CmdletBinding()]
param(
    [string]$CangjieHome = "D:\Cangjie",
    [string]$Stdx        = "E:\cangjie\stdx\windows_x86_64_cjnative\static\stdx",
    [string]$DllSource   = ""
)
# $DllSource 留空时自动指向 club-server 的构建输出：4 个 DLL 直接从那里借
# （同一套工具链，已验证可用），省得再复制一份。

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

if ([string]::IsNullOrEmpty($DllSource)) {
    $DllSource = Join-Path (Split-Path -Parent (Split-Path -Parent $here)) "server\build"
}

$Cjc    = Join-Path $CangjieHome "bin\cjc.exe"
$outDir = Join-Path $here "build"
$exe    = Join-Path $outDir "spike.exe"

Write-Host "[spike] cjc    = $Cjc"
Write-Host "[spike] stdx   = $Stdx"
Write-Host "[spike] dlls   = $DllSource"

if (-not (Test-Path $Cjc))  { throw "找不到编译器：$Cjc" }
if (-not (Test-Path $Stdx)) { throw "找不到 stdx：$Stdx" }
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

# 必须重写 CANGJIE_HOME 并把 SDK 自带的 LLVM 前置到 PATH，否则 cjc 会去拉
# cjenv 那个 1.0.5 SDK 的 opt.exe，与 stdx 1.1.3.1 串台，症状是：
#   LLVM ERROR: Broken module found ... @llvm.cj.get.vtable.func / opt.exe 崩溃(0xC000001D)
# 极易被误判成"编译器 bug"。同 server\build.ps1 的做法。
$env:CANGJIE_HOME = $CangjieHome
$env:PATH = (Join-Path $CangjieHome "bin") + ";" +
            (Join-Path $CangjieHome "third_party\llvm\bin") + ";" + $env:PATH

$ver = (& $Cjc --version 2>&1 | Select-Object -First 1)
Write-Host "[spike] 版本   = $ver"

# 链接全部 stdx 静态库（与 server\build.ps1 同样的 -l:完整文件名 口径，
# 不能写 -lstdx.net.http —— 会被按点号拆开）
$libs = (Get-ChildItem "$Stdx\libstdx*.a" | ForEach-Object { "-l:$($_.Name)" })

$src = Join-Path $here "spike_main.cj"

& $Cjc $src --import-path $Stdx -L $Stdx @libs -lcrypt32 -Woff unused -o $exe
if ($LASTEXITCODE -ne 0) { throw "编译失败 (exit $LASTEXITCODE)" }
Write-Host "[spike] 编译通过 -> $exe"

# 自包含：exe 旁边必须有运行时 + OpenSSL。
#
# ⚠ 运行时 DLL 必须与**编译器同代**：1.2.0 的 libcangjie-runtime.dll 是 1,297,408 字节，
#   1.1.3 的是 1,276,416 字节 —— 拿旧运行时装新编译器编出的 exe 是错配。
#   所以这两个从 $CangjieHome 的 runtime 目录取（与 server\build.ps1 的 $RuntimeDir 同口径）。
#   OpenSSL 两个 DLL 与编译器版本无关，仍从 $DllSource 借。
#   （缺 OpenSSL 时编译期无警告，运行到 TLS 才报
#     "Can not load openssl library or function CRYPTO_get_ex_new_index"）
$RuntimeDir = Join-Path $CangjieHome "runtime\lib\windows_x86_64_cjnative"
$dlls = @(
    @{ n = "libcangjie-runtime.dll"; d = $RuntimeDir },
    @{ n = "libboundscheck.dll";     d = $RuntimeDir },
    @{ n = "libcrypto-3-x64.dll";    d = $DllSource  },
    @{ n = "libssl-3-x64.dll";       d = $DllSource  }
)
foreach ($item in $dlls) {
    $s = Join-Path $item.d $item.n
    if (Test-Path $s) {
        Copy-Item $s (Join-Path $outDir $item.n) -Force
    } else {
        Write-Warning "缺少 $($item.n)（在 $($item.d) 里找不到）—— 运行时会报错"
    }
}
Write-Host "[spike] DLL 就位（运行时取自 $RuntimeDir）"
