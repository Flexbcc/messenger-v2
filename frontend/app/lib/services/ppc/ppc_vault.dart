import '../../security/secure_prefs.dart';
import 'ppc_payload.dart';

/// Persisted direct-mode PPC pairing state via [SecurePrefs]
/// (no raw Keychain on macOS — avoids Login password dialogs).
class PpcVault {
  PpcVault({SecurePrefs? prefs}) : _prefs = prefs ?? SecurePrefs.instance;

  static const _kStoragePubkey = 'ppc.storage_pubkey';
  static const _kRouteKind = 'ppc.route_kind';
  static const _kLanHint = 'ppc.lan_hint';
  static const _kRelayUrl = 'ppc.relay_url';
  static const _kStorageNodeId = 'ppc.storage_node_id';
  static const _kPeerNodeId = 'ppc.peer_node_id';
  static const _kFingerprint = 'ppc.fingerprint';

  final SecurePrefs _prefs;

  /// Save paired state after successful `resolveAndPair`.
  Future<void> save({
    required PpcPairResult result,
    required String peerNodeId,
  }) async {
    await _prefs.write(_kStoragePubkey, result.storagePubkey);
    await _prefs.write(_kRouteKind, result.routeKind.name);
    await _prefs.write(_kPeerNodeId, peerNodeId);
    if (result.fingerprint != null) {
      await _prefs.write(_kFingerprint, result.fingerprint!);
    } else {
      await _prefs.remove(_kFingerprint);
    }
    if (result.lanHint != null) {
      await _prefs.write(_kLanHint, result.lanHint!);
    } else {
      await _prefs.remove(_kLanHint);
    }
    if (result.relayUrl != null) {
      await _prefs.write(_kRelayUrl, result.relayUrl!);
    } else {
      await _prefs.remove(_kRelayUrl);
    }
    if (result.storageNodeId != null) {
      await _prefs.write(_kStorageNodeId, result.storageNodeId!);
    } else {
      await _prefs.remove(_kStorageNodeId);
    }
  }

  /// Load persisted pairing; null when not paired.
  Future<PpcVaultState?> load() async {
    final storagePubkey = await _prefs.read(_kStoragePubkey);
    if (storagePubkey == null || storagePubkey.isEmpty) return null;

    final routeKindRaw = await _prefs.read(_kRouteKind);
    final peerNodeId = await _prefs.read(_kPeerNodeId);
    if (routeKindRaw == null || peerNodeId == null) return null;

    final routeKind =
        PpcRouteKind.values.asNameMap()[routeKindRaw] ??
        (routeKindRaw == 'lan' ? PpcRouteKind.lan : PpcRouteKind.relay);

    return PpcVaultState(
      storagePubkey: storagePubkey,
      routeKind: routeKind,
      peerNodeId: peerNodeId,
      lanHint: await _prefs.read(_kLanHint),
      relayUrl: await _prefs.read(_kRelayUrl),
      storageNodeId: await _prefs.read(_kStorageNodeId),
      fingerprint: await _prefs.read(_kFingerprint),
    );
  }

  Future<bool> isPaired() async {
    final pubkey = await _prefs.read(_kStoragePubkey);
    return pubkey != null && pubkey.isNotEmpty;
  }

  Future<void> clear() async {
    await _prefs.clearKeys([
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
