import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/main.dart';
import 'package:training_app/core/router/app_router.dart';
import 'package:training_app/core/theme/app_theme.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/dashboard/domain/models/dashboard_data.dart';
import 'package:training_app/features/dashboard/presentation/controllers/dashboard_controller.dart';
import 'package:training_app/features/learning/domain/models/assignment.dart';
import 'package:training_app/features/learning/domain/models/assignment_detail.dart';
import 'package:training_app/features/learning/presentation/controllers/learning_controller.dart';
import 'package:training_app/features/notifications/presentation/controllers/notification_controller.dart';

import '../../features/notifications/notification_fixtures.dart';

const title = 'Safe handling and practical equipment care for your working day';

void main() {
  for (final brightness in Brightness.values) {
    for (final (size, scale) in [
      (const Size(320, 640), 2.0),
      (const Size(390, 844), 1.0),
      (const Size(844, 390), 1.3),
    ]) {
      testWidgets(
        'app ${brightness.name} ${size.width} at ${scale}x supports Batch 1 routes',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size;
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          tester.platformDispatcher.platformBrightnessTestValue = brightness;
          addTearDown(() {
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
            tester.platformDispatcher.clearTextScaleFactorTestValue();
            tester.platformDispatcher.clearPlatformBrightnessTestValue();
          });
          final lesson = LessonLearning(
            id: 8,
            title: title,
            position: 1,
            type: 'VIDEO',
            isRequired: true,
            body: '',
            progress: LessonProgress(
              resumePosition: 50,
              watchedSeconds: 10,
              progressPercent: 20,
              completed: false,
            ),
          );
          final detail = AssignmentDetail(
            id: 96,
            trainingId: 3,
            trainingTitle: title,
            versionNumber: 2,
            status: 'IN_PROGRESS',
            isOverdue: false,
            modules: [
              ModuleLearning(
                id: 4,
                title: title,
                description: 'Build confidence with every lesson.',
                position: 1,
                lessons: [lesson],
              ),
            ],
          );
          final container = ProviderContainer(
            overrides: [
              authControllerProvider.overrideWith(NotificationTestAuth.new),
              notificationUnreadCountProvider.overrideWith(
                ZeroUnreadController.new,
              ),
              dashboardDataProvider.overrideWith(
                (ref) => DashboardData(
                  metrics: DashboardMetrics(
                    total: 1,
                    assigned: 0,
                    inProgress: 1,
                    completed: 0,
                    cancelled: 0,
                    overdue: 0,
                    completionPercent: 0,
                    certificatesCount: 0,
                  ),
                  actionRequired: [
                    DashboardAssignment(
                      id: 96,
                      trainingId: 3,
                      trainingTitle: title,
                      versionNumber: 2,
                      status: 'IN_PROGRESS',
                      isOverdue: false,
                    ),
                  ],
                  recentCertificates: [],
                ),
              ),
              assignmentListProvider.overrideWith(
                (ref) => [
                  Assignment(
                    id: 96,
                    trainingId: 3,
                    trainingTitle: title,
                    versionNumber: 2,
                    status: 'IN_PROGRESS',
                    isOverdue: false,
                    progressSummary: ProgressSummary(
                      requiredLessonsCompleted: 0,
                      requiredLessonsTotal: 1,
                    ),
                  ),
                ],
              ),
              assignmentDetailProvider(96).overrideWith((ref) => detail),
            ],
          );
          addTearDown(container.dispose);
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: const MyApp(),
            ),
          );
          await tester.pumpAndSettle();
          final router = container.read(appRouterProvider);
          for (final path in [
            '/dashboard',
            '/learning',
            '/learning/assignments/96',
            '/learning/assignments/96/modules',
            '/learning/assignments/96/modules/4/lessons',
          ]) {
            router.go(path);
            await tester.pumpAndSettle();
            final context = tester.element(find.byType(NavigationBar));
            expect(Theme.of(context).brightness, brightness);
            expect(
              Theme.of(context).colorScheme.primary,
              (brightness == Brightness.dark
                      ? AppTheme.darkTheme
                      : AppTheme.lightTheme)
                  .colorScheme
                  .primary,
            );
            expect(tester.takeException(), isNull, reason: path);
            final scroll = find.byType(Scrollable).first;
            // Exercise the complete scrollable surface, including controls below fold.
            for (var step = 0; step < 5; step++) {
              await tester.drag(scroll, const Offset(0, -300));
              await tester.pumpAndSettle();
              expect(
                tester.takeException(),
                isNull,
                reason: '$path scroll $step',
              );
            }
            expect(find.text('Dashboard'), findsWidgets);
            expect(find.text('Learning'), findsWidgets);
            expect(find.text('Profile'), findsWidgets);
          }
          // Position 50 above is not earned completion: the list remains pending.
          expect(find.text('PENDING'), findsOneWidget);
          expect(find.text('COMPLETED'), findsNothing);
          final switched = brightness == Brightness.dark
              ? Brightness.light
              : Brightness.dark;
          tester.platformDispatcher.platformBrightnessTestValue = switched;
          await tester.pumpAndSettle();
          expect(
            Theme.of(tester.element(find.byType(NavigationBar))).brightness,
            switched,
          );
          expect(
            router.routeInformationProvider.value.uri.path,
            '/learning/assignments/96/modules/4/lessons',
          );
          expect(find.text('PENDING'), findsOneWidget);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
