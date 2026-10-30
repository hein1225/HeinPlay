#include <dlfcn.h>
#include <execinfo.h>
#include <fcntl.h>
#include <glib.h>
#include <glib-unix.h>
#include <gtk/gtk.h>
#include <signal.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "my_application.h"

// ===================== 启动期取证（2026-10-27 新增）=====================
//
// 掌机（Bazzite）游戏模式（gamescope 会话）下应用**直接闪退**，且：
//   · `~/文档/app_logs/` 里**没有** hain_tv_*.log（连 Dart 侧都没起来）
//   · `hein_native.log` 也**没有**（native 壳还没 dlopen）
//   · `coredumpctl` **无** hain_tv 记录
// ⇒ 崩溃发生在**日志系统建立之前**，之前完全没有取证手段。
//
// 本段做三件事（全部只写文件、只读环境，不改任何系统设置）：
//   1. 打开 `~/文档/app_logs/boot.log`（退化路径 /tmp/hein_boot.log）；
//   2. 把 stdout/stderr **dup2** 到该文件 ⇒ GTK/GLib/Flutter 引擎的
//      任何警告都会落盘（Steam 启动 AppImage 时 stderr 会被吞掉，
//      这是之前拿不到任何启动期输出的直接原因）；
//   3. 装 SIGSEGV/SIGABRT/SIGILL/SIGFPE 处理器，崩溃时把
//      **backtrace** 写进同一个文件。
//
// ⚠️ 崩溃处理器只做「写文件 + _exit」，不执行任何清理，避免二次崩溃。

static int g_boot_log_fd = -1;

static void hein_boot_log_open(int argc, char** argv) {
  const char* home = g_get_home_dir();
  gchar* path = nullptr;
  if (home != nullptr && *home != '\0') {
    gchar* dir = g_build_filename(home, "文档", "app_logs", NULL);
    if (dir != nullptr) {
      g_mkdir_with_parents(dir, 0755);
      path = g_build_filename(dir, "boot.log", NULL);
      g_free(dir);
    }
  }
  if (path != nullptr) {
    g_boot_log_fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    g_free(path);
  }
  if (g_boot_log_fd < 0) {
    g_boot_log_fd = open("/tmp/hein_boot.log",
                         O_WRONLY | O_CREAT | O_APPEND, 0644);
  }
  if (g_boot_log_fd < 0) return;

  // 记录启动瞬间的关键环境（判断走的是哪个 GTK 后端 / 是否在 gamescope 会话）
  const char* keys[] = {"HOME",          "WAYLAND_DISPLAY",
                        "DISPLAY",       "GDK_BACKEND",
                        "XDG_RUNTIME_DIR", "GAMESCOPE_WAYLAND_DISPLAY",
                        "XDG_CURRENT_DESKTOP", "XDG_SESSION_TYPE",
                        "SteamGamepadUI", "STEAM_COMPAT_APP_ID", nullptr};
  char line[1024];
  int n = snprintf(line, sizeof(line),
                   "\n=== boot pid=%d ts=%ld argv0=%s ===\n", (int)getpid(),
                   (long)time(NULL), argc > 0 ? argv[0] : "?");
  ssize_t w = write(g_boot_log_fd, line, (size_t)n);
  (void)w;
  for (int i = 0; keys[i] != nullptr; i++) {
    const char* v = g_getenv(keys[i]);
    n = snprintf(line, sizeof(line), "  env %s=%s\n", keys[i],
                 v != nullptr ? v : "(null)");
    w = write(g_boot_log_fd, line, (size_t)n);
    (void)w;
  }

  // stdout/stderr 全部并入日志（Steam 会吞掉 AppImage 的 stderr）
  dup2(g_boot_log_fd, STDOUT_FILENO);
  dup2(g_boot_log_fd, STDERR_FILENO);
}

void hein_boot_log(const char* fmt, ...) {
  if (g_boot_log_fd < 0) return;
  va_list ap;
  va_start(ap, fmt);
  char* text = g_strdup_vprintf(fmt, ap);
  va_end(ap);
  if (text == nullptr) return;
  char line[2048];
  int n = snprintf(line, sizeof(line), "[%ld] %s\n", (long)time(NULL), text);
  ssize_t w = write(g_boot_log_fd, line, (size_t)n);
  (void)w;
  g_free(text);
}

static void hein_crash_handler(int sig) {
  const char* head = "\n=== CRASH: signal caught ===\n";
  ssize_t w = write(g_boot_log_fd >= 0 ? g_boot_log_fd : STDERR_FILENO, head,
                    strlen(head));
  (void)w;
  char sigbuf[64];
  int n = snprintf(sigbuf, sizeof(sigbuf), "signal=%d\n", sig);
  w = write(g_boot_log_fd >= 0 ? g_boot_log_fd : STDERR_FILENO, sigbuf,
            (size_t)n);
  (void)w;
  void* frames[96];
  int cnt = backtrace(frames, 96);
  backtrace_symbols_fd(frames, cnt,
                      g_boot_log_fd >= 0 ? g_boot_log_fd : STDERR_FILENO);
  _exit(128 + sig);
}

