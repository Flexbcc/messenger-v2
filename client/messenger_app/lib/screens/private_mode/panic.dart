import 'package:flutter/material.dart';

import '../../services/hidden_vault_session.dart';

/// Instant exit from Private Mode module.
void panicExit(BuildContext context) {
  HiddenVaultSession.instance.lock();
  Navigator.of(context, rootNavigator: true).popUntil((route) => route.isFirst);
}
