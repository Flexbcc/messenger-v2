import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../../models/message.dart';
import '../../services/autodownload_policy.dart';
import 'duress_signal_banner.dart';
import '../../state/app_controller.dart';
import '../../state/settings_catalog_controller.dart';
import '../../theme/app_decorations.dart';
import '../../theme/spacing.dart';
import '../../theme/typography.dart';
import '../../utils/format.dart';
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
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) && _enterController.value < 1) {
      _enterController.value = 1;
    }
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
    final bubbleStyle =
        ref.watch(settingsCatalogValuesProvider).valueById('appearance.chat_bubbles')?.toString() ??
            'bubbles';
    final flat = bubbleStyle == 'flat';
    final radius = flat
        ? BorderRadius.circular(8)
        : messageBubbleBorderRadius(
            isMine: isMine,
            isFirstInGroup: layout.isFirstInGroup,
            isLastInGroup: layout.isLastInGroup,
          );

    final bubbleDecoration = isMine
        ? BoxDecoration(
            gradient: flat ? null : AppDecorations.outgoingBubbleGradient,
            color: flat ? AppColors.chatOutgoing : null,
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
    } else if (widget.message.contentType == 'file' && widget.message.plaintext != null) {
      content = _FileBubbleContent(message: widget.message, textColor: textColor);
    } else if (widget.message.contentType == 'video' && widget.message.plaintext != null) {
      content = _VideoBubbleContent(message: widget.message, textColor: textColor);
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
    // Task #71: показываем "(изм.)" если сообщение было отредактировано
    final isEdited = widget.message.editedAt != null;

    final bubble = Container(
      margin: EdgeInsets.only(top: layout.isFirstInGroup ? 4 : verticalMargin, bottom: verticalMargin),
      padding: EdgeInsets.symmetric(horizontal: flat ? 12 : 14, vertical: flat ? 8 : 10),
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
                      if (isEdited) ...[
                        Text(
                          '(изм.) ',
                          style: AppTypography.micro.copyWith(
                            color: (isMine ? AppColors.textMain : AppColors.textMuted).withValues(alpha: 0.6),
                            fontStyle: FontStyle.italic,
                          ),
                        ),
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

class _AttachmentPointerMeta {
  const _AttachmentPointerMeta({this.filename, this.mime, this.size});

  final String? filename;
  final String? mime;
  final int? size;

  static _AttachmentPointerMeta? fromMessage(ChatMessage message) {
    final raw = message.plaintext?.trim();
    if (raw == null || !raw.startsWith('{')) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      if (map['pending'] == true) return null;
      final sizeRaw = map['size'];
      return _AttachmentPointerMeta(
        filename: map['filename'] as String?,
        mime: map['mime'] as String?,
        size: sizeRaw is int ? sizeRaw : (sizeRaw is num ? sizeRaw.toInt() : null),
      );
    } catch (_) {
      return null;
    }
  }
}

Widget _attachmentBlockedTapToLoad({required Color textColor, required VoidCallback onTap}) {
  return GestureDetector(
    onTap: onTap,
    child: SizedBox(
      width: 160,
      height: 80,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.lock_outline, color: textColor),
          const SizedBox(height: 4),
          Text(
            'Нажмите, чтобы загрузить',
            style: AppTypography.caption.copyWith(color: textColor),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );
}

Widget _attachmentErrorRetry({
  required Color textColor,
  required String label,
  required VoidCallback onTap,
  String? error,
}) {
  return GestureDetector(
    onTap: onTap,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          error != null ? '$label не удалось загрузить' : label,
          style: AppTypography.caption.copyWith(color: textColor),
        ),
        if (error != null) ...[
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

Future<String> _writeAttachmentTempFile({
  required ChatMessage message,
  required Uint8List bytes,
  required String filename,
}) async {
  final dir = await getTemporaryDirectory();
  final safeName = filename.replaceAll(RegExp(r'[^\w.\-]'), '_');
  final path = '${dir.path}/chat_${message.id}_$safeName';
  final file = File(path);
  if (!await file.exists() || await file.length() != bytes.length) {
    await file.writeAsBytes(bytes, flush: true);
  }
  return path;
}

class _FileBubbleContent extends ConsumerStatefulWidget {
  const _FileBubbleContent({required this.message, required this.textColor});

  final ChatMessage message;
  final Color textColor;

  @override
  ConsumerState<_FileBubbleContent> createState() => _FileBubbleContentState();
}

class _FileBubbleContentState extends ConsumerState<_FileBubbleContent> {
  Uint8List? _bytes;
  bool _loading = true;
  bool _blocked = false;
  String? _error;

  _AttachmentPointerMeta? get _meta => _AttachmentPointerMeta.fromMessage(widget.message);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool force = false}) async {
    setState(() {
      _loading = true;
      _blocked = false;
      _error = null;
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
    final allowed = force ||
        await AutodownloadPolicy.instance.shouldDownloadForSender(
          MediaKind.files,
          trust,
          knownSizeBytes: _meta?.size,
        );
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
      final bytes = await ref.read(appControllerProvider).resolveAttachmentBytes(
            widget.message,
            forceDownload: force || allowed,
          );
      if (mounted) {
        setState(() {
          _bytes = bytes;
          _loading = false;
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

  Future<void> _openFile() async {
    if (_bytes == null) return;
    final filename = _meta?.filename ?? 'attachment';
    try {
      final path = await _writeAttachmentTempFile(
        message: widget.message,
        bytes: _bytes!,
        filename: filename,
      );
      final result = await OpenFilex.open(path);
      if (!mounted) return;
      if (result.type != ResultType.done) {
        await Clipboard.setData(ClipboardData(text: path));
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Путь скопирован: $path'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось открыть файл: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final meta = _meta;
    final filename = meta?.filename;

    if (_loading) {
      return SizedBox(
        width: 180,
        height: 56,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.insert_drive_file_outlined, color: widget.textColor, size: 20),
            const SizedBox(width: 8),
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.textSecondary),
            ),
          ],
        ),
      );
    }
    if (_blocked) {
      return _attachmentBlockedTapToLoad(textColor: widget.textColor, onTap: () => _load(force: true));
    }
    if (_bytes == null) {
      return _attachmentErrorRetry(
        textColor: widget.textColor,
        label: '📎 Файл',
        error: _error,
        onTap: () => _load(force: true),
      );
    }

    final sizeLabel = formatBytes(_bytes!.length);
    return InkWell(
      onTap: _openFile,
      borderRadius: BorderRadius.circular(AppRadii.medium),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.insert_drive_file_outlined, color: widget.textColor, size: 24),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  filename ?? 'Файл',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.body.copyWith(color: widget.textColor),
                ),
                Text(
                  sizeLabel,
                  style: AppTypography.caption.copyWith(color: widget.textColor.withValues(alpha: 0.75)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Icon(Icons.open_in_new, size: 16, color: widget.textColor.withValues(alpha: 0.7)),
        ],
      ),
    );
  }
}

class _VideoBubbleContent extends ConsumerStatefulWidget {
  const _VideoBubbleContent({required this.message, required this.textColor});

  final ChatMessage message;
  final Color textColor;

  @override
  ConsumerState<_VideoBubbleContent> createState() => _VideoBubbleContentState();
}

class _VideoBubbleContentState extends ConsumerState<_VideoBubbleContent> {
  Uint8List? _bytes;
  bool _loading = true;
  bool _blocked = false;
  String? _error;
  VideoPlayerController? _controller;
  bool _videoInitializing = false;

  _AttachmentPointerMeta? get _meta => _AttachmentPointerMeta.fromMessage(widget.message);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _load({bool force = false}) async {
    await _controller?.dispose();
    _controller = null;
    setState(() {
      _loading = true;
      _blocked = false;
      _error = null;
      _bytes = null;
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
    final allowed = force ||
        await AutodownloadPolicy.instance.shouldDownloadForSender(
          MediaKind.videos,
          trust,
          knownSizeBytes: _meta?.size,
        );
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
      final bytes = await ref.read(appControllerProvider).resolveAttachmentBytes(
            widget.message,
            forceDownload: force || allowed,
          );
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _loading = false;
      });
      await _initVideoPlayer(bytes);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _initVideoPlayer(Uint8List bytes) async {
    if (!mounted) return;
    setState(() => _videoInitializing = true);
    try {
      final filename = _meta?.filename ?? 'video.mp4';
      final path = await _writeAttachmentTempFile(
        message: widget.message,
        bytes: bytes,
        filename: filename,
      );
      final controller = VideoPlayerController.file(File(path));
      await controller.initialize();
      controller.addListener(() {
        if (mounted) setState(() {});
      });
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _videoInitializing = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _videoInitializing = false;
          _error = e.toString();
        });
      }
    }
  }

  void _togglePlayback() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    setState(() {
      if (controller.value.isPlaying) {
        controller.pause();
      } else {
        controller.play();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading || _videoInitializing) {
      return const SizedBox(
        width: 220,
        height: 120,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.textSecondary)),
      );
    }
    if (_blocked) {
      return _attachmentBlockedTapToLoad(textColor: widget.textColor, onTap: () => _load(force: true));
    }
    if (_bytes == null || _controller == null || !_controller!.value.isInitialized) {
      return _attachmentErrorRetry(
        textColor: widget.textColor,
        label: '🎬 Видео',
        error: _error,
        onTap: () => _load(force: true),
      );
    }

    final controller = _controller!;
    final aspect = controller.value.aspectRatio > 0 ? controller.value.aspectRatio : 16 / 9;

    return GestureDetector(
      onTap: _togglePlayback,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.medium),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 200, maxWidth: 220),
          child: Stack(
            alignment: Alignment.center,
            children: [
              AspectRatio(
                aspectRatio: aspect,
                child: VideoPlayer(controller),
              ),
              AnimatedOpacity(
                opacity: controller.value.isPlaying ? 0.0 : 1.0,
                duration: const Duration(milliseconds: 200),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.35),
                    shape: BoxShape.circle,
                  ),
                  padding: const EdgeInsets.all(8),
                  child: const Icon(Icons.play_arrow, color: Colors.white, size: 36),
                ),
              ),
            ],
          ),
        ),
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
    final size = _AttachmentPointerMeta.fromMessage(widget.message)?.size;
    final allowed = force ||
        await AutodownloadPolicy.instance.shouldDownloadForSender(
          MediaKind.photos,
          trust,
          knownSizeBytes: size,
        );
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
      final bytes = await ref.read(appControllerProvider).resolveAttachmentBytes(widget.message, forceDownload: force || allowed);
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