static void hein_install_crash_handlers(void) {
  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_handler = hein_crash_handler;
  sigemptyset(&sa.sa_mask);
  sa.sa_flags = SA_NODEFER;
  sigaction(SIGSEGV, &sa, nullptr);
  sigaction(SIGABRT, &sa, nullptr);
  sigaction(SIGILL, &sa, nullptr);
  sigaction(SIGFPE, &sa, nullptr);
}

// ===================== 退出路径说明（2026-10-21）=====================
//
// 历史问题：用户点击关闭后进程挂住不退（69/78 真机均复现）。
//   2026-10-20 曾用 `SIGTERM/SIGINT → _exit(0)` 强行终止来「绕过」，
//   但那只是掩盖症状：不跑任何清理，纹理不注销、mpv 不销毁。
//
// 本轮实测结论（78 真机，逐个方案验证）：
//   · `_exit(0)`（原补丁）：能退出，但清理完全不执行 —— 等于没修。
//   · 交回系统默认处理：信号默认动作直接终止进程，同样不执行清理。
//   · `g_application_quit()` 走 GTK 正常收尾：**段错误**。Flutter Linux
//     引擎（libflutter_linux_gtk）在 GApplication::shutdown 阶段仍持有
//     GTK/GL 资源，此时销毁 EGL 上下文与 mpv 实例会与引擎拆除交叉。
//   · `signal() + g_idle_add`：不执行 —— signal() 的处理函数跑在信号上下文，
//     GTK 主循环尚未处理 idle 就被默认终止抢先。
//   · `g_unix_signal_add` + 弱符号：信号能接住，但**弱符号恒为空** ——
//     壳 .so 是运行时 dlopen 的，链接阶段看不到 hein_mpv_shutdown，
//     弱符号解析为 nullptr（实测日志「壳未加载（弱符号为空）」）。
//
// 最终方案：`g_unix_signal_add` 接信号 + **dlsym 运行时取符号**。
//   壳由 my_application.cc 以 RTLD_GLOBAL 方式 dlopen，
//   故 dlsym(RTLD_DEFAULT, "hein_mpv_shutdown") 可拿到。
//   回调在主线程执行：
//     ① hein_mpv_shutdown()：按正确顺序释放 mpv 实例 / render context /
//        EGL 上下文 / 事件线程；
//     ② _exit(0) 立即退出，避开 Flutter 引擎自身拆除阶段，避免交叉崩溃。

static gboolean hein_on_signal(gpointer data) {
  (void)data;
  g_print("HeinPlayRunner: 收到退出信号，开始清理 mpv 壳\n");
  fflush(stdout);

  // 🔴 运行时取符号：壳 .so 由 runner 在启动后 dlopen(RTLD_GLOBAL)，
  //    链接期的弱符号无法解析到它，必须用 dlsym。
  typedef void (*ShutdownFn)(void);
  ShutdownFn shutdown_fn =
      (ShutdownFn)dlsym(RTLD_DEFAULT, "hein_mpv_shutdown");
  if (shutdown_fn != nullptr) {
    shutdown_fn();
    g_print("HeinPlayRunner: mpv 壳清理完成\n");
  } else {
    g_print("HeinPlayRunner: 未找到 hein_mpv_shutdown 符号（壳未加载）: %s\n",
            dlerror());
  }
  fflush(stdout);

  // 清理完成，立即终止（不进入 Flutter 引擎拆除流程，避免交叉崩溃）。
  _exit(0);
  return G_SOURCE_REMOVE;
}

int main(int argc, char** argv) {
  // 🔴 最早时机：在 GTK/Flutter 任何初始化之前建立取证通道。
  //    崩溃若发生在这之后，boot.log 里必有记录；若连 boot.log 都没有，
  //    则说明进程根本没执行到 main()（加载器/动态库阶段就挂了）。
  hein_boot_log_open(argc, argv);
  hein_install_crash_handlers();
  hein_boot_log("stage: main() 进入，取证已建立");

  g_autoptr(MyApplication) app = my_application_new();
  hein_boot_log("stage: my_application_new() 返回");

  // 🔴 必须用 g_unix_signal_add（而不是 signal()）：
  //    它把信号转成 GLib 主循环事件，保证回调在主线程、且不会被
  //    信号的默认终止动作抢先。
  g_unix_signal_add(SIGTERM, hein_on_signal, nullptr);
  g_unix_signal_add(SIGINT, hein_on_signal, nullptr);

  hein_boot_log("stage: g_application_run() 即将进入");
  int rc = g_application_run(G_APPLICATION(app), argc, argv);
  hein_boot_log("stage: g_application_run() 返回 rc=%d", rc);
  return rc;
}
