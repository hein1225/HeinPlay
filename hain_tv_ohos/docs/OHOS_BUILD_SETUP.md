# 鸿蒙（HarmonyOS NEXT）构建环境搭建与踩坑记录

> 适用工程：`hain_tv_ohos/`（包名 `com.heinplay.hain_tv_ohos`，versionName `1.4.0` / versionCode `24`）
> 目标：在 **Linux 容器 / CI** 环境下，用命令行完整构建出**已签名**的 `.hap`
> 状态：✅ 已打通（2026-09-27 首次构建成功）
>
> 🔴 **包名已于 2026-10-12 变更**：`com.heinplay.hain_tv` → **`com.heinplay.hain_tv_ohos`**
> （与主工程 Android 版区分，已授权）。本文下文凡出现旧包名处均为历史记录。
>
> 🔴 **产物体积已变化**：当前 release 产物约 **68 MB**（71,697,821 字节，2026-10-15）。
> 早期记录的「约 145 MB / 151,873,957 字节」是 fvp 时代的 debug 包，**已不适用**；
> 且当前产物**不含** `libmdk.so` / `libfvp.so`（fvp 已移除，见第 5 节实测清单）。

---

## 0. 一句话结论

Linux 下可以完整构建鸿蒙 HAP，但需要**一套可写的工具链镜像 + 若干环境补丁**。
本仓库把这些补丁全部固化进脚本，复现只需两条命令：

```bash
cd hain_tv_ohos
source scripts/env_ohos_linux.sh          # 载入工具链与补丁环境
bash scripts/gen_ohos_signature.sh        # 生成签名材料（仅首次/换机时需要）
flutter build hap --debug -t lib/main_ohos.dart
```

产物落在 `ohos/entry/build/default/outputs/default/entry-default-signed.hap`。

---

## 1. 构建环境（2026-10-22 已改为直接用 team 目录）

工具链位于 **`/opt/team/tool-deps/`**，由 `scripts/env_ohos_linux.sh` 统一注入环境变量。

> 🔴 **本节旧结论已作废**。原文档称「`/opt/team` 在 DSH 沙箱下只读、必须复制到
> `.deps-staging/`（13GB）」。实测该「只读」只在 `workspace-write` 沙箱策略下成立；
> 当前会话为 `danger-full-access`，`/opt/team/tool-deps` **可写**。
> 因此 `.deps-staging/` 镜像（4.6GB）已于 2026-10-22 **删除**，
> Flutter / ohpm / hvigor 直接回写 team 目录下的缓存。

`env_ohos_linux.sh` 现在的关键导出：

| 变量 | 值 | 用途 |
| --- | --- | --- |
| `TEAM_TOOLS` | `/opt/team/tool-deps` | 工具与依赖的唯一存放位置 |
| `FLUTTER_OHOS_HOME` | `$TEAM_TOOLS/ohos/flutter_flutter-oh-3.41.10` | 鸿蒙 Flutter SDK |
| `OHOS_CLT` | `$TEAM_TOOLS/ohos/command-line-tools` | DevEco 命令行工具 |
| `DEVECO_SDK_HOME` | `$OHOS_CLT/sdk` | SDK 根目录 |
| **`HOME`** | **`$TEAM_TOOLS/cache/ohos-home`** | ohpm / hvigor / node 的缓存写入点 |
| `PUB_CACHE` | `$TEAM_TOOLS/cache/pub-cache` | Dart 依赖缓存（三工程共用一份） |
| `HVIGOR_NODE_PATH` | `$TEAM_TOOLS/cache/hvigor-node-modules` | hvigor 插件软链（`NODE_PATH`） |

> 仍需要写入的位置与用途不变：`<flutter>/bin/cache/*.stamp`（Flutter 启动校验）、
> `$HOME/.ohpm`（ohpm 依赖缓存）、`$HOME/.hvigor`（hvigor 工程缓存与插件链接）、
> `$HOME/.pub-cache`（Dart 依赖缓存）—— 只是这些路径现在都落在 team 目录内。

---

## 2. 工具链版本组合（已验证可用）

| 组件 | 版本 | 说明 |
| --- | --- | --- |
| Flutter (OHOS 分支) | `3.41.10-ohos` | 来自 openharmony-tpc / CPF-Flutter |
| Dart | `3.11.5` | 随上述 Flutter |
| hvigor / hvigor-ohos-plugin | `6.26.8` | 从 `https://repo.harmonyos.com/npm/` 安装 |
| DevEco Node | `v18.20.1` | 随 command-line-tools |
| ohpm | `5.1.3` | 随 command-line-tools |
| JDK | `17.0.20.1+1` | 用于 hap-sign-tool |

