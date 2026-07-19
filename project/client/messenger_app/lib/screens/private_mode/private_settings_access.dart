import 'package:flutter/material.dart';

import '../../services/duress_policy_session.dart';
import '../../services/hidden_vault_session.dart';
import '../../widgets/private/pin_unlock_sheet.dart';
import 'decoy_pin_setup_screen.dart';
import 'device_privacy_screen.dart';
import 'duress_policy_screen.dart';
import 'hidden_chats_screen.dart';
import 'hidden_chats_settings_screen.dart';
import 'pin_setup_screen.dart';
import 'privacy_secret_section_screen.dart';
import 'private_devices_screen.dart';
import 'trusted_contacts_screen.dart';

/// Open privacy screens from main Settings — no Private Mode hub hop.
class PrivateSettingsAccess {
  PrivateSettingsAccess._();

  static Future<T?> pushDirect<T>(BuildContext context, Widget screen) {
    return Navigator.of(context).push<T>(MaterialPageRoute(builder: (_) => screen));
  }

  static Future<void> openPinSetup(BuildContext context) async {
    await pushDirect(context, const PinSetupScreen());
  }

  static Future<void> openDecoyPinSetup(BuildContext context, {bool showSkip = true}) async {
    await pushDirect(context, DecoyPinSetupScreen(showSkip: showSkip));
  }

  static Future<void> openSecretRoomSetup(BuildContext context) async {
    await pushDirect(context, const PrivacySecretSectionScreen());
  }

  static Future<void> openHiddenChatsSettings(BuildContext context) async {
    await pushDirect(context, const HiddenChatsSettingsScreen());
  }

  static Future<void> openPrivateDevices(BuildContext context) async {
    await pushDirect(context, const PrivateDevicesScreen());
  }

  static Future<void> openDevicePrivacy(BuildContext context) async {
    await pushDirect(context, const DevicePrivacyScreen());
  }

  /// Unlock vault for editing policy — keeps unlocked until [lockVault].
  static Future<bool> ensureVaultUnlocked(BuildContext context) async {
    if (HiddenVaultSession.instance.isUnlocked && DuressPolicySession.instance.isUnlocked) {
      return true;
    }
    return showPinUnlockSheet(context);
  }

  static Future<void> openTrustedContacts(BuildContext context, {bool keepUnlocked = false}) async {
    if (!await ensureVaultUnlocked(context)) return;
    if (!context.mounted) return;
    await pushDirect(context, const TrustedContactsScreen());
    if (!keepUnlocked) lockVault();
  }

  static Future<void> openDuressPolicy(BuildContext context, {bool keepUnlocked = false}) async {
    if (!await ensureVaultUnlocked(context)) return;
    if (!context.mounted) return;
    await pushDirect(context, const DuressPolicyScreen());
    if (!keepUnlocked) lockVault();
  }

  static Future<void> openDuressRules(BuildContext context, {bool keepUnlocked = false}) async {
    if (!await ensureVaultUnlocked(context)) return;
    if (!context.mounted) return;
    await pushDirect(context, const DuressPolicyScreen());
    if (!keepUnlocked) lockVault();
  }

  static Future<void> openHiddenChats(BuildContext context) async {
    if (!await ensureVaultUnlocked(context)) return;
    if (!context.mounted) return;
    await pushDirect(context, const HiddenChatsScreen());
    lockVault();
  }

  static void lockVault() {
    HiddenVaultSession.instance.lock();
    DuressPolicySession.instance.lock();
  }
}
