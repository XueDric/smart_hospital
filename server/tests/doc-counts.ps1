# 文档数字校验：把文档里写的测试项数与**实测值**对账
#
# ── 为什么要有这个脚本（2026-10-07 加）────────────────────────────────────
# "文档里的测试项数"这一类数字，本项目已经**漂移过两次**：
#   第一次：selftest 写 32、实际 33（加断言后没回头改）
#   第二次：删了 AC-8 后，P1 交接稿 / ADR / server/README 仍写 33 / 35（实际 30 / 43）
# 两次都是同一个毛病：**同一个事实存了多份，改一处忘其它处**。
#
# 光靠"下次记得改"是没用的（已经忘两次了）。所以做法变成：
#   ① 数字以**跑出来的结果**为准，不靠人记；
#   ② 本脚本负责"跑 + 对账"，把它当 CI 的一步来跑；
#   ③ 文档里凡出现项数的地方，都必须能被本脚本查到（见 $checks）。
#
# 用法（需要 devdb 在跑 + 建过管理员）：
#   .\tests\doc-counts.ps1
#   .\tests\doc-counts.ps1 -Fix        # 直接按实测值改写文档
#
# ⚠ 含中文的 PowerShell 脚本必须 UTF-8 with BOM。

param(
    [string]$Dsn = "mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital_test",
    [switch]$Fix
)

$ErrorActionPreference = "Stop"
$serverDir = Split-Path $PSScriptRoot -Parent
$repoDir   = Split-Path $serverDir -Parent
$exe       = Join-Path $serverDir "build\hospital-server.exe"

if (-not (Test-Path $exe)) { throw "找不到 $exe，先跑 build.ps1" }

# ── 1) 跑出实测值 ─────────────────────────────────────────────────────────
function Get-PassCount([string]$args_) {
    $out = & $exe @($args_.Split(' ')) 2>&1
    $text = ($out -join "`n")
    # ★ 2026-10-17 评审 P1-6：**先看退出码，再看 PASS 数**。
    #   原实现只数 `[PASS]` 行：库里夹具被前次运行污染（或连不上库）时 accept 会失败，
    #   PASS 数随之变小，脚本却把它当成"文档写错了"报 DRIFT —— 会把人引去改文档。
    #   现在：非 0 退出或出现 `[FAIL]` ⇒ 判定"实测不成立"，不产出可对账的数字。
    if ($LASTEXITCODE -ne 0) {
        Write-Host $text
        throw "『$args_』退出码 $LASTEXITCODE（非 0）—— 实测不成立，先修环境/换干净库，别改文档。"
    }
    $fails = ([regex]::Matches($text, '\[FAIL\]')).Count
    if ($fails -gt 0) {
        Write-Host $text
        throw "『$args_』有 $fails 项 [FAIL] —— 实测不成立，先修失败项，别改文档。"
    }
    return ([regex]::Matches($text, '\[PASS\]')).Count
}

Write-Host "=== 实测（这是唯一的权威来源）==="
$actual = [ordered]@{}
$actual['selftest'] = Get-PassCount 'selftest'
$actual['authtest'] = Get-PassCount 'authtest'
$actual['accept']   = Get-PassCount "accept $Dsn"
# ★ P2 分诊纯逻辑自检（triagetest）—— 与 selftest 同理：从**运行结果**数，不写死。
#   ⚠ 必须在**这里**算（不能放到下面去）：`$actual['triagetest']` 当场就要用它，
#     而 PowerShell 是顺序执行 —— 我第一版把计算放在文件下半部分，
#     结果登记到的是**空值**，对账报"文档写 60，实测 <空>"，
#     看起来像文档错，实际是脚本自己的赋值顺序错。

