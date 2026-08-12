import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/extensions/context_extensions.dart';
import '../../core/theme/app_radius.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/ui/app_badge.dart';
import '../../core/ui/app_button.dart';
import '../../core/ui/app_card.dart';
import '../../core/ui/app_empty_state.dart';
import '../../core/ui/app_switch_tile.dart';
import '../../models/login_approval_request.dart';
import '../../services/login_approval_service.dart';
import '../../state/app_controller.dart';
import '../../utils/format.dart';

/// Review and approve/deny login attempts from new devices.
class LoginApprovalScreen extends ConsumerStatefulWidget {
  const LoginApprovalScreen({super.key});

  @override
  ConsumerState<LoginApprovalScreen> createState() =>
      _LoginApprovalScreenState();
}

class _LoginApprovalScreenState extends ConsumerState<LoginApprovalScreen> {
  bool _enabled = true;
  bool _loadingSetting = true;

  @override
  void initState() {
    super.initState();
    _loadSetting();
    Future.microtask(() => ref.read(appControllerProvider).refreshDevices());
  }

  Future<void> _loadSetting() async {
    final enabled = await LoginApprovalService.instance.isEnabled();
    if (mounted) {
      setState(() {
        _enabled = enabled;
        _loadingSetting = false;
      });
    }
  }

  Future<void> _toggleEnabled(bool value) async {
    await LoginApprovalService.instance.setEnabled(value);
    setState(() => _enabled = value);
  }

  Future<void> _approve(LoginApprovalRequest request) async {
    try {
      await ref
          .read(appControllerProvider)
          .approveLoginRequest(request.deviceId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Вход разрешён: ${request.deviceName}')),
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

  Future<void> _deny(LoginApprovalRequest request) async {
    final colors = context.colors;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Запретить вход?'),
        content: Text(
          'Устройство «${request.deviceName}» не получит доступ. Если сеанс уже создан — завершите его в списке устройств.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Запретить', style: TextStyle(color: colors.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await ref.read(appControllerProvider).denyLoginRequest(request.deviceId);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Вход отклонён')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = context.textStyles;
    final pending = ref.watch(appControllerProvider).pendingLoginApprovals;

    return Scaffold(
      appBar: AppBar(title: const Text('Подтверждение входа')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            child: AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Login Approval', style: text.title),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Новые входы требуют подтверждения с доверенного устройства.',
                    style: text.caption,
                  ),
                ],
              ),
            ),
          ),
          if (!_loadingSetting)
            AppSettingsGroup(
              margin: const EdgeInsets.symmetric(
                horizontal: AppSpacing.screenPadding,
              ),
              children: [
                AppSwitchTile(
                  title: 'Требовать подтверждение',
                  value: _enabled,
                  onChanged: _toggleEnabled,
                  showDivider: false,
                ),
              ],
            ),
          const SizedBox(height: AppSpacing.lg),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.screenPadding,
            ),
            child: Text('Ожидают подтверждения', style: text.sectionTitle),
          ),
          const SizedBox(height: AppSpacing.sm),
          if (pending.isEmpty)
            AppEmptyState(
              icon: Icons.verified_user_outlined,
              title: 'Нет запросов',
              subtitle: 'Новые входы появятся здесь',
            )
          else
            AppSettingsGroup(
              margin: const EdgeInsets.symmetric(
                horizontal: AppSpacing.screenPadding,
              ),
              children: [
                for (var i = 0; i < pending.length; i++)
                  _RequestCard(
                    request: pending[i],
                    showDivider: i < pending.length - 1,
                    onApprove: () => _approve(pending[i]),
                    onDeny: () => _deny(pending[i]),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _RequestCard extends StatelessWidget {
  const _RequestCard({
    required this.request,
    required this.onApprove,
    required this.onDeny,
    this.showDivider = true,
  });

  final LoginApprovalRequest request;
  final VoidCallback onApprove;
  final VoidCallback onDeny;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: colors.cardSoft,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    child: Icon(
                      deviceTypeIcon(request.deviceType),
                      size: 20,
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(request.deviceName, style: text.subtitle),
                        Text(
                          '${devicePlatformLabel(request.deviceType)} · ${formatRelativeTime(request.requestedAt)}',
                          style: text.caption,
                        ),
                      ],
                    ),
                  ),
                  AppSecurityBadge(
                    icon: Icons.schedule,
                    label: 'Новый',
                    color: colors.warning,
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: AppButton(
                      label: 'Разрешить',
                      expanded: true,
                      onPressed: onApprove,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: AppButton(
                      label: 'Запретить',
                      variant: AppButtonVariant.danger,
                      expanded: true,
                      onPressed: onDeny,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (showDivider) Divider(height: 1, color: colors.divider),
      ],
    );
  }
}
