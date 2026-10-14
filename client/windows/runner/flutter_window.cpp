#include "flutter_window.h"

#include <optional>
#include <shellapi.h>
#include <windows.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <string>
#include <variant>

#include "daemon_service_control.h"
#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {
constexpr UINT kTrayIconId = 1;
constexpr wchar_t kTrayTooltip[] = L"AeroVPN";
}  // namespace

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
  std::string recovery_error;
  system_proxy_.Disable(&recovery_error);
  system_proxy_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "aerovpn/system_proxy",
      &flutter::StandardMethodCodec::GetInstance());
  system_proxy_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        std::string error;
        bool ok = false;
        if (call.method_name() == "disable") {
          ok = system_proxy_.Disable(&error);
        } else if (call.method_name() == "enable") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          int port = 0;
          if (args) {
            const auto entry = args->find(flutter::EncodableValue("port"));
            if (entry != args->end()) {
              if (const auto* value = std::get_if<int32_t>(&entry->second)) port = *value;
            }
          }
          ok = system_proxy_.Enable(port, &error);
        } else {
          result->NotImplemented();
          return;
        }
        if (ok) result->Success();
        else result->Error("SYSTEM_PROXY_FAILED", error);
      });
  daemon_control_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "aerovpn/daemon_control",
      &flutter::StandardMethodCodec::GetInstance());
  daemon_control_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() != "startIfStopped") {
          result->NotImplemented();
          return;
        }
        std::string error;
        if (EnsureAeroVpnDaemonStarted(&error)) {
          result->Success();
        } else {
          result->Error("DAEMON_START_FAILED", error);
        }
      });
  tray_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "aerovpn/tray",
      &flutter::StandardMethodCodec::GetInstance());
  AddTrayIcon();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  RemoveTrayIcon();
  // Proxy restoration belongs to a confirmed tunnel stop. Restoring it here
  // could send traffic direct if the window is destroyed while the daemon runs.
  system_proxy_channel_.reset();
  daemon_control_channel_.reset();
  if (tray_channel_) {
    tray_channel_->SetMethodCallHandler(nullptr);
    tray_channel_.reset();
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (taskbar_created_message_ != 0 && message == taskbar_created_message_) {
    tray_icon_added_ = false;
    AddTrayIcon();
    return 0;
  }

  if (message == kExitConfirmedMessage) {
    Destroy();
    return 0;
  }

  if (message == WM_CLOSE) {
    if (tray_icon_added_) {
      ShowWindow(hwnd, SW_HIDE);
    } else {
      RequestExit();
    }
    return 0;
  }

  if (message == kTrayCallbackMessage) {
    const UINT event = LOWORD(static_cast<DWORD_PTR>(lparam));
    if (event == WM_LBUTTONUP || event == WM_LBUTTONDBLCLK) {
      RestoreFromTray();
    } else if (event == WM_RBUTTONUP || event == WM_CONTEXTMENU) {
      ShowTrayContextMenu();
    }
    return 0;
  }

  if (message == WM_COMMAND) {
    switch (LOWORD(wparam)) {
      case kTrayShowCommand:
        RestoreFromTray();
        return 0;
      case kTrayExitCommand:
        RequestExit();
        return 0;
    }
  }

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

bool FlutterWindow::AddTrayIcon() {
  if (tray_icon_added_) return true;

  HWND window = GetHandle();
  if (window == nullptr) return false;

  if (taskbar_created_message_ == 0) {
    taskbar_created_message_ = RegisterWindowMessageW(L"TaskbarCreated");
  }
  if (tray_icon_handle_ == nullptr) {
    tray_icon_handle_ = static_cast<HICON>(LoadImageW(
        GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
        GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON),
        LR_DEFAULTCOLOR));
  }
  if (tray_icon_handle_ == nullptr) return false;

  tray_icon_data_ = {};
  tray_icon_data_.cbSize = sizeof(tray_icon_data_);
  tray_icon_data_.hWnd = window;
  tray_icon_data_.uID = kTrayIconId;
  tray_icon_data_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  tray_icon_data_.uCallbackMessage = kTrayCallbackMessage;
  tray_icon_data_.hIcon = tray_icon_handle_;
  wcscpy_s(tray_icon_data_.szTip, kTrayTooltip);

  if (!Shell_NotifyIconW(NIM_ADD, &tray_icon_data_)) return false;
  tray_icon_added_ = true;
  tray_icon_data_.uVersion = NOTIFYICON_VERSION_4;
  Shell_NotifyIconW(NIM_SETVERSION, &tray_icon_data_);
  return true;
}

void FlutterWindow::RemoveTrayIcon() {
  if (tray_icon_added_) {
    Shell_NotifyIconW(NIM_DELETE, &tray_icon_data_);
    tray_icon_added_ = false;
  }
  if (tray_icon_handle_ != nullptr) {
    DestroyIcon(tray_icon_handle_);
    tray_icon_handle_ = nullptr;
  }
}

void FlutterWindow::RestoreFromTray() {
  HWND window = GetHandle();
  if (window == nullptr) return;
  ShowWindow(window, SW_RESTORE);
  ShowWindow(window, SW_SHOW);
  SetForegroundWindow(window);
}

void FlutterWindow::ShowTrayContextMenu() {
  HWND window = GetHandle();
  if (window == nullptr) return;
  HMENU menu = CreatePopupMenu();
  if (menu == nullptr) return;
  AppendMenuW(menu, MF_STRING, kTrayShowCommand, L"Open AeroVPN");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kTrayExitCommand, L"Exit AeroVPN");

  POINT cursor{};
  GetCursorPos(&cursor);
  SetForegroundWindow(window);
  TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN | TPM_LEFTALIGN,
                 cursor.x, cursor.y, 0, window, nullptr);
  PostMessageW(window, WM_NULL, 0, 0);
  DestroyMenu(menu);
}

void FlutterWindow::RequestExit() {
  if (exit_pending_) return;
  if (!tray_channel_) {
    RestoreFromTray();
    return;
  }

  exit_pending_ = true;
  auto result = std::make_unique<flutter::MethodResultFunctions<flutter::EncodableValue>>(
      [this](const flutter::EncodableValue* value) {
        exit_pending_ = false;
        const auto* should_exit = value ? std::get_if<bool>(value) : nullptr;
        if (should_exit != nullptr && *should_exit) {
          HWND window = GetHandle();
          if (window == nullptr ||
              !PostMessageW(window, kExitConfirmedMessage, 0, 0)) {
            RestoreFromTray();
          }
        } else {
          RestoreFromTray();
        }
      },
      [this](const std::string&, const std::string&,
             const flutter::EncodableValue*) {
        exit_pending_ = false;
        RestoreFromTray();
      },
      [this]() {
        exit_pending_ = false;
        RestoreFromTray();
      });
  tray_channel_->InvokeMethod("requestExit", nullptr, std::move(result));
}
