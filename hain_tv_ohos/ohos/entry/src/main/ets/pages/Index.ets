import common from '@ohos.app.ability.common';
import display from '@ohos.display';
import { FlutterPage } from '@ohos/flutter_ohos'

let storage = LocalStorage.getShared()
const EVENT_BACK_PRESS = 'EVENT_BACK_PRESS'

/// eventHub 事件名：Dart 侧通知「Flutter 封面已解码完成，可移除原生覆盖层」。
/// 与安卓 MainActivity 的 SPLASH_CHANNEL(coverReady) 语义一一对应。
const EVENT_SPLASH_COVER_READY = 'heinplay_splash_cover_ready'

/// 原生启动封面覆盖层 —— 对齐安卓 MainActivity 的 splashCoverView 机制。
///
/// 【为什么需要它】
/// 鸿蒙「增强启动页」（module.json5 的 startWindow → profile/start_window.json）
/// 已能让**启动窗口**整窗铺满封面；但一旦 windowStage.loadContent 执行、Flutter
/// 页开始渲染，启动窗口就被替换掉，而此刻 Flutter 侧的 SplashScreen 封面常常
/// 还没解码完成 —— 这段空窗期会露出底色，观感上是「封面闪一下」。
///
/// 安卓的解法是在 Activity 的 content 上叠一层全屏 ImageView（CENTER_CROP），
/// 等 Flutter 首帧封面解码完成后通过 channel 通知移除。鸿蒙这里用等价的
/// ArkUI 做法：在 Stack 中把 Image 盖在 FlutterPage 之上。
///
/// 【协作时序】
///   启动窗口（增强启动页，铺满 launch_cover）
///     → Index 页面构建，本覆盖层立刻显示同一张 launch_cover（无缝衔接）
///       → Flutter 首帧渲染，SplashScreen 封面解码完成
///         → Dart 通过 channel 发 coverReady → EntryAbility 转 eventHub
///           → 本页面移除覆盖层，露出 Flutter 自绘封面（同一张图，无缝）
///
/// 【兜底】4 秒后强制移除，避免 Flutter 启动异常时封面永久停留。
/// 该超时与安卓 MainActivity.kt 的 4000ms 兜底保持一致。
const SPLASH_COVER_TIMEOUT_MS = 4000;

@Entry(storage)
@Component
struct Index {
  private context = getContext(this) as common.UIAbilityContext
  @LocalStorageLink('viewId') viewId: string = "";

  /// 启动封面是否仍显示。Flutter 通知就绪（或超时兜底）后置 false。
  @State private showLaunchCover: boolean = true;

  /// 🔴 2026-10-06 修复：启动封面按**当前实际显示宽高**在代码里选图，
  /// 不再依赖资源限定词目录（vertical/horizontal）。
  ///
  /// 【为什么不用限定词目录】系统启动窗口在冷启动阶段方向尚未就绪，
  /// vertical/horizontal 限定词匹配不上、永远落到 base —— 这正是「封面固定、
  /// 不随屏幕方向变」的根因（实测两轮：base 换竖图后横屏设备即显示竖封面）。
  ///
  /// 【为什么不用 display.getDefaultDisplaySync()】它返回的是设备**自然方向**
  /// 尺寸；本机（平板/折叠屏）自然方向为横屏，故平板竖屏时仍被判成横屏。
  /// 改用组件的 onAreaChange 实际渲染区域，与当前屏幕方向严格一致。
  ///
  /// 【为什么不用 window.getLastWindow()】Index 构建早于窗口就绪，实测抛
  /// BusinessError 1300002（This window state is abnormal），校正从未生效。
  @State private coverRes: Resource = $r('app.media.launch_cover_portrait');

  /// 当前是否横屏（用于 onAreaChange 去重，避免高频 setState）。
  private coverIsLandscape: boolean = false;

  /// 超时兜底定时器句柄，用于在页面销毁时清理。
  private coverTimeoutId: number = -1;

  /// display 变化回调（旋转时重新选图），需持有引用以便 off 注销。
  /// 签名须为 Callback<number>（@ohos.display 的 on('change') 回调参数是
  /// 发生变化的 display id，不是 Display 对象）。
  private onDisplayChange: (id: number) => void = (_: number) => {
    // display 变化后由 onAreaChange 依据新渲染区域重选封面；
    // 此处仅在拿不到 onAreaChange 时用 display 兜底。
    this.coverRes = this.pickCoverByDisplay();
  };

