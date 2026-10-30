# =============================================================================
# HeinPlay Windows 构建机（192.168.8.10 / HEINCI-SERVER）SSH 长期密钥授权脚本
#
# 用法：在 192.168.8.10 上，以【管理员身份】打开 PowerShell，整段粘贴执行。
#       可重复执行（幂等），不会重复写入同一行公钥。
#
# 作用：把 DSH 容器的长期密钥写入 Windows sshd 的 authorized_keys，
#       使容器可以永久免密远程执行 Windows 构建（Flutter Windows 嵌件必须 MSVC，
#       容器内无法交叉编译）。
#
# 密钥对存放位置（容器侧，勿外传私钥）：
#   私钥 /workspace/.ssh_router/id_ed25519_heinwin
#   备份 /opt/team/tool-deps/ssh/keys/id_ed25519_heinwin (+ .sha256)
#   别名 ~/.ssh/config -> Include /workspace/.ssh_router/config  (Host heinwin)
# =============================================================================

$pub = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK5y9ZBcd4gm/YE67PZg5mzBN6cgIUBocY9IeWNfwYvr dsh-heinplay-build@heinwin-server-192.168.8.10'

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "== 1/4 检查 sshd 服务 ==" -ForegroundColor Cyan
$sshd = Get-Service sshd -ErrorAction SilentlyContinue
if (-not $sshd) {
    Write-Host "未找到 sshd 服务，请先安装 OpenSSH Server："
    Write-Host "  Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0"
    Write-Host "  Start-Service sshd; Set-Service -Name sshd -StartupType Automatic"
    exit 1
}
if ($sshd.Status -ne 'Running') { Start-Service sshd; Write-Host "sshd 已启动" }
else { Write-Host "sshd 运行中" }

Write-Host "== 2/4 写入公钥 ==" -ForegroundColor Cyan
$targets = @(
    "$env:ProgramData\ssh\administrators_authorized_keys",   # 管理员组账号走这里
    "$env:USERPROFILE\.ssh\authorized_keys"                 # 普通账号走这里
)
foreach ($ak in $targets) {
    $dir = Split-Path $ak
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    if (-not (Test-Path $ak)) { New-Item -ItemType File -Path $ak | Out-Null }
    if (-not (Select-String -Path $ak -SimpleMatch $pub -Quiet)) {
        Add-Content -Path $ak -Value $pub
        Write-Host "已追加: $ak" -ForegroundColor Green
    } else {
        Write-Host "已存在，跳过: $ak" -ForegroundColor DarkGray
    }
}

Write-Host "== 3/4 修正权限 ==" -ForegroundColor Cyan
# sshd 对 authorized_keys 权限极严：仅允许 SYSTEM/Administrators 完全控制，且不继承
foreach ($ak in $targets) {
    if (Test-Path $ak) {
        icacls $ak /inheritance:r /grant:r "Administrators:F" "SYSTEM:F" | Out-Null
        icacls $ak | Out-Null
    }
}
$userSsh = "$env:USERPROFILE\.ssh"
if (Test-Path $userSsh) {
    icacls $userSsh /inheritance:r /grant:r "$env:USERNAME:(OI)(CI)(F)" | Out-Null
}

Write-Host "== 4/4 重启 sshd 并校验 ==" -ForegroundColor Cyan
Restart-Service sshd
Start-Sleep -Seconds 2
Get-Service sshd | Format-Table Name, Status -AutoSize

Write-Host ""
Write-Host "完成。现在可以回到容器执行：" -ForegroundColor Green
Write-Host "  ssh heinwin 'echo CONNECT_OK'"
Write-Host "  bash hain_tv/scripts/win_build_remote.sh --check"
