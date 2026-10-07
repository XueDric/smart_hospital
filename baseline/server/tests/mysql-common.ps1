# mysql-common.ps1 —— 测试脚本共用的一小块 MySQL 辅助（2026-09-20）
#
# 为什么要有这个文件：club-server 的持久化从"一个临时数据目录里的 db.json"换成了
# **MySQL**（路线 B，见 docs\club-server-mysql-assessment.md），于是每个会启动
# club-server 的测试脚本都必须：① 找到 MySQL 客户端；② 检测可连性；③ 用一个
# **专用测试库**并把它的 7 张业务表清空当夹具。
# 这三件事在四个脚本（smoke / tls-check / client-contract-check / ops-check）里
# 一模一样，抄四遍就是四份会各自漂移的代码 —— 所以抽到这里，用法是 dot-source：
#
#     . (Join-Path $PSScriptRoot "mysql-common.ps1")
#     $my = Initialize-MySqlTestEnv -DefaultDb "club_smoke"
#
# ⚠ 绝不碰正式库：调用方传进来的库名（club_smoke / club_tls / club_contract / club_ops_e2e）
#   都是**测试专用**的，且 Initialize-MySqlTestEnv 会 DROP 掉其中的 club 业务表。
#   连接参数默认取本机的便携版 MariaDB（127.0.0.1:3307 / root / clubroot123，
#   见 docs\mysql-backend.md §7），可用环境变量覆盖：
#     CLUB_MYSQL_HOST / CLUB_MYSQL_PORT / CLUB_MYSQL_USER / CLUB_MYSQL_PASS / CLUB_MYSQL_DB
#     CLUB_MYSQL_CLI（mariadb.exe 的完整路径）/ CLUB_MARIADB_HOME（便携版根目录）
#     CLUB_MYSQL_USE_SSL=1（取消默认的 --skip-ssl，让客户端走真实 TLS）
#
# 2026-10-04 起：调客户端时**默认加 `--skip-ssl`**，且**不再吞掉客户端 stderr**
# （此前 `2>NUL` 会把"TLS/SSPI 握手失败"误报成"连不上 MySQL / 口令不对"，
#   7 个依赖 MySQL 的套件全部中止在夹具阶段，方向常常是错的）。
# 要测真实 TLS 就设 CLUB_MYSQL_USE_SSL=1。

function Find-ClubMySqlCli {
    foreach ($c in @("mariadb.exe", "mysql.exe")) {
        $g = Get-Command $c -ErrorAction SilentlyContinue
        if ($null -ne $g) { return $g.Source }
    }
    if ($env:CLUB_MYSQL_CLI -and (Test-Path $env:CLUB_MYSQL_CLI)) { return $env:CLUB_MYSQL_CLI }
    $cands = @()
    if ($env:CLUB_MARIADB_HOME) { $cands += (Join-Path $env:CLUB_MARIADB_HOME "bin\mariadb.exe") }
    $cands += @(
        "E:\cangjie\mariadb\mariadb-11.4.13-winx64\bin\mariadb.exe",
        "D:\cangjie\mariadb\mariadb-11.4.13-winx64\bin\mariadb.exe",
        "C:\mariadb\bin\mariadb.exe",
        "C:\Program Files\MariaDB 11.4\bin\mariadb.exe",
        "C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe"
    )
    # 便携版目录名带版本号，换个版本就找不到 —— 再模糊找一层
    foreach ($r in @("E:\cangjie\mariadb", "D:\cangjie\mariadb")) {
        if (Test-Path $r) {
            $hits = Get-ChildItem $r -Directory -ErrorAction SilentlyContinue |
                    ForEach-Object { Join-Path $_.FullName "bin\mariadb.exe" } |
                    Where-Object { Test-Path $_ }
            if ($hits) { return ($hits | Select-Object -First 1) }
        }
    }
    foreach ($c in $cands) { if (Test-Path $c) { return $c } }
    return $null
}

# 把 [可执行文件路径, 参数…] 拼成一条 cmd 能认的命令行（每段都用双引号包住）。
function Join-ClubCmdLine([string]$exe, [string[]]$argv) {
    $parts = @(('"' + $exe + '"'))
    foreach ($a in $argv) { $parts += ('"' + ($a -replace '"', '\"') + '"') }
    return ($parts -join ' ')
}

# 客户端的 SSL 参数：**默认加 `--skip-ssl`**（2026-10-04）。
#
# 现象：某些 Windows 环境下客户端 TLS/SSPI 握手失败 ——
#   `ERROR 2026 (HY000): TLS/SSL error: no credentials. Error 0x8009030E(SEC_E_NO_CREDENTIALS)`
# 而**库完全可达**（同口令加 --skip-ssl 立刻连上）。要真实 TLS 就设 CLUB_MYSQL_USE_SSL=1。
function Get-ClubSslArgs {
    if ($env:CLUB_MYSQL_USE_SSL -eq "1") { return @() }
    return @("--skip-ssl")
}

