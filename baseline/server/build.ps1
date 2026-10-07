# 社团管理工具 · 服务端构建脚本
#
# 编译路径（已在 ..\docs\HANDOFF.md §2 / 上层的 cangjie-upstream\qingzhou-tls-verification.md §1.2 实测过）：
#   cjc 1.2.0 + stdx 1.1.3.1（静态）+ **仓库内置的**轻舟源码，**同一次调用、同一个包**。
#
# 轻舟已内置在 third_party\qingzhou（2026-09-15 迁移，对应 docs/code-review.md 的 N-20）：
#   原先按**机器本地路径** E:\cangjie\qingzhou 取框架源码，且只查"在不在"、不查版本 ——
#   换台机器（或本地对轻舟 pull 一次）就会编到另一个版本的框架，**照样 BUILD SUCCESSFUL**，
#   而 server\src\fw_rbac*.cj 是跟着上游文件走的适配，于是变成"框架换了、适配没换"的静默漂移。
#   现在：源码在仓库里、版本记在 third_party\qingzhou\UPSTREAM_COMMIT（**唯一出处**）、
#   内容由 MANIFEST.sha256 逐字节校验；内置框架被改动/增删会**当场拒绝构建**。
#
# 为什么不用 cjpm：轻舟自己的 examples/*.cj 都写 `package qingzhou`，
# 框架既定用法就是与框架源码一起编译（build.sh 也是这么做的）。
#
# 用法：
#   .\build.ps1                      校验内置框架 + 编译 + 复制依赖 DLL 到 build\
#   .\build.ps1 -Target admin        改编译**轻舟后台管理界面**（admin.exe，见下）
#   .\build.ps1 -NoDll               只编译（本机已装好 DLL 时更快）
#   .\build.ps1 -SkipFrameworkCheck  跳过内置框架的内容校验（**仅**在有意改动内置框架时用）
#
# -Target admin（2026-09-16 新增）编译的是**运维台**：后台管理界面 + 「社团管理」运维页：
#   源码 = 框架 src（保留上游 rbac.cj **与 store.cj**）＋ server\src\ops\*.cj（我们自己的入口与只读视图）
#        ＋ server\src\{store,audit,timex,strx}.cj（社团库只读 + 时间/字符串工具）
#   数据层 = 框架 src\store.cj 的 RbacStore（2026-09-19 起：后端是 MySQL，不再是我们那个
#            JSON 文件适配 fw_rbac_store.cj —— 它是给没有数据库的年代写的，见下）
#   产物 = build\admin\admin.exe ＋ admin-web\（前端，取 server\admin-web）＋ admin.env
#   它是个**独立小程序**，与本项目的 club-server 各编各的（不共享入口、不共享令牌体系）；
#   运维页**读**社团库文件、**写**交给 club-server 的真实 API（见 docs\HANDOFF.md §2）。
#   上游 examples\admin.cj / admin-web 仍留在快照里，但**只作对照**、不参与这条构建。
#
# admin 的数据层（2026-09-19 改）：轻舟 v0.7 有了数据库抽象层（src\db.cj 接口 +
# src\db_mysql.cj 的 MySqlBackend），当年写 fw_rbac_store.cj 的理由（沧海 CangDB 1.0.5 与旧版 cjc 1.1.3 不兼容：编译通过、运行超时）
# 对 MySQL 不成立 —— 所以运维台的 RBAC 数据层改用**框架的 RbacStore + MySQL**。
#   · 框架 store.cj 参与 admin 构建（从下面的排除清单里去掉）；
#   · $app 里去掉 fw_rbac_store.cj（与框架 RbacStore 同名同包，不能并存）；
#   · 额外链上 MariaDB 驱动（third_party\mariadb-driver 的产物，见 build-mysql-driver.ps1）。
# ⚠ club-server（else 分支）**不受影响**：它仍排除 store.cj / db_mysql.cj，仍用 fw_rbac*.cj
#   那套文件后端。切换只发生在 admin 这条分支上，原因见 docs\mysql-backend.md。
#
# 换一台机器：cjc 与 stdx 的位置**不再写死**，脚本自动探测（显式传参 > 环境变量 > 常见位置 > PATH）：
#   .\build.ps1 -CangjieHome <SDK目录> -Stdx <...\windows_x86_64_cjnative\static\stdx>
#   或设环境变量 CANGJIE_HOME / CANGJIE_STDX
#   （**不需要**仓库外的轻舟：框架已内置在 third_party\qingzhou）

param(
    [string]$CangjieHome = "",
    [string]$Stdx        = "",
    [string]$Vendor      = "",
    [string]$OpenSslDir  = "",
    [ValidateSet('server', 'admin')]
    [string]$Target      = "server",
    [switch]$NoDll,
    [switch]$SkipFrameworkCheck
)

$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
$src  = Join-Path $root "src"
$out  = Join-Path $root "build"
if ([string]::IsNullOrEmpty($Vendor)) { $Vendor = Join-Path $root "third_party\qingzhou" }
New-Item -ItemType Directory -Force -Path $out | Out-Null

