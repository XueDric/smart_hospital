# SPDX-License-Identifier: MIT
#
# ===== json-schema-lite.ps1 —— 极小 JSON Schema 子集校验器（改进 5 用）=====
#
# 为什么要自己写：
#   门禁要能在 **Windows PowerShell 5.1**（没有 `Test-Json`，也没有内置的 JSON Schema 库）
#   和 PS 7 上给出**一样**的结论；引第三方模块又要谈离线可跑、版本锁。
#   于是只实现"契约样例真正用得到"的关键字。
#
# ⚠ 本校验器的诚实之处（也是纪律）：
#   **遇到不认识的关键字直接 throw**，绝不静默跳过。
#   静默跳过 = 让人以为"这个约束被检查了"，而那正是契约门禁最坏的失效方式。
#   想让某个关键字生效？先在这里实现它，再写进 contract/README.md 的支持清单。
#
# 支持：
#   type（字符串或字符串数组）/ required / properties / additionalProperties:false /
#   items（单个 schema，作用于所有元素）/ enum / const /
#   minimum / maximum / minLength / maxLength
# 不支持（出现即报错）：pattern / oneOf / anyOf / allOf / not / $ref / format / …
#
# 一个特殊约定：节点值恰为字符串 "<volatile>" 时**跳过任何校验**。
#   这是导出机的 volatile 占位（成员集合依赖全院数据的端点，比如管理员用户列表），
#   见 contract/README.md 的「volatile」一节。

$script:JsonSchemaSupported = @(
    'type', 'required', 'properties', 'additionalProperties', 'items',
    'enum', 'const', 'minimum', 'maximum', 'minLength', 'maxLength', 'pattern',
    'title', 'description'
)

function Get-SchemaKeys($Schema) {
    if ($null -eq $Schema) { return @() }
    if ($Schema -is [System.Collections.IDictionary]) { return @($Schema.Keys | ForEach-Object { [string]$_ }) }
    return @($Schema.PSObject.Properties | ForEach-Object { $_.Name })
}

function Get-SchemaValue($Schema, [string]$Name) {
    if ($Schema -is [System.Collections.IDictionary]) { return $Schema[$Name] }
    return $Schema.$Name
}

function Get-HasKey($Node, [string]$Name) {
    if ($null -eq $Node) { return $false }
    if ($Node -is [System.Collections.IDictionary]) { return $Node.Contains($Name) }
    return (@($Node.PSObject.Properties | Where-Object { $_.Name -eq $Name }).Count -gt 0)
}

function Get-KeyValue($Node, [string]$Name) {
    # ⚠ PowerShell 的隐式展开：函数「返回」数组时会把它枚举掉 ——
    #   空数组变成 $null、单元素数组变成那个元素。校验器会因此把
    #   「空的 items」当成「字段缺失」、把「只有一个元素的 items」当成「对象」。
    #   逗号运算符 `,$v` 把值包一层单元素数组，从而保住内层数组（含空数组）。
    $v = $null
    if ($Node -is [System.Collections.IDictionary]) { $v = $Node[$Name] } else { $v = $Node.$Name }
    if ($v -is [System.Array]) { return ,$v }
    return $v
}

function Get-JsonTypeName($v) {
    if ($null -eq $v) { return 'null' }
    if ($v -is [bool]) { return 'boolean' }
    if ($v -is [int] -or $v -is [int64] -or $v -is [int16] -or $v -is [byte]) { return 'integer' }
    if ($v -is [double] -or $v -is [single] -or $v -is [decimal]) { return 'number' }
    if ($v -is [string]) { return 'string' }
    if ($v -is [System.Array]) { return 'array' }
    return 'object'
}

function Test-TypeMatch($Node, [string]$Want) {
    $t = Get-JsonTypeName $Node
    if ($Want -eq 'number') { return ($t -eq 'number' -or $t -eq 'integer') }
    if ($Want -eq 'integer') { return ($t -eq 'integer') }
    return ($t -eq $Want)
}

# enum/const 的比较必须**带类型**：PowerShell 会把 "1" 和 1 判等、把 "true" 和 $true 判等，
# 直接用 -eq 会让契约悄悄放过类型错误（正是这种"看起来过了"最危险）。
function Test-StrictEqual($Node, $Want) {
    $tn = Get-JsonTypeName $Node
    $tw = Get-JsonTypeName $Want
    if ($tw -eq 'number' -and $tn -eq 'integer') { return ([double]$Node -eq [double]$Want) }
    if ($tw -ne $tn) { return $false }
    return ($Node -eq $Want)
}

function Format-SchemaScalar($v) {
    if ($null -eq $v) { return 'null' }
    if ($v -is [bool]) { if ($v) { return 'true' } else { return 'false' } }
    if ($v -is [string]) { return ('"' + $v + '"') }
    return ([string]$v)
}

