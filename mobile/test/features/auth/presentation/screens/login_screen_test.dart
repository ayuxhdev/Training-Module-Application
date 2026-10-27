import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/theme/app_theme.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/auth/presentation/screens/login_screen.dart';

class _LoginTestAuth extends AuthController {
  final submissions = <(String, String)>[];

  @override
  AuthState build() => AuthUnauthenticated();

  @override
  Future<void> login(String username, String password) async {
    submissions.add((username, password));
  }

  void emit(AuthState next) => state = next;
}

void main() {
  late _LoginTestAuth auth;

  Future<void> pumpLogin(
    WidgetTester tester, {
    ThemeMode themeMode = ThemeMode.light,
  }) async {
    auth = _LoginTestAuth();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [authControllerProvider.overrideWith(() => auth)],
        child: MaterialApp(
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: themeMode,
          home: const LoginScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  final passwordField = find.byType(TextFormField).last;

  testWidgets('password starts hidden and toggles accessibly without changes', (
    tester,
  ) async {
    await pumpLogin(tester);
    final semantics = tester.ensureSemantics();

    final editableText = find.descendant(
      of: passwordField,
      matching: find.byType(EditableText),
    );
    expect(tester.widget<EditableText>(editableText).obscureText, isTrue);
    expect(find.byTooltip('Show password'), findsOneWidget);

    await tester.enterText(passwordField, 'secret-value');
    final controller = tester.widget<TextFormField>(passwordField).controller!;
    controller.selection = const TextSelection.collapsed(offset: 4);
    final focusNode = tester.widget<EditableText>(editableText).focusNode;
    expect(focusNode.hasFocus, isTrue);

    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();

    expect(tester.widget<EditableText>(editableText).obscureText, isFalse);
    expect(find.byTooltip('Hide password'), findsOneWidget);
    expect(find.bySemanticsLabel('Hide password'), findsOneWidget);
    expect(controller.text, 'secret-value');
    expect(controller.selection, const TextSelection.collapsed(offset: 4));
    expect(focusNode.hasFocus, isTrue);

    await tester.tap(find.byTooltip('Hide password'));
    await tester.pump();

    expect(tester.widget<EditableText>(editableText).obscureText, isTrue);
    expect(find.byTooltip('Show password'), findsOneWidget);
    expect(find.bySemanticsLabel('Show password'), findsOneWidget);
    expect(controller.text, 'secret-value');
    expect(controller.selection, const TextSelection.collapsed(offset: 4));
    expect(focusNode.hasFocus, isTrue);
    semantics.dispose();
  });

  testWidgets('validation and authentication submission are preserved', (
    tester,
  ) async {
    await pumpLogin(tester);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Login'));
    await tester.pump();
    expect(find.text('Please enter your username'), findsOneWidget);
    expect(find.text('Please enter your password'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField).first, '  employee-7  ');
    await tester.enterText(passwordField, 'password-7');
    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Login'));
    await tester.pump();

    expect(auth.submissions, [('employee-7', 'password-7')]);
  });

  testWidgets('authentication errors continue to use the login snackbar', (
    tester,
  ) async {
    await pumpLogin(tester);

    auth.emit(
      AuthError(ApiError(message: 'Invalid credentials.', statusCode: 401)),
    );
    await tester.pump();

    expect(find.text('Invalid credentials.'), findsOneWidget);
  });

  testWidgets('login follows light, dark, and system theme brightness', (
    tester,
  ) async {
    for (final scenario in [
      (
        mode: ThemeMode.light,
        platform: Brightness.dark,
        expected: Brightness.light,
      ),
      (
        mode: ThemeMode.dark,
        platform: Brightness.light,
        expected: Brightness.dark,
      ),
      (
        mode: ThemeMode.system,
        platform: Brightness.light,
        expected: Brightness.light,
      ),
      (
        mode: ThemeMode.system,
        platform: Brightness.dark,
        expected: Brightness.dark,
      ),
    ]) {
      tester.platformDispatcher.platformBrightnessTestValue = scenario.platform;
      await pumpLogin(tester, themeMode: scenario.mode);

      expect(
        Theme.of(tester.element(find.byType(LoginScreen))).brightness,
        scenario.expected,
      );
    }

    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
  });
}
