import 'package:flutter/material.dart';

/// A local answer selection, never an indication of correctness or saved data.
class AssessmentChoice extends StatelessWidget {
  final String text;
  final bool selected;
  final VoidCallback? onPressed;

  const AssessmentChoice({
    super.key,
    required this.text,
    required this.selected,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          alignment: Alignment.centerLeft,
          minimumSize: const Size(48, 64),
          padding: const EdgeInsets.all(20),
          animationDuration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 180),
          side: BorderSide(
            color: selected ? colors.primary : colors.outlineVariant,
            width: selected ? 2 : 1,
          ),
          backgroundColor: selected
              ? colors.primaryContainer
              : colors.surfaceContainerLow,
          foregroundColor: selected
              ? colors.onPrimaryContainer
              : colors.onSurface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
        onPressed: onPressed,
        icon: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        ),
        label: Text(text, style: const TextStyle(height: 1.5)),
      ),
    );
  }
}
