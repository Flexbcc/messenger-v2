import 'package:flutter/material.dart';

import '../models/device_info.dart';
import '../models/device_session_meta.dart';

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes Б';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} КБ';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} МБ';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} ГБ';
}

String formatSyncTime(DateTime dateTime) {
  final diff = DateTime.now().difference(dateTime);
  if (diff.inSeconds < 30) return 'Только что';
  if (diff.inMinutes < 60) return '${diff.inMinutes} мин назад';
  return formatCallHistoryTime(dateTime);
}

String formatRelativeTime(DateTime dateTime) {
  final now = DateTime.now();
  final diff = now.difference(dateTime.toLocal());
  if (diff.isNegative || diff.inMinutes < 2) return 'Онлайн';
  if (diff.inMinutes < 60) return 'Был(а) ${diff.inMinutes} мин назад';
  if (diff.inHours < 24) return 'Был(а) ${diff.inHours} ч назад';
  if (diff.inDays < 7) return 'Был(а) ${diff.inDays} д назад';
  return '${dateTime.toLocal().day}.${dateTime.toLocal().month}.${dateTime.toLocal().year}';
}

String formatTime(DateTime dateTime) => formatCallHistoryTime(dateTime);

String formatCallHistoryTime(DateTime dateTime) {
  final local = dateTime.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final hm = '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  if (day == today) return hm;
  if (day == today.subtract(const Duration(days: 1))) return 'Вчера, $hm';
  if (now.difference(local).inDays < 7) {
    const weekdays = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];
    return '${weekdays[local.weekday - 1]}, $hm';
  }
  return '${local.day.toString().padLeft(2, '0')}.${local.month.toString().padLeft(2, '0')}';
}

String deviceTypeLabel(String deviceType) => switch (deviceType) {
      'ios' => 'iOS',
      'android' => 'Android',
      'web' => 'Web',
      'desktop' => 'Desktop',
      'macos' || 'windows' || 'linux' => 'Desktop',
      _ => deviceType,
    };

String devicePlatformLabel(String deviceType) => deviceTypeLabel(deviceType);

IconData deviceTypeIcon(String deviceType) => switch (deviceType) {
      'ios' => Icons.phone_iphone,
      'android' => Icons.phone_android,
      'web' => Icons.language,
      'desktop' || 'macos' || 'windows' || 'linux' => Icons.computer,
      _ => Icons.devices_other,
    };

bool isDeviceOnline(DeviceInfo device) {
  if (device.isCurrent) return true;
  return DateTime.now().difference(device.lastActive.toLocal()).inMinutes < 5;
}

String deviceStatusLabel(DeviceInfo device) {
  if (device.isCurrent) return 'Текущее · Онлайн';
  if (isDeviceOnline(device)) return 'Онлайн';
  return formatRelativeTime(device.lastActive);
}

String deviceListSubtitle(DeviceInfo device, {DeviceSessionMeta? meta}) {
  final platform = devicePlatformLabel(device.deviceType);
  final type = deviceTypeLabel(device.deviceType);
  final status = deviceStatusLabel(device);
  final version = meta?.appVersion;
  if (version != null && version.isNotEmpty) {
    return '$platform · v$version · $status';
  }
  return '$platform · $type · $status';
}
