# =============================================================================
# Install Visual Studio 2022 Build Tools with the C++ desktop workload.
#
# Flutter Windows embeds (C++/WinRT, ANGLE, Impeller) REQUIRE the MSVC toolchain.
# There is no mingw cross-compile path for Flutter desktop.
#
# Run detached from the SSH session (Start-Process) so that dropping the
# connection cannot kill the installer. Logs land in C:\heinplay\.
# =============================================================================

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$logDir = 'C:\heinplay'
$outLog = Join-Path $logDir 'vs_install.out.log'
$errLog = Join-Path $logDir 'vs_install.err.log'
$doneFlag = Join-Path $logDir 'vs_install.done'

foreach ($f in @($outLog, $errLog, $doneFlag)) {
    if (Test-Path $f) { Remove-Item $f -Force }
}

# --- already installed? ---
$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vswhere) {
    $existing = & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
    if ($existing) {
        Write-Host "VS build tools already present: $existing"
        Set-Content -Path $doneFlag -Value "already-installed"
        exit 0
    }
}
Write-Host "VS build tools not present - starting install."

# The --override payload is passed to the VS installer as-is.
$vsOverride = "--wait --passive --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --locale zh-CN"

$argList = @(
    'install',
    '--id', 'Microsoft.VisualStudio.2022.BuildTools',
    '-e',
    '--source', 'winget',
    '--disable-interactivity',
    '--accept-package-agreements',
    '--accept-source-agreements',
    '--override', $vsOverride
)

try {
    $p = Start-Process -FilePath 'winget.exe' -ArgumentList $argList `
         -RedirectStandardOutput $outLog -RedirectStandardError $errLog `
         -WindowStyle Hidden -PassThru
    Write-Host ("winget started, pid=" + $p.Id)
    Write-Host ("stdout -> " + $outLog)
    Write-Host ("stderr -> " + $errLog)
    Set-Content -Path $doneFlag -Value ("pid=" + $p.Id)
} catch {
    Write-Host ("failed to launch winget: " + $_.Exception.Message)
    Set-Content -Path $doneFlag -Value ("launch-failed: " + $_.Exception.Message)
    exit 1
}

Write-Host "=== installer launched, this session may exit now ==="
