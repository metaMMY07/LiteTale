param(
    [string]$Version = '0.0.18-dev.1',
    [int]$BuildNumber = 18,
    [string]$Toolchains = 'D:\CodexToolchains',
    [string]$AndroidSdk = "$env:LOCALAPPDATA\Android\sdk",
    [string]$Proxy = 'http://127.0.0.1:10808'
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$env:JAVA_HOME = Join-Path $Toolchains 'jdk17\jdk-17.0.16+8'
$env:ANDROID_HOME = $AndroidSdk
$env:GRADLE_USER_HOME = Join-Path $Toolchains 'gradle'
$env:CARGO_HOME = Join-Path $Toolchains 'cargo'
$env:RUSTUP_HOME = Join-Path $Toolchains 'rustup'
$env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-msvc'
$env:CARGO_BUILD_JOBS = '4'
$env:PUB_CACHE = Join-Path $Toolchains 'pub-cache'
$flutterRoot = Join-Path $Toolchains 'flutter-3.29.3\flutter'
$env:PATH = "$env:JAVA_HOME\bin;$env:CARGO_HOME\bin;$flutterRoot\bin;$env:PATH"
if ($Proxy) {
    $proxyUri = [Uri]$Proxy
    $env:HTTPS_PROXY = $Proxy
    $env:JAVA_TOOL_OPTIONS = "-Dhttps.proxyHost=$($proxyUri.Host) -Dhttps.proxyPort=$($proxyUri.Port) -Dhttp.proxyHost=$($proxyUri.Host) -Dhttp.proxyPort=$($proxyUri.Port)"
}
Set-Location $projectRoot
$localProperties = "sdk.dir=$($AndroidSdk.Replace('\','\\'))`nflutter.sdk=$($flutterRoot.Replace('\','\\'))`n"
[IO.File]::WriteAllText((Join-Path $projectRoot 'android\local.properties'), $localProperties)
& "$flutterRoot\bin\flutter.bat" pub get 2>&1 | Tee-Object -Variable dependencyOutput
if ($LASTEXITCODE -ne 0) {
    # Android builds work without desktop plugin symlinks on this machine.
    # Never suppress a dependency resolution failure.
    $dependencyText = $dependencyOutput -join "`n"
    if ($dependencyText -notmatch 'Got dependencies!' -or $dependencyText -notmatch 'symlink support' -or !(Test-Path '.dart_tool\package_config.json') -or !(Test-Path '.flutter-plugins-dependencies')) {
        throw 'Flutter dependencies were not resolved.'
    }
    Write-Warning 'Retrying dependency setup after the desktop symlink warning.'
    & "$flutterRoot\bin\flutter.bat" pub get
    if ($LASTEXITCODE -ne 0) { throw 'Plugin registration is incomplete; enable Windows Developer Mode and rerun.' }
}
& "$flutterRoot\bin\flutter.bat" build apk --release --target-platform android-arm64,android-x64 --split-per-abi --build-name $Version --build-number $BuildNumber --no-pub
if ($LASTEXITCODE -ne 0) { throw 'Android release build failed.' }
Write-Output "APKs: $projectRoot\build\app\outputs\flutter-apk"
