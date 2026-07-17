# 海因影视 构建指南

本项目为单一代码库双端产出：TV 版与手机版共享业务层，但拥有独立的 UI 入口与壳层。

## 1. 项目结构速览

```
hain_tv/
├── lib/
│   ├── main_tv.dart              # TV 版入口
│   ├── main_mobile.dart          # 手机版入口
│   ├── main_windows.dart         # Windows 桌面版入口
│   ├── app_tv.dart               # TV 版 MaterialApp
│   ├── app_mobile.dart           # 手机版 MaterialApp
│   ├── app_windows.dart          # Windows 桌面版 MaterialApp
│   ├── screens/
│   │   ├── tv/                   # TV 版页面（保持原有逻辑）
│   │   └── mobile/               # 手机版页面（逐步新建）
│   ├── widgets/
│   │   ├── tv/                   # TV 版组件（含焦点系统）
│   │   ├── mobile/               # 手机版组件
│   │   └── common/               # 通用组件
│   ├── models/                   # 共享数据模型
│   ├── services/                 # 共享业务服务
│   ├── player/                   # 共享播放器后端
│   ├── focus/                    # TV 焦点策略（手机版不引用）
│   ├── platform/                 # 平台相关工具
│   └── theme.dart                # 共享设计 token
├── android/app/build.gradle.kts  # 已配置 tv / mobile 两个 flavor
├── windows/                       # Windows 桌面端平台目录
└── scripts/
    ├── build_tv.ps1              # TV 版 release 打包脚本
    ├── build_mobile.ps1          # 手机版 release 打包脚本
    └── build_windows.ps1         # Windows 桌面端 release 打包脚本
```

## 2. 运行调试

### TV 版

```powershell
flutter run -t lib/main_tv.dart --flavor tv
```

### 手机版

```powershell
flutter run -t lib/main_mobile.dart --flavor mobile
```

### Windows 桌面版

```powershell
flutter run -d windows --target lib/main_windows.dart
```

前置条件：

1. 已安装 Visual Studio 2022「使用 C++ 的桌面开发」工作负荷。
2. 已启用 Windows 桌面支持：

```powershell
flutter config --enable-windows-desktop
```

> 提示：若工程位于 `E:` 盘而默认 Pub Cache 在 `C:` 盘，首次构建可能因 Kotlin daemon 跨盘符缓存问题失败。可设置环境变量 `PUB_CACHE=E:\code\HeinPlay\hain_tv\.pub-cache` 后重新执行 `flutter pub get`。

## 3. 图标配置

### TV 版

TV 版图标使用 `../plan/ico.png`，由 `pubspec.yaml` 中的 `flutter_launcher_icons` 配置生成到 `android/app/src/main/res/`。

```powershell
flutter pub run flutter_launcher_icons
```

### 手机版

手机版图标使用 `../plan/mo_ico.png`，由独立的 `flutter_launcher_icons-mobile.yaml` 配置生成到 `android/app/src/mobile/res/`。

```powershell
flutter pub run flutter_launcher_icons:main -f flutter_launcher_icons-mobile.yaml
```

两个 flavor 的图标互相独立，mobile flavor 会优先使用 `src/mobile/res/`，tv flavor 会回退到 `src/main/res/`。

### Windows 桌面版

Windows 桌面版图标使用 `../plan/mo_ico.png`，由独立的 `flutter_launcher_icons-windows.yaml` 配置生成到 `windows/runner/resources/app_icon.ico`。

```powershell
flutter pub run flutter_launcher_icons -f flutter_launcher_icons-windows.yaml
```

该命令**不会**修改 Android 任何版本的图标。

## 4. Release 打包

### 4.1 前置条件

Release 打包需要正确的签名配置与 keystore 文件。

#### TV 版

1. 确认 `android/key.properties` 存在且内容正确：

```properties
storeFile=hain_tv_keystore.jks
storePassword=YOUR_STORE_PASSWORD
keyAlias=your_key_alias
keyPassword=YOUR_KEY_PASSWORD
```

2. 确认 keystore 文件存在于 `android/app/hain_tv_keystore.jks`。
3. **必须使用与旧版本完全相同的 keystore**，否则已安装用户无法覆盖更新。

