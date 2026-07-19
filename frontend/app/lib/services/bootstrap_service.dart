import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Runtime network endpoints (from invite redeem or manual bootstrap).
class NetworkBootstrap {
  const NetworkBootstrap({
    required this.clusterId,
    required this.gatewayUrl,
    required this.discoveryUrl,
    required this.homeUrl,
    required this.mediaUrl,
  });

  final String clusterId;
  final String gatewayUrl;
  final String discoveryUrl;
  final String homeUrl;
  final String mediaUrl;

  factory NetworkBootstrap.fromJson(Map<String, dynamic> json) {
    return NetworkBootstrap(
      clusterId: json['cluster_id'] as String? ?? 'default',
      gatewayUrl: json['gateway_url'] as String,
      discoveryUrl: json['discovery_url'] as String,
      homeUrl: json['home_url'] as String,
      mediaUrl: json['media_url'] as String,
    );
  }

  Map<String, dynamic> toJson() => {
        'cluster_id': clusterId,
        'gateway_url': gatewayUrl,
        'discovery_url': discoveryUrl,
        'home_url': homeUrl,
        'media_url': mediaUrl,
      };
}

/// Persists chosen cluster endpoints on device (replaces compile-time URLs when set).
class BootstrapStore {
  BootstrapStore._();

  static const _prefix = 'network_bootstrap_';
  static NetworkBootstrap? _memory;

  static NetworkBootstrap? get current => _memory;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('${_prefix}json');
    if (raw == null || raw.isEmpty) {
      _memory = null;
      return;
    }
    try {
      _memory = NetworkBootstrap.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      _memory = null;
    }
  }

  static Future<void> save(NetworkBootstrap bootstrap) async {
    _memory = bootstrap;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('${_prefix}json', jsonEncode(bootstrap.toJson()));
  }

  static Future<void> clear() async {
    _memory = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('${_prefix}json');
  }

  static bool get isConfigured => _memory != null;
}

class BootstrapService {
  /// Parse invite link: .../join?t=TOKEN or messenger://join?gateway=...&t=...
  static ({String gatewayUrl, String token})? parseInviteLink(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;
    Uri uri;
    try {
      uri = Uri.parse(trimmed);
    } catch (_) {
      return null;
    }
    final token = uri.queryParameters['t'] ?? uri.queryParameters['token'];
    if (token == null || token.length < 8) return null;
    String gateway;
    if (uri.scheme == 'messenger') {
      gateway = uri.queryParameters['gateway'] ?? '';
      if (gateway.isEmpty) return null;
    } else if (uri.scheme == 'http' || uri.scheme == 'https') {
      gateway = '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
    } else {
      return null;
    }
    return (gatewayUrl: gateway.replaceAll(RegExp(r'/+$'), ''), token: token);
  }

  static Future<NetworkBootstrap> redeemInvite({
    required String gatewayUrl,
    required String token,
  }) async {
    final base = gatewayUrl.replaceAll(RegExp(r'/+$'), '');
    final resp = await http.get(
      Uri.parse('$base/gateway/invite/redeem/$token'),
      headers: {'Accept': 'application/json'},
    );
    if (resp.statusCode != 200) {
      throw Exception('Invite недействителен (${resp.statusCode})');
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return NetworkBootstrap.fromJson(data);
  }
}
