/// Explicitly unsupported on non-web targets.
class PwaUpdateBridge {
  PwaUpdateBridge._();
  static final instance = PwaUpdateBridge._();

  bool get isSupported => false;

  Future<void> applyReload() async {
    throw UnsupportedError(
      'Application reload is not supported on this target',
    );
  }
}
