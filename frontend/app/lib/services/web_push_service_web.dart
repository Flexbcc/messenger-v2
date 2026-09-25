import 'dart:js_interop';

@JS('ouoPushSubscribe')
external JSPromise<JSString?> _subscribe(JSString vapidPublicKey);

@JS('ouoPushUnsubscribe')
external JSPromise<JSAny?> _unsubscribe();

@JS('ouoPushSupported')
external JSBoolean get _supported;

class WebPushService {
  WebPushService._();
  static final instance = WebPushService._();

  bool get isSupported => _supported.toDart;

  Future<String?> subscribe(String vapidPublicKey) async {
    final value = await _subscribe(vapidPublicKey.toJS).toDart;
    return value?.toDart;
  }

  Future<void> unsubscribe() async {
    await _unsubscribe().toDart;
  }
}
