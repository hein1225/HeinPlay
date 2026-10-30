# HarmonyOS/OpenHarmony (API 12+) 音量 API 调研报告

> 目的：修复「右侧上下滑动手势调音量 → 系统媒体音量不变」的真实 bug。
> 结论全部基于一手出处：Gitee 上 `interface_sdk-js` 的 `.d.ts` 原始文件、Gitee 上 `docs` 的官方开发指南、以及本仓库锁定的 OHOS SDK（apiVersion 23 / 6.1.0.31）本地声明文件。
> 调研日期：2026-10-09

---

## 0. 一句话结论

**普通（非系统）HarmonyOS 应用无法通过任何 ArkTS API 直接写系统媒体音量。**
`setAppVolumePercentage()` 改的是「应用自身相对音量」，不是系统音量 —— 这正是 bug 根因。
唯一官方许可的路径是系统提供的 **`AVVolumePanel` 组件**（API 12+，非 systemapi），
由**用户**在界面里操作来改系统音量；应用不能主动调。

对 HeimPlay 这类需要「全屏手势调音量」的播放器：**做不到 1:1 复刻安卓体验**，
最接近的正确做法是 `AVVolumePanel` + 隐藏系统默认面板 + 自绘面板（详见 §7）。

---

## 1. `setAppVolumePercentage()` 到底改的是什么？

**答：改的是「应用音量（app-level volume）」，是本应用音频输出的一个相对系数，不是系统媒体音量。**

一手证据（Gitee `interface_sdk-js`，`api/@ohos.multimedia.audio.d.ts`，`AudioVolumeManager` 接口）：

```ts
/**
 * Sets the volume for your app with range from 0 to 100. Applications with the same uid share the same volume.
 * Only AudioRenderers with {@link AudioRendererInfo.volumeMode} set to {@link AudioVolumeMode.APP_INDIVIDUAL}
 * will be affected by this volume.
 * When you change your app's volume, you will receive 'appVolumeChange' callback event.
 * Your app volume can be also changed by other system settings, and you can monitor the changes through
 * 'appVolumeChange' callback.
 * @param { number } volume - Volume to set. The value range is from 0 to 100.
 * @returns { Promise<void> } Promise used to return the result.
 * @syscap SystemCapability.Multimedia.Audio.Volume
 * @since 19
 */
setAppVolumePercentage(volume: number): Promise<void>;
```

关键在 **`Only AudioRenderers with AudioRendererInfo.volumeMode set to AudioVolumeMode.APP_INDIVIDUAL will be affected by this volume`**：

```ts
enum AudioVolumeMode {
  SYSTEM_GLOBAL = 0,    // Audio volume affected by system volume level.（默认）
  APP_INDIVIDUAL = 1    // Audio volume affected by app's individual percentage.
}
```

### 这条直接解释了 bug 的「静默失效」现象

如果播放器（AVPlayer / AudioRenderer / 或本仓库的 mpv 内核）用**默认**的 `volumeMode = SYSTEM_GLOBAL`，
那么 `setAppVolumePercentage()` **对该音频流完全无效** —— 不报错、Promise 正常 resolve，
但听感音量一点不变。而应用自己画的手势提示条照常更新 → 用户看到的就是
「提示条在动，系统音量没变」。

> 补充：即便 `volumeMode = APP_INDIVIDUAL` 生效了，它改的仍然只是**本应用**的输出音量，
> **系统音量条不动、其他应用不受影响**。与「和安卓一样调系统媒体音量」的预期在语义上就是两回事。

### 官方对「应用音量」作用域的原文（Gitee `docs`，`zh-cn/application-dev/media/audio/volume-management.md`）

> **应用音量**是OpenHarmony提供给三方应用用来控制该应用下所有音频流音量的一种音量类型。三方应用设置应用音量之后，该应用中起的所有音频流默认使用该音量大小。另外具有系统应用权限的应用可以通过UID单独调整指定应用的音量。

> - 层级关系：系统音量是全局的，应用音量和音频流音量是局部的。
>   应用音量和音频流音量的调整范围受系统音量的限制。例如：系统媒体音量设置为50%，应用音量设置为100%，应用程序的最终输出音量只能达到50%（50% * 100%）。

**「应用音量 100% × 系统音量 50% = 实际输出 50%」** —— 应用音量是乘在系统音量上的**从属系数**，
永远无法突破系统音量上限。这从数学上就证明了它不能用来「调大系统音量」。

