import 'package:flutter/material.dart';

import '../config.dart';
import '../core/extensions/context_extensions.dart';
import '../core/theme/app_radius.dart';
import '../core/theme/app_spacing.dart';
import '../core/ui/app_card.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;

    return Scaffold(
      appBar: AppBar(title: const Text('О приложении')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.screenPadding),
        children: [
          const SizedBox(height: AppSpacing.xl),
          Center(
            child: Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                gradient: colors.accentGradient,
                borderRadius: BorderRadius.circular(AppRadius.lg),
              ),
              child: Icon(Icons.shield_outlined, color: colors.textPrimary, size: 40),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Center(child: Text('Messenger', style: text.title)),
          const SizedBox(height: AppSpacing.sm),
          Center(child: Text('Версия ${AppInfo.version} (${AppInfo.buildNumber})', style: text.caption)),
          const SizedBox(height: AppSpacing.xl),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Сервер', style: text.subtitle),
                const SizedBox(height: AppSpacing.sm),
                Text('Home Node: ${AppConfig.homeNodeUrl}\nMedia Node: ${AppConfig.mediaNodeUrl}', style: text.caption),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Конфиденциальность', style: text.subtitle),
                const SizedBox(height: AppSpacing.sm),
                Text('Сообщения шифруются на устройстве. Сервер не имеет доступа к содержимому.', style: text.caption),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Open Source', style: text.subtitle),
                const SizedBox(height: AppSpacing.sm),
                Text('Flutter · Riverpod · libsignal · flutter_webrtc', style: text.caption),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
