import 'package:flutter/material.dart';

import '../core/extensions/context_extensions.dart';
import '../core/theme/app_spacing.dart';
import '../core/ui/app_button.dart';
import '../security/pin_security.dart';
import '../services/hidden_vault_session.dart';
import '../services/settings_runtime.dart';
import '../screens/private_mode/hidden_chats_screen.dart';

/// PIN gate before opening hidden chats (outside full Private Mode flow).
class HiddenChatsAccess {
  HiddenChatsAccess._();

  static Future<bool> openWithPin(BuildContext context) async {
    if (!await SettingsRuntime.instance.hiddenEnabled()) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Скрытые чаты отключены')),
        );
      }
      return false;
    }

    if (!await PinSecurity.isRealPinConfigured()) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Сначала настройте PIN в Private Mode')),
        );
      }
      return false;
    }

    if (!context.mounted) return false;

    final pin = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => const _PinEntrySheet(),
    );
    if (pin == null || pin.isEmpty) return false;

    final result = await PinSecurity.evaluatePin(pin);
    if (result != PinUnlockResult.realPin) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Неверный PIN')));
      }
      return false;
    }

    if (!context.mounted) return false;
    await HiddenVaultSession.instance.unlock(pin);
    if (!context.mounted) return false;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HiddenChatsScreen()));
    return true;
  }
}

class _PinEntrySheet extends StatefulWidget {
  const _PinEntrySheet();

  @override
  State<_PinEntrySheet> createState() => _PinEntrySheetState();
}

class _PinEntrySheetState extends State<_PinEntrySheet> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = context.textStyles;

    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.screenPadding,
        right: AppSpacing.screenPadding,
        top: AppSpacing.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Скрытые чаты', style: text.title),
          const SizedBox(height: AppSpacing.sm),
          Text('Введите PIN Private Mode', style: text.caption),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _controller,
            obscureText: true,
            keyboardType: TextInputType.number,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'PIN'),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
          const SizedBox(height: AppSpacing.md),
          AppButton(
            label: 'Открыть',
            onPressed: () => Navigator.pop(context, _controller.text),
          ),
        ],
      ),
    );
  }
}
