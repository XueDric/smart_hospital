# init-name-check.ps1 —— `init-admin` 的**会长姓名**选项回归闸门（2026-09-17 新增）
#
# 为什么单列一个文件：这条功能的形状是被一个**硬约束**逼出来的 —— 中文命令行参数会让
# 仓颉在进 main 之前就崩（`IllegalArgumentException: Invalid unicode scalar value.`，
# 见 docs/API-NOTES.md 坑 11），所以中文姓名只能走 `--name-file <UTF-8 文件>`。
# 一个"绕开 argv"的输入通道值得有自己的一组闸门：文件带 BOM / 带结尾换行 / 空文件 /
# 只有 BOM / 文件不存在 / 两个选项同时给 / 不认识的参数 …
#
# ⚠⚠ 新前提（2026-09-20 起）：**必须有一台可连的 MySQL / MariaDB**。
#   本脚本会跑 `init-admin`，而它从这一天起写的是 **MySQL**（路线 B，见
#   docs\club-server-mysql-assessment.md），所以：
#     · 第二个位置参数是 **DSN**（不再是数据目录）；
#     · **每个用例一个专用测试库**（club_name_<用例>），绝不碰 club_rbac / club 等真实库；
#     · 开头检测客户端与可连性，取不到 → 中文提示 + **判 FAIL + 非零退出**（不静默跳过）；
#     · 「不能半途写库」这条断言改成**直查 information_schema**（原先看有没有 db.json）。
#   连接参数默认取本机便携版 MariaDB（127.0.0.1:3307 / root / clubroot123），
#   可用 CLUB_MYSQL_HOST/PORT/USER/PASS 覆盖；细节见 tests\mysql-common.ps1 的文件头。
#
# 隔离性：审计日志仍全部落在 build\init-name-check\ 下，跑完删掉；测试库也会被清掉。
# cwd 也切到那个临时目录，所以第 6 条（省掉 DSN、用默认库名 club_server）不会误建 build\data。
#
# 用法（在 server\ 下）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\init-name-check.ps1

$ErrorActionPreference = "Stop"

$here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$root  = Split-Path -Parent $here                 # server\
$build = Join-Path $root "build"
$exe   = Join-Path $build "club-server.exe"
if (-not (Test-Path $exe)) {
    Write-Host "找不到 $exe"
    Write-Host "先跑：.\build.ps1"
    exit 2
}

# 专用测试库 + 连接检测（取不到就 FAIL 退出）
. (Join-Path $here "mysql-common.ps1")
$my = Initialize-MySqlTestEnv -DefaultDb "club_name_default"
$dbHost = $my.Host; $dbPort = $my.Port; $dbUser = $my.User; $dbPass = $my.Pass

$work = Join-Path $build "init-name-check"
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Path $work -Force | Out-Null

$pass = 0; $fail = 0
function Check([string]$name, [bool]$cond, [string]$extra = "") {
    if ($cond) { Write-Host "  ok    $name"; $script:pass++ }
    else       { Write-Host "  FAIL  $name  $extra"; $script:fail++ }
}

# 每个用例一个库；DSN 用同一个账号口令，只换库名。
function DsnOf([string]$db) {
    return "mysql://${dbUser}:${dbPass}@${dbHost}:${dbPort}/$db"
}
# 用例库名（不碰真实库）
$dbDefault = "club_name_t_default"
$dbAscii   = "club_name_t_ascii"
$dbZh      = "club_name_t_zh"
$dbBom     = "club_name_t_bom"
$dbTrim    = "club_name_t_trim"
$dbErr     = "club_name_t_err"
# 注意：第 6 条故意**不给 DSN**，走默认库名 —— 那正是要验的行为
$dbImplicit = "club_server"

# ⚠ 库的清理**必须放在函数定义之后**（PowerShell 按顺序解释，先调用后定义会
#   报 "The term 'Reset-ClubMySqlSchema'/'DropDb' is not recognized" —— 本轮踩过）。

# 在 $work 下跑 exe（审计日志目录相对 cwd；exe 用绝对路径，DLL 挨着 exe 由系统加载）
function Run([string[]]$cmdArgs) {
    Push-Location $work
    try {
        $out = & $exe @cmdArgs 2>&1
        return @{ Code = $LASTEXITCODE; Out = ($out -join "`n") }
    } finally { Pop-Location }
}

