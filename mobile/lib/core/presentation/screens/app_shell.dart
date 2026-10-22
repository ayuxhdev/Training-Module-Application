import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/core/presentation/components/error_view.dart';

class AppShell extends ConsumerWidget {
  final Widget child;
  final String location;

  const AppShell({super.key, required this.child, required this.location});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authControllerProvider);

    if (authState is AuthInitial || authState is AuthLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (authState is AuthError) {
      return Scaffold(
        body: ErrorView(
          title: 'Authentication unavailable',
          message: authState.error.message,
          onRetry: () =>
              ref.read(authControllerProvider.notifier).retryAuthentication(),
        ),
      );
    }

    if (authState is! AuthAuthenticated) return const SizedBox.shrink();
    final identity = authState.identity;
    final paths = [
      if (identity.canLearn) '/dashboard',
      if (identity.canLearn) '/learning',
      if (identity.canManage || identity.canViewTeam) '/workspace',
      '/profile',
    ];
    final destinations = [
      if (identity.canLearn)
        const NavigationDestination(
          icon: Icon(Icons.dashboard_outlined),
          selectedIcon: Icon(Icons.dashboard_rounded),
          label: 'Dashboard',
        ),
      if (identity.canLearn)
        const NavigationDestination(
          icon: Icon(Icons.school_outlined),
          selectedIcon: Icon(Icons.school_rounded),
          label: 'Learning',
        ),
      if (identity.canManage || identity.canViewTeam)
        NavigationDestination(
          icon: const Icon(Icons.workspaces_outline),
          selectedIcon: const Icon(Icons.workspaces),
          label: identity.canManage ? 'Management' : 'Team',
        ),
      const NavigationDestination(
        icon: Icon(Icons.person_outline_rounded),
        selectedIcon: Icon(Icons.person_rounded),
        label: 'Profile',
      ),
    ];
    final matched = paths.indexWhere(
      (path) => location == path || location.startsWith('$path/'),
    );
    final currentIndex = matched < 0
        ? location.startsWith('/workspace/')
              ? paths.indexOf('/profile')
              : 0
        : matched;

    return Scaffold(
      body: child,
      bottomNavigationBar: destinations.length < 2
          ? null
          : Container(
              margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(28),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              child: NavigationBar(
                selectedIndex: currentIndex,
                onDestinationSelected: (index) {
                  context.go(paths[index]);
                },
                destinations: destinations,
              ),
            ),
    );
  }
}
