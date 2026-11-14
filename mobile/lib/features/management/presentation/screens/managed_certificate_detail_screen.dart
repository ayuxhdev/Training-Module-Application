import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
import 'package:training_app/core/presentation/components/cinematic_notice.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/presentation/components/loading_view.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/core/presentation/formatters/date_labels.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';
import 'package:training_app/features/management/presentation/controllers/management_controller.dart';

enum RevocationSubmitResult { success, alreadyRevoked, refreshFailed }

class ManagedCertificateDetailScreen extends ConsumerStatefulWidget {
  final int certificateId;
  final ManagedCertificate? initialCertificate;

  const ManagedCertificateDetailScreen({
    super.key,
    required this.certificateId,
    this.initialCertificate,
  });

  @override
  ConsumerState<ManagedCertificateDetailScreen> createState() =>
      _ManagedCertificateDetailScreenState();
}

class _ManagedCertificateDetailScreenState
    extends ConsumerState<ManagedCertificateDetailScreen> {
  Future<void> _showRevokeDialog(ManagedCertificateDetail cert) async {
    final messenger = ScaffoldMessenger.of(context);
    final initialAuth = ref.read(authControllerProvider);
    final account = managementAccount(initialAuth);
    if (account == null ||
        initialAuth is! AuthAuthenticated ||
        !canRevokeCertificate(initialAuth.identity)) {
      return;
    }
    String? alreadyRevokedMessage;

    final result = await showDialog<RevocationSubmitResult>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => _RevocationDialog(
        cert: cert,
        onRevoke: (reason) async {
          try {
            if (!mounted ||
                managementAccount(ref.read(authControllerProvider)) !=
                    account) {
              throw ApiError(
                message: 'The account changed. Reopen the certificate before revoking it.',
                statusCode: 403,
              );
            }
            await ref
                .read(certificateRevocationMutationProvider)
                .revoke(
                  certificateId: cert.id,
                  reason: reason,
                  expectedAccount: account,
                );
            if (mounted) {
              ref.invalidate(
                managedCertificateDetailProvider(widget.certificateId),
              );
              ref.invalidate(managedCertificatesProvider);
            }
            return RevocationSubmitResult.success;
          } on ApiError catch (error) {
            if (error.statusCode == 409) {
              alreadyRevokedMessage = error.message;
              final ManagedCertificateDetail refreshed;
              try {
                refreshed = await ref.refresh(
                  managedCertificateDetailProvider(widget.certificateId).future,
                );
                ref.invalidate(managedCertificatesProvider);
              } catch (_) {
                return RevocationSubmitResult.refreshFailed;
              }

              final currentAuth = ref.read(authControllerProvider);
              if (managementAccount(currentAuth) != account ||
                  currentAuth is! AuthAuthenticated ||
                  !canViewCertificates(currentAuth.identity)) {
                return RevocationSubmitResult.refreshFailed;
              }

              if (refreshed.isRevoked) {
                return RevocationSubmitResult.alreadyRevoked;
              }
              // Concurrency/locking conflict, certificate still valid on server
              rethrow;
            }
            rethrow;
          }
        },
      ),
    );

    if (!mounted) return;
    final currentAuth = ref.read(authControllerProvider);
    if (managementAccount(currentAuth) != account) return;

    if (result == RevocationSubmitResult.success) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Certificate revoked successfully.')),
      );
    } else if (result == RevocationSubmitResult.alreadyRevoked) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            alreadyRevokedMessage?.isNotEmpty == true
                ? alreadyRevokedMessage!
                : 'This certificate was already revoked.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    if (auth is! AuthAuthenticated || !canViewCertificates(auth.identity)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Certificate details')),
        body: const Center(
          child: Text('You do not have permission to view certificates.'),
        ),
      );
    }

    final identity = auth.identity;
    final detailAsync = ref.watch(
      managedCertificateDetailProvider(widget.certificateId),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Certificate details'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(
              managedCertificateDetailProvider(widget.certificateId),
            ),
          ),
        ],
      ),
      body: detailAsync.when(
        loading: () =>
            const LoadingView(message: 'Loading certificate details...'),
        error: (error, _) => ApiErrorView(
          error: error,
          onRetry: () => ref.invalidate(
            managedCertificateDetailProvider(widget.certificateId),
          ),
        ),
        data: (cert) {
          final theme = Theme.of(context);
          final colors = theme.colorScheme;
          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(
                managedCertificateDetailProvider(widget.certificateId),
              );
              await ref.read(
                managedCertificateDetailProvider(widget.certificateId).future,
              );
            },
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.md),
              children: [
                CinematicNotice(
                  message: cert.isRevoked
                      ? 'Revoked certificate. This credential is no longer valid.'
                      : "Issued certificate. Not revoked in Garden's Need records.",
                  isError: cert.isRevoked,
                  icon: cert.isRevoked ? Icons.block : Icons.verified_outlined,
                ),
                const SizedBox(height: AppSpacing.md),
                CustomCard(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              "Garden's Need",
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            StatusBadge(
                              text: cert.isRevoked ? 'Revoked' : 'Valid',
                              status: cert.isRevoked
                                  ? BadgeStatus.error
                                  : BadgeStatus.success,
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.lg),
                        _DetailField(
                          label: 'Certificate number',
                          value: cert.certificateNumber,
                          isMonospace: true,
                        ),
                        const Divider(height: AppSpacing.lg),
                        _DetailField(
                          label: 'Awarded to',
                          value: cert.employeeName,
                          isProminent: true,
                        ),
                        _DetailField(
                          label: 'Employee code',
                          value: cert.employeeCode,
                        ),
                        const Divider(height: AppSpacing.lg),
                        _DetailField(
                          label: 'Training title',
                          value: cert.trainingTitle,
                          isProminent: true,
                        ),
                        _DetailField(
                          label: 'Training version',
                          value: 'Version ${cert.versionNumber}',
                        ),
                        _DetailField(
                          label: 'Issued at',
                          value: localDateLabel(cert.issuedAt),
                        ),
                        if (cert.isRevoked) ...[
                          const Divider(height: AppSpacing.lg),
                          if (cert.revokedAt != null)
                            _DetailField(
                              label: 'Revoked on',
                              value: localDateLabel(cert.revokedAt!),
                              isError: true,
                            ),
                          if (cert.revocationReason != null &&
                              cert.revocationReason!.isNotEmpty)
                            _DetailField(
                              label: 'Revocation reason',
                              value: cert.revocationReason!,
                              isError: true,
                            ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                const CinematicNotice(
                  message: "Need a printed copy? Sign in to the Garden's Need website, open this certificate and choose Print certificate.",
                  icon: Icons.info_outline,
                ),
                const SizedBox(height: AppSpacing.lg),
                if (!cert.isRevoked && canRevokeCertificate(identity))
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: colors.error,
                      foregroundColor: colors.onError,
                      minimumSize: const Size.fromHeight(48),
                    ),
                    icon: const Icon(Icons.block),
                    label: const Text('Revoke certificate'),
                    onPressed: () => _showRevokeDialog(cert),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _DetailField extends StatelessWidget {
  final String label;
  final String value;
  final bool isProminent;
  final bool isMonospace;
  final bool isError;

  const _DetailField({
    required this.label,
    required this.value,
    this.isProminent = false,
    this.isMonospace = false,
    this.isError = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: isProminent
                ? theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: isError ? colors.error : null,
                  )
                : theme.textTheme.bodyMedium?.copyWith(
                    fontFamily: isMonospace ? 'monospace' : null,
                    color: isError ? colors.error : null,
                    fontWeight: isError ? FontWeight.w500 : null,
                  ),
          ),
        ],
      ),
    );
  }
}

