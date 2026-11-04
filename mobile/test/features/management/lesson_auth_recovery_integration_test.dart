import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/network/auth_session.dart';
import 'package:training_app/core/network/dio_client.dart';
import 'package:training_app/core/providers/core_providers.dart';
import 'package:training_app/core/router/app_router.dart';
import 'package:training_app/core/theme/app_theme.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/data/services/video_file_picker.dart';
import 'package:training_app/features/notifications/presentation/controllers/notification_controller.dart';

import '../../core/network/automatic_auth_test.dart' as http;
import 'management_fixtures.dart';

class _ZeroUnread extends NotificationUnreadController {
  @override
  Future<int?> build() async => 0;
}

class _Picker implements VideoFilePicker {
  final SelectedVideoFile file;
  _Picker(this.file);
  @override
  Future<SelectedVideoFile?> pickVideo() async => file;
  @override
  Future<void> clearCache() async {}
}

// Production client, repositories, controller, router and forms; fake HTTP and SAF.
class _Journey {
  final bool video;
  final storage = http.MemoryTokens();
  final refreshStarted = Completer<void>();
  final releaseRefresh = Completer<void>();
  late final Directory directory;
  late final File temporaryFile;
  late final ApiClient client;
  late final ProviderContainer container;
  late final GoRouter router;
  final requests = <String>[];
  bool _disposed = false;
  int refreshes = 0;
  int submissions = 0;
  int userId = 1;
  String username = 'author';
  bool rejectPassword = false;
  _Journey(this.video, {bool authenticated = true}) {
    directory = Directory.systemTemp.createTempSync('lesson-auth-');
    temporaryFile = File('${directory.path}/draft.mp4')
      ..writeAsBytesSync([1, 2, 3]);
    storage.access = http.jwt(DateTime.now().add(const Duration(minutes: 30)));
    storage.refresh = 'parent';
    if (!authenticated) {
      storage.access = null;
      storage.refresh = null;
    }
    client = http.clientFor(storage, (options) async {
      requests.add('${options.method} ${options.path}');
      if (options.path == '/auth/refresh/') {
        refreshes++;
        if (!refreshStarted.isCompleted) refreshStarted.complete();
        await releaseRefresh.future;
        return http.reply({
          'detail': 'Token is blacklisted',
          'code': 'token_not_valid',
        }, 401);
      }
      if (options.path == '/auth/login/') {
        if (rejectPassword) {
          return http.reply({'detail': 'Check your password.'}, 401);
        }
        username = (options.data as Map)['username'] as String;
        userId = username == 'author' ? 1 : 2;
        return http.reply({
          'access': http.jwt(
            DateTime.now().add(const Duration(minutes: 30)),
            user: userId,
          ),
          'refresh': 'new-parent',
        });
      }
      if (options.path == '/auth/logout/') return http.reply({}, 204);
      if (options.path == '/auth/me/') {
        return http.reply({
          'user': {
            'id': userId,
            'username': username,
            'display_name': username,
          },
          'employee': null,
          'capabilities': [
            'management_workspace',
            'training.view_trainingversion',
            'training.view_module',
            'training.view_lesson',
            'training.add_lesson',
            'training.change_lesson',
          ],
        });
      }
      if (options.method == 'POST' && options.path.contains('-lessons/')) {
        submissions++;
        return http.reply(
          video
              ? managedVideoLessonDetailJson()
              : managedTextLessonDetailJson(),
          201,
        );
      }
      fail('Unexpected request: ${options.method} ${options.path}');
    });
    container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(client),
        secureTokenStorageProvider.overrideWithValue(storage),
        notificationUnreadCountProvider.overrideWith(_ZeroUnread.new),
        videoFilePickerProvider.overrideWithValue(
          _Picker(
            SelectedVideoFile(
              path: temporaryFile.path,
              name: 'draft.mp4',
              sizeInBytes: 3,
              multipartFileFactory: () =>
                  MultipartFile.fromBytes([1, 2, 3], filename: 'draft.mp4'),
            ),
          ),
        ),
      ],
    );
    router = container.read(appRouterProvider);
    addTearDown(_clean);
  }
  String get path =>
      '/workspace/training/versions/20/modules/51/${video ? 'video-lessons' : 'lessons'}/new';
  Finder get save => find.widgetWithText(
    FilledButton,
    video ? 'Create Video Lesson' : 'Create Lesson',
  );
  Finder get title => find.widgetWithText(TextFormField, 'Lesson Title *');
  Finder get body =>
      find.widgetWithText(TextFormField, 'Lesson Body (plain text) *');
  AuthController get auth => container.read(authControllerProvider.notifier);
  Future<void> launch(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          theme: AppTheme.lightTheme,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(container.read(authControllerProvider), isA<AuthAuthenticated>());
    unawaited(router.push<void>(path));
    await tester.pumpAndSettle();
    await tester.enterText(title, 'Private unfinished lesson');
    if (video) {
      await tester.tap(find.text('Choose Video File'));
      await tester.pumpAndSettle();
    } else {
      await tester.enterText(body, '  Keep indentation\n\n');
    }
  }

  Future<void> expire(WidgetTester tester, {required bool withProfile}) async {
    storage.access = http.jwt(
      DateTime.now().subtract(const Duration(seconds: 1)),
    );
    await tester.tap(save);
    for (var i = 0; i < 20 && !refreshStarted.isCompleted; i++) {
      await tester.pump(Duration.zero);
    }
    expect(refreshStarted.isCompleted, isTrue, reason: 'Requests: $requests');
    Future<void>? profile;
    if (withProfile) {
      profile = expectLater(auth.refreshProfile(), throwsA(isA<ApiError>()));
      await tester.pump(Duration.zero);
    }
    releaseRefresh.complete();
    await tester.pumpAndSettle();
    if (profile != null) await profile;
    expect(refreshes, 1);
    expect(submissions, 0);
    expect(storage.access, isNull);
    expect(storage.refresh, isNull);
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    _clean();
  }

  void _clean() {
    if (_disposed) return;
    _disposed = true;
    if (!releaseRefresh.isCompleted) releaseRefresh.complete();
    container.dispose();
    client.dio.close(force: true);
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  }
}

