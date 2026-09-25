import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config.dart';
import '../models/settings_catalog.dart';
import '../screens/debug_log_screen.dart';
import '../screens/devices_screen.dart';
import '../screens/private_mode/decoy_pin_setup_screen.dart';
import '../screens/private_mode/pin_setup_screen.dart';
import '../screens/profile_qr_screen.dart';
import '../services/backup_crypto.dart';
import '../services/backup_file_download.dart';
import '../services/catalog_list_store.dart';
import '../services/catalog_seed_service.dart';
import '../services/database_init.dart';
import '../services/debug_log.dart';
import '../services/hidden_chats_store.dart';
import '../services/in_app_notification_service.dart';
import '../services/local_identity_backup.dart';
import '../services/local_backup_codec.dart';
import '../services/media_cache.dart';
import '../services/message_cache_store.dart';
import '../services/persistent_media_store.dart';
import '../services/secure_catalog_secrets.dart';
import '../services/settings_runtime.dart';
import '../services/sensitive_data_cleanup_service.dart';
import '../services/trusted_contacts_store.dart';
import '../security/pin_security.dart';
import '../crypto/crypto_service.dart';
import '../state/app_controller.dart';
import '../screens/private_mode/private_mode_state.dart';
import '../state/notification_settings.dart';
import '../state/settings_catalog_controller.dart';

/// Executes catalog `action` settings and navigates for `secret` settings.
class SettingsCatalogActions {
  static const _userListSettingIds = <String>{
    'privacy.phone_visibility_list',
    'privacy.email_visibility_list',
    'privacy.last_seen_list',
    'privacy.calls_allowlist',
    'security.distress_contacts',
    'contacts.trusted_list',
    'contacts.blocked_list',
  };
  SettingsCatalogActions({
    required this.context,
    required this.ref,
    required this.listStore,
  });

  final BuildContext context;
  final WidgetRef ref;
  final CatalogListStore listStore;

  Future<bool> _ensureCriticalPin(String actionToken) async {
    if (!await SettingsRuntime.instance.requiresPinFor(actionToken)) {
      return true;
    }
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
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (ok != true) return false;
    final valid = await PinSecurity.verifyRealPin(ctrl.text);
    if (!valid && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Неверный PIN')));
    }
    return valid;
  }

