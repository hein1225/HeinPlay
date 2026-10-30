#!/usr/bin/env bash
# =============================================================================
# HeinPlay Windows 版 fvp→mpv 改造 · 远程构建驱动脚本
#
# 用途：在 Linux 容器内把改好的代码同步到 Windows 构建机（192.168.8.10），
#       远程执行 build_windows.ps1，产物回收到仓库 dist/。
#
# 为什么需要它：容器内**没有 MSVC**，Flutter Windows 嵌件（C++/WinRT、
#       ANGLE、Impeller）只能由真 MSVC 工具链构建，无法用 mingw 交叉编译。
#
# 前置条件（Windows 侧一次性，见 plan/worklogs/2026-10-22-*.md）：
#   · OpenSSH Server 已装并运行，密钥已授权
#   · VS2022 + "使用 C++ 的桌面开发" 工作负载
#   · Flutter SDK（3.47.5）已装并在 PATH
#
# 用法：
#   ./win_build_remote.sh              # 同步 + 构建 + 回收产物
#   ./win_build_remote.sh --check      # 只探测 Windows 侧工具链，不构建
#   ./win_build_remote.sh --push-only  # 只同步代码，不构建
# =============================================================================
set -euo pipefail

REPO=/workspace/code/HeinPlay
PROJ=$REPO/hain_tv
WIN_HOST=heinwin                 # ~/.ssh/config 里的别名（192.168.8.10）
WIN_PROJ='D:\build\hain_tv'   # Windows 侧工程目录（2026-10-22 全量迁到 D 盘）
LOG_DIR=$REPO/plan/worklogs
STAMP=$(date +%Y%m%d-%H%M%S)

mkdir -p "$LOG_DIR"

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "[FATAL] $*" >&2; exit 1; }

# ---- 0. 连通性 ----
log "探测 $WIN_HOST 连通性 ..."
ssh -o ConnectTimeout=15 -o BatchMode=yes "$WIN_HOST" \
  "powershell -NoProfile -Command \"Write-Host CONNECT_OK\"" >/dev/null 2>&1 \
  || die "无法 SSH 到 $WIN_HOST。请确认 Windows 侧 sshd 在跑、密钥已授权。"

# ---- 1. Windows 侧工具链探测 ----
check_toolchain() {
  log "探测 Windows 侧工具链 ..."
  # 🔴 2026-10-23：原来这里用 ssh + 单引号包裹的嵌套引号 PowerShell，
  #    其中为防 bash 展开而写的 \$ 会被 PowerShell 当成字面反斜杠，
  #    导致 `\$fl` / `\$(if(...))` 全部报 CommandNotFoundException，
  #    退出码非 0 → set -e 直接把整个构建脚本打断（server 上停留在 08:47 的旧 zip）。
  #    改为与 sync_code 相同的做法：PS 写成文件再执行，彻底绕开引号地狱。
  cat > /tmp/hein_probe.ps1 <<'PSEOF'
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
function T($n,$v){ Write-Host ("  {0,-22}: {1}" -f $n,$v) }
T "OS" (Get-CimInstance Win32_OperatingSystem).Caption
$vs = @(
  Get-ChildItem "C:\Program Files\Microsoft Visual Studio" -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName "VC\Auxiliary\Build\vcvars64.bat") }
  Get-ChildItem "D:\Program Files\Microsoft Visual Studio" -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName "VC\Auxiliary\Build\vcvars64.bat") }
) | Select-Object -First 1
T "VS2022" $(if($vs){$vs.Name}else{"NOT FOUND"})
$fl = (Get-Command flutter -ErrorAction SilentlyContinue).Source
T "flutter" $(if($fl){$fl}else{"NOT FOUND"})
if($fl){ T "flutter ver" (& flutter --version --no-version-check 2>$null | Select-Object -First 1) }
$git = (Get-Command git -ErrorAction SilentlyContinue).Source
T "git" $(if($git){$git}else{"NOT FOUND"})
T "7z" $(if(Test-Path "C:\Program Files\7-Zip\7z.exe"){"yes"}else{"no"})
$mpvDll = Join-Path "__WIN_PROJ__" "third_party\mpv-windows\bin\libmpv-2.dll"
T "mpv-windows" $(if(Test-Path $mpvDll){"yes"}else{"MISSING"})
T "CPU" (Get-CimInstance Win32_Processor).Name
$ram = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
T "RAM(GB)" ([math]::Round($ram/1GB,1))
PSEOF
  # 占位符替换：把工程目录写进 PS 脚本（Windows 侧路径用反斜杠）
  python3 - "$WIN_PROJ" <<'PYEOF'
import io, sys
win_proj = sys.argv[1].replace('/', '\\')
p = r'/tmp/hein_probe.ps1'
s = io.open(p, encoding='utf-8').read().replace('__WIN_PROJ__', win_proj)
io.open(p, 'w', encoding='utf-8').write(s)
PYEOF
  scp -q /tmp/hein_probe.ps1 "$WIN_HOST:D:/build/hein_probe.ps1"
  # 探测失败不应中断整体构建（工具链齐不齐由后面的构建步骤自己报错）
  ssh "$WIN_HOST" 'powershell -NoProfile -ExecutionPolicy Bypass -File D:/build/hein_probe.ps1' || \
    log "⚠️  工具链探测返回非 0（不中断，继续尝试构建）"
}

