import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/contact_trust.dart';

final _urlPattern = RegExp(r'https?://[^\s<>"{}|\\^`\[\]]+', caseSensitive: false);

Iterable<RegExpMatch> findUrls(String text) => _urlPattern.allMatches(text);

/// Renders message text with trust-aware link handling.
class TrustAwareMessageText extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final matches = findUrls(text).toList();
    if (matches.isEmpty) {
      return Text(text, style: style);
    }

    if (!trust.allowsLinkInteraction) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_redactUrls(text), style: style),
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.link_off, size: 12, color: style.color?.withValues(alpha: 0.6)),
              const SizedBox(width: 4),
              Text(
                'Ссылка скрыта — повысьте уровень доверия',
                style: style.copyWith(fontSize: 11, fontStyle: FontStyle.italic),
              ),
            ],
          ),
        ],
      );
    }

    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final match in matches) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, match.start)));
      }
      final url = match.group(0)!;
      spans.add(
        TextSpan(
          text: url,
          style: style.copyWith(decoration: TextDecoration.underline),
          recognizer: TapGestureRecognizer()
            ..onTap = () => _onLinkTap(context, url),
        ),
      );
      cursor = match.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }

    return RichText(text: TextSpan(style: style, children: spans));
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
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ссылка скопирована')));
              },
            ),
          ],
        ),
      ),
    );
  }
}
