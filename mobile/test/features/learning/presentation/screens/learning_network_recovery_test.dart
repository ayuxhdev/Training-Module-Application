import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/core/network/dio_client.dart';
import 'package:training_app/core/presentation/components/content_skeleton.dart';
import 'package:training_app/core/providers/core_providers.dart';
import 'package:training_app/core/storage/secure_token_storage.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/employee.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/learning/presentation/controllers/learning_controller.dart';
import 'package:training_app/features/learning/data/repositories/learning_repository.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/features/learning/presentation/screens/learning_screen.dart';
import 'package:training_app/features/learning/presentation/screens/assignment_detail_screen.dart';

String _access({bool expired = false}) {
  final expiry = DateTime.now().add(Duration(minutes: expired ? -1 : 30));
  final payload = base64Url.encode(
    utf8.encode(
      jsonEncode({'user_id': 1, 'exp': expiry.millisecondsSinceEpoch ~/ 1000}),
    ),
  );
  return 'header.$payload.signature';
}

class _Tokens extends Fake implements SecureTokenStorage {
  String? access = _access();
  String? refresh = 'parent';
  bool invalid = false;

  @override
  Future<String?> readAccessToken() async => access;
  @override
  Future<String?> readRefreshToken() async => refresh;
  @override
  Future<bool> isSessionInvalid() async => invalid;
  @override
  Future<void> saveAccessToken(String value) async => access = value;
  @override
  Future<void> saveRefreshToken(String value) async => refresh = value;
  @override
  Future<void> markSessionInvalid() async => invalid = true;
  @override
  Future<void> clearAuthenticationState() async {
    access = null;
    refresh = null;
  }
}

class _Auth extends AuthController {
  @override
  AuthState build() => AuthAuthenticated(
    Employee(
      username: 'learner',
      employeeCode: 'LEARNER',
      displayName: 'Learner',
      department: 'QA',
      jobRole: 'Learner',
      isActive: true,
    ),
  );

  void switchAccount() => state = AuthAuthenticated(
    Employee(
      username: 'second',
      employeeCode: 'SECOND',
      displayName: 'Second learner',
      department: 'QA',
      jobRole: 'Learner',
      isActive: true,
    ),
  );
}

class _Adapter implements HttpClientAdapter {
  final FutureOr<ResponseBody> Function(RequestOptions) respond;
  final requests = <RequestOptions>[];
  _Adapter(this.respond);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _reply(Object data) => ResponseBody.fromString(
  jsonEncode(data),
  200,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

ResponseBody _page(String title, {String? next}) => _reply({
  'count': 1,
  'next': next,
  'previous': null,
  'results': [
    {'id': 1, 'training_title': title},
  ],
});

class _Harness {
  final tokens = _Tokens();
  final auth = _Auth();
  late final _Adapter adapter;
  late final ApiClient client;
  late final ProviderContainer container;

  _Harness(FutureOr<ResponseBody> Function(RequestOptions) respond) {
    adapter = _Adapter(respond);
    final dio = Dio(
      BaseOptions(
        baseUrl: 'https://example.invalid/api/v1',
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
        sendTimeout: const Duration(seconds: 15),
      ),
    )..httpClientAdapter = adapter;
    client = ApiClient(tokenStorage: tokens, dioOverride: dio);
    container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(client),
        secureTokenStorageProvider.overrideWithValue(tokens),
        authControllerProvider.overrideWith(() => auth),
      ],
    );
    addTearDown(() {
      container.dispose();
      dio.close(force: true);
    });
  }

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: LearningScreen()),
      ),
    );
    await dispatched(tester, 1);
  }

  Future<void> dispatched(WidgetTester tester, int count) async {
    // Dio schedules interceptor stages on the event queue. Drain those stages
    // with small fake-clock steps, without real sleeps or settling the skeleton.
    for (var turn = 0; turn < 30 && adapter.requests.length < count; turn++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(adapter.requests, hasLength(count));
  }

  void expectSessionPreserved() {
    expect(container.read(authControllerProvider), isA<AuthAuthenticated>());
    expect(tokens.access, isNotNull);
    expect(tokens.refresh, isNotNull);
    expect(tokens.invalid, isFalse);
    expect(client.session.canAuthorize, isTrue);
  }
}

