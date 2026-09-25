import 'dart:convert';

import 'account_scope_id.dart';
import 'local_settings_store.dart';

String accountScopedFileName(String baseName) {
  final userId = AccountScopeId.require(LocalSettingsStore.activeUserId);
  final encoded = base64UrlEncode(utf8.encode(userId)).replaceAll('=', '');
  return '${encoded}_$baseName';
}

/// Filename used before account IDs were encoded injectively. Read-only
/// compatibility helper; new writes must use [accountScopedFileName].
String legacyAccountScopedFileName(String baseName) {
  final userId = AccountScopeId.require(LocalSettingsStore.activeUserId);
  final sanitized = userId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  return '${sanitized}_$baseName';
}
