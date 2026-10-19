import 'package:flutter/material.dart';

import 'feedback_panel.dart';

class LoadingView extends StatelessWidget {
  final String? message;

  const LoadingView({super.key, this.message});

  @override
  Widget build(BuildContext context) {
    return FeedbackPanel(
      announce: true,
      visual: MediaQuery.disableAnimationsOf(context)
          ? Icon(
              Icons.hourglass_empty_rounded,
              size: 40,
              color: Theme.of(context).colorScheme.primary,
            )
          : const CircularProgressIndicator(),
      message: message ?? 'Loading…',
    );
  }
}
