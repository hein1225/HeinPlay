# mpv 内核依赖契约（HeinPlay 侧唯一真源）

> 本文件是 **HeinPlay 主仓库**关于「mpv 内核从哪来、落到哪去、怎么校验」的唯一权威入口。
> 上游权威文件：`HeinPlayMPV/docs/heinplay-integration.md`（内核仓侧唯一事实来源）。
> 两者冲突时，以上游文件为准，并回来修本文件。

## 一、铁律（违反即视为缺陷）

1. **mpv 内核的权威来源只有一个：独立仓库 [hein1225/HeinPlayMPV](https://github.com/hein1225/HeinPlayMPV)**。
   主仓库 `HeinPlay` **不含任何 mpv 内核文件**（源码 / 二进制 / 构建脚本一律没有）。
2. **版本对应只认固定 tag `mpv-v1.4.1`**（命名规则 `mpv-v<HeinPlay 版本>`）。
   主仓 CI 通过两个 env 指向它：`MPV_DEPS_TAG` / `MPV_DEPS_BASE`（见 `.github/workflows/build-release.yml` 顶部）。
3. **头文件必须与二进制同源**：Android 侧头文件是 mpv **0.41.0**（`mpv-headers-android.tar.gz`），
   Windows / Linux 侧是 mpv master 头（`mpv-headers.tar.gz`）。**不得混用**。
4. **禁止把 `.mpv-build/` 用作 Android 头文件来源**。
   `.mpv-build/` 是**鸿蒙**交叉编译树（mpv master，含 lycium NDK / shaderc 等），
   与 Android 的 0.41.0 不同源 —— 历史上正是在这里发生过一次头/二进制漂移。
   构建脚本已加**硬断言**拦截（见第三节）。

## 二、四个工程各自从哪里取内核

| 工程 | 平台 | 内核来源（本地） | 内核来源（CI / 干净环境） | 落地路径 |
|---|---|---|---|---|
| `hain_tv` | Android 手机 / TV | `.mpv-android/src/mpv`（头）+ `.mpv-android/.../prefix/`（so） | HeinPlayMPV 资产解包 | `third_party/include/mpv/`、`android/app/src/main/jniLibs/<abi>/` |
| `hain_tv_legacy` | Android tvLegacy (API21) | 同上（独立 prefix） | HeinPlayMPV `android-tvlegacy-*` | `third_party/include/mpv/`、`android/app/src/main/jniLibs/<abi>/` |
| `hain_tv` | Windows | `hain_tv/third_party/mpv-windows/` | 同左（CI 解包） | `third_party/mpv-windows/` |
| `hain_tv` | Linux | `hain_tv/third_party/mpv-linux/libmpv.so.2`（缺失才回退系统 libmpv） | 同左（CI 解包 + 安装到系统路径） | `third_party/mpv-linux/`、`third_party/ffmpeg-mini/` |
| `hain_tv_ohos` | HarmonyOS NEXT | `ohos/mpv_arkts/libs/arm64-v8a/`（本地构建，鸿蒙 SDK 不可上云） | 线上鸿蒙 job 已移除 | — |

## 三、构建脚本里的强制检查（防漂移闸门）

| 位置 | 检查 | 失败行为 |
|---|---|---|
| `hain_tv/android/app/build.gradle.kts` | 解析 `MPV_INCLUDE_DIR` 后：`require` 拒绝 `.mpv-build`；`require` 头文件存在；打印实际来源 | 构建直接失败并给出指引 |
| `hain_tv_legacy/android/app/build.gradle.kts` | 同上 | 同上 |
| `hain_tv/android/app/src/main/cpp/CMakeLists.txt` | `FATAL_ERROR` 拒绝 `.mpv-build`；`FATAL_ERROR` 头文件缺失；打印来源 | configure 失败 |
| `hain_tv_legacy/android/app/src/main/cpp/CMakeLists.txt` | 同上 | 同上 |
| `hain_tv/linux/CMakeLists.txt` | 优先 `third_party/mpv-linux/libmpv.so.2`，缺失才 `find_library` 系统 mpv | 静默回退（已记录，见下） |
| `tools/check_mpv_deps.sh` | 一键巡检四个工程的来源路径与关键文件，打印来源与校验值 | 非零退出即异常 |

Linux 的"系统 mpv 回退"是**已知偏差**：本地若未解包 `third_party/mpv-linux`，会链到系统 libmpv（Debian trixie 为 0.40），
与 CI 的自编译 ABI 2.6 不同源。**发版前必须先跑 `tools/check_mpv_deps.sh` 确认走的是随包分发那份。**

## 四、换版本时怎么做（不可跳步）

1. 在 HeinPlayMPV 仓打新 tag `mpv-v<新版本>`，打包并发布资产（`scripts/pack_release.sh`）；
2. 更新 HeinPlayMPV `docs/heinplay-integration.md` 的 tag ↔ 资产 ↔ 落地路径表；
3. 改 HeinPlay `.github/workflows/build-release.yml` 的 `MPV_DEPS_TAG`；
4. 本地跑 `tools/check_mpv_deps.sh`，再跑一次**模拟 CI 的干净构建**（移走 `.mpv-android`，只用 `third_party` 头文件）；
5. 四个工程全部构建通过后，再更新本文件与 `CHANGELOG.md`。

## 五、本地构建树（不属于版本管理，禁止当作内核来源）

| 目录 | 是什么 | 大小 | 能否删 |
|---|---|---|---|
| `.mpv-android/` | mpv-android 构建树（Android 内核本地编译用，含 deps/prefix） | ~2.7G | ❌ 删了要重编 mpv |
| `.mpv-build/` | 鸿蒙交叉编译树（lycium NDK + shaderc + mpv master） | ~8.6G | ❌ 删了要重编鸿蒙内核 |

两者都已被 `.gitignore` 排除，**只服务于本地重建**，CI 不使用；
CI 一律走 HeinPlayMPV 的 Release 资产。`.mpv-build/` 尤其只属鸿蒙，不要挪作他用。
