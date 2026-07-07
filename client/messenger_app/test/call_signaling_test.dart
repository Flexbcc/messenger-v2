// Verifies call signaling plumbing (spec/0303_CALLS.md, ADR-0008): offer/
// answer/ICE/reject/cancel/end/busy ride the existing 1:1 E2EE session
// (already proven end-to-end by crypto_roundtrip_test.dart) and are
// distinguishable from regular chat content by content_type, exactly like
// the group `sender_key_distribution` control messages. No WebRTC/network
// involved — this test exercises encode/decode only.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:messenger_app/calls/call_signal.dart';
import 'package:messenger_app/calls/call_signaling_service.dart';
import 'package:messenger_app/crypto/crypto_service.dart';

void main() {
  test('offer/answer/ICE/end round-trip through the 1:1 session and decode correctly', () async {
    final aliceCrypto = CryptoService.ephemeral();
    final bobCrypto = CryptoService.ephemeral();
    final alice = CallSignalingService(aliceCrypto);
    final bob = CallSignalingService(bobCrypto);

    // Same X3DH setup as crypto_roundtrip_test.dart.
    final bobBundle = await bobCrypto.generatePublishableBundle();
    await aliceCrypto.establishSessionFromBundle('bob', bobBundle);

    const callId = 'call-123';

    final offerCiphertext = await alice.encodeOffer(
      peerUserId: 'bob',
      callId: callId,
      kind: CallKind.video,
      sdp: 'v=0 offer-sdp',
    );
    expect(CallSignalingService.isCallSignal('call_offer'), isTrue);
    final decodedOffer = await bob.decode(senderUserId: 'alice', contentType: 'call_offer', ciphertext: offerCiphertext);
    expect(decodedOffer.type, CallSignalType.offer);
    expect(decodedOffer.callId, callId);
    expect(decodedOffer.kind, CallKind.video);
    expect(decodedOffer.sdp, 'v=0 offer-sdp');

    final answerCiphertext = await bob.encodeAnswer(peerUserId: 'alice', callId: callId, sdp: 'v=0 answer-sdp');
    final decodedAnswer = await alice.decode(senderUserId: 'bob', contentType: 'call_answer', ciphertext: answerCiphertext);
    expect(decodedAnswer.type, CallSignalType.answer);
    expect(decodedAnswer.callId, callId);
    expect(decodedAnswer.sdp, 'v=0 answer-sdp');

    final candidate = {'candidate': 'candidate:1 1 UDP 1 1.2.3.4 5 typ host', 'sdpMid': '0', 'sdpMLineIndex': 0};
    final iceCiphertext = await alice.encodeIceCandidate(peerUserId: 'bob', callId: callId, candidate: candidate);
    final decodedIce = await bob.decode(senderUserId: 'alice', contentType: 'call_ice_candidate', ciphertext: iceCiphertext);
    expect(decodedIce.type, CallSignalType.iceCandidate);
    expect(decodedIce.candidate, candidate);

    final endCiphertext = await bob.encodeEnd(peerUserId: 'alice', callId: callId);
    final decodedEnd = await alice.decode(senderUserId: 'bob', contentType: 'call_end', ciphertext: endCiphertext);
    expect(decodedEnd.type, CallSignalType.end);
    expect(decodedEnd.callId, callId);
    expect(decodedEnd.sdp, isNull);
    expect(decodedEnd.kind, isNull);
  });

  test('reject/cancel/busy carry only a call_id, no extra payload', () async {
    final aliceCrypto = CryptoService.ephemeral();
    final bobCrypto = CryptoService.ephemeral();
    final alice = CallSignalingService(aliceCrypto);
    final bob = CallSignalingService(bobCrypto);

    final bobBundle = await bobCrypto.generatePublishableBundle();
    await aliceCrypto.establishSessionFromBundle('bob', bobBundle);

    const callId = 'call-456';

    // Bob's side of the session only exists once he's decrypted a first
    // message from Alice (PreKeySignalMessage) — same asymmetry already
    // exercised by crypto_roundtrip_test.dart. A real call always starts
    // with an offer alice->bob, so that's what establishes it here too.
    final offerCiphertext = await alice.encodeOffer(peerUserId: 'bob', callId: callId, kind: CallKind.audio, sdp: 'v=0');
    await bob.decode(senderUserId: 'alice', contentType: 'call_offer', ciphertext: offerCiphertext);

    final rejectCiphertext = await bob.encodeReject(peerUserId: 'alice', callId: callId);
    expect((await alice.decode(senderUserId: 'bob', contentType: 'call_reject', ciphertext: rejectCiphertext)).type, CallSignalType.reject);

    final cancelCiphertext = await alice.encodeCancel(peerUserId: 'bob', callId: callId);
    expect((await bob.decode(senderUserId: 'alice', contentType: 'call_cancel', ciphertext: cancelCiphertext)).type, CallSignalType.cancel);

    final busyCiphertext = await bob.encodeBusy(peerUserId: 'alice', callId: callId);
    expect((await alice.decode(senderUserId: 'bob', contentType: 'call_busy', ciphertext: busyCiphertext)).type, CallSignalType.busy);
  });

  test('isCallSignal distinguishes signaling content_types from regular chat content', () {
    expect(CallSignalingService.isCallSignal('call_offer'), isTrue);
    expect(CallSignalingService.isCallSignal('call_answer'), isTrue);
    expect(CallSignalingService.isCallSignal('call_ice_candidate'), isTrue);
    expect(CallSignalingService.isCallSignal('call_reject'), isTrue);
    expect(CallSignalingService.isCallSignal('call_cancel'), isTrue);
    expect(CallSignalingService.isCallSignal('call_end'), isTrue);
    expect(CallSignalingService.isCallSignal('call_busy'), isTrue);
    expect(CallSignalingService.isCallSignal('text'), isFalse);
    expect(CallSignalingService.isCallSignal('image'), isFalse);
    expect(CallSignalingService.isCallSignal('sender_key_distribution'), isFalse);
  });

  test('decode throws for a non-call content_type instead of silently misinterpreting it', () async {
    final aliceCrypto = CryptoService.ephemeral();
    final bobCrypto = CryptoService.ephemeral();
    final bob = CallSignalingService(bobCrypto);

    final bobBundle = await bobCrypto.generatePublishableBundle();
    await aliceCrypto.establishSessionFromBundle('bob', bobBundle);
    final textCiphertext = await aliceCrypto.encrypt('bob', Uint8List.fromList(utf8.encode('hello')));

    expect(
      () => bob.decode(senderUserId: 'alice', contentType: 'text', ciphertext: textCiphertext),
      throwsArgumentError,
    );
  });
}
