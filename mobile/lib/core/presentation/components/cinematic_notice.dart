import 'package:flutter/material.dart';

/// Persistent inline feedback; its lifetime belongs to the caller's state.
class CinematicNotice extends StatelessWidget {
  final String message;
  final IconData icon;
  final bool isError;
  final Widget? child;

  const CinematicNotice({
    super.key,
    required this.message,
    this.icon = Icons.info_outline_rounded,
    this.isError = false,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final foreground = isError ? colors.onErrorContainer : colors.onSurface;
    return Semantics(
      liveRegion: isError,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: isError ? colors.errorContainer : colors.surfaceContainer,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: colors.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, color: foreground, size: 22),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      message,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: foreground,
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
              if (child != null) ...[const SizedBox(height: 12), child!],
            ],
          ),
        ),
      ),
    );
  }
}
