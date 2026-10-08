# 测试脚本共用：从 DSN 解析出 MySQL 客户端参数
#
# ── 为什么要有这个文件（2026-10-07）────────────────────────────────────────
# 原先每个测试脚本都各自维护一套连接参数：
#     -Dsn "mysql://…@127.0.0.1:3317/hospital"   ← 给服务端用
#     -MySqlPort 3317 / -MySqlDb "hospital_test"  ← 给脚本里的 SQL 夹具用
# 两者**互相独立**，于是很容易「服务端写 A 库、脚本查 B 库」——
# 实测就这么踩了：断言一直读到空结果，而失败现象看起来像 SQL 坏了。
# 这跟复查指出的「数字/口径不一致」是同一类毛病：**同一事实存了两份**。
#
# 现在统一以 `-Dsn` 为**唯一事实来源**，从它派生客户端参数。
#
# 用法（在脚本里 dot-source）：
#     . "$PSScriptRoot\common.ps1"
#     $my = Get-MySqlClientArgs -Dsn $Dsn
#     & $my.Client -h $my.DbHost -P $my.Port -u $my.User "-p$($my.Pass)" --skip-ssl $my.Db -N -B -e "SELECT 1"

function Get-MySqlClientArgs {
    param([Parameter(Mandatory=$true)][string]$Dsn)

    # 解析 mysql://user:pass@host:port/db
    # 与 Cangjie 侧 parseDsn 保持同一口径：@ 取**最后一个**、用户口令在**第一个** `:` 拆。
    $s = $Dsn
    if ($s -match '^mysql://') { $s = $s.Substring(8) }
    $slash = $s.LastIndexOf('/')
    if ($slash -lt 0) { throw "DSN 缺少库名：$Dsn" }
    $authority = $s.Substring(0, $slash)
    $db = $s.Substring($slash + 1)
    $at = $authority.LastIndexOf('@')
    if ($at -lt 0) { throw "DSN 缺少 '@'：$Dsn" }
    $userinfo = $authority.Substring(0, $at)
    $hostport = $authority.Substring($at + 1)

    $user = $userinfo
    $pass = ''
    $colon = $userinfo.IndexOf(':')
    if ($colon -ge 0) {
        $user = $userinfo.Substring(0, $colon)
        $pass = $userinfo.Substring($colon + 1)
    }

    $dbHost = $hostport
    $port = 3306
    $hc = $hostport.LastIndexOf(':')
    if ($hc -ge 0) {
        $dbHost = $hostport.Substring(0, $hc)
        $p = $hostport.Substring($hc + 1)
        if ($p.Length -gt 0) { $port = [int]$p }
    }
    if ([string]::IsNullOrEmpty($dbHost)) { $dbHost = '127.0.0.1' }

    # 客户端二进制：允许环境变量覆盖（不同机器便携包落点不同）
    $client = 'E:\cangjie\mariadb\mariadb-11.4.13-winx64\bin\mariadb.exe'
    if ($env:HOSP_MYSQL_CLIENT) { $client = $env:HOSP_MYSQL_CLIENT }

    return [pscustomobject]@{
        Client = $client
        DbHost = $dbHost
        Port   = $port
        User   = $user
        Pass   = $pass
        Db     = $db
        Dsn    = $Dsn
    }
}

# 跑一条 SQL，返回标量字符串；**SELECT 无返回行时明确告警**而不是静默返回空。
# ⚠ `(& native ...)` 在查询无行时得到 $null，直接 .Trim() 会报
#   「不能对 Null 值表达式调用方法」—— 那个报错完全没提"SQL 没查到行"，
#   很容易被带去查错方向。这里统一包一层。
#
# ⚠⚠ 但 **DELETE / UPDATE / INSERT 本来就不返回行集**（它们返回受影响行数，
#   而客户端默认不回显）—— 对它们告警是**假警报**。实测踩到：
#   限流测试脚本里每清一次计数就打一行"SQL 未返回任何行"，把真正的输出淹了。
#   所以这里按语句类型分流：
#     · SELECT → 无行 = 异常，告警
#     · 其它   → 无行 = 正常，静默返回 ""
function Invoke-MySqlScalar {
    param(
        [Parameter(Mandatory=$true)]$My,
        [Parameter(Mandatory=$true)][string]$Sql,
        [string]$Label = "scalar"
    )
    # 库名为空时**不传**库名（管理员 DSN 常常不带库名，而 DROP/GRANT 不需要当前库）
    $cliArgs = @("-h", $My.DbHost, "-P", "$($My.Port)", "-u", $My.User, "-p$($My.Pass)", "--skip-ssl")
    if ($My.Db) { $cliArgs += $My.Db }
    $cliArgs += @("-N", "-B", "-e", $Sql)
    $raw = & $My.Client $cliArgs 2>&1
    if ($null -eq $raw -or "$raw".Trim().Length -eq 0) {
        if ($Sql.TrimStart().ToUpper().StartsWith("SELECT")) {
            Write-Warning "  SQL 未返回任何行（$Label，库 $($My.Db)）：$Sql"
        }
        return ""
    }
    return "$raw".Trim()
}

# 执行一个 .sql 文件（用 source）。
function Invoke-MySqlFile {
    param(
        [Parameter(Mandatory=$true)]$My,
        [Parameter(Mandatory=$true)][string]$Path
    )
    & $My.Client -h $My.DbHost -P $My.Port -u $My.User "-p$($My.Pass)" --skip-ssl $My.Db -e "source $Path" | Out-Null
}
