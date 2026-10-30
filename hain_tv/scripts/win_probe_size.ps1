$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function DirSize($p) {
    if (-not (Test-Path $p)) { return $null }
    $s = (Get-ChildItem $p -Recurse -File -Force -ErrorAction SilentlyContinue |
          Measure-Object -Property Length -Sum).Sum
    if ($null -eq $s) { return 0 }
    return [math]::Round($s / 1GB, 2)
}

Write-Host "=== C 盘占用 ==="
foreach ($p in @(
    'C:\src\flutter',
    'C:\heinplay',
    'C:\heinplay\hain_tv\.pub-cache',
    'C:\heinplay\hain_tv\build',
    'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools',
    'C:\Program Files (x86)\Windows Kits\10',
    'C:\src\flutter\bin\cache\artifacts'
)) {
    $s = DirSize $p
    if ($null -ne $s) { Write-Host ("  {0,-70} {1} GB" -f $p, $s) }
}

Write-Host ""
Write-Host "=== C:\heinplay 大文件 ==="
Get-ChildItem C:\heinplay -File -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Length -gt 50MB } |
    ForEach-Object { Write-Host ("  {0,-40} {1} MB" -f $_.Name, [math]::Round($_.Length/1MB,1)) }

Write-Host ""
Write-Host "=== D 盘现状 ==="
Get-ChildItem D:\ -Force -ErrorAction SilentlyContinue | Select-Object -First 20 | ForEach-Object { Write-Host ("  " + $_.Name) }

Write-Host ""
Write-Host "=== 当前用户 PATH（flutter 相关）==="
$up = [Environment]::GetEnvironmentVariable('Path', 'User')
Write-Host ("  User PATH: " + $up)
$sp = [Environment]::GetEnvironmentVariable('Path', 'Machine')
if ($sp -match 'flutter') { Write-Host ("  Machine PATH contains flutter: " + $sp) } else { Write-Host "  Machine PATH has no flutter" }

Write-Host ""
Write-Host "=== 相关环境变量 ==="
foreach ($n in @('FLUTTER_ROOT','PUB_CACHE','PUB_HOSTED_URL','FLUTTER_STORAGE_BASE_URL')) {
    Write-Host ("  {0,-24} user={1}  machine={2}" -f $n,
        [Environment]::GetEnvironmentVariable($n,'User'),
        [Environment]::GetEnvironmentVariable($n,'Machine'))
}

Write-Host ""
Write-Host "=== 正在运行的 flutter/dart 进程 ==="
Get-Process -Name 'dart','flutter','cmake','MSBuild','cl' -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host ("  " + $_.ProcessName + " pid=" + $_.Id) }

Write-Host ""
Write-Host "=== probe done ==="
