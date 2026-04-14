import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_controller.dart';
import 'auth/login_screen.dart';
import 'home/home_screen.dart';

class AppShell extends StatelessWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    if (!app.isAuthenticated) {
      return const LoginScreen();
    }
    return const HomeScreen();
  }
}
