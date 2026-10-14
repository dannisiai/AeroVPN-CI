#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <windows.h>
#include <shellapi.h>

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "win32_window.h"
#include "system_proxy.h"

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
  WindowsSystemProxy system_proxy_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> system_proxy_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> daemon_control_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> tray_channel_;

  static constexpr UINT kTrayCallbackMessage = WM_APP + 1;
  static constexpr UINT kExitConfirmedMessage = WM_APP + 2;
  static constexpr UINT kTrayShowCommand = 0xA101;
  static constexpr UINT kTrayExitCommand = 0xA102;

  NOTIFYICONDATAW tray_icon_data_{};
  HICON tray_icon_handle_ = nullptr;
  UINT taskbar_created_message_ = 0;
  bool tray_icon_added_ = false;
  bool exit_pending_ = false;

  bool AddTrayIcon();
  void RemoveTrayIcon();
  void RestoreFromTray();
  void ShowTrayContextMenu();
  void RequestExit();
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