  /// 按组件实际渲染区域选封面：宽 ≥ 高 → 横图，否则竖图。
  /// 由根 Stack 的 onAreaChange 驱动，首次布局与旋转都会触发，方向最准。
  ///
  /// 用 isLandscape 布尔量做去重（$r() 每次返回新对象，不能用 !== 比较），
  /// 避免 onAreaChange 高频触发时反复 setState 重建。
  private applyCoverByArea(w: number, h: number): void {
    // 用 !(x > 0) 而非 x <= 0：可同时挡住 0、负数与 NaN
    // （Length 理论上可能是非数字字符串，Number() 后为 NaN）。
    if (!(w > 0) || !(h > 0)) return;
    const landscape = w >= h;
    if (this.coverIsLandscape === landscape) return;
    this.coverIsLandscape = landscape;
    if (this.showLaunchCover) {
      this.coverRes = landscape
        ? $r('app.media.launch_cover_landscape')
        : $r('app.media.launch_cover_portrait');
    }
  }

  /// display 兜底选图（仅在 onAreaChange 尚未触发时使用）。
  private pickCoverByDisplay(): Resource {
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      const landscape = d.width >= d.height;
      this.coverIsLandscape = landscape;
      return landscape
        ? $r('app.media.launch_cover_landscape')
        : $r('app.media.launch_cover_portrait');
    } catch (e) {
      return $r('app.media.launch_cover_portrait');
    }
  }

  aboutToAppear(): void {
    // 先用 display 给一个初值，随后 onAreaChange 会按真实渲染区域校正。
    this.coverRes = this.pickCoverByDisplay();
    // 启动阶段若发生旋转，同步换图（onAreaChange 亦会触发，双保险）。
    try {
      display.on('change', this.onDisplayChange);
    } catch (e) {
      console.warn('[HeinPlay] display.on(change) 注册失败: ' + JSON.stringify(e));
    }
    // 兜底：最多 SPLASH_COVER_TIMEOUT_MS 后强制移除覆盖层。
    this.coverTimeoutId = setTimeout(() => {
      this.dismissLaunchCover('超时兜底');
    }, SPLASH_COVER_TIMEOUT_MS);

    // 监听 Dart 侧「封面已就绪」通知。
    //
    // ⚠️ 用 eventHub 中转而非在本组件里直接建 MethodChannel：MethodChannel 需要
    // 注册到 FlutterEngine 上，而引擎归 EntryAbility 持有。通过 eventHub 让
    // 「持有引擎的 EntryAbility」与「持有 UI 状态的 Index 页面」解耦，
    // 避免在 ArkUI 组件生命周期里去触碰引擎对象。
    this.context.eventHub.on(EVENT_SPLASH_COVER_READY, () => {
      this.dismissLaunchCover('Flutter 封面已就绪');
    });
  }

  aboutToDisappear(): void {
    if (this.coverTimeoutId !== -1) {
      clearTimeout(this.coverTimeoutId);
      this.coverTimeoutId = -1;
    }
    try {
      display.off('change', this.onDisplayChange);
    } catch (e) {
      console.warn('[HeinPlay] display.off(change) 注销失败: ' + JSON.stringify(e));
    }
    this.context.eventHub.off(EVENT_SPLASH_COVER_READY);
  }

  private dismissLaunchCover(reason: string): void {
    if (!this.showLaunchCover) {
      return;
    }
    this.showLaunchCover = false;
    if (this.coverTimeoutId !== -1) {
      clearTimeout(this.coverTimeoutId);
      this.coverTimeoutId = -1;
    }
    console.info('[HeinPlay] 启动封面已移除（' + reason + '）');
  }

  build() {
    // Stack 让封面覆盖层叠在 FlutterPage 之上（等价于安卓的 content.addView）。
    Stack() {
      Column() {
        FlutterPage({ viewId: this.viewId })
      }
      .width('100%')
      .height('100%')

      if (this.showLaunchCover) {
        // 🔴 2026-10-06：封面资源由 pickCoverByDisplay() 按 display 实际宽高选定
        // （coverRes），不依赖 vertical/horizontal 限定词目录 —— 避免自然方向为
        // 横屏的设备在竖屏启动时被系统按自然方向匹配到横图。
        // ImageFit.Cover = 保持宽高比、两边都 ≥ 显示边界（裁剪铺满），
        // 与安卓的 ImageView.ScaleType.CENTER_CROP 语义一致。
        Image(this.coverRes)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .syncLoad(true) // 同步加载：避免覆盖层自身再出现一次解码空窗
          .interpolation(ImageInterpolation.High)
          .hitTestBehavior(HitTestMode.None) // 不拦截触摸事件
      }
    }
    .width('100%')
    .height('100%')
    // 🔴 2026-10-06：按根容器**实际渲染区域**判定方向并选封面。
    // 首次布局与旋转（区域尺寸变化）都会触发，不受设备自然方向影响，
    // 也不依赖 window API 的调用时机（后者在启动早期会抛 1300002）。
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      this.applyCoverByArea(Number(newValue.width), Number(newValue.height));
    })
  }

  onBackPress(): boolean {
    this.context.eventHub.emit(EVENT_BACK_PRESS)
    return true
  }
}
