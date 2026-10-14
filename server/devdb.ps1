# 仓库自管的开发数据库（server\devdb）—— 启停脚本
#
# 规格与理由见 docs\DEV-DB.md。
# 与本机另一台实例（3307）**完全隔离**：本实例用 3317、独立数据目录。
#
# ⚠ 含中文的 PowerShell 脚本必须 UTF-8 with BOM（PS 5.1 否则按 ANSI 解析 → 语法报错）。
#
# 用法：
#   .\devdb.ps1 init     初始化数据目录（只在没有时做）
#   .\devdb.ps1 start    启动（自动 init）
#   .\devdb.ps1 stop     停止
#   .\devdb.ps1 status   看状态
#   .\devdb.ps1 reset    停 + 删数据目录（会二次确认）
# 可选参数：-MariaDbHome <目录>、-Port、-RootPassword、-AppUser、-AppPassword、-ShowPassword
#
# ── 2026-10-14 复查（SERVER-REVIEW-2026-10-14 §D2 / §D3）后的改动 ────────────
#  D2: MariaDB 安装目录不再写死 "E:\cangjie\mariadb\…"，改为走 tests\common.ps1 的
#      Resolve-HospPath（参数 > $env:HOSP_MARIADB_HOME > 候选落点 > 兜底递归），
#      找不到时把**实际搜索过的全部路径**打出来再失败。
#  D3: ① Invoke-Status 之前写死 `-phospital_dev_2026`、且 `2>$null` 把 MySQL 的
#         stderr 全吞了 —— 口令一改就只看到"库："后面空空如也，看不出是**登录失败**。
#         现在口令来自参数，stderr 原样捕获并在失败时打印（附退出码）。
#      ② `:91` 打印的 DSN 含**明文口令**（终端回滚、截图、CI 日志都会把它带走）。
#         现在默认打码成 `mysql://hospital:***@…`，要明文得显式加 -ShowPassword。
#         注：这**不是**在保护什么秘密（口令本来就写在 docs\DEV-DB.md 里），
#         而是不让它**顺手**漏进日志与截图 —— 少一次"无意的扩散"。

param(
    [Parameter(Position=0)]
    [ValidateSet('init','start','stop','status','reset')]
    [string]$Action = 'status',

    [string]$MariaDbHome = "",
    [int]$Port = 3317,
    # root 口令：给 init（mysql_install_db）用。
    [string]$RootPassword = "devroot2026",
    # 应用账号：给 status 查询用（默认值与 docs\DEV-DB.md / docs\FRONTEND-INTEGRATION.md 一致）。
    [string]$AppUser = "hospital",
    [string]$AppPassword = "hospital_dev_2026",
    # D3②：默认**打码**打印 DSN，显式加这个开关才打明文。
    [switch]$ShowPassword
)

$ErrorActionPreference = "Stop"

$serverDir = $PSScriptRoot
$devdb     = Join-Path $serverDir "devdb"
$dataDir   = Join-Path $devdb "data"
$outLog    = Join-Path $devdb "mysqld.out.log"
$errLog    = Join-Path $devdb "mysqld.err.log"

# 共用路径解析入口（D2）。缺了就直接失败，不静默退化成本地另写一份。
$commonPs1 = Join-Path $serverDir "tests\common.ps1"
if (-not (Test-Path -LiteralPath $commonPs1)) {
    throw "缺少共用脚本 $commonPs1（提供 Resolve-HospPath / Join-HospPathSafe / ConvertFrom-HospNativeOutput）"
}
. $commonPs1

