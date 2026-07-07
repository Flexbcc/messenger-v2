import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/extensions/context_extensions.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/ui/app_card.dart';
import '../../core/ui/app_tile.dart';
import '../../models/duress_policy.dart';
import '../../services/duress_policy_session.dart';
import '../../state/app_controller.dart';
import 'trusted_contacts_screen.dart';
import 'duress_rules_editor_screen.dart';

/// Preset picker for duress policy — Private Mode only.
class DuressPolicyScreen extends ConsumerStatefulWidget {
  const DuressPolicyScreen({super.key});

  @override
  ConsumerState<DuressPolicyScreen> createState() => _DuressPolicyScreenState();
}

class _DuressPolicyScreenState extends ConsumerState<DuressPolicyScreen> {
  String _presetId = 'P2';
  List<String> _channels = List.from(DuressTrustedChannels.both);
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final data = DuressPolicySession.instance.data;
    if (!mounted) return;
    setState(() {
      _presetId = data?.presetId ?? 'P2';
      _channels = List.from(data?.trustedChannels ?? DuressTrustedChannels.both);
      _loading = false;
    });
  }

  Future<void> _pickPreset() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final id in DuressPresets.ids)
              ListTile(
                title: Text(DuressPresets.label(id)),
                subtitle: Text(DuressPresets.description(id)),
                trailing: _presetId == id ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(ctx, id),
              ),
          ],
        ),
      ),
    );
    if (picked == null || picked == _presetId) return;
    await DuressPolicySession.instance.setPreset(picked);
    setState(() => _presetId = picked);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Пресет: ${DuressPresets.label(picked)}')),
    );
    if (picked == DuressPresets.customId) {
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const DuressRulesEditorScreen()),
      );
      if (mounted) await _load();
    }
  }

  Future<void> _openRulesEditor() async {
    if (_presetId != DuressPresets.customId) {
      await DuressPolicySession.instance.setPreset(DuressPresets.customId);
      if (!mounted) return;
      setState(() => _presetId = DuressPresets.customId);
    }
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const DuressRulesEditorScreen()),
    );
    if (mounted) await _load();
  }

  Future<void> _pickChannels() async {
    final options = <List<String>>[
      DuressTrustedChannels.chatOnly,
      DuressTrustedChannels.relayOnly,
      DuressTrustedChannels.both,
    ];
    final picked = await showModalBottomSheet<List<String>>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final ch in options)
              ListTile(
                title: Text(DuressTrustedChannels.label(ch)),
                subtitle: Text(DuressTrustedChannels.description(ch)),
                trailing: _channelsMatch(ch, _channels) ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(ctx, ch),
              ),
          ],
        ),
      ),
    );
    if (picked == null || _channelsMatch(picked, _channels)) return;
    await DuressPolicySession.instance.setTrustedChannels(picked);
    setState(() => _channels = List.from(picked));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Канал: ${DuressTrustedChannels.label(picked)}')),
    );
  }

  bool _channelsMatch(List<String> a, List<String> b) {
    final na = DuressTrustedChannels.normalize(a);
    final nb = DuressTrustedChannels.normalize(b);
    if (na.length != nb.length) return false;
    return na.every(nb.contains);
  }

  Future<void> _testSignal() async {
    final result = await ref.read(appControllerProvider).testDuressDelivery();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(result)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = context.textStyles;
    final colors = context.colors;

    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (!DuressPolicySession.instance.isUnlocked) {
      return Scaffold(
        appBar: AppBar(title: const Text('Политика безопасности')),
        body: const Center(child: Text('Сначала разблокируйте защищённый раздел')),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Политика безопасности')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            child: AppCard(
              child: Text(
                'Правила срабатывают при вводе PIN и дополнительного PIN. '
                'Настройки хранятся на устройстве в зашифрованном виде.',
                style: text.caption,
              ),
            ),
          ),
          AppSettingsGroup(
            title: 'Пресет',
            children: [
              AppTile(
                leading: Icon(Icons.policy_outlined, color: colors.textSecondary),
                title: DuressPresets.label(_presetId),
                subtitle: DuressPresets.description(_presetId),
                trailing: AppTile.chevron(context),
                onTap: _pickPreset,
              ),
              AppTile(
                leading: Icon(Icons.tune_outlined, color: colors.textSecondary),
                title: 'Свои правила',
                subtitle: _presetId == DuressPresets.customId
                    ? '${DuressPolicySession.instance.data?.rules.length ?? 0} правил'
                    : 'Настроить пороги и действия вручную',
                trailing: AppTile.chevron(context),
                onTap: _openRulesEditor,
                showDivider: false,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          AppSettingsGroup(
            title: 'Доставка сигналов',
            children: [
              AppTile(
                leading: Icon(Icons.hub_outlined, color: colors.textSecondary),
                title: DuressTrustedChannels.label(_channels),
                subtitle: DuressTrustedChannels.description(_channels),
                trailing: AppTile.chevron(context),
                onTap: _pickChannels,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          AppSettingsGroup(
            title: 'Доверенные лица',
            children: [
              AppTile(
                leading: Icon(Icons.verified_user_outlined, color: colors.textSecondary),
                title: 'Список контактов',
                subtitle: '${DuressPolicySession.instance.data?.trustedUserIds.length ?? 0} выбрано',
                trailing: AppTile.chevron(context),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const TrustedContactsScreen()),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          AppSettingsGroup(
            title: 'Проверка',
            children: [
              AppTile(
                leading: Icon(Icons.send_outlined, color: colors.textSecondary),
                title: 'Тестовый сигнал',
                subtitle: 'Код 90 — по выбранным каналам',
                trailing: AppTile.chevron(context),
                onTap: _testSignal,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