void main() {
  test('session expiry wording is neutral outside lesson forms', () {
    expect(
      AuthSession.signInRequired().message,
      'Your session has ended. Sign in again to continue.',
    );
  });

  testWidgets(
    'cold start without credentials redirects to login with no draft recovery',
    (tester) async {
      final journey = _Journey(false, authenticated: false);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: journey.container,
          child: MaterialApp.router(
            routerConfig: journey.router,
            theme: AppTheme.lightTheme,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        journey.container.read(authControllerProvider),
        isA<AuthUnauthenticated>(),
      );
      expect(journey.router.state.matchedLocation, '/login');
      expect(journey.auth.canRecoverLessonDraft(journey.path), isFalse);
      expect(journey.requests, isEmpty);
      expect(tester.takeException(), isNull);
      await journey.dispose(tester);
    },
  );

  for (final video in [false, true]) {
    final kind = video ? 'VIDEO' : 'TEXT';
    testWidgets(
      '$kind real renewal rejection keeps recovery visible after editing',
      (tester) async {
        final journey = _Journey(video);
        await journey.launch(tester);
        await journey.expire(tester, withProfile: false);
        expect(
          journey.container.read(authControllerProvider),
          isA<AuthAuthenticated>(),
        );
        expect(find.text('Sign in again'), findsOneWidget);
        await tester.enterText(journey.title, 'Still editing');
        await tester.pump();
        expect(find.text('Sign in again'), findsOneWidget);
        await tester.enterText(journey.title, '');
        await tester.tap(journey.save);
        await tester.pumpAndSettle();
        expect(find.text('Sign in again'), findsOneWidget);
        if (video) {
          expect(journey.temporaryFile.existsSync(), isTrue);
        } else {
          expect(
            tester.widget<TextFormField>(journey.body).controller!.text,
            '  Keep indentation\n\n',
          );
        }
        await journey.dispose(tester);
      },
    );
    testWidgets(
      '$kind real renewal and profile failure preserve an unauthenticated draft through sign-in',
      (tester) async {
        final journey = _Journey(video);
        await journey.launch(tester);
        await journey.expire(tester, withProfile: true);
        expect(
          journey.container.read(authControllerProvider),
          isA<AuthUnauthenticated>(),
        );
        final expired = journey.container.read(
          authControllerProvider,
        ) as AuthUnauthenticated;
        expect(expired.expiredIdentity?.username, 'author');
        expect(
          journey.auth.canRecoverLessonDraft(journey.path),
          isTrue,
          reason:
              'Current route: ${journey.router.routeInformationProvider.value.uri.path}',
        );
        expect(find.text('Private unfinished lesson'), findsOneWidget);
        expect(find.text('Sign in again'), findsOneWidget);
        expect(journey.router.state.matchedLocation, journey.path);
        await tester.enterText(journey.title, 'Still private');
        await tester.pump();
        expect(find.text('Sign in again'), findsOneWidget);
        await tester.tap(journey.save);
        await tester.pumpAndSettle();
        expect(journey.submissions, 0);
        await tester.tap(find.text('Sign in again'));
        await tester.pumpAndSettle();
        expect(find.text('Account: author'), findsOneWidget);
        journey.rejectPassword = true;
        await tester.enterText(
          find.widgetWithText(TextField, 'Password'),
          'test-only-password',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
        await tester.pumpAndSettle();
        expect(find.text('Check your password.'), findsOneWidget);
        expect(
          journey.container.read(authControllerProvider),
          isA<AuthUnauthenticated>(),
        );
        journey.rejectPassword = false;
        await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
        await tester.pumpAndSettle();
        expect(
          journey.container.read(authControllerProvider),
          isA<AuthAuthenticated>(),
        );
        expect(find.text('Still private'), findsOneWidget);
        if (video) {
          expect(find.text('draft.mp4'), findsOneWidget);
          expect(journey.temporaryFile.existsSync(), isTrue);
        } else {
          expect(
            tester.widget<TextFormField>(journey.body).controller!.text,
            '  Keep indentation\n\n',
          );
        }
        expect(journey.submissions, 0); // Sign-in must not replay a mutation.
        await tester.tap(journey.save);
        await tester.pumpAndSettle();
        expect(journey.submissions, 1);
        expect(tester.takeException(), isNull);
        await journey.dispose(tester);
      },
    );

    for (final systemBack in [false, true]) {
      testWidgets(
        '$kind expired draft ${systemBack ? 'system Back' : 'Cancel'}/Discard reaches login',
        (tester) async {
          final journey = _Journey(video);
          await journey.launch(tester);
          await journey.expire(tester, withProfile: true);
          final requestsBeforeLeaving = List.of(journey.requests);
          expect(journey.auth.canRecoverLessonDraft(journey.path), isTrue);
          if (systemBack) {
            await tester.binding.handlePopRoute();
          } else {
            await tester.ensureVisible(find.text('Cancel'));
            await tester.tap(find.text('Cancel'));
          }
          await tester.pumpAndSettle();
          expect(find.text('Discard unsaved changes?'), findsOneWidget);
          await tester.tap(find.widgetWithText(FilledButton, 'Discard'));
          await tester.pumpAndSettle();
          expect(journey.router.state.matchedLocation, '/login');
          expect(
            find.widgetWithText(TextFormField, 'Username'),
            findsOneWidget,
          );
          expect(find.widgetWithText(ElevatedButton, 'Login'), findsOneWidget);
          expect(find.text('Private unfinished lesson'), findsNothing);
          final ended = journey.container.read(
            authControllerProvider,
          ) as AuthUnauthenticated;
          expect(ended.expiredIdentity, isNull);
          expect(journey.auth.canRecoverLessonDraft(journey.path), isFalse);
          if (video) expect(journey.temporaryFile.existsSync(), isFalse);
          expect(journey.submissions, 0);
          expect(journey.requests, requestsBeforeLeaving);
          expect(tester.takeException(), isNull);
          await journey.dispose(tester);
        },
      );
    }

    testWidgets(
      '$kind expired draft cannot authorize another route or be reopened after leaving',
      (tester) async {
        final journey = _Journey(video);
        await journey.launch(tester);
        await journey.expire(tester, withProfile: true);
        expect(journey.auth.canRecoverLessonDraft(journey.path), isTrue);
        final requestsBeforeNavigation = List.of(journey.requests);
        journey.router.go(
          '/workspace/training/versions/99/modules/51/lessons/new',
        );
        await tester.pumpAndSettle();
        expect(journey.router.state.matchedLocation, '/login');
        expect(journey.auth.canRecoverLessonDraft(journey.path), isFalse);
        expect(find.text('Private unfinished lesson'), findsNothing);
        if (video) expect(journey.temporaryFile.existsSync(), isFalse);
        journey.router.go(journey.path);
        await tester.pumpAndSettle();
        expect(journey.router.state.matchedLocation, '/login');
        expect(journey.requests, requestsBeforeNavigation);
        await journey.dispose(tester);
      },
    );

    for (final switchAccount in [false, true]) {
      testWidgets(
        '$kind explicit ${switchAccount ? 'account switch' : 'logout'} discards expired draft',
        (tester) async {
          final journey = _Journey(video);
          await journey.launch(tester);
          await journey.expire(tester, withProfile: true);
          final change = switchAccount
              ? journey.auth.login('other', 'test-only-password')
              : journey.auth.logout();
          await tester.pumpAndSettle();
          await change;
          expect(find.text('Private unfinished lesson'), findsNothing);
          expect(find.text('draft.mp4'), findsNothing);
          if (video) expect(journey.temporaryFile.existsSync(), isFalse);
          expect(journey.submissions, 0);
          if (!switchAccount) {
            journey.router.go(journey.path);
            await tester.pumpAndSettle();
            expect(
              journey.router.routeInformationProvider.value.uri.path,
              '/login',
            );
          }
          expect(tester.takeException(), isNull);
          await journey.dispose(tester);
        },
      );
    }
  }
}
