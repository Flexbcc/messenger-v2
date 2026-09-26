import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config.dart';
import '../core/extensions/context_extensions.dart';
import '../core/theme/app_spacing.dart';
import '../core/ui/app_card.dart';
import '../core/ui/app_empty_state.dart';
import '../core/ui/app_notice.dart';
import '../core/ui/app_page.dart';
import '../services/node_owner/managed_node.dart';
import '../services/node_owner/managed_node_registry.dart';
import '../services/node_owner/node_owner_api_client.dart';
import '../services/node_owner/node_owner_pairing_payload.dart';
import '../services/local_settings_store.dart';
import '../services/node_config_resolver.dart';
import '../services/settings_catalog_bridge.dart';
import 'node_owner_pairing_scanner_screen.dart';

class ManagedNodesScreen extends StatefulWidget {
  const ManagedNodesScreen({super.key, this.registry, this.apiClient});

  final ManagedNodeRegistry? registry;
  final NodeOwnerApiClient? apiClient;

  @override
  State<ManagedNodesScreen> createState() => _ManagedNodesScreenState();
}

class _ManagedNodesScreenState extends State<ManagedNodesScreen> {
  late final ManagedNodeRegistry _registry =
      widget.registry ?? ManagedNodeRegistry();
  late final NodeOwnerApiClient _api = widget.apiClient ?? NodeOwnerApiClient();
  List<ManagedNode> _nodes = const [];
  bool _loading = true;
  bool _pairing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final nodes = await _registry.list();
      if (mounted) setState(() => _nodes = nodes);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Не удалось прочитать список нод на этом устройстве.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _addNode() async {
    final pairing = await Navigator.of(context).push<NodeOwnerPairingPayload>(
      MaterialPageRoute(builder: (_) => const NodeOwnerPairingScannerScreen()),
    );
    if (pairing == null || !mounted) return;
    final label = await _askLabel(pairing.nodeId);
    if (label == null || !mounted) return;
    setState(() {
      _pairing = true;
      _error = null;
    });
    try {
      await _api.pair(pairing: pairing, localLabel: label);
      await _reload();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Не удалось подключить ноду. Проверьте QR-код и доступность сервера.',
        );
      }
    } finally {
      if (mounted) setState(() => _pairing = false);
    }
  }

  Future<String?> _askLabel(String nodeId) async {
    final controller = TextEditingController(text: 'Моя нода');
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Как назвать ноду?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Название видно только на этом устройстве.'),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: controller,
              autofocus: true,
              maxLength: 64,
              decoration: const InputDecoration(labelText: 'Название'),
            ),
            Text(
              nodeId,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Подключить'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return AppPage(
      title: 'Мои ноды',
      scroll: false,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _pairing ? null : _addNode,
        icon: _pairing
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.qr_code_scanner),
        label: Text(_pairing ? 'Подключение…' : 'Добавить ноду'),
      ),
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _reload,
              child: ListView(
                padding: const EdgeInsets.all(AppSpacing.screenPadding),
                children: [
                  Text(
                    'Управляйте своими OUO-нодами без доступа к переписке. Каждая нода использует отдельный ключ этого устройства.',
                    style: context.textStyles.body.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: AppSpacing.md),
                    AppNotice(message: _error!, tone: AppNoticeTone.danger),
                  ],
                  const SizedBox(height: AppSpacing.lg),
                  if (_nodes.isEmpty)
                    const AppEmptyState(
                      icon: Icons.dns_outlined,
                      title: 'Ноды ещё не подключены',
                      subtitle:
                          'На сервере создайте одноразовый QR командой ouoctl и отсканируйте его здесь.',
                    )
                  else
                    for (final node in _nodes) ...[
                      AppCard(
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => ManagedNodeDetailsScreen(
                              node: node,
                              apiClient: _api,
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.dns_outlined, color: colors.primary),
                            const SizedBox(width: AppSpacing.md),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    node.localLabel,
                                    style: context.textStyles.title,
                                  ),
                                  const SizedBox(height: AppSpacing.xs),
                                  Text(
                                    node.nodeId,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: context.textStyles.caption,
                                  ),
                                ],
                              ),
                            ),
                            const Icon(Icons.chevron_right),
                          ],
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                    ],
                  const SizedBox(height: 88),
                ],
              ),
            ),
    );
  }
}

