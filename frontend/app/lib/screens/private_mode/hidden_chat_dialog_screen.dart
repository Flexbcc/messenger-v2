import 'package:flutter/material.dart';

import '../../core/extensions/context_extensions.dart';
import '../../models/hidden_chat.dart';
import '../../services/hidden_vault_session.dart';
import '../../theme/spacing.dart';
import '../../theme/typography.dart';
import '../../utils/format.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/avatar.dart';
import 'panic.dart';

enum _DisappearingTimer { off, oneHour, oneDay, oneWeek }

extension on _DisappearingTimer {
  String get storageKey => switch (this) {
    _DisappearingTimer.off => 'off',
    _DisappearingTimer.oneHour => 'oneHour',
    _DisappearingTimer.oneDay => 'oneDay',
    _DisappearingTimer.oneWeek => 'oneWeek',
  };

  String get label => switch (this) {
    _DisappearingTimer.off => 'Выкл',
    _DisappearingTimer.oneHour => '1 час',
    _DisappearingTimer.oneDay => '1 день',
    _DisappearingTimer.oneWeek => '1 неделя',
  };
}

_DisappearingTimer _timerFromKey(String key) => switch (key) {
  'oneHour' => _DisappearingTimer.oneHour,
  'oneDay' => _DisappearingTimer.oneDay,
  'oneWeek' => _DisappearingTimer.oneWeek,
  _ => _DisappearingTimer.off,
};

/// Hidden conversation backed by the encrypted local vault.
class HiddenChatDialogScreen extends StatefulWidget {
  const HiddenChatDialogScreen({
    super.key,
    required this.chatId,
    required this.contactName,
  });

  final String chatId;
  final String contactName;

  @override
  State<HiddenChatDialogScreen> createState() => _HiddenChatDialogScreenState();
}

class _HiddenChatDialogScreenState extends State<HiddenChatDialogScreen> {
  final _vault = HiddenVaultSession.instance;
  final _controller = TextEditingController();
  _DisappearingTimer _timer = _DisappearingTimer.off;

  @override
  void initState() {
    super.initState();
    _vault.addListener(_onVaultChanged);
    _syncTimer();
  }

  @override
  void dispose() {
    _vault.removeListener(_onVaultChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onVaultChanged() {
    if (mounted) {
      _syncTimer();
      setState(() {});
    }
  }

  void _syncTimer() {
    final chat = _vault.chatById(widget.chatId);
    if (chat != null) {
      _timer = _timerFromKey(chat.disappearingTimer);
    }
  }

  HiddenChat? get _chat => _vault.chatById(widget.chatId);

  Future<void> _send() async {
    final text = _controller.text;
    if (text.trim().isEmpty) return;
    await _vault.addMessage(chatId: widget.chatId, text: text, isMine: true);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final messages = _chat?.messages ?? const <HiddenMessage>[];
    final colors = context.colors;

    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        backgroundColor: colors.background,
        elevation: 0,
        foregroundColor: colors.textPrimary,
        titleSpacing: 0,
        title: Row(
          children: [
            AppAvatar(label: widget.contactName, size: AppAvatarSize.small),
            const SizedBox(width: AppSpacing.smallGap),
            Text(widget.contactName, style: AppTypography.title),
          ],
        ),
        actions: [
          PopupMenuButton<_DisappearingTimer>(
            icon: const Icon(Icons.timer_outlined),
            tooltip: 'Исчезающие сообщения',
            initialValue: _timer,
            onSelected: (v) async {
              setState(() => _timer = v);
              await _vault.setDisappearingTimer(widget.chatId, v.storageKey);
            },
            itemBuilder: (context) => _DisappearingTimer.values
                .map((t) => PopupMenuItem(value: t, child: Text(t.label)))
                .toList(),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              if (value == 'quick_exit') panicExit(context);
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'quick_exit', child: Text('Быстрый выход')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (_timer != _DisappearingTimer.off)
            Container(
              width: double.infinity,
              color: colors.surfaceElevated,
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.screenPadding,
                vertical: AppSpacing.smallGap,
              ),
              child: Text(
                'Исчезающие сообщения: ${_timer.label}',
                style: AppTypography.caption,
              ),
            ),
          Expanded(
            child: messages.isEmpty
                ? const Center(
                    child: Text(
                      'Напишите первое сообщение',
                      style: AppTypography.secondary,
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(AppSpacing.screenPadding),
                    itemCount: messages.length,
                    itemBuilder: (context, i) => _Bubble(message: messages[i]),
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.screenPadding),
              child: AppTextField(
                controller: _controller,
                hintText: 'Сообщение',
                trailing: GestureDetector(
                  onTap: _send,
                  child: Icon(Icons.send, color: colors.primary),
                ),
                onSubmitted: (_) => _send(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message});

  final HiddenMessage message;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final bubbleColor = message.isMine
        ? colors.chatOutgoingStart
        : colors.chatIncoming;
    final textColor = colors.textPrimary;

    return Align(
      alignment: message.isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: AppSpacing.smallGap),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.mediumGap,
          vertical: AppSpacing.smallGap,
        ),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.circular(AppRadii.medium),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message.text,
              style: AppTypography.body.copyWith(color: textColor),
            ),
            const SizedBox(height: 2),
            Text(
              formatTime(message.createdAt),
              style: AppTypography.caption.copyWith(color: colors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}
