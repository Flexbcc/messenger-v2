import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'api_client.dart';
import 'local_settings_store.dart';

class ContactDeviceFingerprint {
  const ContactDeviceFingerprint({
    required this.deviceId,
    required this.deviceName,
    required this.deviceType,
    required this.fingerprint,
  });

  final String deviceId;
  final String deviceName;
  final String deviceType;
  final String fingerprint;
}

/// Loads and validates public Signal identity keys used for manual trust.
class ContactKeyVerificationService {
  ContactKeyVerificationService({ApiClient? api, LocalSettingsStore? store})
    : _api = api ?? ApiClient(),
      _store = store ?? LocalSettingsStore();

  final ApiClient _api;
  final LocalSettingsStore _store;

  Future<List<ContactDeviceFingerprint>> load(String userId) async {
    if (!_canonicalId.hasMatch(userId)) {
      throw const FormatException('invalid contact id');
    }
    final rawDevices = await _api.getUserDeviceBundles(userId);
    if (rawDevices.isEmpty) {
      throw StateError('У контакта нет подтверждённых устройств');
    }
    final seen = <String>{};
    final result = <ContactDeviceFingerprint>[];
    for (final raw in rawDevices) {
      if (raw.keys.toSet().difference(_allowedFields).isNotEmpty) {
        throw const FormatException('invalid contact device response');
      }
      final deviceId = _bounded(raw['device_id'], 128, 'device id');
      final deviceName = _bounded(raw['device_name'], 100, 'device name');
      final deviceType = _bounded(raw['device_type'], 20, 'device type');
      final encodedKey = _bounded(raw['identity_key'], 128, 'identity key');
      if (!seen.add(deviceId)) {
        throw const FormatException('duplicate contact device');
      }
      late final List<int> keyBytes;
      try {
        keyBytes = base64Decode(encodedKey);
      } on FormatException {
        throw const FormatException('invalid contact identity key');
      }
      if (keyBytes.length != 33 || base64Encode(keyBytes) != encodedKey) {
        throw const FormatException('invalid contact identity key');
      }
      result.add(
        ContactDeviceFingerprint(
          deviceId: deviceId,
          deviceName: deviceName,
          deviceType: deviceType,
          fingerprint: _formatFingerprint(
            sha256.convert(keyBytes).toString().toUpperCase(),
          ),
        ),
      );
    }
    result.sort((left, right) => left.deviceId.compareTo(right.deviceId));
    return List.unmodifiable(result);
  }

  Future<void> recordVerified(
    String userId,
    List<ContactDeviceFingerprint> devices,
  ) async {
    if (!_canonicalId.hasMatch(userId) ||
        devices.isEmpty ||
        devices.length > 512 ||
        devices.any(
          (device) =>
              !_canonicalId.hasMatch(device.deviceId) ||
              !_fingerprintPattern.hasMatch(device.fingerprint),
        )) {
      throw const FormatException('invalid verified contact keys');
    }
    await _store.setString(
      _snapshotKey(userId),
      jsonEncode({
        'v': 1,
        'devices': [
          for (final device in devices)
            {'device_id': device.deviceId, 'fingerprint': device.fingerprint},
        ],
      }),
    );
  }

  Future<bool> hasCurrentVerification(String userId) async {
    final current = await load(userId);
    final packed = await _store.getString(_snapshotKey(userId), '');
    if (packed.isEmpty || packed.length > 64 * 1024) return false;
    final decoded = jsonDecode(packed);
    if (decoded is! Map<String, dynamic> ||
        decoded['v'] != 1 ||
        decoded['devices'] is! List) {
      return false;
    }
    final stored = decoded['devices'] as List;
    if (stored.length != current.length || stored.length > 512) return false;
    for (var index = 0; index < current.length; index++) {
      final item = stored[index];
      if (item is! Map ||
          item.length != 2 ||
          item['device_id'] != current[index].deviceId ||
          item['fingerprint'] != current[index].fingerprint) {
        return false;
      }
    }
    return true;
  }

  Future<void> clearVerification(String userId) async {
    if (!_canonicalId.hasMatch(userId)) return;
    await _store.remove(_snapshotKey(userId));
  }

  static String _bounded(Object? value, int maxLength, String label) {
    if (value is! String || value.isEmpty || value.length > maxLength) {
      throw FormatException('invalid $label');
    }
    return value;
  }

  static String _formatFingerprint(String value) {
    final groups = <String>[];
    for (var offset = 0; offset < value.length; offset += 4) {
      groups.add(value.substring(offset, offset + 4));
    }
    return groups.join(' ');
  }

  static String _snapshotKey(String userId) =>
      'contact_verified_keys_v1.$userId';

  static final _canonicalId = RegExp(r'^[A-Za-z0-9_.:-]{1,128}$');
  static final _fingerprintPattern = RegExp(r'^[A-F0-9]{4}( [A-F0-9]{4}){15}$');
  static const _allowedFields = {
    'device_id',
    'device_name',
    'device_type',
    'identity_key',
  };
}
