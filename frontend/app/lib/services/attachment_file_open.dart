export 'attachment_file_open_stub.dart'
    if (dart.library.html) 'attachment_file_open_web.dart'
    if (dart.library.io) 'attachment_file_open_io.dart';
