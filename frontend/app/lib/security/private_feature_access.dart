import 'pin_security.dart';

/// Security prerequisites for progressively disclosed private features.
///
/// These values are derived from the secure PIN store. UI catalog flags must
/// never be used as authorization for protected features.
class PrivateFeatureAccess {
  const PrivateFeatureAccess({
    required this.hasPrimaryPin,
    required this.hasDecoyPin,
  });

  final bool hasPrimaryPin;
  final bool hasDecoyPin;

  bool get canConfigureDecoyPin => hasPrimaryPin;
  bool get canUseSecretFeatures => hasPrimaryPin && hasDecoyPin;

  static Future<PrivateFeatureAccess> load() async {
    final primary = await PinSecurity.isRealPinConfigured();
    // A stale decoy hash must not unlock anything without the primary PIN.
    final decoy = primary && await PinSecurity.hasFakePin();
    return PrivateFeatureAccess(hasPrimaryPin: primary, hasDecoyPin: decoy);
  }
}
