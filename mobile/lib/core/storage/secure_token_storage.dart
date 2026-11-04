import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract class SecureTokenStorage {
  Future<void> saveAccessToken(String token);
  Future<String?> readAccessToken();
  Future<void> saveRefreshToken(String token);
  Future<String?> readRefreshToken();
  Future<void> deleteTokens();
  Future<void> clearAuthenticationState();

  Future<void> markSessionInvalid();
  Future<void> clearInvalidationMarker();
  Future<bool> isSessionInvalid();
}

class SecureTokenStorageImpl implements SecureTokenStorage {
  final FlutterSecureStorage _storage;

  static const String _accessTokenKey = 'access_token';
  static const String _refreshTokenKey = 'refresh_token';
  static const String _sessionInvalidMarkerKey = 'auth_session_invalid';

  SecureTokenStorageImpl({FlutterSecureStorage? storage})
    : _storage =
          storage ?? const FlutterSecureStorage(aOptions: AndroidOptions());

  @override
  Future<void> saveAccessToken(String token) async {
    await _storage.write(key: _accessTokenKey, value: token);
  }

  @override
  Future<String?> readAccessToken() async {
    if (await isSessionInvalid()) return null;
    return await _storage.read(key: _accessTokenKey);
  }

  @override
  Future<void> saveRefreshToken(String token) async {
    await _storage.write(key: _refreshTokenKey, value: token);
  }

  @override
  Future<String?> readRefreshToken() async {
    if (await isSessionInvalid()) return null;
    return await _storage.read(key: _refreshTokenKey);
  }

  @override
  Future<void> deleteTokens() async {
    await _storage.delete(key: _accessTokenKey);
    await _storage.delete(key: _refreshTokenKey);
  }

  @override
  Future<void> clearAuthenticationState() async {
    await deleteTokens();
  }

  @override
  Future<void> markSessionInvalid() async {
    await _storage.write(key: _sessionInvalidMarkerKey, value: 'true');
  }

  @override
  Future<void> clearInvalidationMarker() async {
    await _storage.delete(key: _sessionInvalidMarkerKey);
  }

  @override
  Future<bool> isSessionInvalid() async {
    final value = await _storage.read(key: _sessionInvalidMarkerKey);
    return value == 'true';
  }
}
