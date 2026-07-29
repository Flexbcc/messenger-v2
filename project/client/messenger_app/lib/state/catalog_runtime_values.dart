import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config.dart';
import '../services/bootstrap_service.dart';
import '../services/node_config_resolver.dart';
import '../services/settings_runtime.dart';
import 'app_controller.dart';

/// Live read-only values for catalog settings that reflect current app state.
class CatalogRuntimeValues {
  const CatalogRuntimeValues({
    this.publicId = '',
    this.displayName = '',
    this.deviceLabel = '',
    this.nodeLabel = '',
    this.protocolVersion = '1.0.0',
    this.storageSummary = '',
    this.bio = '',
    this.username = '',
    this.phoneVerified = '—',
    this.emailVerified = '—',
    this.proxyStatus = '—',
    this.certificateFingerprint = '—',
    this.pinAttemptPolicy = '—',
    this.lastSync = '—',
    this.lastBackup = '—',
  });

  final String publicId;
  final String displayName;
  final String deviceLabel;
  final String nodeLabel;
  final String protocolVersion;
  final String storageSummary;
  final String bio;
  final String username;
  final String phoneVerified;
  final String emailVerified;
  final String proxyStatus;
  final String certificateFingerprint;
  final String pinAttemptPolicy;
  final String lastSync;
  final String lastBackup;

  String? valueFor(String settingId) => switch (settingId) {
        'profile.public_id' => publicId.isEmpty ? null : publicId,
        'profile.display_name' => displayName.isEmpty ? null : displayName,
        'profile.username' => username.isEmpty ? null : username,
        'profile.bio' => bio.isEmpty ? null : bio,
        'identity.phone_verified' => phoneVerified,
        'identity.email_verified' => emailVerified,
        'devices.current' => deviceLabel.isEmpty ? null : deviceLabel,
        'node.current' => nodeLabel.isEmpty ? null : nodeLabel,
        'node.certificate_fingerprint' => certificateFingerprint,
        'security.pin_attempt_policy' => pinAttemptPolicy,
        'storage.summary' => storageSummary.isEmpty ? 'Локально' : storageSummary,
        'storage.last_sync' => lastSync,
        'storage.last_backup' => lastBackup,
        'developer.protocol_version' => protocolVersion,
        _ => null,
      };
}

final catalogRuntimeValuesProvider = FutureProvider<CatalogRuntimeValues>((ref) async {
  final app = ref.watch(appControllerProvider);
  final session = app.session;
  final runtime = SettingsRuntime.instance;
  final bootstrap = BootstrapStore.current;
  final storageSummary = await runtime.storageSummaryLabel();
  final customNode = await runtime.nodeCustomEnabled();
  final mode = await runtime.nodeMode();
  final nodeAddr = customNode
      ? await runtime.nodeCustomAddress()
      : (bootstrap?.homeUrl ?? AppConfig.homeNodeUrl);
  final nodeLabel = nodeAddr.isEmpty ? mode : '$mode · $nodeAddr';
  final proxy = await NodeConfigResolver().connectionSummary();
  final phoneOk = await runtime.phoneVerified();
  final emailOk = await runtime.emailVerified();
  final fp = await runtime.nodeCertificateFingerprint();
  final pinPolicy = await runtime.pinAttemptPolicyLabel();
  final lastSync = await runtime.storageLastSyncIso() ??
      (app.lastConversationSyncAt?.toIso8601String() ?? '—');
  final lastBackup = await runtime.storageLastBackupIso() ?? '—';
  return CatalogRuntimeValues(
    publicId: session?.userId ?? '',
    displayName: session?.displayName ?? await runtime.displayName(),
    deviceLabel: session?.deviceId ?? '',
    nodeLabel: nodeLabel,
    protocolVersion: '${AppInfo.version}+${AppInfo.buildNumber}',
    storageSummary: storageSummary,
    bio: await runtime.bio(),
    username: await runtime.username(),
    phoneVerified: phoneOk ? 'да' : 'нет',
    emailVerified: emailOk ? 'да' : 'нет',
    proxyStatus: proxy,
    certificateFingerprint: fp,
    pinAttemptPolicy: pinPolicy,
    lastSync: lastSync,
    lastBackup: lastBackup,
  );
});
