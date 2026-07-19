import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/extensions/context_extensions.dart';
import '../core/theme/app_spacing.dart';
import '../core/ui/app_bottom_sheet.dart';
import '../core/ui/app_card.dart';
import '../core/ui/app_switch_tile.dart';
import '../core/ui/app_tile.dart';
import '../services/local_settings_store.dart';
import '../state/app_controller.dart';

/// Who can find you / message you — synced to Home Node profile_settings.
class DiscoverabilitySettingsScreen extends ConsumerStatefulWidget {
  const DiscoverabilitySettingsScreen({super.key});

  @override
  ConsumerState<DiscoverabilitySettingsScreen> createState() => _DiscoverabilitySettingsScreenState();
}

class _DiscoverabilitySettingsScreenState extends ConsumerState<DiscoverabilitySettingsScreen> {
  final _store = LocalSettingsStore();
  bool _loading = true;
  bool _saving = false;

  bool _usernameSearch = true;
  bool _phoneSearch = false;
  bool _emailSearch = false;
  bool _readReceipts = true;
  String _incoming = 'invites';

  static const _incomingLabels = {
    'nobody': 'Никто',
    'contacts': 'Только контакты',
    'invites': 'По приглашению',
    'everyone': 'Все',
  };

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    Map<String, dynamic> values = {};
    try {
      final blob = await ref.read(appControllerProvider).api.getProfileSettings();
      values = Map<String, dynamic>.from((blob['values'] as Map?) ?? {});
    } catch (_) {
      // Offline — fall back to local cache.
    }
    final local = await _store.getString('discoverability_cache', '');
    if (values.isEmpty && local.isNotEmpty) {
      // ignore malformed
    }

    bool readBool(String key, bool fallback) {
      final v = values[key];
      if (v is bool) return v;
      return fallback;
    }

    String readStr(String key, String fallback) {
      final v = values[key];
      if (v is String && v.isNotEmpty) return v;
      return fallback;
    }

    if (!mounted) return;
    setState(() {
      _usernameSearch = readBool('privacy.username_search', true);
      _phoneSearch = readBool('privacy.phone_search', false);
      _emailSearch = readBool('privacy.email_search', false);
      _readReceipts = readBool('privacy.read_receipts', true);
      _incoming = readStr('privacy.incoming_messages', 'invites');
      _loading = false;
    });
  }

  Future<void> _persist() async {
    setState(() => _saving = true);
    final values = {
      'privacy.username_search': _usernameSearch,
      'privacy.phone_search': _phoneSearch,
      'privacy.email_search': _emailSearch,
      'privacy.read_receipts': _readReceipts,
      'privacy.incoming_messages': _incoming,
    };
    try {
      Map<String, dynamic> blob = {'values': <String, dynamic>{}, 'lists': <String, dynamic>{}};
      try {
        blob = await ref.read(appControllerProvider).api.getProfileSettings();
      } catch (_) {}
      final merged = Map<String, dynamic>.from((blob['values'] as Map?)?.cast<String, dynamic>() ?? {});
      merged.addAll(values);
      await ref.read(appControllerProvider).api.updateProfileSettings({
        'values': merged,
        'lists': blob['lists'] ?? {},
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось сохранить на сервер: $e')),
        );
      }
    }
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _pickIncoming() async {
    final colors = context.colors;
    final text = context.textStyles;
    final picked = await showAppBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final e in _incomingLabels.entries)
              ListTile(
                title: Text(e.value, style: text.body),
                trailing: e.key == _incoming ? Icon(Icons.check, color: colors.primary) : null,
                onTap: () => Navigator.pop(context, e.key),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    setState(() => _incoming = picked);
    await _persist();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Кто может найти'),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: AppSpacing.xl),
              children: [
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.screenPadding),
                  child: AppCard(
                    child: Text(
                      'Поиск по username / телефону / почте в Discovery. Изменения уходят на Home Node.',
                      style: text.caption,
                    ),
                  ),
                ),
                AppSettingsGroup(
                  title: 'Поиск',
                  children: [
                    AppSwitchTile(
                      leading: Icon(Icons.alternate_email, color: colors.textSecondary),
                      title: 'Поиск по username',
                      subtitle: 'Находить вас по логину',
                      value: _usernameSearch,
                      onChanged: (v) async {
                        setState(() => _usernameSearch = v);
                        await _persist();
                      },
                    ),
                    AppSwitchTile(
                      leading: Icon(Icons.phone_outlined, color: colors.textSecondary),
                      title: 'Поиск по телефону',
                      value: _phoneSearch,
                      onChanged: (v) async {
                        setState(() => _phoneSearch = v);
                        await _persist();
                      },
                    ),
                    AppSwitchTile(
                      leading: Icon(Icons.email_outlined, color: colors.textSecondary),
                      title: 'Поиск по почте',
                      value: _emailSearch,
                      onChanged: (v) async {
                        setState(() => _emailSearch = v);
                        await _persist();
                      },
                      showDivider: false,
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.lg),
                AppSettingsGroup(
                  title: 'Сообщения',
                  children: [
                    AppTile(
                      leading: Icon(Icons.mail_outline, color: colors.textSecondary),
                      title: 'Кто может писать первым',
                      trailingText: _incomingLabels[_incoming],
                      trailing: AppTile.chevron(context),
                      onTap: _pickIncoming,
                    ),
                    AppSwitchTile(
                      leading: Icon(Icons.done_all, color: colors.textSecondary),
                      title: 'Отчёты о прочтении',
                      value: _readReceipts,
                      onChanged: (v) async {
                        setState(() => _readReceipts = v);
                        await _persist();
                      },
                      showDivider: false,
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}
