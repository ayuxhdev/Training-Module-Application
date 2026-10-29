import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/presentation/components/cinematic_components.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/presentation/controllers/management_controller.dart';

class DraftVersionFormScreen extends ConsumerStatefulWidget {
  final int trainingId;
  final String? courseTitle;

  const DraftVersionFormScreen({
    super.key,
    required this.trainingId,
    this.courseTitle,
  });

  @override
  ConsumerState<DraftVersionFormScreen> createState() =>
      _DraftVersionFormScreenState();
}

class _DraftVersionFormScreenState
    extends ConsumerState<DraftVersionFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _learningObjectivesController = TextEditingController();
  final _changeSummaryController = TextEditingController();

  late final String? _account;
  bool _isSaving = false;
  CancelToken? _activeRequest;
  String? _serverError;
  String? _serverValidationError;
  Map<String, String> _fieldErrors = const {};

  bool get _isDirty =>
      _titleController.text.trim().isNotEmpty ||
      _descriptionController.text.trim().isNotEmpty ||
      _learningObjectivesController.text.trim().isNotEmpty ||
      _changeSummaryController.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _account = managementAccount(ref.read(authControllerProvider));
  }

  @override
  void dispose() {
    _activeRequest?.cancel('Form disposed');
    _titleController.dispose();
    _descriptionController.dispose();
    _learningObjectivesController.dispose();
    _changeSummaryController.dispose();
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
    for (final field in [
      'title',
      'description',
      'learning_objectives',
      'change_summary',
    ]) {
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
        title: const Text('Discard draft version?'),
        content: const Text('Your unsaved version details will be lost.'),
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
    if (_isSaving) return;
    if (!_formKey.currentState!.validate()) return;

    final auth = ref.read(authControllerProvider);
    final allowed =
        auth is AuthAuthenticated &&
        managementAccount(auth) == _account &&
        canCreateVersions(auth.identity);
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
      final mutationController = ref.read(draftVersionMutationProvider);
      await mutationController.create(
        trainingId: widget.trainingId,
        title: _titleController.text.trim(),
        description: _descriptionController.text.trim(),
        learningObjectives: _learningObjectivesController.text.trim(),
        changeSummary: _changeSummaryController.text.trim(),
        cancelToken: request,
      );

      // Invalidate affected providers
      ref.invalidate(managedTrainingDetailProvider(widget.trainingId));
      ref.invalidate(managedTrainingsProvider);
      ref.invalidate(allTrainingVersionsProvider);
      ref.invalidate(managedTrainingVersionsProvider);

      if (!mounted ||
          request.isCancelled ||
          managementAccount(ref.read(authControllerProvider)) != _account) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Draft version created successfully.')),
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
        if (apiError.statusCode == 409) {
          _serverError = 'Another author created that version. Refresh the version history and try again.';
        } else if (apiError.statusCode == 403) {
          _serverError =
              'You are not authorized to create draft training versions.';
        } else {
          _serverError = apiError.message;
        }
        _serverValidationError =
            apiError.statusCode == 403 || apiError.statusCode == 409
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
        canCreateVersions(auth.identity);

    if (!permitted) {
      return Scaffold(
        appBar: AppBar(title: const Text('New draft version')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(AppSpacing.lg),
            child: Text(
              'You do not have permission to create draft training versions.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final theme = Theme.of(context);
    final courseDisplay =
        widget.courseTitle != null && widget.courseTitle!.isNotEmpty
        ? widget.courseTitle!
        : 'Course #${widget.trainingId}';

    return PopScope(
      canPop: !_isDirty || _isSaving,
      onPopInvokedWithResult: (didPop, result) => _onPopInvoked(didPop, result),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('New draft version'),
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
                eyebrow: 'Curriculum versioning',
                title: 'New draft version',
                subtitle:
                    'Author a new DRAFT curriculum version for $courseDisplay.',
                icon: Icons.post_add_outlined,
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

              // Versioning policy notice
              CustomCard(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline,
                      color: theme.colorScheme.primary,
                      size: 20,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        'Version numbers are allocated sequentially by the server upon creation. '
                        'New versions start in editable DRAFT status.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),

              const SectionHeading(
                'Version specifications',
                subtitle: 'Version title, objectives, and changelog summary.',
              ),
              CustomCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextFormField(
                      controller: _titleController,
                      enabled: !_isSaving,
                      maxLength: 200,
                      decoration: InputDecoration(
                        labelText: 'Version title *',
                        hintText: 'e.g. Workplace Safety Fundamentals 2026',
                        helperText: 'Display title for this version, up to 200 characters.',
                        errorText: _fieldError('title'),
                      ),
                      onChanged: (_) => _markChanged(),
                      validator: (value) {
                        final trimmed = value?.trim() ?? '';
                        if (trimmed.isEmpty) {
                          return 'Version title is required.';
                        }
                        if (trimmed.length > 200) {
                          return 'Version title must be 200 characters or fewer.';
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
                        hintText: 'Detailed curriculum overview and target audience...',
                        errorText: _fieldError('description'),
                      ),
                      onChanged: (_) => _markChanged(),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextFormField(
                      controller: _learningObjectivesController,
                      enabled: !_isSaving,
                      maxLines: 3,
                      decoration: InputDecoration(
                        labelText: 'Learning objectives',
                        hintText: 'Target skills, competencies, and compliance criteria...',
                        errorText: _fieldError('learning_objectives'),
                      ),
                      onChanged: (_) => _markChanged(),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextFormField(
                      controller: _changeSummaryController,
                      enabled: !_isSaving,
                      maxLines: 3,
                      decoration: InputDecoration(
                        labelText: 'Change summary',
                        hintText: 'Summary of revisions compared to earlier versions...',
                        errorText: _fieldError('change_summary'),
                      ),
                      onChanged: (_) => _markChanged(),
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
                      onPressed: _isSaving ? null : _save,
                      icon: _isSaving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.add),
                      label: const Text('Create draft version'),
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
