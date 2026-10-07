import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/features/auth/data/repositories/auth_repository.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';

final authControllerProvider = NotifierProvider<AuthController, AuthState>(() {
  return AuthController();
});

class AuthController extends Notifier<AuthState> {
  AuthRepository get _repository => ref.read(authRepositoryProvider);

  @override
  AuthState build() {
    _checkAuthentication();
    return AuthInitial();
  }

  Future<void> _checkAuthentication() async {
    state = AuthLoading();
    final hasTokens = await _repository.hasStoredCredentials();
    if (!hasTokens) {
      state = AuthUnauthenticated();
      return;
    }

    try {
      final employee = await _repository.getCurrentEmployee();
      state = AuthAuthenticated(employee);
    } catch (e) {
      if (e is ApiError && e.statusCode == 401) {
        try {
          await _repository.logout();
        } catch (_) {
          // Ignore API failure during logout; local cleanup must proceed
        } finally {
          await _repository.tokenStorage.clearAuthenticationState();
          state = AuthUnauthenticated();
        }
      } else {
        state = AuthError(e is ApiError ? e : ApiError.unexpected());
      }
    }
  }

  Future<void> retryAuthentication() async {
    await _checkAuthentication();
  }

  Future<void> login(String employeeCode, String password) async {
    state = AuthLoading();
    try {
      final employee = await _repository.login(employeeCode, password);
      state = AuthAuthenticated(employee);
    } on ApiError catch (e) {
      state = AuthError(e);
      Future.delayed(const Duration(milliseconds: 100), () {
        state = AuthUnauthenticated();
      });
    } catch (e) {
      state = AuthError(ApiError.unexpected());
      Future.delayed(const Duration(milliseconds: 100), () {
        state = AuthUnauthenticated();
      });
    }
  }

  Future<void> logout() async {
    state = AuthLoading();
    try {
      await _repository.logout();
    } catch (_) {
      // Ignore API failure during logout; local cleanup must proceed
    } finally {
      await _repository.tokenStorage.clearAuthenticationState();
      state = AuthUnauthenticated();
    }
  }
}
