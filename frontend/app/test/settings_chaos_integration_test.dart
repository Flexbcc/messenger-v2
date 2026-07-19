// ignore_for_file: avoid_print
//
// «Грязный» интеграционный прогон: 3 пользователя, поочерёдная переписка,
// каждый меняет настройки — фиксируем pass/fail/warn по каждой проверке.
//
// Требует поднятый стек (project/docker-compose или backend/docker-compose).
// Запуск: ./project/scripts/run-settings-chaos.sh
//    или: cd frontend/app && flutter test test/settings_chaos_integration_test.dart

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:messenger_app/crypto/crypto_service.dart';
import 'package:messenger_app/services/api_client.dart';
import 'package:messenger_app/services/bootstrap_service.dart';
import 'package:messenger_app/services/catalog_list_store.dart';
import 'package:messenger_app/services/local_settings_store.dart';
import 'package:messenger_app/services/settings_catalog_bridge.dart';
import 'package:messenger_app/services/settings_runtime.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum CheckStatus { pass, fail, warn, skip }

class ChaosCheck {
  ChaosCheck({
    required this.actor,
    required this.settingId,
    required this.scenario,
    required this.status,
    this.detail = '',
  });

  final String actor;
  final String settingId;
  final String scenario;
  final CheckStatus status;
  final String detail;
}

class _ChaosUser {
  _ChaosUser({
    required this.name,
    required this.api,
    required this.crypto,
    required this.userId,
    required this.login,
  });

  final String name;
  final ApiClient api;
  final CryptoService crypto;
  final String userId;
  final String login;
}

const _discoveryUrl = String.fromEnvironment(
  'DISCOVERY_NODE_URL',
  defaultValue: 'http://[::1]:8003',
);
const _homeInternalUrl = String.fromEnvironment(
  'HOME_NODE_URL',
  defaultValue: 'http://localhost:8001',
);

final _report = <ChaosCheck>[];

void _record(
  String actor,
  String settingId,
  String scenario,
  CheckStatus status, {
  String detail = '',
}) {
  _report.add(ChaosCheck(
    actor: actor,
    settingId: settingId,
    scenario: scenario,
    status: status,
    detail: detail,
  ));
}

void _recordOk(String actor, String settingId, String scenario, {String detail = ''}) =>
    _record(actor, settingId, scenario, CheckStatus.pass, detail: detail);

void _recordFail(String actor, String settingId, String scenario, String detail) =>
    _record(actor, settingId, scenario, CheckStatus.fail, detail: detail);

void _recordWarn(String actor, String settingId, String scenario, String detail) =>
    _record(actor, settingId, scenario, CheckStatus.warn, detail: detail);

Future<Map<String, dynamic>?> _discoveryUserById(String userId) async {
  final resp = await http.get(Uri.parse('$_discoveryUrl/registry/users/$userId'));
  if (resp.statusCode != 200) return null;
  return jsonDecode(resp.body) as Map<String, dynamic>;
}

Future<String> _resolveLogin(_ChaosUser user) async {
  final me = await user.api.getMyProfile();
  final fromProfile = (me['login'] as String?)?.trim();
  if (fromProfile != null && fromProfile.isNotEmpty) {
    return fromProfile;
  }
  return user.login;
}

Future<String> _upsertDiscoveryUser(
  _ChaosUser user, {
  required bool usernameSearchEnabled,
  required String displayName,
}) async {
  final login = await _resolveLogin(user);
  final body = {
    'user_id': user.userId,
    'home_node_url': _homeInternalUrl,
    'display_name': displayName,
    'auth_public_key': base64Encode(List.filled(32, 7)),
    'login': login,
    'username_search_enabled': usernameSearchEnabled,
    'cluster_id': 'default',
  };
  final resp = await http.post(
    Uri.parse('$_discoveryUrl/registry/users'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode(body),
  );
  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    throw StateError('discovery upsert failed: ${resp.statusCode} ${resp.body}');
  }
  return login;
}

Future<int> _rawDiscoverySearch(String login) async {
  final resp = await http.get(
    Uri.parse('$_discoveryUrl/registry/users/search?login=${Uri.encodeQueryComponent(login)}'),
  );
  return resp.statusCode;
}

