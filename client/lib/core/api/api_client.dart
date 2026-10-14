import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../config/brand_config.dart';
import 'api_endpoints.dart';
import 'api_models.dart';

class ApiException implements Exception {
  final int statusCode;
  final String message;
  ApiException(this.statusCode, this.message);

  @override
  String toString() => 'ApiException($statusCode): $message';
}

typedef TokenUpdateCallback = Future<void> Function(String newAccessToken, String newRefreshToken);
typedef LogoutCallback = void Function();

/// Outcome of a token refresh attempt.
/// - success: new tokens stored, original request should be retried.
/// - expired: the server definitively rejected the refresh token
///   (rotated away / revoked) - the local session must be dropped.
/// - transient: network/timeout/5xx - the session must SURVIVE so the
///   user can retry instead of being logged out.
enum _RefreshOutcome { success, expired, transient }

class ApiClient {
  final String baseUrl;
  final http.Client _client = http.Client();

  String? _accessToken;
  String? _refreshToken;
  TokenUpdateCallback? onTokenUpdate;
  LogoutCallback? onSessionExpired;

  ApiClient({this.baseUrl = BrandConfig.apiBaseUrl});

  void setTokens({String? accessToken, String? refreshToken}) {
    _accessToken = accessToken;
    _refreshToken = refreshToken;
  }

  void clearTokens() {
    _accessToken = null;
    _refreshToken = null;
  }

  bool get isAuthenticated => _accessToken != null && _accessToken!.isNotEmpty;

  // HTTP POST helper
  Future<dynamic> post(String endpoint, Map<String, dynamic> body, {bool requireAuth = false}) async {
    return _send('POST', endpoint, body: body, requireAuth: requireAuth);
  }

  // HTTP GET helper
  Future<dynamic> get(String endpoint, {bool requireAuth = true}) async {
    return _send('GET', endpoint, requireAuth: requireAuth);
  }

  Future<dynamic> _send(String method, String endpoint, {Map<String, dynamic>? body, bool requireAuth = false}) async {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };

    if (requireAuth && _accessToken != null) {
      headers['Authorization'] = 'Bearer $_accessToken';
    }

    // Primary is the configured HTTPS API (BrandConfig.apiBaseUrl). Fallbacks come
    // from whitelabel.json (BrandConfig.apiFallbackBaseUrls) so the brand
    // config stays the single source of truth; the list is de-duplicated.
    final candidateBaseUrls = <String>{
      baseUrl,
      ...BrandConfig.apiFallbackBaseUrls,
    }.toList();

    http.Response? response;
    dynamic lastError;
    // The base URL that actually served the request. The 401-refresh retry
    // must reuse it: the fallback exists precisely because the primary is
    // unreachable, so retrying against the primary would always fail.
    String? usedBaseUrl;

    for (final base in candidateBaseUrls) {
      try {
        final uri = Uri.parse('$base$endpoint');
        if (method == 'POST') {
          response = await _client.post(
            uri,
            headers: headers,
            body: body != null ? jsonEncode(body) : null,
          ).timeout(BrandConfig.apiTimeout);
        } else {
          response = await _client.get(
            uri,
            headers: headers,
          ).timeout(BrandConfig.apiTimeout);
        }
        if (response.statusCode > 0) {
          usedBaseUrl = base;
          break;
        }
      } catch (e) {
        lastError = e;
      }
    }

    if (response == null) {
      throw ApiException(0, 'Network connection error: $lastError');
    }

    // Handle 401 Unauthorized with Automatic Token Refresh
    if (response.statusCode == 401 && requireAuth && _refreshToken != null) {
      final outcome = await _attemptTokenRefresh();
      if (outcome == _RefreshOutcome.success) {
        // Retry the original request on the base URL that actually worked,
        // with the newly obtained access token.
        headers['Authorization'] = 'Bearer $_accessToken';
        final retryUri = Uri.parse('${usedBaseUrl ?? baseUrl}$endpoint');
        if (method == 'POST') {
          response = await _client.post(
            retryUri,
            headers: headers,
            body: body != null ? jsonEncode(body) : null,
          ).timeout(BrandConfig.apiTimeout);
        } else {
          response = await _client.get(
            retryUri,
            headers: headers,
          ).timeout(BrandConfig.apiTimeout);
        }
      } else if (outcome == _RefreshOutcome.expired) {
        onSessionExpired?.call();
        throw ApiException(401, 'Session expired. Please log in again.');
      } else {
        // Transient refresh failure (network down, timeout, 5xx): keep the
        // local session and surface a retriable network error instead of
        // logging the user out.
        throw ApiException(0, 'Token refresh temporarily unavailable; please retry');
      }
    }

