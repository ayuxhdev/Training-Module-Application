import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/storage/appearance_storage.dart';
import 'package:training_app/core/storage/secure_token_storage.dart';

class _Storage extends Mock implements FlutterSecureStorage {}

void main() {
  test('only recognized appearance values restore a non-system mode', () async {
    final disk = _Storage();
    final storage = AppearanceStorage(storage: disk);
    for (final (value, expected) in [
      (null, ThemeMode.system),
      ('system', ThemeMode.system),
      ('light', ThemeMode.light),
      ('dark', ThemeMode.dark),
      ('unexpected', ThemeMode.system),
    ]) {
      when(() => disk.read(key: 'app_appearance_mode'))
          .thenAnswer((_) async => value);
      expect(await storage.readMode(), expected);
    }
  });

  test('appearance persists separately and authentication cleanup leaves its key intact', () async {
    final disk = _Storage();
    final values = <String, String?>{};
    when(
      () => disk.write(
        key: any(named: 'key'),
        value: any(named: 'value'),
      ),
    ).thenAnswer((call) async {
      values[call.namedArguments[#key] as String] =
          call.namedArguments[#value] as String?;
    });
    when(() => disk.read(key: 'app_appearance_mode'))
        .thenAnswer((_) async => values['app_appearance_mode']);
    when(() => disk.delete(key: any(named: 'key'))).thenAnswer((call) async {
      values.remove(call.namedArguments[#key]);
    });
    final appearance = AppearanceStorage(storage: disk);
    for (final mode in ThemeMode.values) {
      await appearance.writeMode(mode);
      expect(await appearance.readMode(), mode);
    }
    await SecureTokenStorageImpl(storage: disk).clearAuthenticationState();
    expect(values, {'app_appearance_mode': ThemeMode.values.last.name});
    verifyNever(() => disk.delete(key: 'app_appearance_mode'));
    verifyNever(
      () => disk.write(
        key: 'access_token',
        value: any(named: 'value'),
      ),
    );
    verifyNever(
      () => disk.write(
        key: 'refresh_token',
        value: any(named: 'value'),
      ),
    );
  });
}
