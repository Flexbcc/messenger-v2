import 'dart:convert';
import 'dart:typed_data';

import 'api_client.dart';
import 'local_settings_store.dart';
import 'session_store.dart';

typedef ProfileSnapshot = ({
  String displayName,
  String? login,
  String? phone,
  String? email,
  String? bio,
  Uint8List? avatar,
});

class ProfileService {
  ProfileService(this._api, this._localSettings, this._sessionStore);

  static const _avatarKey = 'profile.avatar.bytes';
  static const _maxAvatarBytes = 5 * 1024 * 1024;

  final ApiClient _api;
  final LocalSettingsStore _localSettings;
  final SessionStore _sessionStore;

  static String _requiredString(
    Map<String, dynamic> value,
    String key, {
    int maximum = 256,
  }) {
    final item = value[key];
    if (item is! String || item.isEmpty || item.length > maximum) {
      throw FormatException('invalid profile field: $key');
    }
    return item;
  }

  static String? _optionalString(
    Map<String, dynamic> value,
    String key, {
    int maximum = 1024,
  }) {
    final item = value[key];
    if (item == null || item == '') return null;
    if (item is! String || item.length > maximum) {
      throw FormatException('invalid profile field: $key');
    }
    return item;
  }

  Future<ProfileSnapshot> load() async {
    final remote = await _api.getMyProfile();
    Uint8List? avatar;
    final encodedAvatar = await _localSettings.getString(_avatarKey, '');
    if (encodedAvatar.isNotEmpty && encodedAvatar.length <= 8 * 1024 * 1024) {
      try {
        final decoded = base64Decode(encodedAvatar);
        if (decoded.length <= _maxAvatarBytes) avatar = decoded;
      } on FormatException {
        await _localSettings.remove(_avatarKey);
      }
    } else if (encodedAvatar.isNotEmpty) {
      await _localSettings.remove(_avatarKey);
    }
    return (
      displayName: _requiredString(remote, 'display_name'),
      login: _optionalString(remote, 'login', maximum: 50),
      phone: _optionalString(remote, 'phone', maximum: 32),
      email: _optionalString(remote, 'email', maximum: 255),
      bio: _optionalString(remote, 'bio'),
      avatar: avatar,
    );
  }

  Future<void> updateDisplayName(String displayName) async {
    await _api.updateDisplayName(displayName);
    await _sessionStore.saveDisplayName(displayName);
  }

  Future<void> update({
    required String displayName,
    required String login,
    required String phone,
    required String email,
    required String bio,
  }) async {
    await _api.updateProfile(
      displayName: displayName,
      login: login,
      phone: phone,
      email: email,
      bio: bio,
    );
    await _sessionStore.saveDisplayName(displayName);
  }

  Future<void> setAvatar(Uint8List? bytes) async {
    if (bytes == null) {
      await _localSettings.remove(_avatarKey);
      return;
    }
    if (bytes.length > _maxAvatarBytes) {
      throw ArgumentError.value(bytes.length, 'bytes', 'avatar is too large');
    }
    await _localSettings.setString(_avatarKey, base64Encode(bytes));
  }
}