#### 手机版

1. 复制示例文件：

```powershell
cp android\key-mobile.properties.example android\key-mobile.properties
```

2. 编辑 `android/key-mobile.properties`，填写手机版独立密钥信息：

```properties
storeFile=heinplay-mobile.jks
storePassword=YOUR_STORE_PASSWORD
keyAlias=your_key_alias
keyPassword=YOUR_KEY_PASSWORD
```

> **路径说明**：`storeFile` 是相对于 `android/app/` 目录解析的。手机版 keystore 放在 `android/app/heinplay-mobile.jks`。

3. 确认 `android/app/heinplay-mobile.jks` 存在。
4. 手机版是全新应用，使用新密钥不会影响 TV 版更新。

#### 生成新 keystore（如手机版密钥尚未创建）

```powershell
cd android\app
keytool -genkey -v -keystore heinplay-mobile.jks -alias your_key_alias -keyalg RSA -keysize 2048 -validity 10000
```

按提示设置密码与证书信息。生成的 `heinplay-mobile.jks` 不要提交到 Git。

### 4.2 使用脚本打包（推荐）

脚本会自动读取 `pubspec.yaml` 版本号，构建 release APK，并将产物重命名后复制到 `dist/`。

> **注意**：Flutter 默认输出文件名固定为 `app-tv-release.apk` / `app-mobile-release.apk`，不会自动带版本号。使用下方脚本后，带版本号的 APK 会生成在 `dist/` 目录中。

#### TV 版

```powershell
.\scripts\build_tv.ps1
```

输出：`dist/heinplay-{version}-tv.apk`

#### 手机版

```powershell
.\scripts\build_mobile.ps1
```

输出：`dist/heinplay-{version}-mobile.apk`

#### Windows 桌面版

```powershell
.\scripts\build_windows.ps1
```

输出：`dist/heinplay-{version}-windows-portable.zip`，解压后运行 `hain_tv.exe`。

例如当前 `pubspec.yaml` 版本为 `1.1.5+10`，三个脚本会输出：

- `dist/heinplay-1.1.5-tv.apk`
- `dist/heinplay-1.1.5-mobile.apk`
- `dist/heinplay-1.1.5-windows-portable.zip`

### 4.3 手动打包

如果不需要自动重命名，可直接运行。手动打包的产物文件名仍为 `app-tv-release.apk` / `app-mobile-release.apk`，如需版本号命名请使用 4.2 节的脚本。

#### TV 版

```powershell
flutter build apk --target lib/main_tv.dart --flavor tv --release
```

默认产物：`build\app\outputs\flutter-apk\app-tv-release.apk`

#### 手机版

```powershell
flutter build apk --target lib/main_mobile.dart --flavor mobile --release
```

默认产物：`build\app\outputs\flutter-apk\app-mobile-release.apk`

#### Windows 桌面版

```powershell
flutter build windows --target lib/main_windows.dart --release
```

默认产物：`build\windows\x64\runner\Release\hain_tv.exe`

### 4.4 验证产物

#### 检查签名

TV 版：

```powershell
jarsigner -verify -verbose -certs build\app\outputs\flutter-apk\app-tv-release.apk
```

手机版：

```powershell
jarsigner -verify -verbose -certs build\app\outputs\flutter-apk\app-mobile-release.apk
```

或使用 apksigner（Android SDK 中）：

```powershell
apksigner verify -v build\app\outputs\flutter-apk\app-tv-release.apk
```

#### 检查包名与版本

TV 版：

```powershell
aapt dump badging build\app\outputs\flutter-apk\app-tv-release.apk | findstr package
```

手机版：

```powershell
aapt dump badging build\app\outputs\flutter-apk\app-mobile-release.apk | findstr package
```

应分别看到：

- TV 版：`package: name='com.heinplay.hain_tv'`
- 手机版：`package: name='com.heinplay.mobile'`

### 4.5 常见问题

**Q：Windows 构建提示 `Integrity check failed, please try to re-build project again`？**  
A：这是 `media_kit` 下载 Windows 原生依赖（`mpv-dev-...7z`）时文件损坏或校验失败。解决方法：

