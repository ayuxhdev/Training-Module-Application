import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/network/dio_client.dart';
import 'package:training_app/features/dashboard/data/repositories/dashboard_repository.dart';

class MockApiClient extends Mock implements ApiClient {}
class MockDio extends Mock implements Dio {}

void main() {
  late MockApiClient mockApiClient;
  late MockDio mockDio;
  late DashboardRepository repository;

  setUp(() {
    mockApiClient = MockApiClient();
    mockDio = MockDio();
    when(() => mockApiClient.dio).thenReturn(mockDio);
    repository = DashboardRepository(apiClient: mockApiClient);
  });

  test('getDashboardData returns DashboardData on success', () async {
    final Map<String, dynamic> mockResponse = {
      'metrics': {
        'total': 5,
        'assigned': 2,
        'in_progress': 1,
        'completed': 2,
        'cancelled': 0,
        'overdue': 0,
        'completion_percent': 40.0,
        'certificates_count': 1,
      },
      'action_required': [],
      'recent_certificates': [],
    };

    when(() => mockDio.get('/dashboard/')).thenAnswer(
      (_) async => Response(
        requestOptions: RequestOptions(path: '/dashboard/'),
        data: mockResponse,
        statusCode: 200,
      ),
    );

    final result = await repository.getDashboardData();
    expect(result.metrics.total, 5);
    expect(result.metrics.assigned, 2);
    expect(result.metrics.completionPercent, 40.0);
  });
}