# 首任会长的姓名：**直查 MySQL**（原先读 db.json —— 那个文件已经不再产生）
function NameOf([string]$db) {
    $n = (Invoke-ClubMySql "SELECT name FROM members WHERE role='president' LIMIT 1;" $db).Trim()
    if ($n.Length -eq 0) { return "<没有会长>" }
    return $n
}

# 这个库有没有被建出来（错误用法那条要断言"没半途建库"）
function DbExists([string]$db) {
    $c = (Invoke-ClubMySql "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='$db';" "").Trim()
    return ($c -eq '1')
}

# 删掉整个库（不只是表）—— 错误用例断言的是"库都没被建出来"，而
# Reset-ClubMySqlSchema 只 DROP 表、**库会留着**（那样 DbExists 恒为真，断言就假绿）。
function DropDb([string]$db) {
    $null = Invoke-ClubMySql "DROP DATABASE IF EXISTS $db;" ""
}

function WriteNameFile([string]$text, [string]$file, [bool]$bom, [string]$suffix = "") {
    [IO.File]::WriteAllText((Join-Path $work $file), $text + $suffix, [Text.UTF8Encoding]::new($bom))
}

# ---------- 夹具准备：把用到的库清成空库 ----------
# 表不存在 = 空库，init-admin 才有资格执行。
# ⚠ **不要**把 $dbImplicit（默认库 club_server）放进这个列表：它是**真实社团库**的名字，
#   Reset-ClubMySqlSchema 会把它的 9 张表全 DROP。第 6 条用例已改成非破坏性验证（见那里）。
foreach ($d in @($dbDefault, $dbAscii, $dbZh, $dbBom, $dbTrim)) {
    Reset-ClubMySqlSchema $d
}
# 错误用例那个库要**整个删掉**：下面要断言"连库都没建出来"
DropDb $dbErr

Write-Host "=== init-admin 会长姓名选项 ==="
Write-Host "  exe $exe"
Write-Host "  审计目录 build\init-name-check\（跑完删除）；数据在专用测试库 club_name_*"
Write-Host ""

# ---------- 1) 老行为：不给姓名选项 ----------
Write-Host "[1] 不给姓名选项 -> 默认「会长」"
$r = Run @('init-admin', '13700000001', 'TestPass2026', (DsnOf $dbDefault))
Check "退出码 0" ($r.Code -eq 0) "out=$($r.Out)"
Check "姓名默认是「会长」" ((NameOf $dbDefault) -eq '会长') "name=[$(NameOf $dbDefault)]"
Check "输出里带上了姓名" ($r.Out -match '已创建首任会长：会长') "out=$($r.Out)"
Check "注册口令那行没被破坏（ops-check 靠它取值）" ($r.Out -match '当前注册口令：[A-Z0-9]+') "out=$($r.Out)"

# ---------- 2) --name（仅 ASCII） ----------
Write-Host ""
Write-Host "[2] --name LiSi（ASCII 姓名直接给）"
$r = Run @('init-admin', '13700000002', 'TestPass2026', (DsnOf $dbAscii), '--name', 'LiSi')
Check "退出码 0" ($r.Code -eq 0) "out=$($r.Out)"
Check "姓名 = LiSi" ((NameOf $dbAscii) -eq 'LiSi') "name=[$(NameOf $dbAscii)]"

# ---------- 3) --name-file（中文走这条） ----------
Write-Host ""
Write-Host "[3] --name-file（中文姓名必须走这里）"
WriteNameFile '张三' 'n3.txt' $false
$r = Run @('init-admin', '13700000003', 'TestPass2026', (DsnOf $dbZh), '--name-file', 'n3.txt')
Check "退出码 0" ($r.Code -eq 0) "out=$($r.Out)"
Check "中文姓名完整写入（UTF-8 往返没坏）" ((NameOf $dbZh) -eq '张三') "name=[$(NameOf $dbZh)]"
Check "输出里的姓名也是中文（终端能看见）" ($r.Out -match '已创建首任会长：张三') "out=$($r.Out)"

# ---------- 4) 文件带 BOM ----------
Write-Host ""
Write-Host "[4] 姓名文件带 UTF-8 BOM（PowerShell Set-Content -Encoding UTF8 的产物）"
WriteNameFile '李四' 'n4.txt' $true
$r = Run @('init-admin', '13700000004', 'TestPass2026', (DsnOf $dbBom), '--name-file', 'n4.txt')
Check "退出码 0" ($r.Code -eq 0) "out=$($r.Out)"
Check "BOM 被剥掉（姓名前没有多余字符）" ((NameOf $dbBom) -eq '李四') "name=[$(NameOf $dbBom)]"

