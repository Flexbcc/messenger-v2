import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/extensions/context_extensions.dart';
import '../core/theme/app_spacing.dart';
import '../core/ui/app_button.dart';
import '../core/ui/app_card.dart';
import '../core/ui/app_search_field.dart';
import '../crypto/auth_keypair.dart';
import '../services/api_client.dart';
import '../services/local_settings_store.dart';
import '../services/ppc/ppc_client.dart';
import '../services/ppc/ppc_payload.dart';
import '../services/ppc/ppc_vault.dart';
import '../services/settings_catalog_bridge.dart';
import '../state/app_controller.dart';

/// Pair messenger with storage-app on a home PC (node-mode or direct-mode).
/// See storage-app/docs/PAIRING-FLOWS.md.
class PersonalPcPairingScreen extends ConsumerStatefulWidget {
  const PersonalPcPairingScreen({super.key});

  @override
  ConsumerState<PersonalPcPairingScreen> createState() => _PersonalPcPairingScreenState();
}

class _PersonalPcPairingScreenState extends ConsumerState<PersonalPcPairingScreen> {
  final _userIdController = TextEditingController();
  final _payloadController = TextEditingController();
  final _scannerController = MobileScannerController();

  bool _loading = false;
  bool _scanning = false;
  bool _scanHandled = false;
  String? _error;
  String? _success;
  String? _detectedIntent;
  bool _alreadyPairedDirect = false;
  bool _mediaOnSenderDevice = false;

  @override
  void initState() {
    super.initState();
    final userId = ref.read(appControllerProvider).session?.userId;
    if (userId != null) _userIdController.text = userId;
    _payloadController.addListener(() => _onPayloadChanged(_payloadController.text));
    PpcVault().isPaired().then((paired) {
      if (mounted) setState(() => _alreadyPairedDirect = paired);
    });
    _loadMediaLocationSetting();
  }

  Future<void> _loadMediaLocationSetting() async {
    final location = await LocalSettingsStore().getString(
      SettingsCatalogBridge.catalogKey('storage.media_location'),
      'personal_node_s3',
    );
    if (!mounted) return;
    setState(() => _mediaOnSenderDevice = location == 'sender_device');
  }

  @override
  void dispose() {
    _userIdController.dispose();
    _payloadController.dispose();
    _scannerController.dispose();
    super.dispose();
  }

  void _onPayloadChanged(String value) {
    setState(() {
      _error = null;
      _success = null;
      _detectedIntent = _tryDetectIntent(value);
    });
  }

  String? _tryDetectIntent(String raw) {
    try {
      return PpcPairingPayload.parse(raw).intent;
    } catch (_) {
      return null;
    }
  }

  String? _intentHint(String? intent) {
    return switch (intent) {
      'node' =>
        'Телефон только передаёт код вашей ноде. Файлы потом идут через ноду на ПК.',
      'direct' => 'Телефон сам подключается к ПК. Нода для хранения не нужна.',
      _ => null,
    };
  }

  String _friendlyPairError(String message) {
    final m = message.toLowerCase();
    if (m.contains('expired') ||
        m.contains('устарел') ||
        m.contains('bad or expired pairing code')) {
      return 'Код устарел — сгенерируйте новый на ПК';
    }
    if (m.contains('unreachable') ||
        m.contains('no route') ||
        m.contains('не достучалась')) {
      return 'Нода не достучалась до ПК';
    }
    if (m.contains('invalid or expired token') || m.contains('missing bearer token')) {
      return 'Войдите в аккаунт и попробуйте снова';
    }
    if (m.contains('invalid json') || m.contains('unexpected kind')) {
      return 'Неверный QR — отсканируйте код с домашнего ПК';
    }
    return message;
  }

  String _resolveUserId({required bool isLoggedIn, String? sessionUserId}) {
    if (isLoggedIn && sessionUserId != null) {
      return sessionUserId;
    }
    return _userIdController.text.trim();
  }

