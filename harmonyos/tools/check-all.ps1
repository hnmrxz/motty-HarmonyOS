# 一条命令跑完静态门禁：build + lint + check-ids + check-paging
# 用法: powershell harmonyos\tools\check-all.ps1
$ErrorActionPreference = "Continue"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location (Join-Path $root "harmonyos\ohos\app")
Write-Host "== build ==" -ForegroundColor Cyan
$build = & "C:\Users\Administrator\AppData\Roaming\npm\devecocli.ps1" build 2>&1
$buildLine = ($build | Select-String -Pattern "BUILD SUCCESSFUL|BUILD FAILED" | Select-Object -First 1).Line
Write-Host ("build: " + $buildLine)
if ($buildLine -notmatch "SUCCESSFUL") { $build | Select-Object -Last 15; exit 1 }
Set-Location $root
Write-Host "== spec/lint ==" -ForegroundColor Cyan
& C:\Python315\python.exe harmonyos\spec\lint.py | Select-Object -Last 1
if ($LASTEXITCODE -ne 0) { exit 1 }
Write-Host "== check-ids ==" -ForegroundColor Cyan
& C:\Python315\python.exe harmonyos\tools\check-ids.py | Select-Object -Last 2
if ($LASTEXITCODE -ne 0) { exit 1 }
Write-Host "== check-paging ==" -ForegroundColor Cyan
& C:\Python315\python.exe harmonyos\tools\check-paging.py | Select-Object -Last 1
if ($LASTEXITCODE -ne 0) { exit 1 }
Write-Host "== check-contrast ==" -ForegroundColor Cyan
& C:\Python315\python.exe harmonyos\tools\check-contrast.py | Select-Object -Last 1
if ($LASTEXITCODE -ne 0) { exit 1 }
Write-Host "== check-actions ==" -ForegroundColor Cyan
& C:\Python315\python.exe harmonyos\tools\check-actions.py | Select-Object -Last 2
if ($LASTEXITCODE -ne 0) { exit 1 }
Write-Host "ALL STATIC GATES PASSED" -ForegroundColor Green
