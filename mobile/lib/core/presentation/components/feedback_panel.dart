import 'package:flutter/material.dart';

import 'custom_card.dart';

/// Scrollable even on short screens, without fixed-height feedback or actions.
class FeedbackPanel extends StatelessWidget {
  final Widget visual;
  final String? title, message;
  final Widget? action;
  final bool announce;
  const FeedbackPanel({
    super.key,
    required this.visual,
    this.title,
    this.message,
    this.action,
    this.announce = false,
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
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: CustomCard(
                  padding: const EdgeInsets.all(24),
                  child: Semantics(
                    liveRegion: announce,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(child: visual),
                        if (title != null) ...[
                          const SizedBox(height: 20),
                          Semantics(
                            header: true,
                            child: Text(
                              title!,
                              style: theme.textTheme.titleLarge,
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                        if (message != null) ...[
                          const SizedBox(height: 16),
                          Text(
                            message!,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              height: 1.5,
                            ),
                          ),
                        ],
                        if (action != null) ...[
                          const SizedBox(height: 24),
                          action!,
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
