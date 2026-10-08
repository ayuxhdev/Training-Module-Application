import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/presentation/components/error_view.dart';
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
      appBar: AppBar(
        title: const Text('Modules'),
      ),
      body: detailAsync.when(
        data: (detail) {
          final modules = detail.modules;

          if (modules.isEmpty) {
            return RefreshIndicator(
              onRefresh: () async => ref.refresh(assignmentDetailProvider(assignmentId).future),
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
            onRefresh: () async => ref.refresh(assignmentDetailProvider(assignmentId).future),
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: AppSpacing.pagePadding,
              itemCount: modules.length,
              separatorBuilder: (context, index) => AppSpacing.gapMd,
              itemBuilder: (context, index) {
                final module = modules[index];
                return GestureDetector(
                  onTap: () {
                    context.go('/learning/assignments/$assignmentId/modules/${module.id}/lessons');
                  },
                  child: CustomCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Text(
                                '${module.position}. ${module.title}',
                                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            const Icon(Icons.chevron_right),
                          ],
                        ),
                        if (module.description.isNotEmpty) ...[
                          AppSpacing.gapSm,
                          Text(
                            module.description,
                            style: Theme.of(context).textTheme.bodyMedium,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                        AppSpacing.gapSm,
                        Text(
                          '${module.lessons.length} Lesson${module.lessons.length == 1 ? '' : 's'}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          );
        },
        loading: () => const LoadingView(),
        error: (error, stackTrace) => ErrorView(
          message: error.toString(),
          onRetry: () => ref.refresh(assignmentDetailProvider(assignmentId).future),
        ),
      ),
    );
  }
}