> `hvigor-config.json5` 与 `oh-package.json5` 里的 `modelVersion` 都是 `26.0.0`，
> 因此 hvigor 必须是 6.x。CLT 自带的 `hvigor-5.18.5` 会直接报
> `00303028 Unsupported modelVersion of Hvigor 26.0.0`，需替换。

---

## 3. 关键补丁清单（全部必要，缺一不可）

以下补丁针对的是「**用 OpenHarmony SDK 冒充 HarmonyOS SDK**」这一现实约束。
本机只有 OpenHarmony 格式的 SDK（组件元数据叫 `oh-uni-package.json`），
而工程 `runtimeOS` 是 `HarmonyOS`，hvigor 会按 HMS 规则去校验。
因此必须做兼容性适配。**这些是构建环境补丁，不是上游代码问题。**

### 3.1 hvigor 插件模块解析（Linux 特有）

**症状**：`00302039 Failed to load or execute hvigorfile.ts: Cannot find module '@ohos/hvigor-ohos-plugin'`

**原因**：Windows 上 hvigorw 用 junction 把 `@ohos/hvigor(-ohos-plugin)` 链进
`<HOME>/.hvigor/project_caches/<hash>/workspace/node_modules`，然后依赖 Node 的
**向上查找**解析工程 `hvigorfile.ts` 里的 import。Linux 下该查找链从工程目录出发，
走不到 workspace 那层。

**补丁**（已固化在 `env_ohos_linux.sh`）：建一个固定目录放软链，用 `NODE_PATH` 挂上。
`NODE_PATH` 是 `require` 的**最终兜底**，对「工程侧 require 插件」和「插件侧 require hvigor」都生效。

```bash
export HVIGOR_NODE_PATH=$STAGE/hvigor-node-modules
mkdir -p "$HVIGOR_NODE_PATH/@ohos"
for p in hvigor hvigor-ohos-plugin; do
  ln -sfn "$OHOS_CLT/hvigor/$p" "$HVIGOR_NODE_PATH/@ohos/$p"
done
export NODE_PATH="$HVIGOR_NODE_PATH${NODE_PATH:+:$NODE_PATH}"
```

> 踩坑：**不要**把 glob（如 `$HOME/.hvigor/project_caches/*/...`）写进 `NODE_PATH` 赋值 ——
> shell 在赋值语境下不做 glob 展开，会留下字面 `*`，导致解析失败。

### 3.2 SDK 目录结构改造（冒充 HMS）

**症状**：`00303312 Cannot find the corresponding SDK version under the specified SDK path.`

**原因**：`HmosSdkLoader.checkSdkVersionMatch()` 要求 SDK 的 `fullVersion` 等于
`HosVersionMapper.getLatestSupportVersion().getFullBaseApi()`，即 **`26.0.0`**
（来自 `hos-config.json` 的 `osVersionMapper` 最新项）。而本机 SDK 是 6.1.0 格式。

**补丁**：在 `$DEVECO_SDK_HOME/` 下新建 `default/` 目录，放一份 `sdk-pkg.json`，
并把各组件软链过去：

```jsonc
// $DEVECO_SDK_HOME/default/sdk-pkg.json
{
  "apiVersion": "26",
  "displayName": "HarmonyOS NEXT2 26.0.0",
  "path": "HarmonyOS NEXT2",
  "platformVersion": "26.0.0",
  "releaseType": "Beta",
  "version": "26.0.0.38",
  "stage": "Beta"
}
```

```
sdk/default/
├── sdk-pkg.json
├── openharmony/{ets,js,native,previewer,toolchains} -> ohos-sdk-26.0.0/default/openharmony/<c>
└── hms/{ets,js,native,previewer,toolchains}         -> 同上
```

### 3.3 组件元数据文件名差异

**症状**：`00303168 Missing SDK components. missing components: toolchains,ets,native.`

**原因**：hvigor 对两侧要求**不同文件名**：

| 侧 | 元数据文件名 |
| --- | --- |
| OpenHarmony | `oh-uni-package.json` |
| HMS | `uni-package.json` |

**补丁**：在每个组件目录里，把 `oh-uni-package.json` **复制**一份为 `uni-package.json`。

### 3.4 `externalconfig.json` 缺失

**症状**：`00305010 Syntax Error / Cannot read properties of undefined (reading 'ets')`

