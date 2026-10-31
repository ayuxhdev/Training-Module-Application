import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/router/app_router.dart';
import 'package:training_app/core/theme/app_theme.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/authenticated_identity.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/data/repositories/management_repository.dart';
import 'package:training_app/features/management/data/services/video_file_picker.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';
import 'package:training_app/features/notifications/presentation/controllers/notification_controller.dart';

import 'management_fixtures.dart';

class MockManagementRepository extends Mock implements ManagementRepository {}

class MockVideoFilePicker extends Mock implements VideoFilePicker {}

class DeletionTrackedVideoFile extends SelectedVideoFile {
  int deleteCalls = 0;

  DeletionTrackedVideoFile(String path)
    : super(path: path, name: 'late-copy.mp4', sizeInBytes: 3);

  @override
  Future<void> delete() {
    deleteCalls++;
    return super.delete();
  }
}

class ZeroUnread extends NotificationUnreadController {
  @override
  Future<int?> build() async => 0;
}

void main() {
  late MockManagementRepository repository;
  late MockVideoFilePicker picker;
  late ManagementTestAuth auth;
  late GoRouter router;

  setUpAll(() {
    registerFallbackValue(ReferenceKind.departments);
    registerFallbackValue(
      const SelectedVideoFile(path: '', name: '', sizeInBytes: 0),
    );
  });

  setUp(() {
    repository = MockManagementRepository();
    picker = MockVideoFilePicker();

    when(
      () => repository.versionDetail(
        any(),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) async => ManagedVersionDetail.fromJson(
        managedVersionDetailJson(
          id: 20,
          trainingId: 1,
          versionNumber: 2,
          title: 'Workplace Safety v2',
          status: 'DRAFT',
        ),
      ),
    );

    when(
      () => repository.videoLessonDetail(
        any(),
        any(),
        any(),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) async => ManagedVideoLessonDetail.fromJson(
        managedVideoLessonDetailJson(
          id: 94,
          moduleId: 51,
          trainingVersionId: 20,
          title: 'Equipment Inspection',
          position: 2,
          isRequired: true,
          minimumWatchPercent: '90.00',
          videoDurationSeconds: 69,
          hasVideo: true,
        ),
      ),
    );

    when(() => picker.pickVideo()).thenAnswer(
      (_) async => SelectedVideoFile(
        path: '/tmp/test.mp4',
        name: 'test.mp4',
        sizeInBytes: 1024 * 1024,
        mimeType: 'video/mp4',
        multipartFileFactory: () =>
            MultipartFile.fromBytes([0, 1, 2, 3], filename: 'test.mp4'),
      ),
    );

    when(() => picker.clearCache()).thenAnswer((_) async {});
  });

  Future<ProviderContainer> launch(
    WidgetTester tester, {
    AuthenticatedIdentity? identity,
    String path =
        '/workspace/training/versions/20/modules/51/video-lessons/new',
    ThemeMode themeMode = ThemeMode.light,
    Size size = const Size(800, 2400),
    double textScale = 1.0,
    Object? extra,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    auth = ManagementTestAuth(
      identity ??
          managementIdentity(
            capabilities: {
              'management_workspace',
              'training.view_training',
              'training.view_trainingversion',
              'training.view_module',
              'training.add_lesson',
              'training.view_lesson',
              'training.change_lesson',
            },
          ),
    );

    final container = ProviderContainer(
      overrides: [
        managementRepositoryProvider.overrideWithValue(repository),
        authControllerProvider.overrideWith(() => auth),
        notificationUnreadCountProvider.overrideWith(ZeroUnread.new),
        videoFilePickerProvider.overrideWithValue(picker),
      ],
    );

    router = container.read(appRouterProvider);
    if (extra != null) {
      router.go(path, extra: extra);
    } else {
      router.go(path);
    }

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(textScale),
          ),
          child: MaterialApp.router(
            routerConfig: router,
            theme: AppTheme.lightTheme,
            darkTheme: AppTheme.darkTheme,
            themeMode: themeMode,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  group('VideoLessonFormScreen - Creation Workflow', () {
    testWidgets('renders creation form with all required fields and picker', (
      tester,
    ) async {
      await launch(tester);

      expect(find.text('New video lesson'), findsOneWidget);
      expect(find.text('Create Video Lesson'), findsOneWidget);
      expect(find.text('Video Lesson Details'), findsOneWidget);
      expect(find.text('Lesson Title *'), findsOneWidget);
      expect(find.text('Position *'), findsOneWidget);
      expect(find.text('Minimum Watch Percentage (%) *'), findsOneWidget);
      expect(find.text('Required Lesson'), findsOneWidget);
      expect(find.text('Choose Video File'), findsOneWidget);
      expect(find.text('MP4 / WEBM / MOV'), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(
              find.widgetWithText(
                TextFormField,
                'Minimum Watch Percentage (%) *',
              ),
            )
            .controller!
            .text,
        '90.00',
      ); // default watch percent
      expect(
        tester
            .widget<TextFormField>(
              find.widgetWithText(TextFormField, 'Position *'),
            )
            .controller!
            .text,
        '1',
      );
    });

    testWidgets(
      'client-side validation requires title, position, and video file',
      (tester) async {
        await launch(tester);

        // Clear position
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Position *'),
          '',
        );
        await tester.tap(
          find.widgetWithText(FilledButton, 'Create Video Lesson'),
        );
        await tester.pumpAndSettle();

        expect(find.text('Lesson title is required.'), findsOneWidget);
        expect(find.text('Position is required.'), findsOneWidget);
        expect(
          find.text('Choose a video file for this lesson.'),
          findsOneWidget,
        );
        verifyZeroInteractions(repository);
      },
    );

    testWidgets(
      'selecting a valid video file displays name, size, and clear action',
      (tester) async {
        await launch(tester);

        await tester.tap(find.text('Choose Video File'));
        await tester.pumpAndSettle();

        expect(find.text('test.mp4'), findsOneWidget);
        expect(find.text('1.0 MB'), findsOneWidget);
        expect(find.byTooltip('Remove file'), findsOneWidget);
        expect(find.text('Change file'), findsOneWidget);

        // Tapping remove clears selected file
        await tester.tap(find.byTooltip('Remove file'));
        await tester.pumpAndSettle();

        expect(find.text('test.mp4'), findsNothing);
        expect(find.text('Choose Video File'), findsOneWidget);
        verify(() => picker.clearCache()).called(1);
      },
    );

    testWidgets(
      'submits form with valid data and calls repository createVideoLesson',
      (tester) async {
        when(
          () => repository.createVideoLesson(
            20,
            51,
            title: 'Equipment Safety',
            position: 1,
            videoFile: any(named: 'videoFile'),
            isRequired: true,
            minimumWatchPercent: 90.0,
            onSendProgress: any(named: 'onSendProgress'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagedVideoLessonDetail.fromJson(
            managedVideoLessonDetailJson(
              id: 94,
              moduleId: 51,
              trainingVersionId: 20,
              title: 'Equipment Safety',
              position: 1,
            ),
          ),
        );

        await launch(tester);

        await tester.enterText(
          find.widgetWithText(TextFormField, 'Lesson Title *'),
          'Equipment Safety',
        );
        await tester.tap(find.text('Choose Video File'));
        await tester.pumpAndSettle();

        await tester.tap(
          find.widgetWithText(FilledButton, 'Create Video Lesson'),
        );
        await tester.pumpAndSettle();

        verify(
          () => repository.createVideoLesson(
            20,
            51,
            title: 'Equipment Safety',
            position: 1,
            videoFile: any(named: 'videoFile'),
            isRequired: true,
            minimumWatchPercent: 90.0,
            onSendProgress: any(named: 'onSendProgress'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).called(1);

        expect(
          find.text('Video lesson "Equipment Safety" created successfully.'),
          findsOneWidget,
        );
        verify(() => picker.clearCache()).called(1);
      },
    );

    testWidgets('stepper increments and decrements position', (tester) async {
      await launch(tester);

      String currentPos() => tester
          .widget<TextFormField>(
            find.widgetWithText(TextFormField, 'Position *'),
          )
          .controller!
          .text;

      expect(currentPos(), '1');

      await tester.tap(find.byTooltip('Increase position'));
      await tester.pumpAndSettle();
      expect(currentPos(), '2');

      await tester.tap(find.byTooltip('Increase position'));
      await tester.pumpAndSettle();
      expect(currentPos(), '3');

      await tester.tap(find.byTooltip('Decrease position'));
      await tester.pumpAndSettle();
      expect(currentPos(), '2');

      await tester.tap(find.byTooltip('Decrease position'));
      await tester.pumpAndSettle();
      expect(currentPos(), '1');

      // Decreasing at 1 stays at 1
      await tester.tap(find.byTooltip('Decrease position'));
      await tester.pumpAndSettle();
      expect(currentPos(), '1');
    });

    testWidgets('honors suggested position from module extra', (tester) async {
      final module = ManagedModule(
        id: 51,
        title: 'Safety',
        order: 1,
        lessons: [
          const ManagedLessonSummary(
            id: 1,
            title: 'L1',
            lessonType: 'VIDEO',
            order: 3,
          ),
        ],
      );

      await launch(tester, extra: module);

      expect(find.text('4'), findsOneWidget);
    });
  });

  group('VideoLessonFormScreen - File Validation and Error Handling', () {
    testWidgets('rejects empty video file with client validation error', (
      tester,
    ) async {
      when(() => picker.pickVideo()).thenAnswer(
        (_) async => const SelectedVideoFile(
          path: '/tmp/empty.mp4',
          name: 'empty.mp4',
          sizeInBytes: 0,
        ),
      );

      await launch(tester);
      await tester.tap(find.text('Choose Video File'));
      await tester.pumpAndSettle();

      expect(
        find.text('Video file is empty. Please select a valid video.'),
        findsOneWidget,
      );
      expect(find.text('empty.mp4'), findsNothing);
    });

    testWidgets('rejects oversized video file exceeding 2 GB', (tester) async {
      when(() => picker.pickVideo()).thenAnswer(
        (_) async => const SelectedVideoFile(
          path: '/tmp/huge.mp4',
          name: 'huge.mp4',
          sizeInBytes: 3 * 1024 * 1024 * 1024, // 3 GB
        ),
      );

      await launch(tester);
      await tester.tap(find.text('Choose Video File'));
      await tester.pumpAndSettle();

      expect(
        find.text('Video file exceeds the 2 GB maximum size limit.'),
        findsOneWidget,
      );
      expect(find.text('huge.mp4'), findsNothing);
    });

    testWidgets('rejects unsupported file extensions', (tester) async {
      when(() => picker.pickVideo()).thenAnswer(
        (_) async => const SelectedVideoFile(
          path: '/tmp/malware.exe',
          name: 'malware.exe',
          sizeInBytes: 1024,
        ),
      );

      await launch(tester);
      await tester.tap(find.text('Choose Video File'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Unsupported video format. Allowed formats are MP4, WebM, and MOV.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('accepts valid WebM and MOV formats', (tester) async {
      when(() => picker.pickVideo()).thenAnswer(
        (_) async => const SelectedVideoFile(
          path: '/tmp/intro.webm',
          name: 'intro.webm',
          sizeInBytes: 2 * 1024 * 1024,
        ),
      );

      await launch(tester);
      await tester.tap(find.text('Choose Video File'));
      await tester.pumpAndSettle();

      expect(find.text('intro.webm'), findsOneWidget);
      expect(find.text('2.0 MB'), findsOneWidget);
    });

    testWidgets('picker cancellation does not disturb form state', (
      tester,
    ) async {
      when(() => picker.pickVideo()).thenAnswer((_) async => null);

      await launch(tester);
      await tester.tap(find.text('Choose Video File'));
      await tester.pumpAndSettle();

      expect(find.text('Choose Video File'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets(
      'late picker result after disposal deletes only its temporary file exactly once',
      (tester) async {
        final directory = Directory.systemTemp.createTempSync(
          'video_late_pick_',
        );
        addTearDown(() => directory.deleteSync(recursive: true));
        final source = File('${directory.path}/original.mp4')
          ..writeAsStringSync('original video');
        final otherActiveFile = File('${directory.path}/other-active.mp4')
          ..writeAsStringSync('another operation');
        final returnedFile = File('${directory.path}/late-copy.mp4')
          ..writeAsBytesSync([1, 2, 3]);
        final selected = DeletionTrackedVideoFile(returnedFile.path);
        final pending = Completer<SelectedVideoFile?>();
        when(() => picker.pickVideo()).thenAnswer((_) => pending.future);

        final container = await launch(tester);
        addTearDown(container.dispose);
        clearInteractions(repository);
        await tester.tap(find.text('Choose Video File'));
        await tester.pump();
        verify(() => picker.pickVideo()).called(1);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        expect(selected.deleteCalls, 0);
        expect(returnedFile.existsSync(), isTrue);

        pending.complete(selected);
        await tester.pumpAndSettle();

        expect(returnedFile.existsSync(), isFalse);
        expect(selected.deleteCalls, 1);
        expect(source.readAsStringSync(), 'original video');
        expect(otherActiveFile.readAsStringSync(), 'another operation');
        verifyNever(() => picker.clearCache());
        verifyZeroInteractions(repository);
        expect(tester.takeException(), isNull);
        await tester.pump();
        expect(selected.deleteCalls, 1);
      },
    );

    testWidgets('displays error when native picker throws ApiError', (
      tester,
    ) async {
      when(() => picker.pickVideo()).thenThrow(
        ApiError(
          message: 'Native video picker failed to stream file.',
          statusCode: 400,
        ),
      );

      await launch(tester);
      await tester.tap(find.text('Choose Video File'));
      await tester.pumpAndSettle();

      expect(
        find.text('Native video picker failed to stream file.'),
        findsOneWidget,
      );
    });

    testWidgets('clears cache when discard dialog confirms', (tester) async {
      await launch(tester);
      await tester.tap(find.text('Choose Video File'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Discard unsaved changes?'), findsOneWidget);
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();

      verify(() => picker.clearCache()).called(greaterThanOrEqualTo(1));
    });

    testWidgets(
      'change file followed by cancellation preserves original selection and uses it on submit',
      (tester) async {
        SelectedVideoFile? submittedFile;
        when(
          () => repository.createVideoLesson(
            20,
            51,
            title: 'Preserve Selection',
            position: 1,
            videoFile: any(named: 'videoFile'),
            isRequired: true,
            minimumWatchPercent: 90.0,
            onSendProgress: any(named: 'onSendProgress'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((invocation) {
          submittedFile =
              invocation.namedArguments[#videoFile] as SelectedVideoFile?;
          return Future.value(
            ManagedVideoLessonDetail.fromJson(
              managedVideoLessonDetailJson(
                id: 201,
                title: 'Preserve Selection',
              ),
            ),
          );
        });

        await launch(tester);
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Lesson Title *'),
          'Preserve Selection',
        );

        // Initial selection: test.mp4
        await tester.tap(find.text('Choose Video File'));
        await tester.pumpAndSettle();
        expect(find.text('test.mp4'), findsOneWidget);
        expect(find.text('Change file'), findsOneWidget);

        // Tap Change file, but user cancels native picker
        when(() => picker.pickVideo()).thenAnswer((_) async => null);
        await tester.tap(find.text('Change file'));
        await tester.pumpAndSettle();

        // Original selection is preserved
        expect(find.text('test.mp4'), findsOneWidget);
        expect(find.text('Change file'), findsOneWidget);

        // Submit form
        await tester.ensureVisible(
          find.widgetWithText(FilledButton, 'Create Video Lesson'),
        );
        await tester.tap(
          find.widgetWithText(FilledButton, 'Create Video Lesson'),
        );
        await tester.pumpAndSettle();

        // Verify upload used the original file
        expect(submittedFile, isNotNull);
        expect(submittedFile!.name, 'test.mp4');
        expect(
          find.text('Video lesson "Preserve Selection" created successfully.'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'successful replacement deletes old file and assigns new file',
      (tester) async {
        final tempDir = Directory.systemTemp.createTempSync('video_rep_');
        final firstFile = File('${tempDir.path}/first.mp4');
        firstFile.writeAsStringSync('first video');
        final secondFile = File('${tempDir.path}/second.mp4');
        secondFile.writeAsStringSync('second video');

        try {
          when(() => picker.pickVideo()).thenAnswer(
            (_) async => SelectedVideoFile(
              path: firstFile.path,
              name: 'first.mp4',
              sizeInBytes: 11,
            ),
          );

          await launch(tester);
          await tester.tap(find.text('Choose Video File'));
          await tester.pumpAndSettle();
          expect(find.text('first.mp4'), findsOneWidget);
          expect(firstFile.existsSync(), isTrue);

          // Now pick replacement
          when(() => picker.pickVideo()).thenAnswer(
            (_) async => SelectedVideoFile(
              path: secondFile.path,
              name: 'second.mp4',
              sizeInBytes: 12,
            ),
          );

          await tester.tap(find.text('Change file'));
          await tester.pumpAndSettle();

          // New file is displayed
          expect(find.text('second.mp4'), findsOneWidget);
          expect(find.text('first.mp4'), findsNothing);

          // Old file was safely deleted
          expect(firstFile.existsSync(), isFalse);
          // New file remains intact
          expect(secondFile.existsSync(), isTrue);
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      },
    );

    testWidgets(
      'failed replacement preserves original file and deletes rejected temporary file',
      (tester) async {
        final tempDir = Directory.systemTemp.createTempSync('video_fail_rep_');
        final validFile = File('${tempDir.path}/valid.mp4');
        validFile.writeAsStringSync('valid video data');
        final oversizedFile = File('${tempDir.path}/oversized.mp4');
        oversizedFile.writeAsStringSync('oversized data');

        try {
          when(() => picker.pickVideo()).thenAnswer(
            (_) async => SelectedVideoFile(
              path: validFile.path,
              name: 'valid.mp4',
              sizeInBytes: 16,
            ),
          );

          await launch(tester);
          await tester.tap(find.text('Choose Video File'));
          await tester.pumpAndSettle();
          expect(find.text('valid.mp4'), findsOneWidget);
          expect(validFile.existsSync(), isTrue);

          // Now attempt to pick oversized file (> 2 GB)
          when(() => picker.pickVideo()).thenAnswer(
            (_) async => SelectedVideoFile(
              path: oversizedFile.path,
              name: 'oversized.mp4',
              sizeInBytes: 3 * 1024 * 1024 * 1024,
            ),
          );

          await tester.tap(find.text('Change file'));
          await tester.pumpAndSettle();

          // Validation error shown
          expect(
            find.text('Video file exceeds the 2 GB maximum size limit.'),
            findsOneWidget,
          );
          // Original file remains selected in UI
          expect(find.text('valid.mp4'), findsOneWidget);
          // Original file is still on disk
          expect(validFile.existsSync(), isTrue);
          // Rejected oversized file was deleted from disk
          expect(oversizedFile.existsSync(), isFalse);
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      },
    );

    testWidgets(
      'initial invalid file selection deletes rejected temporary file',
      (tester) async {
        final tempDir = Directory.systemTemp.createTempSync('video_init_rej_');
        final badFormatFile = File('${tempDir.path}/script.sh');
        badFormatFile.writeAsStringSync('malicious script');

        try {
          when(() => picker.pickVideo()).thenAnswer(
            (_) async => SelectedVideoFile(
              path: badFormatFile.path,
              name: 'script.sh',
              sizeInBytes: 16,
            ),
          );

          await launch(tester);
          await tester.tap(find.text('Choose Video File'));
          await tester.pumpAndSettle();

          expect(
            find.text(
              'Unsupported video format. Allowed formats are MP4, WebM, and MOV.',
            ),
            findsOneWidget,
          );
          expect(find.text('Choose Video File'), findsOneWidget);
          // Rejected file was deleted
          expect(badFormatFile.existsSync(), isFalse);
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      },
    );

    testWidgets(
      'repeated replacements clean previous temporary files without abandoning them',
      (tester) async {
        final tempDir = Directory.systemTemp.createTempSync('video_rep_chain_');
        final file1 = File('${tempDir.path}/v1.mp4');
        file1.writeAsStringSync('video 1');
        final file2 = File('${tempDir.path}/v2.mp4');
        file2.writeAsStringSync('video 2');
        final file3 = File('${tempDir.path}/v3.mp4');
        file3.writeAsStringSync('video 3');

        try {
          // Select v1
          when(() => picker.pickVideo()).thenAnswer(
            (_) async => SelectedVideoFile(
              path: file1.path,
              name: 'v1.mp4',
              sizeInBytes: 7,
            ),
          );
          await launch(tester);
          await tester.tap(find.text('Choose Video File'));
          await tester.pumpAndSettle();
          expect(find.text('v1.mp4'), findsOneWidget);

          // Replace with v2
          when(() => picker.pickVideo()).thenAnswer(
            (_) async => SelectedVideoFile(
              path: file2.path,
              name: 'v2.mp4',
              sizeInBytes: 7,
            ),
          );
          await tester.tap(find.text('Change file'));
          await tester.pumpAndSettle();
          expect(find.text('v2.mp4'), findsOneWidget);
          expect(file1.existsSync(), isFalse);
          expect(file2.existsSync(), isTrue);

          // Replace with v3
          when(() => picker.pickVideo()).thenAnswer(
            (_) async => SelectedVideoFile(
              path: file3.path,
              name: 'v3.mp4',
              sizeInBytes: 7,
            ),
          );
          await tester.tap(find.text('Change file'));
          await tester.pumpAndSettle();
          expect(find.text('v3.mp4'), findsOneWidget);
          expect(file1.existsSync(), isFalse);
          expect(file2.existsSync(), isFalse);
          expect(file3.existsSync(), isTrue);
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      },
    );
  });

  group('VideoLessonFormScreen - Upload Progress & Cancellation', () {
    testWidgets(
      'cancel upload triggers cancelToken, clears selected file, and prevents reusing deleted file',
      (tester) async {
        final completer = Completer<ManagedVideoLessonDetail>();
        when(
          () => repository.createVideoLesson(
            20,
            51,
            title: 'Long Video',
            position: 1,
            videoFile: any(named: 'videoFile'),
            isRequired: true,
            minimumWatchPercent: 90.0,
            onSendProgress: any(named: 'onSendProgress'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((invocation) {
          final progress =
              invocation.namedArguments[#onSendProgress] as ProgressCallback?;
          progress?.call(500, 1000);
          return completer.future;
        });

        await launch(tester);
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Lesson Title *'),
          'Long Video',
        );
        await tester.tap(find.text('Choose Video File'));
        await tester.pumpAndSettle();

        await tester.tap(
          find.widgetWithText(FilledButton, 'Create Video Lesson'),
        );
        await tester.pump();

        expect(find.text('Uploading video... 50%'), findsOneWidget);
        expect(find.text('Cancel Upload'), findsOneWidget);

        await tester.tap(find.text('Cancel Upload'));
        await tester.pumpAndSettle();

        expect(find.text('Upload cancelled.'), findsOneWidget);
        expect(find.text('Uploading video... 50%'), findsNothing);
        expect(
          find.widgetWithText(FilledButton, 'Create Video Lesson'),
          findsOneWidget,
        );

        // Finding 1 Verification: Selected file is cleared, UI reverts to Choose Video File
        expect(find.text('test.mp4'), findsNothing);
        expect(find.text('Choose Video File'), findsOneWidget);

        // Finding 1 Verification: Submitting without selecting another file fails client validation
        await tester.tap(
          find.widgetWithText(FilledButton, 'Create Video Lesson'),
        );
        await tester.pumpAndSettle();
        expect(
          find.text('Choose a video file for this lesson.'),
          findsOneWidget,
        );

        // Finding 1 Verification: Late completion of the cancelled request cannot show false success
        completer.complete(
          ManagedVideoLessonDetail.fromJson(
            managedVideoLessonDetailJson(id: 99, title: 'Long Video'),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text('Video lesson "Long Video" created successfully.'),
          findsNothing,
        );
        expect(find.text('New video lesson'), findsOneWidget);
      },
    );

    testWidgets(
      'cancelling active upload allows selecting a new file and submitting successfully',
      (tester) async {
        final completer = Completer<ManagedVideoLessonDetail>();
        when(
          () => repository.createVideoLesson(
            20,
            51,
            title: 'Resubmitted Video',
            position: 1,
            videoFile: any(named: 'videoFile'),
            isRequired: true,
            minimumWatchPercent: 90.0,
            onSendProgress: any(named: 'onSendProgress'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((invocation) {
          final progress =
              invocation.namedArguments[#onSendProgress] as ProgressCallback?;
          progress?.call(300, 1000);
          return completer.future;
        });

        await launch(tester);
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Lesson Title *'),
          'Resubmitted Video',
        );
        await tester.tap(find.text('Choose Video File'));
        await tester.pumpAndSettle();

        await tester.tap(
          find.widgetWithText(FilledButton, 'Create Video Lesson'),
        );
        await tester.pump();

        expect(find.text('Uploading video... 30%'), findsOneWidget);
        await tester.tap(find.text('Cancel Upload'));
        await tester.pumpAndSettle();

        expect(find.text('Upload cancelled.'), findsOneWidget);
        expect(find.text('Choose Video File'), findsOneWidget);

        // Pick new file
        when(() => picker.pickVideo()).thenAnswer(
          (_) async => SelectedVideoFile(
            path: '/tmp/second_take.mp4',
            name: 'second_take.mp4',
            sizeInBytes: 5 * 1024 * 1024,
            multipartFileFactory: () =>
                MultipartFile.fromBytes([1, 2, 3], filename: 'second_take.mp4'),
          ),
        );

        // Configure repository to succeed on next submit
        when(
          () => repository.createVideoLesson(
            20,
            51,
            title: 'Resubmitted Video',
            position: 1,
            videoFile: any(named: 'videoFile'),
            isRequired: true,
            minimumWatchPercent: 90.0,
            onSendProgress: any(named: 'onSendProgress'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagedVideoLessonDetail.fromJson(
            managedVideoLessonDetailJson(id: 100, title: 'Resubmitted Video'),
          ),
        );

        await tester.tap(find.text('Choose Video File'));
        await tester.pumpAndSettle();
        expect(find.text('second_take.mp4'), findsOneWidget);

        await tester.ensureVisible(
          find.widgetWithText(FilledButton, 'Create Video Lesson'),
        );
        await tester.tap(
          find.widgetWithText(FilledButton, 'Create Video Lesson'),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('Video lesson "Resubmitted Video" created successfully.'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'account switch cancels active upload request and isolates data',
      (tester) async {
        final completer = Completer<ManagedVideoLessonDetail>();
        CancelToken? capturedToken;

        when(
          () => repository.createVideoLesson(
            20,
            51,
            title: 'Switch Account',
            position: 1,
            videoFile: any(named: 'videoFile'),
            isRequired: true,
            minimumWatchPercent: 90.0,
            onSendProgress: any(named: 'onSendProgress'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((invocation) {
          capturedToken =
              invocation.namedArguments[#cancelToken] as CancelToken?;
          return completer.future;
        });

        await launch(tester);
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Lesson Title *'),
          'Switch Account',
        );
        await tester.tap(find.text('Choose Video File'));
        await tester.pumpAndSettle();

        await tester.tap(
          find.widgetWithText(FilledButton, 'Create Video Lesson'),
        );
        await tester.pump();

        expect(capturedToken?.isCancelled, isFalse);

        // Account switches to another coordinator
        auth.setAuth(
          AuthAuthenticated.identity(
            managementIdentity(
              username: 'other_admin',
              capabilities: {
                'management_workspace',
                'training.view_trainingversion',
                'training.view_module',
                'training.add_lesson',
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(capturedToken?.isCancelled, isTrue);

        // Finding 2 Verification: Account B cannot see Account A's loaded form or selected file
        expect(find.text('Switch Account'), findsNothing);
        expect(find.text('test.mp4'), findsNothing);
        expect(
          find.text('This account does not have permission to create lessons.'),
          findsOneWidget,
        );

        // Late response from Account A's cancelled request has no effect
        completer.complete(
          ManagedVideoLessonDetail.fromJson(
            managedVideoLessonDetailJson(id: 99, title: 'Switch Account'),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text('This account does not have permission to create lessons.'),
          findsOneWidget,
        );
      },
    );

    testWidgets('account switch during edit hides previous account metadata', (
      tester,
    ) async {
      await launch(
        tester,
        path:
            '/workspace/training/versions/20/modules/51/video-lessons/94/edit',
      );

      expect(find.text('Edit video lesson'), findsOneWidget);
      expect(find.text('Equipment Inspection'), findsOneWidget);

      // Switch to another account
      auth.setAuth(
        AuthAuthenticated.identity(
          managementIdentity(
            username: 'secondary_admin',
            capabilities: {
              'management_workspace',
              'training.view_trainingversion',
              'training.view_module',
              'training.change_lesson',
              'training.view_lesson',
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Equipment Inspection'), findsNothing);
      expect(
        find.text('This account does not have permission to edit lessons.'),
        findsOneWidget,
      );
    });
  });

  group('VideoLessonFormScreen - Editing Workflow', () {
    testWidgets('prefills metadata from videoLessonDetail', (tester) async {
      await launch(
        tester,
        path:
            '/workspace/training/versions/20/modules/51/video-lessons/94/edit',
      );

      expect(find.text('Edit video lesson'), findsOneWidget);
      expect(find.text('Equipment Inspection'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(
              find.widgetWithText(
                TextFormField,
                'Minimum Watch Percentage (%) *',
              ),
            )
            .controller!
            .text,
        '90.00',
      );
      expect(find.text('Current Video Attached'), findsOneWidget);
      expect(find.text('Duration: 1m 9s'), findsOneWidget);
      expect(find.text('Choose Replacement Video'), findsOneWidget);
    });

    testWidgets('metadata-only edit sends patch with null videoFile', (
      tester,
    ) async {
      when(
        () => repository.updateVideoLesson(
          20,
          51,
          94,
          title: 'Updated Inspection',
          position: null,
          isRequired: null,
          minimumWatchPercent: null,
          videoFile: null,
          onSendProgress: any(named: 'onSendProgress'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagedVideoLessonDetail.fromJson(
          managedVideoLessonDetailJson(
            id: 94,
            moduleId: 51,
            trainingVersionId: 20,
            title: 'Updated Inspection',
          ),
        ),
      );

      await launch(
        tester,
        path:
            '/workspace/training/versions/20/modules/51/video-lessons/94/edit',
      );

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Lesson Title *'),
        'Updated Inspection',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Save Changes'));
      await tester.pumpAndSettle();

      verify(
        () => repository.updateVideoLesson(
          20,
          51,
          94,
          title: 'Updated Inspection',
          position: null,
          isRequired: null,
          minimumWatchPercent: null,
          videoFile: null,
          onSendProgress: any(named: 'onSendProgress'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);

      expect(find.text('Video lesson updated successfully.'), findsOneWidget);
      verifyNever(() => picker.clearCache());
    });

    testWidgets('editing with replacement video sends multipart patch', (
      tester,
    ) async {
      when(
        () => repository.updateVideoLesson(
          20,
          51,
          94,
          title: null,
          position: null,
          isRequired: null,
          minimumWatchPercent: null,
          videoFile: any(named: 'videoFile'),
          onSendProgress: any(named: 'onSendProgress'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagedVideoLessonDetail.fromJson(
          managedVideoLessonDetailJson(
            id: 94,
            moduleId: 51,
            trainingVersionId: 20,
            videoDurationSeconds: 120,
          ),
        ),
      );

      await launch(
        tester,
        path:
            '/workspace/training/versions/20/modules/51/video-lessons/94/edit',
      );

      await tester.tap(find.text('Choose Replacement Video'));
      await tester.pumpAndSettle();

      expect(find.text('test.mp4'), findsOneWidget);
      expect(find.byTooltip('Remove replacement'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Save Changes'));
      await tester.pumpAndSettle();

      verify(
        () => repository.updateVideoLesson(
          20,
          51,
          94,
          title: null,
          position: null,
          isRequired: null,
          minimumWatchPercent: null,
          videoFile: any(named: 'videoFile'),
          onSendProgress: any(named: 'onSendProgress'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
      verify(() => picker.clearCache()).called(1);
    });

    testWidgets('unchanged edit pops without calling API', (tester) async {
      await launch(
        tester,
        path:
            '/workspace/training/versions/20/modules/51/video-lessons/94/edit',
      );

      // Save button is disabled when not dirty
      final saveBtn = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save Changes'),
      );
      expect(saveBtn.onPressed, isNull);
      verifyNever(() => repository.updateVideoLesson(any(), any(), any()));
    });

    testWidgets('discard dialog prompts on dirty form cancellation', (
      tester,
    ) async {
      await launch(
        tester,
        path:
            '/workspace/training/versions/20/modules/51/video-lessons/94/edit',
      );

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Lesson Title *'),
        'Modified Title',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Discard unsaved changes?'), findsOneWidget);
      expect(find.text('Keep editing'), findsOneWidget);
      expect(find.text('Discard'), findsOneWidget);

      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();

      expect(find.text('Modified Title'), findsOneWidget);
    });

    testWidgets(
      'successful submission clears file reference so dispose does not duplicate cleanup',
      (tester) async {
        when(
          () => repository.createVideoLesson(
            20,
            51,
            title: 'Clean On Submit',
            position: 1,
            videoFile: any(named: 'videoFile'),
            isRequired: true,
            minimumWatchPercent: 90.0,
            onSendProgress: any(named: 'onSendProgress'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagedVideoLessonDetail.fromJson(
            managedVideoLessonDetailJson(id: 105, title: 'Clean On Submit'),
          ),
        );

        await launch(tester);
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Lesson Title *'),
          'Clean On Submit',
        );
        await tester.tap(find.text('Choose Video File'));
        await tester.pumpAndSettle();

        await tester.tap(
          find.widgetWithText(FilledButton, 'Create Video Lesson'),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('Video lesson "Clean On Submit" created successfully.'),
          findsOneWidget,
        );

        // Unmount the form to trigger State.dispose() on the widget tree
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();

        // Exactly 1 clearCache call from successful submit, 0 repeated calls from dispose
        verify(() => picker.clearCache()).called(1);
      },
    );
  });

  group('VideoLessonFormScreen - TEXT vs VIDEO Separation', () {
    testWidgets('shows warning when text lesson is opened in video editor', (
      tester,
    ) async {
      final textLessonSummary = const ManagedLessonSummary(
        id: 90,
        title: 'Safety Policy Text',
        lessonType: 'TEXT',
        order: 1,
      );

      await launch(
        tester,
        path:
            '/workspace/training/versions/20/modules/51/video-lessons/90/edit',
        extra: textLessonSummary,
      );

      expect(
        find.text(
          'Text lessons cannot be edited through video lesson authoring.',
        ),
        findsOneWidget,
      );
      expect(find.text('Open in Text Lesson Editor'), findsOneWidget);

      await tester.tap(find.text('Open in Text Lesson Editor'));
      await tester.pumpAndSettle();

      expect(
        find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == 'TextLessonFormScreen',
        ),
        findsOneWidget,
      );
    });
  });

  group('VideoLessonFormScreen - Permissions & Router Guarding', () {
    testWidgets('router redirects away when lacking training.add_lesson', (
      tester,
    ) async {
      await launch(
        tester,
        identity: managementIdentity(
          capabilities: {
            'management_workspace',
            'training.view_trainingversion',
            // Missing training.add_lesson
          },
        ),
      );

      expect(find.text('Create Video Lesson'), findsNothing);
    });

    testWidgets('router redirects away from edit when lacking change_lesson', (
      tester,
    ) async {
      await launch(
        tester,
        path:
            '/workspace/training/versions/20/modules/51/video-lessons/94/edit',
        identity: managementIdentity(
          capabilities: {
            'management_workspace',
            'training.view_trainingversion',
            'training.view_lesson',
            // Missing training.change_lesson
          },
        ),
      );

      expect(find.text('Edit video lesson'), findsNothing);
    });

    testWidgets('router redirects away from edit when lacking view_lesson', (
      tester,
    ) async {
      await launch(
        tester,
        path:
            '/workspace/training/versions/20/modules/51/video-lessons/94/edit',
        identity: managementIdentity(
          capabilities: {
            'management_workspace',
            'training.view_trainingversion',
            'training.change_lesson',
            // Missing training.view_lesson
          },
        ),
      );

      expect(find.text('Edit video lesson'), findsNothing);
    });
  });

  group('VideoLessonFormScreen - Server Error Handling', () {
    testWidgets('displays 409 position conflict error', (tester) async {
      when(
        () => repository.createVideoLesson(
          any(),
          any(),
          title: any(named: 'title'),
          position: any(named: 'position'),
          videoFile: any(named: 'videoFile'),
          isRequired: any(named: 'isRequired'),
          minimumWatchPercent: any(named: 'minimumWatchPercent'),
          onSendProgress: any(named: 'onSendProgress'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(
        ApiError(statusCode: 409, code: 'conflict', message: 'Conflict'),
      );

      await launch(tester);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Lesson Title *'),
        'New Lesson',
      );
      await tester.tap(find.text('Choose Video File'));
      await tester.pumpAndSettle();

      await tester.tap(
        find.widgetWithText(FilledButton, 'Create Video Lesson'),
      );
      await tester.pumpAndSettle();

      expect(
        find.text(
          'That position was taken by another edit. Refresh and choose an unused position.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('displays 503 storage unavailable error', (tester) async {
      when(
        () => repository.createVideoLesson(
          any(),
          any(),
          title: any(named: 'title'),
          position: any(named: 'position'),
          videoFile: any(named: 'videoFile'),
          isRequired: any(named: 'isRequired'),
          minimumWatchPercent: any(named: 'minimumWatchPercent'),
          onSendProgress: any(named: 'onSendProgress'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(
        ApiError(
          statusCode: 503,
          code: 'upload_unavailable',
          message: 'Video storage is unavailable. Contact your administrator and try again.',
        ),
      );

      await launch(tester);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Lesson Title *'),
        'New Lesson',
      );
      await tester.tap(find.text('Choose Video File'));
      await tester.pumpAndSettle();

      await tester.tap(
        find.widgetWithText(FilledButton, 'Create Video Lesson'),
      );
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Video storage is unavailable. Contact your administrator and try again.',
        ),
        findsOneWidget,
      );
    });
  });

  group('VideoLessonFormScreen - Responsive & Accessibility', () {
    testWidgets('renders cleanly in dark theme', (tester) async {
      await launch(tester, themeMode: ThemeMode.dark);

      expect(find.text('New video lesson'), findsOneWidget);
      expect(find.text('Video Lesson Details'), findsOneWidget);
    });

    testWidgets(
      'fits small screen 320x640 with 2.0x text scale without overflow',
      (tester) async {
        await launch(tester, size: const Size(320, 640), textScale: 2.0);

        expect(find.text('New video lesson'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('fits landscape orientation 844x390 with 1.6x text scale', (
      tester,
    ) async {
      await launch(tester, size: const Size(844, 390), textScale: 1.6);

      expect(find.text('New video lesson'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
