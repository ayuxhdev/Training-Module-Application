import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';
import 'package:training_app/features/management/presentation/controllers/management_controller.dart';

class OrganizationReferenceFormScreen extends ConsumerStatefulWidget {
  final ReferenceKind kind;
  final int? referenceId;
  final OrganizationReference? initialReference;

  const OrganizationReferenceFormScreen({
    super.key,
    required this.kind,
    this.referenceId,
    this.initialReference,
  });

  @override
  ConsumerState<OrganizationReferenceFormScreen> createState() =>
      _OrganizationReferenceFormScreenState();
}

class _OrganizationReferenceFormScreenState
    extends ConsumerState<OrganizationReferenceFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _codeController;
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late final String? _account;
  late final String _originalCode;
  late final String _originalName;
  late final String _originalDescription;
  late final bool _originalActive;
  bool _isActive = true;
  bool _isSaving = false;
  CancelToken? _activeRequest;
  String? _serverError;
  String? _serverValidationError;
  Map<String, String> _fieldErrors = const {};

  bool get _isEditing => widget.referenceId != null;

  bool get _isDirty =>
      _codeController.text.trim() != _originalCode ||
      _nameController.text.trim() != _originalName ||
      _descriptionController.text.trim() != _originalDescription ||
      _isActive != _originalActive;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialReference;
    _codeController = TextEditingController(text: initial?.code ?? '');
    _nameController = TextEditingController(text: initial?.name ?? '');
    _descriptionController = TextEditingController(
      text: initial?.description ?? '',
    );
    _originalCode = initial?.code ?? '';
    _originalName = initial?.name ?? '';
    _originalDescription = initial?.description ?? '';
    _originalActive = initial?.isActive ?? true;
    _isActive = _originalActive;
    _account = managementAccount(ref.read(authControllerProvider));
  }

  @override
  void dispose() {
    _activeRequest?.cancel('Form disposed');
    _codeController.dispose();
    _nameController.dispose();
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

  String? _requiredField(String? value, String label, int maxLength) {
    final normalized = value?.trim() ?? '';
    if (normalized.isEmpty) return '$label is required.';
    if (normalized.length > maxLength) {
      return '$label must be $maxLength characters or fewer.';
    }
    return null;
  }

  Map<String, String> _fieldErrorsFrom(ApiError error) {
    final details = error.details;
    if (details is! Map) return const {};
    final result = <String, String>{};
    for (final field in ['code', 'name', 'description', 'is_active']) {
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
        content: const Text('Your unsaved changes will be lost.'),
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
            ? canEditOrganizationReference(auth.identity, widget.kind)
            : canCreateOrganizationReference(auth.identity, widget.kind));
    if (!allowed) {
      setState(() {
        _serverError = 'Your account or permissions changed. Return to the list and reopen this form.';
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
      await ref
          .read(organizationReferenceMutationProvider)
          .save(
            kind: widget.kind,
            id: widget.referenceId,
            original: widget.initialReference,
            code: _codeController.text.trim(),
            name: _nameController.text.trim(),
            description: _descriptionController.text.trim(),
            isActive: _isActive,
            cancelToken: request,
          );
      if (!mounted ||
          request.isCancelled ||
          managementAccount(ref.read(authControllerProvider)) != _account) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${widget.kind.singular[0].toUpperCase()}${widget.kind.singular.substring(1)} saved.',
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
            ? 'You are not authorized to save this ${widget.kind.singular}.'
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
            ? canEditOrganizationReference(auth.identity, widget.kind)
            : canCreateOrganizationReference(auth.identity, widget.kind));
    final initialRecordMatches =
        !_isEditing ||
        (widget.initialReference != null &&
            widget.initialReference!.id == widget.referenceId);

    return PopScope<Object?>(
      canPop: !_isDirty || _isSaving,
      onPopInvokedWithResult: _onPopInvoked,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            '${_isEditing ? 'Edit' : 'Create'} ${widget.kind.singular}',
          ),
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                '${_isEditing ? 'Edit' : 'Create'} ${widget.kind.singular}',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                'Enter the reference code, name, description and availability.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 20),
              if (!initialRecordMatches)
                const _FormNotice(
                  message: 'This record could not be loaded. Return to the list and select it again.',
                  isError: true,
                )
              else if (!permitted)
                const _FormNotice(
                  message: 'This account does not have permission to make this change.',
                  isError: true,
                )
              else ...[
                if (_serverError != null)
                  _FormNotice(message: _serverError!, isError: true),
                if (_serverValidationError != null)
                  _FormNotice(message: _serverValidationError!, isError: true),
                Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextFormField(
                        controller: _codeController,
                        enabled: !_isSaving,
                        textCapitalization: TextCapitalization.characters,
                        textInputAction: TextInputAction.next,
                        maxLength: 30,
                        decoration: InputDecoration(
                          labelText: 'Code',
                          errorText: _fieldError('code'),
                        ),
                        validator: (value) => _requiredField(value, 'Code', 30),
                        onChanged: (_) => _markChanged(),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _nameController,
                        enabled: !_isSaving,
                        textCapitalization: TextCapitalization.words,
                        textInputAction: TextInputAction.next,
                        maxLength: 120,
                        decoration: InputDecoration(
                          labelText: 'Name',
                          errorText: _fieldError('name'),
                        ),
                        validator: (value) =>
                            _requiredField(value, 'Name', 120),
                        onChanged: (_) => _markChanged(),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _descriptionController,
                        enabled: !_isSaving,
                        minLines: 3,
                        maxLines: 6,
                        textInputAction: TextInputAction.newline,
                        decoration: InputDecoration(
                          labelText: 'Description',
                          alignLabelWithHint: true,
                          errorText: _fieldError('description'),
                        ),
                        onChanged: (_) => _markChanged(),
                      ),
                      const SizedBox(height: 8),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Active'),
                        subtitle: const Text(
                          'Inactive references remain available for historical records.',
                        ),
                        value: _isActive,
                        onChanged: _isSaving
                            ? null
                            : (value) {
                                setState(() {
                                  _isActive = value;
                                  _serverError = null;
                                  _serverValidationError = null;
                                  _fieldErrors = const {};
                                });
                              },
                      ),
                      if (_fieldError('is_active') case final error?)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            error,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      const SizedBox(height: 20),
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            onPressed: _isSaving || (_isEditing && !_isDirty)
                                ? null
                                : _save,
                            icon: _isSaving
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.save_outlined),
                            label: Text(_isSaving ? 'Saving…' : 'Save'),
                          ),
                          OutlinedButton(
                            onPressed: _isSaving ? null : _leave,
                            child: const Text('Cancel'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _FormNotice extends StatelessWidget {
  final String message;
  final bool isError;

  const _FormNotice({required this.message, required this.isError});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isError ? colors.errorContainer : colors.surfaceContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          message,
          style: TextStyle(
            color: isError ? colors.onErrorContainer : colors.onSurface,
          ),
        ),
      ),
    );
  }
}
