#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // "localview/window" channel: borderless fullscreen for Theater mode.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> window_channel_;
  void SetFullscreen(bool on);

  // Keep running in the background: closing the window hides it to a tray icon
  // while Localview has connections or is hosting.
  bool keep_alive_ = false;
  bool tray_added_ = false;
  std::wstring tray_tip_ = L"Localview";
  void HideToTray();
  void ShowFromTray();
  void RemoveTray();
  void NotifyHidden(bool hidden);
  bool fullscreen_ = false;
  LONG_PTR saved_style_ = 0;
  RECT saved_rect_ = {0, 0, 0, 0};
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
