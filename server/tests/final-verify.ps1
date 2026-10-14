# 收官全量验证（2026-10-14，SERVER-REVIEW 修复后）
#
# 目的：一次跑完**所有** HTTP 层门禁脚本 + 三种部署形态的 health-check，
#       并给出统一的 EXIT 汇总表（供修复文档引用）。
#
# 为何要三个实例：
#   · 18092 --dev-auth（回环）—— 业务脚本都跑在开发态
#   · 18095 无 --dev-auth     —— auth-check 第 2 节断言“未开 --dev-auth 时 X-Role 被忽略”
#   · 18096 --prod            —— health-check -Mode prod 断言 dev_auth=false
#
# ⚠ 端口必须 ≥ 15001：本机 1024-15000 是 Windows 动态端口范围，显式 bind 会 WSAEACCES(10013)。
# ⚠ 含中文必须 UTF-8 with BOM（PS 5.1）。
# ⚠ 原生命令写 stderr + `2>&1` 在 EAP=Stop 下会抛 NativeCommandError ⇒ 读 create-admin 口令时局部放宽。

$ErrorActionPreference = 'Stop'
$server = 'E:\harmonyOS\智能医院客户端\server'
$exe = "$server\build\hospital-server.exe"
$dsn = 'mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital_test'
$log = "$env:TEMP\final-verify.log"
Remove-Item $log -ErrorAction SilentlyContinue

function Log([string]$s) { $s | Add-Content $log; $s | Write-Host }

function Start-Inst([int]$port, [string[]]$extra) {
    $args = @('serve', $dsn, '--port', "$port") + $extra
    $p = Start-Process -FilePath $exe -ArgumentList $args `
        -RedirectStandardOutput "$env:TEMP\srv$port.out" -RedirectStandardError "$env:TEMP\srv$port.err" `
        -PassThru -WindowStyle Hidden
    $ok = $false
    foreach ($i in 1..40) {
        Start-Sleep -Milliseconds 500
        try {
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:$port/health" -UseBasicParsing -TimeoutSec 2
            if ($r.StatusCode -eq 200) { $ok = $true; break }
        } catch { }
    }
    if (-not $ok) { Log "[FATAL] 实例 $port 起不来（见 %TEMP%\srv$port.err）"; return $null }
    Log "[ok] 实例 $port 已就绪（pid=$($p.Id)）"
    return $p
}

$instances = @()
try {
    $instances += Start-Inst 18092 @('--dev-auth')
    $instances += Start-Inst 18095 @()
    $instances += Start-Inst 18096 @('--prod')

    # ── 管理员口令：现场生成（并交给 p1-extra-check 用；它会把它还原）──
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $ca = (& $exe create-admin $dsn 2>&1 | Out-String)
    $ErrorActionPreference = $prevEap
    $m = [regex]::Matches($ca, '口\s*令：\s*([A-Za-z0-9]+)')
    if ($m.Count -lt 1) { throw "拿不到 create-admin 生成的口令" }
    $pw = $m[0].Groups[1].Value
    Set-Content -Path "$env:TEMP\adminpw.txt" -Value $pw -Encoding Ascii -NoNewline
    Log "[ok] 管理员口令已生成（写入 %TEMP%\adminpw.txt）"

    $dev = 'http://127.0.0.1:18092'
    $bare = 'http://127.0.0.1:18095'
    $prod = 'http://127.0.0.1:18096'

    $specs = @(
        @{ n = 'health-check'; p = @{ Base = $dev; Mode = 'dev' } },
        @{ n = 'health-check'; p = @{ Base = $prod; Mode = 'prod' } },
        @{ n = 'base-check'; p = @{ Base = $dev; AdminPw = $pw } },
        @{ n = 'auth-check'; p = @{ Base = $bare; AdminPw = $pw } },
        @{ n = 'kb-check'; p = @{ Base = $dev; AdminPw = $pw } },
        @{ n = 'triage-check'; p = @{ Base = $dev; AdminPw = $pw } },
        @{ n = 'emr-check'; p = @{ Base = $dev; AdminPw = $pw } },
        @{ n = 'previsit-check'; p = @{ Base = $dev; AdminPw = $pw } },
        @{ n = 'ai-model-check'; p = @{ Base = $dev; AdminPw = $pw } },
        @{ n = 'rate-limit-check'; p = @{ Base = $dev; AdminPw = $pw } },
        @{ n = 'p1-extra-check'; p = @{ Base = $dev; AdminPw = $pw } }
    )

    $results = @()
    foreach ($s in $specs) {
        $label = "$($s.n)$(if ($s.p.Mode) { " -Mode $($s.p.Mode)" } elseif ($s.p.Base -ne $dev) { " @$($s.p.Base)" })"
        Log "===== $label ====="
        $code = -99
        try {
            # ⚠ 不能写 `& $script @($s.p)`：那会把**哈希表当位置参数**传（PS 报
            #   "无法处理对参数 Base 的参数转换"），必须先把哈希表取到普通变量再 `@params` 展开。
            $params = $s.p
            $o = & "$server\tests\$($s.n).ps1" @params *>&1 | Out-String
            $code = $LASTEXITCODE
            $o | Add-Content $log
        } catch {
            Log "RUNNER-CAUGHT: $($_.Exception.Message)"
            $code = -1
        }
        Log "EXIT=$code"
        $results += [pscustomobject]@{ Script = $label; Exit = $code }
    }

    Log "--- 汇总 ---"
    foreach ($r in $results) { Log ("{0,-32} EXIT={1}" -f $r.Script, $r.Exit) }
    $bad = @($results | Where-Object { $_.Exit -ne 0 })
    if ($bad.Count -eq 0) { Log "✅ 全量 live 门禁通过（$($results.Count) 项）"; exit 0 }
    Log "❌ 有 $($bad.Count) 项未通过"
    exit 1
} finally {
    foreach ($p in $instances) { if ($p) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }
    Log "[ok] 已停止全部临时实例"
}