function Invoke-SchemaCheck {
    param($Node, $Schema, [string]$Path, $Errs)

    if ($null -eq $Schema) { return }
    if ($Node -is [string] -and $Node -eq '<volatile>') { return }

    foreach ($k in (Get-SchemaKeys $Schema)) {
        if ($script:JsonSchemaSupported -notcontains $k) {
            throw "json-schema-lite 不支持关键字 '$k'（在 $Path）：请改用支持的关键字，或在 server/tests/json-schema-lite.ps1 里真正实现它 —— 不能让约束静默失效。"
        }
    }

    # ── type ──
    $wantType = Get-SchemaValue $Schema 'type'
    if ($null -ne $wantType -and -not ($wantType -is [string] -and [string]::IsNullOrEmpty($wantType))) {
        $wants = @($wantType)
        $ok = $false
        foreach ($w in $wants) { if (Test-TypeMatch $Node ([string]$w)) { $ok = $true } }
        if (-not $ok) {
            $null = $Errs.Add(("{0}: 类型应为 {1}，实际是 {2}" -f $Path, ($wants -join '|'), (Get-JsonTypeName $Node)))
            return   # 类型都不对，后面的约束只会刷屏
        }
    }

    # ── enum / const ──
    $enumVals = Get-SchemaValue $Schema 'enum'
    if ($null -ne $enumVals) {
        $hit = $false
        foreach ($e in @($enumVals)) { if (Test-StrictEqual $Node $e) { $hit = $true } }
        if (-not $hit) { $null = $Errs.Add(("{0}: 值不在 enum 里（允许 {1}）" -f $Path, (@($enumVals) -join '|'))) }
    }
    $constVal = Get-SchemaValue $Schema 'const'
    if ($null -ne $constVal) {
        if (-not (Test-StrictEqual $Node $constVal)) {
            $null = $Errs.Add(("{0}: 值应为 const {1}" -f $Path, (Format-SchemaScalar $constVal)))
        }
    }

    $tn = Get-JsonTypeName $Node

    # ── 数值 / 字符串长度 ──
    if ($tn -eq 'integer' -or $tn -eq 'number') {
        $min = Get-SchemaValue $Schema 'minimum'
        if ($null -ne $min -and [double]$Node -lt [double]$min) { $null = $Errs.Add(("{0}: 应 ≥ {1}（实际 {2}）" -f $Path, $min, $Node)) }
        $max = Get-SchemaValue $Schema 'maximum'
        if ($null -ne $max -and [double]$Node -gt [double]$max) { $null = $Errs.Add(("{0}: 应 ≤ {1}（实际 {2}）" -f $Path, $max, $Node)) }
    }
    if ($tn -eq 'string') {
        $minL = Get-SchemaValue $Schema 'minLength'
        if ($null -ne $minL -and ([string]$Node).Length -lt [int]$minL) { $null = $Errs.Add(("{0}: 长度应 ≥ {1}（实际 {2}）" -f $Path, $minL, ([string]$Node).Length)) }
        $maxL = Get-SchemaValue $Schema 'maxLength'
        if ($null -ne $maxL -and ([string]$Node).Length -gt [int]$maxL) { $null = $Errs.Add(("{0}: 长度应 ≤ {1}（实际 {2}）" -f $Path, $maxL, ([string]$Node).Length)) }
        # pattern：.NET 正则（大小写敏感，和 JS 的 /…/ 一致；需要忽略大小写就在正则里写 (?i)）。
        # ⚠ 正则写错必须**报错**而不是当成"匹配失败"——否则约束悄悄失效，正是契约门禁最坏的失效方式。
        $pat = Get-SchemaValue $Schema 'pattern'
        if ($null -ne $pat -and ([string]$pat).Length -gt 0) {
            $re = $null
            try { $re = New-Object System.Text.RegularExpressions.Regex([string]$pat, [System.Text.RegularExpressions.RegexOptions]::None, [TimeSpan]::FromSeconds(2)) }
            catch { throw ("Schema 里的 pattern 不是合法正则（在 {0}）：{1} —— {2}" -f $Path, $pat, $_.Exception.Message) }
            if (-not $re.IsMatch([string]$Node)) { $null = $Errs.Add(("{0}: 不匹配 pattern /{1}/" -f $Path, $pat)) }
        }
    }

    # ── 对象 ──
    if ($tn -eq 'object') {
        $required = Get-SchemaValue $Schema 'required'
        if ($null -ne $required) {
            foreach ($r in @($required)) {
                if (-not (Get-HasKey $Node ([string]$r))) { $null = $Errs.Add(("{0}: 缺必填字段 '{1}'" -f $Path, $r)) }
            }
        }
        $props = Get-SchemaValue $Schema 'properties'
        $addl = Get-SchemaValue $Schema 'additionalProperties'
        foreach ($k in (Get-SchemaKeys $Node)) {
            $subSchema = $null
            if ($null -ne $props -and (Get-HasKey $props $k)) { $subSchema = Get-KeyValue $props $k }
            if ($null -ne $subSchema) {
                Invoke-SchemaCheck -Node (Get-KeyValue $Node $k) -Schema $subSchema -Path ("$Path.$k") -Errs $Errs
            } elseif ($addl -is [bool] -and -not $addl) {
                $null = $Errs.Add(("{0}: 多出未声明的字段 '{1}'（契约是精确形状；真要加字段就得重新导出样例并更新 Schema）" -f $Path, $k))
            }
        }
    }

    # ── 数组 ──
    if ($tn -eq 'array') {
        $items = Get-SchemaValue $Schema 'items'
        if ($null -ne $items) {
            $i = 0
            foreach ($x in @($Node)) {
                Invoke-SchemaCheck -Node $x -Schema $items -Path ("$Path[$i]") -Errs $Errs
                $i++
            }
        }
    }
}

# 校验一个节点；返回错误字符串数组（空数组 = 通过）。
function Test-JsonSchemaLite {
    param($Node, $Schema, [string]$Path = '$')
    $errs = New-Object System.Collections.ArrayList
    Invoke-SchemaCheck -Node $Node -Schema $Schema -Path $Path -Errs $errs
    return $errs.ToArray()
}
