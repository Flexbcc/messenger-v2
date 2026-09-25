import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/contact_trust.dart';
import '../../services/settings_runtime.dart';

final _urlPattern = RegExp(
  r'https?://[^\s<>"{}|\\^`\[\]]+',
  caseSensitive: false,
);

Iterable<RegExpMatch> findUrls(String text) => _urlPattern.allMatches(text);

/// Renders message text with trust-aware link handling and optional local
/// URL preview chips gated by [messages.link_preview].
class TrustAwareMessageText extends StatefulWidget {
  const TrustAwareMessageText({
    super.key,
    required this.text,
    required this.style,
    required this.trust,
  });

  final String text;
  final TextStyle style;
  final TrustLevel trust;

  @override
  State<TrustAwareMessageText> createState() => _TrustAwareMessageTextState();
}

class _TrustAwareMessageTextState extends State<TrustAwareMessageText> {
  bool _previewsEnabled = true;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadPreviewPref();
  }

  Future<void> _loadPreviewPref() async {
    final enabled = await SettingsRuntime.instance.linkPreviewEnabled();
    if (!mounted) return;
    setState(() {
      _previewsEnabled = enabled;
      _loaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final matches = findUrls(widget.text).toList();
    if (matches.isEmpty) {
      return Text(widget.text, style: widget.style);
    }

    // Pref not loaded yet — avoid flashing preview chips.
    if (!_loaded) {
      return Text(widget.text, style: widget.style);
    }

    if (!_previewsEnabled) {
      // messages.link_preview = off: plain text, no preview widgets / link UI.
      return Text(widget.text, style: widget.style);
    }

    if (!widget.trust.allowsLinkInteraction) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_redactUrls(widget.text), style: widget.style),
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.link_off,
                size: 12,
                color: widget.style.color?.withValues(alpha: 0.6),
              ),
              const SizedBox(width: 4),
              Text(
                'Ссылка скрыта — повысьте уровень доверия',
                style: widget.style.copyWith(
                  fontSize: 11,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ),
        ],
      );
    }

    final spans = <InlineSpan>[];
    var cursor = 0;
    final urls = <String>[];
    for (final match in matches) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: widget.text.substring(cursor, match.start)));
      }
      final url = match.group(0)!;
      urls.add(url);
      spans.add(
        TextSpan(
          text: url,
          style: widget.style.copyWith(decoration: TextDecoration.underline),
          recognizer: TapGestureRecognizer()
            ..onTap = () => _onLinkTap(context, url),
        ),
      );
      cursor = match.end;
    }
    if (cursor < widget.text.length) {
      spans.add(TextSpan(text: widget.text.substring(cursor)));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        RichText(
          text: TextSpan(style: widget.style, children: spans),
        ),
        for (final url in urls.take(3))
          _LocalLinkPreviewChip(url: url, style: widget.style),
      ],
    );
  }

  static String _redactUrls(String input) {
    return input.replaceAllMapped(_urlPattern, (m) => '[ссылка]');
  }

  void _onLinkTap(BuildContext context, String url) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: const Text('Копировать ссылку'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: url));
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Ссылка скопирована')),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Lightweight local-only preview (host) — no remote fetch.
class _LocalLinkPreviewChip extends StatelessWidget {
  const _LocalLinkPreviewChip({required this.url, required this.style});

  final String url;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final host = Uri.tryParse(url)?.host;
    if (host == null || host.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: (style.color ?? Colors.black).withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.link,
              size: 14,
              color: style.color?.withValues(alpha: 0.7),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                host,
                style: style.copyWith(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
