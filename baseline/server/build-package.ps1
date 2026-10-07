# 生成可直接拷到服务器的部署目录
#
# 产出：server\dist\club-server\
#   club-server.exe
#   libcangjie-runtime.dll / libboundscheck.dll / libcrypto-3-x64.dll / libssl-3-x64.dll
#   certs\cert.pem / certs\key.pem
#   start-http.cmd / start-https.cmd
#   README.txt
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\build-package.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\build-package.ps1 -SkipCert   # 不带证书

param(
    [string]$CangjieHome = "D:\Cangjie",
    [string]$CertDir     = "",
    [switch]$SkipCert
)

$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
$dist = Join-Path $root "dist\club-server"
$exe  = Join-Path $root "build\club-server.exe"

if (-not (Test-Path $exe)) { throw "找不到 $exe，先跑 build.ps1" }

if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
New-Item -ItemType Directory -Force -Path $dist | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $dist "certs") | Out-Null

# ---------- 1. 制品 ----------
Copy-Item $exe (Join-Path $dist "club-server.exe") -Force

# 4 个依赖 DLL 全部从 build\ 取 —— 那是 build.ps1 已经解析并拷好的（连 OpenSSL 的来源判定
# 也在那边），本脚本因此不必再关心"OpenSSL 从哪儿来"。
$buildDir = Join-Path $root "build"
foreach ($n in @("libcangjie-runtime.dll", "libboundscheck.dll", "libcrypto-3-x64.dll", "libssl-3-x64.dll")) {
    $src = Join-Path $buildDir $n
    if (-not (Test-Path $src)) { throw "缺少依赖 DLL：$src —— 请先跑 build.ps1（**不要**加 -NoDll）" }
    Copy-Item $src $dist -Force
}

# N-23：把**实际打包进去**的运行时库版本与哈希写进部署包 —— 部署方因此能回答
# "这份包用的是哪个 OpenSSL"，而不是只能相信"当时是从哪儿拷的"。
$dllInfo = @("# 本部署包使用的运行时库（构建时记录，便于追溯）", "")
foreach ($n in @("libcangjie-runtime.dll", "libboundscheck.dll", "libcrypto-3-x64.dll", "libssl-3-x64.dll")) {
    $p = Join-Path $buildDir $n
    $dllInfo += ("{0,-26} version={1,-16} sha256={2}" -f $n, (Get-Item $p).VersionInfo.FileVersion, (Get-FileHash $p -Algorithm SHA256).Hash.ToLower())
}
Set-Content -Path (Join-Path $dist "dll-versions.txt") -Value $dllInfo -Encoding UTF8

# ---------- 2. 证书 ----------
if (-not $SkipCert) {
    if ([string]::IsNullOrEmpty($CertDir)) { $CertDir = Join-Path $root "certs" }
    $c = Join-Path $CertDir "cert.pem"
    $k = Join-Path $CertDir "key.pem"
    if ((Test-Path $c) -and (Test-Path $k)) {
        Copy-Item $c (Join-Path $dist "certs\cert.pem") -Force
        Copy-Item $k (Join-Path $dist "certs\key.pem") -Force
    } else {
        Write-Host "[pkg] 警告：$CertDir 下没有证书，未包含 certs\（部署前必须补上）"
    }
}

# ---------- 3. 启动脚本（cwd 必须是 exe 所在目录，所以脚本自己 cd 过去） ----------
$httpCmd = @'
@echo off
rem 切到 UTF-8 代码页：服务端的日志/报错是中文，cmd 默认 936 会显示成乱码。
chcp 65001 >nul
rem 明文 HTTP。仅用于本机调试；正式使用请用 start-https.cmd。
cd /d "%~dp0"
club-server.exe serve 8080 mysql://root:<口令>@127.0.0.1:3306/club_server
'@
# 按 ANSI 写：cmd.exe 默认按 ANSI（中文 Windows 是 GBK）读 .cmd，
# 用 -Encoding ASCII 会把上面的中文注释整行变成 "?"。
[IO.File]::WriteAllText((Join-Path $dist "start-http.cmd"), $httpCmd, [Text.Encoding]::Default)

$httpsCmd = @'
@echo off
rem 切到 UTF-8 代码页（同 start-http.cmd）。
chcp 65001 >nul
rem HTTPS（框架原生 TLS，不用 Nginx）。端口/数据目录/证书路径都可改。
cd /d "%~dp0"
club-server.exe serve-tls 8443 mysql://root:<口令>@127.0.0.1:3306/club_server --cert certs\cert.pem --key certs\key.pem
'@
# 按 ANSI 写：cmd.exe 默认按 ANSI（中文 Windows 是 GBK）读 .cmd，
# 用 -Encoding ASCII 会把上面的中文注释整行变成 "?"。
[IO.File]::WriteAllText((Join-Path $dist "start-https.cmd"), $httpsCmd, [Text.Encoding]::Default)

# ---------- 4. 说明 ----------
$readme = @'
社团管理工具 · 服务端部署包
============================

一、这是什么
  社团内部管理工具的服务端。仓颉 1.1.3 + 轻舟框架。
  ⚠ 数据存进 **MySQL**（2026-09-20 起，路线 B：只换持久化层）—— 部署前请准备一台可连的
  MySQL / MariaDB，库与表会自动建。审计日志仍写本地 data\audit.log。