**原因**：`ets-loader/lib/external_component_map.js` 的 `concatenateEtsOptions()` 会读
`ets-loader/components/externalconfig.json` 并取 `.config`，文件不存在时得到 `undefined`。

**补丁**：新建该文件，给出空的组件声明：

```json
{ "compilerOptions": { "ets": { "components": [], "extend": { "components": [] } } } }
```

### 3.5 `libimage_transcoder_shared.so` 缺失

**症状**：`11201001 Dependency Error / Failed to load the library '.../hms/toolchains/lib/libimage_transcoder_shared.so', path invalid`

**原因**：`process-resource.js` 会无条件调用
`OptCompressionBuilder.setExtensionPath(this.sdkInfo.getLibimageTranscoderShared())`。
该 `.so` 是 HMS 专有的 restool 图像压缩依赖，OpenHarmony SDK 里没有（全盘搜索无果）。

**补丁**：把 `hvigor-ohos-plugin/src/sdk/info/hos-sdk-info.js` 里的
`getLibimageTranscoderShared()` 改为返回空串：

```js
// 原: getLibimageTranscoderShared(){return this.hosToolchainsComponent.getLibimageTranscoderShared()}
getLibimageTranscoderShared(){return ""}
```

> 代价：资源不做图像压缩优化。对功能无影响，仅影响包体。

### 3.6 `id_defined.json` 重复定义

**症状**：`11211012 Resource Pack Error: The names 'ohos_id_color_foreground' and
'ohos_id_color_foreground' in the id_defined.json file define the same ID.`

**原因**：因为 `hms/` 与 `openharmony/` 是**同一目录的软链**，同一个 `id_defined.json`
被注入两次 —— 一次作为 restool 自身目录下的文件，一次通过 `definedSysIds` 传入。

**补丁**：把 `hms/toolchains/` 从「整体软链」改为「**逐项软链，唯独排除 `id_defined.json`**」：

```bash
rm -f $CLT/sdk/default/hms/toolchains
mkdir -p $CLT/sdk/default/hms/toolchains
for e in $SDK26/toolchains/*; do
  b=$(basename "$e")
  [ "$b" = "id_defined.json" ] && continue
  ln -sfn "$e" "$CLT/sdk/default/hms/toolchains/$b"
done
```

### 3.7 插件源码的 API 26 适配

**症状**：`10505001 ArkTS Compiler Error: This expression is not callable.
Type 'ResourceManager' has no call signatures. At .../fvp-0.37.0/.../FvpPlugin.ets:34:72`

**原因**：API 26 中 `Context.resourceManager` 是**属性**（`Context.d.ts` 里写作
`resourceManager: resmgr.ResourceManager`），而 fvp 0.37.0 仍按函数调用。

**补丁**：去掉调用括号：

```diff
- binding.getApplicationContext().resourceManager()
+ binding.getApplicationContext().resourceManager
```

**症状**：`10505001 Cannot find module '@ohos/flutter_ohos'` in `screen_brightness_ohos-2.1.4`

**原因**：该插件的 `oh-package.json5` 里 `dependencies` 是空的，导致 flutter_tools
注入的 `overrides` 无从生效。

**补丁**：补上与 fvp 一致的依赖声明：

```json5
"dependencies": { "@ohos/flutter_ohos": "file:./har/flutter.har" }
```

> 这两个补丁改的是 **pub-cache 里的第三方包**（`$HOME/.pub-cache/hosted/pub.flutter-io.cn/...`）。
> 换机或清缓存后需重做，已在下方「复现清单」中列出。

---

## 4. 签名：Linux 下的自动签名

### 4.1 为什么需要专门处理

DevEco 的「自动签名」依赖 GUI 与 Windows 路径（`C:\Users\<user>\.ohos\config\...`），
Linux/CI 上不可用。而 hvigor **强制**要求 `build-profile.json5` 里的
`storePassword` / `keyPassword` 是**加密串**（长度 ≥32 的十六进制），不接受明文：

```
00303116 The length of the storePassword or keyPassword field in the signature
configuration is less than 32.
```

该加密由 DevEco 用「签名材料」目录（`material/{fd,ac,ce}`）派生密钥完成。
解密算法见 `hvigor-ohos-plugin/src/utils/decipher-util.js`，是**完全确定**的，
因此可以在 Linux 上自行生成。

### 4.2 口令加密格式（逆向所得）

