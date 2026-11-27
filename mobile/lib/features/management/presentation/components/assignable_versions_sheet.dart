import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
import 'package:training_app/core/presentation/components/empty_view.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/presentation/controllers/management_controller.dart';

void showAssignableVersions(BuildContext context, AuthAuthenticated auth) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.75,
      child: _AssignableVersionsSheet(account: managementAccount(auth)),
    ),
  );
}

class _AssignableVersionsSheet extends ConsumerWidget {
  const _AssignableVersionsSheet({required this.account});

  final String? account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    if (auth is! AuthAuthenticated ||
        managementAccount(auth) != account ||
        !canAssignTraining(auth.identity)) {
      return const Center(child: Text('Assignable versions are unavailable.'));
    }

    const request = (page: 1, search: null);
    final versions = ref.watch(assignableTrainingVersionsProvider(request));
    return Column(
      children: [
        ListTile(
          title: Semantics(
            header: true,
            child: const Text('Assignable versions'),
          ),
          trailing: IconButton(
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
          ),
        ),
        Expanded(
          child: versions.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => ListView(
              padding: AppSpacing.pagePadding,
              children: [
                ApiErrorView(
                  error: error,
                  onRetry: () => ref.invalidate(
                    assignableTrainingVersionsProvider(request),
                  ),
                ),
              ],
            ),
            data: (page) => ListView(
              padding: AppSpacing.pagePadding,
              children: [
                if (page.items.isEmpty)
                  const EmptyView(
                    message:
                        'No published training versions currently available.',
                    icon: Icons.school_outlined,
                  )
                else ...[
                  Text(
                    page.items.length < page.count
                        ? 'Showing ${page.items.length} of ${page.count}'
                        : '${page.count} available',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  for (final version in page.items)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(version.title),
                      subtitle: Text(
                        [
                          '${version.trainingTitle} · ${version.trainingCode}',
                          'Version ${version.versionNumber} · ${version.status}',
                          if (version.description.isNotEmpty)
                            version.description,
                        ].join('\n'),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}
