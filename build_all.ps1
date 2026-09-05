#Requires -Version 5.1
# HeinPlay 全平台构建脚本
# 功能：菜单选择 flutter doctor、依赖检查、Windows 插件检查、Android 签名完整性检查
#       构建 TV / tvLegacy / 手机 / Windows / Linux(AppImage) / 鸿蒙(HAP) / 全部版本，汇总结果、日志路径与产物路径
# 说明：Linux 版为 AppImage，需在 Linux 环境或 WSL2 中构建（Flutter 不支持 Windows 交叉编译 Linux）。
#       在 Windows 上运行时会自动尝试通过 WSL2 执行 build_linux_appimage.sh；未安装 WSL 则跳过并提示。
#       鸿蒙版走 scripts/build_hap.sh（Git Bash + DevEco SDK），需要 DevEco 命令行工具链与本机签名材料；
#       【默认不参与「1.构建全部」】，需通过菜单 11/12 或 -IncludeHap 显式启用。

[CmdletBinding()]
param(
    [switch]$SkipDoctor,
    [switch]$SkipMobile,
    [switch]$SkipTv,
    [switch]$SkipTvlegacy,
    [switch]$SkipWindows,
    [switch]$SkipLinux,
    [switch]$IncludeHap,
    [switch]$Clean
)

$rootDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$hainDir = Join-Path $rootDir 'hain_tv'
$androidDir = Join-Path $hainDir 'android'
$androidAppDir = Join-Path $androidDir 'app'
$distDir = Join-Path $hainDir 'dist'
$logsDir = Join-Path $hainDir 'logs'

function Write-Section($title) {
    Write-Host "`n=== $title ===" -ForegroundColor Cyan
}

function Write-Ok($msg) {
    Write-Host "[OK] $msg" -ForegroundColor Green
}

function Write-Warn($msg) {
    Write-Host "[WARN] $msg" -ForegroundColor Yellow
}

function Write-Err($msg) {
    Write-Host "[ERR] $msg" -ForegroundColor Red
}

function Write-LocalLink($label, $path) {
    # 输出可点击的 file:// 超链接：点击由资源管理器直接打开目录/文件，
    # 在用户终端中原即可点击、且不会残留无法关闭的 cmd 窗口。
    # 注意：此前为“规避浏览器拦截”引入的 OSC 8 超链接反而在点击时残留关不掉的 cmd，
    # 已弃用；还原为最初的 file:// 写法。
    $uri = [System.Uri]::new((Resolve-Path $path).Path).AbsoluteUri
    Write-Host "$label $uri" -ForegroundColor Cyan
}

function Invoke-FlutterDoctor {
    Write-Section 'Flutter Doctor'
    flutter doctor
    $ok = ($LASTEXITCODE -eq 0)
    if ($ok) { Write-Ok 'flutter doctor 未发现异常' }
    else { Write-Warn 'flutter doctor 检测到问题，请查看上方输出' }
    return $ok
}

function Invoke-FlutterPubGet {
    param([switch]$Clean)

    if ($Clean) {
        Write-Section 'Flutter 依赖检查 / flutter clean + pub get'
    }
    else {
        Write-Section 'Flutter 依赖检查 / flutter pub get'
    }

    Push-Location $hainDir
    try {
        if ($Clean) {
            # flutter clean 会删除整个 build 目录，但 Windows 插件依赖（如 vlc_player、
            # fvp 下载的 mdk-sdk 等）体积大且下载困难，需要保留。
            # 同时保留 _deps 目录（包含 nuget.exe 等 CMake 下载的构建工具），避免每次构建重复下载。
            $buildDir = Join-Path $hainDir 'build\windows\x64'
            $backupDir = Join-Path $env:TEMP "heinplay_build_backup_$(Get-Random)"
            $hasBackup = $false
            if (Test-Path $buildDir) {
                Write-Host "备份 Windows 构建依赖目录..." -ForegroundColor Cyan
                New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
                $subDirs = @('plugins', '_deps')
                foreach ($subDir in $subDirs) {
                    $srcPath = Join-Path $buildDir $subDir
                    if (Test-Path $srcPath) {
                        $dstPath = Join-Path $backupDir $subDir
                        Copy-Item -Path $srcPath -Destination $dstPath -Recurse -Force
                        $hasBackup = $true
                    }
                }
            }

            flutter clean
            $cleanOk = ($LASTEXITCODE -eq 0)
            if (-not $cleanOk) { Write-Warn 'flutter clean 返回非零，继续执行 pub get' }

            if ($hasBackup -and (Test-Path $backupDir)) {
                Write-Host "恢复 Windows 构建依赖目录..." -ForegroundColor Cyan
                New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
                $subDirs = @('plugins', '_deps')
                foreach ($subDir in $subDirs) {
                    $srcPath = Join-Path $backupDir $subDir
                    if (Test-Path $srcPath) {
                        $dstPath = Join-Path $buildDir $subDir
                        New-Item -ItemType Directory -Force -Path $dstPath | Out-Null
                        Copy-Item -Path "$srcPath\*" -Destination $dstPath -Recurse -Force
                    }
                }
                Remove-Item -Path $backupDir -Recurse -Force
            }
        }

        flutter pub get
        $ok = ($LASTEXITCODE -eq 0)
        if ($ok) { Write-Ok 'flutter pub get 成功' }
        else { Write-Err 'flutter pub get 失败' }
        return $ok
    }
    finally {
        Pop-Location
    }
}