$triOut = & $exe triagetest 2>&1 | Out-String
$triExit = $LASTEXITCODE
$triPass = ([regex]::Matches($triOut, '\[PASS\]')).Count
$triFail = ([regex]::Matches($triOut, '\[FAIL\]')).Count
# ✅ 2026-10-17 复查：**必须先看退出码**。triagetest 起不来（例如库连不上）时
#   输出里一个 [PASS] 都没有 ⇒ 实测=0 ⇒ 报"文档写 150，实测 0"的假 DRIFT，
#   而真因是环境。与 Get-PassCount 里踩过的坑是同一个 —— 教训只吃一次。
if ($triExit -ne 0 -or $triFail -gt 0) {
    throw "triagetest 实测不成立（exit=$triExit，[FAIL]=$triFail 项）：先修环境，别改文档。"
}
$actual['triagetest'] = $triPass
# ★ final-verify 的"项数"= 它 `$specs` 里的条目数，即"一条命令跑多少道门禁"。
#   同样从源码数：加了门禁却忘了改文档，正是本脚本存在的理由
#   （2026-10-17 把 doc-counts 接进去，17 → 18 就是这一项）。
$fvSrc = [System.IO.File]::ReadAllText((Join-Path $serverDir "tests\final-verify.ps1"), [System.Text.UTF8Encoding]::new($false))
$actual['finalverify'] = ([regex]::Matches($fvSrc, "@\{\s*n = '")).Count
# ★ 提交数：文档写"107 个提交（截至 tag v0.2.0-p1-rev）"，就用 **tag 指向的提交数**核对 ——
#   不能拿 HEAD 核：文档一旦这么写，每加一个提交都会假红（评审 P1-2 漂的就是这个数字）。
#   tag 不存在时退回 HEAD 并告警（否则本地没取 tag 的人会看到一个无法解释的红）。
$tagName = 'v0.2.0-p1-rev'
$tagCount = (& git -C (Split-Path -Parent $serverDir) rev-list --count "$tagName" 2>$null)
if (-not $tagCount -or $LASTEXITCODE -ne 0) {
    Write-Warning "  提交数：取不到 tag $tagName（改用 HEAD），文档里的提交数请按 HEAD 核对"
    $tagCount = (& git -C (Split-Path -Parent $serverDir) rev-list --count HEAD 2>$null)
}
$actual['commits'] = [int]$tagCount

