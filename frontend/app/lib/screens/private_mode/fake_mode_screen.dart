import 'package:flutter/material.dart';

import '../../theme/colors.dart';
import '../../widgets/avatar.dart';
import '../../widgets/app_list_tile.dart';
import 'panic.dart';

class _FakeChat {
  const _FakeChat({required this.name, required this.lastMessage, required this.time});
  final String name;
  final String lastMessage;
  final String time;
}

const _fakeChats = [
  _FakeChat(name: 'Мама', lastMessage: 'Позвони, когда будет время', time: '09:14'),
  _FakeChat(name: 'Работа', lastMessage: 'Созвон перенесли на 15:00', time: 'вчера'),
  _FakeChat(name: 'Аптека на углу', lastMessage: 'Заказ готов к выдаче', time: 'пн'),
];

/// Decoy view opened by entering the Fake PIN instead of the real Private
/// Mode PIN. Deliberately looks like an ordinary, unremarkable chat list —
/// per spec/0402_PRIVATE_MODE.md this screen must contain no icon, menu
/// item, or affordance that hints Secret Room exists.
class FakeModeScreen extends StatelessWidget {
  const FakeModeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      appBar: AppBar(
        backgroundColor: AppColors.backgroundLight,
        elevation: 0,
        foregroundColor: AppColors.textPrimary,
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
            onTap: () {},
          );
        },
      ),
    );
  }
}
