import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/services/node_owner/managed_node_registry.dart';
import 'package:messenger_app/services/node_owner/node_owner_api_client.dart';
import 'package:messenger_app/services/node_owner/node_owner_http_transport.dart';
import 'package:messenger_app/services/node_owner/node_owner_key_store.dart';
import 'package:messenger_app/services/node_owner/node_owner_pairing_payload.dart';
import 'package:messenger_app/services/node_owner/node_owner_request_signer.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final enabled = Platform.environment['RUN_LIVE_OWNER_MANAGEMENT'] == '1';

  test(
    'Flutter pairs with real Python management node and revokes itself',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      final encoded = Platform.environment['OWNER_PAIRING_B64'];
      if (encoded == null || encoded.isEmpty) {
        fail('OWNER_PAIRING_B64 is required');
      }
      final pairing = NodeOwnerPairingPayload.parse(
        utf8.decode(base64Decode(encoded)),
      );
      final keys = NodeOwnerKeyStore();
      final registry = ManagedNodeRegistry(keyStore: keys);
      final client = NodeOwnerApiClient(
        transport: _LoopbackOwnerTransport(),
        keyStore: keys,
        registry: registry,
        signer: NodeOwnerRequestSigner(keyStore: keys),
      );

      final node = await client.pair(pairing: pairing, localLabel: 'Live node');
      final status = await client.status(node.nodeId);
      expect(status['status'], 'ok');
      expect(status['node_id'], node.nodeId);
      final devices = await client.devices(node.nodeId);
      expect(
        devices.any((device) => device['serial'] == node.certificateSerial),
        isTrue,
      );

      await client.revokeDevice(node.nodeId, node.certificateSerial);
      expect(await registry.list(), isEmpty);
      expect(await keys.contains(node.keyAlias), isFalse);
    },
    skip: enabled
        ? false
        : 'Requires RUN_LIVE_OWNER_MANAGEMENT=1 and a one-time pairing payload',
  );
}

class _LoopbackOwnerTransport implements NodeOwnerTransport {
  @override
  Future<NodeOwnerHttpResponse> send({
    required Uri uri,
    required String method,
    required Map<String, String> headers,
    required List<int> body,
    required String expectedCaFingerprint,
  }) async {
    if (uri.scheme != 'http' ||
        (uri.host != '127.0.0.1' && uri.host != 'localhost')) {
      throw StateError('live test transport is loopback-only');
    }
    final socket = await Socket.connect(uri.host, uri.port);
    final requestHeaders = <String, String>{
      'Host': '${uri.host}:${uri.port}',
      'Connection': 'close',
      'Content-Length': body.length.toString(),
      ...headers,
    };
    final head = StringBuffer(
      '${method.toUpperCase()} ${uri.path} HTTP/1.1\r\n',
    );
    for (final entry in requestHeaders.entries) {
      head.write('${entry.key}: ${entry.value}\r\n');
    }
    head.write('\r\n');
    socket.add(utf8.encode(head.toString()));
    socket.add(body);
    await socket.flush();
    final responseBytes = await socket.expand((chunk) => chunk).toList();
    await socket.close();
    final marker = utf8.encode('\r\n\r\n');
    var split = -1;
    for (
      var index = 0;
      index <= responseBytes.length - marker.length;
      index++
    ) {
      if (responseBytes[index] == marker[0] &&
          responseBytes[index + 1] == marker[1] &&
          responseBytes[index + 2] == marker[2] &&
          responseBytes[index + 3] == marker[3]) {
        split = index;
        break;
      }
    }
    if (split < 0) throw const FormatException('invalid HTTP response');
    final headerText = utf8.decode(responseBytes.sublist(0, split));
    final status = int.parse(headerText.split('\r\n').first.split(' ')[1]);
    return NodeOwnerHttpResponse(
      statusCode: status,
      body: responseBytes.sublist(split + marker.length),
    );
  }
}
