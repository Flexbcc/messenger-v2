import 'package:flutter/material.dart';

import '../models/message_delivery_info.dart';
import '../services/message_delivery_store.dart';

export '../models/message_delivery_info.dart' show MessageDeliveryStatus, MessageDeliveryInfo;

MessageDeliveryStatus deliveryStatusFor({
  required String messageId,
  required String conversationId,
  required bool isMine,
  required bool isLastOutgoingInChat,
  required DateTime messageCreatedAt,
  bool peerOnline = false,
}) {
  if (!isMine) return MessageDeliveryStatus.sent;

  final info = MessageDeliveryStore.instance.infoFor(messageId);
  if (info != null) {
    if (info.status == MessageDeliveryStatus.failed ||
        info.status == MessageDeliveryStatus.pending ||
        info.status == MessageDeliveryStatus.sending) {
      return info.status;
    }
  }

  final peerRead = MessageDeliveryStore.instance.peerReadUntil(conversationId);
  if (peerRead != null && !messageCreatedAt.isAfter(peerRead)) {
    return MessageDeliveryStatus.read;
  }

  if (info != null) {
    if (info.status == MessageDeliveryStatus.delivered ||
        info.status == MessageDeliveryStatus.read ||
        info.status == MessageDeliveryStatus.relay ||
        info.status == MessageDeliveryStatus.gateway) {
      return info.status;
    }
    if (info.status == MessageDeliveryStatus.sent && isLastOutgoingInChat && peerOnline) {
      return MessageDeliveryStatus.delivered;
    }
    return info.status;
  }

  return MessageDeliveryStatus.sent;
}

String? deliveryErrorFor(String messageId) => MessageDeliveryStore.instance.infoFor(messageId)?.error;

String deliveryStatusLabel(MessageDeliveryStatus status) => switch (status) {
      MessageDeliveryStatus.pending => 'Ожидание',
      MessageDeliveryStatus.sending => 'Отправка',
      MessageDeliveryStatus.sent => 'Отправлено',
      MessageDeliveryStatus.relay => 'Relay',
      MessageDeliveryStatus.gateway => 'Gateway',
      MessageDeliveryStatus.delivered => 'Доставлено',
      MessageDeliveryStatus.read => 'Прочитано',
      MessageDeliveryStatus.failed => 'Ошибка',
    };

IconData statusIcon(MessageDeliveryStatus status) => switch (status) {
      MessageDeliveryStatus.pending => Icons.schedule,
      MessageDeliveryStatus.sending => Icons.upload_outlined,
      MessageDeliveryStatus.sent => Icons.done,
      MessageDeliveryStatus.relay => Icons.hub_outlined,
      MessageDeliveryStatus.gateway => Icons.router_outlined,
      MessageDeliveryStatus.delivered => Icons.done_all,
      MessageDeliveryStatus.read => Icons.done_all,
      MessageDeliveryStatus.failed => Icons.error_outline,
    };

Color statusIconColor(MessageDeliveryStatus status, Color primary, Color danger) => switch (status) {
      MessageDeliveryStatus.read => primary,
      MessageDeliveryStatus.failed => danger,
      _ => primary,
    };

double statusIconOpacity(MessageDeliveryStatus status) => switch (status) {
      MessageDeliveryStatus.read => 1,
      MessageDeliveryStatus.failed => 1,
      _ => 0.75,
    };
