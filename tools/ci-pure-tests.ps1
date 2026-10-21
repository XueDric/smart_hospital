<#
  在 CI 里跑「不需要数据库」的三层纯逻辑测试（评估报告 P1-3）。

  ## 为什么单独一个脚本

  `selftest` / `authtest` / `triagetest` 这三个子命令**不碰 MySQL**：
  口令与令牌原语、状态机、分诊规则与红牌判定都是纯函数。
  它们是"任何人都能在 10 秒内自己跑一遍"的自证层 —— 而这正是评估报告说我们缺的东西：
  `accept` 需要 MariaDB（CI 上装不全），于是"801 条断言"只能靠我们自述。

  ## 为什么可能 SKIP 而不是 FAIL

  这三个子命令**编译在同一份二进制里**（`server/build/hospital-server.exe`），
  而 CI 的 windows-latest 上没有仓颉工具链（cjc 1.2.0 + stdx + 自编 MariaDB 驱动），
  现装一份约 1 GB 且需要联网拉 SDK —— 那种"装不全就红"的 job 最后一定会被绕过。
  ⇒ 本脚本的契约是：
    · 找得到 exe（本地 / 自己上传的 artifact） ⇒ **真跑**，任一失败即非 0；
    · 找不到 exe ⇒ 打印 SKIP 并以 0 退出，**不伪装成通过**。

  ## 用法

    .\tools\ci-pure-tests.ps1                              # 用 server/build/hospital-server.exe
    .\tools\ci-pure-tests.ps1 -ExePath D:\x\hospital-server.exe

  退出码：0 = 全过或 SKIP；1 = 有测试失败。
#>
param(
    [string]$ExePath = "",
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"
function Say([string]$m) { if (-not $Quiet) { Write-Host $m } }

if (-not $ExePath) { $ExePath = Join-Path (Split-Path $PSScriptRoot -Parent) "server\build\hospital-server.exe" }

if (-not (Test-Path -LiteralPath $ExePath)) {
    Say ("SKIP：找不到 " + $ExePath)
    Say "      纯逻辑测试编译在该二进制里，CI 未装仓颉工具链时无法生成它。"
    Say "      本地自证：.\\server\\build.ps1 之后再跑本脚本。"
    exit 0
}

Say ("二进制：" + $ExePath)
$fail = 0
$cases = @(
    @{ Name = "selftest";     Cmd = "selftest" },
    @{ Name = "authtest";     Cmd = "authtest" },
    @{ Name = "triagetest";   Cmd = "triagetest" }
)
foreach ($c in $cases) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $out = & $ExePath $c.Cmd 2>&1
    $code = $LASTEXITCODE
    $sw.Stop()
    $tail = ($out | Select-Object -Last 1)
    if ($code -eq 0) {
        Say ("  [PASS] " + $c.Name.PadRight(11) + " " + $sw.ElapsedMilliseconds + " ms  — " + $tail)
    } else {
        $fail++
        Write-Host ("  [FAIL] " + $c.Name + "（退出码 " + $code + "）") -ForegroundColor Red
        $out | Select-Object -Last 15 | ForEach-Object { Write-Host ("      " + $_) }
    }
}

if ($fail -gt 0) { Write-Host ("❌ 纯逻辑测试有 " + $fail + " 项失败") -ForegroundColor Red; exit 1 }
Say "✅ 纯逻辑测试全部通过（不需要数据库）"
