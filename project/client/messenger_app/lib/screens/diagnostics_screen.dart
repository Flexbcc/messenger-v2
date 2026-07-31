import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../config.dart';
import '../../core/extensions/context_extensions.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/ui/app_button.dart';
import '../../core/ui/app_card.dart';
import '../../core/ui/app_section.dart';
import '../../core/ui/app_tile.dart';
import '../../services/catalog_seed_service.dart';
import '../../services/database_init.dart';
import '../../services/debug_log.dart';
import '../../state/app_controller.dart';
import '../../state/settings_catalog_controller.dart';
import '../../utils/format.dart';
import 'settings_catalog_json_screen.dart';

/// Developer diagnostics — local runtime state for distributed-network debugging.
class DiagnosticsScreen extends ConsumerWidget {
  const DiagnosticsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final text = context.textStyles;
    final controller = ref.watch(appControllerProvider);
    final session = controller.session;
    final lastErr = DebugLog.instance.lastError;

    final rows = <(String, String)>[
      ('Версия', AppInfo.displayVersion),
      ('Home Node', AppConfig.homeNodeUrl),
      ('Gateway', AppConfig.gatewayNodeUrl),
      ('Discovery', AppConfig.discoveryNodeUrl),
      ('Media', AppConfig.mediaNodeUrl),
      ('Relay', 'federation · через Discovery (порт 8005 не для клиента)'),
      ('WebSocket', AppConfig.wsUrl),
      ('WS состояние', controller.websocketConnected ? 'connected' : 'disconnected'),
      ('User ID', session?.userId ?? '—'),
      ('Device ID', session?.deviceId ?? '—'),
      ('Crypto store', controller.crypto != null ? 'loaded' : 'missing'),
      ('Auth keypair', controller.authKeyPair != null ? 'loaded' : 'missing'),
      ('Local DB', DatabaseInit.isInitialized ? 'ready' : 'not initialized'),
      ('Last sync', controller.lastConversationSyncAt == null
          ? '—'
          : formatCallHistoryTime(controller.lastConversationSyncAt!)),
      ('Failed outbound', '${controller.failedOutboundCount}'),
      ('Scheduled queue', '${controller.scheduledMessageCount}'),
      ('Last error', lastErr ?? '—'),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Диагностика'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Копировать',
            onPressed: () {
              final buf = StringBuffer('Messenger diagnostics\n');
              for (final row in rows) {
                buf.writeln('${row.$1}: ${row.$2}');
              }
              Clipboard.setData(ClipboardData(text: buf.toString()));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Скопировано')),
              );
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            child: AppCard(
              child: Text(
                'Только локальные данные клиента. TLS/mTLS и server-side E2EE здесь не проверяются.',
                style: text.caption,
              ),
            ),
          ),
          AppSection(
            title: 'Runtime',
            child: AppSettingsGroup(
              children: [
                for (var i = 0; i < rows.length; i++)
                  AppTile(
                    title: rows[i].$1,
                    trailingText: rows[i].$2,
                    showDivider: i < rows.length - 1,
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            child: AppButton(
              label: 'Переподключить WebSocket',
              variant: AppButtonVariant.secondary,
              icon: Icons.refresh,
              onPressed: () async {
                await controller.reconnectConnection();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Переподключение выполнено')),
                  );
                }
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
            child: AppButton(
              label: 'JSON настроек / тестовый seed',
              variant: AppButtonVariant.secondary,
              icon: Icons.data_object,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsCatalogJsonScreen()),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
            child: AppButton(
              label: 'Заполнить настройки тестовыми данными',
              variant: AppButtonVariant.secondary,
              icon: Icons.science_outlined,
              onPressed: () async {
                final catalog = await ref.read(settingsCatalogProvider.future);
                final n = await CatalogSeedService().applyDevSeedAsset(catalog);
                await ref.read(settingsCatalogValuesProvider).reloadFromLegacy(catalog);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Применено $n значений')),
                  );
                }
              },
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
            child: Text(
              'Подробный лог API/crypto: Настройки → Журнал отладки',
              style: text.micro.copyWith(color: colors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}
