param(
  [ValidateSet('debug','release')][string]$Variant = 'debug',
  [switch]$Offline,
  [switch]$Bundle,
  [string]$ApiBaseUrl = ''
)
$ErrorActionPreference = 'Stop'

function Test-CompleteJdk([string]$Candidate) {
  if ([string]::IsNullOrWhiteSpace($Candidate)) { return $false }
  foreach ($tool in @('java.exe','javac.exe','jlink.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $Candidate "bin\$tool") -PathType Leaf)) { return $false }
  }
  return $true
}
function Resolve-Jdk {
  # Explicit selection wins; a broken JAVA_HOME is not silently replaced.
  if ($env:JAVA_HOME) {
    if (-not (Test-CompleteJdk $env:JAVA_HOME)) { throw 'JAVA_HOME 必须指向完整 JDK（包含 java.exe、javac.exe、jlink.exe），不能是 JRE。' }
    return (Resolve-Path -LiteralPath $env:JAVA_HOME).Path
  }
  $workspaceJdk = Join-Path $PSScriptRoot '..\.build-tools\jdk17'
  if (Test-Path -LiteralPath $workspaceJdk -PathType Container) {
    if (Test-CompleteJdk $workspaceJdk) { return (Resolve-Path -LiteralPath $workspaceJdk).Path }
    foreach ($candidate in (Get-ChildItem -LiteralPath $workspaceJdk -Directory | Sort-Object Name -Descending)) {
      if (Test-CompleteJdk $candidate.FullName) { return $candidate.FullName }
    }
  }
  $javaCommand = Get-Command java.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($javaCommand) {
    $candidate = Split-Path (Split-Path $javaCommand.Source -Parent) -Parent
    if (Test-CompleteJdk $candidate) { return $candidate }
  }
  throw '未找到完整 JDK：设置 JAVA_HOME 为 JDK 17，或解压到仓库 .build-tools\jdk17\<版本>。'
}
$jdkHome = Resolve-Jdk
# Capture java stderr without triggering PowerShell 5.1 native error handling.
$versionOutput = [IO.Path]::GetTempFileName()
$versionError = [IO.Path]::GetTempFileName()
try {
  $javaProcess = Start-Process -FilePath (Join-Path $jdkHome 'bin\java.exe') -ArgumentList '-version' -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $versionOutput -RedirectStandardError $versionError
  $versionText = [IO.File]::ReadAllText($versionOutput) + [IO.File]::ReadAllText($versionError)
  $versionMatch = [regex]::Match($versionText, 'version "(\d+)')
  if ($javaProcess.ExitCode -ne 0 -or -not $versionMatch.Success) { throw '无法读取 JDK 版本。' }
  $javaMajor = [int]$versionMatch.Groups[1].Value
  if ($javaMajor -lt 17 -or $javaMajor -gt 21) { throw 'Gradle 8.7 / AGP 8.5.2 请使用 JDK 17～21，推荐 JDK 17。' }
} finally {
  Remove-Item -LiteralPath $versionOutput, $versionError -Force -ErrorAction SilentlyContinue
}
$env:JAVA_HOME = $jdkHome
$env:Path = (Join-Path $jdkHome 'bin') + ';' + $env:Path
Write-Host "[build] JDK: $jdkHome"

function Resolve-AndroidSdk {
  $candidates = @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME)
  $properties = Join-Path $PSScriptRoot 'local.properties'
  if (Test-Path -LiteralPath $properties) {
    $entry = Select-String -LiteralPath $properties -Pattern '^\s*sdk\.dir\s*=\s*(.+)$' | Select-Object -First 1
    if ($entry) { $candidates += $entry.Matches[0].Groups[1].Value.Trim().Replace('\\', '\').Replace('\:', ':') }
  }
  if ($env:LOCALAPPDATA) { $candidates += Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
  $candidates += 'C:\Android\Sdk'
  foreach ($candidate in $candidates) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    if (Test-Path -LiteralPath (Join-Path $candidate 'platforms\android-35\android.jar') -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
  }
  throw '未找到 Android SDK Platform 35。设置 ANDROID_SDK_ROOT，或安装 platforms;android-35。'
}
$sdkRoot = Resolve-AndroidSdk
if (-not (Test-Path -LiteralPath (Join-Path $sdkRoot 'build-tools\34.0.0\aapt2.exe') -PathType Leaf)) { throw 'SDK 缺少 AGP 8.5.2 默认使用的 Build-Tools 34.0.0，请通过 SDK Manager 安装。' }
$env:ANDROID_SDK_ROOT = $sdkRoot
$env:ANDROID_HOME = $sdkRoot
$env:Path = (Join-Path $sdkRoot 'platform-tools') + ';' + $env:Path
Write-Host "[build] Android SDK: $sdkRoot"
# Forward slashes avoid Java Properties escaping; preserve unrelated local keys.
$properties = Join-Path $PSScriptRoot 'local.properties'
$lines = @(if (Test-Path -LiteralPath $properties) { Get-Content -LiteralPath $properties -Encoding UTF8 | Where-Object { $_ -notmatch '^\s*sdk\.dir\s*=' } })
$lines += 'sdk.dir=' + $sdkRoot.Replace('\', '/')
$propertiesText = ($lines -join [Environment]::NewLine) + [Environment]::NewLine
if (-not (Test-Path -LiteralPath $properties) -or [IO.File]::ReadAllText($properties) -ne $propertiesText) {
  [IO.File]::WriteAllText($properties, $propertiesText, [Text.UTF8Encoding]::new($false))
}

$wrapper = Join-Path $PSScriptRoot 'gradlew.bat'
foreach ($file in @($wrapper, (Join-Path $PSScriptRoot 'gradle\wrapper\gradle-wrapper.jar'), (Join-Path $PSScriptRoot 'gradle\wrapper\gradle-wrapper.properties'))) {
  if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Gradle Wrapper 文件缺失，请恢复完整工程文件：$file" }
}
if ($Bundle -and $Variant -ne 'release') { throw '-Bundle 仅用于 release 构建。' }
if ($Variant -eq 'release') {
  $releaseUrl = if ($ApiBaseUrl) { $ApiBaseUrl } else { $env:API_BASE_URL }
  $parsedUrl = $null
  if (-not [Uri]::TryCreate($releaseUrl, [UriKind]::Absolute, [ref]$parsedUrl) -or $parsedUrl.Scheme -ne 'https' -or -not $parsedUrl.Host -or $parsedUrl.UserInfo) { throw 'release 必须提供有效且不带凭据的 HTTPS API 地址（-ApiBaseUrl 或 API_BASE_URL）。' }
  foreach ($name in @('ANDROID_KEYSTORE_PATH','ANDROID_KEYSTORE_PASSWORD','ANDROID_KEY_ALIAS','ANDROID_KEY_PASSWORD')) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) { throw "release 缺少环境变量 $name" }
  }
  if (-not (Test-Path -LiteralPath $env:ANDROID_KEYSTORE_PATH -PathType Leaf)) { throw 'ANDROID_KEYSTORE_PATH 指向的 keystore 不存在。' }
  if (-not $ApiBaseUrl) { $ApiBaseUrl = $releaseUrl }
}
$buildArguments = @($(if ($Variant -eq 'release') { ':app:assembleRelease' } else { ':app:assembleDebug' }), '--no-daemon')
if ($Bundle) { $buildArguments += ':app:bundleRelease' }
if ($Offline) { $buildArguments += '--offline' }
if ($ApiBaseUrl) { $buildArguments += "-PapiBaseUrl=$ApiBaseUrl" }
Push-Location $PSScriptRoot
try {
  & $wrapper @buildArguments
  if ($LASTEXITCODE -ne 0) { throw "Gradle 构建失败，退出码 $LASTEXITCODE。" }
  Write-Host "[build] 完成：$Variant"
} finally { Pop-Location }
