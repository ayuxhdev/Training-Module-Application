import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/certificates/data/services/certificate_print_service.dart';
import 'package:training_app/features/certificates/domain/models/certificate_print_data.dart';
import 'package:training_app/features/management/presentation/controllers/management_controller.dart';

/// Prints a local PDF copy only after refreshing the authorized server record.
class CertificatePrintSection extends ConsumerStatefulWidget {
  final CertificatePrintData printData;

  final Future<CertificatePrintData> Function(CancelToken) refresh;

  const CertificatePrintSection({
    super.key,
    required this.printData,
    required this.refresh,
  });

  @override
  ConsumerState<CertificatePrintSection> createState() =>
      _CertificatePrintSectionState();
}

class _CertificatePrintSectionState
    extends ConsumerState<CertificatePrintSection> {
  bool _isPrinting = false;
  int _generation = 0;
  CancelToken? _request;

  bool _current(int generation, String owner) =>
      mounted &&
      generation == _generation &&
      managementAccount(ref.read(authControllerProvider)) == owner;

  void _cancelRefresh() {
    _generation++;
    _request?.cancel('Certificate print context changed.');
  }

  @override
  void didUpdateWidget(covariant CertificatePrintSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.printData.certificateId != widget.printData.certificateId) {
      _cancelRefresh();
      _request = null;
      _isPrinting = false;
    }
  }

  @override
  void dispose() {
    _cancelRefresh();
    super.dispose();
  }

  Future<void> _handlePrint() async {
    if (!mounted || _isPrinting) return;
    final owner = managementAccount(ref.read(authControllerProvider));
    if (owner == null) return;
    final generation = ++_generation;
    final certificateId = widget.printData.certificateId;
    final requests = CancelToken();
    _request = requests;
    setState(() => _isPrinting = true);

    try {
      final service = ref.read(certificatePrintServiceProvider);
      final refreshed = await widget
          .refresh(requests)
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () {
              requests.cancel('Certificate refresh deadline exceeded.');
              throw ApiError.timeout();
            },
          );
      if (!_current(generation, owner) || requests.isCancelled) return;
      if (refreshed.certificateId != certificateId) {
        throw const FormatException(
          'Unexpected certificate in print response.',
        );
      }
      // Only this fresh response may reach PDF generation. No cached fallback.
      final printed = await service.printCertificate(
        refreshed,
        canPrint: () => _current(generation, owner),
      );
      if (!printed && mounted && _current(generation, owner)) {
        // Native print dialog was cancelled/dismissed by user or spooler aborted.
        // Standard user cancellation completes cleanly without error banners.
      }
    } catch (error) {
      if (!mounted || !_current(generation, owner)) return;
      if (error is DioException && CancelToken.isCancel(error)) return;
      if (error is ApiError && error.code == 'print_cancelled') return;
      final status = error is ApiError ? error.statusCode : null;
      final String message;
      if (status == 401) {
        message = 'Your session has ended. Sign in again to print.';
      } else if (status == 403) {
        message = 'You no longer have access to this certificate.';
      } else if (status == 404) {
        message = 'This certificate is no longer available.';
      } else if (error is ApiError &&
          (error.code == 'network_failure' || error.code == 'timeout')) {
        message = 'Could not refresh the certificate. Check your connection and try again.';
      } else {
        message =
            'Unable to prepare certificate for printing. Please try again.';
      }
      final messenger = ScaffoldMessenger.of(context);
      messenger.clearSnackBars();
      messenger.showSnackBar(
        SnackBar(
          content: Text(message),
          action: status == 401 || status == 403 || status == 404
              ? null
              : SnackBarAction(label: 'Retry', onPressed: _handlePrint),
        ),
      );
    } finally {
      if (mounted && identical(_request, requests)) {
        _request = null;
        setState(() => _isPrinting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    ref.listen<AuthState>(authControllerProvider, (previous, next) {
      if (managementAccount(previous ?? AuthInitial()) !=
          managementAccount(next)) {
        _cancelRefresh();
      }
    });
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isRevoked = widget.printData.isRevoked;

    return CustomCard(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.print_outlined,
                  color: isRevoked ? colors.error : colors.primary,
                  size: 24,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    'Print & PDF Export',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              isRevoked
                  ? 'Print or export this certificate record as a PDF. The generated document will clearly indicate that this credential has been REVOKED.'
                  : 'Print or save a copy of this certificate. Its current server status will be checked before printing.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                backgroundColor: isRevoked
                    ? colors.errorContainer
                    : colors.primary,
                foregroundColor: isRevoked
                    ? colors.onErrorContainer
                    : colors.onPrimary,
              ),
              onPressed: _isPrinting || auth is! AuthAuthenticated
                  ? null
                  : _handlePrint,
              icon: _isPrinting
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: isRevoked
                            ? colors.onErrorContainer
                            : colors.onPrimary,
                      ),
                    )
                  : const Icon(Icons.print),
              label: Text(
                _isPrinting ? 'Preparing document...' : 'Print / Save as PDF',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
