# 海因影视 鸿蒙版（HarmonyOS NEXT / OpenHarmony）

本目录是 **鸿蒙独立工程**，与主工程 `hain_tv/` 平级，专门用于构建面向
**HarmonyOS NEXT / OpenHarmony** 的 `.hap` 安装包（手机版形态）。

## 为什么独立成工程

1. **工具链完全不同**：鸿蒙需要 OpenHarmony 移植版 Flutter（`flutter_flutter`），
   官方 Flutter 不含 `ohos` 平台支持；还需 DevEco 的 node/ohpm/hvigor 与 HarmonyOS SDK。
2. **依赖互相干扰**：鸿蒙专属依赖（`shared_preferences` 的 atomgit git 覆盖、
   `fvp` 的 ohos 平台注册）混在主工程会拖累 Android / 桌面两侧的依赖解析，
   且主工程会因 atomgit 可达性受影响。
3. **构建方式冲突**：flutter 工具链硬编码查找 `<工程>/ohos`，主工程实体名是
   `harmony_haintv/`，此前每次构建都要临时 `mklink /J` junction 绕行。

迁出后：鸿蒙工程实体**直接命名为 `ohos/`**，不再需要任何 junction 绕行。

## 关键信息

| 项 | 值 |
|---|---|
| Flutter SDK | `flutter_flutter` 3.41.10-ohos（Dart 3.11.5） |
| 目标 SDK | targetSdkVersion **26.0.0** / compatibleSdkVersion **6.1.0(23)** |
| 应用包名 | `com.heinplay.hain_tv_ohos`（2026-10-12 由 `com.heinplay.hain_tv` 改，已授权） |
| 播放后端 | **mpv（默认，硬解）+ avplayer（兜底）**；fvp 已于 2026-10-06 彻底移除 |
| 入口 | `lib/main_ohos.dart`（复用 `MobileApp`，手机版竖屏形态） |
| 工程实体 | `ohos/`（AppScope + entry + har 依赖包） |
| 签名 | 华为 AGC 正式发布签名，材料在 `ohos/signature/release/`（`heinplay-release.{cer,p7b,p12}`）；一键切换 `bash scripts/use_release_signature.sh` |

## 构建

```powershell
# 双击亦可；等价于 .\scripts\build_ohos.ps1
.\build_ohos.bat

# 出 release 包
.\scripts\build_ohos.ps1 -Release
```

⚠️ **必须在本机 Windows 执行**（需 DevEco 工具链），不能在 WSL/Linux 下跑。

产物输出到**仓库根** `dist/heinplay-<version>-harmonyos.hap`。

## 与主工程的关系

- 主工程 `hain_tv/` **不再包含** `harmony_haintv/`、`lib/main_ohos.dart`、
  `scripts/build_hap.sh`、`scripts/check_hap_signing.js`、`hijack/`、
  `docs/OHOS_PORT_GUIDE.md`，以及 `pubspec.yaml` 中鸿蒙专属的
  `shared_preferences` git 覆盖（已于 2026-09-27 全部迁出）。
- 本工程持有 `lib/` 的独立副本（与 tvLegacy 同样处理），因此鸿蒙端的应用内更新
  检测由本副本自行处理。
- 共享约定（播放后端、平台判定等）仍以主工程为参照，但**不再自动同步** ——
  两侧各自维护，改动按需对搬。

## 本副本相对主工程 lib/ 的差异

| 文件 | 差异 |
|---|---|
| `lib/player/player_backend_factory.dart` | 改为 **avplayer + mpv**：摘除 `exo_player_backend.dart` / `vlc_backend.dart` 的 import 与分支；`availableBackends` 恒为 `[avplayer, mpv]`；`platformDefault`/`platformLiveDefault` 恒为 avplayer（🔴 2026-10-23 由 mpv 改回，mpv 退为备选） |
| `lib/player/exo_player_backend.dart` | **已删除**（鸿蒙无 Android 运行时） |
| `lib/player/exo_player_buffer_config.dart` | **已删除**（同上） |
| `lib/player/vlc_backend.dart` | **已删除**（仅 Windows 实现） |
| `lib/main_*.dart`（除 ohos） | **已删除**（`main.dart` / `main_tv` / `main_mobile` / `main_linux` / `main_windows`） |
| `lib/app_*.dart`（除 mobile） | **已删除**（`app_tv` / `app_linux` / `app_windows`） |

> `lib/screens/` 与 `lib/widgets/` 下的 `tv/`、`windows/`、`linux/` 子目录**保留**：
> 它们被跨平台代码以注释或条件分支方式引用，删除会引发编译错误，且鸿蒙运行期不会走到。

## 发布红线（改动前务必确认）

1. **包名**保持 `com.heinplay.hain_tv_ohos`（2026-10-12 起独立，与主工程 Android 版不同）；
2. **签名**沿用同一套证书，否则无法覆盖升级；
3. **versionCode** 相对已发布版本递增（见 `pubspec.yaml` 的 `version: x.y.z+N`
   与 `ohos/AppScope/app.json5` 的 `versionCode`，**两处需同步**）。

## 已知限制

- **DevEco Studio 无 Linux 版**：只能在 Windows/macOS 构建，本容器（Linux）无法出包。
- **HarmonyOS 闭源 `hms`（`@hms.*` 专有 API）缺失**：OpenHarmony SDK 只含 openharmony 部分；
  若用到专有 API，需登录华为账号下载 6.1+ 版 hms 补回。
- **HAP 发布签名**：已切换为华为 AGC 正式发布签名（见上表）；`heinplay-release.p12` 丢失后将无法更新已上架应用，须离线多地备份。
- 鸿蒙没有 Android 运行时，**系统媒体通知 / 画中画**等 ExoPlayer 专属特性在鸿蒙端不可用。