# ── HAP 字节数：入库证据里的 .hap 与文档里写的必须一致 ──────────────────────
#   理由：HAP 每次重建都会变（有一次 1,714,016 → 1,742,917 B），而 README/DEPLOYMENT
#   把字节数当"可核对的现场证据"写着。人抄的数字会过期，所以让它对账。
$hapPath = Join-Path $repoDir 'release\harmony\entry-default-unsigned.hap'
if (Test-Path $hapPath) {
    $actual['hapsize'] = (Get-Item $hapPath).Length
    Write-Host ("  入库 HAP 字节数 = {0:N0}" -f $actual['hapsize'])
} else {
    Write-Warning "  找不到 release\harmony\entry-default-unsigned.hap（证据未入库？）"
}
# accept 用例的最大编号（AC-1…AC-N 里的 N）——由源码里 runner.acN() 的调用推导
$accSrc = [System.IO.File]::ReadAllText((Join-Path $serverDir "src\acceptance.cj"), [System.Text.UTF8Encoding]::new($false))
# ★ AC 编号上限：既数 `runner.acN()`（AC-1…AC-12），也认 P2 的用例（AC-P2-N）。
#   P2 的用例是**独立函数**（`acP2_N(runner, db)`），不是 runner 的成员，
#   所以正则要同时覆盖两种调用形态 —— 否则"上限"会停留在 AC-12，
#   而文档写 AC-P2-4 就会被误报成漂移（反之更糟：新用例加了没人发现）。
$acNums = [regex]::Matches($accSrc, 'runner\.ac(\d+)\(\)') | ForEach-Object { [int]$_.Groups[1].Value }
$acP2Nums = [regex]::Matches($accSrc, '\bacP2_(\d+)\(') | ForEach-Object { [int]$_.Groups[1].Value }
# P3 用例在 acceptance_ai.cj 里（acP3_N）；一并数进来，否则新加的 P3 用例没人对账
$accAiSrc = [System.IO.File]::ReadAllText((Join-Path $serverDir 'src\acceptance_ai.cj'), [System.Text.UTF8Encoding]::new($false))
$acP3Nums = [regex]::Matches($accSrc + $accAiSrc, '\bacP3_(\d+)\(') | ForEach-Object { [int]$_.Groups[1].Value }
# P4 用例在 acceptance_p4.cj 里（acP4_N）—— 同上，不数进来就没人对账
$accP4Src = [System.IO.File]::ReadAllText((Join-Path $serverDir 'src\acceptance_p4.cj'), [System.Text.UTF8Encoding]::new($false))
$acP4Nums = [regex]::Matches($accSrc + $accP4Src, '\bacP4_(\d+)\(') | ForEach-Object { [int]$_.Groups[1].Value }
# 公告域用例在 acceptance_notice.cj 里（acNoticeN）—— 第五套体系，同样要有人对账，
# 否则"新加了用例但文档没提"会悄悄过去（这正是本脚本存在的理由）。
$accNoticeSrc = [System.IO.File]::ReadAllText((Join-Path $serverDir 'src\acceptance_notice.cj'), [System.Text.UTF8Encoding]::new($false))
$acNoticeNums = [regex]::Matches($accNoticeSrc, '\bacNotice(\d+)\(') | ForEach-Object { [int]$_.Groups[1].Value }
$acNoticeMax = 0
if ($acNoticeNums.Count -gt 0) { $acNoticeMax = ($acNoticeNums | Measure-Object -Maximum).Maximum }
$acMax = ($acNums | Measure-Object -Maximum).Maximum
$acP2Max = 0
if ($acP2Nums.Count -gt 0) { $acP2Max = ($acP2Nums | Measure-Object -Maximum).Maximum }
# 展示用：有 P2 用例时上限写作 "AC-P2-<n>"
$acMaxLabel = "AC-$acMax"
$acP3Max = 0
if ($acP3Nums.Count -gt 0) { $acP3Max = ($acP3Nums | Measure-Object -Maximum).Maximum }
$acP4Max = 0
if ($acP4Nums.Count -gt 0) { $acP4Max = ($acP4Nums | Measure-Object -Maximum).Maximum }
if ($acP4Max -gt 0) { $acMaxLabel = "AC-P4-$acP4Max" }
elseif ($acP3Max -gt 0) { $acMaxLabel = "AC-P3-$acP3Max" }
elseif ($acP2Max -gt 0) { $acMaxLabel = "AC-P2-$acP2Max" }
# ★ 对账用"**单一可比数字**"：AC-N 记 N，AC-P2-N 记 N（两套编号各自独立计数，
#   所以文档里 `AC-1…AC-P2-4` 与 `AC-1…AC-12` 表达的是**同一个上限概念**）。
#   正则接受两种写法，取到的数字都应等于对应体系的最大 N。
foreach ($k in $actual.Keys) { Write-Host ("  {0,-9} = {1}" -f $k, $actual[$k]) }
Write-Host "  AC 编号上限（五套体系各自）= AC-$acMax / AC-P2-$acP2Max / AC-P3-$acP3Max / AC-P4-$acP4Max / AC-NOTICE-$acNoticeMax"

# ★ REST 端点数 —— 这个数字最容易漂：
#   每加一个端点都得回头改 README，而"加了但忘了改文档"正是本项目漂过两次的病。
#
# ⚠⚠ P4 时发现它自己有**两个缺陷**（都会让它**静默少数**，比少数更坏的是"看起来对"）：
#   ① 正则只写 `r\.(get|post|put|del)\(` —— 漏了 `delete(`（框架的方法是 `delete`）。
#      于是用 `r.delete(...)` 注册的端点**永远不被计入**。
#   ② 只扫 `http_app.cj` —— 而 P4 把 11 个端点放在 `http_p4.cj`
#      （理由：那一块有自己的纪律要写清）。⇒ 不扫它就会漏掉整块。
#   ⇒ 现在：扫**全部注册文件**（清单显式给出，与"路由注册集中可见"这条约定配套）。
#     并覆盖 `delete`。📌 教训：**计数脚本本身也要能被"加了东西"这件事验证到** ——
#     否则它会给一个恒定的旧数字，而所有人都以为它对。
$regFiles = @("src\http_app.cj", "src\http_p4.cj", "src\http_base.cj", "src\http_kb.cj", "src\http_notice.cj")
$epCount = 0
foreach ($rf in $regFiles) {
    $p = Join-Path $serverDir $rf
    if (Test-Path $p) {
        $src = [System.IO.File]::ReadAllText($p, [System.Text.UTF8Encoding]::new($false))
        $n = ([regex]::Matches($src, 'r\.(get|post|put|delete)\("/api/')).Count
        Write-Host ("  REST 端点（{0}）= {1}" -f $rf, $n)
        $epCount += $n
    } else {
        Write-Warning "  端点计数：找不到 $rf（清单与代码脱节）"
    }
}
Write-Host "  REST 端点数 = $epCount"