# ── 工具链解析（2026-09-16：为了「换一台机器也能编」） ────────────────────
# 原先这两个路径写死成本机的 D:\Cangjie 与 E:\cangjie\stdx\...，别人 clone 下来必然报
# 「找不到编译器」/「找不到 stdx」。现在按下面的顺序找，并把**解法**写在报错里。
function Resolve-CangjieHome([string]$explicit) {
    $cands = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrEmpty($explicit)) { [void]$cands.Add($explicit) }
    # 注意顺序：**常见安装位置优先于 PATH**。项目内工具目录放在最前，确保 clone 后
    # 可以用明确的 1.2.0 SDK 构建，不会被 PATH 上的旧版 shim 抢走。
    # 所以 PATH 只作最后兜底。
    foreach ($d in @((Join-Path $root "..\.tools\cangjie-1.2.0\cangjie"),
                     (Join-Path $root "..\.tools\cangjie-1.2.0\cangjie"),
                     "D:\Cangjie", "C:\Cangjie", "E:\Cangjie",
                     (Join-Path $env:USERPROFILE "Cangjie"),
                     (Join-Path $env:ProgramFiles "Cangjie"))) { [void]$cands.Add($d) }
    if ($env:CANGJIE_HOME) { [void]$cands.Add($env:CANGJIE_HOME) }
    $onPath = Get-Command cjc -ErrorAction SilentlyContinue
    if ($null -ne $onPath) { [void]$cands.Add((Split-Path (Split-Path $onPath.Source) -Parent)) }
    # 先把"真实存在"的候选按优先级收集起来
    $found = New-Object System.Collections.ArrayList
    foreach ($c in $cands) {
        if (-not [string]::IsNullOrEmpty($c) -and (Test-Path ([System.IO.Path]::Combine($c, "bin\cjc.exe")))) {
            $rp = (Resolve-Path $c).Path
            if (-not $found.Contains($rp)) { [void]$found.Add($rp) }
        }
    }
    # 再**按版本挑**：优先本项目基线的 1.2.0。
    # 为什么不能只看位置：cjenv 会把全局 CANGJIE_HOME 改写成旧 SDK，
    # 而 PATH 上的 cjc 也可能是那个 shim —— 拿它去配 stdx 1.1.3.1 会串台
    # （症状 LLVM ERROR: Broken module found，见下面钉死工具链那段注释）。
    foreach ($c in $found) {
        $v = (& (Join-Path $c "bin\cjc.exe") --version 2>&1 | Select-Object -First 1)
        if ("$v" -match '1\.2\.0') { return $c }
    }
    if ($found.Count -gt 0) { return $found[0] }
    return ""
}

function Resolve-Stdx([string]$explicit, [string]$sdkHome) {
    $cands = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrEmpty($explicit)) { [void]$cands.Add($explicit) }
    if ($env:CANGJIE_STDX) { [void]$cands.Add($env:CANGJIE_STDX) }
    $roots = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrEmpty($sdkHome)) {
        [void]$roots.Add((Split-Path $sdkHome -Parent))
        [void]$roots.Add($sdkHome)
    }
    foreach ($r in @((Join-Path $root "..\.tools\stdx"),
                     (Join-Path $root "..\.tools\cangjie-stdx-windows-x64-1.1.3.1"),
                     "E:\cangjie", "D:\cangjie", "C:\cangjie", (Join-Path $env:USERPROFILE "cangjie"))) { [void]$roots.Add($r) }
    foreach ($c in $cands) { if (Test-Path $c) { return (Resolve-Path $c).Path } }
    foreach ($r in $roots) {
        foreach ($sub in @("stdx\windows_x86_64_cjnative\static\stdx", "stdx\static\stdx")) {
            $p = [System.IO.Path]::Combine($r, $sub)
            if (Test-Path $p) { return (Resolve-Path $p).Path }
        }
    }
    return ""
}

