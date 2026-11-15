# Bake supabase/env.local into APK, then build release.
# Usage:  .\build_apk.ps1
#         .\build_apk.ps1 -Install
#         .\build_apk.ps1 -Publish -Changelog "fix qiniu upload"
#         .\build_apk.ps1 -Install -Publish -Changelog "..."
# Default: force publish update; add -AllowSkip to allow skip

param(
    [switch]$Install,
    [switch]$Publish,
    [string]$Changelog = "",
    [switch]$AllowSkip
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

# Isolate Gradle home: user ~/.gradle often hits Binary store / registry.bin / jar locks on Windows
$env:GRADLE_USER_HOME = Join-Path $PSScriptRoot ".gradle-user"
New-Item -ItemType Directory -Force -Path $env:GRADLE_USER_HOME | Out-Null
Write-Host "==> GRADLE_USER_HOME=$env:GRADLE_USER_HOME" -ForegroundColor DarkGray

Write-Host "==> bake env.local -> dart_defines.json" -ForegroundColor Cyan
python tool/bake_env.py
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# supabase_flutter -> sign_in_with_apple defaults compileSdk 28; machine may lack android-28
# Must write UTF-8 without BOM or Gradle reports Unexpected character: '?'
$appleGradle = Join-Path $env:LOCALAPPDATA "Pub\Cache\hosted\pub.dev"
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
Get-ChildItem $appleGradle -Directory -Filter "sign_in_with_apple-*" -ErrorAction SilentlyContinue | ForEach-Object {
    $g = Join-Path $_.FullName "android\build.gradle"
    if (Test-Path $g) {
        $bytes = [System.IO.File]::ReadAllBytes($g)
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        $raw = [System.IO.File]::ReadAllText($g).TrimStart([char]0xFEFF)
        $patched = $false
        if ($raw -match 'compileSdkVersion\s+28') {
            $raw = $raw -replace 'compileSdkVersion\s+28', 'compileSdkVersion 34'
            $patched = $true
            Write-Host "note: $($_.Name) compileSdkVersion 28->34" -ForegroundColor DarkYellow
        }
        if ($hasBom -or $patched) {
            [System.IO.File]::WriteAllText($g, $raw, $utf8NoBom)
            if ($hasBom) { Write-Host "note: stripped UTF-8 BOM from $($_.Name) build.gradle" -ForegroundColor DarkYellow }
        }
    }
}

Write-Host "==> gradle --stop (best effort)" -ForegroundColor Cyan
Push-Location (Join-Path $PSScriptRoot "android")
try { & .\gradlew.bat --stop 2>$null | Out-Null } catch {}
Pop-Location
# Also stop any daemon still tied to the old user home
$oldTmp = Join-Path $env:USERPROFILE ".gradle\.tmp"
if (Test-Path $oldTmp) {
    Remove-Item -Recurse -Force $oldTmp -ErrorAction SilentlyContinue
}

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
