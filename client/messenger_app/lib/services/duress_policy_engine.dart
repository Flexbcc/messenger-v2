import '../models/duress_policy.dart';
import '../state/app_controller.dart';
import 'duress_policy_session.dart';
import 'duress_runtime_store.dart';
import 'hidden_vault_session.dart';

/// Evaluates duress triggers against preset rules — spec/0404 phase 1.
class DuressPolicyEngine {
  DuressPolicyEngine._();
  static final instance = DuressPolicyEngine._();

  Future<bool> isPinLockedOut() async {
    final data = await _activeData();
    if (data.lockoutUntil == null) return false;
    return DateTime.now().isBefore(data.lockoutUntil!);
  }

  Future<Duration?> lockoutRemaining() async {
    final data = await _activeData();
    final until = data.lockoutUntil;
    if (until == null) return null;
    final rem = until.difference(DateTime.now());
    if (rem.isNegative) return null;
    return rem;
  }

  Future<DuressHandleResult> handle(
    DuressTrigger trigger, {
    AppController? controller,
    bool incrementCounter = true,
  }) async {
    final data = await _activeData();
    final now = DateTime.now();

    if (data.lockoutUntil != null && now.isBefore(data.lockoutUntil!)) {
      return DuressHandleResult(lockoutUntil: data.lockoutUntil);
    }

    var streak = 0;
    final counterTrigger = _counterTrigger(trigger);
    if (incrementCounter && _usesCounter(trigger)) {
      streak = _bumpCounter(data, counterTrigger, now);
    } else if (_usesCounter(trigger)) {
      streak = _currentCount(data, counterTrigger, now);
    }

    final ruleTriggers = _ruleTriggersFor(trigger);
    final rules = data.rules.where((r) => ruleTriggers.contains(r.trigger)).toList()
      ..sort((a, b) => a.threshold.compareTo(b.threshold));

    var openDecoy = false;
    var purged = false;
    DateTime? lockoutUntil;

    for (final rule in rules) {
      if (streak < rule.threshold) continue;
      for (final action in rule.actions) {
        switch (action.type) {
          case DuressActionType.lockPinUi:
          case DuressActionType.lockApp:
            final sec = action.durationSec ?? 300;
            final until = now.add(Duration(seconds: sec));
            if (lockoutUntil == null || until.isAfter(lockoutUntil)) {
              lockoutUntil = until;
              data.lockoutUntil = until;
            }
          case DuressActionType.notifyTrustedChat:
            if (controller != null &&
                action.uiCode != null &&
                _channelEnabled(data, 'chat', ruleChannels: rule.channels)) {
              await controller.sendDuressSignalToTrusted(
                code: action.uiCode!,
                trigger: trigger,
                channelsOverride: rule.channels,
              );
            }
          case DuressActionType.relayEvent:
            if (controller != null &&
                action.relayEvent != null &&
                _channelEnabled(data, 'relay', ruleChannels: rule.channels)) {
              await controller.relaySecuritySignal(
                event: action.relayEvent!,
                trigger: trigger,
                channelsOverride: rule.channels,
              );
            }
          case DuressActionType.purgeSecretMessages:
            if (controller != null) {
              await controller.purgeAllSecretMessages();
              purged = true;
            }
          case DuressActionType.wipePrivateVault:
            await HiddenVaultSession.instance.wipe();
          case DuressActionType.deactivateSecretSessions:
            controller?.deactivateSecretSessionForAll();
          case DuressActionType.showDecoyOnly:
            openDecoy = true;
          case DuressActionType.none:
            break;
        }
      }
    }

    if (trigger == DuressTrigger.pinUnlockOkReal) {
      _resetCounter(data, DuressTrigger.decoyPinStreak);
      _resetCounter(data, DuressTrigger.pinUnlockFail);
      data.lockoutUntil = null;
    }

    await _saveData(data);

    return DuressHandleResult(
      openDecoy: openDecoy,
      lockoutUntil: lockoutUntil,
      purgedSecrets: purged,
    );
  }

  bool _usesCounter(DuressTrigger t) => switch (t) {
        DuressTrigger.pinUnlockFail => true,
        DuressTrigger.decoyPinStreak => true,
        DuressTrigger.secretRoomActivateFail => true,
        DuressTrigger.appLockFail => true,
        _ => false,
      };

  DuressTrigger _counterTrigger(DuressTrigger t) => switch (t) {
        DuressTrigger.appLockFail => DuressTrigger.pinUnlockFail,
        _ => t,
      };

  List<DuressTrigger> _ruleTriggersFor(DuressTrigger t) => switch (t) {
        DuressTrigger.appLockFail => [DuressTrigger.appLockFail, DuressTrigger.pinUnlockFail],
        _ => [t],
      };

  int _bumpCounter(DuressPolicyData data, DuressTrigger trigger, DateTime now) {
    final windowSec = data.rules
        .where((r) => r.trigger == trigger)
        .map((r) => r.windowSec)
        .fold(86400, (a, b) => a > b ? a : b);

    final counter = data.counterFor(trigger);
    if (now.difference(counter.windowStart).inSeconds > windowSec) {
      counter.count = 0;
      counter.windowStart = now;
    }
    counter.count++;
    return counter.count;
  }

  int _currentCount(DuressPolicyData data, DuressTrigger trigger, DateTime now) {
    final windowSec = data.rules
        .where((r) => r.trigger == trigger)
        .map((r) => r.windowSec)
        .fold(86400, (a, b) => a > b ? a : b);
    final counter = data.counterFor(trigger);
    if (now.difference(counter.windowStart).inSeconds > windowSec) return 0;
    return counter.count;
  }

  void _resetCounter(DuressPolicyData data, DuressTrigger trigger) {
    data.counters[trigger.wire] = DuressCounter();
  }

  Future<DuressPolicyData> _activeData() async {
    if (DuressPolicySession.instance.isUnlocked && DuressPolicySession.instance.data != null) {
      return DuressPolicySession.instance.data!;
    }
    return DuressRuntimeStore.instance.loadMirror();
  }

  Future<void> _saveData(DuressPolicyData data) async {
    await DuressRuntimeStore.instance.saveMirror(data);
    if (DuressPolicySession.instance.isUnlocked) {
      await DuressPolicySession.instance.syncFrom(data);
    }
  }

  bool _channelEnabled(DuressPolicyData data, String channel, {List<String>? ruleChannels}) {
    final ch = ruleChannels ?? data.trustedChannels;
    if (ch.contains('both')) return true;
    return ch.contains(channel);
  }
}
