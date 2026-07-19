import 'package:flutter/material.dart';

import 'profile_screen.dart';

/// Legacy route — Account merged into [ProfileScreen].
@Deprecated('Use ProfileScreen')
class AccountScreen extends StatelessWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context) => const ProfileScreen();
}
