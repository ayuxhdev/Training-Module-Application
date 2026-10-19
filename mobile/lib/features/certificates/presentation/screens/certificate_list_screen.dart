import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/presentation/components/cinematic_components.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/core/presentation/components/empty_view.dart';
import 'package:training_app/core/presentation/components/error_view.dart';
import 'package:training_app/core/presentation/components/loading_view.dart';
import 'package:training_app/features/certificates/presentation/controllers/certificate_controller.dart';

class CertificateListScreen extends ConsumerWidget {
  const CertificateListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('My Certificates')),
      body: ref
          .watch(certificateListProvider)
          .when(
            skipLoadingOnRefresh: false,
            skipLoadingOnReload: false,
            loading: () =>
                const LoadingView(message: 'Loading your certificates...'),
            error: (error, _) => SingleChildScrollView(
              child: ErrorView(
                title: 'Certificates unavailable',
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
                itemCount: certificates.isEmpty ? 2 : certificates.length + 1,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return const Padding(
                      padding: EdgeInsets.only(bottom: 24),
                      child: CinematicHero(
                        eyebrow: 'Your achievements',
                        title: 'Learning worth celebrating.',
                        subtitle: 'View your issued certificates and their recorded training details.',
                        icon: Icons.workspace_premium_outlined,
                      ),
                    );
                  }
                  if (certificates.isEmpty) {
                    return const EmptyView(
                      message: 'No certificates earned yet. Complete your assigned training to earn a certificate.',
                      icon: Icons.workspace_premium_outlined,
                    );
                  }
                  final certificate = certificates[index - 1];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: LearningCard(
                      title: certificate.trainingTitle,
                      subtitle: certificate.certificateNumber,
                      status: certificate.isRevoked ? 'Revoked' : 'Issued',
                      badgeStatus: certificate.isRevoked
                          ? BadgeStatus.error
                          : BadgeStatus.success,
                      icon: certificate.isRevoked
                          ? Icons.block
                          : Icons.workspace_premium_outlined,
                      footer: Text(
                        'Issued ${certificateDate(certificate.issuedAt)}',
                      ),
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
