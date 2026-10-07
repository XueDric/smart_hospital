# 社团管理工具 · 服务端冒烟测试（打真实 HTTP）
#
# 单测覆盖不到接口层：JSON 包装形状、HTTP 状态码、错误码、令牌流转、
# 真实落盘与重启后的持久性。这一层是集成证据，与单测互补。
#
# ⚠⚠ 新前提（2026-09-20 起）：**必须有一台可连的 MySQL / MariaDB**。
#   服务端持久化已从"一个临时数据目录里的 db.json"整体换成 MySQL（路线 B，
#   见 docs\club-server-mysql-assessment.md），于是本脚本：
#     · 用**专用测试库 club_smoke**（绝不碰 club_rbac 或任何真实业务库）；
#     · 开头检测 MySQL 客户端与可连性，取不到 → **中文提示 + 判 FAIL + 非零退出**
#       （不静默跳过：数据层跑不起来时"数据到底写没写进去"根本没有答案）；
#     · 每次运行前 DROP 掉该库的 9 张表（7 张业务表 + 2 张元数据表）当干净夹具。
#   连接参数默认取本机便携版 MariaDB（127.0.0.1:3307 / root / clubroot123），
#   可用环境变量覆盖：CLUB_MYSQL_HOST / CLUB_MYSQL_PORT / CLUB_MYSQL_USER /
#   CLUB_MYSQL_PASS / CLUB_MYSQL_DB，以及 CLUB_MYSQL_CLI / CLUB_MARIADB_HOME。
#   细节与"怎么起一台本机 MariaDB"见 tests\mysql-common.ps1 的文件头。
#
# 用法（Windows PowerShell 5.1 默认禁止跑脚本，必须带 Bypass）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\smoke.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\smoke.ps1 -Port 18081

param(
    [int]$Port = 18080,
    [string]$Exe = ""
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrEmpty($Exe)) { $Exe = Join-Path $root "build\club-server.exe" }
if (-not (Test-Path $Exe)) { throw "找不到服务端可执行文件：$Exe（先跑 build.ps1）" }

# 专用测试库 + 连接检测（取不到就 FAIL 退出，见 tests\mysql-common.ps1）
. (Join-Path $PSScriptRoot "mysql-common.ps1")
$my        = Initialize-MySqlTestEnv -DefaultDb "club_smoke"
$dataRel   = "build\smoke-data"      # 只剩审计日志（audit.log）用；业务数据在 MySQL 里
$dataAbs   = Join-Path $root $dataRel
$logOut    = Join-Path $root "build\smoke-server.out.log"
$logErr    = Join-Path $root "build\smoke-server.err.log"
$base      = "http://127.0.0.1:$Port"

$script:pass = 0
$script:fail = 0

function Check([string]$name, [bool]$cond, [string]$extra = "") {
    if ($cond) {
        $script:pass++
        Write-Host ("  ok    " + $name)
    } else {
        $script:fail++
        Write-Host ("  FAIL  " + $name + "   " + $extra) -ForegroundColor Red
    }
}

# 调接口。返回 @{ status; json }；4xx/5xx 不抛异常，靠 status 判断。
function Call-Api([string]$method, [string]$path, $body = $null, [string]$token = "") {
    $headers = @{}
    if ($token) { $headers["Authorization"] = "Bearer $token" }
    $p = @{
        Method          = $method
        Uri             = "$base$path"
        UseBasicParsing = $true
        Headers         = $headers
        TimeoutSec      = 10
    }
    if ($null -ne $body) {
        # PS 5.1 的坑：Body 传字符串会按 ANSI 发送，中文到达服务端就是乱码。
        # 必须自己转成 UTF-8 字节，并在 Content-Type 里声明 charset。
        $json = if ($body -is [string]) { $body } else { $body | ConvertTo-Json -Compress }
        $p["ContentType"] = "application/json; charset=utf-8"
        $p["Body"] = [System.Text.Encoding]::UTF8.GetBytes($json)
    }
    try {
        $r = Invoke-WebRequest @p
        $j = $null
        if ($r.Content) { try { $j = $r.Content | ConvertFrom-Json } catch { } }
        return @{ status = [int]$r.StatusCode; json = $j; raw = [string]$r.Content; headers = $r.Headers }
    } catch {
        # PS 5.1：非 2xx 会抛异常。响应体优先取 ErrorDetails.Message——
        # Invoke-WebRequest 已经把响应流读走了，直接 GetResponseStream() 会拿到空串。
        $txt = ""
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $txt = [string]$_.ErrorDetails.Message }
        $resp = $_.Exception.Response
        if ((-not $txt) -and ($null -ne $resp)) {
            try {
                $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
                $txt = $sr.ReadToEnd()
                $sr.Close()
            } catch { }
        }
        $status = 0
        if ($null -ne $resp) { $status = [int]$resp.StatusCode }
        $j = $null
        if ($txt) { try { $j = $txt | ConvertFrom-Json } catch { } }
        $hdrs = @{}
        if ($null -ne $resp) { $hdrs = $resp.Headers }
        return @{ status = $status; json = $j; raw = $txt; headers = $hdrs }
    }
}

# 从 403/4xx 响应里取业务错误码
function ErrCode($r) {
    if ($null -eq $r.json) { return "" }
    return [string]$r.json.error.code
}

# 注册一个账号
function New-Account([string]$phone, [string]$name, [string]$pw, [string]$code) {
    return Call-Api "POST" "/api/v1/auth/register" @{ register_code = $code; phone = $phone; name = $name; password = $pw }
}

# 登录并返回 token（失败返回空串）
function Login-Token([string]$phone, [string]$pw) {
    $r = Call-Api "POST" "/api/v1/auth/login" @{ phone = $phone; password = $pw }
    if ($r.status -ne 200) { return "" }
    return [string]$r.json.data.token
}

