import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Desktop FFI sqlite factory before opening any database.
class DatabaseInit {
  DatabaseInit._();
  static bool _ready = false;

  static bool get isInitialized => _ready;

  static Future<void> ensureInitialized() async {
    if (_ready) return;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    _ready = true;
  }
}
