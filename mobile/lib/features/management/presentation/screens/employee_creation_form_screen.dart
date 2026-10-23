import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';
import 'package:training_app/features/management/presentation/controllers/management_controller.dart';

class EmployeeCreationFormScreen extends ConsumerStatefulWidget {
  const EmployeeCreationFormScreen({super.key});

  @override
  ConsumerState<EmployeeCreationFormScreen> createState() =>
      _EmployeeCreationFormScreenState();
}

class _EmployeeCreationFormScreenState
    extends ConsumerState<EmployeeCreationFormScreen> {
  static const _noManager = -1;

  final _formKey = GlobalKey<FormState>();
  final _scrollController = ScrollController();
  final _employeeCodeController = TextEditingController();
  final _displayNameController = TextEditingController();
  late final String? _account;
  int? _departmentId;
  int? _jobRoleId;
  int _managerId = _noManager;
  DateTime? _dateJoined;
  bool _isSaving = false;
  bool _saveCompleted = false;
  CancelToken? _activeRequest;
  String? _serverError;
  String? _serverValidationError;
  Map<String, String> _fieldErrors = const {};

  bool get _isDirty =>
      _employeeCodeController.text.isNotEmpty ||
      _displayNameController.text.isNotEmpty ||
      _departmentId != null ||
      _jobRoleId != null ||
      _managerId != _noManager ||
      _dateJoined != null;

  @override
  void initState() {
    super.initState();
    _account = managementAccount(ref.read(authControllerProvider));
  }

  @override
  void dispose() {
    _activeRequest?.cancel('Employee creation form disposed');
    _scrollController.dispose();
    _employeeCodeController.dispose();
    _displayNameController.dispose();
    super.dispose();
  }

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? 'This field is required.' : null;

  Future<void> _chooseDate() async {
    final now = DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: _dateJoined ?? now,
      firstDate: DateTime(1900),
      lastDate: DateTime(2100),
    );
    if (selected != null && mounted) {
      setState(() {
        _dateJoined = DateTime(selected.year, selected.month, selected.day);
      });
    }
  }

  Future<void> _leave() async {
    if (_isSaving) return;
    if (!_isDirty) {
      context.pop();
      return;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard employee details?'),
        content: const Text('Your unsaved details will be lost.'),
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

  Map<String, String> _fieldErrorsFrom(ApiError error) {
    final details = error.details;
    if (details is! Map) return const {};
    final result = <String, String>{};
    for (final field in [
      'employee_code',
      'display_name',
      'department',
      'job_role',
      'reporting_manager',
      'date_joined',
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

  void _clearServerErrors() {
    _serverError = null;
    _serverValidationError = null;
    _fieldErrors = const {};
  }

  Future<void> _create() async {
    if (_isSaving || !_formKey.currentState!.validate()) return;
    if (_dateJoined == null) {
      setState(() {});
      return;
    }
    final auth = ref.read(authControllerProvider);
    if (auth is! AuthAuthenticated ||
        managementAccount(auth) != _account ||
        !canCreateEmployee(auth.identity)) {
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
      _clearServerErrors();
    });
    try {
      await ref
          .read(employeeCreationMutationProvider)
          .create(
            employeeCode: _employeeCodeController.text.trim(),
            displayName: _displayNameController.text.trim(),
            departmentId: _departmentId!,
            jobRoleId: _jobRoleId!,
            dateJoined: _formatDate(_dateJoined!),
            reportingManagerId: _managerId == _noManager ? null : _managerId,
            cancelToken: request,
          );
      if (!mounted ||
          request.isCancelled ||
          managementAccount(ref.read(authControllerProvider)) != _account) {
        return;
      }
      ref.invalidate(employeeDirectoryProvider(1));
      ref.invalidate(managementDashboardProvider);
      setState(() => _saveCompleted = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Employee created. No login account was linked.'),
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
            ? 'You are not authorized to create employees.'
            : apiError.message;
        _serverValidationError = apiError.statusCode == 403
            ? null
            : _nonFieldErrorFrom(apiError);
        _fieldErrors = _fieldErrorsFrom(apiError);
      });
      _scrollController.jumpTo(0);
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
        setState(() {});
      }
    });
    ref.listen<AsyncValue<EmployeeEditChoices>>(
      employeeCreationChoicesProvider,
      (_, next) {
        final error = next.error;
        if (error is ApiError && error.statusCode == 401) {
          ref.read(authControllerProvider.notifier).logout();
        }
      },
    );
    final auth = ref.watch(authControllerProvider);
    final permitted =
        auth is AuthAuthenticated &&
        managementAccount(auth) == _account &&
        canCreateEmployee(auth.identity);
    final choices = ref.watch(employeeCreationChoicesProvider);

    return PopScope<Object?>(
      canPop: _saveCompleted || (!_isDirty && !_isSaving),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_isSaving) _leave();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Add employee')),
        body: SafeArea(
          child: !permitted
              ? const _CreationNotice(
                  message: 'This account cannot create employees. Reopen the directory with an authorized account.',
                  isError: true,
                )
              : choices.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (error, _) => _CreationNotice(
                    message: error is ApiError
                        ? error.message
                        : 'Employee choices could not be loaded.',
                    isError: true,
                    onRetry: () =>
                        ref.invalidate(employeeCreationChoicesProvider),
                  ),
                  data: _buildForm,
                ),
        ),
      ),
    );
  }

  Widget _buildForm(EmployeeEditChoices choices) => Form(
    key: _formKey,
    autovalidateMode: AutovalidateMode.onUserInteraction,
    child: ListView(
      controller: _scrollController,
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          'New employee profile',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        const _CreationNotice(
          message: 'Employees created here will not have login access. Account linking and credentials are not part of this workflow.',
          isError: false,
        ),
        if (_serverError != null) ...[
          const SizedBox(height: 12),
          _CreationNotice(message: _serverError!, isError: true),
        ],
        if (_serverValidationError != null) ...[
          const SizedBox(height: 8),
          _CreationNotice(message: _serverValidationError!, isError: true),
        ],
        const SizedBox(height: 16),
        TextFormField(
          controller: _employeeCodeController,
          textCapitalization: TextCapitalization.characters,
          textInputAction: TextInputAction.next,
          maxLength: 30,
          decoration: InputDecoration(
            labelText: 'Employee code',
            errorText: _fieldErrors['employee_code'],
          ),
          validator: _required,
          onChanged: (_) => setState(_clearServerErrors),
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _displayNameController,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.next,
          maxLength: 150,
          decoration: InputDecoration(
            labelText: 'Display name',
            errorText: _fieldErrors['display_name'],
          ),
          validator: _required,
          onChanged: (_) => setState(_clearServerErrors),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<int>(
          initialValue: _departmentId,
          decoration: InputDecoration(
            labelText: 'Department',
            errorText: _fieldErrors['department'],
          ),
          items: choices.departments
              .map(
                (item) => DropdownMenuItem(
                  value: item.id,
                  child: Text(
                    item.isActive ? item.name : '${item.name} (inactive)',
                  ),
                ),
              )
              .toList(),
          validator: (value) => value == null ? 'Select a department.' : null,
          onChanged: (value) => setState(() {
            _departmentId = value;
            _clearServerErrors();
          }),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<int>(
          initialValue: _jobRoleId,
          decoration: InputDecoration(
            labelText: 'Job role',
            errorText: _fieldErrors['job_role'],
          ),
          items: choices.jobRoles
              .map(
                (item) => DropdownMenuItem(
                  value: item.id,
                  child: Text(
                    item.isActive ? item.name : '${item.name} (inactive)',
                  ),
                ),
              )
              .toList(),
          validator: (value) => value == null ? 'Select a job role.' : null,
          onChanged: (value) => setState(() {
            _jobRoleId = value;
            _clearServerErrors();
          }),
        ),
        const SizedBox(height: 16),
        InputDecorator(
          decoration: InputDecoration(
            labelText: 'Date joined',
            errorText: _dateJoined == null
                ? 'Select a date joined.'
                : _fieldErrors['date_joined'],
            border: const OutlineInputBorder(),
          ),
          child: Semantics(
            button: true,
            label:
                'Date joined: ${_dateJoined == null ? 'Not selected' : _formatDate(_dateJoined!)}',
            child: TextButton.icon(
              onPressed: _chooseDate,
              icon: const Icon(Icons.calendar_today_outlined),
              label: Text(
                _dateJoined == null ? 'Choose date' : _formatDate(_dateJoined!),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<int>(
          initialValue: _managerId,
          decoration: InputDecoration(
            labelText: 'Reporting manager (optional)',
            helperText:
                'Manager choices follow your permitted employee directory.',
            errorText: _fieldErrors['reporting_manager'],
          ),
          items: [
            const DropdownMenuItem(
              value: _noManager,
              child: Text('No reporting manager'),
            ),
            ...choices.reportingManagers.map(
              (employee) => DropdownMenuItem(
                value: employee.id,
                child: Text(
                  '${employee.displayName} · ${employee.employeeCode}'
                  '${employee.isActive ? '' : ' (inactive)'}',
                ),
              ),
            ),
          ],
          onChanged: (value) {
            if (value != null) {
              setState(() {
                _managerId = value;
                _clearServerErrors();
              });
            }
          },
        ),
        const SizedBox(height: 24),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: _isSaving ? null : _create,
              icon: _isSaving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.person_add_alt_1_outlined),
              label: Text(_isSaving ? 'Creating…' : 'Create employee'),
            ),
            OutlinedButton(
              onPressed: _isSaving ? null : _leave,
              child: const Text('Cancel'),
            ),
          ],
        ),
      ],
    ),
  );

  String _formatDate(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}

class _CreationNotice extends StatelessWidget {
  final String message;
  final bool isError;
  final VoidCallback? onRetry;

  const _CreationNotice({
    required this.message,
    required this.isError,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final content = Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isError ? colors.errorContainer : colors.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message,
            style: TextStyle(
              color: isError ? colors.onErrorContainer : colors.onSurface,
            ),
          ),
          if (onRetry != null)
            TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
    if (isError) {
      return Semantics(liveRegion: true, child: content);
    }
    return content;
  }
}
