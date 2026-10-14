#include "daemon_service_control.h"

#include <windows.h>

#include <string>

namespace {

void SetWindowsError(std::string* error, const char* action, DWORD code) {
  if (error != nullptr) {
    *error = std::string(action) + " (Windows error " +
             std::to_string(static_cast<unsigned long>(code)) +
             "). Run the AeroVPN installer as administrator if the service is missing or access is denied.";
  }
}

bool QueryStatus(SC_HANDLE service, SERVICE_STATUS_PROCESS* status,
                 std::string* error) {
  DWORD bytes_needed = 0;
  if (!QueryServiceStatusEx(service, SC_STATUS_PROCESS_INFO,
                            reinterpret_cast<LPBYTE>(status),
                            static_cast<DWORD>(sizeof(*status)), &bytes_needed)) {
    SetWindowsError(error, "Could not query AeroVPN service state",
                    GetLastError());
    return false;
  }
  return true;
}

}  // namespace

bool EnsureAeroVpnDaemonStarted(std::string* error) {
  SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
  if (manager == nullptr) {
    SetWindowsError(error, "Could not connect to the Windows Service Manager",
                    GetLastError());
    return false;
  }

  SC_HANDLE service = OpenServiceW(manager, L"AeroVpnDaemon",
                                  SERVICE_QUERY_STATUS | SERVICE_START);
  if (service == nullptr) {
    const DWORD code = GetLastError();
    CloseServiceHandle(manager);
    SetWindowsError(error, "Could not open AeroVpnDaemon", code);
    return false;
  }

  SERVICE_STATUS_PROCESS status{};
  if (!QueryStatus(service, &status, error)) {
    CloseServiceHandle(service);
    CloseServiceHandle(manager);
    return false;
  }

  if (status.dwCurrentState == SERVICE_RUNNING ||
      status.dwCurrentState == SERVICE_START_PENDING) {
    CloseServiceHandle(service);
    CloseServiceHandle(manager);
    return true;
  }

  if (status.dwCurrentState == SERVICE_STOP_PENDING) {
    CloseServiceHandle(service);
    CloseServiceHandle(manager);
    if (error != nullptr) {
      *error = "AeroVpnDaemon is stopping. Wait a few seconds and retry.";
    }
    return false;
  }

  if (status.dwCurrentState != SERVICE_STOPPED) {
    CloseServiceHandle(service);
    CloseServiceHandle(manager);
    if (error != nullptr) {
      *error = "AeroVpnDaemon is in an unsupported service state.";
    }
    return false;
  }

  if (!StartServiceW(service, 0, nullptr)) {
    const DWORD code = GetLastError();
    if (code != ERROR_SERVICE_ALREADY_RUNNING) {
      CloseServiceHandle(service);
      CloseServiceHandle(manager);
      SetWindowsError(error, "Could not start AeroVpnDaemon", code);
      return false;
    }
  }

  CloseServiceHandle(service);
  CloseServiceHandle(manager);
  return true;
}