```powershell
Remove-Item -Path "E:\code\HeinPlay\hain_tv\build\windows\x64\mpv-dev-x86_64-20230924-git-652a1dd.7z" -Force
flutter clean
flutter pub get
.\scripts\build_windows.ps1
```

如果仍然失败，通常是网络问题导致下载不完整，可尝试开启代理或手动下载对应 7z 文件放到上述路径后重新构建。

**Q：Release 构建提示 `Keystore file not found for signing config 'mobile'`？**  
A：请检查 `android/key-mobile.properties` 中的 `storeFile` 路径是否正确，且 keystore 文件确实存在于 `android/` 目录下。

**Q：Release 构建提示密码错误？**  
A：确认 `keyPassword` 与 `storePassword` 填写正确。如果 keystore 是新创建的，建议先用 `keytool -list -v -keystore` 验证能否打开。

**Q：TV 版 release 安装后提示“签名冲突，无法安装”？**  
A：说明使用的 keystore 与旧版本不一致。必须使用旧版本发布时所用的同一 keystore。

**Q：手机版与 TV 版能否装在同一台设备上？**  
A：可以。两者 applicationId 不同（`com.heinplay.hain_tv` vs `com.heinplay.mobile`），且使用不同签名，不会互相覆盖。

## 5. 签名配置

### TV 版

TV 版保持原有签名配置不变，读取 `android/key.properties`：

```properties
storeFile=hain_tv_keystore.jks
storePassword=YOUR_STORE_PASSWORD
keyAlias=your_key_alias
keyPassword=YOUR_KEY_PASSWORD
```

**包名保持为 `com.heinplay.hain_tv`**，与旧版本一致，确保已安装用户可以正常更新。

### 手机版

手机版使用独立的签名配置，读取 `android/key-mobile.properties`：

```properties
storeFile=heinplay-mobile.jks
storePassword=YOUR_STORE_PASSWORD
keyAlias=your_key_alias
keyPassword=YOUR_KEY_PASSWORD
```

可参考 `android/key-mobile.properties.example` 创建该文件。手机版包名为 `com.heinplay.mobile`，与 TV 版完全不同，不会互相覆盖。

> 注意：`key.properties`、`key-mobile.properties` 以及所有 `.jks` 文件已加入 `.gitignore`，请勿提交到仓库。

## 6. 包名与版本

| 平台   | applicationId          | 版本名后缀 | 说明                     |
|--------|------------------------|------------|--------------------------|
| tv     | com.heinplay.hain_tv   | -tv        | Android TV 版            |
| mobile | com.heinplay.mobile    | -mobile    | Android 手机版           |
| windows| hain_tv.exe            | -windows   | Windows 桌面端，无需包名 |

TV 版与手机版可安装在同一台 Android 设备上，互不覆盖。

## 7. 开发规范

- **不要修改 TV 版业务逻辑**：TV 版已稳定，手机版开发应在 `screens/mobile/` 与 `widgets/mobile/` 中新建。
- **Windows 桌面版复用 TV 版页面**：通过 `DeviceUtils.isTvOverride = true` 标记为 TV 模式，保持焦点、键盘与鼠标悬停逻辑一致。
- **共享层保持 UI 无关**：`models/`、`services/`、`player/` 不应直接引用任何 UI 组件或 `BuildContext`。
- **import 统一使用 package 路径**：例如 `package:hain_tv/screens/tv/home_screen.dart`、`package:hain_tv/services/search_service.dart`。
- **每完成一个页面运行一次 `flutter analyze`**，确保无 import 错误。

## 8. 常见问题

**Q：同时保留 `lib/main.dart` 有什么用？**  
A：`lib/main.dart` 暂时保留为 TV 版兼容入口，指向 `app_tv.dart`。新构建请优先使用 `main_tv.dart` 或 `main_mobile.dart`。

**Q：手机版页面目前只有占位页，如何继续开发？**  
A：参考 `screens/mobile/home_screen.dart` 等占位页，在 `screens/mobile/` 中实现具体页面，然后在 `widgets/mobile/mobile_shell.dart` 的底部导航中替换对应页面即可。

