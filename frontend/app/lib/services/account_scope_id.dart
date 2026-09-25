class AccountScopeId {
  AccountScopeId._();

  static final RegExp _pattern = RegExp(r'^[A-Za-z0-9._:-]+$');

  /// Returns a validated account identifier or `null` when clearing a scope.
  ///
  /// Account identifiers become part of local and secure-storage keys, so an
  /// invalid value must never be silently accepted or rewritten.
  static String? validateNullable(String? userId) {
    if (userId == null) return null;
    if (userId.isEmpty || userId.length > 128 || !_pattern.hasMatch(userId)) {
      throw ArgumentError.value(userId, 'userId', 'invalid account scope');
    }
    return userId;
  }

  static String require(String? userId) {
    final validated = validateNullable(userId);
    if (validated == null) {
      throw StateError('account scope is required');
    }
    return validated;
  }
}
