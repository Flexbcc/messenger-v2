import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/extensions/context_extensions.dart';
import '../core/theme/app_radius.dart';
import '../core/theme/app_spacing.dart';
import '../core/ui/app_badge.dart';
import '../core/ui/app_button.dart';
import '../core/ui/app_card.dart';
import '../core/ui/app_tile.dart';
import '../models/device_info.dart';
import '../services/settings_runtime.dart';
import '../state/app_controller.dart';
import '../utils/format.dart';
import 'security/login_approval_screen.dart';
import 'device_detail_screen.dart';
import 'device_link_scanner_screen.dart';

/// Trusted Devices center — sessions, trust, Private Mode access.
class DevicesScreen extends ConsumerStatefulWidget {
  const DevicesScreen({super.key});

  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends ConsumerState<DevicesScreen> {
  bool _loading = true;
  String? _error;
  bool _remoteWipe = true;
  bool _requireApproval = true;
  String _historySync = 'from_pairing';
  bool _hiddenAccess = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final runtime = SettingsRuntime.instance;
      await ref.read(appControllerProvider).refreshDevices();
      _remoteWipe = await runtime.devicesRemoteWipeEnabled();
      _requireApproval = await runtime.devicesRequireApproval();
      _historySync = await runtime.devicesHistorySyncDefault();
      _hiddenAccess = await runtime.devicesHiddenAccessDefault();
    } catch (e) {
      _error = e.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _confirmRemoteWipe(DeviceInfo device) async {
    if (!_remoteWipe) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Удалённое стирание отключено (devices.remote_wipe)'),
        ),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалённое стирание?'),
        content: Text(
          'Завершить сеанс «${device.deviceName}» на удалённом устройстве?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Стереть'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(appControllerProvider).revokeDeviceSession(device.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Сеанс устройства завершён')),
        );
      }
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
      }
    }
  }

  Future<void> _confirmEndOtherSessions() async {
    final colors = context.colors;
    final devices = ref.read(appControllerProvider).devices;
    final others = devices.where((d) => !d.isCurrent).length;
    if (others == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Других активных сеансов нет')),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Завершить все другие сеансы?'),
        content: Text(
          'Будет удалено устройств: $others. Текущее устройство останется в системе.',
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

    try {
      await ref.read(appControllerProvider).revokeOtherDevices();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Другие сеансы завершены')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;
    final controller = ref.watch(appControllerProvider);
    final devices = controller.devices;
    final trustedCount = controller.trustedDeviceCount;
    final onlineCount = devices.where(isDeviceOnline).length;

    return Scaffold(
      appBar: AppBar(title: const Text('Сеансы устройств')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _error!,
                    style: text.caption,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  AppButton(label: 'Повторить', onPressed: _load),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.only(bottom: AppSpacing.xl),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(AppSpacing.screenPadding),
                    child: AppCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Центр устройств', style: text.title),
                          const SizedBox(height: AppSpacing.sm),
                          Text(
                            'Текущее: ${controller.session?.deviceId ?? '—'}',
                            style: text.caption,
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          Text(
                            'Подтверждение нового устройства: ${_requireApproval ? 'вкл.' : 'выкл.'}',
                            style: text.caption,
                          ),
                          Text(
                            'История новому устройству: $_historySync · скрытые чаты: ${_hiddenAccess ? 'да' : 'нет'}',
                            style: text.caption,
                          ),
                          const SizedBox(height: AppSpacing.md),
                          Row(
                            children: [
                              _SummaryChip(
                                icon: Icons.devices_outlined,
                                label: '${devices.length} устройств',
                              ),
                              const SizedBox(width: AppSpacing.sm),
                              _SummaryChip(
                                icon: Icons.verified_user_outlined,
                                label: '$trustedCount доверенных',
                                color: colors.primary,
                              ),
                              const SizedBox(width: AppSpacing.sm),
                              _SummaryChip(
                                icon: Icons.circle,
                                label: '$onlineCount онлайн',
                                color: colors.success,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (devices.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(AppSpacing.screenPadding),
                      child: Text(
                        'Нет зарегистрированных устройств',
                        style: text.caption,
                      ),
                    )
                  else
                    AppSettingsGroup(
                      margin: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.screenPadding,
                      ),
                      children: [
                        for (var i = 0; i < devices.length; i++)
                          _DeviceRow(
                            device: devices[i],
                            showDivider: i < devices.length - 1,
                            remoteWipeEnabled:
                                _remoteWipe && !devices[i].isCurrent,
                            onRemoteWipe: () => _confirmRemoteWipe(devices[i]),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) =>
                                    DeviceDetailScreen(device: devices[i]),
                              ),
                            ),
                          ),
                      ],
                    ),
                  const SizedBox(height: AppSpacing.xl),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.screenPadding,
                    ),
                    child: AppButton(
                      label: 'Сканировать QR нового устройства',
                      variant: AppButtonVariant.secondary,
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const DeviceLinkScannerScreen(),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.screenPadding,
                    ),
                    child: AppButton(
                      label: 'Запросы подтверждения',
                      variant: AppButtonVariant.secondary,
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const LoginApprovalScreen(),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.screenPadding,
                    ),
                    child: AppButton(
                      label: 'Завершить все другие сеансы',
                      variant: AppButtonVariant.danger,
                      onPressed: _confirmEndOtherSessions,
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _SummaryChip extends StatelessWidget {
  const _SummaryChip({required this.icon, required this.label, this.color});

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;
    final c = color ?? colors.textSecondary;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colors.cardSoft,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: c),
          const SizedBox(width: 4),
          Text(label, style: text.micro.copyWith(color: c)),
        ],
      ),
    );
  }
}

class _DeviceRow extends ConsumerWidget {
  const _DeviceRow({
    required this.device,
    required this.onTap,
    this.showDivider = true,
    this.remoteWipeEnabled = false,
    this.onRemoteWipe,
  });

  final DeviceInfo device;
  final VoidCallback onTap;
  final bool showDivider;
  final bool remoteWipeEnabled;
  final VoidCallback? onRemoteWipe;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final controller = ref.watch(appControllerProvider);
    final online = isDeviceOnline(device);
    final meta = controller.sessionMetaFor(device.id);
    final profile = controller.deviceTrustFor(device.id);

    return AppTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: colors.cardSoft,
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Icon(
          deviceTypeIcon(device.deviceType),
          color: colors.textPrimary,
          size: 20,
        ),
      ),
      title: device.deviceName,
      subtitle: deviceListSubtitle(device, meta: meta),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (device.isCurrent)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: AppSecurityBadge(
                icon: Icons.smartphone,
                label: 'Это устройство',
                color: colors.primary,
              ),
            ),
          if (remoteWipeEnabled)
            IconButton(
              icon: Icon(
                Icons.delete_forever_outlined,
                size: 18,
                color: colors.danger,
              ),
              tooltip: 'Удалённое стирание',
              onPressed: onRemoteWipe,
            ),
          if (!profile.trusted)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: AppSecurityBadge(
                icon: Icons.lock_outline,
                label: 'Нет доверия',
                color: colors.warning,
              ),
            ),
          StatusDot(
            status: online ? AppStatus.online : AppStatus.offline,
            diameter: 8,
          ),
          const SizedBox(width: 8),
          AppTile.chevron(context),
        ],
      ),
      showDivider: showDivider,
      onTap: onTap,
    );
  }
}
