import '../models/duress_policy.dart';
import 'local_settings_store.dart';
import 'security_log_service.dart';

/// Local audit for outbound duress signals — spec/0404 phase 4.
class DuressAuditService {
  DuressAuditService._();
  static final instance = DuressAuditService._();

  final _store = LocalSettingsStore();

  Future<void> recordOutbound({
    required int code,
    required String channel,
    DuressTrigger? trigger,
  }) async {
    final at = DateTime.now();
    await _store.setInt('duress_last_code', code);
    await _store.setString('duress_last_channel', channel);
    if (trigger != null) {
      await _store.setString('duress_last_trigger', trigger.wire);
    }
    await _store.setInt('duress_last_at_ms', at.millisecondsSinceEpoch);

    final triggerLabel = trigger != null ? ' · ${trigger.wire}' : '';
    await SecurityLogService.instance.append(
      SecurityEvent(
        title: 'Сигнал duress ($code)',
        subtitle: '${DuressSignalLabels.forCode(code)} · $channel$triggerLabel',
        at: at,
        icon: 'duress',
      ),
    );
  }

  Future<void> recordTrigger(DuressTrigger trigger, {String? detail}) async {
    await SecurityLogService.instance.append(
      SecurityEvent(
        title: 'Событие duress',
        subtitle: detail ?? trigger.wire,
        at: DateTime.now(),
        icon: 'duress',
      ),
    );
  }

  Future<DuressAuditRecord?> lastOutbound() async {
    final code = await _store.getInt('duress_last_code', 0);
    if (code == 0) return null;
    final ms = await _store.getInt('duress_last_at_ms', 0);
    return DuressAuditRecord(
      code: code,
      channel: await _store.getString('duress_last_channel', ''),
      triggerWire: await _store.getString('duress_last_trigger', ''),
      at: ms == 0 ? null : DateTime.fromMillisecondsSinceEpoch(ms),
    );
  }
}

class DuressAuditRecord {
  const DuressAuditRecord({
    required this.code,
    required this.channel,
    required this.triggerWire,
    this.at,
  });

  final int code;
  final String channel;
  final String triggerWire;
  final DateTime? at;

  String get label => DuressSignalLabels.forCode(code);
}
