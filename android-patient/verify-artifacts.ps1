param(
  [Parameter(Mandatory = $true)][string]$ApkPath,
  [string]$AabPath = ''
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $ApkPath -PathType Leaf)) { throw "APK not found: $ApkPath" }
if ($AabPath -and -not (Test-Path -LiteralPath $AabPath -PathType Leaf)) { throw "AAB not found: $AabPath" }
function Test-SignerJava([string]$Candidate) {
  if ([string]::IsNullOrWhiteSpace($Candidate)) { return $false }
  foreach ($relativePath in @('bin\java.exe', 'bin\server\jvm.dll', 'lib\modules')) {
    if (-not (Test-Path -LiteralPath (Join-Path $Candidate $relativePath) -PathType Leaf)) { return $false }
  }
  return $true
}
function Resolve-SignerJava {
  if ($env:JAVA_HOME) {
    if (-not (Test-SignerJava $env:JAVA_HOME)) { throw 'JAVA_HOME 的 Java 运行文件不完整：需要 bin\java.exe、bin\server\jvm.dll 和 lib\modules。请指向完整 JDK 17。' }
    return (Resolve-Path -LiteralPath $env:JAVA_HOME).Path
  }
  $workspaceJdk = Join-Path $PSScriptRoot '..\.build-tools\jdk17'
  if (Test-Path -LiteralPath $workspaceJdk -PathType Container) {
    if (Test-SignerJava $workspaceJdk) { return (Resolve-Path -LiteralPath $workspaceJdk).Path }
    foreach ($candidate in (Get-ChildItem -LiteralPath $workspaceJdk -Directory | Sort-Object Name -Descending)) {
      if (Test-SignerJava $candidate.FullName) { return $candidate.FullName }
    }
  }
  $javaCommand = Get-Command java.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($javaCommand) {
    $candidate = Split-Path (Split-Path $javaCommand.Source -Parent) -Parent
    if (Test-SignerJava $candidate) { return $candidate }
  }
  throw 'apksigner 需要可用 Java：设置 JAVA_HOME 为完整 JDK 17，或放到仓库 .build-tools\jdk17\<版本>；也可将完整 JDK 的 bin 加入 PATH。'
}
# Standalone verification must not depend on a previous build process environment.
# Locate necessary runtime files only; this discovery never invokes java.
$signerJavaHome = Resolve-SignerJava
$env:JAVA_HOME = $signerJavaHome
$env:Path = (Join-Path $signerJavaHome 'bin') + ';' + $env:Path
$command = Get-Command apksigner.bat, apksigner -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$signerPath = if ($command) { $command.Source } else { '' }
if (-not $signerPath) {
  $sdkCandidates = @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME)
  $properties = Join-Path $PSScriptRoot 'local.properties'
  if (Test-Path -LiteralPath $properties) {
    $entry = Select-String -LiteralPath $properties -Pattern '^\s*sdk\.dir\s*=\s*(.+)$' | Select-Object -First 1
    if ($entry) { $sdkCandidates += $entry.Matches[0].Groups[1].Value.Trim().Replace('\\', '\').Replace('\:', ':') }
  }
  if ($env:LOCALAPPDATA) { $sdkCandidates += Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
  $sdkCandidates += 'C:\Android\Sdk'
  foreach ($sdkCandidate in $sdkCandidates) {
    if ([string]::IsNullOrWhiteSpace($sdkCandidate)) { continue }
    $toolsDirectory = Join-Path $sdkCandidate 'build-tools'
    if (-not (Test-Path -LiteralPath $toolsDirectory -PathType Container)) { continue }
    $versions = Get-ChildItem -LiteralPath $toolsDirectory -Directory | Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } | Sort-Object { [version]$_.Name } -Descending
    foreach ($versionDirectory in $versions) {
      $candidate = Join-Path $versionDirectory.FullName 'apksigner.bat'
      if (Test-Path -LiteralPath $candidate -PathType Leaf) { $signerPath = $candidate; break }
    }
    if ($signerPath) { break }
  }
}
if (-not $signerPath) { throw '未找到 apksigner：设置 ANDROID_SDK_ROOT / ANDROID_HOME 或 local.properties，并安装 Android SDK Build-Tools。' }
& $signerPath verify --verbose --print-certs $ApkPath
if ($LASTEXITCODE -ne 0) { throw "APK 签名校验失败，退出码 $LASTEXITCODE。" }
$result = [ordered]@{
  apk = (Resolve-Path -LiteralPath $ApkPath).Path
  apk_sha256 = (Get-FileHash -LiteralPath $ApkPath -Algorithm SHA256).Hash
}
if ($AabPath) {
  $result.aab = (Resolve-Path -LiteralPath $AabPath).Path
  $result.aab_sha256 = (Get-FileHash -LiteralPath $AabPath -Algorithm SHA256).Hash
}
# AAB hashing does not verify its signature or installation.
$result | ConvertTo-Json