# ---- 2. 同步代码 ----
# 只同步本项目相关目录，避免把整个仓库（含 legacy/安卓主工程）推过去。
sync_code() {
  log "同步代码到 $WIN_HOST:$WIN_PROJ ..."
  # 预建仓库根 dist 目录：build_windows.ps1 靠它判定产物输出位置
  # （2026-10-22 加的兼容逻辑，见脚本内 forceRepoDist）。
  ssh "$WIN_HOST" "powershell -NoProfile -Command \"
    New-Item -ItemType Directory -Force -Path '$WIN_PROJ' | Out-Null
    New-Item -ItemType Directory -Force -Path 'D:/build/dist' | Out-Null
  \""

  # 用 tar 打包再解包，比 scp -r 快且保留权限/时间戳
  # ⚠️ 必须排除 windows/flutter/ephemeral：它是 `flutter pub get` 生成的，
  #    内含指向容器内路径的符号链接（.plugin_symlinks/*），同步到 Windows
  #    后全是断链，Copy-Item 会直接抛 DirectoryNotFoundException。
  #    该目录由远端 flutter build 自动重建，无需也不应同步。
  tar -C "$REPO" -czf /tmp/hein_sync.tgz \
    --exclude='hain_tv/windows/flutter/ephemeral' \
    --exclude='hain_tv/windows/flutter/ephemeral/*' \
    hain_tv/lib \
    hain_tv/src/mpv_desktop \
    hain_tv/windows \
    hain_tv/third_party/mpv-windows/include \
    hain_tv/third_party/mpv-windows/lib \
    hain_tv/third_party/mpv-windows/bin/libmpv-2.dll \
    hain_tv/pubspec.yaml \
    hain_tv/pubspec.lock \
    hain_tv/scripts/build_windows.ps1 \
    2>/dev/null || true

  scp -q /tmp/hein_sync.tgz "$WIN_HOST:D:/build/hein_sync.tgz"
  # 🔴 2026-10-22：不要用 `ssh "... -Command \" ... \$var ... \""` 这种嵌套引号。
  #    实测 PowerShell 收到后 $var 恒为空（Copy-Item 变成 /hain_tv/*，
  #    Remove-Item 缺参数），同步静默失败但脚本仍打印「unpacked」。
  #    改为把 PS 脚本写成文件再执行，彻底绕开引号地狱。
  cat > /tmp/hein_unpack.ps1 <<'PSEOF'
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$tmp = 'D:/build/_unpack'
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
tar -xzf D:/build/hein_sync.tgz -C $tmp
if (-not (Test-Path "$tmp/hain_tv")) { throw "unpack failed: $tmp/hain_tv missing" }
Copy-Item -Recurse -Force "$tmp/hain_tv/*" 'D:/build/hain_tv/'
Remove-Item -Recurse -Force $tmp
Write-Host 'unpacked'
PSEOF
  scp -q /tmp/hein_unpack.ps1 "$WIN_HOST:D:/build/hein_unpack.ps1"
  ssh "$WIN_HOST" "powershell -NoProfile -ExecutionPolicy Bypass -File D:/build/hein_unpack.ps1"
  rm -f /tmp/hein_sync.tgz /tmp/hein_unpack.ps1
  log "同步完成"
}

# ---- 3. 远程构建 ----
build() {
  log "远程执行 build_windows.ps1（这一步可能要几分钟到十几分钟）..."
  # 🔴 2026-10-23：原来写的是 -File '$WIN_PROJ'\\scripts\\build_windows.ps1。
  #    Windows OpenSSH 服务端默认用 cmd.exe 解析命令，cmd 不认单引号，
  #    参数里会带上字面单引号 → 「无法找到文件」。改为正斜杠路径且不加引号
  #    （路径无空格），Windows PowerShell 同样接受正斜杠。
  ssh "$WIN_HOST" "powershell -NoProfile -ExecutionPolicy Bypass -File D:/build/hain_tv/scripts/build_windows.ps1" \
    2>&1 | tee "$LOG_DIR/${STAMP}-win-build.log"
  log "构建日志已存：$LOG_DIR/${STAMP}-win-build.log"
}

# ---- 4. 回收产物 ----
collect() {
  log "回收产物到 dist/ ..."
  mkdir -p "$REPO/dist"
  scp -q "$WIN_HOST:D:/build/dist/*.zip" "$REPO/dist/" 2>/dev/null \
    && log "产物已回收" \
    || log "（未找到 zip，可能构建失败或路径不同，请查日志）"
  ls -la "$REPO/dist/" | tail -5
}

case "${1:-all}" in
  --check)     check_toolchain ;;
  --push-only) sync_code ;;
  all|"")      check_toolchain; sync_code; build; collect ;;
  *) die "未知参数：$1（支持 --check / --push-only / 无参=全流程）" ;;
esac
