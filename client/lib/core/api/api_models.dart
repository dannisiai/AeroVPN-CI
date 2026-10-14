class UserModel {
  final String id;
  final String email;
  final String planStatus;

  UserModel({required this.id, required this.email, required this.planStatus});

  factory UserModel.fromJson(Map<String, dynamic> json) {
    return UserModel(
      id: json['id'] as String? ?? '',
      email: json['email'] as String? ?? '',
      planStatus: json['plan_status'] as String? ?? 'active',
    );
  }
}

class PlanModel {
  final String id;
  final String name;
  final String status;
  final int expiresAt;
  final int maxDevices;
  final int currentDevices;
  final double trafficGb;

  PlanModel({
    required this.id,
    required this.name,
    required this.status,
    required this.expiresAt,
    required this.maxDevices,
    required this.currentDevices,
    this.trafficGb = 0.0,
  });

  bool get isActive => status == 'active' && expiresAt > (DateTime.now().millisecondsSinceEpoch ~/ 1000);
  DateTime get expiryDate => DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000);
  int get remainingDays {
    final diff = expiryDate.difference(DateTime.now()).inDays;
    return diff > 0 ? diff : 0;
  }

  factory PlanModel.fromJson(Map<String, dynamic> json) {
    return PlanModel(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '未开通会员',
      status: json['status'] as String? ?? 'expired',
      expiresAt: (json['expires_at'] as num?)?.toInt() ?? 0,
      maxDevices: (json['max_devices'] as num?)?.toInt() ?? 0,
      currentDevices: (json['current_devices'] as num?)?.toInt() ?? 0,
      trafficGb: (json['traffic_gb'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

class CityModel {
  final String id;
  final String name;
  final int latencyMs;
  final int loadPercent;
  final List<String> features;

  CityModel({
    required this.id,
    required this.name,
    required this.latencyMs,
    required this.loadPercent,
    required this.features,
  });

  factory CityModel.fromJson(Map<String, dynamic> json) {
    return CityModel(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      latencyMs: (json['latency_ms'] as num?)?.toInt() ?? 50,
      loadPercent: (json['load_percent'] as num?)?.toInt() ?? 40,
      features: (json['features'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [],
    );
  }
}

class RegionModel {
  final String id;
  final String name;
  final String code;
  final String flagEmoji;
  final bool recommended;
  final List<CityModel> cities;

  RegionModel({
    required this.id,
    required this.name,
    required this.code,
    required this.flagEmoji,
    required this.recommended,
    required this.cities,
  });

  CityModel get defaultCity => cities.isNotEmpty ? cities.first : CityModel(id: id, name: name, latencyMs: 40, loadPercent: 30, features: []);

  factory RegionModel.fromJson(Map<String, dynamic> json) {
    final citiesRaw = json['cities'] as List<dynamic>? ?? [];
    return RegionModel(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      code: json['code'] as String? ?? '',
      flagEmoji: json['flag_emoji'] as String? ?? '🌐',
      recommended: json['recommended'] as bool? ?? false,
      cities: citiesRaw.map((c) => CityModel.fromJson(c as Map<String, dynamic>)).toList(),
    );
  }
}

class EphemeralNodeSpec {
  final String server;
  final int serverPort;
  final String? uuid;
  final String? password;
  final String? flow;
  final Map<String, dynamic>? tls;
  final Map<String, dynamic>? obfs;
  final Map<String, dynamic>? wireguard;
  // Server-declared bandwidth capacity for hysteria2 (Mbps). Null/0 keeps the
  // sing-box default (BBR); values > 0 are passed through as up_mbps/down_mbps.
  final int? upMbps;
  final int? downMbps;

  EphemeralNodeSpec({
    required this.server,
    required this.serverPort,
    this.uuid,
    this.password,
    this.flow,
    this.tls,
    this.obfs,
    this.wireguard,
    this.upMbps,
    this.downMbps,
  });

  factory EphemeralNodeSpec.fromJson(Map<String, dynamic> json) {
    return EphemeralNodeSpec(
      server: json['server'] as String? ?? '',
      serverPort: (json['server_port'] as num?)?.toInt() ?? 443,
      uuid: json['uuid'] as String?,
      password: json['password'] as String?,
      flow: json['flow'] as String?,
      tls: json['tls'] as Map<String, dynamic>?,
      obfs: (json['obfs'] ?? (json['tls'] as Map<String, dynamic>?)?['obfs']) as Map<String, dynamic>?,
      wireguard: json['wireguard'] as Map<String, dynamic>?,
      upMbps: (json['up_mbps'] as num?)?.toInt(),
      downMbps: (json['down_mbps'] as num?)?.toInt(),
    );
  }
}

class ConnectResponse {
  final String sessionId;
  final String regionId;
  final String cityId;
  final String cityName;
  final String countryName;
  final String countryCode;
  final String virtualIp;
  final int expiresAt;
  final int ttlSeconds;
  final String protocol;
  final EphemeralNodeSpec nodeSpec;

  ConnectResponse({
    required this.sessionId,
    required this.regionId,
    required this.cityId,
    required this.cityName,
    required this.countryName,
    required this.countryCode,
    required this.virtualIp,
    required this.expiresAt,
    required this.ttlSeconds,
    required this.protocol,
    required this.nodeSpec,
  });

  factory ConnectResponse.fromJson(Map<String, dynamic> json) {
    return ConnectResponse(
      sessionId: json['session_id'] as String? ?? '',
      regionId: json['region_id'] as String? ?? '',
      cityId: json['city_id'] as String? ?? '',
      cityName: json['city_name'] as String? ?? '',
      countryName: json['country_name'] as String? ?? '',
      countryCode: json['country_code'] as String? ?? '',
      virtualIp: json['virtual_ip'] as String? ?? '',
      expiresAt: (json['expires_at'] as num?)?.toInt() ?? 0,
      ttlSeconds: (json['ttl_seconds'] as num?)?.toInt() ?? 3600,
      protocol: json['protocol'] as String? ?? 'vless',
      nodeSpec: EphemeralNodeSpec.fromJson(json['node_spec'] as Map<String, dynamic>? ?? {}),
    );
  }
}

class AuthTokens {
  final String accessToken;
  final String refreshToken;
  final int expiresIn;
  final String deviceSessionId;
  final UserModel user;

  AuthTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresIn,
    required this.deviceSessionId,
    required this.user,
  });

  factory AuthTokens.fromJson(Map<String, dynamic> json) {
    return AuthTokens(
      accessToken: json['access_token'] as String? ?? '',
      refreshToken: json['refresh_token'] as String? ?? '',
      expiresIn: (json['expires_in'] as num?)?.toInt() ?? 3600,
      deviceSessionId: json['device_session_id'] as String? ?? '',
      user: UserModel.fromJson(json['user'] as Map<String, dynamic>? ?? {}),
    );
  }
}
