# =============================================================================
# HeinPlay Windows build environment probe
#
# Executed on the remote Windows host via:
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:/heinplay/win_probe.ps1
#
# IMPORTANT: This file MUST be saved as UTF-8 **with BOM**. Windows PowerShell
# 5.1 decodes BOM-less files using the system ANSI codepage (GBK on zh-CN),
# which mangles non-ASCII bytes and can shift quoting characters, breaking
# the script. All output below is deliberately ASCII-only for the same reason.
# =============================================================================

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function ShowInfo($name, $value) {
    Write-Host ("  {0,-26}: {1}" -f $name, $value)
}

function Safe($label, $block) {
    try {
        & $block
    } catch {
        Write-Host ("  {0,-26}: ERROR {1}" -f $label, $_.Exception.Message)
    }
}

Write-Host "=== HeinPlay Windows build environment probe ==="
Safe "OS" { ShowInfo "OS" (Get-CimInstance Win32_OperatingSystem).Caption }
Safe "OSVersion" { ShowInfo "OSVersion" (Get-CimInstance Win32_OperatingSystem).Version }
Safe "Host" { ShowInfo "HostName" $env:COMPUTERNAME }
Safe "User" { ShowInfo "User" ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) }
Safe "CPU" { ShowInfo "CPU" (Get-CimInstance Win32_Processor).Name }
Safe "Cores" { ShowInfo "LogicalCores" (Get-CimInstance Win32_Processor).NumberOfLogicalProcessors }
Safe "RAM" {
    $ram = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
    ShowInfo "RAM_GB" ([math]::Round($ram / (1024 * 1024 * 1024), 1))
}

Write-Host ""
Write-Host "--- Visual Studio 2022 ---"
$vs = $null
try {
    $vsRoot = Join-Path ${env:ProgramFiles} "Microsoft Visual Studio"
    if (Test-Path $vsRoot) {
        $vs = Get-ChildItem $vsRoot -ErrorAction SilentlyContinue |
              Where-Object { Test-Path (Join-Path $_.FullName "VC\Auxiliary\Build\vcvars64.bat") } |
              Select-Object -First 1
    }
} catch {
    Write-Host ("  VS scan error: " + $_.Exception.Message)
}

if ($vs) {
    ShowInfo "VS2022" $vs.Name
    ShowInfo "InstallPath" $vs.FullName
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $cpp = & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property displayName 2>$null
        if ($cpp) {
            ShowInfo "C++ desktop workload" ("OK -> " + ($cpp -join ' | '))
        } else {
            ShowInfo "C++ desktop workload" "*** MISSING (need C++ desktop workload) ***"
        }
        $cl = & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -find "VC\Tools\MSVC\*\bin\Hostx64\x64\cl.exe" 2>$null
        if ($cl) { ShowInfo "cl.exe" ($cl -join ' | ') } else { ShowInfo "cl.exe" "*** MISSING ***" }
    } else {
        ShowInfo "vswhere.exe" "NOT FOUND"
    }
} else {
    ShowInfo "VS2022" "*** NOT FOUND (need VS2022 + C++ desktop workload) ***"
}

Write-Host ""
Write-Host "--- Flutter SDK ---"
$flutter = $null
try { $flutter = (Get-Command flutter -ErrorAction SilentlyContinue).Source } catch { }
if ($flutter) {
    ShowInfo "flutter" $flutter
    Safe "flutter version" {
        $v = & $flutter --version --no-version-check 2>$null
        ShowInfo "version" (($v | Select-Object -First 1))
    }
} else {
    $guesses = @(
        "C:\src\flutter\bin\flutter.bat",
        "C:\flutter\bin\flutter.bat",
        (Join-Path $env:LOCALAPPDATA "flutter\bin\flutter.bat"),
        (Join-Path $env:USERPROFILE "flutter\bin\flutter.bat"),
        "D:\flutter\bin\flutter.bat",
        "C:\dev\flutter\bin\flutter.bat",
        "D:\src\flutter\bin\flutter.bat"
    )
    $found = $null
    foreach ($g in $guesses) { if (Test-Path $g) { $found = $g; break } }
    if ($found) {
        ShowInfo "flutter_guessed" $found
        ShowInfo "note" "not on PATH - add it or use absolute path"
    } else {
        ShowInfo "flutter" "*** NOT FOUND (need Flutter SDK 3.47.5) ***"
    }
}

Write-Host ""
Write-Host "--- Other tools ---"
foreach ($t in @('git', 'cmake', 'ninja', 'python', '7z', 'msbuild')) {
    $c = $null
    try { $c = (Get-Command $t -ErrorAction SilentlyContinue).Source } catch { }
    ShowInfo $t ($(if ($c) { $c } else { "NOT FOUND" }))
}

Write-Host ""
Write-Host "--- mpv runtime (third_party) ---"
$mpvRoot = "C:\heinplay\hain_tv\third_party\mpv-windows"
foreach ($rel in @("bin\libmpv-2.dll", "lib\mpv.lib", "include\mpv\client.h")) {
    $p = Join-Path $mpvRoot $rel
    if (Test-Path $p) {
        $f = Get-Item $p
        ShowInfo $rel ("OK  " + [math]::Round($f.Length / 1MB, 1) + " MB")
    } else {
        ShowInfo $rel "MISSING"
    }
}
$mpvAlt = "C:\Program Files\mpv\bin\libmpv-2.dll"
if (Test-Path $mpvAlt) { ShowInfo "system libmpv-2.dll" "OK" }

Write-Host ""
Write-Host "--- Disk space ---"
try {
    Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -ne $null } | ForEach-Object {
        ShowInfo $_.Name ("free " + [math]::Round($_.Free / 1GB, 1) + " GB / total " + [math]::Round(($_.Used + $_.Free) / 1GB, 1) + " GB")
    }
} catch { Write-Host "  disk scan error" }

Write-Host ""
Write-Host "--- Project dir ---"
foreach ($d in @("C:\heinplay", "C:\heinplay\hain_tv", "C:\heinplay\dist")) {
    ShowInfo $d ($(if (Test-Path $d) { "EXISTS" } else { "absent" }))
}

Write-Host ""
Write-Host "=== probe finished ==="
