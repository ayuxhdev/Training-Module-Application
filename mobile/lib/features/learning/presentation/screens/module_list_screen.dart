import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/presentation/components/cinematic_components.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
import 'package:training_app/core/presentation/components/loading_view.dart';
import 'package:training_app/core/presentation/components/empty_view.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/features/learning/presentation/controllers/learning_controller.dart';

class ModuleListScreen extends ConsumerWidget {
  final int assignmentId;

  const ModuleListScreen({super.key, required this.assignmentId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detailAsync = ref.watch(assignmentDetailProvider(assignmentId));

    return Scaffold(
      appBar: AppBar(title: const Text('Modules')),
      body: detailAsync.when(
        data: (detail) {
          final modules = detail.modules;

          if (modules.isEmpty) {
            return RefreshIndicator(
              onRefresh: () => ref
                  .refresh(assignmentDetailProvider(assignmentId).future)
                  .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverFillRemaining(
                    child: EmptyView(
                      message: 'No modules found for this assignment.',
                      icon: Icons.view_module_outlined,
                    ),
                  ),
                ],
              ),
            );
          }

          return RefreshIndicator(
            onRefresh: () => ref
                .refresh(assignmentDetailProvider(assignmentId).future)
                .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: AppSpacing.pagePadding,
              itemCount: modules.length,
              separatorBuilder: (context, index) => AppSpacing.gapMd,
              itemBuilder: (context, index) {
                final module = modules[index];
                return LearningCard(
                  title: '${module.position}. ${module.title}',
                  subtitle: module.description.isNotEmpty
                      ? module.description
                      : 'Explore the lessons in this module.',
                  status:
                      '${module.lessons.length} Lesson${module.lessons.length == 1 ? '' : 's'}',
                  badgeStatus: BadgeStatus.info,
                  icon: Icons.layers_outlined,
                  onTap: () => context.go(
                    '/learning/assignments/$assignmentId/modules/${module.id}/lessons',
                  ),
                );
              },
            ),
          );
        },
        loading: () => const LoadingView(),
        error: (error, stackTrace) => ApiErrorView(
          error: error,
          onRetry: () => ref.invalidate(assignmentDetailProvider(assignmentId)),
        ),
      ),
    );
  }
}
