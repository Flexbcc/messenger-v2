import '../calls/call_signal.dart';

enum CallHistoryStatus { completed, missed, cancelled, rejected, busy, failed }

class CallHistoryEntry {
  CallHistoryEntry({
    required this.callId,
    required this.peerUserId,
    required this.kind,
    required this.outgoing,
    required this.status,
    required this.startedAt,
    this.durationSeconds,
  });

  final String callId;
  final String peerUserId;
  final CallKind kind;
  final bool outgoing;
  final CallHistoryStatus status;
  final DateTime startedAt;
  final int? durationSeconds;

  bool get missed => status == CallHistoryStatus.missed;

  Map<String, dynamic> toJson() => {
    'call_id': callId,
    'peer_user_id': peerUserId,
    'kind': kind.name,
    'outgoing': outgoing,
    'status': status.name,
    'started_at': startedAt.toUtc().toIso8601String(),
    if (durationSeconds != null) 'duration_seconds': durationSeconds,
  };

  factory CallHistoryEntry.fromJson(Map<String, dynamic> json) =>
      CallHistoryEntry(
        callId: json['call_id'] as String,
        peerUserId: json['peer_user_id'] as String,
        kind: CallKind.values.byName(json['kind'] as String),
        outgoing: json['outgoing'] as bool,
        status: CallHistoryStatus.values.byName(json['status'] as String),
        startedAt: DateTime.parse(json['started_at'] as String),
        durationSeconds: json['duration_seconds'] as int?,
      );
}
