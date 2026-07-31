import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../config.dart';
import '../../core/extensions/context_extensions.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/ui/app_badge.dart';
import '../../core/ui/app_button.dart';
import '../../core/ui/app_card.dart';
import '../../core/ui/app_section.dart';
import '../../core/ui/app_tile.dart';
import '../../models/connection_probe_result.dart';
import '../../services/debug_log.dart';
import '../../services/node_config_resolver.dart';
import '../../services/settings_runtime.dart';
import '../../state/app_controller.dart';
import '../../utils/format.dart';

/// Infrastructure connectivity — nodes, WebSocket, last sync.
class ConnectionStatusScreen extends ConsumerStatefulWidget {
  const ConnectionStatusScreen({super.key});

  @override
  ConsumerState<ConnectionStatusScreen> createState() => _ConnectionStatusScreenState();
}

class _ConnectionStatusScreenState extends ConsumerState<ConnectionStatusScreen> {
  ConnectionStatusSnapshot? _snapshot;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _probe();
  }

  Future<void> _probe() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snapshot = await ref.read(appControllerProvider).probeConnectionStatus();
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _reconnect() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(appControllerProvider).reconnectConnection();
      await _probe();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;
    final controller = ref.watch(appControllerProvider);
    final snapshot = _snapshot;
    final online = controller.websocketConnected &&
        (snapshot?.clientReachable ?? false);

    return Scaffold(
      appBar: AppBar(title: const Text('Состояние соединения')),
      body: RefreshIndicator(
        onRefresh: _probe,
        child: ListView(
          padding: const EdgeInsets.only(bottom: AppSpacing.xl),
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpacing.screenPadding),
              child: AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Сеть и узлы', style: text.title),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      'Проверка Gateway, Home, Discovery, Media и Relay (через Discovery)',
                      style: text.caption,
                    ),
                    if (snapshot != null) ...[
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        'Обновлено: ${formatCallHistoryTime(snapshot.probedAt)}',
                        style: text.micro.copyWith(color: colors.textMuted),
                      ),
                    ],
                    const SizedBox(height: AppSpacing.md),
                    Row(
                      children: [
                        StatusDot(
                          status: online ? AppStatus.online : AppStatus.warning,
                          diameter: 10,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          online ? 'Сеть доступна' : 'Ограниченная связность',
                          style: text.subtitle,
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.md),
                    AppButton(
                      label: _loading ? 'Проверка…' : 'Проверить узлы',
                      onPressed: _loading ? null : _probe,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    AppButton(
                      label: 'Переподключить WebSocket',
                      variant: AppButtonVariant.secondary,
                      onPressed: _loading ? null : _reconnect,
                    ),
                  ],
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
                child: Text(_error!, style: text.caption.copyWith(color: colors.danger)),
              ),
            AppSection(
              title: 'Клиент',
              child: AppSettingsGroup(
                children: [
                  _LiveRow(
                    label: 'Статус',
                    value: controller.session == null ? 'Не в сети' : (controller.websocketConnected ? 'Online' : 'Offline'),
                    status: controller.session != null && controller.websocketConnected
                        ? AppStatus.online
                        : AppStatus.offline,
                  ),
                  _LiveRow(
                    label: 'Home Node',
                    value: AppConfig.homeNodeUrl,
                    status: snapshot?.endpoints.any((e) => e.id == 'home' && e.reachable) == true
                        ? AppStatus.online
                        : AppStatus.warning,
                    subtitle: 'Текущий API endpoint',
                  ),
                  Builder(builder: (context) {
                    final backups = NodeConfigResolver().backupHomeUrls();
                    return _LiveRow(
                      label: 'Запасные Home-узлы',
                      value: backups.isEmpty ? 'нет' : '${backups.length}',
                      status: backups.isEmpty ? AppStatus.warning : AppStatus.online,
                      subtitle: backups.isEmpty
                          ? 'Re-bootstrap упадёт на дефолт, если primary Gateway/Home down'
                          : backups.join(', '),
                    );
                  }),
                  if (controller.lastFailoverAt != null)
                    _LiveRow(
                      label: 'Failover',
                      value: formatCallHistoryTime(controller.lastFailoverAt!),
                      status: AppStatus.warning,
                      subtitle: 'Переключились с ${controller.lastFailoverFromUrl} '
                          'на ${controller.lastFailoverToUrl}',
                    ),
                  if (controller.lastHomeChangedEntry != null)
                    _LiveRow(
                      label: 'Home контакта сменился',
                      value: formatCallHistoryTime(
                        controller.lastHomeChangedEntry!.updatedAt ??
                            controller.lastHomeChangedEntry!.cachedAt,
                      ),
                      status: AppStatus.warning,
                      subtitle: '${controller.lastHomeChangedUserId} → '
                          '${controller.lastHomeChangedEntry!.homeUrl}',
                    ),
                  FutureBuilder<String>(
                    future: NodeConfigResolver().connectionSummary(),
                    builder: (context, snap) {
                      final summary = snap.data;
                      final proxyOn = summary != null && summary.contains('прокси');
                      return _LiveRow(
                        label: 'Каталог ноды',
                        value: summary ?? '…',
                        status: proxyOn ? AppStatus.warning : AppStatus.online,
                        subtitle: 'fallback / service nodes / fingerprint',
                      );
                    },
                  ),
                  FutureBuilder<String>(
                    future: SettingsRuntime.instance.nodeCertificateFingerprint(),
                    builder: (context, snap) => _LiveRow(
                      label: 'Certificate fingerprint',
                      value: snap.data ?? '…',
                      status: AppStatus.online,
                      subtitle: 'node.certificate_fingerprint',
                    ),
                  ),
                  FutureBuilder<(bool, bool, bool)>(
                    future: () async {
                      final r = SettingsRuntime.instance;
                      return (
                        await r.nodeAllowFallback(),
                        await r.nodeAllowServiceNodes(),
                        await r.nodeRoaming(),
                      );
                    }(),
                    builder: (context, snap) {
                      final v = snap.data;
                      return _LiveRow(
                        label: 'Fallback / service / roaming',
                        value: v == null
                            ? '…'
                            : '${v.$1 ? 'fallback' : 'no-fallback'} · '
                                '${v.$2 ? 'service' : 'no-service'} · '
                                '${v.$3 ? 'roaming' : 'no-roaming'}',
                        status: AppStatus.online,
                      );
                    },
                  ),
                  _LiveRow(
                    label: 'WebSocket',
                    value: controller.websocketConnected ? 'Подключён' : 'Отключён',
                    status: controller.websocketConnected ? AppStatus.online : AppStatus.offline,
                    subtitle: AppConfig.wsUrl,
                  ),
                  _LiveRow(
                    label: 'Синхронизация чатов',
                    value: controller.lastConversationSyncAt == null
                        ? 'Ещё не было'
                        : formatSyncTime(controller.lastConversationSyncAt!),
                    status: controller.lastConversationSyncAt != null ? AppStatus.online : AppStatus.warning,
                    subtitle: 'Последний запрос списка диалогов',
                  ),
                  _LiveRow(
                    label: 'Очередь отправки',
                    value: controller.failedOutboundCount > 0
                        ? '${controller.failedOutboundCount} ошибок'
                        : controller.scheduledMessageCount > 0
                            ? '${controller.scheduledMessageCount} отложено'
                            : 'Пусто',
                    status: controller.failedOutboundCount > 0 ? AppStatus.error : AppStatus.online,
                    subtitle: 'Локально на устройстве',
                    showDivider: false,
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            AppSection(
              title: 'Узлы',
              subtitle: 'Пинг /health',
              child: _loading && snapshot == null
                  ? const Padding(
                      padding: EdgeInsets.all(AppSpacing.xl),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : AppSettingsGroup(
                      children: [
                        if (snapshot != null)
                          for (var i = 0; i < snapshot.endpoints.length; i++)
                            _EndpointRow(
                              result: snapshot.endpoints[i],
                              showDivider: i < snapshot.endpoints.length - 1,
                            ),
                      ],
                    ),
            ),
            if (snapshot != null && !snapshot.clientReachable)
              Padding(
                padding: const EdgeInsets.all(AppSpacing.screenPadding),
                child: AppCard(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline, color: colors.warning, size: 20),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          'Некоторые клиентские узлы недоступны. Сообщения могут не отправляться, пока Home Node или WebSocket offline.',
                          style: text.caption,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (DebugLog.instance.lastError != null)
              Padding(
                padding: const EdgeInsets.all(AppSpacing.screenPadding),
                child: AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Последняя ошибка (dev)', style: text.caption.copyWith(color: colors.danger)),
                      const SizedBox(height: AppSpacing.sm),
                      Text(DebugLog.instance.lastError!, style: text.micro),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _LiveRow extends StatelessWidget {
  const _LiveRow({
    required this.label,
    required this.value,
    required this.status,
    this.subtitle,
    this.showDivider = true,
  });

  final String label;
  final String value;
  final AppStatus status;
  final String? subtitle;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    return AppTile(
      title: label,
      subtitle: subtitle,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusDot(status: status, diameter: 8),
          const SizedBox(width: 8),
          Text(value, style: context.textStyles.caption),
        ],
      ),
      showDivider: showDivider,
    );
  }
}

class _EndpointRow extends StatelessWidget {
  const _EndpointRow({required this.result, this.showDivider = true});

  final ConnectionProbeResult result;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final text = context.textStyles;
    final status = result.reachable ? AppStatus.online : AppStatus.error;
    final role = result.nodeRole;

    return AppTile(
      title: result.label,
      subtitle: '${result.url}${role != null ? ' · $role' : ''}',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusDot(status: status, diameter: 8),
          const SizedBox(width: 8),
          Text(result.statusLabel, style: text.caption),
        ],
      ),
      showDivider: showDivider,
    );
  }
}
