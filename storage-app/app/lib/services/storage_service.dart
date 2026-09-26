// Управление жизненным циклом StorageApp из Flutter UI.
library;

import 'dart:io';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app.dart';
import '../models/models.dart';
import '../net/discovery_register.dart';
import '../pairing/pairing.dart';
import '../pairing/payload.dart';
import 'app_settings.dart';

enum StorageUiPhase { loading, onboarding, ready, error }

class StorageService extends ChangeNotifier {
  StorageUiPhase phase = StorageUiPhase.loading;
  String? errorMessage;

  AppSettings settings = const AppSettings();
  StorageApp? app;
  PairCode? activePairCode;
  bool serverRunning = false;

  Future<void> init() async {
    try {
      settings = await AppSettings.load();
      if (!settings.isConfigured) {
        phase = StorageUiPhase.onboarding;
        notifyListeners();
        return;
      }
      await _bootstrapAndStart(settings.allowedRoot!, settings.port);
      phase = StorageUiPhase.ready;
    } catch (e) {
      phase = StorageUiPhase.error;
      errorMessage = '$e';
    }
    notifyListeners();
  }

  Future<String> defaultStoragePath() async {
    final dir = await getApplicationSupportDirectory();
    return p.join(dir.path, 'storage-app', 'data');
  }

  Future<void> completeOnboarding(String allowedRoot, {int port = 7345}) async {
    phase = StorageUiPhase.loading;
    errorMessage = null;
    notifyListeners();

    try {
      await Directory(allowedRoot).create(recursive: true);
      await AppSettings().save(allowedRoot: allowedRoot, port: port);
      settings = await AppSettings.load();
      await _bootstrapAndStart(allowedRoot, port);
      phase = StorageUiPhase.ready;
    } catch (e) {
      phase = StorageUiPhase.error;
      errorMessage = '$e';
    }
    notifyListeners();
  }

  Future<void> _bootstrapAndStart(String allowedRoot, int port) async {
    if (app != null) {
      await app!.shutdown();
      app = null;
      serverRunning = false;
    }
    final config = StorageConfig(allowedRoot: allowedRoot, port: port);
    app = await StorageApp.bootstrap(config);
    app!.pairing.configurePin(
      hash: settings.pinHash,
      salt: settings.pinSalt,
      enabled: settings.pinEnabled,
    );
    app!.pairing.allowOpen = settings.openPairing;
    await app!.start();
    serverRunning = true;
    activePairCode = null;
  }

  Future<void> toggleServer() async {
    if (app == null) return;
    if (serverRunning) {
      await stopServer();
    } else {
      await app!.start();
      serverRunning = true;
    }
    notifyListeners();
  }

  /// Отозвать пир. [deleteBlobs] — удалить его папку на диске (PAIRING.md).
  Future<void> revokePeer(String userUuid, {bool deleteBlobs = false}) async {
    if (app == null) return;
    app!.metaDb.revokePeer(userUuid);
    if (deleteBlobs) {
      app!.metaDb.deleteUserBlobs(userUuid);
      await app!.blobStore.deleteUserData(userUuid);
    }
    app!.metaDb.appendAudit(
      ts: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      op: 'REVOKE',
      userUuid: userUuid,
      result: 'ok',
      detail: deleteBlobs ? 'ui+wipe' : 'ui',
    );
    notifyListeners();
  }

  List<AuditEntry> listAudit({int limit = 200}) =>
      app?.metaDb.listAudit(limit: limit) ?? [];

  List<StoredBlobMetadata> listStoredBlobs({int limit = 500}) =>
      app?.metaDb.listBlobs(limit: limit) ?? [];

  bool get mdnsActive => app?.mdnsActive ?? false;
  bool get relayActive => app?.relayActive ?? false;
  bool get discoveryActive => app?.discoveryActive ?? false;

  int? peerLastAccess(String userUuid) => app?.metaDb.peerLastAccess(userUuid);

  /// Сменить порт (перезапуск сервера).
  Future<void> updatePort(int port) async {
    if (port < 1024 || port > 65535) {
      throw ArgumentError('port out of range');
    }
    final root = allowedRoot;
    if (root == null) return;
    await AppSettings().updatePort(port);
    settings = await AppSettings.load();
    await _bootstrapAndStart(root, port);
    notifyListeners();
  }

  /// Сменить папку хранения (новый bootstrap; старые данные остаются на месте).
  Future<void> updateStoragePath(String newRoot) async {
    await Directory(newRoot).create(recursive: true);
    final port = settings.port;
    await AppSettings().save(allowedRoot: newRoot, port: port);
    settings = await AppSettings.load();
    await _bootstrapAndStart(newRoot, port);
    notifyListeners();
  }

