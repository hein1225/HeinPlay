# =============================================================================
# Migrate all movable build dependencies from C: to D: on HEINCI-SERVER.
#
# Layout after migration:
#   D:\src\flutter      Flutter SDK 3.47.5        (was C:\src\flutter)
#   D:\build\hain_tv     project tree              (was C:\heinplay\hain_tv)
#   D:\build\dist        build artifacts           (was C:\heinplay\dist)
#   D:\VSBuildTools      VS2022 BuildTools          (junction, was C:\Program Files (x86)\...)
#   D:\WindowsKits10     Windows SDK 10             (junction, was C:\Program Files (x86)\Windows Kits\10)
#
# Strategy per item:
#   · Flutter SDK / project  -> robocopy (verify) -> delete source
#   · VS BuildTools / WinSDK -> robocopy -> delete source -> mklink /J junction
#     (a junction keeps every hard-coded path in the registry / MSBuild /
#      vcvars working, while the bytes live on D:)
#
# Run it twice:  pass -Phase Copy  then  -Phase Cut
# =============================================================================

param(
    [ValidateSet('Copy', 'Cut')][string]$Phase = 'Copy'
)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Say($m) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }

# ---- source -> destination map ----
$plainMoves = @(
    @{ Src = 'C:\src\flutter';        Dst = 'D:\src\flutter' },
    @{ Src = 'C:\heinplay\hain_tv';   Dst = 'D:\build\hain_tv' },
    @{ Src = 'C:\heinplay\dist';      Dst = 'D:\build\dist' }
)

$junctionMoves = @(
    @{ Src = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools'; Dst = 'D:\VSBuildTools' },
    @{ Src = 'C:\Program Files (x86)\Windows Kits\10';                          Dst = 'D:\WindowsKits10' }
)

function Invoke-Robo([string]$src, [string]$dst) {
    if (-not (Test-Path $src)) { Say "skip (source gone): $src"; return $true }
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    Say "robocopy $src -> $dst"
    # /E subdirs+files, /COPY:DAT data+attrs+times, /R:2 /W:1 retry, /MT:8 threads
    & robocopy.exe $src $dst /E /COPY:DAT /DCOPY:DAT /R:2 /W:1 /NFL /NDL /NP /NJH /NJS /MT:8
    $rc = $LASTEXITCODE
    if ($rc -ge 8) { Say "ROBOCOPY FAILED rc=$rc for $src"; return $false }
    Say "robocopy done rc=$rc"
    return $true
}

function Measure-Bytes([string]$p) {
    if (-not (Test-Path $p)) { return 0 }
    $s = (Get-ChildItem $p -Recurse -File -Force -ErrorAction SilentlyContinue |
          Measure-Object -Property Length -Sum).Sum
    if ($null -eq $s) { return 0 }
    return $s
}

# =============================================================================
Say "PHASE = $Phase"
Say "=== 1. plain moves ==="
foreach ($m in $plainMoves) {
    if (-not (Test-Path $m.Src)) { Say "skip: $($m.Src) not present"; continue }
    if (Test-Path $m.Dst) {
        $sb = Measure-Bytes $m.Src
        $db = Measure-Bytes $m.Dst
        Say ("destination already exists: {0}  (src {1} GB / dst {2} GB)" -f $m.Dst, [math]::Round($sb/1GB,2), [math]::Round($db/1GB,2))
    } else {
        if (-not (Invoke-Robo $m.Src $m.Dst)) { Say "copy failed, aborting this item"; continue }
    }
    if ($Phase -eq 'Cut') {
        Say "removing source: $($m.Src)"
        Remove-Item -Recurse -Force $m.Src -ErrorAction SilentlyContinue
        if (Test-Path $m.Src) { Say "WARNING: could not fully remove $($m.Src)" }
        else { Say "removed: $($m.Src)" }
    }
}

# =============================================================================
Say ""
Say "=== 2. junction moves (VS BuildTools / Windows SDK) ==="
foreach ($m in $junctionMoves) {
    if (-not (Test-Path $m.Src)) { Say "skip: $($m.Src) not present"; continue }

    # already a junction?  (ReparsePoint)
    $item = Get-Item $m.Src -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        Say "already a reparse point: $($m.Src) -> $((Get-Item $m.Src -Force).Target)"
        continue
    }

    if (-not (Test-Path $m.Dst)) {
        if (-not (Invoke-Robo $m.Src $m.Dst)) { Say "copy failed, skipping junction for $($m.Src)"; continue }
    } else {
        Say "destination exists: $($m.Dst)"
    }

    if ($Phase -eq 'Cut') {
        Say "removing source: $($m.Src)"
        Remove-Item -Recurse -Force $m.Src -ErrorAction SilentlyContinue
        if (Test-Path $m.Src) {
            Say "could not remove $($m.Src) (likely locked by an installer service) - leaving as-is"
            continue
        }
        Say "creating junction: $($m.Src) -> $($m.Dst)"
        & cmd.exe /c "mklink /J `"$($m.Src)`" `"$($m.Dst)`""
        Say ("mklink rc=" + $LASTEXITCODE)
    }
}

