#include "flutter_window.h"

#include <cstdarg>
#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"

#include <flutter/plugin_registrar.h>

// 🔴 桌面 mpv 壳（Windows）：官方 libmpv 内核 + 自写 C++ 壳。
//    Flutter 的 generated_plugin_registrant.cc 只认 pubspec 里声明的 Dart
//    插件，我们这个纯 C++ 壳不在其中，故在此手动注册。
//    壳 DLL（heinplay_mpv_desktop.dll）由 windows/CMakeLists.txt 装到
//    可执行文件同级目录，此处按名加载。
extern "C" void HeinPlayMpvDesktopPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

// 🔴 2026-10-22：runner 侧落盘日志。
//   原实现只用 OutputDebugStringA —— 那是给调试器看的，双击 exe 运行时
//   什么也看不到，于是「插件没注册」这类问题完全无迹可寻
//   （曾表现为 MissingPluginException: No implementation found for method
//   init on channel hain_tv/mpv_desktop，根因是壳 DLL 没装/没导出，
//   而日志里一个字都没有）。
//   现在同步写一份到 %LOCALAPPDATA%\HeinPlay\logs\hein_runner.log。
static void RunnerLog(const char* fmt, ...) {
  static HANDLE file = INVALID_HANDLE_VALUE;
  if (file == INVALID_HANDLE_VALUE) {
    wchar_t dir[MAX_PATH];
    if (GetEnvironmentVariableW(L"LOCALAPPDATA", dir, MAX_PATH) == 0) return;
    std::wstring path = std::wstring(dir) + L"\\HeinPlay\\logs";
    CreateDirectoryW(path.c_str(), nullptr);
    path += L"\\hein_runner.log";
    file = CreateFileW(path.c_str(), FILE_APPEND_DATA,
                       FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                       OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return;
  }
  char buf[1024];
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);
  if (n <= 0) return;
  SYSTEMTIME st;
  GetLocalTime(&st);
  char line[1200];
  int m = snprintf(line, sizeof(line),
                   "[%04d-%02d-%02d %02d:%02d:%02d.%03d] %s\r\n",
                   st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute,
                   st.wSecond, st.wMilliseconds, buf);
  if (m > 0) {
    DWORD written = 0;
    WriteFile(file, line, (DWORD)m, &written, nullptr);
  }
  OutputDebugStringA(line);
}

static void RegisterHeinMpvPlugin(flutter::PluginRegistry* registry) {
  if (registry == nullptr) {
    RunnerLog("HeinMpv: PluginRegistry 为空");
    return;
  }
  static HMODULE handle = nullptr;
  if (handle == nullptr) {
    // 优先用「exe 所在目录」的绝对路径：LoadLibraryA 只传裸文件名时，
    // 搜索顺序受 SafeDllSearchMode 影响，可能命中别处的同名 DLL 或找不到。
    wchar_t exePath[MAX_PATH] = {0};
    GetModuleFileNameW(nullptr, exePath, MAX_PATH);
    std::wstring dir(exePath);
    size_t slash = dir.find_last_of(L"\\");
    if (slash != std::wstring::npos) dir = dir.substr(0, slash + 1);
    std::wstring full = dir + L"heinplay_mpv_desktop.dll";

    handle = LoadLibraryW(full.c_str());
    if (handle == nullptr) {
      DWORD err = GetLastError();
      RunnerLog("HeinMpv: LoadLibraryW 失败 path=%ls err=%lu (=%d)",
                full.c_str(), (unsigned long)err, (int)err);
      // 回退：裸文件名（万一被装到了 PATH 里的其它位置）
      handle = LoadLibraryA("heinplay_mpv_desktop.dll");
      if (handle == nullptr) {
        RunnerLog("HeinMpv: 裸名 LoadLibraryA 也失败 err=%lu", (unsigned long)GetLastError());
        return;
      }
      RunnerLog("HeinMpv: 裸名 LoadLibraryA 成功（exe 同目录没有该 DLL）");
    } else {
      RunnerLog("HeinMpv: LoadLibraryW 成功 %ls", full.c_str());
    }
  }
  auto fn = reinterpret_cast<void (*)(FlutterDesktopPluginRegistrarRef)>(
      GetProcAddress(handle, "HeinPlayMpvDesktopPluginRegisterWithRegistrar"));
  if (fn == nullptr) {
    RunnerLog("HeinMpv: GetProcAddress(HeinPlayMpvDesktopPluginRegisterWithRegistrar) 失败 err=%lu",
              (unsigned long)GetLastError());
    return;
  }
  // 🔴 Flutter 3.47 起 PluginRegistry::GetRegistrarForPlugin 直接返回
  //    FlutterDesktopPluginRegistrarRef（C API 句柄），不再返回
  //    C++ 的 PluginRegistrar* 包装类。旧代码按包装类写法会编译失败。
  FlutterDesktopPluginRegistrarRef registrar =
      registry->GetRegistrarForPlugin("HeinPlayMpvDesktop");
  if (registrar == nullptr) {
    RunnerLog("HeinMpv: GetRegistrarForPlugin 返回空");
    return;
  }
  fn(registrar);
  RunnerLog("HeinMpv: Windows 壳已注册");
}

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  // 🔴 桌面 mpv 壳（非 pubspec 插件，须手动注册）。
  //    Flutter 3.47 起 FlutterEngine 直接继承 PluginRegistry，
  //    旧的 engine()->plugins() 访问器已被移除（编译报
  //    C2039: "plugins" 不是 "flutter::FlutterEngine" 的成员），
  //    现在直接把 engine 指针当 PluginRegistry 用即可。
  RegisterHeinMpvPlugin(flutter_controller_->engine());

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // 立即显示窗口，并创建原生启动封面覆盖层（位于 Flutter 视图之上）。Flutter 子
  // 视图保持原有可见状态正常渲染，因此首帧回调会按原模板逻辑可靠触发；覆盖层在
  // 引擎初始化阶段显示“零解码”封面，首帧就绪后移除，由 Flutter 视图（同一张 TV
  // 封面）无缝衔接。
  CreateSplashOverlay();
  this->Show();

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    // 首帧就绪后移除原生封面覆盖层，Flutter 视图（同一张 TV 封面）无缝衔接显示。
    DestroySplashOverlay();
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
