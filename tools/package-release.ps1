<#
.SYNOPSIS
  智慧医院服务端「可运行程序包」打包脚本（Windows x64）。

.DESCRIPTION
  把 server\build\ 下编译出来的 hospital-server.exe + 运行时 DLL + 管理台静态资源
  收成一个 zip，解压即用：改配置 → 起库 → 双击 / 命令行启动。

  流程：
    ① 停掉正在跑的 hospital-server（否则编译输出被占用）
    ② 调 server\build.ps1 真编译（-SkipBuild 时跳过，复用已有产物）
    ③ 按 server\build\ 的**实际内容**收集文件（不硬编码文件名）
       + server\admin-web\（管理台静态资源，存在才收；缺了它 /admin 与 --prod 不可用）
    ④ 生成 README-运行说明.txt（UTF-8 with BOM，PS 5.1 下不乱码）
    ⑤ 打 zip → $OutDir\hospital-server-<Version>-win-x64.zip
    ⑥ 打印包内清单与体积

  幂等：重复跑覆盖旧包（旧的 staging 目录与 zip 都会被清掉）。
  失败：非 0 退出并打印原因（stdout/stderr 都能看到）。

  注意：
    · `release\` 是**生成物，通常不入库**（仓库 `.gitignore:81-82` 已收录 `release/`；本脚本不碰 .gitignore）。
    · 含中文的 .ps1 必须 UTF-8 with BOM（PowerShell 5.1 否则按 ANSI 解析 → Unexpected token）。
    · 仓颉编译器必须是 1.2.0（PATH 上的 1.1.3 会 LLVM ERROR: Broken module found），
      server\build.ps1 会自己挑版本并校验。
    · 路径含非 ASCII 时（本仓库已改名为 smart_hospital，纯 ASCII），**运行** exe 仍需用 ASCII 路径的副本；
      证书路径同理（cangjie 运行时无法接受含非 ASCII 的 argv）。

.PARAMETER OutDir
  产物目录，默认 <仓库根>\release（相对路径按仓库根解析）。

.PARAMETER Version
  版本串，默认从 server\src\main.cj 的 SERVER_VERSION 读；
  读不到就用 git 短 SHA；再不行用 dev。

.PARAMETER SkipBuild
  跳过 server\build.ps1，直接拿 server\build\ 里的现有产物打包。

.EXAMPLE
  .\tools\package-release.ps1

.EXAMPLE
  .\tools\package-release.ps1 -Version 0.2.0-p1 -OutDir D:\dist

.EXAMPLE
  .\tools\package-release.ps1 -SkipBuild
#>
[CmdletBinding()]
param(
    [string]$OutDir = 'release',
    [string]$Version = '',
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'

$total = [System.Diagnostics.Stopwatch]::StartNew()

function Write-Step([string]$msg) { Write-Host "[package] $msg" }
function Write-Ok([string]$msg) { Write-Host "[package] ✅ $msg" -ForegroundColor Green }
function Write-Warn2([string]$msg) { Write-Host "[package] ⚠ $msg" -ForegroundColor Yellow }
function Fail([string]$msg) {
    Write-Host "[package] ❌ $msg" -ForegroundColor Red
    exit 1
}

# ── 0. 路径 ──────────────────────────────────────────────────────────────
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$serverDir = Join-Path $repoRoot 'server'
$buildDir = Join-Path $serverDir 'build'
$buildScript = Join-Path $serverDir 'build.ps1'
$adminWebDir = Join-Path $serverDir 'admin-web'
$exeName = 'hospital-server.exe'
$appName = 'hospital-server'

if (-not (Test-Path -LiteralPath $serverDir)) { Fail "找不到服务端目录：$serverDir" }

if ([System.IO.Path]::IsPathRooted($OutDir)) {
    $outAbs = $OutDir
} else {
    $outAbs = Join-Path $repoRoot $OutDir
}

Write-Step "仓库根：$repoRoot"
Write-Step "产物目录：$outAbs"

# ── 1. 版本 ─────────────────────────────────────────────────────────────
function Resolve-PackageVersion {
    param([string]$Explicit)

    if (-not [string]::IsNullOrWhiteSpace($Explicit)) {
        return $Explicit.Trim()
    }

    # ① 源码里的版本串（server\src\main.cj: public let SERVER_VERSION: String = "0.2.0-p1"）
    $mainCj = Join-Path $serverDir 'src\main.cj'
    if (Test-Path -LiteralPath $mainCj) {
        $m = Select-String -LiteralPath $mainCj -Pattern 'SERVER_VERSION\s*:\s*String\s*=\s*"([^"]+)"' -Encoding UTF8 |
            Select-Object -First 1
        if ($m -and $m.Matches.Count -gt 0) {
            $v = $m.Matches[0].Groups[1].Value.Trim()
            if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
        }
    }

    # ② git 短 SHA
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        $oldEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $sha = (& git -C $repoRoot rev-parse --short HEAD 2>$null | Out-String).Trim()
        } catch {
            $sha = ''
        }
        $ErrorActionPreference = $oldEap
        if ($sha -match '^[0-9a-fA-F]{6,40}$') { return $sha }
    }

    return 'dev'
}

$versionText = Resolve-PackageVersion -Explicit $Version
# 文件名安全化（版本串里若带 / \ : * ? " < > | 就换成 -）
$versionSafe = ($versionText -replace '[\\/:*?"<>|\s]+', '-').Trim('-')
if ([string]::IsNullOrWhiteSpace($versionSafe)) { $versionSafe = 'dev' }

$packageName = "$appName-$versionSafe-win-x64"
$zipPath = Join-Path $outAbs "$packageName.zip"
$stagingDir = Join-Path $outAbs ".staging-$packageName"

Write-Step "版本：$versionText（用于文件名：$versionSafe）"

# ── 2. 停掉正在跑的实例（否则编译输出被占用）──────────────────────────────
$running = @(Get-Process -Name 'hospital-server' -ErrorAction SilentlyContinue)
if ($running.Count -gt 0) {
    Write-Warn2 "发现 $($running.Count) 个 hospital-server 进程，先停掉（否则编译输出被占用）"
    foreach ($p in $running) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch {
            Write-Warn2 "停 pid=$($p.Id) 失败：$($_.Exception.Message)"
        }
    }
    Start-Sleep -Milliseconds 800
} else {
    Write-Step '没有正在运行的 hospital-server'
}

# ── 3. 编译 ─────────────────────────────────────────────────────────────
$exePath = Join-Path $buildDir $exeName
if ($SkipBuild) {
    Write-Warn2 '-SkipBuild：跳过 server\build.ps1，复用现有产物'
    if (-not (Test-Path -LiteralPath $exePath)) {
        Fail "-SkipBuild 但找不到 $exePath；先不带 -SkipBuild 跑一次，删掉 server\build 后产物就没了"
    }
} else {
    if (-not (Test-Path -LiteralPath $buildScript)) { Fail "找不到构建脚本：$buildScript" }
    Write-Step '开始编译（server\build.ps1，仓颉 cjc + stdx 静态链接，通常 1~3 分钟）…'
    $buildSw = [System.Diagnostics.Stopwatch]::StartNew()
    & $buildScript
    $buildCode = $LASTEXITCODE
    $buildSw.Stop()
    if ($null -ne $buildCode -and $buildCode -ne 0) {
        Fail "server\build.ps1 失败（exit=$buildCode，耗时 $([math]::Round($buildSw.Elapsed.TotalSeconds,1))s）。常见原因：cjc 版本不是 1.2.0 / 编译输出被占用 / 缺 stdx"
    }
    Write-Ok "编译完成，耗时 $([math]::Round($buildSw.Elapsed.TotalSeconds,1))s"
    if (-not (Test-Path -LiteralPath $exePath)) {
        Fail "编译结束但没看到 $exePath —— 构建脚本可能改了输出路径"
    }
}

# ── 3b. 运行时 DLL ──────────────────────────────────────────────────────
# server\build.ps1 只产 exe；4 个运行时 DLL 由 server\setup-runtime.ps1 放到输出目录
# （缺 DLL 的典型症状：运行时 CryptoException: Can not load openssl library or function SHA256_Init，
#   编译期毫无提示）。
$requiredDlls = @('libcangjie-runtime.dll', 'libboundscheck.dll', 'libcrypto-3-x64.dll', 'libssl-3-x64.dll')
function Get-MissingDlls {
    @($requiredDlls | Where-Object { -not (Test-Path -LiteralPath (Join-Path $buildDir $_)) })
}
$missingDlls = Get-MissingDlls
if ($missingDlls.Count -gt 0) {
    Write-Step ("缺运行时 DLL：" + ($missingDlls -join '、') + " → 调 server\setup-runtime.ps1")
    $setupScript = Join-Path $serverDir 'setup-runtime.ps1'
    if (-not (Test-Path -LiteralPath $setupScript)) { Fail "找不到 $setupScript（缺 DLL 就没法打包）" }
    & $setupScript -OutDir $buildDir
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        Fail "setup-runtime.ps1 失败（exit=$LASTEXITCODE）：缺 OpenSSL 3 运行时 DLL 或仓颉运行时 DLL"
    }
    $still = Get-MissingDlls
    if ($still.Count -gt 0) {
        Fail ("setup-runtime.ps1 跑完了仍缺：" + ($still -join '、') + "；用 -OpenSslDir 手工指一个含 libcrypto-3-x64.dll 的目录")
    }
    Write-Ok '运行时 DLL 已就位'
} else {
    Write-Step '运行时 DLL 已齐（4 个）'
}

# ── 4. 收集文件（按实际目录内容，不硬编码）──────────────────────────────
if (-not (Test-Path -LiteralPath $buildDir)) { Fail "找不到构建输出目录：$buildDir" }

$collected = @()   # 每项：@{ Rel = 'hospital-server.exe'; Src = 绝对路径 }
# 只收 build\ **顶层**文件：exe + 4 个运行时 DLL + SOURCE-MANIFEST.sha256。
# 排除：① 子目录（如 build\mysql-driver\ 的 .cjo/.a）② 顶层 *.cjo —— 都是**编译/链接中间产物**，
# 内容已经进 exe，打进包里只会白占容积。③ *.log（跑过一次就有的运行日志）
# ④ *.pem / *.key —— 信任锚/私钥**绝不能随包分发**（可能含企业内网根），由目标机现场生成。
$buildFiles = @(Get-ChildItem -LiteralPath $buildDir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -ne '.cjo' -and $_.Extension -ne '.log' -and
                   $_.Extension -ne '.pem' -and $_.Extension -ne '.key' })
$skippedDirs = @(Get-ChildItem -LiteralPath $buildDir -Directory -ErrorAction SilentlyContinue)
$skippedCjo = @(Get-ChildItem -LiteralPath $buildDir -File -Filter '*.cjo' -ErrorAction SilentlyContinue)
if ($buildFiles.Count -eq 0) { Fail "构建输出目录里没有文件：$buildDir" }
$skipNotes = @()
if ($skippedDirs.Count -gt 0) { $skipNotes += ("子目录：" + (($skippedDirs | ForEach-Object { $_.Name }) -join '、')) }
if ($skippedCjo.Count -gt 0) { $skipNotes += ("*.cjo：" + (($skippedCjo | ForEach-Object { $_.Name }) -join '、')) }
if ($skipNotes.Count -gt 0) {
    Write-Step ("跳过编译中间产物（不进包）→ " + ($skipNotes -join '；'))
}

foreach ($f in $buildFiles) {
    $rel = $f.FullName.Substring($buildDir.Length).TrimStart('\', '/')
    $collected += @{ Rel = $rel; Src = $f.FullName }
}
Write-Step "从 server\build\ 收集 $($buildFiles.Count) 个文件"

# 出站 HTTPS 的信任锚脚本：仓颉 stdx 走 OpenSSL，不读 Windows 证书存储，
# 没有信任锚时 AI 出站会报 `certificate verify failed (134), unknown CA`。
# 包内**带脚本不帶导出的 PEM**（PEM 可能含企业内网根证书，必须目标机现场生成）。
$caScriptSrc = Join-Path $repoRoot 'server\export-ca-bundle.ps1'
if (Test-Path -LiteralPath $caScriptSrc) {
    $collected += @{ Rel = 'export-ca-bundle.ps1'; Src = $caScriptSrc }
    Write-Step "收集 CA 导出脚本 → export-ca-bundle.ps1"
} else {
    Write-Warn2 "没有 server\export-ca-bundle.ps1 —— 包内缺 AI 出站的信任锚工具"
}

# 管理台静态资源：与 exe 同级放成 admin-web\，`hospital-server serve` 的候选目录之一
# 就是相对 CWD 的 "admin-web"（server\src\main.cj 的 pickAdminWebDir）。
# 缺了它 /admin 不可用，且 --prod 会拒绝启动。
if (Test-Path -LiteralPath $adminWebDir) {
    $awFiles = @(Get-ChildItem -LiteralPath $adminWebDir -File -Recurse -ErrorAction SilentlyContinue)
    foreach ($f in $awFiles) {
        $relInner = $f.FullName.Substring($adminWebDir.Length).TrimStart('\', '/')
        $collected += @{ Rel = ('admin-web/' + ($relInner -replace '\\', '/')); Src = $f.FullName }
    }
    Write-Step "收集管理台静态资源 $($awFiles.Count) 个文件 → admin-web\"
} else {
    Write-Warn2 "没有 server\admin-web\ —— 包内不会有管理台，/admin 与 --prod 都不可用"
}

# ── 5. staging ──────────────────────────────────────────────────────────
if (Test-Path -LiteralPath $stagingDir) {
    Remove-Item -LiteralPath $stagingDir -Recurse -Force
}
New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null
New-Item -ItemType Directory -Path $outAbs -Force | Out-Null

foreach ($item in $collected) {
    $dest = Join-Path $stagingDir ($item.Rel -replace '/', '\')
    $destDir = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }
    Copy-Item -LiteralPath $item.Src -Destination $dest -Force
}

# ── 5b. 许可证与第三方声明 ──────────────────────────────────────────────
# 为什么单独一步：源码树根有 LICENSE，
# 但用户拿到的是 zip，解压后看不到任何许可与第三方归属信息，等于交付物不合规。
# 这里把 ① 本项目许可证 ② 第三方归属（NOTICE）③ 第三方审计文档 ④ 两份 vendored
# 组件的许可证全文 一起放进包内 licenses\，与 zip 同生命周期。
$licenseFiles = @()

$rootLicense = Join-Path $repoRoot 'LICENSE'
if (-not (Test-Path -LiteralPath $rootLicense)) { Fail "找不到 $rootLicense（分发包必须带许可证）" }
Copy-Item -LiteralPath $rootLicense -Destination (Join-Path $stagingDir 'LICENSE.txt') -Force
$licenseFiles += 'LICENSE.txt'

$thirdPartyDoc = Join-Path $repoRoot 'docs\THIRD-PARTY.md'
if (Test-Path -LiteralPath $thirdPartyDoc) {
    Copy-Item -LiteralPath $thirdPartyDoc -Destination (Join-Path $stagingDir 'THIRD-PARTY.md') -Force
    $licenseFiles += 'THIRD-PARTY.md'
} else {
    Write-Warn2 '没有 docs\THIRD-PARTY.md —— 包内不会有第三方清单'
}

# vendored 组件的许可证全文（Apache-2.0 要求随分发附带 LICENSE 与 NOTICE）
$licDir = Join-Path $stagingDir 'licenses'
New-Item -ItemType Directory -Path $licDir -Force | Out-Null
$vendored = @(
    @{ Src = (Join-Path $serverDir 'third_party\qingzhou\LICENSE');          Rel = 'licenses\qingzhou-LICENSE.txt' },
    @{ Src = (Join-Path $serverDir 'third_party\mariadb-driver\LICENSE');    Rel = 'licenses\mariadb-driver-LICENSE.txt' },
    @{ Src = (Join-Path $serverDir 'third_party\openssl\LICENSE.txt');       Rel = 'licenses\openssl-LICENSE.txt' },
    @{ Src = (Join-Path $serverDir 'third_party\openssl\NOTICE.txt');        Rel = 'licenses\openssl-NOTICE.txt' },
    @{ Src = (Join-Path $serverDir 'third_party\cangjie-runtime\LICENSE.txt'); Rel = 'licenses\cangjie-runtime-LICENSE.txt' },
    @{ Src = (Join-Path $serverDir 'third_party\cangjie-runtime\NOTICE.txt'); Rel = 'licenses\cangjie-runtime-NOTICE.txt' }
)
foreach ($v in $vendored) {
    if (Test-Path -LiteralPath $v.Src) {
        Copy-Item -LiteralPath $v.Src -Destination (Join-Path $stagingDir $v.Rel) -Force
        $licenseFiles += ($v.Rel -replace '\\', '/')
    } else {
        Write-Warn2 ("缺 vendored 许可证：" + $v.Src)
    }
}

# NOTICE：归属声明 + 每个第三方组件的许可证与「用在哪」一句话，便于合规审查直接引用
$noticeText = @"
===============================================================
 智慧医院智能导诊就诊系统 (smart_hospital) $versionText · NOTICE
===============================================================

本项目自身代码以 MIT 许可证发布，全文见包内 LICENSE.txt。

本包内含以下第三方组件（源码或以静态库形式链接进 hospital-server.exe）：

1) 轻舟 QingZhou —— 仓颉 Web 框架（源码副本，构建时编译进 exe）
   ★ 本团队参与该框架的开发：路由/静态错误体可注入、数据库断链自愈与探活、
     MySQL 参数化绑定等修复由本团队提交并已并入上游（不改版权归属）。
   许可证：MIT（版权归上游）
   版权：Copyright (c) 2026 guowei, BIT FSSLab
   全文：licenses/qingzhou-LICENSE.txt
   上游：https://gitcode.com/BIT-FSSLab/QingZhou

2) MariaDB 驱动 Cangjie MySQL driver（源码副本，静态链接进 exe）
   许可证：Apache-2.0
   上游：https://gitcode.com/Cangjie-SIG/mysql-driver
   全文：licenses/mariadb-driver-LICENSE.txt
   ⚠ Apache-2.0 第 4 条：本包随附上述许可证全文；本项目对该源码副本的修改情况
     记录在仓库 server/third_party/mariadb-driver/PROVENANCE.md。

3) OpenSSL 3 运行时（libcrypto-3-x64.dll / libssl-3-x64.dll，未修改的动态链接库）
   许可证：Apache-2.0（OpenSSL 3.x）
   版权：Copyright 1998-2025 The OpenSSL Project Authors
   上游：https://www.openssl.org/source/
   全文：licenses/openssl-LICENSE.txt ｜ 归属声明：licenses/openssl-NOTICE.txt
   本包内含的软件由 OpenSSL Project 开发，用于 OpenSSL Toolkit（http://www.openssl.org/）。
   （构建机上的副本路径由 server/setup-runtime.ps1 的 -OpenSslDir 决定。）

4) Cangjie（仓颉）运行时（libcangjie-runtime.dll / libboundscheck.dll）
   许可证：Apache-2.0 **with Runtime Library Exception**
   版权：Copyright (c) 2024-2025 Huawei Device Co., Ltd.
   全文：licenses/cangjie-runtime-LICENSE.txt ｜ 归属声明：licenses/cangjie-runtime-NOTICE.txt
   说明：Runtime Library Exception 使"用仓颉编译器编译本项目"不导致本项目代码受 Apache-2.0
   约束（本项目代码仍按 MIT 发布）；随包分发的运行时 DLL 未修改。

   ⚠ 不随包分发但开发期会用到的组件见 THIRD-PARTY.md 的「不随包分发」一节：
     MariaDB 服务端（GPL-2.0，仅本地 devdb 用）、仓颉编译器、DevEco/Android SDK、JDK。

5) 管理台前端（admin-web/）为原生 HTML/CSS/JS，无前端框架依赖。

完整审计（含鸿蒙/安卓端依赖、外部 API、模型与数据集、合规边界）见 THIRD-PARTY.md。

———————————————————————————————————————————————
如发现归属遗漏或许可证不符，请按 LICENSE.txt 中的联系方式提出。
"@
$noticePath = Join-Path $stagingDir 'NOTICE.txt'
[System.IO.File]::WriteAllText($noticePath, $noticeText, (New-Object System.Text.UTF8Encoding($true)))
$licenseFiles += 'NOTICE.txt'

Write-Step ("生成许可证文件 " + $licenseFiles.Count + " 个：" + ($licenseFiles -join '、'))

# ── 5c. 双击启动用的 .cmd ───────────────────────────────────────────────
# ⚠ .cmd 内容保持**纯 ASCII**：cmd.exe 控制台按本地代码页（GBK）显示，
#   写中文在 UTF-8 文件里会变乱码。说明文字一律放在 README-运行说明.txt 里。
$cmdName = 'start-dev.cmd'
$cmdPath = Join-Path $stagingDir $cmdName
$cmdText = (@(
    '@echo off',
    'setlocal',
    'rem ============================================================',
    'rem  Smart Hospital - server launcher (dev mode)',
    'rem  Edit DSN / PORT below, then double-click this file.',
    'rem  NOTE: keep this folder on an ASCII-only path (e.g. C:\hospital).',
    'rem ============================================================',
    'set "DSN=mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital"',
    'set "PORT=8091"',
    'rem --- TLS trust for outbound AI calls ---',
    'rem  Cangjie stdx uses OpenSSL and ignores the Windows cert store.',
    'rem  Without a trust anchor HTTPS fails: certificate verify failed (134).',
    'rem  The PEM is generated on THIS machine on first run (never shipped).',
    'set "CA=%~dp0ca-bundle.pem"',
    'if not exist "%CA%" if exist "%~dp0export-ca-bundle.ps1" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0export-ca-bundle.ps1" -Out "%CA%"',
    'if exist "%CA%" set "SSL_CERT_FILE=%CA%"',
    'echo Starting hospital-server on port %PORT% ...',
    'echo Health check: http://127.0.0.1:%PORT%/health',
    '"%~dp0hospital-server.exe" serve "%DSN%" --port %PORT% --dev-auth',
    'echo.',
    'echo [server exited with code %ERRORLEVEL%]',
    'pause'
) -join "`r`n") + "`r`n"
[System.IO.File]::WriteAllText($cmdPath, $cmdText, (New-Object System.Text.UTF8Encoding($false)))
Write-Step "生成 $cmdName"

# ── 6. README-运行说明.txt（UTF-8 with BOM）──────────────────────────────
$readmeName = 'README-运行说明.txt'
$readmePath = Join-Path $stagingDir $readmeName
$buildTimeText = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$fileListText = ((@($collected | ForEach-Object { '    ' + $_.Rel }) +
                  @($licenseFiles | ForEach-Object { '    ' + $_ }) +
                  @('    ' + $cmdName)) | Sort-Object) -join "`r`n"

$readme = @"
================================================================
 智慧医院智能导诊就诊系统 · 服务端可运行包
 版本：$versionText
 打包时间：$buildTimeText
 平台：Windows x64
================================================================

一、环境要求
  · Windows 10/11 x64（或 Windows Server 2019+）
  · 无需安装 .NET / VC++ 运行库 —— 运行时 DLL 已在包内（4 个，见文末清单）
  · 数据库：MariaDB 11.4.13 或 MySQL 8.x，监听 127.0.0.1:3317（本包默认按此口径写 DSN）
  · PowerShell 5.1 以上（只为执行下面的命令；服务端本身不依赖 PowerShell）
  · 内存 ≥ 2 GB 可用、磁盘 ≥ 200 MB

二、起数据库（两步）
  1) 解压 MariaDB 便携版，初始化数据目录（只需一次；已有数据目录就跳过）：
       & <MariaDbHome>\bin\mysql_install_db.exe --datadir=<数据目录> --password=<root口令> --port=3317
  2) 启动（--bind-address 必须给，否则会监听 0.0.0.0，同网段任何人可连）：
       & <MariaDbHome>\bin\mysqld.exe --datadir=<数据目录> --port=3317 --console --bind-address=127.0.0.1
  3) 建业务账号与库（用 root 连上后执行，口令请自行替换）：
       CREATE DATABASE IF NOT EXISTS hospital DEFAULT CHARSET utf8mb4;
       CREATE USER IF NOT EXISTS 'hospital'@'localhost' IDENTIFIED BY '<业务口令>';
       GRANT ALL PRIVILEGES ON hospital.* TO 'hospital'@'localhost';
       FLUSH PRIVILEGES;
  DSN 形状：mysql://<user>:<pass>@<host>:<port>/<db>
  本机开发库示例：mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital

三、启动服务端
  ⚠ 本包所在路径若含中文，请先复制到纯 ASCII 路径（如 C:\hospital）再运行：
    仓颉运行时读不了含非 ASCII 的 argv（证书路径同理）。

  方式 A：双击（包内自带 start-dev.cmd，先改成你的 DSN / 端口再双击）
       start-dev.cmd
  方式 B：命令行（推荐，能看日志）
     cd <解压目录>
     .\hospital-server.exe serve "mysql://hospital:<口令>@127.0.0.1:3317/hospital" --dev-auth

  参数口径：
     --port N        监听端口，默认 8091（与客户端默认值一致，裸启动即可联调）
     --bind IP       绑定地址，默认 127.0.0.1（要局域网联调才 --bind 0.0.0.0）
     --dev-auth      开发模式：绕过全部鉴权（只认本机回环来源）。**生产禁用**，且不能与 --prod 同用
     --prod          生产模式：要求 dev_auth=false，且必须能挂到 admin-web 静态目录
     --tls-cert / --tls-key   给这两个参数就强制 HTTPS，证书读不到会直接退出，绝不静默降级

  生产模式（HTTPS）：
     .\hospital-server.exe serve "mysql://<user>:<pass>@<host>:3317/hospital" --port 8091 --prod `
         --tls-cert C:\hospital\tls\server.crt --tls-key C:\hospital\tls\server.key
     自签证书可由仓库里 server\new-tls-cert.ps1 生成；证书与私钥请放在 ASCII 路径下。

