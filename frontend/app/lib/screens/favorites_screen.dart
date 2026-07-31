import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/extensions/context_extensions.dart';
import '../core/theme/app_spacing.dart';
import '../core/ui/app_card.dart';
import '../core/ui/app_tile.dart';
import '../models/favorite_item.dart';
import '../services/favorites_store.dart';
import '../state/app_controller.dart';
import '../utils/format.dart';
import 'chat_screen.dart';

class FavoritesScreen extends ConsumerStatefulWidget {
  const FavoritesScreen({super.key});

  @override
  ConsumerState<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends ConsumerState<FavoritesScreen> {
  List<FavoriteItem> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await FavoritesStore.instance.loadAll();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = context.textStyles;
    final colors = context.colors;

    return Scaffold(
      appBar: AppBar(title: const Text('Избранное')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? Center(child: Text('Пока пусто', style: text.caption))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: AppSpacing.xl),
                    children: [
                      AppSettingsGroup(
                        margin: const EdgeInsets.all(AppSpacing.screenPadding),
                        children: [
                          for (var i = 0; i < _items.length; i++)
                            AppTile(
                              leading: Icon(
                                _items[i].contentType == 'image' ? Icons.image_outlined : Icons.chat_bubble_outline,
                                color: colors.textSecondary,
                              ),
                              title: _items[i].conversationTitle,
                              subtitle: '${_items[i].preview}\n${formatSyncTime(_items[i].savedAt)}',
                              trailing: AppTile.chevron(context),
                              showDivider: i < _items.length - 1,
                              onTap: () async {
                                final controller = ref.read(appControllerProvider);
                                final conv = controller.conversations
                                    .where((c) => c.id == _items[i].conversationId)
                                    .firstOrNull;
                                if (conv == null || !mounted) return;
                                await Navigator.of(context).push(
                                  MaterialPageRoute(builder: (_) => ChatScreen(conversation: conv)),
                                );
                              },
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
    );
  }
}
