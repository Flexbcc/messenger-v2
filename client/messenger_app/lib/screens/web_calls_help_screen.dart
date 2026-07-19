import 'package:flutter/material.dart';

import '../core/extensions/context_extensions.dart';
import '../core/platform/platform_capabilities.dart';
import '../core/theme/app_spacing.dart';
import '../core/ui/app_card.dart';

/// Why web calls need HTTPS and how to set up a dev/self-signed certificate.
class WebCallsHelpScreen extends StatelessWidget {
  const WebCallsHelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final text = context.textStyles;
    final colors = context.colors;
    final secure = Uri.base.scheme == 'https';

    return Scaffold(
      appBar: AppBar(title: const Text('Звонки в браузере')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.screenPadding),
        children: [
          AppCard(
            child: Row(
              children: [
                Icon(
                  secure ? Icons.check_circle_outline : Icons.warning_amber_outlined,
                  color: secure ? colors.success : colors.warning,
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    secure
                        ? 'Страница открыта по HTTPS — WebRTC (микрофон/камера) доступен.'
                        : 'Сейчас ${Uri.base.scheme}:// — браузер блокирует звонки без HTTPS.',
                    style: text.body,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text('Почему так', style: text.title),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'В веб-версии звонки используют WebRTC. Браузеры разрешают доступ к микрофону и камере '
            'только в «безопасном контексте»: HTTPS или localhost. Это ограничение Chrome, Safari и Firefox — '
            'обойти его в коде приложения нельзя.',
            style: text.body,
          ),
          const SizedBox(height: AppSpacing.lg),
          Text('Варианты', style: text.title),
          const SizedBox(height: AppSpacing.sm),
          const _Bullet(
            title: 'Локальная разработка',
            body: 'http://127.0.0.1:7357 — localhost считается безопасным, звонки работают.',
          ),
          const _Bullet(
            title: 'Публичный сервер без домена',
            body: 'Поднимите nginx с самоподписанным сертификатом (скрипт project/scripts/generate-dev-https-cert.sh). '
                'Один раз примите предупреждение браузера о сертификате — после этого WebRTC заработает.',
          ),
          const _Bullet(
            title: 'Домен + Let\'s Encrypt',
            body: 'Для продакшена: certbot + nginx (см. deploy/nginx-pwa.example.conf и docs/pwa-deploy.md). '
                'PWA и WebSocket тоже должны идти через HTTPS, иначе mixed content.',
          ),
          const _Bullet(
            title: 'Нативное приложение',
            body: 'macOS/desktop-сборка не требует HTTPS для звонков.',
          ),
          if (PlatformCapabilities.isWeb) ...[
            const SizedBox(height: AppSpacing.lg),
            Text('Сборка PWA под HTTPS', style: text.title),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'При деплое задайте URL нод с https://:\n'
              'HOME_NODE_URL=https://host/home \\\n'
              'MEDIA_NODE_URL=https://host/media \\\n'
              'DISCOVERY_NODE_URL=https://host/discovery \\\n'
              './scripts/build-web-pwa.sh',
              style: text.caption.copyWith(fontFamily: 'monospace'),
            ),
          ],
        ],
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final text = context.textStyles;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: text.sectionTitle),
          const SizedBox(height: 4),
          Text(body, style: text.body),
        ],
      ),
    );
  }
}
