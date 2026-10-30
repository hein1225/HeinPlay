/// 渲染方式：控制视频画面在设备上的呈现路径。
///
/// 与 Android 的 SurfaceView / TextureView 概念对齐：
/// - [texture]（TextureView）：Flutter 外部纹理。鸿蒙当前两后端（avplayer
///   的 video_player_ohos、mpv 的路线 B）实际都走此路径，稳定出画。
/// - [surface]（SurfaceView）：原生合成 surface。鸿蒙上对应 mpv 路线 A 的
///   XComponent(SURFACE) 与 avplayer 的 XComponent 原生通道；两后端当前
///   经实测均不可稳定出画（mpv 路线 A 黑屏、avplayer 无对应通道），
///   属「预留能力」，当前版本选它时后端会回落到纹理并打日志标注。
///
/// 枚举值按 `name` 持久化（shared_preferences），新增值时勿改旧值名。
enum VideoRenderMode { texture, surface }