import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
import 'package:training_app/core/presentation/components/content_skeleton.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/presentation/components/empty_view.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/core/presentation/formatters/date_labels.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/presentation/controllers/management_controller.dart';

class ManagedCertificateListScreen extends ConsumerStatefulWidget {
  const ManagedCertificateListScreen({super.key});

  @override
  ConsumerState<ManagedCertificateListScreen> createState() =>
      _ManagedCertificateListScreenState();
}

class _ManagedCertificateListScreenState
    extends ConsumerState<ManagedCertificateListScreen> {
  int _page = 1;
  String _search = '';
  bool? _isRevoked;
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

  void _onFilterChanged(bool? isRevoked) {
    setState(() {
      _isRevoked = isRevoked;
      _page = 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    if (auth is! AuthAuthenticated || !canViewCertificates(auth.identity)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Certificate management')),
        body: const Center(
          child: Text('You do not have permission to view certificates.'),
        ),
      );
    }

    final query = (
      page: _page,
      pageSize: 20,
      search: _search.isEmpty ? null : _search,
      isRevoked: _isRevoked,
    );
    final certificatesAsync = ref.watch(managedCertificatesProvider(query));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Certificate management'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(managedCertificatesProvider),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              children: [
                TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: 'Search by number, employee, or training...',
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
                Wrap(
                  spacing: AppSpacing.xs,
                  runSpacing: AppSpacing.xs,
                  children: [
                    FilterChip(
                      label: const Text('All'),
                      selected: _isRevoked == null,
                      onSelected: (_) => _onFilterChanged(null),
                    ),
                    FilterChip(
                      label: const Text('Valid'),
                      selected: _isRevoked == false,
                      onSelected: (_) => _onFilterChanged(false),
                    ),
                    FilterChip(
                      label: const Text('Revoked'),
                      selected: _isRevoked == true,
                      onSelected: (_) => _onFilterChanged(true),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: certificatesAsync.when(
              loading: () => const SingleChildScrollView(
                child: CardListSkeleton(
                  message: 'Loading certificates...',
                  compact: true,
                ),
              ),
              error: (error, _) {
                if (_page > 1 && error is ApiError && error.statusCode == 404) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) {
                      setState(() => _page = _page - 1);
                    }
                  });
                  return const SingleChildScrollView(
                    child: CardListSkeleton(
                      message: 'Returning to previous page...',
                      compact: true,
                    ),
                  );
                }
                return ApiErrorView(
                  error: error,
                  onRetry: () =>
                      ref.refresh(managedCertificatesProvider(query).future),
                );
              },
              data: (pageData) {
                final certificates = pageData.items;
                if (certificates.isEmpty) {
                  if (_page > 1) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) {
                        final targetPage = pageData.count > 0
                            ? ((pageData.count - 1) ~/ 20) + 1
                            : _page - 1;
                        setState(() => _page = targetPage > 0 ? targetPage : 1);
                      }
                    });
                    return const SingleChildScrollView(
                      child: CardListSkeleton(
                        message: 'Returning to previous page...',
                        compact: true,
                      ),
                    );
                  }
                  return const EmptyView(
                    message: 'No certificates found.',
                    icon: Icons.workspace_premium_outlined,
                  );
                }

                return RefreshIndicator(
                  onRefresh: () async {
                    ref.invalidate(managedCertificatesProvider(query));
                    await ref.read(managedCertificatesProvider(query).future);
                  },
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                    ),
                    itemCount: certificates.length + 1,
                    itemBuilder: (context, index) {
                      if (index == certificates.length) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: AppSpacing.md,
                          ),
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final textScaler = MediaQuery.textScalerOf(
                                context,
                              );
                              final isCompact =
                                  constraints.maxWidth < 360 ||
                                  textScaler.scale(1.0) > 1.3;
                              final prevButton = TextButton.icon(
                                icon: const Icon(Icons.chevron_left),
                                label: const Text('Previous'),
                                onPressed: _page > 1
                                    ? () => setState(() => _page--)
                                    : null,
                              );
                              final pageText = Text(
                                'Page $_page · ${pageData.count} total',
                                style: Theme.of(context).textTheme.bodySmall,
                                textAlign: TextAlign.center,
                              );
                              final nextButton = TextButton.icon(
                                label: const Text('Next'),
                                icon: const Icon(Icons.chevron_right),
                                onPressed: pageData.hasMore
                                    ? () => setState(() => _page++)
                                    : null,
                              );

                              if (isCompact) {
                                return Column(
                                  children: [
                                    pageText,
                                    const SizedBox(height: AppSpacing.xs),
                                    Wrap(
                                      alignment: WrapAlignment.center,
                                      spacing: AppSpacing.sm,
                                      children: [prevButton, nextButton],
                                    ),
                                  ],
                                );
                              }

                              return Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [prevButton, pageText, nextButton],
                              );
                            },
                          ),
                        );
                      }

                      final cert = certificates[index];
                      final theme = Theme.of(context);
                      final colors = theme.colorScheme;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                        child: CustomCard(
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () {
                              context.push(
                                '/workspace/certificates/${cert.id}',
                                extra: cert,
                              );
                            },
                            child: Padding(
                              padding: const EdgeInsets.all(AppSpacing.sm),
                              child: Row(
                                children: [
                                  CircleAvatar(
                                    backgroundColor: cert.isRevoked
                                        ? colors.errorContainer
                                        : colors.primaryContainer,
                                    child: Icon(
                                      cert.isRevoked
                                          ? Icons.block
                                          : Icons.workspace_premium_outlined,
                                      color: cert.isRevoked
                                          ? colors.onErrorContainer
                                          : colors.onPrimaryContainer,
                                    ),
                                  ),
                                  const SizedBox(width: AppSpacing.md),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                cert.certificateNumber,
                                                style: theme
                                                    .textTheme
                                                    .titleSmall
                                                    ?.copyWith(
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      fontFamily: 'monospace',
                                                    ),
                                              ),
                                            ),
                                            StatusBadge(
                                              text: cert.isRevoked
                                                  ? 'Revoked'
                                                  : 'Valid',
                                              status: cert.isRevoked
                                                  ? BadgeStatus.error
                                                  : BadgeStatus.success,
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          '${cert.employeeName} (${cert.employeeCode})',
                                          style: theme.textTheme.bodyMedium
                                              ?.copyWith(
                                                fontWeight: FontWeight.w500,
                                              ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          '${cert.trainingTitle} · v${cert.versionNumber}',
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                                color: colors.onSurfaceVariant,
                                              ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          'Issued: ${localDateLabel(cert.issuedAt)}',
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                                color: colors.onSurfaceVariant,
                                              ),
                                        ),
                                        if (cert.isRevoked &&
                                            cert.revokedAt != null) ...[
                                          const SizedBox(height: 2),
                                          Text(
                                            'Revoked: ${localDateLabel(cert.revokedAt!)}',
                                            style: theme.textTheme.bodySmall
                                                ?.copyWith(
                                                  color: colors.error,
                                                  fontWeight: FontWeight.w500,
                                                ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  const Icon(Icons.chevron_right),
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