  Future<void> _pair({required bool isLoggedIn, String? sessionUserId}) async {
    final payloadRaw = _payloadController.text.trim();
    final userId = _resolveUserId(isLoggedIn: isLoggedIn, sessionUserId: sessionUserId);

    if (userId.isEmpty) {
      setState(() {
        _error = 'Укажите ID пользователя';
        _success = null;
      });
      return;
    }
    if (payloadRaw.isEmpty) {
      setState(() {
        _error = 'Отсканируйте QR-код с домашнего ПК';
        _success = null;
      });
      return;
    }

    PpcPairingPayload payload;
    try {
      payload = PpcPairingPayload.parse(payloadRaw);
    } on PpcPayloadError catch (e) {
      setState(() {
        _error = _friendlyPairError(e.message);
        _success = null;
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      _success = null;
      _detectedIntent = payload.intent;
    });

    try {
      if (payload.intent == 'direct') {
        final controller = ref.read(appControllerProvider);
        final authKeyPair = controller.authKeyPair ?? await AuthKeyPair.loadOrCreate();
        final client = PpcClient.fromAuth(
          authKeyPair: authKeyPair,
          nodeId: userId,
          deviceName: 'phone',
        );
        await client.resolveAndPair(payloadRaw);
        setState(() {
          _alreadyPairedDirect = true;
          _success = 'ПК подключён напрямую к этому телефону';
        });
      } else {
        final token = ref.read(appControllerProvider).session?.accessToken;
        if (token == null) {
          setState(() {
            _error = 'Войдите в аккаунт, чтобы привязать ПК через ноду';
            _success = null;
          });
          return;
        }
        final api = ApiClient(accessToken: token);
        await api.pairPersonalPc(payloadJson: payloadRaw);
        setState(() {
          _success = 'ПК привязан к вашему аккаунту';
        });
      }
    } on ApiException catch (e) {
      setState(() => _error = _friendlyPairError(e.message));
    } on PpcException catch (e) {
      setState(() => _error = _friendlyPairError(e.message));
    } on PpcPayloadError catch (e) {
      setState(() => _error = _friendlyPairError(e.message));
    } catch (e) {
      setState(() => _error = _friendlyPairError('$e'));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _handleScan(String? raw) {
    if (raw == null || raw.trim().isEmpty || !_scanning || _scanHandled) return;
    final text = raw.trim();
    try {
      PpcPairingPayload.parse(text);
    } on PpcPayloadError catch (e) {
      setState(() => _error = _friendlyPairError(e.message));
      return;
    }
    _scanHandled = true;
    setState(() {
      _payloadController.text = text;
      _detectedIntent = _tryDetectIntent(text);
      _error = null;
      _success = null;
      _scanning = false;
      _scanHandled = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;
    final session = ref.watch(appControllerProvider).session;
    final isLoggedIn = session != null;
    final intentHint = _intentHint(_detectedIntent);

    return Scaffold(
      appBar: AppBar(title: const Text('Привязать домашний ПК')),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.only(
              top: AppSpacing.md,
              bottom: AppSpacing.xxl,
            ),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
                child: Text(
                  'Отсканируйте QR-код с домашнего ПК или вставьте код вручную.',
                  style: text.secondary,
                ),
              ),
              if (intentHint != null) ...[
                const SizedBox(height: AppSpacing.md),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
                  child: AppCard(
                    color: colors.cardSoft,
                    child: Text(intentHint, style: text.body),
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.lg),
              if (!_mediaOnSenderDevice) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
                  child: AppCard(
                    color: colors.warning.withValues(alpha: 0.08),
                    child: Text(
                      'Прямая загрузка медиа на ПК доступна только при настройке '
                      '«Где хранятся медиа» = «На устройстве отправителя». '
                      'Сейчас выбран другой режим — новые изображения пойдут через media-node.',
                      style: text.body.copyWith(color: colors.warning),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
              ],
              if (_alreadyPairedDirect) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
                  child: AppCard(
                    color: colors.success.withValues(alpha: 0.08),
                    child: Text(
                      _mediaOnSenderDevice
                          ? 'ПК уже подключён напрямую к этому телефону. '
                              'Новые изображения будут загружаться на ваш ПК.'
                          : 'ПК подключён напрямую, но новые изображения не будут '
                              'загружаться на ПК, пока не выбран режим «На устройстве отправителя».',
                      style: text.body.copyWith(color: colors.success),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
              ],
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
                child: AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (!isLoggedIn) ...[
                        Text('ID пользователя', style: text.caption),
                        const SizedBox(height: AppSpacing.sm),
                        AppTextField(
                          controller: _userIdController,
                          hintText: 'UUID пользователя на home-node',
                        ),
                        const SizedBox(height: AppSpacing.lg),
                      ],
                      Row(
                        children: [
                          Text('Код с ПК', style: text.caption),
                          const Spacer(),
                          if (_detectedIntent != null)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.sm,
                                vertical: AppSpacing.xs,
                              ),
                              decoration: BoxDecoration(
                                color: colors.cardSoft,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                _detectedIntent == 'direct' ? 'напрямую' : 'через ноду',
                                style: text.micro.copyWith(color: colors.primary),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      AppTextField(
                        controller: _payloadController,
                        hintText: 'Вставьте код или отсканируйте QR',
                        maxLines: 6,
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      AppButton(
                        label: 'Сканировать QR',
                        variant: AppButtonVariant.secondary,
                        icon: Icons.qr_code_scanner_outlined,
                        onPressed: _loading
                            ? null
                            : () => setState(() {
                                  _scanning = true;
                                  _scanHandled = false;
                                  _error = null;
                                }),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      AppButton(
                        label: _loading ? 'Привязка…' : 'Привязать ПК',
                        loading: _loading,
                        onPressed: _loading
                            ? null
                            : () => _pair(isLoggedIn: isLoggedIn, sessionUserId: session?.userId),
                      ),
                    ],
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: AppSpacing.md),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
                  child: Text(_error!, style: text.caption.copyWith(color: colors.danger)),
                ),
              ],
              if (_success != null) ...[
                const SizedBox(height: AppSpacing.md),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
                  child: AppCard(
                    color: colors.success.withValues(alpha: 0.08),
                    child: Text(_success!, style: text.body.copyWith(color: colors.success)),
                  ),
                ),
              ],
            ],
          ),
          if (_scanning)
            _QrScannerOverlay(
              controller: _scannerController,
              scanHandled: _scanHandled,
              onDetect: _handleScan,
              onClose: () => setState(() {
                _scanning = false;
                _scanHandled = false;
              }),
            ),
        ],
      ),
    );
  }
}

class _QrScannerOverlay extends StatelessWidget {
  const _QrScannerOverlay({
    required this.controller,
    required this.scanHandled,
    required this.onDetect,
    required this.onClose,
  });

  final MobileScannerController controller;
  final bool scanHandled;
  final ValueChanged<String?> onDetect;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final text = context.textStyles;

    return Material(
      color: Colors.black87,
      child: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: onClose,
              ),
            ),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: MobileScanner(
                  controller: controller,
                  onDetect: (capture) {
                    if (scanHandled) return;
                    for (final barcode in capture.barcodes) {
                      final raw = barcode.rawValue;
                      if (raw != null && raw.isNotEmpty) {
                        onDetect(raw);
                        break;
                      }
                    }
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Text(
                'Наведите камеру на QR-код с домашнего ПК',
                style: text.body.copyWith(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
