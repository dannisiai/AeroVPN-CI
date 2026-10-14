class ApiEndpoints {
  static const String sendCode = '/v1/auth/send-code';
  static const String register = '/v1/auth/register';
  // NOTE: /v1/auth/verify-email was removed from the contract - registration
  // verifies the code directly via /v1/auth/register and the production control
  // plane never implemented a separate verify endpoint.
  static const String login = '/v1/auth/login';
  static const String refresh = '/v1/auth/refresh';
  static const String logout = '/v1/auth/logout';
  static const String forgotPassword = '/v1/auth/forgot-password';
  static const String resetPassword = '/v1/auth/reset-password';

  static const String account = '/v1/account';
  static const String regions = '/v1/regions';
  static const String connect = '/v1/connect';
  static const String connectSessions = '/v1/connect/sessions';
  static const String revokeConnectSession = '/v1/connect/revoke';
  static const String devices = '/v1/devices';
  static const String revokeDevice = '/v1/devices/revoke';
}
