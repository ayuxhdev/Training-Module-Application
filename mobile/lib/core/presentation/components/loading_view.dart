import 'package:flutter/material.dart';

import 'feedback_panel.dart';

class LoadingView extends StatelessWidget {
  final String? message;
  final String? title;

  final Widget? branding;

  const LoadingView({super.key, this.message, this.title, this.branding});

  @override
  Widget build(BuildContext context) {
    final indicator = MediaQuery.disableAnimationsOf(context)
        ? Icon(
            Icons.hourglass_empty_rounded,
            size: 40,
            color: Theme.of(context).colorScheme.primary,
          )
        : const CircularProgressIndicator();
    final mark = branding;

    return FeedbackPanel(
      announce: true,
      visual: mark == null
          ? indicator
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [mark, const SizedBox(height: 16), indicator],
            ),
      title: title,
      message: message ?? 'Loading…',
    );
  }
}
