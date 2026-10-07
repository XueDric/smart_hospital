# 仓库自管的开发数据库（server\devdb）—— 启停脚本
#
# 规格与理由见 docs\DEV-DB.md。
# 与社团那台（3307）**完全隔离**：本实例用 3317、独立数据目录。
#
# ⚠ 含中文的 PowerShell 脚本必须 UTF-8 with BOM（PS 5.1 否则按 ANSI 解析 → 语法报错）。
#
# 用法：
#   .\devdb.ps1 init     初始化数据目录（只在没有时做）
#   .\devdb.ps1 start    启动（自动 init）
#   .\devdb.ps1 stop     停止
#   .\devdb.ps1 status   看状态
#   .\devdb.ps1 reset    停 + 删数据目录（会二次确认）

param(
    [Parameter(Position=0)]
    [ValidateSet('init','start','stop','status','reset')]
    [string]$Action = 'status',

    [string]$MariaDbHome = "",
    [int]$Port = 3317,
    [string]$RootPassword = "devroot2026"
)

$ErrorActionPreference = "Stop"

$serverDir = $PSScriptRoot
$devdb     = Join-Path $serverDir "devdb"
$dataDir   = Join-Path $devdb "data"
$outLog    = Join-Path $devdb "mysqld.out.log"
$errLog    = Join-Path $devdb "mysqld.err.log"

# MariaDB 二进制：显式参数 > 环境变量 > 本机默认落点。
# ⚠ 与社团那台**共用同一套二进制**（只是数据目录与端口不同），所以不需要再下一份。
if ([string]::IsNullOrEmpty($MariaDbHome)) {
    if ($env:HOSP_MARIADB_HOME) { $MariaDbHome = $env:HOSP_MARIADB_HOME }
    else { $MariaDbHome = "E:\cangjie\mariadb\mariadb-11.4.13-winx64" }
}
$mysqld = Join-Path $MariaDbHome "bin\mysqld.exe"
$mysql  = Join-Path $MariaDbHome "bin\mariadb.exe"
$installDb = Join-Path $MariaDbHome "bin\mysql_install_db.exe"

function Get-DevDbProcess {
    Get-CimInstance Win32_Process -Filter "Name='mysqld.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*$dataDir*" }
}

function Test-Listening {
    $null -ne (Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
               Where-Object { $_.LocalPort -eq $Port })
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
        Write-Host "[devdb]    DSN: mysql://hospital:hospital_dev_2026@127.0.0.1:$Port/hospital_test"
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
    if ($listen) {
        $n = & $mysql -h 127.0.0.1 -P $Port -u hospital "-phospital_dev_2026" --skip-ssl -N -B -e "SHOW DATABASES" 2>$null
        Write-Host "[devdb] 库       : $($n -join ', ')"
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
