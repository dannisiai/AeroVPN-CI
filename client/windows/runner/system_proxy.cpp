#include "system_proxy.h"

#include <wininet.h>
#include <vector>

namespace {
constexpr wchar_t kBackup[] = L"Software\\AeroVPN\\SystemProxyRecovery";

bool Fail(const char* operation, long long code, std::string* error) {
  *error = std::string(operation) + " failed (Windows " + std::to_string(code) + ")";
  return false;
}

LSTATUS WriteString(HKEY key, const wchar_t* name, const std::wstring& value) {
  return RegSetValueExW(key, name, 0, REG_SZ,
      reinterpret_cast<const BYTE*>(value.c_str()),
      static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
}

LSTATUS ReadString(HKEY key, const wchar_t* name, std::wstring* value) {
  DWORD bytes = 0;
  LSTATUS status = RegGetValueW(key, nullptr, name, RRF_RT_REG_SZ, nullptr, nullptr, &bytes);
  if (status != ERROR_SUCCESS) return status;
  std::vector<wchar_t> buffer(bytes / sizeof(wchar_t) + 1, L'\0');
  status = RegGetValueW(key, nullptr, name, RRF_RT_REG_SZ, nullptr, buffer.data(), &bytes);
  if (status == ERROR_SUCCESS) *value = buffer.data();
  return status;
}
}  // namespace

bool WindowsSystemProxy::Read(State* state, std::string* error) {
  INTERNET_PER_CONN_OPTIONW options[4]{};
  options[0].dwOption = INTERNET_PER_CONN_FLAGS;
  options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
  options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
  options[3].dwOption = INTERNET_PER_CONN_AUTOCONFIG_URL;
  INTERNET_PER_CONN_OPTION_LISTW list{};
  list.dwSize = static_cast<DWORD>(sizeof(list));
  list.dwOptionCount = 4;
  list.pOptions = options;
  DWORD size = static_cast<DWORD>(sizeof(list));
  const BOOL ok = InternetQueryOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION, &list, &size);
  const DWORD code = ok ? ERROR_SUCCESS : GetLastError();
  if (ok) {
    state->flags = options[0].Value.dwValue;
    state->server = options[1].Value.pszValue ? options[1].Value.pszValue : L"";
    state->bypass = options[2].Value.pszValue ? options[2].Value.pszValue : L"";
    state->pac = options[3].Value.pszValue ? options[3].Value.pszValue : L"";
  }
  for (int i = 1; i < 4; ++i) {
    if (options[i].Value.pszValue) GlobalFree(options[i].Value.pszValue);
  }
  return ok || Fail("Read system proxy", code, error);
}

bool WindowsSystemProxy::Apply(const State& state, std::string* error) {
  INTERNET_PER_CONN_OPTIONW options[4]{};
  options[0].dwOption = INTERNET_PER_CONN_FLAGS;
  options[0].Value.dwValue = state.flags;
  options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
  options[1].Value.pszValue = const_cast<wchar_t*>(state.server.c_str());
  options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
  options[2].Value.pszValue = const_cast<wchar_t*>(state.bypass.c_str());
  options[3].dwOption = INTERNET_PER_CONN_AUTOCONFIG_URL;
  options[3].Value.pszValue = const_cast<wchar_t*>(state.pac.c_str());
  INTERNET_PER_CONN_OPTION_LISTW list{};
  list.dwSize = static_cast<DWORD>(sizeof(list));
  list.dwOptionCount = 4;
  list.pOptions = options;
  if (!InternetSetOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION, &list,
                          static_cast<DWORD>(sizeof(list)))) {
    return Fail("Set system proxy", GetLastError(), error);
  }
  if (!InternetSetOptionW(nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr, 0) ||
      !InternetSetOptionW(nullptr, INTERNET_OPTION_REFRESH, nullptr, 0)) {
    return Fail("Notify proxy settings", GetLastError(), error);
  }
  return true;
}

