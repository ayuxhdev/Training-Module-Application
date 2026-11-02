import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
import 'package:training_app/core/presentation/components/content_skeleton.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/presentation/components/empty_view.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/presentation/controllers/management_controller.dart';

class QuestionBankScreen extends ConsumerStatefulWidget {
  const QuestionBankScreen({super.key});

  @override
  ConsumerState<QuestionBankScreen> createState() => _QuestionBankScreenState();
}

class _QuestionBankScreenState extends ConsumerState<QuestionBankScreen> {
  int _page = 1;
  String _search = '';
  bool? _isActive;
  late final TextEditingController _searchController;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    setState(() {
      _search = value.trim();
      _page = 1;
    });
  }

  void _onFilterChanged(bool? isActive) {
    setState(() {
      _isActive = isActive;
      _page = 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    if (auth is! AuthAuthenticated || !canViewQuestions(auth.identity)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Question bank')),
        body: const Center(
          child: Text('You do not have permission to view the question bank.'),
        ),
      );
    }

    final identity = auth.identity;
    final query = (
      page: _page,
      search: _search.isEmpty ? null : _search,
      isActive: _isActive,
    );
    final questionsAsync = ref.watch(managedQuestionsProvider(query));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Question bank'),
        actions: [
          if (canCreateQuestions(identity))
            IconButton(
              tooltip: 'New question',
              icon: const Icon(Icons.add),
              onPressed: () =>
                  context.push('/workspace/training/questions/new'),
            ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () =>
                ref.refresh(managedQuestionsProvider(query).future),
          ),
        ],
      ),
      body: Column(
        children: [
          // Search & Filter header
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              children: [
                TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: 'Search code or topic...',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _search.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchController.clear();
                              _onSearchChanged('');
                            },
                          )
                        : null,
                  ),
                  onSubmitted: _onSearchChanged,
                ),
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: [
                    FilterChip(
                      label: const Text('All'),
                      selected: _isActive == null,
                      onSelected: (_) => _onFilterChanged(null),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    FilterChip(
                      label: const Text('Active only'),
                      selected: _isActive == true,
                      onSelected: (_) => _onFilterChanged(true),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    FilterChip(
                      label: const Text('Inactive only'),
                      selected: _isActive == false,
                      onSelected: (_) => _onFilterChanged(false),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: questionsAsync.when(
              loading: () => const Center(
                child: CardListSkeleton(
                  message: 'Loading questions...',
                  compact: true,
                ),
              ),
              error: (error, _) => ApiErrorView(
                error: error,
                onRetry: () =>
                    ref.refresh(managedQuestionsProvider(query).future),
              ),
              data: (pageData) {
                final questions = pageData.items;
                if (questions.isEmpty) {
                  return const EmptyView(
                    message: 'No questions found.',
                    icon: Icons.quiz_outlined,
                  );
                }

                return RefreshIndicator(
                  onRefresh: () async {
                    ref.invalidate(managedQuestionsProvider(query));
                    await ref.read(managedQuestionsProvider(query).future);
                  },
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                    ),
                    itemCount: questions.length + 1,
                    itemBuilder: (context, index) {
                      if (index == questions.length) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: AppSpacing.md,
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              TextButton.icon(
                                icon: const Icon(Icons.chevron_left),
                                label: const Text('Previous'),
                                onPressed: _page > 1
                                    ? () => setState(() => _page--)
                                    : null,
                              ),
                              Text(
                                'Page $_page · ${pageData.count} total',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              TextButton.icon(
                                label: const Text('Next'),
                                icon: const Icon(Icons.chevron_right),
                                onPressed: pageData.hasMore
                                    ? () => setState(() => _page++)
                                    : null,
                              ),
                            ],
                          ),
                        );
                      }

                      final q = questions[index];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                        child: CustomCard(
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () {
                              context.push(
                                '/workspace/training/questions/${q.id}',
                                extra: q,
                              );
                            },
                            child: Padding(
                              padding: const EdgeInsets.all(AppSpacing.sm),
                              child: Row(
                                children: [
                                  CircleAvatar(
                                    backgroundColor: q.isActive
                                        ? Theme.of(context)
                                              .colorScheme
                                              .primaryContainer
                                        : Theme.of(context)
                                              .colorScheme
                                              .surfaceContainerHighest,
                                    child: Icon(
                                      Icons.help_outline,
                                      color: q.isActive
                                          ? Theme.of(context)
                                                .colorScheme
                                                .onPrimaryContainer
                                          : Theme.of(context)
                                                .colorScheme
                                                .onSurfaceVariant,
                                    ),
                                  ),
                                  const SizedBox(width: AppSpacing.md),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          q.code,
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleSmall
                                              ?.copyWith(
                                                fontWeight: FontWeight.bold,
                                              ),
                                        ),
                                        if (q.topic.isNotEmpty) ...[
                                          const SizedBox(height: 2),
                                          Text(
                                            q.topic,
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
                                      ],
                                    ),
                                  ),
                                  StatusBadge(
                                    text: q.isActive ? 'ACTIVE' : 'INACTIVE',
                                    status: q.isActive
                                        ? BadgeStatus.success
                                        : BadgeStatus.neutral,
                                  ),
                                  const SizedBox(width: AppSpacing.xs),
                                  const Icon(Icons.chevron_right, size: 20),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