class _RevocationDialog extends StatefulWidget {
  final ManagedCertificateDetail cert;
  final Future<RevocationSubmitResult> Function(String reason) onRevoke;

  const _RevocationDialog({required this.cert, required this.onRevoke});

  @override
  State<_RevocationDialog> createState() => _RevocationDialogState();
}

class _RevocationDialogState extends State<_RevocationDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _reasonController;
  bool _isRevoking = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _reasonController = TextEditingController();
    _reasonController.addListener(() {
      if (_errorMessage != null) {
        setState(() => _errorMessage = null);
      }
    });
  }

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _isRevoking = true;
      _errorMessage = null;
    });
    try {
      final result = await widget.onRevoke(_reasonController.text);
      if (mounted) {
        Navigator.of(context).pop(result);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _isRevoking = false;
          _errorMessage = error is ApiError
              ? error.message
              : 'Failed to revoke certificate.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return PopScope(
      canPop: !_isRevoking,
      child: AlertDialog(
        title: const Text('Revoke certificate'),
        content: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_errorMessage != null) ...[
                  Semantics(
                    liveRegion: true,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(AppSpacing.sm),
                      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                      decoration: BoxDecoration(
                        color: colors.errorContainer,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: colors.error),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.error_outline,
                            size: 20,
                            color: colors.onErrorContainer,
                          ),
                          const SizedBox(width: AppSpacing.xs),
                          Expanded(
                            child: Text(
                              _errorMessage!,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colors.onErrorContainer,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                const Text(
                  'Revoking this certificate is a permanent action and cannot be undone. An authoritative audit record will be preserved.',
                  style: TextStyle(fontSize: 13),
                ),
                const SizedBox(height: AppSpacing.md),
                TextFormField(
                  controller: _reasonController,
                  enabled: !_isRevoking,
                  decoration: const InputDecoration(
                    labelText: 'Revocation reason *',
                    hintText: 'Enter reason for revoking this certificate',
                    border: OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                  maxLength: 1000,
                  maxLines: 3,
                  validator: (value) {
                    final trimmed = value?.trim() ?? '';
                    if (trimmed.isEmpty) {
                      return 'A revocation reason is required.';
                    }
                    if (trimmed.length > 1000) {
                      return 'Reason must be at most 1000 characters.';
                    }
                    return null;
                  },
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _isRevoking
                ? null
                : () => Navigator.of(context).pop(null),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: colors.error,
              foregroundColor: colors.onError,
            ),
            onPressed: _isRevoking ? null : _submit,
            child: _isRevoking
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Confirm Revocation'),
          ),
        ],
      ),
    );
  }
}
