import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/extensions/context_extensions.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/ui/app_button.dart';
import '../../core/ui/app_card.dart';
import '../../core/ui/app_tile.dart';
import '../../models/security_snapshot.dart';
import '../../services/hidden_vault_session.dart';
import '../../services/security_snapshot_service.dart';
import '../../state/app_controller.dart';
import '../../utils/format.dart';
import '../devices_screen.dart';
import '../private_mode/private_mode_navigation.dart';
import 'connection_status_screen.dart';
import 'emergency_lock_screen.dart';
import 'login_approval_screen.dart';
import '../contacts_screen.dart';
import 'recovery_key_screen.dart';
import 'security_log_screen.dart';

/// Security center — shows **local client state only**, no absolute security claims.
class SecurityDashboardScreen extends ConsumerStatefulWidget {
  const SecurityDashboardScreen({super.key});

  @override
  ConsumerState<SecurityDashboardScreen> createState() => _SecurityDashboardScreenState();
}

class _SecurityDashboardScreenState extends ConsumerState<SecurityDashboardScreen> {
  SecuritySnapshot? _snapshot;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final controller = ref.read(appControllerProvider);
    await controller.refreshDevices();
    final snapshot = await const SecuritySnapshotService().build(
      isLoggedIn: controller.isLoggedIn,
      cryptoKeysPresent: controller.crypto != null,
      authKeysPresent: controller.authKeyPair != null,
      deviceCount: controller.devices.length,
      trustedDeviceCount: controller.trustedDeviceCount,
      websocketConnected: controller.websocketConnected,
      privateVaultUnlocked: HiddenVaultSession.instance.isUnlocked,
      secretHiddenChatCount: controller.secretHiddenChatCount,
    );
    if (!mounted) return;
    setState(() {
      _snapshot = snapshot;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;
    final snap = _snapshot;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Безопасность'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loading ? null : _load),
        ],
      ),
      body: _loading && snap == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: AppSpacing.xl),
              children: [
                if (snap != null) ...[
                  Padding(
                    padding: const EdgeInsets.all(AppSpacing.screenPadding),
                    child: AppCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                snap.recoveryLockActive ? Icons.gpp_bad_outlined : Icons.shield_outlined,
                                color: snap.recoveryLockActive ? colors.danger : colors.textSecondary,
                              ),
                              const SizedBox(width: AppSpacing.sm),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(snap.summaryTitle, style: text.title),
                                    const SizedBox(height: 4),
                                    Text(
                                      'Только локальные проверки клиента. Серверный статус E2EE/TLS не подтверждён.',
                                      style: text.caption,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: AppSpacing.lg),
                          AppButton(
                            label: 'Экстренная блокировка',
                            variant: AppButtonVariant.danger,
                            icon: Icons.lock_person_outlined,
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => const EmergencyLockScreen()),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  AppSettingsGroup(
                    title: 'Криптография и соединение',
                    children: [
                      _StatusTile(
                        icon: Icons.lock_outline,
                        label: 'E2E (локально)',
                        value: snap.e2eLabel,
                        color: snap.cryptoKeysPresent ? colors.primary : colors.warning,
                      ),
                      _StatusTile(
                        icon: Icons.vpn_key_outlined,
                        label: 'Ключи устройства',
                        value: snap.authKeysPresent ? 'Есть' : 'Нет данных',
                        color: snap.authKeysPresent ? colors.primary : colors.warning,
                      ),
                      _StatusTile(
                        icon: Icons.dns_outlined,
                        label: 'Home Node',
                        value: snap.homeNodeUrl,
                        color: colors.textSecondary,
                      ),
                      _StatusTile(
                        icon: Icons.https_outlined,
                        label: 'Защита канала',
                        value: snap.secureTransportLabel,
                        color: colors.textMuted,
                      ),
                      _StatusTile(
                        icon: Icons.wifi_tethering,
                        label: 'WebSocket',
                        value: snap.websocketConnected ? 'Подключён' : 'Отключён',
                        color: snap.websocketConnected ? colors.success : colors.warning,
                        showDivider: false,
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  AppSettingsGroup(
                    title: 'Устройства и доступ',
                    children: [
                      _StatusTile(
                        icon: Icons.devices_outlined,
                        label: 'Активные сеансы',
                        value: snap.deviceCount == 0 ? 'Нет данных' : '${snap.deviceCount}',
                        color: colors.textSecondary,
                      ),
                      _StatusTile(
                        icon: Icons.verified_user_outlined,
                        label: 'Доверенные (локально)',
                        value: '${snap.trustedDeviceCount} / ${snap.deviceCount}',
                        color: colors.warning,
                      ),
                      _StatusTile(
                        icon: Icons.phonelink_lock_outlined,
                        label: 'Подтверждение входа',
                        value: snap.loginApprovalEnabled ? 'Включено' : 'Выключено',
                        color: snap.loginApprovalEnabled ? colors.warning : colors.textMuted,
                      ),
                      _StatusTile(
                        icon: Icons.key_outlined,
                        label: 'Recovery Key',
                        value: snap.recoveryKeyLabel,
                        color: snap.recoveryLockActive ? colors.danger : colors.textMuted,
                        showDivider: false,
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  if (!snap.pinEnabled)
                    AppSettingsGroup(
                      title: 'Блокировка',
                      children: [
                        AppTile(
                          leading: Icon(Icons.pin_outlined, color: colors.textSecondary),
                          title: 'Настроить PIN',
                          subtitle: 'Дополнительные функции защиты откроются после настройки',
                          trailing: AppTile.chevron(context),
                          onTap: () => PrivateModeNavigation.openConfidentiality(context),
                          showDivider: false,
                        ),
                      ],
                    )
                  else
                    AppSettingsGroup(
                      title: 'Защищённый раздел',
                      children: [
                        _StatusTile(
                          icon: Icons.pin_outlined,
                          label: 'PIN',
                          value: 'Включён',
                          color: colors.primary,
                        ),
                        _StatusTile(
                          icon: Icons.lock_outline,
                          label: 'Хранилище',
                          value: snap.privateVaultUnlocked ? 'Разблокирован' : 'Заблокирован',
                          color: snap.privateVaultUnlocked ? colors.warning : colors.textMuted,
                        ),
                        if (snap.fakePinEnabled)
                          _StatusTile(
                            icon: Icons.dialpad_outlined,
                            label: 'Дополнительный PIN',
                            value: 'Настроен',
                            color: colors.secondary,
                          ),
                        _StatusTile(
                          icon: Icons.hide_source_outlined,
                          label: 'Скрытые чаты',
                          value: snap.hiddenChatsEnabled
                              ? 'Включены · ${snap.secretHiddenChatCount} скрыто'
                              : 'Выключены',
                          color: snap.hiddenChatsEnabled ? colors.secondary : colors.textMuted,
                          showDivider: false,
                        ),
                      ],
                    ),
                  const SizedBox(height: AppSpacing.lg),
                  AppSettingsGroup(
                    title: 'Активность',
                    children: [
                      _StatusTile(
                        icon: Icons.login,
                        label: 'Последний вход',
                        value: _formatWhen(snap.lastLoginAt),
                        color: colors.textSecondary,
                      ),
                      _StatusTile(
                        icon: Icons.pin_outlined,
                        label: 'Смена PIN',
                        value: _formatWhen(snap.lastPinChangeAt),
                        color: colors.textSecondary,
                      ),
                      _StatusTile(
                        icon: Icons.verified_user_outlined,
                        label: 'Проверка контакта',
                        value: _formatWhen(snap.lastContactVerificationAt),
                        color: colors.textSecondary,
                      ),
                      _StatusTile(
                        icon: Icons.history,
                        label: 'Последнее событие',
                        value: snap.lastSecurityEventTitle ?? 'Нет событий',
                        color: colors.textSecondary,
                      ),
                      if (snap.lastDuressCode != null) ...[
                        _StatusTile(
                          icon: Icons.campaign_outlined,
                          label: 'Последний сигнал duress',
                          value: 'Код ${snap.lastDuressCode} · ${snap.lastDuressChannel ?? '—'}',
                          color: colors.warning,
                        ),
                        _StatusTile(
                          icon: Icons.schedule,
                          label: 'Время сигнала duress',
                          value: _formatWhen(snap.lastDuressAt),
                          color: colors.textSecondary,
                          showDivider: false,
                        ),
                      ] else
                        _StatusTile(
                          icon: Icons.campaign_outlined,
                          label: 'Сигналы duress',
                          value: 'Не отправлялись',
                          color: colors.textMuted,
                          showDivider: false,
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  AppSettingsGroup(
                    title: 'Действия',
                    children: [
                      AppTile(
                        leading: Icon(Icons.devices_outlined, color: colors.textSecondary),
                        title: 'Сеансы устройств',
                        subtitle: 'Доверие, завершение доступа',
                        trailing: AppTile.chevron(context),
                        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DevicesScreen())),
                      ),
                      AppTile(
                        leading: Icon(Icons.wifi_tethering, color: colors.textSecondary),
                        title: 'Состояние соединения',
                        subtitle: 'Узлы, WebSocket, синхронизация',
                        trailing: AppTile.chevron(context),
                        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ConnectionStatusScreen())),
                      ),
                      AppTile(
                        leading: Icon(Icons.shield_outlined, color: colors.secondary),
                        title: 'Конфиденциальность',
                        subtitle: 'PIN, фейк, секретная комната',
                        trailing: AppTile.chevron(context),
                        onTap: () => PrivateModeNavigation.openConfidentiality(context),
                      ),
                      AppTile(
                        leading: Icon(Icons.policy_outlined, color: colors.textSecondary),
                        title: 'Политика безопасности',
                        subtitle: 'Рецепты: действие + условие + очередь',
                        trailing: AppTile.chevron(context),
                        onTap: () => PrivateModeNavigation.openPolicy(context),
                      ),
                      AppTile(
                        leading: Icon(Icons.people_outline, color: colors.textSecondary),
                        title: 'Доверенные контакты',
                        subtitle: 'Сигналы тревоги',
                        trailing: AppTile.chevron(context),
                        onTap: () => PrivateModeNavigation.openTrusted(context),
                      ),
                      AppTile(
                        leading: Icon(Icons.phonelink_lock_outlined, color: colors.textSecondary),
                        title: 'Подтверждение входа',
                        subtitle: 'Новые устройства',
                        trailing: AppTile.chevron(context),
                        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LoginApprovalScreen())),
                      ),
                      AppTile(
                        leading: Icon(Icons.verified_user_outlined, color: colors.textSecondary),
                        title: 'Проверить контакт',
                        trailing: AppTile.chevron(context),
                        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ContactsScreen())),
                      ),
                      AppTile(
                        leading: Icon(Icons.key_outlined, color: colors.textSecondary),
                        title: 'Ключ восстановления',
                        subtitle: 'Статус с сервера неизвестен',
                        trailing: AppTile.chevron(context),
                        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RecoveryKeyScreen())),
                      ),
                      AppTile(
                        leading: Icon(Icons.list_alt_outlined, color: colors.textSecondary),
                        title: 'Журнал безопасности',
                        trailing: AppTile.chevron(context),
                        showDivider: false,
                        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SecurityLogScreen())),
                      ),
                    ],
                  ),
                ],
              ],
            ),
    );
  }

  String _formatWhen(DateTime? at) {
    if (at == null) return 'Нет данных';
    return formatSyncTime(at);
  }
}

class _StatusTile extends StatelessWidget {
  const _StatusTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
    this.showDivider = true,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    return AppTile(
      leading: Icon(icon, color: color),
      title: label,
      trailingText: value,
      showDivider: showDivider,
    );
  }
}
