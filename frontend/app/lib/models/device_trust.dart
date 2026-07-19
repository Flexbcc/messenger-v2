/// Local trust & access flags for a registered device session.
class DeviceTrustProfile {
  const DeviceTrustProfile({
    required this.trusted,
    required this.privateModeAccess,
    required this.secretRoomAccess,
  });

  final bool trusted;
  final bool privateModeAccess;
  final bool secretRoomAccess;

  static const currentDevice = DeviceTrustProfile(
    trusted: true,
    privateModeAccess: true,
    secretRoomAccess: true,
  );

  static const unknown = DeviceTrustProfile(
    trusted: false,
    privateModeAccess: false,
    secretRoomAccess: false,
  );

  DeviceTrustProfile copyWith({
    bool? trusted,
    bool? privateModeAccess,
    bool? secretRoomAccess,
  }) {
    return DeviceTrustProfile(
      trusted: trusted ?? this.trusted,
      privateModeAccess: privateModeAccess ?? this.privateModeAccess,
      secretRoomAccess: secretRoomAccess ?? this.secretRoomAccess,
    );
  }

  String encode() => '${trusted ? 1 : 0}|${privateModeAccess ? 1 : 0}|${secretRoomAccess ? 1 : 0}';

  static DeviceTrustProfile decode(String? raw) {
    if (raw == null || raw.isEmpty) return DeviceTrustProfile.unknown;
    final parts = raw.split('|');
    if (parts.length != 3) return DeviceTrustProfile.unknown;
    bool flag(String s) => s == '1';
    return DeviceTrustProfile(
      trusted: flag(parts[0]),
      privateModeAccess: flag(parts[1]),
      secretRoomAccess: flag(parts[2]),
    );
  }
}
