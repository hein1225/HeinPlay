# 海因影视（hain_tv）鸿蒙（HarmonyOS / OpenHarmony）移植教程

> 目标：在现有 Flutter 工程基础上，产出手机版 `.hap`，**视频层只保留 fvp（libmdk）一个播放器**。
> 适用 Flutter 分支：OpenHarmony TPC / CPF-Flutter 的 `flutter_flutter`。
> **版本选择（重要）**：生产用 **`3.27.4-ohos`**（分支 `oh-3.27.0-release`，最新 1.0.3，基于上游 3.27.4，稳定）；`oh-3.35.7-dev` 只是**技术预览/学习分支，不建议用于生产**。仓库已从 openharmony-tpc 迁移到 CPF-Flutter 组织（旧地址仍可访问，新地址 `https://atomgit.com/openharmony-tpc/flutter_flutter` 或 CPF-Flutter/flutter_flutter）。
> 本机现状：只有 Google 官方 Flutter 3.47.0，**没有**鸿蒙工具链，无法在此机器直接产出 `.hap`。
> 本教程所有 Dart 侧移植改动已落地（见「已完成的代码改动」），剩下的是装工具链 + 生成 `ohos/` 壳 + 处理依赖兼容。

---

## 0. 已完成的代码改动（无需你再写）

| 文件 | 改动 |
|------|------|
| `lib/player/player_backend_factory.dart` | 新增 `_restoreOhosFvp()`；`platformDefault`/`availableBackends` 在鸿蒙端返回 **仅 fvp**；`create()` 的 fvp 分支在鸿蒙注册 fvp |
| `lib/main_ohos.dart`（新增） | 鸿蒙入口，复用 `MobileApp`，仅注册 fvp，不引入桌面依赖 |
| `pubspec.yaml` | 无需改（fvp `^0.38.1` 已支持鸿蒙；安卓/Windows 专属依赖在下方「依赖兼容」处理） |

> 平台判断用 `Platform.operatingSystem == 'ohos'`（而非 `Platform.isOhos`），这样**官方 Flutter SDK 也能编译通过**，不会卡在 CI。

---

## 1. 需要安装什么（清单）

| 工具 | 用途 | 体积估算 |
|------|------|----------|
| **flutter_flutter**（OpenHarmony 分支，如 `3.27.4-ohos`） | 替代官方 Flutter，提供 `flutter build hap` 等命令 | ~1–2 GB（git 仓库 + 缓存） |
| **JDK 17** | flutter_flutter 构建强制要求（低版本不兼容），Oracle JDK 17 或等价发行版 | ~0.3 GB |
| **DevEco Studio** | 鸿蒙官方 IDE，用于 SDK 管理、签名、模拟器 | ~2 GB |
| **HarmonyOS SDK**（API 12+ / HarmonyOS 5.0+） | 编译/运行所必需的原生 SDK | ~5–8 GB |
| **Command Line Tools**：`ohpm`、`hvigor` | 包管理 + 构建编排（随 SDK 或 DevEco 附带） | 小 |
| **签名证书** | 真机/Release 需 AG 实名证书；**模拟器可用 DevEco 自动生成的调试证书** | — |
| （可选）**鸿蒙模拟器 / 真机** | 运行验证 | — |

> 合计约 **10 GB+ 下载 + 安装空间**。需要联网，且 DevEco 是 GUI 安装器，建议在本地机器执行，而非受限沙箱。

---

## 2. 安装步骤

### 2.1 克隆 flutter_flutter（鸿蒙分支）

```bash
# 建议放在用户目录，避免与官方 Flutter 混用
# 生产推荐：3.27.4-ohos（分支 oh-3.27.0-release）
git clone -b oh-3.27.0-release https://gitcode.com/openharmony-tpc/flutter_flutter.git ~/flutter_flutter
# 仓库已迁移至 CPF-Flutter 组织，新地址也可用：
# git clone -b oh-3.27.0-release https://atomgit.com/openharmony-tpc/flutter_flutter.git ~/flutter_flutter
# （gitee.com/openharmony-sig 为旧镜像，已停更，勿用）

cd ~/flutter_flutter
./bin/flutter --version
```

### 2.2 配置环境变量

把下面内容写进你的 shell 配置（`~/.bashrc` / `~/.zshrc` / PowerShell `$PROFILE`）：

```bash
# 鸿蒙 Flutter 工具链（优先于官方 Flutter）
export PATH="$HOME/flutter_flutter/bin:$PATH"

# 鸿蒙 SDK 根目录（安装 SDK 后指向实际路径，例如 ~/HarmonyOS/Sdk）
export OHOS_SDK_HOME="$HOME/HarmonyOS/Sdk"

# NDK / toolchain（SDK 内自带，按实际路径调整）
export OHOS_NDK_HOME="$OHOS_SDK_HOME/native"
```

