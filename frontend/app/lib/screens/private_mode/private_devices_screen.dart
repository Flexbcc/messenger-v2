import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/extensions/context_extensions.dart';
import '../../core/platform/platform_capabilities.dart';
import '../../core/theme/app_radius.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/ui/app_badge.dart';
import '../../core/ui/app_button.dart';
import '../../core/ui/app_card.dart';
import '../../core/ui/app_switch_tile.dart';
import '../../core/ui/app_tile.dart';
import '../../models/device_info.dart';
import '../../models/device_trust.dart';
import '../../services/hidden_vault_session.dart';
import '../../state/app_controller.dart';
import '../../utils/format.dart';
import '../device_detail_screen.dart';

/// Devices with access to Private Mode / Secret Room.
class PrivateDevicesScreen extends ConsumerStatefulWidget {
  const PrivateDevicesScreen({super.key});

  @override
  ConsumerState<PrivateDevicesScreen> createState() =>
      _PrivateDevicesScreenState();
}

class _PrivateDevicesScreenState extends ConsumerState<PrivateDevicesScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(appControllerProvider).refreshDevices());
  }

  Future<void> _endPrivateSessions() async {
    final colors = context.colors;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Завершить приватные сессии?'),
        content: const Text(
          'Secret Room будет заблокирован на этом устройстве. Доступ на других устройствах зависит от их настроек.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Завершить', style: TextStyle(color: colors.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    HiddenVaultSession.instance.lock();
    final currentId = ref.read(appControllerProvider).session?.deviceId;
    if (currentId != null) {
      final profile = ref.read(appControllerProvider).deviceTrustFor(currentId);
      await ref
          .read(appControllerProvider)
          .setDeviceTrustProfile(
            currentId,
            profile.copyWith(secretRoomAccess: false),
          );
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Приватная сессия завершена на этом устройстве'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;
    final controller = ref.watch(appControllerProvider);
    final devices = controller.devices;

    return Scaffold(
      appBar: AppBar(title: const Text('Приватные устройства')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.screenPadding),
        children: [
          if (PlatformCapabilities.isWeb)
            AppCard(
              margin: const EdgeInsets.only(bottom: AppSpacing.lg),
              child: Text(
                'В веб-версии управление приватными сессиями ограничено. Данные хранятся локально в браузере.',
                style: text.caption.copyWith(color: colors.warning),
              ),
            ),
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < devices.length; i++)
                  _DeviceRow(
                    device: devices[i],
                    profile: controller.deviceTrustFor(devices[i].id),
                    showDivider: i < devices.length - 1,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => DeviceDetailScreen(device: devices[i]),
                      ),
                    ),
                    onPrivateModeChanged: (v) =>
                        controller.setDevicePrivateModeAccess(devices[i].id, v),
                    onSecretRoomChanged: (v) =>
                        controller.setDeviceSecretRoomAccess(devices[i].id, v),
                  ),
                if (devices.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: Text(
                      'Нет зарегистрированных устройств',
                      style: text.secondary,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          AppButton(
            label: 'Завершить приватную сессию',
            variant: AppButtonVariant.danger,
            onPressed: _endPrivateSessions,
          ),
        ],
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.device,
    required this.profile,
    required this.onTap,
    required this.onPrivateModeChanged,
    required this.onSecretRoomChanged,
    this.showDivider = true,
  });

  final DeviceInfo device;
  final DeviceTrustProfile profile;
  final VoidCallback onTap;
  final ValueChanged<bool> onPrivateModeChanged;
  final ValueChanged<bool> onSecretRoomChanged;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;
    final online = isDeviceOnline(device);
    final pmLabel = profile.privateModeAccess
        ? 'Private Mode: да'
        : 'Private Mode: нет';
    final srLabel = profile.secretRoomAccess
        ? 'Secret Room: да'
        : 'Secret Room: нет';

    return Column(
      children: [
        AppTile(
          leading: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: colors.cardSoft,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Icon(
              deviceTypeIcon(device.deviceType),
              color: device.isCurrent ? colors.primary : colors.textSecondary,
              size: 18,
            ),
          ),
          title: '${device.deviceName}${device.isCurrent ? ' (текущее)' : ''}',
          subtitle: '$pmLabel · $srLabel · ${deviceStatusLabel(device)}',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              StatusDot(
                status: online ? AppStatus.online : AppStatus.offline,
                diameter: 8,
              ),
              const SizedBox(width: 8),
              AppTile.chevron(context),
            ],
          ),
          showDivider: false,
          onTap: onTap,
        ),
        if (profile.trusted) ...[
          AppSwitchTile(
            title: 'Private Mode',
            value: profile.privateModeAccess,
            enabled: !device.isCurrent || profile.trusted,
            onChanged: onPrivateModeChanged,
            showDivider: false,
          ),
          AppSwitchTile(
            title: 'Secret Room',
            value: profile.secretRoomAccess,
            enabled: profile.privateModeAccess,
            onChanged: onSecretRoomChanged,
            showDivider: showDivider,
          ),
        ] else
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Сначала отметьте устройство как доверенное',
                style: text.caption.copyWith(color: colors.warning),
              ),
            ),
          ),
        if (!profile.trusted && showDivider)
          Divider(height: 1, color: colors.divider),
      ],
    );
  }
}
