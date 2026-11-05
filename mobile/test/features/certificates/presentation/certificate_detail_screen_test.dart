import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/presentation/formatters/date_labels.dart';
import 'package:training_app/core/theme/app_theme.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/employee.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/certificates/data/repositories/certificate_repository.dart';
import 'package:training_app/features/certificates/domain/models/certificate_detail.dart';
import 'package:training_app/features/certificates/presentation/screens/certificate_detail_screen.dart';
import 'package:training_app/features/learning/data/repositories/learning_repository.dart';
import 'package:training_app/features/learning/domain/models/assignment_detail.dart';

class _Certificates extends Mock implements CertificateRepository {}

class _Learning extends Mock implements LearningRepository {}

class _Auth extends AuthController {
  bool loggedOut = false;
  @override
  AuthState build() => AuthAuthenticated(_employee('current'));
  void change(String username) =>
      state = AuthAuthenticated(_employee(username));
  @override
  Future<void> logout() async {
    loggedOut = true;
    state = AuthUnauthenticated();
  }
}

Employee _employee(String username) => Employee(
  username: username,
  employeeCode: username,
  displayName: 'Current employee name',
  department: 'Operations',
  jobRole: 'Learner',
  isActive: true,
);

CertificateDetail _certificate({
  bool revoked = false,
  bool document = false,
  bool long = false,
}) => CertificateDetail(
  id: 8,
  certificateNumber: long ? 'GN-${'1234567890' * 12}' : 'GN-008',
  employeeName: long
      ? 'Avery ${'Alexandria ' * 16}Rivera'
      : 'Recorded learner name',
  employeeCode: long ? 'EMP-${'0123456789' * 8}' : 'EMP-008',
  trainingTitle: long
      ? 'Advanced ${'workplace safety and operational readiness ' * 12}'
      : 'Workplace safety',
  versionNumber: 3,
  issuedAt: DateTime.utc(2026, 11, 3, 15),
  isRevoked: revoked,
  revokedAt: revoked ? DateTime.utc(2026, 11, 4, 12) : null,
  assignmentId: 1,
  hasDocument: document,
);

AssignmentDetail _assignment({DateTime? completed}) => AssignmentDetail(
  id: 1,
  trainingId: 2,
  trainingTitle: 'Workplace safety',
  versionNumber: 3,
  status: 'COMPLETED',
  completedAt: completed,
  isOverdue: false,
  modules: [],
);

class _Harness {
  final certificates = _Certificates();
  final learning = _Learning();
  final auth = _Auth();
  late final ProviderContainer container;
  late final GoRouter router;
  CertificateDetail record;
  _Harness({CertificateDetail? certificate})
    : record = certificate ?? _certificate() {
    when(
      () => certificates.getCertificateDetail(
        8,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => record);
    when(
      () => learning.getAssignmentDetail(
        1,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) async => _assignment(completed: DateTime.utc(2026, 11, 2, 10)),
    );
    container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWith(() => auth),
        certificateRepositoryProvider.overrideWithValue(certificates),
        learningRepositoryProvider.overrideWithValue(learning),
      ],
    );
    router = GoRouter(
      initialLocation: '/profile/certificates/8',
      routes: [
        GoRoute(
          path: '/profile/certificates',
          builder: (_, _) =>
              const Scaffold(body: Text('Certificate list destination')),
        ),
        GoRoute(
          path: '/profile/certificates/8',
          builder: (_, _) => const CertificateDetailScreen(certificateId: 8),
        ),
      ],
    );
    addTearDown(() {
      router.dispose();
      container.dispose();
    });
  }

  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(430, 900),
    double scale = 1,
    ThemeMode mode = ThemeMode.light,
    bool settle = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: mode,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: true,
            ),
            child: child!,
          ),
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  Future<void> reveal(WidgetTester tester, Finder target) async {
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    expect(target.hitTestable(), findsOneWidget);
  }

  Future<void> expand(WidgetTester tester) async {
    await reveal(tester, find.text('Completion record'));
    await tester.tap(find.text('Completion record'));
    await tester.pumpAndSettle();
  }
}

