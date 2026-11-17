#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>
#include <shellapi.h>

#include "resource.h"

#include "flutter/generated_plugin_registrant.h"

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
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  window_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "localview/window",
      &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "setFullscreen") {
          const bool* on = std::get_if<bool>(call.arguments());
          SetFullscreen(on != nullptr && *on);
          result->Success();
        } else if (call.method_name() == "setKeepAlive") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (args != nullptr) {
            auto on = args->find(flutter::EncodableValue("on"));
            if (on != args->end()) {
              const bool* b = std::get_if<bool>(&on->second);
              keep_alive_ = b != nullptr && *b;
            }
            auto tip = args->find(flutter::EncodableValue("tip"));
            if (tip != args->end()) {
              const std::string* t = std::get_if<std::string>(&tip->second);
              if (t != nullptr) {
                int n = MultiByteToWideChar(CP_UTF8, 0, t->c_str(), -1, nullptr, 0);
                std::wstring w(n > 0 ? n - 1 : 0, L'\0');
                if (n > 1) MultiByteToWideChar(CP_UTF8, 0, t->c_str(), -1, w.data(), n);
                tray_tip_ = w.empty() ? L"Localview" : w;
              }
            }
          }
          // Nothing left to keep alive while hidden: quit as a normal close would have.
          if (!keep_alive_ && tray_added_ && !IsWindowVisible(GetHandle())) {
            RemoveTray();
            DestroyWindow(GetHandle());
          }
          result->Success();
        } else if (call.method_name() == "hide") {
          HideToTray();
          result->Success();
        } else if (call.method_name() == "show") {
          ShowFromTray();
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::SetFullscreen(bool on) {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr || on == fullscreen_) {
    return;
  }
  if (on) {
    saved_style_ = GetWindowLongPtr(hwnd, GWL_STYLE);
    GetWindowRect(hwnd, &saved_rect_);
    MONITORINFO mi;
    mi.cbSize = sizeof(mi);
    GetMonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &mi);
    SetWindowLongPtr(hwnd, GWL_STYLE, saved_style_ & ~static_cast<LONG_PTR>(WS_OVERLAPPEDWINDOW));
    SetWindowPos(hwnd, HWND_TOP, mi.rcMonitor.left, mi.rcMonitor.top,
                 mi.rcMonitor.right - mi.rcMonitor.left, mi.rcMonitor.bottom - mi.rcMonitor.top,
                 SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
  } else {
    SetWindowLongPtr(hwnd, GWL_STYLE, saved_style_);
    SetWindowPos(hwnd, nullptr, saved_rect_.left, saved_rect_.top,
                 saved_rect_.right - saved_rect_.left, saved_rect_.bottom - saved_rect_.top,
                 SWP_NOOWNERZORDER | SWP_NOZORDER | SWP_FRAMECHANGED);
  }
  fullscreen_ = on;
}

constexpr UINT kTrayMessage = WM_APP + 1;
constexpr UINT kTrayOpen = 1, kTrayQuit = 2;

void FlutterWindow::HideToTray() {
  HWND hwnd = GetHandle();
  if (!tray_added_) {
    NOTIFYICONDATAW nid = {};
    nid.cbSize = sizeof(nid);
    nid.hWnd = hwnd;
    nid.uID = 1;
    nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    nid.uCallbackMessage = kTrayMessage;
    nid.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
    wcsncpy_s(nid.szTip, tray_tip_.c_str(), _TRUNCATE);
    tray_added_ = Shell_NotifyIconW(NIM_ADD, &nid) != FALSE;
  }
  ShowWindow(hwnd, SW_HIDE);
  NotifyHidden(true);
}

void FlutterWindow::ShowFromTray() {
  HWND hwnd = GetHandle();
  ShowWindow(hwnd, IsIconic(hwnd) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(hwnd);
  RemoveTray();
  NotifyHidden(false);
}

void FlutterWindow::RemoveTray() {
  if (!tray_added_) return;
  NOTIFYICONDATAW nid = {};
  nid.cbSize = sizeof(nid);
  nid.hWnd = GetHandle();
  nid.uID = 1;
  Shell_NotifyIconW(NIM_DELETE, &nid);
  tray_added_ = false;
}

void FlutterWindow::NotifyHidden(bool hidden) {
  if (window_channel_) {
    window_channel_->InvokeMethod("hidden", std::make_unique<flutter::EncodableValue>(hidden));
  }
}

void FlutterWindow::OnDestroy() {
  RemoveTray();
  window_channel_ = nullptr;
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
    case WM_CLOSE:
      if (keep_alive_) {
        HideToTray();
        return 0;
      }
      break;
    case kTrayMessage:
      switch (LOWORD(lparam)) {
        case WM_LBUTTONUP:
        case WM_LBUTTONDBLCLK:
          ShowFromTray();
          break;
        case WM_RBUTTONUP:
        case WM_CONTEXTMENU: {
          HMENU menu = CreatePopupMenu();
          AppendMenuW(menu, MF_STRING, kTrayOpen, L"Open Localview");
          AppendMenuW(menu, MF_STRING, kTrayQuit, L"Quit (disconnects)");
          POINT pt;
          GetCursorPos(&pt);
          SetForegroundWindow(hwnd);
          UINT cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON, pt.x, pt.y, 0, hwnd, nullptr);
          DestroyMenu(menu);
          if (cmd == kTrayOpen) {
            ShowFromTray();
          } else if (cmd == kTrayQuit) {
            keep_alive_ = false;
            RemoveTray();
            DestroyWindow(hwnd);
          }
          break;
        }
      }
      return 0;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