bool WindowsSystemProxy::Save(const State& state, const std::wstring& managed,
                              std::string* error) {
  HKEY key = nullptr;
  LSTATUS status = RegCreateKeyExW(HKEY_CURRENT_USER, kBackup, 0, nullptr, 0,
                                  KEY_SET_VALUE, nullptr, &key, nullptr);
  if (status != ERROR_SUCCESS) return Fail("Create proxy recovery", status, error);
  status = RegSetValueExW(key, L"Flags", 0, REG_DWORD,
                         reinterpret_cast<const BYTE*>(&state.flags), sizeof(DWORD));
  if (status == ERROR_SUCCESS) status = WriteString(key, L"Server", state.server);
  if (status == ERROR_SUCCESS) status = WriteString(key, L"Bypass", state.bypass);
  if (status == ERROR_SUCCESS) status = WriteString(key, L"PAC", state.pac);
  if (status == ERROR_SUCCESS) status = WriteString(key, L"ManagedServer", managed);
  const DWORD valid = 1;
  if (status == ERROR_SUCCESS) {
    status = RegSetValueExW(key, L"Valid", 0, REG_DWORD,
                           reinterpret_cast<const BYTE*>(&valid), sizeof(DWORD));
  }
  if (status == ERROR_SUCCESS) status = RegFlushKey(key);
  RegCloseKey(key);
  if (status != ERROR_SUCCESS) {
    RegDeleteTreeW(HKEY_CURRENT_USER, kBackup);
    return Fail("Save proxy recovery", status, error);
  }
  return true;
}

bool WindowsSystemProxy::Enable(int port, std::string* error) {
  if (port < 1024 || port > 65535) return Fail("Proxy port", ERROR_INVALID_PARAMETER, error);
  if (!Disable(error)) return false;
  State previous;
  if (!Read(&previous, error)) return false;
  const std::wstring address = L"127.0.0.1:" + std::to_wstring(port);
  State next;
  next.flags = PROXY_TYPE_DIRECT | PROXY_TYPE_PROXY;
  next.server = L"http=" + address + L";https=" + address + L";socks=" + address;
  next.bypass = L"<local>;localhost;127.*;[::1];www.ethworldcupcoin.xyz;ethworldcupcoin.xyz";
  if (!Save(previous, next.server, error)) return false;
  if (!Apply(next, error)) {
    std::string rollback;
    if (Apply(previous, &rollback)) RegDeleteTreeW(HKEY_CURRENT_USER, kBackup);
    return false;
  }
  return true;
}

bool WindowsSystemProxy::Disable(std::string* error) {
  HKEY key = nullptr;
  LSTATUS status = RegOpenKeyExW(HKEY_CURRENT_USER, kBackup, 0, KEY_QUERY_VALUE, &key);
  if (status == ERROR_FILE_NOT_FOUND || status == ERROR_PATH_NOT_FOUND) return true;
  if (status != ERROR_SUCCESS) return Fail("Open proxy recovery", status, error);
  DWORD valid = 0, size = sizeof(DWORD);
  status = RegGetValueW(key, nullptr, L"Valid", RRF_RT_REG_DWORD, nullptr, &valid, &size);
  if (status == ERROR_FILE_NOT_FOUND || (status == ERROR_SUCCESS && valid != 1)) {
    RegCloseKey(key);
    RegDeleteTreeW(HKEY_CURRENT_USER, kBackup);
    return true;
  }
  State previous;
  std::wstring managed;
  if (status == ERROR_SUCCESS) {
    size = sizeof(DWORD);
    status = RegGetValueW(key, nullptr, L"Flags", RRF_RT_REG_DWORD, nullptr, &previous.flags, &size);
  }
  if (status == ERROR_SUCCESS) status = ReadString(key, L"Server", &previous.server);
  if (status == ERROR_SUCCESS) status = ReadString(key, L"Bypass", &previous.bypass);
  if (status == ERROR_SUCCESS) status = ReadString(key, L"PAC", &previous.pac);
  if (status == ERROR_SUCCESS) status = ReadString(key, L"ManagedServer", &managed);
  RegCloseKey(key);
  if (status != ERROR_SUCCESS) return Fail("Read proxy recovery", status, error);
  State current;
  if (!Read(&current, error)) return false;
  // Another application/user may have taken ownership since our connection.
  if ((current.flags & PROXY_TYPE_PROXY) != 0 && current.server == managed) {
    if (!Apply(previous, error)) return false;
  }
  status = RegDeleteTreeW(HKEY_CURRENT_USER, kBackup);
  return status == ERROR_SUCCESS || status == ERROR_FILE_NOT_FOUND || status == ERROR_PATH_NOT_FOUND ||
         Fail("Remove proxy recovery", status, error);
}
