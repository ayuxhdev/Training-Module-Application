import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/network/dio_client.dart';
import 'package:training_app/core/providers/core_providers.dart';
import 'package:training_app/features/certificates/domain/models/certificate.dart';
import 'package:training_app/features/certificates/domain/models/certificate_detail.dart';

final certificateRepositoryProvider = Provider<CertificateRepository>((ref) {
  return CertificateRepository(apiClient: ref.watch(apiClientProvider));
});

class CertificateRepository {
  final ApiClient apiClient;

  CertificateRepository({required this.apiClient});

  /// Returns all certificates for the authenticated employee, consuming every
  /// page of the paginated response. The list is server-ordered (newest first).
  Future<List<Certificate>> getCertificates({CancelToken? cancelToken}) async {
    try {
      final certificates = <Certificate>[];
      var page = 1;
      while (true) {
        final response = page == 1
            ? await apiClient.dio.get('/certificates/', cancelToken: cancelToken)
            : await apiClient.dio.get(
                '/certificates/',
                queryParameters: {'page': page},
                cancelToken: cancelToken,
              );
        final data = response.data as Map<String, dynamic>;
        final results = data['results'] as List<dynamic>;
        certificates.addAll(
          results.map((item) => Certificate.fromJson(item as Map<String, dynamic>)),
        );
        if (data['next'] == null) return certificates;
        if (results.isEmpty || data['next'] is! String) {
          throw const FormatException('Invalid certificate pagination response.');
        }
        page++;
      }
    } catch (e) {
      throw apiClient.mapExceptionToApiError(e);
    }
  }

  /// Returns the full detail for a single certificate owned by the authenticated
  /// employee. Throws [ApiError] with status 404 if not found or not owned.
  Future<CertificateDetail> getCertificateDetail(
    int certificateId, {
    CancelToken? cancelToken,
  }) async {
    if (certificateId <= 0) {
      throw ArgumentError('certificateId must be a positive integer.');
    }
    try {
      final response = await apiClient.dio.get(
        '/certificates/$certificateId/',
        cancelToken: cancelToken,
      );
      return CertificateDetail.fromJson(response.data as Map<String, dynamic>);
    } catch (e) {
      throw apiClient.mapExceptionToApiError(e);
    }
  }
}