# ── 2) 文档里"应该"写的值（想加新位置就往这里加一行）───────────────────
#    每项：文件、匹配的正则（含一个捕获组）、期望值来源
$checks = @(
    @{ File = "server\README.md";     Pattern = '\| `selftest` \|[^\r\n]*自检（\*\*?(?<n>\d+) 项'; Want = 'selftest' },
    @{ File = "server\README.md";     Pattern = '`accept <dsn>` \| 验收测试 AC-1…AC-(?:P[234]-)?(?<ac>\d+)（\*\*(?<n>\d+) 项断言\*\*'; Want = 'accept' },
    @{ File = "server\README.md";     Pattern = '`src/acceptance\.cj` \| AC-1…AC-(?:P[234]-)?(?<ac>\d+) 验收测试'; Want = 'accept' },
    @{ File = "README.md";            Pattern = '\*\*(?<ep>\d+) 个 REST\*\*'; Want = 'endpoints' },
    @{ File = "server\README.md";     Pattern = '`triagetest` \|[^|]*?自检（\*\*\s*(?<n>\d+) 项\*\*'; Want = 'triagetest' },
    @{ File = "docs\adr\ADR-0001-号源与挂号独立MySQL路径.md"; Pattern = '`hospital-server\.exe selftest` \| ✅ \*\*(?<n>\d+) 项\*\*'; Want = 'selftest' },
    @{ File = "docs\adr\ADR-0001-号源与挂号独立MySQL路径.md"; Pattern = '`hospital-server\.exe accept <dsn>` \| ✅ \*\*(?<n>\d+) 项 / 失败 0\*\*'; Want = 'accept' },
    @{ File = "server\README.md";     Pattern = '`src/acceptance_notice\.cj` \| AC-NOTICE-1…AC-NOTICE-(?<ac>\d+)'; Want = 'accept' },
    # ── 2026-10-17 补的对账点：README / 总览 / 系统设计 / 部署 里"跑出来的数字" ──
    #    加这些的理由：这几处原先靠人抄，triagetest 110→139、accept 762→777 都漂过一次。
    @{ File = "README.md";            Pattern = '`accept` \*\*(?<n>\d+) 条断言\*\*'; Want = 'accept' },
    @{ File = "README.md";            Pattern = '`triagetest` (?<n>\d+) \+'; Want = 'triagetest' },
    @{ File = "README.md";            Pattern = '`final-verify` (?<n>\d+)/\d+ 全绿'; Want = 'finalverify' },
    @{ File = "docs\项目说明.md"; Pattern = '`triagetest` (?<n>\d+) \+'; Want = 'triagetest' },
    @{ File = "docs\项目说明.md"; Pattern = '`accept` (?<n>\d+) 断言'; Want = 'accept' },
    @{ File = "docs\项目说明.md"; Pattern = '`final-verify` (?<n>\d+) 项门禁'; Want = 'finalverify' },
    @{ File = "docs\系统设计.md";    Pattern = '(?<n>\d+) 条断言的验收套件'; Want = 'accept' },
    @{ File = "docs\系统设计.md";    Pattern = '\| \*\*(?<n>\d+) 条断言\*\* \|'; Want = 'accept' },
    @{ File = "docs\系统设计.md";    Pattern = '\| 全量门禁 \| `final-verify\.ps1` \| (?<n>\d+)/\d+ 全绿 \|'; Want = 'finalverify' },
    @{ File = "docs\部署说明.md";       Pattern = '全量验收（(?<n>\d+) 项）'; Want = 'accept' },
    @{ File = "docs\部署说明.md";       Pattern = '一次跑完 \*\*(?<n>\d+) 项\*\*'; Want = 'finalverify' },
    # 2026-10-17：DEPLOYMENT 的耗时/项数表曾漏改 triagetest（110 → 139），加一条对账点钉住
    @{ File = "docs\部署说明.md";       Pattern = '`通过 (?<n>\d+) 项，失败 0 项`'; Want = 'triagetest' },
    # ── 提交数：三处都锚在 tag 上，用 tag 指向的提交数核对（见 $actual['commits'] 的注释）──
    @{ File = "README.md";                Pattern = '\| 提交历史 \| (?<n>\d+) 个提交'; Want = 'commits' },
    @{ File = "docs\项目说明.md"; Pattern = '共 (?<n>\d+) 个提交'; Want = 'commits' },
    # ── SYSTEM-DESIGN 的"51 + 17 + N 项"曾漏改 triagetest（110 → 139）──
    @{ File = "docs\系统设计.md";    Pattern = '51 \+ 17 \+ (?<n>\d+) 项'; Want = 'triagetest' },
    # ── HAP 字节数（带千位分隔，比较时剥掉逗号）──
    @{ File = "README.md";                Pattern = '`entry-default-unsigned\.hap`（(?<n>[\d,]+) B'; Want = 'hapsize' },
    @{ File = "docs\部署说明.md";       Pattern = '`entry-default-unsigned\.hap`（(?<n>[\d,]+) B'; Want = 'hapsize' }
)

