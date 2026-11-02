import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
import 'package:training_app/core/presentation/components/cinematic_components.dart';
import 'package:training_app/core/presentation/components/content_skeleton.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/presentation/components/empty_view.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/presentation/components/curriculum_components.dart';
import 'package:training_app/features/management/presentation/controllers/management_controller.dart';

class ManagedVersionDetailScreen extends ConsumerStatefulWidget {
  final int versionId;

  const ManagedVersionDetailScreen({super.key, required this.versionId});

  @override
  ConsumerState<ManagedVersionDetailScreen> createState() =>
      _ManagedVersionDetailScreenState();
}

class _ManagedVersionDetailScreenState
    extends ConsumerState<ManagedVersionDetailScreen> {
  int _assessmentsPage = 1;

  @override
  Widget build(BuildContext context) {
    final versionId = widget.versionId;
    final auth = ref.watch(authControllerProvider);
    if (auth is! AuthAuthenticated || !canViewVersions(auth.identity)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Version details')),
        body: const Center(
          child: Text('You do not have permission to view version details.'),
        ),
      );
    }

    final asyncVersion = ref.watch(managedVersionDetailProvider(versionId));
    final theme = Theme.of(context);
    final identity = auth.identity;
    final isDraft = asyncVersion.asData?.value.status.toUpperCase() == 'DRAFT';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Version details'),
        actions: [
          if (isDraft && canCreateModules(identity))
            IconButton(
              tooltip: 'Create module',
              onPressed: () => context.push(
                '/workspace/training/versions/$versionId/modules/new',
                extra: asyncVersion.asData?.value,
              ),
              icon: const Icon(Icons.add_box_outlined),
            ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: () =>
                ref.refresh(managedVersionDetailProvider(versionId).future),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: asyncVersion.when(
        loading: () => const Center(
          child: CardListSkeleton(message: 'Loading curriculum', compact: true),
        ),
        error: (error, _) => ApiErrorView(
          error: error,
          onRetry: () =>
              ref.refresh(managedVersionDetailProvider(versionId).future),
        ),
        data: (version) {
          final totalLessons = version.modules.fold<int>(
            0,
            (sum, m) => sum + m.lessons.length,
          );
          final status = version.status.toUpperCase();
          final canViewAss = canViewAssessments(identity);
          final canCreateAss =
              status == 'DRAFT' && canCreateAssessments(identity);
          final lifecyclePolicy = switch (status) {
            'PUBLISHED' => 'This version is PUBLISHED and immutable. Content cannot be edited or deleted. Active learner assignments are pinned to this version.',
            'DRAFT' => 'This version is in DRAFT. Content, modules, lessons, and media can be configured before publication.',
            'RETIRED' => 'This version is RETIRED. Existing learners may complete their training, but no new assignments can be made.',
            _ => 'Version status: $status',
          };

          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(managedVersionDetailProvider(versionId));
              if (canViewAssessments(identity)) {
                ref.invalidate(managedVersionAssessmentsProvider);
              }
              await ref.read(managedVersionDetailProvider(versionId).future);
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(AppSpacing.md),
              children: [
                CinematicHero(
                  eyebrow: 'VERSION ${version.versionNumber}',
                  title: version.title,
                  subtitle: version.description.isNotEmpty
                      ? version.description
                      : (version.trainingTitle ?? 'Curriculum structure'),
                  icon: Icons.layers_outlined,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      VersionLifecycleBadge(status: version.status),
                      const StatusBadge(
                        text: 'MANAGEMENT VIEW',
                        status: BadgeStatus.info,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),

                // Lifecycle and architecture summary
                const SectionHeading(
                  'Lifecycle status',
                  subtitle: 'Garden’s Need enforces strict immutability and version rules.',
                ),
                CustomCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            status == 'PUBLISHED'
                                ? Icons.verified_outlined
                                : status == 'DRAFT'
                                ? Icons.edit_note_outlined
                                : Icons.archive_outlined,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: Text(
                              '$status Version',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        lifecyclePolicy,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      const Divider(height: 1),
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        '${version.modules.length} module(s) · $totalLessons lesson(s) recorded',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),

                // Modules and lessons curriculum section
                const SectionHeading(
                  'Curriculum structure',
                  subtitle:
                      'Ordered modules and lesson summaries for this version.',
                ),
                if (status == 'DRAFT' && canCreateModules(identity))
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.add),
                      label: const Text('Create module'),
                      onPressed: () => context.push(
                        '/workspace/training/versions/$versionId/modules/new',
                        extra: version,
                      ),
                    ),
                  ),
                if (version.modules.isEmpty)
                  const EmptyView(
                    message: 'No modules defined in this version.',
                    icon: Icons.view_module_outlined,
                  )
                else
                  ...version.modules.map(
                    (module) => Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: ManagedModuleCard(
                        module: module,
                        actionSlot: status == 'DRAFT'
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (canEditModules(identity))
                                    IconButton(
                                      tooltip: 'Edit module',
                                      icon: const Icon(
                                        Icons.edit_outlined,
                                        size: 20,
                                      ),
                                      visualDensity: VisualDensity.compact,
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                      onPressed: () => context.push(
                                        '/workspace/training/versions/$versionId/modules/${module.id}/edit',
                                        extra: module,
                                      ),
                                    ),
                                  if (canCreateLessons(identity)) ...[
                                    const SizedBox(width: AppSpacing.xs),
                                    IconButton(
                                      tooltip: 'Add text lesson',
                                      icon: const Icon(
                                        Icons.add_circle_outline,
                                        size: 20,
                                      ),
                                      visualDensity: VisualDensity.compact,
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                      onPressed: () => context.push(
                                        '/workspace/training/versions/$versionId/modules/${module.id}/lessons/new',
                                        extra: module,
                                      ),
                                    ),
                                    const SizedBox(width: AppSpacing.xs),
                                    IconButton(
                                      tooltip: 'Add video lesson',
                                      icon: const Icon(
                                        Icons.video_call_outlined,
                                        size: 20,
                                      ),
                                      visualDensity: VisualDensity.compact,
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                      onPressed: () => context.push(
                                        '/workspace/training/versions/$versionId/modules/${module.id}/video-lessons/new',
                                        extra: module,
                                      ),
                                    ),
                                  ],
                                ],
                              )
                            : null,
                        onEditLesson:
                            status == 'DRAFT' &&
                                canAccessLessonEditForm(identity)
                            ? (lesson) {
                                if (lesson.lessonType.toUpperCase() ==
                                    'VIDEO') {
                                  context.push(
                                    '/workspace/training/versions/$versionId/modules/${module.id}/video-lessons/${lesson.id}/edit',
                                    extra: lesson,
                                  );
                                } else {
                                  context.push(
                                    '/workspace/training/versions/$versionId/modules/${module.id}/lessons/${lesson.id}/edit',
                                    extra: lesson,
                                  );
                                }
                              }
                            : null,
                      ),
                    ),
                  ),
                if (canViewAss || canCreateAss) ...[
                  const SizedBox(height: AppSpacing.lg),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Expanded(
                        child: SectionHeading(
                          'Assessments',
                          subtitle: 'Module quizzes and final assessments configured for this version.',
                        ),
                      ),
                      if (canCreateAss)
                        OutlinedButton.icon(
                          icon: const Icon(Icons.add),
                          label: const Text('Create assessment'),
                          onPressed: () => context.push(
                            '/workspace/training/versions/$versionId/assessments/new',
                            extra: version,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  if (canViewAss)
                    Consumer(
                      builder: (context, ref, _) {
                        final assessmentsAsync = ref.watch(
                          managedVersionAssessmentsProvider((
                            versionId: versionId,
                            page: _assessmentsPage,
                          )),
                        );
                        return assessmentsAsync.when(
                          loading: () => const Center(
                            child: Padding(
                              padding: EdgeInsets.all(AppSpacing.md),
                              child: CircularProgressIndicator(),
                            ),
                          ),
                          error: (err, _) => CustomCard(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Error loading assessments: $err'),
                                const SizedBox(height: AppSpacing.sm),
                                TextButton.icon(
                                  onPressed: () => ref.refresh(
                                    managedVersionAssessmentsProvider((
                                      versionId: versionId,
                                      page: _assessmentsPage,
                                    )).future,
                                  ),
                                  icon: const Icon(Icons.refresh),
                                  label: const Text('Retry'),
                                ),
                              ],
                            ),
                          ),
                          data: (page) {
                            final assessments = page.items;
                            if (assessments.isEmpty) {
                              return const EmptyView(
                                message: 'No assessments configured for this version.',
                                icon: Icons.quiz_outlined,
                              );
                            }
                            return Column(
                              children: [
                                ...assessments.map((assessment) {
                                  final isQuiz = assessment.isQuiz;
                                  return Padding(
                                    padding: const EdgeInsets.only(
                                      bottom: AppSpacing.sm,
                                    ),
                                    child: CustomCard(
                                      child: InkWell(
                                        borderRadius: BorderRadius.circular(12),
                                        onTap: () {
                                          context.push(
                                            '/workspace/training/versions/$versionId/assessments/${assessment.id}',
                                            extra: assessment,
                                          );
                                        },
                                        child: Padding(
                                          padding: const EdgeInsets.all(
                                            AppSpacing.sm,
                                          ),
                                          child: Row(
                                            children: [
                                              CircleAvatar(
                                                radius: 18,
                                                backgroundColor: isQuiz
                                                    ? Theme.of(context)
                                                          .colorScheme
                                                          .primaryContainer
                                                    : Theme.of(context)
                                                          .colorScheme
                                                          .tertiaryContainer,
                                                child: Icon(
                                                  isQuiz
                                                      ? Icons.quiz_outlined
                                                      : Icons
                                                            .military_tech_outlined,
                                                  size: 20,
                                                  color: isQuiz
                                                      ? Theme.of(context)
                                                            .colorScheme
                                                            .onPrimaryContainer
                                                      : Theme.of(context)
                                                            .colorScheme
                                                            .onTertiaryContainer,
                                                ),
                                              ),
                                              const SizedBox(
                                                width: AppSpacing.md,
                                              ),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      assessment.title,
                                                      style: Theme.of(context)
                                                          .textTheme
                                                          .titleSmall
                                                          ?.copyWith(
                                                            fontWeight:
                                                                FontWeight.bold,
                                                          ),
                                                    ),
                                                    const SizedBox(height: 2),
                                                    Text(
                                                      '${assessment.kind} · Pass: ${assessment.passPercentage}% · Max attempts: ${assessment.maxAttempts}',
                                                      style: Theme.of(context)
                                                          .textTheme
                                                          .bodySmall
                                                          ?.copyWith(
                                                            color: Theme.of(context)
                                                                .colorScheme
                                                                .onSurfaceVariant,
                                                          ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              StatusBadge(
                                                text: assessment.kind,
                                                status: isQuiz
                                                    ? BadgeStatus.info
                                                    : BadgeStatus.success,
                                              ),
                                              const SizedBox(
                                                width: AppSpacing.xs,
                                              ),
                                              const Icon(
                                                Icons.chevron_right,
                                                size: 20,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                }),
                                if (page.hasMore || _assessmentsPage > 1)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: AppSpacing.sm,
                                    ),
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        TextButton.icon(
                                          icon: const Icon(Icons.chevron_left),
                                          label: const Text('Previous'),
                                          onPressed: _assessmentsPage > 1
                                              ? () => setState(
                                                  () => _assessmentsPage--,
                                                )
                                              : null,
                                        ),
                                        Text(
                                          'Page $_assessmentsPage · ${page.count} total',
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall,
                                        ),
                                        TextButton.icon(
                                          label: const Text('Next'),
                                          icon: const Icon(Icons.chevron_right),
                                          onPressed: page.hasMore
                                              ? () => setState(
                                                  () => _assessmentsPage++,
                                                )
                                              : null,
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            );
                          },
                        );
                      },
                    ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}