# 跑一次 mysql/mariadb 客户端：**返回干净的 stdout**（调用方要按值/按行解析结果），
# stderr **落到临时文件**并保留在 `$script:ClubMySqlLastErr`，供失败时原样打印。
#
# ⚠ 为什么必须经 `cmd /c ...`，而不是 PowerShell 的 `2>$null`（踩过，值得记下来）：
#   四个调用方大多设了 `$ErrorActionPreference = "Stop"`。PS 5.1 在**捕获**原生命令输出时，
#   只要 stderr 非空就会造一条 NativeCommandError —— 在 Stop 下**直接终止脚本**；
#   而且实测 `2>$null` **压不住它**（stderr 被重定向了，但错误记录已经产生）。
#   症状：`DROP TABLE IF EXISTS` 在"表本来就不存在"时的那句 information 提示
#   （`--------------` 之类）会让整个测试在**夹具准备阶段**就崩，看起来还像 MySQL 坏了。
#   绕开的办法是在 **cmd 那一层**做重定向 —— 那时 PowerShell 根本看不到 stderr。
#
# ⚠ 2026-10-04 改：stderr 不再丢给 NUL，而是**存进临时文件**。
#   丢弃的代价是把"客户端 TLS/SSPI 握手失败"这类**有明确指向的报错**一起丢了，
#   上层只能看到 `$LASTEXITCODE -ne 0`，于是误报成"连不上 / 口令不对"。
#   ⚠ 为什么**不**把 stderr 并进 stdout（`2>&1`）：调用方里有**严格解析** ——
#   例如 `(...).Trim() -eq '1'`、`[int](...)`、把返回值当注册口令用（smoke / tls /
#   bench / init-name-check）—— 客户端一旦往 stderr 说话，那些断言就被污染，
#   而这台机器上没有可连的库、污染在本机测不出来。所以 stdout 必须干净，报错另走一路。
function Invoke-ClubClient([string[]]$argv) {
    $errFile = [IO.Path]::GetTempFileName()
    $line = (Join-ClubCmdLine $script:ClubMySqlCli $argv) + ' 2>"' + $errFile + '"'
    $out = (& cmd /c $line | Out-String)
    $script:ClubMySqlLastErr = ""
    if (Test-Path $errFile) {
        $script:ClubMySqlLastErr = [IO.File]::ReadAllText($errFile)
        Remove-Item $errFile -Force -ErrorAction SilentlyContinue
    }
    return $out
}

function Test-ClubMySqlConn([string]$h, [int]$p, [string]$u, [string]$pw) {
    if ([string]::IsNullOrEmpty($script:ClubMySqlCli)) { return $false }
    $a = @("-h", $h, "-P", "$p", "-u", $u, "--protocol=tcp", "--batch",
           "--skip-column-names", "--connect-timeout=5")
    $a += Get-ClubSslArgs
    if ($pw.Length -gt 0) { $a += "-p$pw" }
    $a += @("-e", "SELECT 1")
    $out = Invoke-ClubClient $a
    # 留给调用方打印（连接失败时这段原始报错就是唯一的线索）
    $script:ClubMySqlLastOut = $out
    return ($LASTEXITCODE -eq 0 -and $out -match '1')
}

# 在某个库上跑一句 SQL。返回值是 stdout（查询结果）。
function Invoke-ClubMySql([string]$sql, [string]$db) {
    $a = @("-h", $script:ClubDbHost, "-P", "$script:ClubDbPort", "-u", $script:ClubDbUser,
           "--protocol=tcp", "--batch", "--skip-column-names", "--connect-timeout=5")
    $a += Get-ClubSslArgs
    if ($script:ClubDbPass.Length -gt 0) { $a += "-p$script:ClubDbPass" }
    $a += @("-e", "CREATE DATABASE IF NOT EXISTS $db CHARACTER SET utf8mb4;")
    $null = Invoke-ClubClient $a
    $b = @("-h", $script:ClubDbHost, "-P", "$script:ClubDbPort", "-u", $script:ClubDbUser,
           "--protocol=tcp", "--batch", "--skip-column-names", "--connect-timeout=5")
    $b += Get-ClubSslArgs
    if ($script:ClubDbPass.Length -gt 0) { $b += "-p$script:ClubDbPass" }
    $b += @($db, "-e", $sql)
    return (Invoke-ClubClient $b)
}

# 清掉 club-server 的 9 张表（7 张业务表 + 2 张元数据表）—— 制造"空库"夹具。
# 表不存在时 DROP 是空操作，所以这个函数在"库是全新的"时同样安全。
function Reset-ClubMySqlSchema([string]$db) {
    $tables = @("departments", "members", "plans", "tasks", "invite_links", "tokens",
                "idem", "meta", "meta_str")
    $sql = ($tables | ForEach-Object { "DROP TABLE IF EXISTS $_;" }) -join " "
    $null = Invoke-ClubMySql $sql $db
}