  Future<void> runAction(SettingDef def) async {
    if (def.id.startsWith('developer.') && !kDebugMode) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Инструмент доступен только в debug-сборке'),
          ),
        );
      }
      return;
    }
    if (def.requiresConfirmation) {
      final ok = await _confirm(def.title, def.description);
      if (!ok) return;
    }
    switch (def.id) {
      case 'profile.avatar':
        await _updateProfileAvatar();
      case 'profile.qr':
        if (context.mounted) {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const ProfileQrScreen()),
          );
        }
      case 'data.clear_cache':
        MediaCache.instance.clear();
        final cacheUserId = ref.read(appControllerProvider).session?.userId;
        if (cacheUserId != null) {
          await PersistentMediaStore.instance.clearUser(cacheUserId);
        }
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Кэш медиа очищен')));
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
        await _runIntegrityCheck();
      case 'storage.route_audit':
        await _runRouteAudit();
      case 'storage.delete_local':
        if (!await _ensureCriticalPin('delete_profile')) return;
        MediaCache.instance.clear();
        final userId = ref.read(appControllerProvider).session?.userId;
        if (userId != null) {
          await MessageCacheStore.instance.clearUser(userId);
          await PersistentMediaStore.instance.clearUser(userId);
        }
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Локальные копии медиа и истории очищены'),
            ),
          );
        }
      case 'developer.logs':
        if (context.mounted) {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const DebugLogScreen()),
          );
        }
      case 'developer.network_debug':
        await _showNetworkCheck();
      case 'developer.test_notifications':
        InAppNotificationService.instance.notify(
          InAppNotificationEvent(title: 'Тест', body: 'Тестовое уведомление'),
        );
      case 'developer.test_crypto':
        await _runCryptoSelfTest();
      case 'devices.list':
        if (!await _ensureCriticalPin('add_device')) return;
        if (context.mounted) {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const DevicesScreen()),
          );
        }
      case 'storage.access_devices':
        if (!await _ensureCriticalPin('add_device')) return;
        await _showStorageAccessDevices();
      default:
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('«${def.title}» недоступно в этой сборке')),
          );
        }
    }
  }

  Future<void> _updateProfileAvatar() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp'],
      withData: true,
    );
    final file = result?.files.single;
    if (file == null || file.bytes == null || !context.mounted) return;
    if (file.size > 5 * 1024 * 1024) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Изображение должно быть меньше 5 МБ')),
      );
      return;
    }
    await ref.read(appControllerProvider).setProfileAvatar(file.bytes);
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Аватар обновлён')));
    }
  }

  Future<void> _runIntegrityCheck() async {
    final controller = ref.read(appControllerProvider);
    final checks = <String, bool>{
      'Локальная база': DatabaseInit.isInitialized,
      'Сеанс пользователя': controller.session != null,
      'Хранилище шифрования': controller.crypto != null,
      'Ключ устройства': controller.authKeyPair != null,
    };
    final failed = checks.entries.where((entry) => !entry.value).toList();
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          failed.isEmpty ? 'Целостность подтверждена' : 'Найдены проблемы',
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final entry in checks.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(
                      entry.value
                          ? Icons.check_circle_outline
                          : Icons.error_outline,
                      color: entry.value
                          ? Colors.green
                          : Theme.of(dialogContext).colorScheme.error,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(entry.key)),
                  ],
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Готово'),
          ),
        ],
      ),
    );
  }

  Future<void> _runRouteAudit() async {
    final controller = ref.read(appControllerProvider);
    await controller.validateAllConversationsReachability();
    if (!context.mounted) return;
    final failed = controller.failedOutboundCount;
    await _showResultDialog(
      title: failed == 0 ? 'Маршруты доступны' : 'Есть проблемы с доставкой',
      message: failed == 0
          ? 'Недоступных исходящих маршрутов не найдено.'
          : 'В очереди осталось сообщений без доступного маршрута: $failed.',
      ok: failed == 0,
    );
  }

  Future<void> _showNetworkCheck() async {
    final controller = ref.read(appControllerProvider);
    await _showResultDialog(
      title: controller.websocketConnected
          ? 'Соединение активно'
          : 'Соединение ограничено',
      message: [
        'Домашний узел: ${AppConfig.homeNodeUrl}',
        'Шлюз: ${AppConfig.gatewayNodeUrl}',
        'Поиск узлов: ${AppConfig.discoveryNodeUrls.join(', ')}',
        'Канал событий: ${controller.websocketConnected ? 'подключён' : 'не подключён'}',
        'Неотправленных сообщений: ${controller.failedOutboundCount}',
      ].join('\n'),
      ok: controller.websocketConnected,
    );
  }

  Future<void> _showStorageAccessDevices() async {
    final devices = ref.read(appControllerProvider).devices;
    await _showResultDialog(
      title: 'Доступ к локальным данным',
      message: devices.isEmpty
          ? 'Зарегистрированных устройств нет.'
          : devices
                .map(
                  (device) =>
                      '${device.deviceName} · ${device.deviceType}${device.isCurrent ? ' · это устройство' : ''}',
                )
                .join('\n'),
      ok: true,
    );
  }

  Future<void> _showResultDialog({
    required String title,
    required String message,
    required bool ok,
  }) async {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(
          ok ? Icons.check_circle_outline : Icons.warning_amber_outlined,
          color: ok ? Colors.green : Theme.of(dialogContext).colorScheme.error,
        ),
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Готово'),
          ),
        ],
      ),
    );
  }

  Future<void> _runCryptoSelfTest() async {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Проверяем локальное шифрование…')),
      );
    }
    try {
      final first = CryptoService.ephemeral();
      final second = CryptoService.ephemeral();
      await first.establishSessionFromBundle(
        'test-device-2',
        await second.generatePublishableBundle(preKeyCount: 1),
      );
      const source = 'local encryption self-test';
      final encrypted = await first.encrypt(
        'test-device-2',
        utf8.encode(source),
      );
      final decrypted = await second.decrypt('test-device-1', encrypted);
      final passed =
          utf8.decode(decrypted) == source && !encrypted.contains(source);
      if (!passed) throw StateError('Результат расшифровки не совпал');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Шифрование работает корректно')),
        );
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка проверки шифрования: $error')),
        );
      }
    }
  }

  Future<void> openSecret(SettingDef def) async {
    switch (def.id) {
      case 'security.pin':
        if (!context.mounted) return;
        await Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const PinSetupScreen()));
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
      case 'backup.password':
        await _setBackupPassword();
      default:
        await _editSecureCatalogSecret(def);
    }
  }

  Future<void> _editSecureCatalogSecret(SettingDef def) async {
    if (!context.mounted || def.storage != 'local_encrypted') return;
    final configured = (await SecureCatalogSecrets.read(def.id)).isNotEmpty;
    if (!context.mounted) return;
    final controller = TextEditingController();
    String? validationError;
    final update = await showDialog<_SecretUpdate>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(def.title),
          content: TextField(
            controller: controller,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            autofocus: true,
            maxLength: (def.maxLength ?? 4096).clamp(1, 4096),
            decoration: InputDecoration(
              labelText: configured ? 'Новое значение' : 'Значение',
              helperText: configured
                  ? 'Секрет уже настроен; текущее значение не отображается'
                  : 'Будет сохранено в защищённом хранилище устройства',
              errorText: validationError,
            ),
          ),
          actions: [
            if (configured)
              TextButton(
                onPressed: () =>
                    Navigator.pop(ctx, const _SecretUpdate.remove()),
                child: const Text('Удалить'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Отмена'),
            ),
            TextButton(
              onPressed: () {
                final value = controller.text;
                final minimum = def.minLength ?? 1;
                final maximum = (def.maxLength ?? 4096).clamp(1, 4096);
                var valid = value.length >= minimum && value.length <= maximum;
                final pattern = def.pattern;
                if (valid && pattern != null && pattern.isNotEmpty) {
                  try {
                    valid = RegExp(pattern).hasMatch(value);
                  } on FormatException {
                    valid = false;
                  }
                }
                if (!valid) {
                  setLocal(() {
                    validationError = 'Допустимая длина: $minimum–$maximum';
                  });
                  return;
                }
                Navigator.pop(ctx, _SecretUpdate.write(value));
              },
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (update == null) return;
    if (update.remove) {
      await SecureCatalogSecrets.remove(def.id);
    } else {
      await SecureCatalogSecrets.write(def.id, update.value!);
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            update.remove
                ? 'Защищённое значение удалено'
                : 'Защищённое значение сохранено на этом устройстве',
          ),
        ),
      );
    }
  }

  Future<void> _setBackupPassword() async {
    if (!context.mounted) return;
    final first = TextEditingController();
    final second = TextEditingController();
    String? error;
    final password = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Пароль резервной копии'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: first,
                obscureText: true,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Новый пароль'),
              ),
              TextField(
                controller: second,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'Повторите пароль',
                  errorText: error,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Отмена'),
            ),
            TextButton(
              onPressed: () {
                if (first.text.length < 12) {
                  setLocal(() => error = 'Минимум 12 символов');
                } else if (first.text != second.text) {
                  setLocal(() => error = 'Пароли не совпадают');
                } else {
                  Navigator.pop(ctx, first.text);
                }
              },
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
    if (password == null) return;
    await SecureCatalogSecrets.write('backup.password', password);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Пароль сохранён только на этом устройстве'),
        ),
      );
    }
  }

  Future<void> editList(SettingDef def) async {
    final items = await listStore.load(def.id);
    if (!context.mounted) return;
    final app = ref.read(appControllerProvider);
    final edited = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => _userListSettingIds.contains(def.id)
          ? _UserListPickerDialog(
              title: def.title,
              selectedIds: items,
              contacts: {
                for (final entry in app.knownDisplayNames.entries)
                  if (entry.key != app.session?.userId &&
                      RegExp(
                        r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
                        caseSensitive: false,
                      ).hasMatch(entry.key))
                    entry.key: entry.value,
              },
            )
          : _ListEditorDialog(title: def.title, items: items),
    );
    if (edited != null) {
      await listStore.save(def.id, edited);
      if (def.id == 'notifications.dnd_schedule' ||
          def.id == 'notifications.dnd_exceptions') {
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

  Future<void> _createBackup() async {
    if (!await SettingsRuntime.instance.backupEnabled()) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Сначала включите резервное копирование'),
          ),
        );
      }
      return;
    }
    if (!backupFileDownloadSupported) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Экспорт резервной копии в файл не поддерживается на этой платформе',
            ),
          ),
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
        'phone': app.phone ?? await runtime.phone(),
        'email': app.email ?? await runtime.email(),
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
          if (contacts.length == 500) break;
        }
        if (contacts.length == 500) break;
      }
      blob['contacts'] = contacts;
    }
    if (contents.contains('messages')) {
      final conversations = <Map<String, dynamic>>[];
      for (final c in app.conversations.take(200)) {
        final msgs = app.messagesByConversation[c.id] ?? const [];
        conversations.add({
          'id': c.id,
          'messages': [
            for (final m in msgs.take(200)) LocalBackupCodec.encodeMessage(m),
          ],
        });
      }
      blob['messages'] = conversations;
    }
    if (contents.contains('hidden_chats')) {
      blob['hidden_chats'] = (await listStore.load(
        'hidden.chat_list',
      )).take(500).toList();
    }
    if (contents.contains('keys')) {
      blob['keys'] = await LocalIdentityBackup.export();
    }
    if (contents.contains('media')) {
      final userId = app.session?.userId;
      blob['media'] = userId == null
          ? <String, String>{}
          : await PersistentMediaStore.instance.exportUser(userId);
    }

    String outText;
    final includesKeys = contents.contains('keys');
    final containsSensitiveData = LocalBackupCodec.requiresEncryption(contents);
    if (containsSensitiveData || await runtime.backupEncryption()) {
      final password = await runtime.backupPassword();
      if (password.trim().isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                includesKeys
                    ? 'Копия с ключами обязательно шифруется. Задайте backup.password'
                    : 'Копия с личными данными обязательно шифруется. Задайте backup.password',
              ),
            ),
          );
        }
        return;
      }
      final envelope = await BackupCrypto.encryptJson(blob, password);
      outText = const JsonEncoder.withIndent('  ').convert(envelope);
    } else {
      outText = const JsonEncoder.withIndent('  ').convert(blob);
    }

    final downloaded = await downloadBackupFile(
      outText,
      'ouo-backup-${DateTime.now().toUtc().toIso8601String().replaceAll(':', '-')}.json',
    );
    if (downloaded) await runtime.markLastBackup();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            downloaded
                ? 'Резервная копия сохранена в файл'
                : 'Сохранение резервной копии отменено',
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
    if (bytes.length > 256 * 1024 * 1024) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Файл резервной копии слишком большой')),
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
      final wasEncrypted = decoded['kind'] == 'encrypted_settings_backup';
      if (wasEncrypted) {
        var password = await SettingsRuntime.instance.backupPassword();
        if (password.trim().isEmpty) {
          password = await _askBackupPassword() ?? '';
        }
        if (password.isEmpty) return;
        decoded = await BackupCrypto.decryptJson(decoded, password);
      }
      LocalBackupCodec.rejectSensitivePlaintext(
        decoded,
        wasEncrypted: wasEncrypted,
      );
      LocalBackupCodec.validateRestorePayload(decoded);
      final app = ref.read(appControllerProvider);
      final keys = decoded['keys'];
      if (keys is Map<String, dynamic> &&
          (keys['user_id'] != app.session?.userId ||
              keys['device_id'] != app.session?.deviceId)) {
        throw const FormatException(
          'Ключи копии принадлежат другому аккаунту или устройству',
        );
      }
      final profile = decoded['profile'];
      if (profile is Map && profile['user_id'] != app.session?.userId) {
        throw const FormatException(
          'Профиль копии принадлежит другому аккаунту',
        );
      }
      final settingsPart =
          decoded['settings'] as Map<String, dynamic>? ?? decoded;
      final catalog = await ref.read(settingsCatalogProvider.future);
      final n = await CatalogSeedService().applyJson(catalog, settingsPart);
      if (keys is Map<String, dynamic>) {
        await LocalIdentityBackup.restore(keys);
        await app.reloadLocalCryptographicIdentity();
      }
      final media = decoded['media'];
      final userId = ref.read(appControllerProvider).session?.userId;
      if (media is Map<String, dynamic> && userId != null) {
        await PersistentMediaStore.instance.importUser(userId, media);
      }
      var restoredProfile = false;
      if (profile is Map) {
        await app.loadMyProfile();
        final displayName = LocalBackupCodec.boundedString(
          profile['display_name'],
          maxLength: 120,
        );
        if (displayName == null || displayName.trim().isEmpty) {
          throw const FormatException('В копии отсутствует имя профиля');
        }
        await app.updateOwnProfile(
          displayName: displayName.trim(),
          login:
              LocalBackupCodec.boundedString(
                profile['username'],
                maxLength: 120,
              ) ??
              app.login ??
              '',
          phone:
              LocalBackupCodec.boundedString(profile['phone'], maxLength: 64) ??
              app.phone ??
              '',
          email:
              LocalBackupCodec.boundedString(
                profile['email'],
                maxLength: 254,
              ) ??
              app.email ??
              '',
          bio:
              LocalBackupCodec.boundedString(profile['bio'], maxLength: 1000) ??
              app.bio ??
              '',
        );
        restoredProfile = true;
      }
      var restoredContacts = 0;
      final contacts = decoded['contacts'];
      if (contacts is List) {
        for (final raw in contacts.take(500)) {
          if (raw is! Map) continue;
          final id = raw['user_id'];
          final name = raw['display_name'];
          if (id is! String ||
              name is! String ||
              name.trim().isEmpty ||
              name.length > 120 ||
              !RegExp(
                r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
                caseSensitive: false,
              ).hasMatch(id)) {
            continue;
          }
          await app.setContactAlias(id, name.trim());
          restoredContacts++;
        }
      }
      final messageSection = decoded.containsKey('messages')
          ? decoded['messages']
          : decoded['conversations'];
      final restoredMessages = await app.restoreLocalMessageHistory(
        LocalBackupCodec.decodeMessages(messageSection),
      );
      final hidden = decoded['hidden_chats'];
      if (hidden is List) {
        final ids = hidden
            .whereType<String>()
            .where((id) => id.isNotEmpty && id.length <= 128)
            .take(500)
            .toSet();
        await HiddenChatsStore.instance.saveSecretHiddenIds(ids);
        await app.reloadSecretHiddenFromStore();
      }
      await ref.read(settingsCatalogValuesProvider).reloadFromLegacy(catalog);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              keys is Map<String, dynamic>
                  ? 'Восстановлено: настройки $n, профиль ${restoredProfile ? 1 : 0}, контакты $restoredContacts, сообщения $restoredMessages и локальные ключи'
                  : 'Восстановлено: настройки $n, профиль ${restoredProfile ? 1 : 0}, контакты $restoredContacts, сообщения $restoredMessages',
            ),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Ошибка восстановления: $e')));
      }
    }
  }

  Future<String?> _askBackupPassword() async {
    if (!context.mounted) return null;
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Пароль копии'),
        content: TextField(
          controller: controller,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Пароль, заданный при создании файла',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Расшифровать'),
          ),
        ],
      ),
    );
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
    payload['bio'] = await runtime.bio();
    await _exportJsonFile('Профиль', 'profile', payload);
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
    await _exportJsonFile('История', 'history', {
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
        contacts.add({'user_id': id, 'display_name': app.labelFor(id)});
      }
    }
    await _exportJsonFile('Контакты', 'contacts', {
      'exported_at': DateTime.now().toIso8601String(),
      'contacts': contacts,
    });
  }

  Future<void> _clearLocalData() async {
    MediaCache.instance.clear();
    final app = ref.read(appControllerProvider);
    final userId = app.session?.userId;
    final failures = <String, Object>{};
    if (userId != null) {
      final report = await const SensitiveDataCleanupService().clearAccountData(
        userId,
      );
      failures.addAll(report.failures);
      for (final id in app.messagesByConversation.keys.toList()) {
        try {
          await app.clearLocalHistory(id);
        } catch (error) {
          failures.putIfAbsent('conversation_history', () => error);
        }
      }
      try {
        await ref.read(privateModeStateProvider).reset();
      } catch (error) {
        failures['private_mode'] = error;
      }
    }
    _logCleanupFailures('local cleanup', failures);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            failures.isEmpty
                ? 'Локальные данные и настройки очищены'
                : 'Часть хранилищ не очищена; повторите безопасную очистку',
          ),
        ),
      );
    }
  }

  Future<void> _deleteLocalProfile() async {
    final app = ref.read(appControllerProvider);
    final userId = app.session?.userId;
    final failures = <String, Object>{};
    if (userId != null) {
      final report = await const SensitiveDataCleanupService().clearAccountData(
        userId,
      );
      failures.addAll(report.failures);
      try {
        await ref.read(privateModeStateProvider).reset();
      } catch (error) {
        failures['private_mode'] = error;
      }
    }
    MediaCache.instance.clear();
    final identityReport = await const SensitiveDataCleanupService()
        .wipeIdentity();
    failures.addAll(identityReport.failures);
    try {
      await app.logout();
    } catch (error) {
      failures['logout'] = error;
    }
    _logCleanupFailures('profile deletion', failures);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            failures.isEmpty
                ? 'Профиль, ключи и локальные данные удалены'
                : 'Удаление выполнено не полностью; повторите безопасную очистку',
          ),
        ),
      );
    }
  }

  void _logCleanupFailures(String operation, Map<String, Object> failures) {
    for (final entry in failures.entries) {
      DebugLog.instance.error(
        'data',
        '$operation failed for ${entry.key}',
        entry.value,
      );
    }
  }

  Future<void> _revokeOtherDevices() async {
    try {
      await ref.read(appControllerProvider).revokeOtherDevices();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Сеансы на других устройствах завершены'),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
      }
    }
  }

  Future<void> _exportJsonFile(
    String label,
    String fileKind,
    Map<String, dynamic> payload,
  ) async {
    if (!backupFileDownloadSupported) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Экспорт файлов не поддерживается на этой платформе'),
          ),
        );
      }
      return;
    }
    final json = const JsonEncoder.withIndent('  ').convert(payload);
    final timestamp = DateTime.now().toUtc().toIso8601String().replaceAll(
      ':',
      '-',
    );
    final saved = await downloadBackupFile(
      json,
      'ouo-$fileKind-$timestamp.json',
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            saved ? '$label: файл сохранён' : '$label: сохранение отменено',
          ),
        ),
      );
    }
  }

  Future<bool> _confirm(String title, String description) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(
          description.isEmpty ? 'Подтвердите действие' : description,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    return result == true;
  }
}