# ── 3) 对账 ───────────────────────────────────────────────────────────────
$bad = 0
foreach ($c in $checks) {
    $path = Join-Path $repoDir $c.File
    if (-not (Test-Path $path)) { Write-Warning "  文档不存在：$($c.File)"; continue }
    $text = [System.IO.File]::ReadAllText($path, [System.Text.UTF8Encoding]::new($false))
    $m = [regex]::Match($text, $c.Pattern)
    if (-not $m.Success) {
        Write-Host "  [MISS] $($c.File) —— 匹配不到（文档措辞改了？请同步更新本脚本的正则）"
        Write-Host "         正则: $($c.Pattern)"
        $bad++
        continue
    }
    $want = if ($c.Want -eq "endpoints") { $epCount } elseif ($c.Want -eq "hapsize") { $actual["hapsize"] } else { $actual[$c.Want] }
    # ★ 用具名组取数 —— 不再靠"捕获组顺序"（那东西一改正则就错，实测被坑过）
    #
    # 两种检查形态（用哪个看正则里有哪些具名组）：
    #   · 有 `n`  → 检查"项数"是否等于实测 PASS 数；
    #   · 只有 `ac` → 检查"AC 编号上限"是否等于源码里 runner.acN() 的最大 N。
    #     （这类检查没有"项数"可比，不能要求它必须有 n 组。）
    # 端点数检查（只有 ep 具名组）
    if ($m.Groups['ep'].Success) {
        $gotEp = [int]$m.Groups['ep'].Value
        if ($gotEp -eq $epCount) {
            Write-Host "  [OK]   $($c.File) —— REST 端点数 = $gotEp"
        } else {
            Write-Host "  [DRIFT] $($c.File) —— 文档写 $gotEp 个端点，实测 $epCount 个"
            $bad++
        }
        continue
    }
    $hasN  = $m.Groups['n'].Success
    $hasAc = $m.Groups['ac'].Success
    if (-not ($hasN -or $hasAc)) {
        Write-Host "  [MISS] $($c.File) —— 正则里既无 (?<n>...) 也无 (?<ac>...)，无法比对"
        Write-Host "         正则: $($c.Pattern)"
        $bad++
        continue
    }
    if ($hasAc) {
        $gotAc = [int]$m.Groups['ac'].Value
        # 文档里若是 `AC-…AC-P2-N`，该与 P2 用例的最大编号比；否则与 AC-N 的比
        # 公告域写 `AC-NOTICE-1…AC-NOTICE-N`，与 acNoticeN 的最大编号比。
        $isP2Label = $m.Value -match 'P2-'
        $isP3Label = $m.Value -match 'P3-'
        $isP4Label = $m.Value -match 'P4-'
        $isNoticeLabel = $m.Value -match 'NOTICE-'
        $wantAc = if ($isNoticeLabel) { $acNoticeMax } elseif ($isP4Label) { $acP4Max } elseif ($isP3Label) { $acP3Max } elseif ($isP2Label) { $acP2Max } else { $acMax }
        if ($gotAc -eq $wantAc) {
            Write-Host "  [OK]   $($c.File) —— AC 编号上限 = AC-$gotAc（$(if ($isNoticeLabel) { "公告域" } elseif ($isP2Label) { "P2 体系" } else { "主体系" })）"
        } else {
            Write-Host "  [DRIFT] $($c.File) —— 文档写 AC-$gotAc，实测上限 $acMaxLabel"
            $bad++
        }
    }
    if (-not $hasN) { continue }
    $got = [int]($m.Groups['n'].Value -replace ',', '')
    if ($got -eq $want) {
        Write-Host "  [OK]   $($c.File) —— $($c.Want) = $got"
    } else {
        Write-Host "  [DRIFT] $($c.File) —— 文档写 $got，实测 $want"
        $bad++
    }
}

