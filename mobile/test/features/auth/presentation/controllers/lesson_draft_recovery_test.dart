import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/storage/secure_token_storage.dart';
import 'package:training_app/features/auth/data/repositories/auth_repository.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/authenticated_identity.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';

class _Repository extends Mock implements AuthRepository {}

class _Storage extends Mock implements SecureTokenStorage {}

const _path = '/workspace/training/versions/20/modules/51/lessons/new';

final _identity = AuthenticatedIdentity.fromJson({
  'user': {'id': 1, 'username': 'author', 'display_name': 'Author'},
  'employee': null,
  'capabilities': ['management_workspace', 'training.add_lesson'],
});

class _Fixture {
  final repository = _Repository();
  final storage = _Storage();
  final owner = Object();
  late final ProviderContainer container;
  bool _disposed = false;

  _Fixture() {
    when(() => repository.tokenStorage).thenReturn(storage);
    when(() => repository.hasStoredCredentials()).thenAnswer((_) async => true);
    when(() => repository.getCurrentIdentity())
        .thenAnswer((_) async => _identity);
    when(() => repository.logout()).thenAnswer((_) async {});
    when(() => storage.clearAuthenticationState()).thenAnswer((_) async {});
    when(() => repository.login('author', 'password'))
        .thenAnswer((_) async => _identity);
    container = ProviderContainer(
      overrides: [authRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(dispose);
  }

  AuthController get controller =>
      container.read(authControllerProvider.notifier);
  AuthState get state => container.read(authControllerProvider);

  Future<void> start() async {
    container.read(authControllerProvider);
    await Future<void>.delayed(Duration.zero);
    expect(state, isA<AuthAuthenticated>());
    controller.registerLessonDraft(owner, _path);
  }

  Future<void> expire() async {
    when(() => repository.getCurrentIdentity())
        .thenThrow(ApiError(message: 'Expired', statusCode: 401));
    await expectLater(controller.refreshProfile(), throwsA(isA<ApiError>()));
    expect(controller.canRecoverLessonDraft(_path), isTrue);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    container.dispose();
  }
}

void main() {
  test(
    'final release defers the auth notification until after disposal',
    () async {
      final fixture = _Fixture();
      await fixture.start();
      await fixture.expire();
      final expired = fixture.state;
      final changes = <AuthState>[];
      fixture.container.listen(
        authControllerProvider,
        (_, next) => changes.add(next),
      );

      fixture.controller.unregisterLessonDraft(fixture.owner);
      expect(fixture.controller.canRecoverLessonDraft(_path), isFalse);
      expect(fixture.state, same(expired));
      expect(changes, isEmpty);
      await Future<void>.delayed(Duration.zero);

      expect((fixture.state as AuthUnauthenticated).expiredIdentity, isNull);
      expect(changes, hasLength(1));
      fixture.controller.unregisterLessonDraft(fixture.owner);
      await Future<void>.delayed(Duration.zero);
      expect(changes, hasLength(1));
    },
  );

  test('an old form cannot release another active draft owner', () async {
    final fixture = _Fixture();
    await fixture.start();
    final otherOwner = Object();
    const otherPath =
        '/workspace/training/versions/20/modules/51/video-lessons/new';
    fixture.controller.registerLessonDraft(otherOwner, otherPath);
    when(() => fixture.repository.getCurrentIdentity())
        .thenThrow(ApiError(message: 'Expired', statusCode: 401));
    await expectLater(
      fixture.controller.refreshProfile(),
      throwsA(isA<ApiError>()),
    );
    final expired = fixture.state;

    fixture.controller.unregisterLessonDraft(fixture.owner);
    await Future<void>.delayed(Duration.zero);
    expect(fixture.state, same(expired));
    expect(
      fixture.controller.canRecoverLessonDraft(otherPath, owner: otherOwner),
      isTrue,
    );

    fixture.controller.unregisterLessonDraft(otherOwner);
    await Future<void>.delayed(Duration.zero);
    expect((fixture.state as AuthUnauthenticated).expiredIdentity, isNull);
  });

  test('deferred release cannot clear a newer sign-in or its draft', () async {
    final fixture = _Fixture();
    await fixture.start();
    await fixture.expire();
    final pending = Completer<AuthenticatedIdentity>();
    when(() => fixture.repository.login('author', 'password'))
        .thenAnswer((_) => pending.future);
    final expired = fixture.state;

    fixture.controller.unregisterLessonDraft(fixture.owner);
    final recovery = fixture.controller.reauthenticate('password');
    await Future<void>.delayed(Duration.zero);
    expect(fixture.state, same(expired));
    pending.complete(_identity);
    await recovery;
    expect((fixture.state as AuthAuthenticated).identity, same(_identity));
    verify(() => fixture.repository.login('author', 'password')).called(1);
    final otherOwner = Object();
    fixture.controller.registerLessonDraft(otherOwner, _path);
    fixture.controller.unregisterLessonDraft(fixture.owner);
    await Future<void>.delayed(Duration.zero);
    expect(fixture.state, isA<AuthAuthenticated>());
    await fixture.expire();
    expect(
      fixture.controller.canRecoverLessonDraft(_path, owner: otherOwner),
      isTrue,
    );
  });

  test(
    'deferred release cannot overwrite explicit logout or account switching',
    () async {
      for (final switching in [false, true]) {
        final fixture = _Fixture();
        await fixture.start();
        await fixture.expire();
        fixture.controller.unregisterLessonDraft(fixture.owner);
        final secondIdentity = AuthenticatedIdentity(
          userId: 2,
          username: 'second-author',
          displayName: 'Second Author',
          capabilities: _identity.capabilities,
        );
        if (switching) {
          when(() => fixture.repository.login('second-author', 'password'))
              .thenAnswer((_) async => secondIdentity);
          await fixture.controller.login('second-author', 'password');
          expect(
            (fixture.state as AuthAuthenticated).identity,
            same(secondIdentity),
          );
          verify(() => fixture.repository.login('second-author', 'password'))
              .called(1);
          verifyNever(() => fixture.repository.login('author', 'password'));
        } else {
          await fixture.controller.logout();
          expect(
            (fixture.state as AuthUnauthenticated).expiredIdentity,
            isNull,
          );
        }
        await Future<void>.delayed(Duration.zero);
        expect(
          fixture.state,
          switching ? isA<AuthAuthenticated>() : isA<AuthUnauthenticated>(),
        );
        expect(
          fixture.controller.canRecoverLessonDraft(_path, owner: fixture.owner),
          isFalse,
        );
        if (switching) {
          expect(
            (fixture.state as AuthAuthenticated).identity,
            same(secondIdentity),
          );
          // Even a later expiry cannot restore the original author's draft.
          await expectLater(
            fixture.controller.refreshProfile(),
            throwsA(isA<ApiError>()),
          );
          expect(
            (fixture.state as AuthUnauthenticated).expiredIdentity,
            isNull,
          );
          expect(fixture.controller.canRecoverLessonDraft(_path), isFalse);
        }
        fixture.dispose();
      }
    },
  );

  test(
    'provider disposal before the microtask does not access disposed state',
    () async {
      final fixture = _Fixture();
      await fixture.start();
      await fixture.expire();
      fixture.controller.unregisterLessonDraft(fixture.owner);
      fixture.dispose();
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'late expiry cleanup cannot resurrect a released recovery identity',
    () async {
      final fixture = _Fixture();
      await fixture.start();
      final cleanupStarted = Completer<void>();
      final releaseCleanup = Completer<void>();
      when(() => fixture.repository.logout()).thenAnswer((_) {
        cleanupStarted.complete();
        return releaseCleanup.future;
      });
      when(() => fixture.repository.getCurrentIdentity())
          .thenThrow(ApiError(message: 'Expired', statusCode: 401));
      final expiry = expectLater(
        fixture.controller.refreshProfile(),
        throwsA(isA<ApiError>()),
      );
      await cleanupStarted.future;
      expect(fixture.controller.canRecoverLessonDraft(_path), isTrue);

      fixture.controller.unregisterLessonDraft(fixture.owner);
      await Future<void>.delayed(Duration.zero);
      expect((fixture.state as AuthUnauthenticated).expiredIdentity, isNull);
      releaseCleanup.complete();
      await expiry;
      expect((fixture.state as AuthUnauthenticated).expiredIdentity, isNull);
      verify(() => fixture.storage.clearAuthenticationState()).called(1);
    },
  );

  test(
    'late credential cleanup failure remains fail-closed after draft release',
    () async {
      final fixture = _Fixture();
      await fixture.start();
      final cleanupStarted = Completer<void>();
      final releaseCleanup = Completer<void>();
      when(() => fixture.repository.logout()).thenAnswer((_) {
        cleanupStarted.complete();
        return releaseCleanup.future;
      });
      when(() => fixture.repository.getCurrentIdentity())
          .thenThrow(ApiError(message: 'Expired', statusCode: 401));
      when(() => fixture.storage.clearAuthenticationState())
          .thenThrow(StateError('Storage unavailable'));
      final expiry = expectLater(
        fixture.controller.refreshProfile(),
        throwsA(isA<ApiError>()),
      );
      await cleanupStarted.future;
      fixture.controller.unregisterLessonDraft(fixture.owner);
      await Future<void>.delayed(Duration.zero);
      releaseCleanup.complete();
      await expiry;
      expect(
        (fixture.state as AuthError).error.code,
        'credential_cleanup_failed',
      );
    },
  );
}
