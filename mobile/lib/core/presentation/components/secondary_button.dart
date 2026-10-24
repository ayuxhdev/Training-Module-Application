import 'package:flutter/material.dart';

class SecondaryButton extends StatelessWidget {
  final String text;
  final VoidCallback? onPressed;
  final bool isLoading;
  final Widget? icon;

  const SecondaryButton({
    super.key,
    required this.text,
    this.onPressed,
    this.isLoading = false,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;

    final labelWidget = Text(
      text,
      style: const TextStyle(
        fontWeight: FontWeight.w600,
      ),
    );

    final childWidget = isLoading
        ? SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: primaryColor,
            ),
          )
        : icon != null
            ? Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  icon!,
                  const SizedBox(width: 8),
                  labelWidget,
                ],
              )
            : labelWidget;

    return OutlinedButton(
      onPressed: isLoading ? null : onPressed,
      child: childWidget,
    );
  }
}
