import 'package:flutter/material.dart';

import '../../core/extensions/context_extensions.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/ui/app_card.dart';
import '../../core/ui/app_tile.dart';
import '../../models/scheduled_message.dart';
import '../../services/scheduled_message_store.dart';
import '../../state/app_controller.dart';
import '../../utils/format.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ScheduledMessagesScreen extends ConsumerStatefulWidget {
  const ScheduledMessagesScreen({super.key});

  @override
  ConsumerState<ScheduledMessagesScreen> createState() => _ScheduledMessagesScreenState();
}

class _ScheduledMessagesScreenState extends ConsumerState<ScheduledMessagesScreen> {
  List<ScheduledMessage> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await ScheduledMessageStore.instance.loadAll();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  String _titleFor(ScheduledMessage item) {
    final controller = ref.read(appControllerProvider);
    final conv = controller.conversations.where((c) => c.id == item.conversationId).firstOrNull;
    return conv != null ? controller.conversationTitle(conv) : 'Чат';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;

    return Scaffold(
      appBar: AppBar(title: const Text('Отложенные')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.screenPadding),
                    child: Text('Нет отложенных сообщений', style: text.caption),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: AppSpacing.xl),
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(AppSpacing.screenPadding),
                        child: AppCard(
                          child: Text(
                            'До отправки текст можно изменить только из чата — отмените и создайте заново.',
                            style: text.caption,
                          ),
                        ),
                      ),
                      AppSettingsGroup(
                        margin: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
                        children: [
                          for (var i = 0; i < _items.length; i++)
                            AppTile(
                              title: _titleFor(_items[i]),
                              subtitle: '${_items[i].text}\n${formatCallHistoryTime(_items[i].sendAt)}',
                              trailing: IconButton(
                                icon: Icon(Icons.close, color: colors.danger, size: 20),
                                onPressed: () async {
                                  await ref.read(appControllerProvider).cancelScheduledMessage(_items[i].id);
                                  await _load();
                                },
                              ),
                              showDivider: i < _items.length - 1,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
    );
  }
}
