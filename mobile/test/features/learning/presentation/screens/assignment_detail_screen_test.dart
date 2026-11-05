import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/presentation/components/error_view.dart';
import 'package:training_app/core/presentation/components/loading_view.dart';
import 'package:training_app/core/presentation/components/primary_button.dart';
import 'package:training_app/features/learning/domain/models/assignment_detail.dart';
import 'package:training_app/features/learning/presentation/controllers/learning_controller.dart';
import 'package:training_app/features/learning/presentation/screens/assignment_detail_screen.dart';

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/router/app_router.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/certificates/data/repositories/certificate_repository.dart';
import 'package:training_app/features/certificates/domain/models/certificate_detail.dart';
import 'package:training_app/features/learning/data/repositories/learning_repository.dart';
import 'package:training_app/features/notifications/presentation/controllers/notification_controller.dart';

import '../../../notifications/notification_fixtures.dart';

class _Learning extends Mock implements LearningRepository {}

class _Certificates extends Mock implements CertificateRepository {}

Map<String, dynamic> _assignmentJson({
  String status = 'COMPLETED',
  int? certificateId = 123,
}) => {
  'id': 1,
  'training_id': 101,
  'training_title': 'Safety Basics',
  'version_number': 1,
  'status': status,
  'certificate_id': certificateId,
  'is_overdue': false,
  'modules': [],
};

class _CertificateNavigation {
  final learning = _Learning();
  final certificates = _Certificates();
  final auth = NotificationTestAuth();
  late final ProviderContainer container;
  late final GoRouter router;
  late Future<AssignmentDetail> Function() loadAssignment;
  late Future<CertificateDetail> Function() loadCertificate;

  _CertificateNavigation({Map<String, dynamic>? json}) {
    loadAssignment = () async =>
        AssignmentDetail.fromJson(json ?? _assignmentJson());
    loadCertificate = () async => CertificateDetail(
      id: 123,
      certificateNumber: 'QA-123',
      trainingTitle: 'Safety Basics',
      versionNumber: 1,
      employeeName: 'Original account',
      employeeCode: 'A',
      issuedAt: DateTime(2026, 11, 5),
      isRevoked: false,
      revokedAt: null,
      assignmentId: 1,
      hasDocument: false,
    );
    when(
      () => learning.getAssignmentDetail(
        1,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => loadAssignment());
    when(
      () => certificates.getCertificateDetail(
        123,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => loadCertificate());
    when(
      () =>
          certificates.getCertificates(cancelToken: any(named: 'cancelToken')),
    ).thenAnswer((_) async => []);
    container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWith(() => auth),
        notificationUnreadCountProvider.overrideWith(ZeroUnreadController.new),
        learningRepositoryProvider.overrideWithValue(learning),
        certificateRepositoryProvider.overrideWithValue(certificates),
        assignmentListProvider.overrideWith((_) async => []),
      ],
    );
    router = container.read(appRouterProvider);
    addTearDown(container.dispose);
    addTearDown(router.dispose);
  }

  Future<void> open(
    WidgetTester tester, {
    String path = '/learning/assignments/1',
  }) async {
    router.go(path);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String label) async {
    final target = find.text(label);
    if (target.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        target,
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
    }
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }
}