```
密文容器 = [4 字节大端 = 密文长度 + 16][12 字节 IV][密文][16 字节 GCM tag]

密钥派生：
  xored   = fd1 ^ fd2 ^ fd3 ^ component      // component 为插件内硬编码 16 字节常量
  rootKey = PBKDF2(xored.toString(), salt, 10000, 16, 'sha256')
  workKey = AES-128-GCM-Decrypt(rootKey, material/ce 文件)
  明文口令 = AES-128-GCM-Decrypt(workKey, 密文容器)
```

`scripts/gen_sign_material.js` 实现了这套算法，产出 `material/` 与加密口令。
已实测可被 hvigor 的 `decryptPwd()` 正确解出。

### 4.3 证书链（最容易踩的坑）

**症状**：`11013004 Profile cert must a cert chain` 或
`verify certificate chain failed! Signature does not match.`

**原因**：用 `keytool -exportcert -alias "openharmony application release"` 导出的是
**自签名证书（链长 1）**，不是链。必须用 Profile 模板里那张由
**Application CA 签发**的叶子证书：

```python
# 叶子证书取自 UnsgnedDebugProfileTemplate.json
cert = json.load(open(template))['bundle-info']['development-certificate']
# 再追加 Application CA 与 Root CA，构成三段链
```

正确链结构：

```
叶子（OpenHarmony Application Release，签发者 Application CA）
  └─ OpenHarmony Application CA（签发者 Root CA）
       └─ OpenHarmony Application Root CA（自签）
```

**另一个坑**：`profile.json` 的 `development-certificate` 必须是**真实换行**，
写成字面 `\n` 会触发 `Illegal base64 character 20`。

`scripts/gen_ohos_signature.sh` 已完整封装上述流程，产出：

```
ohos/signature/
├── OpenHarmony.p12           SDK 自带密钥库（含调试私钥与 CA 链）
├── ohos_debug.cer            三段证书链
├── profile.json              按 bundleName 定制的调试 Profile
├── profile.p7b               Profile 签名结果
├── material/{fd,ac,ce}       hvigor 口令解密材料
└── encrypted-passwords.json  加密后的 storePassword / keyPassword
```

### 4.4 安全提示

上述方案使用的是 **SDK 公开的 OpenHarmony 调试密钥**（口令 `123456`），
仅供开发/测试与 CI 内部验证。**上架发布必须换用华为开发者账号申请的真实证书与 Profile。**

---

## 5. 已验证的构建结果

```
$ flutter build hap --debug -t lib/main_ohos.dart
start hap build...
✓ Built ohos/entry/build/default/outputs/default/entry-default-signed.hap.
```

| 项目 | 值 |
| --- | --- |
| 产物 | `entry-default-signed.hap` |
| 大小 | **71,697,821 字节（约 68 MB，release，2026-10-15）** |
| bundleName | **`com.heinplay.hain_tv_ohos`** |
| versionName / versionCode | `1.4.0` / `24` |
| deviceTypes | `["phone", "tablet"]` |
| compileSdkVersion | `26.0.0.38`（`compileSdkType: HarmonyOS`） |
| 签名校验 | `hap-sign-tool verify-app` → **Verify success** |

HAP 内主要原生库（实测 `unzip -l`）：

| 库 | 大小 |
| --- | --- |
| `libmpv.so` | **38,695,792**（mpv 硬解版） |
| `libflutter.so` | 16,380,352 |
| `libapp.so` | 7,832,496 |
| `libmpv_wrapper.so` | 443,848 |
| `libc++_shared.so` | 1,262,248 |
| `libaki_jsbind.so` | 189,976 |
| `libuv.so` | 17,096 |

> 📉 与早期 debug 包（151,873,957 字节）对比：体积下降约 55%，主因是
> **fvp 栈（`libmdk.so` / `libfvp.so` / `libffmpeg.so`）整体移除**、改用 mpv 单体内核，
> 以及 release 编译。旧记录中出现的 `libmdk.so` / `libfvp.so` 在当前产物中**已不存在**。

---

## 6. 已知遗留问题

