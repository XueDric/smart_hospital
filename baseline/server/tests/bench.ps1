# 社团管理工具 · 服务端容量基准
#
# 目的：给 docs/capacity-baseline.md 里的"改造前/改造后"数字一个**可复现**的来源。
# 这里打的是真实 HTTP，量的是客户端能感知的端到端耗时（含序列化与网络）。
#
# 用法（Windows PowerShell 5.1 默认禁止跑脚本，必须带 Bypass）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\bench.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\bench.ps1 -Members 3000 -Tasks 3000
#
# 对比历史版本（用 git worktree 在旧提交上编译，数据形状完全一致）：
#   git worktree add ..\bench-old HEAD
#   (cd ..\bench-old\server; powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1)
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\bench.ps1 -Exe ..\bench-old\server\build\club-server.exe
#   git worktree remove ..\bench-old
#
# 造数据：init-admin 生成一个带**真实口令哈希**的库，再用 MySQL 的递归 CTE 把首任会长那条
#        成员记录**在库里**克隆成 N 条（共用同一份 pw_salt/pw_hash，于是所有人都是 password123）；
#        任务同理，但先经接口建 1 条真记录再克隆 —— 不手写 JSON 模板，避免 schema 漂移。
#        不走接口慢慢造 1000 个账号/任务：那要几分钟，而且造数本身就被待测代码拖慢。
#
# ⚠ 2026-09-20 起：服务端持久化是 **MySQL**（路线 B，见 docs\club-server-mysql-assessment.md），
#   所以造数从"改写 db.json"改成"往 MySQL 里 INSERT ... SELECT 展开"。
#   数据量口径与迁移前**一致**（同样 N 成员 + M 任务，due_at 同样按 $i*7919 打散），
#   因此新旧版本的 [bench] RESULT 行仍然可比。
#   用**专用测试库 club_bench**（绝不碰 club / club_rbac 等真实库），开头检测可连性，
#   取不到 → 中文提示 + 非零退出（与其他测试脚本同一口径，见 tests\mysql-common.ps1）。
#
# 用独立审计日志目录 build\bench-data，绝不碰正式数据 data\。
#
# 指标（各取 Rounds 次的中位数）：
#   login   POST /api/v1/auth/login          PBKDF2-SHA256 10 万次迭代（动作 2：哈希移出锁）
#   tasks   GET  /api/v1/tasks               列表 + 排序（动作 1：插入排序 -> 堆排序）
#   members GET  /api/v1/members?size=50     列表 + 排序（同上，成员表本身）
#   write   POST /api/v1/tasks               改内存 + 落盘（动作 4 在文件后端下是"整库 IO 移出锁"，
#                                            MySQL 后端下是"事务写库移出全局锁"）
# 并发项（4 个请求同时发）：
#   动作 2/4 不降低**单个**请求的耗时，它们降低的是"锁被占住时别人在门外排队"的时间，
#   所以只有并发才看得见。串行因子 = 并发墙钟 / (4 × 单发中位数)，≈1 即被完全串行化。

param(
    [int]$Members = 1000,
    [int]$Tasks = 1000,
    [int]$Rounds = 10,
    [int]$Port = 18090,
    [string]$Exe = ""
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrEmpty($Exe)) { $Exe = Join-Path $root "build\club-server.exe" }
if (-not (Test-Path $Exe)) { throw "找不到服务端可执行文件：$Exe（先跑 build.ps1）" }

# 专用测试库 + 连接检测
. (Join-Path $PSScriptRoot "mysql-common.ps1")
$my = Initialize-MySqlTestEnv -DefaultDb "club_bench"
$benchDsn = $my.Dsn

$dataRel = "build\bench-data"      # 只剩审计日志（audit.log）用；业务数据在 MySQL 里
$dataAbs = Join-Path $root $dataRel
$logOut  = Join-Path $root "build\bench-server.out.log"
$logErr  = Join-Path $root "build\bench-server.err.log"
$base    = "http://127.0.0.1:$Port"

