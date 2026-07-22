import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/extensions/context_extensions.dart';
import '../core/theme/app_spacing.dart';
import '../core/ui/app_button.dart';
import '../core/ui/app_card.dart';
import '../services/api_client.dart';
import '../services/settings_runtime.dart';
import '../state/app_controller.dart';
import '../utils/api_errors.dart';
import '../utils/user_id.dart';
import '../widgets/app_text_field.dart';
import 'chat_screen.dart';
import 'qr_scanner_screen.dart';

/// Начать чат.
/// Основной путь — QR-сканирование при личном присутствии.
/// Дополнительно — по User ID или Username (если разрешено приватностью).
class NewChatScreen extends ConsumerStatefulWidget {
  const NewChatScreen({super.key});

  @override
  ConsumerState<NewChatScreen> createState() => _NewChatScreenState();
}

enum _FallbackMode { userId, username }

class _NewChatScreenState extends ConsumerState<NewChatScreen> {
  final _idController = TextEditingController();
  final _nameController = TextEditingController();
  final _usernameController = TextEditingController();

  bool _scanning = false;
  bool _loading = false;
  String? _error;
  bool _showFallback = false;
  _FallbackMode _fallbackMode = _FallbackMode.userId;

  @override
  void dispose() {
    _idController.dispose();
    _nameController.dispose();
    _usernameController.dispose();
    super.dispose();
  }

  // ── QR-путь ────────────────────────────────────────────────────────────────

  Future<void> _scanQr() async {
    setState(() {
      _scanning = true;
      _error = null;
    });

    final payload = await QrScannerScreen.open(context);
    if (!mounted) return;

    setState(() => _scanning = false);

    if (payload == null) return; // пользователь закрыл сканер

    if (payload.isExpired) {
      setState(() => _error = 'QR-код истёк — попросите собеседника обновить его');
      return;
    }

    await _openChat(payload.userId, payload.displayName);
  }

  // ── Ручной ввод ─────────────────────────────────────────────────────────────

  Future<void> _startManual() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final controller = ref.read(appControllerProvider);

      switch (_fallbackMode) {
        case _FallbackMode.username:
          if (!await SettingsRuntime.instance.usernameSearchAllowed()) {
            setState(() => _error = 'Поиск по username отключён в настройках приватности');
            return;
          }
          final login = _usernameController.text.trim();
          if (login.length < 3) {
            setState(() => _error = 'Username минимум 3 символа');
            return;
          }
          final api = ApiClient(accessToken: controller.session?.accessToken);
          final found = await api.searchUserByLogin(login);
          final id = found['user_id'] as String;
          final label = found['display_name'] as String? ?? login;
          await _openChat(id, label);

        case _FallbackMode.userId:
          final id = normalizeUserId(_idController.text);
          if (id.isEmpty || !isValidUserIdFormat(id)) {
            setState(() => _error = userIdFormatHint());
            return;
          }
          final label = _nameController.text.trim();
          await _openChat(id, label.isEmpty ? id : label);
      }
    } catch (e) {
      setState(() => _error = friendlyApiError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openChat(String userId, String displayName) async {
    try {
      final conv = await ref
          .read(appControllerProvider)
          .startDirectChat(userId, displayName);
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => ChatScreen(conversation: conv)),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = friendlyApiError(e));
    }
  }

  // ── UI ──────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final text = context.textStyles;
    final colors = context.colors;
    final myId = ref.watch(appControllerProvider).session?.userId;

    return Scaffold(
      appBar: AppBar(title: const Text('Новый чат')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.screenPadding),
        children: [
          // ── Мой QR (краткая плашка) ──────────────────────────────────
          if (myId != null)
            AppCard(
              child: Row(
                children: [
                  Icon(Icons.qr_code_2, size: 36, color: colors.primary),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Ваш User ID', style: text.caption),
                        SelectableText(myId,
                            style: text.body.copyWith(fontSize: 13)),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy_outlined, size: 18),
                    tooltip: 'Скопировать',
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: myId));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('User ID скопирован')),
                      );
                    },
                  ),
                ],
              ),
            ),

          const SizedBox(height: AppSpacing.xl),

          // ── Главная кнопка: сканировать QR ───────────────────────────
          AppButton(
            label: _scanning ? 'Открываю камеру…' : 'Сканировать QR',
            onPressed: (_scanning || _loading) ? null : _scanQr,
            loading: _scanning,
          ),

          const SizedBox(height: AppSpacing.sm),

          Text(
            'Попросите собеседника открыть «Мой QR» и наведите камеру.\n'
            'Знакомство происходит при личном присутствии — без телефонов и имён.',
            style: text.caption.copyWith(color: colors.textSecondary),
            textAlign: TextAlign.center,
          ),

          const SizedBox(height: AppSpacing.xl),
          Divider(color: colors.divider),
          const SizedBox(height: AppSpacing.md),

          // ── Дополнительные способы ───────────────────────────────────
          GestureDetector(
            onTap: () => setState(() => _showFallback = !_showFallback),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('Другие способы', style: text.caption.copyWith(color: colors.primary)),
                const SizedBox(width: 4),
                Icon(
                  _showFallback ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: colors.primary,
                ),
              ],
            ),
          ),

          if (_showFallback) ...[
            const SizedBox(height: AppSpacing.md),

            // Переключатель режима
            SegmentedButton<_FallbackMode>(
              segments: const [
                ButtonSegment(
                  value: _FallbackMode.userId,
                  label: Text('User ID'),
                  icon: Icon(Icons.badge_outlined),
                ),
                ButtonSegment(
                  value: _FallbackMode.username,
                  label: Text('Username'),
                  icon: Icon(Icons.alternate_email),
                ),
              ],
              selected: {_fallbackMode},
              onSelectionChanged: (s) =>
                  setState(() => _fallbackMode = s.first),
            ),

            const SizedBox(height: AppSpacing.md),

            if (_fallbackMode == _FallbackMode.username) ...[
              Text('Username собеседника:', style: text.secondary),
              const SizedBox(height: AppSpacing.sm),
              AppTextField(
                controller: _usernameController,
                hintText: 'username',
              ),
            ] else ...[
              Text(
                'User ID собеседника (из Настройки → Аккаунт):',
                style: text.secondary,
              ),
              const SizedBox(height: AppSpacing.sm),
              AppTextField(
                controller: _idController,
                hintText: 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx',
              ),
              const SizedBox(height: AppSpacing.sm),
              Text('Как подписать чат (необязательно):', style: text.secondary),
              const SizedBox(height: AppSpacing.sm),
              AppTextField(controller: _nameController, hintText: 'Имя'),
            ],

            const SizedBox(height: AppSpacing.md),

            AppButton(
              label: 'Начать чат',
              onPressed: (_loading || _scanning) ? null : _startManual,
              loading: _loading,
            ),
          ],

          // ── Ошибка ───────────────────────────────────────────────────
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.md),
            AppCard(
              child: Row(
                children: [
                  Icon(Icons.error_outline, color: colors.danger, size: 20),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      _error!,
                      style: text.caption.copyWith(color: colors.danger),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
