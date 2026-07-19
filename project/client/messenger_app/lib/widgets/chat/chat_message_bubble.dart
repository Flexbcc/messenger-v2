import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/message.dart';
import '../../services/autodownload_policy.dart';
import 'duress_signal_banner.dart';
import '../../state/app_controller.dart';
import '../../theme/app_decorations.dart';
import '../../theme/spacing.dart';
import '../../theme/typography.dart';
import '../../utils/message_format.dart';
import '../../utils/message_delivery_status.dart';
import '../../utils/message_grouping.dart';
import 'trust_aware_message_text.dart';

class ChatTimeSeparator extends StatelessWidget {
  const ChatTimeSeparator({super.key, required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.smallGap),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: AppColors.cardSecondary,
            borderRadius: BorderRadius.circular(AppRadii.medium),
          ),
          child: Text(label, style: AppTypography.caption),
        ),
      ),
    );
  }
}

class ChatPauseSeparator extends StatelessWidget {
  const ChatPauseSeparator({super.key, required this.time});
  final DateTime time;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.smallGap / 2),
      child: Center(
        child: Text(formatMessageTime(time), style: AppTypography.caption.copyWith(fontSize: 11)),
      ),
    );
  }
}

class ChatMessageBubble extends ConsumerStatefulWidget {
  const ChatMessageBubble({
    super.key,
    required this.message,
    required this.isMine,
    required this.layout,
    this.onReply,
    this.onLongPress,
    this.deliveryStatus,
    this.deliveryError,
    this.onRetryFailed,
    this.isPinned = false,
    this.highlighted = false,
    this.onOpenFavoriteSource,
  });

  final ChatMessage message;
  final bool isMine;
  final MessageGroupLayout layout;
  final VoidCallback? onReply;
  final VoidCallback? onLongPress;
  final MessageDeliveryStatus? deliveryStatus;
  final String? deliveryError;
  final VoidCallback? onRetryFailed;
  final bool isPinned;
  final bool highlighted;
  final VoidCallback? onOpenFavoriteSource;

  @override
  ConsumerState<ChatMessageBubble> createState() => _ChatMessageBubbleState();
}

class _ChatMessageBubbleState extends ConsumerState<ChatMessageBubble> with SingleTickerProviderStateMixin {
  late final AnimationController _enterController;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _enterController = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
    _fade = CurvedAnimation(parent: _enterController, curve: Curves.easeOut);
    _slide = Tween<Offset>(begin: const Offset(0, 0.08), end: Offset.zero).animate(_fade);
    _enterController.forward();
  }

  @override
  void dispose() {
    _enterController.dispose();
    super.dispose();
  }

  Widget _replyQuote(String preview, Color textColor) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: textColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: AppColors.accentBlue, width: 3)),
      ),
      child: Text(
        preview,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: AppTypography.caption.copyWith(color: textColor.withValues(alpha: 0.85)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final systemKind = widget.message.systemKind;
    final duressCode = widget.message.duressCode ??
        (systemKind != null && systemKind != 'duress' ? duressCodeFromLegacyKind(systemKind) : null) ??
        (systemKind == 'duress' ? widget.message.duressCode : null);

    if (systemKind == 'duress' || duressCode != null) {
      return DuressSignalBanner(
        code: duressCode ?? 0,
        text: widget.message.plaintext,
      );
    }

    final layout = widget.layout;
    final isMine = widget.isMine;
    final textColor = isMine ? AppColors.chatOutgoingText : AppColors.chatIncomingText;
    final radius = messageBubbleBorderRadius(
      isMine: isMine,
      isFirstInGroup: layout.isFirstInGroup,
      isLastInGroup: layout.isLastInGroup,
    );

    final bubbleDecoration = isMine
        ? BoxDecoration(
            gradient: AppDecorations.outgoingBubbleGradient,
            borderRadius: radius,
            border: widget.highlighted ? Border.all(color: AppColors.accentBlue, width: 2) : null,
          )
        : BoxDecoration(
            color: AppColors.chatIncoming,
            borderRadius: radius,
            border: widget.highlighted ? Border.all(color: AppColors.accentBlue, width: 2) : null,
          );

    final verticalMargin = layout.isMiddleInGroup
        ? 1.5
        : layout.isLastInGroup && !layout.isFirstInGroup
            ? 2.0
            : 4.0;

    Widget content;
    if (widget.message.decryptFailed) {
      content = Text(
        '🔒 не удалось расшифровать',
        style: AppTypography.body.copyWith(color: textColor, fontStyle: FontStyle.italic),
      );
    } else if (widget.message.contentType == 'image' && widget.message.plaintext != null) {
      content = _ImageBubbleContent(message: widget.message, textColor: textColor);
    } else {
      final trust = ref.watch(appControllerProvider).trustLevelFor(widget.message.senderUserId);
      final body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.message.replyPreview != null && widget.message.replyPreview!.isNotEmpty)
            _replyQuote(widget.message.replyPreview!, textColor),
          TrustAwareMessageText(
            text: widget.message.plaintext ?? '…',
            style: AppTypography.body.copyWith(color: textColor),
            trust: trust,
          ),
        ],
      );
      content = body;
    }

    if (widget.message.favoriteSourceTitle != null && widget.onOpenFavoriteSource != null) {
      final sender = widget.message.favoriteSenderLabel;
      final sourceLabel = widget.message.favoriteSourceTitle!;
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          content,
          const SizedBox(height: 8),
          InkWell(
            onTap: widget.onOpenFavoriteSource,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.open_in_new, size: 14, color: textColor.withValues(alpha: 0.75)),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      sender != null && sender.isNotEmpty
                          ? 'Из «$sourceLabel» · $sender'
                          : 'Из «$sourceLabel»',
                      style: AppTypography.micro.copyWith(
                        color: AppColors.accentBlue,
                        decoration: TextDecoration.underline,
                        decorationColor: AppColors.accentBlue.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    final timeLabel = formatMessageTime(widget.message.createdAt);

    final bubble = Container(
      margin: EdgeInsets.only(top: layout.isFirstInGroup ? 4 : verticalMargin, bottom: verticalMargin),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.76),
      decoration: bubbleDecoration,
      child: layout.showGroupTime
            ? Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Flexible(child: content),
                  const SizedBox(width: 8),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.isPinned) ...[
                        Icon(Icons.push_pin, size: 12, color: textColor.withValues(alpha: 0.7)),
                        const SizedBox(width: 3),
                      ],
                      Text(
                        timeLabel,
                        style: AppTypography.micro.copyWith(
                          color: isMine ? AppColors.textMain.withValues(alpha: 0.75) : AppColors.textMuted,
                        ),
                      ),
                      if (isMine) ...[
                        const SizedBox(width: 3),
                        Tooltip(
                          message: widget.deliveryStatus == MessageDeliveryStatus.failed
                              ? (widget.deliveryError != null
                                  ? '${widget.deliveryError}\nНажмите, чтобы повторить'
                                  : 'Не отправлено. Нажмите, чтобы повторить')
                              : deliveryStatusLabel(widget.deliveryStatus ?? MessageDeliveryStatus.sent),
                          child: GestureDetector(
                            onTap: widget.deliveryStatus == MessageDeliveryStatus.failed
                                ? widget.onRetryFailed
                                : null,
                            behavior: HitTestBehavior.opaque,
                            child: Icon(
                              statusIcon(widget.deliveryStatus ?? MessageDeliveryStatus.sent),
                              size: 14,
                              color: (widget.deliveryStatus == MessageDeliveryStatus.read
                                      ? AppColors.primary
                                      : widget.deliveryStatus == MessageDeliveryStatus.failed
                                          ? AppColors.dangerRed
                                          : AppColors.textMain)
                                  .withValues(alpha: statusIconOpacity(widget.deliveryStatus ?? MessageDeliveryStatus.sent)),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              )
            : content,
    );

    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: Align(
          alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: widget.onLongPress,
            onSecondaryTap: widget.onLongPress,
            child: ReplySwipeWrapper(
              onReply: widget.onReply,
              child: bubble,
            ),
          ),
        ),
      ),
    );
  }
}

