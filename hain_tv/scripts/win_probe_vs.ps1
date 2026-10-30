$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    Write-Host "vswhere NOT FOUND"
    exit 1
}

Write-Host "=== all VS installations ==="
$all = & $vswhere -products * -format json 2>$null | ConvertFrom-Json
foreach ($inst in $all) {
    Write-Host ("  {0}  |  {1}  |  {2}" -f $inst.displayName, $inst.installationVersion, $inst.installationPath)
}

Write-Host ""
Write-Host "=== instances with C++ (VC.Tools.x86.x64) ==="
$cpp = & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
if ($cpp) { $cpp | ForEach-Object { Write-Host ("  " + $_) } } else { Write-Host "  NONE - C++ workload missing" }

Write-Host ""
Write-Host "=== instances with Windows SDK component ==="
$sdkInst = & $vswhere -products * -requires Microsoft.VisualStudio.Component.Windows11SDK.* -property installationPath 2>$null
if (-not $sdkInst) {
    $sdkInst = & $vswhere -products * -requires Microsoft.VisualStudio.Component.Windows10SDK.* -property installationPath 2>$null
}
if ($sdkInst) { $sdkInst | ForEach-Object { Write-Host ("  " + $_) } } else { Write-Host "  NONE - Windows SDK component missing" }

Write-Host ""
Write-Host "=== Windows Kits (SDK) on disk ==="
$kits = "C:\Program Files (x86)\Windows Kits\10"
if (Test-Path $kits) {
    Get-ChildItem (Join-Path $kits "Include") -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host ("  Include version: " + $_.Name)
    }
    Get-ChildItem (Join-Path $kits "Lib") -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host ("  Lib version:     " + $_.Name)
    }
} else {
    Write-Host "  C:\Program Files (x86)\Windows Kits\10 NOT FOUND"
}

Write-Host ""
Write-Host "=== MSVC toolchain ==="
Get-ChildItem "C:\Program Files (x86)\Microsoft Visual Studio\2022" -ErrorAction SilentlyContinue |
    ForEach-Object {
        $msvcRoot = Join-Path $_.FullName "VC\Tools\MSVC"
        if (Test-Path $msvcRoot) {
            Get-ChildItem $msvcRoot -Directory | ForEach-Object {
                $cl = Join-Path $_.FullName "bin\Hostx64\x64\cl.exe"
                Write-Host ("  " + $_.Name + "   cl.exe=" + (Test-Path $cl))
            }
        }
    }

Write-Host ""
Write-Host "=== CMake / Ninja bundled with VS ==="
$vsBase = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools"
foreach ($rel in @(
    "Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe",
    "Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe",
    "MSBuild\Current\Bin\MSBuild.exe"
)) {
    $p = Join-Path $vsBase $rel
    Write-Host ("  {0,-80} {1}" -f $rel, $(if (Test-Path $p) { "OK" } else { "MISSING" }))
}

Write-Host ""
Write-Host "=== vcvars64 ==="
$vcvars = Get-ChildItem $vsBase -Recurse -Filter 'vcvars64.bat' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($vcvars) { Write-Host ("  " + $vcvars.FullName) } else { Write-Host "  MISSING" }

Write-Host ""
Write-Host "=== installed packages (filtered) ==="
$pkgRoot = "C:\ProgramData\Microsoft\VisualStudio\Packages"
if (Test-Path $pkgRoot) {
    Get-ChildItem $pkgRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'VC|MSVC|WindowsSdk|CMake|WinUI|Cpp' } |
        Select-Object -First 25 | ForEach-Object { Write-Host ("  " + $_.Name) }
}

Write-Host ""
Write-Host "=== VS component summary ==="
& $vswhere -products * -format json -include packages 2>$null | Out-Null
$pkgs = & $vswhere -products * -format json -prerelease 2>$null | ConvertFrom-Json
foreach ($inst in $pkgs) {
    if ($inst.packages) {
        Write-Host ("--- " + $inst.displayName + " ---")
        $inst.packages | ForEach-Object { Write-Host ("  " + $_.id) }
    }
}

Write-Host ""
Write-Host "=== summary finished ==="
