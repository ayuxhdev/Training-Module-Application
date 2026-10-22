import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/presentation/components/cinematic_components.dart';
import 'package:training_app/features/profile/presentation/widgets/appearance_settings.dart';
import 'package:training_app/core/presentation/components/secondary_button.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  void _showAppearance() {
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      requestFocus: true,
      constraints: BoxConstraints(
        maxWidth: 560,
        maxHeight: MediaQuery.sizeOf(context).height * .9,
      ),
      sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : null,
      builder: (_) => const SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: AppearanceSettings(),
      ),
    );
  }

  Future<void> _refresh() async {
    final authState = ref.read(authControllerProvider);
    try {
      await ref.read(authControllerProvider.notifier).refreshProfile();
    } on ApiError catch (error) {
      // A delayed failure must not display another account's error after logout/login.
      if (mounted && identical(ref.read(authControllerProvider), authState)) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authControllerProvider);

    if (authState is! AuthAuthenticated) {
      return const SizedBox.shrink(); // AppShell handles loading/error
    }

    final employee = authState.employee;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        actions: [
          IconButton(
            tooltip: 'Appearance',
            style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: _showAppearance,
            icon: const Icon(Icons.palette_outlined),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            CinematicHero(
              eyebrow: employee == null
                  ? 'Account profile'
                  : 'Employee profile',
              title: employee?.displayName ?? authState.identity.displayName,
              subtitle: employee == null
                  ? 'Your account and appearance.'
                  : 'Your learning, your way.',
              icon: Icons.person_outline_rounded,
              child: Align(
                alignment: Alignment.centerLeft,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: StatusBadge(
                    text: employee == null || employee.isActive
                        ? 'Active'
                        : 'Inactive',
                    status: employee == null || employee.isActive
                        ? BadgeStatus.success
                        : BadgeStatus.error,
                  ),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            const SectionHeading(
              'Account details',
              subtitle: 'Your organization profile.',
            ),
            CustomCard(
              child: Column(
                children: [
                  if (employee != null) ...[
                    _ProfileItem(
                      label: 'Employee Code',
                      value: employee.employeeCode,
                    ),
                    const Divider(),
                    _ProfileItem(
                      label: 'Department',
                      value: employee.department,
                    ),
                    const Divider(),
                    _ProfileItem(label: 'Job Role', value: employee.jobRole),
                    const Divider(),
                  ],
                  _ProfileItem(
                    label: 'Username',
                    value: authState.identity.username,
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            if (authState.canLearn)
              Card(
                child: ListTile(
                  contentPadding: const EdgeInsets.all(16),
                  leading: const Icon(Icons.workspace_premium_outlined),
                  title: const Text('My Certificates'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/profile/certificates'),
                ),
              ),
            const SizedBox(height: AppSpacing.md),
            for (final kind in ReferenceKind.values)
              if (authState.identity.capabilities.contains(kind.permission))
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.account_tree_outlined),
                    title: Text(kind.title),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => context.push('/workspace/${kind.path}'),
                  ),
                ),
            SecondaryButton(
              text: 'Logout',
              onPressed: () {
                ref.read(authControllerProvider.notifier).logout();
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileItem extends StatelessWidget {
  final String label;
  final String value;

  const _ProfileItem({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: Theme.of(context).textTheme.bodyLarge
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
