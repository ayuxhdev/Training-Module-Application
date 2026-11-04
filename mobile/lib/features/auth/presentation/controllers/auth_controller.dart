import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/features/auth/data/repositories/auth_repository.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';

final authControllerProvider = NotifierProvider<AuthController, AuthState>(() {
  return AuthController();
});

class AuthController extends Notifier<AuthState> {
  AuthRepository get _repository => ref.read(authRepositoryProvider);
  int _sessionRevision = 0;
  int _profileRevision = 0;
  // Failed credential deletion must not allow retry to restore the old session.
  bool _requiresLogin = false;
  Future<void> _sessionWork = Future.value();
  Object? _lessonDraftOwner;
  String? _lessonDraftPath;

  void registerLessonDraft(Object owner, String path) {
    if (state is! AuthAuthenticated || _requiresLogin) return;
    _lessonDraftOwner = owner;
    _lessonDraftPath = path;
  }

  void unregisterLessonDraft(Object owner) {
    if (!identical(_lessonDraftOwner, owner)) return;
    _discardLessonDraft();
    final expired = state;
    if (expired is! AuthUnauthenticated || expired.expiredIdentity == null) {
      return;
    }
    final revision = _sessionRevision;
    // Forms release ownership during disposal. Notify the router after that
    // lifecycle phase, without replacing a newer session or another draft.
    scheduleMicrotask(() {
      if (!_isCurrent(revision) ||
          !identical(state, expired) ||
          _lessonDraftOwner != null) {
        return;
      }
      state = AuthUnauthenticated();
    });
  }

  void _discardLessonDraft() {
    _lessonDraftOwner = null;
    _lessonDraftPath = null;
  }

  bool canRecoverLessonDraft(String path, {Object? owner}) {
    final current = state;
    return current is AuthUnauthenticated &&
        current.expiredIdentity != null &&
        _lessonDraftOwner != null &&
        _lessonDraftPath == path &&
        (owner == null || identical(_lessonDraftOwner, owner));
  }

  bool _isCurrent(int revision) => ref.mounted && revision == _sessionRevision;

  Future<void> _changeSession(
    Future<void> Function(int) operation, {
    AuthState? pendingState,
  }) {
    final revision = ++_sessionRevision;
    state = pendingState ?? AuthLoading();
    // Credential writes and cleanup must finish before the next login/logout.
    final work = _sessionWork.then((_) => operation(revision));
    _sessionWork = work.catchError((Object _) {});
    return work;
  }

  @override
  AuthState build() {
    _checkAuthentication();
    return AuthInitial();
  }

  Future<void> _checkAuthentication() async {
    final revision = ++_sessionRevision;
    state = AuthLoading();
    try {
      if (_requiresLogin) {
        state = AuthUnauthenticated();
        return;
      }
      final hasTokens = await _repository.hasStoredCredentials();
      if (!_isCurrent(revision)) return;
      if (!hasTokens) {
        state = AuthUnauthenticated();
        return;
      }
      final identity = await _repository.getCurrentIdentity();
      if (_isCurrent(revision)) state = AuthAuthenticated.identity(identity);
    } catch (e) {
      if (!_isCurrent(revision)) return;
      if (e is ApiError && (e.statusCode == 401 || e.statusCode == 403)) {
        await logout();
      } else {
        state = AuthError(e is ApiError ? e : ApiError.unexpected());
      }
    }
  }

  Future<void> retryAuthentication() async {
    await _checkAuthentication();
  }

  Future<void> login(String username, String password) async {
    _discardLessonDraft();
    final repository = _repository;
    await _changeSession((revision) async {
      try {
        final identity = await repository.login(username, password);
        if (_isCurrent(revision)) {
          _requiresLogin = false;
          state = AuthAuthenticated.identity(identity);
        }
      } catch (e) {
        if (!_isCurrent(revision)) return;
        state = AuthError(e is ApiError ? e : ApiError.unexpected());
        Future.delayed(const Duration(milliseconds: 100), () {
          if (_isCurrent(revision)) state = AuthUnauthenticated();
        });
      }
    });
  }

  /// Keep the authenticated route mounted so its unsaved draft survives.
  Future<void> reauthenticate(String password) async {
    final previous = state;
    final previousIdentity = previous is AuthAuthenticated
        ? previous.identity
        : previous is AuthUnauthenticated
        ? previous.expiredIdentity
        : null;
    if (previousIdentity == null) {
      throw ApiError(message: 'Open sign in to continue.', statusCode: 401);
    }
    final revision = ++_sessionRevision;
    final repository = _repository;
    final work = _sessionWork.then((_) async {
      final identity = await repository.login(
        previousIdentity.username,
        password,
      );
      if (!_isCurrent(revision)) {
        throw ApiError(
          message: 'Your account changed. Reopen the form to continue.',
          statusCode: 401,
        );
      }
      if (identity.userId != previousIdentity.userId ||
          identity.username != previousIdentity.username) {
        _requiresLogin = true;
        await repository.logout();
        if (_isCurrent(revision)) state = AuthUnauthenticated();
        throw ApiError(
          message: 'Sign in with the original account to keep editing.',
          statusCode: 401,
        );
      }
      _requiresLogin = false;
      state = AuthAuthenticated.identity(identity);
    });
    _sessionWork = work.catchError((Object _) {});
    await work;
  }

  Future<void> logout() => _endSession();

  Future<void> _endSession({bool expired = false}) async {
    final previous = state;
    final expiredIdentity = expired && previous is AuthAuthenticated
        ? previous.identity
        : null;
    if (!expired) _discardLessonDraft();
    final ended = AuthUnauthenticated(expiredIdentity: expiredIdentity);
    final repository = _repository;
    _requiresLogin = true;
    await _changeSession((revision) async {
      try {
        await repository.logout();
      } catch (_) {
        // Local cleanup must proceed even when remote logout fails.
      } finally {
        try {
          await repository.tokenStorage.clearAuthenticationState();
          if (_isCurrent(revision)) {
            // Disposal may have released the draft while cleanup was pending.
            state = expired && _lessonDraftOwner == null
                ? AuthUnauthenticated()
                : ended;
          }
        } catch (_) {
          if (_isCurrent(revision)) {
            state = AuthError(
              ApiError(
                message: 'Unable to clear saved credentials. Sign in again to continue.',
                code: 'credential_cleanup_failed',
              ),
            );
          }
        }
      }
    }, pendingState: expired ? ended : null);
  }

  Future<void> refreshProfile() async {
    if (state is! AuthAuthenticated) return;
    final sessionRevision = _sessionRevision;
    final profileRevision = ++_profileRevision;
    try {
      final identity = await _repository.getCurrentIdentity();
      if (_isCurrent(sessionRevision) && profileRevision == _profileRevision) {
        state = AuthAuthenticated.identity(identity);
      }
    } catch (e) {
      if (!_isCurrent(sessionRevision) || profileRevision != _profileRevision) {
        return;
      }
      final error = e is ApiError ? e : ApiError.unexpected();
      if (error.statusCode == 401) {
        await _endSession(expired: true);
      } else if (error.statusCode == 403) {
        await logout();
      }
      throw error;
    }
  }
}
