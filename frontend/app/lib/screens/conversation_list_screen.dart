import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/extensions/context_extensions.dart';
import '../models/conversation.dart';
import '../state/notification_settings.dart';
import '../state/app_controller.dart';
import '../theme/spacing.dart';
import '../theme/typography.dart';
import '../utils/message_format.dart';
import '../widgets/app_button.dart';
import '../widgets/app_text_field.dart';
import '../widgets/chat_list_tile.dart';
import '../utils/hidden_chats_access.dart';
import '../utils/favorites_chat.dart';
import '../services/chat_draft_store.dart';
import '../services/hidden_chats_store.dart';
import 'chat_screen.dart';
import 'new_chat_screen.dart';
import 'new_group_screen.dart';

class ConversationListScreen extends ConsumerStatefulWidget {
  const ConversationListScreen({super.key});

  @override
  ConsumerState<ConversationListScreen> createState() =>
      _ConversationListScreenState();
}

class _ConversationListScreenState
    extends ConsumerState<ConversationListScreen> {
  final _searchController = TextEditingController();
  String _query = '';
  String _secretCmd = '.скрытые';
  bool _gestureEntry = false;
  bool _secretCommandEntry = false;
  bool _hiddenEnabled = false;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(
      () => setState(() => _query = _searchController.text),
    );
    Future.microtask(() async {
      final controller = ref.read(appControllerProvider);
      await controller.refreshConversations();
      await controller.refreshFavoritesChat();
      for (final c in controller.conversations) {
        if (!controller.messagesByConversation.containsKey(c.id)) {
          await controller.loadHistory(c.id);
        }
        await ChatDraftStore.instance.get(c.id);
      }
      await controller.refreshHiddenChatsPolicies();
      _secretCmd = await HiddenChatsStore.instance.secretSearchCommand();
      _hiddenEnabled = controller.hiddenChatsEnabled;
      final method = controller.hiddenChatsOpenMethod;
      _gestureEntry = _hiddenEnabled && method == 'gesture';
      _secretCommandEntry = _hiddenEnabled && method == 'secret_command';
      if (mounted) setState(() {});
    });
  }

  bool get _isSecretCommand {
    if (!_secretCommandEntry) return false;
    return HiddenChatsStore.instance.matchesSecretCommand(_query, _secretCmd);
  }

  Future<void> _openHiddenChats() async {
    await HiddenChatsAccess.openWithPin(context);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _openNewChat() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const NewChatScreen()));
  }

  void _openNewGroup() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const NewGroupScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(appControllerProvider);
    final notifSettings = ref.watch(notificationSettingsProvider);
    final previewMode = notifSettings.effectivePreview;
    final conversations = controller.conversationsForList;
    final colors = context.colors;

    final filtered = _query.trim().isEmpty
        ? conversations
        : controller.conversationsMatchingSearch(_query);

    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onLongPress: _gestureEntry ? _openHiddenChats : null,
          child: const Text('Чаты'),
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.add_circle_outline),
            color: colors.surfaceElevated,
            onSelected: (value) {
              if (value == 'direct') {
                _openNewChat();
              } else {
                _openNewGroup();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'direct', child: Text('Новый чат')),
              PopupMenuItem(value: 'group', child: Text('Новая группа')),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        color: colors.primary,
        onRefresh: controller.refreshConversations,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.screenPadding,
                AppSpacing.smallGap,
                AppSpacing.screenPadding,
                AppSpacing.smallGap,
              ),
              child: AppTextField(
                controller: _searchController,
                hintText: 'Поиск',
                leading: Icon(
                  Icons.search_outlined,
                  color: colors.textMuted,
                  size: 20,
                ),
                onSubmitted: (v) {
                  if (_isSecretCommand) _openHiddenChats();
                },
              ),
            ),
            if (_isSecretCommand)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.screenPadding,
                  0,
                  AppSpacing.screenPadding,
                  AppSpacing.sm,
                ),
                child: AppButton(
                  label: 'Открыть скрытые чаты',
                  onPressed: _openHiddenChats,
                  expanded: false,
                ),
              ),
            Expanded(
              child: conversations.isEmpty
                  ? _EmptyState(onCreateChat: _openNewChat)
                  : filtered.isEmpty
                  ? ListView(
                      children: [
                        const SizedBox(height: 120),
                        Center(
                          child: Text(
                            'Ничего не найдено',
                            style: AppTypography.secondary,
                          ),
                        ),
                      ],
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(
                        bottom: AppSpacing.sectionGap,
                      ),
                      itemCount: filtered.length,
                      itemBuilder: (context, i) => _ConversationTile(
                        conversation: filtered[i],
                        previewMode: previewMode,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onCreateChat});
  final VoidCallback onCreateChat;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ListView(
      children: [
        const SizedBox(height: 100),
        Icon(
          Icons.lock_outline,
          size: 64,
          color: colors.primary.withValues(alpha: 0.6),
        ),
        const SizedBox(height: AppSpacing.largeGap),
        Text(
          'Пока нет чатов',
          textAlign: TextAlign.center,
          style: AppTypography.largeTitle,
        ),
        const SizedBox(height: AppSpacing.smallGap),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sectionGap * 2,
          ),
          child: Text(
            'Создайте защищённый диалог — переписка шифруется на устройстве.',
            textAlign: TextAlign.center,
            style: AppTypography.secondary,
          ),
        ),
        const SizedBox(height: AppSpacing.sectionGap),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sectionGap * 2,
          ),
          child: AppButton(label: 'Создать чат', onPressed: onCreateChat),
        ),
      ],
    );
  }
}

