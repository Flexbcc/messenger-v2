import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const _allowInsecureBootstrapHttp = bool.fromEnvironment(
  'ALLOW_INSECURE_BOOTSTRAP_HTTP',
  defaultValue: false,
);
const _maxBootstrapResponseBytes = 256 * 1024;

Future<http.Response> _getBounded(Uri uri, Duration timeout) async {
  final client = http.Client();
  try {
    final request = http.Request('GET', uri)
      ..headers['Accept'] = 'application/json'
      ..followRedirects = false
      ..maxRedirects = 0;
    final streamed = await client.send(request).timeout(timeout);
    final declared = streamed.contentLength;
    if (declared != null &&
        (declared < 0 || declared > _maxBootstrapResponseBytes)) {
      throw const FormatException('Ответ bootstrap слишком большой');
    }
    final builder = BytesBuilder(copy: false);
    var received = 0;
    await for (final chunk in streamed.stream.timeout(timeout)) {
      received += chunk.length;
      if (received > _maxBootstrapResponseBytes) {
        throw const FormatException('Ответ bootstrap слишком большой');
      }
      builder.add(chunk);
    }
    return http.Response.bytes(
      builder.takeBytes(),
      streamed.statusCode,
      headers: streamed.headers,
      isRedirect: streamed.isRedirect,
      persistentConnection: streamed.persistentConnection,
      reasonPhrase: streamed.reasonPhrase,
      request: streamed.request,
    );
  } finally {
    client.close();
  }
}

String validatedNetworkOrigin(Object? raw, String fieldName) {
  if (raw is! String || raw.isEmpty || raw.length > 2048) {
    throw FormatException('$fieldName содержит недопустимый адрес');
  }
  final uri = Uri.tryParse(raw);
  if (uri == null ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.query.isNotEmpty ||
      uri.fragment.isNotEmpty ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      (uri.scheme != 'https' &&
          !(_allowInsecureBootstrapHttp && uri.scheme == 'http'))) {
    throw FormatException('$fieldName должен быть безопасным HTTPS origin');
  }
  return '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
}

Map<String, dynamic> _decodeBoundedObject(http.Response response) {
  if (response.bodyBytes.length > _maxBootstrapResponseBytes) {
    throw const FormatException('Ответ bootstrap слишком большой');
  }
  final decoded = jsonDecode(utf8.decode(response.bodyBytes));
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Ответ bootstrap имеет неверный формат');
  }
  return decoded;
}

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
    this.discoveryUrls = const [],
  });

  final String clusterId;
  final String gatewayUrl;
  final String discoveryUrl;
  final List<String> discoveryUrls;
  final String homeUrl;
  final String mediaUrl;
  final List<String> backupHomeUrls;

  factory NetworkBootstrap.fromJson(Map<String, dynamic> json) {
    final homeUrl = validatedNetworkOrigin(json['home_url'], 'home_url');
    // `backup_home_urls` is our own persisted shape (see toJson); Gateway
    // responses (invite redeem / GET /gateway/routing) instead carry a
    // nested `routing.home_nodes` (or top-level `home_nodes`) ranked list —
    // fall back to deriving backups from that when present.
    final storedBackups = json['backup_home_urls'] as List<dynamic>?;
    final routing = json['routing'] as Map<String, dynamic>? ?? json;
    final clusterId = json['cluster_id'] as String? ?? 'default';
    if (clusterId.isEmpty || clusterId.length > 128) {
      throw const FormatException('cluster_id имеет неверный формат');
    }
    final backups = storedBackups != null
        ? storedBackups
              .map((value) => validatedNetworkOrigin(value, 'backup_home_url'))
              .toList(growable: false)
        : extractBackupHomeUrls(routing, homeUrl);
    if (backups.length > 32) {
      throw const FormatException('Слишком много запасных Home-нод');
    }
    final rawDiscoveryUrls = json['discovery_urls'] as List<dynamic>?;
    final discoveryUrl = validatedNetworkOrigin(
      json['discovery_url'],
      'discovery_url',
    );
    final discoveryUrls = <String>[];
    for (final raw in rawDiscoveryUrls ?? const <dynamic>[]) {
      final origin = validatedNetworkOrigin(raw, 'discovery_urls');
      if (!discoveryUrls.contains(origin)) discoveryUrls.add(origin);
    }
    if (discoveryUrls.length > 16) {
      throw const FormatException('Слишком много Discovery-источников');
    }
    return NetworkBootstrap(
      clusterId: clusterId,
      gatewayUrl: validatedNetworkOrigin(json['gateway_url'], 'gateway_url'),
      discoveryUrl: discoveryUrl,
      homeUrl: homeUrl,
      mediaUrl: validatedNetworkOrigin(json['media_url'], 'media_url'),
      backupHomeUrls: backups.where((url) => url != homeUrl).toSet().toList(),
      discoveryUrls: {discoveryUrl, ...discoveryUrls}.toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'cluster_id': clusterId,
    'gateway_url': gatewayUrl,
    'discovery_url': discoveryUrl,
    'discovery_urls': discoveryUrls,
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
    List<String>? discoveryUrls,
  }) {
    return NetworkBootstrap(
      clusterId: clusterId ?? this.clusterId,
      gatewayUrl: gatewayUrl ?? this.gatewayUrl,
      discoveryUrl: discoveryUrl ?? this.discoveryUrl,
      homeUrl: homeUrl ?? this.homeUrl,
      mediaUrl: mediaUrl ?? this.mediaUrl,
      backupHomeUrls: backupHomeUrls ?? this.backupHomeUrls,
      discoveryUrls: discoveryUrls ?? this.discoveryUrls,
    );
  }
}

