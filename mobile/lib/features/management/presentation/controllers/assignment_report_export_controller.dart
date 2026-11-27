import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart'
    show StateNotifier, StateNotifierProvider;
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/data/repositories/management_repository.dart';
import 'package:training_app/features/management/data/services/assignment_report_csv_service.dart';
import 'package:training_app/features/management/presentation/controllers/management_controller.dart';
import 'package:training_app/features/management/presentation/models/assignment_report_view_data.dart';

sealed class AssignmentReportExportState {
  const AssignmentReportExportState();
}

class AssignmentReportExportIdle extends AssignmentReportExportState {
  const AssignmentReportExportIdle();
}

class AssignmentReportExportInProgress extends AssignmentReportExportState {
  final int? progressCurrent;
  final int? progressTotal;
  const AssignmentReportExportInProgress({
    this.progressCurrent,
    this.progressTotal,
  });
}

/// Distinguishes direct file saving to storage from handing off to a share dialog.
enum ReportExportSaveType {
  /// File was successfully saved directly to device storage via native Save As or file creation.
  fileSaved,

  /// File was handed off to a system share dialog/chooser.
  shareDialog,
}

class AssignmentReportExportSuccess extends AssignmentReportExportState {
  final String filename;
  final int itemCount;
  final ReportExportSaveType saveType;
  final String? savedPath;

  const AssignmentReportExportSuccess({
    required this.filename,
    required this.itemCount,
    this.saveType = ReportExportSaveType.fileSaved,
    this.savedPath,
  });

  bool get isFileSaved => saveType == ReportExportSaveType.fileSaved;
  bool get isShareDialog => saveType == ReportExportSaveType.shareDialog;
}

class AssignmentReportExportCancelled extends AssignmentReportExportState {
  const AssignmentReportExportCancelled();
}

class AssignmentReportExportEmpty extends AssignmentReportExportState {
  const AssignmentReportExportEmpty();
}

class AssignmentReportExportError extends AssignmentReportExportState {
  final String message;
  const AssignmentReportExportError(this.message);
}

final assignmentReportExportControllerProvider =
    StateNotifierProvider.autoDispose<
      AssignmentReportExportController,
      AssignmentReportExportState
    >((ref) => AssignmentReportExportController(ref));

class AssignmentReportExportController
    extends StateNotifier<AssignmentReportExportState> {
  static const MethodChannel _fileSaverChannel =
      MethodChannel('gardensneed/file_saver');

  final Ref _ref;
  CancelToken? _request;
  int _generation = 0;
  bool _disposed = false;
  CancelToken? _saveRequest;

  AssignmentReportExportController(this._ref)
    : super(const AssignmentReportExportIdle()) {
    _ref.listen<AuthState>(authControllerProvider, (previous, next) {
      if (managementAccount(previous ?? AuthInitial()) !=
          managementAccount(next)) {
        _invalidate();
        if (!_disposed) state = const AssignmentReportExportIdle();
      }
    });
  }

  void _invalidate() {
    _generation++;
    _request?.cancel('Report export owner changed or operation ended.');
    _request = null;
    _cancelNativeSave();
  }

  void _cancelNativeSave() {
    if (_saveRequest != null) {
      try {
        _fileSaverChannel
            .invokeMethod<dynamic>('cancelSave')
            .catchError((_) => null);
      } catch (_) {}
    }
  }

  bool _current(int generation, String? owner) =>
      !_disposed &&
      generation == _generation &&
      managementAccount(_ref.read(authControllerProvider)) == owner;

  Future<void> exportReport(AssignmentReportFilterQuery query) async {
    // A native Save As already in progress cannot be replayed or superseded.
    if (_disposed || _request != null || _saveRequest != null) return;
    final auth = _ref.read(authControllerProvider);
    if (auth is! AuthAuthenticated ||
        !canViewAssignmentReports(auth.identity)) {
      state = const AssignmentReportExportError(
        'You do not have permission to export assignment reports.',
      );
      return;
    }
    final owner = managementAccount(auth);
    final generation = ++_generation;
    final requests = CancelToken();
    _request = requests;
    state = const AssignmentReportExportInProgress();

    try {
      final repository = _ref.read(managementRepositoryProvider);
      final fileSaver = _ref.read(reportFileSaverProvider);
      final download = await repository.downloadAssignmentReportCsv(
        query: query,
        cancelToken: requests,
      );
      if (!_current(generation, owner) || requests.isCancelled) return;
      if (download.itemCount == 0) {
        state = const AssignmentReportExportEmpty();
        return;
      }

      _saveRequest = requests;
      final result = await fileSaver.saveFile(
        bytes: download.bytes,
        filename: download.filename,
        mimeType: 'text/csv',
      );
      if (!_current(generation, owner) || requests.isCancelled) return;
      switch (result.status) {
        case ReportFileSaveStatus.saved:
          state = AssignmentReportExportSuccess(
            filename: download.filename,
            itemCount: download.itemCount,
            savedPath: result.savedPath,
          );
        case ReportFileSaveStatus.shared:
          state = const AssignmentReportExportError(
            'The share dialog opened, but saving the report was not confirmed.',
          );
        case ReportFileSaveStatus.cancelled:
          state = const AssignmentReportExportCancelled();
      }
    } catch (error) {
      if (!_current(generation, owner) || requests.isCancelled) return;
      if (error is DioException && CancelToken.isCancel(error)) {
        state = const AssignmentReportExportCancelled();
      } else if (error is ApiError &&
          error.statusCode == 413 &&
          error.code == 'export_too_large') {
        state = const AssignmentReportExportError(
          'This report exceeds the 10,000-row export limit. Narrow the filters and try again.',
        );
      } else {
        state = AssignmentReportExportError(
          error is ApiError
              ? error.message
              : 'The report could not be exported. Please try again.',
        );
      }
    } finally {
      if (identical(_saveRequest, requests)) _saveRequest = null;
      if (identical(_request, requests)) _request = null;
    }
  }

  void reset() {
    _invalidate();
    if (!_disposed) state = const AssignmentReportExportIdle();
  }

  @override
  void dispose() {
    _disposed = true;
    _invalidate();
    super.dispose();
  }
}
