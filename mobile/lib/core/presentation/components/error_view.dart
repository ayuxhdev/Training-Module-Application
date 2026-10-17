import 'package:flutter/material.dart';
import 'package:training_app/core/presentation/components/primary_button.dart';

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
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: constraints.hasBoundedHeight ? constraints.maxHeight : 0,
          ),
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Semantics(
              liveRegion: true,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 48,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(height: 16),
                  if (title != null) ...[
                    Semantics(
                      header: true,
                      child: Text(
                        title!,
                        style: theme.textTheme.titleLarge,
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  Text(
                    message,
                    style: theme.textTheme.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                  if (onRetry != null) ...[
                    const SizedBox(height: 24),
                    PrimaryButton(text: retryLabel, onPressed: onRetry),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