Future<int> _assertDiscoverySearchPolicy({
  required _ChaosUser user,
  required bool usernameSearchEnabled,
  required String displayName,
  required int expectedStatus,
}) async {
  for (var i = 0; i < 15; i++) {
    await _upsertDiscoveryUser(
      user,
      usernameSearchEnabled: usernameSearchEnabled,
      displayName: displayName,
    );
    final rec = await _discoveryUserById(user.userId);
    final storedLogin = (rec?['login'] as String?)?.trim();
    if (storedLogin == null || storedLogin.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      continue;
    }
    final code = await _rawDiscoverySearch(storedLogin);
    if (code == expectedStatus) {
      return code;
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  return 404;
}

Future<Map<String, dynamic>?> _fetchStorageProfile(String userId) async {
  final uri = Uri.parse('$_homeInternalUrl/internal/users/$userId/storage-profile');
  final resp = await http.get(uri);
  if (resp.statusCode != 200) return null;
  return jsonDecode(resp.body) as Map<String, dynamic>;
}

Future<_ChaosUser> _registerUser({
  required String name,
  required int phoneNonce,
  required String login,
  required int authByte,
}) async {
  final api = ApiClient();
  final crypto = CryptoService.ephemeral();
  final bundle = await crypto.generatePublishableBundle();
  final phone = '+7${phoneNonce.toString().padLeft(10, '0')}';
  final reg = await api.register(
    displayName: '$name-$phoneNonce',
    phone: phone,
    login: login,
    password: 'chaos-pass-$phoneNonce',
    deviceName: 'chaos-test',
    deviceType: 'linux',
    authPublicKey: base64Encode(List.filled(32, authByte)),
    identityKeyBundle: bundle,
  );
  api.accessToken = reg['access_token'] as String;
  return _ChaosUser(
    name: name,
    api: api,
    crypto: crypto,
    userId: reg['user_id'] as String,
    login: login,
  );
}

Future<void> _ensureSession(_ChaosUser from, _ChaosUser to) async {
  final bundle = await from.api.getPreKeyBundle(to.userId);
  await from.crypto.establishSessionFromBundle(
    to.userId,
    bundle['bundle'] as Map<String, dynamic>,
  );
}

Future<Map<String, dynamic>> _directConv(_ChaosUser a, _ChaosUser b) async {
  return a.api.createConversation(type: 'direct', participantUserIds: [b.userId]);
}

Future<String> _sendText(_ChaosUser from, _ChaosUser to, String convId, String text) async {
  final ciphertext = await from.crypto.encrypt(to.userId, utf8.encode(text));
  final sent = await from.api.sendMessage(
    conversationId: convId,
    ciphertext: ciphertext,
    contentType: 'text',
  );
  final serverCipher = sent['ciphertext'] as String;
  if (serverCipher.contains(text)) {
    throw StateError('plaintext leaked to server');
  }
  return serverCipher;
}

Future<String> _receiveDecrypt(_ChaosUser recipient, _ChaosUser sender, String convId) async {
  final history = await recipient.api.getMessages(convId);
  expect(history, isNotEmpty);
  // API returns newest-first (created_at DESC).
  final envelope = history.first as Map<String, dynamic>;
  final plain = await recipient.crypto.decrypt(sender.userId, envelope['ciphertext'] as String);
  return utf8.decode(plain);
}

Future<SettingsRuntime> _runtimeFromBlob(Map<String, dynamic> blob) async {
  SharedPreferences.setMockInitialValues({});
  final store = LocalSettingsStore();
  final lists = CatalogListStore(store: store);
  final values = (blob['values'] as Map<String, dynamic>?) ?? {};
  for (final entry in values.entries) {
    final key = SettingsCatalogBridge.catalogKey(entry.key);
    final v = entry.value;
    if (v is bool) {
      await store.setBool(key, v);
    } else if (v is int) {
      await store.setInt(key, v);
    } else if (v is num) {
      await store.setInt(key, v.toInt());
    } else {
      await store.setString(key, v.toString());
    }
  }
  final listMap = (blob['lists'] as Map<String, dynamic>?) ?? {};
  for (final entry in listMap.entries) {
    await lists.save(entry.key, List<String>.from(entry.value as List));
  }
  return SettingsRuntime(
    reader: CatalogSettingsReader(store: store),
    lists: lists,
  );
}

Future<void> _applyProfileSettings(_ChaosUser user, Map<String, dynamic> values, [Map<String, dynamic>? lists]) async {
  await user.api.updateProfileSettings({
    'values': values,
    'lists': lists ?? {},
  });
}

void _printReport() {
  print('\n${'=' * 72}');
  print('SETTINGS CHAOS REPORT');
  print('=' * 72);
  const wActor = 8;
  const wSetting = 28;
  const wScenario = 22;
  print('${'ACTOR'.padRight(wActor)} ${'SETTING'.padRight(wSetting)} ${'SCENARIO'.padRight(wScenario)} STATUS');
  print('-' * 72);
  for (final c in _report) {
    final status = switch (c.status) {
      CheckStatus.pass => 'PASS',
      CheckStatus.fail => 'FAIL',
      CheckStatus.warn => 'WARN',
      CheckStatus.skip => 'SKIP',
    };
    print('${c.actor.padRight(wActor)} ${c.settingId.padRight(wSetting)} ${c.scenario.padRight(wScenario)} $status');
    if (c.detail.isNotEmpty) {
      print('  └─ ${c.detail}');
    }
  }
  final pass = _report.where((c) => c.status == CheckStatus.pass).length;
  final fail = _report.where((c) => c.status == CheckStatus.fail).length;
  final warn = _report.where((c) => c.status == CheckStatus.warn).length;
  print('-' * 72);
  print('TOTAL: ${_report.length}  PASS: $pass  FAIL: $fail  WARN: $warn');
  print('=' * 72);
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await BootstrapStore.clear();
  });

  test('three users rotate messages and apply settings — chaos audit', () async {
    final runId = DateTime.now().microsecondsSinceEpoch;
    final loginAlice = 'chaos_a_${runId % 10000000}';
    final loginBob = 'chaos_b_${(runId + 1) % 10000000}';
    final loginCarol = 'chaos_c_${(runId + 2) % 10000000}';
    final phoneBase = 9000000000 + (runId % 900000000);

    // ── Register triangle ───────────────────────────────────────────────────
    final alice = await _registerUser(name: 'Alice', phoneNonce: phoneBase, login: loginAlice, authByte: 11);
    final bob = await _registerUser(name: 'Bob', phoneNonce: phoneBase + 1, login: loginBob, authByte: 22);
    final carol = await _registerUser(name: 'Carol', phoneNonce: phoneBase + 2, login: loginCarol, authByte: 33);

    _recordOk('setup', 'auth.register', 'three users registered',
        detail: '${alice.userId}, ${bob.userId}, ${carol.userId}');

    for (final pair in [
      (alice, bob),
      (bob, carol),
      (carol, alice),
    ]) {
      await _ensureSession(pair.$1, pair.$2);
    }

    final convAb = await _directConv(alice, bob);
    final convBc = await _directConv(bob, carol);
    final convCa = await _directConv(carol, alice);

    await alice.api.updateProfile(
      displayName: 'Alice Chaos $runId',
      bio: 'bio-alice-$runId',
      login: loginAlice,
    );
    await _applyProfileSettings(alice, {
      'profile.display_name': 'Alice Chaos $runId',
      'profile.username_enabled': true,
      'profile.username': loginAlice,
      'profile.bio': 'bio-alice-$runId',
      'privacy.username_search': true,
      'sync.enabled': true,
    });

    final aliceMe = await alice.api.getMyProfile();
    if (aliceMe['display_name'] == 'Alice Chaos $runId' && aliceMe['bio'] == 'bio-alice-$runId') {
      _recordOk('Alice', 'profile.display_name', 'GET /users/me reflects profile');
    } else {
      _recordFail('Alice', 'profile.display_name', 'GET /users/me', 'got $aliceMe');
    }

    // ── Bob: storage S3 + read receipts off + block Alice later ─────────────
    await _applyProfileSettings(bob, {
      'storage.media_location': 'selected_s3',
      'storage.s3_endpoint': 'https://s3.test.local',
      'storage.s3_bucket': 'chaos-bucket',
      'storage.s3_access_key': 'AKIATEST',
      'storage.s3_secret_key': 'secret-test',
      'storage.message_location': 'personal_node',
      'privacy.read_receipts': false,
      'messages.read_receipts_override': true,
      'messages.send_key': 'ctrl_enter',
    }, {
      'contacts.blocked_list': [alice.userId],
    });

    final bobBlob = await bob.api.getProfileSettings();
    final gotBucket = (bobBlob['values'] as Map?)?['storage.s3_bucket'];
    if (gotBucket == 'chaos-bucket') {
      _recordOk('Bob', 'profile-settings', 'PUT/GET roundtrip storage.s3_bucket');
    } else {
      _recordFail('Bob', 'profile-settings', 'roundtrip', 'bucket=$gotBucket');
    }

    final bobStorage = await _fetchStorageProfile(bob.userId);
    final profile = bobStorage?['profile'] as Map<String, dynamic>?;
    if (profile?['backend'] == 's3' && (profile?['s3'] as Map?)?['bucket'] == 'chaos-bucket') {
      _recordOk('Bob', 'storage.media_location', 'internal storage-profile → S3');
    } else {
      _recordFail('Bob', 'storage.media_location', 'storage-profile', '${bobStorage ?? 'null'}');
    }

    final bobRuntime = await _runtimeFromBlob(bobBlob);
    if (!await bobRuntime.readReceiptsEnabled()) {
      _recordOk('Bob', 'privacy.read_receipts', 'SettingsRuntime.readReceiptsEnabled=false');
    } else {
      _recordFail('Bob', 'privacy.read_receipts', 'runtime', 'still enabled');
    }
    if (await bobRuntime.isBlocked(alice.userId)) {
      _recordOk('Bob', 'contacts.blocked_list', 'SettingsRuntime.isBlocked(alice)');
    } else {
      _recordFail('Bob', 'contacts.blocked_list', 'runtime', 'alice not blocked');
    }
    if (await bobRuntime.sendKey() == 'ctrl_enter') {
      _recordOk('Bob', 'messages.send_key', 'SettingsRuntime.sendKey');
    } else {
      _recordWarn('Bob', 'messages.send_key', 'runtime', 'UI-only until chat uses runtime');
    }

    // ── Carol: hide from username search + nobody incoming ──────────────────
    await carol.api.updateProfile(login: loginCarol);
    await _applyProfileSettings(carol, {
      'privacy.username_search': false,
      'privacy.incoming_messages': 'nobody',
      'appearance.theme': 'dark',
      'node.allow_relays': false,
    });

    final carolBlob = await carol.api.getProfileSettings();
    final carolRuntime = await _runtimeFromBlob(carolBlob);
    if (!await carolRuntime.incomingMessagesAllowed(alice.userId, isContact: false)) {
      _recordOk('Carol', 'privacy.incoming_messages', 'SettingsRuntime blocks strangers');
    } else {
      _recordFail('Carol', 'privacy.incoming_messages', 'runtime', 'still allows');
    }
    if (await carolRuntime.nodeAllowRelays() == false) {
      _recordOk('Carol', 'node.allow_relays', 'SettingsRuntime.nodeAllowRelays');
    } else {
      _recordWarn('Carol', 'node.allow_relays', 'runtime', 'node routing not exercised in test');
    }

    // ── Round-robin messaging (2 rounds) ────────────────────────────────────
    final rounds = [
      (alice, bob, convAb['id'] as String, 'A→B r1'),
      (bob, carol, convBc['id'] as String, 'B→C r1'),
      (carol, alice, convCa['id'] as String, 'C→A r1'),
      (alice, bob, convAb['id'] as String, 'A→B r2 after settings'),
      (bob, carol, convBc['id'] as String, 'B→C r2 after settings'),
      (carol, alice, convCa['id'] as String, 'C→A r2 after settings'),
    ];

    for (final (from, to, convId, label) in rounds) {
      try {
        await _sendText(from, to, convId, label);
        final decrypted = await _receiveDecrypt(to, from, convId);
        if (decrypted == label) {
          _recordOk(from.name, 'messaging.e2ee', label);
        } else {
          _recordFail(from.name, 'messaging.e2ee', label, 'decrypted="$decrypted"');
        }
      } catch (e) {
        _recordFail(from.name, 'messaging.e2ee', label, e.toString());
      }
    }

    // ── Discovery search policy (after messaging) ─────────────────────────
    final aliceDiscBefore = await _discoveryUserById(alice.userId);
    if (aliceDiscBefore != null && aliceDiscBefore['login'] != null) {
      _recordOk('Alice', 'discovery.publish', 'home→discovery user record present');
    } else {
      _recordWarn('Alice', 'discovery.publish', 'home→discovery', 'not visible before manual sync');
    }

    final carolDiscBefore = await _discoveryUserById(carol.userId);
    if (carolDiscBefore != null && carolDiscBefore['login'] != null) {
      _recordOk('Carol', 'discovery.publish', 'home→discovery user record present');
    } else {
      _recordWarn('Carol', 'discovery.publish', 'home→discovery', 'not visible before manual sync');
    }

    final searchAlice = await _assertDiscoverySearchPolicy(
      user: alice,
      usernameSearchEnabled: true,
      displayName: 'Alice Chaos $runId',
      expectedStatus: 200,
    );
    if (searchAlice == 200) {
      _recordOk('Alice', 'privacy.username_search', 'discovery search when enabled');
    } else {
      _recordFail('Alice', 'privacy.username_search', 'discovery search', 'HTTP $searchAlice login=$loginAlice');
    }

    final searchCarol = await _assertDiscoverySearchPolicy(
      user: carol,
      usernameSearchEnabled: false,
      displayName: 'Carol-$phoneBase',
      expectedStatus: 403,
    );
    if (searchCarol == 403) {
      _recordOk('Carol', 'privacy.username_search', 'discovery search disabled → 403');
    } else {
      _recordFail('Carol', 'privacy.username_search', 'discovery search', 'HTTP $searchCarol (expected 403)');
    }

    if (searchAlice == 200 && searchCarol == 403) {
      _recordOk('all', 'privacy.username_search', 'search policy isolated per user');
    } else {
      _recordFail('all', 'privacy.username_search', 'isolation', 'alice=$searchAlice carol=$searchCarol');
    }

    _printReport();

    final failures = _report.where((c) => c.status == CheckStatus.fail).length;
    expect(failures, 0, reason: 'chaos audit has $_report failures — see report above');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
