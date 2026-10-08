# SPDX-License-Identifier: MIT
#
# ===== create-db-check.ps1 —— 建库必须"真能用"（第八份复查的真问题）=========
#
# 复查实测 6/6：`create-db` 报「✅ 库已就绪」，紧接着 `check-db` 在
# `migrateSchema` 的 ALTER 上被拒 —— 因为权益是**按库逐个授**的：
#     GRANT CREATE ON *.*                     ← 全局：只能"建库"
#     GRANT ALL PRIVILEGES ON hospital.*      ← 库级：权限在这里
#     GRANT ALL PRIVILEGES ON hospital_test.*
# ⇒ 业务账号能建第三个库，却对新库**没有任何权限**。
#
# 本脚本把这条钉死：干净库上必须「不给 --admin-dsn 就明确失败」、
# 「给了就一步到位」，且失败时**不许出现堆栈**。
#
# 用法：
#   .\create-db-check.ps1 [-MySqlHost 127.0.0.1] [-MySqlPort 3317]
#                         [-MySqlUser hospital] [-MySqlPass hospital_dev_2026]
#                         [-AdminDsn mysql://root:pw@127.0.0.1:3317/]
#
# ⚠ 需要管理员 DSN 才能验证"一步到位"那条；不给则只验证"明确失败"那条，
#   并把跳过的那条**如实标出**（不静默略过）。

