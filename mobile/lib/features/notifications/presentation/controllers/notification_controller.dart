import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/notifications/data/repositories/notification_repository.dart';
import 'package:training_app/features/notifications/domain/models/training_notification.dart';

String? _account(AuthState auth) =>
    auth is AuthAuthenticated && auth.employee.isActive
    ? '${auth.employee.username}:${auth.employee.employeeCode}'
    : null;

void _guardAccount(Ref ref, void Function() clear) {
  final owner = _account(ref.read(authControllerProvider));
  ref.listen(authControllerProvider, (_, next) {
    if (_account(next) != owner) {
      clear();
      ref.invalidateSelf();
    }
  });
  if (owner == null) {
    throw ApiError(message: 'Sign in to view notifications.', statusCode: 401);
  }
}

final notificationUnreadCountProvider =
    AsyncNotifierProvider.autoDispose<NotificationUnreadController, int?>(
      NotificationUnreadController.new,
      retry: (_, _) => null,
    );

class NotificationUnreadController extends AsyncNotifier<int?> {
  @override
  Future<int?> build() async {
    _guardAccount(ref, () => state = const AsyncData(null));
    final requests = CancelToken();
    ref.onDispose(requests.cancel);
    return ref
        .watch(notificationRepositoryProvider)
        .getUnreadCount(cancelToken: requests);
  }
}

class NotificationFeed {
  final List<TrainingNotification> items;
  final int count;
  final int? nextPage;
  final bool busy;
  final bool loadingMore;
  final ApiError? moreError;

  NotificationFeed({
    required List<TrainingNotification> items,
    required this.count,
    this.nextPage,
    this.busy = false,
    this.loadingMore = false,
    this.moreError,
  }) : items = List.unmodifiable(items);

  factory NotificationFeed.fromPage(NotificationPage page) => NotificationFeed(
    items: page.items,
    count: page.count,
    nextPage: page.hasMore ? 2 : null,
  );

  NotificationFeed working({
    bool busy = false,
    bool loadingMore = false,
    ApiError? moreError,
  }) => NotificationFeed(
    items: items,
    count: count,
    nextPage: nextPage,
    busy: busy,
    loadingMore: loadingMore,
    moreError: moreError,
  );
}

class NotificationMutationError extends ApiError {
  NotificationMutationError(ApiError failure)
    : super(
        message: '${failure.message} Refresh to check the saved read status.',
        statusCode: failure.statusCode,
        code: failure.code,
        details: failure.details,
      );
}

final notificationListProvider =
    AsyncNotifierProvider.autoDispose<
      NotificationController,
      NotificationFeed?
    >(NotificationController.new, retry: (_, _) => null);

class NotificationController extends AsyncNotifier<NotificationFeed?> {
  late NotificationRepository _repository;
  late CancelToken _requests;
  String? _owner;
  int _generation = 0;
  Future<void>? _mutation;
  Future<void>? _pagination;

  @override
  Future<NotificationFeed?> build() async {
    final generation = ++_generation;
    _mutation = null;
    _pagination = null;
    final requests = _requests = CancelToken();
    ref.onDispose(requests.cancel);
    _guardAccount(ref, () {
      _generation++;
      requests.cancel();
      state = const AsyncData(null);
    });
    _owner = _account(ref.read(authControllerProvider));
    _repository = ref.watch(notificationRepositoryProvider);
    final page = await _repository.getPage(cancelToken: requests);
    if (!_current(generation)) return null;
    return NotificationFeed.fromPage(page);
  }

  bool _current(int generation) =>
      ref.mounted &&
      generation == _generation &&
      !_requests.isCancelled &&
      _owner != null &&
      _owner == _account(ref.read(authControllerProvider));

  ApiError _error(Object error) =>
      error is ApiError ? error : ApiError.unexpected();

