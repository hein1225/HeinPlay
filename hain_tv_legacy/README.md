# 海因影视 tvLegacy（Android 5.0+ / API 21）

本目录是 **tvLegacy 独立工程**，与主工程 `hain_tv/` 平级，专门用于构建面向
**Android 5.0+（API 21）** 旧电视盒子 / 老设备的安装包。

## 为什么独立成工程

自 Flutter 3.35 起官方把 Android minSdk 提升到 24，主工程使用的新版 SDK 无法再产出
API 21 的包。因此本工程单独固定 **Flutter 3.32.8（Dart 3.8.1）** —— 最后一个原生支持
API 21 的稳定版本，并使用独立的依赖缓存，与主工程工具链完全隔离。

## 关键信息

| 项 | 值 |
|---|---|
| Flutter SDK | `D:\heinplay-legacy\flutter`（3.32.8 / Dart 3.8.1） |
| JDK | `D:\heinplay-legacy\jdk-21.0.2`（由 `android/gradle.properties` 的 `org.gradle.java.home` 钉死） |
| 目标 API | minSdk **21** / targetSdk 36 |
| 应用包名 | `com.heinplay.hain_tv_legacy` |
| 播放后端 | **fvp-only**（ExoPlayer/media3 与 VLC 后端已移除） |
| 签名 | `android/app/heinplay-tvlegacy.jks`（口令见 `android/key-tvlegacy.properties`，两者均不入库） |

## 构建

```powershell
# 双击亦可；等价于 .\scripts\build_tvlegacy.ps1
.\build_tvlegacy.bat
```

也可从仓库根统一构建：`build_all.bat -IncludeTvlegacy`（以独立子进程转发到本工程）。

产物输出到**仓库根** `dist/heinplay-<version>-tvLegacy.apk`。

冷构建约 70 分钟（含 fvp 的 MDK 原生 CMake 编译）；增量通常几分钟。

## CI 构建（GitHub Actions）

仓库根的 `.github/workflows/build-release.yml` 里有独立的 **`build-tvlegacy`** job 构建本工程
（`working-directory: hain_tv_legacy`，`flutter-version: 3.32.8`，JDK 21）。两点值得注意：

- **签名密钥直接复用**：Secrets 属于**仓库**而非某个 workflow，因此迁址后原样引用同一组
  `TVLEGACY_KEYSTORE_BASE64` / `TVLEGACY_KEYSTORE_PASSWORD` / `TVLEGACY_KEY_ALIAS` /
  `TVLEGACY_KEY_PASSWORD` 即可，无需新增或迁移任何密钥。keystore 会被还原到
  `android/app/heinplay-tvlegacy.jks`，口令写入 `android/key-tvlegacy.properties`。
- **本机 JDK 钉死需要在 CI 里摘掉**：`android/gradle.properties` 的
  `org.gradle.java.home` 指向本机 D 盘路径，workflow 里有一步 `sed` 删除它
  （runner 上由 `JAVA_HOME` 决定）。**不要**为了让 CI 通过而把这个本机路径删掉 ——
  本机 Flutter 会优先用 Android Studio 的 JBR 25.x，Gradle 8.12 解析不了该版本号。
- job 末尾会 `keytool` 比对产物证书 SHA256，与发布版指纹不一致即失败（防止误用密钥导致无法升级）。

## ⚠️ 发布红线（改动前务必确认）

老用户能否**覆盖升级**取决于三件事同时成立，任一改动都会导致升级失败：

1. **包名**保持 `com.heinplay.hain_tv_legacy`；
2. **签名**沿用同一个 `heinplay-tvlegacy.jks`（证书 SHA256 `9F:0D:EA:55:…:C8:0C`，CN=HeinPlay tvLegacy）；
3. **versionCode** 相对已发布版本递增（见 `pubspec.yaml` 的 `version: x.y.z+N`）。

## 与主工程的关系

- 主工程 `hain_tv/` **不再包含** `tvlegacy` flavor、`src/tvlegacy/`、tvLegacy 签名配置与
  `LocalizationPlugin` 补丁链（已于 2026-09-21 全部迁出并清理）。
- 本工程持有 `lib/` 的独立副本，因此 tvLegacy 用户的应用内更新检测由本副本自行处理。
- 共享约定（播放后端、手柄输入、平台判定等）仍以主工程为参照，但**不再自动同步** ——
  两侧各自维护，改动按需对搬。
