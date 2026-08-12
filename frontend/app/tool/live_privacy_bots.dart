import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:messenger_app/crypto/crypto_service.dart';
import 'package:messenger_app/services/api_client.dart';
import 'package:uuid/uuid.dart';

const _password = 'Local-live-bot-2026!';
const _uuid = Uuid();

class LiveBot {
  LiveBot({required this.name, required this.login, required this.crypto});

  final String name;
  final String login;
  final CryptoService crypto;
  final ApiClient api = ApiClient();
  final Map<String, String> conversations = {};
  late String userId;
  late String deviceId;

  static Future<LiveBot> create(String name, String login, int suffix) async {
    final crypto = CryptoService.ephemeral();
    final bot = LiveBot(name: name, login: login, crypto: crypto);
    final result = await bot.api.register(
      displayName: name,
      phone: '+7900${suffix.remainder(10000000).toString().padLeft(7, '0')}',
      login: login,
      password: _password,
      deviceName: 'Автоматический собеседник',
      deviceType: 'desktop',
      authPublicKey: base64Encode(
        List<int>.generate(32, (index) => Random.secure().nextInt(256)),
      ),
      identityKeyBundle: await crypto.generatePublishableBundle(
        preKeyCount: 80,
      ),
    );
    bot.userId = result['user_id'] as String;
    bot.deviceId = result['device_id'] as String;
    bot.api.accessToken = result['access_token'] as String;
    return bot;
  }

  Future<String> _conversationWith(String recipientId) async {
    final cached = conversations[recipientId];
    if (cached != null) return cached;
    final data = await api.createConversation(
      type: 'direct',
      participantUserIds: [recipientId],
    );
    final id = data['id'] as String;
    conversations[recipientId] = id;
    return id;
  }

  Future<void> send(String recipientId, String text) async {
    final bundles = await api.getUserDeviceBundles(recipientId);
    final envelopes = <Map<String, String>>[];
    for (final raw in bundles.whereType<Map<String, dynamic>>()) {
      final recipientDeviceId = raw['device_id']?.toString() ?? '';
      if (recipientDeviceId.isEmpty) continue;
      try {
        if (!await crypto.hasSessionWith(
          recipientId,
          deviceId: recipientDeviceId,
        )) {
          final bundle = await api.getDevicePreKeyBundle(
            recipientId,
            recipientDeviceId,
          );
          await crypto.establishSessionFromBundle(
            recipientId,
            bundle,
            deviceId: recipientDeviceId,
          );
        }
        envelopes.add({
          'device_id': recipientDeviceId,
          'ciphertext': await crypto.encrypt(
            recipientId,
            Uint8List.fromList(utf8.encode(text)),
            recipientDeviceId: recipientDeviceId,
          ),
        });
      } catch (error) {
        // A stale/revoked device must not block delivery to every healthy
        // device owned by the same account.
        stderr.writeln(
          'Пропущено устройство $recipientDeviceId получателя $recipientId: $error',
        );
      }
    }
    if (envelopes.isEmpty) {
      throw StateError(
        'У получателя $recipientId нет доступных ключей устройств',
      );
    }
    await api.sendMessage(
      conversationId: await _conversationWith(recipientId),
      ciphertext: envelopes.first['ciphertext']!,
      contentType: 'text',
      clientMsgId: _uuid.v4(),
      deviceEnvelopes: envelopes,
    );
  }
}

Future<void> main(List<String> args) async {
  String? targetArg;
  for (final arg in args) {
    if (arg.startsWith('--target=')) targetArg = arg;
  }
  if (targetArg == null) {
    stderr.writeln(
      'Использование: dart run tool/live_privacy_bots.dart --target=USER_ID',
    );
    exitCode = 64;
    return;
  }
  final targetId = targetArg.substring('--target='.length);
  final stamp = DateTime.now().millisecondsSinceEpoch.remainder(10000000);
  final bots = <LiveBot>[
    await LiveBot.create('Мария Соколова', 'maria_live_$stamp', stamp),
    await LiveBot.create('Максим Орлов', 'maxim_live_$stamp', stamp + 1),
    await LiveBot.create('Ольга Волкова', 'olga_live_$stamp', stamp + 2),
  ];
  final log = File('logs/live-privacy-bots.jsonl');
  await log.parent.create(recursive: true);
  var step = 0;
  const phrases = [
    'Привет! Проверяю, доходят ли обычные сообщения.',
    'Как отображается уведомление при текущих настройках приватности?',
    'Это плановое тестовое сообщение — отвечать необязательно.',
    'Проверяем список контактов и разрешения на сообщения.',
    'Ещё одна проверка доставки и статуса прочтения.',
  ];

  Future<void> writeEvent(Map<String, Object?> event) async {
    final row = {'time': DateTime.now().toUtc().toIso8601String(), ...event};
    await log.writeAsString('${jsonEncode(row)}\n', mode: FileMode.append);
    stdout.writeln(jsonEncode(row));
  }

  await writeEvent({
    'event': 'started',
    'target_user_id': targetId,
    'bots': [
      for (final bot in bots)
        {'name': bot.name, 'login': bot.login, 'user_id': bot.userId},
    ],
  });

  while (true) {
    final sender = bots[step % bots.length];
    final peer = bots[(step + 1) % bots.length];
    final phrase = phrases[step % phrases.length];
    for (final recipient in [targetId, peer.userId]) {
      try {
        await sender.send(recipient, phrase);
        await writeEvent({
          'event': 'message_sent',
          'sender': sender.name,
          'sender_id': sender.userId,
          'recipient_id': recipient,
          'text': phrase,
        });
      } catch (error) {
        await writeEvent({
          'event': 'send_failed',
          'sender': sender.name,
          'recipient_id': recipient,
          'error': error.toString(),
        });
      }
    }
    step++;
    await Future<void>.delayed(const Duration(seconds: 45));
  }
}
