import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/extensions/context_extensions.dart';
import '../core/theme/app_radius.dart';
import '../core/theme/app_spacing.dart';
import '../core/ui/app_badge.dart';
import '../core/ui/app_button.dart';
import '../core/ui/app_card.dart';
import '../core/ui/app_section.dart';
import '../core/ui/app_switch_tile.dart';
import '../models/device_info.dart';
import '../state/app_controller.dart';
import '../utils/format.dart';

class DeviceDetailScreen extends ConsumerStatefulWidget {
  const DeviceDetailScreen({super.key, required this.device});

  final DeviceInfo device;

  @override
  ConsumerState<DeviceDetailScreen> createState() => _DeviceDetailScreenState();
}

class _DeviceDetailScreenState extends ConsumerState<DeviceDetailScreen> {
  bool _revoking = false;

  String _formatDateTime(DateTime dt) {
    final local = dt.toLocal();
    return '${local.day.toString().padLeft(2, '0')}.'
        '${local.month.toString().padLeft(2, '0')}.'
        '${local.year} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _confirmRevoke() async {
    final colors = context.colors;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Завершить сеанс?'),
        content: Text(
          'Устройство «${widget.device.deviceName}» потеряет доступ к аккаунту. '
          'Потребуется повторный вход.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Завершить', style: TextStyle(color: colors.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _revoking = true);
    try {
      await ref
          .read(appControllerProvider)
          .revokeDeviceSession(widget.device.id);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Сеанс завершён')));
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
      }
    } finally {
      if (mounted) setState(() => _revoking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;
    final controller = ref.watch(appControllerProvider);
    final profile = controller.deviceTrustFor(widget.device.id);
    final meta = controller.sessionMetaFor(widget.device.id);
    final online = isDeviceOnline(widget.device);

    return Scaffold(
      appBar: AppBar(title: const Text('Сеанс устройства')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        children: [
          const SizedBox(height: AppSpacing.xl),
          Center(
            child: Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: colors.cardSoft,
                borderRadius: BorderRadius.circular(AppRadius.lg),
              ),
              child: Icon(
                deviceTypeIcon(widget.device.deviceType),
                size: 36,
                color: colors.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Center(child: Text(widget.device.deviceName, style: text.title)),
          const SizedBox(height: AppSpacing.sm),
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                StatusDot(
                  status: online ? AppStatus.online : AppStatus.offline,
                  diameter: 8,
                ),
                const SizedBox(width: 6),
                Text(deviceStatusLabel(widget.device), style: text.caption),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Center(
            child: AppSecurityBadge(
              icon: profile.trusted
                  ? Icons.verified_user_outlined
                  : Icons.lock_outline,
              label: profile.trusted ? 'Доверенное' : 'Недоверенное',
              color: profile.trusted ? colors.primary : colors.warning,
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          AppSettingsGroup(
            title: 'Сеанс',
            children: [
              AppInfoRow(
                label: 'Платформа',
                value: devicePlatformLabel(widget.device.deviceType),
              ),
              AppInfoRow(label: 'ОС', value: meta?.platformLabel ?? '—'),
              AppInfoRow(
                label: 'Версия приложения',
                value: meta?.appVersion ?? '—',
              ),
              AppInfoRow(
                label: 'Соединение',
                value: controller.connectionLabelFor(widget.device),
              ),
              AppInfoRow(
                label: 'Последняя активность',
                value: _formatDateTime(widget.device.lastActive),
              ),
              AppInfoRow(
                label: 'Первый вход',
                value: _formatDateTime(widget.device.createdAt),
              ),
              AppInfoRow(
                label: 'Статус',
                value: widget.device.isCurrent
                    ? 'Текущее устройство'
                    : (online ? 'Онлайн' : 'Не в сети'),
                showDivider: false,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          AppSettingsGroup(
            title: 'Доверие и доступ',
            children: [
              AppSwitchTile(
                leading: Icon(
                  Icons.verified_user_outlined,
                  color: colors.textSecondary,
                ),
                title: 'Доверенное устройство',
                subtitle: widget.device.isCurrent
                    ? 'Текущее устройство всегда доверенное'
                    : 'Разрешить автоматические действия',
                value: profile.trusted,
                enabled: !widget.device.isCurrent,
                onChanged: (v) => ref
                    .read(appControllerProvider)
                    .setDeviceTrusted(widget.device.id, v),
              ),
              AppSwitchTile(
                leading: Icon(
                  Icons.visibility_off_outlined,
                  color: colors.textSecondary,
                ),
                title: 'Доступ к Private Mode',
                value: profile.privateModeAccess,
                enabled: profile.trusted,
                onChanged: (v) => ref
                    .read(appControllerProvider)
                    .setDevicePrivateModeAccess(widget.device.id, v),
              ),
              AppSwitchTile(
                leading: Icon(Icons.key_outlined, color: colors.textSecondary),
                title: 'Доступ к Secret Room',
                value: profile.secretRoomAccess,
                enabled: profile.trusted && profile.privateModeAccess,
                showDivider: false,
                onChanged: (v) => ref
                    .read(appControllerProvider)
                    .setDeviceSecretRoomAccess(widget.device.id, v),
              ),
            ],
          ),
          if (!widget.device.isCurrent) ...[
            const SizedBox(height: AppSpacing.xl),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.screenPadding,
              ),
              child: AppButton(
                label: 'Завершить сеанс',
                variant: AppButtonVariant.danger,
                loading: _revoking,
                onPressed: _revoking ? null : _confirmRevoke,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.screenPadding,
            ),
            child: AppCard(
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('ID устройства', style: text.caption),
                        const SizedBox(height: 4),
                        SelectableText(
                          widget.device.id,
                          style: text.body.copyWith(fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.copy_outlined,
                      size: 18,
                      color: colors.textSecondary,
                    ),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: widget.device.id));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Скопировано')),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