# MariaDB 二进制（D2）：显式参数 > $env:HOSP_MARIADB_HOME > 候选落点 > 兜底递归。
# ⚠ 与本机另一台实例**共用同一套二进制**（只是数据目录与端口不同），所以不需要再下一份。
$mariaBin = ""
if (-not [string]::IsNullOrEmpty($MariaDbHome)) {
    $mariaBin = Join-HospPathSafe $MariaDbHome "bin"
    if (-not (Test-Path -LiteralPath $mariaBin)) {
        throw ("-MariaDbHome 指向的目录下没有 bin\（找不到 mysqld.exe）。`n" +
               "  已搜索：`n    - $mariaBin    ← 参数 -MariaDbHome=$MariaDbHome`n" +
               "  提示：传 MariaDB 的**安装根目录**（其下应有 bin\mysqld.exe）。")
    }
} else {
    $mysqldExe = Resolve-HospPath `
        -EnvPaths @(@{ Var = 'HOSP_MARIADB_HOME'; Sub = 'bin\mysqld.exe' }) `
        -Candidates @(
            "E:\cangjie\mariadb\mariadb-11.4.13-winx64\bin\mysqld.exe",
            "D:\cangjie\mariadb\mariadb-11.4.13-winx64\bin\mysqld.exe",
            "C:\cangjie\mariadb\mariadb-11.4.13-winx64\bin\mysqld.exe",
            (Join-HospPathSafe $env:ProgramFiles 'MariaDB 11.4\bin\mysqld.exe'),
            (Join-HospPathSafe ${env:ProgramFiles(x86)} 'MariaDB 11.4\bin\mysqld.exe')
        ) `
        -RecurseRoots @(
            "E:\cangjie\mariadb", "D:\cangjie\mariadb", "C:\cangjie\mariadb",
            (Join-HospPathSafe $env:ProgramFiles 'MariaDB 11.4')
        ) `
        -FindName 'mysqld.exe' `
        -Type File `
        -What "MariaDB 服务端 mysqld.exe" `
        -Hint "用 -MariaDbHome <安装根目录> 指定，或设 `$env:HOSP_MARIADB_HOME。"
    $mariaBin = Split-Path -Parent $mysqldExe
    $MariaDbHome = Split-Path -Parent $mariaBin
}
$mysqld = Join-Path $mariaBin "mysqld.exe"
$mysql  = Join-Path $mariaBin "mariadb.exe"
$installDb = Join-Path $mariaBin "mysql_install_db.exe"

function Get-DevDbProcess {
    Get-CimInstance Win32_Process -Filter "Name='mysqld.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*$dataDir*" }
}

function Test-Listening {
    $null -ne (Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
               Where-Object { $_.LocalPort -eq $Port })
}

# D3①：跑一条查询并**同时**返回退出码 + stderr 文本（不再 2>$null）。
# ⚠ 调用外部命令期间临时把 $ErrorActionPreference 切到 'Continue'
#   （否则原生命令写 stderr 会被当成错误记录、配上顶部 'Stop' 直接中断脚本），
#   用完立刻还原；并且**必须**看 $LASTEXITCODE —— 否则失败又被当成成功。
function Invoke-DevDbQuery {
    param(
        [Parameter(Mandatory=$true)][string]$User,
        [Parameter(Mandatory=$true)][string]$Password,
        [Parameter(Mandatory=$true)][string]$Sql
    )
    $cliArgs = @("-h", "127.0.0.1", "-P", "$Port", "-u", $User, "-p$Password", "--skip-ssl", "-N", "-B", "-e", $Sql)
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $raw = @()
    $code = 0
    try {
        $raw = & $mysql $cliArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedEap
    }
    $text = @(ConvertFrom-HospNativeOutput -Raw $raw)
    return [pscustomobject]@{
        ExitCode = $code
        Lines    = $text
        Out      = (($text -join "`n").Trim())
    }
}

function Invoke-Init {
    if (Test-Path (Join-Path $dataDir "mysql")) {
        Write-Host "[devdb] 数据目录已存在，跳过初始化：$dataDir"
        return
    }
    if (-not (Test-Path $installDb)) { throw "找不到 mysql_install_db.exe：$installDb" }
    New-Item -ItemType Directory -Path $devdb -Force | Out-Null
    Write-Host "[devdb] 初始化数据目录：$dataDir（端口 $Port）"
    & $installDb --datadir="$dataDir" --password="$RootPassword" --port=$Port
    if ($LASTEXITCODE -ne 0) { throw "初始化失败（exit $LASTEXITCODE）" }
    Write-Host "[devdb] ✅ 初始化完成"
}

