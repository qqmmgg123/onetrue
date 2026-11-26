# Bake supabase/env.local then flutter run with --dart-define-from-file
# Usage:  .\run_app.ps1
#         .\run_app.ps1 -d chrome
# Extra args are forwarded to flutter run.

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

Write-Host "==> bake env.local -> dart_defines.json" -ForegroundColor Cyan
python tool/bake_env.py
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$defines = Join-Path $PSScriptRoot "supabase\dart_defines.json"
if (-not (Test-Path $defines)) {
    Write-Host "缺少 $defines，请先配置 supabase/env.local" -ForegroundColor Red
    exit 1
}

Write-Host "==> flutter run --dart-define-from-file=supabase/dart_defines.json" -ForegroundColor Cyan
& flutter run "--dart-define-from-file=$defines" @args
exit $LASTEXITCODE
