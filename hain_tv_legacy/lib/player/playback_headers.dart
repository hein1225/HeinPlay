import 'dart:io';

/// 过滤播放请求头中的内部传输键（`x-heinplay-` 前缀）。
///
/// 这类键是 App 内部约定的传输信道，**不应泄漏给上游 CDN**：
/// - `x-heinplay-proxy-url`：仅 ExoPlayer 后端（Android 的 video_player_android）
///   会由原生插件剥离并解析为 OkHttp 代理，因此该平台需保留；
/// - 其余后端（tvLegacy 的 mpv / 桌面端）不解析该键，一律丢弃。
///
/// 【本轮变更】本函数原先定义在 fvp 后端实现文件（已随 fvp 移除而删除）中，
/// 被 [MpvBackend] 跨文件复用。故把这一唯一仍被使用的工具函数迁到独立文件，
/// 避免 mpv 后端被迫依赖死代码。
///
/// [force] 为 true 时无视平台，强制剥离（mpv 后端恒用 true）。
Map<String, String>? stripInternalRequestHeaders(
  Map<String, String>? headers, {
  bool force = false,
}) {
  if (headers == null) return null;
  if (!force && Platform.isAndroid) return headers;
  final filtered = <String, String>{};
  for (final entry in headers.entries) {
    if (!entry.key.toLowerCase().startsWith('x-heinplay-')) {
      filtered[entry.key] = entry.value;
    }
  }
  return filtered;
}
