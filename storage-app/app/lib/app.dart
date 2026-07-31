// storage-app :: app
// Сборка ПК-сервера из компонентов (используется main.dart и тестами).
library;

import 'dart:async';
import 'dart:io';

import 'models/models.dart';
import 'net/discovery_register.dart';
import 'net/mdns_advertiser.dart';
import 'net/relay_agent.dart';
import 'pairing/keys.dart';
import 'pairing/pairing.dart';
import 'storage/blob_gc.dart';
import 'storage/blob_store.dart';
import 'storage/meta_db.dart';
import 'storage/secure_key_store.dart';
import 'transport/server.dart';

/// Собранный сервер + его зависимости (для управления жизненным циклом).
class StorageApp {
  final StorageConfig config;
  final StorageKeys keys;
  final MetaDb metaDb;
  final BlobStore blobStore;
  final PairingManager pairing;
  final PpcServer server;
  final PpcMdnsAdvertiser mdns;
  final PpcRelayEnvConfig? relayEnv;
  PpcDiscoveryRegister? discovery;
  PpcRelayAgent? relayAgent;
  BlobGcRunner? gcRunner;
  Timer? _gcTimer;
  bool mdnsActive = false;
  bool relayActive = false;
  bool discoveryActive = false;

  StorageApp._({
    required this.config,
    required this.keys,
    required this.metaDb,
    required this.blobStore,
    required this.pairing,
    required this.server,
    required this.mdns,
    this.relayEnv,
    this.gcRunner,
  });

  static Future<StorageApp> bootstrap(StorageConfig config) async {
    await SecureKeyStore.ensureInitialized();
    final keys = await StorageKeys.loadOrCreate(config.allowedRoot);
    final metaDb = await MetaDb.open(config.allowedRoot);
    final blobStore = BlobStore(config.allowedRoot);
    final pairing = PairingManager(
      db: metaDb,
      storagePubkey: keys.publicKeyString,
    );
    final server = PpcServer(
      config: config,
      keys: keys,
      metaDb: metaDb,
      blobStore: blobStore,
      pairing: pairing,
    );
    final ttlDays =
        int.tryParse(Platform.environment['PPC_GC_TTL_DAYS'] ?? '') ?? 0;
    final gcRunner = BlobGcRunner(
      metaDb: metaDb,
      blobStore: blobStore,
      ttlDays: ttlDays,
    );
    return StorageApp._(
      config: config,
      keys: keys,
      metaDb: metaDb,
      blobStore: blobStore,
      pairing: pairing,
      server: server,
      mdns: PpcMdnsAdvertiser(),
      relayEnv: PpcRelayEnvConfig.fromPlatform(),
      gcRunner: gcRunner,
    );
  }

  Future<void> start() async {
    await server.start();
    _startGcScheduler();
    try {
      await mdns.start(
        port: server.port,
        fingerprint: keys.fingerprint,
        storagePubkey: keys.publicKeyString,
      );
      mdnsActive = true;
    } catch (_) {
      mdnsActive = false;
    }

    final env = relayEnv;
    if (env != null) {
      relayAgent = PpcRelayAgent(
        relayUrl: env.relayUrl,
        storageNodeId: env.storageNodeId.isNotEmpty
            ? env.storageNodeId
            : keys.fingerprint,
        storagePubkey: keys.publicKeyString,
        localPort: server.port,
        keys: keys,
      );
      try {
        await relayAgent!.start();
        relayActive = true;
      } catch (_) {
        relayActive = false;
      }

      if (env.isComplete) {
        discovery = PpcDiscoveryRegister(
          discoveryUrl: env.discoveryUrl,
          nodeId: env.storageNodeId,
          nodeUrl: env.relayUrl,
        );
        try {
          await discovery!.start();
          discoveryActive = true;
        } catch (_) {
          discoveryActive = false;
        }
      }
    }
  }

  void _startGcScheduler() {
    final runner = gcRunner;
    if (runner == null) return;

    if (Platform.environment['PPC_GC_ON_START'] == '1') {
      unawaited(runner.runOnce());
    }

    final hours =
        int.tryParse(Platform.environment['PPC_GC_INTERVAL_HOURS'] ?? '') ??
            24;
    if (hours <= 0) return;

    _gcTimer?.cancel();
    _gcTimer = Timer.periodic(Duration(hours: hours), (_) {
      unawaited(runner.runOnce());
    });
  }

  /// Остановить HTTP-сервер (meta.db остаётся открытой — можно снова start()).
  Future<void> stopListening() async {
    _gcTimer?.cancel();
    _gcTimer = null;
    mdnsActive = false;
    relayActive = false;
    discoveryActive = false;
    await mdns.stop();
    await relayAgent?.stop();
    relayAgent = null;
    await discovery?.stop();
    discovery = null;
    await server.stop();
  }

  /// Полное завершение: сервер + закрытие meta.db.
  Future<void> shutdown() async {
    await stopListening();
    await metaDb.close();
  }
}
