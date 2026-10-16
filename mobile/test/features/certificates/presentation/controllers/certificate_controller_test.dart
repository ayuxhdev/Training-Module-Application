import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/employee.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/certificates/data/repositories/certificate_repository.dart';
import 'package:training_app/features/certificates/domain/models/certificate.dart';
import 'package:training_app/features/certificates/domain/models/certificate_detail.dart';
import 'package:training_app/features/certificates/presentation/controllers/certificate_controller.dart';

class _MockCertificateRepository extends Mock
    implements CertificateRepository {}

Employee _employee(String name) => Employee(
  username: name,
  employeeCode: name,
  displayName: name,
  department: 'QA',
  jobRole: 'Learner',
  isActive: true,
);

class _TestAuth extends AuthController {
  @override
  AuthState build() => AuthAuthenticated(_employee('A'));
  void change(AuthState value) => state = value;
}

void main() {
  late _MockCertificateRepository mockRepository;
  late _TestAuth auth;

  ProviderContainer makeContainer() {
    return ProviderContainer(
      overrides: [
        certificateRepositoryProvider.overrideWithValue(mockRepository),
        authControllerProvider.overrideWith(() => auth),
      ],
    );
  }

  setUpAll(() => registerFallbackValue(CancelToken()));
  setUp(() {
    mockRepository = _MockCertificateRepository();
    auth = _TestAuth();
  });

  // ---------------------------------------------------------------------------
  // certificateListProvider
  // ---------------------------------------------------------------------------

  group('certificateListProvider', () {
    test('returns list of certificates from repository', () async {
      final certs = [
        Certificate(
          id: 1,
          certificateNumber: 'GN-001',
          trainingTitle: 'Safety',
          versionNumber: 1,
          issuedAt: DateTime(2024, 1, 1),
          isRevoked: false,
        ),
      ];
      when(
        () => mockRepository.getCertificates(
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => certs);

      final container = makeContainer();
      addTearDown(container.dispose);

      final result = await container.read(certificateListProvider.future);
      expect(result.length, 1);
      expect(result.first.certificateNumber, 'GN-001');
    });

    test('returns empty list when repository has no certificates', () async {
      when(
        () => mockRepository.getCertificates(
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => []);

      final container = makeContainer();
      addTearDown(container.dispose);

      final result = await container.read(certificateListProvider.future);
      expect(result, isEmpty);
    });

    test('propagates ApiError from repository', () async {
      when(
        () => mockRepository.getCertificates(
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(ApiError(message: 'Network failure.', statusCode: null));

      final container = makeContainer();
      addTearDown(container.dispose);
      final sub = container.listen(certificateListProvider, (_, _) {});
      addTearDown(sub.close);

      await expectLater(
        container.read(certificateListProvider.future),
        throwsA(isA<ApiError>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // certificateDetailProvider
  // ---------------------------------------------------------------------------

  group('certificateDetailProvider', () {
    test('returns certificate detail for valid id', () async {
      final detail = CertificateDetail(
        id: 7,
        certificateNumber: 'GN-007',
        trainingTitle: 'First Aid',
        versionNumber: 2,
        employeeName: 'Alice',
        employeeCode: 'GN-EMP-01',
        issuedAt: DateTime(2024, 3, 15),
        isRevoked: false,
        revokedAt: null,
        assignmentId: 70,
        hasDocument: false,
      );
      when(
        () => mockRepository.getCertificateDetail(
          7,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => detail);

      final container = makeContainer();
      addTearDown(container.dispose);

      final result = await container.read(certificateDetailProvider(7).future);
      expect(result!.id, 7);
      expect(result.certificateNumber, 'GN-007');
      expect(result.hasDocument, false);
    });

    test('propagates 404 ApiError', () async {
      when(
        () => mockRepository.getCertificateDetail(
          999,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(ApiError(message: 'Not found.', statusCode: 404));

      final container = makeContainer();
      addTearDown(container.dispose);
      final sub = container.listen(certificateDetailProvider(999), (_, _) {});
      addTearDown(sub.close);

      await expectLater(
        container.read(certificateDetailProvider(999).future),
        throwsA(isA<ApiError>()),
      );
    });

    test('throws ArgumentError for non-positive id', () async {
      final container = makeContainer();
      addTearDown(container.dispose);

      await expectLater(
        container.read(certificateDetailProvider(0).future),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  test('logout clears loaded certificates and does not refetch', () async {
    when(
      () => mockRepository.getCertificates(
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) async => [
        Certificate(
          id: 1,
          certificateNumber: 'A',
          trainingTitle: 'QA',
          versionNumber: 1,
          issuedAt: DateTime.utc(2026),
          isRevoked: false,
        ),
      ],
    );
    final container = makeContainer();
    addTearDown(container.dispose);
    container.listen(certificateListProvider, (_, _) {});
    await container.read(certificateListProvider.future);
    auth.change(AuthUnauthenticated());
    expect(container.read(certificateListProvider).value, isEmpty);
    await expectLater(
      container.read(certificateListProvider.future),
      throwsA(isA<ApiError>()),
    );
    verify(
      () => mockRepository.getCertificates(
        cancelToken: any(named: 'cancelToken'),
      ),
    ).called(1);
  });

  test(
    'switching accounts cancels pending requests and ignores the old response',
    () async {
      final old = Completer<List<Certificate>>();
      final next = Completer<List<Certificate>>();
      final requests = <CancelToken>[];
      when(
        () => mockRepository.getCertificates(
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((invocation) {
        requests.add(invocation.namedArguments[#cancelToken] as CancelToken);
        return requests.length == 1 ? old.future : next.future;
      });
      final container = makeContainer();
      addTearDown(container.dispose);
      container.listen(certificateListProvider, (_, _) {});
      await Future<void>.delayed(Duration.zero);
      auth.change(AuthAuthenticated(_employee('B')));
      expect(container.read(certificateListProvider).value, isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(requests.first.isCancelled, isTrue);
      old.complete([
        Certificate(
          id: 1,
          certificateNumber: 'OLD',
          trainingTitle: 'Old',
          versionNumber: 1,
          issuedAt: DateTime.utc(2026),
          isRevoked: false,
        ),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(certificateListProvider).value, isEmpty);
      next.complete([]);
      expect(await container.read(certificateListProvider.future), isEmpty);
    },
  );

  test(
    'loaded detail is cleared before another account receives a denied lookup',
    () async {
      final detail = CertificateDetail(
        id: 7,
        certificateNumber: 'PRIVATE-A',
        trainingTitle: 'QA',
        versionNumber: 1,
        employeeName: 'A',
        employeeCode: 'A',
        issuedAt: DateTime.utc(2026),
        isRevoked: false,
        revokedAt: null,
        assignmentId: 1,
        hasDocument: false,
      );
      when(
        () => mockRepository.getCertificateDetail(
          7,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => detail);
      final container = makeContainer();
      addTearDown(container.dispose);
      final provider = certificateDetailProvider(7);
      container.listen(provider, (_, _) {});
      expect((await container.read(provider.future))!.employeeCode, 'A');
      when(
        () => mockRepository.getCertificateDetail(
          7,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(ApiError(message: 'Not found', statusCode: 404));
      auth.change(AuthAuthenticated(_employee('B')));
      expect(container.read(provider).value, isNull);
      await expectLater(
        container.read(provider.future),
        throwsA(isA<ApiError>()),
      );
      expect(container.read(provider).value, isNull);
    },
  );

  test(
    'permission denial on refresh clears previously loaded certificate detail',
    () async {
      final detail = CertificateDetail(
        id: 7,
        certificateNumber: 'PRIVATE',
        trainingTitle: 'QA',
        versionNumber: 1,
        employeeName: 'A',
        employeeCode: 'A',
        issuedAt: DateTime.utc(2026),
        isRevoked: false,
        revokedAt: null,
        assignmentId: 1,
        hasDocument: false,
      );
      when(
        () => mockRepository.getCertificateDetail(
          7,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => detail);
      final container = makeContainer();
      addTearDown(container.dispose);
      final provider = certificateDetailProvider(7);
      container.listen(provider, (_, _) {});
      await container.read(provider.future);
      when(
        () => mockRepository.getCertificateDetail(
          7,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(ApiError(message: 'Employee inactive', statusCode: 403));
      container.invalidate(provider);
      await container.read(provider.future);
      await Future<void>.delayed(Duration.zero);
      expect(
        container.read(provider).error,
        isA<ApiError>().having((error) => error.statusCode, 'status', 403),
      );
      await expectLater(
        container.read(provider.future),
        throwsA(isA<ApiError>()),
      );
      expect(container.read(provider).value, isNull);
    },
  );
}
