import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
import 'package:training_app/core/presentation/components/content_skeleton.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/data/services/video_file_picker.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';
import 'package:training_app/features/management/presentation/controllers/management_controller.dart';

class VideoLessonFormScreen extends ConsumerStatefulWidget {
  final int versionId;
  final int moduleId;
  final int? lessonId;
  final dynamic initialLesson;
  final int? suggestedPosition;

  const VideoLessonFormScreen({
    super.key,
    required this.versionId,
    required this.moduleId,
    this.lessonId,
    this.initialLesson,
    this.suggestedPosition,
  });

  @override
  ConsumerState<VideoLessonFormScreen> createState() =>
      _VideoLessonFormScreenState();
}

class _VideoLessonFormScreenState extends ConsumerState<VideoLessonFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _positionController;
  late final TextEditingController _minimumWatchPercentController;
  bool _isRequired = true;

  SelectedVideoFile? _selectedVideoFile;
  String? _videoFileError;
  double? _uploadProgress;

  bool _isSubmitting = false;
  CancelToken? _activeRequest;
  String? _serverError;
  Map<String, String> _fieldErrors = const {};

  bool _initialLoaded = false;
  String? _initialTitle;
  int? _initialPosition;
  bool? _initialIsRequired;
  String? _initialMinWatchPercent;
  bool _currentHasVideo = false;
  int _currentDurationSeconds = 0;

  late String _account;
  late final VideoFilePicker _videoFilePicker;

  bool get _isEditing => widget.lessonId != null;

  bool get _isTextLesson {
    final initial = widget.initialLesson;
    if (initial is ManagedLessonSummary &&
        initial.lessonType.toUpperCase() == 'TEXT') {
      return true;
    }
    if (initial is ManagedTextLessonDetail) {
      return true;
    }
    return false;
  }

  bool get _isDirty {
    if (!_initialLoaded) return false;
    final currentTitle = _titleController.text.trim();
    final currentPos = int.tryParse(_positionController.text.trim());
    final currentMinPercent = _minimumWatchPercentController.text.trim();

    if (!_isEditing) {
      return currentTitle.isNotEmpty ||
          _selectedVideoFile != null ||
          (currentPos != null &&
              currentPos != (widget.suggestedPosition ?? 1)) ||
          !_isRequired ||
          currentMinPercent != '90.00';
    }

    return currentTitle != (_initialTitle ?? '') ||
        currentPos != _initialPosition ||
        _isRequired != _initialIsRequired ||
        currentMinPercent != (_initialMinWatchPercent ?? '90.00') ||
        _selectedVideoFile != null;
  }

  @override
  void initState() {
    super.initState();
    final auth = ref.read(authControllerProvider);
    _account = managementAccount(auth) ?? '';
    _videoFilePicker = ref.read(videoFilePickerProvider);

    _titleController = TextEditingController();
    _positionController = TextEditingController();
    _minimumWatchPercentController = TextEditingController(text: '90.00');

    final initial = widget.initialLesson;
    if (initial is ManagedVideoLessonDetail) {
      _populateFromDetail(initial);
    } else if (initial is ManagedLessonSummary && !_isTextLesson) {
      _initialTitle = initial.title;
      _initialPosition = initial.order;
      _initialIsRequired = initial.isRequired;
      _isRequired = initial.isRequired;

      _titleController.text = initial.title;
      _positionController.text = initial.order.toString();
      _initialLoaded = false;
    } else if (!_isEditing) {
      _positionController.text = (widget.suggestedPosition ?? 1).toString();
      _isRequired = true;
      _initialLoaded = true;
    } else {
      _isRequired = true;
      _initialLoaded = false;
    }
  }

  void _populateFromDetail(ManagedVideoLessonDetail detail) {
    if (_initialLoaded) return;
    final currentAuth = ref.read(authControllerProvider);
    if (managementAccount(currentAuth) != _account) return;
    _initialTitle = detail.title;
    _initialPosition = detail.position;
    _initialIsRequired = detail.isRequired;
    _initialMinWatchPercent = detail.minimumWatchPercent;
    _currentDurationSeconds = detail.videoDurationSeconds;
    _currentHasVideo = detail.hasVideo;

    _titleController.text = detail.title;
    _positionController.text = detail.position.toString();
    _isRequired = detail.isRequired;
    _minimumWatchPercentController.text = detail.minimumWatchPercent;
    _initialLoaded = true;
  }

  @override
  void dispose() {
    _activeRequest?.cancel('Form disposed');
    _titleController.dispose();
    _positionController.dispose();
    _minimumWatchPercentController.dispose();
    final remainingFile = _selectedVideoFile;
    _selectedVideoFile = null;
    if (remainingFile != null) {
      remainingFile.delete();
      _videoFilePicker.clearCache();
    }
    super.dispose();
  }

  Map<String, String> _fieldErrorsFrom(ApiError error) {
    final details = error.details;
    if (details is! Map) return const {};
    final result = <String, String>{};
    for (final entry in details.entries) {
      final key = entry.key.toString();
      final value = entry.value;
      if (value is String && value.isNotEmpty) {
        result[key] = value;
      } else if (value is List && value.isNotEmpty) {
        result[key] = value.map((item) => item.toString()).join(' ');
      }
    }
    return result;
  }

  String? _nonFieldErrorFrom(ApiError error) {
    final details = error.details;
    if (details is! Map) return null;
    final value = details['non_field_errors'] ?? details['detail'];
    if (value is String && value.isNotEmpty) return value;
    if (value is List && value.isNotEmpty) {
      return value.map((item) => item.toString()).join(' ');
    }
    return null;
  }

  void _markChanged() {
    setState(() {
      _serverError = null;
      _fieldErrors = const {};
    });
  }

  String? _validateVideoFile(
    SelectedVideoFile? file, {
    required bool isEditing,
  }) {
    if (file == null) {
      if (!isEditing) {
        return 'Choose a video file for this lesson.';
      }
      return null;
    }

    if (file.sizeInBytes <= 0) {
      return 'Video file is empty. Please select a valid video.';
    }

    const maxVideoSizeBytes = 2 * 1024 * 1024 * 1024; // 2 GB
    if (file.sizeInBytes > maxVideoSizeBytes) {
      return 'Video file exceeds the 2 GB maximum size limit.';
    }

    final lower = file.name.toLowerCase();
    final hasValidExt =
        lower.endsWith('.mp4') ||
        lower.endsWith('.webm') ||
        lower.endsWith('.mov');
    if (!hasValidExt) {
      return 'Unsupported video format. Allowed formats are MP4, WebM, and MOV.';
    }

    return null;
  }

  Future<void> _pickVideo() async {
    setState(() {
      _videoFileError = null;
    });

    try {
      final picked = await _videoFilePicker.pickVideo();
      if (!mounted) {
        picked?.delete();
        return;
      }
      if (picked == null) return;

      final validationError = _validateVideoFile(picked, isEditing: _isEditing);
      if (validationError != null) {
        picked.delete();
        setState(() {
          _videoFileError = validationError;
        });
        return;
      }

      final previousFile = _selectedVideoFile;
      setState(() {
        _selectedVideoFile = picked;
        _videoFileError = null;
      });
      if (previousFile != null && previousFile.path != picked.path) {
        previousFile.delete();
      }
      _markChanged();
    } catch (error) {
      if (!mounted) return;
      final parsed = error is ApiError ? error : ApiError.unexpected();
      setState(() {
        _videoFileError = parsed.message;
      });
    }
  }

  void _removeSelectedVideo() {
    final oldFile = _selectedVideoFile;
    setState(() {
      _selectedVideoFile = null;
      _videoFileError = null;
    });
    if (oldFile != null) {
      oldFile.delete();
      _videoFilePicker.clearCache();
    }
    _markChanged();
  }

  void _cancelActiveUpload() {
    if (_activeRequest != null && !_activeRequest!.isCancelled) {
      _activeRequest!.cancel('Upload cancelled by user');
    }
    final fileToDelete = _selectedVideoFile;
    setState(() {
      _isSubmitting = false;
      _uploadProgress = null;
      _selectedVideoFile = null;
    });
    if (fileToDelete != null) {
      fileToDelete.delete();
      _videoFilePicker.clearCache();
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Upload cancelled.')));
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _formatDuration(int seconds) {
    if (seconds <= 0) return '0s';
    final minutes = seconds ~/ 60;
    final remaining = seconds % 60;
    if (minutes == 0) return '${remaining}s';
    return '${minutes}m ${remaining}s';
  }

  Future<bool> _confirmDiscard() async {
    if (!_isDirty || _isSubmitting) return true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Discard unsaved changes?'),
        content: const Text(
          'You have unsaved edits in this video lesson form. Leaving will discard them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final fileToDelete = _selectedVideoFile;
      _selectedVideoFile = null;
      if (fileToDelete != null) {
        fileToDelete.delete();
        _videoFilePicker.clearCache();
      }
    }
    return confirmed ?? false;
  }

  Future<void> _submitForm() async {
    setState(() {
      _serverError = null;
      _fieldErrors = const {};
    });

    final isValid = _formKey.currentState!.validate();
    if (!_isEditing && _selectedVideoFile == null) {
      setState(() {
        _videoFileError = 'Choose a video file for this lesson.';
      });
    }

    if (!isValid || (!_isEditing && _selectedVideoFile == null)) return;

    if (_selectedVideoFile != null) {
      final fileErr = _validateVideoFile(
        _selectedVideoFile,
        isEditing: _isEditing,
      );
      if (fileErr != null) {
        setState(() {
          _videoFileError = fileErr;
        });
        return;
      }
    }

    final auth = ref.read(authControllerProvider);
    final allowed =
        auth is AuthAuthenticated &&
        managementAccount(auth) == _account &&
        (_isEditing
            ? canAccessLessonEditForm(auth.identity)
            : canCreateLessons(auth.identity));

    if (!allowed) {
      setState(() {
        _serverError = _isEditing
            ? 'This account does not have permission to edit lessons.'
            : 'This account does not have permission to create lessons.';
      });
      return;
    }

    final title = _titleController.text.trim();
    final position = int.tryParse(_positionController.text.trim()) ?? 1;
    final minWatchPercent = double.tryParse(
      _minimumWatchPercentController.text.trim(),
    );

    if (_isEditing && !_isDirty) {
      if (mounted && context.canPop()) context.pop();
      return;
    }

    setState(() {
      _isSubmitting = true;
      _uploadProgress = _selectedVideoFile != null ? 0.0 : null;
    });

    final cancelToken = CancelToken();
    _activeRequest = cancelToken;

    try {
      final controller = ref.read(videoLessonMutationProvider);
      if (_isEditing) {
        await controller.update(
          versionId: widget.versionId,
          moduleId: widget.moduleId,
          lessonId: widget.lessonId!,
          title: title != _initialTitle ? title : null,
          position: position != _initialPosition ? position : null,
          isRequired: _isRequired != _initialIsRequired ? _isRequired : null,
          minimumWatchPercent:
              minWatchPercent != null &&
                  _minimumWatchPercentController.text.trim() !=
                      _initialMinWatchPercent
              ? minWatchPercent
              : null,
          videoFile: _selectedVideoFile,
          onSendProgress: (sent, total) {
            if (total > 0 && mounted) {
              setState(() {
                _uploadProgress = sent / total;
              });
            }
          },
          cancelToken: cancelToken,
        );
      } else {
        await controller.create(
          versionId: widget.versionId,
          moduleId: widget.moduleId,
          title: title,
          position: position,
          videoFile: _selectedVideoFile!,
          isRequired: _isRequired,
          minimumWatchPercent: minWatchPercent,
          onSendProgress: (sent, total) {
            if (total > 0 && mounted) {
              setState(() {
                _uploadProgress = sent / total;
              });
            }
          },
          cancelToken: cancelToken,
        );
      }

      if (!mounted) return;
      if (cancelToken.isCancelled) return;
      final currentAuth = ref.read(authControllerProvider);
      if (managementAccount(currentAuth) != _account) return;

      ref.invalidate(managedVersionDetailProvider(widget.versionId));
      ref.invalidate(
        managedModuleDetailProvider((
          versionId: widget.versionId,
          moduleId: widget.moduleId,
        )),
      );
      if (_isEditing) {
        ref.invalidate(
          managedVideoLessonDetailProvider((
            versionId: widget.versionId,
            moduleId: widget.moduleId,
            lessonId: widget.lessonId!,
          )),
        );
      }

      final uploadedFile = _selectedVideoFile;
      _selectedVideoFile = null;
      if (uploadedFile != null) {
        uploadedFile.delete();
        _videoFilePicker.clearCache();
      }

      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              _isEditing
                  ? 'Video lesson updated successfully.'
                  : 'Video lesson "$title" created successfully.',
            ),
          ),
        );
      if (context.canPop()) {
        context.pop(true);
      }
    } catch (error) {
      if (!mounted) return;
      if (cancelToken.isCancelled) return;
      final currentAuth = ref.read(authControllerProvider);
      if (managementAccount(currentAuth) != _account) return;

      final parsed = error is ApiError ? error : ApiError.unexpected();
      final fields = _fieldErrorsFrom(parsed);

      setState(() {
        _fieldErrors = fields;
        if (fields.containsKey('video_file')) {
          _videoFileError = fields['video_file'];
        }
        if (parsed.statusCode == 409) {
          _serverError = 'That position was taken by another edit. Refresh and choose an unused position.';
        } else if (parsed.statusCode == 404) {
          _serverError = 'The curriculum version, module, or lesson was not found, or is no longer in draft.';
        } else if (parsed.statusCode == 403) {
          _serverError =
              'You do not have permission to ${_isEditing ? "edit" : "create"} lessons.';
        } else if (parsed.statusCode == 503) {
          _serverError = parsed.message.isNotEmpty ? parsed.message : 'Video storage is unavailable. Contact your administrator and try again.';
        } else {
          _serverError = _nonFieldErrorFrom(parsed) ?? parsed.message;
        }
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
          _uploadProgress = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isTextLesson) {
      return Scaffold(
        appBar: AppBar(title: const Text('Edit video lesson')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Text lessons cannot be edited through video lesson authoring.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.md),
                FilledButton.tonal(
                  onPressed: () {
                    context.pushReplacement(
                      '/workspace/training/versions/${widget.versionId}/modules/${widget.moduleId}/lessons/${widget.lessonId}/edit',
                      extra: widget.initialLesson,
                    );
                  },
                  child: const Text('Open in Text Lesson Editor'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    ref.listen<AuthState>(authControllerProvider, (_, next) {
      if (managementAccount(next) != _account) {
        _activeRequest?.cancel('Account changed');
        final fileToDelete = _selectedVideoFile;
        _selectedVideoFile = null;
        if (fileToDelete != null) {
          fileToDelete.delete();
          _videoFilePicker.clearCache();
        }
        if (mounted) {
          setState(() {
            _isSubmitting = false;
            _uploadProgress = null;
            _selectedVideoFile = null;
          });
        }
      }
    });

    final auth = ref.watch(authControllerProvider);
    final permitted =
        auth is AuthAuthenticated &&
        managementAccount(auth) == _account &&
        (_isEditing
            ? canAccessLessonEditForm(auth.identity)
            : canCreateLessons(auth.identity));

    if (!permitted) {
      return Scaffold(
        appBar: AppBar(
          title: Text(_isEditing ? 'Edit video lesson' : 'Create Video Lesson'),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Text(
              _isEditing
                  ? 'This account does not have permission to edit lessons.'
                  : 'This account does not have permission to create lessons.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    if (_isEditing && !_initialLoaded) {
      final detailAsync = ref.watch(
        managedVideoLessonDetailProvider((
          versionId: widget.versionId,
          moduleId: widget.moduleId,
          lessonId: widget.lessonId!,
        )),
      );

      return detailAsync.when(
        data: (detail) {
          if (detail.contentType.toUpperCase() != 'VIDEO') {
            return Scaffold(
              appBar: AppBar(title: const Text('Edit video lesson')),
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Text lessons cannot be edited through video lesson authoring.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: AppSpacing.md),
                      FilledButton.tonal(
                        onPressed: () {
                          context.pushReplacement(
                            '/workspace/training/versions/${widget.versionId}/modules/${widget.moduleId}/lessons/${widget.lessonId}/edit',
                            extra: widget.initialLesson,
                          );
                        },
                        child: const Text('Open in Text Lesson Editor'),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }
          _populateFromDetail(detail);
          return _buildFormScaffold(context);
        },
        loading: () => Scaffold(
          appBar: AppBar(title: const Text('Edit video lesson')),
          body: const Center(
            child: CardListSkeleton(
              message: 'Loading lesson details',
              compact: true,
            ),
          ),
        ),
        error: (error, _) {
          final parsed = error is ApiError ? error : ApiError.unexpected();
          return Scaffold(
            appBar: AppBar(title: const Text('Edit video lesson')),
            body: ApiErrorView(
              error: parsed,
              onRetry: () => ref.refresh(
                managedVideoLessonDetailProvider((
                  versionId: widget.versionId,
                  moduleId: widget.moduleId,
                  lessonId: widget.lessonId!,
                )).future,
              ),
            ),
          );
        },
      );
    }

    return _buildFormScaffold(context);
  }

  Widget _buildFormScaffold(BuildContext context) {
    final theme = Theme.of(context);
    final titleFieldErr = _fieldErrors['title'];
    final posFieldErr = _fieldErrors['position'];
    final minWatchFieldErr = _fieldErrors['minimum_watch_percent'];
    final fileFieldErr = _fieldErrors['video_file'] ?? _videoFileError;

    return PopScope(
      canPop: !_isDirty || _isSubmitting,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final shouldDiscard = await _confirmDiscard();
        if (shouldDiscard && context.mounted) {
          if (context.canPop()) {
            context.pop();
          }
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_isEditing ? 'Edit video lesson' : 'New video lesson'),
          actions: [
            if (_isSubmitting)
              Padding(
                padding: const EdgeInsets.only(right: AppSpacing.md),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
              ),
          ],
        ),
        body: Form(
          key: _formKey,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_serverError != null) ...[
                  Container(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.error_outline,
                          color: theme.colorScheme.onErrorContainer,
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(
                            _serverError!,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onErrorContainer,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                ],

                // Upload progress indicator card when active
                if (_isSubmitting && _uploadProgress != null) ...[
                  CustomCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.cloud_upload_outlined,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            Expanded(
                              child: Text(
                                'Uploading video... ${(_uploadProgress! * 100).toStringAsFixed(0)}%',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        LinearProgressIndicator(
                          value: _uploadProgress,
                          backgroundColor:
                              theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        Align(
                          alignment: Alignment.centerRight,
                          child: OutlinedButton.icon(
                            onPressed: _cancelActiveUpload,
                            icon: const Icon(Icons.cancel_outlined, size: 18),
                            label: const Text('Cancel Upload'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                ],

                // Metadata Card
                CustomCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Video Lesson Details',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        _isEditing
                            ? 'Update video metadata or upload a replacement file for this draft lesson.'
                            : 'Set lesson title, order, completion rules, and select a local video file.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),

                      // Title field
                      TextFormField(
                        controller: _titleController,
                        enabled: !_isSubmitting,
                        decoration: InputDecoration(
                          labelText: 'Lesson Title *',
                          hintText: 'e.g. Safety Orientation Overview',
                          errorText: titleFieldErr,
                          helperText: 'Max 200 characters',
                        ),
                        maxLength: 200,
                        onChanged: (_) => _markChanged(),
                        validator: (val) {
                          if (val == null || val.trim().isEmpty) {
                            return 'Lesson title is required.';
                          }
                          if (val.trim().length > 200) {
                            return 'Title cannot exceed 200 characters.';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: AppSpacing.sm),

                      // Position field with stepper
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _positionController,
                              enabled: !_isSubmitting,
                              decoration: InputDecoration(
                                labelText: 'Position *',
                                hintText: '1',
                                errorText: posFieldErr,
                                helperText: 'Explicit positive integer. Gaps are allowed.',
                              ),
                              keyboardType: TextInputType.number,
                              onChanged: (_) => _markChanged(),
                              validator: (val) {
                                if (val == null || val.trim().isEmpty) {
                                  return 'Position is required.';
                                }
                                final pos = int.tryParse(val.trim());
                                if (pos == null ||
                                    pos < 1 ||
                                    pos > 2147483647) {
                                  return 'Enter a valid position (1 or greater).';
                                }
                                return null;
                              },
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          IconButton.outlined(
                            icon: const Icon(Icons.remove, size: 20),
                            tooltip: 'Decrease position',
                            onPressed: _isSubmitting
                                ? null
                                : () {
                                    final current =
                                        int.tryParse(
                                          _positionController.text.trim(),
                                        ) ??
                                        1;
                                    if (current > 1) {
                                      _positionController.text = (current - 1)
                                          .toString();
                                      _markChanged();
                                    }
                                  },
                          ),
                          const SizedBox(width: AppSpacing.xs),
                          IconButton.outlined(
                            icon: const Icon(Icons.add, size: 20),
                            tooltip: 'Increase position',
                            onPressed: _isSubmitting
                                ? null
                                : () {
                                    final current =
                                        int.tryParse(
                                          _positionController.text.trim(),
                                        ) ??
                                        1;
                                    if (current < 2147483647) {
                                      _positionController.text = (current + 1)
                                          .toString();
                                      _markChanged();
                                    }
                                  },
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.sm),

                      // Minimum watch percent
                      TextFormField(
                        controller: _minimumWatchPercentController,
                        enabled: !_isSubmitting,
                        decoration: InputDecoration(
                          labelText: 'Minimum Watch Percentage (%) *',
                          hintText: '90.00',
                          errorText: minWatchFieldErr,
                          helperText:
                              'Between 0.00 and 100.00. Default is 90.00%.',
                          suffixText: '%',
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        onChanged: (_) => _markChanged(),
                        validator: (val) {
                          if (val == null || val.trim().isEmpty) {
                            return 'Minimum watch percentage is required.';
                          }
                          final p = double.tryParse(val.trim());
                          if (p == null || p < 0.0 || p > 100.0) {
                            return 'Enter a valid percentage between 0 and 100.';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: AppSpacing.md),

                      // Is required toggle
                      SwitchListTile(
                        title: const Text('Required Lesson'),
                        subtitle: Text(
                          _isRequired
                              ? 'Learners must complete this lesson to satisfy assignment rules.'
                              : 'Optional lesson; learners are not blocked from completing the module.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        value: _isRequired,
                        onChanged: _isSubmitting
                            ? null
                            : (val) {
                                setState(() {
                                  _isRequired = val;
                                });
                                _markChanged();
                              },
                        contentPadding: EdgeInsets.zero,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.md),

                // Video File Selection Card
                CustomCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: AppSpacing.sm,
                        runSpacing: AppSpacing.xs,
                        children: [
                          Text(
                            _isEditing ? 'Video Media' : 'Video File *',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const StatusBadge(
                            text: 'MP4 / WebM / MOV',
                            status: BadgeStatus.info,
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        _isEditing
                            ? 'The existing video is preserved unless a replacement file is selected.'
                            : 'Select a video file to upload. Maximum size 2 GB.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),

                      // In edit mode: current video status
                      if (_isEditing) ...[
                        Container(
                          padding: const EdgeInsets.all(AppSpacing.sm),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                _currentHasVideo
                                    ? Icons.video_file
                                    : Icons.videocam_off_outlined,
                                color: _currentHasVideo
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.outline,
                              ),
                              const SizedBox(width: AppSpacing.sm),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _currentHasVideo
                                          ? 'Current Video Attached'
                                          : 'No Video Attached',
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                    if (_currentHasVideo &&
                                        _currentDurationSeconds > 0)
                                      Text(
                                        'Duration: ${_formatDuration(_currentDurationSeconds)}',
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: theme
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                            ),
                                      ),
                                  ],
                                ),
                              ),
                              if (_currentHasVideo)
                                const StatusBadge(
                                  text: 'ATTACHED',
                                  status: BadgeStatus.success,
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: AppSpacing.md),
                      ],

                      // Selected Video File details or picker button
                      if (_selectedVideoFile != null) ...[
                        Container(
                          padding: const EdgeInsets.all(AppSpacing.sm),
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: theme.colorScheme.primary,
                              width: 1.5,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.movie_outlined,
                                color: theme.colorScheme.primary,
                              ),
                              const SizedBox(width: AppSpacing.sm),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _selectedVideoFile!.name,
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.w600,
                                          ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    Text(
                                      _formatFileSize(
                                        _selectedVideoFile!.sizeInBytes,
                                      ),
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: AppSpacing.xs),
                              IconButton(
                                tooltip: _isEditing
                                    ? 'Remove replacement'
                                    : 'Remove file',
                                icon: const Icon(Icons.close, size: 20),
                                onPressed: _isSubmitting
                                    ? null
                                    : _removeSelectedVideo,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        Row(
                          children: [
                            OutlinedButton.icon(
                              onPressed: _isSubmitting ? null : _pickVideo,
                              icon: const Icon(
                                Icons.file_upload_outlined,
                                size: 18,
                              ),
                              label: const Text('Change file'),
                            ),
                          ],
                        ),
                      ] else ...[
                        OutlinedButton.icon(
                          onPressed: _isSubmitting ? null : _pickVideo,
                          icon: const Icon(Icons.video_call_outlined),
                          label: Text(
                            _isEditing
                                ? 'Choose Replacement Video'
                                : 'Choose Video File',
                          ),
                        ),
                      ],

                      if (fileFieldErr != null) ...[
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          fileFieldErr,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.error,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),

                // Form actions
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    TextButton(
                      onPressed: _isSubmitting
                          ? null
                          : () async {
                              final shouldDiscard = await _confirmDiscard();
                              if (shouldDiscard && context.mounted) {
                                if (context.canPop()) {
                                  context.pop();
                                }
                              }
                            },
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: _isSubmitting || (_isEditing && !_isDirty)
                          ? null
                          : _submitForm,
                      child: Text(
                        _isEditing ? 'Save Changes' : 'Create Video Lesson',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
