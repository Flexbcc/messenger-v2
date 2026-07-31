import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Runtime network endpoints (from invite redeem or manual bootstrap).
///
/// Post-R5 (docs/reality/R4-routing.md, "Нет client backup routes"): besides
/// the primary [homeUrl], we keep [backupHomeUrls] — alternate Home nodes
/// seen in the Gateway `/gateway/routing` response — so re-bootstrap has
/// somewhere to go if the primary Gateway/Home is down. [gatewayUrl] and
/// [discoveryUrl] are kept alongside so a re-bootstrap doesn't depend on the
/// compile-time defaults either.
class NetworkBootstrap {
  const NetworkBootstrap({
    required this.clusterId,
    required this.gatewayUrl,
    required this.discoveryUrl,
    required this.homeUrl,
    required this.mediaUrl,
    this.backupHomeUrls = const [],
  });

  final String clusterId;
  final String gatewayUrl;
  final String discoveryUrl;
  final String homeUrl;
  final String mediaUrl;
  final List<String> backupHomeUrls;

  factory NetworkBootstrap.fromJson(Map<String, dynamic> json) {
    final homeUrl = json['home_url'] as String;
    // `backup_home_urls` is our own persisted shape (see toJson); Gateway
    // responses (invite redeem / GET /gateway/routing) instead carry a
    // nested `routing.home_nodes` (or top-level `home_nodes`) ranked list —
    // fall back to deriving backups from that when present.
    final storedBackups = json['backup_home_urls'] as List<dynamic>?;
    final routing = json['routing'] as Map<String, dynamic>? ?? json;
    return NetworkBootstrap(
      clusterId: json['cluster_id'] as String? ?? 'default',
      gatewayUrl: json['gateway_url'] as String,
      discoveryUrl: json['discovery_url'] as String,
      homeUrl: homeUrl,
      mediaUrl: json['media_url'] as String,
      backupHomeUrls: storedBackups != null
          ? storedBackups.map((e) => e.toString()).toList()
          : extractBackupHomeUrls(routing, homeUrl),
    );
  }

  Map<String, dynamic> toJson() => {
        'cluster_id': clusterId,
        'gateway_url': gatewayUrl,
        'discovery_url': discoveryUrl,
        'home_url': homeUrl,
        'media_url': mediaUrl,
        'backup_home_urls': backupHomeUrls,
      };

  /// All known Home candidates, primary first, de-duplicated.
  List<String> get allHomeUrls => {homeUrl, ...backupHomeUrls}.toList();

  NetworkBootstrap copyWith({
    String? clusterId,
    String? gatewayUrl,
    String? discoveryUrl,
    String? homeUrl,
    String? mediaUrl,
    List<String>? backupHomeUrls,
  }) {
    return NetworkBootstrap(
      clusterId: clusterId ?? this.clusterId,
      gatewayUrl: gatewayUrl ?? this.gatewayUrl,
      discoveryUrl: discoveryUrl ?? this.discoveryUrl,
      homeUrl: homeUrl ?? this.homeUrl,
      mediaUrl: mediaUrl ?? this.mediaUrl,
      backupHomeUrls: backupHomeUrls ?? this.backupHomeUrls,
    );
  }
}

/// Pulls alternate Home URLs out of a `/gateway/routing` payload (either the
/// nested `routing` object from invite redeem, or the routing response
/// itself), excluding [primaryHomeUrl]. Ranking (latency) from the Gateway is
/// preserved as-is.
List<String> extractBackupHomeUrls(Map<String, dynamic>? routing, String primaryHomeUrl) {
  if (routing == null) return const [];
  final nodes = routing['home_nodes'] as List<dynamic>?;
  if (nodes == null) return const [];
  final urls = <String>[];
  for (final n in nodes) {
    final url = (n as Map<String, dynamic>?)?['url'] as String?;
    if (url != null && url.isNotEmpty && url != primaryHomeUrl && !urls.contains(url)) {
      urls.add(url);
    }
  }
  return urls;
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

  /// Post-R5 phase C (lite): re-fetch `/gateway/routing` from the last known
  /// Gateway to refresh [NetworkBootstrap.backupHomeUrls] / discoveryUrl
  /// without touching the primary [NetworkBootstrap.homeUrl]. Best-effort —
  /// swallows errors so callers (boot, connection retry) never block on a
  /// down Gateway; on failure the last persisted backups are kept as-is.
  static Future<void> refreshBackups() async {
    final current = _memory;
    if (current == null) return;
    try {
      final routing = await BootstrapService.fetchRouting(
        gatewayUrl: current.gatewayUrl,
        clusterId: current.clusterId,
      );
      final backups = extractBackupHomeUrls(routing, current.homeUrl);
      await save(current.copyWith(
        backupHomeUrls: backups,
        discoveryUrl: routing['discovery_url'] as String? ?? current.discoveryUrl,
      ));
    } catch (_) {
      // Gateway unreachable — primary connectivity is unaffected; retry next boot/probe.
    }
  }
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

  /// `GET /gateway/routing` — used to refresh backup Home/Discovery
  /// candidates after the initial bootstrap (see [BootstrapStore.refreshBackups]).
  static Future<Map<String, dynamic>> fetchRouting({
    required String gatewayUrl,
    String clusterId = 'default',
  }) async {
    final base = gatewayUrl.replaceAll(RegExp(r'/+$'), '');
    final resp = await http
        .get(
          Uri.parse('$base/gateway/routing?cluster_id=$clusterId'),
          headers: {'Accept': 'application/json'},
        )
        .timeout(const Duration(seconds: 6));
    if (resp.statusCode != 200) {
      throw Exception('Routing недоступен (${resp.statusCode})');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }
}
