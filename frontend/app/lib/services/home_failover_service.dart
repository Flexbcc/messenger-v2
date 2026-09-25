import '../config.dart';
import 'bootstrap_service.dart';
import 'debug_log.dart';
import 'node_config_resolver.dart';

class HomeFailoverService {
  HomeFailoverService({NodeConfigResolver? resolver})
    : _resolver = resolver ?? NodeConfigResolver();

  final NodeConfigResolver _resolver;
  static const _cooldown = Duration(minutes: 3);

  DateTime? _lastAttemptAt;
  bool _inFlight = false;

  String? lastFromUrl;
  String? lastToUrl;
  DateTime? lastSucceededAt;

  Future<HomeFailoverResult?> recoverSession(
    Future<void> Function() recover,
  ) async {
    if (_inFlight) return null;
    final now = DateTime.now();
    final last = _lastAttemptAt;
    if (last != null && now.difference(last) < _cooldown) return null;

    _inFlight = true;
    _lastAttemptAt = now;
    try {
      final oldPrimary = BootstrapStore.current?.homeUrl;
      final newPrimary = await _resolver.failoverToBackupHome();
      if (newPrimary == null || newPrimary == oldPrimary) return null;
      await AppConfig.refreshFromCatalog();
      DebugLog.instance.warn(
        'routing',
        'client failover: $oldPrimary -> $newPrimary',
      );

      var recovered = false;
      try {
        await recover();
        recovered = true;
      } catch (error) {
        DebugLog.instance.warn(
          'routing',
          'session recovery on new home failed: $error',
        );
      }
      lastFromUrl = oldPrimary;
      lastToUrl = newPrimary;
      lastSucceededAt = now;
      return HomeFailoverResult(
        oldHomeUrl: oldPrimary,
        newHomeUrl: newPrimary,
        recovered: recovered,
        switchedAt: now,
      );
    } finally {
      _inFlight = false;
    }
  }

  Future<String?> preflight() async {
    try {
      if (await _resolver.isPrimaryReachable()) return null;
      final newPrimary = await _resolver.failoverToBackupHome();
      if (newPrimary == null) return null;
      await AppConfig.refreshFromCatalog();
      DebugLog.instance.warn(
        'routing',
        'client failover (pre-login) -> $newPrimary',
      );
      return newPrimary;
    } catch (error) {
      DebugLog.instance.warn(
        'routing',
        'pre-login failover unavailable: $error',
      );
      return null;
    }
  }
}

class HomeFailoverResult {
  const HomeFailoverResult({
    required this.oldHomeUrl,
    required this.newHomeUrl,
    required this.recovered,
    required this.switchedAt,
  });

  final String? oldHomeUrl;
  final String newHomeUrl;
  final bool recovered;
  final DateTime switchedAt;
}
