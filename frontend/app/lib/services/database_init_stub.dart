/// Web / wasm — no sqlite FFI initialization needed.
class DatabaseInit {
  DatabaseInit._();
  static bool _ready = false;

  static bool get isInitialized => _ready;

  static Future<void> ensureInitialized() async {
    _ready = true;
  }
}
