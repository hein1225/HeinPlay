#include "win32_window.h"

#include <algorithm>
#include <dwmapi.h>
#include <flutter_windows.h>

#include "resource.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

// 将 |bmp| 以 cover 方式（保持比例、居中裁切）拉伸绘制到 |wnd| 的客户区 DC。
static void PaintSplashBitmap(HDC hdc, HWND wnd, HBITMAP bmp) {
  BITMAP bm{};
  if (!GetObject(bmp, sizeof(bm), &bm) || bm.bmWidth <= 0 ||
      bm.bmHeight <= 0) {
    return;
  }
  RECT rc{};
  GetClientRect(wnd, &rc);
  const int cw = rc.right - rc.left;
  const int ch = rc.bottom - rc.top;
  if (cw <= 0 || ch <= 0) {
    return;
  }
  const double scale = std::max(static_cast<double>(cw) / bm.bmWidth,
                                static_cast<double>(ch) / bm.bmHeight);
  const int dw = static_cast<int>(bm.bmWidth * scale);
  const int dh = static_cast<int>(bm.bmHeight * scale);
  const int dx = (cw - dw) / 2;
  const int dy = (ch - dh) / 2;

  HDC mem_dc = CreateCompatibleDC(hdc);
  if (mem_dc == nullptr) {
    return;
  }
  const HBITMAP old = reinterpret_cast<HBITMAP>(SelectObject(mem_dc, bmp));
  SetStretchBltMode(hdc, HALFTONE);
  SetBrushOrgEx(hdc, 0, 0, nullptr);
  StretchBlt(hdc, dx, dy, dw, dh, mem_dc, 0, 0, bm.bmWidth, bm.bmHeight,
             SRCCOPY);
  SelectObject(mem_dc, old);
  DeleteDC(mem_dc);
}

// 原生启动封面覆盖层：一个覆盖在 Flutter 视图之上的子窗口，引擎初始化阶段显示
// 零解码封面；首帧就绪后销毁。其绘制逻辑与父窗口共用 PaintSplashBitmap。
constexpr const wchar_t kSplashOverlayClass[] =
    L"FLUTTER_RUNNER_SPLASH_OVERLAY";

static LRESULT CALLBACK SplashOverlayWndProc(HWND hwnd, UINT const message,
                                             WPARAM const wparam,
                                             LPARAM const lparam) noexcept {
  if (message == WM_PAINT) {
    PAINTSTRUCT ps;
    HDC hdc = BeginPaint(hwnd, &ps);
    const HBITMAP bmp =
        reinterpret_cast<HBITMAP>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
    if (bmp != nullptr) {
      PaintSplashBitmap(hdc, hwnd, bmp);
    }
    EndPaint(hwnd, &ps);
    return 0;
  }
  if (message == WM_ERASEBKGND) {
    return 1;
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}

static bool EnsureSplashOverlayClass() {
  static bool registered = false;
  if (registered) {
    return true;
  }
  WNDCLASS window_class{};
  window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
  window_class.lpszClassName = kSplashOverlayClass;
  window_class.style = CS_HREDRAW | CS_VREDRAW;
  window_class.hInstance = GetModuleHandle(nullptr);
  window_class.hbrBackground =
      reinterpret_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
  window_class.lpfnWndProc = SplashOverlayWndProc;
  if (RegisterClass(&window_class)) {
    registered = true;
  }
  return registered;
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    // 深色背景刷：在原生封面绘制前作为兜底，避免窗口显示瞬间露出桌面。
    window_class.hbrBackground = CreateSolidBrush(RGB(10, 10, 15));
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  HWND window = CreateWindow(
      window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
      Scale(origin.x, scale_factor), Scale(origin.y, scale_factor),
      Scale(size.width, scale_factor), Scale(size.height, scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  UpdateTheme(window);

  return OnCreate();
}

bool Win32Window::Show() {
  return ShowWindow(window_handle_, SW_SHOWNORMAL);
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    case WM_DESTROY:
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_SIZE: {
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      // 仅在启动封面仍生效时同步覆盖层/重绘父窗口封面；首帧后封面已移除，resize
      // 不再绘制封面，避免播放中调整窗口大小（窗口/小窗模式）露出静态封面。
      if (splash_shown_ && splash_overlay_ != nullptr) {
        MoveWindow(splash_overlay_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      } else if (splash_shown_ && splash_bitmap_ != nullptr) {
        InvalidateRect(hwnd, nullptr, FALSE);
      }
      return 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;

    case WM_ERASEBKGND:
      // 由 WM_PAINT 统一绘制封面，避免默认擦除露出桌面。
      return 1;

    case WM_PAINT: {
      PAINTSTRUCT ps;
      HDC hdc = BeginPaint(hwnd, &ps);
      // 仅启动封面生效期间绘制封面；首帧后封面移除，resize/重绘不再绘制，避免露出静态封面。
      if (splash_shown_ && splash_bitmap_ != nullptr) {
        DrawSplashBitmap(hdc, hwnd);
      }
      EndPaint(hwnd, &ps);
      return 0;
    }
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::DrawSplashBitmap(HDC hdc, HWND window) const {
  if (splash_bitmap_ != nullptr) {
    PaintSplashBitmap(hdc, window, splash_bitmap_);
  }
}

void Win32Window::CreateSplashOverlay() {
  if (splash_bitmap_ == nullptr || window_handle_ == nullptr) {
    return;
  }
  if (!EnsureSplashOverlayClass()) {
    return;
  }
  RECT rc = GetClientArea();
  splash_overlay_ = CreateWindowEx(
      0, kSplashOverlayClass, nullptr,
      WS_CHILD | WS_VISIBLE | WS_DISABLED, rc.left, rc.top,
      rc.right - rc.left, rc.bottom - rc.top, window_handle_, nullptr,
      GetModuleHandle(nullptr), nullptr);
  if (splash_overlay_ != nullptr) {
    SetWindowLongPtr(splash_overlay_, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(splash_bitmap_));
    // 确保覆盖层位于 Flutter 子视图之上。
    SetWindowPos(splash_overlay_, HWND_TOP, 0, 0, 0, 0,
                 SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE);
  }
}

void Win32Window::DestroySplashOverlay() {
  if (splash_overlay_ != nullptr) {
    DestroyWindow(splash_overlay_);
    splash_overlay_ = nullptr;
  }
  // 首帧后封面彻底失效：后续 resize/重绘均不再绘制封面，避免播放中调整窗口大小
  // （窗口/小窗模式）露出静态封面。封面位图资源仍保留至应用退出时统一释放。
  splash_shown_ = false;
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

bool Win32Window::OnCreate() {
  // 加载原生启动封面（若资源缺失则留空，由子类决定是否显示 Flutter 封面）。
  if (splash_bitmap_ == nullptr) {
    splash_bitmap_ = reinterpret_cast<HBITMAP>(LoadImage(
        GetModuleHandle(nullptr), MAKEINTRESOURCE(IDB_SPLASH), IMAGE_BITMAP, 0,
        0, LR_CREATEDIBSECTION));
  }
  // No-op otherwise; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  DestroySplashOverlay();
  if (splash_bitmap_ != nullptr) {
    DeleteObject(splash_bitmap_);
    splash_bitmap_ = nullptr;
  }
  // No-op otherwise; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}
