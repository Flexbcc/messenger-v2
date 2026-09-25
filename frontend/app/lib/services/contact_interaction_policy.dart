import 'settings_runtime.dart';

/// One policy boundary for every direct interaction with another user.
/// UI affordances are not a security boundary: realtime messages, calls and
/// previously opened chat screens must all consult the same blocked-user rule.
class ContactInteractionPolicy {
  ContactInteractionPolicy({SettingsRuntime? runtime})
    : _runtime = runtime ?? SettingsRuntime.instance;

  final SettingsRuntime _runtime;

  Future<bool> canInitiate(String peerUserId) async =>
      !await _runtime.isBlocked(peerUserId);

  Future<bool> canReceiveMessage(
    String senderUserId, {
    required bool isContact,
    required bool hasPriorOutgoing,
  }) async {
    if (await _runtime.isBlocked(senderUserId)) return false;
    if (hasPriorOutgoing) return true;
    return _runtime.incomingMessagesAllowed(senderUserId, isContact: isContact);
  }

  Future<bool> canReceiveCall(
    String callerUserId, {
    required bool isContact,
  }) async {
    if (await _runtime.isBlocked(callerUserId)) return false;
    return _runtime.callsAllowed(callerUserId, isContact: isContact);
  }
}
