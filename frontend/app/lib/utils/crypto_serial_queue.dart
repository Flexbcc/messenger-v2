import 'dart:async';

/// Runs async work for the same [key] strictly one-after-another.
///
/// Signal Double Ratchet / sender-key operations must preserve order per
/// session. Encrypt and decrypt both mutate the same ratchet record, so every
/// direction and every control payload must share this queue.
class CryptoSerialQueue {
  final _chains = <String, Future<void>>{};

  Future<T> run<T>(String key, Future<T> Function() action) async {
    final previous = _chains[key] ?? Future<void>.value();
    final done = Completer<void>();
    _chains[key] = done.future;
    await previous;
    try {
      return await action();
    } finally {
      done.complete();
    }
  }
}
