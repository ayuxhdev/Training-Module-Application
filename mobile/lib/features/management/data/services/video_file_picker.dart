import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/errors/api_error.dart';

/// Represents a locally selected video file ready for streaming multipart upload.
class SelectedVideoFile {
  final String path;
  final String name;
  final int sizeInBytes;
  final String? mimeType;
  final MultipartFile Function()? multipartFileFactory;

  const SelectedVideoFile({
    required this.path,
    required this.name,
    required this.sizeInBytes,
    this.mimeType,
    this.multipartFileFactory,
  });

  /// Creates a streaming [MultipartFile] for Dio.
  ///
  /// Uses chunked file streams from disk without loading large video bytes into memory.
  Future<MultipartFile> toMultipartFile() async {
    if (multipartFileFactory != null) {
      return multipartFileFactory!();
    }
    return MultipartFile.fromFile(path, filename: name);
  }

  /// Deletes the cached temporary file if it exists.
  Future<void> delete() async {
    try {
      final file = File(path);
      if (file.existsSync()) {
        file.deleteSync();
      }
    } catch (_) {
      // Non-fatal cleanup failure.
    }
  }
}

/// Abstract contract for picking local video files and managing cached media.
abstract class VideoFilePicker {
  Future<SelectedVideoFile?> pickVideo();
  Future<void> clearCache();
}

/// Default platform-channel implementation of [VideoFilePicker].
class MethodChannelVideoFilePicker implements VideoFilePicker {
  static const _channel = MethodChannel('gardensneed/video_picker');

  const MethodChannelVideoFilePicker();

  @override
  Future<SelectedVideoFile?> pickVideo() async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'pickVideo',
      );
      if (result == null) return null;
      return SelectedVideoFile(
        path: result['path'] as String,
        name: result['name'] as String,
        sizeInBytes: (result['size'] as num).toInt(),
        mimeType: result['mimeType'] as String?,
      );
    } on MissingPluginException {
      throw ApiError(
        message: 'Native video picker is not supported on this platform configuration.',
        statusCode: 501,
      );
    } on PlatformException catch (e) {
      if (e.code == 'ALREADY_ACTIVE') {
        throw ApiError(
          message: e.message ?? 'A video selection is already in progress.',
          statusCode: 409,
        );
      }
      throw ApiError(
        message: e.message ?? 'Failed to select video file.',
        statusCode: 400,
      );
    }
  }

  @override
  Future<void> clearCache() async {
    try {
      await _channel.invokeMethod<void>('clearCache');
    } on MissingPluginException {
      // Harmless on platforms without native implementation.
    } catch (_) {
      // Non-fatal cache clearing attempt.
    }
  }
}

/// Riverpod provider for video file selection. Can be overridden in tests.
final videoFilePickerProvider = Provider<VideoFilePicker>(
  (ref) => const MethodChannelVideoFilePicker(),
);
