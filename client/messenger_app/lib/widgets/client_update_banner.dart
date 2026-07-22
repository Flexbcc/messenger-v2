import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/client_update_service.dart';

/// Floating top banner when a newer client build is available.
class ClientUpdateBannerHost extends StatefulWidget {
  const ClientUpdateBannerHost({super.key, required this.child});

  final Widget child;

  @override
  State<ClientUpdateBannerHost> createState() => _ClientUpdateBannerHostState();
}

class _ClientUpdateBannerHostState extends State<ClientUpdateBannerHost> {
  final _updates = ClientUpdateService.instance;

  @override
  void initState() {
    super.initState();
    _updates.addListener(_onUpdate);
    _updates.start();
  }

  @override
  void dispose() {
    _updates.removeListener(_onUpdate);
    super.dispose();
  }

  void _onUpdate() => setState(() {});

  @override
  Widget build(BuildContext context) {
    // Force-upgrade gate: block entire UI if running version is below min_version
    if (_updates.forceUpgrade) {
      return _ForceUpgradeScreen(updates: _updates);
    }

    final msg = _updates.bannerMessage;
    final show = _updates.hasUpdate && msg != null;
    final isReload = _updates.pwaReloadReady || _updates.updateKind == 'reload';

    return Stack(
      children: [
        widget.child,
        if (show)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Material(
              elevation: 4,
              color: Theme.of(context).colorScheme.primaryContainer,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.system_update_alt,
                        size: 20,
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              msg,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: Theme.of(context).colorScheme.onPrimaryContainer,
                              ),
                            ),
                            if (_updates.releaseNotes != null &&
                                _updates.releaseNotes!.isNotEmpty)
                              Text(
                                _updates.releaseNotes!,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onPrimaryContainer
                                      .withValues(alpha: 0.85),
                                ),
                              ),
                          ],
                        ),
                      ),
                      TextButton(
                        onPressed: () => _updates.applyUpdate(),
                        child: Text(isReload ? 'Перезагрузить' : 'Скачать'),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Скрыть',
                        onPressed: _updates.dismissForSession,
                        icon: Icon(
                          Icons.close,
                          size: 18,
                          color: Theme.of(context).colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Full-screen blocker shown when the running version is below min_version.
/// The user cannot dismiss it — they must update the app.
class _ForceUpgradeScreen extends StatelessWidget {
  const _ForceUpgradeScreen({required this.updates});

  final ClientUpdateService updates;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isReload = updates.pwaReloadReady || updates.updateKind == 'reload';

    return Scaffold(
      backgroundColor: cs.surface,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.system_update, size: 72, color: cs.primary),
                const SizedBox(height: 24),
                Text(
                  'Необходимо обновление',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  'Эта версия приложения больше не поддерживается.\n'
                  'Пожалуйста, обновитесь, чтобы продолжить.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
                if (updates.remoteVersion != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Актуальная версия: ${updates.remoteVersion}',
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                  ),
                ],
                if (updates.releaseNotes != null && updates.releaseNotes!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    updates.releaseNotes!,
                    textAlign: TextAlign.center,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                  ),
                ],
                const SizedBox(height: 32),
                FilledButton.icon(
                  onPressed: () => _doUpdate(updates),
                  icon: const Icon(Icons.download),
                  label: Text(isReload ? 'Перезагрузить' : 'Скачать обновление'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _doUpdate(ClientUpdateService svc) async {
    if (svc.pwaReloadReady || svc.updateKind == 'reload') {
      await svc.applyUpdate();
      return;
    }
    final url = svc.downloadUrl;
    if (url != null && url.isNotEmpty) {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    }
  }
}