# 显式传参传错时**不能静默忽略**：否则用户以为自己在用指定 SDK，实际用的是探测到的另一个。
$explicitHome = $CangjieHome
$explicitStdx = $Stdx
$CangjieHome = Resolve-CangjieHome $CangjieHome
if (-not [string]::IsNullOrEmpty($explicitHome) -and
    -not (Test-Path (Join-Path $explicitHome "bin\cjc.exe"))) {
    Write-Warning "-CangjieHome 指定的目录里没有 bin\cjc.exe：$explicitHome（已忽略，改用自动探测结果）"
}
if ([string]::IsNullOrEmpty($CangjieHome)) {
    throw ("找不到仓颉 SDK（cjc.exe）—— 这是**编译**服务端的前提。`n" +
           "  ① 只想要能跑的服务端（不编译）：拿一份**部署包**即可 —— `n" +
           "     server\dist\club-server\ 里的 exe + 4 个 DLL + 启动脚本，同平台直接可运行；`n" +
           "     或在本机已有构建的机器上跑 build-package.ps1 生成后拷过去。`n" +
           "  ② 要自己编译：装好「仓颉 SDK 1.2.0 + stdx 1.1.3.1」两个包，`n" +
           "     版本见 README『环境事实』），然后任选其一告诉我路径：`n" +
           "     · .\build.ps1 -CangjieHome <SDK目录> -Stdx <stdx目录>`n" +
           "     · 设环境变量 CANGJIE_HOME 与 CANGJIE_STDX`n" +
           "     · 把 cjc.exe 放进 PATH`n" +
           "  下载：https://cangjie-lang.cn/download")
}
$Stdx = Resolve-Stdx $Stdx $CangjieHome
if (-not [string]::IsNullOrEmpty($explicitStdx) -and -not (Test-Path $explicitStdx)) {
    Write-Warning "-Stdx 指定的目录不存在：$explicitStdx（已忽略，改用自动探测结果）"
}
if ([string]::IsNullOrEmpty($Stdx)) {
    throw ("找不到 stdx 的静态库（libstdx*.a）。`n" +
           "  cjc 与 stdx 是**两个包**：装了编译器还要单独装 stdx（本机在 E:\cangjie\stdx\...）。`n" +
           "  找到后：.\build.ps1 -Stdx <...\windows_x86_64_cjnative\static\stdx>，或设 `$env:CANGJIE_STDX。")
}
Write-Host "[build] 工具链：cjc=$CangjieHome"
Write-Host "[build]          stdx=$Stdx"
# 显式传了 A、实际用了 B 时必须说清楚（例如显式指了 cjenv 的 1.0.5，按版本被跳过）。
function Test-SameDir([string]$a, [string]$b) {
    if ([string]::IsNullOrEmpty($a) -or [string]::IsNullOrEmpty($b)) { return $true }
    $ra = (Resolve-Path $a -ErrorAction SilentlyContinue)
    $rb = (Resolve-Path $b -ErrorAction SilentlyContinue)
    if ($null -eq $ra -or $null -eq $rb) { return $true }
    return ($ra.Path -eq $rb.Path)
}
if (-not (Test-SameDir $explicitHome $CangjieHome)) {
    Write-Warning "-CangjieHome 指定的是 $explicitHome，实际使用 $CangjieHome（前者版本不是 1.2.0，按基线跳过）"
}
if (-not (Test-SameDir $explicitStdx $Stdx)) {
    Write-Warning "-Stdx 指定的是 $explicitStdx，实际使用 $Stdx"
}

$Cjc        = Join-Path $CangjieHome "bin\cjc.exe"
$RuntimeDir = Join-Path $CangjieHome "runtime\lib\windows_x86_64_cjnative"

$ver = (& $Cjc --version 2>&1 | Select-Object -First 1)
Write-Host "[build]          cjc 版本：$ver"
# 版本不对时**不要**让它编到一半才炸：cjc 与 stdx 版本串台的症状是
#   LLVM ERROR: Broken module found … @llvm.cj.get.vtable.func、opt.exe 崩溃
# 极易被当成编译器 bug。这里提前讲清楚，并给出解法。
if ("$ver" -notmatch '1\.2\.0') {
    throw ("本机 cjc 是 '$ver'，而本项目要求 1.2.0 + stdx 1.1.3.1（见 README『环境事实』）。`n" +
                   "    cjc 与 stdx 版本不一致时，典型症状是编译中途 LLVM ERROR: Broken module found / opt 崩溃。`n" +
                   "    处置：装仓颉 1.2.0 SDK 与 stdx 1.1.3.1，再用 -CangjieHome / -Stdx 显式指过去。")
}
if (-not (Test-Path $Cjc))  { throw "找不到编译器：$Cjc" }
if (-not (Test-Path $Stdx)) { throw "找不到 stdx：$Stdx" }
$VendorSrc = Join-Path $Vendor "src"
if (-not (Test-Path $VendorSrc)) {
    throw "找不到内置的轻舟源码：$VendorSrc —— 本项目把框架内置在 server\third_party\qingzhou，请确认该目录已随仓库检出。"
}

# ── 内置框架的版本与完整性（N-20） ──────────────────────────────────────
$upCommitFile = Join-Path $Vendor "UPSTREAM_COMMIT"
$upCommit = if (Test-Path $upCommitFile) { (Get-Content $upCommitFile -Encoding UTF8 | Select-Object -First 1).Trim() } else { "未知" }
$upShort  = $upCommit.Substring(0, [Math]::Min(7, $upCommit.Length))

