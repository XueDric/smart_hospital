<#
  在服务端种入一批「知识库种子文档」，并验证**检索真的能命中**（评估报告 P1-5）。

  ## 为什么需要这个脚本

  知识库的检索路是（关键词路，见 `server/src/kb.cj` 文件头）：
    文档入库 → 切块 → 查询词切词 → 命中块计分 → topN
  「有没有接上」这件事，**光看代码看不出来**：一条文档能写进去、但切词器不认它的词，
  检索就永远 0 命中，而页面上一切正常。所以这里种完立刻**用查询词验一遍**。

  ## 用法

    # 1) 先起库与服务端（默认 3417 / 8091）
    .\server\devdb.ps1 start -Port 3417
    .\build\hospital-server.exe serve mysql://hospital:<pw>@127.0.0.1:3417/hospital_test --port 8091

    # 2) 种入 8 条种子并验证检索（管理端口令：create-admin 生成的那个）
    .\server\tests\kb-seed.ps1 -AdminPw <口令>

    # 3) 想让分诊真的用上知识库（`used_kb=true`），再加患者账号跑一次分诊
    .\server\tests\kb-seed.ps1 -AdminPw <口令> -PatientLogin <患者登录名> -PatientPw <患者口令>

  -Reset 会先删掉所有标题以「种子：」开头的文档（幂等重跑）。

  退出码：0 = 全部断言通过；1 = 有断言失败（会打印是哪一条）。
##>
param(
    [string]$Base = "http://127.0.0.1:8091",
    [string]$AdminLogin = "admin",
    [string]$AdminPw = $env:HOSPITAL_ADMIN_PW,
    [string]$Token = $env:HOSPITAL_ADMIN_TOKEN,
    [string]$PatientLogin = "",
    [string]$PatientPw = "",
    [switch]$Reset
)

$ErrorActionPreference = "Stop"
$fail = 0
function Check([string]$name, [bool]$ok, [string]$extra = "") {
    if ($ok) {
        if ($extra) { Write-Host ("  [PASS] " + $name + " —— " + $extra) } else { Write-Host ("  [PASS] " + $name) }
    } else {
        $script:fail++
        if ($extra) { Write-Host ("  [FAIL] " + $name + " —— " + $extra) -ForegroundColor Red } else { Write-Host ("  [FAIL] " + $name) -ForegroundColor Red }
    }
}

