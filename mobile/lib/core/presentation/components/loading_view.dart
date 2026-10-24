import 'package:flutter/material.dart';

import 'feedback_panel.dart';

class LoadingView extends StatelessWidget {
  final String? message;
  final String? title;

  const LoadingView({super.key, this.message, this.title});

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
      title: title,
      message: message ?? 'Loading…',
    );
  }
}
