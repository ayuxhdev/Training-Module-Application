import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/core/theme/app_theme.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/certificates/domain/models/certificate.dart';
import 'package:training_app/features/certificates/domain/models/certificate_detail.dart';
import 'package:training_app/features/certificates/presentation/controllers/certificate_controller.dart';
import 'package:training_app/features/certificates/presentation/screens/certificate_detail_screen.dart';
import 'package:training_app/features/certificates/presentation/screens/certificate_list_screen.dart';
import 'package:training_app/features/dashboard/domain/models/dashboard_data.dart';
import 'package:training_app/features/dashboard/presentation/controllers/dashboard_controller.dart';
import 'package:training_app/features/dashboard/presentation/screens/dashboard_screen.dart';
import 'package:training_app/features/notifications/presentation/controllers/notification_controller.dart';

import '../../notifications/notification_fixtures.dart';

// Exercise conversion at both midnight boundaries independently of the test host's timezone.
class _BoundaryDate extends Fake implements DateTime {
  final DateTime utc, local;
  _BoundaryDate(this.utc, this.local);
  @override
  DateTime toLocal() => local;
  @override
  int get year => utc.year;
  @override
  int get month => utc.month;
  @override
  int get day => utc.day;
}

void main() {
  for (final issued in [
    _BoundaryDate(
      DateTime.utc(2026, 10, 20, 20, 30),
      DateTime(2026, 10, 21, 2),
    ),
    _BoundaryDate(DateTime.utc(2026, 10, 21, 1), DateTime(2026, 10, 20, 18)),
    DateTime.parse('2026-10-20T20:30:00Z'),
  ]) {
    final local = issued.toLocal();
    final label =
        '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
    testWidgets(
      'all certificate entry points show device-local issue date $label (${issued.runtimeType})',
      (tester) async {
        final container = ProviderContainer(
          overrides: [
            authControllerProvider.overrideWith(NotificationTestAuth.new),
            notificationUnreadCountProvider.overrideWith(
              ZeroUnreadController.new,
            ),
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
                  certificatesCount: 1,
                ),
                actionRequired: [],
                recentCertificates: [
                  DashboardCertificate(
                    id: 8,
                    certificateNumber: 'GN-008',
                    trainingTitle: 'Safety',
                    versionNumber: 1,
                    issuedAt: issued,
                  ),
                ],
              ),
            ),
            certificateListProvider.overrideWith(() => _List(issued)),
            certificateDetailProvider(8).overrideWith(() => _Detail(issued)),
          ],
        );
        addTearDown(container.dispose);
        for (final (screen, text) in [
          (const DashboardScreen(), 'Issued: $label'),
          (const CertificateListScreen(), 'Issued $label'),
          (const CertificateDetailScreen(certificateId: 8), label),
        ]) {
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                key: ValueKey(screen.runtimeType),
                theme: AppTheme.lightTheme,
                home: screen,
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(
            find.text(text),
            200,
            scrollable: find.byType(Scrollable).first,
          );
          expect(find.text(text), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
      },
    );
  }
}

class _List extends CertificateListController {
  final DateTime issued;
  _List(this.issued);
  @override
  Future<List<Certificate>> build() async => [
    Certificate(
      id: 8,
      certificateNumber: 'GN-008',
      trainingTitle: 'Safety',
      versionNumber: 1,
      issuedAt: issued,
      isRevoked: false,
    ),
  ];
}

class _Detail extends CertificateDetailController {
  final DateTime issued;
  _Detail(this.issued) : super(8);
  @override
  Future<CertificateDetail?> build() async => CertificateDetail(
    id: 8,
    certificateNumber: 'GN-008',
    trainingTitle: 'Safety',
    versionNumber: 1,
    issuedAt: issued,
    isRevoked: false,
    employeeName: 'Learner',
    employeeCode: 'QA',
    assignmentId: 1,
    hasDocument: false,
    revokedAt: null,
  );
}
