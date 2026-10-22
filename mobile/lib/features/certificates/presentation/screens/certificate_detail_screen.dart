import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/presentation/components/cinematic_components.dart';
import 'package:training_app/core/presentation/components/cinematic_notice.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
import 'package:training_app/core/presentation/formatters/date_labels.dart';
import 'package:training_app/core/presentation/components/loading_view.dart';
import 'package:training_app/features/certificates/presentation/controllers/certificate_controller.dart';

class CertificateDetailScreen extends ConsumerWidget {
  final int certificateId;
  const CertificateDetailScreen({super.key, required this.certificateId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = certificateDetailProvider(certificateId);
    return Scaffold(
      appBar: AppBar(title: const Text('Certificate')),
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
                    // The provider renders the refresh failure with a retry action.
                  }
                },
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(16),
                  children: [
                    CinematicHero(
                      eyebrow: 'Certificate of completion',
                      title: certificate.trainingTitle,
                      subtitle: 'A record of your completed training.',
                      icon: certificate.isRevoked
                          ? Icons.block
                          : Icons.workspace_premium_outlined,
                      child: CinematicNotice(
                        message: certificate.isRevoked ? 'Revoked' : 'Issued',
                        isError: certificate.isRevoked,
                        icon: certificate.isRevoked
                            ? Icons.block
                            : Icons.verified_outlined,
                      ),
                    ),
                    const SizedBox(height: 24),
                    const SectionHeading(
                      'Certificate details',
                      subtitle: 'Your historical training record.',
                    ),
                    CustomCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _Field(
                            label: 'Certificate number',
                            value: certificate.certificateNumber,
                          ),
                          _Field(
                            label: 'Awarded to',
                            value: certificate.employeeName,
                          ),
                          _Field(
                            label: 'Employee code',
                            value: certificate.employeeCode,
                          ),
                          _Field(
                            label: 'Training version',
                            value: '${certificate.versionNumber}',
                          ),
                          _Field(
                            label: 'Issued',
                            value: localDateLabel(certificate.issuedAt),
                          ),
                          if (certificate.revokedAt != null)
                            _Field(
                              label: 'Revoked on',
                              value: localDateLabel(certificate.revokedAt!),
                            ),
                          const SizedBox(height: 12),
                          const CinematicNotice(
                            message: 'These details reflect the employee and training recorded when this certificate was issued.',
                            icon: Icons.history_rounded,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton(
                      onPressed: () => context.go('/profile/certificates'),
                      child: const Text('All certificates'),
                    ),
                  ],
                ),
              );
            },
          ),
    );
  }
}

class _Field extends StatelessWidget {
  final String label;
  final String value;
  const _Field({required this.label, required this.value});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.labelLarge
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 4),
        SelectableText(value, style: Theme.of(context).textTheme.bodyLarge),
      ],
    ),
  );
}