    // A gateway or proxy may answer with an HTML error page instead of JSON;
    // surface that as an ApiException rather than crashing on FormatException.
    dynamic responseBody;
    try {
      responseBody = response.body.isNotEmpty ? jsonDecode(response.body) : {};
    } catch (_) {
      throw ApiException(
          response.statusCode,
          'Non-JSON response from server (HTTP ${response.statusCode}); '
          'a gateway or captive portal may be intercepting the connection');
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return responseBody;
    } else {
      final errorMsg = responseBody is Map ? (responseBody['error'] ?? responseBody['message'] ?? 'Request failed') : 'Request failed';
      throw ApiException(response.statusCode, errorMsg.toString());
    }
  }

  // Single-flight guard: concurrent 401s share one refresh call. The control
  // plane rotates refresh tokens on every use, so a second parallel refresh
  // would present the already-rotated token, fail as expired, and force a
  // logout that the first refresh was about to prevent.
  Future<_RefreshOutcome> _attemptTokenRefresh() {
    return _refreshInFlight ??= _doTokenRefresh().whenComplete(() {
      _refreshInFlight = null;
    });
  }

  Future<_RefreshOutcome>? _refreshInFlight;

  Future<_RefreshOutcome> _doTokenRefresh() async {
    if (_refreshToken == null) return _RefreshOutcome.expired;
    // The refresh endpoint is reachable through the same fallback chain as
    // every other call. A 4xx from the server means the refresh token is
    // definitively rejected (rotated away / revoked); network errors and
    // 5xx are transient.
    final candidateBaseUrls = <String>{
      baseUrl,
      ...BrandConfig.apiFallbackBaseUrls,
    };
    http.Response? response;
    for (final base in candidateBaseUrls) {
      try {
        response = await _client.post(
          Uri.parse('$base${ApiEndpoints.refresh}'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'refresh_token': _refreshToken}),
        ).timeout(const Duration(seconds: 5));
        break;
      } catch (_) {}
    }
    if (response == null) return _RefreshOutcome.transient;
    if (response.statusCode == 200) {
      try {
        final data = jsonDecode(response.body);
        final newAccess = data['access_token'] as String;
        final newRefresh = data['refresh_token'] as String;
        _accessToken = newAccess;
        _refreshToken = newRefresh;
        await onTokenUpdate?.call(newAccess, newRefresh);
        return _RefreshOutcome.success;
      } catch (_) {
        return _RefreshOutcome.transient;
      }
    }
    if (response.statusCode >= 500) return _RefreshOutcome.transient;
    return _RefreshOutcome.expired;
  }

  // Typed API Operations
  Future<void> sendVerificationCode(String email) async {
    await post(ApiEndpoints.sendCode, {'email': email});
  }

  Future<Map<String, dynamic>> register(String email, String password, String code) async {
    final res = await post(ApiEndpoints.register, {
      'email': email,
      'password': password,
      'code': code,
    });
    return res as Map<String, dynamic>;
  }

  Future<AuthTokens> login(String email, String password, {Map<String, dynamic>? deviceInfo}) async {
    final res = await post(ApiEndpoints.login, {
      'email': email,
      'password': password,
      'device_info': deviceInfo ?? {'device_name': 'Desktop Client', 'os': 'windows'},
    });
    return AuthTokens.fromJson(res as Map<String, dynamic>);
  }

  Future<void> forgotPassword(String email) async {
    await post(ApiEndpoints.forgotPassword, {'email': email});
  }

  Future<void> resetPassword(String email, String code, String newPassword) async {
    await post(ApiEndpoints.resetPassword, {
      'email': email,
      'code': code,
      'new_password': newPassword,
    });
  }

  Future<PlanModel> getAccount() async {
    final res = await get(ApiEndpoints.account, requireAuth: true);
    return PlanModel.fromJson((res as Map<String, dynamic>)['plan'] as Map<String, dynamic>? ?? {});
  }

  Future<List<RegionModel>> getRegions() async {
    final res = await get(ApiEndpoints.regions, requireAuth: true);
    final rawList = (res as Map<String, dynamic>)['regions'] as List<dynamic>? ?? [];
    return rawList.map((e) => RegionModel.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<ConnectResponse> connect({
    required String regionId,
    String? cityId,
    String protocolPreference = 'auto',
    String? deviceId,
  }) async {
    final payload = <String, dynamic>{
      'region_id': regionId,
      'protocol_preference': protocolPreference,
    };
    if (cityId != null) payload['city_id'] = cityId;
    if (deviceId != null) payload['device_id'] = deviceId;

    final res = await post(ApiEndpoints.connect, payload, requireAuth: true);
    return ConnectResponse.fromJson(res as Map<String, dynamic>);
  }

  /// Revokes the server-side login session (POST /v1/auth/logout).
  Future<void> logout() async {
    await post(ApiEndpoints.logout, <String, dynamic>{}, requireAuth: true);
  }

  /// Flags a live connect session revoked so its device slot frees immediately
  /// (otherwise it occupies max_devices accounting until the TTL sweep).
  Future<void> revokeConnectSession(String sessionId) async {
    await post(
      ApiEndpoints.revokeConnectSession,
      {'session_id': sessionId},
      requireAuth: true,
    );
  }
}