### ⚠️ 版本红线：这是 API 19+，不是 API 12+

`@since 19`。**API 12 上这两个接口根本不存在**，`setAppVolumePercentage` 与
`getAppVolumePercentage` 都是 API 19 才引入的。项目若声明 `compatibleSdkVersion` 低于 19，
编译期就会失败（本仓库 SDK 是 23，所以能编过）。

---

## 2. 调系统音量的正确 API 与精确签名

**`AudioVolumeGroupManager.setVolume(audio.AudioVolumeType.MEDIA, volume)` 确实就是那个 API —— 但它是 `@systemapi`，三方应用不可用。**

一手证据（Gitee `interface_sdk-js`，`api/@ohos.multimedia.audio.d.ts`）：

```ts
/**
 * Sets the volume for a stream. This method uses a promise to return the result.
 * @permission ohos.permission.ACCESS_NOTIFICATION_POLICY
 * @param { AudioVolumeType } volumeType - Audio stream type.
 * @param { number } volume - Volume to set. The value range can be obtained by calling getMinVolume and getMaxVolume.
 * @returns { Promise<void> } Promise used to return the result.
 * @syscap SystemCapability.Multimedia.Audio.Volume
 * @systemapi
 * @since 9
 */
setVolume(volumeType: AudioVolumeType, volume: number): Promise<void>;
```

### 精确回答各项

| 问题 | 答案 |
|---|---|
| 参数类型 | `volumeType: AudioVolumeType`（枚举，如 `.MEDIA`）、`volume: number` |
| 返回值 | `Promise<void>`（另有 callback 重载 `AsyncCallback<void>`） |
| 是否 Promise | 是，两种重载二选一 |
| 音量取值 | **档位整数（level），不是归一化 0..1**。范围必须由 `getMinVolume*` / `getMaxVolume*` 动态取得，典型 0..15，**绝不能假定为 0..100** |
| 权限 | `ohos.permission.ACCESS_NOTIFICATION_POLICY`（系统级，三方不可申请） |
| 可用性 | **`@systemapi`，仅系统应用** |

> **易错点**：`AudioVolumeType.MEDIA` 的音量是「档位」而非「百分比」。
> 正确写法是先读 min/max 再线性映射，见 §7.3。

### 相关配套 API（同属 `@systemapi`，均不可用）

- `setVolumeWithFlag(volumeType, volume, flags)` —— `@systemapi`，`@since 12`
- `on('systemVolumeChange')` / `off(...)` —— `@systemapi`，`@since 20`
- `setAppVolumePercentageForUid(uid, volume)` —— `@systemapi`（按 UID 改别人的应用音量）

---

## 3. 需要权限吗？是不是「仅系统应用」？

**是的，确切结论：`setVolume(AudioVolumeType.MEDIA, ...)` 是 `@systemapi`，普通第三方应用在 HarmonyOS NEXT / API 12+ 上无法调用。**

### 三重独立证据（互相印证）

**证据 A — d.ts 的 `@systemapi` 标记（编译期硬隔离，非文档口径）**

Gitee `interface_sdk-js` 的 `AudioVolumeGroupManager.setVolume` JSDoc 中明确带有 `@systemapi`。
构建 SDK 会据此生成 `systemapi` 变体；三方应用使用 Release SDK 编译时，
该符号**不在公开 `d.ts` 里**，直接报「属性不存在」。

**证据 B — 本仓库锁定 SDK 的实际表现（最贴近本项目的实证）**

本仓库 SDK：`.deps-staging/toolchain/ohos/ohos-sdk-6.1.0/default/openharmony/ets/`
（`oh-uni-package.json`: `apiVersion 23`, `version 6.1.0.31`）。

在该 SDK 的 `@ohos.multimedia.audio.d.ts` 中检索 `setVolume`，结果只有：

```
2476:  setVolume(volumeType: AudioVolumeType, volume: number, callback: AsyncCallback<void>): void;  // AudioManager, @deprecated since 9
2488:  setVolume(volumeType: AudioVolumeType, volume: number): Promise<void>;                          // AudioManager, @deprecated since 9
7004:  setVolume(volume: number, callback: AsyncCallback<void>): void;                                  // AudioRenderer（流级）
7020:  setVolume(volume: number): Promise<void>;                                                        // AudioRenderer（流级）
7051:  setVolumeWithRamp(...)
9235:  setVolume(volume: number): Promise<void>;                                                        // AVPlayer（流级）
```

