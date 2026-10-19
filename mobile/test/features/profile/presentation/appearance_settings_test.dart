import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/main.dart';
import 'package:training_app/core/router/app_router.dart';
import 'package:training_app/core/storage/appearance_storage.dart';
import 'package:training_app/core/theme/appearance_controller.dart';
import 'package:training_app/core/presentation/components/cinematic_components.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/auth/presentation/screens/login_screen.dart';
import 'package:training_app/features/learning/domain/models/assignment_detail.dart';
import 'package:training_app/features/learning/presentation/controllers/learning_controller.dart';
import 'package:training_app/features/profile/presentation/screens/profile_screen.dart';
import 'package:training_app/features/profile/presentation/widgets/appearance_settings.dart';

import '../../../core/theme/appearance_fixtures.dart';
import '../../notifications/notification_fixtures.dart';

void main() {
  late MemoryAppearanceStorage storage;
  late ProviderContainer container;
  late NotificationTestAuth auth;

  Future<void> open(WidgetTester tester) async {
    auth = NotificationTestAuth();
    container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWith(() => auth),
        appearanceStorageProvider.overrideWithValue(storage),
        assignmentDetailProvider(1).overrideWith(
          (_) async => AssignmentDetail(
            id: 1,
            trainingId: 1,
            trainingTitle: 'Working safely',
            versionNumber: 1,
            status: 'IN_PROGRESS',
            isOverdue: false,
            modules: [
              ModuleLearning(
                id: 4,
                title: 'Safety',
                description: '',
                position: 1,
                lessons: [
                  LessonLearning(
                    id: 7,
                    title: 'Read the safety guidance before starting work',
                    position: 1,
                    type: 'TEXT',
                    isRequired: true,
                    body: 'Read the instructions carefully.\n\nReport hazards before proceeding.',
                    progress: LessonProgress(
                      resumePosition: 0,
                      watchedSeconds: 0,
                      progressPercent: 100,
                      completed: true,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
    final router = container.read(appRouterProvider)..go('/profile');
    addTearDown(container.dispose);
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const MyApp()),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openAppearance(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Appearance'));
    await tester.pumpAndSettle();
  }

  Future<void> closeAppearance(WidgetTester tester) async {
    await tester.ensureVisible(find.byTooltip('Close appearance'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close appearance'));
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, String label) async {
    if (find.byType(BottomSheet).evaluate().isEmpty) {
      await openAppearance(tester);
    }
    await tester.scrollUntilVisible(
      find.text(label),
      220,
      scrollable: find
          .descendant(
            of: find.byType(BottomSheet),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  Brightness brightness(WidgetTester tester) =>
      Theme.of(tester.element(find.byType(ProfileScreen))).brightness;

  testWidgets(
    'actual app applies all three choices and System Default follows device changes',
    (tester) async {
      storage = MemoryAppearanceStorage();
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await open(tester);
      expect(brightness(tester), Brightness.dark);
      await choose(tester, 'Light Mode');
      expect(brightness(tester), Brightness.light);
      expect(
        Theme.of(tester.element(find.byType(AppearanceSettings))).brightness,
        Brightness.light,
      );
      expect(
        tester
            .widget<RadioGroup<ThemeMode>>(find.byType(RadioGroup<ThemeMode>))
            .groupValue,
        ThemeMode.light,
      );
      await choose(tester, 'Dark Mode');
      expect(brightness(tester), Brightness.dark);
      expect(
        Theme.of(tester.element(find.byType(AppearanceSettings))).brightness,
        Brightness.dark,
      );
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpAndSettle();
      expect(brightness(tester), Brightness.dark);
      await choose(tester, 'System Default');
      expect(brightness(tester), Brightness.light);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();
      expect(brightness(tester), Brightness.dark);
      expect(storage.saved, ThemeMode.system);
      expect(
        container
            .read(appRouterProvider)
            .routeInformationProvider
            .value
            .uri
            .path,
        '/profile',
      );
    },
  );

  testWidgets(
    'selected appearance restores after app recreation without carrying employee data',
    (tester) async {
      storage = MemoryAppearanceStorage();
      await open(tester);
      await choose(tester, 'Dark Mode');
      await closeAppearance(tester);
      auth.change(AuthAuthenticated(noticeEmployee('B')));
      await tester.pumpAndSettle();
      expect(find.text('A'), findsNothing);
      expect(brightness(tester), Brightness.dark);
      await tester.scrollUntilVisible(
        find.byWidgetPredicate(
          (widget) => widget is CinematicHero && widget.title == 'B',
        ),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('B'), findsWidgets);
      auth.change(AuthUnauthenticated());
      await tester.pumpAndSettle();
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.text('B'), findsNothing);
      expect(
        Theme.of(tester.element(find.byType(LoginScreen))).brightness,
        Brightness.dark,
      );
      await tester.pumpWidget(const SizedBox());
      await open(tester);
      expect(brightness(tester), Brightness.dark);
      expect(container.read(appearanceControllerProvider).mode, ThemeMode.dark);
    },
  );

  testWidgets(
    'failed persistence is visible, keeps selected theme and can be retried',
    (tester) async {
      storage = MemoryAppearanceStorage()
        ..onWrite = (_) async => throw StateError('unavailable');
      await open(tester);
      await choose(tester, 'Dark Mode');
      expect(brightness(tester), Brightness.dark);
      expect(
        find.textContaining('Your choice is active for this session.'),
        findsOneWidget,
      );
      storage.onWrite = null;
      await choose(tester, 'Retry appearance setting');
      expect(storage.saved, ThemeMode.dark);
      expect(
        find.textContaining('Your choice is active for this session.'),
        findsNothing,
      );
    },
  );

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    for (final (size, scale) in [
      (const Size(320, 640), 2.0),
      (const Size(390, 844), 1.0),
      (const Size(844, 390), 1.6),
    ]) {
      testWidgets(
        '${mode.name} profile, settings and lesson fit $size at ${scale}x',
        (tester) async {
          storage = MemoryAppearanceStorage(mode);
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          tester.platformDispatcher.accessibilityFeaturesTestValue =
              FakeAccessibilityFeatures(disableAnimations: true);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          addTearDown(
            tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
          );
          await open(tester);
          expect(
            brightness(tester),
            mode == ThemeMode.dark ? Brightness.dark : Brightness.light,
          );
          await openAppearance(tester);
          for (final label in ['System Default', 'Light Mode', 'Dark Mode']) {
            await tester.scrollUntilVisible(
              find.text(label),
              220,
              scrollable: find
                  .descendant(
                    of: find.byType(BottomSheet),
                    matching: find.byType(Scrollable),
                  )
                  .first,
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(find.text(label), findsOneWidget);
          }
          await closeAppearance(tester);
          await tester.scrollUntilVisible(
            find.text('Logout'),
            220,
            scrollable: find.byType(Scrollable).first,
          );
          expect(tester.takeException(), isNull);
          container
              .read(appRouterProvider)
              .go('/learning/assignments/1/modules/4/lessons/7/text');
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.drag(
            find.byType(Scrollable).first,
            const Offset(0, -500),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('Complete Lesson'), findsNothing);
        },
      );
    }
  }

  testWidgets(
    'header palette opens an accessible sheet and restores keyboard focus',
    (tester) async {
      storage = MemoryAppearanceStorage();
      await open(tester);
      expect(find.text('System Default'), findsNothing);
      final palette = find.byTooltip('Appearance');
      expect(tester.getSize(palette).shortestSide, greaterThanOrEqualTo(48));
      final buttonFocus = Focus.of(
        tester.element(find.byIcon(Icons.palette_outlined)),
      );
      buttonFocus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(buttonFocus.hasFocus, isFalse);
      final semantics = tester.ensureSemantics();
      expect(
        tester.getSemantics(find.text('Appearance')),
        matchesSemantics(
          isHeader: true,
          label: 'Appearance',
          textDirection: TextDirection.ltr,
        ),
      );
      semantics.dispose();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(buttonFocus.hasFocus, isTrue);
    },
  );

  testWidgets('login remains scrollable with large text and keyboard visible', (
    tester,
  ) async {
    storage = MemoryAppearanceStorage(ThemeMode.dark);
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await open(tester);
    auth.change(AuthUnauthenticated());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final button = find.widgetWithText(ElevatedButton, 'Login');
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('Please enter your employee code'), findsOneWidget);
    expect(find.text('Please enter your password'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
