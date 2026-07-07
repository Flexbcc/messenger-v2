import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../calls/call_signal.dart';
import '../models/conversation.dart';
import '../models/message.dart';
import '../models/chat_draft.dart';
import '../services/chat_draft_store.dart';
import '../services/message_delivery_store.dart';
import '../state/app_controller.dart';
import '../theme/app_decorations.dart';
import '../theme/spacing.dart';
import '../theme/typography.dart';
import '../utils/api_errors.dart';
import '../utils/message_format.dart';
import '../utils/favorites_chat.dart';
import '../utils/message_delivery_status.dart';
import '../utils/message_grouping.dart';
import '../core/ui/typing_indicator.dart';
import '../core/platform/platform_capabilities.dart';
import '../widgets/chat/chat_message_bubble.dart';
import '../widgets/chat/time_action_sheets.dart';
import '../widgets/avatar.dart';
import 'chat_info_screen.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({
    super.key,
    required this.conversation,
    this.scrollToMessageId,
  });
  final Conversation conversation;
  final String? scrollToMessageId;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  bool _loadingHistory = true;
  bool _sending = false;
  final bool _showTyping = false;
  ChatMessage? _replyTo;
  AppController? _controller;
  Timer? _draftTimer;
  String? _draftAttachmentName;
  String? _highlightMessageId;
  final _messageKeys = <String, GlobalKey>{};

  GlobalKey _keyForMessage(String messageId) =>
      _messageKeys.putIfAbsent(messageId, GlobalKey.new);

  bool get _isFavoritesChat => FavoritesChat.isId(widget.conversation.id);

  @override
  void initState() {
    super.initState();
    _controller = ref.read(appControllerProvider);
    _controller!.setActiveConversation(widget.conversation.id);
    _controller!.loadChatPreferences(widget.conversation.id);
    _textController.addListener(_onDraftChanged);
    Future.microtask(() async {
      await _loadDraft();
      await _controller!.loadHistory(widget.conversation.id);
      await MessageDeliveryStore.instance.loadPeerRead(widget.conversation.id);
      await _controller!.markConversationRead(widget.conversation.id);
      if (!_isFavoritesChat) {
        await _controller!.validateConversationReachability(widget.conversation);
      }
      if (mounted) setState(() => _loadingHistory = false);
      if (widget.scrollToMessageId != null) {
        _scrollToMessageId(widget.scrollToMessageId);
      } else {
        _scrollToBottom();
      }
    });
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    _persistDraft();
    _controller?.setActiveConversation(null);
    _textController.removeListener(_onDraftChanged);
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadDraft() async {
    final draft = await ChatDraftStore.instance.get(widget.conversation.id);
    if (!mounted || draft.isEmpty) return;
    _textController.text = draft.text;
    _draftAttachmentName = draft.attachmentName;
    if (draft.replyToMessageId != null && draft.replyPreview != null) {
      setState(() {
        _replyTo = ChatMessage(
          id: draft.replyToMessageId!,
          conversationId: widget.conversation.id,
          senderUserId: '',
          senderDeviceId: null,
          ciphertext: '',
          contentType: 'text',
          cryptoVersion: 'draft',
          createdAt: DateTime.now(),
          plaintext: draft.replyPreview,
        );
      });
    }
  }

  void _onDraftChanged() {
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 400), _persistDraft);
  }

  Future<void> _persistDraft() async {
    final draft = ChatDraft(
      text: _textController.text,
      replyToMessageId: _replyTo?.id,
      replyPreview: _replyTo?.plaintext,
      attachmentName: _draftAttachmentName,
    );
    await ChatDraftStore.instance.save(widget.conversation.id, draft);
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 50), () {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  void _scrollToMessageId(String? messageId) {
    if (messageId == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final key = _messageKeys[messageId];
      final ctx = key?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOut,
          alignment: 0.35,
        );
        setState(() => _highlightMessageId = messageId);
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) setState(() => _highlightMessageId = null);
        });
        return;
      }
      final messages = ref.read(appControllerProvider).visibleMessagesFor(widget.conversation.id);
      if (!messages.any((m) => m.id == messageId) && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Сообщение не найдено в загруженной истории')),
        );
      }
    });
  }

  Future<void> _openSourceMessage(ChatMessage favorite) async {
    final controller = ref.read(appControllerProvider);
    final convId = favorite.favoriteSourceConversationId;
    final msgId = favorite.favoriteSourceMessageId;
    if (convId == null || msgId == null) return;
    final conv = controller.conversationById(convId);
    if (conv == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Исходный чат не найден')),
        );
      }
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(conversation: conv, scrollToMessageId: msgId),
      ),
    );
  }

  void _openFavoriteItemActions(ChatMessage message) {
    final controller = ref.read(appControllerProvider);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: const Text('Перейти к сообщению'),
              subtitle: Text(message.favoriteSourceTitle ?? 'Исходный чат'),
              onTap: () {
                Navigator.pop(context);
                _openSourceMessage(message);
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: const Text('Копировать'),
              onTap: () {
                Navigator.pop(context);
                final body = messageDisplayBody(message);
                Clipboard.setData(ClipboardData(text: body));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Текст скопирован')),
                );
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
              title: Text('Удалить из избранного', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () async {
                Navigator.pop(context);
                await controller.removeFavorite(message.id);
              },
            ),
          ],
        ),
      ),
    );
  }

  bool get _canSend {
    final c = ref.read(appControllerProvider);
    return c.isConversationReachable(widget.conversation) && c.canSendMessages;
  }

  Future<void> _reload() async {
    setState(() => _loadingHistory = true);
    await ref.read(appControllerProvider).loadHistory(widget.conversation.id);
    await ref.read(appControllerProvider).markConversationRead(widget.conversation.id);
    if (mounted) {
      setState(() => _loadingHistory = false);
      _scrollToBottom();
    }
  }

  Future<void> _scheduleText() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _sending) return;
    final when = await showSchedulePicker(context);
    if (when == null) return;
    try {
      await ref.read(appControllerProvider).scheduleTextMessage(
            conversation: widget.conversation,
            text: text,
            sendAt: when,
            replyToMessageId: _replyTo?.id,
            replyPreview: _replyTo?.plaintext,
          );
      _textController.clear();
      _draftAttachmentName = null;
      setState(() => _replyTo = null);
      await ChatDraftStore.instance.clear(widget.conversation.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Отложено на ${formatMessageTime(when)}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось отложить: ${friendlyApiError(e)}')));
      }
    }
  }

  void _openMessageActions(ChatMessage message) {
    if (_isFavoritesChat) {
      _openFavoriteItemActions(message);
      return;
    }
    final controller = ref.read(appControllerProvider);
    final isMine = message.senderUserId == controller.session?.userId;
    showMessageActionsSheet(
      context: context,
      message: message,
      isMine: isMine,
      isPinned: controller.isMessagePinned(message.id),
      conversationTitle: controller.conversationTitle(widget.conversation),
      onReply: () => setState(() => _replyTo = message),
      onFavorite: () async {
        await controller.addFavoriteMessage(widget.conversation, message);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Добавлено в чат «Избранное»')),
          );
        }
      },
      onReminder: (when) => controller.addMessageReminder(
        conversation: widget.conversation,
        message: message,
        remindAt: when,
      ),
      onDelete: () async {
        await controller.hideMessageLocally(message.id);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Сообщение скрыто на этом устройстве')),
          );
        }
      },
      onForward: () async {
        final target = await showForwardTargetPicker(
          context,
          conversations: controller.sortedConversations,
          currentConversationId: widget.conversation.id,
          titleFor: controller.conversationTitle,
        );
        if (target == null || !mounted) return;
        try {
          await controller.forwardMessage(message, target);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Переслано в «${controller.conversationTitle(target)}»')),
            );
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Не удалось переслать: ${friendlyApiError(e)}')),
            );
          }
        }
      },
      onTogglePin: () async {
        await controller.toggleMessagePinned(message.id);
      },
      onEdit: isMine && message.contentType == 'text'
          ? () {
              _textController.text = message.plaintext ?? '';
              _textController.selection = TextSelection.collapsed(offset: _textController.text.length);
              setState(() => _replyTo = null);
            }
          : null,
    );
  }

  Future<void> _sendText() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await ref.read(appControllerProvider).sendText(
            widget.conversation,
            text,
            replyToMessageId: _replyTo?.id,
            replyPreview: _replyTo != null ? messageDisplayBody(_replyTo!) : null,
          );
      _textController.clear();
      _draftAttachmentName = null;
      setState(() => _replyTo = null);
      await ChatDraftStore.instance.clear(widget.conversation.id);
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось отправить: ${friendlyApiError(e)}')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _retryMessage(ChatMessage message) async {
    setState(() => _sending = true);
    try {
      await ref.read(appControllerProvider).retryFailedMessage(widget.conversation, message.id);
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Повтор не удался: ${friendlyApiError(e)}')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _startCall(CallKind kind) async {
    if (widget.conversation.isGroup) return;
    if (PlatformCapabilities.callsNeedSecureContext && Uri.base.scheme != 'https') {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Звонки в браузере работают только по HTTPS. Откройте PWA через https://…'),
          ),
        );
      }
      return;
    }
    final controller = ref.read(appControllerProvider);
    final peerUserId = widget.conversation.participantUserIds.firstWhere((id) => id != controller.session!.userId);
    try {
      await controller.startCall(peerUserId: peerUserId, kind: kind);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось начать звонок: ${friendlyApiError(e)}')));
      }
    }
  }

  Future<void> _pickAndSendImage() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
    final file = result?.files.single;
    if (file?.bytes == null) return;
    setState(() => _sending = true);
    try {
      await ref.read(appControllerProvider).sendImage(
            widget.conversation,
            file!.bytes!,
            file.name,
            'image/${file.extension ?? 'jpeg'}',
          );
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось отправить фото: ${friendlyApiError(e)}')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _showChatGesturesHelp() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.screenPadding),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Действия с сообщениями', style: AppTypography.title),
              const SizedBox(height: AppSpacing.md),
              const Text('• Долгое нажатие или правый клик — полное меню'),
              const Text('• Свайп влево/вправо — ответить'),
              const SizedBox(height: AppSpacing.sm),
              const Text('В меню: избранное, переслать, закрепить, напомнить, удалить у меня.'),
              const SizedBox(height: AppSpacing.md),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(appControllerProvider);
    final title = controller.conversationTitle(widget.conversation);
    final messages = controller.visibleMessagesFor(widget.conversation.id);
    final layouts = buildMessageLayouts(messages);
    final isMuted = controller.chatMuted[widget.conversation.id] ?? false;
    final reachable = controller.isConversationReachable(widget.conversation);
    final reachError = controller.reachabilityErrorFor(widget.conversation);
    final wsOnline = controller.canSendMessages;
    String? peerId;
    if (!widget.conversation.isGroup) {
      for (final id in widget.conversation.participantUserIds) {
        if (id != controller.session?.userId) {
          peerId = id;
          break;
        }
      }
    }
    final peerOnline = peerId != null && controller.isContactOnline(peerId);

    // Scroll when new messages arrive while this chat is open.
    ref.listen(appControllerProvider, (prev, next) {
      final prevLen = prev?.visibleMessagesFor(widget.conversation.id).length ?? 0;
      final nextLen = next.visibleMessagesFor(widget.conversation.id).length;
      if (nextLen > prevLen) {
        _scrollToBottom();
        next.markConversationRead(widget.conversation.id);
      }
    });

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          onTap: _isFavoritesChat
              ? null
              : () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => ChatInfoScreen(conversation: widget.conversation)),
                  ),
          child: Row(
            children: [
              AppAvatar(
                label: _isFavoritesChat ? '★' : title,
                isGroup: widget.conversation.isGroup,
                size: AppAvatarSize.small,
              ),
              const SizedBox(width: AppSpacing.smallGap),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title, overflow: TextOverflow.ellipsis, style: AppTypography.title),
                    if (_isFavoritesChat)
                      Text('Нажмите на источник под сообщением', style: AppTypography.caption.copyWith(fontSize: 11))
                    else if (isMuted)
                      Text('Уведомления выключены', style: AppTypography.caption.copyWith(fontSize: 11)),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (!_isFavoritesChat) ...[
            IconButton(
              icon: const Icon(Icons.touch_app_outlined),
              tooltip: 'Действия с сообщениями',
              onPressed: _showChatGesturesHelp,
            ),
            if (!widget.conversation.isGroup) ...[
              IconButton(
                icon: const Icon(Icons.call_outlined),
                onPressed: controller.currentCall != null ? null : () => _startCall(CallKind.audio),
              ),
              IconButton(
                icon: const Icon(Icons.videocam_outlined),
                onPressed: controller.currentCall != null ? null : () => _startCall(CallKind.video),
              ),
            ],
          ],
        ],
      ),
      body: Column(
        children: [
          if (!reachable && reachError != null)
            Material(
              color: AppColors.dangerRed.withValues(alpha: 0.12),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.screenPadding),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '$reachError\n\nСоздайте новый чат с правильным User ID (Настройки → Аккаунт у собеседника). '
                      'Старые чаты с неверным ID работать не будут.',
                      style: AppTypography.caption.copyWith(color: AppColors.dangerRed),
                    ),
                    const SizedBox(height: AppSpacing.smallGap),
                    TextButton(
                      onPressed: () async {
                        await ref.read(appControllerProvider).hideConversationLocally(widget.conversation.id);
                        if (context.mounted) Navigator.of(context).pop();
                      },
                      child: Text('Скрыть этот чат', style: AppTypography.caption.copyWith(color: AppColors.dangerRed)),
                    ),
                  ],
                ),
              ),
            )
          else if (reachable && !wsOnline)
            Material(
              color: AppColors.warningYellow.withValues(alpha: 0.12),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding, vertical: AppSpacing.smallGap),
                child: Text(
                  'Нет соединения — отправка недоступна. Проверьте сеть или переподключитесь в «Состояние соединения».',
                  style: AppTypography.caption,
                ),
              ),
            ),
          Expanded(
            child: RefreshIndicator(
              color: AppColors.accentBlue,
              onRefresh: _reload,
              child: _loadingHistory
                  ? ListView(
                      children: const [SizedBox(height: 200), Center(child: CircularProgressIndicator(color: AppColors.textPrimary))],
                    )
                  : messages.isEmpty
                      ? ListView(
                          children: [
                            const SizedBox(height: 120),
                            Center(
                              child: Text(
                                _isFavoritesChat
                                    ? 'Пока пусто.\nДолгое нажатие на сообщение в любом чате → «В избранное»'
                                    : 'Нет сообщений',
                                textAlign: TextAlign.center,
                                style: AppTypography.caption,
                              ),
                            ),
                          ],
                        )
                      : ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.all(AppSpacing.mediumGap),
                          itemCount: layouts.length,
                          itemBuilder: (context, i) {
                            final layout = layouts[i];
                            final message = layout.message;
                            final isMine = message.senderUserId == controller.session?.userId;
                            final isLastOutgoing = isMine &&
                                messages.where((m) => m.senderUserId == controller.session?.userId).lastOrNull?.id ==
                                    message.id;
                            final status = deliveryStatusFor(
                              messageId: message.id,
                              conversationId: widget.conversation.id,
                              isMine: isMine,
                              isLastOutgoingInChat: isLastOutgoing,
                              messageCreatedAt: message.createdAt,
                              peerOnline: peerOnline,
                            );
                            return KeyedSubtree(
                              key: _keyForMessage(message.id),
                              child: Column(
                                children: [
                                  if (layout.showDateSeparator)
                                    ChatTimeSeparator(label: formatDateSeparator(message.createdAt)),
                                  if (layout.showPauseSeparator)
                                    ChatPauseSeparator(time: message.createdAt),
                                  ChatMessageBubble(
                                  message: message,
                                  isMine: isMine,
                                  layout: layout,
                                  isPinned: controller.isMessagePinned(message.id),
                                  highlighted: _highlightMessageId == message.id,
                                  deliveryStatus: status,
                                  deliveryError: deliveryErrorFor(message.id),
                                  onReply: _isFavoritesChat ? null : () => setState(() => _replyTo = message),
                                  onLongPress: () => _openMessageActions(message),
                                  onOpenFavoriteSource: message.favoriteSourceConversationId != null
                                      ? () => _openSourceMessage(message)
                                      : null,
                                  onRetryFailed: status == MessageDeliveryStatus.failed && isMine
                                      ? () => _retryMessage(message)
                                      : null,
                                ),
                              ],
                            ),
                            );
                          },
                        ),
            ),
          ),
          if (_showTyping) const TypingIndicator(),
          if (!_isFavoritesChat)
            SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_replyTo != null)
                  Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: AppColors.card,
                      border: Border(top: BorderSide(color: AppColors.divider)),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding, vertical: AppSpacing.smallGap),
                    child: Row(
                      children: [
                        Container(width: 3, height: 32, decoration: BoxDecoration(gradient: AppDecorations.accentGradient, borderRadius: BorderRadius.circular(2))),
                        const SizedBox(width: AppSpacing.smallGap),
                        Expanded(
                          child: Text(
                            _replyTo != null ? messageDisplayBody(_replyTo!) : '…',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.caption,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, size: 18, color: AppColors.textMuted),
                          onPressed: () => setState(() => _replyTo = null),
                        ),
                      ],
                    ),
                  ),
                Container(
                  decoration: const BoxDecoration(
                    color: AppColors.backgroundElevated,
                    border: Border(top: BorderSide(color: AppColors.divider)),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.smallGap,
                    vertical: AppSpacing.smallGap,
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.schedule_outlined, color: AppColors.textSecondary),
                        onPressed: !_canSend || _sending ? null : _scheduleText,
                      ),
                      IconButton(
                        icon: const Icon(Icons.attach_file, color: AppColors.textSecondary),
                        onPressed: !_canSend || _sending ? null : _pickAndSendImage,
                      ),
                      Expanded(
                        child: SizedBox(
                          height: AppSpacing.inputHeight,
                          child: TextField(
                            controller: _textController,
                            enabled: _canSend && !_sending,
                            style: AppTypography.body,
                            decoration: InputDecoration(
                              hintText: !reachable
                                  ? 'Чат недоступен'
                                  : !wsOnline
                                      ? 'Нет соединения'
                                      : 'Сообщение',
                              hintStyle: AppTypography.body.copyWith(color: AppColors.textMuted),
                              filled: true,
                              fillColor: AppColors.card,
                              contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.mediumGap),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(AppRadii.large),
                                borderSide: BorderSide.none,
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(AppRadii.large),
                                borderSide: const BorderSide(color: AppColors.divider),
                              ),
                            ),
                            onSubmitted: (_) => _sendText(),
                            textInputAction: TextInputAction.send,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.smallGap),
                      IconButton(
                        icon: const Icon(Icons.arrow_upward, size: 20),
                        style: IconButton.styleFrom(
                          backgroundColor: AppColors.accentBlue,
                          foregroundColor: AppColors.textMain,
                          disabledBackgroundColor: AppColors.cardSecondary,
                          disabledForegroundColor: AppColors.textMuted,
                        ),
                        onPressed: !_canSend || _sending ? null : _sendText,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
