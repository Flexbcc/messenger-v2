// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:js_util' as js_util;

import 'package:js/js.dart';

@JS('ouoPushSubscribe')
external Object _subscribe(String vapidPublicKey);

@JS('ouoPushUnsubscribe')
external Object _unsubscribe();

@JS('ouoPushSupported')
external bool get _supported;

class WebPushService {
  WebPushService._();
  static final instance = WebPushService._();

  bool get isSupported => _supported;

  Future<String?> subscribe(String vapidPublicKey) async {
    final value = await js_util.promiseToFuture<Object?>(
      _subscribe(vapidPublicKey),
    );
    return value?.toString();
  }

  Future<void> unsubscribe() async {
    await js_util.promiseToFuture<Object?>(_unsubscribe());
  }
}