[CmdletBinding()]
param(
    [string]$MySqlHost = "127.0.0.1",
    [int]$MySqlPort = 3317,
    [string]$MySqlUser = "hospital",
    [string]$MySqlPass = "hospital_dev_2026",
    [string]$AdminDsn = "",
    [string]$Exe = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

# ⚠ `Get-MySqlClientArgs` 要求 DSN **带库名**（与仓颉侧 parseDsn 同口径）。
#   管理员 DSN 常常不带库名，而 DROP/GRANT 都不关心当前库 ——
#   所以这里给它补一个占位库名（不会真的用到，也不会建它）。
function Get-AdminMy([string]$dsn) {
    $my = Get-MySqlClientArgs -Dsn $dsn
    # 管理员 DSN 常常不带库名 ⇒ Db 为空；`Invoke-MySqlScalar` 已支持（不传库名参数）
    if ($dsn -match "/$") { $my.Db = "" }
    return $my
}

$root = Split-Path -Parent $PSScriptRoot
if (-not $Exe) { $Exe = Join-Path $root "build\hospital-server.exe" }
if (-not (Test-Path $Exe)) { throw "找不到 $Exe（先跑 build.ps1）" }
$Exe = (Resolve-Path $Exe).Path

$passed = 0
$failed = 0
function Check($name, $cond, $detail) {
    if ($cond) { Write-Host "  [PASS] $name" -ForegroundColor Green; $script:passed++ }
    else { Write-Host "  [FAIL] $name" -ForegroundColor Red; $script:failed++ }
    if ($detail) { Write-Host "         $detail" -ForegroundColor DarkGray }
}

Write-Host ""
Write-Host "=== create-db / check-db 端到端（建库必须真能用）===" -ForegroundColor Cyan
Write-Host "  exe : $Exe"
Write-Host "  库  : ${MySqlUser}@${MySqlHost}:${MySqlPort}"

# ⚠ 用带 test 的库名：accept 只允许显式测试库（这是另一条守卫，别在这里踩到）
$DbName = "zz_createdb_test"
$target = "mysql://${MySqlUser}:${MySqlPass}@${MySqlHost}:${MySqlPort}/${DbName}"

# ── 前置：库必须**不存在，且该账号对它没有任何权限**
#
# ⚠⚠ 这里必须**同时**保证两件事，否则测试会依赖残留状态（我第一次就踩了）：
#   ① 库不存在（否则测的不是建库路径）；
#   ② **权限也已被撤销** —— 因为 GRANT 是**独立于库**存在的：
#      库被 DROP 掉之后，`hospital@localhost` 对它的授权**仍然留在
#      mysql.db 里**；下次再建同名库时，权限**立刻生效**。
#      于是"不给 --admin-dsn 必须失败"这条用例会变成成功（假红）——
#      我实测跑第二遍时就是 `exit=0`。
#   ⇒ 只 DROP 库是不够的，必须**连授权一起撤**。这才是真正的"干净状态"。
Write-Host ""
Write-Host "[0] 前置：库不存在**且无残留授权**"
if (-not $AdminDsn) {
    Write-Host "  ⚠ 未给 -AdminDsn ⇒ 无法**撤销残留授权**，也无法验证授权类用例。" -ForegroundColor Yellow
    Write-Host "     这些用例会如实标为 SKIP，不会静默略过。" -ForegroundColor Yellow
    Write-Host "     （提示：至少要能跑一次带 -AdminDsn 的，才能保证本脚本可重复）" -ForegroundColor Yellow
} else {
    $adminMy = Get-AdminMy $AdminDsn
    # 先撤权、再删库（顺序无关，但都做）
    #
    # ⚠ `REVOKE` 对"本来就没有该授权的账户"会**报错**（MySQL 的正常行为），
    #   而本脚本顶部是 `$ErrorActionPreference = "Stop"` ⇒ 原生程序的 stderr 会被
    #   升级成**终止错误**，把整个脚本打断（我实测踩到）。
    #   ⇒ 这一段**临时放宽**错误处理：撤销是"尽力而为"的幂等清理，
    #     真正的判据是下面那条"残留授权计数 == 0"的断言，而不是 REVOKE 有没有报错。
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    foreach ($acct in @("'${MySqlUser}'@'localhost'", "'${MySqlUser}'@'%'")) {
        try {
            $null = Invoke-MySqlScalar -My $adminMy -Label "撤销 $acct 对 $DbName 的授权" `
                -Sql "REVOKE ALL PRIVILEGES ON ``$DbName``.* FROM $acct"
        } catch {
            # 账户不存在 / 本来就没这条授权 —— 都是正常情况
        }
    }
    try {
        $null = Invoke-MySqlScalar -My $adminMy -Sql "DROP DATABASE IF EXISTS $DbName" -Label "删除旧库"
    } catch {
        # 库本来就不存在 —— 正常
    }
    $ErrorActionPreference = $savedEap
    # ★ 验证"真的干净了"：直接查权限表，而不是假设 REVOKE 一定成功
    $left = Invoke-MySqlScalar -My $adminMy -Label "残留授权计数" `
        -Sql "SELECT COUNT(*) FROM mysql.db WHERE Db='$DbName' AND User='$MySqlUser'"
    Check "前置：$DbName 已删除且无残留授权（残留 $left 条）" ("$left".Trim() -eq "0")
}

# ── ① 不带 --admin-dsn：库能建，但必须**明确失败**（不许报"就绪"）
Write-Host ""
Write-Host "[1] ★ 不给 --admin-dsn：必须明确失败（原缺陷是报「就绪」）"
$o1 = & $Exe create-db $target 2>&1 | Out-String
$c1 = $LASTEXITCODE
Check "退出码非 0（原缺陷下是 0 + 「✅ 库已就绪」）" ($c1 -ne 0) ("exit=$c1")
Check "★ 输出**没有**「✅ 库已就绪」这类成功话术" (-not ($o1 -match '✅ 库已就绪')) `
      (($o1 -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1).Trim())
# ⚠ 不要把 `if` 表达式直接写在续行参数位置 —— PowerShell 会把 `if` 当成命令名
$stack1 = if ($o1 -match 'An exception has occurred') { "发现堆栈" } else { "无堆栈" }
Check "★ 输出**没有**未捕获异常堆栈（失败要靠 ❌ 说出来，不能靠崩溃表达）" `
      (-not ($o1 -match 'An exception has occurred|at mariadb\.cdbc::|at qingzhou::')) `
      $stack1
Check "★ 给出了可复制的 GRANT 处置（不给处置就等于让人猜）" `
      ($o1 -match 'GRANT ALL PRIVILEGES ON') `
      (($o1 -split "`n" | Where-Object { $_ -match 'GRANT ALL PRIVILEGES' } | Select-Object -First 1).Trim())
Check "★ 处置里的**账户带真实 host**（用 CURRENT_USER()，不是硬编码 localhost）" `
      ($o1 -match "TO '\w+'@'\w+'") `
      (($o1 -split "`n" | Where-Object { $_ -match "TO '" } | Select-Object -First 1).Trim())

# ── ② check-db：必须**干净报错**（原缺陷是未捕获异常 + 堆栈）
Write-Host ""
Write-Host "[2] ★ check-db 在权限不足时必须干净报错（原缺陷：堆栈）"
$o2 = & $Exe check-db $target 2>&1 | Out-String
$c2 = $LASTEXITCODE
Check "退出码非 0" ($c2 -ne 0) ("exit=$c2")
$stack2 = if ($o2 -match 'An exception has occurred') { "发现堆栈" } else { "无堆栈" }
Check "★★ 输出**没有**未捕获异常堆栈" `
      (-not ($o2 -match 'An exception has occurred|at mariadb\.cdbc::|at qingzhou::')) `
      $stack2
Check "★ 报错里点出了 ALTER（真正缺的权限）" ($o2 -match 'ALTER') `
      (($o2 -split "`n" | Where-Object { $_ -match '❌' } | Select-Object -First 1).Trim())
Check "★ 并给出处置（GRANT 命令）" ($o2 -match 'GRANT ALL PRIVILEGES ON')

if (-not $AdminDsn) {
    Write-Host ""
    Write-Host "[3] SKIP：需要 -AdminDsn 才能验证「一步到位」" -ForegroundColor Yellow
    Write-Host "[4] SKIP：需要 -AdminDsn 才能验证「授权后 check-db/accept 通过」" -ForegroundColor Yellow
} else {
    # ── ③ 给 --admin-dsn：必须一步到位
    Write-Host ""
    Write-Host "[3] ★★ 给 --admin-dsn：建库 + 授权 + 探通，一步到位"
    $null = Invoke-MySqlScalar -My $adminMy -Sql "DROP DATABASE IF EXISTS $DbName" -Label "重置库"
    $o3 = & $Exe create-db $target --admin-dsn $AdminDsn 2>&1 | Out-String
    $c3 = $LASTEXITCODE
    Check "退出码 0" ($c3 -eq 0) ("exit=$c3")
    Check "★ 输出里有「已就绪且可用」（不是含糊的「就绪」）" ($o3 -match '库已就绪且可用') `
          (($o3 -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1).Trim())

    # ── ④ 授权后：check-db / accept 都必须通过（复查的原始断言）
    Write-Host ""
    Write-Host "[4] ★★ 授权后 check-db 与 accept 都必须通过（复查的 6/6 断言）"
    $o4 = & $Exe check-db $target 2>&1 | Out-String
    Check "check-db 退出码 0" ($LASTEXITCODE -eq 0) ("exit=$LASTEXITCODE")
    Check "★★ check-db 输出**没有** ALTER denied" (-not ($o4 -match 'ALTER command denied'))
    $o5 = & $Exe accept $target 2>&1 | Out-String
    Check "accept 退出码 0" ($LASTEXITCODE -eq 0) ("exit=$LASTEXITCODE")
    Check "★★ accept 全部通过（原缺陷下这一步必失败）" ($o5 -match '验收测试全部通过') `
          (($o5 -split "`n" | Where-Object { $_ -match '通过 \d+ 项' } | Select-Object -First 1).Trim())

    # ── ⑤ 反例：管理员 DSN 也可以是**不带库名**的（实测踩到过）
    Write-Host ""
    Write-Host "[5] ★ 管理员 DSN 不带库名也要能用（GRANT 不需要库名）"
    $null = Invoke-MySqlScalar -My $adminMy -Sql "DROP DATABASE IF EXISTS $DbName" -Label "重置库"
    $admNoDb = $AdminDsn
    if ($admNoDb -match '^(.*?/)[^/]*$') { $admNoDb = $Matches[1] }
    $o6 = & $Exe create-db $target --admin-dsn $admNoDb 2>&1 | Out-String
    Check "不带库名的管理员 DSN 也能一步到位" ($LASTEXITCODE -eq 0) `
          ("admin-dsn='$admNoDb' exit=$LASTEXITCODE")

    # ── 清理：★ 必须**既撤权又删库**，并自检不留孤儿授权
    #
    # ⚠ 这一步是给自己上的闸门：我第一版只 DROP 库 ⇒ 授权留在 `mysql.db` 里
    #   成了**孤儿授权**（库都没了、权限还在）—— 连我自己复现时都留下了两条。
    #   `GRANT` 独立于库存在，所以清理必须两步都做。
    $savedEap2 = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    foreach ($acct in @("'${MySqlUser}'@'localhost'", "'${MySqlUser}'@'%'")) {
        try { $null = Invoke-MySqlScalar -My $adminMy -Label "撤权" -Sql "REVOKE ALL PRIVILEGES ON ``$DbName``.* FROM $acct" } catch { }
    }
    try { $null = Invoke-MySqlScalar -My $adminMy -Sql "DROP DATABASE IF EXISTS $DbName" -Label "清理测试库" } catch { }
    $ErrorActionPreference = $savedEap2
    $orphan = Invoke-MySqlScalar -My $adminMy -Label "孤儿授权计数" `
        -Sql "SELECT COUNT(*) FROM mysql.db WHERE Db='$DbName'"
    Check "★ 清理后不留孤儿授权（残留 $orphan 条）" ("$orphan".Trim() -eq "0")
}

Write-Host ""
if ($failed -eq 0) {
    Write-Host "✅ create-db 验证全部通过（通过 $passed 项）" -ForegroundColor Green
    exit 0
} else {
    Write-Host "❌ create-db 验证失败 $failed 项（通过 $passed 项）" -ForegroundColor Red
    exit 1
}
