import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
import 'package:training_app/core/theme/app_theme.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/learning/domain/models/assignment_detail.dart';
import 'package:training_app/features/learning/presentation/controllers/learning_controller.dart';
import 'package:training_app/features/notifications/data/repositories/notification_repository.dart';
import 'package:training_app/features/notifications/presentation/screens/notification_center_screen.dart';

import '../../notification_fixtures.dart';

void main() {
  late MockNotificationRepository repository;
  late NotificationTestAuth authController;
  late ProviderContainer container;
  late GoRouter router;
  final navigatedRoutes = <String>[];

  setUpAll(() {
    registerNotificationFallbacks();
  });

  setUp(() {
    repository = MockNotificationRepository();
    authController = NotificationTestAuth();
    navigatedRoutes.clear();

    stubNotifications(repository);
  });

  tearDown(() {
    router.dispose();
    container.dispose();
  });

  Widget buildTestApp() {
    authController = NotificationTestAuth();
    container = ProviderContainer(
      overrides: [
        notificationRepositoryProvider.overrideWithValue(repository),
        authControllerProvider.overrideWith(() => authController),
        assignmentDetailProvider(55).overrideWith((_) async => AssignmentDetail(
              id: 55,
              trainingId: 10,
              trainingTitle: 'Safety Orientation 55',
              versionNumber: 1,
              status: 'IN_PROGRESS',
              isOverdue: false,
              modules: [],
            )),
      ],
    );

    router = GoRouter(
      initialLocation: '/notifications',
      routes: [
        GoRoute(
          path: '/notifications',
          builder: (_, _) => const NotificationCenterScreen(),
        ),
        GoRoute(
          path: '/learning/assignments/:id',
          builder: (context, state) {
            navigatedRoutes.add(state.uri.toString());
            return Scaffold(body: Text('Assignment ${state.pathParameters['id']}'));
          },
        ),
      ],
    );

    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        theme: AppTheme.lightTheme,
      ),
    );
  }

  group('M18 Notification Center Release Acceptance & Deep Linking', () {
    testWidgets('1. Notification item tap navigates to assignment deep link target', (tester) async {
      when(
        () => repository.getPage(
          page: any(named: 'page'),
          status: any(named: 'status'),
          query: any(named: 'query'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => noticePage(
          items: [
            notice(id: 101, assignmentId: 55, type: 'ASSIGNED'),
          ],
        ),
      );

      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      final openBtn = find.text('Open training');
      expect(openBtn, findsOneWidget);

      await tester.tap(openBtn);
      await tester.pumpAndSettle();

      expect(navigatedRoutes, contains('/learning/assignments/55'));
      expect(find.text('Assignment 55'), findsOneWidget);
    });

    testWidgets('2. Empty notification inbox displays clear caught-up state without error', (tester) async {
      when(
        () => repository.getPage(
          page: any(named: 'page'),
          status: any(named: 'status'),
          query: any(named: 'query'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => noticePage(items: [], count: 0));
      when(() => repository.getUnreadCount(cancelToken: any(named: 'cancelToken'))).thenAnswer((_) async => 0);

      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      expect(find.text('You’re all caught up. Training updates will appear here.'), findsOneWidget);
    });

    testWidgets('3. Mark all read calls repository and refreshes unread count', (tester) async {
      when(
        () => repository.getPage(
          page: any(named: 'page'),
          status: any(named: 'status'),
          query: any(named: 'query'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => noticePage(
          items: [
            notice(id: 1, read: false),
            notice(id: 2, read: false),
          ],
          count: 2,
        ),
      );
      when(() => repository.getUnreadCount(cancelToken: any(named: 'cancelToken'))).thenAnswer((_) async => 2);
      when(() => repository.markAllRead(cancelToken: any(named: 'cancelToken'))).thenAnswer((_) async => 2);

      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      final markAllFinder = find.byTooltip('Mark all as read');
      expect(markAllFinder, findsOneWidget);

      await tester.tap(markAllFinder);
      await tester.pumpAndSettle();

      verify(() => repository.markAllRead(cancelToken: any(named: 'cancelToken'))).called(1);
    });

    testWidgets('4. Session expiry (401) during notification load offers sign-in recovery', (tester) async {
      when(
        () => repository.getPage(
          page: any(named: 'page'),
          status: any(named: 'status'),
          query: any(named: 'query'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(ApiError.fromBackend(401, {'detail': 'Given token not valid for any token type'}));

      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      expect(find.byType(ApiErrorView), findsOneWidget);
    });

    testWidgets('5. Narrow screen (320x640) with large text renders notification items without overflow', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearAllTestValues);

      when(
        () => repository.getPage(
          page: any(named: 'page'),
          status: any(named: 'status'),
          query: any(named: 'query'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => noticePage(
          items: [
            notice(id: 1, type: 'OVERDUE'),
          ],
        ),
      );

      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('Training update 1'),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Training update 1'), findsOneWidget);
    });
  });
}
