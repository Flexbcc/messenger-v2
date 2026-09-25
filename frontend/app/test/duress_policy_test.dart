import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:messenger_app/models/duress_policy.dart';
import 'package:messenger_app/services/duress_rate_limiter.dart';

void main() {
  group('DuressPresets', () {
    test('factory presets have rules', () {
      for (final id in ['P1', 'P2', 'P3', 'P4']) {
        expect(DuressPresets.rulesFor(id), isNotEmpty);
      }
    });

    test('custom preset label explains manual rules', () {
      expect(DuressPresets.label('custom'), 'Своя');
      expect(DuressPresets.description('custom'), contains('задаёте'));
    });

    test('custom preset does not ship factory rules', () {
      expect(
        () => DuressPresets.rulesFor('custom'),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('DuressRule channels', () {
    test('serializes per-rule channels', () {
      const rule = DuressRule(
        trigger: DuressTrigger.pinUnlockFail,
        threshold: 3,
        channels: ['relay'],
        actions: [
          DuressAction(type: DuressActionType.relayEvent, relayEvent: 10),
        ],
      );
      final json = rule.toJson();
      expect(json['channels'], ['relay']);
      final back = DuressRule.fromJson(json);
      expect(back.channels, ['relay']);
    });

    test('summary includes channel override', () {
      const rule = DuressRule(
        trigger: DuressTrigger.decoyPinStreak,
        threshold: 1,
        channels: ['chat'],
        actions: [
          DuressAction(type: DuressActionType.notifyTrustedChat, uiCode: 20),
        ],
      );
      expect(rule.summaryRu, contains('Только чат'));
    });
  });

  group('DuressTrustedChannels', () {
    test('normalize both keyword', () {
      expect(DuressTrustedChannels.normalize(['both']), ['chat', 'relay']);
    });
  });

  group('DuressRateLimiter', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('allows up to maxPerHour relay attempts', () async {
      final limiter = DuressRateLimiter.instance;
      for (var i = 0; i < DuressRateLimiter.maxPerHour; i++) {
        expect(await limiter.allowRelay(), isTrue, reason: 'attempt $i');
      }
      expect(await limiter.allowRelay(), isFalse);
    });
  });
}
