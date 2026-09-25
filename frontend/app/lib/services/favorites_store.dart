import '../models/favorite_item.dart';
import 'local_settings_store.dart';

class FavoritesStore {
  FavoritesStore._();
  static final instance = FavoritesStore._();

  static const _indexKey = 'favorites_index';
  final _store = LocalSettingsStore();

  Future<List<FavoriteItem>> loadAll() async {
    final ids = await _store.getStringList(_indexKey);
    final result = <FavoriteItem>[];
    for (final id in ids) {
      final raw = await _store.getString('favorite_$id', '');
      if (raw.isNotEmpty) result.add(FavoriteItem.decode(raw));
    }
    result.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return result;
  }

  Future<bool> contains(String messageId) async {
    final all = await loadAll();
    return all.any((f) => f.messageId == messageId);
  }

  Future<void> save(FavoriteItem item) async {
    final all = await loadAll();
    for (final existing in all) {
      if (existing.messageId == item.messageId) {
        await remove(existing.id);
      }
    }
    final ids = await _store.getStringList(_indexKey);
    ids.removeWhere((id) => id == item.id);
    ids.insert(0, item.id);
    await _store.setStringList(_indexKey, ids);
    await _store.setString('favorite_${item.id}', item.encode());
  }

  Future<void> remove(String id) async {
    final ids = await _store.getStringList(_indexKey);
    ids.remove(id);
    await _store.setStringList(_indexKey, ids);
    await _store.setString('favorite_$id', '');
  }

  Future<void> removeByMessageId(String messageId) async {
    final all = await loadAll();
    for (final f in all) {
      if (f.messageId == messageId) await remove(f.id);
    }
  }
}
