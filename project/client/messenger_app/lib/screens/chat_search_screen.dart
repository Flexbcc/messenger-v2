import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/conversation.dart';
import '../models/message.dart';
import '../state/app_controller.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../utils/message_format.dart';

/// In-chat search — фильтрует уже загруженные расшифрованные сообщения локально.
/// Поиск серверный не нужен: ciphertext непрозрачен, весь plaintext доступен
/// в памяти после расшифровки (visibleMessagesFor).
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
    final q = _query.trim();

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
        actions: [
          if (q.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: Text(
                  '${results.length}',
                  style: AppTypography.caption.copyWith(color: AppColors.textSecondary),
                ),
              ),
            ),
        ],
      ),
      body: q.isEmpty
          ? Center(child: Text('Введите текст для поиска', style: AppTypography.caption))
          : results.isEmpty
              ? Center(child: Text('Ничего не найдено', style: AppTypography.caption))
              : ListView.builder(
                  itemCount: results.length,
                  itemBuilder: (context, i) => _ResultTile(message: results[i], query: q),
                ),
    );
  }
}

class _ResultTile extends ConsumerWidget {
  const _ResultTile({required this.message, required this.query});

  final ChatMessage message;
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(appControllerProvider);
    final sender = message.senderUserId == controller.session?.userId
        ? 'Вы'
        : controller.labelFor(message.senderUserId);
    final body = messagePreview(message);

    return ListTile(
      title: Text(sender, style: AppTypography.body),
      subtitle: _HighlightText(text: body, query: query, maxLines: 2),
      trailing: Text(formatMessageTime(message.createdAt), style: AppTypography.caption),
      onTap: () => Navigator.of(context).pop(message.id),
    );
  }
}

/// Подсвечивает вхождения query в text жёлтым цветом.
class _HighlightText extends StatelessWidget {
  const _HighlightText({required this.text, required this.query, this.maxLines = 3});

  final String text;
  final String query;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    if (query.isEmpty) {
      return Text(text, maxLines: maxLines, overflow: TextOverflow.ellipsis,
          style: AppTypography.caption);
    }
    final lower = text.toLowerCase();
    final lowerQ = query.toLowerCase();
    final spans = <TextSpan>[];
    int start = 0;
    while (true) {
      final idx = lower.indexOf(lowerQ, start);
      if (idx == -1) {
        spans.add(TextSpan(text: text.substring(start)));
        break;
      }
      if (idx > start) spans.add(TextSpan(text: text.substring(start, idx)));
      spans.add(TextSpan(
        text: text.substring(idx, idx + query.length),
        style: const TextStyle(
          backgroundColor: Color(0xFFFFD700),
          color: Colors.black,
          fontWeight: FontWeight.w600,
        ),
      ));
      start = idx + query.length;
    }
    return Text.rich(
      TextSpan(children: spans, style: AppTypography.caption),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
    );
  }
}