# =============================================================================
Say ""
Say "=== 3. cleanup loose large files ==="
foreach ($f in @(
    'C:\heinplay\flutter_windows_3.47.5-stable.zip',
    'C:\heinplay\hein_sync.tgz',
    'C:\heinplay\hein_sync2.tgz',
    'C:\heinplay\hein_fix3.tgz',
    'C:\heinplay\hein_runner.tgz',
    'C:\heinplay\hein_assets.tgz'
)) {
    if (Test-Path $f) {
        $sz = [math]::Round((Get-Item $f).Length / 1MB, 1)
        Remove-Item $f -Force -ErrorAction SilentlyContinue
        if (Test-Path $f) { Say "could not remove $f" } else { Say "removed $f ($sz MB)" }
    }
}
# the whole C:\heinplay staging dir if it is now empty
if ((Test-Path 'C:\heinplay') -and -not (Get-ChildItem 'C:\heinplay' -Force | Select-Object -First 1)) {
    Remove-Item 'C:\heinplay' -Force -ErrorAction SilentlyContinue
    Say "removed empty C:\heinplay"
}

# =============================================================================
Say ""
Say "=== 4. environment variables ==="
$newFlutterBin = 'D:\src\flutter\bin'
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath) {
    $parts = $userPath -split ';' | Where-Object { $_ -and ($_ -ne 'C:\src\flutter\bin') }
    $newPath = (@($newFlutterBin) + $parts) -join ';'
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Say "User PATH updated: flutter bin -> $newFlutterBin"
    Say "  new PATH: $newPath"
} else {
    [Environment]::SetEnvironmentVariable('Path', $newFlutterBin, 'User')
    Say "User PATH set to $newFlutterBin"
}
# process-level so the rest of this session sees it
$env:Path = "$newFlutterBin;$env:Path"

if ($Phase -eq 'Cut') {
    # PUB_CACHE moves with the project; make the default explicit and stable.
    [Environment]::SetEnvironmentVariable('PUB_CACHE', 'D:\build\pub-cache', 'User')
    Say "User PUB_CACHE = D:\build\pub-cache"
}

# =============================================================================
Say ""
Say "=== 5. verify ==="
$flutterBat = Join-Path $newFlutterBin 'flutter.bat'
if (Test-Path $flutterBat) {
    Say "flutter version via new path:"
    & $flutterBat --version --no-version-check 2>&1 | Select-Object -First 3 | ForEach-Object { Write-Host ("  " + $_) }
} else {
    Say "*** flutter.bat NOT FOUND at $flutterBat ***"
}
foreach ($m in $plainMoves + $junctionMoves) {
    if (Test-Path $m.Src) {
        $it = Get-Item $m.Src -Force
        $t = if ($it.Attributes -band [IO.FileAttributes]::ReparsePoint) { "JUNCTION -> $($it.Target)" } else { "real dir" }
        Say ("  {0,-62} {1}" -f $m.Src, $t)
    } else {
        Say ("  {0,-62} (moved away)" -f $m.Src)
    }
}

Say ""
Say "=== migration phase finished ==="
