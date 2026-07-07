import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/extensions/context_extensions.dart';
import '../core/theme/app_spacing.dart';
import '../core/ui/app_avatar.dart';
import '../core/ui/app_badge.dart';
import '../core/ui/app_empty_state.dart';
import '../core/ui/app_icon_button.dart';
import '../core/ui/app_search_field.dart';
import '../models/contact_trust.dart';
import '../state/app_controller.dart';
import 'contact_profile_screen.dart';
import 'new_chat_screen.dart';
import 'new_group_screen.dart';

class ContactsScreen extends ConsumerStatefulWidget {
  const ContactsScreen({super.key});

  @override
  ConsumerState<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends ConsumerState<ContactsScreen> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() => setState(() => _query = _searchController.text.trim().toLowerCase()));
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(appControllerProvider);
    final selfId = controller.session?.userId;

    final entries = controller.knownDisplayNames.entries
        .where((e) => e.key != selfId)
        .where((e) => RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', caseSensitive: false).hasMatch(e.key))
        .where((e) => _query.isEmpty || e.value.toLowerCase().contains(_query) || e.key.toLowerCase().contains(_query))
        .toList()
      ..sort((a, b) => a.value.compareTo(b.value));

    return Scaffold(
      appBar: AppBar(title: const Text('Контакты')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.screenPadding,
              AppSpacing.md,
              AppSpacing.screenPadding,
              AppSpacing.sm,
            ),
            child: AppSearchField(controller: _searchController),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                AppQuickAction(
                  icon: Icons.group_add_outlined,
                  label: 'Группа',
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NewGroupScreen())),
                ),
                AppQuickAction(
                  icon: Icons.person_add_alt_1_outlined,
                  label: 'Контакт',
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NewChatScreen())),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Expanded(
            child: entries.isEmpty
                ? AppEmptyState(
                    icon: Icons.people_outline,
                    title: _query.isNotEmpty ? 'Ничего не найдено' : 'Пока нет контактов',
                    subtitle: _query.isNotEmpty
                        ? null
                        : 'Контакты появятся после переписки или через «Контакт»',
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: AppSpacing.xl),
                    itemCount: entries.length,
                    itemBuilder: (context, i) {
                      final entry = entries[i];
                      return _ContactRow(userId: entry.key, name: entry.value);
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _ContactRow extends ConsumerWidget {
  const _ContactRow({required this.userId, required this.name});

  final String userId;
  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final text = context.textStyles;
    final controller = ref.watch(appControllerProvider);
    final online = controller.isContactOnline(userId);
    final status = controller.contactStatusLabel(userId);
    final trust = controller.trustLevelFor(userId);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => ContactProfileScreen(userId: userId, displayName: name)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding, vertical: 10),
          child: Row(
            children: [
              AppAvatar(label: name, showOnline: online),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(child: Text(name, style: text.subtitle, overflow: TextOverflow.ellipsis)),
                        if (trust != TrustLevel.normal) ...[
                          const SizedBox(width: 6),
                          AppSecurityBadge(
                            icon: trust == TrustLevel.unknown ? Icons.help_outline : Icons.shield_outlined,
                            label: trust.shortLabel,
                            color: trust == TrustLevel.unknown ? colors.warning : colors.primary,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        StatusDot(status: online ? AppStatus.online : AppStatus.offline, diameter: 8),
                        const SizedBox(width: 6),
                        Flexible(child: Text(status, style: text.caption, overflow: TextOverflow.ellipsis)),
                      ],
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: colors.textMuted, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}