void main() {
  testWidgets(
    'stalled read leaves loading within 30 seconds and Retry recovers',
    (tester) async {
      final stalled = Completer<ResponseBody>();
      var online = false;
      final harness = _Harness(
        (_) => online ? _page('Recovered') : stalled.future,
      );
      await harness.mount(tester);
      expect(find.byType(LearningSkeleton), findsOneWidget);
      await tester.pump(const Duration(seconds: 31));
      await tester.pump();
      expect(find.text('Request timed out'), findsOneWidget);
      expect(find.byType(LearningSkeleton), findsNothing);
      expect(harness.adapter.requests.single.cancelToken!.isCancelled, isTrue);
      harness.expectSessionPreserved();
      online = true;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Recovered'), findsOneWidget);
      stalled.complete(_page('Obsolete result'));
      await tester.pumpAndSettle();
      expect(find.text('Obsolete result'), findsNothing);
      expect(harness.adapter.requests, hasLength(2));
      harness.expectSessionPreserved();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'body trickling within Dio idle timeout still has a total deadline',
    (tester) async {
      final body = StreamController<Uint8List>();
      final timer = Timer.periodic(const Duration(seconds: 5), (_) {
        body.add(Uint8List.fromList([32]));
      });
      body.onCancel = timer.cancel;
      addTearDown(timer.cancel);
      addTearDown(() {
        unawaited(body.close());
      });
      final harness = _Harness(
        (_) => ResponseBody(
          body.stream,
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        ),
      );
      await harness.mount(tester);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 5));
      }
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('Request timed out'), findsOneWidget);
      expect(find.byType(LearningSkeleton), findsNothing);
      harness.expectSessionPreserved();
    },
  );

  for (final type in [
    DioExceptionType.connectionError,
    DioExceptionType.connectionTimeout,
    DioExceptionType.receiveTimeout,
  ]) {
    testWidgets(
      '${type.name} shows a recoverable error without ending the session',
      (tester) async {
        var online = false;
        final harness = _Harness((options) {
          if (!online) throw DioException(requestOptions: options, type: type);
          return _page('Connected again');
        });
        await harness.mount(tester);
        await tester.pumpAndSettle();
        expect(
          find.text(
            type == DioExceptionType.connectionError
                ? 'Connection unavailable'
                : 'Request timed out',
          ),
          findsOneWidget,
        );
        expect(find.byType(LearningSkeleton), findsNothing);
        harness.expectSessionPreserved();
        await tester.pump(const Duration(seconds: 60));
        expect(harness.adapter.requests, hasLength(1));
        online = true;
        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();
        expect(find.text('Connected again'), findsOneWidget);
        expect(harness.adapter.requests, hasLength(2));
        harness.expectSessionPreserved();
      },
    );
  }

  testWidgets(
    'all pages share one deadline and partial assignments are not exposed',
    (tester) async {
      final first = Completer<ResponseBody>();
      final second = Completer<ResponseBody>();
      final harness = _Harness(
        (options) =>
            options.queryParameters['page'] == 2 ? second.future : first.future,
      );
      await harness.mount(tester);
      await tester.pump(const Duration(seconds: 20));
      first.complete(_page('Incomplete list', next: '/assignments/?page=2'));
      await harness.dispatched(tester, 2);
      expect(harness.adapter.requests, hasLength(2));
      expect(find.text('Incomplete list'), findsNothing);
      await tester.pump(const Duration(seconds: 11));
      await tester.pump();
      expect(find.text('Request timed out'), findsOneWidget);
      expect(harness.adapter.requests.last.cancelToken!.isCancelled, isTrue);
      second.complete(_page('Late second page', next: '/assignments/?page=3'));
      await tester.pumpAndSettle();
      expect(harness.adapter.requests, hasLength(2));
      expect(find.text('Late second page'), findsNothing);
      harness.expectSessionPreserved();
    },
  );

  testWidgets(
    'authentication wait is bounded without cancelling shared token rotation',
    (tester) async {
      final rotation = Completer<ResponseBody>();
      final harness = _Harness(
        (options) => options.path == '/auth/refresh/'
            ? rotation.future
            : _page('Refreshed session'),
      );
      harness.tokens.access = _access(expired: true);
      await harness.mount(tester);
      expect(harness.adapter.requests.single.path, '/auth/refresh/');
      await tester.pump(const Duration(seconds: 31));
      await tester.pump();
      expect(find.text('Request timed out'), findsOneWidget);
      expect(harness.tokens.refresh, 'parent');
      harness.expectSessionPreserved();
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(harness.adapter.requests, hasLength(1));
      rotation.complete(
        _reply({'access': _access(), 'refresh': 'rotated-child'}),
      );
      await tester.pumpAndSettle();
      expect(find.text('Refreshed session'), findsOneWidget);
      expect(harness.tokens.refresh, 'rotated-child');
      expect(
        harness.adapter.requests.where((r) => r.path == '/auth/refresh/'),
        hasLength(1),
      );
      expect(
        harness.adapter.requests.where((r) => r.path == '/assignments/'),
        hasLength(1),
      );
      harness.expectSessionPreserved();
    },
  );

  testWidgets(
    'offline refresh can be retried after reconnection without clearing credentials',
    (tester) async {
      var online = false;
      final harness = _Harness((options) {
        if (options.path == '/auth/refresh/') {
          if (!online) {
            throw DioException(
              requestOptions: options,
              type: DioExceptionType.connectionTimeout,
            );
          }
          return _reply({'access': _access(), 'refresh': 'child'});
        }
        return _page('Authenticated recovery');
      });
      harness.tokens.access = _access(expired: true);
      await harness.mount(tester);
      await tester.pumpAndSettle();
      expect(find.text('Request timed out'), findsOneWidget);
      expect(harness.tokens.refresh, 'parent');
      harness.expectSessionPreserved();
      online = true;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Authenticated recovery'), findsOneWidget);
      expect(harness.tokens.refresh, 'child');
      harness.expectSessionPreserved();
    },
  );

  testWidgets(
    'repeated refresh cancels superseded requests and rejects late results',
    (tester) async {
      final pending = <Completer<ResponseBody>>[];
      final harness = _Harness((_) {
        final reply = Completer<ResponseBody>();
        pending.add(reply);
        return reply.future;
      });
      await harness.mount(tester);
      for (var i = 0; i < 2; i++) {
        harness.container.invalidate(assignmentListProvider);
        await harness.dispatched(tester, i + 2);
      }
      expect(pending, hasLength(3));
      expect(
        harness.adapter.requests
            .take(2)
            .every((r) => r.cancelToken!.isCancelled),
        isTrue,
      );
      pending.last.complete(_page('Newest assignments'));
      await tester.pumpAndSettle();
      pending[0].complete(_page('Stale one'));
      pending[1].complete(_page('Stale two'));
      await tester.pumpAndSettle();
      expect(find.text('Newest assignments'), findsOneWidget);
      expect(find.textContaining('Stale'), findsNothing);
      expect(tester.takeException(), isNull);
      harness.expectSessionPreserved();
    },
  );

  testWidgets(
    'account switch cancels old reads and never exposes another account response',
    (tester) async {
      final previous = Completer<ResponseBody>();
      var calls = 0;
      final harness = _Harness(
        (_) => ++calls == 1 ? previous.future : _page('Second account'),
      );
      await harness.mount(tester);
      harness.auth.switchAccount();
      await tester.pumpAndSettle();
      expect(harness.adapter.requests.first.cancelToken!.isCancelled, isTrue);
      expect(find.text('Second account'), findsOneWidget);
      previous.complete(_page('Private first account'));
      await tester.pumpAndSettle();
      expect(find.text('Private first account'), findsNothing);
      expect(find.text('Second account'), findsOneWidget);
    },
  );

  testWidgets(
    'disposal cancels in-flight read and its deadline without UI errors',
    (tester) async {
      final pending = Completer<ResponseBody>();
      final harness = _Harness((_) => pending.future);
      await harness.mount(tester);
      // Keep the app/provider scope alive, as when navigating away from Learning.
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: harness.container,
          child: const MaterialApp(home: SizedBox.shrink()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 1));
      expect(harness.adapter.requests.single.cancelToken!.isCancelled, isTrue);
      pending.complete(_page('Disposed result'));
      await tester.pump(const Duration(seconds: 31));
      expect(tester.takeException(), isNull);
      expect(harness.adapter.requests, hasLength(1));
      harness.expectSessionPreserved();
    },
  );

  testWidgets(
    'assignment detail also terminates and Retry reloads without restarting',
    (tester) async {
      final pending = Completer<ResponseBody>();
      var online = false;
      final harness = _Harness(
        (_) => online
            ? _reply({
                'id': 1,
                'training_title': 'Recovered detail',
                'modules': [],
              })
            : pending.future,
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: harness.container,
          child: const MaterialApp(
            home: AssignmentDetailScreen(assignmentId: 1),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 31));
      await tester.pump();
      expect(find.text('Request timed out'), findsOneWidget);
      online = true;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Recovered detail'), findsOneWidget);
      pending.complete(
        _reply({'id': 1, 'training_title': 'Obsolete detail', 'modules': []}),
      );
      await tester.pumpAndSettle();
      expect(find.text('Obsolete detail'), findsNothing);
      harness.expectSessionPreserved();
    },
  );

  testWidgets(
    'Learning deadline does not apply to a slow mutation or replay it',
    (tester) async {
      final pending = Completer<ResponseBody>();
      final harness = _Harness((_) => pending.future);
      final mutation = harness.client.dio.post(
        '/assignments/1/lessons/2/complete/',
      );
      await harness.dispatched(tester, 1);
      await tester.pump(const Duration(seconds: 31));
      expect(harness.adapter.requests.single.method, 'POST');
      expect(
        harness.adapter.requests.single.cancelToken?.isCancelled ?? false,
        isFalse,
      );
      pending.complete(_reply({'completed': true}));
      await tester.pumpAndSettle();
      expect((await mutation).data['completed'], isTrue);
      expect(harness.adapter.requests, hasLength(1));
    },
  );

  testWidgets(
    'pull refresh terminates on timeout and can be repeated after Retry',
    (tester) async {
      final pending = <Completer<ResponseBody>>[];
      var online = true;
      final harness = _Harness((_) {
        if (online) return _page('Available assignments');
        final response = Completer<ResponseBody>();
        pending.add(response);
        return response.future;
      });
      await harness.mount(tester);
      await tester.pumpAndSettle();
      for (var attempt = 0; attempt < 2; attempt++) {
        online = false;
        // The screen replaces the indicator while refreshing. Flutter's show()
        // future only completes while that indicator remains mounted.
        unawaited(
          tester
              .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
              .show(),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await harness.dispatched(tester, 2 + attempt * 2);
        await tester.pump(const Duration(seconds: 31));
        await tester.pumpAndSettle();
        expect(find.text('Request timed out'), findsOneWidget);
        expect(find.byType(RefreshProgressIndicator), findsNothing);
        online = true;
        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();
        expect(find.text('Available assignments'), findsOneWidget);
      }
      for (final response in pending) {
        response.complete(_page('Old refresh'));
      }
      await tester.pumpAndSettle();
      expect(find.text('Old refresh'), findsNothing);
      expect(harness.adapter.requests, hasLength(5));
      harness.expectSessionPreserved();
    },
  );

  testWidgets(
    'deadline cancels its owned request without cancelling the caller token',
    (tester) async {
      final pending = Completer<ResponseBody>();
      final harness = _Harness((_) => pending.future);
      final owner = CancelToken();
      final outcome = expectLater(
        harness.container
            .read(learningRepositoryProvider)
            .getAssignments(cancelToken: owner),
        throwsA(isA<ApiError>().having((e) => e.code, 'code', 'timeout')),
      );
      await harness.dispatched(tester, 1);
      await tester.pump(const Duration(seconds: 31));
      await outcome;
      expect(owner.isCancelled, isFalse);
      expect(harness.adapter.requests.single.cancelToken!.isCancelled, isTrue);
      pending.complete(_page('Too late'));
      await tester.pumpAndSettle();
      owner.cancel();
      harness.expectSessionPreserved();
    },
  );
}
