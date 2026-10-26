import 'package:flutter/material.dart';
import 'package:training_app/core/theme/app_spacing.dart';

/// Static placeholders: no tickers, focus targets or invented record details.
class SkeletonBox extends StatelessWidget {
  final double height;
  final double fraction;
  const SkeletonBox({super.key, this.height = 14, this.fraction = 1});

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: fraction,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    ),
  );
}

class _SkeletonContent extends StatelessWidget {
  final String message;
  final List<Widget> children;
  const _SkeletonContent(this.message, this.children);

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    liveRegion: true,
    label: message,
    child: ExcludeSemantics(
      child: IgnorePointer(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: AppSpacing.md,
          children: [
            Text(message, style: Theme.of(context).textTheme.labelLarge),
            ...children,
          ],
        ),
      ),
    ),
  );
}

class _SkeletonCard extends StatelessWidget {
  final bool header, compact;
  const _SkeletonCard({this.header = false, this.compact = false});

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          SkeletonBox(height: header ? 20 : 14, fraction: .4),
          SkeletonBox(
            height: MediaQuery.textScalerOf(context).scale(header ? 32 : 20),
            fraction: .8,
          ),
          if (!compact) const SkeletonBox(fraction: .65),
          if (!compact && !header) const SkeletonBox(height: 6),
        ],
      ),
    ),
  );
}

class DashboardSkeleton extends StatelessWidget {
  const DashboardSkeleton({super.key});

  @override
  Widget build(BuildContext context) =>
      const _SkeletonContent('Loading dashboard', [
        _SkeletonCard(header: true),
        _SkeletonMetrics(count: 3, columns: 3, breakpoint: 720),
        _SkeletonCard(),
        _SkeletonCard(),
      ]);
}

class LearningSkeleton extends StatelessWidget {
  const LearningSkeleton({super.key});

  @override
  Widget build(BuildContext context) => const _SkeletonContent(
    'Loading assignments',
    [_SkeletonCard(header: true), _SkeletonCard(), _SkeletonCard()],
  );
}

/// List geometry is also suitable for certificates, notifications and directories.
class CardListSkeleton extends StatelessWidget {
  final String message;
  final bool showHeader, compact;
  const CardListSkeleton({
    super.key,
    required this.message,
    this.showHeader = true,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) => _SkeletonContent(message, [
    if (showHeader) const _SkeletonCard(header: true),
    _SkeletonCard(compact: compact),
    _SkeletonCard(compact: compact),
    _SkeletonCard(compact: compact),
  ]);
}

class ManagementSkeleton extends StatelessWidget {
  const ManagementSkeleton({super.key});

  @override
  Widget build(BuildContext context) =>
      _SkeletonContent('Loading management dashboard', [
        const _SkeletonCard(header: true),
        const _SkeletonMetrics(count: 6, columns: 2, breakpoint: 320),
        const _SkeletonCard(),
      ]);
}

class _SkeletonMetrics extends StatelessWidget {
  final int count, columns;
  final double breakpoint;
  const _SkeletonMetrics({
    required this.count,
    required this.columns,
    required this.breakpoint,
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final visibleColumns =
          constraints.maxWidth >= breakpoint &&
              (columns == 3 || MediaQuery.textScalerOf(context).scale(14) <= 21)
          ? columns
          : 1;
      return Wrap(
        spacing: AppSpacing.md,
        runSpacing: AppSpacing.md,
        children: [
          for (var index = 0; index < count; index++)
            SizedBox(
              width:
                  (constraints.maxWidth -
                      AppSpacing.md * (visibleColumns - 1)) /
                  visibleColumns,
              child: const _SkeletonCard(compact: true),
            ),
        ],
      );
    },
  );
}

/// Hosts list-shaped loading content without blocking scrolling on short screens.
class SkeletonPage extends StatelessWidget {
  final Widget child;
  const SkeletonPage({super.key, required this.child});

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    physics: const AlwaysScrollableScrollPhysics(),
    padding: AppSpacing.pagePadding,
    child: child,
  );
}
