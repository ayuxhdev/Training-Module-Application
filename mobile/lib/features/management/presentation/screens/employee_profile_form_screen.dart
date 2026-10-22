import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';
import 'package:training_app/features/management/presentation/controllers/management_controller.dart';

class EmployeeProfileFormScreen extends ConsumerStatefulWidget {
  final int employeeId;
  final DirectoryEmployee? initialEmployee;

  const EmployeeProfileFormScreen({
    super.key,
    required this.employeeId,
    required this.initialEmployee,
  });

  @override
  ConsumerState<EmployeeProfileFormScreen> createState() =>
      _EmployeeProfileFormScreenState();
}

class _EmployeeProfileFormScreenState
    extends ConsumerState<EmployeeProfileFormScreen> {
  static const _clearManager = -2;

  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _displayNameController;
  late final String? _account;
  late int _departmentId;
  late int _jobRoleId;
  late DateTime? _dateJoined;
  late int _managerChoice;
  bool _isSaving = false;
  CancelToken? _activeRequest;
  String? _serverError;
  String? _serverValidationError;
  Map<String, String> _fieldErrors = const {};

  DirectoryEmployee get _original => widget.initialEmployee!;

  bool get _isDirty {
    final original = widget.initialEmployee;
    if (original == null || original.id != widget.employeeId) return false;
    return _displayNameController.text.trim() != original.displayName ||
        _departmentId != original.department.id ||
        _jobRoleId != original.jobRole.id ||
        _dateJoined == null ||
        _formatDate(_dateJoined!) != original.dateJoined ||
        _selectedReportingManagerId != original.reportingManagerId;
  }

  int? get _selectedReportingManagerId =>
      _managerChoice == _clearManager ? null : _managerChoice;

  @override
  void initState() {
    super.initState();
    final employee = widget.initialEmployee;
    _displayNameController = TextEditingController(
      text: employee?.displayName ?? '',
    );
    _departmentId = employee?.department.id ?? 0;
    _jobRoleId = employee?.jobRole.id ?? 0;
    _dateJoined = _parseDate(employee?.dateJoined);
    _managerChoice = employee?.reportingManagerId ?? _clearManager;
    _account = managementAccount(ref.read(authControllerProvider));
  }

  @override
  void dispose() {
    _activeRequest?.cancel('Employee form disposed');
    _displayNameController.dispose();
    super.dispose();
  }

  DateTime? _parseDate(String? value) {
    if (value == null) return null;
    try {
      return DateTime.parse(value);
    } on FormatException {
      return null;
    }
  }

  String _formatDate(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  Map<String, String> _fieldErrorsFrom(ApiError error) {
    final details = error.details;
    if (details is! Map) return const {};
    final result = <String, String>{};
    for (final field in [
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

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? 'Name is required.' : null;

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
        _clearServerErrors();
      });
    }
  }

  void _clearServerErrors() {
    _serverError = null;
    _serverValidationError = null;
    _fieldErrors = const {};
  }

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
    if (_isSaving || !_isDirty || !_formKey.currentState!.validate()) return;
    final auth = ref.read(authControllerProvider);
    if (auth is! AuthAuthenticated ||
        managementAccount(auth) != _account ||
        !canEditEmployee(auth.identity)) {
      setState(() {
        _serverError = 'Your account or permissions changed. Reopen this employee to continue.';
      });
      return;
    }
    if (_dateJoined == null) {
      setState(() {
        _serverError =
            'The current join date is unavailable. Refresh and try again.';
      });
      return;
    }

    final request = CancelToken();
    _activeRequest = request;
    final updateReportingManager =
        _selectedReportingManagerId != _original.reportingManagerId;
    setState(() {
      _isSaving = true;
      _clearServerErrors();
    });
    try {
      await ref
          .read(employeeProfileMutationProvider)
          .save(
            original: _original,
            displayName: _displayNameController.text.trim(),
            departmentId: _departmentId,
            jobRoleId: _jobRoleId,
            dateJoined: _formatDate(_dateJoined!),
            updateReportingManager: updateReportingManager,
            reportingManagerId: updateReportingManager
                ? _selectedReportingManagerId
                : null,
            cancelToken: request,
          );
      if (!mounted ||
          request.isCancelled ||
          managementAccount(ref.read(authControllerProvider)) != _account) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Employee profile saved.')));
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
            ? 'You are not authorized to edit this employee.'
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
    ref.listen<AsyncValue<EmployeeEditChoices>>(
      employeeEditChoicesProvider(widget.employeeId),
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
        canEditEmployee(auth.identity);
    final validRecord =
        widget.initialEmployee?.id == widget.employeeId &&
        widget.initialEmployee != null;
    final choices = ref.watch(employeeEditChoicesProvider(widget.employeeId));

    return PopScope<Object?>(
      canPop: !_isDirty || _isSaving,
      onPopInvokedWithResult: _onPopInvoked,
      child: Scaffold(
        appBar: AppBar(title: const Text('Edit employee')),
        body: SafeArea(
          child: !validRecord
              ? const _EmployeeFormNotice(
                  message: 'Employee details are unavailable. Return to the directory and open the record again.',
                  isError: true,
                )
              : !permitted
              ? const _EmployeeFormNotice(
                  message: 'This account cannot edit employee profiles.',
                  isError: true,
                )
              : choices.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (error, _) => _EmployeeFormNotice(
                    message: error is ApiError
                        ? error.message
                        : 'Employee edit choices could not be loaded.',
                    isError: true,
                    onRetry: () => ref.invalidate(
                      employeeEditChoicesProvider(widget.employeeId),
                    ),
                  ),
                  data: (options) => _buildForm(options),
                ),
        ),
      ),
    );
  }

  Widget _buildForm(EmployeeEditChoices choices) {
    final departments = _withCurrentReference(
      choices.departments,
      _original.department,
    );
    final jobRoles = _withCurrentReference(choices.jobRoles, _original.jobRole);
    final managers = choices.reportingManagers;
    final currentManagerIsListed = managers.any(
      (employee) => employee.id == _original.reportingManagerId,
    );
    final currentDepartmentAvailable = departments.any(
      (item) => item.id == _departmentId,
    );
    final currentJobRoleAvailable = jobRoles.any(
      (item) => item.id == _jobRoleId,
    );
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Update employee profile',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            'Employee code, login access, groups and employment status are protected.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 20),
          if (_serverError != null)
            _EmployeeFormNotice(message: _serverError!, isError: true),
          if (_serverValidationError != null)
            _EmployeeFormNotice(
              message: _serverValidationError!,
              isError: true,
            ),
          TextFormField(
            controller: _displayNameController,
            enabled: !_isSaving,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            maxLength: 150,
            decoration: InputDecoration(
              labelText: 'Display name',
              errorText: _fieldErrors['display_name'],
            ),
            validator: _required,
            onChanged: (_) => _clearErrorsWithRebuild(),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<int>(
            initialValue: currentDepartmentAvailable ? _departmentId : null,
            decoration: InputDecoration(
              labelText: 'Department',
              errorText: _fieldErrors['department'],
            ),
            items: departments
                .map(
                  (item) => DropdownMenuItem(
                    value: item.id,
                    child: Text(
                      item.isActive ? item.name : '${item.name} (inactive)',
                    ),
                  ),
                )
                .toList(),
            onChanged: _isSaving
                ? null
                : (value) {
                    if (value != null) {
                      setState(() {
                        _departmentId = value;
                        _clearServerErrors();
                      });
                    }
                  },
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<int>(
            initialValue: currentJobRoleAvailable ? _jobRoleId : null,
            decoration: InputDecoration(
              labelText: 'Job role',
              errorText: _fieldErrors['job_role'],
            ),
            items: jobRoles
                .map(
                  (item) => DropdownMenuItem(
                    value: item.id,
                    child: Text(
                      item.isActive ? item.name : '${item.name} (inactive)',
                    ),
                  ),
                )
                .toList(),
            onChanged: _isSaving
                ? null
                : (value) {
                    if (value != null) {
                      setState(() {
                        _jobRoleId = value;
                        _clearServerErrors();
                      });
                    }
                  },
          ),
          const SizedBox(height: 16),
          InputDecorator(
            decoration: InputDecoration(
              labelText: 'Date joined',
              errorText: _fieldErrors['date_joined'],
              border: const OutlineInputBorder(),
            ),
            child: Semantics(
              button: true,
              label:
                  'Date joined: ${_dateJoined == null ? 'Unavailable' : _formatDate(_dateJoined!)}',
              child: TextButton.icon(
                onPressed: _isSaving ? null : _chooseDate,
                icon: const Icon(Icons.calendar_today_outlined),
                label: Text(
                  _dateJoined == null
                      ? 'Unavailable'
                      : _formatDate(_dateJoined!),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<int>(
            initialValue: _managerChoice,
            decoration: InputDecoration(
              labelText: 'Reporting manager',
              helperText: 'Choose an employee or clear the current manager.',
              errorText: _fieldErrors['reporting_manager'],
            ),
            items: [
              if (_original.reportingManagerId != null &&
                  !currentManagerIsListed)
                DropdownMenuItem(
                  value: _original.reportingManagerId,
                  child: Text(
                    '${_original.reportingManager ?? 'Current manager'} (current)',
                  ),
                ),
              const DropdownMenuItem(
                value: _clearManager,
                child: Text('No reporting manager'),
              ),
              ...managers.map(
                (employee) => DropdownMenuItem(
                  value: employee.id,
                  child: Text(
                    '${employee.displayName} · ${employee.employeeCode}'
                    '${employee.isActive ? '' : ' (inactive)'}',
                  ),
                ),
              ),
            ],
            onChanged: _isSaving
                ? null
                : (value) {
                    if (value != null) {
                      setState(() {
                        _managerChoice = value;
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
                onPressed: _isSaving || !_isDirty ? null : _save,
                icon: _isSaving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
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
    );
  }

  List<OrganizationReference> _withCurrentReference(
    List<OrganizationReference> options,
    OrganizationReference current,
  ) {
    if (options.any((item) => item.id == current.id)) return options;
    return [...options, current];
  }

  void _clearErrorsWithRebuild() => setState(_clearServerErrors);
}

class _EmployeeFormNotice extends StatelessWidget {
  final String message;
  final bool isError;
  final VoidCallback? onRetry;

  const _EmployeeFormNotice({
    required this.message,
    required this.isError,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Semantics(
        liveRegion: true,
        child: Container(
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
        ),
      ),
    );
  }
}