function Start-Server([string]$dsn, [string]$logSuffix = "") {
    $o = $logOut
    $e = $logErr
    if ($logSuffix) {
        $o = $logOut -replace '\.log$', ".$logSuffix.log"
        $e = $logErr -replace '\.log$', ".$logSuffix.log"
    }
    $p = Start-Process -FilePath $Exe `
        -ArgumentList @("serve", "$Port", $dsn, "--data-dir", $dataRel) `
        -WorkingDirectory $root `
        -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $o -RedirectStandardError $e
    $p | Add-Member -NotePropertyName LogOut -NotePropertyValue $o -Force
    $ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 400
        if ($p.HasExited) { break }
        try {
            $r = Invoke-WebRequest "$base/health" -UseBasicParsing -TimeoutSec 2
            if ($r.StatusCode -eq 200) { $ready = $true; break }
        } catch { }
    }
    if (-not $ready) {
        if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
        $tail = ""
        if (Test-Path $logOut) { $tail = (Get-Content $logOut -Raw) }
        throw "服务未能在 :$Port 就绪。日志：`n$tail`n$logErr"
    }
    return $p
}

function Stop-Server($p) {
    if ($null -eq $p) { return }
    if (-not $p.HasExited) {
        try { $p.Kill() } catch { }
    }
    try { $p.WaitForExit(3000) | Out-Null } catch { }
}

Push-Location $root
try {
    Write-Host "=== 社团管理工具 · 服务端冒烟测试 ==="
    Write-Host "可执行文件: $Exe"
    Write-Host "审计日志目录: $dataRel（业务数据在 MySQL）"
    Write-Host ""

    # ---------- 准备：清库（DROP 9 张表）+ 初始化首任会长 ----------
    if (Test-Path $dataAbs) { Remove-Item -Recurse -Force $dataAbs }
    Remove-Item $logOut, $logErr -Force -ErrorAction SilentlyContinue
    Write-Host "[准备] 清掉测试库 $($my.Db) 的 9 张表（干净夹具）"
    Reset-ClubMySqlSchema $my.Db
    Check "测试库已清空（9 张表都不存在）" ((Invoke-ClubMySql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$($my.Db)' AND table_name IN ('departments','members','plans','tasks','invite_links','tokens','idem','meta','meta_str');" "") -match '0') "查 information_schema 失败"

    Write-Host "[准备] init-admin"
    & $Exe init-admin 13800000000 password123 $my.Dsn --data-dir $dataRel
    Check "init-admin 返回 0" ($LASTEXITCODE -eq 0) "exit=$LASTEXITCODE"
    # 数据真的进了 MySQL（不是"某个文件里出现了某个字符串"）
    Check "MySQL 里已建出 members 表" ((Invoke-ClubMySql "SHOW TABLES LIKE 'members';" $my.Db) -match 'members')
    Check "MySQL 里已有 1 个成员（会长）" ((Invoke-ClubMySql "SELECT COUNT(*) FROM members;" $my.Db).Trim() -eq '1')
    Check "MySQL 里已有 4 个预置部门" ((Invoke-ClubMySql "SELECT COUNT(*) FROM departments;" $my.Db).Trim() -eq '4')

    # 注：SQL 里不用反引号 —— PowerShell 双引号串里的 ` 是转义符，会被吃掉。
    # meta_str.k 在本查询里没有歧义，裸列名即可。
    $regCode = (Invoke-ClubMySql "SELECT v FROM meta_str WHERE k='register_code';" $my.Db).Trim()
    Check "注册口令已生成（6 位）" ($regCode.Length -eq 6) "code=$regCode"
    $deptCount = [int](Invoke-ClubMySql "SELECT COUNT(*) FROM departments;" $my.Db).Trim()
    Check "预置 4 个组织" ($deptCount -eq 4) "count=$deptCount"

    Write-Host "[准备] init-admin 重复执行应被拒绝"
    & $Exe init-admin 13800000001 password123 $my.Dsn --data-dir $dataRel | Out-Null
    Check "重复 init-admin 返回 1" ($LASTEXITCODE -eq 1) "exit=$LASTEXITCODE"

    # 运维账号（role = ops）：名录要**隐藏**它（它不是社团成员，客户端那 5 档标签也认不出），
    # 但它必须真实存在 —— 下面用它的 id 反查详情来证明"是隐藏、不是丢失"。
    Write-Host "[准备] init-ops（系统账号，名录里应被隐藏）"
    $opsOut = & $Exe init-ops 13800000009 opspassword $my.Dsn --data-dir $dataRel 2>&1 | Out-String
    Check "init-ops 返回 0" ($LASTEXITCODE -eq 0) "out=$opsOut"
    $opsId = 0
    if ($opsOut -match '成员 id=(\d+)') { $opsId = [int]$Matches[1] }
    Check "拿到运维账号 id" ($opsId -gt 0) "out=$opsOut"
    Check "运维账号也在 MySQL 里" ((Invoke-ClubMySql "SELECT COUNT(*) FROM members WHERE role='ops';" $my.Db).Trim() -eq '1')

    # ---------- 启动服务 ----------
    Write-Host ""
    Write-Host "[启动] serve :$Port"
    $proc = Start-Server $my.Dsn
    Check "服务已就绪" ($null -ne $proc)

    # ---------- 1. 健康检查 ----------
    Write-Host ""
    Write-Host "[1] 健康检查 /health（不带 /api 前缀、不需认证）"
    $r = Call-Api "GET" "/health"
    Check "GET /health -> 200" ($r.status -eq 200) "status=$($r.status)"
    Check "/health ok=true" ($r.json.ok -eq $true)
    Check "/health 带 version" ($null -ne $r.json.data.version)

    # ---------- 2. 认证 ----------
    Write-Host ""
    Write-Host "[2] 登录与令牌"
    $r = Call-Api "POST" "/api/v1/auth/login" @{ phone = "13800000000"; password = "password123" }
    Check "会长登录 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    $presToken = [string]$r.json.data.token
    Check "返回 token（64 hex）" ($presToken.Length -eq 64) "len=$($presToken.Length)"
    Check "member.role = president" ($r.json.data.member.role -eq "president")
    Check "member 不含手机号" ($null -eq $r.json.data.member.phone)
    Check "permissions.set_role = true" ($r.json.data.permissions.set_role -eq $true)
    Check "permissions.view_scope = all" ($r.json.data.permissions.view_scope -eq "all")
    Check "expires_at 为 +08:00" ($r.json.data.expires_at -like "*+08:00")

    $r = Call-Api "GET" "/api/v1/auth/me" $null $presToken
    Check "GET /auth/me -> 200" ($r.status -eq 200) "status=$($r.status)"
    Check "本人视图含手机号" ($r.json.data.member.phone -eq "13800000000")

    $r = Call-Api "GET" "/api/v1/auth/me"
    Check "无令牌 -> 401 AUTH_REQUIRED" (($r.status -eq 401) -and ((ErrCode $r) -eq "AUTH_REQUIRED")) "status=$($r.status) code=$(ErrCode $r)"

    $r = Call-Api "GET" "/api/v1/auth/me" $null "deadbeef"
    Check "伪造令牌 -> 401" ($r.status -eq 401) "status=$($r.status)"

    $r = Call-Api "POST" "/api/v1/auth/login" @{ phone = "13800000000"; password = "wrong-password" }
    Check "密码错误 -> 401 AUTH_BAD_CREDENTIALS" (($r.status -eq 401) -and ((ErrCode $r) -eq "AUTH_BAD_CREDENTIALS")) "status=$($r.status) code=$(ErrCode $r)"

    $r = Call-Api "POST" "/api/v1/auth/login" @{ phone = "19900000000"; password = "whatever123" }
    Check "不存在的手机号 -> 同 401 错误码（不泄露是否注册）" (($r.status -eq 401) -and ((ErrCode $r) -eq "AUTH_BAD_CREDENTIALS")) "status=$($r.status)"

    # ---------- 3. 注册（注册与授权分离） ----------
    Write-Host ""
    Write-Host "[3] 注册：注册即登录，但账号是 pending"
    $r = Call-Api "POST" "/api/v1/auth/register" @{ register_code = "WRONG1"; phone = "13900000001"; name = "张三"; password = "abc12345" }
    Check "口令错误 -> 400 REGISTER_CODE_INVALID" (($r.status -eq 400) -and ((ErrCode $r) -eq "REGISTER_CODE_INVALID")) "status=$($r.status) code=$(ErrCode $r)"

    $r = Call-Api "POST" "/api/v1/auth/register" @{ register_code = $regCode; phone = ""; name = ""; password = "" }
    Check "缺字段 -> 400 VALIDATION_FAILED" (($r.status -eq 400) -and ((ErrCode $r) -eq "VALIDATION_FAILED")) "status=$($r.status)"
    Check "fields 逐字段给原因" ($null -ne $r.json.error.fields.phone) "fields=$($r.json.error.fields | ConvertTo-Json -Compress)"

    $r = Call-Api "POST" "/api/v1/auth/register" @{ register_code = $regCode; phone = "1390000000"; name = "张三"; password = "abc12345" }
    Check "手机号格式错 -> 400" ($r.status -eq 400) "status=$($r.status)"

    $r = Call-Api "POST" "/api/v1/auth/register" @{ register_code = $regCode; phone = "13900000001"; name = "张三"; password = "abc12345" }
    Check "正常注册 -> 201" ($r.status -eq 201) "status=$($r.status) code=$(ErrCode $r)"
    $newToken = [string]$r.json.data.token
    Check "新账号 status = pending" ($r.json.data.member.status -eq "pending")
    Check "pending 的 role 为 null" ($null -eq $r.json.data.member.role)
    Check "pending 的 dept 为 null" ($null -eq $r.json.data.member.dept)
    Check "pending view_scope = none" ($r.json.data.permissions.view_scope -eq "none")
    Check "pending 无任何权限" ($r.json.data.permissions.create_task -eq $false)

    $r = Call-Api "POST" "/api/v1/auth/register" @{ register_code = $regCode; phone = "13900000001"; name = "张三"; password = "abc12345" }
    Check "重复手机号 -> 409 ALREADY_EXISTS" (($r.status -eq 409) -and ((ErrCode $r) -eq "ALREADY_EXISTS")) "status=$($r.status) code=$(ErrCode $r)"

    $r = Call-Api "GET" "/api/v1/auth/me" $null $newToken
    Check "pending 账号登录后 /auth/me 仍 200（不是错误）" ($r.status -eq 200) "status=$($r.status)"
    Check "pending view_scope = none" ($r.json.data.permissions.view_scope -eq "none")

    # ---------- 4. 登录限流 ----------
    Write-Host ""
    Write-Host "[4] 登录限流（同一手机号 15 分钟内失败 5 次 -> 锁定）"
    $last = $null
    for ($i = 1; $i -le 5; $i++) {
        $last = Call-Api "POST" "/api/v1/auth/login" @{ phone = "13900000001"; password = "definitely-wrong" }
    }
    Check "第 5 次失败仍是 401" ($last.status -eq 401) "status=$($last.status)"
    $r = Call-Api "POST" "/api/v1/auth/login" @{ phone = "13900000001"; password = "definitely-wrong" }
    Check "第 6 次 -> 429 TOO_MANY_ATTEMPTS" (($r.status -eq 429) -and ((ErrCode $r) -eq "TOO_MANY_ATTEMPTS")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/auth/login" @{ phone = "13900000001"; password = "abc12345" }
    Check "锁定期间正确密码也被拒" ($r.status -eq 429) "status=$($r.status)"

    # ---------- 5. 注销 ----------
    Write-Host ""
    Write-Host "[5] 注销后令牌立即失效"
    $r = Call-Api "POST" "/api/v1/auth/logout" $null $newToken
    Check "logout -> 200" ($r.status -eq 200) "status=$($r.status)"
    $r = Call-Api "GET" "/api/v1/auth/me" $null $newToken
    Check "旧令牌已失效 -> 401" ($r.status -eq 401) "status=$($r.status)"

    # ---------- 6. 改密码 ----------
    Write-Host ""
    Write-Host "[6] 本人改密码"
    $r = Call-Api "PUT" "/api/v1/auth/password" @{ old_password = "nope"; new_password = "newpassword1" } $presToken
    Check "原密码错误 -> 401" (($r.status -eq 401) -and ((ErrCode $r) -eq "AUTH_BAD_CREDENTIALS")) "status=$($r.status)"

    # 再造一个会长的令牌，用来验证"改密后其它令牌全部失效"
    $r = Call-Api "POST" "/api/v1/auth/login" @{ phone = "13800000000"; password = "password123" }
    $extraToken = [string]$r.json.data.token
    Check "第二个令牌签发成功" ($extraToken.Length -eq 64)

    $r = Call-Api "PUT" "/api/v1/auth/password" @{ old_password = "password123"; new_password = "newpassword1" } $presToken
    Check "改密码 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "GET" "/api/v1/auth/me" $null $extraToken
    Check "其它令牌已失效 -> 401" ($r.status -eq 401) "status=$($r.status)"
    $r = Call-Api "GET" "/api/v1/auth/me" $null $presToken
    Check "当前令牌仍有效 -> 200" ($r.status -eq 200) "status=$($r.status)"
    $r = Call-Api "POST" "/api/v1/auth/login" @{ phone = "13800000000"; password = "password123" }
    Check "旧密码登录 -> 401" ($r.status -eq 401) "status=$($r.status)"
    $r = Call-Api "POST" "/api/v1/auth/login" @{ phone = "13800000000"; password = "newpassword1" }
    Check "新密码登录 -> 200" ($r.status -eq 200) "status=$($r.status)"
    $presToken = [string]$r.json.data.token

    # ---------- 7. 路由层 ----------
    Write-Host ""
    Write-Host "[7] 路由与错误包装"
    $r = Call-Api "GET" "/api/v1/nope"
    Check "未知路径 -> 404" ($r.status -eq 404) "status=$($r.status)"
    $r = Call-Api "GET" "/api/v1/auth/login"
    Check "方法不对 -> 405" ($r.status -eq 405) "status=$($r.status)"
    $r = Call-Api "POST" "/api/v1/auth/login" "not-a-json-object"
    Check "坏请求体 -> 400" ($r.status -eq 400) "status=$($r.status)"

    # ---------- 8. 部门（组织） ----------
    Write-Host ""
    Write-Host "[8] 部门：会长独占增删改"
    $presId = (Call-Api "GET" "/api/v1/auth/me" $null $presToken).json.data.member.id
    $r = Call-Api "GET" "/api/v1/depts" $null $presToken
    Check "GET /depts -> 200" ($r.status -eq 200) "status=$($r.status)"

    # ---------- 系统账号（ops）在名录里不可见，但它确实存在 ----------
    # ⚠ 用独立的 $rm：这段紧跟上面的 /depts 断言，复用 $r 会把后面的断言读串（真踩过）。
    # ⚠ Call-Api 返回的是 @{status; json; raw}（没有 .body），断言要用 .raw / .json —— 用 .body 会静默变成空串，
    #    "-notmatch" 永远为真 = 假通过（本轮真踩过：3 条断言里 2 条是假的）。
    $rm = Call-Api "GET" "/api/v1/members" $null $presToken
    Check "名录里没有运维账号（隐藏系统账号）" (($rm.status -eq 200) -and ($rm.raw -notmatch '"role":"ops"') -and ($rm.raw -notmatch '13800000009')) "raw=$($rm.raw)"
    $rm = Call-Api "GET" "/api/v1/members?q=13800000009" $null $presToken
    Check "按手机号也搜不到运维账号（q= 搜索同样过滤）" (($rm.status -eq 200) -and ($rm.raw -notmatch '13800000009')) "raw=$($rm.raw)"
    $rm = Call-Api "GET" "/api/v1/members/$opsId" $null $presToken
    Check "运维账号本身仍在（按 id 能查到，是隐藏不是丢失）" (($rm.status -eq 200) -and ($rm.json.data.member.role -eq 'ops')) "status=$($rm.status) raw=$($rm.raw)"
    Check "预置 4 个组织" ($r.json.data.items.Count -eq 4) "count=$($r.json.data.items.Count)"
    $deptOps = ($r.json.data.items | Where-Object { $_.name -eq "运营部" }).id
    $deptPub = ($r.json.data.items | Where-Object { $_.name -eq "宣传部" }).id
    Check "部门含 member_count（软提示）" ($null -ne $r.json.data.items[0].member_count)

    $r = Call-Api "POST" "/api/v1/depts" @{ name = "技术部"; sort = 9 } $presToken
    Check "会长新建部门 -> 201" ($r.status -eq 201) "status=$($r.status) code=$(ErrCode $r)"
    $newDept = $r.json.data.dept.id
    $r = Call-Api "POST" "/api/v1/depts" @{ name = "技术部" } $presToken
    Check "部门重名 -> 409 ALREADY_EXISTS" (($r.status -eq 409) -and ((ErrCode $r) -eq "ALREADY_EXISTS")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "PATCH" "/api/v1/depts/$newDept" @{ name = "技术委员会"; sort = 10 } $presToken
    Check "改名 -> 200" ($r.status -eq 200) "status=$($r.status)"
    Check "改名已生效" ($r.json.data.dept.name -eq "技术委员会")
    $r = Call-Api "PATCH" "/api/v1/depts/$newDept" @{ lead_id = 9 } $presToken
    Check "传 lead_id -> 400（该字段不存在）" (($r.status -eq 400) -and ((ErrCode $r) -eq "VALIDATION_FAILED")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "DELETE" "/api/v1/depts/$newDept" $null $presToken
    Check "删除空部门 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "PATCH" "/api/v1/depts/99999" @{ name = "x" } $presToken
    Check "改不存在的部门 -> 404" (($r.status -eq 404) -and ((ErrCode $r) -eq "DEPT_NOT_FOUND")) "status=$($r.status)"
    # M-8：sort 直接参与 `sort * 1000000 + id` 的排序键，越界会溢出并**落盘**，
    # 之后每次 GET /depts 都在排序时溢出 —— 接口永久 500，只能手改文件恢复。
    $r = Call-Api "POST" "/api/v1/depts" @{ name = "越界排序部门"; sort = 9223372036854775807 } $presToken
    Check "新建 sort 越界 -> 400（M-8）" (($r.status -eq 400) -and ((ErrCode $r) -eq "VALIDATION_FAILED")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "PATCH" "/api/v1/depts/$deptPub" @{ sort = 9223372036854775807 } $presToken
    Check "改 sort 越界 -> 400（M-8）" (($r.status -eq 400) -and ((ErrCode $r) -eq "VALIDATION_FAILED")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "GET" "/api/v1/depts" $null $presToken
    Check "GET /depts 仍然正常（M-8 没把接口打挂）" ($r.status -eq 200) "status=$($r.status)"

    # ---------- 9. 待分配与授权（招新主线） ----------
    Write-Host ""
    Write-Host "[9] 待分配与授权（注册与授权分离）"
    $leadPhone = "13900000010"
    $memPhone  = "13900000011"
    $newPhone  = "13900000012"
    $r = New-Account $leadPhone "部长候选人" "leadpw123" $regCode
    Check "注册部长候选人 -> 201" ($r.status -eq 201) "status=$($r.status) code=$(ErrCode $r)"
    $leadId = $r.json.data.member.id
    $leadPendingToken = [string]$r.json.data.token
    $r = New-Account $memPhone "普通成员" "mempw1234" $regCode
    $memId = $r.json.data.member.id
    Check "注册普通成员 -> 201" ($r.status -eq 201) "status=$($r.status)"
    $r = New-Account $newPhone "待分配乙" "newpw1234" $regCode
    $newId = $r.json.data.member.id
    Check "注册待分配乙 -> 201" ($r.status -eq 201) "status=$($r.status)"

    $r = Call-Api "GET" "/api/v1/members/pending" $null $presToken
    Check "待分配列表 -> 200" ($r.status -eq 200) "status=$($r.status)"
    Check "待分配含 4 人（含 M1 段注册的 13900000001）" ($r.json.data.items.Count -eq 4) "count=$($r.json.data.items.Count)"
    Check "待分配含 registered_at" ($null -ne $r.json.data.items[0].registered_at)

    $r = Call-Api "GET" "/api/v1/members/pending" $null $leadPendingToken
    Check "pending 账号查待分配 -> 403 MEMBER_PENDING" (($r.status -eq 403) -and ((ErrCode $r) -eq "MEMBER_PENDING")) "status=$($r.status) code=$(ErrCode $r)"

    $r = Call-Api "POST" "/api/v1/members/$leadId/assign" @{ dept_id = $deptOps; role = "lead" } $presToken
    Check "分配部长 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    Check "分配后 status=active" ($r.json.data.status -eq "active")
    Check "分配后 role=lead" ($r.json.data.role -eq "lead")
    Check "分配后 dept 正确" ($r.json.data.dept.id -eq $deptOps)
    $r = Call-Api "POST" "/api/v1/members/$leadId/assign" @{ dept_id = $deptOps; role = "lead" } $presToken
    Check "重复分配幂等 -> 200" ($r.status -eq 200) "status=$($r.status)"
    $r = Call-Api "POST" "/api/v1/members/$memId/assign" @{ dept_id = $deptOps; role = "member" } $presToken
    Check "分配普通成员 -> 200" ($r.status -eq 200) "status=$($r.status)"
    $r = Call-Api "POST" "/api/v1/members/99999/assign" @{ dept_id = $deptOps; role = "member" } $presToken
    Check "分配不存在的成员 -> 404" (($r.status -eq 404) -and ((ErrCode $r) -eq "MEMBER_NOT_FOUND")) "status=$($r.status)"
    $r = Call-Api "POST" "/api/v1/members/$newId/assign" @{ dept_id = $deptOps; role = "president" } $presToken
    Check "assign 授予 president -> 400" (($r.status -eq 400) -and ((ErrCode $r) -eq "VALIDATION_FAILED")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/members/$newId/assign" @{ dept_id = 99999; role = "member" } $presToken
    Check "分配到不存在的部门 -> 404" (($r.status -eq 404) -and ((ErrCode $r) -eq "DEPT_NOT_FOUND")) "status=$($r.status)"

    $r = Call-Api "POST" "/api/v1/members/assign-batch" @{ member_ids = @($newId, 99999); dept_id = $deptPub; role = "member" } $presToken
    Check "批量分配 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    Check "批量：成功 1 条" ($r.json.data.succeeded.Count -eq 1) "succeeded=$($r.json.data.succeeded | ConvertTo-Json -Compress)"
    Check "批量：失败 1 条" ($r.json.data.failed.Count -eq 1)
    Check "批量：失败原因是 MEMBER_NOT_FOUND" ($r.json.data.failed[0].code -eq "MEMBER_NOT_FOUND")
    Check "批量：成功的那条真的生效了（部分成功不回滚）" ($r.json.data.succeeded[0] -eq $newId)

    $r = Call-Api "DELETE" "/api/v1/depts/$deptOps" $null $presToken
    Check "删除非空部门 -> 409 DEPT_NOT_EMPTY" (($r.status -eq 409) -and ((ErrCode $r) -eq "DEPT_NOT_EMPTY")) "status=$($r.status) code=$(ErrCode $r)"

    # ---------- 10. 成员名录与编辑 ----------
    Write-Host ""
    Write-Host "[10] 成员名录与编辑"
    $r = Call-Api "GET" "/api/v1/members" $null $presToken
    Check "GET /members -> 200" ($r.status -eq 200) "status=$($r.status)"
    Check "分页字段齐全" (($null -ne $r.json.data.total) -and ($null -ne $r.json.data.page) -and ($null -ne $r.json.data.size))
    Check "page 从 1 开始" ($r.json.data.page -eq 1)
    Check "名录不含手机号" (-not ($r.json.data.items[0].PSObject.Properties.Name -contains "phone"))
    $r = Call-Api "GET" "/api/v1/members?dept_id=$deptOps" $null $presToken
    Check "按部门筛选" ($r.json.data.total -eq 2) "total=$($r.json.data.total)"
    $r = Call-Api "GET" "/api/v1/members?status=disabled" $null $presToken
    Check "按状态筛选（无已退出成员）" ($r.json.data.total -eq 0) "total=$($r.json.data.total)"
    $r = Call-Api "GET" "/api/v1/members?page=1&size=1" $null $presToken
    Check "size=1 生效" ($r.json.data.items.Count -eq 1)
    Check "size 超上限按 200" ((Call-Api "GET" "/api/v1/members?size=9999" $null $presToken).json.data.size -eq 200)

    $r = Call-Api "GET" "/api/v1/members/$memId" $null $presToken
    Check "成员详情 -> 200" ($r.status -eq 200) "status=$($r.status)"
    Check "详情含 stats.owned_tasks" ($null -ne $r.json.data.stats.owned_tasks)
    $r = Call-Api "GET" "/api/v1/members/99999" $null $presToken
    Check "不存在的成员 -> 404" (($r.status -eq 404) -and ((ErrCode $r) -eq "MEMBER_NOT_FOUND")) "status=$($r.status)"
    $r = Call-Api "GET" "/api/v1/members/abc" $null $presToken
    Check "非数字 id -> 404（不是 500）" ($r.status -eq 404) "status=$($r.status)"

    $r = Call-Api "PATCH" "/api/v1/members/$memId" @{ name = "普通成员改名" } $presToken
    Check "改姓名 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    Check "姓名已改" ($r.json.data.name -eq "普通成员改名") "got=[$($r.json.data.name)]"
    $r = Call-Api "PATCH" "/api/v1/members/$memId" @{ role = "president" } $presToken
    Check "PATCH 授予 president -> 400" (($r.status -eq 400) -and ((ErrCode $r) -eq "VALIDATION_FAILED")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "PATCH" "/api/v1/members/$memId" @{ role = "vip" } $presToken
    Check "非法角色 -> 400" ($r.status -eq 400) "status=$($r.status)"
    $r = Call-Api "PATCH" "/api/v1/members/$newId" @{ role = "member" } $presToken
    Check "改已分配成员的部门/角色 -> 200" ($r.status -eq 200) "status=$($r.status)"

    # 待分配成员不允许用 PATCH 授权（那属于 assign 的职责）
    $r = New-Account "13900000013" "仍未分配" "stillpw12" $regCode
    $stillId = $r.json.data.member.id
    $r = Call-Api "PATCH" "/api/v1/members/$stillId" @{ role = "member" } $presToken
    Check "待分配成员用 PATCH 授权 -> 400" (($r.status -eq 400) -and ((ErrCode $r) -eq "VALIDATION_FAILED")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "PATCH" "/api/v1/members/$stillId" @{ name = "仍未分配改名" } $presToken
    Check "待分配成员改姓名 -> 200" ($r.status -eq 200) "status=$($r.status)"

    # ---------- 11. 会长保护与移交 ----------
    Write-Host ""
    Write-Host "[11] 最后一个会长保护 + 会长移交（原子）"
    $vpPhone = "13900000014"
    $r = New-Account $vpPhone "副会长候选人" "vppw1234" $regCode
    $vpId = $r.json.data.member.id
    $r = Call-Api "POST" "/api/v1/members/$vpId/assign" @{ dept_id = 1; role = "vice_president" } $presToken
    Check "分配副会长 -> 200" ($r.status -eq 200) "status=$($r.status)"
    $vpToken = Login-Token $vpPhone "vppw1234"
    Check "副会长登录成功" ($vpToken.Length -eq 64)

    $r = Call-Api "GET" "/api/v1/register-config" $null $vpToken
    Check "副会长可查看注册口令 -> 200" ($r.status -eq 200) "status=$($r.status)"
    $r = Call-Api "PUT" "/api/v1/register-config/code" @{ code = "VPCODE" } $vpToken
    Check "副会长换口令 -> 403 FORBIDDEN_ROLE" (($r.status -eq 403) -and ((ErrCode $r) -eq "FORBIDDEN_ROLE")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/depts" @{ name = "副会长想建的部门" } $vpToken
    Check "副会长新建部门 -> 403（会长独占）" (($r.status -eq 403) -and ((ErrCode $r) -eq "FORBIDDEN_ROLE")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "DELETE" "/api/v1/depts/$deptPub" $null $vpToken
    Check "副会长删除部门 -> 403（会长独占）" (($r.status -eq 403) -and ((ErrCode $r) -eq "FORBIDDEN_ROLE")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "PATCH" "/api/v1/depts/$deptPub" @{ sort = 99 } $vpToken
    Check "副会长改部门 -> 403（会长独占）" ($r.status -eq 403) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/members/$presId/transfer-presidency" @{ self_role = "member" } $vpToken
    Check "副会长移交会长 -> 403" ($r.status -eq 403) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "PATCH" "/api/v1/members/$presId" @{ role = "member" } $vpToken
    Check "副会长改动会长本人 -> 403" ($r.status -eq 403) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "GET" "/api/v1/members/pending" $null $vpToken
    Check "副会长可看待分配 -> 200" ($r.status -eq 200) "status=$($r.status)"

    $r = Call-Api "PATCH" "/api/v1/members/$presId" @{ role = "member" } $presToken
    Check "会长把自己降级 -> 409 FORBIDDEN_LAST_PRESIDENT" (($r.status -eq 409) -and ((ErrCode $r) -eq "FORBIDDEN_LAST_PRESIDENT")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/members/$presId/disable" $null $presToken
    Check "禁用最后一个会长 -> 409" (($r.status -eq 409) -and ((ErrCode $r) -eq "FORBIDDEN_LAST_PRESIDENT")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/members/$presId/transfer-presidency" @{ self_role = "member" } $presToken
    Check "移交给自己 -> 400" ($r.status -eq 400) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/members/$stillId/transfer-presidency" @{ self_role = "member" } $presToken
    Check "移交给 pending 账号 -> 403 MEMBER_PENDING" (($r.status -eq 403) -and ((ErrCode $r) -eq "MEMBER_PENDING")) "status=$($r.status) code=$(ErrCode $r)"

    $r = Call-Api "POST" "/api/v1/members/$vpId/transfer-presidency" @{ self_role = "vice_president" } $presToken
    Check "会长移交给副会长 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    Check "新会长 role=president" ($r.json.data.president.role -eq "president")
    Check "原会长降为 vice_president" ($r.json.data.previous.role -eq "vice_president")
    $r = Call-Api "GET" "/api/v1/auth/me" $null $vpToken
    Check "新会长权限 view_scope=all" ($r.json.data.permissions.view_scope -eq "all")
    Check "新会长 permissions.set_role=true" ($r.json.data.permissions.set_role -eq $true)
    $r = Call-Api "POST" "/api/v1/members/$presId/transfer-presidency" @{ self_role = "member" } $presToken
    Check "已不是会长者移交 -> 403" ($r.status -eq 403) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/members/$presId/transfer-presidency" @{ self_role = "vice_president" } $vpToken
    Check "新会长移交回原会长 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "GET" "/api/v1/auth/me" $null $presToken
    Check "角色已复原为 president" ($r.json.data.member.role -eq "president")

    # ---------- 12. 重置密码 ----------
    Write-Host ""
    Write-Host "[12] 重置密码（会长/副会长/本部门部长/本人）"
    $r = Call-Api "POST" "/api/v1/members/$memId/reset-password" $null $presToken
    Check "会长重置成员密码 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    $tempPw = [string]$r.json.data.temporary_password
    Check "返回 8 位临时密码" ($tempPw.Length -eq 8) "temp=$tempPw"
    $tmpToken = Login-Token $memPhone $tempPw
    Check "用临时密码可登录" ($tmpToken.Length -eq 64)
    Check "旧密码已失效" ((Login-Token $memPhone "mempw1234").Length -eq 0)

    $leadToken = Login-Token $leadPhone "leadpw123"
    Check "部长登录成功" ($leadToken.Length -eq 64)
    $r = Call-Api "POST" "/api/v1/members/$memId/reset-password" $null $leadToken
    Check "部长重置本部门成员密码 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    # L-4：口径统一为"管理员救济动作，本人不适用"（本人改密走 PUT /auth/password）。
    # 这条断言把语义钉死，避免以后又出现两处文档打架。
    $memPwAfterLead = [string]$r.json.data.temporary_password
    $memSelfToken = Login-Token $memPhone $memPwAfterLead
    Check "成员用新临时密码登录" ($memSelfToken.Length -eq 64)
    $r = Call-Api "POST" "/api/v1/members/$memId/reset-password" $null $memSelfToken
    Check "成员对自己重置密码 -> 403（L-4 本人改密走 /auth/password）" (($r.status -eq 403) -and ((ErrCode $r) -eq "FORBIDDEN_ROLE")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/members/$newId/reset-password" $null $leadToken
    Check "部长重置外部门成员密码 -> 403 FORBIDDEN_NOT_IN_DEPT" (($r.status -eq 403) -and ((ErrCode $r) -eq "FORBIDDEN_NOT_IN_DEPT")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/members/$presId/reset-password" $null $leadToken
    Check "部长重置会长密码 -> 403" ($r.status -eq 403) "status=$($r.status) code=$(ErrCode $r)"

    # N-7：reset-password 是"管理员救济动作"，**不含本人** —— 对会长/副会长同样成立。
    # 他们的角色分支是"直接放行"，所以只有动作语义层拦得住；而这条路径收尾会
    # revokeOtherTokens(s, tgt.id, "") 把目标的所有令牌作废，对自己执行就是
    # "响应 200、自己当场掉线"。下面两条必须成对：既要有 403，也要证明会长的 token
    # 没被误伤（否则"成功即掉线"会以紧跟着的 401 形式溜过去）。
    $r = Call-Api "POST" "/api/v1/members/$presId/reset-password" $null $presToken
    Check "会长对自己重置密码 -> 403 FORBIDDEN_ROLE（N-7）" (($r.status -eq 403) -and ((ErrCode $r) -eq "FORBIDDEN_ROLE")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "GET" "/api/v1/auth/me" $null $presToken
    Check "会长自己的令牌仍然有效（N-7：没有成功后掉线）" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/members/$vpId/reset-password" $null $vpToken
    Check "副会长对自己重置密码 -> 403（N-7）" (($r.status -eq 403) -and ((ErrCode $r) -eq "FORBIDDEN_ROLE")) "status=$($r.status) code=$(ErrCode $r)"

    # 「不可重置与自己同权或更高权的人」——这条通用规则把 N-7（对自己即同权）一并覆盖。
    # 现有成员里只有一个副会长，所以临时造一个同权对照（13900000019 这个号段未被占用）。
    $r = New-Account "13900000019" "同权副会长" "peerpw123" $regCode
    $peerId = $r.json.data.member.id
    $r = Call-Api "POST" "/api/v1/members/$peerId/assign" @{ dept_id = 1; role = "vice_president" } $presToken
    Check "造第二个副会长（同权对照）-> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/members/$peerId/reset-password" $null $vpToken
    Check "副会长重置另一位副会长（同权）-> 403 FORBIDDEN_ROLE" (($r.status -eq 403) -and ((ErrCode $r) -eq "FORBIDDEN_ROLE")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/members/$peerId/reset-password" $null $presToken
    Check "会长重置副会长（更低档）-> 200（未过度收紧）" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"

    # 同权约束推广到改名 / 改角色 / 禁用（2026-09-14）：
    # 只保护重置密码是不够的——副会长原本可以把**另一位副会长**降级为 member 或直接禁用。
    $r = Call-Api "PATCH" "/api/v1/members/$peerId" @{ role = "member" } $vpToken
    Check "副会长把另一位副会长降级 -> 403 FORBIDDEN_ROLE" (($r.status -eq 403) -and ((ErrCode $r) -eq "FORBIDDEN_ROLE")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/members/$peerId/disable" $null $vpToken
    Check "副会长禁用另一位副会长 -> 403 FORBIDDEN_ROLE" (($r.status -eq 403) -and ((ErrCode $r) -eq "FORBIDDEN_ROLE")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "PATCH" "/api/v1/members/$peerId" @{ name = "被同僚改掉的名字" } $vpToken
    Check "副会长改另一位副会长的姓名 -> 403 FORBIDDEN_ROLE" (($r.status -eq 403) -and ((ErrCode $r) -eq "FORBIDDEN_ROLE")) "status=$($r.status) code=$(ErrCode $r)"
    # 反证：会长对这些目标仍然放行（没有过度收紧），且会长令牌未被误伤
    $r = Call-Api "PATCH" "/api/v1/members/$peerId" @{ role = "vice_president" } $presToken
    Check "会长改副会长角色 -> 200（未过度收紧）" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "GET" "/api/v1/auth/me" $null $presToken
    Check "会长令牌仍然有效（推广未误伤）" ($r.status -eq 200) "status=$($r.status)"

    # N-10：assign / assign-batch 也是成员处置类动作（同样写 role 与 status），
    # 必须受同一条同权约束。此前同权用例只走 PATCH / disable / reset-password 三条路，
    # 于是这两条路径漏了 —— "一个能力只测了一条实现路径"，与 H-1 的假绿灯同模式。
    $r = Call-Api "POST" "/api/v1/members/$peerId/assign" @{ dept_id = 1; role = "member" } $vpToken
    Check "副会长用 assign 降级另一位副会长 -> 403 FORBIDDEN_ROLE（N-10）" (($r.status -eq 403) -and ((ErrCode $r) -eq "FORBIDDEN_ROLE")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/members/assign-batch" @{ member_ids = @($peerId); dept_id = 1; role = "member" } $vpToken
    $peerFail = $r.json.data.failed | Where-Object { $_.id -eq $peerId }
    Check "批量 assign 对同权者 -> failed 记 FORBIDDEN_ROLE（N-10）" (($r.status -eq 200) -and ($null -ne $peerFail) -and ($peerFail.code -eq "FORBIDDEN_ROLE")) "status=$($r.status) json=$($r.json | ConvertTo-Json -Compress)"
    # 反证：没有过度收紧 —— 会长对同权目标仍放行，同权者仍能合法处置更低档的人
    $r = Call-Api "POST" "/api/v1/members/$peerId/assign" @{ dept_id = 1; role = "vice_president" } $presToken
    Check "会长用 assign 调整副会长 -> 200（未过度收紧）" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/members/$newId/assign" @{ dept_id = $deptPub; role = "member" } $vpToken
    Check "副会长用 assign 调整普通成员（更低档）-> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"

    $r = Call-Api "POST" "/api/v1/depts" @{ name = "部长想建的部门" } $leadToken
    Check "部长新建部门 -> 403" ($r.status -eq 403) "status=$($r.status)"
    $r = Call-Api "POST" "/api/v1/members/$stillId/assign" @{ dept_id = $deptOps; role = "member" } $leadToken
    Check "部长审批待分配 -> 403（审批统一归会长/副会长）" ($r.status -eq 403) "status=$($r.status) code=$(ErrCode $r)"

    # H-1 回归（P0 权限漏洞）：上面那条"部长重置会长密码 -> 403"是**假绿灯**——
    # 会长在主席团、部长在运营部，403 其实是 FORBIDDEN_NOT_IN_DEPT 挡的，
    # 角色维度的漏洞根本没被测到。这里把部长临时调进会长所在的部门再试一次。
    $r = Call-Api "GET" "/api/v1/depts" $null $presToken
    $deptPres = ($r.json.data.items | Where-Object { $_.name -eq "主席团" }).id
    $r = Call-Api "PATCH" "/api/v1/members/$leadId" @{ dept_id = $deptPres } $presToken
    Check "会长把部长临时调进主席团" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/members/$presId/reset-password" $null $leadToken
    Check "同部门部长重置会长密码 -> 403 FORBIDDEN_ROLE（H-1）" (($r.status -eq 403) -and ((ErrCode $r) -eq "FORBIDDEN_ROLE")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "PATCH" "/api/v1/members/$presId" @{ name = "被部长改掉的会长" } $leadToken
    Check "同部门部长改会长姓名 -> 403 FORBIDDEN_ROLE（H-1）" (($r.status -eq 403) -and ((ErrCode $r) -eq "FORBIDDEN_ROLE")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/members/$vpId/reset-password" $null $leadToken
    Check "同部门部长重置副会长密码 -> 403 FORBIDDEN_ROLE（H-1）" (($r.status -eq 403) -and ((ErrCode $r) -eq "FORBIDDEN_ROLE")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "GET" "/api/v1/auth/me" $null $presToken
    Check "会长姓名未被改动（H-1 真的挡住了）" ($r.json.data.member.name -ne "被部长改掉的会长") "name=$($r.json.data.member.name)"
    # 同档位保护：部长也改不了同部门的另一位部长
    $r = Call-Api "PATCH" "/api/v1/members/$leadId" @{ name = "部长改名" } $leadToken
    Check "部长改自己姓名 -> 200（改名不是提权）" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "PATCH" "/api/v1/members/$leadId" @{ name = "部长候选人" } $presToken
    Check "复原部长姓名" ($r.status -eq 200) "status=$($r.status)"
    $r = Call-Api "PATCH" "/api/v1/members/$leadId" @{ dept_id = $deptOps } $presToken
    Check "复原：部长回到运营部" ($r.status -eq 200) "status=$($r.status)"

    # ---------- 13. 注册配置 ----------
    Write-Host ""
    Write-Host "[13] 注册口令：查看 / 更换 / 轮换"
    $r = Call-Api "GET" "/api/v1/register-config" $null $presToken
    Check "会长查看口令 -> 200" ($r.status -eq 200) "status=$($r.status)"
    Check "口令含操作人" ($null -ne $r.json.data.updated_by)
    $oldCode = [string]$r.json.data.code
    $r = Call-Api "PUT" "/api/v1/register-config/code" @{ code = "NEWCODE1" } $presToken
    Check "会长换口令 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    Check "返回新口令" ($r.json.data.code -eq "NEWCODE1")
    $r = New-Account "13900000015" "旧口令注册" "oldcode12" $oldCode
    Check "旧口令立即失效 -> 400" (($r.status -eq 400) -and ((ErrCode $r) -eq "REGISTER_CODE_INVALID")) "status=$($r.status) code=$(ErrCode $r)"
    $r = New-Account "13900000016" "新口令注册" "newcode12" "NEWCODE1"
    Check "新口令可注册 -> 201" ($r.status -eq 201) "status=$($r.status)"
    $regCode = "NEWCODE1"
    $r = Call-Api "PUT" "/api/v1/register-config/code" @{ code = "ab" } $presToken
    Check "口令过短（2 位）-> 400" ($r.status -eq 400) "status=$($r.status)"
    # M-2：下限从 4 提到 6，5 位也必须拒
    $r = Call-Api "PUT" "/api/v1/register-config/code" @{ code = "ABCDE" } $presToken
    Check "口令 5 位 -> 400（M-2 下限 6）" ($r.status -eq 400) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "PUT" "/api/v1/register-config/code" @{ code = "ABCDEF" } $presToken
    Check "口令 6 位 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/register-config/rotate" $null $presToken
    Check "随机轮换 -> 200" ($r.status -eq 200) "status=$($r.status)"
    $regCode = [string]$r.json.data.code
    Check "轮换后口令变化且 6 位" (($regCode.Length -eq 6) -and ($regCode -ne "NEWCODE1")) "code=$regCode"

    # ---------- 14. 部门招募链接 ----------
    Write-Host ""
    Write-Host "[14] 招募链接（只预填部门，不赋予角色）"
    $r = Call-Api "POST" "/api/v1/dept-invite-links" @{ dept_id = $deptPub } $presToken
    Check "创建招募链接 -> 201" ($r.status -eq 201) "status=$($r.status) code=$(ErrCode $r)"
    $linkToken = [string]$r.json.data.token
    Check "返回 token（16 字节 = 32 位十六进制，N-19）" ($linkToken.Length -eq 32) "token=$linkToken"
    Check "返回 url 含 /join/" (([string]$r.json.data.url) -like "*/join/*")
    $r = Call-Api "POST" "/api/v1/dept-invite-links" @{ dept_id = 99999 } $presToken
    Check "链接指向不存在的部门 -> 404" (($r.status -eq 404) -and ((ErrCode $r) -eq "DEPT_NOT_FOUND")) "status=$($r.status)"
    $r = Call-Api "POST" "/api/v1/dept-invite-links" @{ dept_id = $deptPub } $vpToken
    Check "副会长可管招募链接 -> 201" ($r.status -eq 201) "status=$($r.status)"

    $r = Call-Api "GET" "/api/v1/dept-invite-links" $null $presToken
    Check "链接列表 -> 200" ($r.status -eq 200) "status=$($r.status)"
    Check "列表含 2 条" ($r.json.data.items.Count -eq 2) "count=$($r.json.data.items.Count)"
    Check "列表含部门名" ($null -ne $r.json.data.items[0].dept.name)

    # 通过招募链接进来的人：客户端把链接里的 dept_id 带进注册请求（只做预填）
    $r = Call-Api "POST" "/api/v1/auth/register" @{ register_code = $regCode; phone = "13900000017"; name = "链接进来的人"; password = "linkpw123"; dept_id = $deptPub }
    Check "经链接注册 -> 201" ($r.status -eq 201) "status=$($r.status) code=$(ErrCode $r)"
    $linkMemberId = $r.json.data.member.id
    $r = Call-Api "GET" "/api/v1/members/pending" $null $presToken
    $hinted = $r.json.data.items | Where-Object { $_.id -eq $linkMemberId }
    Check "待分配项带 dept_hint（来自链接）" ($hinted.dept_hint.id -eq $deptPub) "hint=$($hinted.dept_hint | ConvertTo-Json -Compress)"
    $r = Call-Api "POST" "/api/v1/members/$linkMemberId/assign" @{ dept_id = $hinted.dept_hint.id; role = "member" } $presToken
    Check "按链接预填直接分配 -> 200" ($r.status -eq 200) "status=$($r.status)"

    # L-2：落地页必须真的存在（链接是要发到群里的，点开不能是 404）
    $r = Call-Api "GET" "/join/$linkToken"
    Check "GET /join/{token} -> 200（L-2 落地页）" ($r.status -eq 200) "status=$($r.status)"
    Check "落地页是 HTML" ($r.raw -like "*<html*") "raw=$($r.raw.Substring(0, [Math]::Min(40, $r.raw.Length)))"
    $r = Call-Api "GET" "/join/nonexistent"
    Check "失效链接落地页 -> 200（提示已失效）" (($r.status -eq 200) -and ($r.raw -like "*失效*")) "status=$($r.status)"

    # ---------- 14b. 招募链接 → App 的部门预填闭环（D-16，2026-09-16） ----------
    # 方案 1：App 免认证把 token 换成 dept_id（原先只有 HTML 落地页，链路不闭环）
    $r = Call-Api "GET" "/api/v1/join/$linkToken"
    Check "D16 公开解析 token -> 200（免认证）" ($r.status -eq 200) "status=$($r.status)"
    Check "D16 解析出部门 id" ($r.json.data.dept.id -eq $deptPub) "dept=$($r.json.data.dept | ConvertTo-Json -Compress)"
    Check "D16 解析出部门 name（客户端要显示预填块）" ($null -ne $r.json.data.dept.name)
    Check "D16 enabled=true" ($r.json.data.enabled -eq $true)
    $r = Call-Api "GET" "/api/v1/join/nonexistent"
    Check "D16 不存在的 token -> 200 + dept=null（与失效同形状，客户端不写特例）" (($r.status -eq 200) -and ($null -eq $r.json.data.dept) -and ($r.json.data.enabled -eq $false)) "status=$($r.status)"
    # 方案 2：注册带 invite_token，部门由**服务端**从 token 推导（不再信任客户端自报的 dept_id）
    $r = Call-Api "POST" "/api/v1/auth/register" @{ register_code = $regCode; phone = "13900000021"; name = "带token注册"; password = "tokenpw12"; invite_token = $linkToken }
    Check "D16 带 invite_token 注册 -> 201" ($r.status -eq 201) "status=$($r.status) code=$(ErrCode $r)"
    $tokenMemberId = $r.json.data.member.id
    Check "D16 响应回显采纳的 dept_hint（不静默）" ($r.json.data.dept_hint.id -eq $deptPub) "hint=$($r.json.data.dept_hint | ConvertTo-Json -Compress)"
    $r = Call-Api "GET" "/api/v1/members/pending" $null $presToken
    $tokenHinted = $r.json.data.items | Where-Object { $_.id -eq $tokenMemberId }
    Check "D16 待分配项带服务端推导的 dept_hint" ($tokenHinted.dept_hint.id -eq $deptPub) "hint=$($tokenHinted.dept_hint | ConvertTo-Json -Compress)"
    # 优先级：token 说了算 —— 这里故意自报一个**别的**部门
    $r = Call-Api "POST" "/api/v1/auth/register" @{ register_code = $regCode; phone = "13900000022"; name = "token优先"; password = "tokenpw12"; invite_token = $linkToken; dept_id = $deptOps }
    Check "D16 token 优先于客户端自报的 dept_id" ($r.json.data.dept_hint.id -eq $deptPub) "hint=$($r.json.data.dept_hint.id) 期望=$deptPub 自报=$deptOps"

    $r = Call-Api "DELETE" "/api/v1/dept-invite-links/$linkToken" $null $presToken
    Check "停用链接 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    Check "停用后 enabled=false" ($r.json.data.enabled -eq $false)
    # D16 反例：停用后解析与"不存在"同形状；注册则退回客户端自报值（链接只是便利，不阻断注册）
    $r = Call-Api "GET" "/api/v1/join/$linkToken"
    Check "D16 停用后解析 -> dept=null 且 enabled=false" (($r.status -eq 200) -and ($null -eq $r.json.data.dept) -and ($r.json.data.enabled -eq $false)) "enabled=$($r.json.data.enabled) dept=$($r.json.data.dept)"
    $r = Call-Api "POST" "/api/v1/auth/register" @{ register_code = $regCode; phone = "13900000023"; name = "失效链接回落"; password = "tokenpw12"; invite_token = $linkToken; dept_id = $deptOps }
    Check "D16 失效 token 退回客户端自报的 dept_id" (($r.status -eq 201) -and ($r.json.data.dept_hint.id -eq $deptOps)) "status=$($r.status) hint=$($r.json.data.dept_hint.id)"
    $r = Call-Api "DELETE" "/api/v1/dept-invite-links/$linkToken" $null $presToken
    Check "重复停用幂等 -> 200" ($r.status -eq 200) "status=$($r.status)"
    $r = Call-Api "DELETE" "/api/v1/dept-invite-links/nonexistent" $null $presToken
    Check "停用不存在的链接 -> 200（幂等）" ($r.status -eq 200) "status=$($r.status)"
    # L-3：两种结果必须是同一个响应形状，客户端不用写特例
    # （视图直接放在 data 下 —— 与"链接存在"那条路径完全一致）
    Check "不存在的链接也返回完整视图（L-3）" ($null -ne $r.json.data.token) "json=$($r.raw)"
    Check "不存在的链接 enabled=false（L-3）" ($r.json.data.enabled -eq $false)
    Check "不存在的链接回显 token（L-3）" ($r.json.data.token -eq "nonexistent")
    Check "不存在的链接也有 dept 字段（L-3）" ($null -ne $r.json.data.dept)
    $r = Call-Api "GET" "/join/$linkToken"
    Check "停用后的落地页提示失效" ($r.raw -like "*失效*") "status=$($r.status)"

    # N-1 / N-9：落地页是本项目唯一的 HTML 输出。
    # N-1：部门名只校验过"非空"，直接拼进 HTML 就是注入点 —— 造一个带标签的部门名，
    #      断言页面里**没有**原始的 <script>，而是实体形式 &lt;script&gt;。
    # N-9：落地页必须带 CSP，一行 default-src 'none' 就能让漏网的脚本不执行。
    $r = Call-Api "POST" "/api/v1/depts" @{ name = "<script>alert(1)</script>" } $presToken
    Check "创建含标签的部门 -> 201（N-1 前置）" ($r.status -eq 201) "status=$($r.status) code=$(ErrCode $r)"
    $evilDept = $r.json.data.dept.id
    $r = Call-Api "POST" "/api/v1/dept-invite-links" @{ dept_id = $evilDept } $presToken
    $evilToken = [string]$r.json.data.token
    $r = Call-Api "GET" "/join/$evilToken"
    Check "落地页转义了部门名（N-1）" (($r.status -eq 200) -and ($r.raw -notlike "*<script>*") -and ($r.raw -like "*&lt;script&gt;*")) "status=$($r.status) raw=$($r.raw)"
    Check "落地页带 CSP 响应头（N-9）" ([string]$r.headers["content-security-policy"] -like "*default-src*") "csp=$([string]$r.headers['content-security-policy'])"

    # ---------- 15. 任务：创建与幂等 ----------
    Write-Host ""
    Write-Host "[15] 任务：创建、负责人唯一、client_token 幂等"
    $r = Call-Api "POST" "/api/v1/members/$memId/reset-password" $null $presToken
    $memPw = [string]$r.json.data.temporary_password
    $memToken = Login-Token $memPhone $memPw
    Check "成员登录成功（任务用例需要）" ($memToken.Length -eq 64)

    $pastDue = (Get-Date).AddDays(-3).ToString("yyyy-MM-ddTHH:mm:sszzz")
    # "今天到期"取当天 23:59。若恰好在一天最后一分钟运行，它会落进「逾期」组，
    # 因此下面的断言对两种结果都接受。
    $soonDue = (Get-Date).Date.AddHours(23).AddMinutes(59).ToString("yyyy-MM-ddTHH:mm:sszzz")
    $weekDue = (Get-Date).AddDays(3).ToString("yyyy-MM-ddTHH:mm:sszzz")
    $lateDue = (Get-Date).AddDays(20).ToString("yyyy-MM-ddTHH:mm:sszzz")

    $r = Call-Api "POST" "/api/v1/tasks" @{ title = "逾期任务"; owner_id = $memId; due_at = $pastDue; desc = "已经晚了" } $presToken
    Check "创建任务 -> 201" ($r.status -eq 201) "status=$($r.status) code=$(ErrCode $r)"
    $taskOverdue = $r.json.data.task.id
    Check "新任务 status=todo" ($r.json.data.task.status -eq "todo")
    Check "部门标签跟随负责人" ($r.json.data.task.dept.id -eq $deptOps)
    Check "新任务 is_overdue=true" ($r.json.data.task.is_overdue -eq $true)

    $ct = [guid]::NewGuid().ToString()
    $r = Call-Api "POST" "/api/v1/tasks" @{ title = "幂等任务"; owner_id = $memId; client_token = $ct } $presToken
    Check "带 client_token 创建 -> 201" ($r.status -eq 201) "status=$($r.status)"
    $idemTask = $r.json.data.task.id
    $r = Call-Api "POST" "/api/v1/tasks" @{ title = "幂等任务"; owner_id = $memId; client_token = $ct } $presToken
    Check "重复提交 -> 200（不是 201）" ($r.status -eq 200) "status=$($r.status)"
    Check "重复提交 duplicated=true" ($r.json.data.duplicated -eq $true)
    Check "重复提交返回同一个任务（没有创建两遍）" ($r.json.data.task.id -eq $idemTask)

    # H-2 回归（P0 越权读）：甲用过的 client_token，乙拿去重放**不能**读到甲的资源。
    # 幂等键带上提交者之后，乙的这次请求匹配不到任何记录，会走正常创建流程。
    $r = Call-Api "POST" "/api/v1/tasks" @{ title = "幂等任务"; owner_id = $memId; client_token = $ct } $leadToken
    Check "换个人重放同一 client_token -> 不是 200 回放（H-2）" ($r.status -eq 201) "status=$($r.status) code=$(ErrCode $r)"
    Check "换个人重放拿到的是自己的新资源（H-2）" ($r.json.data.task.id -ne $idemTask) "id=$($r.json.data.task.id) vs $idemTask"
    Check "换个人重放不会返回 duplicated（H-2）" ($null -eq $r.json.data.duplicated) "duplicated=$($r.json.data.duplicated)"

    # M-6：ArkTS/JS 的 toISOString() 带毫秒，客户端第一天就会撞上它
    $msDue = (Get-Date).AddDays(5).ToString("yyyy-MM-ddTHH:mm:ss.fff") + "+08:00"
    $r = Call-Api "POST" "/api/v1/tasks" @{ title = "带毫秒的截止时间"; owner_id = $memId; due_at = $msDue } $presToken
    Check "due_at 带毫秒 -> 201（M-6）" ($r.status -eq 201) "status=$($r.status) code=$(ErrCode $r) due=$msDue"
    $r = Call-Api "POST" "/api/v1/tasks" @{ title = "不存在的日期"; owner_id = $memId; due_at = "2026-02-30T10:00:00+08:00" } $presToken
    Check "2026-02-30 -> 400（L-5 不静默顺延）" (($r.status -eq 400) -and ((ErrCode $r) -eq "VALIDATION_FAILED")) "status=$($r.status) code=$(ErrCode $r)"

    $r = Call-Api "POST" "/api/v1/tasks" @{ title = "没有负责人" } $presToken
    Check "缺负责人 -> 400 VALIDATION_FAILED" (($r.status -eq 400) -and ((ErrCode $r) -eq "VALIDATION_FAILED")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/tasks" @{ title = "分给待分配账号"; owner_id = $stillId } $presToken
    Check "分给待分配账号 -> 403 MEMBER_PENDING" (($r.status -eq 403) -and ((ErrCode $r) -eq "MEMBER_PENDING")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/tasks" @{ title = "挂到不存在的课题"; owner_id = $memId; plan_id = 99999 } $presToken
    Check "挂到不存在的课题 -> 404 PLAN_NOT_FOUND" (($r.status -eq 404) -and ((ErrCode $r) -eq "PLAN_NOT_FOUND")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/tasks" @{ title = "部长跨部门分配"; owner_id = $newId } $leadToken
    Check "部长给外部门成员分任务 -> 403 FORBIDDEN_NOT_IN_DEPT" (($r.status -eq 403) -and ((ErrCode $r) -eq "FORBIDDEN_NOT_IN_DEPT")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/tasks" @{ title = "成员建任务"; owner_id = $memId } $memToken
    Check "普通成员建任务 -> 403 FORBIDDEN_ROLE" (($r.status -eq 403) -and ((ErrCode $r) -eq "FORBIDDEN_ROLE")) "status=$($r.status) code=$(ErrCode $r)"

    # ---------- 16. 我的任务（服务端分组） ----------
    Write-Host ""
    Write-Host "[16] GET /tasks/mine：服务端分组，客户端不重复实现"
    Call-Api "POST" "/api/v1/tasks" @{ title = "今天到期"; owner_id = $memId; due_at = $soonDue } $presToken | Out-Null
    Call-Api "POST" "/api/v1/tasks" @{ title = "三天后"; owner_id = $memId; due_at = $weekDue } $presToken | Out-Null
    Call-Api "POST" "/api/v1/tasks" @{ title = "很久以后"; owner_id = $memId; due_at = $lateDue } $presToken | Out-Null
    Call-Api "POST" "/api/v1/tasks" @{ title = "没有截止"; owner_id = $memId } $presToken | Out-Null

    $r = Call-Api "GET" "/api/v1/tasks/mine" $null $memToken
    Check "GET /tasks/mine -> 200" ($r.status -eq 200) "status=$($r.status)"
    Check "逾期组非空" ($r.json.data.counts.overdue -ge 1) "counts=$($r.json.data.counts | ConvertTo-Json -Compress)"
    $todayOk = ($r.json.data.due_today.Count -ge 1) -or
               (($r.json.data.overdue | Where-Object { $_.title -eq "今天到期" }) -ne $null)
    Check "今天组非空（当日最后一分钟运行时归入逾期）" $todayOk
    Check "本周组非空" ($r.json.data.due_week.Count -ge 1)
    Check "以后组非空" ($r.json.data.later.Count -ge 1)
    Check "无截止组非空" ($r.json.data.no_due.Count -ge 1)
    Check "counts.open_total 存在" ($null -ne $r.json.data.counts.open_total)
    $r = Call-Api "GET" "/api/v1/tasks/mine" $null $presToken
    Check "会长 /tasks/mine 只返回自己的（0 条）" ($r.json.data.counts.open_total -eq 0) "open_total=$($r.json.data.counts.open_total)"

    # ---------- 17. 状态流转与阻塞原因 ----------
    Write-Host ""
    Write-Host "[17] 状态流转：blocked 必须填原因、离开自动清空、done 记时间"
    $r = Call-Api "PUT" "/api/v1/tasks/$taskOverdue/status" @{ status = "blocked" } $presToken
    Check "进 blocked 不填原因 -> 400 BLOCKER_REQUIRED" (($r.status -eq 400) -and ((ErrCode $r) -eq "BLOCKER_REQUIRED")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "PUT" "/api/v1/tasks/$taskOverdue/status" @{ status = "blocked"; blocker = "等场地审批，已提交 3 天" } $presToken
    Check "填了原因 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    Check "blocked=true" ($r.json.data.blocked -eq $true)
    Check "blocker 已保存" ($r.json.data.blocker -eq "等场地审批，已提交 3 天")
    Check "阻塞与逾期两个事实并存（不互斥）" ($r.json.data.is_overdue -eq $true)
    $r = Call-Api "PUT" "/api/v1/tasks/$taskOverdue/status" @{ status = "doing" } $presToken
    Check "离开 blocked 自动清空 blocker" ($null -eq $r.json.data.blocker) "blocker=$($r.json.data.blocker)"
    $r = Call-Api "PUT" "/api/v1/tasks/$taskOverdue/status" @{ status = "done" } $presToken
    Check "进 done -> 200" ($r.status -eq 200)
    Check "completed_at 已记录" ($null -ne $r.json.data.completed_at)
    Check "已完成不算逾期" ($r.json.data.is_overdue -eq $false)
    $r = Call-Api "PUT" "/api/v1/tasks/$taskOverdue/status" @{ status = "todo" } $presToken
    Check "从 done 退回清空 completed_at" ($null -eq $r.json.data.completed_at)
    $r = Call-Api "PUT" "/api/v1/tasks/$taskOverdue/status" @{ status = "50%" } $presToken
    Check "非法状态 -> 400（不做进度百分比）" ($r.status -eq 400) "status=$($r.status)"

    $r = Call-Api "PUT" "/api/v1/tasks/$taskOverdue/status" @{ status = "doing" } $memToken
    Check "成员改自己任务状态 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/tasks" @{ title = "部长的任务"; owner_id = $leadId } $presToken
    $leadTask = $r.json.data.task.id
    $r = Call-Api "PUT" "/api/v1/tasks/$leadTask/status" @{ status = "doing" } $memToken
    Check "成员改他人任务状态 -> 403" (($r.status -eq 403) -and ((ErrCode $r) -eq "FORBIDDEN_ROLE")) "status=$($r.status) code=$(ErrCode $r)"

    # ---------- 18. 详情 / 编辑 / 转交 / 软删除 / 日历同步 ----------
    Write-Host ""
    Write-Host "[18] 任务详情、转交、软删除、日历同步 lookup"
    $r = Call-Api "GET" "/api/v1/tasks/$taskOverdue" $null $presToken
    Check "详情 -> 200" ($r.status -eq 200) "status=$($r.status)"
    Check "详情含 desc" ($r.json.data.desc -eq "已经晚了")
    Check "详情含 plan_path（客户端画面包屑用）" ($null -ne $r.json.data.plan_path)
    Check "详情含 created_by" ($null -ne $r.json.data.created_by)
    Check "详情不含手机号" (-not ($r.json.data.owner.PSObject.Properties.Name -contains "phone"))

    $r = Call-Api "PATCH" "/api/v1/tasks/$taskOverdue" @{ title = "改名后的任务"; desc = "改过的描述" } $presToken
    Check "编辑标题/描述 -> 200" ($r.status -eq 200) "status=$($r.status)"
    Check "标题已改" ($r.json.data.title -eq "改名后的任务")
    $r = Call-Api "PATCH" "/api/v1/tasks/$taskOverdue" @{ due_at = $null } $presToken
    Check "due_at 显式传 null -> 清空截止时间" ($null -eq $r.json.data.due_at) "due_at=$($r.json.data.due_at)"
    $r = Call-Api "PATCH" "/api/v1/tasks/$taskOverdue" @{ owner_id = 0 } $presToken
    Check "负责人置空 -> 400（任务必须始终有人负责）" ($r.status -eq 400) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "PATCH" "/api/v1/tasks/$taskOverdue" @{ owner_id = $newId } $presToken
    Check "跨部门转交（会长）-> 200" ($r.status -eq 200) "status=$($r.status)"
    Check "部门标签跟随新负责人" ($r.json.data.dept.id -eq $deptPub) "dept=$($r.json.data.dept.id) 期望=$deptPub"

    # D-3（2026-09-16，按 UI 设计规格）：读范围放开到全社团。
    # 设计规格 P02 屏幕就写着「共 38 项 · 全社团范围可见」、P04 课题树用「全部」
    # 能筛出非本部门课题。原先这里断言 total=0（旧的"本部门"口径），已作废。
    $r = Call-Api "GET" "/api/v1/tasks?dept_id=$deptPub" $null $leadToken
    Check "部长能读外部门任务（D-3 全社团可读）" ($r.json.data.total -ge 1) "total=$($r.json.data.total)"
    $r = Call-Api "GET" "/api/v1/tasks" $null $leadToken
    Check "部长看任务列表 -> 200" ($r.status -eq 200) "status=$($r.status)"
    # 但**写**没有跟着放开：改外部门任务状态仍须被挡（D-3 只放开读）
    $r = Call-Api "PUT" "/api/v1/tasks/$taskOverdue/status" @{ status = "doing" } $leadToken
    Check "部长改外部门任务状态 -> 403（D-3 只放开读）" (($r.status -eq 403) -and ((ErrCode $r) -eq "FORBIDDEN_NOT_IN_DEPT")) "status=$($r.status) code=$(ErrCode $r)"
    # 普通成员同样能读外部门任务（读范围不是"部长特权"）
    $r = Call-Api "GET" "/api/v1/tasks/$taskOverdue" $null $memToken
    Check "普通成员读外部门任务详情 -> 200（D-3）" ($r.status -eq 200) "status=$($r.status)"

    $r = Call-Api "POST" "/api/v1/tasks/lookup" @{ task_ids = @($leadTask, 99999) } $presToken
    Check "lookup -> 200" ($r.status -eq 200) "status=$($r.status)"
    Check "lookup：存在的进 items" ($r.json.data.items.Count -eq 1) "items=$($r.json.data.items.Count)"
    Check "lookup：不存在的进 missing" ($r.json.data.missing -contains 99999)

    $r = Call-Api "DELETE" "/api/v1/tasks/$idemTask" $null $presToken
    Check "软删除 -> 200" ($r.status -eq 200) "status=$($r.status)"
    $r = Call-Api "GET" "/api/v1/tasks/$idemTask" $null $presToken
    Check "删除后详情 -> 404" ($r.status -eq 404) "status=$($r.status)"
    $r = Call-Api "POST" "/api/v1/tasks/lookup" @{ task_ids = @($idemTask) } $presToken
    Check "删除后 lookup 归入 missing（客户端据此清理本地日历）" ($r.json.data.missing -contains $idemTask)
    $r = Call-Api "GET" "/api/v1/tasks?owner_id=$memId" $null $presToken
    $deletedStill = $r.json.data.items | Where-Object { $_.id -eq $idemTask }
    Check "软删除的任务不再出现在列表里" ($null -eq $deletedStill)

    # L-8：待分配与已退出是两件事，错误码必须分开
    # （原先两条路径都报 MEMBER_PENDING，客户端会提示"尚未被分配"，与事实不符）
    $r = New-Account "13900000018" "临时退出者" "leavepw12" $regCode
    $leaveId = $r.json.data.member.id
    $r = Call-Api "POST" "/api/v1/members/$leaveId/assign" @{ dept_id = $deptOps; role = "member" } $presToken
    Check "临时成员已分配" ($r.status -eq 200) "status=$($r.status)"
    $r = Call-Api "POST" "/api/v1/members/$leaveId/disable" $null $presToken
    Check "移出社团 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/tasks" @{ title = "分给已退出成员"; owner_id = $leaveId } $presToken
    Check "给已退出成员建任务 -> 403 MEMBER_DISABLED（L-8）" (($r.status -eq 403) -and ((ErrCode $r) -eq "MEMBER_DISABLED")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "PATCH" "/api/v1/tasks/$taskOverdue" @{ owner_id = $leaveId } $presToken
    Check "转交给已退出成员 -> 403 MEMBER_DISABLED（L-8）" (($r.status -eq 403) -and ((ErrCode $r) -eq "MEMBER_DISABLED")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/plans" @{ title = "已退出者负责的课题"; dept_id = $deptOps; owner_id = $leaveId } $presToken
    Check "给已退出成员建课题 -> 403 MEMBER_DISABLED（L-8）" (($r.status -eq 403) -and ((ErrCode $r) -eq "MEMBER_DISABLED")) "status=$($r.status) code=$(ErrCode $r)"

    # M-4：assign 对 disabled 目标即"恢复"。文档写明移出社团保留数据、日后可恢复，
    # 所以行为保留；但审计里必须能与普通分配区分（动作名 restore-member）。
    # 这条用例把语义钉死：以后要改成"拒绝"或"独立恢复接口"，先改这里。
    $r = Call-Api "POST" "/api/v1/members/$leaveId/assign" @{ dept_id = $deptOps; role = "member" } $presToken
    Check "恢复已退出成员（assign）-> 200（M-4 语义已钉住）" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    Check "恢复后 status=active" ($r.json.data.status -eq "active")
    $r = Call-Api "POST" "/api/v1/members/$leaveId/disable" $null $presToken
    Check "再次移出（复原状态）-> 200" ($r.status -eq 200) "status=$($r.status)"

    # ---------- 19. 课题：创建与树 ----------
    Write-Host ""
    Write-Host "[19] 课题：创建、dept_id 规则、课题树"
    $r = Call-Api "POST" "/api/v1/plans" @{ title = "招新总课题"; dept_id = $deptOps; owner_id = $leadId } $presToken
    Check "建顶层课题 -> 201" ($r.status -eq 201) "status=$($r.status) code=$(ErrCode $r)"
    $planRoot = $r.json.data.plan.id
    Check "顶层课题带 dept" ($r.json.data.plan.dept.id -eq $deptOps)
    Check "顶层 parent_id=0" ($r.json.data.plan.parent_id -eq 0)

    $r = Call-Api "POST" "/api/v1/plans" @{ title = "子课题"; parent_id = $planRoot; owner_id = $leadId } $presToken
    Check "建子课题 -> 201" ($r.status -eq 201) "status=$($r.status) code=$(ErrCode $r)"
    $planChild = $r.json.data.plan.id
    Check "子课题 dept 为 null（部门看根）" ($null -eq $r.json.data.plan.dept)
    Check "子课题 parent_id 正确" ($r.json.data.plan.parent_id -eq $planRoot)

    $r = Call-Api "POST" "/api/v1/plans" @{ title = "孙课题"; parent_id = $planChild; owner_id = $leadId } $presToken
    Check "建孙课题 -> 201" ($r.status -eq 201) "status=$($r.status)"
    $planGrand = $r.json.data.plan.id

    $r = Call-Api "POST" "/api/v1/plans" @{ title = "缺部门的顶层课题"; owner_id = $leadId } $presToken
    Check "顶层缺 dept_id -> 400" (($r.status -eq 400) -and ((ErrCode $r) -eq "VALIDATION_FAILED")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/plans" @{ title = "子课题却传部门"; parent_id = $planRoot; dept_id = $deptOps; owner_id = $leadId } $presToken
    Check "子课题传 dept_id -> 400（部门继承自根）" (($r.status -eq 400) -and ((ErrCode $r) -eq "VALIDATION_FAILED")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/plans" @{ title = "没有负责人"; dept_id = $deptOps } $presToken
    Check "缺 owner_id -> 400（任意层级都要有负责人）" (($r.status -eq 400) -and ((ErrCode $r) -eq "VALIDATION_FAILED")) "status=$($r.status)"
    $r = Call-Api "POST" "/api/v1/plans" @{ title = "挂到不存在的父"; parent_id = 99999; owner_id = $leadId } $presToken
    Check "父课题不存在 -> 404" (($r.status -eq 404) -and ((ErrCode $r) -eq "PLAN_NOT_FOUND")) "status=$($r.status)"
    $r = Call-Api "POST" "/api/v1/plans" @{ title = "部长跨部门建顶层"; dept_id = $deptPub; owner_id = $leadId } $leadToken
    Check "部长在别的部门建课题 -> 403" (($r.status -eq 403) -and ((ErrCode $r) -eq "FORBIDDEN_NOT_IN_DEPT")) "status=$($r.status) code=$(ErrCode $r)"

    $r = Call-Api "GET" "/api/v1/plans" $null $presToken
    Check "GET /plans -> 200" ($r.status -eq 200) "status=$($r.status)"
    $node = $r.json.data.items | Where-Object { $_.id -eq $planRoot }
    Check "森林含根节点" ($null -ne $node)
    Check "根节点内嵌 children" ($node.children.Count -ge 1)
    Check "节点含 progress" ($null -ne $node.progress)
    Check "节点含 child_count" ($node.child_count -ge 1)
    $r = Call-Api "GET" "/api/v1/plans?dept_id=$deptPub" $null $presToken
    $pubNode = $r.json.data.items | Where-Object { $_.id -eq $planRoot }
    Check "按部门筛选：别的部门看不到" ($null -eq $pubNode)
    $r = Call-Api "GET" "/api/v1/plans?include_progress=false" $null $presToken
    $n2 = $r.json.data.items | Where-Object { $_.id -eq $planRoot }
    Check "include_progress=false 时不返回 progress" ($null -eq $n2.progress)

    # ---------- 20. 课题：递归进度聚合 ----------
    Write-Host ""
    Write-Host "[20] 递归进度聚合（含整棵子树）"
    $r = Call-Api "POST" "/api/v1/tasks" @{ title = "根本级-完成"; owner_id = $leadId; plan_id = $planRoot } $presToken
    $rootTaskId = $r.json.data.task.id
    Call-Api "PUT" "/api/v1/tasks/$rootTaskId/status" @{ status = "done" } $presToken | Out-Null
    $r = Call-Api "POST" "/api/v1/tasks" @{ title = "子本级-进行中"; owner_id = $leadId; plan_id = $planChild } $presToken
    $childTaskId = $r.json.data.task.id
    $r = Call-Api "POST" "/api/v1/tasks" @{ title = "孙本级-完成"; owner_id = $leadId; plan_id = $planGrand } $presToken
    $grandTask1 = $r.json.data.task.id
    Call-Api "PUT" "/api/v1/tasks/$grandTask1/status" @{ status = "done" } $presToken | Out-Null
    Call-Api "POST" "/api/v1/tasks" @{ title = "孙本级-未开始"; owner_id = $leadId; plan_id = $planGrand } $presToken | Out-Null

    $r = Call-Api "GET" "/api/v1/plans" $null $presToken
    $node = $r.json.data.items | Where-Object { $_.id -eq $planRoot }
    Check "根 progress.total 含整棵子树 = 4" ($node.progress.total -eq 4) "progress=$($node.progress | ConvertTo-Json -Compress)"
    Check "根 progress.done 含整棵子树 = 2" ($node.progress.done -eq 2) "progress=$($node.progress | ConvertTo-Json -Compress)"
    Check "根 task_count 只算本级 = 1" ($node.task_count -eq 1) "task_count=$($node.task_count)"
    $childNode = $node.children | Where-Object { $_.id -eq $planChild }
    Check "子课题 progress.total = 3（本级1 + 孙2）" ($childNode.progress.total -eq 3) "progress=$($childNode.progress | ConvertTo-Json -Compress)"

    $r = Call-Api "GET" "/api/v1/plans/$planRoot" $null $presToken
    Check "课题详情 -> 200" ($r.status -eq 200) "status=$($r.status)"
    Check "详情 plan.progress 递归" ($r.json.data.plan.progress.total -eq 4)
    Check "详情 path 面包屑含自身" (($r.json.data.path | Select-Object -Last 1).id -eq $planRoot)
    Check "详情 children 平铺" ($r.json.data.children.Count -eq 1)
    Check "详情 tasks 只含本级 = 1" ($r.json.data.tasks.total -eq 1) "tasks.total=$($r.json.data.tasks.total)"
    $r = Call-Api "GET" "/api/v1/plans/$planGrand" $null $presToken
    Check "孙课题面包屑 3 级" ($r.json.data.path.Count -eq 3) "path=$($r.json.data.path.Count)"

    # ---------- 21. 课题：深度上限与环形校验 ----------
    Write-Host ""
    Write-Host "[21] 深度上限 6 层、环形校验、跨部门禁止"
    $deepest = $planGrand
    for ($i = 4; $i -le 6; $i++) {
        $r = Call-Api "POST" "/api/v1/plans" @{ title = "第${i}层"; parent_id = $deepest; owner_id = $leadId } $presToken
        Check "建第 $i 层 -> 201" ($r.status -eq 201) "status=$($r.status) depth=$i code=$(ErrCode $r)"
        $deepest = $r.json.data.plan.id
    }
    $r = Call-Api "POST" "/api/v1/plans" @{ title = "第7层"; parent_id = $deepest; owner_id = $leadId } $presToken
    Check "建第 7 层 -> 400 PLAN_DEPTH_EXCEEDED" (($r.status -eq 400) -and ((ErrCode $r) -eq "PLAN_DEPTH_EXCEEDED")) "status=$($r.status) code=$(ErrCode $r)"

    $r = Call-Api "POST" "/api/v1/plans/$planRoot/move" @{ new_parent_id = $planRoot } $presToken
    Check "移动到自己下面 -> 409 PLAN_CYCLE_DETECTED" (($r.status -eq 409) -and ((ErrCode $r) -eq "PLAN_CYCLE_DETECTED")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/plans/$planRoot/move" @{ new_parent_id = $planGrand } $presToken
    Check "移动到自己的后代下面 -> 409" (($r.status -eq 409) -and ((ErrCode $r) -eq "PLAN_CYCLE_DETECTED")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/plans/$planRoot/move" @{ new_parent_id = 99999 } $presToken
    Check "移动到不存在的父 -> 404" (($r.status -eq 404) -and ((ErrCode $r) -eq "PLAN_NOT_FOUND")) "status=$($r.status)"
    $r = Call-Api "POST" "/api/v1/plans/$planRoot/move" @{ new_parent_id = $planRoot } $vpToken
    Check "副会长可移动课题（成环仍 409）" ($r.status -eq 409) "status=$($r.status)"

    $r = Call-Api "POST" "/api/v1/plans" @{ title = "宣传部课题"; dept_id = $deptPub; owner_id = $newId } $presToken
    $planPub = $r.json.data.plan.id
    $r = Call-Api "POST" "/api/v1/plans/$planChild/move" @{ new_parent_id = $planPub } $presToken
    Check "跨部门移动 -> 400（v1 禁止）" (($r.status -eq 400) -and ((ErrCode $r) -eq "VALIDATION_FAILED")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/plans/$planPub/move" @{ new_parent_id = $planChild } $leadToken
    Check "部长跨部门移动 -> 403" ($r.status -eq 403) "status=$($r.status) code=$(ErrCode $r)"
    # H-3 回归（P0）：换父节点那条路判了权限，**提升为顶层那条路原先没有判**。
    # 部长可以把自己部门的课题 dept_id 一填就"提升"到别的部门去。
    $r = Call-Api "GET" "/api/v1/plans/$planGrand" $null $presToken
    $grandParentBefore = $r.json.data.plan.parent_id
    $r = Call-Api "POST" "/api/v1/plans/$planGrand/move" @{ new_parent_id = $null; dept_id = $deptPub } $leadToken
    Check "部长把课题提升到别的部门 -> 403（H-3）" (($r.status -eq 403) -and ((ErrCode $r) -eq "FORBIDDEN_NOT_IN_DEPT")) "status=$($r.status) code=$(ErrCode $r)"
    # 被拒绝的移动不该改动任何状态：父节点仍是移动前那个
    # （子树不存 dept_id，所以这里查 parent_id 而不是 dept.id）
    $r = Call-Api "GET" "/api/v1/plans/$planGrand" $null $presToken
    Check "课题没有被偷偷挪走（H-3）" ($r.json.data.plan.parent_id -eq $grandParentBefore) "parent=$($r.json.data.plan.parent_id) 期望=$grandParentBefore"
    $r = Call-Api "POST" "/api/v1/plans/$planGrand/move" @{ new_parent_id = $null; dept_id = $deptPub } $presToken
    Check "会长提升到别的部门 -> 400（v1 禁止跨部门）" (($r.status -eq 400) -and ((ErrCode $r) -eq "VALIDATION_FAILED")) "status=$($r.status) code=$(ErrCode $r)"

    $r = Call-Api "POST" "/api/v1/plans" @{ title = "另一分枝"; parent_id = $planRoot; owner_id = $leadId } $presToken
    $planBranch = $r.json.data.plan.id
    $r = Call-Api "POST" "/api/v1/plans/$planGrand/move" @{ new_parent_id = $planBranch } $presToken
    Check "合法移动 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    Check "移动后 parent_id 已变" ($r.json.data.plan.parent_id -eq $planBranch)
    $r = Call-Api "POST" "/api/v1/plans/$planGrand/move" @{ new_parent_id = $null; dept_id = $deptOps } $presToken
    Check "提升为顶层 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    Check "提升后 parent_id=0" ($r.json.data.plan.parent_id -eq 0)
    Check "提升后带上部门" ($r.json.data.plan.dept.id -eq $deptOps)

    # ---------- 22. 课题：编辑与删除上提 ----------
    Write-Host ""
    Write-Host "[22] 课题编辑、删除上提（绝不级联删除）"
    $r = Call-Api "GET" "/api/v1/plans/$planChild" $null $presToken
    $childTotalBefore = $r.json.data.plan.progress.total
    $r = Call-Api "PATCH" "/api/v1/plans/$planChild" @{ title = "改名后的子课题"; desc = "补充说明" } $presToken
    Check "编辑课题 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    Check "标题已改" ($r.json.data.plan.title -eq "改名后的子课题")
    Check "描述已存" ($r.json.data.plan.desc -eq "补充说明")
    # M-1：PATCH 的响应里原先 progress 恒为 0/0（传了 None 进去）。
    # 客户端改完标题，进度条会突然归零——一个"看起来像数据丢失"的假象。
    Check "PATCH 返回真实进度而非 0/0（M-1）" ($r.json.data.plan.progress.total -eq $childTotalBefore) "patch=$($r.json.data.plan.progress.total) get=$childTotalBefore"
    Check "PATCH 的进度非零（M-1）" ($r.json.data.plan.progress.total -gt 0) "total=$($r.json.data.plan.progress.total)"
    $r = Call-Api "PATCH" "/api/v1/plans/$planChild" @{ dept_id = $deptPub } $presToken
    Check "PATCH 改 dept_id -> 400" (($r.status -eq 400) -and ((ErrCode $r) -eq "VALIDATION_FAILED")) "status=$($r.status)"
    $r = Call-Api "PATCH" "/api/v1/plans/$planChild" @{ owner_id = 0 } $presToken
    Check "负责人置空 -> 400" ($r.status -eq 400) "status=$($r.status) code=$(ErrCode $r)"

    # 先给待删课题挂一个子课题，这样才真正验证到"上提"
    $r = Call-Api "POST" "/api/v1/plans" @{ title = "待上提的子课题"; parent_id = $planChild; owner_id = $leadId } $presToken
    $promoteMe = $r.json.data.plan.id
    Check "为删除用例准备子课题 -> 201" ($r.status -eq 201) "status=$($r.status)"

    $r = Call-Api "DELETE" "/api/v1/plans/$planChild" $null $presToken
    Check "删除中间课题 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    Check "上提 1 个子课题" ($r.json.data.moved_plans -eq 1) "moved_plans=$($r.json.data.moved_plans)"
    Check "上提 1 个本级任务" ($r.json.data.moved_tasks -eq 1) "moved_tasks=$($r.json.data.moved_tasks)"
    $r = Call-Api "GET" "/api/v1/plans/$planChild" $null $presToken
    Check "被删课题详情 -> 404" ($r.status -eq 404) "status=$($r.status)"
    $r = Call-Api "GET" "/api/v1/plans/$promoteMe" $null $presToken
    Check "子课题上提到祖父下" ($r.json.data.plan.parent_id -eq $planRoot) "parent=$($r.json.data.plan.parent_id) 期望=$planRoot"
    $r = Call-Api "GET" "/api/v1/tasks/$childTaskId" $null $presToken
    Check "被删课题的本级任务已上提到其父" ($r.json.data.plan.id -eq $planRoot) "plan=$($r.json.data.plan.id) 期望=$planRoot"

    $r = Call-Api "POST" "/api/v1/plans" @{ title = "待删顶层"; dept_id = $deptOps; owner_id = $leadId } $presToken
    $planTop2 = $r.json.data.plan.id
    $r = Call-Api "POST" "/api/v1/plans" @{ title = "它的子课题"; parent_id = $planTop2; owner_id = $leadId } $presToken
    $planTop2Child = $r.json.data.plan.id
    $r = Call-Api "POST" "/api/v1/tasks" @{ title = "顶层待删课题的任务"; owner_id = $leadId; plan_id = $planTop2 } $presToken
    $topTaskId = $r.json.data.task.id
    $r = Call-Api "DELETE" "/api/v1/plans/$planTop2" $null $presToken
    Check "删除顶层课题 -> 200" ($r.status -eq 200) "status=$($r.status)"
    $r = Call-Api "GET" "/api/v1/plans/$planTop2Child" $null $presToken
    Check "子课题变成顶层（parent_id=0）" ($r.json.data.plan.parent_id -eq 0)
    Check "子课题继承原根的部门" ($r.json.data.plan.dept.id -eq $deptOps) "dept=$($r.json.data.plan.dept.id)"
    $r = Call-Api "GET" "/api/v1/tasks/$topTaskId" $null $presToken
    Check "顶层被删后任务变为独立任务" ($null -eq $r.json.data.plan)

    # ---------- 23. 优雅关闭（仅本机） ----------
    # ---------- 22.5 第四轮复验的回归闸门（N-15 / N-18） ----------
    # N-15：被 4xx 拒绝的请求不能在内存与磁盘上留下"半改"状态。
    # N-18：任务不能挂到**别的部门**的课题下。
    # 位置必须在 23 之前 —— 那一段会把服务关停。
    Write-Host ""
    Write-Host "[22.5] 被拒请求不留半改状态（N-15）· 跨部门挂课题被拒（N-18）"

    # N-15a：姓名合法 + 角色非法（president 只能靠移交）-> 整体 400，姓名必须没变
    $beforeName = (Call-Api "GET" "/api/v1/members/$newId" $null $presToken).json.data.member.name
    $r = Call-Api "PATCH" "/api/v1/members/$newId" @{ name = "N15RejectedName"; role = "president" } $presToken
    Check "成员：合法名 + 非法角色 -> 400" (($r.status -eq 400) -and ((ErrCode $r) -eq "VALIDATION_FAILED")) "status=$($r.status) code=$(ErrCode $r)"
    $afterName = (Call-Api "GET" "/api/v1/members/$newId" $null $presToken).json.data.member.name
    Check "成员：被拒后姓名未变（N-15）" ($afterName -eq $beforeName) "before=$beforeName after=$afterName"

    # N-15b：部门改名合法 + sort 越界 -> 整体 400，名字必须没变
    $r = Call-Api "POST" "/api/v1/depts" @{ name = "N15部门"; sort = 7 } $presToken
    $n15Dept = $r.json.data.dept.id
    $r = Call-Api "PATCH" "/api/v1/depts/$n15Dept" @{ name = "N15RejectedDeptName"; sort = 99999 } $presToken
    Check "部门：合法名 + 越界 sort -> 400" (($r.status -eq 400) -and ((ErrCode $r) -eq "VALIDATION_FAILED")) "status=$($r.status) code=$(ErrCode $r)"
    $n15Name = ((Call-Api "GET" "/api/v1/depts" $null $presToken).json.data.items | Where-Object { $_.id -eq $n15Dept }).name
    Check "部门：被拒后名称未变（N-15）" ($n15Name -eq "N15部门") "name=$n15Name"

    # N-15 的落盘面：上面被拒之后触发一次普通写，被拒的值不能出现在 **MySQL 里**
    #（2026-09-20：原来读 db.json，现在直接查库 —— 断言更强，读的就是真后端）
    $r = Call-Api "POST" "/api/v1/depts" @{ name = "N15落盘探针"; sort = 8 } $presToken
    $probeDept = $r.json.data.dept.id
    $r = Call-Api "DELETE" "/api/v1/depts/$probeDept" $null $presToken
    Check "N15 落盘探针建删 -> 200" ($r.status -eq 200) "status=$($r.status)"
    $badMember = (Invoke-ClubMySql "SELECT COUNT(*) FROM members WHERE name='N15RejectedName';" $my.Db).Trim()
    $badDept   = (Invoke-ClubMySql "SELECT COUNT(*) FROM departments WHERE name='N15RejectedDeptName';" $my.Db).Trim()
    Check "被拒的成员名没进 MySQL（N-15）" ($badMember -eq '0') "count=$badMember"
    Check "被拒的部门名没进 MySQL（N-15）" ($badDept -eq '0') "count=$badDept"

    # N-18：会长自己的部门是主席团，拿它当负责人去挂"乙部门"的课题就是跨部门
    $r = Call-Api "POST" "/api/v1/depts" @{ name = "N18乙"; sort = 12 } $presToken
    $n18DeptB = $r.json.data.dept.id
    $r = Call-Api "POST" "/api/v1/plans" @{ title = "N18乙部门课题"; dept_id = $n18DeptB; owner_id = $presId } $presToken
    Check "N18 探针课题 -> 201" ($r.status -eq 201) "status=$($r.status) code=$(ErrCode $r)"
    $n18Plan = $r.json.data.plan.id
    $r = Call-Api "POST" "/api/v1/tasks" @{ title = "N18跨部门任务"; owner_id = $presId; plan_id = $n18Plan } $presToken
    Check "创建：跨部门挂课题 -> 403 FORBIDDEN_NOT_IN_DEPT（N-18）" (($r.status -eq 403) -and ((ErrCode $r) -eq "FORBIDDEN_NOT_IN_DEPT")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "PATCH" "/api/v1/tasks/$taskOverdue" @{ plan_id = $n18Plan } $presToken
    Check "修改：跨部门挂课题 -> 403 FORBIDDEN_NOT_IN_DEPT（N-18）" (($r.status -eq 403) -and ((ErrCode $r) -eq "FORBIDDEN_NOT_IN_DEPT")) "status=$($r.status) code=$(ErrCode $r)"
    # 同部门挂载的正例由本文件 [20] 那批"课题下建任务"承担（部门一致，必须继续 201）；
    # 这里只做清理，确认探针没留下垃圾。
    $r = Call-Api "DELETE" "/api/v1/plans/$n18Plan" $null $presToken
    Check "N18 探针课题删除 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "DELETE" "/api/v1/depts/$n18DeptB" $null $presToken
    Check "N18 探针部门删除 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "DELETE" "/api/v1/depts/$n15Dept" $null $presToken
    Check "N15 探针部门删除 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"

    # ---------- 22.7 登录按 IP 节流（N-21）—— 已于 2026-09-18 移除 ----------
    # 口径：**应用层不做抗 DDoS / 抗分布式滥用**。按 IP 的限流挡不住分布式，
    # 而且在 NAT / 校园网出口下会把整个社团一起锁在外面 —— 流量层的事交给网络侧
    # （云清洗 / WAF / 网关限速）。应用层只保留与来源无关的减载闸门：
    # PBKDF2 并发上限 8，超出直接 429、不排队（由单测 testPbkdf2Gate 钉住）。
    # 该闸门是纯计数、不需要网卡，也不该挂在冒烟上；因此本节连同它依赖的
    # 「非回环网卡」一并删除（原 N-30 的 skip 分支随之作废）。

    Write-Host ""
    Write-Host "[23] /admin/shutdown 仅本机可访问"
    $r = Call-Api "POST" "/admin/shutdown"
    Check "本机关停 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    $proc.WaitForExit(8000) | Out-Null
    Check "进程自行退出（无人 kill，说明 shutdown 走完）" ($proc.HasExited) "hasExited=$($proc.HasExited)"

    # 优雅关闭的直接证据：日志里出现收尾那行。
    # （PS 5.1 拿不到 Start-Process 出来的 ExitCode，用日志替代。）
    $logText = ""
    if ((Test-Path $proc.LogOut)) {
        $logText = [System.IO.File]::ReadAllText($proc.LogOut, [System.Text.Encoding]::UTF8)
    }
    Check "日志出现『服务已停止』" ($logText -match "服务已停止") "log=[$logText]"
    Check "日志无 ERROR/FATAL" (($logText -notmatch "\[FATAL\]") -and ($logText -notmatch "FSException")) ""

    # 审计日志：敏感操作要能事后追查，且 M-4 的"恢复"与普通分配要能区分开
    $auditText = ""
    $auditPath = Join-Path $dataAbs "audit.log"
    if (Test-Path $auditPath) {
        $auditText = [System.IO.File]::ReadAllText($auditPath, [System.Text.Encoding]::UTF8)
    }
    Check "审计日志已生成" ($auditText.Length -gt 0) "path=$auditPath"
    Check "审计含重置密码记录" ($auditText -match "reset-password")
    Check "审计含注册口令更换记录" ($auditText -match "change-register-code")
    Check "审计区分恢复与普通分配（M-4）" (($auditText -match "restore-member") -and ($auditText -match "assign-member")) "audit=$auditText"
    # 部门增删改三条都要留痕（2026-09-16 补：原先只有删除记了审计；
    # 运维页开放「新增部门」后，"谁建的部门"必须查得到）
    Check "审计含部门新增/改名记录" (($auditText -match "create-dept") -and ($auditText -match "update-dept")) "audit=$auditText"

    # ---------- 24. 重启后数据仍在 ----------
    # 2026-09-20 起这条断言的分量更重了：数据只在 MySQL 里，
    # 进程重启**什么都不带过来**（内存全新），能读到就说明真在库里。
    Write-Host ""
    Write-Host "[24] 重启后持久性（数据只在 MySQL，重启不携带任何内存状态）"
    $proc = Start-Server $my.Dsn "2"
    Check "重启后服务就绪" ($null -ne $proc)
    $r = Call-Api "POST" "/api/v1/auth/login" @{ phone = "13800000000"; password = "newpassword1" }
    Check "重启后仍能用改过的密码登录" ($r.status -eq 200) "status=$($r.status)"
    $r = Call-Api "POST" "/api/v1/auth/login" @{ phone = "13900000001"; password = "abc12345" }
    Check "重启后 pending 账号仍在（锁定已过期？此处应为 429 或 200）" (($r.status -eq 200) -or ($r.status -eq 429)) "status=$($r.status)"
    $r = Call-Api "GET" "/health"
    Check "重启后 /health 正常" ($r.status -eq 200)

    # ---------- 26. UI 设计规格一致性（D-1 / D-2 / D-4 / D-5 / D-7，2026-09-16） ----------
    # 按《鸿蒙俱乐部-全场景UI设计规格》实现的能力，每条都是"回退即变红"的闸门。
    # 放在 [25] 之前：[25] 会把本机 IP 的注册节流锁住，之后的注册都不通。
    Write-Host ""
    Write-Host "[26] 设计规格一致性：权限摘要 / 名录搜索 / 需要帮助 / 逾期天数 / 成员计数"

    # --- D-1：管理页四张分区卡按权限显示，需要这几个布尔（会长 / 副会长必须不同） ---
    # 重新登录取 token：本段在 [24] 重启之后，不依赖重启前的会话
    $r = Call-Api "POST" "/api/v1/auth/login" @{ phone = "13800000000"; password = "newpassword1" }
    $presToken2 = [string]$r.json.data.token
    $leadToken = Login-Token $leadPhone "leadpw123"
    $memToken = Login-Token $memPhone $memPw
    $r = Call-Api "GET" "/api/v1/auth/me" $null $presToken2
    $pP = $r.json.data.permissions
    Check "D1 会长 manage_depts=true" ($pP.manage_depts -eq $true) "manage_depts=$($pP.manage_depts)"
    Check "D1 会长 change_register_code=true" ($pP.change_register_code -eq $true)
    Check "D1 会长 transfer_presidency=true" ($pP.transfer_presidency -eq $true)
    Check "D1 会长 view_scope=all（D-3 读范围全社团）" ($pP.view_scope -eq "all") "view_scope=$($pP.view_scope)"
    $r = Call-Api "GET" "/api/v1/auth/me" $null $leadToken
    $pL = $r.json.data.permissions
    Check "D1 部长 manage_depts=false" ($pL.manage_depts -eq $false)
    Check "D1 部长 view_register_code=false" ($pL.view_register_code -eq $false)
    Check "D1 部长 view_scope=all（部长也是全社团可读）" ($pL.view_scope -eq "all") "view_scope=$($pL.view_scope)"

    # --- D-2：名录搜索「姓名或部门」（设计规格 P06 的搜索框） ---
    $r = Call-Api "GET" "/api/v1/members" $null $leadToken
    $allTotal = $r.json.data.total
    $r = Call-Api "GET" "/api/v1/members?q=$([uri]::EscapeDataString("运营"))" $null $leadToken
    $byDept = $r.json.data.total
    Check "D2 按部门名搜索 -> 200" ($r.status -eq 200) "status=$($r.status)"
    Check "D2 按部门名搜索命中（0 < 命中数 <= 总数）" (($byDept -gt 0) -and ($byDept -le $allTotal)) "命中=$byDept 总=$allTotal"
    $r = Call-Api "GET" "/api/v1/members?q=$([uri]::EscapeDataString("绝不可能匹配的串"))" $null $leadToken
    Check "D2 搜索无匹配 -> total=0" ($r.json.data.total -eq 0) "total=$($r.json.data.total)"
    $r = Call-Api "GET" "/api/v1/members?q=$([uri]::EscapeDataString("13800000000"))" $null $leadToken
    Check "D2 手机号不参与搜索（隐私最小化）" ($r.json.data.total -eq 0) "total=$($r.json.data.total)"

    # --- D-5：逾期天数由服务端算（设计规格 P03「该判断由服务端算出，客户端不重算」） ---
    $r = Call-Api "POST" "/api/v1/tasks" @{ title = "D5 逾期天数探针"; owner_id = $memId; due_at = "2026-09-01T10:00:00+08:00" } $presToken2
    $d5Task = $r.json.data.task.id
    Check "D5 建探针 -> 201" ($r.status -eq 201) "status=$($r.status)"
    Check "D5 is_overdue=true" ($r.json.data.task.is_overdue -eq $true)
    Check "D5 接口直接下发逾期天数（不是只有布尔）" ($null -ne $r.json.data.task.overdue_days) "overdue_days=$($r.json.data.task.overdue_days)"
    Check "D5 逾期天数 >= 1（2026-09-01 已过）" ($r.json.data.task.overdue_days -ge 1) "overdue_days=$($r.json.data.task.overdue_days)"

    # --- D-4：需要帮助（求助对象 = 部门 + 人）+ 部长首页能看到本部门被阻塞项 ---
    $r = Call-Api "PUT" "/api/v1/tasks/$d5Task/status" @{ status = "blocked"; blocker = "等宣传部出主视觉" } $presToken2
    Check "D4 只填 blocker 也能进 blocked（needs_help=null）" (($r.status -eq 200) -and ($null -eq $r.json.data.needs_help)) "status=$($r.status) needs_help=$($r.json.data.needs_help)"
    $r = Call-Api "PUT" "/api/v1/tasks/$d5Task/status" @{ status = "blocked"; blocker = "等宣传部出主视觉"; help_dept_id = $deptPub } $presToken2
    Check "D4 带求助部门 -> 200" ($r.status -eq 200) "status=$($r.status) code=$(ErrCode $r)"
    Check "D4 needs_help.dept 是所选部门" ($r.json.data.needs_help.dept.id -eq $deptPub) "dept=$($r.json.data.needs_help.dept.id)"
    Check "D4 只到部门时 member=null" ($null -eq $r.json.data.needs_help.member)
    $r = Call-Api "PUT" "/api/v1/tasks/$d5Task/status" @{ status = "blocked"; blocker = "等宣传部出主视觉"; help_member_id = $newId } $presToken2
    Check "D4 只填人 -> 自动补齐部门（D-4 口径）" (($r.status -eq 200) -and ($r.json.data.needs_help.dept.id -eq $deptPub)) "status=$($r.status) dept=$($r.json.data.needs_help.dept.id)"
    Check "D4 needs_help.member 是人视图" ($r.json.data.needs_help.member.id -eq $newId) "member=$($r.json.data.needs_help.member.id)"
    $r = Call-Api "PUT" "/api/v1/tasks/$d5Task/status" @{ status = "blocked"; blocker = "等宣传部出主视觉"; help_dept_id = $deptPub; help_member_id = $memId } $presToken2
    Check "D4 人与部门不一致 -> 400" ($r.status -eq 400) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "PUT" "/api/v1/tasks/$d5Task/status" @{ status = "doing"; help_dept_id = $deptPub } $presToken2
    Check "D4 非阻塞状态带求助对象 -> 400（不静默忽略）" ($r.status -eq 400) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "PUT" "/api/v1/tasks/$d5Task/status" @{ status = "blocked"; blocker = "等宣传部出主视觉"; help_member_id = $newId } $presToken2
    $r = Call-Api "PUT" "/api/v1/tasks/$d5Task/status" @{ status = "doing" } $presToken2
    Check "D4 离开 blocked 自动清空求助对象" (($r.status -eq 200) -and ($null -eq $r.json.data.needs_help)) "needs_help=$($r.json.data.needs_help)"
    # 部长首页带上「本部门别人的阻塞项」（设计规格 P03「部长在首页即可看到这条」）
    $r = Call-Api "PUT" "/api/v1/tasks/$d5Task/status" @{ status = "blocked"; blocker = "等宣传部出主视觉"; help_member_id = $newId } $presToken2
    $r = Call-Api "GET" "/api/v1/tasks/mine" $null $leadToken
    $borrowedInBlocked = @($r.json.data.blocked | Where-Object { $_.owner.id -ne $leadId })
    Check "D4 部长首页出现本部门别人负责的阻塞项" ($borrowedInBlocked.Count -ge 1) "borrowed=$($borrowedInBlocked.Count)"
    Check "D4 counts.borrowed_blocked 与之一致" ($r.json.data.counts.borrowed_blocked -eq $borrowedInBlocked.Count) "counts=$($r.json.data.counts.borrowed_blocked) 实际=$($borrowedInBlocked.Count)"
    # P0（队友复验，2026-09-16）：首页「阻塞中」每张卡都要自带 blocker，
    # 否则客户端要显示规格 P01 的阻塞原因高亮块，就得为每张卡再打一次详情接口。
    $noBlocker = @($r.json.data.blocked | Where-Object { [string]::IsNullOrEmpty($_.blocker) })
    Check "P0 首页「阻塞中」卡片全带 blocker（不必再打详情）" ($noBlocker.Count -eq 0) "缺 blocker 的卡片数=$($noBlocker.Count)"
    Check "P0 blocker 内容正确（不是空串/占位）" (@($r.json.data.blocked | Where-Object { $_.blocker -eq "等宣传部出主视觉" }).Count -ge 1)
    # 非阻塞任务给 null（不是空串），客户端据此决定渲不渲染那一块
    $r = Call-Api "POST" "/api/v1/tasks" @{ title = "P0 非阻塞探针"; owner_id = $memId } $presToken2
    $p0Task = $r.json.data.task.id
    Check "P0 非阻塞任务 blocker=null" ($null -eq $r.json.data.task.blocker) "blocker=[$($r.json.data.task.blocker)]"
    $r = Call-Api "DELETE" "/api/v1/tasks/$p0Task" $null $presToken2
    Check "P0 探针清理 -> 200" ($r.status -eq 200) "status=$($r.status)"
    # 反证：普通成员（非部长）的首页不带 borrowed
    $r = Call-Api "GET" "/api/v1/tasks/mine" $null $memToken
    Check "D4 普通成员首页 borrowed_blocked=0" ($r.json.data.counts.borrowed_blocked -eq 0) "counts=$($r.json.data.counts.borrowed_blocked)"

    # --- D-7：成员详情身份卡三个计数（未完成 / 逾期 / 已完成）都由服务端给 ---
    $r = Call-Api "GET" "/api/v1/members/$memId" $null $presToken2
    Check "D7 详情有 open_tasks" ($null -ne $r.json.data.stats.open_tasks)
    Check "D7 详情有 overdue_tasks（原先没有）" ($null -ne $r.json.data.stats.overdue_tasks) "stats=$($r.json.data.stats | ConvertTo-Json -Compress)"
    Check "D7 详情有 done_tasks（原先没有）" ($null -ne $r.json.data.stats.done_tasks)
    Check "D7 未完成 + 已完成 = 总数" (($r.json.data.stats.open_tasks + $r.json.data.stats.done_tasks) -eq $r.json.data.stats.owned_tasks) "open=$($r.json.data.stats.open_tasks) done=$($r.json.data.stats.done_tasks) owned=$($r.json.data.stats.owned_tasks)"
    Check "D7 逾期数 <= 未完成数" ($r.json.data.stats.overdue_tasks -le $r.json.data.stats.open_tasks)
    # 收尾：把 D5/D4 探针任务删掉，别把脏数据留给后面的断言
    $r = Call-Api "DELETE" "/api/v1/tasks/$d5Task" $null $presToken2
    Check "D5 探针清理 -> 200" ($r.status -eq 200) "status=$($r.status)"

    # --- D-6：密码口径 = 8–32 字节 + 只用数字 / 英文 / 符号（2026-09-16 定稿） ---
    # 放在 [25] 之前：[25] 会把本机 IP 的注册节流锁住。
    $pwPhone = "13900000031"
    $r = Call-Api "POST" "/api/v1/auth/register" @{ register_code = $regCode; phone = $pwPhone; name = "密码探针"; password = "abc1234" }
    Check "D6 7 位密码 -> 400（下界）" (($r.status -eq 400) -and ((ErrCode $r) -eq "VALIDATION_FAILED")) "status=$($r.status) code=$(ErrCode $r)"
    Check "D6 字段级提示落在 password 上" ($null -ne $r.json.error.fields.password) "fields=$($r.json.error.fields | ConvertTo-Json -Compress)"
    $r = Call-Api "POST" "/api/v1/auth/register" @{ register_code = $regCode; phone = $pwPhone; name = "密码探针"; password = ("a" * 33) }
    Check "D6 33 位密码 -> 400（上界；改动前没有上限）" ($r.status -eq 400) "status=$($r.status) code=$(ErrCode $r)"
    # 中文密码：6 个字 = 18 字节，**长度是合法的**，必须靠字符集拒绝（否则这条测不出字符集）
    $r = Call-Api "POST" "/api/v1/auth/register" @{ register_code = $regCode; phone = $pwPhone; name = "密码探针"; password = "密码密码密码" }
    Check "D6 中文密码 -> 400（长度合法，靠字符集拒绝）" ($r.status -eq 400) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/auth/register" @{ register_code = $regCode; phone = $pwPhone; name = "密码探针"; password = "abc 1234" }
    Check "D6 含空格密码 -> 400（不可见字符）" ($r.status -eq 400) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/auth/register" @{ register_code = $regCode; phone = $pwPhone; name = "密码探针"; password = "Abc123._/\-!" }
    Check "D6 数字+英文+符号 且 12 位 -> 201（正例）" ($r.status -eq 201) "status=$($r.status) code=$(ErrCode $r)"
    # 改密码走同一口径；这两次都会被 400 挡在验证之前，不会真的改掉会长密码（后续段落还依赖它）
    $r = Call-Api "PUT" "/api/v1/auth/password" @{ old_password = "newpassword1"; new_password = ("a" * 33) } $presToken2
    Check "D6 改密 33 位 -> 400" ($r.status -eq 400) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "PUT" "/api/v1/auth/password" @{ old_password = "newpassword1"; new_password = "密码密码密码" } $presToken2
    Check "D6 改密中文 -> 400" ($r.status -eq 400) "status=$($r.status) code=$(ErrCode $r)"
    # 反证：会长密码没被这两次被拒的请求改掉
    $r = Call-Api "POST" "/api/v1/auth/login" @{ phone = "13800000000"; password = "newpassword1" }
    Check "D6 被拒的改密没有改掉密码（N-15 同源纪律）" ($r.status -eq 200) "status=$($r.status)"

    # ---------- 25. 注册口令节流（按 IP + 递增退避，N-6） ----------
    # 放在最后一段：它会把本机 IP 锁住，之后再打注册都会 429。
    # 手机号用没被占用的号段；错口令在"手机号查重"之前就被拒，不会留下脏数据。
    Write-Host ""
    Write-Host "[25] 注册口令节流（按客户端 IP，不再是全局锁）"
    for ($i = 1; $i -le 10; $i++) {
        $r = Call-Api "POST" "/api/v1/auth/register" @{ register_code = "WRONGCODE"; phone = "13900000100"; name = "节流探针"; password = "throttle12" }
    }
    Check "错口令第 10 次 -> 400（此时还没锁）" ($r.status -eq 400) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/auth/register" @{ register_code = "WRONGCODE"; phone = "13900000100"; name = "节流探针"; password = "throttle12" }
    Check "第 11 次 -> 429 TOO_MANY_ATTEMPTS（按 IP 锁定）" (($r.status -eq 429) -and ((ErrCode $r) -eq "TOO_MANY_ATTEMPTS")) "status=$($r.status) code=$(ErrCode $r)"
    $r = Call-Api "POST" "/api/v1/auth/register" @{ register_code = $regCode; phone = "13900000101"; name = "锁定期正确口令"; password = "throttle12" }
    Check "锁定期间正确口令也被拒 -> 429（N-6）" (($r.status -eq 429) -and ((ErrCode $r) -eq "TOO_MANY_ATTEMPTS")) "status=$($r.status) code=$(ErrCode $r)"
    # 反证：锁只作用于注册，不影响其它接口
    $r = Call-Api "GET" "/health"
    Check "锁定期间 /health 不受影响（锁只作用于注册）" ($r.status -eq 200) "status=$($r.status)"

    # ---------- 27. 请求体闸门（limits.cj，2026-09-18 新增） ----------
    # 每条都是"回退即变红"的闸门：闸门必须**在 bodyParser 之前**把请求拦住，
    # 否则大 body 会先被框架读进内存（framework 的 1 MiB 是"先读后判"）。
    # 注意：本节必须在 [25] 注册节流之后也没关系 —— 这些请求都在校验之前就被拦。
    Write-Host ""
    Write-Host "[27] 请求体闸门：413 / 415 / 411 / Content-Type 大小写 / 非法 JSON"

    $bigFile = Join-Path $env:TEMP "smoke-gate-big.json"
    $okFile = Join-Path $env:TEMP "smoke-gate-ok.json"
    $xmlFile = Join-Path $env:TEMP "smoke-gate-ok.xml"
    $badFile = Join-Path $env:TEMP "smoke-gate-bad.json"
    $respFile = Join-Path $env:TEMP "smoke-gate-resp.txt"
    $pad = "a" * 70000
    [IO.File]::WriteAllText($bigFile, ('{"pad":"' + $pad + '"}'), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($okFile, '{"phone":"13800000000","password":"newpassword1"}', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($xmlFile, '<a/>', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($badFile, '{not json', [Text.UTF8Encoding]::new($false))

    # ① 超过 64 KiB -> 413，且响应体是**项目信封**（不是框架的 {"error":"..."}）
    $code = [int](& curl.exe -s -o $respFile -w "%{http_code}" --max-time 30 -X POST `
        -H "Content-Type: application/json" --data-binary "@$bigFile" "$base/api/v1/auth/login")
    $body = [string](Get-Content $respFile -Raw -ErrorAction SilentlyContinue)
    Check "27.1 请求体 >64KiB -> 413" ($code -eq 413) "status=$code"
    Check "27.2 413 走项目错误信封（PAYLOAD_TOO_LARGE）" ($body -like "*PAYLOAD_TOO_LARGE*") "body=$body"

    # ② 非白名单 Content-Type -> 415
    $code = [int](& curl.exe -s -o $respFile -w "%{http_code}" --max-time 20 -X POST `
        -H "Content-Type: application/xml" --data-binary "@$xmlFile" "$base/api/v1/auth/login")
    $body = [string](Get-Content $respFile -Raw -ErrorAction SilentlyContinue)
    Check "27.3 非白名单 Content-Type -> 415" ($code -eq 415) "status=$code"
    Check "27.4 415 走项目错误信封（UNSUPPORTED_MEDIA_TYPE）" ($body -like "*UNSUPPORTED_MEDIA_TYPE*") "body=$body"

    # ③ Content-Type 大小写不敏感（RFC 7231 §3.1.1.1）—— 不能 415
    $code = [int](& curl.exe -s -o $respFile -w "%{http_code}" --max-time 20 -X POST `
        -H "Content-Type: Application/JSON" --data-binary "@$okFile" "$base/api/v1/auth/login")
    Check "27.5 Content-Type 大小写不敏感（Application/JSON 不得 415）" ($code -ne 415) "status=$code"

    # ④ chunked（长度不可判定）-> 411：闸门判不了就必须拒，不能放它绕到框架那边
    $code = [int](& curl.exe -s -o $respFile -w "%{http_code}" --max-time 20 -X POST `
        -H "Content-Type: application/json" -H "Transfer-Encoding: chunked" `
        --data-binary "@$okFile" "$base/api/v1/auth/login")
    $body = [string](Get-Content $respFile -Raw -ErrorAction SilentlyContinue)
    Check "27.6 chunked（无 Content-Length）-> 411" ($code -eq 411) "status=$code"
    Check "27.7 411 走项目错误信封（LENGTH_REQUIRED）" ($body -like "*LENGTH_REQUIRED*") "body=$body"

    # ⑤ 非法 JSON -> 400 且统一到项目信封（原先框架直接吐 {"error":"Invalid JSON body"}）
    $code = [int](& curl.exe -s -o $respFile -w "%{http_code}" --max-time 20 -X POST `
        -H "Content-Type: application/json" --data-binary "@$badFile" "$base/api/v1/auth/login")
    $body = [string](Get-Content $respFile -Raw -ErrorAction SilentlyContinue)
    Check "27.8 非法 JSON -> 400" ($code -eq 400) "status=$code"
    Check "27.9 非法 JSON 走项目信封（INVALID_JSON）" ($body -like "*INVALID_JSON*") "body=$body"

    # ⑥ 请求体**不是合法 UTF-8**（客户端编码错）-> 400，**不能是 500**
    #    （2026-09-20 独立复核发现：框架 context.cj 的 bodyJson 把 `body()` 放在 try **之外**，
    #      非 UTF-8 时 String.fromUtf8 先抛，异常绕过 _bodyJsonError 一路到链尾 → 500。
    #      触发现场就是 PowerShell 5.1 的 Invoke-RestMethod：不写 charset 时中文按系统 ANSI(936)
    #      发出，服务端收到 GBK 字节。已在 src\limits.cj 的闸门 ④ 里补上。）
    $gbkFile = Join-Path $env:TEMP "smoke-gate-gbk.json"
    $gbkJson = '{"phone":"13800000000","password":"中文口令"}'
    [IO.File]::WriteAllBytes($gbkFile, [Text.Encoding]::GetEncoding(936).GetBytes($gbkJson))
    $code = [int](& curl.exe -s -o $respFile -w "%{http_code}" --max-time 20 -X POST `
        -H "Content-Type: application/json" --data-binary "@$gbkFile" "$base/api/v1/auth/login")
    $body = [string](Get-Content $respFile -Raw -ErrorAction SilentlyContinue)
    Check "27.10 非 UTF-8 的 JSON body -> 400（不是 500）" ($code -eq 400) "status=$code"
    Check "27.11 非 UTF-8 走项目信封（INVALID_JSON）" ($body -like "*INVALID_JSON*") "body=$body"

    Remove-Item $bigFile, $okFile, $xmlFile, $badFile, $gbkFile, $respFile -ErrorAction SilentlyContinue

    Stop-Server $proc
} finally {
    Pop-Location
}

Write-Host ""
Write-Host "======================================"
Write-Host ("冒烟测试： PASS {0} / FAIL {1}" -f $script:pass, $script:fail)
Write-Host "======================================"
if ($script:fail -gt 0) { exit 1 }
exit 0
