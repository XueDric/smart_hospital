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
#
# ── 2026-10-14 复查（SERVER-REVIEW-2026-10-14 §C3 / §D2）后补的两条铁律 ────
#  1) 本文件顶部**显式**设 $ErrorActionPreference = 'Stop'。
#     此前 :93 的注释声称"本文件顶部设了"，**实际没有** —— 等于把护栏
#     外包给调用方，哪天有人少写一行，外部命令的错误就全被吞掉。
#  2) 外部命令（mariadb.exe / mysql.exe）**必须查 $LASTEXITCODE**。
#     此前 `2>&1` 抓回来的错误文本会被当成"查询结果"原样返回：
#     SQL 报错、连不上库时，调用方拿到的是错误信息而不是数据，
#     断言于是静默失效（"不可能失败"的断言）。
#     ⇒ 现在：退出码非 0 一律**抛异常**，异常里带 Label、SQL 片段/文件路径、退出码。
#     ⚠ 只有"SELECT 没查到行"（退出码 0）保留告警语义 —— 那是查询成功、结果为空。

$ErrorActionPreference = 'Stop'

# 安全拼接：$Base 为空时**不要**调 Join-Path（PS 5.1 会抛
# ParameterBindingValidationException：无法将参数绑定到参数 'Path'，因为该参数是空值）。
# ⚠ 这就是复查 D1 在 setup-runtime.ps1 抓到的坑的**通用形态** ——
#   凡是"环境变量 + 子路径"的候选，都必须走这个函数（或本文件的 Resolve-HospPath）。
function Join-HospPathSafe {
    param([string]$Base, [string]$Leaf)
    if ([string]::IsNullOrEmpty($Base)) { return "" }
    return [System.IO.Path]::Combine($Base, $Leaf)
}

# ── 工具路径的**统一入口**（复查 D2）───────────────────────────────────────
# 优先级固定为：显式参数 > 环境变量 > 候选默认落点 > 兜底递归搜索。
# 找不到时**把实际搜索过的全部路径打印出来**再失败（throw），
# 而不是静默退化到某个不存在的路径。
#   -Optional  : 只告警并返回 $null（给"找不到也还能继续"的诊断场景用）
#   -EnvPaths  : @{ Var = 'HOSP_XXX'; Sub = 'bin\foo.exe' }；Sub 可省
#   -RecurseRoots/-FindName : 直接候选全落空后，在这些根目录下递归找该文件名
#                              （扫过的根目录也会记进"已搜索"清单 —— 慢是慢，
#                               但**不静默**：看得见它到底翻过哪儿）
function Resolve-HospPath {
    [CmdletBinding()]
    param(
        [string]$Explicit = "",
        [hashtable[]]$EnvPaths = @(),
        [string[]]$Candidates = @(),
        [string[]]$RecurseRoots = @(),
        [string]$FindName = "",
        [string]$OnPath = "",
        [ValidateSet('Any', 'File', 'Directory')]
        [string]$Type = 'Any',
        [string]$What = '路径',
        [string]$Hint = "",
        [switch]$Optional
    )

    $searched = New-Object System.Collections.ArrayList
    $ordered = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrEmpty($Explicit)) {
        [void]$ordered.Add(@{ P = $Explicit; Why = '参数显式指定' })
    }
    foreach ($ep in $EnvPaths) {
        if ($null -eq $ep -or [string]::IsNullOrEmpty([string]$ep.Var)) { continue }
        $v = [System.Environment]::GetEnvironmentVariable([string]$ep.Var)
        if ([string]::IsNullOrEmpty($v)) { continue }
        $p = $v
        if ($ep.Sub) { $p = [System.IO.Path]::Combine($v, [string]$ep.Sub) }
        [void]$ordered.Add(@{ P = $p; Why = "`$env:$($ep.Var)" })
    }
    foreach ($c in $Candidates) {
        if (-not [string]::IsNullOrEmpty($c)) {
            [void]$ordered.Add(@{ P = $c; Why = '候选默认落点' })
        }
    }

    foreach ($o in $ordered) {
        [void]$searched.Add("$($o.P)    ← $($o.Why)")
        if (-not (Test-Path -LiteralPath $o.P)) {
            # 显式参数 / 环境变量**指错地方**时要说一声：否则会静默退回到默认落点，
            # 使用者以为自己的设置生效了（"静默退化"正是 D2 要消灭的东西）。
            if ($o.Why -ne '候选默认落点') {
                Write-Warning "$What：$($o.Why) 指向的路径不存在，继续按后面的候选查找 —— $($o.P)"
            }
            continue
        }
        if ($Type -eq 'File' -and -not (Test-Path -LiteralPath $o.P -PathType Leaf)) { continue }
        if ($Type -eq 'Directory' -and -not (Test-Path -LiteralPath $o.P -PathType Container)) { continue }
        return (Resolve-Path -LiteralPath $o.P).Path
    }

    if (-not [string]::IsNullOrEmpty($OnPath)) {
        [void]$searched.Add("PATH 上的 $OnPath    ← `$env:PATH")
        $cmd = Get-Command $OnPath -ErrorAction SilentlyContinue
        if ($null -ne $cmd) { return $cmd.Source }
    }

    if ($RecurseRoots.Count -gt 0) {
        $name = $FindName
        if ([string]::IsNullOrEmpty($name)) {
            foreach ($o in $ordered) {
                $n = Split-Path -Leaf $o.P
                if (-not [string]::IsNullOrEmpty($n)) { $name = $n; break }
            }
        }
        if (-not [string]::IsNullOrEmpty($name)) {
            foreach ($r in $RecurseRoots) {
                [void]$searched.Add("$r\**\$name    ← 兜底递归搜索")
                if (-not (Test-Path -LiteralPath $r)) { continue }
                # -ErrorAction SilentlyContinue 只吞"某个子目录无权限"，扫过哪些根
                # 目录已经记进 $searched 了 —— 失败信息里看得见，不是静默。
                $hit = Get-ChildItem -LiteralPath $r -Recurse -File -Filter $name -ErrorAction SilentlyContinue |
                       Select-Object -First 1
                if ($null -ne $hit) { return $hit.FullName }
            }
        }
    }

    $list = ($searched | ForEach-Object { "    - $_" }) -join "`n"
    $msg = "$What 未找到。已按优先级搜索以下路径（共 $($searched.Count) 条）：`n$list"
    if (-not [string]::IsNullOrEmpty($Hint)) { $msg += "`n  提示：$Hint" }
    if ($Optional) { Write-Warning $msg; return $null }
    throw $msg
}