/// Pulls alternate Home URLs out of a `/gateway/routing` payload (either the
/// nested `routing` object from invite redeem, or the routing response
/// itself), excluding [primaryHomeUrl]. Ranking (latency) from the Gateway is
/// preserved as-is.
List<String> extractBackupHomeUrls(
  Map<String, dynamic>? routing,
  String primaryHomeUrl,
) {
  if (routing == null) return const [];
  final nodes = routing['home_nodes'] as List<dynamic>?;
  if (nodes == null) return const [];
  final urls = <String>[];
  for (final n in nodes) {
    final rawUrl = (n as Map<String, dynamic>?)?['url'];
    try {
      final url = validatedNetworkOrigin(rawUrl, 'home_nodes.url');
      if (url != primaryHomeUrl && !urls.contains(url)) {
        urls.add(url);
      }
    } on FormatException {
      continue;
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
      final key = '${_prefix}json';
      if (prefs.containsKey(key) && !await prefs.remove(key)) {
        throw StateError('Unable to remove invalid network bootstrap');
      }
    }
  }

  static Future<void> save(NetworkBootstrap bootstrap) async {
    final validated = NetworkBootstrap.fromJson(bootstrap.toJson());
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(
      '${_prefix}json',
      jsonEncode(validated.toJson()),
    )) {
      throw StateError('Unable to persist network bootstrap');
    }
    _memory = validated;
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    final key = '${_prefix}json';
    if (prefs.containsKey(key) && !await prefs.remove(key)) {
      throw StateError('Unable to clear network bootstrap');
    }
    _memory = null;
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
      await save(
        current.copyWith(
          backupHomeUrls: backups,
          discoveryUrl:
              routing['discovery_url'] as String? ?? current.discoveryUrl,
          discoveryUrls: (routing['discovery_urls'] as List<dynamic>?)
              ?.map((value) => validatedNetworkOrigin(value, 'discovery_urls'))
              .toSet()
              .toList(),
        ),
      );
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
    if (token == null ||
        token.length < 16 ||
        token.length > 256 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(token)) {
      return null;
    }
    String gateway;
    if (uri.scheme == 'messenger') {
      gateway = uri.queryParameters['gateway'] ?? '';
      if (gateway.isEmpty) return null;
    } else if (uri.scheme == 'http' || uri.scheme == 'https') {
      try {
        gateway = validatedNetworkOrigin(
          '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}',
          'gateway',
        );
      } on FormatException {
        return null;
      }
    } else {
      return null;
    }
    try {
      gateway = validatedNetworkOrigin(gateway, 'gateway');
    } on FormatException {
      return null;
    }
    return (gatewayUrl: gateway, token: token);
  }

  static Future<NetworkBootstrap> redeemInvite({
    required String gatewayUrl,
    required String token,
  }) async {
    if (token.length < 16 ||
        token.length > 256 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(token)) {
      throw const FormatException('invite token имеет неверный формат');
    }
    final base = validatedNetworkOrigin(gatewayUrl, 'gateway');
    final resp = await _getBounded(
      Uri.parse('$base/gateway/invite/redeem/$token'),
      const Duration(seconds: 10),
    );
    if (resp.statusCode != 200) {
      throw Exception('Invite недействителен (${resp.statusCode})');
    }
    final data = _decodeBoundedObject(resp);
    return NetworkBootstrap.fromJson(data);
  }

  /// `GET /gateway/routing` — used to refresh backup Home/Discovery
  /// candidates after the initial bootstrap (see [BootstrapStore.refreshBackups]).
  static Future<Map<String, dynamic>> fetchRouting({
    required String gatewayUrl,
    String clusterId = 'default',
  }) async {
    if (clusterId.isEmpty ||
        clusterId.length > 128 ||
        !RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(clusterId)) {
      throw const FormatException('cluster_id имеет неверный формат');
    }
    final base = validatedNetworkOrigin(gatewayUrl, 'gateway');
    final uri = Uri.parse(
      '$base/gateway/routing',
    ).replace(queryParameters: {'cluster_id': clusterId});
    final resp = await _getBounded(uri, const Duration(seconds: 6));
    if (resp.statusCode != 200) {
      throw Exception('Routing недоступен (${resp.statusCode})');
    }
    return _decodeBoundedObject(resp);
  }
}
