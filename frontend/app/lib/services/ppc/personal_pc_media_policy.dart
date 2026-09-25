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
}
