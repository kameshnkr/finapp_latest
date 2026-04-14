import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/app_theme.dart';
import 'state/app_controller.dart';
import 'ui/app_shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FinappApp());
}

class FinappApp extends StatelessWidget {
  const FinappApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppController()..tryRestoreSession(),
      child: MaterialApp(
        title: 'Finapp',
        theme: buildFinappTheme(),
        home: const AppShell(),
      ),
    );
  }
}
