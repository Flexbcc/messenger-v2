import 'node_owner_http_transport.dart';
import 'node_owner_transport_stub.dart'
    if (dart.library.io) 'node_owner_transport_io.dart'
    as platform;

NodeOwnerTransport createNodeOwnerTransport() =>
    platform.createNodeOwnerTransport();
