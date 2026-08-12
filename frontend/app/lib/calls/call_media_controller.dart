import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Simplified connection-state surface for the app — collapses
/// flutter_webrtc's ICE states down to what spec/0303_CALLS.md →
/// Устойчивость соединения actually needs to react to.
enum MediaConnectionState {
  connecting,
  connected,
  disconnected,
  failed,
  closed,
}

/// Wraps one `RTCPeerConnection` for the call in progress — the only module
/// that touches flutter_webrtc directly (Single Responsibility, same
/// posture as CryptoService for libsignal). `AppController` owns signaling
/// delivery, addressing, and call-state orchestration; this owns media/ICE
/// mechanics only (spec/0303_CALLS.md, ADR-0008).
class CallMediaController {
  CallMediaController._(this._pc, this._localStream);

  final RTCPeerConnection _pc;
  final MediaStream _localStream;
  MediaStream get localStream => _localStream;
  MediaStream? remoteStream;

  bool _muted = false;
  bool _onHold = false;
  bool _speakerOn = false;

  bool get isMuted => _muted;
  bool get onHold => _onHold;
  bool get isSpeakerOn => _speakerOn;

  void _applyAudioState() {
    final enableLocal = !_muted && !_onHold;
    for (final track in _localStream.getAudioTracks()) {
      track.enabled = enableLocal;
    }
    final remote = remoteStream;
    if (remote != null) {
      for (final track in remote.getAudioTracks()) {
        track.enabled = !_onHold;
      }
    }
  }

  void setMuted(bool muted) {
    _muted = muted;
    _applyAudioState();
  }

  void setOnHold(bool hold) {
    _onHold = hold;
    _applyAudioState();
  }

  /// Loudspeaker / speakerphone. Best-effort: platforms without routing
  /// still flip the UI flag so controls and screenshots stay consistent.
  Future<void> setSpeaker(bool on) async {
    _speakerOn = on;
    try {
      await Helper.setSpeakerphoneOn(on);
    } catch (_) {}
  }

  final _connectionStateController =
      StreamController<MediaConnectionState>.broadcast();
  Stream<MediaConnectionState> get connectionState =>
      _connectionStateController.stream;

  /// Fired for every locally-gathered ICE candidate — the caller is
  /// responsible for delivering it (over the existing E2EE signaling
  /// channel, see CallSignalingService), not this class.
  void Function(Map<String, dynamic> candidate)? onLocalIceCandidate;
  void Function(MediaStream stream)? onRemoteStream;

  bool _remoteDescriptionSet = false;
  final List<RTCIceCandidate> _pendingRemoteCandidates = [];

  bool _disposed = false;

  static Future<CallMediaController> create({
    required List<Map<String, dynamic>> iceServers,
    required bool video,
    bool forceRelay = false,
    bool noiseSuppression = true,
    bool echoCancellation = true,
    String quality = 'balanced',
    bool dataSaver = false,
  }) async {
    final pcConfig = <String, dynamic>{
      'iceServers': iceServers,
      if (forceRelay) 'iceTransportPolicy': 'relay',
    };
    final pc = await createPeerConnection(pcConfig);
    final mediaConstraints = <String, dynamic>{
      'audio': {
        'noiseSuppression': noiseSuppression,
        'echoCancellation': echoCancellation,
      },
      'video': video
          ? _videoConstraints(quality: quality, dataSaver: dataSaver)
          : false,
    };
    final localStream = await navigator.mediaDevices.getUserMedia(
      mediaConstraints,
    );
    for (final track in localStream.getTracks()) {
      await pc.addTrack(track, localStream);
    }
    final controller = CallMediaController._(pc, localStream);
    controller._wire();
    return controller;
  }

  static Map<String, dynamic> _videoConstraints({
    required String quality,
    required bool dataSaver,
  }) {
    final effective = dataSaver ? 'low' : quality;
    return switch (effective) {
      'high' => {
        'width': {'ideal': 1280},
        'height': {'ideal': 720},
        'frameRate': {'ideal': 30},
      },
      'low' => {
        'width': {'ideal': 320},
        'height': {'ideal': 240},
        'frameRate': {'ideal': 15},
      },
      _ => {
        'width': {'ideal': 640},
        'height': {'ideal': 480},
        'frameRate': {'ideal': 24},
      },
    };
  }

  void _wire() {
    _pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null) {
        return; // end-of-candidates marker, nothing to send
      }
      onLocalIceCandidate?.call(candidate.toMap());
    };
    _pc.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        remoteStream = event.streams.first;
        onRemoteStream?.call(remoteStream!);
      }
    };
    _pc.onIceConnectionState = (state) {
      if (_disposed) return;
      if (!_connectionStateController.isClosed) {
        _connectionStateController.add(_simplify(state));
      }
    };
  }

  MediaConnectionState _simplify(RTCIceConnectionState state) {
    switch (state) {
      case RTCIceConnectionState.RTCIceConnectionStateConnected:
      case RTCIceConnectionState.RTCIceConnectionStateCompleted:
        return MediaConnectionState.connected;
      case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
        return MediaConnectionState.disconnected;
      case RTCIceConnectionState.RTCIceConnectionStateFailed:
        return MediaConnectionState.failed;
      case RTCIceConnectionState.RTCIceConnectionStateClosed:
        return MediaConnectionState.closed;
      case RTCIceConnectionState.RTCIceConnectionStateNew:
      case RTCIceConnectionState.RTCIceConnectionStateChecking:
      case RTCIceConnectionState.RTCIceConnectionStateCount:
        return MediaConnectionState.connecting;
    }
  }

  Future<String> createOffer() async {
    final desc = await _pc.createOffer();
    await _pc.setLocalDescription(desc);
    return desc.sdp!;
  }

  /// Sets the remote offer and produces our answer in one step — mirrors
  /// how a callee always processes an offer immediately before replying.
  Future<String> createAnswer(String remoteOfferSdp) async {
    await setRemoteDescription(remoteOfferSdp, 'offer');
    final desc = await _pc.createAnswer();
    await _pc.setLocalDescription(desc);
    return desc.sdp!;
  }

  Future<void> applyRemoteAnswer(String sdp) =>
      setRemoteDescription(sdp, 'answer');

  Future<void> setRemoteDescription(String sdp, String type) async {
    await _pc.setRemoteDescription(RTCSessionDescription(sdp, type));
    _remoteDescriptionSet = true;
    for (final candidate in _pendingRemoteCandidates) {
      await _pc.addCandidate(candidate);
    }
    _pendingRemoteCandidates.clear();
  }

  /// Buffers the candidate if the remote description isn't set yet — ICE
  /// candidates can arrive before setRemoteDescription() completes.
  Future<void> addRemoteIceCandidate(Map<String, dynamic> candidate) async {
    final ice = RTCIceCandidate(
      candidate['candidate'] as String?,
      candidate['sdpMid'] as String?,
      candidate['sdpMLineIndex'] as int?,
    );
    if (!_remoteDescriptionSet) {
      _pendingRemoteCandidates.add(ice);
      return;
    }
    await _pc.addCandidate(ice);
  }

  /// Attempts to re-establish connectivity without tearing down the call —
  /// see spec/0303_CALLS.md → Устойчивость соединения.
  Future<void> restartIce() => _pc.restartIce();

  Future<void> dispose() async {
    _disposed = true;
    if (!_connectionStateController.isClosed) {
      await _connectionStateController.close();
    }
    for (final track in _localStream.getTracks()) {
      await track.stop();
    }
    await _pc.close();
  }
}
