import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';

import 'error_view.dart';

/// Recovery for read failures. Mutations keep their feature-specific reconciliation.
class ApiErrorView extends ConsumerWidget {
  final Object error;
  final VoidCallback? onRetry;
  const ApiErrorView({super.key, required this.error, this.onRetry});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final failure = error is ApiError
        ? error as ApiError
        : ApiError.unexpected();
    final denied = failure.statusCode == 401 || failure.statusCode == 403;
    final retryable =
        failure.statusCode == null ||
        failure.statusCode! >= 500 ||
        failure.statusCode == 408 ||
        failure.statusCode == 429;
    final title = denied
        ? 'Sign in required'
        : switch (failure.code) {
            'network_failure' => 'Connection unavailable',
            'timeout' => 'Request timed out',
            _ => 'Unable to load this page',
          };
    return ErrorView(
      title: title,
      message: failure.message,
      retryLabel: denied ? 'Sign in again' : 'Retry',
      onRetry: denied
          ? () {
              ref.read(authControllerProvider.notifier).logout();
            }
          : retryable
          ? onRetry
          : null,
    );
  }
}
