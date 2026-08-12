import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/extensions/context_extensions.dart';
import '../core/theme/app_spacing.dart';
import '../core/ui/app_card.dart';

class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  static const _supportEmail = 'support@example.com';

  @override
  Widget build(BuildContext context) {
    final text = context.textStyles;
    final colors = context.colors;

    return Scaffold(
      appBar: AppBar(title: const Text('Помощь и поддержка')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.screenPadding),
        children: [
          Text('Частые вопросы', style: text.title),
          const SizedBox(height: AppSpacing.md),
          const _FaqItem(
            question: 'Как начать чат?',
            answer:
                'Попросите собеседника поделиться User ID из профиля и создайте '
                'новый чат через «+». В системе нет глобального поиска пользователей.',
          ),
          const _FaqItem(
            question: 'Безопасны ли сообщения?',
            answer:
                'Переписка зашифрована end-to-end (Signal Protocol). Сервер видит только ciphertext.',
          ),
          const _FaqItem(
            question: 'Как войти с другого устройства?',
            answer:
                'Используйте тот же логин/телефон/email и пароль. Устройство появится в «Устройства».',
          ),
          const _FaqItem(
            question: 'Что делать, если не приходят сообщения?',
            answer:
                'Проверьте Home Node, обновите список чатов и убедитесь, что вы в аккаунте.',
          ),
          const SizedBox(height: AppSpacing.xl),
          Text('Связаться с поддержкой', style: text.title),
          const SizedBox(height: AppSpacing.md),
          AppCard(
            onTap: () {
              Clipboard.setData(const ClipboardData(text: _supportEmail));
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('Email скопирован')));
            },
            child: Row(
              children: [
                Icon(Icons.mail_outline, color: colors.textSecondary),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Email', style: text.caption),
                      Text(_supportEmail, style: text.body),
                    ],
                  ),
                ),
                Icon(
                  Icons.copy_outlined,
                  size: 18,
                  color: colors.textSecondary,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FaqItem extends StatelessWidget {
  const _FaqItem({required this.question, required this.answer});

  final String question;
  final String answer;

  @override
  Widget build(BuildContext context) {
    final text = context.textStyles;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: AppCard(
        padding: const EdgeInsets.all(AppSpacing.md),
        shadow: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(question, style: text.subtitle),
            const SizedBox(height: 4),
            Text(answer, style: text.caption),
          ],
        ),
      ),
    );
  }
}
