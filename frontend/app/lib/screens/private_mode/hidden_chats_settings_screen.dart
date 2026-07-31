import 'package:flutter/material.dart';

import '../../core/extensions/context_extensions.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/ui/app_card.dart';
import '../../core/ui/app_switch_tile.dart';
import '../../core/ui/app_tile.dart';
import '../../services/hidden_chats_store.dart';
import '../../services/local_settings_store.dart';
import '../../state/app_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Policies for secret-hidden conversations.
class HiddenChatsSettingsScreen extends ConsumerStatefulWidget {
  const HiddenChatsSettingsScreen({super.key});

  @override
  ConsumerState<HiddenChatsSettingsScreen> createState() => _HiddenChatsSettingsScreenState();
}

class _HiddenChatsSettingsScreenState extends ConsumerState<HiddenChatsSettingsScreen> {
  bool _excludeSearch = true;
  bool _silenceNotif = true;
  bool _gestureEntry = true;
  HiddenChatSort _sort = HiddenChatSort.recent;
  String _searchCmd = '.скрытые';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = HiddenChatsStore.instance;
    final exclude = await store.excludeFromGlobalSearch();
    final silence = await store.silenceNotifications();
    final gesture = await store.gestureEntryEnabled();
    final sort = await store.sortOrder();
    final cmd = await store.secretSearchCommand();
    if (!mounted) return;
    setState(() {
      _excludeSearch = exclude;
      _silenceNotif = silence;
      _gestureEntry = gesture;
      _sort = sort;
      _searchCmd = cmd;
      _loading = false;
    });
  }

  Future<void> _editSearchCommand() async {
    final controller = TextEditingController(text: _searchCmd);
    final next = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Секретная команда'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: '.скрытые'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Сохранить')),
        ],
      ),
    );
    if (next == null || next.trim().isEmpty) return;
    await HiddenChatsStore.instance.setSecretSearchCommand(next);
    await ref.read(appControllerProvider).refreshHiddenChatsPolicies();
    setState(() => _searchCmd = next.trim());
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;

    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Настройки скрытых чатов')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            child: Text(
              'Скрытые диалоги не отображаются в основном списке. Доступ — через PIN, жест или команду в поиске.',
              style: text.caption,
            ),
          ),
          AppSettingsGroup(
            title: 'Приватность',
            children: [
              AppSwitchTile(
                title: 'Исключить из общего поиска',
                subtitle: 'Не показывать в поиске на вкладке «Чаты»',
                value: _excludeSearch,
                onChanged: (v) async {
                  await HiddenChatsStore.instance.setExcludeFromGlobalSearch(v);
                  await ref.read(appControllerProvider).refreshHiddenChatsPolicies();
                  setState(() => _excludeSearch = v);
                },
              ),
              AppSwitchTile(
                title: 'Скрыть уведомления',
                subtitle: 'Без баннеров и звуков для скрытых чатов',
                value: _silenceNotif,
                onChanged: (v) async {
                  await HiddenChatsStore.instance.setSilenceNotifications(v);
                  await ref.read(appControllerProvider).refreshHiddenChatsPolicies();
                  setState(() => _silenceNotif = v);
                },
                showDivider: false,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          AppSettingsGroup(
            title: 'Доступ',
            children: [
              AppSwitchTile(
                title: 'Вход долгим нажатием',
                subtitle: 'Удерживайте заголовок «Чаты» на главном экране',
                value: _gestureEntry,
                onChanged: (v) async {
                  await HiddenChatsStore.instance.setGestureEntryEnabled(v);
                  if (v) {
                    await HiddenChatsStore.instance.setOpenMethod('gesture');
                    await LocalSettingsStore().setString('catalog.hidden.open_method', 'gesture');
                  } else {
                    await HiddenChatsStore.instance.setOpenMethod('pin');
                    await LocalSettingsStore().setString('catalog.hidden.open_method', 'pin');
                  }
                  await ref.read(appControllerProvider).refreshHiddenChatsPolicies();
                  setState(() => _gestureEntry = v);
                },
              ),
              AppTile(
                leading: Icon(Icons.terminal, color: colors.textSecondary),
                title: 'Команда в поиске',
                subtitle: 'Также: .hidden, #скрытые',
                trailingText: _searchCmd,
                showDivider: false,
                onTap: _editSearchCommand,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          AppSettingsGroup(
            title: 'Сортировка',
            children: [
              AppTile(
                leading: Icon(Icons.sort, color: colors.textSecondary),
                title: 'Порядок списка',
                trailingText: _sort == HiddenChatSort.recent ? 'Недавние' : 'По имени',
                onTap: () async {
                  final next = _sort == HiddenChatSort.recent ? HiddenChatSort.name : HiddenChatSort.recent;
                  await HiddenChatsStore.instance.setSortOrder(next);
                  await ref.read(appControllerProvider).refreshHiddenChatsPolicies();
                  setState(() => _sort = next);
                },
                showDivider: false,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
