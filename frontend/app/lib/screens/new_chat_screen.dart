import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/extensions/context_extensions.dart';
import '../core/theme/app_spacing.dart';
import '../core/ui/app_card.dart';
import '../core/ui/app_form_body.dart';
import '../core/ui/app_notice.dart';
import '../core/ui/app_page.dart';
import '../core/ui/app_button.dart';
import '../core/ui/app_search_field.dart';
import '../services/api_client.dart';
import '../services/settings_runtime.dart';
import '../services/contact_pairing_store.dart';
import '../state/app_controller.dart';
import '../utils/api_errors.dart';
import '../utils/user_id.dart';
import 'chat_screen.dart';
import 'profile_qr_scanner_screen.dart';

enum _SearchMode { userId, username }

/// Start a chat by User ID or username (gated by privacy settings).
class NewChatScreen extends ConsumerStatefulWidget {
  const NewChatScreen({super.key});

  @override
  ConsumerState<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends ConsumerState<NewChatScreen> {
  final _idController = TextEditingController();
  final _nameController = TextEditingController();
  final _usernameController = TextEditingController();
  bool _loading = false;
  String? _error;
  _SearchMode _mode = _SearchMode.userId;

  Future<void> _scanProfileQr() async {
    final result = await Navigator.of(context).push<ProfileQrResult>(
      MaterialPageRoute(builder: (_) => const ProfileQrScannerScreen()),
    );
    if (result == null || !mounted) return;
    try {
      final controller = ref.read(appControllerProvider);
      if (result.userId == controller.session?.userId) {
        throw StateError('Нельзя добавить собственный QR как контакт');
      }
      final api = ApiClient(accessToken: controller.session?.accessToken);
      final record = await api.getDiscoveryUserRecord(result.userId);
      final registeredAuthKey = record['auth_public_key'];
      if (registeredAuthKey is! String ||
          registeredAuthKey != result.handshake.authPublicKey) {
        throw StateError(
          'Ключ QR не совпадает с зарегистрированным ключом пользователя',
        );
      }
      final devices = await api.getUserDeviceBundles(result.userId);
      final matchingDevices = devices
          .where(
            (device) =>
                device['identity_key'] == result.handshake.identityPublicKey,
          )
          .toList(growable: false);
      if (matchingDevices.length != 1) {
        throw StateError(
          'Устройство из QR не найдено или его ключ неоднозначен',
        );
      }
      final deviceId = matchingDevices.single['device_id'];
      if (deviceId is! String || deviceId.isEmpty || deviceId.length > 64) {
        throw StateError('Сервер вернул некорректный идентификатор устройства');
      }
      await ContactPairingStore().save(result.handshake, deviceId: deviceId);
    } catch (error) {
      if (mounted) setState(() => _error = friendlyApiError(error));
      return;
    }
    if (!mounted) return;
    setState(() {
      _mode = _SearchMode.userId;
      _idController.text = result.userId;
      // The display name is received later through the encrypted channel.
      _nameController.clear();
      _error = null;
    });
  }

  Future<void> _start() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final controller = ref.read(appControllerProvider);
      String id;
      String label;
      switch (_mode) {
        case _SearchMode.username:
          if (!await SettingsRuntime.instance.usernameSearchAllowed()) {
            setState(
              () => _error =
                  'Поиск по username отключён в настройках приватности',
            );
            return;
          }
          final login = _usernameController.text.trim();
          if (login.length < 3) {
            setState(() => _error = 'Username минимум 3 символа');
            return;
          }
          final api = ApiClient(accessToken: controller.session?.accessToken);
          final found = await api.searchUserByLogin(login);
          id = found['user_id'] as String;
          label = found['display_name'] as String? ?? login;
        case _SearchMode.userId:
          id = normalizeUserId(_idController.text);
          label = _nameController.text.trim();
          if (id.isEmpty) {
            setState(() => _error = userIdFormatHint());
            return;
          }
          if (!isValidUserIdFormat(id)) {
            setState(() => _error = userIdFormatHint());
            return;
          }
      }
      final conv = await controller.startDirectChat(
        id,
        label.isEmpty ? id : label,
      );
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => ChatScreen(conversation: conv)),
        );
      }
    } catch (e) {
      setState(() => _error = friendlyApiError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _idController.dispose();
    _nameController.dispose();
    _usernameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final myId = ref.watch(appControllerProvider).session?.userId;

    final colors = context.colors;
    final text = context.textStyles;
    return AppPage(
      title: 'Новый чат',
      scroll: false,
      child: AppFormBody(
        maxWidth: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (myId != null) ...[
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Ваш User ID (отправьте собеседнику):',
                      style: text.caption.copyWith(color: colors.textSecondary),
                    ),
                    const SizedBox(height: AppSpacing.smallGap / 2),
                    Row(
                      children: [
                        Expanded(child: SelectableText(myId, style: text.body)),
                        IconButton(
                          icon: const Icon(Icons.copy, size: 18),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: myId));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Ваш User ID скопирован'),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
            ],
            OutlinedButton.icon(
              onPressed: _loading ? null : _scanProfileQr,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Сканировать QR собеседника'),
            ),
            const SizedBox(height: AppSpacing.lg),
            SegmentedButton<_SearchMode>(
              segments: const [
                ButtonSegment(
                  value: _SearchMode.userId,
                  label: Text('ID'),
                  icon: Icon(Icons.badge_outlined),
                ),
                ButtonSegment(
                  value: _SearchMode.username,
                  label: Text('User'),
                  icon: Icon(Icons.alternate_email),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
            const SizedBox(height: AppSpacing.lg),
            if (_mode == _SearchMode.username) ...[
              Text(
                'Username собеседника:',
                style: text.secondary.copyWith(color: colors.textSecondary),
              ),
              const SizedBox(height: AppSpacing.sm),
              AppTextField(
                controller: _usernameController,
                hintText: 'kekwekke_user',
              ),
            ] else ...[
              Text(
                'User ID собеседника (UUID из Настройки → Аккаунт):',
                style: text.secondary.copyWith(color: colors.textSecondary),
              ),
              const SizedBox(height: AppSpacing.sm),
              AppTextField(
                controller: _idController,
                hintText: 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx',
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                'Как подписать чат у себя (необязательно):',
                style: text.secondary.copyWith(color: colors.textSecondary),
              ),
              const SizedBox(height: AppSpacing.sm),
              AppTextField(controller: _nameController, hintText: 'Имя'),
            ],
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.md),
              AppNotice(message: _error!, tone: AppNoticeTone.danger),
            ],
            const SizedBox(height: AppSpacing.xl),
            AppButton(
              label: 'Начать чат',
              onPressed: _loading ? null : _start,
              loading: _loading,
            ),
          ],
        ),
      ),
    );
  }
}
