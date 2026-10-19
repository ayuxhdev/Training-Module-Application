import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final appearanceStorageProvider = Provider((ref) => AppearanceStorage());

/// Installation-wide, non-sensitive preference. Authentication only deletes its
/// own token keys, so signing out does not change this device's appearance.
class AppearanceStorage {
  final FlutterSecureStorage _storage;
  static const _key = 'app_appearance_mode';

  AppearanceStorage({FlutterSecureStorage? storage})
    : _storage =
          storage ?? const FlutterSecureStorage(aOptions: AndroidOptions());

  Future<ThemeMode> readMode() async =>
      switch (await _storage.read(key: _key)) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  Future<void> writeMode(ThemeMode mode) =>
      _storage.write(key: _key, value: mode.name);
}
