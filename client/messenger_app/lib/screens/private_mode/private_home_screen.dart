import 'package:flutter/material.dart';

import 'confidentiality_hub_screen.dart';

/// Legacy Private Mode hub — redirects to the nested confidentiality settings.
class PrivateHomeScreen extends StatelessWidget {
  const PrivateHomeScreen({super.key});

  @override
  Widget build(BuildContext context) => const ConfidentialityHubScreen();
}

/// Backward-compatible alias.
typedef SecretRoomScreen = PrivateHomeScreen;
