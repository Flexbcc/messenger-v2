/// Call signaling data model — see spec/0303_CALLS.md and ADR-0008.
///
/// These are never displayed as chat bubbles: they ride the existing 1:1
/// E2EE session as control content, exactly like the group
/// `sender_key_distribution` messages (see AppController._onRealtimeEvent).
enum CallKind { audio, video }

enum CallSignalType { offer, answer, iceCandidate, reject, cancel, end, busy }

extension CallSignalTypeContentType on CallSignalType {
  /// The `content_type` string used on the wire (Message envelope).
  String get contentType {
    switch (this) {
      case CallSignalType.offer:
        return 'call_offer';
      case CallSignalType.answer:
        return 'call_answer';
      case CallSignalType.iceCandidate:
        return 'call_ice_candidate';
      case CallSignalType.reject:
        return 'call_reject';
      case CallSignalType.cancel:
        return 'call_cancel';
      case CallSignalType.end:
        return 'call_end';
      case CallSignalType.busy:
        return 'call_busy';
    }
  }

  static CallSignalType? fromContentType(String contentType) {
    for (final type in CallSignalType.values) {
      if (type.contentType == contentType) return type;
    }
    return null;
  }
}

/// A single decoded signaling message for one [callId] (see 0303_CALLS.md
/// → `call_id`). Which fields are populated depends on [type]:
/// - offer: [kind] and [sdp] required.
/// - answer: [sdp] required.
/// - iceCandidate: [candidate] required.
/// - reject/cancel/end/busy: no extra payload beyond [callId].
class CallSignal {
  const CallSignal({
    required this.type,
    required this.callId,
    this.kind,
    this.sdp,
    this.candidate,
  });

  final CallSignalType type;
  final String callId;
  final CallKind? kind;
  final String? sdp;
  final Map<String, dynamic>? candidate;

  Map<String, dynamic> toJson() => {
    'call_id': callId,
    if (kind != null) 'kind': kind!.name,
    if (sdp != null) 'sdp': sdp,
    if (candidate != null) 'candidate': candidate,
  };

  factory CallSignal.fromJson(CallSignalType type, Map<String, dynamic> json) {
    return CallSignal(
      type: type,
      callId: json['call_id'] as String,
      kind: json['kind'] == null
          ? null
          : CallKind.values.byName(json['kind'] as String),
      sdp: json['sdp'] as String?,
      candidate: (json['candidate'] as Map<String, dynamic>?),
    );
  }
}
