/**
 * Copyright (C) 2025 Bao Han <erbws@qq.com>
 */

import { Player } from './Player';

@ComponentV2
export struct PlayerSurface {
  @Param @Require player: Player;
  @Param ignoreSafeArea: boolean = true;
  @Param radius: Length | BorderRadiuses | LocalizedBorderRadiuses = 0;

  // 🔴 HeinPlay 诊断（2026-09-30）：确认 XComponent(SURFACE) 是否真的被构建。
  //    只有它进入渲染树，框架才会回调 Player.onSurfaceCreated → mpv 拿到 wid 出画。
  aboutToAppear(): void {
    console.warn('[mpv-surface] PlayerSurface.aboutToAppear —— 即将构建 XComponent(SURFACE)');
  }

  build() {
    XComponent({
      type: XComponentType.SURFACE,
      controller: this.player,
    })
      .width(LayoutPolicy.matchParent)
      .height(LayoutPolicy.matchParent)
      .borderRadius(this.radius)
      .ignoreLayoutSafeArea(this.ignoreSafeArea ? undefined : [], this.ignoreSafeArea ? undefined : [])
  }
}
