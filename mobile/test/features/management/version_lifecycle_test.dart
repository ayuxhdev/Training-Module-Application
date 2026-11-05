import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/network/dio_client.dart';
import 'package:training_app/core/theme/app_theme.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/data/repositories/management_repository.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';
import 'package:training_app/features/management/presentation/controllers/management_controller.dart';
import 'package:training_app/features/management/presentation/screens/managed_version_detail_screen.dart';

import 'management_fixtures.dart';

class _Repository extends Mock implements ManagementRepository {}

class _Client extends Mock implements ApiClient {}

class _Dio extends Mock implements Dio {}

ManagedTrainingVersionItem result(String status) =>
    ManagedTrainingVersionItem.fromJson(
      managedTrainingVersionJson(id: 20, status: status),
    );

class _Screen {
  final repository = _Repository();
  late final ManagementTestAuth auth;
  late final ProviderContainer container;
  String status;
  _Screen({this.status = 'DRAFT', bool permitted = true}) {
    auth = ManagementTestAuth(
      managementIdentity(
        capabilities: {
          'training.view_trainingversion',
          'training.add_module',
          if (permitted) 'training.change_trainingversion',
        },
      ),
    );
    when(
      () =>
          repository.versionDetail(20, cancelToken: any(named: 'cancelToken')),
    ).thenAnswer(
      (_) async => ManagedVersionDetail.fromJson(
        managedVersionDetailJson(id: 20, status: status),
      ),
    );
    container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWith(() => auth),
        managementRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);
  }
  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.lightTheme,
          home: const ManagedVersionDetailScreen(versionId: 20),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> confirm(WidgetTester tester, {bool publish = true}) async {
    final button = find.text(publish ? 'Publish version' : 'Retire version');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(FilledButton, publish ? 'Publish' : 'Retire'),
    );
    await tester.pumpAndSettle();
  }
}