if (-not $SkipFrameworkCheck) {
    $mf = Join-Path $Vendor "MANIFEST.sha256"
    if (-not (Test-Path $mf)) { throw "内置框架缺少 MANIFEST.sha256：$mf" }
    $bad = New-Object System.Collections.ArrayList
    $listed = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($line in (Get-Content $mf -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $m = [regex]::Match($line, '^([0-9a-f]{64})\s\s(.+)$')
        if (-not $m.Success) { throw "MANIFEST.sha256 行格式不对：$line" }
        $want = $m.Groups[1].Value
        $rel  = $m.Groups[2].Value.Trim()
        [void]$listed.Add($rel)
        $p = Join-Path $Vendor ($rel -replace '/', '\')
        if (-not (Test-Path $p)) { [void]$bad.Add("缺失 $rel"); continue }
        if ((Get-FileHash $p -Algorithm SHA256).Hash.ToLower() -ne $want) { [void]$bad.Add("内容变了 $rel") }
    }
    foreach ($f in (Get-ChildItem $VendorSrc -Filter *.cj -File)) {
        if (-not $listed.Contains("src/$($f.Name)")) { [void]$bad.Add("多出未登记的源文件 src/$($f.Name)") }
    }
    if ($bad.Count -gt 0) {
        throw ("内置轻舟与 MANIFEST.sha256 不一致：`n  - " + ($bad -join "`n  - ") + "`n" +
               "内置框架**不应被本地修改**：我们的改动一律放 server\src\fw_rbac*.cj。`n" +
               "若确实是有意的更新，请跑 server\third_party\qingzhou\update-manifest.ps1，" +
               "并在提交信息里说明为什么改了内置框架。")
    }
}

# ── 把工具链钉死（**不要删**） ───────────────────────────────────────────
# 本机装了 cjenv（另一个项目：仓颉 SDK 版本管理器），它会改写 CANGJIE_HOME 并把
# 自己的 shims 塞进 PATH。一旦 CANGJIE_HOME 指向别的 SDK（例如 1.0.5），
# 而 PATH 里的 cjc 仍是旧版，就会出现前端与后端 LLVM 串台：
#   LLVM ERROR: Broken module found … @llvm.cj.get.vtable.func … opt.exe 崩溃
# 这类错误看起来像编译器 bug，实际只是环境串台。这里显式指定本次编译用的工具链。
$env:CANGJIE_HOME = $CangjieHome
$env:PATH = (Join-Path $CangjieHome "bin") + ";" +
            (Join-Path $CangjieHome "third_party\llvm\bin") + ";" + $env:PATH

$libs = (Get-ChildItem "$Stdx\libstdx*.a" | ForEach-Object { "-l:$($_.Name)" })

# ── MySQL 驱动产物（两条分支都要，2026-09-20）──────────────────────────
# 为什么这里要**显式**检查产物目录：MySqlBackend 在编译期零驱动依赖（驱动是运行时按
# 注册名查找的），所以驱动缺了照样能编过 —— 直到服务启动去建连时才炸一句
# "未注册 mysql/mariadb 驱动"，那时已经和"编译"隔了好几层。宁可在构建这一步就说清楚。
#
# 注意：驱动产物**必须**先在 server\ 下生成一次（产物不入库）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\build-mysql-driver.ps1
$drvDir = Join-Path $out "mysql-driver"
if (-not (Test-Path (Join-Path $drvDir "mariadb.cdbc.cjo"))) {
    throw ("数据层现在是 MySQL，编译需要内置 MariaDB 驱动的产物，但 `n" +
           "  $drvDir 里没有 mariadb.cdbc.cjo。`n" +
           "请先在 server\ 下生成它（只须一次，产物不入库）：`n" +
           "  powershell -NoProfile -ExecutionPolicy Bypass -File .\build-mysql-driver.ps1`n" +
           "说明见 build-mysql-driver.ps1 的文件头与 docs\mysql-backend.md。")
}
# 链接驱动必须用 **-l:完整文件名**：`-lmariadb.cdbc` 会被 cjc 按点号拆开，
# 实测报 `invalid file or directory '.cdbc'`（见 docs\mysql-backend.md §3.3）。
# --import-path / -L 指到产物目录：编译期要找 mariadb.cdbc 的 .cjo，
# 链接期要找三个静态库；两个都得给。
$extraImportPath = @("--import-path", $drvDir)
$extraLibPath    = @("-L", $drvDir)
$extraLibs       = @("-l:mariadb.cdbc", "-l:mariadb.connection", "-l:mariadb.protocol")

# 排除框架自己的入口与测试：main.cj 有 main()、unit_tests.cj / manual_runner.cj 是框架自测，
# 我们的 main.cj 提供入口。这与上层 cangjie-upstream\qingzhou-tls-verification.md 里编译 examples/https.cj 的命令一致。
#
# store.cj / rbac.cj（2026-09-14，轻舟升级到 3ea387e 后新增）：上游这两张文件原本依赖外部 CangDB，
# 而沧海 CangDB 虽已开源，其 1.0.5 版本与本项目当前构建仍未完成兼容验证，`import cangdb.*` 在我们这条构建里没有可用实现。
# club-server 因此用自己的适配版代替（数据层换成文件存储、响应换用我们的错误格式）：
#   server/src/fw_rbac_store.cj  -> RbacStore / UserRow / RoleRow / PermRow
#   server/src/fw_rbac.cj        -> requirePermission
# 所以 club-server 那条**必须**继续排除框架原版，否则 RbacStore 会重名冲突。
# 注意：内置目录里**保留**这两张上游文件（便于对照），被排除的只是"不参与编译"。
#
# ⚠ 2026-09-20 更新：**club-server 的持久化也切到 MySQL 了**（路线 B：只换持久化层，
# 内存模型与业务逻辑一行不动，见 server\src\mysql_store.cj 与 docs\club-server-mysql-assessment.md）。
# 于是两条分支**都要**：① 编框架的 db.cj + db_mysql.cj；② 链内置 MariaDB 驱动。
# 差别只剩 RBAC 那一块：
#   server（默认，club-server）：排除 store.cj / rbac.cj（它用 fw_rbac_store + fw_rbac），
#                                **保留** db.cj + db_mysql.cj（数据层要 MySqlBackend）
#   admin（-Target admin）      ：排除 db_cangdb.cj / db_factory.cj，**保留** store.cj（RbacStore 在它里面）
#                                 + db_mysql.cj
if ($Target -eq "admin") {
    # 与 club-server 那条的差别（2026-09-19）：
    #   · **保留** store.cj —— admin 的数据层就是它的 RbacStore(db)（后端 = MySQL）；
    #   · 仍排除 db_cangdb.cj（要 cangdb）/ db_factory.cj（工厂引用 CangDbBackend，排除前者会编不过），
    #     所以绕过工厂，由 ops\admin_main.cj 直接 new MySqlBackend(...)。
    $fw = Get-ChildItem "$VendorSrc\*.cj" |
          Where-Object { $_.Name -notin @('main.cj', 'unit_tests.cj', 'manual_runner.cj', 'db_cangdb.cj', 'db_factory.cj', 'jsonx_edge_test.cj') } |
          ForEach-Object { $_.FullName }
    # 运维台的源码 = 我们自己的入口 + 社团库（只读）+ 它需要的自包含工具文件。
    # 为什么是"挑文件"而不是"整个 src"：server/src 里的 h_*.cj / main.cj / jsonw.cj 等
    # 是 club-server 的东西，带进来会与框架同包撞名、也会白白膨胀这个 exe。
    # ⚠ 这里**不含** fw_rbac_store.cj（2026-09-19 起）：它的 RbacStore 与框架 store.cj 的
    #   同名同包，两个都编就是重名冲突；而 admin 现在用框架那份 + MySQL。
    #   该文件本身**不能删** —— club-server 那条分支仍在用它（见 else 分支）。
    $app = @(
        (Join-Path $src "store.cj"),          # 社团数据模型与 JSON 字段映射
        (Join-Path $src "store_persistence.cj"), # 加载、快照与落盘
        (Join-Path $src "store_queries.cj"), # 查询、排序、幂等与课题树辅助
        (Join-Path $src "mysql_store.cj"),    # MySQL 载入/落盘（store.cj 现在引用它，必须一起编）
        (Join-Path $src "audit.cj"),          # 审计日志写入口（store.cj 的 flushPending 调它）
        (Join-Path $src "timex.cj"),          # epoch → ISO8601(+08:00)，与服务端口径一致
        (Join-Path $src "strx.cj"),           # isBlank / containsAscii 等字节级工具
        (Join-Path $src "ops\club_json.cj"),  # jsonw.cj 里 6 个工具的自包含替身
        (Join-Path $src "ops\club_view.cj"),  # 社团库只读视图（概览/名录/部门/任务/课题/链接/审计）
        (Join-Path $src "ops\admin_main.cj")  # 入口：上游那套 + /api/club/** + 状态码修正
    )
    foreach ($f in $app) {
        if (-not (Test-Path $f)) { throw "找不到运维台源码：$f" }
    }

    $outDir = Join-Path $out "admin"
    $exe = Join-Path $outDir "admin.exe"
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    Write-Host "[build] 框架：轻舟 $upShort（内置 third_party\qingzhou，$($fw.Count) 个文件参与编译，含 store.cj + db_mysql.cj）"
    Write-Host "[build] 运维台 $($app.Count) 个文件（src\ops\* + 社团库只读） -> $exe"
    Write-Host "[build] 数据层：MySQL（RBAC 走框架 RbacStore + MySqlBackend）"
} else {
    # club-server（2026-09-20 起：数据层也是 MySQL）。
    # 仍排除 store.cj / rbac.cj —— 那是**框架的 RBAC**，club-server 用 fw_rbac_store + fw_rbac。
    # **db_mysql.cj 现在必须编进来**：我们的 MySQL 持久化层（src\mysql_store.cj）
    # 直接构造 MySqlBackend，它在 db_mysql.cj 里。
    $fw = Get-ChildItem "$VendorSrc\*.cj" |
          Where-Object { $_.Name -notin @('main.cj', 'unit_tests.cj', 'manual_runner.cj', 'store.cj', 'rbac.cj', 'db_cangdb.cj', 'db_factory.cj', 'jsonx_edge_test.cj') } |
          ForEach-Object { $_.FullName }
    $app = Get-ChildItem "$src\*.cj" | ForEach-Object { $_.FullName }
    if ($app.Count -eq 0) { throw "没有找到服务端源码：$src" }
    $outDir = $out
    $exe = Join-Path $out "club-server.exe"
    Write-Host "[build] 框架：轻舟 $upShort（内置 third_party\qingzhou，$($fw.Count) 个文件参与编译，含 db.cj + db_mysql.cj）"
    Write-Host "[build] 服务端 $($app.Count) 个文件 -> $exe"
    Write-Host "[build] 数据层：MySQL（src\mysql_store.cj + 驱动 $out\mysql-driver）"
}

# 目标 exe 被上一个进程占着时，ld.lld 只丢一句 "failed to write the output file: Permission denied"，
# 看上去像 SDK/权限问题，实际是服务端没停干净。先自查一遍，给能直接照做的提示。
if (Test-Path $exe) {
    try {
        $fs = [IO.File]::Open($exe, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $fs.Close()
    } catch {
        $procName = if ($Target -eq "admin") { "admin" } else { "club-server" }
        throw ("编译输出被占用：$exe" + [Environment]::NewLine +
               "  原因：还有 $procName.exe 在运行，Windows 不允许覆盖正在执行的 exe。" + [Environment]::NewLine +
               "  处置：Get-Process $procName -ErrorAction SilentlyContinue | Stop-Process -Force" + [Environment]::NewLine +
               "        然后重新执行 .\build.ps1" + $(if ($Target -eq "admin") { " -Target admin" } else { "" }))
    }
}

& $Cjc @fw @app --import-path $Stdx -L $Stdx @libs @extraImportPath @extraLibPath @extraLibs -lcrypt32 -Woff unused -o $exe
if ($LASTEXITCODE -ne 0) { throw "编译失败 (exit $LASTEXITCODE)" }
Write-Host "[build] 编译通过"

# ── admin 额外要带的东西：前端产物 + 配置模板 ───────────────────────────
# 上游 examples\admin.cj 是按 cwd 找资源和配置的（serveWithOpts("./admin-web/dist") /
# loadConfigFile("./admin.env")），所以产物目录必须是**自包含**的：exe + admin-web + admin.env。
# 这与本项目"cwd 必须是 exe 所在目录"的既有约定一致（README 六条坑之一）。
if ($Target -eq "admin") {
    # 前端取**我们自己**的 server\admin-web（在上游版本上加了「社团管理」运维页），
    # 上游那份快照（third_party\qingzhou\admin-web）保持逐字节原样、只作对照。
    # dist 是随仓库提交的预构建产物 —— 部署机与运维机都不需要 Node/npm。
    $webSrc = Join-Path $root "admin-web"
    $webDst = Join-Path $outDir "admin-web"
    if (-not (Test-Path (Join-Path $webSrc "dist\index.html"))) {
        throw ("找不到前端产物：$webSrc\dist\index.html`n" +
               "  改了 server\admin-web\src 之后要重新构建前端（需要 Node）：`n" +
               "    cd server\admin-web ; npm install ; npm run build`n" +
               "  只用现成产物的话，确认 dist\ 已随仓库检出。")
    }
    if (Test-Path $webDst) { Remove-Item $webDst -Recurse -Force }
    # ⚠ **只拷 dist**（2026-09-17 修）。原先写的是 `Copy-Item $webSrc $webDst -Recurse`，
    # 会把整个 server\admin-web 搬过去 —— 包含 **node_modules（npm install 之后约 39 MB / 777 个文件）**、
    # src\、package-lock.json。而运行时只需要 `./admin-web/dist`（见上面 serveWithOpts 那段），
    # 于是每次构建白拷几十 MB，产物目录也跟着膨胀。
    # 只拷 dist 之后：产物依然自包含（exe + admin-web\dist + admin.env），体积回到 ~120 KB。
    $webDist = Join-Path $webSrc "dist"
    New-Item -ItemType Directory -Force -Path $webDst | Out-Null
    Copy-Item $webDist $webDst -Recurse
    Write-Host "[build] 前端已就位：admin-web\dist（只拷 dist；含「社团管理」运维页）"

    # admin.env 若已存在就**不动**（用户可能改过端口/密钥）；否则从内置模板生成一份"MySQL 数据层"版
    $envFile = Join-Path $outDir "admin.env"
    if (-not (Test-Path $envFile)) {
        $port = "3000"
        $ttl = "7200"
        $secret = -join ((1..64) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
        # 模板里的 MySQL 端口默认写 3306（MySQL 的出厂端口）。但本项目**本机联调**用的是一台
        # 便携版 MariaDB，它在 3307（非默认端口、不装 Windows 服务，见 docs\mysql-backend.md §7）。
        # 若模板一律写 3306，用户第一次 -Target admin 后启动就会撞上"连不上 127.0.0.1:3306"，
        # 而病因（端口）恰恰是最不容易想到的那一个。所以这里探测一下：3307 在听就用 3307。
        # 只影响**首次生成**的那一份；已存在的 admin.env 一律不覆盖（见下面的 else 分支）。
        $mysqlPort = "3306"
        foreach ($cand in @(3307, 3306)) {
            $probe = New-Object System.Net.Sockets.TcpClient
            try {
                if ($probe.ConnectAsync("127.0.0.1", $cand).Wait(300)) { $mysqlPort = "$cand"; break }
            } catch { } finally { $probe.Close() }
        }
        Write-Host "[build] admin.env 模板：mysql_port=$mysqlPort（探测 127.0.0.1 上 3307/3306 哪个在听）"
        # 口令同理（2026-09-20 补）：端口探测命中 3307 说明用的就是**本项目文档里那台便携版 MariaDB**
        # （docs\mysql-backend.md §7：root / clubroot123）。此时模板若仍留空 mysql_pass，
        # 首次 -Target admin 生成的这份 env 就**必然连不上** —— 症状是 admin.exe 起不来或
        # 驱动报 `Unsupported auth plugin`，而"口令留空"这件事在报错里完全看不出来。
        # 实测踩到：清掉 build\ 后重新生成 env → ops-check 直接红（它从这份 env 取连接参数）。
        # 探测到的是公网/别人的 3306 时**不猜口令**，仍然留空让人自己填。
        $mysqlPass = ""
        if ($mysqlPort -eq "3307") { $mysqlPass = "clubroot123" }
        $lines = @(
            "# 轻舟后台管理界面 · 本地配置（由 server\build.ps1 -Target admin 首次生成，可自行修改）",
            "#",
            "# 数据层 = **MySQL**（2026-09-19 起）。框架 src\store.cj 的 RbacStore(db) + src\db_mysql.cj 的",
            "# MySqlBackend；驱动是内置的 third_party\mariadb-driver（注册名 mariadb，见 docs\mysql-backend.md）。",
            "# 首次启动会自动建表（CREATE TABLE IF NOT EXISTS）并灌种子；种子口令见下方 admin_pass / user_pass。",
            "",
            "port=$port",
            "",
            "# MySQL / MariaDB 连接（库要先建好：CREATE DATABASE club_rbac CHARACTER SET utf8mb4;）",
            "mysql_host=127.0.0.1",
            "# ⚠ 端口按你自己的服务器改：本机联调的便携版 MariaDB 用的是 3307，MySQL 默认是 3306。",
            "mysql_port=$mysqlPort",
            "mysql_user=root",
            "# ⚠ 口令：**留空 = 无口令**。上面探测到 3307 时这里预填的是本项目文档里那台便携版",
            "#    MariaDB 的口令（docs\mysql-backend.md §7）；换成你自己的服务器时请改掉。",
            "#    留空不会报错，但会表现为连不上（驱动报 Unsupported auth plugin / 认证失败）。",
            "mysql_pass=$mysqlPass",
            "mysql_db=club_rbac",
            "",
            "# JWT 签名密钥：本文件生成时已随机 64 位十六进制。**生产环境请换成自己的强随机值**",
            "secret=$secret",
            "",
            "# token 有效期（秒）",
            "ttl=$ttl",
            "",
            "# 后台账号口令 —— N-29（2026-09-17）起**不再写死**在这份模板里。",
            "# admin.exe 首次启动（建库/建表）时会随机生成一对口令（各 16 个十六进制字符），",
            "# 追加到本文件的 admin_pass / user_pass，并在控制台打印一次；之后不再回显。",
            "# 想自己指定，就取消下面两行的注释并填值（别用 admin123 这类公开默认值）。",
            "admin_user=admin",
            "# admin_pass=",
            "# user_pass=",
            "",
            "# ── 「社团管理」运维页（/club）──",
            "# 社团库的位置（2026-09-20 改）：club-server 的业务数据现在在 **MySQL** 里，",
            "# 与后台自己的 RBAC 库是**同一个实例、不同库**：host/port/user/pass 复用上面的 mysql_*，",
            "# 库名用下面的 club_mysql_db（默认 club_server = club-server 的 MySqlConfig.db 默认值）。",
            "# ⚠ 这里必须与 club-server 实际连的库名**一模一样**（它用 DSN 时以 DSN 里的为准）：",
            "#   写不一致时运维页只报一句 `Unknown database 'xxx'`，看不出是名字写错 —— 实测踩到过",
            "#   （老模板写的是 club，而 club-server 默认 club_server）。",
            "# 运维页**只读**它；写操作仍由前端直连 club-server 的真实 API。",
            "club_mysql_db=club_server",
            "",
            "# club_data 现在**只表示审计日志目录**（audit.log 仍在文件里，不入库）。",
            "# 默认 ../data = club-server 从 build\\ 启动时的默认 --data-dir。",
            "club_data=../data",
            "",
            "# club-server 的地址：club_api 供运维台自己探测 /health（服务端侧），",
            "# club_port 供浏览器拼地址（http://<运维页的 host>:<club_port>），两者可不同。",
            "club_api=http://127.0.0.1:8080",
            "club_port=8080",
            "",
            "# 专用运维账号（club-server 侧的 role = ops，只能用 club-server init-ops 创建）。",
            "# 运维人员只用后台账号登录（口令见上面的说明）；写操作由后台以**这个账号**的身份发出，",
            "# 所以 club-server 的审计里 actor 是运维，而不是会长 —— 运维与会长职责分离。",
            "# 留空 = 运维页只能看不能改（页面会提示怎么做）。",
            "club_user=",
            "club_pass="
        )
        [System.IO.File]::WriteAllLines($envFile, $lines, [System.Text.UTF8Encoding]::new($false))
        Write-Host "[build] 已生成 build\admin\admin.env（MySQL 数据层；secret 已随机）"
    } else {
        Write-Host "[build] 保留已有的 build\admin\admin.env（未覆盖）"
    }
}

# ── OpenSSL 3 的两个 DLL 从哪来 ─────────────────────────────────────────
# 它们是**运行时 dlopen** 用的（不在 exe 导入表里），6.5 MB 二进制，**不随仓库提交**。
# 解析顺序（每一步都会打印实际用的是哪一份，不会静默）：
#   1) 内置目录 third_party\qingzhou\deps\openssl（放了就用）
#   2) -OpenSslDir <目录>（给了就**只用它**，不再回退）
#   3) Git for Windows 自带的 mingw64\bin（本项目本来就依赖它的 openssl CLI；实测 3.5.7）
# 都找不到 → 报错退出并写清两种处置。详见 third_party\qingzhou\deps\openssl\README.md。
function Test-OpenSslDir([string]$d) {
    if ([string]::IsNullOrEmpty($d)) { return $false }
    if (-not (Test-Path (Join-Path $d "libcrypto-3-x64.dll"))) { return $false }
    if (-not (Test-Path (Join-Path $d "libssl-3-x64.dll"))) { return $false }
    return $true
}

function Resolve-OpenSslDir([string]$VendorDir, [string]$Explicit) {
    $inRepo = Join-Path $VendorDir "deps\openssl"
    if (-not [string]::IsNullOrEmpty($Explicit)) {
        if (Test-OpenSslDir $Explicit) { return (Resolve-Path $Explicit).Path }
        throw "-OpenSslDir 里没有 libcrypto-3-x64.dll / libssl-3-x64.dll：$Explicit"
    }
    if (Test-OpenSslDir $inRepo) { return (Resolve-Path $inRepo).Path }
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -ne $git) {
        $gitRoot = Split-Path (Split-Path $git.Source) -Parent
        foreach ($cand in @((Join-Path $gitRoot "mingw64\bin"), (Join-Path $gitRoot "usr\bin"))) {
            if (Test-OpenSslDir $cand) { return (Resolve-Path $cand).Path }
        }
    }
    throw ("找不到 OpenSSL 3 的两个 DLL（libcrypto-3-x64.dll / libssl-3-x64.dll）。`n" +
           "  已按顺序找过：1) $inRepo   2) -OpenSslDir 参数   3) Git for Windows 的 mingw64\bin`n" +
           "  两种处置（任选其一）：`n" +
           "    A) 从 Git for Windows 拷一份到内置目录（推荐，版本已核对 3.5.7）：`n" +
           "         Copy-Item `"<Git>\mingw64\bin\libcrypto-3-x64.dll`" `"$inRepo`"`n" +
           "         Copy-Item `"<Git>\mingw64\bin\libssl-3-x64.dll`"    `"$inRepo`"`n" +
           "    B) 用 -OpenSslDir <目录> 指向任意一份 OpenSSL 3 x64（该目录须同时含这两个 DLL）。`n" +
           "  说明见 third_party\qingzhou\deps\openssl\README.md。")
}

if (-not $NoDll) {
    # 部署文件集（..\docs\deploy-windows-verify.md §2）：exe + 4 个 DLL。
    # 缺 libcangjie-runtime.dll 会启动即失败；缺两个 OpenSSL 3 DLL 则 crypto 运行时才报错。
    # 前两个来自仓颉 SDK（装了编译器就有）；后两个按 Resolve-OpenSslDir 的顺序解析。
    $ossl = Resolve-OpenSslDir $Vendor $OpenSslDir
    Write-Host "[build] OpenSSL DLL 来源：$ossl"
    # N-23：与 EXPECTED.sha256 比对（**告警不拒绝**）。这两个 DLL 决定部署包的密码哈希与 TLS
    # 实现，却来自"谁放了一份 / Git 升级到哪个版本"这种不受控位置 —— 换机器就可能静默换掉。
    $expFile = Join-Path $Vendor "deps\openssl\EXPECTED.sha256"
    if (Test-Path $expFile) {
        $exp = @{}
        foreach ($ln in (Get-Content $expFile -Encoding UTF8)) {
            if ($ln -match '^\s*#|^\s*$') { continue }
            $m = [regex]::Match($ln, '^([0-9a-f]{64})\s+(.+)$')
            if ($m.Success) { $exp[$m.Groups[2].Value.Trim()] = $m.Groups[1].Value }
        }
        foreach ($n in @("libcrypto-3-x64.dll", "libssl-3-x64.dll")) {
            $p = Join-Path $ossl $n
            $got = (Get-FileHash $p -Algorithm SHA256).Hash.ToLower()
            $ver = (Get-Item $p).VersionInfo.FileVersion
            if ($exp.ContainsKey($n) -and $exp[$n] -ne $got) {
                Write-Host "[build] ⚠ OpenSSL 与 EXPECTED.sha256 不一致：$n" -ForegroundColor Yellow
                Write-Host "[build]    期望 $($exp[$n])" -ForegroundColor Yellow
                Write-Host "[build]    实际 $got（版本 $ver，来自 $ossl）" -ForegroundColor Yellow
                Write-Host "[build]    这会把不同的密码学实现打进部署包；有意更换请改 deps\openssl\EXPECTED.sha256" -ForegroundColor Yellow
            } else {
                Write-Host "[build]   $n  $ver  $($got.Substring(0, 16))…  与 EXPECTED 一致"
            }
        }
    } else {
        Write-Host "[build] 提示：deps\openssl\EXPECTED.sha256 不存在 —— 跳过运行时库比对（N-23）"
    }
    $dlls = @(
        @{ n = "libcangjie-runtime.dll"; d = $RuntimeDir },
        @{ n = "libboundscheck.dll";     d = $RuntimeDir },
        @{ n = "libcrypto-3-x64.dll";    d = $ossl },
        @{ n = "libssl-3-x64.dll";       d = $ossl }
    )
    foreach ($x in $dlls) {
        $p = Join-Path $x.d $x.n
        if (-not (Test-Path $p)) { throw "缺少依赖 DLL：$p" }
        Copy-Item $p $outDir -Force
    }
    Write-Host "[build] 已复制 4 个依赖 DLL 到 $outDir\"
}