# ---------- 5) 首尾空白 / 结尾换行 ----------
Write-Host ""
Write-Host "[5] 姓名文件带首尾空格与结尾换行 -> 裁掉"
WriteNameFile '  王五  ' 'n5.txt' $false "`r`n"
$r = Run @('init-admin', '13700000005', 'TestPass2026', (DsnOf $dbTrim), '--name-file', 'n5.txt')
Check "退出码 0" ($r.Code -eq 0) "out=$($r.Out)"
Check "姓名 = 王五（首尾空白与 CRLF 都裁掉）" ((NameOf $dbTrim) -eq '王五') "name=[$(NameOf $dbTrim)]"

# ---------- 6) 省掉 DSN 与库名、直接给选项 ----------
Write-Host ""
Write-Host "[6] 省掉 DSN 与 --mysql-db 直接给选项 -> 用**默认库名** club_server，且不能把选项当成连接参数"
# 默认库名来自 mysql_store.cj 的 MySqlConfig 默认值（club_server）。
#
# ⚠⚠ 2026-09-24 改：这一条**不再真的往 club_server 写**。
#
# 原来的写法是 `Reset-ClubMySqlSchema club_server`（把那 9 张表全 DROP）→ `init-admin`（不带
# --mysql-db）→ 断言会长叫「张三」，收尾再 DROP 一次。也就是说：**跑一次本脚本，就会把默认库
# club_server 里的真实数据清空**。它没有像 admin-check/ops-check 那样的防误伤闸门，
# 而"默认库名"恰好就是大家联调时用的那个库 —— 实测踩到：升级轻舟那轮跑完全套测试，
# 用户的社团库（会长/运维/4 个部门）被清成空表，运维页显示「成员 0 / 部门 0」。
#
# 现在改成**非破坏性**的等价验证：把端口指向一个**没人监听**的端口，
# 让它在"连接"这一步失败，从报错里读它到底想连哪个库 —— 效果一样（证明默认库名是 club_server），
# 但一个字节都不写。顺带还能验"多个 --mysql-* 选项不会被当成位置参数"。
$r = Run @('init-admin', '13700000006', 'TestPass2026', '--mysql-host', $dbHost,
           '--mysql-port', '3399', '--mysql-user', $dbUser, '--mysql-pass', $dbPass,
           '--name-file', 'n3.txt')
Check "连不上时退出码 1（不静默降级）" ($r.Code -eq 1) "code=$($r.Code) out=$($r.Out)"
Check "报错里给出的是**默认库名** club_server（这是要验的行为）" ($r.Out -match 'club_server') "out=$($r.Out)"
Check "选项被当成连接参数（DSN 位没有吃进 --mysql-port）" ($r.Out -match '3399') "out=$($r.Out)"
Check "没有建出名为 --name-file 的目录" (-not (Test-Path (Join-Path $work '--name-file')))
# 防误伤闸门 —— 精确判据：老写法会往默认库里写一条手机号 13700000006 的会长；现在只探连接、不写，
# 所以"这个手机号在默认库里查不到"就说明没被写进去。
# （不能断言"库不存在"：club_server 是真实社团库，它本来就该存在。）
$leaked = ""
try { $leaked = (Invoke-ClubMySql "SELECT phone FROM members WHERE phone='13700000006' LIMIT 1;" $dbImplicit).Trim() } catch { $leaked = "" }
Check "默认库 club_server 里没有本用例写过的手机号（非破坏性）" ($leaked.Length -eq 0) "leaked=$leaked"

# ---------- 7) 错误用法与错误输入：都要明确报错 ----------
Write-Host ""
Write-Host "[7] 错误用法 / 错误输入 -> 明确报错，不静默忽略"
[IO.File]::WriteAllText((Join-Path $work 'empty.txt'), "", [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $work 'bomonly.txt'), "", [Text.UTF8Encoding]::new($true))
DropDb $dbErr