# 调接口。返回 @{ status; json; raw }；非 2xx 不抛异常，靠 status 判断。
function Call-Api([string]$method, [string]$path, $body = $null, [string]$token = "") {
    $headers = @{}
    if ($token) { $headers["Authorization"] = "Bearer $token" }
    $p = @{
        Method          = $method
        Uri             = "$base$path"
        UseBasicParsing = $true
        Headers         = $headers
        TimeoutSec      = 120
    }
    if ($null -ne $body) {
        # PS 5.1 的坑：Body 传字符串会按 ANSI 发送，中文到达服务端就是乱码。
        $json = if ($body -is [string]) { $body } else { $body | ConvertTo-Json -Compress }
        $p["ContentType"] = "application/json; charset=utf-8"
        $p["Body"] = [System.Text.Encoding]::UTF8.GetBytes($json)
    }
    try {
        $r = Invoke-WebRequest @p
        $j = $null
        if ($r.Content) { try { $j = $r.Content | ConvertFrom-Json } catch { } }
        return @{ status = [int]$r.StatusCode; json = $j; raw = [string]$r.Content }
    } catch {
        $txt = ""
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $txt = [string]$_.ErrorDetails.Message }
        $code = 0
        $resp = $_.Exception.Response
        if ($null -ne $resp) { $code = [int]$resp.StatusCode }
        return @{ status = $code; json = $null; raw = $txt }
    }
}

# ===================== 造数（数据库侧展开，2026-09-20 起） =====================
#
# 迁移前这两步是"改写 db.json 里的数组"。现在数据在 MySQL 里，等价做法是
# `INSERT ... SELECT` 直接从已有行复制 —— **同一份 pw_salt/pw_hash 被复用**，
# 所以克隆出来的人都能用 password123 登录；这也是迁移前那句注释的口径。
#
# 为什么用**递归 CTE** 生成序号：一次 INSERT 就把上千行写进库，
# 比在 PowerShell 里循环发 1000 条 INSERT 快两三个数量级（造数时间不能污染被测口径）。
# MariaDB 10.2+ / MySQL 8.0+ 都支持（本机 MariaDB 11.4 实测可用）。

# 先把会长那条记录复制成 $Members 条（id 1 是会长本身，故补 $Members-1 条）
function Expand-Members([int]$Count) {
    if ($Count -le 1) { return }
    $n = $Count - 1
    $sql = "INSERT INTO members (id, name, phone, pw_algo, pw_iter, pw_salt, pw_hash, role, dept_id, dept_hint, status, joined_at) " +
           "WITH RECURSIVE seq(i) AS (SELECT 2 UNION ALL SELECT i+1 FROM seq WHERE i < $Count) " +
           "SELECT i, CONCAT('Member-', LPAD(i, 5, '0')), CONCAT('139', LPAD(i, 8, '0')), pw_algo, pw_iter, pw_salt, pw_hash, 'member', dept_id, 0, 'active', " +
           "       (SELECT joined_at FROM members WHERE id = 1) FROM seq CROSS JOIN members WHERE members.id = 1;"
    $null = Invoke-ClubMySql $sql $my.Db
    # next_member 必须跟上，否则新注册会和克隆出来的 id 撞车
    $null = Invoke-ClubMySql "INSERT INTO meta (k, v) VALUES ('next_member', $($Count + 1)) ON DUPLICATE KEY UPDATE v = VALUES(v);" $my.Db
}

# 把那条"模板任务"复制成 $Count 条
function Expand-Tasks([int]$Count) {
    if ($Count -le 1) { return }
    # 截止时间必须**打散**：GET /tasks 按 due_at 排序（store.cj 的 sortedTasksByDue）。
    # 若留 due_at=0，排序键就退化成"常量 + id"，插入排序恰好走 O(n) 最好情况 ——
    # 那就测不出排序改动的价值了。i * 7919 mod 一年 是确定性的乱序（7919 与模数互质）。
    $sql = "INSERT INTO tasks (id, title, ``desc``, owner_id, plan_id, dept_id, status, blocker, help_dept_id, help_member_id, due_at, updated_at, completed_at, deleted_at, source, created_by, created_at) " +
           "WITH RECURSIVE seq(i) AS (SELECT 2 UNION ALL SELECT i+1 FROM seq WHERE i < $Count) " +
           "SELECT i, CONCAT('Task-', LPAD(i, 5, '0')), t.``desc``, t.owner_id, t.plan_id, t.dept_id, t.status, t.blocker, t.help_dept_id, t.help_member_id, " +
           "       1789000000 + ((i * 7919) % 31536000), t.updated_at, t.completed_at, t.deleted_at, t.source, t.created_by, t.created_at " +
           "FROM seq CROSS JOIN tasks t WHERE t.id = 1;"
    $null = Invoke-ClubMySql $sql $my.Db
    $null = Invoke-ClubMySql "INSERT INTO meta (k, v) VALUES ('next_task', $($Count + 1)) ON DUPLICATE KEY UPDATE v = VALUES(v);" $my.Db
}

# 库里现在有多少行（用来把"数据规模"打进 RESULT 行，便于和文档里的旧数字对照）
function Count-Rows([string]$table) {
    return [int]((Invoke-ClubMySql "SELECT COUNT(*) FROM $table;" $my.Db).Trim())
}

