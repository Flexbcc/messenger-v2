import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../crypto/auth_keypair.dart';
import '../crypto/crypto_service.dart';
import 'api_client.dart';
import 'session_store.dart';

class AuthenticationAttempt {
  const AuthenticationAttempt({
    required this.authKeyPair,
    required this.crypto,
    required this.response,
  });

  final AuthKeyPair authKeyPair;
  final CryptoService crypto;
  final Map<String, dynamic> response;
}

/// Implements device authentication protocols without owning application UI state.
class AuthenticationService {
  AuthenticationService(this._api, this._sessionStore);

  final ApiClient _api;
  final SessionStore _sessionStore;

  static final RegExp _deviceLinkIdPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );
  static final RegExp _deviceLinkSecretPattern = RegExp(r'^[A-Za-z0-9_-]{43}$');

  String get _deviceName => defaultTargetPlatform.name;
  String get _deviceType =>
      kIsWeb ? 'web' : defaultTargetPlatform.name.toLowerCase();

  Future<(AuthKeyPair, CryptoService)> _material() async =>
      (await AuthKeyPair.loadOrCreate(), await CryptoService.loadOrCreate());

  Future<AuthenticationAttempt> register({
    required String displayName,
    required String phone,
    String? login,
    String? email,
    String? password,
  }) async {
    final (authKeyPair, crypto) = await _material();
    final response = await _api.register(
      displayName: displayName,
      phone: phone,
      login: login,
      email: email,
      password: password,
      deviceName: _deviceName,
      deviceType: _deviceType,
      authPublicKey: authKeyPair.publicKeyBase64,
      identityKeyBundle: await crypto.generatePublishableBundle(),
    );
    return AuthenticationAttempt(
      authKeyPair: authKeyPair,
      crypto: crypto,
      response: response,
    );
  }

  Future<AuthenticationAttempt> loginWithPassword({
    required String identifier,
    required String password,
  }) async {
    final (authKeyPair, crypto) = await _material();
    final response = await _api.loginWithPassword(
      identifier: identifier,
      password: password,
      deviceName: _deviceName,
      deviceType: _deviceType,
      authPublicKey: authKeyPair.publicKeyBase64,
      identityKeyBundle: await crypto.generatePublishableBundle(),
    );
    return AuthenticationAttempt(
      authKeyPair: authKeyPair,
      crypto: crypto,
      response: response,
    );
  }

  Future<({AuthenticationAttempt attempt, String displayName})>
  loginWithLocalKey() async {
    if (!await AuthKeyPair.existsLocally()) {
      throw StateError('Локальный ключ не найден');
    }
    final remembered = await _sessionStore.loadRememberedIdentity();
    if (remembered == null) {
      throw StateError('Не найден локальный идентификатор устройства');
    }
    final (authKeyPair, crypto) = await _material();
    final challenge = await _api.challenge(remembered.deviceId);
    final nonce = challenge['nonce'];
    if (nonce is! String || nonce.length < 40 || nonce.length > 64) {
      throw const FormatException('Сервер вернул некорректный challenge');
    }
    final nonceBytes = base64Decode(nonce);
    if (nonceBytes.length != 32) {
      throw const FormatException('Сервер вернул challenge неверной длины');
    }
    final response = await _api.verify(
      deviceId: remembered.deviceId,
      nonce: nonce,
      signature: await authKeyPair.signBase64(nonceBytes),
    );
    return (
      attempt: AuthenticationAttempt(
        authKeyPair: authKeyPair,
        crypto: crypto,
        response: response,
      ),
      displayName: remembered.displayName,
    );
  }

  /// Refresh an existing device session using challenge-response.
  Future<String> refreshSession({
    required Session session,
    required AuthKeyPair authKeyPair,
  }) async {
    final challenge = await _api.challenge(session.deviceId);
    final nonce = challenge['nonce'];
    if (nonce is! String || nonce.length < 40 || nonce.length > 64) {
      throw const FormatException('Сервер вернул некорректный challenge');
    }
    final nonceBytes = base64Decode(nonce);
    if (nonceBytes.length != 32) {
      throw const FormatException('Сервер вернул challenge неверной длины');
    }
    final response = await _api.verify(
      deviceId: session.deviceId,
      nonce: nonce,
      signature: await authKeyPair.signBase64(nonceBytes),
    );
    final accessToken = response['access_token'];
    if (accessToken is! String ||
        accessToken.length < 32 ||
        accessToken.length > 8192) {
      throw const FormatException('Сервер вернул некорректный токен');
    }
    _api.accessToken = accessToken;
    await _sessionStore.saveToken(accessToken);
    return accessToken;
  }

  Future<AuthenticationAttempt> createDeviceLink() async {
    final (authKeyPair, crypto) = await _material();
    final response = await _api.createDeviceLink(
      deviceName: _deviceName,
      deviceType: _deviceType,
      authPublicKey: authKeyPair.publicKeyBase64,
      identityKeyBundle: await crypto.generatePublishableBundle(),
    );
    final linkId = response['link_id'];
    final secret = response['secret'];
    final qrPayload = response['qr_payload'];
    if (linkId is! String || secret is! String || qrPayload is! String) {
      throw const FormatException('Сервер вернул неполную заявку привязки');
    }
    _validateDeviceLinkCredentials(linkId, secret);
    final parsedQr = parseDeviceLinkPayload(qrPayload);
    if (parsedQr['link_id'] != linkId || parsedQr['secret'] != secret) {
      throw const FormatException('QR привязки не совпадает с заявкой');
    }
    return AuthenticationAttempt(
      authKeyPair: authKeyPair,
      crypto: crypto,
      response: response,
    );
  }

  Future<Map<String, dynamic>> pollDeviceLink({
    required String linkId,
    required String secret,
  }) {
    _validateDeviceLinkCredentials(linkId, secret);
    return _api.pollDeviceLink(linkId: linkId, secret: secret);
  }

  Future<Map<String, dynamic>> inspectDeviceLink({
    required String linkId,
    required String secret,
  }) {
    _validateDeviceLinkCredentials(linkId, secret);
    return _api.inspectDeviceLink(linkId: linkId, secret: secret);
  }

  Future<void> approveDeviceLink({
    required String linkId,
    required String secret,
  }) {
    _validateDeviceLinkCredentials(linkId, secret);
    return _api.approveDeviceLink(linkId: linkId, secret: secret);
  }

  static Map<String, String> parseDeviceLinkPayload(String rawPayload) {
    if (rawPayload.isEmpty || rawPayload.length > 16 * 1024) {
      throw const FormatException('QR привязки повреждён');
    }
    final dynamic value;
    try {
      value = jsonDecode(rawPayload);
    } on FormatException {
      throw const FormatException('QR привязки повреждён');
    }
    if (value is! Map<String, dynamic> ||
        value.length != 4 ||
        value['kind'] != 'ouo_device_link' ||
        value['v'] != 1) {
      throw const FormatException('Это не QR привязки устройства OUO');
    }
    final linkId = value['id'];
    final secret = value['secret'];
    if (linkId is! String || secret is! String) {
      throw const FormatException('QR привязки повреждён');
    }
    _validateDeviceLinkCredentials(linkId, secret);
    return {'link_id': linkId, 'secret': secret};
  }

  static void _validateDeviceLinkCredentials(String linkId, String secret) {
    if (!_deviceLinkIdPattern.hasMatch(linkId) ||
        !_deviceLinkSecretPattern.hasMatch(secret)) {
      throw const FormatException('QR привязки содержит неверные данные');
    }
  }
}