class _ConversationTile extends ConsumerWidget {
  const _ConversationTile({
    required this.conversation,
    required this.previewMode,
  });
  final Conversation conversation;
  final String previewMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(appControllerProvider);
    final isFavorites = FavoritesChat.isId(conversation.id);
    final title = controller.conversationTitle(conversation);
    final last = controller.lastMessageForListPreview(conversation.id);
    final unread = isFavorites
        ? 0
        : (controller.unreadCounts[conversation.id] ?? 0);
    final isMuted = controller.chatMuted[conversation.id] ?? false;
    final reachable = controller.isConversationReachable(conversation);

    String subtitle;
    final draftPreview = isFavorites
        ? ''
        : ChatDraftStore.instance.previewFor(conversation.id);
    if (isFavorites) {
      subtitle = last != null
          ? '${last.plaintext ?? '…'}${last.favoriteSourceTitle != null ? ' · ${last.favoriteSourceTitle}' : ''}'
          : 'Сохранённые сообщения';
    } else if (draftPreview.isNotEmpty) {
      subtitle = 'Черновик: $draftPreview';
    } else if (!reachable) {
      subtitle = 'Собеседник не найден — создайте чат заново';
    } else if (last == null) {
      subtitle = conversation.isGroup
          ? 'Группа · ${conversation.participantUserIds.length} участников'
          : 'Начните переписку';
    } else {
      final prefix = last.senderUserId == controller.session?.userId
          ? 'Вы: '
          : '';
      subtitle =
          '$prefix${formatListPreview(message: last, controller: controller, previewMode: previewMode)}';
    }

    String? peerId;
    if (!conversation.isGroup) {
      for (final id in conversation.participantUserIds) {
        if (id != controller.session?.userId) {
          peerId = id;
          break;
        }
      }
    }
    final isOnline = peerId != null && controller.isContactOnline(peerId);

    return ChatListTile(
      title: title,
      subtitle: subtitle,
      timeLabel: last != null ? formatMessageTime(last.createdAt) : null,
      unreadCount: unread,
      isOnline: isFavorites ? false : isOnline,
      isGroup: conversation.isGroup,
      isMuted: isMuted,
      unreachable: !reachable,
      avatarLabel: isFavorites ? '★' : null,
      onTap: () async {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ChatScreen(conversation: conversation),
          ),
        );
        if (!isFavorites) {
          await ref
              .read(appControllerProvider)
              .recomputeUnread(conversation.id);
        }
      },
    );
  }
}
