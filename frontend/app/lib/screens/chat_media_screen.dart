import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/extensions/context_extensions.dart';
import '../models/conversation.dart';
import '../models/message.dart';
import '../services/autodownload_policy.dart';
import '../state/app_controller.dart';
import '../theme/spacing.dart';
import '../theme/typography.dart';

int? _knownSizeBytes(ChatMessage message) {
  final raw = message.plaintext?.trim();
  if (raw == null || !raw.startsWith('{')) return null;
  try {
    final map = jsonDecode(raw) as Map<String, dynamic>;
    final sizeRaw = map['size'];
    if (sizeRaw is int) return sizeRaw;
    if (sizeRaw is num) return sizeRaw.toInt();
    return null;
  } catch (_) {
    return null;
  }
}

/// Grid of images from messages already in this chat's local history.
class ChatMediaScreen extends ConsumerWidget {
  const ChatMediaScreen({super.key, required this.conversation});

  final Conversation conversation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(appControllerProvider);
    final images = controller.imageMessagesFor(conversation.id);

    return Scaffold(
      appBar: AppBar(title: const Text('Медиа')),
      body: images.isEmpty
          ? Center(
              child: Text('Нет фото в этом чате', style: AppTypography.caption),
            )
          : GridView.builder(
              padding: const EdgeInsets.all(AppSpacing.smallGap),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 2,
                mainAxisSpacing: 2,
              ),
              itemCount: images.length,
              itemBuilder: (context, i) => _MediaThumb(message: images[i]),
            ),
    );
  }
}

class _MediaThumb extends ConsumerStatefulWidget {
  const _MediaThumb({required this.message});

  final ChatMessage message;

  @override
  ConsumerState<_MediaThumb> createState() => _MediaThumbState();
}

class _MediaThumbState extends ConsumerState<_MediaThumb> {
  Uint8List? _bytes;
  bool _loading = true;
  bool _blocked = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final size = _knownSizeBytes(widget.message);
    final allowed = await AutodownloadPolicy.instance.shouldDownload(
      MediaKind.photos,
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
      final bytes = await ref
          .read(appControllerProvider)
          .resolveImageBytes(widget.message, forceDownload: true);
      if (mounted) {
        setState(() {
          _bytes = bytes;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    if (_loading) {
      return Container(
        color: colors.surfaceElevated,
        child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_blocked || _bytes == null) {
      return GestureDetector(
        onTap: _blocked ? () => _loadForced() : null,
        child: Container(
          color: colors.surfaceElevated,
          child: Center(
            child: Icon(
              _blocked ? Icons.download_outlined : Icons.broken_image_outlined,
              color: colors.textMuted,
            ),
          ),
        ),
      );
    }
    return Image.memory(_bytes!, fit: BoxFit.cover);
  }

  Future<void> _loadForced() async {
    setState(() {
      _loading = true;
      _blocked = false;
    });
    try {
      final bytes = await ref
          .read(appControllerProvider)
          .resolveImageBytes(widget.message, forceDownload: true);
      if (mounted) {
        setState(() {
          _bytes = bytes;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }
}
