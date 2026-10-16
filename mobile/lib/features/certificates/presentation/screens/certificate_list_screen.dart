import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/presentation/components/empty_view.dart';
import 'package:training_app/core/presentation/components/error_view.dart';
import 'package:training_app/core/presentation/components/loading_view.dart';
import 'package:training_app/features/certificates/presentation/controllers/certificate_controller.dart';

class CertificateListScreen extends ConsumerWidget {
  const CertificateListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('My Certificates')),
      body: ref
          .watch(certificateListProvider)
          .when(
            skipLoadingOnRefresh: false,
            skipLoadingOnReload: false,
            loading: () => const LoadingView(),
            error: (error, _) => SingleChildScrollView(
              child: ErrorView(
                message: error is ApiError
                    ? error.message
                    : 'Unable to load certificates.',
                onRetry: () => ref.invalidate(certificateListProvider),
              ),
            ),
            data: (certificates) => RefreshIndicator(
              onRefresh: () async {
                try {
                  await ref
                      .refresh(certificateListProvider.future)
                      .then<void>((_) {});
                } catch (_) {
                  // The provider renders the refresh failure with a retry action.
                }
              },
              child: ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                itemCount: certificates.isEmpty ? 1 : certificates.length,
                itemBuilder: (context, index) {
                  if (certificates.isEmpty) {
                    return const EmptyView(
                      message: 'No certificates earned yet. Complete your assigned training to earn a certificate.',
                      icon: Icons.workspace_premium_outlined,
                    );
                  }
                  final certificate = certificates[index];
                  return Card(
                    margin: const EdgeInsets.only(bottom: 16),
                    clipBehavior: Clip.antiAlias,
                    child: ListTile(
                      contentPadding: const EdgeInsets.all(16),
                      leading: Icon(
                        certificate.isRevoked
                            ? Icons.block
                            : Icons.workspace_premium_outlined,
                        color: certificate.isRevoked
                            ? theme.colorScheme.error
                            : theme.colorScheme.primary,
                      ),
                      title: Text(
                        certificate.trainingTitle,
                        style: theme.textTheme.titleMedium,
                      ),
                      subtitle: Text(
                        '${certificate.certificateNumber}\nIssued ${certificateDate(certificate.issuedAt)}\n${certificate.isRevoked ? 'Revoked' : 'Issued'}',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => context.push(
                        '/profile/certificates/${certificate.id}',
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
    );
  }
}

String certificateDate(DateTime value) {
  final date = value.toLocal();
  return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}