function Get-MySqlClientArgs {
    param(
        [Parameter(Mandatory=$true)][string]$Dsn,
        [string]$Client = ""
    )

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

    # 客户端二进制：走统一入口（复查 D2）。
    #   $env:HOSP_MYSQL_CLIENT 保留兼容（很多脚本的报错提示里已经写了它），
    #   新增 $env:HOSP_MARIADB_HOME（指向 MariaDB 安装目录，取 bin\mariadb.exe）。
    #   ⚠ 候选里的 Join-HospPathSafe 是**必须的**：$env:ProgramFiles 之类的变量
    #     在候选数组字面量里被求值，为空时裸 Join-Path 会直接抛绑定异常（D1 同款坑）。
    $client = Resolve-HospPath `
        -Explicit $Client `
        -EnvPaths @(
            @{ Var = 'HOSP_MYSQL_CLIENT' },
            @{ Var = 'HOSP_MARIADB_HOME'; Sub = 'bin\mariadb.exe' }
        ) `
        -Candidates @(
            'E:\cangjie\mariadb\mariadb-11.4.13-winx64\bin\mariadb.exe',
            'D:\cangjie\mariadb\mariadb-11.4.13-winx64\bin\mariadb.exe',
            'C:\cangjie\mariadb\mariadb-11.4.13-winx64\bin\mariadb.exe',
            (Join-HospPathSafe $env:ProgramFiles 'MariaDB 11.4\bin\mariadb.exe'),
            (Join-HospPathSafe ${env:ProgramFiles(x86)} 'MariaDB 11.4\bin\mariadb.exe')
        ) `
        -RecurseRoots @('E:\cangjie', 'D:\cangjie', 'C:\cangjie', (Join-HospPathSafe $env:ProgramFiles 'MariaDB 11.4')) `
        -FindName 'mariadb.exe' `
        -OnPath 'mariadb' `
        -Type File `
        -What "MariaDB 客户端（DSN=$Dsn）" `
        -Hint "用 -Client <mariadb.exe> 指定，或设 `$env:HOSP_MYSQL_CLIENT / `$env:HOSP_MARIADB_HOME。"

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

# 把原生命令的输出拍平成纯文本（PowerShell 会把每条 stderr 行包成 ErrorRecord）。
function ConvertFrom-HospNativeOutput {
    param($Raw)
    $text = @()
    foreach ($item in @($Raw)) {
        if ($null -eq $item) { continue }
        if ($item -is [System.Management.Automation.ErrorRecord]) {
            # ⚠ 实测：客户端 stderr 每条行会变成一条 ErrorRecord，
            #   其中还会夹一条 Message 为空、ToString() 为 "…RemoteException" 的**噪音**记录。
            #   空 Message 直接跳过 —— 否则异常信息里会混进一行看不懂的类型名。
            $m = $item.Exception.Message
            if (-not [string]::IsNullOrEmpty($m)) { $text += $m }
        } else {
            $text += "$item"
        }
    }
    return $text
}

# 从客户端输出里挑出**服务器错误行**（`ERROR 1064 (42000): …`）。
#
# ★ 为什么光看 $LASTEXITCODE 不够（2026-10-14 实测，C3 的补充）：
#     mariadb 客户端执行 `-e "source <file>"` 时，**即使文件里的语句报错，退出码也是 0**
#     （只有把 SQL 从 stdin 喂进去才给 1）。实测：
#       & mariadb … -e "source bad.sql"   → exit 0 + stderr `ERROR 1064 (42000) at line 1 in file: …`
#       Get-Content bad.sql | & mariadb … → exit 1
#     所以「查退出码」必须再配一层文本兜底，否则 SQL 文件执行失败**照样静默**。
function Get-HospMysqlServerErrors {
    param($Text)
    return @(@($Text) | Where-Object { $_ -match '^\s*ERROR\s+\d{3,5}\b' })
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
#
# ★ 退出码（复查 C3）：非 0 一律抛异常 —— "命令失败被静默忽略"必须消除。
#   SQL 报错时 `2>&1` 抓回来的是错误文本，以前它就当"查询结果"返回了。
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
    # ⚠⚠ 这里必须把 stderr 的「提升为终止错误」**临时关掉**（2026-10-09 修）。
    #
    # 踩到的现象：`triage-check.ps1` 跑到一半**突然中止**（退出码 1、
    # 只报 10 项、**连一条 [FAIL] 都没有**）—— 看起来像脚本坏了，
    # 其实是 mariadb 客户端往 stderr 打了一段分隔线，
    # 而本文件顶部设了 $ErrorActionPreference = 'Stop'。
    # 在 PowerShell 里，**原生命令写到 stderr 的任何内容都会被当成错误记录**，
    # 配上 'Stop' 就**直接中断整个脚本**。
    #
    # ⇒ 正确做法：只在**这一条**原生命令前后临时切到 'Continue'，用完立刻还原。
    #   ⚠ 不改成「整个文件都用 Continue」—— 那会让真正的错误被吞掉，
    #     把本仓最忌的「静默失败」引进来。
    # 📌 一般化：**调用外部命令并捕获输出时，永远不要让它继承 'Stop'。**
    #   ★ 并且"临时 Continue"**必须**配上 $LASTEXITCODE 检查（复查 C3）——
    #     否则 stderr 的正文虽然抓到了，失败却依然被当成成功。
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $exitCode = 0
    try {
        $raw = & $My.Client $cliArgs 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedEap
    }
    # 过滤掉 PowerShell 为每条 stderr 行包出来的 ErrorRecord（保留真正的输出文本）。
    $text = ConvertFrom-HospNativeOutput -Raw $raw
    $joined = ($text -join "`n")

    if ($exitCode -ne 0 -or (Get-HospMysqlServerErrors -Text $text).Count -gt 0) {
        $sqlSnippet = $Sql.Trim()
        if ($sqlSnippet.Length -gt 400) { $sqlSnippet = $sqlSnippet.Substring(0, 400) + " …(截断)" }
        $why = if ($exitCode -ne 0) { "exit $exitCode" } else { "退出码是 0，但输出里有服务器错误行（客户端对 `-e ""source …""` 的退出码不可靠）" }
        throw ("MySQL 客户端执行失败（$why）。`n" +
               "  Label : $Label`n" +
               "  客户端: $($My.Client)`n" +
               "  库     : $(if ($My.Db) { $My.Db } else { '(未指定)' })`n" +
               "  SQL   : $sqlSnippet`n" +
               "  输出  :`n$joined")
    }

    if ($null -eq $joined -or "$joined".Trim().Length -eq 0) {
        if ($Sql.TrimStart().ToUpper().StartsWith("SELECT")) {
            Write-Warning "  SQL 未返回任何行（$Label，库 $($My.Db)）：$Sql"
        }
        return ""
    }
    return "$joined".Trim()
}

