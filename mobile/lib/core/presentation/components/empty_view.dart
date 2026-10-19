import 'package:flutter/material.dart';

import 'feedback_panel.dart';

class EmptyView extends StatelessWidget {
  final String message;
  final IconData icon;

  const EmptyView({
    super.key,
    required this.message,
    this.icon = Icons.inbox_outlined,
  });

  @override
  Widget build(BuildContext context) {
    return FeedbackPanel(
      visual: Icon(
        icon,
        size: 48,
        color: Theme.of(context).colorScheme.primary,
      ),
      message: message,
    );
  }
}