void main() {
  setUpAll(() {
    registerFallbackValue(CancelToken());
  });

  for (final publish in [true, false]) {
    final verb = publish ? 'publish' : 'retire';
    test(
      'repository $verb posts once to the actual API path and parses summary',
      () async {
        final client = _Client();
        final dio = _Dio();
        when(() => client.dio).thenReturn(dio);
        final path = '/management/versions/20/$verb/';
        when(
          () => dio.post(
            path,
            data: <String, Object?>{},
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => Response(
            requestOptions: RequestOptions(path: path),
            statusCode: 200,
            data: managedTrainingVersionJson(
              id: 20,
              status: publish ? 'PUBLISHED' : 'RETIRED',
            ),
          ),
        );
        final repository = ManagementRepository(client);
        final version = publish
            ? await repository.publishVersion(20)
            : await repository.retireVersion(20);
        expect(version.status, publish ? 'PUBLISHED' : 'RETIRED');
        verify(
          () => dio.post(
            path,
            data: <String, Object?>{},
            cancelToken: any(named: 'cancelToken'),
          ),
        ).called(1);
      },
    );

    test(
      '$verb controller denies missing change permission before dispatch',
      () async {
        final repository = _Repository();
        final controller = VersionLifecycleController(
          repository: repository,
          readAuth: () => AuthAuthenticated.identity(
            managementIdentity(capabilities: {'training.view_trainingversion'}),
          ),
        );
        await expectLater(
          controller.transition(versionId: 20, publish: publish),
          throwsA(isA<ApiError>()),
        );
        verifyZeroInteractions(repository);
      },
    );

    test(
      '$verb controller rejects late results after account switching',
      () async {
        final repository = _Repository();
        AuthState auth = AuthAuthenticated.identity(
          managementIdentity(capabilities: {'training.change_trainingversion'}),
        );
        final response = Completer<ManagedTrainingVersionItem>();
        if (publish) {
          when(
            () => repository.publishVersion(
              20,
              cancelToken: any(named: 'cancelToken'),
            ),
          ).thenAnswer((_) => response.future);
        } else {
          when(
            () => repository.retireVersion(
              20,
              cancelToken: any(named: 'cancelToken'),
            ),
          ).thenAnswer((_) => response.future);
        }
        final controller = VersionLifecycleController(
          repository: repository,
          readAuth: () => auth,
        );
        final work = expectLater(
          controller.transition(versionId: 20, publish: publish),
          throwsA(isA<ApiError>()),
        );
        auth = AuthAuthenticated.identity(
          managementIdentity(
            username: 'other',
            capabilities: {'training.change_trainingversion'},
          ),
        );
        response.complete(result(publish ? 'PUBLISHED' : 'RETIRED'));
        await work;
      },
    );

    testWidgets(
      '$verb requires confirmation, disables repeat requests, refreshes authoritative status',
      (tester) async {
        final screen = _Screen(status: publish ? 'DRAFT' : 'PUBLISHED');
        final response = Completer<ManagedTrainingVersionItem>();
        if (publish) {
          when(
            () => screen.repository.publishVersion(
              20,
              cancelToken: any(named: 'cancelToken'),
            ),
          ).thenAnswer((_) => response.future);
        } else {
          when(
            () => screen.repository.retireVersion(
              20,
              cancelToken: any(named: 'cancelToken'),
            ),
          ).thenAnswer((_) => response.future);
        }
        await screen.open(tester);
        final label = publish ? 'Publish version' : 'Retire version';
        await tester.ensureVisible(find.text(label));
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        expect(
          find.text(publish ? 'Publish this version?' : 'Retire this version?'),
          findsOneWidget,
        );
        await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
        await tester.pumpAndSettle();
        verifyNever(
          () => screen.repository.publishVersion(
            20,
            cancelToken: any(named: 'cancelToken'),
          ),
        );
        verifyNever(
          () => screen.repository.retireVersion(
            20,
            cancelToken: any(named: 'cancelToken'),
          ),
        );
        await screen.confirm(tester, publish: publish);
        final busy = find.widgetWithText(
          FilledButton,
          publish ? 'Publishing...' : 'Retiring...',
        );
        expect(tester.widget<FilledButton>(busy).onPressed, isNull);
        screen.status = publish ? 'PUBLISHED' : 'RETIRED';
        response.complete(result(screen.status));
        await tester.pumpAndSettle();
        expect(
          find.text(publish ? 'Version published.' : 'Version retired.'),
          findsOneWidget,
        );
        expect(find.text(label), findsNothing);
        expect(find.byTooltip('Create module'), findsNothing);
        if (publish) {
          verify(
            () => screen.repository.publishVersion(
              20,
              cancelToken: any(named: 'cancelToken'),
            ),
          ).called(1);
        } else {
          verify(
            () => screen.repository.retireVersion(
              20,
              cancelToken: any(named: 'cancelToken'),
            ),
          ).called(1);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final status in ['DRAFT', 'PUBLISHED', 'RETIRED']) {
    testWidgets('$status hides unauthorized or unavailable lifecycle actions', (
      tester,
    ) async {
      final screen = _Screen(status: status, permitted: status == 'RETIRED');
      await screen.open(tester);
      expect(find.text('Publish version'), findsNothing);
      expect(find.text('Retire version'), findsNothing);
    });
  }

  testWidgets(
    'publication validation is readable and never automatically retried',
    (tester) async {
      final screen = _Screen();
      when(
        () => screen.repository.publishVersion(
          20,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(
        ApiError(
          message: 'Invalid input.',
          statusCode: 400,
          details: {
            'non_field_errors': [
              'Publication requires exactly one final assessment.',
            ],
          },
        ),
      );
      await screen.open(tester);
      await screen.confirm(tester);
      expect(
        find.text('Publication requires exactly one final assessment.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Publish version'),
            )
            .onPressed,
        isNotNull,
      );
      verify(
        () => screen.repository.publishVersion(
          20,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
    },
  );

  testWidgets(
    'account switch during confirmation cannot dispatch old operation',
    (tester) async {
      final screen = _Screen();
      await screen.open(tester);
      await tester.ensureVisible(find.text('Publish version'));
      await tester.tap(find.text('Publish version'));
      await tester.pumpAndSettle();
      screen.auth.setAuth(
        AuthAuthenticated.identity(
          managementIdentity(
            username: 'second',
            capabilities: {
              'training.view_trainingversion',
              'training.change_trainingversion',
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Publish'));
      await tester.pumpAndSettle();
      verifyNever(
        () => screen.repository.publishVersion(
          20,
          cancelToken: any(named: 'cancelToken'),
        ),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'account switch cancels pending action and hides its late result',
    (tester) async {
      final screen = _Screen();
      final response = Completer<ManagedTrainingVersionItem>();
      CancelToken? active;
      when(
        () => screen.repository.publishVersion(
          20,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((call) {
        active = call.namedArguments[#cancelToken] as CancelToken;
        return response.future;
      });
      await screen.open(tester);
      await screen.confirm(tester);
      screen.auth.setAuth(AuthUnauthenticated());
      await tester.pumpAndSettle();
      expect(active!.isCancelled, isTrue);
      response.complete(result('PUBLISHED'));
      await tester.pumpAndSettle();
      expect(find.text('Version published.'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