**`AudioVolumeGroupManager` 上完全没有 `setVolume`**。这与本仓库 `EntryAbility.ets`
第 33–34 行记录的编译期实测一致：

> 🗒️ 本仓库 `EntryAbility.ets` 注释原文：
> 「鸿蒙当前 SDK（compatibleSdkVersion 6.1.0(23)）里 `AudioVolumeGroupManager`
> **只有 getVolume\* 读接口、没有 setVolume**（编译期已实测报错
> "Property 'setVolume' does not exist on type 'AudioVolumeGroupManager'"）；
> 旧版 `AudioVolumeManager.setVolume` 自 API 9 起已废弃且标注 @systemapi。
> 系统音量写入属系统应用能力，三方应用不可用。」

即：**项目作者当时已经查对了**，`setAppVolumePercentage` 是一个深思后的降级选择。

**证据 C — 官方开发指南明确写了「不能主动调节」**

Gitee `docs`，`zh-cn/application-dev/media/audio/volume-management.md`：

> 通过AudioVolumeManager**只能获取音量信息及监听音量变化，不能主动调节系统音量**。如果应用需要调节系统音量，可以[使用音量面板调节系统音量](#使用音量面板调节系统音量)。

并有一节标题直接写着：

> ### 调节系统音量（仅对系统应用开放）
> 目前调节系统音量主要是靠SystemAPI，具体服务于物理音量按键和设置。

（该节位于 `<!--Del-->` / `<!--DelEnd-->` 之间，即**只在系统应用开发者文档中渲染**，
三方应用文档里看不到 —— 这正是网上「说法互相矛盾」的根源：
看了系统侧文档的人以为能调，看了三方文档的人知道不能调。**答案是：三方不能。**）

### 关于「网上说法矛盾」的澄清

矛盾来源于两类文档：
1. **系统应用文档**（`<!--Del-->` 段）描述 `setVolume` 的用法 → 看起来三方也能用；
2. **三方应用文档**只说 AVVolumePanel。

`@systemapi` 标记是最终裁决者：**三方应用不可用**。
若强行调用，结果是编译期找不到符号；即使绕过签名，运行时也会抛
`202 - Not system App` / `201 - Permission denied`（d.ts 中该模块大量方法显式声明了这两个错误码）。

---

## 4. 三方应用不能直接调，官方推荐什么替代方案？

**官方唯一推荐：`AVVolumePanel` 系统音量面板组件。**
它**由系统渲染音量条**（默认样式即系统音量面板），用户拖动时系统会弹出音量提示界面。

官方指南原文：

> **应用无法直接调节系统音量**，可以通过系统音量面板，让用户通过界面操作来调节音量。当用户通过应用内音量面板调节音量时，系统会展示音量提示界面，显性地提示用户系统音量发生改变。

`@ohos.multimedia.avVolumePanel` 文档原文：

> 本模块提供创建音量面板AVVolumePanel的功能，提供展示和调节系统音量的统一面板。
> **应用无法直接调节系统音量**，可以通过系统音量面板，让用户通过界面操作来调节音量。

### 4.1 声明（Gitee `interface_sdk-js`，`api/@ohos.multimedia.avVolumePanel.d.ets`）

```ts
/**
 * @file Defines a panel to set the system audio output volume.
 * @kit AudioKit
 */

export declare class AVVolumePanelParameter {
  /**
   * Sets the position of volume panel.
   * @syscap SystemCapability.Multimedia.Audio.Volume
   * @atomicservice
   * @since 12
   */
  position?: Position;
}

/**
 * A panel to set the system audio output volume.
 * @syscap SystemCapability.Multimedia.Audio.Volume
 * @atomicservice
 * @since 12
 */
@Component
export declare struct AVVolumePanel {
  @Prop volumeLevel?: number;
  @Prop volumeParameter?: AVVolumePanelParameter;
}
```

**注意：整个文件没有任何 `@systemapi` 标记，且有 `@atomicservice`** → **三方应用与元服务均可使用。**
本仓库 SDK（apiVersion 23）中该文件存在，可直接用。

### 4.2 用法示例

```ts
import { AVVolumePanel } from '@kit.AudioKit';

@Entry
@Component
struct Index {
  @State volume: number = 0;

  build() {
    Row() {
      Column() {
        AVVolumePanel({
          volumeLevel: this.volume,          // 不传则用当前设备音量
          volumeParameter: {
            position: { x: 100, y: 200 }     // vp；传屏幕外坐标如 (-1,-1) 可隐藏系统默认面板
          }
        })
      }
    }.width('50%').height('50%')
  }
}
```

- `volumeLevel`：`@Prop`，设置面板音量值，**须在设备 min/max 之间**（越界按最大/最小处理）。
- `volumeParameter.position`：屏幕内坐标 → 面板显示在该处；**屏幕外坐标（如 `(-1,-1)`）→ 隐藏系统默认面板**。
  官方**强制要求**：隐藏系统默认面板时，**必须提供自定义音量面板**，否则用户没法调音量。

### 4.3 官方使用建议（原文，含两条硬约束）

> 1. 应用在实现自定义音量面板的过程中，建议使用音频框架的音量变化监听接口，通过接口回调的音量类型`volumeEvent.volumeType`，音量等级`volumeEvent.volume`以及是否显示音量面板`volumeEvent.updateUi`等信息，应用可以判断是否需要处理当前数据和显示自定义的音量面板。
> 2. **为确保用户能感知音量变化，不允许应用后台调节音量，系统会做出对应的控制措施。**
> 3. **系统提供音量面板的目的是，由用户在应用界面主动操作来调节系统音量，而非应用主动调节。**因此，若应用通过设置音量面板位置参数隐藏了系统默认音量面板，必须提供应用自定义的音量面板，以确保用户正常进行音量调节。

> ⚠️ **这条直接判了 HeimPlay 手势方案的「死刑」**：「由用户在应用界面主动操作来调节」=
> 必须用户**直接拖动系统面板**。用滑动手势在代码里代用户写音量，正是官方明令禁止的「应用主动调节」。

### 4.4 设备限制（原文）

> - 在**穿戴设备**上，可用于调节系统音量，但不显示界面，需开发者自行设计界面。
> - 本模块接口**暂不支持TV设备**使用。

> ⚠️ 对本仓库尤其重要：`hain_tv_ohos` 面向 TV/电视场景，而官方明确 **TV 设备不支持 AVVolumePanel**。
> 若目标设备是 TV，则连这条替代路径都不存在。

---

## 5. `getAppVolumePercentage()` 返回 0..100 还是 0..1？

**答：返回 `0..100`。d.ts 里写得非常明确，无需猜测。**

```ts
/**
 * Get the volume for your app with range from 0 to 100. Applications with the same uid share the same volume.
 * @returns { Promise<number> } The application's volume percentage. The value range is from 0 to 100.
 * @syscap SystemCapability.Multimedia.Audio.Volume
 * @since 19
 */
getAppVolumePercentage(): Promise<number>;
```

中英双语文档一致：

- d.ts：`The value range is from 0 to 100.`
- 官方指南：`// 查询应用音量。` / `audioVolumeManager.getAppVolumePercentage()`
- 华为 API 参考：`取值范围为[0, 100]，单位为百分号（%）`

### 为什么你会看到「有的除以 100，有的不除」

因为**这是两个不同层面的量，恰好都叫 volume**：

| 接口 | 单位/范围 | 典型处理 |
|---|---|---|
| `getAppVolumePercentage()` / `setAppVolumePercentage()` | **0..100 百分比** | UI/手势层常 `/100` 归一化 |
| `AVPlayer.setVolume()` / `AudioRenderer.setVolume()` | **0.0..1.0 归一化** | 直接传 |
| `AudioVolumeGroupManager.getVolume()` / `setVolume()` | **档位整数**（min..max，如 0..15） | 需按 min/max 换算 |
| `AVVolumePanel.volumeLevel` | **档位整数**（同上，设备 min/max 之间） | 用 `getVolumeByStream` 取值 |

所以「除不除 100」取决于你在哪一层：**`*AppVolumePercentage` 必须除 100；`AVPlayer.setVolume` 绝不能除。**

> 本项目现状确认：`EntryAbility.ets` 中 `result.success(pct / 100.0)` 和 `pct = clamped * 100.0`
> 的换算**方向是正确的**（0..100 ↔ 0..1）。**这条不是 bug 成因。**

---

## 6. 官方「应用音量 vs 系统音量」对比说明（原文引用）

来自 Gitee `docs`，`zh-cn/application-dev/media/audio/volume-management.md`（OpenHarmony 官方开发指南，华为侧同源文档为[播放音量管理](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/volume-management)）。

**总述：**

> 本模块提供播放音量管理能力，包括对**系统音量**、**应用音量**和**音频流音量**的管理。

**系统音量定义：**

> **系统音量**是由OpenHarmony系统全局管理的音量设置，适用于所有应用程序和设备。OpenHarmony系统将音频分为不同的流类型，每种流类型有独立的系统音量控制。
>
> 系统音量可以通过物理音量按键或系统设置界面调节。在设置界面中，用户可以单独调整上述每种系统音量的大小。
>
> - 媒体音量：用于音乐、视频、游戏等媒体播放。
> - 通话音量：用于语音通话。
> - 铃声音量：用于来电铃声。
> - 闹钟音量：用于闹钟提醒。

**应用音量定义：**

> **应用音量**是OpenHarmony提供给三方应用用来控制该应用下所有音频流音量的一种音量类型。三方应用设置应用音量之后，该应用中起的所有音频流默认使用该音量大小。另外具有系统应用权限的应用可以通过UID单独调整指定应用的音量。

**音频流音量定义：**

> **音频流音量**是由应用独立控制的音量设置，仅影响该应用中指定的音频流输出音量大小。例如：媒体播放器可以独立控制其播放音量，而不影响系统音量以及该应用中的其他类型流音量。

**三者关系（最关键的一段）：**

> 系统音量、应用音量和音频流音量的关系如下所示。
>
> - 层级关系：系统音量是全局的，应用音量和音频流音量是局部的。
>   应用音量和音频流音量的调整范围受系统音量的限制。例如：系统媒体音量设置为50%，应用音量设置为100%，应用程序的最终输出音量只能达到50%（50% * 100%）。
>   音频流音量是对应用音量的更精细化控制。设置了应用音量的三方应用，还可以继续通过音频流音量对指定的音频流进行更加精细化的控制。
> - 协同关系：应用最终的输出音量是由系统音量、应用音量和音频流音量共同决定的。例如：系统媒体音量设置为50%，应用音量设置为50%，应用程序中对媒体音频流设置音频流音量为100%，则该音频流最终输出的音量为25%（50% * 50% * 100%）。
>
> OpenHarmony通过系统音量，应用音量和音频流音量协同的方式实现应用对音量的精确控制。

**系统音量谁来管（决定性一句）：**

> 管理系统音量的接口由AudioVolumeManager提供，在使用之前，需要使用getVolumeManager获取AudioVolumeManager实例。
>
> 通过AudioVolumeManager**只能获取音量信息及监听音量变化，不能主动调节系统音量**。如果应用需要调节系统音量，可以[使用音量面板调节系统音量](#使用音量面板调节系统音量)。

---

## 7. 对「普通非系统鸿蒙应用」的最终结论与可行做法（2026）

### 7.1 结论：明确做不到「手势直接调系统媒体音量」

**做不到。** 请明确接受这一点，不要继续在 `setAppVolumePercentage` 上做参数调优 ——
那条路在语义上就不是系统音量，且默认 `volumeMode` 下连生效都不会生效。

| 方案 | 能否改系统媒体音量 | 三方可用 | 结论 |
|---|---|---|---|
| `setAppVolumePercentage(pct)` | ❌ 否（只改应用相对音量） | ✅ 可用（API 19+） | **不是**系统音量 |
| `AudioVolumeGroupManager.setVolume()` | ✅ 是 | ❌ **`@systemapi`** | 编译期即不可用 |
| `AudioManager.setVolume()`（旧） | ✅ 是 | ❌ `@systemapi` + API 9 起废弃 | 不可用 |
| `AVPlayer.setVolume()` / `mpv` 内部音量 | ❌ 否（仅本流） | ✅ 可用 | 只影响本应用播放 |
| **`AVVolumePanel`（用户拖动）** | ✅ **是** | ✅ **可用（API 12+）** | **官方唯一路径** |

> 若设备是 **TV**：`AVVolumePanel` 官方声明**不支持 TV**，则连唯一路径也没有 ——
> 此时只能退到「应用内音量（`setAppVolumePercentage` 或播放器流音量）」。

### 7.2 推荐落地方案（按优先级）

**方案 A（推荐，且官方合规）：自绘音量面板 + `AVVolumePanel` 隐藏系统默认面板**

核心思路：**把手势的"落点"从代码写音量，改成驱动一个用户可拖动的系统面板。**

```
手势滑动
  → 更新 ArkTS 侧 @State volumeLevel（档位值）
  → 传给 AVVolumePanel({ volumeLevel, volumeParameter: { position: {x:-1, y:-1} } })
  → 系统按 volumeLevel 改真实系统媒体音量 + 弹系统音量条
```

⚠️ 但**注意官方硬约束**：`volumeLevel` 由**应用**赋值 → 这正是「应用主动调节」，与官方
「由用户在应用界面主动操作……而非应用主动调节」相冲突，且「不允许应用后台调节音量」。
**稳妥做法**：把 `AVVolumePanel` **可见地**显示在手势结束位置，让**用户直接拖**这个面板。

**方案 B（体验最接近安卓、但需承认语义差异）：保留手势 → 应用内音量 + 明确 UI 语义**

- 若必须保留「右侧上下滑」这个交互，就让它调**应用内音量**，并把 UI 文案/图标改为
  「应用音量」而非系统音量，避免用户预期落空。
- 对播放器而言体验其实不差：用户要的是「声音变大/变小」，应用内音量同样满足，
  **只是不会联动系统音量条、也不影响其他应用**。
- 若走这条，**关键修复**：确保渲染器 `volumeMode` 为 `APP_INDIVIDUAL`，
  否则 `setAppVolumePercentage` 无效；或者干脆直接调**播放器自己的音量**
  （`AVPlayer.setVolume(0..1)` / mpv 的 `setVolume`），**这是最可靠、无需任何权限、全 API 版本可用**的做法。

**方案 C（不推荐）：申请系统应用签名 / 上架系统应用。** 对普通商用 App 不现实。

### 7.3 若坚持尝试 `setVolume`：正确写法（仅供确认「确实不可用」）

档位换算的正确姿势（**注意不是 0..100**）：

```ts
// ⚠️ 此代码在三方应用中【无法编译】或【运行时抛 202 Not system App】——
//    仅用于说明「档位整数」的语义，不要用于生产。
import { audio } from '@kit.AudioKit';

const avgm = audio.getAudioManager().getVolumeManager()
  .getVolumeGroupManagerSync(audio.DEFAULT_VOLUME_GROUP_ID);

const min = avgm.getMinVolumeSync(audio.AudioVolumeType.MEDIA);
const max = avgm.getMaxVolumeSync(audio.AudioVolumeType.MEDIA);
const level = Math.round(min + (max - min) * pct01);   // pct01 ∈ [0,1]
// avgm.setVolume(audio.AudioVolumeType.MEDIA, level);  // ← @systemapi，三方不可调用
```

### 7.4 只读替代（三方可用，可用来做 UI 展示）

三方应用**可以读**系统媒体音量并监听变化（这些**没有** `@systemapi`）：

```ts
import { audio } from '@kit.AudioKit';

const avm = audio.getAudioManager().getVolumeManager();

// 读当前系统媒体音量档位（API 20+）
const cur = avm.getVolumeByStream(audio.StreamUsage.STREAM_USAGE_MUSIC);
const lo  = avm.getMinVolumeByStream(audio.StreamUsage.STREAM_USAGE_MUSIC);
const hi  = avm.getMaxVolumeByStream(audio.StreamUsage.STREAM_USAGE_MUSIC);
const pct = (cur - lo) / (hi - lo);   // 归一化，仅用于显示

// 监听系统音量变化（用户按侧边键时同步 UI）
avm.on('streamVolumeChange', audio.StreamUsage.STREAM_USAGE_MUSIC,
  (e: audio.StreamVolumeEvent) => {
    console.info(`volume=${e.volume}, updateUi=${e.updateUi}`);
    // 用 e.volume / e.updateUi 更新自绘提示条
  });
```

> 这解释了为什么「提示条能显示真实音量」是可行的，但「写」不行：**读公开、写 systemapi**。

---

## 8. 对本仓库（HeinPlay / hain_tv_ohos）的具体修复建议

现状代码位置：
- Dart：`hain_tv_ohos/lib/services/volume_ohos.dart`（`VolumeOhos.set/get`，通道 `hain_tv/volume`）
- ArkTS：`hain_tv_ohos/ohos/entry/src/main/ets/entryability/EntryAbility.ets`（约 L128–L167）
- 调用点：`lib/screens/mobile/player_screen.dart:2116`、`lib/screens/tv/player_screen.dart`

### 已确认正确的部分（不要改）

1. **「`volume_controller` 插件无 ohos 实现」的判断正确** —— 该插件确实无 ohos 平台实现，
   这是「提示条动、音量不动」的**第一层**原因。
2. **0..100 ↔ 0..1 换算方向正确**（`pct/100.0`、`clamped*100.0`）—— 见 §5，不是 bug。
3. **「`AudioVolumeGroupManager` 无 `setVolume`、`AudioManager.setVolume` 是 @systemapi」的判断完全正确**
   —— 与 Gitee d.ts 及本地 SDK 实测一致（§3）。

### 需要修正的部分（真正的 bug）

**问题：`setAppVolumePercentage` 在默认 `volumeMode = SYSTEM_GLOBAL` 下是静默空操作。**
即：即使把 MethodChannel 修好，只要 mpv/AVPlayer 渲染器没设 `APP_INDIVIDUAL`，
音量依然不变 —— 用户看到的现象**不会改善**。

**修复路线（按推荐度）：**

**① 首选 —— 直接改播放器自身音量（最可靠）**
HeimPlay 用 mpv 内核（`mpv_arkts`），Dart 侧已有 `MpvBackend.setVolume`（`lib/player/mpv_backend.dart:514`）
和 `AVPlayer` 的 `setVolume`（0.0..1.0）。**手势直接驱动播放器音量**：
无需权限、无 API 版本门槛、所有设备（含 TV）可用、立即生效。
代价：**不改系统音量条、不影响其他应用** —— 但这是三方应用**唯一能保证生效**的路径。

**② 次选 —— 保持 `setAppVolumePercentage`，但补齐 `volumeMode`**
需把渲染器 `AudioRendererInfo.volumeMode` 设为 `AudioVolumeMode.APP_INDIVIDUAL`（API 19+）。
若 mpv 内核不走 AudioRenderer，此路不通 → 回到 ①。

**③ 若产品必须「系统音量」语义 —— `AVVolumePanel`**
在手势结束处弹出/显示 `AVVolumePanel` 让用户拖。注意：**TV 设备官方不支持**，
而本仓库含 `player_screen.dart` (TV) 路径 → 需按设备分支。

**④ UI 诚实化（无论选哪条）**
把提示条语义从「系统音量」改为「应用音量/播放音量」，
避免用户以为改了系统音量（当前反馈正是这种预期落差）。若保留展示系统音量，
可用 §7.4 的只读接口 `on('streamVolumeChange')` 同步真实系统音量，但**不要把两者混为一个滑块**。

---

## 9. 全部出处链接

| 内容 | 链接 |
|---|---|
| 官方开发指南《播放音量管理》（定义/关系/不能主动调节） | https://gitee.com/openharmony/docs/blob/master/zh-cn/application-dev/media/audio/volume-management.md |
| 同上（华为侧镜像） | https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/volume-management |
| `@ohos.multimedia.audio.d.ts` 原始声明（含 `@systemapi`） | https://gitee.com/openharmony/interface_sdk-js/blob/master/api/@ohos.multimedia.audio.d.ts |
| `AudioVolumeGroupManager`（`setVolume` 的 @systemapi） | https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-audio-audiovolumegroupmanager |
| `AudioVolumeManager`（`setAppVolumePercentage` / `getAppVolumePercentage`） | https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-audio-audiovolumemanager |
| `@ohos.multimedia.avVolumePanel`（音量面板） | https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ohos-multimedia-avvolumepanel |
| `@ohos.multimedia.avVolumePanel.d.ets` 原始声明 | https://gitee.com/openharmony/interface_sdk-js/blob/master/api/@ohos.multimedia.avVolumePanel.d.ets |
| `AudioVolumeMode` 枚举 | https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-audio-e |

### 本仓库内的本地证据文件

- `.deps-staging/toolchain/ohos/ohos-sdk-6.1.0/default/openharmony/ets/api/@ohos.multimedia.audio.d.ts`（apiVersion 23 / 6.1.0.31）
- `.deps-staging/toolchain/ohos/ohos-sdk-6.1.0/default/openharmony/ets/api/@ohos.multimedia.avVolumePanel.d.ets`
- `hain_tv_ohos/ohos/entry/src/main/ets/entryability/EntryAbility.ets`
- `hain_tv_ohos/lib/services/volume_ohos.dart`
