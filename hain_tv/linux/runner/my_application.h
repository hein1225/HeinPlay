#ifndef FLUTTER_MY_APPLICATION_H_
#define FLUTTER_MY_APPLICATION_H_

#include <gtk/gtk.h>

G_DECLARE_FINAL_TYPE(MyApplication,
                     my_application,
                     MY,
                     APPLICATION,
                     GtkApplication)

/**
 * my_application_new:
 *
 * Creates a new Flutter-based application.
 *
 * Returns: a new #MyApplication.
 */
MyApplication* my_application_new();

/**
 * hein_boot_log:
 * @fmt: printf 风格格式串
 *
 * 启动期取证日志（2026-10-27 新增）。
 *
 * 背景：掌机（Bazzite）游戏模式（gamescope 会话）下应用**直接闪退**，
 *   且**没有任何 Dart 日志、没有 native 日志、coredumpctl 也无记录**
 *   ⇒ 崩溃发生在日志系统建立之前，取证完全落空。
 *
 * 本函数把关键阶段的打点写入 `~/文档/app_logs/boot.log`（若 HOME 不可用
 * 则退化到 `/tmp/hein_boot.log`），并在 `main()` 里把 stderr/stdout 重定向
 * 到同一文件 ⇒ GTK/GLib/引擎的警告与崩溃栈都能落盘。
 *
 * 仅在 Linux runner 内使用，不影响 Windows/Android。
 */
void hein_boot_log(const char* fmt, ...);

#endif  // FLUTTER_MY_APPLICATION_H_
