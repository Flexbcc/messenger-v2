import 'package:flutter/material.dart';

import '../../core/extensions/context_extensions.dart';
import '../../widgets/avatar.dart';
import '../../core/ui/app_tile.dart';
import 'panic.dart';

class _FakeChat {
  const _FakeChat({
    required this.name,
    required this.lastMessage,
    required this.time,
  });
  final String name;
  final String lastMessage;
  final String time;
}

const _fakeChats = [
  _FakeChat(
    name: 'Мама',
    lastMessage: 'Позвони, когда будет время',
    time: '09:14',
  ),
  _FakeChat(
    name: 'Работа',
    lastMessage: 'Созвон перенесли на 15:00',
    time: 'вчера',
  ),
  _FakeChat(
    name: 'Аптека на углу',
    lastMessage: 'Заказ готов к выдаче',
    time: 'пн',
  ),
];

/// Decoy view opened by entering the Fake PIN instead of the real Private
/// Mode PIN. Deliberately looks like an ordinary, unremarkable chat list —
/// per spec/0402_PRIVATE_MODE.md this screen must contain no icon, menu
/// item, or affordance that hints Secret Room exists.
class FakeModeScreen extends StatelessWidget {
  const FakeModeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        backgroundColor: colors.background,
        elevation: 0,
        foregroundColor: colors.textPrimary,
        title: const Text('Чаты'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => panicExit(context),
        ),
      ),
      body: ListView.builder(
        itemCount: _fakeChats.length,
        itemBuilder: (context, i) {
          final chat = _fakeChats[i];
          return AppListTile(
            leading: AppAvatar(label: chat.name),
            title: chat.name,
            subtitle: chat.lastMessage,
            trailingText: chat.time,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => _FakeConversationScreen(chat: chat),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _FakeConversationScreen extends StatelessWidget {
  const _FakeConversationScreen({required this.chat});

  final _FakeChat chat;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        backgroundColor: colors.background,
        foregroundColor: colors.textPrimary,
        elevation: 0,
        title: Row(
          children: [
            AppAvatar(label: chat.name, size: AppAvatarSize.small),
            const SizedBox(width: 10),
            Text(chat.name),
          ],
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                reverse: true,
                padding: const EdgeInsets.all(16),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 300),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: colors.surface,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        chat.lastMessage,
                        style: TextStyle(color: colors.textPrimary),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: TextField(
                enabled: false,
                decoration: InputDecoration(
                  hintText: 'Сообщение',
                  suffixIcon: const Icon(Icons.send_outlined),
                  filled: true,
                  fillColor: colors.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