二、部署文件（制品 5 个：exe + 4 个 DLL；连证书 2、启动脚本 2 共 9 个文件，另有本说明与 dll-versions.txt）
  club-server.exe              服务端本体
  libcangjie-runtime.dll       仓颉运行时（缺了会启动即失败）
  libboundscheck.dll           仓颉运行时的传递依赖
  libcrypto-3-x64.dll          OpenSSL 3，密码哈希与 TLS 要用
  libssl-3-x64.dll             OpenSSL 3，TLS 要用
  certs\cert.pem               自签证书（必须带 SAN，见第五节）
  certs\key.pem                私钥（机密，不要外传、不要入库）
  start-http.cmd               HTTP 启动脚本
  start-https.cmd              HTTPS 启动脚本

  说明：两个 OpenSSL DLL 不在 exe 的导入表里，是运行时才 dlopen 的。
  缺了它们编译期没有任何警告，运行时才报错，所以必须一起拷。

三、首次部署
  1. 本目录必须在服务端机器上（同平台 Windows x64，制品可直接复用，服务器不需要装编译器）。
  2. 初始化首任会长，同时会写入 4 个组织与一个随机注册口令：

       club-server.exe init-admin 13800000000 你的密码123 mysql://root:<口令>@127.0.0.1:3306/club_server

  3. 启动 HTTPS：

       start-https.cmd

     等价于：

       club-server.exe serve-tls 8443 mysql://root:<口令>@127.0.0.1:3306/club_server --cert certs\cert.pem --key certs\key.pem

  4. 放行端口：Windows 防火墙与云安全组是两层，都要放行 8443。
     只做一层，从外面就是连不上。

四、重要：工作目录
  certs\ 与审计日志目录（data\）都是按相对路径读的，所以**必须在本目录里启动**。
  业务数据在 MySQL 里（不在本目录），连接参数由启动命令的 DSN / --mysql-* 决定。
  start-http.cmd / start-https.cmd 已经做了 cd，直接双击即可。
  用任务计划程序做开机自启时，也要把"起始位置"设成本目录。

五、证书必须带 SAN
  现代 TLS 客户端完全忽略 CN，只看 subjectAltName。仅 CN 的证书在真实使用中等同于无效。
  本包里的证书是给本机调试用的（SAN 为 IP:127.0.0.1 与 localhost）。
  部署到公网服务器时请按真实公网 IP 重新生成：

    openssl req -x509 -newkey rsa:2048 -nodes ^
      -keyout certs\key.pem -out certs\cert.pem ^
      -days 3650 -subj "/C=CN/O=Club/CN=你的公网IP" ^
      -addext "subjectAltName=IP:你的公网IP,DNS:localhost"

  生成后用下面这条自检（应当输出 OK）：

    openssl verify -CAfile certs\cert.pem -verify_ip 你的公网IP certs\cert.pem

六、验证服务是否正常
  1. 健康检查（不需要认证，不带 /api 前缀）：

       curl -k https://127.0.0.1:8443/health

     期望 200 且返回 {"ok":true,...}。用浏览器自带的证书校验会报错，那是自签证书的正常现象。

  2. 确认只允许 TLS 1.2 及以上（1.0/1.1 必须被服务端拒绝）：

       openssl s_client -connect <服务器IP>:8443 -tls1_2 -brief
       openssl s_client -connect <服务器IP>:8443 -tls1_3 -brief
       openssl s_client -connect <服务器IP>:8443 -tls1_1 -cipher "DEFAULT@SECLEVEL=0" -brief

     前两条应当握手成功，第三条应当报 alert protocol version。
     第三条必须加 @SECLEVEL=0，否则是客户端自己不肯发起，属于假阴性。

七、日常运维
  - 优雅关闭：在服务器本机执行

      curl -k -X POST https://127.0.0.1:8443/admin/shutdown

    该端点仅允许本机访问，远程会返回 403。

  - 数据与备份：业务数据在 **MySQL**（一个库、9 张表）。请把那个库纳入每日备份（mysqldump），
    并至少交接给两个人 —— 这是唯一丢了就没了的东西。data\ 下另有 audit.log，也一并备份。

  - 日志：控制台输出（请求日志、错误）。敏感操作另记 data\audit.log（文件，不入库）
    （重置密码、更换注册口令、移出成员、会长移交、删除部门与课题）。

八、常见问题
  - 启动即失败并提示缺少 libcangjie-runtime.dll：4 个 DLL 没有和 exe 放在一起。
  - 密码哈希或 TLS 报错、返回 500：两个 OpenSSL DLL 缺失或版本不对。
  - 从外部连不上但本机正常：防火墙或云安全组只放行了一层。
  - 客户端报证书名称不匹配：证书没有 SAN，或 SAN 里没有客户端实际使用的地址。
'@
Set-Content -Path (Join-Path $dist "README.txt") -Value $readme -Encoding UTF8

Write-Host "[pkg] 部署目录已生成：$dist"
Get-ChildItem $dist -Recurse -File | ForEach-Object {
    "{0,10:N0}  {1}" -f $_.Length, $_.FullName.Substring($dist.Length + 1)
}
$total = (Get-ChildItem $dist -Recurse -File | Measure-Object -Property Length -Sum).Sum
Write-Host ("[pkg] 合计 {0:N1} MB" -f ($total / 1MB))
