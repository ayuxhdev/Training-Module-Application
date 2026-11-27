import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/core/network/dio_client.dart';
import 'package:training_app/core/providers/core_providers.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/authenticated_identity.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/profile/presentation/screens/password_change_screen.dart';

import '../../core/network/automatic_auth_test.dart' as http;

const _old = 'Prior-test-passphrase!42';
const _new = 'Different-test-passphrase!93';

AuthenticatedIdentity _identity(int id) => AuthenticatedIdentity(
  userId: id,
  username: 'password-user-$id',
  displayName: 'Password test user $id',
  capabilities: {'management_workspace'},
);

class _Auth extends AuthController {
  @override
  AuthState build() => AuthAuthenticated.identity(_identity(1));

  void switchAccount(int id) =>
      state = AuthAuthenticated.identity(_identity(id));
}

class _Fixture {
  final storage = http.MemoryTokens();
  final auth = _Auth();
  late final ApiClient client;
  late final ProviderContainer container;
  final requests = <RequestOptions>[];
  int status = 204;
  Object response = const {};
  Completer<ResponseBody>? pending;
  bool timeout = false;

  _Fixture() {
    storage.access = http.jwt(DateTime.now().add(const Duration(minutes: 30)));
    storage.refresh = 'test-parent';
    client = http.clientFor(storage, (options) async {
      requests.add(options);
      if (options.path == '/auth/refresh/') {
        return http.reply({'detail': 'Token is blacklisted'}, 401);
      }
      if (options.path == '/auth/logout/') {
        // The password change already revoked this access token. Even then,
        // production logout must clear local secure credentials.
        return http.reply({'detail': 'Password changed'}, 401);
      }
      if (options.path == '/auth/password-change/') {
        if (timeout) {
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.receiveTimeout,
          );
        }
        return pending == null ? http.reply(response, status) : pending!.future;
      }
      throw StateError('Unexpected test request path');
    });
    container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWith(() => auth),
        apiClientProvider.overrideWithValue(client),
        secureTokenStorageProvider.overrideWithValue(storage),
      ],
    );
    addTearDown(() {
      container.dispose();
      client.dio.close(force: true);
      final unresolved = pending;
      if (unresolved != null && !unresolved.isCompleted) {
        unresolved.complete(http.reply({}, 499));
      }
    });
  }

  int get changes =>
      requests.where((r) => r.path == '/auth/password-change/').length;

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: PasswordChangeScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> fill(WidgetTester tester, {String confirmation = _new}) async {
    await tester.enterText(
      find.byKey(const ValueKey('current_password')),
      _old,
    );
    await tester.enterText(find.byKey(const ValueKey('new_password')), _new);
    await tester.enterText(
      find.byKey(const ValueKey('confirm_password')),
      confirmation,
    );
  }

  Future<void> waitForChangeRequest(WidgetTester tester) async {
    // Drive fake-async microtasks/frames until the real Dio adapter is reached.
    // This is bounded and never waits on real I/O or an arbitrary wall-clock sleep.
    for (var frame = 0; frame < 10 && changes == 0; frame++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(changes, 1);
  }

  Future<void> submit(WidgetTester tester) async {
    final button = find.widgetWithText(FilledButton, 'Change password');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
  }
}

