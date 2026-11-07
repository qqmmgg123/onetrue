# Bake supabase/env.local into APK, then build release.
# Usage:  .\build_apk.ps1
#         .\build_apk.ps1 -Install
#         .\build_apk.ps1 -Publish -Changelog "修复七牛上传"
#         .\build_apk.ps1 -Install -Publish -Changelog "……"
# 默认强制更新；若允许跳过加 -AllowSkip

param(
    [switch]$Install,
    [switch]$Publish,
    [string]$Changelog = "",
    [switch]$AllowSkip
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

Write-Host "==> bake env.local -> dart_defines.json" -ForegroundColor Cyan
python tool/bake_env.py
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$defines = Join-Path $PSScriptRoot "supabase\dart_defines.json"
Write-Host "==> flutter build apk --release" -ForegroundColor Cyan
# Quote path; DATABASE_URL must not contain unescaped '&' (see bake_env.py)
& flutter build apk --release "--dart-define-from-file=$defines"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$apk = Join-Path $PSScriptRoot "build\app\outputs\flutter-apk\app-release.apk"
Write-Host "APK: $apk" -ForegroundColor Green

function Resolve-Adb {
    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $sdkRoots = @()
    if ($env:ANDROID_HOME) { $sdkRoots += $env:ANDROID_HOME }
    if ($env:ANDROID_SDK_ROOT) { $sdkRoots += $env:ANDROID_SDK_ROOT }
    $lp = Join-Path $PSScriptRoot "android\local.properties"
    if (Test-Path $lp) {
        foreach ($line in Get-Content $lp) {
            if ($line -match '^\s*sdk\.dir\s*=\s*(.+)\s*$') {
                $sdkRoots += ($Matches[1] -replace '\\\\', '\').Trim()
            }
        }
    }
    $sdkRoots += @(
        (Join-Path $env:LOCALAPPDATA "Android\Sdk"),
        (Join-Path $env:USERPROFILE "AppData\Local\Android\Sdk")
    )
    foreach ($root in $sdkRoots) {
        if (-not $root) { continue }
        $adbPath = Join-Path $root "platform-tools\adb.exe"
        if (Test-Path $adbPath) { return $adbPath }
    }
    return $null
}

if ($Install) {
    $adb = Resolve-Adb
    if (-not $adb) {
        Write-Host "adb not found. Install Android platform-tools or add it to PATH." -ForegroundColor Red
        Write-Host "APK is ready, install manually: $apk" -ForegroundColor Yellow
        exit 1
    }
    Write-Host "adb: $adb" -ForegroundColor DarkGray
    $devices = & $adb devices | Select-String "device$"
    if (-not $devices) {
        Write-Host "No phone connected, skip install" -ForegroundColor Yellow
    } else {
        Write-Host "==> adb install -r" -ForegroundColor Cyan
        & $adb install -r $apk
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
}

if ($Publish) {
    Write-Host "==> publish APK + version.json to Qiniu" -ForegroundColor Cyan
    $pubArgs = @("tool/publish_apk.py", "--apk", $apk)
    if ($Changelog) { $pubArgs += @("--changelog", $Changelog) }
    if ($AllowSkip) { $pubArgs += "--no-force" } else { $pubArgs += "--force" }
    python @pubArgs
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