class ManagedNodeDetailsScreen extends StatefulWidget {
  const ManagedNodeDetailsScreen({
    super.key,
    required this.node,
    required this.apiClient,
  });

  final ManagedNode node;
  final NodeOwnerApiClient apiClient;

  @override
  State<ManagedNodeDetailsScreen> createState() =>
      _ManagedNodeDetailsScreenState();
}

class _ManagedNodeDetailsScreenState extends State<ManagedNodeDetailsScreen> {
  Map<String, dynamic>? _status;
  List<Map<String, dynamic>> _devices = const [];
  Map<String, dynamic>? _diagnostics;
  Map<String, dynamic>? _config;
  List<Map<String, dynamic>> _auditEvents = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final status = await widget.apiClient.status(widget.node.nodeId);
      final devices = await widget.apiClient.devices(widget.node.nodeId);
      final diagnostics = await widget.apiClient.diagnostics(
        widget.node.nodeId,
      );
      final config = await widget.apiClient.config(widget.node.nodeId);
      List<Map<String, dynamic>> auditEvents = const [];
      try {
        auditEvents = await widget.apiClient.audit(widget.node.nodeId);
      } catch (_) {
        // Viewer devices intentionally have no access to the owner audit log.
      }
      if (mounted) {
        setState(() {
          _status = status;
          _devices = devices;
          _diagnostics = diagnostics;
          _config = config;
          _auditEvents = auditEvents;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Не удалось получить состояние ноды. Проверьте её доступность.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _saveConfig(Map<String, dynamic> next) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.apiClient.updateConfig(
        widget.node.nodeId,
        next,
      );
      if (!mounted) return;
      setState(() {
        _config = Map<String, dynamic>.from((result['config'] as Map?) ?? next);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result['restart_required'] == true
                ? 'Настройки сохранены. Для применения ролей потребуется безопасный перезапуск.'
                : 'Настройки сохранены.',
          ),
        ),
      );
      await _load();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Нода отклонила изменение настроек. Требуется роль владельца.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _createInvite() async {
    final label = await _askText(
      title: 'Новое приглашение',
      label: 'Пометка для владельца',
      initial: '',
    );
    if (label == null || !mounted) return;
    setState(() => _loading = true);
    try {
      final invite = await widget.apiClient.createInvite(
        widget.node.nodeId,
        label: label.trim().isEmpty ? null : label.trim(),
      );
      if (!mounted) return;
      final value =
          invite['join_url']?.toString() ??
          invite['qr_payload']?.toString() ??
          '';
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Одноразовое приглашение'),
          content: SelectableText(
            value.isEmpty ? 'Нода не вернула ссылку приглашения.' : value,
          ),
          actions: [
            if (value.isNotEmpty)
              TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: value));
                  if (context.mounted) Navigator.pop(context);
                },
                icon: const Icon(Icons.copy_outlined),
                label: const Text('Копировать'),
              ),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Готово'),
            ),
          ],
        ),
      );
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Не удалось создать приглашение. Проверьте роль владельца и интеграцию Gateway.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _restartService(String service) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Перезапустить сервис?'),
        content: Text(
          '$service будет кратковременно недоступен. Остальные сервисы ноды продолжат работу.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Перезапустить'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _loading = true);
    try {
      final actionId = await widget.apiClient.restartService(
        widget.node.nodeId,
        service,
      );
      await Future<void>.delayed(const Duration(seconds: 1));
      final result = await widget.apiClient.actionStatus(
        widget.node.nodeId,
        actionId,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result['status'] == 'succeeded'
                ? '$service перезапущен.'
                : 'Действие принято: ${result['status'] ?? 'pending'}.',
          ),
        ),
      );
      await _load();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Не удалось перезапустить $service. Проверьте Node Agent и права оператора.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _applySignedUpdate() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Установить подписанное обновление?'),
        content: const Text(
          'Нода примет только релиз из настроенного TUF-репозитория. После установки она проверит здоровье сервисов и автоматически откатится при ошибке.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.system_update_alt_outlined),
            label: const Text('Проверить и установить'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _loading = true);
    try {
      final actionId = await widget.apiClient.applySignedUpdate(
        widget.node.nodeId,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Обновление передано защищённому агенту. Идентификатор: $actionId',
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Обновление не запущено. Проверьте Node Agent и подписанный update-репозиторий.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _copyConfigBackup() async {
    setState(() => _loading = true);
    try {
      final backup = await widget.apiClient.configBackup(widget.node.nodeId);
      await Clipboard.setData(ClipboardData(text: jsonEncode(backup)));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Подписанная резервная копия конфигурации скопирована. Секреты и сообщения в неё не входят.',
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Не удалось создать резервную копию конфигурации.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _restoreConfigBackup() async {
    final controller = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Восстановить конфигурацию'),
        content: TextField(
          controller: controller,
          minLines: 5,
          maxLines: 10,
          decoration: const InputDecoration(
            hintText: 'Вставьте подписанную JSON-копию этой ноды',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Проверить и восстановить'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (raw == null || raw.isEmpty || !mounted) return;
    setState(() => _loading = true);
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) throw const FormatException('backup');
      final result = await widget.apiClient.restoreConfig(
        widget.node.nodeId,
        Map<String, dynamic>.from(decoded),
      );
      if (!mounted) return;
      setState(
        () => _config = Map<String, dynamic>.from(
          (result['config'] as Map?) ?? const {},
        ),
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Конфигурация проверена и восстановлена.'),
        ),
      );
      await _load();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Копия отклонена: неверный формат, подпись или другая нода.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<String?> _askText({
    required String title,
    required String label,
    required String initial,
  }) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 256,
          decoration: InputDecoration(labelText: label),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Продолжить'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _useAsHome() async {
    final endpoint = widget.node.homeEndpoint;
    if (endpoint == null || endpoint.isEmpty) {
      setState(
        () => _error =
            'Нода не опубликовала Home endpoint. Создайте новый QR после настройки публичного HTTPS-адреса Home.',
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Использовать эту Home Node?'),
        content: Text(
          'Новые подключения будут направляться через $endpoint. Текущий аккаунт не переносится автоматически: перед переключением приложение проверит доступность ноды.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Проверить и выбрать'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final store = LocalSettingsStore();
    final enabledKey = SettingsCatalogBridge.catalogKey('node.custom_enabled');
    final addressKey = SettingsCatalogBridge.catalogKey('node.custom_address');
    final previousEnabled = await store.getBool(enabledKey, false);
    final previousAddress = await store.getString(addressKey, '');
    try {
      await store.setString(addressKey, endpoint);
      await store.setBool(enabledKey, true);
      await AppConfig.refreshFromCatalog();
      if (!await NodeConfigResolver().isPrimaryReachable()) {
        throw StateError('Home health check failed');
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Home Node выбрана. Активный аккаунт потребует безопасного переподключения.',
          ),
        ),
      );
    } catch (_) {
      await store.setString(addressKey, previousAddress);
      await store.setBool(enabledKey, previousEnabled);
      await AppConfig.refreshFromCatalog();
      if (mounted) {
        setState(
          () => _error =
              'Home endpoint не прошёл проверку. Предыдущая конфигурация сохранена.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _revoke(Map<String, dynamic> device) async {
    final serial = device['serial']?.toString() ?? '';
    if (serial.isEmpty || device['active'] != true) return;
    final isCurrent = serial == widget.node.certificateSerial;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isCurrent ? 'Отключить этот телефон?' : 'Отозвать доступ?'),
        content: Text(
          isCurrent
              ? 'Телефон потеряет управление этой нодой. Для повторного подключения потребуется новый одноразовый QR с сервера.'
              : 'Выбранное устройство больше не сможет управлять нодой. Переписка и клиентские устройства не затрагиваются.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Отозвать'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.apiClient.revokeDevice(widget.node.nodeId, serial);
      if (!mounted) return;
      if (isCurrent) {
        Navigator.of(context).pop();
      } else {
        await _load();
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Не удалось отозвать доступ. Состояние ноды не изменено.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppPage(
      title: widget.node.localLabel,
      scroll: false,
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.screenPadding),
          children: [
            if (_loading) const LinearProgressIndicator(),
            if (_error != null) ...[
              AppNotice(message: _error!, tone: AppNoticeTone.danger),
              const SizedBox(height: AppSpacing.md),
            ],
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Состояние', style: context.textStyles.title),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    _status?['status']?.toString() ??
                        'Нет подтверждённых данных',
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(widget.node.nodeId, style: context.textStyles.caption),
                  if ((_status?['version']?.toString() ?? '').isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      'Версия: ${_status!['version']}',
                      style: context.textStyles.caption,
                    ),
                  ],
                  if (_status?['roles'] is List) ...[
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      'Роли: ${(_status!['roles'] as List).join(', ')}',
                      style: context.textStyles.caption,
                    ),
                  ],
                ],
              ),
            ),
            if (_status?['resources'] is Map) ...[
              const SizedBox(height: AppSpacing.md),
              _ResourceCard(
                resources: Map<String, dynamic>.from(
                  _status!['resources'] as Map,
                ),
              ),
            ],
            if (_status?['roles'] is List) ...[
              const SizedBox(height: AppSpacing.md),
              _ServicesCard(
                roles: (_status!['roles'] as List)
                    .map((value) => value.toString())
                    .toList(growable: false),
                disabled: _loading,
                onRestart: _restartService,
              ),
            ],
            if (_diagnostics?['checks'] is List) ...[
              const SizedBox(height: AppSpacing.md),
              _DiagnosticsCard(
                checks: (_diagnostics!['checks'] as List)
                    .whereType<Map>()
                    .map((value) => Map<String, dynamic>.from(value))
                    .toList(growable: false),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Обновление ноды', style: context.textStyles.title),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'Клиент не загружает произвольный код. Root-only агент проверяет TUF-подписи, версию и rollback-защиту, затем выполняет health-check.',
                    style: context.textStyles.caption,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  FilledButton.icon(
                    onPressed: _loading ? null : _applySignedUpdate,
                    icon: const Icon(Icons.system_update_alt_outlined),
                    label: const Text('Проверить подписанное обновление'),
                  ),
                ],
              ),
            ),
            if (_config != null) ...[
              const SizedBox(height: AppSpacing.md),
              _NodeConfigurationCard(
                config: _config!,
                disabled: _loading,
                onSave: _saveConfig,
                onCreateInvite: _createInvite,
                onBackup: _copyConfigBackup,
                onRestore: _restoreConfigBackup,
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Подключение аккаунта', style: context.textStyles.title),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    widget.node.homeEndpoint == null
                        ? 'Home endpoint не опубликован этой нодой.'
                        : widget.node.homeEndpoint!,
                    style: context.textStyles.caption,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  FilledButton.icon(
                    onPressed: _loading ? null : _useAsHome,
                    icon: const Icon(Icons.home_work_outlined),
                    label: const Text('Использовать как мою Home Node'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text('Устройства владельца', style: context.textStyles.title),
            const SizedBox(height: AppSpacing.sm),
            for (final device in _devices)
              AppCard(
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.phone_android_outlined),
                  title: Text(device['role']?.toString() ?? 'device'),
                  subtitle: Text(
                    device['device_id']?.toString() ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: device['active'] == true
                      ? IconButton(
                          tooltip: 'Отозвать доступ',
                          onPressed: _loading ? null : () => _revoke(device),
                          icon: const Icon(Icons.person_remove_outlined),
                        )
                      : const Icon(Icons.block_outlined),
                ),
              ),
            if (_auditEvents.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.lg),
              Text('Последние действия', style: context.textStyles.title),
              const SizedBox(height: AppSpacing.sm),
              AppCard(
                child: Column(
                  children: [
                    for (final event in _auditEvents.take(10))
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        leading: const Icon(Icons.history_outlined),
                        title: Text(event['action']?.toString() ?? 'Действие'),
                        subtitle: Text(
                          event['timestamp']?.toString() ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.xl),
          ],
        ),
      ),
    );
  }
}

class _NodeConfigurationCard extends StatefulWidget {
  const _NodeConfigurationCard({
    required this.config,
    required this.disabled,
    required this.onSave,
    required this.onCreateInvite,
    required this.onBackup,
    required this.onRestore,
  });

  final Map<String, dynamic> config;
  final bool disabled;
  final ValueChanged<Map<String, dynamic>> onSave;
  final VoidCallback onCreateInvite;
  final VoidCallback onBackup;
  final VoidCallback onRestore;

  @override
  State<_NodeConfigurationCard> createState() => _NodeConfigurationCardState();
}

class _NodeConfigurationCardState extends State<_NodeConfigurationCard> {
  late Map<String, dynamic> _draft;

  @override
  void initState() {
    super.initState();
    _draft = Map<String, dynamic>.from(widget.config);
  }

  @override
  void didUpdateWidget(covariant _NodeConfigurationCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.config != widget.config) {
      _draft = Map<String, dynamic>.from(widget.config);
    }
  }

  void _toggleRole(String role, bool enabled) {
    final roles = ((_draft['roles'] as List?) ?? const [])
        .map((value) => value.toString())
        .toSet();
    enabled ? roles.add(role) : roles.remove(role);
    if (roles.isEmpty) return;
    setState(() => _draft['roles'] = roles.toList()..sort());
  }

  Future<void> _editLimit(
    String key,
    String label, {
    required int minimum,
    required int maximum,
  }) async {
    final controller = TextEditingController(
      text: _draft[key]?.toString() ?? '',
    );
    final value = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(label),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(hintText: '$minimum–$maximum'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () {
              final parsed = int.tryParse(controller.text);
              if (parsed == null || parsed < minimum || parsed > maximum) {
                return;
              }
              Navigator.pop(context, parsed);
            },
            child: const Text('Применить'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value != null && mounted) setState(() => _draft[key] = value);
  }

  @override
  Widget build(BuildContext context) {
    final roles = ((_draft['roles'] as List?) ?? const [])
        .map((value) => value.toString())
        .toSet();
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Роли и лимиты', style: context.textStyles.title),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Изменения подписываются ключом владельца и записываются в журнал.',
            style: context.textStyles.caption,
          ),
          const SizedBox(height: AppSpacing.sm),
          for (final role in const [
            'home',
            'relay',
            'storage',
            'discovery',
            'gateway',
            'management',
          ])
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: roles.contains(role),
              onChanged: widget.disabled || role == 'management'
                  ? null
                  : (value) => _toggleRole(role, value),
              title: Text(
                role == 'management' ? 'management · обязательно' : role,
              ),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _draft['transit_enabled'] == true,
            onChanged: widget.disabled
                ? null
                : (value) => setState(() => _draft['transit_enabled'] = value),
            title: const Text('Разрешить транзитный трафик'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _draft['accept_invites'] == true,
            onChanged: widget.disabled
                ? null
                : (value) => setState(() => _draft['accept_invites'] = value),
            title: const Text('Разрешить приглашения пользователей'),
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              _LimitChip(
                label: 'Пользователи',
                value: _draft['max_users'],
                onTap: widget.disabled
                    ? null
                    : () => _editLimit(
                        'max_users',
                        'Лимит пользователей',
                        minimum: 1,
                        maximum: 100000,
                      ),
              ),
              _LimitChip(
                label: 'Хранилище, ГБ',
                value: _draft['max_storage_gb'],
                onTap: widget.disabled
                    ? null
                    : () => _editLimit(
                        'max_storage_gb',
                        'Лимит хранилища',
                        minimum: 1,
                        maximum: 100000,
                      ),
              ),
              _LimitChip(
                label: 'Соединения',
                value: _draft['max_connections'],
                onTap: widget.disabled
                    ? null
                    : () => _editLimit(
                        'max_connections',
                        'Лимит соединений',
                        minimum: 10,
                        maximum: 1000000,
                      ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: widget.disabled
                      ? null
                      : () => widget.onSave(_draft),
                  child: const Text('Сохранить'),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              OutlinedButton.icon(
                onPressed: widget.disabled || _draft['accept_invites'] != true
                    ? null
                    : widget.onCreateInvite,
                icon: const Icon(Icons.person_add_alt_1_outlined),
                label: const Text('Пригласить'),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              OutlinedButton.icon(
                onPressed: widget.disabled ? null : widget.onBackup,
                icon: const Icon(Icons.content_copy_outlined),
                label: const Text('Копировать резервную копию'),
              ),
              OutlinedButton.icon(
                onPressed: widget.disabled ? null : widget.onRestore,
                icon: const Icon(Icons.restore_outlined),
                label: const Text('Восстановить'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LimitChip extends StatelessWidget {
  const _LimitChip({required this.label, required this.value, this.onTap});

  final String label;
  final Object? value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ActionChip(
    avatar: const Icon(Icons.tune_outlined, size: 18),
    label: Text('$label: ${value ?? '—'}'),
    onPressed: onTap,
  );
}

class _ResourceCard extends StatelessWidget {
  const _ResourceCard({required this.resources});

  final Map<String, dynamic> resources;

  @override
  Widget build(BuildContext context) {
    final memory = resources['memory'] is Map
        ? Map<String, dynamic>.from(resources['memory'] as Map)
        : const <String, dynamic>{};
    final disk = resources['disk'] is Map
        ? Map<String, dynamic>.from(resources['disk'] as Map)
        : const <String, dynamic>{};
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Ресурсы', style: context.textStyles.title),
          const SizedBox(height: AppSpacing.sm),
          Text('CPU: ${resources['cpu_count'] ?? '—'} ядер'),
          Text(
            'RAM: ${_formatBytes(memory['used_bytes'])} / ${_formatBytes(memory['total_bytes'])}',
          ),
          Text(
            'Диск: ${_formatBytes(disk['used_bytes'])} / ${_formatBytes(disk['total_bytes'])}',
          ),
        ],
      ),
    );
  }
}

class _ServicesCard extends StatelessWidget {
  const _ServicesCard({
    required this.roles,
    required this.disabled,
    required this.onRestart,
  });

  final List<String> roles;
  final bool disabled;
  final ValueChanged<String> onRestart;

  static const _serviceByRole = {
    'home': 'home-node',
    'relay': 'relay-node',
    'storage': 'storage-node',
    'discovery': 'discovery-node',
    'gateway': 'gateway-node',
    'management': 'management-node',
  };

  @override
  Widget build(BuildContext context) => AppCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Сервисы', style: context.textStyles.title),
        const SizedBox(height: AppSpacing.sm),
        for (final role in roles)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.circle,
              size: 12,
              color: context.colors.success,
            ),
            title: Text(_serviceByRole[role] ?? role),
            subtitle: const Text('Заявлен нодой'),
            trailing: IconButton(
              tooltip: 'Перезапустить',
              onPressed: disabled || _serviceByRole[role] == null
                  ? null
                  : () => onRestart(_serviceByRole[role]!),
              icon: const Icon(Icons.restart_alt_outlined),
            ),
          ),
      ],
    ),
  );
}

class _DiagnosticsCard extends StatelessWidget {
  const _DiagnosticsCard({required this.checks});

  final List<Map<String, dynamic>> checks;

  @override
  Widget build(BuildContext context) => AppCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Диагностика', style: context.textStyles.title),
        const SizedBox(height: AppSpacing.sm),
        for (final check in checks)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(
              check['status'] == 'ok'
                  ? Icons.check_circle_outline
                  : Icons.warning_amber_outlined,
              color: check['status'] == 'ok'
                  ? context.colors.success
                  : context.colors.warning,
            ),
            title: Text(check['summary']?.toString() ?? 'Проверка'),
          ),
      ],
    ),
  );
}

String _formatBytes(Object? raw) {
  final value = raw is num ? raw.toDouble() : null;
  if (value == null) return '—';
  const units = ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ'];
  var size = value;
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  return '${size.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}
