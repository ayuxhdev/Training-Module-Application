import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/network/dio_client.dart';
import 'package:training_app/core/providers/core_providers.dart';
import 'package:training_app/features/notifications/domain/models/training_notification.dart';

final notificationRepositoryProvider = Provider<NotificationRepository>(
  (ref) => NotificationRepository(ref.watch(apiClientProvider)),
);

class NotificationRepository {
  final ApiClient apiClient;
  NotificationRepository(this.apiClient);

  Future<NotificationPage> getPage({
    int page = 1,
    CancelToken? cancelToken,
  }) async {
    if (page <= 0) throw ArgumentError.value(page, 'page');
    try {
      final response = await apiClient.dio.get(
        '/notifications/',
        queryParameters: page == 1 ? null : {'page': page},
        cancelToken: cancelToken,
      );
      if (cancelToken?.cancelError case final error?) throw error;
      return NotificationPage.fromJson(response.data as Map<String, dynamic>);
    } catch (error) {
      throw apiClient.mapExceptionToApiError(error);
    }
  }

  Future<int> getUnreadCount({CancelToken? cancelToken}) async {
    try {
      final response = await apiClient.dio.get(
        '/notifications/unread-count/',
        cancelToken: cancelToken,
      );
      if (cancelToken?.cancelError case final error?) throw error;
      return notificationInteger(
        (response.data as Map<String, dynamic>)['unread_count'],
      );
    } catch (error) {
      throw apiClient.mapExceptionToApiError(error);
    }
  }

  Future<TrainingNotification> markRead(
    int id, {
    CancelToken? cancelToken,
  }) async {
    if (id <= 0) throw ArgumentError.value(id, 'id');
    try {
      final response = await apiClient.dio.post(
        '/notifications/$id/read/',
        data: const <String, dynamic>{},
        cancelToken: cancelToken,
      );
      if (cancelToken?.cancelError case final error?) throw error;
      final result = TrainingNotification.fromJson(
        response.data as Map<String, dynamic>,
      );
      if (result.id != id || !result.isRead) {
        throw const FormatException('Unconfirmed notification read response.');
      }
      return result;
    } catch (error) {
      throw apiClient.mapExceptionToApiError(error);
    }
  }

  Future<int> markAllRead({CancelToken? cancelToken}) async {
    try {
      final response = await apiClient.dio.post(
        '/notifications/read-all/',
        data: const <String, dynamic>{},
        cancelToken: cancelToken,
      );
      if (cancelToken?.cancelError case final error?) throw error;
      return notificationInteger(
        (response.data as Map<String, dynamic>)['updated_count'],
      );
    } catch (error) {
      throw apiClient.mapExceptionToApiError(error);
    }
  }
}
