import 'package:flutter/material.dart';
import 'package:training_app/core/theme/app_spacing.dart';

class CustomCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final String? semanticLabel;

  const CustomCard({
    super.key,
    required this.child,
    this.padding = AppSpacing.pagePadding,
    this.onTap,
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    Widget card = Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: padding,
          child: child,
        ),
      ),
    );
    if (semanticLabel != null) {
      return Semantics(
        label: semanticLabel,
        button: onTap != null,
        child: card,
      );
    }
    return card;
  }
}