  Future<void> reconcile() async {
    final generation = _generation;
    if (!_current(generation) || state.isLoading) return;
    state = const AsyncLoading();
    try {
      final page = await _repository.getPage(cancelToken: _requests);
      if (_current(generation)) {
        state = AsyncData(NotificationFeed.fromPage(page));
      }
    } catch (error, stack) {
      if (_current(generation)) {
        state = AsyncError(NotificationMutationError(_error(error)), stack);
      }
    } finally {
      if (_current(generation)) ref.invalidate(notificationUnreadCountProvider);
    }
  }

  Future<void> loadMore() {
    if (_pagination != null) return _pagination!;
    final feed = state.asData?.value;
    if (feed == null || feed.nextPage == null || _mutation != null) {
      return Future.value();
    }
    final generation = _generation;
    state = AsyncData(feed.working(loadingMore: true));
    final work = _loadMore(feed, generation);
    _pagination = work;
    return work.whenComplete(() {
      if (identical(_pagination, work)) _pagination = null;
    });
  }

  Future<void> _loadMore(NotificationFeed feed, int generation) async {
    try {
      final page = await _repository.getPage(
        page: feed.nextPage!,
        cancelToken: _requests,
      );
      if (!_current(generation)) return;
      final ids = feed.items.map((item) => item.id).toSet();
      final additions = page.items.where((item) => ids.add(item.id)).toList();
      if (page.hasMore && additions.isEmpty) {
        throw const FormatException(
          'Notification pagination made no progress.',
        );
      }
      state = AsyncData(
        NotificationFeed(
          items: [...feed.items, ...additions],
          count: page.count,
          nextPage: page.hasMore ? feed.nextPage! + 1 : null,
        ),
      );
    } catch (error, stack) {
      if (!_current(generation)) return;
      final failure = _error(error);
      if (failure.statusCode == 401 || failure.statusCode == 403) {
        state = AsyncError(failure, stack);
      } else {
        state = AsyncData(feed.working(moreError: failure));
      }
    }
  }

  Future<void> markRead(int id) {
    final feed = state.asData?.value;
    if (feed == null) return Future.value();
    final item = feed.items.where((item) => item.id == id).firstOrNull;
    if (item == null || item.isRead) return Future.value();
    return _mutate(feed, () async {
      final result = await _repository.markRead(id, cancelToken: _requests);
      if (result.assignmentId != item.assignmentId) {
        throw const FormatException('Mismatched notification assignment.');
      }
      return NotificationFeed(
        items: feed.items.map((old) => old.id == id ? result : old).toList(),
        count: feed.count,
        nextPage: feed.nextPage,
      );
    });
  }

  Future<void> markAllRead() {
    final feed = state.asData?.value;
    if (feed == null) return Future.value();
    final generation = _generation;
    return _mutate(feed, () async {
      await _repository.markAllRead(cancelToken: _requests);
      if (!_current(generation)) return null;
      // The POST returns a count, not read timestamps. Reload authoritative items.
      return NotificationFeed.fromPage(
        await _repository.getPage(cancelToken: _requests),
      );
    });
  }

  Future<void> _mutate(
    NotificationFeed feed,
    Future<NotificationFeed?> Function() operation,
  ) {
    if (_mutation != null) return _mutation!;
    if (_pagination != null) return _pagination!;
    final generation = _generation;
    if (!_current(generation)) return Future.value();
    final pending = ref.keepAlive();
    state = AsyncData(feed.working(busy: true));
    final work = _runMutation(operation, generation);
    _mutation = work;
    return work.whenComplete(() {
      if (identical(_mutation, work)) _mutation = null;
      pending.close();
    });
  }

  Future<void> _runMutation(
    Future<NotificationFeed?> Function() operation,
    int generation,
  ) async {
    try {
      final feed = await operation();
      if (!_current(generation)) return;
      state = AsyncData(feed);
    } catch (error, stack) {
      if (!_current(generation)) return;
      final failure = _error(error);
      state = AsyncError(NotificationMutationError(failure), stack);
    } finally {
      if (_current(generation)) ref.invalidate(notificationUnreadCountProvider);
    }
  }
}
