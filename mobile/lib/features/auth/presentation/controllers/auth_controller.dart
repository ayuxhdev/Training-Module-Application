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
  Future<void> _sessionWork = Future.value();

  bool _isCurrent(int revision) => ref.mounted && revision == _sessionRevision;

  Future<void> _changeSession(Future<void> Function(int) operation) {
    final revision = ++_sessionRevision;
    state = AuthLoading();
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
      final hasTokens = await _repository.hasStoredCredentials();
      if (!_isCurrent(revision)) return;
      if (!hasTokens) {
        state = AuthUnauthenticated();
        return;
      }
      final employee = await _repository.getCurrentEmployee();
      if (_isCurrent(revision)) state = AuthAuthenticated(employee);
    } catch (e) {
      if (!_isCurrent(revision)) return;
      if (e is ApiError && e.statusCode == 401) {
        await logout();
      } else {
        state = AuthError(e is ApiError ? e : ApiError.unexpected());
      }
    }
  }

  Future<void> retryAuthentication() async {
    await _checkAuthentication();
  }

  Future<void> login(String employeeCode, String password) async {
    final repository = _repository;
    await _changeSession((revision) async {
      try {
        final employee = await repository.login(employeeCode, password);
        if (_isCurrent(revision)) state = AuthAuthenticated(employee);
      } catch (e) {
        if (!_isCurrent(revision)) return;
        state = AuthError(e is ApiError ? e : ApiError.unexpected());
        Future.delayed(const Duration(milliseconds: 100), () {
          if (_isCurrent(revision)) state = AuthUnauthenticated();
        });
      }
    });
  }

  Future<void> logout() async {
    final repository = _repository;
    await _changeSession((revision) async {
      try {
        await repository.logout();
      } catch (_) {
        // Local cleanup must proceed even when remote logout fails.
      } finally {
        await repository.tokenStorage.clearAuthenticationState();
        if (_isCurrent(revision)) state = AuthUnauthenticated();
      }
    });
  }

  Future<void> refreshProfile() async {
    if (state is! AuthAuthenticated) return;
    final sessionRevision = _sessionRevision;
    final profileRevision = ++_profileRevision;
    try {
      final employee = await _repository.getCurrentEmployee();
      if (_isCurrent(sessionRevision) && profileRevision == _profileRevision) {
        state = AuthAuthenticated(employee);
      }
    } catch (e) {
      if (!_isCurrent(sessionRevision) || profileRevision != _profileRevision) {
        return;
      }
      final error = e is ApiError ? e : ApiError.unexpected();
      if (error.statusCode == 401 || error.statusCode == 403) await logout();
      throw error;
    }
  }
}