| # | 问题 | 影响 | 状态 |
| --- | --- | --- | --- |
| 1 | 用 OpenHarmony SDK 冒充 HarmonyOS SDK | 需 6 处环境补丁；资源未做图像压缩 | 已适配，属环境约束 |
| 2 | 调试签名用 SDK 公开密钥 | 不能上架 | ✅ **已解决**：已切华为 AGC 正式发布签名（`ohos/signature/release/`，一键 `bash scripts/use_release_signature.sh`） |
| 3 | 仅 arm64-v8a | 无 x86_64 模拟器包 | 待评估 |
| 4 | 权限未与安卓版对齐 | 安卓版有 8 项权限 | ✅ **已补齐 3 项**：`ohos/entry/src/main/module.json5` 现有 `INTERNET` / `GET_NETWORK_INFO` / `KEEP_BACKGROUND_RUNNING`；媒体读取类改用免权限方案，`REQUEST_INSTALL_PACKAGES` 无对等权限（见下方详情） |
| 5 | 未在真机/模拟器实机验证 | 运行时行为未知 | 待验证 |
| 6 | `build-profile.json5` 曾含 Windows 签名路径 | 已改为工程内相对路径 | 已修复 |
| 7 | ~~第三方插件需打补丁（fvp / screen_brightness_ohos）~~ | — | ✅ **已消失**：fvp 于 2026-10-06 彻底移除，该补丁对象已不存在。仅 `screen_brightness_ohos` 的 `oh-package.json5` 依赖声明仍需在清 pub-cache 后重做 |

### 待补齐的权限（问题 4 详情）

安卓手机版声明的权限：

```
INTERNET / ACCESS_NETWORK_STATE / REQUEST_INSTALL_PACKAGES
READ_EXTERNAL_STORAGE / READ_MEDIA_IMAGES / READ_MEDIA_VIDEO / READ_MEDIA_AUDIO
WAKE_LOCK
```

鸿蒙对应权限（`module.json5` 的 `requestPermissions`）：

| 安卓 | 鸿蒙 | 说明 |
| --- | --- | --- |
| `INTERNET` | `ohos.permission.INTERNET` | ✅ 已有 |
| `ACCESS_NETWORK_STATE` | `ohos.permission.GET_NETWORK_INFO` | ⬜ 待补 |
| `WAKE_LOCK` | `ohos.permission.KEEP_BACKGROUND_RUNNING` | ⬜ 待补（`wakelock_plus` 需要） |
| 媒体读取类 | 用 `filePicker` / `photoAccessHelper` 免权限方案 | ⬜ 待评估 |

> `REQUEST_INSTALL_PACKAGES`（应用内更新）在鸿蒙上没有对等权限，
> 需改用 `bundleManager` + `installBundle` 的应用内安装流程，属**功能改造**而非加权限。

---

## 7. 复现清单（换机 / 清缓存后需重做）

```bash
# 1) 复制工具链到可写区（约 13 GB）
mkdir -p /workspace/code/HeinPlay/.deps-staging/toolchain
cp -a /opt/team/tool-deps/sdks/flutter_flutter-oh-3.41.10 \
      /workspace/code/HeinPlay/.deps-staging/toolchain/
cp -a /opt/team/tool-deps/ohos/command-line-tools \
      /workspace/code/HeinPlay/.deps-staging/toolchain/

# 2) 安装 hvigor 6.26.8（替换 CLT 自带的 5.18.5）
#    见 3.1 节；装到 $OHOS_CLT/hvigor/{hvigor,hvigor-ohos-plugin}

# 3) 重建 SDK 目录结构（3.2 / 3.3 节）
#    建 sdk/default/sdk-pkg.json + 逐组件软链 + 补 uni-package.json

# 4) 打 hvigor 插件补丁（3.4 / 3.5 / 3.6 节）
#    externalconfig.json / hos-sdk-info.js / hms/toolchains 排除 id_defined.json

# 5) 打第三方插件补丁（3.7 节，需先 flutter pub get 拉下依赖）
#    fvp: FvpPlugin.ets 去掉 resourceManager() 的括号
#    screen_brightness_ohos: oh-package.json5 补 @ohos/flutter_ohos 依赖

# 6) 生成签名材料
source scripts/env_ohos_linux.sh
bash scripts/gen_ohos_signature.sh

# 7) 构建
flutter build hap --debug -t lib/main_ohos.dart
```

---

## 8. 相关文件索引

| 文件 | 作用 |
| --- | --- |
| `scripts/env_ohos_linux.sh` | 载入可写工具链 + 全部环境变量与补丁 |
| `scripts/gen_ohos_signature.sh` | 一键生成 Linux 可用的签名材料 |
| `scripts/gen_sign_material.js` | 生成 hvigor 口令加密材料（算法实现） |
| `scripts/sync_ohos_icons.sh` | 从安卓手机版同步图标到鸿蒙工程 |
| `ohos/build-profile.json5` | 签名配置（已改为工程内相对路径） |
| `ohos/entry/src/main/module.json5` | 设备类型、权限、Ability 声明 |
| `ohos/signature/` | 签名材料（含调试私钥，勿提交到公开仓库） |