import 'package:flutter/material.dart';

import 'feedback_panel.dart';

class EmptyView extends StatelessWidget {
  final String message;
  final IconData icon;
  final String? title;
  final Widget? action;

  const EmptyView({
    super.key,
    required this.message,
    this.icon = Icons.inbox_outlined,
    this.title,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return FeedbackPanel(
      visual: Icon(
        icon,
        size: 48,
        color: Theme.of(context).colorScheme.primary,
      ),
      title: title,
      message: message,
      action: action,
    );
  }
}
