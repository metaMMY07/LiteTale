param([string]$Device = 'emulator-5556', [switch]$SkipBuild, [string]$Target = 'integration_test/android_motion_test.dart')
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
$env:JAVA_HOME = 'D:\CodexToolchains\jdk17\jdk-17.0.16+8'
$env:ANDROID_HOME = 'D:\Codex-Migrated\Android\Sdk'
$env:GRADLE_USER_HOME = 'D:\CodexToolchains\gradle'
$env:CARGO_HOME = 'D:\CodexToolchains\cargo'
$env:RUSTUP_HOME = 'D:\CodexToolchains\rustup'
$env:CARGO_BUILD_JOBS = '4'
$env:PUB_CACHE = 'D:\CodexToolchains\pub-cache'
$env:HTTPS_PROXY = 'http://127.0.0.1:10808'
$env:JAVA_TOOL_OPTIONS = '-Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=10808 -Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=10808'
$env:PATH = "$env:JAVA_HOME\bin;$env:CARGO_HOME\bin;$env:PATH"
$flutter = 'D:\CodexToolchains\flutter-3.29.3\flutter\bin\flutter.bat'
$adb = "$env:ANDROID_HOME\platform-tools\adb.exe"
$aapt = "$env:ANDROID_HOME\build-tools\35.0.0\aapt.exe"
$versionLine = (Select-String -Path pubspec.yaml -Pattern '^version:').Line
if ($versionLine -notmatch '^version: (.+)\+(\d+)$') { throw 'Missing pubspec version.' }
$version = $Matches[1]
# A universal profile APK otherwise has a lower versionCode than split release.
$code = 4000 + [int]$Matches[2]
$installed = & $adb -s $Device shell dumpsys package io.github.metammy07.novels
if ($LASTEXITCODE -ne 0) { throw 'Device inspection failed.' }
if (($installed -join "`n") -match 'versionCode=(\d+)' -and [int]$Matches[1] -gt $code) {
    throw 'Installed app is newer. Refusing to downgrade or uninstall it.'
}
if (!$SkipBuild) {
    & $flutter build apk --profile --target-platform android-x64 --target $Target --build-name $version --build-number $code --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Test build failed.' }
}
$apk = 'build/app/outputs/flutter-apk/app-profile.apk'
$metadata = & $aapt dump badging $apk
$metadataText = $metadata -join "`n"
if ($LASTEXITCODE -ne 0 -or $metadataText -notmatch "versionCode='$code'" -or $metadataText -notmatch "versionName='$([regex]::Escape($version))'" -or $metadataText -notmatch "package: name='io.github.metammy07.novels'") { throw 'Unexpected test APK metadata.' }
Write-Output "Test APK: $apk; SHA256=$((Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash)"
# Verify a data-preserving install first. Never let Flutter's uninstall/retry
# fallback handle an installation failure.
& $adb -s $Device install -r $apk
if ($LASTEXITCODE -ne 0) { throw 'In-place installation failed. No uninstall attempted.' }
# Drive's normal start can uninstall on installation failure, and its normal
# stop also uninstalls. Attach to our explicitly installed/running app instead.
& $adb -s $Device shell am force-stop io.github.metammy07.novels
& $adb -s $Device shell am start -n io.github.metammy07.novels/opensource.wild.MainActivity --ez start-paused true
if ($LASTEXITCODE -ne 0) { throw 'Test app launch failed.' }
$watch = [Diagnostics.Stopwatch]::StartNew()
$deviceService = $null
while (!$deviceService -and $watch.Elapsed.TotalSeconds -lt 30) {
    $appProcess = & $adb -s $Device shell pidof io.github.metammy07.novels
    if ($appProcess) {
        $vmLogs = & $adb -s $Device logcat -d --pid=$appProcess -s flutter:I
        if (($vmLogs -join "`n") -match 'VM service is listening on (http://[^\s]+)') {
            $deviceService = [Uri]$Matches[1]
        }
    }
    if (!$deviceService) { Start-Sleep -Milliseconds 300 }
}
if (!$deviceService) { throw 'VM service unavailable; app left installed.' }
$hostPort = & $adb -s $Device forward tcp:0 "tcp:$($deviceService.Port)"
if ($LASTEXITCODE -ne 0 -or $hostPort -notmatch '^\d+$') { throw 'VM port forwarding failed.' }
try {
    $service = [UriBuilder]$deviceService
    $service.Host = '127.0.0.1'
    $service.Port = [int]$hostPort
    & $flutter drive --profile --no-pub --driver test_driver/android_motion.dart --target $Target --use-existing-app $service.Uri.AbsoluteUri --keep-app-running -d $Device
    if ($LASTEXITCODE -ne 0) { throw 'Device tests failed; app left installed.' }
} finally {
    & $adb -s $Device forward --remove "tcp:$hostPort"
}
