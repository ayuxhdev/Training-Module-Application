import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/storage/appearance_storage.dart';

enum AppearanceFailure { restore, save }

class AppearanceState {
  final ThemeMode mode;
  final bool restoring, saving;
  final AppearanceFailure? failure;
  const AppearanceState({
    this.mode = ThemeMode.system,
    this.restoring = false,
    this.saving = false,
    this.failure,
  });
}

final appearanceControllerProvider =
    NotifierProvider<AppearanceController, AppearanceState>(
      AppearanceController.new,
    );

class AppearanceController extends Notifier<AppearanceState> {
  final ThemeMode? initialMode;
  AppearanceController({this.initialMode});

  int _revision = 0;
  Future<void> _writes = Future.value();

  @override
  AppearanceState build() {
    final storage = ref.watch(appearanceStorageProvider);
    final revision = ++_revision;
    if (initialMode case final mode?) return AppearanceState(mode: mode);
    Future.microtask(() => _restore(storage, revision));
    return const AppearanceState(restoring: true);
  }

  bool _current(int revision) => ref.mounted && revision == _revision;

  Future<void> _restore(AppearanceStorage storage, int revision) async {
    try {
      final mode = await storage.readMode();
      if (_current(revision)) state = AppearanceState(mode: mode);
    } catch (_) {
      if (_current(revision)) {
        state = AppearanceState(
          mode: state.mode,
          failure: AppearanceFailure.restore,
        );
      }
    }
  }

  Future<void> setMode(ThemeMode mode) async {
    final storage = ref.read(appearanceStorageProvider);
    final revision = ++_revision;
    state = AppearanceState(mode: mode, saving: true);
    // Apply immediately, but serialize disk writes so rapid choices persist in
    // the same order. Older completions must not replace newer UI state.
    final write = _writes.then((_) => storage.writeMode(mode));
    _writes = write.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    try {
      await write;
      if (_current(revision)) state = AppearanceState(mode: mode);
    } catch (_) {
      if (_current(revision)) {
        state = AppearanceState(mode: mode, failure: AppearanceFailure.save);
      }
    }
  }

  Future<void> retry() async {
    if (state.failure == AppearanceFailure.restore) {
      final revision = ++_revision;
      state = AppearanceState(mode: state.mode, restoring: true);
      await _restore(ref.read(appearanceStorageProvider), revision);
    } else if (state.failure == AppearanceFailure.save) {
      await setMode(state.mode);
    }
  }
}