**Q：构建产物文件名不符合预期？**  
A：Flutter 默认输出固定文件名，使用 `scripts/build_tv.ps1`、`scripts/build_mobile.ps1` 或 `scripts/build_windows.ps1` 会自动重命名为 `heinplay-{version}-{platform}.apk` 或 `heinplay-{version}-windows-portable.zip`。

**Q：Windows 版会覆盖或影响 Android 版本吗？**  
A：不会。Windows 版使用独立的入口 `lib/main_windows.dart`、独立的构建产物目录 `build/windows/` 和独立的发布脚本 `scripts/build_windows.ps1`，不会修改任何 Android flavor 的代码或配置。

## 9. 关于 .gitignore

本项目仅在仓库根目录 `e:\code\HeinPlay\.gitignore` 保留一份 `.gitignore`，统一覆盖整个 `HeinPlay` 目录及其子目录。

主要忽略内容：

- `plan/` 目录：存放设计方案、参考项目、图标素材等，不需要纳入版本控制。
- 全局 IDE 配置文件（`.idea/`、`.vscode/`、`*.iml`、`*.ipr`、`*.iws`）。
- Flutter / Dart 构建产物：`.dart_tool/`、`build/`、`.pub-cache/`、`.flutter-plugins`、`.flutter-plugins-dependencies` 等。
- `hain_tv` 项目特有的构建产物与敏感配置：
  - `/hain_tv/android/app/debug/`、`/hain_tv/android/app/profile/`、`/hain_tv/android/app/release/`
  - `/hain_tv/android/key.properties`、`/hain_tv/android/key-mobile.properties`
  - `/hain_tv/android/*.keystore`、`/hain_tv/android/*.jks`
- 根目录下的签名密钥与本地配置（`*.jks`、`key.properties`、`local.properties`）。
- OS 临时文件（`.DS_Store`、`Thumbs.db`）。

由于 `.gitignore` 规则会递归作用于所有子目录，因此无需在 `hain_tv/` 下再维护单独的 `.gitignore`。所有忽略规则集中在根目录管理，便于维护。

## 10. 必须单独保存的密钥文件清单

以下文件均已被 Git 忽略，**不会提交到仓库**，务必单独妥善备份（如云盘、密码管理器、CI 密钥库等）。丢失后将无法发布更新版本。

### TV 版

| 文件 | 路径 | 说明 |
|------|------|------|
| TV 签名密钥库 | `hain_tv/android/app/hain_tv_keystore.jks` | TV 版 release 签名密钥，**必须与旧版本完全一致**，否则用户无法覆盖更新。 |
| TV 密钥配置 | `hain_tv/android/key.properties` | 记录 TV 版 keystore 的别名、密码等信息。 |

> **备份优先级最高**：`hain_tv_keystore.jks`。只要保留该文件，即使 `key.properties` 丢失，也可通过 `keytool` 重新查看别名并尝试回忆密码；但 keystore 丢失则无法恢复。

### 手机版

| 文件 | 路径 | 说明 |
|------|------|------|
| 手机签名密钥库 | `hain_tv/android/heinplay-mobile.keystore` | 手机版 release 签名密钥，与 TV 版完全独立。 |
| 手机密钥配置 | `hain_tv/android/key-mobile.properties` | 记录手机版 keystore 的别名、密码等信息。 |

### 备份建议

1. **不要将上述文件上传到公共 Git 仓库**。它们已在 `.gitignore` 中排除。
2. 建议将 keystore 文件与密码分开存放：
   - keystore 文件备份到加密的本地磁盘或可信云盘。
   - 密码记录到密码管理器或企业密钥管理系统。
3. 发布前确认 CI/CD 或打包机器上有这些文件，否则 release 构建会失败。
4. 若更换开发机器，需手动将这四个文件复制到新环境的相同路径下。

## 11. GitHub Actions 自动构建

仓库已配置 `.github/workflows/build-release.yml`，可在 GitHub 云端自动构建 TV 版、手机版与 Windows 桌面版产物。

### 11.1 工作流说明

