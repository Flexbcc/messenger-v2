import '../services/api_client.dart';
import 'debug_log.dart';

/// Relay opaque security event codes to trusted users — spec/0404 phase 3.
class SecuritySignalClient {
  SecuritySignalClient(this._api);

  final ApiClient _api;

  Future<bool> relay({
    required int event,
    required List<String> targets,
  }) async {
    if (targets.isEmpty) return false;
    try {
      await _api.postSecuritySignal(event: event, targets: targets);
      return true;
    } catch (error) {
      DebugLog.instance.warn('security-signal', 'relay request failed', error);
      return false;
    }
  }
}