function Test-SevenZip {
    Write-Section 'Windows 7zip 环境检查'
    $sevenZ = Get-Command 7z -ErrorAction SilentlyContinue
    if (-not $sevenZ) {
        $sevenZ = Get-Command 7za -ErrorAction SilentlyContinue
    }
    if ($sevenZ) {
        Write-Ok "已检测到 7zip: $($sevenZ.Source)"
        return $true
    }
    else {
        Write-Warn '未检测到 7zip（7z 或 7za）。Windows 原生依赖使用 .7z 压缩，建议安装 7zip 并添加到 PATH，否则将回退到 CMake tar 解压。'
        Write-Host '下载地址: https://www.7-zip.org/download.html' -ForegroundColor Yellow
        return $false
    }
}

function Test-WindowsPlugin {
    Write-Section 'Windows 插件依赖检查'
    # Windows 播放器已改为 fvp + vlc，不再依赖 shinchiro mpv-dev。
    # 仅检查构建目录是否存在；依赖由插件在构建时自行下载。
    $depsDir = Join-Path $hainDir 'build\windows\x64'
    if (Test-Path $depsDir) {
        Write-Ok "Windows 构建目录已存在: $depsDir"
        return $true
    }
    Write-Warn '未检测到 Windows 构建目录；首次构建 Windows 版时插件会自动下载所需原生依赖，请确保网络稳定。'
    return $false
}

