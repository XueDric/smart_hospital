# SPDX-License-Identifier: MIT
#
# ===== contract-check.ps1 —— 接口契约门禁（改进 5，服务端侧）=====
#
# 两件事，缺一不可：
#   [1] **逐字节**比对：重新导出契约样例，与 contract/examples 里已提交的样例比。
#       不一致 ⇒ 失败。这拦的是"代码改了、文档/样例没改"（也拦"样例被手工美化"）。
#   [2] **Schema 校验**：用 contract/schema/*.json 校验样例的形状，
#       并断言每个样例的分类（成功信封 / 错误信封 / 业务码）与 schema-map.json 的登记一致。
#       这拦的是"形状对了但分类错了"（例如某个 404 悄悄从业务信封变成平铺错误）。
#
# 用法：
#   .\contract-check.ps1 -Base http://127.0.0.1:18092 -AdminPw <口令>
#   .\contract-check.ps1 -Base ... -AdminPw ... -SkipExport   # 只跑 Schema 校验（不碰服务器）
#
# ⚠ 与 export-contract.ps1 同一纪律：**不要与 `hospital-server.exe accept` 并发跑**。
# ⚠ 含中文的 PowerShell 脚本必须 **UTF-8 with BOM**（PS 5.1 否则按 ANSI 解析 → 语法报错）。
# ⚠ 为什么导出机要**另起进程**跑：export-contract.ps1 里用 `exit` 表达结果，
#   而同进程 `&` 调用的 `exit` 会连调用者一起结束 —— 必须 Start-Process。

