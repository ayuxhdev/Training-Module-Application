import 'package:flutter/material.dart';

class PrimaryButton extends StatelessWidget {
  final String text;
  final VoidCallback? onPressed;
  final bool isLoading;
  final Widget? icon;

  const PrimaryButton({
    super.key,
    required this.text,
    this.onPressed,
    this.isLoading = false,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: isLoading ? null : onPressed,
      child: Builder(
        builder: (context) {
          final spinnerColor =
              DefaultTextStyle.of(context).style.color ??
              IconTheme.of(context).color;

          final labelWidget = Text(
            text,
            style: const TextStyle(fontWeight: FontWeight.w600),
          );

          if (isLoading) {
            return Semantics(
              label: text,
              value: 'Loading',
              liveRegion: true,
              child: ExcludeSemantics(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: MediaQuery.disableAnimationsOf(context)
                      ? Icon(
                          Icons.hourglass_empty_rounded,
                          size: 20,
                          color: spinnerColor,
                        )
                      : CircularProgressIndicator(
                          strokeWidth: 2,
                          color: spinnerColor,
                        ),
                ),
              ),
            );
          }

          if (icon != null) {
            return Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [icon!, const SizedBox(width: 8), labelWidget],
            );
          }

          return labelWidget;
        },
      ),
    );
  }
}
