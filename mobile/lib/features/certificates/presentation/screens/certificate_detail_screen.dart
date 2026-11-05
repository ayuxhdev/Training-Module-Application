import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
import 'package:training_app/core/presentation/components/cinematic_notice.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/presentation/components/loading_view.dart';
import 'package:training_app/core/presentation/formatters/date_labels.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/features/certificates/domain/models/certificate_detail.dart';
import 'package:training_app/features/certificates/presentation/controllers/certificate_controller.dart';
import 'package:training_app/features/learning/presentation/controllers/learning_controller.dart';

class CertificateDetailScreen extends ConsumerWidget {
  final int certificateId;
  const CertificateDetailScreen({super.key, required this.certificateId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = certificateDetailProvider(certificateId);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Certificate'),
        actions: [
          IconButton(
            tooltip: 'Refresh certificate',
            style: IconButton.styleFrom(
              minimumSize: const Size.square(48),
              tapTargetSize: MaterialTapTargetSize.padded,
            ),
            onPressed: () => ref.invalidate(provider),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ref
          .watch(provider)
          .when(
            skipLoadingOnRefresh: false,
            skipLoadingOnReload: false,
            loading: () =>
                const LoadingView(message: 'Loading certificate details...'),
            error: (error, _) => ApiErrorView(
              error: error,
              onRetry: () => ref.invalidate(provider),
            ),
            data: (certificate) {
              if (certificate == null) return const LoadingView();
              return RefreshIndicator(
                onRefresh: () async {
                  try {
                    await ref.refresh(provider.future).then<void>((_) {});
                  } catch (_) {
                    // Display the failure through the existing authorized provider.
                  }
                },
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: AppSpacing.pagePadding,
                  children: [
                    Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 760),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _CertificateRecord(certificate: certificate),
                            const SizedBox(height: AppSpacing.md),
                            _CompletionRecord(
                              key: ValueKey((
                                certificate.id,
                                certificate.assignmentId,
                              )),
                              assignmentId: certificate.assignmentId,
                            ),
                            const SizedBox(height: AppSpacing.md),
                            const CinematicNotice(
                              message: "Need a printed copy? Sign in to the Garden's Need website, open this certificate and choose Print certificate.",
                              icon: Icons.info_outline,
                            ),
                            const SizedBox(height: AppSpacing.md),
                            OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size.fromHeight(48),
                              ),
                              onPressed: () =>
                                  context.go('/profile/certificates'),
                              icon: const Icon(Icons.arrow_back),
                              label: const Text('All certificates'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
    );
  }
}

class _CertificateRecord extends StatelessWidget {
  final CertificateDetail certificate;
  const _CertificateRecord({required this.certificate});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final inset = constraints.maxWidth < 360
            ? AppSpacing.md
            : AppSpacing.lg;
        return DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: certificate.isRevoked
                  ? colors.error.withValues(alpha: 0.45)
                  : colors.primary.withValues(alpha: 0.4),
              width: 1.5,
            ),
          ),
          child: Padding(
            padding: EdgeInsets.all(inset),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    ExcludeSemantics(
                      child: Icon(
                        Icons.workspace_premium_outlined,
                        color: colors.primary,
                        size: 32,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        "Garden's Need",
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.lg),
                Semantics(
                  header: true,
                  child: Text(
                    'Certificate of completion',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                CinematicNotice(
                  message: certificate.isRevoked
                      ? 'Revoked certificate. This credential is no longer valid.'
                      : "Issued certificate. Not revoked in Garden's Need records.",
                  isError: certificate.isRevoked,
                  icon: certificate.isRevoked
                      ? Icons.block
                      : Icons.verified_outlined,
                ),
                const SizedBox(height: AppSpacing.lg),
                _Field(
                  label: 'Awarded to',
                  value: certificate.employeeName,
                  prominent: true,
                ),
                _Field(label: 'Employee code', value: certificate.employeeCode),
                const Divider(height: AppSpacing.lg),
                _Field(
                  label: 'For completing',
                  value: certificate.trainingTitle,
                  prominent: true,
                ),
                _Facts(
                  fields: [
                    _Field(
                      label: 'Training version',
                      value: 'Version ${certificate.versionNumber}',
                    ),
                    _Field(
                      label: 'Issued',
                      value: localDateLabel(certificate.issuedAt),
                    ),
                  ],
                ),
                _Field(
                  label: 'Certificate number',
                  value: certificate.certificateNumber,
                  monospace: true,
                ),
                if (certificate.isRevoked && certificate.revokedAt != null)
                  _Field(
                    label: 'Revoked on',
                    value: localDateLabel(certificate.revokedAt!),
                    isError: true,
                  ),
                const Divider(height: AppSpacing.lg),
                Text(
                  'Employee and training details are preserved as recorded at issuance. Refresh to check the latest certificate status.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Read completion timestamps only when requested; never infer them from issuance.
class _CompletionRecord extends ConsumerStatefulWidget {
  final int assignmentId;
  const _CompletionRecord({super.key, required this.assignmentId});
  @override
  ConsumerState<_CompletionRecord> createState() => _CompletionRecordState();
}

class _CompletionRecordState extends ConsumerState<_CompletionRecord> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return CustomCard(
      padding: EdgeInsets.zero,
      child: ExpansionTile(
        expansionAnimationStyle: MediaQuery.disableAnimationsOf(context)
            ? AnimationStyle.noAnimation
            : null,
        title: const Text('Completion record'),
        subtitle: const Text('View completion date and training status'),
        onExpansionChanged: (expanded) => setState(() => _expanded = expanded),
        children: [
          if (_expanded)
            Padding(
              padding: AppSpacing.pagePadding,
              child: ref
                  .watch(assignmentDetailProvider(widget.assignmentId))
                  .when(
                    skipLoadingOnRefresh: false,
                    skipLoadingOnReload: false,
                    loading: () => const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('Loading completion record...'),
                    ),
                    error: (error, _) => ApiErrorView(
                      error: error,
                      onRetry: () => ref.invalidate(
                        assignmentDetailProvider(widget.assignmentId),
                      ),
                    ),
                    data: (assignment) => Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _Field(
                          label: 'Training status',
                          value: assignment.status.replaceAll('_', ' '),
                        ),
                        _Field(
                          label: 'Completed on',
                          value: assignment.completedAt == null
                              ? 'Not recorded'
                              : localDateLabel(assignment.completedAt!),
                        ),
                      ],
                    ),
                  ),
            ),
        ],
      ),
    );
  }
}

class _Facts extends StatelessWidget {
  final List<Widget> fields;
  const _Facts({required this.fields});
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final largeText = MediaQuery.textScalerOf(context).scale(14) > 14 * 1.3;
      if (constraints.maxWidth < 340 || largeText) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: fields,
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: fields[0]),
          const SizedBox(width: AppSpacing.md),
          Expanded(child: fields[1]),
        ],
      );
    },
  );
}

class _Field extends StatelessWidget {
  final String label;
  final String value;
  final bool monospace;
  final bool prominent;
  final bool isError;
  const _Field({
    required this.label,
    required this.value,
    this.monospace = false,
    this.prominent = false,
    this.isError = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: isError ? colors.error : colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          SelectableText(
            value,
            style:
                (prominent
                        ? theme.textTheme.titleLarge
                        : theme.textTheme.bodyLarge)
                    ?.copyWith(
                      fontWeight: prominent ? FontWeight.w600 : null,
                      fontFamily: monospace ? 'monospace' : null,
                      color: isError ? colors.error : colors.onSurface,
                    ),
          ),
        ],
      ),
    );
  }
}
