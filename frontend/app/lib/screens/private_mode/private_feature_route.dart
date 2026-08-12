import 'package:flutter/material.dart';

import '../../security/private_feature_access.dart';

/// Opens secret-feature screens only after both PIN prerequisites are verified.
/// The destination builder is not invoked before authorization succeeds.
Route<void> privateSecretRoute(
  WidgetBuilder destination, {
  Future<PrivateFeatureAccess> Function()? accessLoader,
}) {
  return MaterialPageRoute<void>(
    builder: (_) => _PrivateFeatureGate(
      destination: destination,
      accessLoader: accessLoader ?? PrivateFeatureAccess.load,
    ),
  );
}

class _PrivateFeatureGate extends StatefulWidget {
  const _PrivateFeatureGate({
    required this.destination,
    required this.accessLoader,
  });

  final WidgetBuilder destination;
  final Future<PrivateFeatureAccess> Function() accessLoader;

  @override
  State<_PrivateFeatureGate> createState() => _PrivateFeatureGateState();
}

class _PrivateFeatureGateState extends State<_PrivateFeatureGate> {
  late final Future<PrivateFeatureAccess> _access = widget.accessLoader();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PrivateFeatureAccess>(
      future: _access,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.data?.canUseSecretFeatures != true) {
          return Scaffold(
            appBar: AppBar(title: const Text('Защищённый раздел')),
            body: const Center(
              child: Text('Сначала завершите настройку защиты'),
            ),
          );
        }
        return widget.destination(context);
      },
    );
  }
}
