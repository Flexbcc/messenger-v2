// mDNS-объявление: Flutter → bonsoir; headless Dart → no-op stub.
library;

export 'mdns_advertiser_stub.dart'
    if (dart.library.ui) 'mdns_advertiser_bonsoir.dart';