工作流文件位于仓库根目录：

```
.github/workflows/build-release.yml
```

包含三个并行任务：

| 任务 | 运行环境 | 输出产物 |
|------|----------|----------|
| build-tv | ubuntu-latest | `heinplay-{version}-tv.apk` |
| build-mobile | ubuntu-latest | `heinplay-{version}-mobile.apk` |
| build-windows | windows-latest | `heinplay-{version}-windows-portable.zip` |

触发条件：

- 推送代码到 `main` / `master` 分支
- 推送 `v*` 标签（如 `v1.1.5`）或纯版本号标签（如 `1.1.5`）
- 对 `main` / `master` 分支发起 Pull Request
- 手动触发（`Actions` → `Build Release` → `Run workflow`）

### 11.2 密钥配置（重要）

**不要把 keystore 文件直接提交到仓库**。GitHub Actions 通过 **Repository Secrets** 安全注入签名信息。

需要配置的 Secrets 如下：

#### TV 版

| Secret 名称 | 说明 |
|-------------|------|
| `TV_KEYSTORE_BASE64` | TV 版 keystore 文件的 Base64 编码 |
| `TV_KEYSTORE_PASSWORD` | keystore 的 storePassword |
| `TV_KEY_ALIAS` | 密钥别名 |
| `TV_KEY_PASSWORD` | 密钥密码 |

#### 手机版

| Secret 名称 | 说明 |
|-------------|------|
| `MOBILE_KEYSTORE_BASE64` | 手机版 keystore 文件的 Base64 编码 |
| `MOBILE_KEYSTORE_PASSWORD` | keystore 的 storePassword |
| `MOBILE_KEY_ALIAS` | 密钥别名 |
| `MOBILE_KEY_PASSWORD` | 密钥密码 |

> Windows 桌面版当前不需要额外签名 Secret。

### 11.3 将 keystore 转为 Base64

在本地使用以下命令生成 Base64 字符串：

**Windows（PowerShell）：**

TV 版：

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("android\app\hain_tv_keystore.jks")) | Set-Clipboard
```

手机版：

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("android\app\heinplay-mobile.jks")) | Set-Clipboard
```

**macOS / Linux：**

```bash
# TV 版
base64 -i android/app/hain_tv_keystore.jks | pbcopy

# 手机版
base64 -i android/app/heinplay-mobile.jks | pbcopy
```

然后将得到的字符串完整粘贴到对应 Secret 中。具体文件名以你本地 `android/key.properties` 和 `android/key-mobile.properties` 中的 `storeFile=` 为准。

### 11.4 在 GitHub 上配置 Secrets

1. 打开仓库页面，进入 `Settings` → `Secrets and variables` → `Actions`。
2. 点击 `New repository secret`。
3. 按 11.2 节的表格依次添加所有 Secret。
4. 添加完成后，工作流即可在下次触发时读取这些 Secret。

### 11.5 手动触发构建

1. 进入仓库 `Actions` 标签页。
2. 选择左侧 `Build Release`。
3. 点击右上角 `Run workflow`。
4. 选择分支，确认 `upload-artifacts` 选项，点击 `Run workflow`。

### 11.6 下载构建产物

工作流运行完成后：

1. 进入该次运行详情页。
2. 页面底部 `Artifacts` 区域会列出：
   - `heinplay-tv-apk`
   - `heinplay-mobile-apk`
   - `heinplay-windows-portable`
3. 点击即可下载对应产物。

### 11.7 常见问题

**Q：GitHub Actions 提示 keystore 解码失败？**  
A：检查 `TV_KEYSTORE_BASE64` / `MOBILE_KEYSTORE_BASE64` 是否完整复制。Base64 字符串通常较长，确保没有遗漏开头或结尾字符。

**Q：构建成功但 APK 无法覆盖安装旧版本？**  
A：说明云端使用的 keystore 与旧版本不一致。必须上传与旧版本发布时完全相同的 TV 版 keystore。

**Q：只想构建其中某一个平台？**  
A：可以直接在 `.github/workflows/build-release.yml` 中注释掉不需要的 `build-*` job，或复制该文件创建单独的平台工作流。
