import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/extensions/context_extensions.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/ui/app_card.dart';
import '../../core/ui/app_tile.dart';
import '../../models/duress_policy.dart';
import '../../services/duress_policy_session.dart';
import '../../services/privacy_setup_summary.dart';
import '../../widgets/private/duress_behavior_card.dart';
import 'private_settings_access.dart';

/// Decoy PIN + what happens when it is entered (notify, purge, decoy UI).
class PrivacyDecoySectionScreen extends ConsumerStatefulWidget {
  const PrivacyDecoySectionScreen({super.key});

  @override
  ConsumerState<PrivacyDecoySectionScreen> createState() => _PrivacyDecoySectionScreenState();
}

class _PrivacyDecoySectionScreenState extends ConsumerState<PrivacyDecoySectionScreen> {
  PrivacySetupSummary? _summary;
  int _trustedCount = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    Future.microtask(_reload);
  }

  @override
  void dispose() {
    PrivateSettingsAccess.lockVault();
    super.dispose();
  }

  Future<void> _reload() async {
    await warmDuressMirror();
    final s = await PrivacySetupSummary.load();
    final trusted = DuressPolicySession.instance.data?.trustedUserIds.length ?? s.trustedContactsCount;
    if (!mounted) return;
    setState(() {
      _summary = s;
      _trustedCount = trusted;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;
    final p = _summary;

    if (_loading || p == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (!p.hasRealPin) {
      return Scaffold(
        appBar: AppBar(title: const Text('Дополнительный PIN')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            child: Text('Сначала создайте основной PIN', style: text.body, textAlign: TextAlign.center),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Дополнительный PIN')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            child: AppCard(
              child: Text(
                'Фейковый PIN открывает «безобидный» вид приложения. '
                'По правилам duress может уведомить доверенных и при повторах удалить секретные сообщения.',
                style: text.caption,
              ),
            ),
          ),
          AppSettingsGroup(
            title: 'Код',
            children: [
              AppTile(
                leading: Icon(Icons.dialpad_outlined, color: colors.textSecondary),
                title: p.hasDecoyPin ? 'Изменить дополнительный PIN' : 'Создать дополнительный PIN',
                subtitle: p.hasDecoyPin ? 'Фейковый PIN настроен' : 'Обязателен для секретной комнаты',
                trailing: AppTile.chevron(context),
                onTap: () async {
                  await PrivateSettingsAccess.openDecoyPinSetup(context, showSkip: false);
                  await _reload();
                },
                showDivider: false,
              ),
            ],
          ),
          if (p.hasDecoyPin) ...[
            const SizedBox(height: AppSpacing.lg),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
              child: Text('Что происходит при вводе', style: text.sectionTitle),
            ),
            const SizedBox(height: AppSpacing.sm),
            const DuressBehaviorCard(
              title: 'Правила (дополнительный PIN)',
              trigger: DuressTrigger.decoyPinStreak,
            ),
            const SizedBox(height: AppSpacing.md),
            AppSettingsGroup(
              title: 'Кому слать сигналы',
              children: [
                AppTile(
                  leading: Icon(Icons.people_outline, color: colors.textSecondary),
                  title: 'Доверенные контакты',
                  subtitle: _trustedCount > 0
                      ? '$_trustedCount · их уведомят при decoy / ошибках'
                      : 'Пока пусто — добавьте, иначе notify некому слать',
                  trailing: AppTile.chevron(context),
                  onTap: () async {
                    await PrivateSettingsAccess.openTrustedContacts(context, keepUnlocked: true);
                    await _reload();
                  },
                  showDivider: false,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            AppSettingsGroup(
              title: 'Изменить поведение',
              children: [
                AppTile(
                  leading: Icon(Icons.shield_outlined, color: colors.textSecondary),
                  title: 'Рецепты защиты',
                  subtitle: 'Действие → условие → очередь (оповещения, очистка…)',
                  trailing: AppTile.chevron(context),
                  onTap: () async {
                    await PrivateSettingsAccess.openDuressPolicy(context, keepUnlocked: true);
                    await _reload();
                  },
                  showDivider: false,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.screenPadding),
              child: AppCard(
                child: Text(
                  'Дополнительный PIN открывает безопасный интерфейс без секретов. '
                  'По умолчанию после 5 вводов доверенные получают предупреждение — '
                  'добавьте контакты и проверьте тест доставки.',
                  style: text.caption,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
