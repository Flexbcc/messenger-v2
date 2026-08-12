/// Outbound message delivery states (client-side, spec/0202_DELIVERY.md subset).
enum MessageDeliveryStatus {
  pending,
  sending,
  sent,
  relay,
  gateway,
  delivered,
  read,
  failed,
}

class MessageDeliveryInfo {
  const MessageDeliveryInfo({required this.status, this.error, this.updatedAt});

  final MessageDeliveryStatus status;
  final String? error;
  final DateTime? updatedAt;
}
