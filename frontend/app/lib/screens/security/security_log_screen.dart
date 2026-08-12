import 'package:flutter/material.dart';

import '../../core/extensions/context_extensions.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/ui/app_card.dart';
import '../../core/ui/app_empty_state.dart';
import '../../services/security_log_service.dart';
import '../../utils/format.dart';

/// Local security event log — replaceable with API.
class SecurityLogScreen extends StatefulWidget {
  const SecurityLogScreen({super.key});

  @override
  State<SecurityLogScreen> createState() => _SecurityLogScreenState();
}

class _SecurityLogScreenState extends State<SecurityLogScreen> {
  List<SecurityEvent> _events = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final events = await SecurityLogService.instance.load();
    if (mounted) {
      setState(() {
        _events = events;
        _loading = false;
      });
    }
  }

  IconData _iconFor(String name) => switch (name) {
    'pin' => Icons.pin_outlined,
    'room' => Icons.lock_open_outlined,
    'device' => Icons.devices_outlined,
    'fake' => Icons.theater_comedy_outlined,
    'duress' => Icons.campaign_outlined,
    'session' => Icons.logout,
    _ => Icons.shield_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Журнал безопасности'),
        actions: [
          if (_events.isNotEmpty)
            TextButton(
              onPressed: () async {
                await SecurityLogService.instance.clear();
                await _load();
              },
              child: Text('Очистить', style: TextStyle(color: colors.danger)),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _events.isEmpty
          ? const AppEmptyState(
              icon: Icons.shield_outlined,
              title: 'Событий пока нет',
              subtitle: 'PIN, Secret Room и сессии будут записываться локально',
            )
          : ListView.builder(
              padding: const EdgeInsets.all(AppSpacing.screenPadding),
              itemCount: _events.length,
              itemBuilder: (context, i) {
                final e = _events[i];
                return Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: AppCard(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(_iconFor(e.icon), size: 20, color: colors.primary),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(e.title, style: text.subtitle),
                              if (e.subtitle.isNotEmpty)
                                Text(e.subtitle, style: text.caption),
                              const SizedBox(height: 4),
                              Text(formatRelativeTime(e.at), style: text.micro),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
