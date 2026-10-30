$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$dll = 'D:\build\hain_tv\build\windows\x64\runner\Release\heinplay_mpv_desktop.dll'
if (-not (Test-Path $dll)) { Write-Host "MISSING: $dll"; exit 1 }

Write-Host "=== DLL 信息 ==="
$f = Get-Item $dll
Write-Host ("  path    : " + $f.FullName)
Write-Host ("  size    : " + [math]::Round($f.Length/1KB,1) + " KB")
Write-Host ("  written : " + $f.LastWriteTime)

Write-Host ""
Write-Host "=== 导出表（dumpbin）==="
$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
$dumpbin = $null
if (Test-Path $vswhere) {
    $p = & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -find "VC\Tools\MSVC\*\bin\Hostx64\x64\dumpbin.exe" 2>$null
    if ($p) { $dumpbin = $p[0] }
}
if ($dumpbin) {
    Write-Host "  dumpbin: $dumpbin"
    & $dumpbin /EXPORTS $dll 2>&1 | Select-String -Pattern "HeinPlay|ordinal hint" -Context 0,2 | ForEach-Object { Write-Host ("  " + $_.ToString().Trim()) }
    $all = & $dumpbin /EXPORTS $dll 2>&1
    $names = $all | Where-Object { $_ -match '^\s+\d+\s+[0-9A-F]+\s+[0-9A-F]+\s+\S+' } | ForEach-Object { ($_ -split '\s+')[-1] }
    Write-Host ""
    Write-Host ("  导出符号总数: " + $names.Count)
    Write-Host ("  含 HeinPlayMpvDesktopPluginRegisterWithRegistrar: " + [bool]($names -contains 'HeinPlayMpvDesktopPluginRegisterWithRegistrar'))
} else {
    Write-Host "  dumpbin 不可用，改用二进制扫描查找导出名字符串"
    $bytes = [System.IO.File]::ReadAllBytes($dll)
    $ascii = [System.Text.Encoding]::ASCII.GetString($bytes)
    Write-Host ("  字符串 'HeinPlayMpvDesktopPluginRegisterWithRegistrar' 出现次数: " +
        ([regex]::Matches($ascii, 'HeinPlayMpvDesktopPluginRegisterWithRegistrar')).Count)
}

Write-Host ""
Write-Host "=== 导入表里的关键依赖 ==="
if ($dumpbin) {
    $imp = & $dumpbin /DEPENDENTS $dll 2>&1
    $imp | ForEach-Object { Write-Host ("  " + $_.ToString().Trim()) }
}

Write-Host ""
Write-Host "=== probe done ==="
