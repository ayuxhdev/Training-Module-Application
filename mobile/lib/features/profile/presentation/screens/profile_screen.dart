import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
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
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final columns =
                      constraints.maxWidth >= 280 &&
                          MediaQuery.textScalerOf(context).scale(14) <= 21
                      ? 2
                      : 1;
                  final fields = [
                    ('Username', authState.identity.username),
                    if (employee != null) ...[
                      ('Employee Code', employee.employeeCode),
                      ('Department', employee.department),
                      ('Job Role', employee.jobRole),
                    ],
                  ];
                  return Wrap(
                    spacing: AppSpacing.md,
                    runSpacing: AppSpacing.md,
                    children: [
                      for (final (index, field) in fields.indexed)
                        SizedBox(
                          width:
                              (constraints.maxWidth -
                                  AppSpacing.md * (columns - 1)) /
                              columns,
                          child: _ProfileItem(
                            label: field.$1,
                            value: field.$2,
                            order: index.toDouble(),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            if (authState.canLearn)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                child: Card(
                  child: ListTile(
                    contentPadding: const EdgeInsets.all(16),
                    leading: const Icon(Icons.workspace_premium_outlined),
                    title: const Text('My Certificates'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => context.push('/profile/certificates'),
                  ),
                ),
              ),
            for (final kind in ReferenceKind.values)
              if (authState.identity.capabilities.contains(kind.permission))
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.md),
                  child: Card(
                    child: ListTile(
                      leading: const Icon(Icons.account_tree_outlined),
                      title: Text(kind.title),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => context.push('/workspace/${kind.path}'),
                    ),
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
  final double order;

  const _ProfileItem({
    required this.label,
    required this.value,
    required this.order,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      sortKey: OrdinalSortKey(order),
      label: '$label: $value',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
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
