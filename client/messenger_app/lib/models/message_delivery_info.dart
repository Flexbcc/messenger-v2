/// Outbound message delivery states (client-side, spec/0202_DELIVERY.md subset).
enum MessageDeliveryStatus {
  pending,
  /// Saved to local outbox queue, waiting for network connectivity.
  queued,
  sending,
  sent,
  relay,
  gateway,
  delivered,
  read,
  failed,
}

class MessageDeliveryInfo {
  const MessageDeliveryInfo({
    required this.status,
    this.error,
    this.updatedAt,
  });

  final MessageDeliveryStatus status;
  final String? error;
  final DateTime? updatedAt;
}
