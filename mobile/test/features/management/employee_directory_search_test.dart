import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/theme/app_theme.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/authenticated_identity.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/data/repositories/management_repository.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';
import 'package:training_app/features/management/presentation/screens/organization_screens.dart';

import 'management_fixtures.dart';

class _DirectoryRepository extends Mock implements ManagementRepository {}

class _DirectoryAuth extends AuthController {
  final AuthenticatedIdentity identity;
  _DirectoryAuth(this.identity);

  @override
  AuthState build() => AuthAuthenticated.identity(identity);

  void setAuth(AuthState auth) => state = auth;
}

typedef _CapturedRequest = ({
  int page,
  String? search,
  int? departmentId,
  int? jobRoleId,
  bool? isActive,
});

void main() {
  late _DirectoryRepository repository;
  late ProviderContainer container;
  late _DirectoryAuth auth;
  late List<_CapturedRequest> requests;
  late Future<ManagementPage<DirectoryEmployee>> Function(Map<Symbol, dynamic>)
  response;

  _CapturedRequest captureRequest(Invocation invocation) {
    final args = invocation.namedArguments;
    final request = (
      page: args[#page] as int,
      search: args[#search] as String?,
      departmentId: args[#departmentId] as int?,
      jobRoleId: args[#jobRoleId] as int?,
      isActive: args[#isActive] as bool?,
    );
    requests.add(request);
    return request;
  }

  Future<void> mount(
    WidgetTester tester, {
    Set<String>? capabilities,
    ThemeMode themeMode = ThemeMode.light,
  }) async {
    auth = _DirectoryAuth(managementIdentity(capabilities: capabilities));
    container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWith(() => auth),
        managementRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: themeMode,
          home: const OrganizationListScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  final searchField = find.byWidgetPredicate(
    (widget) =>
        widget is TextField &&
        widget.decoration?.labelText == 'Search employees',
  );

  Future<void> tapFilter(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 100));
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  setUpAll(() {
    registerFallbackValue(CancelToken());
    registerFallbackValue(ReferenceKind.departments);
  });
  setUp(() {
    repository = _DirectoryRepository();
    requests = [];
    response = (_) async => employeePage();
    when(
      () => repository.employees(
        page: any(named: 'page'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((invocation) {
      captureRequest(invocation);
      return response(invocation.namedArguments);
    });
    when(
      () => repository.employees(
        page: any(named: 'page'),
        search: any(named: 'search'),
        departmentId: any(named: 'departmentId'),
        jobRoleId: any(named: 'jobRoleId'),
        isActive: any(named: 'isActive'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((invocation) {
      captureRequest(invocation);
      return response(invocation.namedArguments);
    });
    when(
      () => repository.allReferences(
        any(),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((invocation) async {
      final kind = invocation.positionalArguments.single as ReferenceKind;
      return [
        OrganizationReference(
          id: kind == ReferenceKind.departments ? 10 : 20,
          code: kind == ReferenceKind.departments ? 'PACK' : 'PACKER',
          name: kind == ReferenceKind.departments
              ? 'Packing department'
              : 'Packer role',
        ),
      ];
    });
  });

  testWidgets('shows loading feedback while the directory request is pending', (
    tester,
  ) async {
    final pending = Completer<ManagementPage<DirectoryEmployee>>();
    response = (_) => pending.future;
    await mount(tester);

    expect(find.text('Loading employees'), findsOneWidget);

    pending.complete(employeePage());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'search keeps focus cursor and keyboard across debounced loading',
    (tester) async {
      await mount(tester, capabilities: {'organization.view_employee'});
      final pending = Completer<ManagementPage<DirectoryEmployee>>();
      response = (_) => pending.future;
      addTearDown(() {
        if (!pending.isCompleted) pending.complete(employeePage());
      });

      await tester.enterText(searchField, 'Taylor');
      final controller = tester.widget<TextField>(searchField).controller!;
      const selection = TextSelection.collapsed(offset: 2);
      controller.selection = selection;
      await tester.pump();
      final editable = find.descendant(
        of: searchField,
        matching: find.byType(EditableText),
      );
      final originalState = tester.state<EditableTextState>(editable);
      final focus = originalState.widget.focusNode;
      final before = requests.length;
      expect(focus.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);

      await tester.pump(const Duration(milliseconds: 349));
      expect(requests, hasLength(before));
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(requests.last.search, 'Taylor');
      expect(find.text('Loading employees'), findsOneWidget);
      expect(originalState.mounted, isTrue);
      expect(editable, findsOneWidget);
      expect(tester.state<EditableTextState>(editable), same(originalState));
      expect(focus.hasFocus, isTrue);
      expect(tester.testTextInput.hasAnyClients, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      expect(controller.text, 'Taylor');
      expect(controller.selection, selection);

      pending.complete(employeePage());
      await tester.pumpAndSettle();
      expect(tester.state<EditableTextState>(editable), same(originalState));
      expect(focus.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      expect(controller.text, 'Taylor');
      expect(controller.selection, selection);
    },
  );

  testWidgets('search is debounced and combines server-side filters', (
    tester,
  ) async {
    await mount(tester);
    final initialCalls = requests.length;
    await tester.enterText(searchField, '  Taylor  ');
    await tester.pump(const Duration(milliseconds: 349));
    expect(requests, hasLength(initialCalls));

    await tester.pump(const Duration(milliseconds: 1));
    await tester.pumpAndSettle();
    expect(requests.last.search, 'Taylor');
    expect(requests.last.page, 1);

    await tapFilter(tester, find.byType(DropdownButtonFormField<int>).at(0));
    await tester.tap(find.text('Packing department').last);
    await tester.pumpAndSettle();
    await tapFilter(tester, find.byType(DropdownButtonFormField<int>).at(1));
    await tester.tap(find.text('Packer role').last);
    await tester.pumpAndSettle();
    await tapFilter(tester, find.byType(DropdownButtonFormField<String>));
    await tester.tap(find.text('Inactive').last);
    await tester.pumpAndSettle();

    expect(requests.last, (
      page: 1,
      search: 'Taylor',
      departmentId: 10,
      jobRoleId: 20,
      isActive: false,
    ));
  });

  testWidgets(
    'changing search resets pagination and Clear Filters clears all',
    (tester) async {
      response = (_) async => employeePage(more: true);
      await mount(tester);

      final nextPage = find.text('Next page');
      await tester.scrollUntilVisible(
        nextPage,
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(nextPage);
      await tester.pumpAndSettle();
      expect(find.text('Page 2'), findsOneWidget);
      expect(requests.last.page, 2);

      await tester.ensureVisible(searchField);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 100));
      await tester.pumpAndSettle();
      await tester.enterText(searchField, 'Morgan');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(requests.last.page, 1);
      expect(requests.last.search, 'Morgan');
      await tester.scrollUntilVisible(
        find.text('Page 1'),
        180,
        scrollable: find.byType(Scrollable).first,
      );

      await tapFilter(tester, find.byType(DropdownButtonFormField<int>).at(0));
      await tester.tap(find.text('Packing department').last);
      await tester.pumpAndSettle();
      await tapFilter(tester, find.byType(DropdownButtonFormField<int>).at(1));
      await tester.tap(find.text('Packer role').last);
      await tester.pumpAndSettle();
      await tapFilter(tester, find.byType(DropdownButtonFormField<String>));
      await tester.tap(find.text('Inactive').last);
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Clear filters').first);
      await tester.tap(find.text('Clear filters').first);
      await tester.pumpAndSettle();

      expect(tester.widget<TextField>(searchField).controller!.text, isEmpty);
      expect(find.text('All departments'), findsOneWidget);
      expect(find.text('All job roles'), findsOneWidget);
      expect(find.text('All employees'), findsOneWidget);
      expect(requests.last, (
        page: 1,
        search: null,
        departmentId: null,
        jobRoleId: null,
        isActive: null,
      ));
    },
  );

  testWidgets('empty and error results remain recoverable', (tester) async {
    response = (_) async => ManagementPage(
      items: const <DirectoryEmployee>[],
      count: 0,
      hasMore: false,
    );
    await mount(tester);
    expect(find.text('No records to display.'), findsOneWidget);
    expect(searchField, findsOneWidget);

    final pendingError = Completer<ManagementPage<DirectoryEmployee>>();
    response = (_) => pendingError.future;
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pump();
    expect(find.text('Loading employees'), findsOneWidget);
    pendingError.completeError(ApiError.networkFailure());
    await tester.pumpAndSettle();
    expect(find.text('Connection unavailable'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    response = (_) async => employeePage(name: 'Recovered employee');
    await tester.ensureVisible(find.text('Retry'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Recovered employee'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Recovered employee'), findsOneWidget);
    expect(find.text('Connection unavailable'), findsNothing);
  });

  testWidgets('late responses from an older search cannot replace newer data', (
    tester,
  ) async {
    final oldResponse = Completer<ManagementPage<DirectoryEmployee>>();
    final newResponse = Completer<ManagementPage<DirectoryEmployee>>();
    response = (args) {
      return args[#search] == 'Old query'
          ? oldResponse.future
          : args[#search] == 'New query'
          ? newResponse.future
          : Future.value(employeePage());
    };
    await mount(tester);

    await tester.scrollUntilVisible(
      searchField,
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(searchField, 'Old query');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(requests.last.search, 'Old query');

    await tester.enterText(searchField, 'New query');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(requests.last.search, 'New query');

    newResponse.complete(employeePage(name: 'New search result'));
    await tester.pumpAndSettle();
    oldResponse.complete(employeePage(name: 'Old search result'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('New search result'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('New search result'), findsOneWidget);
    expect(find.text('Old search result'), findsNothing);
  });

  testWidgets('a pending refresh cannot block newer search results', (
    tester,
  ) async {
    await mount(tester);
    final oldRefresh = Completer<ManagementPage<DirectoryEmployee>>();
    addTearDown(() {
      if (!oldRefresh.isCompleted) oldRefresh.complete(employeePage());
    });
    response = (args) => args[#search] == 'New criteria'
        ? Future.value(employeePage(name: 'Newer criteria result'))
        : oldRefresh.future;

    await tester.tap(find.byTooltip('Refresh'));
    await tester.pump();
    expect(find.text('Loading employees'), findsOneWidget);
    await tester.scrollUntilVisible(
      searchField,
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(searchField, 'New criteria');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Newer criteria result'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Newer criteria result'), findsOneWidget);
    expect(find.text('Loading employees'), findsNothing);

    oldRefresh.complete(employeePage(name: 'Outdated refresh result'));
    await tester.pumpAndSettle();
    expect(find.text('Newer criteria result'), findsOneWidget);
    expect(find.text('Outdated refresh result'), findsNothing);
  });

  testWidgets(
    'logout and account switching clear criteria and pending debounce',
    (tester) async {
      await mount(tester);
      await tapFilter(tester, find.byType(DropdownButtonFormField<int>).at(0));
      await tester.tap(find.text('Packing department').last);
      await tester.pumpAndSettle();
      await tapFilter(tester, find.byType(DropdownButtonFormField<String>));
      await tester.tap(find.text('Inactive').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(searchField);
      await tester.enterText(searchField, 'Previous account pending search');

      auth.setAuth(AuthUnauthenticated());
      await tester.pump();
      auth.setAuth(
        AuthAuthenticated.identity(managementIdentity(username: 'second')),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(tester.widget<TextField>(searchField).controller!.text, isEmpty);
      expect(find.text('All departments'), findsOneWidget);
      expect(find.text('All job roles'), findsOneWidget);
      expect(find.text('All employees'), findsOneWidget);
      expect(requests.last, (
        page: 1,
        search: null,
        departmentId: null,
        jobRoleId: null,
        isActive: null,
      ));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('disposing the directory cancels pending search debounce', (
    tester,
  ) async {
    await mount(tester);
    final before = requests.length;
    await tester.enterText(searchField, 'Never dispatched');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 350));
    expect(requests, hasLength(before));
    expect(tester.takeException(), isNull);
  });

  testWidgets('directory-only capability does not request reference lists', (
    tester,
  ) async {
    await mount(tester, capabilities: {'organization.view_employee'});
    expect(searchField, findsOneWidget);
    expect(find.byType(DropdownButtonFormField<int>), findsNothing);
    verifyNever(
      () => repository.allReferences(
        any(),
        cancelToken: any(named: 'cancelToken'),
      ),
    );
    await tester.enterText(searchField, 'EMP1');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(requests.last.search, 'EMP1');
  });

  testWidgets('employee directory visibility remains capability-gated', (
    tester,
  ) async {
    await mount(tester, capabilities: {});

    expect(searchField, findsNothing);
    expect(find.text('Employees'), findsNothing);
    expect(requests, isEmpty);
  });

  testWidgets('directory respects Light, Dark and System theme brightness', (
    tester,
  ) async {
    for (final (mode, platform, expected) in [
      (ThemeMode.light, Brightness.dark, Brightness.light),
      (ThemeMode.dark, Brightness.light, Brightness.dark),
      (ThemeMode.system, Brightness.dark, Brightness.dark),
    ]) {
      tester.platformDispatcher.platformBrightnessTestValue = platform;
      await mount(tester, themeMode: mode);
      expect(
        Theme.of(tester.element(find.byType(OrganizationListScreen)))
            .brightness,
        expected,
      );
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
  });
}