# 执行一个 .sql 文件（用 source）。
# ★ 退出码（复查 C3）：非 0 抛异常，异常里带文件路径与退出码。
#   ⚠ 以前这里既不查退出码、也不看 stderr（`| Out-Null`），
#     靠"顶部 EAP=Stop 会把原生 stderr 变终止错误"兜着 —— 那是**隐式**的，
#     且客户端只退出非 0、不写 stderr 的失败（如 `--force` 之外的连接中断）
#     会被完全吞掉。
#   ★★ 而且**只查退出码仍不够**：实测 `-e "source <file>"` 在文件内语句报错时
#      退出码是 **0**（只有 stdin 方式才给 1）。所以这里再加一层服务器错误行检测。
function Invoke-MySqlFile {
    param(
        [Parameter(Mandatory=$true)]$My,
        [Parameter(Mandatory=$true)][string]$Path
    )
    if (-not (Test-Path -LiteralPath $Path)) { throw "SQL 文件不存在：$Path" }
    $cliArgs = @("-h", $My.DbHost, "-P", $My.Port, "-u", $My.User, "-p$($My.Pass)", "--skip-ssl")
    if ($My.Db) { $cliArgs += $My.Db }
    $cliArgs += @("-e", "source $Path")
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $exitCode = 0
    $out = @()
    try {
        $out = & $My.Client $cliArgs 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedEap
    }
    $text = @(ConvertFrom-HospNativeOutput -Raw $out)
    $serverErrors = @(Get-HospMysqlServerErrors -Text $text)
    if ($exitCode -ne 0 -or $serverErrors.Count -gt 0) {
        $why = if ($exitCode -ne 0) {
            "exit $exitCode"
        } else {
            "退出码是 0，但文件内语句报错（`-e ""source …"" 的退出码不可靠），错误 $($serverErrors.Count) 条"
        }
        throw ("执行 SQL 文件失败（$why）。`n" +
               "  文件  : $Path`n" +
               "  客户端: $($My.Client)`n" +
               "  库    : $(if ($My.Db) { $My.Db } else { '(未指定)' })`n" +
               "  输出  :`n$($text -join "`n")")
    }
}
# ── 登录拿不到令牌时的统一出口（2026-10-16，第三方复查 S3）─────────────────
# 复查现场：门禁脚本登录失败时是**裸 throw** ——
#   · 打出来的是 PowerShell 堆栈，看起来像“脚本坏了”，而不是“前置条件没满足”；
#   · 被 AUTH_RATE_LIMITED 挡住时更冤：那是 auth_repo.cj 的**正常保护**
#     （LOGIN_FAIL_LIMIT=5 次 / LOGIN_FAIL_WINDOW=900s / LOGIN_LOCK_SECONDS=900s），
#     却让整轮门禁**无交代地中断**（复查者就被挡过一次）。
# 现在的口径：
#   1) Test-HospLoginRateLimited：命中限流（HTTP 429 或 body 含 AUTH_RATE_LIMITED）时
#      **清 auth_login_attempt 的失败计数**并返回 $true，
#      调用方据此**重试一次登录** —— 不静默、也不让人干等 15 分钟；
#   2) Stop-HospLogin：重试后仍失败 ⇒ 打印诊断（登录名 / HTTP / body / 库 / 目标 +
#      已跑断言计数）然后 `exit 2`：**与断言失败的 exit 1 区分**，
#      一眼看出是“没跑完（前置条件）”而不是“跑完有红（断言）”。
function Test-HospLoginRateLimited {
    param(
        [Parameter(Mandatory=$true)][string]$Login,
        [Parameter(Mandatory=$true)]$Resp,
        $My = $null
    )
    $http = 0
    if ($null -ne $Resp.PSObject.Properties['Http']) { $http = [int]$Resp.Http }
    elseif ($null -ne $Resp.PSObject.Properties['Code']) { $http = [int]$Resp.Code }
    $body = "$($Resp.Body)"
    if (-not (($http -eq 429) -or ($body -match 'AUTH_RATE_LIMITED'))) { return $false }

    Write-Host ""
    Write-Host "  ⚠ 登录被限流（HTTP $http）：这是服务端的正常保护，不是缺陷。" -ForegroundColor Yellow
    Write-Host "     auth_repo.cj: LOGIN_FAIL_LIMIT=5 次 / LOGIN_FAIL_WINDOW=900s / LOGIN_LOCK_SECONDS=900s" -ForegroundColor DarkGray
    if ($null -eq $My) {
        Write-Host "     （本脚本没拿到库连接，无法自动清计数：可等 900s，或手工 DELETE FROM auth_login_attempt）" -ForegroundColor DarkGray
        return $false
    }
    try {
        # ⚠ 只能**整表清**：`auth_login_attempt` 的主键是 `login_hash`
        #   （= HMAC-SHA256(LOGIN_HASH_KEY, 归一化登录名)，见 auth_repo.cj:164；
        #   服务端自己也是按 login_hash 删的，auth_repo.cj:430）——
        #   脚本拿不到那个密钥、也不该复刻它，所以「按登录名过滤」做不到。
        #   整表清正是本仓既有口径（auth-check.ps1:57 / previsit-check.ps1:34 /
        #   triage-check.ps1:34 / rate-limit-check.ps1:58 / p1-extra-check.ps1:72
        #   的「清限流计数」都是全表删）；它安全的前提是**测试库独占**（见 DEV-DB.md §四）。
        $null = Invoke-MySqlScalar -My $My -Label "清限流计数" -Sql "DELETE FROM auth_login_attempt"
        Write-Host "     [ok] 已清空 auth_login_attempt（含 $Login 的失败计数），重试一次登录。" -ForegroundColor DarkGray
        return $true
    } catch {
        Write-Host "     [!] 清限流计数失败：$($_.Exception.Message)" -ForegroundColor DarkGray
        return $false
    }
}

function Stop-HospLogin {
    param(
        [Parameter(Mandatory=$true)][string]$Login,
        [Parameter(Mandatory=$true)]$Resp,
        $My = $null,
        [string]$Base = '',
        [string]$Hint = ''
    )
    $http = 0
    if ($null -ne $Resp.PSObject.Properties['Http']) { $http = [int]$Resp.Http }
    elseif ($null -ne $Resp.PSObject.Properties['Code']) { $http = [int]$Resp.Code }
    $body = "$($Resp.Body)"

    Write-Host ""
    Write-Host "❌ 登录失败，脚本无法继续：$Login（HTTP $http）" -ForegroundColor Red
    if (-not [string]::IsNullOrEmpty($body)) { Write-Host "   body : $body" -ForegroundColor DarkGray }
    if ($null -ne $My) {
        Write-Host "   库   : $($My.Db)@$($My.DbHost):$($My.Port)（客户端 $($My.Client)）" -ForegroundColor DarkGray
    }
    if (-not [string]::IsNullOrEmpty($Base)) { Write-Host "   目标 : $Base" -ForegroundColor DarkGray }
    $pv = Get-Variable -Name passed -Scope 1 -ErrorAction SilentlyContinue
    $fv = Get-Variable -Name failed -Scope 1 -ErrorAction SilentlyContinue
    if ($null -ne $pv -and $null -ne $fv) {
        Write-Host "   已跑断言：通过 $($pv.Value) 项 / 失败 $($fv.Value) 项" -ForegroundColor DarkGray
    }
    Write-Host "   提示：管理员口令由 `hospital-server.exe create-admin <dsn>` 生成；" -ForegroundColor DarkGray
    Write-Host "         HTTP 429/AUTH_RATE_LIMITED = 被限流（等 900s 或清 auth_login_attempt）；" -ForegroundColor DarkGray
    Write-Host "         连接被拒 = 服务端没起或端口写错；401 但口令没错 = 连错库（-Dsn 指向的库才是事实来源）。" -ForegroundColor DarkGray
    if (-not [string]::IsNullOrEmpty($Hint)) { Write-Host "   $Hint" -ForegroundColor DarkGray }
    Write-Host "   → 以 exit 2 结束：这是**前置条件**失败，不是断言失败（断言失败是 exit 1）。" -ForegroundColor DarkGray
    exit 2
}