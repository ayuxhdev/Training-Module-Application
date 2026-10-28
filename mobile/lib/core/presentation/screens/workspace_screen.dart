import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/presentation/components/cinematic_components.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/presentation/controllers/management_controller.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';

/// Only destinations authorized by the identity snapshot are offered here.
class WorkspaceScreen extends ConsumerWidget {
  const WorkspaceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    if (auth is! AuthAuthenticated) return const SizedBox.shrink();
    final identity = auth.identity;
    return Scaffold(
      appBar: AppBar(title: const Text('Account access')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          CinematicHero(
            eyebrow: 'Garden’s Need',
            title: identity.displayName,
            subtitle: 'Your authorized workspaces.',
            icon: Icons.workspaces_outline,
          ),
          const SizedBox(height: AppSpacing.lg),
          if (identity.canManage)
            const Padding(
              padding: EdgeInsets.only(bottom: AppSpacing.md),
              child: CustomCard(
                child: ListTile(
                  leading: Icon(Icons.business_outlined),
                  title: Text('Management access'),
                  subtitle: Text(
                    'Create/edit Departments and Job Roles when permitted. '
                    'Other management workflows are unavailable.',
                  ),
                ),
              ),
            ),
          if (identity.canViewTeam)
            const Padding(
              padding: EdgeInsets.only(bottom: AppSpacing.md),
              child: CustomCard(
                child: ListTile(
                  leading: Icon(Icons.groups_outlined),
                  title: Text('Team access'),
                  subtitle: Text(
                    'Team visibility follows your reporting hierarchy.',
                  ),
                ),
              ),
            ),
          if (canViewManagementDashboard(identity))
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.md),
              child: Card(
                child: ListTile(
                  leading: const Icon(Icons.dashboard_outlined),
                  title: Text(
                    identity.capabilities.contains('company_dashboard')
                        ? 'Company dashboard'
                        : 'Team dashboard',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/workspace/dashboard'),
                ),
              ),
            ),
          if (canManageTraining(identity))
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.md),
              child: Card(
                child: ListTile(
                  leading: const Icon(Icons.auto_stories_outlined),
                  title: const Text('Training management'),
                  subtitle: const Text(
                    'Course catalog, version lifecycle, and curriculum authoring.',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/workspace/training'),
                ),
              ),
            ),
          if (identity.capabilities.contains('organization.view_employee'))
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.md),
              child: Card(
                child: ListTile(
                  leading: const Icon(Icons.badge_outlined),
                  title: const Text('Employee directory'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/workspace/employees'),
                ),
              ),
            ),
          for (final kind in ReferenceKind.values)
            if (identity.capabilities.contains(kind.permission))
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
        ],
      ),
    );
  }
}
