part of 'app_controller.dart';

extension AppControllerCallOperations on AppController {
  Future<void> _sendCallSignal({
    required String peerUserId,
    required String contentType,
    required String ciphertext,
  }) async {
    final conv = await _findOrCreateDirectConversation(peerUserId);
    await _api.sendMessage(
      conversationId: conv.id,
      ciphertext: ciphertext,
      contentType: contentType,
    );
  }

  /// Resolves public STUN plus a Turn Node's temporary credentials when
  /// relays are enabled. An unavailable Turn Node degrades to STUN-only.
  Future<List<Map<String, dynamic>>> _resolveIceServers() async {
    final allowRelays = await SettingsRuntime.instance.nodeAllowRelays();
    return _callIce.resolve(
      allowRelays: allowRelays,
      stunUrls: AppConfig.callStunUrls,
    );
  }

  Future<void> startCall({
    required String peerUserId,
    required CallKind kind,
  }) async {
    if (currentCall != null) throw StateError('already in a call');
    final runtime = SettingsRuntime.instance;
    if (!await _interactionPolicy.canInitiate(peerUserId)) {
      throw StateError('Контакт заблокирован');
    }
    var effectiveKind = kind;
    if (kind == CallKind.video && !await runtime.callsVideo()) {
      effectiveKind = CallKind.audio;
    }
    final callId = _uuid.v4();
    await _ensureSessionWith(peerUserId);

    final media = await CallMediaController.create(
      iceServers: await _resolveIceServers(),
      video: effectiveKind == CallKind.video,
      forceRelay: await runtime.callsIceRelayOnly(),
      noiseSuppression: await runtime.callsNoiseSuppression(),
      echoCancellation: await runtime.callsEchoCancellation(),
      quality: await runtime.callsQuality(),
      dataSaver: await runtime.callsDataSaver(),
    );
    final call = ActiveCall(
      callId: callId,
      peerUserId: peerUserId,
      kind: effectiveKind,
      outgoing: true,
    )..media = media;
    currentCall = call;
    callUiMinimized = false;
    _wireMedia(call, media);
    _notifyStateChanged();

    final sdp = await media.createOffer();
    await _sendCallSignal(
      peerUserId: peerUserId,
      contentType: CallSignalType.offer.contentType,
      ciphertext: await _callSignaling.encodeOffer(
        peerUserId: peerUserId,
        callId: callId,
        kind: effectiveKind,
        sdp: sdp,
      ),
    );
  }

  Future<void> answerCall() async {
    final call = currentCall;
    if (call == null ||
        call.outgoing ||
        call.answered ||
        call.remoteSdp == null) {
      return;
    }

    final runtime = SettingsRuntime.instance;
    final useVideo = call.kind == CallKind.video && await runtime.callsVideo();
    final media = await CallMediaController.create(
      iceServers: await _resolveIceServers(),
      video: useVideo,
      forceRelay: await runtime.callsIceRelayOnly(),
      noiseSuppression: await runtime.callsNoiseSuppression(),
      echoCancellation: await runtime.callsEchoCancellation(),
      quality: await runtime.callsQuality(),
      dataSaver: await runtime.callsDataSaver(),
    );
    call.media = media;
    _wireMedia(call, media);
    for (final candidate in call.pendingRemoteIceCandidates) {
      await media.addRemoteIceCandidate(candidate);
    }
    call.pendingRemoteIceCandidates.clear();

    final sdp = await media.createAnswer(call.remoteSdp!);
    await _sendCallSignal(
      peerUserId: call.peerUserId,
      contentType: CallSignalType.answer.contentType,
      ciphertext: await _callSignaling.encodeAnswer(
        peerUserId: call.peerUserId,
        callId: call.callId,
        sdp: sdp,
      ),
    );
    call.answered = true;
    call.answeredAt = DateTime.now();
    _notifyStateChanged();
  }

  Future<void> callPeer({required String peerUserId, required CallKind kind}) =>
      startCall(peerUserId: peerUserId, kind: kind);

  Future<void> clearCallHistory() async {
    await _callHistory.clear();
    _notifyStateChanged();
  }

  void _wireMedia(ActiveCall call, CallMediaController media) {
    media.onLocalIceCandidate = (candidate) =>
        unawaited(_sendLocalIceCandidate(call, candidate));
    media.connectionState.listen(
      (state) => unawaited(_onMediaConnectionState(call, state)),
    );
  }

