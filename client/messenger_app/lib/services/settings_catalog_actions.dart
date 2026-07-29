import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config.dart';
import '../models/settings_catalog.dart';
import '../screens/debug_log_screen.dart';
import '../screens/devices_screen.dart';
import '../screens/diagnostics_screen.dart';
import '../screens/private_mode/decoy_pin_setup_screen.dart';
import '../screens/private_mode/pin_setup_screen.dart';
import '../screens/profile_qr_screen.dart';
import '../screens/profile_screen.dart';
import '../screens/security/connection_status_screen.dart';
import '../screens/security/recovery_key_screen.dart';
import '../services/account_settings_scope.dart';
import '../services/backup_crypto.dart';
import '../services/catalog_list_store.dart';
import '../services/catalog_seed_service.dart';
import '../services/hidden_chats_store.dart';
import '../services/in_app_notification_service.dart';
import '../services/media_cache.dart';
import '../services/message_cache_store.dart';
import '../services/settings_runtime.dart';
import '../services/trusted_contacts_store.dart';
import '../security/pin_security.dart';
import '../state/app_controller.dart';
import '../screens/private_mode/private_mode_state.dart';
import '../state/notification_settings.dart';
import '../state/settings_catalog_controller.dart';

/// Executes catalog `action` settings and navigates for `secret` settings.
class SettingsCatalogActions {
  SettingsCatalogActions({
    required this.context,
    required this.ref,
    required this.listStore,
  });

  final BuildContext context;
  final WidgetRef ref;
  final CatalogListStore listStore;

