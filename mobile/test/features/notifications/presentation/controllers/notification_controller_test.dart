import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/notifications/data/repositories/notification_repository.dart';
import 'package:training_app/features/notifications/domain/models/training_notification.dart';
import 'package:training_app/features/notifications/presentation/controllers/notification_controller.dart';

import '../../notification_fixtures.dart';

void main() {
  late MockNotificationRepository repository;
  late NotificationTestAuth auth;
  late ProviderContainer container;

  setUpAll(registerNotificationFallbacks);
  setUp(() {
    repository = MockNotificationRepository();
    stubNotifications(repository);
    auth = NotificationTestAuth();
    container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWith(() => auth),
        notificationRepositoryProvider.overrideWithValue(repository),
      ],
    );
    container.read(authControllerProvider);
    addTearDown(container.dispose);
  });

  Future<void> load() async {
    container.listen(notificationListProvider, (_, _) {});
    container.listen(notificationUnreadCountProvider, (_, _) {});
    await container.read(notificationListProvider.future);
    await container.read(notificationUnreadCountProvider.future);
  }

  test('loads list and count, appends fixed pages and deduplicates shifting results', () async {
    when(
      () => repository.getPage(page: 1, cancelToken: any(named: 'cancelToken')),
    ).thenAnswer((_) async => noticePage(more: true, count: 3));
    when(
      () => repository.getPage(page: 2, cancelToken: any(named: 'cancelToken')),
    ).thenAnswer(
      (_) async =>
          noticePage(items: [notice(), notice(id: 2)], more: true, count: 3),
    );
    when(
      () => repository.getPage(page: 3, cancelToken: any(named: 'cancelToken')),
    ).thenAnswer((_) async => noticePage(items: [notice(id: 3)], count: 3));
    await load();
    final controller = container.read(notificationListProvider.notifier);
    await controller.loadMore();
    await controller.loadMore();
    final feed = container.read(notificationListProvider).requireValue!;
    expect(feed.items.map((e) => e.id), [1, 2, 3]);
    expect(feed.nextPage, isNull);
    expect(container.read(notificationUnreadCountProvider).requireValue, 1);
  });

  test(
    'pagination failure preserves cards and waits for explicit load-more retry',
    () async {
      when(
        () =>
            repository.getPage(page: 1, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => noticePage(more: true, count: 2));
      when(
        () =>
            repository.getPage(page: 2, cancelToken: any(named: 'cancelToken')),
      ).thenThrow(ApiError.networkFailure());
      await load();
      final controller = container.read(notificationListProvider.notifier);
      await controller.loadMore();
      expect(
        container.read(notificationListProvider).requireValue!.moreError?.code,
        'network_failure',
      );
      expect(
        container.read(notificationListProvider).requireValue!.items.single.id,
        1,
      );
      when(
        () =>
            repository.getPage(page: 2, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => noticePage(items: [notice(id: 2)], count: 2));
      await controller.loadMore();
      expect(
        container.read(notificationListProvider).requireValue!.items.length,
        2,
      );
    },
  );

  test('server-confirmed read updates the exact item and refreshes authoritative count', () async {
    await load();
    when(
      () => repository.getUnreadCount(cancelToken: any(named: 'cancelToken')),
    ).thenAnswer((_) async => 0);
    await container.read(notificationListProvider.notifier).markRead(1);
    final item = container
        .read(notificationListProvider)
        .requireValue!
        .items
        .single;
    expect(item.isRead, isTrue);
    expect(item.readAt, notice(read: true).readAt);
    expect(await container.read(notificationUnreadCountProvider.future), 0);
    await container.read(notificationListProvider.notifier).markRead(1);
    verify(() => repository.markRead(1, cancelToken: any(named: 'cancelToken')))
        .called(1);
  });

  test(
    'mark-all reloads server items rather than inventing read timestamps',
    () async {
      await load();
      when(
        () =>
            repository.getPage(page: 1, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => noticePage(items: [notice(read: true)]));
      when(
        () => repository.getUnreadCount(cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => 0);
      await container.read(notificationListProvider.notifier).markAllRead();
      expect(
        container
            .read(notificationListProvider)
            .requireValue!
            .items
            .single
            .readAt,
        notice(read: true).readAt,
      );
      expect(await container.read(notificationUnreadCountProvider.future), 0);
      verify(
        () => repository.markAllRead(cancelToken: any(named: 'cancelToken')),
      ).called(1);
    },
  );

  test('duplicate and overlapping mutation actions submit only once', () async {
    await load();
    final pending = Completer<TrainingNotification>();
    when(() => repository.markRead(1, cancelToken: any(named: 'cancelToken')))
        .thenAnswer((_) => pending.future);
    final controller = container.read(notificationListProvider.notifier);
    final first = controller.markRead(1);
    final second = controller.markRead(1);
    final all = controller.markAllRead();
    expect(container.read(notificationListProvider).requireValue!.busy, isTrue);
    pending.complete(notice(read: true));
    await Future.wait([first, second, all]);
    verify(() => repository.markRead(1, cancelToken: any(named: 'cancelToken')))
        .called(1);
    verifyNever(
      () => repository.markAllRead(cancelToken: any(named: 'cancelToken')),
    );
  });

  test('uncertain POST failure requires GET recovery without automatic mutation retry', () async {
    await load();
    when(() => repository.markRead(1, cancelToken: any(named: 'cancelToken')))
        .thenThrow(ApiError.timeout());
    await container.read(notificationListProvider.notifier).markRead(1);
    expect(container.read(notificationListProvider).hasError, isTrue);
    expect(
      (container.read(notificationListProvider).error as ApiError).message,
      contains('Refresh to check'),
    );
    when(
      () => repository.getPage(page: 1, cancelToken: any(named: 'cancelToken')),
    ).thenAnswer((_) async => noticePage(items: [notice(read: true)]));
    expect(
      (await container.refresh(notificationListProvider.future))!
          .items
          .single
          .isRead,
      isTrue,
    );
    verify(() => repository.markRead(1, cancelToken: any(named: 'cancelToken')))
        .called(1);
  });

  test(
    'failed reconciliation retains mutation context and can be refreshed again',
    () async {
      await load();
      final failure = ApiError(
        message: 'Rejected',
        statusCode: 409,
        code: 'conflict',
        details: {'field': 'read'},
      );
      when(() => repository.markRead(1, cancelToken: any(named: 'cancelToken')))
          .thenThrow(failure);
      final controller = container.read(notificationListProvider.notifier);
      await controller.markRead(1);
      final error =
          container.read(notificationListProvider).error
              as NotificationMutationError;
      expect(error.statusCode, 409);
      expect(error.code, 'conflict');
      expect(error.details, failure.details);
      when(
        () =>
            repository.getPage(page: 1, cancelToken: any(named: 'cancelToken')),
      ).thenThrow(ApiError(message: 'Unavailable', statusCode: 404));
      await controller.reconcile();
      expect(
        container.read(notificationListProvider).error,
        isA<NotificationMutationError>(),
      );
      when(
        () =>
            repository.getPage(page: 1, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => noticePage(items: [notice(read: true)]));
      await controller.reconcile();
      expect(
        container
            .read(notificationListProvider)
            .requireValue!
            .items
            .single
            .isRead,
        isTrue,
      );
      verify(
        () => repository.markRead(1, cancelToken: any(named: 'cancelToken')),
      ).called(1);
    },
  );

  test(
    'account switching cancels reconciliation and rejects its late response',
    () async {
      await load();
      when(() => repository.markRead(1, cancelToken: any(named: 'cancelToken')))
          .thenThrow(ApiError.timeout());
      final controller = container.read(notificationListProvider.notifier);
      await controller.markRead(1);
      final page = Completer<NotificationPage>();
      late CancelToken token;
      when(
        () =>
            repository.getPage(page: 1, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((call) {
        token = call.namedArguments[#cancelToken] as CancelToken;
        return page.future;
      });
      final pending = controller.reconcile();
      when(
        () =>
            repository.getPage(page: 1, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => noticePage(items: [notice(id: 2)]));
      auth.change(AuthAuthenticated(noticeEmployee('B')));
      await container.read(notificationListProvider.future);
      expect(token.isCancelled, isTrue);
      page.complete(noticePage(items: [notice(read: true)]));
      await pending;
      expect(
        container.read(notificationListProvider).requireValue!.items.single.id,
        2,
      );
      verify(
        () => repository.markRead(1, cancelToken: any(named: 'cancelToken')),
      ).called(1);
    },
  );

  test(
    'a successful mark-read refreshes count after a filter supersedes it',
    () async {
      await load();
      final mutation = Completer<TrainingNotification>();
      when(() => repository.markRead(1, cancelToken: any(named: 'cancelToken')))
          .thenAnswer((_) => mutation.future);
      final controller = container.read(notificationListProvider.notifier);
      final pending = controller.markRead(1);
      when(
        () => repository.getPage(
          page: 1,
          status: NotificationReadFilter.all,
          query: 'latest',
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => noticePage(items: [notice(id: 2)], count: 1));
      await controller.applyFilter(query: 'latest');
      when(
        () => repository.getUnreadCount(cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => 7);
      mutation.complete(notice(read: true));
      await pending;

      expect(await container.read(notificationUnreadCountProvider.future), 7);
      expect(
        container.read(notificationListProvider).requireValue!.items.single.id,
        2,
      );
    },
  );

  test(
    'a successful mark-all refreshes count after a filter supersedes it',
    () async {
      await load();
      final mutation = Completer<int>();
      when(() => repository.markAllRead(cancelToken: any(named: 'cancelToken')))
          .thenAnswer((_) => mutation.future);
      final controller = container.read(notificationListProvider.notifier);
      final pending = controller.markAllRead();
      when(
        () => repository.getPage(
          page: 1,
          status: NotificationReadFilter.all,
          query: 'latest',
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => noticePage(items: [notice(id: 2)], count: 1));
      await controller.applyFilter(query: 'latest');
      when(
        () => repository.getUnreadCount(cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => 6);
      mutation.complete(1);
      await pending;

      expect(await container.read(notificationUnreadCountProvider.future), 6);
      expect(
        container.read(notificationListProvider).requireValue!.items.single.id,
        2,
      );
    },
  );

  test(
    'filter errors and retries never expose cards from a different result set',
    () async {
      await load();
      final pendingPage = Completer<NotificationPage>();
      when(
        () => repository.getPage(
          page: 1,
          status: NotificationReadFilter.all,
          query: 'restricted',
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) => pendingPage.future);

      final controller = container.read(notificationListProvider.notifier);
      final firstRequest = controller.applyFilter(query: 'restricted');
      expect(
        container.read(notificationListProvider).requireValue!.items,
        isEmpty,
      );
      pendingPage.completeError(
        ApiError(message: 'Permission denied.', statusCode: 403),
        StackTrace.current,
      );
      await firstRequest;
      expect(
        container.read(notificationListProvider).requireValue!.items,
        isEmpty,
      );
      expect(
        container
            .read(notificationListProvider)
            .requireValue!
            .filterError
            ?.statusCode,
        403,
      );

      when(
        () => repository.getPage(
          page: 1,
          status: NotificationReadFilter.all,
          query: 'restricted',
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(ApiError(message: 'Permission denied.', statusCode: 403));
      await controller.applyFilter();
      expect(
        container.read(notificationListProvider).requireValue!.items,
        isEmpty,
      );

      when(
        () => repository.getPage(
          page: 1,
          status: NotificationReadFilter.all,
          query: 'restricted',
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => noticePage(items: [notice(id: 2)], count: 1));
      await controller.applyFilter();
      expect(
        container
            .read(notificationListProvider)
            .requireValue!
            .items
            .map((item) => item.id),
        [2],
      );
      expect(controller.activeQuery, 'restricted');
    },
  );

  test('a superseded mutation cannot leave the new filter busy', () async {
    await load();
    final mutation = Completer<TrainingNotification>();
    when(() => repository.markRead(1, cancelToken: any(named: 'cancelToken')))
        .thenAnswer((_) => mutation.future);
    when(
      () => repository.getPage(
        page: 1,
        status: NotificationReadFilter.all,
        query: 'latest',
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenThrow(ApiError.networkFailure());

    final controller = container.read(notificationListProvider.notifier);
    final pendingMutation = controller.markRead(1);
    await controller.applyFilter(query: 'latest');
    var feed = container.read(notificationListProvider).requireValue!;
    expect(feed.busy, isFalse);
    expect(feed.filterError, isNotNull);

    mutation.complete(notice(read: true));
    await pendingMutation;
    feed = container.read(notificationListProvider).requireValue!;
    expect(feed.busy, isFalse);
    expect(feed.query, 'latest');
    expect(feed.items, isEmpty);
    expect(feed.filterError, isNotNull);
  });

  test('successful mark-all followed by failed reload shows recovery, not stale read buttons', () async {
    await load();
    when(
      () => repository.getPage(page: 1, cancelToken: any(named: 'cancelToken')),
    ).thenThrow(ApiError.networkFailure());
    await container.read(notificationListProvider.notifier).markAllRead();
    expect(container.read(notificationListProvider).hasError, isTrue);
    verify(() => repository.markAllRead(cancelToken: any(named: 'cancelToken')))
        .called(1);
  });

  test(
    'read response with mismatched assignment cannot replace current item',
    () async {
      await load();
      when(() => repository.markRead(1, cancelToken: any(named: 'cancelToken')))
          .thenAnswer((_) async => notice(read: true, assignmentId: 99));
      await container.read(notificationListProvider.notifier).markRead(1);
      expect(container.read(notificationListProvider).hasError, isTrue);
    },
  );

  test(
    'logout clears data, cancels both reads, and ignores late successes',
    () async {
      final page = Completer<NotificationPage>();
      final count = Completer<int>();
      final tokens = <CancelToken>[];
      when(
        () =>
            repository.getPage(page: 1, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((call) {
        tokens.add(call.namedArguments[#cancelToken] as CancelToken);
        return page.future;
      });
      when(
        () => repository.getUnreadCount(cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((call) {
        tokens.add(call.namedArguments[#cancelToken] as CancelToken);
        return count.future;
      });
      container.listen(notificationListProvider, (_, _) {});
      container.listen(notificationUnreadCountProvider, (_, _) {});
      await Future<void>.delayed(Duration.zero);
      auth.change(AuthUnauthenticated());
      await expectLater(
        container.read(notificationListProvider.future),
        throwsA(isA<ApiError>()),
      );
      await expectLater(
        container.read(notificationUnreadCountProvider.future),
        throwsA(isA<ApiError>()),
      );
      expect(tokens.every((token) => token.isCancelled), isTrue);
      page.complete(noticePage());
      count.complete(9);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(notificationListProvider).value, isNull);
      expect(container.read(notificationUnreadCountProvider).value, isNull);
    },
  );

  test(
    'A to B to A responses cannot overwrite newer data or an error',
    () async {
      await load();
      final old = Completer<NotificationPage>();
      final oldCount = Completer<int>();
      when(
        () =>
            repository.getPage(page: 1, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) => old.future);
      when(
        () => repository.getUnreadCount(cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) => oldCount.future);
      auth.change(AuthAuthenticated(noticeEmployee('B')));
      await Future<void>.delayed(Duration.zero);
      expect(container.read(notificationListProvider).value, isNull);
      expect(container.read(notificationUnreadCountProvider).value, isNull);
      when(
        () =>
            repository.getPage(page: 1, cancelToken: any(named: 'cancelToken')),
      ).thenThrow(ApiError(message: 'Denied', statusCode: 403));
      when(
        () => repository.getUnreadCount(cancelToken: any(named: 'cancelToken')),
      ).thenThrow(ApiError.networkFailure());
      auth.change(AuthAuthenticated(noticeEmployee('A')));
      await expectLater(
        container.read(notificationListProvider.future),
        throwsA(isA<ApiError>()),
      );
      await expectLater(
        container.read(notificationUnreadCountProvider.future),
        throwsA(isA<ApiError>()),
      );
      old.complete(noticePage(items: [notice(id: 99)]));
      oldCount.complete(99);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(notificationListProvider).value, isNull);
      expect(container.read(notificationUnreadCountProvider).value, isNull);
    },
  );

  test('old mark-all success after account switch cannot fetch or invalidate the new account', () async {
    await load();
    final mutation = Completer<int>();
    when(() => repository.markAllRead(cancelToken: any(named: 'cancelToken')))
        .thenAnswer((_) => mutation.future);
    final pending = container
        .read(notificationListProvider.notifier)
        .markAllRead();
    auth.change(AuthAuthenticated(noticeEmployee('B')));
    await container.read(notificationListProvider.future);
    await container.read(notificationUnreadCountProvider.future);
    clearInteractions(repository);
    mutation.complete(1);
    await pending;
    verifyZeroInteractions(repository);
    expect(
      container
          .read(notificationListProvider)
          .requireValue!
          .items
          .single
          .isRead,
      isFalse,
    );
  });

  test(
    'disposal cancels pending reads and no late UI state is published',
    () async {
      final pending = Completer<NotificationPage>();
      late CancelToken token;
      when(
        () =>
            repository.getPage(page: 1, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((call) {
        token = call.namedArguments[#cancelToken] as CancelToken;
        return pending.future;
      });
      container.listen(notificationListProvider, (_, _) {});
      await Future<void>.delayed(Duration.zero);
      container.dispose();
      expect(token.isCancelled, isTrue);
      pending.complete(noticePage());
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'refresh cancels pagination and late pages cannot replace refreshed data',
    () async {
      when(
        () =>
            repository.getPage(page: 1, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => noticePage(more: true, count: 2));
      await load();
      final page = Completer<NotificationPage>();
      late CancelToken token;
      when(
        () =>
            repository.getPage(page: 2, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((call) {
        token = call.namedArguments[#cancelToken] as CancelToken;
        return page.future;
      });
      final pending = container
          .read(notificationListProvider.notifier)
          .loadMore();
      when(
        () =>
            repository.getPage(page: 1, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => noticePage(items: [notice(id: 3)]));
      await container.refresh(notificationListProvider.future);
      expect(token.isCancelled, isTrue);
      page.complete(noticePage(items: [notice(id: 2)]));
      await pending;
      expect(
        container.read(notificationListProvider).requireValue!.items.single.id,
        3,
      );
    },
  );

  test('inactive or signed-out users make no repository request', () async {
    for (final authState in [
      AuthUnauthenticated(),
      AuthAuthenticated(noticeEmployee('inactive', active: false)),
    ]) {
      auth.change(authState);
      await expectLater(
        container.read(notificationListProvider.future),
        throwsA(isA<ApiError>()),
      );
      await expectLater(
        container.read(notificationUnreadCountProvider.future),
        throwsA(isA<ApiError>()),
      );
    }
    verifyZeroInteractions(repository);
  });

  group('NotificationController - Server-Side Filtering and Search', () {
    test(
      'applyFilter sends server-side status and query and resets pagination',
      () async {
        when(
          () => repository.getPage(
            page: 1,
            status: NotificationReadFilter.unread,
            query: 'safety',
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => noticePage(
            items: [notice(id: 10, type: 'OVERDUE')],
            count: 1,
            more: false,
          ),
        );
        await load();
        final controller = container.read(notificationListProvider.notifier);
        await controller.applyFilter(
          status: NotificationReadFilter.unread,
          query: 'safety',
        );
        final feed = container.read(notificationListProvider).requireValue!;
        expect(feed.status, NotificationReadFilter.unread);
        expect(feed.query, 'safety');
        expect(feed.items.single.id, 10);
        expect(feed.count, 1);
        expect(feed.nextPage, isNull);
      },
    );

    test('marking unread refreshes page one without skipping the shifted last item', () async {
      final firstPage = List.generate(20, (index) => notice(id: index + 1));
      final refreshedPage = List.generate(
        21,
        (index) => index + 1,
      ).where((id) => id != 10).map((id) => notice(id: id)).toList();
      var unreadPageRequests = 0;
      when(
        () => repository.getPage(
          page: 1,
          status: NotificationReadFilter.unread,
          query: 'safety',
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async {
        unreadPageRequests++;
        return unreadPageRequests == 1
            ? noticePage(items: firstPage, count: 21, more: true)
            : noticePage(items: refreshedPage, count: 20);
      });
      when(
        () => repository.markRead(10, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => notice(id: 10, read: true));

      await load();
      final controller = container.read(notificationListProvider.notifier);
      await controller.applyFilter(
        status: NotificationReadFilter.unread,
        query: 'safety',
      );
      expect(
        container
            .read(notificationListProvider)
            .requireValue!
            .items
            .map((item) => item.id)
            .toList(),
        List.generate(20, (index) => index + 1),
      );

      when(
        () => repository.getUnreadCount(cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => 20);
      await controller.markRead(10);
      final feed = container.read(notificationListProvider).requireValue!;
      final ids = feed.items.map((item) => item.id).toList();
      expect(ids, refreshedPage.map((item) => item.id).toList());
      expect(ids.toSet(), hasLength(20));
      expect(ids, contains(21));
      expect(ids, isNot(contains(10)));
      expect(feed.count, 20);
      expect(feed.nextPage, isNull);
      expect(feed.status, NotificationReadFilter.unread);
      expect(feed.query, 'safety');
      expect(await container.read(notificationUnreadCountProvider.future), 20);

      await controller.loadMore();
      verify(
        () => repository.markRead(10, cancelToken: any(named: 'cancelToken')),
      ).called(1);
      verifyNever(
        () => repository.getPage(
          page: 2,
          status: NotificationReadFilter.unread,
          query: 'safety',
          cancelToken: any(named: 'cancelToken'),
        ),
      );
    });

    test(
      'loadMore preserves active status and query to server repository',
      () async {
        when(
          () => repository.getPage(
            page: 1,
            status: NotificationReadFilter.read,
            query: 'fire',
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => noticePage(
            items: [notice(id: 5, read: true)],
            count: 2,
            more: true,
          ),
        );
        when(
          () => repository.getPage(
            page: 2,
            status: NotificationReadFilter.read,
            query: 'fire',
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => noticePage(
            items: [notice(id: 6, read: true)],
            count: 2,
            more: false,
          ),
        );
        await load();
        final controller = container.read(notificationListProvider.notifier);
        await controller.applyFilter(
          status: NotificationReadFilter.read,
          query: 'fire',
        );
        await controller.loadMore();
        final feed = container.read(notificationListProvider).requireValue!;
        expect(feed.items.map((e) => e.id), [5, 6]);
        expect(feed.status, NotificationReadFilter.read);
        expect(feed.query, 'fire');
        verify(
          () => repository.getPage(
            page: 2,
            status: NotificationReadFilter.read,
            query: 'fire',
            cancelToken: any(named: 'cancelToken'),
          ),
        ).called(1);
      },
    );

    test(
      'rapid filter changes cancel and ignore stale in-flight responses',
      () async {
        await load();
        final slowPage = Completer<NotificationPage>();
        late CancelToken slowToken;
        when(
          () => repository.getPage(
            page: 1,
            status: NotificationReadFilter.unread,
            query: 'first',
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((call) {
          slowToken = call.namedArguments[#cancelToken] as CancelToken;
          return slowPage.future;
        });
        when(
          () => repository.getPage(
            page: 1,
            status: NotificationReadFilter.read,
            query: 'second',
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async =>
              noticePage(items: [notice(id: 99, read: true)], count: 1),
        );

        final controller = container.read(notificationListProvider.notifier);
        final first = controller.applyFilter(
          status: NotificationReadFilter.unread,
          query: 'first',
        );
        expect(
          container.read(notificationListProvider).requireValue!.items,
          isEmpty,
        );
        final second = controller.applyFilter(
          status: NotificationReadFilter.read,
          query: 'second',
        );
        expect(slowToken.isCancelled, isTrue);
        slowPage.complete(noticePage(items: [notice(id: 1)]));
        await Future.wait([first, second]);

        final feed = container.read(notificationListProvider).requireValue!;
        expect(feed.status, NotificationReadFilter.read);
        expect(feed.query, 'second');
        expect(feed.items.single.id, 99);
      },
    );

    test('account switch invalidates a pending filter and ignores its late response', () async {
      await load();
      final oldPage = Completer<NotificationPage>();
      when(
        () => repository.getPage(
          page: 1,
          status: NotificationReadFilter.unread,
          query: 'old account',
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) => oldPage.future);
      final controller = container.read(notificationListProvider.notifier);
      final pending = controller.applyFilter(
        status: NotificationReadFilter.unread,
        query: 'old account',
      );

      when(
        () => repository.getPage(
          page: 1,
          status: NotificationReadFilter.all,
          query: '',
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => noticePage(items: [notice(id: 2)]));
      auth.change(AuthAuthenticated(noticeEmployee('B')));
      await container.read(notificationListProvider.future);
      oldPage.complete(noticePage(items: [notice(id: 99)]));
      await pending;

      final feed = container.read(notificationListProvider).requireValue!;
      expect(feed.status, NotificationReadFilter.all);
      expect(feed.query, isEmpty);
      expect(feed.items.single.id, 2);
    });
  });
}
