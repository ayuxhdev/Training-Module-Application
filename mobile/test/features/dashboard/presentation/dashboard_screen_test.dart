import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/theme/app_theme.dart';
import 'package:training_app/core/theme/cadence_tokens.dart';
import 'package:training_app/features/dashboard/data/repositories/dashboard_repository.dart';
import 'package:training_app/features/dashboard/presentation/widgets/continue_training_card.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/presentation/components/content_skeleton.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/employee.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/dashboard/domain/models/dashboard_data.dart';
import 'package:training_app/features/dashboard/presentation/controllers/dashboard_controller.dart';
import 'package:training_app/features/dashboard/presentation/screens/dashboard_screen.dart';
import 'package:training_app/features/notifications/presentation/controllers/notification_controller.dart';

import '../../notifications/notification_fixtures.dart';

void main() {
  testWidgets(
    'recent certificate has one keyboard/tap surface and navigates once',
    (tester) async {
      var opened = 0;
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, state) => const DashboardScreen()),
          GoRoute(
            path: '/profile/certificates/42',
            builder: (_, state) {
              opened++;
              return const Scaffold(body: Text('Certificate details'));
            },
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authControllerProvider.overrideWith(AuthControllerMock.new),
            notificationUnreadCountProvider.overrideWith(
              ZeroUnreadController.new,
            ),
            dashboardDataProvider.overrideWith(
              (_) async => DashboardData(
                metrics: DashboardMetrics.fromJson({}),
                actionRequired: [],
                recentCertificates: [
                  DashboardCertificate(
                    id: 42,
                    certificateNumber: 'GN-42',
                    trainingTitle: 'Keyboard certificate',
                    versionNumber: 1,
                  ),
                ],
              ),
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Keyboard certificate'),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      final card = find.ancestor(
        of: find.text('Keyboard certificate'),
        matching: find.byType(CustomCard),
      );
      final target = find.descendant(of: card, matching: find.byType(InkWell));
      expect(target, findsOneWidget);
      expect(
        find.descendant(
          of: card,
          matching: find.byWidgetPredicate(
            (w) => w is Semantics && w.properties.button == true,
          ),
        ),
        findsOneWidget,
      );
      Focus.of(tester.element(find.text('Keyboard certificate')))
          .requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Certificate details'), findsOneWidget);
      expect(opened, 1);
    },
  );

  testWidgets('DashboardScreen shows loading initially', (tester) async {
    final completer = Completer<DashboardData>();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          notificationUnreadCountProvider.overrideWith(
            ZeroUnreadController.new,
          ),
          authControllerProvider.overrideWith(() => AuthControllerMock()),
          dashboardDataProvider.overrideWith((ref) => completer.future),
        ],
        child: const MaterialApp(home: DashboardScreen()),
      ),
    );

    expect(find.byType(DashboardSkeleton), findsOneWidget);

    // complete the future to avoid pending timers
    completer.complete(
      DashboardData(
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
    );
    await tester.pumpAndSettle();
    expect(find.byType(DashboardSkeleton), findsNothing);
  });

  testWidgets('DashboardScreen displays metrics when loaded', (tester) async {
    final mockData = DashboardData(
      metrics: DashboardMetrics(
        total: 10,
        assigned: 4,
        inProgress: 2,
        completed: 4,
        cancelled: 0,
        overdue: 1,
        completionPercent: 40.0,
        certificatesCount: 3,
      ),
      actionRequired: [],
      recentCertificates: [],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          notificationUnreadCountProvider.overrideWith(
            ZeroUnreadController.new,
          ),
          authControllerProvider.overrideWith(() => AuthControllerMock()),
          dashboardDataProvider.overrideWith((ref) => mockData),
        ],
        child: const MaterialApp(home: DashboardScreen()),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Overview'), findsOneWidget);
    expect(find.text('4'), findsNWidgets(2)); // assigned, completed
    expect(find.text('2'), findsOneWidget); // in progress
  });

  testWidgets('DashboardScreen displays recent certificates when present', (
    tester,
  ) async {
    final mockData = DashboardData(
      metrics: DashboardMetrics(
        total: 1,
        assigned: 0,
        inProgress: 0,
        completed: 1,
        cancelled: 0,
        overdue: 0,
        completionPercent: 100.0,
        certificatesCount: 1,
      ),
      actionRequired: [],
      recentCertificates: [
        DashboardCertificate(
          id: 42,
          certificateNumber: 'CERT-2026-001',
          trainingTitle: 'Safety in Operations',
          versionNumber: 1,
          issuedAt: DateTime(2026, 10, 20),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          notificationUnreadCountProvider.overrideWith(
            ZeroUnreadController.new,
          ),
          authControllerProvider.overrideWith(() => AuthControllerMock()),
          dashboardDataProvider.overrideWith((ref) => mockData),
        ],
        child: const MaterialApp(home: DashboardScreen()),
      ),
    );

    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Recent Certificates'),
      200,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('Recent Certificates'), findsOneWidget);
    expect(find.text('Safety in Operations'), findsOneWidget);
    expect(find.text('Cert #: CERT-2026-001'), findsOneWidget);
    expect(find.byIcon(Icons.workspace_premium), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
  });

  testWidgets('DashboardScreen displays zero metrics cleanly', (tester) async {
    final mockData = DashboardData(
      metrics: DashboardMetrics(
        total: 0,
        assigned: 0,
        inProgress: 0,
        completed: 0,
        cancelled: 0,
        overdue: 0,
        completionPercent: 0.0,
        certificatesCount: 0,
      ),
      actionRequired: [],
      recentCertificates: [],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          notificationUnreadCountProvider.overrideWith(
            ZeroUnreadController.new,
          ),
          authControllerProvider.overrideWith(() => AuthControllerMock()),
          dashboardDataProvider.overrideWith((ref) => mockData),
        ],
        child: const MaterialApp(home: DashboardScreen()),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.text('Overview'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('No certificates earned yet.'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('No certificates earned yet.'), findsOneWidget);
  });

  testWidgets('DashboardScreen shows error view on failure', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          notificationUnreadCountProvider.overrideWith(
            ZeroUnreadController.new,
          ),
          authControllerProvider.overrideWith(() => AuthControllerMock()),
          dashboardDataProvider.overrideWith(
            (ref) => Future.error(Exception('Failed to load')),
          ),
        ],
        child: const MaterialApp(home: DashboardScreen()),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Unable to load this page'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
  setUpAll(() => registerFallbackValue(CancelToken()));

  testWidgets(
    'Continue uses the first API-ordered assignment and preserves other assignments',
    (tester) async {
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const DashboardScreen()),
          GoRoute(
            path: '/learning/assignments/8',
            builder: (_, _) => const Scaffold(body: Text('Assignment 8')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authControllerProvider.overrideWith(AuthControllerMock.new),
            notificationUnreadCountProvider.overrideWith(
              ZeroUnreadController.new,
            ),
            dashboardDataProvider.overrideWith(
              (_) async => phaseOneData('Backend first', second: true),
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      final hero = tester.widget<ContinueTrainingCard>(
        find.byType(ContinueTrainingCard),
      );
      expect(hero.assignment.id, 8);
      expect(hero.assignment.trainingTitle, 'Backend first');
      await tester.scrollUntilVisible(
        find.text('Another assignment'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Another assignment'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Continue training'),
        -150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Continue training'));
      await tester.pumpAndSettle();
      expect(find.text('Assignment 8'), findsOneWidget);
    },
  );

  testWidgets('error Retry loads real provider data without app restart', (
    tester,
  ) async {
    final repo = MockDashboardRepository();
    var calls = 0;
    when(() => repo.getDashboardData(cancelToken: any(named: 'cancelToken')))
        .thenAnswer((_) async {
          calls++;
          if (calls == 1) {
            throw ApiError(
              message: 'Check your connection.',
              code: 'network_failure',
            );
          }
          return phaseOneData('Recovered assignment');
        });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authControllerProvider.overrideWith(AuthControllerMock.new),
          notificationUnreadCountProvider.overrideWith(
            ZeroUnreadController.new,
          ),
          dashboardRepositoryProvider.overrideWithValue(repo),
        ],
        child: const MaterialApp(home: DashboardScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Connection unavailable'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Recovered assignment'), findsOneWidget);
    expect(calls, 2);
  });

  testWidgets(
    'pull refresh hides previous data and returns to populated state',
    (tester) async {
      final next = Completer<DashboardData>();
      var calls = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authControllerProvider.overrideWith(AuthControllerMock.new),
            notificationUnreadCountProvider.overrideWith(
              ZeroUnreadController.new,
            ),
            dashboardDataProvider.overrideWith(
              (_) => ++calls == 1
                  ? Future.value(phaseOneData('Before refresh'))
                  : next.future,
            ),
          ],
          child: const MaterialApp(home: DashboardScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 500));
      await tester.pump(); // Start the indicator snap animation.
      await tester.pump(const Duration(seconds: 1));
      // Rebuild after the callback invalidates the provider.
      await tester.pump();
      expect(calls, 2, reason: 'A pull gesture must reach onRefresh.');
      expect(find.byType(DashboardSkeleton), findsOneWidget);
      expect(find.text('Before refresh'), findsNothing);
      next.complete(phaseOneData('After refresh'));
      await tester.pumpAndSettle();
      expect(find.text('After refresh'), findsOneWidget);
      expect(calls, 2);
    },
  );

  for (final firstCompletes in [false, true]) {
    testWidgets(
      'account switch clears old data and ignores late response; completed=$firstCompletes',
      (tester) async {
        final repo = MockDashboardRepository(),
            a = Completer<DashboardData>(),
            b = Completer<DashboardData>();
        var calls = 0;
        final tokens = <CancelToken>[];
        when(
          () => repo.getDashboardData(cancelToken: any(named: 'cancelToken')),
        ).thenAnswer((call) {
          tokens.add(call.namedArguments[#cancelToken] as CancelToken);
          return ++calls == 1 ? a.future : b.future;
        });
        final container = ProviderContainer(
          overrides: [
            authControllerProvider.overrideWith(NotificationTestAuth.new),
            notificationUnreadCountProvider.overrideWith(
              ZeroUnreadController.new,
            ),
            dashboardRepositoryProvider.overrideWithValue(repo),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: DashboardScreen()),
          ),
        );
        await tester.pump();
        if (firstCompletes) {
          a.complete(phaseOneData('Account A private training'));
          await tester.pumpAndSettle();
          expect(find.text('Account A private training'), findsOneWidget);
        }
        (container.read(authControllerProvider.notifier)
                as NotificationTestAuth)
            .change(AuthAuthenticated(noticeEmployee('B')));
        await tester.pump();
        expect(find.text('Account A private training'), findsNothing);
        b.complete(phaseOneData('Account B training'));
        await tester.pumpAndSettle();
        if (!firstCompletes) {
          a.complete(phaseOneData('Account A private training'));
          await tester.pumpAndSettle();
        }
        expect(find.text('Account B training'), findsOneWidget);
        expect(find.text('Account A private training'), findsNothing);
        expect(tokens.first.isCancelled, isTrue);
        expect(calls, 2);
      },
    );
  }

  testWidgets('unauthenticated or inactive learners never load a dashboard', (
    tester,
  ) async {
    for (final state in [
      AuthUnauthenticated(),
      AuthAuthenticated(noticeEmployee('inactive', active: false)),
    ]) {
      var calls = 0;
      final container = ProviderContainer(
        overrides: [
          authControllerProvider.overrideWith(NotificationTestAuth.new),
          dashboardDataProvider.overrideWith((_) async {
            calls++;
            return phaseOneData('Not authorized');
          }),
        ],
      );
      (container.read(authControllerProvider.notifier) as NotificationTestAuth)
          .change(state);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: DashboardScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ContinueTrainingCard), findsNothing);
      expect(calls, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
    }
  });

  for (final dark in [false, true]) {
    for (final state in ['empty', 'error', 'loading']) {
      testWidgets(
        'hybrid $state at 320px and 200% in ${dark ? 'dark' : 'light'} system mode',
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(320, 844));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final pending = Completer<DashboardData>();
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                authControllerProvider.overrideWith(AuthControllerMock.new),
                notificationUnreadCountProvider.overrideWith(
                  ZeroUnreadController.new,
                ),
                dashboardDataProvider.overrideWith((_) {
                  if (state == 'loading') {
                    return pending.future;
                  }
                  if (state == 'error') {
                    return Future.error(
                      ApiError(message: 'Offline', code: 'network_failure'),
                    );
                  }
                  return Future.value(
                    DashboardData(
                      metrics: DashboardMetrics.fromJson({}),
                      actionRequired: [],
                      recentCertificates: [],
                    ),
                  );
                }),
              ],
              child: MaterialApp(
                theme: AppTheme.lightTheme,
                darkTheme: AppTheme.darkTheme,
                themeMode: dark ? ThemeMode.dark : ThemeMode.light,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(2)),
                  child: child!,
                ),
                home: const DashboardScreen(),
              ),
            ),
          );
          await tester.pump();
          await tester.pump();
          final scaffold = find.byType(Scaffold).first;
          expect(
            Theme.of(tester.element(scaffold)).scaffoldBackgroundColor,
            CadenceTokens.canvas,
          );
          expect(tester.takeException(), isNull);
          if (state == 'loading') {
            expect(find.byType(DashboardSkeleton), findsOneWidget);
          } else if (state == 'error') {
            await tester.scrollUntilVisible(
              find.text('Retry'),
              100,
              scrollable: find.byType(Scrollable).first,
            );
            await tester.pumpAndSettle();
            expect(find.text('Retry').hitTestable(), findsOneWidget);
          } else {
            expect(find.text('No pending assignments.'), findsOneWidget);
            expect(find.byType(ContinueTrainingCard), findsNothing);
            await tester.scrollUntilVisible(
              find.text('Recent Certificates'),
              150,
              scrollable: find.byType(Scrollable).first,
            );
            await tester.pumpAndSettle();
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          if (!pending.isCompleted) {
            pending.complete(phaseOneData('Disposed'));
          }
          await tester.pump();
        },
      );
    }
  }

  for (final sample in [
    ('light', false, 1.0, 390.0),
    ('dark', true, 1.0, 390.0),
    ('large-text', false, 2.0, 320.0),
    ('dark-large-text', true, 2.0, 320.0),
    ('large-text-390', false, 2.0, 390.0),
    ('dark-large-text-390', true, 2.0, 390.0),
    ('large-text-regular', false, 2.0, 390.0),
    ('dark-large-text-regular', true, 2.0, 320.0),
    ('narrow-light', false, 1.0, 320.0),
    ('narrow-dark', true, 1.0, 320.0),
  ]) {
    testWidgets(
      'actual Flutter dashboard render ${sample.$1}, long text remains reachable',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(sample.$4, 844));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        tester.platformDispatcher.platformBrightnessTestValue = sample.$2
            ? Brightness.dark
            : Brightness.light;
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        ThemeData? outerTheme;
        const output = String.fromEnvironment('M22_SCREENSHOT_DIR');
        const fonts = String.fromEnvironment('M22_FONT_DIR');
        if (output.isNotEmpty) {
          expect(
            fonts,
            isNotEmpty,
            reason:
                'Screenshots need reference Roboto, not the test Ahem font.',
          );
          await tester.runAsync(() async {
            final loader = FontLoader('Roboto')
              ..addFont(
                Future.value(
                  ByteData.sublistView(
                    File('$fonts/Roboto-Regular.ttf').readAsBytesSync(),
                  ),
                ),
              )
              ..addFont(
                Future.value(
                  ByteData.sublistView(
                    File('$fonts/Roboto-Bold.ttf').readAsBytesSync(),
                  ),
                ),
              );
            await loader.load();
            final icons = FontLoader('MaterialIcons')
              ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
            await icons.load();
          });
        }
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authControllerProvider.overrideWith(AuthControllerMock.new),
              notificationUnreadCountProvider.overrideWith(
                ZeroUnreadController.new,
              ),
              dashboardDataProvider.overrideWith(
                (_) async => phaseOneData(
                  sample.$1 != 'light' &&
                          sample.$1 != 'dark' &&
                          !sample.$1.contains('regular')
                      ? 'Safe operation of manufacturing equipment with extended training instructions'
                      : 'Safety v1',
                ),
              ),
            ],
            child: RepaintBoundary(
              key: const ValueKey('dashboard-capture'),
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: AppTheme.lightTheme,
                darkTheme: AppTheme.darkTheme,
                themeMode: ThemeMode.system,
                builder: (context, child) {
                  outerTheme = Theme.of(context);
                  return MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(textScaler: TextScaler.linear(sample.$3)),
                    child: child!,
                  );
                },
                home: const DashboardScreen(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final hero = find.byType(ContinueTrainingCard);
        expect(hero, findsOneWidget);
        final local = Theme.of(tester.element(hero));
        expect(local.brightness, Brightness.light);
        expect(local.scaffoldBackgroundColor, CadenceTokens.canvas);
        expect(local.colorScheme.surface, Colors.white);
        expect(local.colorScheme.onSurface, CadenceTokens.ink);
        expect(local.colorScheme.primary, CadenceTokens.primary);
        expect(local.colorScheme.secondary, CadenceTokens.teal);
        expect(local.colorScheme.tertiary, CadenceTokens.violet);
        expect(
          local.elevatedButtonTheme.style!.backgroundColor!.resolve({}),
          CadenceTokens.primary,
        );
        expect(
          outerTheme!.brightness,
          sample.$2 ? Brightness.dark : Brightness.light,
        );
        if (sample.$2) {
          expect(
            outerTheme!.scaffoldBackgroundColor,
            isNot(CadenceTokens.canvas),
          );
        }
        final decoration =
            tester
                    .widget<DecoratedBox>(
                      find
                          .descendant(
                            of: hero,
                            matching: find.byType(DecoratedBox),
                          )
                          .first,
                    )
                    .decoration
                as BoxDecoration;
        expect(decoration.color, CadenceTokens.deep);
        expect(
          MediaQuery.textScalerOf(tester.element(hero)).scale(12),
          12 * sample.$3,
        );
        if (sample.$3 == 2) {
          expect(
            find.text('A little progress. A stronger tomorrow.'),
            findsNothing,
          );
        }
        final card = tester.getRect(hero);
        final cta = tester.getRect(
          find.widgetWithText(ElevatedButton, 'Continue training'),
        );
        expect(cta.top, greaterThanOrEqualTo(card.top));
        expect(cta.bottom, lessThanOrEqualTo(card.bottom));
        expect(cta.height, greaterThanOrEqualTo(48));
        if (output.isNotEmpty) {
          await expectLater(
            find.byKey(const ValueKey('dashboard-capture')),
            matchesGoldenFile(
              Uri.file(
                '$output/employee-dashboard-${sample.$1}.png',
                windows: Platform.isWindows,
              ),
            ),
          );
        }
        if (sample.$3 == 2) {
          await tester.scrollUntilVisible(
            find.widgetWithText(ElevatedButton, 'Continue training'),
            150,
            scrollable: find.byType(Scrollable).first,
          );
          await tester
              .pumpAndSettle(); // Lay out the ensureVisible scroll position.
          expect(find.text('Continue training').hitTestable(), findsOneWidget);
          final visibleAction = tester.getRect(
            find.widgetWithText(ElevatedButton, 'Continue training'),
          );
          final viewport = tester.getRect(find.byType(CustomScrollView));
          expect(visibleAction.top, greaterThanOrEqualTo(viewport.top));
          expect(visibleAction.bottom, lessThanOrEqualTo(viewport.bottom));

          if (output.isNotEmpty) {
            await expectLater(
              find.byKey(const ValueKey('dashboard-capture')),
              matchesGoldenFile(
                Uri.file(
                  '$output/employee-dashboard-${sample.$1}-action.png',
                  windows: Platform.isWindows,
                ),
              ),
            );
          }
        }
        if (sample.$3 == 2) {
          await tester.scrollUntilVisible(
            find.text('Assigned'),
            150,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          final label = find.text('Assigned');
          final row = find
              .ancestor(of: label, matching: find.byType(Row))
              .first;
          final value = find.descendant(of: row, matching: find.text('2'));
          expect(value, findsOneWidget);
          expect(
            tester.getCenter(label).dy,
            closeTo(tester.getCenter(value).dy, 1),
          );
        }
        await tester.scrollUntilVisible(
          find.text('Recent Certificates'),
          160,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }
}

class AuthControllerMock extends AuthController {
  @override
  AuthState build() {
    return AuthAuthenticated(
      Employee(
        username: 'jdoe',
        employeeCode: 'EMP123',
        displayName: 'John Doe',
        department: 'Engineering',
        jobRole: 'Developer',
        isActive: true,
      ),
    );
  }
}

class MockDashboardRepository extends Mock implements DashboardRepository {}

DashboardData phaseOneData(String title, {bool second = false}) =>
    DashboardData(
      metrics: DashboardMetrics(
        total: 5,
        assigned: 2,
        inProgress: 1,
        completed: 2,
        cancelled: 0,
        overdue: 0,
        completionPercent: 40,
        certificatesCount: 1,
      ),
      actionRequired: [
        DashboardAssignment(
          id: 8,
          trainingId: 3,
          trainingTitle: title,
          versionNumber: 1,
          status: 'IN_PROGRESS',
          isOverdue: false,
        ),
        if (second)
          DashboardAssignment(
            id: 1,
            trainingId: 2,
            trainingTitle: 'Another assignment',
            versionNumber: 2,
            status: 'ASSIGNED',
            isOverdue: true,
            dueAt: DateTime(2026, 1, 2),
          ),
      ],
      recentCertificates: [
        DashboardCertificate(
          id: 42,
          certificateNumber: 'CERT-2026-001',
          trainingTitle: 'Safety in Operations',
          versionNumber: 1,
          issuedAt: DateTime(2026, 10, 20),
        ),
      ],
    );
