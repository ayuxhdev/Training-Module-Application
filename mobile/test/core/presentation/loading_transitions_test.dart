import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/presentation/components/content_skeleton.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/dashboard/domain/models/dashboard_data.dart';
import 'package:training_app/features/dashboard/presentation/controllers/dashboard_controller.dart';
import 'package:training_app/features/dashboard/presentation/screens/dashboard_screen.dart';
import 'package:training_app/features/learning/domain/models/assignment.dart';
import 'package:training_app/features/learning/presentation/controllers/learning_controller.dart';
import 'package:training_app/features/learning/presentation/screens/learning_screen.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';
import 'package:training_app/features/management/presentation/controllers/management_controller.dart';
import 'package:training_app/features/management/presentation/screens/management_dashboard_screen.dart';
import 'package:training_app/features/management/presentation/screens/organization_screens.dart';
import 'package:training_app/features/certificates/domain/models/certificate.dart';
import 'package:training_app/features/certificates/presentation/controllers/certificate_controller.dart';
import 'package:training_app/features/certificates/presentation/screens/certificate_list_screen.dart';
import 'package:training_app/features/notifications/presentation/controllers/notification_controller.dart';
import 'package:training_app/features/notifications/presentation/screens/notification_center_screen.dart';

import '../../features/management/management_fixtures.dart';
import '../../features/notifications/notification_fixtures.dart';

class _Certificates extends CertificateListController {
  final Future<List<Certificate>> Function() load;
  _Certificates(this.load);
  @override
  Future<List<Certificate>> build() => load();
}

class _Notifications extends NotificationController {
  final Future<NotificationFeed?> Function() load;
  _Notifications(this.load);
  @override
  Future<NotificationFeed?> build() => load();
}

Widget _account(Widget child) => ProviderScope(
  overrides: [
    authControllerProvider.overrideWith(
      () => ManagementTestAuth(managementIdentity(team: true)),
    ),
    notificationUnreadCountProvider.overrideWith(ZeroUnreadController.new),
  ],
  child: MaterialApp(home: child),
);

