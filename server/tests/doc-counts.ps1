# 文档数字校验：把文档里写的测试项数与**实测值**对账
#
# ── 为什么要有这个脚本（2026-10-07 加）────────────────────────────────────
# "文档里的测试项数"这一类数字，本项目已经**漂移过两次**：
#   第一次：selftest 写 32、实际 33（加断言后没回头改）
#   第二次：删了 AC-8 后，P1-HANDOFF / ADR / server/README 仍写 33 / 35（实际 30 / 43）
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
    return ([regex]::Matches(($out -join "`n"), '\[PASS\]')).Count
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
$triPass = ([regex]::Matches($triOut, '\[PASS\]')).Count
$triFail = ([regex]::Matches($triOut, '\[FAIL\]')).Count
if ($triFail -gt 0) { Write-Warning "  triagetest 有 $triFail 项失败（对账仍继续，但请先修）" }
$actual['triagetest'] = $triPass
# accept 用例的最大编号（AC-1…AC-N 里的 N）——由源码里 runner.acN() 的调用推导
$accSrc = [System.IO.File]::ReadAllText((Join-Path $serverDir "src\acceptance.cj"), [System.Text.UTF8Encoding]::new($false))
# ★ AC 编号上限：既数 `runner.acN()`（AC-1…AC-12），也认 P2 的用例（AC-P2-N）。
#   P2 的用例是**独立函数**（`acP2_N(runner, db)`），不是 runner 的成员，
#   所以正则要同时覆盖两种调用形态 —— 否则"上限"会停留在 AC-12，
#   而文档写 AC-P2-4 就会被误报成漂移（反之更糟：新用例加了没人发现）。
$acNums = [regex]::Matches($accSrc, 'runner\.ac(\d+)\(\)') | ForEach-Object { [int]$_.Groups[1].Value }
$acP2Nums = [regex]::Matches($accSrc, '\bacP2_(\d+)\(') | ForEach-Object { [int]$_.Groups[1].Value }
$acMax = ($acNums | Measure-Object -Maximum).Maximum
$acP2Max = 0
if ($acP2Nums.Count -gt 0) { $acP2Max = ($acP2Nums | Measure-Object -Maximum).Maximum }
# 展示用：有 P2 用例时上限写作 "AC-P2-<n>"
$acMaxLabel = "AC-$acMax"
if ($acP2Max -gt 0) { $acMaxLabel = "AC-P2-$acP2Max" }
# ★ 对账用"**单一可比数字**"：AC-N 记 N，AC-P2-N 记 N（两套编号各自独立计数，
#   所以文档里 `AC-1…AC-P2-4` 与 `AC-1…AC-12` 表达的是**同一个上限概念**）。
#   正则接受两种写法，取到的数字都应等于对应体系的最大 N。
foreach ($k in $actual.Keys) { Write-Host ("  {0,-9} = {1}" -f $k, $actual[$k]) }
Write-Host "  AC 编号上限（两套体系各自）= AC-$acMax 与 AC-P2-$acP2Max"

# ★ REST 端点数（从 http_app.cj 数出来）—— 这个数字最容易漂：
#   每加一个端点都得回头改 README，而"加了但忘了改文档"正是本项目漂过两次的病。
$appSrc = [System.IO.File]::ReadAllText((Join-Path $serverDir "src\http_app.cj"), [System.Text.UTF8Encoding]::new($false))
$epCount = ([regex]::Matches($appSrc, 'r\.(get|post|put|del)\("/api/')).Count
Write-Host "  REST 端点数 = $epCount"




# ── 2) 文档里"应该"写的值（想加新位置就往这里加一行）───────────────────
#    每项：文件、匹配的正则（含一个捕获组）、期望值来源
$checks = @(
    @{ File = "server\README.md";     Pattern = '\| `selftest` \|[^\r\n]*自检（\*\*?(?<n>\d+) 项'; Want = 'selftest' },
    @{ File = "server\README.md";     Pattern = '`accept <dsn>` \| 验收测试 AC-1…AC-(?:P2-)?(?<ac>\d+)（\*\*(?<n>\d+) 项断言\*\*'; Want = 'accept' },
    @{ File = "server\README.md";     Pattern = '`src/acceptance\.cj` \| AC-1…AC-(?:P2-)?(?<ac>\d+) 验收测试'; Want = 'accept' },
    @{ File = "docs\P1-HANDOFF.md";   Pattern = 'schema 自检（无需库） \| `hospital-server\.exe selftest` \| ✅ \*\*(?<n>\d+) 项\*\*'; Want = 'selftest' },
    @{ File = "README.md";            Pattern = '\*\*(?<ep>\d+) 个 REST\*\*'; Want = 'endpoints' },
    @{ File = "server\README.md";     Pattern = '`triagetest` \| P2 分诊.*?自检（\*\*\s*(?<n>\d+) 项\*\*'; Want = 'triagetest' },
    @{ File = "docs\P1-HANDOFF.md";   Pattern = '验收（AC-1…AC-(?:P2-)?(?<ac>\d+)） \| `hospital-server\.exe accept <dsn>` \| ✅ \*\*(?<n>\d+) 项\*\*'; Want = 'accept' },
    @{ File = "docs\adr\ADR-0001-号源与挂号独立MySQL路径.md"; Pattern = '`hospital-server\.exe selftest` \| ✅ \*\*(?<n>\d+) 项\*\*'; Want = 'selftest' },
    @{ File = "docs\adr\ADR-0001-号源与挂号独立MySQL路径.md"; Pattern = '`hospital-server\.exe accept <dsn>` \| ✅ \*\*(?<n>\d+) 项 / 失败 0\*\*'; Want = 'accept' }
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
    $want = if ($c.Want -eq "endpoints") { $epCount } else { $actual[$c.Want] }
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
        $isP2Label = $m.Value -match 'P2-'
        $wantAc = if ($isP2Label) { $acP2Max } else { $acMax }
        if ($gotAc -eq $wantAc) {
            Write-Host "  [OK]   $($c.File) —— AC 编号上限 = AC-$gotAc（$(if ($isP2Label) { "P2 体系" } else { "主体系" })）"
        } else {
            Write-Host "  [DRIFT] $($c.File) —— 文档写 AC-$gotAc，实测上限 $acMaxLabel"
            $bad++
        }
    }
    if (-not $hasN) { continue }
    $got = [int]$m.Groups['n'].Value
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
        $want = if ($c.Want -eq "endpoints") { $epCount } else { $actual[$c.Want] }
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
                $out = $out.Replace("AC-" + $mm.Groups['ac'].Value, "AC-" + "$acMax")
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
