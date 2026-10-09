# SPDX-License-Identifier: MIT
#
# ===== base-check.ps1 —— 基础数据域（科室/医生）管理端 CRUD 端到端验证 ====
#
# 覆盖（重点在**权限**与**错误码映射**这两层 —— accept 抓不到它们）：
#   [1] 权限：只有管理员能维护科室/医生
#   [2] 科室：建 / 改 / 删；**同名 409**（分诊按科室名查，同名会让判断分裂）
#   [3] 医生：建 / 改 / 删；**孤儿医生被拒**（本仓无外键，靠应用层守）
#   [4] 删除的两种语义：有引用 ⇒ 409 且说清是谁；force ⇒ **软删**（行还在）
#   [5] 错误码映射：409/404/400 各自正确（★ P4 踩过"新错误码没注册 ⇒ 全 500"）
#   [6] ★★ **闭环**：新科室建好后，**分诊能推荐它** ——
#       这是本阶段真正要修的那条链路（此前 triage 查 department 而没人能写入）
#
# ⚠⚠ **不要与 `hospital-server.exe accept` 并发跑**：accept 的 `hResetAll`
#   （acceptance.cj）会**整表清空**业务表（appointment / schedule / doctor /
#   department / patient），会把本脚本的夹具删掉 ⇒ 假红。两边也都
#   `taskkill /F /IM hospital-server.exe`，会杀掉对方的 serve（症状是 `HTTP 0`）。
#   ⇒ HTTP 层 e2e 与 `accept` **必须串行**。
#
# 用法：
#   .\base-check.ps1 -Base http://127.0.0.1:8091 -AdminPw <口令> -Dsn <DSN>