  Future<bool> _ensureCriticalPin(String actionToken) async {
    if (!await SettingsRuntime.instance.requiresPinFor(actionToken)) return true;
    final configured = await PinSecurity.isRealPinConfigured();
    if (!configured) return true;
    if (!context.mounted) return false;
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Подтвердите PIN'),
        content: TextField(
          controller: ctrl,
          obscureText: true,
          keyboardType: TextInputType.visiblePassword,
          decoration: const InputDecoration(hintText: 'PIN'),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('OK')),
        ],
      ),
    );
    if (ok != true) return false;
    final valid = await PinSecurity.verifyRealPin(ctrl.text);
    if (!valid && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Неверный PIN')),
      );
    }
    return valid;
  }

  Future<void> runAction(SettingDef def) async {
    if (def.requiresConfirmation) {
      final ok = await _confirm(def.title, def.description);
      if (!ok) return;
    }
    switch (def.id) {
      case 'data.clear_cache':
        MediaCache.instance.clear();
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Кэш медиа очищен')),
          );
        }
      case 'data.clear_local':
        if (!await _ensureCriticalPin('delete_profile')) return;
        await _clearLocalData();
      case 'data.delete_profile':
        if (!await _ensureCriticalPin('delete_profile')) return;
        await _deleteLocalProfile();
      case 'data.revoke_all_devices':
        if (!await _ensureCriticalPin('add_device')) return;
        await _revokeOtherDevices();
      case 'data.export_profile':
        if (!await _ensureCriticalPin('export')) return;
        await _exportProfile();
      case 'data.export_history':
        if (!await _ensureCriticalPin('export')) return;
        await _exportHistory();
      case 'data.export_contacts':
        if (!await _ensureCriticalPin('export')) return;
        await _exportContacts();
      case 'backup.create_now':
        if (!await _ensureCriticalPin('export')) return;
        await _createBackup();
      case 'backup.restore':
        if (!await _ensureCriticalPin('export')) return;
        await _restoreBackup();
      case 'storage.integrity_check':
        if (context.mounted) {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const DiagnosticsScreen()),
          );
        }
      case 'storage.route_audit':
        if (context.mounted) {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const ConnectionStatusScreen()),
          );
        }
      case 'storage.delete_local':
        if (!await _ensureCriticalPin('delete_profile')) return;
        MediaCache.instance.clear();
        final userId = ref.read(appControllerProvider).session?.userId;
        if (userId != null) {
          await MessageCacheStore.instance.clearUser(userId);
        }
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Локальные копии медиа и истории очищены')),
          );
        }
      case 'storage.delete_remote':
        if (!await _ensureCriticalPin('delete_profile')) return;
        await _deleteRemoteStub();
      case 'developer.logs':
        if (context.mounted) {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const DebugLogScreen()),
          );
        }
      case 'developer.network_debug':
        if (context.mounted) {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const DiagnosticsScreen()),
          );
        }
      case 'developer.test_notifications':
        InAppNotificationService.instance.notify(
          InAppNotificationEvent(title: 'Тест', body: 'Тестовое уведомление'),
        );
      case 'developer.test_crypto':
        if (context.mounted) {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const DiagnosticsScreen()),
          );
        }
      case 'devices.add':
        if (!await _ensureCriticalPin('add_device')) return;
        if (context.mounted) {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const DevicesScreen()),
          );
        }
      case 'profile.avatar':
        if (context.mounted) {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const ProfileScreen()),
          );
        }
      case 'profile.qr':
        if (context.mounted) {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const ProfileQrScreen()),
          );
        }
      default:
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('«${def.title}» — в разработке')),
          );
        }
    }
  }

  Future<void> openSecret(SettingDef def) async {
    switch (def.id) {
      case 'security.pin':
        if (!context.mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const PinSetupScreen()),
        );
      case 'security.fake_pin':
        if (!context.mounted) return;
        final hasReal = await PinSecurity.isRealPinConfigured();
        if (!context.mounted) return;
        if (!hasReal) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Сначала задайте основной PIN')),
          );
          return;
        }
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const DecoyPinSetupScreen()),
        );
      case 'hidden.pin':
        if (!context.mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const PinSetupScreen()),
        );
      case 'security.recovery_key':
        if (!await SettingsRuntime.instance.recoveryKeyEnabled()) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Ключ восстановления выключен в настройках')),
            );
          }
          return;
        }
        if (!await _ensureCriticalPin('view_keys')) return;
        if (context.mounted) {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const RecoveryKeyScreen()),
          );
        }
      case 'backup.password':
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Пароль используется при «Создать копию сейчас»')),
          );
        }
      default:
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('«${def.title}» — защищённый параметр')),
          );
        }
    }
  }

  Future<void> editList(SettingDef def) async {
    final items = await listStore.load(def.id);
    if (!context.mounted) return;
    final edited = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => _ListEditorDialog(title: def.title, items: items),
    );
    if (edited != null) {
      await listStore.save(def.id, edited);
      if (def.id == 'notifications.dnd_schedule' || def.id == 'notifications.dnd_exceptions') {
        await ref.read(notificationSettingsProvider).reloadFromStore();
      }
      if (def.id == 'hidden.chat_list') {
        await HiddenChatsStore.instance.saveSecretHiddenIds(edited.toSet());
        await ref.read(appControllerProvider).reloadSecretHiddenFromStore();
      }
      if (def.id == 'contacts.trusted_list') {
        await TrustedContactsStore.instance.save(edited);
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Сохранено: ${edited.length} элементов')),
        );
      }
    }
  }

  Future<void> _deleteRemoteStub() async {
    final app = ref.read(appControllerProvider);
    try {
      if (await SettingsRuntime.instance.devicesRemoteWipeEnabled()) {
        await app.revokeOtherDevices();
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Удаление удалённых копий: сеансы на других устройствах завершены (API stub)'),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Удаление remote: $e')),
        );
      }
    }
  }

  Future<void> _createBackup() async {
    if (!await SettingsRuntime.instance.backupEnabled()) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Сначала включите резервное копирование')),
        );
      }
      return;
    }
    final runtime = SettingsRuntime.instance;
    final schedule = await runtime.backupSchedule();
    final contents = await runtime.backupContents();
    final catalog = await ref.read(settingsCatalogProvider.future);
    final app = ref.read(appControllerProvider);

    final blob = <String, dynamic>{
      'meta': {
        'kind': 'settings_backup',
        'app_version': AppInfo.version,
        'schedule': schedule,
        'contents': contents,
        'created_at': DateTime.now().toIso8601String(),
      },
    };

    if (contents.contains('settings')) {
      final settingsBlob = await CatalogSeedService().exportJson(catalog);
      blob['settings'] = settingsBlob;
    }
    if (contents.contains('profile')) {
      blob['profile'] = {
        'user_id': app.session?.userId,
        'display_name': app.session?.displayName ?? await runtime.displayName(),
        'username': app.login ?? await runtime.username(),
        'bio': await runtime.bio(),
      };
    }
    if (contents.contains('contacts')) {
      final contacts = <Map<String, dynamic>>[];
      final seen = <String>{};
      for (final c in app.conversations) {
        for (final id in c.participantUserIds) {
          if (id == app.session?.userId || !seen.add(id)) continue;
          contacts.add({'user_id': id, 'display_name': app.labelFor(id)});
        }
      }
      blob['contacts'] = contacts;
    }
    if (contents.contains('messages')) {
      final conversations = <Map<String, dynamic>>[];
      for (final c in app.conversations) {
        final msgs = app.messagesByConversation[c.id] ?? const [];
        conversations.add({
          'id': c.id,
          'messages': [
            for (final m in msgs.take(200))
              {
                'id': m.id,
                'sender': m.senderUserId,
                'at': m.createdAt.toIso8601String(),
                'text': m.plaintext,
              },
          ],
        });
      }
      blob['messages'] = conversations;
    }
    if (contents.contains('hidden_chats')) {
      blob['hidden_chats'] = await listStore.load('hidden.chat_list');
    }
    if (contents.contains('keys')) {
      blob['keys'] = {'note': 'Ключи не экспортируются в MVP — только метка'};
    }
    if (contents.contains('media')) {
      blob['media'] = {
        'cache_entries': MediaCache.instance.entryCount,
        'cache_bytes': MediaCache.instance.totalBytes,
      };
    }

    String outText;
    if (await runtime.backupEncryption()) {
      final password = await runtime.backupPassword();
      if (password.trim().isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Задайте пароль резервной копии (backup.password)')),
          );
        }
        return;
      }
      final envelope = await BackupCrypto.encryptJson(blob, password);
      outText = const JsonEncoder.withIndent('  ').convert(envelope);
    } else {
      outText = const JsonEncoder.withIndent('  ').convert(blob);
    }

    await Clipboard.setData(ClipboardData(text: outText));
    await runtime.markLastBackup();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            kIsWeb
                ? 'Бэкап скопирован (${contents.join(', ')})'
                : 'Бэкап скопирован (${outText.length} байт · ${contents.join(', ')})',
          ),
        ),
      );
    }
  }

  Future<void> _restoreBackup() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final bytes = result.files.first.bytes;
    if (bytes == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось прочитать файл')),
        );
      }
      return;
    }
    final ok = await _confirm(
      'Восстановить из копии',
      'Текущие настройки каталога будут перезаписаны. Продолжить?',
    );
    if (!ok) return;
    try {
      var decoded = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (decoded['kind'] == 'encrypted_settings_backup') {
        final password = await SettingsRuntime.instance.backupPassword();
        if (password.trim().isEmpty) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Нужен пароль backup.password для расшифровки')),
            );
          }
          return;
        }
        decoded = await BackupCrypto.decryptJson(decoded, password);
      }
      final settingsPart = decoded['settings'] as Map<String, dynamic>? ?? decoded;
      final catalog = await ref.read(settingsCatalogProvider.future);
      final n = await CatalogSeedService().applyJson(catalog, settingsPart);
      await ref.read(settingsCatalogValuesProvider).reloadFromLegacy(catalog);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Восстановлено параметров: $n')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка восстановления: $e')),
        );
      }
    }
  }

  Future<void> _exportProfile() async {
    final app = ref.read(appControllerProvider);
    final runtime = SettingsRuntime.instance;
    final payload = await runtime.buildShareableProfilePayload(
      userId: app.session?.userId ?? '',
      displayName: app.session?.displayName ?? await runtime.displayName(),
      phone: app.phone ?? await runtime.phone(),
      email: app.email ?? await runtime.email(),
      username: app.login ?? await runtime.username(),
      isContact: true,
    );
    payload['exported_at'] = DateTime.now().toIso8601String();
    payload['phone_login'] = await runtime.phoneLogin();
    payload['phone_recovery'] = await runtime.phoneRecovery();
    payload['email_login'] = await runtime.emailLogin();
    payload['email_recovery'] = await runtime.emailRecovery();
    payload['bio'] = await runtime.bio();
    await _copyJson('Профиль', payload);
  }

  Future<void> _exportHistory() async {
    final app = ref.read(appControllerProvider);
    final conversations = <Map<String, dynamic>>[];
    for (final c in app.conversations) {
      final msgs = app.messagesByConversation[c.id] ?? const [];
      conversations.add({
        'id': c.id,
        'participants': c.participantUserIds,
        'messages': [
          for (final m in msgs)
            {
              'id': m.id,
              'sender': m.senderUserId,
              'at': m.createdAt.toIso8601String(),
              'type': m.contentType,
              'text': m.plaintext,
            },
        ],
      });
    }
    await _copyJson('История', {
      'exported_at': DateTime.now().toIso8601String(),
      'conversations': conversations,
    });
  }

  Future<void> _exportContacts() async {
    final app = ref.read(appControllerProvider);
    final contacts = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final c in app.conversations) {
      for (final id in c.participantUserIds) {
        if (id == app.session?.userId || !seen.add(id)) continue;
        contacts.add({
          'user_id': id,
          'display_name': app.labelFor(id),
        });
      }
    }
    await _copyJson('Контакты', {
      'exported_at': DateTime.now().toIso8601String(),
      'contacts': contacts,
    });
  }

  Future<void> _clearLocalData() async {
    MediaCache.instance.clear();
    final app = ref.read(appControllerProvider);
    final userId = app.session?.userId;
    if (userId != null) {
      await MessageCacheStore.instance.clearUser(userId);
      for (final id in app.messagesByConversation.keys.toList()) {
        await app.clearLocalHistory(id);
      }
      await AccountSettingsScope.wipeUser(userId);
      try {
        await ref.read(privateModeStateProvider).reset();
      } catch (_) {}
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Локальные данные и настройки очищены')),
      );
    }
  }

  Future<void> _deleteLocalProfile() async {
    final app = ref.read(appControllerProvider);
    final userId = app.session?.userId;
    if (userId != null) {
      await MessageCacheStore.instance.clearUser(userId);
      await AccountSettingsScope.wipeUser(userId);
      try {
        await ref.read(privateModeStateProvider).reset();
      } catch (_) {}
    }
    MediaCache.instance.clear();
    await app.logout();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Локальный профиль удалён (серверного API нет)')),
      );
    }
  }

  Future<void> _revokeOtherDevices() async {
    try {
      await ref.read(appControllerProvider).revokeOtherDevices();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Сеансы на других устройствах завершены')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка: $e')),
        );
      }
    }
  }

  Future<void> _copyJson(String label, Map<String, dynamic> payload) async {
    final json = const JsonEncoder.withIndent('  ').convert(payload);
    await Clipboard.setData(ClipboardData(text: json));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$label: JSON скопирован в буфер')),
      );
    }
  }

  Future<bool> _confirm(String title, String description) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(description.isEmpty ? 'Подтвердите действие' : description),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('OK')),
        ],
      ),
    );
    return result == true;
  }
}

class _ListEditorDialog extends StatefulWidget {
  const _ListEditorDialog({required this.title, required this.items});

  final String title;
  final List<String> items;

  @override
  State<_ListEditorDialog> createState() => _ListEditorDialogState();
}

class _ListEditorDialogState extends State<_ListEditorDialog> {
  late List<String> _items;
  final _ctrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _items = [...widget.items];
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final item in _items)
              ListTile(
                title: Text(item),
                trailing: IconButton(
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: () => setState(() => _items.remove(item)),
                ),
              ),
            TextField(
              controller: _ctrl,
              decoration: const InputDecoration(hintText: 'Добавить элемент'),
              onSubmitted: (v) {
                if (v.trim().isNotEmpty && !_items.contains(v.trim())) {
                  setState(() {
                    _items.add(v.trim());
                    _ctrl.clear();
                  });
                }
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        TextButton(
          onPressed: () => Navigator.pop(context, _items),
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}
