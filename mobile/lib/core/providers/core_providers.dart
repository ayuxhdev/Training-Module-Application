import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/network/dio_client.dart';
import 'package:training_app/core/storage/secure_token_storage.dart';

final secureTokenStorageProvider = Provider<SecureTokenStorage>((ref) {
  return SecureTokenStorageImpl();
});

final apiClientProvider = Provider<ApiClient>((ref) {
  final tokenStorage = ref.watch(secureTokenStorageProvider);
  return ApiClient(tokenStorage: tokenStorage);
});

