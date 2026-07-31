import '../local_settings_store.dart';
import '../settings_catalog_bridge.dart';
import '../settings_runtime.dart';
import 'ppc_vault.dart';

/// Decides whether new chat media should use direct PPC (sender device) storage.
class PersonalPcMediaPolicy {
  PersonalPcMediaPolicy._();

  static const _senderDeviceLocation = 'sender_device';

  /// True when catalog says media lives on sender device and phone is PPC-paired.
  static Future<bool> shouldUsePersonalPcMedia() async {
    final location = await SettingsRuntime.instance.storageMediaLocation();
    if (location != _senderDeviceLocation) return false;
    return PpcVault().isPaired();
  }

  /// Prefer SettingsRuntime; fallback keeps older direct-store reads working in tests.
  static Future<String> mediaLocation() async {
    try {
      return await SettingsRuntime.instance.storageMediaLocation();
    } catch (_) {
      return await LocalSettingsStore().getString(
        SettingsCatalogBridge.catalogKey('storage.media_location'),
        'personal_node_s3',
      );
    }
  }
}