class ReplySwipeWrapper extends StatefulWidget {
  const ReplySwipeWrapper({super.key, required this.child, this.onReply});
  final Widget child;
  final VoidCallback? onReply;

  @override
  State<ReplySwipeWrapper> createState() => _ReplySwipeWrapperState();
}

class _ReplySwipeWrapperState extends State<ReplySwipeWrapper> {
  double _drag = 0;

  @override
  Widget build(BuildContext context) {
    if (widget.onReply == null) return widget.child;
    return GestureDetector(
      onHorizontalDragUpdate: (d) => setState(() => _drag = (_drag + d.delta.dx).clamp(-72.0, 72.0)),
      onHorizontalDragEnd: (_) {
        if (_drag.abs() > 48) widget.onReply!();
        setState(() => _drag = 0);
      },
      child: Transform.translate(
        offset: Offset(_drag * 0.35, 0),
        child: widget.child,
      ),
    );
  }
}

class _ImageBubbleContent extends ConsumerStatefulWidget {
  const _ImageBubbleContent({required this.message, required this.textColor});
  final ChatMessage message;
  final Color textColor;

  @override
  ConsumerState<_ImageBubbleContent> createState() => _ImageBubbleContentState();
}

class _ImageBubbleContentState extends ConsumerState<_ImageBubbleContent> {
  Uint8List? _bytes;
  bool _loading = true;
  bool _blocked = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool force = false}) async {
    setState(() {
      _loading = true;
      _blocked = false;
    });
    final trust = ref.read(appControllerProvider).trustLevelFor(widget.message.senderUserId);
    if (!trust.allowsFilePreview && !force) {
      if (mounted) {
        setState(() {
          _blocked = true;
          _loading = false;
        });
      }
      return;
    }
    final allowed = force || await AutodownloadPolicy.instance.shouldDownloadForSender(MediaKind.photos, trust);
    if (!allowed) {
      if (mounted) {
        setState(() {
          _blocked = true;
          _loading = false;
        });
      }
      return;
    }
    try {
      final bytes = await ref.read(appControllerProvider).resolveImageBytes(widget.message, forceDownload: force || allowed);
      if (mounted) {
        setState(() {
          _bytes = bytes;
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        width: 160,
        height: 160,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.textSecondary)),
      );
    }
    if (_blocked) {
      return GestureDetector(
        onTap: () => _load(force: true),
        child: SizedBox(
          width: 160,
          height: 80,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.lock_outline, color: widget.textColor),
              const SizedBox(height: 4),
              Text(
                'Нажмите, чтобы загрузить',
                style: AppTypography.caption.copyWith(color: widget.textColor),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    if (_bytes == null) {
      return GestureDetector(
        onTap: () => _load(force: true),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _error != null ? '🖼️ не удалось загрузить' : '🖼️ фото',
              style: AppTypography.caption.copyWith(color: widget.textColor),
            ),
            if (_error != null) ...[
              const SizedBox(height: 4),
              Text(
                'Нажмите, чтобы повторить',
                style: AppTypography.micro.copyWith(color: AppColors.accentBlue),
              ),
            ],
          ],
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadii.medium),
      child: Image.memory(_bytes!, width: 220, fit: BoxFit.cover),
    );
  }
}

extension on MessageGroupLayout {
  bool get isMiddleInGroup => !isFirstInGroup && !isLastInGroup;
}
