import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/conversation.dart';
import '../models/message.dart';
import '../state/app_controller.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../utils/message_format.dart';

/// In-chat search — filters already-loaded decrypted messages locally.
class ChatSearchScreen extends ConsumerStatefulWidget {
  const ChatSearchScreen({super.key, required this.conversation});

  final Conversation conversation;

  @override
  ConsumerState<ChatSearchScreen> createState() => _ChatSearchScreenState();
}

class _ChatSearchScreenState extends ConsumerState<ChatSearchScreen> {
  final _queryController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _queryController.addListener(() => setState(() => _query = _queryController.text));
  }

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(appControllerProvider);
    final results = controller.searchMessages(widget.conversation.id, _query);

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _queryController,
          autofocus: true,
          style: AppTypography.body,
          decoration: InputDecoration(
            hintText: 'Поиск в чате',
            hintStyle: AppTypography.body.copyWith(color: AppColors.textSecondary),
            border: InputBorder.none,
          ),
        ),
      ),
      body: _query.trim().isEmpty
          ? Center(child: Text('Введите текст для поиска', style: AppTypography.caption))
          : results.isEmpty
              ? Center(child: Text('Ничего не найдено', style: AppTypography.caption))
              : ListView.builder(
                  itemCount: results.length,
                  itemBuilder: (context, i) => _ResultTile(message: results[i]),
                ),
    );
  }
}

class _ResultTile extends ConsumerWidget {
  const _ResultTile({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(appControllerProvider);
    final sender = message.senderUserId == controller.session?.userId
        ? 'Вы'
        : controller.labelFor(message.senderUserId);
    final body = messagePreview(message);

    return ListTile(
      title: Text(sender, style: AppTypography.body),
      subtitle: Text(
        body,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: AppTypography.caption,
      ),
      trailing: Text(formatMessageTime(message.createdAt), style: AppTypography.caption),
    );
  }
}
