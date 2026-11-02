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

class AssessmentFormScreen extends ConsumerStatefulWidget {
  final int versionId;
  final int? assessmentId;
  final ManagedAssessment? initialAssessment;
  final ManagedVersionDetail? versionDetail;

  const AssessmentFormScreen({
    super.key,
    required this.versionId,
    this.assessmentId,
    this.initialAssessment,
    this.versionDetail,
  });

  @override
  ConsumerState<AssessmentFormScreen> createState() =>
      _AssessmentFormScreenState();
}

class _AssessmentFormScreenState extends ConsumerState<AssessmentFormScreen> {
  final _formKey = GlobalKey<FormState>();

  late String _kind;
  late TextEditingController _titleController;
  int? _selectedModuleId;
  late TextEditingController _sequenceController;
  late TextEditingController _passPercentageController;
  late TextEditingController _maxAttemptsController;
  late TextEditingController _timeLimitMinutesController;
  late bool _isRequired;

  bool _isSubmitting = false;
  CancelToken? _activeRequest;
  String? _serverError;
  Map<String, String> _fieldErrors = const {};

  bool _initialLoaded = false;
  String? _initialKind;
  String? _initialTitle;
  int? _initialModuleId;
  int? _initialSequence;
  String? _initialPassPercentage;
  int? _initialMaxAttempts;
  int? _initialTimeLimit;
  bool? _initialIsRequired;

  late String _account;

  bool get _isEditing => widget.assessmentId != null;

  bool get _isDirty {
    if (!_initialLoaded) return false;
    final currentTitle = _titleController.text.trim();
    final currentSeq = int.tryParse(_sequenceController.text.trim());
    final currentPass = _passPercentageController.text.trim();
    final currentAttempts = int.tryParse(_maxAttemptsController.text.trim());
    final currentTime = int.tryParse(_timeLimitMinutesController.text.trim());

    if (!_isEditing) {
      return _kind != 'QUIZ' ||
          currentTitle.isNotEmpty ||
          _selectedModuleId != null ||
          (currentSeq != null && currentSeq != 1) ||
          currentPass != '80.00' ||
          (currentAttempts != null && currentAttempts != 3) ||
          currentTime != null ||
          !_isRequired;
    }

    return _kind != _initialKind ||
        currentTitle != (_initialTitle ?? '') ||
        _selectedModuleId != _initialModuleId ||
        currentSeq != _initialSequence ||
        currentPass != (_initialPassPercentage ?? '80.00') ||
        currentAttempts != _initialMaxAttempts ||
        currentTime != _initialTimeLimit ||
        _isRequired != _initialIsRequired;
  }

  @override
  void initState() {
    super.initState();
    final auth = ref.read(authControllerProvider);
    _account = managementAccount(auth) ?? '';

    _kind = 'QUIZ';
    _titleController = TextEditingController();
    _sequenceController = TextEditingController(text: '1');
    _passPercentageController = TextEditingController(text: '80.00');
    _maxAttemptsController = TextEditingController(text: '3');
    _timeLimitMinutesController = TextEditingController();
    _isRequired = true;

    final initial = widget.initialAssessment;
    if (initial != null) {
      _populateFromAssessment(initial);
    } else if (!_isEditing) {
      _initialLoaded = true;
    }
  }

  void _populateFromAssessment(ManagedAssessment assessment) {
    _kind = assessment.kind.toUpperCase();
    _initialKind = _kind;
    _initialTitle = assessment.title;
    _initialModuleId = assessment.moduleId;
    _initialSequence = assessment.sequence;
    _initialPassPercentage = assessment.passPercentage;
    _initialMaxAttempts = assessment.maxAttempts;
    _initialTimeLimit = assessment.timeLimitMinutes;
    _initialIsRequired = assessment.isRequired;

    _titleController.text = assessment.title;
    _selectedModuleId = assessment.moduleId;
    _sequenceController.text = assessment.sequence.toString();
    _passPercentageController.text = assessment.passPercentage;
    _maxAttemptsController.text = assessment.maxAttempts.toString();
    _timeLimitMinutesController.text =
        assessment.timeLimitMinutes?.toString() ?? '';
    _isRequired = assessment.isRequired;
    _initialLoaded = true;
  }

