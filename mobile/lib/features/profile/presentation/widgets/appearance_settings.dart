import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/presentation/components/cinematic_notice.dart';
import 'package:training_app/core/theme/appearance_controller.dart';

class AppearanceSettings extends ConsumerWidget {
  const AppearanceSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(appearanceControllerProvider);
    final controller = ref.read(appearanceControllerProvider.notifier);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  'Appearance',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Close appearance',
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        Text(
          'Applies on this device, including the sign-in screen.',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        RadioGroup<ThemeMode>(
          groupValue: appearance.mode,
          onChanged: (mode) {
            if (mode != null) controller.setMode(mode);
          },
          child: Column(
            children: [
              for (final (mode, title) in [
                (ThemeMode.system, 'System Default'),
                (ThemeMode.light, 'Light Mode'),
                (ThemeMode.dark, 'Dark Mode'),
              ])
                RadioListTile<ThemeMode>(
                  key: ValueKey(mode),
                  value: mode,
                  title: Text(title),
                  selected: appearance.mode == mode,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                ),
            ],
          ),
        ),
        if (appearance.restoring || appearance.saving) ...[
          const SizedBox(height: 12),
          Semantics(
            liveRegion: true,
            child: Text(
              appearance.restoring
                  ? 'Loading saved appearance…'
                  : 'Saving appearance…',
            ),
          ),
        ],
        if (appearance.failure != null) ...[
          const SizedBox(height: 12),
          Semantics(
            liveRegion: true,
            child: CinematicNotice(
              isError: true,
              message: appearance.failure == AppearanceFailure.restore
                  ? 'Could not load your saved appearance. You can retry or choose a mode.'
                  : 'Could not save appearance. Your choice is active for this session.',
              child: OutlinedButton(
                onPressed: controller.retry,
                child: const Text('Retry appearance setting'),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