# 统一的"没有 MySQL 就没法测"出口：中文说明 + 非零退出（**不静默跳过**）
function Fail-ClubMySqlMissing([string]$scriptName, [string]$reason) {
    Write-Host ""
    Write-Host "FAIL  $scriptName：$reason" -ForegroundColor Red
    Write-Host "      club-server 的持久化自 2026-09-20 起就是 **MySQL**，没有可连的库时"
    Write-Host "      「数据到底写没写进去」根本没有答案 —— 所以这里是**失败**，不是跳过。"
    Write-Host "      起一台本机 MariaDB（便携版、不装 Windows 服务）："
    Write-Host "        & `"<MariaDB>\bin\mysqld.exe`" --datadir=`"<数据目录>`" --port=3307 --console"
    Write-Host "      或按 admin-check.ps1 / ops-check.ps1 的做法设环境变量："
    Write-Host "        `$env:CLUB_MARIADB_HOME 或 `$env:CLUB_MYSQL_CLI / CLUB_MYSQL_HOST / CLUB_MYSQL_PORT /"
    Write-Host "        CLUB_MYSQL_USER / CLUB_MYSQL_PASS"
    Write-Host "      详见 docs\mysql-backend.md 与 docs\local-deploy.md。"
    Write-Host ""
    exit 1
}

# 统一入口：解析连接参数 → 检查客户端与可连性（失败即退出）→ 返回 @{ Dsn = ... }
function Initialize-MySqlTestEnv {
    param([string]$DefaultDb = "club_test")

    $script:ClubDbHost = if ($env:CLUB_MYSQL_HOST) { $env:CLUB_MYSQL_HOST } else { "127.0.0.1" }
    $script:ClubDbPort = if ($env:CLUB_MYSQL_PORT) { [int]$env:CLUB_MYSQL_PORT } else { 3307 }
    $script:ClubDbUser = if ($env:CLUB_MYSQL_USER) { $env:CLUB_MYSQL_USER } else { "root" }
    $script:ClubDbPass = if ($null -ne $env:CLUB_MYSQL_PASS) { $env:CLUB_MYSQL_PASS } else { "clubroot123" }
    $db = if ($env:CLUB_MYSQL_DB) { $env:CLUB_MYSQL_DB } else { $DefaultDb }

    $script:ClubMySqlCli = Find-ClubMySqlCli
    if ([string]::IsNullOrEmpty($script:ClubMySqlCli)) {
        Fail-ClubMySqlMissing "找不到 MySQL 客户端（mariadb.exe / mysql.exe）" `
            "已在 PATH / CLUB_MYSQL_CLI / CLUB_MARIADB_HOME / 常见安装位置里找过，都没有。"
    }
    if (-not (Test-ClubMySqlConn $script:ClubDbHost $script:ClubDbPort $script:ClubDbUser $script:ClubDbPass)) {
        # 2026-10-04：**把客户端的原始报错打出来**。此前 stderr 被 `2>NUL` 丢掉，
        # 只剩一句"连不上 / 口令不对" —— 真凶却往往是客户端 TLS/SSPI 握手。
        $detail = @()
        if ($script:ClubMySqlLastOut) { $detail += $script:ClubMySqlLastOut.Trim() }
        if ($script:ClubMySqlLastErr) { $detail += $script:ClubMySqlLastErr.Trim() }
        if ($detail.Count -gt 0) {
            Write-Host "客户端原始输出（$script:ClubMySqlCli）：" -ForegroundColor Yellow
            foreach ($d in $detail) { Write-Host $d -ForegroundColor Yellow }
            if (($detail -join "`n") -match 'TLS/SSL|SSL error|SEC_E_NO_CREDENTIALS') {
                Write-Host "      ↑ 这看着是**客户端 TLS/握手**问题，不是口令问题：本脚本默认已加 --skip-ssl；" -ForegroundColor Yellow
                Write-Host "        若你显式设过 `$env:CLUB_MYSQL_USE_SSL=1，先去掉它再试。" -ForegroundColor Yellow
            }
        }
        Fail-ClubMySqlMissing "连不上 MySQL（$script:ClubDbUser@$script:ClubDbHost`:$script:ClubDbPort）" `
            "客户端是 $script:ClubMySqlCli，但连不上或账号口令不对（原始报错见上）。"
    }

    $dsn = "mysql://$script:ClubDbUser`:$script:ClubDbPass@$script:ClubDbHost`:$script:ClubDbPort/$db"
    Write-Host "MySQL    : $script:ClubDbUser@$script:ClubDbHost`:$script:ClubDbPort  库 $db（测试专用）"
    return @{ Dsn = $dsn; Db = $db; Host = $script:ClubDbHost; Port = $script:ClubDbPort
              User = $script:ClubDbUser; Pass = $script:ClubDbPass; Cli = $script:ClubMySqlCli }
}