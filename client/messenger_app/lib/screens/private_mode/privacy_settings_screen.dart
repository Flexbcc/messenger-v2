import 'package:flutter/material.dart';

import 'confidentiality_hub_screen.dart';

/// Legacy flat privacy settings — replaced by [ConfidentialityHubScreen].
class PrivacySettingsScreen extends StatelessWidget {
  const PrivacySettingsScreen({super.key});

  @override
  Widget build(BuildContext context) => const ConfidentialityHubScreen();
}