void main() {
  setUpAll(() => registerFallbackValue(CancelToken()));

  testWidgets(
    'issued certificate displays historical identity, training and dates without verification claims',
    (tester) async {
      final harness = _Harness();
      await harness.open(tester);
      expect(find.text("Garden's Need"), findsOneWidget);
      expect(find.text('Certificate of completion'), findsOneWidget);
      expect(find.text('Recorded learner name'), findsOneWidget);
      expect(find.text('Current employee name'), findsNothing);
      expect(find.text('EMP-008'), findsOneWidget);
      expect(find.text('Workplace safety'), findsOneWidget);
      expect(find.text('Version 3'), findsOneWidget);
      expect(find.text('GN-008'), findsOneWidget);
      expect(
        find.text(localDateLabel(harness.record.issuedAt)),
        findsOneWidget,
      );
      expect(
        find.text("Issued certificate. Not revoked in Garden's Need records."),
        findsOneWidget,
      );
      expect(find.text('Revoked on'), findsNothing);
      verifyNever(
        () => harness.learning.getAssignmentDetail(
          1,
          cancelToken: any(named: 'cancelToken'),
        ),
      );
    },
  );

  testWidgets(
    'revoked certificate retains its historical data and clearly reports revocation',
    (tester) async {
      final harness = _Harness(certificate: _certificate(revoked: true));
      await harness.open(tester);
      expect(
        find.text('Revoked certificate. This credential is no longer valid.'),
        findsOneWidget,
      );
      expect(find.text('Recorded learner name'), findsOneWidget);
      expect(find.text('GN-008'), findsOneWidget);
      expect(find.text('Revoked on'), findsOneWidget);
      expect(
        find.text(localDateLabel(harness.record.revokedAt!)),
        findsOneWidget,
      );
      expect(
        find.text("Issued certificate. Not revoked in Garden's Need records."),
        findsNothing,
      );
    },
  );

  for (final document in [false, true]) {
    testWidgets(
      'has_document=$document never fabricates Download, Share or Print controls',
      (tester) async {
        final harness = _Harness(certificate: _certificate(document: document));
        await harness.open(tester);
        for (final label in [
          'Download',
          'Download certificate',
          'Share',
          'Share certificate',
          'Print',
          'Print certificate',
        ]) {
          expect(find.text(label), findsNothing);
        }
        expect(find.textContaining('Need a printed copy?'), findsOneWidget);
      },
    );
  }

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    for (final scenario in [(320.0, 1.0), (320.0, 2.5), (800.0, 1.0)]) {
      testWidgets(
        'long certificate fits ${scenario.$1} width, ${scenario.$2} text, $mode',
        (tester) async {
          final harness = _Harness(certificate: _certificate(long: true));
          await harness.open(
            tester,
            size: Size(scenario.$1, 900),
            scale: scenario.$2,
            mode: mode,
          );
          expect(find.text(harness.record.employeeName), findsOneWidget);
          expect(find.text(harness.record.trainingTitle), findsOneWidget);
          expect(find.text(harness.record.certificateNumber), findsOneWidget);
          expect(find.text(harness.record.employeeCode), findsOneWidget);
          final version = tester.getTopLeft(find.text('Training version'));
          final issued = tester.getTopLeft(find.text('Issued'));
          if (scenario.$1 == 800) {
            expect(issued.dy, version.dy);
          } else {
            expect(issued.dy, greaterThan(version.dy));
          }
          await harness.reveal(tester, find.text('All certificates'));
          expect(
            tester
                .getSize(
                  find.widgetWithText(OutlinedButton, 'All certificates'),
                )
                .height,
            greaterThanOrEqualTo(48),
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'certificate heading and refresh action have accessible semantics',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final harness = _Harness();
        await harness.open(tester);
        expect(
          tester
              .getSemantics(find.text('Certificate of completion'))
              .getSemanticsData()
              .flagsCollection
              .isHeader,
          isTrue,
        );
        expect(find.byTooltip('Refresh certificate'), findsOneWidget);
        expect(
          tester.getSize(find.byTooltip('Refresh certificate')).height,
          greaterThanOrEqualTo(48),
        );
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('loading then success renders without stale data', (
    tester,
  ) async {
    final harness = _Harness();
    final response = Completer<CertificateDetail>();
    when(
      () => harness.certificates.getCertificateDetail(
        8,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => response.future);
    await harness.open(tester, settle: false);
    expect(find.text('Loading certificate details...'), findsOneWidget);
    expect(find.text('Recorded learner name'), findsNothing);
    response.complete(harness.record);
    await tester.pumpAndSettle();
    expect(find.text('Recorded learner name'), findsOneWidget);
  });

  testWidgets('network error offers a working read-only retry', (tester) async {
    final harness = _Harness();
    when(
      () => harness.certificates.getCertificateDetail(
        8,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenThrow(ApiError.networkFailure());
    await harness.open(tester);
    expect(find.text('Connection unavailable'), findsOneWidget);
    expect(find.text('Recorded learner name'), findsNothing);
    when(
      () => harness.certificates.getCertificateDetail(
        8,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => harness.record);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Recorded learner name'), findsOneWidget);
  });

  for (final status in [401, 403, 404]) {
    testWidgets(
      'HTTP $status hides certificate data and offers only appropriate recovery',
      (tester) async {
        final harness = _Harness();
        when(
          () => harness.certificates.getCertificateDetail(
            8,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenThrow(
          ApiError(
            message: status == 404
                ? 'Certificate not found.'
                : 'Sign in to continue.',
            statusCode: status,
          ),
        );
        await harness.open(tester);
        expect(find.text('Recorded learner name'), findsNothing);
        expect(find.text('GN-008'), findsNothing);
        if (status == 404) {
          expect(find.text('Certificate not found.'), findsOneWidget);
          expect(find.text('Retry'), findsNothing);
        } else {
          await tester.tap(find.text('Sign in again'));
          await tester.pumpAndSettle();
          expect(harness.auth.loggedOut, isTrue);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'completion date is loaded on demand independently of issuance and reduced motion is respected',
    (tester) async {
      final harness = _Harness();
      await harness.open(tester);
      verifyNever(
        () => harness.learning.getAssignmentDetail(
          1,
          cancelToken: any(named: 'cancelToken'),
        ),
      );
      expect(
        tester
            .widget<ExpansionTile>(find.byType(ExpansionTile))
            .expansionAnimationStyle,
        AnimationStyle.noAnimation,
      );
      await harness.expand(tester);
      expect(find.text('COMPLETED'), findsOneWidget);
      expect(
        find.text(localDateLabel(DateTime.utc(2026, 11, 2, 10))),
        findsOneWidget,
      );
      expect(
        find.text(localDateLabel(harness.record.issuedAt)),
        findsOneWidget,
      );
      verify(
        () => harness.learning.getAssignmentDetail(
          1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
    },
  );

  testWidgets(
    'missing completion timestamp is not replaced by the issue date',
    (tester) async {
      final harness = _Harness();
      when(
        () => harness.learning.getAssignmentDetail(
          1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => _assignment());
      await harness.open(tester);
      await harness.expand(tester);
      expect(find.text('Not recorded'), findsOneWidget);
      expect(
        find.text(localDateLabel(harness.record.issuedAt)),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'completion read failure preserves the certificate and supports retry',
    (tester) async {
      final harness = _Harness();
      when(
        () => harness.learning.getAssignmentDetail(
          1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(ApiError.networkFailure());
      await harness.open(tester);
      await harness.expand(tester);
      expect(find.text('GN-008'), findsOneWidget);
      expect(find.text('Connection unavailable'), findsOneWidget);
      when(
        () => harness.learning.getAssignmentDetail(
          1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => _assignment(completed: DateTime.utc(2026, 11, 2)),
      );
      await harness.reveal(tester, find.text('Retry'));
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Completed on'), findsOneWidget);
      expect(find.text('Connection unavailable'), findsNothing);
    },
  );

  testWidgets('refresh uses current server revocation status', (tester) async {
    final harness = _Harness();
    await harness.open(tester);
    harness.record = _certificate(revoked: true);
    await tester.tap(find.byTooltip('Refresh certificate'));
    await tester.pumpAndSettle();
    expect(
      find.text('Revoked certificate. This credential is no longer valid.'),
      findsOneWidget,
    );
  });

  testWidgets('All certificates retains existing navigation', (tester) async {
    final harness = _Harness();
    await harness.open(tester);
    await harness.reveal(tester, find.text('All certificates'));
    await tester.tap(find.text('All certificates'));
    await tester.pumpAndSettle();
    expect(find.text('Certificate list destination'), findsOneWidget);
  });

  testWidgets(
    'account switching hides the prior certificate and ignores late completion data',
    (tester) async {
      final harness = _Harness();
      final response = Completer<AssignmentDetail>();
      when(
        () => harness.learning.getAssignmentDetail(
          1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) => response.future);
      await harness.open(tester);
      await harness.expand(tester);
      expect(find.text('Loading completion record...'), findsOneWidget);
      when(
        () => harness.certificates.getCertificateDetail(
          8,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(ApiError(message: 'Certificate not found.', statusCode: 404));
      harness.auth.change('second');
      await tester.pumpAndSettle();
      response.complete(_assignment(completed: DateTime.utc(2026, 11, 2)));
      await tester.pumpAndSettle();
      expect(find.text('Recorded learner name'), findsNothing);
      expect(find.text('GN-008'), findsNothing);
      expect(find.text('Completed on'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
