import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/router/app_router.dart';
import 'package:training_app/core/storage/appearance_storage.dart';
import 'package:training_app/core/theme/app_theme.dart';
import 'package:training_app/core/theme/appearance_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final storage = AppearanceStorage();
  ThemeMode? initialMode;
  try {
    initialMode = await storage.readMode().timeout(const Duration(seconds: 2));
  } catch (_) {
    // Start safely; the controller will attempt its normal asynchronous restore.
  }
  runApp(
    ProviderScope(
      overrides: [
        appearanceStorageProvider.overrideWithValue(storage),
        appearanceControllerProvider.overrideWith(
          () => AppearanceController(initialMode: initialMode),
        ),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);

    return MaterialApp.router(
      title: 'Garden\'s Need Training',
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ref.watch(
        appearanceControllerProvider.select((state) => state.mode),
      ),
      routerConfig: router,
    );
  }
}
