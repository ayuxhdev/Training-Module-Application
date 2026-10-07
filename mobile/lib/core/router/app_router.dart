import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/auth/presentation/screens/login_screen.dart';
import 'package:training_app/features/dashboard/presentation/screens/dashboard_screen.dart';

// Create a Listenable to trigger router redirects on auth state changes
class RouterNotifier extends ChangeNotifier {
  final Ref _ref;

  RouterNotifier(this._ref) {
    _ref.listen<AuthState>(authControllerProvider, (_, _) {
      notifyListeners();
    });
  }
}

final appRouterProvider = Provider<GoRouter>((ref) {
  final notifier = RouterNotifier(ref);

  return GoRouter(
    initialLocation: '/',
    refreshListenable: notifier,
    redirect: (context, state) {
      final authState = ref.read(authControllerProvider);
      final isLoggingIn = state.matchedLocation == '/login';

      if (authState is AuthInitial || authState is AuthLoading) {
        return null;
      }

      if (authState is AuthUnauthenticated) {
        return isLoggingIn ? null : '/login';
      }

      if (authState is AuthAuthenticated) {
        return isLoggingIn ? '/' : null;
      }
      
      if (authState is AuthError) {
        return null; // Do not force logout redirect on transient errors
      }

      return null;
    },
    routes: [
      GoRoute(
        path: '/login',
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: '/',
        builder: (context, state) {
          final authState = ref.read(authControllerProvider);
          if (authState is AuthInitial || authState is AuthLoading) {
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }
          if (authState is AuthError) {
            return Scaffold(
              body: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(authState.error.message),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () {
                        ref.read(authControllerProvider.notifier).retryAuthentication();
                      },
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            );
          }
          return const DashboardScreen();
        },
      ),
    ],
  );
});

