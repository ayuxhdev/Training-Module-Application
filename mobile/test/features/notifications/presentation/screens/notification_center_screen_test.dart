import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/router/app_router.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/dashboard/domain/models/dashboard_data.dart';
import 'package:training_app/features/dashboard/presentation/controllers/dashboard_controller.dart';
import 'package:training_app/features/learning/domain/models/assignment_detail.dart';
import 'package:training_app/features/learning/presentation/controllers/learning_controller.dart';
import 'package:training_app/features/learning/presentation/screens/assignment_detail_screen.dart';
import 'package:training_app/features/notifications/data/repositories/notification_repository.dart';
import 'package:training_app/features/notifications/domain/models/training_notification.dart';
import 'package:training_app/main.dart';

import '../../notification_fixtures.dart';

void main() {
  late MockNotificationRepository repository;
  late NotificationTestAuth auth;
  late ProviderContainer container;
  late GoRouter router;

  setUpAll(registerNotificationFallbacks);
  setUp(() {
    repository = MockNotificationRepository();
    stubNotifications(repository);
    auth = NotificationTestAuth();
  });

  Future<void> mount(
    WidgetTester tester, {
    String path = '/notifications',
    bool inaccessible = false,
    Brightness brightness = Brightness.light,
    Size size = const Size(390, 844),
    double scale = 1,
    bool reducedMotion = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.platformBrightnessTestValue = brightness;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        FakeAccessibilityFeatures(disableAnimations: reducedMotion);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWith(() => auth),
        notificationRepositoryProvider.overrideWithValue(repository),
        dashboardDataProvider.overrideWith(
          (_) async => DashboardData(
            metrics: DashboardMetrics(
              total: 0,
              assigned: 0,
              inProgress: 0,
              completed: 0,
              cancelled: 0,
              overdue: 0,
              completionPercent: 0,
              certificatesCount: 0,
            ),
            actionRequired: [],
            recentCertificates: [],
          ),
        ),
        assignmentDetailProvider(1).overrideWith((_) async {
          if (inaccessible) {
            throw ApiError(
              message: 'This assignment is no longer accessible.',
              statusCode: 404,
            );
          }
          return AssignmentDetail(
            id: 1,
            trainingId: 1,
            trainingTitle: 'Owned training',
            versionNumber: 1,
            status: 'IN_PROGRESS',
            isOverdue: false,
            modules: [],
          );
        }),
      ],
    );
    router = container.read(appRouterProvider);
    router.go(path);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
      container.dispose();
      await tester.pump();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const MyApp()),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapText(WidgetTester tester, String label) async {
    final finder = find.text(label);
    if (finder.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        finder,
        140,
        scrollable: find.byType(Scrollable).last,
      );
    }
    await tester.ensureVisible(finder.first);
    await tester.pumpAndSettle();
    await tester.tap(finder.first);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Dashboard bell shows the server unread count and keeps the existing three tabs',
    (tester) async {
      when(
        () => repository.getUnreadCount(cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => 3);
      await mount(tester, path: '/dashboard');
      await tester.tap(find.byTooltip('Notifications, 3 unread'));
      await tester.pumpAndSettle();
      expect(find.text('Your updates'), findsOneWidget);
      expect(find.byType(NavigationDestination), findsNWidgets(3));
      expect(find.text('Dashboard'), findsOneWidget);
      expect(find.text('Learning'), findsOneWidget);
      expect(find.text('Profile'), findsOneWidget);
    },
  );

  for (final event in <String, IconData>{
    'ASSIGNED': Icons.assignment_outlined,
    'APPROACHING': Icons.schedule,
    'OVERDUE': Icons.event_busy,
    'COMPLETED': Icons.task_alt,
  }.entries) {
    testWidgets('${event.key} uses the event icon and a clear unread label', (
      tester,
    ) async {
      when(
        () =>
            repository.getPage(page: 1, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => noticePage(items: [notice(type: event.key)]));
      await mount(tester);
      expect(find.byIcon(event.value), findsOneWidget);
      expect(find.text('Unread'), findsOneWidget);
      expect(find.text('Your training update 1.'), findsOneWidget);
    });
  }

  testWidgets(
    'mark as read uses confirmed state and synchronizes unread count',
    (tester) async {
      await mount(tester);
      when(
        () => repository.getUnreadCount(cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => 0);
      await tapText(tester, 'Mark as read');
      expect(find.text('Read'), findsOneWidget);
      expect(find.text('Mark as read'), findsNothing);
      expect(find.text('0 unread · 1 notification'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.done_all))
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets(
    'reduced-motion loading remains readable until the GET completes',
    (tester) async {
      final pending = Completer<NotificationPage>();
      when(
        () =>
            repository.getPage(page: 1, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) => pending.future);
      await mount(tester, reducedMotion: true);
      expect(find.text('Loading notifications…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      pending.complete(noticePage());
      await tester.pumpAndSettle();
      expect(find.text('Training update 1'), findsOneWidget);
    },
  );

  testWidgets(
    'unread failure never displays zero and supports an explicit count refresh',
    (tester) async {
      when(
        () => repository.getUnreadCount(cancelToken: any(named: 'cancelToken')),
      ).thenThrow(ApiError.networkFailure());
      await mount(tester, path: '/dashboard');
      expect(
        find.byTooltip('Notifications, unread count unavailable'),
        findsOneWidget,
      );
      await tester.tap(
        find.byTooltip('Notifications, unread count unavailable'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Unread count unavailable'), findsOneWidget);
      when(
        () => repository.getUnreadCount(cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => 2);
      await tapText(tester, 'Refresh unread count');
      expect(find.text('2 unread · 1 notification'), findsOneWidget);
    },
  );

  testWidgets('mark all reloads read states and disables repeated actions', (
    tester,
  ) async {
    await mount(tester);
    when(
      () => repository.getPage(page: 1, cancelToken: any(named: 'cancelToken')),
    ).thenAnswer((_) async => noticePage(items: [notice(read: true)]));
    when(
      () => repository.getUnreadCount(cancelToken: any(named: 'cancelToken')),
    ).thenAnswer((_) async => 0);
    await tester.tap(find.byTooltip('Mark all as read'));
    await tester.pumpAndSettle();
    expect(find.text('Read'), findsOneWidget);
    expect(find.text('Mark as read'), findsNothing);
    verify(() => repository.markAllRead(cancelToken: any(named: 'cancelToken')))
        .called(1);
  });

  testWidgets(
    'offline state offers explicit read recovery without replaying a POST',
    (tester) async {
      when(
        () =>
            repository.getPage(page: 1, cancelToken: any(named: 'cancelToken')),
      ).thenThrow(ApiError.networkFailure());
      await mount(tester);
      expect(find.text('Connection unavailable'), findsOneWidget);
      when(
        () =>
            repository.getPage(page: 1, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => noticePage());
      await tapText(tester, 'Retry');
      expect(find.text('Training update 1'), findsOneWidget);
      verifyNever(
        () =>
            repository.markRead(any(), cancelToken: any(named: 'cancelToken')),
      );
    },
  );

  testWidgets(
    'uncertain mutation hides stale actions and refresh retrieves saved state',
    (tester) async {
      await mount(tester);
      when(() => repository.markRead(1, cancelToken: any(named: 'cancelToken')))
          .thenThrow(ApiError.timeout());
      await tapText(tester, 'Mark as read');
      expect(find.text('Mark as read'), findsNothing);
      expect(
        find.textContaining('Refresh to check the saved read status'),
        findsOneWidget,
      );
      expect(find.text('Read status not confirmed'), findsOneWidget);
      when(
        () =>
            repository.getPage(page: 1, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => noticePage(items: [notice(read: true)]));
      await tapText(tester, 'Refresh');
      expect(find.text('Read'), findsOneWidget);
      verify(
        () => repository.markRead(1, cancelToken: any(named: 'cancelToken')),
      ).called(1);
    },
  );

  testWidgets(
    'incremental loading appends notifications through explicit load more',
    (tester) async {
      when(
        () =>
            repository.getPage(page: 1, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => noticePage(more: true, count: 2));
      when(
        () =>
            repository.getPage(page: 2, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => noticePage(items: [notice(id: 2)], count: 2));
      await mount(tester);
      await tapText(tester, 'Load more notifications');
      await tester.scrollUntilVisible(
        find.text('Training update 2'),
        120,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('Training update 2'), findsOneWidget);
      expect(find.text('Load more notifications'), findsNothing);
    },
  );

  for (final brightness in Brightness.values) {
    for (final status in [400, 404, 409]) {
      for (final all in [false, true]) {
        testWidgets(
          '${brightness.name} mark-${all ? 'all' : 'one'} $status offers GET-only Refresh',
          (tester) async {
            await mount(tester, brightness: brightness);
            final failure = ApiError(
              message: 'Read request rejected.',
              statusCode: status,
            );
            if (all) {
              when(
                () => repository.markAllRead(
                  cancelToken: any(named: 'cancelToken'),
                ),
              ).thenThrow(failure);
              await tester.tap(find.byTooltip('Mark all as read'));
              await tester.pumpAndSettle();
            } else {
              when(
                () => repository.markRead(
                  1,
                  cancelToken: any(named: 'cancelToken'),
                ),
              ).thenThrow(failure);
              await tapText(tester, 'Mark as read');
            }
            final heading = find.text('Read status not confirmed');
            expect(heading, findsOneWidget);
            expect(find.text('Unable to load this page'), findsNothing);
            expect(find.text('Refresh'), findsOneWidget);
            expect(find.text('Mark as read'), findsNothing);
            expect(Theme.of(tester.element(heading)).brightness, brightness);
            final semantics = tester.ensureSemantics();
            try {
              await tester.pump();
              expect(
                tester.getSemantics(find.text('Refresh')).label,
                contains('Refresh'),
              );
            } finally {
              semantics.dispose();
            }
            if (all) {
              verify(
                () => repository.markAllRead(
                  cancelToken: any(named: 'cancelToken'),
                ),
              ).called(1);
            } else {
              verify(
                () => repository.markRead(
                  1,
                  cancelToken: any(named: 'cancelToken'),
                ),
              ).called(1);
            }
            clearInteractions(repository);
            when(
              () => repository.getPage(
                page: 1,
                cancelToken: any(named: 'cancelToken'),
              ),
            ).thenAnswer((_) async => noticePage(items: [notice(read: true)]));
            await tapText(tester, 'Refresh');
            expect(find.text('Read'), findsOneWidget);
            verify(
              () => repository.getPage(
                page: 1,
                cancelToken: any(named: 'cancelToken'),
              ),
            ).called(1);
            verifyNever(
              () => repository.markRead(
                any(),
                cancelToken: any(named: 'cancelToken'),
              ),
            );
            verifyNever(
              () => repository.markAllRead(
                cancelToken: any(named: 'cancelToken'),
              ),
            );
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  for (final status in [401, 403]) {
    testWidgets('mutation $status retains explicit sign-in recovery', (
      tester,
    ) async {
      await mount(tester);
      when(
        () => repository.markRead(1, cancelToken: any(named: 'cancelToken')),
      ).thenThrow(ApiError(message: 'Sign in required.', statusCode: status));
      await tapText(tester, 'Mark as read');
      expect(find.text('Sign in required'), findsOneWidget);
      expect(find.text('Sign in again'), findsOneWidget);
      expect(find.text('Refresh'), findsNothing);
      await tapText(tester, 'Sign in again');
      expect(router.routeInformationProvider.value.uri.path, '/login');
      expect(find.text('Training update 1'), findsNothing);
      verify(
        () => repository.markRead(1, cancelToken: any(named: 'cancelToken')),
      ).called(1);
    });
  }

  testWidgets(
    'empty notification list has a useful state and can be refreshed',
    (tester) async {
      when(
        () =>
            repository.getPage(page: 1, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => noticePage(items: []));
      when(
        () => repository.getUnreadCount(cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => 0);
      await mount(tester);
      expect(find.textContaining('You’re all caught up'), findsOneWidget);
      when(
        () =>
            repository.getPage(page: 1, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => noticePage());
      await tester
          .widget<RefreshIndicator>(find.byType(RefreshIndicator))
          .onRefresh();
      await tester.pumpAndSettle();
      expect(find.text('Training update 1'), findsOneWidget);
    },
  );

  for (final inaccessible in [false, true]) {
    testWidgets(
      'notification uses the existing assignment route; inaccessible=$inaccessible',
      (tester) async {
        await mount(tester, inaccessible: inaccessible);
        await tapText(tester, 'Open training');
        expect(
          GoRouterState.of(tester.element(find.byType(AssignmentDetailScreen)))
              .uri
              .path,
          '/learning/assignments/1',
        );
        expect(
          find.text(
            inaccessible
                ? 'This assignment is no longer accessible.'
                : 'Owned training',
          ),
          findsOneWidget,
        );
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.text('Your updates'), findsOneWidget);
        verifyNever(
          () => repository.markRead(
            any(),
            cancelToken: any(named: 'cancelToken'),
          ),
        );
      },
    );
  }

  testWidgets(
    'pending mutation survives navigation away and refreshes the Dashboard bell',
    (tester) async {
      await mount(tester);
      final pending = Completer<TrainingNotification>();
      when(() => repository.markRead(1, cancelToken: any(named: 'cancelToken')))
          .thenAnswer((_) => pending.future);
      await tester.tap(find.text('Mark as read'));
      await tester.pump();
      expect(find.text('Saving read status…'), findsOneWidget);
      router.go('/dashboard');
      await tester.pumpAndSettle();
      when(
        () => repository.getUnreadCount(cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => 0);
      pending.complete(notice(read: true));
      await tester.pumpAndSettle();
      expect(
        find.byTooltip('Notifications, no unread notifications'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'logout removes notification content and returns through existing authentication routing',
    (tester) async {
      await mount(tester);
      auth.change(AuthUnauthenticated());
      await tester.pumpAndSettle();
      expect(find.text('Training update 1'), findsNothing);
      expect(router.routeInformationProvider.value.uri.path, '/login');
    },
  );

  for (final initialBrightness in Brightness.values) {
    testWidgets(
      'notification text retains contrast across live themes from ${initialBrightness.name}',
      (tester) async {
        await mount(tester, brightness: initialBrightness);
        for (final brightness in [
          initialBrightness,
          initialBrightness == Brightness.light
              ? Brightness.dark
              : Brightness.light,
          initialBrightness,
        ]) {
          tester.platformDispatcher.platformBrightnessTestValue = brightness;
          await tester.pumpAndSettle();
          final heading = find.text('Your updates');
          final theme = Theme.of(tester.element(heading));
          expect(theme.brightness, brightness);
          final headingStyle = tester.widget<Text>(heading).style!;
          expect(headingStyle.color, theme.colorScheme.onSurface);
          expect(
            headingStyle.fontSize,
            theme.textTheme.headlineSmall!.fontSize,
          );
          final card = tester.widget<Card>(find.byType(Card).first);
          for (final (finder, background) in [
            (heading, theme.scaffoldBackgroundColor),
            (
              find.text('1 unread · 1 notification'),
              theme.scaffoldBackgroundColor,
            ),
            (find.text('Training update 1'), card.color!),
            (find.text('Your training update 1.'), card.color!),
            (find.text('Unread'), card.color!),
            (find.textContaining('Received '), card.color!),
          ]) {
            final paragraph = tester.renderObject<RenderParagraph>(
              find.descendant(of: finder, matching: find.byType(RichText)),
            );
            final foreground = paragraph.text.style!.color!;
            final textLuminance = Color.alphaBlend(
              foreground,
              background,
            ).computeLuminance();
            final backgroundLuminance = background.computeLuminance();
            final lighter = textLuminance > backgroundLuminance
                ? textLuminance
                : backgroundLuminance;
            final darker = textLuminance < backgroundLuminance
                ? textLuminance
                : backgroundLuminance;
            expect(
              (lighter + 0.05) / (darker + 0.05),
              greaterThanOrEqualTo(4.5),
              reason: '$finder in ${brightness.name}',
            );
          }
        }
      },
    );
  }

  for (final brightness in Brightness.values) {
    for (final (count, noun) in [
      (0, 'notifications'),
      (1, 'notification'),
      (2, 'notifications'),
    ]) {
      testWidgets(
        'notification count uses $noun for $count in ${brightness.name} mode',
        (tester) async {
          when(
            () => repository.getPage(
              page: 1,
              cancelToken: any(named: 'cancelToken'),
            ),
          ).thenAnswer(
            (_) async => noticePage(
              items: List.generate(count, (index) => notice(id: index + 1)),
            ),
          );
          when(
            () => repository.getUnreadCount(
              cancelToken: any(named: 'cancelToken'),
            ),
          ).thenAnswer((_) async => count);
          await mount(tester, brightness: brightness);
          final label = '$count unread · $count $noun';
          final semantics = tester.ensureSemantics();
          try {
            await tester.pump();
            expect(find.text(label), findsOneWidget);
            expect(
              tester.getSemantics(find.text(label)).label,
              contains(label),
            );
            expect(
              Theme.of(tester.element(find.text(label))).brightness,
              brightness,
            );
            expect(tester.takeException(), isNull);
          } finally {
            semantics.dispose();
          }
        },
      );
    }

    for (final layout in [
      (const Size(390, 844), 1.0),
      (const Size(320, 240), 2.0),
      (const Size(844, 390), 1.6),
    ]) {
      testWidgets(
        '${brightness.name} app theme fits $layout with reduced motion and accessible controls',
        (tester) async {
          final semantics = tester.ensureSemantics();
          try {
            await mount(
              tester,
              brightness: brightness,
              size: layout.$1,
              scale: layout.$2,
              reducedMotion: true,
            );
            final context = tester.element(find.text('Your updates'));
            expect(Theme.of(context).brightness, brightness);
            expect(MediaQuery.disableAnimationsOf(context), isTrue);
            expect(MediaQuery.textScalerOf(context).scale(10), layout.$2 * 10);
            await tapText(tester, 'Mark as read');
            expect(tester.takeException(), isNull);
            expect(find.text('Mark as read'), findsNothing);
            expect(
              tester.getSemantics(find.byTooltip('Mark all as read')),
              isNotNull,
            );
            await expectLater(
              tester,
              meetsGuideline(labeledTapTargetGuideline),
            );
          } finally {
            semantics.dispose();
          }
        },
      );
    }
  }
}