  Future<void> _sendLocalIceCandidate(
    ActiveCall call,
    Map<String, dynamic> candidate,
  ) async {
    if (currentCall?.callId != call.callId) return;
    try {
      await _sendCallSignal(
        peerUserId: call.peerUserId,
        contentType: CallSignalType.iceCandidate.contentType,
        ciphertext: await _callSignaling.encodeIceCandidate(
          peerUserId: call.peerUserId,
          callId: call.callId,
          candidate: candidate,
        ),
      );
    } catch (_) {
      // ICE can continue with the remaining candidates.
    }
  }

  Future<void> _onMediaConnectionState(
    ActiveCall call,
    MediaConnectionState state,
  ) async {
    if (currentCall?.callId != call.callId) return;
    final decision = CallRecoveryPolicy.decide(
      state: state,
      waitingForNetwork: call.waitingForNetwork,
    );
    switch (decision) {
      case CallRecoveryDecision.recovered:
        call.waitingForNetwork = false;
        call.reconnectTimer?.cancel();
        _notifyStateChanged();
      case CallRecoveryDecision.startRecovery:
        call.waitingForNetwork = true;
        _notifyStateChanged();
        unawaited(call.media?.restartIce());
        call.reconnectTimer = Timer(
          const Duration(seconds: 20),
          () => unawaited(_onNetworkRecoveryTimedOut(call)),
        );
      case CallRecoveryDecision.terminate:
        call.reconnectTimer?.cancel();
        await _teardownAfterMediaFailure(call);
      case CallRecoveryDecision.ignore:
        return;
    }
  }

  Future<void> _onNetworkRecoveryTimedOut(ActiveCall call) async {
    if (currentCall?.callId != call.callId || !call.waitingForNetwork) return;
    await _teardownAfterMediaFailure(call);
  }

  Future<void> _teardownAfterMediaFailure(ActiveCall call) async {
    if (currentCall?.callId != call.callId) return;
    final type = call.answered
        ? CallSignalType.end
        : (call.outgoing ? CallSignalType.cancel : CallSignalType.reject);
    try {
      await _sendTeardownSignal(call, type);
    } catch (_) {
      // Local teardown must still complete if peer notification fails.
    }
    final status = call.answered
        ? CallHistoryStatus.completed
        : (call.outgoing
              ? CallHistoryStatus.cancelled
              : CallHistoryStatus.missed);
    await _finalizeCall(call, status);
    _notifyStateChanged();
  }

  Future<void> _sendTeardownSignal(ActiveCall call, CallSignalType type) async {
    final ciphertext = switch (type) {
      CallSignalType.reject => await _callSignaling.encodeReject(
        peerUserId: call.peerUserId,
        callId: call.callId,
      ),
      CallSignalType.cancel => await _callSignaling.encodeCancel(
        peerUserId: call.peerUserId,
        callId: call.callId,
      ),
      CallSignalType.end => await _callSignaling.encodeEnd(
        peerUserId: call.peerUserId,
        callId: call.callId,
      ),
      _ => throw ArgumentError('not a teardown signal: $type'),
    };
    await _sendCallSignal(
      peerUserId: call.peerUserId,
      contentType: type.contentType,
      ciphertext: ciphertext,
    );
  }

  Future<void> _finalizeCall(ActiveCall call, CallHistoryStatus status) async {
    int? duration;
    if (call.answeredAt != null && status == CallHistoryStatus.completed) {
      duration = DateTime.now().difference(call.answeredAt!).inSeconds;
      if (duration <= 0) duration = 1;
    }
    final entry = CallHistoryEntry(
      callId: call.callId,
      peerUserId: call.peerUserId,
      kind: call.kind,
      outgoing: call.outgoing,
      status: status,
      startedAt: call.startedAt,
      durationSeconds: duration,
    );
    final peerLabel = labelFor(call.peerUserId);
    await _callHistory.append(entry);
    await _clearCall(call);
    _showCallEndedOverlay(peerLabel);
  }

  Future<void> _clearCall(ActiveCall call) async {
    call.reconnectTimer?.cancel();
    await call.media?.dispose();
    if (currentCall?.callId == call.callId) {
      currentCall = null;
      callUiMinimized = false;
    }
  }

  Future<void> rejectCall() async {
    final call = currentCall;
    if (call == null || call.outgoing || call.answered) return;
    await _sendTeardownSignal(call, CallSignalType.reject);
    await _finalizeCall(call, CallHistoryStatus.rejected);
    _notifyStateChanged();
  }

