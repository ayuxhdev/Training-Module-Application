import 'package:flutter/material.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';

/// A restrained entrance, disabled for reduced motion. It never gates input.
class CinematicEntrance extends StatelessWidget {
  final Widget child;
  const CinematicEntrance({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      child: child,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, 8 * (1 - value)),
          child: child,
        ),
      ),
    );
  }
}

/// Shared hero composition. No fixed height: titles and large text can wrap.
class CinematicHero extends StatelessWidget {
  final String eyebrow, title, subtitle;
  final IconData icon;
  final Widget? child;
  const CinematicHero({
    super.key,
    required this.eyebrow,
    required this.title,
    required this.subtitle,
    required this.icon,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return CinematicEntrance(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: colors.outlineVariant),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.alphaBlend(
                colors.primary.withValues(alpha: .13),
                colors.surfaceContainerLow,
              ),
              colors.surfaceContainerLow,
            ],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 10,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Icon(icon, color: colors.primary, size: 24),
                  Text(
                    eyebrow.toUpperCase(),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: colors.primary,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.4,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Semantics(
                header: true,
                child: Text(
                  title,
                  style: theme.textTheme.displayLarge?.copyWith(
                    color: colors.onSurface,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                subtitle,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: colors.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
              if (child != null) ...[const SizedBox(height: 24), child!],
            ],
          ),
        ),
      ),
    );
  }
}

class SectionHeading extends StatelessWidget {
  final String title;
  final String? subtitle;
  const SectionHeading(this.title, {super.key, this.subtitle});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 6),
          Text(
            subtitle!,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    ),
  );
}

/// Displays server-provided lesson counts; playback position is never used.
class LearningProgress extends StatelessWidget {
  final int completed, total;
  final String label;
  const LearningProgress({
    super.key,
    required this.completed,
    required this.total,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final value = total > 0 ? (completed / total).clamp(0.0, 1.0) : 0.0;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 280);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 12),
        TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: value, end: value),
          duration: duration,
          builder: (context, amount, _) =>
              LinearProgressIndicator(value: amount, semanticsLabel: label),
        ),
      ],
    );
  }
}

/// One accessible card pattern for dashboard, assignments and curriculum.
class LearningCard extends StatelessWidget {
  final String title, subtitle, status;
  final BadgeStatus badgeStatus;
  final IconData icon;
  final VoidCallback onTap;
  final Widget? footer;
  const LearningCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.status,
    required this.badgeStatus,
    required this.onTap,
    this.icon = Icons.play_lesson_outlined,
    this.footer,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Semantics(
        button: true,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: colors.primary.withValues(alpha: .12),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: colors.primary.withValues(alpha: .2),
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Icon(icon, color: colors.primary),
                      ),
                    ),
                    const Spacer(),
                    Icon(
                      Icons.arrow_outward_rounded,
                      color: colors.onSurfaceVariant,
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  subtitle,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                StatusBadge(
                  text: status.replaceAll('_', ' '),
                  status: badgeStatus,
                ),
                if (footer != null) ...[const SizedBox(height: 20), footer!],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
