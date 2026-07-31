/// No-op on non-web targets.
class PwaUpdateBridge {
  PwaUpdateBridge._();
  static final instance = PwaUpdateBridge._();

  void start(void Function() onReloadReady) {}

  Future<void> applyReload() async {}
}