void _flow<T>(
  String name, {
  required Widget Function(Future<T> Function()) frame,
  required T empty,
  required T success,
  required Type skeleton,
  required String emptyText,
  required String successText,
  Finder Function()? scrollable,
}) {
  testWidgets(
    '$name replaces skeleton on error, Retry, empty and refreshed success',
    (tester) async {
      Future<void> expectLoading() async {
        // Directory loading follows the stable filter controls and may be below
        // the fold. Other screens keep their existing loading placement.
        if (scrollable != null) {
          await tester.scrollUntilVisible(
            find.byType(skeleton),
            160,
            scrollable: scrollable(),
          );
          await tester.pumpAndSettle();
        }
        expect(find.byType(skeleton), findsOneWidget);
      }

      var pending = Completer<T>();
      await tester.pumpWidget(frame(() => pending.future));
      await tester.pump();
      await expectLoading();
      pending.completeError(ApiError.networkFailure());
      await tester.pumpAndSettle();
      expect(find.byType(skeleton), findsNothing);
      await tester.scrollUntilVisible(
        find.text('Retry'),
        160,
        scrollable: scrollable?.call() ?? find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      expect(find.text('Retry'), findsOneWidget);
      pending = Completer<T>();
      await tester.tap(find.text('Retry'));
      await tester.pump();
      await expectLoading();
      pending.complete(empty);
      await tester.pumpAndSettle();
      expect(find.byType(skeleton), findsNothing);
      // Dashboard panels can be below the fold; verify they are reachable.
      await tester.scrollUntilVisible(
        find.text(emptyText),
        160,
        scrollable: scrollable?.call() ?? find.byType(Scrollable).last,
      );
      expect(find.text(emptyText), findsWidgets);
      pending = Completer<T>();
      final refresh = tester
          .widget<RefreshIndicator>(find.byType(RefreshIndicator).first)
          .onRefresh();
      await tester.pump();
      await expectLoading();
      pending.complete(success);
      await refresh;
      await tester.pumpAndSettle();
      expect(find.byType(skeleton), findsNothing);
      await tester.scrollUntilVisible(
        find.text(successText),
        -160,
        scrollable: scrollable?.call() ?? find.byType(Scrollable).last,
      );
      expect(find.text(successText), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
}

void main() {
  DashboardData dashboard(int assigned) => DashboardData(
    metrics: DashboardMetrics.fromJson({'assigned': assigned}),
    actionRequired: [],
    recentCertificates: [],
  );
  _flow<DashboardData>(
    'Dashboard',
    frame: (load) => _account(
      ProviderScope(
        overrides: [dashboardDataProvider.overrideWith((_) => load())],
        child: const DashboardScreen(),
      ),
    ),
    empty: dashboard(0),
    success: dashboard(7),
    skeleton: DashboardSkeleton,
    emptyText: 'No pending assignments.',
    successText: '7',
  );
  _flow<List<Assignment>>(
    'Learning',
    frame: (load) => _account(
      ProviderScope(
        overrides: [assignmentListProvider.overrideWith((_) => load())],
        child: const LearningScreen(),
      ),
    ),
    empty: [],
    success: [
      Assignment(
        id: 1,
        trainingId: 1,
        trainingTitle: 'Owned training',
        versionNumber: 1,
        status: 'ASSIGNED',
        isOverdue: false,
        progressSummary: ProgressSummary(
          requiredLessonsCompleted: 0,
          requiredLessonsTotal: 2,
        ),
      ),
    ],
    skeleton: LearningSkeleton,
    emptyText: 'No assignments found.',
    successText: 'Owned training',
  );
  _flow<ManagementDashboard>(
    'Team dashboard',
    frame: (load) => _account(
      ProviderScope(
        overrides: [managementDashboardProvider.overrideWith((_) => load())],
        child: const ManagementDashboardScreen(),
      ),
    ),
    empty: ManagementDashboard.fromJson({
      ...managementDashboardJson(team: true),
      'recent_failures': [],
      'incomplete_employees': [],
    }),
    success: dashboardFixture(team: true),
    skeleton: ManagementSkeleton,
    emptyText: 'There are no recent assessment failures to review.',
    successText: 'Team dashboard',
  );
  _flow<ManagementPage<DirectoryEmployee>>(
    'Employee directory',
    frame: (load) => _account(
      ProviderScope(
        overrides: [
          employeeDirectoryProvider((
            page: 1,
            search: null,
            departmentId: null,
            jobRoleId: null,
            isActive: null,
          )).overrideWith((_) => load()),
          for (final kind in ReferenceKind.values)
            organizationReferenceChoicesProvider(kind)
                .overrideWith((_) async => []),
        ],
        child: const OrganizationListScreen(),
      ),
    ),
    empty: ManagementPage.fromJson(pageJson([]), DirectoryEmployee.fromJson),
    success: employeePage(),
    skeleton: CardListSkeleton,
    emptyText: 'No records to display.',
    successText: 'Employee 1',
    scrollable: () => find.byType(Scrollable).first,
  );
  for (final kind in ReferenceKind.values) {
    _flow<ManagementPage<OrganizationReference>>(
      kind.title,
      frame: (load) => _account(
        ProviderScope(
          overrides: [
            organizationReferencesProvider((kind: kind, page: 1))
                .overrideWith((_) => load()),
          ],
          child: OrganizationListScreen(referenceKind: kind),
        ),
      ),
      empty: ManagementPage.fromJson(
        pageJson([]),
        OrganizationReference.fromJson,
      ),
      success: ManagementPage.fromJson(
        pageJson([referenceJson()]),
        OrganizationReference.fromJson,
      ),
      skeleton: CardListSkeleton,
      emptyText: 'No records to display.',
      successText: 'Operations 1',
    );
  }
  _flow<List<Certificate>>(
    'Certificates',
    frame: (load) => _account(
      ProviderScope(
        overrides: [
          certificateListProvider.overrideWith(() => _Certificates(load)),
        ],
        child: const CertificateListScreen(),
      ),
    ),
    empty: [],
    success: [
      Certificate(
        id: 8,
        certificateNumber: 'GN-8',
        trainingTitle: 'Safety award',
        versionNumber: 1,
        issuedAt: DateTime(2026),
        isRevoked: false,
      ),
    ],
    skeleton: CardListSkeleton,
    emptyText: 'No certificates earned yet. Complete your assigned training to earn a certificate.',
    successText: 'Safety award',
  );
  _flow<NotificationFeed?>(
    'Notifications',
    frame: (load) => _account(
      ProviderScope(
        overrides: [
          notificationListProvider.overrideWith(() => _Notifications(load)),
        ],
        child: const NotificationCenterScreen(),
      ),
    ),
    empty: NotificationFeed.fromPage(noticePage(items: [])),
    success: NotificationFeed.fromPage(noticePage()),
    skeleton: CardListSkeleton,
    emptyText: 'You’re all caught up. Training updates will appear here.',
    successText: 'Training update 1',
  );
}
