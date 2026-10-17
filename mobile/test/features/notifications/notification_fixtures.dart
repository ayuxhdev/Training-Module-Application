import 'dart:async';

import 'package:dio/dio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/employee.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/notifications/data/repositories/notification_repository.dart';
import 'package:training_app/features/notifications/domain/models/training_notification.dart';
import 'package:training_app/features/notifications/presentation/controllers/notification_controller.dart';

Map<String, dynamic> notificationJson({
  int id = 1,
  int assignmentId = 1,
  bool read = false,
  String type = 'ASSIGNED',
}) => {
  'id': id,
  'type': type,
  'title': 'Training update $id',
  'message': 'Your training update $id.',
  'assignment_id': assignmentId,
  'created_at': '2026-10-17T09:00:00Z',
  'is_read': read,
  'read_at': read ? '2026-10-17T10:00:00Z' : null,
};

TrainingNotification notice({
  int id = 1,
  int assignmentId = 1,
  bool read = false,
  String type = 'ASSIGNED',
}) => TrainingNotification.fromJson(
  notificationJson(id: id, assignmentId: assignmentId, read: read, type: type),
);

NotificationPage noticePage({
  List<TrainingNotification>? items,
  bool more = false,
  int? count,
}) => NotificationPage(
  items: items ?? [notice()],
  count: count ?? items?.length ?? 1,
  hasMore: more,
);

Employee noticeEmployee(String key, {bool active = true}) => Employee(
  username: key,
  employeeCode: key,
  displayName: key,
  department: 'QA',
  jobRole: 'Learner',
  isActive: active,
);

class NotificationTestAuth extends AuthController {
  @override
  AuthState build() => AuthAuthenticated(noticeEmployee('A'));
  void change(AuthState next) => state = next;
  @override
  Future<void> logout() async => state = AuthUnauthenticated();
}

class MockNotificationRepository extends Mock
    implements NotificationRepository {}

class ZeroUnreadController extends NotificationUnreadController {
  @override
  Future<int?> build() async => 0;
}

void stubNotifications(MockNotificationRepository repository) {
  when(
    () => repository.getPage(
      page: any(named: 'page'),
      cancelToken: any(named: 'cancelToken'),
    ),
  ).thenAnswer((_) async => noticePage());
  when(() => repository.getUnreadCount(cancelToken: any(named: 'cancelToken')))
      .thenAnswer((_) async => 1);
  when(() => repository.markRead(any(), cancelToken: any(named: 'cancelToken')))
      .thenAnswer(
        (call) async =>
            notice(id: call.positionalArguments[0] as int, read: true),
      );
  when(() => repository.markAllRead(cancelToken: any(named: 'cancelToken')))
      .thenAnswer((_) async => 1);
}

void registerNotificationFallbacks() => registerFallbackValue(CancelToken());