  Future<void> cancelCall() async {
    final call = currentCall;
    if (call == null || !call.outgoing || call.answered) return;
    await _sendTeardownSignal(call, CallSignalType.cancel);
    await _finalizeCall(call, CallHistoryStatus.cancelled);
    _notifyStateChanged();
  }

  Future<void> endCall() async {
    final call = currentCall;
    if (call == null || !call.answered) return;
    await _sendTeardownSignal(call, CallSignalType.end);
    await _finalizeCall(call, CallHistoryStatus.completed);
    _notifyStateChanged();
  }

  Future<void> _handleIncomingCallSignal(ChatMessage message) async {
    if (message.senderUserId == session?.userId) return;
    CallSignal signal;
    try {
      signal = await _callSignaling.decode(
        senderUserId: message.senderUserId,
        contentType: message.contentType,
        ciphertext: message.ciphertext,
      );
    } catch (error) {
      DebugLog.instance.warn('calls', 'call signal rejected: $error');
      return;
    }

    final incomingAllowed = await _interactionPolicy.canReceiveCall(
      message.senderUserId,
      isContact: isKnownContact(message.senderUserId),
    );
    if (!incomingAllowed) {
      if (signal.type == CallSignalType.offer) {
        await _rejectDisallowedCall(message.senderUserId, signal.callId);
      }
      return;
    }

    switch (signal.type) {
      case CallSignalType.offer:
        if (signal.sdp == null ||
            DateTime.now().difference(message.createdAt) >
                AppController._callOfferMaxAge) {
          return;
        }
        final existing = currentCall;
        if (existing != null) {
          if (existing.callId == signal.callId) return;
          try {
            await _sendCallSignal(
              peerUserId: message.senderUserId,
              contentType: CallSignalType.busy.contentType,
              ciphertext: await _callSignaling.encodeBusy(
                peerUserId: message.senderUserId,
                callId: signal.callId,
              ),
            );
          } catch (_) {
            // The caller will time out if the best-effort busy signal is lost.
          }
          return;
        }
        currentCall = ActiveCall(
          callId: signal.callId,
          peerUserId: message.senderUserId,
          kind: signal.kind ?? CallKind.audio,
          outgoing: false,
          remoteSdp: signal.sdp,
        );
        callUiMinimized = false;
        if (trustLevelFor(message.senderUserId) == TrustLevel.unknown) {
          unawaited(
            SecurityLogService.instance.append(
              SecurityEvent(
                title: 'Звонок от неизвестного контакта',
                subtitle: labelFor(message.senderUserId),
                at: DateTime.now(),
                icon: 'call',
              ),
            ),
          );
        }
        _maybeNotifyIncomingCall(message.senderUserId);
      case CallSignalType.answer:
        final call = currentCall;
        final sdp = signal.sdp;
        if (call == null ||
            call.callId != signal.callId ||
            !call.outgoing ||
            call.media == null ||
            sdp == null) {
          return;
        }
        call.remoteSdp = sdp;
        await call.media!.applyRemoteAnswer(sdp);
        call.answered = true;
        call.answeredAt = DateTime.now();
      case CallSignalType.iceCandidate:
        final call = currentCall;
        final candidate = signal.candidate;
        if (call == null || call.callId != signal.callId || candidate == null) {
          return;
        }
        if (call.media != null) {
          await call.media!.addRemoteIceCandidate(candidate);
        } else {
          call.pendingRemoteIceCandidates.add(candidate);
        }
      case CallSignalType.reject:
      case CallSignalType.cancel:
      case CallSignalType.end:
      case CallSignalType.busy:
        final call = currentCall;
        if (call != null && call.callId == signal.callId) {
          final status = switch (signal.type) {
            CallSignalType.reject => CallHistoryStatus.rejected,
            CallSignalType.cancel =>
              call.outgoing
                  ? CallHistoryStatus.cancelled
                  : CallHistoryStatus.missed,
            CallSignalType.end => CallHistoryStatus.completed,
            CallSignalType.busy => CallHistoryStatus.busy,
            _ => CallHistoryStatus.failed,
          };
          await _finalizeCall(call, status);
        }
    }
    _notifyStateChanged();
  }

  Future<void> _rejectDisallowedCall(String peerUserId, String callId) async {
    try {
      await _sendCallSignal(
        peerUserId: peerUserId,
        contentType: CallSignalType.reject.contentType,
        ciphertext: await _callSignaling.encodeReject(
          peerUserId: peerUserId,
          callId: callId,
        ),
      );
    } catch (error) {
      DebugLog.instance.warn(
        'calls',
        'Unable to reject disallowed incoming call: $error',
      );
    }
  }
}
