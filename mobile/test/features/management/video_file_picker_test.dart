import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/features/management/data/services/video_file_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('gardensneed/video_picker');
  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  group('SelectedVideoFile', () {
    test('stores metadata properties properly', () {
      const selected = SelectedVideoFile(
        path: '/cache/video_picker/sample.mp4',
        name: 'sample.mp4',
        sizeInBytes: 1048576,
        mimeType: 'video/mp4',
      );

      expect(selected.path, '/cache/video_picker/sample.mp4');
      expect(selected.name, 'sample.mp4');
      expect(selected.sizeInBytes, 1048576);
      expect(selected.mimeType, 'video/mp4');
      expect(selected.multipartFileFactory, isNull);
    });

    test('toMultipartFile invokes custom factory if provided', () async {
      var factoryCalled = false;
      final selected = SelectedVideoFile(
        path: '/cache/video_picker/sample.mp4',
        name: 'sample.mp4',
        sizeInBytes: 1024,
        multipartFileFactory: () {
          factoryCalled = true;
          return MultipartFile.fromBytes([1, 2, 3], filename: 'sample.mp4');
        },
      );

      final multipart = await selected.toMultipartFile();
      expect(factoryCalled, isTrue);
      expect(multipart.filename, 'sample.mp4');
      expect(multipart.length, 3);
    });

    test('toMultipartFile defaults to MultipartFile.fromFile', () async {
      final tempDir = await Directory.systemTemp.createTemp('video_test_');
      final testFile = File('${tempDir.path}/test.mp4');
      await testFile.writeAsBytes([1, 2, 3, 4, 5]);

      try {
        final selected = SelectedVideoFile(
          path: testFile.path,
          name: 'test.mp4',
          sizeInBytes: 5,
        );

        final multipart = await selected.toMultipartFile();
        expect(multipart.filename, 'test.mp4');
        expect(multipart.length, 5);
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('delete safely removes file when it exists', () async {
      final tempDir = await Directory.systemTemp.createTemp('video_del_');
      final testFile = File('${tempDir.path}/temp_video.mp4');
      await testFile.writeAsString('mock video data');
      expect(await testFile.exists(), isTrue);

      final selected = SelectedVideoFile(
        path: testFile.path,
        name: 'temp_video.mp4',
        sizeInBytes: 15,
      );

      await selected.delete();
      expect(await testFile.exists(), isFalse);

      await tempDir.delete(recursive: true);
    });

    test('delete does not throw when file does not exist', () async {
      const selected = SelectedVideoFile(
        path: '/non_existent_dir/does_not_exist.mp4',
        name: 'does_not_exist.mp4',
        sizeInBytes: 0,
      );

      await expectLater(selected.delete(), completes);
    });
  });

  group('MethodChannelVideoFilePicker - pickVideo', () {
    tearDown(() {
      binaryMessenger.setMockMethodCallHandler(channel, null);
    });

    test(
      'returns SelectedVideoFile when native channel returns valid map',
      () async {
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'pickVideo') {
            return {
              'path': '/data/user/0/com.gardensneed.training/cache/sample.mp4',
              'name': 'safety_overview.mp4',
              'size': 12345678,
              'mimeType': 'video/mp4',
            };
          }
          return null;
        });

        const picker = MethodChannelVideoFilePicker();
        final result = await picker.pickVideo();

        expect(result, isNotNull);
        expect(
          result!.path,
          '/data/user/0/com.gardensneed.training/cache/sample.mp4',
        );
        expect(result.name, 'safety_overview.mp4');
        expect(result.sizeInBytes, 12345678);
        expect(result.mimeType, 'video/mp4');
      },
    );

    test('returns null when native picker is cancelled by user', () async {
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'pickVideo') {
          return null;
        }
        return null;
      });

      const picker = MethodChannelVideoFilePicker();
      final result = await picker.pickVideo();

      expect(result, isNull);
    });

    test(
      'throws ApiError with statusCode 501 on MissingPluginException',
      () async {
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          throw MissingPluginException();
        });

        const picker = MethodChannelVideoFilePicker();

        expect(
          () => picker.pickVideo(),
          throwsA(
            isA<ApiError>().having((e) => e.statusCode, 'statusCode', 501),
          ),
        );
      },
    );

    test(
      'throws ApiError with statusCode 409 on ALREADY_ACTIVE PlatformException',
      () async {
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(
            code: 'ALREADY_ACTIVE',
            message: 'A video selection is already in progress',
          );
        });

        const picker = MethodChannelVideoFilePicker();

        expect(
          () => picker.pickVideo(),
          throwsA(
            isA<ApiError>()
                .having((e) => e.statusCode, 'statusCode', 409)
                .having(
                  (e) => e.message,
                  'message',
                  'A video selection is already in progress',
                ),
          ),
        );
      },
    );

    test(
      'throws ApiError with statusCode 400 on STREAM_ERROR PlatformException',
      () async {
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(
            code: 'STREAM_ERROR',
            message: 'Failed to read selected video',
          );
        });

        const picker = MethodChannelVideoFilePicker();

        expect(
          () => picker.pickVideo(),
          throwsA(
            isA<ApiError>()
                .having((e) => e.statusCode, 'statusCode', 400)
                .having(
                  (e) => e.message,
                  'message',
                  'Failed to read selected video',
                ),
          ),
        );
      },
    );
  });

  group('MethodChannelVideoFilePicker - clearCache', () {
    tearDown(() {
      binaryMessenger.setMockMethodCallHandler(channel, null);
    });

    test('invokes clearCache method on channel', () async {
      var clearCacheCalled = false;
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'clearCache') {
          clearCacheCalled = true;
          return null;
        }
        return null;
      });

      const picker = MethodChannelVideoFilePicker();
      await picker.clearCache();

      expect(clearCacheCalled, isTrue);
    });

    test('suppresses MissingPluginException and errors gracefully', () async {
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        throw MissingPluginException();
      });

      const picker = MethodChannelVideoFilePicker();
      await expectLater(picker.clearCache(), completes);
    });
  });

  group('videoFilePickerProvider', () {
    test('defaults to MethodChannelVideoFilePicker', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final picker = container.read(videoFilePickerProvider);
      expect(picker, isA<MethodChannelVideoFilePicker>());
    });
  });
}
