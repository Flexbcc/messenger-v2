import 'dart:convert';
import 'dart:io';

import 'package:messenger_app/services/node_owner/node_owner_transport_io.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln(
      'usage: dart run tool/verify_management_tls.dart <https-url> <sha256:fingerprint>',
    );
    exitCode = 64;
    return;
  }
  final base = Uri.parse(arguments[0]);
  final response = await IoNodeOwnerTransport().send(
    uri: base.replace(path: '/health'),
    method: 'GET',
    headers: const {},
    body: const [],
    expectedCaFingerprint: arguments[1],
  );
  if (response.statusCode != 200) {
    throw StateError('management health returned ${response.statusCode}');
  }
  final body = jsonDecode(utf8.decode(response.body));
  if (body is! Map || body['service'] != 'owner-management') {
    throw const FormatException('unexpected management health response');
  }
  stdout.writeln(jsonEncode(body));
}
