import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
import 'package:training_app/core/presentation/components/content_skeleton.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';
import 'package:training_app/features/management/presentation/controllers/management_controller.dart';

class TextLessonFormScreen extends ConsumerStatefulWidget {
  final int versionId;
  final int moduleId;
  final int? lessonId;
  final dynamic initialLesson;
  final int? suggestedPosition;

  const TextLessonFormScreen({
    super.key,
    required this.versionId,
    required this.moduleId,
    this.lessonId,
    this.initialLesson,
    this.suggestedPosition,
  });

  @override
  ConsumerState<TextLessonFormScreen> createState() =>
      _TextLessonFormScreenState();
}

class _TextLessonFormScreenState extends ConsumerState<TextLessonFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _positionController;
  late final TextEditingController _bodyController;
  bool _isRequired = true;

  bool _isSubmitting = false;
  CancelToken? _activeRequest;
  String? _serverError;
  Map<String, String> _fieldErrors = const {};

  bool _initialLoaded = false;
  String? _initialTitle;
  int? _initialPosition;
  String? _initialBody;
  bool? _initialIsRequired;

  late String _account;

  bool get _isEditing => widget.lessonId != null;

  bool get _isVideoLesson {
    final initial = widget.initialLesson;
    if (initial is ManagedLessonSummary &&
        initial.lessonType.toUpperCase() == 'VIDEO') {
      return true;
    }
    return false;
  }

  bool get _isDirty {
    if (!_initialLoaded) return false;
    final currentTitle = _titleController.text.trim();
    final currentPos = int.tryParse(_positionController.text.trim());
    final currentBody = _bodyController.text;

    if (!_isEditing) {
      return currentTitle.isNotEmpty ||
          currentBody.isNotEmpty ||
          (currentPos != null &&
              currentPos != (widget.suggestedPosition ?? 1)) ||
          !_isRequired;
    }

    return currentTitle != (_initialTitle ?? '') ||
        currentPos != _initialPosition ||
        currentBody != (_initialBody ?? '') ||
        _isRequired != _initialIsRequired;
  }

  @override
  void initState() {
    super.initState();
    final auth = ref.read(authControllerProvider);
    _account = managementAccount(auth) ?? '';

    _titleController = TextEditingController();
    _positionController = TextEditingController();
    _bodyController = TextEditingController();

    final initial = widget.initialLesson;
    if (initial is ManagedTextLessonDetail) {
      _populateFromDetail(initial);
    } else if (initial is ManagedLessonSummary) {
      _initialTitle = initial.title;
      _initialPosition = initial.order;
      _initialIsRequired = initial.isRequired;
      _isRequired = initial.isRequired;

      _titleController.text = initial.title;
      _positionController.text = initial.order.toString();
      // In edit mode with summary, body must still be loaded from detail API
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

  void _populateFromDetail(ManagedTextLessonDetail detail) {
    if (_initialLoaded) return;
    _initialTitle = detail.title;
    _initialPosition = detail.position;
    _initialBody = detail.body;
    _initialIsRequired = detail.isRequired;

    _titleController.text = detail.title;
    _positionController.text = detail.position.toString();
    _bodyController.text = detail.body;
    _isRequired = detail.isRequired;
    _initialLoaded = true;
  }

  @override
  void dispose() {
    _activeRequest?.cancel('Form disposed');
    _titleController.dispose();
    _positionController.dispose();
    _bodyController.dispose();
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

  Future<bool> _confirmDiscard() async {
    if (!_isDirty || _isSubmitting) return true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Discard unsaved changes?'),
        content: const Text(
          'You have unsaved edits in this text lesson form. Leaving will discard them.',
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
    return confirmed ?? false;
  }

  Future<void> _submitForm() async {
    setState(() {
      _serverError = null;
      _fieldErrors = const {};
    });

    if (!_formKey.currentState!.validate()) return;

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
    final body = _bodyController.text;
    final position = int.tryParse(_positionController.text.trim()) ?? 1;

    // Check if edit is unchanged
    if (_isEditing && !_isDirty) {
      if (mounted) context.pop();
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    final cancelToken = CancelToken();
    _activeRequest = cancelToken;

    try {
      final controller = ref.read(textLessonMutationProvider);
      if (_isEditing) {
        await controller.update(
          versionId: widget.versionId,
          moduleId: widget.moduleId,
          lessonId: widget.lessonId!,
          title: title != _initialTitle ? title : null,
          body: body != _initialBody ? body : null,
          position: position != _initialPosition ? position : null,
          isRequired: _isRequired != _initialIsRequired ? _isRequired : null,
          cancelToken: cancelToken,
        );
      } else {
        await controller.create(
          versionId: widget.versionId,
          moduleId: widget.moduleId,
          title: title,
          body: body,
          position: position,
          isRequired: _isRequired,
          cancelToken: cancelToken,
        );
      }

      if (!mounted) return;

      ref.invalidate(managedVersionDetailProvider(widget.versionId));
      ref.invalidate(
        managedModuleDetailProvider((
          versionId: widget.versionId,
          moduleId: widget.moduleId,
        )),
      );
      if (_isEditing) {
        ref.invalidate(
          managedTextLessonDetailProvider((
            versionId: widget.versionId,
            moduleId: widget.moduleId,
            lessonId: widget.lessonId!,
          )),
        );
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _isEditing
                ? 'Text lesson updated successfully.'
                : 'Text lesson "$title" created successfully.',
          ),
        ),
      );
      context.pop(true);
    } catch (error) {
      if (!mounted) return;
      if (cancelToken.isCancelled) return;

      final parsed = error is ApiError ? error : ApiError.unexpected();
      final fields = _fieldErrorsFrom(parsed);

      setState(() {
        _fieldErrors = fields;
        if (parsed.statusCode == 409) {
          _serverError = 'That position was taken by another edit. Refresh and choose an unused position.';
        } else if (parsed.statusCode == 404) {
          _serverError = 'The curriculum version, module, or lesson was not found, or is no longer in draft.';
        } else if (parsed.statusCode == 403) {
          _serverError =
              'You do not have permission to ${_isEditing ? "edit" : "create"} lessons.';
        } else {
          _serverError = _nonFieldErrorFrom(parsed) ?? parsed.message;
        }
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isVideoLesson) {
      return Scaffold(
        appBar: AppBar(title: const Text('Edit lesson')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(AppSpacing.lg),
            child: Text(
              'Video lessons cannot be edited through text lesson authoring.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    ref.listen<AuthState>(authControllerProvider, (_, next) {
      if (managementAccount(next) != _account) {
        _activeRequest?.cancel('Account changed');
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
          title: Text(_isEditing ? 'Edit text lesson' : 'New text lesson'),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Text(
              _isEditing
                  ? 'You do not have permission to edit lessons.'
                  : 'You do not have permission to create lessons.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    if (_isEditing && !_initialLoaded) {
      final asyncDetail = ref.watch(
        managedTextLessonDetailProvider((
          versionId: widget.versionId,
          moduleId: widget.moduleId,
          lessonId: widget.lessonId!,
        )),
      );
      return asyncDetail.when(
        loading: () => Scaffold(
          appBar: AppBar(title: const Text('Edit text lesson')),
          body: const Center(
            child: CardListSkeleton(
              message: 'Loading lesson details',
              compact: true,
            ),
          ),
        ),
        error: (error, _) => Scaffold(
          appBar: AppBar(title: const Text('Edit text lesson')),
          body: ApiErrorView(
            error: error,
            onRetry: () => ref.refresh(
              managedTextLessonDetailProvider((
                versionId: widget.versionId,
                moduleId: widget.moduleId,
                lessonId: widget.lessonId!,
              )).future,
            ),
          ),
        ),
        data: (detail) {
          if (detail.contentType.toUpperCase() != 'TEXT') {
            return Scaffold(
              appBar: AppBar(title: const Text('Edit lesson')),
              body: const Center(
                child: Padding(
                  padding: EdgeInsets.all(AppSpacing.lg),
                  child: Text(
                    'Video lessons cannot be edited through text lesson authoring.',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            );
          }
          _populateFromDetail(detail);
          return _buildForm(context);
        },
      );
    }

    return _buildForm(context);
  }

  Widget _buildForm(BuildContext context) {
    final theme = Theme.of(context);

    return PopScope(
      canPop: !_isDirty || _isSubmitting,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final shouldPop = await _confirmDiscard();
        if (shouldPop && context.mounted) {
          context.pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_isEditing ? 'Edit text lesson' : 'New text lesson'),
        ),
        body: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            CustomCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.article_outlined,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          _isEditing ? 'Lesson Settings' : 'Lesson Details',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'Plain text learning material. Markdown/formatting is stored and displayed as literal text. Positions are unique within this module.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            if (_serverError != null) ...[
              Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.error_outline,
                      color: theme.colorScheme.onErrorContainer,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        _serverError!,
                        style: TextStyle(
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
            Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextFormField(
                    controller: _titleController,
                    decoration: InputDecoration(
                      labelText: 'Lesson Title *',
                      hintText: 'e.g. Pre-operation Safety Checklist',
                      errorText: _fieldErrors['title'],
                      border: const OutlineInputBorder(),
                    ),
                    maxLength: 200,
                    enabled: !_isSubmitting,
                    onChanged: (_) => _markChanged(),
                    validator: (val) {
                      final trimmed = val?.trim() ?? '';
                      if (trimmed.isEmpty) return 'Lesson title is required.';
                      if (trimmed.length > 200) {
                        return 'Lesson title cannot exceed 200 characters.';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _positionController,
                          decoration: InputDecoration(
                            labelText: 'Position *',
                            hintText: '1, 2, 3...',
                            helperText:
                                'Positive integer ordering within this module.',
                            errorText: _fieldErrors['position'],
                            border: const OutlineInputBorder(),
                          ),
                          keyboardType: TextInputType.number,
                          enabled: !_isSubmitting,
                          onChanged: (_) => _markChanged(),
                          validator: (val) {
                            final trimmed = val?.trim() ?? '';
                            if (trimmed.isEmpty) return 'Position is required.';
                            final parsed = int.tryParse(trimmed);
                            if (parsed == null || parsed < 1) {
                              return 'Position must be a positive integer.';
                            }
                            if (parsed > 2147483647) {
                              return 'Position value is too large.';
                            }
                            return null;
                          },
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      IconButton.outlined(
                        tooltip: 'Decrease position',
                        icon: const Icon(Icons.remove),
                        onPressed: _isSubmitting
                            ? null
                            : () {
                                final cur =
                                    int.tryParse(_positionController.text) ?? 1;
                                if (cur > 1) {
                                  _positionController.text = (cur - 1)
                                      .toString();
                                  _markChanged();
                                }
                              },
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      IconButton.outlined(
                        tooltip: 'Increase position',
                        icon: const Icon(Icons.add),
                        onPressed: _isSubmitting
                            ? null
                            : () {
                                final cur =
                                    int.tryParse(_positionController.text) ?? 0;
                                _positionController.text = (cur + 1).toString();
                                _markChanged();
                              },
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  SwitchListTile(
                    title: const Text('Required lesson'),
                    subtitle: const Text(
                      'Learners must complete this lesson to advance.',
                    ),
                    value: _isRequired,
                    onChanged: _isSubmitting
                        ? null
                        : (val) {
                            _isRequired = val;
                            _markChanged();
                          },
                    contentPadding: EdgeInsets.zero,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  TextFormField(
                    controller: _bodyController,
                    decoration: InputDecoration(
                      labelText: 'Lesson Body (plain text) *',
                      hintText: 'Enter complete training content, guidelines, and instructions...',
                      errorText: _fieldErrors['body'],
                      border: const OutlineInputBorder(),
                      alignLabelWithHint: true,
                    ),
                    maxLines: 12,
                    minLines: 6,
                    enabled: !_isSubmitting,
                    onChanged: (_) => _markChanged(),
                    validator: (val) {
                      final trimmed = val?.trim() ?? '';
                      if (trimmed.isEmpty) return 'Lesson body is required.';
                      return null;
                    },
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  FilledButton.icon(
                    onPressed: _isSubmitting || (_isEditing && !_isDirty)
                        ? null
                        : _submitForm,
                    icon: _isSubmitting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.save_outlined),
                    label: Text(
                      _isSubmitting
                          ? 'Saving...'
                          : (_isEditing ? 'Save Changes' : 'Create Lesson'),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  OutlinedButton(
                    onPressed: _isSubmitting
                        ? null
                        : () async {
                            final shouldPop = await _confirmDiscard();
                            if (shouldPop && context.mounted) {
                              context.pop();
                            }
                          },
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