class _SecretUpdate {
  const _SecretUpdate.write(this.value) : remove = false;
  const _SecretUpdate.remove() : value = null, remove = true;

  final String? value;
  final bool remove;
}

class _UserListPickerDialog extends StatefulWidget {
  const _UserListPickerDialog({
    required this.title,
    required this.selectedIds,
    required this.contacts,
  });

  final String title;
  final List<String> selectedIds;
  final Map<String, String> contacts;

  @override
  State<_UserListPickerDialog> createState() => _UserListPickerDialogState();
}

class _UserListPickerDialogState extends State<_UserListPickerDialog> {
  final _searchController = TextEditingController();
  late final Set<String> _selected = {...widget.selectedIds};
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final contacts =
        widget.contacts.entries
            .where(
              (entry) =>
                  _query.isEmpty ||
                  entry.value.toLowerCase().contains(_query) ||
                  entry.key.toLowerCase().contains(_query),
            )
            .toList()
          ..sort((a, b) => a.value.compareTo(b.value));
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 520,
        height: 460,
        child: Column(
          children: [
            TextField(
              controller: _searchController,
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Найти контакт',
              ),
              onChanged: (value) =>
                  setState(() => _query = value.trim().toLowerCase()),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: contacts.isEmpty
                  ? Center(
                      child: Text(
                        widget.contacts.isEmpty
                            ? 'Контактов пока нет. Сначала начните переписку или добавьте контакт.'
                            : 'Ничего не найдено',
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView.builder(
                      itemCount: contacts.length,
                      itemBuilder: (context, index) {
                        final contact = contacts[index];
                        return CheckboxListTile(
                          value: _selected.contains(contact.key),
                          title: Text(contact.value),
                          subtitle: Text(
                            contact.key,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onChanged: (selected) => setState(() {
                            if (selected == true) {
                              _selected.add(contact.key);
                            } else {
                              _selected.remove(contact.key);
                            }
                          }),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _selected.toList()),
          child: Text('Готово · ${_selected.length}'),
        ),
      ],
    );
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
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _items),
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}