function Invoke-Start {
    Invoke-Init
    if ((Get-DevDbProcess) -or (Test-Listening)) {
        Write-Host "[devdb] 已在运行（端口 $Port）"
        return
    }
    Write-Host "[devdb] 启动 mysqld（端口 $Port，仅绑 127.0.0.1）…"
    # ★ `--bind-address=127.0.0.1` 是**安全必需**，不是可选优化：
    #   本实例的 root 口令**公开写在仓库文档里**（开发用，见 docs\DEV-DB.md），
    #   若监听 0.0.0.0，同一局域网内任何人都能用这串口令连上来。
    #   实测：不加此参数时它监听 `0.0.0.0:$Port`（`Get-NetTCPConnection` 可见），
    #   只靠账号的 host 授权（'hospital'@'localhost'）兜着 —— 那是**单层**防护，
    #   一旦有人补了 `@'%'` 账号就对外敞开。绑回环是**结构性**隔离。
    Start-Process -FilePath $mysqld `
        -ArgumentList @("--datadir=$dataDir", "--port=$Port", "--console",
                        "--basedir=$MariaDbHome", "--bind-address=127.0.0.1") `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog -WindowStyle Hidden
    # 等就绪：轮询端口，最多 ~30s
    $ok = $false
    foreach ($i in 1..30) {
        Start-Sleep -Seconds 1
        if (Test-Listening) { $ok = $true; break }
    }
    if ($ok) {
        Write-Host "[devdb] ✅ 已启动：127.0.0.1:$Port（数据目录 $dataDir）"
        # D3②：默认打码 —— 口令不该"顺手"进终端回滚 / 截图 / CI 日志。
        if ($ShowPassword) {
            Write-Host "[devdb]    DSN: mysql://${AppUser}:$AppPassword@127.0.0.1:$Port/hospital_test"
        } else {
            Write-Host "[devdb]    DSN: mysql://${AppUser}:***@127.0.0.1:$Port/hospital_test    （加 -ShowPassword 显示明文）"
        }
    } else {
        Write-Host "[devdb] ❌ 启动超时。错误日志末尾："
        Get-Content $errLog -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -Last 10 |
            ForEach-Object { "    $_" }
        exit 1
    }
}

function Invoke-Stop {
    $procs = Get-DevDbProcess
    if (-not $procs) { Write-Host "[devdb] 没有在运行的 devdb 实例"; return }
    foreach ($p in $procs) {
        Write-Host "[devdb] 停止 PID $($p.ProcessId)…"
        Stop-Process -Id $p.ProcessId -Force
    }
    Start-Sleep -Seconds 3
    Write-Host "[devdb] ✅ 已停止"
}

function Invoke-Status {
    $p = Get-DevDbProcess
    $listen = Test-Listening
    Write-Host "[devdb] 数据目录 : $dataDir  (存在=$(Test-Path $dataDir))"
    Write-Host "[devdb] 二进制   : $mysqld  (存在=$(Test-Path $mysqld))"
    Write-Host "[devdb] 进程     : $(if($p){"PID $($p.ProcessId -join ',')"}else{'未运行'})"
    Write-Host "[devdb] 端口 $Port : $(if($listen){'在监听'}else{'未监听'})"
    if (-not $listen) { return }

    # D3①：口令来自参数（不再是写死的 -phospital_dev_2026），
    #       并且**不再吞 stderr** —— 失败时把退出码与客户端原文都报出来。
    # 先按应用账号查；不行再退回 root（本机两套账号都在，见 docs\DEV-DB.md）。
    $accounts = @(
        @{ Name = '应用账号'; User = $AppUser; Pass = $AppPassword },
        @{ Name = 'root';     User = 'root';   Pass = $RootPassword }
    )
    $failures = New-Object System.Collections.ArrayList
    $ok = $null
    $okWho = ""
    foreach ($a in $accounts) {
        $r = Invoke-DevDbQuery -User $a.User -Password $a.Pass -Sql "SHOW DATABASES"
        if ($r.ExitCode -eq 0) { $ok = $r; $okWho = "$($a.Name) [$($a.User)]"; break }
        [void]$failures.Add("  - 以 $($a.Name) [$($a.User)] 查询失败（exit $($r.ExitCode)）：`n$($r.Lines | ForEach-Object { "      $_" } | Out-String)".TrimEnd())
    }

    if ($null -ne $ok) {
        $dbs = ($ok.Out -split "`n" | Where-Object { $_.Trim().Length -gt 0 }) -join ', '
        Write-Host "[devdb] 库       : $dbs   （连接账号：$okWho）"
    } else {
        Write-Warning "[devdb] 端口在监听，但查库失败。MySQL 客户端的 stderr **未被吞掉**，原文如下："
        foreach ($f in $failures) { Write-Warning $f }
        Write-Warning "[devdb] 提示：口令与默认值不同时用 -AppUser/-AppPassword（应用账号）或 -RootPassword（root）指定。"
    }
}

switch ($Action) {
    'init'   { Invoke-Init }
    'start'  { Invoke-Start }
    'stop'   { Invoke-Stop }
    'status' { Invoke-Status }
    'reset'  {
        Write-Host "[devdb] ⚠ reset 会**删除** $dataDir 里的全部数据。"
        $ans = Read-Host "[devdb] 确认请输入 yes"
        if ($ans -ne 'yes') { Write-Host "[devdb] 已取消"; exit 0 }
        Invoke-Stop
        if (Test-Path $dataDir) { Remove-Item -LiteralPath $dataDir -Recurse -Force }
        Write-Host "[devdb] ✅ 已删除数据目录（下次 start 会重新初始化）"
    }
}
