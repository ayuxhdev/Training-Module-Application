import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
import 'package:training_app/core/presentation/components/cinematic_components.dart';
import 'package:training_app/core/presentation/components/content_skeleton.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/presentation/components/empty_view.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';
import 'package:training_app/features/management/presentation/controllers/management_controller.dart';

/// Foundation screen for Training Management in the mobile application.
/// Provides course catalog overview, authoring capability status, lifecycle
/// architecture guidance, and published version monitoring.
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
    final canAssign = canAssignTraining(identity);
    final hasCompanyAssign = hasCompanyAssignmentAuthority(identity);
    final canViewCourses = canViewTraining(identity);
    final canCreateCourses = canCreateTraining(identity);
    final canEditCourses = canEditTraining(identity);
    final canViewVers = canViewVersions(identity);
    final canCreateVers = canCreateVersions(identity);
    final canEditVers = canEditVersions(identity);
    final canViewMod = canViewModules(identity);
    final canCreateMod = canCreateModules(identity);
    final canEditMod = canEditModules(identity);
    final canViewLes = canViewLessons(identity);
    final canCreateLes = canCreateLessons(identity);
    final canEditLes = canEditLessons(identity);

    final canAuthor = canCreateCourses ||
        canEditCourses ||
        canCreateVers ||
        canEditVers ||
        canCreateMod ||
        canEditMod ||
        canCreateLes ||
        canEditLes;

    String courseCatalogValue;
    if (canCreateCourses && canEditCourses) {
      courseCatalogValue = 'Create and edit';
    } else if (canCreateCourses) {
      courseCatalogValue = 'Create only';
    } else if (canEditCourses) {
      courseCatalogValue = 'Edit only';
    } else if (canViewCourses) {
      courseCatalogValue = 'View only';
    } else {
      courseCatalogValue = 'No catalog access';
    }
    final courseCatalogGranted =
        canCreateCourses || canEditCourses || canViewCourses;

    String versionControlValue;
    if (canCreateVers && canEditVers) {
      versionControlValue = 'Create and edit versions';
    } else if (canCreateVers) {
      versionControlValue = 'Create versions only';
    } else if (canEditVers) {
      versionControlValue = 'Edit versions only';
    } else if (canViewVers) {
      versionControlValue = 'View versions only';
    } else {
      versionControlValue = 'No version access';
    }
    final versionControlGranted =
        canCreateVers || canEditVers || canViewVers;

    String moduleManagementValue;
    if (canCreateMod && canEditMod) {
      moduleManagementValue = 'Create and edit';
    } else if (canCreateMod) {
      moduleManagementValue = 'Create only';
    } else if (canEditMod) {
      moduleManagementValue = 'Edit only';
    } else if (canViewMod) {
      moduleManagementValue = 'View only';
    } else {
      moduleManagementValue = 'No module access';
    }
    final moduleManagementGranted =
        canCreateMod || canEditMod || canViewMod;

    String lessonManagementValue;
    if (canCreateLes && canEditLes) {
      lessonManagementValue = 'Create and edit';
    } else if (canCreateLes) {
      lessonManagementValue = 'Create only';
    } else if (canEditLes) {
      lessonManagementValue = 'Edit only';
    } else if (canViewLes) {
      lessonManagementValue = 'View only';
    } else {
      lessonManagementValue = 'No lesson access';
    }
    final lessonManagementGranted =
        canCreateLes || canEditLes || canViewLes;

    String assignmentValue;
    if (hasCompanyAssign) {
      assignmentValue = 'Company-wide assignment';
    } else if (canAssign) {
      assignmentValue = 'Team assignment only';
    } else {
      assignmentValue = 'Assignment restricted';
    }
    final assignmentGranted = canAssign;

    final assignableRequest = (page: 1, search: null);
    final assignableAsync = canAssign
        ? ref.watch(assignableTrainingVersionsProvider(assignableRequest))
        : null;

    Future<void> handleRefresh() async {
      if (canAssign) {
        ref.invalidate(assignableTrainingVersionsProvider(assignableRequest));
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Training management'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () => handleRefresh(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: handleRefresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            CinematicHero(
              eyebrow: 'Curriculum & Catalog',
              title: 'Training management',
              subtitle: 'Course catalog, version lifecycle, and curriculum authoring.',
              icon: Icons.auto_stories_outlined,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  StatusBadge(
                    text: canAuthor ? 'Authoring permitted' : 'Catalog view',
                    status: canAuthor ? BadgeStatus.success : BadgeStatus.neutral,
                  ),
                  if (canAssign)
                    const StatusBadge(
                      text: 'Assignment authority',
                      status: BadgeStatus.info,
                    ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),

            // 1. Authoring Capabilities
            const SectionHeading(
              'Authoring capabilities',
              subtitle: 'Effective permissions granted by server identity.',
            ),
            CustomCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _capabilityRow(
                    context,
                    label: 'Course catalog',
                    value: courseCatalogValue,
                    granted: courseCatalogGranted,
                  ),
                  const Divider(height: AppSpacing.md),
                  _capabilityRow(
                    context,
                    label: 'Version control',
                    value: versionControlValue,
                    granted: versionControlGranted,
                  ),
                  const Divider(height: AppSpacing.md),
                  _capabilityRow(
                    context,
                    label: 'Module management',
                    value: moduleManagementValue,
                    granted: moduleManagementGranted,
                  ),
                  const Divider(height: AppSpacing.md),
                  _capabilityRow(
                    context,
                    label: 'Lesson management',
                    value: lessonManagementValue,
                    granted: lessonManagementGranted,
                  ),
                  const Divider(height: AppSpacing.md),
                  _capabilityRow(
                    context,
                    label: 'Team assignments',
                    value: assignmentValue,
                    granted: assignmentGranted,
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),

            // 2. Version Lifecycle Architectural Rules
            const SectionHeading(
              'Version lifecycle',
              subtitle: 'Garden’s Need strict immutability and version pinning rules.',
            ),
            CustomCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _lifecycleStage(
                    context,
                    title: 'DRAFT',
                    badgeStatus: BadgeStatus.warning,
                    description:
                        'Content is actively mutable. Modules, lessons, video media, '
                        'and assessments can be configured and updated.',
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _lifecycleStage(
                    context,
                    title: 'PUBLISHED',
                    badgeStatus: BadgeStatus.success,
                    description:
                        'Immutable once published. Learner assignments are pinned '
                        'to this version. Content cannot be edited or deleted.',
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _lifecycleStage(
                    context,
                    title: 'RETIRED',
                    badgeStatus: BadgeStatus.neutral,
                    description:
                        'Historical archive. Existing assigned learners may complete '
                        'their assigned version; no new assignments are permitted.',
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),

            // 3. Authoring Operations (Upcoming Stage 2 Notice)
            const SectionHeading(
              'Authoring operations',
              subtitle: 'Upcoming mobile course, module, lesson, and video management.',
            ),
            CustomCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.engineering_outlined,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          'Stage 2 Authoring API in preparation',
                          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Full mobile authoring — including course creation, draft editing, '
                    'module ordering, video uploads, and version publication — will be '
                    'enabled in Stage 2 following backend REST endpoint deployment.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  if (!canAuthor)
                    Text(
                      'Your account has view-only curriculum access. Authoring and mutation controls remain restricted.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    )
                  else
                    Wrap(
                      spacing: AppSpacing.sm,
                      runSpacing: AppSpacing.sm,
                      children: [
                        if (canCreateCourses)
                          ActionChip(
                            avatar: const Icon(Icons.add, size: 16),
                            label: const Text('Create course'),
                            onPressed: null,
                            tooltip: 'Course creation REST API pending Stage 2',
                          ),
                        if (canEditCourses)
                          ActionChip(
                            avatar: const Icon(Icons.edit_note, size: 16),
                            label: const Text('Edit course'),
                            onPressed: null,
                            tooltip: 'Course editing REST API pending Stage 2',
                          ),
                        if (canCreateVers)
                          ActionChip(
                            avatar: const Icon(Icons.post_add, size: 16),
                            label: const Text('New version'),
                            onPressed: null,
                            tooltip: 'Version authoring REST API pending Stage 2',
                          ),
                        if (canEditVers)
                          ActionChip(
                            avatar: const Icon(Icons.edit_calendar_outlined, size: 16),
                            label: const Text('Edit version'),
                            onPressed: null,
                            tooltip: 'Version editing REST API pending Stage 2',
                          ),
                        if (canCreateMod)
                          ActionChip(
                            avatar: const Icon(Icons.view_module_outlined, size: 16),
                            label: const Text('Create module'),
                            onPressed: null,
                            tooltip: 'Module creation REST API pending Stage 2',
                          ),
                        if (canEditMod)
                          ActionChip(
                            avatar: const Icon(Icons.edit_outlined, size: 16),
                            label: const Text('Edit module'),
                            onPressed: null,
                            tooltip: 'Module editing REST API pending Stage 2',
                          ),
                        if (canCreateLes)
                          ActionChip(
                            avatar: const Icon(Icons.note_add_outlined, size: 16),
                            label: const Text('Create lesson'),
                            onPressed: null,
                            tooltip: 'Lesson creation REST API pending Stage 2',
                          ),
                        if (canEditLes)
                          ActionChip(
                            avatar: const Icon(Icons.edit_document, size: 16),
                            label: const Text('Edit lesson'),
                            onPressed: null,
                            tooltip: 'Lesson editing REST API pending Stage 2',
                          ),
                        if (canCreateLes || canEditLes)
                          ActionChip(
                            avatar: const Icon(Icons.video_call_outlined, size: 16),
                            label: const Text('Upload video'),
                            onPressed: null,
                            tooltip: 'Video upload REST API pending Stage 2',
                          ),
                      ],
                    ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),

            // 4. Live Published Assignable Versions
            const SectionHeading(
              'Published assignable versions',
              subtitle:
                  'Active versions available for learner assignment. Full draft '
                  'and retired catalog requires Stage 2 backend APIs.',
            ),
            if (!canAssign)
              const CustomCard(
                child: Text(
                  'Assignable versions list requires training assignment authority.',
                ),
              )
            else if (assignableAsync != null)
              assignableAsync.when(
                loading: () => const CardListSkeleton(
                  message: 'Loading assignable versions',
                  showHeader: false,
                  compact: true,
                ),
                error: (error, _) => ApiErrorView(
                  error: error,
                  onRetry: () => ref.refresh(
                    assignableTrainingVersionsProvider(assignableRequest).future,
                  ),
                ),
                data: (page) {
                  if (page.items.isEmpty) {
                    return const EmptyView(
                      message: 'No published training versions currently available.',
                      icon: Icons.school_outlined,
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                        child: Text(
                          '${page.count} published assignable version(s) in catalog',
                          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ),
                      ...page.items.map(
                        (version) => Padding(
                          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                          child: _versionCard(context, version),
                        ),
                      ),
                    ],
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _capabilityRow(
    BuildContext context, {
    required String label,
    required String value,
    required bool granted,
  }) =>
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          StatusBadge(
            text: granted ? 'Granted' : 'Restricted',
            status: granted ? BadgeStatus.success : BadgeStatus.neutral,
          ),
        ],
      );

  Widget _lifecycleStage(
    BuildContext context, {
    required String title,
    required BadgeStatus badgeStatus,
    required String description,
  }) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StatusBadge(text: title, status: badgeStatus),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            description,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      );

  Widget _versionCard(BuildContext context, AssignableTrainingVersion version) =>
      CustomCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              version.title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              '${version.trainingTitle} · Code: ${version.trainingCode}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                StatusBadge(
                  text: 'Version ${version.versionNumber}',
                  status: BadgeStatus.neutral,
                ),
                StatusBadge(
                  text: version.status,
                  status: BadgeStatus.info,
                ),
              ],
            ),
            if (version.description.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                version.description,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      );
}
