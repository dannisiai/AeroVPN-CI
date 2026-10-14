#ifndef RUNNER_SYSTEM_PROXY_H_
#define RUNNER_SYSTEM_PROXY_H_

#include <windows.h>
#include <string>

// Runs in the desktop user's process, never in the SYSTEM service.
class WindowsSystemProxy {
 public:
  bool Enable(int port, std::string* error);
  bool Disable(std::string* error);

 private:
  struct State {
    DWORD flags = 0;
    std::wstring server;
    std::wstring bypass;
    std::wstring pac;
  };
  static bool Read(State* state, std::string* error);
  static bool Apply(const State& state, std::string* error);
  static bool Save(const State& state, const std::wstring& managed,
                   std::string* error);
};

#endif
