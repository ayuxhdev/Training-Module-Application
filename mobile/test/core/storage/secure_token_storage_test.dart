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
    storage = SecureTokenStorageImpl(storage: mockStorage);
  });

  test('saveAccessToken writes to secure storage', () async {
    when(() => mockStorage.write(key: 'access_token', value: 'my_token'))
        .thenAnswer((_) async {});

    await storage.saveAccessToken('my_token');

    verify(() => mockStorage.write(key: 'access_token', value: 'my_token')).called(1);
  });

  test('readAccessToken reads from secure storage', () async {
    when(() => mockStorage.read(key: 'access_token'))
        .thenAnswer((_) async => 'my_token');

    final result = await storage.readAccessToken();

    expect(result, 'my_token');
    verify(() => mockStorage.read(key: 'access_token')).called(1);
  });

  test('deleteTokens removes both tokens', () async {
    when(() => mockStorage.delete(key: 'access_token')).thenAnswer((_) async {});
    when(() => mockStorage.delete(key: 'refresh_token')).thenAnswer((_) async {});

    await storage.deleteTokens();

    verify(() => mockStorage.delete(key: 'access_token')).called(1);
    verify(() => mockStorage.delete(key: 'refresh_token')).called(1);
  });
}

