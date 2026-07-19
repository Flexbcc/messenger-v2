import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/local_settings_store.dart';
import '../services/media_cache.dart';
import '../state/app_controller.dart';
import '../core/extensions/context_extensions.dart';
import '../core/theme/app_spacing.dart';
import '../core/ui/app_bottom_sheet.dart';
import '../core/ui/app_card.dart';
import '../core/ui/app_tile.dart';
import '../utils/format.dart';

/// See design.md §14 "Экран Данные и хранилище".
class DataStorageScreen extends ConsumerStatefulWidget {
  const DataStorageScreen({super.key});

  @override
  ConsumerState<DataStorageScreen> createState() => _DataStorageScreenState();
}

enum _AutoDownload { never, wifi, wifiAndMobile }

extension on _AutoDownload {
  String get label => switch (this) {
        _AutoDownload.never => 'Никогда',
        _AutoDownload.wifi => 'Wi-Fi',
        _AutoDownload.wifiAndMobile => 'Wi-Fi и мобильная сеть',
      };
}

class _DataStorageScreenState extends ConsumerState<DataStorageScreen> {
  final _store = LocalSettingsStore();

  _AutoDownload _photos = _AutoDownload.wifi;
  _AutoDownload _videos = _AutoDownload.wifi;
  _AutoDownload _files = _AutoDownload.wifi;
  _AutoDownload _audio = _AutoDownload.wifi;

  int _sentBytes = 0;
  int _receivedBytes = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final photos = await _store.getString('dl_photos', _AutoDownload.wifi.name);
    final videos = await _store.getString('dl_videos', _AutoDownload.wifi.name);
    final files = await _store.getString('dl_files', _AutoDownload.wifi.name);
    final audio = await _store.getString('dl_audio', _AutoDownload.wifi.name);
    final totals = await ref.read(appControllerProvider).networkUsage.getTotals();
    if (!mounted) return;
    setState(() {
      _photos = _AutoDownload.values.byName(photos);
      _videos = _AutoDownload.values.byName(videos);
      _files = _AutoDownload.values.byName(files);
      _audio = _AutoDownload.values.byName(audio);
      _sentBytes = totals.sent;
      _receivedBytes = totals.received;
    });
  }

  String get _cacheLabel => formatBytes(MediaCache.instance.totalBytes);

  Future<void> _pickAutoDownload(String title, _AutoDownload current, ValueChanged<_AutoDownload> onSelected) async {
    final selected = await showAppBottomSheet<_AutoDownload>(
      context: context,
      builder: (context) {
        final colors = context.colors;
        final text = context.textStyles;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(AppSpacing.screenPadding),
                child: Text(title, style: text.title),
              ),
              for (final option in _AutoDownload.values)
                ListTile(
                  title: Text(option.label, style: text.body),
                  trailing: option == current ? Icon(Icons.check, color: colors.primary) : null,
                  onTap: () => Navigator.of(context).pop(option),
                ),
              const SizedBox(height: AppSpacing.sm),
            ],
          ),
        );
      },
    );
    if (selected != null) onSelected(selected);
  }

  Future<void> _confirmClearCache() async {
    final sizeLabel = _cacheLabel;
    if (MediaCache.instance.totalBytes == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Кэш уже пуст')),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Очистить кэш?'),
        content: Text('Будет освобождено $sizeLabel. Загруженные медиафайлы нужно будет скачать заново.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Отмена')),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Очистить', style: TextStyle(color: context.colors.danger)),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      MediaCache.instance.clear();
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Кэш очищен')),
      );
    }
  }

  void _showNetworkUsage() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Использование сети'),
        content: Text(
          'Отправлено: ${formatBytes(_sentBytes)}\n'
          'Получено: ${formatBytes(_receivedBytes)}\n'
          'За последние 30 дней.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Закрыть')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;

    return Scaffold(
      appBar: AppBar(title: const Text('Данные и хранилище')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        children: [
          const SizedBox(height: AppSpacing.md),
          AppSettingsGroup(
            children: [
              AppTile(
                leading: Icon(Icons.data_usage_outlined, color: colors.textSecondary),
                title: 'Использование сети',
                subtitle: 'За последние 30 дней',
                trailing: AppTile.chevron(context),
                onTap: _showNetworkUsage,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          AppSettingsGroup(
            title: 'Автозагрузка',
            children: [
              AppTile(title: 'Фото', trailingText: _photos.label, trailing: AppTile.chevron(context), onTap: () => _pickAutoDownload('Фото', _photos, (v) { setState(() => _photos = v); _store.setString('dl_photos', v.name); })),
              AppTile(title: 'Видео', trailingText: _videos.label, trailing: AppTile.chevron(context), onTap: () => _pickAutoDownload('Видео', _videos, (v) { setState(() => _videos = v); _store.setString('dl_videos', v.name); })),
              AppTile(title: 'Файлы', trailingText: _files.label, trailing: AppTile.chevron(context), onTap: () => _pickAutoDownload('Файлы', _files, (v) { setState(() => _files = v); _store.setString('dl_files', v.name); })),
              AppTile(title: 'Аудио', trailingText: _audio.label, trailing: AppTile.chevron(context), showDivider: false, onTap: () => _pickAutoDownload('Аудио', _audio, (v) { setState(() => _audio = v); _store.setString('dl_audio', v.name); })),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          AppSettingsGroup(
            children: [
              AppTile(
                leading: Icon(Icons.delete_sweep_outlined, color: colors.danger),
                title: 'Очистить кэш',
                trailingText: _cacheLabel,
                danger: true,
                showDivider: false,
                onTap: _confirmClearCache,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
