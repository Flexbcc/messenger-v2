import 'api_client.dart';
import 'debug_log.dart';

enum ReachabilityStatus { reachable, notFound, transientFailure }

class ReachabilityResult {
  const ReachabilityResult(this.status, {this.detail});

  final ReachabilityStatus status;
  final String? detail;
}

class ConversationReachabilityService {
  const ConversationReachabilityService(this._api);

  final ApiClient _api;

  Future<ReachabilityResult> check(String peerUserId) async {
    try {
      DebugLog.instance.info('prekey', 'GET /users/$peerUserId/prekey-bundle');
      await _api.getPreKeyBundle(peerUserId);
      DebugLog.instance.info('prekey', 'OK for $peerUserId');
      return const ReachabilityResult(ReachabilityStatus.reachable);
    } on ApiException catch (error) {
      if (error.statusCode == 404) {
        return const ReachabilityResult(
          ReachabilityStatus.notFound,
          detail: 'Собеседник больше недоступен',
        );
      }
      DebugLog.instance.warn(
        'prekey',
        'temporary check failure for $peerUserId: $error',
      );
      return const ReachabilityResult(ReachabilityStatus.transientFailure);
    } catch (error) {
      DebugLog.instance.warn(
        'prekey',
        'temporary check failure for $peerUserId: $error',
      );
      return const ReachabilityResult(ReachabilityStatus.transientFailure);
    }
  }
}
