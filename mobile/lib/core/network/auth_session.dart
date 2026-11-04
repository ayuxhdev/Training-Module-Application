import 'dart:convert';

import 'package:dio/dio.dart';

import '../errors/api_error.dart';
import '../storage/secure_token_storage.dart';

/// One owner for refresh rotation, credential writes, login and logout.
/// The queue covers network rotation too: logout must revoke the newest child.
class AuthSession {
  static const bypass = 'authSessionBypass';
  static const generationKey = 'authSessionGeneration';
  static const minimumValidityKey = 'authMinimumValidity';
  final Dio dio;
  final SecureTokenStorage storage;
  final DateTime Function() now;

  Future<void> _work = Future.value();
  Future<String?>? _refreshing;
  int _changes = 0;
  int _generation = 0;
  bool _requiresLogin = false;

  AuthSession({
    required this.dio,
    required this.storage,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  int get generation => _generation;
  bool get canAuthorize => _changes == 0 && !_requiresLogin;

  static ApiError signInRequired() => ApiError(
    message: 'Your session has ended. Sign in again to continue.',
    statusCode: 401,
    code: 'reauthentication_required',
  );

  Future<T> _serial<T>(Future<T> Function() operation) {
    final result = _work.then((_) => operation());
    _work = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  // Decoding only schedules refresh. The server still verifies every JWT.
  static Map<String, dynamic>? claims(String? token) {
    if (token == null) return null;
    try {
      final parts = token.split('.');
      if (parts.length != 3) return null;
      final value = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      return value is Map<String, dynamic> ? value : null;
    } catch (_) {
      return null;
    }
  }

  bool _expiresSoon(String? token, Duration minimumValidity) {
    final exp = claims(token)?['exp'];
    return exp is num &&
        exp <= now().add(minimumValidity).millisecondsSinceEpoch / 1000;
  }

  Future<String?> accessToken({
    Duration minimumValidity = const Duration(seconds: 60),
  }) async {
    if (_changes > 0 || _requiresLogin) throw signInRequired();
    await _work;
    if (_changes > 0 || _requiresLogin) throw signInRequired();
    if (await storage.isSessionInvalid()) {
      _requiresLogin = true;
      throw signInRequired();
    }
    final access = await storage.readAccessToken();
    if (access == null ||
        access.isEmpty ||
        _expiresSoon(access, minimumValidity)) {
      final refresh = await storage.readRefreshToken();
      if (refresh != null && refresh.isNotEmpty) {
        return renew(rejectedToken: access);
      }
    }
    return access;
  }

  Future<void> _persist(Map<String, dynamic> data) async {
    final access = data['access'];
    final refresh = data['refresh'];
    if (access is! String ||
        access.isEmpty ||
        refresh is! String ||
        refresh.isEmpty) {
      throw const FormatException('Invalid token response.');
    }
    // If interrupted between writes, the usable rotated refresh survives restart.
    await storage.saveRefreshToken(refresh);
    await storage.saveAccessToken(access);
  }

  Future<void> _invalidateLocked() async {
    _requiresLogin = true;
    try {
      await storage.markSessionInvalid();
    } finally {
      await storage.clearAuthenticationState();
    }
  }

  Future<String?> _renewLocked() async {
    if (await storage.isSessionInvalid()) {
      await _invalidateLocked();
      throw signInRequired();
    }
    final parent = await storage.readRefreshToken();
    if (parent == null || parent.isEmpty) {
      await _invalidateLocked();
      throw signInRequired();
    }
    try {
      final response = await dio.post(
        '/auth/refresh/',
        data: {'refresh': parent},
        options: Options(extra: {bypass: true}, followRedirects: false),
      );
      final data = Map<String, dynamic>.from(response.data as Map);
      final previousUser = claims(await storage.readAccessToken())?['user_id'];
      final nextUser = claims(data['access'] as String?)?['user_id'];
      if (previousUser != null &&
          nextUser.toString() != previousUser.toString()) {
        throw const FormatException('Refresh identity changed.');
      }
      await _persist(data);
      return data['access'] as String;
    } on DioException catch (error) {
      if (error.response?.statusCode == 401 ||
          error.response?.statusCode == 403) {
        await _invalidateLocked();
        throw signInRequired();
      }
      // No automatic refresh retry on uncertain transport outcomes.
      rethrow;
    } catch (_) {
      await _invalidateLocked();
      throw signInRequired();
    }
  }

  Future<String?> renew({String? rejectedToken}) async {
    if (_changes > 0 || _requiresLogin) throw signInRequired();
    final currentFlight = _refreshing;
    if (currentFlight != null) return currentFlight;
    final flight = _serial(() async {
      if (_changes > 0 || _requiresLogin) throw signInRequired();
      final current = await storage.readAccessToken();
      // A late 401 for the parent must not rotate the already current child.
      if (rejectedToken != null &&
          current != null &&
          current != rejectedToken) {
        return current;
      }
      return _renewLocked();
    });
    _refreshing = flight;
    try {
      return await flight;
    } finally {
      if (identical(_refreshing, flight)) _refreshing = null;
    }
  }

  Future<void> login(String username, String password) {
    _changes++;
    return _serial(() async {
      _generation++;
      _requiresLogin = true;
      try {
        await storage.markSessionInvalid();
        final response = await dio.post(
          '/auth/login/',
          data: {'username': username, 'password': password},
        );
        await _persist(Map<String, dynamic>.from(response.data as Map));
        await storage.clearInvalidationMarker();
        _requiresLogin = false;
      } catch (_) {
        await _invalidateLocked();
        rethrow;
      }
    }).whenComplete(() => _changes--);
  }

  Future<void> logout() {
    _changes++;
    return _serial(() async {
      _generation++;
      try {
        var access = await storage.readAccessToken();
        var refresh = await storage.readRefreshToken();
        if (refresh != null &&
            (access == null || _expiresSoon(access, Duration.zero))) {
          access = await _renewLocked();
          refresh = await storage.readRefreshToken();
        }
        if (refresh != null && refresh.isNotEmpty) {
          await dio.post(
            '/auth/logout/',
            data: {'refresh': refresh},
            options: Options(
              headers: {if (access != null) 'Authorization': 'Bearer $access'},
              extra: {bypass: true},
              followRedirects: false,
            ),
          );
        }
      } finally {
        await _invalidateLocked();
      }
    }).whenComplete(() => _changes--);
  }

  Future<void> rejectCurrent(int generation) => _serial(() async {
    if (generation == _generation) await _invalidateLocked();
  });
}
