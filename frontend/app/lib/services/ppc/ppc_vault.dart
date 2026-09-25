import '../../security/secure_prefs.dart';
import '../account_scope_id.dart';
import '../local_settings_store.dart';
import 'ppc_payload.dart';
import 'ppc_transport.dart';

/// Persisted direct-mode PPC pairing state via [SecurePrefs]
/// (no raw Keychain on macOS — avoids Login password dialogs).
class PpcVault {
  PpcVault({SecurePrefs? prefs, String? userId})
    : _prefs = prefs ?? SecurePrefs.instance,
      _userId = userId;

  static const _kStoragePubkey = 'ppc.storage_pubkey';
  static const _kRouteKind = 'ppc.route_kind';
  static const _kLanHint = 'ppc.lan_hint';
  static const _kRelayUrl = 'ppc.relay_url';
  static const _kStorageNodeId = 'ppc.storage_node_id';
  static const _kPeerNodeId = 'ppc.peer_node_id';
  static const _kFingerprint = 'ppc.fingerprint';

  final SecurePrefs _prefs;
  final String? _userId;

  String _key(String base) {
    final userId = AccountScopeId.require(
      _userId ?? LocalSettingsStore.activeUserId,
    );
    return '${base}_u_$userId';
  }

  /// Save paired state after successful `resolveAndPair`.
  Future<void> save({
    required PpcPairResult result,
    required String peerNodeId,
  }) async {
    _validateState(
      storagePubkey: result.storagePubkey,
      routeKind: result.routeKind,
      peerNodeId: peerNodeId,
      lanHint: result.lanHint,
      relayUrl: result.relayUrl,
      storageNodeId: result.storageNodeId,
      fingerprint: result.fingerprint,
    );
    await _prefs.write(_key(_kStoragePubkey), result.storagePubkey);
    await _prefs.write(_key(_kRouteKind), result.routeKind.name);
    await _prefs.write(_key(_kPeerNodeId), peerNodeId);
    if (result.fingerprint != null) {
      await _prefs.write(_key(_kFingerprint), result.fingerprint!);
    } else {
      await _prefs.remove(_key(_kFingerprint));
    }
    if (result.lanHint != null) {
      await _prefs.write(_key(_kLanHint), result.lanHint!);
    } else {
      await _prefs.remove(_key(_kLanHint));
    }
    if (result.relayUrl != null) {
      await _prefs.write(_key(_kRelayUrl), result.relayUrl!);
    } else {
      await _prefs.remove(_key(_kRelayUrl));
    }
    if (result.storageNodeId != null) {
      await _prefs.write(_key(_kStorageNodeId), result.storageNodeId!);
    } else {
      await _prefs.remove(_key(_kStorageNodeId));
    }
  }

  /// Load persisted pairing; null when not paired.
  Future<PpcVaultState?> load() async {
    final storagePubkey = await _prefs.read(_key(_kStoragePubkey));
    final routeKindRaw = await _prefs.read(_key(_kRouteKind));
    final peerNodeId = await _prefs.read(_key(_kPeerNodeId));
    final lanHint = await _prefs.read(_key(_kLanHint));
    final relayUrl = await _prefs.read(_key(_kRelayUrl));
    final storageNodeId = await _prefs.read(_key(_kStorageNodeId));
    final fingerprint = await _prefs.read(_key(_kFingerprint));
    final values = [
      storagePubkey,
      routeKindRaw,
      peerNodeId,
      lanHint,
      relayUrl,
      storageNodeId,
      fingerprint,
    ];
    if (values.every((value) => value == null)) return null;
    if (storagePubkey == null || routeKindRaw == null || peerNodeId == null) {
      throw const FormatException('incomplete PPC vault state');
    }
    final routeKind = PpcRouteKind.values.asNameMap()[routeKindRaw];
    if (routeKind == null) {
      throw const FormatException('invalid PPC vault route');
    }
    _validateState(
      storagePubkey: storagePubkey,
      routeKind: routeKind,
      peerNodeId: peerNodeId,
      lanHint: lanHint,
      relayUrl: relayUrl,
      storageNodeId: storageNodeId,
      fingerprint: fingerprint,
    );

    return PpcVaultState(
      storagePubkey: storagePubkey,
      routeKind: routeKind,
      peerNodeId: peerNodeId,
      lanHint: lanHint,
      relayUrl: relayUrl,
      storageNodeId: storageNodeId,
      fingerprint: fingerprint,
    );
  }

  Future<bool> isPaired() async => await load() != null;

  static void _validateState({
    required String storagePubkey,
    required PpcRouteKind routeKind,
    required String peerNodeId,
    required String? lanHint,
    required String? relayUrl,
    required String? storageNodeId,
    required String? fingerprint,
  }) {
    try {
      validatePpcStoragePubkey(storagePubkey);
      validatePpcNodeId(peerNodeId, field: 'peer node id');
      validatePpcFingerprint(fingerprint, storagePubkey);
      if (lanHint != null) parseLanBase(lanHint);
      if (relayUrl != null) validatePpcRelayUrl(relayUrl);
      if (storageNodeId != null) {
        validatePpcNodeId(storageNodeId, field: 'relay storage node id');
      }
      if ((relayUrl == null) != (storageNodeId == null)) {
        throw PpcPayloadError('incomplete relay route');
      }
      if (routeKind == PpcRouteKind.lan && lanHint == null) {
        throw PpcPayloadError('missing LAN route');
      }
      if (routeKind == PpcRouteKind.relay && relayUrl == null) {
        throw PpcPayloadError('missing relay route');
      }
    } on Object catch (error) {
      throw FormatException('invalid PPC vault state', error);
    }
  }

  Future<void> clear() async {
    await _prefs.clearKeys([
      _key(_kStoragePubkey),
      _key(_kRouteKind),
      _key(_kLanHint),
      _key(_kRelayUrl),
      _key(_kStorageNodeId),
      _key(_kPeerNodeId),
      _key(_kFingerprint),
    ]);
  }

  static Future<void> clearLegacyUnscopedKeys() {
    return SecurePrefs.instance.clearKeys(const [
      _kStoragePubkey,
      _kRouteKind,
      _kLanHint,
      _kRelayUrl,
      _kStorageNodeId,
      _kPeerNodeId,
      _kFingerprint,
    ]);
  }
}

/// Restored vault snapshot for transport reconstruction.
class PpcVaultState {
  const PpcVaultState({
    required this.storagePubkey,
    required this.routeKind,
    required this.peerNodeId,
    this.lanHint,
    this.relayUrl,
    this.storageNodeId,
    this.fingerprint,
  });

  final String storagePubkey;
  final PpcRouteKind routeKind;
  final String peerNodeId;
  final String? lanHint;
  final String? relayUrl;
  final String? storageNodeId;
  final String? fingerprint;
}
