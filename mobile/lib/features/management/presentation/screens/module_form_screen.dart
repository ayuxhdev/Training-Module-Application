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

class ModuleFormScreen extends ConsumerStatefulWidget {
  final int versionId;
  final int? moduleId;
  final ManagedModule? initialModule;
  final int? suggestedPosition;

  const ModuleFormScreen({
    super.key,
    required this.versionId,
    this.moduleId,
    this.initialModule,
    this.suggestedPosition,
  });

  @override
  ConsumerState<ModuleFormScreen> createState() => _ModuleFormScreenState();
}

class _ModuleFormScreenState extends ConsumerState<ModuleFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _titleController;
  late TextEditingController _descriptionController;
  late TextEditingController _positionController;

  bool _isSubmitting = false;
  CancelToken? _activeRequest;
  String? _serverError;
  Map<String, String> _fieldErrors = const {};

  bool _initialLoaded = false;
  String? _initialTitle;
  String? _initialDescription;
  int? _initialPosition;

  late String _account;

  bool get _isEditing => widget.moduleId != null;

  bool get _isDirty {
    if (!_initialLoaded) return false;
    final currentTitle = _titleController.text.trim();
    final currentDesc = _descriptionController.text.trim();
    final currentPos = int.tryParse(_positionController.text.trim());

    if (!_isEditing) {
      return currentTitle.isNotEmpty ||
          currentDesc.isNotEmpty ||
          (currentPos != null && currentPos != (widget.suggestedPosition ?? 1));
    }

    return currentTitle != (_initialTitle ?? '') ||
        currentDesc != (_initialDescription ?? '') ||
        currentPos != _initialPosition;
  }

  @override
  void initState() {
    super.initState();
    final auth = ref.read(authControllerProvider);
    _account = managementAccount(auth) ?? '';

    final initial = widget.initialModule;
    if (initial != null) {
      _populateFromSummary(initial);
    } else if (!_isEditing) {
      _titleController = TextEditingController();
      _descriptionController = TextEditingController();
      _positionController = TextEditingController(
        text: (widget.suggestedPosition ?? 1).toString(),
      );
      _initialLoaded = true;
    } else {
      _titleController = TextEditingController();
      _descriptionController = TextEditingController();
      _positionController = TextEditingController();
    }
  }

  void _populateFromSummary(ManagedModule module) {
    _initialTitle = module.title;
    _initialDescription = module.description;
    _initialPosition = module.order;

    _titleController = TextEditingController(text: module.title);
    _descriptionController = TextEditingController(text: module.description);
    _positionController = TextEditingController(text: module.order.toString());
    _initialLoaded = true;
  }

  void _populateFromDetail(ManagedModuleDetail detail) {
    if (_initialLoaded) return;
    _initialTitle = detail.title;
    _initialDescription = detail.description;
    _initialPosition = detail.position;

    _titleController.text = detail.title;
    _descriptionController.text = detail.description;
    _positionController.text = detail.position.toString();
    _initialLoaded = true;
  }

  @override
  void dispose() {
    _activeRequest?.cancel('Form disposed');
    _titleController.dispose();
    _descriptionController.dispose();
    _positionController.dispose();
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

  Future<bool> _confirmDiscard() async {
    if (!_isDirty || _isSubmitting) return true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Discard unsaved changes?'),
        content: const Text(
          'You have unsaved edits in this module form. Leaving will discard them.',
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
            ? canEditModules(auth.identity)
            : canCreateModules(auth.identity));

    if (!allowed) {
      setState(() {
        _serverError = _isEditing
            ? 'This account does not have permission to edit modules.'
            : 'This account does not have permission to create modules.';
      });
      return;
    }

    final title = _titleController.text.trim();
    final description = _descriptionController.text.trim();
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
      final controller = ref.read(moduleMutationProvider);
      if (_isEditing) {
        await controller.update(
          versionId: widget.versionId,
          moduleId: widget.moduleId!,
          title: title != _initialTitle ? title : null,
          description: description != _initialDescription ? description : null,
          position: position != _initialPosition ? position : null,
          cancelToken: cancelToken,
        );
      } else {
        await controller.create(
          versionId: widget.versionId,
          title: title,
          description: description,
          position: position,
          cancelToken: cancelToken,
        );
      }

      if (!mounted) return;

      ref.invalidate(managedVersionDetailProvider(widget.versionId));
      if (_isEditing) {
        ref.invalidate(
          managedModuleDetailProvider((
            versionId: widget.versionId,
            moduleId: widget.moduleId!,
          )),
        );
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _isEditing
                ? 'Module updated successfully.'
                : 'Module "$title" created successfully.',
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
          _serverError = 'The curriculum version or module was not found, or is no longer in draft.';
        } else if (parsed.statusCode == 403) {
          _serverError =
              'You do not have permission to ${_isEditing ? "edit" : "create"} modules.';
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
            ? canEditModules(auth.identity)
            : canCreateModules(auth.identity));

    if (!permitted) {
      return Scaffold(
        appBar: AppBar(title: Text(_isEditing ? 'Edit module' : 'New module')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Text(
              _isEditing
                  ? 'You do not have permission to edit modules.'
                  : 'You do not have permission to create modules.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    if (_isEditing && !_initialLoaded) {
      final asyncDetail = ref.watch(
        managedModuleDetailProvider((
          versionId: widget.versionId,
          moduleId: widget.moduleId!,
        )),
      );
      return asyncDetail.when(
        loading: () => Scaffold(
          appBar: AppBar(title: const Text('Edit module')),
          body: const Center(
            child: CardListSkeleton(
              message: 'Loading module details',
              compact: true,
            ),
          ),
        ),
        error: (error, _) => Scaffold(
          appBar: AppBar(title: const Text('Edit module')),
          body: ApiErrorView(
            error: error,
            onRetry: () => ref.refresh(
              managedModuleDetailProvider((
                versionId: widget.versionId,
                moduleId: widget.moduleId!,
              )).future,
            ),
          ),
        ),
        data: (detail) {
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
        appBar: AppBar(title: Text(_isEditing ? 'Edit module' : 'New module')),
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
                        Icons.view_module_outlined,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          _isEditing ? 'Module Settings' : 'Module Details',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'Modules organize lessons in a strict, explicit order. Positions must be unique within this draft version.',
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
                      labelText: 'Module Title *',
                      hintText: 'e.g. Workplace Safety Fundamentals',
                      errorText: _fieldErrors['title'],
                      border: const OutlineInputBorder(),
                    ),
                    maxLength: 200,
                    enabled: !_isSubmitting,
                    onChanged: (_) {
                      if (_fieldErrors.containsKey('title')) {
                        setState(() {
                          _fieldErrors = Map.from(_fieldErrors)
                            ..remove('title');
                        });
                      }
                    },
                    validator: (val) {
                      final trimmed = val?.trim() ?? '';
                      if (trimmed.isEmpty) return 'Module title is required.';
                      if (trimmed.length > 200) {
                        return 'Module title cannot exceed 200 characters.';
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
                            helperText: 'Positive integer ordering within this version.',
                            errorText: _fieldErrors['position'],
                            border: const OutlineInputBorder(),
                          ),
                          keyboardType: TextInputType.number,
                          enabled: !_isSubmitting,
                          onChanged: (_) {
                            if (_fieldErrors.containsKey('position')) {
                              setState(() {
                                _fieldErrors = Map.from(_fieldErrors)
                                  ..remove('position');
                              });
                            }
                          },
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
                                  setState(() {});
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
                                setState(() {});
                              },
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  TextFormField(
                    controller: _descriptionController,
                    decoration: InputDecoration(
                      labelText: 'Description (optional)',
                      hintText:
                          'Brief summary of module objectives and scope...',
                      errorText: _fieldErrors['description'],
                      border: const OutlineInputBorder(),
                    ),
                    maxLines: 4,
                    minLines: 2,
                    enabled: !_isSubmitting,
                    onChanged: (_) {
                      if (_fieldErrors.containsKey('description')) {
                        setState(() {
                          _fieldErrors = Map.from(_fieldErrors)
                            ..remove('description');
                        });
                      }
                    },
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  FilledButton.icon(
                    onPressed: _isSubmitting ? null : _submitForm,
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
                          : (_isEditing ? 'Save Changes' : 'Create Module'),
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
