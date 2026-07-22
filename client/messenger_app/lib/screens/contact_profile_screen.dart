import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../calls/call_signal.dart';
import '../core/extensions/context_extensions.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/app_spacing.dart';
import '../core/ui/app_avatar.dart';
import '../core/ui/app_badge.dart';
import '../core/ui/app_button.dart';
import '../core/ui/app_card.dart';
import '../core/ui/app_icon_button.dart';
import '../core/ui/app_search_field.dart';
import '../models/contact_trust.dart';
import '../services/settings_runtime.dart';
import '../state/app_controller.dart';
import 'chat_screen.dart';
import 'security/verify_contact_screen.dart';

class ContactProfileScreen extends ConsumerStatefulWidget {
  const ContactProfileScreen({super.key, required this.userId, required this.displayName});

  final String userId;
  final String displayName;

  @override
  ConsumerState<ContactProfileScreen> createState() => _ContactProfileScreenState();
}

class _ContactProfileScreenState extends ConsumerState<ContactProfileScreen> {
  late final TextEditingController _nameController;
  bool _calling = false;
  bool _videoCallsEnabled = true;
  bool _trustLevelsEnabled = true;
  List<String> _allowedTrustLevels = const [];
  bool _showAvatar = true;
  String? _shareHint;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.displayName);
    Future.microtask(_loadCallPrefs);
  }

  Future<void> _loadCallPrefs() async {
    final runtime = SettingsRuntime.instance;
    final video = await runtime.callsVideo();
    final trustOn = await runtime.contactsTrustLevelsEnabled();
    final levels = await runtime.contactsAllowedTrustLevels();
    // Preview how *our* visibility policies would hide fields when sharing.
    final showPhone = await runtime.canShowPhone(widget.userId, isContact: true);
    final showEmail = await runtime.canShowEmail(widget.userId, isContact: true);
    final showAvatar = await runtime.canShowAvatar(widget.userId, isContact: true);
    final qrOnly = await runtime.qrOnlyMode();
    if (!mounted) return;
    setState(() {
      _videoCallsEnabled = video;
      _trustLevelsEnabled = trustOn;
      _allowedTrustLevels = levels;
      _showAvatar = showAvatar;
      _shareHint = qrOnly
          ? 'QR-only: в шаринге только QR payload'
          : 'Видимость (как для контакта): телефон ${showPhone ? 'да' : 'нет'}, email ${showEmail ? 'да' : 'нет'}, аватар ${showAvatar ? 'да' : 'нет'}';
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _saveName() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    await ref.read(appControllerProvider).setContactAlias(widget.userId, name);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Имя сохранено')));
  }

  Future<void> _setTrust(TrustLevel level) async {
    await ref.read(appControllerProvider).setContactTrustLevel(widget.userId, level);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Уровень доверия: ${level.label}')));
    }
  }

  Future<void> _openChat() async {
    try {
      final conv = await ref.read(appControllerProvider).openOrCreateDirectChat(widget.userId);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(conversation: conv)));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось открыть чат: $e')));
    }
  }

  Future<void> _call(CallKind kind) async {
    if (_calling) return;
    if (kind == CallKind.video && !_videoCallsEnabled) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Видеозвонки отключены в настройках')),
        );
      }
      return;
    }
    setState(() => _calling = true);
    try {
      await ref.read(appControllerProvider).callPeer(peerUserId: widget.userId, kind: kind);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось позвонить: $e')));
    } finally {
      if (mounted) setState(() => _calling = false);
    }
  }

  bool _trustLevelAllowed(TrustLevel level) {
    if (_allowedTrustLevels.isEmpty) return true;
    // Map app TrustLevel names onto catalog option tokens.
    final token = switch (level) {
      TrustLevel.unknown => 'unknown',
      TrustLevel.normal => 'contact',
      TrustLevel.trusted => 'trusted',
      TrustLevel.highTrust => 'qr_verified',
    };
    return _allowedTrustLevels.contains(token) ||
        _allowedTrustLevels.contains(level.name) ||
        (level == TrustLevel.normal && _allowedTrustLevels.contains('unverified'));
  }

  IconData _trustIcon(TrustLevel level) => switch (level) {
        TrustLevel.unknown => Icons.help_outline,
        TrustLevel.normal => Icons.person_outline,
        TrustLevel.trusted => Icons.verified_user_outlined,
        TrustLevel.highTrust => Icons.shield_outlined,
      };

  Color _trustColor(TrustLevel level, AppColorScheme colors) => switch (level) {
        TrustLevel.unknown => colors.warning,
        TrustLevel.normal => colors.textSecondary,
        TrustLevel.trusted => colors.primary,
        TrustLevel.highTrust => colors.success,
      };

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;
    final controller = ref.watch(appControllerProvider);
    final name = controller.knownDisplayNames[widget.userId] ?? widget.displayName;
    final online = controller.isContactOnline(widget.userId);
    final status = controller.contactStatusLabel(widget.userId);
    final trust = controller.trustLevelFor(widget.userId);

    return Scaffold(
      appBar: AppBar(title: const Text('Контакт')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.screenPadding),
        children: [
          Center(
            child: _showAvatar
                ? AppAvatar(label: name, size: AppAvatarSize.large, showOnline: online)
                : AppAvatar(label: '?', size: AppAvatarSize.large, showOnline: false),
          ),
          const SizedBox(height: AppSpacing.md),
          Center(child: Text(name, style: text.largeTitle)),
          if (_shareHint != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                child: Text(_shareHint!, style: text.caption, textAlign: TextAlign.center),
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          Center(
            child: AppSecurityBadge(
              icon: _trustIcon(trust),
              label: trust.label,
              color: _trustColor(trust, colors),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          if (status.isNotEmpty)
            Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  StatusDot(status: online ? AppStatus.online : AppStatus.offline, diameter: 8),
                  const SizedBox(width: 6),
                  Text(status, style: text.caption),
                ],
              ),
            ),
          const SizedBox(height: AppSpacing.xl),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              AppQuickAction(icon: Icons.chat_bubble_outline, label: 'Написать', onTap: _openChat),
              AppQuickAction(
                icon: Icons.call_outlined,
                label: 'Аудио',
                onTap: _calling || controller.currentCall != null ? null : () => _call(CallKind.audio),
              ),
              if (_videoCallsEnabled)
                AppQuickAction(
                  icon: Icons.videocam_outlined,
                  label: 'Видео',
                  onTap: _calling || controller.currentCall != null ? null : () => _call(CallKind.video),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.xl),
          if (_trustLevelsEnabled) ...[
          Text('Уровень доверия', style: text.sectionTitle),
          const SizedBox(height: AppSpacing.sm),
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < TrustLevel.values.length; i++) ...[
                  if (_trustLevelAllowed(TrustLevel.values[i])) ...[
                    if (i > 0) Divider(height: 1, color: colors.divider),
                    ListTile(
                      leading: Icon(_trustIcon(TrustLevel.values[i]), color: _trustColor(TrustLevel.values[i], colors)),
                      title: Text(TrustLevel.values[i].label, style: text.subtitle),
                      subtitle: Text(TrustLevel.values[i].description, style: text.caption),
                      trailing: trust == TrustLevel.values[i]
                          ? Icon(Icons.check_circle, color: colors.primary, size: 20)
                          : null,
                      onTap: () => _setTrust(TrustLevel.values[i]),
                    ),
                  ],
                ],
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          ],
          AppButton(
            label: 'Проверить ключи',
            variant: AppButtonVariant.secondary,
            expanded: false,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => VerifyContactScreen(userId: widget.userId, displayName: name),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          AppTextField(controller: _nameController, hintText: 'Имя контакта'),
          const SizedBox(height: AppSpacing.sm),
          AppButton(label: 'Сохранить имя', onPressed: _saveName, expanded: false),
          const SizedBox(height: AppSpacing.xl),
          AppCard(
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('User ID', style: text.caption),
                      const SizedBox(height: 4),
                      SelectableText(widget.userId, style: text.body.copyWith(fontSize: 13)),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.copy_outlined, size: 18, color: colors.textSecondary),
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    final runtime = SettingsRuntime.instance;
                    final controller = ref.read(appControllerProvider);
                    final payload = await runtime.buildShareableProfilePayload(
                      userId: widget.userId,
                      displayName: name,
                      isContact: true,
                    );
                    payload['shared_from'] = controller.session?.userId;
                    await Clipboard.setData(
                      ClipboardData(text: const JsonEncoder().convert(payload)),
                    );
                    if (!mounted) return;
                    messenger.showSnackBar(
                      const SnackBar(content: Text('Карточка контакта скопирована')),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
