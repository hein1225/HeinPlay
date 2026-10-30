$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "=== synced tree verification ==="

$proj = 'C:\heinplay\hain_tv'
$mpv  = Join-Path $proj 'third_party\mpv-windows'

foreach ($rel in @('bin\libmpv-2.dll', 'lib\mpv.lib', 'include\mpv\client.h', 'include\mpv\render.h')) {
    $p = Join-Path $mpv $rel
    if (Test-Path $p) {
        $f = Get-Item $p
        Write-Host ("  {0,-28} OK   {1} MB" -f $rel, [math]::Round($f.Length / 1MB, 1))
    } else {
        Write-Host ("  {0,-28} MISSING" -f $rel)
    }
}

Write-Host ""
Write-Host "--- native sources ---"
$srcDir = Join-Path $proj 'src\mpv_desktop'
if (Test-Path $srcDir) {
    Get-ChildItem $srcDir -File | Sort-Object Name | ForEach-Object {
        Write-Host ("  {0,-34} {1,8} B   {2}" -f $_.Name, $_.Length, $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))
    }
} else {
    Write-Host "  src\mpv_desktop MISSING"
}

Write-Host ""
Write-Host "--- project top level ---"
Get-ChildItem $proj | ForEach-Object {
    $kind = if ($_.PSIsContainer) { 'DIR ' } else { 'FILE' }
    Write-Host ("  {0} {1}" -f $kind, $_.Name)
}

Write-Host ""
Write-Host "--- runner ---"
$runner = Join-Path $proj 'windows\runner'
if (Test-Path $runner) {
    Get-ChildItem $runner -Recurse -File -Include '*.cpp', '*.h', 'CMakeLists.txt' | ForEach-Object {
        Write-Host ("  " + $_.FullName.Replace($proj, '.'))
    }
}

Write-Host ""
Write-Host "--- lib dart count ---"
$libDir = Join-Path $proj 'lib'
if (Test-Path $libDir) {
    $n = (Get-ChildItem $libDir -Recurse -File -Filter '*.dart').Count
    Write-Host ("  dart files: " + $n)
}

Write-Host ""
Write-Host "=== verification finished ==="
