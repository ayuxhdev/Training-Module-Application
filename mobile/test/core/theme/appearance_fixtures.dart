import 'package:flutter/material.dart';
import 'package:training_app/core/storage/appearance_storage.dart';

class MemoryAppearanceStorage extends AppearanceStorage {
  ThemeMode saved;
  final writes = <ThemeMode>[];
  Future<ThemeMode> Function()? onRead;
  Future<void> Function(ThemeMode)? onWrite;
  MemoryAppearanceStorage([this.saved = ThemeMode.system]);

  @override
  Future<ThemeMode> readMode() async {
    final read = onRead;
    return read == null ? saved : await read();
  }

  @override
  Future<void> writeMode(ThemeMode mode) async {
    writes.add(mode);
    if (onWrite case final write?) await write(mode);
    saved = mode;
  }
}