void main() {
  testWidgets(
    'success uses own-password contract then clears real secure session',
    (tester) async {
      final fixture = _Fixture();
      await fixture.open(tester);
      await fixture.fill(tester);
      await fixture.submit(tester);
      await tester.pumpAndSettle();
      expect(fixture.changes, 1);
      final request = fixture.requests.singleWhere(
        (r) => r.path == '/auth/password-change/',
      );
      expect(request.method, 'POST');
      expect(request.data, {
        'current_password': _old,
        'new_password': _new,
        'confirm_password': _new,
      });
      expect(fixture.storage.access, isNull);
      expect(fixture.storage.refresh, isNull);
      expect(
        fixture.container.read(authControllerProvider),
        isA<AuthUnauthenticated>(),
      );
      expect(
        find.text('Password changed. Sign in again with your new password.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('required fields and mismatched confirmation never submit', (
    tester,
  ) async {
    final fixture = _Fixture();
    await fixture.open(tester);
    await fixture.submit(tester);
    expect(find.text('Current password is required.'), findsOneWidget);
    expect(fixture.changes, 0);
    await fixture.fill(tester, confirmation: 'mismatch');
    await fixture.submit(tester);
    expect(find.text('Passwords do not match.'), findsOneWidget);
    expect(fixture.changes, 0);
  });

  testWidgets('passwords are masked with accessible visibility controls', (
    tester,
  ) async {
    final fixture = _Fixture();
    await fixture.open(tester);
    expect(
      tester
          .widgetList<TextField>(find.byType(TextField))
          .every((field) => field.obscureText),
      isTrue,
    );
    await tester.tap(find.byTooltip('Show Current password'));
    await tester.pump();
    expect(
      tester.widgetList<TextField>(find.byType(TextField)).first.obscureText,
      isFalse,
    );
    expect(find.byTooltip('Hide Current password'), findsOneWidget);
  });

  testWidgets(
    'backend field errors are shown without logging out or leaking values',
    (tester) async {
      final fixture = _Fixture()
        ..status = 400
        ..response = {
          'error': {
            'message': 'Invalid input.',
            'fields': {
              'current_password': ['Current password is incorrect.'],
            },
          },
        };
      await fixture.open(tester);
      await fixture.fill(tester);
      await fixture.submit(tester);
      await tester.pumpAndSettle();
      expect(find.text('Current password is incorrect.'), findsOneWidget);
      expect(
        fixture.container.read(authControllerProvider),
        isA<AuthAuthenticated>(),
      );
      expect(fixture.storage.access, isNotNull);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Text &&
              ((widget.data ?? '').contains(_old) ||
                  (widget.data ?? '').contains(_new)),
        ),
        findsNothing,
      );
      expect(
        tester
            .widgetList<TextField>(find.byType(TextField))
            .every((field) => field.obscureText),
        isTrue,
      );
    },
  );

  testWidgets(
    'failed real refresh prevents POST and leaves a Sign in again action',
    (tester) async {
      final fixture = _Fixture();
      fixture.storage.access = http.jwt(
        DateTime.now().subtract(const Duration(minutes: 1)),
      );
      await fixture.open(tester);
      await fixture.fill(tester);
      await fixture.submit(tester);
      await tester.pumpAndSettle();
      expect(fixture.changes, 0);
      expect(
        find.text('Your session has ended. Sign in again to continue.'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(FilledButton, 'Sign in again'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('current_password')),
            )
            .controller!
            .text,
        isEmpty,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in again'));
      await tester.pumpAndSettle();
      expect(
        fixture.container.read(authControllerProvider),
        isA<AuthUnauthenticated>(),
      );
    },
  );

  testWidgets('401 never automatically replays password-changing POST', (
    tester,
  ) async {
    final fixture = _Fixture()..status = 401;
    await fixture.open(tester);
    await fixture.fill(tester);
    await fixture.submit(tester);
    await tester.pumpAndSettle();
    expect(fixture.changes, 1);
    expect(find.text('Sign in again'), findsOneWidget);
  });

  testWidgets('timeout ends loading and allows an explicit manual retry', (
    tester,
  ) async {
    final fixture = _Fixture()..timeout = true;
    await fixture.open(tester);
    await fixture.fill(tester);
    await fixture.submit(tester);
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(
      find.textContaining('Unable to confirm the password change'),
      findsOneWidget,
    );
    expect(
      fixture.container.read(authControllerProvider),
      isA<AuthAuthenticated>(),
    );
    fixture.timeout = false;
    await fixture.submit(tester);
    await tester.pumpAndSettle();
    expect(fixture.changes, 2);
    expect(fixture.storage.access, isNull);
  });

  testWidgets('loading blocks repeated submissions', (tester) async {
    final pending = Completer<ResponseBody>();
    final fixture = _Fixture()..pending = pending;
    await fixture.open(tester);
    await fixture.fill(tester);
    await fixture.submit(tester);
    await fixture.waitForChangeRequest(tester);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(fixture.changes, 1);
    pending.complete(http.reply({}, 204));
    await tester.pumpAndSettle();
    expect(fixture.changes, 1);
  });

  testWidgets(
    'account switch hides credentials and late response cannot log out new user',
    (tester) async {
      final pending = Completer<ResponseBody>();
      final fixture = _Fixture()..pending = pending;
      await fixture.open(tester);
      await fixture.fill(tester);
      await fixture.submit(tester);
      await fixture.waitForChangeRequest(tester);
      fixture.auth.switchAccount(2);
      await tester.pumpAndSettle();
      expect(find.byType(TextFormField), findsNothing);
      expect(
        find.text('Your account changed. Reopen this screen from Profile.'),
        findsOneWidget,
      );
      pending.complete(http.reply({}, 204));
      await tester.pumpAndSettle();
      expect(
        (fixture.container.read(
          authControllerProvider,
        ) as AuthAuthenticated).identity.userId,
        2,
      );
      expect(fixture.requests.where((r) => r.path == '/auth/logout/'), isEmpty);
    },
  );

  testWidgets(
    'disposal cancels in-flight work without feedback after disposal',
    (tester) async {
      final pending = Completer<ResponseBody>();
      final fixture = _Fixture()..pending = pending;
      await fixture.open(tester);
      await fixture.fill(tester);
      await fixture.submit(tester);
      await fixture.waitForChangeRequest(tester);
      final request = fixture.requests.singleWhere(
        (r) => r.path == '/auth/password-change/',
      );
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      expect(request.cancelToken!.isCancelled, isTrue);
      pending.complete(http.reply({}, 204));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        fixture.container.read(authControllerProvider),
        isA<AuthAuthenticated>(),
      );
    },
  );

  testWidgets('narrow large-text layout remains usable', (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = _Fixture();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: fixture.container,
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: const PasswordChangeScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.widgetWithText(FilledButton, 'Change password'),
    );
    expect(tester.takeException(), isNull);
  });
}
