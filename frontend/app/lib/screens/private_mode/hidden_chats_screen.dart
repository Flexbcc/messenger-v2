import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/extensions/context_extensions.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/ui/app_avatar.dart';
import '../../core/ui/app_empty_state.dart';
import '../../core/ui/app_icon_button.dart';
import '../../core/ui/app_search_field.dart';
import '../../core/ui/app_tile.dart';
import '../../core/ui/chat_list_tile.dart';
import '../../models/conversation.dart';
import '../../models/hidden_chat.dart';
import '../../services/hidden_chats_store.dart';
import '../../services/hidden_vault_session.dart';
import '../../state/app_controller.dart';
import '../../utils/format.dart';
import '../../utils/message_format.dart';
import '../chat_screen.dart';
import 'hidden_chat_dialog_screen.dart';
import 'hidden_chats_settings_screen.dart';
import 'private_feature_route.dart';

/// Secret conversations — vault chats + server chats hidden from main list.
class HiddenChatsScreen extends ConsumerStatefulWidget {
  const HiddenChatsScreen({super.key});

  @override
  ConsumerState<HiddenChatsScreen> createState() => _HiddenChatsScreenState();
}

class _HiddenChatsScreenState extends ConsumerState<HiddenChatsScreen> {
  final _searchController = TextEditingController();
  final _vault = HiddenVaultSession.instance;
  String _query = '';
  Timer? _autolockTimer;

  @override
  void initState() {
    super.initState();
    _vault.addListener(_onVaultChanged);
    _searchController.addListener(
      () =>
          setState(() => _query = _searchController.text.trim().toLowerCase()),
    );
    _armAutolock();
  }

  Future<void> _armAutolock() async {
    _autolockTimer?.cancel();
    final duration = await HiddenChatsStore.instance.autolockDuration();
    if (!mounted) return;
    if (duration == Duration.zero) {
      // Lock as soon as the screen is left — handled in dispose.
      return;
    }
    _autolockTimer = Timer(duration, () {
      _vault.lock();
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    });
  }

  void _bumpAutolock() => unawaited(_armAutolock());

  @override
  void dispose() {
    _autolockTimer?.cancel();
    // immediately / leaving the section
    unawaited(
      HiddenChatsStore.instance.autolockDuration().then((d) {
        if (d == Duration.zero) _vault.lock();
      }),
    );
    _vault.removeListener(_onVaultChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onVaultChanged() {
    if (mounted) setState(() {});
  }

  List<HiddenChat> get _vaultFiltered {
    if (_query.isEmpty) return _vault.chats;
    return _vault.chats
        .where((c) => c.name.toLowerCase().contains(_query))
        .toList();
  }

  List<Conversation> get _serverFiltered {
    final controller = ref.read(appControllerProvider);
    final list = controller.secretHiddenConversations;
    if (_query.isEmpty) return list;
    return list
        .where(
          (c) => controller.conversationTitle(c).toLowerCase().contains(_query),
        )
        .toList();
  }

  String _vaultPreview(HiddenChat chat) {
    if (chat.messages.isEmpty) return 'Локальный vault · нет сообщений';
    return chat.messages.last.text;
  }

  @override
  Widget build(BuildContext context) {
    final serverHidden = _serverFiltered;
    final vaultChats = _vaultFiltered;
    final empty = serverHidden.isEmpty && vaultChats.isEmpty;

    return Listener(
      onPointerDown: (_) => _bumpAutolock(),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Скрытые чаты'),
          actions: [
            AppIconButton(
              icon: Icons.settings_outlined,
              onPressed: () => Navigator.of(context).push(
                privateSecretRoute((_) => const HiddenChatsSettingsScreen()),
              ),
            ),
            AppIconButton(
              icon: Icons.add,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const _NewVaultChatScreen()),
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.screenPadding,
                AppSpacing.md,
                AppSpacing.screenPadding,
                AppSpacing.sm,
              ),
              child: AppSearchField(
                controller: _searchController,
                hintText: 'Поиск в скрытых',
              ),
            ),
            Expanded(
              child: empty
                  ? const AppEmptyState(
                      icon: Icons.visibility_off_outlined,
                      title: 'Нет скрытых чатов',
                      subtitle:
                          'Скройте диалог в информации о чате или создайте vault-чат',
                    )
                  : ListView(
                      padding: const EdgeInsets.only(bottom: AppSpacing.xl),
                      children: [
                        if (serverHidden.isNotEmpty) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(
                              AppSpacing.screenPadding,
                              AppSpacing.sm,
                              AppSpacing.screenPadding,
                              4,
                            ),
                            child: Text(
                              'Зашифрованные диалоги',
                              style: context.textStyles.caption,
                            ),
                          ),
                          for (final conv in serverHidden)
                            _ServerHiddenTile(conversation: conv),
                        ],
                        if (vaultChats.isNotEmpty) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(
                              AppSpacing.screenPadding,
                              AppSpacing.md,
                              AppSpacing.screenPadding,
                              4,
                            ),
                            child: Text(
                              'Локальный vault',
                              style: context.textStyles.caption,
                            ),
                          ),
                          for (final chat in vaultChats)
                            AppTile(
                              leading: AppAvatar(label: chat.name),
                              title: chat.name,
                              subtitle: _vaultPreview(chat),
                              trailingText: formatTime(chat.updatedAt),
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => HiddenChatDialogScreen(
                                    chatId: chat.id,
                                    contactName: chat.name,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ServerHiddenTile extends ConsumerWidget {
  const _ServerHiddenTile({required this.conversation});

  final Conversation conversation;

  Future<void> _unhide(BuildContext context, WidgetRef ref) async {
    final controller = ref.read(appControllerProvider);
    final title = controller.conversationTitle(conversation);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Вернуть в основной список?'),
        content: Text('Чат «$title» снова появится на вкладке «Чаты».'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Вернуть'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(appControllerProvider).unhideConversation(conversation.id);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(appControllerProvider);
    final title = controller.conversationTitle(conversation);
    final last = controller.lastMessageFor(conversation.id);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
      child: Row(
        children: [
          Expanded(
            child: ChatListTile(
              title: title,
              subtitle: last != null
                  ? formatListPreview(
                      message: last,
                      controller: controller,
                      previewMode: 'Полный текст',
                    )
                  : 'Скрытый диалог',
              timeLabel: last != null
                  ? formatMessageTime(last.createdAt)
                  : null,
              isGroup: conversation.isGroup,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ChatScreen(conversation: conversation),
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.visibility_outlined),
            tooltip: 'Вернуть',
            onPressed: () => _unhide(context, ref),
          ),
        ],
      ),
    );
  }
}

class _NewVaultChatScreen extends StatefulWidget {
  const _NewVaultChatScreen();

  @override
  State<_NewVaultChatScreen> createState() => _NewVaultChatScreenState();
}

class _NewVaultChatScreenState extends State<_NewVaultChatScreen> {
  final _nameController = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_saving) return;
    setState(() => _saving = true);
    final chat = await HiddenVaultSession.instance.createChat(
      _nameController.text,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (chat == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Введите имя чата')));
      return;
    }
    Navigator.of(context).pop();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            HiddenChatDialogScreen(chatId: chat.id, contactName: chat.name),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Новый vault-чат'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _create,
            child: const Text('Создать'),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(AppSpacing.screenPadding),
        child: TextField(
          controller: _nameController,
          decoration: const InputDecoration(hintText: 'Имя или псевдоним'),
          onSubmitted: (_) => _create(),
        ),
      ),
    );
  }
}
