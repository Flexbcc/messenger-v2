import 'package:flutter/material.dart';

import '../core/extensions/context_extensions.dart';
import '../core/theme/app_spacing.dart';
import '../core/ui/app_card.dart';
import '../core/ui/app_empty_state.dart';
import '../core/ui/app_notice.dart';
import '../services/node_owner/managed_node.dart';
import '../services/node_owner/managed_node_registry.dart';
import '../services/node_owner/node_owner_api_client.dart';
import '../services/node_owner/node_owner_pairing_payload.dart';
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
    return Scaffold(
      appBar: AppBar(title: const Text('Мои ноды')),
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
      body: _loading
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
      if (mounted) {
        setState(() {
          _status = status;
          _devices = devices;
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
    return Scaffold(
      appBar: AppBar(title: Text(widget.node.localLabel)),
      body: RefreshIndicator(
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
            const SizedBox(height: AppSpacing.xl),
            Text(
              'Перезапуск сервисов и обновления появятся после подключения защищённого VPN/mTLS-канала.',
              style: context.textStyles.caption,
            ),
          ],
        ),
      ),
    );
  }
}