[CmdletBinding()]
param(
    [string]$Base = "http://127.0.0.1:8091",
    [Parameter(Mandatory=$true)][string]$AdminPw,
    [string]$Dsn = "mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital_test"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$root = Split-Path -Parent $PSScriptRoot
$Exe = Join-Path $root "build\hospital-server.exe"
if (-not (Test-Path $Exe)) { throw "找不到 $Exe（先跑 build.ps1）" }

$My = Get-MySqlClientArgs -Dsn $Dsn
$passed = 0
$failed = 0
function Check($name, $cond, $detail) {
    if ($cond) { Write-Host "  [PASS] $name" -ForegroundColor Green; $script:passed++ }
    else { Write-Host "  [FAIL] $name" -ForegroundColor Red; $script:failed++ }
    if ($detail) { Write-Host "         $detail" -ForegroundColor DarkGray }
}

# ★★ 防御式取"新建实体的 id"。
#
# ⚠⚠ 我在这里**连续错了三次**，值得写下来：
#   · 第一次猜 `data.user_id`（后来误改成 `data.id`）⇒ 账号口令重设打到 /users/0
#   · 现在又猜 `data.id` 取医生 ⇒ 拿到错值 ⇒ DELETE 打到一个**不存在**的 id
#     症状是 404 BASE_NOT_FOUND，看起来**像产品的删除坏了**，其实是脚本取错了 id。
#   📌 教训：脚本**不要猜接口字段名**。三种可能的形状都试一遍，
#     再兜底"按唯一名字查库" —— 这样字段名怎么变都不会给出**误导性的红**。
function PickId($obj, $candidates, $fallbackSql) {
    foreach ($c in $candidates) {
        $v = $obj.$c
        if ($null -ne $v -and "$v" -match '^\d+$' -and [int]$v -gt 0) { return [int]$v }
    }
    if ($fallbackSql) {
        $n = [int](Invoke-MySqlScalar -My $My -Label "兜底取 id" -Sql $fallbackSql)
        if ($n -gt 0) { return $n }
    }
    return 0
}
# curl 配置文件发请求（不用 -d '...' —— PowerShell 会破坏 JSON 引号）
function Req($tag, $method, $path, $headers, $jsonBody) {
    $cfg = Join-Path $env:TEMP ("base_" + $tag + ".cfg")
    $lines = @("request = `"$method`"", "silent", "write-out = `"\n__M__%{http_code}`"")
    foreach ($h in $headers) { $lines += "header = `"$h`"" }
    if ($null -ne $jsonBody) {
        $bf = Join-Path $env:TEMP ("base_" + $tag + ".json")
        [System.IO.File]::WriteAllText($bf, $jsonBody, (New-Object System.Text.UTF8Encoding($false)))
        $lines += "header = `"Content-Type: application/json`""
        $lines += "data = `"@" + ($bf -replace '\\','/') + "`""
    }
    [System.IO.File]::WriteAllText($cfg, ($lines -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
    $raw = (& curl.exe -s -K $cfg "$Base$path" 2>&1) -join "`n"
    $code = 0
    if ($raw -match '__M__(\d+)') { $code = [int]$Matches[1] }
    $body = ($raw -replace '(?s)\n?__M__\d+\s*$','')
    return [pscustomobject]@{ Http = $code; Body = $body }
}
function Tok($login, $pw) {
    $r = Req ("lg" + $login) 'POST' '/api/v1/auth/login' @() ('{"login_name":"' + $login + '","password":"' + $pw + '"}')
    if ($r.Http -ne 200) { throw "登录失败 $login ($($r.Http)): $($r.Body)" }
    return ($r.Body | ConvertFrom-Json).data.token
}
function SqlFile($sql, $label) {
    $p = Join-Path $env:TEMP "base_sql.sql"
    [System.IO.File]::WriteAllText($p, $sql, (New-Object System.Text.UTF8Encoding($false)))
    Invoke-MySqlFile -My $My -Path ($p -replace '\\','/')
}
function Scalar($sql) {
    return (Invoke-MySqlScalar -My $My -Label "scalar" -Sql $sql | Out-String).Trim()
}

Write-Host ""
Write-Host "=== 基础数据域（科室/医生）CRUD 端到端验证 ===" -ForegroundColor Cyan
Write-Host "  目标: $Base"
Write-Host "  库  : $($My.Db)@$($My.DbHost):$($My.Port)"

# ── [0] 夹具：清掉本脚本的 id 段，并准备一个患者账号用于权限测试
Write-Host ""
Write-Host "[0] 准备夹具"
SqlFile @"
DELETE FROM appointment WHERE department_id BETWEEN 950000 AND 950999;
DELETE FROM schedule WHERE department_id BETWEEN 950000 AND 950999;
DELETE FROM doctor WHERE department_id BETWEEN 950000 AND 950999;
DELETE FROM department WHERE id BETWEEN 950000 AND 950999;
DELETE FROM patient WHERE id = 950001;
INSERT INTO patient (id, phone, name, gender, birth_date, created_at)
  VALUES (950001, '13900950001', 'Base游客', 'M', '1990-01-01', 0)
  ON DUPLICATE KEY UPDATE name = VALUES(name);
"@ "base 夹具"

# ⚠⚠ 夹具必须**按名字/登录名再清一遍**，不能只按 id 段。
#   理由：上一轮若在建科室那步失败（例如残留导致 409），那些行的 id 可能落在
#   950000 段**之外**，"按段清"清不掉 ⇒ 下一轮建同名又 409 ⇒
#   **看起来是产品坏了，其实是夹具不干净**。实测踩过：`Base测试科` 残留
#   导致连续两轮 409，我为此排查了两轮。
SqlFile @"
DELETE FROM auth_user WHERE login_name = 'basepatient';
DELETE FROM department WHERE name IN
  ('Base测试科','Base测试科（改名）','Base另一个科','Base可删科','呼吸内科','患者建的科');
"@ "base 夹具（按名字/登录名清残留）"
Check "夹具就绪（按 id 段 + 按名字双重清理）" $true

$admTok = Tok "admin" $AdminPw
# 患者账号（绑 patient 950001）——用于"患者无权维护科室"
# ⚠⚠ 口令**不能是登录名加前后缀** —— 本仓 P1 的口令强度规则会算"登录名 ± 前后缀"
#   与"去掉首尾字符"的组合，`BasePatient1` 被判成 `basepatient`+`1` ⇒ **400 被拒**。
#   我为此排查了很久（症状是"账号没建成 ⇒ 后续患者侧断言全 401 假红"），
#   而**产品行为完全正确** —— 是测试口令起得太像登录名。
#   📌 教训：夹具口令要与登录名**毫无关系**，否则会触发强度规则，且症状看起来
#     像"权限坏了"（401）而不是"口令被拒"（400）。
$patPw = "Kx7mQp2w"
$r = Req 'mkpat' 'POST' '/api/v1/admin/users' @("Authorization: Bearer $admTok") `
     ('{"login_name":"basepatient","password":"' + $patPw + '","role":"patient","ref_id":950001,"display_name":"Base患者"}')
# ⚠ 建号要接受 **201 与 409 两种**：上面的夹具按登录名删了 auth_user，
#   但若删失败（或本脚本被并发跑）就会撞 USER_EXISTS(409)。
#   409 时**必须**走下面的查库兜底拿 user_id —— 否则 $uid 恒为 0，
#   口令重设打到 /users/0 ⇒ 后续"患者侧"断言全 401（假红）。
#   📌 这就是当初那 11 项失败的**头号根因的邻居**：路径在 201 上，一遇 409 就全崩。
$uid = 0
if ($r.Http -eq 201) {
    # ⚠ 服务端回的字段名是 **`user_id`**（见 http_app.cj 的 `o.put("user_id", ...)`）。
    #   我先前"修"的时候误写成 `data.id` ⇒ uid 恒为 0 ⇒ 口令重设打到 /users/0/password
    #   ⇒ 400/404 ⇒ 后续所有"患者侧"断言全部假红（401）。
    #   📌 教训：**不要靠猜接口字段名** —— 拿不准时两种都试，或直接查库兜底。
    $uid = PickId ($r.Body | ConvertFrom-Json).data @('user_id','id') "SELECT id FROM auth_user WHERE login_name = 'basepatient'"
}
if ($uid -le 0) {
    # 兜底：直接查库（账号已存在时走这条）
    $uid = [int](Invoke-MySqlScalar -My $My -Label "取 auth_user.id" -Sql "SELECT id FROM auth_user WHERE login_name = 'basepatient'")
}
Check "★ 拿到患者账号的 auth_user.id（$uid）" ($uid -gt 0)
$rp = Req 'setpatpw' 'POST' "/api/v1/admin/users/$uid/password" @("Authorization: Bearer $admTok") ('{"password":"' + $patPw + '"}')
Check "★ 患者口令已按 auth_user.id 重设（HTTP $($rp.Http)）" ($rp.Http -eq 200) ("HTTP $($rp.Http)")
# ⚠⚠ 2026-10-09 实测定位：**这一行曾经缺失**。
#   旧版脚本只写了 Check "$patTok.Length -eq 64"，却**从来没有**调用 Tok 登录
#   ⇒ $patTok 是 $null，而 PowerShell 对 $null.Length 先返回 $null、再拿 $null
#     与 64 比 ⇒ 表达式为 $false ⇒ 恒 FAIL，**且不报错**（静默假红）。
#   代价：后面所有"患者侧"断言（读/建科室、分诊）都拿 Bearer $null 发请求 ⇒ 401，
#   看起来像"权限坏了/令牌没换到"，其实是**脚本自己没取令牌**。
#   📌 教训：断言里**不要**引用一个从未赋值的变量 —— 它不会报错，只会一直红。
$patTok = Tok "basepatient" $patPw
Check "患者账号就绪（绑 patient 950001）" ($patTok.Length -eq 64) ("token $($patTok.Length) 字符")

# ── [1] 权限
Write-Host ""
Write-Host "[1] 权限：只有管理员能维护科室/医生"
$r = Req 'p1' 'GET' '/api/v1/admin/departments' @("Authorization: Bearer $patTok") $null
Check "★ 患者读科室列表 → 403" ($r.Http -eq 403) ("HTTP $($r.Http)")
$r = Req 'p2' 'POST' '/api/v1/admin/departments' @("Authorization: Bearer $patTok") '{"name":"患者建的科","code":"HACK"}'
Check "★★ 患者建科室 → 403" ($r.Http -eq 403) ("HTTP $($r.Http)")
$r = Req 'p3' 'GET' '/api/v1/admin/departments' @() $null
Check "★ 无令牌读科室 → 401" ($r.Http -eq 401) ("HTTP $($r.Http)")
$r = Req 'p4' 'GET' '/api/v1/admin/departments' @("Authorization: Bearer $admTok") $null
Check "管理员读科室列表 → 200" ($r.Http -eq 200) ("HTTP $($r.Http)")

# ── [2] 科室 CRUD
Write-Host ""
Write-Host "[2] 科室：建 / 改 / 同名 409"
$r = Req 'dc1' 'POST' '/api/v1/admin/departments' @("Authorization: Bearer $admTok") `
     '{"name":"Base测试科","code":"BASET1","location":"门诊楼1层","sort":7}'
Check "★ 建科室 → 201（不是 200：语义要分清「新建」与「已存在」）" ($r.Http -eq 201) ("HTTP $($r.Http)")
$did = PickId ($r.Body | ConvertFrom-Json).data @('department_id','id') "SELECT id FROM department WHERE name = 'Base测试科' ORDER BY id DESC LIMIT 1"
Check "且返回新 id（$did）" ($did -gt 0)
Check "★ 响应里带回完整对象（客户端不必再查一次）" (($r.Body | ConvertFrom-Json).data.department.name -eq 'Base测试科')

$r = Req 'dc2' 'POST' '/api/v1/admin/departments' @("Authorization: Bearer $admTok") `
     '{"name":"Base测试科","code":"BASET2"}'
Check "★★ 同名科室 → 409（**不是 400**：请求合法，是与既有数据冲突）" ($r.Http -eq 409) ("HTTP $($r.Http)")
Check "★★ 且错误码是 BASE_NAME_TAKEN（客户端能据此定位到「名字」这个字段）" (($r.Body | ConvertFrom-Json).error.code -eq 'BASE_NAME_TAKEN') (($r.Body | ConvertFrom-Json).error.code)

$r = Req 'dc3' 'POST' '/api/v1/admin/departments' @("Authorization: Bearer $admTok") `
     '{"name":"Base另一个科","code":"BASET1"}'
Check "★ 同编码 → 409 BASE_CODE_TAKEN" ($r.Http -eq 409 -and ($r.Body | ConvertFrom-Json).error.code -eq 'BASE_CODE_TAKEN') ("HTTP $($r.Http) $(($r.Body | ConvertFrom-Json).error.code)")

$r = Req 'dc4' 'POST' '/api/v1/admin/departments' @("Authorization: Bearer $admTok") '{"name":"  ","code":"BLANK"}'
Check "★ 空白名字 → 400 VALIDATION_FAILED（**参数问题**，与冲突区分开）" ($r.Http -eq 400) ("HTTP $($r.Http)")

$r = Req 'du1' 'PUT' "/api/v1/admin/departments/$did" @("Authorization: Bearer $admTok") `
     '{"name":"Base测试科（改名）","code":"BASET1","location":"门诊楼2层","sort":9}'
Check "改科室 → 200" ($r.Http -eq 200) ("HTTP $($r.Http)")
Check "★ 改后 created_at 未变（历史不该随编辑被篡改）" `
      ((($r.Body | ConvertFrom-Json).data.department.created_at) -eq (Scalar "SELECT created_at FROM department WHERE id=$did"))

$r = Req 'dg1' 'GET' "/api/v1/admin/departments/999999" @("Authorization: Bearer $admTok") $null
Check "★ 读不存在的科室 → 404 BASE_NOT_FOUND" ($r.Http -eq 404) ("HTTP $($r.Http)")
$r = Req 'dg2' 'GET' "/api/v1/admin/departments/abc" @("Authorization: Bearer $admTok") $null
Check "★ 非数字 id → 404（不查库、不 500）" ($r.Http -eq 404) ("HTTP $($r.Http)")

# ── [3] 医生 CRUD 与孤儿保护
Write-Host ""
Write-Host "[3] 医生：建 / 改 / 孤儿被拒"
$r = Req 'dr1' 'POST' '/api/v1/admin/doctors' @("Authorization: Bearer $admTok") `
     ('{"name":"Base测试医生","department_id":' + $did + ',"title":"主治医师","specialty":"测试"}')
Check "建医生 → 201" ($r.Http -eq 201) ("HTTP $($r.Http)")
$docId = PickId ($r.Body | ConvertFrom-Json).data @('doctor_id','id') "SELECT id FROM doctor WHERE name = 'Base测试医生' ORDER BY id DESC LIMIT 1"
Check "★ 响应带 department_name（列表可读，客户端不必再查科室）" `
      ((($r.Body | ConvertFrom-Json).data.doctor.department_name) -eq 'Base测试科（改名）') (($r.Body | ConvertFrom-Json).data.doctor.department_name)

$r = Req 'dr2' 'POST' '/api/v1/admin/doctors' @("Authorization: Bearer $admTok") `
     '{"name":"孤儿医生","department_id":999999}'
Check "★★ 科室不存在 → 400（**不许产生孤儿医生**：本仓无外键，靠应用层守）" ($r.Http -eq 400) ("HTTP $($r.Http)")
Check "★★ 且说明原因（含科室 id，便于排查）" ($r.Body -match '科室不存在')

$r = Req 'dr3' 'GET' "/api/v1/admin/doctors?department_id=$did" @("Authorization: Bearer $admTok") $null
$docs = @(($r.Body | ConvertFrom-Json).data.items)
Check "★ 按科室过滤只返回该科室医生（实得 $($docs.Count) 位）" ($docs.Count -eq 1) ("ids=$(($docs | ForEach-Object { $_.id }) -join ',')")
Check "★ 且没有混入其它科室" ((@($docs | Where-Object { $_.department_id -ne $did })).Count -eq 0)

$r = Req 'du2' 'PUT' "/api/v1/admin/doctors/$docId" @("Authorization: Bearer $admTok") `
     ('{"name":"Base测试医生（改名）","department_id":' + $did + ',"title":"副主任医师"}')
Check "改医生 → 200" ($r.Http -eq 200) ("HTTP $($r.Http)")

# ── [4] 删除的两种语义
#
# ★★★ 2026-10-09 更正（我先前在这里写错过一次，留档免得再错）：
#
#   我曾经断言「带查询串打路径参数路由会 404，所以 ?force=true 经 HTTP 不可达」，

#
#   真正的根因是 **PowerShell 的插值陷阱**：
#       "/api/v1/admin/departments/$did?force=true"
#   PowerShell 会把 `$did?` 当成**变量名**（变量名允许含 `?`）⇒ 展开成**空** ⇒
#   实际 URL 变成 `/api/v1/admin/departments/?force=true`（id 段为空）⇒ 命中 `:id` 路由
#   但 id 解析为 0 ⇒ 404 BASE_NOT_FOUND。**看起来像路由坏了，其实是 URL 拼错了。**
#   📌 正确写法：`"…/${did}?force=true"`（加花括号界定变量名）。
#
#   我用一个**临时探针端点**回显了服务端实际收到的值，一次就把这事钉死了：
#       DELETE /api/v1/_probe/123?force=true
#       -> {"path":"/api/v1/_probe/123","query":"force=true","id_raw":"123","force":"true"}
#   ⇒ 查询串**没有**混进 path，`paramOr("id")` 与 `queryParamOr("force")` 都正常。
#     框架的路由**没有**这个问题（`router.cj` 与基线逐字节相同，也不需要改）。
#
#   ⇒ 本节现在**如实测两条语义**（这才是本来要测的）：
#     · 有引用 ⇒ 409 BASE_IN_USE，且行必须还在（拒绝是真的拒绝）；
#     · `?force=true` ⇒ **软删**：行保留 + enabled=0（两条断言缺一不可 ——
#       只测"行还在"会让"什么都没做"也通过）。
Write-Host ""
Write-Host "[4] 删除语义：有引用 ⇒ 409（行还在）；force ⇒ 软删（行保留 + enabled=0）"
$r = Req 'dd1' 'DELETE' "/api/v1/admin/departments/$did" @("Authorization: Bearer $admTok") $null
Check "★★ 科室下有医生 ⇒ 默认删除 409" ($r.Http -eq 409) ("HTTP $($r.Http)")
Check "★★ 且错误码 BASE_IN_USE，消息**说清是谁在用**" `
      ((($r.Body | ConvertFrom-Json).error.code -eq 'BASE_IN_USE') -and ($r.Body -match '医生')) (($r.Body | ConvertFrom-Json).error.message)
Check "★★ 且库里那行**还在**（拒绝是真的拒绝）" ((Scalar "SELECT COUNT(*) FROM department WHERE id=$did") -eq '1')

# ── 回归：路径参数路由**带**查询串必须与不带时同样可达
#   （这条留着，因为"带查询串就坏"曾经是一个**看起来很像真的**误判 ——
#     有它钉住，将来真出现这种问题时能被立刻区分出来。）
$r = Req 'dq1' 'GET' "/api/v1/admin/departments/$did" @("Authorization: Bearer $admTok") $null
$cleanGet = $r.Http
$r = Req 'dq2' 'GET' "/api/v1/admin/departments/${did}?x=1" @("Authorization: Bearer $admTok") $null
$queryGet = $r.Http
Check "★★ 同一路径参数路由：带查询串与不带**同为 200**（查询串不得影响路由）" `
      ($cleanGet -eq 200 -and $queryGet -eq 200) ("clean=$cleanGet query=$queryGet")

# ── ★★ 软删：行保留 **且** enabled 置 0（缺一不可）
$docEnabledBefore = Scalar "SELECT enabled FROM doctor WHERE id=$docId"
$r = Req 'dd2' 'DELETE' "/api/v1/admin/doctors/${docId}?force=true" @("Authorization: Bearer $admTok") $null
$docEnabledAfter = Scalar "SELECT enabled FROM doctor WHERE id=$docId"
Check "★★ 医生 ?force=true ⇒ 200 软删（HTTP $($r.Http)）" ($r.Http -eq 200) ("HTTP $($r.Http)")
Check "★★ 且响应标 soft_deleted=true（如实告知「不是真删」）" ((($r.Body | ConvertFrom-Json).data.soft_deleted) -eq $true)
Check "★★★ 行**仍在库里**（历史挂号/病历还能解析出医生名）" ((Scalar "SELECT COUNT(*) FROM doctor WHERE id=$docId") -eq '1')
Check "★★★ 且 enabled $docEnabledBefore -> 0（证明真的动了，不是「什么都没做」）" `
      ($docEnabledBefore -eq '1' -and $docEnabledAfter -eq '0') ("enabled=$docEnabledAfter")

# 科室软删（此时其下医生已被软删，不再构成"启用的医生"引用）
$r = Req 'dd3' 'DELETE' "/api/v1/admin/departments/${did}?force=true" @("Authorization: Bearer $admTok") $null
Check "★ 科室 ?force=true ⇒ 200 软删（HTTP $($r.Http)）" ($r.Http -eq 200) ("HTTP $($r.Http)")
Check "★★ 科室行保留**且** enabled=0（两条都要，否则「什么都没做」也会通过）" `
      ((Scalar "SELECT COUNT(*) FROM department WHERE id=$did") -eq '1' -and (Scalar "SELECT enabled FROM department WHERE id=$did") -eq '0')

# 未被引用的科室可以真删
$r = Req 'dc9' 'POST' '/api/v1/admin/departments' @("Authorization: Bearer $admTok") '{"name":"Base可删科","code":"BASEDEL"}'
$delId = PickId ($r.Body | ConvertFrom-Json).data @('department_id','id') "SELECT id FROM department WHERE name = 'Base可删科' ORDER BY id DESC LIMIT 1"
$r = Req 'dd9' 'DELETE' "/api/v1/admin/departments/$delId" @("Authorization: Bearer $admTok") $null
Check "★ 未被引用的科室 → 真删（200，soft_deleted=false）" ($r.Http -eq 200 -and ($r.Body | ConvertFrom-Json).data.soft_deleted -eq $false) ("HTTP $($r.Http)")
Check "★ 且库里确实没了" ((Scalar "SELECT COUNT(*) FROM department WHERE id=$delId") -eq '0')

# ── [5] 错误码映射抽查
Write-Host ""
Write-Host "[5] 错误码映射（★ P4 踩过「新错误码没注册 ⇒ 全 500」）"
$codes = @{}
foreach ($t in @(@('e1','POST','/api/v1/admin/departments','{"name":"Base测试科（改名）","code":"BASEX"}'),
                 @('e2','GET',"/api/v1/admin/departments/999999",$null),
                 @('e3','POST','/api/v1/admin/departments','{"name":"","code":"X"}'))) {
    $r = Req $t[0] $t[1] $t[2] @("Authorization: Bearer $admTok") $t[3]
    $codes[$t[0]] = $r.Http
    Check "  $($t[0]) → HTTP $($r.Http)（不是 500）" ($r.Http -ne 500) ("code=$(($r.Body | ConvertFrom-Json).error.code)")
}

# ── [6] ★★ 闭环：新科室能被分诊推荐
Write-Host ""
Write-Host "[6] ★★ 闭环：建好的科室**能被分诊推荐**（这才是本阶段要修的那条链路）"
SqlFile @"
DELETE FROM schedule WHERE department_id BETWEEN 950000 AND 950999;
DELETE FROM department WHERE id BETWEEN 950000 AND 950999;
"@ "清旧"
# 建一个名字能被分诊词表命中的科室（"呼吸内科"是分诊的既有科室名）
$r = Req 'c1' 'POST' '/api/v1/admin/departments' @("Authorization: Bearer $admTok") '{"name":"呼吸内科","code":"RESP950"}'
# ⚠ 这里原来写的是 `data.id` —— 与第 2 节同一条纪律：**不要猜字段名**，统一走 PickId。
#   （`data.id` 目前确实存在，但字段名一旦换成 `department_id` 就会静默变 0，
#     症状是"排班建了但分诊推荐不出来"，看起来像分诊坏了。）
$respId = PickId ($r.Body | ConvertFrom-Json).data @('department_id','id') "SELECT id FROM department WHERE name = '呼吸内科' ORDER BY id DESC LIMIT 1"
Check "① 通过管理端建出「呼吸内科」（HTTP $($r.Http)）" ($respId -gt 0) ("id=$respId")
# 给该科室建医生 + 排班（分诊只推荐**有号**的科室）
$r = Req 'c2' 'POST' '/api/v1/admin/doctors' @("Authorization: Bearer $admTok") ('{"name":"Base呼吸医生","department_id":' + $respId + ',"title":"医师"}')
$docId2 = PickId ($r.Body | ConvertFrom-Json).data @('doctor_id','id') "SELECT id FROM doctor WHERE name = 'Base呼吸医生' ORDER BY id DESC LIMIT 1"
Check "② 通过管理端建出该科室的医生" ($docId2 -gt 0) ("id=$docId2")
SqlFile @"
INSERT INTO schedule (doctor_id, department_id, work_date, period, total_num, remain_num, version, enabled, created_at)
  VALUES ($docId2, $respId, '2027-03-01', 'AM', 10, 10, 0, 1, 0);
"@ "加排班"
Check "③ 给该医生排了号（有号才可能被推荐）" ((Scalar "SELECT COUNT(*) FROM schedule WHERE department_id=$respId") -eq '1')

# 患者调分诊 —— 主诉是"咳嗽"，词表命中呼吸内科
$r = Req 'tri' 'POST' '/api/v1/triage' @("Authorization: Bearer $patTok") '{"chief_complaint":"咳嗽三天"}'
Check "④ 患者调分诊 → 200" ($r.Http -eq 200) ("HTTP $($r.Http)")
$tri = $r.Body | ConvertFrom-Json
Check "★★⑤ 分诊推荐**含**刚建出的「呼吸内科」——" `
      ((@($tri.data.options | Where-Object { $_.department_name -eq '呼吸内科' })).Count -ge 1) `
      ("推荐=$(($tri.data.options | ForEach-Object { $_.department_name }) -join ',')")
Check "★★⑤ 且推荐的排班有号（绝不给没号的推荐）" `
      ((@($tri.data.options | Where-Object { $_.department_name -eq '呼吸内科' -and $_.remain_num -le 0 })).Count -eq 0)
Check "⑤ source 如实标注（未接模型时为 rules）" ($tri.data.source -eq 'rules') ($tri.data.source)

# 清理
SqlFile @"
DELETE FROM schedule WHERE department_id BETWEEN 950000 AND 950999;
DELETE FROM doctor WHERE department_id BETWEEN 950000 AND 950999;
DELETE FROM department WHERE id BETWEEN 950000 AND 950999;
"@ "清理"

Write-Host ""
if ($failed -eq 0) {
    Write-Host "✅ 基础数据域 CRUD 验证全部通过（通过 $passed 项）" -ForegroundColor Green
    exit 0
} else {
    Write-Host "❌ 失败 $failed 项（通过 $passed 项）" -ForegroundColor Red
    exit 1
}
