# SPDX-License-Identifier: MIT
#
# ===== kb-check.ps1 —— P5 知识库接口层端到端 ============================
#
# ⚠ 为什么必须有这个脚本（而不是只靠 accept 里的 AC-KB）：
#   AC-KB 检的是**仓储与算法**（不经 HTTP）。而本仓真踩过一次：
#   **新错误码没在 `apiErrorSpec` 里登记** ⇒ 正常的业务拒绝（"同名已存在"、
#   "不存在"）被兜底成 **500**，而**纯逻辑测试完全抓不到**（P4 的教训，写进了
#   http_common.cj 的注释）。
#   ⇒ 本脚本的**核心价值是钉住错误码 → HTTP 状态码的映射**，
#     尤其是"**绝不能是 500**"这一条。
#
# ⚠ 夹具纪律（第十份复查的教训）：本文档**一律用自己的标题前缀 KBCHK**，
#   清理**只按该前缀**删 —— 不按 id 段（AUTO_INCREMENT 会落在别处）、
#   不按通用名字（会与别的用例撞名）。
#
# 用法：.\kb-check.ps1 -AdminPw <口令> [-Base http://127.0.0.1:8091] [-Dsn <DSN>]

[CmdletBinding()]
param(
    [string]$Base = "http://127.0.0.1:8091",
    [Parameter(Mandatory=$true)][string]$AdminPw,
    [string]$Dsn = "mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital_test"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$My = Get-MySqlClientArgs -Dsn $Dsn
$passed = 0
$failed = 0
function Check($name, $cond, $detail) {
    if ($cond) { Write-Host "  [PASS] $name" -ForegroundColor Green; $script:passed++ }
    else { Write-Host "  [FAIL] $name" -ForegroundColor Red; $script:failed++ }
    if ($detail) { Write-Host "         $detail" -ForegroundColor DarkGray }
}

function Req($tag, $method, $path, $headers, $jsonBody) {
    $cfg = Join-Path $env:TEMP ("kbchk_" + $tag + ".cfg")
    $lines = @("request = `"$method`"", "silent", "write-out = `"\n__M__%{http_code}`"")
    foreach ($h in $headers) { $lines += "header = `"$h`"" }
    if ($null -ne $jsonBody) {
        $bf = Join-Path $env:TEMP ("kbchk_" + $tag + ".json")
        [System.IO.File]::WriteAllText($bf, $jsonBody, (New-Object System.Text.UTF8Encoding($false)))
        $lines += "header = `"Content-Type: application/json`""
        $lines += "data = `"@" + ($bf -replace '\\','/') + "`""
    }
    [System.IO.File]::WriteAllText($cfg, ($lines -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
    $raw = (& curl.exe -s -K $cfg "$Base$path" 2>&1) -join "`n"
    $code = 0
    if ($raw -match '__M__(\d+)') { $code = [int]$Matches[1] }
    return [pscustomobject]@{ Http = $code; Body = ($raw -replace '(?s)\n?__M__\d+\s*$','') }
}

function Tok($login, $pw) {
    $r = Req ("lg" + $login) 'POST' '/api/v1/auth/login' @() ('{"login_name":"' + $login + '","password":"' + $pw + '"}')
    if ($r.Http -ne 200) {
        # 限流是服务端的正常保护：能清就清掉计数再重试一次，然后才谈失败
        if (Test-HospLoginRateLimited -Login $login -Resp $r -My $My) {
            $r = Req ("lg2" + $login) 'POST' '/api/v1/auth/login' @() ('{"login_name":"' + $login + '","password":"' + $pw + '"}')
        }
        if ($r.Http -ne 200) { Stop-HospLogin -Login $login -Resp $r -My $My -Base $Base }
    }
    return ($r.Body | ConvertFrom-Json).data.token
}
function Sql($sql) {
    $p = Join-Path $env:TEMP "kbchk.sql"
    [System.IO.File]::WriteAllText($p, $sql, (New-Object System.Text.UTF8Encoding($false)))
    Invoke-MySqlFile -My $My -Path ($p -replace '\\','/')
}
function One($sql) {
    return (Invoke-MySqlScalar -My $My -Label "scalar" -Sql $sql | Out-String).Trim()
}

Write-Host ""
Write-Host "=== P5 知识库接口层端到端 ===" -ForegroundColor Cyan
Write-Host "  目标: $Base"
Write-Host "  库  : $($My.Db)@$($My.DbHost):$($My.Port)"

# ── [0] 夹具：按自己的标题前缀清残留
#
# ★ 夹具纪律之二（2026-10-14，第十一份复查发现）：本脚本必须**自带**它绑定的
#   业务档案（doctor/patient），不能借库里"碰巧存在的行"。
#
#   踩过的坑：这里原来是 `SELECT MAX(id) FROM doctor` 取一个已有医生给 kbchkdoc 绑定。
#   而**别的脚本的清理会把这行删掉** —— 于是第二次跑时账号还在、`ref_id` 指向的行没了，
#   登录**按设计**拒绝签发令牌（auth_repo.cj `authReferenceExists` 判"幽灵业务身份"，
#   见该处注释：不签发、也不泄露缺什么）⇒ 表现为 401 AUTH_BAD_CREDENTIALS，
#   看上去像"口令被改了"，实则是**夹具不幂等**。
#   ⇒ 现在：先删旧账号与旧档案，再自建 department/doctor/patient（固定 id），
#     并在脚本末尾一并清掉。这样本脚本**连跑 N 次结果一致**。
Write-Host ""
Write-Host "[0] 夹具（KBCHK 前缀清残留 + 自建 KBCHK 科室/医生/患者）"
Sql "DELETE FROM kb_chunk WHERE doc_id IN (SELECT id FROM kb_doc WHERE title LIKE 'KBCHK%');
DELETE FROM kb_doc WHERE title LIKE 'KBCHK%';
DELETE FROM auth_token WHERE user_id IN (SELECT id FROM auth_user WHERE login_name IN ('kbchkdoc','kbchkpat'));
DELETE FROM auth_user WHERE login_name IN ('kbchkdoc','kbchkpat');
DELETE FROM doctor WHERE id = 900103;
DELETE FROM patient WHERE id = 960001;
DELETE FROM department WHERE id = 900103 OR code = 'KBCHK900103';
INSERT INTO department (id,name,code,location,sort,enabled,created_at) VALUES (900103,'KBCHK测试科室','KBCHK900103','',900103,1,0);
INSERT INTO doctor (id,name,department_id,title,specialty,enabled,created_at) VALUES (900103,'KBCHK端到端医生',900103,'主任医师','测试',1,0);
INSERT INTO patient (id,phone,name,gender,birth_date,created_at) VALUES (960001,'13800096001','KBCHK端到端患者','M','1990-01-01',0);"
$leftover = One "SELECT COUNT(*) FROM kb_doc WHERE title LIKE 'KBCHK%'"
Check "旧残留已清（剩 $leftover 行）" ("$leftover" -eq '0')
Check "自建档案就绪（doctor 900103 / patient 960001）" `
      ("$(One "SELECT COUNT(*) FROM doctor WHERE id = 900103")" -eq '1' -and `
       "$(One "SELECT COUNT(*) FROM patient WHERE id = 960001")" -eq '1')

$admTok = Tok "admin" $AdminPw

# 建一个医生账号与一个患者账号（验权限边界）
# ★ 绑定的是**上面刚自建**的档案（固定 id），不是"库里碰巧有的那一行"
$docId = 900103
$duid = 0
$r = Req 'mkdoc' 'POST' '/api/v1/admin/users' @("Authorization: Bearer $admTok") ('{"login_name":"kbchkdoc","password":"Zq4nRw8t","role":"doctor","ref_id":' + $docId + '}')
Check "建医生账号 → 201（ref_id=$docId）" ($r.Http -eq 201) ("HTTP $($r.Http) $($r.Body)")
if ($r.Http -eq 201) { $duid = [int](($r.Body | ConvertFrom-Json).data.user_id) }
if ($duid -le 0) { $duid = [int](One "SELECT id FROM auth_user WHERE login_name = 'kbchkdoc'") }
Check "医生账号 id 解析出来（$duid）" ($duid -gt 0)
$null = Req 'setdpw' 'POST' ("/api/v1/admin/users/" + $duid + "/password") @("Authorization: Bearer $admTok") '{"password":"Zq4nRw8t"}'
$docTok = Tok "kbchkdoc" "Zq4nRw8t"

$puid = 0
$r = Req 'mkpat' 'POST' '/api/v1/admin/users' @("Authorization: Bearer $admTok") '{"login_name":"kbchkpat","password":"Zq4nRw8t","role":"patient","ref_id":960001}'
Check "建患者账号 → 201（ref_id=960001）" ($r.Http -eq 201) ("HTTP $($r.Http) $($r.Body)")
if ($r.Http -eq 201) { $puid = [int](($r.Body | ConvertFrom-Json).data.user_id) }
if ($puid -le 0) { $puid = [int](One "SELECT id FROM auth_user WHERE login_name = 'kbchkpat'") }
Check "患者账号 id 解析出来（$puid）" ($puid -gt 0)
$null = Req 'setppw' 'POST' ("/api/v1/admin/users/" + $puid + "/password") @("Authorization: Bearer $admTok") '{"password":"Zq4nRw8t"}'
$patTok = Tok "kbchkpat" "Zq4nRw8t"
Check "三端令牌就绪（管理员/医生/患者 = $($admTok.Length)/$($docTok.Length)/$($patTok.Length) 字符）" `
      ($admTok.Length -eq 64 -and $docTok.Length -eq 64 -and $patTok.Length -eq 64)

# ── [1] 权限边界
Write-Host ""
Write-Host "[1] ★★ 权限边界（知识库**不给患者**）"
Check "未认证 → 401" ((Req 'anon' 'GET' '/api/v1/kb/search?q=%E9%AB%98%E8%A1%80%E5%8E%8B' @() $null).Http -eq 401)
$rp = Req 'pat' 'GET' '/api/v1/kb/search?q=%E9%AB%98%E8%A1%80%E5%8E%8B' @("Authorization: Bearer $patTok") $null
Check "★★ 患者检索 → 403（**不是** 200 —— 只读也不等于可放开）" ($rp.Http -eq 403) ("HTTP $($rp.Http)")
Check "★ 患者写文档 → 403" ((Req 'patw' 'POST' '/api/v1/admin/kb/docs' @("Authorization: Bearer $patTok") '{"title":"KBCHK患者建的","body":"x"}').Http -eq 403)
Check "★ 医生检索 → 200（医生可读）" ((Req 'doc' 'GET' '/api/v1/kb/search?q=%E9%AB%98%E8%A1%80%E5%8E%8B' @("Authorization: Bearer $docTok") $null).Http -eq 200)
Check "★ 医生写文档 → 403（写只给管理员）" ((Req 'docw' 'POST' '/api/v1/admin/kb/docs' @("Authorization: Bearer $docTok") '{"title":"KBCHK医生建的","body":"x"}').Http -eq 403)
Check "★ 医生读列表 → 403（列表是管理端）" ((Req 'docl' 'GET' '/api/v1/admin/kb/docs' @("Authorization: Bearer $docTok") $null).Http -eq 403)

# ── [2] CRUD + 切块
Write-Host ""
Write-Host "[2] 文档 CRUD（含自动切块）"
$body = "高血压患者应当低盐饮食并规律服药，定期监测血压。出现头晕头痛请及时就诊。" * 12
$r = Req 'c1' 'POST' '/api/v1/admin/kb/docs' @("Authorization: Bearer $admTok") `
     ('{"title":"KBCHK高血压须知","category":"内科","body":"' + $body + '"}')
Check "① 建文档 → 201" ($r.Http -eq 201) ("HTTP $($r.Http)")
$docId1 = 0
if ($r.Http -eq 201) { $docId1 = [int](($r.Body | ConvertFrom-Json).data.id) }
$chunks = 0
if ($r.Http -eq 201) { $chunks = [int](($r.Body | ConvertFrom-Json).data.chunk_count) }
Check "★★ ① 长正文被**自动切成多块**（实得 $chunks 块）" ($chunks -ge 2)
Check "★ ① 库里的块数与返回值一致（$(One "SELECT COUNT(*) FROM kb_chunk WHERE doc_id = $docId1") 行）" `
      ("$(One "SELECT COUNT(*) FROM kb_chunk WHERE doc_id = $docId1")" -eq "$chunks")

$r = Req 'g1' 'GET' ("/api/v1/admin/kb/docs/" + $docId1) @("Authorization: Bearer $admTok") $null
Check "② 读详情 → 200 且含 body" ($r.Http -eq 200 -and ($r.Body | ConvertFrom-Json).data.body.Length -gt 0)

$r = Req 'l1' 'GET' '/api/v1/admin/kb/docs' @("Authorization: Bearer $admTok") $null
Check "③ 列表 → 200 且 count ≥ 1" ($r.Http -eq 200 -and [int](($r.Body | ConvertFrom-Json).data.count) -ge 1)

# ── [3] ★★ 错误码映射（本脚本的核心价值）
Write-Host ""
Write-Host "[3] ★★★ 错误码 → HTTP 状态码（**绝不能是 500**）"
$r = Req 'dup' 'POST' '/api/v1/admin/kb/docs' @("Authorization: Bearer $admTok") `
     ('{"title":"KBCHK高血压须知","category":"内科","body":"另一份。"}')
Check "★★ 同名文档 → 409 KB_TITLE_TAKEN（**不是** 500）" `
      ($r.Http -eq 409 -and $r.Body -match 'KB_TITLE_TAKEN') ("HTTP $($r.Http)")
Check "★★ 且消息里带上了**冲突的标题**（不只是一句空话）" ($r.Body -match 'KBCHK') ("$($r.Body)")

$r = Req 'nf' 'GET' '/api/v1/admin/kb/docs/99999999' @("Authorization: Bearer $admTok") $null
Check "★★ 不存在 → 404 KB_DOC_NOT_FOUND（不是 500）" `
      ($r.Http -eq 404 -and $r.Body -match 'KB_DOC_NOT_FOUND') ("HTTP $($r.Http)")

$r = Req 'bad' 'POST' '/api/v1/admin/kb/docs' @("Authorization: Bearer $admTok") '{"title":"","category":"","body":"x"}'
Check "★ 空标题 → 400 VALIDATION_FAILED（不是 500）" ($r.Http -eq 400) ("HTTP $($r.Http)")

$r = Req 'pi' 'POST' '/api/v1/admin/kb/docs' @("Authorization: Bearer $admTok") `
     '{"title":"KBCHK含手机号","category":"","body":"患者电话 13800138000 请随访。"}'
Check "★★ 含手机号形态 → 400（合规闸门，知识库不得放患者信息）" ($r.Http -eq 400) ("HTTP $($r.Http)")
Check "★★ 且理由里说明了是个人信息" ($r.Body -match '个人信息')

$r = Req 'noq' 'GET' '/api/v1/kb/search' @("Authorization: Bearer $admTok") $null
Check "★ 缺 q → 400（不是 500）" ($r.Http -eq 400) ("HTTP $($r.Http)")

$r = Req 'badtop' 'GET' '/api/v1/kb/search?q=%E9%AB%98%E8%A1%80%E5%8E%8B&top=99999' @("Authorization: Bearer $admTok") $null
Check "★ 超大 top 被夹住（仍 200，不因参数越界而 500/超时）" ($r.Http -eq 200) ("HTTP $($r.Http)")

# ── [4] 检索语义
Write-Host ""
Write-Host "[4] ★★ 检索：source 如实标注 + 命中块"
$r = Req 's1' 'GET' '/api/v1/kb/search?q=%E9%AB%98%E8%A1%80%E5%8E%8B' @("Authorization: Bearer $admTok") $null
Check "① 检索 → 200" ($r.Http -eq 200)
$j = $r.Body | ConvertFrom-Json
Check "★★ ① `source` = keyword（**不冒充** vector）" ($j.data.source -eq 'keyword') ("source=$($j.data.source)")
$hitOk = $true
foreach ($h in @($j.data.items)) { if ($h.source -ne 'keyword') { $hitOk = $false } }
Check "★★ ① 每条命中也都标 keyword" $hitOk
Check "★ ① 命中块内容确实含查询词" ((@($j.data.items | Where-Object { $_.content -match '高血压' })).Count -ge 1)
Check "★ ① 含 scanned 与 missing_vectors（口径可见）" `
      ($null -ne $j.data.scanned -and $null -ne $j.data.missing_vectors)

$r = Req 's2' 'GET' '/api/v1/kb/search?q=%EF%BC%8C%E3%80%82%EF%BC%81' @("Authorization: Bearer $admTok") $null
Check "★ ② 纯标点查询 → 200 且 0 命中（不返回随机块）" `
      ($r.Http -eq 200 -and [int](($r.Body | ConvertFrom-Json).data.count) -eq 0)

# ── [5] ★★★ 改短 ⇒ 旧块必须消失（HTTP 端到端）
Write-Host ""
Write-Host "[5] ★★★ 改正文后**旧块消失**（HTTP 端到端）"
$before = [int](One "SELECT COUNT(*) FROM kb_chunk WHERE doc_id = $docId1")
$r = Req 'u1' 'PUT' ("/api/v1/admin/kb/docs/" + $docId1) @("Authorization: Bearer $admTok") `
     '{"title":"KBCHK高血压须知","category":"内科","body":"KBCHK短正文：仅一段。"}'
Check "① 改成短正文 → 200" ($r.Http -eq 200) ("HTTP $($r.Http)")
$after = [int](One "SELECT COUNT(*) FROM kb_chunk WHERE doc_id = $docId1")
Check "★★★ ② 块数从 $before 降到 $after（尾部旧块已删）" ($after -eq 1)
Check "★★★ ③ 且库里**没有任何**残留的旧块内容" `
      ("$(One "SELECT COUNT(*) FROM kb_chunk WHERE doc_id = $docId1 AND content LIKE '%规律服药%'")" -eq '0')

# 停用 ⇒ 检索不到
$r = Req 'u2' 'PUT' ("/api/v1/admin/kb/docs/" + $docId1) @("Authorization: Bearer $admTok") `
     ('{"title":"KBCHK高血压须知","category":"内科","body":"KBCHK停用检索专用内容甲乙丙。","enabled":false}')
Check "④ 停用 → 200" ($r.Http -eq 200)
$r = Req 's3' 'GET' '/api/v1/kb/search?q=KBCHK%E5%81%9C%E7%94%A8%E6%A3%80%E7%B4%A2%E4%B8%93%E7%94%A8' @("Authorization: Bearer $admTok") $null
Check "★★ ⑤ 停用后检索不到（enabled 是检索语义的一部分）" ([int](($r.Body | ConvertFrom-Json).data.count) -eq 0)

# ── [6] 删除连带块
Write-Host ""
Write-Host "[6] 删文档 ⇒ 块连带删除"
$r = Req 'd1' 'DELETE' ("/api/v1/admin/kb/docs/" + $docId1) @("Authorization: Bearer $admTok") $null
Check "① 删除 → 200" ($r.Http -eq 200) ("HTTP $($r.Http)")
Check "★★ ② 其块也被删（真删，与科室软删策略不同）" `
      ("$(One "SELECT COUNT(*) FROM kb_chunk WHERE doc_id = $docId1")" -eq '0')
$r = Req 'd2' 'DELETE' ("/api/v1/admin/kb/docs/" + $docId1) @("Authorization: Bearer $admTok") $null
Check "★ ③ 再删 → 404（不是 500）" ($r.Http -eq 404) ("HTTP $($r.Http)")

# ── [7] stats
Write-Host ""
Write-Host "[7] 规模统计"
$r = Req 'st' 'GET' '/api/v1/admin/kb/stats' @("Authorization: Bearer $admTok") $null
Check "① stats → 200" ($r.Http -eq 200)
$sj = $r.Body | ConvertFrom-Json
Check "★ ② 含 docs/chunks/embedding_coverage_pct" `
      ($null -ne $sj.data.docs -and $null -ne $sj.data.chunks -and $null -ne $sj.data.embedding_coverage_pct)
Check "★★ ③ 含口径说明（0% 时不能让人以为「功能坏了」）" ($sj.data.embedding_note.Length -gt 0)
Check "★★ ③ 且给出**布尔结论** scan_limit_reached（静默触顶的显式信号）" `
      ($null -ne $sj.data.scan_limit_reached -and $null -ne $sj.data.scan_limit)

# ── [8] ★★ 看板里的知识库规模（与 stats 同源、且**独立容错**）
Write-Host ""
Write-Host "[8] ★★ 看板知识库块"
$r = Req 'dash' 'GET' '/api/v1/admin/dashboard' @("Authorization: Bearer $admTok") $null
Check "① 看板 → 200（知识库表缺失时也不该整页 500）" ($r.Http -eq 200) ("HTTP $($r.Http)")
$dj = $r.Body | ConvertFrom-Json
Check "★★ ② 含 knowledge_base 块" ($null -ne $dj.data.knowledge_base)
Check "★★ ② 且计数存在（实际值随库变化，只断言「有真实的数」）" `
      ($null -ne $dj.data.knowledge_base.docs -and $null -ne $dj.data.knowledge_base.chunks)
Check "★★ ③ 含 scan_limit_reached（看板上**一眼可见**是否触顶，不让人自己去比）" `
      ($null -ne $dj.data.knowledge_base.scan_limit_reached)
Check "★★ ③ 且含口径说明（0% 不等于功能损坏）" ($dj.data.knowledge_base.note.Length -gt 0)

# ── 清理
# ★ 连**账号与业务档案**一起清：只清文档的话，下次跑就又会撞上"账号在、ref_id 指向的行不在"
#   （见 [0] 夹具纪律之二的注释）。
Sql "DELETE FROM kb_chunk WHERE doc_id IN (SELECT id FROM kb_doc WHERE title LIKE 'KBCHK%');
DELETE FROM kb_doc WHERE title LIKE 'KBCHK%';
DELETE FROM auth_token WHERE user_id IN (SELECT id FROM auth_user WHERE login_name IN ('kbchkdoc','kbchkpat'));
DELETE FROM auth_user WHERE login_name IN ('kbchkdoc','kbchkpat');
DELETE FROM doctor WHERE id = 900103;
DELETE FROM patient WHERE id = 960001;
DELETE FROM department WHERE id = 900103 OR code = 'KBCHK900103';"
$final = One "SELECT COUNT(*) FROM kb_doc WHERE title LIKE 'KBCHK%'"
Check "清理：本脚本的文档已全部删除（剩 $final 行）" ("$final" -eq '0')
Check "清理：本脚本的账号与档案已删除（不留给下一次跑）" `
      ("$(One "SELECT COUNT(*) FROM auth_user WHERE login_name IN ('kbchkdoc','kbchkpat')")" -eq '0' -and `
       "$(One "SELECT COUNT(*) FROM doctor WHERE id = 900103")" -eq '0' -and `
       "$(One "SELECT COUNT(*) FROM patient WHERE id = 960001")" -eq '0')

Write-Host ""
if ($failed -eq 0) {
    Write-Host "✅ 知识库接口层验证全部通过（通过 $passed 项）" -ForegroundColor Green
    exit 0
} else {
    Write-Host "❌ 失败 $failed 项（通过 $passed 项）" -ForegroundColor Red
    exit 1
}