四、默认端口
  · 服务端默认 8091（--port 改），鸿蒙/安卓客户端默认也连 8091 —— 无需额外参数
  · 管理台与 API 同源同端口：http://127.0.0.1:<port>/admin/
  · 数据库默认 127.0.0.1:3317

五、/health 自检
  PowerShell：
    Invoke-WebRequest -Uri http://127.0.0.1:8091/health -UseBasicParsing | Select-Object -Expand Content
  curl：
    curl.exe -s http://127.0.0.1:8091/health
  语义：HTTP 200 = 进程活着**且**库通；HTTP 503 = 进程活着但库不通（响应体 db.ok=false）。
  响应里 db.reconnects 非 0 说明链路抖过并已自愈。

六、管理员初始化
  首次部署需要建一个管理员账号（口令由程序随机生成并打印一次，请立刻保存）：
    .\hospital-server.exe create-admin "mysql://hospital:<口令>@127.0.0.1:3317/hospital"

七、AI 出站（TLS 信任锚，必须做一次）
  仓颉 stdx 的 HTTPS 客户端走 **OpenSSL**，不读 Windows 证书存储。少了信任锚，
  AI 出站会失败并报：TLS handshake failed (client): certificate verify failed (134), unknown CA(F)
  —— 此时 curl.exe / PowerShell 访问同一个地址却都是 200，容易误判成"密钥错"。

  start-dev.cmd 会在首次运行时自动执行 export-ca-bundle.ps1 生成 ca-bundle.pem 并设置 SSL_CERT_FILE。
  手工做一遍（方式 B 走这条）：
     powershell -NoProfile -ExecutionPolicy Bypass -File .\export-ca-bundle.ps1
     set "SSL_CERT_FILE=%CD%\ca-bundle.pem"
     .\hospital-server.exe serve "<DSN>" --dev-auth
  验证：管理台「模型管理」里对默认对话模型点「测试」，应返回 ok=true / http_status=200。
  ⚠ ca-bundle.pem 由**本机**证书存储导出（含企业内网根），不要跨机器拷贝；
    换网络/换代理后要重新导一次。

