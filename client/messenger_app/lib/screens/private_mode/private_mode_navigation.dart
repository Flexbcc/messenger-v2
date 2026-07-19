import 'package:flutter/material.dart';

import '../security/security_log_screen.dart';
import 'confidentiality_hub_screen.dart';
import 'duress_policy_screen.dart';
import 'hidden_chats_screen.dart';
import 'hidden_chats_settings_screen.dart';
import 'privacy_advanced_section_screen.dart';
import 'privacy_decoy_section_screen.dart';
import 'privacy_pin_section_screen.dart';
import 'privacy_secret_section_screen.dart';
import 'private_devices_screen.dart';
import 'private_mode_entry.dart';
import 'private_settings_access.dart';
import 'trusted_contacts_screen.dart';

/// Deep-link target after optional PIN gate (no old flat privacy UI).
enum PrivateDestination {
  home,
  pinSection,
  decoySection,
  secretSection,
  advancedSection,
  duressPolicy,
  trustedContacts,
  secretRoom,
  hiddenChats,
  hiddenChatsSettings,
  privateDevices,
  securityLog,
}

/// Remembers where to navigate after successful PIN entry.
class PrivateModeNavigation {
  PrivateModeNavigation._();

  static PrivateDestination _pending = PrivateDestination.home;

  static Route<void> entryRoute([PrivateDestination destination = PrivateDestination.home]) {
    _pending = destination;
    return privateModeEntryRoute();
  }

  static PrivateDestination consumePending() {
    final dest = _pending;
    _pending = PrivateDestination.home;
    return dest;
  }

  static Widget screenFor(PrivateDestination destination) {
    switch (destination) {
      case PrivateDestination.home:
        return const ConfidentialityHubScreen();
      case PrivateDestination.pinSection:
        return const PrivacyPinSectionScreen();
      case PrivateDestination.decoySection:
        return const PrivacyDecoySectionScreen();
      case PrivateDestination.secretSection:
        return const PrivacySecretSectionScreen();
      case PrivateDestination.advancedSection:
        return const PrivacyAdvancedSectionScreen();
      case PrivateDestination.duressPolicy:
        return const DuressPolicyScreen();
      case PrivateDestination.trustedContacts:
        return const TrustedContactsScreen();
      case PrivateDestination.secretRoom:
        return const PrivacySecretSectionScreen();
      case PrivateDestination.hiddenChats:
        return const HiddenChatsScreen();
      case PrivateDestination.hiddenChatsSettings:
        return const HiddenChatsSettingsScreen();
      case PrivateDestination.privateDevices:
        return const PrivateDevicesScreen();
      case PrivateDestination.securityLog:
        return const SecurityLogScreen();
    }
  }

  static void openAfterUnlock(BuildContext context, PrivateDestination destination) {
    if (destination == PrivateDestination.home) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => screenFor(destination)),
      );
    });
  }

  static Future<void> openConfidentiality(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ConfidentialityHubScreen()),
    );
  }

  static Future<void> openTrusted(BuildContext context) =>
      PrivateSettingsAccess.openTrustedContacts(context);

  static Future<void> openPolicy(BuildContext context) =>
      PrivateSettingsAccess.openDuressPolicy(context);
}
