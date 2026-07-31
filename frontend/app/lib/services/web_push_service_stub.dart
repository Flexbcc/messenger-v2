class WebPushService {
  WebPushService._();
  static final instance = WebPushService._();

  bool get isSupported => false;
  Future<String?> subscribe(String vapidPublicKey) async => null;
  Future<void> unsubscribe() async {}
}
