#ifndef RUNNER_DAEMON_SERVICE_CONTROL_H_
#define RUNNER_DAEMON_SERVICE_CONTROL_H_

#include <string>

// Starts AeroVpnDaemon through the Service Control Manager. The installer
// grants the interactive user only SERVICE_START and SERVICE_QUERY_STATUS.
bool EnsureAeroVpnDaemonStarted(std::string* error);

#endif  // RUNNER_DAEMON_SERVICE_CONTROL_H_
