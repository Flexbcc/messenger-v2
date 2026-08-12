import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/duress_policy.dart';
import '../../services/app_privacy_session.dart';
import '../../services/duress_audit_service.dart';
import '../../services/duress_policy_engine.dart';
import '../../services/duress_policy_session.dart';
import '../../services/hidden_vault_session.dart';
import '../../state/app_controller.dart';

/// Instant exit from Private Mode module.
Future<void> panicExit(BuildContext context) async {
  AppController? controller;
  try {
    controller = ProviderScope.containerOf(context).read(appControllerProvider);
  } catch (_) {}

  controller?.deactivateSecretSessionForAll();
  await DuressPolicyEngine.instance.handle(
    DuressTrigger.panicExit,
    controller: controller,
    incrementCounter: false,
  );
  await DuressAuditService.instance.recordTrigger(
    DuressTrigger.panicExit,
    detail: 'Быстрый выход из защищённого раздела',
  );

  HiddenVaultSession.instance.lock();
  DuressPolicySession.instance.lock();
  AppPrivacySession.instance.exit();
  if (context.mounted) {
    Navigator.of(
      context,
      rootNavigator: true,
    ).popUntil((route) => route.isFirst);
  }
}
