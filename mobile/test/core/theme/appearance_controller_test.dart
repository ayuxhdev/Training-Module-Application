import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/core/storage/appearance_storage.dart';
import 'package:training_app/core/theme/appearance_controller.dart';

import 'appearance_fixtures.dart';

void main() {
  late MemoryAppearanceStorage storage;
  late ProviderContainer container;
  setUp(() {
    storage = MemoryAppearanceStorage();
    container = ProviderContainer(
      overrides: [appearanceStorageProvider.overrideWithValue(storage)],
    );
  });
  tearDown(() => container.dispose());
  Future<void> restore() async {
    container.read(appearanceControllerProvider);
    await Future<void>.delayed(Duration.zero);
  }

  test(
    'restores persisted choice and applies selection before saving finishes',
    () async {
      storage.saved = ThemeMode.dark;
      await restore();
      expect(container.read(appearanceControllerProvider).mode, ThemeMode.dark);
      final pending = Completer<void>();
      storage.onWrite = (_) => pending.future;
      final save = container
          .read(appearanceControllerProvider.notifier)
          .setMode(ThemeMode.light);
      expect(
        container.read(appearanceControllerProvider).mode,
        ThemeMode.light,
      );
      expect(container.read(appearanceControllerProvider).saving, isTrue);
      pending.complete();
      await save;
      expect(storage.saved, ThemeMode.light);
      expect(container.read(appearanceControllerProvider).saving, isFalse);
    },
  );

  test('restores the saved mode in a new application container', () async {
    await restore();
    await container
        .read(appearanceControllerProvider.notifier)
        .setMode(ThemeMode.dark);
    final restarted = ProviderContainer(
      overrides: [appearanceStorageProvider.overrideWithValue(storage)],
    );
    try {
      restarted.read(appearanceControllerProvider);
      await Future<void>.delayed(Duration.zero);
      expect(restarted.read(appearanceControllerProvider).mode, ThemeMode.dark);
    } finally {
      restarted.dispose();
    }
  });

  test('late restoration cannot overwrite a user selection', () async {
    final read = Completer<ThemeMode>();
    storage.onRead = () => read.future;
    await restore();
    await container
        .read(appearanceControllerProvider.notifier)
        .setMode(ThemeMode.light);
    read.complete(ThemeMode.dark);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(appearanceControllerProvider).mode, ThemeMode.light);
    expect(storage.saved, ThemeMode.light);
  });

  test('rapid writes are serialized and an older completion does not change the latest choice', () async {
    await restore();
    final first = Completer<void>();
    storage.onWrite = (mode) =>
        mode == ThemeMode.dark ? first.future : Future.value();
    final controller = container.read(appearanceControllerProvider.notifier);
    final dark = controller.setMode(ThemeMode.dark);
    final light = controller.setMode(ThemeMode.light);
    await Future<void>.delayed(Duration.zero);
    expect(storage.writes, [ThemeMode.dark]);
    expect(container.read(appearanceControllerProvider).mode, ThemeMode.light);
    first.complete();
    await Future.wait([dark, light]);
    expect(storage.writes, [ThemeMode.dark, ThemeMode.light]);
    expect(storage.saved, ThemeMode.light);
    expect(container.read(appearanceControllerProvider).mode, ThemeMode.light);
  });

  test(
    'restore failure falls back safely and can be retried explicitly',
    () async {
      storage.onRead = () async => throw StateError('unavailable');
      await restore();
      expect(
        container.read(appearanceControllerProvider).mode,
        ThemeMode.system,
      );
      expect(
        container.read(appearanceControllerProvider).failure,
        AppearanceFailure.restore,
      );
      storage.onRead = null;
      storage.saved = ThemeMode.dark;
      await container.read(appearanceControllerProvider.notifier).retry();
      expect(container.read(appearanceControllerProvider).mode, ThemeMode.dark);
      expect(container.read(appearanceControllerProvider).failure, isNull);
    },
  );

  test(
    'save failure keeps the chosen theme active and supports retry',
    () async {
      await restore();
      storage.onWrite = (_) async => throw StateError('unavailable');
      await container
          .read(appearanceControllerProvider.notifier)
          .setMode(ThemeMode.dark);
      expect(container.read(appearanceControllerProvider).mode, ThemeMode.dark);
      expect(
        container.read(appearanceControllerProvider).failure,
        AppearanceFailure.save,
      );
      storage.onWrite = null;
      await container.read(appearanceControllerProvider.notifier).retry();
      expect(storage.saved, ThemeMode.dark);
      expect(container.read(appearanceControllerProvider).failure, isNull);
    },
  );

  test('older write failure neither breaks the queue nor replaces a newer selection', () async {
    await restore();
    storage.onWrite = (mode) async {
      if (mode == ThemeMode.dark) throw StateError('unavailable');
    };
    final controller = container.read(appearanceControllerProvider.notifier);
    await Future.wait([
      controller.setMode(ThemeMode.dark),
      controller.setMode(ThemeMode.light),
    ]);
    expect(storage.saved, ThemeMode.light);
    expect(container.read(appearanceControllerProvider).failure, isNull);
  });

  test(
    'pending restoration and writes can finish safely after disposal',
    () async {
      final read = Completer<ThemeMode>();
      final write = Completer<void>();
      storage.onRead = () => read.future;
      storage.onWrite = (_) => write.future;
      final isolated = ProviderContainer(
        overrides: [appearanceStorageProvider.overrideWithValue(storage)],
      );
      isolated.read(appearanceControllerProvider);
      final save = isolated
          .read(appearanceControllerProvider.notifier)
          .setMode(ThemeMode.dark);
      await Future<void>.delayed(Duration.zero);
      isolated.dispose();
      read.complete(ThemeMode.light);
      write.complete();
      await save;
      expect(storage.saved, ThemeMode.dark);
    },
  );
}