function Invoke-Api([string]$method, [string]$path, $body) {
    $args = @("--noproxy", "*", "-s", "-X", $method, ($Base + $path))
    if ($script:tok) { $args += @("-H", ("Authorization: Bearer " + $script:tok)) }
    $tmp = $null
    if ($null -ne $body) {
        $tmp = [System.IO.Path]::GetTempFileName()
        $json = ($body | ConvertTo-Json -Compress -Depth 8)
        [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
        $args += @("-H", "Content-Type: application/json", "--data-binary", ("@" + $tmp))
    }
    $raw = & curl.exe @args
    if ($tmp -and (Test-Path $tmp)) { Remove-Item $tmp -Force }
    if (-not $raw) { return $null }
    return ($raw | ConvertFrom-Json)
}

Write-Host "== 0. 取得管理员令牌 =="
$script:tok = $Token
if (-not $script:tok) {
    if (-not $AdminPw) { Write-Host "  [FAIL] 需要 -AdminPw（或用 HOSPITAL_ADMIN_PW / HOSPITAL_ADMIN_TOKEN）" -ForegroundColor Red; exit 1 }
    $r = Invoke-Api "POST" "/api/v1/auth/login" @{ login_name = $AdminLogin; password = $AdminPw }
    if ($r -and $r.ok) { $script:tok = $r.data.token }
    Check "管理员登录" ([bool]$script:tok)
    if (-not $script:tok) { exit 1 }
}

Write-Host "== 1. 可选：清理上一次的种子文档 =="
if ($Reset) {
    $list = Invoke-Api "GET" "/api/v1/admin/kb/docs?include_disabled=true" $null
    $seeds = @($list.data.items | Where-Object { $_.title -like "种子：*" })
    foreach ($d in $seeds) { Invoke-Api "DELETE" ("/api/v1/admin/kb/docs/" + $d.id) $null | Out-Null }
    Check "清理旧种子文档" $true ("" + $seeds.Count + " 条")
}

Write-Host "== 2. 种入 8 条知识库文档 =="
$docs = @(
    @{ t = "种子：呼吸内科就诊指引"; c = "呼吸内科"; b = "呼吸内科负责咳嗽、发热、咽痛、咳痰、气短等呼吸道症状的初诊。`n就诊前请准备：症状开始的日期、最高体温、痰的颜色、是否接触过发热病人。`n持续咳嗽超过两周、痰中带血、夜间盗汗者，请尽早到呼吸内科门诊。`n门诊楼 3F，工作日 08:00-17:00。" },
    @{ t = "种子：消化内科就诊指引"; c = "消化内科"; b = "消化内科负责腹痛、腹泻、反酸、腹胀、恶心呕吐、便血等消化道症状。`n就诊前请准备：疼痛位置与性质、与进食的关系、大便性状与次数。`n剧烈腹痛伴冷汗、黑便或呕血，请立即到急诊。`n门诊楼 3F。" },
    @{ t = "种子：皮肤科就诊指引"; c = "皮肤科"; b = "皮肤科负责皮疹、瘙痒、红斑、脱屑、荨麻疹、痤疮与色素问题。`n就诊前请准备：皮疹出现时间、是否瘙痒、近期用药与接触物、手机里拍下的皮疹照片。`n皮疹伴呼吸困难、面部肿胀，请立即到急诊。`n门诊楼 4F。" },
    @{ t = "种子：骨科就诊指引"; c = "骨科"; b = "骨科负责膝关节疼痛、腰背痛、扭伤、骨折后复查与运动损伤。`n就诊前请准备：受伤经过、疼痛动作、是否肿胀、既往影像片。`n外伤后肢体变形、无法负重、麻木发凉，请到急诊。`n门诊楼 2F。" },
    @{ t = "种子：儿科就诊指引"; c = "儿科"; b = "儿科负责 14 岁以下儿童的发热、咳嗽、腹泻、皮疹与生长发育问题。`n就诊前请准备：孩子的月龄/年龄、体重、体温曲线、精神状态与进食情况。`n三个月以下婴儿发热、抽搐、嗜睡，请立即到急诊。`n门诊楼 2F。" },
    @{ t = "种子：妇产科就诊指引"; c = "妇产科"; b = "妇产科负责月经异常、孕期保健、腹痛与产后复查。`n就诊前请准备：末次月经日期、孕周、既往孕产史、近期用药。`n孕期阴道流血、剧烈腹痛、胎动明显减少，请立即到急诊。`n门诊楼 4F。" },
    @{ t = "种子：眼科就诊指引"; c = "眼科"; b = "眼科负责眼红、眼痛、视力下降、异物感与眼外伤。`n就诊前请准备：哪只眼、症状持续时间、是否戴隐形眼镜、近期外伤。`n突然视物不见、眼外伤或化学物入眼，请立即到急诊冲洗并就诊。`n门诊楼 5F。" },
    @{ t = "种子：急诊与危急征象识别"; c = "急诊"; b = "出现胸痛、呼吸困难、意识障碍、抽搐、大出血、剧烈头痛、言语不清或肢体无力，请立即到急诊或拨打 120。`n急诊 24 小时开放，位于门诊楼 1F 东侧。`n分诊台会按病情紧急程度安排顺序，危急患者优先。" }
)
$created = 0
$existed = 0
foreach ($d in $docs) {
    $r = Invoke-Api "POST" "/api/v1/admin/kb/docs" @{ title = $d.t; category = $d.c; body = $d.b }
    if ($r -and $r.ok) {
        $created++
    } elseif ($r -and $r.error -and $r.error.code -eq "KB_TITLE_TAKEN") {
        # 幂等：同名文档已存在（重跑不 -Reset 时的正常情况），当作"已在库里"
        $existed++
    } else {
        Write-Host ("    写入失败：" + $d.t + " —— " + ($r | ConvertTo-Json -Compress)) -ForegroundColor Red
    }
}
Check "8 条文档都在库里（新写入 + 已存在）" (($created + $existed) -eq 8) ("" + $created + " 条新写入 / " + $existed + " 条已存在")

Write-Host "== 3. 验证切块与检索（这才是「真的接上」的证据）=="
$list = Invoke-Api "GET" "/api/v1/admin/kb/docs?include_disabled=true" $null
$seedsNow = @($list.data.items | Where-Object { $_.title -like "种子：*" })
Check "管理端能列出种子文档" ($seedsNow.Count -ge 8) ("" + $seedsNow.Count + " 条")
$withChunks = @($seedsNow | Where-Object { $_.chunk_count -gt 0 })
Check "每条都切出了块（chunk_count > 0）" ($withChunks.Count -eq $seedsNow.Count) ("" + $withChunks.Count + "/" + $seedsNow.Count)

$queries = @(
    @{ q = "咳嗽 发热 咽痛"; expect = "呼吸内科" },
    @{ q = "腹痛 腹泻"; expect = "消化内科" },
    @{ q = "皮疹 瘙痒"; expect = "皮肤科" },
    @{ q = "膝关节疼痛"; expect = "骨科" },
    @{ q = "胸痛 呼吸困难"; expect = "急诊" }
)
foreach ($item in $queries) {
    $enc = [System.Uri]::EscapeDataString($item.q)
    $r = Invoke-Api "GET" ("/api/v1/kb/search?q=" + $enc + "&top=5") $null
    $hits = @($r.data.items)
    $titles = ($hits | ForEach-Object { $_.title }) -join " / "
    Check ("检索「" + $item.q + "」有命中") ($hits.Count -gt 0) ("" + $hits.Count + " 条；source=" + $r.data.source + "；" + $titles)
    $hitExpected = @($hits | Where-Object { $_.title -like ("*" + $item.expect + "*") }).Count -gt 0
    Check ("  且命中包含「" + $item.expect + "」") $hitExpected
}

Write-Host "== 4. 可选：跑一次真实分诊，看 used_kb =="
if ($PatientLogin -and $PatientPw) {
    $saved = $script:tok
    $script:tok = $null
    $lr = Invoke-Api "POST" "/api/v1/auth/login" @{ login_name = $PatientLogin; password = $PatientPw }
    if ($lr -and $lr.ok) { $script:tok = $lr.data.token }
    Check "患者登录" ([bool]$script:tok)
    if ($script:tok) {
        $tr = Invoke-Api "POST" "/api/v1/triage" @{ chief_complaint = "咳嗽三天，伴发热和咽痛" }
        Check "分诊请求成功" ([bool]($tr -and $tr.ok))
        $rid = ""
        if ($tr -and $tr.ok) {
            $rid = $tr.data.request_id
            Write-Host ("    source=" + $tr.data.source + "  可用号源=" + @($tr.data.options).Count + "  request_id=" + $rid)
            if ($tr.data.ai_note) { Write-Host ("    ai_note=" + $tr.data.ai_note) }
            if ($tr.data.ai_reason) { Write-Host ("    ai_reason=" + $tr.data.ai_reason) }
        }
        $script:tok = $saved
        # ⚠ used_kb **不在分诊响应里**（响应只给患者看的东西）。它落在 triage_stat 的调用事实里，
        #   要按 request_id 去 /api/v1/admin/ai/triage-calls/<id> 查 —— 这是有意的：
        #   患者不该看到"我们检索了 2 个块"这种内部细节。
        if ($rid) {
            Start-Sleep -Milliseconds 200
            $call = Invoke-Api "GET" ("/api/v1/admin/ai/triage-calls/" + $rid) $null
            $row = @($call.data.items)[0]
            if ($row) {
                Check "这次分诊 used_kb = true" ($row.used_kb -eq $true) ("kb_doc_ids=" + $row.kb_doc_ids + "  source=" + $row.source + "  elapsed=" + $row.elapsed_ms + "ms  degrade=" + $row.degrade_reason)
            } else {
                Check "能按 request_id 查到调用事实" $false
            }
        }
    }
} else {
    Write-Host "  （跳过：未提供 -PatientLogin/-PatientPw，`used_kb` 未验证）"
}

Write-Host ""
if ($fail -eq 0) { Write-Host "✅ 知识库种子与检索验证全部通过" } else { Write-Host ("❌ 有 " + $fail + " 条断言失败") -ForegroundColor Red; exit 1 }