> Windows（PowerShell）示例：
> ```powershell
> $env:PATH = "C:\Users\you\flutter_flutter\bin;" + $env:PATH
> $env:OHOS_SDK_HOME = "C:\Users\you\HarmonyOS\Sdk"
> ```

### 2.3 安装 DevEco Studio

1. 到华为开发者联盟下载 **DevEco Studio**（最新版）：https://developer.huawei.com/consumer/cn/deveco-studio/
2. 一路默认安装。
3. 首次启动 → **SDK Manager** → 勾选 **HarmonyOS SDK**（API 12 / HarmonyOS 5.0+）、**Command Line Tools（ohpm、hvigor）**、**Native（NDK）**、**Emulator**（如需模拟器）。
4. 记下 SDK 安装路径，回填 `OHOS_SDK_HOME`。

### 2.4 验证工具链

```bash
flutter --version            # 应显示 flutter_flutter 3.27.4-ohos（或所用分支）
flutter doctor               # 检查 ohos 相关项是否为 ✓
flutter devices              # 连上模拟器/真机后这里会出现 ohos 设备
```

---

## 3. 生成 `ohos/` 原生壳

在工程根目录（`hain_tv/`）执行：

```bash
cd hain_tv
flutter create --platforms=ohos .
```

这会生成 `ohos/` 目录（ArkTS 入口 `EntryAbility.ets`、`module.json5`、`build-profile.json5`、`oh-package.json5` 等），并把 ohos 注册为工程支持平台。

> ⚠️ 该命令可能修改 `pubspec.yaml` / `lib/main.dart` 的少量样板。因为我们已有 `lib/main_ohos.dart`，**不要**让它覆盖我们的入口逻辑；生成后确认 `lib/main.dart` 未被改成鸿蒙专属内容（如有，保持原样或删除，用 `-t` 指定入口即可）。

### 3.1 指定鸿蒙入口为 `main_ohos.dart`

构建/运行时用 `--target` 指向我们新建的入口：

```bash
# 调试运行到模拟器
flutter run -d ohos -t lib/main_ohos.dart

# 发布构建
flutter build hap --target-platform ohos-arm64 --release -t lib/main_ohos.dart
```

（若想让 `ohos/` 默认就用 `main_ohos.dart`，可改 `ohos/entry/src/main/ets/.../EntryAbility.ets` 里 FlutterEntry 的 `getEntryPoint` / 或在 `build-profile.json5` 配置 target，具体以生成的模板为准。）

---

## 4. 依赖兼容性处理（最关键、最易卡的一步）

本工程有两类「非鸿蒙」依赖，鸿蒙构建会因为它们**没有 ohos 实现而报错**：

### 4.1 桌面专属（只在 Windows 用到）
- `win32`、`window_manager`、以及本地副本 `deps/vlc_player_windows`（`vlc_player`）。
- 这些**只**被 `main_windows.dart` / `vlc_backend.dart` 引用。`main_ohos.dart` 不引用它们，但 `vlc_backend.dart` 被共享的 `player_backend_factory.dart` 顶层 `import` 了，所以鸿蒙构建仍会尝试解析 `vlc_player` → 失败。

### 4.2 安卓专属（只给 ExoPlayer 用）
- 本地副本 `deps/video_player_android`（`video_player_android`）。鸿蒙不用 ExoPlayer，`exo_player_backend.dart` 同样被工厂顶层引用 → 构建会尝试解析该插件 → 失败。

### 4.3 推荐解法：给两个本地插件副本加 ohos 桩（可维护，单代码库）

`deps/video_player_android` 与 `deps/vlc_player_windows` 是我们自己控制的 path 依赖，给它们各自补一个**空实现的 ohos 平台支持**即可让鸿蒙构建通过（运行时不会走到——鸿蒙只走 fvp）：

1. 在插件副本内新增 `ohos/` 目录（ArkTS/NAPI 空实现，参考 OpenHarmony TPC 插件模板）。
2. 在插件副本的 `pubspec.yaml` 的 `flutter.plugin.platforms` 下增加：
   ```yaml
   ohos:
     package: <插件包名>
     pluginClass: <PluginClass>   # 空实现类
     # 不需要 native 代码时可用 dartOnly / 占位
   ```
3. 该空实现类只实现「不支持/无操作」分支（鸿蒙永不调用 ExoPlayer/VLC 路径）。

> 这是 OpenHarmony TPC 官方推荐的「为插件补 ohos 支持」做法，能保证单一代码库、不破坏安卓/Windows 现有构建。

