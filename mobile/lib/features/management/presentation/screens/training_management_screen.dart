import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/presentation/components/assignable_versions_sheet.dart';
import 'package:training_app/features/management/presentation/components/curriculum_components.dart';
import 'package:training_app/features/management/presentation/controllers/management_controller.dart';

class TrainingManagementScreen extends ConsumerWidget {
  const TrainingManagementScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    if (auth is! AuthAuthenticated || !canManageTraining(auth.identity)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Training management')),
        body: const Center(
          child: Text('You do not have permission to manage training.'),
        ),
      );
    }

    final identity = auth.identity;
    final shortcuts = [
      if (canViewTraining(identity))
        TrainingNavigationCard(
          title: 'Course catalog',
          description: 'Find courses and open their version history.',
          icon: Icons.auto_stories_outlined,
          onTap: () => context.push('/workspace/training/catalog'),
        )
      else if (canCreateTraining(identity))
        TrainingNavigationCard(
          title: 'Create course',
          description: 'Add a course to the training catalog.',
          icon: Icons.add_circle_outline,
          onTap: () => context.push('/workspace/training/catalog/new'),
        ),
      if (canViewVersions(identity))
        TrainingNavigationCard(
          title: 'Training versions',
          description: 'Browse versions across all courses.',
          icon: Icons.layers_outlined,
          onTap: () => context.push('/workspace/training/versions'),
        )
      else if (canAssignTraining(identity))
        TrainingNavigationCard(
          title: 'Assignable versions',
          description: 'See which published versions can be assigned.',
          icon: Icons.assignment_outlined,
          onTap: () => showAssignableVersions(context, auth),
        ),
      if (canViewQuestions(identity))
        TrainingNavigationCard(
          title: 'Question bank',
          description: 'Browse questions and revisions.',
          icon: Icons.quiz_outlined,
          onTap: () => context.push('/workspace/training/questions'),
        ),
      if (canManageRoleRequirements(identity))
        TrainingNavigationCard(
          title: 'Role requirements',
          description: canViewRoleRequirements(identity)
              ? 'Review required training by job role.'
              : 'Set required training by job role.',
          icon: Icons.rule_outlined,
          onTap: () => context.push('/workspace/training/role-requirements'),
        ),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Training management')),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView.separated(
            padding: AppSpacing.pagePadding,
            itemCount: shortcuts.isEmpty ? 1 : shortcuts.length,
            separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
            itemBuilder: (context, index) => shortcuts.isEmpty
                ? const Text(
                    'No training tools are available for this account.',
                  )
                : shortcuts[index],
          ),
        ),
      ),
    );
  }
}
