import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
import 'package:training_app/core/presentation/components/cinematic_components.dart';
import 'package:training_app/core/presentation/components/content_skeleton.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';
import 'package:training_app/features/management/presentation/controllers/management_controller.dart';

class TrainingCourseFormScreen extends ConsumerStatefulWidget {
  final int? trainingId;
  final ManagedTraining? initialTraining;

  const TrainingCourseFormScreen({
    super.key,
    this.trainingId,
    this.initialTraining,
  });

  @override
  ConsumerState<TrainingCourseFormScreen> createState() =>
      _TrainingCourseFormScreenState();
}

class _TrainingCourseFormScreenState
    extends ConsumerState<TrainingCourseFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _codeController;
  late final TextEditingController _catalogTitleController;
  late final TextEditingController _descriptionController;

  late final String? _account;
  String _originalCode = '';
  String _originalTitle = '';
  String _originalDescription = '';
  bool _originalActive = true;
  bool _isActive = true;
  bool _isSaving = false;
  CancelToken? _activeRequest;
  String? _serverError;
  String? _serverValidationError;
  Map<String, String> _fieldErrors = const {};
  bool _initialLoaded = false;

  bool get _isEditing => widget.trainingId != null;

  bool get _isDirty =>
      _codeController.text.trim() != _originalCode ||
      _catalogTitleController.text.trim() != _originalTitle ||
      _descriptionController.text.trim() != _originalDescription ||
      _isActive != _originalActive;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialTraining;
    _codeController = TextEditingController(text: initial?.code ?? '');
    _catalogTitleController = TextEditingController(text: initial?.title ?? '');
    _descriptionController = TextEditingController(
      text: initial?.description ?? '',
    );
    if (initial != null) {
      _originalCode = initial.code;
      _originalTitle = initial.title;
      _originalDescription = initial.description;
      _originalActive = initial.isActive;
      _isActive = initial.isActive;
      _initialLoaded = true;
    } else if (!_isEditing) {
      _initialLoaded = true;
    }
    _account = managementAccount(ref.read(authControllerProvider));
  }

  void _populateFromLoaded(ManagedTraining course) {
    if (_initialLoaded) return;
    _codeController.text = course.code;
    _catalogTitleController.text = course.title;
    _descriptionController.text = course.description;
    _originalCode = course.code;
    _originalTitle = course.title;
    _originalDescription = course.description;
    _originalActive = course.isActive;
    _isActive = course.isActive;
    _initialLoaded = true;
  }

  @override
  void dispose() {
    _activeRequest?.cancel('Form disposed');
    _codeController.dispose();
    _catalogTitleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  void _markChanged() {
    setState(() {
      _serverError = null;
      _serverValidationError = null;
      _fieldErrors = const {};
    });
  }

  Map<String, String> _fieldErrorsFrom(ApiError error) {
    final details = error.details;
    if (details is! Map) return const {};
    final result = <String, String>{};
    for (final field in ['code', 'catalog_title', 'description', 'is_active']) {
      final value = details[field];
      if (value is String && value.isNotEmpty) {
        result[field] = value;
      } else if (value is List && value.isNotEmpty) {
        result[field] = value.map((item) => item.toString()).join(' ');
      }
    }
    return result;
  }

  String? _nonFieldErrorFrom(ApiError error) {
    final details = error.details;
    if (details is! Map) return null;
    final value = details['non_field_errors'];
    if (value is String && value.isNotEmpty) return value;
    if (value is List && value.isNotEmpty) {
      return value.map((item) => item.toString()).join(' ');
    }
    return null;
  }

  String? _fieldError(String key) => _fieldErrors[key];

  Future<void> _leave() async {
    if (!_isDirty || _isSaving) {
      if (mounted) context.pop();
      return;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('Your unsaved course changes will be lost.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) context.pop();
  }

  void _onPopInvoked(bool didPop, Object? result) {
    if (!didPop && !_isSaving) _leave();
  }

  Future<void> _save() async {
    if (_isSaving || (_isEditing && !_isDirty)) return;
    if (!_formKey.currentState!.validate()) return;

    final auth = ref.read(authControllerProvider);
    final allowed =
        auth is AuthAuthenticated &&
        managementAccount(auth) == _account &&
        (_isEditing
            ? canEditTraining(auth.identity)
            : canCreateTraining(auth.identity));
    if (!allowed) {
      setState(() {
        _serverError =
            'Your account or permissions changed. Reopen the form to continue.';
      });
      return;
    }

    final request = CancelToken();
    _activeRequest = request;
    setState(() {
      _isSaving = true;
      _serverError = null;
      _serverValidationError = null;
      _fieldErrors = const {};
    });

    try {
      final mutationController = ref.read(trainingCourseMutationProvider);
      if (_isEditing) {
        await mutationController.update(
          widget.trainingId!,
          code: _codeController.text.trim(),
          catalogTitle: _catalogTitleController.text.trim(),
          description: _descriptionController.text.trim(),
          isActive: _isActive,
          cancelToken: request,
        );
        ref.invalidate(managedTrainingDetailProvider(widget.trainingId!));
      } else {
        await mutationController.create(
          code: _codeController.text.trim(),
          catalogTitle: _catalogTitleController.text.trim(),
          description: _descriptionController.text.trim(),
          isActive: _isActive,
          cancelToken: request,
        );
      }
      ref.invalidate(managedTrainingsProvider);

      if (!mounted ||
          request.isCancelled ||
          managementAccount(ref.read(authControllerProvider)) != _account) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _isEditing
                ? 'Course updated successfully.'
                : 'Training course created successfully.',
          ),
        ),
      );
      context.pop(true);
    } catch (error) {
      if (!mounted || request.isCancelled) return;
      final apiError = error is ApiError ? error : ApiError.unexpected();
      if (apiError.statusCode == 401) {
        await ref.read(authControllerProvider.notifier).logout();
        return;
      }
      setState(() {
        _serverError = apiError.statusCode == 403
            ? 'You are not authorized to ${_isEditing ? 'edit' : 'create'} this course.'
            : apiError.message;
        _serverValidationError = apiError.statusCode == 403
            ? null
            : _nonFieldErrorFrom(apiError);
        _fieldErrors = _fieldErrorsFrom(apiError);
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
          if (identical(_activeRequest, request)) _activeRequest = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
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
            ? canEditTraining(auth.identity)
            : canCreateTraining(auth.identity));

    if (!permitted) {
      return Scaffold(
        appBar: AppBar(title: Text(_isEditing ? 'Edit course' : 'New course')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Text(
              _isEditing
                  ? 'You do not have permission to edit training courses.'
                  : 'You do not have permission to create training courses.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    if (_isEditing && !_initialLoaded) {
      final asyncCourse = ref.watch(
        managedTrainingDetailProvider(widget.trainingId!),
      );
      return asyncCourse.when(
        loading: () => Scaffold(
          appBar: AppBar(title: const Text('Edit course')),
          body: const Center(
            child: CardListSkeleton(
              message: 'Loading course details',
              compact: true,
            ),
          ),
        ),
        error: (error, _) => Scaffold(
          appBar: AppBar(title: const Text('Edit course')),
          body: ApiErrorView(
            error: error,
            onRetry: () => ref.refresh(
              managedTrainingDetailProvider(widget.trainingId!).future,
            ),
          ),
        ),
        data: (course) {
          _populateFromLoaded(course);
          return _buildForm(context);
        },
      );
    }

    return _buildForm(context);
  }

  Widget _buildForm(BuildContext context) {
    final theme = Theme.of(context);

    return PopScope(
      canPop: !_isDirty || _isSaving,
      onPopInvokedWithResult: (didPop, result) => _onPopInvoked(didPop, result),
      child: Scaffold(
        appBar: AppBar(
          title: Text(_isEditing ? 'Edit course' : 'New course'),
          leading: IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Cancel',
            onPressed: _isSaving ? null : _leave,
          ),
        ),
        body: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              CinematicHero(
                eyebrow: 'Curriculum authoring',
                title: _isEditing ? 'Edit course' : 'New training course',
                subtitle: _isEditing
                    ? 'Update course specifications and active training status.'
                    : 'Register a new training course in the catalog.',
                icon: Icons.school_outlined,
              ),
              const SizedBox(height: AppSpacing.lg),

              if (_serverError != null) ...[
                Container(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline, color: theme.colorScheme.error),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          _serverError!,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onErrorContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
              ],

              if (_serverValidationError != null) ...[
                Container(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _serverValidationError!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
              ],

              const SectionHeading(
                'Course specifications',
                subtitle: 'Unique identifier, catalog title, and descriptions.',
              ),
              CustomCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextFormField(
                      controller: _codeController,
                      enabled: !_isSaving,
                      maxLength: 40,
                      decoration: InputDecoration(
                        labelText: 'Course code *',
                        hintText: 'e.g. TR-FORK-001',
                        helperText: 'Unique identifier, up to 40 characters.',
                        errorText: _fieldError('code'),
                      ),
                      onChanged: (_) => _markChanged(),
                      validator: (value) {
                        final trimmed = value?.trim() ?? '';
                        if (trimmed.isEmpty) {
                          return 'Course code is required.';
                        }
                        if (trimmed.length > 40) {
                          return 'Course code must be 40 characters or fewer.';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextFormField(
                      controller: _catalogTitleController,
                      enabled: !_isSaving,
                      maxLength: 200,
                      decoration: InputDecoration(
                        labelText: 'Course title *',
                        hintText: 'e.g. Forklift Operations & Safety',
                        helperText:
                            'Display title in catalog, up to 200 characters.',
                        errorText: _fieldError('catalog_title'),
                      ),
                      onChanged: (_) => _markChanged(),
                      validator: (value) {
                        final trimmed = value?.trim() ?? '';
                        if (trimmed.isEmpty) {
                          return 'Course title is required.';
                        }
                        if (trimmed.length > 200) {
                          return 'Course title must be 200 characters or fewer.';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextFormField(
                      controller: _descriptionController,
                      enabled: !_isSaving,
                      maxLines: 3,
                      decoration: InputDecoration(
                        labelText: 'Description',
                        hintText: 'Course overview, prerequisites, and learning goals...',
                        errorText: _fieldError('description'),
                      ),
                      onChanged: (_) => _markChanged(),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Active for training'),
                      subtitle: const Text(
                        'Active courses can be assigned to employees once published.',
                      ),
                      value: _isActive,
                      onChanged: _isSaving
                          ? null
                          : (val) {
                              setState(() {
                                _isActive = val;
                                _markChanged();
                              });
                            },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.xl),

              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _isSaving ? null : _leave,
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _isSaving || (_isEditing && !_isDirty)
                          ? null
                          : _save,
                      icon: _isSaving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(_isEditing ? Icons.save : Icons.add),
                      label: Text(
                        _isEditing ? 'Save changes' : 'Create course',
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
