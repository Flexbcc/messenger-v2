import 'package:flutter/material.dart';

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
    _updates.stop();
    super.dispose();
  }

  void _onUpdate() => setState(() {});

  @override
  Widget build(BuildContext context) {
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
            child: SizedBox(
              width: double.infinity,
              child: Material(
                elevation: 4,
                color: Theme.of(context).colorScheme.primaryContainer,
                child: SafeArea(
                  bottom: false,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final compact = constraints.maxWidth < 560;
                      final message = Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.system_update_alt,
                            size: 20,
                            color: Theme.of(
                              context,
                            ).colorScheme.onPrimaryContainer,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  msg,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onPrimaryContainer,
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
                        ],
                      );
                      final actions = Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton(
                            onPressed: () => _updates.applyUpdate(),
                            child: Text(isReload ? 'Обновить' : 'Скачать'),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: 'Скрыть',
                            onPressed: _updates.dismissForSession,
                            icon: Icon(
                              Icons.close,
                              size: 18,
                              color: Theme.of(
                                context,
                              ).colorScheme.onPrimaryContainer,
                            ),
                          ),
                        ],
                      );
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        child: compact
                            ? Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  message,
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: actions,
                                  ),
                                ],
                              )
                            : Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Expanded(child: message),
                                  const SizedBox(width: 12),
                                  actions,
                                ],
                              ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
