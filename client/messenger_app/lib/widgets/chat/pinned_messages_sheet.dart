import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/extensions/context_extensions.dart';
import '../../core/theme/app_spacing.dart';
import '../../models/conversation.dart';
import '../../models/message.dart';
import '../../state/app_controller.dart';
import '../../utils/message_format.dart' show formatMessageTime, messagePreview;

Future<void> showPinnedMessagesSheet({
  required BuildContext context,
  required Conversation conversation,
  required void Function(String messageId) onOpenMessage,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.55,
      minChildSize: 0.32,
      maxChildSize: 0.88,
      builder: (context, scrollController) => _PinnedMessagesBody(
        conversation: conversation,
        scrollController: scrollController,
        onOpenMessage: onOpenMessage,
      ),
    ),
  );
}

class _PinnedMessagesBody extends ConsumerWidget {
  const _PinnedMessagesBody({
    required this.conversation,
    required this.scrollController,
    required this.onOpenMessage,
  });

  final Conversation conversation;
  final ScrollController scrollController;
  final void Function(String messageId) onOpenMessage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(appControllerProvider);
    final pinned = controller.pinnedMessagesFor(conversation.id);
    final colors = context.colors;
    final text = context.textStyles;

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.screenPadding, 0, AppSpacing.screenPadding, AppSpacing.sm),
            child: Text('Закреплённые', style: text.title),
          ),
          Expanded(
            child: pinned.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.screenPadding),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.push_pin_outlined, size: 40, color: colors.textMuted),
                          const SizedBox(height: AppSpacing.md),
                          Text(
                            'Долгое нажатие на сообщение → «Закрепить»',
                            style: text.caption,
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: scrollController,
                    itemCount: pinned.length,
                    itemBuilder: (context, i) {
                      final message = pinned[i];
                      return _PinnedTile(
                        message: message,
                        isMine: message.senderUserId == controller.session?.userId,
                        onTap: () {
                          Navigator.pop(context);
                          onOpenMessage(message.id);
                        },
                        onUnpin: () async {
                          await controller.toggleMessagePinned(message.id);
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _PinnedTile extends StatelessWidget {
  const _PinnedTile({
    required this.message,
    required this.isMine,
    required this.onTap,
    required this.onUnpin,
  });

  final ChatMessage message;
  final bool isMine;
  final VoidCallback onTap;
  final VoidCallback onUnpin;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;
    final preview = messagePreview(message);

    return ListTile(
      leading: Icon(Icons.push_pin, color: colors.primary, size: 20),
      title: Text(
        preview,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: text.body,
      ),
      subtitle: Text(formatMessageTime(message.createdAt), style: text.caption),
      trailing: IconButton(
        icon: Icon(Icons.push_pin_outlined, color: colors.textMuted, size: 20),
        tooltip: 'Открепить',
        onPressed: onUnpin,
      ),
      onTap: onTap,
    );
  }
}