[CmdletBinding()]
param(
    [string]$Base = "http://127.0.0.1:18092",
    [Parameter(Mandatory=$true)][string]$AdminPw,
    [string]$Dsn = "mysql://hospital:hospital_dev_2026@127.0.0.1:3317/hospital_test",
    [switch]$SkipExport
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")
. (Join-Path $PSScriptRoot "json-schema-lite.ps1")

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$examplesDir = Join-Path $repoRoot "contract\examples"
$schemaDir = Join-Path $repoRoot "contract\schema"
$mapPath = Join-Path $repoRoot "contract\schema-map.json"

# 读样例里的子节点：对象/字典都能用，缺字段返回 $null（不抛）。
# ⚠ 不返回 @() 而返回 $null：调用方用 Get-PropNames 拿"干净的名字列表"。
function Get-PropSafe($obj, [string]$name) {
    if ($null -eq $obj) { return $null }
    if ($obj -is [System.Collections.IDictionary]) {
        if ($obj.Contains($name)) { return $obj[$name] }
        return $null
    }
    $hit = @($obj.PSObject.Properties | Where-Object { $_.Name -eq $name })
    if ($hit.Count -eq 0) { return $null }
    $v = $hit[0].Value
    # ⚠ PowerShell 的隐式展开：函数返回数组会被枚举 —— 空数组变 $null、单元素数组
    #   变成那个元素。样例里 items/sections 常常只有一个元素（甚至为空），
    #   不包一层就会把"数组"误判成"对象"或"缺字段"。
    if ($v -is [System.Array]) { return ,$v }
    return $v
}

# 取一个"字符串名字列表"字段（缺字段 / 空串 / 单个字符串 / 数组 都能吃掉）。
function Get-PropNames($obj, [string]$name) {
    $v = Get-PropSafe $obj $name
    if ($null -eq $v) { return @() }
    return @($v | Where-Object { $null -ne $_ -and ([string]$_).Length -gt 0 } | ForEach-Object { [string]$_ })
}

$script:Passed = 0
$script:Failed = 0
function Check([string]$name, [bool]$cond, [string]$detail = "") {
    if ($cond) { $script:Passed++; Write-Host ("  [PASS] " + $name) -ForegroundColor DarkGray }
    else {
        $script:Failed++
        Write-Host ("  [FAIL] " + $name + $(if ($detail) { "  -- $detail" } else { "" })) -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "=== 接口契约门禁（改进 5）===" -ForegroundColor Cyan
Write-Host "  样例: $examplesDir"
Write-Host "  Schema: $schemaDir"
Write-Host ""

# ── [1] 逐字节比对 ──────────────────────────────────────────────────────────
if ($SkipExport) {
    Write-Host "[1] 逐字节比对：已跳过（-SkipExport）" -ForegroundColor Yellow
} else {
    Write-Host "[1] 逐字节比对（重新导出并与已提交样例比对）"
    $exporter = Join-Path $PSScriptRoot "export-contract.ps1"
    $outFile = Join-Path $env:TEMP "contract-export.out"
    $errFile = Join-Path $env:TEMP "contract-export.err"
    $psExe = (Get-Process -Id $PID).Path
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $exporter,
                '-Base', $Base, '-AdminPw', $AdminPw, '-Dsn', $Dsn, '-Check')
    $proc = Start-Process -FilePath $psExe -ArgumentList $psArgs -Wait -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $out = ""
    if (Test-Path $outFile) { $out = [System.IO.File]::ReadAllText($outFile) }
    foreach ($line in ($out -split "`r?`n")) {
        if ($line -match '\[(DIFF|缺失|多余)\]|比对完成|已提交:|实测\s*:') { Write-Host "  $line" -ForegroundColor DarkGray }
    }
    if ($proc.ExitCode -ne 0) {
        $err = ""
        if (Test-Path $errFile) { $err = [System.IO.File]::ReadAllText($errFile) }
        Write-Host "  导出机 EXIT=$($proc.ExitCode)" -ForegroundColor Red
        if ($err.Trim().Length -gt 0) { Write-Host "  导出机 stderr: $($err.Trim())" -ForegroundColor Red }
    }
    Check "样例与实测逐字节一致（导出机 -Check）" ($proc.ExitCode -eq 0) "导出机 EXIT=$($proc.ExitCode)"
}

# ── [2] Schema 校验 ────────────────────────────────────────────────────────
Write-Host ""
Write-Host "[2] Schema 校验与登记完整性"
$map = [System.IO.File]::ReadAllText($mapPath) | ConvertFrom-Json
$schemas = @{}
foreach ($f in Get-ChildItem $schemaDir -Filter '*.schema.json' -File) {
    $name = $f.Name -replace '\.schema\.json$', ''
    $schemas[$name] = [System.IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json
}
Write-Host ("  载入 Schema {0} 个" -f $schemas.Count)

$files = @(Get-ChildItem $examplesDir -Filter '*.json' -File | Sort-Object Name)
$used = @{}
$entries = @($map.map.PSObject.Properties)

# 登记完整性：样例 ↔ 登记 双向都要对上（新端点不能偷偷绕过契约）
foreach ($e in $entries) {
    if (-not ($files.Name -contains ($e.Name + '.json'))) {
        Check "登记表里的 '$($e.Name)' 有对应样例文件" $false "contract/examples/$($e.Name).json 不存在"
    }
}
foreach ($f in $files) {
    $nm = $f.Name -replace '\.json$', ''
    $hit = @($entries | Where-Object { $_.Name -eq $nm })
    if ($hit.Count -eq 0) { Check "样例 '$nm' 已在 schema-map.json 登记" $false "新样例必须登记，否则它会绕过契约门禁" }
}
foreach ($g in @($map.file)) {
    $used[[string]$g] = $true
    if (-not $schemas.ContainsKey([string]$g)) { Check "顶层 file Schema '$g' 存在" $false "contract/schema/$g.schema.json 缺失" }
}
foreach ($e in $entries) {
    foreach ($target in @('body', 'data', 'body_text')) {
        foreach ($s in (Get-PropNames $e.Value $target)) {
            $used[$s] = $true
            if (-not $schemas.ContainsKey($s)) { Check "Schema '$s'（$($e.Name).$target）存在" $false "contract/schema/$s.schema.json 缺失" }
        }
    }
}
foreach ($k in $schemas.Keys) {
    if (-not $used.ContainsKey($k)) { Check "Schema '$k' 被引用" $false "没有任何样例用它 —— 孤儿 Schema 会让契约看起来比实际更全" }
}

# 逐样例校验
$bad = 0
foreach ($f in $files) {
    $nm = $f.Name -replace '\.json$', ''
    $doc = [System.IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json
    $errs = New-Object System.Collections.ArrayList

    foreach ($g in @($map.file)) {
        foreach ($x in @(Test-JsonSchemaLite -Node $doc -Schema $schemas[[string]$g] -Path '$')) { $null = $errs.Add("[$g] $x") }
    }
    $entry = @($entries | Where-Object { $_.Name -eq $nm })
    if ($entry.Count -eq 1) {
        $ev = $entry[0].Value
        $bodyNode = Get-PropSafe $doc.response 'body'
        # 三个可选靶位：body（整个响应体）/ data（信封里的 data）/ body_text（SSE 等非 JSON 主体）
        $targetNode = @{
            'body'      = $bodyNode
            'data'      = (Get-PropSafe $bodyNode 'data')
            'body_text' = (Get-PropSafe $doc.response 'body_text')
        }
        foreach ($target in @('body', 'data', 'body_text')) {
            foreach ($s in (Get-PropNames $ev $target)) {
                if (-not $schemas.ContainsKey($s)) { continue }
                foreach ($x in @(Test-JsonSchemaLite -Node $targetNode[$target] -Schema $schemas[$s] -Path $target)) { $null = $errs.Add("[$s] $x") }
            }
        }
        # 业务码断言：错误样例必须带**预期**的那个 code（不是"随便一个 4xx"）
        $wantCode = Get-PropSafe $ev 'error_code'
        if ($null -ne $wantCode -and ([string]$wantCode).Length -gt 0) {
            $errNode = Get-PropSafe $bodyNode 'error'
            $gotCode = [string](Get-PropSafe $errNode 'code')
            if ($gotCode -ne [string]$wantCode) { $null = $errs.Add("[error_code] 期望 $wantCode，实际 '$gotCode'") }
        }
    }

    if ($errs.Count -eq 0) { $script:Passed++ }
    else {
        $bad++
        $script:Failed++
        Write-Host "  [FAIL] $nm" -ForegroundColor Red
        foreach ($x in $errs) { Write-Host "         $x" -ForegroundColor Red }
    }
}

$regCount = @($entries).Count
Check "样例条数 = 登记条数（$($files.Count)）" ($files.Count -eq $regCount) "样例 $($files.Count) / 登记 $regCount"

Write-Host ""
Write-Host ("Schema 校验：通过 {0} / 失败 {1}（样例 {2} 条，Schema {3} 个）" -f ($files.Count - $bad), $bad, $files.Count, $schemas.Count) -ForegroundColor Cyan
Write-Host ("契约门禁汇总：PASS {0} / FAIL {1}" -f $script:Passed, $script:Failed) -ForegroundColor Cyan
if ($script:Failed -gt 0) {
    Write-Host "❌ 契约门禁未通过" -ForegroundColor Red
    exit 1
}
Write-Host "✅ 契约门禁通过（样例与实测一致、Schema 与登记齐全、业务码相符）" -ForegroundColor Green
exit 0