八、升级到已存在的库
  serve 启动时会自动建表（CREATE TABLE IF NOT EXISTS）并跑幂等迁移；已有数据的库可直接换新 exe，
  重复启动不会重复改结构，也不会清数据。

九、故障排查
  1) 编译输出被占用（打包/重新编译时）：还有 hospital-server.exe 在跑
       Get-Process hospital-server | Stop-Process -Force
  2) 端口 3317 已被占用：Get-NetTCPConnection -State Listen | Where-Object LocalPort -eq 3317
       先停掉占用者，或改 --port / 改 DSN 端口
  3) CryptoException: Can not load openssl library or function SHA256_Init
       运行时 DLL 没跟 exe 放一起：确认本目录有 libcrypto-3-x64.dll / libssl-3-x64.dll
  4) Unexpected token（跑 .ps1 时）：脚本不是 UTF-8 with BOM
       用 [System.IO.File]::WriteAllText(`$p, `$text, (New-Object System.Text.UTF8Encoding(`$true))) 重存
  5) 客户端 401/403：没开 --dev-auth 却带了 X-Role/X-User-Id 头（这些头只在 --dev-auth 下认），
     或令牌过期；--dev-auth 只认 127.0.0.1 / ::1 来源，绑 0.0.0.0 后远程请求一律 401
  6) /admin/ 404：启动时没找到 admin-web 目录（本包已随包提供，请在解压目录里启动）
  7) 服务端日志有 [HEALTH] 库探活失败：先查数据库是否在跑、DSN 口令是否正确

十、包内文件清单
$fileListText
    $readmeName  （本文件）

================================================================
"@

[System.IO.File]::WriteAllText($readmePath, $readme, (New-Object System.Text.UTF8Encoding($true)))
Write-Step "生成 $readmeName（UTF-8 with BOM）"

# ── 7. 打 zip ───────────────────────────────────────────────────────────
# ⚠ 用 ZipArchive **手动逐条建条目**，而不是 ZipFile.CreateFromDirectory：
#   .NET Framework（PS 5.1）的 CreateFromDirectory 把条目分隔符写成 `\`，
#   Windows 资源管理器能解开，但 unzip / Java / macOS 的归档工具会把它当成**文件名字符**，
#   解出一堆名字里带反斜杠的文件。这里统一写成 `/`。
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

$stageFiles = @(Get-ChildItem -LiteralPath $stagingDir -File -Recurse | Sort-Object FullName)
$zipStream = [System.IO.File]::Create($zipPath)
$archive = New-Object System.IO.Compression.ZipArchive(
    $zipStream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
try {
    foreach ($f in $stageFiles) {
        $rel = ($f.FullName.Substring($stagingDir.Length).TrimStart('\', '/')) -replace '\\', '/'
        $entry = $archive.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
        $entryStream = $entry.Open()
        $srcStream = [System.IO.File]::OpenRead($f.FullName)
        try {
            $srcStream.CopyTo($entryStream)
        } finally {
            $srcStream.Dispose()
            $entryStream.Dispose()
        }
    }
} finally {
    $archive.Dispose()
    $zipStream.Dispose()
}

if (-not (Test-Path -LiteralPath $zipPath)) { Fail "打包失败：没有生成 $zipPath" }

$zipItem = Get-Item -LiteralPath $zipPath
Write-Ok "已生成 $($zipItem.FullName)"

# ── 8. 打印包内清单与体积（以 zip 内容为准）──────────────────────────────
$zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
$entries = @($zip.Entries | Sort-Object FullName)
$uncompressed = 0
Write-Host ''
Write-Host '包内文件清单：'
foreach ($e in $entries) {
    $uncompressed += $e.Length
    $kb = [math]::Round($e.Length / 1KB, 1)
    Write-Host ('  {0,-46} {1,10} KB' -f $e.FullName, $kb)
}
$zip.Dispose()

$mbSize = [math]::Round($zipItem.Length / 1MB, 2)
$mbRaw = [math]::Round($uncompressed / 1MB, 2)
$total.Stop()

Write-Host ''
Write-Host ('文件数：{0}' -f $entries.Count)
Write-Host ('压缩后体积：{0} MB' -f $mbSize)
Write-Host ('解压后体积：{0} MB' -f $mbRaw)
Write-Host ('总耗时：{0} 秒' -f [math]::Round($total.Elapsed.TotalSeconds, 1))
Write-Ok "打包完成：$zipPath"

# ── 9. 清理 staging ─────────────────────────────────────────────────────
try {
    Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction Stop
} catch {
    Write-Warn2 "清理临时目录失败（可手工删）：$stagingDir"
}

exit 0