function Start-Server {
    $p = Start-Process -FilePath $Exe `
        -ArgumentList @("serve", "$Port", $benchDsn, "--data-dir", $dataRel) `
        -WorkingDirectory $root `
        -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $logOut -RedirectStandardError $logErr
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $ready = $false
    for ($i = 0; $i -lt 600; $i++) {
        Start-Sleep -Milliseconds 50
        if ($p.HasExited) { break }
        try {
            $r = Invoke-WebRequest "$base/health" -UseBasicParsing -TimeoutSec 2
            if ($r.StatusCode -eq 200) { $ready = $true; break }
        } catch { }
    }
    $sw.Stop()
    if (-not $ready) {
        if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
        $tail = ""
        if (Test-Path $logOut) { $tail = (Get-Content $logOut -Raw) }
        throw "服务未能在 :$Port 就绪（$Members 人档）。日志：`n$tail`n$logErr"
    }
    $p | Add-Member -NotePropertyName StartupMs -NotePropertyValue $sw.ElapsedMilliseconds -Force
    return $p
}

function Stop-Server($p) {
    if ($null -eq $p) { return }
    if (-not $p.HasExited) { try { $p.Kill() } catch { } }
    try { $p.WaitForExit(5000) | Out-Null } catch { }
}

# 量 Rounds 次，返回中位数/最小/最大（毫秒）。先热身一次，避免把连接建立算进去。
function Measure-Call([string]$name, [scriptblock]$body, [int]$Rounds) {
    & $body 0 | Out-Null
    $times = New-Object System.Collections.ArrayList
    for ($i = 1; $i -le $Rounds; $i++) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        & $body $i | Out-Null
        $sw.Stop()
        [void]$times.Add([int]$sw.ElapsedMilliseconds)
    }
    $sorted = @($times | Sort-Object)
    $med = $sorted[[int][Math]::Floor($sorted.Count / 2)]
    $line = "{0,-8} median={1,6} ms   min={2,6}   max={3,6}" -f $name, $med, $sorted[0], $sorted[-1]
    Write-Host "[bench] $line"
    return @{ name = $name; median = $med; min = $sorted[0]; max = $sorted[-1] }
}

# 并发墙钟：N 个请求**同时**发出，量最后一个回来的时间。
# 用 .NET HttpClient 的 Task 做真并发（Start-Job 起进程太重，会把测量本身污染掉）。
function Measure-Concurrent([string]$name, [int]$N, [scriptblock]$makeTask, [int]$SingleMedian) {
    # PS 5.1 默认没加载 System.Net.Http（.NET 4.x 把它放在独立程序集里）
    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.UseProxy = $false
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(180)

    # 热身，避免把连接建立算进去
    $warm = & $makeTask $client -1
    $warm.GetAwaiter().GetResult() | Out-Null

    $tasks = New-Object System.Collections.ArrayList
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $N; $i++) {
        [void]$tasks.Add((& $makeTask $client $i))
    }
    [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]$tasks.ToArray())
    $sw.Stop()

    $wall = [int]$sw.ElapsedMilliseconds
    $serial = 1.0
    if ($SingleMedian -gt 0) { $serial = [Math]::Round($wall / ($N * $SingleMedian), 2) }
    $bad = 0
    foreach ($t in $tasks) {
        $code = [int]$t.Result.StatusCode
        if ($code -ne 200 -and $code -ne 201) { $bad++ }
    }
    $client.Dispose()
    $line = "{0,-10} N={1}  并发墙钟={2,6} ms  平均={3,5} ms/个  串行因子={4}  非2xx={5}" -f `
        $name, $N, $wall, [int]($wall / $N), $serial, $bad
    Write-Host "[bench] $line"
    return @{ name = $name; wall = $wall; serial = $serial; bad = $bad }
}