Write-Host ""
if ($bad -eq 0) {
    Write-Host "✅ 文档数字与实测一致"
    exit 0
}

if ($Fix) {
    Write-Host "=== -Fix：按实测值改写 ==="
    foreach ($c in $checks) {
        $path = Join-Path $repoDir $c.File
        if (-not (Test-Path $path)) { continue }
        $text = [System.IO.File]::ReadAllText($path, [System.Text.UTF8Encoding]::new($false))
        $want = if ($c.Want -eq "endpoints") { $epCount } elseif ($c.Want -eq "hapsize") { $actual["hapsize"] } else { $actual[$c.Want] }
        $n = 0
        $new = [regex]::Replace($text, $c.Pattern, {
            param($mm)
            $script:n++
            # ⚠⚠ 用"按组值替换"而不是"按下标 Remove/Insert"。
            # 第一版按下标改（`$mm.Value.Remove($g.Index - $mm.Index, …)`）实测报
            # `StartIndex 不能小于 0` —— MatchEvaluator 收到的 Match 里
            # `Group.Index` 的基准与当时假设不一致（匹配不在串首时变负数）。
            # 按值替换没这个问题，且**天然幂等**：值本来就对时不产生变化。
            #
            # ⚠ 这里必须用 PowerShell 的 `#` 注释：整个 scriptblock 是 **PowerShell 上下文**，
            #   写 C 风格 `/* */` 会被当命令执行（实测报 "无法将 /* 项识别为 cmdlet"）。
            $out = $mm.Value
            if ($mm.Groups['ac'].Success) {
                # 公告域的行写作 `AC-NOTICE-1…AC-NOTICE-N`，按值替换时要连前缀一起换，
                # 否则 `AC-3` 在 `AC-NOTICE-3` 里根本匹配不到（-Fix 会静默不修）。
                if ($mm.Value -match 'NOTICE-') {
                    $out = $out.Replace("AC-NOTICE-" + $mm.Groups['ac'].Value, "AC-NOTICE-" + "$acNoticeMax")
                } else {
                    $out = $out.Replace("AC-" + $mm.Groups['ac'].Value, "AC-" + "$acMax")
                }
            }
            # 端点数（ep 组）也要能 -Fix
            if ($mm.Groups['ep'].Success) {
                $out = $out.Replace($mm.Groups['ep'].Value, "$epCount")
            }
            if ($mm.Groups['n'].Success) {
                $out = $out.Replace($mm.Groups['n'].Value, "$want")
            }
            return $out
        })
        if ($new -ne $text) {
            [System.IO.File]::WriteAllText($path, $new, [System.Text.UTF8Encoding]::new($false))
            Write-Host "  ✅ 已改 $($c.File)（$($c.Want) -> $want）"
        }
    }
    Write-Host "`n请重跑本脚本确认全 OK。"
    exit 0
}

Write-Host "❌ 有 $bad 处漂移。加 -Fix 自动改写，或手工修正。"
exit 1