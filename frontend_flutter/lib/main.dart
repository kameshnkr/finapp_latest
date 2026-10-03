import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/app_theme.dart';
import 'data/api_client.dart';
import 'state/app_controller.dart';
import 'state/investments_controller.dart';
import 'ui/app_shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FinappApp());
}

class FinappApp extends StatelessWidget {
  const FinappApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Single ApiClient instance shared by both controllers, so the auth
    // token set by AppController on login/session-restore is automatically
    // visible to InvestmentsController too — no other state is shared.
    final sharedApiClient = ApiClient();

    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => AppController(apiClient: sharedApiClient)..tryRestoreSession(),
        ),
        ChangeNotifierProvider(
          create: (_) => InvestmentsController(apiClient: sharedApiClient),
        ),
      ],
      child: MaterialApp(
        title: 'Finapp',
        theme: buildFinappTheme(),
        home: const AppShell(),
      ),
    );
  }
}
