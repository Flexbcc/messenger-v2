import '../models/device_info.dart';
import '../models/login_approval_request.dart';
import 'login_approval_service.dart';

/// Owns the in-memory queue of login approvals for the active account.
class LoginApprovalRuntimeService {
  LoginApprovalRuntimeService({LoginApprovalService? store})
    : _store = store ?? LoginApprovalService.instance;

  final LoginApprovalService _store;
  List<LoginApprovalRequest> _pending = const [];

  List<LoginApprovalRequest> get pending => List.unmodifiable(_pending);

  void clearRuntime() => _pending = const [];

  Future<LoginApprovalScanResult> refresh({
    required Iterable<DeviceInfo> devices,
    required bool currentDeviceTrusted,
    required bool Function(String deviceId) isTrusted,
  }) async {
    final previousIds = _pending.map((request) => request.deviceId).toSet();
    if (!currentDeviceTrusted) {
      _pending = const [];
      return const LoginApprovalScanResult(newRequests: []);
    }

    final next = await _store.pendingRequests(
      devices: devices,
      isTrusted: isTrusted,
    );
    _pending = List.unmodifiable(next);
    return LoginApprovalScanResult(
      newRequests: next
          .where((request) => !previousIds.contains(request.deviceId))
          .toList(growable: false),
    );
  }
}

class LoginApprovalScanResult {
  const LoginApprovalScanResult({required this.newRequests});

  final List<LoginApprovalRequest> newRequests;
}
