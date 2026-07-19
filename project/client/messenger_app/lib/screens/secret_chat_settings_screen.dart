import 'package:flutter/material.dart';

import 'private_mode/privacy_secret_section_screen.dart';

/// Legacy entry — redirects to the nested secret-room section.
class SecretChatSettingsScreen extends StatelessWidget {
  const SecretChatSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) => const PrivacySecretSectionScreen();
}
