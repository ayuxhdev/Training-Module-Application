import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/certificates/data/repositories/certificate_repository.dart';
import 'package:training_app/features/certificates/domain/models/certificate.dart';
import 'package:training_app/features/certificates/domain/models/certificate_detail.dart';

String? _account(AuthState auth) =>
    auth is AuthAuthenticated
    ? auth.personalAccount
    : null;

void _guardAccount(Ref ref, void Function() clear) {
  final owner = _account(ref.read(authControllerProvider));
  ref.listen(authControllerProvider, (_, next) {
    if (_account(next) != owner) {
      // Clear data before rebuilding; AsyncValue must not retain another user's value.
      clear();
      ref.invalidateSelf();
    }
  });
  if (owner == null) {
    throw ApiError(message: 'Sign in to view certificates.', statusCode: 401);
  }
}

Future<T> _readAuthorized<T>(
  Ref requestRef,
  Future<T> Function() read,
  void Function() clear,
) async {
  try {
    return await read();
  } catch (error) {
    if (requestRef.mounted &&
        error is ApiError &&
        (error.statusCode == 401 || error.statusCode == 403)) {
      clear();
    }
    rethrow;
  }
}

/// Provides the paginated list of certificates for the authenticated employee.
final certificateListProvider =
    AsyncNotifierProvider.autoDispose<
      CertificateListController,
      List<Certificate>
    >(CertificateListController.new, retry: (_, _) => null);

class CertificateListController extends AsyncNotifier<List<Certificate>> {
  @override
  Future<List<Certificate>> build() {
    _guardAccount(ref, () => state = const AsyncData([]));
    final requests = CancelToken();
    ref.onDispose(requests.cancel);
    final repository = ref.watch(certificateRepositoryProvider);
    return _readAuthorized(
      ref,
      () => repository.getCertificates(cancelToken: requests),
      () => state = const AsyncData([]),
    );
  }
}

/// Provides the full detail for a single certificate identified by its [id].
final certificateDetailProvider = AsyncNotifierProvider.autoDispose
    .family<CertificateDetailController, CertificateDetail?, int>(
      CertificateDetailController.new,
      retry: (_, _) => null,
    );

class CertificateDetailController extends AsyncNotifier<CertificateDetail?> {
  final int id;
  CertificateDetailController(this.id);

  @override
  Future<CertificateDetail?> build() {
    if (id <= 0) {
      throw ArgumentError('certificateId must be a positive integer.');
    }
    _guardAccount(ref, () => state = const AsyncData(null));
    final requests = CancelToken();
    ref.onDispose(requests.cancel);
    final repository = ref.watch(certificateRepositoryProvider);
    return _readAuthorized(
      ref,
      () => repository.getCertificateDetail(id, cancelToken: requests),
      () => state = const AsyncData(null),
    );
  }
}