$bad = @(
    @{ n = '不认识的参数';        a = @('init-admin', '13700000007', 'TestPass2026', (DsnOf $dbErr), '--nmae', 'X'); m = '不认识的参数' },
    # 下两条的提示来自 splitFlags（选项缺值），文案是「选项 --name 后面要跟一个值」——
    # 与 main.cj 里 init-admin 自己那句「--name 后面要跟姓名」不同（那条在 inspect 之后，
    # 现在先被通用解析拦下）。断言按**实际口径**写，不迁就旧文案。
    @{ n = '--name 后面缺值';     a = @('init-admin', '13700000007', 'TestPass2026', (DsnOf $dbErr), '--name');       m = '--name 后面要跟一个值' },
    @{ n = '--name-file 缺值';    a = @('init-admin', '13700000007', 'TestPass2026', (DsnOf $dbErr), '--name-file');  m = '--name-file 后面要跟一个值' },
    @{ n = '两个选项同时给';      a = @('init-admin', '13700000007', 'TestPass2026', (DsnOf $dbErr), '--name', 'A', '--name-file', 'n3.txt'); m = '只能给一个' },
    @{ n = '文件不存在';          a = @('init-admin', '13700000007', 'TestPass2026', (DsnOf $dbErr), '--name-file', 'nope.txt');  m = '读不到姓名文件' },
    @{ n = '空文件';              a = @('init-admin', '13700000007', 'TestPass2026', (DsnOf $dbErr), '--name-file', 'empty.txt'); m = '姓名文件是空的' },
    @{ n = '只有 BOM 的文件';     a = @('init-admin', '13700000007', 'TestPass2026', (DsnOf $dbErr), '--name-file', 'bomonly.txt'); m = '姓名文件是空的' }
)
foreach ($c in $bad) {
    $r = Run $c.a
    Check "$($c.n) -> 退出码 1" ($r.Code -eq 1) "code=$($r.Code) out=$($r.Out)"
    Check "$($c.n) -> 提示说明了原因" ($r.Out -match [regex]::Escape($c.m)) "out=$($r.Out)"
    # 「不能半途写库」：这些错误都在**参数校验阶段**就退出，所以连库都不该被创建。
    # （校验发生在 loadOrExitDb 之前 —— 见 main.cj 里把 resolveMySqlCfg 放在校验之后。）
    Check "$($c.n) -> **没有**建出库（不能半途写库）" (-not (DbExists $dbErr))
}

# ---------- 8) 空库才有资格：非空库仍然拒绝 ----------
Write-Host ""
Write-Host "[8] 非空库仍拒绝（加姓名选项不能绕过这条）"
$r = Run @('init-admin', '13700000008', 'TestPass2026', (DsnOf $dbDefault), '--name', 'Other')
Check "退出码 1" ($r.Code -eq 1) "out=$($r.Out)"
Check "提示「已存在会长账号」" ($r.Out -match '已存在会长账号') "out=$($r.Out)"
Check "原会长的姓名没被改掉" ((NameOf $dbDefault) -eq '会长') "name=[$(NameOf $dbDefault)]"

# ---------- 9) 一个连接参数都不给：必须在连接**之前**喊出来 ----------
Write-Host ""
Write-Host "[9] 不给 DSN 也不给 --mysql-* -> 先明说「正在用默认参数」"
#
# 现场（2026-09-20 实测踩到）：用户在 PowerShell 里跑
#     .\club-server.exe init-ops 13800000009 123456789 $dsn
# 而 `$dsn` **从未定义** —— PowerShell 引用未定义变量不报错、就是空串，于是位置参数空着，
# 程序静默退回默认值（127.0.0.1:**3306** / root / 空口令 / club_server），
# 报出来的是 `Failed to connect 10061`，看着像"端口配错/服务器没起"。
# 本机联调那台 MariaDB 在 **3307**，所以照文档逐行复制时特别容易中这一枪。
#
# 断言只盯**与 3306 有没有服务无关**的部分：那条"我在用默认参数"的提示必须出现，
# 且必须点出本机联调端口 3307 —— 这样无论 3306 上有没有库，这条都是确定的。
$r = Run @('init-ops', '13700000009', 'TestPass2026')
Check "提示里点名「没有给 DSN / --mysql-*」" ($r.Out -match '没有.*给 DSN') "out=$($r.Out)"
Check "提示里给出本机联调端口 3307（否则用户只能瞎猜）" ($r.Out -match '3307') "out=$($r.Out)"
Check "提示里给出正确写法示例" ($r.Out -match 'mysql://root:<口令>@127\.0\.0\.1:3307') "out=$($r.Out)"

# ---------- 收尾：清测试库与临时目录 ----------
# ⚠ 同样**不含** $dbImplicit（默认库 club_server = 真实社团库），一个字节都不碰它。
foreach ($d in @($dbDefault, $dbAscii, $dbZh, $dbBom, $dbTrim, $dbErr)) {
    Reset-ClubMySqlSchema $d
}
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "======================================"
Write-Host "会长姓名选项： PASS $pass / FAIL $fail"
Write-Host "======================================"
if ($fail -gt 0) { exit 1 }
exit 0
