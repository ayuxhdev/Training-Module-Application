import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/core/theme/appearance_controller.dart';
import 'package:training_app/features/auth/presentation/screens/login_screen.dart';
import 'package:training_app/main.dart' as app;

void main() {
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late int reads;
  late String? saved;
  Future<String?> Function()? onRead;

  setUp(() {
    reads = 0;
    saved = null;
    onRead = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final arguments = call.arguments as Map;
          if (arguments['key'] != 'app_appearance_mode') return null;
          if (call.method == 'read') {
            reads++;
            final read = onRead;
            return read == null ? saved : await read();
          }
          if (call.method == 'write') saved = arguments['value'] as String?;
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  ProviderContainer container(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(app.MyApp)));

  for (final mode in ThemeMode.values) {
    testWidgets(
      '${mode.name} is applied on the first app frame with one read',
      (tester) async {
        saved = mode.name;
        final device = mode == ThemeMode.dark
            ? Brightness.light
            : Brightness.dark;
        tester.platformDispatcher.platformBrightnessTestValue = device;
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        await tester.pumpWidget(const SizedBox());
        await app.main();
        // runApp draws the warm-up frame synchronously in widget tests.
        expect(
          tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
          mode,
        );
        expect(
          Theme.of(tester.element(find.byType(Navigator).first)).brightness,
          mode == ThemeMode.system
              ? device
              : mode == ThemeMode.dark
              ? Brightness.dark
              : Brightness.light,
        );
        await tester.pumpAndSettle();
        expect(find.byType(LoginScreen), findsOneWidget);
        expect(reads, 1);
        expect(
          container(tester).read(appearanceControllerProvider).restoring,
          false,
        );

        await container(tester)
            .read(appearanceControllerProvider.notifier)
            .setMode(ThemeMode.light);
        await tester.pumpAndSettle();
        expect(saved, 'light');
        expect(reads, 1);
        expect(
          Theme.of(tester.element(find.byType(LoginScreen))).brightness,
          Brightness.light,
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('failed preload still performs asynchronous restoration', (
    tester,
  ) async {
    final restored = Completer<String?>();
    onRead = () {
      if (reads == 1) throw PlatformException(code: 'unavailable');
      return restored.future;
    };
    await tester.pumpWidget(const SizedBox());
    await app.main();
    await tester.pump();
    expect(find.byType(app.MyApp), findsOneWidget);
    expect(reads, 2);
    expect(
      container(tester).read(appearanceControllerProvider).restoring,
      true,
    );
    restored.complete('dark');
    await tester.pumpAndSettle();
    expect(
      container(tester).read(appearanceControllerProvider).mode,
      ThemeMode.dark,
    );
    expect(
      container(tester).read(appearanceControllerProvider).restoring,
      false,
    );
    expect(
      Theme.of(tester.element(find.byType(LoginScreen))).brightness,
      Brightness.dark,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('failed preload and restore retain explicit recovery', (
    tester,
  ) async {
    onRead = () async => throw PlatformException(code: 'unavailable');
    await tester.pumpWidget(const SizedBox());
    await app.main();
    await tester.pumpAndSettle();
    final providers = container(tester);
    expect(reads, 2);
    expect(providers.read(appearanceControllerProvider).restoring, false);
    expect(
      providers.read(appearanceControllerProvider).failure,
      AppearanceFailure.restore,
    );
    onRead = null;
    saved = 'dark';
    await providers.read(appearanceControllerProvider.notifier).retry();
    await tester.pumpAndSettle();
    expect(providers.read(appearanceControllerProvider).mode, ThemeMode.dark);
    expect(providers.read(appearanceControllerProvider).failure, isNull);
    expect(reads, 3);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'stalled preload is bounded and its late result cannot reset a choice',
    (tester) async {
      final pending = Completer<String?>();
      onRead = () => reads == 1 ? pending.future : Future.value('dark');
      await tester.pumpWidget(const SizedBox());
      final startup = app.main();
      await tester.pump();
      expect(find.byType(app.MyApp), findsNothing);
      await tester.pump(const Duration(seconds: 2));
      await startup;
      await tester.pumpAndSettle();
      expect(reads, 2);
      final providers = container(tester);
      expect(providers.read(appearanceControllerProvider).mode, ThemeMode.dark);
      await providers
          .read(appearanceControllerProvider.notifier)
          .setMode(ThemeMode.light);
      pending.complete('dark');
      await tester.pumpAndSettle();
      expect(
        providers.read(appearanceControllerProvider).mode,
        ThemeMode.light,
      );
      expect(saved, 'light');
      await tester.pumpWidget(const SizedBox());
    },
  );
}
