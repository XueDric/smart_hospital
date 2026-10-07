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
# accept 用例的最大编号（AC-1…AC-N 里的 N）——由源码里 runner.acN() 的调用推导
$accSrc = [System.IO.File]::ReadAllText((Join-Path $serverDir "src\acceptance.cj"), [System.Text.UTF8Encoding]::new($false))
$acMax = ([regex]::Matches($accSrc, 'runner\.ac(\d+)\(\)') | ForEach-Object { [int]$_.Groups[1].Value } | Measure-Object -Maximum).Maximum
foreach ($k in $actual.Keys) { Write-Host ("  {0,-9} = {1}" -f $k, $actual[$k]) }
Write-Host "  AC 编号上限 = AC-$acMax"

# ── 2) 文档里"应该"写的值（想加新位置就往这里加一行）───────────────────
#    每项：文件、匹配的正则（含一个捕获组）、期望值来源
$checks = @(
    @{ File = "server\README.md";     Pattern = '\| `selftest` \|[^\r\n]*自检（\*\*?(?<n>\d+) 项'; Want = 'selftest' },
    @{ File = "server\README.md";     Pattern = '`accept <dsn>` \| 验收测试 AC-1…AC-(?<ac>\d+)（\*\*(?<n>\d+) 项断言\*\*'; Want = 'accept' },
    @{ File = "server\README.md";     Pattern = '`src/acceptance\.cj` \| AC-1…AC-(?<ac>\d+) 验收测试'; Want = 'accept' },
    @{ File = "docs\P1-HANDOFF.md";   Pattern = 'schema 自检（无需库） \| `hospital-server\.exe selftest` \| ✅ \*\*(?<n>\d+) 项\*\*'; Want = 'selftest' },
    @{ File = "docs\P1-HANDOFF.md";   Pattern = '验收（AC-1…AC-(?<ac>\d+)） \| `hospital-server\.exe accept <dsn>` \| ✅ \*\*(?<n>\d+) 项\*\*'; Want = 'accept' },
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
    $want = $actual[$c.Want]
    # ★ 用具名组取数 —— 不再靠"捕获组顺序"（那东西一改正则就错，实测被坑过）
    #
    # 两种检查形态（用哪个看正则里有哪些具名组）：
    #   · 有 `n`  → 检查"项数"是否等于实测 PASS 数；
    #   · 只有 `ac` → 检查"AC 编号上限"是否等于源码里 runner.acN() 的最大 N。
    #     （这类检查没有"项数"可比，不能要求它必须有 n 组。）
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
        if ($gotAc -eq $acMax) {
            Write-Host "  [OK]   $($c.File) —— AC 编号上限 = AC-$gotAc"
        } else {
            Write-Host "  [DRIFT] $($c.File) —— 文档写 AC-$gotAc，实测上限 AC-$acMax"
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
        $want = $actual[$c.Want]
        $n = 0
        $new = [regex]::Replace($text, $c.Pattern, {
            param($mm)
            $script:n++
            # 把具名组 n（项数）换成实测值；顺带把 AC 编号也推到实际最大值
            $g = $mm.Groups['n']
            $out = $mm.Value.Remove($g.Index - $mm.Index, $g.Length).Insert($g.Index - $mm.Index, "$want")
            if ($mm.Groups['ac'].Success) {
                $ga = $mm.Groups['ac']
                # 注意：上面的 Remove/Insert 改了长度，ac 组在 n 组**之前**，索引不受影响
                $out = $out.Remove($ga.Index - $mm.Index, $ga.Length).Insert($ga.Index - $mm.Index, "$acMax")
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