function Repair-WindowsNativeDeps {
    $depsDir = Join-Path $hainDir 'build\windows\x64'

    $expectedHashes = @{
        'ANGLE.7z' = 'E866F13E8D552348058AFAAFE869B1ED'
    }

    if (-not (Test-Path $depsDir)) {
        New-Item -ItemType Directory -Path $depsDir -Force | Out-Null
    }

    # Windows 播放器已改为 fvp + vlc，不再依赖 shinchiro mpv-dev。
    # 清理残留的 mpv 缓存与解压目录，避免旧文件干扰新构建。
    $mpvArchives = Get-ChildItem -Path $depsDir -Filter 'mpv-dev-*.7z' -ErrorAction SilentlyContinue
    foreach ($f in $mpvArchives) {
        Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
    }
    $targetMpv = Join-Path $depsDir 'shinchiro-mpv-dev-x86_64.7z'
    if (Test-Path $targetMpv) {
        Remove-Item $targetMpv -Force -ErrorAction SilentlyContinue
    }
    $assetMarker = Join-Path $depsDir 'shinchiro-mpv-dev-x86_64.asset.txt'
    if (Test-Path $assetMarker) {
        Remove-Item $assetMarker -Force -ErrorAction SilentlyContinue
    }
    $libmpvSrc = Join-Path $depsDir 'libmpv'
    if (Test-Path $libmpvSrc) {
        Remove-Item $libmpvSrc -Recurse -Force -ErrorAction SilentlyContinue
    }

    $otherArchives = Get-ChildItem -Path $depsDir -Filter '*.7z' -ErrorAction SilentlyContinue
    foreach ($f in $otherArchives) {
        if ($f.Length -lt 1MB) {
            $sizeKB = [math]::Round($f.Length / 1KB, 2)
            Write-Warn "检测到疑似损坏的 Windows 原生依赖: $($f.Name) (${sizeKB} KB)，已删除，构建时将重新下载。"
            Remove-Item $f.FullName -Force
            continue
        }

        $expectedHash = $expectedHashes[$f.Name]
        if ($expectedHash) {
            $actualHash = (Get-FileHash $f.FullName -Algorithm MD5).Hash
            if ($actualHash -ne $expectedHash) {
                $sizeMB = [math]::Round($f.Length / 1MB, 2)
                Write-Warn "检测到 MD5 不匹配的 Windows 原生依赖: $($f.Name) (${sizeMB} MB)`n  实际=$actualHash`n  预期=$expectedHash，已删除，构建时将重新下载。"
                Remove-Item $f.FullName -Force
            }
        }
    }

    $localPlugins = @{
        # Windows 播放器已改为 fvp + vlc；flutter_mpv / media_kit 不再使用。
        'permission_handler_windows' = 'deps\permission_handler_windows'
    }

    $anySymlinkInvalid = $false
    foreach ($pluginName in $localPlugins.Keys) {
        $symlinkDir = Join-Path $hainDir "windows\flutter\ephemeral\.plugin_symlinks\$pluginName"
        $expectedTarget = Resolve-Path (Join-Path $hainDir $localPlugins[$pluginName]) -ErrorAction SilentlyContinue
        $symlinkValid = $false
        if (Test-Path $symlinkDir) {
            try {
                $item = Get-Item $symlinkDir -ErrorAction Stop
                if ($item.Target -and (Test-Path $item.Target)) {
                    $actualTarget = Resolve-Path $item.Target -ErrorAction SilentlyContinue
                    if ($actualTarget -and $expectedTarget -and ($actualTarget.Path -eq $expectedTarget.Path)) {
                        $symlinkValid = $true
                    }
                }
            }
            catch {
                $symlinkValid = $false
            }
        }

        if (-not $symlinkValid) {
            Write-Warn "Windows 插件 $pluginName 的 symlink 未指向本地修正依赖。"
            $anySymlinkInvalid = $true
        }
    }

    if ($anySymlinkInvalid) {
        Write-Warn '清理 ephemeral 缓存并重新执行 flutter pub get...'
        $ephemeralDir = Join-Path $hainDir 'windows\flutter\ephemeral'
        if (Test-Path $ephemeralDir) {
            Remove-Item $ephemeralDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Invoke-FlutterPubGet | Out-Null
    }
}

function Test-AndroidSigning {
    Write-Section 'Android 签名文件完整性检查'
    $allOk = $true

    function Test-OneKey($label, $propFile) {
        $propPath = Join-Path $androidDir $propFile
        if (-not (Test-Path $propPath)) {
            Write-Err "$label 签名配置文件不存在: $propPath"
            return $false
        }

        $storeFile = Get-Content $propPath | Where-Object { $_ -match '^\s*storeFile\s*=\s*(.+?)\s*$' } | ForEach-Object { $matches[1].Trim() }
        if (-not $storeFile) {
            Write-Err "$label 签名配置未找到 storeFile: $propPath"
            return $false
        }

        $storePath = Join-Path $androidAppDir $storeFile
        if (-not (Test-Path $storePath)) {
            Write-Err "$label keystore 文件不存在: $storePath（在 $propFile 中配置为 $storeFile）"
            return $false
        }

        $sizeKB = [math]::Round((Get-Item $storePath).Length / 1KB, 2)
        Write-Ok "$label 签名配置完整: $storeFile (${sizeKB} KB)"
        return $true
    }

    $script:tvKeyOk = Test-OneKey 'TV 版' 'key.properties'
    $script:mobileKeyOk = Test-OneKey '手机版' 'key-mobile.properties'
    $script:tvlegacyKeyOk = Test-OneKey 'tvLegacy 版' 'key-tvlegacy.properties'

    if (-not ($tvKeyOk -and $mobileKeyOk -and $tvlegacyKeyOk)) {
        Write-Warn 'Android 签名文件不完整，将跳过相关 Android 构建。请按 BUILD_GUIDE.md 第 4.1 节配置签名。'
    }
    return ($tvKeyOk -and $mobileKeyOk -and $tvlegacyKeyOk)
}

function Get-ProjectVersion {
    $pubspecPath = Join-Path $hainDir 'pubspec.yaml'
    $pubspec = Get-Content -Path $pubspecPath -Raw
    if ($pubspec -notmatch 'version:\s*([^\s]+)') {
        throw '无法从 pubspec.yaml 读取 version'
    }
    return $Matches[1].Split('+')[0]
}

function Invoke-BuildScript($name, $scriptPath) {
    Write-Section "$name 构建"
    if (-not (Test-Path $scriptPath)) {
        Write-Err "构建脚本不存在: $scriptPath"
        return @{ Success = $false; Skipped = $false; LogPath = $null }
    }

    New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
    $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
    $safeName = $name -replace '\s+', '_'
    $logPath = Join-Path $logsDir "build_${safeName}_${timestamp}.log"

    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    Push-Location $hainDir
    try {
        $utf8Bom = New-Object System.Text.UTF8Encoding $true
        [System.IO.File]::AppendAllText($logPath, "`n=== $name 构建开始 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===`n", $utf8Bom)

        # 判断是否为 shell 脚本（Linux/macOS 构建，如 build_linux_appimage.sh）。
        # PowerShell 脚本（.ps1）直接调用；shell 脚本在 Windows 上优先走 WSL2，
        # 在原生 Linux 主机上走 bash。
        $isShell = $scriptPath -match '\.sh$'
        $runBlock = $null
        $ok = $true
        $skipped = $false
        $wslRan = $false

        if ($isShell) {
            if ($IsWindows -or ($env:OS -match 'Windows')) {
                $wsl = Get-Command wsl -ErrorAction SilentlyContinue
                if (-not $wsl) {
                    Write-Warn "$name 跳过：当前为 Windows 环境且未检测到 WSL，无法交叉编译 Linux 版。请在 Linux 主机 / CI 构建，或使用 -SkipLinux 跳过。"
                    $ok = $false
                    $skipped = $true
                }
                else {
                    # 探测 WSL 是否已配置可用的 Linux 发行版。仅安装 WSL 但未装发行版时，
                    # `wsl -e` 会打印安装指引并以非 0 退出，不能用于构建。
                    wsl -e true 2>$null | Out-Null
                    if ($LASTEXITCODE -ne 0) {
                        Write-Warn "$name 跳过：WSL 已安装但未配置可用的 Linux 发行版。请先 `wsl --install -d Ubuntu` 安装发行版，并在其中安装 Flutter / appimage-builder；或使用 -SkipLinux 跳过。CI 也会产出 Linux AppImage。"
                        $ok = $false
                        $skipped = $true
                    }
                    else {
                        # 将 Windows 绝对路径转换为 WSL 路径。
                        # 关键点：WSL 默认把 Windows 盘挂载为小写（/mnt/e），而 Linux 文件系统区分大小写，
                        # 因此盘符必须转为小写，否则会报 "No such file or directory"。
                        # 优先用 wslpath -u（把 Windows 路径转成 WSL 路径，并遵循 WSL 实际挂载配置）；
                        # 失败再手动映射并强制小写盘符。路径统一用正斜杠，避免反斜杠在 WSL 中被转义。
                        $winPathFs = $scriptPath -replace '\\', '/'
                        $wslScript = (wsl -e wslpath -u "$winPathFs" 2>$null)
                        if (-not $wslScript) {
                            $wslScript = ($winPathFs -replace '^([A-Za-z]):', { '/mnt/' + $_.Groups[1].Value.ToLower() })
                        }
                        # 校验转换后的脚本在 WSL 中确实存在，提前给出可诊断的错误，避免神秘失败。
                        $wslFileOk = (wsl -e bash -c "test -f '$wslScript' && echo yes || echo no" 2>$null)
                        if ($wslFileOk -ne 'yes') {
                            Write-Err "$name 构建失败：WSL 中找不到构建脚本 $wslScript（原 Windows 路径 $scriptPath）。请确认该磁盘已在 WSL 中挂载（默认位于 /mnt/<小写盘符>）。"
                            $ok = $false
                            $wslRan = $true
                        }
                        else {
                            # 用 Start-Process 重定向原生输出到日志，避免 PowerShell 编解码产生乱码/空字节；
                            # 同时实时回显到控制台。
                            $tmpOut = Join-Path $env:TEMP ("hein_linux_out_$(Get-Random).txt")
                            $tmpErr = Join-Path $env:TEMP ("hein_linux_err_$(Get-Random).txt")
                            $proc = Start-Process -FilePath 'wsl' -ArgumentList '-e', 'bash', $wslScript -NoNewWindow -Wait -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr -PassThru
                            if (Test-Path $tmpOut) { [System.IO.File]::AppendAllText($logPath, [System.IO.File]::ReadAllText($tmpOut, [System.Text.Encoding]::UTF8), $utf8Bom) }
                            if (Test-Path $tmpErr) { [System.IO.File]::AppendAllText($logPath, [System.IO.File]::ReadAllText($tmpErr, [System.Text.Encoding]::UTF8), $utf8Bom) }
                            Get-Content -Path $tmpOut -Encoding utf8 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
                            Get-Content -Path $tmpErr -Encoding utf8 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
                            Remove-Item $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
                            $ok = ($proc.ExitCode -eq 0)
                            $wslRan = $true
                        }
                    }
                }
            }
            else {
                $bashCmd = Get-Command bash -ErrorAction SilentlyContinue
                if (-not $bashCmd) {
                    Write-Err "$name 构建失败：未检测到 bash，无法执行 Linux 构建脚本。"
                    $ok = $false
                }
                else {
                    $runBlock = { & bash "$scriptPath" }
                }
            }
        }
        else {
            $runBlock = { & $scriptPath }
        }

        if (-not $wslRan -and $runBlock) {
            & $runBlock 2>&1 | ForEach-Object {
                $line = $_
                Write-Host $line
                [System.IO.File]::AppendAllText($logPath, "$line`n", $utf8Bom)
            }
            $ok = ($LASTEXITCODE -eq 0)
        }
    }
    catch {
        $errLine = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') EXCEPTION: $_"
        [System.IO.File]::AppendAllText($logPath, "$errLine`n", $utf8Bom)
        Write-Err "$name 构建异常: $_"
        $ok = $false
    }
    finally {
        Pop-Location
        $ErrorActionPreference = $oldEAP
    }

    if ($ok) {
        Write-Ok "$name 构建成功"
    }
    else {
        Write-Err "$name 构建失败，日志: $logPath"
        if (Test-Path $logPath) {
            Write-Host "`n--- 最近 30 行日志 ---" -ForegroundColor Yellow
            Get-Content -Path $logPath -Tail 30 | ForEach-Object { Write-Host $_ }
            Write-Host '--- 日志结束 ---' -ForegroundColor Yellow
        }
    }
                        return @{ Success = $ok; Skipped = $skipped; LogPath = $logPath }
                    }

function Invoke-BuildHap {
    # 鸿蒙(HarmonyOS NEXT) HAP 构建。
    # 说明：
    #   1) 只能在本机 Windows 上经 Git Bash 执行 scripts/build_hap.sh（脚本内会导出
    #      DevEco node/ohpm/flutter 等环境并调用 `flutter build hap`）；
    #      绝不能走 WSL（Linux 无 DevEco 工具链）。
    #   2) flutter 工具链硬编码查找 <工程>/ohos。鸿蒙工程实体已统一为 harmony_haintv/，
    #      故调用前若缺 ohos 会自动创建临时 junction（ohos -> harmony_haintv），
    #      构建结束后删除（仅删链接，不影响 harmony_haintv 实体与产物）。
    #   3) 鸿蒙为 opt-in 构建（测试期），不会因任何「构建全部」自动触发。

    $name = '鸿蒙版'
    Write-Section "$name 构建"
    New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
    $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
    $logPath = Join-Path $logsDir "build_HarmonyOS_${timestamp}.log"
    $utf8Bom = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::AppendAllText($logPath, "`n=== $name 构建开始 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===`n", $utf8Bom)

    $hapProject = Join-Path $hainDir 'harmony_haintv'
    $buildScript = Join-Path $hainDir 'scripts\build_hap.sh'
    if (-not (Test-Path $hapProject)) {
        Write-Err "鸿蒙工程目录不存在: $hapProject（应包含 AppScope/entry/oh-package.json5）"
        return @{ Success = $false; Skipped = $true; LogPath = $logPath }
    }
    if (-not (Test-Path $buildScript)) {
        Write-Err "构建脚本不存在: $buildScript"
        return @{ Success = $false; Skipped = $true; LogPath = $logPath }
    }

    # 定位 Git Bash
    $bashExe = $null
    $cmdBash = Get-Command bash -ErrorAction SilentlyContinue
    if ($cmdBash) { $bashExe = $cmdBash.Source }
    if (-not $bashExe) {
        foreach ($p in @("$env:ProgramFiles\Git\bin\bash.exe", "${env:ProgramFiles(x86)}\Git\bin\bash.exe")) {
            if (Test-Path $p) { $bashExe = $p; break }
        }
    }
    if (-not $bashExe) {
        Write-Err '未找到 Git Bash（bash.exe）。鸿蒙构建需在 Windows Git Bash 中执行 build_hap.sh。'
        return @{ Success = $false; Skipped = $true; LogPath = $logPath }
    }

    # 临时 ohos junction（仅当缺失时创建）
    $ohosLink = Join-Path $hainDir 'ohos'
    $createdJunction = $false
    if (-not (Test-Path $ohosLink)) {
        Write-Host '创建临时 junction: ohos -> harmony_haintv（构建后自动删除）...' -ForegroundColor Cyan
        try {
            cmd /c mklink /J "$ohosLink" "$hapProject" | Out-Null
            if (-not (Test-Path $ohosLink)) { throw 'mklink 失败' }
            $createdJunction = $true
        }
        catch {
            Write-Err "创建 ohos junction 失败: $_。可手动执行: mklink /J `"$ohosLink`" `"$hapProject`""
            return @{ Success = $false; Skipped = $true; LogPath = $logPath }
        }
    }

    try {
        # PowerShell 5.1 Start-Process 用大小写不敏感字典收集环境变量，
        # 若同时存在小写 http_proxy/https_proxy 与大写 HTTP_PROXY/HTTPS_PROXY 会抛
        # "Item has already been added"。构建走本机环路，无需代理，先移除小写副本。
        foreach ($dup in 'http_proxy', 'https_proxy') {
            if (Get-Item "Env:$dup" -ErrorAction SilentlyContinue) {
                Remove-Item "Env:$dup" -ErrorAction SilentlyContinue
                Write-Host "已移除环境变量 $dup（避免与大写版冲突）" -ForegroundColor DarkGray
            }
        }
        # 用 Start-Process 重定向输出到临时文件再落盘/回显，规避 PowerShell 管道编码问题
        $tmpOut = Join-Path $env:TEMP ("hein_hap_out_$(Get-Random).txt")
        $tmpErr = Join-Path $env:TEMP ("hein_hap_err_$(Get-Random).txt")
        # 转 POSIX 路径传给 Git Bash（Windows 反斜杠路径会被转成 E:codeHeinPlay... 而 127）
        $drive = $buildScript.Substring(0, 1).ToLower()
        $posixScript = '/' + $drive + $buildScript.Substring(2).Replace('\', '/')
        # 注意：不要用 -Wait！PS 5.1 的 -Wait 在子进程树持有重定向句柄时会无限挂起
        #（实测：hvigor 12s 失败后外层仍卡 25min）。改用 WaitForExit(ms) 带超时，
        # 超时则强杀整棵进程树并报错，避免构建卡死拖住整个 build_all。
        $hapTimeoutMs = 60 * 60 * 1000   # 冷构建可能很久（含 native 编译），给 60 分钟
        $proc = Start-Process -FilePath $bashExe -ArgumentList '-c', $posixScript -NoNewWindow -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr -PassThru
        if (-not $proc.WaitForExit($hapTimeoutMs)) {
            Write-Err "build_hap.sh 执行超过 60 分钟，判定超时，强制终止进程树 (PID $($proc.Id))..."
            cmd /c "taskkill /PID $($proc.Id) /T /F" | Out-Null
            throw "build_hap.sh 执行超时"
        }
        if (Test-Path $tmpOut) {
            [System.IO.File]::AppendAllText($logPath, [System.IO.File]::ReadAllText($tmpOut, [System.Text.Encoding]::UTF8), $utf8Bom)
            Get-Content -Path $tmpOut -Encoding utf8 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
        }
        if (Test-Path $tmpErr) {
            [System.IO.File]::AppendAllText($logPath, [System.IO.File]::ReadAllText($tmpErr, [System.Text.Encoding]::UTF8), $utf8Bom)
            Get-Content -Path $tmpErr -Encoding utf8 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
        }
        Remove-Item $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue

        if ($proc.ExitCode -ne 0) {
            throw "build_hap.sh 退出码 $($proc.ExitCode)"
        }

        # 产物：flutter build hap 输出到 ohos/entry/build/...（junction 指向 harmony_haintv）
        $hapOut = Join-Path $hainDir "harmony_haintv\entry\build\default\outputs\default\entry-default-signed.hap"
        if (-not (Test-Path $hapOut)) {
            throw "未找到产物: $hapOut"
        }
        $version = Get-ProjectVersion
        $distName = "heinplay-${version}-harmonyos.hap"
        $distPath = Join-Path $distDir $distName
        New-Item -ItemType Directory -Force -Path $distDir | Out-Null
        Copy-Item -Path $hapOut -Destination $distPath -Force
        Write-Ok "$name 构建成功"
        Write-LocalLink "$name 产物:" $distPath
        return @{ Success = $true; Skipped = $false; LogPath = $logPath }
    }
    catch {
        $errLine = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') EXCEPTION: $_"
        [System.IO.File]::AppendAllText($logPath, "$errLine`n", $utf8Bom)
        Write-Err "$name 构建失败: $_"
        if (Test-Path $logPath) {
            Write-Host "`n--- 最近 30 行日志 ---" -ForegroundColor Yellow
            Get-Content -Path $logPath -Tail 30 | ForEach-Object { Write-Host $_ }
            Write-Host '--- 日志结束 ---' -ForegroundColor Yellow
        }
        return @{ Success = $false; Skipped = $false; LogPath = $logPath }
    }
    finally {
        # 仅删除本次创建的 junction 链接（不会触碰 harmony_haintv 实体内容）
        if ($createdJunction -and (Test-Path $ohosLink)) {
            cmd /c rmdir "$ohosLink" | Out-Null
            Write-Host '已删除临时 ohos junction（harmony_haintv 实体与产物不受影响）' -ForegroundColor DarkGray
        }
    }
}

function Invoke-SelectedBuilds {
    param(
        [switch]$SkipDoctor,
        [switch]$SkipMobile,
        [switch]$SkipTv,
        [switch]$SkipTvlegacy,
        [switch]$SkipWindows,
        [switch]$SkipLinux,
        [switch]$IncludeHap,
        [switch]$Clean
    )

    Write-Host "`nHeinPlay 全平台构建脚本" -ForegroundColor Cyan
    Write-Host "项目根目录: $rootDir" -ForegroundColor Cyan
    Write-Host "Flutter 项目目录: $hainDir" -ForegroundColor Cyan
    # 依赖/构建缓存一律落在项目目录：强制 PUB_CACHE = <工程>/.pub-cache，
    # 杜绝回退 C 盘默认缓存（%LOCALAPPDATA%\Pub\Cache）。
    # 原因：① 鸿蒙 ohpm 要求插件源依赖与工程同盘（否则 00618008 跨盘符）；
    #       ② 默认缓存曾导致 flutter 向 build-profile.json5 注入 C: 绝对 srcPath
    #          使 hvigor schema 校验失败（00303038）；③ 工程级缓存便于整体迁移/清理。
    $pubCache = Join-Path $hainDir '.pub-cache'
    if ($env:PUB_CACHE -ne $pubCache) {
        $env:PUB_CACHE = $pubCache
        Write-Host "PUB_CACHE 已强制指向工程缓存: $pubCache" -ForegroundColor DarkGray
    }
    if ($IncludeHap) {
        Write-Host '包含鸿蒙(HAP)构建' -ForegroundColor Yellow
    }
    if ($Clean) { Write-Host '本次构建将执行 flutter clean' -ForegroundColor Yellow }

    if (-not $SkipDoctor) {
        Invoke-FlutterDoctor | Out-Null
    }

    $depsOk = Invoke-FlutterPubGet -Clean:$Clean
    if (-not $depsOk) {
        Write-Err '依赖准备失败，停止构建。'
        return @{ Success = $false; Results = @() }
    }

    if (-not $SkipWindows) {
        Test-WindowsPlugin | Out-Null
    }

    if ((-not $SkipMobile) -or (-not $SkipTv) -or (-not $SkipTvlegacy)) {
        Test-AndroidSigning | Out-Null
    }

    $version = Get-ProjectVersion
    Write-Host "`n当前构建版本: $version" -ForegroundColor Cyan

    $results = @()

    if (-not $SkipMobile) {
        if ($mobileKeyOk) {
            $r = Invoke-BuildScript '手机版' (Join-Path $hainDir 'scripts\build_mobile.ps1')
            $results += [PSCustomObject]@{
                Platform     = '手机版'
                Status       = if ($r.Success) { '成功' } else { '失败' }
                ArtifactPath = Join-Path $distDir "heinplay-${version}-mobile.apk"
                LogPath      = $r.LogPath
            }
        }
        else {
            Write-Warn '跳过手机版构建：签名文件不完整'
            $results += [PSCustomObject]@{ Platform = '手机版'; Status = '跳过'; ArtifactPath = 'N/A'; LogPath = 'N/A' }
        }
    }

    if (-not $SkipTv) {
        if ($tvKeyOk) {
            $r = Invoke-BuildScript 'TV 版' (Join-Path $hainDir 'scripts\build_tv.ps1')
            $results += [PSCustomObject]@{
                Platform     = 'TV 版'
                Status       = if ($r.Success) { '成功' } else { '失败' }
                ArtifactPath = Join-Path $distDir "heinplay-${version}-tv.apk"
                LogPath      = $r.LogPath
            }
        }
        else {
            Write-Warn '跳过 TV 版构建：签名文件不完整'
            $results += [PSCustomObject]@{ Platform = 'TV 版'; Status = '跳过'; ArtifactPath = 'N/A'; LogPath = 'N/A' }
        }
    }

    if (-not $SkipTvlegacy) {
        if ($tvlegacyKeyOk) {
            $r = Invoke-BuildScript 'tvLegacy 版' (Join-Path $hainDir 'scripts\build_tvlegacy.ps1')
            $results += [PSCustomObject]@{
                Platform     = 'tvLegacy 版'
                Status       = if ($r.Success) { '成功' } else { '失败' }
                ArtifactPath = Join-Path $distDir "heinplay-${version}-tvLegacy.apk"
                LogPath      = $r.LogPath
            }
        }
        else {
            Write-Warn '跳过 tvLegacy 版构建：签名文件不完整'
            $results += [PSCustomObject]@{ Platform = 'tvLegacy 版'; Status = '跳过'; ArtifactPath = 'N/A'; LogPath = 'N/A' }
        }
    }

    if (-not $SkipWindows) {
        Test-SevenZip | Out-Null
        Repair-WindowsNativeDeps
        $r = Invoke-BuildScript 'Windows 版' (Join-Path $hainDir 'scripts\build_windows.ps1')
        $artifactZip = Join-Path $distDir "heinplay-${version}-windows-portable.zip"
        $artifactDir = Join-Path $distDir "heinplay-${version}-windows-portable"
        if ($r.Success -and (Test-Path $artifactZip)) {
            if (-not (Test-Path $artifactDir)) {
                New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null
            }
            Write-Ok "覆盖解压 Windows 产物到 $artifactDir（保留目录内现有数据）"
            Expand-Archive -Path $artifactZip -DestinationPath $artifactDir -Force
        }
        $results += [PSCustomObject]@{
            Platform     = 'Windows 版'
            Status       = if ($r.Success) { '成功' } else { '失败' }
            ArtifactPath = $artifactZip
            LogPath      = $r.LogPath
        }
    }

    if (-not $SkipLinux) {
        $r = Invoke-BuildScript 'Linux 版' (Join-Path $hainDir 'scripts\build_linux_appimage.sh')
        $artifactAppImage = Join-Path $distDir "heinplay-${version}-linux-x86_64.AppImage"
        $linuxStatus = if ($r.Skipped) { '跳过' } elseif ($r.Success) { '成功' } else { '失败' }
        $results += [PSCustomObject]@{
            Platform     = 'Linux 版'
            Status       = $linuxStatus
            ArtifactPath = if ($r.Success -and (Test-Path $artifactAppImage)) { $artifactAppImage } else { 'N/A' }
            LogPath      = $r.LogPath
        }
    }

    if ($IncludeHap) {
        $r = Invoke-BuildHap
        $hapOut = Join-Path $distDir "heinplay-${version}-harmonyos.hap"
        $hapStatus = if ($r.Skipped) { '跳过' } elseif ($r.Success) { '成功' } else { '失败' }
        $results += [PSCustomObject]@{
            Platform     = '鸿蒙版'
            Status       = $hapStatus
            ArtifactPath = if ($r.Success -and (Test-Path $hapOut)) { $hapOut } else { 'N/A' }
            LogPath      = $r.LogPath
        }
    }

    $allSuccess = $true
    if ($results) {
        Write-Section '构建结果汇总'
        $results | Format-Table -AutoSize | Out-String | Write-Host
    }

    $failed = $results | Where-Object { $_.Status -eq '失败' }
    $skipped = $results | Where-Object { $_.Status -eq '跳过' }
    $successCount = ($results | Where-Object { $_.Status -eq '成功' }).Count

    New-Item -ItemType Directory -Force -Path $distDir | Out-Null
    Write-LocalLink '产物输出目录:' (Resolve-Path $distDir).Path

    foreach ($r in $results) {
        if ($r.Status -eq '成功' -and $r.ArtifactPath -ne 'N/A' -and (Test-Path $r.ArtifactPath)) {
            Write-LocalLink "$($r.Platform) 产物:" (Resolve-Path $r.ArtifactPath).Path
        }
    }

    if ($failed) {
        Write-Err "存在构建失败项（成功: $successCount / 总计: $($results.Count)），请查看上方汇总与日志。"
        $allSuccess = $false
    }
    elseif ($skipped) {
        Write-Warn "存在跳过的构建项（成功: $successCount / 总计: $($results.Count)）。"
        $allSuccess = $false
    }
    else {
        Write-Ok '所有构建均成功。'
    }

    return @{ Success = $allSuccess; Results = $results }
}

function Show-MainMenu {
    Clear-Host
    Write-Host "`nHeinPlay 全平台构建菜单" -ForegroundColor Cyan
    Write-Host '========================' -ForegroundColor Cyan
    Write-Host '1. 构建全部版本 (手机 / TV / tvLegacy / Windows)'
    Write-Host '2. 仅构建手机版'
    Write-Host '3. 仅构建 TV 版'
    Write-Host '4. 仅构建 tvLegacy 版'
    Write-Host '5. 仅构建 Windows 版'
    Write-Host '6. 仅构建 Linux 版 (AppImage)'
    Write-Host '10. 仅构建安卓版 (手机 / TV / tvLegacy)'
    Write-Host '11. 除 Linux 外构建全部（含鸿蒙 HAP）'
    Write-Host '12. 仅构建鸿蒙版 (HAP)'
    Write-Host '7. 运行 flutter doctor'
    Write-Host '8. 运行 flutter pub get'
    Write-Host '9. 清理构建缓存 (flutter clean)'
    Write-Host '0. 退出'
    Write-Host ''
    Write-Host '命令行参数示例:' -ForegroundColor DarkGray
    Write-Host '  build_all.bat -SkipWindows          跳过 Windows 构建' -ForegroundColor DarkGray
    Write-Host '  build_all.bat -SkipLinux            跳过 Linux 构建（Windows 上默认尝试 WSL2，无 WSL 则跳过）' -ForegroundColor DarkGray
    Write-Host '  build_all.bat -IncludeHap           额外构建鸿蒙 HAP（默认不参与「构建全部」）' -ForegroundColor DarkGray
    Write-Host '  build_all.bat -SkipDoctor -SkipMobile -SkipTv -SkipTvlegacy -SkipWindows -SkipLinux -IncludeHap   仅构建鸿蒙 HAP' -ForegroundColor DarkGray
    Write-Host '  build_all.bat -Clean                构建前执行 flutter clean' -ForegroundColor DarkGray
    Write-Host ''
    return Read-Host '请输入选项编号'
}

function Read-ReturnOrExit {
    $choice = (Read-Host "`n按 Enter 返回主菜单，或输入 q 退出").Trim()
    return ($choice -notmatch '^[Qq]$')
}

function Exit-Script($code = 0) {
    [Environment]::Exit($code)
}

$nonInteractive = $SkipDoctor -or $SkipMobile -or $SkipTv -or $SkipTvlegacy -or $SkipWindows -or $SkipLinux -or $IncludeHap -or $Clean

if ($nonInteractive) {
    $buildResult = Invoke-SelectedBuilds -SkipDoctor:$SkipDoctor -SkipMobile:$SkipMobile -SkipTv:$SkipTv -SkipTvlegacy:$SkipTvlegacy -SkipWindows:$SkipWindows -SkipLinux:$SkipLinux -IncludeHap:$IncludeHap -Clean:$Clean
    if ($buildResult.Success) { Exit-Script 0 } else { Exit-Script 1 }
}

do {
    $choice = Show-MainMenu
    $continueMenu = $true
    switch ($choice) {
        '1' { Invoke-SelectedBuilds -SkipLinux | Out-Null }
        '2' { Invoke-SelectedBuilds -SkipDoctor -SkipTv -SkipTvlegacy -SkipWindows -SkipLinux | Out-Null }
        '3' { Invoke-SelectedBuilds -SkipDoctor -SkipMobile -SkipTvlegacy -SkipWindows -SkipLinux | Out-Null }
        '4' { Invoke-SelectedBuilds -SkipDoctor -SkipMobile -SkipTv -SkipWindows -SkipLinux | Out-Null }
        '5' { Invoke-SelectedBuilds -SkipDoctor -SkipMobile -SkipTv -SkipTvlegacy -SkipLinux | Out-Null }
        '6' { Invoke-SelectedBuilds -SkipDoctor -SkipMobile -SkipTv -SkipTvlegacy -SkipWindows | Out-Null }
        '10' { Invoke-SelectedBuilds -SkipDoctor -SkipWindows -SkipLinux | Out-Null }
        '11' { Invoke-SelectedBuilds -SkipDoctor -SkipLinux -IncludeHap | Out-Null }
        '12' { Invoke-SelectedBuilds -SkipDoctor -SkipMobile -SkipTv -SkipTvlegacy -SkipWindows -SkipLinux -IncludeHap | Out-Null }
        '7' { Invoke-FlutterDoctor | Out-Null }
        '8' { Invoke-FlutterPubGet | Out-Null }
        '9' { Invoke-FlutterPubGet -Clean | Out-Null }
        '0' { $continueMenu = $false; Exit-Script 0 }
        default { Write-Warn "无效选项: $choice" }
    }
    if ($choice -ne '0') {
        $continueMenu = Read-ReturnOrExit
    }
} while ($continueMenu)

Exit-Script 0
