import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:training_app/core/storage/secure_token_storage.dart';

class MockFlutterSecureStorage extends Mock implements FlutterSecureStorage {}

void main() {
  late MockFlutterSecureStorage mockStorage;
  late SecureTokenStorageImpl storage;

  setUp(() {
    mockStorage = MockFlutterSecureStorage();
    when(() => mockStorage.read(key: 'auth_session_invalid'))
        .thenAnswer((_) async => null);
    storage = SecureTokenStorageImpl(storage: mockStorage);
  });

  test('saveAccessToken writes to secure storage', () async {
    when(() => mockStorage.write(key: 'access_token', value: 'my_token'))
        .thenAnswer((_) async {});

    await storage.saveAccessToken('my_token');

    verify(() => mockStorage.write(key: 'access_token', value: 'my_token'))
        .called(1);
  });

  test('readAccessToken reads from secure storage', () async {
    when(() => mockStorage.read(key: 'access_token'))
        .thenAnswer((_) async => 'my_token');

    final result = await storage.readAccessToken();

    expect(result, 'my_token');
    verify(() => mockStorage.read(key: 'access_token')).called(1);
  });

  test('deleteTokens removes both tokens', () async {
    when(() => mockStorage.delete(key: 'access_token'))
        .thenAnswer((_) async {});
    when(() => mockStorage.delete(key: 'refresh_token'))
        .thenAnswer((_) async {});

    await storage.deleteTokens();

    verify(() => mockStorage.delete(key: 'access_token')).called(1);
    verify(() => mockStorage.delete(key: 'refresh_token')).called(1);
  });

  test('markSessionInvalid writes marker', () async {
    when(() => mockStorage.write(key: 'auth_session_invalid', value: 'true'))
        .thenAnswer((_) async {});

    await storage.markSessionInvalid();

    verify(() => mockStorage.write(key: 'auth_session_invalid', value: 'true'))
        .called(1);
  });

  test('clearInvalidationMarker deletes marker', () async {
    when(() => mockStorage.delete(key: 'auth_session_invalid'))
        .thenAnswer((_) async {});

    await storage.clearInvalidationMarker();

    verify(() => mockStorage.delete(key: 'auth_session_invalid')).called(1);
  });

  test('isSessionInvalid returns true when marker is set', () async {
    when(() => mockStorage.read(key: 'auth_session_invalid'))
        .thenAnswer((_) async => 'true');

    expect(await storage.isSessionInvalid(), isTrue);
  });

  test('readAccessToken returns null when session is invalid', () async {
    when(() => mockStorage.read(key: 'auth_session_invalid'))
        .thenAnswer((_) async => 'true');
    when(() => mockStorage.read(key: 'access_token'))
        .thenAnswer((_) async => 'stale_token');

    expect(await storage.readAccessToken(), isNull);
    verifyNever(() => mockStorage.read(key: 'access_token'));
  });

  test('readRefreshToken returns null when session is invalid', () async {
    when(() => mockStorage.read(key: 'auth_session_invalid'))
        .thenAnswer((_) async => 'true');
    when(() => mockStorage.read(key: 'refresh_token'))
        .thenAnswer((_) async => 'stale_refresh');

    expect(await storage.readRefreshToken(), isNull);
    verifyNever(() => mockStorage.read(key: 'refresh_token'));
  });

  test('clearAuthenticationState deletes tokens', () async {
    when(() => mockStorage.delete(key: 'access_token'))
        .thenAnswer((_) async {});
    when(() => mockStorage.delete(key: 'refresh_token'))
        .thenAnswer((_) async {});

    await storage.clearAuthenticationState();

    verifyInOrder([
      () => mockStorage.delete(key: 'access_token'),
      () => mockStorage.delete(key: 'refresh_token'),
    ]);
  });
}