**更省事的做法**：在插件副本目录内直接执行官方命令即可自动生成 ohos 空实现骨架：
```bash
cd deps/video_player_android && flutter create . --template=plugin --platforms=ohos
cd ../vlc_player_windows && flutter create . --template=plugin --platforms=ohos
```

> ⚠️ **版本约束冲突**：`deps/video_player_android/pubspec.yaml` 写的是 `flutter: ">=3.44.0"`，而当前 OHOS 稳定分支（3.27.4-ohos / 3.35.7-dev）对应的上游 Flutter 都 **低于 3.44**，会导致 `flutter pub get` 解析失败。两种处理：① 把该本地副本的 `flutter` 约束降到 `>=3.22.0`（安卓端用官方 3.47 仍满足，不影响安卓/Windows 构建）；② 或暂时用第 4.4 节的「注释掉 override + 顶层 import」方式让 OHOS 构建完全不解析这两个插件。

### 4.4 快速替代法（临时验证用）
若只想先跑通一个鸿蒙包验证 fvp 播放，可在**专用于鸿蒙构建的分支**上：
- 把 `pubspec.yaml` 里 `vlc_player`、`video_player_android` 及其 `dependency_overrides` 注释掉；
- 把 `player_backend_factory.dart` 顶层对 `exo_player_backend.dart` / `vlc_backend.dart` 的 `import` 注释掉（鸿蒙只调 fvp，`create()` 的 exo/vlc 分支不会被命中，编译期也不会再拉这两个插件）。

> 此法改动最小、最快验证，但会偏离主分支，仅建议作为「先打通再回头补桩」的临时手段。

### 4.5 其余跨平台插件的 ohos 支持需逐个确认
`permission_handler`、`screen_brightness`、`volume_controller`、`wakelock_plus`、`open_filex`、`url_launcher`、`package_info_plus`、`qr_flutter`、`flutter_js`、`cached_network_image`、`visibility_detector`、`xml`、`dio`、`http`、`shared_preferences`、`path_provider` 等，请执行 `flutter pub get` 后看是否报「xxx doesn't support ohos」。近期版本大多已有 ohos 支持；报错的就升级到带 ohos 的版本，或替换为 ohos 兼容替代品。

---

## 5. 构建与运行

```bash
cd hain_tv
flutter pub get
flutter analyze -t lib/main_ohos.dart        # 可选，先过静态检查

# 模拟器调试
flutter run -d ohos -t lib/main_ohos.dart

# 发布包（需签名）
flutter build hap --target-platform ohos-arm64 --release -t lib/main_ohos.dart
```

产物位置：`hain_tv/ohos/entry/build/default/outputs/default/*.hap`

### 5.1 签名
- **模拟器 / 调试**：DevEco 首次运行会自动生成调试签名（`build-profile.json5` 的 `signingConfigs` 自动填充），无需手动。
- **真机 / Release**：需在华为开发者联盟申请 **AG 调试/发布证书 + Profile**，在 DevEco 的 **Project Structure → Signing Configs** 填入，或在 `build-profile.json5` 配置。
- ⚠️ 不要提交真实签名材料（`*.p12` / `*.cer` / `*.p7b` 路径与密码），提交前清空 `signingConfigs`。

---

## 6. 验证清单（移植完成后逐项确认）

- [ ] 启动无黑屏（复用 `splash_mobile.jpeg`，`main_ohos` 不阻塞解码封面）
- [ ] 登录页可登录，登录后「继续观看 / 播放记录 / 收藏夹」正常加载（此前已修的同步逻辑复用）
- [ ] 点播播放正常（fvp 渲染，IPTV 源能连）
- [ ] 切集 / 切源不卡死（此前 `PlayerSwitchGate` 复用）
- [ ] 直播播放 + 最小化/待机恢复不闪退（此前全安卓修复的逻辑，鸿蒙走 fvp 同路径）
- [ ] 设置内「切换播放器」只显示 FVP（鸿蒙 `availableBackends` 仅 fvp）
- [ ] 明/暗主题切换正常
- [ ] `flutter analyze` 无错误

---

## 7. 已知限制

1. **本机无法出包**：当前机器只有官方 Flutter，缺 DevEco + SDK，需你在本机按第 2 节装好工具链后执行第 3–5 节。
2. **ExoPlayer / VLC 在鸿蒙彻底不可用**：符合「只留 fvp」的需求，但意味着安卓专属的系统媒体通知 / 画中画等特性在鸿蒙端没有。
3. **两个本地插件副本需补 ohos 桩**（第 4.3 节），否则 `flutter build hap` 会在插件解析阶段失败。这一步需要鸿蒙 SDK 才能真正编译/调试桩代码。
4. **播放器内手势/控件**：手机版竖屏控件沿用 `MobileApp`，鸿蒙是触屏形态，体验与安卓手机版一致。
