// storage-app :: models/models
// Конфигурация сервера и доменные модели. См. ../../docs/{SPEC,SETTINGS,WIRE}.md
library;

/// Локальная конфигурация ПК-приложения (не синхронизируется).
/// См. SETTINGS.md §«Черновик storage-app config».
class StorageConfig {
  /// Разрешённый корень хранения. Все записи строго внутри него.
  final String allowedRoot;

  /// Порт HTTP-сервера (WIRE.md — по умолчанию 7345).
  final int port;

  /// Адрес прослушивания.
  final String host;

  /// Глобальная квота: 0 = без лимита (SETTINGS.md §7).
  final int maxBytes;
  final int maxFiles;

  /// Версия, отдаётся в /ppc/health.
  final String version;

  const StorageConfig({
    required this.allowedRoot,
    this.port = 7345,
    this.host = '0.0.0.0',
    this.maxBytes = 0,
    this.maxFiles = 0,
    this.version = '0.0.1',
  });
}

/// Сопряжённый пир (нода/телефон). SETTINGS.md §4 (таблица peers).
class Peer {
  final String userUuid; // node_id из pairing
  final String pubkey; // "ed25519:<base64>"
  final String name;
  final int addedAt;
  final int quotaBytes; // per-user квота, 0 = глобальная/без лимита
  final bool revoked;

  const Peer({
    required this.userUuid,
    required this.pubkey,
    required this.name,
    required this.addedAt,
    this.quotaBytes = 0,
    this.revoked = false,
  });
}

/// Итог по использованию для /ppc/usage.
class Usage {
  final int usedBytes;
  final int usedFiles;
  final int quotaBytes;

  const Usage(this.usedBytes, this.usedFiles, this.quotaBytes);

  Map<String, Object?> toJson() => {
        'used_bytes': usedBytes,
        'used_files': usedFiles,
        'quota_bytes': quotaBytes,
      };
}

/// Запись append-only журнала (SETTINGS.md §6, audit_log).
class AuditEntry {
  final int id;
  final int ts;
  final String op;
  final String? userUuid;
  final String? hash;
  final int size;
  final String result;
  final String detail;

  const AuditEntry({
    required this.id,
    required this.ts,
    required this.op,
    this.userUuid,
    this.hash,
    this.size = 0,
    required this.result,
    this.detail = '',
  });
}
