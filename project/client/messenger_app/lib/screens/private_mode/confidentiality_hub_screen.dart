import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/extensions/context_extensions.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/ui/app_card.dart';
import '../../core/ui/app_tile.dart';
import '../../services/privacy_setup_summary.dart';
import 'privacy_pin_section_screen.dart';
import 'privacy_decoy_section_screen.dart';
import 'privacy_secret_section_screen.dart';
import 'privacy_advanced_section_screen.dart';

/// Nested privacy hub — sequential unlock of sections.
class ConfidentialityHubScreen extends ConsumerStatefulWidget {
  const ConfidentialityHubScreen({super.key});

  @override
  ConsumerState<ConfidentialityHubScreen> createState() => _ConfidentialityHubScreenState();
}

class _ConfidentialityHubScreenState extends ConsumerState<ConfidentialityHubScreen> {
  PrivacySetupSummary? _summary;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    Future.microtask(_reload);
  }

  Future<void> _reload() async {
    final s = await PrivacySetupSummary.load();
    if (!mounted) return;
    setState(() {
      _summary = s;
      _loading = false;
    });
  }

  Future<void> _open(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;
    final p = _summary;

    return Scaffold(
      appBar: AppBar(title: const Text('Конфиденциальность')),
      body: _loading || p == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: AppSpacing.xl),
              children: [
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.screenPadding),
                  child: AppCard(
                    child: Text(
                      'Разделы открываются по очереди: сначала основной PIN, затем дополнительный, потом секретная комната.',
                      style: text.caption,
                    ),
                  ),
                ),
                AppSettingsGroup(
                  children: [
                    AppTile(
                      leading: Icon(Icons.pin_outlined, color: colors.primary),
                      title: 'Основной PIN',
                      subtitle: p.hasRealPin
                          ? 'Код · ошибки · блокировка · очистка'
                          : 'Шаг 1 · обязательный',
                      trailing: AppTile.chevron(context),
                      onTap: () => _open(const PrivacyPinSectionScreen()),
                    ),
                    AppTile(
                      leading: Icon(
                        Icons.dialpad_outlined,
                        color: p.hasRealPin ? colors.textSecondary : colors.textMuted,
                      ),
                      title: 'Дополнительный PIN',
                      subtitle: !p.hasRealPin
                          ? 'Сначала настройте основной PIN'
                          : p.hasDecoyPin
                              ? 'Фейк-интерфейс · доверенные · защита'
                              : 'Шаг 2 · нужен для секретной комнаты',
                      trailing: p.hasRealPin ? AppTile.chevron(context) : null,
                      enabled: p.hasRealPin,
                      onTap: p.hasRealPin ? () => _open(const PrivacyDecoySectionScreen()) : null,
                    ),
                    AppTile(
                      leading: Icon(
                        Icons.lock_person_outlined,
                        color: p.canConfigureSecretRoom ? colors.textSecondary : colors.textMuted,
                      ),
                      title: 'Секретная комната',
                      subtitle: !p.hasRealPin
                          ? 'Сначала основной PIN'
                          : !p.hasDecoyPin
                              ? 'Сначала доп. PIN'
                              : p.secretRoomConfigured
                                  ? 'Пароль · таймер · исчезающие'
                                  : 'Шаг 3 · скрытые сообщения',
                      trailing: p.canConfigureSecretRoom ? AppTile.chevron(context) : null,
                      enabled: p.canConfigureSecretRoom,
                      onTap: p.canConfigureSecretRoom ? () => _open(const PrivacySecretSectionScreen()) : null,
                    ),
                    AppTile(
                      leading: Icon(
                        Icons.tune_outlined,
                        color: p.secretRoomConfigured ? colors.textSecondary : colors.textMuted,
                      ),
                      title: 'Дополнительные',
                      subtitle: p.secretRoomConfigured
                          ? 'Скрытые чаты и устройства'
                          : 'Откроются после секретной комнаты',
                      trailing: p.secretRoomConfigured ? AppTile.chevron(context) : null,
                      enabled: p.secretRoomConfigured,
                      showDivider: false,
                      onTap: p.secretRoomConfigured ? () => _open(const PrivacyAdvancedSectionScreen()) : null,
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}
