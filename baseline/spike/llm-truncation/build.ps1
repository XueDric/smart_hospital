<#
.SYNOPSIS
    Build the AI-2 truncation probe (ASCII-only on purpose: PowerShell 5.1
    mis-decodes non-ASCII .ps1 files that lack a UTF-8 BOM).

.DESCRIPTION
    Compiles probe.cj against stdx (static) + OpenSSL + the Cangjie runtime.
    Deliberately NOT built with the qingzhou snapshot: the probe *replicates*
    the framework's read loop verbatim so the defect can be demonstrated
    without MySQL, without the server, and without auth.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
#>
[CmdletBinding()]
param(
    [string]$CangjieHome = "C:\Users\ASUS\.cjenv\sdks\1.2.0\cangjie",
    [string]$Stdx        = "E:\cangjie\stdx\windows_x86_64_cjnative\static\stdx",
    [string]$DllSource   = ""
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrEmpty($DllSource)) {
    $DllSource = Join-Path (Split-Path -Parent (Split-Path -Parent $here)) "server\build"
}

$Cjc    = Join-Path $CangjieHome "bin\cjc.exe"
$outDir = Join-Path $here "build"
$exe    = Join-Path $outDir "probe.exe"

if (-not (Test-Path $Cjc))  { throw "cjc not found: $Cjc" }
if (-not (Test-Path $Stdx)) { throw "stdx not found: $Stdx" }
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

# CANGJIE_HOME must point at the real SDK, otherwise cjc picks up the wrong
# opt.exe and dies with "LLVM ERROR: Broken module found".
$env:CANGJIE_HOME = $CangjieHome
$env:PATH = (Join-Path $CangjieHome "bin") + ";" +
            (Join-Path $CangjieHome "third_party\llvm\bin") + ";" + $env:PATH

Write-Host "[probe] cjc = $((& $Cjc --version 2>&1 | Select-Object -First 1))"

$libs = (Get-ChildItem "$Stdx\libstdx*.a" | ForEach-Object { "-l:$($_.Name)" })
$src  = Join-Path $here "probe.cj"

& $Cjc $src --import-path $Stdx -L $Stdx @libs -lcrypt32 -Woff unused -o $exe
if ($LASTEXITCODE -ne 0) { throw "compile failed (exit $LASTEXITCODE)" }
Write-Host "[probe] compiled -> $exe"

# Runtime DLLs must match the compiler generation; OpenSSL is borrowed.
$RuntimeDir = Join-Path $CangjieHome "runtime\lib\windows_x86_64_cjnative"
foreach ($item in @(
    @{ n = "libcangjie-runtime.dll"; d = $RuntimeDir },
    @{ n = "libboundscheck.dll";     d = $RuntimeDir },
    @{ n = "libcrypto-3-x64.dll";    d = $DllSource  },
    @{ n = "libssl-3-x64.dll";       d = $DllSource  }
)) {
    $s = Join-Path $item.d $item.n
    if (Test-Path $s) { Copy-Item $s (Join-Path $outDir $item.n) -Force }
    else { Write-Warning "missing $($item.n) in $($item.d)" }
}
Write-Host "[probe] dlls ready"
