$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$flutterRoot = 'C:\src\flutter'
$art = Join-Path $flutterRoot 'bin\cache\artifacts\engine\windows-x64'
$proj = 'C:\heinplay\hain_tv'
$eph = Join-Path $proj 'windows\flutter\ephemeral'

Write-Host "=== engine artifacts windows-x64 ==="
if (Test-Path $art) {
    Get-ChildItem $art | ForEach-Object { Write-Host ("  " + $_.Name) }
} else {
    Write-Host "  NOT FOUND: $art"
}

Write-Host ""
Write-Host "=== flutter_windows.h locations ==="
foreach ($root in @($art, $flutterRoot, $proj)) {
    Get-ChildItem $root -Recurse -Filter 'flutter_windows.h' -ErrorAction SilentlyContinue |
        Select-Object -First 5 | ForEach-Object { Write-Host ("  " + $_.FullName) }
}

Write-Host ""
Write-Host "=== flutter_texture_registrar.h locations ==="
foreach ($root in @($art, $flutterRoot)) {
    Get-ChildItem $root -Recurse -Filter 'flutter_texture_registrar.h' -ErrorAction SilentlyContinue |
        Select-Object -First 5 | ForEach-Object { Write-Host ("  " + $_.FullName) }
}

Write-Host ""
Write-Host "=== ephemeral dir ==="
if (Test-Path $eph) {
    Get-ChildItem $eph | ForEach-Object { Write-Host ("  " + $_.Name) }
} else {
    Write-Host "  NOT FOUND: $eph"
}

Write-Host ""
Write-Host "=== generated_plugins.cmake (include dirs it sets) ==="
$gp = Join-Path $proj 'windows\flutter\generated_plugins.cmake'
if (Test-Path $gp) { Get-Content $gp -TotalCount 40 } else { Write-Host "  NOT FOUND" }

Write-Host ""
Write-Host "=== windows/flutter/CMakeLists.txt include dirs ==="
$cm = Join-Path $proj 'windows\flutter\CMakeLists.txt'
if (Test-Path $cm) {
    Select-String -Path $cm -Pattern 'include_directories|target_include_directories|FLUTTER_ROOT|EPHEMERAL' |
        ForEach-Object { Write-Host ("  " + $_.LineNumber + ": " + $_.Line.Trim()) }
} else { Write-Host "  NOT FOUND" }

Write-Host ""
Write-Host "=== engine version / windows artifacts dir list ==="
Get-ChildItem (Join-Path $flutterRoot 'bin\cache\artifacts\engine') -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host ("  " + $_.Name) }

Write-Host ""
Write-Host "=== probe done ==="