Push-Location $root
$srv = $null
try {
    Write-Host "=== 社团管理工具 · 服务端容量基准 ==="
    Write-Host "可执行文件: $Exe"
    Write-Host "规模      : $Members 名成员 / $Tasks 个任务 / $Rounds 轮"
    Write-Host ""

    # ---------- 1. 造库：克隆成员 ----------
    if (Test-Path $dataAbs) { Remove-Item -Recurse -Force $dataAbs }
    Remove-Item $logOut, $logErr -Force -ErrorAction SilentlyContinue
    Reset-ClubMySqlSchema $my.Db
    & $Exe init-admin 13800000000 password123 $benchDsn --data-dir $dataRel | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "init-admin 失败（exit=$LASTEXITCODE）" }

    $t0 = [System.Diagnostics.Stopwatch]::StartNew()
    Expand-Members $Members
    $t0.Stop()
    Write-Host "[bench] 成员档 members = $(Count-Rows 'members') 行（造数 $($t0.ElapsedMilliseconds) ms）"

    # ---------- 2. 造库：先建 1 个真任务，再克隆成 $Tasks 个 ----------
    $srv = Start-Server
    $login = Call-Api "POST" "/api/v1/auth/login" @{ phone = "13800000000"; password = "password123" }
    if ($login.status -ne 200) { throw "登录失败：status=$($login.status) body=$($login.raw)" }
    $token = $login.json.data.token
    $r = Call-Api "POST" "/api/v1/tasks" @{ title = "模板任务"; owner_id = 1 } $token
    if ($r.status -ne 201 -and $r.status -ne 200) { throw "模板任务失败：status=$($r.status) body=$($r.raw)" }
    Stop-Server $srv
    $srv = $null

    $t1 = [System.Diagnostics.Stopwatch]::StartNew()
    Expand-Tasks $Tasks
    $t1.Stop()

    $memRows = Count-Rows 'members'
    $taskRows = Count-Rows 'tasks'
    Write-Host "[bench] 完整库 tasks = $taskRows 行（造数 $($t1.ElapsedMilliseconds) ms）；合计 $memRows 成员 + $taskRows 任务"

    # ---------- 3. 起服务、登录 ----------
    $srv = Start-Server
    $startupMs = $srv.StartupMs
    Write-Host "[bench] 启动就绪 = $startupMs ms"
    $login = Call-Api "POST" "/api/v1/auth/login" @{ phone = "13800000000"; password = "password123" }
    if ($login.status -ne 200) { throw "登录失败：status=$($login.status) body=$($login.raw)" }
    $token = $login.json.data.token
    Write-Host ""

    # ---------- 4. 单发打点 ----------
    $rows = New-Object System.Collections.ArrayList
    [void]$rows.Add((Measure-Call "login"   { Call-Api "POST" "/api/v1/auth/login" @{ phone = "13800000000"; password = "password123" } } $Rounds))
    [void]$rows.Add((Measure-Call "tasks"   { Call-Api "GET"  "/api/v1/tasks" $null $token } $Rounds))
    [void]$rows.Add((Measure-Call "members" { Call-Api "GET"  "/api/v1/members?page=1&size=50" $null $token } $Rounds))
    [void]$rows.Add((Measure-Call "write"   { param($i) Call-Api "POST" "/api/v1/tasks" @{ title = "基准任务 $i-$([guid]::NewGuid().ToString('N').Substring(0,8))"; owner_id = 1 } $token } $Rounds))

    # ---------- 5. 并发打点（动作 2/4 的真正考场） ----------
    $loginMedian = 0; $writeMedian = 0
    foreach ($r in $rows) {
        if ($r.name -eq "login") { $loginMedian = $r.median }
        if ($r.name -eq "write") { $writeMedian = $r.median }
    }
    Write-Host ""
    $b = '{"phone":"13800000000","password":"password123"}'
    $crow = New-Object System.Collections.ArrayList
    [void]$crow.Add((Measure-Concurrent "login并发" 4 {
        param($c, $i)
        $ct = New-Object System.Net.Http.StringContent($b, [Text.Encoding]::UTF8, "application/json")
        return $c.PostAsync("$base/api/v1/auth/login", $ct)
    } $loginMedian))
    [void]$crow.Add((Measure-Concurrent "write并发" 4 {
        param($c, $i)
        $j = '{"title":"并发任务 ' + $i + '","owner_id":1}'
        $ct = New-Object System.Net.Http.StringContent($j, [Text.Encoding]::UTF8, "application/json")
        $req = New-Object System.Net.Http.HttpRequestMessage("POST", "$base/api/v1/tasks")
        $req.Content = $ct
        $req.Headers.Add("Authorization", "Bearer $token")
        return $c.SendAsync($req)
    } $writeMedian))

    Write-Host ""
    # 机器可读的一行，方便往文档里贴
    $cells = @()
    foreach ($r in $rows) { $cells += ("{0}={1}" -f $r.name, $r.median) }
    Write-Host ("[bench] RESULT members=$memRows tasks=$taskRows startup=$startupMs " + ($cells -join " "))
    foreach ($r in $crow) { Write-Host ("[bench] CONC {0} wall={1} serial={2} bad={3}" -f $r.name, $r.wall, $r.serial, $r.bad) }
} finally {
    Stop-Server $srv
    Pop-Location
}
