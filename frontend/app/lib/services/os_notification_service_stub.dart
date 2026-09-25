/// Fallback for targets without a supported OS/browser notification API.
class OsNotificationService {
  OsNotificationService._();
  static final instance = OsNotificationService._();

  bool get isSupported => false;
  String get permission => 'unsupported';

  Future<void> init() async {}

  Future<bool> requestPermission() async => false;

  Future<void> show({
    required String title,
    required String body,
    String? conversationId,
  }) async {}
}
