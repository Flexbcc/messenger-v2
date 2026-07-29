import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../models/client_release_manifest.dart';
import 'pwa_update_bridge.dart';

/// Checks gateway release manifest and (on web) PWA service worker updates.
class ClientUpdateService extends ChangeNotifier {
  ClientUpdateService._();
  static final instance = ClientUpdateService._();

  bool _started = false;
  bool _checking = false;

  bool pwaReloadReady = false;
  bool manifestUpdateAvailable = false;
  String? releaseNotes;
  String? downloadUrl;
  String? remoteVersion;
  int? remoteBuild;
  String updateKind = 'download';
  String? lastError;

  bool get hasUpdate => pwaReloadReady || manifestUpdateAvailable;

  String? get bannerMessage {
    if (pwaReloadReady) {
      return 'Доступна новая версия веб-клиента';
    }
    if (manifestUpdateAvailable && remoteVersion != null) {
      return 'Доступна версия $remoteVersion (${AppInfo.channel})';
    }
    return null;
  }

  void start() {
    if (_started) return;
    _started = true;

    if (kIsWeb) {
      PwaUpdateBridge.instance.start(() {
        pwaReloadReady = true;
        notifyListeners();
      });
    }

    unawaited(checkForUpdates());
    Timer.periodic(const Duration(hours: 6), (_) => checkForUpdates());
  }

  Future<void> checkForUpdates() async {
    if (_checking) return;
    _checking = true;
    try {
      lastError = null;
      final uri = Uri.parse('${AppConfig.gatewayNodeUrl}/releases/clients/manifest.json');
      final res = await http.get(uri).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) {
        lastError = 'manifest ${res.statusCode}';
        return;
      }
      final manifest = ClientReleaseManifest.fromJson(
        jsonDecode(res.body) as Map<String, dynamic>,
      );
      final platform = _currentPlatformKey();
      final plat = manifest.messenger.forPlatform(platform);
      if (plat == null || !plat.available) {
        manifestUpdateAvailable = false;
        notifyListeners();
        return;
      }

      remoteVersion = plat.version;
      remoteBuild = plat.build;
      releaseNotes = manifest.messenger.releaseNotes;
      downloadUrl = plat.downloadUrl;
      updateKind = plat.updateKind;

      manifestUpdateAvailable = isRemoteNewer(
        localVersion: AppInfo.version,
        localBuild: int.tryParse(AppInfo.buildNumber) ?? 0,
        remoteVersion: plat.version,
        remoteBuild: plat.build,
      );
      notifyListeners();
    } catch (e) {
      lastError = e.toString();
    } finally {
      _checking = false;
    }
  }

  Future<void> applyUpdate() async {
    if (pwaReloadReady || (kIsWeb && updateKind == 'reload')) {
      await PwaUpdateBridge.instance.applyReload();
      return;
    }
    final url = downloadUrl;
    if (url != null && url.isNotEmpty) {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    }
  }

  void dismissForSession() {
    pwaReloadReady = false;
    manifestUpdateAvailable = false;
    notifyListeners();
  }

  String _currentPlatformKey() {
    if (kIsWeb) return 'web';
    try {
      if (Platform.isMacOS) return 'macos';
      if (Platform.isWindows) return 'windows';
      if (Platform.isLinux) return 'linux';
      if (Platform.isAndroid) return 'android';
      if (Platform.isIOS) return 'ios';
    } catch (_) {}
    return 'web';
  }
}