  Future<void> setMinimizeToTray(bool value) async {
    await AppSettings().setMinimizeToTray(value);
    settings = await AppSettings.load();
    notifyListeners();
  }

  Future<void> setPairingPin(String pin) async {
    if (!RegExp(r'^\d{8,12}$').hasMatch(pin)) {
      throw ArgumentError('PIN должен содержать 8–12 цифр');
    }
    final rng = Random.secure();
    final salt = base64UrlEncode(
      List<int>.generate(24, (_) => rng.nextInt(256)),
    );
    final hash = PairingManager.derivePinHash(salt, pin);
    await AppSettings().setPairingPin(hash: hash, salt: salt);
    settings = await AppSettings.load();
    app?.pairing.configurePin(hash: hash, salt: salt, enabled: true);
    if (app != null) app!.pairing.allowOpen = false;
    notifyListeners();
  }

  Future<void> disablePairingPin() async {
    await AppSettings().disablePairingPin();
    settings = await AppSettings.load();
    app?.pairing.configurePin(enabled: false);
    notifyListeners();
  }

  Future<void> setOpenPairing(bool value) async {
    await AppSettings().setOpenPairing(value);
    settings = await AppSettings.load();
    if (app != null) {
      app!.pairing.allowOpen = value;
      if (value) app!.pairing.configurePin(enabled: false);
    }
    notifyListeners();
  }

  /// Сброс онбординга (данные на диске не удаляются).
  Future<void> resetOnboarding() async {
    await stopServer();
    if (app != null) {
      await app!.shutdown();
      app = null;
    }
    await AppSettings().clear();
    settings = const AppSettings();
    phase = StorageUiPhase.onboarding;
    notifyListeners();
  }

  String? pairingPayloadJson(
    List<String> lanHosts, {
    bool includeQrSecret = true,
  }) {
    final code = activePairCode;
    if (code == null) return null;
    return PairingPayload.encode(
      code: code.code,
      qrSecret: code.qrSecret,
      storagePubkey: storagePubkey ?? '',
      fingerprint: fingerprint ?? '',
      port: listenPort,
      lanHosts: lanHosts,
      expiresAt: code.expiresAt,
      mdns: app?.mdnsActive ?? false,
      relay: PpcRelayEnvConfig.fromPlatform()?.relayReach,
      includeQrSecret: includeQrSecret,
    );
  }

  Future<void> stopServer() async {
    if (app != null && serverRunning) {
      await app!.stopListening();
      serverRunning = false;
      activePairCode = null;
    }
  }

  PairCode issuePairingCode() {
    final code = app!.pairing.issueCode();
    activePairCode = code;
    notifyListeners();
    return code;
  }

  void clearExpiredPairCode() {
    final code = activePairCode;
    if (code == null) return;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (code.expiresAt <= now) {
      activePairCode = null;
      notifyListeners();
    }
  }

  List<Peer> listPeers() => app?.metaDb.listPeers() ?? [];

  List<PendingPairRequest> get pendingPairRequests =>
      app?.pairing.pendingRequests ?? const [];

  void approvePairRequest(String requestId) {
    app?.pairing.approve(requestId);
    notifyListeners();
  }

  void denyPairRequest(String requestId) {
    app?.pairing.deny(requestId);
    notifyListeners();
  }

  ({int bytes, int files}) globalUsage() =>
      app?.metaDb.globalUsage() ?? (bytes: 0, files: 0);

  ({int bytes, int files}) peerUsage(String userUuid) =>
      app?.metaDb.userUsage(userUuid) ?? (bytes: 0, files: 0);

  int get listenPort => app?.server.port ?? settings.port;

  String? get allowedRoot => app?.config.allowedRoot ?? settings.allowedRoot;

  String? get storagePubkey => app?.keys.publicKeyString;

  String? get fingerprint => app?.keys.fingerprint;

  Future<List<String>> localAddresses() async {
    final addrs = <String>[];
    for (final iface in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLinkLocal: false,
    )) {
      for (final addr in iface.addresses) {
        if (!addr.isLoopback) addrs.add(addr.address);
      }
    }
    return addrs;
  }

  /// Await this before calling exit() so meta.db gets encrypted properly.
  Future<void> shutdownGracefully() async {
    if (app != null) {
      await app!.shutdown();
      app = null;
    }
  }

  @override
  void dispose() {
    // For normal Flutter widget disposal (not app exit). The graceful exit
    // path uses shutdownGracefully() + exit(0) instead.
    // ignore: discarded_futures
    app?.shutdown();
    super.dispose();
  }
}
