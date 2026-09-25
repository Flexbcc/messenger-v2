import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/extensions/context_extensions.dart';
import '../services/debug_log.dart';
import '../state/app_controller.dart';
import '../theme/spacing.dart';
import '../theme/typography.dart';

/// Local debug log for API/crypto troubleshooting (dev builds).
class DebugLogScreen extends ConsumerStatefulWidget {
  const DebugLogScreen({super.key});

  @override
  ConsumerState<DebugLogScreen> createState() => _DebugLogScreenState();
}

class _DebugLogScreenState extends ConsumerState<DebugLogScreen> {
  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(appControllerProvider);
    final lines = DebugLog.instance.lines;
    final session = controller.session;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Журнал отладки'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Проверить чаты',
            onPressed: () async {
              await controller.validateAllConversationsReachability();
              if (mounted) setState(() {});
            },
          ),
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Копировать',
            onPressed: lines.isEmpty
                ? null
                : () {
                    Clipboard.setData(ClipboardData(text: lines.join('\n')));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Журнал скопирован')),
                    );
                  },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Очистить',
            onPressed: () {
              DebugLog.instance.clear();
              setState(() {});
            },
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (session != null)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.screenPadding),
              child: Text(
                'Аккаунт: ${session.displayName}\nUser ID: ${session.userId}',
                style: AppTypography.caption,
              ),
            ),
          Expanded(
            child: lines.isEmpty
                ? const Center(
                    child: Text(
                      'Пока пусто — действия в приложении появятся здесь',
                      style: AppTypography.secondary,
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(AppSpacing.screenPadding),
                    itemCount: lines.length,
                    separatorBuilder: (_, __) =>
                        const SizedBox(height: AppSpacing.smallGap / 2),
                    itemBuilder: (context, i) => SelectableText(
                      lines[i],
                      style: AppTypography.caption.copyWith(
                        fontFamily: 'monospace',
                        color: lines[i].contains('[ERR]')
                            ? context.colors.danger
                            : context.colors.textPrimary,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