  @override
  void dispose() {
    _activeRequest?.cancel('AssessmentFormScreen disposed');
    _titleController.dispose();
    _sequenceController.dispose();
    _passPercentageController.dispose();
    _maxAttemptsController.dispose();
    _timeLimitMinutesController.dispose();
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

  Future<bool> _onWillPop() async {
    if (!_isDirty || _isSubmitting) return true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text(
          'You have unsaved changes. Are you sure you want to discard them?',
        ),
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
    return discard ?? false;
  }

  Future<void> _submit() async {
    if (_isSubmitting) return;

    final auth = ref.read(authControllerProvider);
    final currentAccount = managementAccount(auth) ?? '';
    if (currentAccount != _account) {
      setState(() {
        _serverError =
            'Account context changed. Please reload the form to submit.';
      });
      return;
    }

    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }

    if (_kind == 'QUIZ' && _selectedModuleId == null) {
      setState(() {
        _fieldErrors = {
          ..._fieldErrors,
          'module_id': 'Module is required for a quiz.',
        };
      });
      return;
    }

    setState(() {
      _isSubmitting = true;
      _serverError = null;
      _fieldErrors = const {};
    });

    final cancelToken = CancelToken();
    _activeRequest = cancelToken;

    final title = _titleController.text.trim();
    final sequence = _kind == 'FINAL'
        ? 1
        : int.parse(_sequenceController.text.trim());
    final passPercentage =
        double.tryParse(_passPercentageController.text.trim()) ?? 80.00;
    final maxAttempts = int.tryParse(_maxAttemptsController.text.trim()) ?? 3;
    final timeLimitStr = _timeLimitMinutesController.text.trim();
    final timeLimit = timeLimitStr.isEmpty ? null : int.tryParse(timeLimitStr);
    final isRequired = _kind == 'FINAL' ? true : _isRequired;

    try {
      if (_isEditing) {
        await ref
            .read(assessmentMutationProvider)
            .update(
              versionId: widget.versionId,
              assessmentId: widget.assessmentId!,
              kind: _kind,
              title: title,
              moduleId: _kind == 'FINAL' ? null : _selectedModuleId,
              clearModuleId: _kind == 'FINAL',
              sequence: sequence,
              passPercentage: passPercentage,
              maxAttempts: maxAttempts,
              timeLimitMinutes: timeLimit,
              clearTimeLimit: timeLimit == null,
              isRequired: isRequired,
              cancelToken: cancelToken,
            );
        ref.invalidate(
          managedAssessmentDetailProvider((
            versionId: widget.versionId,
            assessmentId: widget.assessmentId!,
          )),
        );
      } else {
        await ref
            .read(assessmentMutationProvider)
            .create(
              versionId: widget.versionId,
              kind: _kind,
              title: title,
              moduleId: _kind == 'FINAL' ? null : _selectedModuleId,
              sequence: sequence,
              passPercentage: passPercentage,
              maxAttempts: maxAttempts,
              timeLimitMinutes: timeLimit,
              isRequired: isRequired,
              cancelToken: cancelToken,
            );
      }

      ref.invalidate(managedVersionAssessmentsProvider);
      ref.invalidate(managedVersionDetailProvider(widget.versionId));

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _isEditing
                  ? 'Assessment updated successfully.'
                  : 'Assessment created successfully.',
            ),
          ),
        );
        context.pop();
      }
    } on ApiError catch (error) {
      if (cancelToken.isCancelled) return;
      if (mounted) {
        setState(() {
          _fieldErrors = _fieldErrorsFrom(error);
          _serverError = _nonFieldErrorFrom(error) ?? error.message;
        });
      }
    } catch (e) {
      if (cancelToken.isCancelled) return;
      if (mounted) {
        setState(() {
          _serverError = 'An unexpected error occurred. Please try again.';
        });
      }
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
    final auth = ref.watch(authControllerProvider);
    final identity = auth is AuthAuthenticated ? auth.identity : null;

    final permitted = _isEditing
        ? (identity != null && canAccessAssessmentEditForm(identity))
        : (identity != null && canCreateAssessments(identity));

    if (!permitted) {
      return Scaffold(
        appBar: AppBar(
          title: Text(_isEditing ? 'Edit assessment' : 'Create assessment'),
        ),
        body: Center(
          child: Text(
            _isEditing
                ? 'You do not have permission to edit assessments.'
                : 'You do not have permission to create assessments.',
          ),
        ),
      );
    }

    final versionAsync = ref.watch(
      managedVersionDetailProvider(widget.versionId),
    );

    if (_isEditing && !_initialLoaded) {
      final assessmentAsync = ref.watch(
        managedAssessmentDetailProvider((
          versionId: widget.versionId,
          assessmentId: widget.assessmentId!,
        )),
      );

      return assessmentAsync.when(
        loading: () => Scaffold(
          appBar: AppBar(title: const Text('Edit assessment')),
          body: const Center(
            child: CardListSkeleton(message: 'Loading assessment...'),
          ),
        ),
        error: (error, _) => Scaffold(
          appBar: AppBar(title: const Text('Edit assessment')),
          body: ApiErrorView(
            error: error,
            onRetry: () => ref.refresh(
              managedAssessmentDetailProvider((
                versionId: widget.versionId,
                assessmentId: widget.assessmentId!,
              )).future,
            ),
          ),
        ),
        data: (assessment) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_initialLoaded) {
              setState(() {
                _populateFromAssessment(assessment);
              });
            }
          });
          return Scaffold(
            appBar: AppBar(title: const Text('Edit assessment')),
            body: const Center(
              child: CardListSkeleton(message: 'Initializing form...'),
            ),
          );
        },
      );
    }

    final modules =
        versionAsync.asData?.value.modules ??
        widget.versionDetail?.modules ??
        const [];

    return PopScope(
      canPop: !_isDirty || _isSubmitting,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final shouldPop = await _onWillPop();
        if (shouldPop && context.mounted) {
          context.pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_isEditing ? 'Edit assessment' : 'Create assessment'),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_serverError != null) ...[
                  Container(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.error_outline,
                          color: Theme.of(context).colorScheme.onErrorContainer,
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(
                            _serverError!,
                            style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onErrorContainer,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                ],
                CustomCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Assessment details',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: AppSpacing.md),

                      // Kind
                      DropdownButtonFormField<String>(
                        initialValue: _kind,
                        decoration: InputDecoration(
                          labelText: 'Assessment type *',
                          errorText: _fieldErrors['kind'],
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'QUIZ',
                            child: Text('Module quiz (QUIZ)'),
                          ),
                          DropdownMenuItem(
                            value: 'FINAL',
                            child: Text('Final assessment (FINAL)'),
                          ),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() {
                            _kind = value;
                            if (_kind == 'FINAL') {
                              _selectedModuleId = null;
                              _sequenceController.text = '1';
                              _isRequired = true;
                            }
                          });
                        },
                      ),
                      const SizedBox(height: AppSpacing.md),

                      // Title
                      TextFormField(
                        controller: _titleController,
                        maxLength: 200,
                        decoration: InputDecoration(
                          labelText: 'Title *',
                          hintText: 'e.g. Module 1 Knowledge Check',
                          errorText: _fieldErrors['title'],
                        ),
                        validator: (value) {
                          final v = value?.trim() ?? '';
                          if (v.isEmpty) return 'Title is required.';
                          if (v.length > 200) {
                            return 'Title cannot exceed 200 characters.';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: AppSpacing.md),

                      // Module (only if QUIZ)
                      if (_kind == 'QUIZ') ...[
                        DropdownButtonFormField<int>(
                          initialValue: _selectedModuleId,
                          decoration: InputDecoration(
                            labelText: 'Module *',
                            errorText:
                                _fieldErrors['module_id'] ??
                                _fieldErrors['module'],
                          ),
                          items: modules
                              .map(
                                (m) => DropdownMenuItem(
                                  value: m.id,
                                  child: Text('Module ${m.order}: ${m.title}'),
                                ),
                              )
                              .toList(),
                          onChanged: (val) {
                            setState(() {
                              _selectedModuleId = val;
                            });
                          },
                          validator: (val) {
                            if (_kind == 'QUIZ' && val == null) {
                              return 'Please select a module.';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: AppSpacing.md),
                        TextFormField(
                          controller: _sequenceController,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: 'Sequence *',
                            hintText: 'e.g. 1',
                            errorText: _fieldErrors['sequence'],
                          ),
                          validator: (value) {
                            if (_kind == 'FINAL') return null;
                            final v = int.tryParse(value?.trim() ?? '');
                            if (v == null || v < 1) {
                              return 'Sequence must be an integer >= 1.';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: AppSpacing.md),
                      ],

                      // Pass Percentage
                      TextFormField(
                        controller: _passPercentageController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          labelText: 'Pass percentage (0 - 100) *',
                          hintText: 'e.g. 80.00',
                          errorText: _fieldErrors['pass_percentage'],
                        ),
                        validator: (value) {
                          final v = double.tryParse(value?.trim() ?? '');
                          if (v == null || v < 0 || v > 100) {
                            return 'Enter a valid percentage between 0 and 100.';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: AppSpacing.md),

                      // Max Attempts
                      TextFormField(
                        controller: _maxAttemptsController,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: 'Max attempts *',
                          hintText: 'e.g. 3',
                          errorText: _fieldErrors['max_attempts'],
                        ),
                        validator: (value) {
                          final v = int.tryParse(value?.trim() ?? '');
                          if (v == null || v < 1) {
                            return 'Max attempts must be >= 1.';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: AppSpacing.md),

                      // Time Limit Minutes (Optional)
                      TextFormField(
                        controller: _timeLimitMinutesController,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: 'Time limit in minutes (optional)',
                          hintText: 'Leave empty for no limit',
                          errorText: _fieldErrors['time_limit_minutes'],
                        ),
                        validator: (value) {
                          final str = value?.trim() ?? '';
                          if (str.isEmpty) return null;
                          final v = int.tryParse(str);
                          if (v == null || v < 1) {
                            return 'Time limit must be >= 1 minute.';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: AppSpacing.md),

                      // Is Required
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Required to pass training'),
                        subtitle: Text(
                          _kind == 'FINAL'
                              ? 'Final assessments are always required.'
                              : 'Must be completed to satisfy module requirements.',
                        ),
                        value: _kind == 'FINAL' ? true : _isRequired,
                        onChanged: _kind == 'FINAL'
                            ? null
                            : (val) {
                                setState(() {
                                  _isRequired = val;
                                });
                              },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                FilledButton.icon(
                  onPressed: _isSubmitting ? null : _submit,
                  icon: _isSubmitting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.save),
                  label: Text(
                    _isEditing ? 'Save changes' : 'Create assessment',
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                OutlinedButton(
                  onPressed: _isSubmitting
                      ? null
                      : () async {
                          final shouldPop = await _onWillPop();
                          if (shouldPop && context.mounted) {
                            context.pop();
                          }
                        },
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