void main() {
  setUpAll(() => registerFallbackValue(CancelToken()));
  Widget createTestWidget(ProviderContainer container) {
    return UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: AssignmentDetailScreen(assignmentId: 1)),
    );
  }

  testWidgets(
    'cancelled training explains unavailable curriculum without a Start action',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          assignmentDetailProvider(1).overrideWith(
            (_) async => AssignmentDetail(
              id: 1,
              trainingId: 1,
              trainingTitle: 'Cancelled training',
              versionNumber: 1,
              status: 'CANCELLED',
              isOverdue: false,
              modules: [],
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(createTestWidget(container));
      await tester.pumpAndSettle();
      expect(find.text('Start Training'), findsNothing);
      expect(
        find.text(
          'This assignment was cancelled. Its learning content is unavailable.',
        ),
        findsOneWidget,
      );
      expect(find.text('CANCELLED'), findsOneWidget);
    },
  );

  testWidgets('shows LoadingView while fetching detail', (tester) async {
    final completer = Completer<AssignmentDetail>();
    final container = ProviderContainer(
      overrides: [
        assignmentDetailProvider(1).overrideWith((ref) => completer.future),
      ],
    );

    await tester.pumpWidget(createTestWidget(container));
    expect(find.byType(LoadingView), findsOneWidget);

    // Clean up
    completer.complete(
      AssignmentDetail(
        id: 1,
        trainingId: 101,
        trainingTitle: 'Cleanup',
        versionNumber: 1,
        status: 'ASSIGNED',
        isOverdue: false,
        modules: [],
      ),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('shows ErrorView when fetching detail fails', (tester) async {
    final container = ProviderContainer(
      overrides: [
        assignmentDetailProvider(1).overrideWith((ref) async {
          throw Exception('Failed to fetch detail');
        }),
      ],
    );

    await tester.pumpWidget(createTestWidget(container));
    await tester.pumpAndSettle();

    expect(find.byType(ErrorView), findsOneWidget);
  });

  testWidgets(
    'shows AssignmentDetail on successful fetch and handles primary button tap',
    (tester) async {
      final mockDetail = AssignmentDetail(
        id: 1,
        trainingId: 101,
        trainingTitle: 'Safety Basics',
        versionNumber: 1,
        status: 'IN_PROGRESS',
        isOverdue: false,
        dueAt: DateTime(2023, 10, 1),
        modules: [],
      );

      final container = ProviderContainer(
        overrides: [
          assignmentDetailProvider(1).overrideWith((ref) async => mockDetail),
        ],
      );

      await tester.pumpWidget(createTestWidget(container));
      await tester.pumpAndSettle();

      expect(find.text('Safety Basics'), findsOneWidget);
      expect(find.text('Due: 2023-10-01'), findsOneWidget);
      expect(find.text('Progress: 0/0 lessons'), findsOneWidget);

      expect(find.text('Progress: 0/0 lessons'), findsOneWidget);
      expect(find.byType(PrimaryButton), findsOneWidget);
    },
  );

  testWidgets('Start Training button navigates to modules list route', (
    tester,
  ) async {
    final mockDetail = AssignmentDetail(
      id: 1,
      trainingId: 101,
      trainingTitle: 'Safety Basics',
      versionNumber: 1,
      status: 'IN_PROGRESS',
      isOverdue: false,
      dueAt: DateTime(2023, 10, 1),
      modules: [],
    );

    final container = ProviderContainer(
      overrides: [
        assignmentDetailProvider(1).overrideWith((ref) async => mockDetail),
      ],
    );

    final router = GoRouter(
      initialLocation: '/detail',
      routes: [
        GoRoute(
          path: '/detail',
          builder: (context, state) =>
              const AssignmentDetailScreen(assignmentId: 1),
        ),
        GoRoute(
          path: '/learning/assignments/:id/modules',
          builder: (context, state) =>
              Text('Modules Route for ${state.pathParameters['id']}'),
        ),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );

    await tester.pumpAndSettle();

    final button = find.widgetWithText(PrimaryButton, 'Start Training');
    expect(button, findsOneWidget);

    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(find.text('Modules Route for 1'), findsOneWidget);
  });

  for (final json in [
    _assignmentJson(),
    _assignmentJson(certificateId: null),
    {..._assignmentJson()}..remove('certificate_id'),
  ]) {
    test(
      'certificate ID parses as nullable: ${json.containsKey('certificate_id') ? json['certificate_id'] : 'omitted'}',
      () {
        final detail = AssignmentDetail.fromJson(json);
        expect(detail.certificateId, json['certificate_id']);
        expect(detail.id, 1);
        expect(detail.trainingTitle, 'Safety Basics');
      },
    );
  }

  testWidgets(
    'completed assignment opens its Certificate directly, preserving other actions',
    (tester) async {
      final fixture = _CertificateNavigation();
      await fixture.open(tester);
      expect(find.text('Certificate'), findsOneWidget);
      expect(find.text('My Certificates'), findsNothing);
      expect(find.text('Start Training'), findsOneWidget);
      expect(find.text('Assessments and attempts'), findsOneWidget);
      await fixture.tap(tester, 'Certificate');
      expect(fixture.router.state.matchedLocation, '/profile/certificates/123');
      expect(find.text('QA-123'), findsOneWidget);
      verify(
        () => fixture.certificates.getCertificateDetail(
          123,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
    },
  );

  for (final json in [
    _assignmentJson(certificateId: null),
    {..._assignmentJson()}..remove('certificate_id'),
    _assignmentJson(status: 'IN_PROGRESS'),
    _assignmentJson(status: 'ASSIGNED'),
    _assignmentJson(status: 'CANCELLED'),
  ]) {
    testWidgets(
      'certificate action absent for ${json['status']} / ${json.containsKey('certificate_id') ? json['certificate_id'] : 'omitted'}',
      (tester) async {
        final fixture = _CertificateNavigation(json: json);
        await fixture.open(tester);
        expect(find.text('Certificate'), findsNothing);
        expect(find.text('My Certificates'), findsNothing);
        expect(find.text('Assessments and attempts'), findsOneWidget);
        verifyNever(
          () => fixture.certificates.getCertificateDetail(
            any(),
            cancelToken: any(named: 'cancelToken'),
          ),
        );
      },
    );
  }

  testWidgets('Profile My Certificates keeps the global list route', (
    tester,
  ) async {
    final fixture = _CertificateNavigation();
    await fixture.open(tester, path: '/profile');
    await fixture.tap(tester, 'My Certificates');
    expect(fixture.router.state.matchedLocation, '/profile/certificates');
  });

  for (final code in [403, 404]) {
    testWidgets(
      'certificate $code remains on the secured detail route without guessing another record',
      (tester) async {
        final fixture = _CertificateNavigation();
        fixture.loadCertificate = () async => throw ApiError(
          message: 'Certificate unavailable.',
          statusCode: code,
        );
        await fixture.open(tester);
        await fixture.tap(tester, 'Certificate');
        expect(
          fixture.router.state.matchedLocation,
          '/profile/certificates/123',
        );
        expect(find.text('Certificate unavailable.'), findsOneWidget);
        expect(find.text('QA-123'), findsNothing);
        verify(
          () => fixture.certificates.getCertificateDetail(
            123,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).called(1);
      },
    );
  }

  testWidgets(
    'account switch removes the old certificate action while assignment reloads',
    (tester) async {
      final fixture = _CertificateNavigation();
      await fixture.open(tester);
      expect(find.text('Certificate'), findsOneWidget);
      final pending = Completer<AssignmentDetail>();
      fixture.loadAssignment = () => pending.future;
      fixture.auth.change(AuthAuthenticated(noticeEmployee('B')));
      await tester.pump();
      expect(find.text('Certificate'), findsNothing);
      pending.complete(
        AssignmentDetail.fromJson(_assignmentJson(certificateId: null)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Certificate'), findsNothing);
      verifyNever(
        () => fixture.certificates.getCertificateDetail(
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
    },
  );

  testWidgets(
    'open certificate hides previous-account data and preserves access-denied behavior',
    (tester) async {
      final fixture = _CertificateNavigation();
      await fixture.open(tester);
      await fixture.tap(tester, 'Certificate');
      expect(find.text('QA-123'), findsOneWidget);
      final pending = Completer<CertificateDetail>();
      fixture.loadCertificate = () => pending.future;
      fixture.auth.change(AuthAuthenticated(noticeEmployee('B')));
      await tester.pump();
      expect(find.text('QA-123'), findsNothing);
      pending.completeError(
        ApiError(message: 'Certificate unavailable.', statusCode: 403),
      );
      await tester.pumpAndSettle();
      expect(find.text('QA-123'), findsNothing);
      expect(find.text('Certificate unavailable.'), findsOneWidget);
      expect(fixture.router.state.matchedLocation, '/profile/certificates/123');
    },
  );
}
