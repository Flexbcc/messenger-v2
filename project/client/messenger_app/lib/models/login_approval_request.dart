import '../models/device_info.dart';

enum LoginApprovalStatus { pending, approved, denied }

/// A login attempt from a new device awaiting approval on a trusted device.
class LoginApprovalRequest {
  LoginApprovalRequest({
    required this.deviceId,
    required this.deviceName,
    required this.deviceType,
    required this.requestedAt,
    this.status = LoginApprovalStatus.pending,
  });

  final String deviceId;
  final String deviceName;
  final String deviceType;
  final DateTime requestedAt;
  final LoginApprovalStatus status;

  factory LoginApprovalRequest.fromDevice(DeviceInfo device) {
    return LoginApprovalRequest(
      deviceId: device.id,
      deviceName: device.deviceName,
      deviceType: device.deviceType,
      requestedAt: device.createdAt,
    );
  }

  String encode() =>
      '${requestedAt.toIso8601String()}|$deviceId|$deviceName|$deviceType|${status.name}';

  static LoginApprovalRequest decode(String raw) {
    final parts = raw.split('|');
    if (parts.length < 5) {
      return LoginApprovalRequest(
        deviceId: raw,
        deviceName: 'Устройство',
        deviceType: 'unknown',
        requestedAt: DateTime.now(),
      );
    }
    return LoginApprovalRequest(
      requestedAt: DateTime.tryParse(parts[0]) ?? DateTime.now(),
      deviceId: parts[1],
      deviceName: parts[2],
      deviceType: parts[3],
      status: LoginApprovalStatus.values.firstWhere(
        (v) => v.name == parts[4],
        orElse: () => LoginApprovalStatus.pending,
      ),
    );
  }
}
