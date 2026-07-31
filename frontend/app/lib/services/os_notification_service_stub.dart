/// Web — OS notifications unavailable.
class OsNotificationService {
  OsNotificationService._();
  static final instance = OsNotificationService._();

  Future<void> init() async {}

  Future<void> show({
    required String title,
    required String body,
    String? conversationId,
  }) async {}
}
