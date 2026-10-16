import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/presentation/components/error_view.dart';
import 'package:training_app/core/presentation/components/loading_view.dart';
import 'package:training_app/features/certificates/presentation/controllers/certificate_controller.dart';

import 'certificate_list_screen.dart';

class CertificateDetailScreen extends ConsumerWidget {
  final int certificateId;
  const CertificateDetailScreen({super.key, required this.certificateId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = certificateDetailProvider(certificateId);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Certificate')),
      body: ref
          .watch(provider)
          .when(
            skipLoadingOnRefresh: false,
            skipLoadingOnReload: false,
            loading: () => const LoadingView(),
            error: (error, _) => SingleChildScrollView(
              child: ErrorView(
                message: error is ApiError
                    ? error.message
                    : 'Unable to load this certificate.',
                onRetry: () => ref.invalidate(provider),
              ),
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
                    CustomCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Icon(
                            certificate.isRevoked
                                ? Icons.block
                                : Icons.workspace_premium_outlined,
                            size: 56,
                            color: certificate.isRevoked
                                ? theme.colorScheme.error
                                : theme.colorScheme.primary,
                          ),
                          const SizedBox(height: 16),
                          Semantics(
                            header: true,
                            child: Text(
                              certificate.trainingTitle,
                              style: theme.textTheme.headlineSmall,
                              textAlign: TextAlign.center,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            certificate.isRevoked ? 'Revoked' : 'Issued',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: certificate.isRevoked
                                  ? theme.colorScheme.error
                                  : theme.colorScheme.primary,
                            ),
                          ),
                          const Divider(height: 32),
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
                            value: certificateDate(certificate.issuedAt),
                          ),
                          if (certificate.revokedAt != null)
                            _Field(
                              label: 'Revoked on',
                              value: certificateDate(certificate.revokedAt!),
                            ),
                          const SizedBox(height: 12),
                          const Text(
                            'These details reflect the employee and training recorded when this certificate was issued.',
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
