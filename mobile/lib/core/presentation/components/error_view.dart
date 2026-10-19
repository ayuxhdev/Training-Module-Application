import 'package:flutter/material.dart';
import 'package:training_app/core/presentation/components/primary_button.dart';

import 'feedback_panel.dart';

class ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;
  final String retryLabel;
  final String? title;

  const ErrorView({
    super.key,
    required this.message,
    this.onRetry,
    this.retryLabel = 'Retry',
    this.title,
  });

  @override
  Widget build(BuildContext context) {
    return FeedbackPanel(
      announce: true,
      visual: Icon(
        Icons.error_outline,
        size: 48,
        color: Theme.of(context).colorScheme.error,
      ),
      title: title,
      message: message,
      action: onRetry == null
          ? null
          : PrimaryButton(text: retryLabel, onPressed: onRetry),
    );
  }
}
