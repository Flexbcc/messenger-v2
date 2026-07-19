import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/conversation.dart';
import '../services/notification_navigation_service.dart';
import '../state/app_controller.dart';
import 'calls_screen.dart';
import 'chat_screen.dart';
import 'contacts_screen.dart';
import 'conversation_list_screen.dart';
import 'settings_screen.dart';

/// Main 4-tab shell per design.md §6.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;
  StreamSubscription<String>? _notificationNavSub;

  @override
  void initState() {
    super.initState();
    _notificationNavSub = NotificationNavigationService.instance.opens.listen(_openConversation);
  }

  @override
  void dispose() {
    _notificationNavSub?.cancel();
    super.dispose();
  }

  Future<void> _openConversation(String conversationId) async {
    final controller = ref.read(appControllerProvider);
    await controller.refreshConversations();
    if (!mounted) return;

    Conversation? conv;
    for (final c in controller.conversations) {
      if (c.id == conversationId) {
        conv = c;
        break;
      }
    }
    if (conv == null) return;

    if (controller.isSecretHidden(conversationId) && controller.hiddenChatsSilenceNotifications) {
      return;
    }

    setState(() => _index = 0);
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(conversation: conv!)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [
          ConversationListScreen(),
          CallsScreen(),
          ContactsScreen(),
          SettingsScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.chat_bubble_outline), selectedIcon: Icon(Icons.chat_bubble), label: 'Чаты'),
          NavigationDestination(icon: Icon(Icons.call_outlined), selectedIcon: Icon(Icons.call), label: 'Звонки'),
          NavigationDestination(icon: Icon(Icons.people_outline), selectedIcon: Icon(Icons.people), label: 'Контакты'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Настройки'),
        ],
      ),
    );
  }
}
